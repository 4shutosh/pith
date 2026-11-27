use std::sync::{Arc, Mutex};

use pith_core::display::{BlockDisplay, RunStyle};
use pith_core::journal::{local_time_of_day, resolve_journal_date, shift_journal_date};
use pith_core::parser::{
    self, CompletionContext, CompletionKind, HighlightKind, InlineFormat, SlashClock, SlashCommand,
    highlight_ranges,
};
use pith_core::snippet::Segment;
use pith_core::{
    ApplyResult, Backlink, BlockKind, BlockLocation, BlockProp, ChangeCursor, ChangeEntry,
    ChangeFeed, EditOutcome, Error, FlatBlockRow, GraphChanges, Id, LinkPreview, Op, Origin, Page,
    PageMatch, PageSummary, PageWindow, PreviewLine, RenderedSpan, SearchHit, Store, TxMeta,
    UnlinkedRef, order,
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
    pub undo_group: Option<String>,
}

impl From<FfiTxMeta> for TxMeta {
    fn from(meta: FfiTxMeta) -> Self {
        let mut out = TxMeta::new(meta.writer.into(), meta.actor, meta.summary);
        if let Some(session) = meta.session {
            out = out.with_session(session);
        }
        if let Some(group) = meta.undo_group {
            out = out.with_undo_group(group);
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
    pub favorite: bool,
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
            favorite: page.favorite,
            version: page.version,
            updated_at: page.updated_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPageSummary {
    pub page: FfiPage,
    pub block_count: u64,
    pub backlink_count: u64,
}

impl From<PageSummary> for FfiPageSummary {
    fn from(summary: PageSummary) -> Self {
        Self {
            page: summary.page.into(),
            block_count: summary.block_count,
            backlink_count: summary.backlink_count,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiBlockKind {
    Paragraph,
    Heading {
        level: u8,
    },
    CodeBlock {
        language: Option<String>,
        code: String,
    },
    Quote,
    Divider,
}

impl From<BlockKind> for FfiBlockKind {
    fn from(kind: BlockKind) -> Self {
        match kind {
            BlockKind::Paragraph => Self::Paragraph,
            BlockKind::Heading { level } => Self::Heading { level },
            BlockKind::CodeBlock { language, code } => Self::CodeBlock { language, code },
            BlockKind::Quote => Self::Quote,
            BlockKind::Divider => Self::Divider,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBlockProp {
    pub key: String,
    pub value: String,
    pub value_spans: Vec<FfiSpan>,
}

impl From<BlockProp> for FfiBlockProp {
    fn from(prop: BlockProp) -> Self {
        Self {
            key: prop.key,
            value: prop.value,
            value_spans: prop.value_spans.into_iter().map(Into::into).collect(),
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
    pub spans: Vec<FfiSpan>,
    pub kind: FfiBlockKind,
    pub props: Vec<FfiBlockProp>,
    pub display: FfiBlockDisplay,
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
            spans: row.spans.into_iter().map(Into::into).collect(),
            kind: row.kind.into(),
            props: row.props.into_iter().map(Into::into).collect(),
            display: row.display.into(),
            collapsed: row.collapsed,
            has_children: row.has_children,
            version: row.version,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiRunStyle {
    Plain,
    Marker,
    Code,
    Bold,
    Italic,
    Strike,
    Highlight,
    ExternalLink {
        url: String,
    },
    Link {
        page_id: Option<String>,
        deleted: bool,
    },
    Tag {
        page_id: Option<String>,
        deleted: bool,
    },
    BlockRef {
        block_id: String,
    },
}

impl From<RunStyle> for FfiRunStyle {
    fn from(style: RunStyle) -> Self {
        match style {
            RunStyle::Plain => Self::Plain,
            RunStyle::Marker => Self::Marker,
            RunStyle::Code => Self::Code,
            RunStyle::Bold => Self::Bold,
            RunStyle::Italic => Self::Italic,
            RunStyle::Strike => Self::Strike,
            RunStyle::Highlight => Self::Highlight,
            RunStyle::ExternalLink { url } => Self::ExternalLink { url },
            RunStyle::Link { page_id, deleted } => Self::Link {
                page_id: page_id.map(|id| id.to_string()),
                deleted,
            },
            RunStyle::Tag { page_id, deleted } => Self::Tag {
                page_id: page_id.map(|id| id.to_string()),
                deleted,
            },
            RunStyle::BlockRef { block_id } => Self::BlockRef {
                block_id: block_id.to_string(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiDisplayRun {
    pub display: String,
    pub source: String,
    pub style: FfiRunStyle,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBlockDisplay {
    pub task_state: Option<String>,
    pub prefix: String,
    pub runs: Vec<FfiDisplayRun>,
}

impl From<BlockDisplay> for FfiBlockDisplay {
    fn from(display: BlockDisplay) -> Self {
        Self {
            task_state: display.task_state,
            prefix: display.prefix,
            runs: display
                .runs
                .into_iter()
                .map(|run| FfiDisplayRun {
                    display: run.display,
                    source: run.source,
                    style: run.style.into(),
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPageMatch {
    pub block_id: String,
    pub start: u32,
    pub len: u32,
}

impl From<PageMatch> for FfiPageMatch {
    fn from(m: PageMatch) -> Self {
        Self {
            block_id: m.block_id.to_string(),
            start: m.start,
            len: m.len,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiBlockLocation {
    pub page_id: String,
    pub visible_index: u64,
}

impl From<BlockLocation> for FfiBlockLocation {
    fn from(loc: BlockLocation) -> Self {
        Self {
            page_id: loc.page_id.to_string(),
            visible_index: loc.visible_index,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiPreviewLine {
    pub depth: u32,
    pub spans: Vec<FfiSpan>,
}

impl From<PreviewLine> for FfiPreviewLine {
    fn from(line: PreviewLine) -> Self {
        Self {
            depth: line.depth,
            spans: line.spans.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiLinkPreview {
    pub title: String,
    pub deleted: bool,
    pub lines: Vec<FfiPreviewLine>,
    pub total_blocks: u64,
    pub backlink_count: u64,
    pub parent_path: Vec<String>,
}

impl From<LinkPreview> for FfiLinkPreview {
    fn from(p: LinkPreview) -> Self {
        Self {
            title: p.title,
            deleted: p.deleted,
            lines: p.lines.into_iter().map(Into::into).collect(),
            total_blocks: p.total_blocks,
            backlink_count: p.backlink_count,
            parent_path: p.parent_path,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiUnlinkedRef {
    pub block_id: String,
    pub page_id: String,
    pub page_title: String,
    pub rendered_content: String,
    pub spans: Vec<FfiSpan>,
    pub match_start: u32,
    pub match_len: u32,
}

impl From<UnlinkedRef> for FfiUnlinkedRef {
    fn from(r: UnlinkedRef) -> Self {
        Self {
            block_id: r.block_id.to_string(),
            page_id: r.page_id.to_string(),
            page_title: r.page_title,
            rendered_content: r.rendered_content,
            spans: r.spans.into_iter().map(Into::into).collect(),
            match_start: r.match_start,
            match_len: r.match_len,
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
    SetPageFavorite {
        id: String,
        favorite: bool,
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
            FfiOp::SetPageFavorite { id, favorite } => Self::SetPageFavorite {
                id: parse_id(&id)?,
                favorite,
            },
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiApplyResult {
    pub txn_id: Option<String>,
    pub applied_count: u32,
    pub pages_changed: bool,
}

impl From<ApplyResult> for FfiApplyResult {
    fn from(res: ApplyResult) -> Self {
        Self {
            txn_id: res.txn_id.map(|id| id.to_string()),
            applied_count: res.applied_ops.len() as u32,
            pages_changed: res.applied_ops.iter().any(|op| {
                matches!(
                    op,
                    Op::CreatePage { .. }
                        | Op::RenamePage { .. }
                        | Op::DeletePage { .. }
                        | Op::RestorePage { .. }
                )
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum FfiSearchHit {
    Page {
        page_id: String,
        title: String,
        highlighted_title: Vec<FfiSegment>,
    },
    Block {
        block_id: String,
        page_id: String,
        page_title: String,
        breadcrumb: Vec<String>,
        snippet: Vec<FfiSegment>,
        cursor: u32,
        rank: f64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiSegment {
    pub text: String,
    pub highlighted: bool,
}

impl From<Segment> for FfiSegment {
    fn from(segment: Segment) -> Self {
        Self {
            text: segment.text,
            highlighted: segment.highlighted,
        }
    }
}

impl From<SearchHit> for FfiSearchHit {
    fn from(hit: SearchHit) -> Self {
        match hit {
            SearchHit::Page {
                page_id,
                title,
                highlighted_title,
            } => Self::Page {
                page_id: page_id.to_string(),
                title,
                highlighted_title: highlighted_title.into_iter().map(Into::into).collect(),
            },
            SearchHit::Block {
                block_id,
                page_id,
                page_title,
                breadcrumb,
                snippet,
                cursor,
                rank,
                ..
            } => Self::Block {
                block_id: block_id.to_string(),
                page_id: page_id.to_string(),
                page_title,
                breadcrumb,
                snippet: snippet.into_iter().map(Into::into).collect(),
                cursor,
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
    pub spans: Vec<FfiSpan>,
}

impl From<Backlink> for FfiBacklink {
    fn from(b: Backlink) -> Self {
        Self {
            block_id: b.block_id.to_string(),
            page_id: b.page_id.to_string(),
            page_title: b.page_title,
            kind: b.kind,
            rendered_content: b.rendered_content,
            spans: b.spans.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiSpan {
    Text {
        text: String,
    },
    Code {
        text: String,
    },
    Bold {
        text: String,
        source: String,
    },
    Italic {
        text: String,
        source: String,
    },
    Strike {
        text: String,
        source: String,
    },
    Highlight {
        text: String,
        source: String,
    },
    ExternalLink {
        label: String,
        url: String,
        source: String,
    },
    Task {
        state: String,
        source: String,
    },
    PageLink {
        page_id: Option<String>,
        title: String,
        source: String,
        deleted: bool,
    },
    Tag {
        page_id: Option<String>,
        title: String,
        source: String,
        deleted: bool,
    },
    BlockRef {
        block_id: String,
        text: String,
        source: String,
    },
}

impl From<RenderedSpan> for FfiSpan {
    fn from(span: RenderedSpan) -> Self {
        match span {
            RenderedSpan::Text(text) => Self::Text { text },
            RenderedSpan::Code(text) => Self::Code { text },
            RenderedSpan::Bold { text, source } => Self::Bold { text, source },
            RenderedSpan::Italic { text, source } => Self::Italic { text, source },
            RenderedSpan::Strike { text, source } => Self::Strike { text, source },
            RenderedSpan::Highlight { text, source } => Self::Highlight { text, source },
            RenderedSpan::ExternalLink { label, url, source } => {
                Self::ExternalLink { label, url, source }
            }
            RenderedSpan::Task { state, source } => Self::Task { state, source },
            RenderedSpan::PageLink {
                page_id,
                title,
                source,
                deleted,
            } => Self::PageLink {
                page_id: page_id.map(|id| id.to_string()),
                title,
                source,
                deleted,
            },
            RenderedSpan::Tag {
                page_id,
                title,
                source,
                deleted,
            } => Self::Tag {
                page_id: page_id.map(|id| id.to_string()),
                title,
                source,
                deleted,
            },
            RenderedSpan::BlockRef {
                block_id,
                text,
                source,
            } => Self::BlockRef {
                block_id: block_id.to_string(),
                text,
                source,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiEditOutcome {
    pub txn_id: Option<String>,
    pub focus_block_id: String,
    pub cursor: Option<u32>,
}

impl From<EditOutcome> for FfiEditOutcome {
    fn from(outcome: EditOutcome) -> Self {
        Self {
            txn_id: outcome.result.txn_id.map(|id| id.to_string()),
            focus_block_id: outcome.focus_block.to_string(),
            cursor: outcome.cursor,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct FfiChangeCursor {
    pub txn_seq: i64,
    pub view_seq: i64,
}

impl From<ChangeCursor> for FfiChangeCursor {
    fn from(cursor: ChangeCursor) -> Self {
        Self {
            txn_seq: cursor.txn_seq,
            view_seq: cursor.view_seq,
        }
    }
}

impl From<FfiChangeCursor> for ChangeCursor {
    fn from(cursor: FfiChangeCursor) -> Self {
        Self {
            txn_seq: cursor.txn_seq,
            view_seq: cursor.view_seq,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiGraphChanges {
    pub cursor: FfiChangeCursor,
    pub reload_all: bool,
    pub pages: Vec<String>,
    pub restructured_pages: Vec<String>,
    pub stale_blocks: Vec<String>,
}

impl From<GraphChanges> for FfiGraphChanges {
    fn from(changes: GraphChanges) -> Self {
        let strings = |ids: Vec<Id>| ids.into_iter().map(|id| id.to_string()).collect();
        Self {
            cursor: changes.cursor.into(),
            reload_all: changes.reload_all,
            pages: strings(changes.pages),
            restructured_pages: strings(changes.restructured_pages),
            stale_blocks: strings(changes.stale_blocks),
        }
    }
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

    pub fn journal_page(&self, date: Option<String>) -> Result<Option<FfiPage>, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.journal_page(date.as_deref())?.map(Into::into))
    }

    pub fn start_journal(
        &self,
        date: Option<String>,
        meta: FfiTxMeta,
    ) -> Result<FfiEditOutcome, FfiError> {
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.start_journal(date.as_deref(), &meta.into())?.into())
    }

    pub fn append_block(
        &self,
        page_id: String,
        text: String,
        meta: FfiTxMeta,
    ) -> Result<FfiEditOutcome, FfiError> {
        let page_id = parse_id(&page_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.append_block(page_id, &text, &meta.into())?.into())
    }

    pub fn split_block(
        &self,
        block_id: String,
        base_version: i64,
        before: String,
        after: String,
        meta: FfiTxMeta,
    ) -> Result<FfiEditOutcome, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .split_block(block_id, base_version, &before, &after, &meta.into())?
            .into())
    }

    pub fn merge_into_previous(
        &self,
        block_id: String,
        base_version: i64,
        text: String,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiEditOutcome>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .merge_into_previous(block_id, base_version, &text, &meta.into())?
            .map(Into::into))
    }

    pub fn move_block_up(
        &self,
        block_id: String,
        base_version: i64,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiEditOutcome>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .move_block_up(block_id, base_version, &meta.into())?
            .map(Into::into))
    }

    pub fn move_block_down(
        &self,
        block_id: String,
        base_version: i64,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiEditOutcome>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .move_block_down(block_id, base_version, &meta.into())?
            .map(Into::into))
    }

    pub fn reveal_block(&self, block_id: String, meta: FfiTxMeta) -> Result<u64, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.reveal_block(block_id, &meta.into())?)
    }

    pub fn reveal_block_location(
        &self,
        block_id: String,
        meta: FfiTxMeta,
    ) -> Result<FfiBlockLocation, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.reveal_block_location(block_id, &meta.into())?.into())
    }

    pub fn set_all_collapsed(
        &self,
        page_id: String,
        root_block_id: Option<String>,
        collapsed: bool,
        meta: FfiTxMeta,
    ) -> Result<u32, FfiError> {
        let page_id = parse_id(&page_id)?;
        let root_block_id = root_block_id.as_deref().map(parse_id).transpose()?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.set_all_collapsed(page_id, root_block_id, collapsed, &meta.into())?)
    }

    pub fn find_in_page(
        &self,
        page_id: String,
        root_block_id: Option<String>,
        query: String,
    ) -> Result<Vec<FfiPageMatch>, FfiError> {
        let page_id = parse_id(&page_id)?;
        let root_block_id = root_block_id.as_deref().map(parse_id).transpose()?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .find_in_page(page_id, root_block_id, &query)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn preview_page(
        &self,
        page_id: String,
        max_lines: u32,
    ) -> Result<Option<FfiLinkPreview>, FfiError> {
        let page_id = parse_id(&page_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .preview_page(page_id, max_lines as usize)?
            .map(Into::into))
    }

    pub fn preview_block(
        &self,
        block_id: String,
        max_lines: u32,
    ) -> Result<Option<FfiLinkPreview>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .preview_block(block_id, max_lines as usize)?
            .map(Into::into))
    }

    pub fn unlinked_references(
        &self,
        page_id: String,
        limit: u32,
    ) -> Result<Vec<FfiUnlinkedRef>, FfiError> {
        let page_id = parse_id(&page_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .unlinked_references(page_id, limit as usize)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn link_unlinked_reference(
        &self,
        block_id: String,
        target_page_id: String,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let target_page_id = parse_id(&target_page_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .link_unlinked_reference(block_id, target_page_id, &meta.into())?
            .map(Into::into))
    }

    pub fn read_block_window(
        &self,
        block_id: String,
        offset: u64,
        limit: u64,
    ) -> Result<FfiPageWindow, FfiError> {
        let block_id = parse_id(&block_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.read_block_window(block_id, offset, limit)?.into())
    }

    pub fn block_breadcrumb(&self, block_id: String) -> Result<Vec<FfiCrumb>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .block_breadcrumb(block_id)?
            .into_iter()
            .map(|c| FfiCrumb {
                block_id: c.block_id.map(|id| id.to_string()),
                label: c.label,
            })
            .collect())
    }

    pub fn suggest_pages(&self, query: String, limit: u32) -> Result<Vec<FfiPage>, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .suggest_pages(&query, limit as usize)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn list_journals(&self, limit: u32) -> Result<Vec<FfiPage>, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .list_journals(limit as usize)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn list_page_summaries(&self) -> Result<Vec<FfiPageSummary>, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .list_page_summaries()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn paste_text(
        &self,
        block_id: String,
        base_version: i64,
        before: String,
        after: String,
        pasted: String,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiEditOutcome>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .paste_text(
                block_id,
                base_version,
                &before,
                &after,
                &pasted,
                &meta.into(),
            )?
            .map(Into::into))
    }

    pub fn subtree_markdown(&self, block_id: String) -> Result<String, FfiError> {
        let block_id = parse_id(&block_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.subtree_markdown(block_id)?)
    }

    pub fn run_slash_command(
        &self,
        block_id: String,
        base_version: i64,
        text: String,
        caret: u32,
        command: FfiSlashCommand,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiEditOutcome>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let clock = LocalClock::now()?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .run_slash_command(
                block_id,
                base_version,
                &text,
                caret as usize,
                command.into(),
                &clock.borrow(),
                &meta.into(),
            )?
            .map(Into::into))
    }

    pub fn blocks_markdown(&self, block_ids: Vec<String>) -> Result<String, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.blocks_markdown(&ids)?)
    }

    pub fn delete_blocks(
        &self,
        block_ids: Vec<String>,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.delete_blocks(&ids, &meta.into())?.map(Into::into))
    }

    pub fn indent_blocks(
        &self,
        block_ids: Vec<String>,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.indent_blocks(&ids, &meta.into())?.map(Into::into))
    }

    pub fn outdent_blocks(
        &self,
        block_ids: Vec<String>,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.outdent_blocks(&ids, &meta.into())?.map(Into::into))
    }

    pub fn move_blocks_up(
        &self,
        block_ids: Vec<String>,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.move_blocks_up(&ids, &meta.into())?.map(Into::into))
    }

    pub fn move_blocks_down(
        &self,
        block_ids: Vec<String>,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.move_blocks_down(&ids, &meta.into())?.map(Into::into))
    }

    pub fn cycle_tasks(
        &self,
        block_ids: Vec<String>,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiApplyResult>, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.cycle_tasks(&ids, &meta.into())?.map(Into::into))
    }

    pub fn cycle_task(
        &self,
        block_id: String,
        base_version: i64,
        meta: FfiTxMeta,
    ) -> Result<FfiEditOutcome, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .cycle_task(block_id, base_version, &meta.into())?
            .into())
    }

    pub fn toggle_task_done(
        &self,
        block_id: String,
        base_version: i64,
        meta: FfiTxMeta,
    ) -> Result<FfiEditOutcome, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .toggle_task_done(block_id, base_version, &meta.into())?
            .into())
    }

    pub fn indent_block(
        &self,
        block_id: String,
        base_version: i64,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiEditOutcome>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .indent_block(block_id, base_version, &meta.into())?
            .map(Into::into))
    }

    pub fn outdent_block(
        &self,
        block_id: String,
        base_version: i64,
        meta: FfiTxMeta,
    ) -> Result<Option<FfiEditOutcome>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let mut store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .outdent_block(block_id, base_version, &meta.into())?
            .map(Into::into))
    }

    pub fn block_row(&self, block_id: String) -> Result<Option<FfiFlatBlockRow>, FfiError> {
        let block_id = parse_id(&block_id)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.block_row(block_id)?.map(Into::into))
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

    pub fn change_cursor(&self) -> Result<FfiChangeCursor, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.change_cursor()?.into())
    }

    pub fn changes_after(&self, cursor: FfiChangeCursor) -> Result<FfiGraphChanges, FfiError> {
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store.changes_after(cursor.into())?.into())
    }

    pub fn block_rows(&self, block_ids: Vec<String>) -> Result<Vec<FfiFlatBlockRow>, FfiError> {
        let ids = parse_ids(&block_ids)?;
        let store = self.store.lock().map_err(|_| FfiError::LockPoisoned)?;
        Ok(store
            .block_rows(&ids)?
            .into_iter()
            .map(Into::into)
            .collect())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiHighlightKind {
    Bracket,
    Link,
    Tag,
    Code,
    BlockRef,
    Bold,
    Italic,
    Strike,
    Highlight,
    ExternalLink,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiInlineFormat {
    Bold,
    Italic,
    Strike,
    Highlight,
}

impl From<FfiInlineFormat> for InlineFormat {
    fn from(format: FfiInlineFormat) -> Self {
        match format {
            FfiInlineFormat::Bold => Self::Bold,
            FfiInlineFormat::Italic => Self::Italic,
            FfiInlineFormat::Strike => Self::Strike,
            FfiInlineFormat::Highlight => Self::Highlight,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiRangeEdit {
    pub text: String,
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiHighlight {
    pub start: u32,
    pub len: u32,
    pub kind: FfiHighlightKind,
}

#[uniffi::export]
pub fn highlight(text: String) -> Vec<FfiHighlight> {
    highlight_ranges(&text)
        .into_iter()
        .map(|h| FfiHighlight {
            start: h.start as u32,
            len: h.len as u32,
            kind: match h.kind {
                HighlightKind::Bracket => FfiHighlightKind::Bracket,
                HighlightKind::Link => FfiHighlightKind::Link,
                HighlightKind::Tag => FfiHighlightKind::Tag,
                HighlightKind::Code => FfiHighlightKind::Code,
                HighlightKind::BlockRef => FfiHighlightKind::BlockRef,
                HighlightKind::Bold => FfiHighlightKind::Bold,
                HighlightKind::Italic => FfiHighlightKind::Italic,
                HighlightKind::Strike => FfiHighlightKind::Strike,
                HighlightKind::Highlight => FfiHighlightKind::Highlight,
                HighlightKind::ExternalLink => FfiHighlightKind::ExternalLink,
            },
        })
        .collect()
}

#[uniffi::export]
pub fn toggle_inline_format(
    text: String,
    start: u32,
    end: u32,
    format: FfiInlineFormat,
) -> FfiRangeEdit {
    let (text, start, end) =
        parser::toggle_inline_format(&text, start as usize, end as usize, format.into());
    FfiRangeEdit {
        text,
        start: start as u32,
        end: end as u32,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCrumb {
    pub block_id: Option<String>,
    pub label: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiCompletionKind {
    Page,
    Tag,
    Block,
    Slash,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiCompletionContext {
    pub kind: FfiCompletionKind,
    pub query: String,
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiTextEdit {
    pub text: String,
    pub caret: u32,
}

impl From<CompletionContext> for FfiCompletionContext {
    fn from(c: CompletionContext) -> Self {
        Self {
            kind: match c.kind {
                CompletionKind::Page => FfiCompletionKind::Page,
                CompletionKind::Tag => FfiCompletionKind::Tag,
                CompletionKind::Block => FfiCompletionKind::Block,
                CompletionKind::Slash => FfiCompletionKind::Slash,
            },
            query: c.query,
            start: c.start as u32,
            end: c.end as u32,
        }
    }
}

impl From<FfiCompletionContext> for CompletionContext {
    fn from(c: FfiCompletionContext) -> Self {
        Self {
            kind: match c.kind {
                FfiCompletionKind::Page => CompletionKind::Page,
                FfiCompletionKind::Tag => CompletionKind::Tag,
                FfiCompletionKind::Block => CompletionKind::Block,
                FfiCompletionKind::Slash => CompletionKind::Slash,
            },
            query: c.query,
            start: c.start as usize,
            end: c.end as usize,
        }
    }
}

#[uniffi::export]
pub fn completion_context(text: String, caret: u32) -> Option<FfiCompletionContext> {
    parser::completion_context(&text, caret as usize).map(Into::into)
}

#[uniffi::export]
pub fn apply_completion(text: String, context: FfiCompletionContext, value: String) -> FfiTextEdit {
    let (text, caret) = parser::apply_completion(&text, &context.into(), &value);
    FfiTextEdit {
        text,
        caret: caret as u32,
    }
}

#[uniffi::export]
pub fn auto_pair(text: String, caret: u32) -> Option<String> {
    parser::auto_pair(&text, caret as usize)
}

#[uniffi::export]
pub fn journal_title(date: Option<String>) -> Result<String, FfiError> {
    Ok(resolve_journal_date(date.as_deref())?.1)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FfiSlashCommand {
    Todo,
    Doing,
    Done,
    Today,
    Tomorrow,
    Yesterday,
    CurrentTime,
    CodeBlock,
}

impl From<SlashCommand> for FfiSlashCommand {
    fn from(command: SlashCommand) -> Self {
        match command {
            SlashCommand::Todo => Self::Todo,
            SlashCommand::Doing => Self::Doing,
            SlashCommand::Done => Self::Done,
            SlashCommand::Today => Self::Today,
            SlashCommand::Tomorrow => Self::Tomorrow,
            SlashCommand::Yesterday => Self::Yesterday,
            SlashCommand::CurrentTime => Self::CurrentTime,
            SlashCommand::CodeBlock => Self::CodeBlock,
        }
    }
}

impl From<FfiSlashCommand> for SlashCommand {
    fn from(command: FfiSlashCommand) -> Self {
        match command {
            FfiSlashCommand::Todo => Self::Todo,
            FfiSlashCommand::Doing => Self::Doing,
            FfiSlashCommand::Done => Self::Done,
            FfiSlashCommand::Today => Self::Today,
            FfiSlashCommand::Tomorrow => Self::Tomorrow,
            FfiSlashCommand::Yesterday => Self::Yesterday,
            FfiSlashCommand::CurrentTime => Self::CurrentTime,
            FfiSlashCommand::CodeBlock => Self::CodeBlock,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FfiSlashItem {
    pub command: FfiSlashCommand,
    pub label: String,
    pub detail: Option<String>,
}

struct LocalClock {
    today: String,
    tomorrow: String,
    yesterday: String,
    time: String,
}

impl LocalClock {
    fn now() -> Result<Self, FfiError> {
        Ok(Self {
            today: resolve_journal_date(None)?.1,
            tomorrow: shift_journal_date(None, 1)?,
            yesterday: shift_journal_date(None, -1)?,
            time: local_time_of_day(),
        })
    }

    fn borrow(&self) -> SlashClock<'_> {
        SlashClock {
            today: &self.today,
            tomorrow: &self.tomorrow,
            yesterday: &self.yesterday,
            time: &self.time,
        }
    }
}

#[uniffi::export]
pub fn slash_commands(query: String) -> Result<Vec<FfiSlashItem>, FfiError> {
    let clock = LocalClock::now()?;
    Ok(parser::slash_commands(&query)
        .into_iter()
        .map(|command| FfiSlashItem {
            command: command.into(),
            label: command.label().to_string(),
            detail: parser::slash_preview(command, &clock.borrow()),
        })
        .collect())
}

#[uniffi::export]
pub fn shift_journal_day(date: Option<String>, delta_days: i32) -> Result<String, FfiError> {
    Ok(shift_journal_date(date.as_deref(), delta_days)?)
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

fn parse_ids(raw: &[String]) -> Result<Vec<Id>, FfiError> {
    raw.iter().map(|s| parse_id(s)).collect()
}
