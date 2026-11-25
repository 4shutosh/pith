# AGENTS.md

pith: local-first, agent-native block outliner. Rust + SQLite core, CLI + MCP for agents, native apps over UniFFI.

Design lives in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Read it before touching `crates/`; if a task conflicts with it, stop and ask.

## Before calling work done

```sh
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

## Rules

- New crates go in `crates/<name>/` with package name `pith-<name>`. Create crates and directories only when adding real code to them.
- `pith-core` depends on no other workspace crate; apps talk only to `pith-ffi`.
- All writes go through `apply_ops` in `pith-core`; SQL lives only in `pith-core`.
- Every op ships with a test that applies it, applies its inverse, and checks the state is restored.
- No comments or doc comments. Code is the truth: use names, types, small functions, `expect("…")` messages and tests. Only exception: `// SAFETY:` on `unsafe` in `pith-ffi`.
- No `unwrap()` in library code; `thiserror` in libraries, `anyhow` only in binaries and tests.
- Keep `docs/ARCHITECTURE.md` timeless and update it in the same change when a design decision changes.

## Git

- One-line commit messages with a conventional prefix, e.g. `feat(core): add move_block inverse`.
- Never add `Co-Authored-By` or any AI attribution to commits.
- Never commit `target/`, `.claude/settings.local.json`, or `docs/ROADMAP.md`.
