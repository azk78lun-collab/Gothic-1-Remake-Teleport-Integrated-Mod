[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("G1RModUiNativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class G1RModUiNativeMethods
{
    public const int SW_MINIMIZE = 6;
    public const int SW_RESTORE = 9;

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    public static bool ForceForeground(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;

        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = GetWindowThreadProcessId(foreground, IntPtr.Zero);
        uint currentThread = GetCurrentThreadId();
        bool attached = false;

        try
        {
            if (foregroundThread != 0 && foregroundThread != currentThread)
            {
                attached = AttachThreadInput(currentThread, foregroundThread, true);
            }

            ShowWindowAsync(hWnd, SW_RESTORE);
            BringWindowToTop(hWnd);
            return SetForegroundWindow(hWnd);
        }
        finally
        {
            if (attached)
            {
                AttachThreadInput(currentThread, foregroundThread, false);
            }
        }
    }
}
"@
}

# Global error trap: log to file so silent failures become visible
trap {
    $errPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "TeleportModUI_error.log"
    $msg = "[{0:yyyy-MM-dd HH:mm:ss}] FATAL: {1}`n  at {2}`n" -f (Get-Date), $_.Exception.Message, $_.InvocationInfo.PositionMessage
    [System.IO.File]::AppendAllText($errPath, $msg, [System.Text.UTF8Encoding]::new($false))
    break
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$windowTitle = "Gothic 1 Remake - Mod 管理"

# Compute paths early (required by singleton check below)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$win64Dir = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "..\.."))
$uiActiveFlagPath = Join-Path $win64Dir "TeleportMod_ui_active.flag"
$uiControlPath = Join-Path $win64Dir "TeleportMod_ui_control.txt"
$script:uiErrorLogPath = Join-Path $scriptDir "TeleportModUI_error.log"
$script:uiErrorLastWrite = @{}

function Write-UiErrorLog([string]$message) {
    try {
        $keyEnd = $message.IndexOf(":")
        $key = if ($keyEnd -gt 0) { $message.Substring(0, $keyEnd) } else { $message }
        $now = [DateTime]::UtcNow
        if ($script:uiErrorLastWrite.ContainsKey($key)) {
            $elapsed = ($now - $script:uiErrorLastWrite[$key]).TotalSeconds
            if ($elapsed -lt 10.0) { return }
        }
        $script:uiErrorLastWrite[$key] = $now

        if (Test-Path -LiteralPath $script:uiErrorLogPath) {
            $logInfo = Get-Item -LiteralPath $script:uiErrorLogPath -ErrorAction SilentlyContinue
            if ($logInfo -and $logInfo.Length -gt 524288) {
                $archivePath = "$($script:uiErrorLogPath).previous"
                Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $script:uiErrorLogPath -Destination $archivePath -Force
            }
        }
        $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}`r`n" -f (Get-Date), $message
        [System.IO.File]::AppendAllText($script:uiErrorLogPath, $line, [System.Text.UTF8Encoding]::new($false))
    } catch {
    }
}

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $eventArgs)
    $message = "UI事件错误: " + $eventArgs.Exception.Message
    Write-UiErrorLog ("UI事件错误: " + $eventArgs.Exception.ToString())
    try {
        if ($script:statusLabel) {
            $script:statusLabel.Text = $message
        }
    } catch {
    }
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $eventArgs)
    Write-UiErrorLog ("未处理错误: " + $eventArgs.ExceptionObject.ToString())
})

function Invoke-UiInitStep([string]$name, [scriptblock]$scriptBlock) {
    try {
        & $scriptBlock
    } catch {
        Write-UiErrorLog ("初始化步骤失败 [{0}]: {1}`r`n{2}" -f $name, $_.Exception.Message, $_.Exception.ToString())
        try {
            if ($script:statusLabel) {
                $script:statusLabel.Text = "初始化部分失败: $name，其他功能继续可用。"
            }
        } catch {
        }
    }
}

# Robust singleton: check flag file first to detect stale processes
$stalePid = $null
if (Test-Path -LiteralPath $uiActiveFlagPath) {
    try {
        $flagContent = [System.IO.File]::ReadAllText($uiActiveFlagPath, [System.Text.UTF8Encoding]::new($false))
        if ($flagContent -match 'PID=(\d+)') {
            $stalePid = [int]$Matches[1]
            $staleProc = Get-Process -Id $stalePid -ErrorAction SilentlyContinue
            if (-not $staleProc) {
                # Process is dead - clear stale flag
                Remove-Item -LiteralPath $uiActiveFlagPath -Force -ErrorAction SilentlyContinue
            } else {
                # A second launcher means the game requested the existing UI.
                $line = "ACTION=SHOW`nTIME={0}`n" -f ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
                [System.IO.File]::WriteAllText($uiControlPath, $line, [System.Text.UTF8Encoding]::new($false))
                exit
            }
        }
    } catch {
        # Flag file corrupted or inaccessible - clear it
        Remove-Item -LiteralPath $uiActiveFlagPath -Force -ErrorAction SilentlyContinue
    }
}

# Now try Mutex with timeout (handles abandoned Mutex from killed processes)
$script:singletonMutex = New-Object System.Threading.Mutex($false, "Gothic1Remake_ModUI_Singleton")
try {
    $script:singletonAcquired = $script:singletonMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # Previous owner crashed - we now own it
    $script:singletonAcquired = $true
}

function Activate-WindowByProcessId([int]$processId) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        return [bool]$shell.AppActivate($processId)
    } catch {
        return $false
    }
}
if (-not $script:singletonAcquired) {
    try {
        $line = "ACTION=SHOW`nTIME={0}`n" -f ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        [System.IO.File]::WriteAllText($uiControlPath, $line, [System.Text.UTF8Encoding]::new($false))
    } catch {
    }
    exit
}

# Capture the game process at startup so we can detect when it exits
$script:gameProcessName = "G1R-Win64-Shipping"
$script:gameProcessId = $null
$script:gameProcessWasPresentAtStartup = $false
$gameProc = Get-Process -Name $script:gameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gameProc) {
    $script:gameProcessId = $gameProc.Id
    $script:gameProcessWasPresentAtStartup = $true
}

$spotsPath = Join-Path $win64Dir "TeleportMod_spots.ini"
$actionsPath = Join-Path $win64Dir "TeleportMod_actions.txt"
$hotkeyPath = Join-Path $win64Dir "TeleportMod_hotkeys.ini"
$script:teleportStatusPath = Join-Path $win64Dir "TeleportMod_status.txt"
$script:teleportDiagPath = Join-Path $win64Dir "TeleportMod_diag.txt"
$script:teleportMemActionsPath = Join-Path $win64Dir "TeleportMod_mem_actions.txt"
$script:teleportMemStatusPath = Join-Path $win64Dir "TeleportMod_mem_status.txt"
$script:teleportMemDiagPath = Join-Path $win64Dir "TeleportMod_mem_diag.txt"
$script:teleportMemBridgePath = Join-Path $scriptDir "TeleportMemoryBridge.ps1"
$script:teleportCppActionsPath = Join-Path $win64Dir "TeleportMod_cpp_actions.txt"
$script:teleportCppStatusPath = Join-Path $win64Dir "TeleportMod_cpp_status.txt"
$script:teleportCppDiagPath = Join-Path $win64Dir "TeleportMod_cpp_diag.txt"
$script:teleportCppBridgePath = Join-Path $scriptDir "TeleportCppBridge.exe"
$script:focusHighlightControlPath = Join-Path $win64Dir "FocusNearbyPickups_control.txt"
$script:focusHighlightStatusPath = Join-Path $win64Dir "FocusNearbyPickups_status.txt"
$script:npcScanResultPath = Join-Path $win64Dir "TeleportMod_npc_scan.tsv"
$script:npcScanStatePath = Join-Path $win64Dir "TeleportMod_npc_scan_state.txt"
$script:npcScanHistoryPath = Join-Path $win64Dir "TeleportMod_npc_scan_history.tsv"
$script:npcPullRequestPath = Join-Path $win64Dir "TeleportMod_npc_pull_request.tsv"
$script:npcPullStatusPath = Join-Path $win64Dir "TeleportMod_npc_pull_status.txt"
$script:npcPullResultPath = Join-Path $win64Dir "TeleportMod_npc_pull_result.tsv"
$script:ue4ssLogPath = Join-Path $win64Dir "UE4SS.log"
$walkthroughPath = Join-Path $scriptDir "WalkthroughGuide.txt"
$script:moneyCandidates = New-Object System.Collections.Generic.List[object]
$script:attrCandidates = New-Object System.Collections.Generic.List[object]
$script:walkthroughEntries = New-Object System.Collections.Generic.List[object]
$script:npcScanItems = @()
$script:npcScanHistoryItems = @()
$script:npcScanCurrentGroupExpanded = @{}
$script:npcScanHistoryGroupExpanded = @{}
$script:npcSuppressContextMenuOnce = $false
$script:npcPullPendingRequestId = $null
$script:npcPullDeadlineUtc = [DateTime]::MinValue
$script:npcPullTimer = $null
$script:moneyStatePath = Join-Path $win64Dir "TeleportMod_money_state.txt"
$script:moneyActionsPath = Join-Path $win64Dir "TeleportMod_money_actions.txt"
$script:attrStatePath = Join-Path $win64Dir "TeleportMod_player_state.txt"
$script:attrActionsPath = Join-Path $win64Dir "TeleportMod_player_actions.txt"
$script:playerEditDiagPath = Join-Path $win64Dir "TeleportMod_player_diag.txt"
$script:playerEditBridgePath = Join-Path $scriptDir "PlayerEditCppBridge.exe"
$script:itemCatalogPath = Join-Path $scriptDir "TeleportMod_items.tsv"
$script:itemNameOverridesPath = Join-Path $scriptDir "TeleportMod_item_names_zh.tsv"
$script:itemStatePath = Join-Path $win64Dir "TeleportMod_item_state.txt"
$script:itemInventoryStatePath = Join-Path $win64Dir "TeleportMod_inventory_state.txt"
$script:itemInventoryListPath = Join-Path $win64Dir "TeleportMod_inventory_list.txt"
$script:itemActionsPath = Join-Path $win64Dir "TeleportMod_item_actions.txt"
$script:itemSnapshotDir = Join-Path $scriptDir "InventorySnapshots"
$script:unlockStatePath = Join-Path $win64Dir "G1R_NoChestLocks_state.txt"
$script:unlockControlPath = Join-Path $win64Dir "G1R_NoChestLocks_control.txt"
$script:moneyStateTimer = $null
$script:moneyStateLastWrite = $null
$script:attrStateTimer = $null
$script:attrStateLastWrite = $null
$script:itemStateTimer = $null
$script:itemStateLastWrite = $null
$script:itemInventoryStateLastWrite = $null
$script:itemInventoryListTimer = $null
$script:itemInventoryListLastWrite = $null
$script:itemCategorySyncing = $false
$script:unlockStateTimer = $null
$script:unlockStateLastWrite = $null
$script:unlockSyncing = $false
$script:spotsFileTimer = $null
$script:spotsLastWrite = $null
$script:teleportStatusTimer = $null
$script:teleportStatusLastWrite = $null
$script:teleportStatusActivePath = ""
$script:teleportRemoteState = "UNKNOWN"
$script:teleportRemoteMessage = ""
$script:teleportLocalCooldownUntil = [DateTime]::MinValue
$script:highlightSyncing = $false
$script:teleportBridgeMode = "Lua"
$script:uiControlTimer = $null
$script:uiControlLastWrite = $null
$script:noClipUiSyncing = $false
$script:uiActiveHeartbeatLast = [DateTime]::MinValue
$script:uiIsShown = $true
$script:uiLastF6ToggleUtc = [DateTime]::MinValue
$script:uiF6ReadyUtc = [DateTime]::UtcNow.AddMilliseconds(1200)
$script:userTopMostEnabled = $false
$script:spotGroupExpanded = @{}
$script:pendingSpotGroupFocus = $null
$script:itemCatalog = New-Object System.Collections.Generic.List[object]
$script:itemNameOverrides = @{}
$script:inventoryItems = New-Object System.Collections.Generic.List[object]
$script:inventoryGroupExpanded = @{}
$script:pendingInventoryGroupFocus = $null
$script:lastInventorySnapshotPath = ""

function Clear-ActionFiles {
    Remove-Item -LiteralPath $actionsPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:teleportMemActionsPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:teleportCppActionsPath -Force -ErrorAction SilentlyContinue
}
Clear-ActionFiles

$script:attributeDefinitions = @(
    [pscustomobject]@{ Key = "Level"; Name = "等级"; Current = "1"; Write = "20" },
    [pscustomobject]@{ Key = "Experience"; Name = "经验值"; Current = "0"; Write = "10000" },
    [pscustomobject]@{ Key = "SkillPoints"; Name = "技能点"; Current = "0"; Write = "10" },
    [pscustomobject]@{ Key = "Health"; Name = "生命值"; Current = "100"; Write = "500" },
    [pscustomobject]@{ Key = "MaxHealth"; Name = "最大生命"; Current = "100"; Write = "500" },
    [pscustomobject]@{ Key = "Mana"; Name = "法力值"; Current = "50"; Write = "200" },
    [pscustomobject]@{ Key = "MaxMana"; Name = "最大法力"; Current = "50"; Write = "200" },
    [pscustomobject]@{ Key = "Strength"; Name = "力量"; Current = "10"; Write = "100" },
    [pscustomobject]@{ Key = "Dexterity"; Name = "敏捷"; Current = "10"; Write = "100" }
)

function Read-FileShareSafe([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        $reader.Close()
        $fs.Close()
        if ([string]::IsNullOrEmpty($content)) { return @() }
        return $content -split "`r?`n"
    } catch {
        return @()
    }
}

function Read-Spots {
    $spots = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $spotsPath)) { return $spots }

    $index = 0
    foreach ($line in Read-FileShareSafe $spotsPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        if ($parts.Length -lt 4) { continue }
        $index++
        [void]$spots.Add([pscustomobject]@{
            Index = $index
            Name = $parts[0]
            X = $parts[1]
            Y = $parts[2]
            Z = $parts[3]
        })
    }
    return $spots
}

function Append-Action([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    $isTeleport = $line -match '^(TELEPORT_COORD|TP_COORD)\|'
    if ($isTeleport) {
        Disable-FocusHighlightForTeleport
    }

    if (-not $isTeleport -or $script:teleportBridgeMode -eq "Lua") {
        [System.IO.File]::AppendAllText(
            $actionsPath,
            $line + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    if ($isTeleport) {
        $bridgeActionsPath = if ($script:teleportBridgeMode -eq "CPP") {
            $script:teleportCppActionsPath
        } elseif ($script:teleportBridgeMode -eq "MEM") {
            $script:teleportMemActionsPath
        } else {
            $null
        }
        if (-not $bridgeActionsPath) { return }
        try {
            [System.IO.File]::AppendAllText(
                $bridgeActionsPath,
                $line + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false)
            )
        } catch {
            Write-UiErrorLog ("写入瞬移桥动作失败: " + $_.Exception.Message)
        }
    }
}

function Ensure-TeleportCppBridge {
    try {
        if (-not (Test-Path -LiteralPath $script:teleportCppBridgePath)) {
            return $false
        }
        $flagPath = Join-Path $win64Dir "TeleportMod_cpp_bridge.pid"
        if (Test-Path -LiteralPath $flagPath) {
            try {
                $pidText = [System.IO.File]::ReadAllText($flagPath).Trim()
                $bridgePid = [int]$pidText
                $bridgeProcess = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
                $actualBridgePath = if ($bridgeProcess) {
                    [System.IO.Path]::GetFullPath([string]$bridgeProcess.Path)
                } else {
                    ""
                }
                $expectedBridgePath = [System.IO.Path]::GetFullPath($script:teleportCppBridgePath)
                if ([string]::Equals($actualBridgePath, $expectedBridgePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $script:teleportBridgeMode = "CPP"
                    return $true
                }
                Write-UiErrorLog ("检测到失效的C++瞬移桥PID缓存，已自动清理: PID={0}" -f $bridgePid)
                Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
            } catch {
                Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
            }
        }

        $args = '-Win64Dir "{0}"' -f $win64Dir
        Start-Process -FilePath $script:teleportCppBridgePath -ArgumentList $args -WorkingDirectory $scriptDir -WindowStyle Hidden | Out-Null

        # CppBridge 启动后会写 IDLE 到状态文件，TeleportStatusTimer 会自动检测就绪
        # 不再同步等待 3 秒，让 UI 即时显示

        $script:teleportBridgeMode = "CPP"
        return $true
    } catch {
        Write-UiErrorLog ("启动C++瞬移桥失败: " + $_.Exception.Message)
        return $false
    }
}

function Ensure-PlayerEditCppBridge {
    try {
        if (-not (Test-Path -LiteralPath $script:playerEditBridgePath)) {
            Set-AttrStatus "人物属性桥未找到，请先编译 PlayerEditCppBridge.exe。"
            return $false
        }
        $flagPath = Join-Path $win64Dir "TeleportMod_player_bridge.pid"
        if (Test-Path -LiteralPath $flagPath) {
            try {
                $pidText = [System.IO.File]::ReadAllText($flagPath).Trim()
                $bridgePid = [int]$pidText
                if (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue) {
                    return $true
                }
            } catch {
                Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
            }
        }

        $args = '-Win64Dir "{0}"' -f $win64Dir
        Start-Process -FilePath $script:playerEditBridgePath -ArgumentList $args -WorkingDirectory $scriptDir -WindowStyle Hidden | Out-Null
        return $true
    } catch {
        Write-UiErrorLog ("启动人物属性桥失败: " + $_.Exception.Message)
        Set-AttrStatus ("启动人物属性桥失败: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Ensure-TeleportMemoryBridge {
    try {
        if (Ensure-TeleportCppBridge) {
            return
        }
        if (-not (Test-Path -LiteralPath $script:teleportMemBridgePath)) {
            Write-UiErrorLog "内存桥脚本不存在。"
            $script:teleportBridgeMode = "Lua"
            return
        }
        $flagPath = Join-Path $win64Dir "TeleportMod_mem_bridge.pid"
        if (Test-Path -LiteralPath $flagPath) {
            try {
                $pidText = [System.IO.File]::ReadAllText($flagPath).Trim()
                $bridgePid = [int]$pidText
                if (Get-Process -Id $bridgePid -ErrorAction SilentlyContinue) {
                    $script:teleportBridgeMode = "MEM"
                    return
                }
            } catch {
                Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
            }
        }

        $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Win64Dir "{1}"' -f $script:teleportMemBridgePath, $win64Dir
        Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden | Out-Null
        $script:teleportBridgeMode = "MEM"
    } catch {
        Write-UiErrorLog ("启动内存桥失败: " + $_.Exception.Message)
        $script:teleportBridgeMode = "Lua"
    }
}

function Get-TeleportRuntimeStatusPath {
    if ($script:teleportBridgeMode -eq "CPP") { return $script:teleportCppStatusPath }
    if ($script:teleportBridgeMode -eq "MEM") { return $script:teleportMemStatusPath }
    return $script:teleportStatusPath
}

function Read-TeleportStatus([string]$path) {
    $status = @{
        STATE = "UNKNOWN"
        MESSAGE = ""
    }
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]$status
    }

    foreach ($line in Read-FileShareSafe $path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -le 0) { continue }
        $key = $line.Substring(0, $idx).Trim().ToUpperInvariant()
        $value = $line.Substring($idx + 1).Trim()
        $status[$key] = $value
    }
    return [pscustomobject]$status
}

function Update-TeleportStatusCache {
    $changed = $false
    $statusPath = Get-TeleportRuntimeStatusPath
    if ($script:teleportStatusActivePath -ne $statusPath) {
        $script:teleportStatusActivePath = $statusPath
        $script:teleportStatusLastWrite = $null
        $changed = $true
    }
    if (Test-Path -LiteralPath $statusPath) {
        $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($statusPath)
        if ($script:teleportStatusLastWrite -ne $lastWrite) {
            $script:teleportStatusLastWrite = $lastWrite
            $changed = $true
        }
        $status = Read-TeleportStatus $statusPath
        $script:teleportRemoteState = ("$($status.STATE)").ToUpperInvariant()
        $script:teleportRemoteMessage = "$($status.MESSAGE)"
    } else {
        $script:teleportRemoteState = "UNKNOWN"
        $script:teleportRemoteMessage = ""
    }
    return $changed
}

function Get-TeleportBlockReason {
    $now = [DateTime]::UtcNow
    if ($now -lt $script:teleportLocalCooldownUntil) {
        $left = [Math]::Max(0, ($script:teleportLocalCooldownUntil - $now).TotalSeconds)
        return ("瞬移冷却中，请稍等 {0:N1} 秒。" -f $left)
    }

    if ($script:teleportRemoteState -eq "BUSY") {
        if ($script:teleportRemoteMessage) { return "游戏正在瞬移：$script:teleportRemoteMessage" }
        return "游戏正在瞬移，请等待完成。"
    }
    if ($script:teleportRemoteState -eq "COOLDOWN") {
        if ($script:teleportRemoteMessage) { return "瞬移冷却中：$script:teleportRemoteMessage" }
        return "瞬移冷却中，请稍等。"
    }
    return $null
}

function Set-TeleportControlsEnabled([bool]$enabled) {
    if ($teleportCoordButton) { $teleportCoordButton.Enabled = $enabled }
    if ($spotsTeleportMenuItem) { $spotsTeleportMenuItem.Enabled = $enabled }
}

function Update-TeleportControls {
    $changed = Update-TeleportStatusCache
    $blockReason = Get-TeleportBlockReason
    Set-TeleportControlsEnabled (-not $blockReason)

    if ($changed -and $script:teleportRemoteState -in @("BUSY", "COOLDOWN", "SUCCESS", "FAILED")) {
        $message = $script:teleportRemoteMessage
        if ([string]::IsNullOrWhiteSpace($message)) { $message = $script:teleportRemoteState }
        Set-Status ("瞬移状态: {0} - {1}" -f $script:teleportRemoteState, $message)
    }
}

function Send-TeleportAction([string]$line, [string]$statusMessage) {
    Ensure-TeleportMemoryBridge
    Update-TeleportStatusCache | Out-Null
    $blockReason = Get-TeleportBlockReason
    if ($blockReason) {
        Set-TeleportControlsEnabled $false
        Set-Status $blockReason
        return $false
    }

    Append-Action $line
    $script:teleportLocalCooldownUntil = [DateTime]::UtcNow.AddSeconds(4)
    Set-TeleportControlsEnabled $false
    Set-Status $statusMessage
    return $true
}

function Set-UiActiveFlag {
    $unixTime = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $text = ("PID={0}`nTIME={1}" -f $PID, $unixTime)
    [System.IO.File]::WriteAllText($uiActiveFlagPath, $text, [System.Text.UTF8Encoding]::new($false))
}

function Update-UiActiveHeartbeat {
    $now = [DateTime]::UtcNow
    if (($now - $script:uiActiveHeartbeatLast).TotalSeconds -lt 10) { return }
    $script:uiActiveHeartbeatLast = $now
    try {
        Set-UiActiveFlag
    } catch {
        Write-UiErrorLog ("刷新UI心跳失败: " + $_.Exception.Message)
    }
}

function Clear-UiActiveFlag {
    try {
        if (Test-Path -LiteralPath $uiActiveFlagPath) {
            Remove-Item -LiteralPath $uiActiveFlagPath -Force
        }
    } catch {
        # UI focus flag is only a safety guard; ignore cleanup failures.
    }
}

function Clear-UiControlFile {
    try {
        if (Test-Path -LiteralPath $uiControlPath) {
            Remove-Item -LiteralPath $uiControlPath -Force
        }
    } catch {
        # A stale toggle file is harmless; the next tick will try again.
    }
}

function Send-UiClosedNotification {
    try {
        $line = "UI_CLOSED|{0}|{1}" -f $PID, ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        [System.IO.File]::AppendAllText($actionsPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-UiErrorLog ("通知UI关闭失败: " + $_.Exception.Message)
    }
}

function Bring-UiWindowToFront {
    if (-not $form) { return }

    # Never use a temporary TopMost state here. If initialization is busy, the
    # deferred reset can be missed and leave the UI permanently above the game.
    $form.TopMost = $script:userTopMostEnabled
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }

    $form.Show()
    $form.BringToFront()
    $form.Activate()
    $activated = [G1RModUiNativeMethods]::ForceForeground($form.Handle)
    if (-not $activated) {
        [void](Activate-WindowByProcessId $PID)
    }
    $script:uiIsShown = $true
}

function Test-UiWindowIsForeground {
    if (-not $form) { return $false }
    try {
        return [G1RModUiNativeMethods]::GetForegroundWindow() -eq $form.Handle
    } catch {
        return $form.ContainsFocus
    }
}

function Minimize-UiWindowToTaskbar {
    if (-not $form) { return }

    $form.ShowInTaskbar = $true
    $form.TopMost = $script:userTopMostEnabled
    [void][G1RModUiNativeMethods]::ShowWindowAsync(
        $form.Handle,
        [G1RModUiNativeMethods]::SW_MINIMIZE
    )
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $script:uiIsShown = $false
    Set-Status "UI 已最小化到任务栏。"
}

function Toggle-UiWindowFromF6 {
    if (-not $form) { return }

    $now = [DateTime]::UtcNow
    if ($now -lt $script:uiF6ReadyUtc) { return }
    if (($now - $script:uiLastF6ToggleUtc).TotalMilliseconds -lt 800) {
        return
    }
    $script:uiLastF6ToggleUtc = $now

    if ($form.Visible -and
        $form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized -and
        (Test-UiWindowIsForeground)) {
        Minimize-UiWindowToTaskbar
    } else {
        Bring-UiWindowToFront
        Set-Status "UI 已显示并恢复前台。"
    }
}

function Show-UiWindowFromExternalF6 {
    if (-not $form) { return }

    $now = [DateTime]::UtcNow
    if (($now - $script:uiLastF6ToggleUtc).TotalMilliseconds -lt 800) {
        return
    }
    $script:uiLastF6ToggleUtc = $now
    Bring-UiWindowToFront
    Set-Status "UI 已显示并恢复前台。"
}

function Ensure-UiControlTimer {
    if ($script:uiControlTimer) { return }

    $script:uiControlTimer = New-Object System.Windows.Forms.Timer
    $script:uiControlTimer.Interval = 250
    $script:uiControlTimer.Add_Tick({
        Update-UiActiveHeartbeat
        if (-not (Test-Path -LiteralPath $uiControlPath)) { return }

        try {
            $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($uiControlPath)
            if ($script:uiControlLastWrite -eq $lastWrite) { return }
            $script:uiControlLastWrite = $lastWrite

            $lines = Read-FileShareSafe $uiControlPath
            $actionLine = $lines | Where-Object { $_ -match '^ACTION=' } | Select-Object -First 1
            $action = ""
            if ($actionLine) {
                $action = ($actionLine -replace '^ACTION=', '').Trim().ToUpperInvariant()
            }

            Clear-UiControlFile
            if ($action -eq "TOGGLE") {
                Toggle-UiWindowFromF6
            } elseif ($action -eq "SHOW") {
                Show-UiWindowFromExternalF6
            } elseif ($action -eq "FLIGHT_ON") {
                $script:noClipUiSyncing = $true
                try {
                    if ($noClipEnableCheckBox) {
                        $noClipEnableCheckBox.Checked = $true
                    }
                } finally {
                    $script:noClipUiSyncing = $false
                }
                Set-Status "F7 已开启自由飞翔。"
            } elseif ($action -eq "FLIGHT_OFF" -or $action -eq "FLIGHT_OFF_HOTKEY") {
                $script:noClipUiSyncing = $true
                try {
                    if ($noClipEnableCheckBox) {
                        $noClipEnableCheckBox.Checked = $false
                    }
                } finally {
                    $script:noClipUiSyncing = $false
                }
                if ($action -eq "FLIGHT_OFF_HOTKEY") {
                    Set-Status "F7 已关闭自由飞翔。"
                } else {
                    Set-Status "普通互动已自动关闭自由飞翔；互动或对话结束后请手动重新开启。"
                }
            }
        } catch {
            Clear-UiControlFile
        }
    })
}

function Read-NumpadBindings {
    $bindings = @{}
    if (-not (Test-Path -LiteralPath $hotkeyPath)) { return $bindings }

    foreach ($line in [System.IO.File]::ReadAllLines($hotkeyPath, [System.Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split("|")
        if ($parts.Length -lt 5) { continue }
        $key = [int]0
        if (-not [int]::TryParse($parts[0], [ref]$key)) { continue }
        if ($key -lt 0 -or $key -gt 9) { continue }
        $bindings[$key] = [pscustomobject]@{
            Key = $key
            Name = $parts[1]
            X = $parts[2]
            Y = $parts[3]
            Z = $parts[4]
        }
    }

    return $bindings
}

function Write-NumpadBindings($bindings) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in @(1,2,3,4,5,6,7,8,9,0)) {
        if (-not $bindings.ContainsKey($key)) { continue }
        $binding = $bindings[$key]
        $name = ([string]$binding.Name).Replace("|", "_").Replace("`r", " ").Replace("`n", " ").Trim()
        $x = (ConvertTo-CleanNumber ([string]$binding.X) "X轴").ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
        $y = (ConvertTo-CleanNumber ([string]$binding.Y) "Y轴").ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
        $z = (ConvertTo-CleanNumber ([string]$binding.Z) "Z轴").ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
        [void]$lines.Add(("{0}|{1}|{2}|{3}|{4}" -f $key, $name, $x, $y, $z))
    }
    [System.IO.File]::WriteAllLines($hotkeyPath, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Set-NumpadBinding([int]$keyNumber, [object]$spot) {
    if (-not $spot) { return }
    if ($keyNumber -lt 0 -or $keyNumber -gt 9) { return }

    $bindings = Read-NumpadBindings
    $bindings[$keyNumber] = [pscustomobject]@{
        Key = $keyNumber
        Name = $spot.Name
        X = $spot.X
        Y = $spot.Y
        Z = $spot.Z
    }
    Write-NumpadBindings $bindings
    Append-Action "RELOAD_HOTKEYS"
    Set-Status ("已绑定小键盘 {0}: {1}" -f $keyNumber, $spot.Name)
}

function Clear-NumpadBinding([int]$keyNumber) {
    $bindings = Read-NumpadBindings
    if ($bindings.ContainsKey($keyNumber)) {
        $bindings.Remove($keyNumber)
        Write-NumpadBindings $bindings
        Append-Action "RELOAD_HOTKEYS"
        Set-Status ("已清除小键盘 {0} 绑定。" -f $keyNumber)
    }
}

function Refresh-NumpadBindingMenus {
    if (-not $script:numpadBindMenuItems -or -not $script:numpadClearMenuItems) { return }

    $bindings = Read-NumpadBindings
    foreach ($keyNumber in @(1,2,3,4,5,6,7,8,9,0)) {
        $label = "未绑定"
        if ($bindings.ContainsKey($keyNumber)) {
            $label = $bindings[$keyNumber].Name
        }
        if ($script:numpadBindMenuItems.ContainsKey($keyNumber)) {
            $script:numpadBindMenuItems[$keyNumber].Text = ("小键盘 {0}  ->  {1}" -f $keyNumber, $label)
        }
        if ($script:numpadClearMenuItems.ContainsKey($keyNumber)) {
            $script:numpadClearMenuItems[$keyNumber].Text = ("清除小键盘 {0}  ({1})" -f $keyNumber, $label)
        }
    }
}

function Append-MoneyAction([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    [System.IO.File]::AppendAllText(
        $script:moneyActionsPath,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Append-AttrAction([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    [System.IO.File]::AppendAllText(
        $script:attrActionsPath,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function ConvertTo-MoneyNumber([string]$text, [string]$label) {
    $raw = ($text | ForEach-Object { $_.Trim() })
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "$label 不能为空。"
    }

    $value = [double]0
    $styles = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($raw, $styles, $culture, [ref]$value)) {
        $culture = [System.Globalization.CultureInfo]::CurrentCulture
        if (-not [double]::TryParse($raw, $styles, $culture, [ref]$value)) {
            throw "$label 不是有效数字。"
        }
    }

    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) {
        throw "$label 不能是无穷大或非数字。"
    }

    return $value
}

function ConvertTo-CleanNumber([string]$text, [string]$label) {
    $raw = ($text | ForEach-Object { $_.Trim() })
    $raw = $raw.Replace("，", ".").Replace("－", "-").Replace("−", "-")
    return ConvertTo-MoneyNumber $raw $label
}

function Set-MoneyStatus([string]$message) {
    $displayMessage = Convert-UiText $message
    $statusPrefix = if ($script:uiLanguage -eq "en") { "Status: " } else { "状态: " }
    if ($moneyStatusLabel) {
        $moneyStatusLabel.Text = $statusPrefix + $displayMessage
    }
    if ($script:statusLabel) {
        $script:statusLabel.Text = $displayMessage
    }
}

function Get-MoneySelectedCandidate {
    if (-not $moneyCandidateListView -or $moneyCandidateListView.SelectedItems.Count -eq 0) {
        return $null
    }
    return $moneyCandidateListView.SelectedItems[0].Tag
}

function Read-MoneyStateFile {
    if (-not (Test-Path -LiteralPath $script:moneyStatePath)) {
        return $null
    }
    $status = ""
    $message = ""
    $candidates = New-Object System.Collections.Generic.List[object]

    $lines = Read-FileShareSafe $script:moneyStatePath
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        if ($parts.Length -lt 2) { continue }

        if ($parts[0] -eq "STATUS") {
            $status = $parts[1]
            if ($parts.Length -ge 3) {
                $message = ($parts | Select-Object -Skip 2) -join "|"
            }
        } elseif ($parts[0] -eq "CAND" -and $parts.Length -ge 7) {
            $score = ""
            $pinned = 0
            try { $score = $parts[5] } catch {}
            try { $pinned = [int]$parts[6] } catch {}
            [void]$candidates.Add([pscustomobject]@{
                RootKind = $parts[1]
                Path     = $parts[2]
                Type     = $parts[3]
                Value    = $parts[4]
                Score    = $score
                Pinned   = $pinned
            })
        }
    }

    return [pscustomobject]@{
        Status     = $status
        Message    = $message
        Candidates = $candidates
    }
}

function Refresh-MoneyCandidatesList {
    if (-not $moneyCandidateListView) { return }

    $moneyCandidateListView.BeginUpdate()
    $moneyCandidateListView.Items.Clear()
    $item = New-Object System.Windows.Forms.ListViewItem("矿石")
    [void]$item.SubItems.Add("ItMi_Orenugget")
    [void]$item.SubItems.Add("背包原生增删")
    [void]$item.SubItems.Add("每次动作直接使用输入数量。")
    [void]$item.SubItems.Add("CT确认")
    [void]$moneyCandidateListView.Items.Add($item)
    $moneyCandidateListView.EndUpdate()

    if ($moneyCandidateCountLabel) {
        $moneyCandidateCountLabel.Text = "代码 ItMi_Orenugget"
    }
    if ($moneyDetailBox) {
        $moneyDetailBox.Text = "矿石使用背包原生增删，不读取当前总数。请进游戏背包确认数量变化。"
    }
}

function Apply-MoneyState($state) {
    if (-not $state) { return }
    $script:moneyCandidates.Clear()
    foreach ($c in $state.Candidates) {
        [void]$script:moneyCandidates.Add($c)
    }
    Refresh-MoneyCandidatesList
    if ($state.Message) {
        Set-MoneyStatus $state.Message
    }
}

function Get-SelectedAttributeDefinition {
    if (-not $attrSelectBox -or -not $attrSelectBox.SelectedItem) {
        return $null
    }
    return $attrSelectBox.SelectedItem
}

function Set-AttrStatus([string]$message) {
    $displayMessage = Convert-UiText $message
    $statusPrefix = if ($script:uiLanguage -eq "en") { "Status: " } else { "状态: " }
    if ($attrStatusLabel) {
        $attrStatusLabel.Text = $statusPrefix + $displayMessage
    }
    if ($script:statusLabel) {
        $script:statusLabel.Text = $displayMessage
    }
}

function Get-AttrSelectedCandidate {
    if (-not $attrCandidateListView -or $attrCandidateListView.SelectedItems.Count -eq 0) {
        return $null
    }
    return $attrCandidateListView.SelectedItems[0].Tag
}

function Read-AttrStateFile {
    if (-not (Test-Path -LiteralPath $script:attrStatePath)) {
        return $null
    }

    $state = Read-KeyValueState $script:attrStatePath
    return [pscustomobject]@{
        Status  = "$($state.STATE)"
        Message = "$($state.MESSAGE)"
        AttrKey = "$($state.ATTR)"
        Base    = "$($state.BASE)"
        Current = "$($state.CURRENT)"
    }
}

function Get-AttributeName([string]$key) {
    foreach ($def in $script:attributeDefinitions) {
        if ($def.Key -eq $key) { return $def.Name }
    }
    return $key
}

function Get-CandidatePathHint([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    $lower = $path.ToLowerInvariant()
    $displayTerms = @("hud ref", "wb_", "widget", "bar.", "render", "opacity", "material", "text", "cursor", "viewport", "trail", "als.", "customdepth", "stencil")
    foreach ($term in $displayTerms) {
        if ($lower.Contains($term)) {
            return "提示: 这条路径像界面/动画显示字段，写入后可能读回变化但游戏属性不生效。优先试 SaveLoad、Attribute、Stats、Leveling、PlayerState 这类源数据路径。"
        }
    }
    return "提示: 如果写入后游戏界面不变，说明它可能是缓存或派生字段，需要换同值候选继续试。"
}

function Refresh-AttrCandidatesList {
    if (-not $attrCandidateListView) { return }

    $attrCandidateListView.BeginUpdate()
    $attrCandidateListView.Items.Clear()
    $def = Get-SelectedAttributeDefinition
    if ($def) {
        $baseItem = New-Object System.Windows.Forms.ListViewItem($def.Name)
        [void]$baseItem.SubItems.Add("BaseValue")
        [void]$baseItem.SubItems.Add($attrCurrentValueBox.Text)
        [void]$baseItem.SubItems.Add("CT固定链")
        [void]$baseItem.SubItems.Add($def.Key)
        [void]$baseItem.SubItems.Add("")
        [void]$attrCandidateListView.Items.Add($baseItem)

        $currentItem = New-Object System.Windows.Forms.ListViewItem($def.Name)
        [void]$currentItem.SubItems.Add("CurrentValue")
        [void]$currentItem.SubItems.Add($attrCurrentValueBox.Text)
        [void]$currentItem.SubItems.Add("CT固定链")
        [void]$currentItem.SubItems.Add($def.Key)
        [void]$currentItem.SubItems.Add("")
        [void]$attrCandidateListView.Items.Add($currentItem)
    }
    $attrCandidateListView.EndUpdate()

    if ($attrCandidateCountLabel) {
        $attrCandidateCountLabel.Text = "CT固定链"
    }
}

function Apply-AttrState($state) {
    if (-not $state) { return }

    if ($state.AttrKey) {
        foreach ($item in $attrSelectBox.Items) {
            if ($item.Key -eq $state.AttrKey) {
                $attrSelectBox.SelectedItem = $item
                break
            }
        }
    }
    if ($state.Current) { $attrCurrentValueBox.Text = $state.Current }
    if ($state.Base -and $attrDetailBox) {
        $attrDetailBox.Text = ("属性: {0}`r`nBaseValue: {1}`r`nCurrentValue: {2}`r`n状态: {3}`r`n消息: {4}" -f (Get-AttributeName $state.AttrKey), $state.Base, $state.Current, $state.Status, $state.Message)
    }
    Refresh-AttrCandidatesList
    if ($state.Message) {
        Set-AttrStatus $state.Message
    }
}

function Append-ItemAction([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    [System.IO.File]::AppendAllText(
        $script:itemActionsPath,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-KeyValueState([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $result = @{}
    foreach ($line in Read-FileShareSafe $path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -le 0) { continue }
        $key = $line.Substring(0, $idx).Trim().ToUpperInvariant()
        $value = $line.Substring($idx + 1).Trim()
        $result[$key] = $value
    }
    return [pscustomobject]$result
}

function Set-ItemStatus([string]$message) {
    $displayMessage = Convert-UiText $message
    $statusPrefix = if ($script:uiLanguage -eq "en") { "Status: " } else { "状态: " }
    if ($itemStatusLabel) {
        $itemStatusLabel.Text = $statusPrefix + $displayMessage
    }
    if ($script:statusLabel) {
        $script:statusLabel.Text = $displayMessage
    }
}

function Set-UnlockStatus([string]$message) {
    if ($unlockStatusLabel) {
        $unlockStatusLabel.Text = "开锁: $message"
    }
    if ($script:statusLabel) {
        $script:statusLabel.Text = $message
    }
}

function Read-ItemCatalog {
    $script:itemCatalog.Clear()
    if (-not (Test-Path -LiteralPath $script:itemCatalogPath)) { return }

    $first = $true
    $seenCodes = New-Object "System.Collections.Generic.HashSet[string]"
    foreach ($line in Read-FileShareSafe $script:itemCatalogPath) {
        if ($first) {
            $first = $false
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Length -lt 4) { continue }
        $code = $parts[1].Trim()
        $lowerCode = $code.ToLowerInvariant()
        if ($seenCodes.Contains($lowerCode)) { continue }
        [void]$seenCodes.Add($lowerCode)
        [void]$script:itemCatalog.Add([pscustomobject]@{
            Category = $parts[0]
            Code     = $code
            Command  = $parts[2]
            Path     = $parts[3]
            Name     = if ($parts.Length -ge 5) { $parts[4] } else { "" }
        })
    }
}

function Read-ItemNameOverrides {
    $script:itemNameOverrides = @{}
    if (-not (Test-Path -LiteralPath $script:itemNameOverridesPath)) { return }

    $first = $true
    foreach ($line in Read-FileShareSafe $script:itemNameOverridesPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($first -and $line -match '^Code\t') {
            $first = $false
            continue
        }
        $first = $false
        $parts = $line -split "`t"
        if ($parts.Length -lt 2) { continue }
        $code = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $script:itemNameOverrides[$code.ToLowerInvariant()] = [pscustomobject]@{
            Code = $code
            Name = if ($parts.Length -ge 2) { $parts[1].Trim() } else { "" }
            Category = if ($parts.Length -ge 3) { $parts[2].Trim() } else { "" }
            Note = if ($parts.Length -ge 4) { $parts[3].Trim() } else { "" }
        }
    }
}

function Find-ItemCatalogEntry([string]$code) {
    if ([string]::IsNullOrWhiteSpace($code)) { return $null }
    foreach ($entry in $script:itemCatalog) {
        if ($entry -and ([string]$entry.Code).Equals($code, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry
        }
    }
    return $null
}

function Get-ItemDisplayInfo([string]$code) {
    $name = ""
    $category = ""
    $source = "未知"
    $key = if ($code) { $code.ToLowerInvariant() } else { "" }

    if ($key -and $script:itemNameOverrides.ContainsKey($key)) {
        $override = $script:itemNameOverrides[$key]
        $name = [string]$override.Name
        $category = [string]$override.Category
        $source = "中文覆盖"
    }

    $catalog = Find-ItemCatalogEntry $code
    if ($catalog) {
        if ([string]::IsNullOrWhiteSpace($category)) { $category = [string]$catalog.Category }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$catalog.Name }
        if ($source -eq "未知") { $source = "物品表" }
    }

    if ($category -eq "Herb") { $category = "草本植物" }

    if ([string]::IsNullOrWhiteSpace($category)) { $category = "背包未知" }

    return [pscustomobject]@{
        Name = $name
        Category = $category
        Source = $source
    }
}

function Write-ItemNameOverrides {
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Code`tNameZh`tCategoryZh`tNote")

    foreach ($key in ($script:itemNameOverrides.Keys | Sort-Object)) {
        $override = $script:itemNameOverrides[$key]
        if (-not $override) { continue }
        $code = [string]$override.Code
        if ([string]::IsNullOrWhiteSpace($code)) { continue }

        $name = ([string]$override.Name).Replace("`t", " ").Replace("`r", " ").Replace("`n", " ").Trim()
        $category = ([string]$override.Category).Replace("`t", " ").Replace("`r", " ").Replace("`n", " ").Trim()
        $note = ([string]$override.Note).Replace("`t", " ").Replace("`r", " ").Replace("`n", " ").Trim()
        [void]$lines.Add(("{0}`t{1}`t{2}`t{3}" -f $code, $name, $category, $note))
    }

    $dir = Split-Path -Parent $script:itemNameOverridesPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllLines($script:itemNameOverridesPath, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Set-ItemNameOverride([string]$code, [string]$name) {
    if ([string]::IsNullOrWhiteSpace($code)) { return }
    $code = $code.Trim()
    $key = $code.ToLowerInvariant()
    $name = ([string]$name).Trim()

    $existing = $null
    if ($script:itemNameOverrides.ContainsKey($key)) {
        $existing = $script:itemNameOverrides[$key]
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        if ($script:itemNameOverrides.ContainsKey($key)) {
            $script:itemNameOverrides.Remove($key)
        }
    } else {
        $script:itemNameOverrides[$key] = [pscustomobject]@{
            Code = if ($existing -and $existing.Code) { [string]$existing.Code } else { $code }
            Name = $name
            Category = if ($existing) { [string]$existing.Category } else { "" }
            Note = if ($existing) { [string]$existing.Note } else { "UI命名" }
        }
    }

    Write-ItemNameOverrides
    Refresh-ItemCategories
    Refresh-ItemList
    Apply-InventoryListFile
}

function Show-ItemRenameDialog([object]$entry) {
    if (-not $entry) { return }

    $display = Get-ItemDisplayInfo ([string]$entry.Code)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "命名物品"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(420, 154)
    $dialog.ShowInTaskbar = $false

    $codeLabel = New-Object System.Windows.Forms.Label
    $codeLabel.Text = "代码: $($entry.Code)"
    $codeLabel.AutoSize = $true
    $codeLabel.Location = New-Object System.Drawing.Point(14, 16)

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = "中文名"
    $nameLabel.AutoSize = $true
    $nameLabel.Location = New-Object System.Drawing.Point(14, 52)

    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Location = New-Object System.Drawing.Point(72, 48)
    $nameBox.Width = 328
    $nameBox.Text = [string]$display.Name

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "确定"
    $okButton.Width = 84
    $okButton.Location = New-Object System.Drawing.Point(222, 104)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "取消"
    $cancelButton.Width = 84
    $cancelButton.Location = New-Object System.Drawing.Point(316, 104)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    $dialog.Controls.AddRange(@($codeLabel, $nameLabel, $nameBox, $okButton, $cancelButton))
    Set-ControlColors $dialog

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-ItemNameOverride ([string]$entry.Code) $nameBox.Text
        Set-ItemStatus ("已更新中文名: {0}" -f $entry.Code)
    }
}

function Read-InventoryPipeStatus([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $status = $null
    $message = ""
    $result = $null
    foreach ($line in Read-FileShareSafe $path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        if ($parts.Length -lt 1) { continue }
        switch ($parts[0]) {
            "STATUS" {
                if ($parts.Length -ge 2) { $status = $parts[1] }
                if ($parts.Length -ge 3) { $message = $parts[2] }
            }
            "NATIVE_RESULT" {
                $result = $parts
            }
        }
    }
    if (-not $status -and -not $result) { return $null }
    return [pscustomobject]@{
        Status = $status
        Message = $message
        Result = $result
    }
}

function Apply-InventoryActionState($state) {
    if (-not $state) { return }
    $text = if ($state.Message) { $state.Message } else { $state.Status }
    if ($state.Result -and $state.Result.Length -ge 6) {
        $text = ("背包{0}: {1} x{2} ({3})" -f $state.Result[1], $state.Result[2], $state.Result[3], $state.Result[4])
    }
    if ($inventoryStatusLabel) {
        $inventoryStatusLabel.Text = "背包: $text"
    }
    Set-ItemStatus "背包: $text"
    if ($script:statusLabel) {
        $script:statusLabel.Text = $text
    }
}

function Read-InventoryListFile {
    $items = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:itemInventoryListPath)) { return $items }

    foreach ($line in Read-FileShareSafe $script:itemInventoryListPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        if ($parts.Length -lt 3 -or $parts[0] -ne "ITEM") { continue }

        $code = $parts[1].Trim()
        $qty = 0
        if (-not [int]::TryParse($parts[2].Trim(), [ref]$qty)) { $qty = 1 }
        if ($qty -lt 1) { $qty = 1 }

        $display = Get-ItemDisplayInfo $code
        [void]$items.Add([pscustomobject]@{
            Code = $code
            Qty = $qty
            Name = $display.Name
            Category = $display.Category
            DisplaySource = $display.Source
            ClassName = if ($parts.Length -ge 4) { $parts[3] } else { "" }
            Source = if ($parts.Length -ge 5) { $parts[4] } else { "" }
        })
    }

    return $items
}

function Apply-InventoryListFile {
    $script:inventoryItems.Clear()
    foreach ($item in Read-InventoryListFile) {
        [void]$script:inventoryItems.Add($item)
    }
    Refresh-InventoryList
    $state = Read-InventoryPipeStatus $script:itemInventoryListPath
    if ($state) { Apply-InventoryActionState $state }
}

function Test-InventoryGroupTag([object]$tag) {
    return ($tag -and $tag.PSObject.Properties["IsInventoryGroup"] -and $tag.IsInventoryGroup)
}

function Toggle-InventoryGroup([string]$groupName) {
    if ([string]::IsNullOrWhiteSpace($groupName)) { return }
    if (-not $script:inventoryGroupExpanded.ContainsKey($groupName)) {
        $script:inventoryGroupExpanded[$groupName] = $true
    }
    $script:inventoryGroupExpanded[$groupName] = -not [bool]$script:inventoryGroupExpanded[$groupName]
    $script:pendingInventoryGroupFocus = $groupName
    Refresh-InventoryList
}

function Get-SelectedInventoryEntry {
    if (-not $inventoryListView -or $inventoryListView.SelectedItems.Count -eq 0) { return $null }
    if (Test-InventoryGroupTag $inventoryListView.SelectedItems[0].Tag) { return $null }
    return $inventoryListView.SelectedItems[0].Tag
}

function Refresh-InventoryList {
    if (-not $inventoryListView) { return }

    $search = ""
    if ($inventorySearchBox) { $search = $inventorySearchBox.Text.Trim().ToLowerInvariant() }

    $groups = @{}
    foreach ($entry in $script:inventoryItems) {
        if (-not $entry) { continue }
        if ($search) {
            $haystack = ("{0} {1} {2} {3}" -f $entry.Name, $entry.Code, $entry.Category, $entry.Source).ToLowerInvariant()
            if (-not $haystack.Contains($search)) { continue }
        }

        $groupName = if ($entry.Category) { [string]$entry.Category } else { "背包未知" }
        if (-not $groups.ContainsKey($groupName)) {
            $groups[$groupName] = New-Object System.Collections.Generic.List[object]
        }
        [void]$groups[$groupName].Add($entry)
    }

    $inventoryListView.BeginUpdate()
    $inventoryListView.Items.Clear()

    $visibleCount = 0
    foreach ($groupName in ($groups.Keys | Sort-Object)) {
        if (-not $script:inventoryGroupExpanded.ContainsKey($groupName)) {
            $script:inventoryGroupExpanded[$groupName] = $true
        }
        $expanded = [bool]$script:inventoryGroupExpanded[$groupName]
        $marker = if ($expanded) { "[-]" } else { "[+]" }
        $groupItem = New-Object System.Windows.Forms.ListViewItem(("{0} {1} ({2})" -f $marker, $groupName, $groups[$groupName].Count))
        [void]$groupItem.SubItems.Add("")
        [void]$groupItem.SubItems.Add("")
        [void]$groupItem.SubItems.Add("点击展开/折叠")
        [void]$groupItem.SubItems.Add("")
        $groupItem.Tag = [pscustomobject]@{
            IsInventoryGroup = $true
            GroupName = $groupName
        }
        $groupItem.Font = New-Object System.Drawing.Font($inventoryListView.Font, [System.Drawing.FontStyle]::Bold)
        $groupItem.BackColor = $script:uiWindowColor
        $groupItem.ForeColor = $script:uiTextColor
        [void]$inventoryListView.Items.Add($groupItem)

        if ($script:pendingInventoryGroupFocus -and $script:pendingInventoryGroupFocus -eq $groupName) {
            $groupItem.Selected = $true
            $groupItem.Focused = $true
        }

        if (-not $expanded) { continue }

        foreach ($entry in ($groups[$groupName] | Sort-Object Name, Code)) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$entry.Name)
            [void]$row.SubItems.Add([string]$entry.Code)
            [void]$row.SubItems.Add([string]$entry.Qty)
            [void]$row.SubItems.Add([string]$entry.Category)
            [void]$row.SubItems.Add([string]$entry.Source)
            $row.Tag = $entry
            [void]$inventoryListView.Items.Add($row)
            $visibleCount++
        }
    }

    $inventoryListView.EndUpdate()
    $script:pendingInventoryGroupFocus = $null

    if ($inventoryCountLabel) {
        $inventoryCountLabel.Text = "背包物品 $visibleCount / $($script:inventoryItems.Count)"
    }
    if ($inventoryDetailBox -and $script:inventoryItems.Count -eq 0) {
        $inventoryDetailBox.Text = "还没有背包列表。可点击[尝试读取]做实验性读取；稳定操作请直接输入英文代码增删。"
    }
}

function Start-InventoryRefresh {
    Append-ItemAction "INV_NATIVE_LIST"
    if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = "背包: 已请求刷新，等待游戏返回列表。" }
}

function Start-InventoryProbe {
    Append-ItemAction "INV_LIST_PROBE"
    if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = "背包: 已请求只读探针，结果在诊断页/物品状态查看。" }
}

function Append-InventoryNativeChange([string]$kind, [string]$code, [int]$qty) {
    if ([string]::IsNullOrWhiteSpace($code)) { throw "请输入或选中一个英文物品代码。" }
    if ($qty -lt 1) { throw "数量必须大于 0。" }

    $remaining = $qty
    $sent = 0
    while ($remaining -gt 0) {
        $chunk = [Math]::Min(20, $remaining)
        Append-ItemAction ("INV_NATIVE_{0}|{1}|{2}" -f $kind.ToUpperInvariant(), $code.Trim(), $chunk)
        $remaining -= $chunk
        $sent++
    }
    return $sent
}

function Invoke-InventoryNativeChange([string]$kind, [string]$code, [int]$qty) {
    $sent = Append-InventoryNativeChange $kind $code $qty
    $verb = if ($kind.ToUpperInvariant() -eq "ADD") { "增加" } else { "删除" }
    if ($inventoryStatusLabel) {
        $inventoryStatusLabel.Text = ("背包: 已发送{0}请求 {1} x{2}，拆分 {3} 条。" -f $verb, $code, $qty, $sent)
    }
    return $sent
}

function Get-InventoryCodeInput {
    if ($inventoryCodeBox -and -not [string]::IsNullOrWhiteSpace($inventoryCodeBox.Text)) {
        return $inventoryCodeBox.Text.Trim()
    }
    $entry = Get-SelectedInventoryEntry
    if ($entry) { return [string]$entry.Code }
    return ""
}

function Get-InventoryQtyInput {
    $qty = 0
    if (-not $inventoryQtyBox -or -not [int]::TryParse($inventoryQtyBox.Text.Trim(), [ref]$qty)) {
        throw "数量必须是整数。"
    }
    if ($qty -lt 1) { throw "数量必须大于 0。" }
    return $qty
}

function Wait-InventoryListRefresh([int]$timeoutMs = 5000) {
    $before = $null
    if (Test-Path -LiteralPath $script:itemInventoryListPath) {
        $before = [System.IO.File]::GetLastWriteTimeUtc($script:itemInventoryListPath)
    }

    Append-ItemAction "INV_NATIVE_LIST"
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
        if (-not (Test-Path -LiteralPath $script:itemInventoryListPath)) { continue }
        $now = [System.IO.File]::GetLastWriteTimeUtc($script:itemInventoryListPath)
        if (-not $before -or $now -gt $before) {
            $script:itemInventoryListLastWrite = $now
            Apply-InventoryListFile
            return $true
        }
    }
    return $false
}

function Save-InventorySnapshot {
    if ($script:inventoryItems.Count -eq 0) {
        throw "当前没有背包列表，请先刷新背包。"
    }
    if (-not (Test-Path -LiteralPath $script:itemSnapshotDir)) {
        New-Item -ItemType Directory -Force -Path $script:itemSnapshotDir | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $path = Join-Path $script:itemSnapshotDir ("inventory_snapshot_{0}.json" -f $stamp)
    $snapshot = [pscustomobject]@{
        CreatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Tool = "TeleportModUI"
        Items = @($script:inventoryItems | ForEach-Object {
            [pscustomobject]@{
                Code = [string]$_.Code
                Qty = [int]$_.Qty
                Name = [string]$_.Name
                Category = [string]$_.Category
                Source = [string]$_.Source
            }
        })
    }
    $json = $snapshot | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    $script:lastInventorySnapshotPath = $path
    if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = "背包: 快照已保存。" }
    return $path
}

function Get-LatestInventorySnapshotPath {
    if ($script:lastInventorySnapshotPath -and (Test-Path -LiteralPath $script:lastInventorySnapshotPath)) {
        return $script:lastInventorySnapshotPath
    }
    if (-not (Test-Path -LiteralPath $script:itemSnapshotDir)) { return "" }
    $latest = Get-ChildItem -LiteralPath $script:itemSnapshotDir -Filter "inventory_snapshot_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return ""
}

function Get-InventoryQtyMap($items) {
    $map = @{}
    foreach ($item in @($items)) {
        if (-not $item -or [string]::IsNullOrWhiteSpace([string]$item.Code)) { continue }
        $key = ([string]$item.Code).ToLowerInvariant()
        $qty = [int]$item.Qty
        if ($map.ContainsKey($key)) {
            $map[$key].Qty += $qty
        } else {
            $map[$key] = [pscustomobject]@{
                Code = [string]$item.Code
                Qty = $qty
            }
        }
    }
    return $map
}

function Restore-InventorySnapshotDelta {
    $path = Get-LatestInventorySnapshotPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "还没有背包快照。"
    }

    if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = "背包: 正在刷新当前背包，用于计算差量。" }
    if (-not (Wait-InventoryListRefresh 5000)) {
        throw "刷新当前背包超时，未执行还原。"
    }

    $snapshot = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = Get-InventoryQtyMap @($snapshot.Items)
    $current = Get-InventoryQtyMap $script:inventoryItems

    $keys = New-Object "System.Collections.Generic.HashSet[string]"
    foreach ($key in $target.Keys) { [void]$keys.Add($key) }
    foreach ($key in $current.Keys) { [void]$keys.Add($key) }

    $commands = 0
    foreach ($key in $keys) {
        $targetQty = if ($target.ContainsKey($key)) { [int]$target[$key].Qty } else { 0 }
        $currentQty = if ($current.ContainsKey($key)) { [int]$current[$key].Qty } else { 0 }
        $code = if ($target.ContainsKey($key)) { [string]$target[$key].Code } else { [string]$current[$key].Code }
        $delta = $targetQty - $currentQty
        if ($delta -gt 0) {
            $commands += (Append-InventoryNativeChange "ADD" $code $delta)
        } elseif ($delta -lt 0) {
            $commands += (Append-InventoryNativeChange "REMOVE" $code ([Math]::Abs($delta)))
        }
    }

    if ($inventoryStatusLabel) {
        $inventoryStatusLabel.Text = ("背包: 已按快照发送差量还原，动作 {0} 条。" -f $commands)
    }
    return $commands
}

function Refresh-ItemCategories {
    if (-not $itemCategoryBox) { return }
    $selected = if ($itemCategoryBox.SelectedItem) { $itemCategoryBox.SelectedItem.ToString() } else { "全部" }
    if ($selected -eq "All") { $selected = "全部" }
    if ($script:uiTextZh -and $script:uiTextZh.ContainsKey($selected)) {
        $selected = $script:uiTextZh[$selected]
    }
    $allLabel = if ($script:uiLanguage -eq "en") { "All" } else { "全部" }
    $script:itemCategorySyncing = $true
    try {
        $itemCategoryBox.Items.Clear()
        [void]$itemCategoryBox.Items.Add($allLabel)
        $categorySet = New-Object "System.Collections.Generic.HashSet[string]"
        foreach ($entry in $script:itemCatalog) {
            if (-not $entry) { continue }
            $display = Get-ItemDisplayInfo ([string]$entry.Code)
            if (-not [string]::IsNullOrWhiteSpace($display.Category)) {
                [void]$categorySet.Add($display.Category)
            }
        }
        $categories = New-Object System.Collections.ArrayList
        foreach ($category in $categorySet) {
            [void]$categories.Add($category)
        }
        $categories.Sort()
        foreach ($category in $categories) {
            $categoryLabel = if ($script:uiLanguage -eq "en") { Convert-UiText ([string]$category) } else { [string]$category }
            [void]$itemCategoryBox.Items.Add($categoryLabel)
        }
        $selectedIndex = 0
        for ($i = 0; $i -lt $itemCategoryBox.Items.Count; $i++) {
            $candidate = $itemCategoryBox.Items[$i].ToString()
            if ($candidate -eq "All") { $candidate = "全部" }
            if ($script:uiTextZh -and $script:uiTextZh.ContainsKey($candidate)) {
                $candidate = $script:uiTextZh[$candidate]
            }
            if ($candidate -eq $selected) {
                $selectedIndex = $i
                break
            }
        }
        if ($itemCategoryBox.Items.Count -gt 0) {
            $itemCategoryBox.SelectedIndex = $selectedIndex
        }
    } finally {
        $script:itemCategorySyncing = $false
    }
}

function Get-SelectedItemEntry {
    if (-not $itemListView -or $itemListView.SelectedItems.Count -eq 0) { return $null }
    return $itemListView.SelectedItems[0].Tag
}

function Get-ItemQuantityInput([int]$maximum = 0) {
    $qty = 0
    if (-not $itemQtyBox -or -not [int]::TryParse($itemQtyBox.Text.Trim(), [ref]$qty)) {
        throw "数量必须是正整数。"
    }
    if ($qty -lt 1) { throw "数量必须大于 0。" }
    if ($maximum -gt 0 -and $qty -gt $maximum) {
        throw "生成到脚边时数量只能是 1 到 $maximum。"
    }
    return $qty
}

function Refresh-ItemList {
    if (-not $itemListView) { return }

    $search = ""
    if ($itemSearchBox) { $search = $itemSearchBox.Text.Trim().ToLowerInvariant() }
    $category = "全部"
    if ($itemCategoryBox -and $itemCategoryBox.SelectedItem) { $category = $itemCategoryBox.SelectedItem.ToString() }
    if ($category -eq "All") { $category = "全部" }
    if ($script:uiTextZh -and $script:uiTextZh.ContainsKey($category)) {
        $category = $script:uiTextZh[$category]
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $script:itemCatalog) {
        if (-not $entry) { continue }
        $display = Get-ItemDisplayInfo ([string]$entry.Code)
        if ($category -and $category -ne "全部" -and $display.Category -ne $category) {
            continue
        }
        if ($search) {
            $haystack = ("{0} {1} {2} {3} {4}" -f $entry.Code, $display.Name, $entry.Name, $display.Category, $entry.Path).ToLowerInvariant()
            if (-not $haystack.Contains($search)) {
                continue
            }
        }
        [void]$items.Add($entry)
    }

    $itemListView.BeginUpdate()
    $itemListView.Items.Clear()
    foreach ($entry in $items) {
        $display = Get-ItemDisplayInfo ([string]$entry.Code)
        $row = New-Object System.Windows.Forms.ListViewItem($entry.Code)
        [void]$row.SubItems.Add($display.Name)
        [void]$row.SubItems.Add($(if ($script:uiLanguage -eq "en") { Convert-UiText ([string]$display.Category) } else { [string]$display.Category }))
        [void]$row.SubItems.Add($entry.Path)
        $row.Tag = $entry
        [void]$itemListView.Items.Add($row)
    }
    $itemListView.EndUpdate()

    if ($itemCountLabel) {
        $itemCountLabel.Text = "物品 $($items.Count) / $($script:itemCatalog.Count)"
    }
    if ($itemDetailBox -and $items.Count -eq 0) {
        $itemDetailBox.Text = "没有匹配的物品。"
    }
}

function Start-SpawnSelectedItem {
    $entry = Get-SelectedItemEntry
    if (-not $entry) {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个物品。", "物品生成")
        return
    }

    $qty = Get-ItemQuantityInput 20

    Append-ItemAction ("SPAWN|{0}|{1}" -f $entry.Code, $qty)
    $display = Get-ItemDisplayInfo ([string]$entry.Code)
    $displayName = if ($display.Name) { "{0} / {1}" -f $entry.Code, $display.Name } else { $entry.Code }
    Set-ItemStatus ("已发送生成请求: {0} x{1}" -f $displayName, $qty)
}

function Apply-ItemState($state) {
    if (-not $state) { return }
    $stateName = ("$($state.STATE)").ToUpperInvariant()
    $message = if ($state.MESSAGE) { $state.MESSAGE } else { $state.STATE }
    $method = if ($state.METHOD) { " | $($state.METHOD)" } else { "" }

    switch ($stateName) {
        "SPAWNED" { $message = "已验证生成: $message" }
        "SENT_UNVERIFIED" { $message = "已发送但未验证: $message" }
        "FAILED" { $message = "生成失败: $message" }
        "BUSY" { $message = "正在生成: $message" }
    }

    if ($state.CODE) {
        Set-ItemStatus ("{0}: {1} x{2}{3}" -f $message, $state.CODE, $state.QTY, $method)
    } else {
        Set-ItemStatus $message
    }
}

function Write-UnlockControl([bool]$enabled) {
    $text = if ($enabled) { "ENABLED=1`nSTATE=ENABLED`n" } else { "ENABLED=0`nSTATE=DISABLED`n" }
    [System.IO.File]::WriteAllText($script:unlockControlPath, $text, [System.Text.UTF8Encoding]::new($false))
}

function Apply-UnlockState($state) {
    if (-not $state) { return }
    $enabled = ("$($state.STATE)").ToUpperInvariant() -eq "ENABLED"
    if ($unlockEnabledCheckBox) {
        if ($unlockEnabledCheckBox.Checked -ne $enabled) {
            $script:unlockSyncing = $true
            try {
                $unlockEnabledCheckBox.Checked = $enabled
            } finally {
                $script:unlockSyncing = $false
            }
        }
    }
    $message = if ($state.MESSAGE) { $state.MESSAGE } else { $state.STATE }
    Set-UnlockStatus $message
}

function Read-WalkthroughGuide {
    $script:walkthroughEntries.Clear()
    if (-not (Test-Path -LiteralPath $walkthroughPath)) { return }

    $group = "未分类"
    $title = $null
    $body = New-Object System.Collections.Generic.List[string]

    function Add-WalkthroughEntry {
        if ([string]::IsNullOrWhiteSpace($script:pendingWalkthroughTitle)) { return }
        $text = ($script:pendingWalkthroughBody -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return }
        [void]$script:walkthroughEntries.Add([pscustomobject]@{
            Group = $script:pendingWalkthroughGroup
            Title = $script:pendingWalkthroughTitle
            Body  = $text
        })
    }

    $script:pendingWalkthroughGroup = $group
    $script:pendingWalkthroughTitle = $null
    $script:pendingWalkthroughBody = New-Object System.Collections.Generic.List[string]

    foreach ($line in [System.IO.File]::ReadAllLines($walkthroughPath, [System.Text.UTF8Encoding]::new($true))) {
        if ($line.StartsWith("## ")) {
            Add-WalkthroughEntry
            $script:pendingWalkthroughGroup = $line.Substring(3).Trim()
            $script:pendingWalkthroughTitle = $null
            $script:pendingWalkthroughBody = New-Object System.Collections.Generic.List[string]
        } elseif ($line.StartsWith("### ")) {
            Add-WalkthroughEntry
            $script:pendingWalkthroughTitle = $line.Substring(4).Trim()
            $script:pendingWalkthroughBody = New-Object System.Collections.Generic.List[string]
        } elseif ($script:pendingWalkthroughTitle) {
            [void]$script:pendingWalkthroughBody.Add($line)
        }
    }
    Add-WalkthroughEntry
}

function Refresh-WalkthroughTree {
    if (-not $walkthroughTreeView) { return }

    $filter = ""
    if ($walkthroughSearchBox) {
        $filter = $walkthroughSearchBox.Text.Trim().ToLowerInvariant()
    }

    $walkthroughTreeView.BeginUpdate()
    $walkthroughTreeView.Nodes.Clear()
    $groups = @{}
    $shown = 0

    foreach ($entry in $script:walkthroughEntries) {
        $haystack = ("{0} {1} {2}" -f $entry.Group, $entry.Title, $entry.Body).ToLowerInvariant()
        if ($filter -and -not $haystack.Contains($filter)) { continue }

        if (-not $groups.ContainsKey($entry.Group)) {
            $node = New-Object System.Windows.Forms.TreeNode($entry.Group)
            $node.Tag = $null
            [void]$walkthroughTreeView.Nodes.Add($node)
            $groups[$entry.Group] = $node
        }

        $child = New-Object System.Windows.Forms.TreeNode($entry.Title)
        $child.Tag = $entry
        [void]$groups[$entry.Group].Nodes.Add($child)
        $shown++
    }

    if ($filter) {
        $walkthroughTreeView.ExpandAll()
    }
    $walkthroughTreeView.EndUpdate()

    if ($walkthroughCountLabel) {
        $walkthroughCountLabel.Text = "任务 $shown / $($script:walkthroughEntries.Count)"
    }
    if ($walkthroughDetailBox -and $shown -eq 0) {
        $walkthroughDetailBox.Text = "没有匹配的任务。"
    }
}

function Show-WalkthroughEntry($entry) {
    if (-not $walkthroughDetailBox) { return }
    if (-not $entry) {
        $walkthroughDetailBox.Text = "选择左侧任务查看攻略内容。"
        return
    }
    $walkthroughDetailBox.Text = ("【{0}】`r`n{1}`r`n`r`n{2}" -f $entry.Title, $entry.Group, $entry.Body)
}

function Get-SelectedSpot {
    if ($listView.SelectedItems.Count -eq 0) { return $null }
    if ($listView.FocusedItem -and $listView.FocusedItem.Selected) {
        if (Test-SpotGroupTag $listView.FocusedItem.Tag) { return $null }
        return $listView.FocusedItem.Tag
    }
    if (Test-SpotGroupTag $listView.SelectedItems[0].Tag) { return $null }
    return $listView.SelectedItems[0].Tag
}

function Get-SelectedSpots {
    $spots = New-Object System.Collections.Generic.List[object]
    foreach ($item in $listView.SelectedItems) {
        if ($item.Tag -and -not (Test-SpotGroupTag $item.Tag)) {
            [void]$spots.Add($item.Tag)
        }
    }
    return @($spots | Sort-Object Index -Descending)
}

function Get-SpotIdentity([object]$spot) {
    if (-not $spot) { return $null }
    if (Test-SpotGroupTag $spot) { return $null }
    return ("{0}|{1}|{2}" -f $spot.X, $spot.Y, $spot.Z)
}

function Get-SelectedSpotIdentities {
    $identities = New-Object System.Collections.Generic.HashSet[string]
    foreach ($item in $listView.SelectedItems) {
        $identity = Get-SpotIdentity $item.Tag
        if ($identity) {
            [void]$identities.Add($identity)
        }
    }
    return ,$identities
}

function Get-FocusedSpot {
    if ($listView.FocusedItem -and $listView.FocusedItem.Selected) {
        if (Test-SpotGroupTag $listView.FocusedItem.Tag) { return $null }
        return $listView.FocusedItem.Tag
    }
    return Get-SelectedSpot
}

function Require-SelectedSpot {
    $spot = Get-SelectedSpot
    if (-not $spot) {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个节点。", "瞬移管理")
        return $null
    }
    return $spot
}

function Copy-SpotText([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($text)
    } catch {
        # Ignore clipboard failures.
    }
}

function ConvertFrom-CoordinateText([string]$text) {
    $raw = ($text | ForEach-Object { $_.Trim() })
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "坐标不能为空。"
    }

    $clean = $raw.Replace("，", " ").Replace(",", " ").Replace("－", "-").Replace("−", "-")
    $matches = [regex]::Matches($clean, "[-+]?(?:\d+(?:\.\d*)?|\.\d+)")
    if ($matches.Count -lt 3) {
        throw "无法识别坐标。请粘贴类似 X: 66348.95 | Y: -6340.03 | Z: 2337.22 的内容。"
    }

    return [pscustomobject]@{
        X = ConvertTo-CleanNumber $matches[0].Value "X轴"
        Y = ConvertTo-CleanNumber $matches[1].Value "Y轴"
        Z = ConvertTo-CleanNumber $matches[2].Value "Z轴"
    }
}

function Read-SpotRenameName([object]$spot) {
    if (-not $spot) { return $null }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "重命名节点"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(420, 138)
    $dialog.Font = $font
    $dialog.BackColor = $script:uiWindowColor
    $dialog.ForeColor = $script:uiTextColor

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "节点名称"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(14, 18)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(92, 14)
    $textBox.Width = 306
    $textBox.Text = $spot.Name
    $textBox.BackColor = $script:uiInputColor
    $textBox.ForeColor = $script:uiTextColor

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "确定"
    $okButton.Width = 88
    $okButton.Height = 30
    $okButton.Location = New-Object System.Drawing.Point(214, 82)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "取消"
    $cancelButton.Width = 88
    $cancelButton.Height = 30
    $cancelButton.Location = New-Object System.Drawing.Point(310, 82)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dialog.Controls.AddRange(@($label, $textBox, $okButton, $cancelButton))
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    $result = $dialog.ShowDialog($form)
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $newName = $textBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($newName)) {
        [System.Windows.Forms.MessageBox]::Show("名称不能为空。", "瞬移管理")
        return $null
    }
    return $newName
}

function Start-ManualTeleport {
    $coord = ConvertFrom-CoordinateText $teleportCoordBox.Text
    $x = $coord.X
    $y = $coord.Y
    $z = $coord.Z
    $xText = $x.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $yText = $y.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $zText = $z.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    Send-TeleportAction `
        ("TELEPORT_COORD|{0}|{1}|{2}|手动坐标" -f $xText, $yText, $zText) `
        ("已发送手动坐标瞬移请求: X={0}, Y={1}, Z={2}" -f $xText, $yText, $zText) | Out-Null
}

function Delete-SelectedSpots {
    $spots = @(Get-SelectedSpots)
    if ($spots.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个节点。", "瞬移管理")
        return
    }

    $label = if ($spots.Count -eq 1) {
        "确定删除节点 [$($spots[0].Index)] $($spots[0].Name) 吗？"
    } else {
        "确定删除选中的 $($spots.Count) 个节点吗？"
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
        $label,
        "瞬移管理",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }

    foreach ($spot in $spots) {
        Append-Action ("DELETE|{0}" -f $spot.Index)
    }

    Set-Status ("已发送删除请求: {0} 个节点" -f $spots.Count)
    Start-Sleep -Milliseconds 100
    Refresh-SpotList
}

function Move-SelectedSpot([int]$delta) {
    $spot = Get-FocusedSpot
    if (-not $spot) {
        [System.Windows.Forms.MessageBox]::Show("请先选中一个节点。", "瞬移管理")
        return
    }

    $targetIndex = [int]$spot.Index + $delta
    if ($targetIndex -lt 1) { return }

    Append-Action ("MOVE|{0}|{1}" -f $spot.Index, $targetIndex)
    Set-Status ("已发送移动请求: [{0}] {1}" -f $spot.Index, $spot.Name)
    Start-Sleep -Milliseconds 100
    Refresh-SpotList
}

function Move-SpotToIndex($spot, [int]$targetIndex) {
    if (-not $spot) { return }
    if ($targetIndex -lt 1) { return }
    if ([int]$spot.Index -eq $targetIndex) { return }

    Append-Action ("MOVE|{0}|{1}" -f $spot.Index, $targetIndex)
    Set-Status ("已发送移动请求: [{0}] {1} -> {2}" -f $spot.Index, $spot.Name, $targetIndex)
    Start-Sleep -Milliseconds 100
    Refresh-SpotList
}

function Ensure-MoneyStateTimer {
    if ($script:moneyStateTimer) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        try {
            if (-not (Test-Path -LiteralPath $script:moneyStatePath)) { return }
            $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($script:moneyStatePath)
            if ($script:moneyStateLastWrite -and $lastWrite -eq $script:moneyStateLastWrite) { return }
            $script:moneyStateLastWrite = $lastWrite
            $state = Read-MoneyStateFile
            if ($state) {
                Apply-MoneyState $state
            }
        } catch {
            # silently ignore poll errors
        }
    })
    $script:moneyStateTimer = $timer
}

function Ensure-AttrStateTimer {
    if ($script:attrStateTimer) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        try {
            if (-not (Test-Path -LiteralPath $script:attrStatePath)) { return }
            $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($script:attrStatePath)
            if ($script:attrStateLastWrite -and $lastWrite -eq $script:attrStateLastWrite) { return }
            $script:attrStateLastWrite = $lastWrite
            $state = Read-AttrStateFile
            if ($state) {
                Apply-AttrState $state
            }
        } catch {
            # silently ignore poll errors
        }
    })
    $script:attrStateTimer = $timer
}

function Ensure-SpotsFileTimer {
    if ($script:spotsFileTimer) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        try {
            if (-not (Test-Path -LiteralPath $spotsPath)) { return }
            $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($spotsPath)
            if ($script:spotsLastWrite -and $lastWrite -eq $script:spotsLastWrite) { return }
            $script:spotsLastWrite = $lastWrite
            Refresh-SpotList
        } catch {
            # silently ignore refresh errors
        }
    })
    $script:spotsFileTimer = $timer
}

function Ensure-TeleportStatusTimer {
    if ($script:teleportStatusTimer) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        try {
            Update-TeleportControls
        } catch {
        }
    })
    $script:teleportStatusTimer = $timer
}

function Ensure-ItemStateTimer {
    if ($script:itemStateTimer) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        try {
            if (Test-Path -LiteralPath $script:itemStatePath) {
                $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($script:itemStatePath)
                if (-not $script:itemStateLastWrite -or $lastWrite -ne $script:itemStateLastWrite) {
                    $script:itemStateLastWrite = $lastWrite
                    Apply-ItemState (Read-KeyValueState $script:itemStatePath)
                }
            }
        } catch {
        }
        try {
            if (Test-Path -LiteralPath $script:itemInventoryStatePath) {
                $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($script:itemInventoryStatePath)
                if (-not $script:itemInventoryStateLastWrite -or $lastWrite -ne $script:itemInventoryStateLastWrite) {
                    $script:itemInventoryStateLastWrite = $lastWrite
                    Apply-InventoryActionState (Read-InventoryPipeStatus $script:itemInventoryStatePath)
                }
            }
        } catch {
        }
    })
    $script:itemStateTimer = $timer
}

function Ensure-InventoryListTimer {
    if ($script:itemInventoryListTimer) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        try {
            if (-not (Test-Path -LiteralPath $script:itemInventoryListPath)) { return }
            $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($script:itemInventoryListPath)
            if ($script:itemInventoryListLastWrite -and $lastWrite -eq $script:itemInventoryListLastWrite) { return }
            $script:itemInventoryListLastWrite = $lastWrite
            Apply-InventoryListFile
        } catch {
        }
    })
    $script:itemInventoryListTimer = $timer
}

function Ensure-UnlockStateTimer {
    if ($script:unlockStateTimer) { return }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        try {
            if (-not (Test-Path -LiteralPath $script:unlockStatePath)) { return }
            $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($script:unlockStatePath)
            if ($script:unlockStateLastWrite -and $lastWrite -eq $script:unlockStateLastWrite) { return }
            $script:unlockStateLastWrite = $lastWrite
            Apply-UnlockState (Read-KeyValueState $script:unlockStatePath)
        } catch {
        }
    })
    $script:unlockStateTimer = $timer
}

function Send-OreChange([string]$mode, [int]$quantity) {
    if ($quantity -lt 1) {
        throw "数量必须大于 0。"
    }
    $op = $mode.ToUpperInvariant()
    if ($op -ne "ADD" -and $op -ne "REMOVE") {
        throw "矿石动作必须是 ADD 或 REMOVE。"
    }

    Append-ItemAction ("INV_NATIVE_{0}|ItMi_Orenugget|{1}" -f $op, $quantity)

    $label = if ($op -eq "ADD") { "增加" } else { "减少" }
    Set-MoneyStatus ("已请求{0}矿石 {1}。" -f $label, $quantity)
}

function Send-CustomOreChange([string]$mode) {
    $value = ConvertTo-MoneyNumber $moneyWriteValueBox.Text "自定义数量"
    $quantity = [int][Math]::Round($value)
    if ($quantity -lt 1) {
        throw "自定义数量必须大于 0。"
    }
    Send-OreChange $mode $quantity
}

function Start-MoneyDetect {
    Send-OreChange "ADD" 1
}

function Add-Ore10 {
    Send-OreChange "ADD" 10
}

function Add-Ore100 {
    Send-OreChange "ADD" 100
}

function Remove-Ore1 {
    Send-OreChange "REMOVE" 1
}

function Remove-Ore10 {
    Send-OreChange "REMOVE" 10
}

function Sync-AttributeInputs {
    $def = Get-SelectedAttributeDefinition
    if (-not $def) { return }
    if ($attrCurrentValueBox) { $attrCurrentValueBox.Text = $def.Current }
    if ($attrWriteValueBox) { $attrWriteValueBox.Text = $def.Write }
    $script:attrCandidates.Clear()
    Refresh-AttrCandidatesList
    Set-AttrStatus ("已选择 {0}，可先读取，再写入 Current/Base/Both。" -f $def.Name)
}

function Start-AttrDetect {
    $def = Get-SelectedAttributeDefinition
    if (-not $def) {
        [System.Windows.Forms.MessageBox]::Show("请先选择一个属性。", "人物属性")
        return
    }

    if (Ensure-PlayerEditCppBridge) {
        Append-AttrAction ("ATTR_READ|{0}" -f $def.Key)
        Set-AttrStatus ("已请求读取 {0}。" -f $def.Name)
    }
}

function Start-AttrRefresh {
    Write-AttrValue "Current"
}

function Write-AttrValue([string]$slot) {
    $def = Get-SelectedAttributeDefinition
    if (-not $def) {
        [System.Windows.Forms.MessageBox]::Show("请先选择一个属性。", "人物属性")
        return
    }

    $targetValue = ConvertTo-MoneyNumber $attrWriteValueBox.Text "写入数值"
    $newValue = $targetValue.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    if (Ensure-PlayerEditCppBridge) {
        Append-AttrAction ("ATTR_WRITE|{0}|{1}|{2}" -f $def.Key, $slot, $newValue)
        Set-AttrStatus ("已请求写入 {0} {1} = {2}。" -f $def.Name, $slot, $newValue)
    }
}

function Write-SelectedAttrCandidate {
    Write-AttrValue "Base"
}

function Pin-SelectedAttrCandidate {
    Write-AttrValue "Both"
}

function Clear-AttrCandidates {
    if ($attrDetailBox) {
        $attrDetailBox.Text = "人物属性使用独立 C++ 桥和 CT 固定链。建议先读取，再写入小值测试。"
    }
    Refresh-AttrCandidatesList
    Set-AttrStatus "已清空显示状态"
}

function Set-Status([string]$message) {
    if ($script:uiLanguage -eq "en" -and $script:uiTextEn) {
        $message = Convert-UiText $message
    }
    $script:statusLabel.Text = $message
}

function Get-DiagnosticLogPath {
    $source = "瞬移诊断"
    if ($diagSourceBox -and $null -ne $diagSourceBox.SelectedItem) {
        $source = $diagSourceBox.SelectedItem.ToString()
    }
    if ($script:uiLanguage -eq "en") {
        $source = Convert-UiText $source
    }
    switch ($source) {
        "瞬移状态" { return $script:teleportStatusPath }
        "C++桥诊断" { return $script:teleportCppDiagPath }
        "C++桥状态" { return $script:teleportCppStatusPath }
        "内存桥诊断" { return $script:teleportMemDiagPath }
        "内存桥状态" { return $script:teleportMemStatusPath }
        "UE4SS日志" { return $script:ue4ssLogPath }
        "物品状态" { return $script:itemStatePath }
        "背包动作状态" { return $script:itemInventoryStatePath }
        "背包列表" { return $script:itemInventoryListPath }
        "人物属性状态" { return $script:attrStatePath }
        "人物属性诊断" { return $script:playerEditDiagPath }
        "开锁状态" { return $script:unlockStatePath }
        "物品高亮状态" { return $script:focusHighlightStatusPath }
        "UI错误" { return $script:uiErrorLogPath }
        default { return $script:teleportDiagPath }
    }
}

function Refresh-DiagnosticLog {
    if (-not $diagLogBox) { return }

    $path = Get-DiagnosticLogPath
    if ($diagPathLabel) {
        $diagPathLabel.Text = $path
    }

    try {
        if (-not (Test-Path -LiteralPath $path)) {
            $diagLogBox.Text = "文件还不存在。`r`n$path"
            return
        }

        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in (Read-FileShareSafe $path)) {
            [void]$lines.Add([string]$line)
        }

        if ($lines.Count -eq 0) {
            $diagLogBox.Text = "文件为空。`r`n$path"
        } else {
            $start = [Math]::Max(0, $lines.Count - 500)
            $tail = New-Object System.Collections.Generic.List[string]
            for ($i = $start; $i -lt $lines.Count; $i++) {
                [void]$tail.Add($lines[$i])
            }
            $diagLogBox.Text = [string]::Join("`r`n", $tail.ToArray())
            $diagLogBox.SelectionStart = $diagLogBox.TextLength
            $diagLogBox.ScrollToCaret()
        }
    } catch {
        $diagLogBox.Text = "读取失败: $($_.Exception.Message)`r`n$path"
    }
}

function Start-CoreReload {
    Append-Action "RELOAD_CORE"
    Set-Status "已发送核心重载请求。回游戏等待 0.5 秒，或刷新日志查看结果。"
    if ($diagSourceBox) { $diagSourceBox.SelectedItem = Convert-UiText "瞬移诊断" }
}

function Start-FullHotReload {
    try {
        $proc = Get-Process -Name $script:gameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) {
            Set-Status "没有找到游戏进程，无法发送 R 热重载。"
            return
        }
        if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
            Set-Status "找到了游戏进程，但暂时没有窗口句柄。请手动回游戏按 R。"
            return
        }

        [void](Activate-WindowByProcessId $proc.Id)
        Start-Sleep -Milliseconds 180
        [System.Windows.Forms.SendKeys]::SendWait("^r")
        Set-Status "已向游戏发送 Ctrl+R 热重载。请等 UE4SS 日志出现 All mods re-installed。"
        if ($diagSourceBox) { $diagSourceBox.SelectedItem = Convert-UiText "UE4SS日志" }
    } catch {
        Write-UiErrorLog ("发送全量热重载失败: " + $_.Exception.Message)
        Set-Status ("发送全量热重载失败: {0}。请手动回游戏按 Ctrl+R。" -f $_.Exception.Message)
    }
}

function Get-SpotGroupName([string]$name) {
    $text = ([string]$name).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return "未分类" }

    foreach ($prefix in @(
        "Khorinis",
        "Old Camp",
        "New Camp",
        "Swamp Camp",
        "Monastery",
        "Mine",
        "Xardas",
        "Free Mine",
        "Pass",
        "Spot"
    )) {
        if ($text.StartsWith($prefix)) { return $prefix }
    }

    $match = [regex]::Match($text, "^(.+?)[-－—_]")
    if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
        return $match.Groups[1].Value.Trim()
    }

    return "未分类"
}

function Get-SpotGroupOrder([string]$groupName) {
    $order = @{
        "Khorinis" = 10
        "Old Camp" = 20
        "New Camp" = 30
        "Swamp Camp" = 40
        "Monastery" = 50
        "Mine" = 60
        "Xardas" = 70
        "Free Mine" = 80
        "Pass" = 90
        "Spot" = 900
        "未分类" = 999
    }
    if ($order.ContainsKey($groupName)) { return $order[$groupName] }
    return 500
}

function Test-SpotGroupTag([object]$tag) {
    return ($tag -and $tag.PSObject.Properties["IsGroup"] -and $tag.IsGroup)
}

function Toggle-SpotGroup([string]$groupName) {
    if ([string]::IsNullOrWhiteSpace($groupName)) { return }
    $current = $false
    if ($script:spotGroupExpanded.ContainsKey($groupName)) {
        $current = [bool]$script:spotGroupExpanded[$groupName]
    }
    $script:spotGroupExpanded[$groupName] = -not $current
    $script:pendingSpotGroupFocus = $groupName
    Refresh-SpotList
}

function Refresh-SpotList {
    $filter = $searchBox.Text.Trim().ToLowerInvariant()
    $selectedIdentities = Get-SelectedSpotIdentities
    $spots = Read-Spots
    $groups = @{}
    foreach ($spot in $spots) {
        $groupName = Get-SpotGroupName $spot.Name
        if (-not $groups.ContainsKey($groupName)) {
            $groups[$groupName] = New-Object System.Collections.Generic.List[object]
        }
        [void]$groups[$groupName].Add($spot)
    }

    $listView.BeginUpdate()
    $listView.Items.Clear()

    $visibleSpotCount = 0
    $focusItem = $null
    $sortedGroups = $groups.Keys | Sort-Object @{ Expression = { Get-SpotGroupOrder $_ } }, @{ Expression = { $_ } }
    foreach ($groupName in $sortedGroups) {
        $groupSpots = @($groups[$groupName] | Sort-Object Name)
        $matchingSpots = @($groupSpots | Where-Object {
            -not $filter -or $_.Name.ToLowerInvariant().Contains($filter)
        })
        if ($matchingSpots.Count -eq 0) { continue }

        if (-not $script:spotGroupExpanded.ContainsKey($groupName)) {
            $script:spotGroupExpanded[$groupName] = $false
        }
        $expanded = [bool]$script:spotGroupExpanded[$groupName]
        if ($filter) { $expanded = $true }

        $marker = if ($expanded) { "[-]" } else { "[+]" }
        $groupItem = New-Object System.Windows.Forms.ListViewItem(("{0} {1} ({2})" -f $marker, $groupName, $matchingSpots.Count))
        [void]$groupItem.SubItems.Add("")
        [void]$groupItem.SubItems.Add("点击展开/折叠")
        $groupItem.Tag = [pscustomobject]@{
            IsGroup = $true
            GroupName = $groupName
        }
        $groupItem.Font = New-Object System.Drawing.Font($listView.Font, [System.Drawing.FontStyle]::Bold)
        $groupItem.BackColor = $script:uiWindowColor
        $groupItem.ForeColor = $script:uiTextColor
        [void]$listView.Items.Add($groupItem)
        if ($script:pendingSpotGroupFocus -and $groupName -eq $script:pendingSpotGroupFocus) {
            $focusItem = $groupItem
        }

        if (-not $expanded) { continue }

        foreach ($spot in $matchingSpots) {
            $item = New-Object System.Windows.Forms.ListViewItem($spot.Name)
            [void]$item.SubItems.Add($spot.Index.ToString())
            [void]$item.SubItems.Add(("X: {0} | Y: {1} | Z: {2}" -f $spot.X, $spot.Y, $spot.Z))
            $item.Tag = $spot
            [void]$listView.Items.Add($item)
            $visibleSpotCount++

            $identity = Get-SpotIdentity $spot
            if ($identity -and $selectedIdentities.Contains($identity)) {
                $item.Selected = $true
                $item.Focused = $true
            }
        }
    }

    $listView.EndUpdate()
    $countLabel.Text = "节点 $visibleSpotCount/$($spots.Count) | 组 $($sortedGroups.Count)"

    if ($focusItem) {
        foreach ($item in @($listView.SelectedItems)) {
            $item.Selected = $false
        }
        $focusItem.Selected = $true
        $focusItem.Focused = $true
        try {
            $listView.TopItem = $focusItem
        } catch {
            $focusItem.EnsureVisible()
        }
        $script:pendingSpotGroupFocus = $null
    } elseif ($listView.SelectedItems.Count -gt 0) {
        $listView.SelectedItems[0].EnsureVisible()
    }

    Refresh-NpcSpotPrefixBox
}

function Get-DefaultSpotExportPath {
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = $env:USERPROFILE
    }
    return (Join-Path $desktop "瞬移坐标.txt")
}

function ConvertTo-SpotFileLine([object]$spot) {
    $name = ([string]$spot.Name).Replace("|", "_").Replace("`r", " ").Replace("`n", " ").Trim()
    $x = (ConvertTo-CleanNumber ([string]$spot.X) "X轴").ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
    $y = (ConvertTo-CleanNumber ([string]$spot.Y) "Y轴").ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
    $z = (ConvertTo-CleanNumber ([string]$spot.Z) "Z轴").ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
    return ("{0}|{1}|{2}|{3}" -f $name, $x, $y, $z)
}

function Export-SpotCoordinatesToFile([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw "导出路径不能为空。" }

    $spots = Read-Spots
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Gothic 1 Remake 瞬移坐标")
    [void]$lines.Add("# 导出日期: " + (Get-Date -Format "yyyy-MM-dd"))
    [void]$lines.Add("# 格式: 名称|X|Y|Z")
    [void]$lines.Add("# 可在 UI 的「操作指南」页导入；以 # 开头的说明行会被忽略。")
    foreach ($spot in $spots) {
        [void]$lines.Add((ConvertTo-SpotFileLine $spot))
    }

    [System.IO.File]::WriteAllLines($path, $lines, [System.Text.UTF8Encoding]::new($false))
    return $spots.Count
}

function Import-SpotCoordinatesFromFile([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        throw "找不到坐标文件。"
    }

    $imported = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.UTF8Encoding]::new($true))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trim = $line.Trim()
        if ($trim.StartsWith("#")) { continue }

        $parts = $trim.Split("|")
        if ($parts.Length -lt 4) { continue }
        $spot = [pscustomobject]@{
            Name = $parts[0]
            X = $parts[1]
            Y = $parts[2]
            Z = $parts[3]
        }
        [void]$imported.Add((ConvertTo-SpotFileLine $spot))
    }

    if ($imported.Count -eq 0) {
        throw "没有识别到有效坐标。请使用格式: 名称|X|Y|Z"
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "将导入 $($imported.Count) 个坐标，并替换当前节点列表。导入前会自动备份当前坐标。是否继续？",
        "导入瞬移坐标",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::OK) { return $false }

    if (Test-Path -LiteralPath $spotsPath) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupPath = Join-Path $win64Dir ("TeleportMod_spots_backup_{0}.ini" -f $stamp)
        Copy-Item -LiteralPath $spotsPath -Destination $backupPath -Force
    }

    [System.IO.File]::WriteAllLines($spotsPath, $imported, [System.Text.UTF8Encoding]::new($false))
    Append-Action "RELOAD"
    Start-Sleep -Milliseconds 100
    Refresh-SpotList
    return $true
}

function Start-ExportSpotCoordinates {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "导出瞬移坐标"
    $dialog.Filter = "文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*"
    $defaultPath = Get-DefaultSpotExportPath
    $dialog.FileName = [System.IO.Path]::GetFileName($defaultPath)
    $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($defaultPath)
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $count = Export-SpotCoordinatesToFile $dialog.FileName
    Set-Status ("已导出 {0} 个坐标: {1}" -f $count, $dialog.FileName)
    [System.Windows.Forms.MessageBox]::Show("已导出 $count 个坐标。", "导出瞬移坐标")
}

function Start-ImportSpotCoordinates {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "导入瞬移坐标"
    $dialog.Filter = "文本文件 (*.txt)|*.txt|INI 文件 (*.ini)|*.ini|所有文件 (*.*)|*.*"
    $dialog.InitialDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    if (Import-SpotCoordinatesFromFile $dialog.FileName) {
        Set-Status ("已导入坐标并通知游戏重新加载: {0}" -f $dialog.FileName)
        [System.Windows.Forms.MessageBox]::Show("导入完成。目前节点列表已刷新。", "导入瞬移坐标")
    }
}

function Normalize-NpcLifeState([string]$value) {
    switch ($value.Trim().ToUpperInvariant()) {
        "ACTIVE" { return "ACTIVE" }
        "DOWN_OR_DEAD" { return "DOWN_OR_DEAD" }
        default { return "UNKNOWN" }
    }
}

function Get-NpcLifeStateText([string]$value) {
    switch (Normalize-NpcLifeState $value) {
        "ACTIVE" { return "存活" }
        "DOWN_OR_DEAD" { return "倒地/死亡" }
        default { return "未知" }
    }
}

function ConvertFrom-NpcScanLine([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    if ($line.StartsWith("Name`t")) { return $null }

    $parts = $line -split "`t", 9
    if ($parts.Length -lt 6) { return $null }

    return [pscustomobject]@{
        Name = $parts[0]
        X = $parts[1]
        Y = $parts[2]
        Z = $parts[3]
        Distance = $parts[4]
        FullName = $parts[5]
        Key = if ($parts.Length -ge 7) { $parts[6] } else { "" }
        LifeState = if ($parts.Length -ge 8) { Normalize-NpcLifeState $parts[7] } else { "UNKNOWN" }
        ObservedAt = if ($parts.Length -ge 9) { $parts[8] } else { "" }
    }
}

function Get-NpcScanIdentity([object]$entry) {
    if (-not $entry) { return "" }
    $fullName = [string]$entry.FullName
    if (-not [string]::IsNullOrWhiteSpace($fullName)) {
        $match = [regex]::Match($fullName, "(?:^|[\.:])Character_([^\s/:]+)")
        if ($match.Success) {
            $id = $match.Groups[1].Value
            $id = [regex]::Replace($id, "-.*$", "")
            $id = [regex]::Replace($id, "_C_\d+$", "")
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                return $id
            }
        }
        $cleanFullName = [regex]::Replace($fullName, "_C_\d+$", "")
        $cleanFullName = [regex]::Replace($cleanFullName, "_\d+$", "")
        if (-not [string]::IsNullOrWhiteSpace($cleanFullName)) {
            return $cleanFullName
        }
    }
    $x = [math]::Round((ConvertTo-CleanNumber ([string]$entry.X) "X"), 0)
    $y = [math]::Round((ConvertTo-CleanNumber ([string]$entry.Y) "Y"), 0)
    $z = [math]::Round((ConvertTo-CleanNumber ([string]$entry.Z) "Z"), 0)
    return ("{0}|{1}|{2}|{3}" -f $entry.Name, $x, $y, $z)
}

function Get-NpcGroupName([object]$entry) {
    if (-not $entry) { return "未知人物" }
    $name = ([string]$entry.Name).Trim()
    $key = ([string]$entry.Key).Trim()
    $fullName = ([string]$entry.FullName).Trim()
    $text = ("{0} {1} {2}" -f $name, $key, $fullName)

    if ($fullName -match "(?i)AIAgentCharacter_Meatbug") { return "肉虫" }
    if ($fullName -match "(?i)AIAgentCharacter_Scavenger") { return "食腐鸟" }
    if ($fullName -match "(?i)AIAgentCharacter_Molerat") { return "鼹鼠" }
    if ($fullName -match "(?i)AIAgentCharacter_Bloodfly") { return "血蝇" }
    if ($fullName -match "(?i)AIAgentCharacter_Goblin") { return "哥布林" }
    if ($fullName -match "(?i)AIAgentCharacter_Wolf") { return "狼" }

    if ($text -match "(?i)(^|[_\-\s])Peasant\d*|WorldPointActor_Peasant\d*") { return "农民" }
    if ($text -match "(?i)(^|[_\-\s])Rogue\d*|WorldPointActor_Rogue\d*") { return "强盗" }
    if ($text -match "(?i)(^|[_\-\s])Shadow\d*|Spawnpoint_Shadow") { return "暗影" }
    if ($text -match "(?i)(^|[_\-\s])Guard\d*|GateGuard") { return "守卫" }
    if ($text -match "(?i)(^|[_\-\s])Digger\d*") { return "矿工" }
    if ($text -match "(?i)(^|[_\-\s])Mercenary\d*|WorldPointActor_Mercenary\d*") { return "佣兵" }
    if ($text -match "(?i)(^|[_\-\s])Prisoner\d*|WorldPointActor_Prisoner\d*") { return "囚犯" }
    if ($text -match "(?i)(^|[_\-\s])Novice\d*") { return "新手" }
    if ($text -match "(?i)(^|[_\-\s])Templar\d*") { return "圣殿武士" }
    if ($text -match "(?i)(^|[_\-\s])Scraper\d*|WorldPointActor_Scraper\d*") { return "刮削工" }
    if ($text -match "(?i)(^|[_\-\s])Meatbug") { return "肉虫" }
    if ($text -match "(?i)(^|[_\-\s])Scavenger") { return "食腐鸟" }
    if ($text -match "(?i)(^|[_\-\s])Molerat") { return "鼹鼠" }
    if ($text -match "(?i)(^|[_\-\s])Bloodfly") { return "血蝇" }
    if ($text -match "(?i)(^|[_\-\s])Goblin") { return "哥布林" }

    if ([string]::IsNullOrWhiteSpace($name)) { return "未知人物" }
    return $name
}

function Get-NpcScanFilterText {
    if ($npcScanSearchBox) {
        return $npcScanSearchBox.Text.Trim().ToLowerInvariant()
    }
    return ""
}

function Get-NpcLifeStateFilter {
    if (-not $npcScanStateFilterCombo) { return "ACTIVE" }
    switch ([string]$npcScanStateFilterCombo.SelectedItem) {
        "全部" { return "ALL" }
        "倒地/死亡" { return "DOWN_OR_DEAD" }
        "未知" { return "UNKNOWN" }
        default { return "ACTIVE" }
    }
}

function Test-NpcScanEntryMatchesFilter([object]$entry, [string]$groupName, [string]$filter, [string]$lifeFilter) {
    if (-not $entry) { return $false }

    $lifeState = Normalize-NpcLifeState ([string]$entry.LifeState)
    if ($lifeFilter -ne "ALL" -and $lifeState -ne $lifeFilter) { return $false }
    if ([string]::IsNullOrWhiteSpace($filter)) { return $true }

    $haystack = @(
        [string]$groupName,
        [string]$entry.Name,
        [string]$entry.Key,
        [string]$entry.FullName,
        [string]$entry.Distance,
        (Get-NpcLifeStateText $lifeState),
        [string]$entry.ObservedAt,
        [string]$entry.X,
        [string]$entry.Y,
        [string]$entry.Z
    ) -join " "

    return $haystack.ToLowerInvariant().Contains($filter)
}

function Get-NpcScanFilteredCount($entries) {
    $filter = Get-NpcScanFilterText
    $lifeFilter = Get-NpcLifeStateFilter

    $count = 0
    foreach ($entry in @($entries)) {
        $groupName = Get-NpcGroupName $entry
        if (Test-NpcScanEntryMatchesFilter $entry $groupName $filter $lifeFilter) {
            $count++
        }
    }
    return $count
}

function Test-NpcGroupTag([object]$tag) {
    return ($tag -and $tag.PSObject.Properties["IsNpcGroup"] -and $tag.IsNpcGroup)
}

function Get-NpcGroupStateTable([string]$viewKind) {
    if ($viewKind -eq "History") { return $script:npcScanHistoryGroupExpanded }
    return $script:npcScanCurrentGroupExpanded
}

function Toggle-NpcGroup([string]$viewKind, [string]$groupName) {
    if ([string]::IsNullOrWhiteSpace($groupName)) { return }
    $state = Get-NpcGroupStateTable $viewKind
    $current = $false
    if ($state.ContainsKey($groupName)) { $current = [bool]$state[$groupName] }
    $state[$groupName] = -not $current
    Refresh-NpcScanViews
}

function Remove-DuplicateNpcEntries($entries) {
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $unique = @()
    foreach ($entry in @($entries)) {
        $identity = Get-NpcScanIdentity $entry
        if ([string]::IsNullOrWhiteSpace($identity)) { continue }
        if ($seen.Add($identity)) {
            $unique += $entry
        }
    }
    return @($unique)
}

function Read-NpcScanEntries([string]$path) {
    $items = @()
    foreach ($line in Read-FileShareSafe $path) {
        $entry = ConvertFrom-NpcScanLine $line
        if ($entry) { $items += $entry }
    }
    return @($items)
}

function ConvertTo-NpcScanLine([object]$entry) {
    $values = @(
        $entry.Name, $entry.X, $entry.Y, $entry.Z, $entry.Distance,
        $entry.FullName, $entry.Key, (Normalize-NpcLifeState ([string]$entry.LifeState)), $entry.ObservedAt
    )
    $safe = foreach ($value in $values) {
        ([string]$value).Replace("`t", " ").Replace("`r", " ").Replace("`n", " ")
    }
    return ($safe -join "`t")
}

function Save-NpcScanHistory {
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Name`tX`tY`tZ`tDistance`tFullName`tKey`tLifeState`tObservedAt")
    foreach ($entry in $script:npcScanHistoryItems) {
        [void]$lines.Add((ConvertTo-NpcScanLine $entry))
    }
    [System.IO.File]::WriteAllLines($script:npcScanHistoryPath, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Load-NpcScanHistory {
    $loaded = @(Read-NpcScanEntries $script:npcScanHistoryPath)
    $script:npcScanHistoryItems = @(Remove-DuplicateNpcEntries $loaded)
    if ($loaded.Count -ne $script:npcScanHistoryItems.Count) {
        Save-NpcScanHistory
    }
}

function Merge-NpcScanHistory($entries) {
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $indexByIdentity = @{}
    $script:npcScanHistoryItems = @(Remove-DuplicateNpcEntries $script:npcScanHistoryItems)
    for ($i = 0; $i -lt $script:npcScanHistoryItems.Count; $i++) {
        $identity = Get-NpcScanIdentity $script:npcScanHistoryItems[$i]
        if (-not [string]::IsNullOrWhiteSpace($identity)) {
            $indexByIdentity[$identity] = $i
        }
    }
    foreach ($entry in @($script:npcScanHistoryItems)) {
        [void]$seen.Add((Get-NpcScanIdentity $entry))
    }

    $added = 0
    $updated = 0
    foreach ($entry in @($entries)) {
        $identity = Get-NpcScanIdentity $entry
        if ([string]::IsNullOrWhiteSpace($identity)) { continue }
        if ($seen.Add($identity)) {
            $script:npcScanHistoryItems += $entry
            $added++
        } elseif ($indexByIdentity.ContainsKey($identity)) {
            $idx = [int]$indexByIdentity[$identity]
            $old = $script:npcScanHistoryItems[$idx]
            $fields = @("Name", "X", "Y", "Z", "Distance", "FullName", "Key", "LifeState", "ObservedAt")
            $changed = $false
            foreach ($field in $fields) {
                if ([string]$old.$field -ne [string]$entry.$field) {
                    $changed = $true
                    break
                }
            }
            if ($changed) {
                foreach ($field in $fields) {
                    $old.$field = $entry.$field
                }
                $updated++
            }
        }
    }
    if ($added -gt 0 -or $updated -gt 0) { Save-NpcScanHistory }
    return $added
}

function Add-NpcEntryToListView([System.Windows.Forms.ListView]$view, [object]$entry) {
    $item = New-Object System.Windows.Forms.ListViewItem([string]$entry.Name)
    [void]$item.SubItems.Add((Get-NpcLifeStateText ([string]$entry.LifeState)))
    [void]$item.SubItems.Add([string]$entry.Distance)
    [void]$item.SubItems.Add(("X: {0} | Y: {1} | Z: {2}" -f $entry.X, $entry.Y, $entry.Z))
    [void]$item.SubItems.Add([string]$entry.FullName)
    $item.Tag = $entry
    [void]$view.Items.Add($item)
}

function Add-NpcGroupHeaderToListView([System.Windows.Forms.ListView]$view, [string]$viewKind, [string]$groupName, [int]$count, [bool]$expanded) {
    $marker = if ($expanded) { "[-]" } else { "[+]" }
    $item = New-Object System.Windows.Forms.ListViewItem(("{0} {1} ({2})" -f $marker, $groupName, $count))
    [void]$item.SubItems.Add("")
    [void]$item.SubItems.Add("")
    [void]$item.SubItems.Add("点击展开/折叠")
    [void]$item.SubItems.Add("")
    $item.Tag = [pscustomobject]@{
        IsNpcGroup = $true
        ViewKind = $viewKind
        GroupName = $groupName
    }
    $item.Font = New-Object System.Drawing.Font($view.Font, [System.Drawing.FontStyle]::Bold)
    $item.BackColor = $script:uiWindowColor
    $item.ForeColor = $script:uiTextColor
    [void]$view.Items.Add($item)
}

function Get-NpcDistanceValue([object]$entry) {
    $value = 999999999.0
    [void][double]::TryParse([string]$entry.Distance, [ref]$value)
    return $value
}

function Refresh-NpcScanListView([System.Windows.Forms.ListView]$view, $entries, [string]$viewKind) {
    if (-not $view) { return }

    $filter = Get-NpcScanFilterText
    $lifeFilter = Get-NpcLifeStateFilter
    $groups = @{}
    foreach ($entry in @($entries)) {
        $groupName = Get-NpcGroupName $entry
        if (-not (Test-NpcScanEntryMatchesFilter $entry $groupName $filter $lifeFilter)) { continue }
        if (-not $groups.ContainsKey($groupName)) {
            $groups[$groupName] = @()
        }
        $groups[$groupName] = @($groups[$groupName]) + $entry
    }

    $state = Get-NpcGroupStateTable $viewKind
    $view.BeginUpdate()
    $view.Items.Clear()

    $singleGroups = @()
    $multiGroups = @()
    foreach ($groupName in @($groups.Keys)) {
        $groupItems = @($groups[$groupName])
        if ($groupItems.Count -gt 1) {
            $multiGroups += $groupName
        } else {
            $singleGroups += $groupName
        }
    }

    foreach ($groupName in @($singleGroups | Sort-Object @{ Expression = { Get-NpcDistanceValue (@($groups[$_])[0]) } }, @{ Expression = { $_ } })) {
        foreach ($entry in @($groups[$groupName])) {
            Add-NpcEntryToListView $view $entry
        }
    }

    foreach ($groupName in @($multiGroups | Sort-Object)) {
        $groupItems = @($groups[$groupName] | Sort-Object @{ Expression = { Get-NpcDistanceValue $_ } }, @{ Expression = { [string]$_.FullName } })
        if (-not $state.ContainsKey($groupName)) {
            $state[$groupName] = $false
        }
        $expanded = [bool]$state[$groupName]
        if ($filter) { $expanded = $true }
        Add-NpcGroupHeaderToListView $view $viewKind $groupName $groupItems.Count $expanded
        if (-not $expanded) { continue }

        foreach ($entry in $groupItems) {
            Add-NpcEntryToListView $view $entry
        }
    }

    $view.EndUpdate()
}

function Refresh-NpcScanViews {
    Refresh-NpcScanListView $npcScanCurrentListView $script:npcScanItems "Current"
    Refresh-NpcScanListView $npcScanHistoryListView $script:npcScanHistoryItems "History"

    if ($npcScanCountLabel) {
        $currentCount = @($script:npcScanItems).Count
        $historyCount = @($script:npcScanHistoryItems).Count
        $filter = Get-NpcScanFilterText
        $lifeFilter = Get-NpcLifeStateFilter
        if ($filter -or $lifeFilter -ne "ALL") {
            $npcScanCountLabel.Text = "本次 $(Get-NpcScanFilteredCount $script:npcScanItems)/$currentCount | 历史 $(Get-NpcScanFilteredCount $script:npcScanHistoryItems)/$historyCount"
        } else {
            $npcScanCountLabel.Text = "本次 $currentCount | 历史 $historyCount"
        }
    }
}

function Get-SelectedNpcEntry([System.Windows.Forms.ListView]$view) {
    if (-not $view -or $view.SelectedItems.Count -eq 0) { return $null }
    if ($view.FocusedItem -and $view.FocusedItem.Selected) {
        if (Test-NpcGroupTag $view.FocusedItem.Tag) { return $null }
        return $view.FocusedItem.Tag
    }
    if (Test-NpcGroupTag $view.SelectedItems[0].Tag) { return $null }
    return $view.SelectedItems[0].Tag
}

function Get-SelectedNpcEntries([System.Windows.Forms.ListView]$view) {
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not $view) { return @() }
    foreach ($item in @($view.SelectedItems)) {
        if ($item.Tag -and -not (Test-NpcGroupTag $item.Tag)) {
            [void]$entries.Add($item.Tag)
        }
    }
    return $entries.ToArray()
}

function Get-CurrentNpcSelection {
    $activeView = $npcScanCurrentListView
    $source = "CURRENT"
    if ($npcScanInnerTabs -and $npcScanInnerTabs.SelectedTab -eq $npcScanHistoryPage) {
        $activeView = $npcScanHistoryListView
        $source = "HISTORY"
    }
    return [pscustomobject]@{
        Source = $source
        Entries = @(Get-SelectedNpcEntries $activeView)
    }
}

function Get-CurrentNpcEntry {
    $activeView = $npcScanCurrentListView
    if ($npcScanInnerTabs -and $npcScanInnerTabs.SelectedTab -eq $npcScanHistoryPage) {
        $activeView = $npcScanHistoryListView
    }
    return Get-SelectedNpcEntry $activeView
}

function Get-NpcSpotPrefixes {
    $prefixes = New-Object System.Collections.Generic.SortedSet[string]
    foreach ($spot in Read-Spots) {
        $group = Get-SpotGroupName $spot.Name
        if ([string]::IsNullOrWhiteSpace($group) -or $group -eq "未分类") { continue }
        $prefix = $group
        if (-not ($prefix.EndsWith("-") -or $prefix.EndsWith("－") -or $prefix.EndsWith("_"))) {
            $prefix = $prefix + "-"
        }
        [void]$prefixes.Add($prefix)
    }
    if ($prefixes.Count -eq 0) {
        [void]$prefixes.Add("旧城-")
        [void]$prefixes.Add("新营地-")
        [void]$prefixes.Add("沼泽营地-")
    }

    return @($prefixes)
}

function Refresh-NpcSpotPrefixBox {
    # Kept as a compatibility no-op. The prefix selector now lives in the
    # right-click add dialog, not in the main scan toolbar.
}

function Fill-NpcSpotPrefixBox([System.Windows.Forms.ComboBox]$comboBox, [string]$current) {
    if (-not $comboBox) { return }
    $comboBox.Items.Clear()
    $prefixes = Get-NpcSpotPrefixes
    foreach ($prefix in $prefixes) {
        [void]$comboBox.Items.Add($prefix)
    }
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $comboBox.Text = $current
    } elseif ($comboBox.Items.Count -gt 0) {
        $comboBox.SelectedIndex = 0
    }
}

function Read-NpcSpotName([object]$entry) {
    if (-not $entry) { return $null }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "添加扫描人物到瞬移列表"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(480, 186)
    $dialog.Font = $font
    $dialog.BackColor = $script:uiWindowColor
    $dialog.ForeColor = $script:uiTextColor

    $prefixLabel = New-Object System.Windows.Forms.Label
    $prefixLabel.Text = "瞬移头"
    $prefixLabel.AutoSize = $true
    $prefixLabel.Location = New-Object System.Drawing.Point(14, 18)

    $prefixBox = New-Object System.Windows.Forms.ComboBox
    $prefixBox.Location = New-Object System.Drawing.Point(90, 14)
    $prefixBox.Width = 370
    $prefixBox.DropDownStyle = "DropDown"
    Fill-NpcSpotPrefixBox $prefixBox ""

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = "节点名称"
    $nameLabel.AutoSize = $true
    $nameLabel.Location = New-Object System.Drawing.Point(14, 60)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(90, 56)
    $textBox.Width = 370
    $textBox.Text = (([string]$prefixBox.Text + [string]$entry.Name).Trim())

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "确定"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(282, 126)
    $okButton.Width = 80

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "取消"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(380, 126)
    $cancelButton.Width = 80

    $prefixBox.Add_SelectedIndexChanged({
        $textBox.Text = (([string]$prefixBox.Text + [string]$entry.Name).Trim())
        $textBox.SelectionStart = $textBox.Text.Length
    })

    $dialog.Controls.AddRange(@($prefixLabel, $prefixBox, $nameLabel, $textBox, $okButton, $cancelButton))
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    $textBox.SelectAll()

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $textBox.Text.Trim()
}

function Add-NpcEntryToSpots([object]$entry) {
    if (-not $entry) { return }
    $name = Read-NpcSpotName $entry
    if ([string]::IsNullOrWhiteSpace($name)) { return }

    $spot = [pscustomobject]@{
        Name = $name
        X = $entry.X
        Y = $entry.Y
        Z = $entry.Z
    }
    $line = ConvertTo-SpotFileLine $spot
    [System.IO.File]::AppendAllText($spotsPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Append-Action "RELOAD"
    Refresh-SpotList
    Refresh-NpcSpotPrefixBox
    Set-Status ("已添加扫描人物到瞬移列表: {0}" -f $name)
}

function Invoke-NpcEntryTeleport([object]$entry) {
    if (-not $entry) { return }
    Send-TeleportAction `
        ("TELEPORT_COORD|{0}|{1}|{2}|{3}" -f $entry.X, $entry.Y, $entry.Z, $entry.Name) `
        ("已发送人物瞬移请求: {0}" -f $entry.Name) | Out-Null
}

function ConvertTo-NpcPullRequestLine([object]$entry) {
    $values = @(
        $entry.RequestId, $entry.Source, $entry.Name, $entry.X,
        $entry.Y, $entry.Z, $entry.FullName, $entry.Key
    )
    $safe = foreach ($value in $values) {
        ([string]$value).Replace("`t", " ").Replace("`r", " ").Replace("`n", " ")
    }
    return ($safe -join "`t")
}

function Read-NpcPullResults([string]$requestId) {
    $results = @()
    foreach ($line in Read-FileShareSafe $script:npcPullResultPath) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("RequestId`t")) { continue }
        $parts = $line -split "`t", 9
        if ($parts.Length -lt 6 -or $parts[0] -ne $requestId) { continue }
        $results += [pscustomobject]@{
            RequestId = $parts[0]
            Source = $parts[1]
            Name = $parts[2]
            Outcome = $parts[3]
            Reason = $parts[4]
            ResolvedFullName = $parts[5]
            TargetX = if ($parts.Length -ge 7) { $parts[6] } else { "" }
            TargetY = if ($parts.Length -ge 8) { $parts[7] } else { "" }
            TargetZ = if ($parts.Length -ge 9) { $parts[8] } else { "" }
        }
    }
    return @($results)
}

function Get-NpcPullReasonText([string]$reason) {
    $value = ([string]$reason).Trim()
    switch -Wildcard ($value) {
        "FREE_FLIGHT_ENABLED" { return "自由飞行正在开启，请先落地并关闭自由飞行" }
        "PLAYER_UNAVAILABLE" { return "无法读取玩家对象" }
        "PLAYER_LOCATION_UNAVAILABLE" { return "无法读取玩家位置" }
        "CHARACTER_SCAN_FAILED" { return "无法枚举当前已加载人物" }
        "TARGET_NOT_LOADED" { return "人物当前未加载" }
        "AMBIGUOUS_EXACT_NAME" { return "完整对象名匹配到多个目标" }
        "AMBIGUOUS_IDENTITY" { return "人物身份匹配不唯一" }
        "SPOT_COORDINATES_INVALID" { return "节点坐标无效" }
        "SPOT_NO_MATCH" { return "节点附近没有唯一名称匹配人物" }
        "SPOT_AMBIGUOUS" { return "节点附近有多个同名候选人物" }
        "DUPLICATE_TARGET" { return "与本批其他选项是同一个人物" }
        "TARGET_SLOT_MISSING" { return "没有可用的半圆落点" }
        "ACTOR_INVALID" { return "目标对象已失效" }
        "MOVE_REJECTED*" { return "游戏当前拒绝移动该人物（常见于脚本动作、交互或战斗状态，可稍后重试）" }
        "REQUEST_FILE_MISSING" { return "拉取请求文件不存在" }
        "REQUEST_ID_NOT_FOUND" { return "请求编号已失效" }
        "REQUEST_ID_MISSING" { return "请求编号为空" }
        "BATCH_LIMIT" { return "一次最多拉取20个人物" }
        "RESULT_WRITE_FAILED" { return "游戏无法写入拉取结果" }
        default {
            if ([string]::IsNullOrWhiteSpace($value)) { return "未知失败" }
            return $value
        }
    }
}

function Set-NpcPullControlsEnabled([bool]$enabled) {
    if ($npcPullMenuItem) { $npcPullMenuItem.Enabled = $enabled }
    if ($spotsPullNpcMenuItem) { $spotsPullNpcMenuItem.Enabled = $enabled }
}

function Complete-NpcPullRequest([string]$requestId, [object]$state) {
    $results = @(Read-NpcPullResults $requestId)
    $requested = [int]([string]$state.REQUESTED)
    $moved = [int]([string]$state.MOVED)
    $failed = [int]([string]$state.FAILED)
    $duplicate = [int]([string]$state.DUPLICATE)
    $summary = "人物拉取完成：请求 $requested，成功 $moved，失败 $failed，重复 $duplicate"
    Set-Status $summary
    if ($npcScanStatusLabel) { $npcScanStatusLabel.Text = $summary }

    if ($failed -le 0 -and ([string]$state.STATE).ToUpperInvariant() -ne "FAILED") { return }

    $failureLines = New-Object System.Collections.Generic.List[string]
    foreach ($result in @($results | Where-Object { $_.Outcome -eq "FAILED" } | Select-Object -First 10)) {
        [void]$failureLines.Add(("{0}：{1}" -f $result.Name, (Get-NpcPullReasonText $result.Reason)))
    }
    if ($failed -gt $failureLines.Count) {
        [void]$failureLines.Add(("另有 {0} 个失败目标。" -f ($failed - $failureLines.Count)))
    }
    if ($failureLines.Count -eq 0) {
        [void]$failureLines.Add((Get-NpcPullReasonText ([string]$state.MESSAGE)))
    }
    $detail = $summary + "`r`n`r`n" + ($failureLines -join "`r`n")
    [System.Windows.Forms.MessageBox]::Show(
        $detail,
        "人物拉取结果",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Ensure-NpcPullTimer {
    if ($script:npcPullTimer) { return }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        if ([string]::IsNullOrWhiteSpace([string]$script:npcPullPendingRequestId)) {
            $script:npcPullTimer.Stop()
            return
        }
        if ([DateTime]::UtcNow -gt $script:npcPullDeadlineUtc) {
            $timedOutId = $script:npcPullPendingRequestId
            $script:npcPullPendingRequestId = $null
            $script:npcPullTimer.Stop()
            Set-NpcPullControlsEnabled $true
            Set-Status "人物拉取等待超时，请检查游戏是否已加载新版核心。"
            [System.Windows.Forms.MessageBox]::Show(
                "人物拉取等待超时。请完整重启游戏和修改器后重试。`r`n请求：$timedOutId",
                "人物拉取失败",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $state = Read-KeyValueState $script:npcPullStatusPath
        if (-not $state -or [string]$state.REQUEST_ID -ne [string]$script:npcPullPendingRequestId) { return }
        $stateName = ([string]$state.STATE).ToUpperInvariant()
        if ($stateName -notin @("DONE", "FAILED")) { return }

        $completedId = [string]$script:npcPullPendingRequestId
        $script:npcPullPendingRequestId = $null
        $script:npcPullTimer.Stop()
        Set-NpcPullControlsEnabled $true
        Complete-NpcPullRequest $completedId $state
    })
    $script:npcPullTimer = $timer
}

function Start-NpcPullRequest([object[]]$entries, [string]$source) {
    $selected = @($entries | Where-Object { $_ })
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("请先选择至少一个人物或节点。", "人物拉取") | Out-Null
        return
    }
    if ($selected.Count -gt 20) {
        [System.Windows.Forms.MessageBox]::Show("一次最多拉取20个人物，请减少选择。", "人物拉取") | Out-Null
        return
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:npcPullPendingRequestId)) {
        [System.Windows.Forms.MessageBox]::Show("上一批人物拉取仍在处理中，请稍候。", "人物拉取") | Out-Null
        return
    }

    $requestId = [Guid]::NewGuid().ToString("N")
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("RequestId`tSource`tName`tX`tY`tZ`tFullName`tKey")
    foreach ($entry in $selected) {
        $request = [pscustomobject]@{
            RequestId = $requestId
            Source = $source
            Name = [string]$entry.Name
            X = [string]$entry.X
            Y = [string]$entry.Y
            Z = [string]$entry.Z
            FullName = if ($source -eq "SPOT") { "" } else { [string]$entry.FullName }
            Key = if ($source -eq "SPOT") { "" } else { [string]$entry.Key }
        }
        [void]$lines.Add((ConvertTo-NpcPullRequestLine $request))
    }

    $tempPath = $script:npcPullRequestPath + "." + $PID + ".tmp"
    $backupPath = $script:npcPullRequestPath + "." + $PID + ".bak"
    try {
        [System.IO.File]::WriteAllLines($tempPath, $lines, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $script:npcPullRequestPath) {
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            [System.IO.File]::Replace($tempPath, $script:npcPullRequestPath, $backupPath)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($tempPath, $script:npcPullRequestPath)
        }

        $script:npcPullPendingRequestId = $requestId
        $script:npcPullDeadlineUtc = [DateTime]::UtcNow.AddSeconds(8)
        Set-NpcPullControlsEnabled $false
        Ensure-NpcPullTimer
        $script:npcPullTimer.Start()
        Append-Action ("PULL_NPCS|{0}" -f $requestId)
        $message = "已发送人物拉取请求：$($selected.Count) 个目标"
        Set-Status $message
        if ($npcScanStatusLabel) { $npcScanStatusLabel.Text = $message }
    } catch {
        $script:npcPullPendingRequestId = $null
        if ($script:npcPullTimer) { $script:npcPullTimer.Stop() }
        Set-NpcPullControlsEnabled $true
        Remove-Item -LiteralPath $tempPath,$backupPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Start-SelectedNpcPull {
    $selection = Get-CurrentNpcSelection
    Start-NpcPullRequest @($selection.Entries) $selection.Source
}

function Start-SelectedSpotNpcPull {
    $spots = @(Get-SelectedSpots | Sort-Object Index)
    Start-NpcPullRequest $spots "SPOT"
}

function Copy-NpcEntryNode([object]$entry) {
    if (-not $entry) { return }
    $name = ([string]$entry.Name).Replace("|", "_")
    Copy-SpotText ("{0}|{1}|{2}|{3}" -f $name, $entry.X, $entry.Y, $entry.Z)
    Set-Status ("已复制扫描节点: {0}" -f $entry.Name)
}

function Refresh-NpcScanFromFile {
    $script:npcScanItems = @(Remove-DuplicateNpcEntries (Read-NpcScanEntries $script:npcScanResultPath))
    $added = Merge-NpcScanHistory $script:npcScanItems
    Refresh-NpcScanViews

    $stateText = "扫描完成，本次 $(@($script:npcScanItems).Count) 人；历史新增 $added"
    if ($npcScanStatusLabel) {
        $npcScanStatusLabel.Text = $stateText
    }
    Set-Status $stateText
}

function Start-NpcNearbyScan {
    $requestId = [Guid]::NewGuid().ToString("N")
    $script:npcScanItems = @()
    Refresh-NpcScanViews
    $npcScanButton.Enabled = $false

    try {
        Append-Action ("SCAN_NEARBY_NPCS|{0}" -f $requestId)
        if ($npcScanStatusLabel) { $npcScanStatusLabel.Text = "正在读取当前可用人物..." }
        Set-Status "已发送扫描周围人物请求。"

        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            [System.Windows.Forms.Application]::DoEvents()

            $state = Read-KeyValueState $script:npcScanStatePath
            if (-not $state -or [string]$state.REQUEST_ID -ne $requestId) { continue }
            $stateName = ([string]$state.STATE).ToUpperInvariant()
            if ($stateName -eq "BUSY") { continue }
            if ($stateName -eq "DONE") {
                Refresh-NpcScanFromFile
                return
            }
            if ($stateName -eq "FAILED") {
                $message = [string]$state.MESSAGE
                if ([string]::IsNullOrWhiteSpace($message)) { $message = "游戏端扫描失败" }
                if ($npcScanStatusLabel) { $npcScanStatusLabel.Text = "扫描失败：$message" }
                Set-Status "扫描人物失败：$message"
                return
            }
        }

        $message = "本次扫描等待超时，未载入上一位置的旧结果；请重试。"
        if ($npcScanStatusLabel) { $npcScanStatusLabel.Text = $message }
        Set-Status $message
    } finally {
        $npcScanButton.Enabled = $true
    }
}

$font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$script:uiEnglishFont = New-Object System.Drawing.Font("Segoe UI", 9)
$script:uiButtonFontCache = @{}
$script:uiThemes = [ordered]@{
    "默认白" = @{
        Window = [System.Drawing.SystemColors]::Control
        Input  = [System.Drawing.Color]::White
        Text   = [System.Drawing.Color]::Black
        Link   = [System.Drawing.Color]::FromArgb(0, 102, 204)
    }
    "柔和绿" = @{
        Window = [System.Drawing.Color]::FromArgb(232, 242, 229)
        Input  = [System.Drawing.Color]::FromArgb(250, 255, 246)
        Text   = [System.Drawing.Color]::FromArgb(24, 55, 38)
        Link   = [System.Drawing.Color]::FromArgb(34, 105, 76)
    }
    "米杏色" = @{
        Window = [System.Drawing.Color]::FromArgb(242, 236, 220)
        Input  = [System.Drawing.Color]::FromArgb(255, 252, 240)
        Text   = [System.Drawing.Color]::FromArgb(68, 52, 35)
        Link   = [System.Drawing.Color]::FromArgb(130, 82, 18)
    }
    "淡灰蓝" = @{
        Window = [System.Drawing.Color]::FromArgb(228, 235, 240)
        Input  = [System.Drawing.Color]::FromArgb(247, 251, 253)
        Text   = [System.Drawing.Color]::FromArgb(34, 48, 62)
        Link   = [System.Drawing.Color]::FromArgb(38, 92, 140)
    }
    "夜间灰" = @{
        Window = [System.Drawing.Color]::FromArgb(47, 50, 54)
        Input  = [System.Drawing.Color]::FromArgb(63, 67, 72)
        Text   = [System.Drawing.Color]::FromArgb(235, 235, 228)
        Link   = [System.Drawing.Color]::FromArgb(137, 184, 232)
    }
}
$script:currentThemeName = "默认白"
$script:uiTextColor = $script:uiThemes[$script:currentThemeName].Text
$script:uiWindowColor = $script:uiThemes[$script:currentThemeName].Window
$script:uiInputColor = $script:uiThemes[$script:currentThemeName].Input
$script:uiLinkColor = $script:uiThemes[$script:currentThemeName].Link

function Set-ThemeColors([string]$themeName) {
    if (-not $script:uiThemes.Contains($themeName)) {
        $themeName = "默认白"
    }

    $theme = $script:uiThemes[$themeName]
    $script:currentThemeName = $themeName
    $script:uiWindowColor = $theme.Window
    $script:uiInputColor = $theme.Input
    $script:uiTextColor = $theme.Text
    $script:uiLinkColor = $theme.Link
}

function Set-ToolStripColors($toolStrip) {
    if (-not $toolStrip) { return }

    $toolStrip.BackColor = $script:uiWindowColor
    $toolStrip.ForeColor = $script:uiTextColor
    foreach ($item in $toolStrip.Items) {
        $item.BackColor = $script:uiWindowColor
        $item.ForeColor = $script:uiTextColor
        if ($item.DropDownItems) {
            foreach ($child in $item.DropDownItems) {
                $child.BackColor = $script:uiWindowColor
                $child.ForeColor = $script:uiTextColor
            }
        }
    }
}

function Set-ControlColors($control) {
    if (-not $control) { return }

    if ($control -is [System.Windows.Forms.TextBox] -or
        $control -is [System.Windows.Forms.RichTextBox] -or
        $control -is [System.Windows.Forms.ListView] -or
        $control -is [System.Windows.Forms.ComboBox] -or
        $control -is [System.Windows.Forms.TreeView]) {
        $control.BackColor = $script:uiInputColor
        $control.ForeColor = $script:uiTextColor
    } elseif ($control -is [System.Windows.Forms.LinkLabel]) {
        $control.BackColor = $script:uiWindowColor
        $control.ForeColor = $script:uiTextColor
        $control.LinkColor = $script:uiLinkColor
        $control.ActiveLinkColor = [System.Drawing.Color]::FromArgb(180, 60, 0)
        $control.VisitedLinkColor = [System.Drawing.Color]::FromArgb(90, 60, 130)
    } elseif ($control -is [System.Windows.Forms.Button] -or
              $control -is [System.Windows.Forms.Label] -or
              $control -is [System.Windows.Forms.TabControl] -or
              $control -is [System.Windows.Forms.TabPage] -or
              $control -is [System.Windows.Forms.Panel] -or
              $control -is [System.Windows.Forms.TableLayoutPanel] -or
              $control -is [System.Windows.Forms.FlowLayoutPanel] -or
              $control -is [System.Windows.Forms.SplitContainer] -or
              $control -is [System.Windows.Forms.Form]) {
        $control.BackColor = $script:uiWindowColor
        $control.ForeColor = $script:uiTextColor
    } elseif ($control -is [System.Windows.Forms.StatusStrip]) {
        $control.BackColor = $script:uiWindowColor
        $control.ForeColor = $script:uiTextColor
    }

    foreach ($child in $control.Controls) {
        Set-ControlColors $child
    }
}

function Apply-UiTheme([string]$themeName) {
    Set-ThemeColors $themeName

    if ($form) {
        Set-ControlColors $form
    }
    Set-ToolStripColors $spotsContextMenu
    Set-ToolStripColors $npcContextMenu
    Set-ToolStripColors $itemContextMenu
    Set-ToolStripColors $inventoryContextMenu
    if ($statusStrip) {
        $statusStrip.BackColor = $script:uiWindowColor
        $statusStrip.ForeColor = $script:uiTextColor
    }
    if ($script:statusLabel) {
        $script:statusLabel.ForeColor = $script:uiTextColor
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $windowTitle
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(980, 680)
$form.MinimumSize = New-Object System.Drawing.Size(900, 620)
$form.Font = $font

$appIconPath = Join-Path $scriptDir "app_icon.png"
if (Test-Path -LiteralPath $appIconPath) {
    try {
        $iconBmp = [System.Drawing.Bitmap]::FromFile($appIconPath)
        $form.Icon = [System.Drawing.Icon]::FromHandle($iconBmp.GetHicon())
    } catch {}
}
$form.KeyPreview = $true
$form.TopMost = $false

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"

$spotsTab = New-Object System.Windows.Forms.TabPage
$spotsTab.Text = "瞬移节点"

$modifyTab = New-Object System.Windows.Forms.TabPage
$modifyTab.Text = "修改"

$modifyTabs = New-Object System.Windows.Forms.TabControl
$modifyTabs.Dock = "Fill"

$moneyTab = New-Object System.Windows.Forms.TabPage
$moneyTab.Text = "矿石"

$attrTab = New-Object System.Windows.Forms.TabPage
$attrTab.Text = "人物属性"

$itemUnlockTab = New-Object System.Windows.Forms.TabPage
$itemUnlockTab.Text = "物品/开锁/高亮"

$npcScanTab = New-Object System.Windows.Forms.TabPage
$npcScanTab.Text = "扫描周围人物"

$worldTimeTab = New-Object System.Windows.Forms.TabPage
$worldTimeTab.Text = "自由飞翔/时间"

$diagTab = New-Object System.Windows.Forms.TabPage
$diagTab.Text = "日志/诊断"

$walkthroughTab = New-Object System.Windows.Forms.TabPage
$walkthroughTab.Text = "流程攻略"

$guideTab = New-Object System.Windows.Forms.TabPage
$guideTab.Text = "操作指南"

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = "Top"
$topPanel.Height = 88
$topPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 8)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "搜索"
$searchLabel.Location = New-Object System.Drawing.Point(12, 16)
$searchLabel.AutoSize = $true

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(64, 12)
$searchBox.Width = 220

$saveLabel = New-Object System.Windows.Forms.Label
$saveLabel.Text = "保存名称"
$saveLabel.Location = New-Object System.Drawing.Point(310, 16)
$saveLabel.AutoSize = $true

$saveNameBox = New-Object System.Windows.Forms.TextBox
$saveNameBox.Location = New-Object System.Drawing.Point(384, 12)
$saveNameBox.Width = 180

$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Location = New-Object System.Drawing.Point(590, 16)
$countLabel.AutoSize = $true
$countLabel.Text = "节点 0"

$teleportCoordLabel = New-Object System.Windows.Forms.Label
$teleportCoordLabel.Text = "手动坐标"
$teleportCoordLabel.AutoSize = $true
$teleportCoordLabel.Location = New-Object System.Drawing.Point(12, 56)

$teleportCoordBox = New-Object System.Windows.Forms.TextBox
$teleportCoordBox.Location = New-Object System.Drawing.Point(92, 52)
$teleportCoordBox.Width = 470
$teleportCoordBox.Text = "X: 0 | Y: 0 | Z: 0"

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = "Top"
$buttonPanel.Height = 42
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
$buttonPanel.WrapContents = $false

function New-UiButton([string]$text, [int]$width = 132) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $text
    $button.Width = $width
    $button.Height = 32
    $button.AutoEllipsis = $true
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    return $button
}

$refreshButton = New-UiButton "刷新列表" 100
$saveButton = New-UiButton "保存当前位置" 132
$saveButton.Location = New-Object System.Drawing.Point(582, 10)
$teleportCoordButton = New-UiButton "手动坐标确认" 132
$teleportCoordButton.Location = New-Object System.Drawing.Point(582, 50)

$listView = New-Object System.Windows.Forms.ListView
$listView.Dock = "Fill"
$listView.View = "Details"
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.HideSelection = $false
$listView.MultiSelect = $true
$listView.LabelEdit = $false
$listView.AllowDrop = $false
$listView.Columns.Add("名称", 260) | Out-Null
$listView.Columns.Add("序号", 80) | Out-Null
$listView.Columns.Add("坐标", 560) | Out-Null

$spotsContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$spotsContextMenu.ShowImageMargin = $false
$spotsContextMenu.BackColor = $script:uiWindowColor
$spotsContextMenu.ForeColor = $script:uiTextColor

$spotsTeleportMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("瞬移到这里")
$spotsPullNpcMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("尝试拉取人物到身边")
$spotsRenameMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("重命名")
$spotsDeleteMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("删除选中")
$spotsCopyCoordsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("复制坐标")
$spotsBindNumpadMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("绑定到小键盘")
$spotsClearNumpadMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("清除小键盘绑定")
$script:numpadBindMenuItems = @{}
$script:numpadClearMenuItems = @{}
foreach ($keyNumber in @(1,2,3,4,5,6,7,8,9,0)) {
    $bindItem = New-Object System.Windows.Forms.ToolStripMenuItem(("小键盘 {0}" -f $keyNumber))
    $bindItem.Tag = $keyNumber
    $bindItem.Add_Click({
        param($sender, $e)
        $spot = Require-SelectedSpot
        if (-not $spot) { return }
        Set-NumpadBinding ([int]$sender.Tag) $spot
    })
    [void]$spotsBindNumpadMenuItem.DropDownItems.Add($bindItem)
    $script:numpadBindMenuItems[$keyNumber] = $bindItem

    $clearItem = New-Object System.Windows.Forms.ToolStripMenuItem(("小键盘 {0}" -f $keyNumber))
    $clearItem.Tag = $keyNumber
    $clearItem.Add_Click({
        param($sender, $e)
        Clear-NumpadBinding ([int]$sender.Tag)
    })
    [void]$spotsClearNumpadMenuItem.DropDownItems.Add($clearItem)
    $script:numpadClearMenuItems[$keyNumber] = $clearItem
}
foreach ($menuItem in @($spotsTeleportMenuItem, $spotsPullNpcMenuItem, $spotsRenameMenuItem, $spotsDeleteMenuItem, $spotsCopyCoordsMenuItem, $spotsBindNumpadMenuItem, $spotsClearNumpadMenuItem)) {
    $menuItem.ForeColor = $script:uiTextColor
    $menuItem.BackColor = $script:uiWindowColor
    if ($menuItem.DropDownItems) {
        foreach ($child in $menuItem.DropDownItems) {
            $child.ForeColor = $script:uiTextColor
            $child.BackColor = $script:uiWindowColor
        }
    }
}

$spotsContextMenu.Items.AddRange(@(
    $spotsTeleportMenuItem,
    $spotsPullNpcMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $spotsRenameMenuItem,
    $spotsDeleteMenuItem,
    $spotsBindNumpadMenuItem,
    $spotsClearNumpadMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $spotsCopyCoordsMenuItem
))

$npcScanLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$npcScanLayoutPanel.Dock = "Fill"
$npcScanLayoutPanel.ColumnCount = 1
$npcScanLayoutPanel.RowCount = 3
$npcScanLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12)
$npcScanLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$npcScanLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
$npcScanLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$npcScanLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32))) | Out-Null

$npcScanTopPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$npcScanTopPanel.Dock = "Fill"
$npcScanTopPanel.WrapContents = $false
$npcScanTopPanel.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

$npcScanButton = New-UiButton "扫描" 88

$npcScanStateFilterLabel = New-Object System.Windows.Forms.Label
$npcScanStateFilterLabel.Text = "状态"
$npcScanStateFilterLabel.AutoSize = $true
$npcScanStateFilterLabel.Margin = New-Object System.Windows.Forms.Padding(8, 8, 4, 0)

$npcScanStateFilterCombo = New-Object System.Windows.Forms.ComboBox
$npcScanStateFilterCombo.Width = 112
$npcScanStateFilterCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$npcScanStateFilterCombo.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)
@("仅存活", "全部", "倒地/死亡", "未知") | ForEach-Object {
    [void]$npcScanStateFilterCombo.Items.Add($_)
}
$npcScanStateFilterCombo.SelectedIndex = 0

$npcScanSearchLabel = New-Object System.Windows.Forms.Label
$npcScanSearchLabel.Text = "搜索"
$npcScanSearchLabel.AutoSize = $true
$npcScanSearchLabel.Margin = New-Object System.Windows.Forms.Padding(8, 8, 4, 0)

$npcScanSearchBox = New-Object System.Windows.Forms.TextBox
$npcScanSearchBox.Width = 240
$npcScanSearchBox.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)

$npcScanClearSearchButton = New-UiButton "清空" 64

$npcScanCountLabel = New-Object System.Windows.Forms.Label
$npcScanCountLabel.Text = "本次 0 | 历史 0"
$npcScanCountLabel.AutoSize = $true
$npcScanCountLabel.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)

$npcScanTopPanel.Controls.AddRange(@(
    $npcScanButton,
    $npcScanStateFilterLabel,
    $npcScanStateFilterCombo,
    $npcScanSearchLabel,
    $npcScanSearchBox,
    $npcScanClearSearchButton,
    $npcScanCountLabel
))

$npcScanInnerTabs = New-Object System.Windows.Forms.TabControl
$npcScanInnerTabs.Dock = "Fill"

$npcScanCurrentPage = New-Object System.Windows.Forms.TabPage
$npcScanCurrentPage.Text = "本次扫描"

$npcScanHistoryPage = New-Object System.Windows.Forms.TabPage
$npcScanHistoryPage.Text = "历史扫描"

function New-NpcScanListView([string]$stateColumnName) {
    $view = New-Object System.Windows.Forms.ListView
    $view.Dock = "Fill"
    $view.View = "Details"
    $view.FullRowSelect = $true
    $view.GridLines = $true
    $view.HideSelection = $false
    $view.MultiSelect = $true
    $view.Columns.Add("名称", 160) | Out-Null
    $view.Columns.Add($stateColumnName, 90) | Out-Null
    $view.Columns.Add("距离", 80) | Out-Null
    $view.Columns.Add("坐标", 240) | Out-Null
    $view.Columns.Add("对象", 370) | Out-Null
    return $view
}

$npcScanCurrentListView = New-NpcScanListView "状态"
$npcScanHistoryListView = New-NpcScanListView "最近状态"

$npcContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$npcContextMenu.ShowImageMargin = $false
$npcContextMenu.BackColor = $script:uiWindowColor
$npcContextMenu.ForeColor = $script:uiTextColor
$npcTeleportMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("瞬移到这里")
$npcPullMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("拉到身边")
$npcAddSpotMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("添加到瞬移列表")
$npcCopyNodeMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("复制节点")
foreach ($menuItem in @($npcTeleportMenuItem, $npcPullMenuItem, $npcAddSpotMenuItem, $npcCopyNodeMenuItem)) {
    $menuItem.ForeColor = $script:uiTextColor
    $menuItem.BackColor = $script:uiWindowColor
}
$npcContextMenu.Items.AddRange(@(
    $npcTeleportMenuItem,
    $npcPullMenuItem,
    $npcAddSpotMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $npcCopyNodeMenuItem
))
$npcContextMenu.Add_Opening({
    param($sender, $e)
    if ($script:npcSuppressContextMenuOnce) {
        $script:npcSuppressContextMenuOnce = $false
        $e.Cancel = $true
        return
    }
    if (-not (Get-CurrentNpcEntry)) {
        $e.Cancel = $true
    }
})
$npcScanCurrentListView.ContextMenuStrip = $npcContextMenu
$npcScanHistoryListView.ContextMenuStrip = $npcContextMenu

$npcScanCurrentPage.Controls.Add($npcScanCurrentListView)
$npcScanHistoryPage.Controls.Add($npcScanHistoryListView)
$npcScanInnerTabs.TabPages.Add($npcScanCurrentPage) | Out-Null
$npcScanInnerTabs.TabPages.Add($npcScanHistoryPage) | Out-Null

$npcScanStatusLabel = New-Object System.Windows.Forms.Label
$npcScanStatusLabel.Dock = "Fill"
$npcScanStatusLabel.Text = "按扫描后读取周围人物；Ctrl/Shift 可多选，右键可拉到身边。"
$npcScanStatusLabel.AutoEllipsis = $true

$npcScanLayoutPanel.Controls.Add($npcScanTopPanel, 0, 0)
$npcScanLayoutPanel.Controls.Add($npcScanInnerTabs, 0, 1)
$npcScanLayoutPanel.Controls.Add($npcScanStatusLabel, 0, 2)
$npcScanTab.Controls.Add($npcScanLayoutPanel)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$script:statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:statusLabel.Text = "F6 可唤起本窗口；右键节点可绑定小键盘；UI 打开时小键盘输入不会触发瞬移。"
$statusStrip.Items.Add($script:statusLabel) | Out-Null

$topPanel.Controls.AddRange(@(
    $searchLabel,
    $searchBox,
    $saveLabel,
    $saveNameBox,
    $saveButton,
    $countLabel,
    $teleportCoordLabel,
    $teleportCoordBox,
    $teleportCoordButton
))
$buttonPanel.Controls.AddRange(@($refreshButton))
$spotsLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$spotsLayoutPanel.Dock = "Fill"
$spotsLayoutPanel.ColumnCount = 1
$spotsLayoutPanel.RowCount = 4
$spotsLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$spotsLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$spotsLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 88))) | Out-Null
$spotsLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42))) | Out-Null
$spotsLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$spotsLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$spotsLayoutPanel.Controls.Add($topPanel, 0, 0)
$spotsLayoutPanel.Controls.Add($buttonPanel, 0, 1)
$spotsLayoutPanel.Controls.Add($listView, 0, 2)
$spotsLayoutPanel.Controls.Add($statusStrip, 0, 3)
$spotsTab.Controls.Add($spotsLayoutPanel)

$moneyTopPanel = New-Object System.Windows.Forms.Panel
$moneyTopPanel.Dock = "Top"
$moneyTopPanel.Height = 104
$moneyTopPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 8)

$moneyInfoLabel = New-Object System.Windows.Forms.Label
$moneyInfoLabel.Text = "矿石是当前游戏货币。底层代码 ItMi_Orenugget，使用已验证的背包原生增删，不读取当前总数。"
$moneyInfoLabel.AutoSize = $true
$moneyInfoLabel.Location = New-Object System.Drawing.Point(12, 14)

$moneyCurrentValueLabel = New-Object System.Windows.Forms.Label
$moneyCurrentValueLabel.Text = "货币"
$moneyCurrentValueLabel.AutoSize = $true
$moneyCurrentValueLabel.Location = New-Object System.Drawing.Point(12, 48)

$moneyCurrentValueBox = New-Object System.Windows.Forms.TextBox
$moneyCurrentValueBox.Location = New-Object System.Drawing.Point(90, 44)
$moneyCurrentValueBox.Width = 160
$moneyCurrentValueBox.ReadOnly = $true
$moneyCurrentValueBox.Text = "矿石 / ItMi_Orenugget"

$moneyWriteValueLabel = New-Object System.Windows.Forms.Label
$moneyWriteValueLabel.Text = "自定义数量"
$moneyWriteValueLabel.AutoSize = $true
$moneyWriteValueLabel.Location = New-Object System.Drawing.Point(280, 48)

$moneyWriteValueBox = New-Object System.Windows.Forms.TextBox
$moneyWriteValueBox.Location = New-Object System.Drawing.Point(358, 44)
$moneyWriteValueBox.Width = 160
$moneyWriteValueBox.Text = "100"

$moneyCandidateCountLabel = New-Object System.Windows.Forms.Label
$moneyCandidateCountLabel.Text = "代码 ItMi_Orenugget"
$moneyCandidateCountLabel.AutoSize = $true
$moneyCandidateCountLabel.Location = New-Object System.Drawing.Point(548, 48)

$moneyStatusLabel = New-Object System.Windows.Forms.Label
$moneyStatusLabel.Text = "状态: 等待操作"
$moneyStatusLabel.AutoSize = $false
$moneyStatusLabel.Width = 900
$moneyStatusLabel.Height = 22
$moneyStatusLabel.Location = New-Object System.Drawing.Point(12, 76)

$moneyButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$moneyButtonPanel.Dock = "Top"
$moneyButtonPanel.Height = 54
$moneyButtonPanel.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
$moneyButtonPanel.WrapContents = $true

$oreCustomAddButton = New-UiButton "自定义增加" 132
$oreCustomRemoveButton = New-UiButton "自定义减少" 132

$moneyCandidateListView = New-Object System.Windows.Forms.ListView
$moneyCandidateListView.Dock = "Fill"
$moneyCandidateListView.View = "Details"
$moneyCandidateListView.FullRowSelect = $true
$moneyCandidateListView.GridLines = $true
$moneyCandidateListView.HideSelection = $false
$moneyCandidateListView.MultiSelect = $false
$moneyCandidateListView.Columns.Add("名称", 120) | Out-Null
$moneyCandidateListView.Columns.Add("底层代码", 180) | Out-Null
$moneyCandidateListView.Columns.Add("方式", 180) | Out-Null
$moneyCandidateListView.Columns.Add("说明", 560) | Out-Null
$moneyCandidateListView.Columns.Add("来源", 100) | Out-Null

$moneyDetailBox = New-Object System.Windows.Forms.TextBox
$moneyDetailBox.Dock = "Fill"
$moneyDetailBox.Height = 76
$moneyDetailBox.Multiline = $true
$moneyDetailBox.ReadOnly = $true
$moneyDetailBox.ScrollBars = "Horizontal"
$moneyDetailBox.WordWrap = $false
$moneyDetailBox.BackColor = [System.Drawing.Color]::White
$moneyDetailBox.Text = "点击按钮后会写入 TeleportMod_item_actions.txt；后端按 INV_NATIVE_ADD/REMOVE 执行。"

$moneyLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$moneyLayoutPanel.Dock = "Fill"
$moneyLayoutPanel.ColumnCount = 1
$moneyLayoutPanel.RowCount = 4
$moneyLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$moneyLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$moneyLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$moneyLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$moneyLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$moneyLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 76))) | Out-Null

$moneyLayoutPanel.Controls.Add($moneyTopPanel, 0, 0)
$moneyLayoutPanel.Controls.Add($moneyButtonPanel, 0, 1)
$moneyLayoutPanel.Controls.Add($moneyCandidateListView, 0, 2)
$moneyLayoutPanel.Controls.Add($moneyDetailBox, 0, 3)

$moneyTab.Controls.Add($moneyLayoutPanel)

$moneyTopPanel.Controls.AddRange(@(
    $moneyInfoLabel,
    $moneyCurrentValueLabel,
    $moneyCurrentValueBox,
    $moneyWriteValueLabel,
    $moneyWriteValueBox,
    $moneyCandidateCountLabel,
    $moneyStatusLabel
))

$moneyButtonPanel.Controls.AddRange(@(
    $oreCustomAddButton,
    $oreCustomRemoveButton
))

$attrTopPanel = New-Object System.Windows.Forms.Panel
$attrTopPanel.Dock = "Top"
$attrTopPanel.Height = 126
$attrTopPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 8)

$attrInfoLabel = New-Object System.Windows.Forms.Label
$attrInfoLabel.Text = "选择属性后先读取；写入可选择 CurrentValue、BaseValue 或两者。属性使用独立 C++ 桥，不混入瞬移桥。"
$attrInfoLabel.AutoSize = $true
$attrInfoLabel.Location = New-Object System.Drawing.Point(12, 14)

$attrSelectLabel = New-Object System.Windows.Forms.Label
$attrSelectLabel.Text = "属性"
$attrSelectLabel.AutoSize = $true
$attrSelectLabel.Location = New-Object System.Drawing.Point(12, 48)

$attrSelectBox = New-Object System.Windows.Forms.ComboBox
$attrSelectBox.Location = New-Object System.Drawing.Point(60, 44)
$attrSelectBox.Width = 170
$attrSelectBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$attrSelectBox.DisplayMember = "Name"
$attrSelectBox.ValueMember = "Key"
foreach ($def in $script:attributeDefinitions) {
    [void]$attrSelectBox.Items.Add($def)
}
if ($attrSelectBox.Items.Count -gt 0) {
    $attrSelectBox.SelectedIndex = 0
}

$attrCurrentValueLabel = New-Object System.Windows.Forms.Label
$attrCurrentValueLabel.Text = "当前值"
$attrCurrentValueLabel.AutoSize = $true
$attrCurrentValueLabel.Location = New-Object System.Drawing.Point(260, 48)

$attrCurrentValueBox = New-Object System.Windows.Forms.TextBox
$attrCurrentValueBox.Location = New-Object System.Drawing.Point(322, 44)
$attrCurrentValueBox.Width = 140

$attrWriteValueLabel = New-Object System.Windows.Forms.Label
$attrWriteValueLabel.Text = "写入值"
$attrWriteValueLabel.AutoSize = $true
$attrWriteValueLabel.Location = New-Object System.Drawing.Point(490, 48)

$attrWriteValueBox = New-Object System.Windows.Forms.TextBox
$attrWriteValueBox.Location = New-Object System.Drawing.Point(552, 44)
$attrWriteValueBox.Width = 140

$attrCandidateCountLabel = New-Object System.Windows.Forms.Label
$attrCandidateCountLabel.Text = "CT固定链"
$attrCandidateCountLabel.AutoSize = $true
$attrCandidateCountLabel.Location = New-Object System.Drawing.Point(722, 48)

$attrStatusLabel = New-Object System.Windows.Forms.Label
$attrStatusLabel.Text = "状态: 等待操作"
$attrStatusLabel.AutoSize = $false
$attrStatusLabel.Width = 900
$attrStatusLabel.Height = 42
$attrStatusLabel.Location = New-Object System.Drawing.Point(12, 78)

$attrButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$attrButtonPanel.Dock = "Top"
$attrButtonPanel.Height = 54
$attrButtonPanel.Padding = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
$attrButtonPanel.WrapContents = $true

$attrDetectButton = New-UiButton "读取属性" 110
$attrRefreshButton = New-UiButton "写入当前值" 120
$attrWriteSelectedButton = New-UiButton "写入基础值" 120
$attrPinButton = New-UiButton "两者都写入" 120
$attrClearButton = New-UiButton "清空显示" 100

$attrCandidateListView = New-Object System.Windows.Forms.ListView
$attrCandidateListView.Dock = "Fill"
$attrCandidateListView.View = "Details"
$attrCandidateListView.FullRowSelect = $true
$attrCandidateListView.GridLines = $true
$attrCandidateListView.HideSelection = $false
$attrCandidateListView.MultiSelect = $false
$attrCandidateListView.Columns.Add("属性", 140) | Out-Null
$attrCandidateListView.Columns.Add("字段", 140) | Out-Null
$attrCandidateListView.Columns.Add("值", 140) | Out-Null
$attrCandidateListView.Columns.Add("来源", 140) | Out-Null
$attrCandidateListView.Columns.Add("Key", 160) | Out-Null
$attrCandidateListView.Columns.Add("备注", 300) | Out-Null

$attrDetailBox = New-Object System.Windows.Forms.TextBox
$attrDetailBox.Dock = "Fill"
$attrDetailBox.Height = 82
$attrDetailBox.Multiline = $true
$attrDetailBox.ReadOnly = $true
$attrDetailBox.ScrollBars = "Horizontal"
$attrDetailBox.WordWrap = $false
$attrDetailBox.BackColor = [System.Drawing.Color]::White
$attrDetailBox.Text = "建议先读取 Strength / Dexterity / SkillPoints；写入时先用小值测试并回游戏确认。"

$attrLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$attrLayoutPanel.Dock = "Fill"
$attrLayoutPanel.ColumnCount = 1
$attrLayoutPanel.RowCount = 4
$attrLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$attrLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$attrLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$attrLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$attrLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$attrLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 82))) | Out-Null

$attrLayoutPanel.Controls.Add($attrTopPanel, 0, 0)
$attrLayoutPanel.Controls.Add($attrButtonPanel, 0, 1)
$attrLayoutPanel.Controls.Add($attrCandidateListView, 0, 2)
$attrLayoutPanel.Controls.Add($attrDetailBox, 0, 3)

$attrTab.Controls.Add($attrLayoutPanel)

$attrTopPanel.Controls.AddRange(@(
    $attrInfoLabel,
    $attrSelectLabel,
    $attrSelectBox,
    $attrCurrentValueLabel,
    $attrCurrentValueBox,
    $attrWriteValueLabel,
    $attrWriteValueBox,
    $attrCandidateCountLabel,
    $attrStatusLabel
))

$attrButtonPanel.Controls.AddRange(@(
    $attrDetectButton,
    $attrRefreshButton,
    $attrWriteSelectedButton,
    $attrPinButton,
    $attrClearButton
))

$itemTopPanel = New-Object System.Windows.Forms.Panel
$itemTopPanel.Dock = "Top"
$itemTopPanel.Height = 96
$itemTopPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 8)

$itemSearchLabel = New-Object System.Windows.Forms.Label
$itemSearchLabel.Text = "搜索"
$itemSearchLabel.AutoSize = $true
$itemSearchLabel.Location = New-Object System.Drawing.Point(12, 16)

$itemSearchBox = New-Object System.Windows.Forms.TextBox
$itemSearchBox.Location = New-Object System.Drawing.Point(60, 12)
$itemSearchBox.Width = 260

$itemCategoryLabel = New-Object System.Windows.Forms.Label
$itemCategoryLabel.Text = "分类"
$itemCategoryLabel.AutoSize = $true
$itemCategoryLabel.Location = New-Object System.Drawing.Point(340, 16)

$itemCategoryBox = New-Object System.Windows.Forms.ComboBox
$itemCategoryBox.Location = New-Object System.Drawing.Point(388, 12)
$itemCategoryBox.Width = 160
$itemCategoryBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

$itemQtyLabel = New-Object System.Windows.Forms.Label
$itemQtyLabel.Text = "数量"
$itemQtyLabel.AutoSize = $true
$itemQtyLabel.Location = New-Object System.Drawing.Point(568, 16)

$itemQtyBox = New-Object System.Windows.Forms.TextBox
$itemQtyBox.Location = New-Object System.Drawing.Point(616, 12)
$itemQtyBox.Width = 56
$itemQtyBox.Text = "1"

$itemSpawnButton = New-UiButton "生成到脚边" 120
$itemSpawnButton.Location = New-Object System.Drawing.Point(692, 10)

$itemCountLabel = New-Object System.Windows.Forms.Label
$itemCountLabel.Text = "物品 0 / 0"
$itemCountLabel.AutoSize = $true
$itemCountLabel.Location = New-Object System.Drawing.Point(12, 54)

$itemStatusLabel = New-Object System.Windows.Forms.Label
$itemStatusLabel.Text = "状态: 等待操作"
$itemStatusLabel.AutoSize = $false
$itemStatusLabel.Width = 900
$itemStatusLabel.Height = 22
$itemStatusLabel.Location = New-Object System.Drawing.Point(120, 52)

$itemTopPanel.Controls.AddRange(@(
    $itemSearchLabel,
    $itemSearchBox,
    $itemCategoryLabel,
    $itemCategoryBox,
    $itemQtyLabel,
    $itemQtyBox,
    $itemSpawnButton,
    $itemCountLabel,
    $itemStatusLabel
))

$itemListView = New-Object System.Windows.Forms.ListView
$itemListView.Dock = "Fill"
$itemListView.View = "Details"
$itemListView.FullRowSelect = $true
$itemListView.GridLines = $true
$itemListView.HideSelection = $false
$itemListView.MultiSelect = $false
$itemListView.Columns.Add("代码", 230) | Out-Null
$itemListView.Columns.Add("名称", 180) | Out-Null
$itemListView.Columns.Add("分类", 120) | Out-Null
$itemListView.Columns.Add("资源路径", 610) | Out-Null

$itemContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$itemContextMenu.ShowImageMargin = $false
$itemContextMenu.BackColor = $script:uiWindowColor
$itemContextMenu.ForeColor = $script:uiTextColor
$itemRenameMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("命名中文名")
$itemClearNameMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("清空中文名")
$itemAddInventoryMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("添加进背包")
$itemRemoveInventoryMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("从背包删除")
$itemContextMenu.Items.AddRange(@(
    $itemRenameMenuItem,
    $itemClearNameMenuItem,
    (New-Object System.Windows.Forms.ToolStripSeparator),
    $itemAddInventoryMenuItem,
    $itemRemoveInventoryMenuItem
))
$itemListView.ContextMenuStrip = $itemContextMenu

$itemDetailBox = New-Object System.Windows.Forms.TextBox
$itemDetailBox.Dock = "Fill"
$itemDetailBox.Multiline = $true
$itemDetailBox.ReadOnly = $true
$itemDetailBox.ScrollBars = "Horizontal"
$itemDetailBox.WordWrap = $false
$itemDetailBox.BackColor = [System.Drawing.Color]::White
$itemDetailBox.Text = "选中物品后，这里显示 Summon 命令。生成后请回游戏确认脚边是否出现物品。"

$inventoryTopPanel = New-Object System.Windows.Forms.Panel
$inventoryTopPanel.Dock = "Top"
$inventoryTopPanel.Height = 128
$inventoryTopPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 8)

$inventorySearchLabel = New-Object System.Windows.Forms.Label
$inventorySearchLabel.Text = "搜索"
$inventorySearchLabel.AutoSize = $true
$inventorySearchLabel.Location = New-Object System.Drawing.Point(12, 16)

$inventorySearchBox = New-Object System.Windows.Forms.TextBox
$inventorySearchBox.Location = New-Object System.Drawing.Point(60, 12)
$inventorySearchBox.Width = 220

$inventoryCodeLabel = New-Object System.Windows.Forms.Label
$inventoryCodeLabel.Text = "代码"
$inventoryCodeLabel.AutoSize = $true
$inventoryCodeLabel.Location = New-Object System.Drawing.Point(300, 16)

$inventoryCodeBox = New-Object System.Windows.Forms.TextBox
$inventoryCodeBox.Location = New-Object System.Drawing.Point(348, 12)
$inventoryCodeBox.Width = 220

$inventoryQtyLabel = New-Object System.Windows.Forms.Label
$inventoryQtyLabel.Text = "数量"
$inventoryQtyLabel.AutoSize = $true
$inventoryQtyLabel.Location = New-Object System.Drawing.Point(588, 16)

$inventoryQtyBox = New-Object System.Windows.Forms.TextBox
$inventoryQtyBox.Location = New-Object System.Drawing.Point(636, 12)
$inventoryQtyBox.Width = 56
$inventoryQtyBox.Text = "1"

$inventoryRefreshButton = New-UiButton "尝试读取" 120
$inventoryRefreshButton.Location = New-Object System.Drawing.Point(12, 50)

$inventoryProbeButton = New-UiButton "只读探针" 120
$inventoryProbeButton.Location = New-Object System.Drawing.Point(142, 50)

$inventoryAddButton = New-UiButton "增加到背包" 120
$inventoryAddButton.Location = New-Object System.Drawing.Point(272, 50)

$inventoryRemoveButton = New-UiButton "从背包删除" 120
$inventoryRemoveButton.Location = New-Object System.Drawing.Point(402, 50)

$inventorySnapshotButton = New-UiButton "保存快照(实验)" 120
$inventorySnapshotButton.Location = New-Object System.Drawing.Point(532, 50)

$inventoryRestoreButton = New-UiButton "差量还原(实验)" 120
$inventoryRestoreButton.Location = New-Object System.Drawing.Point(662, 50)

$inventoryCountLabel = New-Object System.Windows.Forms.Label
$inventoryCountLabel.Text = "背包物品 0 / 0"
$inventoryCountLabel.AutoSize = $true
$inventoryCountLabel.Location = New-Object System.Drawing.Point(12, 94)

$inventoryStatusLabel = New-Object System.Windows.Forms.Label
$inventoryStatusLabel.Text = "背包: 已知英文代码可直接增删；读取列表是实验功能。"
$inventoryStatusLabel.AutoSize = $false
$inventoryStatusLabel.Width = 760
$inventoryStatusLabel.Height = 22
$inventoryStatusLabel.Location = New-Object System.Drawing.Point(140, 92)

$inventoryTopPanel.Controls.AddRange(@(
    $inventorySearchLabel,
    $inventorySearchBox,
    $inventoryCodeLabel,
    $inventoryCodeBox,
    $inventoryQtyLabel,
    $inventoryQtyBox,
    $inventoryRefreshButton,
    $inventoryProbeButton,
    $inventoryAddButton,
    $inventoryRemoveButton,
    $inventorySnapshotButton,
    $inventoryRestoreButton,
    $inventoryCountLabel,
    $inventoryStatusLabel
))

$inventoryListView = New-Object System.Windows.Forms.ListView
$inventoryListView.Dock = "Fill"
$inventoryListView.View = "Details"
$inventoryListView.FullRowSelect = $true
$inventoryListView.GridLines = $true
$inventoryListView.HideSelection = $false
$inventoryListView.MultiSelect = $false
$inventoryListView.Columns.Add("中文名", 220) | Out-Null
$inventoryListView.Columns.Add("英文代码", 230) | Out-Null
$inventoryListView.Columns.Add("数量", 70) | Out-Null
$inventoryListView.Columns.Add("分类", 140) | Out-Null
$inventoryListView.Columns.Add("来源", 360) | Out-Null

$inventoryContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$inventoryContextMenu.ShowImageMargin = $false
$inventoryContextMenu.BackColor = $script:uiWindowColor
$inventoryContextMenu.ForeColor = $script:uiTextColor
$inventoryRenameMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("命名中文名")
$inventoryClearNameMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("清空中文名")
$inventoryCopyCodeMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("复制代码")
$inventoryContextMenu.Items.AddRange(@(
    $inventoryRenameMenuItem,
    $inventoryClearNameMenuItem,
    $inventoryCopyCodeMenuItem
))
$inventoryListView.ContextMenuStrip = $inventoryContextMenu

$inventoryDetailBox = New-Object System.Windows.Forms.TextBox
$inventoryDetailBox.Dock = "Fill"
$inventoryDetailBox.Multiline = $true
$inventoryDetailBox.ReadOnly = $true
$inventoryDetailBox.ScrollBars = "Horizontal"
$inventoryDetailBox.WordWrap = $false
$inventoryDetailBox.BackColor = [System.Drawing.Color]::White
$inventoryDetailBox.Text = "稳定用法：输入英文代码和数量，然后点击增加或删除。列表读取/快照还原目前是实验功能，读不到时不要继续深扫。"

$unlockPanel = New-Object System.Windows.Forms.Panel
$unlockPanel.Dock = "Fill"
$unlockPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)

$unlockEnabledCheckBox = New-Object System.Windows.Forms.CheckBox
$unlockEnabledCheckBox.Text = "启用一键开锁"
$unlockEnabledCheckBox.AutoSize = $true
$unlockEnabledCheckBox.Location = New-Object System.Drawing.Point(12, 18)

$unlockStatusLabel = New-Object System.Windows.Forms.Label
$unlockStatusLabel.Text = "开锁: 等待游戏加载 Mod"
$unlockStatusLabel.AutoSize = $false
$unlockStatusLabel.Width = 700
$unlockStatusLabel.Height = 22
$unlockStatusLabel.Location = New-Object System.Drawing.Point(150, 18)

$unlockPanel.Controls.AddRange(@($unlockEnabledCheckBox, $unlockStatusLabel))

$itemLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$itemLayoutPanel.Dock = "Fill"
$itemLayoutPanel.ColumnCount = 1
$itemLayoutPanel.RowCount = 3
$itemLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$itemLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$itemLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 96))) | Out-Null
$itemLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$itemLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 86))) | Out-Null
$itemLayoutPanel.Controls.Add($itemTopPanel, 0, 0)
$itemLayoutPanel.Controls.Add($itemListView, 0, 1)
$itemLayoutPanel.Controls.Add($itemDetailBox, 0, 2)

$inventoryLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$inventoryLayoutPanel.Dock = "Fill"
$inventoryLayoutPanel.ColumnCount = 1
$inventoryLayoutPanel.RowCount = 3
$inventoryLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$inventoryLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$inventoryLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 128))) | Out-Null
$inventoryLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$inventoryLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 86))) | Out-Null
$inventoryLayoutPanel.Controls.Add($inventoryTopPanel, 0, 0)
$inventoryLayoutPanel.Controls.Add($inventoryListView, 0, 1)
$inventoryLayoutPanel.Controls.Add($inventoryDetailBox, 0, 2)

$itemInnerTabs = New-Object System.Windows.Forms.TabControl
$itemInnerTabs.Dock = "Fill"
$itemSpawnPage = New-Object System.Windows.Forms.TabPage
$itemSpawnPage.Text = "物品生成"
$unlockPage = New-Object System.Windows.Forms.TabPage
$unlockPage.Text = "开锁"
$highlightPage = New-Object System.Windows.Forms.TabPage
$highlightPage.Text = "物品高亮"

# Highlight page content
$highlightPanel = New-Object System.Windows.Forms.Panel
$highlightPanel.Dock = "Fill"
$highlightPanel.Padding = New-Object System.Windows.Forms.Padding(16, 16, 16, 16)

$highlightPingButton = New-UiButton "立即高亮（同 V 键）" 180
$highlightPingButton.Location = New-Object System.Drawing.Point(16, 16)

$highlightRadiusLabel = New-Object System.Windows.Forms.Label
$highlightRadiusLabel.Text = "高亮距离（米）"
$highlightRadiusLabel.AutoSize = $true
$highlightRadiusLabel.Location = New-Object System.Drawing.Point(16, 66)

$highlightRadiusValue = New-Object System.Windows.Forms.Label
$highlightRadiusValue.Text = "35"
$highlightRadiusValue.AutoSize = $true
$highlightRadiusValue.Font = New-Object System.Drawing.Font("微软雅黑", 10, [System.Drawing.FontStyle]::Bold)
$highlightRadiusValue.Location = New-Object System.Drawing.Point(132, 64)

$highlightRadiusBar = New-Object System.Windows.Forms.TrackBar
$highlightRadiusBar.Minimum = 5
$highlightRadiusBar.Maximum = 100
$highlightRadiusBar.Value = 35
$highlightRadiusBar.TickFrequency = 5
$highlightRadiusBar.LargeChange = 10
$highlightRadiusBar.SmallChange = 1
$highlightRadiusBar.Location = New-Object System.Drawing.Point(180, 56)
$highlightRadiusBar.Width = 360

$highlightDurationLabel = New-Object System.Windows.Forms.Label
$highlightDurationLabel.Text = "高亮时间（秒）"
$highlightDurationLabel.AutoSize = $true
$highlightDurationLabel.Location = New-Object System.Drawing.Point(16, 116)

$highlightDurationValue = New-Object System.Windows.Forms.Label
$highlightDurationValue.Text = "10"
$highlightDurationValue.AutoSize = $true
$highlightDurationValue.Font = New-Object System.Drawing.Font("微软雅黑", 10, [System.Drawing.FontStyle]::Bold)
$highlightDurationValue.Location = New-Object System.Drawing.Point(132, 114)

$highlightDurationBar = New-Object System.Windows.Forms.TrackBar
$highlightDurationBar.Minimum = 1
$highlightDurationBar.Maximum = 30
$highlightDurationBar.Value = 10
$highlightDurationBar.TickFrequency = 2
$highlightDurationBar.LargeChange = 5
$highlightDurationBar.SmallChange = 1
$highlightDurationBar.Location = New-Object System.Drawing.Point(180, 106)
$highlightDurationBar.Width = 360

$highlightColorLabel = New-Object System.Windows.Forms.Label
$highlightColorLabel.Text = "高亮颜色"
$highlightColorLabel.AutoSize = $true
$highlightColorLabel.Location = New-Object System.Drawing.Point(16, 166)

$highlightColorBox = New-Object System.Windows.Forms.ComboBox
$highlightColorBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$highlightColorBox.Location = New-Object System.Drawing.Point(112, 162)
$highlightColorBox.Width = 180
$script:fnpStencilValues = [int[]]@(4)
foreach ($colorName in @(
    "蓝色（已验证）"
)) {
    [void]$highlightColorBox.Items.Add($colorName)
}
$highlightColorBox.SelectedIndex = 0

$highlightAlphaLabel = New-Object System.Windows.Forms.Label
$highlightAlphaLabel.Text = "亮度"
$highlightAlphaLabel.AutoSize = $true
$highlightAlphaLabel.Location = New-Object System.Drawing.Point(320, 166)

$highlightAlphaValue = New-Object System.Windows.Forms.Label
$highlightAlphaValue.Text = "100%"
$highlightAlphaValue.AutoSize = $true
$highlightAlphaValue.Location = New-Object System.Drawing.Point(370, 166)

$highlightAlphaBar = New-Object System.Windows.Forms.TrackBar
$highlightAlphaBar.Minimum = 10
$highlightAlphaBar.Maximum = 100
$highlightAlphaBar.Value = 100
$highlightAlphaBar.TickFrequency = 10
$highlightAlphaBar.LargeChange = 10
$highlightAlphaBar.SmallChange = 5
$highlightAlphaBar.Location = New-Object System.Drawing.Point(430, 156)
$highlightAlphaBar.Width = 220

$highlightThickCheck = New-Object System.Windows.Forms.CheckBox
$highlightThickCheck.Text = "粗轮廓"
$highlightThickCheck.AutoSize = $true
$highlightThickCheck.Checked = $true
$highlightThickCheck.Location = New-Object System.Drawing.Point(16, 214)

$highlightCorpsesCheck = New-Object System.Windows.Forms.CheckBox
$highlightCorpsesCheck.Text = "包含尸体"
$highlightCorpsesCheck.AutoSize = $true
$highlightCorpsesCheck.Checked = $true
$highlightCorpsesCheck.Location = New-Object System.Drawing.Point(112, 214)

$highlightChestsCheck = New-Object System.Windows.Forms.CheckBox
$highlightChestsCheck.Text = "包含宝箱"
$highlightChestsCheck.AutoSize = $true
$highlightChestsCheck.Checked = $true
$highlightChestsCheck.Location = New-Object System.Drawing.Point(220, 214)

$highlightStatusLabel = New-Object System.Windows.Forms.Label
$highlightStatusLabel.Text = "状态：等待游戏中的 Ping Mode v3…"
$highlightStatusLabel.AutoSize = $false
$highlightStatusLabel.Location = New-Object System.Drawing.Point(16, 252)
$highlightStatusLabel.Width = 820
$highlightStatusLabel.Height = 24

$highlightInfoLabel = New-Object System.Windows.Forms.Label
$highlightInfoLabel.Text = @"
功能说明：
• 回到游戏按 V，或点击上方按钮，高亮当前已经加载的物品
• 高亮结束后会自动清理；设置修改后自动写入，无需确认按钮
• 尸体与宝箱扫描会增加单次工作量，只在需要时开启
"@
$highlightInfoLabel.AutoSize = $false
$highlightInfoLabel.Location = New-Object System.Drawing.Point(16, 286)
$highlightInfoLabel.Width = 820
$highlightInfoLabel.Height = 100

$highlightPanel.Controls.AddRange(@(
    $highlightPingButton,
    $highlightRadiusLabel,
    $highlightRadiusValue,
    $highlightRadiusBar,
    $highlightDurationLabel,
    $highlightDurationValue,
    $highlightDurationBar,
    $highlightColorLabel,
    $highlightColorBox,
    $highlightAlphaLabel,
    $highlightAlphaValue,
    $highlightAlphaBar,
    $highlightThickCheck,
    $highlightCorpsesCheck,
    $highlightChestsCheck,
    $highlightStatusLabel,
    $highlightInfoLabel
))
$highlightPage.Controls.Add($highlightPanel)

$itemSpawnPage.Controls.Add($itemLayoutPanel)
$unlockPage.Controls.Add($unlockPanel)
$itemInnerTabs.TabPages.Add($itemSpawnPage) | Out-Null
$itemInnerTabs.TabPages.Add($unlockPage) | Out-Null
$itemInnerTabs.TabPages.Add($highlightPage) | Out-Null
$itemUnlockTab.Controls.Add($itemInnerTabs)

$diagTopPanel = New-Object System.Windows.Forms.Panel
$diagTopPanel.Dock = "Top"
$diagTopPanel.Height = 72
$diagTopPanel.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 8)

$diagSourceLabel = New-Object System.Windows.Forms.Label
$diagSourceLabel.Text = "来源"
$diagSourceLabel.AutoSize = $true
$diagSourceLabel.Location = New-Object System.Drawing.Point(12, 17)

$diagSourceBox = New-Object System.Windows.Forms.ComboBox
$diagSourceBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$diagSourceBox.Location = New-Object System.Drawing.Point(54, 13)
$diagSourceBox.Width = 150
foreach ($sourceName in @("瞬移诊断", "瞬移状态", "C++桥诊断", "C++桥状态", "内存桥诊断", "内存桥状态", "UE4SS日志", "物品状态", "背包动作状态", "背包列表", "人物属性状态", "人物属性诊断", "开锁状态", "物品高亮状态", "UI错误")) {
    [void]$diagSourceBox.Items.Add($sourceName)
}
$diagSourceBox.SelectedItem = "瞬移诊断"

$diagRefreshButton = New-UiButton "刷新日志" 100
$diagRefreshButton.Location = New-Object System.Drawing.Point(218, 10)

$diagReloadCoreButton = New-UiButton "重载核心" 100
$diagReloadCoreButton.Location = New-Object System.Drawing.Point(328, 10)

$diagFullReloadButton = New-UiButton "全量热重载(Ctrl+R)" 160
$diagFullReloadButton.Location = New-Object System.Drawing.Point(438, 10)

$diagClearButton = New-UiButton "清空显示" 100
$diagClearButton.Location = New-Object System.Drawing.Point(608, 10)

$diagPathLabel = New-Object System.Windows.Forms.Label
$diagPathLabel.AutoSize = $false
$diagPathLabel.Location = New-Object System.Drawing.Point(12, 44)
$diagPathLabel.Width = 900
$diagPathLabel.Height = 20
$diagPathLabel.Text = $script:teleportDiagPath

[void]$diagTopPanel.Controls.Add($diagSourceLabel)
[void]$diagTopPanel.Controls.Add($diagSourceBox)
[void]$diagTopPanel.Controls.Add($diagRefreshButton)
[void]$diagTopPanel.Controls.Add($diagReloadCoreButton)
[void]$diagTopPanel.Controls.Add($diagFullReloadButton)
[void]$diagTopPanel.Controls.Add($diagClearButton)
[void]$diagTopPanel.Controls.Add($diagPathLabel)

$diagLogBox = New-Object System.Windows.Forms.TextBox
$diagLogBox.Dock = "Fill"
$diagLogBox.Multiline = $true
$diagLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$diagLogBox.WordWrap = $false
$diagLogBox.ReadOnly = $true
$diagLogBox.Font = New-Object System.Drawing.Font("Consolas", 9)

$diagLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$diagLayoutPanel.Dock = "Fill"
$diagLayoutPanel.ColumnCount = 1
$diagLayoutPanel.RowCount = 2
$diagLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$diagLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$diagLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 84))) | Out-Null
$diagLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$diagLayoutPanel.Controls.Add($diagTopPanel, 0, 0)
$diagLayoutPanel.Controls.Add($diagLogBox, 0, 1)
$diagTab.Controls.Add($diagLayoutPanel)
# ==========================================
# [TAB: 自由飞翔/时间] 世界与时空控制
# ==========================================
$worldLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$worldLayoutPanel.Dock = "Fill"
$worldLayoutPanel.ColumnCount = 1
$worldLayoutPanel.RowCount = 2
$worldLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(16, 16, 16, 16)
$worldLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$worldLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$worldLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null

$noClipGroup = New-Object System.Windows.Forms.GroupBox
$noClipGroup.Text = " 自由飞翔 "
$noClipGroup.Dock = "Fill"
$noClipGroup.Padding = New-Object System.Windows.Forms.Padding(16, 24, 16, 16)

$noClipEnableCheckBox = New-Object System.Windows.Forms.CheckBox
$noClipEnableCheckBox.Text = "开启自由飞翔"
$noClipEnableCheckBox.Location = New-Object System.Drawing.Point(24, 36)
$noClipEnableCheckBox.AutoSize = $true

$noClipSpeedLabel = New-Object System.Windows.Forms.Label
$noClipSpeedLabel.Text = "飞行速度倍率:"
$noClipSpeedLabel.Location = New-Object System.Drawing.Point(24, 80)
$noClipSpeedLabel.AutoSize = $true

$noClipSpeedValue = New-Object System.Windows.Forms.Label
$noClipSpeedValue.Text = "3.00x"
$noClipSpeedValue.AutoSize = $true
$noClipSpeedValue.Font = New-Object System.Drawing.Font("微软雅黑", 10, [System.Drawing.FontStyle]::Bold)
$noClipSpeedValue.Location = New-Object System.Drawing.Point(138, 78)

$noClipSpeedBar = New-Object System.Windows.Forms.TrackBar
$noClipSpeedBar.Minimum = 25
$noClipSpeedBar.Maximum = 1000
$noClipSpeedBar.Value = 300
$noClipSpeedBar.TickFrequency = 100
$noClipSpeedBar.LargeChange = 100
$noClipSpeedBar.SmallChange = 25
$noClipSpeedBar.Location = New-Object System.Drawing.Point(200, 68)
$noClipSpeedBar.Width = 420

$getNoClipSelectedSpeed = {
    return [string]::Format(
        [System.Globalization.CultureInfo]::InvariantCulture,
        "{0:0.00}",
        ([double]$noClipSpeedBar.Value / 100.0)
    )
}

$noClipToggleAction = {
    if ($script:noClipUiSyncing) { return }
    $val = "0"
    $stateStr = "关闭"
    if ($noClipEnableCheckBox.Checked) {
        $val = "1"
        $stateStr = "开启"
        Ensure-TeleportMemoryBridge
    }
    $speed = & $getNoClipSelectedSpeed
    Append-Action ("NOCLIP|{0}|{1}" -f $val, $speed)
    Set-Status ("自由飞翔已{0}（速度 {1}x）" -f $stateStr, $speed)
}
$noClipEnableCheckBox.Add_CheckedChanged($noClipToggleAction)
$noClipSpeedBar.Add_ValueChanged({
    $speed = & $getNoClipSelectedSpeed
    $noClipSpeedValue.Text = ("{0}x" -f $speed)
    if ($script:noClipUiSyncing) { return }
    if ($noClipEnableCheckBox.Checked) { Ensure-TeleportMemoryBridge }
    Append-Action ("NOCLIP_SPEED|{0}" -f $speed)
    $verb = if ($noClipEnableCheckBox.Checked) { "已调整" } else { "已预设" }
    Set-Status ("自由飞翔速度{0}为 {1}x" -f $verb, $speed)
})

$noClipProbeButton = New-Object System.Windows.Forms.Button
$noClipProbeButton.Text = "检查实际状态"
$noClipProbeButton.Location = New-Object System.Drawing.Point(24, 114)
$noClipProbeButton.Size = New-Object System.Drawing.Size(120, 28)
$noClipProbeButton.Add_Click({
    Append-Action "NOCLIP_PROBE"
    Set-Status "已请求检查自由飞翔状态，请在日志/诊断页刷新瞬移诊断。"
})

$noClipTipLabel = New-Object System.Windows.Forms.Label
$noClipTipLabel.Text = "F7 可直接开关。W/S 沿镜头方向前进/后退，A/D 左右平移。普通互动会自动关闭飞行；互动或对话结束后请手动重新开启。"
$noClipTipLabel.Location = New-Object System.Drawing.Point(160, 120)
$noClipTipLabel.Size = New-Object System.Drawing.Size(700, 42)

$noClipGroup.Controls.Add($noClipEnableCheckBox)
$noClipGroup.Controls.Add($noClipSpeedLabel)
$noClipGroup.Controls.Add($noClipSpeedValue)
$noClipGroup.Controls.Add($noClipSpeedBar)
$noClipGroup.Controls.Add($noClipProbeButton)
$noClipGroup.Controls.Add($noClipTipLabel)

$timeControlGroup = New-Object System.Windows.Forms.GroupBox
$timeControlGroup.Text = " 游戏世界与时空控制 (World & Time Control) "
$timeControlGroup.Dock = "Fill"
$timeControlGroup.Padding = New-Object System.Windows.Forms.Padding(16, 24, 16, 16)

$worldFreezeCheckBox = New-Object System.Windows.Forms.CheckBox
$worldFreezeCheckBox.Text = "冻结世界与敌人 (仅自己可动 / 时空静止)"
$worldFreezeCheckBox.Location = New-Object System.Drawing.Point(24, 30)
$worldFreezeCheckBox.AutoSize = $true
$worldFreezeCheckBox.Add_CheckedChanged({
    $val = "0"
    $stateStr = "关闭"
    if ($worldFreezeCheckBox.Checked) {
        $val = "1"
        $stateStr = "开启"
    }
    Append-Action ("WORLD_FREEZE|{0}" -f $val)
    Set-Status ("已发送冻结世界与敌人命令: {0}" -f $stateStr)
})

$clockFreezeCheckBox = New-Object System.Windows.Forms.CheckBox
$clockFreezeCheckBox.Text = "暂停昼夜时钟流逝 (锁死白天/黑夜)"
$clockFreezeCheckBox.Location = New-Object System.Drawing.Point(320, 30)
$clockFreezeCheckBox.AutoSize = $true
$clockFreezeCheckBox.Add_CheckedChanged({
    $val = "0"
    $stateStr = "关闭"
    if ($clockFreezeCheckBox.Checked) {
        $val = "1"
        $stateStr = "开启"
    }
    Append-Action ("CLOCK_FREEZE|{0}" -f $val)
    Set-Status ("已发送暂停昼夜时钟流逝命令: {0}" -f $stateStr)
})

$timeAdvanceLabel = New-Object System.Windows.Forms.Label
$timeAdvanceLabel.Text = "快进世界时间 (Advance Time):"
$timeAdvanceLabel.Location = New-Object System.Drawing.Point(24, 75)
$timeAdvanceLabel.AutoSize = $true

$btnPlus1 = New-Object System.Windows.Forms.Button
$btnPlus1.Text = "+1 小时"
$btnPlus1.Location = New-Object System.Drawing.Point(220, 80)
$btnPlus1.Size = New-Object System.Drawing.Size(85, 28)
$btnPlus1.Add_Click({ Append-Action "TIME_ADVANCE|1"; Set-Status "已发送快进时间: +1 小时" })

$btnPlus3 = New-Object System.Windows.Forms.Button
$btnPlus3.Text = "+3 小时"
$btnPlus3.Location = New-Object System.Drawing.Point(315, 80)
$btnPlus3.Size = New-Object System.Drawing.Size(85, 28)
$btnPlus3.Add_Click({ Append-Action "TIME_ADVANCE|3"; Set-Status "已发送快进时间: +3 小时" })

$btnPlus6 = New-Object System.Windows.Forms.Button
$btnPlus6.Text = "+6 小时"
$btnPlus6.Location = New-Object System.Drawing.Point(410, 80)
$btnPlus6.Size = New-Object System.Drawing.Size(85, 28)
$btnPlus6.Add_Click({ Append-Action "TIME_ADVANCE|6"; Set-Status "已发送快进时间: +6 小时" })

$btnPlus12 = New-Object System.Windows.Forms.Button
$btnPlus12.Text = "+12 小时"
$btnPlus12.Location = New-Object System.Drawing.Point(505, 80)
$btnPlus12.Size = New-Object System.Drawing.Size(85, 28)
$btnPlus12.Add_Click({ Append-Action "TIME_ADVANCE|12"; Set-Status "已发送快进时间: +12 小时" })

$btnPlus24 = New-Object System.Windows.Forms.Button
$btnPlus24.Text = "+24 小时"
$btnPlus24.Location = New-Object System.Drawing.Point(600, 80)
$btnPlus24.Size = New-Object System.Drawing.Size(85, 28)
$btnPlus24.Add_Click({ Append-Action "TIME_ADVANCE|24"; Set-Status "已发送快进时间: +24 小时" })

$timeTipLabel = New-Object System.Windows.Forms.Label
$timeTipLabel.Text = "说明: [冻结世界与敌人]将非玩家对象静止(主角可动); [暂停昼夜时钟]锁定天色变化。两者互不冲突。"
$timeTipLabel.Location = New-Object System.Drawing.Point(24, 130)
$timeTipLabel.Size = New-Object System.Drawing.Size(650, 45)

$timeControlGroup.Controls.Add($worldFreezeCheckBox)
$timeControlGroup.Controls.Add($clockFreezeCheckBox)
$timeControlGroup.Controls.Add($timeAdvanceLabel)
$timeControlGroup.Controls.Add($btnPlus1)
$timeControlGroup.Controls.Add($btnPlus3)
$timeControlGroup.Controls.Add($btnPlus6)
$timeControlGroup.Controls.Add($btnPlus12)
$timeControlGroup.Controls.Add($btnPlus24)
$timeControlGroup.Controls.Add($timeTipLabel)

$worldLayoutPanel.Controls.Add($noClipGroup, 0, 0)
$worldLayoutPanel.Controls.Add($timeControlGroup, 0, 1)
$worldTimeTab.Controls.Add($worldLayoutPanel)







$walkthroughTopPanel = New-Object System.Windows.Forms.Panel
$walkthroughTopPanel.Dock = "Top"
$walkthroughTopPanel.Height = 54
$walkthroughTopPanel.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 8)

$walkthroughSearchLabel = New-Object System.Windows.Forms.Label
$walkthroughSearchLabel.Text = "检索"
$walkthroughSearchLabel.AutoSize = $true
$walkthroughSearchLabel.Location = New-Object System.Drawing.Point(12, 18)

$walkthroughSearchBox = New-Object System.Windows.Forms.TextBox
$walkthroughSearchBox.Location = New-Object System.Drawing.Point(60, 14)
$walkthroughSearchBox.Width = 300

$walkthroughClearButton = New-UiButton "清空检索" 100
$walkthroughClearButton.Location = New-Object System.Drawing.Point(374, 12)

$walkthroughExpandButton = New-UiButton "全部展开" 100
$walkthroughExpandButton.Location = New-Object System.Drawing.Point(486, 12)

$walkthroughCollapseButton = New-UiButton "全部折叠" 100
$walkthroughCollapseButton.Location = New-Object System.Drawing.Point(598, 12)

$walkthroughCountLabel = New-Object System.Windows.Forms.Label
$walkthroughCountLabel.Text = "任务 0 / 0"
$walkthroughCountLabel.AutoSize = $true
$walkthroughCountLabel.Location = New-Object System.Drawing.Point(724, 18)

$walkthroughTopPanel.Controls.AddRange(@(
    $walkthroughSearchLabel,
    $walkthroughSearchBox,
    $walkthroughClearButton,
    $walkthroughExpandButton,
    $walkthroughCollapseButton,
    $walkthroughCountLabel
))

$walkthroughSplit = New-Object System.Windows.Forms.SplitContainer
$walkthroughSplit.Dock = "Fill"
$walkthroughSplit.Orientation = [System.Windows.Forms.Orientation]::Vertical
$walkthroughSplit.SplitterDistance = 330

$walkthroughTreeView = New-Object System.Windows.Forms.TreeView
$walkthroughTreeView.Dock = "Fill"
$walkthroughTreeView.HideSelection = $false

$walkthroughDetailBox = New-Object System.Windows.Forms.TextBox
$walkthroughDetailBox.Dock = "Fill"
$walkthroughDetailBox.Multiline = $true
$walkthroughDetailBox.ReadOnly = $true
$walkthroughDetailBox.ScrollBars = "Vertical"
$walkthroughDetailBox.WordWrap = $true
$walkthroughDetailBox.BackColor = [System.Drawing.Color]::White
$walkthroughDetailBox.Text = "选择左侧任务查看攻略内容。"

$walkthroughSplit.Panel1.Controls.Add($walkthroughTreeView)
$walkthroughSplit.Panel2.Controls.Add($walkthroughDetailBox)

$walkthroughLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$walkthroughLayoutPanel.Dock = "Fill"
$walkthroughLayoutPanel.ColumnCount = 1
$walkthroughLayoutPanel.RowCount = 2
$walkthroughLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$walkthroughLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$walkthroughLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54))) | Out-Null
$walkthroughLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$walkthroughLayoutPanel.Controls.Add($walkthroughTopPanel, 0, 0)
$walkthroughLayoutPanel.Controls.Add($walkthroughSplit, 0, 1)
$walkthroughTab.Controls.Add($walkthroughLayoutPanel)

$guideScrollPanel = New-Object System.Windows.Forms.Panel
$guideScrollPanel.Dock = "Fill"
$guideScrollPanel.AutoScroll = $true
$guideScrollPanel.BackColor = [System.Drawing.Color]::White

$guideBox = New-Object System.Windows.Forms.RichTextBox
$guideBox.Location = New-Object System.Drawing.Point(10, 10)
$guideBox.Width = 680
$guideBox.Height = 1400
$guideBox.ReadOnly = $true
$guideBox.ScrollBars = "None"
$guideBox.BorderStyle = "None"
$guideBox.DetectUrls = $false
$guideBox.BackColor = [System.Drawing.Color]::White
$guideBox.Text = @"

═══════════════════════════════════════
            操  作  指  南
═══════════════════════════════════════

【窗口操作】
  F6        唤出或隐藏 UI 面板
            如果 UI 正在显示，按 F6 会最小化到任务栏；
            如果 UI 已最小化，按 F6 会恢复到前台。
  F1        快速保存当前位置为瞬移节点（游戏内按键）
  窗口置顶  右上角按钮，可让 UI 始终在游戏前面（独立控制）

【瞬移节点】
  ▸ 保存：站到目标位置 → 填写名称 → 点「保存当前位置」
  ▸ 瞬移：双击节点 = 立即瞬移
  ▸ 右键节点 = 瞬移 / 重命名 / 删除 / 复制坐标 / 绑定小键盘
  ▸ 快捷键：Del 删除、PgUp/PgDn 调序、Ctrl+点击多选
  ▸ 小键盘 1-9, 0 前往绑定的节点（UI 打开时暂停）
【扫描周围人物】
  ▸ Ctrl/Shift 可多选人物，右键「拉到身边」；一次最多 20 人。
  ▸ 存活、倒地和死亡人物均可拉取；自由飞行开启时会拒绝操作。
  ▸ 历史人物必须当前已加载；瞬移节点只会尝试匹配附近唯一人物。
【物品管理】
  ▸ 生成物品：
    1. 打开 UI → 切换到「修改」→「物品/开锁」→「物品生成」
    2. 在左侧物品列表中选择或搜索目标物品
    3. 顶部输入数量；点击「生成到脚边」会出现在角色脚下
    4. 右键物品可按同一数量「添加进背包」或「从背包删除」

【矿石（货币）修改】
  1. 打开 UI → 切换到「修改」→「矿石」
  2. 输入自定义数量，点「自定义增加」或「自定义减少」
  3. 每次操作会直接使用输入的完整数量

【人物属性修改】
  1. 打开 UI → 切换到「修改」→「人物属性」
  2. 选择要修改的属性（等级/经验/技能点/生命/法力/力量/敏捷）
  3. 点「读取属性」确认当前值
  4. 在输入框中填入目标值
  5. 选择写入方式（当前值/基础值/两者），点「写入」
  6. 回到游戏中确认效果，建议手动保存

  示例：将力量改为 100
    → 选择「力量」→ 读取 → 输入 100 → 写入「两者」→ 回游戏确认

  支持的属性：等级、经验值、技能点、生命值、最大生命、
             法力值、最大法力、力量、敏捷
  ⚠ 写入后数值没变？查看「日志/诊断 → 人物属性诊断」排查原因。

【开锁功能】
  打开 UI → 切换到「修改」→「物品/开锁」→「开锁」
  勾选启用后可一键开锁，关闭后恢复正常。

【自由飞翔】
  默认 3 倍速；可用横条在 0.25x～10.00x 之间连续调节。
  开启后使用 W/S 沿镜头方向移动，A/D 左右平移。
  与人物、书籍、昆虫等普通对象互动前会自动关闭；互动或对话结束后请手动重新开启。

【日志/诊断】
  遇到问题时切换到「日志/诊断」页面查看各类日志。
  「重载核心」= 重新加载 Lua 核心脚本。
  「全量热重载」= 发送 Ctrl+R 重装所有 Mod。

【导入导出坐标】
  在瞬移节点页面下方可导出/导入所有节点为 txt 文件。

【支持与打赏】
  向下滚动到本页最底部，可查看 USDT（TRON）二维码并复制钱包地址。
"@

$guideSupportTitle = New-Object System.Windows.Forms.Label
$guideSupportTitle.Text = "支持开发者（仅 USDT / TRON）"
$guideSupportTitle.AutoSize = $false
$guideSupportTitle.Height = 28
$guideSupportTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$guideSupportTitle.Font = New-Object System.Drawing.Font("微软雅黑", 11, [System.Drawing.FontStyle]::Bold)

$guideSupportImage = New-Object System.Windows.Forms.PictureBox
$guideSupportImage.Size = New-Object System.Drawing.Size(400, 711)
$guideSupportImage.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$supportImagePath = Join-Path $scriptDir "support_usdt_tron.png"
if (Test-Path -LiteralPath $supportImagePath) {
    try { $guideSupportImage.Image = [System.Drawing.Image]::FromFile($supportImagePath) } catch {}
}

$guideSupportAddressLabel = New-Object System.Windows.Forms.Label
$guideSupportAddressLabel.Text = "钱包地址"
$guideSupportAddressLabel.AutoSize = $true

$guideSupportAddressBox = New-Object System.Windows.Forms.TextBox
$guideSupportAddressBox.Text = "TWWGexPoyv46BUAxjuXkwAVx8JBPRgTtFJ"
$guideSupportAddressBox.ReadOnly = $true
$guideSupportAddressBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$guideSupportAddressBox.BackColor = [System.Drawing.Color]::White

$guideSupportCopyButton = New-UiButton "复制 USDT 地址" 150

function Layout-GuideSupport {
    $contentWidth = [Math]::Max(480, $guideScrollPanel.ClientSize.Width)
    $guideBox.Width = [Math]::Max(460, $contentWidth - 20)

    $cardWidth = [Math]::Min(560, [Math]::Max(390, $contentWidth - 20))
    $cardLeft = [Math]::Max(10, [int](($contentWidth - $cardWidth) / 2))
    $imageTop = $guideBox.Bottom + 24
    $guideSupportTitle.Location = [System.Drawing.Point]::new([int]$cardLeft, [int]$imageTop)
    $guideSupportTitle.Width = $cardWidth
    $guideSupportImage.Left = $cardLeft + [int](($cardWidth - $guideSupportImage.Width) / 2)
    $guideSupportImage.Top = $guideSupportTitle.Bottom + 8
    $guideSupportAddressLabel.Location = [System.Drawing.Point]::new([int]$cardLeft, [int]($guideSupportImage.Bottom + 18))
    $guideSupportAddressBox.Location = [System.Drawing.Point]::new([int]$cardLeft, [int]($guideSupportAddressLabel.Bottom + 5))
    $guideSupportAddressBox.Width = $cardWidth - $guideSupportCopyButton.Width - 10
    $guideSupportCopyButton.Location = [System.Drawing.Point]::new([int]($guideSupportAddressBox.Right + 10), [int]($guideSupportAddressBox.Top - 2))
    $guideScrollPanel.AutoScrollMinSize = [System.Drawing.Size]::new(0, [int]($guideSupportCopyButton.Bottom + 32))
}

$guideScrollPanel.Controls.AddRange(@(
    $guideBox,
    $guideSupportTitle,
    $guideSupportImage,
    $guideSupportAddressLabel,
    $guideSupportAddressBox,
    $guideSupportCopyButton
))

$guideScrollByWheel = {
    param($sender, $e)
    $currentY = -$guideScrollPanel.AutoScrollPosition.Y
    $step = if ($e.Delta -gt 0) { -80 } else { 80 }
    $targetY = [Math]::Max(0, $currentY + $step)
    $guideScrollPanel.AutoScrollPosition = New-Object System.Drawing.Point(0, $targetY)
}
$guideBox.Add_MouseWheel($guideScrollByWheel)
$guideSupportImage.Add_MouseWheel($guideScrollByWheel)
$guideSupportAddressBox.Add_MouseWheel($guideScrollByWheel)
$guideScrollPanel.Add_SizeChanged({
    Layout-GuideSupport
})
Layout-GuideSupport

$guideCoordPanel = New-Object System.Windows.Forms.Panel
$guideCoordPanel.Dock = "Fill"
$guideCoordPanel.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 6)

$guideCoordLabel = New-Object System.Windows.Forms.Label
$guideCoordLabel.Text = "瞬移坐标文件：可导出为 txt 审查，也可从 txt 导入替换当前节点。导入前会自动备份。"
$guideCoordLabel.AutoSize = $true
$guideCoordLabel.Location = New-Object System.Drawing.Point(8, 12)

$guideExportCoordsButton = New-UiButton "导出瞬移坐标.txt" 150
$guideExportCoordsButton.Location = New-Object System.Drawing.Point(640, 8)

$guideImportCoordsButton = New-UiButton "导入瞬移坐标.txt" 150
$guideImportCoordsButton.Location = New-Object System.Drawing.Point(800, 8)

$guideCoordPanel.Controls.AddRange(@(
    $guideCoordLabel,
    $guideExportCoordsButton,
    $guideImportCoordsButton
))
$guideCoordPanel.Add_SizeChanged({
    $right = $guideCoordPanel.ClientSize.Width - $guideCoordPanel.Padding.Right
    $guideImportCoordsButton.Left = $right - $guideImportCoordsButton.Width
    $guideExportCoordsButton.Left = $guideImportCoordsButton.Left - 10 - $guideExportCoordsButton.Width
    $guideCoordLabel.MaximumSize = New-Object System.Drawing.Size(([Math]::Max(260, $guideExportCoordsButton.Left - 20)), 0)
})

$guideSourcePanel = New-Object System.Windows.Forms.Panel
$guideSourcePanel.Dock = "Bottom"
$guideSourcePanel.Height = 34
$guideSourcePanel.Padding = New-Object System.Windows.Forms.Padding(8, 6, 12, 6)

$guideVideoLink = New-Object System.Windows.Forms.LinkLabel
$guideVideoLink.Text = "B站视频使用演示"
$guideVideoLink.AutoSize = $true
$guideVideoLink.Anchor = "Top,Right"
$guideVideoLink.Location = New-Object System.Drawing.Point(560, 8)

$guideSourceLabel = New-Object System.Windows.Forms.Label
$guideSourceLabel.Text = "作者：猴子香蕉你大爷"
$guideSourceLabel.AutoSize = $true
$guideSourceLabel.Anchor = "Top,Right"
$guideSourceLabel.Location = New-Object System.Drawing.Point(395, 9)

$guideAvatar = New-Object System.Windows.Forms.PictureBox
$guideAvatar.Size = New-Object System.Drawing.Size(24, 24)
$guideAvatar.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
$guideAvatar.Anchor = "Top,Right"
$guideAvatar.Location = New-Object System.Drawing.Point(365, 5)
$avatarPath = Join-Path $scriptDir "avatar_layered.gif"
if (Test-Path -LiteralPath $avatarPath) {
    try { $guideAvatar.Image = [System.Drawing.Image]::FromFile($avatarPath) } catch {}
}

$guideSourcePanel.Controls.AddRange(@($guideAvatar, $guideSourceLabel, $guideVideoLink))
$guideSourcePanel.Add_SizeChanged({
    $gap = 18
    $right = $guideSourcePanel.ClientSize.Width - $guideSourcePanel.Padding.Right
    $guideVideoLink.Left = $right - $guideVideoLink.Width
    $guideSourceLabel.Left = $guideVideoLink.Left - $gap - $guideSourceLabel.Width
    $guideAvatar.Left = $guideSourceLabel.Left - 8 - $guideAvatar.Width
})

$guideVideoLink.Add_LinkClicked({
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "https://space.bilibili.com/258597412"
    $psi.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null
})

$guideSupportCopyButton.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText($guideSupportAddressBox.Text)
        $guideSupportAddressBox.SelectAll()
        Set-Status "已复制 USDT (TRON) 地址。"
    } catch {
        Set-Status ("复制 USDT (TRON) 地址失败: {0}" -f $_.Exception.Message)
    }
})

$guideExportCoordsButton.Add_Click({
    try {
        Start-ExportSpotCoordinates
    } catch {
        Set-Status ("导出坐标失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "导出瞬移坐标")
    }
})

$guideImportCoordsButton.Add_Click({
    try {
        Start-ImportSpotCoordinates
    } catch {
        Set-Status ("导入坐标失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "导入瞬移坐标")
    }
})

$guideLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$guideLayoutPanel.Dock = "Fill"
$guideLayoutPanel.ColumnCount = 1
$guideLayoutPanel.RowCount = 3
$guideLayoutPanel.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
$guideLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$guideLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$guideLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50))) | Out-Null
$guideLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34))) | Out-Null
$guideLayoutPanel.Controls.Add($guideScrollPanel, 0, 0)
$guideLayoutPanel.Controls.Add($guideCoordPanel, 0, 1)
$guideLayoutPanel.Controls.Add($guideSourcePanel, 0, 2)
$guideTab.Controls.Add($guideLayoutPanel)

$script:uiLanguage = "zh"
$script:guideTextZh = $guideBox.Text
$script:guideTextEn = @"

=======================================
              USER GUIDE
=======================================

[WINDOW]
  F6        Open, minimize, or bring this panel to the front.
  F7        Toggle Free Flight without opening this panel.
  F1        Save the current game position as a teleport node.
  Always on top keeps this panel above the game window.

[TELEPORT NODES]
  - Enter a name and click Save Current Position.
  - Double-click a node to teleport.
  - Right-click for teleport, rename, delete, copy coordinates, or numpad binding.
  - Del deletes; PageUp/PageDown reorders; Ctrl+click selects multiple nodes.
  - Numpad 1-9 and 0 teleport to bound nodes while the UI is not focused.

[NEARBY NPCS]
  - Use Ctrl/Shift to select up to 20 NPCs, then right-click Pull to Me.
  - Active, downed, and dead characters are supported. Free Flight must be off.
  - History entries must be loaded; teleport nodes only try a unique nearby NPC match.

[ITEMS AND INVENTORY]
  - Item Spawn sends the selected item to the world near the player.
  - Enter a quantity at the top, then right-click an item to add it to or remove it from the inventory.

[ATTRIBUTES AND ORE]
  - Ore uses the verified ItMi_Orenugget inventory path.
  - Read an attribute before writing and test with a small value first.

[HIGHLIGHT]
  - Press V in game or use Highlight Now.
  - Distance, duration, brightness, corpses, and chests are configurable. Blue is the verified outline color.

[FREE FLIGHT]
  - Default speed is 3x; use the slider for continuous adjustment from 0.25x to 10.00x.
  - Enable Free Flight, then use W/S along the camera and A/D to strafe.
  - Speed changes apply immediately.
  - Normal interactions turn flight off automatically; enable it again after the interaction or dialogue.

[TROUBLESHOOTING]
  - Logs/Diagnostics shows the latest status files.
  - Core Reload reloads the teleport core only.
  - Full Reload sends Ctrl+R to UE4SS.

[SUPPORT]
  - Scroll to the bottom of this page for the USDT (TRON) QR code and a copyable wallet address.
"@
$script:highlightInfoTextZh = $highlightInfoLabel.Text
$script:highlightInfoTextEn = @"
How it works:
* Press V in game, or click the button above, to highlight loaded nearby objects.
* Highlights are cleaned automatically after the selected duration.
* Corpses and chests add work to each scan; enable them only when needed.
"@

$script:uiTextEn = @{
    "Gothic 1 Remake - Mod 管理" = "Gothic 1 Remake - Mod Manager"
    "瞬移节点" = "Teleport Nodes"
    "修改" = "Edit"
    "矿石" = "Ore"
    "人物属性" = "Attributes"
    "物品/开锁/高亮" = "Items / Unlock / Highlight"
    "扫描周围人物" = "Nearby NPCs"
    "自由飞翔/时间" = "Free Flight / Time"
    "日志/诊断" = "Logs / Diagnostics"
    "流程攻略" = "Walkthrough"
    "操作指南" = "User Guide"
    "搜索" = "Search"
    "检索" = "Filter"
    "保存名称" = "Node Name"
    "节点 0" = "Nodes 0"
    "手动坐标" = "Manual Coordinates"
    "状态: 等待操作" = "Status: waiting"
    "刷新列表" = "Refresh"
    "保存当前位置" = "Save Position"
    "手动坐标确认" = "Teleport"
    "名称" = "Name"
    "序号" = "Index"
    "坐标" = "Coordinates"
    "距离" = "Distance"
    "对象" = "Object"
    "瞬移到这里" = "Teleport Here"
    "拉到身边" = "Pull to Me"
    "尝试拉取人物到身边" = "Try Pulling NPCs to Me"
    "重命名" = "Rename"
    "删除选中" = "Delete Selected"
    "复制坐标" = "Copy Coordinates"
    "绑定到小键盘" = "Bind to Numpad"
    "清除小键盘绑定" = "Clear Numpad Binding"
    "添加到瞬移列表" = "Add to Teleport Nodes"
    "复制节点" = "Copy Node"
    "扫描" = "Scan"
    "清空" = "Clear"
    "本次扫描" = "Current Scan"
    "历史扫描" = "Scan History"
    "状态" = "Status"
    "最近状态" = "Latest Status"
    "按扫描后读取周围人物；Ctrl/Shift 可多选，右键可拉到身边。" = "Scan nearby NPCs; use Ctrl/Shift to multi-select and right-click to pull them to you."
    "自定义增加" = "Custom Add"
    "自定义减少" = "Custom Remove"
    "底层代码" = "Internal Code"
    "方式" = "Method"
    "说明" = "Description"
    "来源" = "Source"
    "属性" = "Attribute"
    "当前值" = "Current Value"
    "写入值" = "Write Value"
    "CT固定链" = "CT Chain"
    "货币" = "Currency"
    "自定义数量" = "Custom Quantity"
    "代码 ItMi_Orenugget" = "Code ItMi_Orenugget"
    "矿石是当前游戏货币。底层代码 ItMi_Orenugget，使用已验证的背包原生增删，不读取当前总数。" = "Ore is the in-game currency. Code: ItMi_Orenugget. It uses the verified native inventory add/remove path and does not read the current total."
    "选择属性后先读取；写入可选择 CurrentValue、BaseValue 或两者。属性使用独立 C++ 桥，不混入瞬移桥。" = "Read an attribute first. Writes can target CurrentValue, BaseValue, or both. Attributes use a separate C++ bridge."
    "建议先读取 Strength / Dexterity / SkillPoints；写入时先用小值测试并回游戏确认。" = "Read Strength, Dexterity, or SkillPoints first. Test writes with a small value and verify in game."
    "读取属性" = "Read Attributes"
    "写入当前值" = "Write Current"
    "写入基础值" = "Write Base"
    "两者都写入" = "Write Both"
    "清空显示" = "Clear View"
    "字段" = "Field"
    "值" = "Value"
    "备注" = "Notes"
    "分类" = "Category"
    "草本植物" = "Herbs"
    "单手武器" = "One-Handed Weapons"
    "双手武器" = "Two-Handed Weapons"
    "符石" = "Runes"
    "弓" = "Bows"
    "护甲" = "Armor"
    "护身符" = "Amulets"
    "戒指" = "Rings"
    "卷轴" = "Scrolls"
    "食物" = "Food"
    "药水" = "Potions"
    "钥匙" = "Keys"
    "杂项" = "Miscellaneous"
    "数量" = "Quantity"
    "生成到脚边" = "Spawn Nearby"
    "代码" = "Code"
    "资源路径" = "Asset Path"
    "命名中文名" = "Set Display Name"
    "清空中文名" = "Clear Display Name"
    "复制代码" = "Copy Code"
    "添加进背包" = "Add to Inventory"
    "尝试读取" = "Try Read"
    "只读探针" = "Read-only Probe"
    "增加到背包" = "Add to Inventory"
    "从背包删除" = "Remove from Inventory"
    "保存快照(实验)" = "Save Snapshot*"
    "差量还原(实验)" = "Delta Restore*"
    "中文名" = "Display Name"
    "英文代码" = "English Code"
    "启用一键开锁" = "Enable Instant Unlock"
    "物品生成" = "Item Spawn"
    "开锁" = "Unlock"
    "物品高亮" = "Item Highlight"
    "立即高亮（同 V 键）" = "Highlight Now (same as V)"
    "高亮距离（米）" = "Highlight Distance (m)"
    "高亮时间（秒）" = "Highlight Duration (s)"
    "高亮颜色" = "Outline Color"
    "蓝色（已验证）" = "Blue (verified)"
    "亮度" = "Brightness"
    "粗轮廓" = "Thick Outline"
    "包含尸体" = "Include Corpses"
    "包含宝箱" = "Include Chests"
    "刷新日志" = "Refresh Log"
    "重载核心" = "Reload Core"
    "全量热重载(Ctrl+R)" = "Full Reload (Ctrl+R)"
    "瞬移诊断" = "Teleport Diagnostics"
    "瞬移状态" = "Teleport Status"
    "C++桥诊断" = "C++ Bridge Diagnostics"
    "C++桥状态" = "C++ Bridge Status"
    "内存桥诊断" = "Memory Bridge Diagnostics"
    "内存桥状态" = "Memory Bridge Status"
    "UE4SS日志" = "UE4SS Log"
    "物品状态" = "Item Status"
    "背包动作状态" = "Inventory Action Status"
    "背包列表" = "Inventory List"
    "人物属性状态" = "Attribute Status"
    "人物属性诊断" = "Attribute Diagnostics"
    "开锁状态" = "Unlock Status"
    "物品高亮状态" = "Item Highlight Status"
    "UI错误" = "UI Errors"
    " 自由飞翔 " = " Free Flight "
    "开启自由飞翔" = "Enable Free Flight"
    "飞行速度倍率:" = "Flight Speed:"
    "检查实际状态" = "Check Status"
    "F7 可直接开关。W/S 沿镜头方向前进/后退，A/D 左右平移。普通互动会自动关闭飞行；互动或对话结束后请手动重新开启。" = "Press F7 to toggle. W/S follows the camera; A/D strafes. Normal interactions turn flight off; enable it again afterward."
    " 游戏世界与时空控制 (World & Time Control) " = " World & Time Control "
    "冻结世界与敌人 (仅自己可动 / 时空静止)" = "Freeze World and Enemies (player can move)"
    "暂停昼夜时钟流逝 (锁死白天/黑夜)" = "Pause Day/Night Clock"
    "快进世界时间 (Advance Time):" = "Advance World Time:"
    "+1 小时" = "+1 Hour"
    "+3 小时" = "+3 Hours"
    "+6 小时" = "+6 Hours"
    "+12 小时" = "+12 Hours"
    "+24 小时" = "+24 Hours"
    "清空检索" = "Clear Search"
    "全部" = "All"
    "全部展开" = "Expand All"
    "全部折叠" = "Collapse All"
    "选择左侧任务查看攻略内容。" = "Select a quest on the left to view its walkthrough."
    "支持开发者（仅 USDT / TRON）" = "Support the developer (USDT / TRON only)"
    "钱包地址" = "Wallet address"
    "复制 USDT 地址" = "Copy USDT Address"
    "已复制 USDT (TRON) 地址。" = "USDT (TRON) address copied."
    "护眼颜色" = "Theme"
    "窗口置顶" = "Pin Window"
    "取消置顶" = "Unpin"
    "F6 可唤起本窗口；右键节点可绑定小键盘；UI 打开时小键盘输入不会触发瞬移。" = "F6 opens or toggles this window. Right-click a node for numpad binding."
    "UI 已显示并恢复前台。" = "UI restored to the foreground."
    "UI 已最小化到任务栏。" = "UI minimized to the taskbar."
    "窗口置顶已关闭。" = "Always on top disabled."
    "窗口置顶已开启。" = "Always on top enabled."
    "列表已刷新。" = "List refreshed."
    "没有找到游戏进程，无法发送 R 热重载。" = "Game process not found; reload was not sent."
    "已发送保存请求。" = "Save request sent."
    "已发送核心重载请求。回游戏等待 0.5 秒，或刷新日志查看结果。" = "Core reload requested. Return to the game or refresh the log."
    "已发送快进时间: +1 小时" = "Advanced world time by 1 hour."
    "已发送快进时间: +3 小时" = "Advanced world time by 3 hours."
    "已发送快进时间: +6 小时" = "Advanced world time by 6 hours."
    "已发送快进时间: +12 小时" = "Advanced world time by 12 hours."
    "已发送快进时间: +24 小时" = "Advanced world time by 24 hours."
    "已发送扫描周围人物请求。" = "Nearby NPC scan requested."
    "已检测到游戏进程，UI 已绑定。" = "Game process detected; UI attached."
    "已请求检查自由飞翔状态，请在日志/诊断页刷新瞬移诊断。" = "Free Flight status check requested. Refresh teleport diagnostics for details."
    "已通过 F1 请求保存当前位置..." = "F1 position save requested..."
    "已向游戏发送 Ctrl+R 热重载。请等 UE4SS 日志出现 All mods re-installed。" = "Ctrl+R reload sent. Wait for 'All mods re-installed' in UE4SS.log."
    "找到了游戏进程，但暂时没有窗口句柄。请手动回游戏按 R。" = "Game process found without a window handle. Return to the game and press R manually."
}
$script:uiTextZh = @{}
foreach ($entry in $script:uiTextEn.GetEnumerator()) {
    $script:uiTextZh[$entry.Value] = $entry.Key
}

function Convert-UiText([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return $text }
    if ($script:uiLanguage -eq "en") {
        if ($script:uiTextEn.ContainsKey($text)) { return $script:uiTextEn[$text] }
        if ($text -match '^小键盘 (\d+)$') { return "Numpad $($Matches[1])" }
    } else {
        if ($script:uiTextZh.ContainsKey($text)) { return $script:uiTextZh[$text] }
        if ($text -match '^Numpad (\d+)$') { return "小键盘 $($Matches[1])" }
    }
    return $text
}

function Set-ToolStripLanguage($item) {
    if (-not $item) { return }
    $item.Text = Convert-UiText $item.Text
    if ($item -is [System.Windows.Forms.ToolStripDropDownItem]) {
        foreach ($child in $item.DropDownItems) { Set-ToolStripLanguage $child }
    }
}

function Get-UiButtonFont([System.Drawing.FontStyle]$style, [double]$size) {
    $familyName = if ($script:uiLanguage -eq "en") { "Segoe UI" } else { "Microsoft YaHei UI" }
    $key = "{0}|{1:0.0}|{2}" -f $familyName, $size, [int]$style
    if (-not $script:uiButtonFontCache.ContainsKey($key)) {
        $script:uiButtonFontCache[$key] = [System.Drawing.Font]::new(
            $familyName,
            [single]$size,
            $style,
            [System.Drawing.GraphicsUnit]::Point
        )
    }
    return $script:uiButtonFontCache[$key]
}

function Fit-UiButtonText($button) {
    if (-not ($button -is [System.Windows.Forms.Button])) { return }

    $sizes = if ($script:uiLanguage -eq "en") { @(9.0, 8.5, 8.0, 7.5) } else { @(10.0, 9.5, 9.0, 8.5) }
    $availableWidth = [Math]::Max(8, $button.ClientSize.Width - 12)
    $availableHeight = [Math]::Max(8, $button.ClientSize.Height - 6)
    $button.AutoEllipsis = $false

    foreach ($size in $sizes) {
        $candidate = Get-UiButtonFont $button.Font.Style $size
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($button.Text, $candidate)
        if ($measured.Width -le $availableWidth -and $measured.Height -le $availableHeight) {
            $button.Font = $candidate
            return
        }
    }

    $button.Font = Get-UiButtonFont $button.Font.Style $sizes[-1]
    $button.AutoEllipsis = $true
}

function Layout-ItemSpawnTopControls {
    if (-not $itemSearchLabel) { return }
    if ($script:uiLanguage -eq "en") {
        $itemSearchLabel.Location = New-Object System.Drawing.Point(12, 16)
        $itemSearchBox.Location = New-Object System.Drawing.Point(88, 12)
        $itemSearchBox.Width = 260
        $itemCategoryLabel.Location = New-Object System.Drawing.Point(370, 16)
        $itemCategoryBox.Location = New-Object System.Drawing.Point(435, 12)
        $itemCategoryBox.Width = 142
        $itemQtyLabel.Location = New-Object System.Drawing.Point(598, 16)
        $itemQtyBox.Location = New-Object System.Drawing.Point(660, 12)
        $itemQtyBox.Width = 48
        $itemSpawnButton.Location = New-Object System.Drawing.Point(722, 10)
    } else {
        $itemSearchLabel.Location = New-Object System.Drawing.Point(12, 16)
        $itemSearchBox.Location = New-Object System.Drawing.Point(60, 12)
        $itemSearchBox.Width = 260
        $itemCategoryLabel.Location = New-Object System.Drawing.Point(340, 16)
        $itemCategoryBox.Location = New-Object System.Drawing.Point(388, 12)
        $itemCategoryBox.Width = 160
        $itemQtyLabel.Location = New-Object System.Drawing.Point(568, 16)
        $itemQtyBox.Location = New-Object System.Drawing.Point(616, 12)
        $itemQtyBox.Width = 56
        $itemSpawnButton.Location = New-Object System.Drawing.Point(692, 10)
    }
}

function Layout-TeleportNodesTopControls {
    if (-not $topPanel) { return }
    if ($script:uiLanguage -eq "en") {
        $searchLabel.Location = New-Object System.Drawing.Point(12, 16)
        $searchBox.Location = New-Object System.Drawing.Point(76, 12)
        $searchBox.Width = 218
        $saveLabel.Location = New-Object System.Drawing.Point(312, 16)
        $saveNameBox.Location = New-Object System.Drawing.Point(412, 12)
        $saveNameBox.Width = 158
        $countLabel.Visible = $false
        $teleportCoordLabel.Location = New-Object System.Drawing.Point(12, 56)
        $teleportCoordBox.Location = New-Object System.Drawing.Point(164, 52)
        $teleportCoordBox.Width = 406
    } else {
        $searchLabel.Location = New-Object System.Drawing.Point(12, 16)
        $searchBox.Location = New-Object System.Drawing.Point(64, 12)
        $searchBox.Width = 220
        $saveLabel.Location = New-Object System.Drawing.Point(310, 16)
        $saveNameBox.Location = New-Object System.Drawing.Point(384, 12)
        $saveNameBox.Width = 180
        $countLabel.Visible = $true
        $teleportCoordLabel.Location = New-Object System.Drawing.Point(12, 56)
        $teleportCoordBox.Location = New-Object System.Drawing.Point(92, 52)
        $teleportCoordBox.Width = 470
    }
}

function Layout-OreTopControls {
    if (-not $moneyTopPanel) { return }
    if ($script:uiLanguage -eq "en") {
        $moneyCurrentValueLabel.Location = New-Object System.Drawing.Point(12, 48)
        $moneyCurrentValueBox.Location = New-Object System.Drawing.Point(84, 44)
        $moneyCurrentValueBox.Width = 160
        $moneyWriteValueLabel.Location = New-Object System.Drawing.Point(270, 48)
        $moneyWriteValueBox.Location = New-Object System.Drawing.Point(388, 44)
        $moneyWriteValueBox.Width = 130
        $moneyCandidateCountLabel.Location = New-Object System.Drawing.Point(540, 48)
    } else {
        $moneyCurrentValueLabel.Location = New-Object System.Drawing.Point(12, 48)
        $moneyCurrentValueBox.Location = New-Object System.Drawing.Point(90, 44)
        $moneyCurrentValueBox.Width = 160
        $moneyWriteValueLabel.Location = New-Object System.Drawing.Point(280, 48)
        $moneyWriteValueBox.Location = New-Object System.Drawing.Point(358, 44)
        $moneyWriteValueBox.Width = 160
        $moneyCandidateCountLabel.Location = New-Object System.Drawing.Point(548, 48)
    }
}

function Layout-AttributeTopControls {
    if (-not $attrTopPanel) { return }
    if ($script:uiLanguage -eq "en") {
        $attrSelectLabel.Location = New-Object System.Drawing.Point(12, 48)
        $attrSelectBox.Location = New-Object System.Drawing.Point(82, 44)
        $attrSelectBox.Width = 150
        $attrCurrentValueLabel.Location = New-Object System.Drawing.Point(250, 48)
        $attrCurrentValueBox.Location = New-Object System.Drawing.Point(348, 44)
        $attrCurrentValueBox.Width = 115
        $attrWriteValueLabel.Location = New-Object System.Drawing.Point(480, 48)
        $attrWriteValueBox.Location = New-Object System.Drawing.Point(570, 44)
        $attrWriteValueBox.Width = 115
        $attrCandidateCountLabel.Location = New-Object System.Drawing.Point(695, 48)
    } else {
        $attrSelectLabel.Location = New-Object System.Drawing.Point(12, 48)
        $attrSelectBox.Location = New-Object System.Drawing.Point(60, 44)
        $attrSelectBox.Width = 170
        $attrCurrentValueLabel.Location = New-Object System.Drawing.Point(260, 48)
        $attrCurrentValueBox.Location = New-Object System.Drawing.Point(322, 44)
        $attrCurrentValueBox.Width = 140
        $attrWriteValueLabel.Location = New-Object System.Drawing.Point(490, 48)
        $attrWriteValueBox.Location = New-Object System.Drawing.Point(552, 44)
        $attrWriteValueBox.Width = 140
        $attrCandidateCountLabel.Location = New-Object System.Drawing.Point(722, 48)
    }
}

function Layout-DiagnosticsTopControls {
    if (-not $diagTopPanel) { return }
    if ($script:uiLanguage -eq "en") {
        $diagSourceLabel.Location = New-Object System.Drawing.Point(12, 17)
        $diagSourceBox.Location = New-Object System.Drawing.Point(64, 13)
        $diagSourceBox.Width = 140
    } else {
        $diagSourceLabel.Location = New-Object System.Drawing.Point(12, 17)
        $diagSourceBox.Location = New-Object System.Drawing.Point(54, 13)
        $diagSourceBox.Width = 150
    }
}

function Set-ControlLanguage($control) {
    if (-not $control) { return }
    $control.Text = Convert-UiText $control.Text
    if ($control -is [System.Windows.Forms.Button]) {
        Fit-UiButtonText $control
    }

    if ($control -is [System.Windows.Forms.ListView]) {
        foreach ($column in $control.Columns) { $column.Text = Convert-UiText $column.Text }
    }
    if ($control -is [System.Windows.Forms.ComboBox]) {
        for ($index = 0; $index -lt $control.Items.Count; $index++) {
            if ($control.Items[$index] -is [string]) {
                $control.Items[$index] = Convert-UiText ([string]$control.Items[$index])
            }
        }
    }
    if ($control -is [System.Windows.Forms.ToolStrip]) {
        foreach ($item in $control.Items) { Set-ToolStripLanguage $item }
    }
    if ($control.ContextMenuStrip) {
        foreach ($item in $control.ContextMenuStrip.Items) { Set-ToolStripLanguage $item }
    }
    foreach ($child in $control.Controls) { Set-ControlLanguage $child }
}

function Apply-UiLanguage([string]$language) {
    $script:uiLanguage = if ($language -eq "en") { "en" } else { "zh" }
    Set-ControlLanguage $form
    foreach ($menu in @($spotsContextMenu, $npcContextMenu, $itemContextMenu, $inventoryContextMenu)) {
        if ($menu) {
            foreach ($item in $menu.Items) { Set-ToolStripLanguage $item }
        }
    }
    $guideBox.Text = if ($script:uiLanguage -eq "en") { $script:guideTextEn } else { $script:guideTextZh }
    $highlightInfoLabel.Text = if ($script:uiLanguage -eq "en") { $script:highlightInfoTextEn } else { $script:highlightInfoTextZh }
    if ($highlightColorBox -and $highlightColorBox.Items.Count -gt 0) {
        $highlightColorBox.Items[0] = if ($script:uiLanguage -eq "en") { "Blue (verified)" } else { "蓝色（已验证）" }
        $highlightColorBox.SelectedIndex = 0
    }
    Layout-ItemSpawnTopControls
    Layout-TeleportNodesTopControls
    Layout-OreTopControls
    Layout-AttributeTopControls
    Layout-DiagnosticsTopControls
    Refresh-ItemCategories
    Refresh-ItemList
    if ($languageButton) {
        $languageButton.Text = if ($script:uiLanguage -eq "en") { "中文" } else { "English" }
    }
    Sync-TopMostButtonText
    Layout-ThemeBarControls
}

$themeBar = New-Object System.Windows.Forms.Panel
$themeBar.Dock = "Fill"
$themeBar.Height = 34
$themeBar.Padding = New-Object System.Windows.Forms.Padding(8, 5, 12, 5)

$themeLabel = New-Object System.Windows.Forms.Label
$themeLabel.Text = "护眼颜色"
$themeLabel.AutoSize = $true
$themeLabel.Anchor = "Top,Right"
$themeLabel.Location = New-Object System.Drawing.Point(700, 9)

$themeSelectBox = New-Object System.Windows.Forms.ComboBox
$themeSelectBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$themeSelectBox.Width = 130
$themeSelectBox.Anchor = "Top,Right"
$themeSelectBox.Location = New-Object System.Drawing.Point(780, 5)
foreach ($themeName in $script:uiThemes.Keys) {
    [void]$themeSelectBox.Items.Add($themeName)
}
$themeSelectBox.SelectedItem = $script:currentThemeName

$topMostButton = New-UiButton "取消置顶" 90
$topMostButton.Anchor = "Top,Right"
$topMostButton.Location = New-Object System.Drawing.Point(680, 4)

$languageButton = New-UiButton "English" 78
$languageButton.Anchor = "Top,Right"
$languageButton.Location = New-Object System.Drawing.Point(592, 4)

function Sync-TopMostButtonText {
    if ($script:uiLanguage -eq "en") {
        $topMostButton.Text = if ($script:userTopMostEnabled) { "Unpin" } else { "Pin Window" }
    } else {
        $topMostButton.Text = if ($script:userTopMostEnabled) { "取消置顶" } else { "窗口置顶" }
    }
    Fit-UiButtonText $topMostButton
}

$themeBar.Controls.AddRange(@($themeLabel, $themeSelectBox, $topMostButton, $languageButton))
function Layout-ThemeBarControls {
    $right = $themeBar.ClientSize.Width - $themeBar.Padding.Right
    $themeSelectBox.Left = $right - $themeSelectBox.Width
    $themeLabel.Left = $themeSelectBox.Left - 12 - $themeLabel.Width
    $topMostButton.Left = $themeLabel.Left - 18 - $topMostButton.Width
    $languageButton.Left = $topMostButton.Left - 10 - $languageButton.Width
}
$themeBar.Add_SizeChanged({ Layout-ThemeBarControls })

$themeSelectBox.Add_SelectedIndexChanged({
    if ($themeSelectBox.SelectedItem) {
        Apply-UiTheme $themeSelectBox.SelectedItem.ToString()
    }
})

$topMostButton.Add_Click({
    $script:userTopMostEnabled = -not $script:userTopMostEnabled
    $form.TopMost = $script:userTopMostEnabled
    Sync-TopMostButtonText
    if ($script:userTopMostEnabled) {
        $form.BringToFront()
        $form.Activate()
        [void](Activate-WindowByProcessId $PID)
        Set-Status "窗口置顶已开启。"
    } else {
        Set-Status "窗口置顶已关闭。"
    }
})
$languageButton.Add_Click({
    if ($script:uiLanguage -eq "en") {
        Apply-UiLanguage "zh"
    } else {
        Apply-UiLanguage "en"
    }
})
Sync-TopMostButtonText

$rootLayoutPanel = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayoutPanel.Dock = "Fill"
$rootLayoutPanel.ColumnCount = 1
$rootLayoutPanel.RowCount = 2
$rootLayoutPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$rootLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34))) | Out-Null
$rootLayoutPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$rootLayoutPanel.Controls.Add($themeBar, 0, 0)
$rootLayoutPanel.Controls.Add($tabs, 0, 1)

$modifyTabs.TabPages.Add($moneyTab) | Out-Null
$modifyTabs.TabPages.Add($attrTab) | Out-Null
$modifyTab.Controls.Add($modifyTabs)

$tabs.TabPages.Add($spotsTab) | Out-Null
$tabs.TabPages.Add($modifyTab) | Out-Null
$tabs.TabPages.Add($itemUnlockTab) | Out-Null
$tabs.TabPages.Add($npcScanTab) | Out-Null
$tabs.TabPages.Add($worldTimeTab) | Out-Null
$tabs.TabPages.Add($diagTab) | Out-Null
# $tabs.TabPages.Add($walkthroughTab) | Out-Null  # Gothic 版暂无攻略文件，暂时隐藏
$tabs.TabPages.Add($guideTab) | Out-Null
$form.Controls.Add($rootLayoutPanel)
Apply-UiTheme $script:currentThemeName
Apply-UiLanguage "zh"

$searchBox.Add_TextChanged({ Refresh-SpotList })

$refreshButton.Add_Click({
    Refresh-SpotList
    Set-Status "列表已刷新。"
})

$saveButton.Add_Click({
    Append-Action ("SAVE|{0}" -f $saveNameBox.Text.Trim())
    Set-Status "已发送保存请求。"
    Start-Sleep -Milliseconds 100
    Refresh-SpotList
})

$teleportCoordButton.Add_Click({
    try {
        Start-ManualTeleport
    } catch {
        Set-Status ("手动飞行失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "瞬移管理")
    }
})

$spotsTeleportMenuItem.Add_Click({
    $spot = Require-SelectedSpot
    if (-not $spot) { return }
    Send-TeleportAction `
        ("TELEPORT_COORD|{0}|{1}|{2}|{3}" -f $spot.X, $spot.Y, $spot.Z, $spot.Name) `
        ("已发送瞬移请求: [{0}] {1}" -f $spot.Index, $spot.Name) | Out-Null
})

$spotsPullNpcMenuItem.Add_Click({
    try {
        Start-SelectedSpotNpcPull
    } catch {
        Set-Status ("节点人物拉取失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "人物拉取") | Out-Null
    }
})

$spotsRenameMenuItem.Add_Click({
    $spot = Require-SelectedSpot
    if (-not $spot) { return }
    $newName = Read-SpotRenameName $spot
    if ([string]::IsNullOrWhiteSpace($newName)) { return }
    Append-Action ("RENAME|{0}|{1}" -f $spot.Index, $newName)
    Set-Status ("已发送重命名请求: [{0}] {1}" -f $spot.Index, $newName)
    Start-Sleep -Milliseconds 100
    Refresh-SpotList
})

$spotsDeleteMenuItem.Add_Click({
    Delete-SelectedSpots
})

$spotsCopyCoordsMenuItem.Add_Click({
    $spot = Require-SelectedSpot
    if (-not $spot) { return }
    $coordText = "X: {0} | Y: {1} | Z: {2}" -f $spot.X, $spot.Y, $spot.Z
    Copy-SpotText $coordText
    Set-Status ("已复制坐标: {0}" -f $coordText)
})

$npcScanButton.Add_Click({
    try {
        Start-NpcNearbyScan
    } catch {
        Set-Status ("扫描人物失败: {0}" -f $_.Exception.Message)
        if ($npcScanStatusLabel) { $npcScanStatusLabel.Text = "扫描失败: " + $_.Exception.Message }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "扫描周围人物")
    }
})

$npcScanSearchBox.Add_TextChanged({
    Refresh-NpcScanViews
})

$npcScanStateFilterCombo.Add_SelectedIndexChanged({
    Refresh-NpcScanViews
})

$npcScanClearSearchButton.Add_Click({
    $npcScanSearchBox.Clear()
    Refresh-NpcScanViews
})

$npcTeleportMenuItem.Add_Click({
    Invoke-NpcEntryTeleport (Get-CurrentNpcEntry)
})

$npcPullMenuItem.Add_Click({
    try {
        Start-SelectedNpcPull
    } catch {
        Set-Status ("人物拉取失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "人物拉取") | Out-Null
    }
})

$npcAddSpotMenuItem.Add_Click({
    try {
        Add-NpcEntryToSpots (Get-CurrentNpcEntry)
    } catch {
        Set-Status ("添加扫描人物失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "扫描周围人物")
    }
})

$npcCopyNodeMenuItem.Add_Click({
    Copy-NpcEntryNode (Get-CurrentNpcEntry)
})

$oreCustomAddButton.Add_Click({
    try {
        Send-CustomOreChange "ADD"
    } catch {
        Set-MoneyStatus ("自定义增加失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "矿石")
    }
})

$oreCustomRemoveButton.Add_Click({
    try {
        Send-CustomOreChange "REMOVE"
    } catch {
        Set-MoneyStatus ("自定义减少失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "矿石")
    }
})

$moneyCandidateListView.Add_SelectedIndexChanged({
    $candidate = Get-MoneySelectedCandidate
    if ($candidate) {
        Set-MoneyStatus "矿石使用固定底层代码 ItMi_Orenugget。"
        if ($moneyDetailBox) {
            $moneyDetailBox.Text = "矿石固定代码: ItMi_Orenugget`r`n方式: 背包原生增删 INV_NATIVE_ADD/REMOVE`r`n说明: 每次直接使用输入数量。第一版不读取当前矿石总数，请在游戏背包确认变化。"
        }
    }
})

$attrSelectBox.Add_SelectedIndexChanged({
    Sync-AttributeInputs
})

$attrDetectButton.Add_Click({
    try {
        Start-AttrDetect
    } catch {
        Set-AttrStatus ("读取失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "人物属性")
    }
})

$attrRefreshButton.Add_Click({
    try {
        Start-AttrRefresh
    } catch {
        Set-AttrStatus ("写入当前值失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "人物属性")
    }
})

$attrWriteSelectedButton.Add_Click({
    try {
        Write-SelectedAttrCandidate
    } catch {
        Set-AttrStatus ("写入基础值失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "人物属性")
    }
})

$attrPinButton.Add_Click({
    try {
        Pin-SelectedAttrCandidate
    } catch {
        Set-AttrStatus ("写入失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "人物属性")
    }
})

$attrClearButton.Add_Click({
    try {
        Clear-AttrCandidates
    } catch {
        Set-AttrStatus ("清空失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "人物属性")
    }
})

$attrCandidateListView.Add_SelectedIndexChanged({
    $candidate = Get-AttrSelectedCandidate
    if ($candidate) {
        $attrName = Get-AttributeName $candidate.AttrKey
        Set-AttrStatus ("已选中 {0} 的 {1} [{2}]，完整路径见下方。" -f $attrName, $candidate.Type, $candidate.RootKind)
        if ($attrDetailBox) {
            $hint = Get-CandidatePathHint $candidate.Path
            $attrDetailBox.Text = ("属性: {0}`r`n当前值: {1}    评分: {2}`r`n类型: {3}`r`n根: {4}`r`n路径: {5}`r`n{6}" -f $attrName, $candidate.Value, $candidate.Score, $candidate.Type, $candidate.RootKind, $candidate.Path, $hint)
        }
    }
})

$itemSearchBox.Add_TextChanged({
    Refresh-ItemList
})

$itemCategoryBox.Add_SelectedIndexChanged({
    if ($script:itemCategorySyncing) { return }
    Refresh-ItemList
})

$itemSpawnButton.Add_Click({
    try {
        Start-SpawnSelectedItem
    } catch {
        Set-ItemStatus ("生成失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "物品生成")
    }
})

$itemListView.Add_SelectedIndexChanged({
    $entry = Get-SelectedItemEntry
    if ($entry -and $itemDetailBox) {
        $display = Get-ItemDisplayInfo ([string]$entry.Code)
        $itemDetailBox.Text = ("代码: {0}`r`n中文名: {1}`r`n目录原名: {2}`r`n分类: {3}`r`n命令: {4}`r`n路径: {5}" -f $entry.Code, $display.Name, $entry.Name, $entry.Category, $entry.Command, $entry.Path)
    }
})

$itemRenameMenuItem.Add_Click({
    Show-ItemRenameDialog (Get-SelectedItemEntry)
})

$itemClearNameMenuItem.Add_Click({
    $entry = Get-SelectedItemEntry
    if ($entry) {
        Set-ItemNameOverride ([string]$entry.Code) ""
        Set-ItemStatus ("已清空中文名: {0}" -f $entry.Code)
    }
})

$itemAddInventoryMenuItem.Add_Click({
    try {
        $entry = Get-SelectedItemEntry
        if (-not $entry) { throw "请先选中一个物品。" }
        $qty = Get-ItemQuantityInput
        $sent = Invoke-InventoryNativeChange "ADD" ([string]$entry.Code) $qty
        Set-ItemStatus ("已发送添加进背包请求: {0} x{1}，拆分 {2} 条。" -f $entry.Code, $qty, $sent)
    } catch {
        Set-ItemStatus ("添加进背包失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "物品生成")
    }
})

$itemRemoveInventoryMenuItem.Add_Click({
    try {
        $entry = Get-SelectedItemEntry
        if (-not $entry) { throw "请先选中一个物品。" }
        $qty = Get-ItemQuantityInput
        $sent = Invoke-InventoryNativeChange "REMOVE" ([string]$entry.Code) $qty
        Set-ItemStatus ("已发送从背包删除请求: {0} x{1}，拆分 {2} 条。" -f $entry.Code, $qty, $sent)
    } catch {
        Set-ItemStatus ("从背包删除失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "物品生成")
    }
})

$itemListView.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $hit = $itemListView.HitTest($e.Location)
    if ($hit -and $hit.Item) {
        $hit.Item.Selected = $true
        $itemListView.FocusedItem = $hit.Item
    }
})

$itemListView.Add_DoubleClick({
    try {
        Start-SpawnSelectedItem
    } catch {
        Set-ItemStatus ("生成失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "物品生成")
    }
})

$inventorySearchBox.Add_TextChanged({
    Refresh-InventoryList
})

$inventoryRefreshButton.Add_Click({
    try {
        Start-InventoryRefresh
    } catch {
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 刷新失败: {0}" -f $_.Exception.Message) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "背包管理")
    }
})

$inventoryProbeButton.Add_Click({
    try {
        Start-InventoryProbe
    } catch {
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 探针失败: {0}" -f $_.Exception.Message) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "背包管理")
    }
})

$inventoryAddButton.Add_Click({
    try {
        Invoke-InventoryNativeChange "ADD" (Get-InventoryCodeInput) (Get-InventoryQtyInput)
    } catch {
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 增加失败: {0}" -f $_.Exception.Message) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "背包管理")
    }
})

$inventoryRemoveButton.Add_Click({
    try {
        Invoke-InventoryNativeChange "REMOVE" (Get-InventoryCodeInput) (Get-InventoryQtyInput)
    } catch {
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 删除失败: {0}" -f $_.Exception.Message) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "背包管理")
    }
})

$inventorySnapshotButton.Add_Click({
    try {
        $path = Save-InventorySnapshot
        $inventoryDetailBox.Text = "快照已保存:`r`n$path`r`n`r`n还原会按英文代码和数量做差量增删，不改存档结构。"
    } catch {
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 保存快照失败: {0}" -f $_.Exception.Message) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "背包管理")
    }
})

$inventoryRestoreButton.Add_Click({
    try {
        $commands = Restore-InventorySnapshotDelta
        $inventoryDetailBox.Text = "已发送差量还原动作: $commands 条。`r`n请回游戏确认背包变化；确认后可再次刷新背包。"
    } catch {
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 还原失败: {0}" -f $_.Exception.Message) }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "背包管理")
    }
})

$inventoryListView.Add_SelectedIndexChanged({
    $entry = Get-SelectedInventoryEntry
    if ($entry) {
        if ($inventoryCodeBox) { $inventoryCodeBox.Text = [string]$entry.Code }
        if ($inventoryDetailBox) {
            $inventoryDetailBox.Text = ("中文名: {0}`r`n英文代码: {1}`r`n数量: {2}`r`n分类: {3}`r`n显示来源: {4}`r`n读取来源: {5}`r`n类名: {6}" -f $entry.Name, $entry.Code, $entry.Qty, $entry.Category, $entry.DisplaySource, $entry.Source, $entry.ClassName)
        }
    }
})

$inventoryListView.Add_DoubleClick({
    if ($inventoryListView.FocusedItem -and (Test-InventoryGroupTag $inventoryListView.FocusedItem.Tag)) {
        Toggle-InventoryGroup $inventoryListView.FocusedItem.Tag.GroupName
    }
})

$inventoryListView.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hit = $inventoryListView.HitTest($e.Location)
    if (-not $hit -or -not $hit.Item) { return }
    if (Test-InventoryGroupTag $hit.Item.Tag) {
        Toggle-InventoryGroup $hit.Item.Tag.GroupName
    }
})

$inventoryRenameMenuItem.Add_Click({
    $entry = Get-SelectedInventoryEntry
    if ($entry) {
        Show-ItemRenameDialog $entry
        Refresh-InventoryList
    }
})

$inventoryClearNameMenuItem.Add_Click({
    $entry = Get-SelectedInventoryEntry
    if ($entry) {
        Set-ItemNameOverride ([string]$entry.Code) ""
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 已清空中文名: {0}" -f $entry.Code) }
        Refresh-InventoryList
    }
})

$inventoryCopyCodeMenuItem.Add_Click({
    $entry = Get-SelectedInventoryEntry
    if ($entry) {
        [System.Windows.Forms.Clipboard]::SetText([string]$entry.Code)
        if ($inventoryStatusLabel) { $inventoryStatusLabel.Text = ("背包: 已复制代码: {0}" -f $entry.Code) }
    }
})

$inventoryListView.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $hit = $inventoryListView.HitTest($e.Location)
    if ($hit -and $hit.Item) {
        if (-not (Test-InventoryGroupTag $hit.Item.Tag)) {
            $hit.Item.Selected = $true
            $inventoryListView.FocusedItem = $hit.Item
        }
    }
})

$unlockEnabledCheckBox.Add_CheckedChanged({
    if ($script:unlockSyncing) { return }
    try {
        Write-UnlockControl $unlockEnabledCheckBox.Checked
        if ($unlockEnabledCheckBox.Checked) {
            Set-UnlockStatus "已请求启用，等待游戏确认。"
        } else {
            Set-UnlockStatus "已请求关闭，等待游戏确认。"
        }
    } catch {
        Set-UnlockStatus ("写入开关失败: {0}" -f $_.Exception.Message)
    }
})

# ---- FocusNearbyPickups Ping Mode v3 control ----
function Limit-FnpInt([int]$value, [int]$minimum, [int]$maximum) {
    if ($value -lt $minimum) { return $minimum }
    if ($value -gt $maximum) { return $maximum }
    return $value
}

function Read-FnpValues([string]$path) {
    $values = @{}
    foreach ($line in Read-FileShareSafe $path) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*([A-Za-z_]+)\s*(?:=|\s)\s*(\S+)') {
            $values[$Matches[1].ToUpperInvariant()] = $Matches[2]
        }
    }
    return $values
}

function Get-FnpStencilValue {
    $index = $highlightColorBox.SelectedIndex
    if ($index -lt 0 -or $index -ge $script:fnpStencilValues.Length) { return 4 }
    return [int]$script:fnpStencilValues[$index]
}

function Set-FnpStencilSelection([int]$stencil) {
    for ($i = 0; $i -lt $script:fnpStencilValues.Length; $i++) {
        if ($script:fnpStencilValues[$i] -eq $stencil) {
            $highlightColorBox.SelectedIndex = $i
            return
        }
    }
}

function Update-FnpValueLabels {
    $highlightRadiusValue.Text = "$($highlightRadiusBar.Value)"
    $highlightDurationValue.Text = "$($highlightDurationBar.Value)"
    $highlightAlphaValue.Text = "$($highlightAlphaBar.Value)%"
}

function Write-FnpControl([bool]$ping) {
    try {
        $alpha = [string]::Format(
            [System.Globalization.CultureInfo]::InvariantCulture,
            "{0:0.00}",
            ([double]$highlightAlphaBar.Value / 100.0)
        )
        $lines = [string[]]@(
            "RADIUS $([int]$highlightRadiusBar.Value * 100)",
            "DURATION $([int]$highlightDurationBar.Value)",
            "STENCIL $(Get-FnpStencilValue)",
            "ALPHA $alpha",
            "THICK $(if ($highlightThickCheck.Checked) { '1' } else { '0' })",
            "CORPSES $(if ($highlightCorpsesCheck.Checked) { '1' } else { '0' })",
            "CHESTS $(if ($highlightChestsCheck.Checked) { '1' } else { '0' })"
        )
        $content = [string]::Join([Environment]::NewLine, $lines)
        if ($ping) { $content += [Environment]::NewLine + "PING" }
        $content += [Environment]::NewLine
        [System.IO.File]::WriteAllText($script:focusHighlightControlPath, $content, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        $highlightStatusLabel.Text = "状态：写入高亮设置失败"
        Write-UiErrorLog ("写入物品高亮设置失败: " + $_.Exception.Message)
        return $false
    }
}

function Sync-FnpControlsFromFiles {
    try {
        $values = Read-FnpValues $script:focusHighlightStatusPath
        $controlValues = Read-FnpValues $script:focusHighlightControlPath
        foreach ($key in $controlValues.Keys) { $values[$key] = $controlValues[$key] }

        $script:highlightSyncing = $true
        if ($values.ContainsKey("RADIUS")) {
            $meters = [int]([double]$values["RADIUS"] / 100.0)
            $highlightRadiusBar.Value = Limit-FnpInt $meters $highlightRadiusBar.Minimum $highlightRadiusBar.Maximum
        }
        if ($values.ContainsKey("DURATION")) {
            $duration = [int]$values["DURATION"]
            $highlightDurationBar.Value = Limit-FnpInt $duration $highlightDurationBar.Minimum $highlightDurationBar.Maximum
        }
        if ($values.ContainsKey("STENCIL")) { Set-FnpStencilSelection ([int]$values["STENCIL"]) }
        if ($values.ContainsKey("ALPHA")) {
            $alphaPercent = [int]([double]::Parse($values["ALPHA"], [System.Globalization.CultureInfo]::InvariantCulture) * 100.0)
            $highlightAlphaBar.Value = Limit-FnpInt $alphaPercent $highlightAlphaBar.Minimum $highlightAlphaBar.Maximum
        }
        if ($values.ContainsKey("THICK")) { $highlightThickCheck.Checked = $values["THICK"] -eq "1" }
        if ($values.ContainsKey("CORPSES")) { $highlightCorpsesCheck.Checked = $values["CORPSES"] -eq "1" }
        if ($values.ContainsKey("CHESTS")) { $highlightChestsCheck.Checked = $values["CHESTS"] -eq "1" }
        Update-FnpValueLabels
    } catch {
        $highlightStatusLabel.Text = "状态：现有高亮设置格式无效，已保留界面默认值"
    } finally {
        $script:highlightSyncing = $false
    }
}

function Disable-FocusHighlightForTeleport {
    if ($highlightStatusLabel) {
        $highlightStatusLabel.Text = "状态：瞬移已发起；当前高亮会按设定时间自动结束"
    }
}

function Refresh-FocusHighlightStatus {
    if (-not (Test-Path -LiteralPath $script:focusHighlightStatusPath)) {
        $highlightStatusLabel.Text = "状态：等待游戏加载 FocusNearbyPickups Ping Mode v3…"
        return
    }
    try {
        $status = Read-FnpValues $script:focusHighlightStatusPath
        $state = if ($status.ContainsKey("STATE")) { $status["STATE"] } else { "UNKNOWN" }
        $radius = if ($status.ContainsKey("RADIUS")) { $status["RADIUS"] } else { "$([int]$highlightRadiusBar.Value * 100)" }
        $outlined = if ($status.ContainsKey("OUTLINED")) { $status["OUTLINED"] } else { "0" }
        $mode = if ($status.ContainsKey("MODE")) { $status["MODE"] } else { "PING" }
        $highlightStatusLabel.Text = "状态：$state | 模式 $mode | 距离 ${radius}uu | 当前高亮 $outlined"
    } catch {
        $highlightStatusLabel.Text = "状态：状态文件暂时不可读，稍后自动重试"
    }
}

$highlightPingButton.Add_Click({
    if (Write-FnpControl $true) {
        $highlightStatusLabel.Text = "状态：已发送一次高亮请求"
    }
})

$highlightRadiusBar.Add_ValueChanged({
    Update-FnpValueLabels
    if (-not $script:highlightSyncing) { [void](Write-FnpControl $false) }
})
$highlightDurationBar.Add_ValueChanged({
    Update-FnpValueLabels
    if (-not $script:highlightSyncing) { [void](Write-FnpControl $false) }
})
$highlightAlphaBar.Add_ValueChanged({
    Update-FnpValueLabels
    if (-not $script:highlightSyncing) { [void](Write-FnpControl $false) }
})
$highlightColorBox.Add_SelectedIndexChanged({
    if (-not $script:highlightSyncing) { [void](Write-FnpControl $false) }
})
foreach ($checkBox in @($highlightThickCheck, $highlightCorpsesCheck, $highlightChestsCheck)) {
    $checkBox.Add_CheckedChanged({
        if (-not $script:highlightSyncing) { [void](Write-FnpControl $false) }
    })
}

Sync-FnpControlsFromFiles
Refresh-FocusHighlightStatus

$script:focusHighlightStatusTimer = New-Object System.Windows.Forms.Timer
$script:focusHighlightStatusTimer.Interval = 2000
$script:focusHighlightStatusTimer.Add_Tick({ Refresh-FocusHighlightStatus })


$diagSourceBox.Add_SelectedIndexChanged({
    Refresh-DiagnosticLog
})

$diagRefreshButton.Add_Click({
    Refresh-DiagnosticLog
})

$diagReloadCoreButton.Add_Click({
    Start-CoreReload
    Refresh-DiagnosticLog
})

$diagFullReloadButton.Add_Click({
    Start-FullHotReload
    Start-Sleep -Milliseconds 250
    Refresh-DiagnosticLog
})

$diagClearButton.Add_Click({
    $diagLogBox.Clear()
})

$walkthroughSearchBox.Add_TextChanged({
    Refresh-WalkthroughTree
})

$walkthroughClearButton.Add_Click({
    $walkthroughSearchBox.Clear()
    Refresh-WalkthroughTree
})

$walkthroughExpandButton.Add_Click({
    $walkthroughTreeView.ExpandAll()
})

$walkthroughCollapseButton.Add_Click({
    $walkthroughTreeView.CollapseAll()
})

$walkthroughTreeView.Add_AfterSelect({
    param($sender, $e)
    if ($e.Node -and $e.Node.Tag) {
        Show-WalkthroughEntry $e.Node.Tag
    } else {
        Show-WalkthroughEntry $null
    }
})

$listView.Add_DoubleClick({
    if ($listView.FocusedItem -and (Test-SpotGroupTag $listView.FocusedItem.Tag)) {
        Toggle-SpotGroup $listView.FocusedItem.Tag.GroupName
        return
    }
    $spot = Get-SelectedSpot
    if (-not $spot) { return }
    Send-TeleportAction `
        ("TELEPORT_COORD|{0}|{1}|{2}|{3}" -f $spot.X, $spot.Y, $spot.Z, $spot.Name) `
        ("已发送瞬移请求: [{0}] {1}" -f $spot.Index, $spot.Name) | Out-Null
})

$listView.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        Delete-SelectedSpots
        $e.Handled = $true
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::PageUp) {
        Move-SelectedSpot -1
        $e.Handled = $true
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::PageDown) {
        Move-SelectedSpot 1
        $e.Handled = $true
    }
})

$listView.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hit = $listView.HitTest($e.Location)
    if (-not $hit -or -not $hit.Item) { return }
    if (Test-SpotGroupTag $hit.Item.Tag) {
        Toggle-SpotGroup $hit.Item.Tag.GroupName
    }
})

$listView.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $hit = $listView.HitTest($e.Location)
    if (-not $hit -or -not $hit.Item) { return }
    if (Test-SpotGroupTag $hit.Item.Tag) {
        Toggle-SpotGroup $hit.Item.Tag.GroupName
        return
    }
    if (-not $hit.Item.Selected) {
        foreach ($item in @($listView.SelectedItems)) {
            $item.Selected = $false
        }
    }
    $hit.Item.Selected = $true
    $hit.Item.Focused = $true
    $hit.Item.EnsureVisible()
    Refresh-NumpadBindingMenus
    Update-TeleportControls
    [void]$spotsContextMenu.Show($listView, $e.Location)
})

foreach ($npcView in @($npcScanCurrentListView, $npcScanHistoryListView)) {
    $npcView.Add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $sender.HitTest($e.Location)
        if (-not $hit -or -not $hit.Item) {
            $script:npcSuppressContextMenuOnce = $true
            return
        }
        if (Test-NpcGroupTag $hit.Item.Tag) {
            $script:npcSuppressContextMenuOnce = $true
            foreach ($item in @($sender.SelectedItems)) {
                $item.Selected = $false
            }
            Toggle-NpcGroup $hit.Item.Tag.ViewKind $hit.Item.Tag.GroupName
            return
        }
        if (-not $hit.Item.Selected) {
            foreach ($item in @($sender.SelectedItems)) {
                $item.Selected = $false
            }
        }
        $hit.Item.Selected = $true
        $hit.Item.Focused = $true
        $sender.FocusedItem = $hit.Item
    })
    $npcView.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $hit = $sender.HitTest($e.Location)
        if (-not $hit -or -not $hit.Item) { return }
        if (Test-NpcGroupTag $hit.Item.Tag) {
            Toggle-NpcGroup $hit.Item.Tag.ViewKind $hit.Item.Tag.GroupName
        }
    })
    $npcView.Add_DoubleClick({
        param($sender, $e)
        if ($sender.FocusedItem -and (Test-NpcGroupTag $sender.FocusedItem.Tag)) {
            Toggle-NpcGroup $sender.FocusedItem.Tag.ViewKind $sender.FocusedItem.Tag.GroupName
            return
        }
        Invoke-NpcEntryTeleport (Get-SelectedNpcEntry $sender)
    })
}

$form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F1) {
        # F1: save current position even when UI has focus
        # UE4SS keybinds only fire when the GAME window has focus,
        # so we forward F1 via the action file for the Lua core to pick up.
        try {
            Append-Action "SAVE_CURRENT_POS"
            Set-Status "已通过 F1 请求保存当前位置..."
        } catch {
            Write-UiErrorLog ("F1保存位置失败: " + $_.Exception.Message)
        }
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F6) {
        # When the UI owns keyboard focus, handle F6 locally. If UE4SS also
        # reports the same press, Toggle-UiWindowFromF6 drops it via debounce.
        Toggle-UiWindowFromF6
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    }
})

# Game process monitor: auto-close UI when game exits
$script:gameMonitorTimer = New-Object System.Windows.Forms.Timer
$script:gameMonitorTimer.Interval = 3000
$script:gameMonitorTimer.Add_Tick({
    if (-not $script:gameProcessWasPresentAtStartup) {
        $proc = Get-Process -Name $script:gameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $script:gameProcessId = $proc.Id
            $script:gameProcessWasPresentAtStartup = $true
            Set-Status "已检测到游戏进程，UI 已绑定。"
        }
        return
    }

    $proc = Get-Process -Name $script:gameProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) {
        # No game process found by name - game has truly exited; close the form.
        $form.Close()
    } elseif ($script:gameProcessId) {
        # Game is still running; update our tracked PID if the old one died
        $tracked = Get-Process -Id $script:gameProcessId -ErrorAction SilentlyContinue
        if (-not $tracked) {
            $script:gameProcessId = $proc.Id
        }
    }
})

$form.Add_Shown({
    # Force the first frame above the game before deferred initialization starts.
    Bring-UiWindowToFront
    $script:uiIsShown = $true

    # Minimal sync init: just the flag so F6 toggle works right away
    Invoke-UiInitStep "UI标记" { Set-UiActiveFlag; Clear-UiControlFile }
    Invoke-UiInitStep "UI心跳" {
        Ensure-UiControlTimer
        $script:uiControlTimer.Start()
    }

    # Run one initialization step per message-loop turn so the frame stays responsive.
    $script:deferredInitSteps = @(
        [pscustomobject]@{ Name = "内存桥"; Action = { Ensure-TeleportMemoryBridge } },
        [pscustomobject]@{ Name = "瞬移节点"; Action = { Refresh-SpotList; Update-TeleportControls } },
        [pscustomobject]@{ Name = "扫描人物"; Action = { Load-NpcScanHistory; Refresh-NpcSpotPrefixBox; $script:npcScanItems = @(); Refresh-NpcScanViews } },
        [pscustomobject]@{ Name = "矿石"; Action = { Refresh-MoneyCandidatesList } },
        [pscustomobject]@{ Name = "人物属性"; Action = { Ensure-PlayerEditCppBridge | Out-Null; Refresh-AttrCandidatesList; Sync-AttributeInputs } },
        [pscustomobject]@{ Name = "物品列表"; Action = { Read-ItemCatalog; Read-ItemNameOverrides; Refresh-ItemCategories; Refresh-ItemList } },
        [pscustomobject]@{ Name = "诊断日志"; Action = { Refresh-DiagnosticLog } },
        [pscustomobject]@{ Name = "攻略页"; Action = { Read-WalkthroughGuide; Refresh-WalkthroughTree } },
        [pscustomobject]@{ Name = "计时器"; Action = {
            Ensure-AttrStateTimer
            Ensure-ItemStateTimer
            Ensure-UnlockStateTimer
            Ensure-SpotsFileTimer
            Ensure-TeleportStatusTimer
            Ensure-UiControlTimer
            $script:attrStateTimer.Start()
            $script:itemStateTimer.Start()
            $script:unlockStateTimer.Start()
            $script:spotsFileTimer.Start()
            $script:teleportStatusTimer.Start()
            $script:focusHighlightStatusTimer.Start()
            $script:uiControlTimer.Start()
            $script:gameMonitorTimer.Start()
        } }
    )
    $script:deferredInitIndex = 0
    $script:deferredInitTimer = New-Object System.Windows.Forms.Timer
    $script:deferredInitTimer.Interval = 75
    $script:deferredInitTimer.Add_Tick({
        if ($script:deferredInitIndex -ge $script:deferredInitSteps.Count) {
            $script:deferredInitTimer.Stop()
            $script:deferredInitTimer.Dispose()
            $script:deferredInitTimer = $null
            return
        }

        $step = $script:deferredInitSteps[$script:deferredInitIndex]
        $script:deferredInitIndex++
        Invoke-UiInitStep $step.Name $step.Action
    })
    $script:deferredInitTimer.Start()
})

$form.Add_FormClosed({
    Send-UiClosedNotification
    Stop-Process -Name "*CppBridge*" -Force -ErrorAction SilentlyContinue
    $script:gameMonitorTimer.Stop()
    $script:gameMonitorTimer.Dispose()
    if ($script:moneyStateTimer) { $script:moneyStateTimer.Stop(); $script:moneyStateTimer.Dispose() }
    if ($script:attrStateTimer) { $script:attrStateTimer.Stop(); $script:attrStateTimer.Dispose() }
    if ($script:itemStateTimer) { $script:itemStateTimer.Stop(); $script:itemStateTimer.Dispose() }
    if ($script:itemInventoryListTimer) { $script:itemInventoryListTimer.Stop(); $script:itemInventoryListTimer.Dispose() }
    if ($script:unlockStateTimer) { $script:unlockStateTimer.Stop(); $script:unlockStateTimer.Dispose() }
    if ($script:spotsFileTimer) { $script:spotsFileTimer.Stop(); $script:spotsFileTimer.Dispose() }
    if ($script:teleportStatusTimer) { $script:teleportStatusTimer.Stop(); $script:teleportStatusTimer.Dispose() }
    if ($script:focusHighlightStatusTimer) { $script:focusHighlightStatusTimer.Stop(); $script:focusHighlightStatusTimer.Dispose() }
    if ($script:uiControlTimer) { $script:uiControlTimer.Stop(); $script:uiControlTimer.Dispose() }
    if ($script:npcPullTimer) { $script:npcPullTimer.Stop(); $script:npcPullTimer.Dispose() }
    Clear-UiActiveFlag
    Clear-UiControlFile
    if ($script:singletonAcquired) { $script:singletonMutex.ReleaseMutex() }
    $script:singletonMutex.Dispose()
})

[void]$form.ShowDialog()
