use crate::destination_registry::{Availability, DestinationId, DestinationRegistry};
use crate::tele_response_engine::{DestinationUnavailableReason, ResponseContext};

pub fn available_display_names(
    registry: &DestinationRegistry,
    exclude: Option<&DestinationId>,
    limit: usize,
) -> Vec<String> {
    registry
        .available_destinations()
        .into_iter()
        .filter(|id| exclude.map(|excluded| excluded != id).unwrap_or(true))
        .filter_map(|id| registry.destination(&id).map(|definition| definition.display_name.clone()))
        .take(limit)
        .collect()
}

pub fn request_accepted_context(
    registry: &DestinationRegistry,
    recipient: impl Into<String>,
    destination: &DestinationId,
) -> Option<ResponseContext> {
    let display_name = registry.destination(destination)?.display_name.clone();
    Some(ResponseContext::RequestAccepted {
        recipient: recipient.into(),
        destination: display_name,
    })
}

pub fn request_queued_context(
    registry: &DestinationRegistry,
    recipient: impl Into<String>,
    destination: &DestinationId,
    queue_position: Option<usize>,
    queue_length: Option<usize>,
) -> Option<ResponseContext> {
    let display_name = registry.destination(destination)?.display_name.clone();
    Some(ResponseContext::RequestQueued {
        recipient: recipient.into(),
        destination: display_name,
        queue_position,
        queue_length,
    })
}

pub fn unsupported_destination_context(
    registry: &DestinationRegistry,
    recipient: impl Into<String>,
    requested_destination: impl Into<String>,
    alternatives_limit: usize,
) -> ResponseContext {
    ResponseContext::UnsupportedDestination {
        recipient: recipient.into(),
        requested_destination: requested_destination.into(),
        alternatives: available_display_names(registry, None, alternatives_limit),
    }
}

pub fn unavailable_destination_context(
    registry: &DestinationRegistry,
    recipient: impl Into<String>,
    destination: &DestinationId,
    alternatives_limit: usize,
) -> Option<ResponseContext> {
    let definition = registry.destination(destination)?;
    let status = registry.status(destination)?;
    if status.availability == Availability::Enabled {
        return None;
    }

    let reason = match status.availability {
        Availability::DisabledLowShards => DestinationUnavailableReason::LowShards,
        Availability::DisabledManual | Availability::DisabledMaintenance => {
            DestinationUnavailableReason::ManualOffOrMaintenance
        }
        Availability::DisabledUnhealthyTeam => DestinationUnavailableReason::UnhealthyTeam,
        Availability::Unknown => DestinationUnavailableReason::Temporary,
        Availability::Enabled => return None,
    };

    Some(ResponseContext::DestinationUnavailable {
        recipient: recipient.into(),
        destination: definition.display_name.clone(),
        reason,
        alternatives: available_display_names(registry, Some(destination), alternatives_limit),
    })
}

pub fn summon_completed_context(
    registry: &DestinationRegistry,
    recipient: impl Into<String>,
    completed_destination: &DestinationId,
    alternatives_limit: usize,
) -> ResponseContext {
    ResponseContext::SummonCompleted {
        recipient: recipient.into(),
        alternatives: available_display_names(
            registry,
            Some(completed_destination),
            alternatives_limit,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::destination_registry::{
        DestinationDefinition, DestinationObservation, ExecutionTeam, ManualOverride,
        RegistryConfig, RoleAssignment, ShardPolicy, TeamHealth,
    };

    fn id(value: &str) -> DestinationId {
        DestinationId::new(value).unwrap()
    }

    fn registry() -> DestinationRegistry {
        let team = |id: &str| ExecutionTeam {
            id: format!("team-{id}"),
            resource_key: format!("resource-{id}"),
            summoner: RoleAssignment {
                role: "summoner".into(),
                character: Some(format!("Summoner{id}")),
                exclusive: true,
            },
            clickers: vec![
                RoleAssignment {
                    role: "clicker1".into(),
                    character: Some(format!("Click{id}A")),
                    exclusive: true,
                },
                RoleAssignment {
                    role: "clicker2".into(),
                    character: Some(format!("Click{id}B")),
                    exclusive: true,
                },
            ],
        };
        let destination = |id_value: &str, display: &str, shard_policy| DestinationDefinition {
            id: id(id_value),
            display_name: display.into(),
            aliases: vec![],
            enabled: true,
            execution_team: format!("team-{id_value}"),
            required_clickers: 2,
            shard_policy,
            price: None,
            metadata: Default::default(),
        };
        DestinationRegistry::from_config(RegistryConfig {
            schema_version: 1,
            destinations: vec![
                destination("hyjal", "Hyjal", Some(ShardPolicy { disable_below: 3, reenable_at: 5, allow_unknown: false })),
                destination("winterspring", "Winterspring", None),
                destination("azshara", "Azshara", None),
            ],
            execution_teams: vec![team("hyjal"), team("winterspring"), team("azshara")],
        })
        .unwrap()
    }

    fn mark_healthy(registry: &mut DestinationRegistry, destination: &DestinationId, shards: Option<u32>) {
        registry
            .set_observation(
                destination,
                DestinationObservation {
                    shard_count: shards,
                    manual_override: ManualOverride::Automatic,
                    team_health: TeamHealth::Healthy,
                },
            )
            .unwrap();
    }

    #[test]
    fn unsupported_uses_only_currently_available_display_names() {
        let mut registry = registry();
        let hyjal = id("hyjal");
        let winterspring = id("winterspring");
        let azshara = id("azshara");
        mark_healthy(&mut registry, &hyjal, Some(10));
        mark_healthy(&mut registry, &winterspring, None);
        mark_healthy(&mut registry, &azshara, None);

        let context = unsupported_destination_context(&registry, "Sam", "Feralas", 10);
        match context {
            ResponseContext::UnsupportedDestination { requested_destination, alternatives, .. } => {
                assert_eq!(requested_destination, "Feralas");
                assert_eq!(alternatives, vec!["Azshara", "Hyjal", "Winterspring"]);
            }
            other => panic!("unexpected context: {other:?}"),
        }
    }

    #[test]
    fn low_shards_maps_to_low_shards_response_and_excludes_requested_destination() {
        let mut registry = registry();
        let hyjal = id("hyjal");
        let winterspring = id("winterspring");
        let azshara = id("azshara");
        mark_healthy(&mut registry, &hyjal, Some(2));
        mark_healthy(&mut registry, &winterspring, None);
        mark_healthy(&mut registry, &azshara, None);

        let context = unavailable_destination_context(&registry, "Sam", &hyjal, 10).unwrap();
        match context {
            ResponseContext::DestinationUnavailable { destination, reason, alternatives, .. } => {
                assert_eq!(destination, "Hyjal");
                assert_eq!(reason, DestinationUnavailableReason::LowShards);
                assert_eq!(alternatives, vec!["Azshara", "Winterspring"]);
            }
            other => panic!("unexpected context: {other:?}"),
        }
    }

    #[test]
    fn unhealthy_team_maps_to_unhealthy_team_response() {
        let mut registry = registry();
        let hyjal = id("hyjal");
        registry
            .set_observation(
                &hyjal,
                DestinationObservation {
                    shard_count: Some(10),
                    manual_override: ManualOverride::Automatic,
                    team_health: TeamHealth::Unhealthy,
                },
            )
            .unwrap();

        let context = unavailable_destination_context(&registry, "Sam", &hyjal, 3).unwrap();
        match context {
            ResponseContext::DestinationUnavailable { reason, .. } => {
                assert_eq!(reason, DestinationUnavailableReason::UnhealthyTeam);
            }
            other => panic!("unexpected context: {other:?}"),
        }
    }

    #[test]
    fn enabled_destination_has_no_unavailable_context() {
        let mut registry = registry();
        let hyjal = id("hyjal");
        mark_healthy(&mut registry, &hyjal, Some(10));
        assert!(unavailable_destination_context(&registry, "Sam", &hyjal, 3).is_none());
    }
}
