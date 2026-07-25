Focus Nearby Pickups - Extended Item Highlight Range (Lua version)
==================================================================

REQUIRES RE-UE4SS (a UE 5.4-compatible build). Install that first.
This Lua version is NOT tied to a specific UE4SS build, so it works across
UE4SS versions - no compiler needed.

INSTALL
-------
1. If you previously installed the C++ (dlls\main.dll) version of this mod,
   DELETE that old "FocusNearbyPickups" folder first to avoid a conflict.

2. Copy the "FocusNearbyPickups" folder (the one containing this file) into:
   <Gothic 1 Remake>\G1R\Binaries\Win64\ue4ss\Mods\

   The result must look exactly like:
   ...\ue4ss\Mods\FocusNearbyPickups\Scripts\main.lua
   ...\ue4ss\Mods\FocusNearbyPickups\enabled.txt

3. In-game, turn ON the "Highlight Items" option in the settings.
4. Press F6 in-game to toggle the boost on/off.

The included "enabled.txt" makes UE4SS load the mod automatically - you do NOT
need to edit mods.txt.

TUNING (optional)
-----------------
Open Scripts\main.lua and edit the CONFIG block near the top:
  MAX_RADIUS_ON          - how far items light up (default 2500)
  OUTLINE_ALPHA          - outline opacity, 1.0 = solid
  THICKNESS_MULTIPLIER   - outline width vs default (default 2.0)
  CHEST_REQUIRE_LINE_OF_SIGHT - hide chest outlines through walls (default true)
  AUTO_LOOT_ENABLED      - auto-pick close loose world items (default false)
No rebuild required - just save and relaunch the game.

KEYBIND MODES
-------------
Default keyboard toggle:
  local KEYBIND_MODE = "toggle"
  local HIGHLIGHT_KEY = Key.F6

Keyboard hold:
  local KEYBIND_MODE = "hold"
  local HIGHLIGHT_HOLD_KEY_NAMES = { "F6" }

Controller L2/LT hold:
  local KEYBIND_MODE = "hold"
  local HIGHLIGHT_HOLD_KEY_NAMES = { "Gamepad_LeftTrigger", "Gamepad_LeftTriggerAxis" }

The controller hold mode polls Unreal's native input state, so it does not require
Steam Input to translate the controller button into a keyboard key.

AUTO-LOOT
---------
Disabled by default. To enable it:
  local AUTO_LOOT_ENABLED = true

Auto-loot only tries loose world pickups. It does not loot corpses or chests.
Useful extra knobs:
  local AUTO_LOOT_RADIUS = 180.0
  local AUTO_LOOT_REQUIRE_IN_VIEW = true

UNINSTALL
---------
Delete the "FocusNearbyPickups" folder from ...\ue4ss\Mods\ .
