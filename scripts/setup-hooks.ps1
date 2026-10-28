# Point this clone at the versioned hooks in .githooks/.
# Run once after cloning:  .\scripts\setup-hooks.ps1
git config core.hooksPath .githooks
Write-Host "core.hooksPath set to .githooks"
