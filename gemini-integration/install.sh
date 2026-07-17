#!/usr/bin/env bash
# Installs the Gemini-on-Vertex integration for Grok Build into ~/.grok/,
# and wires the launch-time model picker into ~/.zshrc.
#
# Re-runnable (idempotent). Backs up an existing ~/.grok/config.toml.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.grok"
ZSHRC="$HOME/.zshrc"
SOURCE_LINE="source ~/.grok/grok-pick.zsh"

mkdir -p "$DEST"

# config.toml — back up any existing one so we never silently clobber it.
if [[ -f "$DEST/config.toml" ]] && ! cmp -s "$SRC/config.toml" "$DEST/config.toml"; then
  cp "$DEST/config.toml" "$DEST/config.toml.bak.$(date +%s)"
  echo "backed up existing ~/.grok/config.toml"
fi
cp "$SRC/config.toml"    "$DEST/config.toml"
cp "$SRC/gcp-token.sh"   "$DEST/gcp-token.sh"
cp "$SRC/grok-pick.zsh"  "$DEST/grok-pick.zsh"
chmod +x "$DEST/gcp-token.sh"
echo "installed config.toml, gcp-token.sh, grok-pick.zsh -> $DEST"

# Wire the picker into ~/.zshrc (once).
if [[ -f "$ZSHRC" ]] && grep -qF "$SOURCE_LINE" "$ZSHRC"; then
  echo "~/.zshrc already sources the picker"
else
  printf '\n# Grok Build: ask which Gemini model at launch\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "added picker source line to ~/.zshrc"
fi

echo
echo "Done. Next steps:"
echo "  1) One-time GCP login:   gcloud auth application-default login"
echo "  2) Enable billing on project smoothiesdeliveryv1 (required for inference)"
echo "  3) Open a new terminal (or: source ~/.zshrc), then run:  grok"
