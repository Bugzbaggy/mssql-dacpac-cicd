# Git hooks

What git runs in a clone of this repository once its `core.hooksPath` points here. Turn them on
once per clone, with whichever shell you have:

```bash
.githooks/bootstrap.sh          # bash: Git Bash, macOS, Linux
.githooks\bootstrap.cmd         # cmd.exe or PowerShell on Windows
pwsh scripts/setup-hooks.ps1    # PowerShell on any platform
```

All three leave a clone alone when `core.hooksPath` already names another folder (a hook
framework), and print the command that switches it. A Claude Code session turns the hooks on by
itself at start (`pr-ready-bootstrap.sh`, run from `.claude/settings.json`), but only in a clone with
no hooks of its own.

## At each commit

`pre-commit` runs three checks, in this order:

| Check | Looks at | When it finds something |
|---|---|---|
| `sql-doc-gate.sh` | whether the branch's `.sql` changes are documented | blocks the commit |
| `pr-ready-hook.sh pre-commit` | whether the commit's changes have had `/review-before-commit` | warns |
| nitsql (`analyze_sql.py`) | the staged `.sql` files | blocks on CRITICAL, warns on the rest |

Then `commit-msg` adds `Co-authored-by: Claude <noreply@anthropic.com>` to the message's trailers,
unless one of them already credits Claude.

### The doc gate

`sql-doc-gate.sh` compares the branch's `.sql` changes with the ones last marked as documented. Those
changes are the `*.sql` files that differ between the merge base with `base_branch` and the working
tree, less `skip_paths`, `tests/` and `local-test/`: generated migrations, rollback scripts,
pipeline SQL and test code hold no schema objects to document. When they don't match, the commit
stops and the message lists the files. `--files` prints that list (it is `/schemalore`'s default
scope) and `--base` the base branch in use; `git config schemalore.base` overrides `base_branch`
for one clone.

- `/schemalore` (the `documenter` in `.sql-ready.conf`) updates the docs and then marks them with
  `bash .githooks/sql-doc-gate.sh --mark-done`. Run that yourself only when the docs already match.
- The mark follows the files' content. A rebase keeps it, and so does a merge from `base_branch`
  that leaves the branch's own `.sql` files alone. Each branch has its own, in
  `.git/sql-doc-gate/<branch>`.
- Nothing is checked on `base_branch` itself, on a detached HEAD (a rebase), during a merge, or when
  there is no merge base (a shallow clone).

### nitsql

[nitsql](https://github.com/Bugzbaggy/nitsql) is a SQL analyzer with 52 rules that tells SQL Server,
PostgreSQL, Oracle, MySQL and SQLite apart from the code itself. This copy is one rule ahead of the
nitsql repository: SA-MS002 checks each procedure on its own and is CRITICAL. A procedure that opens
a transaction without `SET XACT_ABORT ON` is one Flyway treats as non-transactional, and unless
`mixed` is on, Flyway rejects a migration that mixes it with transactional statements, so it fails
at deploy, not just in review. The hook runs nitsql on a copy of what
is staged, the version the commit will hold, so an unstaged edit can neither hide a finding nor add
one. A CRITICAL finding blocks the commit; HIGH, MEDIUM and LOW ones are printed and the commit goes
ahead. Without Python 3.8 or later, or without the analyzer, the hook says so and lets the commit
through.

The hook is there for fast feedback. `.github/workflows/nitsql.yml` runs the same analyzer on the
`.sql` files each pull request changes, and fails on a CRITICAL finding whether or not anyone's hook
ran.

## At each push

`pre-push` reminds you, and never blocks, when a branch you push hasn't been through `/pr-ready`.
Pushing work in progress is fine. The check that holds is on the pull request: in Claude Code,
`pr-ready-gate.sh` denies `gh pr create` and `gh pr ready` until `/pr-ready` has reviewed the branch's
commits, and the CI review comments on every pull request regardless.

`bash .githooks/pr-ready-stamp.sh status` shows where the current branch stands, and
`bash .githooks/pr-ready-stamp.sh scan-check --explain` whether the staged changes have had their
pre-commit scan. See [AI Review Flow](../docs/architecture/pipeline.md#ai-review-flow) for the whole
flow.

## Skipping them

`git commit --no-verify` skips `pre-commit` and `commit-msg` for one commit, and
`git push --no-verify` skips `pre-push`. CI still runs nitsql and the review on the pull request.
In Claude Code, the pre-PR gate turns `--no-verify`, `git commit -n` and `git -c core.hooksPath=...`
into a question for the user.

## Files

| File | What it is |
|---|---|
| `pre-commit` | the three commit checks above |
| `commit-msg` | the Claude co-author trailer |
| `sql-doc-gate.sh` | the doc gate, the same file as `hooks/sql-doc-gate.sh` in [schemalore](https://github.com/Bugzbaggy/schemalore) |
| `analyze_sql.py` | nitsql (Python 3.8+), with the per-procedure SA-MS002 |
| `bootstrap.sh`, `bootstrap.cmd` | turn the hooks on for a clone |
| `pre-push` | the `/pr-ready` reminder |
| `pr-ready-hook.sh` | the reminders `pre-commit` and `pre-push` give |
| `pr-ready-gate.sh` | the Claude Code hook (`.claude/settings.json`) that holds `gh pr create` and `gh pr ready` until `/pr-ready` has reviewed the branch |
| `pr-ready-stamp.sh` | the per-branch review state behind the gate and the reminders, in `.git/claude-review/`; reads `.sql-ready.conf` |
| `pr-ready-bootstrap.sh` | turns the hooks on at the start of a Claude Code session |

## Updating

Nothing updates `analyze_sql.py` for you. A newer `scripts/analyze_sql.py` from
[nitsql](https://github.com/Bugzbaggy/nitsql) can replace it once that one checks SA-MS002 per
procedure; until then, copying it over drops the rule. `nitsql.yml` runs on the change.
The `pr-ready-*` files and `pre-push` come from [sql-ready](https://github.com/Bugzbaggy/sql-ready),
whose `install.sh` upgrades them in place.
