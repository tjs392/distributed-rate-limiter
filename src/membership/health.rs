/*
    /membership/health.rs
    health per node, LIFEGUARD implementation of SWIM
    see: https://arxiv.org/abs/1707.00788
 */

use std::sync::atomic::{AtomicU32, Ordering::Relaxed};
use std::time::Duration;



pub struct HealthChecker {
    // probe task and gossip receiver can update the health score
    score: AtomicU32,
    max_score: u32,
}

impl HealthChecker {
    pub fn new(max_score: u32) -> Self {
        HealthChecker { 
            score: AtomicU32::new(0), 
            max_score 
        }
    }

    /// Increment individual health score if the probe did not succeed under the time limit.
    /// This means that the node is either dead or under network or CPU pressure. This will
    /// propagate through and give it more time to respond to probes.
    /// 
    /// Capped at max_score
    pub fn probe_failed(&self) {
        let current = self.score.load(Relaxed);
        if current < self.max_score {
            self.score.store(current + 1, Relaxed);
        }
    }

    /// Decrement score if the probe succeeded under the time
    /// 
    /// Minimum at score 0 (healthiest score)
    pub fn probe_succeeded(&self) {
        let current = self.score.load(Relaxed);
        if current > 0 {
            self.score.store(current - 1, Relaxed);
        }
    }

    /// When the node is health (score 0), return base interval for health checking
    /// 
    /// When the node is struggling (say score 3), it returns base * n + 1 (base * 4)
    /// This gives it more time if under CPU pressure or network congestion so
    /// it does not trip false positives for dead nodes. See LifeGuard Swim Extension
    pub fn adjusted_interval(&self, base: Duration) -> Duration {
        base * (1 + self.score.load(Relaxed))
    }
}