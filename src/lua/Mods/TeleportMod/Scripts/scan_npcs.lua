-- scan_npcs_final.lua  ─  最终版：蓝图名→中文名映射 + 坐标提取 + 追加模式
-- 中文名来自哥特1原版角色命名规则（GRD=守卫, VLK=平民, STT=暗影, ORG=兄弟会 等）

local OUTPUT_FILE = "npc_scan_final.txt"
local DUP_THRESHOLD = 3

-- ======== 哥特1 角色中文名映射表 ========
-- 格式：蓝图名中的关键标识 → 中文名
-- 命名规则: Character_[营地]_[阵营]_[名字]_[编号]
local NAME_MAP = {
    -- 主角
    ["PlayerCharacterBP"] = "主角(无名者)",

    -- ===== 有名 NPC =====
    ["Diego"] = "迪亚哥",
    ["Mordrag"] = "莫德拉格",
    ["Thorus"] = "索鲁斯",
    ["Scorpio"] = "天蝎",
    ["Jackal"] = "豺狼",
    ["Sly"] = "斯莱",
    ["Bloodwyn"] = "布拉德温",
    ["Bullit"] = "布利特",
    ["Graham"] = "格拉汉姆",
    ["Gravo"] = "格拉沃",
    ["Grim"] = "格里姆",
    ["Snaf"] = "斯纳夫(厨师)",
    ["Glen"] = "格伦",
    ["Aleph"] = "阿列夫",
    ["BaalTaran"] = "巴尔·塔兰",
    ["BaalKadash"] = "巴尔·卡达尔",
    ["BaalTondral"] = "巴尔·汤德拉尔",
    ["BaalLukor"] = "巴尔·卢科尔",
    ["BaalOrun"] = "巴尔·奥伦",
    ["BaalParvez"] = "巴尔·帕维兹",
    ["BaalIsidro"] = "巴尔·伊西德罗",
    ["BaalNamib"] = "巴尔·纳米布",
    ["Xardas"] = "扎尔达斯",
    ["Milten"] = "米尔腾",
    ["Lester"] = "莱斯特",
    ["Gorn"] = "戈恩",
    ["Fisk"] = "费斯克",
    ["Dexter"] = "德克斯特",
    ["Torlof"] = "托雷兹",
    ["Whistler"] = "惠斯勒",
    ["Cavalorn"] = "卡瓦洛恩",
    ["Mud"] = "穆德",
    ["Homer"] = "荷马",
    ["Corristo"] = "科里斯托",
    ["Saturas"] = "萨图拉斯",
    ["Lee"] = "李",
    ["Gomez"] = "戈麦斯",
    ["Raven"] = "乌鸦",
    ["YBerion"] = "伊贝利翁",
    ["CorAngar"] = "科尔·安加尔",
    ["CorKalom"] = "科尔·卡洛姆",
    ["GorNaToth"] = "戈尔·纳·托斯",
    ["GorBoba"] = "戈尔·波巴",
    ["Lares"] = "拉雷斯",
    ["Jarvis"] = "贾维斯",
    ["Scatty"] = "斯卡提",
    ["Bartholo"] = "巴索洛",
    ["Stone"] = "石头",
    ["Fingers"] = "手指",
    ["Nek"] = "内克",
    ["Lefty"] = "左撇子",
    ["Dusty"] = "灰尘",
    ["Drax"] = "德拉克斯",
    ["Skip"] = "斯基普",
    ["Cipher"] = "赛弗",
    ["Ratford"] = "拉特福德",
    ["Kirgo"] = "基尔戈",
    ["Wolf"] = "沃尔夫",
    ["Baal"] = "巴尔",
    ["Ian"] = "伊恩",
    ["Fletcher"] = "弗莱彻",
    ["Mordrag"] = "莫德拉格",
    ["Arlin"] = "阿林",

    -- ===== 通用职业名（按阵营前缀） =====
    -- GRD = 守卫 (Guard)
    ["GRD_Guard"] = "守卫",
    ["GRD_GateGuard"] = "门卫",

    -- STT = 暗影 (Shadow/Schatten)
    ["STT_Shadow"] = "暗影",

    -- VLK = 平民 (Volk)
    ["VLK_Digger"] = "矿工",

    -- ORG = 兄弟会 (Organisation)
    ["ORG_"] = "兄弟会成员",

    -- NOV = 新手 (Novice)
    ["NOV_"] = "新手",

    -- WOC = 苦工/囚犯
    ["WOC_Prisoner"] = "囚犯",

    -- ===== 生物 =====
    ["Meatbug"] = "肉虫",
    ["Scavenger"] = "食腐兽",
    ["Molerat"] = "鼹鼠鼠",
    ["Bloodfly"] = "血蝇",
    ["Lurker"] = "潜伏者",
    ["Snapper"] = "利齿兽",
    ["Warg"] = "狼",
    ["Shadowbeast"] = "暗影兽",
    ["Troll"] = "巨魔",
    ["Golem"] = "石魔",
    ["Skeleton"] = "骷髅",
    ["Zombie"] = "僵尸",
    ["Minecrawler"] = "矿虫",
    ["OrcWarrior"] = "兽人战士",
    ["OrcScout"] = "兽人斥候",
    ["OrcSlave"] = "兽人奴隶",
}

-- 从蓝图名中提取中文名
local function lookupChinese(bpName)
    -- 1. 精确匹配有名NPC（从名字部分提取）
    for key, cn in pairs(NAME_MAP) do
        if bpName:find(key, 1, true) then
            return cn
        end
    end
    -- 2. 没有匹配到
    return nil
end

-- 坐标（延时读取，确保初始化完成）
local function getLoc(actor)
    local ok, root = pcall(function() return actor.RootComponent end)
    if ok and root and root:IsValid() then
        local ok2, ctw = pcall(function() return root.ComponentToWorld end)
        if ok2 and ctw and ctw.Translation then
            local t = ctw.Translation
            if type(t.X) == "number" and t.X ~= 0 then return t.X, t.Y, t.Z end
        end
        local ok3, loc = pcall(function() return root.RelativeLocation end)
        if ok3 and loc and type(loc.X) == "number" and loc.X ~= 0 then return loc.X, loc.Y, loc.Z end
    end
    local ok4, v = pcall(function() return actor:K2_GetActorLocation() end)
    if ok4 and v and type(v.X) == "number" then return v.X, v.Y, v.Z end
    return nil
end

local function shortBP(fullName)
    if not fullName then return "?" end
    local tail = fullName:match("%.([^%.]+)$") or fullName
    return tail:gsub("_C_%d+$", ""):gsub("_%d+$", "")
end

print("[NPC-FINAL] Starting NPC scan with Chinese name mapping...\n")

-- 延迟 2 秒执行，确保热加载后角色坐标已初始化
ExecuteInGameThread(function()
    local allChars = FindAllOf("GothicCharacter")
    if not allChars then
        print("[NPC-FINAL] ERROR: FindAllOf returned nil.\n")
        return
    end

    local entries = {}
    local cnCount = {}  -- 中文名计数（用于去重）

    for _, actor in pairs(allChars) do
        local ok, valid = pcall(function() return actor:IsValid() end)
        if ok and valid then
            local okN, fullName = pcall(function() return actor:GetFullName() end)
            local bp = shortBP(okN and tostring(fullName) or nil)
            local x, y, z = getLoc(actor)

            if x then
                local cn = lookupChinese(bp) or bp
                entries[#entries + 1] = { cn = cn, bp = bp, x = x, y = y, z = z }
                cnCount[cn] = (cnCount[cn] or 0) + 1
            end
        end
    end

    -- 过滤掉中文名出现 >= DUP_THRESHOLD 次的（批量NPC）
    local filtered = {}
    local skipped = {}
    for _, e in ipairs(entries) do
        if cnCount[e.cn] >= DUP_THRESHOLD then
            skipped[e.cn] = cnCount[e.cn]
        else
            filtered[#filtered + 1] = e
        end
    end

    table.sort(filtered, function(a, b) return a.cn < b.cn end)

    local f = io.open(OUTPUT_FILE, "w")
    if not f then
        print("[NPC-FINAL] ERROR: Cannot open " .. OUTPUT_FILE .. "\n")
        return
    end

    f:write("=== Gothic 1 Remake NPC 坐标扫描 (中文名) ===\n")
    f:write(string.format("扫描总数: %d | 保留: %d | 过滤(≥%d同名): %d\n\n",
        #entries, #filtered, DUP_THRESHOLD, #entries - #filtered))

    -- 被过滤的批量 NPC
    f:write("--- 已过滤的批量NPC (同名≥" .. DUP_THRESHOLD .. ") ---\n")
    local skList = {}
    for name, count in pairs(skipped) do skList[#skList + 1] = { name = name, count = count } end
    table.sort(skList, function(a, b) return a.count > b.count end)
    for _, s in ipairs(skList) do
        f:write(string.format("  [跳过] %-20s x%d\n", s.name, s.count))
    end
    f:write("\n")

    -- 保留的有名 NPC
    f:write("--- 有名NPC坐标列表 ---\n")
    f:write(string.format("%-20s | %-50s | %8s | %8s | %8s\n", "中文名", "蓝图名", "X", "Y", "Z"))
    f:write(string.rep("-", 110) .. "\n")
    for _, e in ipairs(filtered) do
        f:write(string.format("%-20s | %-50s | %8.0f | %8.0f | %8.0f\n",
            e.cn, e.bp, e.x, e.y, e.z))
    end

    -- TeleportMod 兼容格式
    f:write("\n\n--- TeleportMod spots.ini 格式 (可直接复制追加) ---\n")
    for _, e in ipairs(filtered) do
        f:write(string.format("NPC-%s|%.0f|%.0f|%.0f\n", e.cn, e.x, e.y, e.z))
    end

    f:close()
    print(string.format("[NPC-FINAL] Done! %d NPCs → %s\n", #filtered, OUTPUT_FILE))
end)
