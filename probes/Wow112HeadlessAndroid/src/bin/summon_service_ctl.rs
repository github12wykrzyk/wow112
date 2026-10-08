use std::env;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use wow112_headless_android_probe::summon_service_control::{
    ControlInbox, ServiceControlCommand,
};

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn usage() -> String {
    "usage: summon_service_ctl <root> pause|resume|shutdown|manual-whisper|portal-committed|summon-completed [args]".to_string()
}

fn arg(args: &[String], index: usize, name: &str) -> Result<String, String> {
    args.get(index)
        .cloned()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("missing {name}; {}", usage()))
}

fn run() -> Result<(), String> {
    let args = env::args().collect::<Vec<_>>();
    if args.len() < 3 {
        return Err(usage());
    }
    let root = PathBuf::from(arg(&args, 1, "root")?);
    let verb = arg(&args, 2, "command")?.to_ascii_lowercase();
    let command = match verb.as_str() {
        "pause" => ServiceControlCommand::Pause,
        "resume" => ServiceControlCommand::Resume,
        "shutdown" | "graceful-shutdown" => {
            ServiceControlCommand::GracefulShutdown { now_ms: now_ms() }
        }
        "manual-whisper" => {
            let customer = arg(&args, 3, "customer")?;
            let text = arg(&args, 4, "text")?;
            let destination_context = args
                .get(5)
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty());
            ServiceControlCommand::ManualWhisper {
                customer,
                text,
                destination_context,
                now_ms: now_ms(),
            }
        }
        "portal-committed" => ServiceControlCommand::PortalCommitted {
            request_id: arg(&args, 3, "request_id")?,
        },
        "summon-completed" => ServiceControlCommand::SummonCompleted {
            request_id: arg(&args, 3, "request_id")?,
            now_ms: now_ms(),
        },
        _ => return Err(format!("unknown command {verb:?}; {}", usage())),
    };
    let path = ControlInbox::submit(&root, &command)?;
    println!(
        "SUMMON_SERVICE_CONTROL_SUBMITTED command={} path={}",
        verb,
        path.display()
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("SUMMON_SERVICE_CONTROL_FAIL {error}");
        std::process::exit(2);
    }
}
