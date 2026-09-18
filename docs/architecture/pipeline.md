---
status: implemented
---

# CI/CD Pipeline & Migrations

**Status:** Implemented

How migration scripts are generated, versioned, and deployed for AppDb_Analytics.
This is reference material — for day-to-day rules see `CLAUDE.md`
and the `sql-gener8-migration` skill.

## Pipeline Architecture

The project uses a two-stage CI/CD pipeline.

### 1. CI Pipeline: Migration Script Generation

**Script**: `CICD_AppDb_Analytics_Generic_Migration_Script.ps1`
**Purpose**: Generates and manages version-controlled migration scripts.

**Process Flow**:
1. **Connection Testing**: Validates database connectivity to staging environment
2. **Folder Processing**: Monitors Jenkins workspace for new build folders
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

**Script**: `Flyway_PRD_Deploy.ps1`
**Purpose**: Deploys migration scripts using Flyway and tracks deployment status.

**Process Flow**:
1. **Pre-Migration Check**: Gets current Flyway schema version
2. **Flyway Execution**: Runs migration with comprehensive output capture
3. **Success Handling**:
   - Parses Flyway output to identify successfully deployed versions
   - Updates `VersionHistory` with `IsDeployed = 1`, `DeployDate`, and success notes
4. **Error Handling**:
   - Identifies failed versions from Flyway output
   - Updates `DeployNote` with error information (without changing `IsDeployed` status)
   - Exits cleanly for manual review

## Migration Scripts

> Migration scripts are **automatically generated** by the GitHub Actions
> workflow `.github/workflows/generate-migration-scripts.yml`. Never create,
> modify, or delete them manually.

**File Naming Standards** (Flyway V7+ Format):

```
Versioned Migrations: V{major}.{minor}__{date}.{database}.{branchname}.sql
Repeatable Migrations: R__{date}.{database}.{branchname}.sql
```

**Version Format**: V1.00000 to V999.99999
- Major version: 1-999 (no zero padding)
- Minor version: 00000-99999 (5-digit zero padding)

**Examples**:
- `V1.00001__2025-09-24.AppDb_Analytics.CICD-T1012.sql`
- `V12.00015__2025-11-05.AppDb_Analytics.feature-branch.sql`
- `V999.99999__2025-12-31.AppDb_Analytics.hotfix-urgent.sql`
- `R__2025-09-24.AppDb_Analytics.CICD-T1012.sql`

**When each type is generated**:
- **Version migrations** — schema structure changes (tables/indexes/FKs/synonyms/UDTs), data updates, reference data
- **Repeatable migrations** — views, stored procedures, functions, triggers
  - Use `CREATE OR ALTER` syntax in migration scripts, never DROP and CREATE — ensures safe redeployment without losing permissions or dependencies

**Rules**:
- **Branch Migration Cleanup (MANDATORY)** — all existing migration scripts on a branch are replaced so each commit/PR carries one unique script with all accumulated changes; prevents multiple files per branch that could cause deployment conflicts
- **Automatic Processing** — CI handles version numbering and conflict resolution
- **Date Consistency** — CI updates script dates to current date automatically
- **Rollback Scripts** — placed in `Archive\` with `ROLLBACK.` prefix

## VersionHistory Table

The CI/CD pipeline tracks all migration versions in `VersionHistory`.

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
- **Production**: `listener.example.com/AppDb_Analytics`

## Version Conflict Resolution

The CI pipeline automatically handles version conflicts.

### Automatic Reassignment
- **Scenario**: When a version would break Flyway's sequential deployment
- **Action**: Automatically assigns next available version number
- **Tracking**: Records both original and new version in VersionHistory
- **File Management**: Renames script files to match new version

### Version Numbering Logic
- **Sequential**: Each new version increments minor version by 1
- **Rollover**: When minor reaches 99999, major increments and minor resets to 1
- **Conflict Resolution**: If version already exists, finds next available version
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
- Updates VersionHistory: `IsDeployed = 1`, `DeployNote = 'Successfully deployed'`
- Continues with next folder processing

### Failure Path
- Identifies specific failed versions from Flyway output
- Updates only `DeployNote = 'Error: [details]'` for affected versions
- Preserves `IsDeployed = 0` for retry capability
- Exits cleanly for manual intervention

### Manual Recovery
- Check VersionHistory table for error details
- Review Flyway output in deployment logs
- Fix issues and re-run CD pipeline — undeployed versions retry automatically

## Development Workflow

1. **Schema Changes**: Make changes to SQL objects in the appropriate schema directories (`AppDb_Analytics\{schema}\Tables\`, `AppDb_Analytics\{schema}\Stored Procedures\`, etc.)
2. **Commit and Push**: Commit changes to your feature branch and push to GitHub
3. **Create Pull Request**: Open/update a PR against master
4. **Automatic Migration Generation**: the GitHub Actions workflow detects SQL changes, retrieves content for deleted files from origin/master, categorizes changes (Version vs. Repeatable), generates scripts with IF EXISTS/IF NOT EXISTS checks, handles version conflicts, and commits the scripts back to the PR
5. **Review Generated Scripts**: Check the `Migration\` folder
6. **Testing**: Pipeline deploys to staging with full tracking
7. **CD Pipeline**: After merge, handles production deployment with error tracking
8. **Code Review**: Review and merge when ready

## References

- `schema-map.md` — schema organization
- [`security-model.md`](security-model.md) — CI/CD account permissions
- `sql-gener8-migration` skill — migration script generation and standards
