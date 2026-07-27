# Guild Stasis

A **server-side** mod for Palworld 1.0 dedicated servers. While every member of a guild is offline, that guild's base Pals stop getting hungry and stop losing SAN — and every other guild on the server is left completely alone.

Player clients stay 100% vanilla. Nothing is written to the save file. No launch arguments.

## Why this exists

On a shared server with several guilds, someone is almost always online. The world is only simulated while at least one player is connected — so your base keeps ticking while you're away, your Pals keep burning through the food box, and nobody is there to restock it. You come back to starving, depressed Pals.

Palworld gives you no per-guild lever for this. `PalStomachDecreaceRate` is server-global, and there is no sanity setting at all. So this mod does it per-Pal, scoped to one guild at a time.

## Status

Verified on a live Windows dedicated server (app 2394010, build `24181105`, `v1.0.1.100619`):

- UE4SS loads, server-side Lua runs, the login hook fires
- Guild → base camp → worker Pal → parameter chain resolves, including camps built mid-session
- **Hunger freeze is a hard stop** — `GetFullStomachDecreasingRate()` goes `1.0 → 0.0`
- **SAN freeze holds** — both Pals bit-identical for 4.5 min against a measured 2.0/min drain baseline, with a player online and the Pals verifiably awake and working
- **Reverses on login** within ~8s, confirmed by read-back
- **Per-guild isolation proven symmetrically** — 2 Pals written for one guild, 1 for the other, never 3; each camp written only while its own guild was offline
- Zero errors across ~130 write cycles
- Nothing persists to the save, so uninstalling leaves no trace

Not yet verified: durability beyond ~20 minutes (no overnight soak), and the full collateral scope of `SetDisableNaturalUpdate`.

## Known tradeoff in v1

Suppressed Pals **keep working**. They haul, they craft, they produce — they just never get hungry and never lose SAN. So an offline base keeps generating output with no upkeep, which is arguably better than being online.

If you consider that unbalanced, that's what the v2 work targets: parking the Pals so they're genuinely inert, plus preventing raids against a guild that can no longer defend itself. Neither mechanism is solved yet — see `docs/TESTPLAN.md`.

## Requirements

- **A Windows dedicated server.** Not optional. Pocketpair's docs: *"At this time, server-side mods work only on the dedicated server with Windows edition."* UE4SS has no Linux support, and Palworld 1.0 under Proton has a documented save-corruption bug.
- **UE4SS**, Okaetsu's `experimental-palworld` build. Verified: `UE4SS-Palworld.zip`, commit `c838a8ac`, SHA256 `768A45718FBB9E429AC5CC3CE4A139A1B7B468BFF31B4A136AE483D725ACA1CA`. The release *tag* is dated 2025-02-20 but the tag is rolling — pin the hash, not the tag.
- File access to the server, and the ability to restart it.

## Install

Two routes. The manual one is what's been tested end to end, and it's the one that works on rented hosting with no Workshop integration.

### Manual (tested)

1. Copy `dwmapi.dll` and the `ue4ss/` folder into `<server>/Pal/Binaries/Win64/`
2. Copy this repo's `Scripts/` folder and `enabled.txt` into `<server>/Pal/Binaries/Win64/ue4ss/Mods/GuildStasis/`
3. Add one line to `ue4ss/Mods/mods.txt`:
   ```
   GuildStasis : 1
   ```
4. Restart the server
5. Check `ue4ss/UE4SS.log` for `[STASIS]` lines

Leave `bGlobalEnableMod=false` — the official loader isn't needed this way.

### Official mod loader (untested)

Palworld 1.0 ships a first-party loader that recognises UE4SS as an install type. Place this folder under `<server>/Mods/Workshop/`, then in `Mods/PalModSettings.ini`:

```ini
[PalModSettings]
bGlobalEnableMod=true
ActiveModList=UE4SS
ActiveModList=GuildStasis
WorkshopRootDir=<absolute path to Mods\Workshop>
```

`ActiveModList` matches `PackageName` from `Info.json`, **not** the folder name. Read the UE4SS package's own `Info.json` for its real name — it may be `UE4SS` or `UE4SSExperimentalPW`.

**Never install UE4SS both ways.** A manual copy in `Win64` alongside a loader-deployed one will crash the server. Disabling isn't enough — leftover files still load.

## Configuration

`Scripts/config.lua`, read once at load. Restart to apply.

| Setting | Default | Notes |
|---|---|---|
| `mode` | `"run"` | `"recon"` is read-only — enumerates everything and writes nothing |
| `dry_run` | `false` | `true` logs every decision without writing |
| `grace_seconds` | `300` | Delay after the last member logs out. Also deters logging off mid-fight |
| `sweep_interval_ms` | `30000` | `FindAllOf` scans the whole object array — don't make this small |
| `freeze_hunger` | `true` | The high-confidence lever |
| `sanity_mode` | `"natural_update"` | The verified one. `"none"`, `"disable_flags"`, `"topup"` also exist |
| `topup_once_on_offline` | `true` | See below |
| `stop_work_when_offline` | `false` | **Experimental, incomplete** — no restore map yet |
| `verbose_pals` | `false` | Per-Pal write logging. Noisy but it's the isolation evidence |
| `force_suppress_for_testing` | `false` | **Test only.** Suppresses every guild unconditionally |

### Why `topup_once_on_offline` exists

A hunger-frozen Pal never gets hungry, so it never eats, so the eat-driven SAN recovery path never fires. A guild that logs off with already-miserable Pals would stay miserable forever. This tops SAN up once on the offline transition. Turn it off if you consider it too generous.

## How it works

A sweep every 30s:

1. Enumerate guilds from `UPalGroupManager.GuildMap` (the key *is* the guild FGuid)
2. Decide which guilds have every member offline, cross-checking the guild's own `EPalGuildPlayerStatus` against live `PlayerController`s
3. After the grace delay, for each of that guild's base Pals:
   ```lua
   param:SetDecreaseFullStomachRates(FName("GuildStasis_Offline"), 0.0)
   param:SetDisableNaturalUpdate(FName("GuildStasis_Offline"), true)
   ```
4. On login, reverse both and remove the FName entries

State is recomputed from live objects every sweep and applied idempotently, so it self-heals after a restart and nothing is keyed on Pal instance IDs (which are reassigned across restarts).

Camps are found with `FindAllOf("PalBaseCampModel")` and matched on the camp's own `GetGroupIdBelongTo()`. That ownership check is the per-guild guarantee — a camp that doesn't claim this guild is never touched.

## Risks to decide about

- **UE4SS issue #1091 is open.** Installing UE4SS on a Palworld dedicated server has been reported to make players reconnect as brand-new characters with fresh GUIDs. This is a risk of UE4SS itself, not this mod. Back up saves, set `DedicatedServerName` in `GameUserSettings.ini` **before** installing, then verify an existing character survives.
- **`bAutoResetGuildNoOnlinePlayers=True` deletes an offline guild's structures and base Pals** regardless of how well fed they are. This mod warns at startup but cannot stop it. Set it `False`.
- **`AutoTransferMasterThresholdDays`** transfers guild leadership after a long absence. This mod makes long absences viable, so it's more likely to fire.
- The world save records `bLastSavedUsingMod`. Modded crash reports are attributed to mods.

## Layout

```
Info.json                        first-party loader manifest (Type=Lua, IsServer=true)
enabled.txt                      UE4SS enable marker
Scripts/config.lua               all configuration
Scripts/main.lua                 the mod
docs/RESEARCH.md                 verified ground truth, dead ends, and prior art
docs/TESTPLAN.md                 M1-M6 milestones
tools/setup-local-testserver.ps1 stands up a local test server
tools/probe/                     throwaway discovery mods (not shipped)
```

`docs/RESEARCH.md` is worth reading before changing anything — it records what does **not** exist and what silently fails, which is most of the value.

## License

MIT. UE4SS is separately licensed and is not redistributed here.
