param(
    [string]$Win64Dir = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Win64Dir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $Win64Dir = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
}

$actionsPath = Join-Path $Win64Dir "TeleportMod_mem_actions.txt"
$statusPath = Join-Path $Win64Dir "TeleportMod_mem_status.txt"
$diagPath = Join-Path $Win64Dir "TeleportMod_mem_diag.txt"
$flagPath = Join-Path $Win64Dir "TeleportMod_mem_bridge.pid"
$processName = "G1R-Win64-Shipping"

function Write-Diag([string]$message) {
    try {
        $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}`r`n" -f (Get-Date), $message
        [System.IO.File]::AppendAllText($diagPath, $line, [System.Text.UTF8Encoding]::new($false))
    } catch {
    }
}

function Write-State([string]$state, [string]$message) {
    try {
        $text = "STATE=$state`r`nMESSAGE=$message`r`nUPDATED=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`r`n"
        [System.IO.File]::WriteAllText($statusPath, $text, [System.Text.UTF8Encoding]::new($false))
    } catch {
    }
}

if (Test-Path -LiteralPath $flagPath) {
    try {
        $oldPid = [int]([System.IO.File]::ReadAllText($flagPath).Trim())
        if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
            Write-State "IDLE" "memory bridge already running"
            exit
        }
    } catch {
    }
}
[System.IO.File]::WriteAllText($flagPath, "$PID", [System.Text.UTF8Encoding]::new($false))

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MemBridgeNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(UInt32 dwDesiredAccess, bool bInheritHandle, UInt32 dwProcessId);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, UIntPtr nSize, out UIntPtr lpNumberOfBytesRead);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, UIntPtr nSize, out UIntPtr lpNumberOfBytesWritten);
}
"@

$PROCESS_QUERY_INFORMATION = [uint32]0x0400
$PROCESS_VM_OPERATION = [uint32]0x0008
$PROCESS_VM_READ = [uint32]0x0010
$PROCESS_VM_WRITE = [uint32]0x0020
$PROCESS_ACCESS = $PROCESS_QUERY_INFORMATION -bor $PROCESS_VM_OPERATION -bor $PROCESS_VM_READ -bor $PROCESS_VM_WRITE

function Open-GameProcess {
    $proc = Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) {
        $proc = Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $proc) { throw "game process not found" }
    $handle = [MemBridgeNative]::OpenProcess($PROCESS_ACCESS, $false, [uint32]$proc.Id)
    if ($handle -eq [IntPtr]::Zero) { throw "failed to open game process" }
    return [pscustomobject]@{ Process = $proc; Handle = $handle }
}

function Read-Bytes($handle, [UInt64]$address, [int]$count) {
    $buffer = New-Object byte[] $count
    $read = [UIntPtr]::Zero
    $ok = [MemBridgeNative]::ReadProcessMemory($handle, [IntPtr]$address, $buffer, [UIntPtr][uint64]$count, [ref]$read)
    if (-not $ok -or [uint64]$read -ne [uint64]$count) {
        throw ("read memory failed 0x{0:X}" -f $address)
    }
    return $buffer
}

function Read-U64($handle, [UInt64]$address) {
    return [BitConverter]::ToUInt64((Read-Bytes $handle $address 8), 0)
}

function Read-I32($handle, [UInt64]$address) {
    return [BitConverter]::ToInt32((Read-Bytes $handle $address 4), 0)
}

function Read-F64($handle, [UInt64]$address) {
    return [BitConverter]::ToDouble((Read-Bytes $handle $address 8), 0)
}

function Write-F64($handle, [UInt64]$address, [double]$value) {
    $bytes = [BitConverter]::GetBytes($value)
    $written = [UIntPtr]::Zero
    $ok = [MemBridgeNative]::WriteProcessMemory($handle, [IntPtr]$address, $bytes, [UIntPtr][uint64]8, [ref]$written)
    if (-not $ok -or [uint64]$written -ne 8) {
        throw ("write memory failed 0x{0:X}" -f $address)
    }
}

function Find-Pattern($handle, [UInt64]$base, [int]$size, [byte[]]$pattern, [bool[]]$mask) {
    $chunkSize = 0x400000
    $overlap = $pattern.Length
    $offset = 0
    $tail = New-Object byte[] 0

    while ($offset -lt $size) {
        $count = [Math]::Min($chunkSize, $size - $offset)
        try {
            $chunk = Read-Bytes $handle ($base + [uint64]$offset) $count
        } catch {
            $offset += $count
            $tail = New-Object byte[] 0
            continue
        }

        $scan = New-Object byte[] ($tail.Length + $chunk.Length)
        if ($tail.Length -gt 0) { [Array]::Copy($tail, 0, $scan, 0, $tail.Length) }
        [Array]::Copy($chunk, 0, $scan, $tail.Length, $chunk.Length)
        $scanBase = $base + [uint64]$offset - [uint64]$tail.Length

        for ($i = 0; $i -le $scan.Length - $pattern.Length; $i++) {
            $matched = $true
            for ($j = 0; $j -lt $pattern.Length; $j++) {
                if ($mask[$j] -and $scan[$i + $j] -ne $pattern[$j]) {
                    $matched = $false
                    break
                }
            }
            if ($matched) { return $scanBase + [uint64]$i }
        }

        $keep = [Math]::Min($overlap, $scan.Length)
        $tail = New-Object byte[] $keep
        [Array]::Copy($scan, $scan.Length - $keep, $tail, 0, $keep)
        $offset += $count
    }
    return 0
}

function Resolve-GEngineAddress($ctx) {
    $module = $ctx.Process.MainModule
    $base = [uint64]$module.BaseAddress.ToInt64()
    $size = [int]$module.ModuleMemorySize

    $pattern = [byte[]](0x48,0x8B,0x05,0,0,0,0,0x48,0x8B,0x88,0x80,0x0A,0x00,0x00)
    $mask = [bool[]]($true,$true,$true,$false,$false,$false,$false,$true,$true,$true,$true,$true,$true,$true)
    $match = Find-Pattern $ctx.Handle $base $size $pattern $mask
    if ($match -eq 0) { throw "pGEngine pattern not found" }

    $disp = Read-I32 $ctx.Handle ($match + 3)
    $gEnginePtrAddress = [uint64]([int64]$match + 7 + $disp)
    $gEngine = Read-U64 $ctx.Handle $gEnginePtrAddress
    if ($gEngine -eq 0) { throw "GEngine is null, save may not be loaded" }
    return [pscustomobject]@{ PointerAddress = $gEnginePtrAddress; GEngine = $gEngine }
}

function Resolve-RootAddress($ctx) {
    $ge = Resolve-GEngineAddress $ctx
    $localPlayersArray = Read-U64 $ctx.Handle ($ge.GEngine + 0x10A8)
    if ($localPlayersArray -eq 0) { throw "LocalPlayers array is null" }
    $localPlayersData = Read-U64 $ctx.Handle ($localPlayersArray + 0x38)
    if ($localPlayersData -eq 0) { throw "LocalPlayers data is null" }
    $localPlayer = Read-U64 $ctx.Handle $localPlayersData
    if ($localPlayer -eq 0) { throw "LocalPlayer is null" }
    $pc = Read-U64 $ctx.Handle ($localPlayer + 0x30)
    if ($pc -eq 0) { throw "PlayerController is null" }
    $pawn = Read-U64 $ctx.Handle ($pc + 0x2D0)
    if ($pawn -eq 0) { throw "Pawn is null" }
    $root = Read-U64 $ctx.Handle ($pawn + 0x1A0)
    if ($root -eq 0) { throw "RootComponent is null" }
    return [pscustomobject]@{ Root = $root; Pawn = $pawn; PlayerController = $pc; GEngine = $ge.GEngine }
}

function Invoke-MemoryTeleport([double]$x, [double]$y, [double]$z, [string]$name) {
    $ctx = $null
    try {
        $ctx = Open-GameProcess
        $rootInfo = Resolve-RootAddress $ctx
        $coord = $rootInfo.Root + 0x1F0
        $beforeX = Read-F64 $ctx.Handle $coord
        $beforeY = Read-F64 $ctx.Handle ($coord + 8)
        $beforeZ = Read-F64 $ctx.Handle ($coord + 16)
        Write-Diag ("REQUEST name={0} target={1:N1},{2:N1},{3:N1} root=0x{4:X} before={5:N1},{6:N1},{7:N1}" -f $name,$x,$y,$z,$rootInfo.Root,$beforeX,$beforeY,$beforeZ)
        Write-State "BUSY" "memory bridge writing"

        for ($i = 0; $i -le 150; $i++) {
            Write-F64 $ctx.Handle $coord $x
            Write-F64 $ctx.Handle ($coord + 8) $y
            Write-F64 $ctx.Handle ($coord + 16) $z
            Start-Sleep -Milliseconds 5
        }

        $afterX = Read-F64 $ctx.Handle $coord
        $afterY = Read-F64 $ctx.Handle ($coord + 8)
        $afterZ = Read-F64 $ctx.Handle ($coord + 16)
        $dist = [Math]::Sqrt([Math]::Pow($afterX - $x, 2) + [Math]::Pow($afterY - $y, 2) + [Math]::Pow($afterZ - $z, 2))
        if ($dist -lt 250.0) {
            Write-Diag ("SUCCESS name={0} readback={1:N1},{2:N1},{3:N1} dist={4:N1}" -f $name,$afterX,$afterY,$afterZ,$dist)
            Write-State "SUCCESS" ("memory bridge wrote: {0}" -f $name)
        } else {
            Write-Diag ("FAILED name={0} readback={1:N1},{2:N1},{3:N1} dist={4:N1}" -f $name,$afterX,$afterY,$afterZ,$dist)
            Write-State "FAILED" ("readback not at target: {0:N1}" -f $dist)
        }
    } catch {
        Write-Diag ("ERROR " + $_.Exception.Message)
        Write-State "FAILED" $_.Exception.Message
    } finally {
        if ($ctx -and $ctx.Handle -ne [IntPtr]::Zero) {
            [void][MemBridgeNative]::CloseHandle($ctx.Handle)
        }
    }
}

function Process-Line([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $parts = $line.Trim().Split('|')
    if ($parts.Length -lt 4) { return }
    $cmd = $parts[0].Trim().ToUpperInvariant()
    if ($cmd -ne "TELEPORT_COORD" -and $cmd -ne "TP_COORD") { return }
    $x = 0.0; $y = 0.0; $z = 0.0
    if (-not [double]::TryParse($parts[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { throw "invalid X coordinate" }
    if (-not [double]::TryParse($parts[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$y)) { throw "invalid Y coordinate" }
    if (-not [double]::TryParse($parts[3], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$z)) { throw "invalid Z coordinate" }
    $name = if ($parts.Length -ge 5) { $parts[4] } else { "coordinate" }
    Invoke-MemoryTeleport $x $y $z $name
}

try {
    if (-not (Test-Path -LiteralPath $actionsPath)) {
        [System.IO.File]::WriteAllText($actionsPath, "", [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText($diagPath, "[{0:yyyy-MM-dd HH:mm:ss}] TeleportMemoryBridge started`r`n" -f (Get-Date), [System.Text.UTF8Encoding]::new($false))
    Write-State "IDLE" "memory bridge started"
    $lastLength = (Get-Item -LiteralPath $actionsPath -ErrorAction SilentlyContinue).Length

    while ($true) {
        if (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            Write-State "IDLE" "waiting for game process"
            Start-Sleep -Seconds 2
            continue
        }

        $item = Get-Item -LiteralPath $actionsPath -ErrorAction SilentlyContinue
        if ($item) {
            if ($item.Length -lt $lastLength) { $lastLength = 0 }
            if ($item.Length -gt $lastLength) {
                $fs = [System.IO.File]::Open($actionsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $fs.Seek($lastLength, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $reader = New-Object System.IO.StreamReader($fs, [System.Text.UTF8Encoding]::new($false))
                    $text = $reader.ReadToEnd()
                    $lastLength = $item.Length
                    foreach ($line in ($text -split "`r?`n")) {
                        Process-Line $line
                    }
                } finally {
                    $fs.Close()
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
} finally {
    Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
}
