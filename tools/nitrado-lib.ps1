<#
  Shared FTP + REST helpers for a Nitrado-hosted Palworld server.

  Dot-source this, don't run it:
      . .\nitrado-lib.ps1

  Credentials come from tools/nitrado.config.ps1, which is gitignored. Copy
  nitrado.config.ps1.example and fill it in. Never commit real credentials --
  Nitrado's FTP is plain FTP on port 21, so they already travel unencrypted;
  there's no reason to also put them in git history.

  NOTE ON SCOPE: Nitrado exposes only Pal/Saved over FTP. Pal/Binaries, Mods,
  Pal/Content, Pal/Plugins and Engine are all inaccessible (verified with
  retries -- they do not appear in a listing of their own parent). So these
  helpers can back up and read config, but cannot install a mod.
#>

$script:NitradoCfg = $null

function Get-NitradoConfig {
    if ($script:NitradoCfg) { return $script:NitradoCfg }
    $path = Join-Path $PSScriptRoot 'nitrado.config.ps1'
    if (-not (Test-Path $path)) {
        throw "Missing $path. Copy nitrado.config.ps1.example and fill it in."
    }
    $cfg = & $path
    foreach ($k in @('FtpHost','FtpUser','FtpPass','GameRoot')) {
        if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$cfg[$k])) {
            throw "nitrado.config.ps1 is missing '$k'."
        }
    }
    $script:NitradoCfg = $cfg
    return $cfg
}

function Get-NitradoCredential {
    $c = Get-NitradoConfig
    return (New-Object System.Net.NetworkCredential($c.FtpUser, $c.FtpPass))
}

function New-FtpRequest {
    param([string]$Path, [string]$Method, [int]$TimeoutMs = 45000)
    $c = Get-NitradoConfig
    $url = "ftp://$($c.FtpHost)/$($Path.TrimStart('/'))"
    $r = [System.Net.FtpWebRequest]::Create($url)
    $r.Credentials = Get-NitradoCredential
    $r.Method      = $Method
    $r.UsePassive  = $true
    $r.UseBinary   = $true
    $r.KeepAlive   = $false
    $r.Timeout     = $TimeoutMs
    return $r
}

# Nitrado's FTP throws transient 450 "file busy" under concurrent access, so
# every operation retries rather than treating one failure as absence.
function Invoke-FtpWithRetry {
    param([scriptblock]$Action, [int]$Retries = 3, [string]$What = 'ftp op')
    $lastErr = $null
    for ($i = 1; $i -le $Retries; $i++) {
        try { return & $Action }
        catch {
            $lastErr = $_.Exception.Message
            if ($i -lt $Retries) { Start-Sleep -Seconds ([Math]::Min(2 * $i, 6)) }
        }
    }
    throw "$What failed after $Retries attempt(s): $lastErr"
}

function Get-FtpListing {
    param([string]$Path, [switch]$Quiet)
    try {
        return Invoke-FtpWithRetry -What "list /$Path" -Action {
            $r = New-FtpRequest -Path $Path -Method ([System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails)
            $resp = $r.GetResponse()
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return $t
        }
    } catch { if ($Quiet) { return $null } else { throw } }
}

# Parses a unix-style FTP listing into objects. Returns Name, IsDir, Size.
function Get-FtpChildren {
    param([string]$Path, [switch]$Quiet)
    $raw = Get-FtpListing -Path $Path -Quiet:$Quiet
    if ($null -eq $raw) { return @() }
    $items = @()
    foreach ($line in ($raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # drwxr-xr-x  3 owner group  4096 Jul 11 03:33 Name With Spaces
        $m = [regex]::Match($line, '^([\-dl])\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(.+)$')
        if (-not $m.Success) { continue }
        $name = $m.Groups[3].Value.Trim()
        if ($name -in @('.', '..')) { continue }
        $items += [pscustomobject]@{
            Name  = $name
            IsDir = ($m.Groups[1].Value -eq 'd')
            Size  = [int64]$m.Groups[2].Value
            Path  = ($Path.TrimEnd('/') + '/' + $name)
        }
    }
    return $items
}

function Get-FtpFileText {
    param([string]$Path)
    return Invoke-FtpWithRetry -What "download /$Path" -Action {
        $r = New-FtpRequest -Path $Path -Method ([System.Net.WebRequestMethods+Ftp]::DownloadFile)
        $resp = $r.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $t = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        return $t
    }
}

function Save-FtpFile {
    param([string]$Path, [string]$Destination)
    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Invoke-FtpWithRetry -What "download /$Path" -Action {
        $r = New-FtpRequest -Path $Path -Method ([System.Net.WebRequestMethods+Ftp]::DownloadFile)
        $resp = $r.GetResponse()
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($Destination)
        try { $in.CopyTo($out) } finally { $out.Close(); $in.Close(); $resp.Close() }
        return $true
    } | Out-Null
    return (Get-Item $Destination).Length
}

# Recursive download. Returns a manifest of every file fetched.
function Save-FtpTree {
    param([string]$Path, [string]$Destination, [int]$Depth = 0, [int]$MaxDepth = 12)
    $manifest = @()
    if ($Depth -gt $MaxDepth) { return $manifest }
    $children = Get-FtpChildren -Path $Path -Quiet
    foreach ($c in $children) {
        $local = Join-Path $Destination $c.Name
        if ($c.IsDir) {
            if (-not (Test-Path $local)) { New-Item -ItemType Directory -Force -Path $local | Out-Null }
            $manifest += Save-FtpTree -Path $c.Path -Destination $local -Depth ($Depth + 1) -MaxDepth $MaxDepth
        } else {
            try {
                $bytes = Save-FtpFile -Path $c.Path -Destination $local
                $manifest += [pscustomobject]@{
                    RemotePath = $c.Path; LocalPath = $local
                    RemoteSize = $c.Size; LocalSize = $bytes
                    Match      = ($c.Size -eq $bytes)
                    Sha256     = (Get-FileHash $local -Algorithm SHA256).Hash
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

#-------------------------------------------------------------------------------
# Multi-host support
#
# Migration means talking to TWO hosts, so the config is switchable. Each host
# gets its own gitignored <name>.config.ps1 alongside this file.
#-------------------------------------------------------------------------------

function Use-PalHost {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $PSScriptRoot "$Name.config.ps1"
    if (-not (Test-Path $path)) { throw "No config for host '$Name' (expected $path)." }
    $cfg = & $path
    foreach ($k in @('FtpHost','FtpUser','FtpPass','GameRoot')) {
        if (-not $cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$cfg[$k])) {
            throw "$Name.config.ps1 is missing '$k'."
        }
    }
    $script:NitradoCfg = $cfg
    Write-Verbose "Active host: $Name ($($cfg.FtpHost))"
    return $cfg
}

#-------------------------------------------------------------------------------
# Upload
#-------------------------------------------------------------------------------

function New-FtpDirectory {
    param([string]$Path)
    try {
        Invoke-FtpWithRetry -Retries 2 -What "mkdir /$Path" -Action {
            $r = New-FtpRequest -Path $Path -Method ([System.Net.WebRequestMethods+Ftp]::MakeDirectory)
            $resp = $r.GetResponse(); $resp.Close(); return $true
        } | Out-Null
    } catch {
        # 550 here almost always means "already exists", which is fine.
        if ($_.Exception.Message -notmatch '550') { throw }
    }
}

function Send-FtpFile {
    param([string]$LocalPath, [string]$RemotePath)
    $bytes = [IO.File]::ReadAllBytes($LocalPath)
    Invoke-FtpWithRetry -What "upload /$RemotePath" -Action {
        $r = New-FtpRequest -Path $RemotePath -Method ([System.Net.WebRequestMethods+Ftp]::UploadFile) -TimeoutMs 120000
        $r.ContentLength = $bytes.Length
        $s = $r.GetRequestStream()
        try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Close() }
        $resp = $r.GetResponse(); $resp.Close(); return $true
    } | Out-Null
    # Verify by reading the size back off the server, not by trusting the write.
    $remote = Get-FtpFileSize -Path $RemotePath
    return [pscustomobject]@{
        LocalPath = $LocalPath; RemotePath = $RemotePath
        LocalSize = $bytes.Length; RemoteSize = $remote
        Ok = ($remote -eq $bytes.Length)
    }
}

# Recursive upload. Creates directories as needed and verifies every file's size
# on the far side.
function Send-FtpTree {
    param([string]$LocalRoot, [string]$RemoteRoot, [string[]]$ExcludeDirs = @())
    $results = @()
    New-FtpDirectory -Path $RemoteRoot
    foreach ($item in (Get-ChildItem $LocalRoot -Force)) {
        if ($item.PSIsContainer) {
            if ($ExcludeDirs -contains $item.Name) { continue }
            $results += Send-FtpTree -LocalRoot $item.FullName `
                                     -RemoteRoot ("$RemoteRoot/$($item.Name)") `
                                     -ExcludeDirs $ExcludeDirs
        } else {
            try   { $results += Send-FtpFile -LocalPath $item.FullName -RemotePath "$RemoteRoot/$($item.Name)" }
            catch { $results += [pscustomobject]@{ LocalPath=$item.FullName; RemotePath="$RemoteRoot/$($item.Name)"
                                                   LocalSize=$item.Length; RemoteSize=-1; Ok=$false; Error=$_.Exception.Message } }
        }
    }
    return $results
}

# Is this host usable for the mod at all? The single most important pre-flight
# check: UE4SS has to live in Pal/Binaries/Win64, so that path must be writable.
function Test-PalHostModCapable {
    param([switch]$Quiet)
    $c = Get-NitradoConfig
    $report = [pscustomobject]@{
        FtpHost = $c.FtpHost; Win64Listable = $false; Win64Writable = $false
        SavedListable = $false; WindowsBuild = $false; Notes = @()
    }
    $win64 = "$($c.GameRoot)/Pal/Binaries/Win64"

    $kids = Get-FtpChildren -Path $win64 -Quiet
    if ($kids -and $kids.Count -gt 0) {
        $report.Win64Listable = $true
        if ($kids | Where-Object { $_.Name -match 'PalServer-Win64-Shipping' }) {
            $report.WindowsBuild = $true
            $report.Notes += 'PalServer-Win64-Shipping present -- Windows build confirmed'
        }
    } else { $report.Notes += "cannot list $win64" }

    if (Get-FtpChildren -Path "$($c.GameRoot)/Pal/Saved" -Quiet) { $report.SavedListable = $true }

    # Write test with a throwaway file, then clean up.
    if ($report.Win64Listable) {
        $probe = "$win64/.palhost-write-test"
        $tmp = [IO.Path]::GetTempFileName()
        try {
            'write test' | Out-File $tmp -Encoding ascii
            $r = Send-FtpFile -LocalPath $tmp -RemotePath $probe
            $report.Win64Writable = $r.Ok
            try {
                Invoke-FtpWithRetry -Retries 2 -What 'delete probe' -Action {
                    $d = New-FtpRequest -Path $probe -Method ([System.Net.WebRequestMethods+Ftp]::DeleteFile)
                    $resp = $d.GetResponse(); $resp.Close(); return $true
                } | Out-Null
            } catch { $report.Notes += 'left behind .palhost-write-test -- delete it manually' }
        } catch { $report.Notes += "write test failed: $($_.Exception.Message)" }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    if (-not $Quiet) {
        Write-Host "  host          : $($report.FtpHost)"
        Write-Host "  Win64 listable: $($report.Win64Listable)"
        Write-Host "  Win64 writable: $($report.Win64Writable)"
        Write-Host "  Windows build : $($report.WindowsBuild)"
        Write-Host "  Saved listable: $($report.SavedListable)"
        $report.Notes | ForEach-Object { Write-Host "  note          : $_" }
    }
    return $report
}

#-------------------------------------------------------------------------------
# Save-file integrity
#
# Comparing a downloaded file against the size from an earlier directory listing
# is unreliable on a LIVE server: the game autosaves, so the listing goes stale
# and a perfectly good download looks like a mismatch. That exact false alarm
# fired on the first real backup.
#
# So verify a save intrinsically instead. A Palworld .sav is:
#   uncompressed_len (4, LE) | compressed_len (4, LE) | magic (3) | save_type (1) | payload
# magic is PlZ (double zlib), PlM (Oodle) or CNK (chunked, nested header).
#-------------------------------------------------------------------------------

function Test-PalSaveFile {
    param([string]$Path)
    $result = [pscustomobject]@{
        Path = $Path; Ok = $false; Magic = $null; SaveType = $null
        UncompressedLen = 0; CompressedLen = 0; PayloadBytes = 0; Reason = $null
    }
    try {
        $fi = Get-Item $Path -ErrorAction Stop
        if ($fi.Length -lt 13) { $result.Reason = 'file too small to hold a header'; return $result }
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 12
            if ($fs.Read($buf, 0, 12) -ne 12) { $result.Reason = 'short read on header'; return $result }
        } finally { $fs.Close() }

        $result.UncompressedLen = [BitConverter]::ToUInt32($buf, 0)
        $result.CompressedLen   = [BitConverter]::ToUInt32($buf, 4)
        $result.Magic           = [Text.Encoding]::ASCII.GetString($buf, 8, 3)
        $result.SaveType        = $buf[11]
        $result.PayloadBytes    = $fi.Length - 12

        if ($result.Magic -notin @('PlZ', 'PlM', 'CNK')) {
            $result.Reason = "unrecognised magic '$($result.Magic)'"
            return $result
        }
        # CNK nests a second header, so its payload accounting differs; only the
        # flat formats can be length-checked this simply.
        if ($result.Magic -ne 'CNK' -and $result.PayloadBytes -lt $result.CompressedLen) {
            $result.Reason = "truncated: payload $($result.PayloadBytes) < compressed_len $($result.CompressedLen)"
            return $result
        }
        $result.Ok = $true
        return $result
    } catch {
        $result.Reason = $_.Exception.Message
        return $result
    }
}

# Re-stat a remote file. Used to tell "our download is stale" apart from "the
# server rewrote the file while we were reading it".
function Get-FtpFileSize {
    param([string]$Path)
    $parent = ($Path -replace '/[^/]+$', '')
    $leaf   = ($Path -split '/')[-1]
    $kids = Get-FtpChildren -Path $parent -Quiet
    $hit = $kids | Where-Object { $_.Name -eq $leaf -and -not $_.IsDir } | Select-Object -First 1
    if ($hit) { return $hit.Size }
    return -1
}

#-------------------------------------------------------------------------------
# REST helpers. The game's own API, reachable on RESTAPIPort.
#-------------------------------------------------------------------------------

function Invoke-PalRest {
    param([string]$Endpoint, [string]$Method = 'GET', $Body = $null, [int]$TimeoutSec = 20)
    $c = Get-NitradoConfig
    if (-not $c.RestBase -or -not $c.AdminPassword) {
        throw "nitrado.config.ps1 needs RestBase and AdminPassword for REST calls."
    }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$($c.AdminPassword)"))
    $headers = @{ Authorization = "Basic $b64" }
    $uri = "$($c.RestBase.TrimEnd('/'))/v1/api/$Endpoint"
    if ($Method -eq 'GET') {
        return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec $TimeoutSec
    }
    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec $TimeoutSec `
                             -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress)
}

function Get-PalSettingValue {
    param([string]$IniText, [string]$Key)
    if ($IniText -match "$Key=([^,\)]*)") { return $Matches[1] }
    return $null
}
