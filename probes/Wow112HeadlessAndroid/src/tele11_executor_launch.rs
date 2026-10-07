use crate::tele11_executor_process::ExternalExecutorConfig;
use crate::tele11_process_containment::KillOnCloseJob;
use std::env;
use std::fs;
use std::process::{Command, Stdio};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContainedExecutorResult {
    Exit(i32),
    SafePreActive(String),
    Uncertain(String),
}

pub fn run_contained_executor(exec: &ExternalExecutorConfig) -> ContainedExecutorResult {
    if let Err(error) = fs::create_dir_all(&exec.run_dir) {
        return ContainedExecutorResult::SafePreActive(format!(
            "create executor run dir {} failed before spawn: {error}",
            exec.run_dir.display()
        ));
    }
    let gate = exec.run_dir.join("START.GATE");
    let _ = fs::remove_file(&gate);

    let current = match env::current_exe() {
        Ok(value) => value,
        Err(error) => {
            return ContainedExecutorResult::SafePreActive(format!(
                "resolve parent executable failed before spawn: {error}"
            ))
        }
    };
    let executor = match current.parent() {
        Some(parent) => parent.join("tele11_external_executor.exe"),
        None => {
            return ContainedExecutorResult::SafePreActive(
                "parent executable has no directory".to_string(),
            )
        }
    };
    if !executor.exists() {
        return ContainedExecutorResult::SafePreActive(format!(
            "executor binary missing before spawn: {}",
            executor.display()
        ));
    }

    let containment = match KillOnCloseJob::new() {
        Ok(job) => job,
        Err(error) => {
            return ContainedExecutorResult::SafePreActive(format!(
                "kill-on-close containment initialization failed before spawn: {error}"
            ))
        }
    };

    let mut command = Command::new(&executor);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .env("WOW112_PASSWORD", &exec.password)
        .env("WOW112_REALM_INDEX", exec.realm_index.to_string())
        .env("WOW112_TELE11_RUN_DIR", &exec.run_dir)
        .env("WOW112_TELE11_CUSTOMER_CHARACTER", &exec.customer)
        .env("WOW112_TELE11_DESTINATION", &exec.destination)
        .env("WOW112_TELE11_RESOURCE", &exec.resource)
        .env("WOW112_TELE11_SUMMONER_ACCOUNT", &exec.summoner.account)
        .env("WOW112_TELE11_SUMMONER_CHARACTER", &exec.summoner.character)
        .env("WOW112_TELE11_CLICKER1_ACCOUNT", &exec.clicker1.account)
        .env("WOW112_TELE11_CLICKER1_CHARACTER", &exec.clicker1.character)
        .env("WOW112_TELE11_CLICKER2_ACCOUNT", &exec.clicker2.account)
        .env("WOW112_TELE11_CLICKER2_CHARACTER", &exec.clicker2.character)
        .env(
            "WOW112_TELE11_READY_TIMEOUT_SECS",
            exec.ready_timeout.as_secs().to_string(),
        )
        .env(
            "WOW112_TELE11_ACTIVE_TIMEOUT_SECS",
            exec.active_timeout.as_secs().to_string(),
        )
        .env(
            "WOW112_TELE11_OFFER_SETTLE_MS",
            exec.offer_settle.as_millis().to_string(),
        )
        .env("WOW112_TELE11_START_GATE", &gate)
        .env("WOW112_TELE11_START_GATE_TIMEOUT_MS", "30000");

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return ContainedExecutorResult::SafePreActive(format!(
                "executor spawn failed before start gate: {error}"
            ))
        }
    };
    if let Err(error) = containment.assign_child(&child) {
        let _ = child.kill();
        let _ = child.wait();
        return ContainedExecutorResult::SafePreActive(format!(
            "executor containment assignment failed while gate closed: {error}"
        ));
    }
    if let Err(error) = fs::write(&gate, b"contained\n") {
        let _ = child.kill();
        let _ = child.wait();
        return ContainedExecutorResult::SafePreActive(format!(
            "publish executor start gate failed; role processes never authorized: {error}"
        ));
    }
    println!(
        "[TELE11-LAUNCH] CONTAINMENT PASS executor_pid={} gate={} kill_on_job_close=true",
        child.id(),
        gate.display()
    );

    let result = match child.wait() {
        Ok(status) => ContainedExecutorResult::Exit(status.code().unwrap_or(3)),
        Err(error) => ContainedExecutorResult::Uncertain(format!(
            "executor wait failed after start gate; containment terminates tree: {error}"
        )),
    };
    let _ = fs::remove_file(&gate);
    drop(containment);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn result_classes_are_explicit() {
        assert_eq!(ContainedExecutorResult::Exit(0), ContainedExecutorResult::Exit(0));
        assert!(matches!(
            ContainedExecutorResult::SafePreActive("x".into()),
            ContainedExecutorResult::SafePreActive(_)
        ));
        assert!(matches!(
            ContainedExecutorResult::Uncertain("x".into()),
            ContainedExecutorResult::Uncertain(_)
        ));
    }
}
