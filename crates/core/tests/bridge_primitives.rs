use anyhow::{Context, Result};
use pith_core::{Id, Op, Origin, Store, TxMeta, order};

fn user_meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::User, "me", summary)
}

#[test]
fn read_page_window_respects_depth_collapse_and_pagination() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let b1 = Id::new();
    let b1_child = Id::new();
    let b2 = Id::new();
    let k1 = order::between(None, None)?;
    let k2 = order::between(Some(&k1), None)?;

    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Window".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: b1,
                page_id,
                parent_id: None,
                order_key: k1.clone(),
                content: "Parent [[Ref]]".to_string(),
            },
            Op::InsertBlock {
                id: b1_child,
                page_id,
                parent_id: Some(b1),
                order_key: k1,
                content: "Child".to_string(),
            },
            Op::InsertBlock {
                id: b2,
                page_id,
                parent_id: None,
                order_key: k2,
                content: "Second".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    let full = store.read_page_window(page_id, 0, 10)?;
    assert_eq!(full.total_visible, 3);
    assert_eq!(full.rows.len(), 3);
    assert_eq!(full.rows[0].depth, 0);
    assert!(full.rows[0].has_children);
    assert_eq!(full.rows[0].rendered_content, "Parent [[Ref]]");
    assert_eq!(full.rows[1].depth, 1);
    assert_eq!(full.rows[2].depth, 0);

    let paged = store.read_page_window(page_id, 1, 1)?;
    assert_eq!(paged.total_visible, 3);
    assert_eq!(paged.offset, 1);
    assert_eq!(paged.rows.len(), 1);
    assert_eq!(paged.rows[0].id, b1_child);

    store.apply_ops(
        &[Op::SetCollapsed {
            id: b1,
            collapsed: true,
        }],
        &user_meta("collapse"),
    )?;

    let collapsed = store.read_page_window(page_id, 0, 10)?;
    assert_eq!(collapsed.total_visible, 2);
    assert_eq!(collapsed.rows.len(), 2);
    assert_eq!(collapsed.rows[0].id, b1);
    assert!(collapsed.rows[0].collapsed);
    assert_eq!(collapsed.rows[1].id, b2);
    Ok(())
}

#[test]
fn change_feed_and_undo_redo_last_work_across_connections() -> Result<()> {
    let path = std::env::temp_dir().join(format!("pith-feed-{}.db", Id::new()));
    let result = (|| -> Result<()> {
        let mut app = Store::open(&path)?;
        let mut cli = Store::open(&path)?;

        let v0 = app.data_version()?;
        let s0 = app.latest_txn_seq()?;
        assert_eq!(s0, 0);

        let page_id = Id::new();
        let block_id = Id::new();
        cli.apply_ops(
            &[
                Op::CreatePage {
                    id: page_id,
                    title: "Feed".to_string(),
                    journal_day: None,
                    document_mode: false,
                },
                Op::InsertBlock {
                    id: block_id,
                    page_id,
                    parent_id: None,
                    order_key: order::between(None, None)?,
                    content: "First".to_string(),
                },
            ],
            &TxMeta::new(Origin::Agent, "agent:claude", "cli write"),
        )?;

        assert_ne!(app.data_version()?, v0);
        let feed = app.changes_since(s0, 50)?;
        assert_eq!(feed.entries.len(), 1);
        assert_eq!(feed.entries[0].actor, "agent:claude");
        assert!(feed.entries[0].touched_ids.contains(&block_id));

        app.apply_ops(
            &[Op::UpdateBlock {
                id: block_id,
                content: "Edited".to_string(),
                expected_version: Some(1),
            }],
            &user_meta("edit"),
        )?;

        let undone = app.undo_last(&user_meta("undo"), false)?;
        assert!(undone.is_some());
        assert_eq!(app.get_block(block_id)?.context("block")?.content, "First");

        let redone = app.redo_last(&user_meta("redo"), false)?;
        assert!(redone.is_some());
        assert_eq!(app.get_block(block_id)?.context("block")?.content, "Edited");
        Ok(())
    })();

    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    result
}

fn seeded_block() -> Result<(Store, Id)> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Undo".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "v0".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;
    Ok((store, block_id))
}

fn type_text(store: &mut Store, block_id: Id, text: &str) -> Result<()> {
    store.apply_ops(
        &[Op::UpdateBlock {
            id: block_id,
            content: text.to_string(),
            expected_version: None,
        }],
        &user_meta("type"),
    )?;
    Ok(())
}

fn text_of(store: &Store, block_id: Id) -> Result<String> {
    Ok(store.get_block(block_id)?.context("block")?.content)
}

#[test]
fn undo_redo_walk_back_and_forward_through_edits_in_order() -> Result<()> {
    let (mut store, block) = seeded_block()?;
    type_text(&mut store, block, "A")?;
    type_text(&mut store, block, "B")?;

    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "A");
    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "v0");

    store.redo_last(&user_meta("redo"), false)?;
    assert_eq!(text_of(&store, block)?, "A");
    store.redo_last(&user_meta("redo"), false)?;
    assert_eq!(text_of(&store, block)?, "B");

    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "A");
    store.check_invariants()?;
    Ok(())
}

#[test]
fn redo_is_a_no_op_once_everything_is_redone() -> Result<()> {
    let (mut store, block) = seeded_block()?;
    type_text(&mut store, block, "A")?;

    store.undo_last(&user_meta("undo"), false)?;
    assert!(store.redo_last(&user_meta("redo"), false)?.is_some());
    assert!(store.redo_last(&user_meta("redo"), false)?.is_none());
    assert_eq!(text_of(&store, block)?, "A");
    Ok(())
}

#[test]
fn a_new_edit_clears_redo_so_newer_text_is_never_overwritten() -> Result<()> {
    let (mut store, block) = seeded_block()?;
    type_text(&mut store, block, "A")?;

    store.undo_last(&user_meta("undo"), false)?;
    type_text(&mut store, block, "B")?;

    assert!(store.redo_last(&user_meta("redo"), false)?.is_none());
    assert_eq!(text_of(&store, block)?, "B");
    Ok(())
}

#[test]
fn undo_and_redo_only_walk_the_callers_own_history() -> Result<()> {
    let (mut store, block) = seeded_block()?;
    type_text(&mut store, block, "mine")?;
    let agent = TxMeta::new(Origin::Agent, "agent:claude", "agent edit");
    store.apply_ops(
        &[Op::InsertBlock {
            id: Id::new(),
            page_id: store.get_block(block)?.context("block")?.page_id,
            parent_id: None,
            order_key: order::between(Some("V"), None)?,
            content: "agent note".to_string(),
        }],
        &agent,
    )?;

    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "v0");
    let agent_blocks = store.search("agent note", 5)?;
    assert_eq!(agent_blocks.len(), 1);
    Ok(())
}

fn type_in_group(store: &mut Store, block_id: Id, text: &str, group: &str) -> Result<Id> {
    store
        .apply_ops(
            &[Op::UpdateBlock {
                id: block_id,
                content: text.to_string(),
                expected_version: None,
            }],
            &user_meta("type").with_undo_group(group),
        )?
        .txn_id
        .context("txn")
}

#[test]
fn an_undo_group_is_one_undo_and_redo_step() -> Result<()> {
    let (mut store, block) = seeded_block()?;
    type_in_group(&mut store, block, "v0 t", "burst-1")?;
    type_in_group(&mut store, block, "v0 typing", "burst-1")?;
    type_in_group(&mut store, block, "v0 typing more", "burst-1")?;

    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "v0");

    store.redo_last(&user_meta("redo"), false)?;
    assert_eq!(text_of(&store, block)?, "v0 typing more");

    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "v0");
    store.check_invariants()?;
    Ok(())
}

#[test]
fn undo_groups_keep_history_append_only_and_visible_in_the_feed() -> Result<()> {
    let (mut store, block) = seeded_block()?;
    let first = type_in_group(&mut store, block, "first", "burst-1")?;
    let cursor = store.changes_since(0, 100)?.latest_seq;
    let second = type_in_group(&mut store, block, "second", "burst-1")?;

    assert_ne!(first, second);
    let feed = store.changes_since(cursor, 100)?;
    assert_eq!(feed.entries.len(), 1);
    assert_eq!(feed.entries[0].txn_id, second);
    Ok(())
}

#[test]
fn separate_groups_undo_separately() -> Result<()> {
    let (mut store, block) = seeded_block()?;
    type_in_group(&mut store, block, "A", "burst-1")?;
    type_in_group(&mut store, block, "B", "burst-2")?;

    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "A");
    store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(text_of(&store, block)?, "v0");
    Ok(())
}
