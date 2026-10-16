@echo off
setlocal
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-android-toolchain.ps1"
set "LOOM_EXIT=%ERRORLEVEL%"
if not "%LOOM_EXIT%"=="0" echo Android toolchain installation failed. Read the message above.
pause
exit /b %LOOM_EXIT%
