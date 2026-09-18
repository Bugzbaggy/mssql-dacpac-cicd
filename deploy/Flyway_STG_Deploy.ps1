<#
.SYNOPSIS
    Continuous Deployment (CD) using PowerShell and Flyway for SQL Server.

.DESCRIPTION
    Automates Flyway migrations to target production database/s and updates VersionHistory.
    
    Author: Renz Bagasbas
    Date: July 07, 2025
    Updated: November 2025 - Changed version format from V000.00000 to V1.00000
#>

#region Variables
$SourceUser = $Env:USER
$SourcePass = $Env:PASS

# Alternate way to load environment variables for local testing:
# $SourceUser = [System.Environment]::GetEnvironmentVariable("STG_DB_USER", [System.EnvironmentVariableTarget]::User)
# $SourcePass = [System.Environment]::GetEnvironmentVariable("STG_DB_PASS", [System.EnvironmentVariableTarget]::User)

$BUILD_NUMBER = [System.Environment]::GetEnvironmentVariable("BUILD_NUMBER", [System.EnvironmentVariableTarget]::User)

# If BUILD_NUMBER is not set, use a default
if ([string]::IsNullOrEmpty($BUILD_NUMBER)) {
    $BUILD_NUMBER = "manual-$(Get-Date -Format 'yyyyMMdd')"
    Write-Host "Generated BUILD_NUMBER: $BUILD_NUMBER" -ForegroundColor Yellow
}

$server = 'listener.example.com'
$database = 'AppDb_Analytics'
$isWindowsAuthentication = $false
$rootFolder = "C:\Jenkins\workspace"

Write-Host "Server: $server; Database: $database"

# Create connection string for testing
$connectionString = "Server=$server;Database=$database;User ID=$SourceUser;Password=$SourcePass;"

# Test the database connection
Write-Host "Testing the database connection..."
$connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
try {
    $connection.Open()
    Write-Host "Connection successful" -ForegroundColor Green
}
catch {
    Write-Host "Connection failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    $connection.Close()
}

# Function to execute SQL queries
function Invoke-SqlQuery {
    param (
        [string]$query,
        [string]$connectionString
    )
    
    Write-Host "Executing query: $query" -ForegroundColor Gray
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
    
    try {
        $connection.Open()
        Write-Host "Connection opened successfully" -ForegroundColor Gray
        
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $dataset = New-Object System.Data.DataSet
        $rowCount = $adapter.Fill($dataset)
        
        Write-Host "Query executed. Rows affected/returned: $rowCount" -ForegroundColor Gray
        
        if ($dataset.Tables.Count -gt 0) {
            $table = $dataset.Tables[0]
            Write-Host "Returned DataTable with $($table.Rows.Count) rows and $($table.Columns.Count) columns" -ForegroundColor Gray
            return $table
        } else {
            Write-Host "No tables returned from query" -ForegroundColor Yellow
            # Return an empty DataTable instead of null
            $emptyTable = New-Object System.Data.DataTable
            return $emptyTable
        }
    }
    catch {
        Write-Host "SQL query failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Connection State: $($connection.State)" -ForegroundColor Red
        throw
    }
    finally {
        if ($connection.State -eq 'Open') {
            $connection.Close()
            Write-Host "Connection closed" -ForegroundColor Gray
        }
    }
}

# Function to execute non-query SQL commands
function Invoke-SqlNonQuery {
    param (
        [string]$query,
        [string]$connectionString
    )
    
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
    
    try {
        $connection.Open()
        $result = $command.ExecuteNonQuery()
        return $result
    }
    catch {
        Write-Host "SQL command failed: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    finally {
        $connection.Close()
    }
}

# Function to get the current Flyway schema version
function Get-FlywayCurrentVersion {
    param (
        [string]$connectionString
    )
    
    $query = "SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC"
    Write-Host "Getting current Flyway version..." -ForegroundColor Gray
    
    try {
        $result = Invoke-SqlQuery -query $query -connectionString $connectionString
        
        if ($result -ne $null) {
            if ($result.GetType().Name -eq "DataTable" -and $result.Rows.Count -gt 0) {
                $currentVersion = $result.Rows[0]["version"]
                Write-Host "Current Flyway schema version: $currentVersion" -ForegroundColor Cyan
                return $currentVersion
            } elseif ($result.GetType().Name -eq "DataRow") {
                $currentVersion = $result["version"]
                Write-Host "Current Flyway schema version: $currentVersion" -ForegroundColor Cyan
                return $currentVersion
            }
        }
        
        Write-Host "No version found in flyway_schema_history" -ForegroundColor Yellow
        return $null
    }
    catch {
        Write-Host "Could not retrieve Flyway version (table might not exist yet): $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# Function to parse and extract deployed versions from Flyway output - UPDATED FOR NEW FORMAT
function Get-DeployedVersionsFromFlywayOutput {
    param (
        [string]$flywayOutput
    )
    
    Write-Host "Analyzing Flyway output for deployed versions..." -ForegroundColor Cyan
    
    $deployedVersions = @()
    $outputLines = $flywayOutput -split "`n"
    
    # Look for migration success patterns - UPDATED REGEX FOR V1.00000 FORMAT
    foreach ($line in $outputLines) {
        Write-Host "Analyzing line: $line" -ForegroundColor DarkGray
        
        # Match patterns like: "Migrating schema [dbo] to version "1.00002 - 2025-08-06.AppDb Connect.CICD-T1000""
        # Updated regex to handle 1-3 digit major version (V1.00000 to V999.99999)
        $matches = [regex]::Matches($line, 'Migrating\s+schema.*?to\s+version\s+"(\d{1,3}\.\d{5})\s*-')
        foreach ($match in $matches) {
            $version = $match.Groups[1].Value.Trim()
            if ($version -notin $deployedVersions) {
                $deployedVersions += $version
                Write-Host "Found deployed version: $version" -ForegroundColor Green
            }
        }
        
        # Alternative pattern: "Migrating schema ... to version 1.00011"
        $altMatches = [regex]::Matches($line, "Migrating.*?to version\s*`"?(\d{1,3}\.\d{5})")
        foreach ($match in $altMatches) {
            $version = $match.Groups[1].Value.Trim()
            if ($version -notin $deployedVersions) {
                $deployedVersions += $version
                Write-Host "Found deployed version: $version" -ForegroundColor Green
            }
        }
        
        # Match patterns like: "Successfully applied 1 migration to schema"
        if ($line -match "Successfully applied \d+ migration.*to schema" -and $deployedVersions.Count -eq 0) {
            # This indicates migrations happened but we need to look for version info elsewhere
            Write-Host "Migration success detected, but need to identify specific version" -ForegroundColor Yellow
        }
        
        # Match version patterns in success messages - more comprehensive (as fallback)
        # Updated regex for new format
        if ($line -match "version\s*`"?(\d{1,3}\.\d{5})" -or 
            $line -match "V(\d{1,3}\.\d{5}).*applied" -or 
            $line -match "now at version v(\d{1,3}\.\d{5})") {
            $version = $matches[1].Trim()
            if ($version -notin $deployedVersions) {
                $deployedVersions += $version
                Write-Host "Found deployed version from success message: $version" -ForegroundColor Green
            }
        }
    }
    
    Write-Host "Total deployed versions identified: $($deployedVersions.Count)" -ForegroundColor Cyan
    foreach ($ver in $deployedVersions) {
        Write-Host "  - $ver" -ForegroundColor Green
    }
    
    return $deployedVersions
}

# Function to get failed versions from Flyway output - UPDATED FOR NEW FORMAT
function Get-FailedVersionsFromFlywayOutput {
    param (
        [string]$flywayOutput
    )
    
    Write-Host "Analyzing Flyway output for failed versions..." -ForegroundColor Magenta
    
    $failedVersions = @()
    $outputLines = $flywayOutput -split "`n"
    
    # Look for migration failure patterns - UPDATED REGEX FOR V1.00000 FORMAT
    foreach ($line in $outputLines) {
        Write-Host "Analyzing line for failures: $line" -ForegroundColor DarkGray
        
        # Match patterns indicating migration failures
        # Updated regex to handle 1-3 digit major version
        if ($line -match "Migration.*V(\d{1,3}\.\d{5}).*failed" -or
            $line -match "Error.*version.*(\d{1,3}\.\d{5})" -or
            $line -match "Unable to obtain connection.*V(\d{1,3}\.\d{5})" -or
            $line -match "Migration.*(\d{1,3}\.\d{5}).*ERROR") {
            $version = $matches[1].Trim()
            if ($version -notin $failedVersions) {
                $failedVersions += $version
                Write-Host "Found failed version: $version" -ForegroundColor Red
            }
        }
    }
    
    Write-Host "Total failed versions identified: $($failedVersions.Count)" -ForegroundColor Magenta
    foreach ($ver in $failedVersions) {
        Write-Host "  - $ver" -ForegroundColor Red
    }
    
    return $failedVersions
}

# Function to update VersionHistory for successful deployments
function Update-VersionHistorySuccess {
    param (
        [array]$deployedVersions,
        [string]$connectionString
    )
    
    Write-Host "Updating VersionHistory for successful deployments..." -ForegroundColor Cyan
    
    foreach ($deployedVersion in $deployedVersions) {
        Write-Host "Processing successfully deployed version: $deployedVersion" -ForegroundColor Cyan
        
        # Check if version exists and current status
        $statusQuery = "SELECT IsDeployed, DeployNote FROM [AppDb_Analytics].[dbo].[VersionHistory] WHERE VersionId = '$deployedVersion'"
        $statusResult = Invoke-SqlQuery -query $statusQuery -connectionString $connectionString
        
        $versionExists = $false
        $currentIsDeployed = $false
        
        if ($statusResult -ne $null) {
            if ($statusResult.GetType().Name -eq "DataTable" -and $statusResult.Rows.Count -gt 0) {
                $versionExists = $true
                $currentIsDeployed = [bool]$statusResult.Rows[0]["IsDeployed"]
            } elseif ($statusResult.GetType().Name -eq "DataRow") {
                $versionExists = $true
                $currentIsDeployed = [bool]$statusResult["IsDeployed"]
            }
        }
        
        if (-not $versionExists) {
            Write-Host "Warning: Version $deployedVersion not found in VersionHistory table" -ForegroundColor Yellow
            continue
        }
        
        # Skip if already marked as deployed
        if ($currentIsDeployed) {
            Write-Host "Version $deployedVersion is already marked as deployed. Skipping update." -ForegroundColor Yellow
            continue
        }
        
        # Update the VersionHistory record for successful deployment
        $updateQuery = @"
UPDATE [AppDb_Analytics].[dbo].[VersionHistory] 
SET IsDeployed = 1, 
    DeployDate = GETDATE(), 
    DeployNote = 'Successfully deployed'
WHERE VersionId = '$deployedVersion'
    AND IsDeployed = 0
"@
        
        Write-Host "Updating VersionHistory for successful deployment of version $deployedVersion" -ForegroundColor Green
        
        try {
            $rowsUpdated = Invoke-SqlNonQuery -query $updateQuery -connectionString $connectionString
            
            if ($rowsUpdated -gt 0) {
                Write-Host "Successfully updated $rowsUpdated record(s) for version $deployedVersion" -ForegroundColor Green
            } else {
                Write-Host "No records updated for version $deployedVersion - may already be deployed" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Error updating VersionHistory for version $deployedVersion : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Function to update VersionHistory for failed deployments
function Update-VersionHistoryFailure {
    param (
        [array]$failedVersions,
        [string]$errorMessage,
        [string]$connectionString
    )
    
    Write-Host "Updating VersionHistory for failed deployments..." -ForegroundColor Red
    
    # If no specific failed versions identified, try to find versions that might have been affected
    if ($failedVersions.Count -eq 0) {
        Write-Host "No specific failed versions identified. Looking for pending versions..." -ForegroundColor Yellow
        
        # Get versions that are not deployed (potential candidates for failure)
        $pendingQuery = "SELECT VersionId FROM [AppDb_Analytics].[dbo].[VersionHistory] WHERE IsDeployed = 0 AND ReassignmentNote IS NULL"
        try {
            $pendingResult = Invoke-SqlQuery -query $pendingQuery -connectionString $connectionString
            
            if ($pendingResult -ne $null -and $pendingResult.GetType().Name -eq "DataTable" -and $pendingResult.Rows.Count -gt 0) {
                Write-Host "Found $($pendingResult.Rows.Count) pending version(s) that may have failed" -ForegroundColor Yellow
                # For now, we won't automatically mark all pending as failed unless we can be more specific
                # This prevents false positives
                Write-Host "Manual review may be needed to identify which specific version(s) failed" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Could not query for pending versions: $($_.Exception.Message)" -ForegroundColor Red
        }
        return
    }
    
    foreach ($failedVersion in $failedVersions) {
        Write-Host "Processing failed version: $failedVersion" -ForegroundColor Red
        
        # Check if version exists in VersionHistory
        $statusQuery = "SELECT IsDeployed, DeployNote FROM [AppDb_Analytics].[dbo].[VersionHistory] WHERE VersionId = '$failedVersion'"
        $statusResult = Invoke-SqlQuery -query $statusQuery -connectionString $connectionString
        
        $versionExists = $false
        $currentIsDeployed = $false
        
        if ($statusResult -ne $null) {
            if ($statusResult.GetType().Name -eq "DataTable" -and $statusResult.Rows.Count -gt 0) {
                $versionExists = $true
                $currentIsDeployed = [bool]$statusResult.Rows[0]["IsDeployed"]
            } elseif ($statusResult.GetType().Name -eq "DataRow") {
                $versionExists = $true
                $currentIsDeployed = [bool]$statusResult["IsDeployed"]
            }
        }
        
        if (-not $versionExists) {
            Write-Host "Warning: Failed version $failedVersion not found in VersionHistory table" -ForegroundColor Yellow
            continue
        }
        
        # Skip if already marked as deployed
        if ($currentIsDeployed) {
            Write-Host "Version $failedVersion is already marked as deployed. Not updating with error." -ForegroundColor Yellow
            continue
        }
        
        # Truncate error message if too long (SQL Server varchar limits)
        $truncatedError = if ($errorMessage.Length -gt 500) { 
            $errorMessage.Substring(0, 497) + "..." 
        } else { 
            $errorMessage 
        }
        
        # Update the VersionHistory record for failed deployment
        $updateQuery = @"
UPDATE [AppDb_Analytics].[dbo].[VersionHistory] 
SET DeployDate = GETDATE(), 
    DeployNote = 'Error: $truncatedError'
WHERE VersionId = '$failedVersion'
    AND IsDeployed = 0
"@
        
        Write-Host "Updating VersionHistory with error for version $failedVersion" -ForegroundColor Red
        
        try {
            $rowsUpdated = Invoke-SqlNonQuery -query $updateQuery -connectionString $connectionString
            
            if ($rowsUpdated -gt 0) {
                Write-Host "Successfully updated $rowsUpdated record(s) with error for version $failedVersion" -ForegroundColor Yellow
            } else {
                Write-Host "No records updated for failed version $failedVersion - may already be processed" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Error updating VersionHistory for failed version $failedVersion : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Enhanced function to handle Flyway migration with simplified error handling
function Invoke-FlywayMigration {
    param (
        [string]$DiffScriptLocation,
        [string]$SourceUser,
        [string]$SourcePass,
        [string]$connectionString
    )
    
    Write-Host "Starting Flyway migration..." -ForegroundColor Cyan
    
    # Get current schema version before migration attempt
    $preFlywayVersion = Get-FlywayCurrentVersion -connectionString $connectionString
    Write-Host "Pre-migration Flyway version: $preFlywayVersion" -ForegroundColor Yellow
    
    # Capture Flyway output
    $flywayOutput = ""
    $flywayExitCode = 0
    
    try {
        Write-Host "Executing Flyway migrate command..." -ForegroundColor Gray
        $flywayOutput = flyway -configFiles="$DiffScriptLocation\flyway.stg.conf" -user="$SourceUser" -password="$SourcePass" migrate 2>&1
        $flywayExitCode = $LASTEXITCODE
    }
    catch {
        $flywayOutput = $_.Exception.Message
        $flywayExitCode = 1
    }
    
    Write-Host "Flyway output:" -ForegroundColor Yellow
    Write-Host $flywayOutput -ForegroundColor Gray
    Write-Host "Flyway exit code: $flywayExitCode" -ForegroundColor Yellow
    
    # Get the post-migration version
    $postFlywayVersion = Get-FlywayCurrentVersion -connectionString $connectionString
    Write-Host "Post-migration Flyway version: $postFlywayVersion" -ForegroundColor Yellow
    
    # Determine if migration was successful based on exit code
    if ($flywayExitCode -eq 0) {
        Write-Host "Flyway migration completed successfully" -ForegroundColor Green
        
        # Parse successful deployments from output
        $deployedVersions = Get-DeployedVersionsFromFlywayOutput -flywayOutput $flywayOutput
        
        # Check if any actual migration occurred
        $actualMigrationOccurred = $false
        if ($deployedVersions.Count -gt 0) {
            $actualMigrationOccurred = $true
            Write-Host "Migration versions detected from Flyway output: $($deployedVersions -join ', ')" -ForegroundColor Green
        }
        elseif ($preFlywayVersion -ne $postFlywayVersion -and ![string]::IsNullOrEmpty($postFlywayVersion)) {
            $actualMigrationOccurred = $true
            Write-Host "Schema version changed from $preFlywayVersion to $postFlywayVersion" -ForegroundColor Green
            # Add the new version to deployed versions
            if ($postFlywayVersion -notin $deployedVersions) {
                $deployedVersions += $postFlywayVersion
            }
        }
        
        if ($actualMigrationOccurred) {
            Write-Host "Actual migration occurred - updating VersionHistory with success" -ForegroundColor Green
            Update-VersionHistorySuccess -deployedVersions $deployedVersions -connectionString $connectionString
        } else {
            Write-Host "No actual migration occurred - schema was already up to date" -ForegroundColor Green
        }
        
        return $true
    }
    else {
        Write-Host "Flyway migration failed" -ForegroundColor Red
        
        # Parse failed versions from output
        $failedVersions = Get-FailedVersionsFromFlywayOutput -flywayOutput $flywayOutput
        
        # Update VersionHistory with error information
        Update-VersionHistoryFailure -failedVersions $failedVersions -errorMessage $flywayOutput -connectionString $connectionString
        
        return $false
    }
}

# Function to get the latest folder based on a known subfolder path
function Get-LatestFolder {
    param (
        [string]$folderPath
    )
    $migrationFolder = Join-Path -Path $folderPath -ChildPath "ect_AppDb_Analytics_PRODUCTION_master\deploy"
    
    if (Test-Path -Path $migrationFolder -PathType Container) {
        return $migrationFolder
    } else {
        Write-Host "Migration folder not found: $migrationFolder" -ForegroundColor Yellow
        return $null
    }
}

# Track already processed folders
$processedFolders = @()

Write-Host "Starting enhanced Flyway CD process..." -ForegroundColor Cyan
Write-Host "Configuration:" -ForegroundColor Gray
Write-Host "  - Server: $server" -ForegroundColor Gray
Write-Host "  - Database: $database" -ForegroundColor Gray
Write-Host "  - Build Number: $BUILD_NUMBER" -ForegroundColor Gray
Write-Host "  - Root Folder: $rootFolder" -ForegroundColor Gray
Write-Host "  - Version Format: V1.00000 to V999.99999" -ForegroundColor Gray

# Main processing loop
while ($true) {
    $latestFolder = Get-LatestFolder -folderPath $rootFolder
    
    if ($null -eq $latestFolder) {
        Write-Host "No migration folder found. Waiting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        continue
    }
    
    if ($latestFolder -in $processedFolders) {
        Write-Host "All folders processed successfully. Exiting the script." -ForegroundColor Green
        break
    }
    
    $DiffScriptLocation = $latestFolder
    $migrationFiles = Join-Path -Path $rootFolder -ChildPath "ect_AppDb_Analytics_PRODUCTION_master\Migration"
    Write-Host "Processing folder: $migrationFiles" -ForegroundColor Cyan
    
    # Run simplified Flyway migration
    $migrationSuccess = Invoke-FlywayMigration -DiffScriptLocation $DiffScriptLocation -SourceUser $SourceUser -SourcePass $SourcePass -connectionString $connectionString
    
    if ($migrationSuccess) {
        Write-Host "Migration process completed successfully" -ForegroundColor Green
        $processedFolders += $latestFolder
    } else {
        Write-Host "Migration process completed with errors - check VersionHistory table for details" -ForegroundColor Yellow
        Write-Host "Script will exit to allow for manual review and resolution" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "Enhanced Flyway CD process completed" -ForegroundColor Green

