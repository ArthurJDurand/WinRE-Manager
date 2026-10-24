<#
.SYNOPSIS
    Build DellWinPEMap.json from Dell's DriverPackCatalog.cab.
.DESCRIPTION
    Downloads the Dell catalog CAB, extracts the XML with 7-Zip,
    filters for type=winpe packages, and emits a map keyed by WinPE family.
    Selected packs' supplied SHA256/MD5 values are trimmed and validated
    before publication. Missing hashes retain the existing policy.
.NOTES
    Malformed supplied hashes stop publication without replacing the previous
    map. Superseded catalog entries that are not published do not veto a build.
    Current alias selection also supports a single selected pack on PowerShell 5.1.
#>

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# Output directory: prefer ./Maps next to this script, fall back to C:\Temp\Maps.
# Created here so the JSON write at the end of the run cannot fail on a missing parent.
$MapsDir = $null
if ($PSScriptRoot) {
    $candidate = Join-Path $PSScriptRoot "Maps"
    try {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            New-Item -ItemType Directory -Path $candidate -Force -ErrorAction Stop | Out-Null
        }
        $MapsDir = $candidate
    } catch {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Could not use $candidate ($_) - falling back to C:\Temp\Maps" -ForegroundColor Yellow
    }
}
if (-not $MapsDir) {
    $MapsDir = "C:\Temp\Maps"
    if (-not (Test-Path -LiteralPath $MapsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $MapsDir -Force | Out-Null
    }
}
$OutputFile = Join-Path $MapsDir "DellWinPEMap.json"
$WorkDir     = "C:\Temp\DellMapBuild"
$CabUrl      = "https://downloads.dell.com/catalog/DriverPackCatalog.cab"
$7Zip        = "C:\Program Files\7-Zip\7z.exe"
$Headers     = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
}

function Write-T {
    param([string]$M, [string]$L = "INFO")
    $c = switch ($L) { "ERROR"{"Red"} "WARN"{"Yellow"} "SUCCESS"{"Green"} "FOUND"{"Cyan"} default{"Gray"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" -ForegroundColor $c
}

# Keep absent hashes distinct from supplied malformed metadata. Validate only
# selected packs, so an unused historical catalog entry cannot block the map.
function ConvertTo-DellChecksum {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][ValidateSet('SHA256','MD5')][string]$Algorithm,
        [string]$Context
    )
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $normalized = $Value.Trim()
    $expectedLength = if ($Algorithm -eq 'SHA256') { 64 } else { 32 }
    if ($normalized.Length -ne $expectedLength -or $normalized -notmatch '^[a-fA-F0-9]+$') {
        throw "Invalid $Algorithm metadata for Dell $Context; refusing to publish the map."
    }
    return $normalized
}

# Stale-workspace cleanup. Recreate the workspace fresh on every run so that
# a workspace left behind by an earlier interrupted run cannot satisfy this
# run's file-presence checks. Mirrors the equivalent cleanup at the start
# of Inspect-GitHubWinRE.ps1.
if (Test-Path -LiteralPath $WorkDir) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $WorkDir) {
        try { [System.IO.Directory]::Delete($WorkDir, $true) } catch { }
    }
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
if (-not (Test-Path $7Zip)) { Write-T "7-Zip not found at $7Zip - aborting" -L ERROR; return }

# Download CAB
$cabPath = Join-Path $WorkDir "DriverPackCatalog.cab"
Write-T "Downloading Dell catalog CAB ..." -L INFO
for ($retry = 1; $retry -le 3; $retry++) {
    if (Test-Path $cabPath) { Remove-Item $cabPath -Force -ErrorAction SilentlyContinue }
    try {
        Invoke-WebRequest -Uri $CabUrl -OutFile $cabPath -Headers $Headers -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        if ((Test-Path $cabPath) -and (Get-Item $cabPath).Length -gt 0) { break }
        Write-T "Attempt $retry produced a zero-byte file" -L WARN
    } catch {
        Write-T "Attempt $retry failed: $_" -L WARN
    }
    if ($retry -lt 3) { Start-Sleep 5 }
}
if (-not (Test-Path $cabPath)) { Write-T "Could not download CAB" -L ERROR; return }
Write-T "CAB: $((Get-Item $cabPath).Length) bytes" -L SUCCESS

# Extract XML
$extractDir = Join-Path $WorkDir "extracted"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

Write-T "Extracting CAB with 7-Zip ..." -L INFO
& $7Zip x $cabPath -o"$extractDir" -y 2>&1 | Out-Null

$xmlPath = Join-Path $extractDir "DriverPackCatalog.xml"
if (-not (Test-Path $xmlPath)) { Write-T "DriverPackCatalog.xml not found" -L ERROR; return }
Write-T "XML extracted: $((Get-Item $xmlPath).Length) bytes" -L SUCCESS

# Preserve whitespace-only supplied hash content until checksum validation;
# the usual [xml] cast would silently turn such an element into an empty one.
$catalog = [System.Xml.XmlDocument]::new()
$catalog.PreserveWhitespace = $true
$catalog.LoadXml((Get-Content -LiteralPath $xmlPath -Raw))

$base = "$($catalog.DriverPackManifest.baseLocation)".Trim()
if ($base -notmatch '^https?://') { $base = "https://$base" }
if ($base -notmatch '/$') { $base = "$base/" }
Write-T "Base URL: $base" -L INFO

$winpeAll = @($catalog.DriverPackManifest.DriverPackage | Where-Object { $_.type -eq 'winpe' })
Write-T "WinPE packages: $($winpeAll.Count)" -L SUCCESS

# Parse each pack
$parsed = @()
foreach ($pkg in $winpeAll) {
    $name = if ($pkg.Name -is [System.Xml.XmlElement]) { $pkg.Name.InnerText } else { "$($pkg.Name)" }
    $path = "$($pkg.path)"
    $url  = if ($path -match '^https?://') { $path } else { "$base$path" }

    # SHA256 is a child node
    $sha256 = ""
    try {
        $hashNode = $pkg.Cryptography.Hash | Where-Object { $_.algorithm -eq 'SHA256' } | Select-Object -First 1
        if ($hashNode) { $sha256 = "$($hashNode.InnerText)" }
    } catch { }

    $parsed += [PSCustomObject]@{
        Name         = $name
        DellVersion  = "$($pkg.dellVersion)"
        ReleaseID    = "$($pkg.releaseID)"
        Date         = "$($pkg.dateTime)"
        Url          = $url
        MD5          = "$($pkg.hashMD5)"
        SHA256       = $sha256
        SizeBytes    = [int64]"$($pkg.size)"
        Type         = "$($pkg.type)"
        Path         = $path
    }
}

# Determine WinPE generation from the package filename
function Get-WinPEGeneration {
    param([string]$Name)
    if ($Name -match 'WinPE(\d+)') { return "WinPE$($Matches[1])" }
    return "Unknown"
}

# Build map keyed by generation; keep newest per generation
$packs = @{}
foreach ($p in $parsed) {
    $gen = Get-WinPEGeneration -Name $p.Name
    if ($gen -eq 'Unknown') { continue }

    if (-not $packs.ContainsKey($gen)) {
        $packs[$gen] = $p
    } else {
        $existingDate = try { [DateTime]$packs[$gen].Date } catch { [DateTime]::MinValue }
        $newDate      = try { [DateTime]$p.Date } catch { [DateTime]::MinValue }
        if ($newDate -gt $existingDate) { $packs[$gen] = $p }
    }
}

Write-T ""
Write-T "Selected packs:" -L FOUND
foreach ($gen in @('WinPE11','WinPE10','WinPE5','WinPE4','WinPE3')) {
    if (-not $packs.ContainsKey($gen)) { continue }
    $p = $packs[$gen]
    Write-T "  $gen -> $($p.Name) (v$($p.DellVersion), released $($p.Date))" -L INFO
}

# Convert to JSON-friendly objects
$jsonPacks = @{}
foreach ($gen in $packs.Keys) {
    $p = $packs[$gen]
    # Outside the catalog-parser catch: supplied malformed values must stop
    # publication rather than silently becoming an absent hash.
    $p.SHA256 = ConvertTo-DellChecksum -Value $p.SHA256 -Algorithm SHA256 -Context $p.Name
    $p.MD5 = ConvertTo-DellChecksum -Value $p.MD5 -Algorithm MD5 -Context $p.Name
    $jsonPacks[$gen] = @{
        name        = $p.Name
        dellVersion = $p.DellVersion
        releaseId   = $p.ReleaseID
        date        = $p.Date
        url         = $p.Url
        md5         = $p.MD5
        sha256      = $p.SHA256
        sizeBytes   = $p.SizeBytes
    }
}

# Also set 'Current' alias based on newest across all
$allSorted = @($packs.Values | Sort-Object { try { [DateTime]$_.Date } catch { [DateTime]::MinValue } } -Descending)
if ($allSorted.Count -gt 0) {
    $newest = $allSorted | Select-Object -First 1
    $newestGen = Get-WinPEGeneration -Name $newest.Name
    $jsonPacks['Current'] = @{
        name        = $newest.Name
        dellVersion = $newest.DellVersion
        releaseId   = $newest.ReleaseID
        date        = $newest.Date
        url         = $newest.Url
        md5         = $newest.MD5
        sha256      = $newest.SHA256
        sizeBytes   = $newest.SizeBytes
        generation  = $newestGen
    }
    Write-T ""
    Write-T "Current alias: $($newest.Name) (generation $newestGen)" -L SUCCESS
}

if ($jsonPacks.Count -le 0) {
    Write-T "Generated Dell map is empty - refusing to publish" -L ERROR
    throw "Generated Dell map is empty"
}

$output = @{
    Generated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Count     = $jsonPacks.Count
    Packs     = $jsonPacks
}

[System.IO.File]::WriteAllText($OutputFile, ($output | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
Write-T "Map saved: $OutputFile" -L SUCCESS
Write-T "Upload to your Dell map gist and set `$DellWinPEMapUrl in WinRE.ps1" -L INFO

# Workspace cleanup. The map JSON is written to $MapsDir, which is
# separate from the build workspace. The workspace holds the downloaded
# catalog CAB and the extracted XML, neither of which is needed after the
# map is built. Remove the workspace, then remove the parent directory if
# it is named "Temp" and is now empty. Mirrors Remove-EmptyWorkspaceParent
# in WinRE.ps1.
if (Test-Path -LiteralPath $WorkDir) {
    try {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction Stop
        Write-T "Workspace removed: $WorkDir" -L INFO
    } catch {
        try { [System.IO.Directory]::Delete($WorkDir, $true) } catch { }
        if (Test-Path -LiteralPath $WorkDir) {
            Write-T "Could not remove workspace ${WorkDir}: $_" -L WARN
            Write-T "Manual cleanup:  Remove-Item '$WorkDir' -Recurse -Force" -L WARN
        } else {
            Write-T "Workspace removed: $WorkDir" -L INFO
        }
    }
}
$workspaceParent = $null
try { $workspaceParent = Split-Path -LiteralPath $WorkDir -Parent } catch { }
if ($workspaceParent -and $workspaceParent -notmatch '^[A-Za-z]:\\?$') {
    $leaf = $null
    try { $leaf = Split-Path -LiteralPath $workspaceParent -Leaf } catch { }
    if ($leaf -and [System.StringComparer]::OrdinalIgnoreCase.Equals($leaf, 'Temp')) {
        if (Test-Path -LiteralPath $workspaceParent -PathType Container) {
            $entries = $null
            try { $entries = @(Get-ChildItem -LiteralPath $workspaceParent -Force -ErrorAction Stop) } catch { $entries = $null }
            if ($null -ne $entries -and $entries.Count -eq 0) {
                try {
                    Remove-Item -LiteralPath $workspaceParent -Force -ErrorAction Stop
                    Write-T "Removed empty parent: $workspaceParent" -L INFO
                } catch {
                    try { [System.IO.Directory]::Delete($workspaceParent, $false) } catch { }
                }
            }
        }
    }
}
