[CmdletBinding()]
param(
    [string]$GameWin64Directory = '',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Pause-Uninstaller([string]$Message = '回车或者点击右上角 X 关闭') {
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
    foreach ($candidate in @(
        'C:\Program Files (x86)\Steam\steamapps\common\Gothic 1 Remake\G1R\Binaries\Win64',
        'C:\Program Files\Steam\steamapps\common\Gothic 1 Remake\G1R\Binaries\Win64'
    )) {
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

$sourceDir = Split-Path -Parent $PSCommandPath
$manifest = Join-Path $sourceDir 'managed_mods.txt'

Write-Host '=============================================' -ForegroundColor Red
Write-Host '     Gothic 1 Remake 瞬移+整合版 V4 一键卸载程序     ' -ForegroundColor Red
Write-Host '     作者：猴子香蕉你大爷                         ' -ForegroundColor Red
Write-Host '     B站主页：https://space.bilibili.com/258597412 ' -ForegroundColor Red
Write-Host '=============================================' -ForegroundColor Red

try {
    if (-not (Test-Path -LiteralPath $manifest)) { throw '卸载包不完整：缺少 managed_mods.txt。' }
    if (Get-Process -Name 'G1R-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw '检测到游戏正在运行，请先彻底关闭游戏后再卸载。'
    }

    $win64Dir = Get-GameWin64Directory
    $targetMods = Join-Path $win64Dir 'Mods'
    $managedMods = Get-ManagedModNames $manifest
    Write-Host '[1/4] 正在检测游戏安装路径...' -ForegroundColor Yellow
    Write-Host ('[+] 检测到游戏路径：{0}' -f $win64Dir) -ForegroundColor Green

    Write-Host '[2/4] 正在清理后台进程...' -ForegroundColor Yellow
    Stop-PackageProcesses
    Write-Host '  - [清理] TeleportCppBridge、PlayerEditCppBridge 和 UI 进程已检查。' -ForegroundColor DarkGray

    Write-Host '[3/4] 正在卸载 V4 Mod 文件夹...' -ForegroundColor Yellow
    foreach ($name in $managedMods) {
        $targetFolder = Join-Path $targetMods $name
        if (Test-Path -LiteralPath $targetFolder) {
            Remove-Item -LiteralPath $targetFolder -Recurse -Force
            Write-Host ('  - [Mod卸载] 删除文件夹：{0} ... 成功' -f $name) -ForegroundColor Green
        } else {
            Write-Host ('  - [Mod卸载] 文件夹：{0} ... 不存在，跳过' -f $name) -ForegroundColor DarkGray
        }
    }

    Write-Host '[4/4] 正在清理 V4 配置和 UE4SS 框架文件...' -ForegroundColor Yellow
    $targetModsTxt = Join-Path $targetMods 'mods.txt'
    if (Test-Path -LiteralPath $targetModsTxt) {
        $beforeLines = @(Get-Content -LiteralPath $targetModsTxt)
        $afterLines = @(Remove-ManagedEntries $beforeLines $managedMods)
        Write-Utf8NoBom -Path $targetModsTxt -Lines $afterLines
        Write-Host '  - [配置清理] 已移除 V4 Mod 加载条目，其他条目保留。' -ForegroundColor Green
    } else {
        Write-Host '  - [配置清理] mods.txt 不存在，跳过。' -ForegroundColor DarkGray
    }
    $targetProxy = Join-Path $win64Dir 'dwmapi.dll'
    if (Test-Path -LiteralPath $targetProxy) {
        if ((Get-Item -LiteralPath $targetProxy).Length -lt 70000) {
            Remove-Item -LiteralPath $targetProxy -Force
            Write-Host '  - [框架] 删除 UE4SS dwmapi.dll 代理文件 ... 成功' -ForegroundColor Green
        } else {
            Write-Host '  - [框架] 检测到非 UE4SS dwmapi.dll，保留不删除。' -ForegroundColor DarkYellow
        }
    } else {
        Write-Host '  - [框架] dwmapi.dll 不存在，跳过。' -ForegroundColor DarkGray
    }
    foreach ($file in @('UE4SS.dll','UE4SS-settings.ini')) {
        $targetFile = Join-Path $win64Dir $file
        $sourceFile = Join-Path $sourceDir $file
        if ((Test-Path -LiteralPath $targetFile) -and (Test-Path -LiteralPath $sourceFile) -and
            ((Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash)) {
            Remove-Item -LiteralPath $targetFile -Force
            Write-Host ('  - [框架] 删除 {0} ... 成功' -f $file) -ForegroundColor Green
        } else {
            Write-Host ('  - [框架] {0} 与 V4 源文件不一致或不存在，保留。' -f $file) -ForegroundColor DarkYellow
        }
    }
    $userProxyBackup = Join-Path $win64Dir 'dwmapi.dll.user-backup'
    if (Test-Path -LiteralPath $userProxyBackup) {
        Move-Item -LiteralPath $userProxyBackup -Destination $targetProxy -Force
        Write-Host '  - [恢复] 已恢复安装前的 dwmapi.dll。' -ForegroundColor Green
    }
    Get-ChildItem -LiteralPath $win64Dir -File -Filter 'TeleportMod_*.txt' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $win64Dir -File -Filter 'TeleportMod_*.pid' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'V4 一键卸载完成！未列在 V4 清单中的其他 Mod 没有被修改。' -ForegroundColor Green
} catch {
    Write-Host ('卸载失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
}

Pause-Uninstaller
