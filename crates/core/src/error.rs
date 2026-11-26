use std::fmt;

use crate::id::Id;
use crate::types::Origin;

#[derive(Debug)]
pub enum Error {
    Sqlite(rusqlite::Error),
    Json(serde_json::Error),
    NotFound(Id),
    NotFoundRef(String),
    AmbiguousId {
        suffix: String,
        matches: Vec<Id>,
    },
    InvalidDate(String),
    EmptyInput,
    MissingExpectedVersion,
    NotASibling {
        id: Id,
    },
    DeletedEntity(Id),
    AlreadyExists(Id),
    PageTitleExists {
        id: Id,
        title: String,
    },
    JournalDayExists {
        id: Id,
        journal_day: i32,
    },
    VersionMismatch {
        id: Id,
        expected: i64,
        actual: i64,
    },
    CycleDetected(Id),
    ParentPageMismatch {
        parent_id: Id,
        page_id: Id,
    },
    BlocksOnDifferentPages {
        block_id: Id,
        page_id: Id,
    },
    TxnNotFound(Id),
    AlreadyUndone(Id),
    ReservedOrigin(Origin),
    UndoConflict {
        txn_id: Id,
        entity_id: Id,
        reason: String,
    },
    InvalidOrderBounds {
        lower: Option<String>,
        upper: Option<String>,
    },
    InvalidOrderChar(char),
    InvariantViolation(String),
}

impl Error {
    pub fn describe(&self, show_id: &dyn Fn(Id) -> String) -> String {
        match self {
            Self::Sqlite(err) => format!("sqlite error: {err}"),
            Self::Json(err) => format!("serialization error: {err}"),
            Self::NotFound(id) => format!("entity not found: {}", show_id(*id)),
            Self::NotFoundRef(input) => format!("entity not found: {input}"),
            Self::AmbiguousId { suffix, matches } => {
                let ids: Vec<String> = matches.iter().map(|id| show_id(*id)).collect();
                format!("ambiguous id suffix '{suffix}': matches {}", ids.join(", "))
            }
            Self::InvalidDate(raw) => format!("invalid date '{raw}': expected YYYY-MM-DD"),
            Self::EmptyInput => "empty markdown input".to_string(),
            Self::MissingExpectedVersion => "agent writes require expected_version".to_string(),
            Self::NotASibling { id } => {
                format!(
                    "block {} is not a sibling under the target parent",
                    show_id(*id)
                )
            }
            Self::DeletedEntity(id) => format!("entity is deleted: {}", show_id(*id)),
            Self::AlreadyExists(id) => format!("entity already exists: {}", show_id(*id)),
            Self::PageTitleExists { id, title } => {
                format!("page title already exists for {}: {title}", show_id(*id))
            }
            Self::JournalDayExists { id, journal_day } => {
                format!(
                    "journal day {journal_day} already exists for {}",
                    show_id(*id)
                )
            }
            Self::VersionMismatch {
                id,
                expected,
                actual,
            } => format!(
                "version mismatch for {}: expected {expected}, actual {actual}",
                show_id(*id)
            ),
            Self::CycleDetected(id) => {
                format!("move would create a cycle for block {}", show_id(*id))
            }
            Self::BlocksOnDifferentPages { block_id, page_id } => {
                format!("block {block_id} is not on page {page_id} like the rest of the selection")
            }
            Self::ParentPageMismatch { parent_id, page_id } => format!(
                "parent {} does not belong to page {}",
                show_id(*parent_id),
                show_id(*page_id)
            ),
            Self::TxnNotFound(id) => format!("transaction not found: {}", show_id(*id)),
            Self::AlreadyUndone(id) => format!("transaction already undone: {}", show_id(*id)),
            Self::ReservedOrigin(origin) => {
                format!("origin {} is reserved for Store::undo", origin.as_str())
            }
            Self::UndoConflict {
                txn_id,
                entity_id,
                reason,
            } => format!(
                "undo conflict on txn {} for entity {}: {reason}",
                show_id(*txn_id),
                show_id(*entity_id)
            ),
            Self::InvalidOrderBounds { lower, upper } => {
                format!("invalid order key bounds: lower={lower:?}, upper={upper:?}")
            }
            Self::InvalidOrderChar(c) => format!("invalid order key character: {c}"),
            Self::InvariantViolation(detail) => format!("invariant violation: {detail}"),
        }
    }

    pub fn code(&self) -> &'static str {
        match self {
            Self::Sqlite(_) => "sqlite_error",
            Self::Json(_) => "json_error",
            Self::NotFound(_) | Self::NotFoundRef(_) => "not_found",
            Self::AmbiguousId { .. } => "ambiguous_id",
            Self::InvalidDate(_) => "invalid_date",
            Self::EmptyInput => "empty_input",
            Self::MissingExpectedVersion => "missing_expected_version",
            Self::NotASibling { .. } => "not_a_sibling",
            Self::DeletedEntity(_) => "deleted_entity",
            Self::AlreadyExists(_) => "already_exists",
            Self::PageTitleExists { .. } => "page_title_exists",
            Self::JournalDayExists { .. } => "journal_day_exists",
            Self::VersionMismatch { .. } => "version_mismatch",
            Self::CycleDetected(_) => "cycle_detected",
            Self::ParentPageMismatch { .. } => "parent_page_mismatch",
            Self::BlocksOnDifferentPages { .. } => "blocks_on_different_pages",
            Self::TxnNotFound(_) => "txn_not_found",
            Self::AlreadyUndone(_) => "already_undone",
            Self::ReservedOrigin(_) => "reserved_origin",
            Self::UndoConflict { .. } => "undo_conflict",
            Self::InvalidOrderBounds { .. } | Self::InvalidOrderChar(_) => "invalid_order_key",
            Self::InvariantViolation(_) => "invariant_violation",
        }
    }

    pub fn hint(&self) -> Option<&'static str> {
        match self {
            Self::NotFound(_) | Self::NotFoundRef(_) => {
                Some("check the id or page title with `pith search`")
            }
            Self::AmbiguousId { .. } => Some("provide more trailing hex characters of the id"),
            Self::InvalidDate(_) => Some("use YYYY-MM-DD, for example 2026-11-25"),
            Self::VersionMismatch { .. } => {
                Some("re-read the block with `pith show` to get its latest version")
            }
            Self::MissingExpectedVersion => {
                Some("pass --expected-version from `pith show` when writing as an agent")
            }
            Self::NotASibling { .. } => {
                Some("pass a block id that is a direct child of the target parent")
            }
            Self::UndoConflict { .. } => {
                Some("review with `pith history`, or pass --force to override")
            }
            Self::AlreadyUndone(_) => Some("undo the undo transaction if you want to redo"),
            _ => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.describe(&|id| id.to_string()))
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Sqlite(err) => Some(err),
            Self::Json(err) => Some(err),
            _ => None,
        }
    }
}

impl From<rusqlite::Error> for Error {
    fn from(err: rusqlite::Error) -> Self {
        Self::Sqlite(err)
    }
}

impl From<serde_json::Error> for Error {
    fn from(err: serde_json::Error) -> Self {
        Self::Json(err)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
