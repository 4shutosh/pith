use thiserror::Error;

use crate::id::Id;

#[derive(Debug, Error)]
pub enum Error {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("serialization error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("entity not found: {0}")]
    NotFound(Id),

    #[error("entity is deleted: {0}")]
    DeletedEntity(Id),

    #[error("entity already exists: {0}")]
    AlreadyExists(Id),

    #[error("page title already exists for {id}: {title}")]
    PageTitleExists { id: Id, title: String },

    #[error("journal day {journal_day} already exists for {id}")]
    JournalDayExists { id: Id, journal_day: i32 },

    #[error("version mismatch for {id}: expected {expected}, actual {actual}")]
    VersionMismatch { id: Id, expected: i64, actual: i64 },

    #[error("move would create a cycle for block {0}")]
    CycleDetected(Id),

    #[error("parent {parent_id} does not belong to page {page_id}")]
    ParentPageMismatch { parent_id: Id, page_id: Id },

    #[error("transaction not found: {0}")]
    TxnNotFound(Id),

    #[error("transaction already undone: {0}")]
    AlreadyUndone(Id),

    #[error("origin {0:?} is reserved for Store::undo")]
    ReservedOrigin(crate::types::Origin),

    #[error("undo conflict on txn {txn_id} for entity {entity_id}: {reason}")]
    UndoConflict {
        txn_id: Id,
        entity_id: Id,
        reason: String,
    },

    #[error("invalid order key bounds: lower={lower:?}, upper={upper:?}")]
    InvalidOrderBounds {
        lower: Option<String>,
        upper: Option<String>,
    },

    #[error("invalid order key character: {0}")]
    InvalidOrderChar(char),

    #[error("invariant violation: {0}")]
    InvariantViolation(String),
}

pub type Result<T> = std::result::Result<T, Error>;
