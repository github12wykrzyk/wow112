use std::collections::BTreeMap;

use crate::destination_registry::{
    Availability, AvailabilityReason, DestinationRegistry,
};
use crate::tele08_bc_adapter::{classification_to_request, AdmissionRejection};
use crate::tele08_whisper_parser::{
    normalize_whisper_text, DestinationAlias, DestinationKey, ParserConfig, WhisperClassification,
};
use tele08_request_queue::{QueueConfig, SummonRequest, Timestamp};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RoutingRejection {
    ParserAdmission(AdmissionRejection),
    UnknownDestination(String),
    DestinationUnavailable {
        destination: String,
        availability: Availability,
        reason: AvailabilityReason,
        alternatives: Vec<String>,
    },
    MissingResource(String),
}

/// Builds Track-B parser configuration from Track-D's canonical registry.
/// Non-destination parser policy stays owned by B; destination vocabulary is
/// replaced entirely so there is one runtime source of truth for destinations.
pub fn parser_config_from_registry(registry: &DestinationRegistry) -> ParserConfig {
    let mut config = ParserConfig::default();
    let mut aliases = BTreeMap::<String, String>::new();

    for definition in &registry.config().destinations {
        let canonical = definition.id.as_str().to_owned();
        for raw in std::iter::once(definition.id.as_str())
            .chain(std::iter::once(definition.display_name.as_str()))
            .chain(definition.aliases.iter().map(String::as_str))
        {
            let normalized = normalize_whisper_text(raw);
            if !normalized.is_empty() {
                aliases.insert(normalized, canonical.clone());
            }
        }
    }

    config.destination_aliases = aliases
        .into_iter()
        .map(|(alias, canonical)| DestinationAlias {
            alias,
            key: DestinationKey::new(canonical),
        })
        .collect();
    config
}

/// Builds QueueConfig strictly from Track-D execution-team resource ownership.
/// Availability remains a runtime admission decision and does not mutate the
/// structural destination->resource mapping.
pub fn queue_config_from_registry(
    registry: &DestinationRegistry,
    dedup_window: Timestamp,
    expiry: Timestamp,
) -> Result<QueueConfig, RoutingRejection> {
    let mut config = QueueConfig::new(dedup_window, expiry);
    for definition in &registry.config().destinations {
        let destination = definition.id.as_str();
        let resource = registry
            .resource_key(&definition.id)
            .ok_or_else(|| RoutingRejection::MissingResource(destination.to_owned()))?;
        config.map_destination_resource(destination, resource);
    }
    Ok(config)
}

/// Converts B classification into a C request only after D resolves the
/// destination and confirms it is currently Enabled.
pub fn classification_to_routed_request(
    classification: &WhisperClassification,
    registry: &DestinationRegistry,
) -> Result<SummonRequest, RoutingRejection> {
    let mut request =
        classification_to_request(classification).map_err(RoutingRejection::ParserAdmission)?;

    let destination = registry
        .resolve_destination(&request.destination)
        .ok_or_else(|| RoutingRejection::UnknownDestination(request.destination.clone()))?;
    let status = registry
        .status(&destination)
        .ok_or_else(|| RoutingRejection::UnknownDestination(destination.to_string()))?;

    if status.availability != Availability::Enabled {
        return Err(RoutingRejection::DestinationUnavailable {
            destination: destination.to_string(),
            availability: status.availability,
            reason: status.reason.clone(),
            alternatives: registry
                .alternatives_for(&destination, 3)
                .into_iter()
                .map(|id| id.to_string())
                .collect(),
        });
    }

    let resource = registry
        .resource_key(&destination)
        .ok_or_else(|| RoutingRejection::MissingResource(destination.to_string()))?;

    request.destination = destination.to_string();
    request
        .metadata
        .insert("destination_source".into(), "tele08_registry".into());
    request
        .metadata
        .insert("execution_resource".into(), resource.to_owned());
    request
        .metadata
        .insert("availability_at_admission".into(), "Enabled".into());
    Ok(request)
}
