[CmdletBinding()]
param([switch]$SetupOnly, [switch]$Universal, [switch]$AnalyzeSize, [switch]$OfflinePub)

$ErrorActionPreference = 'Stop'
$appDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'apps/loom'
$propertiesFile = Join-Path $appDirectory 'android/key.properties'
$credentialNames = @('LOOM_ANDROID_KEYSTORE', 'LOOM_ANDROID_STORE_PASSWORD', 'LOOM_ANDROID_KEY_ALIAS', 'LOOM_ANDROID_KEY_PASSWORD')
$configuredNames = @($credentialNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })

if ($configuredNames.Count -gt 0 -and $configuredNames.Count -ne 4) {
    throw 'Partial LOOM_ANDROID signing environment. Set all four variables or clear them to use android/key.properties.'
}

function ConvertTo-PropertyValue([string]$Value) {
    $result = New-Object System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        # Escape every UTF-16 code unit: Java Properties.load(InputStream) uses Latin-1.
        [void]$result.Append(('\u{0:x4}' -f $code))
    }
    return $result.ToString()
}

if ($configuredNames.Count -eq 0 -and -not (Test-Path -LiteralPath $propertiesFile)) {
    $profileDirectory = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($profileDirectory)) { throw 'Cannot locate your user profile.' }
    $signingDirectory = Join-Path $profileDirectory '.loom/android-signing'
    $savedProperties = Join-Path $signingDirectory 'key.properties'
    $keystore = Join-Path $signingDirectory 'loom-release.jks'

    if (Test-Path -LiteralPath $savedProperties) {
        if (-not (Test-Path -LiteralPath $keystore)) { throw 'Saved signing settings exist but the keystore is missing. Restore your signing backup.' }
        Copy-Item -LiteralPath $savedProperties -Destination $propertiesFile -ErrorAction Stop
        Write-Host 'Reused your existing Loom signing key.'
    } else {
        throw 'A production signing key is required for the independent Loom package. Provide key.properties or all four LOOM_ANDROID signing variables. No key will be generated automatically.'
    }
} else {
    Write-Host 'Using existing signing configuration; no key was generated or replaced.'
}

if ($SetupOnly) { return }
& (Join-Path $PSScriptRoot 'build-mls.ps1') -Target Android
Push-Location $appDirectory
try {
    if ($OfflinePub) {
        # Validate the existing locked versions against the cache; never resolve
        # different versions merely because they happen to be available offline.
        & flutter pub get --offline --enforce-lockfile
    } else {
        & flutter pub get
    }
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed with exit code $LASTEXITCODE" }
    if ($OfflinePub) {
        # Flutter's build cache checks strict timestamps as well as its version
        # marker. Pub may retain an unchanged lockfile's checkout timestamp.
        # Mark only successfully validated outputs fresh so the build skips a
        # second online pub get while still regenerating release plugin tooling.
        $pubspecTime = (Get-Item -LiteralPath 'pubspec.yaml').LastWriteTimeUtc
        $validatedTime = [DateTime]::UtcNow
        if ($validatedTime -le $pubspecTime) { $validatedTime = $pubspecTime.AddSeconds(1) }
        foreach ($validatedOutput in @('pubspec.lock', '.dart_tool/package_config.json')) {
            (Get-Item -LiteralPath $validatedOutput -ErrorAction Stop).LastWriteTimeUtc = $validatedTime
        }
        if (-not (Test-Path -LiteralPath '.dart_tool/version' -PathType Leaf)) {
            throw 'Flutter did not write its dependency version marker. Offline build preparation failed.'
        }
    }
    # Keep pub enabled on platform builds: Flutter also uses this step to
    # regenerate native plugin registration for the requested build mode.
    if ($AnalyzeSize) {
        & flutter build apk --release --target-platform android-arm64 --analyze-size
    } elseif ($Universal) {
        & flutter build apk --release
    } else {
        & flutter build apk --release --split-per-abi
    }
    if ($LASTEXITCODE -ne 0) { throw "Android release build failed with exit code $LASTEXITCODE" }
    Get-ChildItem -LiteralPath 'build/app/outputs/flutter-apk' -Filter '*.apk' |
        Select-Object Name, @{Name='MiB'; Expression={ [Math]::Round($_.Length / 1MB, 2) }} |
        Format-Table -AutoSize
} finally {
    Pop-Location
}

