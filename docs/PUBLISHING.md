# Publishing and deploying

Two separate jobs that get confused with each other:

- **Deploying** puts the mod on a server you control. Copy files, restart, verify.
- **Publishing** hands it to strangers who will install it wrong unless the packaging and the description stop them.

Most of the work is in the second one, and almost all of it is about the fact that this is a **server-side** mod.

## The one thing that will generate every support request

Palworld mod sites mix client mods and server mods in the same listings, and the overwhelming majority of visitors are looking for client mods. Someone will download this, drop it into their game install, see nothing happen, and leave a one-star comment.

So the description has to answer, above the fold, before anything else:

- This runs on a **dedicated server**, not on your game client.
- The server must be the **Windows** build. Pocketpair: *"At this time, server-side mods work only on the dedicated server with Windows edition."* A Wine-hosted Windows build is fine; a Linux build is not.
- You need **write access to `Pal/Binaries/Win64`**. Most rented hosting does not give you this, and that disqualifies more people than any other requirement.
- **UE4SS must already be installed.** This mod is a Lua mod that UE4SS loads; it does nothing on its own.
- Nothing is installed on player clients. Players need do nothing at all.

Point people at the "Hosting compatibility" section of the README and at `tools/palworld-check-platform.ps1`, which answers "can this host run it" before anyone pays for hosting.

## What ships

```
Info.json          first-party loader manifest
enabled.txt        UE4SS enable marker
Scripts/main.lua   the mod
Scripts/config.lua all configuration
README.md          the docs people will actually read
CHANGELOG.md
LICENSE
```

What does **not** ship: `tools/` (operator tooling, some of it host-specific), `docs/` (research notes and test plans, useful in the repo and noise in a release), and `tools/probe/` (throwaway discovery mods that write to a live game and must never reach a user).

**Never bundle UE4SS.** It is separately licensed and is not redistributed here. Declare it as a dependency and link to the exact build:

> Okaetsu's `experimental-palworld` release, asset `UE4SS-Palworld.zip`, commit `c838a8ac`, SHA256 `768A45718FBB9E429AC5CC3CE4A139A1B7B468BFF31B4A136AE483D725ACA1CA`

Tell people to pin the **hash, not the tag**. That release tag is rolling and its date (2025-02-20) is misleading.

## Package shapes

Two, because the two install routes are different and people will want whichever matches their host.

**Manual UE4SS mod** is the one that is tested end to end and the one that works on rented hosting with no Workshop integration. The zip should unpack to a single folder the user drops into `ue4ss/Mods/`:

```
GuildStasis/
  enabled.txt
  Scripts/main.lua
  Scripts/config.lua
```

They then add `GuildStasis : 1` to `ue4ss/Mods/mods.txt`. Say so in the description, because forgetting that line is the second most common failure after installing it client-side.

**First-party loader package** puts the same folder plus `Info.json` under `Mods/Workshop/`. This route is untested here, so label it as such rather than implying it works.

## Info.json rules

The schema is authoritative from Pocketpair's own `Models/ModInfo.cs`, which is more reliable than their docs page:

| Field | Rule |
|---|---|
| `PackageName` | Validated against `^[A-Za-z0-9]+$`. No spaces, no punctuation. `GuildStasis` |
| `Type` | Must be one of `Paks`, `Lua`, `LogicMods`, `UE4SS`, `PalSchema`. `Lua` here. Note `Scripts` is a target *folder*, not a Type |
| `IsServer` | `true` |
| `DebugMode` | **`false` for release.** `true` forces the loader to reinstall the mod on every launch, which is the dev loop |
| `Author` | Fill it in. An empty string looks abandoned |
| `Thumbnail` | Only include it if the file actually exists. A dangling path is worse than no field |
| `IsClient` | Does not exist. Web sources that mention it are wrong |

`ActiveModList` in `PalModSettings.ini` matches `PackageName`, not the folder name. Worth stating explicitly in the description, since it catches people out.

## Where to publish

[Nexus Mods](https://www.nexusmods.com/palworld) is the primary Palworld mod site and already hosts comparable server-side UE4SS mods, so there is precedent and an audience that understands the category. [CurseForge](https://www.curseforge.com/palworld) and Thunderstore also carry Palworld mods and are worth a mirror if you want the reach.

Check each site's current submission rules yourself at upload time. Category names, file-structure expectations and permission settings change, and a mod filed under the wrong category gets the wrong audience and the support requests that come with it.

GitHub Releases is worth doing regardless, even if the mod sites are the front door. Tag the version, attach the zip, and paste the changelog entry. It gives you a stable download URL that does not depend on any site's policies, and it is the natural home for a mod whose docs are this much of the product.

## Release checklist

Before tagging anything:

1. `Info.json`: `Version` bumped, `DebugMode: false`, `Author` set, `Thumbnail` either valid or absent
2. `Scripts/main.lua`: `MOD_VERSION` matches `Info.json`
3. `Scripts/config.lua` ships with safe defaults, specifically `mode = "run"`, `dry_run = false`, `force_suppress_for_testing = false`, `probe_write = nil`, `stop_work_when_offline = false`
4. `CHANGELOG.md` has an entry that says what changed and what is still unverified
5. The README's Status section reflects what is actually proven, not what is hoped
6. No probe mod is enabled anywhere in the shipped tree
7. Installed clean on a throwaway server from the zip alone, following only the published instructions

That last one matters most. Every install problem this mod will ever have comes from someone following the instructions exactly and still ending up somewhere different from you.

## Deploying to a server you run

```powershell
tools\palworld-backup.ps1     -HostName <name>      # first, always
# upload Scripts\main.lua and Scripts\config.lua over SFTP
# restart the server
tools\palworld-modstatus.ps1  -HostName <name>      # verify
```

`config.lua` and `main.lua` are read once at mod load, so a restart is required. Nothing is hot-reloaded.

After a restart, check three things in `modstatus` output:

- the banner shows the version you just uploaded, not the one before it
- `speed_zero` matches `pals_written` on the heartbeat, which proves the work-speed write is landing rather than merely being attempted
- `write_errors=0`

Then watch that the heartbeat keeps climbing for at least a couple of hours. UE4SS has a timer-death bug that appears between 40 minutes and 2 hours, and since v0.2.0 a dead timer leaves suppressed Pals frozen at zero work speed until the next restart. Nothing is lost, because none of it persists, but it is visible to players in a way that v0.1.0's failure mode was not.
