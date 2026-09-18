<#
.Synopsis
   Continuous Integration (CI) using PowerShell for SQL Server.
.DESCRIPTION
   Automates SQL Server database integration by extracting branch information from folder names,
   validating migration script dates, and managing version history to ensure proper deployment sequencing.
   Renz Bagasbas
   February 08, 2024
   Enhanced: March 2025 - Branch extraction from folder name with strict file validation pipeline
   Fixed: October 2025 - Prevent duplicate version assignment by checking branch first, not filename version
   Updated: November 2025 - Changed version format from V000.00000 to V1.00000
   Enhanced: November 2025 - Strict sequential versioning with aggressive overwrite of undeployed conflicts
#>
  
#region Variables
$SourceUser = $Env:USER
$SourcePass = $Env:PASS
# Alternate way to load environment variables for local testing
#$SourceUser = [System.Environment]::GetEnvironmentVariable("STG_DB_USER", [System.EnvironmentVariableTarget]::User)
#$SourcePass = [System.Environment]::GetEnvironmentVariable("STG_DB_PASS", [System.EnvironmentVariableTarget]::User)   

#region Configuration
$rootFolder = "C:\Jenkins\workspace\"
$serverSTG = 'listener.example.com'
$serverPRD = 'listener.region1.example.com'
$database = 'AppDb_Analytics'
$testdb = 'AppDb_Analytics_STG'
$isWindowsAuthentication = $False
#endregion

Write-Host "Server: $serverPRD; Database: $database; isWindowsAuthentication: $isWindowsAuthentication"

$userName = $SourceUser
$password = $SourcePass

# Create connection strings
if ($isWindowsAuthentication -eq $True) {
    $connectionString = "Server=$serverPRD;Database=$database;Integrated Security=True;"
    $TargetConnectionString = "Data Source=$serverPRD;Initial Catalog=$database;Integrated Security=True;"
} else {
    $connectionString = "Server=$serverPRD;Database=$database;User ID=$userName;Password=$password;"
    $TargetConnectionString = "Data Source=$serverPRD;Initial Catalog=$database;Integrated Security=False;User ID=$userName;Password=$password;"
}

# Test database connection
Write-Host "Testing the database connection..."
$connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
try {
    $connection.Open()
    Write-Host "Connection successful" -ForegroundColor Green
} catch {
    Write-Host "Connection failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    $connection.Close()
}

# Helper function to parse version numbers
function Parse-VersionNumber {
    param([string]$version)
    
    # Pattern: V1.00000 (major 1-999, minor 00000-99999)
    if ($version -match "^V(\d{1,3})\.(\d{5})$") {
        return @{
            Major = [int]$matches[1]
            Minor = [int]$matches[2]
            IsValid = $true
        }
    }
    return @{ IsValid = $false }
}

# Helper function to format version number
function Format-VersionNumber {
    param([int]$major, [int]$minor)
    # Format: V{major}.{minor:D5} where major is 1-999 (no padding)
    return "V{0}.{1:D5}" -f $major, $minor
}

# Extract branch name directly from folder name
function Get-BranchFromFolderName {
    param([string]$folderPath)
    
    $folderName = Split-Path -Path $folderPath -Leaf
    
    # Expected pattern: AppDb_Analytics_STG_MGR__branchname
    if ($folderName -match "^AppDb_Analytics_STG_MGR_(.+)$") {
        $branchName = $matches[1]
        
        # Security validation
        if ([string]::IsNullOrWhiteSpace($branchName) -or 
            $branchName.Contains("..") -or 
            $branchName.Contains("\") -or 
            $branchName.Contains("/")) {
            Write-Host "Invalid branch name extracted from folder: '$branchName'" -ForegroundColor Red
            return $null
        }
        
        Write-Host "Extracted branch name from folder: '$branchName'" -ForegroundColor Green
        return $branchName
    }
    
    Write-Host "Folder name does not match expected pattern: AppDb_Analytics_STG_MGR_branchname" -ForegroundColor Red
    Write-Host "Actual folder name: $folderName" -ForegroundColor Yellow
    return $null
}

# Validate and collect migration files for the specific branch
function Get-ValidatedMigrationFiles {
    param(
        [string]$migrationPath,
        [string]$branch,
        [string]$database,
        [string]$today
    )
    
    $result = @{
        Success = $false
        RepeatableFiles = @()
        VersionFiles = @()
        Error = $null
    }
    
    if (-not (Test-Path $migrationPath)) {
        $result.Error = "Migration path does not exist: $migrationPath"
        return $result
    }
    
    Write-Host "Scanning for migration files matching branch '$branch'..." -ForegroundColor Cyan
    
    # Get all SQL files
    $allSqlFiles = Get-ChildItem -Path $migrationPath -Filter "*.sql" -ErrorAction SilentlyContinue
    Write-Host "Found $($allSqlFiles.Count) SQL files in migration folder" -ForegroundColor Cyan
    
    # Pattern for Repeatable scripts: R__YYYY-MM-DD.DATABASE.BRANCH.sql
    $repeatablePattern = "^R__(\d{4}-\d{2}-\d{2})\.([^\.]+)\.(.+)\.sql$"
    
    # Pattern for Version scripts: V1.00000__YYYY-MM-DD.DATABASE.BRANCH.sql
    $versionPattern = "^(V\d{1,3}\.\d{5})__(\d{4}-\d{2}-\d{2})\.([^\.]+)\.(.+)\.sql$"
    
    foreach ($file in $allSqlFiles) {
        # Check repeatable script
        if ($file.Name -match $repeatablePattern) {
            $fileDate = $matches[1]
            $fileDatabase = $matches[2]
            $branchFromFile = $matches[3]
            
            # STRICT: Only include if BOTH database AND branch match
            if ($fileDatabase -eq $database -and $branchFromFile -eq $branch) {
                $result.RepeatableFiles += [PSCustomObject]@{
                    FileName = $file.Name
                    FullPath = $file.FullName
                    FileDate = $fileDate
                    RequiresDateUpdate = ($fileDate -ne $today)
                    FileObject = $file
                }
                Write-Host "  Found repeatable: $($file.Name)" -ForegroundColor Green
            }
        }
        # Check version script
        elseif ($file.Name -match $versionPattern) {
            $versionNumber = $matches[1]
            $fileDate = $matches[2]
            $fileDatabase = $matches[3]
            $branchFromFile = $matches[4]
            
            # STRICT: Only include if BOTH database AND branch match
            if ($fileDatabase -eq $database -and $branchFromFile -eq $branch) {
                $result.VersionFiles += [PSCustomObject]@{
                    FileName = $file.Name
                    FullPath = $file.FullName
                    FileDate = $fileDate
                    Version = $versionNumber
                    RequiresDateUpdate = ($fileDate -ne $today)
                    FileObject = $file
                }
                Write-Host "  Found version: $($file.Name)" -ForegroundColor Green
            }
        }
    }
    
    # Check if we found any matching files
    $totalMatches = $result.RepeatableFiles.Count + $result.VersionFiles.Count
    
    if ($totalMatches -eq 0) {
        $result.Error = "No migration files found for branch '$branch' with database '$database'.`n" +
                       "Expected patterns:`n" +
                       "  Repeatable: R__YYYY-MM-DD.$database.$branch.sql`n" +
                       "  Versioned: V1.00000__YYYY-MM-DD.$database.$branch.sql"
        return $result
    }
    
    $result.Success = $true
    Write-Host "Validated $totalMatches migration file(s) for branch '$branch'" -ForegroundColor Green
    
    return $result
}

# Update migration script dates using ONLY the validated files
function Update-ValidatedMigrationScriptDates {
    param(
        [array]$repeatableFiles,
        [array]$versionFiles,
        [string]$migrationPath,
        [string]$branch,
        [string]$database,
        [string]$today
    )
    
    $results = @{
        RepeatableScript = $null
        VersionScripts = @()
        UpdatedFiles = @()
    }
    
    # Process Repeatable scripts from validated list ONLY
    if ($repeatableFiles.Count -gt 0) {
        # Take the most recent one if multiple exist
        $latestRepeatable = $repeatableFiles | Sort-Object { $_.FileObject.LastWriteTime } -Descending | Select-Object -First 1
        
        $currentRepeatablePattern = "R__$today.$database.$branch.sql"
        $currentRepeatablePath = Join-Path $migrationPath $currentRepeatablePattern
        
        if ($latestRepeatable.RequiresDateUpdate) {
            Write-Host "Updating repeatable script date: $($latestRepeatable.FileName)" -ForegroundColor Yellow
            
            try {
                if (Test-Path $currentRepeatablePath) {
                    Remove-Item $currentRepeatablePath -Force
                }
                
                Rename-Item -Path $latestRepeatable.FullPath -NewName $currentRepeatablePattern -Force
                Write-Host "Renamed to: $currentRepeatablePattern" -ForegroundColor Green
                
                $results.UpdatedFiles += @{
                    OldName = $latestRepeatable.FileName
                    NewName = $currentRepeatablePattern
                    Type = "Repeatable"
                }
                
                $results.RepeatableScript = $currentRepeatablePath
            } catch {
                Write-Host "Failed to rename repeatable script: $($_.Exception.Message)" -ForegroundColor Red
                $results.RepeatableScript = $latestRepeatable.FullPath
            }
        } else {
            Write-Host "Repeatable script already has current date: $($latestRepeatable.FileName)" -ForegroundColor Green
            $results.RepeatableScript = $latestRepeatable.FullPath
        }
    }
    
    # Process Version scripts from validated list ONLY
    if ($versionFiles.Count -gt 0) {
        foreach ($versionFile in $versionFiles) {
            if ($versionFile.RequiresDateUpdate) {
                Write-Host "Updating version script date: $($versionFile.FileName)" -ForegroundColor Yellow
                
                $newVersionName = "$($versionFile.Version)__$today.$database.$branch.sql"
                $newVersionPath = Join-Path $migrationPath $newVersionName
                
                try {
                    if (Test-Path $newVersionPath) {
                        Remove-Item $newVersionPath -Force
                    }
                    
                    Rename-Item -Path $versionFile.FullPath -NewName $newVersionName -Force
                    Write-Host "Renamed to: $newVersionName" -ForegroundColor Green
                    
                    $results.UpdatedFiles += @{
                        OldName = $versionFile.FileName
                        NewName = $newVersionName
                        Type = "Version"
                        Version = $versionFile.Version
                    }
                    
                    # Add the updated file object
                    $results.VersionScripts += Get-Item $newVersionPath
                } catch {
                    Write-Host "Failed to rename version script: $($_.Exception.Message)" -ForegroundColor Red
                    # Keep the original if rename failed
                    $results.VersionScripts += $versionFile.FileObject
                }
            } else {
                Write-Host "Version script already has current date: $($versionFile.FileName)" -ForegroundColor Green
                $results.VersionScripts += $versionFile.FileObject
            }
        }
    }
    
    return $results
}

# Define a function to get the latest folder based on timestamp
function Get-LatestFolder {
    param([string]$folderPath)

    $folders = Get-ChildItem -Path $folderPath -Directory | Where-Object {
        $_.Name -like "*AppDb_Analytics_STG_MGR*" -and
        $_.Name -notlike "*master*" -and
        $_.Name -notlike "*@tmp" -and
        $_.Name -notlike "*deploy*" -and
        $_.Name -ne "Archive" -and
        $_.Name -ne "Migration" -and
        $_.Name -ne "*github*"
    }

    $latestFolder = $folders | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    return $latestFolder.FullName
}

# Initialize processed folders list
$processedFolders = @()

while ($true) {
    $latestFolder = Get-LatestFolder -folderPath $rootFolder

    if ($latestFolder -in $processedFolders) {
        Write-Host "All new folders are already processed. Exiting the script."
        break
    }

    if ($latestFolder) {
        Write-Host "Processing new folder: $latestFolder"

        $today = (Get-Date -Format "yyyy-MM-dd")
        $DateTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

        # STEP 1: Extract branch name from folder name
        Write-Host ""
        Write-Host "=== Step 1: Extracting Branch from Folder Name ===" -ForegroundColor Cyan
        $branch = Get-BranchFromFolderName -folderPath $latestFolder
        
        if (-not $branch) {
            Write-Host ""
            Write-Host "======================================" -ForegroundColor Red
            Write-Host "CRITICAL ERROR: Could not extract branch name from folder" -ForegroundColor Red
            Write-Host "======================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "Expected folder pattern: AppDb_Analytics_STG_MGR_branchname" -ForegroundColor Yellow
            Write-Host "Actual folder: $(Split-Path -Path $latestFolder -Leaf)" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Exiting with error code 1" -ForegroundColor Red
            Write-Host "======================================" -ForegroundColor Red
            exit 1
        }
        
        Write-Host "Successfully extracted branch: '$branch'" -ForegroundColor Green
        Write-Host "Processing branch: $branch" -ForegroundColor "Red"

        $DiffScriptLocation = "$latestFolder\Migration"
        
        # STEP 2: Validate Migration folder exists
        Write-Host ""
        Write-Host "=== Step 2: Validating Migration Folder ===" -ForegroundColor Cyan
        if (-not (Test-Path $DiffScriptLocation)) {
            Write-Host ""
            Write-Host "======================================" -ForegroundColor Red
            Write-Host "CRITICAL ERROR: Migration folder not found" -ForegroundColor Red
            Write-Host "======================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "Expected location: $DiffScriptLocation" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Migration scripts are MANDATORY for every Pull Request." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Please ensure:" -ForegroundColor Cyan
            Write-Host "  1. Migration folder exists at: $DiffScriptLocation" -ForegroundColor Cyan
            Write-Host "  2. Migration scripts follow naming conventions:" -ForegroundColor Cyan
            Write-Host "     - Repeatable: R__YYYY-MM-DD.$database.$branch.sql" -ForegroundColor Cyan
            Write-Host "     - Versioned: V1.00000__YYYY-MM-DD.$database.$branch.sql" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Exiting with error code 1" -ForegroundColor Red
            Write-Host "======================================" -ForegroundColor Red
            exit 1
        }
        
        Write-Host "Migration folder found: $DiffScriptLocation" -ForegroundColor Green

        # STEP 3: Validate and collect migration files for this specific branch
        Write-Host ""
        Write-Host "=== Step 3: Validating Migration Files for Branch '$branch' ===" -ForegroundColor Cyan
        $validatedFiles = Get-ValidatedMigrationFiles -migrationPath $DiffScriptLocation -branch $branch -database $database -today $today
        
        if (-not $validatedFiles.Success) {
            Write-Host ""
            Write-Host "======================================" -ForegroundColor Red
            Write-Host "CRITICAL ERROR: No valid migration scripts found for branch '$branch'" -ForegroundColor Red
            Write-Host "======================================" -ForegroundColor Red
            Write-Host ""
            Write-Host $validatedFiles.Error -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Migration Path: $DiffScriptLocation" -ForegroundColor Yellow
            Write-Host "Branch: $branch" -ForegroundColor Yellow
            Write-Host "Database: $database" -ForegroundColor Yellow
            Write-Host ""
            
            # Show what files exist but don't match
            $allFiles = Get-ChildItem -Path $DiffScriptLocation -Filter "*.sql" -ErrorAction SilentlyContinue
            if ($allFiles.Count -gt 0) {
                Write-Host "SQL files found in migration folder (none match branch '$branch'):" -ForegroundColor Yellow
                foreach ($file in $allFiles) {
                    Write-Host "  - $($file.Name)" -ForegroundColor Gray
                }
            } else {
                Write-Host "The migration folder contains NO SQL files." -ForegroundColor Yellow
            }
            
            Write-Host ""
            Write-Host "Required naming for branch '$branch':" -ForegroundColor Cyan
            Write-Host "  R__$today.$database.$branch.sql" -ForegroundColor White
            Write-Host "  V1.00000__$today.$database.$branch.sql" -ForegroundColor White
            Write-Host ""
            Write-Host "Exiting with error code 1" -ForegroundColor Red
            Write-Host "======================================" -ForegroundColor Red
            exit 1
        }

        Write-Host "Migration files validation passed!" -ForegroundColor Green
        Write-Host "  Repeatable files: $($validatedFiles.RepeatableFiles.Count)" -ForegroundColor Green
        Write-Host "  Version files: $($validatedFiles.VersionFiles.Count)" -ForegroundColor Green

        # STEP 4: Update dates using ONLY the validated files
        Write-Host ""
        Write-Host "=== Step 4: Updating Migration Script Dates ===" -ForegroundColor Cyan
        $scriptUpdate = Update-ValidatedMigrationScriptDates `
            -repeatableFiles $validatedFiles.RepeatableFiles `
            -versionFiles $validatedFiles.VersionFiles `
            -migrationPath $DiffScriptLocation `
            -branch $branch `
            -database $database `
            -today $today
        
        if ($scriptUpdate.UpdatedFiles.Count -gt 0) {
            Write-Host ""
            Write-Host "Updated migration script dates:" -ForegroundColor Green
            foreach ($update in $scriptUpdate.UpdatedFiles) {
                Write-Host "  $($update.Type): $($update.OldName) -> $($update.NewName)" -ForegroundColor Green
            }
        } else {
            Write-Host "All migration scripts already have current date." -ForegroundColor Green
        }

        # STEP 5: Repeatable Script Processing
        Write-Host ""
        Write-Host "=== Step 5: Repeatable Script Processing ===" -ForegroundColor Cyan
        if ($scriptUpdate.RepeatableScript -and (Test-Path $scriptUpdate.RepeatableScript)) {
            Write-Host "Found repeatable script: $(Split-Path -Path $scriptUpdate.RepeatableScript -Leaf)" -ForegroundColor Green
            Write-Host "Repeatable scripts don't require database version tracking." -ForegroundColor Cyan
        } else {
            Write-Host "No repeatable script found for branch '$branch'." -ForegroundColor Yellow
        }

        # STEP 6: Version Script Processing
        Write-Host ""
        Write-Host "=== Step 6: Version Script Processing ===" -ForegroundColor Cyan
        if ($scriptUpdate.VersionScripts.Count -eq 0) {
            Write-Host "No version scripts found for branch '$branch'." -ForegroundColor Yellow
            Write-Host "Skipping database version management." -ForegroundColor Yellow
            $processedFolders += $latestFolder
            continue
        }

        Write-Host "Found $($scriptUpdate.VersionScripts.Count) version script(s):" -ForegroundColor Green
        foreach ($script in $scriptUpdate.VersionScripts) {
            Write-Host "  - $($script.Name)" -ForegroundColor Green
        }
        
        $versionScript = $scriptUpdate.VersionScripts[0]
        # Extract version from script name
        if ($versionScript.Name -match "^(V\d{1,3}\.\d{5})__") {
            $scriptVersion = $matches[1]
            Write-Host "Script file version: $scriptVersion" -ForegroundColor Cyan
        } else {
            Write-Host "Warning: Could not extract version from script name: $($versionScript.Name)" -ForegroundColor Yellow
            $processedFolders += $latestFolder
            continue
        }

        # STEP 7: Database Version Management with Strict Sequential Enforcement
        Write-Host ""
        Write-Host "=== Step 7: Database Version Management (Strict Sequential Enforcement) ===" -ForegroundColor Cyan
        Write-Host "Connecting to database for version management..."
        
        $versionConnectionString = "Server=$serverPRD;Database=AppDb_Analytics;User ID=$userName;Password=$password;"
        $versionConnection = New-Object System.Data.SqlClient.SqlConnection($versionConnectionString)

        try {
            $versionConnection.Open()
            Write-Host "Connected to AppDb_Analytics database"
        }
        catch {
            Write-Host "Failed to connect to AppDb_Analytics. Error: $($_.Exception.Message)" -ForegroundColor Red
            $processedFolders += $latestFolder
            continue
        }

        $finalVersion = $scriptVersion
        $shouldCreateNewRecord = $true
        $gapDetectedForOldVersion = $null

        try {
            # STEP 7.1: Find the LATEST DEPLOYED version (this is our baseline)
            Write-Host ""
            Write-Host "Step 7.1: Identifying latest deployed version..." -ForegroundColor Yellow
            
            $latestDeployedQuery = @"
SELECT TOP 1 VersionPR 
FROM [AppDb_Analytics].[dbo].[VersionHistory]
WHERE IsDeployed = 1
ORDER BY 
    CAST(SUBSTRING(VersionPR, 2, CHARINDEX('.', VersionPR) - 2) AS INT) DESC,
    CAST(SUBSTRING(VersionPR, CHARINDEX('.', VersionPR) + 1, 5) AS INT) DESC;
"@
            
            $latestDeployedCmd = $versionConnection.CreateCommand()
            $latestDeployedCmd.CommandText = $latestDeployedQuery
            $latestDeployedVersion = $latestDeployedCmd.ExecuteScalar()
            
            if ($latestDeployedVersion) {
                Write-Host "Latest deployed version: $latestDeployedVersion" -ForegroundColor Cyan
                $deployedParsed = Parse-VersionNumber -version $latestDeployedVersion
                
                if (-not $deployedParsed.IsValid) {
                    Write-Host "Warning: Could not parse deployed version format" -ForegroundColor Yellow
                    $latestDeployedVersion = $null
                }
            } else {
                Write-Host "No deployed versions found - this is the first deployment" -ForegroundColor Cyan
            }
            
            # STEP 7.2: Calculate the NEXT AVAILABLE version after latest deployed
            Write-Host ""
            Write-Host "Step 7.2: Calculating next available version..." -ForegroundColor Yellow
            
            $nextAvailableVersion = $null
            
            if ($latestDeployedVersion) {
                $deployedParsed = Parse-VersionNumber -version $latestDeployedVersion
                $nextMajor = $deployedParsed.Major
                $nextMinor = $deployedParsed.Minor + 1
                
                if ($nextMinor -gt 99999) {
                    $nextMinor = 1
                    $nextMajor += 1
                }
                
                $nextAvailableVersion = Format-VersionNumber -major $nextMajor -minor $nextMinor
                Write-Host "Next available version after deployed: $nextAvailableVersion" -ForegroundColor Green
            } else {
                # No deployed versions - check if ANY versions exist at all
                $anyVersionQuery = "SELECT TOP 1 VersionPR FROM [AppDb_Analytics].[dbo].[VersionHistory] ORDER BY CAST(SUBSTRING(VersionPR, 2, CHARINDEX('.', VersionPR) - 2) AS INT) DESC, CAST(SUBSTRING(VersionPR, CHARINDEX('.', VersionPR) + 1, 5) AS INT) DESC"
                $anyVersionCmd = $versionConnection.CreateCommand()
                $anyVersionCmd.CommandText = $anyVersionQuery
                $anyVersion = $anyVersionCmd.ExecuteScalar()
                
                if ($anyVersion) {
                    $anyParsed = Parse-VersionNumber -version $anyVersion
                    $nextMajor = $anyParsed.Major
                    $nextMinor = $anyParsed.Minor + 1
                    
                    if ($nextMinor -gt 99999) {
                        $nextMinor = 1
                        $nextMajor += 1
                    }
                    
                    $nextAvailableVersion = Format-VersionNumber -major $nextMajor -minor $nextMinor
                    Write-Host "Next available version (no deployments yet): $nextAvailableVersion" -ForegroundColor Green
                } else {
                    # Truly first version ever
                    $nextAvailableVersion = Format-VersionNumber -major 1 -minor 1
                    Write-Host "First version ever: $nextAvailableVersion" -ForegroundColor Green
                }
            }
            
            # STEP 7.3: Check if current branch already has a version
            Write-Host ""
            Write-Host "Step 7.3: Checking if branch '$branch' has existing version..." -ForegroundColor Yellow
            
            $branchVersionQuery = @"
SELECT TOP 1 VersionPR, IsDeployed, BranchDate, ReassignmentNote
FROM [AppDb_Analytics].[dbo].[VersionHistory]
WHERE BranchName = @branch
ORDER BY 
    CAST(SUBSTRING(VersionPR, 2, CHARINDEX('.', VersionPR) - 2) AS INT) DESC,
    CAST(SUBSTRING(VersionPR, CHARINDEX('.', VersionPR) + 1, 5) AS INT) DESC
"@
            
            $branchCmd = $versionConnection.CreateCommand()
            $branchCmd.CommandText = $branchVersionQuery
            $branchCmd.Parameters.AddWithValue("@branch", $branch) | Out-Null
            $branchReader = $branchCmd.ExecuteReader()
            
            $existingBranchRecord = $null
            if ($branchReader.Read()) {
                $existingBranchRecord = @{
                    VersionPR = $branchReader["VersionPR"].ToString()
                    IsDeployed = [bool]$branchReader["IsDeployed"]
                    BranchDate = $branchReader["BranchDate"]
                    ReassignmentNote = if ($branchReader["ReassignmentNote"] -is [DBNull]) { $null } else { $branchReader["ReassignmentNote"].ToString() }
                }
            }
            $branchReader.Close()
            
            if ($existingBranchRecord) {
                Write-Host "Found existing version for branch: $($existingBranchRecord.VersionPR)" -ForegroundColor Cyan
                Write-Host "  IsDeployed: $($existingBranchRecord.IsDeployed)" -ForegroundColor Gray
                
                if ($existingBranchRecord.IsDeployed) {
                    # Branch version is deployed - cannot change it
                    Write-Host "This version has been deployed - keeping version $($existingBranchRecord.VersionPR)" -ForegroundColor Green
                    $finalVersion = $existingBranchRecord.VersionPR
                    $shouldCreateNewRecord = $false
                } else {
                    # Branch version exists but NOT deployed - check if it's valid for deployment
                    $branchVersionParsed = Parse-VersionNumber -version $existingBranchRecord.VersionPR
                    
                    if ($latestDeployedVersion) {
                        $deployedParsed = Parse-VersionNumber -version $latestDeployedVersion
                        $branchVersionNumber = ($branchVersionParsed.Major * 100000) + $branchVersionParsed.Minor
                        $deployedVersionNumber = ($deployedParsed.Major * 100000) + $deployedParsed.Minor
                        
                        if ($branchVersionNumber -le $deployedVersionNumber) {
                            # Existing branch version is BEHIND deployed version - MUST reassign
                            Write-Host "Existing version $($existingBranchRecord.VersionPR) is behind deployed $latestDeployedVersion" -ForegroundColor Yellow
                            Write-Host "Reassigning to next available: $nextAvailableVersion" -ForegroundColor Yellow
                            
                            # Delete the old record for this branch
                            $deleteOldQuery = "DELETE FROM [AppDb_Analytics].[dbo].[VersionHistory] WHERE VersionPR = @oldVersion AND BranchName = @branch"
                            $deleteCmd = $versionConnection.CreateCommand()
                            $deleteCmd.CommandText = $deleteOldQuery
                            $deleteCmd.Parameters.AddWithValue("@oldVersion", $existingBranchRecord.VersionPR) | Out-Null
                            $deleteCmd.Parameters.AddWithValue("@branch", $branch) | Out-Null
                            $deleteCmd.ExecuteNonQuery() | Out-Null
                            Write-Host "Deleted outdated version record: $($existingBranchRecord.VersionPR)" -ForegroundColor Gray
                            
                            # Rename script file to next available version
                            $newScriptName = "${nextAvailableVersion}__$today.$database.$branch.sql"
                            $newScriptPath = Join-Path $DiffScriptLocation $newScriptName
                            
                            if (Test-Path $newScriptPath) { Remove-Item $newScriptPath -Force }
                            Rename-Item -Path $versionScript.FullName -NewName $newScriptName -Force
                            Write-Host "Renamed script to: $newScriptName" -ForegroundColor Green
                            $versionScript = Get-Item $newScriptPath
                            
                            $finalVersion = $nextAvailableVersion
                            $shouldCreateNewRecord = $true
                            $gapDetectedForOldVersion = $existingBranchRecord.VersionPR
                        } else {
                            # Existing branch version is AFTER deployed - it's still valid
                            Write-Host "Existing version $($existingBranchRecord.VersionPR) is after deployed $latestDeployedVersion - keeping it" -ForegroundColor Green
                            $finalVersion = $existingBranchRecord.VersionPR
                            $shouldCreateNewRecord = $false
                            
                            # Update script file name to match database version if needed
                            if ($scriptVersion -ne $existingBranchRecord.VersionPR) {
                                $correctScriptName = "$($existingBranchRecord.VersionPR)__$today.$database.$branch.sql"
                                $correctScriptPath = Join-Path $DiffScriptLocation $correctScriptName
                                
                                if (Test-Path $correctScriptPath) { Remove-Item $correctScriptPath -Force }
                                Rename-Item -Path $versionScript.FullName -NewName $correctScriptName -Force
                                Write-Host "Renamed script to match database version: $correctScriptName" -ForegroundColor Green
                                $versionScript = Get-Item $correctScriptPath
                            }
                        }
                    } else {
                        # No deployed versions - keep existing branch version
                        Write-Host "No deployed versions yet - keeping existing version $($existingBranchRecord.VersionPR)" -ForegroundColor Green
                        $finalVersion = $existingBranchRecord.VersionPR
                        $shouldCreateNewRecord = $false
                    }
                }
            } else {
    # STEP 7.4: No existing version for this branch - check if nextAvailableVersion is occupied
    Write-Host "No existing version for branch '$branch'" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Step 7.4: Checking if next available version is occupied..." -ForegroundColor Yellow
    
    $occupiedCheckQuery = @"
SELECT TOP 1 BranchName, IsDeployed 
FROM [AppDb_Analytics].[dbo].[VersionHistory]
WHERE VersionPR = @nextVersion
"@
    
    $occupiedCmd = $versionConnection.CreateCommand()
    $occupiedCmd.CommandText = $occupiedCheckQuery
    $occupiedCmd.Parameters.AddWithValue("@nextVersion", $nextAvailableVersion) | Out-Null
    $occupiedReader = $occupiedCmd.ExecuteReader()
    
    $occupyingBranch = $null
    $isOccupiedDeployed = $false
    
    if ($occupiedReader.Read()) {
        $occupyingBranch = $occupiedReader["BranchName"].ToString()
        $isOccupiedDeployed = [bool]$occupiedReader["IsDeployed"]
    }
    $occupiedReader.Close()
    
    if ($occupyingBranch) {
        if ($isOccupiedDeployed) {
            # Version is occupied by a DEPLOYED branch - skip to next version
            Write-Host "Version $nextAvailableVersion is occupied by DEPLOYED branch '$occupyingBranch'" -ForegroundColor Yellow
            Write-Host "This should not happen - recalculating next available..." -ForegroundColor Red
            
            # Recalculate by finding absolute max version
            $maxQuery = "SELECT TOP 1 VersionPR FROM [AppDb_Analytics].[dbo].[VersionHistory] ORDER BY CAST(SUBSTRING(VersionPR, 2, CHARINDEX('.', VersionPR) - 2) AS INT) DESC, CAST(SUBSTRING(VersionPR, CHARINDEX('.', VersionPR) + 1, 5) AS INT) DESC"
            $maxCmd = $versionConnection.CreateCommand()
            $maxCmd.CommandText = $maxQuery
            $maxVersion = $maxCmd.ExecuteScalar()
            
            $maxParsed = Parse-VersionNumber -version $maxVersion
            $nextMajor = $maxParsed.Major
            $nextMinor = $maxParsed.Minor + 1
            if ($nextMinor -gt 99999) { $nextMinor = 1; $nextMajor += 1 }
            
            $nextAvailableVersion = Format-VersionNumber -major $nextMajor -minor $nextMinor
            Write-Host "Recalculated next available: $nextAvailableVersion" -ForegroundColor Green
        } else {
            # Version is occupied by UNDEPLOYED branch - OVERWRITE it
            Write-Host "Version $nextAvailableVersion is occupied by UNDEPLOYED branch '$occupyingBranch'" -ForegroundColor Yellow
            Write-Host "Enforcing strict sequencing - OVERWRITING with current branch '$branch'" -ForegroundColor Red
            
            # Delete the occupying record
            $deleteQuery = "DELETE FROM [AppDb_Analytics].[dbo].[VersionHistory] WHERE VersionPR = @version AND BranchName = @occupyingBranch"
            $deleteCmd = $versionConnection.CreateCommand()
            $deleteCmd.CommandText = $deleteQuery
            $deleteCmd.Parameters.AddWithValue("@version", $nextAvailableVersion) | Out-Null
            $deleteCmd.Parameters.AddWithValue("@occupyingBranch", $occupyingBranch) | Out-Null
            
            $deletedRows = $deleteCmd.ExecuteNonQuery()
            Write-Host "Removed version assignment from branch '$occupyingBranch' ($deletedRows row(s) deleted)" -ForegroundColor Gray
        }
    } else {
        Write-Host "Version $nextAvailableVersion is available - assigning to branch '$branch'" -ForegroundColor Green
    }
    
    #FIX: Check if script already has the correct version before renaming
    $currentScriptVersion = $scriptVersion  # The version extracted from current filename
    $targetScriptName = "${nextAvailableVersion}__$today.$database.$branch.sql"
    $targetScriptPath = Join-Path $DiffScriptLocation $targetScriptName
    
    if ($versionScript.Name -eq $targetScriptName) {
        # Script already has the correct name - don't rename!
        Write-Host "Script already has correct version and name: $targetScriptName" -ForegroundColor Green
        Write-Host "No rename needed - keeping existing file" -ForegroundColor Cyan
    } elseif ($versionScript.FullName -eq $targetScriptPath) {
        # Full paths match - don't rename!
        Write-Host "Script path already correct: $targetScriptPath" -ForegroundColor Green
    } else {
        # Need to rename - but be careful!
        Write-Host "Renaming script from $($versionScript.Name) to $targetScriptName" -ForegroundColor Yellow
        
        # Only remove target if it exists AND is different from source
        if ((Test-Path $targetScriptPath) -and ($versionScript.FullName -ne $targetScriptPath)) {
            Write-Host "Removing existing file at target location" -ForegroundColor Yellow
            Remove-Item $targetScriptPath -Force
        }
        
        # Perform the rename
        Rename-Item -Path $versionScript.FullName -NewName $targetScriptName -Force
        Write-Host "Renamed script to: $targetScriptName" -ForegroundColor Green
        $versionScript = Get-Item $targetScriptPath
    }
    
    $finalVersion = $nextAvailableVersion
    $shouldCreateNewRecord = $true
    
    if ($currentScriptVersion -ne $nextAvailableVersion) {
        $gapDetectedForOldVersion = $currentScriptVersion
    }
}
            
# STEP 7.5: Insert or Update database record
Write-Host ""
Write-Host "Step 7.5: Saving version to database..." -ForegroundColor Yellow

# Define script filename BEFORE the if/else blocks so it's available in both paths
$scriptFileName = $versionScript.Name

if ($shouldCreateNewRecord) {
    Write-Host "Inserting new version record: $finalVersion" -ForegroundColor Cyan
    
    $versionPRForDB = $finalVersion
    $versionIdForDB = $finalVersion.Substring(1)  # Remove 'V' prefix
    
    $insertQuery = @"
INSERT INTO [AppDb_Analytics].[dbo].[VersionHistory] (VersionId, VersionPR, BranchName, BranchDate, IsDeployed, Script, ReassignmentNote)
VALUES (@versionId, @versionPR, @branch, @datetime, 0, @script, @reassignmentNote)
"@
    
    $insertCmd = $versionConnection.CreateCommand()
    $insertCmd.CommandText = $insertQuery
    $insertCmd.Parameters.AddWithValue("@versionId", $versionIdForDB) | Out-Null
    $insertCmd.Parameters.AddWithValue("@versionPR", $versionPRForDB) | Out-Null
    $insertCmd.Parameters.AddWithValue("@branch", $branch) | Out-Null
    $insertCmd.Parameters.AddWithValue("@datetime", $DateTime) | Out-Null
    $insertCmd.Parameters.AddWithValue("@script", $scriptFileName) | Out-Null
    
    $reassignmentNote = if ($gapDetectedForOldVersion) {
        "Originally $gapDetectedForOldVersion, reassigned to enforce sequential deployment order"
    } else {
        [DBNull]::Value
    }
    $insertCmd.Parameters.AddWithValue("@reassignmentNote", $reassignmentNote) | Out-Null
    
    try {
        $rowsAffected = $insertCmd.ExecuteNonQuery()
        if ($rowsAffected -gt 0) {
            Write-Host "Successfully inserted version: $versionPRForDB for branch '$branch'" -ForegroundColor Green
            Write-Host "  Script file: $scriptFileName" -ForegroundColor Gray
            if ($gapDetectedForOldVersion) {
                Write-Host "  Note: Reassigned from $gapDetectedForOldVersion" -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host "Failed to insert: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "Updating existing version record: $finalVersion" -ForegroundColor Cyan
    
    # CRITICAL FIX: Update both BranchDate AND Script columns to keep them in sync
    $updateQuery = @"
UPDATE [AppDb_Analytics].[dbo].[VersionHistory] 
SET BranchDate = @datetime,
    Script = @script
WHERE VersionPR = @version AND BranchName = @branch
"@
    
    $updateCmd = $versionConnection.CreateCommand()
    $updateCmd.CommandText = $updateQuery
    $updateCmd.Parameters.AddWithValue("@version", $finalVersion) | Out-Null
    $updateCmd.Parameters.AddWithValue("@branch", $branch) | Out-Null
    $updateCmd.Parameters.AddWithValue("@datetime", $DateTime) | Out-Null
    $updateCmd.Parameters.AddWithValue("@script", $scriptFileName) | Out-Null
    
    try {
        $rowsUpdated = $updateCmd.ExecuteNonQuery()
        if ($rowsUpdated -gt 0) {
            Write-Host "Updated version record successfully" -ForegroundColor Green
            Write-Host "  New timestamp: $DateTime" -ForegroundColor Gray
            Write-Host "  Updated script filename: $scriptFileName" -ForegroundColor Gray
        } else {
            Write-Host "Warning: No rows updated" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Failed to update: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
            
        } finally {
            $versionConnection.Close()
            Write-Host "Closed database connection"
        }

        Write-Host ""
        Write-Host "=== Version Management Complete ===" -ForegroundColor Cyan
        Write-Host "Branch: $branch" -ForegroundColor White
        Write-Host "Final Version: $finalVersion" -ForegroundColor Green
        Write-Host "Action: $(if ($shouldCreateNewRecord) { 'Created new version' } else { 'Updated existing version' })" -ForegroundColor Green
        if ($latestDeployedVersion) {
            Write-Host "Latest Deployed: $latestDeployedVersion" -ForegroundColor Gray
        }
        Write-Host ""

        # Mark folder as processed
        $processedFolders += $latestFolder
    }
}

# Move files back to AppDb_Analytics folder
if ($latestFolder) {
    Write-Host "Moving project file to AppDb_Analytics folder...`r`n"

    $sourceFolder = "$latestFolder\"
    $destinationFolder = "$latestFolder\AppDb_Analytics"

    $filesToMove = @("AppDb_Converse.sqlproj")

    foreach ($file in $filesToMove) {
        $sourcePath = Join-Path $sourceFolder $file
        $destinationPath = Join-Path $destinationFolder $file
        
        if (Test-Path -Path $sourcePath) {
            Move-Item -Path $sourcePath -Destination $destinationPath -Force
            Write-Host "Moved $file back to AppDb_Analytics folder" -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Host "File $file not found" -ForegroundColor Yellow
            Write-Host ""
        }
    }
}
