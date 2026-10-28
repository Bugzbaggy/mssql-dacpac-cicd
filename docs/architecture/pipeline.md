---
status: implemented
---

# CI/CD Pipeline & Migrations

**Status:** Implemented

How migration scripts are generated, versioned, and deployed for AppDb_Analytics.
This is reference material — for day-to-day rules see the database project's `CLAUDE.md`
and the `sql-migration-generator` skill (neither is shipped in this repository; see "Adapting it" in the README).

## Pipeline Architecture

The project uses a two-stage CI/CD pipeline.

### 1. CI Pipeline: Migration Script Versioning

**Script**: `CICD_AppDb_Analytics_Generic_Migration_Script.ps1`, run by the "Migration Management" stage of `deploy/Jenkinsfile.staging.management`
**Purpose**: Versions, re-dates and records the migration scripts the generator workflow committed.

**Process Flow**:
1. **Connection Testing**: Validates connectivity to the production database (`$serverPRD`), which holds `VersionHistory`
2. **Folder Processing**: Processes the checkout Jenkins pins with `PR_WORKSPACE` / `PR_BRANCH_SLUG`; without them it falls back to the newest `AppDb_Analytics_STG_MGR_*` folder under `C:\Jenkins\workspace\`
3. **Script Date Validation**: Updates migration script dates to current date if needed
4. **Version Management**:
   - Checks VersionHistory table for existing versions
   - Handles version conflicts and reassignments to maintain Flyway sequence
   - Creates new version records or updates existing ones
5. **Database Tracking**: Records all version information in `VersionHistory` table

**Key Features**:
- Automatic version conflict resolution
- Deployment sequence validation
- Branch-based version tracking
- Script file renaming for date consistency

### 2. CD Pipeline: Flyway Deployment

**Script**: `Flyway_PRD_Deploy.ps1`, run by `deploy/Jenkinsfile.production` after the deployment approval and the PolicyGate pre-deploy gate (a DENY blocks)
**Purpose**: Deploys migration scripts using Flyway and tracks deployment status.

**Process Flow**:
1. **Pre-Migration Check**: Gets current Flyway schema version
2. **Flyway Execution**: Runs migration with comprehensive output capture
3. **Success Handling**:
   - Parses Flyway output to identify successfully deployed versions
   - Updates `VersionHistory` with `IsDeployed = 1`, `DeployDate`, and success notes
   - If Flyway applied nothing but the checked-out `Migration` folder holds a versioned script newer than the database's current version, fails the build instead of reporting success (stale-checkout guard)
4. **Error Handling**:
   - Identifies failed versions from Flyway output
   - Updates `DeployNote` with error information and sets `DeployDate` (without changing `IsDeployed` status)
   - Exits with code 1, failing the Jenkins stage, for manual review

## Migration Scripts

> Migration scripts are **automatically generated** by the GitHub Actions
> workflow `.github/workflows/generate-migration-scripts.yml`. Never create,
> modify, or delete them manually.

**File Naming Standards** (Flyway V7+ Format):

```
Versioned Migrations: V{major}.{minor}__{date}.{database}.{branchname}.sql
Repeatable Migrations: R__{date}.{database}.{branchname}.sql
```

`{branchname}` is the branch with `/` replaced by `.` (e.g. `feature/x` → `feature.x`).

**Version Format**: V1.00000 to V999.99999
- Major version: 1-999 (no zero padding)
- Minor version: 00000-99999 (5-digit zero padding)

**Examples**:
- `V1.00001__2025-09-24.AppDb_Analytics.PROJ-1012.sql`
- `V12.00015__2025-11-05.AppDb_Analytics.feature-branch.sql`
- `V999.99999__2025-12-31.AppDb_Analytics.hotfix-urgent.sql`
- `R__2025-09-24.AppDb_Analytics.PROJ-1012.sql`

**When each type is generated**:
- **Version migrations** — schema structure changes (tables/indexes/FKs/synonyms/UDTs), data updates, reference data
- **Repeatable migrations** — views, stored procedures, functions, triggers
  - Use `CREATE OR ALTER` syntax in migration scripts, never DROP and CREATE — ensures safe redeployment without losing permissions or dependencies

**Rules**:
- **Branch Migration Cleanup (MANDATORY)** — all existing migration scripts on a branch are replaced so each commit/PR carries at most one versioned and one repeatable script with all accumulated changes; prevents multiple files per branch that could cause deployment conflicts
- **Automatic Processing** — CI handles version numbering and conflict resolution
- **Date Consistency** — CI updates script dates to current date automatically
- **Rollback Scripts** — placed in `Archive\` with `ROLLBACK.` prefix

## VersionHistory Table

The CI/CD pipeline tracks all migration versions in `VersionHistory` in the production database; the staging deploy reads it from there.

**Key Columns**:
- `VersionId`: Version number without 'V' prefix (e.g., "1.00001", "12.00015")
- `VersionPR`: Version number with 'V' prefix (e.g., "V1.00001", "V12.00015")
- `BranchName`: Git branch name
- `BranchDate`: When the version was created/updated
- `IsDeployed`: Boolean flag for deployment status
- `DeployDate`: When the version was actually deployed
- `DeployNote`: Success message or error details
- `ReassignmentNote`: Details if version was reassigned due to conflicts
- `Script`: Migration script filename

**Pipeline Integration**:
- **CI Phase**: Creates/updates version records, handles conflicts
- **CD Phase**: Updates deployment status and notes

### Database Environments
- **Staging**: `listener.example.com/AppDb_Analytics`
- **Production**: `listener.region1.example.com/AppDb_Analytics`

## Version Conflict Resolution

The CI pipeline automatically handles version conflicts.

### Automatic Reassignment
- **Scenario**: When a version would break Flyway's sequential deployment
- **Action**: Automatically assigns next available version number
- **Tracking**: Any outdated record for the branch is deleted, and the new record's `ReassignmentNote` names the original version
- **File Management**: Renames script files to match new version

### Version Numbering Logic
- **Sequential**: Each new version increments minor version by 1
- **Rollover**: When minor reaches 99999, major increments and minor resets to 1
- **Conflict Resolution**: The next version after the latest deployed one is assigned. If another branch holds it but has not deployed, that branch's record is removed and the version goes to the current branch; if a deployed version holds it, the version after the highest recorded one is used
- **Gap Prevention**: Ensures no deployment sequence gaps

```
V1.00001 → V1.00002 → V1.00003 → ... → V1.99999 → V2.00001 → V2.00002
```

### Deployment Sequence Validation
- Ensures no version gaps in deployment sequence
- Prevents deployment of versions lower than already-deployed versions
- Maintains Flyway compatibility

## Error Handling and Recovery

### Success Path
- Parses Flyway output for successfully deployed versions
- Updates VersionHistory: `IsDeployed = 1`, `DeployDate`, `DeployNote = 'Successfully deployed'`
- Fails the build if Flyway applied nothing while the Migration folder holds a versioned script newer than the database's current version

### Failure Path
- Identifies specific failed versions from Flyway output
- Updates `DeployNote = 'Error: [details]'` and `DeployDate` for affected versions
- Preserves `IsDeployed = 0` for retry capability
- Exits with code 1 for manual intervention

### Manual Recovery
- Check VersionHistory table for error details
- Review Flyway output in deployment logs
- Fix issues and re-run CD pipeline — undeployed versions retry automatically

## Development Workflow

1. **Schema Changes**: Make changes to SQL objects in the appropriate schema directories (`AppDb_Analytics\{schema}\Tables\`, `AppDb_Analytics\{schema}\Stored Procedures\`, etc.)
2. **Commit and Push**: Commit changes to your feature branch and push to GitHub
3. **Create Pull Request**: Open/update a PR against master
4. **Automatic Migration Generation**: the GitHub Actions workflow detects SQL changes, blocks on CRITICAL nitsql findings in the changed source files, retrieves content for deleted files from origin/master, categorizes changes (Version vs. Repeatable), generates scripts with IF EXISTS/IF NOT EXISTS checks (the repeatable script is rebuilt from the changed source files), handles version conflicts, has Claude review the scripts (syntax errors, or references to objects that exist nowhere, fail the job), checks the object order in both scripts (anything used before it is created, or after it is dropped, fails the job), adds grants for new schemas to `role_app_ci.sql`, updates the `.sqlproj`, and commits the scripts back to the PR
5. **Review Generated Scripts**: Check the `Migration\` folder
6. **Testing**: Approving the PR makes `.github/workflows/jenkins-pr-approved.yml` start the Jenkins job named in its `JENKINS_JOB` secret with `PR_NUMBER`, `PR_BRANCH` and `GIT_COMMIT_HASH` — the parameters of `deploy/Jenkinsfile.staging.management`, which versions the scripts, validates their order and triggers `deploy/Jenkinsfile.staging.deployment`. That job runs the branch's versioned, then repeatable, script on staging (`Execute_Staging_Migrations.ps1`)
7. **CD Pipeline**: After merge, `deploy/Jenkinsfile.production` waits for approval by `DEPLOYMENT_APPROVERS`, runs the PolicyGate pre-deploy gate (a DENY blocks), and deploys to production with error tracking
8. **Code Review**: `.github/workflows/claude-code-review.yml` runs Claude Code's `/code-review` on the PR and posts its findings as inline comments (comment `/code-review [effort]` to re-run it); it never blocks. Review and merge when ready

## References

- `schema-map.md` — schema organization (part of the database project; not shipped here)
- [`security-model.md`](security-model.md) — CI/CD account permissions
- `sql-migration-generator` skill — migration script generation and standards. Not shipped here: the generator workflow reads it from `.claude/skills/sql-migration-generator/` and fails without it (see "Adapting it" in the README for the files it must provide)
