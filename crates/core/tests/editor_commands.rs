use anyhow::{Context, Result};
use pith_core::{Error, Id, Op, Origin, RenderedSpan, Store, TxMeta, order};

fn user_meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::User, "me", summary)
}

struct Fixture {
    store: Store,
    page: Id,
}

impl Fixture {
    fn new() -> Result<Self> {
        let mut store = Store::open_in_memory()?;
        let page = Id::new();
        store.apply_ops(
            &[Op::CreatePage {
                id: page,
                title: "Outline".to_string(),
                journal_day: None,
                document_mode: false,
            }],
            &user_meta("page"),
        )?;
        Ok(Self { store, page })
    }

    fn block(
        &mut self,
        parent: Option<Id>,
        after_key: Option<&str>,
        text: &str,
    ) -> Result<(Id, String)> {
        let id = Id::new();
        let key = order::between(after_key, None)?;
        self.store.apply_ops(
            &[Op::InsertBlock {
                id,
                page_id: self.page,
                parent_id: parent,
                order_key: key.clone(),
                content: text.to_string(),
            }],
            &user_meta("seed"),
        )?;
        Ok((id, key))
    }

    fn children_text(&self, parent: Option<Id>) -> Result<Vec<String>> {
        Ok(self
            .store
            .list_children(self.page, parent)?
            .into_iter()
            .map(|b| b.content)
            .collect())
    }

    fn version(&self, id: Id) -> Result<i64> {
        Ok(self.store.get_block(id)?.context("block")?.version)
    }

    fn texts(&self) -> Result<Vec<String>> {
        Ok(self
            .store
            .read_page_window(self.page, 0, 100)?
            .rows
            .into_iter()
            .map(|r| r.rendered_content)
            .collect())
    }

    fn depths(&self) -> Result<Vec<u32>> {
        Ok(self
            .store
            .read_page_window(self.page, 0, 100)?
            .rows
            .into_iter()
            .map(|r| r.depth)
            .collect())
    }
}

#[test]
fn split_inserts_directly_after_the_block_before_its_next_sibling() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, ka) = f.block(None, None, "Alpha beta")?;
    f.block(None, Some(&ka), "Next")?;

    let v = f.version(a)?;
    let outcome = f
        .store
        .split_block(a, v, "Alpha", " beta", &user_meta("split"))?;

    assert_eq!(f.children_text(None)?, vec!["Alpha", " beta", "Next"]);
    assert_eq!(outcome.cursor, Some(0));
    f.store.check_invariants()?;
    Ok(())
}

#[test]
fn split_of_an_expanded_parent_creates_its_first_child() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "Parent")?;
    f.block(Some(a), None, "Existing child")?;

    let v = f.version(a)?;
    f.store
        .split_block(a, v, "Parent", "", &user_meta("split"))?;

    assert_eq!(f.children_text(Some(a))?, vec!["", "Existing child"]);
    Ok(())
}

#[test]
fn split_with_a_stale_version_changes_nothing() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "Original")?;
    f.store.apply_ops(
        &[Op::UpdateBlock {
            id: a,
            content: "Changed elsewhere".to_string(),
            expected_version: None,
        }],
        &TxMeta::new(Origin::Agent, "agent:claude", "agent edit"),
    )?;

    let err = f
        .store
        .split_block(a, 1, "Orig", "inal", &user_meta("split"))
        .expect_err("stale base version must conflict");
    assert!(matches!(err, Error::VersionMismatch { .. }));
    assert_eq!(f.children_text(None)?, vec!["Changed elsewhere"]);
    Ok(())
}

#[test]
fn indent_under_a_collapsed_sibling_appends_after_its_hidden_children() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, ka) = f.block(None, None, "A")?;
    let (_, k1) = f.block(Some(a), None, "A1")?;
    f.block(Some(a), Some(&k1), "A2")?;
    let (b, _) = f.block(None, Some(&ka), "B")?;
    f.store.apply_ops(
        &[Op::SetCollapsed {
            id: a,
            collapsed: true,
        }],
        &user_meta("collapse"),
    )?;

    let v = f.version(b)?;
    f.store
        .indent_block(b, v, &user_meta("indent"))?
        .context("indent applies")?;

    assert_eq!(f.children_text(Some(a))?, vec!["A1", "A2", "B"]);
    assert!(!f.store.get_block(a)?.context("a")?.collapsed);
    f.store.check_invariants()?;
    Ok(())
}

#[test]
fn indent_of_a_first_child_is_a_no_op() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "Only")?;
    let v = f.version(a)?;
    assert!(f.store.indent_block(a, v, &user_meta("indent"))?.is_none());
    Ok(())
}

#[test]
fn outdent_places_the_block_right_after_its_parent() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, ka) = f.block(None, None, "A")?;
    let (child, _) = f.block(Some(a), None, "Child")?;
    f.block(None, Some(&ka), "B")?;

    let v = f.version(child)?;
    f.store
        .outdent_block(child, v, &user_meta("outdent"))?
        .context("outdent applies")?;

    assert_eq!(f.children_text(None)?, vec!["A", "Child", "B"]);
    Ok(())
}

#[test]
fn merge_appends_text_to_the_previous_visible_block() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, ka) = f.block(None, None, "Hello")?;
    let (b, _) = f.block(None, Some(&ka), " world")?;

    let v = f.version(b)?;
    let outcome = f
        .store
        .merge_into_previous(b, v, " world", &user_meta("merge"))?
        .context("merge applies")?;

    assert_eq!(f.children_text(None)?, vec!["Hello world"]);
    assert_eq!(outcome.focus_block, a);
    assert_eq!(outcome.cursor, Some(5));
    Ok(())
}

#[test]
fn merge_is_a_no_op_for_the_first_block_or_a_block_with_children() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "First")?;
    f.block(Some(a), None, "Child")?;
    let v = f.version(a)?;
    assert!(
        f.store
            .merge_into_previous(a, v, "First", &user_meta("merge"))?
            .is_none()
    );
    Ok(())
}

#[test]
fn journal_is_created_with_its_first_block_and_undo_removes_both() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    assert!(store.journal_page(Some("2026-11-25"))?.is_none());

    let outcome = store.start_journal(Some("2026-11-25"), &user_meta("start journal"))?;
    let page = store
        .journal_page(Some("2026-11-25"))?
        .context("journal exists")?;
    assert_eq!(store.list_children(page.id, None)?.len(), 1);
    assert_eq!(outcome.cursor, Some(0));

    store.undo_last(&user_meta("undo"), false)?;
    assert!(store.journal_page(Some("2026-11-25"))?.is_none());
    store.check_invariants()?;
    Ok(())
}

#[test]
fn rows_carry_rendered_spans_from_the_core_tokenizer() -> Result<()> {
    let mut f = Fixture::new()?;
    let (target, kt) = f.block(None, None, "Referenced block")?;
    let content = format!("TODO read [[Atomic Habits]] #books `[[not-a-link]]` (({target}))");
    f.block(None, Some(&kt), &content)?;

    let habits = f
        .store
        .get_page_by_title("Atomic Habits")?
        .context("page")?;
    let books = f.store.get_page_by_title("books")?.context("tag page")?;
    let window = f.store.read_page_window(f.page, 0, 10)?;
    let spans = &window.rows[1].spans;

    assert_eq!(
        spans[0],
        RenderedSpan::Task {
            state: "TODO".to_string(),
            source: "TODO".to_string(),
        }
    );
    assert!(spans.contains(&RenderedSpan::PageLink {
        page_id: Some(habits.id),
        title: "Atomic Habits".to_string(),
        source: "[[Atomic Habits]]".to_string(),
        deleted: false,
    }));
    assert!(spans.contains(&RenderedSpan::Tag {
        page_id: Some(books.id),
        title: "books".to_string(),
        source: "#books".to_string(),
        deleted: false,
    }));
    assert!(spans.contains(&RenderedSpan::Code("`[[not-a-link]]`".to_string())));
    assert!(spans.contains(&RenderedSpan::BlockRef {
        block_id: target,
        text: "Referenced block".to_string(),
        source: format!("(({target}))"),
    }));
    let joined: String = spans.iter().map(RenderedSpan::source).collect();
    assert_eq!(
        joined,
        format!("TODO read [[Atomic Habits]] #books `[[not-a-link]]` (({target}))")
    );
    Ok(())
}

#[test]
fn a_version_1_database_migrates_and_supports_undo_groups() -> Result<()> {
    let path = std::env::temp_dir().join(format!("pith-migrate-{}.db", Id::new()));
    let result = (|| -> Result<()> {
        drop(Store::open(&path)?);
        let raw = rusqlite::Connection::open(&path)?;
        raw.execute_batch(
            "DROP INDEX idx_txns_actor_undo_group;
             ALTER TABLE txns DROP COLUMN undo_group;
             ALTER TABLE pages DROP COLUMN favorite;
             DROP TABLE view_log;
             DROP INDEX idx_blocks_page_live;
             CREATE INDEX idx_blocks_page ON blocks(page_id);
             DROP INDEX idx_refs_target_src;
             CREATE INDEX idx_refs_target ON refs(target);
             PRAGMA user_version = 1;",
        )?;
        drop(raw);

        let mut store = Store::open(&path)?;
        let outcome = store.start_journal(
            Some("2026-11-25"),
            &user_meta("start").with_undo_group("burst"),
        )?;
        assert!(outcome.result.txn_id.is_some());
        store.check_invariants()?;
        Ok(())
    })();
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    result
}

#[test]
fn multi_word_tags_keep_their_bracket_form_as_source() -> Result<()> {
    let mut f = Fixture::new()?;
    f.block(None, None, "  DONE ship #[[Release Plan]] today")?;
    let spans = f.store.read_page_window(f.page, 0, 10)?.rows[0]
        .spans
        .clone();

    assert_eq!(
        spans[0],
        RenderedSpan::Task {
            state: "DONE".to_string(),
            source: "  DONE".to_string(),
        }
    );
    let tag_source = spans.iter().find_map(|s| match s {
        RenderedSpan::Tag { source, .. } => Some(source.clone()),
        _ => None,
    });
    assert_eq!(tag_source.as_deref(), Some("#[[Release Plan]]"));
    Ok(())
}

#[test]
fn cycling_a_task_walks_todo_doing_done_and_back_to_plain() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "Write the ADR")?;

    let mut seen = Vec::new();
    for _ in 0..4 {
        let v = f.version(a)?;
        f.store.cycle_task(a, v, &user_meta("cycle"))?;
        seen.push(f.store.get_block(a)?.context("block")?.content);
    }
    assert_eq!(
        seen,
        vec![
            "TODO Write the ADR",
            "DOING Write the ADR",
            "DONE Write the ADR",
            "Write the ADR",
        ]
    );
    Ok(())
}

#[test]
fn toggling_done_checks_and_unchecks_a_task() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "DOING Write the ADR")?;

    let v = f.version(a)?;
    f.store.toggle_task_done(a, v, &user_meta("check"))?;
    assert_eq!(
        f.store.get_block(a)?.context("block")?.content,
        "DONE Write the ADR"
    );

    let v = f.version(a)?;
    f.store.toggle_task_done(a, v, &user_meta("uncheck"))?;
    assert_eq!(
        f.store.get_block(a)?.context("block")?.content,
        "TODO Write the ADR"
    );
    Ok(())
}

#[test]
fn task_commands_respect_the_editor_base_version() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "Write the ADR")?;
    f.store.cycle_task(a, 1, &user_meta("cycle"))?;
    let err = f
        .store
        .cycle_task(a, 1, &user_meta("stale cycle"))
        .expect_err("stale version must be rejected");
    assert!(matches!(err, Error::VersionMismatch { .. }));
    Ok(())
}

#[test]
fn bulk_delete_prunes_descendants_and_undoes_in_one_step() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, ak) = f.block(None, None, "A")?;
    let (a1, _) = f.block(Some(a), None, "A1")?;
    let (b, bk) = f.block(None, Some(&ak), "B")?;
    let (_c, _) = f.block(None, Some(&bk), "C")?;

    let applied = f
        .store
        .delete_blocks(&[a1, b, a], &user_meta("delete selection"))?;
    assert!(applied.is_some());
    assert_eq!(f.texts()?, vec!["C"]);

    f.store.undo_last(&user_meta("undo"), false)?;
    assert_eq!(f.texts()?, vec!["A", "A1", "B", "C"]);
    Ok(())
}

#[test]
fn bulk_indent_and_outdent_preserve_order_in_one_undo_step() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, ak) = f.block(None, None, "A")?;
    let (b, bk) = f.block(None, Some(&ak), "B")?;
    let (c, _) = f.block(None, Some(&bk), "C")?;

    f.store.indent_blocks(&[c, b], &user_meta("indent"))?;
    assert_eq!(f.texts()?, vec!["A", "B", "C"]);
    assert_eq!(f.depths()?, vec![0, 1, 1]);
    assert_eq!(f.store.get_block(b)?.context("b")?.parent_id, Some(a));
    assert_eq!(f.store.get_block(c)?.context("c")?.parent_id, Some(a));

    f.store.outdent_blocks(&[b, c], &user_meta("outdent"))?;
    assert_eq!(f.texts()?, vec!["A", "B", "C"]);
    assert_eq!(f.depths()?, vec![0, 0, 0]);

    f.store.undo_last(&user_meta("undo outdent"), false)?;
    assert_eq!(f.depths()?, vec![0, 1, 1]);
    f.store.undo_last(&user_meta("undo indent"), false)?;
    assert_eq!(f.depths()?, vec![0, 0, 0]);
    Ok(())
}

#[test]
fn bulk_move_up_and_down_shifts_selection_in_one_step() -> Result<()> {
    let mut f = Fixture::new()?;
    let (_a, ak) = f.block(None, None, "A")?;
    let (b, bk) = f.block(None, Some(&ak), "B")?;
    let (c, ck) = f.block(None, Some(&bk), "C")?;
    let (_d, _) = f.block(None, Some(&ck), "D")?;

    f.store.move_blocks_up(&[c, b], &user_meta("move up"))?;
    assert_eq!(f.texts()?, vec!["B", "C", "A", "D"]);

    f.store.move_blocks_down(&[b, c], &user_meta("move down"))?;
    assert_eq!(f.texts()?, vec!["A", "B", "C", "D"]);

    f.store.undo_last(&user_meta("undo move down"), false)?;
    assert_eq!(f.texts()?, vec!["B", "C", "A", "D"]);
    f.store.undo_last(&user_meta("undo move up"), false)?;
    assert_eq!(f.texts()?, vec!["A", "B", "C", "D"]);
    Ok(())
}

#[test]
fn bulk_cycle_tasks_and_markdown_export() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, ak) = f.block(None, None, "First")?;
    let (a1, _) = f.block(Some(a), None, "Child")?;
    let (b, _) = f.block(None, Some(&ak), "Second")?;

    f.store.cycle_tasks(&[b, a], &user_meta("todo"))?;
    assert_eq!(f.texts()?, vec!["TODO First", "Child", "TODO Second"]);

    f.store.cycle_tasks(&[a, b], &user_meta("doing"))?;
    assert_eq!(f.texts()?, vec!["DOING First", "Child", "DOING Second"]);

    assert_eq!(
        f.store.blocks_markdown(&[a, a1, b])?,
        "- DOING First\n  - Child\n- DOING Second"
    );

    f.store.undo_last(&user_meta("undo doing"), false)?;
    assert_eq!(f.texts()?, vec!["TODO First", "Child", "TODO Second"]);
    Ok(())
}

#[test]
fn inline_formatting_spans_toggle_slash_and_favorites() -> Result<()> {
    let mut f = Fixture::new()?;
    let (id, _) = f.block(
        None,
        None,
        "Say **bold** *italic* ~~gone~~ ==mark== [docs](https://pith.app) and https://example.com.",
    )?;
    let row = f.store.block_row(id)?.context("row")?;
    let joined: String = row.spans.iter().map(|s| s.source()).collect();
    assert_eq!(joined, row.rendered_content);
    assert!(row.spans.contains(&RenderedSpan::Bold {
        text: "bold".to_string(),
        source: "**bold**".to_string(),
    }));
    assert!(row.spans.contains(&RenderedSpan::Italic {
        text: "italic".to_string(),
        source: "*italic*".to_string(),
    }));
    assert!(row.spans.contains(&RenderedSpan::Strike {
        text: "gone".to_string(),
        source: "~~gone~~".to_string(),
    }));
    assert!(row.spans.contains(&RenderedSpan::Highlight {
        text: "mark".to_string(),
        source: "==mark==".to_string(),
    }));
    assert!(row.spans.contains(&RenderedSpan::ExternalLink {
        label: "docs".to_string(),
        url: "https://pith.app".to_string(),
        source: "[docs](https://pith.app)".to_string(),
    }));
    assert!(row.spans.contains(&RenderedSpan::ExternalLink {
        label: "https://example.com".to_string(),
        url: "https://example.com".to_string(),
        source: "https://example.com".to_string(),
    }));

    let (wrapped, s, e) = pith_core::parser::toggle_inline_format(
        "hello world",
        6,
        11,
        pith_core::parser::InlineFormat::Bold,
    );
    assert_eq!((wrapped.as_str(), s, e), ("hello **world**", 8, 13));
    let (unwrapped, s2, e2) = pith_core::parser::toggle_inline_format(
        &wrapped,
        s,
        e,
        pith_core::parser::InlineFormat::Bold,
    );
    assert_eq!((unwrapped.as_str(), s2, e2), ("hello world", 6, 11));

    let slash = pith_core::parser::completion_context("run /tod", 8).context("slash")?;
    assert_eq!(slash.kind, pith_core::parser::CompletionKind::Slash);
    assert_eq!(slash.query, "tod");
    assert_eq!(
        pith_core::parser::apply_completion("run /tod", &slash, "[[2026-11-26]]"),
        ("run [[2026-11-26]]".to_string(), 18)
    );

    f.store.apply_ops(
        &[Op::SetPageFavorite {
            id: f.page,
            favorite: true,
        }],
        &user_meta("favorite"),
    )?;
    assert!(f.store.get_page(f.page)?.context("page")?.favorite);

    f.store
        .start_journal(Some("2026-11-25"), &user_meta("j1"))?;
    f.store
        .start_journal(Some("2026-11-26"), &user_meta("j2"))?;
    let journals: Vec<String> = f
        .store
        .list_journals(10)?
        .into_iter()
        .map(|p| p.title)
        .collect();
    assert_eq!(journals, vec!["2026-11-26", "2026-11-25"]);
    assert_eq!(
        pith_core::journal::shift_journal_date(Some("2026-11-26"), -1)?,
        "2026-11-25"
    );
    Ok(())
}

#[test]
fn list_page_summaries_counts_live_blocks_and_backlinks() -> Result<()> {
    let mut f = Fixture::new()?;
    let (b1, k1) = f.block(None, None, "Links to [[Hub]] and [[Hub]]")?;
    let (b2, _) = f.block(None, Some(&k1), "Also mentions [[Hub]]")?;
    f.store.apply_ops(
        &[Op::DeleteBlock {
            id: b2,
            expected_version: Some(1),
        }],
        &user_meta("delete second"),
    )?;
    assert!(f.store.get_block(b1)?.is_some());

    let summaries = f.store.list_page_summaries()?;
    let outline = summaries
        .iter()
        .find(|s| s.page.title == "Outline")
        .context("outline summary")?;
    let hub = summaries
        .iter()
        .find(|s| s.page.title == "Hub")
        .context("hub summary")?;

    assert_eq!(outline.block_count, 1);
    assert_eq!(outline.backlink_count, 0);
    assert_eq!(hub.block_count, 0);
    assert_eq!(hub.backlink_count, 1);
    Ok(())
}

#[test]
fn bulk_commands_refuse_a_selection_spanning_pages() -> Result<()> {
    let mut f = Fixture::new()?;
    let (a, _) = f.block(None, None, "A")?;
    let other_page = Id::new();
    let other = Id::new();
    f.store.apply_ops(
        &[
            Op::CreatePage {
                id: other_page,
                title: "Elsewhere".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: other,
                page_id: other_page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "X".to_string(),
            },
        ],
        &user_meta("other page"),
    )?;

    let err = f
        .store
        .delete_blocks(&[a, other], &user_meta("delete"))
        .expect_err("mixed pages are rejected");
    assert!(matches!(err, Error::BlocksOnDifferentPages { block_id, .. } if block_id == other));
    assert_eq!(f.texts()?, vec!["A"]);
    assert!(
        f.store
            .get_block(other)?
            .context("other")?
            .deleted_at
            .is_none()
    );
    Ok(())
}

#[test]
fn bulk_move_with_gaps_moves_each_run_past_its_neighbour() -> Result<()> {
    let mut f = Fixture::new()?;
    let (_a, ak) = f.block(None, None, "A")?;
    let (b, bk) = f.block(None, Some(&ak), "B")?;
    let (_c, ck) = f.block(None, Some(&bk), "C")?;
    let (d, dk) = f.block(None, Some(&ck), "D")?;
    let (_e, _) = f.block(None, Some(&dk), "E")?;

    f.store.move_blocks_down(&[b, d], &user_meta("down"))?;
    assert_eq!(f.texts()?, vec!["A", "C", "B", "E", "D"]);

    f.store.move_blocks_up(&[b, d], &user_meta("up"))?;
    assert_eq!(f.texts()?, vec!["A", "B", "C", "D", "E"]);

    f.store.move_blocks_up(&[b, d], &user_meta("up"))?;
    assert_eq!(f.texts()?, vec!["B", "A", "D", "C", "E"]);
    Ok(())
}

#[test]
fn starting_a_page_creates_it_with_its_first_block_in_one_undoable_step() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    assert_eq!(store.next_untitled_title()?, "Untitled");

    let cursor = store.change_cursor()?;
    let outcome = store.start_page("Untitled", &user_meta("new page"))?;
    let page = store
        .get_page_by_title("Untitled")?
        .context("page exists")?;
    assert_eq!(
        store
            .get_block(outcome.focus_block)?
            .context("block")?
            .page_id,
        page.id
    );
    assert_eq!(
        store.changes_after(cursor)?.cursor.txn_seq,
        cursor.txn_seq + 1
    );
    assert_eq!(store.next_untitled_title()?, "Untitled 2");

    store.undo_last(&user_meta("undo"), false)?;
    assert!(store.get_page_by_title("Untitled")?.is_none());
    assert_eq!(store.next_untitled_title()?, "Untitled");

    store.start_page("Untitled", &user_meta("again"))?;
    store.start_page("Untitled 2", &user_meta("second"))?;
    assert_eq!(store.next_untitled_title()?, "Untitled 3");
    assert!(store.start_page("Untitled", &user_meta("taken")).is_err());
    Ok(())
}

fn write_journal(store: &mut Store, day: &str, texts: &[&str]) -> Result<Id> {
    let first = store.start_journal(Some(day), &user_meta(day))?.focus_block;
    let page_id = store.get_block(first)?.context("first block")?.page_id;
    let mut key = store.get_block(first)?.context("first block")?.order_key;
    let mut ops = vec![Op::UpdateBlock {
        id: first,
        content: texts[0].to_string(),
        expected_version: None,
    }];
    for text in &texts[1..] {
        key = order::between(Some(&key), None)?;
        ops.push(Op::InsertBlock {
            id: Id::new(),
            page_id,
            parent_id: None,
            order_key: key.clone(),
            content: text.to_string(),
        });
    }
    store.apply_ops(&ops, &user_meta("write"))?;
    Ok(page_id)
}

fn delete_block_of(store: &mut Store, page_id: Id) -> Result<()> {
    let block = store
        .list_children(page_id, None)?
        .into_iter()
        .next()
        .context("a block")?;
    store.apply_ops(
        &[Op::DeleteBlock {
            id: block.id,
            expected_version: None,
        }],
        &user_meta("delete block"),
    )?;
    Ok(())
}

fn create_empty_journal(store: &mut Store, title: &str, day: i32) -> Result<()> {
    store.apply_ops(
        &[Op::CreatePage {
            id: Id::new(),
            title: title.to_string(),
            journal_day: Some(day),
            document_mode: false,
        }],
        &user_meta("empty journal"),
    )?;
    Ok(())
}

#[test]
fn journals_before_pages_older_written_journals_and_skips_unwritten_days() -> Result<()> {
    let mut f = Fixture::new()?;
    for day in [
        "2026-10-30",
        "2026-11-01",
        "2026-11-02",
        "2026-11-03",
        "2026-11-28",
    ] {
        write_journal(&mut f.store, day, &["note"])?;
    }
    create_empty_journal(&mut f.store, "2026-10-31", 20261031)?;
    write_journal(&mut f.store, "2026-10-29", &["   "])?;
    let deleted = write_journal(&mut f.store, "2026-10-28", &["gone"])?;
    delete_block_of(&mut f.store, deleted)?;
    let titles = |before: i32, limit: usize| -> Result<Vec<String>> {
        Ok(f.store
            .journals_before(before, limit)?
            .into_iter()
            .map(|p| p.title)
            .collect())
    };
    assert_eq!(titles(20261128, 2)?, vec!["2026-11-03", "2026-11-02"]);
    assert_eq!(titles(20261102, 10)?, vec!["2026-11-01", "2026-10-30"]);
    assert_eq!(titles(20261030, 10)?, Vec::<String>::new());
    Ok(())
}

#[test]
fn journal_activity_counts_written_blocks_per_day_in_an_inclusive_range() -> Result<()> {
    let mut f = Fixture::new()?;
    write_journal(&mut f.store, "2026-10-25", &["before the range"])?;
    let busy = write_journal(&mut f.store, "2026-10-26", &["one", "", "two", "three"])?;
    let mid = write_journal(&mut f.store, "2026-11-15", &["mid"])?;
    write_journal(&mut f.store, "2026-12-06", &["last day", "again"])?;
    write_journal(&mut f.store, "2026-12-07", &["after the range"])?;
    create_empty_journal(&mut f.store, "2026-11-05", 20261105)?;
    write_journal(&mut f.store, "2026-11-08", &[" ", "\t"])?;
    let deleted_block = write_journal(&mut f.store, "2026-11-10", &["gone"])?;
    delete_block_of(&mut f.store, deleted_block)?;
    let deleted_page = write_journal(&mut f.store, "2026-11-20", &["page gone"])?;
    f.store.apply_ops(
        &[Op::DeletePage {
            id: deleted_page,
            expected_version: None,
        }],
        &user_meta("delete page"),
    )?;

    let days: Vec<(i32, u32)> = f
        .store
        .journal_activity(20261026..=20261206)?
        .into_iter()
        .map(|d| (d.journal_day, d.block_count))
        .collect();
    assert_eq!(days, vec![(20261026, 3), (20261115, 1), (20261206, 2)]);

    let november = f.store.journal_activity(20261101..=20261130)?;
    assert_eq!(november.len(), 1);
    assert_eq!(november[0].page_id, mid);
    assert_ne!(november[0].page_id, busy);
    assert!(f.store.journal_activity(20261116..=20261205)?.is_empty());
    Ok(())
}
