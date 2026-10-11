<#
.SYNOPSIS
    Build HPWinPEMap.json from the HP Client Windows PE Driver Packs page.
.DESCRIPTION
    Parses the WinPEDriverPacks table on ftp.ext.hp.com and emits a map
    keyed by the source family string with spaces and slashes stripped:
    "WinPE 10/11" -> WinPE1011, "WinPE 10" -> WinPE10, "WinPE 5" ->
    WinPE5, "WinPE 4" -> WinPE4, "WinPE 3" -> WinPE3. The newest entry
    per family wins. When WinPE1011 is present, its entry is also
    aliased under the key "Current"; WinRE.ps1 reads Packs.WinPE1011
    directly, so the alias exists for operator convenience only.
#>

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# Output directory: prefer ./Maps next to this script, fall back to C:\Temp\Maps.
# Created here so the Set-Content at the end of the run cannot fail on a missing parent.
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
$OutputFile = Join-Path $MapsDir "HPWinPEMap.json"
$Headers = @{
    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
}

function Write-T {
    param([string]$M, [string]$L = "INFO")
    $c = switch ($L) { "ERROR"{"Red"} "WARN"{"Yellow"} "SUCCESS"{"Green"} "FOUND"{"Cyan"} default{"Gray"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" -ForegroundColor $c
}

$pageUrl = "https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HP_WinPE_DriverPack.html"
Write-T "Fetching HP WinPE page ..." -L INFO

$html = $null
for ($retry = 1; $retry -le 3; $retry++) {
    try {
        $r = Invoke-WebRequest -Uri $pageUrl -Headers $Headers -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $html = $r.Content
        break
    } catch {
        Write-T "Attempt $retry failed: $_" -L WARN
        if ($retry -lt 3) { Start-Sleep 5 }
    }
}
if (-not $html) { Write-T "Could not fetch HP page" -L ERROR; return }
Write-T "Page fetched: $($html.Length) chars" -L SUCCESS

# Isolate table
$tableMatch = [regex]::Match($html, '(?is)<table id="WinPEDriverPacks">(.*?)</table>')
if (-not $tableMatch.Success) { Write-T "WinPEDriverPacks table not found" -L ERROR; return }

$rows = [regex]::Matches($tableMatch.Groups[1].Value, '(?is)<tr[^>]*>\s*(.*?)\s*</tr>')

$entries = @()
foreach ($row in $rows) {
    $cells = [regex]::Matches($row.Groups[1].Value, '(?is)<td[^>]*>(.*?)</td>')
    if ($cells.Count -lt 5) { continue }

    $winpeVer = ($cells[0].Groups[1].Value -replace '<[^>]+>','').Trim()
    $version  = ($cells[1].Groups[1].Value -replace '<[^>]+>','').Trim()
    $softpaq  = ($cells[2].Groups[1].Value -replace '<[^>]+>','').Trim()
    $date     = ($cells[3].Groups[1].Value -replace '<[^>]+>','').Trim()
    $urlMatch = [regex]::Match($cells[4].Groups[1].Value, 'href="([^"]+)"')
    $url      = if ($urlMatch.Success) { $urlMatch.Groups[1].Value } else { "" }

    if (-not $url -or $url -notmatch '\.exe$') { continue }

    $entries += [PSCustomObject]@{
        WinPEVersion = $winpeVer
        Version      = $version
        SoftPaqId    = $softpaq
        Date         = $date
        Url          = $url
    }
}

Write-T "Parsed $($entries.Count) WinPE entries" -L SUCCESS

# Group by family, keep newest (page is newest-first so [0] per group wins)
$packs = @{}
foreach ($family in @('WinPE 10/11','WinPE 10','WinPE 5','WinPE 4','WinPE 3')) {
    $match = $entries | Where-Object { $_.WinPEVersion -eq $family } | Select-Object -First 1
    if (-not $match) { continue }
    $key = $family -replace '[\s/]+',''
    $packs[$key] = @{
        winpeVersion = $match.WinPEVersion
        version      = $match.Version
        softPaqId    = $match.SoftPaqId
        date         = $match.Date
        url          = $match.Url
    }
    Write-T "  $key -> $($match.SoftPaqId) v$($match.Version)" -L INFO
}

# Primary key used by WinRE.ps1
if ($packs.ContainsKey('WinPE1011')) {
    $packs['Current'] = $packs['WinPE1011']
    Write-T "Current pack: $($packs['Current'].softPaqId) v$($packs['Current'].version)" -L SUCCESS
}

$output = @{
    Generated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Count     = $packs.Count
    Packs     = $packs
}

$output | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
Write-T "Map saved: $OutputFile" -L SUCCESS
Write-T "Upload to your HP map gist and set `$HPWinPEMapUrl in WinRE.ps1" -L INFO
