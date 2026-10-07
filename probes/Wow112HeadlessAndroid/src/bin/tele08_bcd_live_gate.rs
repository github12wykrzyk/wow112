use std::env;
use std::fs;
use std::path::PathBuf;

use tele08_request_queue::{QueueConfig, QueueEngine, ResourceKey};
use wow112_headless_android_probe::destination_registry::{
    Availability, DestinationId, DestinationObservation, DestinationRegistry, ManualOverride,
    TeamHealth,
};
use wow112_headless_android_probe::tele08_bc_adapter::{
    classification_to_request, AdmissionRejection,
};
use wow112_headless_android_probe::tele08_whisper_parser::{
    classify_whisper, DestinationAlias, DestinationKey, ParserConfig, WhisperObservation,
};

const SEED: &str = include_str!("../../config/tele08_destinations.example.json");

#[derive(Clone, Copy)]
struct ExpectedCase {
    id: usize,
    text: &'static str,
    outcome: &'static str,
}

const CASES: [ExpectedCase; 12] = [
    ExpectedCase { id: 1, text: "+", outcome: "missing_destination" },
    ExpectedCase { id: 2, text: "+ hyjal", outcome: "queued" },
    ExpectedCase { id: 3, text: "inv pls", outcome: "missing_destination" },
    ExpectedCase { id: 4, text: "invi", outcome: "missing_destination" },
    ExpectedCase { id: 5, text: "I need one", outcome: "missing_destination" },
    ExpectedCase { id: 6, text: "here", outcome: "non_queueable" },
    ExpectedCase { id: 7, text: "winterspring pls", outcome: "queued" },
    ExpectedCase { id: 8, text: "do you have feralas?", outcome: "non_queueable" },
    ExpectedCase { id: 9, text: "selling summons cheaper today", outcome: "non_queueable" },
    ExpectedCase { id: 10, text: "what level are you?", outcome: "non_queueable" },
    ExpectedCase { id: 11, text: "sumon plz???", outcome: "non_queueable" },
    ExpectedCase { id: 12, text: "azshara please", outcome: "queued" },
];

fn main() {
    if let Err(error) = run() {
        eprintln!("TELE08_BCD_LIVE_GATE_FAIL reason={error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let evidence = evidence_path()?;
    let raw = fs::read_to_string(&evidence)
        .map_err(|e| format!("read evidence {} failed: {e}", evidence.display()))?;
    let observations = parse_tsv(&raw)?;
    if observations.len() != CASES.len() {
        return Err(format!("expected {} observations, got {}", CASES.len(), observations.len()));
    }

    let mut registry = DestinationRegistry::from_json(SEED)
        .map_err(|e| format!("destination registry seed invalid: {e}"))?;
    for definition in registry.config().destinations.clone() {
        registry
            .set_observation(
                &definition.id,
                DestinationObservation {
                    shard_count: None,
                    manual_override: ManualOverride::Automatic,
                    team_health: TeamHealth::Healthy,
                },
            )
            .map_err(|e| format!("healthy observation failed for {}: {e}", definition.id))?;
    }

    let parser = parser_config_from_registry(&registry);
    let mut queue_config = QueueConfig::new(10_000, 120_000);
    for definition in &registry.config().destinations {
        let resource = registry
            .resource_key(&definition.id)
            .ok_or_else(|| format!("missing resource key for {}", definition.id))?;
        queue_config.map_destination_resource(definition.id.as_str(), ResourceKey::from(resource));
    }
    let mut queue = QueueEngine::new(queue_config);

    let mut timestamp_ms = 1_000_000u64;
    for (index, (sender, text)) in observations.iter().enumerate() {
        let expected = CASES[index];
        if text != expected.text {
            return Err(format!("case {} text mismatch expected={:?} actual={:?}", expected.id, expected.text, text));
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
                let destination = DestinationId::new(request.destination.clone())
                    .map_err(|e| format!("case {} invalid destination from B/C: {e}", expected.id))?;
                let status = registry
                    .status(&destination)
                    .ok_or_else(|| format!("case {} destination absent from D: {}", expected.id, destination))?;
                if status.availability != Availability::Enabled {
                    "destination_unavailable"
                } else if registry.resource_key(&destination).is_none() {
                    "missing_resource"
                } else {
                    let outcome = queue.enqueue(request);
                    if outcome.accepted { "queued" } else if outcome.duplicate_of.is_some() { "duplicate" } else { "queue_rejected" }
                }
            }
            Err(AdmissionRejection::MissingDestination) => "missing_destination",
            Err(AdmissionRejection::NonQueueableIntent(_)) => "non_queueable",
        };

        println!(
            "TELE08_BCD_LIVE_CASE id={} sender={:?} raw={:?} destination={} expected={} actual={} result={}",
            expected.id,
            sender,
            text,
            classification.destination.as_ref().map(|d| d.0.as_str()).unwrap_or("-"),
            expected.outcome,
            actual,
            if actual == expected.outcome { "PASS" } else { "FAIL" }
        );
        if actual != expected.outcome {
            return Err(format!("case {} mismatch expected={} actual={}", expected.id, expected.outcome, actual));
        }
    }

    queue.validate_invariants().map_err(|e| format!("queue invariant failure: {e:?}"))?;
    let counts = (
        queue.queued_count_by_destination("hyjal"),
        queue.queued_count_by_destination("winterspring"),
        queue.queued_count_by_destination("azshara"),
    );
    if counts != (1, 1, 1) {
        return Err(format!("queue counts mismatch: {counts:?}"));
    }

    let hyjal = DestinationId::new("hyjal").map_err(|e| e.to_string())?;
    registry
        .set_observation(
            &hyjal,
            DestinationObservation {
                shard_count: None,
                manual_override: ManualOverride::ForceOff,
                team_health: TeamHealth::Healthy,
            },
        )
        .map_err(|e| format!("manual-off test failed: {e}"))?;
    if registry.status(&hyjal).map(|s| s.availability) != Some(Availability::DisabledManual) {
        return Err("D manual-off did not fail closed".into());
    }
    let alternatives = registry
        .alternatives_for(&hyjal, 10)
        .into_iter()
        .map(|id| id.as_str().to_owned())
        .collect::<Vec<_>>();
    if alternatives != vec!["azshara".to_string(), "winterspring".to_string()] {
        return Err(format!("D alternatives mismatch: {alternatives:?}"));
    }
    if registry.resolve_destination("Hydraxian Waterlords!!!").map(|id| id.as_str().to_owned()) != Some("azshara".into()) {
        return Err("D legacy Hydraxian alias did not resolve to azshara".into());
    }
    if registry.resolve_destination("feralas").is_some() {
        return Err("D incorrectly resolved Feralas".into());
    }

    println!("TELE08_BCD_LIVE_GATE_PASS observations=12 queued=3 hyjal=1 winterspring=1 azshara=1 d_manual_off=PASS d_alternatives=PASS d_aliases=PASS invariants=OK");
    Ok(())
}

fn parser_config_from_registry(registry: &DestinationRegistry) -> ParserConfig {
    let mut parser = ParserConfig::default();
    parser.destination_aliases.clear();
    for definition in &registry.config().destinations {
        let key = DestinationKey::new(definition.id.as_str());
        parser.destination_aliases.push(DestinationAlias { alias: definition.id.as_str().to_string(), key: key.clone() });
        parser.destination_aliases.push(DestinationAlias { alias: definition.display_name.clone(), key: key.clone() });
        for alias in &definition.aliases {
            parser.destination_aliases.push(DestinationAlias { alias: alias.clone(), key: key.clone() });
        }
    }
    parser
}

fn evidence_path() -> Result<PathBuf, String> {
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--evidence" {
            return args.next().map(PathBuf::from).ok_or_else(|| "--evidence requires a TSV path".to_string());
        }
    }
    Err("usage: tele08_bcd_live_gate --evidence <sender-tab-raw_text.tsv>".to_string())
}

fn parse_tsv(raw: &str) -> Result<Vec<(String, String)>, String> {
    raw.lines()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let (sender, text) = line.split_once('\t').ok_or_else(|| format!("evidence line {} has no TAB", index + 1))?;
            if sender.trim().is_empty() { return Err(format!("evidence line {} has empty sender", index + 1)); }
            Ok((sender.to_string(), text.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_aliases_are_sourced_from_registry() {
        let registry = DestinationRegistry::from_json(SEED).unwrap();
        let parser = parser_config_from_registry(&registry);
        let aliases = parser.destination_aliases.iter().map(|a| (a.alias.as_str(), a.key.0.as_str())).collect::<Vec<_>>();
        assert!(aliases.contains(&("hydraxian waterlords", "azshara")));
        assert!(aliases.contains(&("mount hyjal", "hyjal")));
        assert!(aliases.contains(&("everlook", "winterspring")));
    }

    #[test]
    fn registry_seed_has_exactly_three_resources() {
        let registry = DestinationRegistry::from_json(SEED).unwrap();
        let resources = registry.config().destinations.iter().map(|d| registry.resource_key(&d.id).unwrap()).collect::<Vec<_>>();
        assert_eq!(resources, vec!["summon/azshara", "summon/hyjal", "summon/winterspring"]);
    }
}
