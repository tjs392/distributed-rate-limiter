use smallvec::SmallVec;

type NodeId = u128;

/*
    each entry in contributions represents:
    - which node contributed (incremented the counter)
    - how much that node has incremented

    GCounter works like this:
    - each node tracks its own count
    - when merging with another replica, you take the max of the elems
    - total count = sum of contributions
*/
#[derive(Clone, Debug)]
pub struct GCounter {
    contributions: SmallVec<[(NodeId, u64); 8]>,
}

impl GCounter {
    pub fn new() -> Self {
        GCounter {
            contributions: SmallVec::new(),
        }
    }

    // linear search here is fine because we wont have many elements (actual nodes)
    // TODO: Linear search inefficiency in case this becomes a bottleneck
    pub fn increment(&mut self, node: NodeId, hits: u64) {
        if let Some(entry) = self.contributions.iter_mut().find(|elem| elem.0 == node) {
            entry.1 += hits;
        } else {
            self.contributions.push((node, hits));
        }
    }

    // TODO: Merge can be optimized
    pub fn merge(&mut self, other: &GCounter) {
        for other_entry in &other.contributions {
            if let Some(entry) = self.contributions.iter_mut().find(|elem| elem.0 == other_entry.0) {
                entry.1 = entry.1.max(other_entry.1);
            } else {
                self.contributions.push(other_entry.clone());
            }
        }
    }

    fn total(&self) -> u64 {
        let mut total = 0;
        for entry in &self.contributions {
            total += entry.1;
        }
        total
    }
}

impl Default for GCounter {
    fn default() -> Self {
        GCounter::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NODE_A: NodeId = 1;
    const NODE_B: NodeId = 2;
    const NODE_C: NodeId = 3;

    #[test]
    fn single_increment() {
        let mut gc = GCounter::new();
        gc.increment(NODE_A, 5);
        assert_eq!(gc.total(), 5);
    }

    #[test]
    fn multiple_increments_same_node() {
        let mut gc = GCounter::new();
        gc.increment(NODE_A, 3);
        gc.increment(NODE_A, 7);
        assert_eq!(gc.total(), 10);
    }

    #[test]
    fn multiple_nodes() {
        let mut gc = GCounter::new();
        gc.increment(NODE_A, 10);
        gc.increment(NODE_B, 20);
        gc.increment(NODE_C, 30);
        assert_eq!(gc.total(), 60);
    }

    #[test]
    fn merge_disjoint() {
        let mut a = GCounter::new();
        a.increment(NODE_A, 10);

        let mut b = GCounter::new();
        b.increment(NODE_B, 20);

        a.merge(&b);
        assert_eq!(a.total(), 30);
    }

    #[test]
    fn merge_takes_max_not_sum() {
        let mut a = GCounter::new();
        a.increment(NODE_A, 10);

        let mut b = GCounter::new();
        b.increment(NODE_A, 7);

        a.merge(&b);
        assert_eq!(a.total(), 10);
    }

    #[test]
    fn idempotent() {
        let mut a = GCounter::new();
        a.increment(NODE_A, 5);
        a.increment(NODE_B, 3);

        let snapshot = a.clone();
        a.merge(&snapshot);
        assert_eq!(a.total(), 8);
    }

    #[test]
    fn commutative() {
        let mut a = GCounter::new();
        a.increment(NODE_A, 10);

        let mut b = GCounter::new();
        b.increment(NODE_B, 20);

        let mut ab = a.clone();
        ab.merge(&b);

        let mut ba = b.clone();
        ba.merge(&a);

        assert_eq!(ab.total(), ba.total());
    }

    #[test]
    fn associative() {
        let mut a = GCounter::new();
        a.increment(NODE_A, 5);

        let mut b = GCounter::new();
        b.increment(NODE_B, 10);

        let mut c = GCounter::new();
        c.increment(NODE_C, 15);

        let mut ab_c = a.clone();
        ab_c.merge(&b);
        ab_c.merge(&c);

        let mut bc = b.clone();
        bc.merge(&c);
        let mut a_bc = a.clone();
        a_bc.merge(&bc);

        assert_eq!(ab_c.total(), a_bc.total());
    }

    #[test]
    fn empty_counter() {
        let gc = GCounter::new();
        assert_eq!(gc.total(), 0);
    }

    #[test]
    fn merge_with_empty() {
        let mut a = GCounter::new();
        a.increment(NODE_A, 42);

        let empty = GCounter::new();
        a.merge(&empty);
        assert_eq!(a.total(), 42);
    }

    #[test]
    fn increment_uses_add_not_max() {
        let mut gc = GCounter::new();
        gc.increment(NODE_A, 5);
        gc.increment(NODE_A, 5);
        assert_eq!(gc.total(), 10);
    }
}
