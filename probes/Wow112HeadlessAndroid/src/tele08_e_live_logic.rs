use crate::destination_registry::{
    Availability, DestinationId, DestinationObservation, DestinationRegistry, ManualOverride,
    TeamHealth,
};
use crate::tele08_bc_adapter::classification_to_request;
use crate::tele08_de_adapter::{request_queued_context, unavailable_destination_context};
use crate::tele08_whisper_parser::{WhisperClassification, WhisperIntent};
use crate::tele_response_engine::{ResponseContext, ResponseDecision, ResponseEngine, ResponseEngineConfig};
use tele08_request_queue::{QueueConfig, QueueEngine, QueueEvent, ResourceKey};

const SEEDED_DESTINATIONS: &str = include_str!("../config/tele08_destinations.example.json");
const ALTERNATIVES_LIMIT: usize = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveLogicResult {
    pub response: Option<ResponseDecision>,
    pub trace: Vec<String>,
}

pub struct LiveResponseLogic {
    registry: DestinationRegistry,
    queue: QueueEngine,
    responses: ResponseEngine,
}

impl LiveResponseLogic {
    pub fn seeded() -> Result<Self, String> {
        let mut registry = DestinationRegistry::from_json(SEEDED_DESTINATIONS)
            .map_err(|error| format!("destination registry init failed: {error}"))?;

        let destination_ids = registry
            .config()
            .destinations
            .iter()
            .map(|definition| definition.id.clone())
            .collect::<Vec<_>>();
        for destination in &destination_ids {
            registry
                .set_observation(
                    destination,
                    DestinationObservation {
                        shard_count: Some(999),
                        manual_override: ManualOverride::Automatic,
                        team_health: TeamHealth::Healthy,
                    },
                )
                .map_err(|error| format!("seed destination observation failed: {error}"))?;
        }

        let mut queue_config = QueueConfig::new(30_000, 120_000);
        for definition in &registry.config().destinations {
            let resource = registry
                .resource_key(&definition.id)
                .ok_or_else(|| format!("missing resource key for {}", definition.id))?;
            queue_config.map_destination_resource(
                definition.id.as_str().to_string(),
                ResourceKey(resource.to_string()),
            );
        }

        Ok(Self {
            registry,
            queue: QueueEngine::new(queue_config),
            responses: ResponseEngine::new(ResponseEngineConfig::default()),
        })
    }

    pub fn set_destination_unhealthy(&mut self, destination: &str) -> Result<(), String> {
        let id = self
            .registry
            .resolve_destination(destination)
            .ok_or_else(|| format!("unknown destination {destination:?}"))?;
        self.registry
            .set_observation(
                &id,
                DestinationObservation {
                    shard_count: Some(999),
                    manual_override: ManualOverride::Automatic,
                    team_health: TeamHealth::Unhealthy,
                },
            )
            .map_err(|error| format!("set unhealthy failed: {error}"))?;
        Ok(())
    }

    pub fn handle(
        &mut self,
        classification: &WhisperClassification,
        now: u64,
    ) -> Result<LiveLogicResult, String> {
        let mut trace = vec![format!("B:{:?}", classification.intent)];

        match classification.intent {
            WhisperIntent::CompetitionMessage => {
                trace.push("E:Competition".into());
                return Ok(LiveLogicResult {
                    response: self
                        .responses
                        .handle_context(
                            ResponseContext::CompetitionMessage {
                                recipient: classification.sender.clone(),
                            },
                            now,
                        )
                        .into_iter()
                        .next(),
                    trace,
                });
            }
            WhisperIntent::Unknown | WhisperIntent::Irrelevant | WhisperIntent::PresenceReady => {
                trace.push("E:NoReply".into());
                return Ok(LiveLogicResult {
                    response: None,
                    trace,
                });
            }
            WhisperIntent::DestinationQuery => {
                trace.push("E:DestinationQueryNoMutation".into());
                return Ok(LiveLogicResult {
                    response: None,
                    trace,
                });
            }
            WhisperIntent::SummonRequest
            | WhisperIntent::InviteRequest
            | WhisperIntent::GenericPositive => {}
        }

        let parser_destination = classification
            .destination
            .as_ref()
            .ok_or_else(|| "queueable classification missing destination".to_string())?;
        let destination_id = self
            .registry
            .resolve_destination(&parser_destination.0)
            .ok_or_else(|| format!("D:unknown destination {}", parser_destination.0))?;
        let status = self
            .registry
            .status(&destination_id)
            .ok_or_else(|| format!("D:missing status for {destination_id}"))?;
        trace.push(format!("D:{:?}", status.availability));

        if status.availability != Availability::Enabled {
            let context = unavailable_destination_context(
                &self.registry,
                classification.sender.clone(),
                &destination_id,
                ALTERNATIVES_LIMIT,
            )
            .ok_or_else(|| "D unavailable status produced no E context".to_string())?;
            trace.push("E:DestinationUnavailable".into());
            return Ok(LiveLogicResult {
                response: self.responses.handle_context(context, now).into_iter().next(),
                trace,
            });
        }

        let request = classification_to_request(classification)
            .map_err(|error| format!("C admission adapter rejected: {error:?}"))?;
        let outcome = self.queue.enqueue(request.clone());
        trace.push(format!("C:accepted={}", outcome.accepted));
        if !outcome.accepted {
            return Err(format!("C enqueue rejected events={:?}", outcome.events));
        }

        let position = outcome
            .events
            .iter()
            .find_map(|event| match event {
                QueueEvent::RequestQueued {
                    request_id,
                    position,
                    ..
                } if request_id == &request.request_id => Some(*position),
                _ => None,
            })
            .ok_or_else(|| "C accepted request without RequestQueued event".to_string())?;
        trace.push(format!("C:Queued({position})"));

        let context = request_queued_context(
            &self.registry,
            classification.sender.clone(),
            &destination_id,
            Some(position),
            None,
        )
        .ok_or_else(|| "D failed to build queued response context".to_string())?;
        trace.push("E:Queued".into());

        Ok(LiveLogicResult {
            response: self.responses.handle_context(context, now).into_iter().next(),
            trace,
        })
    }

    pub fn destination_id(&self, value: &str) -> Option<DestinationId> {
        self.registry.resolve_destination(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tele08_whisper_parser::{classify_whisper, ParserConfig, WhisperObservation};

    fn classify(text: &str, now: u64) -> WhisperClassification {
        classify_whisper(
            &WhisperObservation {
                sender: "Smokinpole".into(),
                text: text.into(),
                timestamp_ms: now,
                source_role: Some("SUMMONER".into()),
                destination_context: None,
            },
            &ParserConfig::default(),
        )
    }

    #[test]
    fn supported_request_crosses_b_c_d_e_and_returns_queue_reply() {
        let mut logic = LiveResponseLogic::seeded().unwrap();
        let result = logic.handle(&classify("hyjal pls", 1_000), 1).unwrap();
        let response = result.response.unwrap();
        assert!(response.should_send);
        assert_eq!(response.text, "Queued for Hyjal. Position: 1.");
        assert_eq!(
            result.trace,
            vec!["B:SummonRequest", "D:Enabled", "C:accepted=true", "C:Queued(1)", "E:Queued"]
        );
    }

    #[test]
    fn unhealthy_destination_is_blocked_before_queue_and_uses_dynamic_alternatives() {
        let mut logic = LiveResponseLogic::seeded().unwrap();
        logic.set_destination_unhealthy("winterspring").unwrap();
        let result = logic
            .handle(&classify("winterspring pls", 2_000), 20)
            .unwrap();
        let response = result.response.unwrap();
        assert!(response.should_send);
        assert_eq!(
            response.text,
            "Winterspring is temporarily unavailable."
        );
        assert_eq!(
            result.trace,
            vec!["B:SummonRequest", "D:DisabledUnhealthyTeam", "E:DestinationUnavailable"]
        );
    }

    #[test]
    fn competition_reply_obeys_e_cooldown() {
        let mut logic = LiveResponseLogic::seeded().unwrap();
        let classification = classify("selling summons cheaper today", 3_000);
        let first = logic.handle(&classification, 100).unwrap().response.unwrap();
        assert!(first.should_send);
        let second = logic.handle(&classification, 101).unwrap().response.unwrap();
        assert!(!second.should_send);
    }
}
