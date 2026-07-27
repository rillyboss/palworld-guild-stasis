# Test plan

Six milestones, in order. Each one is independently verifiable and each answers a question that the next one depends on. Do not skip ahead. M4 in particular decides whether the mod is achievable as specified, and it should run before any more code gets written.

Use a **throwaway** Windows dedicated server. Not your community server.

---

## M1. Stack proof: does UE4SS load on PalServer 1.0 and does a hook fire?

The Palworld dedicated server is a **separate Steam depot (app 2394010)**. Nothing about it can be inferred from a client install, different pak layout, different binary.

Before touching UE4SS:

- Full save backup.
- Set `DedicatedServerName` under `[/Script/Pal.PalGameUserSettings]` in `Pal\Saved\Config\WindowsServer\GameUserSettings.ini`. Do this **before** installing UE4SS, not after.
- Set `bIsUseBackupSaveData=True`.
- Set `bAutoResetGuildNoOnlinePlayers=False`.

Then install **exactly one** copy of UE4SS and this mod per the README, and start the server with `mode = "recon"`.

**Passes when:** `[STASIS]` lines appear in `ue4ss/UE4SS.log`, the login hook registers, and a player connecting produces a login-triggered sweep.

Also record, because these are open questions no document settles:

- The `UE4SS.log` header, version **and Git SHA**. The `experimental-palworld` tag is *rolling*: same tag, silently re-uploaded assets. Every future bug report must quote the SHA.
- Whether the loader needed a proxy DLL or loaded UE4SS natively.
- The actual deployed paths, including `Mods\NativeMods\UE4SS\Mods\mods.txt` and `Mods/ManagedMods/GuildStasis/InstallManifest.json`. Two first-party sources disagree about whether the PalSchema and Paks targets carry a `{PackageName}` suffix, find out which is true rather than hardcoding either.
- **UE4SS issue #1091:** connect a pre-existing character and confirm it is *not* recreated with a new GUID. If it is, stop. That bug can eat a live server's characters and no amount of care in this mod's code protects against it.

---

## M2. Read-only reconnaissance: prove per-guild attribution

Still `mode = "recon"`. Create two guilds with base camps and worker Pals.

Read the resolve block at the top of the log. Every identifier the mod needs is logged individually with `OK` or `MISSING`, so a failure names itself.

**Passes when:** the log shows, for each guild, its id, name, every member with status, and each base camp's worker Pals with live `FullStomach` / `SanityValue` / decay rate, and the guild-to-Pal attribution is actually correct.

Specific things to confirm here:

- Does `PalGroupManager.GuildMap` iterate from Lua, or did it fall back to `FindAllOf`? Both counts are logged; they should agree.
- Is a **solo** player's guild found? Solo players are `UPalGroupIndependentGuild`, not `UPalGroupGuild`.
- Did the FastArray member resolve as `Items`, or did a fallback name win?
- Does `PalCheatManager` exist on a shipping dedicated server? If yes, `SetGuildMemberOffline` / `SetPlayerLastOnline` / `SetSanityToBaseCampPal` / `SetDebugFullStomachDecreaseRate` turn multi-hour tests into seconds. Have a plan for both answers.
- What FName keys does the game itself use (`PalDefine.DecreaseFullStomachRate_Work` etc.)? Confirms `GuildStasis_Offline` cannot collide.

In parallel, generate authoritative identifier dumps **on the client, not the server**. UE4SS's dumper keybinds don't work headless. Install UE4SS client-side and run the CXX Header Generator, UHT Dumper, Object Dumper and the `.usmap` dumper. Where a fresh dump disagrees with any published SDK, the fresh dump wins.

---

## M3. Hunger write proof: does `SetDecreaseFullStomachRates(key, 0.0)` actually zero the drain?

Set `mode = "run"`, `dry_run = false`, `freeze_hunger = true`, `sanity_mode = "none"`.

**Passes when** `GetFullStomachDecreasingRate()` reads `0` after the write **and** `FullStomach` holds flat over time on a Pal that is actively working.

This is where the `FFloatContainer` combination rule gets settled. Inspect how our `0.0` entry composes with the game's own working-state entry:

- Multiplies → `0.0` is a hard stop. Good.
- Sums or takes min → the lever is dead. Pivot to writing `FoodWithFullStomachKeep` + `Tiemr_FoodWithFullStomachKeep` (the shipped Nutrient mechanic) and verify via `IsFullStomachDecreaseStoppedByFood()`.

Then `POST /v1/api/save`, restart, and re-read the container. Sources conflict on whether `DecreaseFullStomachRates` is Transient or persisted. This settles whether the boot-time sweep is mandatory. **Assume it does not persist until proven otherwise**, the mod re-applies on every sweep regardless, so it self-heals either way.

Also read `SaveParameterMirror` after each write. `GetSaveParameter()` returns by value and a mirror exists, so a direct property write can be silently reverted.

---

## M4. Write-capability proof (the real risk gate)

**Run this before writing any more production code.**

One probe **per server boot**. A native access violation here cannot be caught by `pcall`, so mixing probes makes a crash impossible to attribute. Set `dry_run = false` (a probe has to actually write) and set `probe_write` to one of:

| `probe_write` | Tests | If it works, you get |
|---|---|---|
| `"ufunction_flag"` | `SetDisableNaturalUpdate(key, true)` | A blunt SAN pause. Catalogue the collateral. |
| `"nested_scalar"` | `SaveParameter.SanityValue = max` | SAN top-ups (sawtooth, not a pause). |
| `"nested_tmap"` | `AffectNaturalSanityDecreaseDisableFlags.Flags[key]` | A true per-guild SAN pause. Best case. |
| `"nested_tarray"` | appending to `OffWorkSuitabilityList` | Stop-work, which combined with frozen hunger makes SAN recover on its own. |

Start the server, read the log, stop, change, repeat. Start Pals at low SAN (or use the cheat manager) so decay is observable in minutes rather than hours.

Start with `"ufunction_flag"` (lowest risk, it's a normal UFUNCTION call), then the nested writes. `"nested_tmap"` and `"nested_tarray"` are the two that answer the real question: **can Lua write a container nested inside a UPROPERTY on this build?** If either works, the other probably does too, and the mod has a clean solution. If neither works, that is the signal to port to C++ rather than keep fighting Lua.

A write that appears to succeed may still be reverted by `SaveParameterMirror`, the probe logs before/after at the instant of the write, which cannot distinguish that. Watch the value over the following minutes.

Separately, register a **log-only** hook on `/Script/Pal.PalBaseCampWorkerEventBase:IsTriggerEventBySanity` and see whether it fires at all. Native callers may hit `..._Implementation` directly and bypass reflection entirely. That is exactly what happened to `IsExistAssignableSlot` in another mod's testing.

Outcomes and what each means:

Then pick the implementation from what survived:

| Surviving capability | What to ship |
|---|---|
| `nested_tarray` (stop-work) | **Preferred.** Freeze hunger + stop work; SAN recovers passively. Needs the restore map built first. |
| `nested_tmap` | Freeze hunger + true SAN pause. `sanity_mode = "disable_flags"`. |
| `ufunction_flag` only | Freeze hunger + `sanity_mode = "natural_update"`. Log HP regen, exp gain, friendship and food timers while the flag is set, to document the collateral. |
| `nested_scalar` only | Freeze hunger + `sanity_mode = "topup"`. A sawtooth. Say so in the README. |
| the `IsTriggerEventBySanity` hook only | No incidents and no work refusal, while `SanityValue` still falls. |
| nothing | Escalate to a UE4SS C++ port before writing more Lua. C++ can write the `FFlagContainer` TMap and read by-value TArrays. |

**The goal for this server is that hunger and SAN both stop, or that the Pals park and suffer neither.** Both of those are satisfied by the stop-work route, which is why `nested_tarray` is the probe that matters most. The `IsTriggerEventBySanity` hook alone is a weaker outcome here, it prevents the symptoms while the bar still drains, so treat it as a floor, not the target.

---

## M5. Per-guild isolation acceptance test

Two guilds, two accounts, both with base camps and known starting values. Guild A logs everyone off; guild B keeps one member online.

**Passes when**, over several hours:

- Guild A's Pals hold their hunger and SAN.
- Guild B's Pals decay **exactly as vanilla**.
- Guild B's Pals were **never written to**, verify from the per-write log lines, not by inference.
- Guild A's member logs back in and suppression lifts within one sweep; `GetFullStomachDecreasingRate()` returns to baseline and decay resumes.

Cross-check with `GET /v1/api/game-data`, grouping by `GuildID` and `UnitType=BaseCampPal`. That is an oracle independent of this mod's own logging, which matters, a mod that believes it worked is not evidence.

If `PalCheatManager` exists, `SetGuildMemberOffline` and `SetPlayerLastOnline` compress this from hours to seconds.

---

## M6. Durability, soak, packaging

- **12+ hours unattended.** Confirm timers still fire at the end. This is the failure mode `LoopAsync` causes (dead timers after 40min–2h) and the reason this mod chains one-shot delays instead. Assert it explicitly rather than assuming.
- **Restart mid-offline.** The boot sweep must re-apply suppression from live state. Nothing may be keyed on `FPalInstanceID`, base Pals get re-instanced with new IDs across restarts.
- **Hostile neighbour.** Walk an online player from guild B through guild A's suppressed base camp. Any player in render distance re-simulates a base, so the mod must be correct under **full simulation** and must never assume actors are absent. A rate multiplier of `0` is preferable to anything actor-dependent precisely because of this.
- **Save integrity.** Round-trip the world through an offline save reader (`deafdudecomputers/PalworldSaveTools`, the maintained 1.0-capable one) and diff against a pre-mod baseline.
- **Client divergence.** `SaveParameter` is `ReplicatedUsing=OnRep_SaveParameter` so server writes *should* replicate, but that is unverified. Check what a connected vanilla client's UI actually shows for a suppressed Pal.
- **Performance.** Measure sweep cost. `FindAllOf` scans the whole UObject array; the engine itself amortises guild iteration across frames (`MaxGuildsPerFrame`), which is a hint about the cost.
- **Package.** Set `MinRevision` to the tested build's revision, read it off the running game's **title screen**, since it is a packed config value, *not* the Steam buildid. Set `DebugMode: false` for release.
