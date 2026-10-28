@echo off
REM Auto-enrol this clone into the .githooks/ pre-commit hook (Windows cmd.exe).
REM Idempotent — safe to run any number of times.
REM CI workflow `nitsql.yml` is the authoritative gate; this is local
REM fast-feedback only.

setlocal

git rev-parse --show-toplevel >nul 2>&1
if errorlevel 1 (
    echo Error: not inside a git repository.
    exit /b 1
)

for /f "delims=" %%R in ('git rev-parse --show-toplevel') do set "REPO_ROOT=%%R"
pushd "%REPO_ROOT%" >nul

for /f "delims=" %%E in ('git config --local --get core.hooksPath 2^>nul') do set "EXISTING=%%E"

if "%EXISTING%"==".githooks" (
    echo [nitsql] Already enrolled ^(core.hooksPath=.githooks^).
    popd >nul
    exit /b 0
)

if defined EXISTING (
    echo [nitsql] Refusing to overwrite existing core.hooksPath: %EXISTING%
    echo   To force, run:  git config --local --replace-all core.hooksPath .githooks
    popd >nul
    exit /b 1
)

git config --local core.hooksPath .githooks
echo [nitsql] Local pre-commit hook enabled ^(core.hooksPath=.githooks^).
echo   Tip: CI runs the same checks regardless — this just gives you faster feedback.

popd >nul
endlocal
