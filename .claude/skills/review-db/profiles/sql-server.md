# Profile: SQL Server (SSDT projects, Flyway migrations, plain T-SQL)

## Severe here
- **The publish rebuilds or refuses.** SSDT rebuilds a table when a column is added anywhere but
  the end (unless `IgnoreColumnOrder` is set), and `BlockOnPossibleDataLoss` stops a publish that
  drops or narrows a column. Check the row count first.
- **A released migration is edited.** An applied Flyway `V__` script's checksum changes, so
  `validate` fails wherever it ran. The fix is a new version.
- **A contract changes and its callers don't.** A new parameter without a default, a renamed or
  reordered result column, or a dropped column a view or synonym still names.
- **A re-run duplicates.** SSDT post-deployment scripts run on every publish, and a Flyway `R__`
  script runs again whenever it changes. An INSERT without an existence check adds rows each time.
- **An error disappears.** A `CATCH` that neither re-throws nor records the error, work after
  `XACT_STATE() = -1`, or `XACT_ABORT OFF` where a client timeout leaves the transaction open.
- **An upsert races.** `IF NOT EXISTS … INSERT`, or `MERGE`, without `UPDLOCK, HOLDLOCK` gives
  duplicate-key errors under concurrent callers.
- **A permission is wrong.** A grant to `public`, a new object the app role can't execute, or an
  Agent job step whose owner lacks rights in another database it reads.
- **An index build blocks writers.** Without `ONLINE = ON` (Enterprise or Azure SQL only), an index
  build on a large table blocks writes until it ends.

## How to prove it
- The table DDL and indexes at the head: types, nullability, defaults, constraints, triggers.
- For performance, the index the query needs. An `nvarchar` parameter against an indexed `varchar`
  column scans under a SQL collation.
- For engine behaviour, a minimal repro in a SQL Server 2022 container.
- Row counts and timings only through the read-only tool the repo notes name.

## Not findings
- Formatting, casing, header blocks, change-history lines, CHANGELOG wording, branch names.
- What the repository's linter already reports.
- Files under `skip_paths` in `.sql-ready.conf`.
- Missing tests, unless the repository requires them.

## Fix rules
- Re-runnable: `CREATE OR ALTER`, existence checks, data fixes that change nothing on a second run.
- Large writes in key-range batches, one transaction each.
- `THROW` numbers from the repository's range, 50000 and up.
- Upsert as UPDATE then INSERT in one transaction, with `UPDLOCK, HOLDLOCK` on the UPDATE.
