/*
    gossip/engine.rs
    The Gossip Engine: send and receives delta data per node
*/
use std::{net::SocketAddr, sync::Arc, time::Duration};

use metrics::{counter, gauge};
use tokio::{net::UdpSocket, time::interval};

use crate::{crdt::CRDTStore, gossip::GossipMessage, membership::{PeerTable, ProbeMessage}, types::{NodeId, UDP_PACKET_MAX_SIZE}};

/// The Gossip engine sends and receives counter updates
/// from nodes in the peer cluster, updating its
/// CRDTstore with their deltas
pub struct GossipEngine {
    store: Arc<CRDTStore>,
    node_id: NodeId,
    peer_addresses: Vec<SocketAddr>,
    gossip_interval: u64,
    receiver_bind_address: SocketAddr,
    peer_table: Arc<PeerTable>,
}

impl GossipEngine {
    pub fn new(
        store: Arc<CRDTStore>, 
        node_id: NodeId, 
        peer_addresses: Vec<SocketAddr>, 
        gossip_interval: u64,
        receiver_bind_address: SocketAddr,
        peer_table: Arc<PeerTable>,
    ) -> Self {

        GossipEngine {
            store,
            node_id,
            peer_addresses,
            gossip_interval,
            receiver_bind_address,
            peer_table,
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

            // track how many dirty keys per round
            gauge!("gossip_delta_size").set(deltas.len() as f64);

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

            counter!("gossip_messages_sent_total").increment(peers.len() as u64)
        }
    }

    async fn receiver_loop(
        node_id: NodeId,
        peer_table: Arc<PeerTable>,
        store: Arc<CRDTStore>,
        bind_addr: SocketAddr,
    ) -> tokio::io::Result<()> {

        let socket = UdpSocket::bind(bind_addr).await?;
        // 65535 bytes = udp max packet size
        let mut buffer = vec![0u8; UDP_PACKET_MAX_SIZE];

        loop {
            let (len, src) = socket.recv_from(&mut buffer).await?;

            // Adding in functionality to detect if it's a probe message
            if let Ok(probe) = rmp_serde::from_slice::<ProbeMessage>(&buffer[..len]) {
                match probe {
                    ProbeMessage::Ping { sender_id, seq } => {
                        let ack = ProbeMessage::Ack { sender_id: node_id, seq };
                        let bytes = rmp_serde::to_vec(&ack).unwrap();
                        let _ = socket.send_to(&bytes, src).await;
                        peer_table.mark_alive(sender_id);
                        continue;
                    }
                    ProbeMessage::Ack { .. } => {
                        // ignore Acks, as they're handled by the probing func
                        continue;
                    }
                }
            }

            let msg: GossipMessage = match rmp_serde::from_slice(&buffer[..len]) {
                Ok(m) => m,
                Err(_) => {
                    counter!("gossip_deserialize_errors_total").increment(1);
                    continue
                },
            };

            counter!("gossip_message_received_total").increment(1);

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
        let peer_table = Arc::clone(&self.peer_table);

        let sender_store = Arc::clone(&store);
        // move is needed because async blocks need to take ownership of all environemnts
        tokio::spawn(async move {
            Self::sender_loop(sender_store, node_id, peers, interval_ms).await;
        });

        tokio::spawn(async move {
            Self::receiver_loop(node_id, peer_table, store, bind_addr).await;
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
    use crate::membership::PeerTable;
    use crate::types::NodeId;

    const NODE_A: NodeId = 1;
    const NODE_B: NodeId = 2;
    const KEY: u64 = 999;
    const EPOCH: u64 = 42;

    fn addr(port: u16) -> SocketAddr {
        format!("127.0.0.1:{}", port).parse().unwrap()
    }

    fn make_peer_table(peers: Vec<(NodeId, SocketAddr)>) -> Arc<PeerTable> {
        let table = Arc::new(PeerTable::new());
        for (id, addr) in peers {
            table.insert(addr, id);
        }
        table
    }

    #[tokio::test]
    async fn two_nodes_sync() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());

        let table_a = make_peer_table(vec![(NODE_B, addr(19001))]);
        let table_b = make_peer_table(vec![(NODE_A, addr(19000))]);

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a),
            NODE_A,
            vec![addr(19001)],
            50,
            addr(19000),
            table_a,
        );

        let engine_b = GossipEngine::new(
            Arc::clone(&store_b),
            NODE_B,
            vec![addr(19000)],
            50,
            addr(19001),
            table_b,
        );

        engine_a.run().await;
        engine_b.run().await;

        store_a.increment(KEY, EPOCH, NODE_A, 10);

        sleep(Duration::from_millis(300)).await;

        let count_b = store_b.estimated_count(KEY, EPOCH, 1.0);
        assert_eq!(count_b, 10.0);
    }

    #[tokio::test]
    async fn bidirectional_sync() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());

        let table_a = make_peer_table(vec![(NODE_B, addr(19003))]);
        let table_b = make_peer_table(vec![(NODE_A, addr(19002))]);

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a),
            NODE_A,
            vec![addr(19003)],
            50,
            addr(19002),
            table_a,
        );

        let engine_b = GossipEngine::new(
            Arc::clone(&store_b),
            NODE_B,
            vec![addr(19002)],
            50,
            addr(19003),
            table_b,
        );

        engine_a.run().await;
        engine_b.run().await;

        store_a.increment(KEY, EPOCH, NODE_A, 10);
        store_b.increment(KEY, EPOCH, NODE_B, 20);

        sleep(Duration::from_millis(300)).await;

        let count_a = store_a.estimated_count(KEY, EPOCH, 1.0);
        let count_b = store_b.estimated_count(KEY, EPOCH, 1.0);
        assert_eq!(count_a, 30.0);
        assert_eq!(count_b, 30.0);
    }

    #[tokio::test]
    async fn no_data_no_crash() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());

        let table_a = make_peer_table(vec![(NODE_B, addr(19005))]);
        let table_b = make_peer_table(vec![(NODE_A, addr(19004))]);

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a),
            NODE_A,
            vec![addr(19005)],
            50,
            addr(19004),
            table_a,
        );

        let engine_b = GossipEngine::new(
            Arc::clone(&store_b),
            NODE_B,
            vec![addr(19004)],
            50,
            addr(19005),
            table_b,
        );

        engine_a.run().await;
        engine_b.run().await;

        sleep(Duration::from_millis(200)).await;

        assert_eq!(store_a.estimated_count(KEY, EPOCH, 1.0), 0.0);
        assert_eq!(store_b.estimated_count(KEY, EPOCH, 1.0), 0.0);
    }
}