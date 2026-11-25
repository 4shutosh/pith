use anyhow::{Context, Result};
use pith_core::order;
use pith_core::parser::{
    RefKind, RefTarget, parse_content, remove_property_in_content, set_property_in_content,
    set_task_state_in_content,
};
use pith_core::snippet::Segment;
use pith_core::{Id, Op, Origin, SearchHit, Store, TxMeta};
use proptest::prelude::*;

fn segs(parts: &[(&str, bool)]) -> Vec<Segment> {
    parts
        .iter()
        .map(|(text, highlighted)| Segment {
            text: text.to_string(),
            highlighted: *highlighted,
        })
        .collect()
}

fn user_meta(summary: &str) -> TxMeta {
    TxMeta::new(Origin::User, "me", summary)
}

#[test]
fn parser_extracts_links_tags_block_refs_props_and_tasks() {
    let target_block = Id::new();
    let text = format!(
        "TODO Ship [[Roadmap]] #v1 #[[Core Engine]] (({target_block}))\nstatus:: active\nowner:: [[Alice]]"
    );
    let parsed = parse_content(&text);

    assert_eq!(parsed.task_state.as_deref(), Some("TODO"));
    assert_eq!(parsed.props.len(), 2);
    assert_eq!(parsed.props[0].key, "status");
    assert_eq!(parsed.props[0].value, "active");
    assert!(parsed.props[0].value_ref.is_none());
    assert_eq!(parsed.props[1].key, "owner");
    assert_eq!(
        parsed.props[1].value_ref,
        Some(RefTarget::Title("Alice".to_string()))
    );

    assert!(parsed.refs.iter().any(|r| {
        r.kind == RefKind::Page && r.target == RefTarget::Title("Roadmap".to_string())
    }));
    assert!(
        parsed
            .refs
            .iter()
            .any(|r| r.kind == RefKind::Tag && r.target == RefTarget::Title("v1".to_string()))
    );
    assert!(parsed.refs.iter().any(|r| {
        r.kind == RefKind::Tag && r.target == RefTarget::Title("Core Engine".to_string())
    }));
    assert!(
        parsed
            .refs
            .iter()
            .any(|r| r.kind == RefKind::Block && r.target == RefTarget::Id(target_block))
    );
    assert!(
        parsed
            .refs
            .iter()
            .any(|r| r.kind == RefKind::Prop && r.target == RefTarget::Title("Alice".to_string()))
    );
}

#[test]
fn code_spans_and_fences_are_excluded_from_parsing_and_preserved() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    let content = "Use `[[NotAPage]] #notag` and:\n```c\n#include <stdio.h>\nkey:: ignored\n[[AlsoIgnored]]\n```\nReal [[RealPage]] #realtag";

    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Code".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: content.to_string(),
            },
        ],
        &user_meta("insert code block"),
    )?;
    store.check_invariants()?;

    assert!(store.get_page_by_title("NotAPage")?.is_none());
    assert!(store.get_page_by_title("notag")?.is_none());
    assert!(store.get_page_by_title("include")?.is_none());
    assert!(store.get_page_by_title("AlsoIgnored")?.is_none());
    assert!(store.find_props("key", None)?.is_empty());

    let real_page = store
        .get_page_by_title("RealPage")?
        .context("RealPage created")?;
    let real_tag = store
        .get_page_by_title("realtag")?
        .context("realtag created")?;
    assert_eq!(store.backlinks(real_page.id)?.len(), 1);
    assert_eq!(store.backlinks(real_tag.id)?.len(), 1);

    let block = store.get_block(block_id)?.context("block")?;
    assert_eq!(store.render_content(&block.content)?, content);
    Ok(())
}

#[test]
fn fence_with_info_string_inside_does_not_drop_trailing_backlink() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let block_id = Id::new();
    let content = "```\nx\n```foo\n[[G]]\n```\n[[H]]";

    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Fences".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: content.to_string(),
            },
        ],
        &user_meta("nested fence info"),
    )?;
    store.check_invariants()?;

    assert!(store.get_page_by_title("G")?.is_none());
    let h = store.get_page_by_title("H")?.context("H created")?;
    assert_eq!(store.backlinks(h.id)?.len(), 1);
    Ok(())
}

#[test]
fn content_helpers_update_properties_and_task_state() {
    let base = "Ship pith\npriority:: low";
    let updated = set_property_in_content(base, "priority", "high");
    assert_eq!(updated, "Ship pith\npriority:: high");

    let added = set_property_in_content(&updated, "area", "core");
    assert_eq!(added, "Ship pith\npriority:: high\narea:: core");

    let removed = remove_property_in_content(&added, "priority");
    assert_eq!(removed, "Ship pith\narea:: core");

    let todo = set_task_state_in_content(&removed, Some("TODO"));
    assert_eq!(todo, "TODO Ship pith\narea:: core");

    let done = set_task_state_in_content(&todo, Some("DONE"));
    assert_eq!(done, "DONE Ship pith\narea:: core");

    let cleared = set_task_state_in_content(&done, None);
    assert_eq!(cleared, "Ship pith\narea:: core");
}

#[test]
fn links_auto_create_pages_store_uuids_and_undo_cleanly() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let home = Id::new();
    let block_id = Id::new();

    store.apply_ops(
        &[Op::CreatePage {
            id: home,
            title: "Home".to_string(),
            journal_day: None,
            document_mode: false,
        }],
        &user_meta("create home"),
    )?;

    let before = store.live_snapshot()?;
    let res = store.apply_ops(
        &[Op::InsertBlock {
            id: block_id,
            page_id: home,
            parent_id: None,
            order_key: order::between(None, None)?,
            content: "Read [[Atomic Habits]] #books #[[Reading List]]".to_string(),
        }],
        &user_meta("insert with refs"),
    )?;
    store.check_invariants()?;

    let atomic = store
        .get_page_by_title("Atomic Habits")?
        .context("auto-created Atomic Habits")?;
    let books = store
        .get_page_by_title("books")?
        .context("auto-created books")?;
    let reading_list = store
        .get_page_by_title("Reading List")?
        .context("auto-created Reading List")?;

    let block = store.get_block(block_id)?.context("block exists")?;
    assert!(block.content.contains(&format!("[[{}]]", atomic.id)));
    assert!(block.content.contains(&format!("#[[{}]]", books.id)));
    assert!(block.content.contains(&format!("#[[{}]]", reading_list.id)));

    let rendered = store.render_content(&block.content)?;
    assert_eq!(rendered, "Read [[Atomic Habits]] #books #[[Reading List]]");

    assert_eq!(store.backlinks(atomic.id)?.len(), 1);
    assert_eq!(store.backlinks(books.id)?.len(), 1);
    assert_eq!(store.backlinks(reading_list.id)?.len(), 1);

    let txn_id = res.txn_id.context("txn_id")?;
    store.undo(txn_id, &user_meta("undo insert"), false)?;
    store.check_invariants()?;
    assert_eq!(before, store.live_snapshot()?);
    assert!(store.get_page_by_title("Atomic Habits")?.is_none());
    assert!(store.backlinks(atomic.id)?.is_empty());
    Ok(())
}

#[test]
fn rename_page_updates_rendered_links_and_fts_search() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let home = Id::new();
    let block_id = Id::new();
    let on_target_block = Id::new();

    store.apply_ops(
        &[
            Op::CreatePage {
                id: home,
                title: "Journal".to_string(),
                journal_day: Some(20261125),
                document_mode: false,
            },
            Op::InsertBlock {
                id: block_id,
                page_id: home,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Discuss [[OldName]] timeline".to_string(),
            },
        ],
        &user_meta("seed"),
    )?;

    let target = store
        .get_page_by_title("OldName")?
        .context("auto-created OldName")?;

    store.apply_ops(
        &[Op::InsertBlock {
            id: on_target_block,
            page_id: target.id,
            parent_id: None,
            order_key: order::between(None, None)?,
            content: "Inside target page".to_string(),
        }],
        &user_meta("add child on target"),
    )?;

    assert_eq!(store.search("OldName", 10)?.len(), 2);
    assert!(store.search("NewName", 10)?.is_empty());

    store.apply_ops(
        &[Op::RenamePage {
            id: target.id,
            title: "NewName".to_string(),
            expected_version: Some(1),
        }],
        &user_meta("rename"),
    )?;
    store.check_invariants()?;

    assert!(store.search("OldName", 10)?.is_empty());
    let hits = store.search("NewName", 10)?;
    assert_eq!(hits.len(), 2);
    let block = store.get_block(block_id)?.context("block")?;
    assert_eq!(
        store.render_content(&block.content)?,
        "Discuss [[NewName]] timeline"
    );
    Ok(())
}

#[test]
fn backlinks_deduplicate_per_block_and_tombstone_lifecycle() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page_id = Id::new();
    let b1 = Id::new();
    let b2 = Id::new();

    store.apply_ops(
        &[
            Op::CreatePage {
                id: page_id,
                title: "Work".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: b1,
                page_id,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "TODO Build [[Parser]] #Parser\npriority:: high".to_string(),
            },
            Op::InsertBlock {
                id: b2,
                page_id,
                parent_id: None,
                order_key: order::between(Some("V"), None)?,
                content: format!("Depends on (({b1}))"),
            },
        ],
        &user_meta("seed"),
    )?;
    store.check_invariants()?;

    let parser_page = store.get_page_by_title("Parser")?.context("Parser")?;
    assert_eq!(store.backlinks(parser_page.id)?.len(), 1);
    assert_eq!(store.list_tasks(Some("TODO"))?.len(), 1);
    assert_eq!(store.find_props("priority", Some("high"))?.len(), 1);
    assert_eq!(store.backlinks(b1)?.len(), 1);
    assert_eq!(store.search("Build", 10)?.len(), 1);

    let del = store
        .apply_ops(
            &[Op::DeleteBlock {
                id: b1,
                expected_version: Some(1),
            }],
            &user_meta("delete b1"),
        )?
        .txn_id
        .context("del txn")?;
    store.check_invariants()?;

    assert!(store.list_tasks(Some("TODO"))?.is_empty());
    assert!(store.find_props("priority", Some("high"))?.is_empty());
    assert!(store.search("Build", 10)?.is_empty());

    store.undo(del, &user_meta("restore b1"), false)?;
    store.check_invariants()?;

    assert_eq!(store.list_tasks(Some("TODO"))?.len(), 1);
    assert_eq!(store.find_props("priority", Some("high"))?.len(), 1);
    assert_eq!(store.search("Build", 10)?.len(), 1);
    Ok(())
}

#[test]
fn search_excludes_uuids_handles_short_queries_and_survives_vacuum() -> Result<()> {
    let path = std::env::temp_dir().join(format!("pith-search-{}.db", Id::new()));
    let result = (|| -> Result<()> {
        let mut store = Store::open(&path)?;
        let page_id = Id::new();
        let b1 = Id::new();
        let b2 = Id::new();

        store.apply_ops(
            &[
                Op::CreatePage {
                    id: page_id,
                    title: "Engineering".to_string(),
                    journal_day: None,
                    document_mode: false,
                },
                Op::InsertBlock {
                    id: b1,
                    page_id,
                    parent_id: None,
                    order_key: order::between(None, None)?,
                    content: "Roadmap for C++ and foo-bar with [[Target]]".to_string(),
                },
                Op::InsertBlock {
                    id: b2,
                    page_id,
                    parent_id: None,
                    order_key: order::between(Some("V"), None)?,
                    content: format!("Ref only (({b1}))"),
                },
            ],
            &user_meta("seed"),
        )?;

        let target_page = store.get_page_by_title("Target")?.context("Target")?;
        let target_uuid_hex = target_page.id.to_string();
        let b1_uuid_hex = b1.to_string();

        assert_eq!(store.search("map", 10)?.len(), 1);
        assert_eq!(
            store.search("en", 10)?,
            vec![SearchHit::Page {
                page_id,
                title: "Engineering".to_string(),
                highlighted_title: segs(&[("En", true), ("gineering", false)]),
            }]
        );
        assert!(store.search("zz", 10)?.is_empty());
        assert_eq!(store.search("foo-bar", 10)?.len(), 1);
        assert!(store.search("", 10)?.is_empty());
        assert!(store.search("   ", 10)?.is_empty());

        assert!(store.search(&target_uuid_hex[..8], 10)?.is_empty());
        assert!(store.search(&b1_uuid_hex[..8], 10)?.is_empty());
        assert!(store.search(&target_uuid_hex[..2], 10)?.is_empty());

        store.rebuild_derived()?;
        store.check_invariants()?;

        drop(store);
        {
            let raw = rusqlite::Connection::open(&path)?;
            raw.execute_batch("VACUUM;")?;
        }

        let reopened = Store::open(&path)?;
        reopened.check_invariants()?;
        let hits = reopened.search("Roadmap", 10)?;
        assert_eq!(hits.len(), 1);
        assert!(matches!(hits[0], SearchHit::Block { block_id, .. } if block_id == b1));
        Ok(())
    })();

    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    result
}

#[test]
fn short_query_returns_pages_including_empty_ones_without_block_crowding() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let design = Id::new();
    let devlog = Id::new();

    let mut ops = vec![
        Op::CreatePage {
            id: design,
            title: "Design".to_string(),
            journal_day: None,
            document_mode: false,
        },
        Op::CreatePage {
            id: devlog,
            title: "Devlog".to_string(),
            journal_day: None,
            document_mode: false,
        },
    ];

    let mut prev: Option<String> = None;
    for i in 0..30 {
        let key = order::between(prev.as_deref(), None)?;
        ops.push(Op::InsertBlock {
            id: Id::new(),
            page_id: devlog,
            parent_id: None,
            order_key: key.clone(),
            content: format!("Entry {i}"),
        });
        prev = Some(key);
    }

    store.apply_ops(&ops, &user_meta("seed"))?;
    let hits = store.search("de", 20)?;
    assert_eq!(
        hits,
        vec![
            SearchHit::Page {
                page_id: design,
                title: "Design".to_string(),
                highlighted_title: segs(&[("De", true), ("sign", false)]),
            },
            SearchHit::Page {
                page_id: devlog,
                title: "Devlog".to_string(),
                highlighted_title: segs(&[("De", true), ("vlog", false)]),
            },
        ]
    );
    Ok(())
}

#[test]
fn title_matches_are_page_hits_at_every_query_length() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let design = Id::new();
    let devlog = Id::new();
    let notes = Id::new();
    let mentioning_block = Id::new();

    let mut ops = vec![
        Op::CreatePage {
            id: design,
            title: "Design".to_string(),
            journal_day: None,
            document_mode: false,
        },
        Op::CreatePage {
            id: devlog,
            title: "Devlog".to_string(),
            journal_day: None,
            document_mode: false,
        },
        Op::CreatePage {
            id: notes,
            title: "Notes".to_string(),
            journal_day: None,
            document_mode: false,
        },
        Op::InsertBlock {
            id: mentioning_block,
            page_id: notes,
            parent_id: None,
            order_key: order::between(None, None)?,
            content: "Started the devlog today".to_string(),
        },
    ];
    let mut prev: Option<String> = None;
    for i in 0..30 {
        let key = order::between(prev.as_deref(), None)?;
        ops.push(Op::InsertBlock {
            id: Id::new(),
            page_id: devlog,
            parent_id: None,
            order_key: key.clone(),
            content: format!("Entry {i}"),
        });
        prev = Some(key);
    }
    store.apply_ops(&ops, &user_meta("seed"))?;
    store.check_invariants()?;

    assert_eq!(
        store.search("des", 20)?,
        vec![SearchHit::Page {
            page_id: design,
            title: "Design".to_string(),
            highlighted_title: segs(&[("Des", true), ("ign", false)]),
        }]
    );

    let devlog_hits = store.search("devlog", 20)?;
    assert_eq!(devlog_hits.len(), 2);
    assert_eq!(
        devlog_hits[0],
        SearchHit::Page {
            page_id: devlog,
            title: "Devlog".to_string(),
            highlighted_title: segs(&[("Devlog", true)]),
        }
    );
    assert!(matches!(
        devlog_hits[1],
        SearchHit::Block { block_id, .. } if block_id == mentioning_block
    ));

    store.apply_ops(
        &[Op::RenamePage {
            id: design,
            title: "Blueprint".to_string(),
            expected_version: None,
        }],
        &user_meta("rename"),
    )?;
    store.check_invariants()?;
    assert!(store.search("des", 20)?.is_empty());
    assert_eq!(store.search("blue", 20)?.len(), 1);

    let delete = store
        .apply_ops(
            &[Op::DeletePage {
                id: design,
                expected_version: None,
            }],
            &user_meta("delete"),
        )?
        .txn_id
        .context("delete txn")?;
    store.check_invariants()?;
    assert!(store.search("blue", 20)?.is_empty());

    store.undo(delete, &user_meta("undo delete"), false)?;
    store.check_invariants()?;
    assert_eq!(store.search("blue", 20)?.len(), 1);
    Ok(())
}

fn syntax_line_strategy() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("```".to_string()),
        Just("```rust".to_string()),
        Just("````".to_string()),
        Just("plain text".to_string()),
        Just("`[[InlineCode]] #inline`".to_string()),
        (0u8..6).prop_map(|n| format!("See [[Page{n}]]")),
        (0u8..6).prop_map(|n| format!("Tagged #tag{n}")),
        (0u8..6).prop_map(|n| format!("Multi #[[Topic {n}]]")),
        (0u8..6).prop_map(|n| format!("owner:: [[Page{n}]]")),
        (0u8..6).prop_map(|n| format!("TODO item [[Page{n}]] and `[[Code{n}]]` #tag{n}")),
        (0u8..6).prop_map(|n| format!("key:: `[[Code{n}]]` [[Page{n}]]")),
    ]
}

proptest! {
    #[test]
    fn every_rewritten_page_uuid_in_stored_content_has_a_backlink(
        lines in prop::collection::vec(syntax_line_strategy(), 1..12)
    ) {
        let mut store = Store::open_in_memory().expect("open");
        let root_page = Id::new();
        let block_id = Id::new();
        let content = lines.join("\n");

        store
            .apply_ops(
                &[
                    Op::CreatePage {
                        id: root_page,
                        title: "Host".to_string(),
                        journal_day: None,
                        document_mode: false,
                    },
                    Op::InsertBlock {
                        id: block_id,
                        page_id: root_page,
                        parent_id: None,
                        order_key: order::between(None, None).expect("key"),
                        content,
                    },
                ],
                &user_meta("prop"),
            )
            .expect("apply");

        store.check_invariants().expect("invariants");
        let stored = store.get_block(block_id).expect("get").expect("exists");
        for page in store.list_live_pages().expect("pages") {
            let uuid_in_content = stored.content.contains(&page.id.to_string());
            let has_backlink = store
                .backlinks(page.id)
                .expect("backlinks")
                .iter()
                .any(|bl| bl.block_id == block_id);
            prop_assert_eq!(
                uuid_in_content,
                has_backlink,
                "rewriter vs refs mismatch for page {} in content:\n{}",
                page.title,
                stored.content
            );
        }
    }

    #[test]
    fn canonicalize_then_render_round_trips_rich_content(
        word in "[a-zA-Z]{2,8}",
        page_a in "[A-Z][a-z]{2,8}",
        tag_simple in "[a-z]{2,8}",
        tag_multi_a in "[A-Z][a-z]{2,6}",
        tag_multi_b in "[A-Z][a-z]{2,6}",
        code_inner in "[a-z]{2,8}",
    ) {
        let mut store = Store::open_in_memory().expect("open");
        let root_page = Id::new();
        let block_id = Id::new();
        let input = format!(
            "TODO {word} [[{page_a}]] #{tag_simple} #[[{tag_multi_a} {tag_multi_b}]] `[[{code_inner}]]`"
        );

        store
            .apply_ops(
                &[
                    Op::CreatePage {
                        id: root_page,
                        title: "Root".to_string(),
                        journal_day: None,
                        document_mode: false,
                    },
                    Op::InsertBlock {
                        id: block_id,
                        page_id: root_page,
                        parent_id: None,
                        order_key: order::between(None, None).expect("key"),
                        content: input.clone(),
                    },
                ],
                &user_meta("roundtrip"),
            )
            .expect("apply");

        store.check_invariants().expect("invariants");
        let stored = store.get_block(block_id).expect("get").expect("exists");
        let rendered = store.render_content(&stored.content).expect("render");
        prop_assert_eq!(rendered, input);
    }
}
