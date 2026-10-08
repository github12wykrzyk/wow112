use std::env;
use std::fs;
use std::path::PathBuf;

use tele08_request_queue::{QueueConfig, QueueEngine, ResourceKey};
use wow112_headless_android_probe::tele08_bc_adapter::{
    classification_to_request, AdmissionRejection,
};
use wow112_headless_android_probe::tele08_whisper_parser::{
    classify_whisper, ParserConfig, WhisperObservation,
};

#[derive(Clone, Copy)]
struct ExpectedCase {
    id: usize,
    text: &'static str,
    queue_outcome: &'static str,
}

const CASES: [ExpectedCase; 12] = [
    ExpectedCase {
        id: 1,
        text: "+",
        queue_outcome: "missing_destination",
    },
    ExpectedCase {
        id: 2,
        text: "+ hyjal",
        queue_outcome: "queued",
    },
    ExpectedCase {
        id: 3,
        text: "inv pls",
        queue_outcome: "missing_destination",
    },
    ExpectedCase {
        id: 4,
        text: "invi",
        queue_outcome: "missing_destination",
    },
    ExpectedCase {
        id: 5,
        text: "I need one",
        queue_outcome: "missing_destination",
    },
    ExpectedCase {
        id: 6,
        text: "here",
        queue_outcome: "non_queueable",
    },
    ExpectedCase {
        id: 7,
        text: "winterspring pls",
        queue_outcome: "queued",
    },
    ExpectedCase {
        id: 8,
        text: "do you have feralas?",
        queue_outcome: "non_queueable",
    },
    ExpectedCase {
        id: 9,
        text: "selling summons cheaper today",
        queue_outcome: "non_queueable",
    },
    ExpectedCase {
        id: 10,
        text: "what level are you?",
        queue_outcome: "non_queueable",
    },
    ExpectedCase {
        id: 11,
        text: "sumon plz???",
        queue_outcome: "non_queueable",
    },
    ExpectedCase {
        id: 12,
        text: "azshara please",
        queue_outcome: "queued",
    },
];

fn main() {
    if let Err(error) = run() {
        eprintln!("TELE08_BC_LIVE_GATE_FAIL reason={error}");
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
    let parser = ParserConfig::default();

    let mut timestamp_ms = 1_000_000u64;
    for (index, (sender, text)) in observations.iter().enumerate() {
        let expected = CASES[index];
        if text != expected.text {
            return Err(format!(
                "case {} raw live text mismatch expected={:?} actual={:?}",
                expected.id, expected.text, text
            ));
        }

        let classification = classify_whisper(
            &WhisperObservation {
                sender: sender.clone(),
                text: text.clone(),
                timestamp_ms,
                source_role: Some("SUMMONER_LIVE_EVIDENCE".into()),
                destination_context: None,
            },
            &parser,
        );
        timestamp_ms = timestamp_ms.saturating_add(20_000);

        let actual = match classification_to_request(&classification) {
            Ok(request) => {
                let outcome = queue.enqueue(request);
                if outcome.accepted {
                    "queued"
                } else if outcome.duplicate_of.is_some() {
                    "duplicate"
                } else {
                    "queue_rejected"
                }
            }
            Err(AdmissionRejection::MissingDestination) => "missing_destination",
            Err(AdmissionRejection::NonQueueableIntent(_)) => "non_queueable",
        };

        println!(
            "TELE08_BC_LIVE_CASE id={} sender={:?} raw={:?} intent={:?} destination={} expected_queue={} actual_queue={} result={}",
            expected.id,
            sender,
            text,
            classification.intent,
            classification
                .destination
                .as_ref()
                .map(|d| d.0.as_str())
                .unwrap_or("-"),
            expected.queue_outcome,
            actual,
            if actual == expected.queue_outcome { "PASS" } else { "FAIL" }
        );

        if actual != expected.queue_outcome {
            return Err(format!(
                "case {} queue mismatch expected={} actual={}",
                expected.id, expected.queue_outcome, actual
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

    println!(
        "TELE08_BC_LIVE_GATE_PASS observations={} queued=3 hyjal={} winterspring={} azshara={} invariants=OK",
        observations.len(), hyjal, winterspring, azshara
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
    fn live_contract_has_exactly_three_queueable_destinations() {
        let queued: Vec<_> = CASES
            .iter()
            .filter(|case| case.queue_outcome == "queued")
            .map(|case| case.id)
            .collect();
        assert_eq!(queued, vec![2, 7, 12]);
    }
}
