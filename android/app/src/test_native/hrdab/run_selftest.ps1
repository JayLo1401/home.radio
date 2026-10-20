# Builds the hrdab self test with the NDK and runs it on an adb device.
#   .\run_selftest.ps1 [-Abi arm64-v8a|armeabi-v7a] [-Serial <adb serial>] [-Mode quick|full]
param(
    [string]$Abi = "arm64-v8a",
    [string]$Serial = "",
    [string]$Mode = "full"
)
$ErrorActionPreference = "Stop"
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$ndk = Get-ChildItem "$sdk\ndk" | Sort-Object Name | Select-Object -Last 1
$bin = "$($ndk.FullName)\toolchains\llvm\prebuilt\windows-x86_64\bin"
$adb = "$sdk\platform-tools\adb.exe"
$target = if ($Abi -eq "armeabi-v7a") { "armv7a-linux-androideabi24" } else { "aarch64-linux-android24" }
$extra = if ($Abi -eq "armeabi-v7a") { @("-mfpu=neon", "-mfloat-abi=softfp") } else { @() }

$here = $PSScriptRoot
$src = Resolve-Path "$here\..\..\main\cpp\hrdab"
$sources = Get-ChildItem $src -Filter *.cpp | Where-Object { $_.Name -ne "hrdab_jni.cpp" } | ForEach-Object { $_.FullName }
$sources += "$here\tx_sim.cpp", "$here\selftest.cpp"
$out = "$env:TEMP\hrdab_selftest_$Abi"

& "$bin\clang++.exe" --target=$target -std=c++17 -O2 -DHRDAB_STDERR_LOG -Wall -Wno-unused-variable @extra -I $src -I $here @sources -static-libstdc++ -llog -o $out
if ($LASTEXITCODE -ne 0) { throw "build failed" }

$adbArgs = if ($Serial) { @("-s", $Serial) } else { @() }
& $adb @adbArgs push $out /data/local/tmp/hrdab_selftest | Out-Null
& $adb @adbArgs shell "chmod 755 /data/local/tmp/hrdab_selftest && /data/local/tmp/hrdab_selftest $Mode"
