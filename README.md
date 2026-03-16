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
 
## TODO

- Make nice documented README with diagrams and such
- SWIM + Lifeguard membership (dynamic peer discovery)
- Rules-based gRPC config (replace hardcoded limits)
- Hook up Envoy end-to-end
- Hand-write tests (current ones are AI-generated)
- LRU eviction for high-cardinality keys
- Benchmarks with Criterion
- eBPF kernel enforcement (maybe... this woul be cool though to have built in)

> **Note:** Tests are currently AI generated for quicker iteration. Hand written tests with better coverage and edge cases are ocming.