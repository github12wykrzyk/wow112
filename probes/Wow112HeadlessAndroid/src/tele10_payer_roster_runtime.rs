use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

static TELE10_PAYER_ROSTER: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
static TELE10_PAYMENT_ATTEMPTED: AtomicBool = AtomicBool::new(false);

fn tele10_payer_roster() -> &'static Mutex<HashMap<String, u64>> {
    TELE10_PAYER_ROSTER.get_or_init(|| Mutex::new(HashMap::new()))
}

fn tele10_payer_observe_packet(opcode: u16, payload: &[u8]) {
    const SMSG_GROUP_LIST_OPCODE_TELE10: u16 = 0x007D;
    if opcode != SMSG_GROUP_LIST_OPCODE_TELE10 {
        return;
    }
    let Ok(ServerOpcodeMessage::SMSG_GROUP_LIST(group)) = parse_raw_server_message(opcode, payload)
    else {
        return;
    };
    let Ok(mut roster) = tele10_payer_roster().lock() else {
        return;
    };
    for member in &group.members {
        roster.insert(member.name.to_ascii_lowercase(), member.guid.guid());
    }
    println!("[TELE10-PAYER] roster_cache members={}", roster.len());
}

fn tele10_cached_guid(name: &str) -> Option<u64> {
    tele10_payer_roster()
        .lock()
        .ok()
        .and_then(|roster| roster.get(&name.to_ascii_lowercase()).copied())
        .filter(|guid| *guid != 0)
}
