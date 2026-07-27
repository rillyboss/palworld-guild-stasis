<#
.SYNOPSIS
  Prepare a LOCAL Palworld 1.0 Windows dedicated server for testing this mod.

.DESCRIPTION
  Mirrors, as closely as possible, the way the mod will be deployed on rented
  hosting: files placed by hand into Mods\Workshop plus an edited
  Mods\PalModSettings.ini. No launch arguments, no injected DLL.

  Safe to re-run. It patches settings in place and never deletes a save.

  Order matters in one place: DedicatedServerName is written BEFORE UE4SS is
  installed, because UE4SS issue #1091 can otherwise make players reconnect as
  brand-new characters.

.PARAMETER ServerRoot
  Palworld Dedicated Server install (the folder containing PalServer.exe).

.PARAMETER ModSource
  This mod's folder (the one containing Info.json).

.PARAMETER WorkshopContent
  Steam workshop content dir for Palworld, used to pick up UE4SS.

.PARAMETER SkipBootstrap
  Skip the first-run step that generates Saved\Config and Mods.

.EXAMPLE
  .\setup-local-testserver.ps1
#>
[CmdletBinding()]
param(
    [string] $ServerRoot      = "D:\SteamLibrary\steamapps\common\PalServer",
    [string] $ModSource       = (Split-Path -Parent $PSScriptRoot),
    [string] $WorkshopContent = "D:\SteamLibrary\steamapps\workshop\content\1623730",
    [switch] $SkipBootstrap
)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  [ok] $m"   -ForegroundColor Green }
function Warn ($m) { Write-Host "  [!!] $m"   -ForegroundColor Yellow }
function Die  ($m) { Write-Host "  [xx] $m"   -ForegroundColor Red; exit 1 }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

# Write UTF-8 with NO BOM. A BOM in an ini is a needless risk.
function Write-TextNoBom ($Path, $Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

#-------------------------------------------------------------------------------
Head "Checking the server install"

$exe = Join-Path $ServerRoot 'PalServer.exe'
if (-not (Test-Path $exe)) {
    Die "PalServer.exe not found under '$ServerRoot'. In Steam, set the Library filter to Tools, find 'Palworld Dedicated Server' (app 2394010) and let it finish downloading, then re-run."
}
$win64 = Join-Path $ServerRoot 'Pal\Binaries\Win64'
if (-not (Test-Path $win64)) { Die "No Pal\Binaries\Win64 -- this is not a Windows-edition server install." }
Ok "Windows-edition server found: $ServerRoot"

$shipping = Get-ChildItem $win64 -Filter 'PalServer-Win64-Shipping.exe' -ErrorAction SilentlyContinue
if ($shipping) { Ok ("Server binary: {0:N0} bytes, {1:yyyy-MM-dd}" -f $shipping.Length, $shipping.LastWriteTime) }

#-------------------------------------------------------------------------------
Head "First-run bootstrap (generates Saved\Config and Mods)"

$cfgDir  = Join-Path $ServerRoot 'Pal\Saved\Config\WindowsServer'
$cfgFile = Join-Path $cfgDir 'PalWorldSettings.ini'

if ($SkipBootstrap) {
    Say "Skipped by request."
} elseif (Test-Path $cfgFile) {
    Ok "Already bootstrapped ($cfgFile exists)."
} else {
    Say "Starting the server once so it creates its config tree. This takes under a minute."
    $proc = Start-Process -FilePath $exe -WorkingDirectory $ServerRoot -PassThru
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $cfgFile)) { Start-Sleep -Seconds 3 }

    # The shipping child process is the one that must be stopped.
    Get-Process -Name 'PalServer-Win64-Shipping' -ErrorAction SilentlyContinue | Stop-Process -Force -Confirm:$false
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -Confirm:$false -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2

    if (Test-Path $cfgFile) { Ok "Config tree created." }
    else { Warn "Config not generated. Start PalServer.exe by hand once, close it, then re-run with -SkipBootstrap." }
}

#-------------------------------------------------------------------------------
Head "Server settings"

$default = Join-Path $ServerRoot 'DefaultPalWorldSettings.ini'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }

# The server's own first run writes an EMPTY PalWorldSettings.ini -- it exists but
# has no OptionSettings line at all. So "file exists" is not good enough: seed
# whenever the OptionSettings block is absent.
$needsSeed = $true
if (Test-Path $cfgFile) {
    $existing = Get-Content $cfgFile -Raw
    if ($existing -match 'OptionSettings=\(') { $needsSeed = $false }
}
if ($needsSeed) {
    if (-not (Test-Path $default)) { Die "No OptionSettings block, and DefaultPalWorldSettings.ini is missing." }
    if (Test-Path $cfgFile) {
        $stubBackup = "$cfgFile.stub-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
        Copy-Item $cfgFile $stubBackup
        Say "Existing settings file has no OptionSettings block; kept a copy as $(Split-Path -Leaf $stubBackup)"
    }
    Copy-Item $default $cfgFile -Force
    Ok "Seeded PalWorldSettings.ini from DefaultPalWorldSettings.ini."
}

$backup = "$cfgFile.bak-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
Copy-Item $cfgFile $backup
Say "Backed up to $(Split-Path -Leaf $backup)"

$ini = Get-Content $cfgFile -Raw

# All real settings live inside one long OptionSettings=(...) line. Splitting it
# across lines does NOT work -- that is the classic broken-Nitrado-panel failure.
function Set-Option ($text, $key, $value) {
    if ($text -match "OptionSettings=\(") {
        if ($text -match "(?m)([\(,])$key=[^,\)]*") {
            return [regex]::Replace($text, "(?m)([\(,])$key=[^,\)]*", "`${1}$key=$value", 1)
        }
        return [regex]::Replace($text, "(?m)(OptionSettings=\((?:[^\r\n]*?))\)", "`${1},$key=$value)", 1)
    }
    return $text
}

$wanted = [ordered]@{
    'RESTAPIEnabled'                  = 'True'
    'RESTAPIPort'                     = '8212'
    'AdminPassword'                   = '"palmodtest"'
    'ServerName'                      = '"STASIS local test"'
    'bAutoResetGuildNoOnlinePlayers'  = 'False'   # would DELETE offline guilds' base pals
    'bIsUseBackupSaveData'            = 'True'
    'bAllowClientMod'                 = 'True'
}
$failed = @()
foreach ($k in $wanted.Keys) {
    $ini = Set-Option $ini $k $wanted[$k]
    # Report what the file actually says, not what we intended to write.
    if ($ini -match "[\(,]$k=([^,\)]*)") {
        Say ("{0,-32} = {1}" -f $k, $Matches[1])
    } else {
        $failed += $k
        Warn ("{0,-32} FAILED to apply" -f $k)
    }
}
Write-TextNoBom $cfgFile $ini

if ($failed.Count -gt 0) {
    Warn "These settings did not apply: $($failed -join ', '). Edit the file by hand."
} else {
    Ok "PalWorldSettings.ini updated; all settings verified present."
}

#-------------------------------------------------------------------------------
Head "Pinning DedicatedServerName (do this BEFORE installing UE4SS)"

$gusDir  = $cfgDir
$gusFile = Join-Path $gusDir 'GameUserSettings.ini'
$serverId = 'guildstasis-local-test'

if (Test-Path $gusFile) { $gus = Get-Content $gusFile -Raw } else { $gus = '' }
if ($gus -match 'DedicatedServerName=(\S+)') {
    Ok "DedicatedServerName already set to '$($Matches[1])' -- left alone."
} else {
    if ($gus -notmatch '\[/Script/Pal\.PalGameUserSettings\]') {
        if ($gus.Length -gt 0 -and -not $gus.EndsWith("`n")) { $gus += "`r`n" }
        $gus += "[/Script/Pal.PalGameUserSettings]`r`nDedicatedServerName=$serverId`r`n"
    } else {
        $gus = $gus -replace '(\[/Script/Pal\.PalGameUserSettings\])', "`$1`r`nDedicatedServerName=$serverId"
    }
    Write-TextNoBom $gusFile $gus
    Ok "DedicatedServerName=$serverId written. This is the UE4SS #1091 mitigation."
}

#-------------------------------------------------------------------------------
Head "Staging mods into Mods\Workshop"

$modsDir  = Join-Path $ServerRoot 'Mods'
$wsDir    = Join-Path $modsDir 'Workshop'
New-Item -ItemType Directory -Force -Path $wsDir | Out-Null
Ok "Workshop staging dir: $wsDir"

# --- UE4SS -------------------------------------------------------------------
$ue4ssPackage = $null
$ue4ssItem = Join-Path $WorkshopContent '3625223587'
if (Test-Path $ue4ssItem) {
    $dest = Join-Path $wsDir 'UE4SS'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $ue4ssItem '*') $dest -Recurse -Force
    Ok "Copied UE4SS workshop item -> $dest"

    $infoPath = Join-Path $dest 'Info.json'
    if (Test-Path $infoPath) {
        try {
            $ue4ssPackage = (Get-Content $infoPath -Raw | ConvertFrom-Json).PackageName
            Ok "UE4SS PackageName read from its own Info.json: '$ue4ssPackage'"
        } catch { Warn "Could not parse UE4SS Info.json: $_" }
    } else {
        Warn "No Info.json inside the UE4SS item. It may not be packaged for the official loader; you would then have to install UE4SS manually into Pal\Binaries\Win64 instead (and NOT both ways)."
    }
} else {
    Warn "UE4SS workshop item not found at $ue4ssItem"
    Say  "Subscribe to workshop item 3625223587 ('UE4SS Experimental (Palworld)') on your CLIENT, let Steam download it, then re-run this script."
}

# --- this mod ----------------------------------------------------------------
$modInfo = Join-Path $ModSource 'Info.json'
if (-not (Test-Path $modInfo)) { Die "No Info.json in '$ModSource'." }
$modPackage = (Get-Content $modInfo -Raw | ConvertFrom-Json).PackageName

$modDest = Join-Path $wsDir $modPackage
New-Item -ItemType Directory -Force -Path $modDest | Out-Null
foreach ($item in @('Info.json','enabled.txt','Scripts')) {
    $src = Join-Path $ModSource $item
    if (Test-Path $src) { Copy-Item $src $modDest -Recurse -Force }
}
Ok "Copied '$modPackage' -> $modDest"

#-------------------------------------------------------------------------------
Head "Writing Mods\PalModSettings.ini"

$active = @()
if ($ue4ssPackage) { $active += $ue4ssPackage } else { $active += 'UE4SS' }
$active += $modPackage

$lines = @('[PalModSettings]', 'bGlobalEnableMod=true')
foreach ($a in $active) { $lines += "ActiveModList=$a" }
$lines += "WorkshopRootDir=$wsDir"
$lines += 'ConfigVersion=1.0'

$pms = Join-Path $modsDir 'PalModSettings.ini'
if (Test-Path $pms) {
    $pmsBackup = "$pms.bak-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
    Copy-Item $pms $pmsBackup -ErrorAction SilentlyContinue
    Say "Backed up existing PalModSettings.ini to $(Split-Path -Leaf $pmsBackup)"
}
Write-TextNoBom $pms (($lines -join "`r`n") + "`r`n")
Ok "Wrote $pms"
$lines | ForEach-Object { Say "  $_" }

if (-not $ue4ssPackage) {
    Warn "ActiveModList=UE4SS is a GUESS. The loader matches the PackageName inside Info.json, not the folder name. Fix this line once you have the real UE4SS package."
}

#-------------------------------------------------------------------------------
Head "Checking for a conflicting legacy UE4SS"

$legacy = @()
foreach ($n in @('dwmapi.dll','ue4ss','UE4SS.dll','xinput1_3.dll')) {
    $p = Join-Path $win64 $n
    if (Test-Path $p) { $legacy += $n }
}
if ($legacy.Count -gt 0) {
    Warn "Found in Pal\Binaries\Win64: $($legacy -join ', ')"
    Warn "A legacy manual UE4SS alongside the Workshop copy WILL crash the server. Rename these to .bak before starting."
} else {
    Ok "No legacy UE4SS in Pal\Binaries\Win64."
}

#-------------------------------------------------------------------------------
Head "Ready"

Write-Host @"
  Next:
    1. Start the server:   $exe
    2. Watch the log:      $ServerRoot\Mods\NativeMods\UE4SS\UE4SS.log
                    (or)   $win64\ue4ss\UE4SS.log
       Look for [STASIS] lines. The mod's first recon pass runs 20s after load.
    3. Join from your client: Join via IP  ->  127.0.0.1:8211
    4. Make a guild, build a base camp, assign a few Pals to it.
    5. Re-read the log. The recon pass lists every guild, member, camp and Pal
       it can see, plus an OK/MISSING line per identifier.

  The mod is in recon mode with dry_run = true: it will not modify anything.
  Config lives at $modDest\Scripts\config.lua
"@ -ForegroundColor Gray
