// Pure (std-only) inventory-baseline logic for AUTO Lifecycle V2.
// Included into the canonical module by integrate.py and also compiled standalone by CI
// (`rustc --edition=2021 --test`) so every state transition is unit tested without a socket.
//
// Why this exists: the lifecycle inventory cache is fed by object-update packets. A single
// update that the typed parser rejects used to wipe the cache, and nothing could ever restore
// it (vanilla has no read-only "resend my inventory" request). The live server emits many tiny
// compressed updates that the typed parser rejects, so the cache was always empty before the
// first CANCEL and every candidate was skipped as "baseline not established".
//
// Model: an unparsable update is classified by an independent byte-level scanner.
//   Irrelevant  -> proven to touch no Item/Container GUID and not the player itself.
//   Relevant    -> may have touched inventory (or could not be proven otherwise): uncertainty
//                  is recorded and is STICKY. Unknown is never treated as "item absent".

use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq, Eq)]
enum LifecycleUnparsed { Irrelevant, Relevant(String) }

#[derive(Debug, Default, Clone)]
struct LifecycleBaselineFacts {
    parsed_updates: u32,
    irrelevant_unparsed: u32,
    uncertain: u32,
    first_uncertain: Option<String>,
}

#[derive(Debug, Clone)]
struct LifecycleBaselineItem { guid: u64, entry: i32, stack: i32, verified: bool, container: bool }

#[derive(Debug, Clone, PartialEq, Eq)]
enum LifecycleBaselineVerdict {
    NotEstablished(String),
    Invalid(String),
    Present(Vec<(u64, i32)>),
    Absent,
}

impl LifecycleBaselineVerdict {
    fn describe(&self) -> String {
        match self {
            Self::NotEstablished(w) => format!("inventory baseline not established: {w}"),
            Self::Invalid(w) => format!("inventory baseline invalid: {w}"),
            Self::Present(v) => format!("same item present in bags (guid,stack)={v:?}"),
            Self::Absent => "target item absent".to_string(),
        }
    }
}

fn lifecycle_hex_prefix(d: &[u8], n: usize) -> String {
    let mut s = String::new();
    for b in d.iter().take(n) { let _ = write!(s, "{b:02x}"); }
    s
}

fn lifecycle_baseline_note_uncertain(f: &mut LifecycleBaselineFacts, why: String) {
    f.uncertain = f.uncertain.saturating_add(1);
    if f.first_uncertain.is_none() { f.first_uncertain = Some(why); }
}

// ---------------------------------------------------------------- authoritative slot structure
//
// Protocol analysis (vanilla 1.12.1):
//  * SMSG_LOGIN_VERIFY_WORLD is sent BEFORE the player is added to the map, so the create-object
//    burst for the player and every bag/item follows it. No packet marks "initial object set
//    complete"; a fixed packet count after coinage proves nothing.
//  * The Player object carries one GUID per inventory slot (PLAYER_FIELD_INV_SLOT_HEAD, 113
//    slots = ItemSlot 0..112: equipment, 4 bags, 16 backpack, bank, bank bags, buyback, keyring).
//  * Every bag Container carries CONTAINER_NUM_SLOTS (field 48) and one GUID per slot starting at
//    CONTAINER_SLOT_1 (field 50, 2 dwords each).
// Therefore the EXPECTED item set is derivable from authoritative fields, and the baseline is
// complete only when every expected GUID is a verified, observed object (and nothing else owned
// by the player is observed). Unknown at any step is never "absent".

const LIFECYCLE_INV_SLOTS: usize = 113;
const LIFECYCLE_CONTAINER_NUM_SLOTS_FIELD: u16 = 48;
const LIFECYCLE_CONTAINER_SLOT1_FIELD: u16 = 50;
const LIFECYCLE_CONTAINER_MAX_SLOTS: usize = 36;

#[derive(Debug, Clone)]
struct LifecycleContainer {
    created: bool,
    unknown: bool,
    num_slots: Option<u32>,
    lo: [Option<u32>; LIFECYCLE_CONTAINER_MAX_SLOTS],
    hi: [Option<u32>; LIFECYCLE_CONTAINER_MAX_SLOTS],
}
impl LifecycleContainer {
    fn blank() -> Self { Self { created: false, unknown: false, num_slots: None, lo: [None; LIFECYCLE_CONTAINER_MAX_SLOTS], hi: [None; LIFECYCLE_CONTAINER_MAX_SLOTS] } }
    fn apply(&mut self, fields: &[(u16, u32)]) {
        for &(f, v) in fields {
            if f == LIFECYCLE_CONTAINER_NUM_SLOTS_FIELD { self.num_slots = Some(v); }
            else if f >= LIFECYCLE_CONTAINER_SLOT1_FIELD && usize::from(f - LIFECYCLE_CONTAINER_SLOT1_FIELD) < LIFECYCLE_CONTAINER_MAX_SLOTS * 2 {
                let i = usize::from(f - LIFECYCLE_CONTAINER_SLOT1_FIELD) / 2;
                if (f - LIFECYCLE_CONTAINER_SLOT1_FIELD) % 2 == 0 { self.lo[i] = Some(v); } else { self.hi[i] = Some(v); }
            }
        }
    }
    fn slot(&self, i: usize) -> Option<u64> { Some(u64::from(self.lo[i]?) | (u64::from(self.hi[i]?) << 32)) }
}

#[derive(Debug, Clone)]
struct LifecycleInvTracker {
    player_created: bool,
    player_slots: [Option<u64>; LIFECYCLE_INV_SLOTS],
    containers: std::collections::HashMap<u64, LifecycleContainer>,
}
impl Default for LifecycleInvTracker {
    fn default() -> Self { Self { player_created: false, player_slots: [None; LIFECYCLE_INV_SLOTS], containers: std::collections::HashMap::new() } }
}
impl LifecycleInvTracker {
    /// Player CREATE block: authoritative for every slot; an absent field means an empty slot.
    fn player_create(&mut self, slots: &[Option<u64>; LIFECYCLE_INV_SLOTS]) {
        self.player_created = true;
        for (d, s) in self.player_slots.iter_mut().zip(slots.iter()) { *d = Some(s.unwrap_or(0)); }
    }
    /// Player VALUES block: only slots present in the delta change.
    fn player_values(&mut self, slots: &[Option<u64>; LIFECYCLE_INV_SLOTS]) {
        for (d, s) in self.player_slots.iter_mut().zip(slots.iter()) { if let Some(v) = s { *d = Some(*v); } }
    }
    fn container_create(&mut self, guid: u64, fields: &[(u16, u32)]) {
        let mut c = LifecycleContainer::blank();
        c.created = true;
        c.lo = [Some(0); LIFECYCLE_CONTAINER_MAX_SLOTS];
        c.hi = [Some(0); LIFECYCLE_CONTAINER_MAX_SLOTS];
        c.apply(fields);
        self.containers.insert(guid, c);
    }
    fn container_values(&mut self, guid: u64, fields: &[(u16, u32)]) {
        self.containers.entry(guid).or_insert_with(LifecycleContainer::blank).apply(fields);
    }
    /// A container was seen through a path that cannot read its slot list.
    fn container_unknown(&mut self, guid: u64) {
        let c = self.containers.entry(guid).or_insert_with(LifecycleContainer::blank);
        if !c.created { c.unknown = true; }
    }
    fn remove(&mut self, guid: u64) { self.containers.remove(&guid); }
    fn apply_event(&mut self, ev: &LifecycleInvEvent) {
        match ev {
            LifecycleInvEvent::ContainerCreate { guid, fields } => self.container_create(*guid, fields),
            LifecycleInvEvent::ContainerValues { guid, fields } => self.container_values(*guid, fields),
        }
    }
}

fn lifecycle_baseline_summary(f: &LifecycleBaselineFacts, inv: &LifecycleInvTracker, cache: &[LifecycleBaselineItem]) -> String {
    let nz = inv.player_slots.iter().filter(|s| s.is_some_and(|g| g != 0)).count();
    let unk = inv.player_slots.iter().filter(|s| s.is_none()).count();
    let created = inv.containers.values().filter(|c| c.created && !c.unknown).count();
    format!("player_created={} slots_nonzero={nz} slots_unknown={unk} containers_tracked={} containers_with_slots={created} cached_objects={} parsed_updates={} irrelevant_unparsed={} uncertain={} first_uncertain={}",
        inv.player_created, inv.containers.len(), cache.len(), f.parsed_updates, f.irrelevant_unparsed, f.uncertain, f.first_uncertain.as_deref().unwrap_or("-"))
}

/// The only place that may answer "is the target item absent from bags".
/// Absent requires: no sticky uncertainty, the player's slot fields known, and EVERY referenced
/// GUID (player slots + contents of every referenced container) observed as a verified object,
/// with no extra owned object outside that set. Anything else is not Absent.
fn lifecycle_baseline_verdict(f: &LifecycleBaselineFacts, inv: &LifecycleInvTracker, cache: &[LifecycleBaselineItem], item: u32) -> LifecycleBaselineVerdict {
    use LifecycleBaselineVerdict as V;
    if f.uncertain > 0 {
        return V::Invalid(format!("{} relevant/undecodable update(s) since login, first: {}", f.uncertain, f.first_uncertain.clone().unwrap_or_default()));
    }
    // Presence is decided on whatever is cached, even if the baseline is incomplete (still a skip).
    let hit: Vec<(u64, i32)> = cache.iter().filter(|c| !c.container && c.entry > 0 && c.entry as u32 == item).map(|c| (c.guid, c.stack)).collect();
    if !hit.is_empty() { return V::Present(hit); }
    if !inv.player_created { return V::NotEstablished("player create block (slot fields) not observed".into()); }
    if let Some(i) = inv.player_slots.iter().position(|s| s.is_none()) { return V::NotEstablished(format!("player slot {i} unknown")); }

    let by_guid: std::collections::HashMap<u64, &LifecycleBaselineItem> = cache.iter().map(|c| (c.guid, c)).collect();
    let mut expected: std::collections::HashSet<u64> = std::collections::HashSet::new();
    let mut missing: Vec<u64> = Vec::new();
    let mut containers: Vec<u64> = Vec::new();

    let mut top: Vec<u64> = inv.player_slots.iter().flatten().copied().filter(|g| *g != 0).collect();
    top.sort_unstable(); top.dedup();
    for g in &top {
        expected.insert(*g);
        match by_guid.get(g) {
            Some(c) if c.verified && c.entry > 0 && c.stack > 0 => { if c.container || inv.containers.contains_key(g) { containers.push(*g); } }
            _ => missing.push(*g),
        }
    }
    for g in &containers {
        let Some(c) = inv.containers.get(g) else { return V::NotEstablished(format!("container 0x{g:016X} slot list never observed")); };
        if c.unknown || !c.created { return V::NotEstablished(format!("container 0x{g:016X} slot list not observed in a create block")); }
        let Some(n) = c.num_slots else { return V::NotEstablished(format!("container 0x{g:016X} num_slots unknown")); };
        let n = n as usize;
        if n > LIFECYCLE_CONTAINER_MAX_SLOTS { return V::Invalid(format!("container 0x{g:016X} num_slots={n} out of range")); }
        for i in 0..LIFECYCLE_CONTAINER_MAX_SLOTS {
            let Some(sg) = c.slot(i) else { return V::NotEstablished(format!("container 0x{g:016X} slot {i} unknown")); };
            if sg == 0 { continue; }
            if i >= n { return V::Invalid(format!("container 0x{g:016X} slot {i} populated beyond num_slots={n}")); }
            expected.insert(sg);
            match by_guid.get(&sg) {
                Some(x) if x.container => return V::Invalid(format!("nested container 0x{sg:016X}")),
                Some(x) if x.verified && x.entry > 0 && x.stack > 0 => {}
                _ => missing.push(sg),
            }
        }
    }
    if !missing.is_empty() {
        return V::NotEstablished(format!("{} referenced GUID(s) not yet observed as verified objects, first 0x{:016X}", missing.len(), missing[0]));
    }
    if let Some(extra) = cache.iter().find(|c| !expected.contains(&c.guid)) {
        return V::NotEstablished(format!("cached object 0x{:016X} entry={} not referenced by any slot field", extra.guid, extra.entry));
    }
    V::Absent
}

// ---------------------------------------------------------------- inflate (RFC 1950/1951)

struct LifecycleBits<'a> { d: &'a [u8], pos: usize, buf: u32, cnt: u32 }
impl<'a> LifecycleBits<'a> {
    fn bits(&mut self, need: u32) -> Result<u32, &'static str> {
        let mut v = self.buf;
        while self.cnt < need {
            let b = *self.d.get(self.pos).ok_or("inflate: out of input")? as u32;
            self.pos += 1;
            v |= b << self.cnt;
            self.cnt += 8;
        }
        self.buf = v >> need;
        self.cnt -= need;
        Ok(v & ((1u32 << need) - 1))
    }
}
struct LifecycleHuff { count: [u16; 16], symbol: Vec<u16> }
fn lifecycle_huff(lengths: &[u8]) -> Result<LifecycleHuff, &'static str> {
    let mut count = [0u16; 16];
    for &l in lengths { count[l as usize] += 1; }
    let mut left: i32 = 1;
    for len in 1..16 { left <<= 1; left -= count[len] as i32; if left < 0 { return Err("inflate: over-subscribed code"); } }
    let mut offs = [0u16; 16];
    for len in 1..15 { offs[len + 1] = offs[len] + count[len]; }
    let mut symbol = vec![0u16; lengths.len()];
    for (s, &l) in lengths.iter().enumerate() { if l != 0 { symbol[offs[l as usize] as usize] = s as u16; offs[l as usize] += 1; } }
    Ok(LifecycleHuff { count, symbol })
}
fn lifecycle_decode(br: &mut LifecycleBits, h: &LifecycleHuff) -> Result<u16, &'static str> {
    let (mut code, mut first, mut index) = (0i32, 0i32, 0i32);
    for len in 1..16 {
        code |= br.bits(1)? as i32;
        let count = h.count[len] as i32;
        if code - count < first { return Ok(h.symbol[(index + (code - first)) as usize]); }
        index += count; first += count; first <<= 1; code <<= 1;
    }
    Err("inflate: bad code")
}
const LEN_BASE: [u16; 29] = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
const LEN_EXTRA: [u8; 29] = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
const DIST_BASE: [u16; 30] = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
const DIST_EXTRA: [u8; 30] = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];

fn lifecycle_inflate_codes(br: &mut LifecycleBits, out: &mut Vec<u8>, max_out: usize, lit: &LifecycleHuff, dist: &LifecycleHuff) -> Result<(), &'static str> {
    loop {
        let sym = lifecycle_decode(br, lit)? as usize;
        if sym < 256 {
            if out.len() >= max_out { return Err("inflate: output limit"); }
            out.push(sym as u8);
        } else if sym == 256 {
            return Ok(());
        } else {
            let s = sym - 257;
            if s >= 29 { return Err("inflate: bad length symbol"); }
            let len = LEN_BASE[s] as usize + br.bits(LEN_EXTRA[s] as u32)? as usize;
            let ds = lifecycle_decode(br, dist)? as usize;
            if ds >= 30 { return Err("inflate: bad distance symbol"); }
            let d = DIST_BASE[ds] as usize + br.bits(DIST_EXTRA[ds] as u32)? as usize;
            if d > out.len() { return Err("inflate: distance too far"); }
            if out.len() + len > max_out { return Err("inflate: output limit"); }
            for _ in 0..len { let b = out[out.len() - d]; out.push(b); }
        }
    }
}

fn lifecycle_inflate_raw(data: &[u8], max_out: usize) -> Result<Vec<u8>, &'static str> {
    let mut br = LifecycleBits { d: data, pos: 0, buf: 0, cnt: 0 };
    let mut out = Vec::new();
    loop {
        let last = br.bits(1)?;
        match br.bits(2)? {
            0 => {
                br.buf = 0; br.cnt = 0;
                let p = br.pos;
                if p + 4 > data.len() { return Err("inflate: stored header"); }
                let len = u16::from_le_bytes([data[p], data[p + 1]]);
                let nlen = u16::from_le_bytes([data[p + 2], data[p + 3]]);
                if len != !nlen { return Err("inflate: stored length mismatch"); }
                let s = p + 4; let e = s + len as usize;
                if e > data.len() { return Err("inflate: stored overrun"); }
                if out.len() + len as usize > max_out { return Err("inflate: output limit"); }
                out.extend_from_slice(&data[s..e]);
                br.pos = e;
            }
            1 => {
                let mut l = [0u8; 288];
                for (i, v) in l.iter_mut().enumerate() { *v = if i < 144 { 8 } else if i < 256 { 9 } else if i < 280 { 7 } else { 8 }; }
                let lit = lifecycle_huff(&l)?;
                let dist = lifecycle_huff(&[5u8; 30])?;
                lifecycle_inflate_codes(&mut br, &mut out, max_out, &lit, &dist)?;
            }
            2 => {
                let nlen = br.bits(5)? as usize + 257;
                let ndist = br.bits(5)? as usize + 1;
                let ncode = br.bits(4)? as usize + 4;
                if nlen > 286 || ndist > 30 { return Err("inflate: bad counts"); }
                const ORDER: [usize; 19] = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
                let mut lengths = [0u8; 320];
                for &o in ORDER.iter().take(ncode) { lengths[o] = br.bits(3)? as u8; }
                let lencode = lifecycle_huff(&lengths[..19])?;
                let mut idx = 0usize;
                let mut ll = [0u8; 320];
                while idx < nlen + ndist {
                    let sym = lifecycle_decode(&mut br, &lencode)?;
                    if sym < 16 { ll[idx] = sym as u8; idx += 1; }
                    else {
                        let (prev, rep) = match sym {
                            16 => { if idx == 0 { return Err("inflate: repeat without previous"); } (ll[idx - 1], 3 + br.bits(2)? as usize) }
                            17 => (0, 3 + br.bits(3)? as usize),
                            _ => (0, 11 + br.bits(7)? as usize),
                        };
                        if idx + rep > nlen + ndist { return Err("inflate: repeat overrun"); }
                        for _ in 0..rep { ll[idx] = prev; idx += 1; }
                    }
                }
                if ll[256] == 0 { return Err("inflate: no end-of-block code"); }
                let lit = lifecycle_huff(&ll[..nlen])?;
                let dist = lifecycle_huff(&ll[nlen..nlen + ndist])?;
                lifecycle_inflate_codes(&mut br, &mut out, max_out, &lit, &dist)?;
            }
            _ => return Err("inflate: reserved block type"),
        }
        if last == 1 { return Ok(out); }
    }
}

fn lifecycle_zlib_inflate(data: &[u8], max_out: usize) -> Result<Vec<u8>, &'static str> {
    if data.len() < 2 { return Err("zlib: short"); }
    if data[0] & 0x0f != 8 || (u32::from(data[0]) * 256 + u32::from(data[1])) % 31 != 0 || data[1] & 0x20 != 0 { return Err("zlib: bad header"); }
    lifecycle_inflate_raw(&data[2..], max_out)
}

// ---------------------------------------------------------------- update-block scanner

fn lifecycle_packed_guid(d: &[u8], pos: &mut usize) -> Option<u64> {
    let m = *d.get(*pos)?; *pos += 1;
    let mut g = 0u64;
    for i in 0..8 { if m & (1 << i) != 0 { g |= u64::from(*d.get(*pos)?) << (8 * i); *pos += 1; } }
    Some(g)
}

/// None  = GUID class is known not to be an inventory object (other player, creature, GO, ...).
/// Some  = may be inventory related (self, Item/Container) or an unknown class.
fn lifecycle_guid_concern(g: u64, player: u64) -> Option<&'static str> {
    if g == 0 { return Some("zero guid"); }
    if g == player { return Some("player self"); }
    match g >> 48 {
        0x0000 | 0xF100 | 0xF101 | 0xF110 | 0xF120 | 0xF130 | 0xF140 => None,
        0x4000 => Some("item/container guid"),
        _ => Some("unknown guid class"),
    }
}

/// Scan an uncompressed update-object body: u32 count, u8 has_transport, blocks.
/// VALUES / OUT_OF_RANGE / NEAR blocks have a self-describing length and are fully walked.
/// MOVEMENT / CREATE blocks are only inspected for their GUID and are accepted solely as the
/// final declared block. Anything else is Relevant (fail closed).
fn lifecycle_scan_update_body(d: &[u8], player: u64) -> LifecycleUnparsed {
    use LifecycleUnparsed::*;
    let rel = |w: String| Relevant(w);
    if d.len() < 5 { return rel("update body too short".into()); }
    let count = u32::from_le_bytes([d[0], d[1], d[2], d[3]]) as usize;
    if count == 0 || count > 4096 { return rel(format!("implausible object count {count}")); }
    let mut pos = 5usize;
    for i in 0..count {
        let Some(&t) = d.get(pos) else { return rel(format!("truncated before block {i}")); };
        pos += 1;
        match t {
            0 => {
                let Some(g) = lifecycle_packed_guid(d, &mut pos) else { return rel("truncated values guid".into()); };
                if let Some(why) = lifecycle_guid_concern(g, player) { return rel(format!("values block touches {why} 0x{g:016X}")); }
                let Some(&nb) = d.get(pos) else { return rel("truncated mask count".into()); };
                pos += 1;
                let mlen = nb as usize * 4;
                if pos + mlen > d.len() { return rel("truncated mask".into()); }
                let set: u32 = d[pos..pos + mlen].iter().map(|b| b.count_ones()).sum();
                pos += mlen + set as usize * 4;
                if pos > d.len() { return rel("truncated values".into()); }
            }
            4 | 5 => {
                if pos + 4 > d.len() { return rel("truncated out-of-range count".into()); }
                let n = u32::from_le_bytes([d[pos], d[pos + 1], d[pos + 2], d[pos + 3]]) as usize;
                pos += 4;
                if n > 4096 { return rel("implausible out-of-range count".into()); }
                for _ in 0..n {
                    let Some(g) = lifecycle_packed_guid(d, &mut pos) else { return rel("truncated out-of-range guid".into()); };
                    if let Some(why) = lifecycle_guid_concern(g, player) { return rel(format!("out-of-range block touches {why} 0x{g:016X}")); }
                }
            }
            1 | 2 | 3 => {
                let Some(g) = lifecycle_packed_guid(d, &mut pos) else { return rel("truncated create/movement guid".into()); };
                if let Some(why) = lifecycle_guid_concern(g, player) { return rel(format!("create/movement block touches {why} 0x{g:016X}")); }
                if i + 1 == count { return Irrelevant; }
                return rel("undecodable create/movement block is not the last block".into());
            }
            other => return rel(format!("unknown update type {other}")),
        }
    }
    if pos != d.len() { return rel("trailing bytes after declared blocks".into()); }
    Irrelevant
}

/// Classify an update packet the typed parser rejected. `payload` is the raw server payload.
fn lifecycle_classify_unparsed_update(compressed: bool, payload: &[u8], player: u64) -> LifecycleUnparsed {
    let prefix = lifecycle_hex_prefix(payload, 48);
    let tag = |r: LifecycleUnparsed| match r {
        LifecycleUnparsed::Relevant(w) => LifecycleUnparsed::Relevant(format!("{w} [compressed={compressed} len={} head={prefix}]", payload.len())),
        ok => ok,
    };
    if !compressed { return tag(lifecycle_scan_update_body(payload, player)); }
    if payload.len() < 6 { return tag(LifecycleUnparsed::Relevant("compressed payload too short".into())); }
    let declared = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    if declared == 0 || declared > (1 << 20) { return tag(LifecycleUnparsed::Relevant("implausible decompressed size".into())); }
    match lifecycle_zlib_inflate(&payload[4..], declared) {
        Ok(body) if body.len() == declared => tag(lifecycle_scan_update_body(&body, player)),
        Ok(body) => tag(LifecycleUnparsed::Relevant(format!("decompressed {} != declared {declared}", body.len()))),
        Err(e) => tag(LifecycleUnparsed::Relevant(format!("zlib failure: {e}"))),
    }
}

// ---------------------------------------------------------------- container slot walker
//
// The typed parser exposes only CONTAINER_SLOT_1, so container slot lists are read straight from
// the update bytes. Only blocks whose layout is self-describing (VALUES / OUT_OF_RANGE / NEAR) or
// whose movement block is non-LIVING (items, containers, most gameobjects) can be walked. The walk
// stops at the first block it cannot size; the caller decides (using the typed parse) whether any
// container block lies beyond the stop and fails closed if so.

#[derive(Debug, Clone, PartialEq, Eq)]
enum LifecycleInvEvent {
    ContainerCreate { guid: u64, fields: Vec<(u16, u32)> },
    ContainerValues { guid: u64, fields: Vec<(u16, u32)> },
}

#[derive(Debug, Default)]
struct LifecycleWalk { events: Vec<LifecycleInvEvent>, stopped_at: Option<usize>, reason: String, total: usize }

fn lifecycle_rd_u32(d: &[u8], pos: &mut usize) -> Option<u32> {
    let b = d.get(*pos..*pos + 4)?; *pos += 4;
    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

/// Walk `u8 nblocks, nblocks*u32 mask, one u32 per set bit`; return fields inside the container range.
fn lifecycle_walk_mask(d: &[u8], pos: &mut usize) -> Option<Vec<(u16, u32)>> {
    let nb = usize::from(*d.get(*pos)?); *pos += 1;
    let mut masks = Vec::with_capacity(nb);
    for _ in 0..nb { masks.push(lifecycle_rd_u32(d, pos)?); }
    let mut out = Vec::new();
    for (w, m) in masks.iter().enumerate() {
        for bit in 0..32u32 {
            if m & (1 << bit) != 0 {
                let v = lifecycle_rd_u32(d, pos)?;
                let f = w as u32 * 32 + bit;
                if (LIFECYCLE_CONTAINER_NUM_SLOTS_FIELD as u32..(LIFECYCLE_CONTAINER_SLOT1_FIELD as u32 + 72)).contains(&f) { out.push((f as u16, v)); }
            }
        }
    }
    Some(out)
}

fn lifecycle_walk_step(d: &[u8], pos: &mut usize, w: &mut LifecycleWalk) -> Result<(), String> {
    let t = *d.get(*pos).ok_or("truncated block type")?; *pos += 1;
    match t {
        0 => {
            let g = lifecycle_packed_guid(d, pos).ok_or("truncated values guid")?;
            let fields = lifecycle_walk_mask(d, pos).ok_or("truncated values mask")?;
            if g >> 48 == 0x4000 && !fields.is_empty() { w.events.push(LifecycleInvEvent::ContainerValues { guid: g, fields }); }
        }
        4 | 5 => {
            let n = lifecycle_rd_u32(d, pos).ok_or("truncated out-of-range count")? as usize;
            if n > 4096 { return Err("implausible out-of-range count".into()); }
            for _ in 0..n { lifecycle_packed_guid(d, pos).ok_or("truncated out-of-range guid")?; }
        }
        2 | 3 => {
            let g = lifecycle_packed_guid(d, pos).ok_or("truncated create guid")?;
            let objtype = *d.get(*pos).ok_or("truncated object type")?; *pos += 1;
            let flags = *d.get(*pos).ok_or("truncated update flags")?; *pos += 1;
            if flags & 0x20 != 0 { return Err("LIVING movement block is not decoded".into()); }
            let mut skip = 0usize;
            if flags & 0x40 != 0 { skip += 16; }
            if flags & 0x08 != 0 { skip += 4; }
            if flags & 0x10 != 0 { skip += 4; }
            if flags & 0x02 != 0 { skip += 4; }
            if *pos + skip > d.len() { return Err("truncated movement block".into()); }
            *pos += skip;
            if flags & 0x04 != 0 { lifecycle_packed_guid(d, pos).ok_or("truncated target guid")?; }
            let fields = lifecycle_walk_mask(d, pos).ok_or("truncated create mask")?;
            if objtype == 2 {
                if g >> 48 != 0x4000 { return Err("container object type with non-item guid".into()); }
                w.events.push(LifecycleInvEvent::ContainerCreate { guid: g, fields });
            }
        }
        other => return Err(format!("undecodable update type {other}")),
    }
    Ok(())
}

fn lifecycle_walk_inventory_blocks(d: &[u8]) -> LifecycleWalk {
    let mut w = LifecycleWalk::default();
    if d.len() < 5 { w.stopped_at = Some(0); w.reason = "body too short".into(); return w; }
    let count = u32::from_le_bytes([d[0], d[1], d[2], d[3]]) as usize;
    if count == 0 || count > 4096 { w.stopped_at = Some(0); w.reason = format!("implausible count {count}"); return w; }
    w.total = count;
    let mut pos = 5usize;
    for i in 0..count {
        if let Err(r) = lifecycle_walk_step(d, &mut pos, &mut w) { w.stopped_at = Some(i); w.reason = r; return w; }
    }
    if pos != d.len() { w.stopped_at = Some(count); w.reason = "trailing bytes after declared blocks".into(); }
    w
}

/// Decompress (when needed) and walk an update packet payload.
fn lifecycle_walk_update_payload(compressed: bool, payload: &[u8]) -> LifecycleWalk {
    if !compressed { return lifecycle_walk_inventory_blocks(payload); }
    let fail = |r: String| LifecycleWalk { stopped_at: Some(0), reason: r, ..Default::default() };
    if payload.len() < 6 { return fail("compressed payload too short".into()); }
    let declared = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    if declared == 0 || declared > (1 << 20) { return fail("implausible decompressed size".into()); }
    match lifecycle_zlib_inflate(&payload[4..], declared) {
        Ok(b) if b.len() == declared => lifecycle_walk_inventory_blocks(&b),
        Ok(_) => fail("decompressed size mismatch".into()),
        Err(e) => fail(format!("zlib failure: {e}")),
    }
}

// ---------------------------------------------------------------- bounded read-only baseline wait

/// Read-only: `barrier` may only issue non-mutating requests that drain world packets. The loop
/// waits (bounded) for a transient NotEstablished to resolve; any other verdict ends it at once.
fn lifecycle_baseline_wait_loop(
    rounds: u32,
    mut barrier: impl FnMut(u32) -> Result<(), String>,
    mut verdict: impl FnMut() -> LifecycleBaselineVerdict,
    mut pause: impl FnMut(),
) -> Result<LifecycleBaselineVerdict, String> {
    let mut last = LifecycleBaselineVerdict::NotEstablished("no wait rounds".into());
    for r in 0..rounds {
        barrier(r)?;
        last = verdict();
        if matches!(last, LifecycleBaselineVerdict::NotEstablished(_)) { if r + 1 < rounds { pause(); } } else { return Ok(last); }
    }
    Ok(last)
}

// ---------------------------------------------------------------- bounded read-only settle

#[derive(Debug, Clone, PartialEq, Eq)]
enum LifecycleSettleStep { Exact(u64), Pending, Merged, Ambiguous(String) }

/// Bounded read-only settle: `poll` may only read (no sends of mutations); `classify` is pure.
/// Never retries a mutation; exhausting the rounds is an error (caller hard-stops).
fn lifecycle_settle_loop<S>(
    rounds: u32,
    mut poll: impl FnMut(u32) -> Result<S, String>,
    mut classify: impl FnMut(&S) -> LifecycleSettleStep,
    mut pause: impl FnMut(),
) -> Result<u64, String> {
    for round in 0..rounds {
        let snap = poll(round)?;
        match classify(&snap) {
            LifecycleSettleStep::Exact(g) => return Ok(g),
            LifecycleSettleStep::Pending => { if round + 1 < rounds { pause(); } }
            LifecycleSettleStep::Merged => return Err(format!("returned item MERGED into existing stack at settle_round={round}; manual reconciliation required")),
            LifecycleSettleStep::Ambiguous(w) => return Err(format!("returned item ambiguous at settle_round={round}: {w}; reconciliation required")),
        }
    }
    Err("exact returned full-stack GUID not observed within bounded read-only settle window; reconciliation required".into())
}

#[cfg(test)]
mod lifecycle_baseline_tests {
    use super::*;

    const ME: u64 = 0x0000_0000_0000_1234;
    fn it(guid: u64, entry: i32, stack: i32) -> LifecycleBaselineItem { LifecycleBaselineItem { guid, entry, stack, verified: true, container: false } }
    fn bag(guid: u64) -> LifecycleBaselineItem { LifecycleBaselineItem { guid, entry: 4496, stack: 1, verified: true, container: true } }
    const G: u64 = 0x4000_0000_0000_0000;
    fn slots(pairs: &[(usize, u64)]) -> [Option<u64>; LIFECYCLE_INV_SLOTS] { let mut s = [None; LIFECYCLE_INV_SLOTS]; for (i, g) in pairs { s[*i] = Some(*g); } s }
    fn inv_with(pairs: &[(usize, u64)]) -> LifecycleInvTracker { let mut t = LifecycleInvTracker::default(); t.player_create(&slots(pairs)); t }
    fn add_bag(t: &mut LifecycleInvTracker, guid: u64, num: u32, contents: &[(usize, u64)]) {
        let mut f = vec![(LIFECYCLE_CONTAINER_NUM_SLOTS_FIELD, num)];
        for (i, g) in contents { f.push((LIFECYCLE_CONTAINER_SLOT1_FIELD + 2 * *i as u16, *g as u32)); f.push((LIFECYCLE_CONTAINER_SLOT1_FIELD + 2 * *i as u16 + 1, (*g >> 32) as u32)); }
        t.container_create(guid, &f);
    }
    fn facts() -> LifecycleBaselineFacts { LifecycleBaselineFacts::default() }
    fn v(t: &LifecycleInvTracker, c: &[LifecycleBaselineItem]) -> LifecycleBaselineVerdict { lifecycle_baseline_verdict(&facts(), t, c, 10998) }

    // ---- baseline state machine
    #[test] fn no_player_create_means_not_established() {
        assert!(matches!(v(&LifecycleInvTracker::default(), &[]), LifecycleBaselineVerdict::NotEstablished(_)));
        assert!(matches!(v(&LifecycleInvTracker::default(), &[it(G | 1, 5, 1)]), LifecycleBaselineVerdict::NotEstablished(_)));
    }
    #[test] fn partial_cache_with_unrelated_items_while_target_may_be_unobserved_is_never_absent() {
        // Real backpack: A, B and the target item 10998 (guid C). Only A and B have been observed.
        let t = inv_with(&[(23, G | 1), (24, G | 2), (25, G | 3)]);
        let cache = [it(G | 1, 2589, 20), it(G | 2, 4306, 5)];
        let verdict = v(&t, &cache);
        assert_ne!(verdict, LifecycleBaselineVerdict::Absent);
        assert!(matches!(verdict, LifecycleBaselineVerdict::NotEstablished(_)));
        // once C arrives and is the target -> Present, never Absent
        let mut cache2 = cache.to_vec(); cache2.push(it(G | 3, 10998, 4));
        assert_eq!(v(&t, &cache2), LifecycleBaselineVerdict::Present(vec![(G | 3, 4)]));
        // once C arrives and is something else -> Absent is now proven
        let mut cache3 = cache.to_vec(); cache3.push(it(G | 3, 11175, 1));
        assert_eq!(v(&t, &cache3), LifecycleBaselineVerdict::Absent);
    }
    #[test] fn target_missing_from_cache_even_if_only_one_slot_unobserved_is_not_absent() {
        let t = inv_with(&[(23, G | 1), (30, G | 9)]);
        assert!(matches!(v(&t, &[it(G | 1, 5, 1)]), LifecycleBaselineVerdict::NotEstablished(_)));
    }
    #[test] fn empty_character_is_absent_only_with_authoritative_empty_slots() {
        assert_eq!(v(&inv_with(&[]), &[]), LifecycleBaselineVerdict::Absent);
        // cache empty but slots reference an object -> not absent
        assert!(matches!(v(&inv_with(&[(23, G | 1)]), &[]), LifecycleBaselineVerdict::NotEstablished(_)));
    }
    #[test] fn bag_contents_are_reconciled_target_in_bag_is_found_or_blocks_absent() {
        let mut t = inv_with(&[(19, G | 100), (23, G | 1)]);
        add_bag(&mut t, G | 100, 16, &[(0, G | 2), (5, G | 3)]);
        let base = [bag(G | 100), it(G | 1, 2589, 5), it(G | 2, 4306, 5)];
        // G|3 (inside the bag) not observed yet -> NOT absent
        assert!(matches!(v(&t, &base), LifecycleBaselineVerdict::NotEstablished(_)));
        let mut with_target = base.to_vec(); with_target.push(it(G | 3, 10998, 2));
        assert_eq!(v(&t, &with_target), LifecycleBaselineVerdict::Present(vec![(G | 3, 2)]));
        let mut other = base.to_vec(); other.push(it(G | 3, 11175, 2));
        assert_eq!(v(&t, &other), LifecycleBaselineVerdict::Absent);
    }
    #[test] fn bag_slot_list_unknown_or_typed_path_only_is_not_established() {
        let t = inv_with(&[(19, G | 100)]);
        assert!(matches!(v(&t, &[bag(G | 100)]), LifecycleBaselineVerdict::NotEstablished(_)));
        let mut t2 = inv_with(&[(19, G | 100)]);
        t2.container_unknown(G | 100);
        assert!(matches!(v(&t2, &[bag(G | 100)]), LifecycleBaselineVerdict::NotEstablished(_)));
        // a Values-only view of a bag (never saw its create) is not a slot list
        let mut t3 = inv_with(&[(19, G | 100)]);
        t3.container_values(G | 100, &[(LIFECYCLE_CONTAINER_NUM_SLOTS_FIELD, 16)]);
        assert!(matches!(v(&t3, &[bag(G | 100)]), LifecycleBaselineVerdict::NotEstablished(_)));
    }
    #[test] fn structural_contradictions_are_invalid() {
        let mut t = inv_with(&[(19, G | 100)]);
        add_bag(&mut t, G | 100, 4, &[(7, G | 2)]); // slot 7 populated beyond num_slots=4
        assert!(matches!(v(&t, &[bag(G | 100), it(G | 2, 5, 1)]), LifecycleBaselineVerdict::Invalid(_)));
        let mut t2 = inv_with(&[(19, G | 100)]);
        add_bag(&mut t2, G | 100, 4, &[(0, G | 101)]);
        assert!(matches!(v(&t2, &[bag(G | 100), bag(G | 101)]), LifecycleBaselineVerdict::Invalid(_)));
    }
    #[test] fn unreferenced_or_unverified_cached_objects_are_not_absent() {
        let t = inv_with(&[(23, G | 1)]);
        assert!(matches!(v(&t, &[it(G | 1, 5, 1), it(G | 77, 5, 1)]), LifecycleBaselineVerdict::NotEstablished(_)));
        let mut unv = it(G | 1, 5, 1); unv.verified = false;
        assert!(matches!(v(&t, &[unv]), LifecycleBaselineVerdict::NotEstablished(_)));
        let mut zero = it(G | 1, 0, 1); zero.verified = true;
        assert!(matches!(v(&t, &[zero]), LifecycleBaselineVerdict::NotEstablished(_)));
    }
    #[test] fn player_values_delta_changes_only_present_slots() {
        let mut t = inv_with(&[(23, G | 1), (24, G | 2)]);
        t.player_values(&slots(&[(24, 0)]));        // slot 24 emptied, slot 23 untouched
        assert_eq!(v(&t, &[it(G | 1, 5, 1)]), LifecycleBaselineVerdict::Absent);
        t.player_values(&slots(&[(25, G | 3)]));    // new item appears in slot 25
        assert!(matches!(v(&t, &[it(G | 1, 5, 1)]), LifecycleBaselineVerdict::NotEstablished(_)));
    }
    #[test] fn uncertainty_is_sticky_and_beats_everything() {
        let t = inv_with(&[(23, G | 1)]);
        let mut f = facts();
        lifecycle_baseline_note_uncertain(&mut f, "malformed inventory update".into());
        let r = lifecycle_baseline_verdict(&f, &t, &[it(G | 1, 5, 1)], 10998);
        assert!(matches!(r, LifecycleBaselineVerdict::Invalid(ref w) if w.contains("malformed inventory update")));
        f.parsed_updates += 100;
        assert!(matches!(lifecycle_baseline_verdict(&f, &t, &[it(G | 1, 5, 1)], 10998), LifecycleBaselineVerdict::Invalid(_)));
    }

    // ---- wait loop
    #[test] fn wait_loop_resolves_transient_not_established_within_bound() {
        let mut barriers = 0; let mut calls = 0;
        let r = lifecycle_baseline_wait_loop(8, |_| { barriers += 1; Ok(()) }, || { calls += 1; if calls < 3 { LifecycleBaselineVerdict::NotEstablished("x".into()) } else { LifecycleBaselineVerdict::Absent } }, || {});
        assert_eq!(r, Ok(LifecycleBaselineVerdict::Absent)); assert_eq!(barriers, 3);
    }
    #[test] fn wait_loop_never_upgrades_unknown_to_absent_and_is_bounded() {
        let mut barriers = 0;
        let r = lifecycle_baseline_wait_loop(8, |_| { barriers += 1; Ok(()) }, || LifecycleBaselineVerdict::NotEstablished("x".into()), || {}).unwrap();
        assert!(matches!(r, LifecycleBaselineVerdict::NotEstablished(_))); assert_eq!(barriers, 8);
    }
    #[test] fn wait_loop_stops_immediately_on_present_or_invalid_and_propagates_errors() {
        let mut b = 0;
        assert_eq!(lifecycle_baseline_wait_loop(8, |_| { b += 1; Ok(()) }, || LifecycleBaselineVerdict::Present(vec![(1, 1)]), || {}), Ok(LifecycleBaselineVerdict::Present(vec![(1, 1)])));
        assert_eq!(b, 1);
        assert!(lifecycle_baseline_wait_loop(8, |_| Err("socket".into()), || LifecycleBaselineVerdict::Absent, || {}).is_err());
    }

    // ---- scanner helpers
    fn pg(g: u64) -> Vec<u8> { // packed guid
        let mut m = 0u8; let mut b = Vec::new();
        for i in 0..8 { let x = ((g >> (8 * i)) & 0xff) as u8; if x != 0 { m |= 1 << i; b.push(x); } }
        let mut v = vec![m]; v.extend(b); v
    }
    fn body(count: u32, blocks: &[Vec<u8>]) -> Vec<u8> {
        let mut v = count.to_le_bytes().to_vec(); v.push(0);
        for b in blocks { v.extend(b); }
        v
    }
    fn values_block(g: u64, set_bits: u32) -> Vec<u8> { // 1 mask word with `set_bits` low bits
        let mut v = vec![0u8]; v.extend(pg(g)); v.push(1);
        let mask = if set_bits >= 32 { u32::MAX } else { (1u32 << set_bits) - 1 };
        v.extend(mask.to_le_bytes());
        for i in 0..set_bits { v.extend((i + 1).to_le_bytes()); }
        v
    }
    fn create_block(g: u64) -> Vec<u8> { let mut v = vec![3u8]; v.extend(pg(g)); v.extend([3u8, 0x70, 1, 2, 3, 4, 5, 6, 7, 8]); v }
    fn oor_block(gs: &[u64]) -> Vec<u8> { let mut v = vec![4u8]; v.extend((gs.len() as u32).to_le_bytes()); for g in gs { v.extend(pg(*g)); } v }
    const CREATURE: u64 = 0xF130_0000_0000_0042;
    const ITEM: u64 = 0x4000_0000_0000_0777;
    fn stored_zlib(raw: &[u8]) -> Vec<u8> { // stored-block zlib stream (no compressor needed)
        let mut v = vec![0x78, 0x01, 0x01];
        v.extend((raw.len() as u16).to_le_bytes()); v.extend((!(raw.len() as u16)).to_le_bytes());
        v.extend(raw); v.extend([0, 0, 0, 0]); v
    }
    fn compressed_payload(raw: &[u8]) -> Vec<u8> { let mut p = (raw.len() as u32).to_le_bytes().to_vec(); p.extend(stored_zlib(raw)); p }

    // ---- scanner: irrelevant vs relevant
    #[test] fn creature_values_update_is_irrelevant() {
        let b = body(1, &[values_block(CREATURE, 3)]);
        assert_eq!(lifecycle_classify_unparsed_update(false, &b, ME), LifecycleUnparsed::Irrelevant);
        assert_eq!(lifecycle_classify_unparsed_update(true, &compressed_payload(&b), ME), LifecycleUnparsed::Irrelevant);
    }
    #[test] fn other_player_and_gameobject_updates_are_irrelevant() {
        let b = body(2, &[values_block(0x99, 2), values_block(0xF110_0000_0000_0001, 1)]);
        assert_eq!(lifecycle_classify_unparsed_update(false, &b, ME), LifecycleUnparsed::Irrelevant);
    }
    #[test] fn item_or_self_update_is_relevant() {
        let b = body(1, &[values_block(ITEM, 2)]);
        assert!(matches!(lifecycle_classify_unparsed_update(false, &b, ME), LifecycleUnparsed::Relevant(_)));
        let b = body(1, &[values_block(ME, 2)]);
        assert!(matches!(lifecycle_classify_unparsed_update(true, &compressed_payload(&b), ME), LifecycleUnparsed::Relevant(_)));
    }
    #[test] fn out_of_range_of_item_is_relevant_creature_is_not() {
        assert_eq!(lifecycle_classify_unparsed_update(false, &body(1, &[oor_block(&[CREATURE, 0x77])]), ME), LifecycleUnparsed::Irrelevant);
        assert!(matches!(lifecycle_classify_unparsed_update(false, &body(1, &[oor_block(&[CREATURE, ITEM])]), ME), LifecycleUnparsed::Relevant(_)));
    }
    #[test] fn last_create_block_of_creature_is_irrelevant_but_not_mid_packet() {
        assert_eq!(lifecycle_classify_unparsed_update(false, &body(1, &[create_block(CREATURE)]), ME), LifecycleUnparsed::Irrelevant);
        assert_eq!(lifecycle_classify_unparsed_update(false, &body(2, &[values_block(CREATURE, 1), create_block(CREATURE)]), ME), LifecycleUnparsed::Irrelevant);
        assert!(matches!(lifecycle_classify_unparsed_update(false, &body(2, &[create_block(CREATURE), values_block(CREATURE, 1)]), ME), LifecycleUnparsed::Relevant(_)));
    }
    #[test] fn create_block_of_item_is_relevant() {
        assert!(matches!(lifecycle_classify_unparsed_update(false, &body(1, &[create_block(ITEM)]), ME), LifecycleUnparsed::Relevant(_)));
    }
    #[test] fn malformed_inputs_fail_closed() {
        let good = body(1, &[values_block(CREATURE, 3)]);
        assert!(matches!(lifecycle_classify_unparsed_update(false, &[], ME), LifecycleUnparsed::Relevant(_)));
        assert!(matches!(lifecycle_classify_unparsed_update(false, &good[..good.len() - 1], ME), LifecycleUnparsed::Relevant(_)));
        let mut trailing = good.clone(); trailing.push(0);
        assert!(matches!(lifecycle_classify_unparsed_update(false, &trailing, ME), LifecycleUnparsed::Relevant(_)));
        let mut zero_count = good.clone(); zero_count[0] = 0;
        assert!(matches!(lifecycle_classify_unparsed_update(false, &zero_count, ME), LifecycleUnparsed::Relevant(_)));
        let mut bad_type = good.clone(); bad_type[5] = 9;
        assert!(matches!(lifecycle_classify_unparsed_update(false, &bad_type, ME), LifecycleUnparsed::Relevant(_)));
        // declared size lies / corrupt zlib / truncated
        let mut p = compressed_payload(&good); p[0] = p[0].wrapping_add(1);
        assert!(matches!(lifecycle_classify_unparsed_update(true, &p, ME), LifecycleUnparsed::Relevant(_)));
        let mut p = compressed_payload(&good); p[4] = 0x00;
        assert!(matches!(lifecycle_classify_unparsed_update(true, &p, ME), LifecycleUnparsed::Relevant(_)));
        assert!(matches!(lifecycle_classify_unparsed_update(true, &[1, 2, 3], ME), LifecycleUnparsed::Relevant(_)));
    }
    #[test] fn relevant_reason_carries_diagnostic_head() {
        match lifecycle_classify_unparsed_update(false, &body(1, &[values_block(ITEM, 1)]), ME) {
            LifecycleUnparsed::Relevant(w) => assert!(w.contains("head=") && w.contains("item/container")),
            other => panic!("{other:?}"),
        }
    }

    // ---- container walker
    fn mask_block(fields: &[(u16, u32)]) -> Vec<u8> {
        let nb = fields.iter().map(|(f, _)| *f as usize / 32 + 1).max().unwrap_or(0);
        let mut masks = vec![0u32; nb];
        let mut sorted = fields.to_vec(); sorted.sort();
        for (f, _) in &sorted { masks[*f as usize / 32] |= 1 << (*f % 32); }
        let mut v = vec![nb as u8];
        for m in &masks { v.extend(m.to_le_bytes()); }
        for (_, val) in &sorted { v.extend(val.to_le_bytes()); }
        v
    }
    fn container_fields(num: u32, contents: &[(usize, u64)]) -> Vec<(u16, u32)> {
        let mut f = vec![(48u16, num)];
        for (i, g) in contents { f.push((50 + 2 * *i as u16, *g as u32)); f.push((51 + 2 * *i as u16, (*g >> 32) as u32)); }
        f
    }
    fn container_create_block(g: u64, fields: &[(u16, u32)]) -> Vec<u8> {
        let mut v = vec![3u8]; v.extend(pg(g)); v.push(2); v.push(0x18); v.extend([0u8; 8]); v.extend(mask_block(fields)); v
    }
    fn item_create_block(g: u64) -> Vec<u8> {
        let mut v = vec![3u8]; v.extend(pg(g)); v.push(1); v.push(0x18); v.extend([0u8; 8]); v.extend(mask_block(&[(6, 1), (14, 3)])); v
    }
    fn container_values_block(g: u64, fields: &[(u16, u32)]) -> Vec<u8> { let mut v = vec![0u8]; v.extend(pg(g)); v.extend(mask_block(fields)); v }
    fn living_create_block(g: u64) -> Vec<u8> { let mut v = vec![3u8]; v.extend(pg(g)); v.push(4); v.push(0x71); v.extend([0u8; 40]); v }

    #[test] fn walker_decodes_container_create_and_values_delta() {
        let bagg = G | 100;
        let b = body(3, &[item_create_block(G | 1), container_create_block(bagg, &container_fields(16, &[(0, G | 2), (5, G | 3)])), container_values_block(bagg, &[(50 + 2 * 5, 0), (51 + 2 * 5, 0)])]);
        let w = lifecycle_walk_inventory_blocks(&b);
        assert_eq!(w.stopped_at, None, "{}", w.reason);
        assert_eq!(w.events.len(), 2);
        let mut t = LifecycleInvTracker::default();
        t.player_create(&slots(&[(19, bagg)]));
        for e in &w.events { t.apply_event(e); }
        // slot 5 was emptied by the delta; slot 0 remains
        assert_eq!(v(&t, &[bag(bagg), it(G | 2, 4306, 1)]), LifecycleBaselineVerdict::Absent);
        let c = &t.containers[&bagg];
        assert!(c.created && c.num_slots == Some(16) && c.slot(0) == Some(G | 2) && c.slot(5) == Some(0));
    }
    #[test] fn walker_works_on_compressed_payload() {
        let bagg = G | 100;
        let b = body(1, &[container_create_block(bagg, &container_fields(4, &[(1, G | 9)]))]);
        let w = lifecycle_walk_update_payload(true, &compressed_payload(&b));
        assert_eq!(w.stopped_at, None, "{}", w.reason);
        assert!(matches!(&w.events[0], LifecycleInvEvent::ContainerCreate { guid, .. } if *guid == bagg));
    }
    #[test] fn walker_stops_at_living_block_and_reports_index() {
        let b = body(3, &[container_create_block(G | 100, &container_fields(4, &[])), living_create_block(CREATURE), container_create_block(G | 101, &container_fields(4, &[]))]);
        let w = lifecycle_walk_inventory_blocks(&b);
        assert_eq!(w.stopped_at, Some(1));
        assert_eq!(w.events.len(), 1, "only the block before the stop is trusted");
    }
    #[test] fn walker_fails_closed_on_truncation_trailing_and_unknown_type() {
        let good = body(1, &[container_create_block(G | 100, &container_fields(4, &[(0, G | 5)]))]);
        assert_eq!(lifecycle_walk_inventory_blocks(&good).stopped_at, None);
        assert!(lifecycle_walk_inventory_blocks(&good[..good.len() - 2]).stopped_at.is_some());
        let mut trailing = good.clone(); trailing.push(0);
        assert!(lifecycle_walk_inventory_blocks(&trailing).stopped_at.is_some());
        let mut bad = good.clone(); bad[5] = 9;
        assert!(lifecycle_walk_inventory_blocks(&bad).stopped_at.is_some());
        assert!(lifecycle_walk_inventory_blocks(&[]).stopped_at.is_some());
    }
    #[test] fn walker_skips_creature_values_and_out_of_range() {
        let b = body(2, &[values_block(CREATURE, 3), oor_block(&[CREATURE, ITEM])]);
        let w = lifecycle_walk_inventory_blocks(&b);
        assert_eq!(w.stopped_at, None, "{}", w.reason);
        assert!(w.events.is_empty());
    }

    // ---- inflate against real zlib output (generated with python zlib levels 0/1/9)
    fn unhex(s: &str) -> Vec<u8> { (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect() }
    #[test] fn inflate_matches_real_zlib_fixed_and_dynamic() {
        for (e, zh) in [
        // (expected plaintext hex, real zlib stream hex) generated with python zlib: fixed / dynamic / stored
        ("576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a6563742031303939382031303939", "78010bcf0f5730d43334d23354282d48492c4955c84fca4a4d2e5108c7256168606969012601216a116f"),
        ("33652032613164616362203164303262336461643065633063626333333163636161646463636520643264636430656120306363656220653333613320626520653120633131636165612030613230203033613161633364626431203220326531623320656130626420323320632065326265206563626365316361623332306164332065313063616131206463336330626330206361306563313363323131203165653130636230326331206362316532323220622033616520326531656520633361313265206531653220206520302063312020326332636420316562306333333230653332656164633331336364636131646361636220633164326130312030336233646420612030653062322061323365626532322033652063303033322031636333303331646333622061306220333332632033303030643165313030633333656531653061206531656331616233316465616330613132326564316164316563656531333132336261636565322033653261312020336361616532316232646130303333313031306465576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420", "78dad550b96d43510c5b851318a2d4c493b8d6d5a4f946e2ec1fbe320132409a7780e2a5587872b20b1cf38ac9b16debea087667ce742fc6a705244cbfc24664a0164b34d97990748345323ba68670f8b2029b56030f34d60f47e22b4e855b8e709a7c88e968ab36742a02a39d04f7c065de722aaebba310b9477c172d433f39d68185c804bcbd47d432b570dbf04da94b725a6dfbd46d8ea75189557aa0fc6be5488f2db920a46d160e6d212cc48a829a408a8d30b3a1a21d07455ccb93a1a9569ccd36c5f21da6a65a03418f4abd8eb2560e844aafb37c523e41a3cd3eae0778a3df88afe7e46b71d5fbf60b7f02b4fbfdedc7f9b1cfebf3f5ebfa7fc2df5496c086"),
        ("576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420", "7801010b01f4fe576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420576f5720312e31322e3120757064617465206f626a65637420576f5720312e31322e3120757064617465206f626a656374203130393938203130393938203130393938207265706f7374207265706f7374207265706f737420301b5179"),
        ] {
            let expect = unhex(e);
            let z = unhex(zh);
            assert_eq!(lifecycle_zlib_inflate(&z, 1 << 20).unwrap(), expect);
        }
    }
    #[test] fn inflate_rejects_garbage_and_enforces_limit() {
        assert!(lifecycle_zlib_inflate(&[0x78, 0x9c, 0xff, 0xff, 0xff], 1 << 20).is_err());
        assert!(lifecycle_zlib_inflate(&[0x00, 0x00], 10).is_err());
        let z = stored_zlib(&[7u8; 64]);
        assert!(lifecycle_zlib_inflate(&z, 10).is_err());
        assert_eq!(lifecycle_zlib_inflate(&z, 64).unwrap(), vec![7u8; 64]);
    }

    // ---- bounded read-only settle (delayed update / timeout / merge / ambiguous)
    #[test] fn delayed_update_settles_within_bound_without_extra_polls() {
        let mut polls = 0; let mut pauses = 0;
        let seq = [LifecycleSettleStep::Pending, LifecycleSettleStep::Pending, LifecycleSettleStep::Exact(77)];
        let r = lifecycle_settle_loop(8, |r| { polls += 1; Ok(r as usize) }, |i| seq[*i].clone(), || pauses += 1);
        assert_eq!(r, Ok(77)); assert_eq!(polls, 3); assert_eq!(pauses, 2);
    }
    #[test] fn settle_timeout_is_hard_error_after_exactly_n_polls() {
        let mut polls = 0;
        let r = lifecycle_settle_loop(8, |_| { polls += 1; Ok(()) }, |_| LifecycleSettleStep::Pending, || {});
        assert!(r.unwrap_err().contains("not observed within bounded"));
        assert_eq!(polls, 8);
    }
    #[test] fn merge_and_ambiguous_stop_immediately() {
        let mut polls = 0;
        let r = lifecycle_settle_loop(8, |_| { polls += 1; Ok(()) }, |_| LifecycleSettleStep::Merged, || {});
        assert!(r.unwrap_err().contains("MERGED")); assert_eq!(polls, 1);
        let r = lifecycle_settle_loop(8, |_| Ok(()), |_| LifecycleSettleStep::Ambiguous("two".into()), || {});
        assert!(r.unwrap_err().contains("ambiguous"));
    }
    #[test] fn poll_error_propagates_without_retry() {
        let mut polls = 0;
        let r: Result<u64, String> = lifecycle_settle_loop(8, |_| { polls += 1; Err::<(), _>("socket".to_string()) }, |_| LifecycleSettleStep::Pending, || {});
        assert_eq!(r, Err("socket".to_string())); assert_eq!(polls, 1);
    }
}
