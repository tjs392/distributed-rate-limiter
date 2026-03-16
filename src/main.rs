/*
    main.rs
    Per node setup. Start with nodeid, port, peers, gossip intervals, etc.
*/
use std::{net::SocketAddr, sync::Arc, time::Duration};

use clap::Parser;
use tokio::time::interval;

use crate::{crdt::CRDTStore, gossip::GossipEngine, limiter::Limiter};

mod crdt;
mod gossip;
mod limiter;
mod types;
mod server;
mod config;

#[derive(Parser, Debug)]
#[command(name = "distributed-rate-limiter")]
struct Args {
    #[arg(long)]
    config: String,
}

#[tokio::main]
async fn main() {
    println!("starting distributed-rate-limiter...");

    let args = Args::parse();
    println!("loading config from: {}", args.config);

    let cfg = config::load(&args.config);
    println!("node {} starting", cfg.node.id);

    let mut peers: Vec<SocketAddr> = vec![];
    for seed in &cfg.node.seeds {
        match tokio::net::lookup_host(seed).await {
            Ok(mut addrs) => {
                if let Some(addr) = addrs.next() {
                    peers.push(addr);
                }
            }
            Err(e) => eprintln!("failed to resolve {}: {}", seed, e),
        }
    }

    let bind_addr: SocketAddr = format!("0.0.0.0:{}", cfg.server.gossip_port).parse().unwrap();
    let http_addr: SocketAddr = format!("0.0.0.0:{}", cfg.server.http_port).parse().unwrap();
    let node_id = cfg.node.id;

    let store = Arc::new(CRDTStore::new());
    let engine = GossipEngine::new(
        Arc::clone(&store),
        node_id,
        peers,
        cfg.gossip.interval_ms,
        bind_addr,
    );

    let limiter = Arc::new(Limiter::new(Arc::clone(&store), node_id));

    engine.run().await;

    let eviction_store = Arc::clone(&store);
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(10));

        loop {
            ticker.tick().await;
            eviction_store.evict(Duration::from_secs(cfg.node.eviction_ttl_seconds));
        }
    });

    let router = crate::server::http::create_router(Arc::clone(&limiter));
    let listener = tokio::net::TcpListener::bind(http_addr).await.unwrap();

    println!("node {} listening on http://{}", node_id, http_addr);

    axum::serve(listener, router).await.unwrap();
}