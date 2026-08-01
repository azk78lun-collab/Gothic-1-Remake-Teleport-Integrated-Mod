-- Gothic 1 Remake Teleport Lite - Nexus test build.
-- UE4SS loads this file. All teleport/UI work stays inside one native DLL.

local VERSION = "1.0.0-test"
local NativePath = "Mods\\TeleportLite\\TeleportLiteNative.dll"
local CommandFile = "TeleportLite_command.txt"
local StatusFile = "TeleportLite_status.txt"
local DiagFile = "TeleportLite_lua_diag.txt"

local NativeInitialize = nil
local NativeDispatch = nil
local NativeShutdown = nil
local LastKeyAt = {}

local NumKeyNames = {
    [1] = "NUM_ONE",   [2] = "NUM_TWO",   [3] = "NUM_THREE",
    [4] = "NUM_FOUR",  [5] = "NUM_FIVE",  [6] = "NUM_SIX",
    [7] = "NUM_SEVEN", [8] = "NUM_EIGHT", [9] = "NUM_NINE",
    [0] = "NUM_ZERO",
}

local function now_text()
    local ok, value = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    return ok and value or "unknown-time"
end

local function diag(message)
    message = tostring(message or "")
    print("[TeleportLite] " .. message .. "\n")
    pcall(function()
        local file = io.open(DiagFile, "a")
        if file then
            file:write("[" .. now_text() .. "] " .. message .. "\n")
            file:close()
        end
    end)
end

local function write_status(state, message)
    pcall(function()
        local file = io.open(StatusFile, "w")
        if file then
            file:write("STATE=" .. tostring(state) .. "\n")
            file:write("MESSAGE=" .. tostring(message) .. "\n")
            file:write("VERSION=" .. VERSION .. "\n")
            file:close()
        end
    end)
end

local function integrated_mod_enabled()
    local file = io.open("Mods\\mods.txt", "r")
    if not file then return false end
    for line in file:lines() do
        local name, enabled = line:match("^%s*([^:]+)%s*:%s*([01])")
        if name and enabled == "1" then
            name = name:gsub("%s+$", "")
            if name:lower() == "teleportmod" then
                file:close()
                return true
            end
        end
    end
    file:close()
    return false
end

local function load_native(symbol)
    if not package or type(package.loadlib) ~= "function" then
        return nil, "package.loadlib unavailable"
    end
    local loader, error_text = package.loadlib(NativePath, symbol)
    if type(loader) ~= "function" then
        return nil, tostring(error_text or (symbol .. " unavailable"))
    end
    return loader
end

local function initialize_native()
    local error_text = nil
    NativeInitialize, error_text = load_native("TeleportLiteInitialize")
    if not NativeInitialize then return false, error_text end
    NativeDispatch, error_text = load_native("TeleportLiteDispatch")
    if not NativeDispatch then return false, error_text end
    NativeShutdown, error_text = load_native("TeleportLiteShutdown")
    if not NativeShutdown then return false, error_text end
    local ok, init_error = pcall(NativeInitialize)
    if not ok then return false, tostring(init_error) end
    return true
end

local function send_command(command)
    if type(NativeDispatch) ~= "function" then
        return false, "native dispatch unavailable"
    end
    local temp_path = CommandFile .. ".tmp"
    local ok, error_text = pcall(function()
        local file = assert(io.open(temp_path, "w"))
        file:write(command .. "\n")
        file:close()
        os.remove(CommandFile)
        assert(os.rename(temp_path, CommandFile))
    end)
    if not ok then return false, tostring(error_text) end
    local dispatch_ok, dispatch_error = pcall(NativeDispatch)
    if not dispatch_ok then return false, tostring(dispatch_error) end
    return true
end

local function register_key(key, name, command)
    if not key then
        diag("Key." .. name .. " unavailable")
        return
    end
    local callback = function()
        local now = os.clock()
        if now - (LastKeyAt[name] or -100.0) < 0.25 then return end
        LastKeyAt[name] = now
        local ok, error_text = send_command(command)
        if not ok then diag(name .. " dispatch failed: " .. tostring(error_text)) end
    end
    if RegisterKeyBindAsync then
        RegisterKeyBindAsync(key, {}, callback)
    elseif RegisterKeyBind then
        local ok = pcall(function() RegisterKeyBind(key, {}, callback) end)
        if not ok then RegisterKeyBind(key, callback) end
    else
        diag("keybind registration unavailable")
        return
    end
    diag("bound " .. name .. " -> " .. command)
end

pcall(function()
    local file = io.open(DiagFile, "w")
    if file then
        file:write("[" .. now_text() .. "] TeleportLite " .. VERSION .. " starting\n")
        file:close()
    end
end)
os.remove(CommandFile)
os.remove(CommandFile .. ".tmp")

if integrated_mod_enabled() then
    write_status("CONFLICT", "Disable TeleportMod before enabling TeleportLite.")
    diag("startup blocked: integrated TeleportMod is enabled in Mods\\mods.txt")
    return
end

local native_ok, native_error = initialize_native()
if not native_ok then
    write_status("FAILED", "TeleportLiteNative.dll could not be loaded")
    diag("native initialization failed: " .. tostring(native_error))
    return
end

register_key(Key and Key.F1, "F1", "SAVE_AUTO")
register_key(Key and Key.F3, "F3", "LIST")
register_key(Key and Key.F6, "F6", "TOGGLE_UI")
for slot = 1, 9 do
    register_key(Key and Key[NumKeyNames[slot]], NumKeyNames[slot], "HOTKEY|" .. slot)
end
register_key(Key and Key.NUM_ZERO, "NUM_ZERO", "HOTKEY|0")

write_status("READY", "F6 opens Teleport Lite; F1 saves; numpad teleports.")
diag("ready; teleport-only build, no F7 binding")
