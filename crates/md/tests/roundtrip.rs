use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Result;
use pith_core::{Id, Store};
use pith_md::{
    Error, ImportOptions, export_markdown, export_markdown_with_progress, import_logseq_db,
    import_logseq_db_with_progress,
};
use rusqlite::Connection;
use serde_json::{Value, json};
use uuid::Uuid;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("pith-md-test-{name}-{}", Id::new()));
    fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

fn kw(s: &str) -> Value {
    Value::String(format!("~:{s}"))
}

fn u(s: &str) -> Value {
    Value::String(format!("~u{s}"))
}

fn s(val: &str) -> Value {
    if val.starts_with('~') || val.starts_with('^') || val.starts_with('`') {
        Value::String(format!("~{val}"))
    } else {
        Value::String(val.to_string())
    }
}

fn datom(e: i64, a: &str, v: Value, tx: i64) -> Value {
    json!([e, kw(a), v, tx])
}

fn write_logseq_sqlite(path: &Path, leaf_batches: &[Vec<Value>], tail: Option<Vec<Vec<Value>>>) {
    let conn = Connection::open(path).expect("open fixture sqlite");
    conn.execute(
        "CREATE TABLE kvs (addr INTEGER primary key, content TEXT, addresses JSON)",
        [],
    )
    .expect("create kvs");

    let mut leaf_addrs = Vec::new();
    let mut next_addr = 100i64;
    for batch in leaf_batches {
        let leaf = json!(["^ ", "~:keys", batch]);
        conn.execute(
            "INSERT INTO kvs (addr, content, addresses) VALUES (?1, ?2, NULL)",
            rusqlite::params![next_addr, leaf.to_string()],
        )
        .expect("insert leaf");
        leaf_addrs.push(next_addr);
        next_addr += 1;
    }

    let root_addr = next_addr;
    let branch_content = json!(["^ ", "~:keys", []]);
    let addrs_json = serde_json::to_string(&leaf_addrs).expect("serialize addrs");
    conn.execute(
        "INSERT INTO kvs (addr, content, addresses) VALUES (?1, ?2, ?3)",
        rusqlite::params![root_addr, branch_content.to_string(), addrs_json],
    )
    .expect("insert branch");

    let meta = json!([
        "^ ",
        "~:eavt",
        root_addr,
        "~:max-tx",
        536870913,
        "~:max-eid",
        5000
    ]);
    conn.execute(
        "INSERT INTO kvs (addr, content, addresses) VALUES (0, ?1, NULL)",
        rusqlite::params![meta.to_string()],
    )
    .expect("insert meta");

    if let Some(tail_batches) = tail {
        let tail_json = serde_json::to_string(&tail_batches).expect("serialize tail");
        conn.execute(
            "INSERT INTO kvs (addr, content, addresses) VALUES (1, ?1, NULL)",
            rusqlite::params![tail_json],
        )
        .expect("insert tail");
    }
}

const UUID_PAGE_NOTES: &str = "11111111-1111-4111-8111-111111111101";
const UUID_PAGE_DUP: &str = "11111111-1111-4111-8111-111111111102";
const UUID_PAGE_CJK: &str = "11111111-1111-4111-8111-111111111103";
const UUID_PAGE_JOURNAL: &str = "11111111-1111-4111-8111-111111111104";
const UUID_TAG_PROJECT: &str = "11111111-1111-4111-8111-111111111105";
const UUID_PAGE_RECYCLE: &str = "11111111-1111-4111-8111-111111111106";
const UUID_PAGE_VIEWS: &str = "11111111-1111-4111-8111-111111111107";
const UUID_PAGE_FAVS: &str = "11111111-1111-4111-8111-111111111108";

const UUID_BLK_HEADING: &str = "22222222-2222-4222-8222-222222222201";
const UUID_BLK_CHILD: &str = "22222222-2222-4222-8222-222222222202";
const UUID_BLK_GRANDCHILD: &str = "22222222-2222-4222-8222-222222222203";
const UUID_BLK_CODE: &str = "22222222-2222-4222-8222-222222222204";
const UUID_BLK_QUOTE: &str = "22222222-2222-4222-8222-222222222205";
const UUID_BLK_TASK_DONE: &str = "22222222-2222-4222-8222-222222222206";
const UUID_BLK_TASK_BACKLOG: &str = "22222222-2222-4222-8222-222222222207";
const UUID_BLK_JOURNAL_REF: &str = "22222222-2222-4222-8222-222222222208";
const UUID_BLK_CJK_PROP: &str = "22222222-2222-4222-8222-222222222209";
const UUID_BLK_DUP_PAGE: &str = "22222222-2222-4222-8222-222222222210";
const UUID_BLK_RECYCLED: &str = "22222222-2222-4222-8222-222222222211";
const UUID_BLK_DELETED: &str = "22222222-2222-4222-8222-222222222212";
const UUID_BLK_VIEW: &str = "22222222-2222-4222-8222-222222222213";
const UUID_BLK_ASSET: &str = "22222222-2222-4222-8222-222222222214";
const UUID_BLK_FAV_LINK: &str = "22222222-2222-4222-8222-222222222215";
const UUID_BLK_MISSING_REF: &str = "99999999-9999-4999-8999-999999999999";

fn build_synthetic_fixture(path: &Path, schema_major: i64) {
    let tx = 536870913;
    let mut leaf1 = Vec::new();
    let mut leaf2 = Vec::new();

    leaf1.extend([
        datom(6, "db/ident", kw("logseq.kv/schema-version"), tx),
        datom(
            6,
            "kv/value",
            json!(["^ ", "~:major", schema_major, "~:minor", 36]),
            tx,
        ),
        datom(2, "db/ident", kw("logseq.class/Tag"), tx),
        datom(2, "logseq.property/built-in?", json!(true), tx),
        datom(3, "db/ident", kw("logseq.class/Property"), tx),
        datom(3, "logseq.property/built-in?", json!(true), tx),
        datom(153, "db/ident", kw("logseq.class/Page"), tx),
        datom(153, "logseq.property/built-in?", json!(true), tx),
        datom(154, "db/ident", kw("logseq.class/Journal"), tx),
        datom(154, "logseq.property/built-in?", json!(true), tx),
        datom(155, "db/ident", kw("logseq.class/Whiteboard"), tx),
        datom(155, "logseq.property/built-in?", json!(true), tx),
        datom(156, "db/ident", kw("logseq.class/Task"), tx),
        datom(156, "logseq.property/built-in?", json!(true), tx),
        datom(160, "db/ident", kw("logseq.class/Asset"), tx),
        datom(160, "logseq.property/built-in?", json!(true), tx),
        datom(161, "db/ident", kw("logseq.class/Code-block"), tx),
        datom(161, "logseq.property/built-in?", json!(true), tx),
        datom(162, "db/ident", kw("logseq.class/Quote-block"), tx),
        datom(162, "logseq.property/built-in?", json!(true), tx),
        datom(78, "db/ident", kw("logseq.property/status.backlog"), tx),
        datom(78, "block/title", s("Backlog"), tx),
        datom(78, "logseq.property/built-in?", json!(true), tx),
        datom(82, "db/ident", kw("logseq.property/status.done"), tx),
        datom(82, "block/title", s("Done"), tx),
        datom(82, "logseq.property/built-in?", json!(true), tx),
        datom(87, "db/ident", kw("logseq.property/priority.high"), tx),
        datom(87, "block/title", s("High"), tx),
        datom(87, "logseq.property/built-in?", json!(true), tx),
        datom(90, "db/ident", kw("user.property/owner"), tx),
        datom(90, "block/title", s("Owner"), tx),
        datom(90, "db/valueType", kw("db.type/ref"), tx),
        datom(90, "block/tags", json!(3), tx),
        datom(91, "db/ident", kw("user.property/estimate"), tx),
        datom(91, "block/title", s("Estimate"), tx),
        datom(91, "block/tags", json!(3), tx),
        datom(173, "block/uuid", u(UUID_PAGE_VIEWS), tx),
        datom(173, "block/title", s("$$$views"), tx),
        datom(173, "block/tags", json!(153), tx),
        datom(173, "logseq.property/built-in?", json!(true), tx),
        datom(173, "logseq.property/hide?", json!(true), tx),
        datom(174, "block/uuid", u(UUID_PAGE_FAVS), tx),
        datom(174, "block/title", s("$$$favorites"), tx),
        datom(174, "block/tags", json!(153), tx),
        datom(174, "logseq.property/built-in?", json!(true), tx),
        datom(174, "logseq.property/hide?", json!(true), tx),
        datom(6092, "block/uuid", u(UUID_PAGE_RECYCLE), tx),
        datom(6092, "block/title", s("Recycle"), tx),
        datom(6092, "block/tags", json!(153), tx),
        datom(6092, "logseq.property/built-in?", json!(true), tx),
        datom(6092, "logseq.property/hide?", json!(true), tx),
    ]);

    leaf1.extend([
        datom(200, "block/uuid", u(UUID_PAGE_NOTES), tx),
        datom(200, "block/title", s("Notes"), tx),
        datom(200, "block/tags", json!(153), tx),
        datom(201, "block/uuid", u(UUID_PAGE_DUP), tx),
        datom(201, "block/title", s("notes"), tx),
        datom(201, "block/tags", json!(153), tx),
        datom(202, "block/uuid", u(UUID_PAGE_CJK), tx),
        datom(202, "block/title", s("日本語/ノート 🚀"), tx),
        datom(202, "block/tags", json!(153), tx),
        datom(203, "block/uuid", u(UUID_PAGE_JOURNAL), tx),
        datom(203, "block/title", s("Feb 14th, 2026"), tx),
        datom(203, "block/journal-day", json!(20260214), tx),
        datom(203, "block/tags", json!(154), tx),
        datom(204, "block/uuid", u(UUID_TAG_PROJECT), tx),
        datom(204, "block/title", s("Project"), tx),
        datom(204, "db/ident", kw("user.class/Project-abc"), tx),
        datom(204, "block/tags", json!(2), tx),
        datom(300, "block/uuid", u(UUID_BLK_FAV_LINK), tx),
        datom(300, "block/page", json!(174), tx),
        datom(300, "block/parent", json!(174), tx),
        datom(300, "block/link", json!(200), tx),
        datom(300, "block/order", s("a0"), tx),
    ]);

    leaf2.extend([
        datom(1001, "block/uuid", u(UUID_BLK_HEADING), tx),
        datom(1001, "block/page", json!(200), tx),
        datom(1001, "block/parent", json!(200), tx),
        datom(1001, "block/order", s("a0"), tx),
        datom(1001, "block/title", s("Overview"), tx),
        datom(1001, "logseq.property/heading", json!(2), tx),
        datom(1001, "block/collapsed?", json!(true), tx),
        datom(1002, "block/uuid", u(UUID_BLK_CHILD), tx),
        datom(1002, "block/page", json!(200), tx),
        datom(1002, "block/parent", json!(1001), tx),
        datom(1002, "block/order", s("a1"), tx),
        datom(
            1002,
            "block/title",
            s(&format!(
                "See [[{UUID_PAGE_CJK}]] and missing [[{UUID_BLK_MISSING_REF}]]"
            )),
            tx,
        ),
        datom(1002, "block/tags", json!(204), tx),
        datom(1003, "block/uuid", u(UUID_BLK_GRANDCHILD), tx),
        datom(1003, "block/page", json!(200), tx),
        datom(1003, "block/parent", json!(1002), tx),
        datom(1003, "block/order", s("a0"), tx),
        datom(
            1003,
            "block/title",
            s("Deep leaf line 1\nDeep leaf line 2"),
            tx,
        ),
        datom(1004, "block/uuid", u(UUID_BLK_CODE), tx),
        datom(1004, "block/page", json!(200), tx),
        datom(1004, "block/parent", json!(200), tx),
        datom(1004, "block/order", s("a1"), tx),
        datom(
            1004,
            "block/title",
            s("fn main() {\n    println!(\"hi\");\n}"),
            tx,
        ),
        datom(1004, "block/tags", json!(161), tx),
        datom(1004, "logseq.property.code/lang", s("rust"), tx),
        datom(1005, "block/uuid", u(UUID_BLK_QUOTE), tx),
        datom(1005, "block/page", json!(200), tx),
        datom(1005, "block/parent", json!(200), tx),
        datom(1005, "block/order", s("a2"), tx),
        datom(1005, "block/title", s("Stay curious"), tx),
        datom(1005, "block/tags", json!(162), tx),
        datom(1006, "block/uuid", u(UUID_BLK_TASK_DONE), tx),
        datom(1006, "block/page", json!(200), tx),
        datom(1006, "block/parent", json!(200), tx),
        datom(1006, "block/order", s("a3"), tx),
        datom(1006, "block/title", s("Ship importer"), tx),
        datom(1006, "block/tags", json!(156), tx),
        datom(1006, "logseq.property/status", json!(82), tx),
        datom(1007, "block/uuid", u(UUID_BLK_TASK_BACKLOG), tx),
        datom(1007, "block/page", json!(200), tx),
        datom(1007, "block/parent", json!(200), tx),
        datom(1007, "block/order", s("a4"), tx),
        datom(1007, "block/title", s("Polish docs"), tx),
        datom(1007, "block/tags", json!(156), tx),
        datom(1007, "logseq.property/status", json!(78), tx),
        datom(1007, "logseq.property/priority", json!(87), tx),
        datom(1008, "block/uuid", u(UUID_BLK_JOURNAL_REF), tx),
        datom(1008, "block/page", json!(203), tx),
        datom(1008, "block/parent", json!(203), tx),
        datom(1008, "block/order", s("a0"), tx),
        datom(
            1008,
            "block/title",
            s(&format!("Referenced block (({UUID_BLK_CHILD}))")),
            tx,
        ),
        datom(1009, "block/uuid", u(UUID_BLK_CJK_PROP), tx),
        datom(1009, "block/page", json!(202), tx),
        datom(1009, "block/parent", json!(202), tx),
        datom(1009, "block/order", s("a0"), tx),
        datom(1009, "block/title", s("漢字メモ"), tx),
        datom(1009, "user.property/owner", json!(200), tx),
        datom(1009, "user.property/estimate", json!(3), tx),
        datom(1010, "block/uuid", u(UUID_BLK_DUP_PAGE), tx),
        datom(1010, "block/page", json!(201), tx),
        datom(1010, "block/parent", json!(201), tx),
        datom(1010, "block/order", s("a0"), tx),
        datom(1010, "block/title", s("Duplicate page body"), tx),
        datom(1011, "block/uuid", u(UUID_BLK_RECYCLED), tx),
        datom(1011, "block/page", json!(6092), tx),
        datom(1011, "block/parent", json!(6092), tx),
        datom(1011, "block/order", s("a0"), tx),
        datom(1011, "block/title", s("Must never be imported"), tx),
        datom(1012, "block/uuid", u(UUID_BLK_DELETED), tx),
        datom(1012, "block/page", json!(200), tx),
        datom(1012, "block/parent", json!(200), tx),
        datom(1012, "block/order", s("a9"), tx),
        datom(1012, "block/title", s("Soft deleted block"), tx),
        datom(1012, "block/deleted?", json!(true), tx),
        datom(1013, "block/uuid", u(UUID_BLK_VIEW), tx),
        datom(1013, "block/page", json!(173), tx),
        datom(1013, "block/parent", json!(173), tx),
        datom(1013, "block/order", s("a0"), tx),
        datom(1013, "logseq.property/view-for", json!(200), tx),
        datom(1014, "block/uuid", u(UUID_BLK_ASSET), tx),
        datom(1014, "block/page", json!(160), tx),
        datom(1014, "block/parent", json!(160), tx),
        datom(1014, "block/order", s("a0"), tx),
        datom(1014, "block/tags", json!(160), tx),
        datom(1014, "block/title", s("image.png"), tx),
    ]);

    let tail = vec![vec![
        datom(1005, "block/order", s("a2"), -(tx + 1)),
        datom(1005, "block/order", s("a01"), tx + 1),
    ]];

    write_logseq_sqlite(path, &[leaf1, leaf2], Some(tail));
}

#[test]
fn round_trip_import_and_export_matches_hand_written_expectations() -> Result<()> {
    let dir = temp_dir("roundtrip");
    let fixture = dir.join("fixture.sqlite");
    build_synthetic_fixture(&fixture, 65);

    let mut store = Store::open_in_memory()?;

    let dry = import_logseq_db(
        &fixture,
        &mut store,
        &ImportOptions {
            dry_run: true,
            ..ImportOptions::default()
        },
    )?;
    assert!(dry.dry_run);
    assert_eq!(dry.schema_major, 65);
    assert_eq!(dry.schema_minor, 36);
    assert_eq!(dry.pages_imported, 4);
    assert_eq!(dry.journals_imported, 1);
    assert_eq!(dry.blocks_imported, 10);
    assert_eq!(dry.txns_written, 0);
    assert!(store.list_live_pages()?.is_empty());

    let report = import_logseq_db(&fixture, &mut store, &ImportOptions::default())?;
    assert!(!report.dry_run);
    assert_eq!(report.pages_imported, 4);
    assert_eq!(report.journals_imported, 1);
    assert_eq!(report.blocks_imported, 10);
    assert_eq!(report.collapsed_applied, 1);
    assert_eq!(report.favorites_applied, 1);
    assert_eq!(report.skipped.recycled_or_deleted, 3);
    assert_eq!(report.skipped.views, 1);
    assert_eq!(report.skipped.assets, 1);
    assert_eq!(report.unresolved_refs.len(), 1);
    assert_eq!(report.unresolved_refs[0].kind, "page");
    assert_eq!(report.unresolved_refs[0].target, UUID_BLK_MISSING_REF);

    let notes_id = Id::from_uuid(Uuid::parse_str(UUID_PAGE_NOTES)?);
    let dup_id = Id::from_uuid(Uuid::parse_str(UUID_PAGE_DUP)?);
    let cjk_id = Id::from_uuid(Uuid::parse_str(UUID_PAGE_CJK)?);
    let journal_id = Id::from_uuid(Uuid::parse_str(UUID_PAGE_JOURNAL)?);
    let heading_id = Id::from_uuid(Uuid::parse_str(UUID_BLK_HEADING)?);
    let child_id = Id::from_uuid(Uuid::parse_str(UUID_BLK_CHILD)?);
    let recycled_id = Id::from_uuid(Uuid::parse_str(UUID_BLK_RECYCLED)?);
    let deleted_id = Id::from_uuid(Uuid::parse_str(UUID_BLK_DELETED)?);

    let notes_page = store.get_page(notes_id)?.expect("notes page");
    assert_eq!(notes_page.title, "Notes");
    assert!(notes_page.favorite);

    let dup_page = store.get_page(dup_id)?.expect("dup page");
    assert_eq!(dup_page.title, "notes (2)");

    let journal_page = store.get_page(journal_id)?.expect("journal page");
    assert_eq!(journal_page.title, "2026-02-14");
    assert_eq!(journal_page.journal_day, Some(20260214));

    assert!(store.get_block(recycled_id)?.is_none());
    assert!(store.get_block(deleted_id)?.is_none());

    let heading = store.get_block(heading_id)?.expect("heading block");
    assert_eq!(heading.content, "## Overview");
    assert!(heading.collapsed);

    let child = store.get_block(child_id)?.expect("child block");
    assert_eq!(child.parent_id, Some(heading_id));
    assert_eq!(
        child.content,
        format!("See [[{UUID_PAGE_CJK}]] and missing [missing:999999] #[[{UUID_TAG_PROJECT}]]")
    );

    let cjk_backlinks = store.backlinks(cjk_id)?;
    assert_eq!(cjk_backlinks.len(), 1);
    assert_eq!(cjk_backlinks[0].block_id, child_id);

    let child_backlinks = store.backlinks(child_id)?;
    assert_eq!(child_backlinks.len(), 1);
    assert_eq!(
        child_backlinks[0].block_id,
        Id::from_uuid(Uuid::parse_str(UUID_BLK_JOURNAL_REF)?)
    );

    let owner_props = store.find_props("owner", None)?;
    assert_eq!(owner_props.len(), 1);
    assert_eq!(owner_props[0].value_ref, Some(notes_id));

    let done_tasks = store.list_tasks(Some("DONE"))?;
    assert_eq!(done_tasks.len(), 1);
    assert_eq!(done_tasks[0].content, "DONE Ship importer");

    let later_tasks = store.list_tasks(Some("LATER"))?;
    assert_eq!(later_tasks.len(), 1);
    assert_eq!(
        later_tasks[0].content,
        "LATER Polish docs\nlogseq-status:: Backlog\npriority:: High"
    );

    let snapshot_before = store.live_snapshot()?;
    let second = import_logseq_db(&fixture, &mut store, &ImportOptions::default())?;
    assert_eq!(second.pages_imported, 0);
    assert_eq!(second.journals_imported, 0);
    assert_eq!(second.blocks_imported, 0);
    assert_eq!(second.txns_written, 0);
    assert_eq!(second.pages_already_present, 5);
    assert_eq!(second.blocks_already_present, 10);
    assert_eq!(store.live_snapshot()?, snapshot_before);

    let out1 = dir.join("export1");
    let out2 = dir.join("export2");
    let exp1 = export_markdown(&store, &out1)?;
    let exp2 = export_markdown(&store, &out2)?;
    assert_eq!(exp1, exp2);
    assert_eq!(exp1.pages_exported, 4);
    assert_eq!(exp1.journals_exported, 1);
    assert_eq!(exp1.blocks_exported, 10);
    assert_eq!(exp1.files_written, 5);

    let expected_notes = format!(
        "\
- ## Overview
  - See [[日本語/ノート 🚀]] and missing [missing:999999] #Project
    id:: {UUID_BLK_CHILD}
    - Deep leaf line 1
      Deep leaf line 2
- > Stay curious
- ```rust
  fn main() {{
      println!(\"hi\");
  }}
  ```
- DONE Ship importer
- LATER Polish docs
  logseq-status:: Backlog
  priority:: High
"
    );
    let actual_notes = fs::read_to_string(out1.join("pages/Notes.md"))?;
    assert_eq!(actual_notes, expected_notes);

    let expected_journal = format!("- Referenced block (({UUID_BLK_CHILD}))\n");
    let actual_journal = fs::read_to_string(out1.join("journals/2026_02_14.md"))?;
    assert_eq!(actual_journal, expected_journal);

    let expected_cjk = "\
- 漢字メモ
  estimate:: 3
  owner:: [[Notes]]
";
    let actual_cjk = fs::read_to_string(out1.join("pages/日本語___ノート 🚀.md"))?;
    assert_eq!(actual_cjk, expected_cjk);

    let expected_dup = "- Duplicate page body\n";
    let actual_dup = fs::read_to_string(out1.join("pages/notes (2).md"))?;
    assert_eq!(actual_dup, expected_dup);

    for rel in [
        "pages/Notes.md",
        "pages/notes (2).md",
        "pages/Project.md",
        "pages/日本語___ノート 🚀.md",
        "journals/2026_02_14.md",
    ] {
        assert_eq!(fs::read(out1.join(rel))?, fs::read(out2.join(rel))?);
    }

    let _ = fs::remove_dir_all(&dir);
    Ok(())
}

#[test]
fn rejects_unsupported_and_missing_schema_version() {
    let dir = temp_dir("schema-version");
    let bad = dir.join("bad_version.sqlite");
    build_synthetic_fixture(&bad, 99);

    let mut store = Store::open_in_memory().expect("open store");
    let err = import_logseq_db(&bad, &mut store, &ImportOptions::default()).expect_err("must fail");
    assert!(matches!(
        err,
        Error::UnsupportedSchemaVersion {
            major: 99,
            minor: 36
        }
    ));

    let missing = dir.join("missing_version.sqlite");
    write_logseq_sqlite(&missing, &[vec![]], None);
    let err =
        import_logseq_db(&missing, &mut store, &ImportOptions::default()).expect_err("must fail");
    assert!(matches!(err, Error::MissingSchemaVersion));

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn refuses_export_into_logseq_graph_directory() -> Result<()> {
    let dir = temp_dir("refuse-logseq");
    fs::create_dir_all(dir.join("logseq"))?;
    fs::write(dir.join("logseq/config.edn"), "{}")?;

    let store = Store::open_in_memory()?;
    let err = export_markdown(&store, &dir).expect_err("must refuse");
    assert!(matches!(err, Error::RefusedLogseqGraphDir(_)));

    let _ = fs::remove_dir_all(&dir);
    Ok(())
}

#[test]
fn supports_cancellation_between_chunks_and_pages() -> Result<()> {
    let dir = temp_dir("cancel");
    let fixture = dir.join("fixture.sqlite");
    build_synthetic_fixture(&fixture, 65);

    let mut store = Store::open_in_memory()?;
    let err = import_logseq_db_with_progress(
        &fixture,
        &mut store,
        &ImportOptions {
            chunk_size: 2,
            ..ImportOptions::default()
        },
        |done, _total| done < 2,
    )
    .expect_err("must cancel");
    assert!(matches!(err, Error::Cancelled));

    let mut store2 = Store::open_in_memory()?;
    import_logseq_db(&fixture, &mut store2, &ImportOptions::default())?;
    let out = dir.join("out");
    let err = export_markdown_with_progress(&store2, &out, |done, _total| done < 1)
        .expect_err("must cancel");
    assert!(matches!(err, Error::Cancelled));

    let _ = fs::remove_dir_all(&dir);
    Ok(())
}
