<#
.Synopsis
   Continuous Deployment (CD) using PowerShell for SQL Server.
.DESCRIPTION
   This CD process deploys migration scripts from a staging server to target production database/s.
   Renz Bagasbas
   February 08, 2024
#>

#region Variables
$SourceUser = $Env:USER
$SourcePass = $Env:PASS   
#$SourceUser = [System.Environment]::GetEnvironmentVariable("STG_DB_USER", [System.EnvironmentVariableTarget]::User)
#$SourcePass = [System.Environment]::GetEnvironmentVariable("STG_DB_PASS", [System.EnvironmentVariableTarget]::User)
$server = 'listener.example.com'
$database = 'AppDb_Analytics'
$isWindowsAuthentication = $False
$rootFolder = "C:\Jenkins\workspace"
$databasesTxtPath = "C:\CICD\Migration\AppDb_Analytics\TargetConnection\ConvergePROD.txt"
$SCFilter = "C:\CICD\Migration\SchemaCompare\SCfilter.scflt"
#Declare $diffToolLocation variable for dbForge Studio for SQL Server
$diffToolLocation = "C:\Program Files\Devart\dbForge SQL Tools Professional\dbForge Schema Compare for SQL Server\schemacompare.com"
#endregion

#region SC Variables
#foreach ($line in [System.IO.File]::ReadAllLines($databasesTxtPath)) {
    # Read the connection parameters for the current database from the configuration file
    #$server = ($line -split ",")[0]
    #$database = ($line -split ",")[1]
    #$isWindowsAuthentication = ($line -split ",")[2]
    #$userName = ($line -split ",")[3]
    #$password = ($line -split ",")[4]
    #$srvCleanName = ($server -replace "\\", "")
#endregion

    Write-Host "Server: $server; Database: $database; isWindowsAuthentication: $isWindowsAuthentication"

    # Create a database connection
    if ($isWindowsAuthentication -eq $True) {
        $connectionString = "Server=$server;Database=$database;Integrated Security=True;"
        $TargetConnectionString = "Data Source=$server;Initial Catalog=$database;Integrated Security=True;"
    }
    else {
        $userName = $SourceUser
        $password = $SourcePass
        $connectionString = "Server=$server;Database=$database;User ID=$userName;Password=$password;"
        $TargetConnectionString = "Data Source=$server;Initial Catalog=$database;Integrated Security=False;User ID=$userName;Password=$password;"
    }

    # Test the database connection
    Write-Host "Testing the database connection..."
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    try {
        $connection.Open()
        Write-Host "Connection successful"
    } 
    catch { 
        Write-Host "Connection failed: $($_.Exception.Message)" 
    } 
    finally { 
        $connection.Close() 
    }


    # Log information about checking the database 
    # New-Item -ItemType File -Force -Path $logName

    # Define a function to get the latest folder based on timestamp
    function Get-LatestFolder {
        param(
            [string]$folderPath
        )

        # Get the Migration folder within Connect_PRODUCTION_Deploy_master
        $migrationFolder = Join-Path -Path $folderPath -ChildPath "ect_AppDb_Analytics_PRODUCTION_master\Migration"

        # Check if the Migration folder exists
        if (Test-Path -Path $migrationFolder -PathType Container) {
            return $migrationFolder
        } else {
            Write-Host "Migration folder not found: $migrationFolder" -ForegroundColor Yellow
            return $null
        }
    }

    # Define a function to get the latest .sql file based on timestamp in its name
    function Get-LatestSqlFile {
        param(
            [string]$folderPath
        )

        # Get all .sql files in the specified folder
        $sqlFiles = Get-ChildItem -Path $folderPath -Filter "*.sql"

        # Sort files by timestamp in the file name and select the latest one
        $latestSqlFile = $sqlFiles | Where-Object { $_.Name -notlike "*ROLLBACK*" } | Sort-Object { [datetime]::ParseExact($_.Name.Split('.')[0], "yyyy-MM-dd", $null) } -Descending | Select-Object -First 1

        return $latestSqlFile
    }

    # Initialize an empty array to store the list of processed folders
    $processedFolders = @()

    # Infinite loop to continuously check for new folders
    while ($true) {
        # Get the latest folder based on timestamp
        $latestFolder = Get-LatestFolder -folderPath $rootFolder

        # Check if the latest folder is newly created and not processed
        if ($latestFolder -in $processedFolders) {
            Write-Host "All new folders are already processed. Exiting the script."
            break
        }

        if ($latestFolder) {
            # Process the new folder
            $DiffScriptLocation = "$latestFolder"

            # Get the latest .sql file in the directory
            $latestSqlFile = Get-LatestSqlFile -folderPath $DiffScriptLocation

            # Check if there's any .sql file found
            if ($latestSqlFile) {
                # Construct the full path of the latest .sql file
                $latestSqlFilePath = $latestSqlFile.FullName

                # Execute the latest .sql file
                try {
                    $devartConnection = New-DevartSqlDatabaseConnection -Server $server -Database $database -UserName $SourceUser -Password $SourcePass
                    $result = Invoke-DevartExecuteScript -Connection $devartConnection -Input $latestSqlFilePath
                    if (-not $result) {
                        Write-Host "Execution of $latestSqlFilePath failed." -ForegroundColor Red
                        [System.Environment]::Exit(1)
                    }
                }
                catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    [System.Environment]::Exit(1)
                }
            }
            else {
                Write-Host "No .sql files found in $DiffScriptLocation." -ForegroundColor Yellow
            }

            # Add the processed folder to the list
            $processedFolders += $latestFolder
        }

        # Sleep for a while before checking again (adjust as needed)
        Start-Sleep -Seconds 10
    }

