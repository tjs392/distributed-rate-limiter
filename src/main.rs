use tokio::net::UdpSocket;
/*
    main.rs
    Per node setup. Start with nodeid, port, peers, gossip intervals, etc.
*/
use std::{net::SocketAddr, sync::Arc, time::Duration};

use clap::Parser;
use metrics::gauge;
use metrics_exporter_prometheus::PrometheusBuilder;
use tokio::time::interval;
use tonic::transport::Server;
use crate::gossip::{GossipMessage, PeerEntry};
use crate::server::grpc::ratelimit::rate_limit_service_server::RateLimitServiceServer;
use crate::server::grpc::RateLimitServer;

use crate::{crdt::CRDTStore, gossip::GossipEngine, limiter::Limiter};

mod crdt;
mod gossip;
mod limiter;
mod types;
mod server;
mod config;
mod membership;
mod rules;

#[derive(Parser, Debug)]
#[command(name = "distributed-rate-limiter")]
struct Args {
    #[arg(long)]
    config: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    println!("starting distributed-rate-limiter...");

    let args = Args::parse();
    println!("loading config from: {}", args.config);

    let cfg = config::load(&args.config);
    println!("node {} starting", cfg.node.id);

    let bind_addr: SocketAddr = format!("0.0.0.0:{}", cfg.server.gossip_port).parse().unwrap();
    let http_addr: SocketAddr = format!("0.0.0.0:{}", cfg.server.http_port).parse().unwrap();
    let metrics_addr: SocketAddr = format!("0.0.0.0:{}", cfg.server.metrics_port).parse().unwrap();
    let grpc_addr: SocketAddr = format!("0.0.0.0:{}", cfg.server.grpc_port).parse().unwrap();
    let node_id = cfg.node.id;

    let store = Arc::new(CRDTStore::new());
    let peer_table = Arc::new(membership::PeerTable::new());

    let mut peers: Vec<SocketAddr> = vec![];
    for seed in &cfg.node.seeds {
        match tokio::net::lookup_host(&seed.address).await {
            Ok(mut addrs) => {
                if let Some(addr) = addrs.next() {
                    peers.push(addr);
                    peer_table.insert(addr, seed.id);
                }
            }
            Err(e) => eprintln!("failed to resolve {}: {}", seed.address, e),
        }
    }

    let gossip_socket = Arc::new(UdpSocket::bind(bind_addr).await.unwrap());

    let engine = GossipEngine::new(
        Arc::clone(&store),
        node_id,
        peers,
        cfg.gossip.interval_ms,
        Arc::clone(&gossip_socket),
        Arc::clone(&peer_table),
    );

    // This runs the gossip engine
    engine.run().await;

    // Set up metrics
    PrometheusBuilder::new().with_http_listener(metrics_addr).install()
        .expect("failed to install metrics exporter");

    // This sets up an eviction task (every 10 seconds for now)
    let eviction_store = Arc::clone(&store);
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(10));

        loop {
            ticker.tick().await;
            eviction_store.evict(Duration::from_secs(cfg.node.eviction_ttl_seconds));
            gauge!("store_entries_total").set(eviction_store.len() as f64);
        }
    });

    // This spawns the membership probe task
    let probe_table = Arc::clone(&peer_table);
    let probe_socket = Arc::clone(&gossip_socket);
    tokio::spawn(async move {
        membership::probe::probe(
            probe_table,
            probe_socket,
            node_id,
            cfg.membership.probe_interval_seconds,
            cfg.membership.probe_timeout_ms,
            cfg.membership.base_suspicion_timeout_ms,
            cfg.membership.min_suspicion_timeout_ms,
            cfg.membership.max_health_score,
        ).await;
    });

    let limiter = Arc::new(Limiter::new(Arc::clone(&store), node_id));
    let rules = Arc::new(rules::loader::load(&cfg.rules_file));
    
    // Set up the gRPC server for envoy
    let grpc_server = RateLimitServer::new(
        Arc::clone(&limiter),
        Arc::clone(&rules),
    );
    tokio::spawn(async move {
        println!("node {} gRPC listening on {}", node_id, grpc_addr);
        Server::builder()
            .add_service(RateLimitServiceServer::new(grpc_server))
            .serve_with_shutdown(grpc_addr, shutdown_signal())
            .await.unwrap();
    });

    // This sets up the listener
    let router = crate::server::http::create_router(Arc::clone(&limiter));
    let listener = tokio::net::TcpListener::bind(http_addr).await.unwrap();

    println!("node {} listening on http://{}", node_id, http_addr);

    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();

    // some cleanup after graceful shutdown
    // grpc and http servers have shut down, but tokio threads still running
    // just send data to all peers before shutting down
    let deltas = store.take_delta();

    let alive = peer_table.get_alive_peers();
    let peer_entries: Vec<PeerEntry> = alive
        .iter()
        .map(|(id, addr)| PeerEntry { node_id: *id, address: *addr })
        .collect();
    
    let msg = GossipMessage {
        sender_id: node_id,
        updates: deltas,
        peers: peer_entries,
    };

    // rmp_serde = rust message pack, binary, compact, faster than regular
    // serde_json this uses MessagePack format
    let bytes = match rmp_serde::to_vec(&msg) {
        Ok(b) => b,
        Err(_) => { return; },
    };

    for peer in peer_table.get_alive_peers() {
        let _ = gossip_socket.send_to(&bytes, peer.1).await;
    }

    // just a short pause to make sure the udp opackets leave the buffer
    tokio::time::sleep(Duration::from_millis(200)).await
}

async fn shutdown_signal() {
    tokio::signal::ctrl_c()
        .await
        .expect("Failed to install signal handler");
}