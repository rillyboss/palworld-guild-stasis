# Nexus Mods page copy

Paste-ready text for the mod page's "Full description", matching Nexus's section
template. Kept in the repo so it can be updated alongside a release instead of being
retyped into a browser.

Nexus's editor is WYSIWYG, so paste the body and apply the heading style to the five
section titles. Everything else is plain paragraphs, bullets and code blocks.

**Keep the first line first.** The single biggest support problem this mod will have is
people installing it client-side, and mod sites mix client and server mods in the same
listings. The warning has to be the first thing a visitor reads, not something they find
in Requirements after it has already not worked.

---

## Description

**This is a server-side mod. It installs on a Palworld dedicated server, not on your game client. Players install nothing.**

Palworld only simulates the world while at least one player is connected. On a shared server, that player is often not you.

Someone from another guild logs in and spends four hours grinding at their own base, or just parks themselves AFK. The whole time, your base is running too. Your Pals keep working, keep eating, and empty the feed box. Then they starve, get depressed, get sick, and start dying, with nobody there to notice or restock anything.

You log in to a wreck, and instead of playing you spend the session feeding Pals, curing sickness and undoing damage from hours you were not even present for. The upkeep gets charged to you based on someone else's playtime.

Guild Stasis fixes that per guild. Once every member of a guild has been offline for a few seconds, that guild's base Pals stop getting hungry, stop losing SAN, and stop working. Every other guild on the server carries on exactly as normal, because every write is per-Pal and scoped to one guild at a time.

Work stops too, not just hunger, and that part matters. A mod that only froze hunger would leave an offline base producing goods with no upkeep at all, which is better than being online and backwards. Here an offline base produces nothing: no crafting, no hauling, no farming, no XP.

Nothing is written to the save file. Every change is session state, so a crash, a hard kill or removing the mod entirely leaves no trace and needs no cleanup.

The point is to spend your playtime playing rather than mending.

## Installation instructions

Guild Stasis is a UE4SS Lua mod. UE4SS has to be installed on the server first, and this mod does nothing without it.

**1. Install UE4SS on the server** (skip if you already have it). Copy `dwmapi.dll` and the `ue4ss/` folder into:

```
<server>/Pal/Binaries/Win64/
```

**2. Install this mod.** Extract the download so you get:

```
<server>/Pal/Binaries/Win64/ue4ss/Mods/GuildStasis/
    enabled.txt
    Scripts/main.lua
    Scripts/config.lua
```

**3. Enable it.** Add one line to `ue4ss/Mods/mods.txt`:

```
GuildStasis : 1
```

Forgetting this line is the most common reason the mod appears to do nothing.

**4. Restart the server.** Configuration is read once at load and nothing is hot-reloaded, so every settings change needs a restart.

**5. Confirm it loaded.** Look in `ue4ss/UE4SS.log` for lines tagged `[STASIS]`. You should see the version banner, then one `HEARTBEAT` line per sweep:

```
HEARTBEAT sweep=42 uptime=2520s guilds=6 camps=11 online=1 protected=5 pals_written=112 speed_zero=112 write_errors=0
```

`speed_zero` should match `pals_written`. If it does, the mod is working on every suppressed Pal. If the heartbeat stops appearing entirely, restart the server: that is a known UE4SS timer bug, not a mod error.

All settings live in `Scripts/config.lua`, which is commented in full. The defaults are what runs in production.

## Main features

- **Hunger frozen.** Offline guilds' Pals stop draining the feed box. Verified as a hard stop, not a slowdown.
- **SAN frozen.** No depression spiral while you are away. A working Pal can lose around 19 SAN in ten minutes, so this is the harm that actually bites.
- **Work stopped, so no free production.** Effective work speed drops to zero across all thirteen work suitabilities: kindling, watering, planting, electricity, handiwork, gathering, lumbering, mining, oil, medicine, cooling, hauling and farming. Offline bases produce nothing and earn no XP.
- **Strictly per guild.** Every write is per-Pal, gated on the camp's own owning-guild check. Other guilds are never touched, verified in both directions on a live six-guild server.
- **Nothing written to the save.** All changes are session state and reverse on login. Uninstalling leaves no trace, and a crash mid-suppression self-heals on the next boot.
- **Reverses on login.** Each Pal returns to its own original work speed. No stored values, so nothing can be lost or mismatched.
- **Admin commands** over the server console or a polled command file, because many host panels cannot reach a real UE console. Query guilds and Pals, force a guild suppressed or released, change the grace period at runtime.
- **Built to be diagnosed remotely.** A heartbeat line per sweep, a machine-readable status JSON, and read-back verification so the log proves writes landed rather than that calls returned.

Tested on a live six-guild server: 11 camps, 112 Pals, zero write errors.

## Requirements

**UE4SS.** Use Okaetsu's `experimental-palworld` build. Pin the file hash rather than the release tag, because that tag is rolling and its date is misleading:

```
UE4SS-Palworld.zip
commit c838a8ac
SHA256 768A45718FBB9E429AC5CC3CE4A139A1B7B468BFF31B4A136AE483D725ACA1CA
```

UE4SS is not bundled here and is licensed separately.

**A Windows dedicated server.** Pocketpair: *"At this time, server-side mods work only on the dedicated server with Windows edition."* A Wine-hosted Windows build is fine, and is confirmed working on BisectHosting's mod-support product. A Linux build cannot run this. Judge by whether `Pal/Binaries/Win64` exists, not by what the panel says.

**Write access to `Pal/Binaries/Win64`, and the ability to restart.** This is the requirement that disqualifies most rented hosting, so check it before buying. Quick test: list `Pal/Binaries/Win64` over FTP or SFTP. If you cannot see it, you cannot run this mod there. Nitrado is confirmed incompatible, because its FTP exposes only `Pal/Saved`.

**No client mods, and no launch arguments.** Players connect with a completely vanilla game.

**One server setting to check.** `bAutoResetGuildNoOnlinePlayers=True` deletes an offline guild's structures and base Pals regardless of how well fed they are. This mod warns about it at startup but cannot stop it. Set it `False`, or the thing you installed this mod to prevent will happen anyway for a different reason.

## Shout outs

**Fenyn / Gamestorming**, for `palworld-priority-mod/docs/callpath-map.md`. An in-game verification log from a live 1.0 dedicated server: which hooks actually fire, the crash rules, and the finding that Pal instance IDs are not stable across restarts. This mod's safety rules come directly from that document, and it saved an enormous amount of time.

**JaredScar / Palworld-GuildPact**, for open-source per-guild server-side Lua and, more usefully, an explicit catalogue of what server-side Lua cannot do.

**SSyl / DynamicBaseCount**, for showing that a guild's full roster including offline members is readable via reflection.

**PalGuildLevelSync**, the closest precedent for writing nested save-parameter values from Lua on 1.0.

**TRRabbit / bastion-orp-plugin**, for the best published specification of a per-guild offline state machine, even though it is closed source.

**The UE4SS team, and Okaetsu** for the Palworld build that makes any of this possible.

And **Pocketpair**, for shipping first-party server mod support and making Lua a recognised install type, so none of this is a loophole.

---

## Media

Generated by `tools/make-art.py`, which writes into `media/`. Regenerate rather than
editing the PNGs, so the text stays correct when the mod changes.

| Slot | File | Size |
|---|---|---|
| Header | `media/header.png` | 1300x372, the size Nexus asks for |
| Images, 1st | `media/tile.png` | 1920x1080. **This one becomes the listing card** |
| Images, 2nd | `media/gallery-1-problem.png` | 1920x1080 |
| Images, 3rd | `media/gallery-2-what.png` | 1920x1080 |
| Images, 4th | `media/gallery-3-requirements.png` | 1920x1080 |
| Loader tile | `thumbnail.png` | 512x512, shipped inside the zip for the first-party loader |

**Order matters, and `tile.png` has to be first.** Nexus builds the listing card from the
first gallery image. The 512x512 `thumbnail.png` was used there originally and got
letterboxed with grey bars down both sides, because the card slot is landscape while the
thumbnail is square. It looked broken next to mods that filled their cards.

`tile.png` is 16:9 so it fills the card, and it is deliberately sparse: at listing size it
renders about 380px wide, a fifth of its real size, so it carries only the wordmark, the
Zzz and two short lines. The other three images are far too text-dense to survive that
reduction, which is why the tile is its own image rather than a reuse of one of them.

Check any change to it by downscaling to 384x216 and looking at the result. The first
version failed exactly there: the tallest Z descended into "SERVER-SIDE MOD" only once the
image was shrunk.

The gallery is deliberately typographic rather than screenshots. Gameplay stills say
little about a server-side mod, and the audience is server admins deciding whether they
can run it. So each image answers one question they actually have: what problem does this
solve, what does it do, and can my host support it.
