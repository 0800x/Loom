@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0status-production.ps1" %*
exit /b %ERRORLEVEL%
