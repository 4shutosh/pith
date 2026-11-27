use crate::id::Id;
use crate::types::{BlockKind, RenderedSpan};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunStyle {
    Plain,
    Marker,
    Code,
    Bold,
    Italic,
    Strike,
    Highlight,
    ExternalLink { url: String },
    Link { page_id: Option<Id>, deleted: bool },
    Tag { page_id: Option<Id>, deleted: bool },
    BlockRef { block_id: Id },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayRun {
    pub display: String,
    pub source: String,
    pub style: RunStyle,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockDisplay {
    pub task_state: Option<String>,
    pub prefix: String,
    pub runs: Vec<DisplayRun>,
}

impl BlockDisplay {
    pub fn text(&self) -> String {
        self.runs.iter().map(|r| r.display.as_str()).collect()
    }
}

fn run(display: &str, source: &str, style: RunStyle) -> DisplayRun {
    DisplayRun {
        display: display.to_string(),
        source: source.to_string(),
        style,
    }
}

pub fn block_display(spans: &[RenderedSpan], kind: &BlockKind) -> BlockDisplay {
    let (task_state, prefix, rest) = split_task(spans);
    let mut runs: Vec<DisplayRun> = rest.iter().flat_map(span_runs).collect();
    match kind {
        BlockKind::Heading { level } => {
            let marker = format!("{} ", "#".repeat(usize::from(*level)));
            runs = hide_leading(&marker, runs);
        }
        BlockKind::Quote => {
            let marker = match runs.first() {
                Some(first)
                    if first.style == RunStyle::Plain && first.display.starts_with("> ") =>
                {
                    "> "
                }
                _ => ">",
            };
            runs = hide_leading(marker, runs);
        }
        BlockKind::Paragraph | BlockKind::CodeBlock { .. } | BlockKind::Divider => {}
    }
    BlockDisplay {
        task_state,
        prefix,
        runs,
    }
}

fn split_task(spans: &[RenderedSpan]) -> (Option<String>, String, Vec<RenderedSpan>) {
    let Some(RenderedSpan::Task { state, source }) = spans.first() else {
        return (None, String::new(), spans.to_vec());
    };
    let mut prefix = source.clone();
    let mut rest: Vec<RenderedSpan> = spans[1..].to_vec();
    if let Some(RenderedSpan::Text(text)) = rest.first().cloned() {
        let spaces: String = text
            .chars()
            .take_while(|c| *c == ' ' || *c == '\t')
            .collect();
        prefix.push_str(&spaces);
        let remainder = &text[spaces.len()..];
        if remainder.is_empty() {
            rest.remove(0);
        } else {
            rest[0] = RenderedSpan::Text(remainder.to_string());
        }
    }
    (Some(state.clone()), prefix, rest)
}

fn hide_leading(marker: &str, runs: Vec<DisplayRun>) -> Vec<DisplayRun> {
    let Some(first) = runs.first() else {
        return runs;
    };
    if first.style != RunStyle::Plain || !first.display.starts_with(marker) {
        return runs;
    }
    let remainder = &first.display[marker.len()..];
    let mut out = vec![run("", marker, RunStyle::Marker)];
    if !remainder.is_empty() {
        out.push(run(remainder, remainder, RunStyle::Plain));
    }
    out.extend(runs.into_iter().skip(1));
    out
}

fn hidden_markers(text: &str, source: &str, style: RunStyle) -> Vec<DisplayRun> {
    let marker_chars = (source.chars().count() - text.chars().count()) / 2;
    let marker: String = source.chars().take(marker_chars).collect();
    vec![
        run("", &marker, RunStyle::Marker),
        run(text, text, style),
        run("", &marker, RunStyle::Marker),
    ]
}

fn span_runs(span: &RenderedSpan) -> Vec<DisplayRun> {
    match span {
        RenderedSpan::Text(text) => vec![run(text, text, RunStyle::Plain)],
        RenderedSpan::Code(text) => {
            let ticks: String = text.chars().take_while(|c| *c == '`').collect();
            let tick_count = ticks.chars().count();
            if tick_count * 2 >= text.chars().count() || !text.ends_with(&ticks) {
                return vec![run(text, text, RunStyle::Code)];
            }
            let inner = &text[ticks.len()..text.len() - ticks.len()];
            vec![
                run("", &ticks, RunStyle::Marker),
                run(inner, inner, RunStyle::Code),
                run("", &ticks, RunStyle::Marker),
            ]
        }
        RenderedSpan::Bold { text, source } => hidden_markers(text, source, RunStyle::Bold),
        RenderedSpan::Italic { text, source } => hidden_markers(text, source, RunStyle::Italic),
        RenderedSpan::Strike { text, source } => hidden_markers(text, source, RunStyle::Strike),
        RenderedSpan::Highlight { text, source } => {
            hidden_markers(text, source, RunStyle::Highlight)
        }
        RenderedSpan::ExternalLink { label, url, source } => {
            vec![run(
                label,
                source,
                RunStyle::ExternalLink { url: url.clone() },
            )]
        }
        RenderedSpan::Task { source, .. } => vec![run(source, source, RunStyle::Plain)],
        RenderedSpan::PageLink {
            page_id,
            title,
            source,
            deleted,
        } => {
            let style = RunStyle::Link {
                page_id: *page_id,
                deleted: *deleted,
            };
            if *source != format!("[[{title}]]") {
                return vec![run(source, source, style)];
            }
            vec![
                run("[[", "[[", RunStyle::Marker),
                run(title, title, style),
                run("]]", "]]", RunStyle::Marker),
            ]
        }
        RenderedSpan::Tag {
            page_id,
            source,
            deleted,
            ..
        } => vec![run(
            source,
            source,
            RunStyle::Tag {
                page_id: *page_id,
                deleted: *deleted,
            },
        )],
        RenderedSpan::BlockRef {
            block_id,
            text,
            source,
        } => vec![run(
            text,
            source,
            RunStyle::BlockRef {
                block_id: *block_id,
            },
        )],
    }
}
