use serde::Deserialize;

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RateLimitUnit {
    Second,
    Minute,
    Hour,
    Day,
}

#[derive(Debug, Deserialize)]
pub struct RateLimit {
    pub requests_per_unit: u64,
    pub unit: RateLimitUnit,
}

#[derive(Debug, Deserialize)]
pub struct DescriptorNode {
    pub key: Option<String>,
    pub value: Option<String>,
    pub rate_limit: Option<RateLimit>,
    #[serde(default)]
    pub descriptors: Vec<DescriptorNode>,
}

#[derive(Debug, Deserialize)]
pub struct DomainConfig {
    pub domain: String,
    #[serde(default)]
    pub descriptors: Vec<DescriptorNode>,
}

#[derive(Debug, Deserialize)]
pub struct RulesConfig {
    pub domains: Vec<DomainConfig>,
}