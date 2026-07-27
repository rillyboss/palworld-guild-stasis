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
- **Write access to `Pal/Binaries/Win64` (or the server root)**, and the ability to restart. This is the requirement that actually disqualifies most rented hosting — see below.

### Hosting compatibility

Check this **before** anything else, because it's a hard gate.

You need to be able to write files *outside* `Pal/Saved`. Both install routes do:

- Manual → `Pal/Binaries/Win64/dwmapi.dll` + `ue4ss/`
- Official loader → `Mods/PalModSettings.ini` + `Mods/Workshop/`

**Verified incompatible: Nitrado.** Its FTP exposes only `Pal/Saved`. Confirmed with retries — the other directories don't appear in a listing of their own parent, so this isn't a permissions quirk you can work around:

```
/palworld              -> only "Pal"
/palworld/Pal          -> only "Saved"
/palworld/Pal/Binaries -> not accessible
/palworld/Mods         -> not accessible
```

The server *build* is fine (`Pal/Saved/Config/WindowsServer/` confirms Windows edition) and `PalWorldSettings.ini` is writable — but there is nowhere to put UE4SS. Nitrado's own FAQ says Palworld mods aren't supported yet, which matches.

Quick test for any host: list `Pal/Binaries/Win64` over FTP. If you can't see it, you can't run this mod there.

Note that no global setting substitutes for this mod. `PalStomachDecreaceRate` is server-wide, and there is **no SAN setting in Palworld at all** — so a host that blocks file access blocks the only mechanism that exists.

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
| `status_file` | `nil` | Path for the status JSON, relative to `Pal/Binaries/Win64`. See below |
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

## Debugging and admin commands

You can't attach a debugger to a rented game server, so the mod is built to produce its own evidence.

### Admin commands

Two transports, because neither is guaranteed on every host. Same commands either way.

**Server console** — prefix with `stasis.`:

| Command | What it does |
|---|---|
| `stasis.status` | Health summary: version, mode, sweeps completed, uptime, players online, guilds suppressed, active overrides, write errors |
| `stasis.guilds` | Every guild with camp count, member count, `allOffline`, whether it's suppressed, its override state, and the reason it isn't protected |
| `stasis.pals <idprefix>` | Live per-Pal detail for one guild — stomach, decay rate, SAN, hunger type, sickness |
| `stasis.suppress <idprefix>` | Force this guild suppressed **now**, ignoring presence and the grace delay |
| `stasis.release <idprefix>` | Force this guild un-suppressed |
| `stasis.auto <idprefix>` | Clear the override, return to automatic behaviour |
| `stasis.sweep` | Run a sweep immediately instead of waiting for the timer |
| `stasis.help` | List the commands |

An id prefix is enough — `stasis.pals 78686694` works, and ambiguous prefixes are rejected rather than guessed.

Console registration uses UE4SS's `RegisterConsoleCommandHandler`, which is **not guaranteed to be reachable** from a headless Palworld server's own console. Each verb is registered independently and failure only logs, so the mod never breaks over it. Check the startup log for `console commands registered: N`.

**Command file** — works everywhere, including hosts with no usable console. Write a line into:

```
Pal/Binaries/Win64/ue4ss/Mods/GuildStasis/command.txt
```

using the panel's file editor or SFTP, **without** the `stasis.` prefix (e.g. just `status`). The mod consumes it on the next sweep and writes the reply to `command-out.txt`. Lines starting with `#` are ignored. The file is truncated when read, so a command runs exactly once.

`suppress` / `release` set a **per-guild manual override** that the sweep honours ahead of both presence and the grace delay. That's the intervention path when someone reports starving Pals and you don't want to wait out `grace_seconds` or edit config.

### Heartbeat

Every sweep logs one greppable line:

```
HEARTBEAT sweep=42 uptime=1260s guilds=6 camps=11 online=1 protected=5 pals_written=63 write_errors=0
```

If this **stops appearing**, the timer loop has died — the failure mode UE4SS's `LoopAsync` bug causes, where the mod stays installed and silently does nothing. It's the single most important thing to monitor, because nothing else about the server looks wrong when it happens.

### Status JSON

Set `status_file` in `config.lua` and the mod writes machine-readable state every sweep:

```lua
status_file = "ue4ss/Mods/GuildStasis/status.json",   -- relative to Pal/Binaries/Win64
```

It contains sweep count, uptime, mode flags, and per guild: `protected`, `camps`, `pals`, `offline_s`, `min_san`, `min_stomach_pct`, `sick`, and crucially **`decay_zero` vs `decay_nonzero`** — read back *after* writing.

That last pair is the real test. A guild marked `protected` with `decay_nonzero > 0` means the writes aren't landing, and no amount of log reading would tell you that.

### Operator tooling

```powershell
tools\palworld-modstatus.ps1 -HostName bisect
```

Pulls the log and status JSON over FTP or SFTP and judges four things: **loaded** (banner + hook), **alive** (heartbeat freshness, measured against the log's own newest line so server clock skew doesn't matter), **working** (are writes landing on protected guilds), and **clean** (errors). Prints a per-guild table.

Related: `palworld-check-platform.ps1` (can this host run the mod at all), `palworld-backup.ps1` / `nitrado-verify-backup.ps1` (back up and verify), `palworld-verify-host.ps1` (host + world identity), `palworld-migrate.ps1` (move a world between hosts).

## Risks to decide about

- **UE4SS issue #1091 is open.** Installing UE4SS on a Palworld dedicated server has been reported to make players reconnect as brand-new characters with fresh GUIDs. This is a risk of UE4SS itself, not this mod. Back up saves, set `DedicatedServerName` in `GameUserSettings.ini` **before** installing, then verify an existing character survives.
- **`bAutoResetGuildNoOnlinePlayers=True` deletes an offline guild's structures and base Pals** regardless of how well fed they are. This mod warns at startup but cannot stop it. Set it `False`.
- **`AutoTransferMasterThresholdDays`** transfers guild leadership after a long absence. This mod makes long absences viable, so it's more likely to fire.
- The world save records `bLastSavedUsingMod`. Modded crash reports are attributed to mods.

## Layout

```
Info.json                          first-party loader manifest (Type=Lua, IsServer=true)
enabled.txt                        UE4SS enable marker
Scripts/config.lua                 all configuration
Scripts/main.lua                   the mod
docs/RESEARCH.md                   verified ground truth, dead ends, and prior art
docs/TESTPLAN.md                   M1-M6 milestones
docs/V2-PLAN.md                    stop-work + raid immunity, and what's already ruled out

tools/setup-local-testserver.ps1   stand up a local Windows test server
tools/palworld-check-platform.ps1  can this host run the mod? RUN THIS BEFORE PAYING
tools/palworld-modstatus.ps1       is the mod alive and actually working, remotely
tools/palworld-backup.ps1          back up saves + config (FTP or SFTP)
tools/nitrado-verify-backup.ps1    verify a backup without re-downloading it
tools/palworld-verify-host.ps1     host capability + world identity in one run
tools/palworld-migrate.ps1         move a world between hosts
tools/palhost.ps1                  protocol-agnostic facade (FTP or SFTP)
tools/nitrado-lib.ps1              FTP primitives + save-integrity helpers
tools/sftp-lib.ps1                 SFTP primitives (needs Posh-SSH)
tools/*.config.ps1.example         host credential templates (real ones are gitignored)
tools/probe/                       throwaway discovery mods (not shipped)
```

Host credentials live in `tools/<name>.config.ps1`, which is gitignored. Copy an `.example` and fill it in. Each host gets its own file, and `Use-PalHostAny <name>` selects it.

`docs/RESEARCH.md` is worth reading before changing anything — it records what does **not** exist and what silently fails, which is most of the value.

## License

MIT. UE4SS is separately licensed and is not redistributed here.
