/*
    gossip/engine.rs
    The Gossip Engine: send and receives delta data per node
*/
use std::{net::SocketAddr, sync::Arc, time::Duration};

use tokio::{net::UdpSocket, time::interval};

use crate::{crdt::CRDTStore, gossip::GossipMessage, types::NodeId};

const UDP_PACKET_MAX_SIZE: usize = 65535;

/// The Gossip engine sends and receives counter updates
/// from nodes in the peer cluster, updating its
/// CRDTstore with their deltas
pub struct GossipEngine {
    store: Arc<CRDTStore>,
    node_id: NodeId,
    peer_addresses: Vec<SocketAddr>,
    gossip_interval: u64,
    receiver_bind_address: SocketAddr,
}

impl GossipEngine {
    pub fn new(
        store: Arc<CRDTStore>, 
        node_id: NodeId, 
        peer_addresses: Vec<SocketAddr>, 
        gossip_interval: u64,
        receiver_bind_address: SocketAddr
    ) -> Self {

        GossipEngine {
            store,
            node_id,
            peer_addresses,
            gossip_interval,
            receiver_bind_address,
        }

    }

    async fn sender_loop(
        store: Arc<CRDTStore>, 
        node_id: NodeId, 
        peers: Vec<SocketAddr>, 
        interval_ms: u64
    ) -> tokio::io::Result<()> {
        // port 0:0 cause we're sending
        let socket = UdpSocket::bind("0.0.0.0:0").await?;
        let mut ticker = interval(Duration::from_millis(interval_ms));

        loop {
            ticker.tick().await;

            let deltas = store.take_delta();
            if deltas.is_empty() { continue }

            /*
                The GossipEngine packages up all of the dirtry (change)
                gcounter on its node and sends out the updates to its peers
                over UDP

                The peers then unwrap the copied gcounters and merge their
                "deltas" with their own gcounters per hash/epoch
             */
            let msg = GossipMessage {
                sender_id: node_id,
                updates: deltas,
            };

            // rmp_serde = rust message pack, binary, compact, faster than regular
            // serde_json this uses MessagePack format
            let bytes = match rmp_serde::to_vec(&msg) {
                Ok(b) => b,
                Err(_) => continue,
            };

            // TODO: right now this sends to all peers, need to just send to a few random
            // for convergence
            for peer in &peers {
                let _ = socket.send_to(&bytes, peer).await;
            }
        }
    }

    async fn receiver_loop(
        store: Arc<CRDTStore>,
        bind_addr: SocketAddr,
    ) -> tokio::io::Result<()> {

        let socket = UdpSocket::bind(bind_addr).await?;
        // 65535 bytes = udp max packet size
        let mut buffer = vec![0u8; UDP_PACKET_MAX_SIZE];

        loop {
            let (len, _) = socket.recv_from(&mut buffer).await?;

            let msg: GossipMessage = match rmp_serde::from_slice(&buffer[..len]) {
                Ok(m) => m,
                Err(_) => continue,
            };

            for ((key_hash, epoch), counter) in &msg.updates {
                store.merge_remote(*key_hash, *epoch, counter);
            }
        }
    }

    pub async fn run(&self) {
        let store = Arc::clone(&self.store);
        let node_id = self.node_id;
        let peers = self.peer_addresses.clone();
        let interval_ms = self.gossip_interval;
        let bind_addr = self.receiver_bind_address;

        let sender_store = Arc::clone(&store);
        // move is needed because async blocks need to take ownership of all environemnts
        tokio::spawn(async move {
            Self::sender_loop(sender_store, node_id, peers, interval_ms).await;
        });

        tokio::spawn(async move {
            Self::receiver_loop(store, bind_addr).await;
        });
    }

}







// ============================







#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::net::SocketAddr;
    use tokio::time::{sleep, Duration};

    use crate::crdt::store::CRDTStore;
    use crate::gossip::engine::GossipEngine;
    use crate::types::NodeId;

    const NODE_A: NodeId = 1;
    const NODE_B: NodeId = 2;
    const KEY: u64 = 999;
    const EPOCH: u64 = 42;

    fn addr(port: u16) -> SocketAddr {
        format!("127.0.0.1:{}", port).parse().unwrap()
    }

    #[tokio::test]
    async fn two_nodes_sync() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a),
            NODE_A,
            vec![addr(19001)],  // A sends to B's receiver
            50,                  // fast interval for testing
            addr(19000),         // A listens on 19000
        );

        let engine_b = GossipEngine::new(
            Arc::clone(&store_b),
            NODE_B,
            vec![addr(19000)],  // B sends to A's receiver
            50,
            addr(19001),         // B listens on 19001
        );

        engine_a.run().await;
        engine_b.run().await;

        // Increment on node A only
        store_a.increment(KEY, EPOCH, NODE_A, 10);

        // Wait for gossip to propagate
        sleep(Duration::from_millis(300)).await;

        // Node B should have the count from node A
        let count_b = store_b.estimated_count(KEY, EPOCH, 1.0);
        assert_eq!(count_b, 10.0);
    }

    #[tokio::test]
    async fn bidirectional_sync() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a),
            NODE_A,
            vec![addr(19003)],
            50,
            addr(19002),
        );

        let engine_b = GossipEngine::new(
            Arc::clone(&store_b),
            NODE_B,
            vec![addr(19002)],
            50,
            addr(19003),
        );

        engine_a.run().await;
        engine_b.run().await;

        // Both nodes get traffic
        store_a.increment(KEY, EPOCH, NODE_A, 10);
        store_b.increment(KEY, EPOCH, NODE_B, 20);

        sleep(Duration::from_millis(300)).await;

        // Both should see the combined count
        let count_a = store_a.estimated_count(KEY, EPOCH, 1.0);
        let count_b = store_b.estimated_count(KEY, EPOCH, 1.0);
        assert_eq!(count_a, 30.0);
        assert_eq!(count_b, 30.0);
    }

    #[tokio::test]
    async fn no_data_no_crash() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a),
            NODE_A,
            vec![addr(19005)],
            50,
            addr(19004),
        );

        let engine_b = GossipEngine::new(
            Arc::clone(&store_b),
            NODE_B,
            vec![addr(19004)],
            50,
            addr(19005),
        );

        engine_a.run().await;
        engine_b.run().await;

        // No increments, just let gossip run
        sleep(Duration::from_millis(200)).await;

        // Both stores should be empty, nothing crashes
        assert_eq!(store_a.estimated_count(KEY, EPOCH, 1.0), 0.0);
        assert_eq!(store_b.estimated_count(KEY, EPOCH, 1.0), 0.0);
    }
}