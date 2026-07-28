[CmdletBinding()]
param(
    [string]$GameWin64Directory = '',
    [switch]$DisableInstallTelemetry,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Pause-Installer([string]$Message = '回车或者点击右上角 X 关闭') {
    if ($NoPause) { return }
    Write-Host ''
    [void](Read-Host $Message)
}

function Get-GameWin64Directory {
    if ($GameWin64Directory) {
        if (Test-Path -LiteralPath $GameWin64Directory) { return (Resolve-Path -LiteralPath $GameWin64Directory).Path }
        throw ('Specified GameWin64Directory does not exist: {0}' -f $GameWin64Directory)
    }
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1297900',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1151460',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1297900',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1151460'
    )
    foreach ($registryPath in $registryPaths) {
        if (Test-Path -LiteralPath $registryPath) {
            $location = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue).InstallLocation
            $candidate = Join-Path $location 'G1R\Binaries\Win64'
            if ($location -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        }
    }

    $fallbacks = @(
        'C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Binaries\Win64',
        'C:\Program Files\Steam\steamapps\common\Gothic 1 Remake\G1R\Binaries\Win64'
    )
    foreach ($candidate in $fallbacks) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $manual = Read-Host 'Game was not found. Enter the G1R\Binaries\Win64 directory'
    if ($manual -and (Test-Path -LiteralPath $manual)) { return (Resolve-Path -LiteralPath $manual).Path }
    throw 'Gothic 1 Remake Win64 directory was not found.'
}

function Stop-PackageProcesses {
    Get-Process -Name 'TeleportCppBridge','PlayerEditCppBridge' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'TeleportModUI\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-ManagedModNames([string]$ManifestPath) {
    return @(Get-Content -LiteralPath $ManifestPath -ErrorAction Stop |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
    [IO.File]::WriteAllLines($Path, $Lines, [Text.UTF8Encoding]::new($false))
}

function Remove-ManagedEntries([string[]]$Lines, [string[]]$ManagedNames) {
    $managed = @{}
    foreach ($name in $ManagedNames) { $managed[$name] = $true }

    $seen = @{}
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $trimmed = ([string]$line).Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            $result.Add($trimmed)
            continue
        }

        $entries = [regex]::Matches($trimmed, '([A-Za-z][A-Za-z0-9_.-]*)\s*:\s*([01])')
        if ($entries.Count -eq 0) {
            $result.Add($trimmed)
            continue
        }
        foreach ($entry in $entries) {
            $name = $entry.Groups[1].Value
            if (-not $managed[$name] -and -not $seen[$name]) {
                $result.Add(('{0} : {1}' -f $name, $entry.Groups[2].Value))
                $seen[$name] = $true
            }
        }
    }
    return @($result)
}

function Assert-CopiedFile([string]$SourcePath, [string]$TargetPath) {
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        throw ('安装校验失败，目标文件不存在：{0}' -f $TargetPath)
    }
    $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash) {
        throw ('安装校验失败，文件哈希不一致：{0}' -f $TargetPath)
    }
}

$sourceDir = Split-Path -Parent $PSCommandPath
$sourceMods = Join-Path $sourceDir 'Mods'
$manifest = Join-Path $sourceDir 'managed_mods.txt'

Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '     Gothic 1 Remake 瞬移+整合版 V4 一键安装程序     ' -ForegroundColor Cyan
Write-Host '     作者：猴子香蕉你大爷                         ' -ForegroundColor Cyan
Write-Host '     B站主页：https://space.bilibili.com/258597412 ' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan

try {
    if (-not (Test-Path -LiteralPath $sourceMods) -or -not (Test-Path -LiteralPath $manifest)) {
        throw '安装包不完整：缺少 Mods 或 managed_mods.txt，请完整解压后再运行。'
    }
    if (Get-Process -Name 'G1R-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw '检测到游戏正在运行，请先彻底关闭游戏后再安装。'
    }

    $win64Dir = Get-GameWin64Directory
    $targetMods = Join-Path $win64Dir 'Mods'
    $managedMods = Get-ManagedModNames $manifest
    Write-Host '[1/5] 正在检测游戏安装路径...' -ForegroundColor Yellow
    Write-Host ('[+] 检测到游戏路径：{0}' -f $win64Dir) -ForegroundColor Green
    Write-Host ('[+] 本次安装包来源：{0}' -f $sourceDir) -ForegroundColor Green

    Write-Host '[2/5] 正在清理旧的后台进程...' -ForegroundColor Yellow
    Stop-PackageProcesses
    Write-Host '  - [清理] TeleportCppBridge、PlayerEditCppBridge 和 UI 进程已检查。' -ForegroundColor DarkGray

    Write-Host '[3/5] 正在安装 UE4SS 框架文件...' -ForegroundColor Yellow
    $targetProxy = Join-Path $win64Dir 'dwmapi.dll'
    $userProxyBackup = Join-Path $win64Dir 'dwmapi.dll.user-backup'
    if ((Test-Path -LiteralPath $targetProxy) -and ((Get-Item -LiteralPath $targetProxy).Length -ge 70000) -and -not (Test-Path -LiteralPath $userProxyBackup)) {
        Copy-Item -LiteralPath $targetProxy -Destination $userProxyBackup -Force
        Write-Host '  - [备份] 已保存安装前的非 UE4SS dwmapi.dll。' -ForegroundColor DarkYellow
    }
    foreach ($file in @('dwmapi.dll','UE4SS.dll','UE4SS-settings.ini')) {
        $sourceFile = Join-Path $sourceDir $file
        if (-not (Test-Path -LiteralPath $sourceFile)) { throw ('安装包缺少源文件：{0}' -f $file) }
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $win64Dir $file) -Force
        Write-Host ('  - [框架] 复制 {0} 到游戏目录 ... 成功' -f $file) -ForegroundColor Green
    }

    Write-Host '[4/5] 正在复制 V4 Mod 文件夹...' -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $targetMods -Force | Out-Null
    foreach ($name in $managedMods) {
        $sourceFolder = Join-Path $sourceMods $name
        if (-not (Test-Path -LiteralPath $sourceFolder)) { throw ('安装包缺少 Mod：{0}' -f $name) }
        $targetFolder = Join-Path $targetMods $name
        if (Test-Path -LiteralPath $targetFolder) {
            Remove-Item -LiteralPath $targetFolder -Recurse -Force
            Write-Host ('  - [清理] 删除旧 Mod 文件夹：{0} ... 成功' -f $name) -ForegroundColor DarkGray
        }
        Copy-Item -LiteralPath $sourceFolder -Destination $targetMods -Recurse -Force
        Write-Host ('  - [Mod复制] 复制文件夹：{0} ... 成功' -f $name) -ForegroundColor Green
    }
    foreach ($relativePath in @(
        'Mods\TeleportMod\Scripts\TeleportMod_core.lua',
        'Mods\TeleportModUIExternal\TeleportUiNative.dll',
        'Mods\TeleportModUIExternal\TeleportModUI.ps1'
    )) {
        Assert-CopiedFile (Join-Path $sourceDir $relativePath) (Join-Path $win64Dir $relativePath)
    }
    Write-Host '  - [校验] 核心、原生启动器和 UI 文件哈希一致。' -ForegroundColor Green

    Write-Host '[5/5] 正在配置 mods.txt 加载列表...' -ForegroundColor Yellow
    $targetModsTxt = Join-Path $targetMods 'mods.txt'
    $sourceModsTxt = Join-Path $sourceMods 'mods.txt'
    $current = if (Test-Path -LiteralPath $targetModsTxt) { @(Get-Content -LiteralPath $targetModsTxt) } else { @() }
    $desired = @(Get-Content -LiteralPath $sourceModsTxt -ErrorAction Stop |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $preserved = @(Remove-ManagedEntries $current $managedMods)
    $merged = @($preserved + $desired)
    Write-Utf8NoBom -Path $targetModsTxt -Lines $merged
    $written = @(Get-Content -LiteralPath $targetModsTxt)
    foreach ($requiredLine in $desired) {
        if ($written -notcontains $requiredLine) {
            throw ('mods.txt 校验失败，缺少加载条目：{0}' -f $requiredLine)
        }
    }
    Write-Host '  - [配置] 已合并 V4 稳定版 mods.txt 加载列表 ... 成功' -ForegroundColor Green

    if (-not $DisableInstallTelemetry -and $env:G1R_MOD_DISABLE_TELEMETRY -ne '1') {
        Write-Host '  - [统计] 正在发送匿名安装事件（仅随机编号与版本，不含用户名、路径、硬件或存档）...' -ForegroundColor DarkGray
        try {
            $communityClient = Join-Path $targetMods 'TeleportModUIExternal\CommunityClient.ps1'
            if (Test-Path -LiteralPath $communityClient) {
                & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                    -File $communityClient -Action Install -Version '4.1.0' -Quiet | Out-Null
                Write-Host '  - [统计] 匿名安装统计已处理；网络不可用不会影响安装。' -ForegroundColor DarkGray
            }
        } catch {
            Write-Host '  - [统计] 服务器暂不可用，已跳过；安装不受影响。' -ForegroundColor DarkGray
        }
    } else {
        Write-Host '  - [统计] 已按本机设置停用匿名安装统计。' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'V4 一键安装完成！进入游戏后按 F6 打开管理界面。' -ForegroundColor Green
} catch {
    Write-Host ('安装失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
}

Pause-Installer
