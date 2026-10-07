from pathlib import Path

p = Path('probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs')
s = p.read_text(encoding='utf-8')

s = s.replace(
    '    const CMSG_SUMMON_RESPONSE_OPCODE: u32 = 0x02AC;\n',
    '    const CMSG_SUMMON_RESPONSE_OPCODE: u32 = 0x02AC;\n    const MSG_MOVE_TELEPORT_ACK_OPCODE: u32 = 0x00C7;\n',
    1,
)
s = s.replace(
    '    static SUMMON_RESPONSE_SENT: AtomicBool = AtomicBool::new(false);\n',
    '    static SUMMON_RESPONSE_SENT: AtomicBool = AtomicBool::new(false);\n    static TELEPORT_ACK_SENT: AtomicBool = AtomicBool::new(false);\n',
    1,
)
s = s.replace(
    '                                    CMSG_SUMMON_RESPONSE_OPCODE,\n                                    &[],\n',
    '                                    CMSG_SUMMON_RESPONSE_OPCODE,\n                                    &summoner_guid.to_le_bytes(),\n',
    1,
)
s = s.replace('vmangos_empty_payload=true', 'payload=guid8', 1)
s = s.replace('empty payload socket write uncertain', 'guid8 payload socket write uncertain', 1)
s = s.replace('accepted vmangos summon request', 'accepted summon request', 1)
s = s.replace('payload=empty vmangos=true', 'payload=guid8', 1)

anchor = '                    if role == Tele06bRole::Customer && opcode == SMSG_NEW_WORLD_OPCODE {'
handler = r'''                    if role == Tele06bRole::Customer
                        && opcode as u32 == MSG_MOVE_TELEPORT_ACK_OPCODE
                        && SUMMON_RESPONSE_SENT.load(Ordering::SeqCst)
                    {
                        if payload.len() < 6 {
                            println!("[TELE-10-SAME-MAP-DIAG] malformed 0x00C7 bytes={}", payload.len());
                            continue;
                        }
                        let mask = payload[0];
                        let guid_len = mask.count_ones() as usize;
                        let counter_off = 1 + guid_len;
                        if payload.len() < counter_off + 4 {
                            println!("[TELE-10-SAME-MAP-DIAG] short 0x00C7 bytes={} mask=0x{mask:02X}", payload.len());
                            continue;
                        }
                        let counter = u32::from_le_bytes(payload[counter_off..counter_off + 4].try_into().unwrap());
                        if TELEPORT_ACK_SENT
                            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                            .is_ok()
                        {
                            let mut ack = Vec::with_capacity(counter_off + 8);
                            ack.extend_from_slice(&payload[..counter_off]);
                            ack.extend_from_slice(&counter.to_le_bytes());
                            ack.extend_from_slice(&tele06c_movement_timestamp().to_le_bytes());
                            publish_runner_state(
                                "TELEPORT_ACK_COMMITTED",
                                &format!("same-map 0x00C7 received counter={counter}; ack retry_allowed=false"),
                            );
                            if let Err(error) = write_encrypted_raw(
                                stream,
                                crypto.encrypter(),
                                MSG_MOVE_TELEPORT_ACK_OPCODE,
                                &ack,
                            ) {
                                publish_runner_state(
                                    "FAIL_TELEPORT_ACK_UNCERTAIN",
                                    "same-map 0x00C7 ack socket write uncertain; retry disabled",
                                );
                                return Err(format!("TELE10_TELEPORT_ACK_MUTATION_UNCERTAIN retry_allowed=false cause={error}"));
                            }
                            publish_runner_state(
                                "PASS_TELEPORT_COMPLETE",
                                &format!("same-map 0x00C7 server+client counter={counter} ack_bytes={}", ack.len()),
                            );
                            println!("[TELE-10-TELEPORT] PASS path=same_map counter={counter} ack_bytes={}", ack.len());
                        }
                        continue;
                    }

'''
if anchor not in s:
    raise SystemExit('same-map insertion anchor missing')
s = s.replace(anchor, handler + anchor, 1)

p.write_text(s, encoding='utf-8')
print('TELE10_SAME_MAP_HOTFIX_OK')
