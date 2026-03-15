/*
    types/primitives.rs
    Just some type aliases and primitives
*/

pub type NodeId = u128;
pub type KeyHash = u64;
pub type Epoch = u64;

#[derive(Debug)]
pub enum RateLimitResult {
    Allow { remaining: u64 },
    Deny { retry_after_ms: u64 },
}