# Distributed Rate Limiter

## So Far
 
- GCounter CRDT
- CRDT store (DashMap, delta tracking, sliding window)
- Rate limiter with checking before incrementoing logic
- UDP gossip engine (sender + receiver, MessagePack)
- HTTP server (axum w./ POST /check, GET /health)
- gRPC server (tonic w/ Envoy rls.proto v3 compatible)
- Prometheus metrics < :D >
- .toml config
- ttl-based eviction
- Demo w/ Docker + docker-compose 3-node cluster
- SWIM + Lifeguard membership (dynamic peer discovery)
- Rules-based gRPC config (replace hardcoded limits)
- Random gossip 
- Hook up Envoy end-to-end
 
## TODO
- Make nice documented README with diagrams and such
- Hand-write tests (current ones are AI-generated)
- LRU eviction for high-cardinality keys
- Benchmarks with Criterion
- Persistence and restart recovery
- Graceful shutdown
- TLS on gossip
- Rate limit rule hot reload
- Observability depth

## TODO Later
- eBPF kernel enforcement (maybe... this woul be cool though to have built in)
- pressure aware adaptive gossip protocol (gossip faster when keys approach limits)

## SWIM
SWIM (Scalable Weakly-consistent Infection-style Membership) is a protocol for distributed systems to track which nodes are alive and which have failed, without any central coordination needed. Each node independently monitors the cluster by randomly probing peers and gossiping what it learns to others.

How I implement it is pretty simple. Every second or so, each node picks a random peers and sends it a ping. If an ack comes back within the predetermined timeout window, the peer is alive. If no ack arrives, the peer is marked suspect (not dead yet), because the problem might be a network hiccup between just those two nodes rather than the peer actually being down. After a timeout period where no other node has seen the suspect peer either, it gets declared dead and remove from the alive peer set.

Gossip is how the information on the cluster spreads. Every gossip round, each node packages up its current state (counter updates, plus its known peer list) and sends it to its alive peers. Recipients merge what they receive with what they know. Within a few rounds, every node in the cluster converges on the same view of the world without any node ever needed to talk to all the others directly.

## Lifeguard
Lifeguard is an extension to SWIM developed by HashiCorp that makes failure detection much better and less prone to false positives. The two key ideas a health aware probe intervals and dogpile suspicion timeouts.

Health awayre probing means each node tracks its own health score based on how its recent probes have been going. If probes are succeeding consistently, it probes at the normal interval. If probes are timing out frequently, suggesting the node itself might be struggling or under load, it backs off and probes less aggressively. This prevents a degraded node from declaring half the cluster dead just cause it can't keep up.

Dogpile suspicion is about what happens when multiple nodes independently suspect the same peer. In SWIM, each nodeh as a fixed suspicion timeout. If nobody refutes the suspicion within the window, the peer is declared dead. Lifeguard makes the timeout dynamic. The more nodes that independently report suspicion of the same peer, the shorter the timeout becomes. 

In my implementation specifically, all of this runs over a single shared UDP socket per node. Gossip messages carry both the CRDT counter deltas and peer membership lists, so peer discovery and data sync happen in the same protocol rounds. A new node joining only needs to know one seed address, it announces itself and gets back the full peer list in the first gossip message it receives, and within just a couple rounds every node in the cluster knows it exists and starts probing it directly.

> **Note:** Tests are currently AI generated for quicker iteration. Hand written tests with better coverage and edge cases are ocming.