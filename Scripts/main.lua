--------------------------------------------------------------------------------
-- GuildStasis
--
-- Server-side UE4SS Lua mod for Palworld 1.0 (UE 5.1) Windows dedicated servers.
--
-- Purpose: while EVERY member of a guild is offline, stop that guild's base camp
-- Pals from starving and losing SAN -- without affecting any other guild on the
-- server. Every write is per-Pal and keyed by our own FName, so it composes with
-- vanilla and with other mods, and it can be removed cleanly.
--
-- Read the README before running this on a server you care about.
--
-- SAFETY RULES OBSERVED THROUGHOUT (each one is a real, reproduced crash on this
-- engine build -- do not "simplify" them away):
--   1. UE4SS returns a WRAPPER, not nil, for null UObject properties, and pcall
--      CANNOT catch the native access violation from calling a method on a stale
--      wrapper. Therefore: alive(obj) before ANY member call. IsValid() itself is
--      safe to call on a stale wrapper.
--   2. Reading a SoftObjectProperty from Lua crashes inside UE4SS. We never do.
--   3. Container enumeration uses the SlotArray property. GetSlots() returns by
--      value and fails to marshal.
--   4. LoopAsync corrupts UE4SS's shared engine-tick callback list and silently
--      kills timers for every Lua mod after 40min-2h. We chain one-shot
--      ExecuteWithDelay instead.
--   5. FindAllOf scans the entire UObject array. It is cached and refreshed on an
--      interval, never called per-tick.
--   6. Default__ CDOs are skipped from every FindAllOf result.
--------------------------------------------------------------------------------

local ok_cfg, CFG = pcall(require, "config")
if not ok_cfg or type(CFG) ~= "table" then
    print("[STASIS] FATAL: could not load config.lua -- mod disabled. Error: " .. tostring(CFG) .. "\n")
    return
end

local MOD_VERSION  = "0.1.0"
local TAG          = "[STASIS] "
local SUPPRESS_KEY = "GuildStasis_Offline"   -- our namespaced FName key

-- Status flipped to Online by the engine; Logout is the other state.
-- EPalGuildPlayerStatus : uint8 { Logout = 0, Online = 1 }
local STATUS_LOGOUT = 0
local STATUS_ONLINE = 1

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

local function try(fn)
    local ok, r, r2, r3 = pcall(fn)
    if ok then return r, r2, r3 end
    return nil
end

local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    print(TAG .. msg .. "\n")
end

-- Rule 1. Never trust ~= nil.
local function alive(o)
    if o == nil then return false end
    return try(function() return o:IsValid() end) == true
end

local function isCDO(o)
    local n = try(function() return o:GetFullName() end)
    return type(n) == "string" and n:find("Default__", 1, true) ~= nil
end

-- FGuid is four int32 fields. Sign-extension on negative int32 is a known
-- footgun in printf here, so mask each word.
local function guidStr(g)
    if g == nil then return nil end
    local a = try(function() return g.A end)
    if type(a) ~= "number" then return nil end
    local b = try(function() return g.B end) or 0
    local c = try(function() return g.C end) or 0
    local d = try(function() return g.D end) or 0
    return string.format("%08X-%08X-%08X-%08X",
        a & 0xFFFFFFFF, b & 0xFFFFFFFF, c & 0xFFFFFFFF, d & 0xFFFFFFFF)
end

local function isNullGuid(s)
    return s == nil or s == "00000000-00000000-00000000-00000000"
end

local function str(v)
    if v == nil then return "nil" end
    local s = try(function()
        if type(v) == "userdata" and v.ToString then return v:ToString() end
        return tostring(v)
    end)
    return s or "?"
end

--------------------------------------------------------------------------------
-- TArray / TMap access
--
-- UE4SS exposes these inconsistently depending on property flavour, so probe for
-- the supported shape once per container rather than assuming one.
--------------------------------------------------------------------------------

local function arrCount(a)
    if a == nil then return 0 end
    local n = try(function() return a:GetArrayNum() end)
    if type(n) == "number" then return n end
    n = try(function() return #a end)
    if type(n) == "number" then return n end
    return 0
end

local function arrEach(a, fn)
    if a == nil then return 0 end
    local seen = 0
    local hasForEach = try(function() return type(a.ForEach) end) == "function"
    if hasForEach then
        local completed = try(function()
            a:ForEach(function(i, el)
                -- ForEach yields a wrapper; :get() unwraps it.
                local v = try(function() return el:get() end)
                if v == nil then v = el end
                seen = seen + 1
                fn(i, v)
            end)
            return true
        end)
        if completed then return seen end
        -- ForEach threw. Do NOT fall through: it may have partially iterated.
        log("WARN: TArray:ForEach failed after %d element(s); skipping remainder", seen)
        return seen
    end
    for i = 1, arrCount(a) do
        local v = try(function() return a[i] end)
        if v ~= nil then
            seen = seen + 1
            fn(i, v)
        end
    end
    return seen
end

local function mapEach(m, fn)
    if m == nil then return 0 end
    local seen = 0
    local hasForEach = try(function() return type(m.ForEach) end) == "function"
    if not hasForEach then return -1 end   -- caller falls back to FindAllOf
    local completed = try(function()
        m:ForEach(function(k, v)
            local kk = try(function() return k:get() end); if kk == nil then kk = k end
            local vv = try(function() return v:get() end); if vv == nil then vv = v end
            seen = seen + 1
            fn(kk, vv)
        end)
        return true
    end)
    if not completed then
        log("WARN: TMap:ForEach failed after %d entry(ies)", seen)
        return -1
    end
    return seen
end

-- Resolve a value by trying each candidate name as a METHOD CALL first, then as a
-- bare property. Returns the value and the name that worked.
--
-- Do NOT reintroduce a `type(obj[n]) == "function"` check here. UE4SS does not
-- return a Lua value of type "function" for a UFunction accessed as a property,
-- so that check silently skipped every method and this helper appeared to work
-- while only ever reading plain properties. It cost us two misdiagnosed failures:
-- guild ids and GetGroupIdBelongTo() both came back nil despite being readable.
local function firstOf(obj, names)
    if not alive(obj) then return nil, nil end
    for _, n in ipairs(names) do
        -- Method form: obj[n](obj) is exactly what obj:n() desugars to.
        local v = try(function() return obj[n](obj) end)
        if v ~= nil then return v, n end
        -- Property form.
        v = try(function() return obj[n] end)
        if v ~= nil then return v, n end
    end
    return nil, nil
end

--------------------------------------------------------------------------------
-- Identifier resolution -- log every one individually so a failure names itself
--------------------------------------------------------------------------------

local RESOLVED = {}

local function resolveCheck(label, fn)
    local v = try(fn)
    local ok = (v ~= nil)
    RESOLVED[label] = ok
    if CFG.verbose_resolve then
        log("resolve %-58s %s", label, ok and "OK" or "MISSING")
    end
    return v
end

local function findFirstLive(className)
    local o = try(function() return FindFirstOf(className) end)
    if alive(o) and not isCDO(o) then return o end
    -- FindFirstOf can hand back the CDO; fall back to scanning.
    local arr = try(function() return FindAllOf(className) end)
    if arr then
        for i = 1, #arr do
            local c = arr[i]
            if alive(c) and not isCDO(c) then return c end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Online player set (cross-check for the guild's own status flags)
--------------------------------------------------------------------------------

local onlineUids = {}          -- guidStr -> true
local lastRefreshAt = 0        -- os.time() seconds

-- Wall-clock seconds. Deliberately NOT a counter advanced by the scheduler:
-- sweeps also fire from the login hook, so a counter would over-count elapsed
-- time and prematurely satisfy the grace delay.
local function now()
    return os.time()
end

local function refreshOnlinePlayers()
    local fresh = {}
    local pcs = try(function() return FindAllOf("PlayerController") end) or {}
    local n = 0
    for i = 1, #pcs do
        local pc = pcs[i]
        if alive(pc) and not isCDO(pc) then
            local ps = try(function() return pc.PlayerState end)
            if alive(ps) then
                local uid = try(function() return ps.IndividualHandleId.PlayerUId end)
                local s = guidStr(uid)
                if not isNullGuid(s) then
                    fresh[s] = true
                    n = n + 1
                end
            end
        end
    end
    onlineUids = fresh
    return n
end

--------------------------------------------------------------------------------
-- Guild enumeration
--------------------------------------------------------------------------------

-- Returns a list of { obj, id, name, solo, members = { {uid, name, status} } }
local function enumerateGuilds()
    local guilds = {}

    local function readMembers(g, solo)
        local members = {}
        if solo then
            local uid  = try(function() return g.PlayerUId end)
            local info = try(function() return g.PlayerInfo end)
            members[#members + 1] = {
                uid    = guidStr(uid),
                name   = str(try(function() return info.PlayerName end)),
                status = try(function() return info.Status end),
            }
            return members
        end
        -- Multi-player guild: FPalFastGuildPlayerInfoRepInfoArray.Items
        local rep = try(function() return g.PlayerInfoRepInfoArray end)
        if rep == nil then return members end
        local items = try(function() return rep.Items end)
        if items == nil then
            -- 'Items' is the UE FastArray convention but was never runtime-proven
            -- on this build. Probe alternatives before giving up.
            items = firstOf(rep, { "ItemArray", "Entries", "Array" })
        end
        if items == nil then return members end
        arrEach(items, function(_, entry)
            local uid  = try(function() return entry.PlayerUId end)
            local info = try(function() return entry.PlayerInfo end)
            members[#members + 1] = {
                uid    = guidStr(uid),
                name   = str(try(function() return info.PlayerName end)),
                status = try(function() return info.Status end),
            }
        end)
        return members
    end

    -- idHint comes from the GuildMap KEY, which IS the guild FGuid (verified on a
    -- live 1.0.1 server: the map key matched the GuildID reported by the REST
    -- game-data endpoint for the same guild). Trust the key over asking the
    -- object, because the object's own id accessor does not resolve on this
    -- build -- and a guild dropped for a missing id used to vanish silently.
    local function addGuild(g, solo, idHint)
        if not alive(g) or isCDO(g) then return end
        local id = idHint
        if isNullGuid(id) then
            id = guidStr(firstOf(g, { "GetGroupId", "GroupId", "group_id", "GroupID" }))
        end
        if isNullGuid(id) then
            log("WARN: skipping a %s -- could not determine its guild id (no map key, no readable accessor)",
                str(try(function() return g:GetClass():GetFName():ToString() end)))
            return
        end
        guilds[#guilds + 1] = {
            obj     = g,
            id      = id,
            -- GuildName is the only one that yields readable text on 1.0.1.
            -- GetGuildName()/GetGroupName() hand back FString handles that do not
            -- stringify from Lua, and the GroupName PROPERTY confusingly holds the
            -- owning player's UID rather than a name. Order matters here.
            name    = str(firstOf(g, { "GuildName", "GetGuildName", "GetGroupName" })),
            solo    = solo,
            members = readMembers(g, solo),
        }
    end

    -- Preferred: the group manager's GuildMap (TMap<FGuid, UPalGroupGuildBase*>).
    -- GuildMap is the correct container: on a live 1.0.1 server it held exactly
    -- the one real guild, while GroupMap held 12 entries (PalGroupOrganization,
    -- PalGroupNeutral, PalGroupRaidBoss, PalGroupResidentEnemy...). So GuildMap
    -- is pre-filtered and needs no class check.
    local gm = findFirstLive("PalGroupManager")
    local viaMap = -1
    if gm then
        local map = try(function() return gm.GuildMap end)
        if map ~= nil then
            viaMap = mapEach(map, function(k, v)
                -- Note: UPalGroupIndependentGuild does NOT exist on this build --
                -- FindAllOf reports the class as not found. A solo player gets a
                -- plain PalGroupGuild ("Unnamed Guild"), so there is no separate
                -- solo shape to handle. Kept as a flag only for readMembers.
                local isSolo = try(function() return v.PlayerInfoRepInfoArray end) == nil
                addGuild(v, isSolo, guidStr(k))
            end)
        end
    end

    -- Fallback: scan by class. Also used to sanity-check the map result.
    if viaMap <= 0 then
        if viaMap == 0 then log("GuildMap iterated but was empty; falling back to FindAllOf") end
        local found = try(function() return FindAllOf("PalGroupGuild") end) or {}
        for i = 1, #found do addGuild(found[i], false, nil) end
        log("guild enumeration via FindAllOf('PalGroupGuild'): %d object(s)", #found)
    end

    return guilds
end

-- All members offline? Uses the guild's own Status flags, cross-checked against
-- the live controller list, because the timing of the Status flip on disconnect
-- is unverified on this build. A member counted online by EITHER source keeps
-- the guild unprotected -- fail safe, never suppress a guild that has players.
local function guildAllOffline(guild)
    if #guild.members == 0 then return false, "no members readable" end
    for _, m in ipairs(guild.members) do
        if m.status == STATUS_ONLINE then
            return false, string.format("%s flagged Online", m.name)
        end
        if m.uid and onlineUids[m.uid] then
            return false, string.format("%s has a live PlayerController", m.name)
        end
    end
    return true, nil
end

--------------------------------------------------------------------------------
-- Guild -> base camps -> worker Pals -> IndividualParameter
--
-- Chain (all reflected, all by name -- never by byte offset):
--   UPalGroupOrganization.BaseCampIds : TArray<FGuid>
--     -> UPalBaseCampManager::TryGetModel(FGuid, UPalBaseCampModel*&)
--       -> UPalBaseCampModel.WorkerDirector
--         -> UPalBaseCampWorkerDirector.CharacterContainer
--           -> UPalIndividualCharacterContainer.SlotArray : TArray<Slot*>
--             -> Slot.Handle -> Handle:TryGetIndividualParameter()
--------------------------------------------------------------------------------

local function getBaseCampManager()
    return findFirstLive("PalBaseCampManager")
end

-- Collect every live base camp once per sweep, tagged with the guild it belongs
-- to. This replaces BaseCampIds -> UPalBaseCampManager::TryGetModel(), which does
-- NOT work from Lua: TryGetModel returns its model through an out-param, and
-- out-param marshalling silently yields nothing here (verified live -- the walk
-- reported "0 pal(s) in 0 camp(s)" while a camp demonstrably existed).
--
-- Matching GetGroupIdBelongTo() against the guild id is both verified working and
-- strictly safer: ownership is read from the camp itself rather than trusted from
-- the guild's own id list, so a camp can never be attributed to the wrong guild.
local function collectBaseCamps()
    local out = {}
    local arr = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    for i = 1, #arr do
        local m = arr[i]
        if alive(m) and not isCDO(m) then
            out[#out + 1] = {
                model = m,
                group = guidStr(firstOf(m, { "GetGroupIdBelongTo", "GroupIdBelongTo" })),
            }
        end
    end
    return out
end

-- Calls fn(param, palLabel) for each live worker Pal belonging to this guild.
local function forEachGuildPal(guild, allCamps, fn)
    if allCamps == nil then return 0, 0, "no base camp list" end

    local camps, pals = 0, 0

    -- Per-camp work lives in its own function so bailing on one bad camp skips
    -- only that camp, instead of returning out of the whole guild.
    local function walkCamp(model, campLabel)
        local wd = try(function() return model.WorkerDirector end)
        if not alive(wd) then return 0 end
        local container = try(function() return wd.CharacterContainer end)
        if not alive(container) then return 0 end

        -- Rule 3: SlotArray property, never GetSlots().
        local slots = try(function() return container.SlotArray end)
        if slots == nil then return 0 end

        local found = 0
        arrEach(slots, function(si, slot)
            if not alive(slot) then return end
            local handle = try(function() return slot.Handle end)
            if not alive(handle) then return end
            -- Accept either (param) or (bool, param) shapes.
            local a, b = try(function() return handle:TryGetIndividualParameter() end)
            local param = alive(a) and a or (alive(b) and b or nil)
            if not alive(param) then return end
            found = found + 1
            fn(param, string.format("camp=%s slot=%d", campLabel, si))
        end)
        return found
    end

    for _, entry in ipairs(allCamps) do
        -- Ownership gate: this IS the per-guild isolation guarantee. A camp whose
        -- own GetGroupIdBelongTo() does not equal this guild is never touched.
        if alive(entry.model) and entry.group ~= nil and entry.group == guild.id then
            camps = camps + 1
            pals = pals + walkCamp(entry.model, entry.group)
        end
    end

    return camps, pals, nil
end

--------------------------------------------------------------------------------
-- Per-Pal levers
--------------------------------------------------------------------------------

local function palSnapshot(param)
    return {
        stomach     = firstOf(param, { "GetFullStomach" }),
        maxStomach  = firstOf(param, { "GetMaxFullStomach" }),
        decayRate   = firstOf(param, { "GetFullStomachDecreasingRate" }),
        sanity      = firstOf(param, { "GetSanityValue" }),
        maxSanity   = firstOf(param, { "GetMaxSanityValue" }),
        hungerType  = firstOf(param, { "GetHungerType" }),
        workerSick  = firstOf(param, { "GetWorkerSick" }),
        groupId     = guidStr(firstOf(param, { "GetGroupId" })),
    }
end

local function fmtSnapshot(s)
    return string.format("stomach=%s/%s decay=%s san=%s/%s hunger=%s sick=%s",
        str(s.stomach), str(s.maxStomach), str(s.decayRate),
        str(s.sanity), str(s.maxSanity), str(s.hungerType), str(s.workerSick))
end

local function freezeHunger(param, on)
    if CFG.dry_run then return "dry_run" end
    local applied = try(function()
        if on then
            param:SetDecreaseFullStomachRates(FName(SUPPRESS_KEY), 0.0)
        else
            param:RemoveDecreaseFullStomachRates(FName(SUPPRESS_KEY))
        end
        return true
    end)
    if not applied then return "call failed" end
    -- Verify: if the container SUMS rather than multiplies, inserting 0.0 does
    -- nothing and the whole hunger lever is dead. Report the observed rate so
    -- this is visible in the log instead of silently ineffective.
    local rate = firstOf(param, { "GetFullStomachDecreasingRate" })
    return string.format("ok (rate now %s)", str(rate))
end

local function sanityTopUp(param)
    if CFG.dry_run then return "dry_run" end
    local maxSan = firstOf(param, { "GetMaxSanityValue" })
    if type(maxSan) ~= "number" then return "max sanity unreadable" end
    local applied = try(function()
        param.SaveParameter.SanityValue = maxSan
        return true
    end)
    if not applied then return "nested write failed" end
    -- SaveParameter is mirrored (SaveParameterMirror) and GetSaveParameter()
    -- returns by value, so a direct write can be reverted. Read it back.
    local now = firstOf(param, { "GetSanityValue" })
    return string.format("wrote %s, reads back %s", str(maxSan), str(now))
end

local function sanityDisableFlags(param, on)
    if CFG.dry_run then return "dry_run" end
    local applied = try(function()
        param.AffectNaturalSanityDecreaseDisableFlags.Flags[SUPPRESS_KEY] = on and true or nil
        return true
    end)
    return applied and "ok" or "nested TMap write failed"
end

local function sanityNaturalUpdate(param, on)
    if CFG.dry_run then return "dry_run" end
    local applied = try(function()
        param:SetDisableNaturalUpdate(FName(SUPPRESS_KEY), on and true or false)
        return true
    end)
    if not applied then return "call failed" end
    local v = firstOf(param, { "GetDisableNaturalUpdate" })
    return string.format("ok (flag reads %s)", str(v))
end

--------------------------------------------------------------------------------
-- Stop work (experimental)
--
-- EPalWorkSuitability values 1..13, confirmed by observation on a live 1.0
-- server: EmitFlame=1 Watering=2 Seeding=3 GenerateElectricity=4 Handcraft=5
-- Collection=6 Deforest=7 Mining=8 OilExtraction=9 ProductMedicine=10 Cool=11
-- Transport=12 MonsterFarm=13. (0=None, 14=MAX are sentinels.)
--
-- The vanilla off-work list lives on the save parameter as
-- FPalWorkSuitabilityPreferenceInfo { TArray<EPalWorkSuitability> OffWorkSuitabilityList; ... }
-- The name of the member that HOLDS that struct is not established, so probe.
--
-- NOTE ON THE ROUTE: the clean way to change this is the vanilla RPC
-- RequestChangeWorkSuitability_ToServer, which is runtime-proven callable from
-- Lua. But it must be invoked on a component belonging to a player who manages
-- the pal, and writes routed through a player of a DIFFERENT guild are silently
-- no-op'd. Every member of the target guild is offline by definition, so there
-- is no such component. Hence the direct nested write below.
--------------------------------------------------------------------------------

local WORK_SUITABILITIES = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }

local PREF_MEMBER_NAMES = {
    "WorkSuitabilityPreferenceInfo",
    "WorkSuitabilityPreference",
    "WorkSuitabilityOption",
}

-- IMPORTANT: a non-nil result from obj[name] proves NOTHING on this build. UE4SS
-- hands back a TrivialObject wrapper for arbitrary names -- verified with a
-- negative control, where "SetStopWorkXYZZY" and "PleaseDoNotExist" returned
-- exactly the same shape as names that do exist. So presence must be established
-- by getting a REAL value out, not by a nil check.
--
-- Here that means the candidate must yield a container that answers GetArrayNum()
-- with an actual number.
local function getOffWorkList(param)
    local sp = try(function() return param.SaveParameter end)
    if sp == nil then return nil, "SaveParameter unreadable" end
    for _, n in ipairs(PREF_MEMBER_NAMES) do
        local pref = try(function() return sp[n] end)
        if pref ~= nil then
            local list = try(function() return pref.OffWorkSuitabilityList end)
            if list ~= nil then
                -- The proof: a real TArray reports a numeric length.
                local cnt = try(function() return list:GetArrayNum() end)
                if type(cnt) ~= "number" then cnt = try(function() return #list end) end
                if type(cnt) == "number" then return list, n end
            end
        end
    end
    return nil, "no candidate preference member yielded a real array (all were phantom wrappers)"
end

local function stopWork(param, on)
    if CFG.dry_run then return "dry_run" end
    local list, whereOrErr = getOffWorkList(param)
    if list == nil then return "unavailable: " .. tostring(whereOrErr) end

    local before = arrCount(list)
    local applied = try(function()
        if on then
            -- Only add what is not already off, so we never clobber a player's
            -- own choices with duplicates.
            local present = {}
            arrEach(list, function(_, v)
                local n = tonumber(try(function() return v end))
                if n then present[n] = true end
            end)
            for _, s in ipairs(WORK_SUITABILITIES) do
                if not present[s] then list[#list + 1] = s end
            end
        else
            -- Restoring correctly requires the pal's ORIGINAL list, which is not
            -- persisted anywhere yet. Refuse rather than guess: clearing the list
            -- outright would silently discard the player's own settings.
            error("restore not implemented")
        end
        return true
    end)
    if not applied then
        return on and "nested TArray append failed" or "restore not implemented (see config.lua)"
    end
    return string.format("ok (off-list %d -> %d via %s)", before, arrCount(list), tostring(whereOrErr))
end

local function applySanity(param, on)
    local mode = CFG.sanity_mode
    if mode == nil or mode == "none" then return "skipped (sanity_mode=none)" end
    if mode == "disable_flags"  then return sanityDisableFlags(param, on) end
    if mode == "natural_update" then return sanityNaturalUpdate(param, on) end
    if mode == "topup" then
        if not on then return "n/a (topup has nothing to undo)" end
        local s = palSnapshot(param)
        if type(s.sanity) == "number" and type(s.maxSanity) == "number"
           and s.maxSanity > 0
           and (s.sanity / s.maxSanity) >= (CFG.topup_below_ratio or 0.9) then
            return "above topup threshold"
        end
        return sanityTopUp(param)
    end
    return "unknown sanity_mode: " .. tostring(mode)
end

--------------------------------------------------------------------------------
-- Suppression state, recomputed from live objects every sweep
--
-- Deliberately NOT keyed on FPalInstanceID: base Pals are re-instanced across
-- restarts (verified live on 1.0), so anything keyed that way silently orphans.
-- We key on guild FGuid and re-apply idempotently.
--------------------------------------------------------------------------------

local guildState = {}   -- guildId -> { offlineSince = ms, suppressed = bool, name = str }

local function sweep()
    local t = now()

    local refreshEvery = math.max(1, math.floor((CFG.controller_refresh_ms or 5000) / 1000))
    if (t - lastRefreshAt) >= refreshEvery then
        lastRefreshAt = t
        refreshOnlinePlayers()
    end

    local guilds = enumerateGuilds()
    -- One FindAllOf per sweep, shared across every guild.
    local allCamps = collectBaseCamps()

    local report = {}

    for _, guild in ipairs(guilds) do
        local st = guildState[guild.id]
        if st == nil then
            st = { offlineSince = nil, suppressed = false }
            guildState[guild.id] = st
        end
        st.name = guild.name

        local allOffline, why = guildAllOffline(guild)

        -- TEST ONLY: pretend every guild is offline so the levers can be proven
        -- on a single-account server (see config.lua for why this is necessary).
        if CFG.force_suppress_for_testing then
            if not allOffline then
                log("FORCE_SUPPRESS: overriding '%s' (%s) -- treating as offline", guild.name, why or "?")
            end
            allOffline = true
            why = nil
        end

        if not allOffline then
            if st.suppressed then
                -- Someone came back. Lift suppression immediately.
                local camps, pals = forEachGuildPal(guild, allCamps, function(param, label)
                    local h = CFG.freeze_hunger and freezeHunger(param, false) or "skipped"
                    local s = applySanity(param, false)
                    local w = CFG.stop_work_when_offline and stopWork(param, false) or "skipped"
                    if CFG.verbose_pals then
                        log("  unsuppress %s: hunger=%s sanity=%s work=%s", label, h, s, w)
                    end
                end)
                log("guild '%s' (%s) BACK ONLINE (%s) -- lifted suppression on %d pal(s) in %d camp(s)",
                    guild.name, guild.id, why or "?", pals, camps)
                st.suppressed = false
            end
            st.offlineSince = nil
            report[#report + 1] = { id = guild.id, name = guild.name, protected = false, reason = why }
        else
            if st.offlineSince == nil then
                st.offlineSince = t
                log("guild '%s' (%s) went fully offline; grace %ds before suppression",
                    guild.name, guild.id, CFG.grace_seconds or 300)
            end

            local offlineFor = t - st.offlineSince
            local graceMet = offlineFor >= (CFG.grace_seconds or 300)
            if CFG.force_suppress_for_testing then graceMet = true end

            if CFG.mode ~= "run" then
                report[#report + 1] = { id = guild.id, name = guild.name, protected = false,
                                        reason = "recon mode" }
            elseif not graceMet then
                report[#report + 1] = { id = guild.id, name = guild.name, protected = false,
                                        reason = string.format("in grace (%.0fs/%ds)", offlineFor, CFG.grace_seconds or 300) }
            else
                local firstTime = not st.suppressed
                local camps, pals, err = forEachGuildPal(guild, allCamps, function(param, label)
                    local before = CFG.verbose_pals and palSnapshot(param) or nil
                    local h = CFG.freeze_hunger and freezeHunger(param, true) or "skipped"
                    local s = applySanity(param, true)
                    local w = CFG.stop_work_when_offline and stopWork(param, true) or "skipped"
                    local tu = "n/a"
                    if firstTime and CFG.topup_once_on_offline and CFG.sanity_mode ~= "topup" then
                        tu = sanityTopUp(param)
                    end
                    if CFG.verbose_pals then
                        log("  suppress %s: %s | hunger=%s sanity=%s work=%s topup=%s",
                            label, fmtSnapshot(before), h, s, w, tu)
                    end
                end)
                if err then log("guild '%s': %s", guild.name, err) end
                if firstTime then
                    log("guild '%s' (%s) SUPPRESSED after %.0fs offline -- %d pal(s) in %d camp(s)%s",
                        guild.name, guild.id, offlineFor, pals, camps,
                        CFG.dry_run and " [DRY RUN, nothing written]" or "")
                end
                st.suppressed = true
                report[#report + 1] = { id = guild.id, name = guild.name, protected = true,
                                        pals = pals, camps = camps }
            end
        end
    end

    log("sweep done: %d guild(s), %d player(s) online", #guilds, (function()
        local n = 0; for _ in pairs(onlineUids) do n = n + 1 end; return n
    end)())

    -- Explicit per-guild decision record. This is the evidence for per-guild
    -- isolation: every guild the sweep considered is named along with whether it
    -- was protected and why. Proving isolation from the ABSENCE of a guild in the
    -- write log is weaker -- a guild missed by enumeration entirely would look
    -- identical to one correctly skipped.
    if CFG.verbose_pals then
        for _, r in ipairs(report) do
            log("  decision guild '%s' (%s): protected=%s pals_written=%d%s",
                r.name or "?", r.id,
                tostring(r.protected and true or false),
                r.pals or 0,
                r.reason and ("  reason=" .. r.reason) or "")
        end
    end

    if CFG.status_file then
        local lines = { string.format('{"version":"%s","mode":"%s","dry_run":%s,"guilds":[',
            MOD_VERSION, tostring(CFG.mode), tostring(CFG.dry_run and true or false)) }
        for i, r in ipairs(report) do
            lines[#lines + 1] = string.format('%s{"id":"%s","name":%q,"protected":%s,"pals":%d,"reason":%q}',
                i > 1 and "," or "", r.id, r.name or "", tostring(r.protected and true or false),
                r.pals or 0, r.reason or "")
        end
        lines[#lines + 1] = "]}"
        local body = table.concat(lines)
        local tmp = CFG.status_file .. ".tmp"
        local f = io.open(tmp, "w")
        if f then
            f:write(body); f:close()
            os.remove(CFG.status_file)
            os.rename(tmp, CFG.status_file)
        else
            log("WARN: could not write status file %s", tostring(CFG.status_file))
        end
    end
end

--------------------------------------------------------------------------------
-- Recon: read-only reconnaissance pass (mode = "recon")
--------------------------------------------------------------------------------

local function recon()
    log("---------- RECON PASS (read-only) ----------")

    local n = refreshOnlinePlayers()
    log("live PlayerControllers with a readable PlayerUId: %d", n)
    for uid in pairs(onlineUids) do log("  online uid %s", uid) end

    local gm = findFirstLive("PalGroupManager")
    log("PalGroupManager: %s", alive(gm) and "found" or "NOT FOUND")
    if alive(gm) then
        local map = try(function() return gm.GuildMap end)
        log("  GuildMap property: %s", map ~= nil and "readable" or "unreadable")
        if map ~= nil then
            local hasForEach = try(function() return type(map.ForEach) end) == "function"
            log("  GuildMap:ForEach available: %s", tostring(hasForEach))
        end
    end

    local mgr = getBaseCampManager()
    log("PalBaseCampManager: %s", alive(mgr) and "found" or "NOT FOUND")
    local allCamps = collectBaseCamps()
    log("live base camps found via FindAllOf: %d", #allCamps)
    for _, c in ipairs(allCamps) do log("  camp belongs to guild %s", tostring(c.group)) end

    local guilds = enumerateGuilds()
    log("guilds discovered: %d", #guilds)

    for _, guild in ipairs(guilds) do
        local allOffline, why = guildAllOffline(guild)
        log("guild '%s' id=%s solo=%s members=%d allOffline=%s%s",
            guild.name, guild.id, tostring(guild.solo), #guild.members,
            tostring(allOffline), why and (" (" .. why .. ")") or "")
        for _, m in ipairs(guild.members) do
            log("    member %-24s uid=%s status=%s", m.name, tostring(m.uid), str(m.status))
        end

        if alive(mgr) then
            local camps, pals, err = forEachGuildPal(guild, allCamps, function(param, label)
                log("    pal %s: %s", label, fmtSnapshot(palSnapshot(param)))
            end)
            log("    -> %d camp(s), %d worker pal(s)%s", camps, pals, err and (" ERR: " .. err) or "")
        end
    end

    -- Probe the game's own FName keys so ours provably cannot collide.
    local def = try(function() return StaticFindObject("/Script/Pal.Default__PalDefine") end)
    if alive(def) then
        for _, k in ipairs({ "DecreaseFullStomachRate_Work", "DecreaseFullStomachRate_WorkHard",
                             "DecreaseSanityRate_WorkHard" }) do
            log("PalDefine.%s = %s", k, str(firstOf(def, { k })))
        end
    else
        log("PalDefine CDO not found (our key '%s' cannot be collision-checked)", SUPPRESS_KEY)
    end

    -- Is there a cheat manager? Its presence turns multi-hour tests into seconds.
    local cheat = try(function() return FindFirstOf("PalCheatManager") end)
    log("PalCheatManager present: %s", alive(cheat) and "YES" or "no")

    log("---------- END RECON ----------")
end

--------------------------------------------------------------------------------
-- Optional one-variant-per-boot sanity probe
--------------------------------------------------------------------------------

local function probeWrites()
    local probe = CFG.probe_write
    if probe == nil then return end

    log("WRITE PROBE: '%s' on the FIRST pal found. ONE probe per server boot only --", probe)
    log("             a native access violation here cannot be caught by pcall.")

    if CFG.dry_run then
        log("WRITE PROBE skipped: dry_run is true. A probe has to actually write.")
        return
    end

    local allCamps = collectBaseCamps()
    if #allCamps == 0 then log("WRITE PROBE aborted: no base camps found"); return end

    local runners = {
        ufunction_flag = function(param) return sanityNaturalUpdate(param, true) end,
        nested_scalar  = function(param) return sanityTopUp(param) end,
        nested_tmap    = function(param) return sanityDisableFlags(param, true) end,
        nested_tarray  = function(param) return stopWork(param, true) end,
    }
    local runner = runners[probe]
    if runner == nil then
        log("WRITE PROBE: unknown probe_write value '%s'", tostring(probe))
        return
    end

    local done = false
    for _, guild in ipairs(enumerateGuilds()) do
        if done then break end
        forEachGuildPal(guild, allCamps, function(param, label)
            if done then return end
            done = true
            log("  target %s", label)
            log("  before: %s", fmtSnapshot(palSnapshot(param)))
            local r = runner(param)
            log("  probe '%s' result: %s", probe, r)
            log("  after:  %s", fmtSnapshot(palSnapshot(param)))
            log("  Now watch the value over time. A write that 'succeeds' but is")
            log("  reverted by SaveParameterMirror looks identical at this instant.")
        end)
    end
    if not done then log("WRITE PROBE: no worker pal found to test on") end
end

--------------------------------------------------------------------------------
-- Server settings guard
--
-- Two vanilla features can delete or hand away exactly what this mod preserves.
-- This mod makes long absences viable and therefore makes both far more likely
-- to bite. Warn loudly; never silently suppress them.
--------------------------------------------------------------------------------

local function checkServerSettings()
    if not CFG.check_server_settings then return end
    local candidates = {
        "Pal/Saved/Config/WindowsServer/PalWorldSettings.ini",
        "./Pal/Saved/Config/WindowsServer/PalWorldSettings.ini",
        "../../../Pal/Saved/Config/WindowsServer/PalWorldSettings.ini",
        "Pal/Saved/Config/LinuxServer/PalWorldSettings.ini",
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then
            local body = f:read("*a") or ""
            f:close()
            log("read server settings from %s", p)
            if body:find("bAutoResetGuildNoOnlinePlayers%s*=%s*[Tt]rue") then
                log("!! WARNING: bAutoResetGuildNoOnlinePlayers=True -- the server will DELETE an")
                log("!! offline guild's structures and base Pals regardless of how well fed they are.")
                log("!! This mod cannot prevent that. Set it to False.")
            end
            local stom = body:match("PalStomachDecreaceRate%s*=%s*([%d%.]+)")
            if stom then log("note: PalStomachDecreaceRate=%s (server-global hunger multiplier)", stom) end
            if body:find("AutoTransferMasterThresholdDays") then
                log("note: AutoTransferMasterThresholdDays present -- long absences may transfer guild leadership")
            end
            return
        end
    end
    log("could not locate PalWorldSettings.ini from the server's working directory (not fatal)")
end

--------------------------------------------------------------------------------
-- Scheduling -- chained one-shot delays. Never LoopAsync (Rule 4).
--------------------------------------------------------------------------------

local stopped = false

local function scheduleSweep()
    if stopped then return end
    ExecuteWithDelay(CFG.sweep_interval_ms or 30000, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(sweep)
            if not ok then log("sweep error: %s", tostring(err)) end
        end)
        scheduleSweep()
    end)
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

log("GuildStasis v%s loading", MOD_VERSION)
log("mode=%s dry_run=%s freeze_hunger=%s sanity_mode=%s grace=%ss sweep=%sms",
    tostring(CFG.mode), tostring(CFG.dry_run), tostring(CFG.freeze_hunger),
    tostring(CFG.sanity_mode), tostring(CFG.grace_seconds), tostring(CFG.sweep_interval_ms))

if CFG.mode ~= "run" then
    log("NOTE: mode is not \"run\" -- no game state will be modified.")
elseif CFG.dry_run then
    log("NOTE: dry_run is true -- decisions will be logged but nothing will be written.")
end

-- Un-suppress fast on login. This hook is runtime-verified to fire on a live 1.0
-- dedicated server. It is a nudge only: the sweep is the mechanism, so a missed
-- hook costs latency, never correctness.
local hooked = try(function()
    RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", function()
        ExecuteInGameThread(function()
            refreshOnlinePlayers()
            local ok, err = pcall(sweep)
            if not ok then log("login-triggered sweep error: %s", tostring(err)) end
        end)
    end)
    return true
end)
log("login hook (ServerAcknowledgePossession): %s", hooked and "registered" or "FAILED")

-- First pass is deferred: the world, group manager and base camps are not ready
-- at mod load on a dedicated server.
ExecuteWithDelay(20000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            checkServerSettings()
            recon()
            probeWrites()
        end)
        if not ok then log("startup pass error: %s", tostring(err)) end
    end)
    scheduleSweep()
end)

log("loaded. First recon pass in 20s, then sweeps every %sms.", tostring(CFG.sweep_interval_ms))
