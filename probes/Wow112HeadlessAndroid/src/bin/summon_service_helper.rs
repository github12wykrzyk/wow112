include!("../world.rs");

use std::collections::HashMap;
use std::fs;
use std::net::ToSocketAddrs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use wow112_headless_android_probe::summon_group_accept_worker::GroupAcceptWorker;
use wow112_headless_android_probe::summon_portal_worker::PortalWorker;
use wow112_headless_android_probe::summon_service_core::{RequestPhase, ServiceSnapshot};

#[path = "../wire_build.rs"] mod wire_build;
#[path = "../auth.rs"] mod auth;

const DEFAULT_AUTH_ADDR: &str = "play.octowow.st:3724";
const DEFAULT_REALM_INDEX: usize = 1;
const LOGIN_WATCHDOG_MS: u64 = 3000;
const CMSG_GROUP_ACCEPT_OPCODE: u32 = 0x0072;
const SMSG_GROUP_INVITE_OPCODE: u16 = 0x006F;
const CMSG_GAMEOBJ_USE_OPCODE: u32 = 0x00B1;
const SUMMONING_PORTAL_ENTRY: i32 = 36727;
const GAMEOBJECT_TYPE_RITUAL: i32 = 18;
const DEFAULT_MAX_RANGE: f32 = 5.8;
const DEFAULT_CLICK_SETTLE_MS: u64 = 150;

fn ow_ms() -> u64 {
 SystemTime::now()
 .duration_since(UNIX_EPOCH)
 .unwrap_or_default()
 .as_millis() as u64
}

fn service_root() -> PathBuf {
 std::env::var("WOW112_SUMMON_SERVICE_ROOT")
 .map(PathBuf::from)
 .unwrap_or_else(|_| PathBuf::from("."))
}

fn send_tcp(addr: &str, data: &[u8]) -> std::io::Result
