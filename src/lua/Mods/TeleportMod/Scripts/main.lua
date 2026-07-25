-- TeleportMod shell for Gothic 1 Remake v5.11-shell-f7-flight
-- Stable entrypoint: keybinds, console commands, action polling, hot core reload.
-- v5.6: Fix numpad teleport by routing key callbacks through game-thread queue.
--       RegisterKeyBindAsync runs callbacks on UE4SS input thread, NOT game thread.
--       Writing actor locations from input thread gets overwritten by next physics tick.
--       Solution: key callbacks push closures to GameThreadQueue, drained by LoopInGameThreadWithDelay.

local SHELL_VERSION = "5.11-shell-f7-flight"
local ACTION_FILE = "TeleportMod_actions.txt"
local DIAG_FILE = "TeleportMod_diag.txt"
local STATUS_FILE = "TeleportMod_status.txt"
local CORE_PATH = "Mods\\TeleportMod\\Scripts\\TeleportMod_core.lua"
local ENABLE_CLIENT_RESTART_HOOK = false

local Core = nil
local CoreLoadCount = 0
local Unpack = table.unpack or unpack
local InteractionHookRegistered = false

-- Queue for actions that MUST run on the game thread.
-- Key callbacks push closures here; the game-thread loop drains them.
local GameThreadQueue = {}

local NumKeyNames = {
    [1] = "NUM_ONE",   [2] = "NUM_TWO",   [3] = "NUM_THREE",
    [4] = "NUM_FOUR",  [5] = "NUM_FIVE",  [6] = "NUM_SIX",
    [7] = "NUM_SEVEN", [8] = "NUM_EIGHT", [9] = "NUM_NINE"
}

local function now_text()
    local ok, value = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    if ok and value then return value end
    return "unknown-time"
end

local function clean(value)
    value = tostring(value or "")
    value = value:gsub("[\r\n]", " ")
    return value
end

local function diag(fmt, ...)
    local args = { ... }
    local okFmt, msg = pcall(function() return string.format(fmt, Unpack(args)) end)
    if not okFmt then msg = tostring(fmt) end
    print("[TP-SHELL] " .. tostring(msg) .. "\n")
    pcall(function()
        local file = io.open(DIAG_FILE, "a")
        if file then
            file:write(string.format("[%s] [shell] %s\n", now_text(), tostring(msg)))
            file:close()
        end
    end)
end

local function write_status(state, message)
    pcall(function()
        local file = io.open(STATUS_FILE, "w")
        if file then
            file:write("STATE=" .. clean(state) .. "\n")
            file:write("MESSAGE=" .. clean(message) .. "\n")
            file:write("UPDATED=" .. tostring(os.time()) .. "\n")
            file:close()
        end
    end)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function command_name(line)
    local value = trim(line)
    local sep = value:find("|", 1, true)
    if sep then value = value:sub(1, sep - 1) end
    return string.upper(trim(value))
end

local function reload_core(reason)
    reason = reason or "manual"
    local previous = Core
    diag("loading core reason=%s path=%s", tostring(reason), CORE_PATH)

    local okLoad, loaded = pcall(function()
        return dofile(CORE_PATH)
    end)
    if not okLoad then
        diag("core load failed reason=%s error=%s", tostring(reason), tostring(loaded))
        write_status("FAILED", "core reload failed; old core kept")
        return false
    end
    if type(loaded) ~= "table" then
        diag("core load failed reason=%s error=core did not return table", tostring(reason))
        write_status("FAILED", "core reload failed; invalid core")
        return false
    end

    Core = loaded
    local okInit, initErr = pcall(function()
        if Core.Init then Core.Init(reason) end
    end)
    if not okInit then
        Core = previous
        diag("core init failed reason=%s error=%s", tostring(reason), tostring(initErr))
        write_status("FAILED", "core init failed; old core kept")
        return false
    end

    CoreLoadCount = CoreLoadCount + 1
    diag("core loaded reason=%s count=%s", tostring(reason), tostring(CoreLoadCount))
    write_status("IDLE", "core loaded " .. tostring(reason))
    return true
end

local function call_core(method, ...)
    if not Core then
        diag("core call skipped method=%s reason=no-core", tostring(method))
        write_status("FAILED", "core not loaded")
        return nil
    end
    local fn = Core[method]
    if type(fn) ~= "function" then
        diag("core call skipped method=%s reason=missing-method", tostring(method))
        write_status("FAILED", "core method missing: " .. tostring(method))
        return nil
    end
    local args = { ... }
    local ok, result = pcall(function()
        return fn(Unpack(args))
    end)
    if not ok then
        diag("core call failed method=%s error=%s", tostring(method), tostring(result))
        write_status("FAILED", "core call failed: " .. tostring(method))
        return nil
    end
    return result
end

local function process_action_line(line)
    local cmd = command_name(line)
    if cmd == "RELOAD_CORE" or cmd == "TP_RELOAD_CORE" or cmd == "TPRELOAD" then
        reload_core("action")
        return
    end
    call_core("ProcessActionLine", line)
end

local function process_queued_actions()
    local file = io.open(ACTION_FILE, "r")
    if not file then return end

    local lines = {}
    for line in file:lines() do
        if line and line ~= "" then table.insert(lines, line) end
    end
    file:close()
    if #lines == 0 then return end

    pcall(function()
        local clear = io.open(ACTION_FILE, "w")
        if clear then clear:close() end
    end)

    for _, line in ipairs(lines) do
        local ok, err = pcall(process_action_line, line)
        if not ok then
            diag("action failed line=%s error=%s", tostring(line), tostring(err))
            write_status("FAILED", "action failed")
        end
    end
end

-- Drain the game-thread queue: execute all pending closures from key callbacks
local function drain_game_thread_queue()
    while #GameThreadQueue > 0 do
        local action = table.remove(GameThreadQueue, 1)
        local ok, err = pcall(action)
        if not ok then
            diag("game-thread queue action failed: %s", tostring(err))
        end
    end
end

local function register_client_restart_hook()
    local ok, preId, postId = pcall(function()
        return RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self, ...)
            call_core("OnClientRestart", self)
        end, function(self, ...)
            call_core("Tick")
        end)
    end)
    if ok then
        diag("base hook registered ClientRestart pre=%s post=%s", tostring(preId), tostring(postId))
    else
        diag("base hook failed ClientRestart error=%s", tostring(preId))
    end
end

local function register_interaction_hook()
    if InteractionHookRegistered then return true end
    local path = "/Script/G1R.GameplayAbilityInteractionBase:OnPreTargetLocationReached"
    local ok, preId, postId = pcall(function()
        return RegisterHook(path, function(context, ...)
            call_core("BeforeInteraction", context)
        end, nil)
    end)
    if ok then
        InteractionHookRegistered = true
        diag("base hook registered BeforeInteraction pre=%s post=%s", tostring(preId), tostring(postId))
        return true
    end
    diag("base hook failed BeforeInteraction error=%s", tostring(preId))
    return false
end

if ClearAllDelayedActions then
    ClearAllDelayedActions()
end

reload_core("startup")
register_interaction_hook()
if ENABLE_CLIENT_RESTART_HOOK then
    register_client_restart_hook()
else
    diag("base hook skipped ClientRestart reason=cppbridge-stability")
end

if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(250, function()
        -- FIRST: drain key-callback queue (these MUST run on the game thread)
        drain_game_thread_queue()
        -- THEN: process file-based UI actions (also on game thread)
        process_queued_actions()
        call_core("Tick")
    end)
else
    diag("LoopInGameThreadWithDelay unavailable")
    write_status("FAILED", "action polling unavailable")
end

-- Key registration helper
local function register_key(key, callback)
    if not key then return end
    if RegisterKeyBindAsync then
        RegisterKeyBindAsync(key, {}, callback)
    elseif RegisterKeyBind then
        local ok = pcall(function() RegisterKeyBind(key, {}, callback) end)
        if not ok then
            RegisterKeyBind(key, callback)
        end
    else
        diag("keybind registration failed: no register function")
    end
end

-- F1/F3 read game state and stay on the game-thread queue.
-- F6 only dispatches an external process, so it runs directly to avoid a game hitch.
if Key.F1 then
    register_key(Key.F1, function()
        table.insert(GameThreadQueue, function() call_core("SaveCurrentPos", "") end)
    end)
end
if Key.F3 then
    register_key(Key.F3, function()
        table.insert(GameThreadQueue, function() call_core("ListSpots") end)
    end)
end
if Key.F6 then
    register_key(Key.F6, function()
        -- UI launch does not touch UObjects. Keep process dispatch off the game thread.
        call_core("LaunchTeleportUI")
    end)
end

-- F7 toggles flight on the game thread; the core owns state restoration.
if Key.F7 then
    register_key(Key.F7, function()
        table.insert(GameThreadQueue, function() call_core("ToggleNoClip") end)
    end)
end

-- Numpad bindings: now just writes to CppBridge actions file (no actor state writes),
-- so no need for game-thread queue. Direct call = zero latency, same as UI double-click.
for i = 1, 9 do
    local keyName = NumKeyNames[i]
    local key = Key[keyName]
    if key then
        local slot = i  -- capture by value
        register_key(key, function()
            call_core("TeleportToNumpadBinding", slot)
        end)
        diag("Bound numpad key %s -> slot %d (direct)", keyName, i)
    else
        diag("WARN: Key.%s is nil, cannot bind numpad slot %d", keyName, i)
    end
end

if Key.NUM_ZERO then
    register_key(Key.NUM_ZERO, function()
        call_core("TeleportToNumpadBinding", 0)
    end)
    diag("Bound numpad key NUM_ZERO -> slot 0 (direct)")
else
    diag("WARN: Key.NUM_ZERO is nil, cannot bind numpad slot 0")
end

RegisterConsoleCommandHandler("tpreload", function()
    reload_core("console")
end)
RegisterConsoleCommandHandler("tp", function(params)
    call_core("ConsoleTp", params)
end)
RegisterConsoleCommandHandler("tpcoord", function(params)
    call_core("ConsoleTpCoord", params)
end)
RegisterConsoleCommandHandler("savespot", function(params)
    call_core("SaveCurrentPos", params or "")
end)
RegisterConsoleCommandHandler("setspot", function(params)
    call_core("SetSpot", params or "")
end)
RegisterConsoleCommandHandler("renamespot", function(params)
    call_core("RenameSpot", params or "")
end)
RegisterConsoleCommandHandler("delspot", function(params)
    call_core("DeleteSpot", params or "")
end)
RegisterConsoleCommandHandler("listspots", function()
    call_core("ListSpots")
end)
RegisterConsoleCommandHandler("tpui", function()
    call_core("LaunchTeleportUI")
end)

diag("TeleportMod shell v%s ready", SHELL_VERSION)
print(string.format("[TeleportMod shell v%s] ready | F6 UI | F7 Free Flight | core hot reload: tpreload or RELOAD_CORE\n", SHELL_VERSION))
