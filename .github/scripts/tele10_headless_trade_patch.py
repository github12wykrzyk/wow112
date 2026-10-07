from pathlib import Path

ACCEPTOR = Path('probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs')
RECEIVER = Path('probes/Wow112HeadlessAndroid/src/tele10_trade_receiver_runtime.rs')

s = ACCEPTOR.read_text(encoding='utf-8')

marker = 'tele10_cache_named_guid(&pay_target, summoner_guid, "summon_request");'
if marker not in s:
    old = '''                            let summoner_guid =
                                u64::from_le_bytes(payload[0..8].try_into().unwrap());
                            let area ='''
    new = '''                            let summoner_guid =
                                u64::from_le_bytes(payload[0..8].try_into().unwrap());
                            if let Some(pay_target) = tele10_pay_target() {
                                tele10_cache_named_guid(
                                    &pay_target,
                                    summoner_guid,
                                    "summon_request",
                                );
                            }
                            let area ='''
    if old not in s:
        raise SystemExit('PATCH_ANCHOR_MISSING authoritative summon-request guid')
    s = s.replace(old, new, 1)

same_old = '''                            publish_runner_state(
                                "PASS_TELEPORT_COMPLETE",
                                &format!(
                                    "same-map 0x00C7 server+client counter={counter} ack_bytes={}",
                                    ack.len()
                                ),
                            );'''
same_new = '''                            tele10_publish_teleport_checkpoint(&format!(
                                "same-map 0x00C7 server+client counter={counter} ack_bytes={}",
                                ack.len()
                            ));'''
if same_new not in s:
    if same_old not in s:
        raise SystemExit('PATCH_ANCHOR_MISSING same-map payment checkpoint')
    s = s.replace(same_old, same_new, 1)

far_old = '''                            publish_runner_state(
                                "PASS_TELEPORT_COMPLETE",
                                &format!("SMSG_NEW_WORLD opcode=0x003E bytes={} + MSG_MOVE_WORLDPORT_ACK opcode=0x00DC write=success", payload.len()),
                            );'''
far_new = '''                            tele10_publish_teleport_checkpoint(&format!(
                                "SMSG_NEW_WORLD opcode=0x003E bytes={} + MSG_MOVE_WORLDPORT_ACK opcode=0x00DC write=success",
                                payload.len()
                            ));'''
if far_new not in s:
    if far_old not in s:
        raise SystemExit('PATCH_ANCHOR_MISSING far payment checkpoint')
    s = s.replace(far_old, far_new, 1)

ACCEPTOR.write_text(s, encoding='utf-8')

r = RECEIVER.read_text(encoding='utf-8')
path_old = '''fn tele10_ledger_path() -> std::path::PathBuf {
    std::env::var("WOW112_TELE10_LEDGER_PATH")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("tele10_payment_ledger.json"))
}'''
path_new = '''fn tele10_ledger_path() -> std::path::PathBuf {
    if let Ok(value) = std::env::var("WOW112_TELE10_LEDGER_PATH") {
        if !value.trim().is_empty() {
            return std::path::PathBuf::from(value);
        }
    }
    if let Ok(state_file) = std::env::var("WOW112_RUNNER_STATE_FILE") {
        let state_path = std::path::PathBuf::from(state_file);
        if let Some(parent) = state_path.parent() {
            return parent.join("payment_ledger.json");
        }
    }
    std::path::PathBuf::from("tele10_payment_ledger.json")
}'''
if path_new not in r:
    if path_old not in r:
        raise SystemExit('PATCH_ANCHOR_MISSING ledger evidence path')
    r = r.replace(path_old, path_new, 1)
RECEIVER.write_text(r, encoding='utf-8')

print('TELE10_HEADLESS_TRADE_SOURCE_PATCH_OK live_payment_gate=true')
