/*
    probe.rs
    Spawn tokio task, and probe the peers
*/

use std::{net::SocketAddr, sync::Arc, time::Duration};

use tokio::{net::UdpSocket, time::interval};

use crate::{membership::{PeerTable, ProbeMessage}, types::{NodeId, UDP_PACKET_MAX_SIZE}};

/// Probe a random peer in the cluster to check if they're still alive
/// 
/// Updates the peer table based on response
pub async fn probe(
    peer_table: Arc<PeerTable>, 
    bind_addr: SocketAddr, 
    node_id: NodeId, 
    probe_interval_seconds: u64,
) {
    let socket = UdpSocket::bind(bind_addr).await.unwrap();
    let mut ticker = interval(Duration::from_secs(probe_interval_seconds));
    let mut seq: u64 = 0;
    let mut buf = vec![0u8; UDP_PACKET_MAX_SIZE];

    loop {
        ticker.tick().await;
        seq += 1;
        let (peer_id, peer_addr) = match peer_table.random_peer() {
            Some(p) => p,
            None => continue,
        };

        let ping = ProbeMessage::Ping { sender_id: node_id, seq };
        let bytes = rmp_serde::to_vec(&ping).unwrap();
        let _ = socket.send_to(&bytes, peer_addr).await;

        let result = tokio::time::timeout(
            // TODO: Hardcoded timeout for peer ackknowlegedment
            Duration::from_millis(500),
            socket.recv_from(&mut buf),
        ).await;

        match result {
            Ok(Ok((len, _))) => {
                if let Ok(ProbeMessage::Ack { seq: ack_seq, .. }) = rmp_serde::from_slice(&buf[..len]) {
                    if ack_seq == seq{
                        peer_table.mark_alive(peer_id);
                    }
                }
            }
            _ => {
                // TODO: Hardcoded timeout for peer suspicion
                peer_table.mark_suspect(peer_id, Duration::from_secs(5));
            }
        }

        peer_table.promote_suspects_to_dead();
    }
}