---
name: release
description: Cut and publish a Guild Stasis release: bump, changelog, tag, verify pipeline
---

# Release Guild Stasis

Takes the mod from "the code is ready" to "published on GitHub and Nexus", and writes the
changelog entry properly on the way.

The mechanical half is already scripted. `tools/bump-version.ps1` updates the version in the
three places it is written and scaffolds a changelog section. What it cannot do is write the
entry, because that needs reading the actual changes and knowing which of them a user would
care about. **That is the part this skill exists for.** If you finish a release and the
changelog is a list of commit subjects, the skill was not followed.

## When to Use

- The user says "release", "cut a release", "ship it", "publish a new version"
- The user asks to bump the version
- Work is finished and they want it on Nexus

Do **not** use this for deploying to a game server. That is a different job: upload
`Scripts/` over SFTP and restart. See `docs/PUBLISHING.md`.

## Instructions

### 1. Preflight

Refuse to continue and say why if any of these fail:

```bash
git status --porcelain          # must be empty
git rev-parse --abbrev-ref HEAD # must be main
git fetch origin && git status -sb   # must not be behind origin/main
```

A dirty tree is a hard stop. The bump has to be its own commit or the release commit becomes
unreadable.

### 2. Decide the bump, and justify it

Read what actually changed since the last tag, not just the subjects:

```bash
git tag -l 'v*' --sort=-v:refname | head -1
git log --no-merges --oneline <lastTag>..HEAD
git diff --stat <lastTag>..HEAD -- Scripts/ Info.json
```

Then propose a bump type **with a one-line reason**, and get confirmation:

- **patch** for fixes and docs only, no behaviour change a user would notice
- **minor** for new settings, changed defaults, or behaviour changes. A changed default is a
  minor, not a patch: it alters what happens on someone's server without them asking
- **major** only past 1.0, for something that breaks existing configs

Pay attention to `Scripts/` specifically. Changes confined to `docs/`, `tools/` or
`.github/` do not ship to users and rarely justify anything above a patch.

### 3. Bump

```powershell
.\tools\bump-version.ps1 -Type <patch|minor|major>
```

Add `-DryRun` first if unsure. Use `-Version x.y.z` for an explicit version.

### 4. Write the changelog entry

Open `CHANGELOG.md`, replace the whole scaffold section, and **delete the TODO line**. CI
fails while it is present, deliberately, because shipping a visible placeholder looks worse
than shipping nothing.

Read the diffs before writing. `git log` subjects tell you what was touched; the diffs tell
you what it means for a user.

Follow the voice already in the file. Look at the 0.2.0 and 0.3.0 entries. The pattern is:

```markdown
## x.y.z - YYYY-MM-DD

One or two sentences on what this release is, in plain terms.

### Fixed / Changed / Added        (only the sections that apply)

- **Short bold claim.** Then the explanation, including the mechanism if it is
  interesting, and a number if one was measured.

### Verified on a live dedicated server

- What was actually observed, with figures.

### Still unverified

- What is genuinely not known yet. Do not skip this section.
```

Rules that matter more than the format:

- **Lead with what changed for the user**, not with the internal cause. "Suppression took up
  to two sweep intervals" before "the grace check fails when offlineFor is zero".
- **Include measured numbers** where they exist: `70 -> 0`, `16s after going offline`,
  `112 Pals, zero write errors`. Vague improvement claims are worthless.
- **Keep the "Still unverified" section honest.** This project's credibility rests on saying
  what it does not know. If the soak test still has not run, say so.
- **Call out changed defaults loudly.** Someone upgrading will get different behaviour
  without asking for it, and that is the single most important thing in any entry.
- **No em dashes.** Team preference, applies everywhere.
- Never paste the commit list in as the entry.

### 5. Validate locally before tagging

Do not discover a validation failure after the tag exists. Check the same things CI does:

- `Info.json`: `DebugMode` false, `Author` set, `Thumbnail` exists as a tracked file
- version identical in `Info.json`, `Scripts/main.lua` `MOD_VERSION`, and the changelog heading
- `Scripts/config.lua` ships `mode = "run"`, `dry_run = false`,
  `force_suppress_for_testing = false`, `probe_write = nil`, `stop_work_when_offline = false`
- the changelog section for this version has no `TODO write this entry`

`force_suppress_for_testing = true` shipping to users would suppress every guild on their
server unconditionally, so treat that one as critical.

### 6. Commit, tag, push

```bash
git add -A
git commit -m "Release x.y.z"
git tag -a vx.y.z -m "vx.y.z"
git push origin main --follow-tags
```

**Order matters.** If this release depends on a change to `.github/workflows/release.yml`,
that change must be committed *before* the tag is created. A workflow run uses the workflow
as it existed at the tag, so a later fix does not apply retroactively. This has already
caused one failed release.

### 7. Watch the pipeline

```bash
gh run list --limit 3
gh run view <run-id>            # poll until completed
gh run view <run-id> --log-failed
```

Expect four jobs: `validate`, `build`, `github-release`, `nexus`. Report each one.

`nexus` skips unless `NEXUS_FILE_ID` is set as a repo variable. That is normal, not a
failure.

### 8. Confirm it landed

```bash
gh release view vx.y.z --json name,tagName,assets,url
gh run view <run-id> --log | grep -i 'uploaded successfully'
```

Then tell the user plainly: the release URL, the asset name and size, and whether Nexus
accepted the upload. If the Nexus job ran, remind them to check the mod page shows the new
version and that the old file was archived.

## Failure handling

| Symptom | Cause | Fix |
|---|---|---|
| `Input required and not supplied: api_key` | The workflow at that tag has no `environment: nexus`, so it looks for a repo secret that is not there | Commit the workflow fix, then move the tag onto it. Never expect a workflow change to apply to an existing tag |
| `gh release create` fails, release exists | Re-running a tagged build | Already fixed: the step creates or updates. If it recurs, check that fix survived |
| `the CHANGELOG.md entry is still the scaffold` | The TODO line was left in | Write the entry. This guard is working as intended |
| Version mismatch | A file was edited by hand instead of via the bump script | Re-run `bump-version.ps1 -Version x.y.z` |
| `tag vx.y.z already exists` | Version already released | Pick the next version, or move the tag deliberately if the shipped files are unchanged |

If a tag has to be moved, check first that nothing shippable changed, so the artifact stays
identical:

```bash
git diff --stat <tag>..HEAD -- Info.json enabled.txt thumbnail.png README.md CHANGELOG.md LICENSE Scripts/
```

Empty output means moving the tag is safe. Anything listed means it is a new version, not a
retag.

## Notes

- The version lives in three files plus the tag because `main.lua` logs its own version and
  cannot parse JSON. CI enforces that they agree.
- Never publish a version number twice with different contents. If the shipped files changed
  after a release, that is a new version.
- `docs/PUBLISHING.md` holds the surrounding detail: what ships, Nexus page fields, where the
  credentials live, and how to deploy to a server.
- The Nexus action is pinned to a beta tag and the API behind it is beta too, so an upload
  failure may be upstream rather than local.
