# Research: Logseq DB version

Notes from reading the database-based Logseq codebase, which informed [pith's architecture](../ARCHITECTURE.md).

- **Source:** local checkout `personal/logseq` @ `b43bcbcc38` (Nov 2026)
- **Paths:** relative to that repo
- **Caveat:** this is a snapshot; Logseq will change

---

## Storage and data model

- **Storage is a key-value table of serialized blobs, not relational tables.**
  - The graph DB is one table, `kvs(addr INTEGER PK, content TEXT, addresses JSON)`, holding the B-tree nodes of a forked DataScript as Transit blobs (`deps/db/src/logseq/db/common/sqlite.cljs`, `src/main/frontend/worker/db_core.cljs`).
  - Each transaction rewrites a "tail" row; index nodes are flushed when the tail fills; a separate GC removes unreachable nodes (`deps/db/src/logseq/db/sqlite/gc.cljs`).
  - Consequence: the data can't be queried with SQL, and every read goes through DataScript in a worker.
  - Logseq has since moved sync client ops out of `kvs` into SQL tables because of CPU and space cost (`docs/adr/0015-*`).
- **Separate SQLite files per graph:** the graph, search, and client-ops.
- **Schema** (`deps/db/src/logseq/db/frontend/schema.cljs`):
  - Pages and blocks are both entities. Journals are pages with `:block/journal-day` and deterministic UUIDs.
  - Shapes are validated with Malli (`malli_schema.cljs`).
- **Properties:**
  - Properties are entities and also DataScript attributes (`:user.property/<name>-<nanoid>`), with typed values (`property/type.cljs`).
  - Most values are separate entities. Closed values are child blocks.
  - Classes are pages with `extends`.
- **Ordering:** fractional indexing (`deps/db/src/logseq/db/common/order.cljs`). There is repair code that sorts by UUID so peers generate the same keys.
- **Refs:**
  - Content stores UUIDs (`[[uuid]]`, `#[[uuid]]`), converted back to titles for display (`deps/db/src/logseq/db/frontend/content.cljs`).
  - `:block/refs` is rebuilt after every transaction (`src/main/frontend/worker/pipeline.cljs`).
  - Backlinks use the reverse index, with no separate table. Path-refs are no longer stored.
- **Search** (`src/main/frontend/worker/search.cljs`):
  - FTS5 with `trigram` in a separate SQLite file, kept in sync by triggers keyed by rowid.
  - It indexes the rendered title plus parent context, and skips blocks over 10k chars.
  - Queries merge prefix, exact, FTS, `LIKE` (≤2 chars), fuzzy and optional vector results.
  - `search_benchmark.cljs` measures result quality, not latency.
- **Markdown mirror** (`docs/adr/0016-markdown-mirror.md`, `worker/markdown_mirror.cljs`):
  - One-way, Electron only.
  - Incremental, debounced and atomic, with stable filenames and `id::` lines.
  - The mirror is ignored by import.

## Outliner ops, transactions, undo

- **Op schema** (`deps/outliner/src/logseq/outliner/op.cljs`):
  - About 35 ops; block references use UUIDs only.
  - The entry point is `apply-ops!`, which runs a batch on a temporary connection and then commits once.
  - A raw `:transact` escape hatch and about 15 skip flags still exist.
- **Pipeline:**
  - Dry-run, then a pure derive step (refs, `:block/tx-id`, created-by), then Malli validation, then commit.
  - Listeners for checksum, op log, search, mirror and render delta run after commit; their failures don't roll back.
- **Undo** (`worker/undo_redo.cljs`, `deps/outliner/.../op/construct.cljc`):
  - Forward and inverse semantic ops are derived *after the fact* from db-before/db-after (1,718 lines), with a raw reversed-tx fallback.
  - The stack is in memory: 250 entries per repo, no keystroke coalescing.
  - It is cleared on unexpected errors and whenever remote txs arrive while local changes are pending.
  - Recent commits are mostly undo and rebase fixes.
- **Deletes:** block delete is a hard retract (except cuts containing assets), while pages go to a recycle bin with 30-day GC. Undo of delete must rebuild subtrees.
- **Attribution:**
  - `created-by-ref` is set only when logged in, and records the human.
  - There is no `updated-by` and no agent/human distinction.
- **UI updates:**
  - The DB lives only in the worker.
  - The UI receives render deltas plus explicit affected keys.
  - Typing debounces at 450 ms with an IME guard and protection against stale echoes.

## Sync

- **Not a CRDT.** It is a server-authoritative rebase.
  - Server: a Cloudflare Durable Object per graph holds the full DB, re-validates each tx and assigns a monotonic `t`; stale `t-before` is rejected (`deps/db-sync`).
  - Client: undoes pending ops, applies remote ones, replays its canonical ops (ADR 0010), then commits once.
- **Pending queue:** a `client_ops` table with one row per user action, holding forward and inverse ops (ADR 0015).
- **Conflicts:**
  - Effectively last-writer-wins by server order.
  - Overwritten remote text is saved to `sync_conflicts`.
  - Move cycles are prevented by a no-op guard.
  - Duplicate order keys are regenerated.
- **E2EE:** only `:block/title`/`:block/name` are encrypted, because the server must validate structure (ADR 0003).
- **Snapshots:** raw `kvs` rows are uploaded and downloaded, then replayed schema-first (ADR 0014).
- **Recurring failures** (`docs/sync/failed-cases.md`):
  - the pending queue changing mid-apply
  - inverse tx-data narrower than the subtree, leaving orphaned children
  - failed txs not rolled back
  - stale checksums
  - stuck after suspend
- **Testing:** ADR 0008 adds multi-client simulation and replay tests built from real logs, after bugs kept escaping unit tests.

## CLI and agent surfaces

- **CLI:** OCaml compiled to JS with Melange (`cli/`).
  - It never opens SQLite; it talks to a per-graph `db-worker-node` daemon over HTTP (`/v1/invoke`, `/v1/events`).
  - Single-writer lock via `lock.sqlite`; the app and the CLI share the daemon.
  - Output: `--output human|json|edn` with error codes; `upsert --blocks <markdown>` with `--dry-run`; soft delete by default; ships an agent skill file.
  - Human output uses integer `db/id` handles.
- **Desktop MCP** (`src/electron/electron/mcp_server.cljs`):
  - Six coarse tools, relayed through the renderer over IPC, so the app window must be running.
  - Returns entity JSON dumps.
  - Write safety is stated only in the prompt.
- **Cloud MCP:** about 40 tools generated from an OpenAPI spec, with OAuth scopes (`deps/db-sync/worker`).
- **Gaps across all surfaces:**
  - no stale-write protection
  - no agent attribution
  - no group undo of agent edits, and no undo in the CLI
  - three APIs with different addressing
- **Mobile:** a Capacitor webview with OPFS sqlite-wasm. The editor isn't native.

## What pith took from this

| Logseq | pith |
|---|---|
| Opaque `kvs` blob storage | Relational tables (D1) |
| Inverses derived from diffs | Op returns its inverse at apply time (D6) |
| Mixed hard delete and recycle | Tombstones everywhere (D7) |
| Created-by only, human only | origin/actor/session on every txn (D8) |
| No version checks | `expected_version` on agent writes (D9) |
| In-memory undo, wiped on sync | Persistent undo, never wiped by sync (D10, §6) |
| Daemon required by in-memory DB | Library + SQLite WAL, no daemon (D12) |
| Separate search DB, async triggers | FTS5 in the same txn (D13) |
| Three agent APIs | One typed API, CLI and MCP generated from it (§4) |
| Kept as-is | UUID refs in content, fractional ordering, one-way Markdown mirror, canonical op set, dry-run, simulation tests for sync |
