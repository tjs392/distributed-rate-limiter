/*
    config.rs
    Parses config file for node setup
 */

use serde::Deserialize;

#[derive(Deserialize)]
pub struct Config {
    pub node: NodeConfig,
    pub gossip: GossipConfig,
    pub server: ServerConfig,
    pub membership: MembershipConfig,
    pub rules_file: String,
}

#[derive(Deserialize)]
pub struct SeedNode {
    pub id: u128,
    pub address: String,
}

#[derive(Deserialize)]
pub struct NodeConfig {
    pub id: u128,
    pub seeds: Vec<SeedNode>,
    pub eviction_ttl_seconds: u64,
    pub eviction_interval_seconds: u64,
    pub persistent_store_path: String,
}

#[derive(Deserialize)]
pub struct GossipConfig {
    pub interval_ms: u64,
    #[serde(default = "default_tier_count")]
    pub tier_count: usize,
    #[serde(default = "default_alpha")]
    pub alpha: f64,
    #[serde(default)]
    pub continuous: bool,
}

fn default_tier_count() -> usize { 5 }
fn default_alpha() -> f64 { 2.0 }

#[derive(Deserialize)]
pub struct ServerConfig {
    pub http_port: u16,
    pub gossip_port: u16,
    pub metrics_port: u16,
    pub grpc_port: u16,
}

#[derive(Deserialize)]
pub struct MembershipConfig {
    pub probe_interval_seconds: u64,
    pub probe_timeout_ms: u64,
    pub min_suspicion_timeout_ms: u64,
    pub base_suspicion_timeout_ms: u64,
    pub max_health_score: u32,
}

pub fn load(path: &str) -> Config {
    let contents = std::fs::read_to_string(path).expect("Failed to read config file");
    toml::from_str(&contents).expect("Failed to parse config file")
}