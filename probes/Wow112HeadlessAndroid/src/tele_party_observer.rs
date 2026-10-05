use std::io::Cursor;
use wow_world_messages::vanilla::opcodes::ServerOpcodeMessage;

pub const SMSG_GROUP_INVITE_OPCODE: u16 = 0x006F;
pub const SMSG_GROUP_CANCEL_OPCODE: u16 = 0x0071;
pub const SMSG_GROUP_DECLINE_OPCODE: u16 = 0x0074;
pub const SMSG_GROUP_UNINVITE_OPCODE: u16 = 0x0077;
pub const SMSG_GROUP_SET_LEADER_OPCODE: u16 = 0x0079;
pub const SMSG_GROUP_DESTROYED_OPCODE: u16 = 0x007C;
pub const SMSG_GROUP_LIST_OPCODE: u16 = 0x007D;
pub const SMSG_PARTY_COMMAND_RESULT_OPCODE: u16 = 0x007F;
pub const UMSG_UPDATE_GROUP_MEMBERS_OPCODE: u16 = 0x0080;

fn party_event_name(opcode: u16) -> Option<&'static str> {
    match opcode {
        SMSG_GROUP_INVITE_OPCODE => Some("GROUP_INVITE"),
        SMSG_GROUP_CANCEL_OPCODE => Some("GROUP_CANCEL"),
        SMSG_GROUP_DECLINE_OPCODE => Some("GROUP_DECLINE"),
        SMSG_GROUP_UNINVITE_OPCODE => Some("GROUP_UNINVITE"),
        SMSG_GROUP_SET_LEADER_OPCODE => Some("GROUP_SET_LEADER"),
        SMSG_GROUP_DESTROYED_OPCODE => Some("GROUP_DESTROYED"),
        SMSG_GROUP_LIST_OPCODE => Some("GROUP_LIST"),
        SMSG_PARTY_COMMAND_RESULT_OPCODE => Some("PARTY_COMMAND_RESULT"),
        UMSG_UPDATE_GROUP_MEMBERS_OPCODE => Some("UPDATE_GROUP_MEMBERS"),
        _ => None,
    }
}

fn parse_party_server_message(opcode: u16, payload: &[u8]) -> Result<ServerOpcodeMessage, String> {
    let size = u16::try_from(payload.len() + 2)
        .map_err(|_| format!("party payload too large for opcode 0x{opcode:04X}"))?;
    let mut wire = Vec::with_capacity(payload.len() + 4);
    wire.extend_from_slice(&size.to_be_bytes());
    wire.extend_from_slice(&opcode.to_le_bytes());
    wire.extend_from_slice(payload);
    ServerOpcodeMessage::read_unencrypted(&mut Cursor::new(wire))
        .map_err(|e| format!("party parse opcode 0x{opcode:04X} failed: {e:?}"))
}

/// Returns true when the opcode belongs to the TELE party-observer surface.
/// TELE-03 is deliberately RX-only: this function never writes to the socket.
pub fn inspect_party_packet(opcode: u16, payload: &[u8]) -> bool {
    let Some(event) = party_event_name(opcode) else {
        return false;
    };

    match parse_party_server_message(opcode, payload) {
        Ok(message) => println!(
            "[TELE-PARTY] event={} opcode=0x{:04X} payload={} parsed={:?}",
            event,
            opcode,
            payload.len(),
            message
        ),
        Err(error) => println!(
            "[TELE-PARTY-DIAG] event={} opcode=0x{:04X} payload={} reason={}",
            event,
            opcode,
            payload.len(),
            error
        ),
    }
    true
}
