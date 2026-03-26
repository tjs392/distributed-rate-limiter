/*
    limiter/limiter.rs
    The Limiter. This connects to the store and checks the limits
    and current counts in epoch per KeyHash, Epoch pair
*/
use std::sync::Arc;
use metrics::{counter, histogram};
use xxhash_rust::xxh3::xxh3_64;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::crdt::store::CRDTStore;
use crate::persistence::DiskStore;
use crate::types::{NodeId, RateLimitResult};

pub struct Limiter {
    /// Store is shared across tasks
    store: Arc<CRDTStore>,
    disk_store: Arc<DiskStore>,
    node_id: NodeId,
    tier_count: usize,
    alpha: f64,
    continuous: bool,
    velocity_weight: f64,
    velocity_alpha:  f64,
}

/// Limiter receives a ref to the CRDTStore so it can do operations
impl Limiter {
    pub fn new(
        store: Arc<CRDTStore>,
        disk_store: Arc<DiskStore>,
        node_id: NodeId,
        tier_count: usize,
        alpha: f64,
        continuous: bool,
        velocity_weight: f64,
        velocity_alpha: f64,
    ) -> Self {
        Limiter { 
            store, 
            disk_store, 
            node_id, 
            tier_count, 
            alpha, 
            continuous, 
            velocity_weight, 
            velocity_alpha }
    }

    pub fn node_id(&self) -> NodeId {
        self.node_id
    }

    pub fn check_rate_limit(&self, key: &str, limit: u64, hits: u64, window_ms: u64) -> RateLimitResult {
        let start = std::time::Instant::now();

        let key_hash = xxh3_64(key.as_bytes());

        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        let epoch = now_ms / window_ms;
        let elapsed_frac = (now_ms % window_ms) as f64 / window_ms as f64;

        let mut estimate = self.store.estimated_count(key_hash, epoch, elapsed_frac);

        // check estimate and load from disk if didnt get an estimate from store
        // this is if the stuff has been evicted from the config
        // check your eviction_ttl_interval in node config if you're getting
        // cache misses a lot. keys that are over the eviction limit get 
        // evicted from the dashmap and persisted on disk
        if estimate == 0.0 {
            // check both current epoch and previous epoch cause thats what estimate wants
            if let Some(counter) = self.disk_store.get(key_hash, epoch) {
                self.store.merge_remote(key_hash, epoch, &counter);
            }
            if let Some(counter) = self.disk_store.get(key_hash, epoch.saturating_sub(1)) {
                self.store.merge_remote(key_hash, epoch.saturating_sub(1), &counter);
            }
            estimate = self.store.estimated_count(key_hash, epoch, elapsed_frac);
        }

        tracing::debug!(
            "key={} epoch={} estimate={} hits={} limit={} elapsed_frac={}",
            key, epoch, estimate, hits, limit, elapsed_frac
        );

        let result = if estimate + hits as f64 > limit as f64 {
            counter!("rate_limit_checks_total", "result" => "deny").increment(1);
            RateLimitResult::Deny { retry_after_ms: (epoch + 1) * window_ms - now_ms }
        } else {
            let instantaneous = (estimate + hits as f64) / limit as f64;

            let effective_pressure = if self.velocity_weight > 0.0 {
                let vel_hits_per_ms = self.store.velocity(key_hash);
                let normalized_velocity = (vel_hits_per_ms * window_ms as f64 / limit as f64).min(1.0);
                let w2 = self.velocity_weight;
                let w1 = 1.0 - w2;
                (w1 * instantaneous + w2 * normalized_velocity).min(1.0)
            } else {
                instantaneous.min(1.0)
            };

            let boundaries = Self::compute_tier_boundaries(self.tier_count);
            let tier = Self::pressure_to_tier(effective_pressure, &boundaries);
            self.store.increment(key_hash, epoch, self.node_id, hits, tier, self.velocity_alpha);

            counter!("rate_limit_checks_total", "result" => "allow").increment(1);
            RateLimitResult::Allow { remaining: (limit as f64 - estimate - hits as f64) as u64 }
        };

        histogram!("rate_limit_check_duration_seconds").record(start.elapsed().as_secs_f64());

        result
    }

    /// computes pressure boundaries for each tier chosen from value K
    /// 
    /// k = 3 [0.0, 0.33, 0.67]
    fn compute_tier_boundaries(k: usize) -> Vec<f64> {
        (0..k).map(|i| i as f64 / k as f64).collect()
    }

    /// just returns current key's pressure tier it's in
    fn pressure_to_tier(pressure: f64, boundaries: &[f64]) -> u8 {
        boundaries.iter()
            .rposition(|&b| pressure >= b)
            .unwrap_or(0) as u8
    }

    pub fn estimate(&self, key: &str, window_ms: u64) -> f64 {
        let key_hash = xxh3_64(key.as_bytes());
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let epoch = now_ms / window_ms;
        let elapsed_frac = (now_ms % window_ms) as f64 / window_ms as f64;

        let mut estimate = self.store.estimated_count(key_hash, epoch, elapsed_frac);

        if estimate == 0.0 {
            if let Some(counter) = self.disk_store.get(key_hash, epoch) {
                self.store.merge_remote(key_hash, epoch, &counter);
            }
            if let Some(counter) = self.disk_store.get(key_hash, epoch.saturating_sub(1)) {
                self.store.merge_remote(key_hash, epoch.saturating_sub(1), &counter);
            }
            estimate = self.store.estimated_count(key_hash, epoch, elapsed_frac);
        }

        estimate
    }
}






// ============================




#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::store::CRDTStore;

    const NODE: NodeId = 1;
    use crate::persistence::DiskStore;
    use std::fs;

    fn make_limiter(name: &str) -> Limiter {
        let path = format!("/tmp/test_limiter_{}.redb", name);
        let _ = fs::remove_file(&path);
        let disk_store = Arc::new(DiskStore::new(&path));
        Limiter::new(Arc::new(CRDTStore::new()), disk_store, NODE, 1, 2.0, false, 0.4, 0.3)
    }

    #[test]
    fn under_limit_allows() {
        let limiter = make_limiter("under_limit");
        let result = limiter.check_rate_limit("user:1", 10, 1, 1000);
        assert!(matches!(result, RateLimitResult::Allow { .. }));
    }

    #[test]
    fn over_limit_denies() {
        let limiter = make_limiter("over_limit");
        let result = limiter.check_rate_limit("user:1", 5, 6, 1000);
        assert!(matches!(result, RateLimitResult::Deny { .. }));
    }

    #[test]
    fn remaining_decreases() {
        let limiter = make_limiter("remaining_decreases");
        let r1 = limiter.check_rate_limit("user:1", 10, 3, 1000);
        let r2 = limiter.check_rate_limit("user:1", 10, 3, 1000);

        match (r1, r2) {
            (RateLimitResult::Allow { remaining: a }, RateLimitResult::Allow { remaining: b }) => {
                assert!(b < a);
            }
            _ => panic!("both should be allowed"),
        }
    }

    #[test]
    fn hits_at_exact_limit() {
        let limiter = make_limiter("hits_exact");
        let result = limiter.check_rate_limit("user:1", 5, 5, 1000);
        assert!(matches!(result, RateLimitResult::Allow { .. }));
    }

    #[test]
    fn different_keys_independent() {
        let limiter = make_limiter("diff_keys");
        limiter.check_rate_limit("user:1", 5, 5, 1000);
        let result = limiter.check_rate_limit("user:2", 5, 1, 1000);
        assert!(matches!(result, RateLimitResult::Allow { .. }));
    }

    #[test]
    fn deny_has_positive_retry() {
        let limiter = make_limiter("deny_positive_retry");
        let result = limiter.check_rate_limit("user:1", 1, 5, 1000);
        match result {
            RateLimitResult::Deny { retry_after_ms } => assert!(retry_after_ms > 0),
            _ => panic!("should deny"),
        }
    }
}