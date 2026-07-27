<#
  Protocol-agnostic host facade.

  Hosts differ in transport: Nitrado is plain FTP on 21, BisectHosting is SFTP on
  2022. Rather than write every script twice, this picks the implementation from
  the host config and exposes one small API:

      Use-PalHostAny <name>     load config, connect if needed
      Get-PalChildren <path>    -> Name / IsDir / Size / Path
      Get-PalText <path>
      Get-PalSize <path>
      Send-Pal <local> <remote>
      Send-PalTree <localRoot> <remoteRoot> [-ExcludeDirs]
      Get-PalPlatform           -> windows | linux | unknown, and ModCapable
      Close-PalHost

  Protocol is taken from the config's Protocol key, or inferred: SftpHost present
  means sftp, otherwise ftp.

  Dot-source this, don't run it.
#>

. (Join-Path $PSScriptRoot 'nitrado-lib.ps1')

# SFTP support must be dot-sourced at SCRIPT scope, not inside a function --
# dot-sourcing inside Use-PalHostAny put the functions in that call's local scope
# and they vanished the moment it returned. Loaded here, guarded, so an FTP-only
# machine without Posh-SSH still works.
$script:SftpAvailable = $false
if (Get-Module -ListAvailable -Name Posh-SSH) {
    . (Join-Path $PSScriptRoot 'sftp-lib.ps1')
    $script:SftpAvailable = $true
}

$script:PalHostCfg      = $null
$script:PalHostProtocol = $null
$script:PalHostName     = $null

function Use-PalHostAny {
    param([Parameter(Mandatory)][string]$Name)

    $path = Join-Path $PSScriptRoot "$Name.config.ps1"
    if (-not (Test-Path $path)) {
        throw "No config for host '$Name'. Copy one of the .example files to $Name.config.ps1 and fill it in."
    }
    $cfg = & $path
    if ($cfg -isnot [hashtable]) { throw "$Name.config.ps1 must return a hashtable." }

    $proto = if ($cfg.ContainsKey('Protocol') -and $cfg.Protocol) { ([string]$cfg.Protocol).ToLower() }
             elseif ($cfg.ContainsKey('SftpHost') -and $cfg.SftpHost) { 'sftp' }
             else { 'ftp' }

    if (-not $cfg.ContainsKey('GameRoot')) { $cfg['GameRoot'] = '.' }

    switch ($proto) {
        'sftp' {
            if (-not $script:SftpAvailable) {
                throw "Host '$Name' uses SFTP but Posh-SSH is not installed. Run: Install-Module Posh-SSH -Scope CurrentUser -Force"
            }
            Connect-PalSftp -Config $cfg | Out-Null
        }
        'ftp' {
            foreach ($k in @('FtpHost','FtpUser','FtpPass')) {
                if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$cfg[$k])) {
                    throw "$Name.config.ps1 uses FTP but is missing '$k'."
                }
            }
        }
        default { throw "Unknown Protocol '$proto' in $Name.config.ps1 (use 'ftp' or 'sftp')." }
    }

    # Shared helpers (Invoke-PalRest, Test-PalSaveFile) read the injected config.
    Set-PalHostConfig -Config $cfg

    $script:PalHostCfg      = $cfg
    $script:PalHostProtocol = $proto
    $script:PalHostName     = $Name
    return [pscustomobject]@{
        Name = $Name; Protocol = $proto
        Endpoint = if ($proto -eq 'sftp') { "$($cfg.SftpHost):$(if($cfg.SftpPort){$cfg.SftpPort}else{22})" } else { $cfg.FtpHost }
        GameRoot = $cfg.GameRoot
    }
}

function Get-PalHostProtocol { return $script:PalHostProtocol }
function Get-PalHostCfg       { if (-not $script:PalHostCfg) { throw "No host selected. Call Use-PalHostAny first." }; return $script:PalHostCfg }

# Resolve a game-relative path against GameRoot. GameRoot '.' means the SFTP/FTP
# login already lands in the game directory (Bisect), whereas Nitrado needs the
# 'palworld' prefix.
function Resolve-PalPath {
    param([Parameter(Mandatory)][string]$Path)
    $root = ([string](Get-PalHostCfg).GameRoot).TrimEnd('/')
    if ($root -eq '' -or $root -eq '.') { return $Path.TrimStart('/') }
    return "$root/$($Path.TrimStart('/'))"
}

function Get-PalChildren {
    param([Parameter(Mandatory)][string]$Path, [switch]$Quiet)
    $p = Resolve-PalPath -Path $Path
    if ($script:PalHostProtocol -eq 'sftp') { return Get-SftpChildren -Path $p -Quiet:$Quiet }
    return Get-FtpChildren -Path $p -Quiet:$Quiet
}

function Get-PalText {
    param([Parameter(Mandatory)][string]$Path)
    $p = Resolve-PalPath -Path $Path
    if ($script:PalHostProtocol -eq 'sftp') { return Get-SftpFileText -Path $p }
    return Get-FtpFileText -Path $p
}

function Get-PalSize {
    param([Parameter(Mandatory)][string]$Path)
    $p = Resolve-PalPath -Path $Path
    if ($script:PalHostProtocol -eq 'sftp') { return Get-SftpFileSize -Path $p }
    return Get-FtpFileSize -Path $p
}

function Send-Pal {
    param([Parameter(Mandatory)][string]$LocalPath, [Parameter(Mandatory)][string]$RemotePath)
    $p = Resolve-PalPath -Path $RemotePath
    if ($script:PalHostProtocol -eq 'sftp') { return Send-SftpFile -LocalPath $LocalPath -RemotePath $p }
    return Send-FtpFile -LocalPath $LocalPath -RemotePath $p
}

function Send-PalTree {
    param(
        [Parameter(Mandatory)][string]$LocalRoot,
        [Parameter(Mandatory)][string]$RemoteRoot,
        [string[]]$ExcludeDirs = @()
    )
    $p = Resolve-PalPath -Path $RemoteRoot
    if ($script:PalHostProtocol -eq 'sftp') { return Send-SftpTree -LocalRoot $LocalRoot -RemoteRoot $p -ExcludeDirs $ExcludeDirs }
    return Send-FtpTree -LocalRoot $LocalRoot -RemoteRoot $p -ExcludeDirs $ExcludeDirs
}

# windows | linux | unknown, plus whether UE4SS can run here at all.
function Get-PalPlatform {
    $report = [pscustomobject]@{
        Platform = 'unknown'; Win64Present = $false; LinuxPresent = $false
        ShippingBinary = $null; ModCapable = $false; Notes = @()
    }
    $kids = Get-PalChildren -Path 'Pal/Binaries' -Quiet
    if (-not $kids -or $kids.Count -eq 0) {
        $report.Notes += 'cannot list Pal/Binaries -- either no access (Nitrado-style scoping) or wrong GameRoot'
        return $report
    }
    foreach ($k in $kids) {
        if ($k.IsDir -and $k.Name -eq 'Win64') { $report.Win64Present = $true }
        if ($k.IsDir -and $k.Name -eq 'Linux') { $report.LinuxPresent = $true }
    }
    if ($report.Win64Present) {
        $report.Platform = 'windows'; $report.ModCapable = $true
        $b = Get-PalChildren -Path 'Pal/Binaries/Win64' -Quiet | Where-Object { $_.Name -match 'PalServer-Win64-Shipping' } | Select-Object -First 1
        if ($b) { $report.ShippingBinary = $b.Name }
        $report.Notes += 'Windows build -- UE4SS can be installed into Pal/Binaries/Win64'
    } elseif ($report.LinuxPresent) {
        $report.Platform = 'linux'; $report.ModCapable = $false
        $b = Get-PalChildren -Path 'Pal/Binaries/Linux' -Quiet | Where-Object { $_.Name -match 'PalServer-Linux-Shipping' } | Select-Object -First 1
        if ($b) { $report.ShippingBinary = $b.Name }
        $report.Notes += 'Linux build -- UE4SS has no working Linux support; the mod cannot run as designed'
    }
    return $report
}

# Can we actually write where UE4SS has to live? Probe and clean up.
function Test-PalWin64Writable {
    if (-not (Get-PalChildren -Path 'Pal/Binaries/Win64' -Quiet)) { return $false }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        'probe' | Out-File $tmp -Encoding ascii
        $r = Send-Pal -LocalPath $tmp -RemotePath 'Pal/Binaries/Win64/.palhost-write-test'
        if ($r.Ok) {
            $p = Resolve-PalPath -Path 'Pal/Binaries/Win64/.palhost-write-test'
            try {
                if ($script:PalHostProtocol -eq 'sftp') { Remove-SFTPItem -SessionId (Get-PalSftpSessionId) -Path $p -Force -ErrorAction SilentlyContinue | Out-Null }
                else {
                    Invoke-FtpWithRetry -Retries 2 -What 'delete probe' -Action {
                        $d = New-FtpRequest -Path $p -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
                        $resp = $d.GetResponse(); $resp.Close(); return $true } | Out-Null
                }
            } catch { Write-Warning "left behind .palhost-write-test at $p" }
        }
        return $r.Ok
    } catch { return $false }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Close-PalHost {
    if ($script:PalHostProtocol -eq 'sftp') { Disconnect-PalSftp }
    $script:PalHostCfg = $null; $script:PalHostProtocol = $null; $script:PalHostName = $null
}
