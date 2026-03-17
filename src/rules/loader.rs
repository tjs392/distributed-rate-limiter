/*
    rules/loader.rs
*/

use std::fs;
use crate::rules::{DescriptorNode, RulesConfig};

pub fn load(path: &str) -> RulesConfig {
    let contents = fs::read_to_string(path)
        .expect("failed to read rules file");
    let config: RulesConfig = serde_yaml::from_str(&contents)
        .expect("failed to parse rules file");
    
    // validate no nodes are missing both key and value
    for domain in &config.domains {
        validate_descriptors(&domain.descriptors, &domain.domain);
    }
    
    config
}

fn validate_descriptors(nodes: &[DescriptorNode], domain: &str) {
    for node in nodes {
        if node.key.is_none() && node.value.is_none() {
            panic!("rules.yaml: domain {} has a descriptor node with neither key or value", domain);
        }
        validate_descriptors(&node.descriptors, domain);
    }
}