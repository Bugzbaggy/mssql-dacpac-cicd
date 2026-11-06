<#
.Synopsis
   Execute migration scripts in Staging database for specific PR branch.
.DESCRIPTION
   STRICTLY executes the SINGLE Repeatable and/or SINGLE Versioned migration script
   that was processed and validated by the CI pipeline (CICD_AppDb_Analytics_Generic_Migration_Script.ps1).
   
   Each PR has exactly ONE unique Repeatable script and ONE unique Versioned script.
   This script queries the VersionHistory table to find the exact script that was assigned
   to this branch, then executes ONLY that specific script.
   
   IMPORTANT: This script uses TWO database connections:
   1. PRODUCTION server - to READ VersionHistory table (source of truth)
   2. STAGING server - to EXECUTE migration scripts
   
   EXECUTION ORDER: Versioned migrations are ALWAYS executed before Repeatable migrations.
   
   Compatible with PowerShell 5.1+
   
   Author: Renz Bagasbas
   Created: November 2025
   Modified: January 2026 - Added strict execution ordering
   Purpose: Separate deployment pipeline for staging database migrations
.PARAMETER username
   Database username from Jenkins credentials
.PARAMETER password
   Database password from Jenkins credentials
.PARAMETER branch
   Branch name to deploy migrations for
.PARAMETER artifactsPath
   Path to the directory containing migration artifacts (SQL files)
.EXAMPLE
   .\Execute_Staging_Migrations.ps1 -username "dbuser" -password "dbpass" -branch "feature-123" -artifactsPath "C:\Jenkins\workspace\artifacts"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$username,
    
    [Parameter(Mandatory=$true)]
    [string]$password,
    
    [Parameter(Mandatory=$true)]
    [string]$branch,
    
    [Parameter(Mandatory=$false)]
    [string]$artifactsPath = $null
)

#region Configuration
$rootFolder = "C:\Jenkins\workspace\"
$serverSTG = 'listener.example.com'
$serverPRD = 'listener.region1.example.com'
$database = 'AppDb_Analytics'
$isWindowsAuthentication = $false
#endregion

#region Helper Functions
function Execute-SqlScriptWithGo {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$SqlContent,
        [int]$CommandTimeout = 300
    )
    
    $goPattern = '(?im)^\s*GO\s*$'
    $batches = $SqlContent -split $goPattern
    
    $totalRowsAffected = 0
    $batchNumber = 0
    $successfulBatches = 0
    
    foreach ($batch in $batches) {
        $trimmedBatch = $batch.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedBatch)) {
            continue
        }
        
        $batchNumber++
        
        try {
            $command = $Connection.CreateCommand()
            $command.CommandText = $trimmedBatch
            $command.CommandTimeout = $CommandTimeout
            
            Write-Host "   Executing batch $batchNumber..." -ForegroundColor Gray
            $rowsAffected = $command.ExecuteNonQuery()
            $totalRowsAffected += $rowsAffected
            $successfulBatches++
            
            if ($rowsAffected -ge 0) {
                Write-Host "   Batch $batchNumber completed: $rowsAffected rows affected" -ForegroundColor Gray
            } else {
                Write-Host "   Batch $batchNumber completed successfully" -ForegroundColor Gray
            }
            
        } catch {
            $errorMessage = $_.Exception.Message
            Write-Host "   Error in batch ${batchNumber}: $errorMessage" -ForegroundColor Red
            
            $snippetLength = [Math]::Min(200, $trimmedBatch.Length)
            $snippet = $trimmedBatch.Substring(0, $snippetLength)
            Write-Host "   Batch content (first 200 chars): $snippet..." -ForegroundColor Yellow
            
            throw
        }
    }
    
    if ($batchNumber -gt 1) {
        Write-Host "   Total: $successfulBatches/$batchNumber batches executed successfully" -ForegroundColor Cyan
    }
    
    return $totalRowsAffected
}
#endregion

$authType = if ($isWindowsAuthentication -eq $True) { "Windows" } else { "SQL" }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "STAGING DATABASE MIGRATION DEPLOYMENT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VersionHistory Server: $serverPRD (PRODUCTION)" -ForegroundColor White
Write-Host "Deployment Server: $serverSTG (STAGING)" -ForegroundColor White
Write-Host "Database: $database" -ForegroundColor White
Write-Host "Branch: $branch" -ForegroundColor Yellow
Write-Host "Authentication: $authType" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Create connection strings for BOTH servers
if ($isWindowsAuthentication -eq $True) {
    $connectionStringPRD = "Server=$serverPRD;Database=$database;Integrated Security=True;"
    $connectionStringSTG = "Server=$serverSTG;Database=$database;Integrated Security=True;"
} else {
    $connectionStringPRD = "Server=$serverPRD;Database=$database;User ID=$username;Password=$password;"
    $connectionStringSTG = "Server=$serverSTG;Database=$database;User ID=$username;Password=$password;"
}

# Test PRODUCTION database connection (for reading VersionHistory)
Write-Host "=== Step 1A: Testing PRODUCTION Database Connection ===" -ForegroundColor Cyan
Write-Host "Server: $serverPRD (for reading VersionHistory table)" -ForegroundColor Gray
$connectionPRD = New-Object System.Data.SqlClient.SqlConnection($connectionStringPRD)
try {
    $connectionPRD.Open()
    Write-Host "Success: PRODUCTION connection successful" -ForegroundColor Green
} catch {
    Write-Host "Error: PRODUCTION connection failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Cannot proceed - need access to VersionHistory table on PRODUCTION." -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test STAGING database connection (for executing scripts)
Write-Host "=== Step 1B: Testing STAGING Database Connection ===" -ForegroundColor Cyan
Write-Host "Server: $serverSTG (for executing migration scripts)" -ForegroundColor Gray
$connectionSTG = New-Object System.Data.SqlClient.SqlConnection($connectionStringSTG)
try {
    $connectionSTG.Open()
    Write-Host "Success: STAGING connection successful" -ForegroundColor Green
} catch {
    Write-Host "Error: STAGING connection failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Cannot proceed with deployment." -ForegroundColor Red
    $connectionPRD.Close()
    exit 1
}
Write-Host ""

# Determine migration path
Write-Host "=== Step 2: Locating Migration Files ===" -ForegroundColor Cyan

if ($artifactsPath) {
    # Use provided artifacts path (new approach)
    $migrationPath = $artifactsPath
    Write-Host "Using provided artifacts path: $migrationPath" -ForegroundColor Cyan
} else {
    # Fallback to old approach - find workspace folder
    Write-Host "No artifacts path provided, searching for workspace folder..." -ForegroundColor Yellow
    
    $workspacePattern = "*AppDb_Analytics_STG_DPLY_$branch*"
    $workspaceFolders = Get-ChildItem -Path $rootFolder -Directory | Where-Object {
        $_.Name -like $workspacePattern -and
        $_.Name -notlike "*@tmp" -and
        $_.Name -notlike "*@script"
    }

    if ($workspaceFolders.Count -eq 0) {
        Write-Host "Error: Could not find workspace folder for branch '$branch'" -ForegroundColor Red
        Write-Host "Expected pattern: AppDb_Analytics_STG_DPLY_$branch" -ForegroundColor Yellow
        $connectionPRD.Close()
        $connectionSTG.Close()
        exit 1
    }

    $workspaceFolder = $workspaceFolders | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    $migrationPath = Join-Path $workspaceFolder.FullName "Migration"
    
    Write-Host "Success: Workspace found: $($workspaceFolder.FullName)" -ForegroundColor Green
}

Write-Host "Migration path: $migrationPath" -ForegroundColor Gray
Write-Host ""

# Validate migration folder exists
Write-Host "=== Step 3: Validating Migration Path ===" -ForegroundColor Cyan
if (-not (Test-Path $migrationPath)) {
    Write-Host "Error: Migration path not found: $migrationPath" -ForegroundColor Red
    $connectionPRD.Close()
    $connectionSTG.Close()
    exit 1
}
Write-Host "Success: Migration path exists" -ForegroundColor Green
Write-Host ""

# Query VersionHistory from PRODUCTION server
Write-Host "=== Step 4: Querying VersionHistory for Branch '$branch' ===" -ForegroundColor Cyan
Write-Host "Reading from PRODUCTION server: $serverPRD" -ForegroundColor Gray
Write-Host "Checking which version script was processed by CI pipeline..." -ForegroundColor Gray

# Debug: First check if record exists at all
Write-Host "Debug: Testing if branch exists in VersionHistory..." -ForegroundColor Gray
$debugQuery = "SELECT COUNT(*) FROM [AppDb_Analytics].[dbo].[VersionHistory] WHERE BranchName = @branch"
$debugCmd = $connectionPRD.CreateCommand()
$debugCmd.CommandText = $debugQuery
$debugCmd.Parameters.AddWithValue("@branch", $branch) | Out-Null
$recordCount = $debugCmd.ExecuteScalar()
Write-Host "Debug: Found $recordCount record(s) for branch '$branch'" -ForegroundColor Gray

# Query to get versioned script from VersionHistory
$versionHistoryQuery = @"
SELECT TOP 1
    VersionId,
    VersionPR,
    Script,
    BranchDate,
    IsDeployed
FROM [AppDb_Analytics].[dbo].[VersionHistory]
WHERE BranchName = @branch
  AND Script IS NOT NULL
ORDER BY VersionId DESC
"@

$versionedScriptFromDB = $null

try {
    $versionCmd = $connectionPRD.CreateCommand()
    $versionCmd.CommandText = $versionHistoryQuery
    $versionCmd.Parameters.AddWithValue("@branch", $branch) | Out-Null
    
    Write-Host "Debug: Executing query for branch '$branch'..." -ForegroundColor Gray
    $versionReader = $versionCmd.ExecuteReader()
    
    if ($versionReader.Read()) {
        $versionedScriptFromDB = [PSCustomObject]@{
            VersionId = [decimal]$versionReader["VersionId"]
            VersionPR = $versionReader["VersionPR"].ToString()
            ScriptFileName = $versionReader["Script"].ToString()
            BranchDate = $versionReader["BranchDate"]
            IsDeployed = [bool]$versionReader["IsDeployed"]
        }
        Write-Host "Debug: Successfully read record from PRODUCTION database" -ForegroundColor Green
    } else {
        Write-Host "Debug: Reader returned no rows from PRODUCTION" -ForegroundColor Yellow
    }
    $versionReader.Close()
    
    if ($versionedScriptFromDB) {
        $deployedIcon = if ($versionedScriptFromDB.IsDeployed) { "[DEPLOYED]" } else { "[PENDING]" }
        $deployedColor = if ($versionedScriptFromDB.IsDeployed) { "Yellow" } else { "Cyan" }
        $deployedText = if ($versionedScriptFromDB.IsDeployed) { "Already Deployed" } else { "Pending Deployment" }
        
        Write-Host "Success: Found versioned script in VersionHistory:" -ForegroundColor Green
        Write-Host "  $deployedIcon Version: $($versionedScriptFromDB.VersionPR)" -ForegroundColor $deployedColor
        Write-Host "  VersionId: $($versionedScriptFromDB.VersionId)" -ForegroundColor Gray
        Write-Host "  Registered Script: $($versionedScriptFromDB.ScriptFileName)" -ForegroundColor White
        Write-Host "  Date: $($versionedScriptFromDB.BranchDate)" -ForegroundColor Gray
        Write-Host "  Status: $deployedText" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Note: Will match files by version number ($($versionedScriptFromDB.VersionPR))" -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Host "Warning: No versioned script found in VersionHistory for branch '$branch'" -ForegroundColor Yellow
        Write-Host "   This means CI pipeline hasn't processed a version script for this branch." -ForegroundColor Gray
        Write-Host ""
        
        # Additional debug: Show what records exist
        Write-Host "Debug: Checking all records in VersionHistory..." -ForegroundColor Gray
        $debugAllQuery = "SELECT TOP 5 VersionPR, BranchName, Script FROM [AppDb_Analytics].[dbo].[VersionHistory] WHERE Script IS NOT NULL ORDER BY VersionId DESC"
        $debugAllCmd = $connectionPRD.CreateCommand()
        $debugAllCmd.CommandText = $debugAllQuery
        $debugAllReader = $debugAllCmd.ExecuteReader()
        
        $foundRecords = 0
        while ($debugAllReader.Read()) {
            $foundRecords++
            $dbBranch = $debugAllReader["BranchName"].ToString()
            $dbVersion = $debugAllReader["VersionPR"].ToString()
            $dbScript = $debugAllReader["Script"].ToString()
            Write-Host "  Found: Branch='$dbBranch', Version='$dbVersion', Script='$dbScript'" -ForegroundColor Gray
            
            if ($dbBranch -eq $branch) {
                Write-Host "    ^ THIS MATCHES YOUR BRANCH but wasn't returned by main query!" -ForegroundColor Red
            }
        }
        $debugAllReader.Close()
        
        if ($foundRecords -eq 0) {
            Write-Host "Debug: No records with Script column found in entire table" -ForegroundColor Yellow
        }
        Write-Host ""
    }
    
} catch {
    Write-Host "Error: Error querying VersionHistory: $($_.Exception.Message)" -ForegroundColor Red
    $connectionPRD.Close()
    $connectionSTG.Close()
    exit 1
}

# Scan for migration files in the Migration folder
Write-Host "=== Step 5: Scanning Migration Path for Branch Scripts ===" -ForegroundColor Cyan

# Escape DB/branch before interpolating into the match regex - the branch slug may
# contain '.' (from the '/' -> '.' normalization) which would otherwise act as a
# regex wildcard and match unintended files.
$databaseEsc = [regex]::Escape($database)
$branchEsc = [regex]::Escape($branch)
$repeatablePattern = "^R__(\d{4}-\d{2}-\d{2})\.$databaseEsc\.$branchEsc\.sql$"
$versionPattern = "^(V\d{1,3}\.\d{5})__(\d{4}-\d{2}-\d{2})\.$databaseEsc\.$branchEsc\.sql$"

$repeatableScript = $null
$versionedScriptFile = $null

$allFiles = Get-ChildItem -Path $migrationPath -Filter "*.sql" -ErrorAction SilentlyContinue

if ($allFiles.Count -eq 0) {
    Write-Host "Warning: No SQL files found in migration path" -ForegroundColor Yellow
    Write-Host "   Path: $migrationPath" -ForegroundColor Gray
} else {
    Write-Host "Found $($allFiles.Count) SQL file(s) in migration path" -ForegroundColor Cyan
    
    foreach ($file in $allFiles) {
        if ($file.Name -match $repeatablePattern) {
            $repeatableScript = [PSCustomObject]@{
                FileName = $file.Name
                FullPath = $file.FullName
                FileDate = $matches[1]
                Type = "Repeatable"
            }
            Write-Host "  Found Repeatable: $($file.Name)" -ForegroundColor Cyan
        }
        elseif ($file.Name -match $versionPattern) {
            $versionNumber = $matches[1]
            $versionedScriptFile = [PSCustomObject]@{
                FileName = $file.Name
                FullPath = $file.FullName
                Version = $versionNumber
                FileDate = $matches[2]
                Type = "Versioned"
            }
            Write-Host "  Found Versioned: $($file.Name)" -ForegroundColor Green
        }
    }
}

Write-Host ""

# Validate and prepare execution plan
Write-Host "=== Step 6: Validating Scripts for Execution ===" -ForegroundColor Cyan

$validationErrors = @()
$versionedScriptToExecute = $null
$repeatableScriptToExecute = $null

# Validate Repeatable script
if ($repeatableScript) {
    Write-Host "Success: Repeatable script ready for execution" -ForegroundColor Green
    Write-Host "   File: $($repeatableScript.FileName)" -ForegroundColor Gray
    $repeatableScriptToExecute = $repeatableScript
} else {
    Write-Host "Info: No Repeatable script found for branch '$branch'" -ForegroundColor Cyan
    Write-Host "   This is acceptable if PR doesn't have repeatable migrations" -ForegroundColor Gray
}

Write-Host ""

# Validate Versioned script - FLEXIBLE matching by version number
if ($versionedScriptFromDB) {
    if ($versionedScriptFile) {
        # Extract version from database script name
        $dbScriptVersion = $null
        if ($versionedScriptFromDB.ScriptFileName -match "^(V\d{1,3}\.\d{5})__") {
            $dbScriptVersion = $matches[1]
        }
        
        # Compare versions, not full filenames (dates may differ)
        if ($versionedScriptFile.Version -eq $dbScriptVersion) {
            Write-Host "Success: Versioned script VALIDATED against VersionHistory" -ForegroundColor Green
            Write-Host "   File: $($versionedScriptFile.FileName)" -ForegroundColor Gray
            Write-Host "   Version: $($versionedScriptFromDB.VersionPR)" -ForegroundColor Gray
            Write-Host "   Database script: $($versionedScriptFromDB.ScriptFileName)" -ForegroundColor Gray
            
            if ($versionedScriptFile.FileName -ne $versionedScriptFromDB.ScriptFileName) {
                Write-Host "   Note: Filenames differ (likely date mismatch) but VERSION matches - OK" -ForegroundColor Cyan
            } else {
                Write-Host "   Exact filename match with VersionHistory" -ForegroundColor Green
            }
            
            # Check if already deployed
            if ($versionedScriptFromDB.IsDeployed) {
                Write-Host "   WARNING: This version is already marked as DEPLOYED in VersionHistory!" -ForegroundColor Yellow
                Write-Host "   Skipping to prevent duplicate deployment" -ForegroundColor Yellow
            } else {
                $versionedScriptToExecute = $versionedScriptFile
            }
        } else {
            $validationErrors += "Versioned script version mismatch!"
            Write-Host "Error: VALIDATION ERROR: Version number mismatch!" -ForegroundColor Red
            Write-Host "   Expected version (from VersionHistory): $dbScriptVersion" -ForegroundColor Yellow
            Write-Host "   Found version in file: $($versionedScriptFile.Version)" -ForegroundColor Yellow
            Write-Host "   Database script: $($versionedScriptFromDB.ScriptFileName)" -ForegroundColor Yellow
            Write-Host "   Artifact file: $($versionedScriptFile.FileName)" -ForegroundColor Yellow
            Write-Host "   Version numbers must match!" -ForegroundColor Red
        }
    } else {
        $validationErrors += "Versioned script file not found in Migration folder"
        Write-Host "Error: VALIDATION ERROR: Versioned script missing!" -ForegroundColor Red
        Write-Host "   Expected version: $($versionedScriptFromDB.VersionPR)" -ForegroundColor Yellow
        Write-Host "   Registered script: $($versionedScriptFromDB.ScriptFileName)" -ForegroundColor Yellow
        Write-Host "   No matching version file found in artifacts!" -ForegroundColor Red
    }
} else {
    Write-Host "Info: No Versioned script in VersionHistory for branch '$branch'" -ForegroundColor Cyan
    Write-Host "   This is acceptable if PR doesn't have versioned migrations" -ForegroundColor Gray
    
    if ($versionedScriptFile) {
        Write-Host "Warning: Found versioned script in folder but NOT in VersionHistory" -ForegroundColor Yellow
        Write-Host "   File: $($versionedScriptFile.FileName)" -ForegroundColor Gray
        Write-Host "   This script was NOT processed by CI pipeline and will be SKIPPED" -ForegroundColor Yellow
    }
}

Write-Host ""

# Build execution array in STRICT ORDER: Versioned first, then Repeatable
Write-Host "=== Step 6B: Building Execution Queue (Versioned → Repeatable) ===" -ForegroundColor Cyan
$scriptsToExecute = @()

# Add Versioned script FIRST (if validated)
if ($versionedScriptToExecute) {
    $versionedScriptToExecute | Add-Member -MemberType NoteProperty -Name ExecutionPriority -Value 1 -Force
    $scriptsToExecute += $versionedScriptToExecute
    Write-Host "Queued [Priority 1]: Versioned migration - $($versionedScriptToExecute.FileName)" -ForegroundColor Green
}

# Add Repeatable script SECOND (if available)
if ($repeatableScriptToExecute) {
    $repeatableScriptToExecute | Add-Member -MemberType NoteProperty -Name ExecutionPriority -Value 2 -Force
    $scriptsToExecute += $repeatableScriptToExecute
    Write-Host "Queued [Priority 2]: Repeatable migration - $($repeatableScriptToExecute.FileName)" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Execution order enforced: Versioned migrations will always run before Repeatable migrations" -ForegroundColor Yellow
Write-Host ""

# Check for validation errors
if ($validationErrors.Count -gt 0) {
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "VALIDATION FAILED" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Errors:" -ForegroundColor Red
    foreach ($validationError in $validationErrors) {
        Write-Host "  Error: $validationError" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Cannot proceed with deployment. Please fix the issues above." -ForegroundColor Red
    $connectionPRD.Close()
    $connectionSTG.Close()
    exit 1
}

# Check if there are any scripts to execute
if ($scriptsToExecute.Count -eq 0) {
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "NO SCRIPTS TO EXECUTE" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No migration scripts found for branch '$branch'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This is expected if:" -ForegroundColor Cyan
    Write-Host "  - PR doesn't contain any database changes" -ForegroundColor Gray
    Write-Host "  - CI pipeline hasn't processed this branch yet" -ForegroundColor Gray
    Write-Host "  - Scripts are already deployed" -ForegroundColor Gray
    Write-Host ""
    $connectionPRD.Close()
    $connectionSTG.Close()
    exit 0
}

# Display execution plan
Write-Host "========================================" -ForegroundColor Green
Write-Host "EXECUTION PLAN" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Branch: $branch" -ForegroundColor White
Write-Host "Deployment Target: $serverSTG (STAGING)" -ForegroundColor White
Write-Host "Scripts to execute: $($scriptsToExecute.Count)" -ForegroundColor White
Write-Host "Execution sequence: VERSIONED → REPEATABLE" -ForegroundColor Yellow
Write-Host ""

$executionOrder = 1
foreach ($script in $scriptsToExecute) {
    $priority = if ($script.ExecutionPriority) { " [Priority: $($script.ExecutionPriority)]" } else { "" }
    Write-Host "$executionOrder. [$($script.Type)]$priority $($script.FileName)" -ForegroundColor Cyan
    $executionOrder++
}

Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Execute migration scripts on STAGING server
Write-Host "=== Step 7: Executing Migration Scripts on STAGING ===" -ForegroundColor Cyan
Write-Host "Target Server: $serverSTG" -ForegroundColor Yellow
Write-Host ""
Write-Host "NOTE: Scripts are executed on STAGING server only." -ForegroundColor Yellow
Write-Host "      VersionHistory table (on PRODUCTION) is NOT modified by this deployment script." -ForegroundColor Yellow
Write-Host ""

$deployedCount = 0
$failedCount = 0
$skippedCount = 0
$executionLog = @()

try {
    foreach ($script in $scriptsToExecute) {
        Write-Host "========================================" -ForegroundColor Magenta
        Write-Host "Executing: $($script.FileName)" -ForegroundColor Yellow
        Write-Host "Type: $($script.Type)" -ForegroundColor Gray
        Write-Host "Priority: $($script.ExecutionPriority)" -ForegroundColor Gray
        if ($script.Version) {
            Write-Host "Version: $($script.Version)" -ForegroundColor Gray
        }
        Write-Host "Target: $serverSTG" -ForegroundColor Gray
        Write-Host "========================================" -ForegroundColor Magenta
        
        $startTime = Get-Date
        
        try {
            $sqlContent = Get-Content -Path $script.FullPath -Raw -ErrorAction Stop
            
            if ([string]::IsNullOrWhiteSpace($sqlContent)) {
                Write-Host "Warning: Script is empty - skipping" -ForegroundColor Yellow
                $skippedCount++
                
                $logEntry = [PSCustomObject]@{
                    ScriptName = $script.FileName
                    Type = $script.Type
                    Priority = $script.ExecutionPriority
                    Status = "Skipped"
                    Reason = "Empty script"
                    ExecutionTime = $null
                }
                if ($script.Version) {
                    $logEntry | Add-Member -MemberType NoteProperty -Name Version -Value $script.Version
                } else {
                    $logEntry | Add-Member -MemberType NoteProperty -Name Version -Value "N/A"
                }
                $executionLog += $logEntry
                
                Write-Host ""
                continue
            }
            
            Write-Host "Executing SQL script on STAGING..." -ForegroundColor Cyan
            # CRITICAL: Use STAGING connection for execution
            $rowsAffected = Execute-SqlScriptWithGo -Connection $connectionSTG -SqlContent $sqlContent -CommandTimeout 300
            $executionTime = ((Get-Date) - $startTime).TotalSeconds
            
            Write-Host "Success: DEPLOYED SUCCESSFULLY to STAGING" -ForegroundColor Green
            Write-Host "   Total rows affected: $rowsAffected" -ForegroundColor White
            Write-Host "   Execution time: $([math]::Round($executionTime, 2)) seconds" -ForegroundColor White
            $deployedCount++
            
            $logEntry = [PSCustomObject]@{
                ScriptName = $script.FileName
                Type = $script.Type
                Priority = $script.ExecutionPriority
                Status = "Success"
                RowsAffected = $rowsAffected
                ExecutionTime = "$([math]::Round($executionTime, 2))s"
            }
            if ($script.Version) {
                $logEntry | Add-Member -MemberType NoteProperty -Name Version -Value $script.Version
            } else {
                $logEntry | Add-Member -MemberType NoteProperty -Name Version -Value "N/A"
            }
            $executionLog += $logEntry
            
        } catch {
            $executionTime = ((Get-Date) - $startTime).TotalSeconds
            Write-Host "Error: DEPLOYMENT FAILED" -ForegroundColor Red
            Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "   Execution time: $([math]::Round($executionTime, 2)) seconds" -ForegroundColor Gray
            $failedCount++
            
            $logEntry = [PSCustomObject]@{
                ScriptName = $script.FileName
                Type = $script.Type
                Priority = $script.ExecutionPriority
                Status = "Failed"
                ErrorMessage = $_.Exception.Message
                ExecutionTime = "$([math]::Round($executionTime, 2))s"
            }
            if ($script.Version) {
                $logEntry | Add-Member -MemberType NoteProperty -Name Version -Value $script.Version
            } else {
                $logEntry | Add-Member -MemberType NoteProperty -Name Version -Value "N/A"
            }
            $executionLog += $logEntry
            
            if ($script.Type -eq "Versioned") {
                Write-Host ""
                Write-Host "CRITICAL: Versioned script failed!" -ForegroundColor Red
                Write-Host "   This may cause issues with database schema consistency." -ForegroundColor Yellow
                Write-Host "   Please review and fix immediately." -ForegroundColor Yellow
            }
        }
        
        Write-Host ""
    }
    
} catch {
    Write-Host "Error: Unexpected error during deployment: $($_.Exception.Message)" -ForegroundColor Red
    $connectionPRD.Close()
    $connectionSTG.Close()
    exit 1
} finally {
    $connectionPRD.Close()
    $connectionSTG.Close()
}

# Detailed Execution Log
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DETAILED EXECUTION LOG" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$executionLog | Format-Table -AutoSize
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Branch: $branch" -ForegroundColor White
Write-Host "VersionHistory Server: $serverPRD (PRODUCTION)" -ForegroundColor White
Write-Host "Deployment Server: $serverSTG (STAGING)" -ForegroundColor White
Write-Host "Database: $database" -ForegroundColor White
Write-Host "Execution Order: VERSIONED → REPEATABLE" -ForegroundColor Yellow
Write-Host "Total Scripts: $($scriptsToExecute.Count)" -ForegroundColor White
Write-Host "Success: Deployed: $deployedCount" -ForegroundColor Green
Write-Host "Warning: Skipped: $skippedCount" -ForegroundColor Yellow
Write-Host "Error: Failed: $failedCount" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "NOTE: Only scripts processed by CI pipeline (CICD_AppDb_Analytics_Generic_Migration_Script.ps1) were executed." -ForegroundColor Yellow
Write-Host "      VersionHistory table is managed on PRODUCTION server." -ForegroundColor Yellow
Write-Host "      Migration scripts were executed on STAGING server only." -ForegroundColor Yellow
Write-Host ""

if ($failedCount -gt 0) {
    Write-Host "Warning: Deployment completed with $failedCount failure(s)" -ForegroundColor Yellow
    Write-Host "Please review the errors above and take corrective action" -ForegroundColor Yellow
    exit 1
}

if ($deployedCount -eq 0 -and $skippedCount -gt 0) {
    Write-Host "Warning: All scripts were skipped (empty files)" -ForegroundColor Yellow
    exit 0
}

Write-Host "Success: All migration scripts deployed successfully to STAGING!" -ForegroundColor Green
exit 0