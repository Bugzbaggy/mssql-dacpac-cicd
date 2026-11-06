#!/usr/bin/env bash
# bootstrap: turn on this repository's git hooks for this clone (core.hooksPath=.githooks). Run it
# once after cloning; running it again changes nothing. bootstrap.cmd does the same from cmd.exe.
#
# Claude Code sessions enrol a clone on their own (pr-ready-bootstrap.sh), but quietly, and only a
# clone with no hooks of its own. This one is for people, and it says what is in the way:
#   exit 0  the hooks are on (now, or already)
#   exit 1  not a git work tree, or core.hooksPath already names another folder (a hook framework);
#           the message gives the command that switches it to .githooks

set -u
say() { echo "[hooks] $*"; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { say "Not inside a git work tree." >&2; exit 1; }
cd "$ROOT" || exit 1

current="$(git config --local --get core.hooksPath 2>/dev/null || true)"
case "$current" in
	.githooks | .githooks/ | ./.githooks | ./.githooks/)
		say "Already on (core.hooksPath=$current)."
		exit 0 ;;
	'') ;;
	*)
		say "core.hooksPath is $current, so nothing changed. To use this repository's hooks instead:" >&2
		say "  git config --local --replace-all core.hooksPath .githooks" >&2
		exit 1 ;;
esac

# Hooks a setting from outside this clone pointed at, and any in .git/hooks, stop running once
# core.hooksPath is set here.
inherited="$(git config --get core.hooksPath 2>/dev/null || true)"
[ -z "$inherited" ] || say "Note: this replaces the hooks in $inherited (set outside this clone) for this clone."
old="$(git rev-parse --git-path hooks)"
for h in "$old"/*; do
	[ -f "$h" ] || continue
	case "$h" in *.sample) continue ;; esac
	say "Note: $h stops running. Call it from the matching .githooks hook if you still need it."
done

git config --local core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push .githooks/commit-msg .githooks/*.sh .githooks/analyze_sql.py 2>/dev/null || true
say "On for this clone (core.hooksPath=.githooks): the doc gate, nitsql and the review reminders run at commit and push."
