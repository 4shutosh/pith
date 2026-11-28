use anyhow::Result;
use pith_core::{ContextLine, Id, Op, Origin, RenderedSpan, Store, TxMeta, order};

fn meta() -> TxMeta {
    TxMeta::new(Origin::User, "me", "test")
}

fn insert(
    store: &mut Store,
    page_id: Id,
    parent: Option<Id>,
    after: Option<&str>,
    content: &str,
) -> Result<(Id, String)> {
    let id = Id::new();
    let key = order::between(after, None)?;
    store.apply_ops(
        &[Op::InsertBlock {
            id,
            page_id,
            parent_id: parent,
            order_key: key.clone(),
            content: content.to_string(),
        }],
        &meta(),
    )?;
    Ok((id, key))
}

fn line(depth: u32, text: &str, is_target: bool) -> ContextLine {
    ContextLine {
        depth,
        spans: vec![RenderedSpan::Text(text.to_string())],
        is_target,
    }
}

struct Outline {
    store: Store,
    page: Id,
    chapter: Id,
    stacking: Id,
    detail: Id,
    tail: Id,
}

fn outline() -> Result<Outline> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    store.apply_ops(
        &[Op::CreatePage {
            id: page,
            title: "Atomic Habits".to_string(),
            journal_day: None,
            document_mode: false,
        }],
        &meta(),
    )?;
    let (_, intro_key) = insert(&mut store, page, None, None, "Intro")?;
    let (chapter, chapter_key) = insert(&mut store, page, None, Some(&intro_key), "Chapter 5")?;
    let (stacking, stacking_key) = insert(&mut store, page, Some(chapter), None, "Habit stacking")?;
    let (detail, _) = insert(
        &mut store,
        page,
        Some(stacking),
        None,
        "After coffee, meditate",
    )?;
    insert(
        &mut store,
        page,
        Some(chapter),
        Some(&stacking_key),
        "Implementation intentions",
    )?;
    let (tail, _) = insert(&mut store, page, None, Some(&chapter_key), "Chapter 6")?;
    Ok(Outline {
        store,
        page,
        chapter,
        stacking,
        detail,
        tail,
    })
}

#[test]
fn context_shows_the_target_between_its_neighbours_with_relative_depth() -> Result<()> {
    let o = outline()?;
    let context = o
        .store
        .search_context(o.stacking, 1, 2)?
        .expect("live block has context");
    assert_eq!(context.page_id, o.page);
    assert_eq!(context.page_title, "Atomic Habits");
    assert_eq!(context.journal_day, None);
    assert_eq!(context.crumbs, vec!["Chapter 5".to_string()]);
    assert_eq!(
        context.lines,
        vec![
            line(0, "Chapter 5", false),
            line(1, "Habit stacking", true),
            line(2, "After coffee, meditate", false),
            line(1, "Implementation intentions", false),
        ]
    );
    Ok(())
}

#[test]
fn context_reaches_blocks_hidden_under_a_collapsed_parent_and_clips_at_page_edges() -> Result<()> {
    let mut o = outline()?;
    o.store.apply_ops(
        &[Op::SetCollapsed {
            id: o.chapter,
            collapsed: true,
        }],
        &meta(),
    )?;
    let context = o
        .store
        .search_context(o.detail, 1, 5)?
        .expect("collapsed child still has context");
    assert_eq!(
        context.lines,
        vec![
            line(1, "Habit stacking", false),
            line(2, "After coffee, meditate", true),
            line(1, "Implementation intentions", false),
            line(0, "Chapter 6", false),
        ]
    );
    Ok(())
}

#[test]
fn deleted_blocks_have_no_context() -> Result<()> {
    let mut o = outline()?;
    o.store.apply_ops(
        &[Op::DeleteBlock {
            id: o.tail,
            expected_version: None,
        }],
        &meta(),
    )?;
    assert_eq!(o.store.search_context(o.tail, 1, 1)?, None);
    assert_eq!(o.store.search_context(Id::new(), 1, 1)?, None);
    Ok(())
}

#[test]
fn a_window_inside_a_subtree_starts_at_depth_zero_and_ends_at_the_target() -> Result<()> {
    let o = outline()?;
    let context = o
        .store
        .search_context(o.detail, 1, 0)?
        .expect("live block has context");
    assert_eq!(
        context.lines,
        vec![
            line(0, "Habit stacking", false),
            line(1, "After coffee, meditate", true)
        ]
    );
    assert_eq!(
        context.crumbs,
        vec!["Chapter 5".to_string(), "Habit stacking".to_string()]
    );
    Ok(())
}
