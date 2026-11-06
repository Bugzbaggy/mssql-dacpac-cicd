---
status: implemented
---

# CI/CD Pipeline & Migrations

**Status:** Implemented

How a change to the database project becomes Flyway migrations, gets a version, and reaches staging
and then production. This is the reference; the rules developers follow day to day live in the
database project's `CLAUDE.md` and in the
[sql-migration-generator](https://github.com/Bugzbaggy/sql-migration-generator) skill. Neither
ships here: `CLAUDE.md` belongs to the database project, and the skill installs from its own
repository ("Adapting it" in the README).

## Two Jenkins stages

### Versioning, before staging

`deploy/Jenkinsfile.staging.management` runs `CICD_AppDb_Analytics_Generic_Migration_Script.ps1` in
its "Migration Management" stage, after the generator workflow has committed the branch's scripts.
The script gives those scripts their final version and date, and writes them down:

1. It checks that it can reach the production database (`$serverPRD`), because `VersionHistory`
   lives there.
2. It works on the checkout Jenkins hands it in `PR_WORKSPACE` and `PR_BRANCH_SLUG`. If those are
   missing it falls back to the newest `AppDb_Analytics_STG_MGR_*` folder under
   `C:\Jenkins\workspace\`.
3. It changes each script's date in its file name to today's where they differ.
4. It looks the branch up in `VersionHistory` and decides its version (see
   [How a version is chosen](#how-a-version-is-chosen)), renaming the files to match.
5. It inserts or updates the branch's row.

### Deployment, after merge

`deploy/Jenkinsfile.production` waits for a deployment approval, runs the PolicyGate pre-deploy
check (a DENY stops it), then runs `Flyway_PRD_Deploy.ps1`:

1. It reads the schema version Flyway reports before migrating.
2. It runs `flyway migrate` and keeps all of its output.
3. On success it finds the versions Flyway applied and marks their rows `IsDeployed = 1`, with
   `DeployDate` and a note. If Flyway applied nothing while the checked-out `Migration` folder holds
   a versioned script newer than the database's version, it fails the build: that is a stale or
   wrong checkout, not a quiet success.
4. On failure it finds the versions that failed, writes the error to their `DeployNote` and sets
   `DeployDate`, leaves `IsDeployed` alone, and exits 1 so the Jenkins stage fails.

## Migration scripts

> The scripts in `Migration/` are written by `.github/workflows/generate-migration-scripts.yml`.
> Nobody creates, edits or deletes them by hand.

A branch carries at most two scripts, each holding everything the branch changes:

```
V{major}.{minor}__{date}.{database}.{branch}.sql    versioned
R__{date}.{database}.{branch}.sql                   repeatable
```

`{branch}` is the branch name with `/` turned into `.` (`feature/x` becomes `feature.x`). Versions
run from `V1.00000` to `V999.99999`: the major part is 1 to 999 with no padding, the minor part five
digits. For example:

- `V1.00001__2025-09-24.AppDb_Analytics.PROJ-1012.sql`
- `V12.00015__2025-11-05.AppDb_Analytics.feature-branch.sql`
- `R__2025-09-24.AppDb_Analytics.PROJ-1012.sql`

What goes where:

- **Versioned:** structure (tables, indexes, foreign keys, synonyms, user-defined types), data
  changes and reference data.
- **Repeatable:** views, procedures, functions and triggers, always as `CREATE OR ALTER`. Dropping
  and re-creating would lose their permissions and break what depends on them.

Each new commit on the branch replaces both scripts rather than adding more, so a branch never
deploys as a pile of files that could conflict. Versions and dates are CI's job. Rollback scripts go
in `Archive\`, named with a `ROLLBACK.` prefix.

## VersionHistory

One row per branch version, in `dbo.VersionHistory` in the production database. The staging
deployment reads it from there too.

| Column | Holds |
|---|---|
| `VersionId` | the version without the `V`, e.g. `1.00001` |
| `VersionPR` | the version with it, e.g. `V1.00001` |
| `BranchName` | the git branch |
| `BranchDate` | when the version was assigned or last updated |
| `IsDeployed` | whether production has it |
| `DeployDate` | when the last deployment attempt ran |
| `DeployNote` | the success message or the error |
| `ReassignmentNote` | the version the branch had before, when it was moved |
| `Script` | the script's file name |

Versioning writes the rows; deployment updates `IsDeployed`, `DeployDate` and `DeployNote`.

The databases, as the shipped configuration names them:

- Staging: `listener.example.com/AppDb_Analytics`
- Production: `listener.region1.example.com/AppDb_Analytics`

## How a version is chosen

Flyway applies versions in order and refuses one lower than what it has already applied, so two
branches must never end up with versions that deploy out of sequence.

- The branch gets the version after the latest deployed one: the minor part plus one, and at 99999
  the major part goes up and the minor part starts again at 1
  (`V1.99999` is followed by `V2.00001`).
- If another branch holds that version but hasn't deployed it, that branch's row is removed and the
  version goes to this branch.
- If a deployed version already holds it, the branch gets the version after the highest one
  recorded.
- When the branch moves to a new version, its old row is deleted, the new row's `ReassignmentNote`
  names the old version, and the script files are renamed.

`deploy/Flyway_Validate_Migration_Order.ps1` checks the result before staging: no gaps, and nothing
lower than what is deployed.

## When a deployment fails

The failed versions keep `IsDeployed = 0`, so the next run of the production pipeline retries them.
To recover:

1. Read the failed rows' `DeployNote` in `VersionHistory`.
2. Read the Flyway output in the Jenkins log.
3. Fix the cause and run the production pipeline again.

## AI Review Flow

Claude Code reviews a change at three points:

- **At each commit**, a quick, low-effort scan of just that commit's changes. It is warn-only.
- **Before the PR exists**, on the developer's machine. It reviews, fixes, and checks against production.
- **On the PR**, as a comment-only backstop.

The flow is the [sql-ready](https://github.com/Bugzbaggy/sql-ready) package, at the same paths; its
README has the details (the gate's output, the stamp's format, exit codes, emergency bypasses).
Repository settings are in `.sql-ready.conf`.

| Stage | What runs | What it blocks |
|-------|-----------|----------------|
| Commit | `.githooks/pre-commit`: sql-doc-gate, the `review-before-commit` reminder, nitsql | Undocumented `.sql` changes, CRITICAL findings. The reminder blocks nothing |
| Before the PR | The `pr-ready` skill, plus the pre-PR gate and `.githooks/pre-push` (details below) | PR creation from Claude Code |
| PR opened, marked ready, pushed | GitHub Actions: `generate-migration-scripts.yml`, `nitsql.yml`, `claude-code-review.yml` (opened, marked ready) and `claude-code-review-commits.yml` (pushed) | nitsql CRITICAL |
| PR approved | Jenkins via `jenkins-pr-approved.yml`: build, migration management, staging deployment | Required checks on the base branch |
| After merge | `deploy/Jenkinsfile.production`: approval, PolicyGate, production deployment | A PolicyGate DENY |

**The `review-before-commit` skill** (`.claude/skills/review-before-commit`):

- Runs `/review-db` (`.claude/skills/review-db`) at low level on just the changes the next commit will contain.
- Fixes the findings the developer picks, in one pass, and records the scan.
- When a commit's changes haven't been scanned, `.githooks/pre-commit` reminds, for Claude Code's commits too. Git runs it with the commit's own index, so `git add` on the same command line, `-a` and pathspecs all count. It never blocks: a hard block teaches people to use `--no-verify`.
- The record lives in `.git/claude-review/<branch>.scanned`, so a re-scan covers only content no scan has seen.

**The `pr-ready` skill** (`.claude/skills/pr-ready`):

- Runs `/review-db` on the branch's commits. It keeps only findings the branch introduced that it has verified and rates moderate or worse; minor ones are listed as Nits.
- Checks findings that depend on the data against production, read-only, through the SQL tool `.claude/skills/review-db/repo-notes/mssql-dacpac-cicd.md` names. The demo has none, so those findings stay "needs data check".
- Fixes and commits the findings the developer picks.
- Runs a second pass on the fix diff only.

**The pre-PR gate** (`.githooks/pr-ready-gate.sh`) is a Claude Code hook. It denies `gh pr create` and `gh pr ready` until the skill has run. `.githooks/pre-push` only reminds.

**The CI review** only comments. `claude-code-review.yml` reviews the whole PR when it's opened or marked ready, and `claude-code-review-commits.yml` reviews each push's new commits:

- Both review PRs into the default branch, and skip with a notice when the repository has no `ANTHROPIC_API_KEY` secret.
- A push shows the per-push review's two checks, and opening the PR or marking it ready shows the full review's three. Each posting job runs after every review and says "Nothing to post" when there's nothing. On a draft PR the review checks show as skipped until it's marked ready.
- It runs `/review-db` too, from the base branch's `.claude/`, so it posts only findings the PR introduced, has verified and rates moderate or worse. Until the base branch has the skill, it falls back to Claude Code's built-in `/code-review`.
- Its ledger (the PR description and earlier review threads, so settled points aren't raised again) is built by a step that runs no model, from text by people with write access only.
- The PR's own `CLAUDE.md`, `.claude/`, `AGENTS.md`, `REVIEW.md` and `.sql-ready.conf` aren't loaded as review instructions: the base branch's copies are, and the PR's changes to them are reviewed from the diff.
- Summary lines (still open, pre-existing severe, belongs in another repo, needs data check) go into one PR comment, and only when there are any. Each line is posted once per anchor: an earlier comment's id, or `path:line`. A line without one is matched by its text, ignoring case and spacing, so a rewording posts it again.
- It never fixes code and never queries production.
- It marks findings that depend on the data "Needs data check:".

Why it's arranged this way:

- **Reviews and fixes happen before the PR.**
  - On an open PR, every fix commit re-runs the migration generator (risking V-number collisions), nitsql and the doc gate.
  - A fix commit can also dismiss an approval, and approval is what starts Jenkins.
- **Jenkins isn't where the review runs.** It starts only after approval, so its review would come after the human one.
- **CI only comments.**
  - Bot fix commits would re-run the migration generator and could loop with it.
  - Querying production from CI would need a production service account and network access from the runner.

**Loop guards** (enforced by `pr-ready`):

- At most two passes per branch.
- Pass 2 reviews the fix diff only, and reports correctness problems only.
- If a fixed finding comes back, the skill stops and asks the developer.
- Findings left over go into the PR description's "Known / deferred" section.

The review state lives in `.git/claude-review/<branch>.json` and is never committed. A re-run reviews only the files whose change the last review didn't cover.

**Not gated:**

- Draft PRs, until they're marked ready.
- Branches that change only docs or the `skip_paths` in `.sql-ready.conf` (`Migration/`, `Archive/`, `deploy/`).
- A PR title with `[skip-review]`, for hotfixes or comment-only re-triggers.
- `PR_READY_GATE=warn` (a reminder instead of a denial) or `off`.

On an open PR, comment `/review-db [low|medium|high]` (or `/code-review [effort]`) to request a full re-review.


## From a branch to production

1. **Change the schema.** Edit the objects under their schema folders
   (`AppDb_Analytics\{schema}\Tables\`, `AppDb_Analytics\{schema}\Stored Procedures\` and so on).
2. **Commit and push to a feature branch.** Before each commit, `/review-before-commit` in Claude
   Code gives the commit a quick scan (warn-only); before the PR is opened or marked ready,
   `/pr-ready` reviews the branch. See [AI Review Flow](#ai-review-flow).
3. **Open the PR** against the default branch.
4. **The generator runs.** `generate-migration-scripts.yml` sees the SQL change and:
   - stops on a CRITICAL nitsql finding in the changed source files;
   - takes the content of deleted files from the base branch;
   - sorts the changes into versioned and repeatable;
   - writes both scripts with `IF EXISTS` / `IF NOT EXISTS` guards, rebuilding the repeatable one
     from the changed source files;
   - resolves version conflicts;
   - has Claude review the scripts, failing on a syntax error or a reference to an object that
     exists nowhere;
   - checks the object order in both scripts, failing on anything used before it is created or
     after it is dropped;
   - adds the grants for a new schema to `role_app_ci.sql` and updates the `.sqlproj`;
   - commits the scripts back to the PR.
5. **Read what it generated** in `Migration\`.
6. **Approve to test on staging.** An approval makes `jenkins-pr-approved.yml` start the Jenkins
   job named in its `JENKINS_JOB` secret with `PR_NUMBER`, `PR_BRANCH` and `GIT_COMMIT_HASH`, the
   parameters of `deploy/Jenkinsfile.staging.management`. That job versions the scripts, checks
   their order and starts `deploy/Jenkinsfile.staging.deployment`, which runs the branch's
   versioned script and then its repeatable one on staging (`Execute_Staging_Migrations.ps1`).
7. **Merge to deploy.** After the merge, `deploy/Jenkinsfile.production` waits for approval by
   `DEPLOYMENT_APPROVERS`, runs the PolicyGate check (a DENY stops it) and deploys to production,
   recording the outcome in `VersionHistory`.
8. **Review throughout.** `claude-code-review.yml` and `claude-code-review-commits.yml` run
   `/review-db` on the PR and on each push and post what they find as inline comments; they never
   block (comment `/review-db [low|medium|high]` for a full re-review). A person reviews and
   approves, which starts Jenkins, and merges when ready.

## References

- `schema-map.md`: how the schemas are organised (in the database project; not shipped here)
- [`security-model.md`](security-model.md): what the deploy account may do
- [sql-ready](https://github.com/Bugzbaggy/sql-ready): the pre-PR review flow, with the `pr-ready`,
  `review-before-commit` and `review-db` skills, the gate, the reminders and the two review
  workflows
- [sql-migration-generator](https://github.com/Bugzbaggy/sql-migration-generator): how the scripts
  are generated and the standards they follow. The generator workflow reads the skill from
  `.claude/skills/sql-migration-generator/` and fails without it; "Adapting it" in the README shows
  how to install it
