# v2 kickoff prompt

Paste this into a fresh session to start v2 work. It is written to be self-contained: everything needed is either here or in a file it names.

---

## Prompt

> I'm working on **Guild Stasis**, a server-side UE4SS Lua mod for Palworld 1.0 dedicated servers. v1 is finished and running in production. I want to build **v2**.
>
> **Read these first, in order:**
> - `README.md` — what the mod is, all 16 settings, the admin commands
> - `docs/RESEARCH.md` — verified API surface, and critically the "what does NOT exist" and "verified by failure" sections
> - `docs/V2-PLAN.md` — the v2 charter, including mechanisms already ruled out
> - `Scripts/main.lua` — the mod itself, ~1300 lines
>
> **What v1 does:** while every member of a guild is offline, it freezes that guild's base Pals' hunger and SAN, per-guild, leaving other guilds untouched. Two per-Pal writes keyed by our own FName: `SetDecreaseFullStomachRates(key, 0.0)` and `SetDisableNaturalUpdate(key, true)`, both reversed on login. Nothing is written to the save file. Proven in production on a 6-guild server: 93 Pals, 11 camps, zero write errors, and per-guild isolation confirmed by one guild releasing on login while five stayed suppressed.
>
> **What v2 must add, and why:** v1 leaves suppressed Pals *working*, so an offline base produces with no upkeep — better than being online, which is backwards. v2 makes stasis mean genuinely inert: **no hunger, no SAN loss, no exp, and no output**. Because parked Pals can't defend themselves, v2 must also prevent raids on a fully-offline guild. These two features are coupled: ship both or neither, since parked-but-raidable is worse than v1.
>
> **Feature 1 — stop work.** The only real lever found is `UPalBaseCampWorkerDirector.CurrentOrderType`, a writable int (default 0; 1/2/3 accepted and read back). Its enum meaning is unknown, and unlike everything v1 writes **it persists to the save**, so it needs explicit restore-on-boot. The fallback is appending every `EPalWorkSuitability` (1–13) to each Pal's `OffWorkSuitabilityList`, which is riskier because that list encodes player decisions and Pal instance IDs are reassigned across restarts, so restoring needs a fingerprint-keyed map persisted to disk. Exhaust `CurrentOrderType` first.
>
> **Feature 2 — raid immunity.** `bEnableInvaderEnemy` exists but is server-global. First establish whether raids even fire against a guild with zero members online — if they don't, this feature is unnecessary and Feature 1 ships alone.
>
> **Non-negotiables.** Read the safety rules at the top of `main.lua` and obey them — each is a reproduced crash. In particular: `IsValid()` before any member call, never read a SoftObjectProperty, use `SlotArray` not `GetSlots()`, never `LoopAsync`. And three traps that cost real time in v1:
> 1. **A non-nil result from `obj[name]` proves nothing.** UE4SS returns a `TrivialObject` wrapper for arbitrary names — `PleaseDoNotExist` looks identical to a real member. Presence must be established by extracting a real value. Verify with a deliberately fake name as a control.
> 2. **UE4SS does not surface UFunctions as Lua `function` values.** A `type(obj[name]) == "function"` guard silently skips every method. Call `obj[name](obj)` inside a pcall.
> 3. **Verify effects, not success messages.** Every write should be read back. Several v1 "successes" were false.
>
> **Test on a throwaway server, never production.** `tools/setup-local-testserver.ps1` stands up a local Windows one. The production server is on BisectHosting (SFTP 2022, `GameRoot = '.'`, UE4SS pre-installed) — do not experiment there; `CurrentOrderType` persists to the save and a bad value could outlive a restart.
>
> **Verification tooling already exists.** `tools/palworld-modstatus.ps1 -HostName <host>` judges loaded/alive/working/clean. The mod has a `HEARTBEAT` line per sweep, a status JSON, and an admin command channel (a polled `command.txt`, because panel consoles that proxy to REST/RCON cannot reach UE4SS console verbs).
>
> **Start by** answering the two questions that decide the design, in this order, before writing production code:
> 1. Do raids fire at all against a fully-offline guild? (If not, Feature 2 is moot.)
> 2. What do `CurrentOrderType` values 0–3 actually mean, and does any of them stop work? Test by writing each and watching `AI_Action` for the camp's Pals via `GET /v1/api/game-data` — `Worker_Working` / `BaseCampWorker_Approach` mean still working, `BaseCampWorker_Wait` / `BaseCampWorker_Sleep` mean idle.
>
> Add M7–M10 from `docs/V2-PLAN.md` as the acceptance criteria, and re-run M3–M5 before merging so v1's guarantees don't regress.

---

## Open decision that isn't v2

Independent of the above: **17 Pals on the production server are already sick** (11 in "Ben Dover's Doverson", 4 in "Butt Stuff", 2 in an unnamed guild) from before the mod existed. v1 prevents further harm but does not heal, and a hunger-frozen Pal never eats so the recovery path never fires — they will stay sick indefinitely.

A `cure_sickness_on_offline` flag (default off) clearing `WorkerSick` and `PhysicalHealth` on the offline transition would fix it. Not built: curing sickness is a gameplay benefit beyond "don't punish absence", so it's a fairness call for the server owner rather than a technical one.

## Where v1 stands

Passed M1–M6 except the durability soak, which is running in production now. Check the heartbeat is still climbing before declaring v1 complete.
