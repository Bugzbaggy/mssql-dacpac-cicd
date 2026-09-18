# nitsql Local Pre-Commit Hook

Vendored from the [`nitsql`](https://github.com/Bugzbaggy/nitsql) plugin (v6.0.0+).

## What it does

Runs the multi-dialect SQL analyzer on every `git commit` against staged
`*.sql` files. Auto-detects MSSQL / PostgreSQL / Oracle / MySQL / SQLite from
syntax — no configuration.

| Severity | Behavior |
|----------|----------|
| CRITICAL | **blocks** the commit (exit 1) |
| HIGH / MEDIUM / LOW | warns, allows the commit |
| no SQL staged | exits silently |

## Strict enforcement

The authoritative gate is the **`nitsql` GitHub Actions workflow** at
`.github/workflows/nitsql.yml`. It runs on every PR and push to `master`,
fails the build on CRITICAL findings, and **cannot be bypassed by skipping
the local hook** — the local hook is just fast feedback.

## Enabling locally (one time per clone)

```bash
# macOS / Linux / Git Bash on Windows
.githooks/bootstrap.sh

# Windows cmd / PowerShell
.githooks\bootstrap.cmd
```

This sets `git config --local core.hooksPath .githooks` and survives every
subsequent `git pull` because the hooks live in the repo.

## Bypassing (discouraged)

`git commit --no-verify` skips the local hook. CI will still reject the PR
if a CRITICAL finding lands.

## Files

| File | Purpose |
|------|---------|
| `pre-commit` | bash hook invoked by git |
| `analyze_sql.py` | the 52-rule analyzer (Python 3.8+) |
| `bootstrap.sh` / `bootstrap.cmd` | one-time enrolment scripts |

## Updating

The CI workflow refreshes `analyze_sql.py` from the marketplace on every run,
committing back to `master` when the upstream version changes. You'll get the
latest analyzer on your next `git pull`.
