[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [string]$OperatorName = "Loom Node",

    [string]$NetworkJurisdiction = "Unspecified",

    [ValidateSet("open", "approval", "closed")]
    [string]$RegistrationPolicy = "approval",

    [ValidateSet("disabled", "trusted", "open", "local", "hybrid")]
    [string]$FederationMode = "disabled",

    [switch]$Force,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
$serverRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$deployRoot = Join-Path $serverRoot "deploy"
$envPath = Join-Path $deployRoot ".env"
$composePath = Join-Path $deployRoot "docker-compose.production.yml"

function New-RandomSecret {
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    } finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($buffer).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Assert-Command {
    param([string]$Name, [string]$Message)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw $Message
    }
}

function Assert-SingleLineValue {
    param([string]$Name, [string]$Value)
    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "$Name must be a single-line value."
    }
}

$Domain = $Domain.Trim().ToLowerInvariant()
if ($Domain -match '^[a-z][a-z0-9+.-]*://' -or $Domain.Contains('/') -or $Domain.Contains(' ')) {
    throw "-Domain must be a hostname only, for example chat.example.com"
}
if ($Domain -notmatch '^[a-z0-9.-]+(?::\d+)?$' -or $Domain.Contains('..')) {
    throw "Invalid public domain: $Domain"
}
Assert-SingleLineValue "OperatorName" $OperatorName
Assert-SingleLineValue "NetworkJurisdiction" $NetworkJurisdiction

Assert-Command "docker" "Docker Desktop/Engine is required for the production bundle. Install Docker, then run this command again."

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker is installed but the Docker engine is not running. Start Docker Desktop/Engine first."
}

& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose v2 is required. Update Docker Desktop/Engine so 'docker compose' is available."
}

if ((Test-Path $envPath) -and -not $Force) {
    throw "Production configuration already exists at $envPath. Use -Force only if you intentionally want to replace its secrets and configuration."
}

$postgresPassword = New-RandomSecret 36
$adminToken = New-RandomSecret 48
$s3AccessKey = "loom_$(New-RandomSecret 12)"
$s3SecretKey = New-RandomSecret 36

$lines = @(
    "LOOM_MODE=production",
    "LOOM_HOST=0.0.0.0",
    "LOOM_PORT=7483",
    "LOOM_HOST_PORT=7483",
    "LOOM_PROXY_MODE=caddy",
    "LOOM_PUBLIC_DOMAIN=$Domain",
    "LOOM_PUBLIC_BASE_URL=https://$Domain",
    "LOOM_OPERATOR_NAME=$OperatorName",
    "LOOM_NETWORK_JURISDICTION=$NetworkJurisdiction",
    "LOOM_REGISTRATION_POLICY=$RegistrationPolicy",
    "LOOM_FEDERATION_MODE=$FederationMode",
    "LOOM_ADMIN_TOKEN=$adminToken",
    "POSTGRES_PASSWORD=$postgresPassword",
    "LOOM_DATABASE_URL=postgres://loom:$postgresPassword@postgres:5432/loom",
    "LOOM_S3_ENDPOINT=http://minio:9000",
    "LOOM_S3_REGION=us-east-1",
    "LOOM_S3_BUCKET=loom-attachments",
    "LOOM_S3_ACCESS_KEY_ID=$s3AccessKey",
    "LOOM_S3_SECRET_ACCESS_KEY=$s3SecretKey",
    "LOOM_S3_FORCE_PATH_STYLE=true"
)

$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($envPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $utf8WithoutBom)

Write-Host "Loom production configuration created."
Write-Host "  Domain:       $Domain"
Write-Host "  Public URL:   https://$Domain"
Write-Host "  Registration: $RegistrationPolicy"
Write-Host "  Federation:   $FederationMode"
Write-Host "  Database:     PostgreSQL (bundled)"
Write-Host "  Attachments:  MinIO / S3-compatible (bundled)"
Write-Host "  TLS:          Caddy automatic HTTPS (bundled)"
Write-Host "  Secrets:      stored in deploy\.env; keep this file private"

if ($RegistrationPolicy -eq "approval") {
    Write-Host "  Approval:     enabled; review pending requests in Node Manager > Registration"
} elseif ($RegistrationPolicy -eq "closed") {
    Write-Warning "Registration is closed. Existing accounts can use the Node, but new accounts cannot register."
} else {
    Write-Warning "Open registration is enabled. Do not expose this pre-alpha policy publicly unless that is intentional."
}

Push-Location $deployRoot
try {
    & docker compose --env-file $envPath -f $composePath --profile caddy config --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose configuration validation failed."
    }

    if (-not $NoStart) {
        Write-Host ""
        Write-Host "Building and starting the production bundle..."
        & docker compose --env-file $envPath -f $composePath --profile caddy up -d --build
        if ($LASTEXITCODE -ne 0) {
            throw "The production bundle failed to start."
        }
        Write-Host ""
        & docker compose --env-file $envPath -f $composePath --profile caddy ps
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Next requirements for public HTTPS:"
Write-Host "  1. Point DNS for $Domain to this server's public IP."
Write-Host "  2. Allow inbound TCP 80 and TCP/UDP 443 through the host/network firewall."
Write-Host "  3. Run scripts\windows\status-production.ps1 to verify TLS and Node readiness."
if ($FederationMode -ne "disabled") {
    Write-Host ""
    Write-Warning "Federation is configured as '$FederationMode', but cross-node event routing is still experimental/incomplete in this branch. Do not treat federation as production-ready yet."
}
