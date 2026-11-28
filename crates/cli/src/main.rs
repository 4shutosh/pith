use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};
use pith_core::{Api, Error, Origin, SearchResultItem, ShowResult, Store, TxMeta, WriteOutcome};
use pith_md::{ExportReport, ImportOptions, ImportReport, export_markdown, import_logseq_db};
use serde::Serialize;

#[derive(Debug, Clone, Copy, ValueEnum)]
enum OutputFormat {
    Human,
    Json,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum CliOrigin {
    User,
    Agent,
}

impl From<CliOrigin> for Origin {
    fn from(value: CliOrigin) -> Self {
        match value {
            CliOrigin::User => Self::User,
            CliOrigin::Agent => Self::Agent,
        }
    }
}

#[derive(Debug, Parser)]
#[command(
    name = "pith",
    version,
    about = "Local-first, agent-native block outliner"
)]
struct Cli {
    #[arg(long, env = "PITH_DB", global = true)]
    db: Option<PathBuf>,

    #[arg(long, value_enum, default_value_t = OutputFormat::Human, global = true)]
    output: OutputFormat,

    #[arg(long, global = true)]
    json: bool,

    #[arg(long, env = "PITH_ACTOR", default_value = "me", global = true)]
    actor: String,

    #[arg(long, value_enum, default_value_t = CliOrigin::User, global = true)]
    origin: CliOrigin,

    #[arg(long, env = "PITH_SESSION", global = true)]
    session: Option<String>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Search {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    Show {
        target: String,
        #[arg(long)]
        depth: Option<usize>,
    },
    Backlinks {
        target: String,
    },
    Journal {
        #[arg(allow_hyphen_values = true)]
        markdown: Option<String>,
        #[arg(long)]
        date: Option<String>,
        #[arg(long)]
        depth: Option<usize>,
        #[arg(long)]
        dry_run: bool,
    },
    Insert {
        parent: String,
        #[arg(allow_hyphen_values = true)]
        markdown: String,
        #[arg(long)]
        after: Option<String>,
        #[arg(long)]
        dry_run: bool,
    },
    Update {
        id: String,
        #[arg(allow_hyphen_values = true)]
        content: String,
        #[arg(long)]
        expected_version: Option<i64>,
        #[arg(long)]
        dry_run: bool,
    },
    Move {
        id: String,
        #[arg(long = "to")]
        parent: String,
        #[arg(long)]
        after: Option<String>,
        #[arg(long)]
        expected_version: Option<i64>,
        #[arg(long)]
        dry_run: bool,
    },
    Rm {
        id: String,
        #[arg(long)]
        expected_version: Option<i64>,
        #[arg(long)]
        dry_run: bool,
    },
    History {
        #[arg(long = "by")]
        by: Option<String>,
        #[arg(long)]
        since: Option<i64>,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    Undo {
        txn_id: String,
        #[arg(long)]
        force: bool,
        #[arg(long)]
        dry_run: bool,
    },
    Import {
        #[command(subcommand)]
        source: ImportSource,
    },
    Export {
        out_dir: PathBuf,
    },
    Example {
        cmd: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
enum ImportSource {
    Logseq {
        path: PathBuf,
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(Serialize)]
struct Failure {
    error: &'static str,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<&'static str>,
}

impl Failure {
    fn new(err: &Error, message: String) -> Self {
        Self {
            error: err.code(),
            message,
            hint: err.hint(),
        }
    }
}

impl From<Error> for Failure {
    fn from(err: Error) -> Self {
        let message = err.to_string();
        Self::new(&err, message)
    }
}

impl From<pith_md::Error> for Failure {
    fn from(err: pith_md::Error) -> Self {
        Self {
            error: err.code(),
            message: err.to_string(),
            hint: None,
        }
    }
}

fn main() -> ExitCode {
    let mut cli = Cli::parse();
    if cli.json {
        cli.output = OutputFormat::Json;
    }
    let output = cli.output;
    match run(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => {
            report_failure(output, &failure);
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<(), Failure> {
    if let Command::Example { cmd } = &cli.command {
        print_example(cmd.as_deref());
        return Ok(());
    }

    let db_path = resolve_db_path(cli.db.clone())?;
    if let Some(parent) = db_path.parent()
        && !parent.as_os_str().is_empty()
    {
        let _ = std::fs::create_dir_all(parent);
    }

    let mut store = Store::open(&db_path)?;

    match cli.command {
        Command::Import {
            source: ImportSource::Logseq { path, dry_run },
        } => {
            let options = ImportOptions {
                dry_run,
                actor: cli.actor,
                ..ImportOptions::default()
            };
            let report = import_logseq_db(&path, &mut store, &options)?;
            print_import_report(cli.output, &report)?;
            return Ok(());
        }
        Command::Export { out_dir } => {
            let report = export_markdown(&store, &out_dir)?;
            print_export_report(cli.output, &report)?;
            return Ok(());
        }
        _ => {}
    }

    let mut api = Api::new(&mut store);
    let outcome = dispatch(&mut api, cli);
    outcome.map_err(|err| {
        let message = api.describe_error(&err);
        Failure::new(&err, message)
    })
}

fn dispatch(api: &mut Api<'_>, cli: Cli) -> Result<(), Error> {
    let make_meta = |summary: &str| {
        let mut meta = TxMeta::new(cli.origin.into(), &cli.actor, summary);
        if let Some(session) = &cli.session {
            meta = meta.with_session(session);
        }
        meta
    };

    match cli.command {
        Command::Search { query, limit } => {
            let items = api.search(&query, limit)?;
            match cli.output {
                OutputFormat::Json => print_json(&items)?,
                OutputFormat::Human => {
                    if items.is_empty() {
                        println!("No results.");
                    } else {
                        for item in items {
                            match item {
                                SearchResultItem::Page {
                                    short_id, title, ..
                                } => {
                                    println!("# {title}  (page {short_id})");
                                }
                                SearchResultItem::Block {
                                    short_id,
                                    breadcrumb,
                                    matched_line,
                                    ..
                                } => {
                                    let path = breadcrumb.join(" / ");
                                    println!("[{path}] - {matched_line}  ^{short_id}");
                                }
                            }
                        }
                    }
                }
            }
        }
        Command::Show { target, depth } => {
            let result = api.show(&target, depth)?;
            match cli.output {
                OutputFormat::Json => print_json(&result)?,
                OutputFormat::Human => match result {
                    ShowResult::Page(page) => println!("{}", page.format_outline()),
                    ShowResult::Block(block) => println!("{}", block.format_outline()),
                },
            }
        }
        Command::Backlinks { target } => {
            let result = api.backlinks(&target)?;
            match cli.output {
                OutputFormat::Json => print_json(&result)?,
                OutputFormat::Human => {
                    println!(
                        "Backlinks for {} ({}): {}",
                        result.target_label,
                        result.target_short_id,
                        result.backlinks.len()
                    );
                    for item in result.backlinks {
                        let first = item.content.lines().next().unwrap_or("");
                        println!(
                            "  [{title}] - {first}  ^{id}",
                            title = item.page_title,
                            id = item.short_id
                        );
                    }
                }
            }
        }
        Command::Journal {
            markdown,
            date,
            depth,
            dry_run,
        } => match markdown {
            Some(md) => {
                let outcome = api.journal_append(
                    &md,
                    date.as_deref(),
                    &make_meta("journal append"),
                    dry_run,
                )?;
                print_write_outcome(cli.output, &outcome)?;
            }
            None => {
                let page = api.journal_show(date.as_deref(), depth)?;
                match cli.output {
                    OutputFormat::Json => print_json(&page)?,
                    OutputFormat::Human => match page {
                        Some(p) => println!("{}", p.format_outline()),
                        None => println!("No journal entries for this date."),
                    },
                }
            }
        },
        Command::Insert {
            parent,
            markdown,
            after,
            dry_run,
        } => {
            let outcome = api.insert(
                &parent,
                after.as_deref(),
                &markdown,
                &make_meta("insert"),
                dry_run,
            )?;
            print_write_outcome(cli.output, &outcome)?;
        }
        Command::Update {
            id,
            content,
            expected_version,
            dry_run,
        } => {
            let outcome = api.update(
                &id,
                &content,
                expected_version,
                &make_meta("update"),
                dry_run,
            )?;
            print_write_outcome(cli.output, &outcome)?;
        }
        Command::Move {
            id,
            parent,
            after,
            expected_version,
            dry_run,
        } => {
            let outcome = api.move_block(
                &id,
                &parent,
                after.as_deref(),
                expected_version,
                &make_meta("move"),
                dry_run,
            )?;
            print_write_outcome(cli.output, &outcome)?;
        }
        Command::Rm {
            id,
            expected_version,
            dry_run,
        } => {
            let outcome = api.delete(&id, expected_version, &make_meta("delete"), dry_run)?;
            print_write_outcome(cli.output, &outcome)?;
        }
        Command::History { by, since, limit } => {
            let entries = api.history(by.as_deref(), since, limit)?;
            match cli.output {
                OutputFormat::Json => print_json(&entries)?,
                OutputFormat::Human => {
                    if entries.is_empty() {
                        println!("No history.");
                    } else {
                        for entry in entries {
                            let undone = if entry.is_undone { " [undone]" } else { "" };
                            println!(
                                "{}  {}  {}  {}{}",
                                entry.short_id,
                                entry.origin.as_str(),
                                entry.actor,
                                entry.summary,
                                undone
                            );
                        }
                    }
                }
            }
        }
        Command::Undo {
            txn_id,
            force,
            dry_run,
        } => {
            let outcome = api.undo(&txn_id, &make_meta("undo"), force, dry_run)?;
            print_write_outcome(cli.output, &outcome)?;
        }
        Command::Import { .. } | Command::Export { .. } | Command::Example { .. } => {}
    }

    Ok(())
}

fn print_import_report(format: OutputFormat, report: &ImportReport) -> Result<(), Failure> {
    match format {
        OutputFormat::Json => {
            print_json(report)?;
        }
        OutputFormat::Human => {
            let mode = if report.dry_run { "Dry run" } else { "Import" };
            println!(
                "{mode} complete (Logseq schema {}.{}):",
                report.schema_major, report.schema_minor
            );
            println!(
                "  Pages: {} imported ({} already present)",
                report.pages_imported, report.pages_already_present
            );
            println!("  Journals: {} imported", report.journals_imported);
            println!(
                "  Blocks: {} imported ({} already present)",
                report.blocks_imported, report.blocks_already_present
            );
            println!(
                "  State: {} collapsed, {} favorites, {} txns written",
                report.collapsed_applied, report.favorites_applied, report.txns_written
            );
            let s = &report.skipped;
            println!(
                "  Skipped: {} total (built-in/hidden={}, recycled/deleted={}, views={}, assets={}, whiteboards={}, properties={}, history={}, files={}, kv={}, other={})",
                s.total(),
                s.built_in_or_hidden,
                s.recycled_or_deleted,
                s.views,
                s.assets,
                s.whiteboards,
                s.properties,
                s.history,
                s.files,
                s.kv,
                s.other
            );
            println!("  Unresolved refs: {}", report.unresolved_refs.len());
            for item in report.unresolved_refs.iter().take(5) {
                println!(
                    "    [{}] block {} -> {}",
                    item.kind, item.source_block, item.target
                );
            }
            if !report.downgraded.is_empty() {
                println!("  Downgraded features:");
                for item in &report.downgraded {
                    println!("    {}: {}", item.kind, item.count);
                    for sample in item.samples.iter().take(3) {
                        println!("      - {sample}");
                    }
                }
            }
        }
    }
    Ok(())
}

fn print_export_report(format: OutputFormat, report: &ExportReport) -> Result<(), Failure> {
    match format {
        OutputFormat::Json => {
            print_json(report)?;
        }
        OutputFormat::Human => {
            println!(
                "Exported {} pages, {} journals, {} blocks ({} files).",
                report.pages_exported,
                report.journals_exported,
                report.blocks_exported,
                report.files_written
            );
        }
    }
    Ok(())
}

fn resolve_db_path(explicit: Option<PathBuf>) -> Result<PathBuf, Error> {
    if let Some(path) = explicit {
        return Ok(path);
    }
    if let Ok(home) = env::var("HOME") {
        return Ok(PathBuf::from(home).join(".pith").join("pith.db"));
    }
    Ok(PathBuf::from("pith.db"))
}

fn print_write_outcome(format: OutputFormat, outcome: &WriteOutcome) -> Result<(), Error> {
    match format {
        OutputFormat::Json => print_json(outcome),
        OutputFormat::Human => {
            if outcome.dry_run {
                println!("Dry run: {} op(s) planned.", outcome.ops.len());
                for op in &outcome.ops {
                    println!("  {}", serde_json::to_string(op)?);
                }
            } else {
                let txn = outcome.txn_short_id.as_deref().unwrap_or("-");
                if outcome.created_short_ids.is_empty() {
                    println!("Committed txn {txn} ({} op(s)).", outcome.ops.len());
                } else {
                    println!(
                        "Committed txn {txn} ({} op(s), created: {}).",
                        outcome.ops.len(),
                        outcome.created_short_ids.join(", ")
                    );
                }
            }
            Ok(())
        }
    }
}

fn print_json<T: Serialize>(value: &T) -> Result<(), Error> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

fn report_failure(format: OutputFormat, failure: &Failure) {
    match format {
        OutputFormat::Json => match serde_json::to_string_pretty(failure) {
            Ok(json) => eprintln!("{json}"),
            Err(_) => eprintln!("{}", failure.message),
        },
        OutputFormat::Human => {
            eprintln!("error[{}]: {}", failure.error, failure.message);
            if let Some(hint) = failure.hint {
                eprintln!("hint: {hint}");
            }
        }
    }
}

fn print_example(cmd: Option<&str>) {
    match cmd {
        Some("journal") => println!(
            "pith journal\npith journal \"Ship M2 [[Roadmap]] #pith\"\npith journal --date 2026-11-25 \"- Item A\\n  - Subitem\""
        ),
        Some("search") => println!("pith search \"roadmap\"\npith search \"pr\" --output json"),
        Some("show") => println!("pith show \"Roadmap\"\npith show a1b2c3 --depth 2"),
        Some("insert") => println!(
            "pith insert \"Roadmap\" \"- New task\\n  - Detail\"\npith insert a1b2c3 \"Child note\" --after d4e5f6"
        ),
        Some("update") => {
            println!("pith update a1b2c3 \"Updated text\" --expected-version 1 --dry-run")
        }
        Some("move") => println!("pith move a1b2c3 --to \"Inbox\" --expected-version 1"),
        Some("rm") => println!("pith rm a1b2c3 --expected-version 1"),
        Some("history") => println!("pith history\npith history --by agent:claude --limit 10"),
        Some("undo") => println!("pith undo 9f1c2e\npith undo 9f1c2e --force"),
        Some("import") => println!(
            "pith import logseq export.sqlite --dry-run\npith import logseq export.sqlite --json"
        ),
        Some("export") => println!("pith export ./markdown-backup\npith export ./backup --json"),
        _ => println!(
            "pith journal \"Hello [[Roadmap]]\"\npith show \"Roadmap\"\npith search \"Hello\"\npith backlinks \"Roadmap\"\npith import logseq export.sqlite --dry-run\npith export ./backup\npith history\npith undo <txn-id>\n\nRun `pith example <cmd>` for command-specific examples."
        ),
    }
}
