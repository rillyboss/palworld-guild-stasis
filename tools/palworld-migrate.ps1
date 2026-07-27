<#
.SYNOPSIS
  Migrate a Palworld world from one host to another over FTP.

.DESCRIPTION
  Uploads a verified backup's world folder and player saves to a new host, and
  sets the one thing that actually decides whether your world loads.

  THE CRITICAL DETAIL: Palworld chooses which world to load by matching
  DedicatedServerName in GameUserSettings.ini to a folder name under
  Pal/Saved/SaveGames/0/. A fresh server generates its own GUID. If you upload
  your world without setting DedicatedServerName to match, the server ignores it
  and boots a brand-new world -- which looks exactly like "my save was lost".

  This script is deliberately NOT fully automatic about that last part: hosts vary
  in whether GameUserSettings.ini is panel-managed or file-managed, so it writes
  the file and then tells you to confirm it stuck.

  Run order:
    1. -WhatIf    to see what would happen
    2. -Preflight to check the target can host the mod at all
    3. for real, with the target server STOPPED

.PARAMETER BackupDir
  A verified backup from nitrado-backup.ps1 (run nitrado-verify-backup.ps1 first).

.PARAMETER TargetHost
  Config name for the destination, e.g. 'bisect' -> tools/bisect.config.ps1

.PARAMETER Preflight
  Only check the target: Windows build, Win64 listable/writable, Saved present.

.PARAMETER IncludeRollingBackups
  Also upload the game's own backup/ folder. Off by default -- it is the bulk of
  the data and the new host will build its own.

.EXAMPLE
  .\palworld-migrate.ps1 -TargetHost bisect -Preflight
  .\palworld-migrate.ps1 -TargetHost bisect -WhatIf
  .\palworld-migrate.ps1 -TargetHost bisect
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $BackupDir,
    [Parameter(Mandatory)][string] $TargetHost,
    [switch] $Preflight,
    [switch] $IncludeRollingBackups
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'nitrado-lib.ps1')

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  [ok] $m"   -ForegroundColor Green }
function Warn ($m) { Write-Host "  [!!] $m"   -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "  [XX] $m"   -ForegroundColor Red }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

#-- target ----------------------------------------------------------------------
Head "Target host"
$tgt = Use-PalHost -Name $TargetHost
Say "ftp   : $($tgt.FtpHost)"
Say "root  : /$($tgt.GameRoot)"

Head "Pre-flight: can this host run the mod?"
$cap = Test-PalHostModCapable
if (-not $cap.Win64Listable) {
    Bad "Pal/Binaries/Win64 is not listable. UE4SS cannot be installed here."
    Bad "This host is NOT suitable -- same blocker as Nitrado. Stop and ask support."
} elseif (-not $cap.Win64Writable) {
    Bad "Win64 is listable but NOT writable. UE4SS cannot be installed here."
} else {
    Ok "Win64 is writable -- UE4SS can be installed on this host"
}
if (-not $cap.WindowsBuild) {
    Warn "Did not see PalServer-Win64-Shipping. Confirm this is the WINDOWS build;"
    Warn "UE4SS does not work on the Linux build at all."
}
if ($Preflight) { Head "Pre-flight only"; Say "Stopping here as requested."; exit 0 }

#-- source ----------------------------------------------------------------------
if (-not $BackupDir) {
    $root = Join-Path $PSScriptRoot '..\backups'
    if (-not (Test-Path $root)) { throw "No backups found; run nitrado-backup.ps1 first." }
    $BackupDir = (Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
}
Head "Source backup"
Say $BackupDir

$savedRoot = Join-Path $BackupDir 'Saved'
if (-not (Test-Path $savedRoot)) { throw "Backup has no Saved/ folder: $savedRoot" }

$worldDir = Get-ChildItem (Join-Path $savedRoot 'SaveGames\0') -Directory | Select-Object -First 1
if (-not $worldDir) { throw "No world folder under Saved/SaveGames/0 in the backup." }
$worldName = $worldDir.Name
Say "world  : $worldName"

$level = Join-Path $worldDir.FullName 'Level.sav'
if (-not (Test-Path $level)) { throw "No Level.sav in the world folder -- refusing to migrate." }
$lv = Test-PalSaveFile -Path $level
if (-not $lv.Ok) { throw "Level.sav failed integrity check: $($lv.Reason)" }
Ok ("Level.sav verified: {0:N0} bytes, magic {1}" -f (Get-Item $level).Length, $lv.Magic)

$playerDir = Join-Path $worldDir.FullName 'Players'
$playerCount = if (Test-Path $playerDir) { (Get-ChildItem $playerDir -File -Filter *.sav | Measure-Object).Count } else { 0 }
Say "players: $playerCount save(s)"

#-- what we will do -------------------------------------------------------------
$remoteWorld = "$($tgt.GameRoot)/Pal/Saved/SaveGames/0/$worldName"
Head "Plan"
Say "upload world -> /$remoteWorld"
Say "set DedicatedServerName=$worldName in the target's GameUserSettings.ini"
if ($IncludeRollingBackups) { Say "including the game's rolling backup/ folder" }
else { Say "skipping backup/ and world_save_bak/ (bulk; target rebuilds its own)" }

Warn "The target server MUST be STOPPED. Uploading over a running server's save"
Warn "will be overwritten by its next autosave, or corrupt the file mid-write."

if (-not $PSCmdlet.ShouldProcess($tgt.FtpHost, "upload world $worldName")) {
    Head "WhatIf"; Say "Nothing was uploaded."; exit 0
}

#-- upload ----------------------------------------------------------------------
Head "Uploading world"
$exclude = @()
if (-not $IncludeRollingBackups) { $exclude = @('backup', 'world_save_bak') }

$results = Send-FtpTree -LocalRoot $worldDir.FullName -RemoteRoot $remoteWorld -ExcludeDirs $exclude
$failed = @($results | Where-Object { -not $_.Ok })
$uploadedMB = [math]::Round((($results | Where-Object { $_.Ok } | Measure-Object -Property LocalSize -Sum).Sum) / 1MB, 2)
Say "uploaded: $(@($results | Where-Object { $_.Ok }).Count) file(s), $uploadedMB MB"

if ($failed.Count -gt 0) {
    Bad "$($failed.Count) file(s) failed to upload or verify:"
    $failed | Select-Object -First 10 | ForEach-Object { Bad "  $($_.RemotePath)  $($_.Error)" }
    Bad "MIGRATION INCOMPLETE. Do not start the server on the new host yet."
    exit 1
}
Ok "every uploaded file verified by size on the far side"

#-- the bit that actually makes it load -----------------------------------------
Head "Pointing the server at the migrated world"
$gusRemote = "$($tgt.GameRoot)/Pal/Saved/Config/WindowsServer/GameUserSettings.ini"
$existing = $null
try { $existing = Get-FtpFileText -Path $gusRemote } catch { Warn "could not read target GameUserSettings.ini ($($_.Exception.Message))" }

$section = '[/Script/Pal.PalGameLocalSettings]'
if ($null -eq $existing -or $existing.Trim().Length -eq 0) {
    $new = "$section`r`nDedicatedServerName=$worldName`r`n"
} elseif ($existing -match 'DedicatedServerName=\S*') {
    $new = [regex]::Replace($existing, 'DedicatedServerName=\S*', "DedicatedServerName=$worldName", 1)
} elseif ($existing -match [regex]::Escape($section)) {
    $new = $existing -replace [regex]::Escape($section), "$section`r`nDedicatedServerName=$worldName"
} else {
    $new = $existing.TrimEnd() + "`r`n$section`r`nDedicatedServerName=$worldName`r`n"
}

$tmp = [IO.Path]::GetTempFileName()
[IO.File]::WriteAllText($tmp, $new, (New-Object System.Text.UTF8Encoding($false)))
try {
    $r = Send-FtpFile -LocalPath $tmp -RemotePath $gusRemote
    if ($r.Ok) { Ok "GameUserSettings.ini updated: DedicatedServerName=$worldName" }
    else { Warn "uploaded GameUserSettings.ini but size did not verify -- check it by hand" }
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Head "Next steps (in this order)"
Write-Host @"
  1. In the host panel, confirm GameUserSettings.ini still reads
         DedicatedServerName=$worldName
     Some panels rewrite this file on start. If it gets reverted, set the world or
     server name through the panel UI instead so the panel and the file agree.

  2. Start the server. Then verify you got YOUR world, not a new one:
         GET http://<host>:<restport>/v1/api/info      -> worldguid should be $worldName
         GET http://<host>:<restport>/v1/api/metrics   -> day and basecampnum should match the old server
     If day resets to 1 and basecampnum is 0, the server booted a fresh world.
     STOP, do not let players on, and fix DedicatedServerName.

  3. Copy your gameplay settings across. Do NOT paste the old PalWorldSettings.ini
     wholesale -- ports, AdminPassword, RCON/REST ports and PublicIP are
     host-specific. Copy the gameplay values only. Keep these as they were:
         bAutoResetGuildNoOnlinePlayers=False
         bIsUseBackupSaveData=True

  4. Only once the world is confirmed: install UE4SS into Pal/Binaries/Win64,
     then GuildStasis into ue4ss/Mods/GuildStasis, and add
         GuildStasis : 1
     to ue4ss/Mods/mods.txt. Set GuiConsoleVisible=0 in UE4SS-settings.ini --
     a visible console makes a headless server crash on startup.

  5. Take a fresh backup of the NEW host before letting players in.
"@ -ForegroundColor Gray
exit 0
