[CmdletBinding()]
param(
    [string]$SourceDirectory = $PSScriptRoot,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'build')
)

$ErrorActionPreference = 'Stop'
$sourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
$outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'

if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Installer vswhere.exe was not found.'
}
$installPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath | Select-Object -First 1
$vsDevCmd = if ($installPath) { Join-Path $installPath 'Common7\Tools\VsDevCmd.bat' } else { '' }
if (-not $vsDevCmd -or -not (Test-Path -LiteralPath $vsDevCmd)) {
    throw 'Visual Studio C++ x64 build tools were not found.'
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$cpp = Join-Path $sourceDirectory 'TeleportLiteNative.cpp'
$objOutput = Join-Path $outputDirectory 'TeleportLiteNative.obj'
$dllOutput = Join-Path $outputDirectory 'TeleportLiteNative.dll'
$tempCmd = Join-Path $env:TEMP ('build_teleport_lite_{0}.cmd' -f ([Guid]::NewGuid().ToString('N')))

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W4 /guard:cf /DUNICODE /D_UNICODE /LD /Fo:"$objOutput" /Fe:"$dllOutput" "$cpp" user32.lib gdi32.lib comctl32.lib comdlg32.lib shell32.lib /link /Brepro /DYNAMICBASE /NXCOMPAT /INCREMENTAL:NO /OPT:REF /OPT:ICF
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $tempCmd -Encoding ASCII

try {
    cmd.exe /d /c "`"$tempCmd`""
    if ($LASTEXITCODE -ne 0) {
        throw "C++ build failed with exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
}

$file = Get-Item -LiteralPath $dllOutput
[pscustomobject]@{
    Path = $file.FullName
    Length = $file.Length
    SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}
