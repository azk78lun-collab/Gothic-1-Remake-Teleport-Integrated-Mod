[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("TeleportCppBridge", "PlayerEditCppBridge", "TeleportUiNative")]
    [string]$Component,

    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$sourcePath = Join-Path $repoRoot ("src\native\{0}.cpp" -f $Component)
if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Source file not found: $sourcePath"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "artifacts\native"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$isDll = $Component -eq "TeleportUiNative"
$extension = if ($isDll) { ".dll" } else { ".exe" }
$outputPath = Join-Path $OutputDirectory ($Component + $extension)

$vsDevCmd = $null
$vswhereCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
    (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe")
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

foreach ($vswhere in $vswhereCandidates) {
    if (-not (Test-Path -LiteralPath $vswhere)) {
        continue
    }
    $installPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath | Select-Object -First 1
    if ($installPath) {
        $candidate = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
        if (Test-Path -LiteralPath $candidate) {
            $vsDevCmd = $candidate
            break
        }
    }
}

if (-not $vsDevCmd) {
    throw "Visual Studio C++ x64 build tools were not found."
}

$compilerFlags = @(
    "/nologo",
    "/std:c++17",
    "/EHsc",
    "/O2",
    "/MT",
    "/W4",
    "/DUNICODE",
    "/D_UNICODE"
)
if ($isDll) {
    $compilerFlags += "/LD"
}
$flagText = $compilerFlags -join " "

$tempCmd = Join-Path $env:TEMP ("g1r_build_{0}_{1}.cmd" -f $Component, [Guid]::NewGuid().ToString("N"))
$commandText = @"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cl $flagText /Fe:"$outputPath" "$sourcePath" user32.lib
exit /b %errorlevel%
"@

[System.IO.File]::WriteAllText($tempCmd, $commandText, [System.Text.Encoding]::ASCII)
try {
    & cmd.exe /d /c "`"$tempCmd`""
    if ($LASTEXITCODE -ne 0) {
        throw "$Component build failed with exit code $LASTEXITCODE."
    }
} finally {
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
}

$file = Get-Item -LiteralPath $outputPath
$hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
[pscustomobject]@{
    Component = $Component
    Path = $file.FullName
    Length = $file.Length
    SHA256 = $hash
}

