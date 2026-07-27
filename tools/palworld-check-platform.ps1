<#
.SYNOPSIS
  Answer the one question that decides whether a host can run this mod.

.DESCRIPTION
  UE4SS requires the WINDOWS Palworld build and must be written into
  Pal/Binaries/Win64. Two hosts have already failed this in different ways:

    Nitrado  - Windows build, but FTP exposes only Pal/Saved. Nowhere to install.
    Bisect   - full file access over SFTP, but the LINUX build. No Win64 at all.

  Run this BEFORE paying, and again after any reinstall or product change. It
  takes seconds and needs no game server running.

  Verdict is one of:
    MOD CAPABLE      Win64 present and writable -> proceed
    WRONG PLATFORM   Linux build -> the mod cannot run here, full stop
    NO ACCESS        Win64 not reachable -> Nitrado-style scoping, or wrong GameRoot

.PARAMETER HostName
  Config name, e.g. 'bisect' -> tools/bisect.config.ps1

.PARAMETER SkipWriteTest
  Don't upload a probe file; only check what's listable.

.EXAMPLE
  .\palworld-check-platform.ps1 -HostName bisect
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [switch] $SkipWriteTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'palhost.ps1')

function Say  ($m) { Write-Host "  $m" }
function Good ($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

try {
    $h = Use-PalHostAny -Name $HostName
    Head "Host"
    Say "config   : $($h.Name)"
    Say "protocol : $($h.Protocol)"
    Say "endpoint : $($h.Endpoint)"
    Say "gameroot : $($h.GameRoot)"

    Head "Directory tree"
    $top = Get-PalChildren -Path '.' -Quiet
    if ($top.Count -gt 0) {
        # A quick tell: PalServer.sh means Linux, PalServer.exe means Windows.
        $sh  = $top | Where-Object { $_.Name -eq 'PalServer.sh' }
        $exe = $top | Where-Object { $_.Name -eq 'PalServer.exe' }
        if ($sh)  { Say "found PalServer.sh   -> launcher is a shell script (Linux)" }
        if ($exe) { Say "found PalServer.exe  -> launcher is a Windows executable" }
        $manifests = $top | Where-Object { $_.Name -match '^Manifest_.*\.txt$' }
        foreach ($mf in $manifests) { Say "manifest: $($mf.Name)" }
    } else { Warn "could not list the game root (GameRoot may be wrong for this host)" }

    Head "Platform"
    $plat = Get-PalPlatform
    Say "Win64 present : $($plat.Win64Present)"
    Say "Linux present : $($plat.LinuxPresent)"
    Say "shipping bin  : $(if($plat.ShippingBinary){$plat.ShippingBinary}else{'not found'})"
    $plat.Notes | ForEach-Object { Say "note : $_" }

    $writable = $null
    if ($plat.Win64Present -and -not $SkipWriteTest) {
        Head "Write test (Pal/Binaries/Win64)"
        $writable = Test-PalWin64Writable
        if ($writable) { Good "Win64 is writable -- UE4SS can be installed" }
        else { Bad "Win64 is NOT writable -- UE4SS cannot be installed" }
    }

    Head "Verdict"
    if ($plat.Platform -eq 'windows' -and ($SkipWriteTest -or $writable)) {
        Good "MOD CAPABLE"
        Say ""
        Say "Next: UE4SS into Pal/Binaries/Win64 (set GuiConsoleVisible=0), then"
        Say "GuildStasis into ue4ss/Mods/GuildStasis, and add 'GuildStasis : 1' to"
        Say "ue4ss/Mods/mods.txt. Back up before letting players in."
        exit 0
    }
    elseif ($plat.Platform -eq 'linux') {
        Bad "WRONG PLATFORM (Linux build)"
        Say ""
        Say "UE4SS has no working Linux support, so the mod cannot run here as designed."
        Say "Options, best first:"
        Say "  1. Ask the host for the WINDOWS Palworld build / a Windows node."
        Say "  2. Refund and choose a host that can show you a Win64 folder."
        Say "  3. Self-host on Windows."
        Say "A Wine/Proton workaround exists in theory but Palworld 1.0 under Proton has"
        Say "a documented save-corruption bug, so it is not appropriate for a live server."
        exit 2
    }
    elseif ($plat.Platform -eq 'windows') {
        Bad "WINDOWS BUILD BUT NOT WRITABLE"
        Say "The build is right but UE4SS cannot be placed. Ask support for write access"
        Say "to Pal/Binaries/Win64."
        exit 3
    }
    else {
        Bad "NO ACCESS to Pal/Binaries"
        Say "Either the host scopes file access to Pal/Saved only (Nitrado does this), or"
        Say "GameRoot is wrong in $HostName.config.ps1. Check the tree listing above:"
        Say "if you can see PalServer.sh/.exe then GameRoot is right and this is scoping."
        exit 4
    }
}
finally { try { Close-PalHost } catch {} }
