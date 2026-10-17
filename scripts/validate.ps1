$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

python scripts/repository_audit.py
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
node scripts/chaos_node.mjs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

foreach ($cmd in @("flutter", "dart", "node", "npm")) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Write-Error "$cmd is not installed or not on PATH"
    exit 127
  }
}

flutter doctor -v
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Push-Location "$Root/services/loom_server"
npm install --ignore-scripts
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
npm test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Pop-Location

$DartPackages = @("packages/loom_models", "packages/loom_protocol", "packages/loom_federation", "packages/loom_storage", "packages/loom_transport")
foreach ($dir in $DartPackages) {
  Push-Location "$Root/$dir"
  dart pub get; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dart format --output=none --set-exit-if-changed .; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dart analyze; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dart test; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Pop-Location
}

$FlutterProjects = @("packages/loom_crypto_bridge", "packages/loom_design", "packages/loom_calls", "apps/loom", "apps/loom_node_ui")
foreach ($dir in $FlutterProjects) {
  Push-Location "$Root/$dir"
  flutter pub get; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dart format --output=none --set-exit-if-changed .; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  flutter analyze; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  flutter test; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Pop-Location
}
