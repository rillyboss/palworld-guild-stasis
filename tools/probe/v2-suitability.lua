--------------------------------------------------------------------------------
-- v2 probe: does zeroing CraftSpeedRates gate EVERY work suitability, or only
-- handiwork?
--
-- READ ONLY. Writes nothing. Safe to leave enabled.
--
-- WHY THIS MATTERS. zero_work_speed is verified to take GetCraftSpeed_withBuff from
-- 70 to 0, and a Lamball was observed attempting to craft with no progress. But
-- Palworld automates thirteen different work types, and if the rate container only
-- gates crafting then a suppressed base could still water crops, generate
-- electricity, or haul items -- and "no free production" would be false.
--
-- Reason for optimism: "CraftSpeed" is the engine's name for the general Work Speed
-- stat, not a handiwork-specific one. The binary carries Rank_CraftSpeed,
-- AddWorkSpeedPerWorkSpeedRank, StatusPointName_AddWorkSpeed, and -- most tellingly
-- -- CraftSpeed_EmitFlame, a craft speed for KINDLING. So the concept is
-- parameterised across work types rather than confined to one.
--
-- Reason for caution: GetCraftSpeedByWorkSuitability(Handcraft) did NOT move when
-- the rate went in, while GetCraftSpeed_withBuff did. The likely explanation is
-- base-versus-final getter pairs:
--
--     GetCraftSpeed                      base    -> stayed 70
--     GetCraftSpeed_withBuff             final   -> 0
--     GetCraftSpeedByWorkSuitability     base    -> stayed 50
--     GetCraftSpeed_withBuff_WorkSuitability   final   -> THIS PROBE
--
-- If the last one reads 0 across all thirteen suitabilities on a suppressed Pal,
-- the lever is global and "no free production" holds. If it only zeroes for some,
-- zero_work_speed is incomplete and the README must say so.
--
-- Method: print both the base and final per-suitability values for EVERY base camp
-- Pal. With one guild offline (suppressed) and one online (not), a single run gives
-- the comparison directly -- no need to trust a remembered baseline.
--------------------------------------------------------------------------------

local TAG = "[V2SUIT] "
local function log(fmt, ...)
    local m = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    print(TAG .. m .. "\n")
end
local function try(fn) local ok, r, r2 = pcall(fn); if ok then return r, r2 end return nil end
local function alive(o)
    if o == nil then return false end
    return try(function() return o:IsValid() end) == true
end
local function isCDO(o)
    local n = try(function() return o:GetFullName() end)
    return type(n) == "string" and n:find("Default__", 1, true) ~= nil
end
local function guidStr(g)
    local a = try(function() return g.A end)
    if type(a) ~= "number" then return nil end
    return string.format("%08X", a & 0xFFFFFFFF)
end

-- Values confirmed by observation on a live 1.0 server (see main.lua).
local SUITABILITIES = {
    { 1,  "EmitFlame"           },   -- kindling
    { 2,  "Watering"            },
    { 3,  "Seeding"             },   -- planting
    { 4,  "GenerateElectricity" },
    { 5,  "Handcraft"           },   -- handiwork
    { 6,  "Collection"          },   -- gathering
    { 7,  "Deforest"            },   -- lumbering
    { 8,  "Mining"              },
    { 9,  "OilExtraction"       },
    { 10, "ProductMedicine"     },
    { 11, "Cool"                },   -- cooling
    { 12, "Transport"           },   -- hauling
    { 13, "MonsterFarm"         },   -- farming
}

local function rateEntries(param)
    local sp = try(function() return param.SaveParameter end)
    local c = sp and try(function() return sp.CraftSpeedRates end) or nil
    local v = c and try(function() return c.Values end) or nil
    local n = v and try(function() return v:GetArrayNum() end) or nil
    if type(n) ~= "number" then return "?" end
    local out = {}
    for i = 1, n do
        local raw = try(function() return v[i] end)
        local el = try(function() return raw:get() end) or raw
        if el ~= nil then
            out[#out + 1] = string.format("%s=%s",
                tostring(try(function() return el.Key:ToString() end)),
                tostring(try(function() return el.Value end)))
        end
    end
    return string.format("%d entry(s) [%s]", n, table.concat(out, " "))
end

local function reportPal(param, label)
    local base  = try(function() return param:GetCraftSpeed() end)
    local final = try(function() return param:GetCraftSpeed_withBuff() end)
    local suppressed = (final == 0)
    log("  %s   base=%s final=%s  %s", label, tostring(base), tostring(final),
        suppressed and "<== SUPPRESSED" or "(working)")
    log("      CraftSpeedRates: %s", rateEntries(param))

    local zero, nonzero, unreadable = {}, {}, {}
    for _, s in ipairs(SUITABILITIES) do
        local id, name = s[1], s[2]
        local f = try(function() return param:GetCraftSpeed_withBuff_WorkSuitability(id) end)
        local b = try(function() return param:GetCraftSpeedByWorkSuitability(id) end)
        if type(f) ~= "number" then
            unreadable[#unreadable + 1] = name
        elseif f == 0 then
            zero[#zero + 1] = string.format("%s(base %s)", name, tostring(b))
        else
            nonzero[#nonzero + 1] = string.format("%s=%s(base %s)", name, tostring(f), tostring(b))
        end
    end
    log("      final ZERO      (%d): %s", #zero, #zero > 0 and table.concat(zero, " ") or "-")
    log("      final NON-ZERO  (%d): %s", #nonzero, #nonzero > 0 and table.concat(nonzero, " ") or "-")
    if #unreadable > 0 then
        log("      unreadable      (%d): %s", #unreadable, table.concat(unreadable, " "))
    end

    -- The interpretation, stated per Pal so it cannot be misread later.
    if suppressed then
        if #nonzero == 0 and #zero > 0 then
            log("      -> every suitability zeroed. The lever is GLOBAL for this Pal.")
        elseif #nonzero > 0 then
            log("      -> NOT global: the listed non-zero suitabilities would still work.")
        end
    end
end

local function run()
    log("=== v2 suitability coverage probe (READ ONLY) ===")
    log("Compare a suppressed Pal against an unsuppressed one in the same run.")

    local camps = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    local seen = 0
    for i = 1, #camps do
        local m = camps[i]
        if alive(m) and not isCDO(m) then
            local grp = guidStr(try(function() return m:GetGroupIdBelongTo() end))
            local wd = try(function() return m.WorkerDirector end)
            local cc = alive(wd) and try(function() return wd.CharacterContainer end) or nil
            local slots = alive(cc) and try(function() return cc.SlotArray end) or nil
            local n = slots and (try(function() return slots:GetArrayNum() end) or 0) or 0
            for si = 1, n do
                local raw = try(function() return slots[si] end)
                local sl = try(function() return raw:get() end) or raw
                local h = alive(sl) and try(function() return sl.Handle end) or nil
                if alive(h) then
                    local a, b = try(function() return h:TryGetIndividualParameter() end)
                    local p = alive(a) and a or (alive(b) and b or nil)
                    if alive(p) then
                        seen = seen + 1
                        reportPal(p, string.format("guild=%s camp=%d slot=%d", tostring(grp), i, si))
                    end
                end
            end
        end
    end
    log("=== %d Pal(s) reported. Nothing was written. ===", seen)
end

-- Repeat, because the first version ran once at 60s and happened to catch no
-- suppressed Pal at all -- the offline guild had not passed its grace period yet.
-- Repeating means suppression can be forced whenever convenient (via the mod's
-- command file: "suppress <idprefix>") and the next pass will report it.
--
-- Chained one-shot ExecuteWithDelay, never LoopAsync: LoopAsync corrupts UE4SS's
-- shared engine-tick callback list and silently kills timers for every Lua mod
-- after 40min-2h. Capped so a forgotten probe cannot log forever.
local PASSES, INTERVAL_MS = 20, 60000
local pass = 0

local function tick()
    pass = pass + 1
    log("---- pass %d/%d ----", pass, PASSES)
    local ok, err = pcall(run)
    if not ok then log("probe error: %s", tostring(err)) end
    if pass < PASSES then
        ExecuteWithDelay(INTERVAL_MS, function()
            ExecuteInGameThread(tick)
        end)
    else
        log("=== probe finished after %d passes; restart to run again ===", PASSES)
    end
end

ExecuteWithDelay(60000, function()
    ExecuteInGameThread(tick)
end)

log(string.format("loaded; first pass in 60s, then every %ds for %d passes",
    INTERVAL_MS / 1000, PASSES))
