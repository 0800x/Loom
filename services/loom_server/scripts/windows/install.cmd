@echo off
setlocal
cd /d "%~dp0\..\.."

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js was not found. Install Node.js 22.16.0 or newer from https://nodejs.org/
  pause
  exit /b 1
)

node -e "const [a,b]=process.versions.node.split('.').map(Number);process.exit(a>22||(a===22&&b>=16)?0:1)"
if errorlevel 1 (
  echo Loom Node requires Node.js 22.16.0 or newer.
  node --version
  pause
  exit /b 1
)

call npm install --ignore-scripts
if errorlevel 1 (
  echo Dependency installation failed.
  pause
  exit /b 1
)

call npm test
if errorlevel 1 (
  echo Server validation failed.
  pause
  exit /b 1
)

echo Loom Node dependencies are installed and tests passed.
pause
