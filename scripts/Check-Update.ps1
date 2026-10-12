<#
.SYNOPSIS
    Lightweight update checker for WinRE Manager.

.DESCRIPTION
    Reads the local WinRE.ps1 ScriptVersion / ScriptPatchLevel, fetches the
    remote CHANGELOG.md from the WinRE Manager GitHub repository, parses the
    topmost production version header, and compares them.

    Protocol output (single line, no trailing newline):
        CURRENT              - local and remote match
        UPDATE|vX patch Y    - remote is newer
        AHEAD                - local is newer (dev build)
        ERROR|<reason>       - could not determine

    Caching. The remote version string (e.g. "49|1" meaning remote v49
    patch 1) is cached in %TEMP%\WinRE-Manager-remote-version.txt for
    CacheHours hours. The cache file also records the local version that was
    current when it was written; if the local version has since changed, the
    cache is discarded and a fresh fetch is performed, so a local upgrade
    immediately re-checks against the remote rather than reporting a stale
    comparison. Pass -Force to bypass the cache.

    This script is read-only, requires no elevation, and never modifies the
    machine. If the network is unavailable or the remote format is
    unexpected, it returns an ERROR string; the caller treats that as
    "not available" and does not block the menu.

.PARAMETER LocalScript
    Path to the local WinRE.ps1. Default: WinRE.ps1 next to this script.

.PARAMETER CacheHours
    Cache validity in hours. Default: 24.

.PARAMETER Force
    Skip the cache and do a fresh remote fetch.

.PARAMETER Quiet
    Do not write the cache file. Useful for one-off diagnostic runs.
#>
param(
    [string]$LocalScript,
    [int]$CacheHours = 24,
    [switch]$Force,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# TLS 1.2 is required by raw.githubusercontent.com. Windows PowerShell 5.1
# defaults to older protocols on some configurations; force 1.2 explicitly.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not $LocalScript) {
    $LocalScript = Join-Path $PSScriptRoot 'WinRE.ps1'
}

$cacheFile = Join-Path $env:TEMP 'WinRE-Manager-remote-version.txt'

function Write-Result {
    param([string]$Result)
    Write-Output $Result
}

# --- Read local version ---
if (-not (Test-Path -LiteralPath $LocalScript -PathType Leaf)) {
    Write-Result 'ERROR|local script not found'
    return
}

try {
    $localContent = Get-Content -LiteralPath $LocalScript -Raw -ErrorAction Stop
} catch {
    Write-Result 'ERROR|cannot read local script'
    return
}

$localVerMatch   = [regex]::Match($localContent, '(?m)^\s*\$ScriptVersion\s*=\s*(\d+)')
$localPatchMatch = [regex]::Match($localContent, '(?m)^\s*\$ScriptPatchLevel\s*=\s*"(\d+)"')

if (-not $localVerMatch.Success) {
    Write-Result 'ERROR|cannot parse local version'
    return
}

$localVersion = [int]$localVerMatch.Groups[1].Value
$localPatch   = if ($localPatchMatch.Success) { [int]$localPatchMatch.Groups[1].Value } else { 0 }

# --- Check cached remote version (compare locally regardless of cache) ---
$remoteVersion = $null
$remotePatch   = $null

$localVersionString = "$localVersion.$localPatch"
if (-not $Force -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime
        if ($age.TotalHours -lt $CacheHours) {
            $cached = (Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop).Trim()
            $parts = $cached -split '\|'
            # New format: localVersionString|remoteVersion|remotePatch
            # Legacy format (v49 patch 2 and earlier): remoteVersion|remotePatch
            # Invalidate the cache if it was written when a different local version was current,
            # so a local upgrade immediately re-checks against the remote rather than
            # reporting a stale comparison.
            if ($parts.Count -ge 3 -and $parts[0] -eq $localVersionString) {
                if ($parts[1] -match '^\d+$') {
                    $remoteVersion = [int]$parts[1]
                    $remotePatch   = if ($parts[2] -match '^\d+$') { [int]$parts[2] } else { 0 }
                }
            } elseif ($parts.Count -eq 2 -and $parts[0] -match '^\d+$') {
                # Legacy two-field cache: cannot prove it was written under the current
                # local version. Discard it and fetch fresh.
                Write-Verbose "Legacy cache format; discarding"
            }
            # else: malformed or local-version mismatch; fall through to fetch
        }
    } catch { }
}

# --- Fetch remote version if cache miss or forced ---
if ($null -eq $remoteVersion) {
    $changelogUrls = @(
        'https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/main/CHANGELOG.md',
        'https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/master/CHANGELOG.md'
    )

    $changelogContent = $null
    $lastError        = $null

    foreach ($url in $changelogUrls) {
        try {
            $changelogContent = Invoke-RestMethod -Uri $url -TimeoutSec 6 -UseBasicParsing -ErrorAction Stop
            if ($changelogContent) { break }
        } catch {
            $lastError = $_
        }
    }

    if (-not $changelogContent) {
        $errMsg = if ($lastError) { $lastError.Exception.Message } else { 'network unavailable' }
        if ($errMsg.Length -gt 50) { $errMsg = $errMsg.Substring(0, 47) + '...' }
        Write-Result "ERROR|$errMsg"
        return
    }

    # Harness headers ("## [harness vNN]") do not match; the pattern requires "[v".
    $remoteMatch = [regex]::Match($changelogContent, '(?m)^##\s+\[v(\d+)(?:\s+patch\s+(\d+))?\]')
    if (-not $remoteMatch.Success) {
        Write-Result 'ERROR|cannot parse remote version'
        return
    }

    $remoteVersion = [int]$remoteMatch.Groups[1].Value
    $remotePatch   = if ($remoteMatch.Groups[2].Success) { [int]$remoteMatch.Groups[2].Value } else { 0 }

    if (-not $Quiet) {
        try {
            Set-Content -LiteralPath $cacheFile -Value "$localVersionString|$remoteVersion|$remotePatch" -NoNewline -ErrorAction SilentlyContinue
        } catch { }
    }
}

# --- Compare (always done locally, using fresh local + cached/fetched remote) ---
if ($remoteVersion -gt $localVersion) {
    Write-Result "UPDATE|v$remoteVersion patch $remotePatch"
} elseif ($remoteVersion -eq $localVersion -and $remotePatch -gt $localPatch) {
    Write-Result "UPDATE|v$remoteVersion patch $remotePatch"
} elseif ($remoteVersion -eq $localVersion -and $remotePatch -eq $localPatch) {
    Write-Result 'CURRENT'
} else {
    Write-Result 'AHEAD'
}
