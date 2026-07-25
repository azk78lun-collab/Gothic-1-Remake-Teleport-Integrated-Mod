-- MoneyMod for Gothic 1 Remake v1.0
-- Recursive deep scan for currency and player numeric attributes.

local MOD_VERSION = "1.0"

local ActionsFile  = "TeleportMod_money_actions.txt"
local StateFile    = "TeleportMod_money_state.txt"
local StateTmpFile = "TeleportMod_money_state.txt.tmp"
local TargetFile   = "TeleportMod_money_target.ini"
local AttrActionsFile  = "TeleportMod_attr_actions.txt"
local AttrStateFile    = "TeleportMod_attr_state.txt"
local AttrStateTmpFile = "TeleportMod_attr_state.txt.tmp"
local AttrTargetFile   = "TeleportMod_attr_target.ini"
local OutputFile   = "MoneyMod_output.txt"

local MAX_DEPTH    = 5
local MAX_CANDIDATES = 50
local MAX_ATTR_CANDIDATES = 80
local POLL_DELAY_MS  = 250

local INTEGER_TYPES = {
    IntProperty = true, Int64Property = true, ByteProperty = true,
    UInt32Property = true, UInt64Property = true,
    Int8Property = true, Int16Property = true, UInt16Property = true,
}

local KEYWORDS = {
    "gold", "money", "coin", "coins", "ore", "nugget", "currency",
    "wealth", "treasure", "purse", "wallet", "inventory",
}

local ROOT_KINDS = { "PC", "PlayerState", "Pawn", "GameInstance", "GameMode", "GameState" }
local ATTR_ROOT_KINDS = { "PlayerState", "PC", "Pawn", "GameInstance", "GameMode", "GameState" }
local DEFAULT_MONEY_TARGET = {
    rootKind = "PC",
    path = "",
    type = "IntProperty",
}
local LastCandidates = {}
local LastAttrCandidates = {}

local ATTRIBUTE_DEFS = {
    Level = { "level", "lvl" },
    Experience = { "experience", "exp", "xp" },
    Health = { "health", "hp", "life", "hit" },
    MaxHealth = { "maxhealth", "max health", "maximum health", "health max" },
    Mana = { "mana", "mp", "magic" },
    MaxMana = { "maxmana", "max mana", "maximum mana", "mana max" },
    Strength = { "strength", "str" },
    Dexterity = { "dexterity", "dex", "agility" },
    SpeedModifier = { "speedmodifier", "speed modifier", "movement speed", "speed" },
    ResistanceFalling = { "resistance_falling", "falling", "fall", "fall damage" },
    SkillPoints = { "skillpoints", "skill points", "learning points", "lp" },
    OneHanded = { "one handed", "onehanded", "1h" },
    TwoHanded = { "two handed", "twohanded", "2h" },
    Bow = { "bow", "ranged", "archery" },
    Crossbow = { "crossbow" },
    Lockpicking = { "lockpicking", "lockpick", "lock" },
    LockpickDurability = { "lockpickdurability", "lockpick durability", "durability" },
    LockpickPrecision = { "lockpickprecision", "lockpick precision", "precision" },
    Pickpocket = { "pickpocket", "steal", "thievery" },
    Smithing = { "smithing", "smith", "forge" },
    Alchemy = { "alchemy", "potion", "brew" },
    Acrobatics = { "acrobatics", "acrobat", "jump" },
    Sneak = { "sneak", "sneaking", "stealth" },
    Armor = { "armor", "armour", "protection", "defense" },
    MagicCircle = { "magic circle", "magic", "circle" },
}

-- ============================================================
-- Output
-- ============================================================

local OutputLines = {}

local function Out(fmt, ...)
    local msg = string.format(fmt, ...)
    print(msg)
    table.insert(OutputLines, msg)
end

local function FlushOutput()
    pcall(function()
        local f = io.open(OutputFile, "w")
        if not f then return end
        for _, line in ipairs(OutputLines) do
            f:write(line)
            if not line:find("\n", 1, true) then f:write("\n") end
        end
        f:close()
    end)
end

-- ============================================================
-- Helpers
-- ============================================================

local function Trim(v)
    v = v or ""
    return v:match("^%s*(.-)%s*$")
end

local function SafeLower(v)
    if not v then return "" end
    return string.lower(tostring(v))
end

local function ContainsKeyword(v)
    local s = SafeLower(v)
    if s == "" then return false end
    for _, kw in ipairs(KEYWORDS) do
        if s:find(kw, 1, true) then return true end
    end
    return false
end

local function ContainsAny(v, terms)
    local s = SafeLower(v)
    if s == "" or not terms then return false end
    for _, term in ipairs(terms) do
        if s:find(term, 1, true) then return true end
    end
    return false
end

local function PathLooksDisplayOnly(v)
    return ContainsAny(v, {
        "hud ref", "wb_", "widget", "bar.", "progressbar", "render", "opacity",
        "material", "text", "font", "cursor", "viewport", "trail", "camera",
        "als.", "animation", "anim", "customdepth", "stencil", "sound",
        "uimanager", "uicomponent", "hudcomponent", "screen",
    })
end

local function PathLooksSourceData(v)
    return ContainsAny(v, {
        "playerstate", "saveload", "save", "attribute", "attributes", "stat",
        "stats", "skill", "skills", "leveling", "progression", "playerxp",
        "expup", "inventory", "playerdata", "characterdata", "gamesave",
        "quest", "ability", "talent", "perk",
    })
end

local function IsValidObj(o)
    if o == nil then return false end
    if type(o) ~= "userdata" and type(o) ~= "table" then return false end
    local ok, valid = pcall(function() return o:IsValid() end)
    return ok and valid == true
end

local function PCallGet(obj, field)
    local ok, v = pcall(function() return obj[field] end)
    if not ok then return nil end
    return v
end

local function GetPropTypeName(prop)
    local ok1, cls = pcall(function() return prop:GetClass() end)
    if not ok1 or not cls then return "" end
    local ok2, fn = pcall(function() return cls:GetFName() end)
    if not ok2 or not fn then return "" end
    local ok3, s = pcall(function() return fn:ToString() end)
    if not ok3 or not s then return "" end
    return tostring(s)
end

local function GetPropName(prop)
    local ok, fn = pcall(function() return prop:GetFName() end)
    if not ok or not fn then return "" end
    local ok2, s = pcall(function() return fn:ToString() end)
    if not ok2 or not s then return "" end
    return tostring(s)
end

local function GetClassFullName(st)
    local ok, s = pcall(function() return st:GetFullName() end)
    if ok and s then return tostring(s) end
    return ""
end

local function ReadIntProp(obj, name)
    if not IsValidObj(obj) or not name or name == "" then return nil end
    local ok, v = pcall(function() return obj[name] end)
    if not ok or v == nil then return nil end
    if type(v) == "number" then return v end
    return tonumber(v)
end

local function ExtractNum(params)
    local s = tostring(params or "")
    local n = s:match("([%-%d%.]+)%s*$")
    if n then local v = tonumber(n); if v then return v end end
    n = s:match("%s+([%-%d%.]+)")
    if n then return tonumber(n) end
    return tonumber(s)
end

local function ForEachProperty(obj, cb)
    if not IsValidObj(obj) then return end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not IsValidObj(cls) then return end
    local cur = cls
    local guard = 0
    while IsValidObj(cur) and guard < 64 do
        guard = guard + 1
        pcall(function()
            cur:ForEachProperty(function(p)
                if p and IsValidObj(p) then cb(p, GetClassFullName(cur)) end
            end)
        end)
        local ok2, sup = pcall(function() return cur:GetSuperStruct() end)
        if not ok2 then break end
        cur = sup
        if not IsValidObj(cur) then break end
    end
end

local function SafeFindFirstOf(className)
    local ok, obj = pcall(function() return FindFirstOf(className) end)
    if ok and IsValidObj(obj) then return obj end
    return nil
end

local function GetPlayerController()
    return SafeFindFirstOf("PlayerController")
end

local function GetPlayerPawn()
    local pc = GetPlayerController()
    if IsValidObj(pc) then
        local ps = PCallGet(pc, "PlayerState")
        if IsValidObj(ps) then
            local pp = PCallGet(ps, "PawnPrivate")
            if IsValidObj(pp) then return pp end
        end

        local ap = PCallGet(pc, "AcknowledgedPawn")
        if IsValidObj(ap) then return ap end
    end

    local pawn = SafeFindFirstOf("Pawn")
    if IsValidObj(pawn) then return pawn end
    return SafeFindFirstOf("Character")
end

local function GetRootObject(kind)
    if kind == "PC" then
        return GetPlayerController()
    elseif kind == "PlayerState" then
        local pc = GetPlayerController()
        if IsValidObj(pc) then return PCallGet(pc, "PlayerState") end
    elseif kind == "Pawn" then
        return GetPlayerPawn()
    elseif kind == "GameInstance" then
        return SafeFindFirstOf("GameInstance")
    elseif kind == "GameMode" then
        return SafeFindFirstOf("GameModeBase") or SafeFindFirstOf("GameMode")
    elseif kind == "GameState" then
        return SafeFindFirstOf("GameStateBase") or SafeFindFirstOf("GameState")
    end
    return nil
end

local function ResolveTarget(rootKind, path)
    local root = GetRootObject(rootKind)
    if not IsValidObj(root) or not path or path == "" then return nil, nil end
    local segs = {}
    for seg in (path .. "."):gmatch("(.-)%.") do
        if seg ~= "" then table.insert(segs, seg) end
    end
    if #segs == 0 then return nil, nil end
    local host = root
    for i = 1, #segs - 1 do
        if not IsValidObj(host) then return nil, nil end
        local child = PCallGet(host, segs[i])
        if not IsValidObj(child) then return nil, nil end
        host = child
    end
    return host, segs[#segs]
end

local function ReadTargetValue(rootKind, path)
    local h, p = ResolveTarget(rootKind, path)
    if not h or not p then return nil end
    return ReadIntProp(h, p)
end

local function ValuesClose(a, b)
    if a == nil or b == nil then return false end
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= 0.01
end

local function PrepareWriteValue(host, prop, ptype, nv)
    if ptype ~= "FloatProperty" and INTEGER_TYPES[ptype] then
        return math.floor(nv + 0.5)
    end
    if ptype == "FloatProperty" then
        local okR, curVal = pcall(function() return host[prop] end)
        if okR and curVal ~= nil and type(curVal) == "number" then
            local frac = curVal - math.floor(curVal)
            if frac < 0 then frac = 0 end
            return math.floor(nv) + frac
        end
    end
    return nv
end

local function WriteTargetValueVerified(rootKind, path, ptype, nv)
    local host, prop = ResolveTarget(rootKind, path)
    if not host or not prop then
        return false, "cannot resolve", nil, nil
    end
    local writeVal = PrepareWriteValue(host, prop, ptype, nv)
    local okW, errW = pcall(function() host[prop] = writeVal end)
    if not okW then
        return false, "write error: " .. tostring(errW), writeVal, nil
    end
    local readback = ReadTargetValue(rootKind, path)
    if readback == nil then
        return false, "write unreadable after set", writeVal, nil
    end
    if not ValuesClose(readback, writeVal) then
        return false, string.format("readback-not-changed: wrote %s read %s", tostring(writeVal), tostring(readback)), writeVal, readback
    end
    return true, "ok", writeVal, readback
end

local function IsNumericType(pt)
    return INTEGER_TYPES[pt] == true or pt == "FloatProperty"
end

local function NumericValueMatches(expected, value, ptype)
    if expected == nil or value == nil then return false end
    if ptype == "FloatProperty" then
        return math.abs(value - expected) <= 0.01 or math.floor(value + 0.5) == expected
    end
    return value == expected
end

local function AttributeValueMatches(expected, value, ptype)
    if expected == nil or value == nil then return false end
    if NumericValueMatches(expected, value, ptype) then return true end
    if ptype == "FloatProperty" then
        if expected > 1 and value >= 0 and value <= 1 then
            return math.abs((value * 100.0) - expected) <= 0.05
        end
        if value > 1 and expected >= 0 and expected <= 1 then
            return math.abs(value - (expected * 100.0)) <= 0.05
        end
    end
    return false
end

-- ============================================================
-- Recursive deep scanner
-- ============================================================

local Visited = {}

local function ScanRecursive(obj, path, depth, expected, results)
    if not IsValidObj(obj) then return end
    if depth > MAX_DEPTH then return end

    -- Cycle detection by object pointer
    local ok, ptr = pcall(function() return obj:GetAddress() end)
    if ok and ptr and ptr ~= 0 then
        if Visited[ptr] then return end
        Visited[ptr] = true
    end

    ForEachProperty(obj, function(prop, cname)
        local pt = GetPropTypeName(prop)
        local pn = GetPropName(prop)
        if pn == "" then return end

        if INTEGER_TYPES[pt] then
            local val = ReadIntProp(obj, pn)
            if val ~= nil and (expected == nil or val == expected) then
                local sc = 0
                if expected ~= nil and val == expected then sc = sc + 10 end
                if ContainsKeyword(pn) then sc = sc + 5 end
                if ContainsKeyword(cname) then sc = sc + 2 end
                table.insert(results, { path=path.."."..pn, type=pt, value=val, score=sc, class=cname })
            end
        elseif pt == "FloatProperty" then
            local okF, fv = pcall(function() return obj[pn] end)
            if okF and fv ~= nil and type(fv) == "number" then
                local rounded = math.floor(fv + 0.5)
                if expected ~= nil and (fv == expected or rounded == expected) then
                    local sc = 10
                    if ContainsKeyword(pn) then sc = sc + 5 end
                    if ContainsKeyword(cname) then sc = sc + 2 end
                    table.insert(results, { path=path.."."..pn, type=pt, value=fv, score=sc, class=cname })
                end
            end
        elseif pt == "ObjectProperty" then
            local child = PCallGet(obj, pn)
            if IsValidObj(child) then
                ScanRecursive(child, path.."."..pn, depth + 1, expected, results)
            end
        elseif pt == "StructProperty" then
            local child = PCallGet(obj, pn)
            if IsValidObj(child) then
                ScanRecursive(child, path.."."..pn, depth + 1, expected, results)
            end
        end
    end)
end

-- Also dump ALL non-zero/keyword props recursively (for moneyall)
local function DumpRecursive(obj, path, depth, results)
    if not IsValidObj(obj) then return end
    if depth > MAX_DEPTH then return end

    local ok, ptr = pcall(function() return obj:GetAddress() end)
    if ok and ptr and ptr ~= 0 then
        if Visited[ptr] then return end
        Visited[ptr] = true
    end

    ForEachProperty(obj, function(prop, cname)
        local pt = GetPropTypeName(prop)
        local pn = GetPropName(prop)
        if pn == "" then return end

        local okV, val = pcall(function() return obj[pn] end)
        local valStr = "nil"
        if okV and val ~= nil then valStr = tostring(val) end
        local isMoney = ContainsKeyword(pn) or ContainsKeyword(cname)
        local isInteresting = (valStr ~= "0" and valStr ~= "nil" and valStr ~= "false" and valStr ~= "")

        if isMoney then
            table.insert(results, { path=path.."."..pn, type=pt, value=valStr, class=cname, tag="<<<MONEY" })
        elseif pt == "ObjectProperty" then
            if IsValidObj(val) then DumpRecursive(val, path.."."..pn, depth + 1, results) end
        elseif pt == "StructProperty" then
            if IsValidObj(val) then DumpRecursive(val, path.."."..pn, depth + 1, results) end
        elseif isInteresting then
            table.insert(results, { path=path.."."..pn, type=pt, value=valStr, class=cname, tag="" })
        end
    end)
end

-- ============================================================
-- Scoring + candidate collection (keyword-filtered)
-- ============================================================

local function CollectCandidates(expectedValue)
    local results = {}
    local seen = {}
    local function tryAdd(rk, path, ptype, val, pname, cname)
        local key = rk .. "\0" .. path
        if seen[key] then return end
        if expectedValue ~= nil and not NumericValueMatches(expectedValue, val, ptype) then
            return
        end
        local sc = 0
        if NumericValueMatches(expectedValue, val, ptype) then sc = sc + 10 end
        if ContainsKeyword(pname) then sc = sc + 5 end
        if ContainsKeyword(cname) then sc = sc + 2 end
        if (expectedValue ~= nil) or sc >= 5 then
            seen[key] = true
            table.insert(results, { rootKind=rk, path=path, type=ptype, value=val, score=sc })
        end
    end

    local function walk(rk, obj, path, depth)
        if not IsValidObj(obj) then return end
        if depth > MAX_DEPTH then return end

        local ok, ptr = pcall(function() return obj:GetAddress() end)
        if ok and ptr and ptr ~= 0 then
            local vk = rk .. "\0" .. tostring(ptr)
            if Visited[vk] then return end
            Visited[vk] = true
        end

        ForEachProperty(obj, function(prop, cname)
            local pt = GetPropTypeName(prop)
            local pn = GetPropName(prop)
            if pn == "" then return end
            local nextPath = (path == "" and pn) or (path .. "." .. pn)

            if INTEGER_TYPES[pt] then
                local val = ReadIntProp(obj, pn)
                if val ~= nil then tryAdd(rk, nextPath, pt, val, pn, cname) end
            elseif pt == "FloatProperty" then
                local okF, fv = pcall(function() return obj[pn] end)
                if okF and fv ~= nil and type(fv) == "number" then
                    tryAdd(rk, nextPath, pt, fv, pn, cname)
                end
            elseif pt == "ObjectProperty" or pt == "StructProperty" then
                local child = PCallGet(obj, pn)
                if IsValidObj(child) then
                    walk(rk, child, nextPath, depth + 1)
                end
            end
        end)
    end

    for _, rk in ipairs(ROOT_KINDS) do
        local root = GetRootObject(rk)
        if IsValidObj(root) then
            Visited = {}
            walk(rk, root, "", 0)
        end
    end
    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.path < b.path
    end)
    if #results > MAX_CANDIDATES then
        local t = {}; for i = 1, MAX_CANDIDATES do t[i] = results[i] end; results = t
    end
    return results
end

local function ScoreAttrCandidate(attrKey, expected, value, ptype, propName, className, path)
    local terms = ATTRIBUTE_DEFS[attrKey] or {}
    local score = 0
    if AttributeValueMatches(expected, value, ptype) then score = score + 10 end
    if ContainsAny(propName, terms) then score = score + 8 end
    if ContainsAny(path, terms) then score = score + 5 end
    if ContainsAny(className, terms) then score = score + 3 end
    if ContainsAny(propName, { "current", "value", "amount", "stat", "attribute", "vital" }) then score = score + 1 end
    if ContainsAny(path, { "playerstate" }) then score = score + 3 end
    if PathLooksSourceData(path) then score = score + 8 end
    if ContainsAny(propName, { "base", "current", "max", "level", "value" }) then score = score + 2 end
    if PathLooksDisplayOnly(path) then score = score - 12 end
    return score
end

local function CollectAttrCandidates(attrKey, expectedValue)
    local results = {}
    local seen = {}

    local function tryAdd(rk, path, ptype, val, pname, cname)
        if expectedValue ~= nil and not AttributeValueMatches(expectedValue, val, ptype) then
            return
        end
        local key = rk .. "\0" .. path
        if seen[key] then return end
        local sc = ScoreAttrCandidate(attrKey, expectedValue, val, ptype, pname, cname, path)
        if rk == "PlayerState" then sc = sc + 5 end
        if expectedValue ~= nil or sc >= 5 then
            seen[key] = true
            table.insert(results, { attrKey=attrKey, rootKind=rk, path=path, type=ptype, value=val, score=sc })
        end
    end

    local function walk(rk, obj, path, depth)
        if not IsValidObj(obj) then return end
        if depth > MAX_DEPTH then return end

        local ok, ptr = pcall(function() return obj:GetAddress() end)
        if ok and ptr and ptr ~= 0 then
            local vk = rk .. "\0" .. tostring(ptr)
            if Visited[vk] then return end
            Visited[vk] = true
        end

        ForEachProperty(obj, function(prop, cname)
            local pt = GetPropTypeName(prop)
            local pn = GetPropName(prop)
            if pn == "" then return end
            local nextPath = (path == "" and pn) or (path .. "." .. pn)

            if INTEGER_TYPES[pt] then
                local val = ReadIntProp(obj, pn)
                if val ~= nil then tryAdd(rk, nextPath, pt, val, pn, cname) end
            elseif pt == "FloatProperty" then
                local okF, fv = pcall(function() return obj[pn] end)
                if okF and fv ~= nil and type(fv) == "number" then
                    tryAdd(rk, nextPath, pt, fv, pn, cname)
                end
            elseif pt == "ObjectProperty" or pt == "StructProperty" then
                local child = PCallGet(obj, pn)
                if IsValidObj(child) then
                    walk(rk, child, nextPath, depth + 1)
                end
            end
        end)
    end

    for _, rk in ipairs(ATTR_ROOT_KINDS) do
        local root = GetRootObject(rk)
        if IsValidObj(root) then
            Visited = {}
            walk(rk, root, "", 0)
        end
    end

    local compHosts = { { "Pawn.Comp", GetRootObject("Pawn") }, { "PlayerState.Comp", GetRootObject("PlayerState") } }
    for _, ch in ipairs(compHosts) do
        local label, obj = ch[1], ch[2]
        if IsValidObj(obj) then
            local ok, comps = pcall(function() return obj:GetAllComponents() end)
            if ok and comps then
                for i = 0, comps:Num() - 1 do
                    local comp = comps:Get(i)
                    if IsValidObj(comp) then
                        Visited = {}
                        walk(label, comp, string.format("Comp[%d]", i), 0)
                    end
                end
            end
        end
    end

    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.rootKind ~= b.rootKind then
            if a.rootKind == "PlayerState" then return true end
            if b.rootKind == "PlayerState" then return false end
        end
        return a.path < b.path
    end)
    if #results > MAX_ATTR_CANDIDATES then
        local t = {}
        for i = 1, MAX_ATTR_CANDIDATES do t[i] = results[i] end
        results = t
    end
    return results
end

-- ============================================================
-- File IO
-- ============================================================

local function PinnedRead()
    local f = io.open(TargetFile, "r")
    if not f then return DEFAULT_MONEY_TARGET end
    local line = f:read("*l"); f:close()
    if not line then return DEFAULT_MONEY_TARGET end
    local rk, pt, tp = line:match("^([^|]+)|([^|]+)|([^|]+)$")
    if not rk then return DEFAULT_MONEY_TARGET end
    return { rootKind=Trim(rk), path=Trim(pt), type=Trim(tp) }
end

local function CandidateFromTarget(target, score)
    if not target then return nil end
    local value = ReadTargetValue(target.rootKind, target.path)
    if value == nil then return nil end
    return {
        rootKind = target.rootKind,
        path = target.path,
        type = target.type,
        value = value,
        score = score or 20,
    }
end

local function AddOrPromoteCandidate(list, candidate)
    if not candidate then return end
    for _, c in ipairs(list) do
        if c.rootKind == candidate.rootKind and c.path == candidate.path then
            c.value = candidate.value
            c.type = candidate.type
            c.score = math.max(tonumber(c.score or 0) or 0, tonumber(candidate.score or 0) or 0)
            return
        end
    end
    table.insert(list, 1, candidate)
end

local function PinnedWrite(rk, path, ptype)
    pcall(function()
        local f = io.open(TargetFile, "w")
        if f then f:write(string.format("%s|%s|%s\n", rk, path, ptype)); f:close() end
    end)
end

local function AttrPinnedRead(attrKey)
    local f = io.open(AttrTargetFile, "r")
    if not f then return nil end
    local found = nil
    for line in f:lines() do
        local ak, rk, pt, tp = line:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
        if ak and Trim(ak) == attrKey then
            found = { attrKey=Trim(ak), rootKind=Trim(rk), path=Trim(pt), type=Trim(tp) }
            break
        end
    end
    f:close()
    return found
end

local function AttrPinnedWrite(attrKey, rk, path, ptype)
    local lines = {}
    local replaced = false
    local f = io.open(AttrTargetFile, "r")
    if f then
        for line in f:lines() do
            local ak = line:match("^([^|]+)|")
            if ak and Trim(ak) == attrKey then
                table.insert(lines, string.format("%s|%s|%s|%s", attrKey, rk, path, ptype))
                replaced = true
            else
                table.insert(lines, line)
            end
        end
        f:close()
    end
    if not replaced then
        table.insert(lines, string.format("%s|%s|%s|%s", attrKey, rk, path, ptype))
    end
    pcall(function()
        local out = io.open(AttrTargetFile, "w")
        if not out then return end
        for _, line in ipairs(lines) do out:write(line .. "\n") end
        out:close()
    end)
end

local function WriteState(statusLine, candidates, pinned)
    local pk = nil
    if pinned and pinned.rootKind and pinned.path then pk = pinned.rootKind .. "\0" .. pinned.path end
    pcall(function()
        local f = io.open(StateTmpFile, "w")
        if not f then return end
        f:write(statusLine)
        if not statusLine:find("\n", 1, true) then f:write("\n") end
        if candidates then
            for _, c in ipairs(candidates) do
                local k = c.rootKind .. "\0" .. c.path
                local ip = (pk and k == pk) and 1 or 0
                f:write(string.format("CAND|%s|%s|%s|%s|%d|%d\n",
                    c.rootKind, c.path, c.type, tostring(c.value), c.score, ip))
            end
        end
        f:close(); os.remove(StateFile); os.rename(StateTmpFile, StateFile)
    end)
end

local function WriteAttrState(statusLine, attrKey, candidates, pinned)
    local pk = nil
    if pinned and pinned.rootKind and pinned.path then pk = pinned.rootKind .. "\0" .. pinned.path end
    pcall(function()
        local f = io.open(AttrStateTmpFile, "w")
        if not f then return end
        f:write(statusLine)
        if not statusLine:find("\n", 1, true) then f:write("\n") end
        if candidates then
            for _, c in ipairs(candidates) do
                local k = c.rootKind .. "\0" .. c.path
                local ip = (pk and k == pk) and 1 or 0
                f:write(string.format("ACAND|%s|%s|%s|%s|%s|%d|%d\n",
                    attrKey, c.rootKind, c.path, c.type, tostring(c.value), c.score, ip))
            end
        end
        f:close(); os.remove(AttrStateFile); os.rename(AttrStateTmpFile, AttrStateFile)
    end)
end

-- ============================================================
-- Action handlers (PS UI)
-- ============================================================

local function Clone(c)
    return { rootKind=c.rootKind, path=c.path, type=c.type, value=c.value, score=c.score }
end

local function CloneAttr(c)
    return { attrKey=c.attrKey, rootKind=c.rootKind, path=c.path, type=c.type, value=c.value, score=c.score }
end

local function HandleDetect(valStr)
    local exp = tonumber(valStr)
    if exp == nil then WriteState("STATUS|ERROR|invalid value", nil, nil); return end
    local cands = CollectCandidates(exp)
    local pinned = PinnedRead()
    AddOrPromoteCandidate(cands, CandidateFromTarget(pinned, 25))
    LastCandidates = {}; for _, c in ipairs(cands) do table.insert(LastCandidates, Clone(c)) end
    WriteState(string.format("STATUS|OK|detected %d for %s", #cands, tostring(exp)), cands, pinned)
end

local function HandleRefresh()
    local pinned = PinnedRead()
    local refreshed = {}
    local pinnedCandidate = CandidateFromTarget(pinned, 25)
    if pinnedCandidate then
        table.insert(refreshed, pinnedCandidate)
        LastCandidates = { Clone(pinnedCandidate) }
    elseif #LastCandidates > 0 then
        for _, c in ipairs(LastCandidates) do
            local e = Clone(c); local v = ReadTargetValue(e.rootKind, e.path)
            if v ~= nil then e.value = v end; table.insert(refreshed, e)
        end
    else
        refreshed = CollectCandidates(nil)
        for _, c in ipairs(refreshed) do table.insert(LastCandidates, Clone(c)) end
    end
    WriteState(string.format("STATUS|OK|refreshed %d", #refreshed), refreshed, pinned)
end

local function Upsert(rk, path, ptype, val, sc)
    for _, c in ipairs(LastCandidates) do
        if c.rootKind == rk and c.path == path then
            c.value = val; if sc and sc > (c.score or 0) then c.score = sc end; return
        end
    end
    table.insert(LastCandidates, 1, { rootKind=rk, path=path, type=ptype, value=val, score=sc or 10 })
end

local function HandleWrite(rk, path, ptype, nvStr)
    local nv = tonumber(nvStr)
    if nv == nil then WriteState("STATUS|ERROR|invalid write value", nil, nil); return end

    local okWrite, message, writeVal, readback = WriteTargetValueVerified(rk, path, ptype, nv)
    if not okWrite then
        WriteState("STATUS|ERROR|" .. message, nil, PinnedRead())
        return
    end

    Upsert(rk, path, ptype, readback, 10)
    local snap = {}
    for _, c in ipairs(LastCandidates) do
        local e = Clone(c)
        if e.rootKind == rk and e.path == path then e.value = readback
        else local v = ReadTargetValue(e.rootKind, e.path); if v ~= nil then e.value = v end end
        table.insert(snap, e)
    end
    WriteState(string.format("STATUS|OK|wrote %s readback %s to %s::%s", tostring(writeVal), tostring(readback), rk, path), snap, PinnedRead())
end

local function HandlePin(rk, path, ptype)
    if not rk or not path or not ptype or rk=="" or path=="" or ptype=="" then
        WriteState("STATUS|ERROR|invalid pin", nil, nil); return
    end
    PinnedWrite(rk, path, ptype)
    local v = ReadTargetValue(rk, path)
    Upsert(rk, path, ptype, v ~= nil and v or 0, 10)
    local snap = {}
    for _, c in ipairs(LastCandidates) do
        local e = Clone(c); local cv = ReadTargetValue(e.rootKind, e.path)
        if cv ~= nil then e.value = cv end; table.insert(snap, e)
    end
    WriteState(string.format("STATUS|OK|pinned %s::%s", rk, path), snap, { rootKind=rk, path=path, type=ptype })
end

local function AttrCandidateFromTarget(attrKey, target, score)
    if not target then return nil end
    local value = ReadTargetValue(target.rootKind, target.path)
    if value == nil then return nil end
    return {
        attrKey = attrKey,
        rootKind = target.rootKind,
        path = target.path,
        type = target.type,
        value = value,
        score = score or 25,
    }
end

local function AddOrPromoteAttrCandidate(list, candidate)
    if not candidate then return end
    for _, c in ipairs(list) do
        if c.rootKind == candidate.rootKind and c.path == candidate.path then
            c.value = candidate.value
            c.type = candidate.type
            c.score = math.max(tonumber(c.score or 0) or 0, tonumber(candidate.score or 0) or 0)
            return
        end
    end
    table.insert(list, 1, candidate)
end

local function HandleAttrDetect(attrKey, valStr)
    attrKey = Trim(attrKey or "")
    if ATTRIBUTE_DEFS[attrKey] == nil then WriteAttrState("ASTATUS|ERROR|unknown attribute", attrKey, nil, nil); return end
    local exp = tonumber(valStr)
    if exp == nil then WriteAttrState("ASTATUS|ERROR|invalid value", attrKey, nil, nil); return end
    local cands = CollectAttrCandidates(attrKey, exp)
    local pinned = AttrPinnedRead(attrKey)
    AddOrPromoteAttrCandidate(cands, AttrCandidateFromTarget(attrKey, pinned, 30))
    LastAttrCandidates[attrKey] = {}
    for _, c in ipairs(cands) do table.insert(LastAttrCandidates[attrKey], CloneAttr(c)) end
    WriteAttrState(string.format("ASTATUS|OK|%s detected %d for %s", attrKey, #cands, tostring(exp)), attrKey, cands, pinned)
end

local function HandleAttrRefresh(attrKey)
    attrKey = Trim(attrKey or "")
    if ATTRIBUTE_DEFS[attrKey] == nil then WriteAttrState("ASTATUS|ERROR|unknown attribute", attrKey, nil, nil); return end
    local pinned = AttrPinnedRead(attrKey)
    local refreshed = {}
    local pinnedCandidate = AttrCandidateFromTarget(attrKey, pinned, 30)
    if pinnedCandidate then
        table.insert(refreshed, pinnedCandidate)
        LastAttrCandidates[attrKey] = { CloneAttr(pinnedCandidate) }
    elseif LastAttrCandidates[attrKey] and #LastAttrCandidates[attrKey] > 0 then
        for _, c in ipairs(LastAttrCandidates[attrKey]) do
            local e = CloneAttr(c)
            local v = ReadTargetValue(e.rootKind, e.path)
            if v ~= nil then e.value = v end
            table.insert(refreshed, e)
        end
    else
        refreshed = CollectAttrCandidates(attrKey, nil)
        LastAttrCandidates[attrKey] = {}
        for _, c in ipairs(refreshed) do table.insert(LastAttrCandidates[attrKey], CloneAttr(c)) end
    end
    WriteAttrState(string.format("ASTATUS|OK|%s refreshed %d", attrKey, #refreshed), attrKey, refreshed, pinned)
end

local function AttrUpsert(attrKey, rk, path, ptype, val, sc)
    LastAttrCandidates[attrKey] = LastAttrCandidates[attrKey] or {}
    for _, c in ipairs(LastAttrCandidates[attrKey]) do
        if c.rootKind == rk and c.path == path then
            c.value = val
            if sc and sc > (c.score or 0) then c.score = sc end
            return
        end
    end
    table.insert(LastAttrCandidates[attrKey], 1, { attrKey=attrKey, rootKind=rk, path=path, type=ptype, value=val, score=sc or 10 })
end

local function HandleAttrWrite(attrKey, rk, path, ptype, nvStr)
    attrKey = Trim(attrKey or "")
    local nv = tonumber(nvStr)
    if ATTRIBUTE_DEFS[attrKey] == nil then WriteAttrState("ASTATUS|ERROR|unknown attribute", attrKey, nil, nil); return end
    if nv == nil then WriteAttrState("ASTATUS|ERROR|invalid write value", attrKey, nil, nil); return end

    local okWrite, message, writeVal, readback = WriteTargetValueVerified(rk, path, ptype, nv)
    if not okWrite then
        WriteAttrState("ASTATUS|ERROR|" .. message, attrKey, nil, AttrPinnedRead(attrKey))
        return
    end

    AttrUpsert(attrKey, rk, path, ptype, readback, 10)
    local snap = {}
    for _, c in ipairs(LastAttrCandidates[attrKey] or {}) do
        local e = CloneAttr(c)
        if e.rootKind == rk and e.path == path then
            e.value = readback
        else
            local v = ReadTargetValue(e.rootKind, e.path)
            if v ~= nil then e.value = v end
        end
        table.insert(snap, e)
    end
    WriteAttrState(string.format("ASTATUS|OK|%s wrote %s readback %s to %s::%s", attrKey, tostring(writeVal), tostring(readback), rk, path), attrKey, snap, AttrPinnedRead(attrKey))
end

local function HandleAttrPin(attrKey, rk, path, ptype)
    attrKey = Trim(attrKey or "")
    if ATTRIBUTE_DEFS[attrKey] == nil then WriteAttrState("ASTATUS|ERROR|unknown attribute", attrKey, nil, nil); return end
    if not rk or not path or not ptype or rk=="" or path=="" or ptype=="" then
        WriteAttrState("ASTATUS|ERROR|invalid pin", attrKey, nil, nil); return
    end
    AttrPinnedWrite(attrKey, rk, path, ptype)
    local v = ReadTargetValue(rk, path)
    AttrUpsert(attrKey, rk, path, ptype, v ~= nil and v or 0, 10)
    local snap = {}
    for _, c in ipairs(LastAttrCandidates[attrKey] or {}) do
        local e = CloneAttr(c)
        local cv = ReadTargetValue(e.rootKind, e.path)
        if cv ~= nil then e.value = cv end
        table.insert(snap, e)
    end
    WriteAttrState(string.format("ASTATUS|OK|%s pinned %s::%s", attrKey, rk, path), attrKey, snap, { attrKey=attrKey, rootKind=rk, path=path, type=ptype })
end

-- ============================================================
-- Action polling
-- ============================================================

local function ParseLine(line)
    local parts = {}
    for part in (line .. "|"):gmatch("(.-)|") do table.insert(parts, part) end
    return parts
end

local function ProcessAction(line)
    line = Trim(line or "")
    if line == "" then return end
    local p = ParseLine(line)
    local cmd = (p[1] or ""):upper()
    if cmd == "DETECT" then HandleDetect(p[2])
    elseif cmd == "WRITE" then HandleWrite(p[2], p[3], p[4], p[5])
    elseif cmd == "REFRESH" then HandleRefresh()
    elseif cmd == "PIN" then HandlePin(p[2], p[3], p[4])
    elseif cmd == "ATTR_DETECT" then HandleAttrDetect(p[2], p[3])
    elseif cmd == "ATTR_REFRESH" then HandleAttrRefresh(p[2])
    elseif cmd == "ATTR_WRITE" then HandleAttrWrite(p[2], p[3], p[4], p[5], p[6])
    elseif cmd == "ATTR_PIN" then HandleAttrPin(p[2], p[3], p[4], p[5])
    end
end

local function ProcessActionFile(fileName)
    local lines = {}
    local okR = pcall(function()
        local f = io.open(fileName, "r")
        if not f then return end
        for l in f:lines() do if l and l ~= "" then table.insert(lines, l) end end
        f:close()
    end)
    if not okR or #lines == 0 then return end
    -- Process actions first, then clear the file. This ensures actions are not
    -- lost if processing fails (the file is truncated only after all actions run).
    for _, l in ipairs(lines) do
        local ok, err = pcall(ProcessAction, l)
        if not ok then
            print(string.format("[MoneyMod] Action failed: %s | Error: %s\n", l, tostring(err)))
        end
    end
    pcall(function() local f = io.open(fileName, "w"); if f then f:close() end end)
end

local function ProcessActions()
    ProcessActionFile(ActionsFile)
    ProcessActionFile(AttrActionsFile)
end

-- ============================================================
-- Startup
-- ============================================================

local function LoadDefault()
    local t = PinnedRead()
    if not t then return end
    local candidate = CandidateFromTarget(t, 25)
    if not candidate then return end
    LastCandidates = { Clone(candidate) }
    WriteState("STATUS|OK|default loaded", { candidate }, t)
end

pcall(LoadDefault)

if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(POLL_DELAY_MS, ProcessActions)
else
    print("[MoneyMod] LoopInGameThreadWithDelay unavailable\n")
end

-- ============================================================
-- Console commands - output to MoneyMod_output.txt
-- All handlers return true (required by UE4SS)
-- ============================================================

-- moneyfind <value>: RECURSIVE deep scan (max 5 levels) for int+float props
RegisterConsoleCommandHandler("moneyfind", function(params)
    OutputLines = {}
    local expected = ExtractNum(params)
    Out("[MoneyMod] moneyfind v3: recursive deep scan, expected=%s", tostring(expected))
    Visited = {}
    local results = {}

    for _, rk in ipairs(ROOT_KINDS) do
        local root = GetRootObject(rk)
        if IsValidObj(root) then
            local before = #results
            ScanRecursive(root, rk, 0, expected, results)
            Out("  %s: %d matches (scanned %d new)", rk, #results - before, #results - before)
        end
    end

    -- Also scan components of Pawn and PlayerState
    local compHosts = { { "PC.Pawn", GetRootObject("Pawn") }, { "PC.PlayerState", GetRootObject("PlayerState") } }
    for _, ch in ipairs(compHosts) do
        local label, obj = ch[1], ch[2]
        if IsValidObj(obj) then
            local ok, comps = pcall(function() return obj:GetAllComponents() end)
            if ok and comps then
                for i = 0, comps:Num() - 1 do
                    local comp = comps:Get(i)
                    if IsValidObj(comp) then
                        local before = #results
                        ScanRecursive(comp, label..".Comp["..i.."]", 0, expected, results)
                        if #results > before then
                            Out("  %s.Comp[%d]: %d matches", label, i, #results - before)
                        end
                    end
                end
            end
        end
    end

    -- Sort by score descending
    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.path < b.path
    end)

    for _, r in ipairs(results) do
        Out("  %s (%s) = %s [score=%d]%s", r.path, r.type, tostring(r.value), r.score, r.class)
    end

    Out("[MoneyMod] moneyfind done: %d total matches for value %s", #results, tostring(expected))
    FlushOutput()
    return true
end)

-- moneyall: RECURSIVE dump of ALL non-zero/keyword props
RegisterConsoleCommandHandler("moneyall", function(params)
    OutputLines = {}
    Out("=== MoneyMod moneyall v3: recursive deep dump ===")
    Visited = {}
    local results = {}

    for _, rk in ipairs(ROOT_KINDS) do
        local root = GetRootObject(rk)
        if IsValidObj(root) then
            DumpRecursive(root, rk, 0, results)
        end
    end

    -- Also scan components
    local compHosts = { { "Pawn", GetRootObject("Pawn") }, { "PlayerState", GetRootObject("PlayerState") } }
    for _, ch in ipairs(compHosts) do
        local label, obj = ch[1], ch[2]
        if IsValidObj(obj) then
            local ok, comps = pcall(function() return obj:GetAllComponents() end)
            if ok and comps then
                for i = 0, comps:Num() - 1 do
                    local comp = comps:Get(i)
                    if IsValidObj(comp) then
                        DumpRecursive(comp, label..".Comp["..i.."]", 0, results)
                    end
                end
            end
        end
    end

    -- Print MONEY-tagged first, then others
    local moneyResults = {}
    local otherResults = {}
    for _, r in ipairs(results) do
        if r.tag == "<<<MONEY" then
            table.insert(moneyResults, r)
        else
            table.insert(otherResults, r)
        end
    end

    Out("\n--- <<<MONEY tagged (%d) ---", #moneyResults)
    for _, r in ipairs(moneyResults) do
        Out("  %s (%s) = %s [%s] <<<MONEY", r.path, r.type, r.value, r.class)
    end

    Out("\n--- Non-zero properties (%d) ---", #otherResults)
    for _, r in ipairs(otherResults) do
        Out("  %s (%s) = %s [%s]", r.path, r.type, r.value, r.class)
    end

    Out("\n=== moneyall done: %d money + %d other ===", #moneyResults, #otherResults)
    FlushOutput()
    return true
end)

-- moneydump <value>: keyword-filtered scan
RegisterConsoleCommandHandler("moneydump", function(params)
    OutputLines = {}
    local exp = ExtractNum(params)
    if exp == nil then
        Out("[MoneyMod] Usage: moneydump <value>")
        FlushOutput()
        return true
    end
    local cands = CollectCandidates(exp)
    LastCandidates = {}
    for _, c in ipairs(cands) do table.insert(LastCandidates, Clone(c)) end
    Out("[MoneyMod] %d keyword-scored candidate(s) for value %d:", #cands, exp)
    for _, c in ipairs(cands) do
        Out("  %s::%s (%s) = %s [score=%d]", c.rootKind, c.path, c.type, tostring(c.value), c.score)
    end
    WriteState(string.format("STATUS|OK|moneydump %d hits", #cands), cands, PinnedRead())
    FlushOutput()
    return true
end)

-- moneyscan: FindFirstOf search for currency-related classes
RegisterConsoleCommandHandler("moneyscan", function(params)
    OutputLines = {}
    Out("=== MoneyMod moneyscan: FindFirstOf search ===")

    local searchTerms = {
        "Inventory", "Wallet", "Money", "Currency", "Coin", "Gold",
        "Shop", "Trade", "Economy", "Resource", "Item", "Container",
        "Craft", "Loot", "Reward", "Bank", "Purse", "Stash",
        "Stats", "Attribute", "Progression", "PlayerData",
        "Save", "Persist", "GameState", "State",
    }

    local found = 0
    for _, term in ipairs(searchTerms) do
        local ok, obj = pcall(function() return FindFirstOf(term) end)
        if ok and IsValidObj(obj) then
            found = found + 1
            local name = ""
            pcall(function() name = obj:GetFullName() end)
            Out("  FindFirstOf('%s') -> %s", term, name)
        end
    end
    Out("\n=== moneyscan done: %d found ===", found)
    FlushOutput()
    return true
end)

-- moneyglobal: scan ALL objects in GUObjectArray for value
RegisterConsoleCommandHandler("moneyglobal", function(params)
    OutputLines = {}
    local targetVal = ExtractNum(params) or 2880
    Out("=== MoneyMod moneyglobal: scanning GUObjectArray for value %d ===", targetVal)

    local ok, GObj = pcall(function() return UObjectArray end)

    if not GObj then
        Out("ERROR: Cannot access UObjectArray, trying StaticObjects approach instead")

        -- Fallback: try common game-specific class names
        local gameClasses = {
            "/Game/Blueprints/BP_PlayerData",
            "/Game/Blueprints/BP_Inventory",
            "/Game/Systems/Inventory/InventoryComponent",
            "/Game/Systems/Economy/EconomyComponent",
            "/Game/Blueprints/Player/BP_PlayerController",
        }
        for _, path in ipairs(gameClasses) do
            local ok2, obj = pcall(function() return StaticObjects(path) end)
            if ok2 and IsValidObj(obj) then
                Out("  Found: %s", path)
                Visited = {}
                local results = {}
                ScanRecursive(obj, path, 0, targetVal, results)
                for _, r in ipairs(results) do
                    Out("  MATCH: %s (%s) = %s", r.path, r.type, tostring(r.value))
                end
            end
        end

        FlushOutput()
        return true
    end

    local count = 0
    local matches = {}

    pcall(function()
        local num = GObj:Num()
        Out("GUObjectArray has %d objects, scanning...", num)
        for i = 0, num - 1 do
            local obj = GObj:Get(i)
            if IsValidObj(obj) then
                count = count + 1
                ForEachProperty(obj, function(prop, cname)
                    local pt = GetPropTypeName(prop)
                    local pn = GetPropName(prop)
                    if pn == "" then return end
                    local okR, v = pcall(function() return obj[pn] end)
                    if okR and v ~= nil and type(v) == "number" and v == targetVal then
                        table.insert(matches, { idx=i, name=GetClassFullName(obj), prop=pn, type=pt, val=v })
                        if #matches >= 20 then return end
                    end
                end)
                if count >= 20000 then break end
                if #matches >= 20 then break end
            end
        end
    end)

    Out("Scanned %d objects, found %d matches for %d", count, #matches, targetVal)
    for _, m in ipairs(matches) do
        Out("  [%d] %s.%s (%s) = %s", m.idx, m.name, m.prop, m.type, m.val)
    end

    Out("\n=== moneyglobal done ===")
    FlushOutput()
    return true
end)

-- moneyset <value>: set gold directly (uses pinned target or runtime discovery)
RegisterConsoleCommandHandler("moneyset", function(params)
    OutputLines = {}
    local newVal = ExtractNum(params)
    if newVal == nil then
        Out("[MoneyMod] Usage: moneyset <integer_value>")
        Out("  Example: moneyset 99999")
        FlushOutput()
        return true
    end

    -- Use pinned target if available, otherwise report error
    local pinned = PinnedRead()
    if not pinned or pinned.path == "" then
        Out("[MoneyMod] ERROR: No money target pinned. Use moneyfind to discover and pin a target first.")
        FlushOutput()
        return true
    end

    local okWrite, message, writeVal, readback = WriteTargetValueVerified(pinned.rootKind, pinned.path, pinned.type, newVal)
    if not okWrite then
        Out("[MoneyMod] ERROR: %s for pinned target '%s::%s'", message, pinned.rootKind, pinned.path)
        FlushOutput()
        return true
    end

    Out("[MoneyMod] moneyset: wrote %s readback %s (input %s)", tostring(writeVal), tostring(readback), tostring(newVal))
    FlushOutput()
    return true
end)

RegisterConsoleCommandHandler("attrfind", function(params)
    OutputLines = {}
    local attrKey, val = tostring(params or ""):match("^(%S+)%s+([%-%d%.]+)")
    if not attrKey or not val then
        Out("[MoneyMod] Usage: attrfind <AttributeKey> <value>")
        Out("  Example: attrfind Strength 50")
        FlushOutput()
        return true
    end
    local expected = tonumber(val)
    local cands = CollectAttrCandidates(attrKey, expected)
    LastAttrCandidates[attrKey] = {}
    for _, c in ipairs(cands) do table.insert(LastAttrCandidates[attrKey], CloneAttr(c)) end
    Out("[MoneyMod] attrfind %s=%s -> %d candidate(s)", attrKey, tostring(expected), #cands)
    for _, c in ipairs(cands) do
        Out("  %s::%s (%s) = %s [score=%d]", c.rootKind, c.path, c.type, tostring(c.value), c.score)
    end
    WriteAttrState(string.format("ASTATUS|OK|%s attrfind %d hits", attrKey, #cands), attrKey, cands, AttrPinnedRead(attrKey))
    FlushOutput()
    return true
end)

print("[MoneyMod v1.0] ready | output -> MoneyMod_output.txt\n")

-- Diagnostic: test Pawn resolution at startup
pcall(function()
    local diagPawn = GetRootObject("Pawn")
    if IsValidObj(diagPawn) then
        local ok, name = pcall(function() return diagPawn:GetFullName() end)
        print("[MoneyMod-DIAG] Pawn resolved: " .. (ok and name or "getname-failed") .. "\n")
    else
        print("[MoneyMod-DIAG] Pawn NOT resolved at startup (may appear later in gameplay)\n")
    end
end)
