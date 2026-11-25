use anyhow::{Context, Result};
use pith_core::order;
use pith_core::{Error, Id, Op, Origin, Store, TxMeta};
use proptest::prelude::*;

fn user_meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::User, "me", summary)
}

fn agent_meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::Agent, "agent:claude", summary)
}

fn assert_op_round_trip(store: &mut Store, ops: &[Op]) -> Result<()> {
    let before = store.live_snapshot()?;
    let applied = store.apply_ops(ops, &user_meta("forward"))?;
    store.check_invariants()?;
    let txn_id = applied.txn_id.context("expected content txn_id")?;
    store.undo(txn_id, &user_meta("undo"), false)?;
    store.check_invariants()?;
    let after = store.live_snapshot()?;
    assert_eq!(before, after);
    Ok(())
}

#[test]
fn create_page_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    assert_op_round_trip(
        &mut store,
        &[Op::CreatePage {
            id: page_id,
            title: "Project X".to_string(),
            journal_day: None,
            document_mode: false,
        }],
    )
}

#[test]
fn rename_page_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    store.apply_ops(
        &[Op::CreatePage {
            id: page_id,
            title: "Original".to_string(),
            journal_day: None,
            document_mode: false,
        }],
        &user_meta("create"),
    )?;
    assert_op_round_trip(
        &mut store,
        &[Op::RenamePage {
            id: page_id,
            title: "Renamed".to_string(),
            expected_version: Some(1),
        }],
    )
}

#[test]
fn delete_page_with_subtree_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let root_id = Id::new();
    let child_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Notes".to_string(),
                journal_day: Some(20261125),
                document_mode: true,
            },
            Op::InsertBlock {
                id: root_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Root".to_string(),
            },
            Op::InsertBlock {
                id: child_id,
                page_id,
                parent_id: Some(root_id),
                order_key: order::between(None, None)?,
                content: "Child".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    assert_op_round_trip(
        &mut store,
        &[Op::DeletePage {
            id: page_id,
            expected_version: Some(1),
        }],
    )
}

#[test]
fn restore_page_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Deleted".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::DeletePage {
                id: page_id,
                expected_version: Some(1),
            },
        ],
        &user_meta("create and delete"),
    )?;

    assert_op_round_trip(&mut store, &[Op::RestorePage { id: page_id }])
}

#[test]
fn insert_block_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[Op::CreatePage {
            id: page_id,
            title: "Inbox".to_string(),
            journal_day: None,
            document_mode: false,
        }],
        &user_meta("create page"),
    )?;

    assert_op_round_trip(
        &mut store,
        &[Op::InsertBlock {
            id: block_id,
            page_id,
            parent_id: None,
            order_key: order::between(None, None)?,
            content: "Hello".to_string(),
        }],
    )
}

#[test]
fn update_block_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Inbox".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Before".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    assert_op_round_trip(
        &mut store,
        &[Op::UpdateBlock {
            id: block_id,
            content: "After".to_string(),
            expected_version: Some(1),
        }],
    )
}

#[test]
fn move_block_cross_page_with_subtree_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_a = Id::new();
    let page_b = Id::new();
    let parent_id = Id::new();
    let child_id = Id::new();
    let key = order::between(None, None)?;

    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_a,
                title: "Page A".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::CreatePage {
                id: page_b,
                title: "Page B".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: parent_id,
                page_id: page_a,
                parent_id: None,
                order_key: key.clone(),
                content: "Parent".to_string(),
            },
            Op::InsertBlock {
                id: child_id,
                page_id: page_a,
                parent_id: Some(parent_id),
                order_key: key.clone(),
                content: "Child".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    let before = store.live_snapshot()?;
    let res = store.apply_ops(
        &[Op::MoveBlock {
            id: parent_id,
            page_id: page_b,
            parent_id: None,
            order_key: order::between(Some(&key), None)?,
            expected_version: Some(1),
        }],
        &user_meta("move cross page"),
    )?;
    store.check_invariants()?;

    let moved_child = store.get_block(child_id)?.context("child must exist")?;
    assert_eq!(moved_child.page_id, page_b);

    let txn_id = res.txn_id.context("expected txn_id")?;
    store.undo(txn_id, &user_meta("undo move"), false)?;
    store.check_invariants()?;
    assert_eq!(before, store.live_snapshot()?);
    Ok(())
}

#[test]
fn delete_block_with_descendants_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let parent_id = Id::new();
    let child_id = Id::new();
    let grandchild_id = Id::new();
    let key = order::between(None, None)?;

    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Tree".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: parent_id,
                page_id,
                parent_id: None,
                order_key: key.clone(),
                content: "P".to_string(),
            },
            Op::InsertBlock {
                id: child_id,
                page_id,
                parent_id: Some(parent_id),
                order_key: key.clone(),
                content: "C".to_string(),
            },
            Op::InsertBlock {
                id: grandchild_id,
                page_id,
                parent_id: Some(child_id),
                order_key: key,
                content: "G".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    assert_op_round_trip(
        &mut store,
        &[Op::DeleteBlock {
            id: parent_id,
            expected_version: Some(1),
        }],
    )
}

#[test]
fn restore_block_inverse_restores_state() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Page".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Temp".to_string(),
            },
            Op::DeleteBlock {
                id: block_id,
                expected_version: Some(1),
            },
        ],
        &user_meta("seed deleted block"),
    )?;

    assert_op_round_trip(&mut store, &[Op::RestoreBlock { id: block_id }])
}

#[test]
fn set_collapsed_persists_without_version_bump_or_txn() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Page".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Collapsible".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    let txns_before = store.list_txns(None)?.len();
    let applied = store.apply_ops(
        &[Op::SetCollapsed {
            id: block_id,
            collapsed: true,
        }],
        &user_meta("collapse"),
    )?;
    assert!(applied.txn_id.is_none());
    assert!(applied.inverse_ops.is_empty());
    assert_eq!(store.list_txns(None)?.len(), txns_before);

    let block = store.get_block(block_id)?.context("block exists")?;
    assert!(block.collapsed);
    assert_eq!(block.version, 1);
    Ok(())
}

#[test]
fn version_mismatch_rejects_and_rolls_back() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Page".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "v1".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    let err = store
        .apply_ops(
            &[Op::UpdateBlock {
                id: block_id,
                content: "stale write".to_string(),
                expected_version: Some(99),
            }],
            &agent_meta("stale"),
        )
        .expect_err("expected version mismatch");
    assert!(matches!(
        err,
        Error::VersionMismatch {
            expected: 99,
            actual: 1,
            ..
        }
    ));
    let block = store.get_block(block_id)?.context("block exists")?;
    assert_eq!(block.content, "v1");
    Ok(())
}

#[test]
fn move_cycle_is_rejected() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let parent_id = Id::new();
    let child_id = Id::new();
    let key = order::between(None, None)?;

    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Cycle".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: parent_id,
                page_id,
                parent_id: None,
                order_key: key.clone(),
                content: "Parent".to_string(),
            },
            Op::InsertBlock {
                id: child_id,
                page_id,
                parent_id: Some(parent_id),
                order_key: key.clone(),
                content: "Child".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    let err = store
        .apply_ops(
            &[Op::MoveBlock {
                id: parent_id,
                page_id,
                parent_id: Some(child_id),
                order_key: key,
                expected_version: Some(1),
            }],
            &user_meta("cycle"),
        )
        .expect_err("expected cycle error");
    assert!(matches!(err, Error::CycleDetected(_)));
    store.check_invariants()?;
    Ok(())
}

#[test]
fn undo_detects_actor_conflict_and_title_collision() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Shared".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "v1".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    let agent_txn = store
        .apply_ops(
            &[Op::UpdateBlock {
                id: block_id,
                content: "agent edit".to_string(),
                expected_version: Some(1),
            }],
            &agent_meta("agent update"),
        )?
        .txn_id
        .context("agent txn_id")?;

    store.apply_ops(
        &[Op::UpdateBlock {
            id: block_id,
            content: "human edit".to_string(),
            expected_version: Some(2),
        }],
        &user_meta("human update"),
    )?;

    let err = store
        .undo(agent_txn, &user_meta("undo agent"), false)
        .expect_err("expected undo actor conflict");
    assert!(matches!(err, Error::UndoConflict { .. }));

    store.undo(agent_txn, &user_meta("force undo agent"), true)?;
    let block = store.get_block(block_id)?.context("block exists")?;
    assert_eq!(block.content, "v1");

    let del_txn = store
        .apply_ops(
            &[Op::DeletePage {
                id: page_id,
                expected_version: None,
            }],
            &user_meta("delete page"),
        )?
        .txn_id
        .context("del txn_id")?;

    let replacement_page = Id::new();
    store.apply_ops(
        &[Op::CreatePage {
            id: replacement_page,
            title: "Shared".to_string(),
            journal_day: None,
            document_mode: false,
        }],
        &user_meta("recreate title"),
    )?;

    let title_conflict = store
        .undo(del_txn, &user_meta("undo delete"), false)
        .expect_err("expected title collision conflict");
    assert!(matches!(
        title_conflict,
        Error::UndoConflict {
            txn_id,
            entity_id,
            ..
        } if txn_id == del_txn && entity_id == page_id
    ));
    Ok(())
}

fn seed_page_with_block(store: &mut Store, content: &str) -> Result<Id> {
    let page_id = Id::new();
    let block_id = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Notes".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: content.to_string(),
            },
        ],
        &user_meta("seed"),
    )?;
    Ok(block_id)
}

fn update(store: &mut Store, id: Id, content: &str) -> Result<Id> {
    store
        .apply_ops(
            &[Op::UpdateBlock {
                id,
                content: content.to_string(),
                expected_version: None,
            }],
            &user_meta("update"),
        )?
        .txn_id
        .context("update txn_id")
}

#[test]
fn double_undo_is_rejected_and_keeps_later_edits() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let block_id = seed_page_with_block(&mut store, "Hello")?;
    let edit = update(&mut store, block_id, "Hello world")?;

    store.undo(edit, &user_meta("undo"), false)?;
    update(&mut store, block_id, "Hi there")?;

    let err = store
        .undo(edit, &user_meta("undo again"), true)
        .expect_err("second undo must be rejected even with force");
    assert!(matches!(err, Error::AlreadyUndone(id) if id == edit));

    let block = store.get_block(block_id)?.context("block exists")?;
    assert_eq!(block.content, "Hi there");
    Ok(())
}

#[test]
fn undoing_an_undo_redoes_and_allows_undo_again() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let block_id = seed_page_with_block(&mut store, "Hello")?;
    let edit = update(&mut store, block_id, "Hello world")?;

    let undo_txn = store
        .undo(edit, &user_meta("undo"), false)?
        .txn_id
        .context("undo txn_id")?;
    assert!(store.is_undone(edit)?);

    store.undo(undo_txn, &user_meta("redo"), false)?;
    assert!(!store.is_undone(edit)?);
    assert_eq!(
        store.get_block(block_id)?.context("block")?.content,
        "Hello world"
    );

    store.undo(edit, &user_meta("undo after redo"), false)?;
    assert_eq!(
        store.get_block(block_id)?.context("block")?.content,
        "Hello"
    );
    Ok(())
}

#[test]
fn undo_origin_is_reserved_for_store_undo() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let block_id = seed_page_with_block(&mut store, "Hello")?;

    let err = store
        .apply_ops(
            &[Op::UpdateBlock {
                id: block_id,
                content: "forged".to_string(),
                expected_version: None,
            }],
            &TxMeta::new(Origin::Undo, "me", "forged undo"),
        )
        .expect_err("callers must not create undo txns directly");
    assert!(matches!(err, Error::ReservedOrigin(Origin::Undo)));
    assert_eq!(
        store.get_block(block_id)?.context("block")?.content,
        "Hello"
    );
    Ok(())
}

#[test]
fn undo_is_consistent_across_connections_to_one_file() -> Result<()> {
    let path = std::env::temp_dir().join(format!("pith-undo-{}.db", Id::new()));
    let result = (|| -> Result<()> {
        let mut app = Store::open(&path)?;
        let mut cli = Store::open(&path)?;

        let block_id = seed_page_with_block(&mut app, "Hello")?;
        let edit = update(&mut app, block_id, "Hello world")?;

        cli.undo(edit, &user_meta("undo from cli"), false)?;
        let err = app
            .undo(edit, &user_meta("undo from app"), false)
            .expect_err("second process must see the first undo");
        assert!(matches!(err, Error::AlreadyUndone(id) if id == edit));
        assert_eq!(app.get_block(block_id)?.context("block")?.content, "Hello");
        Ok(())
    })();
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    result
}

#[derive(Debug, Clone)]
enum Action {
    CreatePage {
        title_idx: u16,
        doc_mode: bool,
    },
    RenamePage {
        page_idx: usize,
        title_idx: u16,
    },
    DeletePage {
        page_idx: usize,
    },
    InsertBlock {
        page_idx: usize,
        parent_idx: Option<usize>,
        text: u16,
    },
    UpdateBlock {
        block_idx: usize,
        text: u16,
    },
    MoveBlock {
        block_idx: usize,
        page_idx: usize,
        parent_idx: Option<usize>,
    },
    DeleteBlock {
        block_idx: usize,
    },
    SetCollapsed {
        block_idx: usize,
        collapsed: bool,
    },
}

fn action_strategy() -> impl Strategy<Value = Action> {
    prop_oneof![
        (any::<u16>(), any::<bool>()).prop_map(|(title_idx, doc_mode)| Action::CreatePage {
            title_idx,
            doc_mode,
        }),
        (0usize..10, any::<u16>()).prop_map(|(page_idx, title_idx)| Action::RenamePage {
            page_idx,
            title_idx,
        }),
        (0usize..10).prop_map(|page_idx| Action::DeletePage { page_idx }),
        (0usize..10, prop::option::of(0usize..20), any::<u16>()).prop_map(
            |(page_idx, parent_idx, text)| Action::InsertBlock {
                page_idx,
                parent_idx,
                text,
            }
        ),
        (0usize..20, any::<u16>())
            .prop_map(|(block_idx, text)| Action::UpdateBlock { block_idx, text }),
        (0usize..20, 0usize..10, prop::option::of(0usize..20)).prop_map(
            |(block_idx, page_idx, parent_idx)| Action::MoveBlock {
                block_idx,
                page_idx,
                parent_idx,
            }
        ),
        (0usize..20).prop_map(|block_idx| Action::DeleteBlock { block_idx }),
        (0usize..20, any::<bool>()).prop_map(|(block_idx, collapsed)| Action::SetCollapsed {
            block_idx,
            collapsed,
        }),
    ]
}

fn is_ancestor(store: &Store, candidate: Id, mut node: Id) -> bool {
    loop {
        if node == candidate {
            return true;
        }
        match store
            .get_block(node)
            .ok()
            .flatten()
            .and_then(|b| b.parent_id)
        {
            Some(parent) => node = parent,
            None => return false,
        }
    }
}

fn rich_block_content(text: u16, counter: u64, live_pages: &[Id], live_blocks: &[Id]) -> String {
    match text % 6 {
        0 => format!(
            "TODO Work on [[RefPage-{}]] #tag-{} item-{counter}",
            text % 4,
            text % 3
        ),
        1 => format!(
            "DONE Finished #[[Topic {}]] `[[ignored]]` note-{counter}\npriority:: p{}",
            text % 3,
            text % 4
        ),
        2 => {
            if let Some(&target_block) = live_blocks.get((text as usize) % live_blocks.len().max(1))
            {
                format!("Depends on (({target_block})) and [[RefPage-{}]]", text % 4)
            } else {
                format!("Plain note {text}-{counter}")
            }
        }
        3 => {
            if let Some(&target_page) = live_pages.get((text as usize) % live_pages.len().max(1)) {
                format!("owner:: [[{target_page}]]\nstatus:: active-{counter}")
            } else {
                format!("status:: active-{counter}")
            }
        }
        4 => format!("```\n#include <stdio.h>\n[[not-a-page]]\n```\nAfter code {text}-{counter}"),
        _ => format!("block-{text}-{counter} #tag-{}", text % 3),
    }
}

fn build_op(store: &Store, action: Action, counter: u64) -> Option<Op> {
    let snapshot_before = store.live_snapshot().expect("snapshot before");
    let live_pages: Vec<Id> = snapshot_before.pages.keys().copied().collect();
    let live_blocks: Vec<Id> = snapshot_before.blocks.keys().copied().collect();

    match action {
        Action::CreatePage {
            title_idx,
            doc_mode,
        } => {
            let title = format!("Page-{title_idx}-{counter}");
            Some(Op::CreatePage {
                id: Id::new(),
                title,
                journal_day: None,
                document_mode: doc_mode,
            })
        }
        Action::RenamePage {
            page_idx,
            title_idx,
        } => live_pages
            .get(page_idx % live_pages.len().max(1))
            .map(|&id| Op::RenamePage {
                id,
                title: format!("Renamed-{title_idx}-{counter}"),
                expected_version: None,
            }),
        Action::DeletePage { page_idx } => {
            live_pages
                .get(page_idx % live_pages.len().max(1))
                .map(|&id| Op::DeletePage {
                    id,
                    expected_version: None,
                })
        }
        Action::InsertBlock {
            page_idx,
            parent_idx,
            text,
        } => live_pages
            .get(page_idx % live_pages.len().max(1))
            .map(|&page_id| {
                let page_blocks: Vec<Id> = snapshot_before
                    .blocks
                    .values()
                    .filter(|b| b.page_id == page_id)
                    .map(|b| b.id)
                    .collect();
                let parent_id = parent_idx.and_then(|pi| {
                    if page_blocks.is_empty() {
                        None
                    } else {
                        Some(page_blocks[pi % page_blocks.len()])
                    }
                });
                let siblings = store.list_children(page_id, parent_id).expect("children");
                let last_key = siblings.last().map(|b| b.order_key.as_str());
                let order_key = order::between(last_key, None).expect("order key");
                Op::InsertBlock {
                    id: Id::new(),
                    page_id,
                    parent_id,
                    order_key,
                    content: rich_block_content(text, counter, &live_pages, &live_blocks),
                }
            }),
        Action::UpdateBlock { block_idx, text } => live_blocks
            .get(block_idx % live_blocks.len().max(1))
            .map(|&id| Op::UpdateBlock {
                id,
                content: rich_block_content(text, counter, &live_pages, &live_blocks),
                expected_version: None,
            }),
        Action::MoveBlock {
            block_idx,
            page_idx,
            parent_idx,
        } => {
            if live_blocks.is_empty() || live_pages.is_empty() {
                None
            } else {
                let id = live_blocks[block_idx % live_blocks.len()];
                let target_page = live_pages[page_idx % live_pages.len()];
                let candidates: Vec<Id> = snapshot_before
                    .blocks
                    .values()
                    .filter(|b| b.page_id == target_page && !is_ancestor(store, id, b.id))
                    .map(|b| b.id)
                    .collect();
                let parent_id = parent_idx.and_then(|pi| {
                    if candidates.is_empty() {
                        None
                    } else {
                        Some(candidates[pi % candidates.len()])
                    }
                });
                let siblings = store
                    .list_children(target_page, parent_id)
                    .expect("children");
                let last_key = siblings.last().map(|b| b.order_key.as_str());
                let order_key = order::between(last_key, None).expect("order key");
                Some(Op::MoveBlock {
                    id,
                    page_id: target_page,
                    parent_id,
                    order_key,
                    expected_version: None,
                })
            }
        }
        Action::DeleteBlock { block_idx } => live_blocks
            .get(block_idx % live_blocks.len().max(1))
            .map(|&id| Op::DeleteBlock {
                id,
                expected_version: None,
            }),
        Action::SetCollapsed {
            block_idx,
            collapsed,
        } => live_blocks
            .get(block_idx % live_blocks.len().max(1))
            .map(|&id| Op::SetCollapsed { id, collapsed }),
    }
}

#[derive(Debug, Clone)]
enum Step {
    Apply(Action),
    Undo { txn_idx: usize, force: bool },
}

fn step_strategy() -> impl Strategy<Value = Step> {
    prop_oneof![
        3 => action_strategy().prop_map(Step::Apply),
        2 => (0usize..60, any::<bool>()).prop_map(|(txn_idx, force)| Step::Undo { txn_idx, force }),
    ]
}

proptest! {
    #[test]
    fn fractional_order_bisection_remains_strictly_ordered(steps in prop::collection::vec(any::<bool>(), 1..40)) {
        let mut keys = vec![
            order::between(None, None).expect("initial key"),
        ];
        for go_left in steps {
            let idx = keys.len() / 2;
            let new_key = if go_left {
                let lower = if idx > 0 { Some(keys[idx - 1].as_str()) } else { None };
                let upper = Some(keys[idx].as_str());
                let k = order::between(lower, upper).expect("between left");
                keys.insert(idx, k.clone());
                k
            } else {
                let lower = Some(keys[idx].as_str());
                let upper = keys.get(idx + 1).map(String::as_str);
                let k = order::between(lower, upper).expect("between right");
                keys.insert(idx + 1, k.clone());
                k
            };
            prop_assert!(!new_key.is_empty());
            for pair in keys.windows(2) {
                prop_assert!(pair[0] < pair[1], "keys out of order: {} >= {}", pair[0], pair[1]);
            }
        }
    }

    #[test]
    fn random_ops_preserve_invariants_and_full_unwind(actions in prop::collection::vec(action_strategy(), 1..45)) {
        let mut store = Store::open_in_memory().expect("open in memory");
        let initial_snapshot = store.live_snapshot().expect("initial snapshot");
        let mut applied_txns: Vec<Id> = Vec::new();
        let mut counter: u64 = 0;

        for action in actions {
            counter += 1;
            let maybe_op = build_op(&store, action, counter);

            if let Some(op) = maybe_op {
                let res = store.apply_ops(&[op], &user_meta("prop")).expect("valid op");
                store.check_invariants().expect("invariants hold");
                if let Some(txn_id) = res.txn_id {
                    applied_txns.push(txn_id);
                }
            }
        }

        for txn_id in applied_txns.into_iter().rev() {
            store.undo(txn_id, &user_meta("unwind"), false).expect("unwind undo");
            store.check_invariants().expect("invariants hold on unwind");
        }

        let final_snapshot = store.live_snapshot().expect("final snapshot");
        prop_assert_eq!(initial_snapshot, final_snapshot);
    }

    #[test]
    fn failed_calls_change_nothing_and_successes_keep_invariants(steps in prop::collection::vec(step_strategy(), 1..60)) {
        let mut store = Store::open_in_memory().expect("open in memory");
        let mut counter: u64 = 0;

        for step in steps {
            counter += 1;
            let before = store.live_snapshot().expect("snapshot before");
            let txns_before = store.list_txns(None).expect("txns before").len();

            let outcome = match step {
                Step::Apply(action) => match build_op(&store, action, counter) {
                    Some(op) => store.apply_ops(&[op], &user_meta("prop")).map(|_| ()),
                    None => continue,
                },
                Step::Undo { txn_idx, force } => {
                    let txns = store.list_txns(None).expect("txns");
                    if txns.is_empty() {
                        continue;
                    }
                    let target = txns[txn_idx % txns.len()].id;
                    store.undo(target, &user_meta("prop undo"), force).map(|_| ())
                }
            };

            store.check_invariants().expect("invariants hold");
            if outcome.is_err() {
                prop_assert_eq!(&before, &store.live_snapshot().expect("snapshot after"));
                prop_assert_eq!(txns_before, store.list_txns(None).expect("txns after").len());
            }
        }

        for txn in store.list_txns(None).expect("all txns") {
            if store.is_undone(txn.id).expect("is_undone") {
                let again = store.undo(txn.id, &user_meta("double undo"), true);
                prop_assert!(matches!(again, Err(Error::AlreadyUndone(id)) if id == txn.id));
            }
        }
    }
}
