--------------------------------------------------------------------------------
-- v2 discovery probe, stage 2: dump the REAL member lists of the classes v2 needs.
--
-- READ ONLY. Writes nothing. Local test server only.
--
-- WHY THIS EXISTS, and why it supersedes name-guessing.
--
-- Stage 1 (v2-palbox.lua) proved guild.PalStorage resolves to a real object of
-- class PalGuildPalStorage -- and then failed to find a single one of its members,
-- because every candidate name was a guess: SlotArray, Slots, CharacterContainer,
-- Container, ContainerId all came back as TrivialObject phantoms. Guessing cannot
-- work here. The binary's ASCII strings don't help either: "PalGuildPalStorage"
-- appears nowhere in them, only "PalGuildPalStorageInfo".
--
-- UE4SS can simply be asked. UStruct exposes ForEachProperty and ForEachFunction,
-- so the actual reflected layout can be enumerated. That removes the phantom
-- problem from discovery altogether: a name that comes OUT of ForEachProperty is
-- real by construction, where a name we put IN can never be trusted.
--
-- If ForEachProperty is unavailable on this UE4SS build, this probe says so
-- clearly rather than printing an empty list and letting it read as "no members".
--
-- Targets, in priority order:
--   1. PalGuildPalStorage      -- the guild's Pal Box. Feature 1 depends on it
--   2. PalIndividualCharacterContainer -- both ends of the move. Look for a
--                                 transfer method here; it would avoid the
--                                 map-object module route entirely
--   3. PalBaseCampWorkerDirector -- the source side
--   4. the guild object        -- storage/raid members we haven't found
--   5. map object models       -- to locate the Pal Box structure and its
--                                 GetCharacterContainerModule()
--------------------------------------------------------------------------------

local TAG = "[V2DUMP] "
local function log(fmt, ...)
    local m = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    print(TAG .. m .. "\n")
end

local function try(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function alive(o)
    if o == nil then return false end
    return try(function() return o:IsValid() end) == true
end
local function full(o) return try(function() return o:GetFullName() end) end
local function isCDO(o)
    local n = full(o)
    return type(n) == "string" and n:find("Default__", 1, true) ~= nil
end

-- Same shape as main.lua's arrEach: ForEach first with :get() to unwrap, raw
-- indexing only as a fallback, because UE4SS exposes TArray inconsistently and
-- raw indexing is not reliably 1-based.
local function arrEachLocal(a, fn)
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
        return seen
    end
    local n = try(function() return a:GetArrayNum() end) or 0
    for i = 1, n do
        local v = try(function() return a[i] end)
        if v ~= nil then seen = seen + 1; fn(i, v) end
    end
    return seen
end

-- Get a readable name out of whatever ForEach* hands us. UE4SS is inconsistent
-- about wrapper shapes, so try the documented routes and report failure honestly.
local function nameOf(x)
    local n = try(function() return x:GetFName():ToString() end)
    if type(n) == "string" and n ~= "" then return n end
    n = try(function() return x:GetName() end)
    if type(n) == "string" and n ~= "" then return n end
    n = try(function() return x:GetFullName() end)
    if type(n) == "string" and n ~= "" then return n end
    return nil
end

-- The type of a property, which is what tells us whether a member is the array,
-- object or int we're looking for.
local function typeOf(p)
    local t = try(function() return p:GetClass():GetFName():ToString() end)
    if type(t) == "string" and t ~= "" then return t end
    t = try(function() return p:GetClass():GetName() end)
    if type(t) == "string" and t ~= "" then return t end
    return "?"
end

--------------------------------------------------------------------------------

-- ForEachProperty/ForEachFunction enumerate a class's OWN declared members only.
-- Proof from the first run of this probe: PalGroupGuild listed 9 properties and
-- PalStorage / GuildName / UnderRaidBaseCampIds were not among them, even though
-- all three read fine. They are declared on the superclass. So walking the chain
-- is not optional -- without it this probe hides exactly what it exists to find.
--
-- Second fix: "the call failed" and "the class has no own members" are different
-- facts, and conflating them is how a dead end gets mistaken for a finding. The
-- pcall result and whether the callback ever fired are now reported separately.
local function dumpOneLevel(cls, depth)
    local cname = nameOf(cls) or "?"
    local pad = string.rep("  ", depth)
    log("    %s[%d] %s", pad, depth, tostring(cname))

    local props, fired = {}, false
    local called = try(function()
        cls:ForEachProperty(function(p)
            fired = true
            props[#props + 1] = string.format("%s : %s", tostring(nameOf(p) or "<unnamed>"), typeOf(p))
        end)
        return true
    end)
    if called ~= true then
        log("    %s     PROPERTIES: ForEachProperty CALL FAILED -- says nothing about the class", pad)
    elseif not fired then
        log("    %s     PROPERTIES: none of its own (call succeeded, zero callbacks)", pad)
    else
        table.sort(props)
        log("    %s     PROPERTIES (%d own):", pad, #props)
        for i = 1, #props do log("    %s       %s", pad, props[i]) end
    end

    local fns, ffired = {}, false
    local fcalled = try(function()
        cls:ForEachFunction(function(f)
            ffired = true
            local n = nameOf(f)
            if n then fns[#fns + 1] = n end
        end)
        return true
    end)
    if fcalled ~= true then
        log("    %s     FUNCTIONS: ForEachFunction CALL FAILED -- says nothing about the class", pad)
    elseif not ffired then
        log("    %s     FUNCTIONS: none of its own (call succeeded, zero callbacks)", pad)
    else
        table.sort(fns)
        log("    %s     FUNCTIONS (%d own):", pad, #fns)
        for i = 1, #fns do log("    %s       %s", pad, fns[i]) end
    end
end

local function dumpStruct(cls, label)
    if not alive(cls) then log("  %s: class not valid", label); return end
    log("  class chain for %s:", label)
    local cur, depth = cls, 0
    while alive(cur) and depth < 8 do
        dumpOneLevel(cur, depth)
        local nm = nameOf(cur)
        -- Object is the root and has nothing we need; stop rather than dump it.
        if nm == "Object" then break end
        local super = try(function() return cur:GetSuperStruct() end)
        if not alive(super) then break end
        cur = super
        depth = depth + 1
    end
end

local function dumpObjectClass(obj, label)
    if not alive(obj) then log("  %s: no live object to dump", label); return end
    log("  --- %s", label)
    log("      instance: %s", tostring(full(obj)))
    local cls = try(function() return obj:GetClass() end)
    dumpStruct(cls, label)
end

--------------------------------------------------------------------------------

local function firstLive(className)
    local all = try(function() return FindAllOf(className) end)
    if all == nil then return nil end
    for i = 1, #all do
        local o = all[i]
        if alive(o) and not isCDO(o) then return o end
    end
    return nil
end

local function run()
    log("=== v2 class dump (READ ONLY) ===")

    -- 1 + 4. The guild, and the Pal Box hanging off it.
    local guild = firstLive("PalGroupGuild")
    if guild == nil then
        log("no live PalGroupGuild -- connect a player and make sure a guild exists")
    else
        dumpObjectClass(guild, "PalGroupGuild")
        local storage = try(function() return guild.PalStorage end)
        if alive(storage) then
            dumpObjectClass(storage, "PalGuildPalStorage (guild.PalStorage) -- THE TARGET")
        else
            log("  guild.PalStorage did not resolve this run, which contradicts stage 1")
        end
    end

    -- 3. The source side, and 2. the container at both ends.
    local camps = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    local wd, cc = nil, nil
    for i = 1, #camps do
        local m = camps[i]
        if alive(m) and not isCDO(m) then
            local d = try(function() return m.WorkerDirector end)
            if alive(d) then
                wd = d
                local c = try(function() return d.CharacterContainer end)
                if alive(c) then cc = c end
                break
            end
        end
    end
    dumpObjectClass(wd, "PalBaseCampWorkerDirector")
    dumpObjectClass(cc, "PalIndividualCharacterContainer -- look for a move/transfer fn")

    -- 5. The map object side. Stage 1 found ZERO live
    -- PalMapObjectCharacterContainerModule instances even though the class name is
    -- in the binary, so find out what map object classes actually exist and which
    -- of them exposes GetCharacterContainerModule.
    log("=== map object classes present ===")
    for _, cls in ipairs({
        "PalMapObjectConcreteModelBase",
        "PalMapObjectConcreteModel",
        "PalMapObjectModel",
        "PalMapObjectCharacterContainerModule",
        "PalMapObjectItemContainerModule",
        "PalMapObjectModule",
    }) do
        local all = try(function() return FindAllOf(cls) end)
        if all == nil then
            log("  %-46s class not found", cls)
        else
            local n = 0
            for i = 1, #all do if alive(all[i]) and not isCDO(all[i]) then n = n + 1 end end
            log("  %-46s %d live instance(s) (%d incl. CDOs)", cls, n, #all)
        end
    end

    local mo = firstLive("PalMapObjectConcreteModelBase") or firstLive("PalMapObjectConcreteModel")
    if mo ~= nil then
        dumpObjectClass(mo, "a map object concrete model")
    end

    -- The container manager owns every container in the world, which is the route
    -- to the Pal Box that does NOT depend on PalGuildPalStorage exposing anything.
    -- Stage 2 showed PalGuildPalStorage has no reflected members of its own and
    -- derives straight from Object, so it may be a dead end; this is the hedge.
    log("=== every character container in the world ===")
    local containers = try(function() return FindAllOf("PalIndividualCharacterContainer") end) or {}
    log("  %d PalIndividualCharacterContainer instance(s)", #containers)
    local shown = 0
    for i = 1, #containers do
        local c = containers[i]
        if alive(c) and not isCDO(c) then
            local slots = try(function() return c.SlotArray end)
            local n = try(function() return slots:GetArrayNum() end)
            local num = try(function() return c:Num() end)
            local empty = try(function() return c:FindEmptySlot() end)
            log("    [%d] slots=%s Num()=%s FindEmptySlot()=%s  %s",
                i, tostring(n), tostring(num), tostring(empty), tostring(full(c)))
            shown = shown + 1
            -- Enough to see the shape; a big base would otherwise flood the log.
            if shown >= 25 then log("    ... truncated at 25 of %d", #containers); break end
        end
    end

    for _, cls in ipairs({ "PalCharacterContainerManager", "PalContainerBase" }) do
        local o = firstLive(cls)
        if o ~= nil then dumpObjectClass(o, cls)
        else log("  %s: no live instance", cls) end
    end

    -- LAST SHOT AT PARKING. No mutator exists anywhere in the container chain, but
    -- FindEmptySlot() hands back a SLOT object, and the slot is what actually holds
    -- the handle. If the slot exposes a reflected setter, a move is still possible
    -- by writing handles between slots. If it does not, parking is dead from Lua and
    -- Feature 1 falls back to OffWorkSuitabilityList.
    log("=== slot and handle classes -- can a slot be written? ===")
    local anyContainer = firstLive("PalIndividualCharacterContainer")
    if alive(anyContainer) then
        local slot = try(function() return anyContainer:FindEmptySlot() end)
        if alive(slot) then
            dumpObjectClass(slot, "an empty slot from FindEmptySlot()")
        else
            log("  FindEmptySlot() gave nothing usable")
        end
        -- And an OCCUPIED slot, via SlotArray, since an empty one may be a
        -- different class or hide members that only matter when filled.
        local sa = try(function() return anyContainer.SlotArray end)
        local first = try(function() return sa:GetArrayNum() end)
        if type(first) == "number" and first > 0 then
            local s0 = try(function() return sa[1] end)
            local unwrapped = try(function() return s0:get() end) or s0
            if alive(unwrapped) then
                dumpObjectClass(unwrapped, "SlotArray[1]")
                local h = try(function() return unwrapped.Handle end)
                if alive(h) then dumpObjectClass(h, "that slot's Handle") end
            end
        end
    end

    -- A UFunction is itself a UStruct, so ForEachProperty on it yields its
    -- PARAMETERS. That is how we learn a signature without calling anything.
    log("=== signatures of the functions we do have ===")
    local WATCH = {
        OrderCommand = true, TryGetContainer = true, GetContainer = true,
        GetLocalSlot = true, FindEmptySlot = true, FindByHandle = true,
        Get = true, GetSlots = true, Num = true, IsEmpty = true,
        GetWorkerCapacityNum = true, IsWorkerCapacityLimited = true,
        OnBaseCampRaidStarted_ServerInternal = true,
        OnBaseCampRaidEnded_ServerInternal = true,
    }
    local function dumpSigs(obj, label)
        if not alive(obj) then return end
        local cls = try(function() return obj:GetClass() end)
        local cur, depth = cls, 0
        while alive(cur) and depth < 8 do
            local cn = nameOf(cur)
            try(function()
                cur:ForEachFunction(function(f)
                    local fname = nameOf(f)
                    if fname ~= nil and WATCH[fname] then
                        local params = {}
                        try(function()
                            f:ForEachProperty(function(p)
                                params[#params + 1] = string.format("%s : %s", tostring(nameOf(p)), typeOf(p))
                            end)
                            return true
                        end)
                        if #params == 0 then
                            log("  %s.%s()  -- no reflected params", tostring(cn), fname)
                        else
                            log("  %s.%s(", tostring(cn), fname)
                            for i = 1, #params do log("        %s", params[i]) end
                            log("      )")
                        end
                    end
                end)
                return true
            end)
            if cn == "Object" then break end
            local sup = try(function() return cur:GetSuperStruct() end)
            if not alive(sup) then break end
            cur = sup; depth = depth + 1
        end
    end
    dumpSigs(anyContainer, "container")
    dumpSigs(firstLive("PalCharacterContainerManager"), "container manager")
    dumpSigs(wd, "worker director")
    dumpSigs(guild, "guild")

    --------------------------------------------------------------------------
    -- Hunger audit, answering a specific question: party Pals appear not to be
    -- getting hungry. Is that this mod, vanilla, or a server setting?
    --
    -- PalStomachDecreaceRate is 1.000000 in the ini, so it is not a setting. The
    -- mod should only ever write to base-camp Pals of OFFLINE guilds, and never
    -- to a party container -- but "should" is not evidence, so read it.
    --
    -- What matters per Pal:
    --   decay 1.0 + flag false  -> untouched. Hunger is just slow (verified
    --                              earlier: hunger moves far slower than SAN)
    --   decay 0.0 or flag true  -> something suppressed it, and if that Pal is in
    --                              a 5-slot party container it is a real bug
    --------------------------------------------------------------------------
    log("=== hunger audit: every Pal in every container ===")
    log("  (5-slot containers are parties, 960-slot are Pal Boxes, small ones are camps)")
    for i = 1, #containers do
        local c = containers[i]
        if alive(c) and not isCDO(c) then
            local slots = try(function() return c.SlotArray end)
            local total = try(function() return slots:GetArrayNum() end) or 0
            local kind = (total == 960 and "PALBOX") or (total == 5 and "PARTY") or "CAMP"
            local reported = 0
            arrEachLocal(slots, function(si, slot)
                if reported >= 8 then return end
                if not alive(slot) then return end
                local handle = try(function() return slot.Handle end)
                if not alive(handle) then return end
                local a, b = try(function() return handle:TryGetIndividualParameter() end)
                local param = alive(a) and a or (alive(b) and b or nil)
                if not alive(param) then return end

                local stom = try(function() return param:GetFullStomach() end)
                local maxs = try(function() return param:GetMaxFullStomach() end)
                local rate = try(function() return param:GetFullStomachDecreasingRate() end)
                local dis  = try(function() return param:GetDisableNaturalUpdate() end)
                local flag = (rate == 0.0 or dis == true) and "  <== SUPPRESSED" or ""
                log("    [%s cont=%d slot=%d] stomach=%s/%s decayRate=%s disableNaturalUpdate=%s%s",
                    kind, i, si, tostring(stom), tostring(maxs), tostring(rate), tostring(dis), flag)
                reported = reported + 1
            end)
            if reported == 0 and kind ~= "PALBOX" then
                log("    [%s cont=%d] no occupied slots", kind, i)
            end
        end
    end

    log("=== done. Nothing was written. ===")
end

ExecuteWithDelay(35000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(run)
        if not ok then log("probe error: %s", tostring(err)) end
    end)
end)

log("loaded; read-only class dump runs in 35s")
