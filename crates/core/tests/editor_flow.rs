use anyhow::{Context, Result};
use pith_core::editor::parse_paste;
use pith_core::parser::{
    CompletionContext, CompletionKind, apply_completion, auto_pair, completion_context,
};
use pith_core::{Crumb, Id, Op, Origin, Store, TxMeta, order};

fn meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::User, "me", summary)
}

struct Page {
    store: Store,
    page: Id,
}

impl Page {
    fn new(title: &str) -> Result<Self> {
        let mut store = Store::open_in_memory()?;
        let page = Id::new();
        store.apply_ops(
            &[Op::CreatePage {
                id: page,
                title: title.to_string(),
                journal_day: None,
                document_mode: false,
            }],
            &meta("page"),
        )?;
        Ok(Self { store, page })
    }

    fn add(&mut self, parent: Option<Id>, text: &str) -> Result<Id> {
        let last = self
            .store
            .list_children(self.page, parent)?
            .last()
            .map(|b| b.order_key.clone());
        let id = Id::new();
        self.store.apply_ops(
            &[Op::InsertBlock {
                id,
                page_id: self.page,
                parent_id: parent,
                order_key: order::between(last.as_deref(), None)?,
                content: text.to_string(),
            }],
            &meta("add"),
        )?;
        Ok(id)
    }

    fn texts(&self, parent: Option<Id>) -> Result<Vec<String>> {
        Ok(self
            .store
            .list_children(self.page, parent)?
            .into_iter()
            .map(|b| self.store.render_content(&b.content))
            .collect::<pith_core::Result<_>>()?)
    }

    fn version(&self, id: Id) -> Result<i64> {
        Ok(self.store.get_block(id)?.context("block")?.version)
    }

    fn content(&self, id: Id) -> Result<String> {
        Ok(self.store.get_block(id)?.context("block")?.content)
    }
}

fn delete_page(store: &mut Store, id: Id) -> Result<Id> {
    store
        .apply_ops(
            &[Op::DeletePage {
                id,
                expected_version: None,
            }],
            &meta("delete page"),
        )?
        .txn_id
        .context("txn")
}

#[test]
fn editing_around_a_link_to_a_deleted_page_keeps_the_link_and_the_page_restorable() -> Result<()> {
    let mut p = Page::new("Home")?;
    let block = p.add(None, "Read [[Atomic Habits]] soon")?;
    let habits = p
        .store
        .get_page_by_title("Atomic Habits")?
        .context("page")?
        .id;
    let deletion = delete_page(&mut p.store, habits)?;

    p.store.apply_ops(
        &[Op::UpdateBlock {
            id: block,
            content: "Read [[Atomic Habits]] today".to_string(),
            expected_version: None,
        }],
        &meta("edit"),
    )?;

    assert_eq!(p.content(block)?, format!("Read [[{habits}]] today"));
    assert!(p.store.get_page_by_title("Atomic Habits")?.is_none());
    p.store.undo(deletion, &meta("restore"), false)?;
    assert_eq!(
        p.store
            .get_page_by_title("Atomic Habits")?
            .context("restored")?
            .id,
        habits
    );
    Ok(())
}

#[test]
fn splitting_and_merging_keep_links_to_deleted_pages() -> Result<()> {
    let mut p = Page::new("Home")?;
    let block = p.add(None, "Before [[Gone]] middle [[Gone Too]]")?;
    let gone = p.store.get_page_by_title("Gone")?.context("gone")?.id;
    let gone_too = p
        .store
        .get_page_by_title("Gone Too")?
        .context("gone too")?
        .id;
    delete_page(&mut p.store, gone)?;
    delete_page(&mut p.store, gone_too)?;

    let v = p.version(block)?;
    let split = p.store.split_block(
        block,
        v,
        "Before [[Gone]] middle ",
        "[[Gone Too]]",
        &meta("split"),
    )?;
    assert_eq!(p.content(split.focus_block)?, format!("[[{gone_too}]]"));

    let v = p.version(split.focus_block)?;
    p.store
        .merge_into_previous(split.focus_block, v, "[[Gone Too]]", &meta("merge"))?
        .context("merge applies")?;
    assert_eq!(
        p.content(block)?,
        format!("Before [[{gone}]] middle [[{gone_too}]]")
    );
    assert_eq!(p.store.list_live_pages()?.len(), 1);
    Ok(())
}

#[test]
fn a_new_title_still_creates_a_page() -> Result<()> {
    let mut p = Page::new("Home")?;
    let block = p.add(None, "plain")?;
    p.store.apply_ops(
        &[Op::UpdateBlock {
            id: block,
            content: "plain [[Brand New]]".to_string(),
            expected_version: None,
        }],
        &meta("edit"),
    )?;
    assert!(p.store.get_page_by_title("Brand New")?.is_some());
    Ok(())
}

#[test]
fn move_up_and_down_swap_siblings_and_carry_children() -> Result<()> {
    let mut p = Page::new("Home")?;
    let a = p.add(None, "A")?;
    p.add(None, "B")?;
    let c = p.add(None, "C")?;
    p.add(Some(c), "C child")?;

    let v = p.version(c)?;
    p.store.move_block_up(c, v, &meta("up"))?.context("moved")?;
    assert_eq!(p.texts(None)?, vec!["A", "C", "B"]);
    assert_eq!(p.texts(Some(c))?, vec!["C child"]);

    let v = p.version(a)?;
    assert!(p.store.move_block_up(a, v, &meta("up"))?.is_none());
    p.store
        .move_block_down(a, v, &meta("down"))?
        .context("moved")?;
    assert_eq!(p.texts(None)?, vec!["C", "A", "B"]);

    let last = p
        .store
        .list_children(p.page, None)?
        .last()
        .context("last")?
        .id;
    let v = p.version(last)?;
    assert!(p.store.move_block_down(last, v, &meta("down"))?.is_none());
    Ok(())
}

#[test]
fn revealing_a_hidden_block_expands_its_ancestors_and_reports_its_row() -> Result<()> {
    let mut p = Page::new("Home")?;
    p.add(None, "First")?;
    let parent = p.add(None, "Parent")?;
    let child = p.add(Some(parent), "Hidden child")?;
    p.store.apply_ops(
        &[Op::SetCollapsed {
            id: parent,
            collapsed: true,
        }],
        &meta("collapse"),
    )?;
    assert_eq!(p.store.visible_index(child)?, None);

    assert_eq!(p.store.reveal_block(child, &meta("reveal"))?, 2);
    assert!(!p.store.get_block(parent)?.context("parent")?.collapsed);
    Ok(())
}

#[test]
fn zooming_reads_a_subtree_with_a_breadcrumb() -> Result<()> {
    let mut p = Page::new("Projects")?;
    p.add(None, "Other")?;
    let parent = p.add(None, "Pith\nsecond line")?;
    let child = p.add(Some(parent), "Editor")?;
    p.add(Some(child), "Autocomplete")?;

    let window = p.store.read_block_window(child, 0, 10)?;
    let rows: Vec<(String, u32)> = window
        .rows
        .iter()
        .map(|r| (r.rendered_content.clone(), r.depth))
        .collect();
    assert_eq!(
        rows,
        vec![("Editor".to_string(), 0), ("Autocomplete".to_string(), 1)]
    );

    assert_eq!(
        p.store.block_breadcrumb(child)?,
        vec![
            Crumb {
                block_id: None,
                label: "Projects".to_string()
            },
            Crumb {
                block_id: Some(parent),
                label: "Pith".to_string()
            },
            Crumb {
                block_id: Some(child),
                label: "Editor".to_string()
            },
        ]
    );
    Ok(())
}

#[test]
fn page_suggestions_match_by_prefix_then_substring() -> Result<()> {
    let mut p = Page::new("Home")?;
    p.add(None, "[[Roadmap]] [[Road trip]] [[Product roadmap]]")?;
    let titles = |q: &str, s: &Store| -> Result<Vec<String>> {
        Ok(s.suggest_pages(q, 10)?
            .into_iter()
            .map(|p| p.title)
            .collect())
    };
    assert_eq!(
        titles("road", &p.store)?,
        vec!["Road trip", "Roadmap", "Product roadmap"]
    );
    assert_eq!(titles("ro", &p.store)?, vec!["Road trip", "Roadmap"]);
    assert_eq!(p.store.suggest_pages("", 2)?.len(), 2);
    Ok(())
}

fn ctx(kind: CompletionKind, query: &str, start: usize, end: usize) -> Option<CompletionContext> {
    Some(CompletionContext {
        kind,
        query: query.to_string(),
        start,
        end,
    })
}

#[test]
fn completion_contexts_are_detected_at_the_caret() {
    assert_eq!(
        completion_context("see [[Road", 10),
        ctx(CompletionKind::Page, "Road", 4, 10)
    );
    assert_eq!(
        completion_context("see [[Road]]", 10),
        ctx(CompletionKind::Page, "Road", 4, 12)
    );
    assert_eq!(
        completion_context("see [[]]", 6),
        ctx(CompletionKind::Page, "", 4, 8)
    );
    assert_eq!(
        completion_context("tag #[[Big Ide", 14),
        ctx(CompletionKind::Tag, "Big Ide", 4, 14)
    );
    assert_eq!(
        completion_context("ref ((cargo", 11),
        ctx(CompletionKind::Block, "cargo", 4, 11)
    );
    assert_eq!(
        completion_context("note #caf", 9),
        ctx(CompletionKind::Tag, "caf", 5, 9)
    );
    assert_eq!(
        completion_context("note #", 6),
        ctx(CompletionKind::Tag, "", 5, 6)
    );
}

#[test]
fn completion_is_not_offered_outside_an_open_token() {
    assert_eq!(completion_context("done [[Road]] now", 17), None);
    assert_eq!(completion_context("café#x", 6), None);
    assert_eq!(completion_context("line [[a\nb", 10), None);
    assert_eq!(completion_context("plain text", 5), None);
}

#[test]
fn applying_a_completion_replaces_the_token_and_places_the_caret_after_it() {
    let page = ctx(CompletionKind::Page, "Road", 4, 12).expect("ctx");
    assert_eq!(
        apply_completion("see [[Road]] x", &page, "Roadmap"),
        ("see [[Roadmap]] x".to_string(), 15)
    );

    let tag = ctx(CompletionKind::Tag, "big", 5, 9).expect("ctx");
    assert_eq!(
        apply_completion("note #big", &tag, "Big Idea"),
        ("note #[[Big Idea]]".to_string(), 18)
    );

    let block = ctx(CompletionKind::Block, "car", 0, 5).expect("ctx");
    assert_eq!(
        apply_completion("((car", &block, "abc"),
        ("((abc))".to_string(), 7)
    );
}

#[test]
fn double_brackets_auto_pair_once() {
    assert_eq!(auto_pair("see [[", 6), Some("see [[]]".to_string()));
    assert_eq!(auto_pair("x ((", 4), Some("x (())".to_string()));
    assert_eq!(auto_pair("see [[]]", 6), None);
    assert_eq!(auto_pair("see [", 5), None);
}

#[test]
fn pasted_bullets_and_paragraphs_become_blocks() {
    let bullets = parse_paste("- One\n  - Nested\n- Two");
    assert_eq!(bullets.len(), 2);
    assert_eq!(bullets[0].content, "One");
    assert_eq!(bullets[0].children[0].content, "Nested");

    let paragraphs = parse_paste("First para\nsame para\n\nSecond para\n\n\nThird");
    let contents: Vec<&str> = paragraphs.iter().map(|n| n.content.as_str()).collect();
    assert_eq!(
        contents,
        vec!["First para\nsame para", "Second para", "Third"]
    );

    assert_eq!(parse_paste("one line").len(), 1);
}

#[test]
fn pasting_an_outline_splits_the_block_and_nests_children() -> Result<()> {
    let mut p = Page::new("Home")?;
    let block = p.add(None, "Hello world")?;
    p.add(None, "Next")?;

    let v = p.version(block)?;
    let outcome = p
        .store
        .paste_text(
            block,
            v,
            "Hello ",
            "world",
            "- One\n- Two\n  - Two child",
            &meta("paste"),
        )?
        .context("multi-block paste")?;

    assert_eq!(p.texts(None)?, vec!["Hello One", "Twoworld", "Next"]);
    assert_eq!(p.content(outcome.focus_block)?, "Twoworld");
    assert_eq!(outcome.cursor, Some(3));
    assert_eq!(p.texts(Some(outcome.focus_block))?, vec!["Two child"]);

    let v = p.version(block)?;
    assert!(
        p.store
            .paste_text(block, v, "a", "b", "single line", &meta("paste"))?
            .is_none()
    );
    Ok(())
}

#[test]
fn a_subtree_copies_as_clean_markdown() -> Result<()> {
    let mut p = Page::new("Home")?;
    let parent = p.add(None, "Parent [[Pith]]\nsecond line")?;
    let child = p.add(Some(parent), "Child")?;
    p.add(Some(child), "Grandchild")?;

    assert_eq!(
        p.store.subtree_markdown(parent)?,
        "- Parent [[Pith]]\n  second line\n  - Child\n    - Grandchild"
    );
    Ok(())
}
