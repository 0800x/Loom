@echo off
setlocal
set "LOOM_NODE_HOME=%~dp0\..\.."
set "COMPOSE_PROFILES=caddy"
set "MANAGER=%LOOM_NODE_HOME%\bin\loom-node-manager.exe"

if not exist "%MANAGER%" (
  echo Loom Node Manager binary was not found:
  echo   %MANAGER%
  echo Use a packaged Windows Node bundle or build tools\loom_node_manager first.
  exit /b 1
)

"%MANAGER%" --home "%LOOM_NODE_HOME%"
exit /b %ERRORLEVEL%
