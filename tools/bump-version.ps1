<#
.SYNOPSIS
  Bump the mod version everywhere it is written, and scaffold a changelog entry.

.DESCRIPTION
  The version lives in three files plus the git tag, and all four have to agree or the
  release workflow fails validation. Keeping them in step by hand is exactly the kind of
  chore that gets half-done, so this does all of it in one go:

    Info.json          "Version"
    Scripts/main.lua   MOD_VERSION
    CHANGELOG.md       a new "## x.y.z - date" section
    git tag            created by you afterwards, from the printed command

  Why the changelog is scaffolded rather than generated. This project's changelog entries
  explain what was ruled out and what is still unverified, which is most of their value. A
  list of commit subjects cannot say "this was measured against a control" or "this is
  still unproven". So the commit subjects since the last tag are dropped in as raw
  material under a TODO marker, and you write the entry. The release workflow refuses to
  publish while that marker is still present, so a placeholder cannot ship.

.PARAMETER Type
  patch, minor or major. Ignored if -Version is given.

.PARAMETER Version
  An explicit version, e.g. 1.0.0. Overrides -Type.

.PARAMETER DryRun
  Print what would change and write nothing.

.EXAMPLE
  .\tools\bump-version.ps1 -Type patch
  .\tools\bump-version.ps1 -Version 1.0.0 -DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('patch', 'minor', 'major')][string] $Type = 'patch',
    [string] $Version,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Push-Location $repo
try {
    function Say  ($m) { Write-Host "  $m" }
    function Ok   ($m) { Write-Host "  [ok] $m"  -ForegroundColor Green }
    function Warn ($m) { Write-Host "  [!!] $m"  -ForegroundColor Yellow }
    function Die  ($m) { Write-Host "  [xx] $m"  -ForegroundColor Red; exit 1 }
    function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

    Head "Checking the working tree"
    # A bump should be its own commit. Mixing it with unrelated edits makes the release
    # commit hard to read and easy to get wrong.
    $dirty = (git status --porcelain) | Where-Object { $_ }
    if ($dirty -and -not $DryRun) {
        $dirty | ForEach-Object { Say $_ }
        Die "working tree is not clean. Commit or stash first, so the bump is its own commit."
    }
    Ok "clean"

    Head "Working out the next version"
    $infoPath = Join-Path $repo 'Info.json'
    $info = Get-Content $infoPath -Raw | ConvertFrom-Json
    $current = $info.Version
    if ($current -notmatch '^\d+\.\d+\.\d+$') { Die "Info.json Version '$current' is not x.y.z" }
    Say "current: $current"

    if ($Version) {
        if ($Version -notmatch '^\d+\.\d+\.\d+$') { Die "-Version '$Version' is not x.y.z" }
        $next = $Version
    }
    else {
        $p = $current.Split('.') | ForEach-Object { [int]$_ }
        switch ($Type) {
            'major' { $next = "$($p[0] + 1).0.0" }
            'minor' { $next = "$($p[0]).$($p[1] + 1).0" }
            'patch' { $next = "$($p[0]).$($p[1]).$($p[2] + 1)" }
        }
    }
    Say "next:    $next   ($(if ($Version) { 'explicit' } else { $Type }))"

    if ($next -eq $current) { Die "next version equals current" }
    if ((git tag -l "v$next")) { Die "tag v$next already exists" }

    Head "Collecting commits since the last release"
    # Deliberately not `git describe`: it writes to stderr and exits non-zero when no tags
    # exist, and PowerShell turns a native command's stderr into a terminating error under
    # ErrorActionPreference=Stop. `git tag -l` prints nothing and exits 0 instead.
    $lastTag = (git tag -l 'v*' --sort=-v:refname | Select-Object -First 1)
    if ($lastTag) {
        Say "since $lastTag"
        $subjects = @(git log --no-merges --pretty=format:'%s' "$lastTag..HEAD")
    }
    else {
        Warn "no previous tag found, using the whole history"
        $subjects = @(git log --no-merges --pretty=format:'%s')
    }
    if (-not $subjects) { Warn "no commits since $lastTag. Bumping anyway." }
    $subjects | ForEach-Object { Say "  - $_" }

    # -------------------------------------------------------------------- writes
    $mainPath = Join-Path $repo 'Scripts/main.lua'
    $changePath = Join-Path $repo 'CHANGELOG.md'

    $mainText = Get-Content $mainPath -Raw
    if ($mainText -notmatch 'MOD_VERSION\s*=\s*"([^"]+)"') { Die "MOD_VERSION not found in Scripts/main.lua" }
    $mainNew = [regex]::Replace($mainText, 'MOD_VERSION(\s*)=(\s*)"[^"]+"', "MOD_VERSION`$1=`$2`"$next`"", 1)

    $infoNew = (Get-Content $infoPath -Raw) -replace '("Version"\s*:\s*)"[^"]+"', "`$1`"$next`""

    $date = Get-Date -Format 'yyyy-MM-dd'
    $stanza = @()
    $stanza += "## $next - $date"
    $stanza += ""
    $stanza += "TODO write this entry, then delete this line. The release workflow will not"
    $stanza += "publish while it is here. Say what changed and why, and what is still unverified."
    $stanza += ""
    $stanza += "Commits since $(if ($lastTag) { $lastTag } else { 'the start' }), as raw material:"
    $stanza += ""
    foreach ($s in $subjects) { $stanza += "- $s" }
    $stanza += ""
    $changeText = Get-Content $changePath -Raw
    # Insert at an offset rather than using String.Replace: that has no count overload, so
    # there is no way to say "first occurrence only". Regex also keeps this agnostic about
    # whether the file uses CRLF or LF.
    $m = [regex]::Match($changeText, '(?m)^# Changelog[ \t]*\r?\n\r?\n')
    if (-not $m.Success) { Die "could not find a '# Changelog' header followed by a blank line" }
    $changeNew = $changeText.Insert($m.Index + $m.Length, (($stanza -join "`n") + "`n"))

    Head "Changes"
    Say "Info.json         Version      $current -> $next"
    Say "Scripts/main.lua  MOD_VERSION  $current -> $next"
    Say "CHANGELOG.md      new '## $next - $date' section with $($subjects.Count) commit(s)"

    if ($DryRun) {
        Head "Dry run, nothing written"
        Write-Host ""
        Write-Host (($stanza | Select-Object -First 12) -join "`n") -ForegroundColor DarkGray
        exit 0
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($infoPath, $infoNew, $enc)
    [IO.File]::WriteAllText($mainPath, $mainNew, $enc)
    [IO.File]::WriteAllText($changePath, $changeNew, $enc)
    Ok "three files written"

    Head "Next steps"
    Say "1. Edit CHANGELOG.md and remove the TODO line."
    Say "2. git add -A && git commit -m `"Release $next`""
    Say "3. git tag -a v$next -m `"v$next`" && git push origin main --follow-tags"
    Write-Host ""
    Say "The tag push runs validate, build, GitHub Release, then Nexus if NEXUS_FILE_ID is set."
}
finally { Pop-Location }
