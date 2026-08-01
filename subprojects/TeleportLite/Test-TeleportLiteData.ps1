[CmdletBinding()]
param(
    [string]$ProjectDirectory = $PSScriptRoot,
    [string]$RuntimeSpotsPath = ''
)

$ErrorActionPreference = 'Stop'
$dataPath = Join-Path $ProjectDirectory 'data\TeleportLite_default_nodes.tsv'
$luaPath = Join-Path $ProjectDirectory 'main.lua'

$rows = @(Import-Csv -LiteralPath $dataPath -Delimiter "`t" -Encoding UTF8)
if ($rows.Count -ne 108) {
    throw "Expected 108 built-in nodes, found $($rows.Count)."
}

$duplicateIds = @($rows | Group-Object Id | Where-Object Count -ne 1)
if ($duplicateIds.Count -ne 0) {
    throw 'Node IDs are not unique.'
}

$required = @('Id', 'GroupZh', 'GroupEn', 'NameZh', 'NameEn', 'X', 'Y', 'Z')
foreach ($row in $rows) {
    foreach ($column in $required) {
        if ([string]::IsNullOrWhiteSpace([string]$row.$column)) {
            throw "Node $($row.Id) is missing $column."
        }
    }
    foreach ($axis in @('X', 'Y', 'Z')) {
        $value = [double]0
        if (-not [double]::TryParse(
            [string]$row.$axis,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$value
        ) -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
            throw "Node $($row.Id) has an invalid $axis coordinate."
        }
    }
}

if (@($rows | Where-Object { $_.NameZh -match '^Spot_\d+$' }).Count -ne 0) {
    throw 'Personal Spot_* nodes leaked into the built-in catalog.'
}

if (-not [string]::IsNullOrWhiteSpace($RuntimeSpotsPath) -and
    (Test-Path -LiteralPath $RuntimeSpotsPath)) {
    $runtimeLines = @(
        [IO.File]::ReadAllLines(
            [IO.Path]::GetFullPath($RuntimeSpotsPath),
            [Text.UTF8Encoding]::new($false)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $officialLines = @($runtimeLines | Where-Object {
        (($_ -split '\|', 2)[0]) -notmatch '^Spot_\d+$'
    })
    if ($officialLines.Count -ne 108) {
        throw "Runtime source contains $($officialLines.Count) official nodes, expected 108."
    }
    for ($index = 0; $index -lt 108; $index++) {
        $parts = $officialLines[$index].Split('|')
        $row = $rows[$index]
        if ($parts.Count -lt 4 -or
            $row.NameZh -ne $parts[0] -or
            [double]$row.X -ne [double]$parts[1] -or
            [double]$row.Y -ne [double]$parts[2] -or
            [double]$row.Z -ne [double]$parts[3]) {
            throw "Node $($row.Id) does not match runtime source line $($index + 1)."
        }
    }
}

$lua = [IO.File]::ReadAllText($luaPath, [Text.UTF8Encoding]::new($false))
foreach ($forbidden in @('Key.F7', 'NOCLIP', 'FreeFlightInitialize', 'CommunityClient')) {
    if ($lua.Contains($forbidden)) {
        throw "Lua contains forbidden non-teleport token: $forbidden"
    }
}
foreach ($requiredToken in @('Key.F1', 'Key.F3', 'Key.F6', 'NUM_ZERO', 'TeleportLiteInitialize')) {
    if (-not $lua.Contains($requiredToken)) {
        throw "Lua is missing required token: $requiredToken"
    }
}

[pscustomobject]@{
    Nodes = $rows.Count
    GroupsZh = @($rows.GroupZh | Sort-Object -Unique).Count
    GroupsEn = @($rows.GroupEn | Sort-Object -Unique).Count
    PersonalNodes = 0
    RuntimeCoordinatesMatched = (-not [string]::IsNullOrWhiteSpace($RuntimeSpotsPath) -and
        (Test-Path -LiteralPath $RuntimeSpotsPath))
}
