use crate::tele08_whisper_parser::*;

fn classify(text: &str) -> WhisperClassification {
    classify_whisper(
        &WhisperObservation {
            sender: "AuditCustomer".into(),
            text: text.into(),
            timestamp_ms: 1_700_000_123_000,
            source_role: Some("tele10_audit".into()),
            destination_context: None,
        },
        &ParserConfig::default(),
    )
}

#[test]
fn tele10_understood_corpus_covers_case_punctuation_slang_and_plus() {
    let cases = [
        ("+ literally anything", WhisperIntent::GenericPositive),
        ("   +   HYJAL!!!", WhisperIntent::GenericPositive),
        ("I NEED ONE!!!", WhisperIntent::SummonRequest),
        ("inv... pls", WhisperIntent::InviteRequest),
        ("invi", WhisperIntent::InviteRequest),
        ("here!!!", WhisperIntent::PresenceReady),
        ("hyjal pls", WhisperIntent::SummonRequest),
        ("please winterspring", WhisperIntent::SummonRequest),
        ("summon me to azshara", WhisperIntent::SummonRequest),
        ("do you have hyjal?", WhisperIntent::DestinationQuery),
        ("selling summons cheaper today", WhisperIntent::CompetitionMessage),
        ("WTS SUMMONS!!!", WhisperIntent::CompetitionMessage),
    ];
    for (text, expected) in cases {
        assert_eq!(classify(text).intent, expected, "input={text:?}");
    }
}

#[test]
fn tele10_false_positive_guard_corpus_stays_non_actionable() {
    let cases = [
        "hello + hyjal",
        "math 2+2",
        "invoice please",
        "invitation sent",
        "invent something",
        "need gold",
        "portal looks nice",
        "winter is coming",
        "hyjacking",
        "thanks for summon",
        "plus sign + in middle",
        "we met yesterday",
    ];
    for text in cases {
        let result = classify(text);
        assert!(
            matches!(result.intent, WhisperIntent::Irrelevant | WhisperIntent::Unknown),
            "false positive for {text:?}: {result:?}"
        );
    }
}

#[test]
fn tele10_known_false_negatives_are_explicit_not_silently_actionable() {
    // These are deliberately reported as false negatives by the audit rather
    // than widening fuzzy matching and risking false-positive auto-invites.
    for text in ["sumon plz", "invvv pls", "summn pls"] {
        let result = classify(text);
        assert_eq!(result.intent, WhisperIntent::Unknown, "input={text:?}");
        assert_eq!(result.reason, "operational_hint_below_action_threshold");
    }
}

#[test]
fn tele10_ambiguous_corpus_fails_closed() {
    let cases = ["summon?", "inv maybe later", "summon maybe", "port eventually"];
    for text in cases {
        let result = classify(text);
        assert_eq!(result.intent, WhisperIntent::Unknown, "input={text:?}");
    }

    // Two destinations without a request envelope must not become an action.
    let two_destinations = classify("hyjal or azshara");
    assert!(matches!(
        two_destinations.intent,
        WhisperIntent::Irrelevant | WhisperIntent::Unknown
    ));
}

#[test]
fn tele10_competitor_precedence_beats_leading_plus() {
    let result = classify("+ selling summons hyjal");
    assert_eq!(result.intent, WhisperIntent::CompetitionMessage);
}
