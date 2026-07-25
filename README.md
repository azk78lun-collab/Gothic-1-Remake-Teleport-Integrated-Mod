# Gothic 1 Remake Teleport & Integrated Mod

## 哥特王朝重制版：瞬移与整合 Mod

<p align="center">
  <a href="#english"><kbd>English</kbd></a>
  <a href="#中文"><kbd>中文</kbd></a>
</p>

---

## English

A Windows utility mod for **Gothic 1 Remake**, built on UE4SS. It combines teleportation, free flight, item and inventory tools, nearby-character scanning and pulling, unlocking, highlighting, and an English/Simplified Chinese UI.

This is an unofficial community project and is not affiliated with the game developer or publisher.

### Features

- Teleport nodes, manual coordinates, saved-node import/export, and teleporting to scanned characters.
- Free Flight with camera-relative movement, a continuous speed slider, and `3x` default speed.
- Nearby-character scanning with active/downed/dead filters, history, multi-selection, and pulling loaded characters to the player.
- Item spawning plus direct add-to-inventory and remove-from-inventory actions using the selected quantity.
- Chest/door unlocking and nearby-item highlighting.
- English and Simplified Chinese UI.

### Download And Installation

1. Download `Gothic-1-Remake-Teleport-Integrated-Mod-V4.zip` from the [Releases](https://github.com/azk78lun-collab/Gothic-1-Remake-Teleport-Integrated-Mod/releases) page.
2. Extract the ZIP to a normal folder.
3. Fully close the game.
4. Double-click `双击一键安装.cmd`.
5. Start the game and use the hotkeys below.

To uninstall, fully close the game and run `双击一键卸载.cmd`.

### Important First-Run Notes

**The first UI launch may take about 10 seconds. Please wait before pressing F6 again.**

**After teleporting, the view may appear unchanged. Take one step to let the game refresh the position.**

### Hotkeys

| Key | Action |
|---|---|
| `F6` | Open the management UI; when already open, toggle foreground/minimized state. |
| `F7` | Toggle Free Flight. |
| `F1` | Save the current position as a teleport node. |
| `V` | Toggle nearby-item highlighting. |

### Usage Notes

- Free Flight uses `W/S` along the camera direction and `A/D` for lateral movement. Ordinary interactions automatically turn it off; re-enable it manually after the interaction or conversation.
- NPC pulling works only for characters currently loaded by the game. Turn Free Flight off before pulling.
- A pulled living NPC may continue following its original AI schedule.
- Item add/remove actions use the quantity shown at the top of the Item Spawn page.
- The first unlock should work directly from the UI and should not require `Ctrl+R`.

### Build From Source

Requirements:

- Windows PowerShell 5.1 or PowerShell 7
- Visual Studio 2022 or later Build Tools with the x64 C++ toolchain
- A compatible UE4SS runtime directory for release packaging

Build all three native components:

```powershell
.\scripts\Build-AllNative.ps1
```

Build a clean V4 package after native compilation:

```powershell
.\scripts\Build-Release.ps1 -Ue4ssRuntimeRoot "D:\Path\To\UE4SS"
```

`-Ue4ssRuntimeRoot` must contain `UE4SS.dll` and `dwmapi.dll`. The build script takes UE4SS's bundled Lua components from `third_party/UE4SS`, overlays this project's source, verifies the package, and creates the ZIP plus SHA-256 file under `dist`.

### Source Layout

- `src/lua`: game-side Lua mods
- `src/powershell`: bilingual management UI and bridge scripts
- `src/native`: three Windows native helpers
- `src/data`: item and NPC name data
- `src/assets`: UI images and icons
- `packaging`: installer templates
- `third_party/UE4SS`: unmodified MIT-licensed UE4SS Lua components

### Known Limitations

- The mod depends on game internals and may require updates after a game or UE4SS update.
- Scanning and pulling cannot force the game to load an NPC that is not currently present in memory.
- Do not install, uninstall, or replace files while the game is running.

### License

Original source in this repository is released under **GPL-3.0**. UE4SS and its bundled components retain their own **MIT License**. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Support The Developer

USDT (TRON) only:

```text
TWWGexPoyv46BUAxjuXkwAVx8JBPRgTtFJ
```

![USDT TRON support QR code](src/assets/support_usdt_tron.png)

---

## 中文

这是一个基于 UE4SS 的 **《哥特王朝重制版》Windows 工具 Mod**。它整合了瞬移、自由飞行、物品与背包工具、附近人物扫描与拉取、开锁、高亮，以及英文/简体中文界面。

本项目是非官方社区作品，与游戏开发商或发行商没有隶属关系。

### 功能

- 瞬移节点、手动坐标、节点导入导出，以及瞬移到扫描到的人物。
- 自由飞行支持跟随镜头方向移动、连续速度横条调节，默认速度为 `3x`。
- 附近人物扫描支持存活/倒地/死亡筛选、历史记录、多选，以及把已加载人物拉到玩家身边。
- 物品生成，并可按选定数量直接添加到背包或从背包删除。
- 箱子和门的一键开锁，以及附近物品高亮。
- 英文和简体中文界面。

### 下载与安装

1. 从 [Releases](https://github.com/azk78lun-collab/Gothic-1-Remake-Teleport-Integrated-Mod/releases) 页面下载 `Gothic-1-Remake-Teleport-Integrated-Mod-V4.zip`。
2. 将 ZIP 完整解压到普通文件夹。
3. 完全关闭游戏。
4. 双击 `双击一键安装.cmd`。
5. 启动游戏，并使用下方快捷键。

需要卸载时，请完全关闭游戏并运行 `双击一键卸载.cmd`。

### 首次运行重要说明

**首次启动 UI 可能需要约 10 秒，请耐心等待，不要连续按 F6。**

**瞬移后画面有时看起来没有变化，请走一步让游戏刷新并应用新位置。**

### 快捷键

| 按键 | 操作 |
|---|---|
| `F6` | 打开管理界面；界面已打开时切换前台/最小化状态。 |
| `F7` | 开启或关闭自由飞行。 |
| `F1` | 将当前位置保存为瞬移节点。 |
| `V` | 开启或关闭附近物品高亮。 |

### 使用说明

- 自由飞行使用 `W/S` 沿镜头方向移动，`A/D` 左右平移。普通互动会自动关闭飞行；互动或对话结束后请手动重新开启。
- 人物拉取只处理游戏当前已加载的人物，执行前请关闭自由飞行。
- 被拉来的存活 NPC 可能继续执行原有 AI 行程。
- 物品添加和删除操作遵循物品生成页顶部的数量输入框。
- 首次开锁应可直接从 UI 启用，不应再需要按 `Ctrl+R`。

### 从源码构建

需要：

- Windows PowerShell 5.1 或 PowerShell 7
- Visual Studio 2022 或更新版本 Build Tools，并安装 x64 C++ 工具链
- 用于打包的兼容 UE4SS 运行时目录

构建三个原生组件：

```powershell
.\scripts\Build-AllNative.ps1
```

完成原生编译后构建干净的 V4 安装包：

```powershell
.\scripts\Build-Release.ps1 -Ue4ssRuntimeRoot "D:\Path\To\UE4SS"
```

`-Ue4ssRuntimeRoot` 必须包含 `UE4SS.dll` 和 `dwmapi.dll`。构建脚本会从 `third_party/UE4SS` 取用 UE4SS 自带 Lua 组件，再覆盖本项目源码、校验安装包，并在 `dist` 中生成 ZIP 和 SHA-256 文件。

### 源码结构

- `src/lua`：游戏侧 Lua Mod
- `src/powershell`：双语管理界面与桥接脚本
- `src/native`：三个 Windows 原生辅助模块
- `src/data`：物品与人物名称数据
- `src/assets`：UI 图片和图标
- `packaging`：安装包模板
- `third_party/UE4SS`：未修改的 MIT 许可 UE4SS Lua 组件

### 已知限制

- 本 Mod 依赖游戏内部结构，游戏或 UE4SS 更新后可能需要适配。
- 扫描和拉取无法强制加载当前不在内存中的 NPC。
- 游戏运行时不要安装、卸载或替换文件。

### 许可证

本仓库原创源码采用 **GPL-3.0** 发布。UE4SS 及其自带组件继续采用其自身的 **MIT License**，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

### 支持开发者

仅支持 USDT（TRON）：

```text
TWWGexPoyv46BUAxjuXkwAVx8JBPRgTtFJ
```

![USDT TRON 打赏二维码](src/assets/support_usdt_tron.png)
