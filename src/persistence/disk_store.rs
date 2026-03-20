/*
    /persistence/disk_store.rs
    Persisting through crashes and stuff
    Trying it out with redb:
    https://github.com/cberner/redb

    Why redb?
    - Pure rust
    - Supports non durable transactions for batched writes
    - ACID
*/

use redb::{Database, ReadableDatabase, ReadableTable, TableDefinition};

use crate::crdt::GCounter;

/*
Key value definition
Key = 8 bit slices of key_hash + epoch
Value = GCounter (MEssage pack Bytes of varlen)
*/
const TABLE: TableDefinition<&[u8], &[u8]> = TableDefinition::new("counters");

pub struct DiskStore {
    db: Database,
}

impl DiskStore {
    pub fn new(data_dir: &str) -> Self {
        DiskStore {
            db: Database::create(data_dir).expect("failed to open redb"),
        }
    }

    pub fn put(&self, key_hash: u64, epoch: u64, counter: &GCounter) {
        let mut key_bytes = Vec::new();
        key_bytes.extend_from_slice(&key_hash.to_be_bytes());
        key_bytes.extend_from_slice(&epoch.to_be_bytes());

        let value_bytes = rmp_serde::to_vec(counter).expect("failed to serialize the counter");

        let write_txn = self.db.begin_write().expect("failed begin write");
        {
            let mut table = write_txn.open_table(TABLE).expect("failed on table open");
            table.insert(key_bytes.as_slice(), value_bytes.as_slice()).expect("failed to insert into table");
        }
        write_txn.commit().expect("failed to commit");
    }

    pub fn get(&self, key_hash: u64, epoch: u64) -> Option<GCounter> {
        let mut key_bytes = Vec::new();
        key_bytes.extend_from_slice(&key_hash.to_be_bytes());
        key_bytes.extend_from_slice(&epoch.to_be_bytes());

        let read_txn = self.db.begin_read().expect("couldnt read");
        let table = match read_txn.open_table(TABLE) {
            Ok(t) => t,
            Err(_) => return None,
        };
        
        let result = table.get(key_bytes.as_slice());
        match result {
            Ok(Some(value)) => {
                let counter: GCounter = rmp_serde::from_slice(value.value()).expect("failed deserialization");
                tracing::info!("disk hit key_hash={} epoch={}", key_hash, epoch);
                Some(counter)
            }
            _ => {
                tracing::info!("disk miss key_hash={} epoch={}", key_hash, epoch);
                None
            }
        }
    }
    
    pub fn flush_all(&self, entries: &[((u64, u64), GCounter)]) {
        let write_txn = self.db.begin_write().expect("failed begin write");
        {
            let mut table = write_txn.open_table(TABLE).expect("failed open table");
            for ((key_hash, epoch), counter) in entries {
                let mut key_bytes = Vec::new();
                key_bytes.extend(&key_hash.to_be_bytes());
                key_bytes.extend(&epoch.to_be_bytes());

                let value_bytes = rmp_serde::to_vec(counter).expect("failed to serialize");
                table.insert(key_bytes.as_slice(), value_bytes.as_slice()).expect("failed to insert");
            }
        }
        write_txn.commit().expect("failed to commit");
    }

    pub fn delete_expired(&self, min_epoch: u64) {
        let write_txn = self.db.begin_write().expect("failed begin write");
        {
            let mut table = write_txn.open_table(TABLE).expect("failed on table open");
            let mut to_delete: Vec<Vec<u8>> = Vec::new();

            let iter = table.iter().expect("failed iter");
            for entry in iter {
                let (key, _) = entry.expect("failed to read entry");
                let key_bytes = key.value();
                let epoch = u64::from_be_bytes(key_bytes[8..16].try_into().unwrap());

                if epoch < min_epoch {
                    to_delete.push(key_bytes.to_vec());
                }
            }

            for key in &to_delete {
                table.remove(key.as_slice()).expect("failed to delete");
            }

        }
        write_txn.commit().expect("failed to commit");
    }
}





// ===========================








#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::GCounter;
    use std::fs;

    fn temp_db(name: &str) -> DiskStore {
        let path = format!("/tmp/test_{}.redb", name);
        let _ = fs::remove_file(&path);
        DiskStore::new(&path)
    }

    #[test]
    fn put_and_get() {
        let store = temp_db("put_and_get");
        let mut counter = GCounter::new();
        counter.increment(1, 10);

        store.put(100, 42, &counter);
        let result = store.get(100, 42);

        assert!(result.is_some());
        assert_eq!(result.unwrap().total(), 10);
    }

    #[test]
    fn get_missing_key() {
        let store = temp_db("get_missing");
        assert!(store.get(999, 999).is_none());
    }

    #[test]
    fn flush_all_batch() {
        let store = temp_db("flush_all");
        let mut c1 = GCounter::new();
        c1.increment(1, 10);
        let mut c2 = GCounter::new();
        c2.increment(2, 20);

        let entries = vec![
            ((100, 1), c1),
            ((200, 2), c2),
        ];
        store.flush_all(&entries);

        assert_eq!(store.get(100, 1).unwrap().total(), 10);
        assert_eq!(store.get(200, 2).unwrap().total(), 20);
    }

    #[test]
    fn delete_expired_removes_old() {
        let store = temp_db("delete_expired");
        let mut counter = GCounter::new();
        counter.increment(1, 5);

        store.put(100, 10, &counter);
        store.put(100, 50, &counter);

        store.delete_expired(30);

        assert!(store.get(100, 10).is_none());
        assert!(store.get(100, 50).is_some());
    }

    #[test]
    fn put_overwrites() {
        let store = temp_db("put_overwrites");
        let mut c1 = GCounter::new();
        c1.increment(1, 10);
        store.put(100, 42, &c1);

        let mut c2 = GCounter::new();
        c2.increment(1, 50);
        store.put(100, 42, &c2);

        assert_eq!(store.get(100, 42).unwrap().total(), 50);
    }
}