<#
.SYNOPSIS
    Build HPWinPEMap.json from the HP Client Windows PE Driver Packs page.
.DESCRIPTION
    Parses the WinPEDriverPacks table on ftp.ext.hp.com and emits a map
    keyed by WinPE family (WinPE10_11, WinPE5, WinPE4, WinPE3).
    The newest entry per family wins.
#>

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$OutputFile = "F:\Downloads\HPWinPEMap.json"
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
        $r = Invoke-WebRequest -Uri $pageUrl -Headers $Headers -UseBasicParsing -ErrorAction Stop
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

$rows = [regex]::Matches($tableMatch.Groups[1].Value, '(?is)<tr>\s*(.*?)\s*</tr>')

$entries = @()
foreach ($row in $rows) {
    $cells = [regex]::Matches($row.Groups[1].Value, '(?is)<td>(.*?)</td>')
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
