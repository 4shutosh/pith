# pith

An open-source, local-first, **agent-native outliner** built for speed.

`pith` combines a Logseq-style block outliner (bullets, nesting, daily journals, `[[page links]]`, `((block refs))`, backlinks) with a single **Rust + SQLite/FTS5 core**, native platform UIs, and first-class **CLI + MCP** support for AI agents.

> **Status:** Early development.

---

## Why pith

- **Outliners fit structured thinking.** Nested blocks, stable IDs, and backlinks work better for personal knowledge than flat documents.
- **Speed is non-negotiable.** Existing outliners are often slow on mobile and large graphs. `pith` puts performance budgets in CI and uses native UI on every platform.
- **Built for AI agents from day one.** Most notes apps force agents to rewrite whole files blindly. `pith` exposes a CLI and MCP server for precise, block-level reads and edits — with every agent edit **attributed and reversible**.
- **Simple and local-first.** Works completely offline, exports cleanly to Logseq-compatible Markdown, and avoids plugin/whiteboard bloat in v1.

---

## Principles

1. **Speed is a feature** — hard latency budgets tested in CI.
2. **The block is the unit** — stable block IDs forever.
3. **Local-first, zero lock-in** — offline by default, plain-text Markdown import/export always available.
4. **Native UI per platform** — Jetpack Compose on Android, SwiftUI on macOS (via UniFFI). No custom cross-platform UI framework.
5. **Agents as first-class citizens** — structured block edits, clear attribution, instant undo.
6. **One-command builds** — no fragile multi-hour toolchains.

---

## Architecture

```
            ┌──────────── Rust core ────────────┐
            │ blocks · SQLite · FTS5 · sync     │
            └──┬──────────┬──────────┬─────────┬┘
           CLI + MCP   Android     macOS     Sync server
           (Rust)     (Compose)  (SwiftUI)   (Rust)
                      via UniFFI via UniFFI
```

- **Storage:** SQLite for the block tree, references, and properties, paired with an FTS5 full-text search index.
- **Agent Layer:** Rust CLI (`pith`) + MCP server exposing search, read, daily journal append, and block-level edit/move/undo with edit attribution.
- **Editor:** One live text field per active block; inactive blocks render as styled text with native cursor/focus navigation across blocks.
- **Sync (planned):** Offline-first multi-device sync with a self-hostable server. The sync model (CRDT relay vs. server rebase) is still open — see [ARCHITECTURE §6](docs/ARCHITECTURE.md#6-sync).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design. To build and run it, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

---

## Performance Budgets

| Interaction | Target |
| :--- | :--- |
| Cold start → typing | `< 300 ms` |
| Local capture saved | `< 16 ms` |
| Search over 100k blocks | `< 30 ms` |
| Backlinks for a page | `< 10 ms` |
| Journal scroll | `60 / 120 fps` |

---

## Scope (v1)

**In scope:**
- Blocks: bullets, nesting, collapse, drag/indent/outdent, tasks, properties (`key:: value`).
- Pages, daily journals, `[[page links]]`, `((block refs))`, `#tags`, backlinks.
- Plain-text paragraph blocks + page-level document mode for long-form writing.
- Fast full-text search (FTS5).
- Logseq Markdown graph import (preserving block IDs) and export.
- CLI + MCP server with attributed, reversible block edits.
- Native Android app with quick capture (widget + share sheet).

**Explicitly out of scope for v1:**
- Plugin system, query language, whiteboards, flashcards, PDF annotation, themes marketplace, web publishing, real-time multiplayer.

---

## Roadmap

1. **Core + CLI + MCP** — Rust core, SQLite/FTS5, Logseq importer/exporter, CLI & MCP server with attributed, reversible agent edits.
2. **Android Editor Prototype** — UniFFI bridge + Jetpack Compose outliner editor hitting 120fps and IME/focus edge cases.
3. **Android Daily Driver** — Journals, pages, backlinks, search, quick capture.
4. **Sync + macOS** — Multi-device sync server and native SwiftUI macOS app.

---

## License

[AGPL-3.0-only](LICENSE). You may use, modify and share pith, but any distributed or network-hosted version, modified or not, must publish its complete source under the same license.
