#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$UseExistingKey,
    [string]$SigningDirectory = (Join-Path $env:LOCALAPPDATA 'Loom/signing')
)
# Explicit owner-run bootstrap. Builds never generate distribution keys.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Run this helper in PowerShell 7 on Windows.' }
$repository = '0800x/Loom'
$signingEnvironment = 'loom-release-signing'
$secretNames = @('LOOM_ANDROID_KEYSTORE_BASE64', 'LOOM_ANDROID_STORE_PASSWORD',
                 'LOOM_ANDROID_KEY_PASSWORD', 'LOOM_ANDROID_KEY_ALIAS')
$certificateVariable = 'LOOM_ANDROID_CERT_SHA256'

function Invoke-PrivateTool {
    param([string]$Tool, [string[]]$Arguments, [string]$InputText = '',
          [hashtable]$ChildEnvironment = @{})
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command $Tool -CommandType Application -ErrorAction Stop).Source
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($name in $ChildEnvironment.Keys) { $start.Environment[$name] = $ChildEnvironment[$name] }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "$Tool failed. Verify authentication, environment access and the existing key. Private command output was suppressed."
        }
        return $output
    } finally { $process.Dispose() }
}

$owner = (Invoke-PrivateTool gh @('api', 'user', '--jq', '.login')).Trim()
if ($owner -cne '0800x') { throw 'Authenticate GitHub CLI as 0800x before continuing.' }
[void](Invoke-PrivateTool gh @('api', "repos/$repository/environments/$signingEnvironment"))
$existingSecrets = Invoke-PrivateTool gh @('secret', 'list', '--repo', $repository,
    '--env', $signingEnvironment, '--json', 'name') | ConvertFrom-Json
$existingVariables = Invoke-PrivateTool gh @('variable', 'list', '--repo', $repository,
    '--env', $signingEnvironment, '--json', 'name') | ConvertFrom-Json
if (@($existingSecrets | Where-Object { $_.name -in $secretNames }).Count -gt 0 -or
    @($existingVariables | Where-Object { $_.name -eq $certificateVariable }).Count -gt 0) {
    throw 'Signing configuration already exists. This bootstrap refuses to replace it. If a prior upload was interrupted, retain its key and reconcile the partial Secrets in GitHub before retrying with -UseExistingKey.'
}

$directory = [System.IO.Path]::GetFullPath($SigningDirectory)
$checkout = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\', '/')
if ($directory -eq $checkout -or $directory.StartsWith($checkout + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Keep the private signing directory outside the checkout.'
}
$keystore = Join-Path $directory 'loom-release.p12'
if ((Test-Path -LiteralPath $keystore) -and -not $UseExistingKey) {
    throw 'A key already exists. It will not be overwritten. Use -UseExistingKey to upload that same identity.'
}
if ($UseExistingKey -and -not (Test-Path -LiteralPath $keystore -PathType Leaf)) {
    throw 'Existing key missing. Restore the signing backup; no replacement will be generated.'
}
[void](New-Item -ItemType Directory -Force -Path $directory)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
[void](Invoke-PrivateTool icacls.exe @($directory, '/inheritance:r', '/grant:r', ('*' + $sid + ':(OI)(CI)F')))
$unexpectedRules = @((Get-Acl -LiteralPath $directory).Access | Where-Object {
    $_.AccessControlType -eq 'Allow' -and
    $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $sid
})
if ($unexpectedRules.Count -ne 0) { throw 'Signing directory grants another account access. Choose a new private directory.' }

$securePassword = Read-Host 'Strong keystore password (keep it with your private backup)' -AsSecureString
$pointer = [IntPtr]::Zero
$der = Join-Path $directory 'certificate.der'
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ($password.Length -lt 16 -or $password.Contains([char]13) -or $password.Contains([char]10)) {
        throw 'Use a password of at least 16 characters without line breaks.'
    }
    $child = @{ LOOM_FIRST_KEY_PASSWORD = $password }
    $common = @('-keystore', $keystore, '-storetype', 'PKCS12',
                '-storepass:env', 'LOOM_FIRST_KEY_PASSWORD', '-alias', 'loom')
    if (-not $UseExistingKey) {
        [void](Invoke-PrivateTool keytool (@('-genkeypair', '-keyalg', 'RSA', '-keysize', '4096',
            '-sigalg', 'SHA256withRSA', '-validity', '10000', '-dname', 'CN=Loom,O=Loom',
            '-keypass:env', 'LOOM_FIRST_KEY_PASSWORD') + $common) '' $child)
        Write-Host 'First Loom key created locally. Keep this exact key and password backed up privately.'
    }
    [void](Invoke-PrivateTool keytool (@('-exportcert', '-file', $der) + $common) '' $child)
    $digest = (Get-FileHash -LiteralPath $der -Algorithm SHA256).Hash.ToLowerInvariant()
    $values = @{
        LOOM_ANDROID_KEYSTORE_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore))
        LOOM_ANDROID_STORE_PASSWORD = $password
        LOOM_ANDROID_KEY_PASSWORD = $password
        LOOM_ANDROID_KEY_ALIAS = 'loom'
    }
    foreach ($name in $secretNames) {
        [void](Invoke-PrivateTool gh @('secret', 'set', $name, '--repo', $repository,
            '--env', $signingEnvironment) $values[$name])
    }
    [void](Invoke-PrivateTool gh @('variable', 'set', $certificateVariable, '--repo', $repository,
        '--env', $signingEnvironment) $digest)
    Write-Host "Protected signing configuration uploaded. Certificate SHA256: $digest"
    Write-Host 'Back up loom-release.p12 and its password privately. Then rerun the failed Android job.'
} finally {
    Remove-Item -LiteralPath $der -ErrorAction SilentlyContinue
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    $password = $null
    $values = $null
    $child = $null
    $securePassword.Dispose()
}
