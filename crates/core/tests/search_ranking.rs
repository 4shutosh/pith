use anyhow::Result;
use pith_core::snippet::plain;
use pith_core::{Id, Op, Origin, SearchHit, Store, TxMeta, order};

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

fn blocks(store: &mut Store, page_id: Id, lines: &[&str]) -> Result<()> {
    let mut key: Option<String> = None;
    for line in lines {
        let next = order::between(key.as_deref(), None)?;
        store.apply_ops(
            &[Op::InsertBlock {
                id: Id::new(),
                page_id,
                parent_id: None,
                order_key: next.clone(),
                content: line.to_string(),
            }],
            &meta(),
        )?;
        key = Some(next);
    }
    Ok(())
}

fn labels(hits: &[SearchHit]) -> Vec<String> {
    hits.iter()
        .map(|hit| match hit {
            SearchHit::Page { title, score, .. } => format!("page {title} {score}"),
            SearchHit::Block { snippet, score, .. } => format!("block {} {score}", plain(snippet)),
        })
        .collect()
}

fn library() -> Result<Store> {
    let mut store = Store::open_in_memory()?;
    page(&mut store, "Habit stacking")?;
    page(&mut store, "Atomic Habits")?;
    page(&mut store, "Inhabitants")?;
    let notes = page(&mut store, "Notes")?;
    blocks(
        &mut store,
        notes,
        &[
            "Habits are the compound interest",
            "Reading about habit loops",
            "inhabit the space",
            "see [[Atomic Habits]]",
            "also [[Atomic Habits]]",
            "nothing relevant",
        ],
    )?;
    Ok(store)
}

#[test]
fn results_are_one_list_ranked_by_how_well_and_where_the_query_matches() -> Result<()> {
    let store = library()?;
    assert_eq!(
        labels(&store.search("habit", 20)?),
        vec![
            "page Habit stacking 101",
            "block Habits are the compound interest 86",
            "page Atomic Habits 83",
            "block see Atomic Habits 66",
            "block also Atomic Habits 66",
            "block Reading about habit loops 66",
            "page Inhabitants 41",
            "block inhabit the space 26",
        ]
    );
    Ok(())
}

#[test]
fn an_exact_title_comes_first_and_the_limit_keeps_the_best() -> Result<()> {
    let store = library()?;
    assert_eq!(
        labels(&store.search("atomic habits", 3)?),
        vec![
            "page Atomic Habits 123",
            "block see Atomic Habits 66",
            "block also Atomic Habits 66",
        ]
    );
    Ok(())
}

#[test]
fn page_hits_carry_journal_day_and_backlink_count() -> Result<()> {
    let mut store = library()?;
    store.start_journal(Some("2026-11-25"), &meta())?;
    let hits = store.search("2026-11-25", 5)?;
    match &hits[0] {
        SearchHit::Page {
            title,
            journal_day,
            backlink_count,
            ..
        } => {
            assert_eq!(title, "2026-11-25");
            assert_eq!(*journal_day, Some(20261125));
            assert_eq!(*backlink_count, 0);
        }
        other => panic!("expected the journal page first, got {other:?}"),
    }
    let atomic = store.search("atomic habits", 1)?;
    assert!(matches!(
        &atomic[0],
        SearchHit::Page {
            backlink_count: 2,
            journal_day: None,
            ..
        }
    ));
    Ok(())
}

#[test]
fn short_queries_match_page_title_prefixes_only() -> Result<()> {
    let store = library()?;
    assert_eq!(
        labels(&store.search("ha", 10)?),
        vec!["page Habit stacking 101"]
    );
    Ok(())
}

#[test]
fn words_spread_over_lines_of_one_block_still_find_it_once() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let notes = page(&mut store, "Notes")?;
    blocks(
        &mut store,
        notes,
        &["compound interest\nfeedback loops", "only compound here"],
    )?;
    assert_eq!(
        labels(&store.search("compound loops", 10)?),
        vec!["block compound interest 56"]
    );
    Ok(())
}
