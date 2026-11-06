---
status: implemented
---

# Security Model

Who may change the database, and how little the pipeline's own account can do. The migration
rules that go with it are in `references/security-constraints.md` of the
[sql-migration-generator](https://github.com/Bugzbaggy/sql-migration-generator) skill, installed at
`.claude/skills/sql-migration-generator/`.

## People

People reach the database through roles, one per team or application (`role_team_ops`,
`role_team_dev`, `role_app_reporting` and so on), and each person's login is a member of the roles
their work needs. The roles live in the database project, not in this repository.

## The deploy account

Flyway runs from Jenkins as one SQL Server login, a member of `role_app_ci`. In production the
login comes from the Jenkins credential `db-ci-credentials`. The role is defined in the database
project's `Security/role_app_ci.sql`; neither it nor the script that creates the login ships here.

What the role holds:

| Scope | Permissions |
|---|---|
| Database | `CREATE TABLE`, `CREATE PROCEDURE`, `CREATE VIEW`, `CREATE FUNCTION`, `CREATE TYPE`, `CREATE SYNONYM`, `CREATE SCHEMA` |
| Each user schema | `ALTER`, `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `EXECUTE`, `REFERENCES` |
| Metadata | `VIEW DEFINITION`, `VIEW DATABASE STATE` |
| Flyway's own tables | `SELECT`, `INSERT`, `UPDATE`, `DELETE` on `dbo.flyway_schema_history` and `dbo.VersionHistory` |

A new schema needs its seven schema grants before the role can deploy into it.
`generate-migration-scripts.yml` adds them to `role_app_ci.sql` when a branch adds a schema folder,
`sqlmig.ps1 init -Check` lists any schema folder still without them, and `sqlmig.ps1 project -Apply`
adds them.

## What it is never given

| Not granted | Because with it the account could |
|---|---|
| `CONTROL` on a schema | drop the schema with everything in it, grant its permissions to anyone, and change or take its ownership |
| `db_owner` | do all of the above database-wide, and manage users, keys, certificates and database settings |
| `ALTER ANY DATABASE`, `CONTROL SERVER` | drop or reconfigure the database itself, or any other on the instance |
| Backup and restore | overwrite the database or copy it out |
| Security principals | create logins or users, or change role membership, including its own |

`CONTROL` on a schema is the one most often handed out for convenience. Deployments never need it:
`ALTER` on the schema plus the database-level `CREATE` permissions cover creating, changing and
dropping the objects in it, and what `CONTROL` adds on top (`DROP SCHEMA`, `GRANT`,
`ALTER AUTHORIZATION`, `TAKE OWNERSHIP`) is the part that turns a bad script or a leaked password
into an outage or a privilege escalation.

## What that still allows

`ALTER` on a schema lets the account drop any table, view or procedure in it, and a migration
legitimately needs that. Nothing in the permissions stops a wrong `DROP TABLE`. What stops it is the
path every script takes: generated from a reviewed branch, run on staging first, deployed to
production only after an approval, and kept in git and in `VersionHistory`. What the permissions
do guarantee is the ceiling: a compromised deploy password can damage objects, but cannot remove a
schema, hand out access, or reach beyond this database.

## References

- [`pipeline.md`](pipeline.md): where the account is used
- `references/security-constraints.md` in the
  [sql-migration-generator](https://github.com/Bugzbaggy/sql-migration-generator) skill: what a
  migration may and may not contain
- `Security/role_app_ci.sql` in the database project: the role itself (not shipped here)
