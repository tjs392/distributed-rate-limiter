/*
    probe.rs
    Spawn tokio task, and probe the peers
*/

use std::{sync::Arc, time::{Duration, Instant}};

use tokio::{net::UdpSocket};

use crate::{membership::{HealthChecker, PeerTable, ProbeMessage}, types::{NodeId}};

/// Probe a random peer in the cluster to check if they're still alive
/// 
/// Updates the peer table based on response
/// 
/// Keeps track of struggling nodes using HealthChecker by adjusting
/// the probe timeout interval
pub async fn probe(
    peer_table: Arc<PeerTable>,
    socket: Arc<UdpSocket>,
    node_id: NodeId,
    probe_interval_seconds: u64,
    probe_timeout_ms: u64,
    base_suspicion_timeout_ms: u64,
    min_suspicion_timeout_ms: u64,
    max_health_score: u32,
) {
    tracing::info!("probe task started for node {}", node_id);

    let mut seq: u64 = 0;
    let health_checker = HealthChecker::new(max_health_score);
    let base_interval = Duration::from_secs(probe_interval_seconds);

    loop {
        tokio::time::sleep(health_checker.adjusted_interval(base_interval)).await;
        seq += 1;

        let (peer_id, peer_addr) = match peer_table.random_peer() {
            Some(p) => p,
            None => continue,
        };

        let ping = ProbeMessage::Ping { sender_id: node_id, seq };
        let bytes = match rmp_serde::to_vec(&ping) {
            Ok(b) => b,
            Err(e) => {
                tracing::error!("failed to serialize ping: {}", e);
                continue;
            }
        };

        let ping_time = Instant::now();

        if let Err(e) = socket.send_to(&bytes, peer_addr).await {
            tracing::error!("failed to send ping to {}: {}", peer_addr, e);
            continue;
        }

        // Wait for the gossip receiver to mark the peer alive via ack.
        // If it doesn't happen within the timeout window, mark suspect.
        tokio::time::sleep(Duration::from_millis(probe_timeout_ms)).await;

        if peer_table.ack_received_since(peer_id, ping_time) {
            health_checker.probe_succeeded();
        } else {
            peer_table.mark_suspect(peer_id, base_suspicion_timeout_ms, min_suspicion_timeout_ms);
            health_checker.probe_failed();
            tracing::info!("peer {} suspect (probe timeout)", peer_id);
        }

        peer_table.promote_suspects_to_dead();
    }
}