#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="soft"
DAYS=7
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--all | --release] [--days N] [--dry-run]

Modes:
  (default)   Remove incremental caches and build units older than N days (default: 7)
  --release   Clean only target/release
  --all       Run cargo clean and remove apps/macos/.build

Options:
  --days N    Age threshold in days for default mode (default: 7)
  --dry-run   Print what would be removed without deleting anything
  -h, --help  Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      MODE="all"
      shift
      ;;
    --release)
      MODE="release"
      shift
      ;;
    --days)
      DAYS="${2:?--days requires a number}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

dir_size() {
  if [[ -d "$1" ]]; then
    du -sh "$1" | awk '{print $1}'
  else
    echo "0B"
  fi
}

remove_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] rm -rf $path ($(dir_size "$path"))"
  else
    rm -rf "$path"
  fi
}

prune_stale_build_units() {
  local build_dir="$1"
  if [[ ! -d "$build_dir" ]]; then
    return
  fi
  while IFS= read -r -d '' unit_dir; do
    remove_path "$unit_dir"
  done < <(find "$build_dir" -mindepth 2 -maxdepth 2 -type d -mtime "+$DAYS" -print0)
}

echo "Before: target=$(dir_size target) apps/macos/.build=$(dir_size apps/macos/.build)"

case "$MODE" in
  soft)
    remove_path target/debug/incremental
    remove_path target/release/incremental
    prune_stale_build_units target/debug/build
    prune_stale_build_units target/release/build
    ;;
  release)
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] cargo clean --release ($(dir_size target/release))"
    else
      cargo clean --release
    fi
    ;;
  all)
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] cargo clean ($(dir_size target))"
    else
      cargo clean
    fi
    remove_path apps/macos/.build
    ;;
esac

echo "After:  target=$(dir_size target) apps/macos/.build=$(dir_size apps/macos/.build)"
