//! Reusable pure-logic APIs for the headless summon service.

pub mod destination_registry;
pub mod tele08_bc_adapter;
pub mod tele08_whisper_parser;
pub mod tele_response_engine;
pub mod tele10_trade_payment;
pub mod tele11_service_core;

#[cfg(test)]
mod tele08_bc_adapter_tests;
#[cfg(test)]
mod tele08_whisper_parser_tests;
#[cfg(test)]
mod tele10_message_audit_tests;
