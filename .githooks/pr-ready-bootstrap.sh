#!/usr/bin/env bash
# pr-ready-bootstrap: points this clone's git hooks at .githooks/, so the review reminders
# (pr-ready-hook.sh) run. .claude/settings.json runs it at the start of every Claude Code session,
# which enrols a fresh clone without anyone running install.sh. Idempotent.
#
# It changes nothing when the clone already has hooks of its own: core.hooksPath set to another
# folder (a hook framework), or hooks in .git/hooks, which core.hooksPath would switch off. Run
# install.sh in those clones: it adds the reminder call to the existing hooks instead.
#
#   --quiet   print only when it changes something

set -u
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" = 1 ] || echo "[pr-ready] $*"; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { say "Not inside a git repository."; exit 0; }
cd "$ROOT" || exit 0
[ -f .githooks/pr-ready-hook.sh ] || { say "No .githooks/pr-ready-hook.sh in this repository."; exit 0; }

current="$(git config --local --get core.hooksPath 2>/dev/null || true)"
case "$current" in
	.githooks | .githooks/ | ./.githooks | ./.githooks/)
		say "Already enrolled (core.hooksPath=$current)."
		exit 0 ;;
	'') ;;
	*)
		say "core.hooksPath is $current, so it is left alone. Run install.sh to add the review reminders to those hooks."
		exit 0 ;;
esac

hooks="$(git rev-parse --git-path hooks 2>/dev/null)"
for h in pre-commit pre-push; do
	if [ -n "$hooks" ] && [ -f "$hooks/$h" ]; then
		say "$hooks/$h exists, and core.hooksPath would switch it off, so nothing changed. Run install.sh to add the review reminders to it."
		exit 0
	fi
done

git config --local core.hooksPath .githooks
chmod +x .githooks/pre-commit .githooks/pre-push .githooks/pr-ready-*.sh 2>/dev/null || true
echo "[pr-ready] Git hooks enabled for this clone (core.hooksPath=.githooks): reminders to run /review-before-commit and /pr-ready."
