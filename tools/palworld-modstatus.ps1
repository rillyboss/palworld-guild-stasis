<#
.SYNOPSIS
  Is Guild Stasis alive and actually working on a remote server?

.DESCRIPTION
  You cannot attach a debugger to a rented game server, so this pulls the mod's
  own evidence and judges it:

    1. LOADED?    the mod's banner and the login-hook registration in UE4SS.log
    2. ALIVE?     HEARTBEAT lines, and how stale the newest one is. A missing or
                  stale heartbeat is the signature of UE4SS timer death, where the
                  mod stays installed but silently stops doing anything.
    3. WORKING?   the per-guild status JSON: which guilds are protected, and
                  crucially decay_zero vs decay_nonzero, read back AFTER the write.
                  decay_nonzero > 0 on a protected guild means the writes are not
                  landing, which no amount of log-reading would tell you.
    4. CLEAN?     Lua errors and write failures.

  Read-only. Downloads, never uploads.

.PARAMETER HostName
  Config name, e.g. 'bisect'

.PARAMETER Tail
  How many recent [STASIS] log lines to show. 0 for none.

.PARAMETER MaxHeartbeatAgeSec
  Fail if the newest heartbeat is older than this. Default 180 (six sweeps at the
  30s default), which tolerates a slow sweep but catches a dead loop.

.EXAMPLE
  .\palworld-modstatus.ps1 -HostName bisect
  .\palworld-modstatus.ps1 -HostName bisect -Tail 40
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [int] $Tail = 15,
    [int] $MaxHeartbeatAgeSec = 180
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'palhost.ps1')

function Say  ($m) { Write-Host "  $m" }
function Good ($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Head ($m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

$fail = 0
try {
    $h = Use-PalHostAny -Name $HostName
    Head "Host"
    Say "$($h.Name)  ($($h.Protocol) $($h.Endpoint))"

    $work = Join-Path $env:TEMP ("modstatus-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    #-- log ---------------------------------------------------------------------
    Head "UE4SS log"
    $logRemote = 'Pal/Binaries/Win64/ue4ss/UE4SS.log'
    $logLocal = $null
    try {
        $size = Get-PalSize -Path $logRemote
        Say ("size: {0:N0} bytes" -f $size)
        if ($h.Protocol -eq 'sftp') { $logLocal = Save-SftpFile -RemotePath (Resolve-PalPath -Path $logRemote) -LocalDir $work }
        else { $logLocal = Join-Path $work 'UE4SS.log'; Save-FtpFile -Path (Resolve-PalPath -Path $logRemote) -Destination $logLocal | Out-Null }
    } catch { Bad "could not download UE4SS.log: $($_.Exception.Message)"; $fail++ }

    $stasis = @()
    if ($logLocal -and (Test-Path -LiteralPath $logLocal)) {
        $stasis = @(Select-String -LiteralPath $logLocal -Pattern '\[STASIS\]' | ForEach-Object { $_.Line })

        #-- 1. loaded -----------------------------------------------------------
        Head "1. Loaded?"
        $banner = $stasis | Where-Object { $_ -match 'GuildStasis v[\d\.]+ loading' } | Select-Object -Last 1
        if ($banner) { Good ($banner -replace '^\[([\d\-]+\s[\d:]+)\.\d+\].*\[STASIS\]\s*','$1  ') } else { Bad "mod banner not found -- not loaded"; $fail++ }
        # Anchor on the startup banner's shape, not just 'mode=... dry_run=', or the
        # 'status' command's own reply (which contains the same text) wins.
        $cfgline = $stasis | Where-Object { $_ -match 'mode=\w+ dry_run=\S+ freeze_hunger=' } | Select-Object -Last 1
        if ($cfgline) { Say ($cfgline -replace '^.*\[STASIS\]\s*','config: ') }
        $hook = $stasis | Where-Object { $_ -match 'login hook.*registered' } | Select-Object -Last 1
        if ($hook) { Good "login hook registered" } else { Warn "login hook not confirmed (un-suppress will rely on the poll only)" }

        #-- 2. alive ------------------------------------------------------------
        Head "2. Alive? (heartbeat)"
        $hb = @($stasis | Where-Object { $_ -match 'HEARTBEAT' })
        if ($hb.Count -eq 0) {
            Warn "no HEARTBEAT lines. Either this build predates them, or no sweep has completed."
        } else {
            $last = $hb[-1]
            Say ($last -replace '^\[([\d\-]+\s[\d:]+)\.\d+\].*\[STASIS\]\s*','$1  ')
            Say "heartbeats seen: $($hb.Count)"
            # The server clock can be hours off ours, so comparing its timestamps to
            # local time is meaningless (it produced a -21573s "age" on Bisect).
            # Measure freshness against the log's OWN newest line instead: that is
            # self-consistent regardless of skew.
            $allTs = @(Select-String -LiteralPath $logLocal -Pattern '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)' |
                       ForEach-Object { $_.Matches[0].Groups[1].Value } )
            if ($last -match '^\[([\d\-]+\s[\d:]+)' -and $allTs.Count -gt 0) {
                $hbTs  = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
                $logTs = [datetime]::ParseExact($allTs[-1], 'yyyy-MM-dd HH:mm:ss', $null)
                $age = [int]($logTs - $hbTs).TotalSeconds
                Say "newest heartbeat is ${age}s behind the newest log line (skew-independent)"
                if ($age -le $MaxHeartbeatAgeSec) { Good "sweep loop is alive" }
                else { Bad "heartbeat is stale by ${age}s of server time -- the sweep loop has likely died"; $script:fail++ }
            }
            if ($last -match 'sweep=(\d+)')        { Say "sweeps completed : $($Matches[1])" }
            if ($last -match 'write_errors=(\d+)') {
                if ([int]$Matches[1] -gt 0) { Bad "write_errors=$($Matches[1])"; $fail++ } else { Good "no write errors" }
            }
        }

        #-- 4. clean ------------------------------------------------------------
        Head "4. Errors"
        $errs = @(Select-String -LiteralPath $logLocal -Pattern 'sweep error|startup pass error|FATAL|Lua error|WARN:' | ForEach-Object { $_.Line })
        if ($errs.Count -eq 0) { Good "no mod errors or warnings in the log" }
        else {
            Warn "$($errs.Count) error/warning line(s):"
            $errs | Select-Object -Last 8 | ForEach-Object { Say "  $($_ -replace '^\[([\d\-]+\s[\d:]+)\.\d+\]\s*','$1 ')" }
        }
    }

    #-- 3. working --------------------------------------------------------------
    Head "3. Working? (status JSON)"
    $cfg = Get-PalHostCfg
    $statusRemote = if ($cfg.ContainsKey('StatusFile') -and $cfg.StatusFile) { $cfg.StatusFile } else { 'Pal/Binaries/Win64/ue4ss/Mods/GuildStasis/status.json' }
    $st = $null
    try { $st = Get-PalText -Path $statusRemote | ConvertFrom-Json } catch { }
    if (-not $st) {
        Warn "no status JSON at $statusRemote"
        Say  "Enable it by setting status_file in the mod's config.lua, e.g."
        Say  '  status_file = "ue4ss/Mods/GuildStasis/status.json"'
        Say  "(path is relative to Pal/Binaries/Win64, the server's working directory)"
    } else {
        Say "sweep=$($st.sweep)  uptime=$($st.uptime_s)s  mode=$($st.mode)  dry_run=$($st.dry_run)"
        Say "sanity_mode=$($st.sanity_mode)  stop_work=$($st.stop_work)"
        Say "guilds=$($st.guild_count)  camps=$($st.camp_count)  online=$($st.players_online)"
        Write-Host ""
        Write-Host ("  {0,-26} {1,-9} {2,5} {3,5} {4,9} {5,8} {6,8} {7,5}" -f 'guild','protected','camps','pals','offline_s','decay0','decayN','sick') -ForegroundColor Gray
        foreach ($g in $st.guilds) {
            $nm = if ($g.name) { $g.name } else { $g.id.Substring(0,8) }
            if ($nm.Length -gt 26) { $nm = $nm.Substring(0,26) }
            Write-Host ("  {0,-26} {1,-9} {2,5} {3,5} {4,9} {5,8} {6,8} {7,5}" -f `
                $nm, $g.protected, $g.camps, $g.pals, $g.offline_s, $g.decay_zero, $g.decay_nonzero, $g.sick)
        }
        # The real verdict: are the writes landing on protected guilds?
        $protected = @($st.guilds | Where-Object { $_.protected -eq $true })
        if ($protected.Count -eq 0) { Say ""; Say "no guild currently protected (nobody has been offline past the grace delay)" }
        else {
            $leaky = @($protected | Where-Object { [int]$_.decay_nonzero -gt 0 })
            if ($st.dry_run -eq $true) {
                Warn "dry_run is ON, so decay is expected to stay non-zero. Flip dry_run=false to act."
            } elseif ($leaky.Count -eq 0) {
                Good "every protected guild has decay=0 on all its pals -- suppression is landing"
            } else {
                Bad "$($leaky.Count) protected guild(s) still have pals with decay != 0 -- writes are NOT landing"
                $leaky | ForEach-Object { Say "  $($_.name): $($_.decay_nonzero) of $($_.pals) pals not suppressed" }
                $fail++
            }
        }
    }

    #-- recent log tail ---------------------------------------------------------
    if ($Tail -gt 0 -and $stasis.Count -gt 0) {
        Head "Recent [STASIS] lines (last $Tail)"
        $stasis | Select-Object -Last $Tail | ForEach-Object { Say ($_ -replace '^\[([\d\-]+\s[\d:]+)\.\d+\]\s*\[Lua\]\s*\[STASIS\]\s*','$1  ') }
    }

    Head "Verdict"
    if ($fail -eq 0) { Good "no blocking problems"; exit 0 }
    Bad "$fail problem(s)"
    exit 1
}
finally { try { Close-PalHost } catch {} }
