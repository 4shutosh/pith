# pith — Build Plan

Sequenced milestones for building `pith`. Architecture and invariants live in [ARCHITECTURE.md](./ARCHITECTURE.md).

Crates are added only as their milestone arrives (no empty placeholder crates upfront).

## Phase 1: Core + CLI + MCP

| Milestone | Deliverable | Done when |
| :--- | :--- | :--- |
| **M0** Core skeleton | Cargo workspace (`pith-core`), schema + migrations, `apply_ops` with the canonical op set, inverses, `txns`/`ops`/`txn_blocks` log, soft delete | Property tests: random op sequences keep tree invariants; `apply(op)` then `apply(inverse)` restores original state |
| **M1** Parser + indexes | Inline parser (`[[ ]]`, `(( ))`, `#tag`, `key::`, tasks), `refs`/`props`/`tasks` derivation, FTS5 (`unicode61` vs `trigram` benchmarked), backlinks, `pith-bench` | `pith-bench` on 100k blocks passes in CI: capture `< 16 ms`, search `< 30 ms`, backlinks `< 10 ms` |
| **M2** CLI | `pith-cli`: `search`, `show`, `journal`, `insert`, `update`, `move`, `rm`, `history`, `undo`, `--output human\|json`, short suffix IDs | End-to-end tests pass on a fixture graph |
| **M3** MCP | `pith-mcp` (`rmcp`, stdio) over the same core API; outline output; `dry_run`; version checks | An AI client can run a session of edits and revert it in one `undo` call |
| **M4** Import / export | `pith-md`: Logseq importer, Markdown exporter/mirror | Round-trip test on a real graph preserves block IDs, tree structure, links, and properties |
| **M5** UniFFI bridge | `pith-ffi`: windowed tree reads, `apply_ops`, change cursor | Android editor prototype can start |

## Later Phases

- **Phase 2 — Android Editor Prototype:** Jetpack Compose outliner hitting 120fps scrolling and IME/focus transitions across blocks, plus editor typing debounce & undo coalescing.
- **Phase 3 — Android Daily Driver:** Journals, pages, backlinks, search, quick capture (widget + share sheet).
- **Phase 4 — Sync + macOS:** Multi-device sync (Loro CRDT vs. server-rebase) and native SwiftUI macOS app.
