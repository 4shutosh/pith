use std::collections::BTreeSet;

use rusqlite::{Connection, OptionalExtension, params};

use crate::error::Result;
use crate::id::Id;
use crate::ops::Op;

pub const MAX_DIFFED_CHANGES: usize = 2000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ChangeCursor {
    pub txn_seq: i64,
    pub view_seq: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GraphChanges {
    pub cursor: ChangeCursor,
    pub reload_all: bool,
    pub pages: Vec<Id>,
    pub restructured_pages: Vec<Id>,
    pub stale_blocks: Vec<Id>,
}

impl GraphChanges {
    pub fn is_empty(&self) -> bool {
        !self.reload_all
            && self.pages.is_empty()
            && self.restructured_pages.is_empty()
            && self.stale_blocks.is_empty()
    }
}

#[derive(Default)]
struct Classified {
    pages: BTreeSet<Id>,
    restructured: BTreeSet<Id>,
    edited: BTreeSet<Id>,
    displayed_elsewhere: BTreeSet<Id>,
}

pub fn change_cursor(conn: &Connection) -> Result<ChangeCursor> {
    Ok(ChangeCursor {
        txn_seq: conn.query_row("SELECT COALESCE(MAX(seq), 0) FROM txns", [], |r| r.get(0))?,
        view_seq: conn.query_row("SELECT COALESCE(MAX(seq), 0) FROM view_log", [], |r| {
            r.get(0)
        })?,
    })
}

pub fn changes_after(conn: &Connection, after: ChangeCursor) -> Result<GraphChanges> {
    let latest = change_cursor(conn)?;
    if latest == after {
        return Ok(GraphChanges {
            cursor: latest,
            ..GraphChanges::default()
        });
    }
    if latest.txn_seq < after.txn_seq || latest.view_seq < after.view_seq {
        return Ok(reload_all(latest));
    }
    let content = content_ops_after(conn, after.txn_seq)?;
    let view = view_ops_after(conn, after.view_seq)?;
    if content.len() + view.len() > MAX_DIFFED_CHANGES {
        return Ok(reload_all(latest));
    }

    let mut classified = Classified::default();
    for (forward, inverse) in &content {
        classify(conn, forward, inverse, &mut classified)?;
    }
    for op in &view {
        classify(conn, op, &[], &mut classified)?;
    }

    let mut stale = classified.edited;
    stale.extend(blocks_displaying(conn, &classified.displayed_elsewhere)?);
    Ok(GraphChanges {
        cursor: latest,
        reload_all: false,
        pages: classified.pages.into_iter().collect(),
        restructured_pages: classified.restructured.into_iter().collect(),
        stale_blocks: stale.into_iter().collect(),
    })
}

fn reload_all(cursor: ChangeCursor) -> GraphChanges {
    GraphChanges {
        cursor,
        reload_all: true,
        ..GraphChanges::default()
    }
}

fn content_ops_after(conn: &Connection, after_seq: i64) -> Result<Vec<(Op, Vec<Op>)>> {
    let mut stmt = conn.prepare_cached(
        "SELECT o.forward, o.inverse
         FROM ops o JOIN txns t ON t.id = o.txn_id
         WHERE t.seq > ?1
         ORDER BY t.seq, o.seq
         LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![after_seq, (MAX_DIFFED_CHANGES + 1) as i64], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (forward, inverse) = row?;
        out.push((
            serde_json::from_str(&forward)?,
            serde_json::from_str(&inverse)?,
        ));
    }
    Ok(out)
}

fn view_ops_after(conn: &Connection, after_seq: i64) -> Result<Vec<Op>> {
    let mut stmt =
        conn.prepare_cached("SELECT op FROM view_log WHERE seq > ?1 ORDER BY seq LIMIT ?2")?;
    let rows = stmt.query_map(params![after_seq, (MAX_DIFFED_CHANGES + 1) as i64], |r| {
        r.get::<_, String>(0)
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(serde_json::from_str(&row?)?);
    }
    Ok(out)
}

fn classify(conn: &Connection, forward: &Op, inverse: &[Op], into: &mut Classified) -> Result<()> {
    match forward {
        Op::CreatePage { id, .. } | Op::SetPageFavorite { id, .. } => {
            into.pages.insert(*id);
        }
        Op::RenamePage { id, .. } => {
            into.pages.insert(*id);
            into.displayed_elsewhere.insert(*id);
        }
        Op::DeletePage { id, .. } | Op::RestorePage { id } => {
            into.pages.insert(*id);
            into.restructured.insert(*id);
            into.displayed_elsewhere.insert(*id);
        }
        Op::InsertBlock { page_id, .. } => {
            into.restructured.insert(*page_id);
        }
        Op::UpdateBlock { id, .. } => {
            into.edited.insert(*id);
            into.displayed_elsewhere.insert(*id);
        }
        Op::MoveBlock { page_id, .. } => {
            into.restructured.insert(*page_id);
            for undo in inverse {
                if let Op::MoveBlock { page_id: from, .. } = undo {
                    into.restructured.insert(*from);
                }
            }
        }
        Op::DeleteBlock { id, .. } | Op::RestoreBlock { id } => {
            into.restructured.extend(page_of_block(conn, *id)?);
            into.displayed_elsewhere.insert(*id);
        }
        Op::SetCollapsed { id, .. } => {
            into.restructured.extend(page_of_block(conn, *id)?);
        }
    }
    Ok(())
}

fn page_of_block(conn: &Connection, id: Id) -> Result<Option<Id>> {
    let bytes: Option<Vec<u8>> = conn
        .prepare_cached("SELECT page_id FROM blocks WHERE id = ?1")?
        .query_row(params![id.as_bytes().as_slice()], |r| r.get(0))
        .optional()?;
    Ok(bytes.and_then(|b| Id::from_slice(&b)))
}

fn blocks_displaying(conn: &Connection, targets: &BTreeSet<Id>) -> Result<BTreeSet<Id>> {
    let mut stmt = conn.prepare_cached("SELECT DISTINCT src_block FROM refs WHERE target = ?1")?;
    let mut out = BTreeSet::new();
    for target in targets {
        let rows = stmt.query_map(params![target.as_bytes().as_slice()], |r| {
            r.get::<_, Vec<u8>>(0)
        })?;
        for row in rows {
            if let Some(id) = Id::from_slice(&row?) {
                out.insert(id);
            }
        }
    }
    Ok(out)
}
