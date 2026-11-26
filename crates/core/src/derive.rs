use std::collections::{BTreeSet, HashMap, HashSet};

use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};

use crate::error::{Error, Result};
use crate::id::Id;
use crate::parser::{self, RefTarget, Span};
use crate::snippet;
use crate::types::{Backlink, PropRecord, RenderedSpan, SearchHit};

pub struct DerivedRows {
    pub refs: Vec<(Id, String, Id)>,
    pub props: Vec<(Id, String, String, Option<Id>)>,
    pub task_state: Option<String>,
}

pub fn derive_rows(block_id: Id, content: &str) -> DerivedRows {
    let parsed = parser::parse_content(content);
    let mut refs = Vec::new();
    for r in parsed.refs {
        if let RefTarget::Id(target_id) = r.target {
            refs.push((block_id, r.kind.as_str().to_string(), target_id));
        }
    }
    let mut props = Vec::new();
    for prop in parsed.props {
        let value_ref = match prop.value_ref {
            Some(RefTarget::Id(id)) => Some(id),
            _ => None,
        };
        props.push((block_id, prop.key, prop.value, value_ref));
    }
    DerivedRows {
        refs,
        props,
        task_state: parsed.task_state,
    }
}

pub fn lookup_page_title(
    conn: &Connection,
    cache: &mut HashMap<Id, Option<String>>,
    page_id: Id,
) -> Result<Option<String>> {
    if let Some(cached) = cache.get(&page_id) {
        return Ok(cached.clone());
    }
    let title: Option<String> = conn
        .query_row(
            "SELECT title FROM pages WHERE id = ?1",
            params![page_id.as_bytes().as_slice()],
            |row| row.get(0),
        )
        .optional()?;
    cache.insert(page_id, title.clone());
    Ok(title)
}

pub fn render_content_with_cache(
    conn: &Connection,
    cache: &mut HashMap<Id, Option<String>>,
    content: &str,
) -> Result<String> {
    parser::render_page_refs(content, |id| lookup_page_title(conn, cache, id))
}

pub fn render_spans(
    conn: &Connection,
    cache: &mut HashMap<Id, Option<String>>,
    content: &str,
) -> Result<Vec<RenderedSpan>> {
    let mut pending_task = parser::parse_task_state(content);
    let mut out = Vec::new();
    for span in parser::tokenize(content) {
        let task = pending_task.take();
        match span {
            Span::Text(text) => {
                let leading = text.len() - text.trim_start().len();
                let remainder = match task.filter(|t| text[leading..].starts_with(t.as_str())) {
                    Some(state) => {
                        let keyword_end = leading + state.len();
                        out.push(RenderedSpan::Task {
                            source: text[..keyword_end].to_string(),
                            state,
                        });
                        &text[keyword_end..]
                    }
                    None => text,
                };
                if !remainder.is_empty() {
                    for inline in parser::tokenize_inline(remainder) {
                        out.push(match inline {
                            parser::InlineToken::Text(t) => RenderedSpan::Text(t.to_string()),
                            parser::InlineToken::Bold { inner, raw } => RenderedSpan::Bold {
                                text: inner.to_string(),
                                source: raw.to_string(),
                            },
                            parser::InlineToken::Italic { inner, raw } => RenderedSpan::Italic {
                                text: inner.to_string(),
                                source: raw.to_string(),
                            },
                            parser::InlineToken::Strike { inner, raw } => RenderedSpan::Strike {
                                text: inner.to_string(),
                                source: raw.to_string(),
                            },
                            parser::InlineToken::Highlight { inner, raw } => {
                                RenderedSpan::Highlight {
                                    text: inner.to_string(),
                                    source: raw.to_string(),
                                }
                            }
                            parser::InlineToken::ExternalLink { label, url, raw } => {
                                RenderedSpan::ExternalLink {
                                    label: label.to_string(),
                                    url: url.to_string(),
                                    source: raw.to_string(),
                                }
                            }
                        });
                    }
                }
            }
            Span::Code(code) => out.push(RenderedSpan::Code(code.to_string())),
            Span::PageLink { raw, target } => out.push(match target {
                RefTarget::Id(id) => match lookup_page_title(conn, cache, id)? {
                    Some(title) => RenderedSpan::PageLink {
                        page_id: Some(id),
                        source: parser::page_link_source(&title),
                        title,
                    },
                    None => RenderedSpan::Text(raw.to_string()),
                },
                RefTarget::Title(title) => RenderedSpan::PageLink {
                    page_id: None,
                    source: raw.to_string(),
                    title,
                },
            }),
            Span::BracketTag { raw, target } | Span::SimpleTag { raw, target } => {
                out.push(match target {
                    RefTarget::Id(id) => match lookup_page_title(conn, cache, id)? {
                        Some(title) => RenderedSpan::Tag {
                            page_id: Some(id),
                            source: parser::tag_source(&title),
                            title,
                        },
                        None => RenderedSpan::Text(raw.to_string()),
                    },
                    RefTarget::Title(title) => RenderedSpan::Tag {
                        page_id: None,
                        source: raw.to_string(),
                        title,
                    },
                })
            }
            Span::BlockRef { raw, id } => {
                let referenced: Option<String> = conn
                    .prepare_cached(
                        "SELECT content FROM blocks WHERE id = ?1 AND deleted_at IS NULL",
                    )?
                    .query_row(params![id.as_bytes().as_slice()], |r| r.get(0))
                    .optional()?;
                let text = match referenced {
                    Some(content) => {
                        let rendered = render_content_with_cache(conn, cache, &content)?;
                        rendered.lines().next().unwrap_or_default().to_string()
                    }
                    None => raw.to_string(),
                };
                out.push(RenderedSpan::BlockRef {
                    block_id: id,
                    text,
                    source: raw.to_string(),
                });
            }
        }
    }
    Ok(out)
}

pub fn sync_derived_in_tx(
    tx: &Transaction<'_>,
    touched_ids: &BTreeSet<Id>,
    renamed_pages: &BTreeSet<Id>,
) -> Result<()> {
    let mut block_ids: BTreeSet<Id> = BTreeSet::new();
    for &id in touched_ids {
        if !sync_single_page(tx, id)? {
            block_ids.insert(id);
        }
    }

    for &page_id in renamed_pages {
        let mut linking_blocks = tx.prepare_cached(
            "SELECT DISTINCT r.src_block
             FROM refs r
             JOIN blocks b ON b.id = r.src_block
             WHERE r.target = ?1 AND b.deleted_at IS NULL",
        )?;
        for row in linking_blocks.query_map(params![page_id.as_bytes().as_slice()], |r| {
            r.get::<_, Vec<u8>>(0)
        })? {
            let bytes = row?;
            let id = Id::from_slice(&bytes)
                .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
            block_ids.insert(id);
        }
    }

    let mut title_cache: HashMap<Id, Option<String>> = HashMap::new();
    for block_id in block_ids {
        sync_single_block(tx, block_id, &mut title_cache)?;
    }
    Ok(())
}

fn sync_single_page(tx: &Transaction<'_>, page_id: Id) -> Result<bool> {
    let row: Option<(i64, String, Option<i64>)> = tx
        .prepare_cached("SELECT seq, title, deleted_at FROM pages WHERE id = ?1")?
        .query_row(params![page_id.as_bytes().as_slice()], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .optional()?;
    let Some((seq, title, deleted_at)) = row else {
        return Ok(false);
    };
    tx.prepare_cached("DELETE FROM pages_fts WHERE rowid = ?1")?
        .execute(params![seq])?;
    if deleted_at.is_none() {
        tx.prepare_cached("INSERT INTO pages_fts (rowid, title) VALUES (?1, ?2)")?
            .execute(params![seq, title])?;
    }
    Ok(true)
}

fn write_derived(
    tx: &Transaction<'_>,
    seq: i64,
    block_id: Id,
    content: &str,
    title_cache: &mut HashMap<Id, Option<String>>,
) -> Result<()> {
    let derived = derive_rows(block_id, content);

    {
        let mut ref_stmt =
            tx.prepare_cached("INSERT INTO refs (src_block, kind, target) VALUES (?1, ?2, ?3)")?;
        for (src, kind, target) in &derived.refs {
            ref_stmt.execute(params![
                src.as_bytes().as_slice(),
                kind,
                target.as_bytes().as_slice(),
            ])?;
        }
    }

    {
        let mut prop_stmt = tx.prepare_cached(
            "INSERT INTO props (block_id, key, value, value_ref) VALUES (?1, ?2, ?3, ?4)",
        )?;
        for (bid, key, value, value_ref) in &derived.props {
            prop_stmt.execute(params![
                bid.as_bytes().as_slice(),
                key,
                value,
                value_ref.map(|id| id.as_bytes().to_vec()),
            ])?;
        }
    }

    if let Some(state) = &derived.task_state {
        let mut task_stmt =
            tx.prepare_cached("INSERT INTO tasks (block_id, state) VALUES (?1, ?2)")?;
        task_stmt.execute(params![block_id.as_bytes().as_slice(), state])?;
    }

    let search_text =
        parser::render_for_search(content, |id| lookup_page_title(tx, title_cache, id))?;
    tx.prepare_cached("INSERT INTO blocks_fts (rowid, text) VALUES (?1, ?2)")?
        .execute(params![seq, search_text])?;

    Ok(())
}

fn sync_single_block(
    tx: &Transaction<'_>,
    block_id: Id,
    title_cache: &mut HashMap<Id, Option<String>>,
) -> Result<()> {
    let row: Option<(i64, String, Option<i64>)> = tx
        .prepare_cached("SELECT seq, content, deleted_at FROM blocks WHERE id = ?1")?
        .query_row(params![block_id.as_bytes().as_slice()], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .optional()?;

    let Some((seq, content, deleted_at)) = row else {
        return Ok(());
    };

    tx.prepare_cached("DELETE FROM refs WHERE src_block = ?1")?
        .execute(params![block_id.as_bytes().as_slice()])?;
    tx.prepare_cached("DELETE FROM props WHERE block_id = ?1")?
        .execute(params![block_id.as_bytes().as_slice()])?;
    tx.prepare_cached("DELETE FROM tasks WHERE block_id = ?1")?
        .execute(params![block_id.as_bytes().as_slice()])?;
    tx.prepare_cached("DELETE FROM blocks_fts WHERE rowid = ?1")?
        .execute(params![seq])?;

    if deleted_at.is_some() {
        return Ok(());
    }

    write_derived(tx, seq, block_id, &content, title_cache)
}

pub fn rebuild_all(conn: &mut Connection) -> Result<()> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute_batch(
        "DELETE FROM refs; DELETE FROM props; DELETE FROM tasks;
         DELETE FROM blocks_fts; DELETE FROM pages_fts;",
    )?;

    let mut title_cache: HashMap<Id, Option<String>> = HashMap::new();
    {
        let mut page_stmt = tx.prepare("SELECT seq, id, title, deleted_at FROM pages")?;
        let mut page_fts = tx.prepare("INSERT INTO pages_fts (rowid, title) VALUES (?1, ?2)")?;
        for row in page_stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<i64>>(3)?,
            ))
        })? {
            let (seq, id_bytes, title, deleted_at) = row?;
            let id = Id::from_slice(&id_bytes)
                .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
            if deleted_at.is_none() {
                page_fts.execute(params![seq, title])?;
            }
            title_cache.insert(id, Some(title));
        }
    }

    let blocks: Vec<(i64, Id, String)> = {
        let mut stmt =
            tx.prepare("SELECT seq, id, content FROM blocks WHERE deleted_at IS NULL")?;
        let mut out = Vec::new();
        for row in stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, String>(2)?,
            ))
        })? {
            let (seq, id_b, content) = row?;
            let id = Id::from_slice(&id_b)
                .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
            out.push((seq, id, content));
        }
        out
    };

    for (seq, block_id, content) in blocks {
        write_derived(&tx, seq, block_id, &content, &mut title_cache)?;
    }

    tx.commit()?;
    Ok(())
}

pub fn search_blocks(conn: &Connection, query: &str, limit: usize) -> Result<Vec<SearchHit>> {
    let trimmed = query.trim();
    if trimmed.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }

    let mut title_cache: HashMap<Id, Option<String>> = HashMap::new();
    let mut hits = Vec::new();

    if trimmed.chars().count() < 3 {
        let lower = trimmed.to_lowercase();
        let upper = format!("{lower}\u{10FFFF}");
        let mut stmt = conn.prepare(
            "SELECT id, title
             FROM pages
             WHERE deleted_at IS NULL
               AND title_lower >= ?1
               AND title_lower <= ?2
             ORDER BY title_lower, id
             LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![lower, upper, limit as i64], |r| {
            Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (pid_b, title) = row?;
            let page_id = Id::from_slice(&pid_b)
                .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
            hits.push(SearchHit::Page {
                page_id,
                highlighted_title: snippet::highlight(&title, trimmed),
                title,
            });
        }
        return Ok(hits);
    }

    let Some(match_expr) = build_trigram_query(trimmed) else {
        return Ok(Vec::new());
    };

    let mut page_stmt = conn.prepare(
        "SELECT p.id, p.title
         FROM pages_fts
         JOIN pages p ON p.seq = pages_fts.rowid
         WHERE pages_fts MATCH ?1 AND p.deleted_at IS NULL
         ORDER BY bm25(pages_fts), p.title_lower, p.id
         LIMIT ?2",
    )?;
    let page_rows = page_stmt.query_map(params![match_expr, limit as i64], |r| {
        Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, String>(1)?))
    })?;
    for row in page_rows {
        let (pid_b, title) = row?;
        let page_id = Id::from_slice(&pid_b)
            .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
        hits.push(SearchHit::Page {
            page_id,
            highlighted_title: snippet::highlight(&title, trimmed),
            title,
        });
    }

    let remaining = limit - hits.len();
    if remaining == 0 {
        return Ok(hits);
    }

    let mut block_stmt = conn.prepare(
        "SELECT b.id, b.page_id, p.title, b.content, bm25(blocks_fts)
         FROM blocks_fts
         JOIN blocks b ON b.seq = blocks_fts.rowid
         JOIN pages p ON p.id = b.page_id
         WHERE blocks_fts MATCH ?1 AND b.deleted_at IS NULL AND p.deleted_at IS NULL
         ORDER BY bm25(blocks_fts), b.id
         LIMIT ?2",
    )?;
    let block_rows = block_stmt.query_map(params![match_expr, remaining as i64], |r| {
        Ok((
            r.get::<_, Vec<u8>>(0)?,
            r.get::<_, Vec<u8>>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, f64>(4)?,
        ))
    })?;
    for row in block_rows {
        let (bid_b, pid_b, page_title, content, rank) = row?;
        let block_id = Id::from_slice(&bid_b)
            .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
        let page_id = Id::from_slice(&pid_b)
            .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
        let rendered_content = render_content_with_cache(conn, &mut title_cache, &content)?;
        let mut breadcrumb = vec![page_title.clone()];
        breadcrumb.extend(ancestor_crumbs(conn, &mut title_cache, block_id)?);
        for line in snippet::matching_lines(&rendered_content, trimmed) {
            if hits.len() >= limit {
                return Ok(hits);
            }
            hits.push(SearchHit::Block {
                block_id,
                page_id,
                page_title: page_title.clone(),
                breadcrumb: breadcrumb.clone(),
                snippet: line.segments,
                cursor: line.cursor as u32,
                rank,
            });
        }
    }

    Ok(hits)
}

fn ancestor_crumbs(
    conn: &Connection,
    cache: &mut HashMap<Id, Option<String>>,
    block_id: Id,
) -> Result<Vec<String>> {
    let mut crumbs = Vec::new();
    let mut parent_stmt = conn.prepare_cached("SELECT parent_id FROM blocks WHERE id = ?1")?;
    let mut content_stmt = conn.prepare_cached("SELECT content FROM blocks WHERE id = ?1")?;
    let mut current = block_id;
    while let Some(parent_bytes) = parent_stmt
        .query_row(params![current.as_bytes().as_slice()], |r| {
            r.get::<_, Option<Vec<u8>>>(0)
        })
        .optional()?
        .flatten()
    {
        let parent = Id::from_slice(&parent_bytes)
            .ok_or_else(|| Error::InvariantViolation("invalid parent id bytes".to_string()))?;
        let content: String =
            content_stmt.query_row(params![parent.as_bytes().as_slice()], |r| r.get(0))?;
        crumbs.push(snippet::crumb(&render_content_with_cache(
            conn, cache, &content,
        )?));
        current = parent;
    }
    crumbs.reverse();
    Ok(crumbs)
}

pub fn query_backlinks(conn: &Connection, target: Id) -> Result<Vec<Backlink>> {
    let mut stmt = conn.prepare(
        "SELECT b.id, b.page_id, p.title, r.kind, b.content
         FROM refs r
         JOIN blocks b ON b.id = r.src_block
         JOIN pages p ON p.id = b.page_id
         WHERE r.target = ?1 AND b.deleted_at IS NULL AND p.deleted_at IS NULL
         ORDER BY p.title_lower, b.order_key, b.id, r.kind",
    )?;
    let mut title_cache: HashMap<Id, Option<String>> = HashMap::new();
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let rows = stmt.query_map(params![target.as_bytes().as_slice()], |r| {
        Ok((
            r.get::<_, Vec<u8>>(0)?,
            r.get::<_, Vec<u8>>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
        ))
    })?;
    for row in rows {
        let (bid_b, pid_b, page_title, kind, content) = row?;
        let block_id = Id::from_slice(&bid_b)
            .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
        if !seen.insert(block_id) {
            continue;
        }
        let page_id = Id::from_slice(&pid_b)
            .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
        let rendered_content = render_content_with_cache(conn, &mut title_cache, &content)?;
        let spans = render_spans(conn, &mut title_cache, &content)?;
        out.push(Backlink {
            block_id,
            page_id,
            page_title,
            kind,
            rendered_content,
            spans,
        });
    }
    Ok(out)
}

pub fn query_props(conn: &Connection, key: &str, value: Option<&str>) -> Result<Vec<PropRecord>> {
    let mut out = Vec::new();
    match value {
        Some(v) => {
            let mut stmt = conn.prepare(
                "SELECT pr.block_id, pr.key, pr.value, pr.value_ref
                 FROM props pr
                 JOIN blocks b ON b.id = pr.block_id
                 WHERE pr.key = ?1 AND pr.value = ?2 AND b.deleted_at IS NULL
                 ORDER BY b.id",
            )?;
            let rows = stmt.query_map(params![key, v], row_to_prop)?;
            for row in rows {
                out.push(row?);
            }
        }
        None => {
            let mut stmt = conn.prepare(
                "SELECT pr.block_id, pr.key, pr.value, pr.value_ref
                 FROM props pr
                 JOIN blocks b ON b.id = pr.block_id
                 WHERE pr.key = ?1 AND b.deleted_at IS NULL
                 ORDER BY b.id",
            )?;
            let rows = stmt.query_map(params![key], row_to_prop)?;
            for row in rows {
                out.push(row?);
            }
        }
    }
    Ok(out)
}

pub fn verify_derived_invariants(conn: &Connection) -> Result<()> {
    let mut title_cache: HashMap<Id, Option<String>> = HashMap::new();
    let live_block_rows: Vec<(i64, Id, String)> = {
        let mut stmt =
            conn.prepare("SELECT seq, id, content FROM blocks WHERE deleted_at IS NULL")?;
        let mut out = Vec::new();
        for row in stmt.query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, String>(2)?,
            ))
        })? {
            let (seq, id_b, content) = row?;
            let id = Id::from_slice(&id_b)
                .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
            out.push((seq, id, content));
        }
        out
    };

    let live_ids: HashSet<Id> = live_block_rows.iter().map(|(_, id, _)| *id).collect();
    let mut expected_refs: Vec<(Id, String, Id)> = Vec::new();
    let mut expected_props: Vec<(Id, String, String, Option<Id>)> = Vec::new();
    let mut expected_tasks: HashMap<Id, String> = HashMap::new();
    let mut expected_fts: HashMap<i64, String> = HashMap::new();

    for (seq, id, content) in &live_block_rows {
        let derived = derive_rows(*id, content);
        expected_refs.extend(derived.refs);
        expected_props.extend(derived.props);
        if let Some(state) = derived.task_state {
            expected_tasks.insert(*id, state);
        }
        let search_text = parser::render_for_search(content, |pid| {
            lookup_page_title(conn, &mut title_cache, pid)
        })?;
        expected_fts.insert(*seq, search_text);
    }
    expected_refs.sort();
    expected_props.sort();

    let mut actual_refs: Vec<(Id, String, Id)> = Vec::new();
    {
        let mut stmt = conn.prepare("SELECT src_block, kind, target FROM refs")?;
        for row in stmt.query_map([], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Vec<u8>>(2)?,
            ))
        })? {
            let (src_b, kind, tgt_b) = row?;
            let src = Id::from_slice(&src_b)
                .ok_or_else(|| Error::InvariantViolation("invalid ref src bytes".to_string()))?;
            let tgt = Id::from_slice(&tgt_b)
                .ok_or_else(|| Error::InvariantViolation("invalid ref target bytes".to_string()))?;
            if !live_ids.contains(&src) {
                return Err(Error::InvariantViolation(format!(
                    "refs contains row for non-live block {src}"
                )));
            }
            actual_refs.push((src, kind, tgt));
        }
    }
    actual_refs.sort();
    if actual_refs != expected_refs {
        return Err(Error::InvariantViolation(
            "refs table does not match parsed block content".to_string(),
        ));
    }

    let actual_ref_pairs: HashSet<(Id, Id)> = actual_refs
        .iter()
        .map(|(src, _, target)| (*src, *target))
        .collect();
    for (_, id, content) in &live_block_rows {
        for span in parser::tokenize(content) {
            let target = match span {
                Span::PageLink {
                    target: RefTarget::Id(tid),
                    ..
                }
                | Span::BracketTag {
                    target: RefTarget::Id(tid),
                    ..
                }
                | Span::SimpleTag {
                    target: RefTarget::Id(tid),
                    ..
                } => Some(tid),
                Span::BlockRef { id: tid, .. } => Some(tid),
                _ => None,
            };
            if let Some(tid) = target
                && !actual_ref_pairs.contains(&(*id, tid))
            {
                return Err(Error::InvariantViolation(format!(
                    "tokenized ref {tid} in block {id} missing from refs table"
                )));
            }
        }
    }

    let mut actual_props: Vec<(Id, String, String, Option<Id>)> = Vec::new();
    {
        let mut stmt = conn.prepare("SELECT block_id, key, value, value_ref FROM props")?;
        for row in stmt.query_map([], row_to_prop)? {
            let p = row?;
            if !live_ids.contains(&p.block_id) {
                return Err(Error::InvariantViolation(format!(
                    "props contains row for non-live block {}",
                    p.block_id
                )));
            }
            actual_props.push((p.block_id, p.key, p.value, p.value_ref));
        }
    }
    actual_props.sort();
    if actual_props != expected_props {
        return Err(Error::InvariantViolation(
            "props table does not match parsed block content".to_string(),
        ));
    }

    let mut actual_tasks: HashMap<Id, String> = HashMap::new();
    {
        let mut stmt = conn.prepare("SELECT block_id, state FROM tasks")?;
        for row in stmt.query_map([], |r| {
            Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, String>(1)?))
        })? {
            let (bid_b, state) = row?;
            let bid = Id::from_slice(&bid_b)
                .ok_or_else(|| Error::InvariantViolation("invalid task block_id".to_string()))?;
            if !live_ids.contains(&bid) {
                return Err(Error::InvariantViolation(format!(
                    "tasks contains row for non-live block {bid}"
                )));
            }
            actual_tasks.insert(bid, state);
        }
    }
    if actual_tasks != expected_tasks {
        return Err(Error::InvariantViolation(
            "tasks table does not match parsed block content".to_string(),
        ));
    }

    let actual_fts: HashMap<i64, String> = conn
        .prepare("SELECT rowid, text FROM blocks_fts")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    if actual_fts != expected_fts {
        return Err(Error::InvariantViolation(
            "blocks_fts does not match rendered live blocks".to_string(),
        ));
    }

    let expected_page_fts: HashMap<i64, String> = conn
        .prepare("SELECT seq, title FROM pages WHERE deleted_at IS NULL")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let actual_page_fts: HashMap<i64, String> = conn
        .prepare("SELECT rowid, title FROM pages_fts")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    if actual_page_fts != expected_page_fts {
        return Err(Error::InvariantViolation(
            "pages_fts does not match live page titles".to_string(),
        ));
    }

    Ok(())
}

fn row_to_prop(row: &rusqlite::Row<'_>) -> rusqlite::Result<PropRecord> {
    let bid_b: Vec<u8> = row.get(0)?;
    let block_id = Id::from_slice(&bid_b).ok_or(rusqlite::Error::InvalidQuery)?;
    let vref_b: Option<Vec<u8>> = row.get(3)?;
    let value_ref = match vref_b {
        Some(b) => Some(Id::from_slice(&b).ok_or(rusqlite::Error::InvalidQuery)?),
        None => None,
    };
    Ok(PropRecord {
        block_id,
        key: row.get(1)?,
        value: row.get(2)?,
        value_ref,
    })
}

fn build_trigram_query(query: &str) -> Option<String> {
    let tokens: Vec<&str> = query.split_whitespace().collect();
    if tokens.is_empty() {
        return None;
    }
    if tokens.iter().all(|t| t.chars().count() >= 3) {
        let parts: Vec<String> = tokens
            .iter()
            .map(|t| format!("\"{}\"", t.replace('"', "\"\"")))
            .collect();
        return Some(parts.join(" "));
    }
    let escaped = query.replace('"', "\"\"");
    Some(format!("\"{escaped}\""))
}
