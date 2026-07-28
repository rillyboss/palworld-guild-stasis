# Guild Stasis

Server-side UE4SS Lua mod for Palworld 1.0 Windows dedicated servers. While every member of
a guild is offline, that guild's base Pals stop getting hungry, stop losing SAN, and stop
working. Per guild, so other guilds are untouched. Nothing is written to the save file.

Live on Nexus as mod 4512, and running in production on a six-guild server.

## Safety rules, non-negotiable

Each of these is a reproduced crash on this engine build. Do not "simplify" them away.

1. **`alive(obj)` before any member call.** UE4SS returns a wrapper, not nil, for null
   UObject properties, and pcall **cannot** catch the native access violation from calling a
   method on a stale wrapper. `IsValid()` is safe to call on a stale wrapper.
2. **Never read a SoftObjectProperty** from Lua. It crashes inside UE4SS.
3. **Use the `SlotArray` property, never `GetSlots()`.** The latter returns by value and
   fails to marshal.
4. **Never `LoopAsync`.** It corrupts UE4SS's shared engine-tick callback list and silently
   kills timers for every Lua mod after 40 minutes to 2 hours. Chain one-shot
   `ExecuteWithDelay` instead.
5. **Wrap every NameProperty argument in `FName(...)`.** A bare Lua string makes UE4SS
   dereference null at offset `0x70`, and pcall cannot catch it: the whole server dies. Cost
   six crashes to find. See `freezeHunger()` for the correct form.
6. `FindAllOf` scans the entire UObject array. Cache it, never call it per-tick.
7. Skip `Default__` CDOs from every `FindAllOf` result.

## Verification discipline

This project's history is mostly false positives that looked like findings. Before believing
anything:

- **A non-nil result from `obj[name]` proves nothing.** UE4SS hands back a `TrivialObject`
  wrapper for arbitrary names, so `PleaseDoNotExist` looks identical to a real member.
  Presence requires extracting a real value, verified against a deliberately fake control.
- **UE4SS does not surface UFunctions as Lua `function` values.** A
  `type(obj[name]) == "function"` guard silently skips every method.
- **Enumerate, do not guess.** `UStruct:ForEachProperty` / `ForEachFunction` work, and a
  UFunction is itself a UStruct so `ForEachProperty` on one yields its parameters. Two traps:
  they return a class's **own** members only, so walk the superclass chain, and keep "the
  call failed" distinct from "zero members".
- **A successful enum readback proves the write landed, not that the value means anything.**
  UE stores the raw byte.
- **Verify effects, not success messages.** Read every write back.
- **A freeze test needs a control that is demonstrably moving.** "The value did not change"
  is worthless if nothing was changing anywhere. This invalidated two XP tests.
- **Change one variable per boot** when hunting a native crash, and bracket suspect code with
  before/after log markers. "What logged last" does not locate a native crash.

## Releasing

Use the `release` skill. Say "cut a release" and it handles bump, changelog, tag, and
verification. It carries the failure modes already hit.

Key points if doing it by hand:

- `tools/bump-version.ps1 -Type patch|minor|major` updates the version in all three places.
- The changelog is written by a human, never generated from commit subjects. CI refuses to
  publish while the scaffold's TODO line is present.
- A workflow run uses the workflow **as it existed at the tag**. A later fix does not apply
  retroactively, so commit workflow changes before tagging.
- A changed default is a **minor**, not a patch. It alters behaviour on someone's server
  without them asking.
- Never publish one version number twice with different contents.

## Decisions already made, do not re-litigate

- **No sickness cure.** Healing is a benefit beyond "do not punish absence".
- **No SAN top-up.** `topup_once_on_offline` ships `false`. Freeze everything, restore
  nothing.
- **No raid feature.** On the view that raids do not fire against a fully offline guild.
  Unverified, and the owner's call. `docs/V2-PLAN.md` records the cheap test.
- **Three stop-work mechanisms were eliminated on evidence** before `CraftSpeedRates` worked:
  `CurrentOrderType` (a battle order that persists to the save), Pal Box parking (no
  reflected mutator anywhere in the container chain), and `OffWorkSuitabilityList` (silent
  failure mode). Read `docs/V2-PLAN.md` before proposing a fourth.

## Where things are

```
Scripts/main.lua       the mod
Scripts/config.lua     all configuration, commented in full
docs/RESEARCH.md       verified ground truth, dead ends, what does NOT exist. Read first
docs/V2-PLAN.md        the stop-work mechanism and three ruled-out alternatives
docs/TESTPLAN.md       M1-M6 milestones
docs/PUBLISHING.md     packaging, release, credentials, server deployment
docs/MOD-PAGE.md       Nexus page copy and which image goes in which slot
tools/probe/           throwaway discovery mods. NEVER ship these, they write to a live game
```

`docs/RESEARCH.md` is the most valuable file: it records what does not exist and what fails
silently, which is most of the work.

## Servers

- **Local test server**: `D:\SteamLibrary\steamapps\common\PalServer`, already has UE4SS.
  Retail binary at `Pal\Binaries\Win64\PalServer-Win64-Shipping.exe`. `grep -a -b -o` over
  it finds reflection names in seconds, and reading a name's neighbourhood identifies its
  owning class, because UE registers a class's members contiguously.
- **Production**: BisectHosting, SFTP port 2022, `GameRoot = '.'`, config in
  `tools/bisect.config.ps1` (gitignored). Verify with
  `tools\palworld-modstatus.ps1 -HostName bisect`. **Never experiment there.**
- Bisect appears to rotate the REST admin password on restart, so REST breaks after one.

## Open items

- **No overnight soak.** Longest clean run is 71 minutes over 72 sweeps at a steady 59.4s
  cadence. UE4SS's timer-death bug appears between 40 minutes and 2 hours. Since 0.2.0 a dead
  timer leaves Pals frozen at zero work speed until a restart, which players can see.
- **Sick Pals while offline**, under investigation. See `docs/V3-KICKOFF.md`.
- The sweep could be split into a cheap presence poll plus a rare reconciliation pass. Logout
  cannot be event-driven: no reflected logout event exists.
