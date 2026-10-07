from pathlib import Path

RITUAL = Path('probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs')
ACCEPTOR = Path('probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs')
SUPERVISOR = Path('probes/Wow112HeadlessAndroid/src/bin/tele07_supervisor.rs')


def replace_once(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f'PATCH_ANCHOR_MISSING {label}')
    return text.replace(old, new, 1)

s = RITUAL.read_text(encoding='utf-8')
s = replace_once(s,
    '    use super::*;\n\n    const CMSG_GROUP_INVITE_OPCODE',
    '    use super::*;\n    include!("../tele10_trade_receiver_runtime.rs");\n\n    const CMSG_GROUP_INVITE_OPCODE',
    'ritual include')
s = replace_once(s,
    '                            SMSG_SPELL_START_OPCODE => {\n                                cast_started = true;',
    '                            SMSG_SPELL_START_OPCODE => {\n                                let target_guid = *last_roster.get(&target_lower).ok_or_else(|| format!("target {target_name:?} missing at ritual start"))?;\n                                let summon_id = tele10_record_ritual_started(target_name, target_guid)?;\n                                println!("[TELE10-LEDGER] ritual_start summon_id={summon_id}");\n                                cast_started = true;',
    'ritual start ledger')
s = replace_once(s,
    '                            SMSG_SPELL_GO_OPCODE => {\n                                publish_runner_state(',
    '                            SMSG_SPELL_GO_OPCODE => {\n                                let target_guid = *last_roster.get(&target_lower).ok_or_else(|| format!("target {target_name:?} missing at ritual go"))?;\n                                let summon_id = tele10_record_ritual_started(target_name, target_guid)?;\n                                println!("[TELE10-LEDGER] ritual_go summon_id={summon_id}");\n                                publish_runner_state(',
    'ritual go ledger')
s = replace_once(s,
    '        println!("[TELE-06A] cast checkpoint complete; observer loop remains active");\n        tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;',
    '        println!("[TELE-06A] cast checkpoint complete; TELE10 trade receiver active");\n        tele10_trade_receiver_loop(stream, &mut crypto, soak_seconds, &target_name)?;',
    'ritual trade loop')
RITUAL.write_text(s, encoding='utf-8')

s = ACCEPTOR.read_text(encoding='utf-8')
s = replace_once(s,
    '    use super::*;\n\n    const CMSG_GROUP_DISBAND_OPCODE',
    '    use super::*;\n    include!("../tele10_payer_roster_runtime.rs");\n    include!("../tele10_payer_driver_runtime.rs");\n\n    const CMSG_GROUP_DISBAND_OPCODE',
    'acceptor includes')
s = replace_once(s,
    '                    tele_trace::trace_packet(role_label, opcode, &payload);\n\n                    if role == Tele06bRole::Customer && opcode == SMSG_SUMMON_REQUEST_OPCODE {',
    '                    tele_trace::trace_packet(role_label, opcode, &payload);\n                    if role == Tele06bRole::Customer {\n                        tele10_payer_observe_packet(opcode, &payload);\n                    }\n\n                    if role == Tele06bRole::Customer && opcode == SMSG_SUMMON_REQUEST_OPCODE {',
    'acceptor roster observer')
s = replace_once(s,
    '                            println!("[TELE-10-TELEPORT] PASS path=same_map counter={counter} ack_bytes={}", ack.len());\n                        }\n                        continue;',
    '                            println!("[TELE-10-TELEPORT] PASS path=same_map counter={counter} ack_bytes={}", ack.len());\n                        }\n                        tele10_customer_pay_after_teleport(stream, crypto)?;\n                        continue;',
    'same-map payment hook')
s = replace_once(s,
    '                            println!("[TELE-10-TELEPORT] PASS new_world_bytes={} worldport_ack=sent", payload.len());\n                        }\n                        continue;',
    '                            println!("[TELE-10-TELEPORT] PASS new_world_bytes={} worldport_ack=sent", payload.len());\n                        }\n                        tele10_customer_pay_after_teleport(stream, crypto)?;\n                        continue;',
    'far payment hook')
ACCEPTOR.write_text(s, encoding='utf-8')

s = SUPERVISOR.read_text(encoding='utf-8')
s = replace_once(s,
    '        "TELE06C_MOVE_MUTATION_UNCERTAIN",\n',
    '        "TELE06C_MOVE_MUTATION_UNCERTAIN",\n        "TELE10_TRADE_BEGIN_MUTATION_UNCERTAIN",\n        "TELE10_TRADE_ACCEPT_MUTATION_UNCERTAIN",\n        "TELE10_PAYER_INITIATE_UNCERTAIN",\n        "TELE10_PAYER_SET_GOLD_UNCERTAIN",\n        "TELE10_PAYER_ACCEPT_UNCERTAIN",\n        "TELE10_PAYER_SOCKET_UNCERTAIN",\n',
    'supervisor uncertainty markers')
old = '''        if customer.state == "PASS_TELEPORT_COMPLETE"\n            && slave1.state == "PORTAL_USE_SENT"\n            && slave2.state == "PORTAL_USE_SENT"\n        {\n            return CycleVerdict {\n                code: "PASS_TELEPORT_COMPLETE".to_string(),\n                detail: format!("summon accepted and far teleport completed; {}", customer.detail),\n            };\n        }'''
new = '''        let require_payment = env::var("WOW112_TELE10_REQUIRE_PAYMENT")\n            .ok()\n            .is_some_and(|value| value == "1" || value.eq_ignore_ascii_case("true"));\n        if require_payment {\n            if summoner_state.state == "PASS_PAYMENT_COMPLETE"\n                && slave1.state == "PORTAL_USE_SENT"\n                && slave2.state == "PORTAL_USE_SENT"\n            {\n                return CycleVerdict {\n                    code: "PASS_TELEPORT_PAYMENT_COMPLETE".to_string(),\n                    detail: summoner_state.detail,\n                };\n            }\n        } else if customer.state == "PASS_TELEPORT_COMPLETE"\n            && slave1.state == "PORTAL_USE_SENT"\n            && slave2.state == "PORTAL_USE_SENT"\n        {\n            return CycleVerdict {\n                code: "PASS_TELEPORT_COMPLETE".to_string(),\n                detail: format!("summon accepted and far teleport completed; {}", customer.detail),\n            };\n        }'''
s = replace_once(s, old, new, 'supervisor payment completion')
s = replace_once(s,
    '        if verdict.code == "PASS_TELEPORT_COMPLETE" {',
    '        if matches!(\n            verdict.code.as_str(),\n            "PASS_TELEPORT_COMPLETE" | "PASS_TELEPORT_PAYMENT_COMPLETE"\n        ) {',
    'supervisor pass verdict')
SUPERVISOR.write_text(s, encoding='utf-8')

print('TELE10_HEADLESS_TRADE_SOURCE_PATCH_OK')
