---
status: implemented
---

# Security Model

**Status:** Implemented

Role-based access control for AppDb_Analytics and the least-privilege model for
the CI/CD deployment account. For migration-specific security rules, see
`.claude/skills/sql-migration-generator/references/security-constraints.md`
(part of the `sql-migration-generator` skill, which this repository does not ship).

## Application Roles

Role-based access control with team-specific roles:
- `role_team_ops`, `role_team_dev`, `role_app_reporting`, etc.
- Individual user accounts with appropriate role assignments

## CI/CD Security (CI/CD login / role_app_ci)

- Dedicated SQL Server login for Jenkins Flyway deployments (production stores it as the Jenkins credential `db-ci-credentials`)
- Follows the **Principle of Least Privilege** for automated deployments
- The role is defined in the database project's `Security/role_app_ci.sql` (not shipped here); `generate-migration-scripts.yml` adds the seven schema-level grants below for every new schema folder, and `sync-skill-config.yml` reconciles the file with the repository. The login/role creation scripts are not shipped either

**Granted Permissions:**
- Database-level: CREATE TABLE, CREATE PROCEDURE, CREATE VIEW, CREATE FUNCTION, CREATE TYPE, CREATE SYNONYM, CREATE SCHEMA
- Schema-level: ALTER, SELECT, INSERT, UPDATE, DELETE, EXECUTE, REFERENCES on all user schemas
- Metadata access: VIEW DEFINITION, VIEW DATABASE STATE
- Flyway tables: SELECT, INSERT, UPDATE, DELETE on `dbo.flyway_schema_history` and `dbo.VersionHistory`

**Explicitly Denied Permissions:**
- Server-level: ALTER ANY DATABASE (prevents DROP DATABASE), CONTROL SERVER
- Database-level: db_owner role, backup/restore operations, security principal management
- **Schema-level: CONTROL ON SCHEMA (see below)**

## Why CONTROL ON SCHEMA Is Excluded

CONTROL ON SCHEMA is explicitly **NOT granted** to CI/CD accounts due to severe security risks:

| Risk | Impact | Why It Matters |
|------|--------|----------------|
| **DROP SCHEMA capability** | Can destroy entire schemas (hundreds of objects) | One malicious/buggy script can wipe out entire functional areas |
| **Permission management** | Can GRANT/REVOKE permissions to other users | Enables privilege escalation and backdoor creation |
| **Ownership transfer** | Can change schema ownership | Attacker can take control of entire schema architecture |
| **Take ownership** | Can seize ownership of individual objects | Bypasses security controls and audit trails |

**What CI/CD CAN Do (Without CONTROL):**
- Create new objects (tables, views, procedures, functions) in existing schemas
- Alter/modify existing objects within schemas
- Drop individual objects (tables, views, etc.) — mitigated by code review
- Create new schemas (if CREATE SCHEMA is granted)
- Execute stored procedures and query data

**What CI/CD CANNOT Do (Blocked by Excluding CONTROL):**
- Drop entire schemas
- Grant permissions to other users/roles
- Transfer schema ownership
- Take ownership of objects
- Alter authorization on schemas

**Security Trade-off:**
- ✅ Allows all legitimate Flyway migration operations
- ✅ Prevents catastrophic schema deletion
- ✅ Blocks privilege escalation attacks
- ✅ Limits blast radius if credentials compromised
- ✅ Maintains audit compliance (SOC 2, ISO 27001)
- ⚠️ Individual objects can still be dropped (mitigated by: code review, version control, audit logging, staging testing)

**Comparison with db_owner:**
The CI/CD role is intentionally more restrictive than `db_owner`:
- Cannot drop the database itself
- Cannot backup/restore databases
- Cannot create/modify logins or database users
- Cannot alter database-level settings
- Cannot manage encryption keys or certificates

## References

- `.claude/skills/sql-migration-generator/references/security-constraints.md` — migration security rules (not shipped here)
- [`pipeline.md`](pipeline.md) — how the CI/CD account is used
- `Security/role_app_ci.sql` in the database project — role implementation (not shipped here)
