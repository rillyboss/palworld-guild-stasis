--------------------------------------------------------------------------------
-- GuildStasisProbe -- throwaway discovery mod. Read-only. Not shipped.
--
-- Purpose: find out how Palworld 1.0.1 actually exposes guilds on a dedicated
-- server, because FindAllOf('PalGroupGuild') and PalGroupManager.GuildMap both
-- came back empty while a guild demonstrably existed (confirmed independently
-- via GET /v1/api/game-data).
--
-- Every access is pcall-wrapped and IsValid-gated. It writes nothing.
--------------------------------------------------------------------------------

local TAG = "[PROBE] "
local function log(fmt, ...)
    local m = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    print(TAG .. m .. "\n")
end
local function try(fn) local ok, r, r2 = pcall(fn); if ok then return r, r2 end return nil end
local function alive(o) if o == nil then return false end return try(function() return o:IsValid() end) == true end

local function clsName(o)
    local n = try(function() return o:GetClass():GetFName():ToString() end)
    if n then return n end
    n = try(function() return o:GetClass():GetFullName() end)
    return n or "?"
end

local function fullName(o)
    return try(function() return o:GetFullName() end) or "?"
end

local function guidStr(g)
    local a = try(function() return g.A end)
    if type(a) ~= "number" then return nil end
    return string.format("%08X%08X%08X%08X",
        a & 0xFFFFFFFF,
        (try(function() return g.B end) or 0) & 0xFFFFFFFF,
        (try(function() return g.C end) or 0) & 0xFFFFFFFF,
        (try(function() return g.D end) or 0) & 0xFFFFFFFF)
end

--------------------------------------------------------------------------------

local CLASS_CANDIDATES = {
    "PalGroupManager", "PalGroupBase", "PalGroupGuild", "PalGroupGuildBase",
    "PalGroupIndependentGuild", "PalGroupOrganization", "PalGroupNeutral",
    "PalGuildInfo", "PalGroupPlayer", "PalBaseCampManager", "PalBaseCampModel",
    "PalBaseCampWorkerDirector", "PalIndividualCharacterContainer",
    "PalIndividualCharacterSlot", "PalIndividualCharacterHandle",
    "PalIndividualCharacterParameter", "PalCheatManager", "PalPlayerState",
}

local MAP_CANDIDATES = {
    "GuildMap", "GroupMap", "GuildInfoMap", "Groups", "GuildList",
    "AdminGroupMap", "GroupIdMap",
}

local function probeClasses()
    log("--- FindAllOf per candidate class (non-CDO counts) ---")
    for _, c in ipairs(CLASS_CANDIDATES) do
        local arr = try(function() return FindAllOf(c) end)
        if arr == nil then
            log("  %-34s FindAllOf -> nil (class not found)", c)
        else
            local total, real, sample = #arr, 0, nil
            for i = 1, total do
                local o = arr[i]
                if alive(o) and not (fullName(o):find("Default__", 1, true)) then
                    real = real + 1
                    if sample == nil then sample = fullName(o) end
                end
            end
            log("  %-34s total=%-4d live=%-4d  %s", c, total, real, sample or "")
        end
    end
end

local function probeManagerMaps()
    local gm = try(function() return FindFirstOf("PalGroupManager") end)
    if not alive(gm) then log("PalGroupManager NOT FOUND"); return end
    log("--- PalGroupManager = %s ---", fullName(gm))

    for _, name in ipairs(MAP_CANDIDATES) do
        local m = try(function() return gm[name] end)
        if m == nil then
            log("  %-14s : absent", name)
        else
            local hasForEach = try(function() return type(m.ForEach) end) == "function"
            local n = 0
            if hasForEach then
                try(function()
                    m:ForEach(function(k, v)
                        n = n + 1
                        local kk = try(function() return k:get() end); if kk == nil then kk = k end
                        local vv = try(function() return v:get() end); if vv == nil then vv = v end
                        if n <= 12 then
                            log("      [%d] key=%s  value=%s  class=%s",
                                n, tostring(guidStr(kk) or kk), fullName(vv), clsName(vv))
                        end
                    end)
                    return true
                end)
            end
            log("  %-14s : present forEach=%s entries=%d", name, tostring(hasForEach), n)
        end
    end
end

-- Reach the guild from the player instead of from the manager.
local function probeFromPlayer()
    log("--- guild reached via the player ---")
    local pcs = try(function() return FindAllOf("PlayerController") end) or {}
    for i = 1, #pcs do
        local pc = pcs[i]
        if alive(pc) and not fullName(pc):find("Default__", 1, true) then
            log("  PlayerController: %s", fullName(pc))
            local ps = try(function() return pc.PlayerState end)
            if alive(ps) then
                log("    PlayerState class = %s", clsName(ps))
                local uid = try(function() return ps.IndividualHandleId.PlayerUId end)
                log("    PlayerUId = %s", tostring(guidStr(uid)))

                -- APalPlayerState is documented to know the guild it belongs to.
                for _, n in ipairs({ "GroupIdBelongTo", "GuildIdBelongTo", "GroupID", "GroupId" }) do
                    local v = try(function() return ps[n] end)
                    if v ~= nil then log("    %s = %s", n, tostring(guidStr(v) or v)) end
                end
                for _, fn in ipairs({ "GetGroupIdBelongTo", "GetGuildBelongTo", "GetGroupBelongTo" }) do
                    local v = try(function() return ps[fn](ps) end)
                    if v ~= nil then
                        log("    %s() -> %s  class=%s", fn, tostring(guidStr(v) or v),
                            (type(v) == "userdata") and clsName(v) or type(v))
                    end
                end
            end
        end
    end
end

-- UPalUtility statics via the CDO.
local function probeUtility()
    log("--- PalUtility statics ---")
    local u = try(function() return StaticFindObject("/Script/Pal.Default__PalUtility") end)
    if not alive(u) then log("  PalUtility CDO not found"); return end
    log("  CDO: %s", fullName(u))
    for _, fn in ipairs({ "GetGroupManager", "GetBaseCampManager", "GetWorldSubsystem" }) do
        local v = try(function() return u[fn](u) end)
        log("  %-22s -> %s", fn .. "()", (v ~= nil) and (fullName(v) .. " class=" .. clsName(v)) or "nil/failed")
    end
end

-- What does a PalGroupGuild actually expose? The mod needs (a) an id, (b) the
-- member list with online status, (c) BaseCampIds.
local function probeGuildObjects()
    log("--- PalGroupGuild internals ---")
    local arr = try(function() return FindAllOf("PalGroupGuild") end) or {}
    for i = 1, #arr do
        local g = arr[i]
        if alive(g) and not fullName(g):find("Default__", 1, true) then
            log("  guild[%d] %s", i, fullName(g))

            for _, n in ipairs({ "GroupId", "GroupID", "group_id", "GuildId" }) do
                local v = try(function() return g[n] end)
                if v ~= nil then log("      prop %-22s = %s", n, tostring(guidStr(v) or v)) end
            end
            for _, fn in ipairs({ "GetGroupId", "GetGroupID", "GetGuildName", "GetGroupName", "GetAdminPlayerUId" }) do
                local v = try(function() return g[fn](g) end)
                if v ~= nil then log("      call %-22s -> %s", fn .. "()", tostring(guidStr(v) or v)) end
            end
            for _, n in ipairs({ "GroupName", "GuildName" }) do
                local v = try(function() return g[n] end)
                if v ~= nil then log("      prop %-22s = %s", n, tostring(try(function() return v:ToString() end) or v)) end
            end

            -- base camps
            local bc = try(function() return g.BaseCampIds end)
            if bc == nil then
                log("      BaseCampIds : ABSENT")
                for _, fn in ipairs({ "GetBaseCampIds", "GetBaseCampIdList" }) do
                    local v = try(function() return g[fn](g) end)
                    if v ~= nil then log("      call %s() -> %s", fn, tostring(v)) end
                end
            else
                local n = try(function() return bc:GetArrayNum() end) or try(function() return #bc end) or 0
                log("      BaseCampIds : present count=%s", tostring(n))
                for j = 1, math.min(n, 5) do
                    local id = try(function() return bc[j] end)
                    log("        [%d] %s", j, tostring(guidStr(id)))
                end
            end

            -- members
            local rep = try(function() return g.PlayerInfoRepInfoArray end)
            if rep == nil then
                log("      PlayerInfoRepInfoArray : ABSENT")
                for _, n in ipairs({ "PlayerInfoArray", "Players", "PlayerInfos", "IndividualHandleIds" }) do
                    local v = try(function() return g[n] end)
                    if v ~= nil then log("      alt member container '%s' present", n) end
                end
            else
                log("      PlayerInfoRepInfoArray : present")
                for _, member in ipairs({ "Items", "ItemArray", "Entries", "Array" }) do
                    local items = try(function() return rep[member] end)
                    if items ~= nil then
                        local n = try(function() return items:GetArrayNum() end) or try(function() return #items end) or 0
                        log("        .%s count=%s", member, tostring(n))
                        for j = 1, math.min(n, 5) do
                            local e = try(function() return items[j] end)
                            if e ~= nil then
                                local uid = try(function() return e.PlayerUId end)
                                local info = try(function() return e.PlayerInfo end)
                                log("          [%d] uid=%s status=%s name=%s lastOnline=%s", j,
                                    tostring(guidStr(uid)),
                                    tostring(try(function() return info.Status end)),
                                    tostring(try(function() return info.PlayerName:ToString() end)),
                                    tostring(try(function() return info.LastOnlineRealTime end)))
                            end
                        end
                    end
                end
            end
        end
    end
    if #arr == 0 then log("  no PalGroupGuild found") end
end

local function probeBaseCamps()
    log("--- base camps directly ---")
    local arr = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    local n = 0
    for i = 1, #arr do
        local m = arr[i]
        if alive(m) and not fullName(m):find("Default__", 1, true) then
            n = n + 1
            local belongs = try(function() return m:GetGroupIdBelongTo() end)
            log("  camp[%d] %s  groupIdBelongTo=%s", n, fullName(m), tostring(guidStr(belongs)))
            local wd = try(function() return m.WorkerDirector end)
            log("      WorkerDirector = %s", alive(wd) and clsName(wd) or "nil")
            if alive(wd) then
                local cont = try(function() return wd.CharacterContainer end)
                log("      CharacterContainer = %s", alive(cont) and clsName(cont) or "nil")
                if alive(cont) then
                    local slots = try(function() return cont.SlotArray end)
                    local cnt = 0
                    if slots ~= nil then cnt = try(function() return slots:GetArrayNum() end) or try(function() return #slots end) or 0 end
                    log("      SlotArray count = %s", tostring(cnt))
                    for si = 1, math.min(cnt, 6) do
                        local slot = try(function() return slots[si] end)
                        if alive(slot) then
                            local h = try(function() return slot.Handle end)
                            local p = alive(h) and try(function() return h:TryGetIndividualParameter() end) or nil
                            local a, b = nil, nil
                            if alive(h) then a, b = try(function() return h:TryGetIndividualParameter() end) end
                            if not alive(p) then if alive(b) then p = b elseif alive(a) then p = a end end
                            if alive(p) then
                                -- Collateral watch: SetDisableNaturalUpdate is a blunt
                                -- switch and its scope is uncatalogued. Log the other
                                -- things that might be frozen alongside hunger/SAN so a
                                -- suppressed Pal can be compared against a live one.
                                local sp = try(function() return p.SaveParameter end)
                                local function spv(name)
                                    if sp == nil then return "?" end
                                    local v = try(function() return sp[name] end)
                                    if v == nil then return "-" end
                                    local n = try(function() return v.Value end)
                                    if n ~= nil then return tostring(n) end
                                    return tostring(v)
                                end
                                log("      slot[%d] param OK  stomach=%s/%s san=%s/%s group=%s | exp=%s friend=%s hp=%s rank=%s sick=%s",
                                    si,
                                    tostring(try(function() return p:GetFullStomach() end)),
                                    tostring(try(function() return p:GetMaxFullStomach() end)),
                                    tostring(try(function() return p:GetSanityValue() end)),
                                    tostring(try(function() return p:GetMaxSanityValue() end)),
                                    tostring(guidStr(try(function() return p:GetGroupId() end))),
                                    spv("Exp"), spv("FriendshipPoint"), spv("Hp"),
                                    spv("Rank"), spv("WorkerSick"))
                            else
                                log("      slot[%d] handle=%s param=UNREADABLE", si, alive(h) and "ok" or "nil")
                            end
                        end
                    end
                end
            end
        end
    end
    if n == 0 then log("  no live PalBaseCampModel found") end
end

--------------------------------------------------------------------------------

-- Discovery for the "park the Pals so they stop working" feature. Keeping base
-- production running while a guild is offline is free upkeep-less output, which
-- is a balance problem on a shared server -- so we want work stopped too.
--
-- Preference order, safest first:
--   1. a per-CAMP order/pause switch on the worker director (one write, trivially
--      reversible, touches no player config)
--   2. a per-CAMP state on the base camp model
--   3. per-PAL off-work list surgery (needs a persisted restore map -- last resort)
local function probeWorkStop()
    log("--- work-stop mechanism discovery ---")

    local function tryNames(obj, label, names)
        if not alive(obj) then log("  %s: not alive", label); return end
        for _, n in ipairs(names) do
            local v = try(function() return obj[n](obj) end)
            local how = "call"
            if v == nil then v = try(function() return obj[n] end); how = "prop" end
            if v ~= nil then
                local shown = try(function() return tostring(v) end) or "?"
                log("  %s.%s [%s] -> %s", label, n, how, shown)
            end
        end
    end

    local camps = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    for i = 1, #camps do
        local m = camps[i]
        if alive(m) and not fullName(m):find("Default__", 1, true) then
            log("  == camp %d guild=%s", i, tostring(guidStr(try(function() return m:GetGroupIdBelongTo() end))))

            tryNames(m, "model", {
                "GetState", "State", "GetBaseCampState", "IsActive", "IsWorkable",
                "SetState", "GetWorkerCount", "GetLevel",
            })

            local wd = try(function() return m.WorkerDirector end)
            tryNames(wd, "workerDirector", {
                "GetCurrentOrderType", "CurrentOrderType", "GetOrderType", "OrderType",
                "SetCurrentOrderType", "SetOrderType", "RequestOrderType",
                "GetCurrentBattleType", "CurrentBattleType",
                "IsStopWork", "SetStopWork", "Pause", "SetPause", "SetEnable",
                "GetWorkerNum", "GetAssignableWorkerNum",
            })
        end
    end

    -- Per-Pal fallback: does the off-work preference container resolve at all?
    local params = try(function() return FindAllOf("PalIndividualCharacterParameter") end) or {}
    local shown = 0
    for i = 1, #params do
        local p = params[i]
        if alive(p) and not fullName(p):find("Default__", 1, true) and shown < 2 then
            local sp = try(function() return p.SaveParameter end)
            if sp ~= nil then
                shown = shown + 1
                for _, n in ipairs({ "WorkSuitabilityPreferenceInfo", "WorkSuitabilityPreference",
                                     "WorkSuitabilityOption", "OffWorkSuitabilityList" }) do
                    local v = try(function() return sp[n] end)
                    if v ~= nil then
                        local inner = try(function() return v.OffWorkSuitabilityList end)
                        local cnt = "n/a"
                        if inner ~= nil then
                            cnt = tostring(try(function() return inner:GetArrayNum() end) or try(function() return #inner end) or "?")
                        end
                        log("  SaveParameter.%s present (OffWorkSuitabilityList count=%s)", n, cnt)
                    end
                end
                tryNames(p, "param", { "GetWorkSuitabilityPreference", "GetOffWorkSuitabilityList",
                                       "IsOffWorkSuitability", "GetCurrentWorkSuitability" })
            end
        end
    end
    log("--- end work-stop discovery ---")
end

local RUNS = 60          -- 30s apart = ~30 minutes of sampling
local run = 0

local function once()
    run = run + 1
    local players = 0
    local pcs = try(function() return FindAllOf("PlayerController") end) or {}
    for i = 1, #pcs do
        if alive(pcs[i]) and not fullName(pcs[i]):find("Default__", 1, true) then players = players + 1 end
    end

    log("============ PROBE RUN %d/%d (playerControllers=%d) ============", run, RUNS, players)
    -- The heavy structural dumps only need to happen a few times; the per-Pal
    -- stat sampling needs to happen every run so we get a decay curve.
    if run <= 2 or run % 10 == 0 then
        probeClasses()
        probeManagerMaps()
        probeGuildObjects()
        probeWorkStop()
        probeFromPlayer()
        if run == 1 then probeUtility() end
    end
    probeBaseCamps()
    log("============ PROBE RUN %d END ============", run)
end

local function schedule(delayMs)
    ExecuteWithDelay(delayMs, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(once)
            if not ok then log("PROBE ERROR: %s", tostring(err)) end
        end)
        if run < RUNS then schedule(60000) end
    end)
end

schedule(25000)
log("GuildStasisProbe loaded; first probe in 25s, then every 60s x%d.", RUNS)
