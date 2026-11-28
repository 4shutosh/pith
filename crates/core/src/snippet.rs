use serde::Serialize;

const MAX_LINE_CHARS: usize = 200;
const CHARS_BEFORE_MATCH: usize = 60;
const MAX_CRUMB_CHARS: usize = 40;
const ELLIPSIS: char = '…';

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Segment {
    pub text: String,
    pub highlighted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LineMatch {
    pub segments: Vec<Segment>,
    pub cursor: usize,
    pub line: String,
}

pub fn matching_lines(content: &str, query: &str) -> Vec<LineMatch> {
    let tokens = query_tokens(query);
    let mut matches = Vec::new();
    let mut first_non_empty: Option<LineMatch> = None;
    let mut line_start = 0;

    for raw_line in content.split('\n') {
        let line = raw_line.trim();
        if !line.is_empty() {
            let leading = raw_line.chars().count() - raw_line.trim_start().chars().count();
            let chars: Vec<char> = line.chars().collect();
            match match_marks(&chars, &tokens)
                .iter()
                .position(|&marked| marked)
            {
                Some(first_match) => matches.push(LineMatch {
                    segments: highlight(&clip_around(&chars, first_match), query),
                    cursor: line_start + leading + first_match,
                    line: line.to_string(),
                }),
                None if first_non_empty.is_none() => {
                    first_non_empty = Some(LineMatch {
                        segments: highlight(&clip_around(&chars, 0), query),
                        cursor: line_start + leading,
                        line: line.to_string(),
                    });
                }
                None => {}
            }
        }
        line_start += raw_line.chars().count() + 1;
    }

    if matches.is_empty() {
        matches.extend(first_non_empty);
    }
    matches
}

pub fn highlight(text: &str, query: &str) -> Vec<Segment> {
    let tokens = query_tokens(query);
    let chars: Vec<char> = text.chars().collect();
    let marks = match_marks(&chars, &tokens);

    let mut segments: Vec<Segment> = Vec::new();
    for (ch, highlighted) in chars.into_iter().zip(marks) {
        match segments.last_mut() {
            Some(last) if last.highlighted == highlighted => last.text.push(ch),
            _ => segments.push(Segment {
                text: ch.to_string(),
                highlighted,
            }),
        }
    }
    segments
}

pub fn crumb(content: &str) -> String {
    let first_line = content
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    truncate(first_line, MAX_CRUMB_CHARS)
}

pub fn without_link_brackets(segments: Vec<Segment>) -> Vec<Segment> {
    let mut out: Vec<Segment> = Vec::new();
    for segment in segments {
        let text = segment.text.replace("[[", "").replace("]]", "");
        if text.is_empty() {
            continue;
        }
        match out.last_mut() {
            Some(last) if last.highlighted == segment.highlighted => last.text.push_str(&text),
            _ => out.push(Segment {
                text,
                highlighted: segment.highlighted,
            }),
        }
    }
    out
}

pub fn plain(segments: &[Segment]) -> String {
    segments.iter().map(|s| s.text.as_str()).collect()
}

fn query_tokens(query: &str) -> Vec<Vec<char>> {
    query
        .split_whitespace()
        .map(|token| token.chars().map(fold).collect())
        .collect()
}

fn fold(ch: char) -> char {
    ch.to_lowercase().next().unwrap_or(ch)
}

fn match_marks(chars: &[char], tokens: &[Vec<char>]) -> Vec<bool> {
    let folded: Vec<char> = chars.iter().copied().map(fold).collect();
    let mut marks = vec![false; chars.len()];
    for token in tokens {
        if token.is_empty() || token.len() > folded.len() {
            continue;
        }
        for start in 0..=folded.len() - token.len() {
            if folded[start..start + token.len()] == token[..] {
                marks[start..start + token.len()].fill(true);
            }
        }
    }
    marks
}

fn clip_around(chars: &[char], focus: usize) -> String {
    if chars.len() <= MAX_LINE_CHARS {
        return chars.iter().collect();
    }
    let start = focus.saturating_sub(CHARS_BEFORE_MATCH);
    let end = (start + MAX_LINE_CHARS).min(chars.len());

    let mut out = String::new();
    if start > 0 {
        out.push(ELLIPSIS);
    }
    out.extend(&chars[start..end]);
    if end < chars.len() {
        out.push(ELLIPSIS);
    }
    out
}

fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max_chars).collect();
    out.push(ELLIPSIS);
    out
}
