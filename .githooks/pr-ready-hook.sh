#!/usr/bin/env bash
# pr-ready-hook: the review reminders git hooks give. Both are warnings: they never fail the commit
# or the push.
#
#   pr-ready-hook.sh pre-commit   the commit's changes haven't had /review-before-commit, a quick,
#                                 low-level /review-db pass over the commit. Here rather than in a
#                                 Claude Code hook: git runs it with the commit's own index (git add
#                                 earlier on the same command line, -a, pathspecs), and Claude Code
#                                 sees the output of its own commits.
#   pr-ready-hook.sh pre-push     a branch being pushed hasn't been through /pr-ready. Pushing work
#                                 in progress is fine: the gate that matters is on PR creation
#                                 (pr-ready-gate.sh, for Claude Code sessions), and the CI review
#                                 comments on every PR regardless. Reads git's pre-push lines on
#                                 stdin; with none (another hook read them first), it checks the
#                                 current branch.
#
# .githooks/pre-commit and .githooks/pre-push call this. A repository with hooks of its own calls it
# from them (install.sh adds the call).

set -u

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$HOOK_DIR/pr-ready-stamp.sh"
ZERO="0000000000000000000000000000000000000000"

pre_commit() {
	local status
	if ! status="$(bash "$STAMP" scan-check --explain 2>/dev/null)" && [ -n "$status" ]; then
		echo "[review] $status (warning only, the commit goes ahead)."
		echo "  Before the next commit, run /review-before-commit in Claude Code: a quick, low-effort scan of the commit."
	fi
	return 0
}

remind_push() {   # remind_push <branch>
	local status
	status="$(bash "$STAMP" check --explain --ref "$1" 2>/dev/null)" && return 0
	echo "[pr-ready] ${status:-$1 has not been through /pr-ready}." >&2
	echo "  Push allowed. Run /pr-ready in Claude Code before you open the PR or mark it ready." >&2
}

pre_push() {
	local base local_ref local_sha remote_ref branch seen=0
	base="$(bash "$STAMP" config base_branch 2>/dev/null)" || base=""
	while read -r local_ref local_sha remote_ref _; do
		seen=1
		[ "$local_sha" = "$ZERO" ] && continue                         # deleting a remote branch
		case "$remote_ref" in "refs/heads/${base:-main}" | refs/tags/*) continue ;; esac
		case "$local_ref" in
			refs/heads/*) branch="${local_ref#refs/heads/}" ;;
			HEAD) branch="$(git symbolic-ref --quiet --short HEAD)" || continue ;;
			*) continue ;;
		esac
		# Only a local branch's tip has review state (not `git push origin <sha>:<branch>`).
		[ "$(git rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)" = "$local_sha" ] || continue
		remind_push "$branch"
	done
	if [ "$seen" = 0 ]; then
		branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 0
		[ "$branch" = "${base:-main}" ] || remind_push "$branch"
	fi
	return 0
}

case "${1:-}" in
	pre-commit) pre_commit ;;
	pre-push) pre_push ;;
	*) echo "usage: $0 {pre-commit|pre-push}" >&2; exit 2 ;;
esac
exit 0
