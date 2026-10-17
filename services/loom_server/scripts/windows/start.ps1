$ErrorActionPreference = "Stop"
$serverRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$configPath = Join-Path $serverRoot "data\loom-node.json"

if (-not (Test-Path (Join-Path $serverRoot "node_modules"))) {
    Write-Host "Dependencies are missing. Run scripts\windows\install.cmd first."
    exit 1
}

$port = 7483
if (Test-Path $configPath) {
    try {
        $configText = [System.IO.File]::ReadAllText($configPath).TrimStart([char]0xFEFF)
        $config = $configText | ConvertFrom-Json
        if ($null -ne $config.listenPort) {
            $port = [int]$config.listenPort
        }
    } catch {
        Write-Host "The Node configuration could not be read: $($_.Exception.Message)"
        Write-Host "Configuration: $configPath"
        exit 1
    }
}

$listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -ne $listener) {
    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $ownerName = if ($null -eq $owner) { "unknown" } else { $owner.ProcessName }
    $healthy = $false
    try {
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://127.0.0.1:$port/healthz"
        $healthy = $response.StatusCode -eq 200 -and $response.Content.Trim() -eq "ok"
    } catch {
        $healthy = $false
    }

    if ($healthy) {
        Write-Host "Loom Node is already running."
        Write-Host "  Address: http://127.0.0.1:$port"
        Write-Host "  Process: $ownerName (PID $($listener.OwningProcess))"
        Write-Host "  Health:  OK"
        exit 0
    }

    Write-Host "Port $port is already used by another process."
    Write-Host "  Process: $ownerName (PID $($listener.OwningProcess))"
    Write-Host "Stop that process or choose another listenPort in data\loom-node.json."
    exit 1
}

Write-Host "Starting Loom Node on the configured address..."
Push-Location $serverRoot
try {
    & npm start
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
