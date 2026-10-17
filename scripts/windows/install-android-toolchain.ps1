param(
    [string]$SdkRoot = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$AndroidApi = "36",
    [string]$BuildTools = "36.0.0",
    [string]$AndroidNdk = "28.2.13676358"
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$Name, [string]$Message) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found. $Message"
    }
}

function Install-WingetPackage([string]$Id, [string]$Name) {
    Write-Host "Checking $Name..."
    & winget list --id $Id --exact --accept-source-agreements | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$Name is already installed."
        return
    }

    Write-Host "Installing $Name with winget..."
    & winget install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install $Name ($Id)."
    }
}

function Find-JavaHome {
    $microsoftJdks = Get-ChildItem "$env:ProgramFiles\Microsoft" -Directory `
        -Filter "jdk-17*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { $_.FullName }
    $candidates = @($microsoftJdks)
    $candidates += "$env:ProgramFiles\Android\Android Studio\jbr"

    foreach ($candidate in $candidates) {
        if (Test-Path (Join-Path $candidate "bin\java.exe")) {
            return $candidate
        }
    }
    return $null
}

function Find-AndroidCli {
    $command = Get-Command "android" -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\android.exe",
        "$env:ProgramFiles\Android CLI\android.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Install-CommandLineTools([string]$DestinationSdk) {
    $sdkManager = Join-Path $DestinationSdk "cmdline-tools\latest\bin\sdkmanager.bat"
    if (Test-Path $sdkManager) {
        return $sdkManager
    }

    Write-Host "Finding the current official Android command-line tools..."
    $repositoryUrl = "https://dl.google.com/android/repository/repository2-1.xml"
    [xml]$repository = (Invoke-WebRequest -UseBasicParsing -Uri $repositoryUrl).Content
    $package = $repository.SelectSingleNode(
        "//*[local-name()='remotePackage' and @path='cmdline-tools;latest']"
    )
    if ($null -eq $package) {
        throw "Google's repository did not publish cmdline-tools;latest."
    }

    $windowsArchive = $null
    foreach ($archive in $package.SelectNodes(".//*[local-name()='archive']")) {
        $hostNode = $archive.SelectSingleNode("./*[local-name()='host-os']")
        if ($null -ne $hostNode -and $hostNode.InnerText -eq "windows") {
            $windowsArchive = $archive
            break
        }
    }
    if ($null -eq $windowsArchive) {
        throw "Google's repository did not provide Windows command-line tools."
    }

    $relativeUrl = $windowsArchive.SelectSingleNode(
        ".//*[local-name()='complete']/*[local-name()='url']"
    ).InnerText
    $checksumNode = $windowsArchive.SelectSingleNode(
        ".//*[local-name()='complete']/*[local-name()='checksum']"
    )
    $downloadUrl = "https://dl.google.com/android/repository/$relativeUrl"
    $temporaryRoot = Join-Path $env:TEMP "loom-android-tools-$PID"
    $archivePath = Join-Path $temporaryRoot "command-line-tools.zip"
    $expandedPath = Join-Path $temporaryRoot "expanded"
    New-Item -ItemType Directory -Force -Path $expandedPath | Out-Null

    Write-Host "Downloading $downloadUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $archivePath

    if ($null -ne $checksumNode -and $checksumNode.InnerText) {
        $expected = $checksumNode.InnerText.Trim().ToLowerInvariant()
        $algorithm = if ($checksumNode.type -eq "sha256") { "SHA256" } else { "SHA1" }
        $actual = (Get-FileHash -Path $archivePath -Algorithm $algorithm).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw "Android command-line tools checksum verification failed."
        }
    }

    Expand-Archive -Path $archivePath -DestinationPath $expandedPath
    $sourceTools = Join-Path $expandedPath "cmdline-tools"
    if (-not (Test-Path (Join-Path $sourceTools "bin\sdkmanager.bat"))) {
        throw "The Android command-line tools archive has an unexpected layout."
    }

    $commandLineRoot = Join-Path $DestinationSdk "cmdline-tools"
    New-Item -ItemType Directory -Force -Path $commandLineRoot | Out-Null
    $latestPath = Join-Path $commandLineRoot "latest"
    if (Test-Path $latestPath) {
        $backup = "$latestPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -Path $latestPath -Destination $backup
        Write-Host "Previous command-line tools moved to $backup"
    }
    Move-Item -Path $sourceTools -Destination $latestPath
    return Join-Path $latestPath "bin\sdkmanager.bat"
}

Require-Command "winget" "Install App Installer from Microsoft Store, then run this script again."
Install-WingetPackage "Google.AndroidStudio" "Android Studio"
Install-WingetPackage "Microsoft.OpenJDK.17" "Microsoft OpenJDK 17"
Install-WingetPackage "Google.AndroidCLI" "Android CLI"

$javaHome = Find-JavaHome
if ($null -eq $javaHome) {
    throw "JDK 17 was installed but JAVA_HOME could not be detected. Open a new terminal and run this script again."
}

New-Item -ItemType Directory -Force -Path $SdkRoot | Out-Null
$env:JAVA_HOME = $javaHome
$env:ANDROID_HOME = $SdkRoot
$env:ANDROID_SDK_ROOT = $SdkRoot
$env:Path = "$javaHome\bin;$SdkRoot\platform-tools;$env:Path"
setx JAVA_HOME "$javaHome" | Out-Null
setx ANDROID_HOME "$SdkRoot" | Out-Null
setx ANDROID_SDK_ROOT "$SdkRoot" | Out-Null

$null = Install-CommandLineTools $SdkRoot
$androidCli = Find-AndroidCli
if ($null -eq $androidCli) {
    throw "Android CLI was installed but android.exe could not be detected. Open a new terminal and run this script again."
}
Write-Host "Installing Android SDK packages..."
& $androidCli sdk install `
    "platform-tools" `
    "platforms/android-$AndroidApi" `
    "build-tools/$BuildTools" `
    "ndk/$AndroidNdk" `
    --force
if ($LASTEXITCODE -ne 0) {
    throw "Android CLI could not install the requested SDK and NDK packages."
}

if (Get-Command flutter -ErrorAction SilentlyContinue) {
    & flutter config --android-sdk $SdkRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter could not save the Android SDK path."
    }
    & flutter config --jdk-dir $javaHome
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter could not save the JDK 17 path."
    }
    & flutter doctor -v
} else {
    Write-Host "Flutter was not found in this terminal. The Android SDK is installed; run flutter doctor -v after reopening the terminal."
}

Write-Host ""
Write-Host "Android toolchain installation completed."
Write-Host "SDK:  $SdkRoot"
Write-Host "Java: $javaHome"
Write-Host "NDK:  $AndroidNdk"
Write-Host "Open a new terminal before building Loom for Android."
