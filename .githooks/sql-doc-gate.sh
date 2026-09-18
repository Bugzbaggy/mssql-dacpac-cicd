#!/usr/bin/env bash
# sql-doc-gate — pre-commit gate: blocks commits while *.sql changes on the
# current branch are undocumented.
#
# Modes:
#   (default) check   — compares a fingerprint of the branch's *.sql changes
#       (vs BASE_BRANCH, including staged and working-tree edits) against the
#       fingerprint recorded the last time /sql-documenter completed. On a
#       mismatch, or when no fingerprint is recorded, the commit is blocked
#       with instructions.
#   --mark-done       — records the current fingerprint. The /sql-documenter
#       skill runs this as its final step after refreshing the docs; run it
#       manually only if the docs are already accurate.
#
# The fingerprint lives under .git/ (per-clone, never committed), so a fresh
# clone or a new branch always starts un-marked.
#
# Bypass a single commit (discouraged): git commit --no-verify

set -euo pipefail

BASE_BRANCH="master"

MODE="check"
for arg in "$@"; do
	case "$arg" in
		--mark-done) MODE="mark" ;;
	esac
done

GIT_DIR="$(git rev-parse --git-dir)"
MARKER="$GIT_DIR/sql-doc-gate.fingerprint"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

# Never gate the base branch, a detached HEAD, or an in-progress merge.
if [ "$BRANCH" = "$BASE_BRANCH" ] || [ "$BRANCH" = "HEAD" ] || [ -f "$GIT_DIR/MERGE_HEAD" ]; then
	[ "$MODE" = "mark" ] && echo "[sql-doc-gate] Nothing to mark on $BRANCH."
	exit 0
fi

# Resolve the base ref (local branch first, then its origin tracking ref).
BASE_REF=""
for ref in "$BASE_BRANCH" "origin/$BASE_BRANCH"; do
	if git rev-parse --verify --quiet "$ref" >/dev/null; then
		BASE_REF="$ref"
		break
	fi
done
if [ -z "$BASE_REF" ]; then
	echo "[sql-doc-gate] Base branch '$BASE_BRANCH' not found — skipping gate."
	exit 0
fi

MERGE_BASE="$(git merge-base "$BASE_REF" HEAD 2>/dev/null || true)"
if [ -z "$MERGE_BASE" ]; then
	echo "[sql-doc-gate] No merge base with $BASE_REF — skipping gate."
	exit 0
fi

# All *.sql files changed on the branch: commits since the merge base plus
# staged and working-tree edits (i.e., what /sql-documenter would document).
CHANGED_FILES="$(git diff --name-only "$MERGE_BASE" -- '*.sql' | sort -u)"

if [ -z "$CHANGED_FILES" ]; then
	[ "$MODE" = "mark" ] && echo "[sql-doc-gate] No .sql changes on $BRANCH — nothing to mark."
	exit 0
fi

FINGERPRINT="$(git diff "$MERGE_BASE" -- '*.sql' | sha1sum | cut -d' ' -f1)"
COUNT="$(printf '%s\n' "$CHANGED_FILES" | wc -l | tr -d ' ')"

if [ "$MODE" = "mark" ]; then
	printf '%s\n' "$FINGERPRINT" > "$MARKER"
	echo "[sql-doc-gate] Marked $COUNT .sql file(s) on $BRANCH as documented."
	exit 0
fi

RECORDED=""
[ -f "$MARKER" ] && RECORDED="$(head -n1 "$MARKER" | tr -d '[:space:]')"

if [ "$FINGERPRINT" = "$RECORDED" ]; then
	exit 0
fi

echo "[sql-doc-gate] BLOCKED — $COUNT .sql file(s) changed on '$BRANCH' are not yet documented:"
printf '%s\n' "$CHANGED_FILES" | sed 's/^/    /'
echo ""
echo "  Run /sql-documenter (no arguments) in Claude Code to document the branch"
echo "  changes. Its final step re-arms this gate; then retry the commit."
echo "  If the docs are already accurate: bash .githooks/sql-doc-gate.sh --mark-done"
echo "  Bypass once (discouraged): git commit --no-verify"
exit 1
