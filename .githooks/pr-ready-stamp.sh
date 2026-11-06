#!/usr/bin/env bash
# pr-ready-stamp: the review state /pr-ready keeps for each branch, and the check the pre-PR gate
# (pr-ready-gate.sh, and the pre-push reminder in pr-ready-hook.sh) makes against it.
#
# State: .git/claude-review/<branch>.json, in the clone's shared git dir, so it is never committed
# and the clone's worktrees share it. It holds the review passes the branch has used (the 2-pass
# cap), the commit last reviewed and, for every file the branch changes, its blob at the merge base
# and the blob that was reviewed. A file whose pair of blobs is unchanged needs no new review.
# /pr-ready keeps its findings tables in .git/claude-review/<branch>.findings.md next to it.
#
# Usage:
#   pr-ready-stamp.sh files [--ref <branch>]   "<base blob> <blob> <path>" for each committed file
#                                              change that needs review (exit 4 when there is no
#                                              merge base to find the changes with)
#   pr-ready-stamp.sh scope                    the files whose change the last review didn't cover
#                                              (all of them when there is none; exit 4 with no
#                                              merge base)
#   pr-ready-stamp.sh uncommitted              changed or new files that aren't committed, so aren't
#                                              part of a review
#   pr-ready-stamp.sh check [--ref <branch>] [--explain]
#                                              exit 0 when nothing needs review or the last review
#                                              covers every change, 1 when it doesn't, 4 when there
#                                              is no merge base to find the changes with (--explain
#                                              then prints the status line)
#   pr-ready-stamp.sh status [--ref <branch>]  one-line summary
#   pr-ready-stamp.sh passes                   review passes the branch has used
#   pr-ready-stamp.sh write [key=value...]     record the committed changes as reviewed; passes=<n>
#                                              adds n to the branch's passes, other pairs are kept
#                                              as notes on this run
#   pr-ready-stamp.sh log <title>              append stdin (a findings table) to the findings log
#   pr-ready-stamp.sh findings                 print the findings log
#   pr-ready-stamp.sh reset                    forget the branch's review state, findings log and
#                                              pre-commit scans
#   pr-ready-stamp.sh config [<key>]           the settings below, defaults filled in, as key=value
#                                              lines (or one key's value)
#
# The pre-commit scan (/review-before-commit, a low-level /review-db pass over one commit's changes)
# keeps its own record, .git/claude-review/<branch>.scanned, so a reminder only fires for content
# no scan has seen:
#   pr-ready-stamp.sh next [--all]             "<blob in HEAD> <blob> <path>" for each change the next
#                                              commit would contain: the staged changes, or with
#                                              --all what `git commit -a` would take
#   pr-ready-stamp.sh scan-scope [--all]       those files no scan has covered yet
#   pr-ready-stamp.sh scan-check [--all] [--explain]
#                                              exit 0 when scans have covered them all, 1 when not
#   pr-ready-stamp.sh scan-write [--all]       record them as scanned, dropping scans of versions HEAD
#                                              has moved past
#
# Settings come from .sql-ready.conf at the repository root (SQL_READY_CONF names another file),
# one "key = value" per line, # for comments:
#   base_branch      the branch PRs go into (default: origin/HEAD's branch, else main)
#   skip_paths       space-separated paths that never need review: a folder ends with /, anything
#                    else is one file. Use it for generated and out-of-scope files (a migrations
#                    folder CI writes, deployment scripts another team owns)
#   generated_paths  the part of skip_paths that CI generates; generator_bot is the commit author
#                    allowed to change it (default github-actions[bot])
#   lint_command     the linter the skills run on the .sql files in scope (the files are appended)
#   doc_gate         the documentation gate the skills run after a fix to a .sql file
#   documenter       the skill to run when the doc gate blocks
#   review_note      repository rules appended to every review, local and CI
#
# Changes are the branch's commits against their merge base with origin/<base_branch> (the local
# <base_branch> as a fallback). Left out: skip_paths, and docs, which never need review: docs/,
# CHANGELOG, and *.md outside .claude/ other than CLAUDE.md and AGENTS.md. Blobs are content hashes,
# so a rebase that keeps a file's content keeps its review; a new edit, or a base-branch merge that
# changes a reviewed file's base, needs a new one.
#
# The gate runs this before Claude Code's gh and git calls, so it sticks to bash builtins and a
# few git calls: process starts are slow on Windows.

set -euo pipefail

cmd="${1:-status}"
[ $# -gt 0 ] && shift
REF=""
EXPLAIN=0
ALL=0
while [ $# -gt 0 ]; do
	case "$1" in
		--ref) REF="${2:-}"; [ $# -gt 1 ] && shift ;;
		--ref=*) REF="${1#--ref=}" ;;
		--explain) EXPLAIN=1 ;;
		--all) ALL=1 ;;
		*) break ;;
	esac
	shift
done
TMP_INDEX="" TMP_SCANS=""
trap '[ -z "$TMP_INDEX" ] || rm -f "$TMP_INDEX" "$TMP_INDEX.lock"; [ -z "$TMP_SCANS" ] || rm -f "$TMP_SCANS"' EXIT

# One git call for the repository root, the shared git dir and the checked-out branch. The shared
# git dir can come back relative to where git ran (no --path-format: that needs git 2.31).
START_DIR="$PWD"
{ IFS= read -r ROOT || true; IFS= read -r COMMON_DIR || true; IFS= read -r HEAD_REF || true; } <<EOF
$(git rev-parse --show-toplevel --git-common-dir --symbolic-full-name HEAD 2>/dev/null)
EOF
if [ -z "$ROOT" ] || [ -z "$COMMON_DIR" ]; then
	echo "[pr-ready] Not inside a git work tree." >&2
	exit 2
fi
case "$COMMON_DIR" in
	/* | [A-Za-z]:[/\\]*) ;;
	*) COMMON_DIR="$START_DIR/$COMMON_DIR" ;;
esac
cd "$ROOT" || exit 2
STATE_DIR="$COMMON_DIR/claude-review"

# ---- settings -----------------------------------------------------------------------------------

BASE_BRANCH="" SKIP_PATHS="" GENERATED_PATHS="" GENERATOR_BOT="" LINT_COMMAND="" DOC_GATE=""
DOCUMENTER="" REVIEW_NOTE=""
trim() {   # trim <text>: sets REPLY to the text without leading and trailing white space
	REPLY="${1#"${1%%[![:space:]]*}"}"
	REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
}
load_conf() {
	local file="${SQL_READY_CONF:-$ROOT/.sql-ready.conf}" line key
	[ -f "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		trim "$line"; line="$REPLY"
		case "$line" in '' | '#'*) continue ;; esac
		case "$line" in *=*) ;; *) continue ;; esac
		trim "${line%%=*}"; key="$REPLY"
		trim "${line#*=}"
		case "$key" in
			base_branch) BASE_BRANCH="$REPLY" ;;
			skip_paths) SKIP_PATHS="$REPLY" ;;
			generated_paths) GENERATED_PATHS="$REPLY" ;;
			generator_bot) GENERATOR_BOT="$REPLY" ;;
			lint_command) LINT_COMMAND="$REPLY" ;;
			doc_gate) DOC_GATE="$REPLY" ;;
			documenter) DOCUMENTER="$REPLY" ;;
			review_note) REVIEW_NOTE="$REPLY" ;;
		esac
	done < "$file"
}
load_conf
if [ -z "$BASE_BRANCH" ]; then
	# Only when the settings don't say: one git call more.
	BASE_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
	BASE_BRANCH="${BASE_BRANCH#origin/}"
	[ -n "$BASE_BRANCH" ] || BASE_BRANCH="main"
fi
[ -n "$GENERATOR_BOT" ] || GENERATOR_BOT="github-actions[bot]"
SKIP=()
read -r -a SKIP <<< "$SKIP_PATHS" || true

if [ -n "$REF" ]; then
	BRANCH="${REF#refs/heads/}"
	REV="$(git rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}")" || {
		echo "[pr-ready] No local branch named $BRANCH." >&2
		exit 3
	}
else
	case "$HEAD_REF" in
		refs/heads/*) BRANCH="${HEAD_REF#refs/heads/}" ;;
		*) BRANCH="" ;;
	esac
	REV="HEAD"
fi
STATE="$STATE_DIR/$BRANCH.json"
LOG="$STATE_DIR/$BRANCH.findings.md"
SCANS="$STATE_DIR/$BRANCH.scanned"

on_base() { [ -z "$BRANCH" ] || [ "$BRANCH" = "$BASE_BRANCH" ]; }

needs_review() {   # needs_review <path>
	local p
	if [ "${#SKIP[@]}" -gt 0 ]; then
		for p in "${SKIP[@]}"; do
			case "$p" in
				*/) case "$1" in "$p"*) return 1 ;; esac ;;
				*) [ "$1" != "$p" ] || return 1 ;;
			esac
		done
	fi
	case "$1" in
		.claude/* | */.claude/* | CLAUDE.md | */CLAUDE.md | CLAUDE.local.md | */CLAUDE.local.md | AGENTS.md | */AGENTS.md) return 0 ;;
		docs/* | *.md | CHANGELOG | CHANGELOG.* | */CHANGELOG | */CHANGELOG.*) return 1 ;;
	esac
	return 0
}

# Merge base with the PR's base branch; empty when there is none (no origin/$BASE_BRANCH or
# $BASE_BRANCH in this clone, or unrelated history).
merge_base() {
	local ref
	for ref in "origin/$BASE_BRANCH" "$BASE_BRANCH"; do
		git merge-base "$ref" "$REV" 2>/dev/null && return 0
	done
	return 0
}

# LIST: "<base blob> <blob> <path>" per committed file change that needs review, one per line. One
# git call: the raw diff carries both blobs (all zeros for a file added or deleted). NO_BASE is 1
# when there's no merge base, so the changes can't be listed.
LIST="" NO_BASE=0
load_list() {
	local mb meta path
	mb="$(merge_base)"
	if [ -z "$mb" ]; then NO_BASE=1; return 0; fi
	while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
		needs_review "$path" || continue
		read -r _ _ old new _ <<< "$meta"   # :<old mode> <new mode> <old blob> <new blob> <status>
		LIST="$LIST$old $new $path"$'\n'
	done < <(git diff --raw --no-abbrev --no-renames -z "$mb" "$REV" --)
}

esc() {   # esc <text>: sets REPLY to the text escaped for a JSON string
	REPLY="${1//\\/\\\\}"
	REPLY="${REPLY//\"/\\\"}"
	REPLY="${REPLY//$'\t'/\\t}"
	REPLY="${REPLY//$'\r'/}"
	REPLY="${REPLY//$'\n'/\\n}"
}
unesc() {   # unesc <JSON string body>: sets REPLY to the text
	REPLY="${1//\\\\/$'\001'}"
	REPLY="${REPLY//\\\"/\"}"
	REPLY="${REPLY//\\t/$'\t'}"
	REPLY="${REPLY//\\n/$'\n'}"
	REPLY="${REPLY//$'\001'/\\}"
}

# The state file is JSON in a fixed layout (written below); this reads that layout back.
REVIEWED="" PASSES="" RUNS=""
FILE_RE='^    \["([0-9a-f]+)", "([0-9a-f]+)", "(.*)"\],?$'
NUM_RE='^  "(passes|runs)": ([0-9]+),?$'
load_state() {
	local line
	[ -f "$STATE" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		if [[ $line =~ $FILE_RE ]]; then
			unesc "${BASH_REMATCH[3]}"
			REVIEWED="$REVIEWED${BASH_REMATCH[1]} ${BASH_REMATCH[2]} $REPLY"$'\n'
		elif [[ $line =~ $NUM_RE ]]; then
			if [ "${BASH_REMATCH[1]}" = passes ]; then PASSES="${BASH_REMATCH[2]}"; else RUNS="${BASH_REMATCH[2]}"; fi
		fi
	done < "$STATE"
}

# compare <listing> <covered>: PENDING, the listing's lines not in <covered>; TOTAL and NPENDING,
# line counts.
PENDING="" TOTAL=0 NPENDING=0
compare() {
	local line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		TOTAL=$((TOTAL + 1))
		case $'\n'"$2" in
			*$'\n'"$line"$'\n'*) ;;
			*) PENDING="$PENDING$line"$'\n'; NPENDING=$((NPENDING + 1)) ;;
		esac
	done <<< "$1"
}

# NEXT: the next commit's changes in the LIST format, against HEAD. Staged changes, or with --all
# what `git commit -a` would take, read from a throwaway copy of the index with every tracked
# file's changes added (the same filters as `git add`, so CRLF copies hash like their blobs).
NEXT=""
load_next() {
	local meta path index use_tmp=0
	if [ "$ALL" = 1 ]; then
		# Next to the real index, by the path git gives: git can read it back on every platform.
		index="$(git rev-parse --git-path index)"
		TMP_INDEX="$index.next-commit.$$"   # removed on exit
		if cp -f "$index" "$TMP_INDEX" 2>/dev/null && GIT_INDEX_FILE="$TMP_INDEX" git add -u -- . 2>/dev/null; then
			use_tmp=1
		else
			echo "[review] Couldn't work out what git commit -a would take; using the staged changes." >&2
		fi
	fi
	while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
		needs_review "$path" || continue
		read -r _ _ old new _ <<< "$meta"
		NEXT="$NEXT$old $new $path"$'\n'
	done < <(
		if [ "$use_tmp" = 1 ]; then
			GIT_INDEX_FILE="$TMP_INDEX" git diff --cached --raw --no-abbrev --no-renames -z --
		else
			git diff --cached --raw --no-abbrev --no-renames -z --
		fi
	)
	drop_taken_as_is
}

# AT: "<path>\037<blob>" for each of the listing's paths that <rev> has. Returns 1, with AT empty,
# when git can't say (no such commit, say), so the caller can keep what it has.
AT=""
blobs_at() {   # blobs_at <rev> <listing in the LIST format>
	local line path seen=$'\n' entry f rc=0
	local -a paths=()
	AT=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		path="${line#* * }"
		case "$seen" in *$'\n'"$path"$'\n'*) continue ;; esac   # once each: the scan record repeats paths
		seen="$seen$path"$'\n'
		paths+=("$path")
	done <<< "$2"
	[ "${#paths[@]}" -gt 0 ] || return 0
	while IFS= read -r -d '' entry; do   # <mode> <type> <blob>TAB<path>, or the marker below
		case "$entry" in *$'\t'*) ;; *) rc=1; continue ;; esac
		f="${entry%%$'\t'*}"
		AT="$AT${entry#*$'\t'}"$'\037'"${f##* }"$'\n'
	done < <(git ls-tree -z "$1" -- "${paths[@]}" 2>/dev/null || printf 'git ls-tree failed\0')
	[ "$rc" = 0 ] || AT=""
	return "$rc"
}

# A commit that concludes a merge, cherry-pick or revert brings in changes made elsewhere. Drop the
# files it takes exactly as the other side has them; conflict resolutions and any other edits stay.
drop_taken_as_is() {
	local f rev="" line rest new path keep=""
	for f in MERGE_HEAD CHERRY_PICK_HEAD; do
		if [ -f "$(git rev-parse --git-path "$f")" ]; then rev="$f"; break; fi
	done
	# A revert takes the content from before the reverted commit.
	[ -n "$rev" ] || [ ! -f "$(git rev-parse --git-path REVERT_HEAD)" ] || rev="REVERT_HEAD^"
	[ -n "$rev" ] && [ -n "$NEXT" ] || return 0
	blobs_at "$rev" "$NEXT" || return 0   # git can't say what the other side has: keep every change
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		rest="${line#* }"
		new="${rest%% *}"
		path="${rest#* }"
		case $'\n'"$AT" in
			*$'\n'"$path"$'\037'"$new"$'\n'*) continue ;;   # the other side's content
			*$'\n'"$path"$'\037'*) ;;
			*) case "$new" in *[!0]*) ;; *) continue ;; esac ;;   # deleted, as on the other side
		esac
		keep="$keep$line"$'\n'
	done <<< "$NEXT"
	NEXT="$keep"
}
SCANNED=""
load_scans() { [ ! -s "$SCANS" ] || SCANNED="$(cat "$SCANS")"$'\n'; }

# KEPT: the recorded scans that can still match a commit's changes, those made against the file HEAD
# has now (or, for a new file, made while HEAD has none). Once a commit moves HEAD past a file, its
# older scans never match again. When git can't say what HEAD has, every scan is kept.
KEPT=""
keep_current_scans() {
	local line path
	KEPT=""
	blobs_at HEAD "$SCANNED" || { KEPT="$SCANNED"; return 0; }
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		path="${line#* * }"
		case $'\n'"$AT" in
			*$'\n'"$path"$'\037'"${line%% *}"$'\n'*) ;;   # made against the file at HEAD
			*$'\n'"$path"$'\037'*) continue ;;            # HEAD has another version
			*) case "${line%% *}" in *[!0]*) continue ;; esac ;;   # HEAD has none: keep only a new file's
		esac
		KEPT="$KEPT$line"$'\n'
	done <<< "$SCANNED"
}

status_line() {
	if on_base; then
		echo "on ${BRANCH:-a detached HEAD}: nothing to gate"
	elif [ "$NO_BASE" = 1 ]; then
		echo "$BRANCH has no merge base with origin/$BASE_BRANCH or $BASE_BRANCH, so its changes can't be listed; run git fetch origin $BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH (in a shallow clone, git fetch --unshallow) and check again"
	elif [ "$TOTAL" = 0 ]; then
		echo "nothing on $BRANCH needs review (no committed changes outside docs and skip_paths)"
	elif [ ! -f "$STATE" ]; then
		echo "no /pr-ready review on record for $BRANCH ($TOTAL changed file(s) need review)"
	elif [ "$NPENDING" = 0 ]; then
		echo "the last /pr-ready review covers all $TOTAL changed file(s) on $BRANCH (${PASSES:-0} pass(es) used)"
	else
		echo "$NPENDING of $TOTAL changed file(s) on $BRANCH aren't covered by the last /pr-ready review (${PASSES:-0} pass(es) used)"
	fi
}

list_uncommitted() {   # paths that need review and differ from HEAD, or are untracked
	local entry
	while IFS= read -r -d '' entry; do
		needs_review "${entry:3}" && printf '%s\n' "${entry:3}"
	done < <(git status --porcelain=v1 -z --no-renames --untracked-files=all)
	return 0
}
listed() {   # after load_list: with no merge base, say why on stderr and exit 4 (nothing is listed)
	[ "$NO_BASE" = 1 ] || return 0
	echo "[pr-ready] $(status_line)." >&2
	exit 4
}

# The note every review appends to its instructions: the skipped paths, then the repository's own.
review_note() {
	local note=""
	if [ -n "$SKIP_PATHS" ]; then
		note="Repository note: files under $SKIP_PATHS are generated or out of scope, so report no findings on them; read the whole diff rather than excluding paths."
	fi
	REPLY="$note${note:+${REVIEW_NOTE:+ }}$REVIEW_NOTE"
}
show_config() {   # show_config [<key>]
	local k v
	for k in base_branch skip_paths generated_paths generator_bot lint_command doc_gate documenter review_note; do
		case "$k" in
			base_branch) v="$BASE_BRANCH" ;;
			skip_paths) v="$SKIP_PATHS" ;;
			generated_paths) v="$GENERATED_PATHS" ;;
			generator_bot) v="$GENERATOR_BOT" ;;
			lint_command) v="$LINT_COMMAND" ;;
			doc_gate) v="$DOC_GATE" ;;
			documenter) v="$DOCUMENTER" ;;
			review_note) review_note; v="$REPLY" ;;
		esac
		if [ -z "${1:-}" ]; then
			printf '%s=%s\n' "$k" "$v"
		elif [ "$1" = "$k" ]; then
			printf '%s\n' "$v"
			return 0
		fi
	done
	if [ -n "${1:-}" ]; then
		echo "[pr-ready] No setting named $1." >&2
		exit 2
	fi
}

case "$cmd" in
	files)
		load_list; listed
		printf '%s' "$LIST"
		;;
	scope)
		load_list; listed; load_state; compare "$LIST" "$REVIEWED"
		printf '%s' "$PENDING" | while IFS= read -r line; do printf '%s\n' "${line#* * }"; done
		;;
	uncommitted)
		list_uncommitted
		;;
	check)
		on_base && exit 0
		load_list
		if [ "$NO_BASE" = 1 ]; then
			[ "$EXPLAIN" = 1 ] && status_line
			exit 4
		fi
		[ -n "$LIST" ] || exit 0
		load_state; compare "$LIST" "$REVIEWED"
		[ "$NPENDING" = 0 ] && exit 0
		[ "$EXPLAIN" = 1 ] && status_line
		exit 1
		;;
	status)
		on_base || { load_list; load_state; compare "$LIST" "$REVIEWED"; }
		status_line
		;;
	next)
		load_next
		printf '%s' "$NEXT"
		;;
	scan-scope)
		load_next; load_scans; compare "$NEXT" "$SCANNED"
		printf '%s' "$PENDING" | while IFS= read -r line; do printf '%s\n' "${line#* * }"; done
		;;
	scan-check)
		on_base && exit 0
		load_next
		[ -n "$NEXT" ] || exit 0
		load_scans; compare "$NEXT" "$SCANNED"
		[ "$NPENDING" = 0 ] && exit 0
		[ "$EXPLAIN" = 1 ] && echo "$NPENDING of $TOTAL file(s) in this commit haven't had the pre-commit scan"
		exit 1
		;;
	scan-write)
		if on_base; then
			echo "[review] Not recording a scan: ${BRANCH:-a detached HEAD} isn't a feature branch." >&2
			exit 1
		fi
		load_next; load_scans; compare "$NEXT" "$SCANNED"
		mkdir -p "${SCANS%/*}"
		# New scans are appended. Scans of versions HEAD has moved past are then dropped, so the record
		# doesn't grow for the life of the branch; the record is replaced only if no other scan-write has
		# appended to it since it was read here. One appending in the instant between that check and the
		# replace would lose its scans, which only brings a reminder back.
		printf '%s' "$PENDING" >> "$SCANS"
		SCANNED=""; load_scans; keep_current_scans
		if [ "$KEPT" != "$SCANNED" ]; then
			TMP_SCANS="$SCANS.tmp.$$"   # removed on exit
			printf '%s' "$KEPT" > "$TMP_SCANS"
			[ "$(cat "$SCANS")"$'\n' != "$SCANNED" ] || mv -f "$TMP_SCANS" "$SCANS"
		fi
		echo "[review] Recorded the pre-commit scan of $TOTAL file(s) on $BRANCH ($NPENDING new)."
		;;
	passes)
		load_state
		echo "${PASSES:-0}"
		;;
	write)
		if on_base; then
			echo "[pr-ready] Not recording a review: ${BRANCH:-a detached HEAD} isn't a feature branch." >&2
			exit 1
		fi
		load_list; load_state
		if [ "$NO_BASE" = 1 ]; then
			echo "[pr-ready] Not recording a review: $(status_line)." >&2
			exit 1
		fi
		add=0
		notes=""
		for kv in "$@"; do
			case "$kv" in *=*) ;; *) continue ;; esac
			key="${kv%%=*}"
			val="${kv#*=}"
			[[ $key =~ ^[A-Za-z0-9_]+$ ]] || continue
			if [ "$key" = passes ]; then
				[[ $val =~ ^[0-9]+$ ]] && add="$val"
				continue
			fi
			esc "$val"
			notes="${notes:+$notes, }\"$key\": \"$REPLY\""
		done
		entries=""
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			rest="${line#* }"
			esc "${rest#* }"
			entries="${entries:+$entries,
}    [\"${line%% *}\", \"${rest%% *}\", \"$REPLY\"]"
		done <<< "$LIST"
		mkdir -p "${STATE%/*}"
		esc "$BRANCH"
		{
			echo "{"
			echo "  \"branch\": \"$REPLY\","
			echo "  \"reviewed_sha\": \"$(git rev-parse "$REV")\","
			echo "  \"base_sha\": \"$(merge_base)\","
			echo "  \"reviewed_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
			echo "  \"passes\": $((${PASSES:-0} + add)),"
			echo "  \"runs\": $((${RUNS:-0} + 1)),"
			echo "  \"last_run\": {$notes},"
			echo "  \"files\": ["
			[ -z "$entries" ] || printf '%s\n' "$entries"
			echo "  ]"
			echo "}"
		} > "$STATE.tmp"
		mv -f "$STATE.tmp" "$STATE"
		n=0
		while IFS= read -r line; do [ -z "$line" ] || n=$((n + 1)); done <<< "$LIST"
		echo "[pr-ready] Recorded a review of $n changed file(s) on $BRANCH."
		left="$(list_uncommitted)"
		if [ -n "$left" ]; then
			echo "[pr-ready] Uncommitted files aren't part of it; committing them needs another review:" >&2
			while IFS= read -r p; do printf '  %s\n' "$p"; done <<< "$left" >&2
		fi
		;;
	log)
		if on_base; then
			echo "[pr-ready] Not logging: ${BRANCH:-a detached HEAD} isn't a feature branch." >&2
			exit 1
		fi
		mkdir -p "${LOG%/*}"
		{
			printf '## %s (%s, at %s)\n\n' "${1:-Findings}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse --short HEAD)"
			cat
			printf '\n'
		} >> "$LOG"
		echo "[pr-ready] Logged to $LOG"
		;;
	findings)
		[ ! -f "$LOG" ] || cat "$LOG"
		;;
	reset)
		on_base || rm -f "$STATE" "$LOG" "$SCANS"
		echo "[pr-ready] Cleared the review state for ${BRANCH:-a detached HEAD}."
		;;
	config)
		show_config "${1:-}"
		;;
	*)
		echo "usage: $0 {files|scope|uncommitted|check [--explain]|status|passes|write [key=value...]|log <title>|findings|reset|config [<key>]} [--ref <branch>]" >&2
		echo "       $0 {next|scan-scope|scan-check [--explain]|scan-write} [--all]" >&2
		exit 2
		;;
esac
