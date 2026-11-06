---
name: pr-ready
description: Pre-PR review loop for a SQL Server database repository. Reviews the branch's committed changes with /review-db (which keeps only introduced, verified, moderate-or-worse findings), checks data-dependent findings against production (read-only, when the repo notes name a read-only SQL tool), asks which findings to fix, fixes and commits them, confirms the fixes with a second pass on the fix diff only (at most two passes per branch), then records the review so the pre-PR gate lets `gh pr create` and `gh pr ready` through. Use before opening a PR or marking a draft ready, or when the gate blocks one. A re-run reviews only the files changed since the last review.
argument-hint: "[low|medium|high] [--hotfix] [--full] [--no-prod]"
---

# PR ready

Review, fix and check against production before the PR exists, so the CI jobs that run on a PR
(a migration generator, the linter, the CI review) run once, on code that has already been
reviewed, and reviewers see the cleaned-up version.

The pieces:

- **This skill:** the review and the fixes, on the developer's machine.
- **The gate:** `.githooks/pr-ready-gate.sh`, a Claude Code hook that denies PR creation until this
  skill has recorded a review of the branch's current commits.
- **The backstop:** the comment-only `Claude Code Review` workflows on the PR.

Repository settings come from `.sql-ready.conf`. Run `bash .githooks/pr-ready-stamp.sh config`
once at the start and keep its output: it prints `base_branch`, `skip_paths`, `generated_paths`,
`generator_bot`, `lint_command`, `doc_gate`, `documenter` and `review_note`. Below, `<base>` is
`base_branch`.

## Where this sits

| Stage | What runs | What it blocks |
|---|---|---|
| Commit | The repo's pre-commit checks (a linter, a doc gate) and `/review-before-commit`, a quick, low-effort scan of the commit; the hooks only remind when it hasn't run | Whatever the repo's own checks block |
| Before the PR | **`/pr-ready`**. The gate denies `gh pr create` and `gh pr ready` (and the GitHub MCP equivalents) in Claude Code until this has run. The pre-push hook only reminds. | PR creation from Claude Code |
| PR opened, marked ready, pushed | GitHub Actions: the repo's own checks, and the Claude Code Review workflows (`/review-db`, comments only) | The repo's required checks |

**Not gated:**
- Draft PRs, until they're marked ready.
- Branches that only change docs or `skip_paths`.
- PRs whose title carries `[skip-review]`: hotfixes or comment-only re-triggers, and only when the developer asks.
- Any PR when the developer sets `PR_READY_GATE=warn` (remind instead of deny) or `off`.

## Arguments

`$ARGUMENTS`

- **Effort:** the first word, if it's `low`, `medium` or `high`. It overrides the default from Step 1.
- **`--hotfix`:** one pass only, no confirmation pass. Implied on a `hotfix/` branch.
- **`--full`:** review every changed file, not only those the last review didn't cover.
- **`--no-prod`:** skip the production checks. Data-dependent findings are reported as "needs data check".

## Loop guards

These hold on every run:

- **At most two passes per branch.**
  - Pass 1 reviews, pass 2 confirms the fixes, and there is never a third.
  - The branch's count is kept in `.git/claude-review/<branch>.json` (`bash .githooks/pr-ready-stamp.sh passes`).
- **Stop early.** No pass 2 when pass 1 finds nothing Important, or the developer fixes nothing.
- **Pass 2 reviews only the fix diff.**
  - It confirms the pass-1 findings are resolved and reports correctness problems only.
  - A full re-review always turns up fresh minor issues, and that's how loops start.
- **A finding that comes back after being fixed:** stop and ask the developer.
- **Nothing is dropped.** What isn't fixed goes into "Known / deferred" in the PR description, or a follow-up issue.

## Step 0: Preconditions

1. **Branch:** `git rev-parse --abbrev-ref HEAD`. Stop on `<base>` or a detached HEAD.
2. **Base:** `git fetch origin <base>`, so the merge base is current. If it fails (offline), carry on and say so in the summary.
3. **Uncommitted work:** run `bash .githooks/pr-ready-stamp.sh uncommitted`.
   - The review covers commits, because that's what the PR will contain and what the gate checks.
   - If files are listed, ask the developer to commit them first (offer to do it), or to confirm they stay out of this PR.
4. **What to review:** run `bash .githooks/pr-ready-stamp.sh status`, then `bash .githooks/pr-ready-stamp.sh scope` to list the files to review.
   - If `scope` is empty, the branch's changes have been reviewed already, or need no review (docs, `skip_paths`). Say so and stop.
5. **Pass budget:** run `bash .githooks/pr-ready-stamp.sh passes`. At 2 or more, the branch has used its two passes. Ask the developer which they want:
   - Review the files in scope anyway: one pass, with no confirmation pass.
   - Record the review as skipped: Step 6 with `passes=0 review=skipped`.
6. **Generated files are CI's:** when `generated_paths` is set, run `git log --format='%h %an %s' origin/<base>..HEAD -- <generated_paths>`.
   - A commit there by anyone but `generator_bot` is an Important finding: those files are written by CI, never by hand.
   - Don't fix it; ask the developer to revert it.
7. **Earlier findings:** run `bash .githooks/pr-ready-stamp.sh findings`. Keep the tables earlier runs logged, for the recurrence check (Step 5) and "Known / deferred" (Step 7).

## Step 1: Effort and checks by change type

Unless the developer gave an effort, pick it from what's in scope. When several rows apply, the highest effort wins.

| Change in scope | Effort | Production check |
|---|---|---|
| Stored procedure, view or function logic | `low` | When filters, joins or aggregations change |
| Table DDL (`*/Tables/*.sql`, `CREATE`/`ALTER TABLE` in a migration), indexes, retention or purge jobs | `medium`, or `high` if the developer asks | Required |
| Security: roles, users, permissions (`*/Security/*`, `GRANT`, `DENY`) | `medium` | n/a |
| Workflows, hooks, Claude config (`.github/`, `.githooks/`, `.claude/`, `CLAUDE.md`) | `low` | n/a |

The effort is `/review-db`'s level: `low` runs no finder subagents, `medium` runs 2 and `high` runs 3.

## Step 2: Linter

Skip this step when `lint_command` is empty. Otherwise run `<lint_command> <files>` for the `.sql` files in scope (if it starts with `python` and that isn't found, try `python3` or `py`).

- The review note tells `/review-db` not to repeat the linter's rules, so they're reported here instead.
- The linter's blocking severity (CRITICAL, or whatever fails the repo's pre-commit hook or CI) and the one below it: list both as Important.
- Mention lower severities, and fix them only when the fix is trivial.
- **Pre-existing findings:** these are on lines the branch doesn't change, so they were already on `<base>` (check with `git diff <merge-base>..HEAD -- <file>`). List them as Nit (pre-existing) and leave them, unless the developer asks for a fix. Fixing them widens the change.

## Step 3: Pass 1

1. **Settings:** take `review_note` from the config output, so this review follows the same rules as the CI review.
2. **Run the review:** invoke `/review-db` (`.claude/skills/review-db/`) through the Skill tool, with skill `review-db` and these args:

   ```text
   <effort>. Local diff, no PR: review git diff <merge-base>..HEAD, skip the context script and the PR ledger (review-db's step 2) and never post. Ledger: <earlier findings>. A candidate that needs production data to verify, and that you can't or don't query: don't drop it under Verified; list it under Held back as "Needs data check: <claim>. Settled by: <query>". <review_note> Only these files are in scope: <scope>. Other changed files were reviewed by an earlier /pr-ready run. This review is Step 3 of /pr-ready: after the terminal report, go back to /pr-ready Step 3 item 3 and carry on; don't end the turn.
   ```

   - `<merge-base>` is `git merge-base origin/<base> HEAD`.
   - **Local diff, even when the branch has a draft PR.** The review covers the local commits, which may not be pushed yet. In PR mode `/review-db` reviews the pushed head and stops on unpushed work.
   - **Ledger:** the findings Step 0 item 7 found logged, with their status, or "none" on a first run.
     - A logged fix counts as fixed (`/review-db` verifies it at HEAD).
     - Deferred and rejected findings count as settled, so they aren't raised again.
     - A finding logged as "needs data check" counts as open: nothing settled it. It can come back as Still open or as a new "Needs data check" line, and that isn't a recurrence.
   - **Production:** `/review-db`'s Verified gate may query production. Those queries follow Step 4's rules. With `--no-prod`, or when the repo notes name no read-only SQL tool, add "Don't query production."
   - **Data-dependent candidates:** keep the "Needs data check" sentence. Without it, `/review-db`'s Verified gate drops any claim it couldn't check against production, and the finding is lost: it isn't even held back.
   - Leave out the "Only these files" and "Other changed files" sentences when every changed file is in scope (a first run, or `--full`).
   - `/review-db` runs in this conversation (it isn't a forked skill), so its instructions take over until its report is out. Keep the last sentence: without it, the run can stop at the report.
3. **Sort the findings:** put every finding, the linter's included, in one table.

   | # | Severity | Kind | File:line | Finding | Verified | Fix |
   |---|---|---|---|---|---|---|

   - **Severity:** Important (changes behaviour, loses or corrupts data, fails CI or a deployment) or Nit. From `/review-db`'s report:

     | Report line | Severity |
     |---|---|
     | Post | Important |
     | Still open, logged as fixed | Important: a logged fix that isn't fixed at HEAD. That is a recurrence, so stop and ask the developer (Loop guards) |
     | Still open, logged as needs data check | Data-dependent, as below: still unsettled, not a recurrence |
     | Still open, logged as deferred or rejected | Settled: don't raise it again, but keep it in "Known / deferred" and the deferred count, as logged. If the report brings new evidence against the reason, show it and ask the developer |
     | Still open, any other status | Important: an earlier finding still unaddressed. Ask the developer |
     | Held back, minor | Nit |
     | Held back, "Needs data check: …" | Data-dependent, and not a Nit: Step 4 settles it. Its severity is the one it would have if confirmed |
     | Pre-existing severe | Important (pre-existing): outside the branch's change, so fix it only if the developer asks |
     | Belongs in `<repo>` | Not fixed here; goes under "Known / deferred" |

   - If the report's labels differ (a developer's own, newer copy of `/review-db`), map them by meaning.
   - Leave `/review-db`'s Dropped candidates out of the table, and give their counts in the summary.
   - **Kind:** code-only, or data-dependent (whether it's true depends on what's in production; see Step 4).
4. **Before proposing a fix, check each finding again.**
   - `/review-db`'s Verified gate has checked its own findings; this check is for the linter's and for anything that reads differently once you look at the code.
   - If the `superpowers:receiving-code-review` skill is available, follow it.
   - Otherwise apply its rule: check each finding against the code (and against production, in Step 4, if it's data-dependent), and push back on wrong findings rather than "fixing" them.

## Step 4: Check data-dependent findings against production

Only findings whose truth depends on the data, plus the checks Step 1 requires. Code-only findings need no query.

**Where:** the read-only SQL tools that `.claude/skills/review-db/repo-notes/<repo>.md` names under "Production reads": typically an MCP server whose tools only run SELECT, under the developer's own credentials, with the server (a read-only replica or listener, when there is one) and the database to use.
- Confirm the database exists with the tool's database list before the first query.
- The rules below, the query budget included, cover `/review-db`'s queries as well as this step's.
- When the database exists in several regions or shards, the data can differ between them. Say so when it matters.

| Finding is about | Check |
|---|---|
| NULLs or empty sets | `COUNT(*)` with the NULL filter |
| Uniqueness or duplicate keys | `GROUP BY … HAVING COUNT(*) > 1`, with `TOP` |
| Column types, join keys, objects the code relies on | The tool's object description (never conclude an object is missing from the code alone) |
| Sentinel values or enum ordering | `DISTINCT` values with counts |
| Rows a data fix, retention or purge job touches | Count what the `WHERE` matches |
| A table change | Compare with production's definition: narrowed types, NOT NULL on a populated column, a dropped column other objects still read (grep the project folder) |

**Rules:**
- SELECT only.
- Filter on a leading index key or the partition column that the object description reports, and use `TOP`.
- Never ask the tool to lift its scan or row limits.
- Run about 10 queries per run at most.
- Only counts and aggregates go into the summary, the PR description or comments. Never customer rows.
- A result that confirms a finding keeps it; one that refutes it drops it. Say which in the table.

**Without the tools, or with `--no-prod`:** mark each data-dependent finding "needs data check", with the query that would settle it, and record `prod_checks=skipped`.

## Step 5: Fix, then pass 2

1. **Ask what to fix.**
   - Show the verified table and ask the developer which findings to fix. The default is every verified Important finding.
   - Use AskUserQuestion when there are four or fewer, otherwise a numbered list.
2. **Fix** what the developer chose.
   - Edit only files in the branch's diff. Never edit files under `skip_paths`.
   - Follow the repo's authoring rules (`CLAUDE.md`, `.claude/rules/`): a header that names an engineer, never "Claude", and the repo's type conventions.
   - Leave the developer's header and change-history lines as they wrote them. The fix makes their change correct; it doesn't redescribe it.
3. **Doc gate:** if the fixes touched `.sql` files and `doc_gate` is set, run it. If it blocks, ask the developer which they want:
   - Run `documenter` now, when one is set. It may ask a few questions.
   - If the fixes don't change what the docs say, mark the docs current the way the gate says (for example `bash .githooks/sql-doc-gate.sh --mark-done`).
4. **Commit the fixes.**
   - Note `PRE_FIX=$(git rev-parse HEAD)`, `git add` the files you changed by path, and commit with a subject like `Address /pr-ready review findings` and a body listing the findings fixed.
   - Before committing, run `bash .githooks/pr-ready-stamp.sh scan-write`. It records the fixes as scanned, so the pre-commit reminder stays quiet; pass 2 reviews them next.
   - Use the developer's git identity, and never pass `--no-verify`.
   - Never push.
5. **Pass 2:** skip it with `--hotfix`, or when nothing was fixed. Otherwise invoke `review-db` again with these args:

   ```text
   <effort>. Local diff, no PR: review git diff <PRE_FIX>..HEAD, the fix commits, skip the context script and the PR ledger (review-db's step 2) and never post. Introduced means on a + line of that diff, judged against <PRE_FIX> rather than the merge-base. Ledger, all claimed fixed in this diff: <numbered list of the fixed pass-1 findings>. <review_note> This pass confirms those fixes: give each one's status (fixed, or unaddressed with why), and report only correctness problems the fixes introduce: wrong results, data loss, runtime or deployment errors. This review is Step 5 of /pr-ready: after the terminal report, go back to /pr-ready Step 5 item 6 and carry on; don't end the turn.
   ```

   Add the "Needs data check" sentence from Step 3, and its "Don't query production." sentence when that applies.

6. **After pass 2:**
   - **Unresolved or recurring:** a pass-1 finding still unresolved, or a finding that matches one fixed earlier (in this run or in the findings log), means stop and ask the developer. Don't fix it again yourself.
   - **New correctness problems:** show them and ask. Fix them only if the developer agrees, and commit as in item 4.
   - Those fixes get no third pass; the CI review still sees them on the PR.

## Step 6: Record the review

1. **Log the tables:** for each pass, run `bash .githooks/pr-ready-stamp.sh log "Pass <n>"` with the findings table on stdin (a heredoc). Give each finding a status: fixed, deferred, rejected (with why) or needs data check.
2. **Record the review:**

   ```bash
   bash .githooks/pr-ready-stamp.sh write passes=<1|2> effort=<effort> remaining_important=<n> deferred=<n> prod_checks=<run|skipped|n/a>
   ```

   - It records the committed changes, which is what the gate checks, so run it after the fixes are committed.
   - Never record over remaining Important findings silently. Ask the developer first; with their OK, record the review and list those findings under "Known / deferred".
   - When the developer chose to skip the review in Step 0, record `passes=0 review=skipped`.

## Step 7: Summary and the PR

1. **Summarise the run:**

   | | Result |
   |---|---|
   | Scope | Files reviewed, and why: a first run, changed since the last review, or `--full` |
   | Effort | The level, and why |
   | Linter | The linter's results, or "none configured" |
   | Pass 1 | Important and Nit counts; verified, rejected; `/review-db`'s Dropped counts |
   | Production checks | Each query with a one-line result (counts only), or skipped and why |
   | Fixes | The commit(s) |
   | Pass 2 | Resolved or remaining, or not run and why |
   | Recorded | Yes or no, and passes used on the branch |

2. **Offer the PR:** ask whether to open the PR now, or mark the draft ready.
   - If yes, run `gh pr create` (or `gh pr ready`). Add these sections to the usual description; write "None" under "Known / deferred" when nothing is left:

     ```markdown
     ## Pre-PR review (/pr-ready)
     <the summary table>

     ## Known / deferred
     - <finding>: <why it's deferred, or the follow-up issue>
     ```

   - Offer a follow-up issue for deferred findings if the developer prefers one.
   - If not now, tell the developer the gate lets `gh pr create` through for as long as the committed changes stay as reviewed.
