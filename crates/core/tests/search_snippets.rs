use anyhow::{Context, Result};
use pith_core::snippet::{LineMatch, Segment, highlight, matching_lines};
use pith_core::{Id, Op, Origin, SearchHit, Store, TxMeta, order};

fn segs(parts: &[(&str, bool)]) -> Vec<Segment> {
    parts
        .iter()
        .map(|(text, highlighted)| Segment {
            text: text.to_string(),
            highlighted: *highlighted,
        })
        .collect()
}

#[test]
fn highlight_marks_every_case_insensitive_occurrence() {
    assert_eq!(
        highlight("Manage the manager", "manage"),
        segs(&[
            ("Manage", true),
            (" the ", false),
            ("manage", true),
            ("r", false)
        ])
    );
}

#[test]
fn highlight_marks_each_query_word_separately() {
    assert_eq!(
        highlight("State management in Compose", "compose state"),
        segs(&[
            ("State", true),
            (" management in ", false),
            ("Compose", true)
        ])
    );
}

fn line(parts: &[(&str, bool)], cursor: usize) -> LineMatch {
    LineMatch {
        segments: segs(parts),
        cursor,
        line: parts.iter().map(|(text, _)| *text).collect(),
    }
}

#[test]
fn every_matching_line_is_returned_in_document_order() {
    let content = "\n\nThe Rust Programming Language\n \nHello, Cargo!\n  Cargo is the build tool\nNo match here";
    assert_eq!(
        matching_lines(content, "cargo"),
        vec![
            line(&[("Hello, ", false), ("Cargo", true), ("!", false)], 41),
            line(&[("Cargo", true), (" is the build tool", false)], 50),
        ]
    );
}

#[test]
fn the_cursor_points_at_the_first_match_in_the_line() {
    let content = "first\nsecond has needle twice needle";
    let matches = matching_lines(content, "needle");
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].cursor, 17);
    let chars: Vec<char> = content.chars().collect();
    let at_cursor: String = chars[17..23].iter().collect();
    assert_eq!(at_cursor, "needle");
}

#[test]
fn with_no_matching_line_the_first_non_empty_line_is_returned() {
    assert_eq!(
        matching_lines("\n  \nFirst real line\nSecond", "zzz"),
        vec![line(&[("First real line", false)], 4)]
    );
}

#[test]
fn long_lines_are_clipped_around_the_first_match() {
    let content = format!("{}needle{}", "a".repeat(300), "b".repeat(300));
    let matches = matching_lines(&content, "needle");
    let text: String = matches[0]
        .segments
        .iter()
        .map(|s| s.text.as_str())
        .collect();

    assert_eq!(text.chars().count(), 202);
    assert_eq!(
        text,
        format!("…{}needle{}…", "a".repeat(60), "b".repeat(134))
    );
    assert_eq!(matches[0].cursor, 300);
}

#[test]
fn highlight_handles_non_ascii_text() {
    assert_eq!(
        highlight("Café au lait", "CAFÉ"),
        segs(&[("Café", true), (" au lait", false)])
    );
}

#[test]
fn block_hits_carry_the_matching_line_and_a_breadcrumb() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let meta = TxMeta::new(Origin::User, "me", "seed");
    let page = Id::new();
    let parent = Id::new();
    let child = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Random".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: parent,
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Reading list\nsecond line".to_string(),
            },
            Op::InsertBlock {
                id: child,
                page_id: page,
                parent_id: Some(parent),
                order_key: order::between(None, None)?,
                content: "The Rust Programming Language\n\nHello, Cargo!".to_string(),
            },
        ],
        &meta,
    )?;

    let hits = store.search("cargo", 10)?;
    assert_eq!(hits.len(), 1);
    let hit = hits.first().context("one hit")?;
    let SearchHit::Block {
        block_id,
        breadcrumb,
        snippet,
        ..
    } = hit
    else {
        panic!("expected a block hit, got {hit:?}");
    };
    assert_eq!(*block_id, child);
    assert_eq!(
        breadcrumb,
        &vec!["Random".to_string(), "Reading list".to_string()]
    );
    assert_eq!(
        snippet,
        &segs(&[("Hello, ", false), ("Cargo", true), ("!", false)])
    );
    Ok(())
}

#[test]
fn a_block_with_several_matching_lines_yields_one_ranked_hit_per_line() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    let block = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Book".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block,
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Hello, Cargo!\nnothing here\n$ cargo --version\nCargo.toml lists deps"
                    .to_string(),
            },
        ],
        &TxMeta::new(Origin::User, "me", "seed"),
    )?;

    let lines: Vec<(Id, String, u32)> = store
        .search("cargo", 10)?
        .into_iter()
        .map(|hit| match hit {
            SearchHit::Block {
                block_id,
                snippet,
                cursor,
                ..
            } => (block_id, pith_core::snippet::plain(&snippet), cursor),
            SearchHit::Page { title, .. } => panic!("unexpected page hit {title}"),
        })
        .collect();

    assert_eq!(
        lines,
        vec![
            (block, "Cargo.toml lists deps".to_string(), 45),
            (block, "Hello, Cargo!".to_string(), 7),
            (block, "$ cargo --version".to_string(), 29),
        ]
    );
    assert_eq!(store.search("cargo", 2)?.len(), 2);
    Ok(())
}

#[test]
fn snippets_drop_link_brackets_but_keep_highlights_and_the_cursor() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Notes".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: Id::new(),
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Reading [[Atomic Habits]] tonight".to_string(),
            },
        ],
        &TxMeta::new(Origin::User, "me", "seed"),
    )?;
    let hits = store.search("atomic", 5)?;
    assert!(matches!(&hits[0], SearchHit::Page { title, .. } if title == "Atomic Habits"));
    let Some(SearchHit::Block {
        snippet,
        cursor,
        page_journal_day,
        ..
    }) = hits.get(1)
    else {
        panic!("expected a block hit, got {hits:?}");
    };
    assert_eq!(
        snippet,
        &segs(&[
            ("Reading ", false),
            ("Atomic", true),
            (" Habits tonight", false)
        ])
    );
    assert_eq!(*cursor, 10);
    assert_eq!(*page_journal_day, None);
    Ok(())
}
