<#
.SYNOPSIS
  Observe whether a guild's base Pals are working. The external oracle for M7/M10.

.DESCRIPTION
  Whatever mechanism v2 ends up using, this observes its effect independently.
  Keeping mutation and observation separate means the evidence does not depend on
  the mod's own assumptions about what it changed.

  Originally written to watch the CurrentOrderType probe, which was deleted: that
  enum turned out to be EPalMapBaseCampWorkerOrderType { Work, BattleFighter,
  BattleAllWorker }, a battle order with no idle value. This tool outlived it
  because "are these Pals actually working" is the question either way.

  Polls GET /v1/api/game-data and reports each base Pal's AI_Action, classified:

    WORKING  BP_AIAction_Worker_Working, BaseCampWorker_Approach, PalActionTransport*
    IDLE     BaseCampWorker_Wait, BaseCampWorker_Sleep, AIActionBaseCamp_Sleep
    OTHER    anything else (printed verbatim so it can be classified later)

  Emits a line only when the aggregate picture changes, so the output lines up
  against the probe's ORDERTYPE markers in UE4SS.log without drowning in noise.

  Needs the game-data endpoint, which requires launching the server with
  -enable-gamedata-api. It is NOT available on hosts that don't let you set launch
  arguments, which is why this is a local-testing tool.

.PARAMETER HostName
  Config name for REST access, e.g. 'local'.

.PARAMETER Seconds
  How long to watch. Default 480. M7 wants at least 300s of a suppressed guild
  reporting no working Pals.

.EXAMPLE
  .\palworld-ordertype-watch.ps1 -HostName local
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [int] $Seconds = 480,
    [int] $IntervalSec = 10
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'palhost.ps1')

function Classify([string]$ai) {
    if ([string]::IsNullOrWhiteSpace($ai)) { return 'IDLE' }
    if ($ai -match 'Worker_Working|BaseCampWorker_Approach|Transport') { return 'WORKING' }
    if ($ai -match 'Wait|Sleep')                                        { return 'IDLE' }
    return 'OTHER'
}

try {
    Use-PalHostAny -Name $HostName | Out-Null
    Write-Host "watching for ${Seconds}s, sampling every ${IntervalSec}s" -ForegroundColor Cyan
    Write-Host "correlate these timestamps with ORDERTYPE markers in UE4SS.log" -ForegroundColor Gray
    Write-Host ""

    $deadline = (Get-Date).AddSeconds($Seconds)
    $prev = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $g = Invoke-PalRest -Endpoint 'game-data'
            $pals = @($g.ActorData | Where-Object { $_.UnitType -eq 'BaseCampPal' })
            $groups = $pals | Group-Object { Classify $_.AI_Action }
            $summary = ($groups | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
            $others = @($pals | Where-Object { (Classify $_.AI_Action) -eq 'OTHER' } |
                        Select-Object -ExpandProperty AI_Action -Unique)
            $line = "$summary" + $(if ($others.Count) { "  other:[" + ($others -join ', ') + "]" } else { "" })
            if ($line -ne $prev) {
                Write-Host ("{0}  pals={1,-3} {2}" -f (Get-Date -Format 'HH:mm:ss'), $pals.Count, $line)
                $prev = $line
            }
        } catch {
            Write-Host ("{0}  game-data unavailable: {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds $IntervalSec
    }
    Write-Host ""
    Write-Host "done. M7 passes only if WORKING held at 0 for the whole window for the suppressed" -ForegroundColor Gray
    Write-Host "guild while another guild's Pals kept working. Under the Pal Box parking design the" -ForegroundColor Gray
    Write-Host "stronger result is pals=0 for that guild: parked Pals leave the world entirely." -ForegroundColor Gray
}
finally { try { Close-PalHost } catch {} }
