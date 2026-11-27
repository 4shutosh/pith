# pith — Architecture

This document describes how pith is built and why. It states design rules, not a schedule.
For notes on prior art, see [research/logseq-db.md](research/logseq-db.md).

---

## 1. Core decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Relational SQLite is the source of truth.** Real `blocks`, `pages`, `refs`, `props` tables. | Every surface (UI, CLI, MCP) reads and writes the same queryable store. There is no in-memory copy to load, keep in sync, or lose. |
| D2 | **Content is the single source for everything that can be derived from it.** Properties (`key:: value`), task state, refs and tags are parsed from block text; their tables are indexes. | One writer per fact, so text and tables can never disagree. Export is lossless because the text holds everything. |
| D3 | **Markdown is a one-way mirror plus an importer.** It is never a live source. | Files as truth force constant reconciliation between disk and DB. A derived mirror keeps zero lock-in without that cost. |
| D4 | **Refs are stored as UUIDs inside content** (`[[<uuid>]]`, `((<uuid>))`, `#[[<uuid>]]`) and rendered to titles on read. | Renames touch one row, and refs never break. |
| D5 | **One entry point for every mutation: `apply_ops(ops, TxMeta)`.** UI, CLI, MCP, importer, undo and sync all go through it. There is no other write path. | Validation, derivation, attribution and history are guaranteed for every change, with no skip flags. |
| D6 | **Each op returns its own inverse at apply time**, computed from the state it actually saw. | Inverses are exact by construction. Reconstructing them later from state diffs is fragile and grows special cases. |
| D7 | **Soft delete everywhere** (`deleted_at` tombstone). Undo of delete = restore. A GC purges tombstones *and* the history that references them, past a retention horizon. | IDs stay stable and undo of a delete is trivial. GC and history agree on what still exists. |
| D8 | **Every transaction carries `origin` + `actor` (+ `session`).** Pages and blocks carry `created_by` / `updated_by`. | Human and agent edits are always distinguishable and reviewable. |
| D9 | **Writes are conditional.** Pages and blocks have a `version`. Content and structural writes from agents (`update`, `move`, `delete`) pass `expected_version` and fail on mismatch. | An agent can never silently overwrite a change it hasn't seen. |
| D10 | **Undo history is persistent, in SQLite, and filterable by actor.** If one entry can't be applied, it is skipped; history is only trimmed by GC (D7). | Undo survives restarts and is available to every surface. A whole agent session can be reverted. |
| D11 | **Stable UUIDv7 IDs and fractional-index sibling ordering**, with a deterministic tie-break (uuid) to repair duplicate keys. | A move rewrites one row. Concurrent inserts and moves merge cleanly, which is what sync needs. |
| D12 | **No daemon.** The core is a library. Each process opens SQLite in WAL mode with `BEGIN IMMEDIATE` + `busy_timeout`. Long-lived apps detect external writes via `PRAGMA data_version` and read what changed through the change cursor (§3). | SQLite already serialises writers safely. Add a daemon only if change-notification latency demands it. |
| D13 | **Search is FTS5 with the `trigram` tokenizer, in the same database, updated synchronously in the write txn, and rebuildable from content.** The tokenizer is fixed in the schema. Page titles and block text have separate indexes: `pages_fts` holds live page titles, `blocks_fts` holds each block's own text with `[[page]]`/`#tag` UUIDs rendered to titles; `((block refs))` are neither expanded nor indexed. A search returns page hits first, then one hit per matching line of each matching block, in document order. A line hit carries its breadcrumb (page and ancestor blocks), the line split into highlighted and plain segments, and the cursor offset of the match (in Unicode scalars, the unit for every text offset the core exchanges). Queries shorter than 3 characters return only page hits, by title prefix. | Trigram gives substring matches ("map" finds "Roadmap") and works for languages without word spaces. Separate title and text indexes make every page findable, including empty ones, and stop one page's blocks from crowding out results just because its title matches. Prefix lookup keeps short queries index-backed. Search is never stale. Not expanding block refs means editing a block re-indexes only that block. |

---

## 2. Data model (SQLite)

```sql
-- content
pages  (seq INTEGER PRIMARY KEY, id BLOB UNIQUE, title TEXT, title_lower TEXT, journal_day INTEGER NULL,
        document_mode INTEGER DEFAULT 0, favorite INTEGER DEFAULT 0,
        created_at, updated_at, created_by, updated_by, deleted_at NULL, version INTEGER)
  UNIQUE INDEX (title_lower) WHERE deleted_at IS NULL   -- a soft-deleted title can be reused
  UNIQUE INDEX (journal_day) WHERE deleted_at IS NULL   -- one journal page per day

blocks (seq INTEGER PRIMARY KEY, id BLOB UNIQUE, page_id BLOB, parent_id BLOB NULL, order_key TEXT,
        content TEXT,            -- raw text, refs stored as UUIDs (D4)
        collapsed INTEGER,       -- view state, see §3
        created_at, updated_at, created_by, updated_by, deleted_at NULL, version INTEGER)
  INDEX (parent_id, order_key)   -- children in order
  INDEX (page_id)

-- derived from content (D2); rows exist only for live (non-deleted) blocks
refs   (src_block BLOB, kind TEXT /* page|block|tag|prop */, target BLOB)
  INDEX (target)                 -- backlinks
props  (block_id BLOB, key TEXT, value TEXT, value_ref BLOB NULL)
  INDEX (key, value)
tasks  (block_id BLOB PK, state TEXT /* TODO|DOING|DONE|... */)
blocks_fts USING fts5(text, tokenize='trigram')    -- rowid = blocks.seq, see D13
pages_fts  USING fts5(title, tokenize='trigram')   -- rowid = pages.seq, live pages only

-- history / attribution
txns       (seq INTEGER PRIMARY KEY, id BLOB UNIQUE /* uuidv7 */, ts,
            origin TEXT /* user|agent|import|undo|sync */,
            actor TEXT /* 'me' | 'agent:claude' */, session TEXT NULL, summary TEXT,
            undoes BLOB NULL /* txn this one reverts */,
            undo_group TEXT NULL /* txns undone and redone as one step */)
  INDEX (undoes)
ops        (txn_id BLOB, seq INTEGER, forward JSON, inverse JSON, PRIMARY KEY (txn_id, seq))
txn_blocks (txn_id BLOB, block_id BLOB)   -- which blocks/pages each txn touched (page ids share the column)
  INDEX (block_id, txn_id)                -- undo conflict checks, per-block history
view_log   (seq INTEGER PRIMARY KEY, ts, actor TEXT, op JSON)   -- view-state ops; never undone
```

**Invariants**
- A block's `page_id` equals its parent's `page_id`. A cross-page move rewrites `page_id` for the whole subtree in the same txn.
- No cycles in `parent_id`.
- Derived rows (`refs`, `props`, `tasks`, `blocks_fts`) exist exactly for live blocks, and `pages_fts` rows exactly for live pages.
  - Tombstoning a block removes them.
  - Restoring it re-derives them.

Tags are `#name` or `#[[any name]]`. A bare `#name` must follow whitespace, an opening bracket or quote, or the start of a line, and runs until whitespace or punctuation (including Unicode quotes and CJK punctuation); letters and marks from any script belong to the tag.

Properties are intentionally simple: `key:: value`, and values may be refs. There are no typed property entities, closed value sets or class hierarchies. The schema can grow into them without changing D2.

---

## 3. Write path

```
apply_ops(ops, TxMeta{origin, actor, session, summary})
  1. validate ops (schema, ids exist, no cycles on move, expected_version)
  2. BEGIN IMMEDIATE
  3. for op in ops: apply → collect inverse                       (D6)
  4. derive for changed blocks:
       - parse content → refs, props, tasks, blocks_fts
       - [[Title]] for a page that doesn't exist yet → create_page in this txn
         (its inverse is part of the txn, so undo removes the page too)
       - tombstoned blocks → drop their derived rows; restored blocks → re-derive
       - touched pages → sync their pages_fts row
       - rename_page → re-index blocks_fts for blocks that link to that page
     bump version, stamp updated_by
  5. check invariants (§2)
  6. insert txns, ops, txn_blocks rows; view-state ops go to view_log
  7. COMMIT
```

Markdown export/mirroring runs explicitly (`pith export`) or as a debounced hook inside long-lived UI apps. It never runs as background work from short-lived CLI calls.

**Canonical op set.** It is kept small on purpose because undo and sync replay these ops.

- **Content ops** (versioned, recorded for undo):
  - `insert_block`, `update_block`, `move_block`, `delete_block`, `restore_block`
  - `create_page`, `rename_page`, `delete_page`, `restore_page`

  `delete_page` tombstones the page and all its blocks in the same txn.
- **Helpers that compile to content ops:**
  - property set/remove and task-state toggles rewrite the block's text through `update_block` (D2)
  - indent, outdent and move up/down become `move_block`
- **View-state ops** `set_collapsed` and `set_page_favorite`: persisted and synced, but they do not bump `version` and are not recorded for undo. They are appended to `view_log` instead of `txns`, in the same transaction, so readers and sync see them while undo history and its conflict checks never do.

**Change feed.** A long-lived reader keeps a cursor (the newest `txns` and `view_log` seqs) and asks the core what changed after it. The core answers in viewer terms, derived from the logged ops: pages whose row changed (created, renamed, deleted, restored, favorited), pages whose visible tree changed (insert, move from or to, delete, restore, collapse), and blocks whose displayed row is stale (edited blocks, plus every block that displays a changed block or page through a ref). Past a fixed number of ops it answers "reload everything" instead of diffing. Readers apply their own writes through the same feed, so there is one refresh path for local, external and synced changes.

**Undo** applies the `inverse` ops of txn T as a new txn with `origin=undo, undoes=T`. Its checks and its write run in one `BEGIN IMMEDIATE` transaction, so two processes can't both undo T. Only undo can create `origin=undo` txns; `apply_ops` rejects that origin from callers.

- T can't be undone while it is undone. Undoing the undo txn is redo, after which T can be undone again. "Undone" is derived from the append-only `undoes` chain; history rows are never mutated.
- Undo/redo stacks are per actor and derived from the log. Txns may carry an `undo_group`; all of an actor's txns in one group undo and redo as one step, while each stays its own append-only history row. "Undo last" reverts the actor's newest edit that isn't undone. "Redo last" re-applies the actor's newest undo made after their last edit; a new edit clears redo. Picking the target and applying it happen in one transaction.
- Undo reports a conflict (`--force` overrides) instead of clobbering when:
  - a later txn by a *different* actor touched any block T touched, or
  - a restored page's title is now taken by another page.

**Editor input:** keystrokes do not each become a txn.
- The editor debounces on idle.
- It flushes on structural actions (Enter, Tab, blur, navigation).
- It never flushes during IME composition.

Saves during one editing session share an `undo_group`, so a typing burst is one undo step.

**Editor commands live in the core.** Split, merge, indent, outdent, move up/down, paste, append, reveal and copy-as-Markdown, and their multi-block forms over a selection (one page, one transaction, one undo step), compile to canonical ops (or reads) using the full tree, never the rows a UI happens to have loaded. Autocomplete (`[[`, `#`, `((`, `/`) detection and insertion, the slash command list and what each command does, inline formatting (parsing `**`, `*`, `~~`, `==`, Markdown links and bare URLs into spans, and toggling a format over a selection), and bracket auto-pairing are core functions too.

**Saving keeps link identity.** When text that came from a block is saved (edit, split, merge), titles the block already linked resolve to the same page ids, including deleted pages, so editing never mints a duplicate page and a deleted page stays restorable. Only titles new to the text are looked up among live pages (and created if missing). Edits carry the version the editor started from, so a change made elsewhere surfaces as a conflict instead of being overwritten. A journal page is created together with its first block, so opening the app writes nothing; a new page likewise exists only on screen until it is named or gets its first block (`start_page` creates both in one transaction), so abandoning it leaves nothing behind.

**Display:** the core turns block content into typed spans (text, code, task, page link, tag, block ref), each carrying its exact source text, so the spans join back into the editable text. The core also decides what is displayed: each row carries its display runs (shown text, source text and style), with formatting markers, the task keyword and heading or quote prefixes hidden, block kinds (heading, code, quote, divider) and properties resolved. UIs style those runs and never re-parse content or re-derive what is shown; for text being edited, the core also returns highlight ranges. Anything that points into displayed text, such as find-in-page matches, is computed by the core against that same displayed text and covers the whole tree, collapsed blocks included. The core returns facts (flags, counts, paths), never user-facing sentences; each app words them. A block is displayed and edited by the same text view, so focusing a block never shifts it; the task keyword stays outside the edited text and is changed by commands (cycle, toggle done) in the core.

---

## 4. Agent layer (CLI + MCP)

There is one typed API in `pith-core`. The CLI and MCP are thin wrappers generated from it, so every surface has the same schema and semantics.

**Addressing:**
- IDs are UUIDs everywhere.
- Output shows the shortest unique **suffix** of the UUID, at least 6 hex chars, lengthened as needed like git's short hashes. Suffixes are used because UUIDv7 prefixes are timestamps and collide for blocks created close together.
- Input accepts the full UUID or any unique suffix.
- Database-local integer ids are never used.

**What the model sees:** a compact outline, not entity JSON dumps:

```
# Project X                                   (page 9f1c2e)
- Ship v1 [[Roadmap]]                         ^a1b2c3 v4
  - Core + CLI  TODO                          ^d4e5f6 v1
```

**Tools**

| Tool | Notes |
|---|---|
| `search(q, limit)` | Page hits, then one hit per matching line: breadcrumb, matched line, block id |
| `get_page(name\|id, depth)` / `get_block(id, depth)` | Outline format above |
| `backlinks(page\|block)` | Live blocks only |
| `journal_append(markdown, date?)` | Most common agent write |
| `insert(parent, after?, markdown)` | Markdown may be a nested tree; it is all applied in one txn |
| `update(id, content, expected_version)` | Fails on version mismatch (D9) |
| `move(id, parent, after?, expected_version)` | Fails on version mismatch; bumps version |
| `delete(id, expected_version)` | Soft delete (D7) |
| `history(actor?, since?)` / `undo(txn_id)` | Lets the user review and revert a whole agent session |

- Every write tool supports `dry_run`, which returns the planned ops.
- The CLI has `--output human|json` with error codes and hints; diagnostics go to stderr.
- The repo ships a `SKILL.md` for agents and a `pith example <cmd>` command.
- Safety comes from these mechanisms (version checks, soft delete, attribution, undo), not from wording in prompts.

---

## 5. Repository layout

One monorepo. A Cargo workspace at the root holds the Rust code, and each native app is a self-contained project under `apps/` that consumes `pith-ffi`.

```
crates/        folder → package
  core/        pith-core    schema+migrations, ops/apply/inverse, parser, queries, undo, search
  bench/       pith-bench   synthetic 100k-block graph; benches gate CI on the README budgets
  cli/         pith-cli     `pith` binary
  mcp/         pith-mcp     MCP server over stdio
  md/          pith-md      Logseq import, Markdown mirror/export, round-trip tests
  ffi/         pith-ffi     UniFFI bindings for native UIs
apps/
  android/     Gradle project (Jetpack Compose); loads pith-ffi's generated Kotlin + .so
  macos/       Xcode / SwiftPM project (SwiftUI); loads pith-ffi's generated Swift + XCFramework
fixtures/      small sample graphs used by tests
docs/          architecture and research
```

Dependency direction is one-way: everything depends on `pith-core`; `pith-core` depends on no other workspace crate; apps depend only on `pith-ffi`.

Directories and crates are added when there is code to put in them; empty placeholders are not scaffolded.

---

## 6. Sync

Sync is a replication layer over the op log. It never adds a second write path: remote changes enter through `apply_ops` with `origin=sync`.

**What the core guarantees, so that any sync model can be built on it:**
- stable UUIDv7 ids and fractional ordering
- tombstones instead of hard deletes
- a persisted log of semantic ops (forward and inverse) per user action, with stable txn ids
- a small canonical op set to replay

**Requirements for any sync design:**
- Replay intent (canonical ops), never raw row diffs.
- Remote changes never wipe local undo history. Undo is scoped to the local actor's own txns and uses the normal conflict check (§3).
- A failed or rejected change is rolled back locally, never left half-applied.
- Text that loses a conflict is preserved somewhere the user can recover it, not silently dropped.
- Divergence is detectable (for example, a checksum compared when replicas should match).
- Correctness is proven by multi-replica simulation tests, not by unit tests alone.

**Design options:**
- **(a) CRDT (e.g. Loro movable tree) with a relay that only stores and forwards.** The server never reads content, so end-to-end encryption can cover everything.
- **(b) Authoritative server with client rebase.** The server orders and validates ops, and clients replay their pending ops on top of it. This is simpler to reason about, but the server must read the data, which limits end-to-end encryption.
