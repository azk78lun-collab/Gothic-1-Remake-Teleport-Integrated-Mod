[CmdletBinding()]
param(
    [string]$ProjectDirectory = $PSScriptRoot,
    [string]$OutputDirectory = '',
    [string]$ArchiveName = 'Gothic 1 Remake Teleport Lite-Nexus.zip'
)

$ErrorActionPreference = 'Stop'
$projectDirectory = [IO.Path]::GetFullPath($ProjectDirectory)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $modifierFolder = -join @(
        [char]0x54E5, [char]0x7279, [char]0x738B, [char]0x671D,
        [char]0x4FEE, [char]0x6539, [char]0x5668
    )
    $OutputDirectory = Join-Path `
        ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)) `
        $modifierFolder
}
$outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$stageRoot = Join-Path $projectDirectory 'dist\Gothic 1 Remake Teleport Lite-Nexus'
$packageGameRoot = Join-Path $stageRoot 'Gothic 1 Remake'
$modRoot = Join-Path $packageGameRoot 'G1R\Binaries\Win64\Mods\TeleportLite'
$scriptsRoot = Join-Path $modRoot 'Scripts'
$dataRoot = Join-Path $modRoot 'data'
$archivePath = Join-Path $outputDirectory $ArchiveName

& (Join-Path $projectDirectory 'Build-TeleportLiteNative.ps1') `
    -SourceDirectory $projectDirectory `
    -OutputDirectory (Join-Path $projectDirectory 'build') | Out-Host

$resolvedStage = [IO.Path]::GetFullPath($stageRoot)
$expectedPrefix = [IO.Path]::GetFullPath((Join-Path $projectDirectory 'dist')) +
    [IO.Path]::DirectorySeparatorChar
if (-not $resolvedStage.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe staging path: $resolvedStage"
}
if (Test-Path -LiteralPath $resolvedStage) {
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $projectDirectory 'build\TeleportLiteNative.dll') `
    -Destination (Join-Path $modRoot 'TeleportLiteNative.dll')
Copy-Item -LiteralPath (Join-Path $projectDirectory 'main.lua') `
    -Destination (Join-Path $scriptsRoot 'main.lua')
Copy-Item -LiteralPath (Join-Path $projectDirectory 'data\TeleportLite_default_nodes.tsv') `
    -Destination (Join-Path $dataRoot 'TeleportLite_default_nodes.tsv')
Copy-Item -LiteralPath (Join-Path $projectDirectory 'README_zh-en.txt') `
    -Destination (Join-Path $packageGameRoot 'README_zh-en.txt')
Copy-Item -LiteralPath (Join-Path $projectDirectory 'LICENSE.txt') `
    -Destination (Join-Path $packageGameRoot 'LICENSE.txt')

$hashLines = foreach ($file in Get-ChildItem -LiteralPath $packageGameRoot -Recurse -File |
    Sort-Object FullName) {
    $relative = $file.FullName.Substring($packageGameRoot.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relative"
}
[IO.File]::WriteAllLines(
    (Join-Path $packageGameRoot 'SHA256SUMS.txt'),
    $hashLines,
    [Text.UTF8Encoding]::new($false)
)

$forbidden = @(
    Get-ChildItem -LiteralPath $stageRoot -Recurse -File |
        Where-Object {
            $_.Extension.ToLowerInvariant() -in @('.exe', '.ps1', '.cmd', '.bat', '.vbs') -or
            $_.Name -in @('dwmapi.dll', 'UE4SS.dll')
        }
)
if ($forbidden.Count -ne 0) {
    throw "Forbidden release entries: $($forbidden.FullName -join ', ')"
}

if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}
Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $archivePath `
    -CompressionLevel Optimal

[pscustomobject]@{
    Stage = $stageRoot
    Archive = $archivePath
    ArchiveBytes = (Get-Item -LiteralPath $archivePath).Length
    ArchiveSHA256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    ReleaseFiles = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File).Count
}
