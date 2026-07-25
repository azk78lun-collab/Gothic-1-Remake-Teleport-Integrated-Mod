-- TeleportMod hot-reloadable core for Gothic 1 Remake v5.28-force-npc-pull
-- F1=Save | F3=List | F6=UI | F7=Free Flight | Numpad1-9/0=Bound TP
-- Core only: no keybind/timer/console registration, loaded by main.lua shell
-- v5.9: Numpad teleport now routes through CppBridge when available.
--       Lua Root.RelativeLocation/set doesn't trigger movement system update,
--       so character snaps back. CppBridge writes directly to game memory.

local MOD_VERSION = "5.28-force-npc-pull"
local TeleportSpots = {}
local NumpadBindings = {}
local SpotAutoIndex = 0
local ConfigFileName = "TeleportMod_spots.ini"
local ActionFileName = "TeleportMod_actions.txt"
local HotkeyFileName = "TeleportMod_hotkeys.ini"
local UiActiveFlagFileName = "TeleportMod_ui_active.flag"
local UiControlFileName = "TeleportMod_ui_control.txt"
local DiagFileName = "TeleportMod_diag.txt"
local StatusFileName = "TeleportMod_status.txt"
local NpcScanFileName = "TeleportMod_npc_scan.tsv"
local NpcScanStateFileName = "TeleportMod_npc_scan_state.txt"
local NpcScanHistoryFileName = "TeleportMod_npc_scan_history.tsv"
local NpcPullRequestFileName = "TeleportMod_npc_pull_request.tsv"
local NpcPullStatusFileName = "TeleportMod_npc_pull_status.txt"
local NpcPullResultFileName = "TeleportMod_npc_pull_result.tsv"
local NpcNameReferenceFileName = "Mods\\TeleportModUIExternal\\TeleportMod_npc_names_zh.tsv"
local CppActionsFileName = "TeleportMod_cpp_actions.txt"
local CppBridgeExePath = "Mods\\TeleportModUIExternal\\TeleportCppBridge.exe"
local UiNativeDllPath = "Mods\\TeleportModUIExternal\\TeleportUiNative.dll"
local UiNativeStatusFileName = "Mods\\TeleportModUIExternal\\TeleportUiNative_status.txt"
local UiActiveFlagMaxAge = 30  -- seconds; stale flag auto-cleanup threshold
local ActionPollHandle = nil
local UiLaunchGateUntil = 0    -- suppress key-repeat launches while the UI is starting
local UiToggleGateUntil = 0    -- suppress duplicate F6 callbacks within one second
local NativeUiLauncher = nil
local NativeUiLauncherError = nil
local NativeBridgeLauncher = nil
local NativeBridgeLauncherError = nil
local NativeBridgeLaunchRequested = false
local LastHookRetry = 0
local Unpack = table.unpack or unpack

local NumKeyNames = {
    [1] = "NUM_ONE",   [2] = "NUM_TWO",   [3] = "NUM_THREE",
    [4] = "NUM_FOUR",  [5] = "NUM_FIVE",  [6] = "NUM_SIX",
    [7] = "NUM_SEVEN", [8] = "NUM_EIGHT", [9] = "NUM_NINE",
}

local function Trim(value)
    value = value or ""
    return value:match("^%s*(.-)%s*$")
end

local function NormalizeName(value)
    value = Trim(value)
    value = value:gsub("[|\r\n]", "_")
    return value
end

local function NowText()
    local ok, value = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    if ok and value then return value end
    return "unknown-time"
end

local function Diag(fmt, ...)
    local args = { ... }
    local okFmt, msg = pcall(function() return string.format(fmt, Unpack(args)) end)
    if not okFmt then msg = tostring(fmt) end
    local line = string.format("[%s] %s", NowText(), tostring(msg))
    print("[TP-DIAG] " .. tostring(msg) .. "\n")
    pcall(function()
        local file = io.open(DiagFileName, "a")
        if file then
            file:write(line .. "\n")
            file:close()
        end
    end)
end

local function ResetDiag()
    pcall(function()
        local file = io.open(DiagFileName, "w")
        if file then
            file:write(string.format("[%s] TeleportMod v%s diagnostics started\n", NowText(), MOD_VERSION))
            file:close()
        end
    end)
end

local function IsValidObject(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function ObjectFullName(obj)
    if not IsValidObject(obj) then return "invalid" end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and value then return tostring(value) end
    return "full-name-unavailable"
end

local function VectorText(v)
    if not v then return "nil" end
    return string.format("%.1f %.1f %.1f", tonumber(v.X or 0) or 0, tonumber(v.Y or 0) or 0, tonumber(v.Z or 0) or 0)
end

local function DistSq(a, b)
    if not a or not b then return nil end
    local dx = (tonumber(a.X) or 0) - (tonumber(b.X) or 0)
    local dy = (tonumber(a.Y) or 0) - (tonumber(b.Y) or 0)
    local dz = (tonumber(a.Z) or 0) - (tonumber(b.Z) or 0)
    return dx * dx + dy * dy + dz * dz
end

-- Check if UI active flag is stale (older than N seconds)
local function IsUiActiveFlagStale()
    local file = io.open(UiActiveFlagFileName, "r")
    if not file then return false end  -- no flag = not active

    local content = file:read("*a")
    file:close()

    -- Flag format: "PID=1234\nTIME=1718234567"
    local timestamp = tonumber(content:match("TIME=(%d+)"))
    if timestamp then
        local now = os.time()
        if (now - timestamp) > UiActiveFlagMaxAge then
            print("[TP] UI active flag is stale (age=" .. (now - timestamp) .. "s), clearing.\n")
            os.remove(UiActiveFlagFileName)
            return true
        end
    end

    -- Also check if PID is still alive
    local pid = tonumber(content:match("PID=(%d+)"))
    if pid then
        -- On Windows, try to check process existence
        -- os.execute returns nil/exit code; we just rely on timestamp
    end

    return false
end

local function ClearUiActiveFlag()
    os.remove(UiActiveFlagFileName)
end

local function ClearUiControlFile()
    os.remove(UiControlFileName)
end

local function IsTeleportUiActive()
    local file = io.open(UiActiveFlagFileName, "r")
    if not file then
        return false
    end
    local content = file:read("*a") or ""
    file:close()  -- MUST close to avoid leaking file handle (blocks OS delete)

    -- Keep F6 lightweight: do not shell out to tasklist from the game thread.
    -- Normal closes send UI_CLOSED, and crashes are handled by heartbeat staleness.
    if IsUiActiveFlagStale() then
        return false
    end
    return true
end

local function SendUiControl(action)
    action = tostring(action or "")
    if action == "" then return false end
    local ok, err = pcall(function()
        local file = io.open(UiControlFileName, "w")
        if file then
            file:write("ACTION=" .. action .. "\n")
            file:write("TIME=" .. tostring(os.time()) .. "\n")
            file:close()
        else
            error("open-failed")
        end
    end)
    if not ok then
        Diag("ui control failed action=%s err=%s", action, tostring(err))
        return false
    end
    Diag("ui control sent action=%s", action)
    return true
end

local function GetNativeUiLauncher()
    if NativeUiLauncher then return NativeUiLauncher end
    if NativeUiLauncherError then return nil, NativeUiLauncherError end
    if not package or type(package.loadlib) ~= "function" then
        NativeUiLauncherError = "package.loadlib unavailable"
        return nil, NativeUiLauncherError
    end

    local loader, err = package.loadlib(UiNativeDllPath, "TeleportLaunchUI")
    if type(loader) ~= "function" then
        NativeUiLauncherError = tostring(err or "loadlib returned no function")
        return nil, NativeUiLauncherError
    end
    NativeUiLauncher = loader
    return NativeUiLauncher, nil
end

local function GetNativeBridgeLauncher()
    if NativeBridgeLauncher then return NativeBridgeLauncher end
    if NativeBridgeLauncherError then return nil, NativeBridgeLauncherError end
    if not package or type(package.loadlib) ~= "function" then
        NativeBridgeLauncherError = "package.loadlib unavailable"
        return nil, NativeBridgeLauncherError
    end

    local loader, err = package.loadlib(UiNativeDllPath, "TeleportEnsureBridge")
    if type(loader) ~= "function" then
        NativeBridgeLauncherError = tostring(err or "loadlib returned no function")
        return nil, NativeBridgeLauncherError
    end
    NativeBridgeLauncher = loader
    return NativeBridgeLauncher, nil
end

local function EnsureCppBridgeStarted(reason)
    if NativeBridgeLaunchRequested then return true end

    local bridge = io.open(CppBridgeExePath, "rb")
    if not bridge then
        Diag("C++ bridge launch failed reason=%s error=missing executable", tostring(reason))
        return false, "C++ bridge missing: " .. CppBridgeExePath
    end
    bridge:close()

    local launcher, loadErr = GetNativeBridgeLauncher()
    if not launcher then
        Diag("C++ bridge launch failed reason=%s error=%s", tostring(reason), tostring(loadErr))
        return false, tostring(loadErr)
    end
    local ok, launchErr = pcall(launcher)
    if not ok then
        Diag("C++ bridge launch failed reason=%s error=%s", tostring(reason), tostring(launchErr))
        return false, tostring(launchErr)
    end

    local nativeState = ""
    local statusFile = io.open(UiNativeStatusFileName, "r")
    if statusFile then
        nativeState = tostring(statusFile:read("*a") or ""):match("STATE=([^\r\n]+)") or ""
        statusFile:close()
    end
    if nativeState:find("^BRIDGE_FAILED") then
        Diag("C++ bridge launch failed reason=%s nativeState=%s", tostring(reason), nativeState)
        return false, nativeState
    end

    NativeBridgeLaunchRequested = true
    Diag("C++ bridge launch dispatched reason=%s route=native-dll nativeState=%s",
        tostring(reason), tostring(nativeState))
    return true, nil
end

local function LaunchTeleportUI()
    local now = os.time()

    -- Check if UI is already active
    if IsTeleportUiActive() then
        if now < UiToggleGateUntil then
            Diag("ui toggle dropped reason=key-repeat")
            return
        end
        UiToggleGateUntil = now + 1
        SendUiControl("TOGGLE")
        print("[TP] UI already active, toggle request sent.\n")
        return
    end

    -- The first F6 can emit more than one key callback before the new process has
    -- written its active flag. Treat those callbacks as one launch request.
    if now < UiLaunchGateUntil then
        Diag("UI launch dropped reason=startup-key-repeat")
        return
    end
    UiLaunchGateUntil = now + 4

    local launcher, loadErr = GetNativeUiLauncher()
    if launcher then
        local ok, launchErr = pcall(launcher)
        if ok then
            Diag("UI launch dispatched route=native-dll")
            print("[TP] UI launch dispatched (native hidden process).\n")
            return
        end
        loadErr = tostring(launchErr)
    end

    -- os.execute routes through cmd.exe on Windows and can flash a console. The
    -- native launcher is part of this distribution, so fail visibly in the log
    -- instead of falling back to a black-window shell launch.
    UiLaunchGateUntil = now + 1
    Diag("UI native launch unavailable err=%s; shell fallback disabled", tostring(loadErr))
    WriteStatus("FAILED", "UI native launcher unavailable", nil)
    print("[TP] UI launch failed; native launcher unavailable.\n")
end

local function UpdateAutoIndexFromName(name)
    local idx = tonumber(name:match("^Spot_(%d+)$"))
    if idx and idx > SpotAutoIndex then
        SpotAutoIndex = idx
    end
end

local function RebuildAutoIndex()
    SpotAutoIndex = 0
    for _, s in ipairs(TeleportSpots) do
        UpdateAutoIndexFromName(s.Name)
    end
end

local function LoadSpots()
    TeleportSpots = {}
    SpotAutoIndex = 0

    local file = io.open(ConfigFileName, "r")
    if not file then return end

    for line in file:lines() do
        local name, x, y, z = line:match("^(.-)|(-?[%d%.]+)|(-?[%d%.]+)|(-?[%d%.]+)$")
        if name then
            local nx = tonumber(x)
            local ny = tonumber(y)
            local nz = tonumber(z)
            if nx and ny and nz and nx == nx and ny == ny and nz == nz then
                table.insert(TeleportSpots, {
                    Name = name,
                    X = nx,
                    Y = ny,
                    Z = nz,
                })
                UpdateAutoIndexFromName(name)
            end
        end
    end
    file:close()
end

local function SaveSpots()
    local tmpName = ConfigFileName .. ".tmp"
    local file = io.open(tmpName, "w")
    if not file then
        print("[TP] SaveSpots: failed to open temp file.\n")
        return false
    end
    for _, s in ipairs(TeleportSpots) do
        file:write(string.format("%s|%.0f|%.0f|%.0f\n", s.Name, s.X, s.Y, s.Z))
    end
    file:close()
    os.remove(ConfigFileName)
    local ok = os.rename(tmpName, ConfigFileName)
    if not ok then
        print("[TP] SaveSpots: failed to rename temp file.\n")
        return false
    end
    return true
end

local function LoadNumpadBindings()
    NumpadBindings = {}
    local file = io.open(HotkeyFileName, "r")
    if not file then return end
    for line in file:lines() do
        local key, name, x, y, z = line:match("^(%d+)|(.-)|(-?[%d%.]+)|(-?[%d%.]+)|(-?[%d%.]+)$")
        key = tonumber(key)
        if key and name then
            local nx = tonumber(x)
            local ny = tonumber(y)
            local nz = tonumber(z)
            if nx and ny and nz then
                NumpadBindings[key] = { Name = name, X = nx, Y = ny, Z = nz }
            end
        end
    end
    file:close()
end

-- GetPlayerPawn: tries multiple strategies with logging
local GetPlayerPawnDiagLogged = false
local function GetPlayerController()
    local ok, pc = pcall(function() return FindFirstOf("PlayerController") end)
    if ok and IsValidObject(pc) then return pc end
    return nil
end

local function GetPlayerPawn()
    local pc = GetPlayerController()
    if IsValidObject(pc) then
        local ok1, ap = pcall(function() return pc.AcknowledgedPawn end)
        if ok1 and IsValidObject(ap) then
            if not GetPlayerPawnDiagLogged then
                print("[TP-DIAG] Pawn via PC.AcknowledgedPawn\n")
                GetPlayerPawnDiagLogged = true
            end
            return ap, "PC.AcknowledgedPawn", pc
        end

        local ok2, ps = pcall(function() return pc.PlayerState end)
        if ok2 and IsValidObject(ps) then
            local ok3, pp = pcall(function() return ps.PawnPrivate end)
            if ok3 and IsValidObject(pp) then
                if not GetPlayerPawnDiagLogged then
                    print("[TP-DIAG] Pawn via PC.PlayerState.PawnPrivate\n")
                    GetPlayerPawnDiagLogged = true
                end
                return pp, "PC.PlayerState.PawnPrivate", pc
            end
        end

        local ok4, pawn = pcall(function() return pc.Pawn end)
        if ok4 and IsValidObject(pawn) then
            if not GetPlayerPawnDiagLogged then
                print("[TP-DIAG] Pawn via PC.Pawn\n")
                GetPlayerPawnDiagLogged = true
            end
            return pawn, "PC.Pawn", pc
        end
    end

    if not GetPlayerPawnDiagLogged then
        local diagPawn = nil
        local diagChar = nil
        pcall(function() diagPawn = FindFirstOf("Pawn") end)
        pcall(function() diagChar = FindFirstOf("Character") end)
        print("[TP-DIAG] Controlled pawn not found; diagnostic Pawn=" ..
            ObjectFullName(diagPawn) .. " Character=" .. ObjectFullName(diagChar) .. "\n")
        GetPlayerPawnDiagLogged = true
    end
    return nil, "cannot-confirm-player-pawn", pc
end

local function FindSpotIndexByName(name)
    name = NormalizeName(name)
    if name == "" then return nil end
    for i, s in ipairs(TeleportSpots) do
        if s.Name == name then return i end
    end
    return nil
end

-- Safe location getter: reads RootComponent.RelativeLocation directly
local GetActorLocationDiagLogged = false
local function GetActorLocation(actor)
    if not GetActorLocationDiagLogged then
        local okName, fullName = pcall(function() return actor:GetFullName() end)
        print("[TP-DIAG] Actor: " .. (okName and tostring(fullName) or "GetFullName-failed") .. "\n")
        GetActorLocationDiagLogged = true
    end

    -- Prefer engine-facing world transform, then fall back to callable getters.
    local ok, root = pcall(function() return actor.RootComponent end)
    if ok and root and root:IsValid() then
        local okCtw, ctw = pcall(function() return root.ComponentToWorld end)
        if okCtw and ctw and ctw.Translation then
            local t = ctw.Translation
            if type(t.X) == "number" and type(t.Y) == "number" and type(t.Z) == "number" then
                return { X = t.X, Y = t.Y, Z = t.Z }
            end
        end
    end

    -- Fallback: K2_GetActorLocation
    local ok3, result3 = pcall(function() return actor:K2_GetActorLocation() end)
    if ok3 and result3 then
        return result3
    end

    -- Fallback: GetActorLocation (native C++)
    local ok4, result4 = pcall(function() return actor:GetActorLocation() end)
    if ok4 and result4 then
        return result4
    end

    if ok and root and root:IsValid() then
        local ok2, loc = pcall(function() return root.RelativeLocation end)
        if ok2 and loc then
            if type(loc.X) == "number" and type(loc.Y) == "number" and type(loc.Z) == "number" then
                return { X = loc.X, Y = loc.Y, Z = loc.Z }
            end
        end
    end

    return nil
end

local function RoundCoord(value)
    value = tonumber(value) or 0
    if value >= 0 then return math.floor(value + 0.5) end
    return math.ceil(value - 0.5)
end

local function Tsv(value)
    value = tostring(value or "")
    value = value:gsub("[\t\r\n]", " ")
    return value
end

local function WriteNpcScanState(state, message, count, requestId)
    pcall(function()
        local file = io.open(NpcScanStateFileName, "w")
        if file then
            file:write(string.format("STATE=%s\n", tostring(state or "UNKNOWN")))
            file:write(string.format("REQUEST_ID=%s\n", Tsv(requestId or "")))
            file:write(string.format("TIME=%s\n", NowText()))
            file:write(string.format("COUNT=%s\n", tostring(count or 0)))
            file:write(string.format("MESSAGE=%s\n", tostring(message or "")))
            file:close()
        end
    end)
end

local function ClearNpcScanResult()
    pcall(function()
        local file = io.open(NpcScanFileName, "w")
        if file then
            file:write("Name\tX\tY\tZ\tDistance\tFullName\tKey\tLifeState\tObservedAt\n")
            file:close()
        end
    end)
end

local function ShortObjectName(fullName)
    fullName = tostring(fullName or "")
    local text = fullName:match("([^%s/%.:]+)$") or fullName
    text = text:gsub("_C_%d+$", "")
    text = text:gsub("_%d+$", "")
    text = text:gsub("^BP_", "")
    text = text:gsub("^NPC_", "")
    text = text:gsub("^Char_", "")
    text = text:gsub("^Character_", "")
    if text == "" then return "未知人物" end
    return text
end

local function NormalizeNpcLookupKey(value)
    value = tostring(value or ""):lower()
    return value:gsub("[^%w]", "")
end

local function FormatNpcBilingual(zhName, enName)
    zhName = Trim(zhName)
    enName = Trim(enName)
    if zhName ~= "" and enName ~= "" then
        return string.format("%s / %s", zhName, enName)
    end
    if zhName ~= "" then return zhName end
    if enName ~= "" then return enName end
    return "未知人物"
end

local NpcNameMap = {
    Diego = "迪亚哥",
    Milten = "米尔顿",
    Gorn = "戈恩",
    Lester = "莱斯特",
    Cavalorn = "卡瓦洛恩",
    Xardas = "萨达斯",
    Thorus = "索鲁斯",
    Bloodwyn = "布拉德温",
    Grim = "格里姆",
    Scatty = "斯卡蒂",
    Mud = "穆德",
    Snaf = "斯纳夫",
    Whistler = "威斯勒",
    Graham = "格雷厄姆",
    Jackal = "豺狼",
    Fletcher = "弗莱彻",
    Scorpio = "斯科皮奥",
    Corristo = "科里斯托",
    Lares = "拉瑞斯",
    Lee = "李",
    Angar = "安加尔",
    YBerion = "伊贝里昂",
    Digger = "矿工",
    Guard = "守卫",
    Novice = "新手",
    Templar = "圣殿武士",
    Mercenary = "佣兵",
    Mage = "法师",
}

local NpcLocalNameEntries = nil
local NpcSavedSpotNameEntries = nil
local NpcReferenceNameEntries = nil
local NpcHistoryNameEntries = nil

local function BuildNpcNameEntries(map)
    local entries = {}
    for key, name in pairs(map) do
        local norm = NormalizeNpcLookupKey(key)
        if norm ~= "" then
            table.insert(entries, { Key = key, Name = name, Norm = norm })
        end
    end
    table.sort(entries, function(a, b)
        return #a.Norm > #b.Norm
    end)
    return entries
end

local function GetNpcLocalNameEntries()
    if NpcLocalNameEntries == nil then
        NpcLocalNameEntries = BuildNpcNameEntries(NpcNameMap)
    end
    return NpcLocalNameEntries
end

local function IsUsefulLocalNpcName(name, key)
    name = Trim(name)
    key = Trim(key)
    if name == "" or key == "" then return false end
    if name == key then return false end
    if name:find("_", 1, true) then return false end
    if name:find("WorldPointActor", 1, true) then return false end
    if name:find("Spawnpoint", 1, true) or name:find("SPAWN", 1, true) then return false end
    if key:find("_", 1, true) or key:find("-", 1, true) then return false end
    return true
end

local function LoadNpcHistoryNameEntries()
    if NpcHistoryNameEntries ~= nil then return NpcHistoryNameEntries end
    local map = {}
    local file = io.open(NpcScanHistoryFileName, "r")
    if file then
        for line in file:lines() do
            if not line:match("^Name\t") then
                local name, _, _, _, _, _, key = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)")
                if IsUsefulLocalNpcName(name, key) then
                    map[key] = name
                end
            end
        end
        file:close()
    end
    NpcHistoryNameEntries = BuildNpcNameEntries(map)
    return NpcHistoryNameEntries
end

local function LoadNpcReferenceNameEntries()
    if NpcReferenceNameEntries ~= nil then return NpcReferenceNameEntries end
    NpcReferenceNameEntries = {}
    local file = io.open(NpcNameReferenceFileName, "r")
    if not file then return NpcReferenceNameEntries end
    for line in file:lines() do
        if not line:match("^English\t") then
            local enName, zhName = line:match("^([^\t]+)\t([^\t]+)")
            enName = Trim(enName)
            zhName = Trim(zhName)
            local norm = NormalizeNpcLookupKey(enName)
            if enName ~= "" and zhName ~= "" and norm ~= "" then
                table.insert(NpcReferenceNameEntries, { Key = enName, Name = zhName, Norm = norm })
            end
        end
    end
    file:close()
    table.sort(NpcReferenceNameEntries, function(a, b)
        return #a.Norm > #b.Norm
    end)
    return NpcReferenceNameEntries
end

local function NormalizeSavedNpcNameText(value)
    value = tostring(value or "")
    value = value:gsub("·", "")
    value = value:gsub("。", "")
    value = value:gsub("，", "")
    value = value:gsub("、", "")
    value = value:gsub("[%s%p%c]", "")
    return value
end

local function LoadNpcSavedSpotNameEntries()
    if NpcSavedSpotNameEntries ~= nil then return NpcSavedSpotNameEntries end
    local spotText = ""
    local file = io.open(ConfigFileName, "r")
    if file then
        for line in file:lines() do
            local name = line:match("^(.-)|")
            if name then spotText = spotText .. " " .. name end
        end
        file:close()
    end

    local normalizedSpotText = NormalizeSavedNpcNameText(spotText)
    local map = {}
    if normalizedSpotText ~= "" then
        for _, entry in ipairs(LoadNpcReferenceNameEntries()) do
            local zhNorm = NormalizeSavedNpcNameText(entry.Name)
            if zhNorm ~= "" and normalizedSpotText:find(zhNorm, 1, true) then
                map[entry.Key] = entry.Name
            end
        end
    end

    NpcSavedSpotNameEntries = BuildNpcNameEntries(map)
    return NpcSavedSpotNameEntries
end

local function FindNpcNameEntry(entries, normalizedFullName)
    for _, entry in ipairs(entries) do
        if normalizedFullName:find(entry.Norm, 1, true) then
            return entry
        end
    end
    return nil
end

local function NpcDisplayName(fullName)
    local text = tostring(fullName or "")
    local normalized = NormalizeNpcLookupKey(text)

    local entry = FindNpcNameEntry(LoadNpcSavedSpotNameEntries(), normalized)
    if entry then
        return FormatNpcBilingual(entry.Name, entry.Key), entry.Key
    end

    entry = FindNpcNameEntry(GetNpcLocalNameEntries(), normalized)
    if entry then
        return FormatNpcBilingual(entry.Name, entry.Key), entry.Key
    end

    entry = FindNpcNameEntry(LoadNpcHistoryNameEntries(), normalized)
    if entry then
        return FormatNpcBilingual(entry.Name, entry.Key), entry.Key
    end

    entry = FindNpcNameEntry(LoadNpcReferenceNameEntries(), normalized)
    if entry then
        return FormatNpcBilingual(entry.Name, entry.Key), entry.Key
    end

    local short = ShortObjectName(text)
    return short, short
end

local function ObjectIdentity(obj)
    if not IsValidObject(obj) then return "invalid" end
    local ok, address = pcall(function() return obj:GetAddress() end)
    if ok and address then return tostring(address) end
    return ObjectFullName(obj)
end

local function ReadNpcLifeState(actor)
    if not IsValidObject(actor) then return "UNKNOWN" end
    local okComponent, ragdollComponent = pcall(function() return actor.m_RagdollComponent end)
    if not okComponent or not IsValidObject(ragdollComponent) then return "UNKNOWN" end
    local okState, isRagdollActive = pcall(function() return ragdollComponent.m_IsRagdollActive end)
    if not okState or type(isRagdollActive) ~= "boolean" then return "UNKNOWN" end
    if isRagdollActive then return "DOWN_OR_DEAD" end
    return "ACTIVE"
end

local function ScanNearbyNpcs(requestId)
    local maxRows = 300

    local pawn, pawnSource = GetPlayerPawn()
    if not IsValidObject(pawn) then
        local message = "无法确认玩家对象"
        WriteNpcScanState("FAILED", message, 0, requestId)
        Diag("npc_scan failed: %s", message)
        return
    end

    local playerLoc = GetActorLocation(pawn)
    if not playerLoc then
        local message = "无法读取玩家坐标"
        WriteNpcScanState("FAILED", message, 0, requestId)
        Diag("npc_scan failed: %s pawn=%s", message, ObjectFullName(pawn))
        return
    end

    local okList, list = pcall(function() return FindAllOf("GothicCharacter") end)
    if (not okList or not list) then
        okList, list = pcall(function() return FindAllOf("Character") end)
    end
    if not okList or not list then
        local message = "FindAllOf(GothicCharacter/Character) 失败"
        WriteNpcScanState("FAILED", message, 0, requestId)
        Diag("npc_scan failed: %s", message)
        return
    end

    local pawnId = ObjectIdentity(pawn)
    local rows = {}
    local seen = {}
    local scanned = 0
    local observedAt = NowText()
    local lifeCounts = { ACTIVE = 0, DOWN_OR_DEAD = 0, UNKNOWN = 0 }

    for _, actor in ipairs(list) do
        if #rows >= maxRows then break end
        if IsValidObject(actor) then
            scanned = scanned + 1
            local id = ObjectIdentity(actor)
            if id ~= pawnId then
                local loc = GetActorLocation(actor)
                local distSq = DistSq(playerLoc, loc)
                if distSq then
                    local fullName = ObjectFullName(actor)
                    local key = fullName
                    if not seen[key] then
                        seen[key] = true
                        local name, nameKey = NpcDisplayName(fullName)
                        local lifeState = ReadNpcLifeState(actor)
                        lifeCounts[lifeState] = (lifeCounts[lifeState] or 0) + 1
                        table.insert(rows, {
                            Name = name,
                            X = loc.X,
                            Y = loc.Y,
                            Z = loc.Z,
                            Distance = math.sqrt(distSq),
                            FullName = fullName,
                            Key = nameKey,
                            LifeState = lifeState,
                            ObservedAt = observedAt,
                        })
                    end
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        return (tonumber(a.Distance) or 0) < (tonumber(b.Distance) or 0)
    end)

    local okWrite, err = pcall(function()
        local file = io.open(NpcScanFileName, "w")
        if not file then error("cannot open " .. NpcScanFileName) end
        file:write("Name\tX\tY\tZ\tDistance\tFullName\tKey\tLifeState\tObservedAt\n")
        for _, row in ipairs(rows) do
            file:write(string.format(
                "%s\t%.2f\t%.2f\t%.2f\t%.1f\t%s\t%s\t%s\t%s\n",
                Tsv(row.Name),
                tonumber(row.X) or 0,
                tonumber(row.Y) or 0,
                tonumber(row.Z) or 0,
                tonumber(row.Distance) or 0,
                Tsv(row.FullName),
                Tsv(row.Key),
                Tsv(row.LifeState),
                Tsv(row.ObservedAt)
            ))
        end
        file:close()
    end)

    if not okWrite then
        WriteNpcScanState("FAILED", tostring(err), #rows, requestId)
        Diag("npc_scan write failed: %s", tostring(err))
        return
    end

    WriteNpcScanState("DONE", string.format(
        "readable-only source=%s scanned=%s active=%s down_or_dead=%s unknown=%s",
        tostring(pawnSource), tostring(scanned), tostring(lifeCounts.ACTIVE),
        tostring(lifeCounts.DOWN_OR_DEAD), tostring(lifeCounts.UNKNOWN)
    ), #rows, requestId)
    Diag("npc_scan done id=%s readable-only rows=%s scanned=%s active=%s down_or_dead=%s unknown=%s player=%s loc=%s",
        tostring(requestId), tostring(#rows), tostring(scanned),
        tostring(lifeCounts.ACTIVE), tostring(lifeCounts.DOWN_OR_DEAD), tostring(lifeCounts.UNKNOWN), ObjectFullName(pawn),
        VectorText({X=RoundCoord(playerLoc.X), Y=RoundCoord(playerLoc.Y), Z=RoundCoord(playerLoc.Z)}))
end

local function BeginNearbyNpcScan(requestId)
    requestId = Trim(requestId or "")
    if requestId == "" then
        requestId = string.format("legacy-%s", tostring(os.time()))
    end
    ClearNpcScanResult()
    WriteNpcScanState("BUSY", "scanning-current-readable", 0, requestId)
    Diag("npc_scan immediate id=%s", requestId)
    ScanNearbyNpcs(requestId)
end

local function SaveCurrentPos(customName)
    local Pawn = GetPlayerPawn()
    if not Pawn then
        print("[TP] SaveCurrentPos: Pawn not found.\n")
        return
    end
    local Loc = GetActorLocation(Pawn)
    if not Loc then
        print("[TP] SaveCurrentPos: failed to get location.\n")
        return
    end
    local name = NormalizeName(customName or "")
    if name == "" then
        SpotAutoIndex = SpotAutoIndex + 1
        name = string.format("Spot_%d", SpotAutoIndex)
    end
    table.insert(TeleportSpots, {Name=name, X=Loc.X, Y=Loc.Y, Z=Loc.Z})
    SaveSpots()
    print(string.format("[TP] Saved: %s (%.0f, %.0f, %.0f)\n", name, Loc.X, Loc.Y, Loc.Z))
end

local function OverwriteSpot(index, customName)
    if index < 1 or index > #TeleportSpots then return end
    local Pawn = GetPlayerPawn()
    if not Pawn then return end
    local Loc = GetActorLocation(Pawn)
    if not Loc then
        print("[TP] OverwriteSpot: failed to get location.\n")
        return
    end
    local name = NormalizeName(customName or "")
    if name == "" then name = TeleportSpots[index].Name end
    TeleportSpots[index] = {Name=name, X=Loc.X, Y=Loc.Y, Z=Loc.Z}
    RebuildAutoIndex()
    SaveSpots()
    print(string.format("[TP] Overwritten: %s (%.0f, %.0f, %.0f)\n", name, Loc.X, Loc.Y, Loc.Z))
end

---------------------------------------------------------------------------
-- TELEPORT v5.3-safe: verified, segmented state machine
--
-- Gothic 1 Remake can crash when a Lua call jumps the root component across
-- large streamed regions too quickly. Keep one authoritative request at a time,
-- move long hops in small verified segments, and reject spammed requests.
---------------------------------------------------------------------------
local PendingTeleport = nil
local TeleportRequestId = 0
local TeleportHooks = {}
local TeleportHookFailures = {}
local TeleportCooldownUntil = 0
local TeleportStatusState = "IDLE"

local SAFE_DIRECT_DISTANCE = 5000.0
local SAFE_STEP_DISTANCE = 3000.0
local SAFE_STEP_DELAY = 1.25
local SAFE_DIRECT_COOLDOWN = 2.0
local SAFE_LONG_COOLDOWN = 4.0
local LEGACY_DIRECT_COOLDOWN = 4.0
local LEGACY_DIRECT_TIMEOUT = 12.0
local VERIFY_DELAY = 0.25
local HOLD_CHECK_DELAY = 0.25
local FINAL_HOLD_SECONDS = 1.0
local MAX_HOLD_CORRECTIONS = 5
local MoveApiDisabled = {}

local TeleportHookCandidates = {
    {Path="/Script/Engine.PlayerController:ClientRestart", Name="ClientRestart"},
    {Path="/Script/Engine.CharacterMovementComponent:PerformMovement", Name="PerformMovement"},
    {Path="/Script/Engine.CharacterMovementComponent:SmoothClientPosition", Name="SmoothClientPosition"},
}

local function VectorClone(v)
    if not v then return nil end
    return {
        X = tonumber(v.X) or 0,
        Y = tonumber(v.Y) or 0,
        Z = tonumber(v.Z) or 0,
    }
end

local function ReadActorRotation(actor)
    if not IsValidObject(actor) then return {Pitch=0, Yaw=0, Roll=0} end
    local okK2, rot = pcall(function() return actor:K2_GetActorRotation() end)
    if okK2 and rot then return rot end
    local okNative, native = pcall(function() return actor:GetActorRotation() end)
    if okNative and native then return native end
    return {Pitch=0, Yaw=0, Roll=0}
end

local function Distance(a, b)
    local d2 = DistSq(a, b)
    if not d2 then return nil end
    return math.sqrt(d2)
end

local function StatusClean(value)
    value = tostring(value or "")
    value = value:gsub("[\r\n]", " ")
    return value
end

local function WriteStatus(state, message, target)
    TeleportStatusState = state or "IDLE"
    local lines = {
        "STATE=" .. StatusClean(TeleportStatusState),
        "MESSAGE=" .. StatusClean(message or ""),
        "UPDATED=" .. tostring(os.time()),
    }

    if target then
        table.insert(lines, "REQUEST_ID=" .. StatusClean(target.Id))
        table.insert(lines, "SOURCE=" .. StatusClean(target.Source))
        table.insert(lines, "NAME=" .. StatusClean(target.Name))
        table.insert(lines, "TARGET=" .. VectorText(target.Final or target))
        table.insert(lines, "STEP=" .. StatusClean(target.StepIndex or 0))
        table.insert(lines, "TOTAL_STEPS=" .. StatusClean(target.TotalSteps or 0))
        if target.Mode then table.insert(lines, "MODE=" .. StatusClean(target.Mode)) end
        if target.LastMethod then table.insert(lines, "METHOD=" .. StatusClean(target.LastMethod)) end
        if target.ActorSource then table.insert(lines, "ACTOR_SOURCE=" .. StatusClean(target.ActorSource)) end
    end

    pcall(function()
        local file = io.open(StatusFileName, "w")
        if file then
            file:write(table.concat(lines, "\n") .. "\n")
            file:close()
        end
    end)
end

local function ReadEngineLocation(actor)
    if not IsValidObject(actor) then return nil, "actor-invalid" end

    local okRoot, root = pcall(function() return actor.RootComponent end)
    if okRoot and IsValidObject(root) then
        local okCtw, ctw = pcall(function() return root.ComponentToWorld end)
        if okCtw and ctw and ctw.Translation then
            local t = ctw.Translation
            if type(t.X) == "number" and type(t.Y) == "number" and type(t.Z) == "number" then
                return {X=t.X, Y=t.Y, Z=t.Z}, "ComponentToWorld"
            end
        end
    end

    local okK2, k2 = pcall(function() return actor:K2_GetActorLocation() end)
    if okK2 and k2 and type(k2.X) == "number" and type(k2.Y) == "number" and type(k2.Z) == "number" then
        return {X=k2.X, Y=k2.Y, Z=k2.Z}, "K2_GetActorLocation"
    end

    local okNative, native = pcall(function() return actor:GetActorLocation() end)
    if okNative and native and type(native.X) == "number" and type(native.Y) == "number" and type(native.Z) == "number" then
        return {X=native.X, Y=native.Y, Z=native.Z}, "GetActorLocation"
    end

    if okRoot and IsValidObject(root) then
        local okRel, rel = pcall(function() return root.RelativeLocation end)
        if okRel and rel and type(rel.X) == "number" and type(rel.Y) == "number" and type(rel.Z) == "number" then
            return {X=rel.X, Y=rel.Y, Z=rel.Z}, "RelativeLocation"
        end
    end

    return nil, "no-readable-location"
end

local function LocationMatches(actual, target)
    local d2 = DistSq(actual, target)
    return d2 ~= nil and d2 <= 2500.0, d2
end

local function ResolveActorFromHook(hookName, remoteSelf)
    local pawn, pawnSource, pc = GetPlayerPawn()
    if IsValidObject(pawn) then
        Diag("actor resolved context=%s source=%s actor=%s root=%s",
            tostring(hookName), tostring(pawnSource), ObjectFullName(pawn),
            ObjectFullName((function()
                local okRoot, root = pcall(function() return pawn.RootComponent end)
                if okRoot then return root end
                return nil
            end)()))
        return pawn, pawnSource, pc
    end
    return nil, pawnSource or "cannot-confirm-player-pawn", pc
end

local function FinishTeleportSuccess(target, location, locationSource)
    local label = target.Name or ("request-" .. tostring(target.Id))
    TeleportCooldownUntil = os.clock() + target.CooldownSeconds
    Diag("SUCCESS id=%s source=%s steps=%s target=%s readback[%s]=%s cooldown=%.1f method=%s actor=%s",
        tostring(target.Id), tostring(target.Source), tostring(target.TotalSteps),
        VectorText(target.Final), tostring(locationSource), VectorText(location),
        target.CooldownSeconds, tostring(target.LastMethod), tostring(target.ActorName))
    print(string.format("[TP] Safe teleport complete: %s (%.0f, %.0f, %.0f)\n", label, target.Final.X, target.Final.Y, target.Final.Z))
    WriteStatus("SUCCESS", string.format("verified complete; cooldown %.1fs", target.CooldownSeconds), target)
    PendingTeleport = nil
end

local function FinishTeleportFailure(target, reason)
    Diag("FAILED id=%s source=%s step=%s/%s reason=%s",
        tostring(target.Id), tostring(target.Source), tostring(target.StepIndex),
        tostring(target.TotalSteps), tostring(reason))
    print(string.format("[TP] Safe teleport failed: %s\n", tostring(reason)))
    WriteStatus("FAILED", reason, target)
    TeleportCooldownUntil = os.clock() + SAFE_DIRECT_COOLDOWN
    PendingTeleport = nil
end

local function ShouldDisableMoveApi(err)
    err = tostring(err or "")
    return err:find("Array failed invariants check", 1, true) ~= nil
        or err:find("TArray", 1, true) ~= nil
        or err:find("bad argument", 1, true) ~= nil
end

local function TryMoveActorLocation(target, actor, pc, stepTarget)
    local before, beforeSource = ReadEngineLocation(actor)
    local loc = VectorClone(stepTarget)
    local rot = ReadActorRotation(actor)
    local moveErrors = {}

    local function try_move(method, fn)
        if MoveApiDisabled[method] then
            table.insert(moveErrors, method .. "=disabled:" .. tostring(MoveApiDisabled[method]))
            return false, nil, nil
        end

        local okMove, result = pcall(fn)
        if not okMove then
            if ShouldDisableMoveApi(result) then
                MoveApiDisabled[method] = tostring(result)
            end
            table.insert(moveErrors, method .. "=" .. tostring(result))
            Diag("id=%s step=%s api=%s error=%s",
                tostring(target.Id), tostring(target.StepIndex), method, tostring(result))
            return false, nil, nil
        end

        local after, afterSource = ReadEngineLocation(actor)
        local matched, d2 = LocationMatches(after, stepTarget)
        Diag("MOVE id=%s step=%s/%s api=%s result=%s actor=%s root=%s before[%s]=%s immediate[%s]=%s target=%s dist2=%s",
            tostring(target.Id), tostring(target.StepIndex), tostring(target.TotalSteps), method, tostring(result),
            ObjectFullName(actor),
            ObjectFullName((function()
                local okRoot, root = pcall(function() return actor.RootComponent end)
                if okRoot then return root end
                return nil
            end)()),
            tostring(beforeSource), VectorText(before), tostring(afterSource), VectorText(after), VectorText(stepTarget), tostring(d2))
        if matched == true then
            return true, after, afterSource
        end

        table.insert(moveErrors, method .. "=readback-mismatch")
        return false, after, afterSource
    end

    local okMove, after, afterSource = try_move("Actor.K2_TeleportTo", function()
        return actor:K2_TeleportTo(loc, rot)
    end)
    if okMove then return true, after, afterSource, "Actor.K2_TeleportTo" end

    okMove, after, afterSource = try_move("Actor.K2_SetActorLocation/full", function()
        return actor:K2_SetActorLocation(loc, false, nil, true)
    end)
    if okMove then return true, after, afterSource, "Actor.K2_SetActorLocation/full" end

    okMove, after, afterSource = try_move("Actor.K2_SetActorLocation/2args", function()
        return actor:K2_SetActorLocation(loc, false)
    end)
    if okMove then return true, after, afterSource, "Actor.K2_SetActorLocation/2args" end

    okMove, after, afterSource = try_move("Actor.SetActorLocation/full", function()
        return actor:SetActorLocation(loc, false, nil, true)
    end)
    if okMove then return true, after, afterSource, "Actor.SetActorLocation/full" end

    okMove, after, afterSource = try_move("Actor.SetActorLocation/1arg", function()
        return actor:SetActorLocation(loc)
    end)
    if okMove then return true, after, afterSource, "Actor.SetActorLocation/1arg" end

    if IsValidObject(pc) then
        okMove, after, afterSource = try_move("PlayerController.ClientSetLocation", function()
            return pc:ClientSetLocation(loc, rot)
        end)
        if okMove then return true, after, afterSource, "PlayerController.ClientSetLocation" end
    else
        table.insert(moveErrors, "PlayerController.ClientSetLocation=no-controller")
    end

    local okRoot, root = pcall(function() return actor.RootComponent end)
    if okRoot and IsValidObject(root) then
        okMove, after, afterSource = try_move("Root.RelativeLocation/set", function()
            root.RelativeLocation = loc
            return true
        end)
        if okMove then return true, after, afterSource, "Root.RelativeLocation/set" end
    else
        table.insert(moveErrors, "Root.RelativeLocation/set=no-root")
    end

    Diag("id=%s step=%s api=move-all-failed errors=%s",
        tostring(target.Id), tostring(target.StepIndex), table.concat(moveErrors, " | "))
    return false, after, afterSource, table.concat(moveErrors, " | ")
end

local function TryMoveLegacyRootLocation(target, actor, stepTarget)
    local before, beforeSource = ReadEngineLocation(actor)

    local okRoot, root = pcall(function() return actor.RootComponent end)
    if not okRoot or not IsValidObject(root) then
        Diag("LEGACY id=%s root invalid", tostring(target.Id))
        return false, nil, nil, "root-invalid"
    end

    local loc = VectorClone(stepTarget)
    local moveErrors = {}

    local function try_root_move(method, fn)
        local okMove, result = pcall(fn)
        if not okMove then
            table.insert(moveErrors, method .. "=" .. tostring(result))
            Diag("LEGACY id=%s api=%s error=%s", tostring(target.Id), method, tostring(result))
            return false, nil, nil
        end

        local after, afterSource = ReadEngineLocation(actor)
        local matched, d2 = LocationMatches(after, stepTarget)
        Diag("LEGACY_MOVE id=%s api=%s result=%s actor=%s root=%s before[%s]=%s after[%s]=%s target=%s dist2=%s",
            tostring(target.Id), method, tostring(result), ObjectFullName(actor), ObjectFullName(root),
            tostring(beforeSource), VectorText(before), tostring(afterSource), VectorText(after), VectorText(stepTarget), tostring(d2))
        if matched then
            return true, after, afterSource
        end
        table.insert(moveErrors, method .. "=readback-mismatch")
        return false, after, afterSource
    end

    local okMove, after, afterSource = try_root_move("Root.K2_SetWorldLocation/hit-table", function()
        local hitResult = {}
        return root:K2_SetWorldLocation(loc, false, hitResult, true)
    end)
    if okMove then return true, after, afterSource, "Root.K2_SetWorldLocation/hit-table" end

    okMove, after, afterSource = try_root_move("Root.K2_SetWorldLocation/2args", function()
        return root:K2_SetWorldLocation(loc, false)
    end)
    if okMove then return true, after, afterSource, "Root.K2_SetWorldLocation/2args" end

    okMove, after, afterSource = try_root_move("Root.RelativeLocation/set", function()
        root.RelativeLocation = loc
        return true
    end)
    if okMove then return true, after, afterSource, "Root.RelativeLocation/set" end

    Diag("LEGACY id=%s api=move-all-failed errors=%s", tostring(target.Id), table.concat(moveErrors, " | "))
    return false, after, afterSource, table.concat(moveErrors, " | ")
end

local function AttemptPendingTeleport(context, remoteSelf)
    if not PendingTeleport then return end
    local target = PendingTeleport
    local now = os.clock()

    if now < target.NextStepAt then return end

    if now > target.TimeoutAt then
        FinishTeleportFailure(target, "timeout")
        return
    end

    if target.StepIndex > target.TotalSteps then
        FinishTeleportFailure(target, "invalid-step")
        return
    end

    if target.Mode == "LEGACY_DIRECT" then
        target.Attempts = target.Attempts + 1
        local actor, actorSource, pc = ResolveActorFromHook(context, remoteSelf)
        if not IsValidObject(actor) then
            FinishTeleportFailure(target, actorSource or "actor-invalid")
            return
        end

        target.ActorSource = actorSource
        target.ActorName = ObjectFullName(actor)
        local okMove, readback, readbackSource, method = TryMoveLegacyRootLocation(target, actor, target.Final)
        target.LastMethod = method
        target.LastReadback = readback
        target.LastReadbackSource = readbackSource
        if not okMove then
            FinishTeleportFailure(target, "legacy-direct-move-not-accepted")
            return
        end

        Diag("LEGACY_SUCCESS id=%s source=%s target=%s readback[%s]=%s method=%s",
            tostring(target.Id), tostring(target.Source), VectorText(target.Final),
            tostring(readbackSource), VectorText(readback), tostring(method))
        FinishTeleportSuccess(target, readback, readbackSource)
        return
    end

    if target.Mode == "HOLD" or target.Mode == "FINAL_HOLD" then
        local actor, actorSource, pc = ResolveActorFromHook(context, remoteSelf)
        if not IsValidObject(actor) then
            FinishTeleportFailure(target, actorSource or "actor-invalid")
            return
        end

        local readback, readbackSource = ReadEngineLocation(actor)
        local matched, d2 = LocationMatches(readback, target.LastStepTarget)
        Diag("HOLD_%s id=%s step=%s/%s method=%s actorSource=%s readback[%s]=%s target=%s dist2=%s corrections=%s",
            matched and "OK" or "DRIFT", tostring(target.Id), tostring(target.StepIndex), tostring(target.TotalSteps),
            tostring(target.LastMethod), tostring(actorSource), tostring(readbackSource), VectorText(readback),
            VectorText(target.LastStepTarget), tostring(d2), tostring(target.HoldCorrections or 0))

        if not matched then
            target.HoldCorrections = (target.HoldCorrections or 0) + 1
            if target.HoldCorrections > MAX_HOLD_CORRECTIONS then
                FinishTeleportFailure(target, "segment-lost-during-hold")
                return
            end

            local okMove, movedBack, movedBackSource, method = TryMoveActorLocation(target, actor, pc, target.LastStepTarget)
            if not okMove then
                FinishTeleportFailure(target, "hold-reapply-failed")
                return
            end
            target.LastMethod = tostring(method) .. "/hold"
            target.LastReadback = movedBack
            target.LastReadbackSource = movedBackSource
            target.NextStepAt = now + VERIFY_DELAY
            WriteStatus("BUSY", string.format("holding step %d/%d correction %d", target.StepIndex, target.TotalSteps, target.HoldCorrections), target)
            return
        end

        if now < (target.HoldUntil or now) then
            target.NextStepAt = now + HOLD_CHECK_DELAY
            WriteStatus("BUSY", string.format("holding step %d/%d", target.StepIndex, target.TotalSteps), target)
            return
        end

        if target.Mode == "FINAL_HOLD" or target.StepIndex >= target.TotalSteps then
            FinishTeleportSuccess(target, readback, readbackSource)
            return
        end

        target.StepIndex = target.StepIndex + 1
        target.Mode = "MOVE"
        target.NextStepAt = now
        target.HoldCorrections = 0
        WriteStatus("BUSY", string.format("safe teleport %d/%d held", target.StepIndex - 1, target.TotalSteps), target)
        return
    end

    if target.Mode == "VERIFY" then
        local actor, actorSource, pc = ResolveActorFromHook(context, remoteSelf)
        if not IsValidObject(actor) then
            FinishTeleportFailure(target, actorSource or "actor-invalid")
            return
        end

        local readback, readbackSource = ReadEngineLocation(actor)
        local matched, d2 = LocationMatches(readback, target.LastStepTarget)
        Diag("VERIFY_%s id=%s step=%s/%s method=%s actorSource=%s actor=%s readback[%s]=%s target=%s dist2=%s",
            matched and "OK" or "FAILED", tostring(target.Id), tostring(target.StepIndex), tostring(target.TotalSteps),
            tostring(target.LastMethod), tostring(actorSource), ObjectFullName(actor), tostring(readbackSource),
            VectorText(readback), VectorText(target.LastStepTarget), tostring(d2))

        if not matched then
            FinishTeleportFailure(target, "delayed-readback-mismatch")
            return
        end

        if target.StepIndex >= target.TotalSteps then
            target.Mode = "FINAL_HOLD"
            target.HoldUntil = now + FINAL_HOLD_SECONDS
            target.HoldCorrections = 0
            target.NextStepAt = now + HOLD_CHECK_DELAY
            WriteStatus("BUSY", string.format("final hold %.1fs", FINAL_HOLD_SECONDS), target)
            return
        end

        target.Mode = "HOLD"
        target.HoldUntil = now + SAFE_STEP_DELAY
        target.HoldCorrections = 0
        target.NextStepAt = now + HOLD_CHECK_DELAY
        WriteStatus("BUSY", string.format("safe teleport %d/%d verified; holding", target.StepIndex, target.TotalSteps), target)
        return
    end

    target.Attempts = target.Attempts + 1

    local actor, actorSource, pc = ResolveActorFromHook(context, remoteSelf)
    if not IsValidObject(actor) then
        FinishTeleportFailure(target, actorSource or "actor-invalid")
        return
    end

    if target.StepIndex > 1 and target.LastStepTarget then
        local current, currentSource = ReadEngineLocation(actor)
        local stillAtPrevious, previousD2 = LocationMatches(current, target.LastStepTarget)
        if not stillAtPrevious then
            Diag("PRESTEP_LOST id=%s step=%s/%s actorSource=%s readback[%s]=%s expected=%s dist2=%s",
                tostring(target.Id), tostring(target.StepIndex), tostring(target.TotalSteps), tostring(actorSource),
                tostring(currentSource), VectorText(current), VectorText(target.LastStepTarget), tostring(previousD2))
            FinishTeleportFailure(target, "segment-lost-before-next-step")
            return
        end
    end

    local stepTarget = target.Steps[target.StepIndex]
    target.ActorSource = actorSource
    target.ActorName = ObjectFullName(actor)
    local okMove, readback, readbackSource, method = TryMoveActorLocation(target, actor, pc, stepTarget)
    if not okMove then
        FinishTeleportFailure(target, "move-not-accepted")
        return
    end

    target.Mode = "VERIFY"
    target.LastMethod = method
    target.LastReadback = readback
    target.LastReadbackSource = readbackSource
    target.LastStepTarget = VectorClone(stepTarget)
    target.VerifyAt = now + VERIFY_DELAY
    target.NextStepAt = target.VerifyAt
    WriteStatus("BUSY", string.format("verifying step %d/%d via %s", target.StepIndex, target.TotalSteps, tostring(method)), target)
end

local function RegisterTeleportHook(path, hookName)
    if TeleportHooks[path] then return true end
    if TeleportHookFailures[path] then return false end
    local ok, preId, postId = pcall(function()
        return RegisterHook(path, function(self, ...)
            AttemptPendingTeleport(hookName, self)
        end, function(self, ...)
            AttemptPendingTeleport(hookName .. ":post", self)
        end)
    end)
    if ok then
        TeleportHooks[path] = {preId=preId, postId=postId, name=hookName}
        Diag("hook registered name=%s path=%s pre=%s post=%s", hookName, path, tostring(preId), tostring(postId))
        return true
    end
    TeleportHookFailures[path] = tostring(preId)
    Diag("hook disabled name=%s path=%s err=%s", hookName, path, tostring(preId))
    return false
end

local function TeleportHookCount()
    local count = 0
    for _, _ in pairs(TeleportHooks) do count = count + 1 end
    return count
end

local function EnsureTeleportHooks(reason)
    for _, candidate in ipairs(TeleportHookCandidates) do
        RegisterTeleportHook(candidate.Path, candidate.Name)
    end
    Diag("hook ensure complete reason=%s count=%s", tostring(reason), tostring(TeleportHookCount()))
end

-- ==========================================
-- NOCLIP / CAMERA FLIGHT
-- UObject access is one-shot on enable/disable. Continuous input and camera
-- tracking run in TeleportCppBridge so Core.Tick never polls NoClip objects.
-- ==========================================
local NoClipEnabled = false
local NoClipSpeed = 3.0
local NoClipOriginal = nil
local PendingInteractionRestore = nil
local InteractionRestoreTick = 0
local NoClipToggleGateTick = 0

local function TryNoClipRaw(label, callback)
    local ok, result = pcall(callback)
    if not ok then
        Diag("NoClip raw write failed label=%s error=%s", tostring(label), tostring(result))
        return false, nil
    end
    return true, result
end

local function NumberValue(value)
    if type(value) == "number" then return value end
    local text = tostring(value or "")
    local number = tonumber(text)
    if number then return number end
    text = text:lower()
    if text:find("nocollision", 1, true) then return 0 end
    if text:find("queryonly", 1, true) then return 1 end
    if text:find("physicsonly", 1, true) then return 2 end
    if text:find("queryandphysics", 1, true) then return 3 end
    if text:find("move_none", 1, true) then return 0 end
    if text:find("move_walking", 1, true) then return 1 end
    if text:find("move_navwalking", 1, true) then return 2 end
    if text:find("move_falling", 1, true) then return 3 end
    if text:find("move_swimming", 1, true) then return 4 end
    if text:find("move_flying", 1, true) then return 5 end
    if text:find("move_custom", 1, true) then return 6 end
    return nil
end

local function ReadObjectNumber(obj, propertyName)
    if not IsValidObject(obj) then return nil end
    local ok, value = pcall(function() return obj[propertyName] end)
    if not ok then return nil end
    return NumberValue(value)
end

local function ReadObjectBool(obj, propertyName)
    if not IsValidObject(obj) then return nil end
    local ok, value = pcall(function() return obj[propertyName] end)
    if not ok then return nil end
    if value == true or value == false then return value end
    local text = tostring(value):lower()
    if text == "true" or text == "1" then return true end
    if text == "false" or text == "0" then return false end
    return nil
end

local function ResolveNoClipMovement(pawn)
    local moveComp
    local moveSource = "unresolved"
    local movementCandidates = {
        {"CharacterMovement", function() return pawn.CharacterMovement end},
        {"CharacterMovementComponent", function() return pawn.CharacterMovementComponent end},
        {"MovementComponent", function() return pawn.MovementComponent end},
    }
    for _, candidate in ipairs(movementCandidates) do
        local ok, value = pcall(candidate[2])
        if ok and IsValidObject(value) then
            moveComp = value
            moveSource = candidate[1]
            break
        end
    end
    return moveComp, moveSource
end

local function ReadActorCollision(pawn)
    return ReadObjectBool(pawn, "bActorEnableCollision")
end

local function CloneNoClipSnapshot(snapshot)
    if type(snapshot) ~= "table" then return nil end
    return {
        PawnName = tostring(snapshot.PawnName or ""),
        ActorCollision = snapshot.ActorCollision,
        MovementMode = tonumber(snapshot.MovementMode),
        DefaultLandMovementMode = tonumber(snapshot.DefaultLandMovementMode),
        GravityScale = tonumber(snapshot.GravityScale),
        MaxFlySpeed = tonumber(snapshot.MaxFlySpeed),
        CheatFlying = snapshot.CheatFlying,
    }
end

local function SanitizeNoClipSnapshot(snapshot, source)
    if type(snapshot) ~= "table" then return snapshot end
    local contaminated = snapshot.MovementMode == 5 and snapshot.ActorCollision == true and
        snapshot.CheatFlying == false and snapshot.GravityScale ~= nil and snapshot.GravityScale > 0.001
    if contaminated then
        Diag("NoClip baseline sanitized source=%s pawn=%s mode=5 collision=true gravity=%s cheatFly=false -> walking",
            tostring(source), tostring(snapshot.PawnName), tostring(snapshot.GravityScale))
        snapshot.MovementMode = 1
        snapshot.DefaultLandMovementMode = 1
    end
    return snapshot
end

local function CaptureNoClipOriginal(pawn, moveComp)
    local captured = {
        PawnName = ObjectFullName(pawn),
        ActorCollision = ReadActorCollision(pawn),
        MovementMode = ReadObjectNumber(moveComp, "MovementMode"),
        DefaultLandMovementMode = ReadObjectNumber(moveComp, "DefaultLandMovementMode"),
        GravityScale = ReadObjectNumber(moveComp, "GravityScale"),
        MaxFlySpeed = ReadObjectNumber(moveComp, "MaxFlySpeed"),
        CheatFlying = ReadObjectBool(moveComp, "bCheatFlying"),
    }
    NoClipOriginal = SanitizeNoClipSnapshot(captured, "capture")
    Diag("NoClip original pawn=%s actorCollision=%s mode=%s gravity=%s flySpeed=%s cheatFly=%s",
        tostring(NoClipOriginal.PawnName), tostring(NoClipOriginal.ActorCollision),
        tostring(NoClipOriginal.MovementMode), tostring(NoClipOriginal.GravityScale),
        tostring(NoClipOriginal.MaxFlySpeed), tostring(NoClipOriginal.CheatFlying))
end

local function AppendCppAction(line)
    local started, startErr = EnsureCppBridgeStarted("action")
    if not started then return false, startErr end
    local ok, err = pcall(function()
        local file = io.open(CppActionsFileName, "a")
        if not file then error("cannot open " .. CppActionsFileName) end
        file:write(line)
        file:close()
    end)
    if not ok then return false, tostring(err) end
    return true, nil
end

local function GetControlRotationAddress(pc)
    if not IsValidObject(pc) then return nil, "PlayerController invalid" end
    local ok, pointer = pcall(function()
        local reflection = pc:Reflection()
        local property = reflection:GetProperty("ControlRotation")
        return property:ContainerPtrToValuePtr(pc, 0)
    end)
    if not ok or pointer == nil then
        return nil, "ControlRotation reflection failed: " .. tostring(pointer)
    end
    local text = tostring(pointer)
    local hex = text:match("0[xX]([0-9a-fA-F]+)") or text:match(":%s*([0-9a-fA-F]+)")
    if not hex or #hex < 6 then
        return nil, "ControlRotation pointer unreadable: " .. text
    end
    return "0x" .. hex, nil
end

local function ApplyNoClipOneShot(pawn, moveComp)
    local writesOk = true
    local function write(label, callback)
        local ok = TryNoClipRaw(label, callback)
        writesOk = writesOk and ok
    end
    write("Pawn.bActorEnableCollision=false", function() pawn.bActorEnableCollision = false end)
    write("CharacterMovement.MovementMode=5", function() moveComp.MovementMode = 5 end)
    write("CharacterMovement.DefaultLandMovementMode=5", function() moveComp.DefaultLandMovementMode = 5 end)
    write("CharacterMovement.bCheatFlying=true", function() moveComp.bCheatFlying = true end)
    write("CharacterMovement.GravityScale=0", function() moveComp.GravityScale = 0.0 end)
    write("CharacterMovement.MaxFlySpeed=0", function() moveComp.MaxFlySpeed = 0.0 end)

    local actorCollision = ReadActorCollision(pawn)
    local movementMode = ReadObjectNumber(moveComp, "MovementMode")
    local gravityScale = ReadObjectNumber(moveComp, "GravityScale")
    local cheatFlying = ReadObjectBool(moveComp, "bCheatFlying")
    local verified = writesOk and actorCollision == false and movementMode == 5 and
        gravityScale ~= nil and math.abs(gravityScale) <= 0.001
    local stateText = string.format("pawn=%s move=%s actorCollision=%s mode=%s gravity=%s cheatFly=%s",
        ObjectFullName(pawn), ObjectFullName(moveComp), tostring(actorCollision), tostring(movementMode),
        tostring(gravityScale), tostring(cheatFlying))
    return verified, stateText
end

local function ApplyNoClipRestoreSnapshot(pawn, snapshot, label)
    if not IsValidObject(pawn) then return false end
    local original = SanitizeNoClipSnapshot(CloneNoClipSnapshot(snapshot), label) or {}
    local actorCollision = original.ActorCollision
    if actorCollision == nil then actorCollision = true end
    TryNoClipRaw("Pawn.bActorEnableCollision restore", function()
        pawn.bActorEnableCollision = actorCollision
    end)

    local moveComp = ResolveNoClipMovement(pawn)
    if IsValidObject(moveComp) then
        TryNoClipRaw("CharacterMovement.MovementMode restore", function()
            moveComp.MovementMode = original.MovementMode or 1
        end)
        TryNoClipRaw("CharacterMovement.DefaultLandMovementMode restore", function()
            moveComp.DefaultLandMovementMode = original.DefaultLandMovementMode or 1
        end)
        TryNoClipRaw("CharacterMovement.bCheatFlying restore", function()
            moveComp.bCheatFlying = original.CheatFlying == true
        end)
        TryNoClipRaw("CharacterMovement.GravityScale restore", function()
            moveComp.GravityScale = original.GravityScale or 2.0
        end)
        TryNoClipRaw("CharacterMovement.MaxFlySpeed restore", function()
            moveComp.MaxFlySpeed = original.MaxFlySpeed or 120.0
        end)
    end
    return true
end

local function RestoreNoClipState(pawn, pc, startupRestore)
    local bridgeOk, bridgeErr = AppendCppAction("FLIGHT_DISABLE\n")
    if not bridgeOk then
        Diag("NoClip bridge disable failed startup=%s error=%s", tostring(startupRestore), tostring(bridgeErr))
    end
    if not IsValidObject(pawn) then return bridgeOk end

    ApplyNoClipRestoreSnapshot(pawn, NoClipOriginal, "restore")
    local moveComp = ResolveNoClipMovement(pawn)
    Diag("NoClip restored startup=%s pawn=%s mode=%s actorCollision=%s bridge=%s",
        tostring(startupRestore), ObjectFullName(pawn), tostring(ReadObjectNumber(moveComp, "MovementMode")),
        tostring(ReadActorCollision(pawn)), tostring(bridgeOk))
    return true
end

local InteractionRestoreDelayTicks = {1, 3, 6} -- shell tick is 250 ms: ~0.25, 0.75, 1.50 s

local function CancelPendingInteractionRestore(reason)
    if not PendingInteractionRestore then return false end
    Diag("interaction restore cancelled reason=%s nextAttempt=%s",
        tostring(reason), tostring(PendingInteractionRestore.NextAttempt))
    PendingInteractionRestore = nil
    return true
end

local function ScheduleInteractionRestore(snapshot, abilityName)
    local saved = SanitizeNoClipSnapshot(CloneNoClipSnapshot(snapshot), "interaction-schedule")
    if not saved or saved.PawnName == "" then return false end
    local dueTicks = {}
    for index, delayTicks in ipairs(InteractionRestoreDelayTicks) do
        dueTicks[index] = InteractionRestoreTick + delayTicks
    end
    PendingInteractionRestore = {
        PawnName = saved.PawnName,
        Snapshot = saved,
        AbilityName = tostring(abilityName or "unknown"),
        NextAttempt = 1,
        DueTicks = dueTicks,
    }
    Diag("interaction restore scheduled pawn=%s attempts=%s ability=%s",
        tostring(saved.PawnName), tostring(#dueTicks), tostring(abilityName))
    return true
end

local function TickPendingInteractionRestore()
    local pending = PendingInteractionRestore
    if not pending then return end
    local attempt = tonumber(pending.NextAttempt) or 1
    local dueTick = pending.DueTicks and pending.DueTicks[attempt]
    if not dueTick then
        PendingInteractionRestore = nil
        return
    end
    if InteractionRestoreTick < dueTick then return end

    pending.NextAttempt = attempt + 1
    local pawn, source = GetPlayerPawn()
    if not IsValidObject(pawn) then
        Diag("interaction restore attempt=%s failed reason=pawn-invalid", tostring(attempt))
    else
        local pawnName = ObjectFullName(pawn)
        if pawnName ~= pending.PawnName then
            Diag("interaction restore attempt=%s skipped reason=pawn-changed expected=%s actual=%s",
                tostring(attempt), tostring(pending.PawnName), tostring(pawnName))
        else
            ApplyNoClipRestoreSnapshot(pawn, pending.Snapshot, "interaction-attempt-" .. tostring(attempt))
            local moveComp = ResolveNoClipMovement(pawn)
            Diag("interaction restore attempt=%s/%s source=%s pawn=%s mode=%s collision=%s gravity=%s cheatFly=%s",
                tostring(attempt), tostring(#pending.DueTicks), tostring(source), tostring(pawnName),
                tostring(ReadObjectNumber(moveComp, "MovementMode")), tostring(ReadActorCollision(pawn)),
                tostring(ReadObjectNumber(moveComp, "GravityScale")), tostring(ReadObjectBool(moveComp, "bCheatFlying")))
        end
    end

    if pending.NextAttempt > #pending.DueTicks then
        Diag("interaction restore completed attempts=%s ability=%s",
            tostring(#pending.DueTicks), tostring(pending.AbilityName))
        PendingInteractionRestore = nil
    end
end

local function GetInteractionObject(context)
    if IsValidObject(context) then return context end
    if context == nil then return nil end
    local ok, value = pcall(function() return context:get() end)
    if ok and IsValidObject(value) then return value end
    ok, value = pcall(function() return context:Get() end)
    if ok and IsValidObject(value) then return value end
    return nil
end

local function IsDoorOrContainerInteraction(ability)
    local name = string.lower(ObjectFullName(ability))
    return name:find("ga_human_opendoor", 1, true) ~= nil or
        name:find("gameplayabilitydoor", 1, true) ~= nil or
        name:find("gameplayabilityopendoor", 1, true) ~= nil or
        name:find("opencontainer", 1, true) ~= nil or
        name:find("gameplayabilityopencontainer", 1, true) ~= nil
end

local function BeforeInteraction(context)
    local ability = GetInteractionObject(context)
    local abilityName = ObjectFullName(ability)
    if IsDoorOrContainerInteraction(ability) then
        Diag("BeforeInteraction keep-flight route=lock ability=%s", tostring(abilityName))
        return false
    end
    if not NoClipEnabled then return false end

    local pawn, source, pc = GetPlayerPawn()
    local snapshot = SanitizeNoClipSnapshot(CloneNoClipSnapshot(NoClipOriginal), "before-interaction")
    local pawnName = IsValidObject(pawn) and ObjectFullName(pawn) or "invalid"
    if IsValidObject(pawn) and (not snapshot or snapshot.PawnName ~= pawnName) then
        snapshot = {
            PawnName = pawnName,
            ActorCollision = true,
            MovementMode = 1,
            DefaultLandMovementMode = 1,
            GravityScale = 2.0,
            MaxFlySpeed = 120.0,
            CheatFlying = false,
        }
        Diag("BeforeInteraction used safe walking fallback pawn=%s", tostring(pawnName))
    end

    NoClipEnabled = false
    if IsValidObject(pawn) then
        NoClipOriginal = snapshot
        RestoreNoClipState(pawn, pc, false)
        ScheduleInteractionRestore(snapshot, abilityName)
    else
        local bridgeOk, bridgeErr = AppendCppAction("FLIGHT_DISABLE\n")
        Diag("BeforeInteraction pawn invalid bridge=%s error=%s", tostring(bridgeOk), tostring(bridgeErr))
    end
    NoClipOriginal = nil
    SendUiControl("FLIGHT_OFF")
    WriteStatus("IDLE", "Free Flight closed for interaction; enable it again after the interaction.", nil)
    Diag("BeforeInteraction flight auto-disabled source=%s pawn=%s ability=%s",
        tostring(source), tostring(pawnName), tostring(abilityName))
    print("[NoClip] AUTO-DISABLED FOR INTERACTION\n")
    return true
end

local function ProbeNoClipState(reason)
    local pawn, source = GetPlayerPawn()
    if not IsValidObject(pawn) then
        Diag("NoClip probe failed reason=%s player pawn invalid", tostring(reason))
        WriteStatus("FAILED", "自由飞翔状态检查失败：玩家对象无效", nil)
        return false
    end
    local moveComp, moveSource = ResolveNoClipMovement(pawn)
    local actorCollision = ReadActorCollision(pawn)
    local movementMode = ReadObjectNumber(moveComp, "MovementMode")
    local gravityScale = ReadObjectNumber(moveComp, "GravityScale")
    local verified = actorCollision == false and movementMode == 5 and gravityScale ~= nil and
        math.abs(gravityScale) <= 0.001
    Diag("NoClip probe reason=%s source=%s moveSource=%s verified=%s pawn=%s move=%s actorCollision=%s mode=%s gravity=%s",
        tostring(reason), tostring(source), tostring(moveSource), tostring(verified), ObjectFullName(pawn),
        ObjectFullName(moveComp), tostring(actorCollision), tostring(movementMode), tostring(gravityScale))
    WriteStatus(verified and "IDLE" or "FAILED", verified and "自由飞翔状态正常" or
        "自由飞翔状态已变化，请关闭后重新开启", nil)
    return verified
end

local function SetNoClipSpeed(speed)
    local requestedSpeed = math.max(0.25, math.min(10.0, tonumber(speed) or NoClipSpeed or 3.0))
    if not NoClipEnabled then
        NoClipSpeed = requestedSpeed
        Diag("SetNoClipSpeed preset while disabled multiplier=%.2f", NoClipSpeed)
        WriteStatus("IDLE", string.format("自由飞翔速度已预设为 %.2fx", NoClipSpeed), nil)
        return true
    end
    local speedUu = 600.0 * requestedSpeed
    local ok, err = AppendCppAction(string.format("FLIGHT_SPEED|%.3f\n", speedUu))
    if not ok then
        Diag("SetNoClipSpeed failed requested=%.2f error=%s", requestedSpeed, tostring(err))
        WriteStatus("FAILED", "自由飞翔速度更新失败", nil)
        return false
    end
    NoClipSpeed = requestedSpeed
    Diag("SetNoClipSpeed sent multiplier=%.2f speedUu=%.1f route=cpp-target-only", NoClipSpeed, speedUu)
    WriteStatus("IDLE", string.format("自由飞翔速度已切换为 %.1fx", NoClipSpeed), nil)
    return true
end

local function RefreshNoClipState(reason)
    reason = NormalizeName(reason or "interaction")
    if not NoClipEnabled then
        Diag("NoClip refresh ignored reason=%s disabled", tostring(reason))
        return false
    end

    local pawn, source = GetPlayerPawn()
    if not IsValidObject(pawn) then
        Diag("NoClip refresh failed reason=%s player pawn invalid", tostring(reason))
        WriteStatus("FAILED", "自由飞翔互动后恢复失败：玩家对象无效", nil)
        return false
    end
    local moveComp, moveSource = ResolveNoClipMovement(pawn)
    if not IsValidObject(moveComp) then
        Diag("NoClip refresh failed reason=%s movement invalid pawn=%s", tostring(reason), ObjectFullName(pawn))
        WriteStatus("FAILED", "自由飞翔互动后恢复失败：移动组件无效", nil)
        return false
    end

    if not NoClipOriginal or NoClipOriginal.PawnName ~= ObjectFullName(pawn) then
        CaptureNoClipOriginal(pawn, moveComp)
    end
    local verified, stateText = ApplyNoClipOneShot(pawn, moveComp)
    local bridgeOk, bridgeErr = AppendCppAction("FLIGHT_REBASE\n")
    Diag("NoClip refresh reason=%s verified=%s source=%s moveSource=%s bridge=%s bridgeErr=%s %s",
        tostring(reason), tostring(verified), tostring(source), tostring(moveSource), tostring(bridgeOk),
        tostring(bridgeErr), tostring(stateText))
    if verified and bridgeOk then
        WriteStatus("IDLE", "自由飞翔已在互动后自动恢复", nil)
        return true
    end
    WriteStatus("FAILED", "自由飞翔互动后自动恢复未完成，请关闭后重新开启", nil)
    return false
end

local function SetNoClipMode(enable, speed)
    local requested = (enable == true or enable == "1" or enable == 1 or
        (enable == "TOGGLE" and not NoClipEnabled))
    local requestedSpeed = math.max(0.25, math.min(10.0, tonumber(speed) or NoClipSpeed or 1.0))
    if requested then
        CancelPendingInteractionRestore("flight-enabled")
    end
    if requested and NoClipEnabled then
        return SetNoClipSpeed(requestedSpeed)
    end
    NoClipSpeed = requestedSpeed
    Diag("SetNoClipMode requested enable=%s speed=%.2f", tostring(requested), NoClipSpeed)

    local pawn, source, pc = GetPlayerPawn()
    if not IsValidObject(pawn) then
        NoClipEnabled = false
        Diag("SetNoClipMode failed player pawn invalid")
        WriteStatus("FAILED", "自由飞翔开启失败：玩家对象无效", nil)
        print("[NoClip] FAILED: player pawn invalid\n")
        return false
    end

    if requested then
        local moveComp, moveSource = ResolveNoClipMovement(pawn)
        if not IsValidObject(moveComp) then
            NoClipEnabled = false
            Diag("SetNoClipMode failed movement component invalid pawn=%s source=%s",
                ObjectFullName(pawn), tostring(source))
            WriteStatus("FAILED", "自由飞翔开启失败：移动组件不可用", nil)
            return false
        end
        local rotationAddress, rotationError = GetControlRotationAddress(pc)
        if not rotationAddress then
            NoClipEnabled = false
            Diag("SetNoClipMode failed rotation-address error=%s", tostring(rotationError))
            WriteStatus("FAILED", "自由飞翔开启失败：无法读取镜头方向", nil)
            return false
        end
        if not NoClipEnabled or not NoClipOriginal or NoClipOriginal.PawnName ~= ObjectFullName(pawn) then
            CaptureNoClipOriginal(pawn, moveComp)
        end
        local stateVerified, stateText = ApplyNoClipOneShot(pawn, moveComp)
        if not stateVerified then
            RestoreNoClipState(pawn, pc, false)
            NoClipOriginal = nil
            NoClipEnabled = false
            Diag("SetNoClipMode one-shot verification failed source=%s moveSource=%s %s",
                tostring(source), tostring(moveSource), stateText)
            WriteStatus("FAILED", "自由飞翔开启失败：状态验证未通过", nil)
            return false
        end
        local speedUu = 600.0 * NoClipSpeed
        local bridgeOk, bridgeErr = AppendCppAction(string.format("FLIGHT_ENABLE|%.3f|%s\n",
            speedUu, rotationAddress))
        if not bridgeOk then
            RestoreNoClipState(pawn, pc, false)
            NoClipOriginal = nil
            NoClipEnabled = false
            Diag("SetNoClipMode bridge enable failed error=%s", tostring(bridgeErr))
            WriteStatus("FAILED", "自由飞翔开启失败：外部飞行桥不可用", nil)
            return false
        end
        NoClipEnabled = true
        Diag("SetNoClipMode enabled source=%s moveSource=%s speedUu=%.1f rotation=%s %s",
            tostring(source), tostring(moveSource), speedUu, rotationAddress, stateText)
        WriteStatus("IDLE", string.format("自由飞翔已开启（%.1fx）", NoClipSpeed), nil)
        print(string.format("[NoClip] SAFE CAMERA FLIGHT ENABLED speed=%.1fx\n", NoClipSpeed))
        return true
    end

    NoClipEnabled = false
    RestoreNoClipState(pawn, pc, false)
    NoClipOriginal = nil
    WriteStatus("IDLE", "自由飞翔已关闭", nil)
    print("[NoClip] DISABLED\n")
    return true
end

-- F7 uses the existing safe flight path and rejects one-frame key repeats.
local function ToggleNoClipFromHotkey()
    if InteractionRestoreTick < NoClipToggleGateTick then
        Diag("F7 flight toggle dropped reason=key-repeat tick=%s gate=%s",
            tostring(InteractionRestoreTick), tostring(NoClipToggleGateTick))
        return false
    end
    NoClipToggleGateTick = InteractionRestoreTick + 2

    local ok = SetNoClipMode("TOGGLE", NoClipSpeed)
    if ok then
        SendUiControl(NoClipEnabled and "FLIGHT_ON" or "FLIGHT_OFF_HOTKEY")
        Diag("F7 flight toggle complete enabled=%s speed=%.2f",
            tostring(NoClipEnabled), tonumber(NoClipSpeed) or 3.0)
    end
    return ok
end

-- ==========================================
-- BATCH NPC PULL (loaded GothicCharacter actors only)
-- ==========================================
local NPC_PULL_MAX = 20
local NPC_PULL_SPOT_RADIUS = 300.0
local NPC_PULL_VERIFY_TOLERANCE = 150.0

local function WriteNpcPullStatus(state, requestId, requested, moved, failed, duplicate, message)
    pcall(function()
        local file = io.open(NpcPullStatusFileName, "w")
        if file then
            file:write("STATE=" .. StatusClean(state or "UNKNOWN") .. "\n")
            file:write("REQUEST_ID=" .. StatusClean(requestId or "") .. "\n")
            file:write("REQUESTED=" .. tostring(requested or 0) .. "\n")
            file:write("MOVED=" .. tostring(moved or 0) .. "\n")
            file:write("FAILED=" .. tostring(failed or 0) .. "\n")
            file:write("DUPLICATE=" .. tostring(duplicate or 0) .. "\n")
            file:write("MESSAGE=" .. StatusClean(message or "") .. "\n")
            file:write("UPDATED=" .. tostring(os.time()) .. "\n")
            file:close()
        end
    end)
end

local function SplitNpcPullTsv(line, expected)
    local fields = {}
    local startAt = 1
    while #fields < expected - 1 do
        local tabAt = line:find("\t", startAt, true)
        if not tabAt then break end
        table.insert(fields, line:sub(startAt, tabAt - 1))
        startAt = tabAt + 1
    end
    table.insert(fields, line:sub(startAt))
    while #fields < expected do table.insert(fields, "") end
    return fields
end

local function ReadNpcPullRequests(requestId)
    local file = io.open(NpcPullRequestFileName, "r")
    if not file then return nil, "REQUEST_FILE_MISSING" end

    local rows = {}
    for line in file:lines() do
        if line ~= "" and not line:match("^RequestId\t") then
            local fields = SplitNpcPullTsv(line, 8)
            if fields[1] == requestId then
                table.insert(rows, {
                    RequestId = fields[1],
                    Source = tostring(fields[2] or ""):upper(),
                    Name = fields[3] or "",
                    X = tonumber(fields[4]),
                    Y = tonumber(fields[5]),
                    Z = tonumber(fields[6]),
                    FullName = fields[7] or "",
                    Key = fields[8] or "",
                })
            end
        end
    end
    file:close()

    if #rows == 0 then return nil, "REQUEST_ID_NOT_FOUND" end
    if #rows > NPC_PULL_MAX then return nil, "BATCH_LIMIT" end
    return rows, nil
end

local function NewNpcPullResult(request, outcome, reason)
    return {
        RequestId = request.RequestId,
        Source = request.Source,
        Name = request.Name,
        Outcome = outcome or "FAILED",
        Reason = reason or "UNKNOWN",
        ResolvedFullName = "",
        TargetX = nil,
        TargetY = nil,
        TargetZ = nil,
    }
end

local function WriteNpcPullResults(results)
    local ok, err = pcall(function()
        local file = io.open(NpcPullResultFileName, "w")
        if not file then error("cannot open " .. NpcPullResultFileName) end
        file:write("RequestId\tSource\tName\tOutcome\tReason\tResolvedFullName\tTargetX\tTargetY\tTargetZ\n")
        for _, result in ipairs(results or {}) do
            file:write(string.format(
                "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                Tsv(result.RequestId),
                Tsv(result.Source),
                Tsv(result.Name),
                Tsv(result.Outcome),
                Tsv(result.Reason),
                Tsv(result.ResolvedFullName),
                result.TargetX and string.format("%.2f", result.TargetX) or "",
                result.TargetY and string.format("%.2f", result.TargetY) or "",
                result.TargetZ and string.format("%.2f", result.TargetZ) or ""
            ))
        end
        file:close()
    end)
    return ok, err
end

local function NpcStableIdentity(fullName)
    fullName = tostring(fullName or "")
    local id = fullName:match("^Character_([^%s/:]+)")
        or fullName:match("[%.:]Character_([^%s/:]+)")
    if id then
        id = id:gsub("%-.*$", "")
        id = id:gsub("_C_%d+$", "")
        if id ~= "" then return id end
    end
    local clean = fullName:gsub("_C_%d+$", ""):gsub("_%d+$", "")
    if clean ~= "" then return clean end
    return nil
end

local function PullSpotNameMatches(request, candidate)
    local requestAscii = NormalizeNpcLookupKey(request.Name)
    local requestText = NormalizeSavedNpcNameText(request.Name):lower()
    local tokens = { candidate.Key, candidate.Name, ShortObjectName(candidate.FullName) }
    for _, token in ipairs(tokens) do
        local ascii = NormalizeNpcLookupKey(token)
        if #ascii >= 3 and requestAscii:find(ascii, 1, true) then return true end
        local text = NormalizeSavedNpcNameText(token):lower()
        if #text >= 3 and requestText:find(text, 1, true) then return true end
    end
    return false
end

local function BuildNpcPullCandidates(playerPawn)
    local okList, list = pcall(function() return FindAllOf("GothicCharacter") end)
    if not okList or not list then
        okList, list = pcall(function() return FindAllOf("Character") end)
    end
    if not okList or not list then return nil, "CHARACTER_SCAN_FAILED" end

    local playerId = ObjectIdentity(playerPawn)
    local candidates = {}
    for _, actor in ipairs(list) do
        if IsValidObject(actor) and ObjectIdentity(actor) ~= playerId then
            local location = ReadEngineLocation(actor)
            if location then
                local fullName = ObjectFullName(actor)
                local name, key = NpcDisplayName(fullName)
                table.insert(candidates, {
                    Actor = actor,
                    ObjectId = ObjectIdentity(actor),
                    FullName = fullName,
                    StableId = NpcStableIdentity(fullName),
                    Location = location,
                    Name = name,
                    Key = key,
                })
            end
        end
    end
    return candidates, nil
end

local function ResolveNpcPullRequest(request, candidates)
    if request.Source == "SPOT" then
        if not request.X or not request.Y or not request.Z then
            return nil, "SPOT_COORDINATES_INVALID"
        end
        local origin = { X=request.X, Y=request.Y, Z=request.Z }
        local radiusSq = NPC_PULL_SPOT_RADIUS * NPC_PULL_SPOT_RADIUS
        local matches = {}
        for _, candidate in ipairs(candidates) do
            local distanceSq = DistSq(origin, candidate.Location)
            if distanceSq and distanceSq <= radiusSq and PullSpotNameMatches(request, candidate) then
                table.insert(matches, candidate)
            end
        end
        if #matches == 1 then return matches[1], nil end
        if #matches > 1 then return nil, "SPOT_AMBIGUOUS" end
        return nil, "SPOT_NO_MATCH"
    end

    local exact = {}
    for _, candidate in ipairs(candidates) do
        if request.FullName ~= "" and candidate.FullName == request.FullName then
            table.insert(exact, candidate)
        end
    end
    if #exact == 1 then return exact[1], nil end
    if #exact > 1 then return nil, "AMBIGUOUS_EXACT_NAME" end

    local stableId = NpcStableIdentity(request.FullName)
    if stableId then
        local stable = {}
        for _, candidate in ipairs(candidates) do
            if candidate.StableId == stableId then table.insert(stable, candidate) end
        end
        if #stable == 1 then return stable[1], nil end
        if #stable > 1 then return nil, "AMBIGUOUS_IDENTITY" end
    end
    return nil, "TARGET_NOT_LOADED"
end

local function BuildNpcPullLocations(playerLocation, viewYaw, count)
    local locations = {}
    if count <= 0 then return locations end
    if count == 1 then
        local yaw = math.rad(viewYaw)
        table.insert(locations, {
            X = playerLocation.X + math.cos(yaw) * 220.0,
            Y = playerLocation.Y + math.sin(yaw) * 220.0,
            Z = playerLocation.Z,
        })
        return locations
    end

    local capacities = { 5, 7, 8 }
    local radii = { 260.0, 450.0, 640.0 }
    local remaining = count
    for ring = 1, #capacities do
        if remaining <= 0 then break end
        local ringCount = math.min(remaining, capacities[ring])
        local halfSpan = math.min(80.0, math.max(0.0, (ringCount - 1) * 20.0))
        for i = 1, ringCount do
            local offset = 0.0
            if ringCount > 1 then
                offset = -halfSpan + ((i - 1) * ((halfSpan * 2.0) / (ringCount - 1)))
            end
            local yaw = math.rad(viewYaw + offset)
            table.insert(locations, {
                X = playerLocation.X + math.cos(yaw) * radii[ring],
                Y = playerLocation.Y + math.sin(yaw) * radii[ring],
                Z = playerLocation.Z,
            })
        end
        remaining = remaining - ringCount
    end
    return locations
end

local function NpcPullLocationMatches(actor, target)
    local actual, source = ReadEngineLocation(actor)
    local distanceSq = DistSq(actual, target)
    if not distanceSq then return false, actual, source end
    return distanceSq <= (NPC_PULL_VERIFY_TOLERANCE * NPC_PULL_VERIFY_TOLERANCE), actual, source
end

local NpcPullUFunctionCache = {}

local function FindNpcPullUFunction(path)
    local cached = NpcPullUFunctionCache[path]
    if cached ~= nil then return cached or nil end

    for _, candidate in ipairs({path, "Function " .. path}) do
        local okFind, fn = pcall(function() return StaticFindObject(candidate) end)
        if okFind and IsValidObject(fn) then
            NpcPullUFunctionCache[path] = fn
            return fn
        end
    end

    NpcPullUFunctionCache[path] = false
    return nil
end

local function CallNpcPullUFunction(actor, path, ...)
    local fn = FindNpcPullUFunction(path)
    if not IsValidObject(fn) then return false, "function-not-found:" .. path, "not-found" end
    local args = {...}

    local okInvoke, invokeResult = pcall(function()
        return fn(actor, table.unpack(args))
    end)
    if okInvoke and invokeResult ~= false then
        return true, invokeResult, "FunctionObject"
    end

    local okCall, callResult = pcall(function()
        return actor:CallFunction(fn, table.unpack(args))
    end)
    if okCall then
        return true, callResult, "Object.CallFunction"
    end

    return okInvoke,
        string.format("function-object=%s object-call=%s", tostring(invokeResult), tostring(callResult)),
        okInvoke and "FunctionObject/rejected" or "failed"
end

local function TryPullNpcActor(actor, target)
    if not IsValidObject(actor) then return false, "ACTOR_INVALID" end
    local rotation = ReadActorRotation(actor)
    local errors = {}
    local function compact_error(value)
        local text = tostring(value or "")
        text = text:gsub("[\r\n\t]+", " ")
        text = text:gsub("%s+", " ")
        if #text > 280 then
            text = text:sub(1, 277) .. "..."
        end
        return text
    end

    local okCallTeleport, callTeleportResult, callTeleportRoute = CallNpcPullUFunction(
        actor, "/Script/Engine.Actor:K2_TeleportTo", target, rotation)
    local matched = NpcPullLocationMatches(actor, target)
    if matched then return true, "FORCED/" .. tostring(callTeleportRoute) .. "/K2_TeleportTo" end
    table.insert(errors, string.format("callTeleport=%s:%s",
        tostring(okCallTeleport), compact_error(callTeleportResult)))

    local okCallSet, callSetResult, callSetRoute = CallNpcPullUFunction(
        actor, "/Script/Engine.Actor:K2_SetActorLocation", target, false, {}, true)
    matched = NpcPullLocationMatches(actor, target)
    if matched then
        return true, "FORCED/" .. tostring(callSetRoute) .. "/K2_SetActorLocation/TeleportPhysics"
    end
    table.insert(errors, string.format("callSet=%s:%s",
        tostring(okCallSet), compact_error(callSetResult)))

    local okRoot, root = pcall(function() return actor.RootComponent end)
    if okRoot and IsValidObject(root) then
        local okRootCall, rootCallResult, rootCallRoute = CallNpcPullUFunction(
            root, "/Script/Engine.SceneComponent:K2_SetWorldLocation", target, false, {}, true)
        matched = NpcPullLocationMatches(actor, target)
        if matched then
            return true, "FORCED/" .. tostring(rootCallRoute) .. "/Root.K2_SetWorldLocation/TeleportPhysics"
        end
        table.insert(errors, string.format("callRoot=%s:%s",
            tostring(okRootCall), compact_error(rootCallResult)))
    else
        table.insert(errors, "callRoot=false:root-invalid")
    end

    local legacyDescriptor = {Id = "npc-pull-force", StepIndex = 1, TotalSteps = 1}
    local okLegacy, _, _, legacyResult = TryMoveLegacyRootLocation(legacyDescriptor, actor, target)
    matched = NpcPullLocationMatches(actor, target)
    if okLegacy and matched then
        return true, "FORCED/" .. tostring(legacyResult)
    end
    table.insert(errors, "legacyRoot=" .. tostring(okLegacy) .. ":" .. compact_error(legacyResult))

    local okTeleport, teleportResult = pcall(function()
        return actor:K2_TeleportTo(target, rotation)
    end)
    matched = NpcPullLocationMatches(actor, target)
    if matched then return true, "K2_TeleportTo" end
    table.insert(errors, string.format("dynamicTeleport=%s:%s",
        tostring(okTeleport), compact_error(teleportResult)))

    local okSet, setResult = pcall(function()
        return actor:K2_SetActorLocation(target, false, nil, true)
    end)
    matched = NpcPullLocationMatches(actor, target)
    if matched then return true, "K2_SetActorLocation/TeleportPhysics" end
    table.insert(errors, string.format("dynamicSet=%s:%s",
        tostring(okSet), compact_error(setResult)))

    return false, "MOVE_REJECTED " .. table.concat(errors, " | ")
end

local function RotationYaw(rotation)
    if not rotation then return nil end
    return tonumber(rotation.Yaw)
end

local function ReadPlayerViewYaw(playerController, playerPawn)
    if IsValidObject(playerController) then
        local cameraManager = nil
        pcall(function() cameraManager = playerController.PlayerCameraManager end)
        if IsValidObject(cameraManager) then
            local okCameraRotation, cameraRotation = pcall(function()
                return cameraManager:GetCameraRotation()
            end)
            local yaw = okCameraRotation and RotationYaw(cameraRotation) or nil
            if yaw then return yaw, "PlayerCameraManager.GetCameraRotation" end

            local okPrivate, privateRotation = pcall(function()
                return cameraManager.CameraCachePrivate.POV.Rotation
            end)
            yaw = okPrivate and RotationYaw(privateRotation) or nil
            if yaw then return yaw, "PlayerCameraManager.CameraCachePrivate" end

            local okCache, cacheRotation = pcall(function()
                return cameraManager.CameraCache.POV.Rotation
            end)
            yaw = okCache and RotationYaw(cacheRotation) or nil
            if yaw then return yaw, "PlayerCameraManager.CameraCache" end
        end

        local okControl, controlRotation = pcall(function()
            return playerController:GetControlRotation()
        end)
        local yaw = okControl and RotationYaw(controlRotation) or nil
        if yaw then return yaw, "PlayerController.GetControlRotation" end

        local okProperty, propertyRotation = pcall(function()
            return playerController.ControlRotation
        end)
        yaw = okProperty and RotationYaw(propertyRotation) or nil
        if yaw then return yaw, "PlayerController.ControlRotation" end
    end

    local pawnRotation = ReadActorRotation(playerPawn)
    return RotationYaw(pawnRotation) or 0.0, "PlayerPawn.ActorRotation"
end

local function PullNpcsToPlayer(requestId)
    requestId = Trim(requestId or "")
    if requestId == "" then
        WriteNpcPullResults({})
        WriteNpcPullStatus("FAILED", "", 0, 0, 0, 0, "REQUEST_ID_MISSING")
        return false
    end

    local requests, requestError = ReadNpcPullRequests(requestId)
    if not requests then
        WriteNpcPullResults({})
        WriteNpcPullStatus("FAILED", requestId, 0, 0, 0, 0, requestError)
        Diag("npc_pull request rejected id=%s reason=%s", tostring(requestId), tostring(requestError))
        return false
    end

    WriteNpcPullStatus("BUSY", requestId, #requests, 0, 0, 0, "RESOLVING")
    local results = {}

    local function fail_all(reason)
        for _, request in ipairs(requests) do
            table.insert(results, NewNpcPullResult(request, "FAILED", reason))
        end
        WriteNpcPullResults(results)
        WriteNpcPullStatus("FAILED", requestId, #requests, 0, #requests, 0, reason)
        Diag("npc_pull failed id=%s requested=%s reason=%s", tostring(requestId), tostring(#requests), tostring(reason))
        return false
    end

    if NoClipEnabled then return fail_all("FREE_FLIGHT_ENABLED") end

    local playerPawn, playerSource, playerController = GetPlayerPawn()
    if not IsValidObject(playerPawn) then return fail_all("PLAYER_UNAVAILABLE") end
    local playerLocation, locationSource = ReadEngineLocation(playerPawn)
    if not playerLocation then return fail_all("PLAYER_LOCATION_UNAVAILABLE") end
    local viewYaw, viewYawSource = ReadPlayerViewYaw(playerController, playerPawn)

    local candidates, candidateError = BuildNpcPullCandidates(playerPawn)
    if not candidates then return fail_all(candidateError or "CHARACTER_SCAN_FAILED") end

    local seenActors = {}
    local resolved = {}
    local duplicateCount = 0
    local failedCount = 0
    for _, request in ipairs(requests) do
        local result = NewNpcPullResult(request, "PENDING", "")
        table.insert(results, result)
        local candidate, resolveError = ResolveNpcPullRequest(request, candidates)
        if not candidate then
            result.Outcome = "FAILED"
            result.Reason = resolveError or "TARGET_NOT_LOADED"
            failedCount = failedCount + 1
            Diag("npc_pull item failed id=%s name=%s stage=resolve reason=%s",
                tostring(requestId), tostring(request.Name), tostring(result.Reason))
        elseif seenActors[candidate.ObjectId] then
            result.Outcome = "DUPLICATE"
            result.Reason = "DUPLICATE_TARGET"
            result.ResolvedFullName = candidate.FullName
            duplicateCount = duplicateCount + 1
        else
            seenActors[candidate.ObjectId] = true
            result.ResolvedFullName = candidate.FullName
            table.insert(resolved, { Candidate=candidate, Result=result })
        end
    end

    local targets = BuildNpcPullLocations(playerLocation, viewYaw, #resolved)
    local movedCount = 0
    for index, item in ipairs(resolved) do
        local target = targets[index]
        item.Result.TargetX = target and target.X or nil
        item.Result.TargetY = target and target.Y or nil
        item.Result.TargetZ = target and target.Z or nil
        if not target then
            item.Result.Outcome = "FAILED"
            item.Result.Reason = "TARGET_SLOT_MISSING"
            failedCount = failedCount + 1
        else
            local moved, moveReason = TryPullNpcActor(item.Candidate.Actor, target)
            if moved then
                item.Result.Outcome = "MOVED"
                item.Result.Reason = moveReason or "OK"
                movedCount = movedCount + 1
            else
                item.Result.Outcome = "FAILED"
                item.Result.Reason = moveReason or "MOVE_REJECTED"
                failedCount = failedCount + 1
                Diag("npc_pull item failed id=%s name=%s stage=move actor=%s reason=%s",
                    tostring(requestId), tostring(item.Result.Name), tostring(item.Candidate.FullName),
                    tostring(item.Result.Reason))
            end
        end
    end

    local wrote, writeError = WriteNpcPullResults(results)
    if not wrote then
        WriteNpcPullStatus("FAILED", requestId, #requests, movedCount, failedCount, duplicateCount,
            "RESULT_WRITE_FAILED")
        Diag("npc_pull result write failed id=%s error=%s", tostring(requestId), tostring(writeError))
        return false
    end

    WriteNpcPullStatus("DONE", requestId, #requests, movedCount, failedCount, duplicateCount, "COMPLETE")
    Diag("npc_pull done id=%s requested=%s moved=%s failed=%s duplicate=%s player=%s source=%s locSource=%s viewYaw=%.1f viewSource=%s",
        tostring(requestId), tostring(#requests), tostring(movedCount), tostring(failedCount),
        tostring(duplicateCount), ObjectFullName(playerPawn), tostring(playerSource), tostring(locationSource),
        tonumber(viewYaw) or 0.0, tostring(viewYawSource))
    return true
end

-- ==========================================
-- WORLD FREEZE (completely independent, one-shot, NO tick reapplication)
-- Restores the 11:23 version that user confirmed working.
-- Sets slomo + CustomTimeDilation ONCE on toggle, never repeats.
-- ==========================================
local WorldFreezeEnabled = false

local function SetWorldFreeze(enable)
    WorldFreezeEnabled = (enable == true or enable == "1" or enable == 1 or
                          (enable == "TOGGLE" and not WorldFreezeEnabled))
    pcall(function()
        local pawn, _, pc = GetPlayerPawn()
        local targetGlobal = WorldFreezeEnabled and 0.0001 or 1.0
        local targetPlayer = WorldFreezeEnabled and 10000.0 or 1.0
        -- Method 1: SetGlobalTimeDilation via GameplayStatics
        pcall(function()
            local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if IsValidObject(statics) and IsValidObject(pawn) then
                statics:SetGlobalTimeDilation(pawn, targetGlobal)
            end
        end)
        -- Method 2: WorldSettings.TimeDilation direct
        pcall(function()
            if IsValidObject(pawn) then
                local ws = pawn:GetWorldSettings()
                if IsValidObject(ws) then ws.TimeDilation = targetGlobal end
            end
        end)
        -- Method 3: slomo console command
        pcall(function()
            if IsValidObject(pc) then
                pc:ConsoleCommand("slomo " .. tostring(targetGlobal))
            end
        end)
        -- Compensate player speed so ONLY player moves normally
        pcall(function()
            if IsValidObject(pawn) then
                pawn.CustomTimeDilation = targetPlayer
            end
        end)
    end)
    print(string.format("[WorldFreeze] %s\n", tostring(WorldFreezeEnabled)))
end

-- ==========================================
-- CLOCK FREEZE (completely independent, one-shot, no tick)
-- ==========================================
local ClockFreezeEnabled = false

local function SetClockFreeze(enable)
    ClockFreezeEnabled = (enable == true or enable == "1" or enable == 1 or
                          (enable == "TOGGLE" and not ClockFreezeEnabled))
    pcall(function()
        local sys = FindFirstOf("GameTimeSubsystem")
        if IsValidObject(sys) then
            sys.bFreeze = ClockFreezeEnabled
        end
    end)
    print(string.format("[ClockFreeze] %s\n", tostring(ClockFreezeEnabled)))
end

-- ==========================================
-- TIME ADVANCE (completely independent)
-- ==========================================
local function AdvanceTimeHours(hours)
    local h = tonumber(hours) or 1
    pcall(function()
        local sys = FindFirstOf("GameTimeSubsystem")
        if IsValidObject(sys) and sys.Current then
            sys.Current = sys.Current + (h * 3600.0)
        end
    end)
    print(string.format("[TimeAdvance] +%s hours\n", tostring(h)))
end

local function HasUnknownTeleportHooks()
    for _, candidate in ipairs(TeleportHookCandidates) do
        if not TeleportHooks[candidate.Path] and not TeleportHookFailures[candidate.Path] then
            return true
        end
    end
    return false
end

local function MaybeRetryTeleportHooks()
    if not HasUnknownTeleportHooks() then return end
    local now = os.time()
    if (now - LastHookRetry) < 2 then return end
    LastHookRetry = now
    EnsureTeleportHooks("retry")
end

local function TickPendingTeleport()
    if PendingTeleport then
        AttemptPendingTeleport("poll", nil)
        return
    end

    local now = os.clock()
    if now < TeleportCooldownUntil then
        if TeleportStatusState ~= "COOLDOWN" then
            WriteStatus("COOLDOWN", string.format("cooldown %.1fs", TeleportCooldownUntil - now), nil)
        end
    elseif TeleportStatusState ~= "IDLE" then
        WriteStatus("IDLE", "ready", nil)
    end
end

local function BuildTeleportSteps(startLoc, finalLoc)
    local steps = {}
    local distance = Distance(startLoc, finalLoc) or 0
    local count = 1
    if distance > SAFE_DIRECT_DISTANCE then
        count = math.ceil(distance / SAFE_STEP_DISTANCE)
        if count < 1 then count = 1 end
    end

    for i = 1, count do
        local t = i / count
        table.insert(steps, {
            X = startLoc.X + ((finalLoc.X - startLoc.X) * t),
            Y = startLoc.Y + ((finalLoc.Y - startLoc.Y) * t),
            Z = startLoc.Z + ((finalLoc.Z - startLoc.Z) * t),
        })
    end
    return steps, distance
end

local function RejectTeleport(source, name, reason)
    Diag("REJECT source=%s name=%s reason=%s", tostring(source), tostring(name), tostring(reason))
    WriteStatus(TeleportStatusState == "COOLDOWN" and "COOLDOWN" or "BUSY", reason, PendingTeleport)
    print(string.format("[TP] Teleport ignored: %s\n", tostring(reason)))
end

local function TeleportTo(x, y, z, name, source)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return end
    if x ~= x or y ~= y or z ~= z then return end  -- NaN check

    if PendingTeleport then
        RejectTeleport(source, name, "busy")
        return
    end

    local now = os.clock()
    if now < TeleportCooldownUntil then
        WriteStatus("COOLDOWN", string.format("cooldown %.1fs", TeleportCooldownUntil - now), nil)
        RejectTeleport(source, name, "cooldown")
        return
    end

    local actor, actorSource = ResolveActorFromHook("request", nil)
    if not IsValidObject(actor) then
        Diag("REJECT source=%s name=%s reason=%s", tostring(source), tostring(name), tostring(actorSource))
        WriteStatus("FAILED", actorSource or "actor-invalid", nil)
        return
    end

    local startLoc, startSource = ReadEngineLocation(actor)
    if not startLoc then
        Diag("REJECT source=%s name=%s reason=%s", tostring(source), tostring(name), tostring(startSource))
        WriteStatus("FAILED", startSource or "location-unreadable", nil)
        return
    end

    local finalLoc = {X=x, Y=y, Z=z}
    local _, distance = BuildTeleportSteps(startLoc, finalLoc)
    local steps = { finalLoc }

    TeleportRequestId = TeleportRequestId + 1
    PendingTeleport = {
        Id = TeleportRequestId,
        X = x, Y = y, Z = z,
        Final = finalLoc,
        Start = startLoc,
        Steps = steps,
        StepIndex = 1,
        TotalSteps = #steps,
        Distance = distance,
        Name = name,
        Source = source or "unknown",
        CreatedAt = now,
        TimeoutAt = now + LEGACY_DIRECT_TIMEOUT,
        NextStepAt = now,
        Mode = "LEGACY_DIRECT",
        CooldownSeconds = LEGACY_DIRECT_COOLDOWN,
        Attempts = 0,
    }

    Diag("REQUEST id=%s source=%s name=%s mode=legacy-direct start[%s]=%s target=%s distance=%.1f steps=%s",
        tostring(PendingTeleport.Id), tostring(PendingTeleport.Source), tostring(name),
        tostring(startSource), VectorText(startLoc), VectorText(PendingTeleport.Final),
        distance, tostring(PendingTeleport.TotalSteps))
    WriteStatus("BUSY", "legacy direct teleport", PendingTeleport)
    TickPendingTeleport()
end
local function TeleportToIndex(index)
    local s = TeleportSpots[index]
    if s then TeleportTo(s.X, s.Y, s.Z, s.Name, "index:" .. tostring(index)) end
end

local function TeleportToName(name)
    local idx = FindSpotIndexByName(name)
    if idx then TeleportToIndex(idx) end
end

-- Numpad teleport: write directly to CppBridge actions file.
-- This is the exact same mechanism the UI double-click uses.
-- No PID checks, no process management, no Lua fallback needed.
-- CppBridge is a persistent process (launched by UI) that polls this file every 200ms.
local function TeleportToNumpadBinding(keyNumber)
    local binding = NumpadBindings[keyNumber]
    if not binding then
        print(string.format("[TP] Numpad %s not bound.\n", tostring(keyNumber)))
        return
    end

    local xStr = string.format("%.0f", tonumber(binding.X) or 0)
    local yStr = string.format("%.0f", tonumber(binding.Y) or 0)
    local zStr = string.format("%.0f", tonumber(binding.Z) or 0)
    local safeName = tostring(binding.Name or "numpad"):gsub("[|\r\n]", "_")
    local line = string.format("TELEPORT_COORD|%s|%s|%s|%s\n", xStr, yStr, zStr, safeName)

    local ok, err = pcall(function()
        local file = io.open(CppActionsFileName, "a")
        if not file then error("cannot open " .. CppActionsFileName) end
        file:write(line)
        file:close()
    end)
    if ok then
        Diag("numpad:%d -> cpp_actions: %s", keyNumber, Trim(line))
    else
        Diag("numpad:%d file write FAILED: %s, trying Lua fallback", keyNumber, tostring(err))
        TeleportTo(binding.X, binding.Y, binding.Z, binding.Name, "numpad:" .. tostring(keyNumber))
    end
end

local function DeleteSpot(index)
    if index < 1 or index > #TeleportSpots then return end
    local name = TeleportSpots[index].Name
    table.remove(TeleportSpots, index)
    RebuildAutoIndex()
    SaveSpots()
    print(string.format("[TP] Deleted: %s\n", name))
end

local function RenameSpot(index, newName)
    if index < 1 or index > #TeleportSpots then return end
    newName = NormalizeName(newName)
    if newName == "" then return end
    TeleportSpots[index].Name = newName
    RebuildAutoIndex()
    SaveSpots()
    print(string.format("[TP] Renamed: [%d] %s\n", index, newName))
end

local function MoveSpot(index, targetIndex)
    if index < 1 or index > #TeleportSpots then return end
    if targetIndex < 1 then targetIndex = 1
    elseif targetIndex > #TeleportSpots then targetIndex = #TeleportSpots end
    if index == targetIndex then return end
    local spot = table.remove(TeleportSpots, index)
    table.insert(TeleportSpots, targetIndex, spot)
    RebuildAutoIndex()
    SaveSpots()
    print(string.format("[TP] Moved: %s -> %d\n", spot.Name, targetIndex))
end

local function ListSpots()
    if #TeleportSpots == 0 then
        print("[TP] No saved spots. Press F1 to save current position.\n")
        return
    end
    print(string.format("[TP] %d spots, auto-index at Spot_%d.\n", #TeleportSpots, SpotAutoIndex + 1))
    for i, s in ipairs(TeleportSpots) do
        print(string.format("  [%d] %s (%.0f, %.0f, %.0f)\n", i, s.Name, s.X, s.Y, s.Z))
    end
end

local function ProcessActionLine(line)
    local parts = {}
    for part in (line .. "|"):gmatch("(.-)|") do
        table.insert(parts, part)
    end
    local cmd = (parts[1] or ""):upper()
    if cmd == "TELEPORT_INDEX" or cmd == "TP_INDEX" then
        local idx = tonumber(parts[2])
        if idx then TeleportToIndex(idx) end
    elseif cmd == "TELEPORT_COORD" or cmd == "TP_COORD" then
        local x = tonumber(parts[2])
        local y = tonumber(parts[3])
        local z = tonumber(parts[4])
        if x and y and z then TeleportTo(x, y, z, parts[5], cmd) end
    elseif cmd == "TELEPORT_NAME" or cmd == "TP_NAME" then
        TeleportToName(Trim(parts[2] or ""))
    elseif cmd == "SAVE" or cmd == "SAVE_CURRENT_POS" then
        SaveCurrentPos(parts[2] or "")
    elseif cmd == "OVERWRITE" then
        local idx = tonumber(parts[2])
        if idx then OverwriteSpot(idx, parts[3] or "") end
    elseif cmd == "RENAME" then
        local idx = tonumber(parts[2])
        if idx then RenameSpot(idx, parts[3] or "") end
    elseif cmd == "DELETE" then
        local idx = tonumber(parts[2])
        if idx then DeleteSpot(idx) end
    elseif cmd == "MOVE" or cmd == "MOVE_TO" then
        local idx = tonumber(parts[2])
        local targetIdx = tonumber(parts[3])
        if idx and targetIdx then MoveSpot(idx, targetIdx) end
    elseif cmd == "RELOAD" or cmd == "RELOAD_SPOTS" then
        LoadSpots()
        print(string.format("[TP] Reloaded spots: %d\n", #TeleportSpots))
    elseif cmd == "RELOAD_HOTKEYS" then
        LoadNumpadBindings()
        print("[TP] Reloaded numpad bindings.\n")
    elseif cmd == "SCAN_NEARBY_NPCS" or cmd == "SCAN_NEARBY_CHARACTERS" then
        BeginNearbyNpcScan(parts[2] or "")
    elseif cmd == "PULL_NPCS" then
        PullNpcsToPlayer(parts[2] or "")
    elseif cmd == "NOCLIP" then
        SetNoClipMode(parts[2], parts[3])
    elseif cmd == "NOCLIP_SPEED" then
        SetNoClipSpeed(parts[2])
    elseif cmd == "NOCLIP_PROBE" then
        ProbeNoClipState("ui-action")
    elseif cmd == "NOCLIP_REFRESH" then
        RefreshNoClipState(parts[2] or "external")
    elseif cmd == "WORLD_FREEZE" then
        SetWorldFreeze(parts[2])
    elseif cmd == "CLOCK_FREEZE" or cmd == "TIME_FREEZE" then
        SetClockFreeze(parts[2])
    elseif cmd == "TIME_ADVANCE" then
        AdvanceTimeHours(parts[2])
    elseif cmd == "UI_CLOSED" then
        ClearUiActiveFlag()
        ClearUiControlFile()
        Diag("ui closed notification received pid=%s", tostring(parts[2] or ""))
    elseif cmd == "LIST" then
        ListSpots()
    elseif cmd ~= "" then
        print(string.format("[TP] Unknown action: %s\n", cmd))
    end
end

local function ProcessQueuedActions()
    local file = io.open(ActionFileName, "r")
    if not file then return end
    local lines = {}
    for line in file:lines() do
        if line and line ~= "" then table.insert(lines, line) end
    end
    file:close()
    if #lines > 0 then
        for _, line in ipairs(lines) do
            local ok, err = pcall(ProcessActionLine, line)
            if not ok then
                print(string.format("[TP] Action failed: %s | Error: %s\n", line, tostring(err)))
            end
        end
        pcall(function()
            local clear = io.open(ActionFileName, "w")
            if clear then clear:close() end
        end)
    end
end

---------------------------------------------------------------------------
-- Hot-reload core API
---------------------------------------------------------------------------
local Core = {}

function Core.Init(reason)
    -- CRITICAL: Reset all world control states on reload.
    -- Without this, Ctrl+R with WorldFreeze active = slomo 0.0001 persists = game appears frozen.
    pcall(function()
        local pawn, _, pc = GetPlayerPawn()
        -- Restore slomo to normal (fixes "卡死" on Ctrl+R with WorldFreeze active)
        pcall(function()
            if IsValidObject(pc) then pc:ConsoleCommand("slomo 1") end
        end)
        pcall(function()
            if IsValidObject(pawn) then
                local ws = pawn:GetWorldSettings()
                if IsValidObject(ws) then ws.TimeDilation = 1.0 end
            end
        end)
        pcall(function()
            local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if IsValidObject(statics) and IsValidObject(pawn) then
                statics:SetGlobalTimeDilation(pawn, 1.0)
            end
        end)
        -- Restore player time
        pcall(function()
            if IsValidObject(pawn) then pawn.CustomTimeDilation = 1.0 end
        end)
        -- Restore collision + walking in case the previous hot-loaded core left NoClip active.
        RestoreNoClipState(pawn, pc, true)
    end)
    -- Reset module-level flags
    NoClipEnabled = false
    NoClipSpeed = 3.0
    NoClipOriginal = nil
    PendingInteractionRestore = nil
    InteractionRestoreTick = 0
    WorldFreezeEnabled = false
    ClockFreezeEnabled = false

    if reason == "startup" then
        ResetDiag()
        ClearUiActiveFlag()
    else
        Diag("core reload requested reason=%s version=%s", tostring(reason), MOD_VERSION)
    end
    NativeBridgeLaunchRequested = false
    EnsureCppBridgeStarted(reason)
    WriteStatus("IDLE", "core ready " .. MOD_VERSION, nil)
    LoadSpots()
    LoadNumpadBindings()
    Diag("core ready reason=%s version=%s spots=%s", tostring(reason), MOD_VERSION, tostring(#TeleportSpots))
    print(string.format("[TeleportMod core v%s] %d spots loaded\n", MOD_VERSION, #TeleportSpots))
end

function Core.Tick()
    InteractionRestoreTick = InteractionRestoreTick + 1
    TickPendingInteractionRestore()
    TickPendingTeleport()
end

function Core.BeforeInteraction(context)
    return BeforeInteraction(context)
end

function Core.OnClientRestart(context)
    AttemptPendingTeleport("ClientRestart", context)
end

function Core.ProcessActionLine(line)
    ProcessActionLine(line)
end

function Core.SaveCurrentPos(name)
    SaveCurrentPos(name or "")
end

function Core.ListSpots()
    ListSpots()
end

function Core.LaunchTeleportUI()
    LaunchTeleportUI()
end

function Core.ToggleNoClip()
    return ToggleNoClipFromHotkey()
end

function Core.TeleportToNumpadBinding(keyNumber)
    TeleportToNumpadBinding(keyNumber)
end

function Core.ConsoleTp(params)
    params = Trim(params or "")
    local x, y, z = params:match("^([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)$")
    if x then
        TeleportTo(tonumber(x), tonumber(y), tonumber(z), nil, "console:tp")
        return
    end
    local idx = tonumber(params)
    if idx then
        TeleportToIndex(idx)
        return
    end
    if params ~= "" then
        TeleportToName(params)
    end
end

function Core.ConsoleTpCoord(params)
    params = Trim(params or "")
    local x, y, z = params:match("^([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)$")
    if x then TeleportTo(tonumber(x), tonumber(y), tonumber(z), nil, "console:tpcoord") end
end

function Core.SetSpot(params)
    params = Trim(params or "")
    local idx, name = params:match("^(%d+)%s*(.*)$")
    if idx then OverwriteSpot(tonumber(idx), name or "") end
end

function Core.RenameSpot(params)
    params = Trim(params or "")
    local idx, name = params:match("^(%d+)%s*(.*)$")
    if idx then RenameSpot(tonumber(idx), name or "") end
end

function Core.DeleteSpot(params)
    local idx = tonumber(Trim(params or ""))
    if idx then DeleteSpot(idx) end
end

return Core
