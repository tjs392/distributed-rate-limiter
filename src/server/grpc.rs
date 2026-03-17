/*
    server/grpc.rs
    My Envoy compatible grpc interface
*/

use std::sync::Arc;
use crate::{limiter::Limiter, rules::{RulesConfig, match_domain_rules}};
use ratelimit::rate_limit_response::{Code, DescriptorStatus};

/// Pull in the proto's generated types:
/// RateLimitRequest, RateLimitResponse, RateLimitDescriptor, RateLimitService
pub mod ratelimit {
    tonic::include_proto!("envoy.service.ratelimit.v3");
}

/// gRPC Rate Limiting Server
pub struct RateLimitServer {
    limiter: Arc<Limiter>,
    rules: Arc<RulesConfig>,
}

impl RateLimitServer {
    pub fn new(limiter: Arc<Limiter>, rules: Arc<RulesConfig>) -> Self {
        RateLimitServer { 
            limiter, 
            rules 
        }
    }
}

// Example Envoy gRPC request:
//
// RateLimitRequest {
//     domain: "my_app",
//     descriptors: [
//         RateLimitDescriptor {
//             entries: [
//                 Entry { key: "tier", value: "premium" },
//                 Entry { key: "user_id", value: "user1" }
//             ]
//         },
//         RateLimitDescriptor {
//             entries: [
//                 Entry { key: "path", value: "/api/search" }
//             ]
//         }
//     ],
//     hits_addend: 1
// }
//
// This handler builds a key per descriptor:
//   descriptor 1 -> "my_app:tier:premium:user_id:user1"
//   descriptor 2 -> "my_app:path:/api/search"
//
// Each key is checked independently against the limiter.
// If any descriptor is over limit, overall_code = OVER_LIMIT.
//
// Example response (user is fine, but endpoint is overloaded):
//
// RateLimitResponse {
//     overall_code: OVER_LIMIT,
//     statuses: [
//         DescriptorStatus { code: OK, limit_remaining: 950 },
//         DescriptorStatus { code: OVER_LIMIT, limit_remaining: 0 }
//     ]
// }
//
// Envoy reads overall_code and returns 429 to the client.
#[tonic::async_trait]
impl ratelimit::rate_limit_service_server::RateLimitService for RateLimitServer {
    async fn should_rate_limit(
        &self,
        request: tonic::Request<ratelimit::RateLimitRequest>,
    ) -> Result<tonic::Response<ratelimit::RateLimitResponse>, tonic::Status> {
        let req = request.into_inner();
        let domain = req.domain;
        let hits = if req.hits_addend == 0 { 1 } else { req.hits_addend as u64 };

        let mut statuses = Vec::new();
        let mut any_over_limit = false;

        for descriptor in req.descriptors {
            let mut key = domain.clone();
            let mut entries: Vec<(String, String)> = Vec::new();

            for entry in &descriptor.entries {
                key.push(':');
                key.push_str(&entry.key);
                key.push(':');
                key.push_str(&entry.value);
                entries.push((entry.key.clone(), entry.value.clone()));
            }

            let matched_rules = match_domain_rules(&domain, &entries, &self.rules);

            if matched_rules.is_empty() {
                // just allow through with warning by default
                tracing::warn!("no rule matched for key: {}", key);
                statuses.push(DescriptorStatus {
                    code: Code::Ok.into(),
                    current_limit: None,
                    limit_remaining: u32::MAX,
                    duration_until_reset: 0,
                });
                continue;
            }

            // apply the most restrictive matched rule by default
            let (limit, window_ms) = matched_rules
                .iter()
                .min_by_key(|(limit, _)| limit)
                .copied()
                .unwrap();

            let result = self.limiter.check_rate_limit(&key, limit, hits, window_ms);
            let status = match result {
                crate::types::RateLimitResult::Allow { remaining } => {
                    DescriptorStatus {
                        code: Code::Ok.into(),
                        current_limit: None,
                        limit_remaining: remaining as u32,
                        duration_until_reset: 0,
                    }
                }

                crate::types::RateLimitResult::Deny { retry_after_ms } => {
                    any_over_limit = true;
                    DescriptorStatus { 
                        code: Code::OverLimit.into(), 
                        current_limit: None, 
                        limit_remaining: 0, 
                        duration_until_reset: 
                        retry_after_ms 
                    }
                }
            };

            statuses.push(status);

        }

        let overall_code = if any_over_limit {
            Code::OverLimit.into()
        } else {
            Code::Ok.into()
        };

        Ok(tonic::Response::new(ratelimit::RateLimitResponse {
            overall_code,
            statuses,
        }))
    }
}