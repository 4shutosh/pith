use serde::{Deserialize, Serialize};

use crate::id::Id;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Op {
    CreatePage {
        id: Id,
        title: String,
        journal_day: Option<i32>,
        document_mode: bool,
    },
    RenamePage {
        id: Id,
        title: String,
        expected_version: Option<i64>,
    },
    DeletePage {
        id: Id,
        expected_version: Option<i64>,
    },
    RestorePage {
        id: Id,
    },
    InsertBlock {
        id: Id,
        page_id: Id,
        parent_id: Option<Id>,
        order_key: String,
        content: String,
    },
    UpdateBlock {
        id: Id,
        content: String,
        expected_version: Option<i64>,
    },
    MoveBlock {
        id: Id,
        page_id: Id,
        parent_id: Option<Id>,
        order_key: String,
        expected_version: Option<i64>,
    },
    DeleteBlock {
        id: Id,
        expected_version: Option<i64>,
    },
    RestoreBlock {
        id: Id,
    },
    SetCollapsed {
        id: Id,
        collapsed: bool,
    },
    SetPageFavorite {
        id: Id,
        favorite: bool,
    },
}

impl Op {
    pub fn is_view_state(&self) -> bool {
        matches!(
            self,
            Self::SetCollapsed { .. } | Self::SetPageFavorite { .. }
        )
    }
}
