<#
.SYNOPSIS
    Builds the Windows release and the Inno Setup installer.

.DESCRIPTION
    flutter build windows --release, then windows/installer/setup.iss with
    Inno Setup 6. Output: windows/installer/output/setup.exe and
    version.json (the update manifest, see lib/data/services/update_service.dart).

.PARAMETER Version
    App version, e.g. 1.3.0 (default: from pubspec.yaml).

.PARAMETER UpdateBaseUrl
    Update server the app checks, e.g.
    https://repository.jaycloud.at/repository/home.radio - empty = the app
    never updates itself.

.EXAMPLE
    ./windows/scripts/build-installer.ps1
.EXAMPLE
    ./windows/scripts/build-installer.ps1 -Version 1.3.0 -UpdateBaseUrl https://repository.jaycloud.at/repository/home.radio
#>
param(
    [string]$Version,
    [string]$BuildNumber,
    [string]$UpdateBaseUrl = ''
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$installer = Join-Path $root 'windows\installer'
Push-Location $root
try {
    if (-not $Version) {
        $Version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\d+\.\d+\.\d+)').Matches[0].Groups[1].Value
    }

    $flutterArgs = @('build', 'windows', '--release', "--build-name=$Version")
    if ($BuildNumber) { $flutterArgs += "--build-number=$BuildNumber" }
    if ($UpdateBaseUrl) { $flutterArgs += "--dart-define=UPDATE_BASE_URL=$UpdateBaseUrl" }
    & flutter @flutterArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)" }

    $redist = Join-Path $installer 'vc_redist.x64.exe'
    if (-not (Test-Path $redist)) {
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $redist
    }

    $iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
    if (-not (Test-Path $iscc)) { $iscc = (Get-Command iscc -ErrorAction Stop).Source }
    $publish = Join-Path $root 'build\windows\x64\runner\Release'
    & $iscc (Join-Path $installer 'setup.iss') "/DPublishDir=$publish" "/DAppVersion=$Version"
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)" }

    $setup = Join-Path $installer 'output\setup.exe'
    $hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLower()
    $manifest = [ordered]@{
        version = $Version
        url     = if ($UpdateBaseUrl) { "$UpdateBaseUrl/windows/release/$Version/home_radio-setup-$Version.exe" } else { '' }
        sha256  = $hash
    }
    $manifest | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $installer 'output\version.json')
    Write-Host "Installer: $setup ($Version)"
} finally {
    Pop-Location
}
