use std::env;
use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use pith_core::{Api, Id, Op, Origin, Store, TxMeta, order};

const PAGE_COUNT: usize = 1_000;
const BLOCKS_PER_PAGE: usize = 100;
const TOTAL_BLOCKS: usize = PAGE_COUNT * BLOCKS_PER_PAGE;
const ITERATIONS: usize = 50;

const CAPTURE_BUDGET_MS: f64 = 16.0;
const SEARCH_BUDGET_MS: f64 = 30.0;
const BACKLINKS_BUDGET_MS: f64 = 10.0;
const SUMMARIES_BUDGET_MS: f64 = 50.0;
const EXPORT_BUDGET_SECS: f64 = 15.0;

const TOPICS: &[&str] = &[
    "architecture",
    "performance",
    "outliner",
    "sqlite",
    "sync",
    "android",
    "macos",
    "agents",
    "roadmap",
    "journal",
    "search",
    "backlinks",
    "parser",
    "benchmarks",
    "workflow",
    "design",
];

struct Stats {
    median_ms: f64,
    p95_ms: f64,
}

fn main() -> Result<()> {
    let check_budgets = env::args().any(|arg| arg == "--check");

    let db_path = env::temp_dir().join(format!("pith-bench-{}.db", Id::new()));
    let run_result = run_benchmarks(&db_path, check_budgets);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", db_path.display()));
    }
    run_result
}

fn run_benchmarks(db_path: &std::path::Path, check_budgets: bool) -> Result<()> {
    let mut store = Store::open(db_path)?;

    let seed_start = Instant::now();
    let (hot_page_id, capture_page_id) = seed_graph(&mut store)?;
    let seed_elapsed = seed_start.elapsed();
    println!(
        "Seeded {} pages, {} blocks in {:.2}s",
        PAGE_COUNT,
        TOTAL_BLOCKS,
        seed_elapsed.as_secs_f64()
    );

    let capture = measure_stats(ITERATIONS, || -> Result<()> {
        let key = order::between(Some("V"), None)?;
        store.apply_ops(
            &[Op::InsertBlock {
                id: Id::new(),
                page_id: capture_page_id,
                parent_id: None,
                order_key: key,
                content: "TODO Capture note about [[Page 0]] #topic-0\npriority:: high".to_string(),
            }],
            &TxMeta::new(Origin::User, "me", "capture"),
        )?;
        Ok(())
    })?;

    let backlinks = measure_stats(ITERATIONS, || -> Result<()> {
        let hits = store.backlinks(hot_page_id)?;
        assert!(!hits.is_empty());
        Ok(())
    })?;

    let queries = [
        "architecture",
        "sqlite performance",
        "outliner search",
        "Page 0",
        "detail 500-42",
    ];
    let mut idx = 0usize;
    let search = measure_stats(ITERATIONS, || -> Result<()> {
        let q = queries[idx % queries.len()];
        idx += 1;
        let hits = store.search(q, 20)?;
        assert!(!hits.is_empty());
        Ok(())
    })?;

    let short_search = measure_stats(ITERATIONS, || -> Result<()> {
        let hits = store.search("pa", 20)?;
        assert!(!hits.is_empty());
        Ok(())
    })?;

    let api_search = {
        let api = Api::new(&mut store);
        let mut api_idx = 0usize;
        measure_stats(ITERATIONS, || -> Result<()> {
            let q = queries[api_idx % queries.len()];
            api_idx += 1;
            let hits = api.search(q, 20)?;
            assert!(!hits.is_empty());
            Ok(())
        })?
    };

    let summaries = measure_stats(ITERATIONS, || -> Result<()> {
        let all = store.list_page_summaries()?;
        assert!(all.len() >= PAGE_COUNT);
        Ok(())
    })?;

    let api_show = {
        let api = Api::new(&mut store);
        measure_stats(ITERATIONS, || -> Result<()> {
            let _ = api.show("Page 0", None)?;
            Ok(())
        })?
    };

    let export_dir = env::temp_dir().join(format!("pith-bench-export-{}", Id::new()));
    let export_start = Instant::now();
    let export_report = pith_md::export_markdown(&store, &export_dir)?;
    let export_elapsed = export_start.elapsed().as_secs_f64();
    let _ = std::fs::remove_dir_all(&export_dir);

    println!();
    println!("Results ({ITERATIONS} runs on {TOTAL_BLOCKS} blocks, trigram FTS5):");
    println!(
        "  capture (InsertBlock) : p50={:>6.2} ms  p95={:>6.2} ms  (budget < {CAPTURE_BUDGET_MS:.0} ms)",
        capture.median_ms, capture.p95_ms
    );
    println!(
        "  backlinks (hot page)  : p50={:>6.2} ms  p95={:>6.2} ms  (budget < {BACKLINKS_BUDGET_MS:.0} ms)",
        backlinks.median_ms, backlinks.p95_ms
    );
    println!(
        "  search                : p50={:>6.2} ms  p95={:>6.2} ms  (budget < {SEARCH_BUDGET_MS:.0} ms)",
        search.median_ms, search.p95_ms
    );
    println!(
        "  search (< 3 chars)    : p50={:>6.2} ms  p95={:>6.2} ms  (budget < {SEARCH_BUDGET_MS:.0} ms)",
        short_search.median_ms, short_search.p95_ms
    );
    println!(
        "  api.search (short id) : p50={:>6.2} ms  p95={:>6.2} ms  (budget < {SEARCH_BUDGET_MS:.0} ms)",
        api_search.median_ms, api_search.p95_ms
    );
    println!(
        "  api.show (100 blocks) : p50={:>6.2} ms  p95={:>6.2} ms",
        api_show.median_ms, api_show.p95_ms
    );
    println!(
        "  page summaries (all)  : p50={:>6.2} ms  p95={:>6.2} ms  (budget < {SUMMARIES_BUDGET_MS:.0} ms)",
        summaries.median_ms, summaries.p95_ms
    );
    println!(
        "  markdown export       : {:>6.2} s ({} files, {} blocks)  (budget < {EXPORT_BUDGET_SECS:.0} s)",
        export_elapsed, export_report.files_written, export_report.blocks_exported
    );

    if check_budgets {
        if capture.p95_ms >= CAPTURE_BUDGET_MS {
            bail!(
                "capture p95 exceeded budget: {:.2} ms >= {CAPTURE_BUDGET_MS:.0} ms",
                capture.p95_ms
            );
        }
        if backlinks.p95_ms >= BACKLINKS_BUDGET_MS {
            bail!(
                "backlinks p95 exceeded budget: {:.2} ms >= {BACKLINKS_BUDGET_MS:.0} ms",
                backlinks.p95_ms
            );
        }
        if search.p95_ms >= SEARCH_BUDGET_MS {
            bail!(
                "search p95 exceeded budget: {:.2} ms >= {SEARCH_BUDGET_MS:.0} ms",
                search.p95_ms
            );
        }
        if short_search.p95_ms >= SEARCH_BUDGET_MS {
            bail!(
                "short search p95 exceeded budget: {:.2} ms >= {SEARCH_BUDGET_MS:.0} ms",
                short_search.p95_ms
            );
        }
        if summaries.p95_ms >= SUMMARIES_BUDGET_MS {
            bail!(
                "page summaries p95 exceeded budget: {:.2} ms >= {SUMMARIES_BUDGET_MS:.0} ms",
                summaries.p95_ms
            );
        }
        if api_search.p95_ms >= SEARCH_BUDGET_MS {
            bail!(
                "api.search p95 exceeded budget: {:.2} ms >= {SEARCH_BUDGET_MS:.0} ms",
                api_search.p95_ms
            );
        }
        if export_elapsed >= EXPORT_BUDGET_SECS {
            bail!(
                "markdown export exceeded budget: {:.2} s >= {EXPORT_BUDGET_SECS:.0} s",
                export_elapsed
            );
        }
    }

    Ok(())
}

fn seed_graph(store: &mut Store) -> Result<(Id, Id)> {
    let import_meta = TxMeta::new(Origin::Import, "bench", "seed 100k");
    let mut page_ids = Vec::with_capacity(PAGE_COUNT);

    let mut page_ops = Vec::with_capacity(PAGE_COUNT);
    for p in 0..PAGE_COUNT {
        let id = Id::new();
        page_ids.push(id);
        page_ops.push(Op::CreatePage {
            id,
            title: format!("Page {p}"),
            journal_day: None,
            document_mode: false,
        });
    }
    store.apply_ops(&page_ops, &import_meta)?;

    let mut order_keys = Vec::with_capacity(BLOCKS_PER_PAGE);
    let mut prev: Option<String> = None;
    for _ in 0..BLOCKS_PER_PAGE {
        let next = order::between(prev.as_deref(), None)?;
        order_keys.push(next.clone());
        prev = Some(next);
    }

    let hot_page_id = page_ids[0];
    let batch_pages = 25;

    for chunk_start in (0..PAGE_COUNT).step_by(batch_pages) {
        let chunk_end = (chunk_start + batch_pages).min(PAGE_COUNT);
        let mut ops = Vec::with_capacity((chunk_end - chunk_start) * BLOCKS_PER_PAGE);

        for (offset, &page_id) in page_ids[chunk_start..chunk_end].iter().enumerate() {
            let p = chunk_start + offset;
            let mut root_id = None;
            for (b, order_key) in order_keys.iter().enumerate() {
                let block_id = Id::new();
                let parent_id = if b % 5 == 0 {
                    root_id = Some(block_id);
                    None
                } else {
                    root_id
                };
                let topic_a = TOPICS[(p + b) % TOPICS.len()];
                let topic_b = TOPICS[(p * 3 + b * 7) % TOPICS.len()];
                let linked_page = page_ids[(p + b) % PAGE_COUNT];
                let content = if b == 0 && p % 5 == 0 {
                    format!(
                        "TODO Review [[{hot_page_id}]] {topic_a} and {topic_b} item {p}-{b}\nstatus:: open"
                    )
                } else {
                    format!(
                        "Notes on {topic_a} with [[{linked_page}]] and {topic_b} detail {p}-{b}"
                    )
                };
                ops.push(Op::InsertBlock {
                    id: block_id,
                    page_id,
                    parent_id,
                    order_key: order_key.clone(),
                    content,
                });
            }
        }
        store.apply_ops(&ops, &import_meta)?;
    }

    Ok((hot_page_id, page_ids[PAGE_COUNT - 1]))
}

fn measure_stats<F>(iterations: usize, mut f: F) -> Result<Stats>
where
    F: FnMut() -> Result<()>,
{
    for _ in 0..3 {
        f()?;
    }
    let mut samples: Vec<Duration> = Vec::with_capacity(iterations);
    for _ in 0..iterations {
        let start = Instant::now();
        f()?;
        samples.push(start.elapsed());
    }
    samples.sort();
    let median = samples[samples.len() / 2];
    let p95_idx = ((samples.len() * 95) / 100).min(samples.len() - 1);
    let p95 = samples[p95_idx];
    Ok(Stats {
        median_ms: median.as_secs_f64() * 1000.0,
        p95_ms: p95.as_secs_f64() * 1000.0,
    })
}
