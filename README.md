# Distributed Rate Limiter

A distributed, gossip based rate limiter in Rust. Runs with a single binary, zero external dependencies. Nodes discover eachother, sync counters via CRDTs over UDP, and detect failures using SWIM + Lifeguard protcols. Compatible with Envoy's rate limit gRPC API.

## Features

- G-Counter CRDTs with sliding window rate limiting
- UDP gossip protocol (MessagePack, delta-only sync, K=3 random peers)
- SWIM+Lifeguard membership (Self-Awareness, Dogpile)
- Envoy-compatible gRPC API (`envoy.service.ratelimit.v3`)
- HTTP REST API (axum)
- YAML rule -based rate limit configuration
- Disk persistence (redb) with graceful shutdown
- Prometheus metrics
- Dynamic peer discovery, nodes only need one seed address

For a deep dive into the architecture, CRDT design, gossip protocol, and SWIM+Lifeguard implementation, see the [technical overview]().

## Quickstart

### Docker (5-node cluster)

```bash
docker compose up --build -d
```

### Single binary

```bash
cargo build --release
./target/release/distributed-rate-limiter --config config/node1.toml
```

## Usage

### HTTP

```bash
# Rate limit check
curl -X POST http://localhost:8080/check \
  -H "Content-Type: application/json" \
  -d '{"key":"user:123","limit":10,"hits":1,"window_ms":60000}'

# {"status":200,"remaining":9,"retry_after_ms":null}

# Health check
curl http://localhost:8080/health

# {"status":200,"node_id":1}
```

### gRPC with Envoy
 
```bash
grpcurl -plaintext -d '{
  "domain": "my_app",
  "descriptors": [{"entries": [{"key": "tier", "value": "free"}]}]
}' localhost:50051 envoy.service.ratelimit.v3.RateLimitService/ShouldRateLimit
```
 
## Configuration
 
### Node config Example: `config/node1.toml`
 
```toml
rules_file = "/config/rules.yaml"
 
[node]
id = 1
eviction_ttl_seconds = 120
eviction_interval_seconds = 10
persistent_store_path = "/data"
 
[[node.seeds]]
id = 2
address = "node2:9000"
 
[[node.seeds]]
id = 3
address = "node3:9000"
 
[gossip]
interval_ms = 100
 
[server]
http_port = 8080
gossip_port = 9000
metrics_port = 9090
grpc_port = 50051
 
[membership]
probe_interval_seconds = 1
probe_timeout_ms = 1500
min_suspicion_timeout_ms = 1000
base_suspicion_timeout_ms = 5000
max_health_score = 8
```
 
### Rate limit rules example: `config/rules.yaml`
 
```yaml
domains:
  - domain: my_app
    descriptors:
      - key: tier
        value: free
        rate_limit:
          unit: minute
          requests_per_unit: 600
        descriptors:
          - key: path
            value: /api/search
            rate_limit:
              unit: minute
              requests_per_unit: 60
          - key: path
            value: /api/write
            rate_limit:
              unit: minute
              requests_per_unit: 30
 
      - key: tier
        value: premium
        rate_limit:
          unit: minute
          requests_per_unit: 6000
        descriptors:
          - key: path
            value: /api/search
            rate_limit:
              unit: minute
              requests_per_unit: 600
 
  - domain: api
    descriptors:
      - key: user_id
        rate_limit:
          unit: minute
          requests_per_unit: 1000
 
  - domain: internal
    descriptors:
      - key: service_name
        rate_limit:
          unit: minute
          requests_per_unit: 10000
```
 
## Benchmarks
 
#### Single node, Intel Core I5
 
| Benchmark | Throughput | p50 | p99 |
|-----------|-----------|-----|-----|
| Core check (in-memory) | ~9M ops/sec | ~108ns |  |
| HTTP API (50 concurrent) | ~51K req/sec | ~600µs | ~2.9ms |
| gRPC API (50 concurrent) | ~25K req/sec | ~1.4ms | ~3.6ms |
 
#### Criterion microbenchmarks
 
| Operation | Time |
|-----------|------|
| GCounter increment | ~1.6ns |
| GCounter total (5 nodes) | ~1.4ns |
| GCounter merge (5 nodes) | ~18.8ns |
| CRDTStore hot path | ~86ns |
| Gossip serialize (100 keys) | ~3.7µs |
| Gossip deserialize (100 keys) | ~12.9µs |
 
#### HTTP throughput (single node)
 
| Tool | Concurrency | Requests/sec | Avg Latency | P99 Latency |
|------|-------------|-------------|-------------|-------------|
| hey | 50 | ~59K | 0.8ms |  |
| wrk | 50 | ~135K | 348µs |  |
| hey | 200 | ~107K | 1.8ms |  |
 
#### gRPC throughput (single node)
 
| Concurrency | Requests/sec | Avg Latency | P99 Latency |
|-------------|-------------|-------------|-------------|
| 1 | ~2.5K | 0.33ms | 0.65ms |
| 10 | ~10.7K | 0.73ms | 1.81ms |
| 50 | ~19.6K | 1.93ms | 4.74ms |
| 100 | ~22K | 3.14ms | 7.74ms |
| 200 | ~22K | 6.54ms | 16.86ms |
 
#### HTTP latency under increasing concurrency
 
| Concurrency | Requests/sec | Avg Latency |
|-------------|-------------|-------------|
| 10 | ~22K | 0.4ms |
| 50 | ~50K | 0.9ms |
| 100 | ~60K | 1.6ms |
| 200 | ~61K | 3.1ms |
| 500 | ~33K | 14ms |
 
#### gRPC latency under increasing concurrency
 
| Concurrency | Requests/sec | Avg Latency | P99 Latency |
|-------------|-------------|-------------|-------------|
| 10 | ~11.8K | 0.66ms |  |
| 50 | ~21.6K | 1.79ms |  |
| 100 | ~25.3K | 2.96ms |  |
| 200 | ~26K | 5.78ms |  |
| 500 | ~27.2K | 13.34ms |  |
 
#### Multi-descriptor overhead
 
| Request Type | Requests/sec | Avg Latency |
|-------------|-------------|-------------|
| Single descriptor (gRPC) | ~20.2K | 1.93ms |
| Multi descriptor (gRPC) | ~18.5K | 2.09ms |
| Multi descriptor (gRPC, hey) | ~17.8K | 2.22ms |
 
#### 5-node cluster throughput
 
| Protocol | Per-node RPS | Combined RPS | Avg Latency | P99 Latency |
|----------|-------------|-------------|-------------|-------------|
| gRPC | ~9.3K | ~46.5K | 4.5ms | ~13.8ms |
| gRPC (stress) | ~15.8K | ~78.9K | 5.0ms |  |
 
#### Gossip convergence
 
| Metric | Value |
|--------|-------|
| Min | 40ms |
| Avg | 190ms |
| P50 | 96ms |
| Max | 622ms |
 
Measured over 10 trials, sending a request to node1 and polling node5 for propagation.
 
#### Throughput under node failure
 
| Protocol | RPS during failure/recovery | Avg Latency |
|----------|---------------------------|-------------|
| HTTP (benchmark) | ~192 |  |
| HTTP (stress, c=200) | ~72.5K | 2.5ms |
| gRPC (benchmark) | ~26.7K | 1.64ms |
 
#### Rate limit accuracy
 
With `limit=20`, sending 25 requests: exactly 20 allowed, exactly 5 denied. Zero over-admission under single-node sequential load.
 
## Stress Tests
 
All stress tests run against the 5-node Docker cluster.
 
```bash
./tests/stress.sh
```
 
**HTTP**: 100K requests at c=200  **107K req/sec**, avg 1.8ms.
 
**gRPC**: 100K requests at c=200  **48K req/sec**, avg 3.38ms.
 
**Distributed gRPC**: 5 nodes at c=100 each for 15s  **78.9K combined req/sec**, ~5ms avg per node.
 
**Node failure resilience**: sustained HTTP load over 25s while killing and restarting a node  **72.5K req/sec** maintained throughout with no errors.
 
## SWIM+Lifeguard Failure Detection
 
Tested by killing a node and observing the membership protocol lifecycle:
 
| Event | Time |
|-------|------|
| Node killed | T+0s |
| Marked suspect (probe timeout) | T+8s |
| Declared dead | T+14s |
| Node restarted | T+16s |
| Marked alive (recovered) | T+18s |
| Cluster converged (spread ≤ 5) | T+26s |
 
Remaining nodes continue serving requests throughout the entire failure/recovery cycle. After rejoin, gossip converges with counter spread ≤ 5 across all nodes.
 
## Integration Tests
 
All tests run against the Docker cluster.
```bash
docker compose up --build -d
 
# Core
./tests/benchmark.sh          # HTTP throughput (hey)
./tests/benchmark_grpc.sh     # gRPC throughput (ghz)
./tests/stress.sh             # Sustained load test
./tests/stress_test.sh        # High-concurrency stress
 
# Failure detection
./tests/lifeguard.sh          # Kill node, verify SWIM detection + rejoin
./tests/restart.sh            # Graceful shutdown + disk recovery
./tests/persistence.sh        # Eviction and disk persistence
 
# Envoy compatibility
./tests/envoy_e2e.sh          # End-to-end Envoy integration
./tests/grpc_test.sh          # gRPC API validation
./tests/rules.sh              # Rules matching across domains/tiers
```

## TODO
- Optimizaitons and feature expansions, TBD
- eBPF kernel enforcement (maybe... this woul be cool though to have built in)
- pressure aware adaptive gossip protocol (gossip faster when keys approach limits)
- TLS on gossip
- Rate limit rule hot reload
- Better benchmarks for cluster
- Observability depth