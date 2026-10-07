use std::env;
use std::fs;
use std::path::PathBuf;

use tele08_request_queue::{QueueConfig, QueueEngine, ResourceKey};
use wow112_headless_android_probe::tele08_whisper_parser::WhisperObservation;
use wow112_headless_android_probe::tele10_message_router::{MessageRoute, Tele10MessageRouter};

#[derive(Clone, Copy)]
struct ExpectedCase {
    id: usize,
    text: &'static str,
    route_outcome: &'static str,
}

const CASES: [ExpectedCase; 12] = [
    ExpectedCase {
        id: 1,
        text: "+",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 2,
        text: "+ hyjal",
        route_outcome: "queued",
    },
    ExpectedCase {
        id: 3,
        text: "inv pls",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 4,
        text: "invi",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 5,
        text: "I need one",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 6,
        text: "here",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 7,
        text: "winterspring pls",
        route_outcome: "queued",
    },
    ExpectedCase {
        id: 8,
        text: "do you have feralas?",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 9,
        text: "selling summons cheaper today",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 10,
        text: "what level are you?",
        route_outcome: "ignore",
    },
    ExpectedCase {
        id: 11,
        text: "sumon plz???",
        route_outcome: "clarify",
    },
    ExpectedCase {
        id: 12,
        text: "azshara please",
        route_outcome: "queued",
    },
];

fn main() {
    if let Err(error) = run() {
        eprintln!("TELE10_ROUTER_LIVE_GATE_FAIL reason={error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let evidence = evidence_path()?;
    let raw = fs::read_to_string(&evidence)
        .map_err(|e| format!("read evidence {} failed: {e}", evidence.display()))?;
    let observations = parse_tsv(&raw)?;
    if observations.len() != CASES.len() {
        return Err(format!(
            "expected {} real whisper observations, got {}",
            CASES.len(),
            observations.len()
        ));
    }

    let team = ResourceKey::from("team-live");
    let mut config = QueueConfig::new(10_000, 120_000);
    config
        .map_destination_resource("hyjal", team.clone())
        .map_destination_resource("winterspring", team.clone())
        .map_destination_resource("azshara", team);
    let mut queue = QueueEngine::new(config);
    let mut router = Tele10MessageRouter::default();

    let mut timestamp_ms = 1_000_000u64;
    let mut clarification_count = 0usize;
    let mut ignored_count = 0usize;

    for (index, (sender, text)) in observations.iter().enumerate() {
        let expected = CASES[index];
        if text != expected.text {
            return Err(format!(
                "case {} raw live text mismatch expected={:?} actual={:?}",
                expected.id, expected.text, text
            ));
        }

        let route = router.handle(&WhisperObservation {
            sender: sender.clone(),
            text: text.clone(),
            timestamp_ms,
            source_role: Some("SUMMONER_LIVE_EVIDENCE".into()),
            destination_context: None,
        });
        timestamp_ms = timestamp_ms.saturating_add(20_000);

        let (actual, detail) = match route {
            MessageRoute::Request(request) => {
                let destination = request.destination.clone();
                let outcome = queue.enqueue(request);
                if outcome.accepted {
                    ("queued", format!("destination={destination}"))
                } else if outcome.duplicate_of.is_some() {
                    ("duplicate", format!("destination={destination}"))
                } else {
                    ("queue_rejected", format!("destination={destination}"))
                }
            }
            MessageRoute::Clarify { recipient, text } => {
                if recipient != *sender {
                    return Err(format!(
                        "case {} clarification recipient mismatch expected={:?} actual={:?}",
                        expected.id, sender, recipient
                    ));
                }
                if expected.id == 11 && text != "Do you want a summon?" {
                    return Err(format!(
                        "case 11 clarification text mismatch actual={text:?}"
                    ));
                }
                clarification_count += 1;
                ("clarify", format!("reply={text:?}"))
            }
            MessageRoute::Ignore { reason } => {
                ignored_count += 1;
                ("ignore", format!("reason={reason}"))
            }
        };

        println!(
            "TELE10_ROUTER_LIVE_CASE id={} sender={:?} raw={:?} expected_route={} actual_route={} detail={} result={}",
            expected.id,
            sender,
            text,
            expected.route_outcome,
            actual,
            detail,
            if actual == expected.route_outcome {
                "PASS"
            } else {
                "FAIL"
            }
        );

        if actual != expected.route_outcome {
            return Err(format!(
                "case {} route mismatch expected={} actual={}",
                expected.id, expected.route_outcome, actual
            ));
        }
    }

    queue
        .validate_invariants()
        .map_err(|e| format!("queue invariant failure: {e:?}"))?;

    let hyjal = queue.queued_count_by_destination("hyjal");
    let winterspring = queue.queued_count_by_destination("winterspring");
    let azshara = queue.queued_count_by_destination("azshara");
    if (hyjal, winterspring, azshara) != (1, 1, 1) {
        return Err(format!(
            "final queue counts mismatch hyjal={hyjal} winterspring={winterspring} azshara={azshara}"
        ));
    }
    if clarification_count != 1 {
        return Err(format!(
            "clarification count mismatch expected=1 actual={clarification_count}"
        ));
    }
    if ignored_count != 8 {
        return Err(format!(
            "ignored count mismatch expected=8 actual={ignored_count}"
        ));
    }
    if router.pending_clarifications() != 1 {
        return Err(format!(
            "pending clarification mismatch expected=1 actual={}",
            router.pending_clarifications()
        ));
    }

    println!(
        "TELE10_ROUTER_LIVE_GATE_PASS observations={} direct_queued=3 clarifications={} ignored={} pending={} hyjal={} winterspring={} azshara={} invariants=OK",
        observations.len(),
        clarification_count,
        ignored_count,
        router.pending_clarifications(),
        hyjal,
        winterspring,
        azshara
    );
    Ok(())
}

fn evidence_path() -> Result<PathBuf, String> {
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--evidence" {
            return args
                .next()
                .map(PathBuf::from)
                .ok_or_else(|| "--evidence requires a TSV path".to_string());
        }
    }
    Err("usage: tele08_bc_live_gate --evidence <sender-tab-raw_text.tsv>".to_string())
}

fn parse_tsv(raw: &str) -> Result<Vec<(String, String)>, String> {
    raw.lines()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let (sender, text) = line
                .split_once('\t')
                .ok_or_else(|| format!("evidence line {} has no TAB separator", index + 1))?;
            if sender.trim().is_empty() {
                return Err(format!("evidence line {} has empty sender", index + 1));
            }
            Ok((sender.to_string(), text.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tsv_parser_preserves_whisper_text() {
        let parsed = parse_tsv("Alice\t+ hyjal\nBob\tdo you have feralas?\n").unwrap();
        assert_eq!(
            parsed,
            vec![
                ("Alice".to_string(), "+ hyjal".to_string()),
                ("Bob".to_string(), "do you have feralas?".to_string())
            ]
        );
    }

    #[test]
    fn live_contract_has_three_direct_requests_and_one_clarification() {
        let queued: Vec<_> = CASES
            .iter()
            .filter(|case| case.route_outcome == "queued")
            .map(|case| case.id)
            .collect();
        let clarified: Vec<_> = CASES
            .iter()
            .filter(|case| case.route_outcome == "clarify")
            .map(|case| case.id)
            .collect();
        assert_eq!(queued, vec![2, 7, 12]);
        assert_eq!(clarified, vec![11]);
    }
}
