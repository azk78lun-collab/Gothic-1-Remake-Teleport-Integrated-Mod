[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Install", "List", "Post")]
    [string]$Action,
    [string]$RequestFile = "",
    [string]$ResponseFile = "",
    [string]$Version = "4.1.0",
    [string]$ApiBase = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($ApiBase)) {
    $ApiBase = if ($env:G1R_COMMUNITY_API_BASE) {
        $env:G1R_COMMUNITY_API_BASE
    } else {
        "https://gothic.1223344.xyz/api/v1"
    }
}
$ApiBase = $ApiBase.TrimEnd("/")
if ($ApiBase -notmatch '^https://' -and $ApiBase -notmatch '^http://(127\.0\.0\.1|localhost)(:\d+)?/') {
    throw "Community API must use HTTPS."
}

$localData = if ($env:LOCALAPPDATA) {
    $env:LOCALAPPDATA
} else {
    Join-Path $env:USERPROFILE "AppData\Local"
}
$stateDirectory = Join-Path $localData "G1RTeleportIntegratedMod"
$identityPath = Join-Path $stateDirectory "community-client.json"

function Write-Utf8JsonAtomic([string]$Path, [object]$Value) {
    $directory = Split-Path -Parent $Path
    if ($directory) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-CommunityIdentity {
    [System.IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    if (Test-Path -LiteralPath $identityPath) {
        try {
            $saved = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parsed = [Guid]::Empty
            if ([Guid]::TryParse([string]$saved.client_id, [ref]$parsed) -and $parsed -ne [Guid]::Empty) {
                return [pscustomobject]@{
                    client_id = $parsed.ToString()
                    created_at = [string]$saved.created_at
                }
            }
        } catch {
        }
    }

    $identity = [pscustomobject]@{
        client_id = [Guid]::NewGuid().ToString()
        created_at = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Write-Utf8JsonAtomic $identityPath $identity
    return $identity
}

function Invoke-CommunityApi([string]$Method, [string]$Path, [object]$Body = $null) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [System.Net.HttpWebRequest]::Create("$ApiBase$Path")
    $request.Method = $Method
    $request.Accept = "application/json"
    $request.UserAgent = "G1R-Teleport-Integrated-Mod/$Version"
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $request.KeepAlive = $false

    if ($null -ne $Body) {
        $payload = $Body | ConvertTo-Json -Depth 8 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $request.ContentType = "application/json; charset=utf-8"
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    }

    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
    } catch [System.Net.WebException] {
        $webResponse = $_.Exception.Response
        if ($webResponse) {
            $reader = [System.IO.StreamReader]::new($webResponse.GetResponseStream(), [System.Text.Encoding]::UTF8)
            try {
                $errorBody = $reader.ReadToEnd() | ConvertFrom-Json
                if ($errorBody.message) { throw [System.Exception]::new([string]$errorBody.message) }
            } finally {
                $reader.Dispose()
                $webResponse.Dispose()
            }
        }
        throw
    }

    try {
        $reader = [System.IO.StreamReader]::new($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try {
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        } finally {
            $reader.Dispose()
        }
    } finally {
        $response.Dispose()
    }
}

function Write-OperationResult([bool]$Ok, [object]$Data, [string]$Message = "") {
    $result = [pscustomobject]@{
        ok = $Ok
        message = $Message
        data = $Data
    }
    if ($ResponseFile) {
        Write-Utf8JsonAtomic $ResponseFile $result
    } elseif (-not $Quiet) {
        $result | ConvertTo-Json -Depth 12 -Compress
    }
}

try {
    $identity = Get-CommunityIdentity
    switch ($Action) {
        "Install" {
            $data = Invoke-CommunityApi "POST" "/installations" @{
                install_id = $identity.client_id
                version = $Version
            }
            Write-OperationResult $true $data "install event recorded"
        }
        "List" {
            $data = Invoke-CommunityApi "GET" "/messages?limit=100"
            Write-OperationResult $true $data "messages loaded"
        }
        "Post" {
            if (-not $RequestFile -or -not (Test-Path -LiteralPath $RequestFile)) {
                throw "Message request file was not found."
            }
            $post = Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $payload = @{
                client_id = $identity.client_id
                nickname = [string]$post.nickname
                message = [string]$post.message
            }
            if ($post.PSObject.Properties.Name -contains "reply_to_id") {
                $replyToId = 0
                if ([int]::TryParse([string]$post.reply_to_id, [ref]$replyToId) -and $replyToId -gt 0) {
                    $payload.reply_to_id = $replyToId
                }
            }
            $data = Invoke-CommunityApi "POST" "/messages" $payload
            Write-OperationResult $true $data "message posted"
        }
    }
    exit 0
} catch {
    Write-OperationResult $false $null $_.Exception.Message
    if (-not $Quiet) {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
    exit 0
}
