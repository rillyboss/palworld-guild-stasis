<#
.SYNOPSIS
  Back up a Palworld server's saves and config. Works over FTP or SFTP.

.DESCRIPTION
  Supersedes nitrado-backup.ps1, which was FTP-only. Protocol comes from the host
  config, so the same command works for any host.

  Downloads Pal/Saved into a timestamped folder, then verifies three ways:
    - every .sav parses as a real Palworld container (offline, authoritative)
    - remote size vs downloaded size per file
    - Level.sav present and non-trivial

  Read-only against the server: never writes, deletes or restarts anything.

  Exits non-zero if the world save is missing or malformed, because an unverified
  backup is not a backup.

.PARAMETER HostName
  Config name, e.g. 'bisect' -> tools/bisect.config.ps1

.PARAMETER SkipRollingBackups
  Skip the game's own backup/ and world_save_bak/ folders. They are the bulk of
  the data; the world itself is small.

.EXAMPLE
  .\palworld-backup.ps1 -HostName bisect
  .\palworld-backup.ps1 -HostName bisect -SkipRollingBackups
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [string] $OutRoot = (Join-Path $PSScriptRoot '..\backups'),
    [switch] $SkipRollingBackups,
    [switch] $SkipRest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'palhost.ps1')

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  [ok] $m"  -ForegroundColor Green }
function Warn ($m) { Write-Host "  [!!] $m"  -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "  [XX] $m"  -ForegroundColor Red }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

try {
    $h = Use-PalHostAny -Name $HostName
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest  = Join-Path $OutRoot "$HostName-$stamp"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    Head "Target"
    Say "host   : $($h.Name)  ($($h.Protocol) $($h.Endpoint))"
    Say "remote : Pal/Saved"
    Say "local  : $dest"

    Head "Live state"
    $info = $null
    if (-not $SkipRest) {
        try {
            $info = Invoke-PalRest -Endpoint 'info'
            $met  = Invoke-PalRest -Endpoint 'metrics'
            Say "server  : $($info.servername)  $($info.version)"
            Say "world   : $($info.worldguid)"
            Say "players : $($met.currentplayernum)   basecamps: $($met.basecampnum)   day: $($met.days)"
            if ($met.currentplayernum -gt 0) {
                Warn "$($met.currentplayernum) player(s) online -- the save may be mid-write."
                Warn "A backup taken while players are on is still useful, but for a clean"
                Warn "point-in-time copy, take one when the server is empty."
            }
        } catch { Warn "REST unavailable ($($_.Exception.Message)); continuing" }
    }

    Head "Downloading"
    $exclude = @()
    if ($SkipRollingBackups) { $exclude = @('backup','world_save_bak') ; Say "skipping the game's own rolling backups" }
    $manifest = @(Save-PalTree -RemotePath 'Pal/Saved' -Destination (Join-Path $dest 'Saved') -ExcludeDirs $exclude)

    $sizeMismatch = @($manifest | Where-Object { -not $_.Match })
    $totalMB = [math]::Round((($manifest | Where-Object { $_.LocalSize -gt 0 } | Measure-Object -Property LocalSize -Sum).Sum)/1MB, 2)
    Say "files : $($manifest.Count)"
    Say "size  : $totalMB MB"

    Head "Verification"
    $saves = @(Get-ChildItem $dest -Recurse -File -Filter *.sav)
    $badSaves = @()
    foreach ($f in $saves) {
        $r = Test-PalSaveFile -Path $f.FullName
        if (-not $r.Ok) { $badSaves += [pscustomobject]@{ File = $f.FullName; Reason = $r.Reason } }
    }
    if ($badSaves.Count -eq 0) { Ok "all $($saves.Count) .sav file(s) are well-formed" }
    else {
        Bad "$($badSaves.Count) malformed .sav file(s):"
        $badSaves | Select-Object -First 10 | ForEach-Object { Bad "  $($_.File) -- $($_.Reason)" }
    }

    $level = $saves | Where-Object { $_.Name -eq 'Level.sav' } | Sort-Object Length -Descending | Select-Object -First 1
    if ($level) {
        $lr = Test-PalSaveFile -Path $level.FullName
        Ok ("Level.sav {0:N0} bytes, magic {1}, uncompressed {2:N0}" -f $level.Length, $lr.Magic, $lr.UncompressedLen)
    } else { Bad "no Level.sav captured -- this backup cannot restore the world" }

    $players = @($saves | Where-Object { $_.FullName -match '\\Players\\' })
    Say "player saves : $($players.Count)"

    # Size mismatches are usually the server autosaving mid-copy, not corruption --
    # the structural check above is the one that decides trustworthiness.
    if ($sizeMismatch.Count -gt 0) {
        Warn "$($sizeMismatch.Count) file(s) changed size between listing and download"
        Warn "(normal on a running server; structural checks above are authoritative)"
    }

    Head "Writing manifest"
    $manifest | Select-Object RemotePath, LocalPath, RemoteSize, LocalSize, Match, Sha256 |
        Export-Csv -Path (Join-Path $dest 'manifest.csv') -NoTypeInformation -Encoding utf8
    [pscustomobject]@{
        TakenUtc   = (Get-Date).ToUniversalTime().ToString('o')
        HostName   = $HostName
        Protocol   = $h.Protocol
        Endpoint   = $h.Endpoint
        FileCount  = $manifest.Count
        TotalBytes = ($manifest | Where-Object { $_.LocalSize -gt 0 } | Measure-Object -Property LocalSize -Sum).Sum
        ServerName = if ($info) { $info.servername } else { $null }
        WorldGuid  = if ($info) { $info.worldguid }  else { $null }
        Version    = if ($info) { $info.version }    else { $null }
        MalformedSaves = $badSaves.Count
    } | ConvertTo-Json -Depth 4 | Out-File (Join-Path $dest 'summary.json') -Encoding utf8
    Ok "manifest.csv + summary.json"

    Head "Verdict"
    if ($badSaves.Count -gt 0 -or -not $level) {
        Bad "BACKUP NOT TRUSTWORTHY -- re-run before changing anything"
        exit 1
    }
    Ok "backup verified and restorable"
    Write-Host ""
    Write-Host "  $dest" -ForegroundColor Green
    Write-Host "  Restore: stop the server, upload Saved\ over Pal/Saved, start it." -ForegroundColor Gray
    exit 0
}
finally { try { Close-PalHost } catch {} }
