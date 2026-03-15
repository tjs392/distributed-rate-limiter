use std::{net::SocketAddr, sync::Arc};

use clap::Parser;

use crate::{crdt::CRDTStore, gossip::GossipEngine, limiter::Limiter, types::NodeId};

pub mod crdt;
pub mod gossip;
pub mod limiter;
pub mod types;

#[derive(Parser, Debug)]
#[command(name = "distributed-rate-limiter")]
struct Args {
    #[arg(long)]
    node_id: NodeId,

    #[arg(long)]
    port: u16,

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
    let limiter = Limiter::new(Arc::clone(&store), node_id);
    let engine = GossipEngine::new(
        Arc::clone(&store),
        node_id,
        peers,
        gossip_interval,
        bind_addr,
    );

    engine.run().await;

    let test_limiter = limiter;
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(tokio::time::Duration::from_secs(1));
        loop {
            tick.tick().await;
            let result = test_limiter.check_rate_limit("test_key", 100, 1, 60000);
            println!("node {}: {:?}", node_id, result);
        }
    });

    tokio::signal::ctrl_c().await.unwrap();
}