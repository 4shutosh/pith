use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Row, Transaction, TransactionBehavior, params};

use crate::error::{Error, Result};
use crate::id::Id;
use crate::ops::Op;
use crate::schema::configure_and_migrate;
use crate::types::{ApplyResult, Block, OpRecord, Origin, Page, TxMeta, TxnRecord};

pub struct Store {
    conn: Connection,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LivePageState {
    pub id: Id,
    pub title: String,
    pub journal_day: Option<i32>,
    pub document_mode: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveBlockState {
    pub id: Id,
    pub page_id: Id,
    pub parent_id: Option<Id>,
    pub order_key: String,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveSnapshot {
    pub pages: BTreeMap<Id, LivePageState>,
    pub blocks: BTreeMap<Id, LiveBlockState>,
}

struct AppliedOp {
    forward: Op,
    inverse: Vec<Op>,
    touched: Vec<Id>,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let mut conn = Connection::open(path)?;
        configure_and_migrate(&mut conn)?;
        Ok(Self { conn })
    }

    pub fn open_in_memory() -> Result<Self> {
        let mut conn = Connection::open_in_memory()?;
        configure_and_migrate(&mut conn)?;
        Ok(Self { conn })
    }

    pub fn apply_ops(&mut self, ops: &[Op], meta: &TxMeta) -> Result<ApplyResult> {
        if meta.origin == Origin::Undo {
            return Err(Error::ReservedOrigin(Origin::Undo));
        }
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let result = apply_in_tx(&tx, ops, meta, None)?;
        tx.commit()?;
        Ok(result)
    }

    pub fn undo(&mut self, txn_id: Id, meta: &TxMeta, force: bool) -> Result<ApplyResult> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;

        let (target_rowid, target_txn) = fetch_txn_with_rowid(&tx, txn_id)?;
        if txn_is_undone(&tx, txn_id)? {
            return Err(Error::AlreadyUndone(txn_id));
        }
        if !force {
            ensure_no_later_foreign_edits(&tx, txn_id, target_rowid, &target_txn.actor)?;
        }

        let inverse_ops: Vec<Op> = fetch_txn_ops(&tx, txn_id)?
            .into_iter()
            .rev()
            .flat_map(|record| record.inverse)
            .collect();

        let undo_meta = TxMeta {
            origin: Origin::Undo,
            actor: meta.actor.clone(),
            session: meta.session.clone(),
            summary: if meta.summary.is_empty() {
                format!("undo {txn_id}")
            } else {
                meta.summary.clone()
            },
        };

        let result = apply_in_tx(&tx, &inverse_ops, &undo_meta, Some(txn_id))
            .map_err(|err| as_undo_conflict(txn_id, err))?;
        tx.commit()?;
        Ok(result)
    }

    pub fn is_undone(&self, txn_id: Id) -> Result<bool> {
        txn_is_undone(&self.conn, txn_id)
    }

    pub fn get_page(&self, id: Id) -> Result<Option<Page>> {
        self.conn
            .query_row(
                "SELECT id, title, title_lower, journal_day, document_mode,
                        created_at, updated_at, created_by, updated_by, deleted_at, version
                 FROM pages WHERE id = ?1",
                params![id.as_bytes().as_slice()],
                row_to_page,
            )
            .optional()
            .map_err(Error::from)
    }

    pub fn get_page_by_title(&self, title: &str) -> Result<Option<Page>> {
        let lower = title.to_lowercase();
        self.conn
            .query_row(
                "SELECT id, title, title_lower, journal_day, document_mode,
                        created_at, updated_at, created_by, updated_by, deleted_at, version
                 FROM pages WHERE title_lower = ?1 AND deleted_at IS NULL",
                params![lower],
                row_to_page,
            )
            .optional()
            .map_err(Error::from)
    }

    pub fn list_live_pages(&self) -> Result<Vec<Page>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, title, title_lower, journal_day, document_mode,
                    created_at, updated_at, created_by, updated_by, deleted_at, version
             FROM pages WHERE deleted_at IS NULL ORDER BY title_lower, id",
        )?;
        let rows = stmt.query_map([], row_to_page)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn get_block(&self, id: Id) -> Result<Option<Block>> {
        self.conn
            .query_row(
                "SELECT id, page_id, parent_id, order_key, content, collapsed,
                        created_at, updated_at, created_by, updated_by, deleted_at, version
                 FROM blocks WHERE id = ?1",
                params![id.as_bytes().as_slice()],
                row_to_block,
            )
            .optional()
            .map_err(Error::from)
    }

    pub fn list_children(&self, page_id: Id, parent_id: Option<Id>) -> Result<Vec<Block>> {
        let mut out = Vec::new();
        match parent_id {
            Some(pid) => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, page_id, parent_id, order_key, content, collapsed,
                            created_at, updated_at, created_by, updated_by, deleted_at, version
                     FROM blocks
                     WHERE page_id = ?1 AND parent_id = ?2 AND deleted_at IS NULL
                     ORDER BY order_key, id",
                )?;
                let rows = stmt.query_map(
                    params![page_id.as_bytes().as_slice(), pid.as_bytes().as_slice()],
                    row_to_block,
                )?;
                for row in rows {
                    out.push(row?);
                }
            }
            None => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, page_id, parent_id, order_key, content, collapsed,
                            created_at, updated_at, created_by, updated_by, deleted_at, version
                     FROM blocks
                     WHERE page_id = ?1 AND parent_id IS NULL AND deleted_at IS NULL
                     ORDER BY order_key, id",
                )?;
                let rows = stmt.query_map(params![page_id.as_bytes().as_slice()], row_to_block)?;
                for row in rows {
                    out.push(row?);
                }
            }
        }
        Ok(out)
    }

    pub fn list_live_blocks(&self, page_id: Id) -> Result<Vec<Block>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, page_id, parent_id, order_key, content, collapsed,
                    created_at, updated_at, created_by, updated_by, deleted_at, version
             FROM blocks
             WHERE page_id = ?1 AND deleted_at IS NULL
             ORDER BY order_key, id",
        )?;
        let rows = stmt.query_map(params![page_id.as_bytes().as_slice()], row_to_block)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn list_txns(&self, actor: Option<&str>) -> Result<Vec<TxnRecord>> {
        let mut out = Vec::new();
        match actor {
            Some(actor_name) => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, ts, origin, actor, session, summary, undoes
                     FROM txns WHERE actor = ?1 ORDER BY rowid DESC",
                )?;
                let rows = stmt.query_map(params![actor_name], row_to_txn)?;
                for row in rows {
                    out.push(row?);
                }
            }
            None => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, ts, origin, actor, session, summary, undoes
                     FROM txns ORDER BY rowid DESC",
                )?;
                let rows = stmt.query_map([], row_to_txn)?;
                for row in rows {
                    out.push(row?);
                }
            }
        }
        Ok(out)
    }

    pub fn get_txn_ops(&self, txn_id: Id) -> Result<Vec<OpRecord>> {
        fetch_txn_ops(&self.conn, txn_id)
    }

    pub fn live_snapshot(&self) -> Result<LiveSnapshot> {
        let mut pages = BTreeMap::new();
        for page in self.list_live_pages()? {
            pages.insert(
                page.id,
                LivePageState {
                    id: page.id,
                    title: page.title,
                    journal_day: page.journal_day,
                    document_mode: page.document_mode,
                },
            );
        }

        let mut stmt = self.conn.prepare(
            "SELECT id, page_id, parent_id, order_key, content, collapsed,
                    created_at, updated_at, created_by, updated_by, deleted_at, version
             FROM blocks WHERE deleted_at IS NULL",
        )?;
        let rows = stmt.query_map([], row_to_block)?;
        let mut blocks = BTreeMap::new();
        for row in rows {
            let block = row?;
            blocks.insert(
                block.id,
                LiveBlockState {
                    id: block.id,
                    page_id: block.page_id,
                    parent_id: block.parent_id,
                    order_key: block.order_key,
                    content: block.content,
                },
            );
        }

        Ok(LiveSnapshot { pages, blocks })
    }

    pub fn check_invariants(&self) -> Result<()> {
        verify_invariants_conn(&self.conn)
    }
}

fn apply_in_tx(
    tx: &Transaction<'_>,
    ops: &[Op],
    meta: &TxMeta,
    undoes: Option<Id>,
) -> Result<ApplyResult> {
    let now = now_millis();
    let mut applied_content = Vec::new();
    let mut all_touched = BTreeSet::new();

    for op in ops {
        let applied = apply_single_op(tx, op, meta, now)?;
        if !op.is_view_state() {
            all_touched.extend(applied.touched.iter().copied());
            applied_content.push(applied);
        }
    }

    verify_touched_invariants(tx, &all_touched)?;

    if applied_content.is_empty() {
        return Ok(ApplyResult {
            txn_id: None,
            inverse_ops: Vec::new(),
        });
    }

    let txn_id = Id::new();
    tx.execute(
        "INSERT INTO txns (id, ts, origin, actor, session, summary, undoes)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            txn_id.as_bytes().as_slice(),
            now,
            meta.origin.as_str(),
            meta.actor,
            meta.session,
            meta.summary,
            undoes.map(|id| id.as_bytes().to_vec()),
        ],
    )?;

    for (seq, item) in applied_content.iter().enumerate() {
        tx.execute(
            "INSERT INTO ops (txn_id, seq, forward, inverse)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                txn_id.as_bytes().as_slice(),
                seq as i64,
                serde_json::to_string(&item.forward)?,
                serde_json::to_string(&item.inverse)?,
            ],
        )?;
    }

    for entity_id in &all_touched {
        tx.execute(
            "INSERT INTO txn_blocks (txn_id, block_id) VALUES (?1, ?2)",
            params![
                txn_id.as_bytes().as_slice(),
                entity_id.as_bytes().as_slice(),
            ],
        )?;
    }

    let inverse_ops = applied_content
        .iter()
        .rev()
        .flat_map(|item| item.inverse.iter().cloned())
        .collect();

    Ok(ApplyResult {
        txn_id: Some(txn_id),
        inverse_ops,
    })
}

fn as_undo_conflict(txn_id: Id, err: Error) -> Error {
    match err {
        Error::PageTitleExists { id, title } => Error::UndoConflict {
            txn_id,
            entity_id: id,
            reason: format!("page title already in use: {title}"),
        },
        Error::JournalDayExists { id, journal_day } => Error::UndoConflict {
            txn_id,
            entity_id: id,
            reason: format!("journal day already in use: {journal_day}"),
        },
        other => other,
    }
}

fn fetch_txn_with_rowid(conn: &Connection, txn_id: Id) -> Result<(i64, TxnRecord)> {
    conn.query_row(
        "SELECT rowid, id, ts, origin, actor, session, summary, undoes
         FROM txns WHERE id = ?1",
        params![txn_id.as_bytes().as_slice()],
        |row| {
            let rowid: i64 = row.get(0)?;
            let txn = row_to_txn_offset(row, 1)?;
            Ok((rowid, txn))
        },
    )
    .optional()?
    .ok_or(Error::TxnNotFound(txn_id))
}

fn fetch_txn_ops(conn: &Connection, txn_id: Id) -> Result<Vec<OpRecord>> {
    let mut stmt = conn.prepare(
        "SELECT seq, forward, inverse
         FROM ops WHERE txn_id = ?1 ORDER BY seq ASC",
    )?;
    let rows = stmt.query_map(params![txn_id.as_bytes().as_slice()], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;

    let mut out = Vec::new();
    for row in rows {
        let (seq, forward, inverse) = row?;
        out.push(OpRecord {
            txn_id,
            seq,
            forward: serde_json::from_str(&forward)?,
            inverse: serde_json::from_str(&inverse)?,
        });
    }
    Ok(out)
}

fn txn_is_undone(conn: &Connection, txn_id: Id) -> Result<bool> {
    let mut stmt = conn.prepare("SELECT id FROM txns WHERE undoes = ?1")?;
    let undoers = stmt
        .query_map(params![txn_id.as_bytes().as_slice()], |row| {
            row.get::<_, Vec<u8>>(0)
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for bytes in undoers {
        let undoer = Id::from_slice(&bytes)
            .ok_or_else(|| Error::InvariantViolation("invalid txn id bytes".to_string()))?;
        if !txn_is_undone(conn, undoer)? {
            return Ok(true);
        }
    }
    Ok(false)
}

fn ensure_no_later_foreign_edits(
    conn: &Connection,
    txn_id: Id,
    target_rowid: i64,
    original_actor: &str,
) -> Result<()> {
    let conflict: Option<(Vec<u8>, String)> = conn
        .query_row(
            "SELECT tb_later.block_id, t_later.actor
             FROM txn_blocks tb_orig
             JOIN txn_blocks tb_later ON tb_orig.block_id = tb_later.block_id
             JOIN txns t_later ON tb_later.txn_id = t_later.id
             WHERE tb_orig.txn_id = ?1
               AND t_later.rowid > ?2
               AND t_later.actor != ?3
             ORDER BY t_later.rowid ASC
             LIMIT 1",
            params![txn_id.as_bytes().as_slice(), target_rowid, original_actor],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;

    match conflict {
        Some((entity_bytes, other_actor)) => {
            let entity_id = Id::from_slice(&entity_bytes).ok_or_else(|| {
                Error::InvariantViolation("invalid entity id in txn_blocks".to_string())
            })?;
            Err(Error::UndoConflict {
                txn_id,
                entity_id,
                reason: format!("modified later by actor {other_actor}"),
            })
        }
        None => Ok(()),
    }
}

fn apply_single_op(tx: &Transaction<'_>, op: &Op, meta: &TxMeta, now: i64) -> Result<AppliedOp> {
    match op {
        Op::CreatePage {
            id,
            title,
            journal_day,
            document_mode,
        } => {
            if fetch_page(tx, *id)?.is_some() {
                return Err(Error::AlreadyExists(*id));
            }
            let title_lower = title.to_lowercase();
            ensure_page_title_available(tx, *id, &title_lower, None, title)?;
            if let Some(day) = journal_day {
                ensure_journal_day_available(tx, *id, *day, None)?;
            }

            tx.execute(
                "INSERT INTO pages (
                    id, title, title_lower, journal_day, document_mode,
                    created_at, updated_at, created_by, updated_by, deleted_at, version
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL, 1)",
                params![
                    id.as_bytes().as_slice(),
                    title,
                    title_lower,
                    journal_day,
                    i64::from(*document_mode),
                    now,
                    now,
                    meta.actor,
                    meta.actor,
                ],
            )?;

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: vec![Op::DeletePage {
                    id: *id,
                    expected_version: None,
                }],
                touched: vec![*id],
            })
        }

        Op::RenamePage {
            id,
            title,
            expected_version,
        } => {
            let page = require_live_page(tx, *id)?;
            check_version(*id, *expected_version, page.version)?;

            let title_lower = title.to_lowercase();
            ensure_page_title_available(tx, *id, &title_lower, Some(*id), title)?;

            tx.execute(
                "UPDATE pages
                 SET title = ?1, title_lower = ?2, updated_at = ?3, updated_by = ?4, version = version + 1
                 WHERE id = ?5",
                params![title, title_lower, now, meta.actor, id.as_bytes().as_slice()],
            )?;

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: vec![Op::RenamePage {
                    id: *id,
                    title: page.title,
                    expected_version: None,
                }],
                touched: vec![*id],
            })
        }

        Op::DeletePage {
            id,
            expected_version,
        } => {
            let page = require_live_page(tx, *id)?;
            check_version(*id, *expected_version, page.version)?;

            let live_blocks = collect_page_live_blocks_top_down(tx, *id)?;

            tx.execute(
                "UPDATE pages
                 SET deleted_at = ?1, updated_at = ?1, updated_by = ?2, version = version + 1
                 WHERE id = ?3",
                params![now, meta.actor, id.as_bytes().as_slice()],
            )?;

            let mut inverse = Vec::with_capacity(1 + live_blocks.len());
            inverse.push(Op::RestorePage { id: *id });

            let mut touched = Vec::with_capacity(1 + live_blocks.len());
            touched.push(*id);

            for block_id in live_blocks {
                tx.execute(
                    "UPDATE blocks
                     SET deleted_at = ?1, updated_at = ?1, updated_by = ?2, version = version + 1
                     WHERE id = ?3",
                    params![now, meta.actor, block_id.as_bytes().as_slice()],
                )?;
                inverse.push(Op::RestoreBlock { id: block_id });
                touched.push(block_id);
            }

            Ok(AppliedOp {
                forward: op.clone(),
                inverse,
                touched,
            })
        }

        Op::RestorePage { id } => {
            let page = fetch_page(tx, *id)?.ok_or(Error::NotFound(*id))?;
            if page.deleted_at.is_none() {
                return Err(Error::AlreadyExists(*id));
            }
            ensure_page_title_available(tx, *id, &page.title_lower, Some(*id), &page.title)?;
            if let Some(day) = page.journal_day {
                ensure_journal_day_available(tx, *id, day, Some(*id))?;
            }

            tx.execute(
                "UPDATE pages
                 SET deleted_at = NULL, updated_at = ?1, updated_by = ?2, version = version + 1
                 WHERE id = ?3",
                params![now, meta.actor, id.as_bytes().as_slice()],
            )?;

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: vec![Op::DeletePage {
                    id: *id,
                    expected_version: None,
                }],
                touched: vec![*id],
            })
        }

        Op::InsertBlock {
            id,
            page_id,
            parent_id,
            order_key,
            content,
        } => {
            if fetch_block(tx, *id)?.is_some() {
                return Err(Error::AlreadyExists(*id));
            }
            require_live_page(tx, *page_id)?;
            if let Some(pid) = parent_id {
                let parent = require_live_block(tx, *pid)?;
                if parent.page_id != *page_id {
                    return Err(Error::ParentPageMismatch {
                        parent_id: *pid,
                        page_id: *page_id,
                    });
                }
            }

            tx.execute(
                "INSERT INTO blocks (
                    id, page_id, parent_id, order_key, content, collapsed,
                    created_at, updated_at, created_by, updated_by, deleted_at, version
                 ) VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9, NULL, 1)",
                params![
                    id.as_bytes().as_slice(),
                    page_id.as_bytes().as_slice(),
                    parent_id.map(|p| p.as_bytes().to_vec()),
                    order_key,
                    content,
                    now,
                    now,
                    meta.actor,
                    meta.actor,
                ],
            )?;

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: vec![Op::DeleteBlock {
                    id: *id,
                    expected_version: None,
                }],
                touched: vec![*id],
            })
        }

        Op::UpdateBlock {
            id,
            content,
            expected_version,
        } => {
            let block = require_live_block(tx, *id)?;
            check_version(*id, *expected_version, block.version)?;

            tx.execute(
                "UPDATE blocks
                 SET content = ?1, updated_at = ?2, updated_by = ?3, version = version + 1
                 WHERE id = ?4",
                params![content, now, meta.actor, id.as_bytes().as_slice()],
            )?;

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: vec![Op::UpdateBlock {
                    id: *id,
                    content: block.content,
                    expected_version: None,
                }],
                touched: vec![*id],
            })
        }

        Op::MoveBlock {
            id,
            page_id,
            parent_id,
            order_key,
            expected_version,
        } => {
            let block = require_live_block(tx, *id)?;
            check_version(*id, *expected_version, block.version)?;
            require_live_page(tx, *page_id)?;

            if let Some(pid) = parent_id {
                if *pid == *id {
                    return Err(Error::CycleDetected(*id));
                }
                let parent = require_live_block(tx, *pid)?;
                if parent.page_id != *page_id {
                    return Err(Error::ParentPageMismatch {
                        parent_id: *pid,
                        page_id: *page_id,
                    });
                }
                ensure_not_ancestor(tx, *id, *pid)?;
            }

            tx.execute(
                "UPDATE blocks
                 SET page_id = ?1, parent_id = ?2, order_key = ?3,
                     updated_at = ?4, updated_by = ?5, version = version + 1
                 WHERE id = ?6",
                params![
                    page_id.as_bytes().as_slice(),
                    parent_id.map(|p| p.as_bytes().to_vec()),
                    order_key,
                    now,
                    meta.actor,
                    id.as_bytes().as_slice(),
                ],
            )?;

            let mut touched = vec![*id];
            if *page_id != block.page_id {
                let descendants = collect_live_descendants(tx, *id)?;
                for desc_id in descendants {
                    tx.execute(
                        "UPDATE blocks
                         SET page_id = ?1, updated_at = ?2, updated_by = ?3, version = version + 1
                         WHERE id = ?4",
                        params![
                            page_id.as_bytes().as_slice(),
                            now,
                            meta.actor,
                            desc_id.as_bytes().as_slice(),
                        ],
                    )?;
                    touched.push(desc_id);
                }
            }

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: vec![Op::MoveBlock {
                    id: *id,
                    page_id: block.page_id,
                    parent_id: block.parent_id,
                    order_key: block.order_key,
                    expected_version: None,
                }],
                touched,
            })
        }

        Op::DeleteBlock {
            id,
            expected_version,
        } => {
            let block = require_live_block(tx, *id)?;
            check_version(*id, *expected_version, block.version)?;

            let mut to_delete = vec![*id];
            to_delete.extend(collect_live_descendants(tx, *id)?);

            let mut inverse = Vec::with_capacity(to_delete.len());
            for bid in &to_delete {
                tx.execute(
                    "UPDATE blocks
                     SET deleted_at = ?1, updated_at = ?1, updated_by = ?2, version = version + 1
                     WHERE id = ?3",
                    params![now, meta.actor, bid.as_bytes().as_slice()],
                )?;
                inverse.push(Op::RestoreBlock { id: *bid });
            }

            Ok(AppliedOp {
                forward: op.clone(),
                inverse,
                touched: to_delete,
            })
        }

        Op::RestoreBlock { id } => {
            let block = fetch_block(tx, *id)?.ok_or(Error::NotFound(*id))?;
            if block.deleted_at.is_none() {
                return Err(Error::AlreadyExists(*id));
            }
            require_live_page(tx, block.page_id)?;
            if let Some(pid) = block.parent_id {
                let parent = require_live_block(tx, pid)?;
                if parent.page_id != block.page_id {
                    return Err(Error::ParentPageMismatch {
                        parent_id: pid,
                        page_id: block.page_id,
                    });
                }
            }

            tx.execute(
                "UPDATE blocks
                 SET deleted_at = NULL, updated_at = ?1, updated_by = ?2, version = version + 1
                 WHERE id = ?3",
                params![now, meta.actor, id.as_bytes().as_slice()],
            )?;

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: vec![Op::DeleteBlock {
                    id: *id,
                    expected_version: None,
                }],
                touched: vec![*id],
            })
        }

        Op::SetCollapsed { id, collapsed } => {
            require_live_block(tx, *id)?;
            tx.execute(
                "UPDATE blocks SET collapsed = ?1 WHERE id = ?2",
                params![i64::from(*collapsed), id.as_bytes().as_slice()],
            )?;

            Ok(AppliedOp {
                forward: op.clone(),
                inverse: Vec::new(),
                touched: Vec::new(),
            })
        }
    }
}

fn verify_touched_invariants(tx: &Transaction<'_>, touched: &BTreeSet<Id>) -> Result<()> {
    for &entity_id in touched {
        if let Some(block) = fetch_block(tx, entity_id)? {
            if block.deleted_at.is_none() {
                let page = fetch_page(tx, block.page_id)?.ok_or_else(|| {
                    Error::InvariantViolation(format!(
                        "live block {} references missing page {}",
                        block.id, block.page_id
                    ))
                })?;
                if page.deleted_at.is_some() {
                    return Err(Error::InvariantViolation(format!(
                        "live block {} references deleted page {}",
                        block.id, block.page_id
                    )));
                }
                if let Some(pid) = block.parent_id {
                    let parent = fetch_block(tx, pid)?.ok_or_else(|| {
                        Error::InvariantViolation(format!(
                            "live block {} references missing parent {pid}",
                            block.id
                        ))
                    })?;
                    if parent.deleted_at.is_some() {
                        return Err(Error::InvariantViolation(format!(
                            "live block {} references deleted parent {pid}",
                            block.id
                        )));
                    }
                    if parent.page_id != block.page_id {
                        return Err(Error::InvariantViolation(format!(
                            "live block {} page {} differs from parent {pid} page {}",
                            block.id, block.page_id, parent.page_id
                        )));
                    }
                }
                let mut seen = HashSet::new();
                let mut cur = Some(block.id);
                while let Some(cid) = cur {
                    if !seen.insert(cid) {
                        return Err(Error::InvariantViolation(format!(
                            "cycle detected involving block {cid}"
                        )));
                    }
                    cur = fetch_block(tx, cid)?.and_then(|b| b.parent_id);
                }
            } else {
                let has_live_child: Option<i64> = tx
                    .query_row(
                        "SELECT 1 FROM blocks WHERE parent_id = ?1 AND deleted_at IS NULL LIMIT 1",
                        params![block.id.as_bytes().as_slice()],
                        |row| row.get(0),
                    )
                    .optional()?;
                if has_live_child.is_some() {
                    return Err(Error::InvariantViolation(format!(
                        "deleted block {} still has live children",
                        block.id
                    )));
                }
            }
        } else if let Some(page) = fetch_page(tx, entity_id)?
            && page.deleted_at.is_some()
        {
            let has_live_block: Option<i64> = tx
                .query_row(
                    "SELECT 1 FROM blocks WHERE page_id = ?1 AND deleted_at IS NULL LIMIT 1",
                    params![page.id.as_bytes().as_slice()],
                    |row| row.get(0),
                )
                .optional()?;
            if has_live_block.is_some() {
                return Err(Error::InvariantViolation(format!(
                    "deleted page {} still has live blocks",
                    page.id
                )));
            }
        }
    }
    Ok(())
}

fn verify_invariants_conn(conn: &Connection) -> Result<()> {
    let mut page_stmt = conn.prepare("SELECT id FROM pages WHERE deleted_at IS NULL")?;
    let mut live_pages = HashSet::new();
    for row in page_stmt.query_map([], |row| row.get::<_, Vec<u8>>(0))? {
        let bytes = row?;
        let id = Id::from_slice(&bytes)
            .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
        live_pages.insert(id);
    }

    let mut block_stmt =
        conn.prepare("SELECT id, page_id, parent_id FROM blocks WHERE deleted_at IS NULL")?;
    let mut live_blocks: HashMap<Id, (Id, Option<Id>)> = HashMap::new();
    for row in block_stmt.query_map([], |row| {
        Ok((
            row.get::<_, Vec<u8>>(0)?,
            row.get::<_, Vec<u8>>(1)?,
            row.get::<_, Option<Vec<u8>>>(2)?,
        ))
    })? {
        let (id_b, page_b, parent_b) = row?;
        let id = Id::from_slice(&id_b)
            .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
        let page_id = Id::from_slice(&page_b)
            .ok_or_else(|| Error::InvariantViolation("invalid block page_id bytes".to_string()))?;
        let parent_id = match parent_b {
            Some(pb) => Some(Id::from_slice(&pb).ok_or_else(|| {
                Error::InvariantViolation("invalid block parent_id bytes".to_string())
            })?),
            None => None,
        };
        live_blocks.insert(id, (page_id, parent_id));
    }

    for (&block_id, &(page_id, parent_id)) in &live_blocks {
        if !live_pages.contains(&page_id) {
            return Err(Error::InvariantViolation(format!(
                "live block {block_id} references non-live page {page_id}"
            )));
        }
        if let Some(pid) = parent_id {
            let Some(&(parent_page_id, _)) = live_blocks.get(&pid) else {
                return Err(Error::InvariantViolation(format!(
                    "live block {block_id} references non-live parent {pid}"
                )));
            };
            if parent_page_id != page_id {
                return Err(Error::InvariantViolation(format!(
                    "live block {block_id} page {page_id} differs from parent {pid} page {parent_page_id}"
                )));
            }
        }

        let mut seen = HashSet::new();
        let mut cur = Some(block_id);
        while let Some(cid) = cur {
            if !seen.insert(cid) {
                return Err(Error::InvariantViolation(format!(
                    "cycle detected involving block {cid}"
                )));
            }
            cur = live_blocks.get(&cid).and_then(|&(_, p)| p);
        }
    }

    Ok(())
}

fn fetch_page(tx: &Transaction<'_>, id: Id) -> Result<Option<Page>> {
    tx.query_row(
        "SELECT id, title, title_lower, journal_day, document_mode,
                created_at, updated_at, created_by, updated_by, deleted_at, version
         FROM pages WHERE id = ?1",
        params![id.as_bytes().as_slice()],
        row_to_page,
    )
    .optional()
    .map_err(Error::from)
}

fn require_live_page(tx: &Transaction<'_>, id: Id) -> Result<Page> {
    let page = fetch_page(tx, id)?.ok_or(Error::NotFound(id))?;
    if page.deleted_at.is_some() {
        return Err(Error::DeletedEntity(id));
    }
    Ok(page)
}

fn fetch_block(tx: &Transaction<'_>, id: Id) -> Result<Option<Block>> {
    tx.query_row(
        "SELECT id, page_id, parent_id, order_key, content, collapsed,
                created_at, updated_at, created_by, updated_by, deleted_at, version
         FROM blocks WHERE id = ?1",
        params![id.as_bytes().as_slice()],
        row_to_block,
    )
    .optional()
    .map_err(Error::from)
}

fn require_live_block(tx: &Transaction<'_>, id: Id) -> Result<Block> {
    let block = fetch_block(tx, id)?.ok_or(Error::NotFound(id))?;
    if block.deleted_at.is_some() {
        return Err(Error::DeletedEntity(id));
    }
    Ok(block)
}

fn check_version(id: Id, expected: Option<i64>, actual: i64) -> Result<()> {
    if let Some(exp) = expected
        && exp != actual
    {
        return Err(Error::VersionMismatch {
            id,
            expected: exp,
            actual,
        });
    }
    Ok(())
}

fn ensure_page_title_available(
    tx: &Transaction<'_>,
    page_id: Id,
    title_lower: &str,
    exclude_id: Option<Id>,
    raw_title: &str,
) -> Result<()> {
    let existing: Option<Vec<u8>> = tx
        .query_row(
            "SELECT id FROM pages WHERE title_lower = ?1 AND deleted_at IS NULL",
            params![title_lower],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(bytes) = existing {
        let found_id = Id::from_slice(&bytes)
            .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
        if exclude_id != Some(found_id) {
            return Err(Error::PageTitleExists {
                id: page_id,
                title: raw_title.to_string(),
            });
        }
    }
    Ok(())
}

fn ensure_journal_day_available(
    tx: &Transaction<'_>,
    page_id: Id,
    journal_day: i32,
    exclude_id: Option<Id>,
) -> Result<()> {
    let existing: Option<Vec<u8>> = tx
        .query_row(
            "SELECT id FROM pages WHERE journal_day = ?1 AND deleted_at IS NULL",
            params![journal_day],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(bytes) = existing {
        let found_id = Id::from_slice(&bytes)
            .ok_or_else(|| Error::InvariantViolation("invalid page id bytes".to_string()))?;
        if exclude_id != Some(found_id) {
            return Err(Error::JournalDayExists {
                id: page_id,
                journal_day,
            });
        }
    }
    Ok(())
}

fn ensure_not_ancestor(tx: &Transaction<'_>, candidate_ancestor: Id, start: Id) -> Result<()> {
    let mut cur = Some(start);
    let mut visited = HashSet::new();
    while let Some(cid) = cur {
        if cid == candidate_ancestor {
            return Err(Error::CycleDetected(candidate_ancestor));
        }
        if !visited.insert(cid) {
            return Err(Error::CycleDetected(cid));
        }
        let parent_bytes: Option<Vec<u8>> = tx
            .query_row(
                "SELECT parent_id FROM blocks WHERE id = ?1",
                params![cid.as_bytes().as_slice()],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        cur =
            match parent_bytes {
                Some(b) => Some(Id::from_slice(&b).ok_or_else(|| {
                    Error::InvariantViolation("invalid parent_id bytes".to_string())
                })?),
                None => None,
            };
    }
    Ok(())
}

fn collect_live_descendants(tx: &Transaction<'_>, root_id: Id) -> Result<Vec<Id>> {
    let mut result = Vec::new();
    let mut queue = VecDeque::new();
    queue.push_back(root_id);

    let mut stmt = tx.prepare(
        "SELECT id FROM blocks WHERE parent_id = ?1 AND deleted_at IS NULL ORDER BY order_key, id",
    )?;

    while let Some(current) = queue.pop_front() {
        let rows = stmt.query_map(params![current.as_bytes().as_slice()], |row| {
            row.get::<_, Vec<u8>>(0)
        })?;
        for row in rows {
            let bytes = row?;
            let child_id = Id::from_slice(&bytes)
                .ok_or_else(|| Error::InvariantViolation("invalid child id bytes".to_string()))?;
            result.push(child_id);
            queue.push_back(child_id);
        }
    }

    Ok(result)
}

fn collect_page_live_blocks_top_down(tx: &Transaction<'_>, page_id: Id) -> Result<Vec<Id>> {
    let mut result = Vec::new();
    let mut queue = VecDeque::new();

    {
        let mut root_stmt = tx.prepare(
            "SELECT id FROM blocks
             WHERE page_id = ?1 AND parent_id IS NULL AND deleted_at IS NULL
             ORDER BY order_key, id",
        )?;
        let rows = root_stmt.query_map(params![page_id.as_bytes().as_slice()], |row| {
            row.get::<_, Vec<u8>>(0)
        })?;
        for row in rows {
            let bytes = row?;
            let id = Id::from_slice(&bytes)
                .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
            result.push(id);
            queue.push_back(id);
        }
    }

    let mut child_stmt = tx.prepare(
        "SELECT id FROM blocks WHERE parent_id = ?1 AND deleted_at IS NULL ORDER BY order_key, id",
    )?;

    while let Some(current) = queue.pop_front() {
        let rows = child_stmt.query_map(params![current.as_bytes().as_slice()], |row| {
            row.get::<_, Vec<u8>>(0)
        })?;
        for row in rows {
            let bytes = row?;
            let id = Id::from_slice(&bytes)
                .ok_or_else(|| Error::InvariantViolation("invalid block id bytes".to_string()))?;
            result.push(id);
            queue.push_back(id);
        }
    }

    Ok(result)
}

fn row_to_page(row: &Row<'_>) -> rusqlite::Result<Page> {
    let id_bytes: Vec<u8> = row.get(0)?;
    let id = Id::from_slice(&id_bytes).ok_or(rusqlite::Error::InvalidQuery)?;
    let document_mode: i64 = row.get(4)?;
    Ok(Page {
        id,
        title: row.get(1)?,
        title_lower: row.get(2)?,
        journal_day: row.get(3)?,
        document_mode: document_mode != 0,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
        created_by: row.get(7)?,
        updated_by: row.get(8)?,
        deleted_at: row.get(9)?,
        version: row.get(10)?,
    })
}

fn row_to_block(row: &Row<'_>) -> rusqlite::Result<Block> {
    let id_bytes: Vec<u8> = row.get(0)?;
    let page_bytes: Vec<u8> = row.get(1)?;
    let parent_bytes: Option<Vec<u8>> = row.get(2)?;
    let id = Id::from_slice(&id_bytes).ok_or(rusqlite::Error::InvalidQuery)?;
    let page_id = Id::from_slice(&page_bytes).ok_or(rusqlite::Error::InvalidQuery)?;
    let parent_id = match parent_bytes {
        Some(b) => Some(Id::from_slice(&b).ok_or(rusqlite::Error::InvalidQuery)?),
        None => None,
    };
    let collapsed: i64 = row.get(5)?;
    Ok(Block {
        id,
        page_id,
        parent_id,
        order_key: row.get(3)?,
        content: row.get(4)?,
        collapsed: collapsed != 0,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
        created_by: row.get(8)?,
        updated_by: row.get(9)?,
        deleted_at: row.get(10)?,
        version: row.get(11)?,
    })
}

fn row_to_txn(row: &Row<'_>) -> rusqlite::Result<TxnRecord> {
    row_to_txn_offset(row, 0)
}

fn row_to_txn_offset(row: &Row<'_>, offset: usize) -> rusqlite::Result<TxnRecord> {
    let id_bytes: Vec<u8> = row.get(offset)?;
    let id = Id::from_slice(&id_bytes).ok_or(rusqlite::Error::InvalidQuery)?;
    let origin_str: String = row.get(offset + 2)?;
    let origin = Origin::parse(&origin_str).ok_or(rusqlite::Error::InvalidQuery)?;
    let undoes_bytes: Option<Vec<u8>> = row.get(offset + 6)?;
    let undoes = match undoes_bytes {
        Some(b) => Some(Id::from_slice(&b).ok_or(rusqlite::Error::InvalidQuery)?),
        None => None,
    };
    Ok(TxnRecord {
        id,
        ts: row.get(offset + 1)?,
        origin,
        actor: row.get(offset + 3)?,
        session: row.get(offset + 4)?,
        summary: row.get(offset + 5)?,
        undoes,
    })
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
