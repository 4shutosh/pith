use anyhow::{Context, Result};
use pith_core::{Api, Error, Op, Origin, SearchResultItem, ShowResult, Store, TxMeta};

fn user_meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::User, "me", summary)
}

fn agent_meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::Agent, "agent:claude", summary)
}

#[test]
fn journal_append_nested_tree_show_search_backlinks_and_undo() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);

    let markdown =
        "- Ship M2 [[Roadmap]] #pith\n  - Add CLI\n    - Support json output\n  - Add tests";
    let outcome = api.journal_append(markdown, Some("2026-11-25"), &user_meta("journal"), false)?;
    assert!(!outcome.dry_run);
    let txn_short = outcome.txn_short_id.context("txn short id")?;
    assert!(txn_short.len() >= 6);
    assert_eq!(outcome.created_ids.len(), 7);

    let journal = api
        .journal_show(Some("2026-11-25"), None)?
        .context("journal page")?;
    assert_eq!(journal.title, "2026-11-25");
    assert_eq!(journal.blocks.len(), 1);
    assert_eq!(journal.blocks[0].children.len(), 2);
    assert_eq!(journal.blocks[0].children[0].children.len(), 1);

    let outline = journal.format_outline();
    assert!(outline.contains("# 2026-11-25 (page "));
    assert!(outline.contains("- Ship M2 [[Roadmap]] #pith  ^"));
    assert!(outline.contains("  - Add CLI  ^"));
    assert!(outline.contains("    - Support json output  ^"));

    let limited = api
        .journal_show(Some("2026-11-25"), Some(1))?
        .context("journal depth 1")?;
    assert_eq!(limited.blocks[0].children.len(), 2);
    assert!(limited.blocks[0].children[0].children.is_empty());

    let backlinks = api.backlinks("Roadmap")?;
    assert_eq!(backlinks.backlinks.len(), 1);

    let hits = api.search("Road", 10)?;
    assert!(
        hits.iter()
            .any(|h| matches!(h, SearchResultItem::Page { title, .. } if title == "Roadmap"))
    );

    let root_short = journal.blocks[0].short_id.clone();
    let show_block = api.show(&format!("^{root_short}"), None)?;
    assert!(matches!(show_block, ShowResult::Block(b) if b.short_id == root_short));

    api.undo(&txn_short, &user_meta("undo journal"), false, false)?;
    assert!(api.journal_show(Some("2026-11-25"), None)?.is_none());
    Ok(())
}

#[test]
fn dry_run_validates_without_persisting() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);

    let planned =
        api.journal_append("Dry run note", Some("2026-11-25"), &user_meta("dry"), true)?;
    assert!(planned.dry_run);
    assert!(planned.txn_id.is_none());
    assert_eq!(planned.ops.len(), 2);
    assert!(api.journal_show(Some("2026-11-25"), None)?.is_none());

    let real = api.journal_append("Real note", Some("2026-11-25"), &user_meta("real"), false)?;
    let block_short = real.created_short_ids[1].clone();

    let err = api
        .update(
            &block_short,
            "Stale",
            Some(99),
            &user_meta("dry stale"),
            true,
        )
        .expect_err("dry run must still validate expected_version");
    assert!(matches!(err, Error::VersionMismatch { .. }));

    let dry_upd = api.update(&block_short, "Changed", Some(1), &user_meta("dry ok"), true)?;
    assert!(dry_upd.dry_run);
    let shown = api.show(&block_short, None)?;
    assert!(matches!(shown, ShowResult::Block(b) if b.content == "Real note"));
    Ok(())
}

#[test]
fn insert_after_move_and_delete_by_short_suffix() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);

    api.journal_append(
        "- First\n- Third",
        Some("2026-11-25"),
        &user_meta("seed"),
        false,
    )?;
    let page = api
        .journal_show(Some("2026-11-25"), None)?
        .context("page")?;
    let first_short = page.blocks[0].short_id.clone();

    api.insert(
        "2026-11-25",
        Some(&first_short),
        "Second",
        &user_meta("insert middle"),
        false,
    )?;

    let page = api
        .journal_show(Some("2026-11-25"), None)?
        .context("page")?;
    let contents: Vec<&str> = page.blocks.iter().map(|b| b.content.as_str()).collect();
    assert_eq!(contents, vec!["First", "Second", "Third"]);

    let third_short = page.blocks[2].short_id.clone();
    api.move_block(
        &third_short,
        &first_short,
        None,
        Some(1),
        &user_meta("nest third under first"),
        false,
    )?;

    let page = api
        .journal_show(Some("2026-11-25"), None)?
        .context("page")?;
    assert_eq!(page.blocks.len(), 2);
    assert_eq!(page.blocks[0].children.len(), 1);
    assert_eq!(page.blocks[0].children[0].content, "Third");

    api.delete(&third_short, Some(2), &user_meta("rm third"), false)?;
    let page = api
        .journal_show(Some("2026-11-25"), None)?
        .context("page")?;
    assert!(page.blocks[0].children.is_empty());

    let hist = api.history(Some("me"), None, 10)?;
    assert_eq!(hist.len(), 4);
    Ok(())
}

#[test]
fn dry_run_includes_auto_created_pages_in_planned_ops() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);

    let planned = api.journal_append(
        "See [[TypoPage]]",
        Some("2026-11-25"),
        &user_meta("dry"),
        true,
    )?;
    assert!(planned.dry_run);
    assert!(
        planned
            .ops
            .iter()
            .any(|op| { matches!(op, Op::CreatePage { title, .. } if title == "TypoPage") })
    );
    assert!(api.show("TypoPage", None).is_err());
    Ok(())
}

#[test]
fn agent_writes_require_expected_version() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);

    api.journal_append("Note", Some("2026-11-25"), &user_meta("seed"), false)?;
    let page = api
        .journal_show(Some("2026-11-25"), None)?
        .context("page")?;
    let block_short = page.blocks[0].short_id.clone();

    assert!(matches!(
        api.update(&block_short, "Agent edit", None, &agent_meta("upd"), false),
        Err(Error::MissingExpectedVersion)
    ));
    assert!(matches!(
        api.move_block(
            &block_short,
            "2026-11-25",
            None,
            None,
            &agent_meta("mv"),
            false
        ),
        Err(Error::MissingExpectedVersion)
    ));
    assert!(matches!(
        api.delete(&block_short, None, &agent_meta("rm"), false),
        Err(Error::MissingExpectedVersion)
    ));

    api.update(
        &block_short,
        "Agent edit",
        Some(1),
        &agent_meta("upd"),
        false,
    )?;
    let hist = api.history(None, None, 10)?;
    assert_eq!(hist.len(), 2);
    assert_eq!(hist[0].actor, "agent:claude");
    assert_eq!(hist[1].actor, "me");
    Ok(())
}

#[test]
fn short_hex_words_do_not_resolve_as_suffix_and_non_sibling_after_is_rejected() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);

    api.journal_append(
        "- Parent\n  - Child",
        Some("2026-11-25"),
        &user_meta("seed"),
        false,
    )?;
    let page = api
        .journal_show(Some("2026-11-25"), None)?
        .context("page")?;
    let child_short = page.blocks[0].children[0].short_id.clone();

    for word in ["cafe", "deed", "add", "beef"] {
        assert!(matches!(api.show(word, None), Err(Error::NotFoundRef(_))));
    }

    let err = api
        .insert(
            "2026-11-25",
            Some(&child_short),
            "Wrong sibling",
            &user_meta("bad after"),
            false,
        )
        .expect_err("child is not a root sibling");
    assert!(matches!(err, Error::NotASibling { .. }));
    Ok(())
}

#[test]
fn described_errors_use_short_ids_while_display_keeps_full_ids() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);

    api.journal_append("Note", Some("2026-11-25"), &user_meta("seed"), false)?;
    let page = api
        .journal_show(Some("2026-11-25"), None)?
        .context("page")?;
    let block = &page.blocks[0];

    let err = api
        .update(
            &block.short_id,
            "Stale",
            Some(99),
            &agent_meta("upd"),
            false,
        )
        .expect_err("stale version must be rejected");
    let full_id = block.id.to_string();

    let described = api.describe_error(&err);
    assert_eq!(
        described,
        format!(
            "version mismatch for {}: expected 99, actual 1",
            block.short_id
        )
    );
    assert!(!described.contains(&full_id));
    assert!(err.to_string().contains(&full_id));
    Ok(())
}

#[test]
fn invariants_detect_id_rev_drift() -> Result<()> {
    let path = std::env::temp_dir().join(format!("pith-idrev-{}.db", pith_core::Id::new()));
    let result = (|| -> Result<()> {
        let mut store = Store::open(&path)?;
        let mut api = Api::new(&mut store);
        api.journal_append("Note", Some("2026-11-25"), &user_meta("seed"), false)?;
        store.check_invariants()?;

        let raw = rusqlite::Connection::open(&path)?;
        raw.execute("UPDATE blocks SET id_rev = 'corrupted'", [])?;

        assert!(matches!(
            store.check_invariants(),
            Err(Error::InvariantViolation(_))
        ));
        Ok(())
    })();
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    result
}

#[test]
fn search_items_carry_the_matched_line_without_repeating_block_content() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let mut api = Api::new(&mut store);
    api.journal_append(
        "Rust book\nHello, Cargo!\n$ cargo --version",
        Some("2026-11-25"),
        &user_meta("seed"),
        false,
    )?;

    let items = api.search("cargo", 10)?;
    let lines: Vec<String> = items
        .iter()
        .map(|item| match item {
            SearchResultItem::Block { matched_line, .. } => matched_line.clone(),
            SearchResultItem::Page { title, .. } => panic!("unexpected page {title}"),
        })
        .collect();
    assert_eq!(lines, vec!["Hello, Cargo!", "$ cargo --version"]);

    let json = serde_json::to_value(&items[0])?;
    assert_eq!(json["breadcrumb"], serde_json::json!(["2026-11-25"]));
    assert!(json.get("content").is_none());
    Ok(())
}
