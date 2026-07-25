# Gothic 1 Remake Teleport & Integrated Mod

## 哥特王朝重制版：瞬移与整合 Mod

A Windows utility mod for **Gothic 1 Remake**, built on UE4SS. It combines teleportation, free flight, item and inventory tools, nearby-character scanning and pulling, unlocking, highlighting, and a bilingual English/Chinese UI.

基于 UE4SS 的 Windows 版《哥特王朝重制版》综合工具 Mod，整合瞬移、自由飞行、物品与背包操作、附近人物扫描与拉取、开锁、高亮以及中英文双语界面。

> This is an unofficial community project and is not affiliated with the game developer or publisher.
>
> 本项目是非官方社区作品，与游戏开发商及发行商无隶属关系。

## Features / 功能

- Teleport nodes, manual coordinates, saved-node import/export, and teleporting to scanned characters.
  / 瞬移节点、手动坐标、节点导入导出，以及瞬移到扫描到的人物。
- Free Flight with camera-relative movement, an adjustable `0.25x–10.00x` speed slider, and `3x` default speed.
  / 跟随镜头方向的自由飞行，支持 `0.25x–10.00x` 横条调速，默认 `3x`。
- Nearby-character scanning with active/downed/dead state filters, history, multi-selection, and pulling loaded characters to the player.
  / 附近人物扫描，支持存活/倒地/死亡筛选、历史记录、多选，以及把已加载人物拉到玩家身边。
- Item spawning plus direct add-to-inventory and remove-from-inventory actions using the selected quantity.
  / 物品生成，并可按照所选数量直接添加到背包或从背包删除。
- Chest/door unlocking and nearby-item highlighting.
  / 箱子、门的一键开锁及附近物品高亮。
- English and Simplified Chinese UI.
  / 英文与简体中文界面。

## Download & Installation / 下载与安装

**English**

1. Download `Gothic-1-Remake-Teleport-Integrated-Mod-V4.zip` from the [Releases](https://github.com/azk78lun-collab/Gothic-1-Remake-Teleport-Integrated-Mod/releases) page.
2. Extract the ZIP to a normal folder.
3. Fully close the game.
4. Double-click `双击一键安装.cmd`.
5. Start the game and use the hotkeys below.

**中文**

1. 从 [Releases](https://github.com/azk78lun-collab/Gothic-1-Remake-Teleport-Integrated-Mod/releases) 页面下载 `Gothic-1-Remake-Teleport-Integrated-Mod-V4.zip`。
2. 将 ZIP 完整解压到普通文件夹。
3. 完全关闭游戏。
4. 双击 `双击一键安装.cmd`。
5. 启动游戏并使用下方快捷键。

To uninstall, fully close the game and run `双击一键卸载.cmd`.

需要卸载时，请完全关闭游戏并运行 `双击一键卸载.cmd`。

## Important First-Run Notes / 首次运行重要说明

**The first UI launch may take about 10 seconds. Please wait before pressing F6 again.**

**首次启动 UI 可能需要约 10 秒，请耐心等待，不要连续按 F6。**

**After teleporting, the view may appear unchanged. Take one step to let the game refresh the position.**

**瞬移后画面有时看起来没有变化，请走一步让游戏刷新并应用新位置。**

## Hotkeys / 快捷键

| Key | English | 中文 |
|---|---|---|
| `F6` | Open the management UI; when already open, toggle foreground/minimized state | 打开管理界面；界面已打开时切换前台与最小化 |
| `F7` | Toggle Free Flight | 开启或关闭自由飞行 |
| `F1` | Save the current position as a teleport node | 将当前位置保存为瞬移节点 |
| `V` | Toggle nearby-item highlighting | 开启或关闭附近物品高亮 |

## Usage Notes / 使用说明

- Free Flight uses `W/S` along the camera direction and `A/D` for lateral movement. Ordinary interactions automatically turn it off; re-enable it manually after the interaction or conversation.
  / 自由飞行使用 `W/S` 沿镜头方向移动，`A/D` 左右平移。普通互动会自动关闭飞行；互动或对话结束后请手动重新开启。
- NPC pulling works only for characters currently loaded by the game. Turn Free Flight off before pulling.
  / 人物拉取只处理游戏当前已加载的人物，执行前必须关闭自由飞行。
- A pulled living NPC may continue following its original AI schedule.
  / 被拉来的存活 NPC 可能继续执行原有 AI 行程。
- Item add/remove actions use the quantity shown at the top of the Item Spawn page.
  / 物品添加和删除操作遵循物品生成页顶部的数量输入值。

## Build from Source / 从源码构建

Requirements / 需要：

- Windows PowerShell 5.1 or PowerShell 7
- Visual Studio 2022 or later Build Tools with the x64 C++ toolchain
- A compatible UE4SS runtime directory for release packaging

Build all three native components:

构建三个原生组件：

```powershell
.\scripts\Build-AllNative.ps1
```

Build a clean V4 package after native compilation:

完成原生编译后构建干净的 V4 安装包：

```powershell
.\scripts\Build-Release.ps1 -Ue4ssRuntimeRoot "D:\Path\To\UE4SS"
```

`-Ue4ssRuntimeRoot` must contain `UE4SS.dll` and `dwmapi.dll`. The build script takes UE4SS's bundled Lua components from `third_party/UE4SS`, overlays this project's source, verifies the package, and creates the ZIP plus SHA-256 file under `dist`.

`-Ue4ssRuntimeRoot` 必须包含 `UE4SS.dll` 和 `dwmapi.dll`。构建脚本会从 `third_party/UE4SS` 取用 UE4SS 自带 Lua 组件，再覆盖本项目源码、校验安装包，并在 `dist` 中生成 ZIP 和 SHA-256 文件。

## Source Layout / 源码结构

- `src/lua` — game-side Lua mods / 游戏侧 Lua Mod
- `src/powershell` — bilingual management UI and bridge / 双语管理界面与桥接脚本
- `src/native` — three Windows native helpers / 三个 Windows 原生辅助模块
- `src/data` — item and NPC name data / 物品与人物名称数据
- `src/assets` — UI images and icons / UI 图片与图标
- `packaging` — installer templates / 安装包模板
- `third_party/UE4SS` — unmodified MIT-licensed UE4SS Lua components / 未修改的 MIT 许可 UE4SS Lua 组件

## Known Limitations / 已知限制

- The mod depends on game internals and may require updates after a game or UE4SS update.
  / 本 Mod 依赖游戏内部结构，游戏或 UE4SS 更新后可能需要适配。
- Scanning and pulling cannot force the game to load an NPC that is not currently present in memory.
  / 扫描和拉取无法强制加载当前不在内存中的 NPC。
- Do not install, uninstall, or replace files while the game is running.
  / 游戏运行时不要安装、卸载或替换文件。

## License / 许可证

Original source in this repository is released under **GPL-3.0**. UE4SS and its bundled components retain their own **MIT License**. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

本仓库原创源码采用 **GPL-3.0** 发布。UE4SS 及其自带组件继续采用其自身的 **MIT License**，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## Support the Developer / 支持开发者

USDT (TRON) only / 仅支持 USDT（TRON）：

```text
TWWGexPoyv46BUAxjuXkwAVx8JBPRgTtFJ
```

![USDT TRON support QR code](src/assets/support_usdt_tron.png)
