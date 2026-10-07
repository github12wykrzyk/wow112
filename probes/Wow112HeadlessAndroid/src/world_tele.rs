// Canonical TELE transport/login/chat core is preserved bit-for-bit in the base file.
// TELE10 payment is a narrow post-summon extension; no existing summon/teleport primitive
// is reimplemented here.
include!("world_tele_base.rs");
include!("tele10_trade_service.rs");
