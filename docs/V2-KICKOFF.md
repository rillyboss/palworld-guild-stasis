# v2 kickoff prompt

Paste this into a fresh session to start v2 work. It is written to be self-contained: everything needed is either here or in a file it names.

**Revised 2026-07-27.** The first version of this prompt sent a session after `UPalBaseCampWorkerDirector.CurrentOrderType`. That lever is dead and was actively harmful. See "What changed" at the bottom before trusting any older note.

---

## Prompt

> I'm working on **Guild Stasis**, a server-side UE4SS Lua mod for Palworld 1.0 dedicated servers. v1 is finished and running in production. I want to build **v2**.
>
> **Read these first, in order:**
> - `README.md` -- what the mod is, all 16 settings, the admin commands
> - `docs/RESEARCH.md` -- verified API surface, and critically the "what does NOT exist", "verified by failure", and "v2 leads, read out of the retail server binary" sections
> - `docs/V2-PLAN.md` -- the v2 charter, including mechanisms already ruled out
> - `Scripts/main.lua` -- the mod itself, ~1300 lines
>
> **What v1 does:** while every member of a guild is offline, it freezes that guild's base Pals' hunger and SAN, per-guild, leaving other guilds untouched. Two per-Pal writes keyed by our own FName: `SetDecreaseFullStomachRates(key, 0.0)` and `SetDisableNaturalUpdate(key, true)`, both reversed on login. Nothing is written to the save file. Proven in production on a 6-guild server: 93 Pals, 11 camps, zero write errors, and per-guild isolation confirmed by one guild releasing on login while five stayed suppressed.
>
> **What v2 must add, and why:** v1 leaves suppressed Pals *working*, so an offline base produces with no upkeep -- better than being online, which is backwards. v2 makes stasis mean genuinely inert: **no hunger, no SAN loss, no exp, and no output**.
>
> **Feature 1 -- stop work. Three mechanisms have been eliminated; one candidate remains, and it is not a good one.** Read the "Where this leaves v2" table in `docs/V2-PLAN.md` before proposing anything, because the two obvious ideas are already dead on evidence: `CurrentOrderType` is a battle order that persists, and Pal Box parking has no reflected mutator anywhere in the container chain (forcing it via `slot.Handle` risks duplicating or deleting Pals).
>
> What is left is appending every `EPalWorkSuitability` (1-13) to each Pal's `OffWorkSuitabilityList`, already half-built behind `stop_work_when_offline`. Its failure mode is the silent one -- it loses the player's per-Pal job configuration invisibly -- and it is unproven that off-work Pals stop *producing* rather than merely stop being assigned.
>
> So **do not write restore-map code first.** Run M7 and M10 with `stop_work_when_offline` on a throwaway server and find out whether output actually goes to zero. If it doesn't, v2 has no viable mechanism, and documenting that exhaustively is a better outcome than shipping something that silently eats player config.
>
> The big change in risk profile if it does work: **`OffWorkSuitabilityList` persists to the save.** v1's "nothing persists" guarantee cannot survive, restore needs a fingerprint-keyed map on disk, and uninstalling mid-suppression would leave Pals off-work forever unless a release-all command is run first.
>
> **Feature 2 -- raids. Deferred, and probably unnecessary. Build nothing here yet.** There is a community claim that raids cannot occur while every member of a guild is offline; if it holds, the feature is moot. It is unconfirmed, and the Palworld blog ecosystem fabricates freely, so confirm it before relying on it: read `UnderRaidBaseCampIds` on the guild object over a long window and see whether it ever becomes non-empty. Do not treat `bAllPlayerNotOnlineAndAlreadyReset` as evidence for the claim -- that flag is bookkeeping for `bAutoResetGuildNoOnlinePlayers`, an unrelated feature with confusingly similar wording.
>
> The coupling to Feature 1 is also weaker than first thought: parked Pals are out of the world and cannot be killed, so what stays exposed is base *property*, not lives. Feature 1 ships alone regardless. If raids do turn out to fire, the likely shape is detect-and-stop via `ForceStopByIncidentType` rather than intercept-and-prevent via a hook, because native callers bypass reflection and a hook probably will not fire.
>
> **Non-negotiables.** Read the safety rules at the top of `main.lua` and obey them -- each is a reproduced crash. In particular: `IsValid()` before any member call, never read a SoftObjectProperty, use `SlotArray` not `GetSlots()`, never `LoopAsync`. And four traps that have each cost real time here:
> 1. **A non-nil result from `obj[name]` proves nothing.** UE4SS returns a `TrivialObject` wrapper for arbitrary names -- `PleaseDoNotExist` looks identical to a real member. Presence must be established by extracting a real value. Verify with a deliberately fake name as a control.
> 2. **UE4SS does not surface UFunctions as Lua `function` values.** A `type(obj[name]) == "function"` guard silently skips every method. Call `obj[name](obj)` inside a pcall.
> 3. **Verify effects, not success messages.** Every write should be read back. Several v1 "successes" were false.
> 4. **A successful readback of an enum property proves the write landed, not that the value means anything.** UE stores the raw byte. `CurrentOrderType` accepted and echoed `3` when the enum has only three enumerators, 0 to 2. That false positive is what sent v2 down a dead end.
> 5. **Wrap every NameProperty argument in `FName(...)`.** Passing a bare Lua string makes UE4SS dereference null at offset `0x70`, and `pcall` cannot catch it -- the server dies outright. This cost six crashes and two misdiagnoses. `main.lua` gets it right in `freezeHunger()`; copy that form.
> 6. **Change one variable per boot when hunting a native crash.** A test that disables two suspects at once attributes nothing, however convincing it looks. And "what logged last" does not locate a native crash -- bracket the suspect code with before/after markers instead.
>
> **Test on a throwaway server, never production.** `tools/setup-local-testserver.ps1` stands up a local Windows one, and it is already installed at `D:\SteamLibrary\steamapps\common\PalServer`. The production server is on BisectHosting (SFTP 2022, `GameRoot = '.'`, UE4SS pre-installed) -- do not experiment there. v2 moves save data, so a bad run outlives a restart.
>
> **Static analysis is cheap and you should use it.** The retail server binary is on disk at `D:\SteamLibrary\steamapps\common\PalServer\Pal\Binaries\Win64\PalServer-Win64-Shipping.exe`. `grep -a -b -o -E '<pattern>'` over it finds reflection names in seconds, and reading the *neighbourhood* of a name identifies its owning class, because UE registers one class's members as a contiguous block. That is how `CurrentOrderType` was killed and the Pal Box route found, without touching a server. A name in the reflection table cannot be a phantom -- but it still does not prove Lua can reach it.
>
> **Verification tooling already exists.** `tools/palworld-modstatus.ps1 -HostName <host>` judges loaded/alive/working/clean. `tools/palworld-ordertype-watch.ps1` is the external work/idle oracle for M7 and M10. `tools/probe/v2-palbox.lua` and `tools/probe/v2-classdump.lua` are read-only probes; the second one is the reusable tool (see below). The mod has a `HEARTBEAT` line per sweep, a status JSON, and an admin command channel (a polled `command.txt`, because panel consoles that proxy to REST/RCON cannot reach UE4SS console verbs).
>
> **Discovery technique -- use this before proposing any new lever.** `UStruct:ForEachProperty` and `ForEachFunction` both work on this UE4SS build, so the reflected surface can be *enumerated* instead of guessed. A name that comes out of them is real by construction, where a name you put in can never be trusted. `tools/probe/v2-classdump.lua` does exactly this and takes a list of classes. Two traps that each cost an iteration: they return a class's **own** members only, so walk the superclass chain (`PalStorage` is on `PalGroupGuildBase`, not `PalGroupGuild`), and keep "the call failed" separate from "zero own members" or a dead end reads as a finding. A UFunction is itself a UStruct, so `ForEachProperty` on one yields its **parameters** -- that is how to read a signature without calling anything.
>
> **Start by** answering these, in this order, before writing production code:
> 1. **M7 + M10.** Enable `stop_work_when_offline` on the local test server and find out whether an off-work guild's output actually drops to zero, not merely slows. This decides whether v2 has a mechanism at all.
> 2. Only if that passes: design the fingerprint restore map, then M8. Not before -- if output doesn't zero, the map is wasted work.
> 3. In parallel, M9: hook `OnBaseCampRaidStarted_ServerInternal(RaidDetectModule)` on the guild and leave a guild offline overnight. A hook that never fires is only evidence if the window was long enough to expect a raid.
>
> Add M7-M11 from `docs/V2-PLAN.md` as the acceptance criteria, and re-run M3-M5 before merging so v1's guarantees don't regress -- except "nothing persists to the save", which v2 breaks by design and which must be restated in the README rather than quietly dropped.

---

## What changed on 2026-07-27

A static read of the retail server binary, before any live testing:

- **`CurrentOrderType` is dead.** The enum is `EPalMapBaseCampWorkerOrderType { 0 Work, 1 BattleFighter, 2 BattleAllWorker }`, with `IsBattleOrderType` registered right after it. It is a battle order with no idle value, and it persists to the save, so the old probe's writes of `1` and `2` would have left a base on a war footing. `tools/probe/v2-ordertype.lua` was deleted for that reason.
- **The Pal Box route was found**, along with the fact that the box regenerates SAN (`AutoSANRegene_Percent_perSecond_PalStorage`) and cures sickness (`PalBoxTimePeriodRecoverySick`) on vanilla timers.
- **Raids have a real per-guild surface**, not just the global `bEnableInvaderEnemy`: `UnderRaidBaseCampIds` on the guild, `bIsUnderRaid` per camp, and `ForceStopByIncidentType`.
- **`bAllPlayerNotOnlineAndAlreadyReset`** on the guild is bookkeeping for `bAutoResetGuildNoOnlinePlayers`, whose ini pair sits immediately beside `bEnableInvaderEnemy`. It is not a reusable engine notion of "offline", and it is not evidence about raids. The mod's existing startup warning is already aimed at the right setting.
- **Feature 2 was deferred** on a community claim that raids cannot fire against a fully-offline guild. Unconfirmed; M9 is the gate.

## The sickness decision, now mostly moot

**17 Pals on the production server are already sick** (11 in one guild, 4 in another, 2 in a third) from before the mod existed. v1 prevents further harm but does not heal, and a hunger-frozen Pal never eats so the recovery path never fires.

The proposed fix was a `cure_sickness_on_offline` flag, held back because a mod-invented cure is a gameplay benefit beyond "don't punish absence". Under the parking design that flag is unnecessary: `PalBoxTimePeriodRecoverySick` means the box cures sickness on the game's own timer, which is exactly what a player does by hand. Still a judgement call, since the mod is what puts them in the box, but a much easier one.

## Where v1 stands

Passed M1-M6 except the durability soak, which is running in production now. Check the heartbeat is still climbing before declaring v1 complete.
