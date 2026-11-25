use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{Context, Result};
use pith_core::Id;
use serde_json::Value;

struct TempDb {
    path: PathBuf,
}

impl TempDb {
    fn new() -> Self {
        Self {
            path: std::env::temp_dir().join(format!("pith-cli-e2e-{}.db", Id::new())),
        }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", self.path.display()));
        }
    }
}

fn run_pith(db: &Path, args: &[&str]) -> Result<Output> {
    let output = Command::new(env!("CARGO_BIN_EXE_pith"))
        .arg("--db")
        .arg(db)
        .args(args)
        .output()
        .context("failed to execute pith")?;
    Ok(output)
}

fn run_json(db: &Path, args: &[&str]) -> Result<Value> {
    let mut full = vec!["--output", "json"];
    full.extend_from_slice(args);
    let out = run_pith(db, &full)?;
    if !out.status.success() {
        anyhow::bail!(
            "pith failed: stdout={} stderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    let val: Value = serde_json::from_slice(&out.stdout)?;
    Ok(val)
}

#[test]
fn cli_end_to_end_human_and_json_workflow() -> Result<()> {
    let db = TempDb::new();

    let journal_res = run_json(
        db.path(),
        &[
            "journal",
            "--date",
            "2026-11-25",
            "- Ship M2 [[Roadmap]] #pith\n  - Build CLI",
        ],
    )?;
    assert_eq!(journal_res["dry_run"], false);
    let journal_txn = journal_res["txn_short_id"]
        .as_str()
        .context("txn_short_id")?
        .to_string();
    let journal_page = run_json(db.path(), &["show", "2026-11-25"])?;
    let root_block_short = journal_page["blocks"][0]["short_id"]
        .as_str()
        .context("root block short id")?
        .to_string();

    let show_human = run_pith(db.path(), &["show", "2026-11-25"])?;
    assert!(show_human.status.success());
    let show_text = String::from_utf8(show_human.stdout)?;
    assert!(show_text.contains("# 2026-11-25 (page "));
    assert!(show_text.contains("- Ship M2 [[Roadmap]] #pith"));
    assert!(show_text.contains("  - Build CLI"));

    let search_hits = run_json(db.path(), &["search", "Roadmap"])?;
    let hits_arr = search_hits.as_array().context("search array")?;
    assert!(!hits_arr.is_empty());
    assert_eq!(hits_arr[0]["kind"], "page");
    assert_eq!(hits_arr[0]["title"], "Roadmap");

    let short_hits = run_json(db.path(), &["search", "ro"])?;
    assert_eq!(short_hits.as_array().context("short array")?.len(), 1);

    let backlinks = run_json(db.path(), &["backlinks", "Roadmap"])?;
    assert_eq!(backlinks["backlinks"].as_array().context("bl")?.len(), 1);

    let insert_res = run_json(
        db.path(),
        &["insert", "Roadmap", "- Core CLI\n  - JSON output"],
    )?;
    let roadmap_block = insert_res["created_short_ids"][0]
        .as_str()
        .context("roadmap block")?
        .to_string();

    let dry = run_json(
        db.path(),
        &[
            "update",
            &roadmap_block,
            "Dry change",
            "--expected-version",
            "1",
            "--dry-run",
        ],
    )?;
    assert_eq!(dry["dry_run"], true);
    assert!(dry["txn_id"].is_null());

    let stale = run_pith(
        db.path(),
        &[
            "--output",
            "json",
            "update",
            &roadmap_block,
            "Stale",
            "--expected-version",
            "99",
        ],
    )?;
    assert!(!stale.status.success());
    assert!(stale.stdout.is_empty());
    let err_json: Value = serde_json::from_slice(&stale.stderr)?;
    assert_eq!(err_json["error"], "version_mismatch");
    assert!(err_json["hint"].as_str().is_some());

    run_json(
        db.path(),
        &[
            "update",
            &roadmap_block,
            "Core CLI shipped",
            "--expected-version",
            "1",
        ],
    )?;

    run_json(
        db.path(),
        &[
            "move",
            &roadmap_block,
            "--to",
            &root_block_short,
            "--expected-version",
            "2",
        ],
    )?;

    let moved_show = run_json(db.path(), &["show", &root_block_short])?;
    assert_eq!(
        moved_show["children"].as_array().context("children")?.len(),
        2
    );

    run_json(
        db.path(),
        &["rm", &roadmap_block, "--expected-version", "3"],
    )?;

    let history = run_json(db.path(), &["history", "--limit", "10"])?;
    assert_eq!(history.as_array().context("history")?.len(), 5);

    let undo_rm = run_json(
        db.path(),
        &["undo", history[0]["short_id"].as_str().context("last txn")?],
    )?;
    assert_eq!(undo_rm["dry_run"], false);

    let example = run_pith(db.path(), &["example", "journal"])?;
    assert!(example.status.success());
    assert!(String::from_utf8(example.stdout)?.contains("pith journal"));

    let _ = journal_txn;
    Ok(())
}

#[test]
fn cli_history_lists_all_actors_and_enforces_agent_version_and_suffix_min_len() -> Result<()> {
    let db = TempDb::new();

    run_json(
        db.path(),
        &["journal", "--date", "2026-11-25", "Human note"],
    )?;
    let page = run_json(db.path(), &["show", "2026-11-25"])?;
    let block_short = page["blocks"][0]["short_id"]
        .as_str()
        .context("block short")?
        .to_string();

    let missing_ver = run_pith(
        db.path(),
        &[
            "--output",
            "json",
            "--origin",
            "agent",
            "--actor",
            "agent:claude",
            "update",
            &block_short,
            "Unsafe agent edit",
        ],
    )?;
    assert!(!missing_ver.status.success());
    let err_json: Value = serde_json::from_slice(&missing_ver.stderr)?;
    assert_eq!(err_json["error"], "missing_expected_version");

    run_json(
        db.path(),
        &[
            "--origin",
            "agent",
            "--actor",
            "agent:claude",
            "update",
            &block_short,
            "Safe agent edit",
            "--expected-version",
            "1",
        ],
    )?;

    let all_history = run_json(db.path(), &["history"])?;
    let all_arr = all_history.as_array().context("all history")?;
    assert_eq!(all_arr.len(), 2);
    assert_eq!(all_arr[0]["actor"], "agent:claude");
    assert_eq!(all_arr[1]["actor"], "me");

    let agent_only = run_json(db.path(), &["history", "--by", "agent:claude"])?;
    let agent_arr = agent_only.as_array().context("agent history")?;
    assert_eq!(agent_arr.len(), 1);
    assert_eq!(agent_arr[0]["actor"], "agent:claude");

    let typo = run_pith(db.path(), &["--output", "json", "show", "cafe"])?;
    assert!(!typo.status.success());
    let typo_err: Value = serde_json::from_slice(&typo.stderr)?;
    assert_eq!(typo_err["error"], "not_found");

    let dry_typo = run_json(
        db.path(),
        &[
            "journal",
            "--date",
            "2026-11-25",
            "--dry-run",
            "See [[DryTypo]]",
        ],
    )?;
    let planned_ops = dry_typo["ops"].as_array().context("ops")?;
    assert!(
        planned_ops
            .iter()
            .any(|op| op["type"] == "create_page" && op["title"] == "DryTypo")
    );
    Ok(())
}
