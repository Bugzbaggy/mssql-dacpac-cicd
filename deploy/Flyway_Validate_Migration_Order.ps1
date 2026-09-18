<#
.SYNOPSIS
    Validates migration version order using Flyway validate command.

.DESCRIPTION
    Performs comprehensive validation of migration scripts to ensure proper version ordering
    and prevent deployment conflicts before PR merge. This script checks:
    - Version sequence integrity for CURRENT BRANCH ONLY
    - Missing migrations
    - Checksum consistency
    - Version conflicts with already deployed migrations
    
    Author: Renz Bagasbas
    Date: October 13, 2025
    Updated: November 2025 - Changed version format from V000.00000 to V1.00000
#>

#region Variables
$SourceUser = $Env:USER
$SourcePass = $Env:PASS   
# Alternate way to load environment variables for local testing
#$SourceUser = [System.Environment]::GetEnvironmentVariable("STG_DB_USER", [System.EnvironmentVariableTarget]::User)
#$SourcePass = [System.Environment]::GetEnvironmentVariable("STG_DB_PASS", [System.EnvironmentVariableTarget]::User)

#$server = 'listener.example.com' #stagingDB
$server = 'listener.region1.example.com'
$database = 'AppDb_Analytics'
$isWindowsAuthentication = $false
$rootFolder = "C:\Jenkins\workspace"

Write-Host "=== Flyway Migration Validation ===" -ForegroundColor Cyan
Write-Host "Server: $server" -ForegroundColor Gray
Write-Host "Database: $database" -ForegroundColor Gray
Write-Host ""

if ($isWindowsAuthentication -eq $true) {
    $connectionString = "Server=$server;Database=$database;Integrated Security=True;"
} else {
    $connectionString = "Server=$server;Database=$database;User ID=$SourceUser;Password=$SourcePass;"
}

Write-Host "Testing database connection..." -ForegroundColor Cyan
$connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
try {
    $connection.Open()
    Write-Host "Connection successful" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host "Connection failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    $connection.Close()
}
#endregion

#region SQL Query Function
function Invoke-SqlQueryWithParams {
    param (
        [string]$query,
        [string]$connectionString,
        [hashtable]$parameters = @{}
    )
    
    $connection = $null
    $command = $null
    $adapter = $null
    
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        
        $command = $connection.CreateCommand()
        $command.CommandText = $query
        $command.CommandTimeout = 30
        
        foreach ($key in $parameters.Keys) {
            [void]$command.Parameters.AddWithValue($key, $parameters[$key])
        }
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $dataTable = New-Object System.Data.DataTable
        
        [void]$adapter.Fill($dataTable)
        
        return ,$dataTable
    }
    catch {
        Write-Host "SQL query failed: $($_.Exception.Message)" -ForegroundColor Red
        
        $emptyTable = New-Object System.Data.DataTable
        return ,$emptyTable
    }
    finally {
        if ($adapter) { $adapter.Dispose() }
        if ($command) { $command.Dispose() }
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
            $connection.Dispose()
        }
    }
}
#endregion

#region Branch Detection
function Get-CurrentBranchName {
    param(
        [string]$migrationPath,
        [string]$connectionString,
        [string]$workspaceName
    )
    
    # Primary method: Extract branch from workspace path
    # Pattern: AppDb_Analytics_STAGING_{BranchName}
    if ($workspaceName -match "AppDb_Analytics_STG_MGR_(.+)$") {
        $branchFromPath = $matches[1]
        Write-Host "Branch detected from workspace: $branchFromPath" -ForegroundColor Green
        return $branchFromPath
    }
    
    # Fallback method 1: Scan SQL files for branch name
    Write-Host "Warning: Could not extract branch from workspace name '$workspaceName', checking files..." -ForegroundColor Yellow
    $sqlFiles = Get-ChildItem -Path $migrationPath -Filter "*.sql" -ErrorAction SilentlyContinue
    
    foreach ($file in $sqlFiles) {
        # Updated pattern for new version format V1.00000
        if ($file.Name -match "^V\d{1,3}\.\d{5}__\d{4}-\d{2}-\d{2}\.$database\.(.+)\.sql$") {
            $branchFromFile = $matches[1]
            Write-Host "Warning: Branch detected from filename: $branchFromFile" -ForegroundColor Yellow
            return $branchFromFile
        }
        if ($file.Name -match "^R__\d{4}-\d{2}-\d{2}\.$database\.(.+)\.sql$") {
            $branchFromFile = $matches[1]
            Write-Host "Warning: Branch detected from repeatable filename: $branchFromFile" -ForegroundColor Yellow
            return $branchFromFile
        }
    }
    
    # Fallback method 2: Query database for undeployed versions (LEAST RELIABLE)
    Write-Host "Warning: No files found, checking database for undeployed versions..." -ForegroundColor Yellow
    $undeployedQuery = 'SELECT DISTINCT BranchName, VersionPR FROM VersionHistory WHERE IsDeployed = 0 ORDER BY VersionPR DESC'
    
    try {
        $emptyParams = @{}
        $dataTable = Invoke-SqlQueryWithParams -query $undeployedQuery -connectionString $connectionString -parameters $emptyParams
        
        if ($dataTable.Rows.Count -gt 0) {
            $detectedBranch = $dataTable.Rows[0]["BranchName"].ToString().Trim()
            Write-Host "Warning: Branch detected from database (unreliable): $detectedBranch" -ForegroundColor Yellow
            return $detectedBranch
        }
    } catch {
        Write-Host "Warning: Could not query database: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    return $null
}
#endregion

#region Workspace Path Detection
function Get-WorkspaceMigrationPath {
    Write-Host "Searching for workspaces in: $rootFolder" -ForegroundColor Gray
    
    # Check if root folder exists
    if (-not (Test-Path $rootFolder)) {
        Write-Host "ERROR: Root folder does not exist: $rootFolder" -ForegroundColor Red
        return $null
    }
    

    $workspacePattern = "AppDb_Analytics_STG_MGR_*"
    $allWorkspaces = Get-ChildItem -Path $rootFolder -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like $workspacePattern
    }
    
      
    $filteredWorkspaces = $allWorkspaces | Where-Object {
        $_.Name -notlike "*master*" -and
        $_.Name -notlike "*@tmp*" -and
        $_.Name -notlike "*deploy*"
    }
    
    #Write-Host "After filtering (excluding master/@tmp/deploy): $($filteredWorkspaces.Count)" -ForegroundColor Gray
    
    if ($filteredWorkspaces.Count -eq 0) {
        Write-Host "WARNING: No workspaces found after filtering" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Trying less restrictive search..." -ForegroundColor Yellow
        
        # Fallback: Try to find ANY workspace directory
        $fallbackWorkspaces = Get-ChildItem -Path $rootFolder -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*AppDb_Analytics*" -and $_.Name -notlike "*@tmp*" } |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        
        if ($fallbackWorkspaces) {
            Write-Host "Found workspace via fallback: $($fallbackWorkspaces.Name)" -ForegroundColor Yellow
            $migrationPath = Join-Path $fallbackWorkspaces.FullName "Migration"
            
            if (Test-Path $migrationPath) {
                Write-Host "Migration folder exists: $migrationPath" -ForegroundColor Green
                return @{
                    MigrationPath = $migrationPath
                    DeployPath = Join-Path $fallbackWorkspaces.FullName "deploy"
                    WorkspaceName = $fallbackWorkspaces.Name
                    WorkspacePath = $fallbackWorkspaces.FullName
                }
            } else {
                Write-Host "Migration folder NOT found at: $migrationPath" -ForegroundColor Red
            }
        }
        
        return $null
    }
    
    $workspace = $filteredWorkspaces | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    
    Write-Host "Selected workspace: $($workspace.Name)" -ForegroundColor Green
    
    $migrationPath = Join-Path $workspace.FullName "Migration"
    
    if (-not (Test-Path $migrationPath)) {
        Write-Host "ERROR: Migration folder not found at: $migrationPath" -ForegroundColor Red
        Write-Host "Workspace structure:" -ForegroundColor Gray
        Get-ChildItem -Path $workspace.FullName -Directory | ForEach-Object {
            Write-Host "  - $($_.Name)" -ForegroundColor Gray
        }
        return $null
    }
    
    Write-Host "Migration folder found: $migrationPath" -ForegroundColor Green
    
    return @{
        MigrationPath = $migrationPath
        DeployPath = Join-Path $workspace.FullName "deploy"
        WorkspaceName = $workspace.Name
        WorkspacePath = $workspace.FullName
    }
}
#endregion

#region Main Validation Logic
$paths = Get-WorkspaceMigrationPath

if (-not $paths) {
    Write-Host "ERROR: Could not find workspace migration path" -ForegroundColor Red
    exit 1
}

$migrationPath = $paths.MigrationPath
$deployPath = $paths.DeployPath
$flywayConfigPath = Join-Path $deployPath "flyway.prd.conf"

Write-Host "Workspace: $($paths.WorkspaceName)" -ForegroundColor Gray
Write-Host "Migration Path: $migrationPath" -ForegroundColor Gray
Write-Host "Flyway Config: $flywayConfigPath" -ForegroundColor Gray
Write-Host ""

$currentBranch = Get-CurrentBranchName -migrationPath $migrationPath -connectionString $connectionString -workspaceName $paths.WorkspaceName

if (-not $currentBranch) {
    Write-Host "ERROR: Could not detect current branch" -ForegroundColor Red
    exit 1
}

Write-Host "Current Branch: $currentBranch" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $flywayConfigPath)) {
    Write-Host "ERROR: Flyway config not found: $flywayConfigPath" -ForegroundColor Red
    exit 1
}

Write-Host "=== Pre-Validation Checks ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "1. Scanning for version migration scripts..." -ForegroundColor Yellow
$allVersionScripts = Get-ChildItem -Path $migrationPath -Filter "V*.sql" -ErrorAction SilentlyContinue
$allRepeatableScripts = Get-ChildItem -Path $migrationPath -Filter "R__*.sql" -ErrorAction SilentlyContinue

# Check if there are ANY migration files at all
if ($allVersionScripts.Count -eq 0 -and $allRepeatableScripts.Count -eq 0) {
    Write-Host ""
    Write-Host "=== VALIDATION FAILED ===" -ForegroundColor Red
    Write-Host "ERROR: No migration scripts found" -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected to find migration files (V*.sql or R__*.sql) in:" -ForegroundColor Yellow
    Write-Host "$migrationPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "POSSIBLE CAUSES:" -ForegroundColor Yellow
    Write-Host "1. Migration files were not generated by the CI pipeline" -ForegroundColor Yellow
    Write-Host "2. Files were deleted or moved to wrong location" -ForegroundColor Yellow
    Write-Host "3. Jenkins workspace is corrupted" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Updated pattern for new version format V1.00000
$versionScripts = $allVersionScripts | Where-Object {
    $_.Name -match "^V\d{1,3}\.\d{5}__\d{4}-\d{2}-\d{2}\.$database\.$currentBranch\.sql$"
}

$otherBranchScripts = $allVersionScripts | Where-Object {
    $_.Name -match "^V\d{1,3}\.\d{5}__\d{4}-\d{2}-\d{2}\.$database\.(.+)\.sql$" -and $matches[1] -ne $currentBranch
}

# Check for repeatable scripts matching current branch
$repeatableScripts = $allRepeatableScripts | Where-Object {
    $_.Name -match "^R__\d{4}-\d{2}-\d{2}\.$database\.$currentBranch\.sql$"
}

if ($versionScripts.Count -eq 0 -and $repeatableScripts.Count -eq 0 -and $otherBranchScripts.Count -gt 0) {
    # This is a problem - there are migration scripts but none match the current branch
    Write-Host ""
    Write-Host "=== VALIDATION FAILED ===" -ForegroundColor Red
    Write-Host "ERROR: Migration script mismatch detected" -ForegroundColor Red
    Write-Host ""
    Write-Host "Found $($otherBranchScripts.Count) migration script(s) in workspace but NONE match branch '$currentBranch'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Migration scripts found:" -ForegroundColor Yellow
    foreach ($script in $otherBranchScripts) {
        if ($script.Name -match "\.([^.]+)\.sql$") {
            $scriptBranch = $matches[1]
            Write-Host "  - $($script.Name) [Branch: $scriptBranch]" -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "POSSIBLE CAUSES:" -ForegroundColor Yellow
    Write-Host "1. Migration files were renamed incorrectly" -ForegroundColor Yellow
    Write-Host "2. Wrong workspace is being used" -ForegroundColor Yellow
    Write-Host "3. CI pipeline didn't properly generate migration files for this branch" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "RESOLUTION:" -ForegroundColor Yellow
    Write-Host "Verify the migration files in the Migration folder match the branch name '$currentBranch'" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

if ($versionScripts.Count -eq 0 -and $repeatableScripts.Count -gt 0) {
    # Only repeatable scripts found, no version scripts - this is okay
    Write-Host "Found $($repeatableScripts.Count) repeatable script(s) for branch '$currentBranch' (no version scripts)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Repeatable scripts found:" -ForegroundColor Green
    foreach ($script in $repeatableScripts) {
        Write-Host "  - $($script.Name)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Note: Repeatable scripts will be validated by Flyway" -ForegroundColor Cyan
    Write-Host ""
    # Continue to Flyway validation for repeatable scripts
}
elseif ($versionScripts.Count -gt 0) {
    if ($otherBranchScripts.Count -gt 0) {
        Write-Host "Found $($versionScripts.Count) version script(s) for branch '$currentBranch' ($($otherBranchScripts.Count) from other branches ignored)" -ForegroundColor Yellow
    } else {
        Write-Host "Found $($versionScripts.Count) version script(s) for branch '$currentBranch'" -ForegroundColor Yellow
    }
    
    if ($repeatableScripts.Count -gt 0) {
        Write-Host "Found $($repeatableScripts.Count) repeatable script(s) for branch '$currentBranch'" -ForegroundColor Yellow
    }
}

Write-Host ""

# Only proceed with version script validation if we have version scripts
if ($versionScripts.Count -gt 0) {
    Write-Host "Found $($versionScripts.Count) version script(s) for '$currentBranch':" -ForegroundColor Green
    foreach ($script in $versionScripts) {
        Write-Host "  - $($script.Name)" -ForegroundColor Gray
    }
    Write-Host ""

Write-Host "2. Checking version assignments..." -ForegroundColor Yellow

$scriptVersions = @()
foreach ($script in $versionScripts) {
    # Updated pattern for new version format V1.00000
    if ($script.Name -match "^(V\d{1,3}\.\d{5})__") {
        $version = $matches[1]
        $versionId = $version.Substring(1)
        
        $scriptVersions += [PSCustomObject]@{
            FileName = $script.Name
            Version = $version
            VersionId = $versionId
        }
    }
}

if ($scriptVersions.Count -eq 0) {
    Write-Host "ERROR: Could not extract version numbers" -ForegroundColor Red
    exit 1
}

$hasConflict = $false

foreach ($scriptVer in $scriptVersions) {
    Write-Host "Checking version: $($scriptVer.Version)" -ForegroundColor Cyan
    
    $versionCheckQuery = 'SELECT VersionPR, IsDeployed, BranchName FROM VersionHistory WHERE VersionId = @versionId AND BranchName = @branchName'
    
    $versionCheckParams = @{
        "@versionId" = $scriptVer.VersionId
        "@branchName" = $currentBranch
    }
    
    $versionRecord = Invoke-SqlQueryWithParams -query $versionCheckQuery -connectionString $connectionString -parameters $versionCheckParams
    
    $versionFoundInCurrentBranch = ($versionRecord.Rows.Count -gt 0)
    
    if ($versionFoundInCurrentBranch) {
        $isDeployed = [bool]$versionRecord.Rows[0]["IsDeployed"]
        
        if ($isDeployed) {
            Write-Host "  Already deployed (skipping)" -ForegroundColor Green
            continue
        }
        
        Write-Host "  Version exists, not yet deployed" -ForegroundColor Green
    }
    
    if (-not $versionFoundInCurrentBranch) {
        $anyBranchQuery = 'SELECT BranchName, IsDeployed FROM VersionHistory WHERE VersionId = @versionId'
        $anyBranchParams = @{ "@versionId" = $scriptVer.VersionId }
        
        $versionRecordAny = Invoke-SqlQueryWithParams -query $anyBranchQuery -connectionString $connectionString -parameters $anyBranchParams
        
        if ($versionRecordAny.Rows.Count -gt 0) {
            $otherBranch = $versionRecordAny.Rows[0]["BranchName"].ToString().Trim()
            Write-Host "  ERROR: Version exists for different branch '$otherBranch'!" -ForegroundColor Red
            $hasConflict = $true
        } else {
            Write-Host "  ERROR: Version not found in VersionHistory!" -ForegroundColor Red
            $hasConflict = $true
        }
    }
    
    # Parse version for comparison - updated for new format
    $versionParts = $scriptVer.VersionId.Split('.')
    if ($versionParts.Count -eq 2) {
        $versionMajor = [int]$versionParts[0]
        $versionMinor = [int]$versionParts[1]
        
        # Updated query to handle new version format (major can be 1-3 digits)
        $higherQuery = @"
SELECT COUNT(*) as HigherCount 
FROM VersionHistory 
WHERE (
    (CAST(SUBSTRING(VersionId, 1, CHARINDEX('.', VersionId) - 1) AS INT) > @major) OR 
    (CAST(SUBSTRING(VersionId, 1, CHARINDEX('.', VersionId) - 1) AS INT) = @major AND 
     CAST(SUBSTRING(VersionId, CHARINDEX('.', VersionId) + 1, 5) AS INT) > @minor)
) 
AND IsDeployed = 1
"@
        
        $higherParams = @{
            "@major" = $versionMajor
            "@minor" = $versionMinor
        }
        
        $higherDeployed = Invoke-SqlQueryWithParams -query $higherQuery -connectionString $connectionString -parameters $higherParams
        
        if ($higherDeployed.Rows.Count -gt 0) {
            $higherCount = [int]$higherDeployed.Rows[0]["HigherCount"]
            if ($higherCount -gt 0) {
                Write-Host "  ERROR: $higherCount higher version(s) already deployed!" -ForegroundColor Red
                $hasConflict = $true
            }
        }
    }
    
    Write-Host ""
}

if ($hasConflict) {
    Write-Host "=== VALIDATION FAILED ===" -ForegroundColor Red
    Write-Host "Version conflicts detected." -ForegroundColor Red
    Write-Host ""
    Write-Host "RESOLUTION:" -ForegroundColor Yellow
    Write-Host "git commit --allow-empty -m 'chore: trigger version reassignment'" -ForegroundColor Yellow
    Write-Host "git push" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "Pre-validation checks passed" -ForegroundColor Green
Write-Host ""
} else {
    # No version scripts, only repeatables - skip version checks
    Write-Host "Skipping version assignment checks (no version scripts)" -ForegroundColor Cyan
    Write-Host ""
}
#endregion

#region Flyway Validation
Write-Host "=== Running Flyway Validate ===" -ForegroundColor Cyan
Write-Host ""

try {
    # Update the flyway config to include the migration location
    $configContent = Get-Content $flywayConfigPath -Raw
    
    # Check if locations line exists (commented or not)
    if ($configContent -match '#?flyway\.locations=') {
        # Replace existing line (match any existing location value)
        $configContent = $configContent -replace '#?flyway\.locations=.*', "flyway.locations=filesystem:$migrationPath"
    } else {
        # Add locations line after url
        $configContent = $configContent -replace '(flyway\.url=[^\r\n]+)', "`$1`r`nflyway.locations=filesystem:$migrationPath"
    }
    
    # Write updated config to a temporary file
    $tempConfigPath = Join-Path $deployPath "flyway.validate.temp.conf"
    $configContent | Set-Content -Path $tempConfigPath -Force
    
    Write-Host "Using migration location: $migrationPath" -ForegroundColor Gray
    Write-Host "Temporary config: $tempConfigPath" -ForegroundColor Gray
    Write-Host ""
    
    # Run Flyway validate command with ignoreMigrationPatterns to handle pending migrations
    $Pending = "*:pending"
    $flywayOutput = flyway -configFiles="$tempConfigPath" -user="$SourceUser" -password="$SourcePass" -ignoreMigrationPatterns="$Pending" validate 2>&1
    $flywayExitCode = $LASTEXITCODE
    
    # Clean up temp config
    if (Test-Path $tempConfigPath) {
        Remove-Item $tempConfigPath -Force
    }
    
    # Display Flyway output
    Write-Host "Flyway Output:" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host $flywayOutput -ForegroundColor White
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Flyway Exit Code: $flywayExitCode" -ForegroundColor Gray
    Write-Host ""
    
    if ($flywayExitCode -eq 0) {
        Write-Host "=== VALIDATION PASSED ===" -ForegroundColor Green
        Write-Host "Migration version order is correct" -ForegroundColor Green
        Write-Host "All migrations are in proper sequence" -ForegroundColor Green
        Write-Host "No version conflicts detected" -ForegroundColor Green
        Write-Host "Safe to proceed with PR merge" -ForegroundColor Green
        Write-Host ""
        exit 0
    }
    
    # Validation failed - analyze the error
    Write-Host "=== VALIDATION FAILED ===" -ForegroundColor Red
    Write-Host ""
    
    $outputString = $flywayOutput | Out-String
    
    if ($outputString -match "Detected resolved migration not applied to database") {
        # Extract the version number from the error message - updated for new format
        if ($outputString -match "Detected resolved migration not applied to database: ([\d\.]+)") {
            $pendingVersion = $matches[1]
            
            # Check if there are any deployed versions HIGHER than this pending version
            $versionParts = $pendingVersion.Split('.')
            if ($versionParts.Count -eq 2) {
                $pendingMajor = [int]$versionParts[0]
                $pendingMinor = [int]$versionParts[1]
                
                # Updated query for new version format
                $higherDeployedCheckQuery = @"
SELECT COUNT(*) as HigherCount 
FROM VersionHistory 
WHERE (
    (CAST(SUBSTRING(VersionId, 1, CHARINDEX('.', VersionId) - 1) AS INT) > @major) OR 
    (CAST(SUBSTRING(VersionId, 1, CHARINDEX('.', VersionId) - 1) AS INT) = @major AND 
     CAST(SUBSTRING(VersionId, CHARINDEX('.', VersionId) + 1, 5) AS INT) > @minor)
) 
AND IsDeployed = 1
"@
                
                $higherCheckParams = @{
                    "@major" = $pendingMajor
                    "@minor" = $pendingMinor
                }
                
                $higherDeployedCheck = Invoke-SqlQueryWithParams -query $higherDeployedCheckQuery -connectionString $connectionString -parameters $higherCheckParams
                
                if ($higherDeployedCheck.Rows.Count -gt 0) {
                    $higherCount = [int]$higherDeployedCheck.Rows[0]["HigherCount"]
                    
                    if ($higherCount -gt 0) {
                        # There ARE higher deployed versions - this is a real gap/sequence issue
                        Write-Host "ERROR TYPE: Version Gap Detected" -ForegroundColor Red
                        Write-Host ""
                        Write-Host "EXPLANATION:" -ForegroundColor Yellow
                        Write-Host "Migration version $pendingVersion cannot be deployed because" -ForegroundColor Yellow
                        Write-Host "$higherCount higher version(s) have already been deployed to the database." -ForegroundColor Yellow
                        Write-Host ""
                        Write-Host "RESOLUTION:" -ForegroundColor Yellow
                        Write-Host "1. Push an empty commit to trigger version reassignment:" -ForegroundColor Yellow
                        Write-Host "   git commit --allow-empty -m 'chore: trigger version reassignment'" -ForegroundColor Yellow
                        Write-Host "   git push" -ForegroundColor Yellow
                        Write-Host "2. The CI pipeline will automatically assign a higher version number" -ForegroundColor Yellow
                        Write-Host ""
                        exit 1
                    } else {
                        # No higher deployed versions - this is just a pending migration (EXPECTED)
                        Write-Host "INFO: Flyway detected pending migration (this is expected for PR validation)" -ForegroundColor Green
                        Write-Host ""
                        Write-Host "Migration $pendingVersion exists in the script but is not yet deployed." -ForegroundColor Green
                        Write-Host "This is the normal state before merge and deployment." -ForegroundColor Green
                        Write-Host "No higher versions have been deployed, so this migration is in proper sequence." -ForegroundColor Green
                        Write-Host ""
                        Write-Host "=== VALIDATION PASSED ===" -ForegroundColor Green
                        Write-Host "Migration version order is correct" -ForegroundColor Green
                        Write-Host "Migration is in proper sequence for deployment" -ForegroundColor Green
                        Write-Host "No version conflicts detected" -ForegroundColor Green
                        Write-Host "Safe to proceed with PR merge" -ForegroundColor Green
                        Write-Host ""
                        exit 0
                    }
                }
            }
        }
        
        # If we couldn't parse the version properly
        Write-Host "ERROR TYPE: Version Gap Detected" -ForegroundColor Red
        Write-Host ""
        Write-Host "EXPLANATION:" -ForegroundColor Yellow
        Write-Host "A migration version in your branch has not been applied to the database." -ForegroundColor Yellow
        Write-Host "This could indicate a deployment sequence issue." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "RESOLUTION:" -ForegroundColor Yellow
        Write-Host "1. Push an empty commit to trigger version reassignment:" -ForegroundColor Yellow
        Write-Host "   git commit --allow-empty -m 'chore: trigger version reassignment'" -ForegroundColor Yellow
        Write-Host "2. The CI pipeline will automatically assign a higher version number" -ForegroundColor Yellow
    }
    elseif ($outputString -match "Validate failed: Migrations have failed validation") {
        Write-Host "ERROR TYPE: Migration Validation Failed" -ForegroundColor Red
        Write-Host ""
        Write-Host "EXPLANATION:" -ForegroundColor Yellow
        Write-Host "One or more migration scripts have validation issues." -ForegroundColor Yellow
        Write-Host "This could be due to checksum mismatches or other integrity problems." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "RESOLUTION:" -ForegroundColor Yellow
        Write-Host "Review the Flyway output above for specific error details." -ForegroundColor Yellow
    }
    elseif ($outputString -match "checksum mismatch") {
        Write-Host "ERROR TYPE: Checksum Mismatch" -ForegroundColor Red
        Write-Host ""
        Write-Host "EXPLANATION:" -ForegroundColor Yellow
        Write-Host "A migration script's content has changed after it was deployed." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "RESOLUTION:" -ForegroundColor Yellow
        Write-Host "Never modify migration scripts after they have been deployed." -ForegroundColor Yellow
        Write-Host "Create a new migration script with the corrected changes." -ForegroundColor Yellow
    }
    else {
        Write-Host "ERROR TYPE: Unknown Validation Error" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please review the Flyway output above for details." -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "Cannot proceed with PR merge until validation passes." -ForegroundColor Red
    Write-Host ""
    exit 1
}
catch {
    Write-Host "=== FLYWAY VALIDATION ERROR ===" -ForegroundColor Red
    Write-Host "An unexpected error occurred while running Flyway validate:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    exit 1
}
#endregion
