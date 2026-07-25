-- ItemMod for Gothic 1 Remake
-- Handles UI item spawn requests using the CT-derived Summon catalog.

local MOD_VERSION = "1.3.14-native-quantity"
local ACTION_FILE = "TeleportMod_item_actions.txt"
local STATE_FILE = "TeleportMod_item_state.txt"
local INVENTORY_STATE_FILE = "TeleportMod_inventory_state.txt"
local INVENTORY_STATE_TMP_FILE = "TeleportMod_inventory_state.txt.tmp"
local INVENTORY_LIST_FILE = "TeleportMod_inventory_list.txt"
local INVENTORY_LIST_TMP_FILE = "TeleportMod_inventory_list.txt.tmp"
local CATALOG_FILE = "Mods\\TeleportModUIExternal\\TeleportMod_items.tsv"
local MAX_QTY = 20
local INVENTORY_MAX_DEPTH = 5
local INVENTORY_MAX_RESULTS = 160
local INVENTORY_MAX_OBJECTS = 320
local INVENTORY_MAX_COMPONENTS = 24
local INVENTORY_FIND_MAX_TARGETS = 24
local INVENTORY_FIND_MAX_FUNCTIONS = 160
local INVENTORY_FIND_MAX_PROPERTIES = 80
local INVENTORY_DETAILS_MAX_PROPERTIES = 120
local INVENTORY_DETAILS_MAX_FUNCTIONS = 120
local INVENTORY_MODULES_MAX_ITEMS = 24
local INVENTORY_LIST_MAX_ITEMS = 320

local UEHelpers = nil
local ItemCatalog = {}
local LastCatalogCount = 0

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

local function write_state(state, message, code, qty, method, command)
    pcall(function()
        local file = io.open(STATE_FILE, "w")
        if file then
            file:write("STATE=" .. clean(state) .. "\n")
            file:write("MESSAGE=" .. clean(message) .. "\n")
            file:write("CODE=" .. clean(code) .. "\n")
            file:write("QTY=" .. clean(qty) .. "\n")
            file:write("METHOD=" .. clean(method) .. "\n")
            file:write("COMMAND=" .. clean(command) .. "\n")
            file:write("UPDATED=" .. tostring(os.time()) .. "\n")
            file:close()
        end
    end)
end

local function is_valid_object(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function safe_full_name(obj)
    if not is_valid_object(obj) then return "" end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and value then return tostring(value) end
    return ""
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function split_tsv(line)
    local parts = {}
    for part in (line .. "\t"):gmatch("(.-)\t") do
        table.insert(parts, part)
    end
    return parts
end

local function load_catalog()
    ItemCatalog = {}
    LastCatalogCount = 0

    local file = io.open(CATALOG_FILE, "r")
    if not file then
        write_state("FAILED", "catalog not found: " .. CATALOG_FILE, "", 0, "")
        return false
    end

    local first = true
    for line in file:lines() do
        if first then
            first = false
        elseif line and line ~= "" then
            local parts = split_tsv(line)
            local code = trim(parts[2])
            local command = trim(parts[3])
            if code ~= "" and command:match("^Summon%s+/Game/Items/") then
                local item = {
                    Code = code,
                    Command = command,
                    Path = trim(parts[4]),
                    Category = trim(parts[1]),
                }
                local key = string.lower(code)
                local previous = ItemCatalog[key]
                if not previous or item_priority(item) > item_priority(previous) then
                    ItemCatalog[key] = item
                end
                LastCatalogCount = LastCatalogCount + 1
            end
        end
    end
    file:close()

    write_state("IDLE", "catalog loaded: " .. tostring(LastCatalogCount), "", 0, "")
    return LastCatalogCount > 0
end

function item_priority(item)
    local text = string.lower(tostring(item.Command or "") .. " " .. tostring(item.Path or ""))
    if text:find("empty", 1, true) then return 1 end
    if text:find("drop", 1, true) then return 2 end
    return 3
end

local function get_player_controller()
    local ok, pc = pcall(function() return FindFirstOf("PlayerController") end)
    if ok and is_valid_object(pc) then return pc end
    return nil
end

local function get_uehelpers()
    if UEHelpers ~= nil then return UEHelpers end
    local ok, helpers = pcall(function() return require("UEHelpers") end)
    if ok and helpers then
        UEHelpers = helpers
        return UEHelpers
    end
    UEHelpers = false
    return nil
end

local function get_world(pc)
    local helpers = get_uehelpers()
    if helpers and helpers.GetWorld then
        local ok, world = pcall(function() return helpers.GetWorld() end)
        if ok and is_valid_object(world) then return world, "UEHelpers.GetWorld" end
    end
    if is_valid_object(pc) then
        local ok, world = pcall(function() return pc:GetWorld() end)
        if ok and is_valid_object(world) then return world, "PlayerController.GetWorld" end
    end
    return nil, "no-world"
end

local function get_player_pawn(pc)
    if not is_valid_object(pc) then return nil, "no-player-controller" end
    local ok1, ap = pcall(function() return pc.AcknowledgedPawn end)
    if ok1 and is_valid_object(ap) then return ap, "AcknowledgedPawn" end

    local ok2, ps = pcall(function() return pc.PlayerState end)
    if ok2 and is_valid_object(ps) then
        local ok3, pp = pcall(function() return ps.PawnPrivate end)
        if ok3 and is_valid_object(pp) then return pp, "PlayerState.PawnPrivate" end
    end

    local ok4, pawn = pcall(function() return pc.Pawn end)
    if ok4 and is_valid_object(pawn) then return pawn, "Pawn" end

    local ok5, pawnFirst = pcall(function() return FindFirstOf("Pawn") end)
    if ok5 and is_valid_object(pawnFirst) then return pawnFirst, "FindFirstOf(Pawn)" end

    local ok6, charFirst = pcall(function() return FindFirstOf("Character") end)
    if ok6 and is_valid_object(charFirst) then return charFirst, "FindFirstOf(Character)" end

    return nil, "no-pawn"
end

local function get_player_location(pc)
    local pawn, pawnSource = get_player_pawn(pc)
    if not is_valid_object(pawn) then return nil, "pawn-not-found:" .. tostring(pawnSource) end

    local ok, root = pcall(function() return pawn.RootComponent end)
    if ok and is_valid_object(root) then
        local okCtw, ctw = pcall(function() return root.ComponentToWorld end)
        if okCtw and ctw and ctw.Translation then
            local t = ctw.Translation
            if type(t.X) == "number" and type(t.Y) == "number" and type(t.Z) == "number" then
                return { X = t.X + 140.0, Y = t.Y, Z = t.Z + 40.0 }, "Pawn.RootComponent.ComponentToWorld.Translation (" .. pawnSource .. ")"
            end
        end
    end

    local okLoc, loc = pcall(function() return pawn:K2_GetActorLocation() end)
    if okLoc and loc and loc.X and loc.Y and loc.Z then
        return {X=loc.X + 140.0, Y=loc.Y, Z=loc.Z + 40.0}, "Pawn.K2_GetActorLocation (" .. pawnSource .. ")"
    end

    if ok and is_valid_object(root) then
        local okRel, rel = pcall(function() return root.RelativeLocation end)
        if okRel and rel and rel.X and rel.Y and rel.Z then
            return {X=rel.X + 140.0, Y=rel.Y, Z=rel.Z + 40.0}, "Pawn.RootComponent.RelativeLocation (" .. pawnSource .. ")"
        end
    end

    return nil, "no-location-fields (" .. pawnSource .. ")"
end

local function add_search_term(terms, value)
    value = string.lower(trim(value or ""))
    if value ~= "" then table.insert(terms, value) end
end

local function item_search_terms(item)
    local terms = {}
    add_search_term(terms, item.Code)
    add_search_term(terms, item.Path)

    local path = tostring(item.Path or "")
    local asset = path:match("([^/]+)%.") or path:match("([^/]+)$")
    if asset then
        add_search_term(terms, asset)
        add_search_term(terms, asset:gsub("_C$", ""))
    end
    return terms
end

local function count_item_actors(item)
    if type(FindAllOf) ~= "function" then
        return nil, "FindAllOf unavailable"
    end

    local ok, actors = pcall(function() return FindAllOf("Actor") end)
    if not ok then return nil, "FindAllOf Actor failed: " .. tostring(actors) end
    if type(actors) ~= "table" then return nil, "FindAllOf Actor returned non-table" end

    local terms = item_search_terms(item)
    local count = 0
    for _, actor in pairs(actors) do
        local name = string.lower(safe_full_name(actor))
        if name ~= "" then
            for _, term in ipairs(terms) do
                if term ~= "" and name:find(term, 1, true) then
                    count = count + 1
                    break
                end
            end
        end
    end
    return count, nil
end

local function item_class_path(item)
    local command = tostring(item.Command or "")
    local classPath = trim(command:match("^Summon%s+(.+)$") or "")
    if classPath ~= "" then return classPath end
    return trim(item.Path or "")
end

local function split_class_path(classPath)
    local packageName, assetName = classPath:match("^(.-)%.([^%.]+)$")
    if not packageName or not assetName then
        packageName = classPath:gsub("_C$", "")
        assetName = packageName:match("([^/]+)$") or ""
    end
    assetName = assetName:gsub("_C$", "")
    return packageName, assetName
end

local function get_asset_registry_class(classPath)
    local helpers = get_uehelpers()
    if not helpers or not helpers.FindOrAddFName then
        return nil, "UEHelpers unavailable"
    end

    local okHelpers, assetRegistryHelpers = pcall(function()
        return StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end)
    if not okHelpers or not is_valid_object(assetRegistryHelpers) then
        return nil, "AssetRegistryHelpers invalid"
    end

    local packageName, assetName = split_class_path(classPath)
    if packageName == "" or assetName == "" then
        return nil, "invalid class path"
    end

    local assetData
    if UnrealVersion and UnrealVersion.IsBelow and UnrealVersion.IsBelow(5, 1) then
        assetData = {
            ["ObjectPath"] = helpers.FindOrAddFName(packageName .. "." .. assetName),
        }
    else
        assetData = {
            ["PackageName"] = helpers.FindOrAddFName(packageName),
            ["AssetName"] = helpers.FindOrAddFName(assetName),
        }
    end

    local okAsset, asset = pcall(function() return assetRegistryHelpers:GetAsset(assetData) end)
    if okAsset and is_valid_object(asset) then
        return asset, "AssetRegistryHelpers.GetAsset"
    end
    return nil, "asset registry miss: " .. tostring(okAsset and asset or okAsset)
end

local function safe_static_load_object(classType, outer, path)
    if type(StaticLoadObject) ~= "function" then return nil end
    local ok, obj = pcall(function() return StaticLoadObject(classType, outer, path) end)
    if ok and is_valid_object(obj) then return obj end
    return nil
end

local function resolve_generated_class(obj)
    if not is_valid_object(obj) then return nil end
    local className = safe_class_full_name(obj)
    if className:find("Blueprint", 1, true) and not className:find("GeneratedClass", 1, true) then
        local ok, genClass = pcall(function() return obj.GeneratedClass end)
        if ok and is_valid_object(genClass) then
            return genClass
        end
    end
    return obj
end

local function resolve_item_class_raw(item)
    local classPath = item_class_path(item)
    if classPath == "" then return nil, "empty class path" end

    local candidates = {
        classPath,
        "BlueprintGeneratedClass " .. classPath,
        classPath:gsub("_C$", ""),
        "Blueprint " .. classPath:gsub("_C$", ""),
    }
    for _, candidate in ipairs(candidates) do
        local ok, obj = pcall(function() return StaticFindObject(candidate) end)
        if ok and is_valid_object(obj) then
            return obj, "StaticFindObject:" .. candidate
        end
    end

    -- Try StaticLoadObject if available
    local classType = StaticFindObject("/Script/CoreUObject.Class")
    local loaded = safe_static_load_object(classType, nil, classPath)
    if is_valid_object(loaded) then
        return loaded, "StaticLoadObject(Class):" .. classPath
    end

    loaded = safe_static_load_object(nil, nil, classPath)
    if is_valid_object(loaded) then
        return loaded, "StaticLoadObject(nil):" .. classPath
    end

    local loadNoSuffix = classPath:gsub("_C$", "")
    loaded = safe_static_load_object(nil, nil, loadNoSuffix)
    if is_valid_object(loaded) then
        return loaded, "StaticLoadObject(nil):" .. loadNoSuffix
    end

    return get_asset_registry_class(classPath)
end

local function resolve_item_class(item)
    local classObj, source = resolve_item_class_raw(item)
    if is_valid_object(classObj) then
        local resolved = resolve_generated_class(classObj)
        if is_valid_object(resolved) then
            if resolved ~= classObj then
                return resolved, source .. "->GeneratedClass"
            end
            return resolved, source
        end
    end
    return classObj, source
end

local function set_actor_location(actor, location)
    if not is_valid_object(actor) or not location then return false, "no-actor-or-location" end
    local loc = {X=location.X, Y=location.Y, Z=location.Z}

    local okSetActor = pcall(function() return actor:K2_SetActorLocation(loc, false, {}, true) end)
    if okSetActor then return true, "Actor.K2_SetActorLocation" end

    local okRoot, root = pcall(function() return actor.RootComponent end)
    if okRoot and is_valid_object(root) then
        local okRel = pcall(function() root.RelativeLocation = loc end)
        if okRel then return true, "Root.RelativeLocation" end
    end

    return false, "location-set-failed"
end

local function try_direct_spawn(pc, item, qty)
    local world, worldSource = get_world(pc)
    if not is_valid_object(world) then return false, "no-world:" .. tostring(worldSource) end

    local classObj, classSource = resolve_item_class(item)
    if not is_valid_object(classObj) then return false, "no-class:" .. tostring(classSource) end

    local playerLoc, locSource = get_player_location(pc)
    local spawned = 0
    local lastActorName = ""
    local lastPlacement = "not-attempted"
    for i = 1, qty do
        local okSpawn, actor = pcall(function() return world:SpawnActor(classObj, {}, {}) end)
        if not okSpawn or not is_valid_object(actor) then
            if spawned > 0 then
                return true, "World.SpawnActor partial +" .. tostring(spawned) .. " spawn-error=" .. tostring(actor)
            end
            return false, "spawn-failed:" .. tostring(actor)
        end

        spawned = spawned + 1
        lastActorName = safe_full_name(actor)
        if playerLoc then
            local target = {X=playerLoc.X + ((i - 1) * 35.0), Y=playerLoc.Y, Z=playerLoc.Z}
            local placed, placeMethod = set_actor_location(actor, target)
            lastPlacement = tostring(placeMethod)
            if not placed then
                lastPlacement = "placement failed:" .. tostring(placeMethod)
            end
        else
            lastPlacement = "no location:" .. tostring(locSource)
        end
    end

    return true, "World.SpawnActor +" .. tostring(spawned) .. " class=" .. tostring(classSource) .. " place=" .. tostring(lastPlacement) .. " actor=" .. tostring(lastActorName)
end

local function try_console_command(pc, command)
    if not is_valid_object(pc) then return false, "no-player-controller" end

    local ok = pcall(function()
        return pc:ConsoleCommand(command, true)
    end)
    if ok then return true, "PlayerController.ConsoleCommand" end

    ok = pcall(function()
        return pc:ConsoleCommand(command)
    end)
    if ok then return true, "PlayerController.ConsoleCommand/1" end

    return false, "console-command-failed"
end

local function try_cheat_manager(pc, command)
    if not is_valid_object(pc) then return false, "no-player-controller" end
    local asset = trim(command:gsub("^Summon%s+", ""))

    local okCm, cm = pcall(function() return pc.CheatManager end)
    if not okCm or not is_valid_object(cm) then
        return false, "no-cheat-manager"
    end

    local ok = pcall(function()
        return cm:Summon(asset)
    end)
    if ok then return true, "CheatManager.Summon" end

    return false, "cheat-summon-failed"
end

local function try_kismet_console(pc, command)
    local okKs, ks = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end)
    if not okKs or not is_valid_object(ks) then
        return false, "no-kismet-system-library"
    end

    local ok = pcall(function()
        return ks:ExecuteConsoleCommand(pc, command, pc)
    end)
    if ok then return true, "KismetSystemLibrary.ExecuteConsoleCommand" end

    ok = pcall(function()
        return ks:ExecuteConsoleCommand(pc, command)
    end)
    if ok then return true, "KismetSystemLibrary.ExecuteConsoleCommand/2" end

    ok = pcall(function()
        return ks:ExecuteConsoleCommand(command)
    end)
    if ok then return true, "KismetSystemLibrary.ExecuteConsoleCommand/1" end

    return false, "kismet-console-failed"
end

local function dispatch_summon_verified(item, qty)
    local pc = get_player_controller()
    local errors = {}
    local accepted = {}
    local beforeCount, beforeErr = count_item_actors(item)
    local afterCount = beforeCount

    local okDirect, directMethod = try_direct_spawn(pc, item, qty)
    if okDirect then
        afterCount = count_item_actors(item)
        return true, "SPAWNED", directMethod, qty, beforeCount, afterCount, ""
    end
    table.insert(errors, "DirectSpawn=" .. tostring(directMethod))

    local function call_method(label, fn)
        local ok, method = fn(pc, item.Command)
        if not ok then
            table.insert(errors, method)
            return false, method
        end

        table.insert(accepted, method)
        for _ = 2, qty do
            local okRepeat, repeatMethod = fn(pc, item.Command)
            if not okRepeat then
                table.insert(errors, repeatMethod)
                break
            end
            method = repeatMethod
        end

        if beforeCount ~= nil then
            local countNow, countErr = count_item_actors(item)
            afterCount = countNow
            if countNow ~= nil and countNow > beforeCount then
                return true, method, "SPAWNED", countNow - beforeCount
            end
            table.insert(errors, label .. "=no-actor-change:" .. tostring(countErr or countNow))
        else
            table.insert(errors, label .. "=unverified:" .. tostring(beforeErr))
        end

        return true, method, "SENT_UNVERIFIED", 0
    end

    local ok, method, state, spawned = call_method("Kismet", try_kismet_console)
    if ok and state == "SPAWNED" then return true, state, method, spawned, beforeCount, afterCount, table.concat(errors, ";") end
    if ok and beforeCount == nil then return true, state, method, spawned, beforeCount, afterCount, table.concat(errors, ";") end

    ok, method, state, spawned = call_method("PlayerController", try_console_command)
    if ok and state == "SPAWNED" then return true, state, method, spawned, beforeCount, afterCount, table.concat(errors, ";") end
    if ok and beforeCount == nil then return true, state, method, spawned, beforeCount, afterCount, table.concat(errors, ";") end

    ok, method, state, spawned = call_method("CheatManager", try_cheat_manager)
    if ok and state == "SPAWNED" then return true, state, method, spawned, beforeCount, afterCount, table.concat(errors, ";") end

    if #accepted > 0 then
        return true, "SENT_UNVERIFIED", table.concat(accepted, ","), qty, beforeCount, afterCount, table.concat(errors, ";")
    end

    return false, "FAILED", table.concat(errors, ";"), 0, beforeCount, afterCount, table.concat(errors, ";")
end

local function spawn_item(code, qty)
    code = trim(code)
    qty = tonumber(qty)
    if code == "" then
        write_state("FAILED", "empty item code", code, 0, "")
        return
    end
    if not qty or qty < 1 or qty > MAX_QTY or qty ~= math.floor(qty) then
        write_state("FAILED", "quantity must be 1-" .. tostring(MAX_QTY), code, tostring(qty), "")
        return
    end

    local item = ItemCatalog[string.lower(code)]
    if not item then
        load_catalog()
        item = ItemCatalog[string.lower(code)]
    end
    if not item then
        write_state("FAILED", "unknown item code", code, qty, "")
        return
    end

    write_state("BUSY", "sending summon command", item.Code, qty, "", item.Command)
    local ok, state, method, spawned, beforeCount, afterCount, details = dispatch_summon_verified(item, qty)
    if not ok then
        write_state("FAILED", method, item.Code, qty, "", item.Command)
        print(string.format("[ItemMod v%s] Spawn failed: %s x%d errors=%s\n", MOD_VERSION, item.Code, qty, tostring(method)))
        return
    end

    if state == "SPAWNED" then
        write_state("SPAWNED", "verified spawned actors +" .. tostring(spawned), item.Code, qty, method, item.Command)
    else
        local counts = "before=" .. tostring(beforeCount) .. " after=" .. tostring(afterCount)
        write_state("SENT_UNVERIFIED", "command sent but actor not verified; " .. counts .. "; " .. tostring(details), item.Code, qty, method, item.Command)
    end
    print(string.format("[ItemMod v%s] Spawn result: %s %s x%d via %s\n", MOD_VERSION, tostring(state), item.Code, qty, tostring(method)))
end

local INVENTORY_KEYWORDS = {
    "inventory", "inventar", "item", "items", "container", "backpack", "bag",
    "stack", "amount", "quantity", "count", "slot", "equipment", "equip",
    "quest", "pickup", "loot", "weapon", "armor", "consumable", "potion",
    "inventories", "slots", "pouch", "maincontainer", "definition", "virtualdata",
}

local INVENTORY_FUNCTION_KEYWORDS = {
    "additem", "removeitem", "add_item", "remove_item", "inventory", "container",
    "slot", "count", "quantity", "stack", "takeout", "take_out", "trytakeout",
    "set_additems", "set_removeitems", "maincontainer", "pouch", "item",
    "datamodule", "data_module", "refreshinventory", "getinventory",
    "additemofclass", "removeitemofclass",
}

local INVENTORY_DIRECT_FUNCTION_NAMES = {
    "AddItem",
    "RemoveItem",
    "Set_AddItems",
    "Set_RemoveItems",
    "TryTakeOutItemIfPossible",
    "AddItemToTakeOutToInventoryIfMissing",
    "Array_RemoveItem",
    "AddItemOfClass",
    "RemoveItemOfClass",
}

local INVENTORY_LIST_FUNCTION_NAMES = {
    "GetItems",
    "GetAllItems",
    "GetInventoryItems",
    "GetItemList",
    "GetItemStacks",
    "GetStacks",
    "GetEntries",
    "GetSlots",
    "GetContent",
}

local INVENTORY_LIST_FIELD_NAMES = {
    "Items",
    "m_Items",
    "InventoryItems",
    "m_InventoryItems",
    "ItemList",
    "m_ItemList",
    "ItemStacks",
    "m_ItemStacks",
    "Entries",
    "m_Entries",
    "Slots",
    "m_Slots",
    "Content",
    "m_Content",
}

local INVENTORY_ENTRY_CODE_FIELDS = {
    "ItemClass",
    "m_ItemClass",
    "Class",
    "m_Class",
    "ASClass",
    "m_ASClass",
    "ItemDefinition",
    "m_ItemDefinition",
    "Definition",
    "m_Definition",
    "Item",
    "m_Item",
    "ItemData",
    "m_ItemData",
    "Data",
    "m_Data",
    "ItemType",
    "m_ItemType",
    "Code",
    "Name",
    "ItemName",
    "ItemId",
    "ItemID",
}

local INVENTORY_ENTRY_QTY_FIELDS = {
    "Quantity",
    "m_Quantity",
    "Count",
    "m_Count",
    "Amount",
    "m_Amount",
    "Stack",
    "m_Stack",
    "StackSize",
    "m_StackSize",
    "ItemCount",
    "m_ItemCount",
    "Num",
    "m_Num",
}

local INVENTORY_TARGET_CLASS_NAMES = {
    "InventoryComponent",
    "DataModule_Container",
    "MainContainerPackage",
    "MainContainer",
    "ItemContainer",
    "ContainerComponent",
    "PlayerInventoryComponent",
}

local INVENTORY_PLAYER_PROBE_KEYWORDS = {
    "inventory", "inventar", "container", "datamodule", "data module",
    "module", "pouch", "item", "equipment", "equip", "component",
}

local INVENTORY_DIRECT_PLAYER_FIELDS = {
    "InventoryComponent",
    "m_InventoryComponent",
    "DataModuleComponent",
    "m_DataModuleComponent",
    "DataModule_Container",
    "m_DataModule_Container",
    "DataModuleContainer",
    "m_DataModuleContainer",
    "Inventory",
    "m_Inventory",
    "Container",
    "m_Container",
}

local INVENTORY_COMPONENT_CLASS_NAMES = {
    "InventoryComponent",
    "DataModuleComponent",
}

local INVENTORY_DISPLAY_ONLY = {
    "widget", "hud", "ui", "umg", "viewport", "screen", "textblock",
    "button", "image", "cursor", "camera", "animation", "anim", "sound",
    "material", "font", "opacity", "progressbar",
}

local INVENTORY_OBJECT_TYPES = {
    ObjectProperty = true,
    StructProperty = true,
}

local INVENTORY_SIMPLE_TYPES = {
    IntProperty = true, Int64Property = true, ByteProperty = true,
    UInt32Property = true, UInt64Property = true, Int8Property = true,
    Int16Property = true, UInt16Property = true, FloatProperty = true,
    BoolProperty = true, StrProperty = true, NameProperty = true,
    TextProperty = true, EnumProperty = true,
}

local InventoryVisited = {}

local function safe_lower(value)
    return string.lower(tostring(value or ""))
end

local function contains_any(value, terms)
    local text = safe_lower(value)
    if text == "" then return false end
    for _, term in ipairs(terms) do
        if text:find(term, 1, true) then return true end
    end
    return false
end

local function clean_inventory_field(value, maxLen)
    local text = clean(value):gsub("|", "/")
    local limit = tonumber(maxLen) or 180
    local length = tonumber(#text) or 0
    if length > limit then
        text = text:sub(1, limit - 3) .. "..."
    end
    return text
end

local function inventory_line(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = clean_inventory_field(select(i, ...))
    end
    return table.concat(parts, "|")
end

local function write_inventory_lines(lines)
    pcall(function()
        local usedTmp = true
        local file = io.open(INVENTORY_STATE_TMP_FILE, "w")
        if not file then
            usedTmp = false
            file = io.open(INVENTORY_STATE_FILE, "w")
        end
        if not file then return end
        for _, line in ipairs(lines) do
            file:write(line)
            file:write("\n")
        end
        file:write(inventory_line("UPDATED", tostring(os.time()), now_text(), MOD_VERSION))
        file:write("\n")
        file:close()

        if usedTmp then
            pcall(function() os.remove(INVENTORY_STATE_FILE) end)
            pcall(function() os.rename(INVENTORY_STATE_TMP_FILE, INVENTORY_STATE_FILE) end)
        end
    end)
end

local function write_inventory_list_lines(lines)
    pcall(function()
        local usedTmp = true
        local file = io.open(INVENTORY_LIST_TMP_FILE, "w")
        if not file then
            usedTmp = false
            file = io.open(INVENTORY_LIST_FILE, "w")
        end
        if not file then return end
        for _, line in ipairs(lines) do
            file:write(line)
            file:write("\n")
        end
        file:write(inventory_line("UPDATED", tostring(os.time()), now_text(), MOD_VERSION))
        file:write("\n")
        file:close()

        if usedTmp then
            pcall(function() os.remove(INVENTORY_LIST_FILE) end)
            pcall(function() os.rename(INVENTORY_LIST_TMP_FILE, INVENTORY_LIST_FILE) end)
        end
    end)
end

local function safe_get(obj, field)
    if obj == nil or field == nil or field == "" then return nil end
    local ok, value = pcall(function() return obj[field] end)
    if ok then return value end
    return nil
end

local function safe_find_first_of(className)
    local ok, obj = pcall(function() return FindFirstOf(className) end)
    if ok and is_valid_object(obj) then return obj end
    return nil
end

local function get_prop_type_name(prop)
    local ok1, cls = pcall(function() return prop:GetClass() end)
    if not ok1 or not cls then return "" end
    local ok2, fn = pcall(function() return cls:GetFName() end)
    if not ok2 or not fn then return "" end
    local ok3, text = pcall(function() return fn:ToString() end)
    if ok3 and text then return tostring(text) end
    return ""
end

local function get_prop_name(prop)
    local ok, fn = pcall(function() return prop:GetFName() end)
    if not ok or not fn then return "" end
    local ok2, text = pcall(function() return fn:ToString() end)
    if ok2 and text then return tostring(text) end
    return ""
end

local function safe_class_full_name(obj)
    if not is_valid_object(obj) then return "" end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if ok and is_valid_object(cls) then return safe_full_name(cls) end
    return ""
end

local function for_each_property(obj, cb)
    if not is_valid_object(obj) then return end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not is_valid_object(cls) then return end

    local cur = cls
    local guard = 0
    while is_valid_object(cur) and guard < 64 do
        guard = guard + 1
        pcall(function()
            cur:ForEachProperty(function(prop)
                if prop and is_valid_object(prop) then
                    return cb(prop, safe_full_name(cur))
                end
                return false
            end)
        end)

        local okSuper, super = pcall(function() return cur:GetSuperStruct() end)
        if not okSuper then break end
        cur = super
    end
end

local function get_inventory_player_pawn()
    local pc = get_player_controller()
    if is_valid_object(pc) then
        local pawn = safe_get(pc, "Pawn")
        if is_valid_object(pawn) then return pawn end

        pawn = safe_get(pc, "AcknowledgedPawn")
        if is_valid_object(pawn) then return pawn end

        local ps = safe_get(pc, "PlayerState")
        if is_valid_object(ps) then
            pawn = safe_get(ps, "PawnPrivate")
            if is_valid_object(pawn) then return pawn end
        end
    end

    return safe_find_first_of("Pawn") or safe_find_first_of("Character")
end

local function get_inventory_root_object(kind)
    if kind == "PC" then
        return get_player_controller()
    elseif kind == "PlayerState" then
        local pc = get_player_controller()
        if is_valid_object(pc) then return safe_get(pc, "PlayerState") end
    elseif kind == "Pawn" then
        return get_inventory_player_pawn()
    elseif kind == "GameInstance" then
        return safe_find_first_of("GameInstance")
    elseif kind == "GameMode" then
        return safe_find_first_of("GameModeBase") or safe_find_first_of("GameMode")
    elseif kind == "GameState" then
        return safe_find_first_of("GameStateBase") or safe_find_first_of("GameState")
    end
    return nil
end

local function object_address_key(rootKind, obj)
    local ok, address = pcall(function() return obj:GetAddress() end)
    if ok and address and address ~= 0 then return rootKind .. ":" .. tostring(address) end
    local fullName = safe_full_name(obj)
    if fullName ~= "" then return rootKind .. ":" .. fullName end
    return nil
end

local function array_count(value)
    if value == nil then return nil end

    local okArrayNum, arrayNum = pcall(function() return value:GetArrayNum() end)
    if okArrayNum and type(arrayNum) == "number" then return arrayNum end

    local ok, count = pcall(function() return value:Num() end)
    if ok and type(count) == "number" then return count end

    local okLen, len = pcall(function() return #value end)
    if okLen and type(len) == "number" then return len end

    return nil
end

local function describe_value(value)
    local vt = type(value)
    if value == nil then return "nil" end
    if vt == "number" or vt == "boolean" or vt == "string" then return tostring(value) end

    local count = array_count(value)
    if count ~= nil then
        return "Array Num=" .. tostring(count)
    end

    if is_valid_object(value) then
        local fullName = safe_full_name(value)
        if fullName ~= "" then return fullName end
        return "valid object"
    end

    return tostring(value)
end

local function inventory_score(path, propName, className, typeName, valueText)
    local score = 0
    if contains_any(propName, INVENTORY_KEYWORDS) then score = score + 10 end
    if contains_any(path, INVENTORY_KEYWORDS) then score = score + 7 end
    if contains_any(className, INVENTORY_KEYWORDS) then score = score + 5 end
    if contains_any(typeName, INVENTORY_KEYWORDS) then score = score + 4 end
    if contains_any(valueText, INVENTORY_KEYWORDS) then score = score + 3 end
    if typeName == "ArrayProperty" or typeName == "MapProperty" or typeName == "SetProperty" then score = score + 2 end
    if INVENTORY_OBJECT_TYPES[typeName] then score = score + 1 end
    if contains_any(path, INVENTORY_DISPLAY_ONLY) or contains_any(className, INVENTORY_DISPLAY_ONLY) then score = score - 8 end
    return score
end

local function add_inventory_result(ctx, row)
    if #ctx.results >= INVENTORY_MAX_RESULTS then return end
    local key = table.concat(row, "\0")
    if ctx.seen[key] then return end
    ctx.seen[key] = true
    table.insert(ctx.results, row)
end

local scan_inventory_object = nil

local function scan_inventory_array(rootKind, value, path, depth, ctx)
    local count = array_count(value)
    if count == nil or count <= 0 then return end
    local maxIndex = math.min(count - 1, 7)
    for i = 0, maxIndex do
        local okItem, item = pcall(function() return value:Get(i) end)
        if okItem and is_valid_object(item) then
            scan_inventory_object(rootKind, item, path .. "[" .. tostring(i) .. "]", depth + 1, ctx)
        end
    end
end

scan_inventory_object = function(rootKind, obj, path, depth, ctx)
    if not is_valid_object(obj) or depth > INVENTORY_MAX_DEPTH then return end
    if ctx.scannedObjects >= INVENTORY_MAX_OBJECTS then return end

    local visitKey = object_address_key(rootKind, obj)
    if visitKey then
        if InventoryVisited[visitKey] then return end
        InventoryVisited[visitKey] = true
    end

    ctx.scannedObjects = ctx.scannedObjects + 1
    local className = safe_class_full_name(obj)
    local objectName = safe_full_name(obj)
    local objScore = inventory_score(path, path, className, "Object", objectName)
    if objScore >= 5 then
        add_inventory_result(ctx, { "INVOBJ", rootKind, path, "Object", className, tostring(objScore), objectName })
    end

    for_each_property(obj, function(prop, declaringClass)
        local typeName = get_prop_type_name(prop)
        local propName = get_prop_name(prop)
        if propName == "" then return end

        local nextPath = (path == "" and propName) or (path .. "." .. propName)
        local okValue, value = pcall(function() return obj[propName] end)
        local valueText = okValue and describe_value(value) or "read-error"
        local score = inventory_score(nextPath, propName, declaringClass, typeName, valueText)

        if score >= 5 or (INVENTORY_SIMPLE_TYPES[typeName] and contains_any(nextPath, { "amount", "quantity", "count", "stack" })) then
            add_inventory_result(ctx, { "INVPROP", rootKind, nextPath, typeName, valueText, tostring(score), declaringClass })
        end

        if depth < INVENTORY_MAX_DEPTH and score >= -3 then
            if INVENTORY_OBJECT_TYPES[typeName] and is_valid_object(value) then
                scan_inventory_object(rootKind, value, nextPath, depth + 1, ctx)
            elseif typeName == "ArrayProperty" then
                scan_inventory_array(rootKind, value, nextPath, depth + 1, ctx)
            end
        end
    end)
end

local function inventory_result_line(row)
    return inventory_line(row[1], row[2], row[3], row[4], row[5], row[6], row[7])
end

local function scan_inventory_components(rootKind, host, ctx)
    if not is_valid_object(host) then return end
    local ok, comps = pcall(function() return host:GetAllComponents() end)
    if not ok or comps == nil then return end

    local count = array_count(comps)
    if count == nil then return end
    local maxIndex = math.min(count - 1, INVENTORY_MAX_COMPONENTS - 1)
    for i = 0, maxIndex do
        local okComp, comp = pcall(function() return comps:Get(i) end)
        if okComp and is_valid_object(comp) then
            scan_inventory_object(rootKind .. ".Component", comp, "Component[" .. tostring(i) .. "]", 0, ctx)
        end
    end
end

local function read_inventory_candidate_value(obj, propName, typeName)
    local ok, value = pcall(function() return obj[propName] end)
    if not ok then return "read-error" end

    if typeName == "ArrayProperty" or typeName == "SetProperty" then
        local count = array_count(value)
        if count ~= nil then return "Array Num=" .. tostring(count) end
    end

    return describe_value(value)
end

local function read_detail_value(obj, propName, typeName)
    local ok, value = pcall(function() return obj[propName] end)
    if not ok then return "read-error" end

    if typeName == "ArrayProperty" or typeName == "SetProperty" or typeName == "MapProperty" then
        local count = array_count(value)
        if count ~= nil then return "Collection Num=" .. tostring(count) end
        return "Collection"
    end

    if INVENTORY_SIMPLE_TYPES[typeName] then return describe_value(value) end
    if is_valid_object(value) then return safe_full_name(value) end
    if value == nil then return "nil" end
    return type(value)
end

local function scan_inventory_root_shallow(rootKind, root, results)
    if not is_valid_object(root) then return 0 end

    local inspected = 0
    for_each_property(root, function(prop, declaringClass)
        if #results >= INVENTORY_MAX_RESULTS then return end

        local typeName = get_prop_type_name(prop)
        local propName = get_prop_name(prop)
        if propName == "" then return end

        local baseScore = inventory_score(propName, propName, declaringClass, typeName, "")
        if baseScore < 5 then return end

        inspected = inspected + 1
        local valueText = read_inventory_candidate_value(root, propName, typeName)
        local score = inventory_score(propName, propName, declaringClass, typeName, valueText)
        if score >= 5 then
            table.insert(results, { "INVPROP", rootKind, propName, typeName, valueText, tostring(score), declaringClass })
        end
    end)

    return inspected
end

local function scan_inventory()
    write_inventory_lines({
        inventory_line("STATUS", "BUSY", "light inventory scan"),
    })

    local results = {}
    local inspected = 0
    local roots = { "PC", "PlayerState", "Pawn", "GameInstance" }
    local rootLines = {}

    for _, rootKind in ipairs(roots) do
        local root = get_inventory_root_object(rootKind)
        if is_valid_object(root) then
            table.insert(rootLines, inventory_line("ROOT", rootKind, safe_class_full_name(root), safe_full_name(root)))
            inspected = inspected + scan_inventory_root_shallow(rootKind, root, results)
        else
            table.insert(rootLines, inventory_line("ROOT", rootKind, "missing", ""))
        end
    end

    table.sort(results, function(a, b)
        local scoreA = tonumber(a[6]) or 0
        local scoreB = tonumber(b[6]) or 0
        if scoreA ~= scoreB then return scoreA > scoreB end
        return tostring(a[3]) < tostring(b[3])
    end)

    local lines = {
        inventory_line("STATUS", "OK", "light scan complete", "results=" .. tostring(#results), "inspected=" .. tostring(inspected)),
    }
    for _, line in ipairs(rootLines) do table.insert(lines, line) end
    for _, row in ipairs(results) do table.insert(lines, inventory_result_line(row)) end

    write_inventory_lines(lines)
    print(string.format("[ItemMod v%s] Light inventory scan complete: results=%d inspected=%d\n", MOD_VERSION, #results, inspected))
end

local function get_uobject_name(obj)
    if not is_valid_object(obj) then return "" end
    local ok, fn = pcall(function() return obj:GetFName() end)
    if ok and fn then
        local okText, text = pcall(function() return fn:ToString() end)
        if okText and text then return tostring(text) end
    end

    local fullName = safe_full_name(obj)
    return fullName:match("([^%s%.]+)$") or fullName
end

local function function_flags_text(fn)
    local ok, flags = pcall(function() return fn:GetFunctionFlags() end)
    if ok and flags ~= nil then return tostring(flags) end
    return ""
end

local function for_each_function(obj, cb)
    if not is_valid_object(obj) then return end

    local starts = { obj }
    local okClass, cls = pcall(function() return obj:GetClass() end)
    if okClass and is_valid_object(cls) then table.insert(starts, cls) end

    local seenStructs = {}
    for _, start in ipairs(starts) do
        local cur = start
        local guard = 0
        while is_valid_object(cur) and guard < 64 do
            guard = guard + 1
            local key = object_address_key("FUNCSTRUCT", cur) or safe_full_name(cur)
            if key ~= "" and not seenStructs[key] then
                seenStructs[key] = true
                pcall(function()
                    cur:ForEachFunction(function(fn)
                        if fn and is_valid_object(fn) then
                            return cb(fn, safe_full_name(cur)) == true
                        end
                        return false
                    end)
                end)
            end

            local okSuper, super = pcall(function() return cur:GetSuperStruct() end)
            if not okSuper or not is_valid_object(super) then break end
            cur = super
        end
    end
end

local function add_inventory_probe_line(ctx, ...)
    if #ctx.lines >= INVENTORY_MAX_RESULTS then return end
    table.insert(ctx.lines, inventory_line(...))
end

local function add_inventory_probe_line_and_flush(ctx, ...)
    add_inventory_probe_line(ctx, ...)
    write_inventory_lines(ctx.lines)
end

local function inventory_target_key(obj)
    return object_address_key("TARGET", obj) or safe_full_name(obj)
end

local function add_inventory_probe_target(ctx, label, obj)
    if not is_valid_object(obj) or #ctx.targets >= INVENTORY_FIND_MAX_TARGETS then return end

    local key = inventory_target_key(obj)
    if key ~= "" and ctx.targetSeen[key] then return end
    if key ~= "" then ctx.targetSeen[key] = true end

    table.insert(ctx.targets, { Label = label, Object = obj })
    add_inventory_probe_line(ctx, "TARGET", label, safe_class_full_name(obj), safe_full_name(obj))
end

local function probe_known_inventory_classes(ctx)
    for _, className in ipairs(INVENTORY_TARGET_CLASS_NAMES) do
        local obj = safe_find_first_of(className)
        if is_valid_object(obj) then
            add_inventory_probe_line(ctx, "CLASS_PROBE", className, "FOUND", safe_class_full_name(obj), safe_full_name(obj))
            add_inventory_probe_target(ctx, "FindFirstOf(" .. className .. ")", obj)
        else
            add_inventory_probe_line(ctx, "CLASS_PROBE", className, "missing", "", "")
        end
    end
end

local function probe_root_inventory_candidates(ctx)
    local roots = { "PC", "PlayerState", "Pawn", "GameInstance" }

    for _, rootKind in ipairs(roots) do
        local root = get_inventory_root_object(rootKind)
        if is_valid_object(root) then
            add_inventory_probe_line(ctx, "ROOT", rootKind, safe_class_full_name(root), safe_full_name(root))

            for_each_property(root, function(prop, declaringClass)
                if #ctx.propertyLines >= INVENTORY_FIND_MAX_PROPERTIES then return true end

                local typeName = get_prop_type_name(prop)
                local propName = get_prop_name(prop)
                if propName == "" then return false end

                local descriptor = propName .. " " .. declaringClass .. " " .. typeName
                if not contains_any(descriptor, INVENTORY_KEYWORDS) then return false end

                local okValue, value = pcall(function() return root[propName] end)
                local valueText = okValue and describe_value(value) or "read-error"
                table.insert(ctx.propertyLines, inventory_line("ROOT_PROP", rootKind, propName, typeName, valueText, declaringClass))

                if okValue and is_valid_object(value) then
                    add_inventory_probe_target(ctx, rootKind .. "." .. propName, value)
                end
                return false
            end)
        else
            add_inventory_probe_line(ctx, "ROOT", rootKind, "missing", "")
        end
    end
end

local function probe_target_direct_methods(ctx, label, obj)
    for _, functionName in ipairs(INVENTORY_DIRECT_FUNCTION_NAMES) do
        local value = safe_get(obj, functionName)
        if value ~= nil then
            add_inventory_probe_line(ctx, "METHOD", label, functionName, type(value), tostring(value))
        end
    end
end

local function probe_target_properties(ctx, label, obj)
    for_each_property(obj, function(prop, declaringClass)
        if #ctx.propertyLines >= INVENTORY_FIND_MAX_PROPERTIES then return true end

        local typeName = get_prop_type_name(prop)
        local propName = get_prop_name(prop)
        if propName == "" then return false end

        local descriptor = propName .. " " .. declaringClass .. " " .. typeName
        if not contains_any(descriptor, INVENTORY_KEYWORDS) then return false end

        local valueText = read_inventory_candidate_value(obj, propName, typeName)
        table.insert(ctx.propertyLines, inventory_line("TARGET_PROP", label, propName, typeName, valueText, declaringClass))
        return false
    end)
end

local function probe_target_functions(ctx, label, obj)
    local matched = 0
    local inspected = 0

    probe_target_direct_methods(ctx, label, obj)
    probe_target_properties(ctx, label, obj)

    for_each_function(obj, function(fn, declaringClass)
        if ctx.functionCount >= INVENTORY_FIND_MAX_FUNCTIONS then return true end

        inspected = inspected + 1
        local functionName = get_uobject_name(fn)
        local fullName = safe_full_name(fn)
        local descriptor = functionName .. " " .. fullName .. " " .. declaringClass

        if contains_any(descriptor, INVENTORY_FUNCTION_KEYWORDS) then
            matched = matched + 1
            ctx.functionCount = ctx.functionCount + 1
            add_inventory_probe_line(ctx, "FUNC", label, functionName, function_flags_text(fn), declaringClass, fullName)
        end
        return false
    end)

    add_inventory_probe_line(ctx, "FUNC_SUMMARY", label, "matched=" .. tostring(matched), "inspected=" .. tostring(inspected))
end

local function find_inventory_functions()
    write_inventory_lines({
        inventory_line("STATUS", "BUSY", "narrow inventory function probe"),
    })

    local ctx = {
        lines = {
            inventory_line("STATUS", "OK", "narrow inventory function probe"),
        },
        targets = {},
        targetSeen = {},
        propertyLines = {},
        functionCount = 0,
    }

    probe_known_inventory_classes(ctx)
    probe_root_inventory_candidates(ctx)

    for _, target in ipairs(ctx.targets) do
        probe_target_functions(ctx, target.Label, target.Object)
    end

    for _, line in ipairs(ctx.propertyLines) do
        if #ctx.lines < INVENTORY_MAX_RESULTS then table.insert(ctx.lines, line) end
    end

    table.insert(ctx.lines, inventory_line("SUMMARY", "targets=" .. tostring(#ctx.targets), "functions=" .. tostring(ctx.functionCount), "properties=" .. tostring(#ctx.propertyLines)))

    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] Inventory function probe complete: targets=%d functions=%d properties=%d\n", MOD_VERSION, #ctx.targets, ctx.functionCount, #ctx.propertyLines))
end

local function class_from_first_object(className)
    local sample = safe_find_first_of(className)
    if not is_valid_object(sample) then return nil end

    local ok, cls = pcall(function() return sample:GetClass() end)
    if ok and is_valid_object(cls) then return cls end
    return nil
end

local function probe_direct_player_fields(ctx, label, obj)
    for _, fieldName in ipairs(INVENTORY_DIRECT_PLAYER_FIELDS) do
        local value = safe_get(obj, fieldName)
        if value ~= nil then
            add_inventory_probe_line(ctx, "DIRECT_FIELD", label, fieldName, type(value), describe_value(value))
            if is_valid_object(value) then
                add_inventory_probe_target(ctx, label .. "." .. fieldName, value)
            end
        end
    end
end

local function probe_get_component_by_class(ctx, label, obj)
    if not is_valid_object(obj) then return end

    for _, className in ipairs(INVENTORY_COMPONENT_CLASS_NAMES) do
        local cls = class_from_first_object(className)
        if is_valid_object(cls) then
            local ok, comp = pcall(function() return obj:GetComponentByClass(cls) end)
            if ok and is_valid_object(comp) then
                add_inventory_probe_line(ctx, "GET_COMPONENT", label, className, "FOUND", safe_class_full_name(comp), safe_full_name(comp))
                add_inventory_probe_target(ctx, label .. ".GetComponentByClass(" .. className .. ")", comp)
            elseif ok then
                add_inventory_probe_line(ctx, "GET_COMPONENT", label, className, "missing", "", "")
            else
                add_inventory_probe_line(ctx, "GET_COMPONENT", label, className, "call-failed", tostring(comp), "")
            end
        else
            add_inventory_probe_line(ctx, "GET_COMPONENT", label, className, "class-missing", "", "")
        end
    end
end

local function probe_player_root_properties(ctx, label, root)
    for_each_property(root, function(prop, declaringClass)
        if #ctx.propertyLines >= INVENTORY_FIND_MAX_PROPERTIES then return true end

        local typeName = get_prop_type_name(prop)
        local propName = get_prop_name(prop)
        if propName == "" then return false end

        local descriptor = propName .. " " .. declaringClass .. " " .. typeName
        if not contains_any(descriptor, INVENTORY_PLAYER_PROBE_KEYWORDS) then return false end

        local okValue, value = pcall(function() return root[propName] end)
        local valueText = okValue and describe_value(value) or "read-error"
        table.insert(ctx.propertyLines, inventory_line("PLAYER_PROP", label, propName, typeName, valueText, declaringClass))

        if okValue and is_valid_object(value) then
            add_inventory_probe_target(ctx, label .. "." .. propName, value)
        end
        return false
    end)
end

local function player_inventory_probe()
    write_inventory_lines({
        inventory_line("STATUS", "BUSY", "player inventory probe"),
    })

    local ctx = {
        lines = {
            inventory_line("STATUS", "OK", "player inventory probe"),
        },
        targets = {},
        targetSeen = {},
        propertyLines = {},
        functionCount = 0,
    }

    local roots = { "PC", "PlayerState", "Pawn" }
    for _, rootKind in ipairs(roots) do
        local root = get_inventory_root_object(rootKind)
        if is_valid_object(root) then
            add_inventory_probe_line(ctx, "PLAYER_ROOT", rootKind, safe_class_full_name(root), safe_full_name(root))
            add_inventory_probe_target(ctx, "PlayerRoot." .. rootKind, root)
            probe_direct_player_fields(ctx, "PlayerRoot." .. rootKind, root)
            probe_player_root_properties(ctx, "PlayerRoot." .. rootKind, root)
        else
            add_inventory_probe_line(ctx, "PLAYER_ROOT", rootKind, "missing", "")
        end
    end

    for _, target in ipairs(ctx.targets) do
        probe_target_functions(ctx, target.Label, target.Object)
    end

    for _, line in ipairs(ctx.propertyLines) do
        if #ctx.lines < INVENTORY_MAX_RESULTS then table.insert(ctx.lines, line) end
    end

    table.insert(ctx.lines, inventory_line("SUMMARY", "player-targets=" .. tostring(#ctx.targets), "functions=" .. tostring(ctx.functionCount), "properties=" .. tostring(#ctx.propertyLines)))

    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] Player inventory probe complete: targets=%d functions=%d properties=%d\n", MOD_VERSION, #ctx.targets, ctx.functionCount, #ctx.propertyLines))
end

local function add_player_detail_target(targets, label, obj)
    if is_valid_object(obj) then
        table.insert(targets, { Label = label, Object = obj })
    end
end

local function get_player_detail_targets()
    local targets = {}
    local ps = get_inventory_root_object("PlayerState")
    if is_valid_object(ps) then
        add_player_detail_target(targets, "PlayerState", ps)
        add_player_detail_target(targets, "PlayerState.InventoryComponent", safe_get(ps, "InventoryComponent"))
        add_player_detail_target(targets, "PlayerState.DataModuleComponent", safe_get(ps, "DataModuleComponent"))
    end
    return targets
end

local function collect_target_property_details(ctx, label, obj)
    local count = 0

    for_each_property(obj, function(prop, declaringClass)
        if count >= INVENTORY_DETAILS_MAX_PROPERTIES then return true end
        if #ctx.lines >= INVENTORY_MAX_RESULTS then return true end

        local typeName = get_prop_type_name(prop)
        local propName = get_prop_name(prop)
        if propName == "" then return false end

        count = count + 1
        add_inventory_probe_line(ctx, "DETAIL_PROP", label, propName, typeName, "value-not-read", declaringClass)
        return false
    end)

    add_inventory_probe_line(ctx, "DETAIL_PROP_SUMMARY", label, "count=" .. tostring(count))
end

local function collect_target_function_details(ctx, label, obj)
    local count = 0

    for_each_function(obj, function(fn, declaringClass)
        if count >= INVENTORY_DETAILS_MAX_FUNCTIONS then return true end
        if #ctx.lines >= INVENTORY_MAX_RESULTS then return true end

        local functionName = get_uobject_name(fn)
        local fullName = safe_full_name(fn)
        local descriptor = functionName .. " " .. fullName .. " " .. declaringClass
        if contains_any(descriptor, INVENTORY_FUNCTION_KEYWORDS) then
            count = count + 1
            add_inventory_probe_line(ctx, "DETAIL_FUNC", label, functionName, function_flags_text(fn), declaringClass, fullName)
        end
        return false
    end)

    add_inventory_probe_line(ctx, "DETAIL_FUNC_SUMMARY", label, "count=" .. tostring(count))
end

local function player_inventory_details()
    write_inventory_lines({
        inventory_line("STATUS", "BUSY", "player inventory details"),
    })

    local ctx = {
        lines = {
            inventory_line("STATUS", "OK", "player inventory details"),
        },
    }

    local targets = get_player_detail_targets()
    for _, target in ipairs(targets) do
        add_inventory_probe_line(ctx, "DETAIL_TARGET", target.Label, safe_class_full_name(target.Object), safe_full_name(target.Object))
        collect_target_property_details(ctx, target.Label, target.Object)
        collect_target_function_details(ctx, target.Label, target.Object)
    end

    table.insert(ctx.lines, inventory_line("SUMMARY", "detail-targets=" .. tostring(#targets)))
    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] Player inventory details complete: targets=%d\n", MOD_VERSION, #targets))
end

local function player_modules_probe()
    local ctx = {
        lines = {
            inventory_line("STATUS", "BUSY", "player modules probe"),
        },
    }
    write_inventory_lines(ctx.lines)

    local ps = get_inventory_root_object("PlayerState")
    if not is_valid_object(ps) then
        add_inventory_probe_line_and_flush(ctx, "STATUS", "FAILED", "player state missing")
        return
    end
    add_inventory_probe_line_and_flush(ctx, "MODULE_ROOT", "PlayerState", safe_class_full_name(ps), safe_full_name(ps))

    local dmc = safe_get(ps, "DataModuleComponent")
    if not is_valid_object(dmc) then
        add_inventory_probe_line_and_flush(ctx, "STATUS", "FAILED", "DataModuleComponent missing or invalid", type(dmc), tostring(dmc))
        return
    end
    add_inventory_probe_line_and_flush(ctx, "MODULE_ROOT", "PlayerState.DataModuleComponent", safe_class_full_name(dmc), safe_full_name(dmc))

    local okModules, modules = pcall(function() return dmc["m_DataModules"] end)
    if not okModules then
        add_inventory_probe_line_and_flush(ctx, "STATUS", "FAILED", "m_DataModules read failed", tostring(modules))
        return
    end

    local count = array_count(modules)
    if count == nil then
        add_inventory_probe_line_and_flush(ctx, "STATUS", "FAILED", "m_DataModules count unavailable", type(modules), tostring(modules))
        return
    end

    add_inventory_probe_line_and_flush(ctx, "MODULE_ARRAY", "PlayerState.DataModuleComponent.m_DataModules", "count=" .. tostring(count))

    local maxIndex = math.min(count - 1, INVENTORY_MODULES_MAX_ITEMS - 1)
    for i = 0, maxIndex do
        local okItem, item = pcall(function() return modules:Get(i) end)
        if okItem and is_valid_object(item) then
            add_inventory_probe_line_and_flush(ctx, "MODULE_ITEM", tostring(i), safe_class_full_name(item), safe_full_name(item))
        elseif okItem then
            add_inventory_probe_line_and_flush(ctx, "MODULE_ITEM", tostring(i), "invalid-or-nil", type(item), tostring(item))
        else
            add_inventory_probe_line_and_flush(ctx, "MODULE_ITEM", tostring(i), "read-failed", tostring(item))
        end
    end

    add_inventory_probe_line(ctx, "SUMMARY", "modules=" .. tostring(count), "listed=" .. tostring(math.max(0, maxIndex + 1)))
    add_inventory_probe_line(ctx, "STATUS", "OK", "player modules probe complete")
    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] Player modules probe complete: modules=%d listed=%d\n", MOD_VERSION, count, math.max(0, maxIndex + 1)))
end

local UFunctionCache = {}

local function find_ufunction(path)
    if UFunctionCache[path] ~= nil then return UFunctionCache[path] or nil end

    local candidates = {
        path,
        "Function " .. path,
    }

    for _, candidate in ipairs(candidates) do
        local ok, fn = pcall(function() return StaticFindObject(candidate) end)
        if ok and is_valid_object(fn) then
            UFunctionCache[path] = fn
            return fn
        end
    end

    UFunctionCache[path] = false
    return nil
end

local function call_ufunction_for_value(obj, path)
    if not is_valid_object(obj) then return nil, "invalid-object" end

    local fn = find_ufunction(path)
    if not is_valid_object(fn) then return nil, "function-not-found:" .. tostring(path) end

    local ok, value = pcall(function() return obj:CallFunction(fn) end)
    if ok and value ~= nil then return value, "CallFunction:" .. path end

    ok, value = pcall(function() return fn(obj) end)
    if ok and value ~= nil then return value, "function-object-call:" .. path end

    return nil, "call-returned-nil:" .. tostring(path)
end

local function native_item_class_candidates(code)
    code = trim(code)
    return {
        code,
        "Class " .. code,
        "/Script/G1R." .. code,
        "Class /Script/G1R." .. code,
        "/Script/Angelscript." .. code,
        "Class /Script/Angelscript." .. code,
    }
end

local function resolve_native_item_class(code)
    code = trim(code)
    if code == "" then return nil, "empty item code" end

    for _, candidate in ipairs(native_item_class_candidates(code)) do
        local ok, obj = pcall(function() return StaticFindObject(candidate) end)
        if ok and is_valid_object(obj) then
            return obj, "StaticFindObject:" .. candidate
        end
    end

    return nil, "native item class not found by short code"
end

local function native_qty(value)
    local qty = tonumber(value)
    if qty == nil then qty = 1 end
    if qty < 1 or qty ~= math.floor(qty) then
        return nil, "quantity must be a positive integer"
    end
    return qty, nil
end

local function try_get_inventory_from_character(character)
    if not is_valid_object(character) then return nil, "invalid-character" end

    local ok, inv = pcall(function() return character:GetInventory() end)
    if ok and is_valid_object(inv) then return inv, "character:GetInventory" end

    ok, inv = pcall(function() return character.GetInventory(character) end)
    if ok and is_valid_object(inv) then return inv, "character.GetInventory(character)" end

    local paths = {
        "/Script/G1R.GothicCharacter:GetInventory",
        "/Script/G1R.GothicCharacterState:GetInventory",
        "/Script/G1R.GothicCharacterBase:GetInventory",
        "/Script/Angelscript.PlayerCharacterBP_C:GetInventory",
    }
    for _, path in ipairs(paths) do
        local value, method = call_ufunction_for_value(character, path)
        if is_valid_object(value) then return value, method end
    end

    return nil, "get-inventory-failed"
end

local function class_function_path(obj, methodName)
    local className = safe_class_full_name(obj)
    local classPath = className:match("^Class%s+(.+)$") or className:match("^BlueprintGeneratedClass%s+(.+)$") or ""
    if classPath == "" then return "" end
    return classPath .. ":" .. tostring(methodName)
end

local function find_inventory_ufunction(inv, methodName)
    local path = class_function_path(inv, methodName)
    if path ~= "" then
        local fn = find_ufunction(path)
        if is_valid_object(fn) then return fn, path end
    end

    local ok, value = pcall(function() return inv[methodName] end)
    if ok and is_valid_object(value) then return value, "inv[" .. methodName .. "]" end

    return nil, "function-not-found:" .. tostring(methodName)
end

local function call_native_inventory_method(inv, methodName, itemClass, qty)
    if not is_valid_object(inv) then return false, "invalid inventory" end
    if not is_valid_object(itemClass) then return false, "invalid item class" end

    if methodName == "AddItemOfClass" then
        local ok = pcall(function() return inv:AddItemOfClass(itemClass, qty) end)
        if ok then return true, "colon:AddItemOfClass" end
    elseif methodName == "RemoveItemOfClass" then
        local ok = pcall(function() return inv:RemoveItemOfClass(itemClass, qty) end)
        if ok then return true, "colon:RemoveItemOfClass" end
    end

    local ok, result = pcall(function() return inv[methodName](inv, itemClass, qty) end)
    if ok then return true, "direct:" .. methodName end

    ok, result = pcall(function()
        local method = inv[methodName]
        return method(inv, itemClass, qty)
    end)
    if ok then return true, "indexed:" .. methodName end

    local fn, path = find_inventory_ufunction(inv, methodName)
    if not is_valid_object(fn) then return false, path end

    ok, result = pcall(function() return inv:CallFunction(fn, itemClass, qty) end)
    if ok then return true, "CallFunction:" .. tostring(path) end

    return false, "call-failed:" .. tostring(result)
end

local function get_ct_inventory()
    local character = get_inventory_root_object("Pawn")
    if not is_valid_object(character) then return nil, "player pawn missing" end
    return try_get_inventory_from_character(character)
end

local function looks_like_item_code(code)
    code = trim(code)
    if code == "" then return false end
    if ItemCatalog[string.lower(code)] ~= nil then return true end
    if code:match("^It[%w_]+$") then return true end
    if code:match("^[A-Z][%w]*_Armor[%w_]*$") then return true end
    return false
end

local function item_code_from_text(text)
    text = trim(text)
    if text == "" then return nil end

    local angelscriptCode = text:match("/Script/Angelscript%.([%w_]+)")
    if angelscriptCode and angelscriptCode ~= "" then return angelscriptCode end

    local worldCode = text:match("BP_([%w_]+)_World")
    if worldCode and worldCode ~= "" then return worldCode end

    local g1rCode = text:match("/Script/G1R%.([%w_]+)")
    if g1rCode and looks_like_item_code(g1rCode) then return g1rCode end

    local rawCode = text:match("^([%w_]+)$")
    if rawCode and looks_like_item_code(rawCode) then return rawCode end

    return nil
end

local function item_code_from_value(value)
    if value == nil then return nil end
    local vt = type(value)
    if vt == "string" or vt == "number" then
        return item_code_from_text(value)
    end

    if is_valid_object(value) then
        local code = item_code_from_text(safe_full_name(value))
        if code then return code end
        code = item_code_from_text(safe_class_full_name(value))
        if code then return code end
        local okName, name = pcall(function() return value:GetFName():ToString() end)
        if okName and name then
            code = item_code_from_text(name)
            if code then return code end
        end
    end

    local okText, text = pcall(function() return value:ToString() end)
    if okText and text then
        local code = item_code_from_text(text)
        if code then return code end
    end

    return item_code_from_text(tostring(value))
end

local function quantity_from_value(value)
    local qty = tonumber(value)
    if qty == nil then
        local okText, text = pcall(function() return value:ToString() end)
        if okText and text then qty = tonumber(text) end
    end
    if qty == nil then return nil end
    qty = math.floor(qty)
    if qty < 1 then return nil end
    return qty
end

local function inventory_array_get(value, index)
    local ok, item = pcall(function() return value:Get(index) end)
    if ok and item ~= nil then return item end

    ok, item = pcall(function() return value:GetRef(index) end)
    if ok and item ~= nil then return item end

    ok, item = pcall(function() return value:At(index) end)
    if ok and item ~= nil then return item end

    ok, item = pcall(function() return value[index] end)
    if ok and item ~= nil then return item end

    return nil
end

local function extract_inventory_entry(entry, source)
    local code = item_code_from_value(entry)
    local className = is_valid_object(entry) and safe_class_full_name(entry) or type(entry)

    if not code then
        for _, fieldName in ipairs(INVENTORY_ENTRY_CODE_FIELDS) do
            local value = safe_get(entry, fieldName)
            code = item_code_from_value(value)
            if code then
                if is_valid_object(value) then className = safe_class_full_name(value) end
                source = source .. "." .. fieldName
                break
            end
        end
    end

    if not code then return nil end

    local qty = nil
    for _, fieldName in ipairs(INVENTORY_ENTRY_QTY_FIELDS) do
        qty = quantity_from_value(safe_get(entry, fieldName))
        if qty then break end
    end
    if not qty then qty = 1 end

    return {
        Code = code,
        Qty = qty,
        ClassName = className,
        Source = source,
    }
end

local function add_inventory_list_source(sources, source, value)
    local count = array_count(value)
    if count == nil then return end
    table.insert(sources, {
        Source = source,
        Value = value,
        Count = count,
        Type = type(value),
    })
end

local function call_inventory_list_function(inv, functionName)
    local ok, value = pcall(function() return inv[functionName](inv) end)
    if ok and value ~= nil then return value end

    ok, value = pcall(function()
        local method = inv[functionName]
        return method(inv)
    end)
    if ok and value ~= nil then return value end

    return nil
end

local function collect_inventory_list_sources(inv, includeFunctions)
    local sources = {}
    if not is_valid_object(inv) then return sources end

    for _, fieldName in ipairs(INVENTORY_LIST_FIELD_NAMES) do
        local value = safe_get(inv, fieldName)
        add_inventory_list_source(sources, "field:" .. fieldName, value)
    end

    if includeFunctions then
        for _, functionName in ipairs(INVENTORY_LIST_FUNCTION_NAMES) do
            local value = call_inventory_list_function(inv, functionName)
            add_inventory_list_source(sources, "function:" .. functionName, value)
        end
    end

    return sources
end

local function add_inventory_entry(entriesByKey, entry)
    if not entry or not entry.Code then return 0 end
    local key = string.lower(entry.Code)
    local existing = entriesByKey[key]
    if existing then
        existing.Qty = existing.Qty + entry.Qty
        if not tostring(existing.Source):find(entry.Source, 1, true) then
            existing.Source = existing.Source .. "," .. entry.Source
        end
    else
        entriesByKey[key] = entry
    end
    return 1
end

local function enumerate_inventory_source(source, entriesByKey)
    local added = 0
    local count = math.min(tonumber(source.Count) or 0, INVENTORY_LIST_MAX_ITEMS)

    for i = 0, count - 1 do
        local raw = inventory_array_get(source.Value, i)
        local entry = extract_inventory_entry(raw, source.Source .. "[" .. tostring(i) .. "]")
        added = added + add_inventory_entry(entriesByKey, entry)
    end

    if added == 0 then
        for i = 1, count do
            local raw = inventory_array_get(source.Value, i)
            local entry = extract_inventory_entry(raw, source.Source .. "[" .. tostring(i) .. "]")
            added = added + add_inventory_entry(entriesByKey, entry)
        end
    end

    return added
end

local function inventory_list_probe()
    local ctx = {
        lines = {
            inventory_line("STATUS", "BUSY", "inventory list probe"),
        },
    }
    write_inventory_lines(ctx.lines)

    local inv, invMethod = get_ct_inventory()
    if not is_valid_object(inv) then
        add_inventory_probe_line(ctx, "STATUS", "FAILED", "inventory unavailable", tostring(invMethod))
        write_inventory_lines(ctx.lines)
        return
    end

    add_inventory_probe_line(ctx, "CT_INVENTORY", tostring(invMethod), safe_class_full_name(inv), safe_full_name(inv))
    local sources = collect_inventory_list_sources(inv, true)
    for _, source in ipairs(sources) do
        add_inventory_probe_line(ctx, "LIST_SOURCE", source.Source, "count=" .. tostring(source.Count), source.Type)
    end

    if #sources == 0 then
        add_inventory_probe_line(ctx, "STATUS", "FAILED", "no safe inventory list source found")
    else
        add_inventory_probe_line(ctx, "SUMMARY", "sources=" .. tostring(#sources))
        add_inventory_probe_line(ctx, "STATUS", "OK", "inventory list probe complete")
    end
    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] Inventory list probe complete: sources=%d\n", MOD_VERSION, #sources))
end

local function native_inventory_list()
    local lines = {
        inventory_line("STATUS", "BUSY", "native inventory list"),
    }
    write_inventory_list_lines(lines)

    local inv, invMethod = get_ct_inventory()
    if not is_valid_object(inv) then
        table.insert(lines, inventory_line("STATUS", "FAILED", "inventory unavailable", tostring(invMethod)))
        write_inventory_list_lines(lines)
        write_inventory_lines(lines)
        return
    end

    table.insert(lines, inventory_line("CT_INVENTORY", tostring(invMethod), safe_class_full_name(inv), safe_full_name(inv)))

    local sources = collect_inventory_list_sources(inv, true)
    if #sources == 0 then
        table.insert(lines, inventory_line("STATUS", "FAILED", "no safe inventory list source found"))
        write_inventory_list_lines(lines)
        write_inventory_lines(lines)
        return
    end

    local entriesByKey = {}
    local chosenSources = 0
    local rawAdded = 0
    for _, source in ipairs(sources) do
        table.insert(lines, inventory_line("LIST_SOURCE", source.Source, "count=" .. tostring(source.Count), source.Type))
        local added = enumerate_inventory_source(source, entriesByKey)
        if added > 0 then
            chosenSources = chosenSources + 1
            rawAdded = rawAdded + added
        end
    end

    local keys = {}
    for key, _ in pairs(entriesByKey) do table.insert(keys, key) end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local entry = entriesByKey[key]
        table.insert(lines, inventory_line("ITEM", entry.Code, tostring(entry.Qty), entry.ClassName, entry.Source))
    end

    if #keys == 0 then
        table.insert(lines, inventory_line("SUMMARY", "sources=" .. tostring(#sources), "recognized=0"))
        table.insert(lines, inventory_line("STATUS", "FAILED", "no recognizable inventory entries"))
    else
        table.insert(lines, inventory_line("SUMMARY", "sources=" .. tostring(chosenSources), "items=" .. tostring(#keys), "raw=" .. tostring(rawAdded)))
        table.insert(lines, inventory_line("STATUS", "OK", "native inventory list complete"))
    end

    write_inventory_list_lines(lines)
    write_inventory_lines(lines)
    print(string.format("[ItemMod v%s] Native inventory list complete: items=%d sources=%d\n", MOD_VERSION, #keys, chosenSources))
end

local function ct_inventory_probe()
    local ctx = {
        lines = {
            inventory_line("STATUS", "BUSY", "ct get inventory probe"),
        },
    }
    write_inventory_lines(ctx.lines)

    local character = get_inventory_root_object("Pawn")
    if not is_valid_object(character) then
        add_inventory_probe_line_and_flush(ctx, "STATUS", "FAILED", "player pawn missing")
        return
    end
    add_inventory_probe_line_and_flush(ctx, "CT_CHARACTER", safe_class_full_name(character), safe_full_name(character))

    local inv, method = try_get_inventory_from_character(character)
    if not is_valid_object(inv) then
        add_inventory_probe_line_and_flush(ctx, "STATUS", "FAILED", "GetInventory failed", tostring(method))
        return
    end

    add_inventory_probe_line_and_flush(ctx, "CT_INVENTORY", tostring(method), safe_class_full_name(inv), safe_full_name(inv))
    probe_target_direct_methods(ctx, "CT.Inventory", inv)
    probe_target_functions(ctx, "CT.Inventory", inv)

    add_inventory_probe_line(ctx, "SUMMARY", "ct-inventory-probe")
    add_inventory_probe_line(ctx, "STATUS", "OK", "ct get inventory probe complete")
    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] CT inventory probe complete\n", MOD_VERSION))
end

local function native_probe_item(code)
    local ctx = {
        lines = {
            inventory_line("STATUS", "BUSY", "native item class probe"),
        },
    }
    write_inventory_lines(ctx.lines)

    code = trim(code)
    local itemClass, method = resolve_native_item_class(code)
    if not is_valid_object(itemClass) then
        add_inventory_probe_line(ctx, "ITEM_CLASS", code, "FAILED", tostring(method))
        add_inventory_probe_line(ctx, "STATUS", "FAILED", "native item class probe failed")
        write_inventory_lines(ctx.lines)
        return
    end

    add_inventory_probe_line(ctx, "ITEM_CLASS", code, safe_class_full_name(itemClass), safe_full_name(itemClass), tostring(method))
    add_inventory_probe_line(ctx, "STATUS", "OK", "native item class probe complete")
    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] Native item class probe complete: %s\n", MOD_VERSION, code))
end

local function native_inventory_change(kind, methodName, code, qtyText)
    local ctx = {
        lines = {
            inventory_line("STATUS", "BUSY", "native inventory " .. string.lower(kind)),
        },
    }
    write_inventory_lines(ctx.lines)

    code = trim(code)
    if code == "" then
        add_inventory_probe_line(ctx, "NATIVE_RESULT", kind, code, "0", "FAILED", "empty item code")
        add_inventory_probe_line(ctx, "STATUS", "FAILED", "empty item code")
        write_inventory_lines(ctx.lines)
        return
    end

    local qty, qtyErr = native_qty(qtyText)
    if not qty then
        add_inventory_probe_line(ctx, "NATIVE_RESULT", kind, code, tostring(qtyText), "FAILED", tostring(qtyErr))
        add_inventory_probe_line(ctx, "STATUS", "FAILED", tostring(qtyErr))
        write_inventory_lines(ctx.lines)
        return
    end

    local inv, invMethod = get_ct_inventory()
    if not is_valid_object(inv) then
        add_inventory_probe_line(ctx, "NATIVE_RESULT", kind, code, tostring(qty), "FAILED", tostring(invMethod))
        add_inventory_probe_line(ctx, "STATUS", "FAILED", "inventory unavailable")
        write_inventory_lines(ctx.lines)
        return
    end
    add_inventory_probe_line(ctx, "CT_INVENTORY", tostring(invMethod), safe_class_full_name(inv), safe_full_name(inv))

    local itemClass, classMethod = resolve_native_item_class(code)
    if not is_valid_object(itemClass) then
        add_inventory_probe_line(ctx, "ITEM_CLASS", code, "FAILED", tostring(classMethod))
        add_inventory_probe_line(ctx, "NATIVE_RESULT", kind, code, tostring(qty), "FAILED", tostring(classMethod))
        add_inventory_probe_line(ctx, "STATUS", "FAILED", "item class unavailable")
        write_inventory_lines(ctx.lines)
        return
    end
    add_inventory_probe_line(ctx, "ITEM_CLASS", code, safe_class_full_name(itemClass), safe_full_name(itemClass), tostring(classMethod))

    local ok, method = call_native_inventory_method(inv, methodName, itemClass, qty)
    if not ok then
        add_inventory_probe_line(ctx, "NATIVE_RESULT", kind, code, tostring(qty), "FAILED", tostring(method))
        add_inventory_probe_line(ctx, "STATUS", "FAILED", "native inventory call failed")
        write_inventory_lines(ctx.lines)
        return
    end

    add_inventory_probe_line(ctx, "NATIVE_RESULT", kind, code, tostring(qty), "SENT", tostring(method))
    add_inventory_probe_line(ctx, "STATUS", "OK", "native inventory " .. string.lower(kind) .. " sent")
    write_inventory_lines(ctx.lines)
    print(string.format("[ItemMod v%s] Native inventory %s sent: %s x%d via %s\n", MOD_VERSION, kind, code, qty, tostring(method)))
end

local function process_action_line(line)
    local parts = {}
    for part in (line .. "|"):gmatch("(.-)|") do
        table.insert(parts, part)
    end

    local cmd = string.upper(trim(parts[1]))
    if cmd == "SPAWN" then
        spawn_item(parts[2], parts[3])
    elseif cmd == "INV_SCAN" then
        scan_inventory()
    elseif cmd == "INV_FIND_FUNCS" then
        find_inventory_functions()
    elseif cmd == "INV_PLAYER_PROBE" then
        player_inventory_probe()
    elseif cmd == "INV_PLAYER_DETAILS" then
        player_inventory_details()
    elseif cmd == "INV_PLAYER_MODULES" then
        player_modules_probe()
    elseif cmd == "INV_CT_PROBE" then
        ct_inventory_probe()
    elseif cmd == "INV_LIST_PROBE" then
        inventory_list_probe()
    elseif cmd == "INV_NATIVE_LIST" then
        native_inventory_list()
    elseif cmd == "INV_NATIVE_PROBE_ITEM" then
        native_probe_item(parts[2])
    elseif cmd == "INV_NATIVE_ADD" then
        native_inventory_change("ADD", "AddItemOfClass", parts[2], parts[3])
    elseif cmd == "INV_NATIVE_REMOVE" then
        native_inventory_change("REMOVE", "RemoveItemOfClass", parts[2], parts[3])
    elseif cmd == "RELOAD" then
        load_catalog()
    elseif cmd ~= "" then
        write_state("FAILED", "unknown action: " .. cmd, "", 0, "")
    end
end

local function process_actions()
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
            write_state("FAILED", tostring(err), "", 0, "")
        end
    end
end

load_catalog()

if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(250, process_actions)
else
    write_state("FAILED", "LoopInGameThreadWithDelay unavailable", "", 0, "")
end

RegisterConsoleCommandHandler("itemspawn", function(params)
    local code, qty = trim(params or ""):match("^(%S+)%s*(%d*)$")
    if code then spawn_item(code, tonumber(qty) or 1) end
end)

print(string.format("[ItemMod v%s] loaded, catalog=%d\n", MOD_VERSION, LastCatalogCount))
