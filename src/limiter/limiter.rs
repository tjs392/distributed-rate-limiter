/*
    limiter/limiter.rs
    The Limiter. This connects to the store and checks the limits
    and current counts in epoch per KeyHash, Epoch pair
*/
use std::sync::Arc;
use xxhash_rust::xxh3::xxh3_64;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::crdt::store::CRDTStore;
use crate::types::{NodeId, RateLimitResult};

pub struct Limiter {
    /// Store is shared across tasks
    store: Arc<CRDTStore>,
    node_id: NodeId,
}

/// Limiter receives a ref to the CRDTStore so it can do operations
impl Limiter {
    pub fn new(store: Arc<CRDTStore>, node_id: NodeId) -> Self {
        Limiter {
            store,
            node_id,
        }
    }

    pub fn node_id(&self) -> NodeId {
        self.node_id
    }

    pub fn check_rate_limit(&self, key: &str, limit: u64, hits: u64, window_ms: u64) -> RateLimitResult {
        let key_hash = xxh3_64(key.as_bytes());

        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        let epoch = now_ms / window_ms;
        let elapsed_frac = (now_ms % window_ms) as f64 / window_ms as f64;

        let estimate = self.store.estimated_count(key_hash, epoch, elapsed_frac);

        if estimate + hits as f64 > limit as f64 {
            // TODO: retry_after_ms currently returns time until next epoch boundary.
            // With sliding window, actual retry time depends on previous epoch decay.
            // Good enough for now — production systems (Cloudflare, GitHub) do the same.
            RateLimitResult::Deny { retry_after_ms: (epoch + 1) * window_ms - now_ms }
        } else {
            // Essential bug catch -- before i was incrementing counts when denied
            // move this increment to after the estimate
            self.store.increment(key_hash, epoch, self.node_id, hits);
            RateLimitResult::Allow { remaining: (limit as f64 - estimate - hits as f64) as u64 }
        }
    }
}






// ============================




#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::store::CRDTStore;

    const NODE: NodeId = 1;

    fn make_limiter() -> Limiter {
        Limiter::new(Arc::new(CRDTStore::new()), NODE)
    }

    #[test]
    fn under_limit_allows() {
        let limiter = make_limiter();
        let result = limiter.check_rate_limit("user:1", 10, 1, 1000);
        assert!(matches!(result, RateLimitResult::Allow { .. }));
    }

    #[test]
    fn over_limit_denies() {
        let limiter = make_limiter();
        let result = limiter.check_rate_limit("user:1", 5, 6, 1000);
        assert!(matches!(result, RateLimitResult::Deny { .. }));
    }

    #[test]
    fn remaining_decreases() {
        let limiter = make_limiter();
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
        let limiter = make_limiter();
        let result = limiter.check_rate_limit("user:1", 5, 5, 1000);
        assert!(matches!(result, RateLimitResult::Allow { .. }));
    }

    #[test]
    fn different_keys_independent() {
        let limiter = make_limiter();
        limiter.check_rate_limit("user:1", 5, 5, 1000);
        let result = limiter.check_rate_limit("user:2", 5, 1, 1000);
        assert!(matches!(result, RateLimitResult::Allow { .. }));
    }

    #[test]
    fn deny_has_positive_retry() {
        let limiter = make_limiter();
        let result = limiter.check_rate_limit("user:1", 1, 5, 1000);
        match result {
            RateLimitResult::Deny { retry_after_ms } => assert!(retry_after_ms > 0),
            _ => panic!("should deny"),
        }
    }
}