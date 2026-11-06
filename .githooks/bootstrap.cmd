@echo off
rem bootstrap.cmd: bootstrap.sh for cmd.exe and PowerShell. Turns on this repository's git hooks
rem for this clone (core.hooksPath=.githooks); running it again changes nothing.
rem   exit 0  the hooks are on (now, or already)
rem   exit 1  not a git work tree, or core.hooksPath already names another folder (a hook
rem           framework); the message gives the command that switches it to .githooks
setlocal

git rev-parse --show-toplevel >nul 2>nul
if errorlevel 1 goto not_a_repo

set "CURRENT="
for /f "usebackq delims=" %%H in (`git config --local --get core.hooksPath 2^>nul`) do set "CURRENT=%%H"
if not defined CURRENT goto enable
if "%CURRENT%"==".githooks" goto already
if "%CURRENT%"==".githooks/" goto already
if "%CURRENT%"=="./.githooks" goto already
if "%CURRENT%"=="./.githooks/" goto already
>&2 echo [hooks] core.hooksPath is %CURRENT%, so nothing changed. To use this repository's hooks instead:
>&2 echo [hooks]   git config --local --replace-all core.hooksPath .githooks
exit /b 1

:already
echo [hooks] Already on (core.hooksPath=%CURRENT%).
exit /b 0

:enable
git config --local core.hooksPath .githooks
if errorlevel 1 exit /b 1
echo [hooks] On for this clone (core.hooksPath=.githooks): the doc gate, nitsql and the review reminders run at commit and push.
exit /b 0

:not_a_repo
>&2 echo [hooks] Not inside a git work tree.
exit /b 1
