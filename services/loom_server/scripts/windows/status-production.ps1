[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$serverRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$deployRoot = Join-Path $serverRoot "deploy"
$envPath = Join-Path $deployRoot ".env"
$composePath = Join-Path $deployRoot "docker-compose.production.yml"

if (-not (Test-Path $envPath)) {
    throw "Production configuration was not found at $envPath. Run setup-production.ps1 first."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker was not found."
}

function Read-DotEnv {
    param([string]$Path)
    $values = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) { continue }
        $key = $trimmed.Substring(0, $index)
        $value = $trimmed.Substring($index + 1)
        $values[$key] = $value
    }
    return $values
}

$envValues = Read-DotEnv $envPath
$domain = [string]$envValues['LOOM_PUBLIC_DOMAIN']
$baseUrl = [string]$envValues['LOOM_PUBLIC_BASE_URL']
$registration = [string]$envValues['LOOM_REGISTRATION_POLICY']
$federation = [string]$envValues['LOOM_FEDERATION_MODE']

Write-Host "Loom Node production status"
Write-Host "============================="
Write-Host "Public URL:   $baseUrl"
Write-Host "Database:     PostgreSQL (bundle service: postgres)"
Write-Host "Attachments:  MinIO / S3-compatible (bundle service: minio)"
Write-Host "Registration: $registration"
Write-Host "Federation:   $federation"
Write-Host ""

Push-Location $deployRoot
try {
    & docker compose --env-file $envPath -f $composePath ps
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read Docker Compose service status."
    }

    Write-Host ""
    Write-Host "Internal Node readiness:"
    $readyScript = "fetch('http://127.0.0.1:7483/readyz').then(async r=>{console.log(r.status+' '+await r.text());process.exit(r.ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})"
    & docker compose --env-file $envPath -f $composePath exec -T loom-node node -e $readyScript
    $internalReady = $LASTEXITCODE -eq 0
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Public HTTPS/TLS:"
$tlsReady = $false
try {
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri "$baseUrl/readyz"
    if ($response.StatusCode -eq 200) {
        $tlsReady = $true
        Write-Host "  OK - HTTPS endpoint is reachable and the certificate was accepted."
    } else {
        Write-Host "  NOT READY - HTTPS returned HTTP $($response.StatusCode)."
    }
} catch {
    Write-Host "  NOT VERIFIED - $($_.Exception.Message)"
    Write-Host "  Check DNS for $domain, firewall/NAT for ports 80 and 443, and Caddy logs."
}

Write-Host ""
Write-Host "Federation readiness:"
if ($federation -eq "disabled") {
    Write-Host "  Disabled by configuration."
} elseif (-not $tlsReady) {
    Write-Host "  CONFIGURED, NOT PUBLICLY READY - federation requires a working trusted HTTPS endpoint."
    Write-Host "  Cross-node routing is also still experimental/incomplete in this branch."
} else {
    Write-Host "  HTTPS prerequisite is satisfied and federation mode is '$federation'."
    Write-Host "  WARNING: cross-node event routing is still experimental/incomplete in this branch; federation is not production-ready yet."
}

Write-Host ""
if ($internalReady -and $tlsReady) {
    Write-Host "Overall: core production bundle is READY for client connectivity."
} elseif ($internalReady) {
    Write-Host "Overall: Node is healthy internally, but public HTTPS is not verified yet."
} else {
    Write-Host "Overall: Node is NOT READY. Inspect the Compose service logs."
}
