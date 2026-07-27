# Changelog

## 0.2.0 - 2026-07-27

Stasis now means no production. While a guild is suppressed, every one of its base
Pals has its effective work speed set to zero, so an offline base generates nothing.

Before this, suppressed Pals kept hauling and crafting while never getting hungry,
so an offline base produced output with no upkeep -- better than being online, which
was backwards.

### Added

- `zero_work_speed` (default `true`). Inserts a `0.0` entry under the mod's own
  FName key into each Pal's `SaveParameter.CraftSpeedRates` -- the same container
  shape and the same "0.0 wins" rule as the existing hunger lever.
- `speed_zero` on the `HEARTBEAT` line, and `speed_zero` / `speed_nonzero` per guild
  in the status JSON. If `speed_zero` lags `pals_written`, the lever is not landing.
- `speed=` in every per-Pal log line, reporting `GetCraftSpeed_withBuff` -- the
  computed value. `GetCraftSpeed` is the base stat and does not move when the rate
  changes, so it would be the wrong thing to log.
- `LOGIN HOOK fired` / `LOGIN HOOK done` markers. A native access violation cannot
  be caught by pcall, so a crash inside the login sweep would otherwise be
  indistinguishable from a crash anywhere else.

### Verified on a live dedicated server

- suppress: computed speed `70 -> 0` and `77 -> 0`; hunger decay `2.0 -> 0.0`
- release: each Pal back to **its own** original speed, `70` and `77`
- restart: `CraftSpeedRates` entries gone entirely -- session state, like the hunger
  write, so nothing persists and no restore map is needed
- idempotent across sweeps: the first sweep appends one entry, later sweeps reuse it
  rather than growing the array
- per-guild isolation held throughout, `write_errors=0`
- observed in game: Pals walk to a station, play the work animation, and produce
  nothing

### Fixed

- The member holding the vanilla off-work list was guessed under three wrong names.
  It is `WorkSuitabilityOptionInfo`, so `stop_work_when_offline` could never have
  worked. That route is now superseded by `zero_work_speed` and stays off by default.

### Notes

- `stop_work_when_offline` is superseded. It writes to the save file and cannot
  restore itself. Do not enable both; the mod warns at startup if you do.
- Pals remain visually active while producing nothing. Making them stand still would
  mean rewriting per-Pal job configuration in the save, which risks silently
  destroying player settings.
- Two mechanisms were eliminated on evidence before this one: `CurrentOrderType` is a
  battle order that persists to the save, and Pal Box parking has no reflected
  mutator anywhere in the container chain. See `docs/V2-PLAN.md`.

## 0.1.0 — 2026-07-26

First release. Freezes hunger and SAN for a guild's base Pals while every member of that guild is offline, per-guild, server-side.

### Verified on a live dedicated server

App 2394010, build `24181105`, reporting `v1.0.1.100619`.

- UE4SS loads into `PalServer`, server-side Lua runs, `ServerAcknowledgePossession` hook registers and fires
- `UPalGroupManager.GuildMap` iterates from Lua; the map key is the guild FGuid and matches the `GuildID` reported by REST `game-data`
- Hunger: `SetDecreaseFullStomachRates(key, 0.0)` drives `GetFullStomachDecreasingRate()` from `1.0` to `0.0` — the rate container does not sum, so a zero entry is a hard stop
- SAN: `SetDisableNaturalUpdate(key, true)` held two Pals bit-identical for 4.5 minutes against a measured 2.0/min drain, with a player online and the Pals confirmed awake and working via `game-data`
- Both writes reverse on login within ~8s, confirmed by read-back
- Per-guild isolation proven in both directions: 2 Pals written for one guild, 1 for the other, never 3, with each camp written only while its own guild was offline
- Nothing written persists to the save — after save + restart the rate reads `1.0` and the flag is clear, so uninstalling leaves no trace
- Camps created mid-session are picked up correctly
- Zero Lua errors across ~130 write cycles

### Bugs found and fixed during live testing

Each of these was invisible to static analysis:

1. Guilds were silently dropped because their own id accessors return nothing — the id now comes from the `GuildMap` key, and an unidentifiable guild logs a warning instead of vanishing
2. `UPalBaseCampManager::TryGetModel()` yields nothing from Lua (out-param marshalling), which made the camp walk report `0 pal(s) in 0 camp(s)` while a camp existed — replaced with `FindAllOf("PalBaseCampModel")` plus an ownership match on `GetGroupIdBelongTo()`, which is also safer
3. The internal `firstOf` helper never called a single method, because it guarded on `type(obj[name]) == "function"` and UE4SS does not surface UFunctions as Lua function values — this masked working APIs as missing
4. Member-presence checks that relied on a non-nil result were unsound: UE4SS returns a wrapper for *any* name, proven with a negative control. Presence now requires extracting a real value

### Known limitations

- Suppressed Pals keep working, so an offline base keeps producing with no upkeep
- No overnight soak yet — the UE4SS timer-death class of bug appears after 40min–2h
- `SetDisableNaturalUpdate`'s full collateral scope is uncatalogued; exp and friendship are observed frozen, which is intended
- Windows dedicated servers only
- `stop_work_when_offline` is experimental and has no restore map — leave it off
