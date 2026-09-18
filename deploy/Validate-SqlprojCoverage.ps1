<#
.SYNOPSIS
    Flag .sql files the .sqlproj does not reference at all (orphans).

.DESCRIPTION
    SSDT only puts files listed under <Build Include> into the model. A .sql file
    that the project references nowhere -- not in <Build>, and not even excluded
    via <None>/<PostDeploy> -- is invisible to the project: it never compiles, and
    the build fails with SQL71501 the moment a compiled object references it. That
    is what happened with `meta.MetaPMPTrafficDelta`: the whole `meta` folder was
    on disk but absent from the .sqlproj.

    This flags exactly that orphan signature. It does NOT flag files a project
    deliberately excludes with <None>/<PostDeploy>/<PreDeploy> (e.g. deprecated
    views, pre/post-deploy scripts) -- those are referenced, just not built -- so
    it stays quiet on the heavy <None> usage in repos like AppDb_VOICE.

    No regex and no external runtime: the .sqlproj is parsed with PowerShell's
    native [xml]; coverage is pure string/set logic over file paths.

.PARAMETER ProjectDir
    Folder containing the .sqlproj (e.g. AppDb_Analytics, AppDb_Routing, AppDb_Connect, AppDb_VOICE).

.PARAMETER FailOnGap
    If set, exit 1 when an orphan is found (hard gate). Default: advisory -- warn
    and exit 0, so the check never blocks an existing pipeline / deploy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectDir,
    [switch]$FailOnGap
)

$ErrorActionPreference = 'Stop'
# Scripts\ holds SSDT pre/post-deployment scripts -- never <Build> model objects -- so it is excluded like bin/obj.
$excludeTop = @('bin', 'obj', 'Properties', '.vs', 'Scripts')

$proj = Get-ChildItem -Path $ProjectDir -Filter *.sqlproj -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proj) {
    Write-Host "::error::No .sqlproj found in $ProjectDir"
    exit 2
}

# --- Every @Include the project mentions, of ANY item type (Build / None /
#     PostDeploy / PreDeploy / Folder / ...). A file referenced by any of these
#     is known to the project; only files referenced by NOTHING are orphans. ---
[xml]$xml = Get-Content -LiteralPath $proj.FullName
$ns = @{ m = 'http://schemas.microsoft.com/developer/msbuild/2003' }
$includes = [System.Collections.Generic.HashSet[string]]::new()
Select-Xml -Xml $xml -Namespace $ns -XPath '//m:*[@Include]' | ForEach-Object {
    [void]$includes.Add($_.Node.GetAttribute('Include').Replace('\', '/').ToLowerInvariant())
}

# --- A .sql file is covered if its exact path is listed, or its folder's *.sql
#     wildcard is listed. Otherwise it is an orphan. (string/set logic, no regex) ---
$projDirFull = (Resolve-Path -LiteralPath $ProjectDir).Path
$orphansByFolder = @{}
foreach ($file in (Get-ChildItem -Path $ProjectDir -Recurse -Filter *.sql -File -ErrorAction SilentlyContinue)) {
    $rel = $file.FullName.Substring($projDirFull.Length).TrimStart('\', '/').Replace('\', '/')
    if ($excludeTop -contains $rel.Split('/')[0]) { continue }
    $folder = ($rel -split '/' | Select-Object -SkipLast 1) -join '/'
    $wildcard = "$folder/*.sql".ToLowerInvariant()
    if ($includes.Contains($rel.ToLowerInvariant()) -or $includes.Contains($wildcard)) { continue }
    if (-not $orphansByFolder.ContainsKey($folder)) {
        $orphansByFolder[$folder] = [pscustomobject]@{ Orphans = [System.Collections.Generic.List[string]]::new(); Total = 0 }
    }
    $orphansByFolder[$folder].Orphans.Add($rel)
}
# Count total .sql per orphan-bearing folder, to decide wildcard-vs-per-file advice.
foreach ($folder in @($orphansByFolder.Keys)) {
    $orphansByFolder[$folder].Total = (Get-ChildItem -Path (Join-Path $projDirFull $folder) -Filter *.sql -File -ErrorAction SilentlyContinue).Count
}

if ($orphansByFolder.Count -eq 0) {
    Write-Host "OK: every .sql file is referenced by $($proj.Name) (built or explicitly excluded)."
    exit 0
}

$orphanCount = ($orphansByFolder.Values | ForEach-Object { $_.Orphans.Count } | Measure-Object -Sum).Sum
$level = if ($FailOnGap) { 'error' } else { 'warning' }
Write-Host "::${level}::$orphanCount .sql file(s) are not referenced by $($proj.Name) at all."
Write-Host "They will not compile, and cause SQL71501 the moment a compiled object"
Write-Host "references them. Register them in the .sqlproj (a <Build Include> wildcard"
Write-Host "for the folder, or per file). Orphans:"
Write-Host ""
foreach ($folder in ($orphansByFolder.Keys | Sort-Object)) {
    $info = $orphansByFolder[$folder]
    if ($info.Orphans.Count -eq $info.Total) {
        Write-Host ('    <Build Include="{0}\*.sql" />   ({1} file(s))' -f $folder.Replace('/', '\'), $info.Total)
    }
    else {
        foreach ($f in ($info.Orphans | Sort-Object)) {
            Write-Host ('    <Build Include="{0}" />' -f $f.Replace('/', '\'))
        }
    }
}
if ($FailOnGap) { exit 1 } else { exit 0 }
