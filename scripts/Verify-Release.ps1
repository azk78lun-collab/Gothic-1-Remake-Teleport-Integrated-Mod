[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageRoot
)

$ErrorActionPreference = "Stop"
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)

$requiredFiles = @(
    "dwmapi.dll",
    "UE4SS.dll",
    "UE4SS-settings.ini",
    "install.ps1",
    "uninstall.ps1",
    "managed_mods.txt",
    "使用说明.txt",
    "Mods\mods.txt",
    "Mods\TeleportMod\Scripts\main.lua",
    "Mods\TeleportMod\Scripts\TeleportMod_core.lua",
    "Mods\ItemMod\Scripts\main.lua",
    "Mods\G1R_NoChestLocks\Scripts\main.lua",
    "Mods\FocusNearbyPickups\Scripts\main.lua",
    "Mods\TeleportModUIExternal\TeleportModUI.ps1",
    "Mods\TeleportModUIExternal\CommunityClient.ps1",
    "Mods\TeleportModUIExternal\TeleportCppBridge.exe",
    "Mods\TeleportModUIExternal\PlayerEditCppBridge.exe",
    "Mods\TeleportModUIExternal\TeleportUiNative.dll",
    "LICENSE",
    "LICENSE-UE4SS-MIT.txt",
    "THIRD_PARTY_NOTICES.md",
    "UE4SS-UPSTREAM.md"
)
foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $PackageRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required release file is missing: $relativePath"
    }
}

$forbiddenPatterns = @(
    "HostilityMemoryCpp",
    "G1RSaveHostilityFix",
    "oo2core",
    "oozle",
    "SaveBackups",
    "G1R-009.sav",
    "TeleportMod_crime_status",
    "TeleportMod_hostility_status",
    ".private",
    "community-admin",
    "g1r-community.env",
    "run-public-e2e",
    "cleanup_test_records"
)
$allFiles = Get-ChildItem -LiteralPath $PackageRoot -Recurse -File
foreach ($pattern in $forbiddenPatterns) {
    $match = $allFiles | Where-Object { $_.FullName -match [regex]::Escape($pattern) } |
        Select-Object -First 1
    if ($match) {
        throw "Forbidden release artifact found: $($match.FullName)"
    }
}

$textFiles = $allFiles | Where-Object {
    $_.Extension -in @(".ps1", ".lua", ".txt", ".md", ".ini", ".cmd", ".vbs", ".tsv")
}
$separator = [System.IO.Path]::DirectorySeparatorChar
$forbiddenContent = @(
    ("E:" + $separator + "OpenClaw"),
    ("C:" + $separator + "Users" + $separator + "Administrator"),
    "FORGIVE_ALL_CRIMES",
    "PARDON_ALL_CRIMES",
    "CLEAR_HOSTILITY",
    "G1R_COMMUNITY_ADMIN_TOKEN=",
    ("161" + ".33.24.201"),
    "ssh-key"
)
foreach ($file in $textFiles) {
    $content = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($pattern in $forbiddenContent) {
        if ($content.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Forbidden content '$pattern' found in $($file.FullName)"
        }
    }
}

[pscustomobject]@{
    PackageRoot = $PackageRoot
    FileCount = $allFiles.Count
    TotalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
    State = "VERIFIED"
}
