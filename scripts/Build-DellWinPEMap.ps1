<#
.SYNOPSIS
    Build DellWinPEMap.json from Dell's DriverPackCatalog.cab.
.DESCRIPTION
    Downloads the Dell catalog CAB, extracts the XML with 7-Zip,
    filters for type=winpe packages, and emits a map keyed by WinPE family.
#>

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$OutputFile  = "F:\Downloads\DellWinPEMap.json"
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

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
if (-not (Test-Path $7Zip)) { Write-T "7-Zip not found at $7Zip - aborting" -L ERROR; return }

# Download CAB
$cabPath = Join-Path $WorkDir "DriverPackCatalog.cab"
Write-T "Downloading Dell catalog CAB ..." -L INFO
for ($retry = 1; $retry -le 3; $retry++) {
    try {
        Invoke-WebRequest -Uri $CabUrl -OutFile $cabPath -Headers $Headers -UseBasicParsing -ErrorAction Stop
        break
    } catch {
        Write-T "Attempt $retry failed: $_" -L WARN
        if ($retry -lt 3) { Start-Sleep 5 }
    }
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

# Parse XML
[xml]$catalog = Get-Content $xmlPath -Raw

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
        if ($hashNode) { $sha256 = "$($hashNode.InnerText)".Trim() }
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
$allSorted = $packs.Values | Sort-Object { try { [DateTime]$_.Date } catch { [DateTime]::MinValue } } -Descending
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

$output = @{
    Generated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Count     = $jsonPacks.Count
    Packs     = $jsonPacks
}

$output | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
Write-T "Map saved: $OutputFile" -L SUCCESS
Write-T "Upload to your Dell map gist and set `$DellWinPEMapUrl in WinRE.ps1" -L INFO
