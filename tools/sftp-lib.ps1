<#
  SFTP primitives, for hosts that speak SFTP rather than plain FTP.

  Nitrado is FTP on port 21; BisectHosting is SFTP on port 2022. The FTP helpers
  in nitrado-lib.ps1 use FtpWebRequest, which cannot do SFTP at all, so this
  provides the same operations over SSH.

  Requires Posh-SSH:
      Install-Module Posh-SSH -Scope CurrentUser

  Dot-source this, don't run it:
      . .\sftp-lib.ps1
#>

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    throw "Posh-SSH is not installed. Run: Install-Module Posh-SSH -Scope CurrentUser -Force"
}
Import-Module Posh-SSH -ErrorAction Stop

$script:SftpSession = $null
$script:SftpCfg     = $null

function Connect-PalSftp {
    param([Parameter(Mandatory)][hashtable]$Config)
    foreach ($k in @('SftpHost','SftpUser','SftpPass')) {
        if (-not $Config.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$Config[$k])) {
            throw "SFTP config is missing '$k'."
        }
    }
    $port = if ($Config.ContainsKey('SftpPort') -and $Config.SftpPort) { [int]$Config.SftpPort } else { 22 }
    $sec  = ConvertTo-SecureString $Config.SftpPass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($Config.SftpUser, $sec)

    if ($script:SftpSession) {
        try { Remove-SFTPSession -SessionId $script:SftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    $script:SftpSession = New-SFTPSession -ComputerName $Config.SftpHost -Port $port -Credential $cred `
                                          -AcceptKey -ConnectionTimeout 30 -ErrorAction Stop
    $script:SftpCfg = $Config
    return $script:SftpSession
}

function Get-PalSftpSessionId {
    if (-not $script:SftpSession) { throw "Not connected. Call Connect-PalSftp first." }
    # Reconnect transparently if the session dropped.
    if (-not (Test-SFTPPath -SessionId $script:SftpSession.SessionId -Path '.' -ErrorAction SilentlyContinue)) {
        Connect-PalSftp -Config $script:SftpCfg | Out-Null
    }
    return $script:SftpSession.SessionId
}

function Disconnect-PalSftp {
    if ($script:SftpSession) {
        try { Remove-SFTPSession -SessionId $script:SftpSession.SessionId -ErrorAction SilentlyContinue | Out-Null } catch {}
        $script:SftpSession = $null
    }
}

# NOTE: deliberately NOT named Test-SftpPath. PowerShell function names are
# case-insensitive, so that name shadows Posh-SSH's own Test-SFTPPath and makes
# this function call itself -- which fails with "cannot find parameter SessionId"
# and silently poisons every other call that depends on it.
function Test-PalSftpPath {
    param([Parameter(Mandatory)][string]$Path)
    try { return (Test-SFTPPath -SessionId (Get-PalSftpSessionId) -Path $Path -ErrorAction Stop) }
    catch { return $false }
}

# Returns Name / IsDir / Size / Path, matching the FTP helper's shape so callers
# can be written once.
function Get-SftpChildren {
    param([Parameter(Mandatory)][string]$Path, [switch]$Quiet)
    try {
        $items = Get-SFTPChildItem -SessionId (Get-PalSftpSessionId) -Path $Path -ErrorAction Stop
        $out = @()
        foreach ($i in $items) {
            if ($i.Name -in @('.', '..')) { continue }
            $out += [pscustomobject]@{
                Name  = $i.Name
                IsDir = [bool]$i.IsDirectory
                Size  = [int64]$i.Length
                Path  = ($Path.TrimEnd('/') + '/' + $i.Name)
            }
        }
        return $out
    } catch { if ($Quiet) { return @() } else { throw } }
}

function Get-SftpFileText {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-SFTPContent -SessionId (Get-PalSftpSessionId) -Path $Path -ContentType String -ErrorAction Stop)
}

function Get-SftpFileSize {
    param([Parameter(Mandatory)][string]$Path)
    $parent = ($Path -replace '/[^/]+$', ''); if ($parent -eq '') { $parent = '.' }
    $leaf   = ($Path -split '/')[-1]
    $hit = Get-SftpChildren -Path $parent -Quiet | Where-Object { $_.Name -eq $leaf -and -not $_.IsDir } | Select-Object -First 1
    if ($hit) { return $hit.Size }
    return -1
}

function New-SftpDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $id = Get-PalSftpSessionId
    if (Test-PalSftpPath -Path $Path) { return }
    # Create each level; SFTP mkdir is not recursive.
    $parts = $Path.Trim('/') -split '/'
    $cur = ''
    foreach ($p in $parts) {
        $cur = if ($cur -eq '') { $p } else { "$cur/$p" }
        if (-not (Test-PalSftpPath -Path $cur)) {
            try { New-SFTPItem -SessionId $id -Path $cur -ItemType Directory -ErrorAction Stop | Out-Null }
            catch { if ($_.Exception.Message -notmatch 'exists') { throw } }
        }
    }
}

# Set-SFTPItem names the remote file after the LOCAL file, and has no way to
# override that. So uploading C:\Temp\tmp1234.tmp to a remote dir creates
# tmp1234.tmp there, not the name you asked for. That silently broke the Win64
# write test (it verified a name that was never created) AND littered the server
# with tmp files. Fix: stage a copy under the exact target leaf name first.
function Send-SftpFile {
    param([Parameter(Mandatory)][string]$LocalPath, [Parameter(Mandatory)][string]$RemotePath)
    $id = Get-PalSftpSessionId
    $remoteDir = ($RemotePath -replace '/[^/]+$', '')
    $leaf      = ($RemotePath -split '/')[-1]
    if ($remoteDir -and $remoteDir -ne $RemotePath) { New-SftpDirectory -Path $remoteDir }

    $localSize = (Get-Item $LocalPath).Length
    $stage = $null
    try {
        if ((Split-Path -Leaf $LocalPath) -eq $leaf) {
            $upload = $LocalPath
        } else {
            $stage  = Join-Path ([IO.Path]::GetTempPath()) ("palstage-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            $upload = Join-Path $stage $leaf
            Copy-Item $LocalPath $upload -Force
        }
        Set-SFTPItem -SessionId $id -Path $upload -Destination $remoteDir -Force -ErrorAction Stop | Out-Null
    } finally {
        # Defensive: only ever delete a path we just created under TEMP, and never
        # anything short enough to be a root. A recursive delete driven by a
        # variable is worth this much paranoia.
        if ($stage -and $stage.Length -gt 12 -and
            $stage.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $remoteSize = Get-SftpFileSize -Path $RemotePath
    return [pscustomobject]@{
        LocalPath = $LocalPath; RemotePath = $RemotePath
        LocalSize = $localSize; RemoteSize = $remoteSize
        Ok = ($remoteSize -eq $localSize)
    }
}

function Send-SftpTree {
    param(
        [Parameter(Mandatory)][string]$LocalRoot,
        [Parameter(Mandatory)][string]$RemoteRoot,
        [string[]]$ExcludeDirs = @()
    )
    $results = @()
    New-SftpDirectory -Path $RemoteRoot
    foreach ($item in (Get-ChildItem $LocalRoot -Force)) {
        if ($item.PSIsContainer) {
            if ($ExcludeDirs -contains $item.Name) { continue }
            $results += Send-SftpTree -LocalRoot $item.FullName -RemoteRoot "$RemoteRoot/$($item.Name)" -ExcludeDirs $ExcludeDirs
        } else {
            try   { $results += Send-SftpFile -LocalPath $item.FullName -RemotePath "$RemoteRoot/$($item.Name)" }
            catch { $results += [pscustomobject]@{ LocalPath=$item.FullName; RemotePath="$RemoteRoot/$($item.Name)"
                                                   LocalSize=$item.Length; RemoteSize=-1; Ok=$false; Error=$_.Exception.Message } }
        }
    }
    return $results
}

function Save-SftpFile {
    param([Parameter(Mandatory)][string]$RemotePath, [Parameter(Mandatory)][string]$LocalDir)
    if (-not (Test-Path $LocalDir)) { New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null }
    Get-SFTPItem -SessionId (Get-PalSftpSessionId) -Path $RemotePath -Destination $LocalDir -Force -ErrorAction Stop | Out-Null
    $leaf = ($RemotePath -split '/')[-1]
    return (Join-Path $LocalDir $leaf)
}

# Recursive download, returning the same manifest shape as the FTP version so the
# backup script can be written once.
function Save-SftpTree {
    param(
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$Destination,
        [int]$Depth = 0,
        [int]$MaxDepth = 12,
        [string[]]$ExcludeDirs = @()
    )
    $manifest = @()
    if ($Depth -gt $MaxDepth) { return $manifest }
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }

    foreach ($c in (Get-SftpChildren -Path $RemotePath -Quiet)) {
        if ($c.IsDir) {
            if ($ExcludeDirs -contains $c.Name) { continue }
            $manifest += Save-SftpTree -RemotePath $c.Path -Destination (Join-Path $Destination $c.Name) `
                                       -Depth ($Depth + 1) -MaxDepth $MaxDepth -ExcludeDirs $ExcludeDirs
        } else {
            $local = Join-Path $Destination $c.Name
            try {
                Save-SftpFile -RemotePath $c.Path -LocalDir $Destination | Out-Null
                $size = if (Test-Path -LiteralPath $local) { (Get-Item -LiteralPath $local).Length } else { -1 }
                $manifest += [pscustomobject]@{
                    RemotePath = $c.Path; LocalPath = $local
                    RemoteSize = $c.Size; LocalSize = $size
                    Match      = ($c.Size -eq $size)
                    Sha256     = if ($size -ge 0) { (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash } else { $null }
                }
            } catch {
                $manifest += [pscustomobject]@{
                    RemotePath = $c.Path; LocalPath = $local
                    RemoteSize = $c.Size; LocalSize = -1; Match = $false; Sha256 = $null
                    Error      = $_.Exception.Message
                }
            }
        }
    }
    return $manifest
}

# Which build is this host running? Decides whether UE4SS can work at all.
function Get-PalHostPlatform {
    param([string]$GameRoot = '.')
    $root = $GameRoot.TrimEnd('/')
    $binaries = if ($root -eq '.' -or $root -eq '') { 'Pal/Binaries' } else { "$root/Pal/Binaries" }
    $report = [pscustomobject]@{
        Platform = 'unknown'; Win64Present = $false; LinuxPresent = $false
        ShippingBinary = $null; ModCapable = $false; Notes = @()
    }
    $kids = Get-SftpChildren -Path $binaries -Quiet
    if (-not $kids -or $kids.Count -eq 0) { $report.Notes += "cannot list $binaries"; return $report }

    foreach ($k in $kids) {
        if ($k.IsDir -and $k.Name -eq 'Win64') { $report.Win64Present = $true }
        if ($k.IsDir -and $k.Name -eq 'Linux') { $report.LinuxPresent = $true }
    }
    if ($report.Win64Present) {
        $report.Platform = 'windows'; $report.ModCapable = $true
        $w = Get-SftpChildren -Path "$binaries/Win64" -Quiet
        $b = $w | Where-Object { $_.Name -match 'PalServer-Win64-Shipping' } | Select-Object -First 1
        if ($b) { $report.ShippingBinary = $b.Name }
    } elseif ($report.LinuxPresent) {
        $report.Platform = 'linux'; $report.ModCapable = $false
        $l = Get-SftpChildren -Path "$binaries/Linux" -Quiet
        $b = $l | Where-Object { $_.Name -match 'PalServer-Linux-Shipping' } | Select-Object -First 1
        if ($b) { $report.ShippingBinary = $b.Name }
        $report.Notes += 'Linux build: UE4SS has no working Linux support, so the mod cannot run as designed'
    }
    return $report
}
