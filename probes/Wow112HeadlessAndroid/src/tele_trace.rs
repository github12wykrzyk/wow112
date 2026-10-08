// TELE-06B ritual / portal response trace.
//
// std-only on purpose: this file is `include!`d by `world_tele.rs` (so every TELE
// runtime can call it) AND compiled standalone by CI:
//     rustc --edition 2021 --test probes/Wow112HeadlessAndroid/src/tele_trace.rs
//
// It is OBSERVE-ONLY. It never writes to the socket and never changes any
// mutation guard. Its purpose is to answer, from the next LIVE logs, the
// questions the V1.3 logs could not:
//   * did the server react to CMSG_GAMEOBJ_USE at all (spell / channel / failure
//     opcodes addressed to this process after the click)?
//   * did the summoner's ritual channel stay alive after SMSG_SPELL_START?
//   * did SMSG_SUMMON_REQUEST go to somebody other than the customer?
//   * what do the SMSG_(COMPRESSED_)UPDATE_OBJECT packets that wow_world_messages
//     rejects ("Missing object TYPE") actually contain (UPDATE_TYPE_VALUES blocks)?
//
// Nothing here logs credentials, session keys or SRP material.

#[allow(dead_code)]
mod tele_trace {
    use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
    use std::sync::Mutex;

    pub const OP_UPDATE_OBJECT: u16 = 0x00A9;
    pub const OP_COMPRESSED_UPDATE_OBJECT: u16 = 0x01F6;
    pub const OP_MESSAGECHAT: u16 = 0x0096;
    pub const OP_DESTROY_OBJECT: u16 = 0x00AA;
    pub const OP_GAMEOBJECT_CUSTOM_ANIM: u16 = 0x00B3;
    pub const OP_CAST_RESULT: u16 = 0x0130;
    pub const OP_SPELL_START: u16 = 0x0131;
    pub const OP_SPELL_GO: u16 = 0x0132;
    pub const OP_SPELL_FAILURE: u16 = 0x0133;
    pub const OP_CHANNEL_START: u16 = 0x0139;
    pub const OP_CHANNEL_UPDATE: u16 = 0x013A;
    pub const OP_NOTIFICATION: u16 = 0x01CB;
    pub const OP_SPELL_FAILED_OTHER: u16 = 0x02A6;
    pub const OP_SUMMON_REQUEST: u16 = 0x02AB;

    pub const RITUAL_SPELL_ID: u32 = 698;
    pub const SUMMONING_PORTAL_ENTRY: u64 = 36727;
    /// HIGHGUID_GAMEOBJECT in the 1.12 GUID layout (high16 | entry24 | counter24).
    pub const HIGHGUID_GAMEOBJECT: u64 = 0xF110;
    /// UNIT_FIELD_CHANNEL_OBJECT low/high dword indices in the 1.12.1 field layout.
    /// Labelled as such in the log; NOT verified against this particular server.
    pub const UNIT_FIELD_CHANNEL_OBJECT_LO: u32 = 0x14;
    pub const UNIT_FIELD_CHANNEL_OBJECT_HI: u32 = 0x15;

    const MAX_LOG_LINES: u64 = 3000;
    const MAX_CHAT_LINES: u32 = 60;
    const CLICKER_OUTCOME_WINDOW_MS: u64 = 20_000;
    const SUMMARY_AFTER_CAST_MS: u64 = 40_000;
    const MAX_INFLATED_BYTES: usize = 1 << 20;

    static LINES: AtomicU64 = AtomicU64::new(0);
    static LOCAL_GUID: AtomicU64 = AtomicU64::new(0);
    static PORTAL_GUID: AtomicU64 = AtomicU64::new(0);
    static PORTAL_SEEN_MS: AtomicU64 = AtomicU64::new(0);
    static CLICK_MS: AtomicU64 = AtomicU64::new(0);
    static CAST_MS: AtomicU64 = AtomicU64::new(0);
    static EV_PARTICIPANT_SPELL: AtomicU32 = AtomicU32::new(0);
    static EV_CHANNEL: AtomicU32 = AtomicU32::new(0);
    static EV_FAILURE: AtomicU32 = AtomicU32::new(0);
    static EV_SUMMON_TO_SELF: AtomicU32 = AtomicU32::new(0);
    static EV_PORTAL_DESTROYED: AtomicU32 = AtomicU32::new(0);
    static EV_NON_UPDATE_AFTER_CLICK: AtomicU32 = AtomicU32::new(0);
    static CHAT_LINES: AtomicU32 = AtomicU32::new(0);
    static UPD_SCANNED: AtomicU32 = AtomicU32::new(0);
    static UPD_PARTIAL: AtomicU32 = AtomicU32::new(0);
    static UPD_INFLATE_FAIL: AtomicU32 = AtomicU32::new(0);
    static UPD_BAD: AtomicU32 = AtomicU32::new(0);
    static OUTCOME_DONE: AtomicBool = AtomicBool::new(false);
    static SUMMARY_DONE: AtomicBool = AtomicBool::new(false);
    static OPCODE_COUNTS: Mutex<Vec<(u16, u32)>> = Mutex::new(Vec::new());

    // ------------------------------------------------------------------ clock / log

    pub fn unix_ms() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    /// `HH:MM:SS.mmmZ` (UTC). The runner log uses local time; every trace line also
    /// carries `ts=<unix ms>` so the four process logs can be merged exactly.
    pub fn utc_hms(ms: u64) -> String {
        let s = ms / 1000;
        format!("{:02}:{:02}:{:02}.{:03}Z", (s / 3600) % 24, (s / 60) % 60, s % 60, ms % 1000)
    }

    fn stamp(now: u64) -> String {
        format!("t={} ts={}", utc_hms(now), now)
    }

    fn emit(line: String) {
        let n = LINES.fetch_add(1, Ordering::SeqCst);
        if n < MAX_LOG_LINES {
            println!("{line}");
        } else if n == MAX_LOG_LINES {
            println!("[T6B] trace line cap reached; further trace output suppressed");
        }
    }

    fn since(now: u64, mark: &AtomicU64) -> String {
        let m = mark.load(Ordering::SeqCst);
        if m == 0 {
            "-".to_string()
        } else if now >= m {
            format!("{}", now - m)
        } else {
            format!("-{}", m - now)
        }
    }

    // ------------------------------------------------------------------ small codecs

    pub fn hex(bytes: &[u8], max: usize) -> String {
        let shown = bytes.len().min(max);
        let mut out = bytes[..shown]
            .iter()
            .map(|b| format!("{b:02X}"))
            .collect::<Vec<_>>()
            .join(" ");
        if bytes.len() > shown {
            out.push_str(" ...");
        }
        out
    }

    pub fn read_packed_guid(data: &[u8], pos: &mut usize) -> Option<u64> {
        let mask = *data.get(*pos)?;
        *pos += 1;
        let mut guid = 0u64;
        for i in 0..8 {
            if mask & (1 << i) != 0 {
                let b = *data.get(*pos)?;
                *pos += 1;
                guid |= (b as u64) << (8 * i);
            }
        }
        Some(guid)
    }

    fn rd_u32(data: &[u8], pos: usize) -> Option<u32> {
        let s = data.get(pos..pos.checked_add(4)?)?;
        Some(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }

    fn rd_u64(data: &[u8], pos: usize) -> Option<u64> {
        let s = data.get(pos..pos.checked_add(8)?)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(s);
        Some(u64::from_le_bytes(a))
    }

    #[derive(Debug, PartialEq, Eq, Clone, Copy)]
    pub struct SpellHeader {
        pub caster_item: u64,
        pub caster: u64,
        pub spell: u32,
        pub flags: u16,
    }

    /// SMSG_SPELL_START / SMSG_SPELL_GO common prefix (1.12): packed guid (cast item),
    /// packed guid (caster), u32 spell, u16 cast flags.
    pub fn decode_spell_header(payload: &[u8]) -> Option<SpellHeader> {
        let mut p = 0usize;
        let caster_item = read_packed_guid(payload, &mut p)?;
        let caster = read_packed_guid(payload, &mut p)?;
        let spell = rd_u32(payload, p)?;
        p += 4;
        let s = payload.get(p..p + 2)?;
        let flags = u16::from_le_bytes([s[0], s[1]]);
        Some(SpellHeader { caster_item, caster, spell, flags })
    }

    /// Printable-ASCII runs (>= `min_len`) joined with " | ". Used for chat and
    /// notification payloads so server-side refusal texts become visible.
    pub fn ascii_runs(payload: &[u8], min_len: usize, max_total: usize) -> String {
        let mut runs: Vec<String> = Vec::new();
        let mut cur = String::new();
        for &b in payload {
            if (0x20..0x7F).contains(&b) {
                cur.push(b as char);
            } else {
                if cur.len() >= min_len {
                    runs.push(std::mem::take(&mut cur));
                } else {
                    cur.clear();
                }
            }
        }
        if cur.len() >= min_len {
            runs.push(cur);
        }
        let mut joined = runs.join(" | ");
        if joined.len() > max_total {
            joined.truncate(max_total);
            joined.push_str("...");
        }
        joined
    }

    pub fn opcode_name(op: u16) -> &'static str {
        match op {
            OP_MESSAGECHAT => "SMSG_MESSAGECHAT",
            OP_DESTROY_OBJECT => "SMSG_DESTROY_OBJECT",
            OP_GAMEOBJECT_CUSTOM_ANIM => "SMSG_GAMEOBJECT_CUSTOM_ANIM",
            OP_CAST_RESULT => "SMSG_CAST_RESULT",
            OP_SPELL_START => "SMSG_SPELL_START",
            OP_SPELL_GO => "SMSG_SPELL_GO",
            OP_SPELL_FAILURE => "SMSG_SPELL_FAILURE",
            OP_CHANNEL_START => "MSG_CHANNEL_START",
            OP_CHANNEL_UPDATE => "MSG_CHANNEL_UPDATE",
            OP_NOTIFICATION => "SMSG_NOTIFICATION",
            OP_SPELL_FAILED_OTHER => "SMSG_SPELL_FAILED_OTHER",
            OP_SUMMON_REQUEST => "SMSG_SUMMON_REQUEST",
            _ => "",
        }
    }

    /// Truncate to at most `max` chars on a char boundary (used for Debug dumps).
    pub fn truncate_chars(s: &str, max: usize) -> String {
        let mut it = s.chars();
        let head: String = it.by_ref().take(max).collect();
        if it.next().is_some() {
            format!("{head}...[truncated]")
        } else {
            head
        }
    }

    pub fn is_ritual_go_guid(guid: u64) -> bool {
        (guid >> 48) == HIGHGUID_GAMEOBJECT && ((guid >> 24) & 0x00FF_FFFF) == SUMMONING_PORTAL_ENTRY
    }

    // ------------------------------------------------------------------ marks (called by runtimes)

    pub fn set_local_guid(guid: u64) {
        LOCAL_GUID.store(guid, Ordering::SeqCst);
        emit(format!("[T6B] local_guid=0x{guid:016X} {}", stamp(unix_ms())));
    }

    pub fn mark_portal_observed(guid: u64) {
        let now = unix_ms();
        PORTAL_GUID.store(guid, Ordering::SeqCst);
        let _ = PORTAL_SEEN_MS.compare_exchange(0, now, Ordering::SeqCst, Ordering::SeqCst);
        emit(format!(
            "[T6B-PORTAL-SEEN] guid=0x{guid:016X} entry_from_guid={} {} since_cast_ms={}",
            (guid >> 24) & 0x00FF_FFFF,
            stamp(now),
            since(now, &CAST_MS)
        ));
    }

    /// Called immediately BEFORE the single CMSG_GAMEOBJ_USE write (guard already committed).
    pub fn mark_click_commit(guid: u64, outgoing_payload: &[u8]) {
        let now = unix_ms();
        let _ = CLICK_MS.compare_exchange(0, now, Ordering::SeqCst, Ordering::SeqCst);
        emit(format!(
            "[T6B-CLICK-TX] stage=before_write guid=0x{guid:016X} opcode=0x00B1 payload_len={} payload_hex={} {} since_portal_seen_ms={} since_cast_ms={}",
            outgoing_payload.len(),
            hex(outgoing_payload, 16),
            stamp(now),
            since(now, &PORTAL_SEEN_MS),
            since(now, &CAST_MS)
        ));
    }

    pub fn mark_click_write_done(guid: u64) {
        let now = unix_ms();
        emit(format!(
            "[T6B-CLICK-TX] stage=write_returned_ok guid=0x{guid:016X} {} since_click_ms={} (socket write only; NOT a server acknowledgement)",
            stamp(now),
            since(now, &CLICK_MS)
        ));
    }

    // ------------------------------------------------------------------ per-packet trace

    fn count_opcode(op: u16) -> bool {
        let mut first = false;
        if let Ok(mut v) = OPCODE_COUNTS.lock() {
            if let Some(e) = v.iter_mut().find(|e| e.0 == op) {
                e.1 += 1;
            } else {
                v.push((op, 1));
                first = true;
            }
        }
        first
    }

    fn evidence(role: &str, kind: &str, detail: &str, now: u64) {
        emit(format!(
            "[TELE-06B-PORTAL-EVIDENCE] role={role} kind={kind} {detail} {} since_click_ms={} since_cast_ms={}",
            stamp(now),
            since(now, &CLICK_MS),
            since(now, &CAST_MS)
        ));
    }

    /// Trace one decrypted server packet. `role` is a free-form label for the log.
    /// Pong packets must be filtered out by the caller. Observe-only and panic-proof:
    /// a tracing bug must never take down a live ritual participant.
    pub fn trace_packet(role: &str, opcode: u16, payload: &[u8]) {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| trace_packet_inner(role, opcode, payload)));
    }

    fn trace_packet_inner(role: &str, opcode: u16, payload: &[u8]) {
        let now = unix_ms();
        if opcode == OP_UPDATE_OBJECT || opcode == OP_COMPRESSED_UPDATE_OBJECT {
            trace_update(role, opcode, payload, now);
            return;
        }
        let click = CLICK_MS.load(Ordering::SeqCst);
        let after_click = click != 0 && now >= click;
        if after_click {
            EV_NON_UPDATE_AFTER_CLICK.fetch_add(1, Ordering::SeqCst);
        }
        let first_seen = count_opcode(opcode);
        let name = opcode_name(opcode);
        if name.is_empty() && !first_seen {
            return;
        }
        let local = LOCAL_GUID.load(Ordering::SeqCst);
        let mut decoded = String::new();

        match opcode {
            OP_SPELL_START | OP_SPELL_GO => {
                if let Some(h) = decode_spell_header(payload) {
                    decoded = format!(
                        "caster=0x{:016X} cast_item=0x{:016X} spell={} flags=0x{:04X} caster_is_local={}",
                        h.caster,
                        h.caster_item,
                        h.spell,
                        h.flags,
                        local != 0 && h.caster == local
                    );
                    if opcode == OP_SPELL_START && h.spell == RITUAL_SPELL_ID {
                        let _ = CAST_MS.compare_exchange(0, now, Ordering::SeqCst, Ordering::SeqCst);
                    }
                    if after_click && local != 0 && h.caster == local {
                        EV_PARTICIPANT_SPELL.fetch_add(1, Ordering::SeqCst);
                        evidence(
                            role,
                            if opcode == OP_SPELL_START { "participant_spell_start" } else { "participant_spell_go" },
                            &format!("spell={}", h.spell),
                            now,
                        );
                    }
                } else {
                    decoded = "spell header undecodable".to_string();
                }
            }
            OP_CAST_RESULT => {
                if payload.len() >= 6 {
                    let spell = rd_u32(payload, 0).unwrap_or(0);
                    decoded = format!("spell={spell} status={} reason=0x{:02X}", payload[4], payload[5]);
                }
                if after_click {
                    EV_FAILURE.fetch_add(1, Ordering::SeqCst);
                    evidence(role, "cast_result_after_click", &decoded, now);
                }
            }
            OP_SPELL_FAILURE | OP_SPELL_FAILED_OTHER => {
                // 1.12 layout assumed: u64 guid, u32 spell [, u8 reason]. Raw hex is always logged.
                if let (Some(g), Some(s)) = (rd_u64(payload, 0), rd_u32(payload, 8)) {
                    decoded = format!(
                        "guid=0x{g:016X} spell={s} guid_is_local={} (layout assumed)",
                        local != 0 && g == local
                    );
                    if after_click && local != 0 && g == local {
                        EV_FAILURE.fetch_add(1, Ordering::SeqCst);
                        evidence(role, "spell_failure_for_local_after_click", &decoded, now);
                    }
                }
            }
            OP_CHANNEL_START => {
                if payload.len() == 8 {
                    decoded = format!(
                        "spell={} duration_ms={} (layout assumed)",
                        rd_u32(payload, 0).unwrap_or(0),
                        rd_u32(payload, 4).unwrap_or(0)
                    );
                }
                if after_click {
                    EV_CHANNEL.fetch_add(1, Ordering::SeqCst);
                    evidence(role, "channel_start_after_click", &decoded, now);
                }
            }
            OP_CHANNEL_UPDATE => {
                if payload.len() == 4 {
                    decoded = format!("remaining_ms={}", rd_u32(payload, 0).unwrap_or(0));
                }
            }
            OP_SUMMON_REQUEST => {
                if payload.len() == 16 {
                    decoded = format!(
                        "summoner=0x{:016X} area={} auto_decline_ms={}",
                        rd_u64(payload, 0).unwrap_or(0),
                        rd_u32(payload, 8).unwrap_or(0),
                        rd_u32(payload, 12).unwrap_or(0)
                    );
                }
                if !role.eq_ignore_ascii_case("customer") {
                    EV_SUMMON_TO_SELF.fetch_add(1, Ordering::SeqCst);
                    evidence(role, "summon_request_addressed_to_non_customer", &decoded, now);
                }
            }
            OP_DESTROY_OBJECT => {
                if let Some(g) = rd_u64(payload, 0) {
                    decoded = format!("guid=0x{g:016X}");
                    if g == PORTAL_GUID.load(Ordering::SeqCst) && g != 0 {
                        EV_PORTAL_DESTROYED.fetch_add(1, Ordering::SeqCst);
                        evidence(role, "portal_destroyed", &decoded, now);
                    }
                }
            }
            OP_GAMEOBJECT_CUSTOM_ANIM => {
                if let (Some(g), Some(a)) = (rd_u64(payload, 0), rd_u32(payload, 8)) {
                    decoded = format!("guid=0x{g:016X} anim={a}");
                }
            }
            OP_MESSAGECHAT | OP_NOTIFICATION => {
                if CHAT_LINES.fetch_add(1, Ordering::SeqCst) >= MAX_CHAT_LINES {
                    return;
                }
                decoded = format!("text=[{}]", ascii_runs(payload, 4, 200));
            }
            _ => {}
        }

        emit(format!(
            "[T6B-RX] role={role} op=0x{opcode:04X} name={} len={} {} since_click_ms={} since_cast_ms={} {} hex={}",
            if name.is_empty() { "unnamed(first_seen)" } else { name },
            payload.len(),
            stamp(now),
            since(now, &CLICK_MS),
            since(now, &CAST_MS),
            decoded,
            hex(payload, 32)
        ));
    }

    // ------------------------------------------------------------------ update-object scanner

    #[derive(Debug, PartialEq, Eq, Clone)]
    pub struct ValuesBlock {
        pub guid: u64,
        pub fields: Vec<(u32, u32)>,
    }

    #[derive(Debug, PartialEq, Eq, Clone, Default)]
    pub struct UpdateScan {
        pub declared: u32,
        pub values: Vec<ValuesBlock>,
        pub out_of_range: u32,
        pub stopped: Option<&'static str>,
    }

    /// Walks a (decompressed) 1.12 SMSG_UPDATE_OBJECT body: u32 count, u8 has_transport,
    /// then blocks. UPDATE_TYPE_VALUES (0), OUT_OF_RANGE (4) and NEAR (5) blocks are fully
    /// decoded; MOVEMENT/CREATE blocks need the movement-block grammar, so the scan stops
    /// there (reported in `stopped`). These Values blocks are precisely what
    /// wow_world_messages rejects with "Missing object TYPE".
    pub fn scan_update_blocks(data: &[u8]) -> Result<UpdateScan, &'static str> {
        let declared = rd_u32(data, 0).ok_or("short header")?;
        let mut p = 5usize; // u32 count + u8 has_transport
        if data.len() < p {
            return Err("short header");
        }
        let mut scan = UpdateScan { declared, ..Default::default() };
        for _ in 0..declared.min(4096) {
            let t = match data.get(p) {
                Some(t) => *t,
                None => {
                    scan.stopped = Some("truncated before block type");
                    return Ok(scan);
                }
            };
            p += 1;
            match t {
                0 => {
                    let guid = read_packed_guid(data, &mut p).ok_or("truncated values guid")?;
                    let nblocks = *data.get(p).ok_or("truncated mask count")? as usize;
                    p += 1;
                    if nblocks == 0 || nblocks > 32 {
                        return Err("implausible mask block count");
                    }
                    let mut masks = Vec::with_capacity(nblocks);
                    for _ in 0..nblocks {
                        masks.push(rd_u32(data, p).ok_or("truncated mask")?);
                        p += 4;
                    }
                    let mut fields = Vec::new();
                    for (bi, m) in masks.iter().enumerate() {
                        for bit in 0..32u32 {
                            if m & (1u32 << bit) != 0 {
                                let v = rd_u32(data, p).ok_or("truncated field value")?;
                                p += 4;
                                fields.push((bi as u32 * 32 + bit, v));
                            }
                        }
                    }
                    scan.values.push(ValuesBlock { guid, fields });
                }
                4 | 5 => {
                    let n = rd_u32(data, p).ok_or("truncated out-of-range count")?;
                    p += 4;
                    if n > 4096 {
                        return Err("implausible out-of-range count");
                    }
                    for _ in 0..n {
                        read_packed_guid(data, &mut p).ok_or("truncated out-of-range guid")?;
                    }
                    scan.out_of_range += n;
                }
                1 | 2 | 3 => {
                    scan.stopped = Some("movement/create block (scan stops; library handles creates)");
                    return Ok(scan);
                }
                _ => {
                    scan.stopped = Some("unknown update type");
                    return Ok(scan);
                }
            }
        }
        Ok(scan)
    }

    fn trace_update(role: &str, opcode: u16, payload: &[u8], now: u64) {
        let body: Vec<u8>;
        let data: &[u8] = if opcode == OP_COMPRESSED_UPDATE_OBJECT {
            let declared = match rd_u32(payload, 0) {
                Some(v) => v as usize,
                None => {
                    UPD_BAD.fetch_add(1, Ordering::SeqCst);
                    return;
                }
            };
            match zlib_inflate(&payload[4..], MAX_INFLATED_BYTES) {
                Ok(v) => {
                    if v.len() != declared {
                        emit(format!(
                            "[T6B-UPDATE] role={role} inflate length mismatch declared={declared} actual={} {}",
                            v.len(),
                            stamp(now)
                        ));
                    }
                    body = v;
                    &body
                }
                Err(e) => {
                    UPD_INFLATE_FAIL.fetch_add(1, Ordering::SeqCst);
                    emit(format!("[T6B-UPDATE] role={role} inflate failed: {e} compressed_len={} {}", payload.len(), stamp(now)));
                    return;
                }
            }
        } else {
            payload
        };
        let scan = match scan_update_blocks(data) {
            Ok(s) => s,
            Err(e) => {
                UPD_BAD.fetch_add(1, Ordering::SeqCst);
                emit(format!("[T6B-UPDATE] role={role} scan error: {e} len={} {}", data.len(), stamp(now)));
                return;
            }
        };
        UPD_SCANNED.fetch_add(1, Ordering::SeqCst);
        if scan.stopped.is_some() {
            UPD_PARTIAL.fetch_add(1, Ordering::SeqCst);
        }
        let local = LOCAL_GUID.load(Ordering::SeqCst);
        let click = CLICK_MS.load(Ordering::SeqCst);
        let in_click_window = click != 0 && now >= click && now - click <= CLICKER_OUTCOME_WINDOW_MS;
        for b in &scan.values {
            let lo = b.fields.iter().find(|f| f.0 == UNIT_FIELD_CHANNEL_OBJECT_LO).map(|f| f.1);
            let hi = b.fields.iter().find(|f| f.0 == UNIT_FIELD_CHANNEL_OBJECT_HI).map(|f| f.1);
            let is_local = local != 0 && b.guid == local;
            let is_go = is_ritual_go_guid(b.guid);
            if lo.is_some() || hi.is_some() {
                let chan = (hi.unwrap_or(0) as u64) << 32 | lo.unwrap_or(0) as u64;
                emit(format!(
                    "[T6B-UPDATE-VALUES] role={role} kind=UNIT_FIELD_CHANNEL_OBJECT(1.12.1 idx 0x14/0x15) guid=0x{:016X} guid_is_local={is_local} channel_object=0x{chan:016X} {} since_click_ms={} since_cast_ms={}",
                    b.guid,
                    stamp(now),
                    since(now, &CLICK_MS),
                    since(now, &CAST_MS)
                ));
            }
            if is_go || (is_local && in_click_window) {
                let fields = b
                    .fields
                    .iter()
                    .map(|(i, v)| format!("0x{i:02X}=0x{v:08X}"))
                    .collect::<Vec<_>>()
                    .join(",");
                emit(format!(
                    "[T6B-UPDATE-VALUES] role={role} kind={} guid=0x{:016X} fields=[{fields}] {} since_click_ms={} since_cast_ms={}",
                    if is_go { "ritual_go_values" } else { "local_player_values_after_click" },
                    b.guid,
                    stamp(now),
                    since(now, &CLICK_MS),
                    since(now, &CAST_MS)
                ));
            }
        }
    }

    // ------------------------------------------------------------------ outcome / summary

    fn opcode_counts_text() -> String {
        match OPCODE_COUNTS.lock() {
            Ok(v) => v
                .iter()
                .map(|(op, n)| format!("0x{op:04X}:{n}"))
                .collect::<Vec<_>>()
                .join(","),
            Err(_) => "unavailable".to_string(),
        }
    }

    fn update_stats_text() -> String {
        format!(
            "scanned={} partial_stop_at_create={} inflate_fail={} bad={}",
            UPD_SCANNED.load(Ordering::SeqCst),
            UPD_PARTIAL.load(Ordering::SeqCst),
            UPD_INFLATE_FAIL.load(Ordering::SeqCst),
            UPD_BAD.load(Ordering::SeqCst)
        )
    }

    /// Classifies what was observed after the single click. Deliberately conservative:
    /// absence of a transition is reported as UNCONFIRMED, never as success or failure.
    pub fn classify_outcome(summon_to_other: u32, failures: u32, participant_spell: u32, channel: u32) -> &'static str {
        if summon_to_other > 0 {
            "SUMMON_REQUEST_ADDRESSED_TO_THIS_CLICKER"
        } else if failures > 0 && participant_spell == 0 && channel == 0 {
            "SERVER_FAILURE_OBSERVED_AFTER_CLICK"
        } else if participant_spell > 0 || channel > 0 {
            "SERVER_TRANSITION_OBSERVED_AFTER_CLICK"
        } else {
            "NO_SERVER_TRANSITION_OBSERVED_UNCONFIRMED"
        }
    }

    /// Call once per loop iteration (the loops already wake every second).
    pub fn poll_outcome(role: &str) {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| poll_outcome_inner(role)));
    }

    fn poll_outcome_inner(role: &str) {
        let now = unix_ms();
        let click = CLICK_MS.load(Ordering::SeqCst);
        if click != 0
            && now >= click + CLICKER_OUTCOME_WINDOW_MS
            && OUTCOME_DONE
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
        {
            let state = classify_outcome(
                EV_SUMMON_TO_SELF.load(Ordering::SeqCst),
                EV_FAILURE.load(Ordering::SeqCst),
                EV_PARTICIPANT_SPELL.load(Ordering::SeqCst),
                EV_CHANNEL.load(Ordering::SeqCst),
            );
            emit(format!(
                "[TELE-06B-PORTAL-OUTCOME] role={role} state={state} window_ms={CLICKER_OUTCOME_WINDOW_MS} participant_spell={} channel_start={} failure={} summon_request_to_self={} portal_destroyed={} non_update_packets_after_click={} {} since_click_ms={}",
                EV_PARTICIPANT_SPELL.load(Ordering::SeqCst),
                EV_CHANNEL.load(Ordering::SeqCst),
                EV_FAILURE.load(Ordering::SeqCst),
                EV_SUMMON_TO_SELF.load(Ordering::SeqCst),
                EV_PORTAL_DESTROYED.load(Ordering::SeqCst),
                EV_NON_UPDATE_AFTER_CLICK.load(Ordering::SeqCst),
                stamp(now),
                since(now, &CLICK_MS)
            ));
        }
        let cast = CAST_MS.load(Ordering::SeqCst);
        if cast != 0
            && now >= cast + SUMMARY_AFTER_CAST_MS
            && SUMMARY_DONE
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
        {
            emit(format!(
                "[T6B-SUMMARY] role={role} {} since_cast_ms={} opcodes_seen=[{}] updates=[{}] portal_guid=0x{:016X} portal_destroyed={} summon_request_to_non_customer={}",
                stamp(now),
                since(now, &CAST_MS),
                opcode_counts_text(),
                update_stats_text(),
                PORTAL_GUID.load(Ordering::SeqCst),
                EV_PORTAL_DESTROYED.load(Ordering::SeqCst),
                EV_SUMMON_TO_SELF.load(Ordering::SeqCst)
            ));
        }
    }

    // ------------------------------------------------------------------ zlib (RFC1950/1951) inflate
    //
    // Minimal, allocation-bounded inflate (structure follows zlib's `puff.c`). Needed
    // because SMSG_COMPRESSED_UPDATE_OBJECT bodies are zlib streams and the library
    // gives us no access to the decompressed bytes when it rejects them.

    struct Bits<'a> {
        data: &'a [u8],
        pos: usize,
        buf: u32,
        cnt: u32,
    }

    impl<'a> Bits<'a> {
        fn take(&mut self, need: u32) -> Result<u32, &'static str> {
            let mut val = self.buf;
            while self.cnt < need {
                let b = *self.data.get(self.pos).ok_or("unexpected end of deflate data")?;
                self.pos += 1;
                val |= (b as u32) << self.cnt;
                self.cnt += 8;
            }
            self.buf = val >> need;
            self.cnt -= need;
            Ok(val & ((1u32 << need) - 1))
        }
    }

    struct Huff {
        count: [u16; 16],
        symbol: Vec<u16>,
    }

    fn huff_build(lengths: &[u8]) -> Result<Huff, &'static str> {
        let mut h = Huff { count: [0; 16], symbol: vec![0; lengths.len()] };
        for &l in lengths {
            h.count[l as usize] += 1;
        }
        let mut left: i32 = 1;
        for len in 1..16 {
            left <<= 1;
            left -= h.count[len] as i32;
            if left < 0 {
                return Err("over-subscribed huffman code");
            }
        }
        let mut offs = [0u16; 16];
        for len in 1..15 {
            offs[len + 1] = offs[len] + h.count[len];
        }
        for (sym, &l) in lengths.iter().enumerate() {
            if l != 0 {
                h.symbol[offs[l as usize] as usize] = sym as u16;
                offs[l as usize] += 1;
            }
        }
        Ok(h)
    }

    fn huff_decode(bits: &mut Bits, h: &Huff) -> Result<u16, &'static str> {
        let mut code: i32 = 0;
        let mut first: i32 = 0;
        let mut index: i32 = 0;
        for len in 1..16 {
            code |= bits.take(1)? as i32;
            let count = h.count[len] as i32;
            if code - count < first {
                return h.symbol.get((index + (code - first)) as usize).copied().ok_or("bad huffman symbol index");
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        Err("invalid huffman code")
    }

    const LEN_BASE: [u16; 29] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ];
    const LEN_EXTRA: [u8; 29] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ];
    const DIST_BASE: [u16; 30] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    ];
    const DIST_EXTRA: [u8; 30] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ];

    fn inflate_codes(
        bits: &mut Bits,
        out: &mut Vec<u8>,
        lit: &Huff,
        dist: &Huff,
        max_out: usize,
    ) -> Result<(), &'static str> {
        loop {
            let sym = huff_decode(bits, lit)? as usize;
            if sym < 256 {
                if out.len() >= max_out {
                    return Err("inflate output limit exceeded");
                }
                out.push(sym as u8);
            } else if sym == 256 {
                return Ok(());
            } else {
                let s = sym - 257;
                if s >= 29 {
                    return Err("invalid length symbol");
                }
                let len = LEN_BASE[s] as usize + bits.take(LEN_EXTRA[s] as u32)? as usize;
                let ds = huff_decode(bits, dist)? as usize;
                if ds >= 30 {
                    return Err("invalid distance symbol");
                }
                let d = DIST_BASE[ds] as usize + bits.take(DIST_EXTRA[ds] as u32)? as usize;
                if d > out.len() {
                    return Err("distance too far back");
                }
                if out.len() + len > max_out {
                    return Err("inflate output limit exceeded");
                }
                for _ in 0..len {
                    let b = out[out.len() - d];
                    out.push(b);
                }
            }
        }
    }

    fn inflate_raw(data: &[u8], max_out: usize) -> Result<(Vec<u8>, usize), &'static str> {
        let mut bits = Bits { data, pos: 0, buf: 0, cnt: 0 };
        let mut out: Vec<u8> = Vec::new();
        loop {
            let last = bits.take(1)?;
            let typ = bits.take(2)?;
            match typ {
                0 => {
                    bits.buf = 0;
                    bits.cnt = 0;
                    let hdr = data.get(bits.pos..bits.pos + 4).ok_or("truncated stored header")?;
                    let len = u16::from_le_bytes([hdr[0], hdr[1]]);
                    let nlen = u16::from_le_bytes([hdr[2], hdr[3]]);
                    if len != !nlen {
                        return Err("stored block length check failed");
                    }
                    bits.pos += 4;
                    let end = bits.pos + len as usize;
                    let chunk = data.get(bits.pos..end).ok_or("truncated stored block")?;
                    if out.len() + chunk.len() > max_out {
                        return Err("inflate output limit exceeded");
                    }
                    out.extend_from_slice(chunk);
                    bits.pos = end;
                }
                1 => {
                    let mut l = [0u8; 288];
                    for (i, v) in l.iter_mut().enumerate() {
                        *v = if i < 144 { 8 } else if i < 256 { 9 } else if i < 280 { 7 } else { 8 };
                    }
                    let lit = huff_build(&l)?;
                    let dist = huff_build(&[5u8; 30])?;
                    inflate_codes(&mut bits, &mut out, &lit, &dist, max_out)?;
                }
                2 => {
                    let nlen = bits.take(5)? as usize + 257;
                    let ndist = bits.take(5)? as usize + 1;
                    let ncode = bits.take(4)? as usize + 4;
                    if nlen > 286 || ndist > 30 {
                        return Err("bad dynamic block counts");
                    }
                    const ORDER: [usize; 19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
                    let mut lengths = [0u8; 320];
                    for &o in ORDER.iter().take(ncode) {
                        lengths[o] = bits.take(3)? as u8;
                    }
                    let lencode = huff_build(&lengths[..19])?;
                    let mut idx = 0usize;
                    let mut table = [0u8; 320];
                    while idx < nlen + ndist {
                        let sym = huff_decode(&mut bits, &lencode)?;
                        if sym < 16 {
                            table[idx] = sym as u8;
                            idx += 1;
                        } else {
                            let (prev, rep) = match sym {
                                16 => {
                                    if idx == 0 {
                                        return Err("repeat with no previous length");
                                    }
                                    (table[idx - 1], 3 + bits.take(2)? as usize)
                                }
                                17 => (0, 3 + bits.take(3)? as usize),
                                _ => (0, 11 + bits.take(7)? as usize),
                            };
                            if idx + rep > nlen + ndist {
                                return Err("too many code lengths");
                            }
                            for _ in 0..rep {
                                table[idx] = prev;
                                idx += 1;
                            }
                        }
                    }
                    if table[256] == 0 {
                        return Err("missing end-of-block code");
                    }
                    let lit = huff_build(&table[..nlen])?;
                    let dist = huff_build(&table[nlen..nlen + ndist])?;
                    inflate_codes(&mut bits, &mut out, &lit, &dist, max_out)?;
                }
                _ => return Err("reserved deflate block type"),
            }
            if last == 1 {
                break;
            }
        }
        Ok((out, bits.pos))
    }

    pub fn adler32(data: &[u8]) -> u32 {
        let (mut a, mut b) = (1u32, 0u32);
        for &x in data {
            a = (a + x as u32) % 65521;
            b = (b + a) % 65521;
        }
        (b << 16) | a
    }

    /// Inflate an RFC1950 zlib stream (header + deflate + adler32 trailer, verified).
    pub fn zlib_inflate(data: &[u8], max_out: usize) -> Result<Vec<u8>, &'static str> {
        if data.len() < 6 {
            return Err("zlib stream too short");
        }
        let cmf = data[0] as u32;
        let flg = data[1] as u32;
        if cmf & 0x0F != 8 || (cmf * 256 + flg) % 31 != 0 {
            return Err("bad zlib header");
        }
        if flg & 0x20 != 0 {
            return Err("zlib preset dictionary unsupported");
        }
        let (out, used) = inflate_raw(&data[2..], max_out)?;
        let trailer = data.get(2 + used..2 + used + 4).ok_or("missing adler32 trailer")?;
        let want = u32::from_be_bytes([trailer[0], trailer[1], trailer[2], trailer[3]]);
        if adler32(&out) != want {
            return Err("adler32 mismatch");
        }
        Ok(out)
    }

    // ------------------------------------------------------------------ tests

    #[cfg(test)]
    mod tests {
        use super::*;

        const STORED: [u8; 31] = [0x78, 0x01, 0x01, 0x14, 0x00, 0xeb, 0xff, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x3a, 0x98, 0x05, 0xd3];
        const FIXED: [u8; 16] = [0x78, 0x01, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x27, 0x01, 0x68, 0x03, 0x08, 0xb1];
        const DYNAMIC: [u8; 166] = [0x78, 0xda, 0x7d, 0x53, 0xed, 0x0a, 0x80, 0x20, 0x0c, 0x7c, 0x95, 0x5e, 0x4d, 0x42, 0x28, 0x32, 0x8d, 0x95, 0xf4, 0xfa, 0x85, 0x6e, 0xe1, 0x8e, 0xad, 0x3f, 0x8a, 0xfb, 0xb8, 0xdd, 0x6d, 0x93, 0xd6, 0xab, 0x86, 0x34, 0x1d, 0x85, 0xae, 0xf7, 0x9a, 0x97, 0x90, 0x73, 0x4c, 0xd3, 0x79, 0xc4, 0xf4, 0x9e, 0x75, 0xdf, 0x4b, 0x96, 0xeb, 0x0e, 0x94, 0xca, 0xbc, 0xc9, 0x93, 0x7a, 0x22, 0x58, 0xe5, 0xc9, 0x78, 0x1a, 0x41, 0xd0, 0xbf, 0x2a, 0xdd, 0xac, 0x63, 0x05, 0x01, 0x82, 0xa0, 0x8e, 0xe4, 0x74, 0x9e, 0xed, 0x74, 0x98, 0x38, 0x78, 0x76, 0x51, 0xb6, 0xb2, 0x36, 0x49, 0x61, 0xab, 0x53, 0x00, 0x1b, 0xd1, 0xc8, 0xd8, 0xf0, 0x66, 0x0c, 0xe7, 0xa3, 0xce, 0x71, 0x02, 0xff, 0x4d, 0xd6, 0x43, 0x43, 0xbd, 0xa0, 0xc5, 0x71, 0x93, 0x5a, 0x03, 0xd5, 0x5d, 0x5b, 0x0a, 0xa8, 0x06, 0xb8, 0x9e, 0x09, 0x46, 0x50, 0xe1, 0xcc, 0x5b, 0x77, 0x05, 0x24, 0xc2, 0x10, 0xcd, 0x26, 0x01, 0x43, 0xc5, 0xc8, 0x61, 0xed, 0xec, 0x88, 0xde, 0x74, 0xf8, 0x1b, 0xc6, 0x0f, 0x19, 0x3d, 0x63, 0xd9, 0x07, 0xe6, 0x67, 0x4c, 0xc7];
        const PKT: [u8; 46] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xdf, 0x8a, 0x23, 0x4d, 0x77, 0x8f, 0x10, 0xf1, 0x01, 0x00, 0x06, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x0f, 0xb2, 0x7f, 0x9f, 0x3b, 0x01, 0x00, 0x00, 0x30, 0x00, 0x8a, 0x23, 0x4d, 0x00, 0x8f, 0x00, 0x10, 0xf1];
        const PKT_COMPRESSED: [u8; 50] = [0x2e, 0x00, 0x00, 0x00, 0x78, 0x9c, 0x63, 0x62, 0x00, 0x81, 0xfb, 0x5d, 0xca, 0xbe, 0xe5, 0xfd, 0x02, 0x1f, 0x19, 0x19, 0xd8, 0x18, 0x18, 0x18, 0x81, 0x02, 0x4c, 0x20, 0x51, 0xfe, 0x4d, 0xf5, 0xf3, 0xad, 0x81, 0x3c, 0x03, 0x06, 0xa0, 0x34, 0x43, 0x3f, 0x83, 0xc0, 0x47, 0x00, 0xbc, 0xfa, 0x08, 0xc2];

        fn packed(g: u64) -> Vec<u8> {
            let b = g.to_le_bytes();
            let mut mask = 0u8;
            let mut out = vec![0u8];
            for (i, x) in b.iter().enumerate() {
                if *x != 0 {
                    mask |= 1 << i;
                    out.push(*x);
                }
            }
            out[0] = mask;
            out
        }

        #[test]
        fn inflate_stored_fixed_dynamic() {
            assert_eq!(zlib_inflate(&STORED, 1 << 16).unwrap(), b"ABCDEFGHIJKLMNOPQRST");
            assert_eq!(zlib_inflate(&FIXED, 1 << 16).unwrap(), b"hello hello hello hello");
            let d = zlib_inflate(&DYNAMIC, 1 << 16).unwrap();
            assert_eq!(d.len(), 868);
            // adler32 trailer is verified inside zlib_inflate, so equal length + success proves content.
            assert!(d.starts_with(b"ritual ") || d.starts_with(b"summon ") || d.starts_with(b"portal ") || d.starts_with(b"channel ") || d.starts_with(b"warlock ") || d.starts_with(b"spell "));
        }

        #[test]
        fn inflate_rejects_corruption_and_limits() {
            let mut bad = DYNAMIC;
            let n = bad.len();
            bad[n - 1] ^= 0xFF; // adler trailer
            assert!(zlib_inflate(&bad, 1 << 16).is_err());
            assert!(zlib_inflate(&DYNAMIC, 100).is_err()); // output limit
            assert!(zlib_inflate(&[0x78, 0x9C], 100).is_err());
            assert!(zlib_inflate(&[0x00; 12], 100).is_err()); // bad header
        }

        #[test]
        fn packed_guid_roundtrip() {
            let g = 0xF110_008F_774D_238Au64;
            let enc = packed(g);
            assert_eq!(enc, vec![0xDF, 0x8A, 0x23, 0x4D, 0x77, 0x8F, 0x10, 0xF1]);
            let mut p = 0;
            assert_eq!(read_packed_guid(&enc, &mut p), Some(g));
            assert_eq!(p, enc.len());
            let mut q = 0;
            assert_eq!(read_packed_guid(&[0x0F, 0xDE], &mut q), None); // truncated
        }

        #[test]
        fn portal_guid_identity() {
            assert!(is_ritual_go_guid(0xF110_008F_774D_238A));
            assert!(!is_ritual_go_guid(0xF130_008F_774D_238A)); // creature high guid
            assert!(!is_ritual_go_guid(0xF110_0000_0000_0001));
        }

        #[test]
        fn spell_start_header_matches_live_log_shape() {
            // Shape of the live SMSG_SPELL_START(698): item=0x3B9F7FB2 caster=0x3B9F7FB2 spell=698 flags=2 timer=5000 targets=0
            let caster = 1000308658u64;
            let mut payload = packed(caster);
            payload.extend(packed(caster));
            payload.extend_from_slice(&698u32.to_le_bytes());
            payload.extend_from_slice(&2u16.to_le_bytes());
            payload.extend_from_slice(&5000u32.to_le_bytes());
            payload.extend_from_slice(&0u16.to_le_bytes());
            assert_eq!(payload.len(), 22); // matches "payload=22" in the live summoner log
            let h = decode_spell_header(&payload).unwrap();
            assert_eq!(h, SpellHeader { caster_item: caster, caster, spell: 698, flags: 2 });
            assert!(decode_spell_header(&payload[..7]).is_none());
        }

        #[test]
        fn truncate_is_char_safe() {
            assert_eq!(truncate_chars("abc", 5), "abc");
            assert_eq!(truncate_chars("abcdef", 3), "abc...[truncated]");
            assert_eq!(truncate_chars("ąęćłó", 2), "ąę...[truncated]");
        }

        #[test]
        fn ascii_runs_extracts_text() {
            let mut p = vec![0x01, 0x00, 0x00];
            p.extend_from_slice(b"Summon failed");
            p.extend_from_slice(&[0x00, 0x07]);
            p.extend_from_slice(b"ab");
            assert_eq!(ascii_runs(&p, 4, 100), "Summon failed");
            assert!(ascii_runs(&p, 4, 5).ends_with("..."));
        }

        #[test]
        fn scanner_decodes_values_only_packet() {
            let scan = scan_update_blocks(&PKT).unwrap();
            assert_eq!(scan.declared, 2);
            assert_eq!(scan.stopped, None);
            assert_eq!(scan.values.len(), 2);
            assert_eq!(scan.values[0].guid, 0xF110_008F_774D_238A);
            assert_eq!(scan.values[0].fields, vec![(9, 1), (10, 2)]);
            assert_eq!(scan.values[1].guid, 1000308658);
            assert_eq!(
                scan.values[1].fields,
                vec![(UNIT_FIELD_CHANNEL_OBJECT_LO, 0x004D_238A), (UNIT_FIELD_CHANNEL_OBJECT_HI, 0xF110_008F)]
            );
        }

        #[test]
        fn compressed_update_roundtrips_through_inflate_and_scan() {
            let declared = u32::from_le_bytes([PKT_COMPRESSED[0], PKT_COMPRESSED[1], PKT_COMPRESSED[2], PKT_COMPRESSED[3]]) as usize;
            assert_eq!(declared, PKT.len());
            let body = zlib_inflate(&PKT_COMPRESSED[4..], 1 << 16).unwrap();
            assert_eq!(body, PKT.to_vec());
            assert_eq!(scan_update_blocks(&body).unwrap().values.len(), 2);
        }

        #[test]
        fn scanner_stops_at_create_and_rejects_garbage() {
            let mut d = Vec::new();
            d.extend_from_slice(&1u32.to_le_bytes());
            d.push(0); // has_transport
            d.push(3); // CREATE_OBJECT2
            let s = scan_update_blocks(&d).unwrap();
            assert!(s.stopped.is_some());
            assert!(s.values.is_empty());
            assert!(scan_update_blocks(&[1, 0]).is_err());
            // out-of-range block: type 4, count 1, one packed guid
            let mut o = Vec::new();
            o.extend_from_slice(&1u32.to_le_bytes());
            o.push(0);
            o.push(4);
            o.extend_from_slice(&1u32.to_le_bytes());
            o.extend(packed(5));
            let s = scan_update_blocks(&o).unwrap();
            assert_eq!(s.out_of_range, 1);
            // implausible mask count must not allocate or panic
            let mut m = Vec::new();
            m.extend_from_slice(&1u32.to_le_bytes());
            m.push(0);
            m.push(0);
            m.extend(packed(7));
            m.push(200);
            assert!(scan_update_blocks(&m).is_err());
        }

        #[test]
        fn outcome_is_conservative() {
            assert_eq!(classify_outcome(0, 0, 0, 0), "NO_SERVER_TRANSITION_OBSERVED_UNCONFIRMED");
            assert_eq!(classify_outcome(0, 0, 1, 0), "SERVER_TRANSITION_OBSERVED_AFTER_CLICK");
            assert_eq!(classify_outcome(0, 0, 0, 1), "SERVER_TRANSITION_OBSERVED_AFTER_CLICK");
            assert_eq!(classify_outcome(0, 2, 0, 0), "SERVER_FAILURE_OBSERVED_AFTER_CLICK");
            assert_eq!(classify_outcome(1, 0, 0, 0), "SUMMON_REQUEST_ADDRESSED_TO_THIS_CLICKER");
        }

        #[test]
        fn random_garbage_never_panics() {
            // xorshift64*; deterministic.
            let mut x = 0x9E37_79B9_7F4A_7C15u64;
            let mut next = || {
                x ^= x >> 12;
                x ^= x << 25;
                x ^= x >> 27;
                x.wrapping_mul(0x2545_F491_4F6C_DD1D)
            };
            for round in 0..4000 {
                let len = (next() % 160) as usize;
                let buf: Vec<u8> = (0..len).map(|_| next() as u8).collect();
                let _ = scan_update_blocks(&buf);
                let _ = zlib_inflate(&buf, 4096);
                let _ = decode_spell_header(&buf);
                let _ = ascii_runs(&buf, 4, 64);
                if round % 40 == 0 {
                    for op in [0x00A9u16, 0x01F6, 0x0096, 0x0130, 0x0131, 0x0132, 0x0133, 0x0139, 0x013A, 0x01CB, 0x02A6, 0x02AB, 0x00AA, 0x00B3, 0x0777] {
                        trace_packet("Fuzz", op, &buf);
                    }
                }
            }
            // Corrupt valid streams too (bit flips inside the deflate body).
            for i in 0..PKT_COMPRESSED.len() {
                let mut c = PKT_COMPRESSED;
                c[i] ^= 0x5A;
                trace_packet("Fuzz", 0x01F6, &c);
            }
            poll_outcome("Fuzz");
        }

        #[test]
        fn clock_format() {
            assert_eq!(utc_hms(1_760_000_000_123 % 86_400_000), utc_hms(1_760_000_000_123));
            assert_eq!(utc_hms(3_723_004), "01:02:03.004Z");
        }
    }
}
