use serde::{Deserialize, Serialize};

use crate::id::Id;
use crate::ops::Op;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    User,
    Agent,
    Import,
    Undo,
    Sync,
}

impl Origin {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Agent => "agent",
            Self::Import => "import",
            Self::Undo => "undo",
            Self::Sync => "sync",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "user" => Some(Self::User),
            "agent" => Some(Self::Agent),
            "import" => Some(Self::Import),
            "undo" => Some(Self::Undo),
            "sync" => Some(Self::Sync),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxMeta {
    pub origin: Origin,
    pub actor: String,
    pub session: Option<String>,
    pub summary: String,
}

impl TxMeta {
    pub fn new(origin: Origin, actor: impl Into<String>, summary: impl Into<String>) -> Self {
        Self {
            origin,
            actor: actor.into(),
            session: None,
            summary: summary.into(),
        }
    }

    pub fn with_session(mut self, session: impl Into<String>) -> Self {
        self.session = Some(session.into());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Page {
    pub id: Id,
    pub title: String,
    pub title_lower: String,
    pub journal_day: Option<i32>,
    pub document_mode: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub created_by: String,
    pub updated_by: String,
    pub deleted_at: Option<i64>,
    pub version: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub id: Id,
    pub page_id: Id,
    pub parent_id: Option<Id>,
    pub order_key: String,
    pub content: String,
    pub collapsed: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub created_by: String,
    pub updated_by: String,
    pub deleted_at: Option<i64>,
    pub version: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxnRecord {
    pub id: Id,
    pub ts: i64,
    pub origin: Origin,
    pub actor: String,
    pub session: Option<String>,
    pub summary: String,
    pub undoes: Option<Id>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpRecord {
    pub txn_id: Id,
    pub seq: i64,
    pub forward: Op,
    pub inverse: Vec<Op>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApplyResult {
    pub txn_id: Option<Id>,
    pub inverse_ops: Vec<Op>,
}
