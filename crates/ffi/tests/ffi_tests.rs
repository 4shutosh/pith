use anyhow::Result;
use pith_ffi::{
    FfiOp, FfiSearchHit, FfiSpan, FfiTxMeta, FfiWriter, PithGraph, new_id, order_key_between,
};

fn user_meta(summary: &str) -> FfiTxMeta {
    FfiTxMeta {
        writer: FfiWriter::User,
        actor: "me".to_string(),
        session: None,
        summary: summary.to_string(),
        undo_group: None,
    }
}

#[test]
fn ffi_graph_round_trip_window_search_undo_redo_and_feed() -> Result<()> {
    let graph = PithGraph::open_in_memory()?;
    assert!(
        graph
            .journal_page(Some("2026-11-25".to_string()))?
            .is_none()
    );
    graph.start_journal(Some("2026-11-25".to_string()), user_meta("start journal"))?;
    let journal = graph
        .journal_page(Some("2026-11-25".to_string()))?
        .expect("journal created on first write");
    assert_eq!(journal.title, "2026-11-25");
    let first = graph.read_page_window(journal.id.clone(), 0, 50)?.rows[0].clone();

    let b1 = new_id();
    let b2 = new_id();
    let k1 = order_key_between(Some(first.order_key.clone()), None)?;
    let k2 = order_key_between(None, None)?;

    graph.apply_ops(
        vec![
            FfiOp::InsertBlock {
                id: b1.clone(),
                page_id: journal.id.clone(),
                parent_id: None,
                order_key: k1.clone(),
                content: "Ship [[Bridge]] #macos".to_string(),
            },
            FfiOp::InsertBlock {
                id: b2.clone(),
                page_id: journal.id.clone(),
                parent_id: Some(b1.clone()),
                order_key: k2,
                content: "Verify SwiftUI".to_string(),
            },
        ],
        user_meta("insert blocks"),
    )?;

    let window = graph.read_page_window(journal.id.clone(), 0, 50)?;
    assert_eq!(window.total_visible, 3);
    assert_eq!(window.rows[1].rendered_content, "Ship [[Bridge]] #macos");
    assert!(
        window.rows[1].spans.iter().any(
            |s| matches!(s, FfiSpan::PageLink { title, page_id: Some(_) } if title == "Bridge")
        )
    );
    assert_eq!(window.rows[2].depth, 1);

    let hits = graph.search("Bridge".to_string(), 10)?;
    assert!(
        hits.iter()
            .any(|h| matches!(h, FfiSearchHit::Page { title, .. } if title == "Bridge"))
    );

    let bridge_page = graph
        .get_page_by_title("Bridge".to_string())?
        .expect("auto-created Bridge page");
    assert_eq!(graph.backlinks(bridge_page.id)?.len(), 1);

    let feed = graph.changes_since(0, 50)?;
    assert_eq!(feed.entries.len(), 2);

    assert!(graph.undo_last("me".to_string(), false)?.is_some());
    assert_eq!(
        graph
            .read_page_window(journal.id.clone(), 0, 50)?
            .total_visible,
        1
    );

    assert!(graph.redo_last("me".to_string(), false)?.is_some());
    assert_eq!(graph.read_page_window(journal.id, 0, 50)?.total_visible, 3);
    Ok(())
}

#[test]
fn ffi_editor_commands_split_indent_and_merge() -> Result<()> {
    let graph = PithGraph::open_in_memory()?;
    let started = graph.start_journal(Some("2026-11-25".to_string()), user_meta("start"))?;
    let page = graph
        .journal_page(Some("2026-11-25".to_string()))?
        .expect("journal");

    let split = graph.split_block(
        started.focus_block_id.clone(),
        1,
        "Hello".to_string(),
        "world".to_string(),
        user_meta("split"),
    )?;
    let rows = graph.read_page_window(page.id.clone(), 0, 10)?.rows;
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1].id, split.focus_block_id);

    graph
        .indent_block(rows[1].id.clone(), rows[1].version, user_meta("indent"))?
        .expect("indent applies");
    let rows = graph.read_page_window(page.id.clone(), 0, 10)?.rows;
    assert_eq!(rows[1].depth, 1);

    let merged = graph
        .merge_into_previous(
            rows[1].id.clone(),
            rows[1].version,
            " world".to_string(),
            user_meta("merge"),
        )?
        .expect("merge applies");
    assert_eq!(merged.cursor, Some(5));
    let rows = graph.read_page_window(page.id, 0, 10)?.rows;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].rendered_content, "Hello world");
    Ok(())
}
