//! Reusable pure-logic APIs for the headless summon service.

pub mod destination_registry;
pub mod tele08_bc_adapter;
pub mod tele08_whisper_parser;
pub mod tele11_executor_contract;
pub mod tele11_service_core;
pub mod tele_response_engine;

#[cfg(test)]
mod tele08_bc_adapter_tests;
#[cfg(test)]
mod tele08_whisper_parser_tests;
