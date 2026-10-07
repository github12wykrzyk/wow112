from pathlib import Path

path = Path('probes/Wow112HeadlessAndroid/src/bin/tele09_full_teleport.rs')
s = path.read_text(encoding='utf-8')

old = '''            let status = format!(
                "result=PASS\\nchain=party>ritual>portal_use>SMSG_SUMMON_REQUEST>CMSG_SUMMON_RESPONSE>SMSG_NEW_WORLD>MSG_MOVE_WORLDPORT_ACK\\ncustomer_account={}\\ncustomer_character={}\\nsummoner={}\\ndetail={}\\n",
                CUSTOMER_ACCOUNT,
                CUSTOMER_CHARACTER,
                SUMMONER_CHARACTER,
                sanitize(&detail)
            );'''
new = '''            let teleport_mode = if detail.contains("MSG_MOVE_TELEPORT_ACK") {
                "near"
            } else {
                "far"
            };
            let status = format!(
                "result=PASS\\nchain=party>ritual>portal_use>SMSG_SUMMON_REQUEST>CMSG_SUMMON_RESPONSE>teleport_instruction>teleport_ack\\nteleport_mode={}\\ncustomer_account={}\\ncustomer_character={}\\nsummoner={}\\ndetail={}\\n",
                teleport_mode,
                CUSTOMER_ACCOUNT,
                CUSTOMER_CHARACTER,
                SUMMONER_CHARACTER,
                sanitize(&detail)
            );'''
if old not in s:
    raise SystemExit('status anchor missing')
s = s.replace(old, new, 1)

old = '''    const CMSG_SUMMON_RESPONSE_OPCODE: u32 = 0x02AC;
    const SMSG_NEW_WORLD_OPCODE: u16 = 0x003E;
    const MSG_MOVE_WORLDPORT_ACK_OPCODE: u32 = 0x00DC;'''
new = '''    const CMSG_SUMMON_RESPONSE_OPCODE: u32 = 0x02AC;
    const SMSG_NEW_WORLD_OPCODE: u16 = 0x003E;
    const MSG_MOVE_TELEPORT_ACK_OPCODE: u16 = 0x00C7;
    const MSG_MOVE_WORLDPORT_ACK_OPCODE: u32 = 0x00DC;'''
if old not in s:
    raise SystemExit('opcode anchor missing')
s = s.replace(old, new, 1)

old = '''        tele_trace::set_local_guid(selected.guid.guid());
        CMSG_PLAYER_LOGIN {
            guid: selected.guid,
        }'''
new = '''        let local_guid = selected.guid.guid();
        tele_trace::set_local_guid(local_guid);
        CMSG_PLAYER_LOGIN {
            guid: selected.guid,
        }'''
if old not in s:
    raise SystemExit('local guid anchor missing')
s = s.replace(old, new, 1)

marker = '''                    if summon_response_committed && opcode == SMSG_NEW_WORLD_OPCODE {'''
near = '''                    if summon_response_committed && opcode == MSG_MOVE_TELEPORT_ACK_OPCODE {
                        let movement_counter = match parse_raw_server_message(opcode, &payload) {
                            Ok(ServerOpcodeMessage::MSG_MOVE_TELEPORT_ACK(message)) => {
                                message.movement_counter
                            }
                            Ok(other) => {
                                return Err(format!(
                                    "opcode 0x00C7 parsed as unexpected message: {other:?}"
                                ));
                            }
                            Err(error) => {
                                return Err(format!(
                                    "MSG_MOVE_TELEPORT_ACK parse failed bytes={} error={error}",
                                    payload.len()
                                ));
                            }
                        };

                        let mut ack = Vec::with_capacity(16);
                        ack.extend_from_slice(&local_guid.to_le_bytes());
                        ack.extend_from_slice(&movement_counter.to_le_bytes());
                        ack.extend_from_slice(&0u32.to_le_bytes());

                        write_state(
                            state_path,
                            "NEAR_TELEPORT_ACK_COMMITTED",
                            &format!(
                                "opcode=0x00C7 local_guid=0x{local_guid:016X} movement_counter={movement_counter} retry_allowed=false"
                            ),
                        )?;
                        if let Err(error) = write_encrypted_raw(
                            stream,
                            crypto.encrypter(),
                            MSG_MOVE_TELEPORT_ACK_OPCODE as u32,
                            &ack,
                        ) {
                            write_state(
                                state_path,
                                "FAIL_NEAR_TELEPORT_ACK_UNCERTAIN",
                                &format!(
                                    "write failed after commit retry_allowed=false cause={error}"
                                ),
                            )?;
                            return Err(format!(
                                "MSG_MOVE_TELEPORT_ACK client mutation uncertain retry_allowed=false cause={error}"
                            ));
                        }

                        let detail = format!(
                            "MSG_MOVE_TELEPORT_ACK server received movement_counter={movement_counter}; MSG_MOVE_TELEPORT_ACK client sent local_guid=0x{local_guid:016X}"
                        );
                        write_state(state_path, "PASS_SUMMON_TELEPORTED", &detail)?;
                        println!("[TELE09-CUSTOMER] PASS {detail}");
                        return Ok(());
                    }

'''
if marker not in s:
    raise SystemExit('near teleport insertion anchor missing')
s = s.replace(marker, near + marker, 1)

path.write_text(s, encoding='utf-8')
print('TELE09_NEAR_TELEPORT_PATCH_APPLIED')
