from pathlib import Path

ACCEPTOR = Path('probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs')
SUPERVISOR = Path('probes/Wow112HeadlessAndroid/src/bin/tele07_supervisor.rs')

s = ACCEPTOR.read_text(encoding='utf-8')

old = '    const SMSG_SUMMON_REQUEST_OPCODE: u16 = 0x02AB;'
new = '''    const SMSG_SUMMON_REQUEST_OPCODE: u16 = 0x02AB;
    const CMSG_SUMMON_RESPONSE_OPCODE: u32 = 0x02AC;
    const SMSG_NEW_WORLD_OPCODE: u16 = 0x003E;
    const MSG_MOVE_WORLDPORT_ACK_OPCODE: u32 = 0x00DC;'''
if old not in s:
    raise SystemExit('constant anchor missing')
s = s.replace(old, new, 1)

old = '    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);'
new = '''    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);
    static SUMMON_RESPONSE_SENT: AtomicBool = AtomicBool::new(false);
    static WORLDPORT_ACK_SENT: AtomicBool = AtomicBool::new(false);'''
if old not in s:
    raise SystemExit('static anchor missing')
s = s.replace(old, new, 1)

s = s.replace('"PASS_RITUAL_COMPLETE"', '"SUMMON_REQUEST_SEEN"')

needle = '''                            println!(
                                "[TELE-06B-COMPLETE] PASS opcode=0x02AB summoner_guid=0x{summoner_guid:016X} area={area} auto_decline_ms={auto_decline_ms}"
                            );
'''
inject = needle + '''                            if SUMMON_RESPONSE_SENT
                                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                                .is_ok()
                            {
                                publish_runner_state(
                                    "SUMMON_ACCEPT_COMMITTED",
                                    &format!("opcode=0x02AC summoner_guid=0x{summoner_guid:016X} retry_allowed=false"),
                                );
                                if let Err(error) = write_encrypted_raw(
                                    stream,
                                    crypto.encrypter(),
                                    CMSG_SUMMON_RESPONSE_OPCODE,
                                    &summoner_guid.to_le_bytes(),
                                ) {
                                    publish_runner_state(
                                        "FAIL_SUMMON_ACCEPT_UNCERTAIN",
                                        &format!("opcode=0x02AC summoner_guid=0x{summoner_guid:016X} socket write uncertain; retry disabled"),
                                    );
                                    return Err(format!("TELE10_SUMMON_ACCEPT_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                                }
                                publish_runner_state(
                                    "WAIT_NEW_WORLD",
                                    &format!("accepted summoner_guid=0x{summoner_guid:016X}; waiting SMSG_NEW_WORLD opcode=0x003E"),
                                );
                                println!("[TELE-10-ACCEPT-TX] PASS opcode=0x02AC summoner_guid=0x{summoner_guid:016X} retry_allowed=false");
                            }
'''
if needle not in s:
    raise SystemExit('summon completion injection anchor missing')
s = s.replace(needle, inject, 1)

anchor = '                    if role == Tele06bRole::Clicker {'
new_world = '''                    if role == Tele06bRole::Customer && opcode == SMSG_NEW_WORLD_OPCODE {
                        if !SUMMON_RESPONSE_SENT.load(Ordering::SeqCst) {
                            println!("[TELE-10-NEW-WORLD-DIAG] ignored 0x003E before summon accept bytes={}", payload.len());
                            continue;
                        }
                        if WORLDPORT_ACK_SENT
                            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                            .is_ok()
                        {
                            publish_runner_state(
                                "WORLDPORT_ACK_COMMITTED",
                                &format!("SMSG_NEW_WORLD bytes={} observed; sending opcode=0x00DC retry_allowed=false", payload.len()),
                            );
                            if let Err(error) = write_encrypted_raw(
                                stream,
                                crypto.encrypter(),
                                MSG_MOVE_WORLDPORT_ACK_OPCODE,
                                &[],
                            ) {
                                publish_runner_state(
                                    "FAIL_WORLDPORT_ACK_UNCERTAIN",
                                    "opcode=0x00DC socket write uncertain after NEW_WORLD; retry disabled",
                                );
                                return Err(format!("TELE10_WORLDPORT_ACK_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                            }
                            publish_runner_state(
                                "PASS_TELEPORT_COMPLETE",
                                &format!("SMSG_NEW_WORLD opcode=0x003E bytes={} + MSG_MOVE_WORLDPORT_ACK opcode=0x00DC write=success", payload.len()),
                            );
                            println!("[TELE-10-TELEPORT] PASS new_world_bytes={} worldport_ack=sent", payload.len());
                        }
                        continue;
                    }

'''
if anchor not in s:
    raise SystemExit('clicker anchor missing')
s = s.replace(anchor, new_world + anchor, 1)
ACCEPTOR.write_text(s, encoding='utf-8')

ss = SUPERVISOR.read_text(encoding='utf-8')
repls = [
    ('if customer.state == "PASS_RITUAL_COMPLETE"', 'if customer.state == "PASS_TELEPORT_COMPLETE"'),
    ('code: "PASS_RITUAL_COMPLETE".to_string(),', 'code: "PASS_TELEPORT_COMPLETE".to_string(),'),
    ('detail: format!("server 0x02AB confirmed; {}", customer.detail),', 'detail: format!("summon accepted and far teleport completed; {}", customer.detail),'),
    ('if verdict.code == "PASS_RITUAL_COMPLETE" {', 'if verdict.code == "PASS_TELEPORT_COMPLETE" {'),
]
for old, new in repls:
    if old not in ss:
        raise SystemExit(f'supervisor anchor missing: {old}')
    ss = ss.replace(old, new, 1)
SUPERVISOR.write_text(ss, encoding='utf-8')
print('TELE10_PATCH_OK')
