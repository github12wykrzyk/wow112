from pathlib import Path
import re

PATH = Path("probes/Wow112HeadlessAndroid/src/bin/tele08_e_live_runtime.rs")
text = PATH.read_text(encoding="utf-8")
original = text


def sub_once(pattern: str, replacement: str, label: str, flags=re.S):
    global text
    text, n = re.subn(pattern, replacement, text, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f"PATCH FAIL {label}: matches={n}")
    print(f"PATCH OK {label}")

# Use library-owned B/C/D/E types so the live runtime exercises the same code that passed crate CI.
sub_once(
    r'#\[path = "\.\./tele08_whisper_parser\.rs"\]\nmod tele08_whisper_parser;\n',
    '',
    'remove local parser module',
)
sub_once(
    r'use tele08_whisper_parser::\{ParserConfig, WhisperObservation\};',
    'use wow112_headless_android_probe::tele08_e_live_logic::LiveResponseLogic;\nuse wow112_headless_android_probe::tele08_whisper_parser::{ParserConfig, WhisperObservation};',
    'library parser and live logic imports',
    flags=0,
)

# Three representative end-to-end cases: C queue path, D unavailable path, E competition path.
sub_once(
    r'(?s)#\[derive\(Clone, Copy, Debug\)\]\nstruct LiveCase \{.*?\nconst CASES: \[LiveCase; 12\] = \[.*?\n\];',
    '''#[derive(Clone, Copy, Debug)]
struct LiveCase {
    id: u32,
    text: &'static str,
    expected_intent: &'static str,
    expected_destination: Option<&'static str>,
    expected_response: &'static str,
}

const CASES: [LiveCase; 3] = [
    LiveCase {
        id: 1,
        text: "hyjal pls",
        expected_intent: "SummonRequest",
        expected_destination: Some("hyjal"),
        expected_response: "Queued for Hyjal. Position: 1.",
    },
    LiveCase {
        id: 2,
        text: "winterspring pls",
        expected_intent: "SummonRequest",
        expected_destination: Some("winterspring"),
        expected_response: "Winterspring is temporarily unavailable. Available: Azshara, Hyjal.",
    },
    LiveCase {
        id: 3,
        text: "selling summons cheaper today",
        expected_intent: "CompetitionMessage",
        expected_destination: None,
        expected_response: "Please keep whispers to summon requests.",
    },
];''',
    'three-case E live matrix',
)

# Self-test contract becomes 3 cases and validates expected response text is non-empty.
text = text.replace('if CASES.len() != 12 {\n        return Err(format!("expected 12 live cases, got {}", CASES.len()));\n    }',
                    'if CASES.len() != 3 {\n        return Err(format!("expected 3 live cases, got {}", CASES.len()));\n    }')
if 'expected 3 live cases' not in text:
    raise SystemExit('PATCH FAIL self-test count')
text = text.replace('        if actual_intent != case.expected_intent\n            || actual_destination != case.expected_destination\n        {',
                    '        if actual_intent != case.expected_intent\n            || actual_destination != case.expected_destination\n            || case.expected_response.is_empty()\n        {')

# Rename evidence labels so B and E live artifacts cannot be confused.
text = text.replace('TELE08-B-LIVE', 'TELE08-E-LIVE')
text = text.replace('TELE08 B LIVE E2E', 'TELE08 E LIVE E2E')
text = text.replace('TELE08_B_LIVE_E2E', 'TELE08_E_LIVE_E2E')
text = text.replace('tele08_b_live_runs', 'tele08_e_live_runs')
text = text.replace('tele08_b_live_test_', 'tele08_e_live_test_')

# CUSTOMER: send one request then wait for exact server echo/reply before advancing.
sub_once(
    r'(?s)    fn sender_loop\(.*?\n    \}\n\n    fn passive_loop\(',
    '''    fn sender_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        state_path: &Path,
        go_file: &Path,
        done_file: &Path,
        target: &str,
    ) -> Result<(), String> {
        wait_for_go_with_keepalive(stream, crypto, role_label, go_file, done_file)?;
        let deadline = Instant::now() + Duration::from_secs(crate::LIVE_TIMEOUT_SECS);
        let mut keepalive = Keepalive::new();
        let mut received = 0usize;

        for case in crate::CASES {
            tele_send_whisper(stream, crypto, target, case.text)?;
            println!(
                "[TELE08-E-LIVE:{role_label}] TX case={} target={:?} text={:?}",
                case.id, target, case.text
            );

            loop {
                keepalive.maybe_send(stream, crypto)?;
                match read_encrypted_raw(stream, crypto.decrypter()) {
                    Ok((opcode, payload)) => {
                        if keepalive.handle_pong(opcode, &payload) {
                            continue;
                        }
                        if opcode != SMSG_MESSAGECHAT_OPCODE {
                            continue;
                        }
                        let message = match parse_raw_server_message(opcode, &payload) {
                            Ok(value) => value,
                            Err(_) => continue,
                        };
                        if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                            let is_reply = matches!(
                                chat.chat_type,
                                SMSG_MESSAGECHAT_ChatType::Whisper { .. }
                                    | SMSG_MESSAGECHAT_ChatType::WhisperInform { .. }
                            );
                            if is_reply && chat.message == case.expected_response {
                                received += 1;
                                println!(
                                    "[TELE08-E-LIVE:{role_label}] RX-RESPONSE case={} PASS text={:?}",
                                    case.id, chat.message
                                );
                                break;
                            }
                        }
                    }
                    Err(error)
                        if error.contains("TimedOut")
                            || error.contains("timed out")
                            || error.contains("WouldBlock") => {}
                    Err(error) => return Err(error),
                }
                if Instant::now() >= deadline {
                    return Err(format!(
                        "CUSTOMER response timeout case={} expected={:?} received={received}",
                        case.id, case.expected_response
                    ));
                }
            }
            thread::sleep(Duration::from_millis(crate::SEND_GAP_MS));
        }

        crate::write_state(
            state_path,
            "PASS",
            role_label,
            &format!("received {received}/{} exact responses", crate::CASES.len()),
        )?;
        while !done_file.exists() {
            keepalive.poll(stream, crypto, role_label)?;
        }
        crate::write_state(state_path, "DONE", role_label, "orchestrator complete")?;
        Ok(())
    }

    fn passive_loop(''',
    'customer send and exact reply verification',
)

# SUMMONER: real RX -> parser -> B/C/D/E logic -> real TX. Winterspring is forced unhealthy
# only in the test harness so the D-unavailable branch is deterministic.
sub_once(
    r'(?s)    fn listener_loop\(.*?\n    \}\n\n    fn classify_case\(.*?\n    \}\n\}',
    '''    fn listener_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        role_label: &str,
        state_path: &Path,
        go_file: &Path,
        done_file: &Path,
        result_file: &Path,
        expected_sender: &str,
    ) -> Result<(), String> {
        wait_for_go_with_keepalive(stream, crypto, role_label, go_file, done_file)?;
        let deadline = Instant::now() + Duration::from_secs(crate::LIVE_TIMEOUT_SECS);
        let mut keepalive = Keepalive::new();
        let mut name_cache: HashMap<u64, String> = HashMap::new();
        let mut pending: HashMap<u64, Vec<String>> = HashMap::new();
        let mut results: Vec<crate::CaseResult> = Vec::new();
        let mut logic = LiveResponseLogic::seeded()?;
        logic.set_destination_unhealthy("winterspring")?;

        while results.len() < crate::CASES.len() {
            keepalive.maybe_send(stream, crypto)?;
            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if keepalive.handle_pong(opcode, &payload) {
                        continue;
                    }
                    if opcode == SMSG_NAME_QUERY_RESPONSE_OPCODE {
                        if let Ok((guid, name)) = tele_parse_name_query_response(&payload) {
                            name_cache.insert(guid, name.clone());
                            if let Some(items) = pending.remove(&guid) {
                                for text in items {
                                    if name.eq_ignore_ascii_case(expected_sender) {
                                        process_case(stream, crypto, &name, &text, &mut logic, &mut results)?;
                                    }
                                }
                            }
                        }
                        continue;
                    }
                    if opcode != SMSG_MESSAGECHAT_OPCODE {
                        continue;
                    }
                    let message = match parse_raw_server_message(opcode, &payload) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if let ServerOpcodeMessage::SMSG_MESSAGECHAT(chat) = message {
                        if let SMSG_MESSAGECHAT_ChatType::Whisper { sender2 } = chat.chat_type {
                            let guid = sender2.guid();
                            let text = chat.message;
                            if let Some(name) = name_cache.get(&guid).cloned() {
                                if name.eq_ignore_ascii_case(expected_sender) {
                                    process_case(stream, crypto, &name, &text, &mut logic, &mut results)?;
                                }
                            } else {
                                let first = !pending.contains_key(&guid);
                                pending.entry(guid).or_default().push(text);
                                if first {
                                    tele_send_name_query(stream, crypto, guid)?;
                                }
                            }
                        }
                    }
                }
                Err(error)
                    if error.contains("TimedOut")
                        || error.contains("timed out")
                        || error.contains("WouldBlock") => {}
                Err(error) => return Err(error),
            }
            if Instant::now() >= deadline {
                crate::write_results(result_file, &results)?;
                return Err(format!("listener timeout received={}/{}", results.len(), crate::CASES.len()));
            }
        }

        crate::write_results(result_file, &results)?;
        let failed = results.iter().filter(|result| !result.pass).count();
        if failed != 0 {
            crate::write_state(state_path, "FAIL", role_label, &format!("{failed} B-C-D-E mismatches"))?;
            return Err(format!("{failed} B-C-D-E mismatches"));
        }
        crate::write_state(
            state_path,
            "PASS",
            role_label,
            &format!("{} real B-C-D-E responses sent", results.len()),
        )?;
        while !done_file.exists() {
            keepalive.poll(stream, crypto, role_label)?;
        }
        Ok(())
    }

    fn process_case(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        sender: &str,
        text: &str,
        logic: &mut LiveResponseLogic,
        results: &mut Vec<crate::CaseResult>,
    ) -> Result<(), String> {
        let index = results.len();
        let case = crate::CASES
            .get(index)
            .ok_or_else(|| format!("unexpected extra whisper from {sender}: {text:?}"))?;
        let observation = WhisperObservation {
            sender: sender.to_string(),
            text: text.to_string(),
            timestamp_ms: observation_timestamp_ms(),
            source_role: Some("SUMMONER".to_string()),
            destination_context: None,
        };
        let classification =
            wow112_headless_android_probe::tele08_whisper_parser::classify_whisper(
                &observation,
                &ParserConfig::default(),
            );
        let actual_intent = format!("{:?}", classification.intent);
        let actual_destination = classification.destination.as_ref().map(|value| value.0.clone());
        let logic_now = 10 + (case.id as u64 * 10);
        let outcome = logic.handle(&classification, logic_now)?;
        let response = outcome
            .response
            .ok_or_else(|| format!("case {} produced no response trace={:?}", case.id, outcome.trace))?;
        let pass = text == case.text
            && actual_intent == case.expected_intent
            && actual_destination.as_deref() == case.expected_destination
            && response.should_send
            && response.text == case.expected_response;
        let reason = format!(
            "trace={} send={} response_match={}",
            outcome.trace.join("->"),
            response.should_send,
            response.text == case.expected_response
        );
        if response.should_send {
            tele_send_whisper(stream, crypto, sender, &response.text)?;
            println!(
                "[TELE08-E-LIVE:SUMMONER] TX-RESPONSE case={} target={:?} text={:?} trace={:?}",
                case.id, sender, response.text, outcome.trace
            );
        }
        results.push(crate::CaseResult {
            id: case.id,
            raw_text: text.to_string(),
            expected_intent: case.expected_intent.to_string(),
            actual_intent,
            expected_destination: case.expected_destination.map(str::to_string),
            actual_destination,
            sender: sender.to_string(),
            pass,
            reason,
        });
        if !pass {
            return Err(format!("case {} B-C-D-E mismatch", case.id));
        }
        Ok(())
    }
}''',
    'summoner B-C-D-E response loop',
)

# Update test name only; behavior now comes from run_self_test's 3-case contract.
text = text.replace('fn live_case_contract_is_exactly_twelve_and_offline_green()',
                    'fn live_case_contract_is_exactly_three_and_offline_green()')

if text == original:
    raise SystemExit('PATCH FAIL: no changes')
PATH.write_text(text, encoding='utf-8')
print('PATCH COMPLETE')
