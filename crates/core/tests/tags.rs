use anyhow::{Context, Result};
use pith_core::parser::{RefTarget, Span, tokenize};
use pith_core::{Id, Op, Origin, Store, TxMeta, order};

fn tags(content: &str) -> Vec<String> {
    tokenize(content)
        .into_iter()
        .filter_map(|span| match span {
            Span::SimpleTag {
                target: RefTarget::Title(title),
                ..
            } => Some(title),
            _ => None,
        })
        .collect()
}

#[test]
fn accented_letters_belong_to_the_tag() {
    assert_eq!(tags("#café au lait"), vec!["café"]);
}

#[test]
fn non_latin_scripts_form_tags() {
    assert_eq!(tags("read #日本語 and #русский"), vec!["日本語", "русский"]);
}

#[test]
fn decomposed_accents_stay_in_the_tag() {
    assert_eq!(tags("#cafe\u{301} note"), vec!["cafe\u{301}"]);
}

#[test]
fn trailing_punctuation_ends_the_tag() {
    assert_eq!(
        tags("see #rust. or #go, maybe #zig! #c++?"),
        vec!["rust", "go", "zig", "c++"]
    );
}

#[test]
fn unicode_punctuation_ends_the_tag() {
    assert_eq!(
        tags("#日本語。次 and “#quote” too"),
        vec!["日本語", "quote"]
    );
    assert_eq!(tags("say \"#hi\" and '#yo'"), vec!["hi", "yo"]);
}

#[test]
fn a_hash_needs_a_boundary_before_it() {
    assert_eq!(
        tags("café#nope https://x.com/#anchor"),
        Vec::<String>::new()
    );
    assert_eq!(tags("a\u{a0}#nbsp (#paren)"), vec!["nbsp", "paren"]);
}

#[test]
fn headings_and_double_hashes_are_not_tags() {
    assert_eq!(tags("# Heading\n## Sub"), Vec::<String>::new());
}

#[test]
fn a_unicode_tag_links_the_whole_word_and_renders_back() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let page = Id::new();
    let block = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Notes".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block,
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "Morning #café visit".to_string(),
            },
        ],
        &TxMeta::new(Origin::User, "me", "seed"),
    )?;

    let cafe = store.get_page_by_title("café")?.context("café page")?;
    assert!(store.get_page_by_title("caf")?.is_none());
    assert_eq!(store.backlinks(cafe.id)?.len(), 1);

    let stored = store.get_block(block)?.context("block")?;
    assert_eq!(stored.content, format!("Morning #[[{}]] visit", cafe.id));
    assert_eq!(
        store.render_content(&stored.content)?,
        "Morning #café visit"
    );
    store.check_invariants()?;
    Ok(())
}
