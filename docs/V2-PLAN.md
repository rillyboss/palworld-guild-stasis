# v2 -- true stasis

v1 stops offline Pals starving and losing SAN. It leaves them **working**, so an offline base keeps producing with no upkeep -- better than being online, which is backwards. v2 makes stasis mean what it says: Pals inert, and the guild not punished for being inert.

Two features, and the second exists only because of the first.

> **Revised 2026-07-27.** A static read of the retail server binary killed this plan's primary lever and replaced it with a better one. See `docs/RESEARCH.md`, "v2 leads, read out of the retail server binary". Everything in this document that rests on that pass is **static evidence only** -- reflection names read out of the binary, nothing executed. It must be runtime-confirmed on a throwaway server before any of it ships.

## Feature 1 -- stop work while offline

**Goal:** suppressed Pals produce nothing. No hauling, no crafting, no output.

**Status: SHIPPED in v0.2.0 and verified end to end.** See "THE MECHANISM" below. The three ruled-out sections above it are kept because the eliminations are what make the final choice trustworthy.

### Ruled out: `CurrentOrderType`

This was v2's headline lever. It is dead, and it was worse than useless.

The enum is `EPalMapBaseCampWorkerOrderType`, three enumerators in declaration order:

```
0  Work               (the default, and what every camp reads)
1  BattleFighter
2  BattleAllWorker
```

`IsBattleOrderType` is registered immediately after the enum, which is what it is for: whether the camp's Pals keep working or drop everything and **fight**. There is no idle or rest value. Writing `1` or `2` puts the base on a war footing, and it persists to the save.

The earlier probe result -- "wrote 3, read back 3" -- was a false positive of the exact kind this project keeps hitting. There is no enumerator 3; UE stores the raw byte, so the readback only echoed the write. **A successful readback of an enum property proves the write landed, not that the value is meaningful.** Add that to the trap list.

### Also still ruled out (from the earlier negative control)

`obj[name]` returns a `TrivialObject` wrapper for *any* string on this build -- `SetStopWorkXYZZY` and `PleaseDoNotExist` returned exactly the same shape as names that supposedly exist. These are phantoms:

```
SetStopWork   IsStopWork   Pause   SetPause   SetEnable
SetOrderType  SetCurrentOrderType  RequestOrderType
GetCurrentOrderType  GetOrderType  GetWorkerNum
```

### Also ruled out, after runtime testing: parking in the Pal Box

This was the replacement mechanism, and it is dead too. It was worth trying and it failed cleanly, without a single write.

Both ends of the move are visible from Lua. The Pal Box containers are ordinary `PalIndividualCharacterContainer` instances with 960 slots (`PalBoxPageNum 32 x PalBoxSlotNumInPage 30`). What does not exist is any reflected way to move a Pal between containers:

- `PalGuildPalStorage`, which `guild.PalStorage` resolves to, has **zero reflected members** and derives straight from `Object`. Visible, and opaque.
- `PalIndividualCharacterContainer`, `PalContainerBase` and `PalCharacterContainerManager` expose only readers.
- `PalMapObjectCharacterContainerModule`, which owns the binary's `TryMoveCharacterToContainerFrom`, **is not registered at runtime** on this build.
- `RequestMoveWorkerToPalBox_ToServer` needs an online member of the target guild, which never exists by definition.

`slot.Handle` is a plain ObjectProperty, so parking could be forced by hand-assigning handles between slots. **That is ruled out on risk.** It bypasses the container manager's bookkeeping, `ReplicateHandleID`, and the director's own `WaitingWorkerIndividualIds` / `WorkerTasks`, and gets you duplicated or deleted Pals when it goes wrong. Losing a player's Pals outright is far worse than the free production v2 exists to stop.

Keeping the distinction straight matters for whoever reads this next: parking is not unreachable, it is unsafe. "Unreachable" invites a clever retry. "Unsafe" should not.

The cost of this being dead: v2 loses the free SAN regeneration and sickness cure that made the Pal Box so attractive. The sickness question therefore reopened, and has since been closed with a decision not to cure. See the end of this document.

### THE MECHANISM: CraftSpeedRates, verified on a live server

**Status: SHIPPED in v0.2.0. Verified end to end on a live server, including reversal.**

The full cycle, driven through the admin command channel so the transitions could be forced with one account:

```
suppress   speed 70 -> 0    and 77 -> 0     decay 2.0 -> 0.0
release    speed    -> 70   and    -> 77    each Pal's OWN original value
restart    CraftSpeedRates entries gone entirely
```

Release needs no stored value: neutralising the mod's own entry to `1.0` lets each Pal's computed speed recover by itself. There is nothing saved that can be lost or mismatched, which is why this route has no restore map at all.

Observed in game: a Pal walks to its station, plays the work animation, and the progress slider never moves. After a while the worker AI gives up and the Pal falls asleep, in daylight. So the end state is genuinely inert, not merely unproductive, which is better than this plan originally predicted.

Everything below was the analysis that led here, kept because the reasoning matters more than the conclusion.

```
BEFORE   GetCraftSpeed=70   GetCraftSpeed_withBuff=70   GetCraftSpeedSickRate=1.0
AFTER    GetCraftSpeed=70   GetCraftSpeed_withBuff=0    GetCraftSpeedSickRate=0.0
```

Appending `{ Key = FName("GuildStasis_Offline"), Value = 0.0 }` to `SaveParameter.CraftSpeedRates.Values` was accepted, read back as one entry at `0.0`, and dropped effective craft speed from 70 to **0**. `GetCraftSpeed` stays at 70 because that is the base stat before rates; `_withBuff` is the computed value and it is what went to zero.

**And the entries do not persist.** After a restart, all three worker Pals read `CraftSpeedRates: 0 entry(s)` with craft speed back to 70/77/70 -- including a Pal that had been left at `0.0` by a probe bug. So this is session state exactly like `DecreaseFullStomachRates`, which means:

- no restore map, no fingerprint anchor, no state on disk
- no boot-time cleanup pass -- a crash mid-suppression self-heals
- **v1's "nothing written persists to the save file" guarantee survives v2**

Every other candidate broke that guarantee. This one has a blast radius no larger than what is already in production, and it touches no player configuration at all.

Implementation shape:

```
suppress:  find our entry in CraftSpeedRates.Values by Key; set Value = 0.0
           if absent, append { Key = FName(SUPPRESS_KEY), Value = 0.0 }
release:   find our entry; set Value = 1.0   (1.0 is this container's identity)
```

Find-then-append keeps it idempotent across sweeps rather than growing the array. Element removal from Lua is not established, so release neutralises to `1.0` instead of deleting -- harmless, and the entry vanishes on restart anyway.

Both of the behavioural questions this plan raised are now answered:

1. **M7/M10 pass.** A Pal was watched at a workbench for over ten minutes with the progress slider frozen. Output is zero, not merely slow.
2. **Every work type is covered.** All thirteen suitabilities read a final speed of `0` on a suppressed Pal, including the three the test Pal actually had ranks in (Handcraft 50, Transport 2, MonsterFarm 12). The base-value getters like `GetCraftSpeedByWorkSuitability` do not move, which was the thing that looked worrying; the `_withBuff_` variants are the computed ones and they all go to zero.
3. **No XP either**, measured against a control that gained 96 XP and a level over the same ten minutes.

### How this was found, and the earlier framing that was wrong

The three candidates below were all attempts to *command a Pal to stop working*. None of them worked, and the search only succeeded after reframing the question as **make the work take infinitely long** instead. That reframing came from the server owner, not from the API hunt.

Worth remembering next time: when every lever for "make X stop" is closed, ask what makes X pointless instead.

### The earlier candidate, kept for the record: CraftSpeedRates rationale

Found by asking the obvious question nobody had asked -- instead of stopping the work, set the work *speed* to zero.

`FPalIndividualCharacterSaveParameter` holds three sibling `FFloatContainer`s, confirmed by enumerating the struct at runtime:

```
DecreaseFullStomachRates    <- v1 writes this, in production, verified
AffectSanityRates
CraftSpeedRates             <- work speed
FloatContainer         { Values : TArray<FloatContainer_FloatPair> }
FloatContainer_FloatPair { Key : FName, Value : float }
```

Why this shape is so much better than the other three candidates:

- **It is the same container type as the one lever already proven in production.** `SetDecreaseFullStomachRates(FName, 0.0)` is a verified hard stop: the container does not sum or average, a `0.0` entry wins outright.
- **Its sibling's entries do not persist.** After save + restart the hunger rate read `1.0` again. If `CraftSpeedRates` behaves the same, work-speed-zero needs no restore map, no fingerprint, no disk state, and **keeps v1's "nothing persists to the save" guarantee** -- the single biggest risk in every other candidate simply disappears.
- **It touches no player configuration**, so it has none of the off-work list's silent-loss failure mode.
- Keyed by our own FName, so it composes with vanilla and removes cleanly.

Confirmed reachable: `sp.CraftSpeedRates` resolves, `.Values` is a real array, and craft speed is readable through several getters (`GetCraftSpeed` = 70, `GetCraftSpeedByWorkSuitability(Handcraft)` = 50) which gives an unambiguous before/after oracle.

**The open problem.** There is no `SetCraftSpeedRates` UFunction -- the class exposes a setter and remover for the hunger container only, verified by enumerating every function on it. So an entry has to be added by writing the array directly, and `Values` is normally **empty** (entries exist only while something is applying a rate), which means an append rather than a mutate. Whether UE4SS Lua can grow a TArray of structs is unproven.

Two questions, in order, and the second only matters if the first succeeds:

1. Can an entry be added at all?
2. Does a `0.0` entry actually zero work speed, or is `CraftSpeedRates` merely a reporting cache that the game recomputes?

`tools/probe/v2-workspeed.lua` tests both, and reads craft speed back rather than trusting the write.

### The fallback: per-Pal off-work list

Appending every `EPalWorkSuitability` (1-13) to each Pal's `OffWorkSuitabilityList`, via `SaveParameter.WorkSuitabilityPreference*`, proving the member with a real `GetArrayNum()` before touching it. Partly implemented already behind `stop_work_when_offline`, with restore deliberately refusing rather than guessing.

**Now reachable, after a real bug fix.** `main.lua` guessed three names for the member holding this list and all three were wrong; the actual member is `WorkSuitabilityOptionInfo`, read out of the save-parameter struct. With the correct name, `sp.WorkSuitabilityOptionInfo.OffWorkSuitabilityList` resolves as a real array. So this path could never have worked before, independently of its other problems -- which also means `stop_work_when_offline` has never actually been exercised.

It is a fallback, not a good option. Be honest about that before building on it:

- **Its failure mode is the silent one.** The list encodes player decisions about which Pal may do which job. A bad restore loses that configuration invisibly, and it looks like the player's own settings rather than a bug. Compare the two mechanisms now ruled out: a wrong `CurrentOrderType` is visible (the base is fighting), and a failed un-park is visible (the Pals are in the box). This one is not.
- **Restore needs a fingerprint map persisted to disk**, because `FPalInstanceID` is reassigned across restarts. Anchor: `CharacterID | Talent_HP | Talent_Shot | Talent_Defense | Gender`, all persisted and immutable. Identical bred twins are genuinely ambiguous and must be **skipped rather than guessed** -- unlike the parking case, where ambiguity would have been harmless, here a wrong match silently rewrites the wrong Pal's config.
- **It stops work, not output.** Whether a base with every Pal off-work actually produces nothing is unverified, and M10 exists precisely to check that rather than assume it.
- It does nothing about raid exposure, though that now matters less: with Pals still in the world they can still defend, exactly as in v1.

Given all that, the sequencing that makes sense is: **prove M7 and M10 with `stop_work_when_offline` on a throwaway server before writing a single line of restore-map code.** If appending to the off-work list does not actually zero production, the restore map is wasted work and v2 has no viable mechanism at all -- which is a legitimate outcome worth reaching cheaply.

### If this one also fails

Then v2's honest answer is that Palworld 1.0 does not expose a safe per-guild way to stop base work from server-side Lua, and the alternatives are all worse than v1's known tradeoff:

- `WorkerTasks` / `RequiredAssignWorks` array surgery on the director -- almost certainly re-derived each tick, and unverified.
- `PalBaseCampWorkerDirector.State` -- a lifecycle enum (`Init`, `WaitForLoadingAround`, `Active`), so writing it repeats the `CurrentOrderType` mistake.
- `slot.Handle` surgery -- see above; risks losing Pals.

Documenting "v1's tradeoff stands, and here is the exhaustive list of why" is a better deliverable than shipping something that silently eats player configuration. Three mechanisms have now been eliminated on evidence; that is a real result, not a failure.

## Feature 2 -- no raids on an offline guild

**Goal:** a guild that cannot defend itself is not attacked.

**Status: CLOSED, 2026-07-27, by the server owner's decision.** Not building it.

The reasoning: raids are not believed to occur against a guild with nobody online, so there is nothing to defend against. That belief is **not verified here**, and this document should not be read as claiming it is. It is a judgement call by the person who runs the server and carries the consequences, which is the right person to make it.

If anyone revisits this, the work is already scoped and cheap. `PalGroupGuildBase` exposes two server-side, per-guild, `RegisterHook`-able UFunctions:

```
OnBaseCampRaidStarted_ServerInternal(RaidDetectModule : Object)
OnBaseCampRaidEnded_ServerInternal(RaidDetectModule : Object)
```

Hook them log-only, leave a guild offline overnight, and see whether either ever fires. That settles the premise in one run. Everything below is the analysis behind the decision, kept because it is what makes the decision informed rather than assumed.

### The original framing

A community claim (reported 2026-07-27) holds that raids cannot occur while every member of a guild is offline. If that is right, this feature is moot.

Runtime testing found the detection hook that makes M9 trivial. `PalGroupGuildBase` has two server-side, per-guild UFunctions:

```
OnBaseCampRaidStarted_ServerInternal(RaidDetectModule : Object)
OnBaseCampRaidEnded_ServerInternal(RaidDetectModule : Object)
```

Both are `RegisterHook`-able, so M9 becomes "hook them, leave a guild offline overnight, see whether either ever fires". That is a far better oracle than polling `UnderRaidBaseCampIds`, because it cannot miss a raid that starts and ends between two sweeps.

It is not confirmed. `docs/RESEARCH.md` records why the claim gets no free pass -- the Palworld blog ecosystem fabricates, and the static pass found no online-player gate anywhere near the invader path. Note also that `bAllPlayerNotOnlineAndAlreadyReset` is **not** evidence for it: that flag is bookkeeping for `bAutoResetGuildNoOnlinePlayers`, a different feature entirely, and the similar wording is a coincidence worth resisting.

The practical consequence was the same either way: build nothing until M9 ran. The owner has since closed the feature outright, so M9 is no longer a gate on anything. It stays documented above as the cheap way to reopen the question if a player ever reports an offline base being raided, which is the evidence that would change the decision.

**The coupling is weaker than this plan first claimed.** The argument was that parking Pals creates raid exposure that v1 did not have, so the two features ship together or not at all. Parking in the Pal Box changes that: a Pal in the box is not in the world and cannot be killed. What stays exposed is the *base* -- structures, chests, and whatever a raider can break. So Feature 1 can ship alone without putting Pals at risk, and Feature 2 becomes about property rather than lives. That is a judgement call for the server owner, not a blocker.

**Established:** `bEnableInvaderEnemy` is `True` in the real 1.0 server ini, and is server-global. There is no per-guild raid setting anywhere in the 1.0 configuration.

**New, static:** the surface is much better than "one global ini key".

| Symbol | Owner | Use |
|---|---|---|
| `UnderRaidBaseCampIds`, `UnderRaidNotificationLogId` | the **guild** object | which camps are under raid, per guild, readable with no hook and no `game-data`. This is the M9 oracle |
| `bIsUnderRaid`, `OnRaidBeginDelegate`, `OnRaidEndDelegate` | `RaidDetectModule`, a camp module | per-camp raid state and begin/end delegates |
| `ForceStopByIncidentId`, `ForceStopByIncidentType` | incident system | reflected force-stop. A raid that has begun can potentially be ended |
| `IsIncidentBeginAllowed` | incident system | a reflected predicate gating whether an incident may begin |
| `StartInvaderMarchForBaseCamp`, `RequestIncidentInvaderEnemy` (param `OccuredBaseCamp`) | invader manager | the spawn path is **per base camp** |
| `bInvaderDisable`, `bForceDisableSpawnRandomIncident` | debug/developer settings block | a runtime global raid off-switch with no restart. Global, so the same operator-choice caveat as the ini key |

This changes the expected shape of the work. The plan assumed `RegisterHook` was the only route and expected it to fail the way `UPalWorkBase::IsExistAssignableSlot` did, because native callers bypass reflection. `ForceStopByIncidentType` is a direct call, so the likely implementation is *detect and stop* rather than *intercept and prevent* -- watch an offline guild's `UnderRaidBaseCampIds`, force-stop the incident. Less elegant, but it does not depend on a hook firing.

**Open questions, in order. Stop after 1 if the answer is "they don't".**

1. Do raids even trigger for a guild with zero members online? Static analysis cannot answer this -- strings show structure, not control flow. Read `UnderRaidBaseCampIds` on a fully-offline guild over a long window.
2. Is `ForceStopByIncidentType` reachable and effective from Lua?
3. Does force-stopping a raid mid-flight leave the camp in a sane state, or does it strand invader actors?

**Acceptable fallback:** `bEnableInvaderEnemy=False` disables base raids server-wide, or `bInvaderDisable` does it at runtime. Both are global and a real gameplay change, so either must be the operator's explicit choice -- documented, never silently applied.

## Worth reading before building either feature

`bAllPlayerNotOnlineAndAlreadyReset` sits in the guild property block next to `EnableResetPropertiesWhenPlayerDelete`. The engine already tracks a per-guild all-members-offline condition and resets something once when it becomes true. What it resets is unknown. Find out before v2 invents a parallel notion of the same state -- and before assuming the mod is the only thing acting on that transition.

## Test additions for v2

Beyond the existing M1-M6:

**Run M7 and M10 first, before writing any restore code.** They decide whether the last remaining mechanism works at all.

- **M7 -- work actually stops.** With a guild suppressed, no camp Pal reports a working `AI_Action` for 5+ minutes, cross-checked against `game-data`, while an unsuppressed guild's Pals keep working. `tools/palworld-ordertype-watch.ps1` is the external oracle.
- **M10 -- no free production.** Confirm base output over an offline window is **zero, not merely reduced**. Count items in the output chests before and after. This is the one that decides whether v2 has a mechanism, because off-work Pals that still haul or still tick a converter would make the whole thing pointless.
- **M8 -- restore is exact, across a restart.** After un-suppress, every Pal's off-work list matches a pre-suppression snapshot exactly. Must survive a server restart mid-suppression, which means the fingerprint map has to be on disk. Ambiguous twins must be logged as skipped, not silently matched.
- **M9 -- raid behaviour.** Whether raids fire against a fully-offline guild, established *before* building anything to stop them. Hook `OnBaseCampRaidStarted_ServerInternal` on the guild and leave a guild offline overnight. This is the gate on whether Feature 2 exists at all, and it needs a long window -- a raid that fires rarely still fires. A hook that never fires is only evidence if the window was long enough to expect one.
- **M11 -- a partial failure leaves nothing half-done.** If the off-work write fails on some Pals of a guild, the guild must end up entirely unsuppressed rather than half-suppressed, and it must be logged loudly.

## Don't regress

v1's guarantees must hold. Re-run M3-M5 before merging:

- Per-guild isolation: never write to a camp whose `GetGroupIdBelongTo()` doesn't match
- Suppression reverses on login within one sweep
- No reliance on Pal instance IDs across restarts
- `force_suppress_for_testing` ships `false`

One v1 guarantee **cannot** survive v2 and has to be restated rather than quietly dropped: *"nothing written persists to the save file"*. `OffWorkSuitabilityList` lives on `SaveParameter` and persists, so any working version of Feature 1 writes save data by design. That is the single biggest change in v2's risk profile, it must be stated plainly in the README, and it is why M8 and M11 exist.

It also means the uninstall story changes. v1 could be removed and left no trace. v2 cannot: a server that removes the mod mid-suppression leaves every offline guild's Pals off-work permanently, with no restore map being read. That needs a documented recovery path -- at minimum a `stasis.release_all` admin command, run before uninstalling.

## Where this leaves v2

Three candidate mechanisms for Feature 1 have been eliminated on evidence, none of them by guesswork and none by a write to a live server:

| Mechanism | Verdict | Basis |
|---|---|---|
| **`CraftSpeedRates`** | **WORKS.** Craft speed 70 -> 0, and entries do not persist | verified live, with readback and a restart check |
| `CurrentOrderType` | dead. Wrong thing entirely -- a battle order, and it persists | binary enum + `OrderCommand(OrderType)` signature |
| Pal Box parking | dead. No reflected mutator exists; forcing it risks losing Pals | full class-chain enumeration at runtime |
| `OffWorkSuitabilityList` | unnecessary now. Reachable after a name fix, but silent failure mode | `WorkSuitabilityOptionInfo` confirmed real |

Feature 2 went the other way: it is probably unnecessary, and if it is needed the hook to build it on now exists.

**The next step is production code**, which is a change from every previous revision of this plan. The mechanism is settled; what remains is:

1. Wire `CraftSpeedRates` into the sweep beside `freezeHunger`, same shape, same FName key, reversed on login.
2. Prove M7 and M10 behaviourally -- Pals observed idle, output measured at zero.
3. Retire `stop_work_when_offline` and its off-work-list code, or keep it clearly marked as an unused fallback. Do not ship two mechanisms.

Because the writes are session state, v2 no longer needs M8's restore map, M11's partial-failure handling is trivial (a failed write leaves a Pal working, which is v1 behaviour), and the README's "nothing persists" claim stands unchanged.

## The sickness question: CLOSED, no cure

**Decided 2026-07-27 by the server owner: the mod will not cure sickness.** No
`cure_sickness_on_offline` flag, and nothing sickness-related is written. The reasoning
that held it back all along stands: curing sickness is a gameplay benefit beyond "do not
punish absence", which is the line this mod tries not to cross.

The Pal Box angle that briefly made this look easy is gone with the parking design.
`PalBoxTimePeriodRecoverySick` does cure sickness on a vanilla timer, but the mod cannot
move Pals into the box, so it cannot reach that mechanism. See the parking section above.

### What that means in practice, so nobody is surprised

**The mod will not make a Pal sick.** It freezes hunger, so suppressed Pals do not
starve, and zero work speed means they cannot be overworked. Both of the routes into
`WorkerSick` are closed while a guild is offline. That is the whole point.

**The mod will preserve sickness that already exists.** A Pal that was sick when its
guild went offline stays sick for the entire offline window, because a hunger-frozen Pal
never eats and the eat-driven recovery path never fires. The 17 sick Pals on the
production server (11 in one guild, 4 in another, 2 in a third) predate the mod and will stay sick until their owners deal with them.

The fix is manual and entirely vanilla: medicine, or put the Pal in the Pal Box, which
cures it on the game's own timer. Worth telling affected players once, because "my Pal
has been sick for a week" is otherwise going to get blamed on the mod.

### The consistency question, resolved

`topup_once_on_offline` used to default true, on the argument that the mod's own freeze
creates a permanent trap: a frozen Pal never eats, so it never recovers SAN.

The owner has since turned it off, which makes the whole policy consistent: freeze
everything, restore nothing. Absence is not punished and it is not rewarded either.

The original argument was also weaker than it looked. SAN is frozen, so it does not fall,
it merely fails to recover, and the freeze lifts the moment anyone logs in. So the effect
was bounded by the offline window rather than permanent, and nothing bad happened during
it: a suppressed Pal is not working and cannot trigger the low-SAN incidents it otherwise
would. "Stays miserable forever" was an overstatement, now corrected in `config.lua`.
