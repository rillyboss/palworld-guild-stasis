<#
.SYNOPSIS
  Verify a Palworld host can run this mod, and that it loaded the right world.

.DESCRIPTION
  Answers the two questions that decide a migration, in one run:

    1. CAN IT RUN THE MOD?  Is Pal/Binaries/Win64 present and writable, and is
       the shipping binary the Windows one? UE4SS needs the Windows build and has
       to be written into Win64. Also reports whether UE4SS is already installed.

    2. DID IT LOAD *YOUR* WORLD?  Compares live worldguid, day count and base camp
       count against expectations. A freshly generated world presents as day 1
       with 0 base camps, which is indistinguishable from a lost save unless you
       check -- so a mismatch is a hard failure, not a warning.

  Works over FTP or SFTP; the protocol comes from the host config.

  Safe to run any time. The only write is a small probe file in Win64, removed
  immediately.

.EXAMPLE
  .\palworld-verify-host.ps1 -HostName bisect
  .\palworld-verify-host.ps1 -HostName bisect -SkipRest
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [string] $ExpectWorldGuid,
    [int]    $ExpectMinDay = 0,
    [int]    $ExpectMinBaseCamps = 1,
    [switch] $SkipRest,
    [switch] $SkipWriteTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'palhost.ps1')

function Say  ($m) { Write-Host "  $m" }
function Good ($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

# Default expectations from the newest local backup.
if (-not $ExpectWorldGuid) {
    $bk = Join-Path $PSScriptRoot '..\backups'
    if (Test-Path $bk) {
        $newest = Get-ChildItem $bk -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($newest) {
            $sj = Join-Path $newest.FullName 'summary.json'
            if (Test-Path $sj) {
                $s = Get-Content $sj -Raw | ConvertFrom-Json
                if ($s.WorldGuid) { $ExpectWorldGuid = $s.WorldGuid }
            }
        }
    }
}

$fail = 0
try {
    $h = Use-PalHostAny -Name $HostName
    Head "Host"
    Say "config   : $($h.Name)"
    Say "protocol : $($h.Protocol)"
    Say "endpoint : $($h.Endpoint)"
    if ($ExpectWorldGuid)    { Say "expect world : $ExpectWorldGuid" }
    if ($ExpectMinDay -gt 0) { Say "expect day   : >= $ExpectMinDay" }

    #-- 1. mod capability -------------------------------------------------------
    Head "1. Can this host run the mod?"
    $plat = Get-PalPlatform
    Say "platform      : $($plat.Platform)"
    Say "Win64 present : $($plat.Win64Present)"
    Say "shipping bin  : $(if($plat.ShippingBinary){$plat.ShippingBinary}else{'not found'})"
    $plat.Notes | ForEach-Object { Say "note : $_" }

    if ($plat.Platform -eq 'linux') {
        Bad "Linux build -- UE4SS cannot run here, so the mod cannot either"
        $fail++
    } elseif (-not $plat.Win64Present) {
        Bad "Pal/Binaries/Win64 not reachable -- cannot install UE4SS"
        $fail++
    } else {
        $writable = $true
        if (-not $SkipWriteTest) { $writable = Test-PalWin64Writable }
        if ($writable) { Good "Windows build, Win64 writable -- mod can be installed" }
        else { Bad "Windows build but Win64 is NOT writable"; $fail++ }

        # Is UE4SS already here, and is it the Palworld-specific build?
        $ue = Get-PalChildren -Path 'Pal/Binaries/Win64/ue4ss' -Quiet
        if ($ue.Count -gt 0) {
            $dll = $ue | Where-Object { $_.Name -eq 'UE4SS.dll' }
            $mvl = $ue | Where-Object { $_.Name -eq 'MemberVariableLayout.ini' }
            Say "UE4SS present : yes"
            if ($dll) { Say "  UE4SS.dll : $('{0:N0}' -f $dll.Size) bytes$(if($dll.Size -eq 16519168){'  (matches the verified Okaetsu palworld build)'})" }
            if ($mvl) { Say "  MemberVariableLayout.ini : $('{0:N0}' -f $mvl.Size) bytes$(if($mvl.Size -eq 37857){'  (matches verified)'})" }
            else { Warn "  MemberVariableLayout.ini missing -- not the Palworld-specific build; expect crashes" }

            $mods = Get-PalChildren -Path 'Pal/Binaries/Win64/ue4ss/Mods' -Quiet
            $stasis = $mods | Where-Object { $_.Name -eq 'GuildStasis' }
            if ($stasis) {
                Good "GuildStasis is installed"
                try {
                    $mt = Get-PalText -Path 'Pal/Binaries/Win64/ue4ss/Mods/mods.txt'
                    if ($mt -match '(?m)^\s*GuildStasis\s*:\s*1') { Good "GuildStasis enabled in mods.txt" }
                    else { Warn "GuildStasis present but NOT enabled -- add 'GuildStasis : 1' to mods.txt" }
                } catch { Warn "could not read mods.txt" }
            } else { Say "GuildStasis   : not installed yet" }
        } else { Say "UE4SS present : no" }
    }

    #-- 2. right world? ---------------------------------------------------------
    if (-not $SkipRest) {
        Head "2. Did it load YOUR world?"
        try {
            $info = Invoke-PalRest -Endpoint 'info'
            $met  = Invoke-PalRest -Endpoint 'metrics'
            Say "servername : $($info.servername)"
            Say "version    : $($info.version)"
            Say "worldguid  : $($info.worldguid)"
            Say "day        : $($met.days)   basecamps: $($met.basecampnum)   players: $($met.currentplayernum)/$($met.maxplayernum)"
            Say "fps        : $($met.serverfps)  uptime: $($met.uptime)s"

            if ($ExpectWorldGuid) {
                if ($info.worldguid -eq $ExpectWorldGuid) { Good "worldguid matches your migrated world" }
                else {
                    Bad "worldguid MISMATCH -- expected $ExpectWorldGuid"
                    Say "  The server is running a different world; yours is on disk but unread."
                    Say "  Stop it, do not let players in, and set DedicatedServerName via the"
                    Say "  panel UI (some panels rewrite GameUserSettings.ini on start)."
                    $fail++
                }
            }
            if ($ExpectMinDay -gt 0) {
                if ($met.days -ge $ExpectMinDay) { Good "day $($met.days) is consistent with the migrated world" }
                else { Bad "day $($met.days) is far below expected >= $ExpectMinDay -- looks like a FRESH world"; $fail++ }
            }
            if ($met.basecampnum -ge $ExpectMinBaseCamps) { Good "$($met.basecampnum) base camps present" }
            else { Bad "only $($met.basecampnum) base camps, expected >= $ExpectMinBaseCamps"; $fail++ }
        } catch {
            Warn "REST unreachable: $($_.Exception.Message)"
            Say "  If the server is stopped that is expected. If it is running, check"
            Say "  RESTAPIEnabled/RESTAPIPort and RestBase in $HostName.config.ps1."
        }
    }

    Head "Verdict"
    if ($fail -eq 0) { Good "no blocking problems found"; exit 0 }
    Bad "$fail blocking problem(s)"
    exit 1
}
finally { try { Close-PalHost } catch {} }
