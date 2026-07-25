-- ----------------------------------------------------------------------------
-- FocusNearbyPickups - PING MODE v3 (On-Demand Highlight)
-- Press V to highlight nearby items/corpses/chests for 5 seconds.
-- Zero background load.
-- ----------------------------------------------------------------------------

local PING_DURATION_MS  = 5000   -- default 5s, configurable 1~30s from UI
local PING_RADIUS_UU    = 2500.0
local STENCIL_USAGE     = 4       -- the only verified non-white outline in this game build
local USE_THICK         = false   -- thick outline toggle
local USER_ALPHA        = 1.0     -- user-configurable brightness 0.0~1.0
local HIGHLIGHT_CORPSES = false   -- highlight dead bodies (ragdoll active)
local HIGHLIGHT_CHESTS  = false   -- highlight chests (InteractiveObjectActor with "chest" in name)
local CHEST_NAME_TERMS  = { "chest", "trunk", "barrel", "crate" }  -- lowercase match
local CHEST_NAME_EXCLUDE = { "bp_it" }  -- exclude item blueprints
local FNP_CONTROL_FILE  = "FocusNearbyPickups_control.txt"
local FNP_STATUS_FILE   = "FocusNearbyPickups_status.txt"

local highlightedComps = {}   -- array of component refs for cleanup
local pcCache = nil
local subsysCache = nil

print("[FNP-Ping3] Script loaded\n")

-- ---- Reflection helpers (copied verbatim from Plan B, proven stable) --------
local function rget(o, n)
    if o == nil then return nil end
    local ok, v = pcall(function()
        if type(o.IsValid) == "function" and not o:IsValid() then return nil end
        return o[n]
    end)
    if ok then return v end
end

local function safeObj(obj)
    if obj == nil then return false end
    local ok, addr = pcall(function()
        if not obj:IsValid() then return nil end
        return obj:GetAddress()
    end)
    return ok and addr ~= nil and addr ~= 0
end

-- ---- Position helpers (copied from Plan B, proven stable) -------------------
local function vec3(v)
    if v == nil then return nil end
    local okx, x = pcall(function() return v.X end)
    if okx and type(x) == "number" then
        local _, y = pcall(function() return v.Y end)
        local _, z = pcall(function() return v.Z end)
        return x, tonumber(y) or 0, tonumber(z) or 0
    end
end

local function rootLoc(a)
    if a == nil then return nil end
    return vec3(rget(rget(a, "RootComponent"), "RelativeLocation"))
end

-- ---- Player location (Plan B's playerLoc, proven to work) -------------------
local function playerLoc()
    if not (pcCache and pcCache:IsValid()) then pcCache = FindFirstOf("PlayerController") end
    if not (pcCache and pcCache:IsValid()) then return nil end
    local x, y, z = rootLoc(rget(pcCache, "Pawn"))
    if x then return x, y, z end
    return nil
end

-- ---- Item location (Plan B's itemLoc, proven to work) -----------------------
local function itemLoc(actor)
    local x, y, z = rootLoc(actor)
    if x then return x, y, z end
    local ok, il = pcall(function() return actor:K2_GetActorLocation() end)
    if ok then return vec3(il) end
end

-- ---- Subsystem (Plan B's subsys, proven to work) ----------------------------
local function subsys()
    if subsysCache and subsysCache:IsValid() then return subsysCache end
    local list = FindAllOf("OutlineSubsystem"); local s = nil
    if list then for _, x in pairs(list) do if x and x:IsValid() then s = x end end end
    subsysCache = s
    return s
end

-- ---- Ragdoll detection (is this character a corpse?) ------------------------
local function ragdollActive(actor)
    local rc = rget(actor, "m_RagdollComponent")
    if rc == nil then return false end
    local ok, valid = pcall(function() return rc:IsValid() end)
    if not (ok and valid) then return false end
    local v = rget(rc, "m_IsRagdollActive")
    if type(v) == "boolean" then return v end
    return false
end

-- ---- Chest name filter ------------------------------------------------------
local function isChestName(actor)
    local ok, fullName = pcall(function() return actor:GetFullName() end)
    if not ok or type(fullName) ~= "string" then return false end
    local low = fullName:lower()
    -- Exclude items that happen to subclass the same actor
    for _, ex in ipairs(CHEST_NAME_EXCLUDE) do
        if low:find(ex, 1, true) then return false end
    end
    -- Must contain at least one chest-related term
    for _, term in ipairs(CHEST_NAME_TERMS) do
        if low:find(term, 1, true) then return true end
    end
    return false
end

-- ---- Boost outline visibility (copied from Plan B) --------------------------
local OUTLINE_FAR_DISTANCE = 1.0e6   -- push distance-fade cap far out
local THICKNESS_MULTIPLIER = 2.0     -- slightly thicker lines
local cfgApplied = false
local origAlphaC, origAlphaF, origFarDist, origThickC, origThickF

local function applyConfig()
    if cfgApplied then return end
    local s = subsys(); if not s then return end
    local cfg = rget(s, "Config"); if not safeObj(cfg) then return end
    
    -- Save originals (only once)
    if origAlphaC == nil then
        origAlphaC = rget(cfg, "OutlineClosestAlpha")
        origAlphaF = rget(cfg, "OutlineFarthestAlpha")
        origFarDist = rget(cfg, "OutlineFarthestDistance")
        origThickC = rget(cfg, "OutlineClosestThickness")
        origThickF = rget(cfg, "OutlineFarthestThickness")
    end
    
    -- Apply boosted values
    local function rset(o, n, v)
        if o == nil then return end
        pcall(function()
            if type(o.IsValid) == "function" and not o:IsValid() then return end
            o[n] = v
        end)
    end
    rset(cfg, "OutlineClosestAlpha",  USER_ALPHA)
    rset(cfg, "OutlineFarthestAlpha", USER_ALPHA)
    if type(origFarDist) == "number" then rset(cfg, "OutlineFarthestDistance", OUTLINE_FAR_DISTANCE) end
    if type(origThickC) == "number" then rset(cfg, "OutlineClosestThickness",  origThickC * THICKNESS_MULTIPLIER) end
    if type(origThickF) == "number" then rset(cfg, "OutlineFarthestThickness", origThickF * THICKNESS_MULTIPLIER) end
    cfgApplied = true
    print("[FNP-Ping2] Outline config boosted (alpha=1.0, thick=2x)\n")
end

-- ---- Cleanup ----------------------------------------------------------------
local function doCleanup()
    local s = subsys()
    local cleaned = 0
    for _, comp in ipairs(highlightedComps) do
        if safeObj(comp) and s then
            pcall(function() s:QueueRemoveOutline(comp) end)
            cleaned = cleaned + 1
        end
    end
    highlightedComps = {}
    print(string.format("[FNP-Ping2] Cleanup: removed %d outlines\n", cleaned))
end

-- ---- Helper: add outline to a component if in range -------------------------
local function tryHighlight(s, actor, px, py, pz, maxD2, compName)
    local ix, iy, iz = itemLoc(actor)
    if not ix then return false end
    local dx, dy, dz = ix - px, iy - py, iz - pz
    if (dx*dx + dy*dy + dz*dz) > maxD2 then return false end
    local comp = rget(actor, compName or "m_InteractiveComponent")
    if not safeObj(comp) then return false end
    local ok2 = pcall(function() s:AddOutline(comp, STENCIL_USAGE, USE_THICK) end)
    if ok2 then
        highlightedComps[#highlightedComps + 1] = comp
        return true
    end
    return false
end

-- ---- The Ping! --------------------------------------------------------------
local function pingArea()
    local s = subsys()
    if not s then
        print("[FNP-Ping3] No OutlineSubsystem\n")
        return
    end

    local px, py, pz = playerLoc()
    if not px then
        print("[FNP-Ping3] No player location\n")
        return
    end

    -- Enable system + boost visibility
    pcall(function() s:SetIsSystemEnabled(true) end)
    applyConfig()

    -- Clear previous highlights
    doCleanup()

    local maxD2 = PING_RADIUS_UU * PING_RADIUS_UU
    local countItems = 0
    local countCorpses = 0
    local countChests = 0
    local scanned = 0

    -- 1) Scan items (always on)
    local ok, items = pcall(function() return FindAllOf("ItemVisualWorld") end)
    if ok and items then
        for _, it in pairs(items) do
            if safeObj(it) then
                scanned = scanned + 1
                if tryHighlight(s, it, px, py, pz, maxD2, "m_InteractiveComponent") then
                    countItems = countItems + 1
                end
            end
        end
    end

    -- 2) Scan corpses (if enabled)
    if HIGHLIGHT_CORPSES then
        local ok2, chars = pcall(function() return FindAllOf("GothicCharacter") end)
        if ok2 and chars then
            -- Get player address to skip self
            local playerPawn = rget(pcCache, "Pawn")
            local playerAddr = nil
            if safeObj(playerPawn) then
                pcall(function() playerAddr = playerPawn:GetAddress() end)
            end
            for _, ch in pairs(chars) do
                if safeObj(ch) then
                    scanned = scanned + 1
                    -- Skip player
                    local chAddr = nil
                    pcall(function() chAddr = ch:GetAddress() end)
                    if chAddr ~= playerAddr then
                        -- Only highlight if ragdoll is active (= dead/defeated)
                        if ragdollActive(ch) then
                            if tryHighlight(s, ch, px, py, pz, maxD2, "m_InteractiveComponent") then
                                countCorpses = countCorpses + 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3) Scan chests (if enabled)
    if HIGHLIGHT_CHESTS then
        local ok3, objs = pcall(function() return FindAllOf("InteractiveObjectActor") end)
        if ok3 and objs then
            for _, obj in pairs(objs) do
                if safeObj(obj) and isChestName(obj) then
                    scanned = scanned + 1
                    if tryHighlight(s, obj, px, py, pz, maxD2, "m_InteractiveComponent") then
                        countChests = countChests + 1
                    end
                end
            end
        end
    end

    local total = countItems + countCorpses + countChests
    print(string.format("[FNP-Ping3] PING! scanned=%d, items=%d, corpses=%d, chests=%d, total=%d, radius=%.0f\n",
        scanned, countItems, countCorpses, countChests, total, PING_RADIUS_UU))

    -- Schedule cleanup
    ExecuteWithDelay(PING_DURATION_MS, function()
        doCleanup()
    end)
end

-- ---- Status file (so UI connects) ------------------------------------------
local function writeStatus()
    local f = io.open(FNP_STATUS_FILE, "w")
    if f then
        f:write("STATE=ON\n")
        f:write(string.format("RADIUS=%.0f\n", PING_RADIUS_UU))
        f:write(string.format("OUTLINED=%d\n", #highlightedComps))
        f:write(string.format("STENCIL=%d\n", STENCIL_USAGE))
        f:write(string.format("ALPHA=%.2f\n", USER_ALPHA))
        f:write(string.format("THICK=%s\n", USE_THICK and "1" or "0"))
        f:write(string.format("CORPSES=%s\n", HIGHLIGHT_CORPSES and "1" or "0"))
        f:write(string.format("CHESTS=%s\n", HIGHLIGHT_CHESTS and "1" or "0"))
        f:write("MODE=PING\n")
        f:close()
    end
end

-- ---- Read config from control file -----------------------------------------
local function readConfig()
    local f = io.open(FNP_CONTROL_FILE, "r")
    if not f then return nil end
    local cmd = nil
    for line in f:lines() do
        local r = line:match("RADIUS%s+(%S+)")
        if r then
            local num = tonumber(r)
            if num and num >= 100 then PING_RADIUS_UU = num end
        end
        local st = line:match("STENCIL%s+(%S+)")
        if st then
            local n = tonumber(st)
            if n then
                -- Other exposed values render as white in the current game.
                STENCIL_USAGE = 4
                cfgApplied = false  -- re-apply config on next ping
            end
        end
        local al = line:match("ALPHA%s+(%S+)")
        if al then
            local a = tonumber(al)
            if a and a >= 0.0 and a <= 1.0 then
                USER_ALPHA = a
                cfgApplied = false
            end
        end
        local th = line:match("THICK%s+(%S+)")
        if th then USE_THICK = (th == "1" or th:lower() == "true") end
        local co = line:match("CORPSES%s+(%S+)")
        if co then HIGHLIGHT_CORPSES = (co == "1" or co:lower() == "true") end
        local ch = line:match("CHESTS%s+(%S+)")
        if ch then HIGHLIGHT_CHESTS = (ch == "1" or ch:lower() == "true") end
        local dur = line:match("DURATION%s+(%S+)")
        if dur then
            local d = tonumber(dur)
            if d and d >= 1 and d <= 30 then PING_DURATION_MS = d * 1000 end
        end
        if line:match("^PING") then cmd = "PING" end
    end
    f:close()
    return cmd
end

-- ---- Hotkey registration ----------------------------------------------------
local isRegistered = false
local function tryRegister()
    if isRegistered then return true end
    local ok = pcall(function()
        RegisterKeyBindAsync(Key.V, {}, function()
            ExecuteInGameThread(function()
                readConfig()
                pcall(pingArea)
            end)
        end)
    end)
    if ok then
        isRegistered = true
        print("[FNP-Ping2] Hotkey V registered\n")
        return true
    end
    return false
end

-- Try registering keybind
LoopAsync(2000, function()
    return not tryRegister()
end)

-- ---- Background loop: write status + poll control file for UI PING command --
LoopAsync(500, function()
    ExecuteInGameThread(function()
        -- Always read config to pick up checkbox/slider changes from UI
        pcall(function() readConfig() end)
        pcall(writeStatus)
        -- Check for UI-triggered PING
        local ok, f = pcall(function() return io.open(FNP_CONTROL_FILE, "r") end)
        if ok and f then
            local content = f:read("*a")
            f:close()
            if content and content:match("PING") then
                -- Strip PING line but keep all config settings
                local cleaned = content:gsub("[^\n]*PING[^\n]*\n?", "")
                if cleaned:match("^%s*$") then cleaned = "IDLE\n" end
                local ok2, fw = pcall(function() return io.open(FNP_CONTROL_FILE, "w") end)
                if ok2 and fw then
                    fw:write(cleaned)
                    fw:close()
                end
                pcall(pingArea)
            end
        end
    end)
    return false
end)
