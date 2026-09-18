#!/usr/bin/env bash
# Auto-enrol this clone into the .githooks/ pre-commit hook.
#
# Idempotent — safe to run any number of times.
# The CI workflow (`nitsql.yml`) is the authoritative gate; this script
# just sets up local fast-feedback so devs don't push commits that CI will
# reject. The bash variant covers Git Bash on Windows + macOS + Linux.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	echo "Error: not inside a git repository."
	exit 1
}

cd "$REPO_ROOT"

EXISTING="$(git config --local --get core.hooksPath 2>/dev/null || true)"
DESIRED=".githooks"

if [ "$EXISTING" = "$DESIRED" ]; then
	echo "[nitsql] Already enrolled (core.hooksPath=$DESIRED)."
	exit 0
fi

if [ -n "$EXISTING" ] && [ "$EXISTING" != "$DESIRED" ]; then
	echo "[nitsql] Refusing to overwrite existing core.hooksPath: $EXISTING"
	echo "  Re-point your hook framework at $DESIRED, or run:"
	echo "    git config --local --replace-all core.hooksPath $DESIRED"
	exit 1
fi

git config --local core.hooksPath "$DESIRED"
chmod +x "$DESIRED/pre-commit" 2>/dev/null || true
echo "[nitsql] Local pre-commit hook enabled (core.hooksPath=$DESIRED)."
echo "  Tip: CI runs the same checks regardless — this just gives you faster feedback."
