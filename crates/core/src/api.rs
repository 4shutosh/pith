use serde::Serialize;
use uuid::Uuid;

use crate::error::{Error, Result};
use crate::id::Id;
use crate::journal::resolve_journal_date;
use crate::ops::Op;
use crate::order;
use crate::store::Store;
use crate::types::{Origin, Page, SearchHit, TxMeta};

const MIN_SHORT_ID_LEN: usize = 6;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedTarget {
    Page(Id),
    Block(Id),
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SearchResultItem {
    Page {
        id: Id,
        short_id: String,
        title: String,
    },
    Block {
        id: Id,
        short_id: String,
        page_id: Id,
        page_short_id: String,
        page_title: String,
        breadcrumb: Vec<String>,
        matched_line: String,
        rank: f64,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct OutlineBlock {
    pub id: Id,
    pub short_id: String,
    pub version: i64,
    pub content: String,
    pub collapsed: bool,
    pub children: Vec<OutlineBlock>,
}

#[derive(Debug, Clone, Serialize)]
pub struct OutlinePage {
    pub id: Id,
    pub short_id: String,
    pub version: i64,
    pub title: String,
    pub journal_day: Option<i32>,
    pub document_mode: bool,
    pub blocks: Vec<OutlineBlock>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ShowResult {
    Page(OutlinePage),
    Block(OutlineBlock),
}

#[derive(Debug, Clone, Serialize)]
pub struct BacklinkItem {
    pub block_id: Id,
    pub short_id: String,
    pub page_id: Id,
    pub page_short_id: String,
    pub page_title: String,
    pub kind: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct BacklinksResult {
    pub target_id: Id,
    pub target_short_id: String,
    pub target_label: String,
    pub backlinks: Vec<BacklinkItem>,
}

#[derive(Debug, Clone, Serialize)]
pub struct HistoryEntry {
    pub id: Id,
    pub short_id: String,
    pub ts: i64,
    pub origin: Origin,
    pub actor: String,
    pub session: Option<String>,
    pub summary: String,
    pub undoes: Option<Id>,
    pub is_undone: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct WriteOutcome {
    pub dry_run: bool,
    pub txn_id: Option<Id>,
    pub txn_short_id: Option<String>,
    pub ops: Vec<Op>,
    pub created_ids: Vec<Id>,
    pub created_short_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownNode {
    pub content: String,
    pub children: Vec<MarkdownNode>,
}

impl OutlinePage {
    pub fn format_outline(&self) -> String {
        let mut lines = Vec::new();
        lines.push(format!("# {} (page {})", self.title, self.short_id));
        for block in &self.blocks {
            format_outline_block(block, 0, &mut lines);
        }
        lines.join("\n")
    }
}

impl OutlineBlock {
    pub fn format_outline(&self) -> String {
        let mut lines = Vec::new();
        format_outline_block(self, 0, &mut lines);
        lines.join("\n")
    }
}

fn format_outline_block(block: &OutlineBlock, depth: usize, lines: &mut Vec<String>) {
    let indent = "  ".repeat(depth);
    let mut content_lines = block.content.lines();
    let first_line = content_lines.next().unwrap_or("");
    let collapsed_marker = if block.collapsed { " [+]" } else { "" };
    lines.push(format!(
        "{indent}- {first_line}{collapsed_marker}  ^{} v{}",
        block.short_id, block.version
    ));
    for cont in content_lines {
        lines.push(format!("{indent}  {cont}"));
    }
    for child in &block.children {
        format_outline_block(child, depth + 1, lines);
    }
}

pub struct Api<'a> {
    store: &'a mut Store,
}

impl<'a> Api<'a> {
    pub fn new(store: &'a mut Store) -> Self {
        Self { store }
    }

    pub fn describe_error(&self, err: &Error) -> String {
        err.describe(&|id| self.store.short_id(id).unwrap_or_else(|_| id.to_string()))
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchResultItem>> {
        let hits = self.store.search(query, limit)?;
        let mut out = Vec::with_capacity(hits.len());
        for hit in hits {
            match hit {
                SearchHit::Page { page_id, title, .. } => out.push(SearchResultItem::Page {
                    id: page_id,
                    short_id: self.store.short_id(page_id)?,
                    title,
                }),
                SearchHit::Block {
                    block_id,
                    page_id,
                    page_title,
                    breadcrumb,
                    snippet,
                    rank,
                    ..
                } => out.push(SearchResultItem::Block {
                    id: block_id,
                    short_id: self.store.short_id(block_id)?,
                    page_id,
                    page_short_id: self.store.short_id(page_id)?,
                    page_title,
                    breadcrumb,
                    matched_line: crate::snippet::plain(&snippet),
                    rank,
                }),
            }
        }
        Ok(out)
    }

    pub fn show(&self, target: &str, depth: Option<usize>) -> Result<ShowResult> {
        match self.resolve_live_target(target)? {
            ResolvedTarget::Page(page_id) => {
                let page = self
                    .store
                    .get_page(page_id)?
                    .ok_or(Error::NotFound(page_id))?;
                let outline = self.build_outline_page(&page, depth)?;
                Ok(ShowResult::Page(outline))
            }
            ResolvedTarget::Block(block_id) => {
                let outline = self.build_outline_block(block_id, depth)?;
                Ok(ShowResult::Block(outline))
            }
        }
    }

    pub fn backlinks(&self, target: &str) -> Result<BacklinksResult> {
        let (target_id, target_label) = match self.resolve_live_target(target)? {
            ResolvedTarget::Page(id) => {
                let page = self.store.get_page(id)?.ok_or(Error::NotFound(id))?;
                (id, page.title)
            }
            ResolvedTarget::Block(id) => {
                let block = self.store.get_block(id)?.ok_or(Error::NotFound(id))?;
                (id, self.store.render_content(&block.content)?)
            }
        };

        let raw = self.store.backlinks(target_id)?;
        let mut backlinks = Vec::with_capacity(raw.len());
        for b in raw {
            backlinks.push(BacklinkItem {
                block_id: b.block_id,
                short_id: self.store.short_id(b.block_id)?,
                page_id: b.page_id,
                page_short_id: self.store.short_id(b.page_id)?,
                page_title: b.page_title,
                kind: b.kind,
                content: b.rendered_content,
            });
        }

        Ok(BacklinksResult {
            target_id,
            target_short_id: self.store.short_id(target_id)?,
            target_label,
            backlinks,
        })
    }

    pub fn journal_show(
        &self,
        date: Option<&str>,
        depth: Option<usize>,
    ) -> Result<Option<OutlinePage>> {
        let Some(page) = self.store.journal_page(date)? else {
            return Ok(None);
        };
        Ok(Some(self.build_outline_page(&page, depth)?))
    }

    pub fn journal_append(
        &mut self,
        markdown: &str,
        date: Option<&str>,
        meta: &TxMeta,
        dry_run: bool,
    ) -> Result<WriteOutcome> {
        let nodes = parse_markdown_tree(markdown)?;
        let (journal_day, title) = resolve_journal_date(date)?;

        let mut ops = Vec::new();
        let page_id = match self.store.journal_page(date)? {
            Some(page) => page.id,
            None => {
                let id = Id::new();
                ops.push(Op::CreatePage {
                    id,
                    title,
                    journal_day: Some(journal_day),
                    document_mode: false,
                });
                id
            }
        };

        let last_key = self
            .store
            .list_children(page_id, None)?
            .last()
            .map(|b| b.order_key.clone());

        append_tree_ops(&nodes, page_id, None, last_key.as_deref(), None, &mut ops)?;

        self.execute_write(ops, meta, dry_run)
    }

    pub fn insert(
        &mut self,
        parent: &str,
        after: Option<&str>,
        markdown: &str,
        meta: &TxMeta,
        dry_run: bool,
    ) -> Result<WriteOutcome> {
        let nodes = parse_markdown_tree(markdown)?;
        let (page_id, parent_id) = match self.resolve_live_target(parent)? {
            ResolvedTarget::Page(pid) => (pid, None),
            ResolvedTarget::Block(bid) => {
                let block = self.store.get_block(bid)?.ok_or(Error::NotFound(bid))?;
                (block.page_id, Some(bid))
            }
        };

        let (lower, upper) = self.sibling_bounds(page_id, parent_id, after)?;
        let mut ops = Vec::new();
        append_tree_ops(
            &nodes,
            page_id,
            parent_id,
            lower.as_deref(),
            upper.as_deref(),
            &mut ops,
        )?;

        self.execute_write(ops, meta, dry_run)
    }

    pub fn update(
        &mut self,
        id_ref: &str,
        content: &str,
        expected_version: Option<i64>,
        meta: &TxMeta,
        dry_run: bool,
    ) -> Result<WriteOutcome> {
        require_agent_version(meta, expected_version)?;
        let block_id = self.resolve_live_block_id(id_ref)?;
        let ops = vec![Op::UpdateBlock {
            id: block_id,
            content: content.to_string(),
            expected_version,
        }];
        self.execute_write(ops, meta, dry_run)
    }

    pub fn move_block(
        &mut self,
        id_ref: &str,
        parent: &str,
        after: Option<&str>,
        expected_version: Option<i64>,
        meta: &TxMeta,
        dry_run: bool,
    ) -> Result<WriteOutcome> {
        require_agent_version(meta, expected_version)?;
        let block_id = self.resolve_live_block_id(id_ref)?;
        let (page_id, parent_id) = match self.resolve_live_target(parent)? {
            ResolvedTarget::Page(pid) => (pid, None),
            ResolvedTarget::Block(bid) => {
                let block = self.store.get_block(bid)?.ok_or(Error::NotFound(bid))?;
                (block.page_id, Some(bid))
            }
        };

        let (lower, upper) = self.sibling_bounds(page_id, parent_id, after)?;
        let order_key = order::between(lower.as_deref(), upper.as_deref())?;
        let ops = vec![Op::MoveBlock {
            id: block_id,
            page_id,
            parent_id,
            order_key,
            expected_version,
        }];
        self.execute_write(ops, meta, dry_run)
    }

    pub fn delete(
        &mut self,
        id_ref: &str,
        expected_version: Option<i64>,
        meta: &TxMeta,
        dry_run: bool,
    ) -> Result<WriteOutcome> {
        require_agent_version(meta, expected_version)?;
        let op = match self.resolve_live_target(id_ref)? {
            ResolvedTarget::Page(id) => Op::DeletePage {
                id,
                expected_version,
            },
            ResolvedTarget::Block(id) => Op::DeleteBlock {
                id,
                expected_version,
            },
        };
        self.execute_write(vec![op], meta, dry_run)
    }

    pub fn history(
        &self,
        actor: Option<&str>,
        since: Option<i64>,
        limit: usize,
    ) -> Result<Vec<HistoryEntry>> {
        let txns = self.store.list_txns(actor)?;
        let mut out = Vec::new();
        for txn in txns {
            if let Some(min_ts) = since
                && txn.ts < min_ts
            {
                continue;
            }
            let is_undone = self.store.is_undone(txn.id)?;
            out.push(HistoryEntry {
                id: txn.id,
                short_id: self.store.short_id(txn.id)?,
                ts: txn.ts,
                origin: txn.origin,
                actor: txn.actor,
                session: txn.session,
                summary: txn.summary,
                undoes: txn.undoes,
                is_undone,
            });
            if out.len() >= limit {
                break;
            }
        }
        Ok(out)
    }

    pub fn undo(
        &mut self,
        txn_ref: &str,
        meta: &TxMeta,
        force: bool,
        dry_run: bool,
    ) -> Result<WriteOutcome> {
        let txn_id = self.resolve_txn_id(txn_ref)?;
        let applied = if dry_run {
            self.store.dry_run_undo(txn_id, meta, force)?
        } else {
            self.store.undo(txn_id, meta, force)?
        };

        let txn_short_id = match (dry_run, applied.txn_id) {
            (false, Some(id)) => Some(self.store.short_id(id)?),
            _ => None,
        };
        Ok(WriteOutcome {
            dry_run,
            txn_id: if dry_run { None } else { applied.txn_id },
            txn_short_id,
            ops: applied.applied_ops,
            created_ids: Vec::new(),
            created_short_ids: Vec::new(),
        })
    }

    fn execute_write(
        &mut self,
        ops: Vec<Op>,
        meta: &TxMeta,
        dry_run: bool,
    ) -> Result<WriteOutcome> {
        let applied = if dry_run {
            self.store.dry_run_ops(&ops, meta)?
        } else {
            self.store.apply_ops(&ops, meta)?
        };
        let created_ids: Vec<Id> = applied
            .applied_ops
            .iter()
            .filter_map(|op| match op {
                Op::CreatePage { id, .. } | Op::InsertBlock { id, .. } => Some(*id),
                _ => None,
            })
            .collect();
        let mut created_short_ids = Vec::with_capacity(created_ids.len());
        for &id in &created_ids {
            created_short_ids.push(self.store.short_id(id)?);
        }
        let txn_short_id = match (dry_run, applied.txn_id) {
            (false, Some(id)) => Some(self.store.short_id(id)?),
            _ => None,
        };
        Ok(WriteOutcome {
            dry_run,
            txn_id: if dry_run { None } else { applied.txn_id },
            txn_short_id,
            ops: applied.applied_ops,
            created_ids,
            created_short_ids,
        })
    }

    fn build_outline_page(&self, page: &Page, depth: Option<usize>) -> Result<OutlinePage> {
        let roots = self.store.list_children(page.id, None)?;
        let mut blocks = Vec::with_capacity(roots.len());
        for root in roots {
            blocks.push(self.build_outline_block_rec(root.id, 0, depth)?);
        }
        Ok(OutlinePage {
            id: page.id,
            short_id: self.store.short_id(page.id)?,
            version: page.version,
            title: page.title.clone(),
            journal_day: page.journal_day,
            document_mode: page.document_mode,
            blocks,
        })
    }

    fn build_outline_block(&self, block_id: Id, depth: Option<usize>) -> Result<OutlineBlock> {
        self.build_outline_block_rec(block_id, 0, depth)
    }

    fn build_outline_block_rec(
        &self,
        block_id: Id,
        current_depth: usize,
        max_depth: Option<usize>,
    ) -> Result<OutlineBlock> {
        let block = self
            .store
            .get_block(block_id)?
            .ok_or(Error::NotFound(block_id))?;
        let rendered = self.store.render_content(&block.content)?;
        let children = if max_depth.is_some_and(|limit| current_depth >= limit) {
            Vec::new()
        } else {
            let child_rows = self.store.list_children(block.page_id, Some(block.id))?;
            let mut out = Vec::with_capacity(child_rows.len());
            for child in child_rows {
                out.push(self.build_outline_block_rec(child.id, current_depth + 1, max_depth)?);
            }
            out
        };

        Ok(OutlineBlock {
            id: block.id,
            short_id: self.store.short_id(block.id)?,
            version: block.version,
            content: rendered,
            collapsed: block.collapsed,
            children,
        })
    }

    fn sibling_bounds(
        &self,
        page_id: Id,
        parent_id: Option<Id>,
        after: Option<&str>,
    ) -> Result<(Option<String>, Option<String>)> {
        let siblings = self.store.list_children(page_id, parent_id)?;
        match after {
            None => Ok((siblings.last().map(|b| b.order_key.clone()), None)),
            Some(after_ref) => {
                let after_id = self.resolve_live_block_id(after_ref)?;
                let pos = siblings
                    .iter()
                    .position(|b| b.id == after_id)
                    .ok_or(Error::NotASibling { id: after_id })?;
                let lower = Some(siblings[pos].order_key.clone());
                let upper = siblings.get(pos + 1).map(|b| b.order_key.clone());
                Ok((lower, upper))
            }
        }
    }

    fn resolve_live_target(&self, input: &str) -> Result<ResolvedTarget> {
        let trimmed = input.trim();
        let stripped = trimmed.strip_prefix('^').unwrap_or(trimmed);

        if let Ok(uuid) = Uuid::parse_str(stripped) {
            let id = Id::from_uuid(uuid);
            if let Some(page) = self.store.get_page(id)?
                && page.deleted_at.is_none()
            {
                return Ok(ResolvedTarget::Page(id));
            }
            if let Some(block) = self.store.get_block(id)?
                && block.deleted_at.is_none()
            {
                return Ok(ResolvedTarget::Block(id));
            }
            return Err(Error::NotFound(id));
        }

        if let Some(page) = self.store.get_page_by_title(trimmed)? {
            return Ok(ResolvedTarget::Page(page.id));
        }

        if is_hex_suffix(stripped) {
            let suffix = stripped.to_ascii_lowercase();
            let mut matches: Vec<ResolvedTarget> = self
                .store
                .find_live_pages_by_suffix(&suffix)?
                .into_iter()
                .map(ResolvedTarget::Page)
                .collect();
            matches.extend(
                self.store
                    .find_live_blocks_by_suffix(&suffix)?
                    .into_iter()
                    .map(ResolvedTarget::Block),
            );
            return match matches.len() {
                0 => Err(Error::NotFoundRef(input.to_string())),
                1 => Ok(matches.remove(0)),
                _ => Err(Error::AmbiguousId {
                    suffix,
                    matches: matches
                        .into_iter()
                        .map(|m| match m {
                            ResolvedTarget::Page(id) | ResolvedTarget::Block(id) => id,
                        })
                        .collect(),
                }),
            };
        }

        Err(Error::NotFoundRef(input.to_string()))
    }

    fn resolve_live_block_id(&self, input: &str) -> Result<Id> {
        let trimmed = input.trim();
        let stripped = trimmed.strip_prefix('^').unwrap_or(trimmed);

        if let Ok(uuid) = Uuid::parse_str(stripped) {
            let id = Id::from_uuid(uuid);
            let block = self.store.get_block(id)?.ok_or(Error::NotFound(id))?;
            if block.deleted_at.is_some() {
                return Err(Error::DeletedEntity(id));
            }
            return Ok(id);
        }

        if is_hex_suffix(stripped) {
            let suffix = stripped.to_ascii_lowercase();
            let matches = self.store.find_live_blocks_by_suffix(&suffix)?;
            return match matches.len() {
                0 => Err(Error::NotFoundRef(input.to_string())),
                1 => Ok(matches[0]),
                _ => Err(Error::AmbiguousId { suffix, matches }),
            };
        }

        Err(Error::NotFoundRef(input.to_string()))
    }

    fn resolve_txn_id(&self, input: &str) -> Result<Id> {
        let trimmed = input.trim();
        let stripped = trimmed.strip_prefix('^').unwrap_or(trimmed);

        if let Ok(uuid) = Uuid::parse_str(stripped) {
            return Ok(Id::from_uuid(uuid));
        }

        if is_hex_suffix(stripped) {
            let suffix = stripped.to_ascii_lowercase();
            let matches = self.store.find_txns_by_suffix(&suffix)?;
            return match matches.len() {
                0 => Err(Error::NotFoundRef(input.to_string())),
                1 => Ok(matches[0]),
                _ => Err(Error::AmbiguousId { suffix, matches }),
            };
        }

        Err(Error::NotFoundRef(input.to_string()))
    }
}

fn require_agent_version(meta: &TxMeta, expected_version: Option<i64>) -> Result<()> {
    if meta.origin == Origin::Agent && expected_version.is_none() {
        return Err(Error::MissingExpectedVersion);
    }
    Ok(())
}

pub fn parse_markdown_tree(markdown: &str) -> Result<Vec<MarkdownNode>> {
    let lines: Vec<&str> = markdown.lines().collect();
    if lines.iter().all(|l| l.trim().is_empty()) {
        return Err(Error::EmptyInput);
    }

    let has_bullets = lines
        .iter()
        .find(|l| !l.trim().is_empty())
        .is_some_and(|l| strip_bullet(l.trim_start()).is_some());

    if !has_bullets {
        return Ok(vec![MarkdownNode {
            content: markdown.trim().to_string(),
            children: Vec::new(),
        }]);
    }

    let mut roots: Vec<MarkdownNode> = Vec::new();
    let mut stack: Vec<(usize, Vec<usize>)> = Vec::new();

    for line in lines {
        if line.trim().is_empty() {
            continue;
        }
        let indent = leading_indent(line);
        let trimmed = line.trim_start();
        if let Some(body) = strip_bullet(trimmed) {
            while stack
                .last()
                .is_some_and(|(parent_indent, _)| *parent_indent >= indent)
            {
                stack.pop();
            }
            let node = MarkdownNode {
                content: body.to_string(),
                children: Vec::new(),
            };
            let path = if let Some((_, parent_path)) = stack.last() {
                let parent = node_at_path_mut(&mut roots, parent_path);
                let idx = parent.children.len();
                parent.children.push(node);
                let mut next_path = parent_path.clone();
                next_path.push(idx);
                next_path
            } else {
                let idx = roots.len();
                roots.push(node);
                vec![idx]
            };
            stack.push((indent, path));
        } else if let Some((_, current_path)) = stack.last() {
            let current = node_at_path_mut(&mut roots, current_path);
            current.content.push('\n');
            current.content.push_str(trimmed);
        } else {
            let idx = roots.len();
            roots.push(MarkdownNode {
                content: trimmed.to_string(),
                children: Vec::new(),
            });
            stack.push((indent, vec![idx]));
        }
    }

    if roots.is_empty() {
        return Err(Error::EmptyInput);
    }
    Ok(roots)
}

fn append_tree_ops(
    nodes: &[MarkdownNode],
    page_id: Id,
    parent_id: Option<Id>,
    lower: Option<&str>,
    upper: Option<&str>,
    ops: &mut Vec<Op>,
) -> Result<()> {
    let mut prev_key: Option<String> = lower.map(ToString::to_string);
    for node in nodes {
        let key = order::between(prev_key.as_deref(), upper)?;
        let id = Id::new();
        ops.push(Op::InsertBlock {
            id,
            page_id,
            parent_id,
            order_key: key.clone(),
            content: node.content.clone(),
        });
        if !node.children.is_empty() {
            append_tree_ops(&node.children, page_id, Some(id), None, None, ops)?;
        }
        prev_key = Some(key);
    }
    Ok(())
}

fn node_at_path_mut<'a>(roots: &'a mut [MarkdownNode], path: &[usize]) -> &'a mut MarkdownNode {
    let mut cur = &mut roots[path[0]];
    for &idx in &path[1..] {
        cur = &mut cur.children[idx];
    }
    cur
}

fn leading_indent(line: &str) -> usize {
    let mut count = 0;
    for b in line.bytes() {
        match b {
            b' ' => count += 1,
            b'\t' => count += 2,
            _ => break,
        }
    }
    count
}

fn strip_bullet(trimmed: &str) -> Option<&str> {
    trimmed
        .strip_prefix("- ")
        .or_else(|| trimmed.strip_prefix("* "))
}

fn is_hex_suffix(s: &str) -> bool {
    s.len() >= MIN_SHORT_ID_LEN && s.len() <= 32 && s.bytes().all(|b| b.is_ascii_hexdigit())
}
