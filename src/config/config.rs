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
}

#[derive(Deserialize)]
pub struct NodeConfig {
    pub id: u128,
    pub seeds: Vec<String>,
    pub eviction_ttl_seconds: u64,
}

#[derive(Deserialize)]
pub struct GossipConfig {
    pub interval_ms: u64,
}

#[derive(Deserialize)]
pub struct ServerConfig {
    pub http_port: u16,
    pub gossip_port: u16,
}

pub fn load(path: &str) -> Config {
    let contents = std::fs::read_to_string(path).expect("Failed to read config file");
    toml::from_str(&contents).expect("Failed to parse config file")
}