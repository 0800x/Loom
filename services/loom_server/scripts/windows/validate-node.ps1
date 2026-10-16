[CmdletBinding()]
param(
    [switch]$SkipDependencyInstall,
    [switch]$SkipTui
)

$ErrorActionPreference = "Stop"
$serverRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$repoRoot = (Resolve-Path (Join-Path $serverRoot "..\..")).Path
$tuiRoot = Join-Path $repoRoot "tools\loom_node_manager"

function Assert-Command {
    param([string]$Name, [string]$Message)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw $Message
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    Write-Host ""
    Write-Host "== $Label =="
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

Assert-Command "node" "Node.js 22.16+ is required to validate the Loom Node server."
Assert-Command "npm" "npm is required to validate the Loom Node server."

$nodeVersionText = (& node --version).Trim().TrimStart('v')
try {
    $nodeVersion = [version]$nodeVersionText
} catch {
    throw "Could not parse Node.js version '$nodeVersionText'."
}
if ($nodeVersion -lt [version]'22.16.0') {
    throw "Node.js 22.16+ is required; found $nodeVersionText."
}

Push-Location $serverRoot
try {
    if (-not $SkipDependencyInstall) {
        Invoke-Checked "Install Node server dependencies" { npm install --ignore-scripts --no-audit --no-fund }
    }
    Invoke-Checked "Node server tests" { npm test }
} finally {
    Pop-Location
}

if (-not $SkipTui) {
    Assert-Command "go" "Go 1.25+ is required to validate the cross-platform Node Manager TUI. Re-run with -SkipTui only if you intentionally want to validate the server alone."
    Push-Location $tuiRoot
    try {
        Invoke-Checked "Download TUI Go modules" { go mod download }
        Invoke-Checked "TUI tests" { go test ./... }
        Invoke-Checked "TUI vet" { go vet ./... }
        $output = Join-Path $env:TEMP "loom-node-manager-validation.exe"
        Invoke-Checked "TUI Windows build" { go build -buildvcs=false -trimpath -o $output . }
        Remove-Item -Force $output -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "Loom Node validation passed."
