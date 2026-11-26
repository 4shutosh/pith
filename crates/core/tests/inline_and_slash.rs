use anyhow::{Context, Result};
use pith_core::parser::{
    InlineFormat, InlineToken, SlashClock, SlashCommand, apply_slash_command, slash_commands,
    toggle_inline_format, tokenize_inline,
};
use pith_core::{Id, Op, Origin, Store, TxMeta, order};

const CLOCK: SlashClock<'static> = SlashClock {
    today: "2026-11-26",
    tomorrow: "2026-11-27",
    yesterday: "2026-11-25",
    time: "14:05",
};

#[test]
fn text_that_only_looks_like_formatting_stays_plain() {
    for text in [
        "2 * 3 * 4",
        "a ** b ** c",
        "** not bold**",
        "== x==",
        "~~~~",
        "[label] (mailto:a@b.c)",
        "[label](ftp://x.y)",
        "[label](mailto:has space)",
        "snake_case and a*b",
        "http://",
    ] {
        assert_eq!(
            tokenize_inline(text),
            vec![InlineToken::Text(text)],
            "{text}"
        );
    }
}

#[test]
fn autolinks_stop_before_trailing_punctuation_and_require_a_boundary() {
    assert_eq!(
        tokenize_inline("see (https://pith.app/docs)."),
        vec![
            InlineToken::Text("see ("),
            InlineToken::ExternalLink {
                label: "https://pith.app/docs",
                url: "https://pith.app/docs",
                raw: "https://pith.app/docs",
            },
            InlineToken::Text(")."),
        ]
    );
    assert_eq!(
        tokenize_inline("xhttps://a.b"),
        vec![InlineToken::Text("xhttps://a.b")]
    );
}

#[test]
fn toggling_formats_wraps_unwraps_and_inserts_empty_pairs() {
    assert_eq!(
        toggle_inline_format("ab", 1, 1, InlineFormat::Italic),
        ("a**b".to_string(), 2, 2)
    );
    assert_eq!(
        toggle_inline_format("x ==hi== y", 2, 8, InlineFormat::Highlight),
        ("x hi y".to_string(), 2, 4)
    );
    assert_eq!(
        toggle_inline_format("é ~~ü~~", 4, 5, InlineFormat::Strike),
        ("é ü".to_string(), 2, 3)
    );
}

#[test]
fn slash_commands_filter_by_label() {
    assert_eq!(
        slash_commands("to"),
        vec![
            SlashCommand::Todo,
            SlashCommand::Today,
            SlashCommand::Tomorrow
        ]
    );
    assert_eq!(slash_commands("").len(), 8);
    assert!(slash_commands("zzz").is_empty());
}

#[test]
fn slash_insertions_replace_the_command_and_place_the_caret() {
    assert_eq!(
        apply_slash_command("due /tom later", 8, SlashCommand::Tomorrow, &CLOCK),
        Some(("due [[2026-11-27]] later".to_string(), 18))
    );
    assert_eq!(
        apply_slash_command("at /time", 8, SlashCommand::CurrentTime, &CLOCK),
        Some(("at 14:05".to_string(), 8))
    );
    assert_eq!(
        apply_slash_command("/code", 5, SlashCommand::CodeBlock, &CLOCK),
        Some(("```\n\n```".to_string(), 4))
    );
    assert_eq!(
        apply_slash_command("no command", 3, SlashCommand::Today, &CLOCK),
        None
    );
}

#[test]
fn slash_task_commands_set_the_keyword_and_keep_the_caret_in_the_body() {
    assert_eq!(
        apply_slash_command("/todo ship it", 5, SlashCommand::Todo, &CLOCK),
        Some(("TODO ship it".to_string(), 5))
    );
    assert_eq!(
        apply_slash_command("ship it /done", 13, SlashCommand::Done, &CLOCK),
        Some(("DONE ship it ".to_string(), 13))
    );
    assert_eq!(
        apply_slash_command("TODO ship /doing", 16, SlashCommand::Doing, &CLOCK),
        Some(("DOING ship ".to_string(), 11))
    );
}

#[test]
fn running_a_slash_command_saves_the_block_and_links_the_date() -> Result<()> {
    let mut store = Store::open_in_memory()?;
    let meta = TxMeta::new(Origin::User, "me", "setup");
    let page = Id::new();
    let block = Id::new();
    store.apply_ops(
        &[
            Op::CreatePage {
                id: page,
                title: "Home".to_string(),
                journal_day: None,
                document_mode: false,
            },
            Op::InsertBlock {
                id: block,
                page_id: page,
                parent_id: None,
                order_key: order::between(None, None)?,
                content: "x".to_string(),
            },
        ],
        &meta,
    )?;
    let version = store.get_block(block)?.context("block")?.version;
    let outcome = store
        .run_slash_command(
            block,
            version,
            "due /tod",
            8,
            SlashCommand::Today,
            &CLOCK,
            &meta,
        )?
        .context("applied")?;
    assert_eq!(outcome.cursor, Some(18));
    let row = store.block_row(block)?.context("row")?;
    assert_eq!(row.rendered_content, "due [[2026-11-26]]");
    let linked = store
        .get_page_by_title("2026-11-26")?
        .context("date page")?;
    assert_eq!(store.backlinks(linked.id)?.len(), 1);
    Ok(())
}
