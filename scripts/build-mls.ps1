[CmdletBinding()]
param(
    [ValidateSet('Windows', 'Android')][string]$Target = 'Windows',
    [string]$NdkPath = $env:ANDROID_NDK_HOME
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $root 'native/loom_mls/Cargo.toml'
$cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargoCommand) { throw 'Install Rust with rustup, then restart PowerShell.' }
$rustupCommand = Get-Command rustup -ErrorAction Stop
if ($Target -eq 'Windows') {
    & $cargoCommand.Source build --manifest-path $manifest --release --locked
    if ($LASTEXITCODE -ne 0) { throw 'Native MLS build failed.' }
    $library = Join-Path $root 'native/loom_mls/target/release/loom_mls.dll'
    if (-not (Test-Path -LiteralPath $library)) { throw 'Built MLS DLL was not found.' }
    Write-Host "Native library: $library"
    Write-Host 'The DLL must be bundled beside the application executable by the client packaging integration.'
    return
}
if ([string]::IsNullOrWhiteSpace($NdkPath)) {
    $sdkPath = $env:ANDROID_HOME
    if ([string]::IsNullOrWhiteSpace($sdkPath)) { $sdkPath = $env:ANDROID_SDK_ROOT }
    if ([string]::IsNullOrWhiteSpace($sdkPath) -and $env:LOCALAPPDATA) { $sdkPath = Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
    if ($sdkPath) {
        $ndkRoot = Join-Path $sdkPath 'ndk'
        if (Test-Path -LiteralPath $ndkRoot) {
            $installed = Get-ChildItem -LiteralPath $ndkRoot -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
            if ($installed) { $NdkPath = $installed.FullName }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($NdkPath) -or -not (Test-Path -LiteralPath $NdkPath)) {
    throw 'Pass -NdkPath or set ANDROID_NDK_HOME to the installed Android NDK directory.'
}
& $cargoCommand.Source ndk --version
if ($LASTEXITCODE -ne 0) { throw 'Install the cross-build tool: cargo install cargo-ndk --locked' }
& $rustupCommand.Source target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
if ($LASTEXITCODE -ne 0) { throw 'Rust Android target installation failed.' }
$previousNdk = $env:ANDROID_NDK_HOME
$previousFlags = $env:RUSTFLAGS
Push-Location (Join-Path $root 'native/loom_mls')
try {
    $env:ANDROID_NDK_HOME = $NdkPath
    $env:RUSTFLAGS = "$previousFlags -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
    $destination = Join-Path $root 'apps/loom/android/app/src/main/jniLibs'
    & $cargoCommand.Source ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -P 24 -o $destination build --manifest-path $manifest --release --locked
    if ($LASTEXITCODE -ne 0) { throw 'Native MLS Android build failed.' }
    Write-Host "Android libraries: $destination"
} finally {
    Pop-Location
    $env:ANDROID_NDK_HOME = $previousNdk
    $env:RUSTFLAGS = $previousFlags
}
