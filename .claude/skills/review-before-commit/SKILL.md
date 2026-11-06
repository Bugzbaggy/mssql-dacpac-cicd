---
name: review-before-commit
description: Low-effort pre-commit scan for a SQL Server database repository. Runs /review-db at low level on just the changes the next commit will contain (the staged changes, or what `git commit -a` would take), lists what it finds, fixes what the developer picks, and records the scan so the commit reminders stop. Use before git commit, or when a commit reminder says the changes haven't had the pre-commit scan. A re-run scans only content no scan has seen.
argument-hint: "[--all] [--no-fix]"
---

# Review before commit

This skill gives each commit a quick, low-level `/review-db` pass before the commit exists, so the obvious problems surface early. It is not the full review:
- `/pr-ready` reviews the whole branch before the PR.
- The `Claude Code Review` workflows are the backstop on the PR.

It is warn-only. The pre-commit hook (`.githooks/pr-ready-hook.sh pre-commit`) reminds when a commit's changes haven't been scanned, and never blocks: a hard block teaches people to use `--no-verify`.

Repository settings come from `.sql-ready.conf`: run `bash .githooks/pr-ready-stamp.sh config` and keep `base_branch`, `skip_paths` and `review_note`.

## Where this sits

| Stage | What runs |
|---|---|
| `git commit` | **This skill:** low effort, this commit's changes only. When a commit's changes haven't been scanned, the pre-commit hook prints a reminder, in Claude Code sessions too, and the commit goes ahead. The repo's own pre-commit checks run as before. |
| `gh pr create`, `gh pr ready` | `/pr-ready`: the whole branch, up to two passes, production checks. The gate denies these commands until it has run. |
| PR opened or pushed | `Claude Code Review` in CI, comments only |

## Arguments

`$ARGUMENTS`

- **`--all`:** scan what `git commit -a` would commit, meaning every tracked file's uncommitted changes. Without it, the scan covers the staged changes. When nothing is staged (`git diff --cached --quiet` succeeds), use `--all`.
- **`--no-fix`:** report only.

Pass the same `--all` (or not) to every `pr-ready-stamp.sh` call below.

## Step 1: Scope

1. Run `git rev-parse --abbrev-ref HEAD`. Stop on `base_branch` or a detached HEAD.
2. Run `bash .githooks/pr-ready-stamp.sh scan-scope [--all]`. It lists the files in the next commit whose content no scan has covered yet. Docs and `skip_paths` never need a scan.
3. If it lists nothing, there's nothing new to scan. Say so and stop.

## Step 2: Scan

1. **Settings:** take `review_note` from the config output.
2. **Run the review:** invoke `/review-db` (`.claude/skills/review-db/`) through the Skill tool, with skill `review-db` and these args:

   ```text
   low. Local diff, no PR: review git diff --cached, the changes the next commit will contain, skip the context script and the PR ledger (review-db's step 2) and never post. Introduced means on a + line of that diff, judged against HEAD rather than the merge-base. The code under review is the staged content: read a changed file with git show :<path>, not from HEAD. A candidate that needs production data to verify, and that you can't or don't query: don't drop it under Verified; list it under Held back as "Needs data check: <claim>. Settled by: <query>". <review_note> Only these files are in scope: <scan-scope>. This is a quick pre-commit scan: don't query production. This review is Step 2 of /review-before-commit: after the terminal report, go back to its Step 2 item 3 and carry on; don't end the turn.
   ```

   - With `--all`, the target is `git diff HEAD`, tracked files only, instead of `git diff --cached`, and the code under review is the working tree: say "read a changed file from the working tree" instead of the `git show :<path>` sentence.
   - Leave out the "Only these files" sentence when every changed file is in scope.
   - `/review-db` runs in this conversation (it isn't a forked skill), so its instructions take over until its report is out. Keep the last sentence: without it, the run can stop at the report.
3. **Data-dependent findings:** these are findings whose truth depends on what's in production. `/review-db` lists them under Held back as "Needs data check: …"; that's what the sentence in its args is for, since without it its Verified gate drops them. Mark them "needs data check" and leave them for `/pr-ready`, which checks them against production. Don't query production here.

## Step 3: Fix

Skip this step with `--no-fix`.

1. Show the findings:

   | # | Severity | File:line | Finding | Fix |
   |---|---|---|---|---|

   Severity is Important (would change behaviour, lose or corrupt data, or fail CI or a deployment) or Nit. From `/review-db`'s report, Post is Important, "Held back, minor" is Nit, and a Held back "Needs data check: …" item is listed with severity "needs data check". If the labels differ (a developer's own, newer copy of `/review-db`), map them by meaning. A "Pre-existing severe" item is outside this commit: list it as Important (pre-existing), and leave it for the developer to decide.
2. Ask the developer which findings to fix. The default is every Important one.
3. Fix those.
   - Follow the repo's authoring rules (`CLAUDE.md`, `.claude/rules/`).
   - Leave the developer's header and change-history lines as they wrote them.
   - Never edit files under `skip_paths`.
4. **Staging the fix:** if the developer's changes were staged, `git add` each file you fixed, so the commit takes the fix.
   - Exception: a file the developer staged only in part. Check with `git diff --quiet -- <file>` before you edit it.
   - For those files, leave your fix unstaged: a whole-file `git add` would also stage the hunks they left out.
   - Tell the developer to stage the fix themselves (`git add -p <file>`).
5. There is no second pass. The fixes are small, and `/pr-ready` reviews the whole branch before the PR.

## Step 4: Record the scan

Run `bash .githooks/pr-ready-stamp.sh scan-write [--all]` after any fixes.

- It records the content that was scanned, so the reminders stop, and a later scan covers only what changes after this.
- It is a record that the scan ran, not that the code is right. Write it even when Important findings remain, and list those in the summary.
- If you left a fix unstaged for the developer (Step 3.4), the record covers the staged content without it. Once they've staged the fix, tell them to run `/review-before-commit` again: it scans only content no scan has seen. Don't tell them to run `scan-write` themselves. That would record whatever is staged at that moment, including hunks no scan has seen.

## Step 5: Summary

| | Result |
|---|---|
| Scope | The files scanned, and why: a first scan, or changed since the last one |
| Findings | Important and Nit counts: fixed, left, needs data check |
| Recorded | Yes |

Then:
- If the developer asked for the commit, make it now: the developer's git identity, never `--no-verify`.
- Otherwise, tell the developer it's ready to commit.
- If Important findings remain, suggest fixing them before the PR. `/pr-ready` will look again.
