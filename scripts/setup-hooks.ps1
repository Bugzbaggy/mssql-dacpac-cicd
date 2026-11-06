# setup-hooks.ps1: turn on this repository's git hooks for this clone (core.hooksPath=.githooks),
# from PowerShell on any platform. .githooks/bootstrap.sh and bootstrap.cmd do the same from bash and
# cmd.exe. Running it again changes nothing; a clone whose core.hooksPath names another folder (a
# hook framework) is left alone, exit 1, with the command that switches it.
$root = Split-Path -Parent $PSScriptRoot
$current = git -C $root config --local --get core.hooksPath
if ($current -in '.githooks', '.githooks/', './.githooks', './.githooks/') {
    Write-Host "[hooks] Already on (core.hooksPath=$current)."
    exit 0
}
if ($current) {
    Write-Host "[hooks] core.hooksPath is $current, so nothing changed. To use this repository's hooks instead:"
    Write-Host '[hooks]   git config --local --replace-all core.hooksPath .githooks'
    exit 1
}
git -C $root config --local core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host '[hooks] On for this clone (core.hooksPath=.githooks): the doc gate, nitsql and the review reminders run at commit and push.'
