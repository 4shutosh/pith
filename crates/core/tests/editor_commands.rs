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

    assert_eq!(spans[0], RenderedSpan::Task("TODO".to_string()));
    assert!(spans.contains(&RenderedSpan::PageLink {
        page_id: Some(habits.id),
        title: "Atomic Habits".to_string(),
    }));
    assert!(spans.contains(&RenderedSpan::Tag {
        page_id: Some(books.id),
        title: "books".to_string(),
    }));
    assert!(spans.contains(&RenderedSpan::Code("`[[not-a-link]]`".to_string())));
    assert!(spans.contains(&RenderedSpan::BlockRef {
        block_id: target,
        text: "Referenced block".to_string(),
    }));
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
