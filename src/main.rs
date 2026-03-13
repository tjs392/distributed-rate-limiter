mod crdt;
pub mod types;
use std::mem::{size_of, align_of};

use crate::crdt::gcounter::GCounter;

type NodeId = u128;

fn main() {
    println!("Element size: {}", size_of::<(NodeId, u64)>());
    println!("Element align: {}", align_of::<(NodeId, u64)>());
    println!("GCounter size: {}", size_of::<GCounter>());
}