/*
    main.rs
    Per node setup. Start with nodeid, port, peers, gossip intervals, etc.
*/
use std::{net::SocketAddr, sync::Arc};

use clap::Parser;

use crate::{crdt::CRDTStore, gossip::GossipEngine, limiter::Limiter, types::NodeId};

pub mod crdt;
pub mod gossip;
pub mod limiter;
pub mod types;
pub mod server;

#[derive(Parser, Debug)]
#[command(name = "distributed-rate-limiter")]
struct Args {
    #[arg(long)]
    node_id: NodeId,

    #[arg(long)]
    port: u16,

    #[arg(long)]
    http_port: u16,

    #[arg(long, value_delimiter = ',')]
    peers: Vec<String>,

    #[arg(long)]
    gossip_interval: u64
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let peers: Vec<SocketAddr> = args.peers
        .iter()
        .map(|p| p.parse().expect("Not a good peer address"))
        .collect();

    let bind_addr: SocketAddr = format!("0.0.0.0:{}", args.port).parse().unwrap();
    let node_id = args.node_id;
    let gossip_interval = args.gossip_interval;

    let store = Arc::new(CRDTStore::new());
    let engine = GossipEngine::new(
        Arc::clone(&store),
        node_id,
        peers,
        gossip_interval,
        bind_addr,
    );

    let limiter = Arc::new(Limiter::new(Arc::clone(&store), node_id));

    engine.run().await;

    let http_addr: SocketAddr = format!("0.0.0.0:{}", args.http_port).parse().unwrap();
    let router = crate::server::http::create_router(Arc::clone(&limiter));
    let listener = tokio::net::TcpListener::bind(http_addr).await.unwrap();

    println!("node {} listening on http://{}", node_id, http_addr);

    axum::serve(listener, router).await.unwrap();

    tokio::signal::ctrl_c().await.unwrap();
}