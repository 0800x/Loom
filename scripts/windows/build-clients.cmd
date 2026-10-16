@echo off
setlocal
cd /d "%~dp0"
echo Loom local engineering build
echo.
echo 1. Windows client only
echo 2. Android APKs only
echo 3. Windows and Android
set /p LOOM_BUILD_CHOICE=Choose 1, 2, or 3: 

if "%LOOM_BUILD_CHOICE%"=="1" set LOOM_BUILD_TARGET=windows
if "%LOOM_BUILD_CHOICE%"=="2" set LOOM_BUILD_TARGET=android
if "%LOOM_BUILD_CHOICE%"=="3" set LOOM_BUILD_TARGET=both

if not defined LOOM_BUILD_TARGET (
  echo Invalid choice.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-clients.ps1" -Target "%LOOM_BUILD_TARGET%"
if errorlevel 1 (
  echo.
  echo Build failed. Read the error above and run flutter doctor -v for missing prerequisites.
) else (
  echo.
  echo Build completed successfully.
)
pause
