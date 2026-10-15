<#
.SYNOPSIS
    Lightweight update checker for WinRE Manager.

.DESCRIPTION
    Reads the local WinRE.ps1 ScriptVersion / ScriptPatchLevel and compares
    them against the latest remote version.

    The GitHub Releases API is queried first (api.github.com/repos/.../
    releases/latest); the tag_name is parsed for a version. If the API is
    unreachable or the tag format is not recognised, the CHANGELOG.md on
    the main branch is fetched and the topmost production version header
    is parsed. Whichever source resolves first is used.

    Protocol output (single line; the wrapper's for /f consumer strips
    the line terminator):
        CURRENT              - local and remote match
        UPDATE|vX patch Y    - remote is newer
        AHEAD                - local is newer (dev build)
        ERROR|<reason>       - could not determine

    No cache. The wrapper invokes this at most once per session (guarded by
    the UPDATE_STATUS_SET flag in WinRE-Manager.cmd), so a stale-cache class
    of bug cannot occur and no temp file is written. If the network is
    unavailable or the remote format is unexpected, the script returns an
    ERROR string; the caller treats that as "not available" and does not
    block the menu.

    This script is read-only, requires no elevation, and never modifies the
    machine.

.PARAMETER LocalScript
    Path to the local WinRE.ps1. Default: WinRE.ps1 next to this script.
#>
param(
    [string]$LocalScript
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# TLS 1.2 is required by api.github.com and raw.githubusercontent.com on
# Windows PowerShell 5.1 configurations that still default to older
# protocols.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not $LocalScript) {
    $LocalScript = Join-Path $PSScriptRoot 'WinRE.ps1'
}

function Write-Result {
    param([string]$Result)
    Write-Output $Result
}

# Parse a GitHub release tag into a version/patch pair.
# Accepts, in order of specificity:
#   v50-patch-1   v50_patch_1   v50patch1   -> 50, 1
#   v50.1  50.1  v50.1.0                    -> 50, 1
#   v50    50                               -> 50, 0
# Returns $null if the tag does not match any of these.
function ConvertFrom-ReleaseTag {
    param([string]$Tag)
    if (-not $Tag) { return $null }
    $t = $Tag.Trim()
    if ($t -match '^v?(\d+)[._-]?patch[._-]?(\d+)$') {
        return @{ Version = [int]$Matches[1]; Patch = [int]$Matches[2] }
    }
    if ($t -match '^v?(\d+)\.(\d+)(?:\.\d+)?$') {
        return @{ Version = [int]$Matches[1]; Patch = [int]$Matches[2] }
    }
    if ($t -match '^v?(\d+)$') {
        return @{ Version = [int]$Matches[1]; Patch = 0 }
    }
    return $null
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

# --- Remote version ---
$remoteVersion = $null
$remotePatch   = $null

# Primary: GitHub Releases API.
$apiUrl = 'https://api.github.com/repos/ArthurJDurand/WinRE-Manager/releases/latest'
$apiHeaders = @{
    'User-Agent' = 'WinRE-Manager-UpdateCheck'
    'Accept'     = 'application/vnd.github+json'
}
try {
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $apiHeaders -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    if ($release -and $release.tag_name) {
        $parsed = ConvertFrom-ReleaseTag -Tag ([string]$release.tag_name)
        if ($parsed) {
            $remoteVersion = $parsed.Version
            $remotePatch   = $parsed.Patch
        }
    }
} catch { }

# Fallback: CHANGELOG.md on main.
$fallbackLastError = $null
if ($null -eq $remoteVersion) {
    $changelogUrl = 'https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/main/CHANGELOG.md'
    $changelogContent = $null
    try {
        $changelogContent = Invoke-RestMethod -Uri $changelogUrl -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    } catch {
        $fallbackLastError = $_
    }

    if (-not $changelogContent) {
        $errMsg = if ($fallbackLastError) { $fallbackLastError.Exception.Message } else { 'network unavailable' }
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
}

# --- Compare ---
if ($remoteVersion -gt $localVersion) {
    Write-Result "UPDATE|v$remoteVersion patch $remotePatch"
} elseif ($remoteVersion -eq $localVersion -and $remotePatch -gt $localPatch) {
    Write-Result "UPDATE|v$remoteVersion patch $remotePatch"
} elseif ($remoteVersion -eq $localVersion -and $remotePatch -eq $localPatch) {
    Write-Result 'CURRENT'
} else {
    Write-Result 'AHEAD'
}
