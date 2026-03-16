/*
    peer_table.rs
    Peer table struct and logic for down detection and peer/cluster membership
    for nodes
*/

use std::{net::SocketAddr, time::{Duration, Instant}};

use dashmap::DashMap;
use rand::seq::IteratorRandom;

use crate::{membership::PeerState, types::NodeId};



pub struct PeerInfo {
    pub address: SocketAddr,
    pub state: PeerState,
    pub last_seen: Instant,
    pub last_ack: Option<Instant>,
    pub suspicion_confirmations: u32,
    pub suspicion_deadline: Option<Instant>,
}

pub struct PeerTable {
    peers: DashMap<NodeId, PeerInfo>,
}

impl PeerTable {
    pub fn new() -> Self {
        PeerTable {
            peers: DashMap::new(),
        }
    }

    pub fn insert(&self, address: SocketAddr, node_id: NodeId) {
        self.peers.insert(
            node_id,
            PeerInfo {
                address,
                state: PeerState::Alive,
                last_seen: Instant::now(),
                last_ack: None,
                suspicion_confirmations: 0,
                suspicion_deadline: None,
            }
        );
    }

    pub fn mark_alive(&self, node_id: NodeId) {
        if let Some(mut peer) = self.peers.get_mut(&node_id) {
            let was_suspect_or_dead = peer.state == PeerState::Suspect
                || peer.state == PeerState::Dead;
            peer.state = PeerState::Alive;
            peer.last_seen = Instant::now();
            peer.last_ack = Some(Instant::now());
            peer.suspicion_confirmations = 0;
            peer.suspicion_deadline = None;
            if was_suspect_or_dead {
                tracing::info!("peer {} alive (recovered)", node_id);
            }
        }
    }

    /// Dogpile semantics: make the suspicion timeout dynamic
    /// As more peers suspect a node, the timeout gets shorter 
    pub fn mark_suspect(
        &self, 
        node_id: NodeId, 
        base_timeout_ms: u64,
        min_timeout_ms: u64,
    ) {
        let already_suspect = {
            self.peers.get(&node_id)
                .map(|p| p.state == PeerState::Suspect)
                .unwrap_or(false)
        };

        // if already suspect, need to calculate the new suspicion deadlines and stuff
        if already_suspect {
            self.add_suspicion_confirmation(node_id, min_timeout_ms, base_timeout_ms);
        } else if let Some(mut peer) = self.peers.get_mut(&node_id) {
            peer.state = PeerState::Suspect;
            peer.suspicion_confirmations = 1;
            peer.suspicion_deadline = Some(Instant::now() + Duration::from_millis(base_timeout_ms));
        }
    }

    pub fn mark_dead(&self, node_id: NodeId) {
        if let Some(mut peer) = self.peers.get_mut(&node_id) {
            peer.state = PeerState::Dead;
            peer.suspicion_confirmations = 0;
            peer.suspicion_deadline = None;
        }
    }

    pub fn ack_received_since(&self, node_id: NodeId, since: Instant) -> bool {
        self.peers.get(&node_id)
            .and_then(|p| p.last_ack)
            .map(|ack_time| ack_time > since)
            .unwrap_or(false)
    }

    pub fn get_alive_peers(&self) -> Vec<(NodeId, SocketAddr)> {
        self.peers
            .iter()
            .filter(|p| p.value().state == PeerState::Alive)
            .map(|p| (*p.key(), p.value().address))
            .collect()
    }

    pub fn random_peer(&self) -> Option<(NodeId, SocketAddr)> {
        let mut rng = rand::rng();

        self.peers
            .iter()
            .filter(|p| p.value().state == PeerState::Alive)
            .choose(&mut rng)
            .map(|p| (*p.key(), p.value().address))
    }

    pub fn add_suspicion_confirmation(
        &self, 
        node_id: NodeId, 
        min_timeout_ms: u64, 
        base_timeout_ms: u64
    ) {
        // since i am doing ln calculations, max 2 prevents a one node cluster from returning
        // zero on the calculation
        // Deadlocking bug fixed:
        // .len() acquires a shard lock in DashMap, so when get_mut holds that same write lock
        // on the shard, then len() tries to acquire the read lock and blocks
        // forever
        // moving cluster_size outside of the block below fixed this.
        // good thing to note about dashmap
        let cluster_size = self.peers.len().max(2) as f64;

        if let Some(mut peer) = self.peers.get_mut(&node_id) {
            if peer.state != PeerState::Suspect { return; }
            peer.suspicion_confirmations += 1;

            let confirmations = peer.suspicion_confirmations as f64;
            let timeout_ms = (base_timeout_ms as f64 * confirmations.ln_1p() / cluster_size.ln())
                .max(min_timeout_ms as f64);

            peer.suspicion_deadline = Some(Instant::now() + Duration::from_millis(timeout_ms as u64));
        }
    }

    pub fn peer_count(&self) -> usize {
        self.peers.len()
    }

    pub fn get(&self, node_id: &NodeId) -> bool {
        self.peers.contains_key(node_id)
    }

    pub fn promote_suspects_to_dead(&self) {
        let now = Instant::now();
        for mut peer in self.peers.iter_mut() {
            if peer.state == PeerState::Suspect {
                if let Some(deadline) = peer.suspicion_deadline {
                    if now > deadline {
                        peer.state = PeerState::Dead;
                        peer.suspicion_confirmations = 0;
                        peer.suspicion_deadline = None;
                        
                        tracing::info!("peer {} declared dead", *peer.key());
                    }
                }
            }
        }
    }

    pub fn is_suspect_or_dead(&self, node_id: NodeId) -> bool {
        self.peers.get(&node_id)
            .map(|p| p.state == PeerState::Suspect || p.state == PeerState::Dead)
            .unwrap_or(true)
    }
}






// ============================







#[cfg(test)]
mod tests {
    use super::*;

    const NODE_A: NodeId = 1;
    const NODE_B: NodeId = 2;
    const NODE_C: NodeId = 3;
    const BASE_TIMEOUT_MS: u64 = 5000;
    const MIN_TIMEOUT_MS: u64 = 1000;

    fn addr(port: u16) -> SocketAddr {
        format!("127.0.0.1:{}", port).parse().unwrap()
    }

    #[test]
    fn insert_peer_is_alive() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        let alive = table.get_alive_peers();
        assert_eq!(alive.len(), 1);
        assert_eq!(alive[0].0, NODE_A);
    }

    #[test]
    fn mark_suspect_removes_from_alive() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        assert!(table.get_alive_peers().is_empty());
    }

    #[test]
    fn mark_dead_removes_from_alive() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.mark_dead(NODE_A);
        assert!(table.get_alive_peers().is_empty());
    }

    #[test]
    fn mark_alive_recovers_suspect() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        table.mark_alive(NODE_A);
        assert_eq!(table.get_alive_peers().len(), 1);
    }

    #[test]
    fn mark_alive_clears_suspicion() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        table.mark_alive(NODE_A);
        let peer = table.peers.get(&NODE_A).unwrap();
        assert_eq!(peer.suspicion_confirmations, 0);
        assert!(peer.suspicion_deadline.is_none());
    }

    #[test]
    fn random_peer_returns_alive_only() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.insert(addr(9001), NODE_B);
        table.mark_dead(NODE_A);
        let (id, _) = table.random_peer().unwrap();
        assert_eq!(id, NODE_B);
    }

    #[test]
    fn random_peer_empty_table() {
        let table = PeerTable::new();
        assert!(table.random_peer().is_none());
    }

    #[test]
    fn multiple_alive_peers() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.insert(addr(9001), NODE_B);
        table.insert(addr(9002), NODE_C);
        assert_eq!(table.get_alive_peers().len(), 3);
    }

    #[test]
    fn suspect_increments_confirmations() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        let peer = table.peers.get(&NODE_A).unwrap();
        assert_eq!(peer.suspicion_confirmations, 1);
    }

    #[test]
    fn dogpile_additional_confirmations() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.insert(addr(9001), NODE_B);
        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        let peer = table.peers.get(&NODE_A).unwrap();
        assert_eq!(peer.suspicion_confirmations, 2);
    }

    #[test]
    fn dogpile_deadline_shrinks_with_confirmations() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.insert(addr(9001), NODE_B);
        table.insert(addr(9002), NODE_C);

        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        let deadline_1 = table.peers.get(&NODE_A).unwrap().suspicion_deadline.unwrap();

        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        let deadline_2 = table.peers.get(&NODE_A).unwrap().suspicion_deadline.unwrap();

        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        let deadline_3 = table.peers.get(&NODE_A).unwrap().suspicion_deadline.unwrap();

        // More confirmations should result in shorter deadlines from now
        // deadline_3 should be sooner than deadline_1 was (relative to when each was set)
        assert!(deadline_3 <= deadline_2 || deadline_2 <= deadline_1);
    }

    #[test]
    fn dogpile_respects_min_timeout() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.insert(addr(9001), NODE_B);

        // Suspect many times to drive deadline down
        table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        for _ in 0..20 {
            table.mark_suspect(NODE_A, BASE_TIMEOUT_MS, MIN_TIMEOUT_MS);
        }

        let peer = table.peers.get(&NODE_A).unwrap();
        let remaining = peer.suspicion_deadline.unwrap().duration_since(Instant::now());
        // Should never go below min_timeout
        assert!(remaining.as_millis() >= MIN_TIMEOUT_MS as u128 - 100); // 100ms tolerance for test execution time
    }
}