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
    Bold,
    Italic,
    Strike,
    Highlight,
    ExternalLink,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InlineFormat {
    Bold,
    Italic,
    Strike,
    Highlight,
}

impl InlineFormat {
    pub fn delimiter(self) -> &'static str {
        match self {
            Self::Bold => "**",
            Self::Italic => "*",
            Self::Strike => "~~",
            Self::Highlight => "==",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InlineToken<'a> {
    Text(&'a str),
    Bold {
        inner: &'a str,
        raw: &'a str,
    },
    Italic {
        inner: &'a str,
        raw: &'a str,
    },
    Strike {
        inner: &'a str,
        raw: &'a str,
    },
    Highlight {
        inner: &'a str,
        raw: &'a str,
    },
    ExternalLink {
        label: &'a str,
        url: &'a str,
        raw: &'a str,
    },
}

pub fn tokenize_inline(text: &str) -> Vec<InlineToken<'_>> {
    let bytes = text.as_bytes();
    let len = bytes.len();
    let mut out = Vec::new();
    let mut i = 0;
    let mut text_start = 0;

    while i < len {
        if i + 1 < len
            && bytes[i] == b'*'
            && bytes[i + 1] == b'*'
            && let Some((inner, end)) = scan_inline_pair(text, i, "**")
        {
            push_inline_text(&mut out, &text[text_start..i]);
            out.push(InlineToken::Bold {
                inner,
                raw: &text[i..end],
            });
            i = end;
            text_start = i;
            continue;
        }
        if i + 1 < len
            && bytes[i] == b'~'
            && bytes[i + 1] == b'~'
            && let Some((inner, end)) = scan_inline_pair(text, i, "~~")
        {
            push_inline_text(&mut out, &text[text_start..i]);
            out.push(InlineToken::Strike {
                inner,
                raw: &text[i..end],
            });
            i = end;
            text_start = i;
            continue;
        }
        if i + 1 < len
            && bytes[i] == b'='
            && bytes[i + 1] == b'='
            && let Some((inner, end)) = scan_inline_pair(text, i, "==")
        {
            push_inline_text(&mut out, &text[text_start..i]);
            out.push(InlineToken::Highlight {
                inner,
                raw: &text[i..end],
            });
            i = end;
            text_start = i;
            continue;
        }
        if bytes[i] == b'*'
            && (i + 1 >= len || bytes[i + 1] != b'*')
            && let Some((inner, end)) = scan_single_italic(text, i)
        {
            push_inline_text(&mut out, &text[text_start..i]);
            out.push(InlineToken::Italic {
                inner,
                raw: &text[i..end],
            });
            i = end;
            text_start = i;
            continue;
        }
        if bytes[i] == b'['
            && let Some((label, url, end)) = scan_markdown_link(text, i)
        {
            push_inline_text(&mut out, &text[text_start..i]);
            out.push(InlineToken::ExternalLink {
                label,
                url,
                raw: &text[i..end],
            });
            i = end;
            text_start = i;
            continue;
        }
        if (text[i..].starts_with("https://") || text[i..].starts_with("http://"))
            && (i == 0 || !bytes[i - 1].is_ascii_alphanumeric())
            && let Some(end) = scan_autolink(text, i)
        {
            push_inline_text(&mut out, &text[text_start..i]);
            let url = &text[i..end];
            out.push(InlineToken::ExternalLink {
                label: url,
                url,
                raw: url,
            });
            i = end;
            text_start = i;
            continue;
        }
        i += text[i..].chars().next().map_or(1, char::len_utf8);
    }

    push_inline_text(&mut out, &text[text_start..]);
    out
}

fn push_inline_text<'a>(out: &mut Vec<InlineToken<'a>>, slice: &'a str) {
    if !slice.is_empty() {
        out.push(InlineToken::Text(slice));
    }
}

fn scan_inline_pair<'a>(text: &'a str, start: usize, delim: &str) -> Option<(&'a str, usize)> {
    let dlen = delim.len();
    let rest = &text[start + dlen..];
    let close = rest.find(delim)?;
    if close == 0 {
        return None;
    }
    let inner = &rest[..close];
    if inner.contains('\n')
        || inner.starts_with(char::is_whitespace)
        || inner.ends_with(char::is_whitespace)
    {
        return None;
    }
    Some((inner, start + dlen + close + dlen))
}

fn scan_single_italic(text: &str, start: usize) -> Option<(&str, usize)> {
    let rest = &text[start + 1..];
    let bytes = rest.as_bytes();
    for (idx, &b) in bytes.iter().enumerate() {
        if b == b'\n' {
            return None;
        }
        if b == b'*' {
            if idx == 0 {
                return None;
            }
            let inner = &rest[..idx];
            if inner.starts_with(char::is_whitespace) || inner.ends_with(char::is_whitespace) {
                return None;
            }
            return Some((inner, start + 1 + idx + 1));
        }
    }
    None
}

fn scan_markdown_link(text: &str, start: usize) -> Option<(&str, &str, usize)> {
    let rest = &text[start + 1..];
    let close_bracket = rest.find(']')?;
    let label = &rest[..close_bracket];
    if label.is_empty() || label.contains(['\n', '[', ']']) {
        return None;
    }
    let after_bracket = &rest[close_bracket + 1..];
    if !after_bracket.starts_with('(') {
        return None;
    }
    let close_paren = after_bracket[1..].find(')')?;
    let url = &after_bracket[1..1 + close_paren];
    if url.is_empty()
        || url.contains(char::is_whitespace)
        || !(url.starts_with("https://")
            || url.starts_with("http://")
            || url.starts_with("mailto:"))
    {
        return None;
    }
    let end = start + 1 + close_bracket + 2 + close_paren + 1;
    Some((label, url, end))
}

fn scan_autolink(text: &str, start: usize) -> Option<usize> {
    let rest = &text[start..];
    let mut end = rest
        .find(|c: char| c.is_whitespace() || matches!(c, '<' | '>' | '"' | '\''))
        .unwrap_or(rest.len());
    while end > 0 {
        let last = rest[..end].chars().next_back()?;
        if matches!(last, '.' | ',' | ';' | ':' | '!' | '?' | ')' | ']' | '}') {
            end -= last.len_utf8();
        } else {
            break;
        }
    }
    let scheme_len = if rest.starts_with("https://") { 8 } else { 7 };
    if end <= scheme_len {
        return None;
    }
    Some(start + end)
}

pub fn toggle_inline_format(
    text: &str,
    start: usize,
    end: usize,
    format: InlineFormat,
) -> (String, usize, usize) {
    let chars: Vec<char> = text.chars().collect();
    let len = chars.len();
    let s = start.min(len);
    let e = end.clamp(s, len);
    let delim: Vec<char> = format.delimiter().chars().collect();
    let dlen = delim.len();

    if s == e {
        let mut out = String::with_capacity(text.len() + dlen * 2);
        out.extend(&chars[..s]);
        out.extend(&delim);
        out.extend(&delim);
        out.extend(&chars[s..]);
        return (out, s + dlen, s + dlen);
    }

    if s >= dlen
        && e + dlen <= len
        && chars[s - dlen..s] == delim[..]
        && chars[e..e + dlen] == delim[..]
    {
        let mut out = String::with_capacity(text.len());
        out.extend(&chars[..s - dlen]);
        out.extend(&chars[s..e]);
        out.extend(&chars[e + dlen..]);
        return (out, s - dlen, e - dlen);
    }

    if e - s >= dlen * 2 && chars[s..s + dlen] == delim[..] && chars[e - dlen..e] == delim[..] {
        let mut out = String::with_capacity(text.len());
        out.extend(&chars[..s]);
        out.extend(&chars[s + dlen..e - dlen]);
        out.extend(&chars[e..]);
        return (out, s, e - dlen * 2);
    }

    let mut out = String::with_capacity(text.len() + dlen * 2);
    out.extend(&chars[..s]);
    out.extend(&delim);
    out.extend(&chars[s..e]);
    out.extend(&delim);
    out.extend(&chars[e..]);
    (out, s + dlen, e + dlen)
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
        match span {
            Span::Text(s) => {
                for inline in tokenize_inline(s) {
                    match inline {
                        InlineToken::Text(t) => offset += t.chars().count(),
                        InlineToken::Bold { inner, raw } => {
                            push_delimited_highlight(
                                &mut out,
                                offset,
                                2,
                                inner.chars().count(),
                                HighlightKind::Bold,
                            );
                            offset += raw.chars().count();
                        }
                        InlineToken::Italic { inner, raw } => {
                            push_delimited_highlight(
                                &mut out,
                                offset,
                                1,
                                inner.chars().count(),
                                HighlightKind::Italic,
                            );
                            offset += raw.chars().count();
                        }
                        InlineToken::Strike { inner, raw } => {
                            push_delimited_highlight(
                                &mut out,
                                offset,
                                2,
                                inner.chars().count(),
                                HighlightKind::Strike,
                            );
                            offset += raw.chars().count();
                        }
                        InlineToken::Highlight { inner, raw } => {
                            push_delimited_highlight(
                                &mut out,
                                offset,
                                2,
                                inner.chars().count(),
                                HighlightKind::Highlight,
                            );
                            offset += raw.chars().count();
                        }
                        InlineToken::ExternalLink { label, raw, .. } => {
                            let raw_len = raw.chars().count();
                            let label_len = label.chars().count();
                            if raw.starts_with('[') && raw_len > label_len + 2 {
                                out.push(Highlight {
                                    start: offset,
                                    len: 1,
                                    kind: HighlightKind::Bracket,
                                });
                                out.push(Highlight {
                                    start: offset + 1,
                                    len: label_len,
                                    kind: HighlightKind::ExternalLink,
                                });
                                out.push(Highlight {
                                    start: offset + 1 + label_len,
                                    len: raw_len - label_len - 1,
                                    kind: HighlightKind::Bracket,
                                });
                            } else {
                                out.push(Highlight {
                                    start: offset,
                                    len: raw_len,
                                    kind: HighlightKind::ExternalLink,
                                });
                            }
                            offset += raw_len;
                        }
                    }
                }
            }
            Span::Code(s) => {
                let len = s.chars().count();
                out.push(Highlight {
                    start: offset,
                    len,
                    kind: HighlightKind::Code,
                });
                offset += len;
            }
            Span::PageLink { raw, .. } => {
                let len = raw.chars().count();
                push_delimited_highlight(&mut out, offset, 2, len - 4, HighlightKind::Link);
                offset += len;
            }
            Span::BracketTag { raw, .. } | Span::SimpleTag { raw, .. } => {
                let len = raw.chars().count();
                out.push(Highlight {
                    start: offset,
                    len,
                    kind: HighlightKind::Tag,
                });
                offset += len;
            }
            Span::BlockRef { raw, .. } => {
                let len = raw.chars().count();
                out.push(Highlight {
                    start: offset,
                    len,
                    kind: HighlightKind::BlockRef,
                });
                offset += len;
            }
        }
    }
    out
}

fn push_delimited_highlight(
    out: &mut Vec<Highlight>,
    offset: usize,
    delim_len: usize,
    inner_len: usize,
    kind: HighlightKind,
) {
    out.push(Highlight {
        start: offset,
        len: delim_len,
        kind: HighlightKind::Bracket,
    });
    out.push(Highlight {
        start: offset + delim_len,
        len: inner_len,
        kind,
    });
    out.push(Highlight {
        start: offset + delim_len + inner_len,
        len: delim_len,
        kind: HighlightKind::Bracket,
    });
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
    Slash,
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
        .or_else(|| slash_context(before, caret))
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

fn slash_context(before: &[char], caret: usize) -> Option<CompletionContext> {
    let slash = before
        .iter()
        .rposition(|&c| c == '/' || c.is_whitespace())?;
    if before[slash] != '/' {
        return None;
    }
    let boundary = slash == 0 || before[slash - 1].is_whitespace();
    if !boundary {
        return None;
    }
    Some(CompletionContext {
        kind: CompletionKind::Slash,
        query: before[slash + 1..].iter().collect(),
        start: slash,
        end: caret,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlashCommand {
    Todo,
    Doing,
    Done,
    Today,
    Tomorrow,
    Yesterday,
    CurrentTime,
    CodeBlock,
}

impl SlashCommand {
    pub const ALL: [SlashCommand; 8] = [
        Self::Todo,
        Self::Doing,
        Self::Done,
        Self::Today,
        Self::Tomorrow,
        Self::Yesterday,
        Self::CurrentTime,
        Self::CodeBlock,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Todo => "TODO",
            Self::Doing => "DOING",
            Self::Done => "DONE",
            Self::Today => "Today",
            Self::Tomorrow => "Tomorrow",
            Self::Yesterday => "Yesterday",
            Self::CurrentTime => "Current time",
            Self::CodeBlock => "Code block",
        }
    }

    fn task_state(self) -> Option<&'static str> {
        match self {
            Self::Todo => Some("TODO"),
            Self::Doing => Some("DOING"),
            Self::Done => Some("DONE"),
            _ => None,
        }
    }
}

pub fn slash_commands(query: &str) -> Vec<SlashCommand> {
    let needle = query.trim().to_lowercase();
    SlashCommand::ALL
        .into_iter()
        .filter(|c| c.label().to_lowercase().contains(&needle))
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlashClock<'a> {
    pub today: &'a str,
    pub tomorrow: &'a str,
    pub yesterday: &'a str,
    pub time: &'a str,
}

pub fn slash_preview(command: SlashCommand, clock: &SlashClock<'_>) -> Option<String> {
    match command {
        SlashCommand::Today => Some(clock.today.to_string()),
        SlashCommand::Tomorrow => Some(clock.tomorrow.to_string()),
        SlashCommand::Yesterday => Some(clock.yesterday.to_string()),
        SlashCommand::CurrentTime => Some(clock.time.to_string()),
        SlashCommand::Todo | SlashCommand::Doing | SlashCommand::Done | SlashCommand::CodeBlock => {
            None
        }
    }
}

pub fn apply_slash_command(
    text: &str,
    caret: usize,
    command: SlashCommand,
    clock: &SlashClock<'_>,
) -> Option<(String, usize)> {
    let context = completion_context(text, caret).filter(|c| c.kind == CompletionKind::Slash)?;
    let chars: Vec<char> = text.chars().collect();
    let before: String = chars[..context.start].iter().collect();
    let after: String = chars[context.end..].iter().collect();
    if let Some(state) = command.task_state() {
        let body_before = if context.start == 0 {
            String::new()
        } else {
            before
        };
        let after = if context.start == 0 {
            after.trim_start().to_string()
        } else {
            after
        };
        let stripped = format!("{body_before}{after}");
        let updated = set_task_state_in_content(&stripped, Some(state));
        let shift = updated.chars().count() - stripped.chars().count();
        return Some((updated, body_before.chars().count() + shift));
    }
    let (insertion, caret_in_insertion) = match command {
        SlashCommand::Today => (page_link_source(clock.today), None),
        SlashCommand::Tomorrow => (page_link_source(clock.tomorrow), None),
        SlashCommand::Yesterday => (page_link_source(clock.yesterday), None),
        SlashCommand::CurrentTime => (clock.time.to_string(), None),
        SlashCommand::CodeBlock => ("```\n\n```".to_string(), Some(4)),
        SlashCommand::Todo | SlashCommand::Doing | SlashCommand::Done => return None,
    };
    let start = before.chars().count();
    let caret = start + caret_in_insertion.unwrap_or(insertion.chars().count());
    Some((format!("{before}{insertion}{after}"), caret))
}

pub fn completion_insertion(kind: CompletionKind, value: &str) -> String {
    match kind {
        CompletionKind::Page => page_link_source(value),
        CompletionKind::Tag => tag_source(value),
        CompletionKind::Block => format!("(({value}))"),
        CompletionKind::Slash => value.to_string(),
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

pub fn classify_block(rendered: &str) -> crate::types::BlockKind {
    let trimmed = rendered.trim();
    if trimmed.is_empty() {
        return crate::types::BlockKind::Paragraph;
    }
    if !trimmed.contains('\n')
        && trimmed.len() >= 3
        && (trimmed.bytes().all(|b| b == b'-')
            || trimmed.bytes().all(|b| b == b'*')
            || trimmed.bytes().all(|b| b == b'_'))
    {
        return crate::types::BlockKind::Divider;
    }
    if trimmed.starts_with("```") && scan_fenced_code(trimmed, 0) == Some(trimmed.len()) {
        let first_end = trimmed.find('\n').unwrap_or(trimmed.len());
        let opening = trimmed[..first_end].trim_start_matches('`').trim();
        let language = if opening.is_empty() {
            None
        } else {
            Some(opening.to_string())
        };
        let body = if first_end < trimmed.len() {
            let after_open = &trimmed[first_end + 1..];
            if let Some(last_nl) = after_open.rfind('\n') {
                let last_line = after_open[last_nl + 1..].trim();
                if last_line.len() >= 3 && last_line.bytes().all(|b| b == b'`') {
                    &after_open[..last_nl]
                } else {
                    after_open
                }
            } else {
                let last_line = after_open.trim();
                if last_line.len() >= 3 && last_line.bytes().all(|b| b == b'`') {
                    ""
                } else {
                    after_open
                }
            }
        } else {
            ""
        };
        return crate::types::BlockKind::CodeBlock {
            language,
            code: body.to_string(),
        };
    }
    let first_line = rendered.lines().next().unwrap_or_default();
    let hashes = first_line.bytes().take_while(|&b| b == b'#').count();
    if (1..=3).contains(&hashes) && first_line.as_bytes().get(hashes) == Some(&b' ') {
        return crate::types::BlockKind::Heading {
            level: hashes as u8,
        };
    }
    if first_line.starts_with("> ") || first_line == ">" {
        return crate::types::BlockKind::Quote;
    }
    crate::types::BlockKind::Paragraph
}

pub fn split_body_and_prop_lines(content: &str) -> (String, Vec<(String, String)>) {
    let mut body_lines: Vec<&str> = Vec::new();
    let mut props: Vec<(String, String)> = Vec::new();
    let mut in_fence = false;
    let mut fence_ticks = 0usize;

    for line in content.split('\n') {
        let trimmed = line.trim();
        if !in_fence && trimmed.starts_with("```") {
            in_fence = true;
            fence_ticks = trimmed.bytes().take_while(|&b| b == b'`').count();
            body_lines.push(line);
            continue;
        }
        if in_fence {
            body_lines.push(line);
            let ticks = trimmed.bytes().take_while(|&b| b == b'`').count();
            if ticks >= fence_ticks && trimmed.bytes().all(|b| b == b'`') {
                in_fence = false;
            }
            continue;
        }
        if let Some((key, value)) = parse_prop_line(line) {
            props.push((key.to_string(), value.to_string()));
        } else {
            body_lines.push(line);
        }
    }

    while body_lines.last().is_some_and(|l| l.is_empty()) {
        body_lines.pop();
    }
    (body_lines.join("\n"), props)
}

pub fn find_case_insensitive_matches(text: &str, query: &str) -> Vec<(u32, u32)> {
    let needle: Vec<char> = query.to_lowercase().chars().collect();
    if needle.is_empty() {
        return Vec::new();
    }
    let mut folded: Vec<char> = Vec::with_capacity(text.len());
    let mut orig_index: Vec<u32> = Vec::with_capacity(text.len());
    for (scalar_idx, ch) in text.chars().enumerate() {
        for lower in ch.to_lowercase() {
            folded.push(lower);
            orig_index.push(scalar_idx as u32);
        }
    }
    let mut matches = Vec::new();
    if needle.len() > folded.len() {
        return matches;
    }
    let mut i = 0;
    while i + needle.len() <= folded.len() {
        if folded[i..i + needle.len()] == needle[..] {
            let start = orig_index[i];
            let end = if i + needle.len() < orig_index.len() {
                orig_index[i + needle.len()]
            } else {
                text.chars().count() as u32
            };
            matches.push((start, end.saturating_sub(start)));
            i += needle.len();
        } else {
            i += 1;
        }
    }
    matches
}

pub fn find_unlinked_match(rendered: &str, title: &str) -> Option<(usize, usize, u32, u32)> {
    let needle: Vec<char> = title.to_lowercase().chars().collect();
    if needle.is_empty() {
        return None;
    }
    for segment in prose_segments(rendered) {
        if let Some((start, end)) = word_match(segment, &needle) {
            let base = offset_within(rendered, segment);
            let byte_start = base + start;
            let byte_end = base + end;
            let scalar_start = rendered[..byte_start].chars().count() as u32;
            let scalar_len = rendered[byte_start..byte_end].chars().count() as u32;
            return Some((byte_start, byte_end, scalar_start, scalar_len));
        }
    }
    None
}

fn prose_segments(content: &str) -> Vec<&str> {
    let mut out = Vec::new();
    for span in tokenize(content) {
        let Span::Text(text) = span else { continue };
        for token in tokenize_inline(text) {
            match token {
                InlineToken::Text(t) => out.push(t),
                InlineToken::Bold { inner, .. }
                | InlineToken::Italic { inner, .. }
                | InlineToken::Strike { inner, .. }
                | InlineToken::Highlight { inner, .. } => out.push(inner),
                InlineToken::ExternalLink { .. } => {}
            }
        }
    }
    out
}

fn offset_within(outer: &str, inner: &str) -> usize {
    inner.as_ptr() as usize - outer.as_ptr() as usize
}

fn word_match(segment: &str, needle: &[char]) -> Option<(usize, usize)> {
    let chars: Vec<(usize, char)> = segment.char_indices().collect();
    let mut folded: Vec<char> = Vec::with_capacity(chars.len());
    let mut origin: Vec<usize> = Vec::with_capacity(chars.len());
    for (index, &(_, ch)) in chars.iter().enumerate() {
        for lower in ch.to_lowercase() {
            folded.push(lower);
            origin.push(index);
        }
    }
    if needle.len() > folded.len() {
        return None;
    }
    for i in 0..=folded.len() - needle.len() {
        if folded[i..i + needle.len()] != needle[..] {
            continue;
        }
        let start = origin[i];
        let end = origin.get(i + needle.len()).copied().unwrap_or(chars.len());
        let left_ok = start == 0 || !chars[start - 1].1.is_alphanumeric();
        let right_ok = end == chars.len() || !chars[end].1.is_alphanumeric();
        if left_ok && right_ok {
            let byte_end = chars.get(end).map_or(segment.len(), |&(b, _)| b);
            return Some((chars[start].0, byte_end));
        }
    }
    None
}
