[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Ue4ssRuntimeRoot,

    [string]$NativeBinRoot = "",
    [string]$OutputRoot = "",
    [string]$Version = "v4.0.0"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$Ue4ssRuntimeRoot = [System.IO.Path]::GetFullPath($Ue4ssRuntimeRoot)
if ([string]::IsNullOrWhiteSpace($NativeBinRoot)) {
    $NativeBinRoot = Join-Path $repoRoot "artifacts\native"
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist"
}
$NativeBinRoot = [System.IO.Path]::GetFullPath($NativeBinRoot)
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$requiredRuntime = @("UE4SS.dll", "dwmapi.dll")
foreach ($name in $requiredRuntime) {
    $path = Join-Path $Ue4ssRuntimeRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "UE4SS runtime file not found: $path"
    }
}

$requiredNative = @(
    "TeleportCppBridge.exe",
    "PlayerEditCppBridge.exe",
    "TeleportUiNative.dll"
)
foreach ($name in $requiredNative) {
    $path = Join-Path $NativeBinRoot $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Native component not found: $path. Run scripts\Build-AllNative.ps1 first."
    }
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$packageName = "Gothic-1-Remake-Teleport-Integrated-Mod-V4"
$stageRoot = Join-Path $OutputRoot $packageName
$zipPath = Join-Path $OutputRoot ($packageName + ".zip")

if (Test-Path -LiteralPath $stageRoot) {
    $resolvedOutput = [System.IO.Path]::GetFullPath($OutputRoot)
    $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
    if (-not $resolvedStage.StartsWith($resolvedOutput + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove staging path outside OutputRoot: $resolvedStage"
    }
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$modsRoot = Join-Path $stageRoot "Mods"
$uiRoot = Join-Path $modsRoot "TeleportModUIExternal"
New-Item -ItemType Directory -Path $modsRoot, $uiRoot -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $Ue4ssRuntimeRoot "UE4SS.dll") -Destination $stageRoot
Copy-Item -LiteralPath (Join-Path $Ue4ssRuntimeRoot "dwmapi.dll") -Destination $stageRoot

foreach ($name in @(
    "install.ps1",
    "uninstall.ps1",
    "managed_mods.txt",
    "UE4SS-settings.ini",
    "使用说明.txt",
    "双击一键安装.cmd",
    "双击一键卸载.cmd"
)) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "packaging\$name") -Destination $stageRoot
}
Copy-Item -LiteralPath (Join-Path $repoRoot "README.md") -Destination $stageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE") -Destination $stageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot "THIRD_PARTY_NOTICES.md") -Destination $stageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot "third_party\UE4SS\LICENSE") `
    -Destination (Join-Path $stageRoot "LICENSE-UE4SS-MIT.txt")
Copy-Item -LiteralPath (Join-Path $repoRoot "third_party\UE4SS\UPSTREAM.md") `
    -Destination (Join-Path $stageRoot "UE4SS-UPSTREAM.md")
Copy-Item -LiteralPath (Join-Path $repoRoot "packaging\mods.txt") `
    -Destination (Join-Path $modsRoot "mods.txt")

Get-ChildItem -LiteralPath (Join-Path $repoRoot "third_party\UE4SS\Mods") -Directory |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $modsRoot -Recurse -Force
    }
Get-ChildItem -LiteralPath (Join-Path $repoRoot "src\lua\Mods") -Directory |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $modsRoot -Recurse -Force
    }

Copy-Item -LiteralPath (Join-Path $repoRoot "src\powershell\TeleportModUI.ps1") -Destination $uiRoot
Copy-Item -LiteralPath (Join-Path $repoRoot "src\powershell\TeleportMemoryBridge.ps1") -Destination $uiRoot
Get-ChildItem -LiteralPath (Join-Path $repoRoot "src\data") -File |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $uiRoot }
Get-ChildItem -LiteralPath (Join-Path $repoRoot "src\assets") -File |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $uiRoot }
Get-ChildItem -LiteralPath (Join-Path $repoRoot "packaging\launchers") -File |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $uiRoot }
foreach ($name in $requiredNative) {
    Copy-Item -LiteralPath (Join-Path $NativeBinRoot $name) -Destination $uiRoot
}

& (Join-Path $PSScriptRoot "Verify-Release.ps1") -PackageRoot $stageRoot

Compress-Archive -LiteralPath $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$checksumPath = Join-Path $OutputRoot "SHA256SUMS.txt"
$checksumLine = "{0}  {1}`r`n" -f $zipHash, [System.IO.Path]::GetFileName($zipPath)
[System.IO.File]::WriteAllText($checksumPath, $checksumLine, [System.Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    Version = $Version
    PackageRoot = $stageRoot
    Zip = $zipPath
    SHA256 = $zipHash
    Checksums = $checksumPath
}
