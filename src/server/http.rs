/*
    server/http.rs
    HTTP server for api calls for getting the rate limit and health
*/

use std::sync::Arc;

use axum::{Json, Router, extract::State, http::StatusCode, routing::{get, post}};
use serde::{Deserialize, Serialize};

use crate::{limiter::Limiter, types::RateLimitResult};

#[derive(Deserialize)]
struct CheckRequest {
    key: String,
    limit: u64,
    hits: u64,
    window_ms: u64,
}

#[derive(Serialize)]
struct CheckResponse {
    status: u16,
    remaining: Option<u64>,
    retry_after_ms: Option<u64>,
}

#[derive(Serialize)]
struct HealthResponse {
    status: u16,
    node_id: u128,
}

#[derive(Deserialize)]
struct EstimateRequest {
    key: String,
    limit: u64,
    window_ms: u64,
}

#[derive(Serialize)]
struct EstimateResponse {
    estimate: f64,
    remaining: f64,
    pressure: f64,
}

async fn estimate_handler(
    State(limiter): State<Arc<Limiter>>,
    Json(body): Json<EstimateRequest>,
) -> Json<EstimateResponse> {
    let estimate = limiter.estimate(&body.key, body.window_ms);
    let remaining = body.limit as f64 - estimate;
    let pressure = estimate / body.limit as f64;

    Json(EstimateResponse {
        estimate,
        remaining,
        pressure,
    })
}

async fn check_handler(
    State(limiter): State<Arc<Limiter>>,
    Json(body): Json<CheckRequest>,
) -> Json<CheckResponse> {
    let result = limiter.check_rate_limit(
        &body.key, 
        body.limit, 
        body.hits, 
        body.window_ms
    );

    match result {
        RateLimitResult::Allow { remaining } => {
            let resp = CheckResponse {
                status: StatusCode::OK.as_u16(), 
                remaining: Some(remaining),
                retry_after_ms: None,
            };
            Json(resp)
        }

        RateLimitResult::Deny { retry_after_ms } => {
            let resp = CheckResponse {
                status: StatusCode::TOO_MANY_REQUESTS.as_u16(), 
                remaining: Some(0),
                retry_after_ms: Some(retry_after_ms),
            };
            Json(resp)
        }
    }
}

async fn health_handler(
    State(limiter): State<Arc<Limiter>>,
) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: StatusCode::OK.as_u16(),
        node_id: limiter.node_id(),
    })
}

pub fn create_router(limiter: Arc<Limiter>) -> Router {
    Router::new()
        .route("/check", post(check_handler))
        .route("/estimate", post(estimate_handler))
        .route("/health", get(health_handler))
        .with_state(limiter)
}









// ==========================








#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;
    use crate::crdt::store::CRDTStore;
    use crate::persistence::DiskStore;
    use std::fs;

    fn make_router(name: &str) -> Router {
        let path = format!("/tmp/test_http_{}.redb", name);
        let _ = fs::remove_file(&path);
        let store = Arc::new(CRDTStore::new());
        let disk_store = Arc::new(DiskStore::new(&path));
        let limiter = Arc::new(Limiter::new(store, disk_store, 1, "fixed".to_string()));
        create_router(limiter)
    }

    #[tokio::test]
    async fn health_returns_ok() {
        let app = make_router("health_ok");
        let req = Request::builder()
            .uri("/health")
            .method("GET")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn check_under_limit() {
        let app = make_router("check_under");
        let req = Request::builder()
            .uri("/check")
            .method("POST")
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"key":"user:1","limit":10,"hits":1,"window_ms":60000}"#))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn check_over_limit() {
        let app = make_router("check_over");
        let req = Request::builder()
            .uri("/check")
            .method("POST")
            .header("Content-Type", "application/json")
            .body(Body::from(r#"{"key":"user:1","limit":2,"hits":3,"window_ms":60000}"#))
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn check_missing_body_returns_error() {
        let app = make_router("check_missing");
        let req = Request::builder()
            .uri("/check")
            .method("POST")
            .header("Content-Type", "application/json")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        assert_ne!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn health_returns_node_id() {
        let app = make_router("health_node_id");
        let req = Request::builder()
            .uri("/health")
            .method("GET")
            .body(Body::empty())
            .unwrap();

        let resp = app.oneshot(req).await.unwrap();
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let health: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(health["node_id"], 1);
        assert_eq!(health["status"], 200);
    }
}