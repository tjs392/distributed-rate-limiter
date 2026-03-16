/*
    membership/types.rs
    types for membership module
*/

use serde::{Deserialize, Serialize};

use crate::types::NodeId;

#[derive(Debug, PartialEq, Copy, Clone)]
pub enum PeerState {
    Alive,
    Suspect,
    Dead,
}

#[derive(Serialize, Deserialize)]
pub enum ProbeMessage {
    Ping { sender_id: NodeId, seq: u64 },
    Ack { sender_id: NodeId, seq: u64 },
}