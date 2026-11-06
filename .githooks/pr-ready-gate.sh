#!/usr/bin/env bash
# pr-ready-gate: the pre-PR gate. A Claude Code PreToolUse hook registered in .claude/settings.json:
# for the Bash tool, `if` filters start it only for the commands below; it also runs for GitHub MCP
# servers' create_pull_request and update_pull_request tools. It reads the hook's JSON on stdin.
#
#   gh pr create (or new), gh pr ready,        denied until /pr-ready has reviewed the PR branch's
#   MCP create_pull_request,                   committed changes (pr-ready-stamp.sh check); the
#   MCP update_pull_request with draft: false  reason tells Claude to run /pr-ready first
#   git commit or push --no-verify,            turned into a question, so a session can't skip the
#   git commit -n, git -c core.hooksPath=...   repo's git hooks without the user agreeing
#
# Not gated: draft PRs until they're marked ready (gh pr create --draft, draft: true), branches
# whose changes need no review (docs, the skip_paths in .sql-ready.conf), a PR title with
# [skip-review] in it (hotfixes, comment-only re-triggers; reviewers see the marker), other clones
# and repositories, and PR_READY_GATE=warn (a reminder instead of a denial) or off (no gate). Nor is
# a push: the pre-push hook (pr-ready-hook.sh pre-push) reminds about each pushed branch that hasn't
# been through /pr-ready, in Claude Code too, from the refs git hands it. PRs opened outside Claude
# Code aren't gated: pre-push reminds people, and the CI review (claude-code-review.yml) is the
# backstop for every PR.
#
# Commands are split into shell words first, so text inside a quoted commit message or PR body, a
# heredoc or a # comment is never mistaken for a command or a flag. Bash builtins only up to the git
# calls (process starts are slow on Windows), and a hook that fails or times out lets the call
# through, so the CI review stays the backstop.
#
# Output: nothing (allow), or one line of hook JSON: permissionDecision deny or ask, or
# additionalContext (a reminder that leaves the decision to the user's settings). Exit code 0.

set -u
[ "${PR_READY_GATE:-on}" = "off" ] && exit 0

IFS= read -r -d '' INPUT || true
# Claude Code versions without `if` filters run this before every Bash call: leave as soon as the
# call can't be one of the commands above.
case "$INPUT" in *gh*|*git*|*pull_request*) ;; *) exit 0 ;; esac

# ---- the hook JSON ------------------------------------------------------------------------------

# A string field (the first one with that name), unescaped well enough for matching. Sets REPLY;
# returns 1 when the field isn't there.
json_field() {
	local re="\"$1\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\""
	REPLY=""
	[[ $INPUT =~ $re ]] || return 1
	REPLY="${BASH_REMATCH[1]//\\\\/$'\001'}"
	REPLY="${REPLY//\\\"/\"}"
	REPLY="${REPLY//\\n/$'\n'}"
	REPLY="${REPLY//\\t/$'\t'}"
	REPLY="${REPLY//\\r/}"
	REPLY="${REPLY//\\\//\/}"
	REPLY="${REPLY//$'\001'/\\}"
}
json_scalar() {   # json_scalar <name>: sets REPLY to a true, false or number field, or ""
	local re="\"$1\"[[:space:]]*:[[:space:]]*(true|false|[0-9]+)"
	REPLY=""
	[[ $INPUT =~ $re ]] && REPLY="${BASH_REMATCH[1]}"
	return 0
}
json_escape() { local s="${1//\\/\\\\}"; s="${s//$'\n'/ }"; printf '%s' "${s//\"/\\\"}"; }
decide() {   # decide <deny|ask> <reason>
	printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
		"$1" "$(json_escape "$2")"
	exit 0
}
remind() {   # context for Claude; the permission decision stays with the user's settings
	printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$(json_escape "$1")"
	exit 0
}

# ---- this clone and its review state ------------------------------------------------------------

START_DIR="$PWD"
HOOK_DIR="${BASH_SOURCE[0]%[/\\]*}"   # Claude Code on Windows passes a C:\... project path
[ "$HOOK_DIR" != "${BASH_SOURCE[0]}" ] || HOOK_DIR="."
cd "$HOOK_DIR" 2>/dev/null && HOOK_DIR="$PWD"
cd "$START_DIR" 2>/dev/null || true
stamp() { bash "$HOOK_DIR/pr-ready-stamp.sh" "$@"; }

common_dir() {   # common_dir <dir>: the physical path of its repository's shared git dir
	local d
	d="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$d" ] || return 1
	(cd "$1" && cd "$d" && pwd -P)
}
in_this_clone() {   # exits (letting the call through) unless the command runs in this clone
	local here ours
	if json_field cwd && [ -n "$REPLY" ]; then cd "$REPLY" 2>/dev/null || exit 0; fi
	here="$(common_dir .)" || exit 0
	ours="$(common_dir "$HOOK_DIR")" || exit 0
	[ "$here" = "$ours" ] || exit 0
}
is_this_repo() {   # is_this_repo <[owner/]repo>: does it name this clone's GitHub repository (or nothing)?
	local want r url seen=0 rc=1
	[ -n "$1" ] || return 0
	want="${1%"${1##*[!/]}"}"; want="${want%.git}"; want="${want##*/}"
	# The name decides, not the owner, so a fork clone's PR to the upstream repository is gated:
	# origin's name, or upstream's when the fork was renamed. git remote get-url applies
	# url.<base>.insteadOf, and --all lists every URL a remote has.
	shopt -s nocasematch
	for r in origin upstream; do
		while IFS= read -r url; do
			[ -n "$url" ] && [ "$url" != "$r" ] || continue   # a remote with no URL is given its own name
			seen=1
			url="${url%"${url##*[!/]}"}"; url="${url%.git}"
			[[ ${url##*[/\\:]} == "$want" ]] && { rc=0; break 2; }
		done < <(cd "$HOOK_DIR" && git remote get-url --all "$r" 2>/dev/null)
	done
	shopt -u nocasematch
	[ "$seen" = 1 ] || return 0   # no remote to tell by
	return "$rc"
}
pr_branch() {   # pr_branch <PR number, URL or branch> [owner/repo]: sets REPLY to the PR's branch
	REPLY=""
	case "$1" in
		'') return 0 ;;   # the current branch
		[0-9]* | '#'[0-9]* | http*://*)
			REPLY="$(cd "$HOOK_DIR" && gh pr view "${1#\#}" ${2:+--repo "$2"} --json headRefName --jq .headRefName 2>/dev/null)" &&
				[ -n "$REPLY" ] ;;
		*) REPLY="$1" ;;
	esac
}

skip_marker() {   # skip_marker <PR title>: let the PR through when the title carries [skip-review]
	case "$1" in
		*"[skip-review]"*) remind "Pre-PR gate skipped: the PR title has [skip-review], which reviewers will see. The CI review still runs on the PR." ;;
	esac
}
unchecked() {   # unchecked <what>
	remind "Pre-PR gate: couldn't tell which branch $1 is on, so couldn't check whether it has been through /pr-ready. If it hasn't, suggest running /pr-ready before the PR is reviewed."
}
gate() {   # gate <how to keep it a draft> [--ref <branch>]: allow when reviewed, deny otherwise
	local draft_hint="$1" rc status
	shift
	status="$(stamp check --explain "$@" 2>/dev/null)"
	rc=$?
	[ "$rc" = 0 ] && exit 0
	if [ "$rc" != 1 ]; then
		remind "Pre-PR gate: couldn't check whether this branch has been through /pr-ready (${status:-pr-ready-stamp.sh exited $rc}). If it hasn't, suggest running /pr-ready before the PR is reviewed."
	fi
	if [ "${PR_READY_GATE:-on}" = "warn" ]; then
		remind "Pre-PR gate (warn mode): $status. Suggest running /pr-ready before the PR is reviewed; the CI review only comments."
	fi
	decide deny "Pre-PR gate: $status. Run the /pr-ready skill, then retry. If the PR isn't ready for review yet, $draft_hint. Only if the developer asks to skip the review (a hotfix, a comment-only change), put [skip-review] in the PR title. The developer can also set PR_READY_GATE=warn or off."
}

# ---- GitHub MCP tools ---------------------------------------------------------------------------

json_field tool_name
TOOL="$REPLY"
case "$TOOL" in
	mcp__*__create_pull_request | mcp__*__update_pull_request)
		cd "$HOOK_DIR" || exit 0
		json_field owner; owner="$REPLY"
		json_field repo; repo="$REPLY"
		is_this_repo "$repo" || exit 0
		json_scalar draft; draft="$REPLY"
		if [ "${TOOL##*__}" = create_pull_request ]; then
			[ "$draft" = true ] && exit 0
			json_field title && skip_marker "$REPLY"
			json_field head
			gate "create it with draft: true" ${REPLY:+--ref "${REPLY##*:}"}
		fi
		[ "$draft" = false ] || exit 0   # only marking a draft ready for review is gated
		json_scalar pullNumber
		pr="$REPLY"
		pr_branch "$pr" "${owner:+$owner/}$repo" || unchecked "PR $pr"
		gate "leave it a draft" ${REPLY:+--ref "$REPLY"}
		;;
esac

# ---- Bash: split the command into shell words ---------------------------------------------------

SEP=$'\037'   # stands for ; & | ( ) and newline, which end a simple command
WORDS=()
SUBSTS=()     # the $( ... ) command lines inside the command, looked at after it
add_word() { [ "$have" = 1 ] && WORDS+=("$w"); w=""; have=0; }

# The helpers below work on split_words' s, n and i.

# At s[i] = the first '<' of << or <<-: note the heredoc's delimiter in HD_DELIM (HD_DASH for <<-),
# leaving i on the delimiter's last character.
read_heredoc_op() {
	local qd
	i=$((i + 2)); HD_DASH=0
	if [ "${s:i:1}" = '-' ]; then HD_DASH=1; i=$((i + 1)); fi
	while [ "${s:i:1}" = ' ' ] || [ "${s:i:1}" = $'\t' ]; do i=$((i + 1)); done
	HD_DELIM=""
	case "${s:i:1}" in
		"'" | '"')
			qd="${s:i:1}"; i=$((i + 1))
			while [ "$i" -lt "$n" ] && [ "${s:i:1}" != "$qd" ]; do HD_DELIM="$HD_DELIM${s:i:1}"; i=$((i + 1)); done ;;
		*)
			while [ "$i" -lt "$n" ]; do
				case "${s:i:1}" in ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;; esac
				[ "${s:i:1}" = '\' ] && i=$((i + 1))
				HD_DELIM="$HD_DELIM${s:i:1}"; i=$((i + 1))
			done
			i=$((i - 1)) ;;
	esac
}
# At s[i] = a newline while a heredoc is pending: skip its body, leaving i on the newline that ends
# the delimiter line (or past the end).
skip_heredoc_body() {
	local j line
	while [ "$i" -lt "$n" ]; do
		j=$((i + 1)); line="${s:j}"; line="${line%%$'\n'*}"; i=$((j + ${#line}))
		if [ "$HD_DASH" = 1 ]; then while [ "${line:0:1}" = $'\t' ]; do line="${line:1}"; done; fi
		[ "$line" = "$HD_DELIM" ] && break
	done
	HD_DELIM=""
}
# At s[i] = the '$' of "$(": move i to the matching ')'. Nested parentheses and substitutions, quotes,
# here-strings and heredoc bodies inside it (git commit -m "$(cat <<'EOF' ... EOF)") don't end it.
skip_substitution() {
	local depth=0 c q2="" HD_DELIM="" HD_DASH=0
	i=$((i + 1))   # onto the '('
	while [ "$i" -lt "$n" ]; do
		c="${s:i:1}"
		if [ -n "$q2" ]; then
			if [ "$c" = "$q2" ]; then
				q2=""
			elif [ "$q2" = '"' ] && [ "$c" = '\' ]; then
				i=$((i + 1))
			elif [ "$q2" = '"' ] && [ "$c" = '$' ] && [ "${s:i+1:1}" = '(' ]; then
				skip_substitution
			fi
		else
			case "$c" in
				"'" | '"') q2="$c" ;;
				'\') i=$((i + 1)) ;;
				'(') depth=$((depth + 1)) ;;
				')') depth=$((depth - 1)); [ "$depth" -gt 0 ] || return 0 ;;
				'<')
					if [ "${s:i:3}" = '<<<' ]; then i=$((i + 2))
					elif [ "${s:i:2}" = '<<' ]; then read_heredoc_op
					fi ;;
				$'\n') [ -z "$HD_DELIM" ] || skip_heredoc_body ;;
			esac
		fi
		i=$((i + 1))
	done
}

split_words() {   # split_words <command>: WORDS, roughly as bash splits them
	local s="$1" n=${#1} i=0 c w="" have=0 q="" start rest HD_DELIM="" HD_DASH=0
	while [ "$i" -lt "$n" ]; do
		c="${s:i:1}"
		if [ "$c" = '$' ] && [ "${s:i+1:1}" = '(' ] && [ "$q" != "'" ]; then   # $( ... ): part of the word,
			start=$i                                                           # and a command line of its own
			skip_substitution
			w="$w${s:start:i-start+1}"; have=1
			SUBSTS+=("${s:start+2:i-start-2}")
		elif [ "$c" = '`' ] && [ "$q" != "'" ]; then   # `...`, the old form of $( ... )
			start=$i
			i=$((i + 1))
			while [ "$i" -lt "$n" ] && [ "${s:i:1}" != '`' ]; do
				[ "${s:i:1}" = '\' ] && i=$((i + 1))
				i=$((i + 1))
			done
			w="$w${s:start:i-start+1}"; have=1
			SUBSTS+=("${s:start+1:i-start-1}")
		elif [ -n "$q" ]; then   # inside quotes: everything is part of the word
			if [ "$c" = "$q" ]; then
				q=""
			elif [ "$q" = '"' ] && [ "$c" = '\' ]; then
				i=$((i + 1)); w="$w${s:i:1}"
			else
				w="$w$c"
			fi
		else
			case "$c" in
				"'" | '"') q="$c"; have=1 ;;
				'\') i=$((i + 1)); [ "${s:i:1}" = $'\n' ] || { w="$w${s:i:1}"; have=1; } ;;
				' ' | $'\t') add_word ;;
				'#')   # at the start of a word, a comment to the end of the line
					if [ "$have" = 1 ]; then
						w="$w$c"
					else
						rest="${s:i}"; rest="${rest%%$'\n'*}"; i=$((i + ${#rest} - 1))
					fi ;;
				';' | '&' | '|' | '(' | ')' | $'\n')
					add_word
					WORDS+=("$SEP")
					if [ "$c" = $'\n' ] && [ -n "$HD_DELIM" ]; then skip_heredoc_body; fi ;;
				'<')
					if [ "${s:i:3}" = '<<<' ]; then   # a here-string: an ordinary word follows
						add_word; i=$((i + 2))
					elif [ "${s:i:2}" = '<<' ]; then   # a heredoc: its body is skipped at the newline
						add_word; read_heredoc_op
					else
						w="$w$c"; have=1
					fi ;;
				*) w="$w$c"; have=1 ;;
			esac
		fi
		i=$((i + 1))
	done
	add_word
}

# ---- Bash: what each simple command does --------------------------------------------------------

NO_VERIFY=0 PR_ACTION="" PR_TITLE="" PR_HEAD="" PR_TARGET="" PR_REPO=""
CMD=()

# The pre-commit scan reminder isn't given here: this hook runs before the whole command line, so in
# `git add x && git commit` it would see the index as it was before the add. The pre-commit hook
# (pr-ready-hook.sh pre-commit) gives it instead, with the commit's own index, for Claude Code's
# commits too.

# takes_value <long option as typed>: is it a git commit option that takes a value, or a prefix of
# one? git takes unambiguous abbreviations of long options (--mess for --message).
takes_value() {
	local o
	[ "${#1}" -ge 4 ] || return 1
	for o in message file reuse-message reedit-message template author date fixup squash trailer \
		cleanup pathspec-from-file; do
		case "--$o" in "$1"*) return 0 ;; esac
	done
	return 1
}
commit_skips_hooks() {   # commit_skips_hooks <first arg>: --no-verify, or -n alone or in a cluster
	local k="$1" a rest ch
	while [ "$k" -lt "${#CMD[@]}" ]; do
		a="${CMD[k]}"
		case "$a" in
			--) return 1 ;;
			--no-veri*) return 0 ;;   # abbreviations too (--no-ver could be --no-verbose)
			-m | -F | -C | -c | -t) k=$((k + 1)) ;;
			--*=*) ;;                 # a long option with its value attached
			--*) takes_value "$a" && k=$((k + 1)) ;;
			-?*)   # short options, possibly clustered (-nm, -am)
				rest="${a#-}"
				while [ -n "$rest" ]; do
					ch="${rest:0:1}"; rest="${rest:1}"
					case "$ch" in
						n) return 0 ;;
						m | F | C | c | t)   # takes a value: the rest of the cluster, or else the next word
							[ -n "$rest" ] || k=$((k + 1))
							break ;;
						S | u) break ;;      # an optional value, attached
					esac
				done ;;
		esac
		k=$((k + 1))
	done
	return 1
}
hooks_option() {   # hooks_option <name=value>: does this -c setting move core.hooksPath off the hooks?
	local rc=1 v
	shopt -s nocasematch
	case "$1" in
		core.hookspath=.githooks | core.hookspath=.githooks/ | core.hookspath=./.githooks | core.hookspath=./.githooks/) ;;
		core.hookspath=*)
			# The clone's own setting (a chained hooks folder such as .husky) doesn't skip anything.
			v="$(cd "$HOOK_DIR" && git config --get core.hooksPath 2>/dev/null)"
			[ -n "$v" ] && [ "${1#*=}" = "$v" ] || rc=0 ;;
		core.hookspath) rc=0 ;;
	esac
	shopt -u nocasematch
	return "$rc"
}
git_command() {
	local k=1 n=${#CMD[@]} j hooks_off=0
	while [ "$k" -lt "$n" ]; do   # git's own options, before the subcommand
		case "${CMD[k]}" in
			-c | --config-env)
				hooks_option "${CMD[k + 1]:-}" && hooks_off=1
				k=$((k + 2)) ;;
			--config-env=*)
				hooks_option "${CMD[k]#*=}" && hooks_off=1
				k=$((k + 1)) ;;
			-C | --git-dir | --work-tree | --namespace) k=$((k + 2)) ;;
			-*) k=$((k + 1)) ;;
			*) break ;;
		esac
	done
	[ "$k" -lt "$n" ] || return 0
	case "${CMD[k]}" in
		commit)
			if [ "$hooks_off" = 1 ] || commit_skips_hooks $((k + 1)); then NO_VERIFY=1; fi ;;
		push)
			[ "$hooks_off" = 1 ] && NO_VERIFY=1
			for ((j = k + 1; j < n; j++)); do
				case "${CMD[j]}" in
					--) break ;;
					--no-veri*) NO_VERIFY=1 ;;
					-o | --push-option | --repo | --receive-pack | --exec) j=$((j + 1)) ;;   # their value
				esac
			done ;;
	esac
	return 0
}
gh_create() {
	local k=3 n=${#CMD[@]} a rest ch v draft=0 title="" head="" repo=""
	while [ "$k" -lt "$n" ]; do
		a="${CMD[k]}"
		case "$a" in
			--draft | --draft=true | --dry-run) draft=1 ;;
			--title | --head | --repo)
				v="${CMD[k + 1]:-}"; k=$((k + 1))
				case "$a" in --title) title="$v" ;; --head) head="$v" ;; *) repo="$v" ;; esac ;;
			--title=*) title="${a#*=}" ;;
			--head=*) head="${a#*=}" ;;
			--repo=*) repo="${a#*=}" ;;
			--body | --base | --body-file | --assignee | --label | --milestone | --project | --reviewer | \
				--template | --recover)
				k=$((k + 1)) ;;
			--*) ;;
			-?*)   # short options, possibly clustered (-dw); the first that takes a value takes the rest
				rest="${a#-}"
				while [ -n "$rest" ]; do
					ch="${rest:0:1}"; rest="${rest:1}"
					case "$ch" in
						d) draft=1 ;;
						t | H | R | b | B | F | a | l | m | p | r | T)
							v="$rest"
							if [ -z "$v" ]; then v="${CMD[k + 1]:-}"; k=$((k + 1)); fi
							case "$ch" in t) title="$v" ;; H) head="$v" ;; R) repo="$v" ;; esac
							break ;;
					esac
				done ;;
		esac
		k=$((k + 1))
	done
	[ "$draft" = 1 ] && return 0
	is_this_repo "$repo" || return 0
	[ -n "$PR_ACTION" ] && return 0   # the first PR command in the line decides
	PR_ACTION=create PR_TITLE="$title" PR_HEAD="${head##*:}" PR_REPO="$repo"
}
gh_ready() {
	local k=3 n=${#CMD[@]} a target="" repo=""
	while [ "$k" -lt "$n" ]; do
		a="${CMD[k]}"
		case "$a" in
			--undo) return 0 ;;
			-R | --repo) repo="${CMD[k + 1]:-}"; k=$((k + 1)) ;;
			--repo=*) repo="${a#*=}" ;;
			-*) ;;
			*) [ -n "$target" ] || target="$a" ;;
		esac
		k=$((k + 1))
	done
	is_this_repo "$repo" || return 0
	[ -n "$PR_ACTION" ] && return 0
	PR_ACTION=ready PR_TARGET="$target" PR_REPO="$repo"
}
analyse_command() {
	local name="${CMD[0]##*[/\\]}"
	name="${name%.exe}"
	case "$name" in
		gh)
			if [ "${#CMD[@]}" -ge 3 ] && [ "${CMD[1]}" = pr ]; then
				case "${CMD[2]}" in create | new) gh_create ;; ready) gh_ready ;; esac   # new: create's alias
			fi ;;
		git) git_command ;;
	esac
	return 0
}
analyse() {   # each simple command, without leading VAR=value words and command/env/exec prefixes
	local k=0 n=${#WORDS[@]} word
	while [ "$k" -le "$n" ]; do
		if [ "$k" -eq "$n" ] || [ "${WORDS[k]}" = "$SEP" ]; then
			[ "${#CMD[@]}" -gt 0 ] && analyse_command
			CMD=()
		else
			word="${WORDS[k]}"
			if [ "${#CMD[@]}" -gt 0 ]; then
				CMD+=("$word")
			elif ! [[ $word =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
				case "$word" in command | env | exec | nohup | time) ;; *) CMD+=("$word") ;; esac
			fi
		fi
		k=$((k + 1))
	done
}

json_field command || exit 0
LC_ALL=C   # byte-wise string handling: quicker, and enough for this
split_words "$REPLY"
analyse
for ((s_i = 0; s_i < ${#SUBSTS[@]}; s_i++)); do   # grows while it runs: substitutions can nest
	WORDS=()
	split_words "${SUBSTS[s_i]}"
	analyse
done
[ "$NO_VERIFY" = 1 ] || [ -n "$PR_ACTION" ] || exit 0
in_this_clone

if [ "$NO_VERIFY" = 1 ]; then
	decide ask "This skips the repo's git hooks (the SQL linter, the doc gate, the review reminders): --no-verify, git commit -n, or -c core.hooksPath pointing elsewhere. Run the command without it, or confirm only if the user asked to skip the hooks."
fi
case "$PR_ACTION" in
	create)
		skip_marker "$PR_TITLE"
		gate "create it with --draft" ${PR_HEAD:+--ref "$PR_HEAD"}
		;;
	ready)
		pr_branch "$PR_TARGET" "$PR_REPO" || unchecked "PR $PR_TARGET"
		gate "leave it a draft" ${REPLY:+--ref "$REPLY"}
		;;
esac
exit 0
