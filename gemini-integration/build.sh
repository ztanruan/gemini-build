#!/usr/bin/env bash
# Build the patched Vertex-native binary from this fork (Sub-project E).
#
# Reproduces the release binary that carries the Gemini thought_signature
# round-trip + Claude-on-Vertex adaptation. Requires the Rust toolchain
# (rustup auto-installs the pinned version) and protoc (or bin/protoc via
# DotSlash).
#
# Usage:  ./build.sh            # release build
#         ./build.sh --debug    # faster debug build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Resolve protoc: prefer $PROTOC, then PATH, then DotSlash-pinned bin/protoc.
if [[ -z "${PROTOC:-}" ]]; then
  if command -v protoc >/dev/null 2>&1; then PROTOC="$(command -v protoc)"
  elif command -v dotslash >/dev/null 2>&1 && [[ -f bin/protoc ]]; then PROTOC="$ROOT/bin/protoc"
  else echo "ERROR: protoc not found. Install protobuf or dotslash." >&2; exit 1; fi
fi
export PROTOC
echo "Using PROTOC=$PROTOC"

command -v cargo >/dev/null 2>&1 || { echo "ERROR: cargo not found. Install rustup." >&2; exit 1; }

PROFILE="release"; FLAG="--release"
if [[ "${1:-}" == "--debug" ]]; then PROFILE="debug"; FLAG=""; fi

echo "Building xai-grok-pager-bin ($PROFILE)…"
# shellcheck disable=SC2086
cargo build -p xai-grok-pager-bin $FLAG

BIN="$ROOT/target/$PROFILE/xai-grok-pager"
if [[ -x "$BIN" ]]; then
  echo "OK: $BIN"
  echo "Sanity: $("$BIN" --version 2>/dev/null || echo '(no --version)')"
else
  echo "ERROR: build did not produce $BIN" >&2; exit 1
fi
