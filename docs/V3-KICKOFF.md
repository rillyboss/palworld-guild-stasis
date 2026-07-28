# Investigation: Pals getting sick while their guild is offline

Paste the prompt below into a fresh session. Everything it needs is either here or in a file
it names.

---

## Prompt

> I run **Guild Stasis**, a server-side UE4SS Lua mod for Palworld 1.0 dedicated servers.
> It is live and working: while every member of a guild is offline, that guild's base Pals
> have hunger frozen, SAN frozen, and work speed set to zero. Read `CLAUDE.md` first, then
> `docs/RESEARCH.md`, then `Scripts/main.lua`.
>
> **The observation.** Between two checks of the production server, the count of sick Pals
> rose from 17 to 21. One guild went from 0 sick to 3, another from 0 to 1. The 17 pre-date
> the mod entirely. The 4 new ones do not.
>
> **Do not repeat my mistake.** When I first saw this I said it happened "while people were
> online and playing". I had no evidence for that. The window between the two observations
> contained both online and offline time, and I assumed. Establish *when* each Pal became
> sick before theorising about why.
>
> **Why this matters enough to investigate properly.** The mod freezes hunger and SAN, which
> are the two documented routes into `WorkerSick`. If Pals are getting sick anyway while
> suppressed, then either the freeze does not cover what we think it covers, or the mod is
> *causing* it. The second possibility is the alarming one and it has a plausible mechanism,
> below. The mod is published on Nexus, so if it is causing sickness that is a regression to
> fix before more people install it.
>
> **Hypotheses, roughly in order of how much they would matter:**
>
> 1. **Zero work speed means work never completes, and the sickness trigger is duration-based
>    rather than completion-based.** A Pal assigned a job it can never finish may accumulate
>    overwork forever. Supporting detail: `UPalBaseCampWorkerDirector` has a
>    `WorkerEventTickCount`, the save parameter carries `BaseCampWorkerEventType` and
>    `BaseCampWorkerEventProgressTime`, and `UPalGameSetting` has
>    `BaseCampWorkerEventTriggerProbability` and `BaseCampWorkerSanityWarningThreshold`. So
>    worker events tick on a counter and fire on probability. If that counter advances while
>    a Pal fruitlessly attempts work, we made it worse. Note also
>    `EPalBaseCampWorkerEventType::OverworkDeath` exists.
> 2. **The owner's hypothesis: Pals gathering from map resource nodes rather than working at
>    a station.** Sulfur and quartz veins sit outside the base. A gatherer may travel, fail
>    to complete, and loop, where a Pal at a workbench eventually gives up and sleeps, which
>    was observed. Supporting detail: `BaseCampExtraWorkAreaRange`,
>    `BaseCampWorkerDistancePickableItem`, and a string
>    `WorkerPalMove_FailedApproachToFacilityAndRespawnFromPalBox` all exist, so there is a
>    failure-to-approach path.
> 3. **`SetDisableNaturalUpdate` does not cover sickness.** Its collateral scope is recorded
>    as uncatalogued in `docs/RESEARCH.md`. SAN could be frozen while the sickness pathway
>    ticks independently.
> 4. **The Pals got sick while online**, and the mod is irrelevant. Perfectly possible, and
>    the null hypothesis. Rule it in or out with timestamps, not vibes.
>
> **The data already exists.** Production runs with `verbose_pals = true`, so
> `Pal/Binaries/Win64/ue4ss/UE4SS.log` carries a line per Pal per sweep including `sick=`,
> and a `HEARTBEAT` line per sweep carrying `online=` and `protected=`. That is a time series.
> Pull the log with `tools\palworld-modstatus.ps1 -HostName bisect` or over SFTP, then:
>
> - For each camp and slot, find the sweep where `sick=` changed from 0 to non-zero.
> - For that timestamp, read the nearest heartbeat: was the guild `protected`, and how many
>   players were `online`?
> - A sick transition while `protected=true` implicates the mod. One while the guild was
>   online exonerates it.
>
> The `sick=` value is an `EPalBaseCampWorkerSickType`, in declaration order from the binary:
> `None, Cold, Sprain, Bulimia, GastricUlcer, Fracture, Weakness, DepressionSprain,
> DisturbingElement`. So `sick=4` is GastricUlcer. Which type appears may itself point at the
> cause, since a sprain or fracture suggests movement and an ulcer suggests eating.
>
> **Also worth checking:** whether the affected Pals share a work suitability. If every newly
> sick Pal has Mining or Gathering and none are pure Handcraft, that supports hypothesis 2
> strongly. `stasis.pals <idprefix>` via the command file dumps per-Pal detail for one guild.
>
> **Rules.** Read `CLAUDE.md`'s safety rules and verification discipline and follow them.
> In particular: a freeze test needs a control that is demonstrably moving, enumerate rather
> than guess member names, and wrap NameProperty arguments in `FName()`. Test on the local
> throwaway server at `D:\SteamLibrary\steamapps\common\PalServer`, never on production.
>
> **Start by** settling hypothesis 4, because it is cheap and it determines whether any of
> the others are worth pursuing. Extract the sick-transition timeline from the production log
> and tell me, with timestamps, whether any Pal became sick while its guild was suppressed.
> Do not start reading engine internals until that question is answered.

---

## Context the prompt assumes

**What was observed, exactly.** Two `palworld-modstatus.ps1` runs against production:

```
2026-07-27 23:40   v0.1.0   Kingdom of Tidds 0   Butt Stuff 4   Ben Dover's 11   others 2   = 17
2026-07-28 20:47   v0.3.0   Kingdom of Tidds 3   Butt Stuff 4   Ben Dover's 11   others 3   = 21
```

Between those, the server was restarted several times, v0.2.0 and v0.3.0 were deployed, and
players were online and offline at various points. So the window is contaminated, which is
exactly why the per-sweep log matters more than these two snapshots.

**One piece of counter-evidence for hypothesis 1.** A Pal watched at a workbench under
suppression eventually stopped trying and fell asleep in daylight. If Pals reliably give up,
they are not accumulating overwork. But a gatherer heading for a distant node may behave
differently from a Pal standing at a bench, which is what makes the owner's hypothesis worth
taking seriously rather than dismissing.

**If the mod turns out to be the cause**, the likely fixes in rough order of preference:

1. Suppress the worker event system as well, if a reflected lever exists for it.
2. Unassign work rather than slowing it, which is the `OffWorkSuitabilityList` route already
   ruled out on the grounds that its failure mode is silent config loss. That ruling would
   need revisiting if the alternative is making Pals ill.
3. Clear `WorkerSick` on suppressed Pals, which the owner has explicitly declined as a
   gameplay benefit. Declining to heal pre-existing sickness is a different question from
   declining to undo harm the mod itself caused, so this is worth re-asking rather than
   treating as settled.
