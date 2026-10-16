param(
  [ValidateSet('windows','android')]
  [string]$Target = 'windows',
  [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ArtifactDir = Join-Path $RepoRoot 'artifacts\acceptance'
$BuildRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("loom-acceptance-" + [guid]::NewGuid().ToString('N'))
$WorktreeAdded = $false
$Sha = ''

Set-Location $RepoRoot

Write-Host "Preparing clean acceptance worktree from origin/$Branch..."
git fetch origin $Branch
if ($LASTEXITCODE -ne 0) { throw 'git fetch failed' }

git worktree add --detach $BuildRoot "origin/$Branch"
if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }
$WorktreeAdded = $true

try {
  $BuildRepoRoot = (Resolve-Path $BuildRoot).Path
  $AppDir = Join-Path $BuildRepoRoot 'apps\loom'
  $CanonicalBuilder = Join-Path $BuildRepoRoot 'scripts\windows\build-clients.ps1'

  $Dirty = @(git -C $BuildRepoRoot status --porcelain)
  if ($Dirty.Count -gt 0) {
    throw 'Fresh acceptance worktree is unexpectedly dirty; refusing to build.'
  }

  $AppFile = Join-Path $AppDir 'lib\app\loom_app.dart'
  $AppText = Get-Content -Raw $AppFile
  if ($AppText -notmatch "'/messenger'\s*:\s*\(_\)\s*=>\s*const\s+MessengerShell\(\)") {
    throw 'The selected branch does not route /messenger to the live MessengerShell.'
  }

  $VersionLine = Get-Content -LiteralPath (Join-Path $AppDir 'pubspec.yaml') |
    Where-Object { $_ -match '^\s*version:\s*' } | Select-Object -First 1
  if (-not $VersionLine -or $VersionLine -notmatch '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') {
    throw 'Could not read the client version and build number from pubspec.yaml.'
  }
  $ClientVersion = $Matches[1]
  $ClientBuildNumber = $Matches[2]

  if (-not (Test-Path $CanonicalBuilder)) {
    throw 'Canonical Windows client builder is missing.'
  }

  $Sha = (git -C $BuildRepoRoot rev-parse --short=12 HEAD).Trim()
  New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

  Write-Host "Running canonical client builder for $Target from clean origin/$Branch..."
  & $CanonicalBuilder -Target $Target -NoOpenArtifacts
  if ($LASTEXITCODE -ne 0) { throw 'Canonical client build failed' }

  $EngineeringDir = Join-Path $AppDir 'build\engineering-artifacts'
  if ($Target -eq 'android') {
    $SourceArtifact = Join-Path $EngineeringDir "loom-android-release-engineering-$ClientVersion.apk"
    $DestinationArtifact = Join-Path $ArtifactDir "loom-android-$ClientVersion-build$ClientBuildNumber-$Sha.apk"
  } else {
    $SourceArtifact = Join-Path $EngineeringDir "loom-windows-x64-$ClientVersion.zip"
    $DestinationArtifact = Join-Path $ArtifactDir "loom-windows-x64-$ClientVersion-build$ClientBuildNumber-$Sha.zip"
  }

  if (-not (Test-Path $SourceArtifact)) {
    throw "Canonical builder completed but expected artifact was not found: $SourceArtifact"
  }
  Copy-Item $SourceArtifact $DestinationArtifact -Force
  Write-Host "Acceptance artifact: $DestinationArtifact"
} finally {
  if ($WorktreeAdded) {
    git -C $RepoRoot worktree remove --force $BuildRoot 2>$null
  }
  if (Test-Path $BuildRoot) {
    Remove-Item -Recurse -Force $BuildRoot -ErrorAction SilentlyContinue
  }
}

Write-Host "Acceptance client built from clean origin/$Branch commit $Sha"
Write-Host "Artifact directory: $ArtifactDir"
