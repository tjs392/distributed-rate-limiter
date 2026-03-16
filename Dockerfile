FROM rust:latest AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src
COPY src/ src/
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/distributed-rate-limiter /usr/local/bin/
ENTRYPOINT ["distributed-rate-limiter"]