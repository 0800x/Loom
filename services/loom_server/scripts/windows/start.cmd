@echo off
setlocal
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
set "LOOM_EXIT=%ERRORLEVEL%"
if not "%LOOM_EXIT%"=="0" echo Loom Node did not start. Read the message above.
pause
exit /b %LOOM_EXIT%
