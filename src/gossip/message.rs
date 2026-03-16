use std::net::SocketAddr;

/*
    gossip/message.rs
    The gossip message used by the gossip engine
*/
use serde::{Deserialize, Serialize};

use crate::{crdt::GCounter, types::{Epoch, KeyHash, NodeId}};

#[derive(Serialize, Deserialize)]
pub struct PeerEntry {
    pub node_id: NodeId,
    pub address: SocketAddr,
}

/// This is the Gossip Message that will be sent over UDP to 
/// n random peers for counting convergence
/// 
/// Sent over network, so need serde
#[derive(Serialize, Deserialize)]
pub struct GossipMessage {
    pub sender_id: NodeId,
    pub updates: Vec<((KeyHash, Epoch), GCounter)>,
    pub peers: Vec<PeerEntry>,
}

impl GossipMessage {
    pub fn new(
        sender_id: NodeId, 
        updates: Vec<((KeyHash, Epoch), GCounter)>,
        peers: Vec<PeerEntry>,
    ) -> Self {
        GossipMessage {
            sender_id,
            updates,
            peers,
        }
    }
}