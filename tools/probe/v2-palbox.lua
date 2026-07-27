--------------------------------------------------------------------------------
-- v2 discovery probe: is the Pal Box parking route reachable from Lua?
--
-- READ ONLY. This probe writes NOTHING. Run it on a local test server anyway.
--
-- It replaces v2-ordertype.lua, which was deleted. That probe wrote values 1 and 2
-- to UPalBaseCampWorkerDirector.CurrentOrderType. A static read of the retail
-- binary then established that the enum is EPalMapBaseCampWorkerOrderType
-- { 0 Work, 1 BattleFighter, 2 BattleAllWorker } -- so those writes would have put
-- a base on a war footing, and current_order_type persists to the save. Its
-- "wrote 3, read back 3" result was a false positive: there is no enumerator 3,
-- UE stores the raw byte, and the readback only echoed the write.
--
-- What this probe is looking for instead (all read out of the binary's reflection
-- data, none of it yet runtime-confirmed -- that is this probe's job):
--
--   guild.PalStorage                     the guild's Pal Box
--   UPalMapObjectCharacterContainerModule::TryMoveCharacterToContainerFrom
--                                        a server-side move, not a _ToServer RPC
--   PalBoxPageNum / PalBoxSlotNumInPage  capacity, to check for room first
--   guild.UnderRaidBaseCampIds           which camps are under raid, per guild
--   camp RaidDetectModule .bIsUnderRaid  per-camp raid state
--
-- METHOD NOTE, and it is the whole point. On this build obj[name] returns a
-- TrivialObject wrapper for ANY string -- "PleaseDoNotExist" is indistinguishable
-- from a real member by a nil check. So every candidate here is judged only by
-- whether a REAL VALUE can be extracted from it, and every batch is run against
-- deliberately fake names as a control. If the control "passes", the test is
-- worthless and says so.
--------------------------------------------------------------------------------

local TAG = "[V2BOX] "
local function log(fmt, ...)
    local m = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    print(TAG .. m .. "\n")
end

local function try(fn) local ok, r = pcall(fn); if ok then return r end return nil end

-- Rule 1: never trust ~= nil. IsValid() is safe to call on a stale wrapper.
local function alive(o)
    if o == nil then return false end
    return try(function() return o:IsValid() end) == true
end

local function full(o) return try(function() return o:GetFullName() end) end
local function isCDO(o)
    local n = full(o)
    return type(n) == "string" and n:find("Default__", 1, true) ~= nil
end

local function arrCount(a)
    if a == nil then return nil end
    local n = try(function() return a:GetArrayNum() end)
    if type(n) == "number" then return n end
    n = try(function() return #a end)
    if type(n) == "number" then return n end
    return nil
end

-- Same shape as main.lua's arrEach, and for the same reason: UE4SS exposes TArray
-- inconsistently, ForEach yields a wrapper that needs :get(), and raw indexing is
-- not reliably 1-based. UnderRaidBaseCampIds is the M9 oracle, so a misread here
-- would answer the raid question wrongly.
local function arrEach(a, fn)
    if a == nil then return 0 end
    local seen = 0
    if try(function() return type(a.ForEach) end) == "function" then
        local completed = try(function()
            a:ForEach(function(i, el)
                local v = try(function() return el:get() end)
                if v == nil then v = el end
                seen = seen + 1
                fn(i, v)
            end)
            return true
        end)
        if completed then return seen end
        log("  WARN: TArray:ForEach failed after %d element(s); not falling through", seen)
        return seen
    end
    for i = 1, (arrCount(a) or 0) do
        local v = try(function() return a[i] end)
        if v ~= nil then seen = seen + 1; fn(i, v) end
    end
    return seen
end

local function guidStr(g)
    local a = try(function() return g.A end)
    if type(a) ~= "number" then return nil end
    return string.format("%08X-%08X-%08X-%08X",
        a & 0xFFFFFFFF, (try(function() return g.B end) or 0) & 0xFFFFFFFF,
        (try(function() return g.C end) or 0) & 0xFFFFFFFF, (try(function() return g.D end) or 0) & 0xFFFFFFFF)
end

--------------------------------------------------------------------------------
-- The only honest test of presence: extract something real.
--
-- For an object-valued member, GetFullName() is the discriminator, and it earns
-- its keep twice -- a phantom wrapper yields nothing, and a real one tells us the
-- ACTUAL class name, which is what we need to look up the next member.
--------------------------------------------------------------------------------

local function probeObject(owner, name)
    local v = try(function() return owner[name] end)
    if v == nil then return nil, "nil" end
    if not alive(v) then return nil, "wrapper, not IsValid" end
    local fn = full(v)
    if type(fn) ~= "string" or fn == "" then return nil, "IsValid but no GetFullName -- treat as phantom" end
    return v, fn
end

local function probeScalar(owner, name)
    local v = try(function() return owner[name] end)
    local t = type(v)
    if t == "number" or t == "boolean" then return v, t end
    return nil, t
end

local function probeArray(owner, name)
    local v = try(function() return owner[name] end)
    if v == nil then return nil, "nil" end
    local n = arrCount(v)
    if n == nil then return nil, "no numeric length -- phantom" end
    return v, string.format("array, %d element(s)", n)
end

-- Controls. If any of these "succeed", every result in the same batch is void.
local FAKE_OBJECT = "PleaseDoNotExistStorage"
local FAKE_SCALAR = "PleaseDoNotExistCount"
local FAKE_ARRAY  = "PleaseDoNotExistIdList"

local function controlBatch(owner, label)
    local _, o = probeObject(owner, FAKE_OBJECT)
    local _, s = probeScalar(owner, FAKE_SCALAR)
    local _, a = probeArray(owner, FAKE_ARRAY)
    local clean = (o ~= nil and o:find("phantom") ~= nil or o == "nil" or o:find("not IsValid") ~= nil)
                  and (s == "nil" or s == "userdata" or s == "table")
                  and (a == "nil" or a:find("phantom") ~= nil)
    log("  CONTROL on %s: object=%s scalar=%s array=%s  -> %s",
        label, tostring(o), tostring(s), tostring(a),
        clean and "clean, results below are meaningful" or "!! CONTROL LEAKED -- DISREGARD THIS BATCH !!")
    return clean
end

--------------------------------------------------------------------------------

local function findLive(className)
    local all = try(function() return FindAllOf(className) end)
    if all == nil then return {} end
    local out = {}
    for i = 1, #all do
        local o = all[i]
        if alive(o) and not isCDO(o) then out[#out + 1] = o end
    end
    return out
end

local function probeGameSettings()
    log("=== Pal Box capacity (UPalGameSetting) ===")
    -- The setting object is a singleton; try the common shapes without assuming.
    for _, cls in ipairs({ "PalGameSetting", "PalGameSettings" }) do
        local objs = try(function() return FindAllOf(cls) end)
        if objs ~= nil and #objs > 0 then
            for i = 1, #objs do
                local s = objs[i]
                if alive(s) then
                    local pages, pt = probeScalar(s, "PalBoxPageNum")
                    local slots, st = probeScalar(s, "PalBoxSlotNumInPage")
                    local sick,  kt = probeScalar(s, "PalBoxTimePeriodRecoverySick")
                    log("  %s [%s]  PalBoxPageNum=%s(%s) PalBoxSlotNumInPage=%s(%s) PalBoxTimePeriodRecoverySick=%s(%s)",
                        cls, tostring(full(s)),
                        tostring(pages), pt, tostring(slots), st, tostring(sick), kt)
                    if type(pages) == "number" and type(slots) == "number" then
                        log("  -> box capacity = %d slots", pages * slots)
                    end
                    controlBatch(s, cls)
                    return
                end
            end
        else
            log("  %s: class not found", cls)
        end
    end
end

local function probeGuilds()
    log("=== Guilds: PalStorage and raid state ===")
    local guilds = findLive("PalGroupGuild")
    log("  %d live guild object(s)", #guilds)
    if #guilds == 0 then
        log("  nothing to probe -- connect a player and create a guild first")
        return
    end

    for i = 1, #guilds do
        local g = guilds[i]
        local nm = try(function() return g.GuildName end)
        log("  --- guild %d/%d  GuildName=%s", i, #guilds, tostring(nm))

        -- The headline question: is the Pal Box reachable straight off the guild?
        local storage, sinfo = probeObject(g, "PalStorage")
        log("      PalStorage: %s", tostring(sinfo))

        -- The M9 oracle. An empty array is a real answer; a phantom is not.
        local raidIds, rinfo = probeArray(g, "UnderRaidBaseCampIds")
        log("      UnderRaidBaseCampIds: %s", tostring(rinfo))
        if raidIds ~= nil then
            local n = arrEach(raidIds, function(_, id)
                log("        under raid: camp %s", tostring(guidStr(id)))
            end)
            if n == 0 then log("        (no camps under raid right now)") end
        end

        -- The engine's own all-members-offline concept.
        local reset, rt = probeScalar(g, "bAllPlayerNotOnlineAndAlreadyReset")
        log("      bAllPlayerNotOnlineAndAlreadyReset: %s (%s)", tostring(reset), rt)

        controlBatch(g, "guild")

        -- If PalStorage resolved, walk it. We do not know its shape yet, so report
        -- what comes out rather than asserting a chain.
        if storage ~= nil then
            log("      walking PalStorage:")
            for _, n in ipairs({ "SlotArray", "Slots", "CharacterContainer", "Container", "ContainerId" }) do
                local asArr, ai = probeArray(storage, n)
                local asObj, oi = probeObject(storage, n)
                if asArr ~= nil then
                    log("        .%s -> %s", n, ai)
                elseif asObj ~= nil then
                    log("        .%s -> %s", n, oi)
                else
                    log("        .%s -> no real value (%s / %s)", n, tostring(ai), tostring(oi))
                end
            end
            controlBatch(storage, "PalStorage")
        end
    end
end

local function probeCamps()
    log("=== Base camps: containers, raid module, order type ===")
    local camps = findLive("PalBaseCampModel")
    log("  %d live base camp(s)", #camps)

    for i = 1, #camps do
        local m = camps[i]
        local grp = guidStr(try(function() return m:GetGroupIdBelongTo() end))
        log("  --- camp %d/%d  guild=%s", i, #camps, tostring(grp))

        -- Recorded for completeness only. NOT a lever: 0 Work, 1 BattleFighter,
        -- 2 BattleAllWorker. Never write it.
        local wd, wdi = probeObject(m, "WorkerDirector")
        if wd ~= nil then
            local ot, tt = probeScalar(wd, "CurrentOrderType")
            log("      WorkerDirector: %s", wdi)
            log("      CurrentOrderType=%s (%s)  [battle order, read only, do not write]", tostring(ot), tt)

            local cc, cci = probeObject(wd, "CharacterContainer")
            log("      CharacterContainer: %s", tostring(cci))
            if cc ~= nil then
                -- Rule 3: SlotArray, never GetSlots().
                local slots, si = probeArray(cc, "SlotArray")
                log("        SlotArray: %s", tostring(si))
                local cid, ci = probeScalar(cc, "ContainerId")
                if cid == nil then
                    local cidObj, cio = probeObject(cc, "ContainerId")
                    log("        ContainerId: %s", tostring(cidObj ~= nil and cio or ci))
                else
                    log("        ContainerId: %s", tostring(cid))
                end
                controlBatch(cc, "CharacterContainer")
            end
        else
            log("      WorkerDirector: %s", tostring(wdi))
        end
    end

    -- Per-camp raid state lives on a module, not the model.
    log("  --- raid detect modules")
    local mods = findLive("PalMapObjectRaidDetectModule")
    if #mods == 0 then
        -- Class name is a guess from the binary's "RaidDetectModule" string; try
        -- the generic module sweep before concluding anything.
        log("      PalMapObjectRaidDetectModule: class not found -- name is unconfirmed")
    end
    for i = 1, #mods do
        local md = mods[i]
        local under, ut = probeScalar(md, "bIsUnderRaid")
        log("      module %d: bIsUnderRaid=%s (%s)  %s", i, tostring(under), ut, tostring(full(md)))
    end
end

local function probeMover()
    log("=== The move function ===")
    -- We must NOT call it: it mutates persisted save data. So all we can
    -- establish read-only is whether a container module object exists at all.
    local mods = findLive("PalMapObjectCharacterContainerModule")
    log("  %d live PalMapObjectCharacterContainerModule instance(s)", #mods)
    if #mods > 0 then
        log("  first: %s", tostring(full(mods[1])))
        log("  TryMoveCharacterToContainerFrom cannot be proven read-only -- calling it")
        log("  moves save data. Prove it on a throwaway save, with a snapshot taken first.")
    else
        log("  class not found under that name. Nothing to build on until it resolves.")
    end
end

ExecuteWithDelay(30000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            log("=== v2 Pal Box probe (READ ONLY) ===")
            probeGameSettings()
            probeGuilds()
            probeCamps()
            probeMover()
            log("=== done. Nothing was written. ===")
        end)
        if not ok then log("probe error: %s", tostring(err)) end
    end)
end)

log("loaded; read-only probe runs in 30s (world and managers need time to come up)")
