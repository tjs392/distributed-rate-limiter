use std::time::{Duration, Instant};

/*
    crdt/store.rs:
    Conflict-free Replicated Data Type Store for Storing Counts per Node
*/
use dashmap::{DashMap, DashSet};

use crate::crdt::{GCounter, TimestampedGCounter};
use crate::types::{Epoch, KeyHash, NodeId};

pub struct CRDTStore {
        
    /*
        Why DashMap?

        CRDT counters may be updated concurrently by many threads.
        DashMap provides a concurrent hash map with internal sharding,
        allowing multiple threads to update different keys without
        locking the entire map like a Mutex<HashMap<...>> would.

        This is due to internal sharding
    */
    /// (Key_hash, Epoch) -> GCounter
    counters: DashMap<(KeyHash, Epoch), TimestampedGCounter>,
    
    // key to gossip tier
    dirty_set: DashMap<(KeyHash, Epoch), u8>,
}

/// Conflict free Replicated Data Type Store. This is an API wrapper around a DashMap of GCounters
impl CRDTStore {
    pub fn new() -> Self {
        CRDTStore {
            counters: DashMap::new(),
            dirty_set: DashMap::new(),
        }
    }

    /// Returns length of counter
    pub fn len(&self) -> usize {
        self.counters.len()
    }

    /// Takes key_hash and epoch and increments the counter for this key
    pub fn increment(&self, key_hash: KeyHash, epoch: Epoch, node_id: NodeId, hits: u64, tier: u8) {
        let key = (key_hash, epoch);
        let mut entry = self.counters.entry(key).or_default();
        entry.last_accessed = Instant::now();
        entry.counter.increment(node_id, hits);
        self.dirty_set.insert(key, tier);
    }

    /// Merge a counter with a remote counter (one way merge, remote_counter is not mutated)
    pub fn merge_remote(&self, key_hash: KeyHash, epoch: Epoch, remote_counter: &GCounter) {
        let key = (key_hash, epoch);

        let mut entry = self.counters.entry(key).or_default();
        entry.counter.merge(remote_counter);

        // Important! Don't mark dirty for this, don't need to re gossip everythiung
    }

    /// Returns all of the dirty keys
    pub fn take_delta(&self) -> Vec<((KeyHash, Epoch), GCounter)> {
        let dirty_keys: Vec<_> = self.dirty_set.iter().map(|entry| *entry.key()).collect();
        self.dirty_set.clear();

        dirty_keys.into_iter()
            .filter_map(|key| {
                self.counters.get(&key).map(|c| (key, c.counter.clone()))
            })
            .collect()
    }

    // tiered delta taking
    pub fn take_delta_tiered(&self, tiers_due: &[bool; 5]) -> Vec<((KeyHash, Epoch), GCounter)> {
        let mut deltas = vec![];

        self.dirty_set.retain(|key_pair, tier| {
            if tiers_due[*tier as usize] {
                if let Some(counter) = self.counters.get(key_pair) {
                    deltas.push((*key_pair, counter.counter.clone()));
                }
                false
            } else {
                true
            }
        });

        deltas
    }

    /// Sliding window read: current + previous * (1 - elapsed_frac)
    /// Returns a smooth count estimate between epochs.
    pub fn estimated_count(&self, key_hash: KeyHash, epoch: Epoch, elapsed_frac: f64) -> f64 {
        let elapsed_frac = elapsed_frac.clamp(0.0, 1.0);
        let key_current = (key_hash, epoch);
        let key_prev = (key_hash, epoch.saturating_sub(1));

        let current_total = self.counters.get(&key_current)
            .map(|c| c.counter.total() as f64)
            .unwrap_or(0.0);
        
        let prev_total = self.counters.get(&key_prev)
            .map(|c| c.counter.total() as f64)
            .unwrap_or(0.0);

        current_total + prev_total * (1.0 - elapsed_frac)
    }

    pub fn take_snapshot(&self) -> Vec<((KeyHash, Epoch), GCounter)> {
        self.counters
            .iter()
            .map(|entry| (*entry.key(), entry.value().counter.clone()))
            .collect()
    }

    /// Evict all keys by last access
    pub fn evict(&self, ttl: Duration) {
        let cutoff = Instant::now() - ttl;
        self.counters.retain(|_, entry| entry.last_accessed > cutoff);
    }
}

impl Default for CRDTStore {
    fn default() -> Self {
        CRDTStore::new()
    }
}






// ============================






#[cfg(test)]
mod tests {
    use super::*;

    const NODE_A: NodeId = 1;
    const NODE_B: NodeId = 2;
    const KEY: KeyHash = 999;
    const EPOCH: Epoch = 42;

    #[test]
    fn increment_and_read() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 10, 0);
        assert_eq!(store.estimated_count(KEY, EPOCH, 0.0), 10.0);
    }

    #[test]
    fn increment_multiple_nodes() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 10, 0);
        store.increment(KEY, EPOCH, NODE_B, 20, 0);
        assert_eq!(store.estimated_count(KEY, EPOCH, 0.0), 30.0);
    }

    #[test]
    fn different_keys_are_independent() {
        let store = CRDTStore::new();
        store.increment(100, EPOCH, NODE_A, 5, 0);
        store.increment(200, EPOCH, NODE_A, 15, 0);
        assert_eq!(store.estimated_count(100, EPOCH, 0.0), 5.0);
        assert_eq!(store.estimated_count(200, EPOCH, 0.0), 15.0);
    }

    #[test]
    fn different_epochs_are_independent() {
        let store = CRDTStore::new();
        store.increment(KEY, 1, NODE_A, 10, 0);
        store.increment(KEY, 2, NODE_A, 20, 0);

        assert_eq!(store.estimated_count(KEY, 1, 1.0), 10.0);
        assert_eq!(store.estimated_count(KEY, 2, 1.0), 20.0);
    }

    #[test]
    fn merge_remote_updates_count() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 10, 0);

        let mut remote = GCounter::new();
        remote.increment(NODE_B, 20);
        store.merge_remote(KEY, EPOCH, &remote);

        assert_eq!(store.estimated_count(KEY, EPOCH, 0.0), 30.0);
    }

    #[test]
    fn merge_remote_does_not_mark_dirty() {
        let store = CRDTStore::new();

        let mut remote = GCounter::new();
        remote.increment(NODE_B, 10);
        store.merge_remote(KEY, EPOCH, &remote);

        let delta = store.take_delta();
        assert!(delta.is_empty());
    }

    #[test]
    fn increment_marks_dirty() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 5, 0);

        let delta = store.take_delta();
        assert_eq!(delta.len(), 1);
        assert_eq!(delta[0].0, (KEY, EPOCH));
    }

    #[test]
    fn take_delta_clears_dirty() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 5, 0);

        let first = store.take_delta();
        assert_eq!(first.len(), 1);

        let second = store.take_delta();
        assert!(second.is_empty());
    }

    #[test]
    fn sliding_window_start_of_epoch() {
        let store = CRDTStore::new();
        store.increment(KEY, 41, NODE_A, 100, 0);
        store.increment(KEY, 42, NODE_A, 10, 0);

        assert_eq!(store.estimated_count(KEY, 42, 0.0), 110.0);
    }

    #[test]
    fn sliding_window_end_of_epoch() {
        let store = CRDTStore::new();
        store.increment(KEY, 41, NODE_A, 100, 0);
        store.increment(KEY, 42, NODE_A, 10, 0);

        assert_eq!(store.estimated_count(KEY, 42, 1.0), 10.0);
    }

    #[test]
    fn sliding_window_midpoint() {
        let store = CRDTStore::new();
        store.increment(KEY, 41, NODE_A, 100, 0);
        store.increment(KEY, 42, NODE_A, 10, 0);

        assert_eq!(store.estimated_count(KEY, 42, 0.5), 60.0);
    }

    #[test]
    fn empty_store_returns_zero() {
        let store = CRDTStore::new();
        assert_eq!(store.estimated_count(KEY, EPOCH, 0.5), 0.0);
    }

    #[test]
    fn no_previous_epoch_data() {
        let store = CRDTStore::new();
        store.increment(KEY, 42, NODE_A, 50, 0);

        assert_eq!(store.estimated_count(KEY, 42, 0.0), 50.0);
        assert_eq!(store.estimated_count(KEY, 42, 0.5), 50.0);
        assert_eq!(store.estimated_count(KEY, 42, 1.0), 50.0);
    }

    #[test]
    fn eviction_removes_old_entries() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 10, 0);

        store.evict(Duration::from_secs(0));

        assert_eq!(store.estimated_count(KEY, EPOCH, 1.0), 0.0);
    }

    #[test]
    fn eviction_keeps_recent_entries() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 10, 0);

        store.evict(Duration::from_secs(3600));

        assert_eq!(store.estimated_count(KEY, EPOCH, 1.0), 10.0);
    }
}