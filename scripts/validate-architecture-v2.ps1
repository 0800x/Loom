$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root

function Require-Tool([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "[loom-v2] required tool not found: $Name"
  }
}

function Run-Step([scriptblock]$Command, [string]$Label) {
  Write-Host ""
  Write-Host "+ $Label"
  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "[loom-v2] command failed ($LASTEXITCODE): $Label"
  }
}

@('flutter', 'dart', 'cargo', 'node', 'npm') | ForEach-Object { Require-Tool $_ }

# Resolve every nested Dart/Flutter package first. VS Code/Dart Analyzer treats
# nested packages as package roots and each one needs its own .dart_tool package
# config; resolving only apps/loom leaves thousands of misleading URI errors.
& (Join-Path $Root 'scripts/bootstrap-dart-workspace.ps1')

$DartPackages = @(
  'packages/loom_identity',
  'packages/loom_sessions',
  'packages/loom_protocol',
  'packages/loom_storage',
  'packages/loom_dtn',
  'packages/loom_messaging',
  'packages/loom_transport',
  'packages/loom_session_vodozemac_poc'
)

foreach ($Package in $DartPackages) {
  Write-Host ""
  Write-Host "=== $Package ==="
  Push-Location $Package
  try {
    Run-Step { dart format --output=none --set-exit-if-changed lib test } 'dart format'
    Run-Step { dart analyze } 'dart analyze'
    Run-Step { dart test } 'dart test'
  } finally {
    Pop-Location
  }
}

Write-Host ""
Write-Host '=== Flutter app ==='
Push-Location 'apps/loom'
try {
  Run-Step { dart format --output=none --set-exit-if-changed lib test } 'dart format app'
  Run-Step { flutter analyze } 'flutter analyze'
  Run-Step { flutter test } 'flutter test'
} finally {
  Pop-Location
}

Write-Host ""
Write-Host '=== Rust session provider candidate ==='
Push-Location 'native/loom_vodozemac_poc'
try {
  Run-Step { cargo fmt --all -- --check } 'cargo fmt --check'
  Run-Step { cargo clippy --all-targets --all-features -- -D warnings } 'cargo clippy'
  Run-Step { cargo test --all-targets } 'cargo test'
  Run-Step { cargo build --release } 'cargo build --release'
} finally {
  Pop-Location
}

if ($env:LOOM_VALIDATE_SKIP_NODE -ne '1') {
  Write-Host ""
  Write-Host '=== Delivery Service v2 ==='
  Push-Location 'services/loom_server'
  try {
    Run-Step { npm install --ignore-scripts } 'npm install --ignore-scripts'
    Run-Step { node --experimental-strip-types --test test/v2_delivery_*.test.ts } 'Delivery v2 tests'
  } finally {
    Pop-Location
  }
}

if ($env:LOOM_VALIDATE_SKIP_ANDROID -ne '1') {
  Write-Host ""
  Write-Host '=== Android native bearers / host ==='
  Push-Location 'apps/loom/android'
  try {
    Run-Step { .\gradlew.bat :app:assembleDebug } 'Android assembleDebug'
  } finally {
    Pop-Location
  }
}

Write-Host ""
Write-Host '[loom-v2] local Architecture v2 validation completed successfully'
