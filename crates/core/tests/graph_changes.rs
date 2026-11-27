use std::collections::BTreeSet;

use anyhow::Result;
use pith_core::changes::MAX_DIFFED_CHANGES;
use pith_core::{Id, Op, Origin, Store, TxMeta, order};

fn meta() -> TxMeta {
    TxMeta::new(Origin::User, "me", "test")
}

fn page(store: &mut Store, title: &str) -> Result<Id> {
    let id = Id::new();
    store.apply_ops(
        &[Op::CreatePage {
            id,
            title: title.to_string(),
            journal_day: None,
            document_mode: false,
        }],
        &meta(),
    )?;
    Ok(id)
}

fn block(store: &mut Store, page_id: Id, text: &str) -> Result<Id> {
    let id = Id::new();
    let last = store
        .list_children(page_id, None)?
        .last()
        .map(|b| b.order_key.clone());
    store.apply_ops(
        &[Op::InsertBlock {
            id,
            page_id,
            parent_id: None,
            order_key: order::between(last.as_deref(), None)?,
            content: text.to_string(),
        }],
        &meta(),
    )?;
    Ok(id)
}

fn set(ids: &[Id]) -> BTreeSet<Id> {
    ids.iter().copied().collect()
}

struct Graph {
    store: Store,
    alpha: Id,
    beta: Id,
    a1: Id,
    a2: Id,
    b1: Id,
    b2: Id,
}

fn graph() -> Result<Graph> {
    let mut store = Store::open_in_memory()?;
    let alpha = page(&mut store, "Alpha")?;
    let beta = page(&mut store, "Beta")?;
    let a1 = block(&mut store, alpha, "first")?;
    let a2 = block(&mut store, alpha, "second")?;
    let b1 = block(
        &mut store,
        beta,
        &format!("quotes (({a1})) and links [[Alpha]]"),
    )?;
    let b2 = block(&mut store, beta, "plain")?;
    Ok(Graph {
        store,
        alpha,
        beta,
        a1,
        a2,
        b1,
        b2,
    })
}

#[test]
fn an_edit_marks_the_block_and_every_block_that_quotes_it() -> Result<()> {
    let mut g = graph()?;
    let cursor = g.store.change_cursor()?;
    g.store.apply_ops(
        &[Op::UpdateBlock {
            id: g.a1,
            content: "first, edited".to_string(),
            expected_version: None,
        }],
        &meta(),
    )?;
    let changes = g.store.changes_after(cursor)?;
    assert!(!changes.reload_all);
    assert!(changes.pages.is_empty());
    assert!(changes.restructured_pages.is_empty());
    assert_eq!(set(&changes.stale_blocks), set(&[g.a1, g.b1]));

    let rows = g.store.block_rows(&changes.stale_blocks)?;
    let quoting = rows.iter().find(|r| r.id == g.b1).expect("quoting row");
    assert!(quoting.display.text().contains("first, edited"));
    assert!(g.store.changes_after(changes.cursor)?.is_empty());
    Ok(())
}

#[test]
fn structure_changes_name_every_page_whose_tree_changed() -> Result<()> {
    let mut g = graph()?;

    let cursor = g.store.change_cursor()?;
    let inserted = block(&mut g.store, g.alpha, "third")?;
    let changes = g.store.changes_after(cursor)?;
    assert_eq!(changes.restructured_pages, vec![g.alpha]);
    assert!(changes.stale_blocks.is_empty());

    let cursor = changes.cursor;
    g.store.apply_ops(
        &[Op::MoveBlock {
            id: g.a2,
            page_id: g.beta,
            parent_id: None,
            order_key: order::between(None, None)?,
            expected_version: None,
        }],
        &meta(),
    )?;
    let changes = g.store.changes_after(cursor)?;
    assert_eq!(set(&changes.restructured_pages), set(&[g.alpha, g.beta]));

    let cursor = changes.cursor;
    g.store.apply_ops(
        &[Op::DeleteBlock {
            id: inserted,
            expected_version: None,
        }],
        &meta(),
    )?;
    let changes = g.store.changes_after(cursor)?;
    assert_eq!(changes.restructured_pages, vec![g.alpha]);
    assert!(changes.pages.is_empty());
    Ok(())
}

#[test]
fn page_changes_mark_the_page_and_the_blocks_that_link_to_it() -> Result<()> {
    let mut g = graph()?;

    let cursor = g.store.change_cursor()?;
    g.store.apply_ops(
        &[Op::RenamePage {
            id: g.alpha,
            title: "Alpha Prime".to_string(),
            expected_version: None,
        }],
        &meta(),
    )?;
    let changes = g.store.changes_after(cursor)?;
    assert_eq!(changes.pages, vec![g.alpha]);
    assert!(changes.restructured_pages.is_empty());
    assert_eq!(changes.stale_blocks, vec![g.b1]);
    let rows = g.store.block_rows(&changes.stale_blocks)?;
    assert!(rows[0].display.text().contains("Alpha Prime"));

    let cursor = changes.cursor;
    g.store.apply_ops(
        &[Op::DeletePage {
            id: g.alpha,
            expected_version: None,
        }],
        &meta(),
    )?;
    let changes = g.store.changes_after(cursor)?;
    assert_eq!(changes.pages, vec![g.alpha]);
    assert_eq!(changes.restructured_pages, vec![g.alpha]);
    assert_eq!(changes.stale_blocks, vec![g.b1]);
    assert_eq!(g.store.block_rows(&[g.a1, g.b2])?.len(), 1);
    Ok(())
}

#[test]
fn view_state_reaches_the_feed_but_never_undo() -> Result<()> {
    let mut g = graph()?;
    let child = Id::new();
    g.store.apply_ops(
        &[Op::InsertBlock {
            id: child,
            page_id: g.alpha,
            parent_id: Some(g.a1),
            order_key: order::between(None, None)?,
            content: "child".to_string(),
        }],
        &meta(),
    )?;
    let txns_before = g.store.change_cursor()?.txn_seq;

    let cursor = g.store.change_cursor()?;
    g.store.apply_ops(
        &[
            Op::SetCollapsed {
                id: g.a1,
                collapsed: true,
            },
            Op::SetPageFavorite {
                id: g.beta,
                favorite: true,
            },
        ],
        &meta(),
    )?;
    let changes = g.store.changes_after(cursor)?;
    assert_eq!(changes.restructured_pages, vec![g.alpha]);
    assert_eq!(changes.pages, vec![g.beta]);
    assert_eq!(changes.cursor.txn_seq, txns_before);
    assert_eq!(changes.cursor.view_seq, cursor.view_seq + 2);

    g.store.undo_last(&meta(), false)?;
    assert!(
        g.store
            .get_block(child)?
            .expect("child row")
            .deleted_at
            .is_some()
    );
    assert!(g.store.get_block(g.a1)?.expect("parent row").collapsed);
    Ok(())
}

#[test]
fn another_connection_s_writes_show_up_through_the_cursor() -> Result<()> {
    let path = std::env::temp_dir().join(format!("pith-changes-{}.db", Id::new()));
    let result = (|| -> Result<()> {
        let mut writer = Store::open(&path)?;
        let notes = page(&mut writer, "Notes")?;
        let line = block(&mut writer, notes, "one")?;

        let reader = Store::open(&path)?;
        let cursor = reader.change_cursor()?;
        writer.apply_ops(
            &[Op::UpdateBlock {
                id: line,
                content: "one, from the CLI".to_string(),
                expected_version: None,
            }],
            &TxMeta::new(Origin::Agent, "agent:cli", "edit"),
        )?;
        writer.apply_ops(
            &[Op::SetCollapsed {
                id: line,
                collapsed: true,
            }],
            &meta(),
        )?;
        let changes = reader.changes_after(cursor)?;
        assert_eq!(changes.stale_blocks, vec![line]);
        assert_eq!(changes.restructured_pages, vec![notes]);
        assert_eq!(changes.cursor, writer.change_cursor()?);
        Ok(())
    })();
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    result
}

#[test]
fn a_burst_too_large_to_diff_asks_for_a_full_reload() -> Result<()> {
    let mut g = graph()?;
    let cursor = g.store.change_cursor()?;
    let mut key: Option<String> = None;
    let mut ops = Vec::new();
    for n in 0..MAX_DIFFED_CHANGES {
        let next = order::between(key.as_deref(), None)?;
        ops.push(Op::InsertBlock {
            id: Id::new(),
            page_id: g.beta,
            parent_id: None,
            order_key: next.clone(),
            content: format!("bulk {n}"),
        });
        key = Some(next);
    }
    g.store.apply_ops(&ops, &meta())?;
    let at_limit = g.store.changes_after(cursor)?;
    assert!(!at_limit.reload_all);
    assert_eq!(at_limit.restructured_pages, vec![g.beta]);

    g.store.apply_ops(
        &[Op::SetCollapsed {
            id: g.b2,
            collapsed: true,
        }],
        &meta(),
    )?;
    let over = g.store.changes_after(cursor)?;
    assert!(over.reload_all);
    assert!(over.pages.is_empty() && over.restructured_pages.is_empty());
    assert_eq!(over.cursor, g.store.change_cursor()?);
    Ok(())
}

#[test]
fn a_version_3_database_gains_the_view_log_on_open() -> Result<()> {
    let path = std::env::temp_dir().join(format!("pith-v3-{}.db", Id::new()));
    let result = (|| -> Result<()> {
        {
            let mut store = Store::open(&path)?;
            page(&mut store, "Old")?;
        }
        {
            let conn = rusqlite::Connection::open(&path)?;
            conn.execute_batch(
                "DROP TABLE view_log;
                 DROP INDEX idx_blocks_page_live;
                 CREATE INDEX idx_blocks_page ON blocks(page_id);
                 DROP INDEX idx_refs_target_src;
                 CREATE INDEX idx_refs_target ON refs(target);
                 PRAGMA user_version = 3;",
            )?;
        }
        let mut store = Store::open(&path)?;
        let favorite = page(&mut store, "Starred")?;
        let cursor = store.change_cursor()?;
        store.apply_ops(
            &[Op::SetPageFavorite {
                id: favorite,
                favorite: true,
            }],
            &meta(),
        )?;
        assert_eq!(store.changes_after(cursor)?.pages, vec![favorite]);
        Ok(())
    })();
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    result
}
