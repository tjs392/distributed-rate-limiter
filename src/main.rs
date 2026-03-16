/*
    main.rs
    Per node setup. Start with nodeid, port, peers, gossip intervals, etc.
*/
use std::{net::SocketAddr, sync::Arc};

use clap::Parser;

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
    let args = Args::parse();
    let cfg = config::load(&args.config);

    let peers: Vec<SocketAddr> = cfg.node.seeds
        .iter()
        .map(|p| p.parse().expect("Invalid peer address"))
        .collect();

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

    let router = crate::server::http::create_router(Arc::clone(&limiter));
    let listener = tokio::net::TcpListener::bind(http_addr).await.unwrap();

    println!("node {} listening on http://{}", node_id, http_addr);

    axum::serve(listener, router).await.unwrap();
}