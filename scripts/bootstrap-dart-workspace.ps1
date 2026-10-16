param(
  [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $Root

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw '[loom-bootstrap] required tool not found: flutter'
}

function Get-LoomRelativePath([string]$BasePath, [string]$ChildPath) {
  $NormalizedBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
  $NormalizedChild = [System.IO.Path]::GetFullPath($ChildPath)
  $Prefix = $NormalizedBase + [System.IO.Path]::DirectorySeparatorChar
  if ($NormalizedChild.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $NormalizedChild.Substring($Prefix.Length)
  }
  return $NormalizedChild
}

$SearchRoots = @(
  (Join-Path $Root 'packages'),
  (Join-Path $Root 'apps')
) | Where-Object { Test-Path $_ }

$Pubspecs = @(
  foreach ($SearchRoot in $SearchRoots) {
    Get-ChildItem -Path $SearchRoot -Filter pubspec.yaml -File -Recurse |
      Where-Object {
        $_.FullName -notmatch '[\\/](?:build|\.dart_tool|node_modules)[\\/]'
      }
  }
) | Sort-Object FullName -Unique

if ($Pubspecs.Count -eq 0) {
  throw '[loom-bootstrap] no Dart/Flutter pubspec.yaml files found'
}

Write-Host "[loom-bootstrap] resolving $($Pubspecs.Count) Dart/Flutter packages"

foreach ($Pubspec in $Pubspecs) {
  $PackageDir = $Pubspec.Directory.FullName
  $Relative = Get-LoomRelativePath $Root $PackageDir
  Write-Host ""
  Write-Host "=== $Relative ==="

  if ($Clean) {
    $DartTool = Join-Path $PackageDir '.dart_tool'
    if (Test-Path $DartTool) {
      Remove-Item -Recurse -Force $DartTool
    }
  }

  Push-Location $PackageDir
  try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) {
      throw "[loom-bootstrap] flutter pub get failed ($LASTEXITCODE): $Relative"
    }
  } finally {
    Pop-Location
  }
}

Write-Host ""
Write-Host '[loom-bootstrap] package graph resolved for the whole monorepo'
Write-Host '[loom-bootstrap] restart the Dart Analysis Server / reload VS Code if stale diagnostics remain'
