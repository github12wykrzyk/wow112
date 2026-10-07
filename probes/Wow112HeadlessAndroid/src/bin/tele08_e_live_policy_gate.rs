use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use wow112_headless_android_probe::destination_registry::{
    DestinationObservation, DestinationRegistry, ManualOverride, TeamHealth,
};
use wow112_headless_android_probe::tele08_whisper_parser::{
    classify_whisper, DestinationAlias, DestinationKey, ParserConfig, WhisperIntent,
    WhisperObservation,
};
use wow112_headless_android_probe::tele_response_engine::{
    DecisionReason, DestinationUnavailableReason, ResponseContext, ResponseEngine,
    ResponseEngineConfig, ResponseKind, UnknownCategory, UnknownWhisperDumpConfig,
    UnknownWhisperDumper, UnknownWhisperRecord,
};

const SEED: &str = include_str!("../../config/tele08_destinations.example.json");

fn main() {
    if let Err(error) = run() {
        eprintln!("TELE08_E_LIVE_POLICY_GATE_FAIL reason={error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let evidence = evidence_path()?;
    let raw = fs::read_to_string(&evidence)
        .map_err(|e| format!("read evidence {} failed: {e}", evidence.display()))?;
    let observations = parse_tsv(&raw)?;
    if observations.len() != 12 {
        return Err(format!("expected 12 live observations, got {}", observations.len()));
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
    let mut engine = ResponseEngine::new(ResponseEngineConfig::default());
    let mut classifications = Vec::with_capacity(observations.len());
    for (index, (sender, text)) in observations.iter().enumerate() {
        classifications.push(classify_whisper(
            &WhisperObservation {
                sender: sender.clone(),
                text: text.clone(),
                timestamp_ms: 1_000_000 + (index as u64 * 20_000),
                source_role: Some("SUMMONER_LIVE_EVIDENCE".into()),
                destination_context: None,
            },
            &parser,
        ));
    }

    assert_queued_response(&mut engine, &classifications[1], 100, "hyjal")?;
    assert_queued_response(&mut engine, &classifications[6], 200, "winterspring")?;

    let feralas = &classifications[7];
    if feralas.intent != WhisperIntent::DestinationQuery || feralas.destination.is_some() {
        return Err("live Feralas query did not remain an unsupported destination query".into());
    }
    let alternatives = registry
        .available_destinations()
        .into_iter()
        .map(|id| id.as_str().to_string())
        .collect::<Vec<_>>();
    let unsupported = one_decision(
        &mut engine,
        ResponseContext::UnsupportedDestination {
            recipient: feralas.sender.clone(),
            requested_destination: "feralas".into(),
            alternatives: alternatives.clone(),
        },
        300,
    )?;
    if !unsupported.should_send
        || unsupported.response_kind != ResponseKind::UnsupportedDestination
        || unsupported.reason != DecisionReason::Allowed
        || unsupported.text
            != "I don't have feralas. Available: azshara, hyjal, winterspring."
    {
        return Err(format!("unsupported destination response mismatch: {unsupported:?}"));
    }

    let competition = &classifications[8];
    if competition.intent != WhisperIntent::CompetitionMessage {
        return Err("live competition whisper lost its B classification".into());
    }
    let competition_response = one_decision(
        &mut engine,
        ResponseContext::CompetitionMessage {
            recipient: competition.sender.clone(),
        },
        400,
    )?;
    if !competition_response.should_send
        || competition_response.response_kind != ResponseKind::Competition
        || competition_response.text != "Please keep whispers to summon requests."
    {
        return Err(format!("competition response mismatch: {competition_response:?}"));
    }

    let unknown = &classifications[10];
    if unknown.intent != WhisperIntent::Unknown {
        return Err("live Unknown whisper lost its B classification".into());
    }
    let unknown_response = one_decision(
        &mut engine,
        ResponseContext::Unknown {
            recipient: unknown.sender.clone(),
        },
        500,
    )?;
    if unknown_response.should_send
        || unknown_response.response_kind != ResponseKind::Unknown
        || unknown_response.reason != DecisionReason::UnknownNoReply
    {
        return Err(format!("Unknown reply policy mismatch: {unknown_response:?}"));
    }

    let dump_path = PathBuf::from("TELE08_E_UNKNOWN_LIVE.jsonl");
    let _ = fs::remove_file(&dump_path);
    let dumper = UnknownWhisperDumper::new(UnknownWhisperDumpConfig {
        path: dump_path.clone(),
        max_bytes: Some(1024 * 1024),
    });
    let mut record = UnknownWhisperRecord::new(
        "live-evidence-case-11",
        unknown.sender.clone(),
        unknown.raw_text.clone(),
    );
    record.normalized_text = Some(unknown.normalized_text.clone());
    record.source_role = Some("SUMMONER_LIVE_EVIDENCE".into());
    record.parser_signals = unknown.signals.clone();
    record.parser_reason = Some(unknown.reason.clone());
    record.category = UnknownCategory::Unknown;
    dumper
        .record_unknown(&record)
        .map_err(|e| format!("Unknown JSONL dump failed: {e}"))?;
    verify_unknown_dump(&dump_path, &unknown.sender, &unknown.raw_text)?;

    assert_queued_response(&mut engine, &classifications[11], 600, "azshara")?;

    let hyjal = registry
        .resolve_destination("hyjal")
        .ok_or_else(|| "D cannot resolve hyjal".to_string())?;
    registry
        .set_observation(
            &hyjal,
            DestinationObservation {
                shard_count: None,
                manual_override: ManualOverride::ForceOff,
                team_health: TeamHealth::Healthy,
            },
        )
        .map_err(|e| format!("D manual-off transition failed: {e}"))?;
    let manual_alternatives = registry
        .alternatives_for(&hyjal, 10)
        .into_iter()
        .map(|id| id.as_str().to_string())
        .collect::<Vec<_>>();
    let unavailable = one_decision(
        &mut engine,
        ResponseContext::DestinationUnavailable {
            recipient: "PolicyProbe".into(),
            destination: "hyjal".into(),
            reason: DestinationUnavailableReason::ManualOffOrMaintenance,
            alternatives: manual_alternatives,
        },
        1_000,
    )?;
    if !unavailable.should_send
        || unavailable.response_kind != ResponseKind::DestinationUnavailable
        || unavailable.text != "hyjal is temporarily unavailable."
    {
        return Err(format!("D->E unavailable response mismatch: {unavailable:?}"));
    }

    println!(
        "TELE08_E_LIVE_POLICY_GATE_PASS queued_responses=3 unsupported=PASS competition=PASS unknown_no_reply=PASS unknown_jsonl=PASS d_unavailable_to_e=PASS"
    );
    Ok(())
}

fn assert_queued_response(
    engine: &mut ResponseEngine,
    classification: &wow112_headless_android_probe::tele08_whisper_parser::WhisperClassification,
    now: u64,
    expected_destination: &str,
) -> Result<(), String> {
    let destination = classification
        .destination
        .as_ref()
        .map(|value| value.0.as_str())
        .ok_or_else(|| format!("missing destination for queued response {expected_destination}"))?;
    if destination != expected_destination {
        return Err(format!(
            "queued destination mismatch expected={expected_destination} actual={destination}"
        ));
    }
    let decision = one_decision(
        engine,
        ResponseContext::RequestQueued {
            recipient: classification.sender.clone(),
            destination: destination.into(),
            queue_position: Some(1),
            queue_length: Some(1),
        },
        now,
    )?;
    let expected_text = format!("Queued for {expected_destination}. Position: 1/1.");
    if !decision.should_send
        || decision.response_kind != ResponseKind::Queued
        || decision.reason != DecisionReason::Allowed
        || decision.text != expected_text
    {
        return Err(format!("queued response mismatch: {decision:?}"));
    }
    Ok(())
}

fn one_decision(
    engine: &mut ResponseEngine,
    context: ResponseContext,
    now: u64,
) -> Result<wow112_headless_android_probe::tele_response_engine::ResponseDecision, String> {
    let mut decisions = engine.handle_context(context, now);
    if decisions.len() != 1 {
        return Err(format!("expected one response decision, got {}", decisions.len()));
    }
    Ok(decisions.remove(0))
}

fn verify_unknown_dump(path: &Path, sender: &str, raw_text: &str) -> Result<(), String> {
    let data = fs::read_to_string(path)
        .map_err(|e| format!("read Unknown JSONL {} failed: {e}", path.display()))?;
    if data.lines().count() != 1
        || !data.contains("\"category\":\"unknown\"")
        || !data.contains(sender)
        || !data.contains(raw_text)
    {
        return Err(format!("Unknown JSONL evidence mismatch: {data:?}"));
    }
    Ok(())
}

fn parser_config_from_registry(registry: &DestinationRegistry) -> ParserConfig {
    let mut parser = ParserConfig::default();
    parser.destination_aliases.clear();
    for definition in &registry.config().destinations {
        let key = DestinationKey::new(definition.id.as_str());
        parser.destination_aliases.push(DestinationAlias {
            alias: definition.id.as_str().to_string(),
            key: key.clone(),
        });
        parser.destination_aliases.push(DestinationAlias {
            alias: definition.display_name.clone(),
            key: key.clone(),
        });
        for alias in &definition.aliases {
            parser.destination_aliases.push(DestinationAlias {
                alias: alias.clone(),
                key: key.clone(),
            });
        }
    }
    parser
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
    Err("usage: tele08_e_live_policy_gate --evidence <sender-tab-raw_text.tsv>".into())
}

fn parse_tsv(raw: &str) -> Result<Vec<(String, String)>, String> {
    raw.lines()
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let (sender, text) = line
                .split_once('\t')
                .ok_or_else(|| format!("evidence line {} has no TAB", index + 1))?;
            if sender.trim().is_empty() {
                return Err(format!("evidence line {} has empty sender", index + 1));
            }
            Ok((sender.to_string(), text.to_string()))
        })
        .collect()
}
