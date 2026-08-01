[CmdletBinding()]
param(
    [string]$ProjectDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$projectDirectory = [IO.Path]::GetFullPath($ProjectDirectory)
$smokeRoot = Join-Path $projectDirectory 'smoke_runtime'
$modRoot = Join-Path $smokeRoot 'Mods\TeleportLite'
$dataRoot = Join-Path $modRoot 'data'
$buildRoot = Join-Path $projectDirectory 'build'
$testExe = Join-Path $buildRoot 'NativeSmoke.exe'
$testObj = Join-Path $buildRoot 'NativeSmoke.obj'

if (Test-Path -LiteralPath $smokeRoot) {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $buildRoot 'TeleportLiteNative.dll') `
    -Destination (Join-Path $modRoot 'TeleportLiteNative.dll')
Copy-Item -LiteralPath (Join-Path $projectDirectory 'data\TeleportLite_default_nodes.tsv') `
    -Destination (Join-Path $dataRoot 'TeleportLite_default_nodes.tsv')

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$installPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath | Select-Object -First 1
$vsDevCmd = Join-Path $installPath 'Common7\Tools\VsDevCmd.bat'
$source = Join-Path $projectDirectory 'tests\NativeSmoke.cpp'
$tempCmd = Join-Path $env:TEMP ('build_teleport_lite_smoke_{0}.cmd' -f ([Guid]::NewGuid().ToString('N')))

@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W4 /Fo:"$testObj" /Fe:"$testExe" "$source"
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $tempCmd -Encoding ASCII
try {
    cmd.exe /d /c "`"$tempCmd`""
    if ($LASTEXITCODE -ne 0) {
        throw "Native smoke harness build failed with exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
}

& $testExe (Join-Path $modRoot 'TeleportLiteNative.dll') $smokeRoot
if ($LASTEXITCODE -ne 0) {
    throw "Native smoke harness failed with exit code $LASTEXITCODE"
}

$nodes = @(Import-Csv -LiteralPath (Join-Path $smokeRoot 'TeleportLite_nodes.tsv') `
    -Delimiter "`t" -Encoding UTF8)
if ($nodes.Count -ne 108) {
    throw "Smoke runtime created $($nodes.Count) nodes instead of 108."
}

[pscustomobject]@{
    Runtime = $smokeRoot
    Nodes = $nodes.Count
    Status = ([IO.File]::ReadAllText((Join-Path $smokeRoot 'TeleportLite_status.txt'))).Trim()
    DiagnosticLines = [IO.File]::ReadAllLines(
        (Join-Path $smokeRoot 'TeleportLite_native_diag.txt')
    ).Count
}
