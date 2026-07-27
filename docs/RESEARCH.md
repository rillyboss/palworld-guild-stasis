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
