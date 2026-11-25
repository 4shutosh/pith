use anyhow::{Context, Result};
use pith_core::parser::{Highlight, HighlightKind, highlight_ranges};
use pith_core::{Id, Op, Origin, Store, TxMeta, order};

fn h(start: usize, len: usize, kind: HighlightKind) -> Highlight {
    Highlight { start, len, kind }
}

#[test]
fn links_split_into_dim_brackets_and_a_title() {
    assert_eq!(
        highlight_ranges("Read [[Atomic Habits]] now"),
        vec![
            h(5, 2, HighlightKind::Bracket),
            h(7, 13, HighlightKind::Link),
            h(20, 2, HighlightKind::Bracket),
        ]
    );
}

#[test]
fn tags_code_and_block_refs_are_highlighted_with_scalar_offsets() {
    assert_eq!(
        highlight_ranges("👍 #café `x` ((0190a6f0-0000-7000-8000-000000000001))"),
        vec![
            h(2, 5, HighlightKind::Tag),
            h(8, 3, HighlightKind::Code),
            h(12, 40, HighlightKind::BlockRef),
        ]
    );
}

#[test]
fn plain_text_has_no_highlights() {
    assert_eq!(highlight_ranges("just words"), Vec::<Highlight>::new());
}

#[test]
fn block_row_matches_the_row_in_the_page_window() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    let parent = Id::new();
    let child = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "P".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: parent,
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Parent".to_string(),
            },
            Op::InsertBlock {
                id: child,
                page_id: page,
                parent_id: Some(parent),
                order_key: order::between(None, None)?,
                content: "Child [[Linked]]".to_string(),
            },
        ],
        &TxMeta::new(Origin::User, "me", "seed"),
    )?;

    let window = store.read_page_window(page, 0, 10)?;
    assert_eq!(store.block_row(parent)?.context("parent")?, window.rows[0]);
    assert_eq!(store.block_row(child)?.context("child")?, window.rows[1]);
    assert_eq!(window.rows[1].depth, 1);
    assert!(window.rows[0].has_children);

    store.apply_ops(
        &[Op::DeleteBlock {
            id: child,
            expected_version: None,
        }],
        &TxMeta::new(Origin::User, "me", "delete"),
    )?;
    assert!(store.block_row(child)?.is_none());
    Ok(())
}
