# Development

## Setup

Install Rust from [rustup.rs](https://rustup.rs), then:

```sh
cargo install --path crates/cli    # installs `pith`
```

Re-run after pulling changes.

## Try it

Use a scratch database so your real notes (`~/.pith/pith.db`) stay untouched:

```sh
export PITH_DB=/tmp/pith-play.db

pith journal "Kickoff for [[Pith]] #planning"
pith show Pith
pith search kickoff
pith history
pith example          # more commands
```

Act as an agent with `--actor agent:claude --origin agent`. Add `--output json` for machine-readable output.

## macOS app

```sh
./scripts/build-swift.sh                         # Rust core → Swift bindings + XCFramework
cd apps/macos && PITH_DB=/tmp/pith-play.db swift run PithMacApp
```

Re-run the script after any Rust change.

## Check your work

```sh
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo run --release -p pith-bench -- --check    # speed budgets
(cd apps/macos && swift test)                   # after ./scripts/build-swift.sh
```

All five must pass before committing.
