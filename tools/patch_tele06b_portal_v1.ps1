$ErrorActionPreference = 'Stop'

$acceptor = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs'
$a = Get-Content $acceptor -Raw

function Require-Replace([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old, $New)
}

$staticAnchor = @'
    static RESET_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static ACCEPT_ATTEMPTED: AtomicBool = AtomicBool::new(false);
'@

$tele06bCore = @'
    static RESET_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static ACCEPT_ATTEMPTED: AtomicBool = AtomicBool::new(false);

    const CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1;
    const SMSG_SUMMON_REQUEST_OPCODE: u16 = 0x02AB;
    const SUMMONING_PORTAL_ENTRY_TELE06B: i32 = 36727;
    const GAMEOBJECT_TYPE_RITUAL_TELE06B: i32 = 18;

    static PORTAL_USE_ATTEMPTED: AtomicBool = AtomicBool::new(false);
    static PORTAL_USE_SUCCEEDED: AtomicBool = AtomicBool::new(false);
    static SUMMON_REQUEST_SEEN: AtomicBool = AtomicBool::new(false);

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Tele06bRole {
        Observer,
        Customer,
        Clicker,
    }

    fn configured_tele06b_role() -> Result<Tele06bRole, String> {
        let value = std::env::var("WOW112_TELE06B_ROLE")
            .unwrap_or_else(|_| "observer".to_string())
            .trim()
            .to_ascii_lowercase();
        match value.as_str() {
            "" | "observer" => Ok(Tele06bRole::Observer),
            "customer" => Ok(Tele06bRole::Customer),
            "clicker" => Ok(Tele06bRole::Clicker),
            other => Err(format!("invalid WOW112_TELE06B_ROLE={other:?}; expected observer/customer/clicker")),
        }
    }

    fn tele06b_mask_is_summoning_portal(mask: &UpdateMask) -> bool {
        match mask {
            UpdateMask::GameObject(go) => {
                let entry = go
                    .object_entry()
                    .map(|value| value == SUMMONING_PORTAL_ENTRY_TELE06B)
                    .unwrap_or(false);
                let ritual = go
                    .gameobject_type_id()
                    .map(|value| value == GAMEOBJECT_TYPE_RITUAL_TELE06B)
                    .unwrap_or(false);
                entry || ritual
            }
            _ => false,
        }
    }

    fn tele06b_collect_portals(objects: &[Object], portals: &mut HashSet<u64>) {
        for object in objects {
            let guid = match object {
                Object::Values { guid1, mask1 } if tele06b_mask_is_summoning_portal(mask1) => {
                    Some(guid1.guid())
                }
                Object::CreateObject { guid3, mask2, .. }
                | Object::CreateObject2 { guid3, mask2, .. }
                    if tele06b_mask_is_summoning_portal(mask2) =>
                {
                    Some(guid3.guid())
                }
                _ => None,
            };
            if let Some(guid) = guid {
                if portals.insert(guid) {
                    println!("[TELE-06B-PORTAL] observed valid summoning portal guid=0x{guid:016X}");
                    println!(
                        "[TELE-06B-PORTAL-OBJECT] {}",
                        tele_trace::truncate_chars(&format!("{object:?}"), 2400)
                    );
                    tele_trace::mark_portal_observed(guid);
                }
            }
        }
    }

    fn tele06b_inspect_portal_update(
        opcode: u16,
        payload: &[u8],
        portals: &mut HashSet<u64>,
    ) {
        if opcode != SMSG_UPDATE_OBJECT_OPCODE && opcode != SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
            return;
        }
        match parse_raw_server_message(opcode, payload) {
            Ok(ServerOpcodeMessage::SMSG_UPDATE_OBJECT(message)) => {
                tele06b_collect_portals(&message.objects, portals)
            }
            Ok(ServerOpcodeMessage::SMSG_COMPRESSED_UPDATE_OBJECT(message)) => {
                tele06b_collect_portals(&message.objects, portals)
            }
            Ok(_) => {}
            Err(error) => println!("[TELE-06B-PORTAL-DIAG] update parse skipped: {error}"),
        }
    }

    fn tele06b_post_handshake_loop(
        stream: &mut TcpStream,
        crypto: &mut HeaderCrypto,
        soak_seconds: u64,
    ) -> Result<(), String> {
        let role = configured_tele06b_role()?;
        if role == Tele06bRole::Observer {
            return tele_sniffer_loop(stream, crypto, soak_seconds);
        }

        let previous_timeout = stream.read_timeout().ok().flatten();
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|error| format!("set TELE-06B read timeout failed: {error}"))?;
        let deadline = if soak_seconds == 0 {
            None
        } else {
            Some(Instant::now() + Duration::from_secs(soak_seconds))
        };
        let mut last_ping = Instant::now();
        let mut ping_sequence = 1u32;
        let mut awaiting_pong: Option<(u32, Instant)> = None;
        let mut portals = HashSet::<u64>::new();

        match role {
            Tele06bRole::Customer => {
                if SUMMON_REQUEST_SEEN.load(Ordering::SeqCst) {
                    publish_runner_state(
                        "PASS_RITUAL_COMPLETE",
                        "SMSG_SUMMON_REQUEST observed in prior live session; completion latched",
                    );
                } else {
                    publish_runner_state(
                        "WAIT_SUMMON_REQUEST",
                        "waiting for server SMSG_SUMMON_REQUEST opcode=0x02AB",
                    );
                }
            }
            Tele06bRole::Clicker => {
                if PORTAL_USE_ATTEMPTED.load(Ordering::SeqCst) {
                    if PORTAL_USE_SUCCEEDED.load(Ordering::SeqCst) {
                        publish_runner_state(
                            "PORTAL_USED",
                            "portal use write succeeded in prior live session; retry disabled",
                        );
                    } else {
                        publish_runner_state(
                            "FAIL_PORTAL_MUTATION_UNCERTAIN",
                            "portal use was committed but socket result was uncertain; retry disabled",
                        );
                        return Err("TELE06B_PORTAL_MUTATION_UNCERTAIN retry_allowed=false".to_string());
                    }
                } else {
                    publish_runner_state(
                        "PORTAL_WAIT",
                        "waiting for summoning portal entry=36727/type=18",
                    );
                }
            }
            Tele06bRole::Observer => unreachable!(),
        }

        let role_label: &str = match role {
            Tele06bRole::Customer => "Customer",
            Tele06bRole::Clicker => "Clicker",
            Tele06bRole::Observer => "Observer",
        };

        println!(
            "[TELE-06B] post-handshake active role={role:?} portal_use=guarded_once completion=SMSG_SUMMON_REQUEST/0x02AB duration={}",
            if soak_seconds == 0 {
                "infinite".to_string()
            } else {
                format!("{soak_seconds}s")
            }
        );

        loop {
            tele_trace::poll_outcome(role_label);
            if deadline.is_some_and(|value| Instant::now() >= value) {
                let _ = stream.set_read_timeout(previous_timeout);
                return Ok(());
            }

            if let Some((sequence, sent_at)) = awaiting_pong {
                if sent_at.elapsed() >= Duration::from_secs(PONG_TIMEOUT_SECONDS) {
                    return Err(format!("world keepalive pong timeout sequence={sequence}"));
                }
            }
            if last_ping.elapsed() >= Duration::from_secs(PING_INTERVAL_SECONDS)
                && awaiting_pong.is_none()
            {
                let mut payload = Vec::with_capacity(8);
                payload.extend_from_slice(&ping_sequence.to_le_bytes());
                payload.extend_from_slice(&0u32.to_le_bytes());
                write_encrypted_raw(stream, crypto.encrypter(), CMSG_PING_OPCODE, &payload)?;
                println!("[TELE-06B] keepalive ping sequence={ping_sequence}");
                awaiting_pong = Some((ping_sequence, Instant::now()));
                ping_sequence = ping_sequence.wrapping_add(1);
                last_ping = Instant::now();
            }

            match read_encrypted_raw(stream, crypto.decrypter()) {
                Ok((opcode, payload)) => {
                    if opcode == SMSG_PONG_OPCODE {
                        if payload.len() >= 4 {
                            let sequence = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                            println!("[TELE-06B] keepalive pong sequence={sequence}");
                            if awaiting_pong.map(|value| value.0) == Some(sequence) {
                                awaiting_pong = None;
                            }
                        }
                        continue;
                    }

                    tele_trace::trace_packet(role_label, opcode, &payload);

                    if role == Tele06bRole::Customer && opcode == SMSG_SUMMON_REQUEST_OPCODE {
                        if payload.len() == 16 {
                            let summoner_guid =
                                u64::from_le_bytes(payload[0..8].try_into().unwrap());
                            let area = u32::from_le_bytes(payload[8..12].try_into().unwrap());
                            let auto_decline_ms =
                                u32::from_le_bytes(payload[12..16].try_into().unwrap());
                            SUMMON_REQUEST_SEEN.store(true, Ordering::SeqCst);
                            publish_runner_state(
                                "PASS_RITUAL_COMPLETE",
                                &format!(
                                    "SMSG_SUMMON_REQUEST opcode=0x02AB summoner_guid=0x{summoner_guid:016X} area={area} auto_decline_ms={auto_decline_ms}"
                                ),
                            );
                            println!(
                                "[TELE-06B-COMPLETE] PASS opcode=0x02AB summoner_guid=0x{summoner_guid:016X} area={area} auto_decline_ms={auto_decline_ms}"
                            );
                        } else {
                            println!(
                                "[TELE-06B-COMPLETE-DIAG] ignored malformed SMSG_SUMMON_REQUEST bytes={} expected=16",
                                payload.len()
                            );
                        }
                        continue;
                    }

                    if role == Tele06bRole::Clicker {
                        tele06b_inspect_portal_update(opcode, &payload, &mut portals);
                        if !PORTAL_USE_ATTEMPTED.load(Ordering::SeqCst) {
                            if let Some(guid) = portals.iter().copied().next() {
                                if PORTAL_USE_ATTEMPTED
                                    .compare_exchange(
                                        false,
                                        true,
                                        Ordering::SeqCst,
                                        Ordering::SeqCst,
                                    )
                                    .is_ok()
                                {
                                    publish_runner_state(
                                        "PORTAL_USE_COMMITTED",
                                        &format!(
                                            "guid=0x{guid:016X} opcode=0x00B1 guard committed before socket I/O"
                                        ),
                                    );
                                    println!(
                                        "[TELE-06B-PORTAL-TX] state=COMMITTED guid=0x{guid:016X} opcode=0x00B1 retry_allowed=false"
                                    );
                                    tele_trace::mark_click_commit(guid, &guid.to_le_bytes());
                                    if let Err(error) = write_encrypted_raw(
                                        stream,
                                        crypto.encrypter(),
                                        CMSG_GAMEOBJ_USE_OPCODE,
                                        &guid.to_le_bytes(),
                                    ) {
                                        publish_runner_state(
                                            "FAIL_PORTAL_MUTATION_UNCERTAIN",
                                            &format!(
                                                "guid=0x{guid:016X} socket write failed after guard commit; retry disabled"
                                            ),
                                        );
                                        println!(
                                            "[TELE-06B-PORTAL-TX] state=UNCERTAIN guid=0x{guid:016X} cause={error} retry_allowed=false"
                                        );
                                        return Err(
                                            "TELE06B_PORTAL_MUTATION_UNCERTAIN retry_allowed=false"
                                                .to_string(),
                                        );
                                    }
                                    PORTAL_USE_SUCCEEDED.store(true, Ordering::SeqCst);
                                    tele_trace::mark_click_write_done(guid);
                                    publish_runner_state(
                                        "PORTAL_USED",
                                        &format!(
                                            "guid=0x{guid:016X} opcode=0x00B1 write=success retry_allowed=false"
                                        ),
                                    );
                                    println!(
                                        "[TELE-06B-PORTAL-TX] state=PORTAL_USED guid=0x{guid:016X} opcode=0x00B1 result=sent_once retry_allowed=false"
                                    );
                                }
                            }
                        }
                    }

                    let _ = crate::tele_party_observer::inspect_party_packet(opcode, &payload);
                }
                Err(error)
                    if error.contains("TimedOut")
                        || error.contains("timed out")
                        || error.contains("WouldBlock") => {}
                Err(error) => return Err(error),
            }
        }
    }
'@

$a = Require-Replace $a $staticAnchor.Trim() $tele06bCore.Trim() 'TELE-06B core insertion'

$oldLoop = '        tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;'
$newLoop = '        tele06b_post_handshake_loop(stream, &mut crypto, soak_seconds)?;'
$a = Require-Replace $a $oldLoop $newLoop 'TELE-06B post-handshake loop'

Set-Content -Path $acceptor -Value $a -Encoding UTF8

$check = Get-Content $acceptor -Raw
foreach ($needle in @(
    'CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1',
    'SMSG_SUMMON_REQUEST_OPCODE: u16 = 0x02AB',
    'SUMMONING_PORTAL_ENTRY_TELE06B: i32 = 36727',
    'PORTAL_USE_ATTEMPTED',
    'PASS_RITUAL_COMPLETE',
    'FAIL_PORTAL_MUTATION_UNCERTAIN',
    'tele06b_post_handshake_loop',
    'tele_trace::trace_packet(role_label, opcode, &payload);',
    'tele_trace::mark_click_commit(guid, &guid.to_le_bytes());',
    'tele_trace::mark_click_write_done(guid);',
    'tele_trace::mark_portal_observed(guid);',
    'tele_trace::poll_outcome(role_label);'
)) {
    if (-not $check.Contains($needle)) { throw "TELE-06B runtime patch missing: $needle" }
}
if ($check.Contains('tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;')) {
    throw 'old post-handshake loop survived TELE-06B patch'
}
Write-Host 'TELE06B PORTAL + COMPLETION PATCH PASS'
