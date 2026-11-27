use anyhow::{Context, Result};
use pith_core::parser::classify_block;
use pith_core::{BlockKind, Id, Op, Origin, PageMatch, RenderedSpan, Store, TxMeta, order};

fn meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::User, "me", summary)
}

#[test]
fn block_kinds_classify_headings_code_quote_divider_and_paragraph() {
    assert_eq!(classify_block("# Title"), BlockKind::Heading { level: 1 });
    assert_eq!(classify_block("## Sub"), BlockKind::Heading { level: 2 });
    assert_eq!(classify_block("### Deep"), BlockKind::Heading { level: 3 });
    assert_eq!(classify_block("#### Too deep"), BlockKind::Paragraph);
    assert_eq!(classify_block("#tag is not heading"), BlockKind::Paragraph);
    assert_eq!(classify_block("> quoted line"), BlockKind::Quote);
    assert_eq!(classify_block("---"), BlockKind::Divider);
    assert_eq!(classify_block("***"), BlockKind::Divider);
    assert_eq!(classify_block("___"), BlockKind::Divider);
    assert_eq!(classify_block("--"), BlockKind::Paragraph);
    assert_eq!(
        classify_block("```rust\nlet x = 1;\n```"),
        BlockKind::CodeBlock {
            language: Some("rust".to_string()),
            code: "let x = 1;".to_string(),
        }
    );
    assert_eq!(
        classify_block("```\nplain\ncode\n```"),
        BlockKind::CodeBlock {
            language: None,
            code: "plain\ncode".to_string(),
        }
    );
    assert_eq!(
        classify_block("prose with `inline` code"),
        BlockKind::Paragraph
    );
}

#[test]
fn deleted_page_links_report_deleted_flag_and_restore_clears_it() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let home = Id::new();
    let target = Id::new();
    let block = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: home,
                title: "Home".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::CreatePage {
                id: target,
                title: "Legacy".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block,
                page_id: home,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "See [[Legacy]]".to_string(),
            },
        ],
        &meta("setup"),
    )?;

    store.apply_ops(
        &[Op::DeletePage {
            id: target,
            expected_version: Some(1),
        }],
        &meta("delete legacy"),
    )?;

    let row = store.block_row(block)?.context("row")?;
    assert!(row.spans.contains(&RenderedSpan::PageLink {
        page_id: Some(target),
        title: "Legacy".to_string(),
        source: "[[Legacy]]".to_string(),
        deleted: true,
    }));

    let preview = store.preview_page(target, 5)?.context("deleted preview")?;
    assert!(preview.deleted);
    assert_eq!(preview.title, "Legacy");

    store.apply_ops(&[Op::RestorePage { id: target }], &meta("restore legacy"))?;
    let restored = store.block_row(block)?.context("restored row")?;
    assert!(restored.spans.contains(&RenderedSpan::PageLink {
        page_id: Some(target),
        title: "Legacy".to_string(),
        source: "[[Legacy]]".to_string(),
        deleted: false,
    }));
    Ok(())
}

#[test]
fn find_in_page_returns_ordered_scalar_matches_and_respects_zoom_root() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    let a = Id::new();
    let b = Id::new();
    let c = Id::new();
    let k1 = order::between(None, None)?;
    let k2 = order::between(Some(&k1), None)?;
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Notes".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: a,
                page_id: page,
                parent_id: None,
                order_key: k1,
                content: "Café Rust and rust".to_string(),
            },
            Op::InsertBlock {
                id: b,
                page_id: page,
                parent_id: Some(a),
                order_key: order::between(None, None)?,
                content: "Nested RUST child".to_string(),
            },
            Op::InsertBlock {
                id: c,
                page_id: page,
                parent_id: None,
                order_key: k2,
                content: "Sibling rust".to_string(),
            },
        ],
        &meta("setup"),
    )?;

    let all = store.find_in_page(page, None, "rust")?;
    assert_eq!(
        all,
        vec![
            PageMatch {
                block_id: a,
                start: 5,
                len: 4
            },
            PageMatch {
                block_id: a,
                start: 14,
                len: 4
            },
            PageMatch {
                block_id: b,
                start: 7,
                len: 4
            },
            PageMatch {
                block_id: c,
                start: 8,
                len: 4
            },
        ]
    );

    let zoomed = store.find_in_page(page, Some(a), "rust")?;
    assert_eq!(zoomed.len(), 3);
    assert!(zoomed.iter().all(|m| m.block_id != c));
    Ok(())
}

#[test]
fn set_all_collapsed_collapses_and_expands_parents_in_scope() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    let root = Id::new();
    let child = Id::new();
    let grand = Id::new();
    let leaf = Id::new();
    let k1 = order::between(None, None)?;
    let k2 = order::between(Some(&k1), None)?;
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Tree".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: root,
                page_id: page,
                parent_id: None,
                order_key: k1,
                content: "Root".to_string(),
            },
            Op::InsertBlock {
                id: child,
                page_id: page,
                parent_id: Some(root),
                order_key: order::between(None, None)?,
                content: "Child".to_string(),
            },
            Op::InsertBlock {
                id: grand,
                page_id: page,
                parent_id: Some(child),
                order_key: order::between(None, None)?,
                content: "Grand".to_string(),
            },
            Op::InsertBlock {
                id: leaf,
                page_id: page,
                parent_id: None,
                order_key: k2,
                content: "Leaf".to_string(),
            },
        ],
        &meta("setup"),
    )?;

    let collapsed = store.set_all_collapsed(page, None, true, &meta("collapse all"))?;
    assert_eq!(collapsed, 2);
    assert!(store.get_block(root)?.context("root")?.collapsed);
    assert!(store.get_block(child)?.context("child")?.collapsed);
    assert!(!store.get_block(leaf)?.context("leaf")?.collapsed);

    let expanded = store.set_all_collapsed(page, None, false, &meta("expand all"))?;
    assert_eq!(expanded, 2);
    assert!(!store.get_block(root)?.context("root")?.collapsed);
    assert!(!store.get_block(child)?.context("child")?.collapsed);

    let zoomed_collapse =
        store.set_all_collapsed(page, Some(root), true, &meta("collapse zoomed"))?;
    assert_eq!(zoomed_collapse, 1);
    assert!(!store.get_block(root)?.context("root")?.collapsed);
    assert!(store.get_block(child)?.context("child")?.collapsed);
    Ok(())
}

#[test]
fn block_props_are_extracted_with_rendered_value_spans_and_body_spans() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    let owner = Id::new();
    let block = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Spec".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::CreatePage {
                id: owner,
                title: "Alice".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block,
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Main note\nstatus:: active\nowner:: [[Alice]]".to_string(),
            },
        ],
        &meta("setup"),
    )?;

    let row = store.block_row(block)?.context("row")?;
    assert_eq!(row.props.len(), 2);
    assert_eq!(row.props[0].key, "status");
    assert_eq!(row.props[0].value, "active");
    assert_eq!(row.props[1].key, "owner");
    assert_eq!(row.props[1].value, "[[Alice]]");
    assert_eq!(
        row.props[1].value_spans,
        vec![RenderedSpan::PageLink {
            page_id: Some(owner),
            title: "Alice".to_string(),
            source: "[[Alice]]".to_string(),
            deleted: false,
        }]
    );
    assert_eq!(
        row.body_spans,
        Some(vec![RenderedSpan::Text("Main note".to_string())])
    );
    Ok(())
}

#[test]
fn preview_page_and_block_return_lines_and_metadata() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    let parent = Id::new();
    let child = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Architecture".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: parent,
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Parent block".to_string(),
            },
            Op::InsertBlock {
                id: child,
                page_id: page,
                parent_id: Some(parent),
                order_key: order::between(None, None)?,
                content: "Child detail".to_string(),
            },
        ],
        &meta("setup"),
    )?;

    let page_preview = store.preview_page(page, 4)?.context("page preview")?;
    assert_eq!(page_preview.title, "Architecture");
    assert!(!page_preview.deleted);
    assert_eq!(page_preview.total_blocks, 2);
    assert_eq!(page_preview.lines.len(), 2);
    assert_eq!(page_preview.lines[0].depth, 0);
    assert_eq!(page_preview.lines[1].depth, 1);
    assert_eq!(page_preview.backlink_count, 0);
    assert!(page_preview.parent_path.is_empty());

    let block_preview = store.preview_block(child, 4)?.context("block preview")?;
    assert_eq!(block_preview.title, "Architecture");
    assert_eq!(block_preview.parent_path, vec!["Parent block".to_string()]);
    assert_eq!(block_preview.lines.len(), 1);
    Ok(())
}

#[test]
fn unlinked_references_exclude_linked_code_and_substrings_and_link_is_undoable() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let rust_page = Id::new();
    let notes = Id::new();
    let unlinked = Id::new();
    let already_linked = Id::new();
    let in_code = Id::new();
    let substring = Id::new();
    let k1 = order::between(None, None)?;
    let k2 = order::between(Some(&k1), None)?;
    let k3 = order::between(Some(&k2), None)?;
    let k4 = order::between(Some(&k3), None)?;

    store.apply_ops(
        &[
            Op::CreatePage {
                id: rust_page,
                title: "Rust".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::CreatePage {
                id: notes,
                title: "Journal".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: unlinked,
                page_id: notes,
                parent_id: None,
                order_key: k1,
                content: "Learning rust today".to_string(),
            },
            Op::InsertBlock {
                id: already_linked,
                page_id: notes,
                parent_id: None,
                order_key: k2,
                content: "Already linked [[Rust]]".to_string(),
            },
            Op::InsertBlock {
                id: in_code,
                page_id: notes,
                parent_id: None,
                order_key: k3,
                content: "Inside `rust` code".to_string(),
            },
            Op::InsertBlock {
                id: substring,
                page_id: notes,
                parent_id: None,
                order_key: k4,
                content: "Trust the process".to_string(),
            },
        ],
        &meta("setup"),
    )?;

    let refs = store.unlinked_references(rust_page, 20)?;
    assert_eq!(refs.len(), 1);
    assert_eq!(refs[0].block_id, unlinked);
    assert_eq!(refs[0].match_start, 9);
    assert_eq!(refs[0].match_len, 4);

    let before = store.live_snapshot()?;
    let applied = store
        .link_unlinked_reference(unlinked, rust_page, &meta("link unlinked"))?
        .context("linked")?;
    assert!(applied.txn_id.is_some());
    assert!(store.unlinked_references(rust_page, 20)?.is_empty());
    assert_eq!(store.backlinks(rust_page)?.len(), 2);

    store.undo_last(&meta("undo link"), false)?;
    assert_eq!(store.live_snapshot()?, before);
    assert_eq!(store.unlinked_references(rust_page, 20)?.len(), 1);
    Ok(())
}
