<#
.SYNOPSIS
    Builds the debug APK and installs it on one or more selected adb devices.

.DESCRIPTION
    Lists every device currently visible to `adb devices` (with model/
    manufacturer looked up per device so they're actually distinguishable -
    plain serials/hostnames aren't), lets you pick one, several, or all of
    them, builds the debug APK via Gradle, then installs it on each chosen
    device in turn.

.PARAMETER SkipBuild
    Install the most recently built APK without rebuilding first.

.EXAMPLE
    ./scripts/deploy.ps1
.EXAMPLE
    ./scripts/deploy.ps1 -SkipBuild
#>
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    throw "adb.exe not found. Set ANDROID_HOME or add platform-tools to PATH."
}

$adb = Find-Adb
$repoRoot = Split-Path -Parent $PSScriptRoot
$apkPath = Join-Path $repoRoot "build\app\outputs\apk\debug\app-debug.apk"

# --- Discover devices -------------------------------------------------
$rawDevices = & $adb devices | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne "" }
$serials = @()
foreach ($line in $rawDevices) {
    $parts = $line -split "\s+"
    if ($parts.Length -ge 2 -and $parts[1] -eq "device") {
        $serials += $parts[0]
    }
}

if ($serials.Count -eq 0) {
    Write-Host "No adb devices found (adb devices shows none in 'device' state)." -ForegroundColor Red
    exit 1
}

Write-Host "Looking up device names..." -ForegroundColor DarkGray
$devices = @()
foreach ($serial in $serials) {
    $model = (& $adb -s $serial shell getprop ro.product.model 2>$null).Trim()
    $manufacturer = (& $adb -s $serial shell getprop ro.product.manufacturer 2>$null).Trim()
    $devices += [PSCustomObject]@{
        Serial       = $serial
        Manufacturer = $manufacturer
        Model        = $model
    }
}

Write-Host ""
Write-Host "Connected devices:" -ForegroundColor Cyan
for ($i = 0; $i -lt $devices.Count; $i++) {
    $d = $devices[$i]
    Write-Host ("  [{0}] {1} {2}  ({3})" -f ($i + 1), $d.Manufacturer, $d.Model, $d.Serial)
}
Write-Host ("  [a] Alle ({0} Geräte)" -f $devices.Count)
Write-Host ""

$selection = Read-Host "Auf welche(s) Gerät(e) installieren? (Nummer(n) mit Komma getrennt, oder 'a' für alle)"

$chosen = @()
if ($selection.Trim().ToLower() -eq 'a') {
    $chosen = $devices
} else {
    $indices = $selection -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    foreach ($idx in $indices) {
        $n = 0
        if ([int]::TryParse($idx, [ref]$n) -and $n -ge 1 -and $n -le $devices.Count) {
            $chosen += $devices[$n - 1]
        } else {
            Write-Host "Ungültige Auswahl übersprungen: '$idx'" -ForegroundColor Yellow
        }
    }
}

if ($chosen.Count -eq 0) {
    Write-Host "Keine gültige Auswahl - Abbruch." -ForegroundColor Red
    exit 1
}

# --- Build --------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host ""
    Write-Host "Baue Debug-APK..." -ForegroundColor Cyan
    Push-Location $repoRoot
    try {
        & "$repoRoot\android\gradlew.bat" -p android ":app:assembleDebug"
        if ($LASTEXITCODE -ne 0) { throw "Gradle build failed (exit code $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $apkPath)) {
    throw "APK not found at $apkPath - build it first (omit -SkipBuild)."
}

# --- Install --------------------------------------------------------------
Write-Host ""
foreach ($d in $chosen) {
    Write-Host ("Installiere auf {0} {1} ({2})..." -f $d.Manufacturer, $d.Model, $d.Serial) -ForegroundColor Cyan
    & $adb -s $d.Serial install -r $apkPath
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  OK" -ForegroundColor Green
    } else {
        Write-Host "  Fehlgeschlagen (exit code $LASTEXITCODE)" -ForegroundColor Red
    }
}
