# mssql-dacpac-cicd

A complete CI/CD pipeline for SQL Server database projects: SSDT/DACPAC build,
Flyway-versioned migrations, policy gates, and staged promotion from staging to
production with approvals.

[![SQL Server](https://img.shields.io/badge/SQL%20Server-2019%2B-CC2927)](https://learn.microsoft.com/sql/)
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
  │ generate migration script    │  diff vs target → reviewable .sql
  └──────────────┬───────────────┘
                 ▼
  ┌──────────────────────────────┐
  │ staging deploy + validate     │  Flyway ordering check
  └──────────────┬───────────────┘
                 ▼
  ┌──────────────────────────────┐
  │ approval → production deploy  │  named approvers, policy gate
  └──────────────────────────────┘
```

## What's in the box

| Path | What it is |
|---|---|
| `.github/workflows/` | Migration-script generation, PR-approval bridge, SQL lint |
| `.githooks/` | `pre-commit` SQL analysis, `commit-msg` format, doc gate |
| `deploy/Jenkinsfile.*` | Staging and production pipelines with approval gates |
| `deploy/Flyway_*.ps1` | Flyway deploy and migration-order validation |
| `deploy/flyway.*.conf` | Per-environment Flyway configuration |
| `deploy/*_Execute.ps1` | Environment-specific execution wrappers |
| `deploy/PolicyGate-Gate.ps1` | External policy/compliance gate call |
| `deploy/Validate-SqlprojCoverage.ps1` | Fails the build if a `.sql` file isn't registered in the `.sqlproj` |
| `demo/DemoDb/` | A tiny runnable database project to try the pipeline against |
| `Migration/DemoDb/` | Example Flyway-versioned migration |

## The gates worth stealing

Even if you don't adopt the whole pipeline, these three are independently useful:

- **`Validate-SqlprojCoverage.ps1`** — catches the single most common SSDT
  mistake: a `.sql` file added on disk but never registered in the `.sqlproj`,
  so it silently never deploys.
- **`Flyway_Validate_Migration_Order.ps1`** — rejects a migration whose version
  sorts before one already applied, which is how two merged branches corrupt
  an environment.
- **`.githooks/sql-doc-gate.sh`** — requires that a new object carries
  documentation before it can be committed.

## Quick start

Install the hooks:

```bash
./scripts/setup-hooks.sh          # or: pwsh scripts/setup-hooks.ps1
```

Build the demo project:

```bash
dotnet build demo/DemoDb/DemoDb.sqlproj
```

Validate that every `.sql` file is registered:

```powershell
pwsh deploy/Validate-SqlprojCoverage.ps1 -ProjectPath demo/DemoDb/DemoDb.sqlproj
```

Check migration ordering:

```powershell
pwsh deploy/Flyway_Validate_Migration_Order.ps1 -MigrationPath Migration/DemoDb
```

## Adapting it

1. Replace `demo/DemoDb/` with your own database project.
2. Point `deploy/flyway.*.conf` at your servers — they ship with placeholder
   listeners (`listener.example.com`) and `AppDb_Analytics` as the database.
3. Set the approver list and credential IDs in `deploy/Jenkinsfile.*`.
4. Set your CODEOWNERS team in `.github/CODEOWNERS`.

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
