use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;

use pith_core::parser;
use pith_core::{Id, LiveBlockState, Store};
use serde::Serialize;

use crate::{Error, Result};

#[derive(Debug, Clone, Default)]
pub struct ExportOptions {}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ExportReport {
    pub pages_exported: usize,
    pub journals_exported: usize,
    pub blocks_exported: usize,
    pub files_written: usize,
}

pub fn export_markdown(store: &Store, out_dir: &Path) -> Result<ExportReport> {
    export_markdown_with_progress(store, out_dir, |_, _| true)
}

pub fn export_markdown_with_progress<F>(
    store: &Store,
    out_dir: &Path,
    mut on_progress: F,
) -> Result<ExportReport>
where
    F: FnMut(usize, usize) -> bool,
{
    check_safe_export_dir(out_dir)?;

    let pages_dir = out_dir.join("pages");
    let journals_dir = out_dir.join("journals");
    fs::create_dir_all(&pages_dir)?;
    fs::create_dir_all(&journals_dir)?;

    let mut pages = store.list_live_pages()?;
    pages.sort_by(|a, b| {
        a.journal_day
            .cmp(&b.journal_day)
            .then_with(|| a.title_lower.cmp(&b.title_lower))
            .then_with(|| a.id.cmp(&b.id))
    });

    let page_titles: HashMap<Id, String> = pages.iter().map(|p| (p.id, p.title.clone())).collect();

    let snapshot = store.live_snapshot()?;
    let referenced_blocks = store.referenced_block_ids()?;

    let mut blocks_by_page: HashMap<Id, HashMap<Option<Id>, Vec<&LiveBlockState>>> = HashMap::new();
    for block in snapshot.blocks.values() {
        blocks_by_page
            .entry(block.page_id)
            .or_default()
            .entry(block.parent_id)
            .or_default()
            .push(block);
    }
    for tree in blocks_by_page.values_mut() {
        for siblings in tree.values_mut() {
            siblings.sort_by(|a, b| a.order_key.cmp(&b.order_key).then_with(|| a.id.cmp(&b.id)));
        }
    }

    let mut used_page_files: HashSet<String> = HashSet::new();
    let mut used_journal_files: HashSet<String> = HashSet::new();
    let total = pages.len();
    let mut report = ExportReport::default();

    for (idx, page) in pages.iter().enumerate() {
        if !on_progress(idx, total) {
            return Err(Error::Cancelled);
        }

        let file_path = if let Some(day) = page.journal_day {
            let base = format_journal_filename(day, &page.title);
            let unique = deduplicate_filename(&base, &mut used_journal_files);
            report.journals_exported += 1;
            journals_dir.join(format!("{unique}.md"))
        } else {
            let base = sanitize_page_filename(&page.title);
            let unique = deduplicate_filename(&base, &mut used_page_files);
            report.pages_exported += 1;
            pages_dir.join(format!("{unique}.md"))
        };

        let mut buf = String::new();
        if let Some(tree) = blocks_by_page.get(&page.id) {
            let count = render_subtree(tree, None, 0, &page_titles, &referenced_blocks, &mut buf)?;
            report.blocks_exported += count;
        }

        fs::write(&file_path, buf.as_bytes())?;
        report.files_written += 1;
    }

    let _ = on_progress(total, total);
    Ok(report)
}

fn check_safe_export_dir(out_dir: &Path) -> Result<()> {
    let config = out_dir.join("logseq").join("config.edn");
    if config.exists() {
        return Err(Error::RefusedLogseqGraphDir(out_dir.to_path_buf()));
    }
    Ok(())
}

fn render_subtree(
    tree: &HashMap<Option<Id>, Vec<&LiveBlockState>>,
    parent_id: Option<Id>,
    depth: usize,
    page_titles: &HashMap<Id, String>,
    referenced_blocks: &HashSet<Id>,
    out: &mut String,
) -> Result<usize> {
    let Some(siblings) = tree.get(&parent_id) else {
        return Ok(0);
    };
    let indent = "  ".repeat(depth);
    let cont_indent = "  ".repeat(depth + 1);
    let mut count = 0usize;

    for block in siblings {
        let rendered = parser::render_page_refs(&block.content, |id| {
            Ok::<_, Error>(page_titles.get(&id).cloned())
        })?;
        let mut lines = rendered.split('\n');
        let first = lines.next().unwrap_or("");
        out.push_str(&indent);
        out.push_str("- ");
        out.push_str(first);
        out.push('\n');

        let mut has_id_prop = false;
        if first.trim_start().starts_with("id:: ") {
            has_id_prop = true;
        }
        for line in lines {
            if line.trim_start().starts_with("id:: ") {
                has_id_prop = true;
            }
            if !line.is_empty() {
                out.push_str(&cont_indent);
                out.push_str(line);
            }
            out.push('\n');
        }

        if referenced_blocks.contains(&block.id) && !has_id_prop {
            out.push_str(&cont_indent);
            out.push_str("id:: ");
            out.push_str(&block.id.to_string());
            out.push('\n');
        }

        count += 1;
        count += render_subtree(
            tree,
            Some(block.id),
            depth + 1,
            page_titles,
            referenced_blocks,
            out,
        )?;
    }

    Ok(count)
}

fn format_journal_filename(day: i32, fallback_title: &str) -> String {
    let y = day / 10_000;
    let m = (day / 100) % 100;
    let d = day % 100;
    if (1..=12).contains(&m) && (1..=31).contains(&d) {
        format!("{y:04}_{m:02}_{d:02}")
    } else {
        sanitize_page_filename(fallback_title)
    }
}

fn sanitize_page_filename(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    for ch in title.trim().chars() {
        match ch {
            '/' => out.push_str("___"),
            '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => out.push('_'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    let trimmed = out.trim_matches('.').trim().to_string();
    if trimmed.is_empty() {
        "untitled".to_string()
    } else {
        trimmed
    }
}

fn deduplicate_filename(base: &str, used: &mut HashSet<String>) -> String {
    let lower = base.to_lowercase();
    if used.insert(lower) {
        return base.to_string();
    }
    let mut idx = 2usize;
    loop {
        let candidate = format!("{base}_{idx}");
        if used.insert(candidate.to_lowercase()) {
            return candidate;
        }
        idx += 1;
    }
}
