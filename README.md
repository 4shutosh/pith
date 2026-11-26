# pith

A local-first, **agent-native block outliner** built for speed.

`pith` pairs a Logseq-style outliner (nested blocks, daily journals, `[[page links]]`, `((block refs))`, `#tags`, backlinks, tasks) with a single **Rust + SQLite/FTS5 core**, native platform UIs over UniFFI, and a first-class **CLI** (with MCP planned) for AI agents.

> **Status:** Active early development. The Rust core, CLI, and macOS app work locally; format and APIs are still evolving.

## Why pith

- **Blocks all the way down.** Every block has a stable UUIDv7 ID, fractional ordering, and live backlinks—ideal for structured thinking without flat-file friction.
- **Fast by design.** One SQLite + FTS5 trigram store, native UIs (SwiftUI + AppKit on macOS today, Jetpack Compose on Android planned), and latency budgets checked by a benchmark.
- **Agent-native from day one.** Agents read compact outlines and make version-checked, block-level edits via the CLI (MCP planned)—never rewriting whole files blindly. Every edit is **attributed by actor and reversible with persistent undo**.
- **Local-first, zero lock-in.** Works offline out of the box with no daemon, no account, and Logseq-compatible Markdown import/export planned for lossless portability.

## Quick Start

Requires [Rust](https://rustup.rs) (and Xcode Command Line Tools on macOS for the native app).

### CLI

```sh
cargo install --path crates/cli

export PITH_DB=/tmp/pith-play.db
pith journal "Kickoff for [[Pith]] #planning"
pith show Pith
pith search kickoff
pith history
```

Run `pith example` for more commands, or pass `--actor agent:claude --origin agent --output json` for agent workflows.

### macOS App

```sh
./scripts/build-swift.sh
cd apps/macos && PITH_DB=/tmp/pith-play.db swift run PithMacApp
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for tests, benchmarks, and build details.

## Architecture

```
            ┌────────────── pith-core (Rust) ──────────────┐
            │  SQLite · FTS5 · ops & inverses · undo log   │
            └──┬──────────────┬──────────────┬────────────┬┘
            pith-cli        macOS          Android      Sync
             (+ MCP)   (Swift/AppKit)     (Compose)   (planned)
                         via UniFFI      via UniFFI
```

- **Single source of truth:** Relational SQLite (`pages`, `blocks`, `refs`, `props`, `tasks`, FTS5) in WAL mode—no background daemon.
- **One write path:** Every mutation (UI, CLI, undo, future sync) goes through `apply_ops(ops, TxMeta)`, which computes exact inverses and updates derived indexes in the same transaction.
- **Core-owned editor logic:** Splitting, merging, indenting, bulk block operations, link identity preservation, autocomplete, and display tokenization live in `pith-core`; native apps stay thin.
- **Persistent, actor-scoped undo:** History lives in SQLite, survives restarts, and lets you revert human or agent sessions cleanly.

Full design notes live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Performance Budgets

| Interaction | Target | Checked by |
| :--- | :--- | :--- |
| Local capture saved | `< 16 ms` | `pith-bench --check` (100k blocks) |
| Search over 100k blocks | `< 30 ms` | `pith-bench --check` |
| Backlinks for a page | `< 10 ms` | `pith-bench --check` |
| Cold start → typing | `< 300 ms` | not yet measured |
| Journal scroll | `60 / 120 fps` | not yet measured |

Run the checked budgets with `cargo run --release -p pith-bench -- --check`.

## What Works Today

- **Core & CLI (`pith`):** SQLite + FTS5 trigram search, backlinks, tasks, properties, actor-scoped persistent undo, and a 100k-block benchmark.
- **macOS app:** Native SwiftUI + AppKit outliner with in-place editing, inline formatting, `[[`/`#`/`((`/`/` autocomplete, multi-block selection, journals, favorites, and light/dark themes.

**Planned:** Logseq Markdown import/export, MCP server, Android app, and offline-first sync.

## License

[AGPL-3.0-only](LICENSE). You may use, modify, and share pith, provided any distributed or network-hosted version publishes its complete source under the same license.
