use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DestinationId(String);

impl DestinationId {
    pub fn new(value: impl Into<String>) -> Result<Self, RegistryError> {
        let value = value.into();
        validate_id(&value, "destination id")?;
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for DestinationId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RoleAssignment {
    pub role: String,
    #[serde(default)]
    pub character: Option<String>,
    #[serde(default)]
    pub exclusive: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ExecutionTeam {
    pub id: String,
    pub resource_key: String,
    pub summoner: RoleAssignment,
    pub clickers: Vec<RoleAssignment>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ShardPolicy {
    pub disable_below: u32,
    pub reenable_at: u32,
    #[serde(default)]
    pub allow_unknown: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PriceMetadata {
    pub amount_copper: u64,
    #[serde(default)]
    pub currency: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DestinationDefinition {
    pub id: DestinationId,
    pub display_name: String,
    #[serde(default)]
    pub aliases: Vec<String>,
    pub enabled: bool,
    pub execution_team: String,
    pub required_clickers: usize,
    #[serde(default)]
    pub shard_policy: Option<ShardPolicy>,
    #[serde(default)]
    pub price: Option<PriceMetadata>,
    #[serde(default)]
    pub metadata: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RegistryConfig {
    pub schema_version: u32,
    pub destinations: Vec<DestinationDefinition>,
    pub execution_teams: Vec<ExecutionTeam>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Availability {
    Enabled,
    DisabledManual,
    DisabledLowShards,
    DisabledUnhealthyTeam,
    DisabledMaintenance,
    Unknown,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum AvailabilityReason {
    EnabledNoShardPolicy,
    EnabledShardPolicySatisfied {
        observed: u32,
    },
    EnabledUnknownShardsExplicitlyAllowed,
    ConfiguredDisabled,
    ManualOff,
    Maintenance,
    LowShards {
        observed: u32,
        disable_below: u32,
        reenable_at: u32,
    },
    ShardCountUnknown,
    TeamUnhealthy,
    TeamHealthUnknown,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum ManualOverride {
    #[default]
    Automatic,
    ForceOff,
    Maintenance,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum TeamHealth {
    Healthy,
    Unhealthy,
    #[default]
    Unknown,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct DestinationObservation {
    pub shard_count: Option<u32>,
    pub manual_override: ManualOverride,
    pub team_health: TeamHealth,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AvailabilityDecision {
    pub availability: Availability,
    pub reason: AvailabilityReason,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DestinationStateChanged {
    pub destination: DestinationId,
    pub old: Availability,
    pub new: Availability,
    pub reason: AvailabilityReason,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DestinationStatus {
    pub destination: DestinationId,
    pub availability: Availability,
    pub reason: AvailabilityReason,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RegistryError {
    Parse(String),
    Validation(String),
    UnknownDestination(String),
}

impl fmt::Display for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Parse(message) => write!(f, "registry parse error: {message}"),
            Self::Validation(message) => write!(f, "registry validation error: {message}"),
            Self::UnknownDestination(id) => write!(f, "unknown destination: {id}"),
        }
    }
}

impl std::error::Error for RegistryError {}

impl From<serde_json::Error> for RegistryError {
    fn from(value: serde_json::Error) -> Self {
        Self::Parse(value.to_string())
    }
}

pub fn evaluate_availability(
    definition: &DestinationDefinition,
    observation: DestinationObservation,
    previous: Option<Availability>,
) -> AvailabilityDecision {
    match observation.manual_override {
        ManualOverride::ForceOff => {
            return decision(Availability::DisabledManual, AvailabilityReason::ManualOff);
        }
        ManualOverride::Maintenance => {
            return decision(
                Availability::DisabledMaintenance,
                AvailabilityReason::Maintenance,
            );
        }
        ManualOverride::Automatic => {}
    }

    if !definition.enabled {
        return decision(
            Availability::DisabledManual,
            AvailabilityReason::ConfiguredDisabled,
        );
    }

    match observation.team_health {
        TeamHealth::Unhealthy => {
            return decision(
                Availability::DisabledUnhealthyTeam,
                AvailabilityReason::TeamUnhealthy,
            );
        }
        TeamHealth::Unknown => {
            return decision(Availability::Unknown, AvailabilityReason::TeamHealthUnknown);
        }
        TeamHealth::Healthy => {}
    }

    let Some(policy) = definition.shard_policy.as_ref() else {
        return decision(
            Availability::Enabled,
            AvailabilityReason::EnabledNoShardPolicy,
        );
    };

    let Some(shards) = observation.shard_count else {
        return if policy.allow_unknown {
            decision(
                Availability::Enabled,
                AvailabilityReason::EnabledUnknownShardsExplicitlyAllowed,
            )
        } else {
            decision(Availability::Unknown, AvailabilityReason::ShardCountUnknown)
        };
    };

    let low_latched = previous == Some(Availability::DisabledLowShards);
    let below_disable = shards < policy.disable_below;
    let below_reenable = low_latched && shards < policy.reenable_at;
    if below_disable || below_reenable {
        return decision(
            Availability::DisabledLowShards,
            AvailabilityReason::LowShards {
                observed: shards,
                disable_below: policy.disable_below,
                reenable_at: policy.reenable_at,
            },
        );
    }

    decision(
        Availability::Enabled,
        AvailabilityReason::EnabledShardPolicySatisfied { observed: shards },
    )
}

fn decision(availability: Availability, reason: AvailabilityReason) -> AvailabilityDecision {
    AvailabilityDecision {
        availability,
        reason,
    }
}

pub struct DestinationRegistry {
    config: RegistryConfig,
    aliases: BTreeMap<String, DestinationId>,
    observations: BTreeMap<DestinationId, DestinationObservation>,
    statuses: BTreeMap<DestinationId, AvailabilityDecision>,
}

impl DestinationRegistry {
    pub fn from_json(input: &str) -> Result<Self, RegistryError> {
        let config: RegistryConfig = serde_json::from_str(input)?;
        Self::from_config(config)
    }

    pub fn from_config(config: RegistryConfig) -> Result<Self, RegistryError> {
        let aliases = validate_config(&config)?;
        let observations = config
            .destinations
            .iter()
            .map(|destination| (destination.id.clone(), DestinationObservation::default()))
            .collect::<BTreeMap<_, _>>();
        let statuses = compute_statuses(&config, &observations, None);
        Ok(Self {
            config,
            aliases,
            observations,
            statuses,
        })
    }

    pub fn config(&self) -> &RegistryConfig {
        &self.config
    }

    pub fn resolve_destination(&self, input: &str) -> Option<DestinationId> {
        let key = normalize_key(input);
        if key.is_empty() {
            return None;
        }
        self.aliases.get(&key).cloned()
    }

    pub fn destination(&self, id: &DestinationId) -> Option<&DestinationDefinition> {
        self.config
            .destinations
            .iter()
            .find(|destination| &destination.id == id)
    }

    pub fn execution_team(&self, id: &DestinationId) -> Option<&ExecutionTeam> {
        let destination = self.destination(id)?;
        self.config
            .execution_teams
            .iter()
            .find(|team| team.id == destination.execution_team)
    }

    pub fn resource_key(&self, id: &DestinationId) -> Option<&str> {
        self.execution_team(id)
            .map(|team| team.resource_key.as_str())
    }

    pub fn set_observation(
        &mut self,
        id: &DestinationId,
        observation: DestinationObservation,
    ) -> Result<Option<DestinationStateChanged>, RegistryError> {
        let definition = self
            .destination(id)
            .cloned()
            .ok_or_else(|| RegistryError::UnknownDestination(id.to_string()))?;
        let previous = self.statuses.get(id).cloned();
        let next = evaluate_availability(
            &definition,
            observation,
            previous.as_ref().map(|status| status.availability),
        );

        self.observations.insert(id.clone(), observation);
        self.statuses.insert(id.clone(), next.clone());

        Ok(previous.and_then(|old| {
            (old.availability != next.availability).then(|| DestinationStateChanged {
                destination: id.clone(),
                old: old.availability,
                new: next.availability,
                reason: next.reason,
            })
        }))
    }

    pub fn status(&self, id: &DestinationId) -> Option<&AvailabilityDecision> {
        self.statuses.get(id)
    }

    pub fn available_destinations(&self) -> Vec<DestinationId> {
        self.statuses
            .iter()
            .filter_map(|(id, status)| {
                (status.availability == Availability::Enabled).then(|| id.clone())
            })
            .collect()
    }

    pub fn unavailable_destination_reason(
        &self,
        id: &DestinationId,
    ) -> Option<AvailabilityReason> {
        self.statuses.get(id).and_then(|status| {
            (status.availability != Availability::Enabled).then(|| status.reason.clone())
        })
    }

    pub fn alternatives_for(&self, requested: &DestinationId, limit: usize) -> Vec<DestinationId> {
        self.available_destinations()
            .into_iter()
            .filter(|id| id != requested)
            .take(limit)
            .collect()
    }

    pub fn destination_status_snapshot(&self) -> Vec<DestinationStatus> {
        self.statuses
            .iter()
            .map(|(destination, status)| DestinationStatus {
                destination: destination.clone(),
                availability: status.availability,
                reason: status.reason.clone(),
            })
            .collect()
    }

    pub fn reload_json(
        &mut self,
        input: &str,
    ) -> Result<Vec<DestinationStateChanged>, RegistryError> {
        let config: RegistryConfig = serde_json::from_str(input)?;
        self.reload_config(config)
    }

    pub fn reload_config(
        &mut self,
        config: RegistryConfig,
    ) -> Result<Vec<DestinationStateChanged>, RegistryError> {
        let aliases = validate_config(&config)?;
        let observations = config
            .destinations
            .iter()
            .map(|definition| {
                let observation = self
                    .observations
                    .get(&definition.id)
                    .copied()
                    .unwrap_or_default();
                (definition.id.clone(), observation)
            })
            .collect::<BTreeMap<_, _>>();
        let statuses = compute_statuses(&config, &observations, Some(&self.statuses));
        let changes = statuses
            .iter()
            .filter_map(|(id, next)| {
                let old = self.statuses.get(id)?;
                (old.availability != next.availability).then(|| DestinationStateChanged {
                    destination: id.clone(),
                    old: old.availability,
                    new: next.availability,
                    reason: next.reason.clone(),
                })
            })
            .collect();

        self.config = config;
        self.aliases = aliases;
        self.observations = observations;
        self.statuses = statuses;
        Ok(changes)
    }
}

fn compute_statuses(
    config: &RegistryConfig,
    observations: &BTreeMap<DestinationId, DestinationObservation>,
    previous: Option<&BTreeMap<DestinationId, AvailabilityDecision>>,
) -> BTreeMap<DestinationId, AvailabilityDecision> {
    config
        .destinations
        .iter()
        .map(|definition| {
            let observation = observations
                .get(&definition.id)
                .copied()
                .unwrap_or_default();
            let old = previous
                .and_then(|statuses| statuses.get(&definition.id))
                .map(|status| status.availability);
            (
                definition.id.clone(),
                evaluate_availability(definition, observation, old),
            )
        })
        .collect()
}

fn validate_config(
    config: &RegistryConfig,
) -> Result<BTreeMap<String, DestinationId>, RegistryError> {
    if config.schema_version == 0 {
        return Err(validation("schema_version must be greater than zero"));
    }
    if config.destinations.is_empty() {
        return Err(validation("at least one destination is required"));
    }

    let mut team_ids = BTreeSet::new();
    let mut resource_keys = BTreeSet::new();
    let mut exclusive_characters = BTreeMap::<String, String>::new();
    for team in &config.execution_teams {
        validate_id(&team.id, "execution team id")?;
        if !team_ids.insert(team.id.clone()) {
            return Err(validation(format!(
                "duplicate execution team id: {}",
                team.id
            )));
        }
        if team.resource_key.trim().is_empty() {
            return Err(validation(format!(
                "team {} has empty resource_key",
                team.id
            )));
        }
        if !resource_keys.insert(team.resource_key.clone()) {
            return Err(validation(format!(
                "duplicate execution team resource_key: {}",
                team.resource_key
            )));
        }
        validate_role(&team.id, &team.summoner, &mut exclusive_characters)?;
        for clicker in &team.clickers {
            validate_role(&team.id, clicker, &mut exclusive_characters)?;
        }
    }

    let teams = config
        .execution_teams
        .iter()
        .map(|team| (team.id.as_str(), team))
        .collect::<BTreeMap<_, _>>();
    let mut ids = BTreeSet::new();
    let mut aliases = BTreeMap::<String, DestinationId>::new();

    for destination in &config.destinations {
        validate_id(destination.id.as_str(), "destination id")?;
        if !ids.insert(destination.id.clone()) {
            return Err(validation(format!(
                "duplicate destination id: {}",
                destination.id
            )));
        }
        if destination.display_name.trim().is_empty() {
            return Err(validation(format!(
                "destination {} has empty display_name",
                destination.id
            )));
        }
        let Some(team) = teams.get(destination.execution_team.as_str()) else {
            return Err(validation(format!(
                "destination {} references missing execution team {}",
                destination.id, destination.execution_team
            )));
        };
        if destination.required_clickers == 0 {
            return Err(validation(format!(
                "destination {} requires zero clickers",
                destination.id
            )));
        }
        if team.clickers.len() < destination.required_clickers {
            return Err(validation(format!(
                "destination {} requires {} clickers but team {} exposes {} clicker roles",
                destination.id,
                destination.required_clickers,
                team.id,
                team.clickers.len()
            )));
        }
        if let Some(policy) = destination.shard_policy.as_ref() {
            if policy.disable_below == 0 {
                return Err(validation(format!(
                    "destination {} has disable_below=0; omit shard_policy instead",
                    destination.id
                )));
            }
            if policy.reenable_at < policy.disable_below {
                return Err(validation(format!(
                    "destination {} has reenable_at below disable_below",
                    destination.id
                )));
            }
        }

        register_alias(&mut aliases, destination.id.as_str(), &destination.id)?;
        register_alias(&mut aliases, &destination.display_name, &destination.id)?;
        for alias in &destination.aliases {
            register_alias(&mut aliases, alias, &destination.id)?;
        }
    }

    Ok(aliases)
}

fn validate_role(
    team_id: &str,
    assignment: &RoleAssignment,
    exclusive_characters: &mut BTreeMap<String, String>,
) -> Result<(), RegistryError> {
    if assignment.role.trim().is_empty() {
        return Err(validation(format!(
            "team {team_id} contains an empty role"
        )));
    }
    if let Some(character) = assignment.character.as_ref() {
        let character = character.trim();
        if character.is_empty() {
            return Err(validation(format!(
                "team {team_id} contains an empty character assignment"
            )));
        }
        if assignment.exclusive {
            let key = normalize_key(character);
            let owner = format!("{team_id}/{}", assignment.role);
            if let Some(existing) = exclusive_characters.insert(key, owner.clone()) {
                return Err(validation(format!(
                    "exclusive character {character} assigned to both {existing} and {owner}"
                )));
            }
        }
    }
    Ok(())
}

fn register_alias(
    aliases: &mut BTreeMap<String, DestinationId>,
    alias: &str,
    id: &DestinationId,
) -> Result<(), RegistryError> {
    let key = normalize_key(alias);
    if key.is_empty() {
        return Err(validation(format!(
            "destination {id} has an empty alias"
        )));
    }
    if let Some(existing) = aliases.get(&key) {
        if existing != id {
            return Err(validation(format!(
                "ambiguous alias {alias:?} resolves to both {existing} and {id}"
            )));
        }
    } else {
        aliases.insert(key, id.clone());
    }
    Ok(())
}

fn validate_id(value: &str, kind: &str) -> Result<(), RegistryError> {
    if value.is_empty()
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Err(validation(format!(
            "{kind} {value:?} must use only ASCII letters, digits, '-' or '_'"
        )));
    }
    Ok(())
}

fn normalize_key(value: &str) -> String {
    value
        .chars()
        .flat_map(char::to_lowercase)
        .filter(|ch| ch.is_alphanumeric())
        .collect()
}

fn validation(message: impl Into<String>) -> RegistryError {
    RegistryError::Validation(message.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEEDED: &str = include_str!("../config/tele08_destinations.example.json");

    fn registry() -> DestinationRegistry {
        DestinationRegistry::from_json(SEEDED).expect("seed config must validate")
    }

    fn id(value: &str) -> DestinationId {
        DestinationId::new(value).unwrap()
    }

    fn healthy(shards: Option<u32>) -> DestinationObservation {
        DestinationObservation {
            shard_count: shards,
            manual_override: ManualOverride::Automatic,
            team_health: TeamHealth::Healthy,
        }
    }

    #[test]
    fn seeded_destinations_are_exactly_current_three() {
        let registry = registry();
        let ids = registry
            .config()
            .destinations
            .iter()
            .map(|destination| destination.id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, vec!["azshara", "hyjal", "winterspring"]);
    }

    #[test]
    fn aliases_are_case_and_punctuation_friendly() {
        let registry = registry();
        assert_eq!(registry.resolve_destination("HYJAL"), Some(id("hyjal")));
        assert_eq!(
            registry.resolve_destination("Hydraxian Waterlords!!!"),
            Some(id("azshara"))
        );
        assert_eq!(
            registry.resolve_destination("winter-spring"),
            Some(id("winterspring"))
        );
    }

    #[test]
    fn ambiguous_alias_is_rejected() {
        let mut config = registry().config().clone();
        config.destinations[0].aliases.push("shared".into());
        config.destinations[1].aliases.push("shared".into());
        assert!(matches!(
            DestinationRegistry::from_config(config),
            Err(RegistryError::Validation(message)) if message.contains("ambiguous alias")
        ));
    }

    #[test]
    fn feralas_remains_unknown() {
        assert_eq!(registry().resolve_destination("feralas"), None);
    }

    #[test]
    fn manual_off_wins() {
        let mut registry = registry();
        let hyjal = id("hyjal");
        registry
            .set_observation(
                &hyjal,
                DestinationObservation {
                    shard_count: Some(999),
                    manual_override: ManualOverride::ForceOff,
                    team_health: TeamHealth::Healthy,
                },
            )
            .unwrap();
        assert_eq!(
            registry.status(&hyjal).unwrap().availability,
            Availability::DisabledManual
        );
    }

    #[test]
    fn low_shards_hysteresis_and_recovery_work() {
        let mut config = registry().config().clone();
        let definition = config
            .destinations
            .iter_mut()
            .find(|destination| destination.id == id("hyjal"))
            .unwrap();
        definition.shard_policy = Some(ShardPolicy {
            disable_below: 5,
            reenable_at: 8,
            allow_unknown: false,
        });
        let mut registry = DestinationRegistry::from_config(config).unwrap();
        let hyjal = id("hyjal");

        registry.set_observation(&hyjal, healthy(Some(4))).unwrap();
        assert_eq!(
            registry.status(&hyjal).unwrap().availability,
            Availability::DisabledLowShards
        );
        registry.set_observation(&hyjal, healthy(Some(6))).unwrap();
        assert_eq!(
            registry.status(&hyjal).unwrap().availability,
            Availability::DisabledLowShards
        );
        let event = registry
            .set_observation(&hyjal, healthy(Some(8)))
            .unwrap()
            .expect("recovery emits state-change event");
        assert_eq!(event.old, Availability::DisabledLowShards);
        assert_eq!(event.new, Availability::Enabled);
    }

    #[test]
    fn unknown_shards_fail_closed_when_policy_requires_observation() {
        let mut config = registry().config().clone();
        let definition = config
            .destinations
            .iter_mut()
            .find(|destination| destination.id == id("hyjal"))
            .unwrap();
        definition.shard_policy = Some(ShardPolicy {
            disable_below: 5,
            reenable_at: 8,
            allow_unknown: false,
        });
        let mut registry = DestinationRegistry::from_config(config).unwrap();
        let hyjal = id("hyjal");
        registry.set_observation(&hyjal, healthy(None)).unwrap();
        assert_eq!(
            registry.status(&hyjal).unwrap().availability,
            Availability::Unknown
        );
        assert_eq!(
            registry.status(&hyjal).unwrap().reason,
            AvailabilityReason::ShardCountUnknown
        );
    }

    #[test]
    fn unhealthy_team_disables_destination() {
        let mut registry = registry();
        let hyjal = id("hyjal");
        registry
            .set_observation(
                &hyjal,
                DestinationObservation {
                    team_health: TeamHealth::Unhealthy,
                    ..DestinationObservation::default()
                },
            )
            .unwrap();
        assert_eq!(
            registry.status(&hyjal).unwrap().availability,
            Availability::DisabledUnhealthyTeam
        );
    }

    #[test]
    fn recovery_to_enabled_emits_state_change() {
        let mut registry = registry();
        let hyjal = id("hyjal");
        registry
            .set_observation(
                &hyjal,
                DestinationObservation {
                    team_health: TeamHealth::Unhealthy,
                    ..DestinationObservation::default()
                },
            )
            .unwrap();
        let event = registry
            .set_observation(&hyjal, healthy(None))
            .unwrap()
            .expect("recovery must emit event");
        assert_eq!(event.old, Availability::DisabledUnhealthyTeam);
        assert_eq!(event.new, Availability::Enabled);
    }

    #[test]
    fn alternatives_exclude_unavailable_and_are_deterministic() {
        let mut registry = registry();
        for destination in [id("azshara"), id("hyjal"), id("winterspring")] {
            registry
                .set_observation(&destination, healthy(None))
                .unwrap();
        }
        registry
            .set_observation(
                &id("hyjal"),
                DestinationObservation {
                    manual_override: ManualOverride::ForceOff,
                    team_health: TeamHealth::Healthy,
                    shard_count: None,
                },
            )
            .unwrap();

        assert_eq!(
            registry.available_destinations(),
            vec![id("azshara"), id("winterspring")]
        );
        assert_eq!(
            registry.alternatives_for(&id("azshara"), 5),
            vec![id("winterspring")]
        );
    }

    #[test]
    fn invalid_reload_preserves_previous_valid_state() {
        let mut registry = registry();
        registry
            .set_observation(&id("hyjal"), healthy(None))
            .unwrap();
        let before = registry.destination_status_snapshot();
        let aliases_before = registry.resolve_destination("hydraxian");

        let mut invalid = registry.config().clone();
        invalid.destinations[0].aliases.push("hyjal".into());
        let invalid_json = serde_json::to_string(&invalid).unwrap();
        assert!(registry.reload_json(&invalid_json).is_err());

        assert_eq!(registry.destination_status_snapshot(), before);
        assert_eq!(registry.resolve_destination("hydraxian"), aliases_before);
    }

    #[test]
    fn validation_rejects_bad_thresholds_and_clicker_requirements() {
        let mut bad_threshold = registry().config().clone();
        bad_threshold.destinations[0].shard_policy = Some(ShardPolicy {
            disable_below: 8,
            reenable_at: 5,
            allow_unknown: false,
        });
        assert!(DestinationRegistry::from_config(bad_threshold).is_err());

        let mut bad_clickers = registry().config().clone();
        bad_clickers.destinations[0].required_clickers = 3;
        assert!(DestinationRegistry::from_config(bad_clickers).is_err());
    }

    #[test]
    fn conflicting_exclusive_character_assignments_are_rejected() {
        let mut config = registry().config().clone();
        config.execution_teams[0].summoner.character = Some("Sharedtoon".into());
        config.execution_teams[0].summoner.exclusive = true;
        config.execution_teams[1].summoner.character = Some("shared-toon".into());
        config.execution_teams[1].summoner.exclusive = true;
        assert!(DestinationRegistry::from_config(config).is_err());
    }
}
