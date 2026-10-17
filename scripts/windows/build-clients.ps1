param(
    [ValidateSet("windows", "android", "both")]
    [string]$Target = "both",
    [switch]$NoOpenArtifacts,
    [switch]$UniversalAndroid
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$clientDirectory = Join-Path $root "apps\loom"
$protocolDirectory = Join-Path $root "packages\loom_protocol"
$cryptoDirectory = Join-Path $root "packages\loom_crypto_bridge"
$outputDirectory = Join-Path $clientDirectory "build\engineering-artifacts"
$pubspecPath = Join-Path $clientDirectory "pubspec.yaml"

$pubspecVersionLine = Get-Content -LiteralPath $pubspecPath |
    Where-Object { $_ -match '^\s*version:\s*' } |
    Select-Object -First 1
if (-not $pubspecVersionLine -or $pubspecVersionLine -notmatch '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?\s*$') {
    throw "Could not read a semantic Flutter version from $pubspecPath."
}
$clientVersion = $Matches[1]
$clientBuildNumber = if ($Matches[2]) { $Matches[2] } else { "0" }
$windowsVersionInfo = "$clientVersion.$clientBuildNumber"

function Require-Command([string]$Name, [string]$InstallMessage) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found. $InstallMessage"
    }
}

function Resolve-InnoCompilerCandidate([string]$Path) {
    if (-not $Path) { return $null }

    $normalized = $Path.Trim().Trim('"')
    if (Test-Path $normalized -PathType Leaf) {
        return (Resolve-Path $normalized).Path
    }
    if (Test-Path $normalized -PathType Container) {
        $nested = Join-Path $normalized "ISCC.exe"
        if (Test-Path $nested -PathType Leaf) {
            return (Resolve-Path $nested).Path
        }
    }
    return $null
}

function Find-InnoCompiler {
    $command = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $configured = Resolve-InnoCompilerCandidate $env:INNO_SETUP_PATH
    if ($configured) { return $configured }

    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Inno Setup 6\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        $resolved = Resolve-InnoCompilerCandidate $candidate
        if ($resolved) { return $resolved }
    }

    $registryRoots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($registryRoot in $registryRoots) {
        $entries = Get-ItemProperty -Path $registryRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "Inno Setup*" }
        foreach ($entry in $entries) {
            $resolved = Resolve-InnoCompilerCandidate $entry.InstallLocation
            if ($resolved) { return $resolved }
        }
    }

    return $null
}

function Require-InnoCompiler {
    $compiler = Find-InnoCompiler
    if ($compiler) {
        Write-Host "Using Inno Setup compiler: $compiler"
        return $compiler
    }

    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "Inno Setup 6 is required for the Windows installer. Install JRSoftware.InnoSetup with winget."
    }
    Write-Host "Installing Inno Setup 6 for the Windows installer..."
    & $winget.Source install --id JRSoftware.InnoSetup --exact --silent `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget could not install Inno Setup 6." }

    $compiler = Find-InnoCompiler
    if (-not $compiler) {
        throw "Inno Setup was installed but ISCC.exe could not be located. Set INNO_SETUP_PATH to the ISCC.exe path and rerun the build."
    }
    Write-Host "Using Inno Setup compiler: $compiler"
    return $compiler
}

function Assert-ApkNativeLibrary([string]$ApkPath, [string]$LibraryName) {
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
        throw "APK was not created: $ApkPath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ApkPath).Path)
    try {
        $nativeEntries = @(
            $archive.Entries | Where-Object {
                $_.FullName -match "^lib/[^/]+/$([regex]::Escape($LibraryName))$"
            }
        )
        if ($nativeEntries.Count -eq 0) {
            throw "$LibraryName is missing from $ApkPath. The APK would crash when SQLite is opened on Android."
        }
        $abis = @(
            $nativeEntries | ForEach-Object { ($_.FullName -split '/')[1] } | Sort-Object -Unique
        )
        Write-Host "Verified $LibraryName in APK for ABI(s): $($abis -join ', ')"
    } finally {
        $archive.Dispose()
    }
}

Require-Command "flutter" "Install Flutter and add its bin directory to PATH: https://docs.flutter.dev/get-started/install/windows"
Require-Command "dart" "The Dart executable is included with Flutter. Confirm Flutter's bin directory is on PATH."

if ($Target -eq "android" -or $Target -eq "both") {
    Write-Host "Preparing Android release signing..."
    & (Join-Path $root "scripts\build-android.ps1") -SetupOnly
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
Write-Host "Loom client version: $clientVersion+$clientBuildNumber"

Push-Location $protocolDirectory
try {
    Write-Host "Validating the corrected Node discovery protocol..."
    dart pub get
    if ($LASTEXITCODE -ne 0) { throw "Protocol package dependency resolution failed." }
    dart format --output=none lib test
    if ($LASTEXITCODE -ne 0) { throw "Protocol package formatting validation failed." }
    dart analyze --fatal-infos
    if ($LASTEXITCODE -ne 0) { throw "Protocol package analysis failed." }
    dart test
    if ($LASTEXITCODE -ne 0) { throw "Protocol package tests failed." }
} finally {
    Pop-Location
}

Push-Location $cryptoDirectory
try {
    Write-Host "Validating identity and Saved Messages cryptography..."
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "Crypto bridge dependency resolution failed." }
    dart format --output=none lib test
    if ($LASTEXITCODE -ne 0) { throw "Crypto bridge formatting validation failed." }
    flutter analyze --fatal-infos --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Crypto bridge analysis failed." }
    flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Crypto bridge tests failed." }
} finally {
    Pop-Location
}

Push-Location $clientDirectory
try {
    Write-Host "Flutter environment:"
    flutter --version
    flutter doctor -v

    Write-Host "Resolving dependencies..."
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }

    Write-Host "Checking client source formatting without rewriting files..."
    dart format --output=none lib test
    if ($LASTEXITCODE -ne 0) { throw "Dart formatting validation failed." }

    Write-Host "Analyzing client source..."
    # Keep real analyzer errors build-blocking while allowing non-fatal lints
    # from newer Flutter SDKs to be reported without preventing artifacts.
    flutter analyze --no-fatal-warnings --no-fatal-infos --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Flutter analyze failed." }

    Write-Host "Running client tests..."
    flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Flutter tests failed." }

    if ($Target -eq "windows" -or $Target -eq "both") {
        Write-Host "Building Windows release..."
        flutter config --enable-windows-desktop

        $windowsBuildDirectory = Join-Path $clientDirectory "build\windows"
        if (Test-Path $windowsBuildDirectory) {
            Write-Host "Removing stale Windows CMake cache..."
            Remove-Item -Recurse -Force $windowsBuildDirectory
        }

        # Let Flutter refresh native plugin registration for release.
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "Windows release build failed. Read the Flutter build output above for the actual cause."
        }

        $windowsRelease = Join-Path $clientDirectory "build\windows\x64\runner\Release"
        $windowsZip = Join-Path $outputDirectory "loom-windows-x64-$clientVersion.zip"
        Compress-Archive -Path "$windowsRelease\*" -DestinationPath $windowsZip -Force
        Write-Host "Windows artifact: $windowsZip"

        Write-Host "Building the Windows installer..."
        $innoCompiler = Require-InnoCompiler
        $installerScript = Join-Path $root "scripts\windows\loom-client.iss"
        & $innoCompiler `
            "/DSourceDir=$windowsRelease" `
            "/DArtifactDir=$outputDirectory" `
            "/DAppVersion=$clientVersion" `
            "/DVersionInfoVersion=$windowsVersionInfo" `
            $installerScript
        if ($LASTEXITCODE -ne 0) { throw "Windows installer build failed." }
        $windowsInstaller = Join-Path $outputDirectory "loom-windows-x64-setup-$clientVersion.exe"
        if (-not (Test-Path $windowsInstaller)) { throw "Windows installer output was not created." }
        Write-Host "Windows installer: $windowsInstaller"
    }

    if ($Target -eq "android" -or $Target -eq "both") {
        & (Join-Path $root "scripts/build-mls.ps1") -Target Android
        # Platform builds must regenerate plugin registration for each mode.
        # --no-pub can leave debug-only plugins in the release Java registrant.
        Write-Host "Building Android debug APK..."
        flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { throw "Android debug build failed." }

        Write-Host "Building Android release APK..."
        if ($UniversalAndroid) { flutter build apk --release }
        else { flutter build apk --release --split-per-abi }
        if ($LASTEXITCODE -ne 0) {
            throw "Android release build failed. Read the Flutter/Gradle output above for the actual cause."
        }

        $debugApk = Join-Path $clientDirectory "build\app\outputs\flutter-apk\app-debug.apk"
        $releaseNames = if ($UniversalAndroid) { @('app-release.apk') } else { @('app-armeabi-v7a-release.apk', 'app-arm64-v8a-release.apk', 'app-x86_64-release.apk') }
        $releaseApks = @($releaseNames | ForEach-Object {
            Join-Path $clientDirectory "build/app/outputs/flutter-apk/$_"
        })
        Assert-ApkNativeLibrary $debugApk "libsqlite3.so"
        Assert-ApkNativeLibrary $debugApk "libloom_mls.so"
        foreach ($releaseApk in $releaseApks) { Assert-ApkNativeLibrary $releaseApk "libsqlite3.so"; Assert-ApkNativeLibrary $releaseApk "libloom_mls.so" }

        Copy-Item $debugApk (Join-Path $outputDirectory "loom-android-debug-$clientVersion.apk") -Force
        foreach ($releaseApk in $releaseApks) {
            $abiName = [System.IO.Path]::GetFileNameWithoutExtension($releaseApk).Replace('app-', '').Replace('-release', '')
            Copy-Item $releaseApk (Join-Path $outputDirectory "loom-android-$abiName-engineering-$clientVersion.apk") -Force
            $size = [Math]::Round((Get-Item $releaseApk).Length / 1MB, 2)
            Write-Host "$abiName release: $size MiB"
        }
        Write-Host "Android artifacts: $outputDirectory"
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Build completed. Open: $outputDirectory"
if (-not $NoOpenArtifacts) {
    Start-Process explorer.exe $outputDirectory
}

