--------------------------------------------------------------------------------
-- v2 discovery probe: what does UPalBaseCampWorkerDirector.CurrentOrderType mean?
--
-- THROWAWAY. Local test server only. Never production.
--
-- Why: v2 needs to stop an offline guild's Pals working, and CurrentOrderType is
-- the only real lever found. A negative control proved that SetStopWork, SetPause,
-- SetEnable, SetOrderType and RequestOrderType are all PHANTOMS -- UE4SS returns a
-- TrivialObject wrapper for arbitrary names, and "PleaseDoNotExist" looked
-- identical to them. CurrentOrderType is genuinely readable and writable (0 default;
-- 1, 2 and 3 all accepted and read back), but its enum meaning is unknown.
--
-- WARNING: unlike everything v1 writes, current_order_type is a SAVE FIELD. It can
-- outlive a restart. This probe restores the original value at the end and on
-- uninstall, but if the server is killed mid-cycle a non-default value may persist.
-- That is exactly why this must not run on a live server.
--
-- Method: dwell on each value for DWELL_MS, logging a timestamped marker. Observe
-- the Pals' behaviour EXTERNALLY with tools/palworld-ordertype-watch.ps1, which
-- reads AI_Action from GET /v1/api/game-data. Splitting mutation from observation
-- keeps the evidence independent of this probe's own assumptions.
--------------------------------------------------------------------------------

local TAG = "[V2ORDER] "
local function log(fmt, ...)
    local m = (select("#", ...) > 0) and string.format(fmt, ...) or fmt
    print(TAG .. m .. "\n")
end
local function try(fn) local ok, r = pcall(fn); if ok then return r end return nil end
local function alive(o) if o == nil then return false end return try(function() return o:IsValid() end) == true end
local function full(o) return try(function() return o:GetFullName() end) or "?" end

local function guidStr(g)
    local a = try(function() return g.A end)
    if type(a) ~= "number" then return nil end
    return string.format("%08X%08X%08X%08X",
        a & 0xFFFFFFFF, (try(function() return g.B end) or 0) & 0xFFFFFFFF,
        (try(function() return g.C end) or 0) & 0xFFFFFFFF, (try(function() return g.D end) or 0) & 0xFFFFFFFF)
end

local VALUES   = { 0, 1, 2, 3 }
local DWELL_MS = 90000     -- long enough for work AI to visibly settle
local idx      = 0
local original = nil
local target   = nil       -- the ONE worker director we touch

-- Pick a single camp so any behaviour change is unambiguous, and remember which.
local function pickTarget()
    local camps = try(function() return FindAllOf("PalBaseCampModel") end) or {}
    for i = 1, #camps do
        local m = camps[i]
        if alive(m) and not full(m):find("Default__", 1, true) then
            local wd = try(function() return m.WorkerDirector end)
            if alive(wd) then
                local grp = guidStr(try(function() return m:GetGroupIdBelongTo() end))
                local cur = try(function() return wd.CurrentOrderType end)
                if type(cur) == "number" then
                    log("target camp: guild=%s  CurrentOrderType=%d", tostring(grp), cur)
                    return wd, cur, grp
                else
                    log("camp guild=%s has no readable CurrentOrderType -- skipping", tostring(grp))
                end
            end
        end
    end
    return nil, nil, nil
end

local function setOrder(v)
    if not alive(target) then log("target director no longer valid; aborting"); return false end
    local ok = try(function() target.CurrentOrderType = v; return true end)
    local back = try(function() return target.CurrentOrderType end)
    log("ORDERTYPE set=%d accepted=%s readback=%s", v, tostring(ok), tostring(back))
    return (back == v)
end

local function restore()
    if original ~= nil and alive(target) then
        try(function() target.CurrentOrderType = original; return true end)
        log("restored CurrentOrderType=%s (readback=%s)", tostring(original),
            tostring(try(function() return target.CurrentOrderType end)))
    end
end

local function step()
    idx = idx + 1
    if idx > #VALUES then
        restore()
        log("cycle complete. Correlate these markers with AI_Action from the watcher.")
        return
    end
    local v = VALUES[idx]
    log("---- dwell %d/%d : CurrentOrderType -> %d (holding %ds) ----", idx, #VALUES, v, DWELL_MS / 1000)
    setOrder(v)
    ExecuteWithDelay(DWELL_MS, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(step)
            if not ok then log("step error: %s", tostring(err)); restore() end
        end)
    end)
end

ExecuteWithDelay(30000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            log("=== v2 CurrentOrderType probe starting (LOCAL TEST ONLY) ===")
            local wd, cur, grp = pickTarget()
            if not alive(wd) then log("no usable worker director found; nothing to probe"); return end
            target, original = wd, cur
            log("original CurrentOrderType=%s for guild %s -- will be restored", tostring(original), tostring(grp))
            step()
        end)
        if not ok then log("startup error: %s", tostring(err)) end
    end)
end)

log("loaded; probe begins in 30s, dwelling 90s per value across 0,1,2,3")
