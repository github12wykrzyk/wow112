use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutorRuntimeState {
    pub state: String,
    pub session: u32,
    pub detail: String,
}

impl ExecutorRuntimeState {
    pub fn connecting() -> Self {
        Self {
            state: "CONNECTING".to_string(),
            session: 0,
            detail: "state file not published yet".to_string(),
        }
    }
}

pub fn parse_executor_runtime_state(text: &str) -> ExecutorRuntimeState {
    let mut parsed = ExecutorRuntimeState::connecting();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "state" => parsed.state = value.trim().to_string(),
            "session" => parsed.session = value.trim().parse().unwrap_or(0),
            "detail" => parsed.detail = value.trim().to_string(),
            _ => {}
        }
    }
    parsed
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutorVerdictClass {
    Pass,
    SafePreActive,
    UncertainDoNotReplay,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutorVerdict {
    pub class: ExecutorVerdictClass,
    pub code: String,
    pub detail: String,
}

pub fn is_clicker_uncertain_state(state: &str) -> bool {
    matches!(
        state,
        "FAIL_PORTAL_MUTATION_UNCERTAIN"
            | "FAIL_AUTO_POSITION_UNCERTAIN"
            | "FAIL_AUTO_POSITION_ALREADY_ATTEMPTED"
    )
}

pub fn is_clicker_terminal_state(state: &str) -> bool {
    matches!(
        state,
        "FAIL_PORTAL_OUT_OF_RANGE"
            | "FAIL_PORTAL_RANGE_UNKNOWN"
            | "FAIL_AUTO_POSITION_LIMIT"
            | "FAIL_AUTO_POSITION_UNCERTAIN"
            | "FAIL_AUTO_POSITION_ALREADY_ATTEMPTED"
            | "FAIL_PORTAL_MUTATION_UNCERTAIN"
    )
}

pub fn logs_have_uncertain_marker(stdout: &str, stderr: &str) -> bool {
    let joined = format!("{stdout}\n{stderr}");
    [
        "TELE06A_INVITE_MUTATION_UNCERTAIN",
        "TELE06A_SELECTION_MUTATION_UNCERTAIN",
        "TELE06A_CAST_MUTATION_UNCERTAIN",
        "TELE06B_PORTAL_MUTATION_UNCERTAIN",
        "TELE06C_MOVE_MUTATION_UNCERTAIN",
    ]
    .iter()
    .any(|needle| joined.contains(needle))
}

pub fn classify_external_executor(
    summoner: &ExecutorRuntimeState,
    clicker1: &ExecutorRuntimeState,
    clicker2: &ExecutorRuntimeState,
    active_phase: bool,
    offered_stable: bool,
    uncertain_marker_seen: bool,
    child_exited: bool,
    timed_out: bool,
) -> Option<ExecutorVerdict> {
    if !active_phase {
        if child_exited || timed_out {
            return Some(ExecutorVerdict {
                class: ExecutorVerdictClass::SafePreActive,
                code: "FAIL_SAFE_PRE_ACTIVE".to_string(),
                detail: "controlled clickers failed before summoner activation; safe retry allowed"
                    .to_string(),
            });
        }
        return None;
    }

    if uncertain_marker_seen || child_exited || timed_out {
        return Some(ExecutorVerdict {
            class: ExecutorVerdictClass::UncertainDoNotReplay,
            code: if timed_out {
                "FAIL_ACTIVE_TIMEOUT"
            } else if child_exited {
                "FAIL_ACTIVE_ROLE_EXITED"
            } else {
                "FAIL_MUTATION_UNCERTAIN"
            }
            .to_string(),
            detail: "active summon path has uncertain outcome; automatic replay forbidden"
                .to_string(),
        });
    }

    if summoner.state == "FAIL_SERVER_REJECT" {
        return Some(ExecutorVerdict {
            class: ExecutorVerdictClass::UncertainDoNotReplay,
            code: "FAIL_SERVER_REJECT_ACTIVE".to_string(),
            detail: format!(
                "spell 698 was attempted and rejected; conservative no-replay: {}",
                summoner.detail
            ),
        });
    }

    for (label, state) in [("CLICKER1", clicker1), ("CLICKER2", clicker2)] {
        if is_clicker_terminal_state(&state.state) {
            return Some(ExecutorVerdict {
                class: ExecutorVerdictClass::UncertainDoNotReplay,
                code: state.state.clone(),
                detail: format!(
                    "{label} failed after active ritual path started; external summon outcome may be partial"
                ),
            });
        }
    }

    if offered_stable
        && summoner.state == "PASS_RITUAL_STARTED"
        && clicker1.state == "PORTAL_USE_SENT"
        && clicker2.state == "PORTAL_USE_SENT"
    {
        return Some(ExecutorVerdict {
            class: ExecutorVerdictClass::Pass,
            code: "PASS_SUMMON_OFFERED".to_string(),
            detail: "ritual started and both controlled portal uses were sent; external customer acceptance/teleport intentionally unobserved".to_string(),
        });
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(name: &str) -> ExecutorRuntimeState {
        ExecutorRuntimeState {
            state: name.to_string(),
            session: 1,
            detail: String::new(),
        }
    }

    #[test]
    fn external_customer_success_is_offer_not_teleport_claim() {
        let verdict = classify_external_executor(
            &state("PASS_RITUAL_STARTED"),
            &state("PORTAL_USE_SENT"),
            &state("PORTAL_USE_SENT"),
            true,
            true,
            false,
            false,
            false,
        )
        .unwrap();
        assert_eq!(verdict.class, ExecutorVerdictClass::Pass);
        assert_eq!(verdict.code, "PASS_SUMMON_OFFERED");
        assert!(verdict.detail.contains("intentionally unobserved"));
    }

    #[test]
    fn pre_active_clicker_failure_is_retryable() {
        let verdict = classify_external_executor(
            &state("CONNECTING"),
            &state("CONNECTING"),
            &state("CONNECTING"),
            false,
            false,
            false,
            true,
            false,
        )
        .unwrap();
        assert_eq!(verdict.class, ExecutorVerdictClass::SafePreActive);
    }

    #[test]
    fn active_exit_is_never_auto_replayed() {
        let verdict = classify_external_executor(
            &state("CAST_SENT"),
            &state("PORTAL_WAIT"),
            &state("PORTAL_WAIT"),
            true,
            false,
            false,
            true,
            false,
        )
        .unwrap();
        assert_eq!(verdict.class, ExecutorVerdictClass::UncertainDoNotReplay);
    }

    #[test]
    fn uncertain_marker_overrides_apparent_progress() {
        let verdict = classify_external_executor(
            &state("PASS_RITUAL_STARTED"),
            &state("PORTAL_USE_SENT"),
            &state("PORTAL_WAIT"),
            true,
            false,
            true,
            false,
            false,
        )
        .unwrap();
        assert_eq!(verdict.class, ExecutorVerdictClass::UncertainDoNotReplay);
    }
}
