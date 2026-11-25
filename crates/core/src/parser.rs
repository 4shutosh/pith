use uuid::Uuid;

use crate::id::Id;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefKind {
    Page,
    Block,
    Tag,
    Prop,
}

impl RefKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Page => "page",
            Self::Block => "block",
            Self::Tag => "tag",
            Self::Prop => "prop",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefTarget {
    Id(Id),
    Title(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Span<'a> {
    Text(&'a str),
    Code(&'a str),
    PageLink { raw: &'a str, target: RefTarget },
    BracketTag { raw: &'a str, target: RefTarget },
    SimpleTag { raw: &'a str, target: RefTarget },
    BlockRef { raw: &'a str, id: Id },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedRef {
    pub kind: RefKind,
    pub target: RefTarget,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedProp {
    pub key: String,
    pub value: String,
    pub value_ref: Option<RefTarget>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedContent {
    pub refs: Vec<ParsedRef>,
    pub props: Vec<ParsedProp>,
    pub task_state: Option<String>,
}

const TASK_STATES: &[&str] = &[
    "TODO",
    "DOING",
    "DONE",
    "LATER",
    "NOW",
    "WAITING",
    "CANCELED",
    "CANCELLED",
];

pub fn tokenize(content: &str) -> Vec<Span<'_>> {
    let bytes = content.as_bytes();
    let len = bytes.len();
    let mut out = Vec::new();
    let mut i = 0;
    let mut text_start = 0;

    while i < len {
        let at_line_start = i == 0 || bytes[i - 1] == b'\n';
        if at_line_start && let Some(fence_end) = scan_fenced_code(content, i) {
            push_text(&mut out, &content[text_start..i]);
            out.push(Span::Code(&content[i..fence_end]));
            i = fence_end;
            text_start = i;
            continue;
        }

        if bytes[i] == b'`'
            && let Some(code_end) = scan_inline_code(content, i)
        {
            push_text(&mut out, &content[text_start..i]);
            out.push(Span::Code(&content[i..code_end]));
            i = code_end;
            text_start = i;
            continue;
        }

        if bytes[i] == b'#'
            && i + 2 < len
            && bytes[i + 1] == b'['
            && bytes[i + 2] == b'['
            && let Some((inner, next_i)) = scan_delimited(content, i + 3, b']', b']')
            && !inner.is_empty()
        {
            push_text(&mut out, &content[text_start..i]);
            out.push(Span::BracketTag {
                raw: &content[i..next_i],
                target: parse_target(inner),
            });
            i = next_i;
            text_start = i;
            continue;
        }

        if bytes[i] == b'['
            && i + 1 < len
            && bytes[i + 1] == b'['
            && let Some((inner, next_i)) = scan_delimited(content, i + 2, b']', b']')
            && !inner.is_empty()
        {
            push_text(&mut out, &content[text_start..i]);
            out.push(Span::PageLink {
                raw: &content[i..next_i],
                target: parse_target(inner),
            });
            i = next_i;
            text_start = i;
            continue;
        }

        if bytes[i] == b'('
            && i + 1 < len
            && bytes[i + 1] == b'('
            && let Some((inner, next_i)) = scan_delimited(content, i + 2, b')', b')')
            && let Ok(uuid) = Uuid::parse_str(inner.trim())
        {
            push_text(&mut out, &content[text_start..i]);
            out.push(Span::BlockRef {
                raw: &content[i..next_i],
                id: Id::from_uuid(uuid),
            });
            i = next_i;
            text_start = i;
            continue;
        }

        if bytes[i] == b'#' && is_tag_boundary(content, i) {
            let start = i + 1;
            let end = content[start..]
                .char_indices()
                .find(|&(_, ch)| !is_tag_char(ch))
                .map_or(len, |(offset, _)| start + offset);
            if end > start {
                push_text(&mut out, &content[text_start..i]);
                let tag = &content[start..end];
                out.push(Span::SimpleTag {
                    raw: &content[i..end],
                    target: parse_target(tag),
                });
                i = end;
                text_start = i;
                continue;
            }
        }

        let ch = content[i..].chars().next().expect("valid utf-8 boundary");
        i += ch.len_utf8();
    }

    push_text(&mut out, &content[text_start..len]);
    out
}

struct LineCollector<'a> {
    text: String,
    spans: Vec<Span<'a>>,
    code_only: bool,
    refs: Vec<ParsedRef>,
    props: Vec<ParsedProp>,
}

impl<'a> LineCollector<'a> {
    fn new() -> Self {
        Self {
            text: String::new(),
            spans: Vec::new(),
            code_only: true,
            refs: Vec::new(),
            props: Vec::new(),
        }
    }

    fn push_text(&mut self, s: &str) {
        if !s.is_empty() {
            self.text.push_str(s);
            self.code_only = false;
        }
    }

    fn push_ref_span(&mut self, raw: &str, span: Span<'a>) {
        self.text.push_str(raw);
        self.code_only = false;
        self.spans.push(span);
    }

    fn flush(&mut self) {
        if self.text.is_empty() && self.spans.is_empty() {
            return;
        }
        if !self.code_only
            && let Some((key, value)) = parse_prop_line(&self.text)
        {
            let value_spans = tokenize(value);
            let line_refs = collect_refs_from_spans(&value_spans);
            let value_ref = line_refs.first().map(|r| r.target.clone());
            for r in &line_refs {
                self.refs.push(ParsedRef {
                    kind: RefKind::Prop,
                    target: r.target.clone(),
                });
            }
            self.props.push(ParsedProp {
                key: key.to_string(),
                value: value.to_string(),
                value_ref,
            });
        } else {
            self.refs.extend(collect_refs_from_spans(&self.spans));
        }
        self.text.clear();
        self.spans.clear();
        self.code_only = true;
    }
}

pub fn parse_content(content: &str) -> ParsedContent {
    let task_state = parse_task_state(content);
    let mut collector = LineCollector::new();

    for span in tokenize(content) {
        match span {
            Span::Text(s) => {
                let mut parts = s.split('\n');
                if let Some(first) = parts.next() {
                    collector.push_text(first);
                    for next in parts {
                        collector.flush();
                        collector.push_text(next);
                    }
                }
            }
            Span::Code(s) => {
                if s.contains('\n') {
                    collector.flush();
                } else {
                    collector.text.push_str(s);
                }
            }
            Span::PageLink { raw, .. }
            | Span::BracketTag { raw, .. }
            | Span::SimpleTag { raw, .. }
            | Span::BlockRef { raw, .. } => {
                collector.push_ref_span(raw, span);
            }
        }
    }

    collector.flush();

    ParsedContent {
        refs: collector.refs,
        props: collector.props,
        task_state,
    }
}

pub fn parse_task_state(content: &str) -> Option<String> {
    let first_line = content.lines().next()?.trim_start();
    let token = first_line.split_whitespace().next().unwrap_or(first_line);
    if TASK_STATES.contains(&token) {
        Some(token.to_string())
    } else {
        None
    }
}

pub fn rewrite_page_refs<F, E>(content: &str, mut resolve: F) -> std::result::Result<String, E>
where
    F: FnMut(&str) -> std::result::Result<Id, E>,
{
    let mut out = String::with_capacity(content.len());
    for span in tokenize(content) {
        match span {
            Span::Text(s) | Span::Code(s) => out.push_str(s),
            Span::BlockRef { raw, .. } => out.push_str(raw),
            Span::PageLink { target, .. } => {
                let id = match target {
                    RefTarget::Id(id) => id,
                    RefTarget::Title(title) => resolve(&title)?,
                };
                out.push_str("[[");
                out.push_str(&id.to_string());
                out.push_str("]]");
            }
            Span::BracketTag { target, .. } | Span::SimpleTag { target, .. } => {
                let id = match target {
                    RefTarget::Id(id) => id,
                    RefTarget::Title(title) => resolve(&title)?,
                };
                out.push_str("#[[");
                out.push_str(&id.to_string());
                out.push_str("]]");
            }
        }
    }
    Ok(out)
}

pub fn render_page_refs<F, E>(content: &str, mut lookup: F) -> std::result::Result<String, E>
where
    F: FnMut(Id) -> std::result::Result<Option<String>, E>,
{
    render_spans(content, &mut lookup, false)
}

pub fn render_for_search<F, E>(content: &str, mut lookup: F) -> std::result::Result<String, E>
where
    F: FnMut(Id) -> std::result::Result<Option<String>, E>,
{
    render_spans(content, &mut lookup, true)
}

fn render_spans<F, E>(
    content: &str,
    lookup: &mut F,
    strip_block_refs: bool,
) -> std::result::Result<String, E>
where
    F: FnMut(Id) -> std::result::Result<Option<String>, E>,
{
    let mut out = String::with_capacity(content.len());
    for span in tokenize(content) {
        match span {
            Span::Text(s) | Span::Code(s) => out.push_str(s),
            Span::BlockRef { raw, .. } => {
                if !strip_block_refs {
                    out.push_str(raw);
                }
            }
            Span::PageLink { raw, target } => match target {
                RefTarget::Id(id) => match lookup(id)? {
                    Some(title) => out.push_str(&page_link_source(&title)),
                    None => out.push_str(raw),
                },
                RefTarget::Title(_) => out.push_str(raw),
            },
            Span::BracketTag { raw, target } | Span::SimpleTag { raw, target } => match target {
                RefTarget::Id(id) => match lookup(id)? {
                    Some(title) => out.push_str(&tag_source(&title)),
                    None => out.push_str(raw),
                },
                RefTarget::Title(_) => out.push_str(raw),
            },
        }
    }
    Ok(out)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HighlightKind {
    Bracket,
    Link,
    Tag,
    Code,
    BlockRef,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Highlight {
    pub start: usize,
    pub len: usize,
    pub kind: HighlightKind,
}

pub fn highlight_ranges(text: &str) -> Vec<Highlight> {
    let mut out = Vec::new();
    let mut offset = 0;
    for span in tokenize(text) {
        let (slice, kind) = match span {
            Span::Text(s) => (s, None),
            Span::Code(s) => (s, Some(HighlightKind::Code)),
            Span::PageLink { raw, .. } => (raw, Some(HighlightKind::Link)),
            Span::BracketTag { raw, .. } | Span::SimpleTag { raw, .. } => {
                (raw, Some(HighlightKind::Tag))
            }
            Span::BlockRef { raw, .. } => (raw, Some(HighlightKind::BlockRef)),
        };
        let len = slice.chars().count();
        match kind {
            Some(HighlightKind::Link) => {
                out.push(Highlight {
                    start: offset,
                    len: 2,
                    kind: HighlightKind::Bracket,
                });
                out.push(Highlight {
                    start: offset + 2,
                    len: len - 4,
                    kind: HighlightKind::Link,
                });
                out.push(Highlight {
                    start: offset + len - 2,
                    len: 2,
                    kind: HighlightKind::Bracket,
                });
            }
            Some(kind) => out.push(Highlight {
                start: offset,
                len,
                kind,
            }),
            None => {}
        }
        offset += len;
    }
    out
}

pub fn pin_known_titles(content: &str, lookup: impl Fn(&str) -> Option<Id>) -> String {
    let mut out = String::with_capacity(content.len());
    for span in tokenize(content) {
        match span {
            Span::Text(s) | Span::Code(s) => out.push_str(s),
            Span::BlockRef { raw, .. } => out.push_str(raw),
            Span::PageLink { raw, target } => match target {
                RefTarget::Title(title) => match lookup(&title) {
                    Some(id) => out.push_str(&format!("[[{id}]]")),
                    None => out.push_str(raw),
                },
                RefTarget::Id(_) => out.push_str(raw),
            },
            Span::BracketTag { raw, target } | Span::SimpleTag { raw, target } => match target {
                RefTarget::Title(title) => match lookup(&title) {
                    Some(id) => out.push_str(&format!("#[[{id}]]")),
                    None => out.push_str(raw),
                },
                RefTarget::Id(_) => out.push_str(raw),
            },
        }
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompletionKind {
    Page,
    Tag,
    Block,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompletionContext {
    pub kind: CompletionKind,
    pub query: String,
    pub start: usize,
    pub end: usize,
}

pub fn completion_context(text: &str, caret: usize) -> Option<CompletionContext> {
    let chars: Vec<char> = text.chars().collect();
    let caret = caret.min(chars.len());
    let before = &chars[..caret];
    bracket_context(&chars, before, caret, '[', ']')
        .or_else(|| bracket_context(&chars, before, caret, '(', ')'))
        .or_else(|| tag_context(before, caret))
}

fn bracket_context(
    chars: &[char],
    before: &[char],
    caret: usize,
    open: char,
    close: char,
) -> Option<CompletionContext> {
    let open_at = (1..before.len())
        .rev()
        .find(|&i| before[i - 1] == open && before[i] == open)?
        - 1;
    let query: String = before[open_at + 2..].iter().collect();
    if query.contains(['\n', open, close]) {
        return None;
    }
    let closes_after = chars.get(caret) == Some(&close) && chars.get(caret + 1) == Some(&close);
    let end = if closes_after { caret + 2 } else { caret };
    let (kind, start) = match open {
        '(' => (CompletionKind::Block, open_at),
        _ if open_at > 0 && before[open_at - 1] == '#' => (CompletionKind::Tag, open_at - 1),
        _ => (CompletionKind::Page, open_at),
    };
    Some(CompletionContext {
        kind,
        query,
        start,
        end,
    })
}

fn tag_context(before: &[char], caret: usize) -> Option<CompletionContext> {
    let hash = before.iter().rposition(|&c| !is_tag_char(c))?;
    if before[hash] != '#' {
        return None;
    }
    let boundary =
        hash == 0 || before[hash - 1].is_whitespace() || TAG_OPENERS.contains(&before[hash - 1]);
    if !boundary {
        return None;
    }
    Some(CompletionContext {
        kind: CompletionKind::Tag,
        query: before[hash + 1..].iter().collect(),
        start: hash,
        end: caret,
    })
}

pub fn completion_insertion(kind: CompletionKind, value: &str) -> String {
    match kind {
        CompletionKind::Page => page_link_source(value),
        CompletionKind::Tag => tag_source(value),
        CompletionKind::Block => format!("(({value}))"),
    }
}

pub fn apply_completion(text: &str, context: &CompletionContext, value: &str) -> (String, usize) {
    let chars: Vec<char> = text.chars().collect();
    let start = context.start.min(chars.len());
    let end = context.end.clamp(start, chars.len());
    let insertion = completion_insertion(context.kind, value);
    let mut out: String = chars[..start].iter().collect();
    out.push_str(&insertion);
    out.extend(&chars[end..]);
    (out, start + insertion.chars().count())
}

pub fn auto_pair(text: &str, caret: usize) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    if caret < 2 || caret > chars.len() {
        return None;
    }
    let close = match (chars[caret - 2], chars[caret - 1]) {
        ('[', '[') => ']',
        ('(', '(') => ')',
        _ => return None,
    };
    if chars.get(caret) == Some(&close) {
        return None;
    }
    let mut out: String = chars[..caret].iter().collect();
    out.push(close);
    out.push(close);
    out.extend(&chars[caret..]);
    Some(out)
}

pub fn page_link_source(title: &str) -> String {
    format!("[[{title}]]")
}

pub fn tag_source(title: &str) -> String {
    if !title.is_empty() && title.chars().all(is_tag_char) {
        format!("#{title}")
    } else {
        format!("#[[{title}]]")
    }
}

pub fn set_property_in_content(content: &str, key: &str, value: &str) -> String {
    let mut lines: Vec<String> = content.lines().map(ToString::to_string).collect();
    let new_line = format!("{key}:: {value}");
    let mut replaced = false;
    for line in &mut lines {
        if let Some((existing_key, _)) = parse_prop_line(line)
            && existing_key == key
        {
            *line = new_line.clone();
            replaced = true;
            break;
        }
    }
    if !replaced {
        lines.push(new_line);
    }
    lines.join("\n")
}

pub fn remove_property_in_content(content: &str, key: &str) -> String {
    let lines: Vec<&str> = content
        .lines()
        .filter(|line| parse_prop_line(line).is_none_or(|(k, _)| k != key))
        .collect();
    lines.join("\n")
}

pub fn set_task_state_in_content(content: &str, state: Option<&str>) -> String {
    let mut lines: Vec<String> = if content.is_empty() {
        vec![String::new()]
    } else {
        content.lines().map(ToString::to_string).collect()
    };

    let first = lines[0].trim_start().to_string();
    let stripped = match parse_task_state(&first) {
        Some(existing) => first[existing.len()..].trim_start().to_string(),
        None => first,
    };

    lines[0] = match state {
        Some(new_state) => {
            if stripped.is_empty() {
                new_state.to_string()
            } else {
                format!("{new_state} {stripped}")
            }
        }
        None => stripped,
    };

    lines.join("\n")
}

fn collect_refs_from_spans(spans: &[Span<'_>]) -> Vec<ParsedRef> {
    let mut out = Vec::new();
    for span in spans {
        match span {
            Span::PageLink { target, .. } => out.push(ParsedRef {
                kind: RefKind::Page,
                target: target.clone(),
            }),
            Span::BracketTag { target, .. } | Span::SimpleTag { target, .. } => {
                out.push(ParsedRef {
                    kind: RefKind::Tag,
                    target: target.clone(),
                })
            }
            Span::BlockRef { id, .. } => out.push(ParsedRef {
                kind: RefKind::Block,
                target: RefTarget::Id(*id),
            }),
            Span::Text(_) | Span::Code(_) => {}
        }
    }
    out
}

fn push_text<'a>(out: &mut Vec<Span<'a>>, s: &'a str) {
    if !s.is_empty() {
        out.push(Span::Text(s));
    }
}

fn parse_prop_line(line: &str) -> Option<(&str, &str)> {
    let trimmed = line.trim();
    let (key, rest) = trimmed.split_once("::")?;
    if key.is_empty()
        || !key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
    {
        return None;
    }
    Some((key, rest.trim()))
}

fn scan_fenced_code(content: &str, start: usize) -> Option<usize> {
    let rest = &content[start..];
    let first_line_end = rest.find('\n').map_or(rest.len(), |pos| pos + 1);
    let first_line = &rest[..first_line_end];
    let trimmed = first_line.trim_start();
    if !trimmed.starts_with("```") {
        return None;
    }
    let fence_ticks = trimmed.bytes().take_while(|&b| b == b'`').count();

    let mut pos = start + first_line_end;
    while pos < content.len() {
        let line_rest = &content[pos..];
        let line_len = line_rest.find('\n').map_or(line_rest.len(), |p| p + 1);
        let line = &line_rest[..line_len];
        let t = line.trim();
        let ticks = t.bytes().take_while(|&b| b == b'`').count();
        pos += line_len;
        if ticks >= fence_ticks && t.bytes().all(|b| b == b'`') {
            return Some(pos);
        }
    }
    Some(content.len())
}

fn scan_inline_code(content: &str, start: usize) -> Option<usize> {
    let bytes = content.as_bytes();
    let mut ticks = 0;
    while start + ticks < bytes.len() && bytes[start + ticks] == b'`' {
        ticks += 1;
    }
    let mut i = start + ticks;
    while i < bytes.len() {
        if bytes[i] == b'\n' {
            return None;
        }
        if bytes[i] == b'`' {
            let mut run = 0;
            while i + run < bytes.len() && bytes[i + run] == b'`' {
                run += 1;
            }
            if run == ticks {
                return Some(i + run);
            }
            i += run;
            continue;
        }
        i += 1;
    }
    None
}

fn parse_target(raw: &str) -> RefTarget {
    let trimmed = raw.trim();
    match Uuid::parse_str(trimmed) {
        Ok(uuid) => RefTarget::Id(Id::from_uuid(uuid)),
        Err(_) => RefTarget::Title(trimmed.to_string()),
    }
}

fn scan_delimited(text: &str, start: usize, close1: u8, close2: u8) -> Option<(&str, usize)> {
    let bytes = text.as_bytes();
    let open = if close1 == b']' { b'[' } else { b'(' };
    let mut i = start;
    while i + 1 < bytes.len() {
        let b = bytes[i];
        if b == b'\n' || b == b'\r' || b == open {
            return None;
        }
        if b == close1 && bytes[i + 1] == close2 {
            return Some((&text[start..i], i + 2));
        }
        i += 1;
    }
    None
}

const TAG_DELIMITERS: &[char] = &[
    ',', '.', '!', '?', ';', ':', '"', '\'', '`', '(', ')', '[', ']', '{', '}', '<', '>', '#', '*',
    '~', '^', '=', '|', '‘', '’', '“', '”', '«', '»', '。', '、', '，', '！', '？', '：', '；',
];

const TAG_OPENERS: &[char] = &[
    '(', '[', '{', ',', ';', ':', '"', '\'', '“', '‘', '«', '「', '（',
];

fn is_tag_boundary(content: &str, hash_idx: usize) -> bool {
    match content[..hash_idx].chars().next_back() {
        None => true,
        Some(prev) => prev.is_whitespace() || TAG_OPENERS.contains(&prev),
    }
}

fn is_tag_char(ch: char) -> bool {
    !ch.is_whitespace() && !TAG_DELIMITERS.contains(&ch)
}
