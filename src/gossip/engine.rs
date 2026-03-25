/*
    gossip/engine.rs
    The Gossip Engine: send and receives delta data per node
*/
use std::{net::SocketAddr, sync::Arc, time::Duration};

use metrics::{counter, gauge};
use rand::seq::IteratorRandom;
use tokio::{net::UdpSocket, time::interval};

use crate::{crdt::CRDTStore, gossip::{GossipMessage, PeerEntry}, membership::{PeerTable, ProbeMessage}, types::{NodeId, UDP_PACKET_MAX_SIZE}};

/// The Gossip engine sends and receives counter updates
/// from nodes in the peer cluster, updating its
/// CRDTstore with their deltas
pub struct GossipEngine {
    store: Arc<CRDTStore>,
    node_id: NodeId,
    peer_addresses: Vec<SocketAddr>,
    gossip_interval: u64,
    gossip_strategy: String,
    socket: Arc<UdpSocket>,
    peer_table: Arc<PeerTable>,
}

impl GossipEngine {
    pub fn new(
        store: Arc<CRDTStore>,
        node_id: NodeId,
        peer_addresses: Vec<SocketAddr>,
        gossip_interval: u64,
        gossip_strategy: String,
        socket: Arc<UdpSocket>,
        peer_table: Arc<PeerTable>,
    ) -> Self {
        GossipEngine {
            store,
            node_id,
            peer_addresses,
            gossip_interval,
            gossip_strategy,
            socket,
            peer_table,
        }
    }

    async fn sender_loop(
        store: Arc<CRDTStore>,
        peer_table: Arc<PeerTable>,
        node_id: NodeId,
        seed_peers: Vec<SocketAddr>,
        base_interval_ms: u64,
        strategy: String,
        socket: Arc<UdpSocket>,
    ) -> tokio::io::Result<()> {
        let t = base_interval_ms;
        match strategy.as_str() {
            "binary" => Self::sender_loop_tiered(
                store, peer_table, node_id, seed_peers,
                &[t, t / 10],
                socket,
            ).await,
            "3tier" => Self::sender_loop_tiered(
                store, peer_table, node_id, seed_peers,
                &[t, t / 2, t / 10],
                socket,
            ).await,
            "tiered" => Self::sender_loop_tiered(
                store, peer_table, node_id, seed_peers,
                &[t, t * 3 / 4, t / 2, t / 4, t / 10],
                socket,
            ).await,
            "8tier" | "continuous" => Self::sender_loop_tiered(
                store, peer_table, node_id, seed_peers,
                &[t, t * 7 / 8, t * 6 / 8, t * 5 / 8, t * 4 / 8, t * 3 / 8, t * 2 / 8, t / 10],
                socket,
            ).await,
            _ => Self::sender_loop_fixed(
                store, peer_table, node_id, seed_peers, base_interval_ms, socket,
            ).await,
        }
    }

    async fn sender_loop_fixed(
        store: Arc<CRDTStore>,
        peer_table: Arc<PeerTable>,
        node_id: NodeId,
        seed_peers: Vec<SocketAddr>,
        interval_ms: u64,
        socket: Arc<UdpSocket>,
    ) -> tokio::io::Result<()> {
        let mut ticker = interval(Duration::from_millis(interval_ms));

        loop {
            ticker.tick().await;


            /*
                Doing peer merging of seed peers so we don't
                need to see each peer per node.
                Just need a full graph of peers and this will propagate through
                For example, if node1 is seeded with all of the other nodes,
                and the each other node is seeded with node1, then each node will
                eventually converge to have their peer set be all other
                peers in the cluster
             */
            let alive = peer_table.get_alive_peers();
            let peer_entries: Vec<PeerEntry> = alive
                .iter()
                .map(|(id, addr)| PeerEntry { node_id: *id, address: *addr })
                .collect();
            
            let deltas = store.take_delta();
            if deltas.is_empty() && peer_entries.is_empty() { continue }

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
                peers: peer_entries,
            };


            // rmp_serde = rust message pack, binary, compact, faster than regular
            // serde_json this uses MessagePack format
            let bytes = match rmp_serde::to_vec(&msg) {
                Ok(b) => b,
                Err(_) => continue,
            };
            
            let targets: Vec<SocketAddr> = {
                let alive_addrs: Vec<SocketAddr> = alive.iter().map(|(_, addr)| *addr).collect();
                if alive_addrs.is_empty() {
                    seed_peers.clone()
                } else {
                    let mut rng = rand::rng();
                    alive.iter()
                        .map(|(_, addr)| *addr)
                        .sample(&mut rng, 3.min(alive.len()))
                }
            };

            for peer in &targets {
                let _ = socket.send_to(&bytes, peer).await;
            }

            counter!("gossip_messages_sent_total").increment(targets.len() as u64);
        }
    }

    async fn sender_loop_tiered(
        store: Arc<CRDTStore>,
        peer_table: Arc<PeerTable>,
        node_id: NodeId,
        seed_peers: Vec<SocketAddr>,
        tier_intervals_ms: &[u64],
        socket: Arc<UdpSocket>,
    ) -> tokio::io::Result<()> {
        let fast_tick = tier_intervals_ms.iter().copied().min().unwrap_or(100);
        let mut ticker = interval(Duration::from_millis(fast_tick));
        let mut tier_last_sent: Vec<tokio::time::Instant> = vec![tokio::time::Instant::now(); tier_intervals_ms.len()];

        loop {
            ticker.tick().await;
            let now = tokio::time::Instant::now();

            let mut tiers_due = vec![false; tier_intervals_ms.len()];
            for (i, &interval_ms) in tier_intervals_ms.iter().enumerate() {
                if now.duration_since(tier_last_sent[i]).as_millis() >= interval_ms as u128 {
                    tiers_due[i] = true;
                    tier_last_sent[i] = now;
                }
            }
            if !tiers_due.iter().any(|&d| d) { continue; }

            let alive = peer_table.get_alive_peers();
            let peer_entries: Vec<PeerEntry> = alive
                .iter()
                .map(|(id, addr)| PeerEntry { node_id: *id, address: *addr })
                .collect();

            let deltas = store.take_delta_tiered(&tiers_due);
            if deltas.is_empty() && peer_entries.is_empty() { continue }

            gauge!("gossip_delta_size").set(deltas.len() as f64);

            let msg = GossipMessage { sender_id: node_id, updates: deltas, peers: peer_entries };
            let bytes = match rmp_serde::to_vec(&msg) {
                Ok(b) => b,
                Err(_) => continue,
            };

            let targets: Vec<SocketAddr> = if alive.is_empty() {
                seed_peers.clone()
            } else {
                let mut rng = rand::rng();
                alive.iter().map(|(_, addr)| *addr).sample(&mut rng, 3.min(alive.len()))
            };

            for peer in &targets { let _ = socket.send_to(&bytes, peer).await; }
            counter!("gossip_messages_sent_total").increment(targets.len() as u64);
        }
    }

    async fn receiver_loop(
        node_id: NodeId,
        peer_table: Arc<PeerTable>,
        store: Arc<CRDTStore>,
        socket: Arc<UdpSocket>,
    ) -> tokio::io::Result<()> {
        // 65535 bytes = udp max packet size
        let mut buffer = vec![0u8; UDP_PACKET_MAX_SIZE];

        loop {
            let (len, src) = socket.recv_from(&mut buffer).await?;
            // tracing::debug!("receiver got {} bytes from {}", len, src);

            // Adding in functionality to detect if it's a probe message
            if let Ok(probe) = rmp_serde::from_slice::<ProbeMessage>(&buffer[..len]) {
                match probe {
                    ProbeMessage::Ping { sender_id, seq } => {
                        // if this is the first time seeing this node, then add it to the
                        // peer table
                        if !peer_table.get(&sender_id) {
                            peer_table.insert(src, sender_id);
                            tracing::info!("receiver: inserted new peer {} at {}", sender_id, src);
                        }
                        peer_table.mark_alive(sender_id);
                        let ack = ProbeMessage::Ack { sender_id: node_id, seq };
                        let bytes = rmp_serde::to_vec(&ack).unwrap();
                        let _ = socket.send_to(&bytes, src).await;
                        peer_table.mark_alive(sender_id);
                        continue;
                    }
                    ProbeMessage::Ack { sender_id, .. } => {
                        // ack received: mark the peer alive so probe.rs
                        // sees the updated state after its sleep window
                        peer_table.mark_alive(sender_id);
                        tracing::info!("peer {} alive (probe ack)", sender_id);
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

            // if this is the first time seeing this node, then add it to the
            // peer table
            if !peer_table.get(&msg.sender_id) {
                peer_table.insert(src, msg.sender_id);
            }
            peer_table.mark_alive(msg.sender_id);

            counter!("gossip_message_received_total").increment(1);

            for peer in &msg.peers {
                if peer.node_id != node_id && !peer_table.get(&peer.node_id) {
                    peer_table.insert(peer.address, peer.node_id);
                    tracing::info!("discovered peer {} via gossip from {}", peer.node_id, msg.sender_id);
                }
            }

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
        let socket = Arc::clone(&self.socket);
        let peer_table_sender_ref = Arc::clone(&self.peer_table);
        let sender_socket = Arc::clone(&self.socket);
        let strategy = self.gossip_strategy.clone();

        let sender_store = Arc::clone(&store);
        tokio::spawn(async move {
            let _ = Self::sender_loop(
                sender_store, 
                peer_table_sender_ref, 
                node_id, 
                peers, 
                interval_ms,
                strategy,
                sender_socket,
            ).await;
        });

        let peer_table_receiver_ref = Arc::clone(&self.peer_table);
        tokio::spawn(async move {
            let _ = Self::receiver_loop(node_id, peer_table_receiver_ref, store, socket).await;
        });
    }
}







// ============================







#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::net::SocketAddr;
    use tokio::time::{sleep, Duration};
    use tokio::net::UdpSocket;

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
        let socket_a = Arc::new(UdpSocket::bind(addr(19000)).await.unwrap());
        let socket_b = Arc::new(UdpSocket::bind(addr(19001)).await.unwrap());

        let table_a = make_peer_table(vec![(NODE_B, addr(19001))]);
        let table_b = make_peer_table(vec![(NODE_A, addr(19000))]);

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a), NODE_A, vec![addr(19001)], 50, "fixed".to_string(), socket_a, table_a,
        );
        let engine_b = GossipEngine::new(
            Arc::clone(&store_b), NODE_B, vec![addr(19000)], 50, "fixed".to_string(),socket_b, table_b,
        );

        engine_a.run().await;
        engine_b.run().await;

        store_a.increment(KEY, EPOCH, NODE_A, 10, 0);
        sleep(Duration::from_millis(300)).await;

        assert_eq!(store_b.estimated_count(KEY, EPOCH, 1.0), 10.0);
    }

    #[tokio::test]
    async fn bidirectional_sync() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());
        let socket_a = Arc::new(UdpSocket::bind(addr(19002)).await.unwrap());
        let socket_b = Arc::new(UdpSocket::bind(addr(19003)).await.unwrap());

        let table_a = make_peer_table(vec![(NODE_B, addr(19003))]);
        let table_b = make_peer_table(vec![(NODE_A, addr(19002))]);

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a), NODE_A, vec![addr(19003)], 50, "fixed".to_string(),socket_a, table_a,
        );
        let engine_b = GossipEngine::new(
            Arc::clone(&store_b), NODE_B, vec![addr(19002)], 50, "fixed".to_string(),socket_b, table_b,
        );

        engine_a.run().await;
        engine_b.run().await;

        store_a.increment(KEY, EPOCH, NODE_A, 10, 0);
        store_b.increment(KEY, EPOCH, NODE_B, 20, 0);
        sleep(Duration::from_millis(300)).await;

        assert_eq!(store_a.estimated_count(KEY, EPOCH, 1.0), 30.0);
        assert_eq!(store_b.estimated_count(KEY, EPOCH, 1.0), 30.0);
    }

    #[tokio::test]
    async fn no_data_no_crash() {
        let store_a = Arc::new(CRDTStore::new());
        let store_b = Arc::new(CRDTStore::new());
        let socket_a = Arc::new(UdpSocket::bind(addr(19004)).await.unwrap());
        let socket_b = Arc::new(UdpSocket::bind(addr(19005)).await.unwrap());

        let table_a = make_peer_table(vec![(NODE_B, addr(19005))]);
        let table_b = make_peer_table(vec![(NODE_A, addr(19004))]);

        let engine_a = GossipEngine::new(
            Arc::clone(&store_a), NODE_A, vec![addr(19005)], 50, "fixed".to_string(),socket_a, table_a,
        );
        let engine_b = GossipEngine::new(
            Arc::clone(&store_b), NODE_B, vec![addr(19004)], 50, "fixed".to_string(),socket_b, table_b,
        );

        engine_a.run().await;
        engine_b.run().await;
        sleep(Duration::from_millis(200)).await;

        assert_eq!(store_a.estimated_count(KEY, EPOCH, 1.0), 0.0);
        assert_eq!(store_b.estimated_count(KEY, EPOCH, 1.0), 0.0);
    }
}