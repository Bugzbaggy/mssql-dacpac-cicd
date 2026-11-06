#!/usr/bin/env bash
# sql-doc-gate: stops a commit while the branch's .sql changes are newer than its docs.
#
#   sql-doc-gate.sh              exit 0 when the branch's .sql changes are the ones last marked as
#                                documented (or there are none), 1, listing the files, when not
#   sql-doc-gate.sh --mark-done  mark the branch's .sql changes as documented. /schemalore runs
#                                this once it has updated the docs; run it by hand only when the
#                                docs already match
#   sql-doc-gate.sh --files      print those changed .sql files, one per line: the scope
#                                /schemalore documents
#   sql-doc-gate.sh --base       print the base branch the changes are measured against
#
# The branch's .sql changes are the *.sql files that differ between the merge base with the base
# branch and the working tree: commits, staged and unstaged edits alike. Left out, because they hold
# no schema objects to document: tests/ and local-test/, skip_paths from .sql-ready.conf, and the
# space-separated paths in git config schemalore.exclude (a folder ends with /).
#
# The mark is a hash of "<blob> <path>" for each of those files, so it follows their content: a
# rebase, or a base-branch merge that leaves the branch's own .sql files alone, keeps it. It is kept
# per branch in the clone's shared git dir, .git/sql-doc-gate/<branch>, so it is never committed and
# marking one branch leaves the others as they were.
#
# The base branch is the first of: git config schemalore.base, base_branch in .sql-ready.conf (or
# the file SQL_READY_CONF names), origin/HEAD's branch, main. The message names documenter from
# .sql-ready.conf, else /schemalore. The gate lets the commit through on the base branch, on a
# detached HEAD (a rebase), during a merge, and when there is no merge base to compare with (a
# shallow clone). git commit --no-verify skips it for one commit.

set -u

say() { echo "[sql-doc-gate] $*"; }

MODE=check
case "${1:-}" in
	'') ;;
	--mark-done) MODE=mark ;;
	--files) MODE=files ;;
	--base) MODE=base ;;
	*) echo "usage: $0 [--mark-done | --files | --base]" >&2; exit 2 ;;
esac

# One git call for the root, both git dirs and the branch. The git dirs can come back relative to
# where git ran.
START_DIR="$PWD"
{ IFS= read -r ROOT || true; IFS= read -r GIT_DIR || true; IFS= read -r COMMON_DIR || true; IFS= read -r HEAD_REF || true; } <<EOF
$(git rev-parse --show-toplevel --git-dir --git-common-dir --symbolic-full-name HEAD 2>/dev/null)
EOF
if [ -z "$ROOT" ] || [ -z "$COMMON_DIR" ]; then
	echo "[sql-doc-gate] Not inside a git work tree." >&2
	exit 2
fi
for v in GIT_DIR COMMON_DIR; do
	case "${!v}" in
		/* | [A-Za-z]:[/\\]*) ;;
		*) printf -v "$v" '%s' "$START_DIR/${!v}" ;;
	esac
done
cd "$ROOT" || exit 2

# ---- settings -----------------------------------------------------------------------------------

trim() {   # trim <text>: sets REPLY to the text without leading and trailing white space
	REPLY="${1#"${1%%[![:space:]]*}"}"
	REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
}
CONF_BASE="" CONF_SKIP="" DOCUMENTER=""
conf="${SQL_READY_CONF:-$ROOT/.sql-ready.conf}"
if [ -f "$conf" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		case "$line" in *=*) ;; *) continue ;; esac
		trim "${line%%=*}"; key="$REPLY"
		trim "${line#*=}"
		case "$key" in
			base_branch) CONF_BASE="$REPLY" ;;
			skip_paths) CONF_SKIP="$REPLY" ;;
			documenter) DOCUMENTER="$REPLY" ;;
		esac
	done < "$conf"
fi
BASE="$(git config --get schemalore.base 2>/dev/null || true)"
[ -n "$BASE" ] || BASE="$CONF_BASE"
if [ -z "$BASE" ]; then
	BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
	BASE="${BASE#origin/}"
fi
BASE="${BASE:-main}"
DOCUMENTER="${DOCUMENTER:-/schemalore}"

if [ "$MODE" = base ]; then
	echo "$BASE"
	exit 0
fi

# ---- is there anything to check? ---------------------------------------------------------------

skip() {   # skip <message for --mark-done>: nothing to check here
	[ "$MODE" = mark ] && say "$1"
	exit 0
}
case "$HEAD_REF" in
	refs/heads/*) BRANCH="${HEAD_REF#refs/heads/}" ;;
	*) skip "HEAD is not on a branch, so there is nothing to mark." ;;
esac
[ "$BRANCH" != "$BASE" ] || skip "$BRANCH is the base branch, so there is nothing to mark."
[ ! -f "$GIT_DIR/MERGE_HEAD" ] || skip "A merge is in progress; mark the docs after it is committed."

# origin/<base> first: a local base branch is often behind.
MERGE_BASE=""
for ref in "refs/remotes/origin/$BASE" "refs/heads/$BASE"; do
	MERGE_BASE="$(git merge-base "$ref" HEAD 2>/dev/null)" && break
	MERGE_BASE=""
done
if [ -z "$MERGE_BASE" ]; then
	say "No merge base with $BASE, so the docs are not checked." >&2
	exit 0
fi

PATHSPEC=('*.sql' ':(exclude)tests' ':(exclude)local-test')
read -r -a SKIP <<< "$CONF_SKIP $(git config --get schemalore.exclude 2>/dev/null || true)" || true
for p in ${SKIP[@]+"${SKIP[@]}"}; do PATHSPEC+=(":(exclude)${p%/}"); done

if ! LIST="$(git --no-optional-locks -c core.quotePath=false diff --name-only --no-renames "$MERGE_BASE" -- "${PATHSPEC[@]}")"; then
	say "git diff against $BASE failed, so the docs are not checked." >&2
	exit 0
fi
if [ "$MODE" = files ]; then
	[ -z "$LIST" ] || printf '%s\n' "$LIST"
	exit 0
fi

FILES=() PRESENT=() LINES=()
while IFS= read -r f; do
	[ -n "$f" ] || continue
	FILES+=("$f")
	if [ -e "$f" ]; then PRESENT+=("$f"); else LINES+=("deleted $f"); fi
done <<< "$LIST"
[ ${#FILES[@]} -gt 0 ] || skip "No .sql changes on $BRANCH, so there is nothing to mark."

# ---- the mark -----------------------------------------------------------------------------------

# One git call hashes every file still on disk, as it would be staged.
if [ ${#PRESENT[@]} -gt 0 ]; then
	i=0
	while IFS= read -r blob; do
		LINES+=("$blob ${PRESENT[$i]}")
		i=$((i + 1))
	done <<EOF
$(printf '%s\n' "${PRESENT[@]}" | git hash-object --stdin-paths)
EOF
	if [ "$i" -ne ${#PRESENT[@]} ]; then
		say "Could not hash the changed .sql files, so the docs are not checked."
		exit 0
	fi
fi
MARK="$(printf '%s\n' "${LINES[@]}" | git hash-object --stdin)"
STORE="$COMMON_DIR/sql-doc-gate/$BRANCH"

if [ "$MODE" = mark ]; then
	if mkdir -p "${STORE%/*}" && printf '%s\n' "$MARK" > "$STORE"; then
		say "Marked ${#FILES[@]} changed .sql file(s) on $BRANCH as documented."
		exit 0
	fi
	say "Could not write $STORE."
	exit 1
fi

SAVED=""
[ -f "$STORE" ] && IFS= read -r SAVED < "$STORE"
[ "$MARK" = "$SAVED" ] && exit 0

if [ -n "$SAVED" ]; then
	say "Blocked: the .sql changes on $BRANCH have moved on since the docs were marked current."
else
	say "Blocked: the .sql changes on $BRANCH have not been documented yet."
fi
printf '    %s\n' "${FILES[@]}"
echo "  Run $DOCUMENTER in Claude Code: it updates the docs and marks them done. Then commit again."
echo "  If the docs already match: bash .githooks/sql-doc-gate.sh --mark-done"
echo "  To skip the gate for one commit: git commit --no-verify"
exit 1
