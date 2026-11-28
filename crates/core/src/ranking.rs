use crate::id::Id;

const DAY_MILLIS: i64 = 86_400_000;
const PAGE_TITLE_BONUS: u32 = 15;
const MAX_LINK_BONUS: u32 = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MatchQuality {
    Substring,
    AllWordStarts,
    WordStart,
    Prefix,
    Exact,
}

impl MatchQuality {
    pub fn points(self) -> u32 {
        match self {
            Self::Exact => 100,
            Self::Prefix => 80,
            Self::WordStart => 60,
            Self::AllWordStarts => 50,
            Self::Substring => 20,
        }
    }
}

pub fn match_quality(text: &str, query: &str) -> Option<MatchQuality> {
    let text = normalize(text);
    let query = normalize(query);
    if query.is_empty() || text.is_empty() {
        return None;
    }
    if text == query {
        return Some(MatchQuality::Exact);
    }
    if text.starts_with(&query) {
        return Some(MatchQuality::Prefix);
    }
    if starts_a_word(&text, &query) {
        return Some(MatchQuality::WordStart);
    }
    let tokens: Vec<&str> = query.split(' ').collect();
    if tokens.len() > 1 && tokens.iter().all(|token| starts_a_word(&text, token)) {
        return Some(MatchQuality::AllWordStarts);
    }
    if tokens.iter().all(|token| text.contains(token)) {
        return Some(MatchQuality::Substring);
    }
    None
}

pub fn recency_points(updated_at: i64, now: i64) -> u32 {
    let age = now.saturating_sub(updated_at);
    if age <= DAY_MILLIS {
        6
    } else if age <= 7 * DAY_MILLIS {
        4
    } else if age <= 30 * DAY_MILLIS {
        2
    } else {
        0
    }
}

pub fn page_score(quality: MatchQuality, backlinks: u32, updated_at: i64, now: i64) -> u32 {
    quality.points()
        + PAGE_TITLE_BONUS
        + backlinks.min(MAX_LINK_BONUS)
        + recency_points(updated_at, now)
}

pub fn block_score(quality: MatchQuality, updated_at: i64, now: i64) -> u32 {
    quality.points() + recency_points(updated_at, now)
}

pub fn command_score(title: &str, keywords: &str, query: &str) -> Option<u32> {
    let quality = match_quality(title, query).or_else(|| {
        match_quality(&format!("{title} {keywords}"), query)
            .map(|quality| quality.min(MatchQuality::AllWordStarts))
    })?;
    Some(quality.points() + PAGE_TITLE_BONUS)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RankKey {
    pub score: u32,
    pub is_page: bool,
    pub text_len: usize,
    pub text_lower: String,
    pub id: Id,
    pub cursor: u32,
}

impl RankKey {
    pub fn order(&self, other: &Self) -> std::cmp::Ordering {
        other
            .score
            .cmp(&self.score)
            .then(other.is_page.cmp(&self.is_page))
            .then(self.text_len.cmp(&other.text_len))
            .then(self.text_lower.cmp(&other.text_lower))
            .then(self.id.cmp(&other.id))
            .then(self.cursor.cmp(&other.cursor))
    }
}

fn normalize(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn starts_a_word(text: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    let mut from = 0;
    while let Some(found) = text[from..].find(needle) {
        let at = from + found;
        let boundary = text[..at]
            .chars()
            .next_back()
            .is_none_or(|before| !before.is_alphanumeric());
        if boundary {
            return true;
        }
        from = at + text[at..].chars().next().map_or(1, char::len_utf8);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quality_orders_exact_prefix_word_start_and_substring() {
        assert_eq!(
            match_quality("Atomic Habits", "atomic habits"),
            Some(MatchQuality::Exact)
        );
        assert_eq!(
            match_quality("Atomic Habits", "atom"),
            Some(MatchQuality::Prefix)
        );
        assert_eq!(
            match_quality("Reading Atomic Habits", "habit"),
            Some(MatchQuality::WordStart)
        );
        assert_eq!(
            match_quality("habits of atomic people", "atomic habit"),
            Some(MatchQuality::AllWordStarts)
        );
        assert_eq!(
            match_quality("Inhabitants", "habit"),
            Some(MatchQuality::Substring)
        );
        assert_eq!(match_quality("Judo", "jeet"), None);
        assert_eq!(
            match_quality("  Spaced   Out  ", "spaced out"),
            Some(MatchQuality::Exact)
        );
        assert_eq!(
            match_quality("Über Café", "café"),
            Some(MatchQuality::WordStart)
        );
        assert_eq!(match_quality("anything", "  "), None);
    }

    #[test]
    fn recency_steps_down_with_age() {
        let now = 100 * DAY_MILLIS;
        assert_eq!(recency_points(now - DAY_MILLIS / 2, now), 6);
        assert_eq!(recency_points(now - 3 * DAY_MILLIS, now), 4);
        assert_eq!(recency_points(now - 20 * DAY_MILLIS, now), 2);
        assert_eq!(recency_points(now - 40 * DAY_MILLIS, now), 0);
    }

    #[test]
    fn a_page_title_outranks_the_same_match_in_a_block_and_links_are_capped() {
        let now = 100 * DAY_MILLIS;
        let old = 0;
        assert_eq!(
            page_score(MatchQuality::WordStart, 3, old, now),
            60 + 15 + 3
        );
        assert_eq!(
            page_score(MatchQuality::WordStart, 50, old, now),
            60 + 15 + 10
        );
        assert_eq!(block_score(MatchQuality::WordStart, old, now), 60);
        assert!(
            block_score(MatchQuality::Exact, old, now)
                > page_score(MatchQuality::Substring, 10, now, now)
        );
    }

    #[test]
    fn commands_score_like_titles_and_keywords_never_beat_a_title_word() {
        assert_eq!(
            command_score("Toggle Light / Dark", "theme appearance", "dark"),
            Some(75)
        );
        assert_eq!(
            command_score("Go to All Pages", "list browse", "go pages"),
            Some(65)
        );
        assert_eq!(
            command_score("Toggle Light / Dark", "theme appearance", "theme"),
            Some(65)
        );
        assert_eq!(command_score("Settings", "preferences", "pref"), Some(65));
        assert_eq!(command_score("Settings", "preferences", "zzz"), None);
    }
}
