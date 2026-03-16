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
                suspicion_confirmations: 0,
                suspicion_deadline: None,
            }
        );
    }

    pub fn mark_alive(&self, node_id: NodeId) {
        if let Some(mut peer) = self.peers.get_mut(&node_id) {
            peer.state = PeerState::Alive;
            peer.last_seen = Instant::now();
            peer.suspicion_confirmations = 0;
            peer.suspicion_deadline = None;
        }
    }

    pub fn mark_suspect(&self, node_id: NodeId, timeout: Duration) {
        if let Some(mut peer) = self.peers.get_mut(&node_id) {
            peer.state = PeerState::Suspect;
            peer.suspicion_confirmations += 1;
            peer.suspicion_deadline = Some(Instant::now() + timeout);
        }
    }

    pub fn mark_dead(&self, node_id: NodeId) {
        if let Some(mut peer) = self.peers.get_mut(&node_id) {
            peer.state = PeerState::Dead;
            peer.suspicion_confirmations = 0;
            peer.suspicion_deadline = None;
        }
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

    pub fn promote_suspects_to_dead(&self) {
        let now = Instant::now();
        for mut peer in self.peers.iter_mut() {
            if peer.state == PeerState::Suspect {
                if let Some(deadline) = peer.suspicion_deadline {
                    if now > deadline {
                        peer.state = PeerState::Dead;
                        peer.suspicion_confirmations = 0;
                        peer.suspicion_deadline = None;
                    }
                }
            }
        }
    }
}






// ============================







#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    const NODE_A: NodeId = 1;
    const NODE_B: NodeId = 2;
    const NODE_C: NodeId = 3;

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
        table.mark_suspect(NODE_A, Duration::from_secs(5));
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
        table.mark_suspect(NODE_A, Duration::from_secs(5));
        table.mark_alive(NODE_A);
        assert_eq!(table.get_alive_peers().len(), 1);
    }

    #[test]
    fn mark_alive_clears_suspicion() {
        let table = PeerTable::new();
        table.insert(addr(9000), NODE_A);
        table.mark_suspect(NODE_A, Duration::from_secs(5));
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
        table.mark_suspect(NODE_A, Duration::from_secs(5));
        let peer = table.peers.get(&NODE_A).unwrap();
        assert_eq!(peer.suspicion_confirmations, 1);
    }
}