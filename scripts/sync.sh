#!/usr/bin/env bash
# Generate provider-specific instruction files from the canonical AGENTS.md.
# Usage: scripts/sync.sh [target-repo-dir]   (default: current directory)
# Symlinks where the provider reads the file as-is; copies where the path is nested.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/AGENTS.md"
TARGET="$(cd "${1:-.}" && pwd)"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

# AGENTS.md is read natively by Copilot, Codex, Cursor and others.
if [[ "$TARGET" != "$(dirname "$SRC")" ]]; then
  ln -sfn "$SRC" "$TARGET/AGENTS.md"
fi

# Claude Code reads CLAUDE.md.
ln -sfn AGENTS.md "$TARGET/CLAUDE.md"

# GitHub Copilot repository instructions.
mkdir -p "$TARGET/.github"
ln -sfn ../AGENTS.md "$TARGET/.github/copilot-instructions.md"

echo "synced from $SRC into $TARGET:"
ls -l "$TARGET/AGENTS.md" "$TARGET/CLAUDE.md" "$TARGET/.github/copilot-instructions.md"
