<#
.SYNOPSIS
  Verify a Palworld host can run this mod, and that it loaded the right world.

.DESCRIPTION
  Answers the two questions that decide a migration, in one run:

    1. CAN IT RUN THE MOD?  Is Pal/Binaries/Win64 listable and writable, and is
       PalServer-Win64-Shipping present? UE4SS needs the WINDOWS build and needs
       to be written into Win64. A Linux-build host fails here no matter what its
       marketing or its knowledgebase says.

    2. DID IT LOAD *YOUR* WORLD?  Compares the live worldguid, day count and base
       camp count against what they should be. A fresh world looks like day 1 with
       0 base camps -- which is indistinguishable from a lost save if you don't
       check.

  Safe to run any time. The only write is a tiny probe file in Win64, deleted
  immediately.

.PARAMETER HostName
  Config name, e.g. 'bisect' -> tools/bisect.config.ps1

.PARAMETER ExpectWorldGuid
  The world you expect. Defaults to the newest backup's WorldGuid.

.PARAMETER ExpectMinDay
  Fail if the live day count is below this. Defaults to 90% of the backup's day.

.PARAMETER ExpectMinBaseCamps
  Fail if fewer base camps than this. Defaults to 1.

.PARAMETER SkipRest
  File checks only (use before the server is live).

.EXAMPLE
  .\palworld-verify-host.ps1 -HostName bisect -SkipRest
  .\palworld-verify-host.ps1 -HostName bisect -ExpectWorldGuid CA51870543876E37839AB8A4BB77572D -ExpectMinDay 700 -ExpectMinBaseCamps 10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [string] $ExpectWorldGuid,
    [int]    $ExpectMinDay = 0,
    [int]    $ExpectMinBaseCamps = 1,
    [switch] $SkipRest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'nitrado-lib.ps1')

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

# Fill expectations from the newest backup unless overridden.
if (-not $ExpectWorldGuid -or $ExpectMinDay -eq 0) {
    $bk = Join-Path $PSScriptRoot '..\backups'
    if (Test-Path $bk) {
        $newest = Get-ChildItem $bk -Directory | Sort-Object Name -Descending | Select-Object -First 1
        $sj = Join-Path $newest.FullName 'summary.json'
        if (Test-Path $sj) {
            $s = Get-Content $sj -Raw | ConvertFrom-Json
            if (-not $ExpectWorldGuid -and $s.WorldGuid) { $ExpectWorldGuid = $s.WorldGuid }
        }
        $rj = Join-Path $newest.FullName 'rest\metrics.json'
        if ($ExpectMinDay -eq 0 -and (Test-Path $rj)) {
            $mj = Get-Content $rj -Raw | ConvertFrom-Json
            if ($mj.days) { $ExpectMinDay = [int]([math]::Floor($mj.days * 0.9)) }
        }
    }
}

$fail = 0
$cfg = Use-PalHost -Name $HostName

Head "Host"
Say "config : $HostName"
Say "ftp    : $($cfg.FtpHost)"
if ($ExpectWorldGuid)   { Say "expect world : $ExpectWorldGuid" }
if ($ExpectMinDay -gt 0){ Say "expect day   : >= $ExpectMinDay" }

#-- 1. mod capability -----------------------------------------------------------
Head "1. Can this host run the mod?"
$cap = Test-PalHostModCapable -Quiet
Say "Win64 listable : $($cap.Win64Listable)"
Say "Win64 writable : $($cap.Win64Writable)"
Say "Windows build  : $($cap.WindowsBuild)"
Say "Saved listable : $($cap.SavedListable)"
$cap.Notes | ForEach-Object { Say "note : $_" }

if ($cap.Win64Listable -and $cap.Win64Writable) {
    Ok "UE4SS can be installed (Win64 present and writable)"
} else {
    Bad "UE4SS CANNOT be installed here"
    $fail++
    Say ""
    Say "  This is the same blocker as Nitrado. Before giving up, check:"
    Say "    - is this the host's MODDED / mod-supported Palworld product?"
    Say "    - does the panel expose a different file root than FTP does?"
    Say "    - ask support directly: 'is this the Windows build, and can I write"
    Say "      to Pal/Binaries/Win64?' Those two facts decide it."
}
if (-not $cap.WindowsBuild) {
    Warn "PalServer-Win64-Shipping not seen. If the tree shows a Linux folder instead"
    Warn "of Win64, UE4SS will not work at all -- it has no working Linux support."
}

#-- 2. right world? -------------------------------------------------------------
if (-not $SkipRest) {
    Head "2. Did it load YOUR world?"
    try {
        $info = Invoke-PalRest -Endpoint 'info'
        $met  = Invoke-PalRest -Endpoint 'metrics'
        Say "server    : $($info.servername)"
        Say "version   : $($info.version)"
        Say "worldguid : $($info.worldguid)"
        Say "day       : $($met.days)    basecamps: $($met.basecampnum)    players: $($met.currentplayernum)"

        if ($ExpectWorldGuid) {
            if ($info.worldguid -eq $ExpectWorldGuid) { Ok "worldguid matches the migrated world" }
            else {
                Bad "worldguid MISMATCH -- expected $ExpectWorldGuid"
                Say "  The server is running a DIFFERENT world. Your save is probably sitting"
                Say "  on disk unread. Stop the server, do not let players in, and set"
                Say "  DedicatedServerName=$ExpectWorldGuid in GameUserSettings.ini."
                $fail++
            }
        }
        if ($ExpectMinDay -gt 0) {
            if ($met.days -ge $ExpectMinDay) { Ok "day count $($met.days) looks like the migrated world" }
            else { Bad "day count $($met.days) is far below expected >= $ExpectMinDay -- likely a FRESH world"; $fail++ }
        }
        if ($met.basecampnum -ge $ExpectMinBaseCamps) { Ok "$($met.basecampnum) base camp(s) present" }
        else { Bad "only $($met.basecampnum) base camp(s) -- expected >= $ExpectMinBaseCamps"; $fail++ }
    } catch {
        Warn "REST unreachable: $($_.Exception.Message)"
        Say "  If the server is not started yet, that is expected -- re-run later."
        Say "  If it IS running, enable RESTAPIEnabled=True and open the REST port,"
        Say "  and make sure RestBase in $HostName.config.ps1 has the right port."
    }
}

#-- verdict ---------------------------------------------------------------------
Head "Verdict"
if ($fail -eq 0) {
    Ok "no blocking problems found"
    Write-Host ""
    Write-Host "  Next: install UE4SS into Pal/Binaries/Win64, set GuiConsoleVisible=0 in" -ForegroundColor Gray
    Write-Host "  UE4SS-settings.ini, then GuildStasis into ue4ss/Mods/GuildStasis and add" -ForegroundColor Gray
    Write-Host "  'GuildStasis : 1' to ue4ss/Mods/mods.txt. Back up before players return." -ForegroundColor Gray
    exit 0
}
Bad "$fail blocking problem(s). Do not proceed until these are resolved."
exit 1
