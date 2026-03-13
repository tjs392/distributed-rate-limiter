/*
    crdt:
    Conflict-free Replicated Data Type Store
*/
use dashmap::{DashMap, DashSet};

use crate::types::{Epoch, NodeId, KeyHash};
use crate::GCounter;

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
    counters: DashMap<(KeyHash, Epoch), GCounter>,
    
    dirty_set: DashSet<(KeyHash, Epoch)>,
}

/// Conflict free Replicated Data Type Store. This is an API wrapper around a DashMap of GCounters
impl CRDTStore {
    pub fn new() -> Self {
        CRDTStore {
            counters: DashMap::new(),
            dirty_set: DashSet::new(),
        }
    }

    /// Takes key_hash and epoch and increments the counter for this key
    pub fn increment(&self, key_hash: KeyHash, epoch: Epoch, node_id: NodeId, hits: u64) {
        let key = (key_hash, epoch);

        let mut counter = self
            .counters
            .entry(key)
            .or_insert_with(GCounter::new);

        counter.increment(node_id, hits);
        
        self.dirty_set.insert(key);
    }

    /// Merge a counter with a remote counter (one way merge, remote_counter is not mutated)
    pub fn merge_remote(&self, key_hash: KeyHash, epoch: Epoch, remote_counter: &GCounter) {
        let key = (key_hash, epoch);

        let mut counter = self
            .counters
            .entry(key)
            .or_insert_with(GCounter::new);

        counter.merge(remote_counter);

        // Important! Don't mark dirty for this, don't need to re gossip everythiung
    }

    /// Returns all of the dirty keys
    pub fn take_delta(&self) -> Vec<((KeyHash, Epoch), GCounter)> {
        let dirty_keys: Vec<_> = self.dirty_set.iter().map(|key| *key).collect();
        self.dirty_set.clear();

        dirty_keys.into_iter()
            .filter_map(|key| {
                self.counters.get(&key).map(|c| (key, c.clone()))
            })
            .collect()
    }

    /// Sliding window read: current + previous * (1 - elapsed_frac)
    /// Returns a smooth count estimate between epochs.
    pub fn estimated_count(&self, key_hash: KeyHash, epoch: Epoch, elapsed_frac: f64) -> f64 {
        let elapsed_frac = elapsed_frac.clamp(0.0, 1.0);
        let key_current = (key_hash, epoch);
        let key_prev = (key_hash, epoch.saturating_sub(1));

        let current_total = self.counters.get(&key_current)
            .map(|c| c.total() as f64)
            .unwrap_or(0.0);
        
        let prev_total = self.counters.get(&key_prev)
            .map(|c| c.total() as f64)
            .unwrap_or(0.0);

        current_total + prev_total * (1.0 - elapsed_frac)
    }
}

impl Default for CRDTStore {
    fn default() -> Self {
        CRDTStore::new()
    }
}

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
        store.increment(KEY, EPOCH, NODE_A, 10);
        assert_eq!(store.estimated_count(KEY, EPOCH, 0.0), 10.0);
    }

    #[test]
    fn increment_multiple_nodes() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 10);
        store.increment(KEY, EPOCH, NODE_B, 20);
        assert_eq!(store.estimated_count(KEY, EPOCH, 0.0), 30.0);
    }

    #[test]
    fn different_keys_are_independent() {
        let store = CRDTStore::new();
        store.increment(100, EPOCH, NODE_A, 5);
        store.increment(200, EPOCH, NODE_A, 15);
        assert_eq!(store.estimated_count(100, EPOCH, 0.0), 5.0);
        assert_eq!(store.estimated_count(200, EPOCH, 0.0), 15.0);
    }

    #[test]
    fn different_epochs_are_independent() {
        let store = CRDTStore::new();
        store.increment(KEY, 1, NODE_A, 10);
        store.increment(KEY, 2, NODE_A, 20);

        assert_eq!(store.estimated_count(KEY, 1, 1.0), 10.0);
        assert_eq!(store.estimated_count(KEY, 2, 1.0), 20.0);
    }

    #[test]
    fn merge_remote_updates_count() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 10);

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
        store.increment(KEY, EPOCH, NODE_A, 5);

        let delta = store.take_delta();
        assert_eq!(delta.len(), 1);
        assert_eq!(delta[0].0, (KEY, EPOCH));
    }

    #[test]
    fn take_delta_clears_dirty() {
        let store = CRDTStore::new();
        store.increment(KEY, EPOCH, NODE_A, 5);

        let first = store.take_delta();
        assert_eq!(first.len(), 1);

        let second = store.take_delta();
        assert!(second.is_empty());
    }

    #[test]
    fn sliding_window_start_of_epoch() {
        let store = CRDTStore::new();
        store.increment(KEY, 41, NODE_A, 100);
        store.increment(KEY, 42, NODE_A, 10);

        assert_eq!(store.estimated_count(KEY, 42, 0.0), 110.0);
    }

    #[test]
    fn sliding_window_end_of_epoch() {
        let store = CRDTStore::new();
        store.increment(KEY, 41, NODE_A, 100);
        store.increment(KEY, 42, NODE_A, 10);

        assert_eq!(store.estimated_count(KEY, 42, 1.0), 10.0);
    }

    #[test]
    fn sliding_window_midpoint() {
        let store = CRDTStore::new();
        store.increment(KEY, 41, NODE_A, 100);
        store.increment(KEY, 42, NODE_A, 10);

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
        store.increment(KEY, 42, NODE_A, 50);

        assert_eq!(store.estimated_count(KEY, 42, 0.0), 50.0);
        assert_eq!(store.estimated_count(KEY, 42, 0.5), 50.0);
        assert_eq!(store.estimated_count(KEY, 42, 1.0), 50.0);
    }
}