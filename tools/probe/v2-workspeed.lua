--------------------------------------------------------------------------------
-- v2 probe: can we set a Pal's WORK SPEED to zero?
--
-- Local test server only. Set WRITE_VARIANT = "read" for a pure read-only pass.
--
-- WHY THIS IS THE MOST PROMISING LEVER FOUND
--
-- FPalIndividualCharacterSaveParameter holds three sibling FFloatContainers:
--
--     DecreaseFullStomachRates    <- v1 writes this, IN PRODUCTION, verified
--     AffectSanityRates
--     CraftSpeedRates             <- work speed
--
-- Two things are already established about the first one, on a live server:
--   1. SetDecreaseFullStomachRates(FName, 0.0) is a HARD STOP. The container does
--      not sum or average -- a 0.0 entry wins outright.
--   2. Its entries DO NOT PERSIST. After save + restart the rate read 1.0 again.
--      So it is session state despite living on the save parameter.
--
-- If CraftSpeedRates behaves like its sibling, then work-speed-zero needs no
-- restore map, no fingerprint, no disk persistence, and keeps v1's "nothing
-- persists to the save" guarantee. That is a far smaller blast radius than the
-- off-work list, which loses player config silently, or Pal Box parking, which
-- has no reflected mutator at all.
--
-- THE CATCH, and what this probe is for: the binary's setter list for
-- UPalIndividualCharacterParameter contains SetDecreaseFullStomachRates but NO
-- SetCraftSpeedRates. So this likely needs a NESTED write into the container
-- rather than a clean UFunction call, and nested container writes are unproven on
-- this build. config.lua's probe_write = "nested_tmap" was designed for exactly
-- this question and has never been run.
--
-- ONE WRITE VARIANT PER BOOT. A native access violation from a nested write
-- cannot be caught by pcall, so mixing variants makes a crash impossible to
-- attribute. That is why this is a switch and not a loop.
--------------------------------------------------------------------------------

-- "read"    -- enumerate only. Writes nothing.
-- "mutate"  -- the decisive test. Two phases:
--             1. LEARN, using only the production-proven UFunction
--                SetDecreaseFullStomachRates: add an entry to the HUNGER container,
--                dump it, remove it. That reveals exactly what a game-created
--                FloatContainer_FloatPair looks like, with no risk.
--             2. Set the existing CraftSpeedRates entry's value to 0.0 and read
--                craft speed back. This is the only nested write in the boot, which
--                keeps a native access violation attributable.
local WRITE_VARIANT = "mutate"

-- Round-tripped on the hunger container during the learn phase, then removed.
local PROBE_KEY = "GuildStasis_Probe"

local OUR_KEY = "GuildStasis_Offline"

local TAG = "[V2SPEED] "
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
local function nameOf(x)
    local n = try(function() return x:GetFName():ToString() end)
    if type(n) == "string" and n ~= "" then return n end
    return try(function() return x:GetName() end)
end
local function typeOf(p)
    return try(function() return p:GetClass():GetFName():ToString() end) or "?"
end

--------------------------------------------------------------------------------
-- Struct layouts. A UScriptStruct is a UStruct, so ForEachProperty enumerates its
-- fields -- and StaticFindObject reaches the struct type by path without needing
-- an instance. This is how we learn a struct's real members instead of guessing,
-- which is what broke the off-work list route (main.lua guesses three names for
-- WorkSuitabilityOptionInfo and all three are wrong).
--------------------------------------------------------------------------------
-- Returns the plain list of field NAMES as well as logging, so callers can read
-- an element's fields by discovered name instead of guessing at them.
local function dumpStructType(path, quiet)
    local s = try(function() return StaticFindObject(path) end)
    if not alive(s) then if not quiet then log("  %s -- not found", path) end return nil, {} end
    local fields, names, fired = {}, {}, false
    local called = try(function()
        s:ForEachProperty(function(p)
            fired = true
            local n = tostring(nameOf(p))
            names[#names + 1] = n
            fields[#fields + 1] = string.format("%s : %s", n, typeOf(p))
        end)
        return true
    end)
    if not quiet then
        if called ~= true then
            log("  %s -- ForEachProperty CALL FAILED (says nothing about the struct)", path)
        elseif not fired then
            log("  %s -- zero fields (call succeeded)", path)
        else
            table.sort(fields)
            log("  %s -- %d field(s):", path, #fields)
            for i = 1, #fields do log("      %s", fields[i]) end
        end
    end
    return s, names
end

-- Field names of FFloatContainer_FloatPair, discovered rather than assumed.
local PAIR_FIELDS = {}

-- Dump every entry of an FFloatContainer, reading each element's fields by the
-- names we discovered. This is what tells us the shape of an entry the GAME made.
local function dumpContainer(container, label)
    if container == nil then log("    %s: nil", label); return 0 end
    local values = try(function() return container.Values end)
    if values == nil then log("    %s: no .Values", label); return 0 end
    local n = try(function() return values:GetArrayNum() end)
    if type(n) ~= "number" then log("    %s: .Values has no numeric length", label); return 0 end
    log("    %s: %d entry(s)", label, n)
    for i = 1, n do
        local raw = try(function() return values[i] end)
        local el = try(function() return raw:get() end) or raw
        if el ~= nil then
            local parts = {}
            for _, f in ipairs(PAIR_FIELDS) do
                local v = try(function() return el[f] end)
                parts[#parts + 1] = string.format("%s=%s", f, tostring(v))
            end
            log("      [%d] %s", i, (#parts > 0 and table.concat(parts, " ") or "<no readable fields>"))
        else
            log("      [%d] <unreadable>", i)
        end
    end
    return n
end

--------------------------------------------------------------------------------

local function findWorkerPal()
    local camps = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    for i = 1, #camps do
        local m = camps[i]
        if alive(m) and not isCDO(m) then
            local wd = try(function() return m.WorkerDirector end)
            if alive(wd) then
                local cc = try(function() return wd.CharacterContainer end)
                local slots = alive(cc) and try(function() return cc.SlotArray end) or nil
                local n = slots and (try(function() return slots:GetArrayNum() end) or 0) or 0
                for si = 1, n do
                    local slot = try(function() return slots[si] end)
                    local sl = try(function() return slot:get() end) or slot
                    if alive(sl) then
                        local h = try(function() return sl.Handle end)
                        if alive(h) then
                            local a, b = try(function() return h:TryGetIndividualParameter() end)
                            local param = alive(a) and a or (alive(b) and b or nil)
                            if alive(param) then return param, si end
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

-- Read craft speed every way the class offers, because we do not yet know which
-- getter reflects a rate-container entry. A lever is only proven if a READ changes.
local function readSpeeds(param, label)
    local out = {}
    for _, fn in ipairs({
        "GetCraftSpeed", "GetCraftSpeed_withBuff", "GetCraftSpeedBuffRate",
        "GetBaseCampCraftSpeedBuffRate", "GetCraftSpeedSickRate", "GetWorkSpeedRank",
    }) do
        local v = try(function() return param[fn](param) end)
        if type(v) == "number" then out[#out + 1] = string.format("%s=%s", fn, tostring(v)) end
    end
    -- Suitability-specific getters need an argument; 5 = Handcraft, a job almost
    -- every base Pal has some rank in.
    for _, fn in ipairs({ "GetCraftSpeedByWorkSuitability", "GetCraftSpeed_WorkSuitability" }) do
        local v = try(function() return param[fn](param, 5) end)
        if type(v) == "number" then out[#out + 1] = string.format("%s(Handcraft)=%s", fn, tostring(v)) end
    end
    local sleeping = try(function() return param:IsSleeping(param) end)
    log("  SPEEDS %-9s %s  IsSleeping=%s", label,
        (#out > 0 and table.concat(out, " ") or "<no numeric getter answered>"), tostring(sleeping))
    return table.concat(out, " ")
end

local function listRateSetters(param)
    local cls = try(function() return param:GetClass() end)
    if not alive(cls) then return end
    log("  setters/getters mentioning CraftSpeed or Rates on the parameter class:")
    local found = 0
    local cur, depth = cls, 0
    while alive(cur) and depth < 6 do
        try(function()
            cur:ForEachFunction(function(f)
                local n = nameOf(f)
                if n and (n:find("CraftSpeed") or n:find("Rates")) then
                    local params = {}
                    try(function()
                        f:ForEachProperty(function(p)
                            params[#params + 1] = string.format("%s : %s", tostring(nameOf(p)), typeOf(p))
                        end)
                        return true
                    end)
                    log("      %s.%s(%s)", tostring(nameOf(cur)), n,
                        (#params > 0 and (" " .. table.concat(params, ", ") .. " ") or ""))
                    found = found + 1
                end
            end)
            return true
        end)
        if nameOf(cur) == "Object" then break end
        local sup = try(function() return cur:GetSuperStruct() end)
        if not alive(sup) then break end
        cur = sup; depth = depth + 1
    end
    if found == 0 then
        log("      NONE. So there is no SetCraftSpeedRates UFunction and a nested")
        log("      write is the only route -- run WRITE_VARIANT = \"tmap\".")
    end
end

--------------------------------------------------------------------------------

local function run()
    log("=== v2 work-speed probe (variant: %s) ===", WRITE_VARIANT)

    log("--- struct layouts")
    dumpStructType("/Script/Pal.PalIndividualCharacterSaveParameter")
    dumpStructType("/Script/Pal.FloatContainer")
    local _, pf = dumpStructType("/Script/Pal.FloatContainer_FloatPair")
    PAIR_FIELDS = pf or {}
    dumpStructType("/Script/Pal.PalWorkSuitabilityOptionInfo")
    dumpStructType("/Script/Pal.PalWorkSuitabilityInfo")

    local param, si = findWorkerPal()
    if not alive(param) then
        log("no base camp worker Pal found -- need a camp with at least one Pal")
        return
    end
    log("--- target: a base camp worker Pal (slot %s)", tostring(si))

    listRateSetters(param)

    local sp = try(function() return param.SaveParameter end)
    if sp == nil then log("SaveParameter unreadable -- stopping"); return end

    -- Prove the container is real by getting a value out of it, never by a nil
    -- check: obj[name] hands back a phantom wrapper for any string on this build.
    local csr = try(function() return sp.CraftSpeedRates end)
    local dfs = try(function() return sp.DecreaseFullStomachRates end)
    log("  container contents as they stand:")
    dumpContainer(dfs, "DecreaseFullStomachRates (v1 writes this)")
    dumpContainer(csr, "CraftSpeedRates (the candidate)")
    -- The off-work list, via the CORRECT member name this time.
    local wsoi = try(function() return sp.WorkSuitabilityOptionInfo end)
    if wsoi ~= nil then
        local lst = try(function() return wsoi.OffWorkSuitabilityList end)
        local n = lst ~= nil and (try(function() return lst:GetArrayNum() end)
                                  or try(function() return #lst end)) or nil
        log("  sp.WorkSuitabilityOptionInfo.OffWorkSuitabilityList -> %s",
            type(n) == "number" and string.format("real array, %d entry(s)", n)
                                 or "no numeric length (phantom)")
    else
        log("  sp.WorkSuitabilityOptionInfo -> nil")
    end

    readSpeeds(param, "BEFORE")

    if WRITE_VARIANT == "read" then
        log("=== read-only pass complete. Nothing written. ===")
        return
    end

    if WRITE_VARIANT ~= "mutate" then
        log("unknown WRITE_VARIANT %q -- stopping without writing", tostring(WRITE_VARIANT))
        return
    end

    ----------------------------------------------------------------------------
    -- PHASE 1: LEARN, at zero risk.
    --
    -- SetDecreaseFullStomachRates is what v1 runs in production, so calling it is
    -- not a new risk. Adding then removing an entry shows us exactly what a
    -- game-created FloatContainer_FloatPair looks like, which is what we need in
    -- order to recognise, and eventually replicate, an entry in the craft-speed
    -- container.
    ----------------------------------------------------------------------------
    log("--- PHASE 1: learn the entry shape via the proven hunger setter")
    local rateBefore = try(function() return param:GetFullStomachDecreasingRate() end)
    -- FName(), NOT a bare Lua string. The parameter is a NameProperty, and passing
    -- a string makes UE4SS read an FName out of it and dereference null at offset
    -- 0x70. That is an access violation pcall CANNOT catch, so it takes the whole
    -- server down. It crashed this probe three times before being spotted, and
    -- main.lua has always done it correctly -- compare freezeHunger().
    local added = try(function() param:SetDecreaseFullStomachRates(FName(PROBE_KEY), 0.5); return true end)
    log("    SetDecreaseFullStomachRates(FName(%q), 0.5) returned=%s", PROBE_KEY, tostring(added))
    dumpContainer(try(function() return sp.DecreaseFullStomachRates end), "hunger container WITH our entry")
    local rateAfter = try(function() return param:GetFullStomachDecreasingRate() end)
    log("    decreasing rate %s -> %s", tostring(rateBefore), tostring(rateAfter))
    try(function() param:RemoveDecreaseFullStomachRates(FName(PROBE_KEY)); return true end)
    dumpContainer(try(function() return sp.DecreaseFullStomachRates end), "hunger container AFTER removal")
    log("    rate restored to %s", tostring(try(function() return param:GetFullStomachDecreasingRate() end)))

    ----------------------------------------------------------------------------
    -- PHASE 2: the actual question. Set the existing craft-speed entry to 0.0.
    --
    -- Mutating an existing entry rather than appending one, because appending a
    -- struct element to a TArray from Lua is a separate problem, and it is not
    -- worth solving until we know the container gates work speed at all. If craft
    -- speed does not move, the whole idea is dead and no append work is wasted.
    ----------------------------------------------------------------------------
    log("--- PHASE 2: set the existing CraftSpeedRates entry to 0.0")
    if csr == nil then log("    no craft-speed container -- stopping"); return end
    local values = try(function() return csr.Values end)
    local n = try(function() return values:GetArrayNum() end)
    log("    CraftSpeedRates.Values currently has %s entry(s)", tostring(n))

    -- The container is usually EMPTY, because entries only exist while something is
    -- applying a rate. So the normal case needs an APPEND, not a mutate. The layout
    -- is known from the struct dump: FloatContainer_FloatPair { Key : Name, Value : Float }.
    -- main.lua already uses the index-past-end idiom for a TArray, so try that with a
    -- Lua table for the struct, then fall back to slot 1.
    if type(n) ~= "number" or n < 1 then
        log("    empty -- attempting APPEND of { Key=FName(%s), Value=0.0 }", OUR_KEY)
        local appended = false
        for _, idx in ipairs({ (type(n) == "number" and n + 1 or 1), 1 }) do
            local ok = try(function()
                values[idx] = { Key = FName(OUR_KEY), Value = 0.0 }
                return true
            end)
            local nowN = try(function() return values:GetArrayNum() end)
            log("      write at index %d -> accepted=%s, length now %s", idx, tostring(ok), tostring(nowN))
            if ok == true and type(nowN) == "number" and nowN > 0 then appended = true; break end
        end
        dumpContainer(csr, "CraftSpeedRates after append attempt")
        readSpeeds(param, "AFTER")
        if not appended then
            log("--- verdict: append did not land. Without a SetCraftSpeedRates UFunction")
            log("    this route needs a way to grow the array that Lua does not offer here.")
        else
            log("--- verdict: compare AFTER against BEFORE. Unchanged speeds mean the")
            log("    container does not gate work speed, and the route is dead.")
        end
        return
    end

    -- Find the float field to write, and remember the original so we can put it back.
    local raw = try(function() return values[1] end)
    local el = try(function() return raw:get() end) or raw
    local floatField, original = nil, nil
    for _, f in ipairs(PAIR_FIELDS) do
        local v = try(function() return el[f] end)
        if type(v) == "number" then floatField, original = f, v; break end
    end
    if floatField == nil then
        log("    could not find a numeric field on the entry -- stopping")
        return
    end
    log("    entry field %q currently %s", floatField, tostring(original))

    local wrote = try(function() el[floatField] = 0.0; return true end) == true
    local readback = try(function() return el[floatField] end)
    log("    wrote 0.0 -> accepted=%s readback=%s", tostring(wrote), tostring(readback))

    -- The only thing that matters. A write that "succeeded" but moves no read is a
    -- false positive, and this project has been burned by several.
    readSpeeds(param, "AFTER")
    log("--- verdict: if the AFTER speeds match BEFORE, CraftSpeedRates does NOT")
    log("    gate work speed and this route is dead. If they dropped, it does.")

    -- Always put it back. These entries are session state, so even a failure here
    -- self-heals on restart, but do not rely on that.
    if wrote then
        local back = try(function() el[floatField] = original; return true end) == true
        log("--- restored %q to %s (ok=%s)", floatField, tostring(original), tostring(back))
        readSpeeds(param, "RESTORED")
    end

    log("=== done ===")
end

ExecuteWithDelay(40000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(run)
        if not ok then log("probe error: %s", tostring(err)) end
    end)
end)

log("loaded; work-speed probe runs in 40s (variant: " .. WRITE_VARIANT .. ")")
