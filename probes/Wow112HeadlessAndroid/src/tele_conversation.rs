#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Destination {
    Hyjal,
    Winterspring,
    Hydraxian,
}

impl Destination {
    pub fn label(self) -> &'static str {
        match self {
            Self::Hyjal => "Hyjal",
            Self::Winterspring => "Winterspring",
            Self::Hydraxian => "Hydraxian/Azshara",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversationPhase {
    New,
    DestinationKnown,
    Invited,
    Grouped,
    Waiting,
    SummonPending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConversationContext {
    pub destination: Option<Destination>,
    pub phase: ConversationPhase,
}

impl Default for ConversationContext {
    fn default() -> Self {
        Self {
            destination: None,
            phase: ConversationPhase::New,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Intent {
    SummonRequest,
    InviteRequest,
    ReadySignal,
    Wait,
    PriceQuery,
    PaymentOffer,
    PaymentNegative,
    CompetitorOffer,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SuggestedAction {
    None,
    AskDestination,
    Invite,
    MarkReady,
    MarkWaiting,
    ReplyPrice,
    RecordPaymentSignal,
    RecordCompetitor,
    LogUnknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classification {
    pub intent: Intent,
    pub destination: Option<Destination>,
    pub confidence: u8,
    pub action: SuggestedAction,
    pub reason: &'static str,
}

fn normalize_message(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut previous_space = true;
    for ch in input.chars().flat_map(char::to_lowercase) {
        let keep = ch.is_ascii_alphanumeric() || ch == '\'';
        if keep {
            out.push(ch);
            previous_space = false;
        } else if !previous_space {
            out.push(' ');
            previous_space = true;
        }
    }
    out.trim().to_string()
}

fn phrase_has(normalized: &str, phrase: &str) -> bool {
    let phrase = normalize_message(phrase);
    if phrase.is_empty() {
        return false;
    }
    format!(" {normalized} ").contains(&format!(" {phrase} "))
}

fn any_phrase(normalized: &str, phrases: &[&str]) -> bool {
    phrases.iter().any(|phrase| phrase_has(normalized, phrase))
}

pub fn resolve_destination(normalized: &str) -> Option<Destination> {
    if any_phrase(normalized, &["mount hyjal", "hyjal"]) {
        return Some(Destination::Hyjal);
    }
    if phrase_has(normalized, "winterspring") {
        return Some(Destination::Winterspring);
    }
    if any_phrase(
        normalized,
        &[
            "azshara",
            "azsh",
            "hydraxian",
            "hydraxian waterlords",
            "waterlords",
            "waterlord",
        ],
    ) || normalized
        .split_whitespace()
        .any(|token| token.len() >= 6 && token.starts_with("hydrax"))
    {
        return Some(Destination::Hydraxian);
    }
    None
}

fn is_competitor(normalized: &str, destination: Option<Destination>) -> bool {
    let travel = any_phrase(
        normalized,
        &["summon", "summons", "summoning", "portal", "portals", "taxi", "teleport"],
    );
    let seller = any_phrase(
        normalized,
        &[
            "wts",
            "selling",
            "sell",
            "service",
            "available",
            "offering",
            "pst",
            "whisper me",
            "dm me",
        ],
    );
    let price = normalized.split_whitespace().any(|token| {
        token == "gold"
            || token == "tip"
            || token.ends_with('g') && token[..token.len().saturating_sub(1)].parse::<u32>().is_ok()
    });
    let buyer = any_phrase(
        normalized,
        &["need", "lf summon", "lf summ", "wtb", "buy", "want", "looking", "can i", "could i"],
    );

    if buyer && !any_phrase(normalized, &["wts", "selling", "service", "offering"]) {
        return false;
    }
    seller && ((travel && destination.is_some()) || (travel && price) || (destination.is_some() && price))
}

fn established_context(context: ConversationContext) -> bool {
    context.destination.is_some()
        && matches!(
            context.phase,
            ConversationPhase::DestinationKnown
                | ConversationPhase::Invited
                | ConversationPhase::Grouped
                | ConversationPhase::Waiting
                | ConversationPhase::SummonPending
        )
}

pub fn classify_whisper(raw: &str, context: ConversationContext) -> Classification {
    let trimmed = raw.trim();
    let normalized = normalize_message(raw);
    let explicit_destination = resolve_destination(&normalized);
    let destination = explicit_destination.or(context.destination);

    if is_competitor(&normalized, explicit_destination) {
        return Classification {
            intent: Intent::CompetitorOffer,
            destination: explicit_destination,
            confidence: 96,
            action: SuggestedAction::RecordCompetitor,
            reason: "seller/travel/price signals",
        };
    }

    if any_phrase(&normalized, &["cannot pay", "cant pay", "can t pay", "wont pay", "will not pay", "not paying", "no pay"]) {
        return Classification {
            intent: Intent::PaymentNegative,
            destination,
            confidence: 96,
            action: SuggestedAction::RecordPaymentSignal,
            reason: "negative payment phrase",
        };
    }

    if any_phrase(&normalized, &["i can pay", "can pay", "i will pay", "will pay", "ill pay", "happy to pay", "pay you"]) {
        return Classification {
            intent: Intent::PaymentOffer,
            destination,
            confidence: 95,
            action: SuggestedAction::RecordPaymentSignal,
            reason: "payment offer phrase",
        };
    }

    if any_phrase(&normalized, &["how much", "price", "cost", "fee"]) {
        return Classification {
            intent: Intent::PriceQuery,
            destination,
            confidence: 97,
            action: SuggestedAction::ReplyPrice,
            reason: "price phrase",
        };
    }

    if any_phrase(
        &normalized,
        &["wait", "one quest", "let me turn", "let me finish", "minute", "min"],
    ) {
        return Classification {
            intent: Intent::Wait,
            destination,
            confidence: 90,
            action: SuggestedAction::MarkWaiting,
            reason: "wait/defer phrase",
        };
    }

    let raw_ready_plus = trimmed.starts_with('+');
    let exact_ready = matches!(normalized.as_str(), "123" | "here" | "sure" | "ready" | "go" | "summon" | "k summon");
    if raw_ready_plus || exact_ready {
        if established_context(context) || explicit_destination.is_some() {
            return Classification {
                intent: Intent::ReadySignal,
                destination,
                confidence: if explicit_destination.is_some() { 98 } else { 94 },
                action: SuggestedAction::MarkReady,
                reason: "contextual ready signal",
            };
        }
        return Classification {
            intent: Intent::Unknown,
            destination: None,
            confidence: 35,
            action: SuggestedAction::LogUnknown,
            reason: "ambiguous ready token without conversation context",
        };
    }

    let invite_cue = any_phrase(
        &normalized,
        &[
            "inv",
            "invite",
            "invite me",
            "invi",
            "port",
            "summon me",
            "sum me",
            "i need one",
            "need one",
            "want one",
            "can i get one",
            "could i get one",
            "one pls",
            "one plz",
            "one please",
        ],
    );
    let summon_request = any_phrase(
        &normalized,
        &[
            "lf summon",
            "lf summ",
            "need summon",
            "need summ",
            "wtb summon",
            "wtb summ",
            "can i get a summon",
            "can i get summon",
        ],
    );

    if explicit_destination.is_some() && (invite_cue || summon_request || normalized.split_whitespace().count() <= 4) {
        return Classification {
            intent: if invite_cue { Intent::InviteRequest } else { Intent::SummonRequest },
            destination: explicit_destination,
            confidence: 97,
            action: SuggestedAction::Invite,
            reason: "supported destination with buyer/request signal",
        };
    }

    if invite_cue || summon_request {
        if context.destination.is_some() {
            return Classification {
                intent: if invite_cue { Intent::InviteRequest } else { Intent::SummonRequest },
                destination: context.destination,
                confidence: 93,
                action: SuggestedAction::Invite,
                reason: "request resolved from conversation destination",
            };
        }
        return Classification {
            intent: if invite_cue { Intent::InviteRequest } else { Intent::SummonRequest },
            destination: None,
            confidence: 82,
            action: SuggestedAction::AskDestination,
            reason: "request intent without destination",
        };
    }

    if let Some(destination) = explicit_destination {
        return Classification {
            intent: Intent::SummonRequest,
            destination: Some(destination),
            confidence: 90,
            action: SuggestedAction::Invite,
            reason: "supported destination in direct whisper",
        };
    }

    Classification {
        intent: Intent::Unknown,
        destination: context.destination,
        confidence: 20,
        action: SuggestedAction::LogUnknown,
        reason: "no supported intent rule matched",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(destination: Destination, phase: ConversationPhase) -> ConversationContext {
        ConversationContext {
            destination: Some(destination),
            phase,
        }
    }

    #[test]
    fn direct_destination_invite_is_high_confidence() {
        let got = classify_whisper("inv hyjal pls", ConversationContext::default());
        assert_eq!(got.intent, Intent::InviteRequest);
        assert_eq!(got.destination, Some(Destination::Hyjal));
        assert_eq!(got.action, SuggestedAction::Invite);
        assert!(got.confidence >= 90);
    }

    #[test]
    fn historical_invi_shortcut_uses_context() {
        let got = classify_whisper(
            "invi",
            ctx(Destination::Winterspring, ConversationPhase::DestinationKnown),
        );
        assert_eq!(got.intent, Intent::InviteRequest);
        assert_eq!(got.destination, Some(Destination::Winterspring));
        assert_eq!(got.action, SuggestedAction::Invite);
    }

    #[test]
    fn plus_anything_is_ready_only_with_context() {
        let with_context = classify_whisper(
            "+ whatever",
            ctx(Destination::Hyjal, ConversationPhase::Grouped),
        );
        assert_eq!(with_context.intent, Intent::ReadySignal);
        assert_eq!(with_context.action, SuggestedAction::MarkReady);

        let without_context = classify_whisper("+ whatever", ConversationContext::default());
        assert_eq!(without_context.intent, Intent::Unknown);
        assert_eq!(without_context.action, SuggestedAction::LogUnknown);
    }

    #[test]
    fn exact_ready_codes_are_contextual() {
        for raw in ["123", "here", "ready", "go"] {
            let got = classify_whisper(
                raw,
                ctx(Destination::Hydraxian, ConversationPhase::Invited),
            );
            assert_eq!(got.intent, Intent::ReadySignal, "{raw}");
        }
        assert_eq!(
            classify_whisper("123", ConversationContext::default()).intent,
            Intent::Unknown
        );
    }

    #[test]
    fn request_without_destination_asks_instead_of_mutating() {
        let got = classify_whisper("i need one", ConversationContext::default());
        assert_eq!(got.intent, Intent::InviteRequest);
        assert_eq!(got.action, SuggestedAction::AskDestination);
        assert_eq!(got.destination, None);
    }

    #[test]
    fn seller_ad_is_not_treated_as_buyer() {
        let got = classify_whisper("WTS summon Hyjal 4g pst", ConversationContext::default());
        assert_eq!(got.intent, Intent::CompetitorOffer);
        assert_eq!(got.action, SuggestedAction::RecordCompetitor);
    }

    #[test]
    fn aliases_resolve_current_three_stations() {
        assert_eq!(resolve_destination("mount hyjal"), Some(Destination::Hyjal));
        assert_eq!(resolve_destination("winterspring"), Some(Destination::Winterspring));
        assert_eq!(resolve_destination("azshara"), Some(Destination::Hydraxian));
        assert_eq!(resolve_destination("hydraxian waterlords"), Some(Destination::Hydraxian));
    }

    #[test]
    fn wait_and_price_are_non_mutating() {
        let wait = classify_whisper(
            "wait 3 min one quest",
            ctx(Destination::Hyjal, ConversationPhase::Grouped),
        );
        assert_eq!(wait.intent, Intent::Wait);
        assert_eq!(wait.action, SuggestedAction::MarkWaiting);

        let price = classify_whisper("how much?", ConversationContext::default());
        assert_eq!(price.intent, Intent::PriceQuery);
        assert_eq!(price.action, SuggestedAction::ReplyPrice);
    }
}
