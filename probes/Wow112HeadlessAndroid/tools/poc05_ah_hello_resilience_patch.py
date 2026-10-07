from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: WORLD_POC05_RETRY_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

pattern = re.compile(
    r"fn poc05_send_auction_hello_candidates\(.*?\n\}\n\nfn poc05_probe_read_only_auction_house_candidates\(",
    re.S,
)

replacement = r'''fn poc05_send_auction_hello_candidates(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    mut discovered: HashSet<u64>,
) -> Result<(u64, u32), String> {
    if discovered.is_empty() {
        return Err("POC-05 has no auctioneer candidates".to_string());
    }

    const HELLO_TIMEOUT_SECS: u64 = 12;
    const HELLO_PACKET_SAFETY_CAP: usize = 4096;
    const HELLO_FALLBACK_AFTER_MS: u128 = 1500;
    const HELLO_RESEND_AFTER_MS: u128 = 5000;

    let configured = env::var("WOW112_AH_GUID")
        .ok()
        .and_then(|value| parse_guid_override("WOW112_AH_GUID", &value).ok())
        .filter(|guid| discovered.contains(guid));

    // Freshly discovered NPC wins. The configured GUID is only a fallback.
    let first_guid = discovered
        .iter()
        .copied()
        .find(|guid| Some(*guid) != configured)
        .or(configured)
        .unwrap_or_else(|| *discovered.iter().next().unwrap());

    let mut attempted = HashSet::new();
    let mut resent_first = false;
    let started = Instant::now();
    let mut total_packets = 0usize;
    let mut meaningful_packets = 0usize;
    let mut background_packets = 0usize;

    println!(
        "[AH-HELLO-V2] opening auction house guid=0x{first_guid:016X} seeded_candidates={} configured_fallback={} timeout={}s",
        discovered.len(),
        configured
            .map(|guid| format!("0x{guid:016X}"))
            .unwrap_or_else(|| "none".to_string()),
        HELLO_TIMEOUT_SECS
    );
    write_encrypted_raw(
        stream,
        crypto.encrypter(),
        u32::from(MSG_AUCTION_HELLO_OPCODE),
        &first_guid.to_le_bytes(),
    )?;
    attempted.insert(first_guid);

    while total_packets < HELLO_PACKET_SAFETY_CAP
        && started.elapsed() < Duration::from_secs(HELLO_TIMEOUT_SECS)
    {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        total_packets = total_packets.saturating_add(1);

        if opcode == MSG_AUCTION_HELLO_OPCODE {
            if payload.len() < 12 {
                return Err(format!(
                    "MSG_AUCTION_HELLO payload too short: {}",
                    payload.len()
                ));
            }
            let response_guid = u64::from_le_bytes(payload[0..8].try_into().unwrap());
            let auction_house = u32::from_le_bytes(payload[8..12].try_into().unwrap());
            println!(
                "[AH-HELLO-V2] PASS guid=0x{response_guid:016X} house={auction_house} attempted={} candidates={} elapsed_ms={} total_packets={} meaningful_packets={} background_packets={}",
                attempted.len(),
                discovered.len(),
                started.elapsed().as_millis(),
                total_packets,
                meaningful_packets,
                background_packets
            );
            return Ok((response_guid, auction_house));
        }

        // Compressed background updates are noisy on this server and the generic
        // vanilla parser cannot always decode their tiny payloads. They must not
        // consume the AH hello budget and are intentionally ignored here.
        if opcode == SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE {
            background_packets = background_packets.saturating_add(1);
        } else if opcode == SMSG_UPDATE_OBJECT_OPCODE {
            background_packets = background_packets.saturating_add(1);
            inspect_update_packet(opcode, &payload, &mut discovered)?;
        } else {
            meaningful_packets = meaningful_packets.saturating_add(1);
            if meaningful_packets <= 8 {
                println!(
                    "[AH-HELLO-V2-DIAG] wait meaningful={} opcode=0x{opcode:04X} payload={} attempted={} candidates={} elapsed_ms={}",
                    meaningful_packets,
                    payload.len(),
                    attempted.len(),
                    discovered.len(),
                    started.elapsed().as_millis()
                );
            }
        }

        let elapsed_ms = started.elapsed().as_millis();
        if elapsed_ms >= HELLO_FALLBACK_AFTER_MS {
            if let Some(next_guid) = discovered
                .iter()
                .copied()
                .find(|guid| !attempted.contains(guid))
            {
                println!(
                    "[AH-HELLO-V2] fallback auctioneer guid=0x{next_guid:016X} elapsed_ms={elapsed_ms}"
                );
                write_encrypted_raw(
                    stream,
                    crypto.encrypter(),
                    u32::from(MSG_AUCTION_HELLO_OPCODE),
                    &next_guid.to_le_bytes(),
                )?;
                attempted.insert(next_guid);
            }
        }

        if !resent_first && elapsed_ms >= HELLO_RESEND_AFTER_MS {
            println!(
                "[AH-HELLO-V2] one-shot resend first guid=0x{first_guid:016X} elapsed_ms={elapsed_ms}"
            );
            write_encrypted_raw(
                stream,
                crypto.encrypter(),
                u32::from(MSG_AUCTION_HELLO_OPCODE),
                &first_guid.to_le_bytes(),
            )?;
            resent_first = true;
        }
    }

    Err(format!(
        "server did not return MSG_AUCTION_HELLO before time budget; attempted={} candidates={} elapsed_ms={} total_packets={} meaningful_packets={} background_packets={} timeout_secs={}",
        attempted.len(),
        discovered.len(),
        started.elapsed().as_millis(),
        total_packets,
        meaningful_packets,
        background_packets,
        HELLO_TIMEOUT_SECS
    ))
}

fn poc05_probe_read_only_auction_house_candidates('''

new_s, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit(f'AH hello resilience patch: expected one function replacement, got {n}')

for marker in [
    '[AH-HELLO-V2]',
    'HELLO_TIMEOUT_SECS',
    'HELLO_PACKET_SAFETY_CAP',
    'SMSG_COMPRESSED_UPDATE_OBJECT_OPCODE',
    'configured_fallback',
    'Freshly discovered NPC wins',
]:
    if marker not in new_s:
        raise SystemExit('missing marker after patch: ' + marker)

p.write_text(new_s, encoding='utf-8')
print('[POC05-AH-HELLO-RESILIENCE] PASS')
