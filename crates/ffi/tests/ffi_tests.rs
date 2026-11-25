use anyhow::Result;
use pith_ffi::{FfiOp, FfiSearchHit, FfiTxMeta, FfiWriter, PithGraph, new_id, order_key_between};

fn user_meta(summary: &str) -> FfiTxMeta {
    FfiTxMeta {
        writer: FfiWriter::User,
        actor: "me".to_string(),
        session: None,
        summary: summary.to_string(),
    }
}

#[test]
fn ffi_graph_round_trip_window_search_undo_redo_and_feed() -> Result<()> {
    let graph = PithGraph::open_in_memory()?;
    let journal = graph.get_or_create_journal(Some("2026-11-25".to_string()), "me".to_string())?;
    assert_eq!(journal.title, "2026-11-25");

    let b1 = new_id();
    let b2 = new_id();
    let k1 = order_key_between(None, None)?;
    let k2 = order_key_between(Some(k1.clone()), None)?;

    graph.apply_ops(
        vec![
            FfiOp::InsertBlock {
                id: b1.clone(),
                page_id: journal.id.clone(),
                parent_id: None,
                order_key: k1,
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
    assert_eq!(window.total_visible, 2);
    assert_eq!(window.rows[0].rendered_content, "Ship [[Bridge]] #macos");
    assert_eq!(window.rows[1].depth, 1);

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
        0
    );

    assert!(graph.redo_last("me".to_string(), false)?.is_some());
    assert_eq!(graph.read_page_window(journal.id, 0, 50)?.total_visible, 2);
    Ok(())
}
