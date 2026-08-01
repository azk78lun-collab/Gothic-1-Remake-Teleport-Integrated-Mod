Gothic 1 Remake Teleport Lite — Nexus Test Build
================================================

English
-------

Teleport-only test build for Gothic 1 Remake. These instructions assume that
you have never installed Teleport Lite or the full Teleport & Integrated Mod.

IMPORTANT

- This archive contains Teleport Lite only.
- UE4SS is required and must be installed separately.
- This archive does not contain UE4SS, an installer, PowerShell, or helper EXEs.
- TeleportLiteNative.dll cannot load by itself without UE4SS.

1. Find the game directory

For the Steam version, the default directory is usually:

  ...\Steam\steamapps\common\Gothic 1 Remake

All paths below start at the "Gothic 1 Remake" directory.

2. Install UE4SS first

Install a compatible x64 UE4SS build for Gothic 1 Remake. After UE4SS is
installed, at least these paths should exist:

  Gothic 1 Remake\
  └─ G1R\
     └─ Binaries\
        └─ Win64\
           ├─ dwmapi.dll
           ├─ UE4SS.dll
           └─ Mods\
              └─ mods.txt

If Mods\mods.txt is missing, finish or verify the UE4SS installation before
installing Teleport Lite. Do not replace an existing mods.txt with a blank file.

3. Copy Teleport Lite

Open this archive and copy its complete "Gothic 1 Remake" folder into:

  ...\Steam\steamapps\common\

Choose Merge/Replace when Windows asks to merge the folder. Teleport Lite does
not overwrite game files or UE4SS files.

The completed manual installation must look like this:

  Gothic 1 Remake\
  └─ G1R\
     └─ Binaries\
        └─ Win64\
           ├─ dwmapi.dll                         [installed separately by UE4SS]
           ├─ UE4SS.dll                          [installed separately by UE4SS]
           └─ Mods\
              ├─ mods.txt
              └─ TeleportLite\
                 ├─ TeleportLiteNative.dll
                 ├─ Scripts\
                 │  └─ main.lua
                 └─ data\
                    └─ TeleportLite_default_nodes.tsv

4. Enable the mod

Open:

  Gothic 1 Remake\G1R\Binaries\Win64\Mods\mods.txt

Add this line and save the file:

  TeleportLite : 1

If "TeleportMod : 1" from the full Integrated Mod is present, disable it or
remove that line before using Lite. Do not enable both versions together.

5. Start and use

Start the game normally and wait until the game world has loaded.

- F1: Save the current position as a new custom node.
- F3: Write the node list to TeleportLite_native_diag.txt.
- F6: Open, hide, or restore the native Teleport Lite window.
- Numpad 1-9/0: Teleport to the node bound to that slot.

The first F6 press creates the native window. No external UI program is started.
After teleporting, the view may appear unchanged. Take one step to let the game
refresh and apply the new position.

If the separate Free Flight V2 mod is installed, turn F7 flight off before
teleporting. Lite rejects teleport requests while that flight status is active.

Runtime files

On first use, Lite creates these files next to the game executable:

  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_nodes.tsv
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_hotkeys.tsv
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_settings.ini
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_status.txt
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_native_diag.txt

Troubleshooting

- F6 does nothing: confirm UE4SS loads and "TeleportLite : 1" is in mods.txt.
- The window is behind the game: press F6 again or use Alt+Tab.
- The view does not change after teleporting: take one step.
- Teleport is refused: turn off Free Flight V2 and wait for the safety cooldown.
- The full Integrated Mod is installed: disable TeleportMod before using Lite.

Uninstall

1. Remove "TeleportLite : 1" from Mods\mods.txt.
2. Delete the folder:
   Gothic 1 Remake\G1R\Binaries\Win64\Mods\TeleportLite
3. Optionally delete the five TeleportLite_* runtime files listed above.


中文
----

这是《哥特王朝重制版》的纯瞬移测试版。以下说明默认你以前从未安装过
Teleport Lite，也没有安装过本项目的“瞬移与整合 Mod”。

重要说明

- 本压缩包只包含 Teleport Lite。
- 必须另外安装 UE4SS。
- 本压缩包不包含 UE4SS、安装程序、PowerShell 或辅助 EXE。
- 没有 UE4SS 时，TeleportLiteNative.dll 无法自行加载。

一、找到游戏目录

Steam 版默认目录通常是：

  ...\Steam\steamapps\common\Gothic 1 Remake

下文所有路径都从“Gothic 1 Remake”目录开始。

二、先安装 UE4SS

请先安装与《哥特王朝重制版》兼容的 x64 UE4SS。正确安装 UE4SS 后，
至少应当存在以下路径：

  Gothic 1 Remake\
  └─ G1R\
     └─ Binaries\
        └─ Win64\
           ├─ dwmapi.dll
           ├─ UE4SS.dll
           └─ Mods\
              └─ mods.txt

如果 Mods\mods.txt 不存在，请先完成或检查 UE4SS 安装。不要用空白文件
覆盖已有的 mods.txt。

三、复制 Teleport Lite

打开本压缩包，把其中完整的“Gothic 1 Remake”文件夹复制到：

  ...\Steam\steamapps\common\

Windows 询问时选择合并文件夹。Teleport Lite 不会覆盖游戏文件或 UE4SS
文件。

完整的手动安装目录必须如下：

  Gothic 1 Remake\
  └─ G1R\
     └─ Binaries\
        └─ Win64\
           ├─ dwmapi.dll                         [由 UE4SS 单独安装]
           ├─ UE4SS.dll                          [由 UE4SS 单独安装]
           └─ Mods\
              ├─ mods.txt
              └─ TeleportLite\
                 ├─ TeleportLiteNative.dll
                 ├─ Scripts\
                 │  └─ main.lua
                 └─ data\
                    └─ TeleportLite_default_nodes.tsv

四、启用模组

打开：

  Gothic 1 Remake\G1R\Binaries\Win64\Mods\mods.txt

加入下面一行并保存：

  TeleportLite : 1

如果文件中存在整合版留下的“TeleportMod : 1”，请先停用或删除该行。
Lite 与整合版不能同时启用。

五、启动与使用

正常启动游戏，等待游戏世界加载完成。

- F1：把当前位置保存为新的自定义节点。
- F3：将节点列表写入 TeleportLite_native_diag.txt。
- F6：打开、隐藏或恢复原生瞬移窗口。
- 小键盘 1-9/0：前往对应绑定节点。

第一次按 F6 时才会建立原生窗口，不会启动外部 UI 程序。瞬移后画面有时
看起来没有变化，请走一步让游戏刷新并应用新位置。

如果另外安装了 Free Flight V2，请先关闭 F7 飞行再瞬移。飞行状态开启
时，Lite 会拒绝执行瞬移。

运行时文件

第一次使用后，Lite 会在游戏可执行文件旁生成：

  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_nodes.tsv
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_hotkeys.tsv
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_settings.ini
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_status.txt
  Gothic 1 Remake\G1R\Binaries\Win64\TeleportLite_native_diag.txt

故障排查

- 按 F6 无反应：确认 UE4SS 已加载，并检查 mods.txt 中是否有
  “TeleportLite : 1”。
- 窗口被游戏遮挡：再次按 F6，或使用 Alt+Tab。
- 瞬移后画面不变：走一步让游戏刷新位置。
- 瞬移被拒绝：关闭 Free Flight V2，并等待安全冷却结束。
- 已安装完整整合版：必须先停用 TeleportMod。

卸载

1. 从 Mods\mods.txt 删除“TeleportLite : 1”。
2. 删除：
   Gothic 1 Remake\G1R\Binaries\Win64\Mods\TeleportLite
3. 如需彻底清理，可再删除上方列出的五个 TeleportLite_* 运行时文件。
