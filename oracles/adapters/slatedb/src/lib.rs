use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use futures::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use slatedb::object_store::path::Path;
use slatedb::object_store::ObjectStore;
use slatedb::{Db, DbTransaction, ErrorKind, IsolationLevel};
use std::collections::{HashMap, HashSet};
use std::ops::Bound;
use std::sync::Arc;

const ADAPTER_PROTOCOL: &str = "flyology.db.oracle.adapter.v1";
const SLATEDB_COMMIT: &str = "e0161973d8d7ffdede7c44725729838811674e99";
const SLATEDB_VERSION: &str = "0.15.0";
const MAX_FAMILY_ID_BYTES: usize = 10;
const MAX_REQUEST_ID_BYTES: usize = 256;

const LOCAL_CAPABILITIES: [&str; 3] = ["snapshot", "serializable", "crash_recovery"];
const KNOWN_CAPABILITIES: [&str; 6] = [
    "multi_column_family",
    "remote_durable",
    "snapshot",
    "serializable",
    "crash_recovery",
    "outcome_resolution",
];

#[derive(Clone, Debug)]
pub struct AdapterLimits {
    pub transactions: usize,
    pub receipt_ids: usize,
    pub mutations_per_transaction: usize,
    pub key_bytes: usize,
    pub value_bytes: usize,
    pub scan_items: usize,
    pub scan_bytes: usize,
    pub state_items: usize,
    pub state_bytes: usize,
}

impl Default for AdapterLimits {
    fn default() -> Self {
        Self {
            transactions: 256,
            receipt_ids: 4_096,
            mutations_per_transaction: 4_096,
            key_bytes: 1_048_576,
            value_bytes: 16_777_216,
            scan_items: 100_000,
            scan_bytes: 67_108_864,
            state_items: 100_000,
            state_bytes: 67_108_864,
        }
    }
}

impl AdapterLimits {
    fn bounded(self) -> Self {
        let maximum = Self::default();
        Self {
            transactions: self.transactions.min(maximum.transactions),
            receipt_ids: self.receipt_ids.min(maximum.receipt_ids),
            mutations_per_transaction: self
                .mutations_per_transaction
                .min(maximum.mutations_per_transaction),
            key_bytes: self.key_bytes.min(maximum.key_bytes),
            value_bytes: self.value_bytes.min(maximum.value_bytes),
            scan_items: self.scan_items.min(maximum.scan_items),
            scan_bytes: self.scan_bytes.min(maximum.scan_bytes),
            state_items: self.state_items.min(maximum.state_items),
            state_bytes: self.state_bytes.min(maximum.state_bytes),
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkloadLimits {
    transactions: usize,
    mutations_per_transaction: usize,
    key_bytes: usize,
    value_bytes: usize,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ColumnFamily {
    id: String,
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Preflight {
        request_id: String,
        protocol: String,
        database_id: String,
        limits: WorkloadLimits,
        column_families: Vec<ColumnFamily>,
        required_capabilities: Vec<String>,
    },
    Create {
        request_id: String,
    },
    Open {
        request_id: String,
    },
    Reopen {
        request_id: String,
    },
    Recovery {
        request_id: String,
    },
    Begin {
        request_id: String,
        transaction: String,
        isolation: Isolation,
    },
    Get {
        request_id: String,
        transaction: String,
        column_family_id: String,
        key: String,
    },
    Put {
        request_id: String,
        transaction: String,
        column_family_id: String,
        key: String,
        value: String,
    },
    Delete {
        request_id: String,
        transaction: String,
        column_family_id: String,
        key: String,
    },
    Scan {
        request_id: String,
        transaction: String,
        column_family_id: String,
        lower: String,
        upper: String,
        maximum_items: usize,
    },
    Commit {
        request_id: String,
        transaction: String,
        receipt: Option<String>,
        durability: Durability,
    },
    Rollback {
        request_id: String,
        transaction: String,
    },
    Flush {
        request_id: String,
    },
    Checkpoint {
        request_id: String,
    },
    State {
        request_id: String,
        durability_barrier: bool,
    },
    Resolve {
        request_id: String,
        receipt: String,
    },
    Crash {
        request_id: String,
    },
}

impl Request {
    fn request_id(&self) -> &str {
        match self {
            Self::Preflight { request_id, .. }
            | Self::Create { request_id }
            | Self::Open { request_id }
            | Self::Reopen { request_id }
            | Self::Recovery { request_id }
            | Self::Begin { request_id, .. }
            | Self::Get { request_id, .. }
            | Self::Put { request_id, .. }
            | Self::Delete { request_id, .. }
            | Self::Scan { request_id, .. }
            | Self::Commit { request_id, .. }
            | Self::Rollback { request_id, .. }
            | Self::Flush { request_id }
            | Self::Checkpoint { request_id }
            | Self::State { request_id, .. }
            | Self::Resolve { request_id, .. }
            | Self::Crash { request_id } => request_id,
        }
    }

    fn transaction_id(&self) -> Option<&str> {
        match self {
            Self::Begin { transaction, .. }
            | Self::Get { transaction, .. }
            | Self::Put { transaction, .. }
            | Self::Delete { transaction, .. }
            | Self::Scan { transaction, .. }
            | Self::Commit { transaction, .. }
            | Self::Rollback { transaction, .. } => Some(transaction),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
pub enum Isolation {
    Snapshot,
    Serializable,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Durability {
    Remote,
    LocalComparative,
}

impl Isolation {
    fn slatedb(self) -> IsolationLevel {
        match self {
            Self::Snapshot => IsolationLevel::Snapshot,
            Self::Serializable => IsolationLevel::SerializableSnapshot,
        }
    }
}

struct HeldTransaction {
    value: DbTransaction,
    isolation: Isolation,
    mutations: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReceiptPhase {
    Success,
    OutcomeUnknown,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ActiveContract {
    database_id: [u8; 16],
    family_id: String,
    limits: WorkloadLimits,
}

pub struct Adapter {
    store: Arc<dyn ObjectStore>,
    database_path: Path,
    limits: AdapterLimits,
    contract: Option<ActiveContract>,
    db: Option<Db>,
    transactions: HashMap<String, HeldTransaction>,
    failed_transactions: HashSet<String>,
    unresolved_transactions: HashSet<String>,
    seen_receipts: HashMap<String, ReceiptPhase>,
    #[cfg(test)]
    inject_durability_data_failure_once: bool,
}

impl Adapter {
    pub fn new(store: Arc<dyn ObjectStore>, database_path: Path, limits: AdapterLimits) -> Self {
        Self {
            store,
            database_path,
            limits: limits.bounded(),
            contract: None,
            db: None,
            transactions: HashMap::new(),
            failed_transactions: HashSet::new(),
            unresolved_transactions: HashSet::new(),
            seen_receipts: HashMap::new(),
            #[cfg(test)]
            inject_durability_data_failure_once: false,
        }
    }

    pub async fn execute(&mut self, request: Request) -> Value {
        let request_id = request.request_id().to_owned();
        if request
            .transaction_id()
            .is_some_and(|transaction| decode_exact::<16>(transaction).is_err())
        {
            return unsupported(request_id, "transaction_id", None);
        }
        match request {
            Request::Preflight {
                protocol,
                database_id,
                limits,
                column_families,
                required_capabilities,
                ..
            } => {
                self.preflight(
                    request_id,
                    protocol,
                    database_id,
                    limits,
                    column_families,
                    required_capabilities,
                )
                .await
            }
            Request::Create { .. } => self.create(request_id).await,
            Request::Open { .. } => self.open(request_id, false).await,
            Request::Reopen { .. } => self.reopen(request_id).await,
            Request::Recovery { .. } => self.open(request_id, true).await,
            Request::Begin {
                transaction,
                isolation,
                ..
            } => self.begin(request_id, transaction, isolation).await,
            Request::Get {
                transaction,
                column_family_id,
                key,
                ..
            } => {
                self.get(request_id, transaction, column_family_id, key)
                    .await
            }
            Request::Put {
                transaction,
                column_family_id,
                key,
                value,
                ..
            } => {
                self.put(request_id, transaction, column_family_id, key, value)
                    .await
            }
            Request::Delete {
                transaction,
                column_family_id,
                key,
                ..
            } => {
                self.delete(request_id, transaction, column_family_id, key)
                    .await
            }
            Request::Scan {
                transaction,
                column_family_id,
                lower,
                upper,
                maximum_items,
                ..
            } => {
                self.scan(
                    request_id,
                    transaction,
                    column_family_id,
                    lower,
                    upper,
                    maximum_items,
                )
                .await
            }
            Request::Commit {
                transaction,
                receipt,
                durability,
                ..
            } => {
                self.commit(request_id, transaction, receipt, durability)
                    .await
            }
            Request::Rollback { transaction, .. } => self.rollback(request_id, transaction),
            Request::Flush { .. } | Request::Checkpoint { .. } => self.flush(request_id).await,
            Request::State {
                durability_barrier, ..
            } => self.state(request_id, durability_barrier).await,
            Request::Resolve { receipt, .. } => {
                if decode_exact::<16>(&receipt).is_err() {
                    unsupported(request_id, "receipt_id", None)
                } else {
                    unsupported(
                        request_id,
                        "outcome_resolution",
                        Some(json!({ "receipt": receipt })),
                    )
                }
            }
            Request::Crash { .. } => json!({
                "request_id": request_id,
                "outcome": "Unsupported",
                "reason": "crash_must_not_return"
            }),
        }
    }

    async fn preflight(
        &mut self,
        request_id: String,
        protocol: String,
        database_id: String,
        limits: WorkloadLimits,
        column_families: Vec<ColumnFamily>,
        required_capabilities: Vec<String>,
    ) -> Value {
        if self.db.is_some()
            || !self.transactions.is_empty()
            || !self.failed_transactions.is_empty()
            || !self.unresolved_transactions.is_empty()
            || self.unresolved_receipt_count() != 0
        {
            return unsupported(request_id, "preflight_after_engine_effect", None);
        }
        if protocol != ADAPTER_PROTOCOL {
            return unsupported(request_id, "protocol", None);
        }

        let database_id = match decode_exact::<16>(&database_id) {
            Ok(value) => value,
            Err(reason) => return unsupported(request_id, reason, None),
        };
        let expected_path = format!("flyology-db-{}", lowercase_hex(&database_id));
        if self.database_path.to_string() != expected_path {
            return unsupported(request_id, "database_identity_path", None);
        }
        if limits.transactions == 0
            || limits.transactions > self.limits.transactions
            || limits.mutations_per_transaction == 0
            || limits.mutations_per_transaction > self.limits.mutations_per_transaction
            || limits.key_bytes > self.limits.key_bytes
            || limits.value_bytes > self.limits.value_bytes
        {
            return unsupported(request_id, "declared_limits", None);
        }
        if column_families.len() != 1 || column_families[0].name != "default" {
            return unsupported(request_id, "column_families", None);
        }
        if column_families[0].id.is_empty()
            || column_families[0].id.len() > MAX_FAMILY_ID_BYTES
            || !column_families[0]
                .id
                .bytes()
                .all(|byte| byte.is_ascii_digit())
            || column_families[0].id.starts_with('0')
            || column_families[0].id.parse::<u32>().is_err()
        {
            return unsupported(request_id, "column_family_id", None);
        }

        let known: HashSet<&str> = KNOWN_CAPABILITIES.into_iter().collect();
        let supported: HashSet<&str> = LOCAL_CAPABILITIES.into_iter().collect();
        let mut seen = HashSet::new();
        let mut missing = Vec::new();
        for capability in &required_capabilities {
            if !known.contains(capability.as_str()) || !seen.insert(capability.as_str()) {
                return unsupported(request_id, "required_capabilities", None);
            }
            if !supported.contains(capability.as_str()) {
                missing.push(capability.clone());
            }
        }
        if !missing.is_empty() {
            return json!({
                "request_id": request_id,
                "outcome": "Unsupported",
                "reason": "required_capabilities",
                "unsupported_capabilities": missing,
                "supported_capabilities": LOCAL_CAPABILITIES,
                "engine": "SlateDB",
                "engine_commit": SLATEDB_COMMIT,
                "engine_version": SLATEDB_VERSION,
                "protocol": ADAPTER_PROTOCOL,
                "storage_profile": "local_filesystem_fsync"
            });
        }

        let contract = ActiveContract {
            database_id,
            family_id: column_families[0].id.clone(),
            limits,
        };
        if self
            .contract
            .as_ref()
            .is_some_and(|active| active != &contract)
        {
            return unsupported(request_id, "changed_preflight", None);
        }
        self.contract = Some(contract);
        json!({
            "request_id": request_id,
            "outcome": "Success",
            "supported_capabilities": LOCAL_CAPABILITIES,
            "engine": "SlateDB",
            "engine_commit": SLATEDB_COMMIT,
            "engine_version": SLATEDB_VERSION,
            "protocol": ADAPTER_PROTOCOL,
            "storage_profile": "local_filesystem_fsync",
            "receipt_capacity": self.limits.receipt_ids
        })
    }

    async fn create(&mut self, request_id: String) -> Value {
        if let Some(response) = self.require_contract(&request_id) {
            return response;
        }
        if self.db.is_some() {
            return outcome(request_id, "Conflict");
        }
        match self.database_exists().await {
            Ok(true) => outcome(request_id, "Conflict"),
            Ok(false) => self.open_unchecked(request_id).await,
            Err(_) => object_store_error(request_id),
        }
    }

    async fn open(&mut self, request_id: String, recovery: bool) -> Value {
        if let Some(response) = self.require_contract(&request_id) {
            return response;
        }
        if self.db.is_some() {
            return outcome(request_id, "Conflict");
        }
        match self.database_exists().await {
            Ok(false) => outcome(request_id, "Not_Found"),
            Ok(true) => {
                let mut response = self.open_unchecked(request_id).await;
                if response["outcome"] == "Success" {
                    response["recovery"] = json!(recovery);
                }
                response
            }
            Err(_) => object_store_error(request_id),
        }
    }

    async fn reopen(&mut self, request_id: String) -> Value {
        if let Some(response) = self.require_contract(&request_id) {
            return response;
        }
        if !self.transactions.is_empty()
            || !self.failed_transactions.is_empty()
            || !self.unresolved_transactions.is_empty()
            || self.unresolved_receipt_count() != 0
        {
            return outcome(request_id, "Conflict");
        }
        if let Some(db) = self.db.take() {
            if let Err(error) = db.close().await {
                return mapped_error(request_id, &error, false, Isolation::Snapshot);
            }
        }
        self.open(request_id, false).await
    }

    async fn open_unchecked(&mut self, request_id: String) -> Value {
        match Db::open(self.database_path.clone(), Arc::clone(&self.store)).await {
            Ok(db) => {
                self.db = Some(db);
                outcome(request_id, "Success")
            }
            Err(error) => mapped_error(request_id, &error, false, Isolation::Snapshot),
        }
    }

    async fn database_exists(&self) -> Result<bool, slatedb::object_store::Error> {
        let mut objects = self.store.list(Some(&self.database_path));
        match objects.next().await {
            Some(Ok(_)) => Ok(true),
            Some(Err(error)) => Err(error),
            None => Ok(false),
        }
    }

    async fn begin(
        &mut self,
        request_id: String,
        transaction: String,
        isolation: Isolation,
    ) -> Value {
        let db = match self.database(&request_id) {
            Ok(db) => db,
            Err(response) => return response,
        };
        let transaction_limit = self.contract.as_ref().unwrap().limits.transactions;
        if self.transactions.len()
            + self.failed_transactions.len()
            + self.unresolved_transactions.len()
            >= transaction_limit
            || self.transactions.contains_key(&transaction)
            || self.failed_transactions.contains(&transaction)
            || self.unresolved_transactions.contains(&transaction)
        {
            return outcome(request_id, "Conflict");
        }
        match db.begin(isolation.slatedb()).await {
            Ok(value) => {
                self.transactions.insert(
                    transaction,
                    HeldTransaction {
                        value,
                        isolation,
                        mutations: 0,
                    },
                );
                outcome(request_id, "Success")
            }
            Err(error) => mapped_error(request_id, &error, false, isolation),
        }
    }

    async fn get(
        &self,
        request_id: String,
        transaction: String,
        column_family_id: String,
        key: String,
    ) -> Value {
        let key = match self.decode_key(&request_id, &column_family_id, &key) {
            Ok(key) => key,
            Err(response) => return response,
        };
        let held = match self.transactions.get(&transaction) {
            Some(held) => held,
            None => return outcome(request_id, "Conflict"),
        };
        match held.value.get(key).await {
            Ok(Some(value)) => json!({
                "request_id": request_id,
                "outcome": "Success",
                "value": encode(value.as_ref())
            }),
            Ok(None) => outcome(request_id, "Not_Found"),
            Err(error) => mapped_error(request_id, &error, false, held.isolation),
        }
    }

    async fn put(
        &mut self,
        request_id: String,
        transaction: String,
        column_family_id: String,
        key: String,
        value: String,
    ) -> Value {
        let key = match self.decode_key(&request_id, &column_family_id, &key) {
            Ok(key) => key,
            Err(response) => return response,
        };
        let value = match decode_bounded(&value, self.contract.as_ref().unwrap().limits.value_bytes)
        {
            Ok(value) => value,
            Err(reason) => return unsupported(request_id, reason, None),
        };
        let mutation_limit = self
            .contract
            .as_ref()
            .unwrap()
            .limits
            .mutations_per_transaction;
        let held = match self.transactions.get_mut(&transaction) {
            Some(held) => held,
            None => return outcome(request_id, "Conflict"),
        };
        if held.mutations >= mutation_limit {
            return unsupported(request_id, "mutation_limit", None);
        }
        match held.value.put(key, value) {
            Ok(()) => {
                held.mutations += 1;
                outcome(request_id, "Success")
            }
            Err(error) => mapped_error(request_id, &error, false, held.isolation),
        }
    }

    async fn delete(
        &mut self,
        request_id: String,
        transaction: String,
        column_family_id: String,
        key: String,
    ) -> Value {
        let key = match self.decode_key(&request_id, &column_family_id, &key) {
            Ok(key) => key,
            Err(response) => return response,
        };
        let mutation_limit = self
            .contract
            .as_ref()
            .unwrap()
            .limits
            .mutations_per_transaction;
        let held = match self.transactions.get_mut(&transaction) {
            Some(held) => held,
            None => return outcome(request_id, "Conflict"),
        };
        if held.mutations >= mutation_limit {
            return unsupported(request_id, "mutation_limit", None);
        }
        match held.value.delete(key) {
            Ok(()) => {
                held.mutations += 1;
                outcome(request_id, "Success")
            }
            Err(error) => mapped_error(request_id, &error, false, held.isolation),
        }
    }

    async fn scan(
        &self,
        request_id: String,
        transaction: String,
        column_family_id: String,
        lower: String,
        upper: String,
        maximum_items: usize,
    ) -> Value {
        let lower = match self.decode_key(&request_id, &column_family_id, &lower) {
            Ok(key) => key,
            Err(response) => return response,
        };
        let upper = match decode_bounded(&upper, self.contract.as_ref().unwrap().limits.key_bytes) {
            Ok(key) => key,
            Err(reason) => return unsupported(request_id, reason, None),
        };
        if lower >= upper || maximum_items == 0 || maximum_items > self.limits.scan_items {
            return unsupported(request_id, "scan_bounds", None);
        }
        let held = match self.transactions.get(&transaction) {
            Some(held) => held,
            None => return outcome(request_id, "Conflict"),
        };
        let mut iterator = match held
            .value
            .scan((Bound::Included(lower), Bound::Excluded(upper)))
            .await
        {
            Ok(iterator) => iterator,
            Err(error) => return mapped_error(request_id, &error, false, held.isolation),
        };
        let mut items = Vec::new();
        let mut truncated = false;
        let mut projected_bytes = serialized_size(&json!({
            "request_id": &request_id,
            "outcome": "Success",
            "items": [],
            "truncated": false
        }));
        if projected_bytes > self.limits.scan_bytes {
            return unsupported(request_id, "scan_byte_limit", None);
        }
        loop {
            match iterator.next().await {
                Ok(Some(item)) if items.len() < maximum_items => {
                    let item_bytes = match projected_tuple_size(0, item.key.len(), item.value.len())
                    {
                        Some(bytes) => bytes,
                        None => return unsupported(request_id, "scan_byte_limit", None),
                    };
                    projected_bytes = match add_projected_item(
                        projected_bytes,
                        item_bytes,
                        !items.is_empty(),
                        self.limits.scan_bytes,
                    ) {
                        Some(bytes) => bytes,
                        None => return unsupported(request_id, "scan_byte_limit", None),
                    };
                    items.push(json!({
                        "key": encode(item.key.as_ref()),
                        "value": encode(item.value.as_ref())
                    }));
                }
                Ok(Some(_)) => {
                    truncated = true;
                    break;
                }
                Ok(None) => break,
                Err(error) => return mapped_error(request_id, &error, false, held.isolation),
            }
        }
        json!({
            "request_id": request_id,
            "outcome": "Success",
            "items": items,
            "truncated": truncated
        })
    }

    async fn commit(
        &mut self,
        request_id: String,
        transaction: String,
        receipt: Option<String>,
        durability: Durability,
    ) -> Value {
        let receipt = match receipt {
            Some(receipt) if decode_exact::<16>(&receipt).is_ok() => receipt,
            _ => return unsupported(request_id, "receipt_id", None),
        };
        if self.seen_receipts.contains_key(&receipt) {
            return unsupported(request_id, "receipt_reused", None);
        }
        if self.seen_receipts.len() >= self.limits.receipt_ids {
            return unsupported(request_id, "receipt_capacity", None);
        }
        if durability == Durability::Remote {
            return unsupported(request_id, "remote_durable", None);
        }
        let held = match self.transactions.remove(&transaction) {
            Some(held) => held,
            None => return outcome(request_id, "Conflict"),
        };
        match held.value.commit().await {
            Ok(Some(handle)) => {
                #[cfg(test)]
                if std::mem::take(&mut self.inject_durability_data_failure_once) {
                    drop(handle);
                    return self.commit_failure(
                        transaction,
                        receipt,
                        mapped_error_kind(request_id, &ErrorKind::Data, true, held.isolation),
                    );
                }

                match handle.await_durable().await {
                    Ok(()) => self.commit_success(request_id, receipt, durability),
                    Err(error) => self.commit_failure(
                        transaction,
                        receipt,
                        mapped_error(request_id, &error, true, held.isolation),
                    ),
                }
            }
            Ok(None) => self.commit_success(request_id, receipt, durability),
            Err(error) => self.commit_failure(
                transaction,
                receipt,
                mapped_error(request_id, &error, true, held.isolation),
            ),
        }
    }

    fn commit_success(
        &mut self,
        request_id: String,
        receipt: String,
        durability: Durability,
    ) -> Value {
        assert!(self
            .seen_receipts
            .insert(receipt.clone(), ReceiptPhase::Success)
            .is_none());
        success_with_receipt(request_id, receipt, durability)
    }

    fn commit_failure(&mut self, transaction: String, receipt: String, response: Value) -> Value {
        let (response, definite) = consumed_commit_failure(response, &receipt);
        if definite {
            self.failed_transactions.insert(transaction);
        } else {
            self.unresolved_transactions.insert(transaction);
            assert!(self
                .seen_receipts
                .insert(receipt, ReceiptPhase::OutcomeUnknown)
                .is_none());
        }
        response
    }

    fn unresolved_receipt_count(&self) -> usize {
        self.seen_receipts
            .values()
            .filter(|phase| **phase == ReceiptPhase::OutcomeUnknown)
            .count()
    }

    fn rollback(&mut self, request_id: String, transaction: String) -> Value {
        match self.transactions.remove(&transaction) {
            Some(held) => {
                held.value.rollback();
                outcome(request_id, "Success")
            }
            None if self.failed_transactions.remove(&transaction) => {
                // SlateDB consumes the engine transaction before returning a
                // definite commit failure. The contract keeps its logical ID
                // live so the caller can explicitly release it with rollback.
                outcome(request_id, "Success")
            }
            None => outcome(request_id, "Conflict"),
        }
    }

    async fn flush(&self, request_id: String) -> Value {
        let db = match self.database(&request_id) {
            Ok(db) => db,
            Err(response) => return response,
        };
        match db.flush().await {
            Ok(()) => outcome(request_id, "Success"),
            Err(error) => mapped_error(request_id, &error, true, Isolation::Snapshot),
        }
    }

    async fn state(&self, request_id: String, durability_barrier: bool) -> Value {
        let db = match self.database(&request_id) {
            Ok(db) => db,
            Err(response) => return response,
        };
        if durability_barrier {
            if let Err(error) = db.flush().await {
                return mapped_error(request_id, &error, true, Isolation::Snapshot);
            }
        }
        let mut iterator = match db.scan::<std::ops::RangeFull>(..).await {
            Ok(iterator) => iterator,
            Err(error) => return mapped_error(request_id, &error, false, Isolation::Snapshot),
        };
        let family_id = self.contract.as_ref().unwrap().family_id.clone();
        let mut tuples = Vec::new();
        let mut projected_bytes = serialized_size(&json!({
            "request_id": &request_id,
            "outcome": "Success",
            "digest": "0000000000000000000000000000000000000000000000000000000000000000",
            "tuples": [],
            "durability_barrier": durability_barrier
        }));
        if projected_bytes > self.limits.state_bytes {
            return unsupported(request_id, "state_byte_limit", None);
        }
        loop {
            match iterator.next().await {
                Ok(Some(item)) => {
                    let item_bytes = match projected_tuple_size(
                        family_id.len(),
                        item.key.len(),
                        item.value.len(),
                    ) {
                        Some(bytes) => bytes,
                        None => return unsupported(request_id, "state_byte_limit", None),
                    };
                    projected_bytes = match add_projected_item(
                        projected_bytes,
                        item_bytes,
                        !tuples.is_empty(),
                        self.limits.state_bytes,
                    ) {
                        Some(bytes) => bytes,
                        None => return unsupported(request_id, "state_byte_limit", None),
                    };
                    if tuples.len() >= self.limits.state_items {
                        return unsupported(request_id, "state_item_limit", None);
                    }
                    tuples.push(LogicalTuple {
                        family_id: family_id.clone(),
                        key: item.key.to_vec(),
                        value: item.value.to_vec(),
                    });
                }
                Ok(None) => break,
                Err(error) => return mapped_error(request_id, &error, false, Isolation::Snapshot),
            }
        }
        let digest = canonical_digest(&tuples);
        let tuples: Vec<Value> = tuples
            .into_iter()
            .map(|item| {
                json!({
                    "column_family_id": item.family_id,
                    "key": encode(&item.key),
                    "value": encode(&item.value)
                })
            })
            .collect();
        json!({
            "request_id": request_id,
            "outcome": "Success",
            "digest": digest,
            "tuples": tuples,
            "durability_barrier": durability_barrier
        })
    }

    pub async fn shutdown(&mut self) -> Result<(), String> {
        if !self.unresolved_transactions.is_empty() || self.unresolved_receipt_count() != 0 {
            return Err("unresolved commit prevents clean shutdown".to_owned());
        }
        self.transactions.clear();
        self.failed_transactions.clear();
        if let Some(db) = self.db.take() {
            db.close()
                .await
                .map_err(|_| "SlateDB clean shutdown failed".to_owned())?;
        }
        Ok(())
    }

    fn require_contract(&self, request_id: &str) -> Option<Value> {
        if self.contract.is_none() {
            Some(unsupported(
                request_id.to_owned(),
                "preflight_required",
                None,
            ))
        } else {
            None
        }
    }

    fn database(&self, request_id: &str) -> Result<&Db, Value> {
        if let Some(response) = self.require_contract(request_id) {
            return Err(response);
        }
        self.db
            .as_ref()
            .ok_or_else(|| outcome(request_id.to_owned(), "Not_Found"))
    }

    fn decode_key(
        &self,
        request_id: &str,
        column_family_id: &str,
        key: &str,
    ) -> Result<Vec<u8>, Value> {
        let contract = match &self.contract {
            Some(contract) => contract,
            None => {
                return Err(unsupported(
                    request_id.to_owned(),
                    "preflight_required",
                    None,
                ))
            }
        };
        if column_family_id != contract.family_id {
            return Err(unsupported(request_id.to_owned(), "column_family_id", None));
        }
        decode_bounded(key, contract.limits.key_bytes)
            .map_err(|reason| unsupported(request_id.to_owned(), reason, None))
    }
}

#[derive(Debug, PartialEq, Eq)]
struct LogicalTuple {
    family_id: String,
    key: Vec<u8>,
    value: Vec<u8>,
}

fn canonical_digest(tuples: &[LogicalTuple]) -> String {
    let mut digest = Sha256::new();
    digest.update(b"flyology.db.oracle.state.v1\0");
    for tuple in tuples {
        update_length_prefixed(&mut digest, tuple.family_id.as_bytes());
        update_length_prefixed(&mut digest, &tuple.key);
        update_length_prefixed(&mut digest, &tuple.value);
    }
    let bytes = digest.finalize();
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn update_length_prefixed(digest: &mut Sha256, bytes: &[u8]) {
    digest.update((bytes.len() as u64).to_be_bytes());
    digest.update(bytes);
}

pub fn parse_request(line: &str) -> Result<Request, Value> {
    match serde_json::from_str::<Request>(line) {
        Ok(request)
            if !request.request_id().is_empty()
                && request.request_id().len() <= MAX_REQUEST_ID_BYTES =>
        {
            Ok(request)
        }
        Ok(request) => Err(unsupported(
            bounded_request_id(request.request_id()),
            "request_id",
            None,
        )),
        Err(_) => {
            let request_id = serde_json::from_str::<Value>(line)
                .ok()
                .and_then(|value| {
                    value
                        .get("request_id")
                        .and_then(Value::as_str)
                        .map(bounded_request_id)
                })
                .unwrap_or_default();
            Err(unsupported(request_id, "invalid_request", None))
        }
    }
}

fn bounded_request_id(value: &str) -> String {
    if value.len() <= MAX_REQUEST_ID_BYTES {
        value.to_owned()
    } else {
        String::new()
    }
}

fn encode(bytes: &[u8]) -> String {
    BASE64.encode(bytes)
}

fn serialized_size(value: &Value) -> usize {
    serde_json::to_vec(value).map_or(usize::MAX, |bytes| bytes.len())
}

fn base64_size(bytes: usize) -> Option<usize> {
    bytes.checked_add(2)?.checked_div(3)?.checked_mul(4)
}

fn projected_tuple_size(
    family_bytes: usize,
    key_bytes: usize,
    value_bytes: usize,
) -> Option<usize> {
    let overhead = if family_bytes == 0 {
        br#"{"key":"","value":""}"#.len()
    } else {
        br#"{"column_family_id":"","key":"","value":""}"#.len()
    };
    overhead
        .checked_add(family_bytes)?
        .checked_add(base64_size(key_bytes)?)?
        .checked_add(base64_size(value_bytes)?)
}

fn add_projected_item(
    current: usize,
    item: usize,
    needs_comma: bool,
    maximum: usize,
) -> Option<usize> {
    let total = current
        .checked_add(usize::from(needs_comma))?
        .checked_add(item)?;
    (total <= maximum).then_some(total)
}

fn lowercase_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn decode_bounded(value: &str, maximum: usize) -> Result<Vec<u8>, &'static str> {
    let bytes = BASE64.decode(value).map_err(|_| "binary_base64")?;
    if BASE64.encode(&bytes) != value {
        return Err("binary_base64");
    }
    if bytes.len() > maximum {
        return Err("binary_length");
    }
    Ok(bytes)
}

fn decode_exact<const N: usize>(value: &str) -> Result<[u8; N], &'static str> {
    let bytes = decode_bounded(value, N)?;
    bytes.try_into().map_err(|_| "identifier_length")
}

fn outcome(request_id: String, normalized: &'static str) -> Value {
    json!({ "request_id": request_id, "outcome": normalized })
}

fn success_with_receipt(request_id: String, receipt: String, durability: Durability) -> Value {
    let mut response = outcome(request_id, "Success");
    response["durability"] = json!(match durability {
        Durability::Remote => "remote",
        Durability::LocalComparative => "local_comparative",
    });
    response["receipt"] = json!(receipt);
    response
}

fn consumed_commit_failure(mut response: Value, receipt: &str) -> (Value, bool) {
    let unknown = response["outcome"] == "Outcome_Unknown";
    if unknown {
        response["receipt"] = json!(receipt);
    }
    (response, !unknown)
}

fn unsupported(request_id: String, reason: &'static str, extra: Option<Value>) -> Value {
    let mut value = json!({
        "request_id": request_id,
        "outcome": "Unsupported",
        "reason": reason
    });
    if let Some(extra) = extra {
        value["detail"] = extra;
    }
    value
}

fn mapped_error(
    request_id: String,
    error: &slatedb::Error,
    admitted_mutation: bool,
    isolation: Isolation,
) -> Value {
    mapped_error_kind(request_id, &error.kind(), admitted_mutation, isolation)
}

fn mapped_error_kind(
    request_id: String,
    error: &ErrorKind,
    admitted_mutation: bool,
    isolation: Isolation,
) -> Value {
    let (normalized, kind) = match error {
        ErrorKind::Transaction => (
            if isolation == Isolation::Serializable {
                "Serialization_Failure"
            } else {
                "Conflict"
            },
            "Transaction",
        ),
        ErrorKind::Data if admitted_mutation => ("Outcome_Unknown", "Data"),
        ErrorKind::Data => ("Corrupt", "Data"),
        ErrorKind::Unavailable if admitted_mutation => ("Outcome_Unknown", "Unavailable"),
        ErrorKind::Closed(_) if admitted_mutation => ("Outcome_Unknown", "Closed"),
        ErrorKind::Internal if admitted_mutation => ("Outcome_Unknown", "Internal"),
        ErrorKind::Unavailable => ("Unsupported", "Unavailable"),
        ErrorKind::Closed(_) => ("Unsupported", "Closed"),
        ErrorKind::Invalid => ("Unsupported", "Invalid"),
        ErrorKind::Internal => ("Unsupported", "Internal"),
        _ => ("Unsupported", "Unknown"),
    };
    json!({
        "request_id": request_id,
        "outcome": normalized,
        "engine_error_kind": kind
    })
}

fn object_store_error(request_id: String) -> Value {
    json!({
        "request_id": request_id,
        "outcome": "Unsupported",
        "engine_error_kind": "ObjectStore"
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use slatedb::object_store::memory::InMemory;

    #[test]
    fn digest_consumes_shared_golden_vectors() {
        let vectors: Value = serde_json::from_str(include_str!(
            "../../../contract/canonical_state_vectors.json"
        ))
        .unwrap();
        for vector in vectors["vectors"].as_array().unwrap() {
            let tuples = vector["tuples"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| LogicalTuple {
                    family_id: item["column_family_id"].as_str().unwrap().to_owned(),
                    key: test_hex(item["key"].as_str().unwrap()),
                    value: test_hex(item["value"].as_str().unwrap()),
                })
                .collect::<Vec<_>>();
            assert_eq!(
                canonical_digest(&tuples),
                vector["sha256"].as_str().unwrap(),
                "{}",
                vector["name"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn digest_is_order_sensitive() {
        let tuples = vec![
            LogicalTuple {
                family_id: "1".to_owned(),
                key: b"a".to_vec(),
                value: b"one".to_vec(),
            },
            LogicalTuple {
                family_id: "1".to_owned(),
                key: vec![0, 255],
                value: Vec::new(),
            },
        ];
        let original = canonical_digest(&tuples);
        let mut reversed = tuples;
        reversed.reverse();
        assert_ne!(canonical_digest(&reversed), original);
    }

    #[test]
    fn base64_is_canonical_and_bounded() {
        assert_eq!(decode_bounded("AP8=", 2).unwrap(), vec![0, 255]);
        assert!(decode_bounded("AP8", 2).is_err());
        assert!(decode_bounded("AP8=", 1).is_err());
    }

    #[test]
    fn projected_tuple_bound_matches_json_and_rejects_aggregate_overflow() {
        let key = vec![0, 255, 1];
        let value = b"value".to_vec();
        let scan = json!({"key": encode(&key), "value": encode(&value)});
        let state = json!({
            "column_family_id": "4294967295",
            "key": encode(&key),
            "value": encode(&value)
        });
        assert_eq!(
            projected_tuple_size(0, key.len(), value.len()),
            Some(serialized_size(&scan))
        );
        assert_eq!(
            projected_tuple_size(10, key.len(), value.len()),
            Some(serialized_size(&state))
        );
        let scan_base = serialized_size(&json!({
            "request_id": "r",
            "outcome": "Success",
            "items": [],
            "truncated": false
        }));
        let scan_total =
            add_projected_item(scan_base, serialized_size(&scan), false, usize::MAX).unwrap();
        assert_eq!(
            scan_total,
            serialized_size(&json!({
                "request_id": "r",
                "outcome": "Success",
                "items": [scan.clone()],
                "truncated": false
            }))
        );
        let state_base = serialized_size(&json!({
            "request_id": "r",
            "outcome": "Success",
            "digest": "0000000000000000000000000000000000000000000000000000000000000000",
            "tuples": [],
            "durability_barrier": false
        }));
        let state_total =
            add_projected_item(state_base, serialized_size(&state), false, usize::MAX).unwrap();
        assert_eq!(
            state_total,
            serialized_size(&json!({
                "request_id": "r",
                "outcome": "Success",
                "digest": "0000000000000000000000000000000000000000000000000000000000000000",
                "tuples": [state.clone()],
                "durability_barrier": false
            }))
        );
        let item = serialized_size(&state);
        assert_eq!(add_projected_item(100, item, true, 100 + item), None);
        assert_eq!(
            add_projected_item(100, item, true, 101 + item),
            Some(101 + item)
        );
    }

    #[test]
    fn consumed_commit_failure_preserves_unknown_receipt_and_marks_definite_failure() {
        let receipt = encode(&[7; 16]);
        let (unknown, definite) = consumed_commit_failure(
            json!({"request_id": "unknown", "outcome": "Outcome_Unknown"}),
            &receipt,
        );
        assert!(!definite);
        assert_eq!(unknown["receipt"], receipt);

        let (corrupt, definite) = consumed_commit_failure(
            json!({"request_id": "corrupt", "outcome": "Corrupt"}),
            &receipt,
        );
        assert!(definite);
        assert!(corrupt.get("receipt").is_none());
    }

    #[tokio::test]
    async fn injected_post_application_data_is_unknown_and_receipt_bound() {
        let store: Arc<dyn ObjectStore> = Arc::new(InMemory::new());
        let database_id = [3_u8; 16];
        let database_path =
            Path::parse(format!("flyology-db-{}", lowercase_hex(&database_id))).unwrap();
        let mut adapter = Adapter::new(store, database_path, AdapterLimits::default());
        let response = adapter
            .execute(Request::Preflight {
                request_id: "preflight".to_owned(),
                protocol: ADAPTER_PROTOCOL.to_owned(),
                database_id: encode(&database_id),
                limits: WorkloadLimits {
                    transactions: 2,
                    mutations_per_transaction: 1,
                    key_bytes: 8,
                    value_bytes: 8,
                },
                column_families: vec![ColumnFamily {
                    id: "1".to_owned(),
                    name: "default".to_owned(),
                }],
                required_capabilities: vec!["snapshot".to_owned()],
            })
            .await;
        assert_eq!(response["outcome"], "Success");
        assert_eq!(
            adapter
                .execute(Request::Create {
                    request_id: "create".to_owned(),
                })
                .await["outcome"],
            "Success"
        );

        let transaction = encode(&[4_u8; 16]);
        let receipt = encode(&[5_u8; 16]);
        assert_eq!(
            adapter
                .execute(Request::Begin {
                    request_id: "begin".to_owned(),
                    transaction: transaction.clone(),
                    isolation: Isolation::Snapshot,
                })
                .await["outcome"],
            "Success"
        );
        assert_eq!(
            adapter
                .execute(Request::Put {
                    request_id: "put".to_owned(),
                    transaction: transaction.clone(),
                    column_family_id: "1".to_owned(),
                    key: encode(b"key"),
                    value: encode(b"value"),
                })
                .await["outcome"],
            "Success"
        );
        adapter.inject_durability_data_failure_once = true;
        let response = adapter
            .execute(Request::Commit {
                request_id: "commit".to_owned(),
                transaction: transaction.clone(),
                receipt: Some(receipt.clone()),
                durability: Durability::LocalComparative,
            })
            .await;
        assert_eq!(response["outcome"], "Outcome_Unknown");
        assert_eq!(response["engine_error_kind"], "Data");
        assert_eq!(response["receipt"], receipt);
        assert!(adapter.unresolved_transactions.contains(&transaction));
        assert_eq!(
            adapter.seen_receipts.get(&receipt),
            Some(&ReceiptPhase::OutcomeUnknown)
        );
        assert_eq!(adapter.unresolved_transactions.len(), 1);
        assert_eq!(adapter.seen_receipts.len(), 1);
        assert_eq!(adapter.unresolved_receipt_count(), 1);
        assert_eq!(
            adapter
                .execute(Request::Begin {
                    request_id: "replay-begin".to_owned(),
                    transaction: transaction.clone(),
                    isolation: Isolation::Snapshot,
                })
                .await["outcome"],
            "Conflict"
        );
        assert_eq!(
            adapter
                .execute(Request::Rollback {
                    request_id: "rollback".to_owned(),
                    transaction,
                })
                .await["outcome"],
            "Conflict"
        );
        assert_eq!(
            adapter
                .execute(Request::Reopen {
                    request_id: "reopen".to_owned(),
                })
                .await["outcome"],
            "Conflict"
        );
        assert_eq!(
            adapter
                .execute(Request::Resolve {
                    request_id: "resolve".to_owned(),
                    receipt: receipt.clone(),
                })
                .await["reason"],
            "outcome_resolution"
        );

        let second_transaction = encode(&[6_u8; 16]);
        assert_eq!(
            adapter
                .execute(Request::Begin {
                    request_id: "second-begin".to_owned(),
                    transaction: second_transaction.clone(),
                    isolation: Isolation::Snapshot,
                })
                .await["outcome"],
            "Success"
        );
        assert_eq!(
            adapter
                .execute(Request::Begin {
                    request_id: "capacity-begin".to_owned(),
                    transaction: encode(&[7_u8; 16]),
                    isolation: Isolation::Snapshot,
                })
                .await["outcome"],
            "Conflict"
        );
        assert_eq!(
            adapter
                .execute(Request::Put {
                    request_id: "second-put".to_owned(),
                    transaction: second_transaction.clone(),
                    column_family_id: "1".to_owned(),
                    key: encode(b"other"),
                    value: encode(b"hidden"),
                })
                .await["outcome"],
            "Success"
        );
        let reused_receipt = adapter
            .execute(Request::Commit {
                request_id: "receipt-reuse".to_owned(),
                transaction: second_transaction.clone(),
                receipt: Some(receipt.clone()),
                durability: Durability::LocalComparative,
            })
            .await;
        assert_eq!(reused_receipt["outcome"], "Unsupported");
        assert_eq!(reused_receipt["reason"], "receipt_reused");
        assert_eq!(
            adapter
                .execute(Request::Rollback {
                    request_id: "second-rollback".to_owned(),
                    transaction: second_transaction,
                })
                .await["outcome"],
            "Success"
        );
        let state = adapter
            .execute(Request::State {
                request_id: "state".to_owned(),
                durability_barrier: false,
            })
            .await;
        assert_eq!(state["outcome"], "Success");
        assert_eq!(
            state["tuples"],
            json!([{
                "column_family_id": "1",
                "key": encode(b"key"),
                "value": encode(b"value")
            }])
        );
        assert_eq!(
            mapped_error_kind(
                "pre-admission".to_owned(),
                &ErrorKind::Data,
                false,
                Isolation::Snapshot,
            )["outcome"],
            "Corrupt"
        );
        assert_eq!(
            adapter.shutdown().await.unwrap_err(),
            "unresolved commit prevents clean shutdown"
        );
    }

    #[test]
    fn configured_projection_bounds_cannot_exceed_hard_limits() {
        let limits = AdapterLimits {
            receipt_ids: usize::MAX,
            scan_bytes: usize::MAX,
            state_bytes: usize::MAX,
            ..AdapterLimits::default()
        }
        .bounded();
        assert_eq!(limits.scan_bytes, AdapterLimits::default().scan_bytes);
        assert_eq!(limits.state_bytes, AdapterLimits::default().state_bytes);
        assert_eq!(limits.receipt_ids, AdapterLimits::default().receipt_ids);
    }

    fn test_hex(value: &str) -> Vec<u8> {
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect()
    }

    #[test]
    fn parser_preserves_request_id_on_rejection() {
        let response =
            parse_request(r#"{"request_id":"alpha","operation":"put","unexpected":true}"#)
                .unwrap_err();
        assert_eq!(response["request_id"], "alpha");
        assert_eq!(response["outcome"], "Unsupported");

        let oversized = format!(
            r#"{{"request_id":"{}","operation":"create"}}"#,
            "x".repeat(MAX_REQUEST_ID_BYTES + 1)
        );
        let response = parse_request(&oversized).unwrap_err();
        assert_eq!(response["request_id"], "");
        assert_eq!(response["reason"], "request_id");
    }
}
