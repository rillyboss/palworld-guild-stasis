# v2 — true stasis

v1 stops offline Pals starving and losing SAN. It leaves them **working**, so an offline base keeps producing with no upkeep — better than being online, which is backwards. v2 makes stasis mean what it says: Pals inert, and the guild not punished for being inert.

Two features, and the second exists only because of the first.

## Feature 1 — stop work while offline

**Goal:** suppressed Pals produce nothing. No hauling, no crafting, no output.

**Status:** no working mechanism yet.

### What was ruled out

A negative control settled this. On this build `obj[name]` returns a `TrivialObject` wrapper for *any* string — `SetStopWorkXYZZY` and `PleaseDoNotExist` returned exactly the same shape as names that supposedly exist. So these are **phantoms**, not APIs:

```
SetStopWork   IsStopWork   Pause   SetPause   SetEnable
SetOrderType  SetCurrentOrderType  RequestOrderType
GetCurrentOrderType  GetOrderType  GetWorkerNum
```

Never treat a non-nil member access as evidence again. Presence requires extracting a real value.

### The one real lever found

`UPalBaseCampWorkerDirector.CurrentOrderType` — a genuine writable integer property.

```
before = 0
wrote 1 -> reads 1        wrote 2 -> reads 2        wrote 3 -> reads 3
restored 0
```

**Unknowns, in priority order:**

1. What do the values *mean*? The enum is unidentified. Writing `2` may mean "rest", or may mean nothing, or may mean something harmful.
2. Does any value actually stop work? Test by writing each value and watching `AI_Action` for the camp's Pals via `GET /v1/api/game-data` — `BP_AIAction_Worker_Working` and `BP_AIAction_BaseCampWorker_Approach` mean still working; `BP_AIActionBaseCamp_Sleep` and `..._Wait` mean idle.
3. **It persists.** `current_order_type` is a save-data field, unlike everything v1 writes. So this needs explicit restore-on-boot, and a wrong value could survive a crash. Capture the original per camp and restore it on un-suppress *and* at startup.

### Fallback: per-Pal off-work list

Append every `EPalWorkSuitability` (1–13) to each Pal's `OffWorkSuitabilityList`, reachable via `SaveParameter.WorkSuitabilityPreference*` — but only after proving the member with a real `GetArrayNum()`, per the phantom-wrapper trap.

This works but is the higher-risk route, because **that list encodes player decisions** — which Pal may do which job. Restoring it needs each Pal's original list, and Pal instance IDs are reassigned across restarts, so it needs a fingerprint-keyed map persisted to disk:

```
anchor = CharacterID | Talent_HP | Talent_Shot | Talent_Defense | Gender
```

All persisted, immutable fields. Identical bred twins are genuinely ambiguous and must be skipped rather than guessed. Get this wrong and players silently lose their work configuration — which is worse than the problem v2 is solving.

**Recommendation:** exhaust `CurrentOrderType` first. One write per camp, restoring to a single engine default, touching no player config, is a far smaller blast radius than per-Pal list surgery.

## Feature 2 — no raids on an offline guild

**Goal:** a guild that cannot defend itself is not attacked.

**Why it's coupled to Feature 1:** in v1 Pals keep working, so they also keep defending — raids are no new exposure. Parking them creates the problem. Ship these together or not at all; parked-but-raidable is strictly worse than v1.

**What exists:** `bEnableInvaderEnemy` (confirmed `True` in the real 1.0 server ini). Server-global only — there is no per-guild raid setting anywhere in the 1.0 configuration.

**Open questions:**

1. Do raids even trigger for a guild with zero members online? If not, this feature is unnecessary and Feature 1 ships alone.
2. If they do, what spawns them? Look for an invader/raid manager and whether its spawn path is reflected and hookable. Note `PalGroupRaidBoss` exists as a live group object.
3. Is the spawn hookable at all? Precedent is discouraging: `UPalWorkBase::IsExistAssignableSlot` never fired under `RegisterHook` because native callers bypass reflection. Expect the same risk here.

**Acceptable fallback:** if the spawn can't be intercepted per-guild, `bEnableInvaderEnemy=False` disables base raids server-wide. It's global and a real gameplay change, so it must be the operator's explicit choice — documented, never silently applied.

## Test additions for v2

Beyond the existing M1–M6:

- **M7 — work actually stops.** With a guild suppressed, no camp Pal reports a working `AI_Action` for 5+ minutes, cross-checked against `game-data`, while an unsuppressed guild's Pals keep working.
- **M8 — work restores exactly.** After un-suppress, every Pal's work configuration matches a pre-suppression snapshot. Must survive a server restart mid-suppression.
- **M9 — raid behaviour.** Establish whether raids fire against a fully-offline guild, before building anything to stop them.
- **M10 — no free production.** Confirm base output over an offline window is zero, not merely reduced.

## Don't regress

v1's guarantees must hold. Re-run M3–M5 before merging:

- Nothing written persists to the save file
- Per-guild isolation: never write to a camp whose `GetGroupIdBelongTo()` doesn't match
- Suppression reverses on login within one sweep
- No reliance on Pal instance IDs across restarts
- `force_suppress_for_testing` ships `false`
