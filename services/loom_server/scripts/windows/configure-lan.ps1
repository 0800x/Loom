$ErrorActionPreference = "Stop"
$serverRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$configPath = Join-Path $serverRoot "data\loom-node.json"

if (-not (Test-Path $configPath)) {
    Write-Host "Configuration was not found. Run start.cmd once, stop it with Ctrl+C, then run this tool."
    exit 1
}

Write-Host "IPv4 addresses detected on this computer:"
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.AddressState -eq "Preferred" } |
    Select-Object InterfaceAlias, IPAddress |
    Format-Table -AutoSize

$lanIp = (Read-Host "Enter this computer's private IPv4 address, for example 192.168.1.25").Trim()
$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($lanIp, [ref]$parsedIp)) {
    Write-Host "That is not a valid IP address."
    exit 1
}

$bytes = $parsedIp.GetAddressBytes()
$private = $bytes.Length -eq 4 -and (
    $bytes[0] -eq 10 -or
    ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
    ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
)
if (-not $private) {
    Write-Host "Use a private LAN address from the list above. Public addresses are not allowed in Easy Mode."
    exit 1
}

$config = Get-Content -Raw $configPath | ConvertFrom-Json
$port = [int]$config.listenPort
$config.listenHost = "0.0.0.0"
$config.publicDomain = "${lanIp}:$port"
$config.publicBaseUrl = "http://${lanIp}:$port"

$allowRegistration = (Read-Host "Enable open registration for isolated testing? Type YES to enable").Trim()
if ($allowRegistration -ceq "YES") {
    $config.registrationPolicy = "open"
}

$json = $config | ConvertTo-Json -Depth 10
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($configPath, "$json$([Environment]::NewLine)", $utf8WithoutBom)

Write-Host "Configuration updated:"
Write-Host "  Listen: 0.0.0.0:$port"
Write-Host "  Client address: ${lanIp}:$port"
Write-Host "Restart start.cmd and allow Node.js through Windows Firewall on Private networks."
