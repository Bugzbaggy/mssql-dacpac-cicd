# mssql-dacpac-cicd

A complete CI/CD pipeline for SQL Server database projects: SSDT/DACPAC build,
Flyway-versioned migrations, policy gates, and staged promotion from staging to
production with approvals.

[![SQL Server](https://img.shields.io/badge/SQL%20Server-2022-CC2927)](https://learn.microsoft.com/sql/)
[![Flyway](https://img.shields.io/badge/Flyway-migrations-CC0000)](https://flywaydb.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Why this exists

Database deployment tends to sit in one of two bad states: hand-run scripts
with no record of what went where, or a DACPAC publish that will happily drop
a column because the model says so.

This pipeline takes the middle path — the **DACPAC is the source of truth for
schema**, but every change reaches production as a **reviewed, ordered,
versioned migration script**, not an implicit diff.

```
  PR opened
     │
     ▼
  ┌──────────────────────────────┐
  │ pre-commit + CI gates        │  SQL lint, doc gate, sqlproj coverage
  └──────────────┬───────────────┘
                 ▼
  ┌──────────────────────────────┐
  │ build DACPAC                 │  the schema model
  └──────────────┬───────────────┘
                 ▼
  ┌──────────────────────────────┐
  │ generate migration script    │  PR's SQL diff vs base → reviewable .sql
  └──────────────┬───────────────┘
                 ▼
  ┌──────────────────────────────┐
  │ staging deploy + validate    │  Flyway ordering check
  └──────────────┬───────────────┘
                 ▼
  ┌──────────────────────────────┐
  │ approval → production deploy │  named approvers, policy gate
  └──────────────────────────────┘
```

## What's in the box

| Path | What it is |
|---|---|
| `.github/workflows/` | CI (demo build, pipeline gates, leak scan), migration-script generation, PR-approval bridge to Jenkins, nitsql SQL lint, skill-config drift sync, Claude Code PR review (`claude-code-review.yml` on open and ready, `claude-code-review-commits.yml` on each push) |
| `.github/scripts/migration-objects.ps1` | T-SQL parsing helpers the generator workflow uses to build the repeatable migration and check object order |
| `.githooks/` | `pre-commit` (doc gate, the pre-commit scan reminder, then nitsql SQL analysis), `pre-push` (the `/pr-ready` reminder), `commit-msg` (adds a `Co-authored-by: Claude` trailer), and the pre-PR gate and its state (`pr-ready-*.sh`) |
| `.claude/` | The `pr-ready`, `review-before-commit` and `review-db` skills, and `settings.json`, which runs the pre-PR gate before `gh pr create` and `gh pr ready` |
| `.sql-ready.conf` | The review flow's settings: base branch, paths it never reviews, the linter, the doc gate, the note every review follows |
| `scripts/setup-hooks.*` | Points the clone's `core.hooksPath` at `.githooks/` |
| `ci/leak-scan.sh` | CI check that fails on internal-identifier shapes and on the private terms you supply |
| `deploy/Jenkinsfile.*` | Staging and production pipelines with approval gates |
| `deploy/CICD_AppDb_Analytics_Generic_Migration_Script.ps1` | Assigns, re-dates and records migration versions in `VersionHistory` (staging-management job) |
| `deploy/Execute_Staging_Migrations.ps1` | Runs the branch's versioned, then repeatable, script on staging (staging-deployment job) |
| `deploy/Flyway_*.ps1` | Flyway deploy and migration-order validation |
| `deploy/flyway.*.conf` | Per-environment Flyway configuration |
| `deploy/*_Execute.ps1` | Production and staging wrappers that run the newest dated `.sql` through dbForge DevOps Automation; no Jenkinsfile calls them |
| `deploy/PolicyGate-Gate.ps1` | External policy/compliance gate call |
| `deploy/Validate-SqlprojCoverage.ps1` | Flags `.sql` files the `.sqlproj` does not reference at all (a warning by default; `-FailOnGap` makes it fail) |
| `demo/DemoDb/` | A tiny runnable database project to try the pipeline against |
| `Migration/DemoDb/` | Example Flyway-versioned migration |

## The gates worth stealing

Even if you don't adopt the whole pipeline, these three are independently useful:

- **`Validate-SqlprojCoverage.ps1`** — catches the single most common SSDT
  mistake: a `.sql` file added on disk but never registered in the `.sqlproj`,
  so it silently never deploys. It warns by default; pass `-FailOnGap` to fail
  the build instead.
- **`Flyway_Validate_Migration_Order.ps1`** — rejects a migration whose version
  sorts before one already applied, which is how two merged branches corrupt
  an environment.
- **`.githooks/sql-doc-gate.sh`** — blocks a commit while the branch's `.sql`
  changes (against `base_branch`) are newer than its docs: it hashes the
  changed files' content and compares that with what
  `bash .githooks/sql-doc-gate.sh --mark-done` last recorded for the branch.

## Quick start

Install the hooks:

```bash
./scripts/setup-hooks.sh          # or: pwsh scripts/setup-hooks.ps1
```

Build the demo project (needs the .NET 8 SDK: `global.json` pins it, because
`Microsoft.Build.Sql` 0.2.3-preview cannot be built by SDK 10):

```bash
dotnet build demo/DemoDb/DemoDb.sqlproj
```

Validate that every `.sql` file is registered (`-ProjectDir` takes the folder
that contains the `.sqlproj`):

```powershell
pwsh deploy/Validate-SqlprojCoverage.ps1 -ProjectDir demo/DemoDb
```

On the demo this currently warns that all four of its `.sql` files are
unreferenced: the validator counts only explicit `Include` items, and the
SDK-style project (`Microsoft.Build.Sql`) includes `**/*.sql` implicitly.

Check migration ordering: `deploy/Flyway_Validate_Migration_Order.ps1` is a
Jenkins step. It takes no parameters, reads the database login from the `USER`
and `PASS` environment variables and the checkout from `PR_WORKSPACE` and
`PR_BRANCH_SLUG` (which Jenkins sets), and validates against the live database
(`VersionHistory` plus `flyway validate`). The database-free half (version
format and duplicates in `Migration/DemoDb`) runs in the `Pipeline gates` job of
`.github/workflows/ci.yml`.

## Pre-PR review with Claude Code

The review flow is [sql-ready](https://github.com/Bugzbaggy/sql-ready), the standalone package,
installed here at the paths it uses in any repository. Its README covers the details: what the gate
outputs, what the stamp records, exit codes, and how to bypass it in an emergency.

| Piece | Where | What it does |
|---|---|---|
| `/review-before-commit` | `.claude/skills/review-before-commit/` | A low-effort `/review-db` pass over the staged changes. `.githooks/pre-commit` reminds when a commit hasn't had it, and never blocks |
| `/pr-ready` | `.claude/skills/pr-ready/` | Reviews the branch's commits (at most two passes), checks data-dependent findings against production when a read-only SQL tool is configured, fixes and commits what you pick, and records the review |
| The pre-PR gate | `.githooks/pr-ready-gate.sh`, registered in `.claude/settings.json` | Denies `gh pr create` and `gh pr ready` in Claude Code until `/pr-ready` has recorded a review that covers the branch's commits; turns `--no-verify` into a question |
| The reminders | `.githooks/pre-commit`, `.githooks/pre-push` | Warn only |
| The CI review | `.github/workflows/claude-code-review.yml`, `claude-code-review-commits.yml` | `/review-db` on PRs into the default branch and on each push, comments only. Without an `ANTHROPIC_API_KEY` secret, both skip with a notice |
| Settings | `.sql-ready.conf`, `.claude/skills/review-db/repo-notes/mssql-dacpac-cicd.md` | `skip_paths = Migration/ Archive/ deploy/` (generated or pipeline-owned), nitsql as the linter, the doc gate, and the demo's repository facts |

In Claude Code, on a feature branch:

```text
/review-before-commit     # before each commit
/pr-ready                 # before gh pr create or gh pr ready
```

The hooks enrol themselves: `.claude/settings.json` runs `.githooks/pr-ready-bootstrap.sh` at the
start of each session, which sets `core.hooksPath=.githooks` in a clone with no hooks of its own
(`./scripts/setup-hooks.sh` does the same by hand). To bring the flow into another repository, or
upgrade it here, run sql-ready's installer:

```bash
bash /path/to/sql-ready/install.sh --target .
```

## Adapting it

1. Replace `demo/DemoDb/` with your own database project. The workflows and
   deploy scripts are wired to a project folder and database named
   `AppDb_Analytics` (`DATABASE`/`DB_DIR` and the path filters in the workflows,
   `$database` in `deploy/*.ps1`, `DB_NAME`, `customWorkspace` and job paths in
   the Jenkinsfiles); rename them.
2. Point `deploy/flyway.*.conf` at your servers — they ship with placeholder
   listeners (`listener.example.com` in `flyway.stg.conf`,
   `listener.region1.example.com` in `flyway.prd.conf` and `flyway.validate.conf`)
   and `AppDb_Analytics` as the database. The `deploy/*.ps1` scripts hard-code the
   same listeners in `$server`, `$serverSTG` and `$serverPRD`.
3. Set the approver list (`DEPLOYMENT_APPROVERS`) and credential IDs in
   `deploy/Jenkinsfile.*`. They ship with placeholders: the approvers
   `approver1,approver2`, the Windows build agent label `windows-build-agent`, and the
   credential IDs `db-connect-credentials` (staging database login),
   `db-ci-credentials` (production database login), `github-app-credentials`,
   `ci-bot`, `slack-ci-token` (Slack notifications) and `POLICYGATE_API_KEY`.
4. Set your CODEOWNERS team in `.github/CODEOWNERS`.
5. `.github/workflows/jenkins-pr-approved.yml` runs on a `self-hosted` runner that
   can reach your Jenkins server; give it your runner's label.
6. `deploy/PolicyGate-Gate.ps1` accepts change tickets shaped `CHG-<number>`; pass
   `-TicketPrefix` for your change process's key.
7. `.github/workflows/generate-migration-scripts.yml` reads its prompts from the
   [sql-migration-generator](https://github.com/Bugzbaggy/sql-migration-generator)
   skill at `.claude/skills/sql-migration-generator/` and fails without it. Copy that
   repository's `skills/sql-migration-generator` folder there. Then, from the
   repository root, write the skill's config from your `.sqlproj` and render the
   repository section the generation prompt appends:

   ```bash
   pwsh .claude/skills/sql-migration-generator/scripts/sqlmig.ps1 init
   pwsh .claude/skills/sql-migration-generator/scripts/sqlmig.ps1 init -RenderRepoConfig \
     .claude/skills/sql-migration-generator/references/repo-config.md
   ```

   The skill provides everything the workflow reads:
   - `SKILL.md`, the generation prompt. The workflow fills in `{{DATABASE}}`,
     `{{BRANCH_NAME}}`, `{{DATE}}`, `{{NEXT_VERSION}}` and `{{CHANGED_FILES_JSON}}`,
     and the answer carries `<VERSION_MIGRATION>`/`<REPEATABLE_MIGRATION>` blocks.
   - `references/repo-config.md`, `idempotent-patterns.md`, `column-modification.md`,
     `sql-standards.md`, `index-standards.md` and `security-constraints.md`, which are
     appended to that prompt.
   - `references/impact-analysis.md` and `migration-review.md`, the prompts for the
     impact analysis (answered as `<IMPACT>` JSON) and the migration review
     (`<REVIEW>` JSON).

   `.github/workflows/sync-skill-config.yml` reads a `.claude/skills/sync-config/SKILL.md`
   that neither repository ships, plus the project's
   `AppDb_Analytics/Security/role_app_ci.sql`. It fails without them. Replace it with
   `sqlmig.ps1 init -Check`, which runs the same drift check deterministically and needs
   no API key. It exits 1 on a `$(Variable)` with no mapping and warns on a schema folder
   without deploy-role grants. `sqlmig.ps1 project -Apply` adds those grants.
8. Add the repository secrets the workflows read: `ANTHROPIC_API_KEY`
   (`generate-migration-scripts.yml`, `sync-skill-config.yml`,
   `claude-code-review.yml`, `claude-code-review-commits.yml`; the two review
   workflows skip with a notice without it); `JENKINS_URL`, `JENKINS_JOB`, `JENKINS_USER` and
   `JENKINS_API_TOKEN` (`jenkins-pr-approved.yml`); and `LEAK_EXTRA_PAT` /
   `LEAK_EXTRA_PAT_CS` for the leak scan in `ci.yml` — set these to your own
   private terms. The leak scan fails on pushes and same-repository pull requests
   when either is missing.
9. The base branch. The GitHub workflows follow the repository's default branch,
   whatever it is called: `nitsql.yml` and `sync-skill-config.yml` run for pushes
   to it, and `generate-migration-scripts.yml` and the two review workflows for
   pull requests into it. The hooks, the pre-PR gate and the reminders read
   `base_branch` from `.sql-ready.conf` (`main` here); set it to yours. The
   Jenkinsfiles and `deploy/*.ps1` are the exception: they name `master` in Jenkins
   job and workspace paths (`..._PRODUCTION_master`) and in the fetch, merge and
   diff steps of `deploy/Jenkinsfile.staging.management`. Rename those if your
   default branch is something else. In this repository the generator and the sync
   workflow stay idle because there is no `AppDb_Analytics/` folder for their path
   filters to match.

Credentials are referenced by environment variable and CI credential ID — no
secret is stored in this repo, and `.gitignore` is configured to keep it that way.

## A note on scope

This repository is the **pipeline**, deliberately without the database it was
built for. The original schema was a production analytics database; publishing
it would have meant publishing commercial pricing and billing logic rather than
reusable engineering.

`demo/DemoDb/` exists so the pipeline is runnable end to end. Every hostname,
database name, role, and approver here is a placeholder.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
