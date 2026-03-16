FROM rust:latest AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y protobuf-compiler && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock build.rs ./
COPY proto/ proto/
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src target/release/distributed-rate-limiter target/release/deps/distributed*
COPY src/ src/
RUN cargo build --release

FROM debian:trixie-slim
COPY --from=builder /app/target/release/distributed-rate-limiter /usr/local/bin/
ENTRYPOINT ["distributed-rate-limiter"]