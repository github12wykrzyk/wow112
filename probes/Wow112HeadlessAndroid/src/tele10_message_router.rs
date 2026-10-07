use crate::tele08_bc_adapter::classification_to_request;
use crate::tele08_whisper_parser::{
    classify_whisper, ParserConfig, WhisperClassification, WhisperIntent, WhisperObservation,
};
use crate::tele10_clarification::{ClarificationConfig, ClarificationDecision, ClarificationGate};
use tele08_request_queue::SummonRequest;

#[derive(Debug)]
pub enum MessageRoute {
    Request(SummonRequest),
    Clarify { recipient: String, text: String },
    Ignore { reason: String },
}

#[derive(Debug, Clone)]
pub struct Tele10MessageRouter {
    parser: ParserConfig,
    clarification: ClarificationGate,
}

impl Default for Tele10MessageRouter {
    fn default() -> Self {
        Self::new(ParserConfig::default(), ClarificationConfig::default())
    }
}

impl Tele10MessageRouter {
    pub fn new(parser: ParserConfig, clarification: ClarificationConfig) -> Self {
        Self {
            parser,
            clarification: ClarificationGate::new(clarification),
        }
    }

    pub fn handle(&mut self, observation: &WhisperObservation) -> MessageRoute {
        let classification = classify_whisper(observation, &self.parser);
        self.route_classification(classification)
    }

    pub fn pending_clarifications(&self) -> usize {
        self.clarification.pending_count()
    }

    fn route_classification(&mut self, classification: WhisperClassification) -> MessageRoute {
        match self.clarification.process(&classification) {
            ClarificationDecision::Prompt {
                recipient, text, ..
            } => MessageRoute::Clarify { recipient, text },
            ClarificationDecision::Confirmed(confirmed) => {
                self.admit_or_ignore(&confirmed, "clarification_confirmed")
            }
            ClarificationDecision::Declined => MessageRoute::Ignore {
                reason: "clarification_declined".into(),
            },
            ClarificationDecision::Suppressed => MessageRoute::Ignore {
                reason: "clarification_suppressed".into(),
            },
            ClarificationDecision::PassThrough => {
                if matches!(
                    classification.intent,
                    WhisperIntent::CompetitionMessage
                        | WhisperIntent::DestinationQuery
                        | WhisperIntent::PresenceReady
                        | WhisperIntent::Irrelevant
                        | WhisperIntent::Unknown
                ) {
                    return MessageRoute::Ignore {
                        reason: format!("non_queueable:{:?}", classification.intent),
                    };
                }
                self.admit_or_ignore(&classification, "direct")
            }
        }
    }

    fn admit_or_ignore(
        &self,
        classification: &WhisperClassification,
        source: &str,
    ) -> MessageRoute {
        match classification_to_request(classification) {
            Ok(mut request) => {
                request
                    .metadata
                    .insert("tele10_message_route".into(), source.into());
                MessageRoute::Request(request)
            }
            Err(error) => MessageRoute::Ignore {
                reason: format!("admission_rejected:{error:?}"),
            },
        }
    }
}
