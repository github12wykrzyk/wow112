use crate::tele11_executor_process::{ExternalExecutorConfig, Identity};
use crate::tele11_service_core::{RouteConfig, ServiceCoreConfig};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdentityConfig {
    pub account: String,
    pub character: String,
}

impl IdentityConfig {
    fn validate(&self, label: &str) -> Result<(), String> {
        if self.account.trim().is_empty() || self.character.trim().is_empty() {
            return Err(format!("{label} account/character cannot be empty"));
        }
        Ok(())
    }

    fn runtime(&self) -> Identity {
        Identity {
            account: self.account.clone(),
            character: self.character.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamConfig {
    pub destination: String,
    pub resource: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub summoner: IdentityConfig,
    pub clicker1: IdentityConfig,
    pub clicker2: IdentityConfig,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceFileConfig {
    pub schema_version: u32,
    pub journal_path: String,
    pub run_root: String,
    #[serde(default = "default_dedup_ms")]
    pub dedup_window_ms: u64,
    #[serde(default = "default_expiry_ms")]
    pub expiry_ms: u64,
    #[serde(default = "default_ready_secs")]
    pub ready_timeout_secs: u64,
    #[serde(default = "default_active_secs")]
    pub active_timeout_secs: u64,
    #[serde(default = "default_offer_settle_ms")]
    pub offer_settle_ms: u64,
    #[serde(default = "default_realm_index")]
    pub realm_index: usize,
    pub teams: Vec<TeamConfig>,
}

fn default_dedup_ms() -> u64 {
    30_000
}
fn default_expiry_ms() -> u64 {
    180_000
}
fn default_ready_secs() -> u64 {
    180
}
fn default_active_secs() -> u64 {
    360
}
fn default_offer_settle_ms() -> u64 {
    3_000
}
fn default_realm_index() -> usize {
    1
}

impl ServiceFileConfig {
    pub fn from_json(text: &str) -> Result<Self, String> {
        let config: Self = serde_json::from_str(text)
            .map_err(|error| format!("parse TELE11 service config failed: {error}"))?;
        config.validate()?;
        Ok(config)
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|error| format!("read TELE11 config {} failed: {error}", path.display()))?;
        Self::from_json(&text)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != 1 {
            return Err(format!(
                "unsupported TELE11 service config schema_version={}",
                self.schema_version
            ));
        }
        if self.journal_path.trim().is_empty() || self.run_root.trim().is_empty() {
            return Err("journal_path and run_root are required".to_string());
        }
        let enabled = self.teams.iter().filter(|team| team.enabled).count();
        if enabled == 0 {
            return Err("TELE11 requires at least one enabled execution team".to_string());
        }
        let mut destinations = BTreeSet::new();
        let mut resources = BTreeSet::new();
        let mut characters = BTreeSet::new();
        for team in self.teams.iter().filter(|team| team.enabled) {
            let destination = team.destination.trim().to_ascii_lowercase();
            let resource = team.resource.trim().to_string();
            if destination.is_empty() || resource.is_empty() {
                return Err("enabled TELE11 team has empty destination/resource".to_string());
            }
            if !destinations.insert(destination.clone()) {
                return Err(format!("duplicate enabled destination: {destination}"));
            }
            if !resources.insert(resource.clone()) {
                return Err(format!("duplicate enabled resource: {resource}"));
            }
            team.summoner.validate(&format!("{destination}/summoner"))?;
            team.clicker1.validate(&format!("{destination}/clicker1"))?;
            team.clicker2.validate(&format!("{destination}/clicker2"))?;
            for identity in [&team.summoner, &team.clicker1, &team.clicker2] {
                let key = identity.character.trim().to_ascii_lowercase();
                if !characters.insert(key.clone()) {
                    return Err(format!(
                        "character {key} assigned to more than one enabled TELE11 role"
                    ));
                }
            }
        }
        Ok(())
    }

    pub fn core_config(&self) -> Result<ServiceCoreConfig, String> {
        self.validate()?;
        Ok(ServiceCoreConfig {
            schema_version: 1,
            dedup_window_ms: self.dedup_window_ms,
            expiry_ms: self.expiry_ms,
            routes: self
                .teams
                .iter()
                .filter(|team| team.enabled)
                .map(|team| RouteConfig {
                    destination: team.destination.trim().to_ascii_lowercase(),
                    resource: team.resource.clone(),
                })
                .collect(),
        })
    }

    pub fn journal_path(&self) -> PathBuf {
        PathBuf::from(&self.journal_path)
    }

    pub fn team_for_resource(&self, resource: &str) -> Option<&TeamConfig> {
        self.teams
            .iter()
            .find(|team| team.enabled && team.resource == resource)
    }

    pub fn executor_config(
        &self,
        team: &TeamConfig,
        customer: &str,
        password: &str,
        job_id: &str,
    ) -> ExternalExecutorConfig {
        let safe_job = job_id
            .chars()
            .map(|ch| if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' { ch } else { '_' })
            .collect::<String>();
        ExternalExecutorConfig {
            customer: customer.to_string(),
            destination: team.destination.trim().to_ascii_lowercase(),
            resource: team.resource.clone(),
            summoner: team.summoner.runtime(),
            clicker1: team.clicker1.runtime(),
            clicker2: team.clicker2.runtime(),
            password: password.to_string(),
            realm_index: self.realm_index,
            run_dir: PathBuf::from(&self.run_root).join(safe_job),
            ready_timeout: Duration::from_secs(self.ready_timeout_secs),
            active_timeout: Duration::from_secs(self.active_timeout_secs),
            offer_settle: Duration::from_millis(self.offer_settle_ms),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_json() -> &'static str {
        r#"{
          "schema_version": 1,
          "journal_path": "state/tele11.jsonl",
          "run_root": "runs/tele11",
          "teams": [{
            "destination": "winterspring",
            "resource": "summon/winterspring",
            "summoner": {"account":"sum","character":"Summoner"},
            "clicker1": {"account":"c1","character":"Clickone"},
            "clicker2": {"account":"c2","character":"Clicktwo"}
          }]
        }"#
    }

    #[test]
    fn parses_valid_service_config() {
        let config = ServiceFileConfig::from_json(valid_json()).unwrap();
        assert_eq!(config.core_config().unwrap().routes.len(), 1);
        assert_eq!(config.realm_index, 1);
    }

    #[test]
    fn rejects_shared_character_across_enabled_roles() {
        let broken = valid_json().replace("Clicktwo", "Summoner");
        assert!(ServiceFileConfig::from_json(&broken).is_err());
    }
}
