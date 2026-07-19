#!/usr/bin/env bash
# Distribution installer for the Vertex-native agent (Sub-project E).
#
# Installs the patched binary + runs the onboarding wizard, so a new user goes
# from clone to a working Vertex/Gemini agent in one command.
#
#   ./install.sh              # build (if needed), install binary, run wizard
#   BRAND=myagent ./install.sh  # install under a custom command name
#
# Set BRAND to rename the installed command (default: keeps `grok`/`agent`).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
BRAND="${BRAND:-grok}"
BINDIR="${BINDIR:-$HOME/.local/bin}"

echo "== Vertex-native agent installer =="

# 1) Build the patched binary if it isn't already present.
BIN="$ROOT/target/release/xai-grok-pager"
if [[ ! -x "$BIN" ]]; then
  echo "Patched binary not found — building (this takes a while)…"
  "$SRC/build.sh"
fi

# 2) Install the binary under the chosen brand name.
mkdir -p "$BINDIR"
install -m 0755 "$BIN" "$BINDIR/$BRAND"
echo "Installed: $BINDIR/$BRAND"
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *) echo "NOTE: add $BINDIR to your PATH (e.g. in ~/.zshrc): export PATH=\"$BINDIR:\$PATH\"" ;;
esac

# 3) Run the onboarding wizard (connect GCP, pick models, write config).
echo
echo "Launching setup wizard…"
"$SRC/setup-wizard.sh"

echo
echo "Done. Start the agent with:  $BRAND"
