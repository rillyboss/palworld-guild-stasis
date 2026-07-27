<#
.SYNOPSIS
  Verify an existing Palworld backup without re-downloading it.

.DESCRIPTION
  Three independent checks, so a pass means something:

    1. Structural  - every .sav parses as a Palworld save container
                     (magic PlZ/PlM/CNK, payload not truncated). This is the check
                     that actually matters, and it needs no network.
    2. Presence    - Level.sav, LevelMeta.sav and at least one player save exist.
    3. Freshness   - each file's size is compared against a FRESH remote stat.
                     A difference here is usually benign: the server autosaves, so
                     a file can legitimately change after it was copied. It is
                     reported as DRIFT, not corruption, and only matters if you
                     wanted a point-in-time capture.

  Why this exists: the first real backup "failed" only because Level.sav was
  compared against a size from a listing taken minutes earlier. The download was
  byte-perfect. Size-vs-stale-listing is the wrong test on a live server.

.PARAMETER BackupDir
  A backup folder produced by nitrado-backup.ps1. Defaults to the newest one.

.PARAMETER SkipRemote
  Structural checks only, no network.

.EXAMPLE
  .\nitrado-verify-backup.ps1
  .\nitrado-verify-backup.ps1 -SkipRemote
#>
[CmdletBinding()]
param(
    [string] $BackupDir,
    [switch] $SkipRemote
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'nitrado-lib.ps1')

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  [ok] $m"    -ForegroundColor Green }
function Warn ($m) { Write-Host "  [!!] $m"    -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "  [XX] $m"    -ForegroundColor Red }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

if (-not $BackupDir) {
    $root = Join-Path $PSScriptRoot '..\backups'
    if (-not (Test-Path $root)) { throw "No backups directory found." }
    $BackupDir = (Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
}
if (-not (Test-Path $BackupDir)) { throw "Backup not found: $BackupDir" }

Head "Backup"
Say $BackupDir
$summaryPath = Join-Path $BackupDir 'summary.json'
if (Test-Path $summaryPath) {
    $s = Get-Content $summaryPath -Raw | ConvertFrom-Json
    Say "taken   : $($s.TakenUtc)"
    Say "server  : $($s.ServerName)  world $($s.WorldGuid)"
}

$files = Get-ChildItem $BackupDir -Recurse -File
$saves = @($files | Where-Object { $_.Extension -eq '.sav' })
Say "files   : $($files.Count)   saves: $($saves.Count)   total: $([math]::Round((($files|Measure-Object -Property Length -Sum).Sum)/1MB,2)) MB"

#-- 1. structural ---------------------------------------------------------------
Head "Structural integrity (offline, authoritative)"
$badSaves = @()
foreach ($f in $saves) {
    $r = Test-PalSaveFile -Path $f.FullName
    if (-not $r.Ok) { $badSaves += $r }
}
if ($badSaves.Count -eq 0) {
    Ok "all $($saves.Count) .sav file(s) are well-formed containers"
} else {
    Bad "$($badSaves.Count) of $($saves.Count) .sav file(s) are malformed:"
    $badSaves | Select-Object -First 12 | ForEach-Object { Bad "  $($_.Path) -- $($_.Reason)" }
}

$level = $saves | Where-Object { $_.Name -eq 'Level.sav' } | Select-Object -First 1
if ($level) {
    $lr = Test-PalSaveFile -Path $level.FullName
    Ok ("Level.sav  {0:N0} bytes  magic={1}  uncompressed={2:N0}" -f $level.Length, $lr.Magic, $lr.UncompressedLen)
} else {
    Bad "Level.sav MISSING -- this backup cannot restore the world"
}

#-- 2. presence -----------------------------------------------------------------
Head "Presence"
$meta    = $files | Where-Object { $_.Name -eq 'LevelMeta.sav' }
$players = @($files | Where-Object { $_.FullName -match '\\Players\\' -and $_.Extension -eq '.sav' })
$cfg     = $files | Where-Object { $_.Name -eq 'PalWorldSettings.ini' }
if ($meta)          { Ok "LevelMeta.sav present" }            else { Warn "LevelMeta.sav missing" }
if ($players.Count) { Ok "$($players.Count) player save(s)" } else { Warn "no player saves captured" }
if ($cfg)           { Ok "PalWorldSettings.ini captured" }    else { Warn "PalWorldSettings.ini not in backup" }

#-- 3. freshness ----------------------------------------------------------------
$drift = @()
if (-not $SkipRemote) {
    Head "Freshness vs live server (drift is expected, not failure)"
    $manifestPath = Join-Path $BackupDir 'manifest.csv'
    if (Test-Path $manifestPath) {
        $rows = Import-Csv $manifestPath
        # Only re-stat the files that matter; re-statting 400 files is slow.
        $interesting = $rows | Where-Object { $_.RemotePath -match '(Level\.sav|LevelMeta\.sav|PalWorldSettings\.ini)$' }
        foreach ($row in $interesting) {
            $now = Get-FtpFileSize -Path $row.RemotePath
            $localSize = [int64]$row.LocalSize
            if ($now -lt 0) { Warn "could not re-stat $($row.RemotePath)"; continue }
            if ($now -eq $localSize) {
                Ok ("{0} matches live server ({1:N0} bytes)" -f ($row.RemotePath -split '/')[-1], $now)
            } else {
                $drift += [pscustomobject]@{ File = ($row.RemotePath -split '/')[-1]; Ours = $localSize; Live = $now }
                Say ("{0}: ours {1:N0} vs live {2:N0} -- server has written since capture" -f ($row.RemotePath -split '/')[-1], $localSize, $now)
            }
        }
    } else { Warn "no manifest.csv; skipping freshness check" }
}

#-- verdict ---------------------------------------------------------------------
Head "Verdict"
if ($badSaves.Count -gt 0 -or -not $level) {
    Bad "BACKUP IS NOT TRUSTWORTHY. Do not rely on it. Re-run nitrado-backup.ps1."
    exit 1
}
Ok "Backup is structurally sound and restorable."
if ($drift.Count -gt 0) {
    Say ""
    Say "$($drift.Count) file(s) have changed on the server since capture. That is normal on a"
    Say "running server and does not affect restorability -- it only means this copy is a"
    Say "snapshot from capture time, not the current state."
}
Write-Host ""
Write-Host "  Restore procedure: stop the server, upload Saved\ over Pal/Saved, start it." -ForegroundColor Gray
Write-Host "  Keep bIsUseBackupSaveData=True so the game keeps its own rolling backups too." -ForegroundColor Gray
exit 0
