/*
Matching logic for parsing the yaml ru;le tree
*/

use crate::rules::{DescriptorNode, RateLimitUnit, RulesConfig};

pub fn match_domain_rules(
    domain: &str,
    request_descriptors: &[(String, String)],
    config: &RulesConfig,
) -> Vec<(u64, u64)> {
    let mut results = Vec::new();

    let domain_node = match config.domains.iter().find(|d| d.domain == domain) {
        Some(d) => d,
        None => return results,
    };

    for node in &domain_node.descriptors {
        walk_tree(
            node,
            request_descriptors,
            0,
            &mut results,
        );
    }

    results
}

fn walk_tree(
    node: &DescriptorNode,
    req_descs: &[(String, String)],
    depth: usize,
    results: &mut Vec<(u64, u64)>,
) {
    if depth >= req_descs.len() {
        return;
    }

    let (req_key, req_value) = &req_descs[depth];

    if !node_matches(node, req_key, req_value) {
        return;
    }

    if let Some(ref rl) = node.rate_limit {
        let window_ms = rate_limit_unit_to_ms(rl.unit);
        results.push((rl.requests_per_unit, window_ms));
    }

    for child in &node.descriptors {
        let next_depth = if node.key.is_some() && node.value.is_none() {
            depth
        } else {
            depth + 1
        };

        walk_tree(child, req_descs, next_depth, results);
    }
}

fn node_matches(
    node: &DescriptorNode,
    req_key: &str,
    req_value: &str
) -> bool {
    if let Some(ref k) = node.key {
        if k != req_key {
            return false;
        }
    }

    if let Some(ref v) = node.value {
        if v != req_value {
            return false;
        }
    }

    true
}

fn rate_limit_unit_to_ms(unit: RateLimitUnit) -> u64 {
    match unit {
        RateLimitUnit::Second => 1000,
        RateLimitUnit::Minute => 60_000,
        RateLimitUnit::Hour   => 3_600_000,
        RateLimitUnit::Day    => 86_400_000,
    }
}






// ===============






#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::{RateLimit, DomainConfig};

    fn test_config() -> RulesConfig {
        RulesConfig {
            domains: vec![
                DomainConfig {
                    domain: "my_app".to_string(),
                    descriptors: vec![
                        DescriptorNode {
                            key: Some("tier".to_string()),
                            value: Some("free".to_string()),
                            rate_limit: Some(RateLimit {
                                requests_per_unit: 100,
                                unit: RateLimitUnit::Minute,
                            }),
                            descriptors: vec![],
                        },
                        DescriptorNode {
                            key: Some("tier".to_string()),
                            value: Some("premium".to_string()),
                            rate_limit: Some(RateLimit {
                                requests_per_unit: 5000,
                                unit: RateLimitUnit::Minute,
                            }),
                            descriptors: vec![
                                DescriptorNode {
                                    key: Some("path".to_string()),
                                    value: Some("/api/search".to_string()),
                                    rate_limit: Some(RateLimit {
                                        requests_per_unit: 200,
                                        unit: RateLimitUnit::Minute,
                                    }),
                                    descriptors: vec![],
                                }
                            ],
                        },
                    ],
                }
            ],
        }
    }
    
    #[test]
    fn test_domain_not_found() {
        let config = test_config();

        let req = vec![("tier".to_string(), "free".to_string())];

        let results = match_domain_rules("unknown", &req, &config);

        assert!(results.is_empty());
    }

    #[test]
    fn test_free_tier_limit() {
        let config = test_config();

        let req = vec![("tier".to_string(), "free".to_string())];

        let results = match_domain_rules("my_app", &req, &config);

        assert_eq!(results, vec![(100, 60_000)]);
    }

    #[test]
    fn test_premium_tier_limit() {
        let config = test_config();

        let req = vec![("tier".to_string(), "premium".to_string())];

        let results = match_domain_rules("my_app", &req, &config);

        assert_eq!(results, vec![(5000, 60_000)]);
    }

    #[test]
    fn test_premium_search_limit() {
        let config = test_config();

        let req = vec![
            ("tier".to_string(), "premium".to_string()),
            ("path".to_string(), "/api/search".to_string()),
        ];

        let results = match_domain_rules("my_app", &req, &config);

        assert_eq!(results.len(), 2);

        assert!(results.contains(&(5000, 60_000)));
        assert!(results.contains(&(200, 60_000)));
    }

    #[test]
    fn test_no_match_value() {
        let config = test_config();

        let req = vec![("tier".to_string(), "unknown".to_string())];

        let results = match_domain_rules("my_app", &req, &config);

        assert!(results.is_empty());
    }

    #[test]
    fn test_partial_descriptor_no_deep_match() {
        let config = test_config();

        let req = vec![
            ("tier".to_string(), "premium".to_string()),
            ("path".to_string(), "/other".to_string()),
        ];

        let results = match_domain_rules("my_app", &req, &config);

        assert_eq!(results, vec![(5000, 60_000)]);
    }
}