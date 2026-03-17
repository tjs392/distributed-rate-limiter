use axum::{
    extract::Path,
    http::{HeaderMap, StatusCode},
    response::Json,
    routing::get,
    Router,
};
use serde::Serialize;
use std::net::SocketAddr;
use std::time::Instant;

#[derive(Serialize)]
struct Response {
    status: &'static str,
    path: String,
    message: &'static str,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
    uptime_secs: u64,
}

static mut START_TIME: Option<Instant> = None;

async fn handle_request(
    headers: HeaderMap,
    axum::extract::OriginalUri(uri): axum::extract::OriginalUri,
) -> Json<Response> {
    Json(Response {
        status: "ok",
        path: uri.path().to_string(),
        message: "Hello from backend",
    })
}

async fn health() -> Json<HealthResponse> {
    let uptime = unsafe { START_TIME.map(|s| s.elapsed().as_secs()).unwrap_or(0) };
    Json(HealthResponse {
        status: "ok",
        uptime_secs: uptime,
    })
}

#[tokio::main]
async fn main() {
    unsafe { START_TIME = Some(Instant::now()) };

    let app = Router::new()
        .route("/health", get(health))
        .fallback(get(handle_request).post(handle_request));

    let addr: SocketAddr = "0.0.0.0:3000".parse().unwrap();
    println!("backend listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}