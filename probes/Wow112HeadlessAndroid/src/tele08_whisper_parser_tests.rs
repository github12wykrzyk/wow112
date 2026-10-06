use crate::tele08_whisper_parser::*;

fn obs(text: &str) -> WhisperObservation {
    WhisperObservation {
        sender: "Customer".into(),
        text: text.into(),
        timestamp_ms: 1_700_000_000_123,
        source_role: Some("listener".into()),
        destination_context: None,
    }
}

fn classify(text: &str) -> WhisperClassification {
    classify_whisper(&obs(text), &ParserConfig::default())
}

#[test]
fn positive_operational_matrix_has_at_least_50_cases() {
    let cases: &[(&str, WhisperIntent)] = &[
        ("+", WhisperIntent::GenericPositive),
        ("+ ", WhisperIntent::GenericPositive),
        ("+ pls", WhisperIntent::GenericPositive),
        ("+ please", WhisperIntent::GenericPositive),
        ("+ anything after it", WhisperIntent::GenericPositive),
        ("+ hyjal", WhisperIntent::GenericPositive),
        ("+ HyJaL", WhisperIntent::GenericPositive),
        ("+ winterspring", WhisperIntent::GenericPositive),
        ("+ azshara", WhisperIntent::GenericPositive),
        ("+ hyjal pls", WhisperIntent::GenericPositive),
        ("+ winterspring please", WhisperIntent::GenericPositive),
        ("+ azshara now", WhisperIntent::GenericPositive),
        ("   +   hyjal!!!", WhisperIntent::GenericPositive),
        ("+one", WhisperIntent::GenericPositive),
        ("++", WhisperIntent::GenericPositive),
        ("+ inv", WhisperIntent::GenericPositive),
        ("+ summon", WhisperIntent::GenericPositive),
        ("+ me", WhisperIntent::GenericPositive),
        ("+ 123", WhisperIntent::GenericPositive),
        ("+ whatever", WhisperIntent::GenericPositive),
        ("i need one", WhisperIntent::SummonRequest),
        ("I NEED ONE", WhisperIntent::SummonRequest),
        ("need one", WhisperIntent::SummonRequest),
        ("Need One!!!", WhisperIntent::SummonRequest),
        ("summon me", WhisperIntent::SummonRequest),
        ("SUMMON ME", WhisperIntent::SummonRequest),
        ("sum me", WhisperIntent::SummonRequest),
        ("need summon", WhisperIntent::SummonRequest),
        ("one pls", WhisperIntent::SummonRequest),
        ("one please", WhisperIntent::SummonRequest),
        ("summon pls", WhisperIntent::SummonRequest),
        ("summon please", WhisperIntent::SummonRequest),
        ("inv", WhisperIntent::InviteRequest),
        ("INV", WhisperIntent::InviteRequest),
        ("inv pls", WhisperIntent::InviteRequest),
        ("inv... pls", WhisperIntent::InviteRequest),
        ("inv please", WhisperIntent::InviteRequest),
        ("inv me", WhisperIntent::InviteRequest),
        ("invite", WhisperIntent::InviteRequest),
        ("invite me", WhisperIntent::InviteRequest),
        ("INVITE ME!!!", WhisperIntent::InviteRequest),
        ("invite pls", WhisperIntent::InviteRequest),
        ("invite please", WhisperIntent::InviteRequest),
        ("invi", WhisperIntent::InviteRequest),
        ("invi pls", WhisperIntent::InviteRequest),
        ("INVI PLEASE", WhisperIntent::InviteRequest),
        ("here", WhisperIntent::PresenceReady),
        ("HERE!!!", WhisperIntent::PresenceReady),
        ("im here", WhisperIntent::PresenceReady),
        ("I'm here", WhisperIntent::PresenceReady),
        ("hyjal", WhisperIntent::SummonRequest),
        ("HYJAL!!!", WhisperIntent::SummonRequest),
        ("hyjal pls", WhisperIntent::SummonRequest),
        ("please hyjal", WhisperIntent::SummonRequest),
        ("summon hyjal", WhisperIntent::SummonRequest),
        ("winterspring", WhisperIntent::SummonRequest),
        ("winterspring pls", WhisperIntent::SummonRequest),
        ("please winterspring", WhisperIntent::SummonRequest),
        ("azshara", WhisperIntent::SummonRequest),
        ("azshara please", WhisperIntent::SummonRequest),
        ("summon me to azshara", WhisperIntent::SummonRequest),
        ("need one to hyjal", WhisperIntent::SummonRequest),
    ];
    assert!(cases.len() >= 50, "fixture count={}", cases.len());
    for (text, expected) in cases {
        assert_eq!(&classify(text).intent, expected, "input={text:?}");
    }
}

#[test]
fn negative_matrix_has_at_least_30_cases_and_stays_non_actionable() {
    let cases = [
        "hello",
        "hi",
        "hey",
        "thanks",
        "ty",
        "good luck",
        "nice service",
        "how are you",
        "lol",
        "brb",
        "afk",
        "one sec",
        "wait",
        "ok",
        "okay",
        "cool",
        "gg",
        "bye",
        "cya",
        "what level are you",
        "what level are you?",
        "where are you from",
        "hello + hyjal",
        "math 2+2",
        "invoice please",
        "invoices",
        "invent something",
        "inside now",
        "invisible",
        "invitation sent",
        "winter is coming",
        "azsharalalala",
        "hyjacking",
        "portal looks nice",
        "telephone",
        "summary",
        "consumer",
        "need gold",
        "invitees are here",
        "plus sign + in middle",
        "we met yesterday",
    ];
    assert!(cases.len() >= 30, "fixture count={}", cases.len());
    for text in cases {
        let result = classify(text);
        assert!(
            matches!(
                result.intent,
                WhisperIntent::Irrelevant | WhisperIntent::Unknown
            ),
            "unsafe false positive for {text:?}: {result:?}"
        );
    }
}

#[test]
fn required_regressions() {
    let cases = [
        ("+", WhisperIntent::GenericPositive),
        ("+ hyjal", WhisperIntent::GenericPositive),
        ("inv pls", WhisperIntent::InviteRequest),
        ("invi", WhisperIntent::InviteRequest),
        ("I need one", WhisperIntent::SummonRequest),
        ("here", WhisperIntent::PresenceReady),
        ("winterspring pls", WhisperIntent::SummonRequest),
    ];
    for (text, expected) in cases {
        assert_eq!(classify(text).intent, expected, "input={text:?}");
    }
}

#[test]
fn feralas_query_never_fakes_availability() {
    let result = classify("do you have feralas?");
    assert_eq!(result.intent, WhisperIntent::DestinationQuery);
    assert_eq!(result.destination, None);
    assert!(result
        .signals
        .iter()
        .any(|s| s.contains("unconfigured_candidate:feralas")));
}

#[test]
fn destination_registry_is_injectable_and_hydraxian_is_legacy_only() {
    assert_eq!(classify("hydraxian pls").destination, None);
    let config = ParserConfig::default()
        .with_destination_alias("feralas", "feralas")
        .with_destination_alias("hydraxian", "hydraxian_waterlords")
        .with_destination_alias("hydraxian waterlords", "hydraxian_waterlords");
    let feralas = classify_whisper(&obs("do you have feralas?"), &config);
    assert_eq!(feralas.destination, Some(DestinationKey::new("feralas")));
    let hydraxian = classify_whisper(&obs("hydraxian waterlords pls"), &config);
    assert_eq!(hydraxian.intent, WhisperIntent::SummonRequest);
    assert_eq!(
        hydraxian.destination,
        Some(DestinationKey::new("hydraxian_waterlords"))
    );
}

#[test]
fn fuzzy_invite_is_explainable_and_bounded() {
    let result = classify("invi");
    assert_eq!(result.intent, WhisperIntent::InviteRequest);
    assert!(result
        .signals
        .iter()
        .any(|s| s == "fuzzy:invi->inv:distance=1"));
    assert_eq!(result.reason, "bounded_short_operational_fuzzy_match");
    for text in ["invoice", "invent", "inside", "invitation"] {
        assert_ne!(
            classify(text).intent,
            WhisperIntent::InviteRequest,
            "input={text:?}"
        );
    }
}

#[test]
fn plus_policy_and_competition_precedence_are_conservative() {
    assert_ne!(
        classify("hello + hyjal").intent,
        WhisperIntent::GenericPositive
    );
    assert_eq!(
        classify("+ selling summons").intent,
        WhisperIntent::CompetitionMessage
    );
    let result = classify("selling summons cheaper today");
    assert_eq!(result.intent, WhisperIntent::CompetitionMessage);
    assert!(result
        .signals
        .iter()
        .any(|s| s == "competition_pattern:selling summons"));
}

#[test]
fn unknown_preserves_reporting_payload() {
    let observation = WhisperObservation {
        sender: "OddCustomer".into(),
        text: "sumon plz???".into(),
        timestamp_ms: 42,
        source_role: Some("hyjal_listener".into()),
        destination_context: Some("hyjal".into()),
    };
    let result = classify_whisper(&observation, &ParserConfig::default());
    assert_eq!(result.intent, WhisperIntent::Unknown);
    assert_eq!(result.sender, "OddCustomer");
    assert_eq!(result.raw_text, "sumon plz???");
    assert_eq!(result.normalized_text, "sumon plz");
    assert_eq!(result.timestamp_ms, 42);
    assert_eq!(result.destination, Some(DestinationKey::new("hyjal")));
    assert!(!result.reason.is_empty());
    assert!(!result.signals.is_empty());
}

#[test]
fn explicit_destination_overrides_context() {
    let mut observation = obs("need one");
    observation.destination_context = Some("hyjal".into());
    assert_eq!(
        classify_whisper(&observation, &ParserConfig::default()).destination,
        Some(DestinationKey::new("hyjal"))
    );
    observation.text = "azshara".into();
    assert_eq!(
        classify_whisper(&observation, &ParserConfig::default()).destination,
        Some(DestinationKey::new("azshara"))
    );
}

#[test]
fn destination_queries_cover_configured_and_unconfigured_names_only() {
    for text in [
        "do you have hyjal?",
        "can i get winterspring?",
        "got azshara?",
    ] {
        let result = classify(text);
        assert_eq!(
            result.intent,
            WhisperIntent::DestinationQuery,
            "input={text:?}"
        );
        assert!(result.destination.is_some());
    }
    let unknown = classify("do you have silithus?");
    assert_eq!(unknown.intent, WhisperIntent::DestinationQuery);
    assert_eq!(unknown.destination, None);
    assert_eq!(
        classify("what level are you?").intent,
        WhisperIntent::Irrelevant
    );
}

#[test]
fn fingerprint_is_deterministic_and_timestamp_independent() {
    let first = classify("+ hyjal");
    let mut second_obs = obs("+   HYJAL!!!");
    second_obs.timestamp_ms = 999_999;
    let second = classify_whisper(&second_obs, &ParserConfig::default());
    assert_eq!(request_fingerprint(&first), request_fingerprint(&second));
    assert_eq!(request_fingerprint(&first).len(), 16);
    let mut other = obs("+ hyjal");
    other.sender = "OtherCustomer".into();
    assert_ne!(
        request_fingerprint(&first),
        request_fingerprint(&classify_whisper(&other, &ParserConfig::default()))
    );
}

#[test]
fn config_and_normalization_helpers_are_deterministic() {
    let mut config = ParserConfig::default();
    config.competition_patterns.push("cheap ports here".into());
    assert_eq!(
        classify_whisper(&obs("CHEAP ports here!!!"), &config).intent,
        WhisperIntent::CompetitionMessage
    );
    assert_eq!(normalize_whisper_text("  +   HyJAL!!!  "), "+ hyjal");
    assert_eq!(normalize_whisper_text("INV... pls"), "inv pls");
    let aliases = destination_alias_map(&ParserConfig::default());
    assert_eq!(aliases.len(), 3);
    assert_eq!(aliases.get("hyjal"), Some(&DestinationKey::new("hyjal")));
}
