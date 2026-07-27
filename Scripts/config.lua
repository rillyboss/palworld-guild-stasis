-- GuildStasis -- configuration
--
-- Edit this file, then restart the dedicated server. Nothing here is hot-reloaded.
-- Every value is read once at mod load.

return {
    ----------------------------------------------------------------------------
    -- MODE
    ----------------------------------------------------------------------------
    -- "recon" = read-only. Enumerates guilds, base camps and pals and logs
    --           everything it can resolve. Writes NOTHING to the game.
    --           Run this first, on a throwaway server, and read UE4SS.log.
    -- "run"   = act on offline guilds (still gated by dry_run below).
    mode = "run",

    -- With dry_run = true the mod decides exactly what it would do and logs it,
    -- but performs no writes. Leave this on until recon looks correct.
    dry_run = false,

    ----------------------------------------------------------------------------
    -- TRIGGER
    ----------------------------------------------------------------------------
    -- Seconds after the LAST guild member logs out before suppression is armed.
    --
    -- Short is generally better here. The grace delay exists only to avoid
    -- churning suppression on brief disconnects and reconnects -- it is NOT an
    -- anti-exploit measure, because freezing hunger on an offline guild is the
    -- entire point of the mod, so arming it sooner is strictly closer to what you
    -- want. Every write is idempotent and reversed on login, so even needless
    -- churn is harmless.
    --
    -- Practical floor: suppression can only be applied on a sweep, so anything
    -- below sweep_interval_ms buys you nothing. With the default 30s sweep, 60
    -- means protection lands within about two sweeps of the last logout.
    --
    -- Set 0 to suppress at the first sweep after a guild goes offline.
    -- Changeable at runtime with 'stasis.grace <seconds>' (does not persist across
    -- a restart -- edit this file for that).
    grace_seconds = 60,

    -- Milliseconds between sweeps. Each sweep re-derives all state from live
    -- objects, so a longer interval only delays reaction, it never desyncs.
    -- FindAllOf scans the whole UObject array, so do not make this small.
    sweep_interval_ms = 30000,

    -- Milliseconds between refreshes of the cached PlayerController list.
    -- Used to cross-check the guild's own online/offline flags.
    controller_refresh_ms = 5000,

    ----------------------------------------------------------------------------
    -- WHAT TO SUPPRESS
    ----------------------------------------------------------------------------
    -- Freeze hunger by inserting a 0.0 multiplier under our own FName key.
    -- This is the highest-confidence lever: SetDecreaseFullStomachRates is a
    -- BlueprintCallable UFUNCTION and the game itself uses the same mechanism.
    freeze_hunger = true,

    -- Which sanity lever to use. Palworld ships NO reflected sanity setter, so
    -- this is the risky half. Run probe_write (below) on a throwaway server to
    -- find out which write shapes actually work on your build, then pin the
    -- winner here.
    --   "none"           -- do not touch sanity at all
    --   "disable_flags"  -- write AffectNaturalSanityDecreaseDisableFlags.Flags[key] = true
    --   "natural_update" -- param:SetDisableNaturalUpdate(key, true)   (blunt; freezes more)
    --   "topup"          -- periodically write SaveParameter.SanityValue = max  (sawtooth)
    sanity_mode = "natural_update",

    -- Only meaningful for sanity_mode = "topup". Top up when SAN falls below
    -- this fraction of max (0.0-1.0).
    topup_below_ratio = 0.9,

    -- On the offline transition, top sanity up ONCE even when sanity_mode is a
    -- pause mode. Without this, a guild that logs off with already-miserable
    -- pals stays miserable forever: a hunger-frozen pal never eats, so the
    -- eat-driven sanity recovery path never fires again.
    topup_once_on_offline = true,

    ----------------------------------------------------------------------------
    -- STOP WORK
    ----------------------------------------------------------------------------
    -- Set every suppressed pal's effective work speed to zero, so an offline base
    -- produces nothing. This is what makes stasis mean inert rather than just
    -- "well fed": without it, an offline guild keeps generating output with no
    -- upkeep, which is better than being online and backwards.
    --
    -- How it works: insert a 0.0 entry under our own FName key into the pal's
    -- SaveParameter.CraftSpeedRates -- the same container shape, and the same
    -- "0.0 wins" rule, as the hunger lever above. Verified on a live 1.0 server:
    -- computed craft speed went 70 -> 0, and the entry does NOT survive a restart.
    --
    -- Why it is safe to leave on: nothing persists to the save file. There is no
    -- restore map, no per-pal fingerprint, and no state on disk. A crash or a
    -- forced kill mid-suppression self-heals on the next boot, and uninstalling
    -- the mod leaves no trace. It also touches no player configuration.
    zero_work_speed = true,

    ----------------------------------------------------------------------------
    -- STOP WORK, the old route (superseded -- leave this off)
    ----------------------------------------------------------------------------
    -- Superseded by zero_work_speed above, which achieves the same goal without
    -- writing anything persistent. Kept only as a fallback in case a game patch
    -- breaks the CraftSpeedRates route.
    --
    -- Do not enable both. This one writes to the save file, its restore path is
    -- unimplemented, and its failure mode is silent loss of the player's per-pal
    -- job configuration.
    --
    -- Park the guild's pals by adding every work suitability to their vanilla
    -- off-work list while the guild is offline, then restoring it on login.
    --
    -- Why this is attractive: SAN only drains from hunger, starvation, hard work
    -- and bad bedding, while it REGENERATES passively whenever the stomach is
    -- above ~30%. Freeze hunger (stomach stays full) and stop work, and every
    -- drain source is gone while regen keeps running -- so SAN recovers on its
    -- own, with no sanity setter needed at all. That sidesteps the riskiest part
    -- of this whole mod.
    --
    -- Why it is OFF by default: restoring the player's ORIGINAL off-work list is
    -- the hard part. Pal instance IDs are not stable across server restarts, so
    -- a restore map has to be keyed on an anchor fingerprint and persisted to
    -- disk. That is not built yet. Enable this only on a throwaway server; if it
    -- goes wrong, players lose their per-pal work configuration.
    stop_work_when_offline = false,

    ----------------------------------------------------------------------------
    -- DIAGNOSTICS
    ----------------------------------------------------------------------------
    -- Probe ONE write capability on ONE pal and log the result. Use exactly one
    -- per server boot: a native access violation here cannot be caught by pcall,
    -- so mixing probes makes a crash impossible to attribute.
    --
    -- All four answer the same underlying question -- what can UE4SS Lua write on
    -- this build -- and between them they decide which of this mod's levers are
    -- available:
    --   "ufunction_flag" -- call SetDisableNaturalUpdate(key, true).  Lowest risk.
    --   "nested_scalar"  -- write SaveParameter.SanityValue = max
    --   "nested_tmap"    -- insert AffectNaturalSanityDecreaseDisableFlags.Flags[key]
    --   "nested_tarray"  -- append to the pal's OffWorkSuitabilityList
    probe_write = nil,

    -- TEST ONLY. Suppress EVERY guild regardless of whether anyone is online,
    -- ignoring the grace delay entirely.
    --
    -- Why this exists: the world is only simulated while at least one player is
    -- connected, so on a single-account test server there is no way to have your
    -- guild offline AND the base still ticking. This flag decouples the two so the
    -- suppression LEVERS can be proven with one account: stay online but far from
    -- your base (so decay is running), and let the mod suppress anyway. If the
    -- numbers stop moving, the lever works.
    --
    -- Never ship this enabled. It defeats the entire per-guild premise.
    force_suppress_for_testing = false,

    -- Log every resolved identifier at load, one line each, so a failure names
    -- itself instead of showing up later as a nil.
    verbose_resolve = true,

    -- Log per-pal detail during sweeps. Noisy on a big server.
    verbose_pals = false,

    -- Best-effort read of PalWorldSettings.ini to warn about server settings
    -- that will undo this mod's whole purpose (see README).
    check_server_settings = true,

    -- Optional status file for external tooling / dashboards. nil to disable.
    -- Rewritten atomically-ish (temp file + rename) on every sweep.
    status_file = nil,
}
