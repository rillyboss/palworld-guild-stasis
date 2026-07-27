<#
.SYNOPSIS
  Back up a Nitrado-hosted Palworld server's saves and config over FTP.

.DESCRIPTION
  Downloads everything under Pal/Saved into a timestamped local folder, then
  verifies it: remote size vs local size per file, plus a SHA256 of each file.
  Writes manifest.csv and summary.json alongside the copy.

  Run this BEFORE changing anything on the server. It is read-only against the
  server -- it never writes, deletes or restarts.

  A backup you have not verified is not a backup, so this exits non-zero if any
  file failed to download or came back a different size than the listing claimed.

.PARAMETER OutRoot
  Where to put the backup. A timestamped subfolder is created inside it.

.PARAMETER IncludeRest
  Also capture REST /info, /players, /metrics and /settings as JSON, giving you a
  record of live state at backup time.

.EXAMPLE
  .\nitrado-backup.ps1
  .\nitrado-backup.ps1 -OutRoot D:\backups\palworld -IncludeRest
#>
[CmdletBinding()]
param(
    [string] $OutRoot = (Join-Path $PSScriptRoot '..\backups'),
    [switch] $IncludeRest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'nitrado-lib.ps1')

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  [ok] $m"  -ForegroundColor Green }
function Warn ($m) { Write-Host "  [!!] $m"  -ForegroundColor Yellow }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

$cfg   = Get-NitradoConfig
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest  = Join-Path $OutRoot "palworld-$stamp"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

Head "Target"
Say "host    : $($cfg.FtpHost)"
Say "remote  : /$($cfg.GameRoot)/Pal/Saved"
Say "local   : $dest"

Head "Live state before backup"
$restInfo = $null
try {
    $restInfo = Invoke-PalRest -Endpoint 'info'
    $m = Invoke-PalRest -Endpoint 'metrics'
    Say "server  : $($restInfo.servername)  ($($restInfo.version))"
    Say "world   : $($restInfo.worldguid)"
    Say "players : $($m.currentplayernum)   basecamps: $($m.basecampnum)   day: $($m.days)"
    if ($m.currentplayernum -gt 0) {
        Warn "$($m.currentplayernum) player(s) online -- the save on disk may be mid-write."
        Warn "For a clean capture, back up when the server is empty or just after a save."
    }
} catch { Warn "REST unavailable ($($_.Exception.Message)); continuing with FTP only." }

Head "Downloading Pal/Saved"
$root = "$($cfg.GameRoot)/Pal/Saved"
$manifest = Save-FtpTree -Path $root -Destination (Join-Path $dest 'Saved')

$files   = @($manifest)
$failed  = @($files | Where-Object { -not $_.Match })
$totalMB = [math]::Round((($files | Where-Object { $_.LocalSize -gt 0 } | Measure-Object -Property LocalSize -Sum).Sum) / 1MB, 2)

Say "files   : $($files.Count)"
Say "size    : $totalMB MB"

# The world save is the thing that actually matters -- call it out explicitly.
$level = $files | Where-Object { $_.RemotePath -match 'Level\.sav$' } | Select-Object -First 1
if ($level) { Ok "Level.sav captured: $([math]::Round($level.LocalSize/1MB,2)) MB  sha256=$($level.Sha256.Substring(0,16))..." }
else        { Warn "No Level.sav found in the backup -- verify the remote path." }

$players = @($files | Where-Object { $_.RemotePath -match '/Players/' })
Say "player saves: $($players.Count)"

if ($IncludeRest) {
    Head "Capturing REST snapshots"
    $restDir = Join-Path $dest 'rest'
    New-Item -ItemType Directory -Force -Path $restDir | Out-Null
    foreach ($ep in @('info','players','metrics','settings')) {
        try {
            Invoke-PalRest -Endpoint $ep | ConvertTo-Json -Depth 6 |
                Out-File (Join-Path $restDir "$ep.json") -Encoding utf8
            Ok "rest/$ep.json"
        } catch { Warn "rest/$ep failed: $($_.Exception.Message)" }
    }
}

Head "Writing manifest"
$manifestPath = Join-Path $dest 'manifest.csv'
$files | Select-Object RemotePath, LocalPath, RemoteSize, LocalSize, Match, Sha256 |
    Export-Csv -Path $manifestPath -NoTypeInformation -Encoding utf8
Ok "manifest.csv"

$summary = [pscustomobject]@{
    TakenUtc     = (Get-Date).ToUniversalTime().ToString('o')
    FtpHost      = $cfg.FtpHost
    RemoteRoot   = $root
    LocalRoot    = $dest
    FileCount    = $files.Count
    TotalBytes   = ($files | Where-Object { $_.LocalSize -gt 0 } | Measure-Object -Property LocalSize -Sum).Sum
    FailedCount  = $failed.Count
    ServerName   = if ($restInfo) { $restInfo.servername } else { $null }
    WorldGuid    = if ($restInfo) { $restInfo.worldguid }  else { $null }
    Version      = if ($restInfo) { $restInfo.version }    else { $null }
}
$summary | ConvertTo-Json -Depth 4 | Out-File (Join-Path $dest 'summary.json') -Encoding utf8
Ok "summary.json"

Head "Verification"
if ($failed.Count -gt 0) {
    Warn "$($failed.Count) file(s) did not verify:"
    $failed | Select-Object -First 15 | ForEach-Object {
        Warn ("  {0}  remote={1} local={2} {3}" -f $_.RemotePath, $_.RemoteSize, $_.LocalSize, $_.Error)
    }
    Warn "TREAT THIS BACKUP AS INCOMPLETE. Re-run before changing anything on the server."
    exit 1
}
Ok "every file matched its remote size and hashed cleanly"
Write-Host ""
Write-Host "  Backup complete: $dest" -ForegroundColor Green
Write-Host "  To restore: stop the server, upload Saved/ back over Pal/Saved, start it." -ForegroundColor Gray
