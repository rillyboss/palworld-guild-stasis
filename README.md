# Guild Stasis

A **server-side** mod for Palworld 1.0 dedicated servers. While every member of a guild is offline, that guild's base Pals stop getting hungry, stop losing SAN, and stop working. Every other guild on the server carries on exactly as normal.

Player clients stay 100% vanilla. Nothing is written to the save file. No launch arguments.

## The problem

Palworld only simulates the world while at least one player is connected. On a shared server, that player is often not you.

Someone from another guild logs in and spends four hours grinding XP at their own base, or just parks themselves AFK. The whole time, your base is running too. Your Pals keep working, keep eating, and empty the feed box. Then they starve. Then they get depressed, get sick, and start dying, and nobody is there to notice or restock anything.

You log in to a wreck. Instead of playing, you spend your session feeding Pals, curing sickness, and undoing damage caused by hours you were not even present for. The upkeep is charged to you based on someone else's playtime.

Palworld gives you no setting for this. `PalStomachDecreaceRate` applies to the entire server, so turning it down helps the AFK player as much as it helps you, and there is no SAN setting at all. The only place the problem can be fixed is per-Pal, one guild at a time, which is what this mod does.

The point is to spend your playtime playing rather than mending.

## What it does

Once every member of a guild has been offline for `grace_seconds`, that guild's base Pals get three writes, each keyed to an FName owned by this mod:

- hunger stops draining
- SAN stops draining
- work speed drops to zero, across all thirteen work suitabilities

All three reverse when any member logs back in. Nothing is written to the save file, so a crash, a hard kill, or uninstalling the mod leaves no trace and needs no cleanup.

The third write matters as much as the first two. Earlier versions froze hunger but left Pals working, which meant an offline base produced goods with no upkeep at all. That is better than being online, and backwards. Now an offline base produces nothing.

What it looks like in game: a suppressed Pal walks to its station and plays the work animation, but the progress bar never moves. After a while the worker AI gives up and the Pal goes to sleep, in daylight, and stays asleep until someone logs in.

Raids are deliberately not addressed. Raids appear not to fire against a guild with nobody online, which would make the feature unnecessary. That is unconfirmed and tracked as M9 in `docs/V2-PLAN.md`.

## Status

Verified on a live Windows dedicated server (app 2394010, build `24181105`, `v1.0.1.100619`).

Working and measured:

- **Hunger freeze is a hard stop.** `GetFullStomachDecreasingRate()` goes `1.0` to `0.0`. In one 8 minute window a suppressed Pal's stomach held at `71.698272705078`, identical to the digit, while a control Pal in another guild ate and worked normally.
- **SAN freeze holds.** Two Pals stayed bit-identical for 4.5 minutes against a measured 2.0/min drain baseline, with a player online and the Pals confirmed awake and working.
- **Work speed reaches zero for every suitability.** Not just handiwork: all thirteen read a final speed of `0`, including the three a Lamball actually has ranks in. Observed at a workbench with the progress slider frozen for over ten minutes.
- **Reversal is exact.** Each Pal returns to its own original speed, `70` and `77` respectively, because release removes the mod's multiplier rather than restoring a remembered number. There is nothing stored that could be lost or mismatched.
- **Per-guild isolation, proven in both directions.** Two Pals written for one guild, one for the other, never three, and each camp written only while its own guild was offline.
- **No XP either.** Over a ten minute window, two working Pals in an online guild each gained 96 XP and a level, while a suppressed Pal in another guild gained exactly zero. Same world, same ten minutes.
- **Nothing persists.** After a save and restart, every write is gone and the Pals read normal values.
- Zero write errors across roughly 130 write cycles.

For scale on what this prevents: during that same window the working control Pal's SAN fell from 98.2 to 79.4, about 19 points in ten minutes, while the suppressed Pal held at 100.0 and its stomach read `71.698272705078` at both ends of the window. SAN, not starvation, is the fast-moving harm.

Still unverified: durability beyond about 20 minutes, since no overnight soak has been run, and the full collateral scope of `SetDisableNaturalUpdate`.

## Requirements

- **A Windows dedicated server.** Not optional. Pocketpair's docs say *"At this time, server-side mods work only on the dedicated server with Windows edition."* UE4SS has no Linux support, and Palworld 1.0 under Proton has a documented save-corruption bug.
- **UE4SS**, Okaetsu's `experimental-palworld` build. Verified: `UE4SS-Palworld.zip`, commit `c838a8ac`, SHA256 `768A45718FBB9E429AC5CC3CE4A139A1B7B468BFF31B4A136AE483D725ACA1CA`. The release *tag* is dated 2025-02-20, but the tag is rolling, so pin the hash instead.
- **Write access to `Pal/Binaries/Win64`** (or the server root), and the ability to restart. This is the requirement that disqualifies most rented hosting, so check it first.

### Hosting compatibility

Check this before anything else. It is a hard gate.

You need to write files *outside* `Pal/Saved`. Both install routes do: the manual one needs `Pal/Binaries/Win64/dwmapi.dll` plus `ue4ss/`, and the official loader needs `Mods/PalModSettings.ini` plus `Mods/Workshop/`.

**A Wine-hosted Windows build counts as compatible.** What matters is the build, not the host OS. BisectHosting's mod-support Palworld product runs the Windows server under Wine in a Linux container (UE4SS logs `Z:\home\container\Pal\Binaries\Win64\...`), and UE4SS, this mod, and saving all behave normally there. That is verified in production. Do not judge by the panel or the advertised OS. Judge by whether `Pal/Binaries/Win64` exists.

One caveat if you land on a Wine host. There is a documented Palworld 1.0-under-Proton bug where the server commits exactly one save per boot and then silently wedges. It does not occur on Bisect's product, but it fails silently when it does occur, so watch `Level.sav` change size across a couple of autosaves before trusting a new host.

**Product variant matters more than provider.** The same Bisect account served the *Linux* build until it was reinstalled as the mod-support product. A provider being "compatible" means nothing on its own, so check the specific product you bought.

**Verified incompatible: Nitrado.** Its FTP exposes only `Pal/Saved`. Confirmed with retries, and the other directories do not appear in a listing of their own parent, so this is not a permissions quirk you can work around:

```
/palworld              -> only "Pal"
/palworld/Pal          -> only "Saved"
/palworld/Pal/Binaries -> not accessible
/palworld/Mods         -> not accessible
```

The server build itself is fine (`Pal/Saved/Config/WindowsServer/` confirms Windows edition) and `PalWorldSettings.ini` is writable, but there is nowhere to put UE4SS. Nitrado's own FAQ says Palworld mods are not supported yet, which matches.

Quick test for any host: list `Pal/Binaries/Win64` over FTP. If you cannot see it, you cannot run this mod there. And no global setting substitutes for the mod, because `PalStomachDecreaceRate` is server-wide and Palworld has no SAN setting at all, so a host that blocks file access blocks the only mechanism that exists.

## Install

Two routes. The manual one is tested end to end, and it is the one that works on rented hosting with no Workshop integration.

### Manual (tested)

1. Copy `dwmapi.dll` and the `ue4ss/` folder into `<server>/Pal/Binaries/Win64/`
2. Copy this repo's `Scripts/` folder and `enabled.txt` into `<server>/Pal/Binaries/Win64/ue4ss/Mods/GuildStasis/`
3. Add one line to `ue4ss/Mods/mods.txt`:
   ```
   GuildStasis : 1
   ```
4. Restart the server
5. Check `ue4ss/UE4SS.log` for `[STASIS]` lines

Leave `bGlobalEnableMod=false`. The official loader is not needed this way.

### Official mod loader (untested)

Palworld 1.0 ships a first-party loader that recognises UE4SS as an install type. Place this folder under `<server>/Mods/Workshop/`, then in `Mods/PalModSettings.ini`:

```ini
[PalModSettings]
bGlobalEnableMod=true
ActiveModList=UE4SS
ActiveModList=GuildStasis
WorkshopRootDir=<absolute path to Mods\Workshop>
```

`ActiveModList` matches `PackageName` from `Info.json`, not the folder name. Read the UE4SS package's own `Info.json` for its real name, which may be `UE4SS` or `UE4SSExperimentalPW`.

**Never install UE4SS both ways.** A manual copy in `Win64` alongside a loader-deployed one will crash the server, and disabling is not enough because leftover files still load.

## Configuration

### How to change settings

All settings live in one file. On the server that is:

```
Pal/Binaries/Win64/ue4ss/Mods/GuildStasis/Scripts/config.lua
```

Edit it with the host's file manager or over FTP/SFTP, then **restart the server**. The file is read once at mod load and nothing in it is hot-reloaded.

It is plain Lua, a table of `key = value,` pairs. Keep the trailing commas, quote strings, and use `true` / `false` / `nil` unquoted. A syntax error makes the mod refuse to load and say so in `UE4SS.log`, rather than running with half a config.

Two things can be changed at runtime without a restart, via the console or command file (see [Debugging and admin commands](#debugging-and-admin-commands)):

| Runtime command | Effect |
|---|---|
| `stasis.grace <seconds>` | Change `grace_seconds` immediately, including for guilds already counting down |
| `stasis.suppress` / `release` / `auto` `<guild>` | Per-guild override of the automatic decision |

Runtime changes do not survive a restart. Edit `config.lua` for that.

### Trigger

| Setting | Default | What it does |
|---|---|---|
| `mode` | `"run"` | `"run"` acts on offline guilds. `"recon"` is fully read-only, enumerating guilds, camps and Pals and logging everything while writing nothing. Use `"recon"` the first time you deploy to an unfamiliar server. |
| `dry_run` | `false` | With `true`, the mod makes every decision and logs exactly what it would write, but performs no writes. A safer first step than `"recon"`, because it also exercises the state machine. |
| `grace_seconds` | `15` | Seconds after the **last** guild member logs out before suppression is armed. Short is better here. The delay only avoids churn on brief disconnects, and it is not an anti-exploit measure, since freezing an offline guild's hunger is the entire point. At `60` a base was observed producing and levelling for a full minute after the last member left. `0` suppresses at the first sweep after a guild goes offline. |
| `sweep_interval_ms` | `60000` | Milliseconds between sweeps, and the setting that decides server load. See [What a sweep costs](#what-a-sweep-costs). Raising it does not delay release, which comes from the login hook, and only pushes out suppression by the same amount. Lowering it buys very little, because suppression already arms on a scheduled follow-up at the grace deadline rather than on the next interval. |
| `controller_refresh_ms` | `5000` | How often the cached `PlayerController` list is refreshed. Used to cross-check each guild's own online/offline flags, so a stale flag cannot cause a wrong decision. |

### What gets suppressed

| Setting | Default | What it does |
|---|---|---|
| `freeze_hunger` | `true` | Freezes hunger via `SetDecreaseFullStomachRates(key, 0.0)`. The highest-confidence lever, verified to drive the observed decay rate from `1.0` to `0.0`. |
| `sanity_mode` | `"natural_update"` | How SAN is handled. `"natural_update"` is the verified option (`SetDisableNaturalUpdate`, a plain reflected UFUNCTION). `"none"` leaves SAN alone. `"disable_flags"` and `"topup"` are alternatives kept for hosts where the verified one misbehaves. See `docs/RESEARCH.md`. |
| `zero_work_speed` | `true` | Drops each suppressed Pal's effective work speed to zero, so an offline base produces nothing. Inserts a `0.0` entry under the mod's own FName key into `SaveParameter.CraftSpeedRates`, the same container shape and the same "0.0 wins" rule as the hunger lever. Verified `70` to `0` and back, across all thirteen work suitabilities. Session state only, so nothing persists and no restore map is needed. |
| `topup_once_on_offline` | `true` | Tops SAN up once on the offline transition. A hunger-frozen Pal never eats, so the eat-driven SAN recovery path never fires again, and a guild that logs off with miserable Pals would otherwise stay miserable forever. Set `false` if you consider it too generous. |
| `topup_below_ratio` | `0.9` | Only used when `sanity_mode = "topup"`. Tops up when SAN falls below this fraction of the Pal's maximum. Deliberately a ratio: `MaxFullStomach` varies from 100 to 600 by species, so absolute thresholds are wrong. |
| `stop_work_when_offline` | `false` | **Superseded by `zero_work_speed`. Leave off, and never enable both.** The older route, which rewrites each Pal's off-work job list. It writes to the save file, its restore path is unimplemented, and getting it wrong silently destroys players' per-Pal work settings. Kept only as a fallback in case a game patch breaks the `CraftSpeedRates` route. |

### Diagnostics

| Setting | Default | What it does |
|---|---|---|
| `status_file` | `nil` | Path for the machine-readable status JSON, **relative to `Pal/Binaries/Win64`** (the server's working directory). Recommended: `"ue4ss/Mods/GuildStasis/status.json"`. This is what `palworld-modstatus.ps1` reads to prove writes are landing. |
| `verbose_pals` | `false` | Log every per-Pal write with before and after values. Noisy on a busy server, but it is the per-guild isolation evidence, since every write line carries its camp id. Worth enabling for a first live run. |
| `verbose_resolve` | `true` | Log each identifier the mod resolves at startup, one line each, so a failure names itself instead of surfacing later as a mysterious nil. |
| `check_server_settings` | `true` | Read `PalWorldSettings.ini` at startup and warn about settings that would undo the mod, chiefly `bAutoResetGuildNoOnlinePlayers`, which deletes an offline guild's base Pals outright. |

### Testing only

| Setting | Default | What it does |
|---|---|---|
| `force_suppress_for_testing` | `false` | Suppresses **every** guild unconditionally, ignoring presence and grace. Exists because on a single-account test server you cannot have your guild offline while the world is still being simulated. **Never ship this enabled.** It defeats the entire per-guild premise. |
| `probe_write` | `nil` | Runs one write-capability probe against one Pal and logs the result: `"ufunction_flag"`, `"nested_scalar"`, `"nested_tmap"`, or `"nested_tarray"`. Use exactly one per server boot. A native access violation here cannot be caught by `pcall`, so mixing probes makes a crash impossible to attribute. |

## How it works

A sweep every 30 seconds:

1. Enumerate guilds from `UPalGroupManager.GuildMap`, where the key *is* the guild FGuid
2. Decide which guilds have every member offline, cross-checking the guild's own `EPalGuildPlayerStatus` against live `PlayerController`s
3. After the grace delay, for each of that guild's base Pals:
   ```lua
   param:SetDecreaseFullStomachRates(FName("GuildStasis_Offline"), 0.0)
   param:SetDisableNaturalUpdate(FName("GuildStasis_Offline"), true)
   -- plus a 0.0 entry in SaveParameter.CraftSpeedRates under the same key
   ```
4. On login, reverse all three

State is recomputed from live objects every sweep and applied idempotently, so it self-heals after a restart and nothing is keyed on Pal instance IDs, which are reassigned across restarts.

### What a sweep costs

One sweep does two things that scale differently:

- **One `FindAllOf("PalBaseCampModel")`**, which walks the entire UObject array. This scales with the size of the *world*, not the number of guilds, so it grows as players build.
- **A read, write and verify on every Pal of every suppressed guild.** On a 6-guild, 11-camp, 100-Pal server that is roughly 300 reflected writes per sweep.

At the default 60 seconds that is a background cost nobody notices. It is the one setting worth tuning if a large server shows CPU load, and raising it is close to free because of how the two latencies actually work.

### How fast it reacts

Release does not wait for a sweep. The login hook fires on possession and queues follow-up sweeps at 2, 5, 10 and 20 seconds, because the guild's own status flag flips slightly after possession and the hook's immediate sweep would otherwise see the player as still offline.

Suppression is the direction with a subtlety. The sweep that *notices* a guild has gone offline cannot suppress it, because at that instant the guild has been offline for zero seconds and the grace check fails. Left alone, suppression would land on the *next* sweep, making the worst case `sweep_interval * 2`, which is two minutes at the default. So the noticing sweep schedules one follow-up at the grace deadline instead:

```
worst case = sweep_interval + grace_seconds     about 75s at the defaults
best case  = grace_seconds                      if the logout lands just before a sweep
```

That is why lowering `sweep_interval_ms` buys much less than it looks like it should, and why raising it is cheap.

Camps are found with `FindAllOf("PalBaseCampModel")` and matched on the camp's own `GetGroupIdBelongTo()`. That ownership check is the per-guild guarantee: a camp that does not claim this guild is never touched.

Login is event-driven through a hook on `ServerAcknowledgePossession`, but logout is not, because no reflected logout event exists on this build. The hook fires on possession slightly before the guild's own status flag flips to `Online`, so the hook also queues follow-up sweeps at 2, 5, 10 and 20 seconds. Without them, release waited for the next scheduled sweep and players saw 10 to 15 seconds of idle Pals after logging in.

The sweep is not just a fallback for the missing logout event. It is what catches Pals that appear inside a suppressed guild, since eggs hatch while nobody is online, and it re-applies writes that the game itself may have cleared. Palworld manages `CraftSpeedRates` too, and writes its own `Sick` entry into the same container. Events give low latency; the sweep gives correctness.

## Debugging and admin commands

You cannot attach a debugger to a rented game server, so the mod is built to produce its own evidence.

### Admin commands

Two transports, because neither is guaranteed on every host. Same commands either way.

**Server console**, prefixed with `stasis.`:

| Command | What it does |
|---|---|
| `stasis.status` | Health summary: version, mode, sweeps completed, uptime, players online, guilds suppressed, active overrides, write errors |
| `stasis.guilds` | Every guild with camp count, member count, `allOffline`, whether it is suppressed, its override state, and the reason it is not protected |
| `stasis.pals <idprefix>` | Live per-Pal detail for one guild: stomach, decay rate, SAN, hunger type, sickness, work speed, level and XP |
| `stasis.suppress <idprefix>` | Force this guild suppressed now, ignoring presence and the grace delay |
| `stasis.release <idprefix>` | Force this guild un-suppressed |
| `stasis.auto <idprefix>` | Clear the override and return to automatic behaviour |
| `stasis.grace` | Show the current `grace_seconds` |
| `stasis.grace <seconds>` | Change it immediately (0 to 86400), including for guilds already counting down. Runtime only, so edit `config.lua` to persist |
| `stasis.sweep` | Run a sweep immediately instead of waiting for the timer |
| `stasis.help` | List the commands |

An id prefix is enough, so `stasis.pals 78686694` works, and ambiguous prefixes are rejected rather than guessed.

Console registration uses UE4SS's `RegisterConsoleCommandHandler`, and it registers successfully (`console commands registered: 9` in the startup log). **Most host panels cannot reach it.** If your panel's console proxies to Palworld's admin API rather than UE's exec layer, you get:

```
[RestAPI]: Command not found in RestAPI Command List, attempting RCON...
[RCON]: Unknown command
```

That is confirmed on BisectHosting, and it is a property of that whole class of panel rather than one host. On such a server, use the command file instead. The console verbs are only usable where a real UE console exists.

**Command file**, which works everywhere. Write a line into:

```
Pal/Binaries/Win64/ue4ss/Mods/GuildStasis/command.txt
```

using the panel's file editor or SFTP, **without** the `stasis.` prefix, so just `status`. The mod consumes it on the next sweep and writes the reply to `command-out.txt`. Lines starting with `#` are ignored, and the file is truncated when read, so a command runs exactly once.

`suppress` and `release` set a per-guild manual override that the sweep honours ahead of both presence and the grace delay. That is the intervention path when someone reports starving Pals and you do not want to wait out `grace_seconds` or edit config. Remember to clear it with `auto` afterwards, because an override left in place means that guild never suppresses again.

### Heartbeat

Every sweep logs one greppable line:

```
HEARTBEAT sweep=42 uptime=1260s guilds=6 camps=11 online=1 protected=5 pals_written=63 speed_zero=63 write_errors=0
```

If this stops appearing, the timer loop has died, which is the failure mode UE4SS's `LoopAsync` bug causes: the mod stays installed and silently does nothing. Monitor this above everything else, because nothing else about the server looks wrong when it happens.

`speed_zero` should match `pals_written`. If it lags, the work-speed write is not landing even though the mod thinks it succeeded.

### Status JSON

Set `status_file` in `config.lua` and the mod writes machine-readable state every sweep:

```lua
status_file = "ue4ss/Mods/GuildStasis/status.json",   -- relative to Pal/Binaries/Win64
```

It carries sweep count, uptime, mode flags, and per guild: `protected`, `camps`, `pals`, `offline_s`, `min_san`, `min_stomach_pct`, `sick`, and the two read-back pairs that actually matter, `decay_zero` against `decay_nonzero` and `speed_zero` against `speed_nonzero`.

Those pairs are the real test, because they are read back *after* writing. A guild marked `protected` with `decay_nonzero > 0` means the writes are not landing, and no amount of log reading would tell you that.

### Operator tooling

```powershell
tools\palworld-modstatus.ps1 -HostName bisect
```

Pulls the log and status JSON over FTP or SFTP and judges four things: **loaded** (banner plus hook), **alive** (heartbeat freshness, measured against the log's own newest line so server clock skew does not matter), **working** (are writes landing on protected guilds), and **clean** (errors). Prints a per-guild table.

Related: `palworld-check-platform.ps1` (can this host run the mod at all), `palworld-backup.ps1` and `nitrado-verify-backup.ps1` (back up and verify), `palworld-verify-host.ps1` (host and world identity), `palworld-migrate.ps1` (move a world between hosts).

## Risks to decide about

- **UE4SS issue #1091 is open.** Installing UE4SS on a Palworld dedicated server has been reported to make players reconnect as brand-new characters with fresh GUIDs. That is a risk of UE4SS itself rather than this mod. Back up saves, set `DedicatedServerName` in `GameUserSettings.ini` before installing, then verify an existing character survives.
- **`bAutoResetGuildNoOnlinePlayers=True` deletes an offline guild's structures and base Pals** regardless of how well fed they are. This mod warns at startup but cannot stop it. Set it `False`.
- **`AutoTransferMasterThresholdDays`** transfers guild leadership after a long absence. This mod makes long absences viable, so it becomes more likely to fire.
- If the sweep timer dies while a guild is suppressed, its Pals stay frozen at zero work speed until the server restarts. Nothing is lost, because none of it persists, but it is a visible outage rather than the silent no-op a dead timer used to cause. The heartbeat is the early warning.
- The world save records `bLastSavedUsingMod`, and modded crash reports are attributed to mods.

## Layout

```
Info.json                          first-party loader manifest (Type=Lua, IsServer=true)
enabled.txt                        UE4SS enable marker
Scripts/config.lua                 all configuration
Scripts/main.lua                   the mod
docs/RESEARCH.md                   verified ground truth, dead ends, and prior art
docs/TESTPLAN.md                   M1-M6 milestones
docs/V2-PLAN.md                    the stop-work mechanism, three ruled-out alternatives, and raids
docs/PUBLISHING.md                 packaging, release checklist, and deploying to a server

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

`docs/RESEARCH.md` is worth reading before changing anything. It records what does not exist and what silently fails, which is most of its value.

## License

MIT. UE4SS is separately licensed and is not redistributed here.
