local MOD_NAME = "[G1R_NoChestLocks]"
local VERSION = "2.7-lazy-lockpick-ui-hook"
local DIAGNOSTIC_LOGS = false
local CONTROL_FILE = "G1R_NoChestLocks_control.txt"
local STATE_FILE = "G1R_NoChestLocks_state.txt"
local FLIGHT_ACTION_FILE = "TeleportMod_cpp_actions.txt"

local RECENT_INTERACTION_WINDOW = 6.0
local SAFETY_ERROR_LIMIT = 12
local ALLOW_ACTIVE_GAME_CALLS = false
local ALLOW_CONTAINER_FINISH_CALLS = true
local ALLOW_CONFIRMED_DOOR_OPEN_CALLS = true
local HOOK_RETRY_DELAY_MS = 1000
local HOOK_RETRY_LIMIT = 90
local LOCKPICK_UI_HOOK_PATH = "/Game/UI/LockPick/W_LockPickUI.W_LockPickUI_C:Construct"
local LOCKPICK_UI_PROBE_DELAY_MS = 100
local LOCKPICK_UI_PROBE_LIMIT = 20

local last_door_interaction = { ability = nil, time = 0 }
local last_container_interaction = { ability = nil, time = 0 }
local last_confirmed_lockpick_door = { unique = "", lock = "", time = 0 }
local last_confirmed_lockpick_container = { unique = "", lock = "", time = 0 }

local registered_hooks = {}
local ready_logged = false
local mod_enabled = false
local last_control_text = nil
local safety_error_count = 0
local safety_disabled = false
local lockpick_ui_probe_active = false
local prune_recent_objects
local required_hooks = {
    "/Script/G1R.GameplayAbilityInteractionBase:OnPreTargetLocationReached",
    "/Script/G1R.AbilityTask_LockPick:TryOpenLock",
    "/Script/G1R.GameplayAbilityDoor:FailedLockEvent",
    "/Script/G1R.GameplayAbilityOpen:OnIntroFinished",
    "/Script/G1R.GameplayAbilityOpen:OnLockSequenceFinished",
    "/Script/G1R.GameplayAbilityOpen:FailedLockEvent",
}

local function log(message)
    print(string.format("%s %s\n", MOD_NAME, tostring(message)))
end

local function clean(value)
    value = tostring(value or "")
    value = value:gsub("[\r\n]", " ")
    return value
end

local function write_state(state, message)
    pcall(function()
        local file = io.open(STATE_FILE, "w")
        if file then
            file:write("STATE=" .. clean(state) .. "\n")
            file:write("MESSAGE=" .. clean(message) .. "\n")
            file:write("UPDATED=" .. tostring(os.time()) .. "\n")
            file:close()
        end
    end)
end

local function request_flight_pause(duration_ms, reason)
    pcall(function()
        local file = io.open(FLIGHT_ACTION_FILE, "a")
        if not file then
            return
        end
        local clean_reason = clean(reason):gsub("|", " ")
        file:write(string.format("FLIGHT_PAUSE|%d|%s\n", tonumber(duration_ms) or 2500, clean_reason))
        file:close()
    end)
end

local function request_flight_resume(reason)
    pcall(function()
        local file = io.open(FLIGHT_ACTION_FILE, "a")
        if not file then
            return
        end
        local clean_reason = clean(reason):gsub("|", " ")
        file:write(string.format("FLIGHT_RESUME|%s\n", clean_reason))
        file:close()
    end)
end

local function note_safety_error(context, err)
    safety_error_count = safety_error_count + 1
    log(string.format("Safety error #%d in %s: %s", safety_error_count, tostring(context), tostring(err)))
    write_state("ERROR", string.format("%s: %s", tostring(context), tostring(err)))
    if safety_error_count >= SAFETY_ERROR_LIMIT then
        safety_disabled = true
        mod_enabled = false
        write_state("DISABLED", "disabled after repeated hook errors")
        log("Disabled after repeated hook errors")
    end
end

local function update_control()
    pcall(prune_recent_objects)
    local file = io.open(CONTROL_FILE, "r")
    local text = ""
    if file then
        text = file:read("*a") or ""
        file:close()
    end

    if text == last_control_text then
        return
    end
    last_control_text = text

    local enabled = false
    local upper = string.upper(text)
    if upper:find("ENABLED=1", 1, true) or upper:find("STATE=ENABLED", 1, true) or upper:find("ACTION=ENABLE", 1, true) then
        enabled = true
    end

    mod_enabled = enabled and not safety_disabled
    if mod_enabled then
        write_state("ENABLED", "no chest locks enabled")
        log("Enabled by UI")
    else
        write_state("DISABLED", "no chest locks disabled")
        log("Disabled by UI")
    end
end

local function run_hook_safely(hook_name, phase, fn, ...)
    if safety_disabled then
        return nil
    end

    local okControl, controlErr = pcall(update_control)
    if not okControl then
        note_safety_error(hook_name .. ":" .. phase .. ":control", controlErr)
        return nil
    end
    if not mod_enabled then
        return nil
    end

    local args = { ... }
    local ok, result = pcall(function()
        return fn(table.unpack(args))
    end)
    if not ok then
        note_safety_error(hook_name .. ":" .. phase, result)
        return nil
    end
    return result
end

local function debug_log(message)
    if DIAGNOSTIC_LOGS then
        log("[debug] " .. tostring(message))
    end
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function contains(haystack, needle)
    return string.find(lower(haystack), lower(needle), 1, true) ~= nil
end

local function is_usable_object(object)
    if not object then
        return false
    end

    local ok, value = pcall(function()
        return object:IsValid()
    end)
    if ok then
        return value
    end

    ok = pcall(function()
        object:GetFullName()
    end)
    return ok
end

local function get_full_name(object)
    if not object then
        return ""
    end

    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    if ok and value then
        return tostring(value)
    end

    ok, value = pcall(function()
        return object:GetName()
    end)
    if ok and value then
        return tostring(value)
    end

    return ""
end

local function get_param_value(param)
    if not param then
        return nil
    end

    local ok, value = pcall(function()
        return param:get()
    end)
    if ok then
        return value
    end

    ok, value = pcall(function()
        return param:Get()
    end)
    if ok then
        return value
    end

    return nil
end

local function get_param_object(param)
    local value = get_param_value(param)
    if is_usable_object(value) then
        return value
    end
    return nil
end

local function set_param_value(param, value)
    if not param then
        return false
    end

    local ok = pcall(function()
        param:set(value)
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        param:Set(value)
    end)
    return ok
end

local function clear_param_array(param)
    if not param then
        return false
    end

    local changed = false
    local value = get_param_value(param)
    if value then
        local ok = pcall(function()
            value:Empty()
        end)
        changed = ok or changed
    end

    local ok = pcall(function()
        param:set({})
    end)
    changed = ok or changed

    ok = pcall(function()
        param:Set({})
    end)
    return ok or changed
end

local function raw_property_value(object, property_name)
    if not object then
        return nil, false
    end

    local ok, value = pcall(function()
        return object[property_name]
    end)
    if ok then
        return value, true
    end

    ok, value = pcall(function()
        return object:GetPropertyValue(property_name)
    end)
    if ok then
        return value, true
    end

    return nil, false
end

local function get_object_property(object, property_name)
    local value, ok = raw_property_value(object, property_name)
    if ok and is_usable_object(value) then
        return value
    end
    return nil
end

local function value_to_string(value)
    if value == nil then
        return ""
    end

    local ok, text = pcall(function()
        return value:ToString()
    end)
    if ok and text then
        return tostring(text)
    end

    return tostring(value)
end

local function get_string_property(object, property_name)
    local value, ok = raw_property_value(object, property_name)
    if not ok then
        return ""
    end
    return value_to_string(value)
end

local function get_bool_property(object, property_name)
    local value, ok = raw_property_value(object, property_name)
    if ok then
        return value == true
    end
    return false
end

local function count_array_items(value)
    if not value then
        return -1
    end

    local ok, count = pcall(function()
        return value:GetArrayNum()
    end)
    if ok and type(count) == "number" then
        return count
    end

    ok, count = pcall(function()
        return value:Num()
    end)
    if ok and type(count) == "number" then
        return count
    end

    ok, count = pcall(function()
        return #value
    end)
    if ok and type(count) == "number" then
        return count
    end

    return -1
end

local function get_array_count_property(object, property_name)
    local value, ok = raw_property_value(object, property_name)
    if not ok then
        return 0
    end

    local count = count_array_items(value)
    if count >= 0 then
        return count
    end
    return 0
end

local function bool_text(value)
    if value then
        return "true"
    end
    return "false"
end

local function short_name(object)
    local name = get_full_name(object)
    if name == "" then
        return "<nil>"
    end

    local compact = string.match(name, "([^%.:]+)$")
    return compact or name
end

local function interaction_age(state)
    if not state or not is_usable_object(state.ability) or state.time == 0 then
        return "none"
    end
    return string.format("%.2f", os.clock() - state.time)
end

local function set_fname_property(object, property_name, value)
    if not object then
        return false
    end

    local ok = pcall(function()
        object[property_name] = FName(value)
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        object:SetPropertyValue(property_name, FName(value))
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        object[property_name] = value
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        object:SetPropertyValue(property_name, value)
    end)
    return ok
end

local function set_bool_property(object, property_name, value)
    if not object then
        return false
    end

    local ok = pcall(function()
        object[property_name] = value
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        object:SetPropertyValue(property_name, value)
    end)
    return ok
end

local function clear_array_property(object, property_name)
    if not object then
        return false
    end

    local ok = pcall(function()
        local value = object[property_name]
        if value then
            value:Empty()
        end
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        object[property_name] = {}
    end)
    return ok
end

local function clear_lock_carrier(object)
    if not object then
        return false
    end

    local changed = false
    changed = set_fname_property(object, "m_Lock", "None") or changed
    changed = set_bool_property(object, "m_ConsumeKeys", false) or changed
    changed = clear_array_property(object, "m_Keys") or changed
    changed = clear_array_property(object, "m_PuzzleKeys") or changed
    return changed
end

local object_find_cache = {}

local function find_object_by_name(name)
    if not name or name == "" or name == "None" then
        return nil
    end

    if object_find_cache[name] ~= nil then
        return object_find_cache[name] or nil
    end

    local candidates = {
        "/Script/Angelscript." .. name,
        "Class /Script/Angelscript." .. name,
        "Angelscript.Default__" .. name,
        name,
    }

    for _, candidate in ipairs(candidates) do
        local ok, object = pcall(function()
            return StaticFindObject(candidate)
        end)
        if ok and is_usable_object(object) then
            object_find_cache[name] = object
            return object
        end
    end

    object_find_cache[name] = false
    return nil
end

local function get_interactive_definition(ability)
    local actor = get_object_property(ability, "m_InteractiveActor")
    if not actor then
        return nil
    end

    local direct = get_object_property(actor, "m_InteractiveObjectDefinition")
    if direct then
        return direct
    end

    local ok, definition = pcall(function()
        return actor:GetInteractiveObjectDefinition()
    end)
    if ok and is_usable_object(definition) then
        return definition
    end

    return nil
end

local lockpick_definition_cache = {}

local function has_lockpick_definition(ability)
    local unique_name = get_string_property(ability, "m_UniqueNameInteractive")
    local lock_name = get_string_property(ability, "m_Lock")
    local definition = get_interactive_definition(ability)
    local definition_lock = get_string_property(definition, "m_Lock")
    local cache_key = unique_name .. "|" .. lock_name .. "|" .. definition_lock

    if lockpick_definition_cache[cache_key] ~= nil then
        return lockpick_definition_cache[cache_key]
    end

    local result = false
    if unique_name ~= "" and unique_name ~= "None" then
        result = find_object_by_name(unique_name .. "_Lock") ~= nil
    end
    if not result and lock_name ~= "" and lock_name ~= "None" then
        result = find_object_by_name(lock_name) ~= nil
    end
    if not result and definition_lock ~= "" and definition_lock ~= "None" then
        result = find_object_by_name(definition_lock) ~= nil
    end

    lockpick_definition_cache[cache_key] = result
    return result
end

local function get_world_context(object)
    if not is_usable_object(object) then
        return nil
    end

    local ok, world = pcall(function()
        return object:GetWorld()
    end)
    if ok and is_usable_object(world) then
        return world
    end

    return nil
end

local puzzles_default
local puzzles_checked = false

local function get_puzzles_subsystem_default()
    if puzzles_checked then
        return puzzles_default
    end
    puzzles_checked = true

    local candidates = {
        "/Script/G1R.Default__PuzzlesSubsystem",
        "G1R.Default__PuzzlesSubsystem",
        "PuzzlesSubsystem G1R.Default__PuzzlesSubsystem",
        "Default__PuzzlesSubsystem",
    }

    for _, candidate in ipairs(candidates) do
        local ok, object = pcall(function()
            return StaticFindObject(candidate)
        end)
        if ok and is_usable_object(object) then
            puzzles_default = object
            return puzzles_default
        end
    end

    return nil
end

local function global_open_door(ability, confirmed_lockpick)
    if not ALLOW_ACTIVE_GAME_CALLS and not (ALLOW_CONFIRMED_DOOR_OPEN_CALLS and confirmed_lockpick) then
        return false
    end

    local door_connection = get_string_property(ability, "m_UniqueNameDoorConnection")
    if door_connection == "" or door_connection == "None" then
        return false
    end

    local puzzles = get_puzzles_subsystem_default()
    if not is_usable_object(puzzles) then
        return false
    end

    local ok = pcall(function()
        puzzles:GlobalOpenDoor(ability, FName(door_connection))
    end)
    if ok then
        return true
    end

    local world = get_world_context(ability)
    ok = pcall(function()
        puzzles:GlobalOpenDoorWorld(world, FName(door_connection))
    end)
    return ok
end

local function looks_like_door_ability(object)
    local name = get_full_name(object)
    return contains(name, "ga_human_opendoor")
        or contains(name, "gameplayabilitydoor")
        or contains(name, "gameplayabilityopendoor")
end

local function looks_like_open_container_ability(object)
    local name = get_full_name(object)
    return contains(name, "opencontainer")
        or contains(name, "gameplayabilityopencontainer")
end

local ability_summary

local function remember_door_interaction(ability)
    if is_usable_object(ability) and looks_like_door_ability(ability) then
        last_door_interaction = { ability = ability, time = os.clock() }
        debug_log("PreTarget door: " .. ability_summary(ability))
    end
end

local function remember_container_interaction(ability)
    if is_usable_object(ability) and looks_like_open_container_ability(ability) then
        last_container_interaction = { ability = ability, time = os.clock() }
        debug_log("PreTarget container: " .. ability_summary(ability))
    end
end

local function get_recent_interaction(state)
    if os.clock() - state.time > RECENT_INTERACTION_WINDOW then
        return nil
    end
    local ability = state.ability
    if not is_usable_object(ability) then
        return nil
    end
    return ability
end

local function reset_interaction_state(state)
    state.ability = nil
    state.time = 0
end

function prune_recent_objects()
    local now = os.clock()
    if now - last_door_interaction.time > RECENT_INTERACTION_WINDOW then
        reset_interaction_state(last_door_interaction)
    end
    if now - last_container_interaction.time > RECENT_INTERACTION_WINDOW then
        reset_interaction_state(last_container_interaction)
    end
end

local function reset_confirmed_container()
    last_confirmed_lockpick_container = { unique = "", lock = "", time = 0 }
end

local function get_recent_lockpick_target()
    local door_ability = get_recent_interaction(last_door_interaction)
    local container_ability = get_recent_interaction(last_container_interaction)

    debug_log(
        "Target scan: door_age=" .. interaction_age(last_door_interaction)
        .. " container_age=" .. interaction_age(last_container_interaction)
        .. " door_valid=" .. bool_text(is_usable_object(door_ability))
        .. " container_valid=" .. bool_text(is_usable_object(container_ability))
    )

    if is_usable_object(door_ability) and is_usable_object(container_ability) then
        if last_container_interaction.time >= last_door_interaction.time then
            debug_log("Target selected container over door: " .. ability_summary(container_ability))
            return "container", container_ability
        end
        debug_log("Target selected door over container: " .. ability_summary(door_ability))
        return "door", door_ability
    end

    if is_usable_object(container_ability) then
        debug_log("Target selected container: " .. ability_summary(container_ability))
        return "container", container_ability
    end

    if is_usable_object(door_ability) then
        debug_log("Target selected door: " .. ability_summary(door_ability))
        return "door", door_ability
    end

    debug_log("Target selected none")
    return nil, nil
end

local function remember_confirmed_lockpick_door(ability)
    if is_usable_object(ability) and looks_like_door_ability(ability) then
        last_confirmed_lockpick_door = {
            unique = get_string_property(ability, "m_UniqueNameInteractive"),
            lock = get_string_property(ability, "m_Lock"),
            time = os.clock(),
        }
    end
end

local function remember_confirmed_lockpick_container(ability)
    if is_usable_object(ability) and looks_like_open_container_ability(ability) then
        last_confirmed_lockpick_container = {
            unique = get_string_property(ability, "m_UniqueNameInteractive"),
            lock = get_string_property(ability, "m_Lock"),
            time = os.clock(),
        }
        debug_log("Confirmed lockpick container: " .. ability_summary(ability))
    end
end

local function is_recent_confirmed_lockpick_door(ability)
    if os.clock() - last_confirmed_lockpick_door.time > RECENT_INTERACTION_WINDOW then
        return false
    end
    if not is_usable_object(ability) or not looks_like_door_ability(ability) then
        return false
    end

    local unique = get_string_property(ability, "m_UniqueNameInteractive")
    local lock = get_string_property(ability, "m_Lock")
    if unique ~= "" and unique ~= "None" and unique == last_confirmed_lockpick_door.unique then
        return true
    end
    if lock ~= "" and lock ~= "None" and lock == last_confirmed_lockpick_door.lock then
        return true
    end

    return false
end

local function is_recent_confirmed_lockpick_container(ability)
    if os.clock() - last_confirmed_lockpick_container.time > RECENT_INTERACTION_WINDOW then
        return false
    end
    if not is_usable_object(ability) or not looks_like_open_container_ability(ability) then
        return false
    end

    local unique = get_string_property(ability, "m_UniqueNameInteractive")
    local lock = get_string_property(ability, "m_Lock")
    if unique ~= "" and unique ~= "None" and unique == last_confirmed_lockpick_container.unique then
        return true
    end
    if lock ~= "" and lock ~= "None" and lock == last_confirmed_lockpick_container.lock then
        return true
    end

    return false
end

local function close_lockpick_ui(widget)
    if not is_usable_object(widget) then
        debug_log("Close lockpick UI: no valid widget")
        return false
    end

    local ok = pcall(function()
        widget:FadeOutAndRemoveFromParent()
    end)
    if ok then
        debug_log("Close lockpick UI: FadeOutAndRemoveFromParent ok widget=" .. short_name(widget))
        return true
    end

    ok = pcall(function()
        widget:RemoveFromParent()
    end)
    debug_log("Close lockpick UI: RemoveFromParent result=" .. bool_text(ok) .. " widget=" .. short_name(widget))
    return ok
end

local function exit_lockpick_scene(ability, widget)
    local lockpick_task = get_object_property(ability, "m_LockPickTask")
    if is_usable_object(lockpick_task) then
        local ok = pcall(function()
            lockpick_task:BackPressed()
        end)
        if ok then
            return true
        end
    end

    return close_lockpick_ui(widget)
end

local function is_quest_locked(ability)
    if not ability then
        return false
    end

    if get_bool_property(ability, "m_ConsumeKeys") then
        return true
    end
    if get_array_count_property(ability, "m_PuzzleKeys") > 0 then
        return true
    end

    local lock_name = get_string_property(ability, "m_Lock")
    if lock_name ~= "" and lock_name ~= "None" then
        if contains(lock_name, "Quest") or contains(lock_name, "Story") or contains(lock_name, "Key") then
            return true
        end
    end

    local unique_name = get_string_property(ability, "m_UniqueNameInteractive")
    if unique_name ~= "" and unique_name ~= "None" then
        if contains(unique_name, "quest") or contains(unique_name, "story") or contains(unique_name, "key") then
            return true
        end
    end

    local definition = get_interactive_definition(ability)
    if get_string_property(definition, "m_ActiveUntilEvent") ~= "" and get_string_property(definition, "m_ActiveUntilEvent") ~= "None" then
        return true
    end
    if get_string_property(definition, "m_DisabledUntilEvent") ~= "" and get_string_property(definition, "m_DisabledUntilEvent") ~= "None" then
        return true
    end
    return false
end

function ability_summary(ability)
    if not is_usable_object(ability) then
        return "<invalid>"
    end

    local definition = get_interactive_definition(ability)
    return string.format(
        "%s unique=%s lock=%s keys=%d puzzle=%d consume=%s quest=%s def=%s def_lock=%s",
        short_name(ability),
        get_string_property(ability, "m_UniqueNameInteractive"),
        get_string_property(ability, "m_Lock"),
        get_array_count_property(ability, "m_Keys"),
        get_array_count_property(ability, "m_PuzzleKeys"),
        bool_text(get_bool_property(ability, "m_ConsumeKeys")),
        bool_text(is_quest_locked(ability)),
        short_name(definition),
        get_string_property(definition, "m_Lock")
    )
end

local function is_door_blocked_by_story_or_key(ability)
    if not ability then
        return false
    end

    local definition = get_interactive_definition(ability)
    if get_string_property(definition, "m_ActiveUntilEvent") ~= "" and get_string_property(definition, "m_ActiveUntilEvent") ~= "None" then
        return true
    end
    if get_string_property(definition, "m_DisabledUntilEvent") ~= "" and get_string_property(definition, "m_DisabledUntilEvent") ~= "None" then
        return true
    end
    if get_string_property(definition, "m_RequiredUniqueObject") ~= "" and get_string_property(definition, "m_RequiredUniqueObject") ~= "None" then
        return true
    end

    local lock_name = get_string_property(ability, "m_Lock")
    if contains(lock_name, "Quest") or contains(lock_name, "Story") then
        return true
    end

    local unique_name = get_string_property(ability, "m_UniqueNameInteractive")
    if contains(unique_name, "quest") or contains(unique_name, "story") then
        return true
    end

    return false
end

local function bypass_door(ability)
    if not is_usable_object(ability) or not looks_like_door_ability(ability) then
        return false
    end
    if not has_lockpick_definition(ability) then
        return false
    end
    if is_door_blocked_by_story_or_key(ability) then
        return false
    end

    clear_lock_carrier(ability)
    clear_lock_carrier(get_interactive_definition(ability))
    return true
end

local function bypass_confirmed_lockpick_door(ability)
    if not is_usable_object(ability) or not looks_like_door_ability(ability) then
        return false
    end

    clear_lock_carrier(ability)
    clear_lock_carrier(get_interactive_definition(ability))
    global_open_door(ability, true)
    return true
end

local function bypass_container(ability)
    if not is_usable_object(ability) or not looks_like_open_container_ability(ability) then
        debug_log("Bypass container: rejected invalid/non-container")
        return false
    end

    local lock_name = get_string_property(ability, "m_Lock")
    if lock_name == "" or lock_name == "None" then
        debug_log("Bypass container: rejected no lock: " .. ability_summary(ability))
        return false
    end
    if is_quest_locked(ability) then
        debug_log("Bypass container: rejected quest/key lock: " .. ability_summary(ability))
        return false
    end

    local ability_changed = clear_lock_carrier(ability)
    local definition_changed = clear_lock_carrier(get_interactive_definition(ability))
    debug_log(
        "Bypass container: accepted ability_changed=" .. bool_text(ability_changed)
        .. " definition_changed=" .. bool_text(definition_changed)
        .. " after=" .. ability_summary(ability)
    )
    return true
end

local ufunction_cache = {}

local function find_ufunction(path)
    if ufunction_cache[path] ~= nil then
        return ufunction_cache[path] or nil
    end

    local candidates = {
        path,
        "Function " .. path,
    }

    for _, candidate in ipairs(candidates) do
        local ok, function_object = pcall(function()
            return StaticFindObject(candidate)
        end)
        if ok and is_usable_object(function_object) then
            ufunction_cache[path] = function_object
            return function_object
        end
    end

    ufunction_cache[path] = false
    return nil
end

local function call_ufunction(object, path, ...)
    if not is_usable_object(object) then
        return false
    end

    local function_object = find_ufunction(path)
    if not function_object then
        return false
    end

    local args = { ... }
    local ok = pcall(function()
        object:CallFunction(function_object, table.unpack(args))
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        function_object(object, table.unpack(args))
    end)
    return ok
end

local function call_container_method(ability, method_name, ...)
    local safe_finish_methods = {
        Server_OnSetLockUnlocked = true,
        NetMulticast_OnSetLockUnlocked = true,
        OnLockSequenceFinished = true,
        NoLockEvent = true,
    }
    if not ALLOW_ACTIVE_GAME_CALLS and not (ALLOW_CONTAINER_FINISH_CALLS and safe_finish_methods[method_name]) then
        return false
    end

    if not is_usable_object(ability) then
        return false
    end

    local args = { ... }
    local ok = pcall(function()
        ability[method_name](ability, table.unpack(args))
    end)

    if not ok then
        local paths = {
            "/Script/G1R.GameplayAbilityOpen:" .. method_name,
            "/Script/G1R.GameplayAbilityOpenContainer:" .. method_name,
            "/Script/Angelscript.GA_Human_OpenContainer:" .. method_name,
        }

        for _, path in ipairs(paths) do
            ok = call_ufunction(ability, path, table.unpack(args))
            if ok then
                break
            end
        end
    end

    return ok
end

local function mark_container_lock_unlocked(ability)
    if not is_usable_object(ability) then
        debug_log("Mark container unlocked: invalid ability")
        return false
    end

    local unique_name = get_string_property(ability, "m_UniqueNameInteractive")
    local changed = call_container_method(ability, "Server_OnSetLockUnlocked")
    debug_log("Mark container unlocked: Server_OnSetLockUnlocked=" .. bool_text(changed) .. " unique=" .. unique_name)

    if unique_name ~= "" and unique_name ~= "None" then
        local multicast = call_container_method(ability, "NetMulticast_OnSetLockUnlocked", FName(unique_name))
        debug_log("Mark container unlocked: NetMulticast_OnSetLockUnlocked=" .. bool_text(multicast) .. " unique=" .. unique_name)
        changed = multicast or changed
    end

    return changed
end

local function open_confirmed_container_now(ability, widget)
    if not is_usable_object(ability) or not looks_like_open_container_ability(ability) then
        debug_log("Open confirmed container: rejected invalid/non-container")
        return false
    end

    debug_log("Open confirmed container: start " .. ability_summary(ability) .. " widget=" .. short_name(widget))
    local marked = mark_container_lock_unlocked(ability)
    local stripped = clear_lock_carrier(ability)
    local sequence = call_container_method(ability, "OnLockSequenceFinished", true)
    local no_lock = call_container_method(ability, "NoLockEvent")
    local finished = marked or sequence or no_lock
    local closed = false
    if finished then
        closed = close_lockpick_ui(widget)
    end
    debug_log(
        "Open confirmed container: done marked=" .. bool_text(marked)
        .. " stripped=" .. bool_text(stripped)
        .. " sequence=" .. bool_text(sequence)
        .. " no_lock=" .. bool_text(no_lock)
        .. " finished=" .. bool_text(finished)
        .. " closed=" .. bool_text(closed)
        .. " after=" .. ability_summary(ability)
    )
    if finished then
        request_flight_resume("container unlock complete")
    end
    return finished
end

local function strip_open_ability(ability)
    if not is_usable_object(ability) then
        return false
    end
    clear_lock_carrier(ability)
    return true
end

local function maybe_log_ready()
    if ready_logged then
        return
    end

    for _, hook_name in ipairs(required_hooks) do
        if not registered_hooks[hook_name] then
            return
        end
    end

    ready_logged = true
    log("Loaded v" .. VERSION .. " - all hooks registered and ready")
end

local function register_hook(name, pre, post, attempt)
    if registered_hooks[name] then
        return true
    end

    attempt = attempt or 1

    local wrapped_pre = nil
    local wrapped_post = nil
    if pre then
        wrapped_pre = function(...)
            return run_hook_safely(name, "pre", pre, ...)
        end
    end
    if post then
        wrapped_post = function(...)
            return run_hook_safely(name, "post", post, ...)
        end
    end

    local ok = pcall(function()
        RegisterHook(name, wrapped_pre, wrapped_post)
    end)
    if ok then
        registered_hooks[name] = true
        maybe_log_ready()
        return true
    end

    if attempt < HOOK_RETRY_LIMIT then
        ExecuteWithDelay(HOOK_RETRY_DELAY_MS, function()
            register_hook(name, pre, post, attempt + 1)
        end)
    end

    return false
end

update_control()
if mod_enabled then
    write_state("ENABLED", "ready; no chest locks enabled")
else
    write_state("DISABLED", "ready; enable from UI")
end
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(500, update_control)
end

local function handle_lockpick_ui_construct(context)
    request_flight_pause(5000, "lockpick scene")
    local widget = get_param_object(context)
    local target_type, ability = get_recent_lockpick_target()
    debug_log("Lockpick UI Construct: widget=" .. short_name(widget) .. " target=" .. tostring(target_type) .. " ability=" .. ability_summary(ability))

    if target_type == "door" and is_usable_object(ability) and looks_like_door_ability(ability) then
        debug_log("Lockpick UI Construct: preparing door")
        remember_confirmed_lockpick_door(ability)
        bypass_door(ability)
        reset_interaction_state(last_door_interaction)
    elseif target_type == "container" and is_usable_object(ability) and looks_like_open_container_ability(ability) then
        debug_log("Lockpick UI Construct: handling container")
        if bypass_container(ability) then
            remember_confirmed_lockpick_container(ability)
            open_confirmed_container_now(ability, widget)
        else
            reset_confirmed_container()
            debug_log("Lockpick UI Construct: container bypass returned false")
        end
        reset_interaction_state(last_container_interaction)
    else
        debug_log("Lockpick UI Construct: no matching target")
    end

    return nil
end

local function lockpick_ui_hook_target_is_loaded()
    if not StaticFindObject then
        return false
    end

    local ok, target = pcall(function()
        return StaticFindObject(LOCKPICK_UI_HOOK_PATH)
    end)
    return ok and is_usable_object(target)
end

local function schedule_lockpick_ui_hook()
    if registered_hooks[LOCKPICK_UI_HOOK_PATH] or lockpick_ui_probe_active then
        return
    end
    if not ExecuteWithDelay then
        return
    end

    lockpick_ui_probe_active = true
    local attempt = 0

    local function probe()
        if registered_hooks[LOCKPICK_UI_HOOK_PATH] then
            lockpick_ui_probe_active = false
            return
        end

        attempt = attempt + 1
        if lockpick_ui_hook_target_is_loaded() then
            -- The target exists now, so RegisterHook is attempted once without
            -- the generic 90-second retry chain used by native functions.
            if register_hook(
                LOCKPICK_UI_HOOK_PATH,
                handle_lockpick_ui_construct,
                nil,
                HOOK_RETRY_LIMIT
            ) then
                lockpick_ui_probe_active = false
                debug_log("Lockpick UI hook registered lazily")
                return
            end
        end

        if attempt >= LOCKPICK_UI_PROBE_LIMIT then
            lockpick_ui_probe_active = false
            debug_log("Lockpick UI hook probe ended without a loaded target")
            return
        end

        ExecuteWithDelay(LOCKPICK_UI_PROBE_DELAY_MS, probe)
    end

    ExecuteWithDelay(LOCKPICK_UI_PROBE_DELAY_MS, probe)
end

register_hook("/Script/G1R.GameplayAbilityInteractionBase:OnPreTargetLocationReached", function(context)
    local ability = get_param_object(context)
    -- This is a generic F-interaction hook used by books, insects and many
    -- unrelated world actions. Pause flight only for an actual lock target.
    if looks_like_door_ability(ability) or looks_like_open_container_ability(ability) then
        request_flight_pause(2500, "lock interaction")
        schedule_lockpick_ui_hook()
    end
    remember_door_interaction(ability)
    remember_container_interaction(ability)
    return nil
end)

register_hook("/Script/G1R.AbilityTask_LockPick:TryOpenLock", function(context, owning_ability, lock, keys, interactive_object_actor_name, puzzle_keys, consume_keys)
    request_flight_pause(5000, "unlock sequence")
    schedule_lockpick_ui_hook()
    local ability = get_param_object(owning_ability)
    debug_log(
        "TryOpenLock: ability=" .. ability_summary(ability)
        .. " param_lock=" .. value_to_string(get_param_value(lock))
        .. " param_keys=" .. tostring(get_param_value(keys))
        .. " param_puzzle=" .. tostring(get_param_value(puzzle_keys))
        .. " param_consume=" .. tostring(get_param_value(consume_keys))
    )

    if is_usable_object(ability) and looks_like_open_container_ability(ability) then
        if bypass_container(ability) then
            remember_confirmed_lockpick_container(ability)
            open_confirmed_container_now(ability, nil)
            local lock_set = set_param_value(lock, FName("None"))
            local consume_set = set_param_value(consume_keys, false)
            debug_log("TryOpenLock: container params lock_set=" .. bool_text(lock_set) .. " consume_set=" .. bool_text(consume_set))
        else
            reset_confirmed_container()
            debug_log("TryOpenLock: container bypass returned false")
        end
        reset_interaction_state(last_container_interaction)
        return nil
    end

    local door_bypassed = bypass_door(ability)
    if not door_bypassed and is_recent_confirmed_lockpick_door(ability) then
        door_bypassed = bypass_confirmed_lockpick_door(ability)
    end

    if door_bypassed then
        debug_log("TryOpenLock: door bypass accepted")
        local lock_set = set_param_value(lock, FName("None"))
        local keys_set = clear_param_array(keys)
        local puzzle_set = clear_param_array(puzzle_keys)
        local consume_set = set_param_value(consume_keys, false)
        global_open_door(ability, true)
        write_state("ENABLED", "door lock bypass applied")
        request_flight_resume("door unlock complete")
        debug_log(
            "TryOpenLock: door params lock_set=" .. bool_text(lock_set)
            .. " keys_set=" .. bool_text(keys_set)
            .. " puzzle_set=" .. bool_text(puzzle_set)
            .. " consume_set=" .. bool_text(consume_set)
        )
        reset_interaction_state(last_door_interaction)
        return nil
    end

    debug_log("TryOpenLock: no bypass")

    return nil
end)

register_hook("/Script/G1R.GameplayAbilityDoor:FailedLockEvent", function(context)
    request_flight_pause(2500, "door lock fallback")
    local ability = get_param_object(context)
    if is_recent_confirmed_lockpick_door(ability) then
        bypass_confirmed_lockpick_door(ability)
        request_flight_resume("door fallback complete")
    end
    return nil
end)

register_hook("/Script/G1R.GameplayAbilityOpen:OnIntroFinished", function(context)
    request_flight_pause(2000, "container intro finished")
    local ability = get_param_object(context)
    debug_log("OnIntroFinished: recent_container=" .. bool_text(is_recent_confirmed_lockpick_container(ability)) .. " ability=" .. ability_summary(ability))
    if is_recent_confirmed_lockpick_container(ability) then
        strip_open_ability(ability)
    end
    return nil
end)

register_hook("/Script/G1R.GameplayAbilityOpen:OnLockSequenceFinished", function(context, success)
    request_flight_pause(2000, "lock sequence finished")
    local ability = get_param_object(context)
    debug_log("OnLockSequenceFinished: recent_container=" .. bool_text(is_recent_confirmed_lockpick_container(ability)) .. " success_param=" .. tostring(get_param_value(success)) .. " ability=" .. ability_summary(ability))
    if is_recent_confirmed_lockpick_container(ability) then
        strip_open_ability(ability)
        set_param_value(success, true)
        request_flight_resume("container sequence complete")
    end
    return nil
end)

register_hook("/Script/G1R.GameplayAbilityOpen:FailedLockEvent", function(context)
    request_flight_pause(2000, "lock sequence fallback")
    local ability = get_param_object(context)
    debug_log("Container FailedLockEvent: recent_container=" .. bool_text(is_recent_confirmed_lockpick_container(ability)) .. " ability=" .. ability_summary(ability))
    if is_recent_confirmed_lockpick_container(ability) then
        strip_open_ability(ability)
        request_flight_resume("container fallback complete")
    end
    return nil
end)
