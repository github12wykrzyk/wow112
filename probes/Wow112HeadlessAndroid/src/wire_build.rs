/// OctoWoW's live login handshake reports 1.12.1 with build 7272 on the wire.
///
/// The headless client still implements the Vanilla 1.12.1 protocol and targets
/// the project's 5875 client semantics. This value is only the server-facing
/// build identifier observed from the real working OctoWoW client capture.
pub const OCTOWOW_WIRE_BUILD: u16 = 7272;
