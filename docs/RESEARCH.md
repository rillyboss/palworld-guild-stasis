# Research notes â€” verified ground truth

## Verified on a live server (2026-07-26)

Run against a local Windows dedicated server, app 2394010, buildid `24181105`, reporting `v1.0.1.100619`. These were open questions or inferences before; they are now observed facts.

| Result | Detail |
|---|---|
| **UE4SS injects into PalServer 1.0.1** | Manual route: `dwmapi.dll` + `ue4ss\` into `Pal\Binaries\Win64`. `UE4SS.log` appeared within ~1s of launch. |
| **Server-side Lua runs, and hooks register** | `Starting Lua mod 'GuildStasis'`, and `RegisterHook` on `/Script/Engine.PlayerController:ServerAcknowledgePossession` succeeded. |
| **`UPalGroupManager` resolves, and `GuildMap` marshals into Lua** | `GuildMap` is readable *and* `GuildMap:ForEach` is available â€” so the TMap iterates from Lua and the `FindAllOf` fallback is a safety net, not the primary path. This was flagged as a real risk. |
| **`UPalBaseCampManager` resolves** | Found via `FindFirstOf`. |
| **`-enable-gamedata-api` is the gate on `GET /v1/api/game-data`** | Without it the endpoint 404s even with `RESTAPIEnabled=True`. With it, it returns 200. The launch-arg name was an unverified guess; it is correct. |
| **`UPalCheatManager` does not exist with zero players connected** | Still absent even with UE4SS's `CheatManagerEnablerMod` enabled. Consistent with `UCheatManager` being instantiated per-PlayerController. Re-check with a player connected. |
| **The server's first run writes an EMPTY `PalWorldSettings.ini`** | 2 bytes, no `OptionSettings` block at all. "File exists" is not a valid check â€” you must seed from `DefaultPalWorldSettings.ini` whenever the `OptionSettings=(` line is absent. |
| **Lua's working directory is `Pal\Binaries\Win64`** | `../../../Pal/Saved/Config/WindowsServer/PalWorldSettings.ini` resolved from `io.open`. |
| **`bUseUObjectArrayCache = false`** | Already the default in the Okaetsu Palworld bundle's `UE4SS-settings.ini`. No change needed. |
| Useful cheap oracle | `GET /v1/api/metrics` returns `basecampnum` and `currentplayernum` â€” no mod required. |

### Wine-hosted Windows servers DO work (correction to earlier research)

Earlier notes here treated Wine/Proton as a dead end for Palworld 1.0, citing an open issue where the server commits exactly one save per boot and then wedges forever (`ReplaceFileW` failing with Win32 error 267, reproduced across five Proton builds). That is real, but it is **not** a blanket statement about Wine — it does not manifest on a properly configured managed host.

Verified on BisectHosting's mod-support Palworld product (2026-07-27):

| Observation | Detail |
|---|---|
| It is the **Windows** build under Wine | UE4SS logged `game executable: Z:\home\container\Pal\Binaries\Win64\PalServer-Win64-Shipping-Cmd.exe`. `Z:\` mapped to `/` is the standard Wine drive mapping, and `/home/container` is a Linux container path. |
| Full Windows tree present | `Pal/Binaries/Win64` with `PalServer-Win64-Shipping.exe` (152,378,880 bytes — byte-identical in size to a native Windows install), `Manifest_*_Win64.txt`, `steamclient.dll`. |
| **UE4SS works** | Injects, loads Lua mods, `RegisterHook` succeeds, reflection reads and writes all behave exactly as on native Windows. |
| **Saving works** | `Level.sav` observed at 1,788,513 → 1,766,282 → 1,754,449 → 1,768,750 across a single boot, and a forced `POST /v1/api/save` changed it again. Multiple commits per boot, so the one-save-then-wedge failure is absent. |

So the requirement is **the Windows build with a writable `Pal/Binaries/Win64`** — not "native Windows hardware". A Wine-hosted Windows build qualifies.

**Detecting this:** don't infer the platform from the panel or the OS. Look at `Pal/Binaries`: a `Win64` directory means viable, a `Linux` directory (with `PalServer.sh`, `Manifest_*_Linux.txt`, `PalServer-Linux-Shipping`) means the mod cannot run. The same Bisect account served the Linux build before a reinstall onto the mod-support product, so **the product variant matters more than the host**.

If you land on a Wine host, still verify saves are cycling before trusting it — watch `Level.sav` change size across a couple of autosaves, or force one over REST. The failure is silent: you lose everything since boot with no error.

### Console commands cannot be reached through a REST/RCON panel console

UE4SS's `RegisterConsoleCommandHandler` registers fine (logged `console commands registered: 9`), but a host panel whose console proxies to Palworld's admin API never reaches UE's exec layer. Typing `stasis.status` into Bisect's console returns:

```
[RestAPI]: Command not found in RestAPI Command List, attempting RCON...
[RCON]: Unknown command
```

This is a property of that whole class of panel, not one host. Any mod relying solely on UE console commands is undebuggable on such a server, which is why this mod also polls a command file.

### Confirmed by writing, not just reading

| Result | Detail |
|---|---|
| **`SetDecreaseFullStomachRates(FName, 0.0)` is a HARD STOP** | `GetFullStomachDecreasingRate()` read `1.0` before the write and `0.0` immediately after, with the game's own working-state entry also present. So the `FFloatContainer` does **not** sum â€” a `0.0` entry wins. This was flagged as make-or-break for the hunger half; it works. |
| **`SetDisableNaturalUpdate(FName, true)` writes and reads back** | `GetDisableNaturalUpdate()` returns `true` after the call. Whether it actually halts SAN decay is a separate question â€” a set flag is not a proven effect. |
| **The full guildâ†’Pal walk works** | `2 pal(s) in 1 camp(s)`, with live per-Pal `FullStomach` / `SanityValue` / decay rate / `HungerType` / `WorkerSick`. |
| `MaxSanityValue` = 100 | Consistent across every Pal observed. |
| `MaxFullStomach` **varies, roughly 100-600** | By species and level. A single local test Pal read 100, which was misleading — a live server showed 100, 210, 230, 280, 300, 410, 450, 460, 480, 490, 530 and 600. Never assume a fixed maximum; always read `GetMaxFullStomach()` per Pal, and express thresholds as a ratio. |
| `EPalGuildPlayerStatus` observed | `0` = Logout, `1` = Online. Confirmed by watching the flag flip across a real login. Previously known only from header ordering. |
| Guild name | Read the **`GuildName`** property. `GetGuildName()`/`GetGroupName()` return FString handles that do not stringify from Lua, and the `GroupName` *property* holds the owning player's UID, not a name. |
| SAN moves fast when simulated | Observed ~2.0/min drain on a working Pal with no beds, and strong recovery (up to full) once fed with beds available. Hunger moved far more slowly. **SAN, not starvation, is the real problem.** |

### The full suppress/un-suppress cycle, verified end to end

```
18:45:48  went fully offline; grace 45s
18:46:33  SUPPRESSED -- 2 pal(s) in 1 camp(s)      rate 1.0 -> 0.0, flag -> true
          4.5 min with a player ONLINE: 1 distinct SAN value per Pal (zero drift
          against a measured 2.0/min unsuppressed baseline)
18:49:03  BACK ONLINE -- lifted on 2 pal(s)        rate 0.0 -> 1.0, flag -> false
```

- `RemoveDecreaseFullStomachRates(FName)` genuinely reverses the write â€” it does not silently no-op, so Pals are never left in permanent stasis.
- The `ServerAcknowledgePossession` hook lifted suppression ~8s after login, ahead of the next scheduled sweep.
- **Nothing written by this mod persists.** After a save + restart both Pals read `decay=1.0` and the disable flag was clear, while the SAN/stomach *values* persisted normally. So the rate entry and the disable flag are session state only. This settles the direct conflict between two research lanes (Transient vs persisted) in favour of Transient, and means re-applying from live state every sweep is both necessary and sufficient â€” no migration, no cleanup pass, and uninstalling leaves no trace in the save.

### Still unverified (do not claim these)

- **What else `SetDisableNaturalUpdate` freezes.** It was applied together with the hunger-rate write, so we cannot even attribute which of the two froze the stomach. Its collateral scope (HP regen, friendship, exp, food timers, egg hatching) is uncatalogued. Risk while a guild is offline is plausibly low â€” nobody is present to lose value, and everything is restored on login â€” but it is unmeasured, not safe-by-proof.
- **Per-guild isolation with a second guild present.** Every write is per-Pal and gated on the camp's own `GetGroupIdBelongTo()` matching the guild, and every write target is logged, but a two-guild test needs a second player and has not been run.
- **Durability beyond ~10 minutes.** No soak test yet, so the UE4SS timer-death class of bug (which kills Lua timers after 40min-2h) is untested here.

### Things that do NOT work from Lua (verified by failure)

- **`UPalBaseCampManager::TryGetModel(FGuid, UPalBaseCampModel*&)`** â€” returns its model via an out-param, and out-param marshalling silently yields nothing. The walk reported `0 pal(s) in 0 camp(s)` while a camp demonstrably existed. Use `FindAllOf("PalBaseCampModel")` and match `GetGroupIdBelongTo()` instead; that is both verified and safer, since ownership is read from the camp itself.
- **A guild's own id accessors** (`GetGroupId()`, `GroupId`, â€¦) do not yield a usable FGuid. Take the id from the **`GuildMap` key**, which is verified to equal the `GuildID` reported by REST `game-data` for the same guild.
- **`UPalUtility` statics** (`GetGroupManager()`, `GetBaseCampManager()`) called on the CDO return nothing â€” they need a world context. `FindFirstOf`/`FindAllOf` work fine instead.
- **`UPalGroupIndependentGuild` does not exist** on this build; `FindAllOf` reports the class as not found. Solo players get a plain `PalGroupGuild`.
- **`UPalCheatManager` is absent from the build entirely** â€” not merely uninstantiated, and enabling UE4SS's `CheatManagerEnablerMod` does not conjure it. There are no debug-command shortcuts; decay tests run in real time.

### Trap worth its own note: accessing UFunctions from Lua

UE4SS does **not** return a Lua value of type `"function"` when you access a UFunction as a property. A helper that guards with `if type(obj[name]) == "function"` will therefore skip every method silently and appear to work while only ever reading plain properties. This produced two misdiagnosed "the API doesn't exist" failures here. Always call the method form `obj[name](obj)` inside a pcall and fall back to the property read.

**Caveat that matters for rented hosting:** `-enable-gamedata-api` is a *launch argument*. Nitrado exposes no way to set launch arguments, so `game-data` is a local-testing oracle only â€” do not design anything that depends on it in production.

The correct UE4SS build is confirmed: Okaetsu's `experimental-palworld` release, commit `c838a8ac`, `UE4SS-Palworld.zip`, SHA256 `768A45718FBB9E429AC5CC3CE4A139A1B7B468BFF31B4A136AE483D725ACA1CA`, asset uploaded 2026-07-19. Note the release *tag* is dated 2025-02-20 â€” the tag is rolling and its date is misleading, exactly as warned. Pin the asset hash, not the tag.

Compiled 2026-07-26 against Palworld client build `24181527` (exe dated 2026-07-15, game 1.0.1). Everything below is either first-party, read out of the retail binary, or read from source we actually fetched. Claims that were *not* verifiable are labelled as such â€” do not promote them to fact by copying them somewhere else.

**Byte offsets appear nowhere in this mod's code.** A single patch reorders all of them. Every access is by reflected name.

## v2 leads, read out of the retail server binary (2026-07-27)

Source: reflection name strings in `PalServer-Win64-Shipping.exe` (152,378,880 bytes, the local 1.0.1 dedicated server install). Method: extract printable ASCII runs and read the *neighbourhood* of each name, because UE registers one class's reflected members as a contiguous block, so a property's neighbours identify its owner.

**How much this evidence is worth.** A name in the reflection table is far stronger than a non-nil `obj[name]` -- it cannot be a `TrivialObject` phantom, because the string is physically present in the registration data. It still does **not** prove that Lua can reach the member, that the member is writable, or that it does what its name suggests. Everything in this section is *static* and must be runtime-confirmed before any of it is relied on. Nothing here has been executed.

### `CurrentOrderType` is a battle order, not a work gate -- Feature 1's primary lever is dead

The enum is `EPalMapBaseCampWorkerOrderType`, and it has exactly three enumerators, in declaration order:

```
0  Work               (the default, and what every camp reads)
1  BattleFighter
2  BattleAllWorker
```

`IsBattleOrderType` is registered in the very next slot after the enum name, which is what the enum is *for*: choosing whether the camp's Pals keep working or drop everything and fight. Nothing in it means "idle", "rest" or "stop".

So the v2 plan's headline lever does the opposite of what was hoped:

- Writing `1` or `2` puts the base on a war footing.
- The probe's finding that `3` was "accepted and read back" proves nothing. There is no enumerator 3. UE stores the raw byte, so a readback only echoes what was written -- exactly the class of false positive this project has been bitten by before.
- And it **persists to the save**. A base left at `BattleAllWorker` stays on a war footing across restarts.

`tools/probe/v2-ordertype.lua` as originally written would therefore have written two known-harmful, save-persisted values to a live camp. It has been replaced.

Also present, and not to be confused with it: `EPalOtomoPalOrderType { Default, Warlike, NotCombat }`, which is the follower-Pal order, not a base camp one.

### The mechanism this repo is named after does exist

| Symbol | Owner (from neighbourhood) | Why it matters |
|---|---|---|
| `PalStorage` | the **guild** object, in the same property block as `UnderRaidBaseCampIds`, `GuildMarkers`, `BaseCampLevel`, `OnRep_GuildName` | a guild's Pal Box reachable straight off a guild we already enumerate, with no map-object hunting |
| `UPalMapObjectCharacterContainerModule::TryMoveCharacterToContainerFrom` | qualified name read from a serialization string; params `OutContainer`, `FromSlot` | a plain server-side function, **not** a `_ToServer` RPC, so it does not need an online player |
| `RequestMoveWorkerToPalBox_ToServer` | player-side RPC block | the vanilla operation, but RPC-only: unusable here, since every member of the target guild is offline by definition |
| `PalBoxPageNum`, `PalBoxSlotNumInPage` | `UPalGameSetting` block | Pal Box capacity, so a park operation can check for room first |
| `Failed_FullGlobalPalStorage`, `Failed_FullPalStorage`, `FullPalBox` | failure-reason strings | parking **can** fail on a full box. It must be handled, not assumed |
| `AutoSANRegene_Percent_perSecond_PalStorage` | `UPalGameSetting` block | Pals in the Pal Box **regenerate SAN** on a vanilla timer |
| `PalBoxTimePeriodRecoverySick` | `UPalGameSetting` block | the Pal Box **cures sickness** over a vanilla time period |

Those last two are the interesting ones, because they are vanilla behaviour rather than anything this mod would have to invent.

### Raids: per-guild state exists, and there is a force-stop

Contrary to the plan's assumption that `bEnableInvaderEnemy` (server-global) was the only surface:

| Symbol | Owner | Use |
|---|---|---|
| `UnderRaidBaseCampIds`, `UnderRaidNotificationLogId` | the **guild** object | which of a guild's camps are under raid, readable per guild. A cheap M9 oracle that needs no hook and no `game-data` |
| `bIsUnderRaid`, `OnRaidBeginDelegate`, `OnRaidEndDelegate`, `Detectors` | `RaidDetectModule`, a base camp module | per-camp raid state and begin/end delegates |
| `IsIncidentBeginAllowed` | incident system | a reflected predicate gating whether an incident may begin |
| `ForceStopByIncidentId`, `ForceStopByIncidentType` | incident system | reflected force-stop. A raid that has begun can potentially be ended |
| `StartInvaderMarchForBaseCamp`, `StartInvaderMarchAll`, `StartInvaderMarchRandom`, `RequestIncidentInvaderEnemy` (param `OccuredBaseCamp`) | invader manager | the spawn path is **per base camp**, not world-global |
| `RemoveInvaderIncident` | invader manager | removal path |
| `bInvaderDisable`, `bForceDisableSpawnRandomIncident` | a **debug/developer settings** block (neighbours are `bDebugLogEnableWanted`, `bDisableCrime`, `bShowDebugWantedSpawnerSphere`) | a runtime global raid off-switch, no restart needed. Global, so same operator-choice caveat as the ini key |
| `RequestCancelInvader`, `GetInvaderCancelCost` | player RPC block, next to `RequestRecruitPal` | the vanilla paid cancel. RPC-only, so unusable for an offline guild |

The plan expected `RegisterHook` to be the only route and expected it to fail the way `UPalWorkBase::IsExistAssignableSlot` did. `ForceStopByIncidentType` is a direct call instead, which sidesteps that risk entirely if it is reachable.

### The game's per-guild all-offline flag is the guild auto-reset, not a raid gate

`bAllPlayerNotOnlineAndAlreadyReset` sits in the guild property block next to `EnableResetPropertiesWhenPlayerDelete`. It is the guild-side bookkeeping for a feature this mod already warns about: `bAutoResetGuildNoOnlinePlayers` and `AutoResetGuildTimeNoOnlinePlayers` are in the ini options block, **immediately adjacent to `bEnableInvaderEnemy`**. So the flag records "this guild has already been auto-reset for having nobody online", not a general engine notion of offline that v2 could reuse.

Two things follow. The mod's existing startup warning about `bAutoResetGuildNoOnlinePlayers` is aimed at exactly the right setting, and finding that flag is **not** evidence about raid gating -- do not let the coincidence of wording promote it into one.

### Runtime results: the reflected surface, enumerated rather than guessed (2026-07-27)

Run on the local test server, two guilds, one online player, read-only. **Method change that matters more than any single finding:** stop guessing member names and enumerate them. `UStruct:ForEachProperty` and `ForEachFunction` both work on this UE4SS build, and a name that comes *out* of them is real by construction, where a name we put *in* can never be trusted. This retires the phantom-wrapper problem for discovery entirely.

Two gotchas, both of which cost a probe iteration:

1. They enumerate a class's **own** declared members only. `PalGroupGuild` reports 9 properties and `PalStorage`, `GuildName`, `UnderRaidBaseCampIds` are not among them -- all three are on `PalGroupGuildBase`. Always walk the superclass chain.
2. "The call failed" and "the class has no own members" are different facts. Report them separately or a dead end reads as a finding.

Also: a UFunction is itself a UStruct, so `ForEachProperty` on one yields its **parameters**. That is how to learn a signature without calling anything.

#### The Pal Box parking route is dead

| Class | Mutators | Verdict |
|---|---|---|
| `PalGuildPalStorage` (`guild.PalStorage`) | **zero reflected members at all**, derives straight from `Object` | resolves as a live object, but opaque from Lua. A handle we can see and cannot open |
| `PalIndividualCharacterContainer` | none. `FindByHandle`, `FindEmptySlot`, `Get`, `GetSlots`, `Num` | read-only |
| `PalContainerBase` | none. `GetId`, `IsEmpty` | read-only |
| `PalCharacterContainerManager` | none. `GetContainer`, `TryGetContainer`, `GetLocalContainer`, `GetLocalSlot` | read-only |
| `PalIndividualCharacterSlot` | `Handle : ObjectProperty` but **no setter**. `GetHandle`, `GetSlotId`, `IsEmpty`, `Setup` | see below |
| `PalMapObjectCharacterContainerModule` | **class not found at runtime** | the binary's `TryMoveCharacterToContainerFrom` is unreachable. Contrast `PalMapObjectItemContainerModule`, 396 live instances |

Both ends of the move are visible: the Pal Box containers are ordinary `PalIndividualCharacterContainer` instances with 960 slots, exactly `PalBoxPageNum 32 x PalBoxSlotNumInPage 30`. There is simply no reflected function to move anything between them, and the only real mover, `RequestMoveWorkerToPalBox_ToServer`, is a player RPC needing an online member of the target guild -- which never exists by definition.

`slot.Handle` is a plain ObjectProperty, so parking is *technically* reachable by hand-assigning handles between slots. **Do not.** It bypasses the container manager's bookkeeping, `ReplicateHandleID`, and the worker director's own `WaitingWorkerIndividualIds` / `WorkerTasks`, and its failure mode is duplicated or deleted Pals. Ruled out on risk, not on reachability -- and worth keeping that distinction, because "unreachable" invites a retry while "unsafe" does not.

#### Signatures worth having

```
PalCharacterContainerManager.GetContainer(ContainerId : Struct) -> Object
PalCharacterContainerManager.TryGetContainer(ContainerId, Container : out, -> bool)
PalIndividualCharacterContainer.Get(Index : int) -> Object
PalIndividualCharacterContainer.FindEmptySlot() -> Object
PalBaseCampWorkerDirector.OrderCommand(OrderType : Enum)
PalGroupGuildBase.OnBaseCampRaidStarted_ServerInternal(RaidDetectModule : Object)
PalGroupGuildBase.OnBaseCampRaidEnded_ServerInternal(RaidDetectModule : Object)
```

Prefer `GetContainer` over `TryGetContainer`: the latter returns its container through an out-param, and out-param marshalling silently yields nothing here, exactly as it does for `TryGetModel`.

`OrderCommand(OrderType)` independently confirms the `CurrentOrderType` verdict -- the only thing a worker director can be *commanded* to do is choose a battle stance.

#### The raid hooks are the Feature 2 unlock

`OnBaseCampRaidStarted_ServerInternal(RaidDetectModule)` and `OnBaseCampRaidEnded_ServerInternal` are UFunctions on `PalGroupGuildBase`: server-side, per-guild, and `RegisterHook`-able. That turns M9 from a research project into "hook it and see whether it ever fires for a fully-offline guild". `OnRep_UnderRaidBaseCampIds` is there too.

#### Corrections to earlier notes in this file

- **A guild's own id IS reachable.** This file says the guild's own id accessors don't yield a usable FGuid. The reason was the wrong name: the property is `ID : StructProperty` on `PalGroupBase`. `GetGroupId` / `GroupId` do not exist. Taking the id from the `GuildMap` key still works and is still fine, but it is not forced.
- `EPalBaseCampWorkerDirectorState { Init, WaitForLoadingAround, Active }` is the `State` property's enum. It is a **lifecycle**, not a work policy. Writing it would repeat the `CurrentOrderType` mistake.
- Other enums seen: `EPalBaseCampWorkerWalkAroundState { WalkAround, Rest }`.

#### Why suppression cannot be fully event-driven

The server visibly knows when a player leaves -- its console prints

```
[LOG] U2short1 joined the server. (User id: steam_..., Player id: ...)
[LOG] U2short1 left the server. (User id: steam_...)
```

so "why poll at all?" is a fair question. Three routes were checked and all are closed:

| Route | Result |
|---|---|
| A reflected logout UFunction | None. The format strings `%s %s left the server. (User id: %s)` / `MESSAGE_DS_LEFT_PLAYER` sit immediately beside `APalGameMode::PreLogin` and `APalGameMode::RespawnPlayer`, so they are emitted from `APalGameMode` -- almost certainly its `Logout` override. In Unreal, `AGameModeBase::Logout` and `PostLogin` are plain C++ virtuals, not UFunctions, and UE4SS Lua can only hook UFunctions |
| Tailing the server log | **`Pal/Saved/Logs` is empty.** Those lines go to the console only; no log file is written, so there is nothing to watch |
| Candidate event names | `PlayerLogout` is `EPalActionType::PlayerLogout`, an animation. `Logout` is `EPalPlayerAccountState::Logout`, a state value. `OnUpdatePlayerInfoInGuildBelongTo` is a real UFunction but lives on the *player* object, which is being destroyed as they leave |

The asymmetry is the whole story: **login is hookable because `ServerAcknowledgePossession` happens to be an RPC, and therefore reflected. Logout goes through a virtual that is not.**

**And even a perfect logout event would not remove the sweep**, which is the more important point:

1. **Pals appear inside suppressed guilds.** Eggs hatch while nobody is online (`OnMultiHatchedIndividualHandle_ServerInternal` is a real function on the player class). A Pal born after a suppress event would never be suppressed under pure event-driven logic, and would work for free -- exactly the hole v2 exists to close.
2. **The game rewrites our container.** Observed live: `CraftSpeedRates: 2 entry(s) [Sick=1.0 GuildStasis_Offline=0.0]`. Palworld manages that array itself, so a rebuild on sickness change, level-up or buff recalc could drop our entry. Only re-application detects and repairs it.
3. **The HEARTBEAT is the only liveness signal.** UE4SS's timer-death bug kills Lua timers after 40min-2h. With a sweep that shows up as the heartbeat stopping; pure event-driven has no such tell, and a dead mod would be indistinguishable from a healthy one until someone logged out and nothing happened.
4. The grace period needs a timer regardless.

So: **events for latency, polling for correctness.** An event you miss is lost forever; a poll you miss just happens one interval later. If sweep cost ever matters, split it -- cheap presence check often, expensive camp walk only when presence changed or a guild is suppressed -- rather than removing it.

#### Login release latency is up to a full sweep interval, not ~8s

An earlier note in this file claimed the login hook lifted suppression "~8s after login". That was a favourable race. Measured properly:

```
17:10:02.55  LOGIN HOOK fired
17:10:02.59  LOGIN HOOK done
17:10:22.23  unsuppress applied      <- the NEXT scheduled sweep, 20s later
```

The hook fires on possession, but the guild's `EPalGuildPlayerStatus` flips to `Online` slightly *after* it, so the sweep running inside the hook still sees the player offline and does nothing. Observed in game as 10-15s of idle Pals after logging in. Fixed by queueing follow-up sweeps at 2s/5s/10s/20s from the hook, guarded against stacking because each sweep costs a full `FindAllOf`.

#### CraftSpeedRates zeroes work speed, and does not persist

The v2 stop-work mechanism, verified live with readback and a restart check.

`FPalIndividualCharacterSaveParameter` holds three sibling `FFloatContainer`s, and the third is work speed:

```
DecreaseFullStomachRates   <- v1's proven hunger lever
AffectSanityRates
CraftSpeedRates            <- work speed
FloatContainer           { Values : TArray<FloatContainer_FloatPair> }
FloatContainer_FloatPair { Key : FName, Value : float }
```

There is **no** `SetCraftSpeedRates` UFunction -- the class exposes a setter and remover for the hunger container only, confirmed by enumerating every function on it. So the entry has to be added by direct array write, and `.Values` is normally empty because entries exist only while something applies a rate. Both worked:

```
append { Key = FName("GuildStasis_Offline"), Value = 0.0 } at index 1  -> accepted, length 1
GetCraftSpeed_withBuff   70 -> 0
GetCraftSpeedSickRate   1.0 -> 0.0
GetCraftSpeed             70 -> 70    (base stat, before rates -- expected)
GetCraftSpeedByWorkSuitability(Handcraft)  50 -> 50   (did NOT move -- see caveat)
```

**Entries do not survive a restart.** After a reboot, all three worker Pals read `CraftSpeedRates: 0 entry(s)` with craft speed back to 70/77/70 -- including one deliberately left at `0.0`. So it is session state exactly like `DecreaseFullStomachRates`, which means v2 needs no restore map, no fingerprint, no disk state, and no boot cleanup, and **v1's no-persistence guarantee holds**.

Caveats, so this is not over-claimed:

- `GetCraftSpeedByWorkSuitability` did not change, so which getter the work system actually consumes is unestablished. The stat moved; the *behaviour* has not been observed yet. That is M7/M10.
- Whether hauling and transport are gated by craft speed at all is unknown.
- A `1.0` entry is the container's identity value, so release can neutralise rather than delete. Removing an array element from Lua is not established.

The reframing that found it is worth more than the finding: every attempt to *command a Pal to stop working* failed, and the answer came from asking how to make the work take infinitely long instead.

#### Passing a Lua string where an FName is expected kills the server

Six identical crashes, all `EXCEPTION_ACCESS_VIOLATION reading address 0x0000000000000070` with a callstack of nothing but `UE4SS` frames.

Cause, once isolated: a probe called

```lua
param:SetDecreaseFullStomachRates(PROBE_KEY, 0.5)      -- PROBE_KEY is a Lua string
```

The signature is `SetDecreaseFullStomachRates( Name : NameProperty, Rate : FloatProperty )`. Given a bare string for a NameProperty, UE4SS reads an FName out of it and dereferences null at offset `0x70`. **`pcall` cannot catch it** -- it is a native access violation, so the whole server goes down. The correct form, which `main.lua` has always used in `freezeHunger()`, is:

```lua
param:SetDecreaseFullStomachRates(FName(SUPPRESS_KEY), 0.0)
```

Any NameProperty parameter needs `FName(...)`. The same applies to a NameProperty *field* inside a struct written from a Lua table.

**How this was misdiagnosed twice, which is the more useful lesson.**

1. First blamed on the probe's own nested write. Wrong -- the nested write never executed; the log stopped one line earlier.
2. Then blamed on UE4SS's bundled `CheatManagerEnablerMod`, on the theory that it had nothing to instantiate because `UPalCheatManager` does not exist in this build. Plausible, and wrong. The "clean login" test that seemed to confirm it had disabled the probe *and* that mod in the same boot, so it isolated nothing. `CheatManagerEnablerMod` was innocent.

Two rules earned the hard way:

- **Change one variable per boot.** A test that disables two suspects at once cannot attribute the result to either, no matter how convincing the outcome looks.
- **"What logged last" does not identify a native crash site,** but bracketing markers do. `LOGIN HOOK fired` with no matching `LOGIN HOOK done` would prove a crash inside our sweep; both lines present exonerates it. `main.lua` logs that pair, and it did correctly clear the mod's login path -- that part of the earlier conclusion still stands.

On a headless server neither `CheatManagerEnablerMod` nor `Keybinds` has any purpose, so leaving them off is still right -- just not because either caused this.

#### A suppressed Pal earns no XP, and the test needed a positive control to say so

Two earlier attempts at this were worthless, and the reason is worth keeping. Both showed the suppressed Pal's exp static, which proves nothing on its own: base-Pal XP is granted on **work completion**, so it is bursty rather than continuous, and in both windows the *control* Pals happened to earn nothing either. "Neither moved" is not evidence.

The valid run, over ten minutes with one guild online and working and one suppressed:

```
                    17:21              17:31            delta
control slot 1      lvl=6 exp=275      lvl=7 exp=371    +96, levelled
control slot 2      lvl=6 exp=295      lvl=7 exp=391    +96, levelled
suppressed          lvl=4 exp=123      lvl=4 exp=123    0
```

Same world, same interval, `speed_zero=1` and `write_errors=0` throughout. So zero work speed means zero work completions means zero XP.

The same window is the best evidence collected for the other two levers as well. The suppressed Pal's stomach read `71.698272705078` at both ends, identical to the digit, and its SAN held at `100.0` while the working control's fell from `98.2` to `79.4`. That last figure is worth remembering as the scale of what the mod prevents: roughly 19 SAN points per ten minutes on a hard-working Pal, which is why SAN and not starvation is the harm that actually bites.

**Lesson worth more than the measurement:** a freeze test needs a control that is demonstrably moving. Without one, "the value did not change" is indistinguishable from "nothing was happening anywhere".

#### Hunger, measured

Read across every container on a live world: every Pal reported `decayRate=1.0` and `disableNaturalUpdate=false` while its guild was online, with `PalStomachDecreaceRate=1.000000` in the ini. Party Pals sat at `100.0/100.0` while a base Pal in the same guild sat at `0.0/100.0`, so decay is real and the difference is food access, not decay rate. Useful as a baseline: **a suppressed Pal must read `decayRate=0.0`, and anything else in a party container is a bug.**

### Still open after this pass

- **Does a raid fire against a fully-offline guild?** Static strings show structure, not control flow, so this is not answerable this way. There is a community claim (reported 2026-07-27) that raids **cannot** occur while every member of a guild is offline. It is plausible and, if true, makes v2's Feature 2 unnecessary. It is **not** confirmed here, and this file's own source-hygiene rule applies: the Palworld hosting/SEO blog ecosystem fabricates freely, and no static evidence for an online-player gate on the invader path turned up. The only online-player predicates in the binary are `IsExistPlayer` and the guild auto-reset pair above -- none of them near the invader manager.
  Confirming it is cheap now: read `UnderRaidBaseCampIds` on a guild whose members are all offline and see whether it ever becomes non-empty. Until that runs, treat the claim as the reason to **defer** Feature 2, not as proof it is unnecessary.
- Whether any of the above is reachable, and writable, from UE4SS Lua.
- Whether `TryMoveCharacterToContainerFrom`'s `OutContainer` is a genuine out-param. If it is, out-param marshalling silently yields nothing here, exactly as it does for `TryGetModel`.

## Platform

| Fact | Confidence |
|---|---|
| Palworld 1.0 released 2026-07-10; 1.0.1 on 2026-07-15 | high |
| Engine is a fork of Unreal Engine 5.1 (`++UE5+Release-5.1`) | high |
| No anti-cheat or anti-tamper anywhere in the install (no EAC/BattlEye/VAC/Denuvo) | high |
| Content ships as one 40.5 GB `Pal-Windows.pak`, pak version 11, Oodle. No IoStore containers, though engine support is compiled in | high |

## The official mod loader

The loader is compiled into the shipping game as its own UE module, `/Script/PalModLoader`. It is not a launcher feature.

Install types, read verbatim from the binary as `EPalModInstallType`:

```
Paks   Lua   LogicMods   UE4SS   PalSchema
```

So **UE4SS and Lua are first-party-recognised install types** â€” running Lua in the dedicated server process is sanctioned, not a loophole.

Deployment targets (official server docs):

| Type | Destination |
|---|---|
| UE4SS | `Mods\NativeMods\UE4SS` |
| Lua | `Mods\NativeMods\UE4SS\Mods\{PackageName}` |
| PalSchema | `Mods\NativeMods\UE4SS\Mods\PalSchema\mods\{PackageName}` |
| LogicMods | `Pal\Content\Paks\LogicMods` |
| Paks | `Pal\Content\Paks\~WorkshopMods\{PackageName}` |

`Info.json` schema is authoritative from Pocketpair's own `Models/ModInfo.cs`, which is **better than their docs page**: there is no `IsClient` field, `Type` must be one of the five above (`"Scripts"` is a target *folder*, not a Type), and `PackageName` is validated against `^[A-Za-z0-9]+$`. `DebugMode: true` forces reinstall on every launch â€” that is the dev loop.

`PalModSettings.ini` keys beyond the documented three (`bGlobalEnableMod`, `WorkshopRootDir`, `ActiveModList`): `DeleteModList`, `ConfigVersion`, `bNeedShowErrorOnNextStart` all exist in the binary's loader key table. Undocumented; don't rely on them.

Server-side mod support is **not new in 1.0** â€” the 0.7.3 docs page is substantively identical, which is mildly reassuring for durability.

Unresolved: whether the loader loads UE4SS natively or still relies on a proxy DLL. What *is* resolved is that a Workshop UE4SS and a legacy `Pal/Binaries/Win64` install conflict and crash.

## Windows only

> "At this time, server-side mods work only on the dedicated server with Windows edition."

UE4SS has no official Linux support (draft PR open since 2024-02). The native port runs in "limited mode" on the stripped Linux server binary where "UE hooks (ProcessEvent, etc.) are not available". PalSchema deadlocks at init under Wine/Proton (reproduced 2026-07-22). Palworld 1.0 under Proton commits exactly one save per boot then wedges forever â€” reproduced by four people across five Proton builds, root-caused to `ReplaceFileW` failing with Win32 error 267.

This is a hard constraint, not a difficulty.

## The call chain this mod walks

Every link is reflected and verified in headers plus an independent offset dump. The `SlotArray â†’ Handle â†’ TryGetIndividualParameter` tail is additionally **runtime-verified on a live 1.0 dedicated server** by a shipped mod.

```
UPalGroupManager : UPalWorldSubsystem
  .GuildMap : TMap<FGuid, UPalGroupGuildBase*>
    â†’ UPalGroupGuild            (multi-member)
        .PlayerInfoRepInfoArray : FPalFastGuildPlayerInfoRepInfoArray
          .Items[] : { FGuid PlayerUId; FPalGuildPlayerInfo PlayerInfo }
    â†’ UPalGroupIndependentGuild  (solo player â€” single PlayerUId + PlayerInfo)
  .BaseCampIds : TArray<FGuid>            (on UPalGroupOrganization)
    â†’ UPalBaseCampManager::TryGetModel(FGuid, UPalBaseCampModel*&)
      â†’ UPalBaseCampModel
          ::GetGroupIdBelongTo()          â† ownership re-check
          .WorkerDirector : UPalBaseCampWorkerDirector
            .CharacterContainer : UPalIndividualCharacterContainer
              .SlotArray : TArray<UPalIndividualCharacterSlot*>
                .Handle : UPalIndividualCharacterHandle
                  ::TryGetIndividualParameter() â†’ UPalIndividualCharacterParameter
```

`FPalGuildPlayerInfo { EPalGuildPlayerStatus Status; FDateTime LastOnlineRealTime; FString PlayerName; EPalGuildRole Role; }` with `EPalGuildPlayerStatus : uint8 { Logout, Online }`.

Notes:
- There is **no** class called `UPalGuildManager` â€” zero hits in the binary. Web sources that name it are wrong.
- Solo players are `UPalGroupIndependentGuild`, *not* `UPalGroupGuild`. Miss this and solo players silently get no benefit.
- `Items` is the UE FastArray convention and a shipped C++ mod resolves it, but the binary evidence was partly a substring of the struct *type* name. `main.lua` probes alternatives.
- `GuildMap`/`GroupMap` are `protected` in C++ with `AllowPrivateAccess` â€” irrelevant for Lua reflection, blocking for a C++ mod compiled against the kit headers.

## Hunger and SAN

Both live on `FPalIndividualCharacterSaveParameter`, owned by `UPalIndividualCharacterParameter` as the public replicated `SaveParameter` property: `float FullStomach`, `float SanityValue`, `EPalStatusHungerType HungerType`, `float MaxFullStomach` (Transient), `FFloatContainer DecreaseFullStomachRates`, `FFloatContainer AffectSanityRates`, `FName FoodWithFullStomachKeep`, `int32 Tiemr_FoodWithFullStomachKeep` (typo verbatim), `EPalBaseCampWorkerSickType WorkerSick`.

Both values **persist** â€” `GetSaveParameterValue_FullStomach` / `_SanityValue` exist on `UPalIndividualCharacterParameterUtility`. This refutes the pre-1.0 community claim that these are session-only.

Reflected `BlueprintCallable` write levers:

| Function | Use |
|---|---|
| `SetDecreaseFullStomachRates(FName, float)` | **the hunger lever** â€” insert `0.0` under our key |
| `RemoveDecreaseFullStomachRates(FName)` | clean removal |
| `SetDisableNaturalUpdate(FName, bool)` | blunt master switch; collateral scope unknown |
| `SetDisableNaturalHealing(FName, bool)` | |
| `SetFullStomach(float)` | absolute write |
| `NaturalUpdateSaveParameter(EPalCharacterNaturalUpdateType)` | |

Getters: `GetFullStomach`, `GetMaxFullStomach`, `GetFullStomachDecreasingRate`, `GetSanityValue`, `GetMaxSanityValue`, `GetHungerType`, `GetWorkerSick`, `GetDisableNaturalUpdate`, `GetGroupId`.

**There is no reflected sanity setter.** Only `GetSanityValue` / `GetMaxSanityValue` / `AffectSanityValue` / `RecoverySanityTo`. This is why the sanity half of the mod is the risky half. Candidate levers, in the order `config.lua` offers them:

1. `AffectNaturalSanityDecreaseDisableFlags.Flags[key] = true` â€” the direct analogue of the vanilla clinic flag. Requires a nested TMap write from Lua: **unproven**.
2. `SetDisableNaturalUpdate(key, true)` â€” works, but nobody has catalogued what else it freezes.
3. Insert into `AffectSanityRates` (`FFloatContainer`, no setter UFunction) â€” unproven.
4. Periodic `SaveParameter.SanityValue = max` top-up â€” a sawtooth, not a pause. This write *shape* is shipped by another 1.0 mod (for `.Level`).

Also worth testing: hooking `/Script/Pal.PalBaseCampWorkerEventBase:IsTriggerEventBySanity` (a `BlueprintNativeEvent`, hence ProcessEvent-dispatched) and returning false. That kills the *incidents* while `SanityValue` still falls â€” which may be all you actually want.

### A cleaner alternative worth trying

1.0 added the **Nutrient** consumable: *"When used on a Pal or the player, hunger will no longer decrease for a limited time."* The machinery is `EPalFoodStatusEffectType::FullStomachKeep`, with `FoodWithFullStomachKeep`, `Tiemr_FoodWithFullStomachKeep`, `IsFullStomachDecreaseStoppedByFood`. Driving a sanctioned game effect is likely more robust than fighting the decay path. Needs the correct FName row from the food status-effect DataTable.

## Two open questions that change the design

1. **`FFloatContainer` combination rule.** Product, sum, or min? Not visible in headers. If entries sum, inserting `0.0` does nothing and the hunger lever is dead. `main.lua` reads `GetFullStomachDecreasingRate()` back after every write so this surfaces immediately. Test by inserting `0.0` alongside the game's own working-state entry.
2. **Does offline decay tick in real time, or catch up at login?** Unresolved. Static analysis found no catch-up symbol, but that is weak negative evidence given this codebase's naming inconsistency (`Tiemr_`, `Decreace`). Settle it empirically with `GET /v1/api/game-data`.

## What does not exist (stop looking)

- No `UPalGuildManager` class.
- No sanity/SAN/depression setting in `PalWorldSettings.ini` â€” checked both language versions of the official 1.0 config page and the REST `/settings` schema, in every casing. `PalStomachDecreaceRate` (misspelling load-bearing) is the *only* hunger lever and it is server-global.
- No `PalSanityDecreaceRate`. Blogs asserting otherwise are fabricating.
- No REST or RCON endpoint that writes Pal hunger, SAN, or any per-guild state. The full 1.0 REST surface is 12 endpoints: `announce ban game-data info kick metrics players save settings shutdown stop unban`. RCON is deprecated and scheduled to stop functioning.
- No way to make a running server re-read `Level.sav`. `POST /save` flushes *out*. Every save edit therefore costs a full restart, which is impossible precisely when one guild is offline and another is online.
- `EPalBaseCampModuleType::TransportManager` does not exist. The real ones are `::TransportItemDirector` and `::PassiveEffect` plus seven no-ops.
- No reflected logout event, and no reflected server-side login hook (`LoginPlayerToGuild_ServerInternal` is a plain C++ member with no UFunction). Suppression therefore arms on a poll.
- Every configuration approach is **world-global**: `FPalOptionWorldSettings` has one hunger key and zero sanity keys, `UPalGameSetting` is a singleton, DataTables are process-global. Per-guild behaviour is only expressible at the per-Pal level. That single fact is why this mod has the shape it does.

## Useful read-only oracle

`GET /v1/api/game-data` returns a world actor snapshot where every actor carries `GuildID`, `GuildName`, `UnitType` (`Player | OtomoPal | BaseCampPal | WildPal | NPC`), `HP`, `MaxHP`, `userid`, `InstanceID`, `TrainerInstanceID`, position, `IsActive`.

It carries **no** hunger or SAN field, so it cannot measure the problem â€” but it is an excellent independent oracle for guild membership and presence that does not depend on this mod's own logging. It may need an enable beyond `RESTAPIEnabled=True`: the binary contains `"PalGameDataBridge GameData API is not enabled"` plus `EnableGameDataAPI` / `SetGameDataAPIEnabled`, and no GameData-named ini key exists. `GET /players` has no `GuildID`, so guild attribution must come from `game-data`.

## Prior art worth reading before changing this mod

- **`Fenyn/Gamestorming` â†’ `palworld-priority-mod/docs/callpath-map.md`** â€” the single most valuable document found. An in-game verification log from a live 1.0 dedicated server: which hooks fire, three hard-won crash rules, the verified RPC surface, and the finding that `FPalInstanceID` is **not stable** across restarts (base Pals get re-instanced). This mod's safety rules come from here.
- **`JaredScar/Palworld-GuildPact`** â€” open-source per-guild server-side Lua for 1.0+, with an explicit catalogue of what server-side Lua *cannot* do.
- **`SSyl/DynamicBaseCount`** â€” UE4SS C++ verified on 1.0.1, reads a guild's full roster including offline members via reflection. The template if this ever needs a C++ port.
- **PalGuildLevelSync** (Nexus 4069) â€” per-GroupId Lua that writes `IndividualParameter.SaveParameter.Level` on 1.0. Closest precedent for the nested-write question.
- **`TRRabbit/bastion-orp-plugin`** â€” closed source, but the best published *spec* of a per-guild offline state machine: activation delay after the last member logs out, dry-run mode, atomically rewritten status JSON.

## Source hygiene

A large family of hosting/SEO blogs (palmods.gg, connecthosting.net, doomhosting.com, low.ms, winternode.com, pinehosting.com and friends) contains outright fabrications about Palworld 1.0 modding, including ini keys that provably do not exist and claims that PalSchema works without UE4SS on Linux. Do not cite them. `cheahjs/palworld-save-tools` is 21 months stale and cannot read any save since 0.6 â€” the maintained successor is `deafdudecomputers/PalworldSaveTools`.
