use std::sync::{Arc, Mutex};

use pith_core::api::resolve_journal_date;
use pith_core::{
    ApplyResult, Backlink, ChangeEntry, ChangeFeed, Error, FlatBlockRow, Id, Op, Origin, Page,
    PageWindow, SearchHit, Store, TxMeta, order,
};
use thiserror::Error;
use uuid::Uuid;

uniffi::setup_scaffolding!();

#[derive(Debug, Error, uniffi::Error)]
pub enum FfiError {
    #[error("invalid id: {0}")]
    InvalidId(String),

    #[error("lock poisoned")]
    LockPoisoned,

    #[error("{code}: {message}")]
    Core { code: String, message: String },
}

impl From<Error> for FfiError {
    fn from(err: Error) -> Self {
        Self::Core {
            code: err.code().to_string(),
            message: err.to_string(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiWriter {
    User,
    Agent,
}

impl From<FfiWriter> for Origin {
    fn from(writer: FfiWriter) -> Self {
        match writer {
            FfiWriter::User => Self::User,
            FfiWriter::Agent => Self::Agent,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiOrigin {
    User,
    Agent,
    Import,
    Undo,
    Sync,
}

impl From<Origin> for FfiOrigin {
    fn from(origin: Origin) -> Self {
        match origin {
            Origin::User => Self::User,
            Origin::Agent => Self::Agent,
            Origin::Import => Self::Import,
            Origin::Undo => Self::Undo,
            Origin::Sync => Self::Sync,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTxMeta {
    pub writer: FfiWriter,
    pub actor: String,
    pub session: Option<String>,
    pub summary: String,
}

impl From<FfiTxMeta> for TxMeta {
    fn from(meta: FfiTxMeta) -> Self {
        let mut out = TxMeta::new(meta.writer.into(), meta.actor, meta.summary);
        if let Some(session) = meta.session {
            out = out.with_session(session);
        }
        out
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPage {
    pub id: String,
    pub title: String,
    pub journal_day: Option<i32>,
    pub document_mode: bool,
    pub version: i64,
    pub updated_at: i64,
}

impl From<Page> for FfiPage {
    fn from(page: Page) -> Self {
        Self {
            id: page.id.to_string(),
            title: page.title,
            journal_day: page.journal_day,
            document_mode: page.document_mode,
            version: page.version,
            updated_at: page.updated_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiFlatBlockRow {
    pub id: String,
    pub page_id: String,
    pub parent_id: Option<String>,
    pub order_key: String,
    pub depth: u32,
    pub raw_content: String,
    pub rendered_content: String,
    pub collapsed: bool,
    pub has_children: bool,
    pub version: i64,
}

impl From<FlatBlockRow> for FfiFlatBlockRow {
    fn from(row: FlatBlockRow) -> Self {
        Self {
            id: row.id.to_string(),
            page_id: row.page_id.to_string(),
            parent_id: row.parent_id.map(|id| id.to_string()),
            order_key: row.order_key,
            depth: row.depth,
            raw_content: row.raw_content,
            rendered_content: row.rendered_content,
            collapsed: row.collapsed,
            has_children: row.has_children,
            version: row.version,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPageWindow {
    pub page: FfiPage,
    pub total_visible: u64,
    pub offset: u64,
    pub rows: Vec<FfiFlatBlockRow>,
}

impl From<PageWindow> for FfiPageWindow {
    fn from(window: PageWindow) -> Self {
        Self {
            page: window.page.into(),
            total_visible: window.total_visible,
            offset: window.offset,
            rows: window.rows.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiOp {
    CreatePage {
        id: String,
        title: String,
        journal_day: Option<i32>,
        document_mode: bool,
    },
    RenamePage {
        id: String,
        title: String,
        expected_version: Option<i64>,
    },
    DeletePage {
        id: String,
        expected_version: Option<i64>,
    },
    RestorePage {
        id: String,
    },
    InsertBlock {
        id: String,
        page_id: String,
        parent_id: Option<String>,
        order_key: String,
        content: String,
    },
    UpdateBlock {
        id: String,
        content: String,
        expected_version: Option<i64>,
    },
    MoveBlock {
        id: String,
        page_id: String,
        parent_id: Option<String>,
        order_key: String,
        expected_version: Option<i64>,
    },
    DeleteBlock {
        id: String,
        expected_version: Option<i64>,
    },
    RestoreBlock {
        id: String,
    },
    SetCollapsed {
        id: String,
        collapsed: bool,
    },
}

impl TryFrom<FfiOp> for Op {
    type Error = FfiError;

    fn try_from(op: FfiOp) -> Result<Self, Self::Error> {
        Ok(match op {
            FfiOp::CreatePage {
                id,
                title,
                journal_day,
                document_mode,
            } => Self::CreatePage {
                id: parse_id(&id)?,
                title,
                journal_day,
                document_mode,
            },
            FfiOp::RenamePage {
                id,
                title,
                expected_version,
            } => Self::RenamePage {
                id: parse_id(&id)?,
                title,
                expected_version,
            },
            FfiOp::DeletePage {
                id,
                expected_version,
            } => Self::DeletePage {
                id: parse_id(&id)?,
                expected_version,
            },
            FfiOp::RestorePage { id } => Self::RestorePage { id: parse_id(&id)? },
            FfiOp::InsertBlock {
                id,
                page_id,
                parent_id,
                order_key,
                content,
            } => Self::InsertBlock {
                id: parse_id(&id)?,
                page_id: parse_id(&page_id)?,
                parent_id: parent_id.as_deref().map(parse_id).transpose()?,
                order_key,
                content,
            },
            FfiOp::UpdateBlock {
                id,
                content,
                expected_version,
            } => Self::UpdateBlock {
                id: parse_id(&id)?,
                content,
                expected_version,
            },
            FfiOp::MoveBlock {
                id,
                page_id,
                parent_id,
                order_key,
                expected_version,
            } => Self::MoveBlock {
                id: parse_id(&id)?,
                page_id: parse_id(&page_id)?,
                parent_id: parent_id.as_deref().map(parse_id).transpose()?,
                order_key,
                expected_version,
            },
            FfiOp::DeleteBlock {
                id,
                expected_version,
            } => Self::DeleteBlock {
                id: parse_id(&id)?,
                expected_version,
            },
            FfiOp::RestoreBlock { id } => Self::RestoreBlock { id: parse_id(&id)? },
            FfiOp::SetCollapsed { id, collapsed } => Self::SetCollapsed {
                id: parse_id(&id)?,
                collapsed,
            },
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiApplyResult {
    pub txn_id: Option<String>,
    pub applied_count: u32,
}

impl From<ApplyResult> for FfiApplyResult {
    fn from(res: ApplyResult) -> Self {
        Self {
            txn_id: res.txn_id.map(|id| id.to_string()),
            applied_count: res.applied_ops.len() as u32,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FfiSearchHit {
    Page {
        page_id: String,
        title: String,
    },
    Block {
        block_id: String,
        page_id: String,
        page_title: String,
        rendered_content: String,
        rank: f64,
    },
}

impl From<SearchHit> for FfiSearchHit {
    fn from(hit: SearchHit) -> Self {
        match hit {
            SearchHit::Page { page_id, title } => Self::Page {
                page_id: page_id.to_string(),
                title,
            },
            SearchHit::Block {
                block_id,
                page_id,
                page_title,
                rendered_content,
                rank,
            } => Self::Block {
                block_id: block_id.to_string(),
                page_id: page_id.to_string(),
                page_title,
                rendered_content,
                rank,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBacklink {
    pub block_id: String,
    pub page_id: String,
    pub page_title: String,
    pub kind: String,
    pub rendered_content: String,
}

impl From<Backlink> for FfiBacklink {
    fn from(b: Backlink) -> Self {
        Self {
            block_id: b.block_id.to_string(),
            page_id: b.page_id.to_string(),
            page_title: b.page_title,
            kind: b.kind,
            rendered_content: b.rendered_content,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiChangeEntry {
    pub seq: i64,
    pub txn_id: String,
    pub ts: i64,
    pub origin: FfiOrigin,
    pub actor: String,
    pub summary: String,
    pub undoes: Option<String>,
    pub touched_ids: Vec<String>,
}

impl From<ChangeEntry> for FfiChangeEntry {
    fn from(entry: ChangeEntry) -> Self {
        Self {
            seq: entry.seq,
            txn_id: entry.txn_id.to_string(),
            ts: entry.ts,
            origin: entry.origin.into(),
            actor: entry.actor,
            summary: entry.summary,
            undoes: entry.undoes.map(|id| id.to_string()),
            touched_ids: entry
                .touched_ids
                .into_iter()
                .map(|id| id.to_string())
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiChangeFeed {
    pub data_version: i64,
    pub latest_seq: i64,
    pub entries: Vec<FfiChangeEntry>,
}

impl From<ChangeFeed> for FfiChangeFeed {
    fn from(feed: ChangeFeed) -> Self {
        Self {
            data_version: feed.data_version,
            latest_seq: feed.latest_seq,
            entries: feed.entries.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct PithGraph {
    store: Mutex<Store>,
}

#[uniffi::export]
impl PithGraph {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, FfiError> {
        let store = Store::open(path)?;
        Ok(Arc::new(Self {
            store: Mutex::new(store),
        }))
    }

    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<Arc<Self>, FfiError> {
        let store = Store::open_in_memory()?;
        Ok(Arc::new(Self {
            store: Mutex::new(store),
        }))
    }

    pub fn list_pages(&self) -> Result<Vec<FfiPage>, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .list_live_pages()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn get_page(&self, id: String) -> Result<Option<FfiPage>, FfiError> {
        let parsed = parse_id(&id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .get_page(parsed)?
            .filter(|p| p.deleted_at.is_none())
            .map(Into::into))
    }

    pub fn get_page_by_title(&self, title: String) -> Result<Option<FfiPage>, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.get_page_by_title(&title)?.map(Into::into))
    }

    pub fn get_or_create_journal(
        &self,
        date: Option<String>,
        actor: String,
    ) -> Result<FfiPage, FfiError> {
        let (journal_day, title) = resolve_journal_date(date.as_deref())?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        if let Some(page) = store.get_page_by_journal_day(journal_day)? {
            return Ok(page.into());
        }
        if let Some(page) = store.get_page_by_title(&title)? {
            return Ok(page.into());
        }
        let id = Id::new();
        let meta = TxMeta::new(Origin::User, actor, format!("create journal {title}"));
        store.apply_ops(
            &[Op::CreatePage {
                id,
                title,
                journal_day: Some(journal_day),
                document_mode: false,
            }],
            &meta,
        )?;
        let page = store.get_page(id)?.ok_or(Error::NotFound(id))?;
        Ok(page.into())
    }

    pub fn read_page_window(
        &self,
        page_id: String,
        offset: u64,
        limit: u64,
    ) -> Result<FfiPageWindow, FfiError> {
        let parsed = parse_id(&page_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.read_page_window(parsed, offset, limit)?.into())
    }

    pub fn apply_ops(&self, ops: Vec<FfiOp>, meta: FfiTxMeta) -> Result<FfiApplyResult, FfiError> {
        let core_ops: Vec<Op> = ops
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<_, _>>()?;
        let core_meta: TxMeta = meta.into();
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.apply_ops(&core_ops, &core_meta)?.into())
    }

    pub fn undo(
        &self,
        txn_id: String,
        actor: String,
        force: bool,
    ) -> Result<FfiApplyResult, FfiError> {
        let parsed = parse_id(&txn_id)?;
        let meta = TxMeta::new(Origin::User, actor, "undo");
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.undo(parsed, &meta, force)?.into())
    }

    pub fn undo_last(
        &self,
        actor: String,
        force: bool,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let meta = TxMeta::new(Origin::User, actor, "undo");
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.undo_last(&meta, force)?.map(Into::into))
    }

    pub fn redo_last(
        &self,
        actor: String,
        force: bool,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let meta = TxMeta::new(Origin::User, actor, "redo");
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.redo_last(&meta, force)?.map(Into::into))
    }

    pub fn search(&self, query: String, limit: u32) -> Result<Vec<FfiSearchHit>, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .search(&query, limit as usize)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn backlinks(&self, target_id: String) -> Result<Vec<FfiBacklink>, FfiError> {
        let parsed = parse_id(&target_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .backlinks(parsed)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn data_version(&self) -> Result<i64, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.data_version()?)
    }

    pub fn changes_since(&self, after_seq: i64, limit: u32) -> Result<FfiChangeFeed, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.changes_since(after_seq, limit as usize)?.into())
    }
}

#[uniffi::export]
pub fn new_id() -> String {
    Id::new().to_string()
}

#[uniffi::export]
pub fn order_key_between(lower: Option<String>, upper: Option<String>) -> Result<String, FfiError> {
    Ok(order::between(lower.as_deref(), upper.as_deref())?)
}

fn parse_id(raw: &str) -> Result<Id, FfiError> {
    let uuid = Uuid::parse_str(raw.trim()).map_err(|_| FfiError::InvalidId(raw.to_string()))?;
    Ok(Id::from_uuid(uuid))
}
