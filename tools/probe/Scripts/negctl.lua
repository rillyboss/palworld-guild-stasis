--------------------------------------------------------------------------------
-- Negative control for member-name probing.
--
-- The work-stop discovery pass reported names like SetStopWork / SetPause /
-- SetEnable as "present" purely because obj[name] returned a wrapper object.
-- That proves nothing unless a name we KNOW is fake behaves differently.
--
-- This asks: does UE4SS hand back a wrapper for arbitrary nonsense names too?
-- If yes, every one of those hits is an artifact and the per-camp order route has
-- no evidence behind it.
--------------------------------------------------------------------------------

local TAG = "[NEGCTL] "
local function log(fmt, ...)
    local m = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    print(TAG .. m .. "\n")
end
local function try(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function alive(o) if o == nil then return false end return try(function() return o:IsValid() end) == true end
local function full(o) return try(function() return o:GetFullName() end) or "?" end

-- Names that cannot possibly exist.
local FAKE = {
    "SetStopWorkXYZZY", "TotallyBogusMemberName", "Zzz_NotAThing_9animals",
    "GetPurpleElephantCount", "PleaseDoNotExist",
}

-- The names the discovery pass claimed were present.
local CLAIMED = {
    "SetStopWork", "IsStopWork", "Pause", "SetPause", "SetEnable",
    "SetOrderType", "SetCurrentOrderType", "RequestOrderType",
    "GetCurrentOrderType", "GetOrderType", "GetWorkerNum",
}

local function classify(obj, name)
    -- 1. does calling it yield a value?
    local called = try(function() return obj[name](obj) end)
    -- 2. what does the bare access give?
    local raw = try(function() return obj[name] end)
    local t = type(raw)
    local desc = "nil"
    if raw ~= nil then
        desc = t
        local s = try(function() return tostring(raw) end)
        if s then desc = desc .. "(" .. s .. ")" end
    end
    return called, desc
end

local function run()
    local wd = nil
    local camps = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    for i = 1, #camps do
        local m = camps[i]
        if alive(m) and not full(m):find("Default__", 1, true) then
            local d = try(function() return m.WorkerDirector end)
            if alive(d) then wd = d; break end
        end
    end
    if not alive(wd) then log("no WorkerDirector found; cannot run control"); return end

    log("target: %s", full(wd))
    log("---- FAKE names (must look identical to real ones if this is an artifact) ----")
    for _, n in ipairs(FAKE) do
        local c, d = classify(wd, n)
        log("  %-28s call=%-10s raw=%s", n, tostring(c), d)
    end
    log("---- CLAIMED names ----")
    for _, n in ipairs(CLAIMED) do
        local c, d = classify(wd, n)
        log("  %-28s call=%-10s raw=%s", n, tostring(c), d)
    end

    -- The one member that returned a real value: try writing it and see whether
    -- the engine accepts the change. 0 is the observed current value.
    log("---- CurrentOrderType write test ----")
    local before = try(function() return wd.CurrentOrderType end)
    log("  before = %s", tostring(before))
    for _, v in ipairs({ 1, 2, 3 }) do
        local ok = try(function() wd.CurrentOrderType = v; return true end)
        local after = try(function() return wd.CurrentOrderType end)
        log("  wrote %d -> accepted=%s reads=%s", v, tostring(ok), tostring(after))
    end
    -- put it back
    if before ~= nil then
        try(function() wd.CurrentOrderType = before; return true end)
        log("  restored = %s", tostring(try(function() return wd.CurrentOrderType end)))
    end
end

ExecuteWithDelay(30000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(run)
        if not ok then log("ERROR: %s", tostring(err)) end
    end)
end)

log("negative control loaded; runs in 30s")
