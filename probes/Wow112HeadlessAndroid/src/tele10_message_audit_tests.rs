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
    for text in [
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
    ] {
        let result = classify(text);
        assert!(
            matches!(result.intent, WhisperIntent::Irrelevant | WhisperIntent::Unknown),
            "false positive for {text:?}: {result:?}"
        );
    }
}

#[test]
fn tele10_known_false_negatives_are_explicit_not_silently_actionable() {
    for text in ["sumon plz", "invvv pls", "summn pls"] {
        let result = classify(text);
        assert_eq!(result.intent, WhisperIntent::Unknown, "input={text:?}");
        assert_eq!(result.reason, "operational_hint_below_action_threshold");
    }
}

#[test]
fn tele10_ambiguous_corpus_fails_closed() {
    for text in ["summon?", "inv maybe later", "summon maybe", "port eventually"] {
        assert_eq!(classify(text).intent, WhisperIntent::Unknown, "input={text:?}");
    }
    assert!(matches!(
        classify("hyjal or azshara").intent,
        WhisperIntent::Irrelevant | WhisperIntent::Unknown
    ));
}

#[test]
fn tele10_competitor_precedence_beats_leading_plus() {
    assert_eq!(
        classify("+ selling summons hyjal").intent,
        WhisperIntent::CompetitionMessage
    );
}
