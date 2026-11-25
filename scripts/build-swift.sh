#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PKG_DIR="$ROOT_DIR/apps/macos/PithCore"
GEN_DIR="$PKG_DIR/Generated"
HEADERS_DIR="$GEN_DIR/Headers"
SWIFT_DIR="$PKG_DIR/Sources/PithCore"
XCFRAMEWORK="$PKG_DIR/PithFFI.xcframework"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

cargo build --release -p pith-ffi

rm -rf "$GEN_DIR" "$XCFRAMEWORK"
mkdir -p "$HEADERS_DIR" "$SWIFT_DIR"

cargo run --release -p pith-ffi --bin uniffi-bindgen -- generate \
  --library "$ROOT_DIR/target/release/libpith_ffi.dylib" \
  --language swift \
  --out-dir "$GEN_DIR"

cp "$GEN_DIR/pith_ffi.swift" "$SWIFT_DIR/pith_ffi.swift"
cp "$GEN_DIR/pith_ffiFFI.h" "$HEADERS_DIR/pith_ffiFFI.h"
cp "$GEN_DIR/pith_ffiFFI.modulemap" "$HEADERS_DIR/module.modulemap"

xcodebuild -create-xcframework \
  -library "$ROOT_DIR/target/release/libpith_ffi.a" \
  -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK"

echo "Built $XCFRAMEWORK and $SWIFT_DIR/pith_ffi.swift"
