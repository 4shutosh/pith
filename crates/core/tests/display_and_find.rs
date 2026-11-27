use anyhow::{Context, Result};
use pith_core::api::parse_markdown_tree;
use pith_core::display::{RunStyle, block_display};
use pith_core::{BlockKind, Id, Op, Origin, RenderedSpan, Store, TxMeta, order};

fn meta() -> TxMeta {
    TxMeta::new(Origin::User, "me", "test")
}

fn page(store: &mut Store, title: &str) -> Result<Id> {
    let id = Id::new();
    store.apply_ops(
        &[Op::CreatePage {
            id,
            title: title.to_string(),
            journal_day: None,
            document_mode: false,
        }],
        &meta(),
    )?;
    Ok(id)
}

fn block(store: &mut Store, page_id: Id, parent: Option<Id>, text: &str) -> Result<Id> {
    let id = Id::new();
    let last = store
        .list_children(page_id, parent)?
        .last()
        .map(|b| b.order_key.clone());
    store.apply_ops(
        &[Op::InsertBlock {
            id,
            page_id,
            parent_id: parent,
            order_key: order::between(last.as_deref(), None)?,
            content: text.to_string(),
        }],
        &meta(),
    )?;
    Ok(id)
}

fn text(s: &str) -> RenderedSpan {
    RenderedSpan::Text(s.to_string())
}

#[test]
fn display_hides_markers_task_keywords_and_kind_prefixes() {
    let spans = vec![
        RenderedSpan::Task {
            state: "TODO".to_string(),
            source: "TODO".to_string(),
        },
        text("  ship "),
        RenderedSpan::Bold {
            text: "now".to_string(),
            source: "**now**".to_string(),
        },
        text(" in "),
        RenderedSpan::Code("`cargo`".to_string()),
        text(" see "),
        RenderedSpan::ExternalLink {
            label: "docs".to_string(),
            url: "https://pith.dev".to_string(),
            source: "[docs](https://pith.dev)".to_string(),
        },
    ];
    let shown = block_display(&spans, &BlockKind::Paragraph);
    assert_eq!(shown.task_state.as_deref(), Some("TODO"));
    assert_eq!(shown.prefix, "TODO  ");
    assert_eq!(shown.text(), "ship now in cargo see docs");
    let sources: String = shown.runs.iter().map(|r| r.source.as_str()).collect();
    assert_eq!(
        sources,
        "ship **now** in `cargo` see [docs](https://pith.dev)"
    );

    let heading = block_display(&[text("## Plan")], &BlockKind::Heading { level: 2 });
    assert_eq!(heading.text(), "Plan");
    assert_eq!(heading.runs[0].style, RunStyle::Marker);

    let quote = block_display(&[text("> Wisdom")], &BlockKind::Quote);
    assert_eq!(quote.text(), "Wisdom");
}

#[test]
fn find_matches_the_displayed_text_across_collapsed_blocks() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let notes = page(&mut store, "Notes")?;
    let bold = block(&mut store, notes, None, "**Bold** word pith")?;
    let link = block(&mut store, notes, None, "read [docs](https://pith.dev)")?;
    let heading = block(&mut store, notes, None, "# Plan pith")?;
    let parent = block(&mut store, notes, None, "parent")?;
    let hidden = block(&mut store, notes, Some(parent), "hidden pith")?;
    store.apply_ops(
        &[Op::SetCollapsed {
            id: parent,
            collapsed: true,
        }],
        &meta(),
    )?;

    let found: Vec<(Id, u32, u32)> = store
        .find_in_page(notes, None, "PITH")?
        .into_iter()
        .map(|m| (m.block_id, m.start, m.len))
        .collect();
    assert_eq!(found, vec![(bold, 10, 4), (heading, 5, 4), (hidden, 7, 4)]);
    assert!(store.find_in_page(notes, None, "pith.dev")?.is_empty());
    assert_eq!(store.find_in_page(notes, None, "docs")?.len(), 1);
    assert_eq!(store.find_in_page(notes, None, "docs")?[0].block_id, link);
    Ok(())
}

#[test]
fn linking_an_unlinked_mention_never_touches_urls_or_markdown_links() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let pith = page(&mut store, "pith")?;
    let notes = page(&mut store, "Notes")?;
    let url = block(&mut store, notes, None, "see https://pith.app/docs")?;
    let md = block(
        &mut store,
        notes,
        None,
        "read [the pith docs](https://pith.dev)",
    )?;
    let bold = block(&mut store, notes, None, "we use **pith** daily")?;

    let candidates: Vec<Id> = store
        .unlinked_references(pith, 10)?
        .into_iter()
        .map(|r| r.block_id)
        .collect();
    assert_eq!(candidates, vec![bold]);

    assert!(store.link_unlinked_reference(url, pith, &meta())?.is_none());
    assert!(store.link_unlinked_reference(md, pith, &meta())?.is_none());
    store
        .link_unlinked_reference(bold, pith, &meta())?
        .context("linked")?;

    let content = |id: Id, store: &Store| -> Result<String> {
        Ok(store.render_content(&store.get_block(id)?.context("block")?.content)?)
    };
    assert_eq!(content(url, &store)?, "see https://pith.app/docs");
    assert_eq!(
        content(md, &store)?,
        "read [the pith docs](https://pith.dev)"
    );
    assert_eq!(content(bold, &store)?, "we use **[[pith]]** daily");
    Ok(())
}

#[test]
fn previews_report_counts_and_paths_not_sentences() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let target = page(&mut store, "Target")?;
    block(&mut store, target, None, "one")?;
    let other = page(&mut store, "Other")?;
    block(&mut store, other, None, "links [[Target]]")?;
    let gone = page(&mut store, "Gone")?;
    store.apply_ops(
        &[Op::DeletePage {
            id: gone,
            expected_version: None,
        }],
        &meta(),
    )?;

    let preview = store.preview_page(target, 5)?.context("preview")?;
    assert_eq!(
        (
            preview.total_blocks,
            preview.backlink_count,
            preview.deleted
        ),
        (1, 1, false)
    );
    let deleted = store.preview_page(gone, 5)?.context("deleted preview")?;
    assert!(deleted.deleted);
    assert!(deleted.lines.is_empty());
    Ok(())
}

#[test]
fn pasted_markdown_keeps_code_indentation_blank_lines_and_fenced_bullets() -> Result<()> {
    let nodes = parse_markdown_tree(
        "- ```yaml\n  steps:\n    - run: test\n\n    - run: lint\n  ```\n- after\n  continued\n    indented",
    )?;
    assert_eq!(nodes.len(), 2);
    assert_eq!(
        nodes[0].content,
        "```yaml\nsteps:\n  - run: test\n\n  - run: lint\n```"
    );
    assert!(nodes[0].children.is_empty());
    assert_eq!(nodes[1].content, "after\ncontinued\n  indented");

    let inline = parse_markdown_tree("- ```inline``` code\n- next")?;
    assert_eq!(inline.len(), 2);
    Ok(())
}
