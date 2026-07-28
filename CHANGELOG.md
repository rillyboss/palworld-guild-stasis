# Changelog

## 0.3.0 - 2026-07-28

Two latency fixes and two changed defaults. No new mechanism: 0.2.0's work-speed freeze is
unchanged and still the thing doing the work.

### Fixed

- **Suppression took up to two sweep intervals, not one.** The sweep that notices a guild
  has gone offline cannot suppress it, because at that instant the guild has been offline
  for zero seconds and the grace check fails. Suppression therefore landed on the *next*
  sweep, making the worst case `sweep_interval * 2`. The noticing sweep now schedules one
  follow-up at the grace deadline, so the worst case is `sweep_interval + grace_seconds`.
  Measured on a live six-guild server: all six suppressed 16s after going offline, where
  the old path would have waited a further minute with 100 Pals still working.
- **Release after login waited for the next scheduled sweep.** The hook fires on
  possession, but the guild's own status flag flips to `Online` slightly after, so the
  sweep inside the hook still saw the player as offline and did nothing. Observed in game
  as 10 to 15 seconds of idle Pals. The hook now queues follow-up sweeps at 2, 5, 10 and
  20 seconds. An earlier note in `docs/RESEARCH.md` claiming release happened "~8s after
  login" was a favourable race and has been corrected.

### Changed

- `sweep_interval_ms` default is now `60000`, up from `30000`. A sweep costs one
  `FindAllOf` over the whole UObject array plus a read-write-verify per suppressed Pal,
  roughly 300 reflected writes on a 100-Pal server. Neither latency now depends much on
  this value, so the interval is close to free to raise.
- `topup_once_on_offline` default is now `false`. Freezing SAN stops absence being
  punished; refilling it rewards absence, which is not this mod's job. A guild returns to
  exactly the SAN it left with. The old comment claiming Pals would otherwise "stay
  miserable forever" was wrong twice over: SAN is frozen so it does not fall, only fails to
  recover, and the freeze lifts the moment anyone logs in.

### Added

- `lvl=` and `exp=` in per-Pal log lines, which is how the XP question below was settled.

### Verified on a live dedicated server

- **Work speed zero covers every job, not just crafting.** All thirteen suitabilities read
  a final speed of `0` on a suppressed Pal, including the three the test Pal had ranks in
  (Handcraft 50, Transport 2, MonsterFarm 12). The base-value getters do not move, which
  looked alarming until the `_withBuff_` variants were checked.
- **The game keeps its own entry in the same container**, `CraftSpeedRates: [Sick=1.0,
  GuildStasis_Offline=0.0]`, so this is Palworld's native work-speed mechanism and the
  mod's namespaced key composes with it rather than fighting it.
- Running in production on six guilds, 11 camps, 112 Pals, `write_errors=0`, with
  `speed_zero` matching `pals_written` on every sweep.
- New Pals are picked up automatically. Pal count went 100 to 112 between sessions as
  players bred and caught more, and all of them were suppressed without intervention.

### Still unverified

- No overnight soak. Longest clean run observed is 71 minutes across 72 sweeps at a steady
  59.4s cadence, which is past the 40 minute mark where UE4SS's timer-death bug starts to
  appear but short of the 2 hour outer bound. Since 0.2.0 a dead timer leaves suppressed
  Pals frozen at zero work speed until a restart, which is visible to players where the
  old failure mode was silent. The heartbeat is the early warning.
- The full collateral scope of `SetDisableNaturalUpdate` is still uncatalogued.

### Notes

- The mod does not cure sickness and does not restore SAN, by decision. It cannot make a
  Pal sick while a guild is offline, since both starvation and overwork are off, but a Pal
  that was already sick stays sick for the offline window. Medicine or the Pal Box fixes
  that, both vanilla.
- Raids are not addressed, on the view that they do not fire against a guild with nobody
  online. That is a judgement call rather than something proven here, and
  `docs/V2-PLAN.md` records the cheap way to test it.

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
  nothing, then give up and fall asleep in daylight
- **no XP either**, measured against a positive control: over ten minutes two working
  Pals in an online guild each gained 96 XP and a level, while a suppressed Pal gained
  exactly zero. Its stomach also read `71.698272705078` at both ends of the window,
  and its SAN held at 100.0 while the working control's fell from 98.2 to 79.4

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

## 0.1.0 - 2026-07-26

First release. Freezes hunger and SAN for a guild's base Pals while every member of that guild is offline, per-guild, server-side.

### Verified on a live dedicated server

App 2394010, build `24181105`, reporting `v1.0.1.100619`.

- UE4SS loads into `PalServer`, server-side Lua runs, `ServerAcknowledgePossession` hook registers and fires
- `UPalGroupManager.GuildMap` iterates from Lua; the map key is the guild FGuid and matches the `GuildID` reported by REST `game-data`
- Hunger: `SetDecreaseFullStomachRates(key, 0.0)` drives `GetFullStomachDecreasingRate()` from `1.0` to `0.0`. The rate container does not sum, so a zero entry is a hard stop
- SAN: `SetDisableNaturalUpdate(key, true)` held two Pals bit-identical for 4.5 minutes against a measured 2.0/min drain, with a player online and the Pals confirmed awake and working via `game-data`
- Both writes reverse on login within ~8s, confirmed by read-back
- Per-guild isolation proven in both directions: 2 Pals written for one guild, 1 for the other, never 3, with each camp written only while its own guild was offline
- Nothing written persists to the save. After save + restart the rate reads `1.0` and the flag is clear, so uninstalling leaves no trace
- Camps created mid-session are picked up correctly
- Zero Lua errors across ~130 write cycles

### Bugs found and fixed during live testing

Each of these was invisible to static analysis:

1. Guilds were silently dropped because their own id accessors return nothing. The id now comes from the `GuildMap` key, and an unidentifiable guild logs a warning instead of vanishing
2. `UPalBaseCampManager::TryGetModel()` yields nothing from Lua (out-param marshalling), which made the camp walk report `0 pal(s) in 0 camp(s)` while a camp existed. Replaced with `FindAllOf("PalBaseCampModel")` plus an ownership match on `GetGroupIdBelongTo()`, which is also safer
3. The internal `firstOf` helper never called a single method, because it guarded on `type(obj[name]) == "function"` and UE4SS does not surface UFunctions as Lua function values, which masked working APIs as missing
4. Member-presence checks that relied on a non-nil result were unsound: UE4SS returns a wrapper for *any* name, proven with a negative control. Presence now requires extracting a real value

### Known limitations

- Suppressed Pals keep working, so an offline base keeps producing with no upkeep
- No overnight soak yet. The UE4SS timer-death class of bug appears after 40min-2h
- `SetDisableNaturalUpdate`'s full collateral scope is uncatalogued; exp and friendship are observed frozen, which is intended
- Windows dedicated servers only
- `stop_work_when_offline` is experimental and has no restore map, so leave it off
