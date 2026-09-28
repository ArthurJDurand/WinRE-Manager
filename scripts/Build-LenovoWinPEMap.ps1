<#
.SYNOPSIS
    Build LenovoWinPEMap.json from RecipeCard.json.
.DESCRIPTION
    File is 0.6 MB - loads fully. Correctly identifies:
      - RecipeCards section (recipeId, modelId, osId, winpePacks)
      - Four model arrays: ThinkPad, ThinkCentre, ThinkStation, Lenovo
      - WinPEPacks section (id, url, version)
    Resolves each WinPE DS ID via support page scraping, outputs final map.
#>

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$WorkDir    = "C:\Temp\LenovoMapBuild"
$ArchiveDir = Join-Path $WorkDir "curl-archive"
$CiExe      = Join-Path $ArchiveDir "curl-impersonate.exe"
$OutputFile = "F:\Downloads\LenovoWinPEMap.json"
$ResolveDelay = 2

$RecipeCardUrl = "https://download.lenovo.com/cdrt/ddrc/recipecard.json"

function Write-T {
    param([string]$M, [string]$L = "INFO")
    $c = switch ($L) { "ERROR"{"Red"} "WARN"{"Yellow"} "SUCCESS"{"Green"} "FOUND"{"Cyan"} default{"Gray"} }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" -ForegroundColor $c
}

function Extract-JsonObject {
    param([string]$Text, [int]$StartBrace)
    $depth = 0; $inString = $false; $escape = $false
    $i = $StartBrace
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($escape) { $escape = $false }
        elseif ($c -eq '\') { $escape = $true }
        elseif ($c -eq '"') { $inString = -not $inString }
        elseif (-not $inString) {
            if ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') {
                $depth--
                if ($depth -eq 0) { return $Text.Substring($StartBrace, $i - $StartBrace + 1) }
            }
        }
        $i++
    }
    return $null
}

# ═══════════════════════════════════════════════════════════════════════
# ENSURE CURL-IMPERSONATE
# ═══════════════════════════════════════════════════════════════════════
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

if (-not (Test-Path $CiExe)) {
    Write-T "Downloading curl-impersonate ..." -L INFO
    if (Test-Path $ArchiveDir) { Remove-Item $ArchiveDir -Recurse -Force }
    New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
    $tarball = Join-Path $ArchiveDir "ci.tar.gz"
    try {
        Invoke-WebRequest -Uri "https://github.com/lexiforest/curl-impersonate/releases/download/v2.2.3/curl-impersonate-v2.2.3.i686-win32.tar.gz" -OutFile $tarball -UseBasicParsing -ErrorAction Stop
        $7z = "C:\Program Files\7-Zip\7z.exe"
        if (Test-Path $7z) {
            & $7z x $tarball -o"$ArchiveDir" -y 2>&1 | Out-Null
            $innerTar = Get-ChildItem $ArchiveDir -Filter "*.tar" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($innerTar) { & $7z x $innerTar.FullName -o"$ArchiveDir" -y 2>&1 | Out-Null }
        }
    } catch { Write-T "Download failed: $_" -L ERROR }
}
if (-not (Test-Path $CiExe)) { Write-T "curl-impersonate unavailable" -L ERROR; return }
Write-T "curl-impersonate: $CiExe" -L SUCCESS

# ═══════════════════════════════════════════════════════════════════════
# DOWNLOAD + PARSE RECIPE CARD
# ═══════════════════════════════════════════════════════════════════════
$recipeFile = Join-Path $WorkDir "recipecard.json"
if (-not (Test-Path $recipeFile) -or (Get-Item $recipeFile).Length -lt 100KB) {
    Write-T "Downloading RecipeCard.json ..." -L INFO
    & $CiExe --compressed --impersonate chrome146 -s -o $recipeFile $RecipeCardUrl 2>&1 | Out-Null
}
Write-T "Parsing RecipeCard ..." -L INFO
$rc = Get-Content $recipeFile -Raw | ConvertFrom-Json

# ═══════════════════════════════════════════════════════════════════════
# BUILD MODEL MAP (merge all four families)
# ═══════════════════════════════════════════════════════════════════════
$modelMap = @{}
foreach ($family in @('ThinkPad','ThinkCentre','ThinkStation','Lenovo')) {
    $arr = $rc.$family
    if (-not $arr) { continue }
    foreach ($m in $arr) {
        if (-not $m.id) { continue }
        $types = @()
        if ($m.types) { $types = @($m.types) }
        $modelMap["$($m.id)"] = @{
            name    = "$($m.name)"
            version = "$($m.version)"
            types   = $types
            series  = "$($m.series)"
        }
    }
}
Write-T "Models loaded: $($modelMap.Count) (ThinkPad+ThinkCentre+ThinkStation+Lenovo)" -L SUCCESS

# ═══════════════════════════════════════════════════════════════════════
# BUILD WINPE PACK MAP (id -> support URL)
# ═══════════════════════════════════════════════════════════════════════
$winpeMap = @{}
foreach ($wp in $rc.WinPEPacks) {
    if (-not $wp.id -or -not $wp.url) { continue }
    $url = "$($wp.url)"
    # Skip descriptive entries like "Import NIC and Storage drivers from the SCCM Driver Pack."
    if ($url -notmatch '/downloads/(ds\d+)') { continue }
    $winpeMap["$($wp.id)"] = @{
        url     = $url
        version = "$($wp.version)"
        dsId    = $Matches[1].ToUpper()
    }
}
Write-T "WinPE packs loaded: $($winpeMap.Count)" -L SUCCESS

# ═══════════════════════════════════════════════════════════════════════
# BUILD MACHINE TYPE MAP
# ═══════════════════════════════════════════════════════════════════════
# Structure: machineType -> list of { model, osId, winpePackId, dsId, url, version }
# A machine type can have multiple recipes (Win10 + Win11).
$machineTypeMap = @{}

foreach ($recipe in $rc.RecipeCards) {
    if (-not $recipe.modelId -or -not $recipe.winpePacks) { continue }
    $modelId = "$($recipe.modelId)"

    if (-not $modelMap.ContainsKey($modelId)) { continue }
    $model = $modelMap[$modelId]
    if (-not $model.types -or $model.types.Count -eq 0) { continue }

    foreach ($packId in $recipe.winpePacks) {
        $packKey = "$packId"
        if (-not $winpeMap.ContainsKey($packKey)) { continue }
        $wp = $winpeMap[$packKey]

        foreach ($mt in $model.types) {
            if (-not $machineTypeMap.ContainsKey($mt)) { $machineTypeMap[$mt] = @() }
            $machineTypeMap[$mt] += [PSCustomObject]@{
                model       = $model.name
                osId        = "$($recipe.osId)"
                winpePackId = $packKey
                dsId        = $wp.dsId
                supportUrl  = $wp.url
                version     = $wp.version
            }
        }
    }
}

Write-T "Machine types with WinPE packs: $($machineTypeMap.Count)" -L SUCCESS
Write-T ""
Write-T "Sample:" -L FOUND
$machineTypeMap.GetEnumerator() | Select-Object -First 8 | ForEach-Object {
    $mt = $_.Key
    $entries = $_.Value
    Write-T "  $mt -> $($entries[0].model) - OS IDs: $($entries.osId -join ', ') - DS IDs: $($entries.dsId -join ', ')" -L INFO
}

# ═══════════════════════════════════════════════════════════════════════
# COLLECT UNIQUE DS IDs TO RESOLVE
# ═══════════════════════════════════════════════════════════════════════
$uniqueDsIds = @{}
foreach ($mt in $machineTypeMap.Keys) {
    foreach ($entry in $machineTypeMap[$mt]) {
        if (-not $uniqueDsIds.ContainsKey($entry.dsId)) {
            $uniqueDsIds[$entry.dsId] = $entry.supportUrl
        }
    }
}
Write-T "Unique DS IDs to resolve: $($uniqueDsIds.Count)" -L SUCCESS

# ═══════════════════════════════════════════════════════════════════════
# RESOLVE DS IDs TO DIRECT URLS
# ═══════════════════════════════════════════════════════════════════════
$dsIdCache = @{}
$total = $uniqueDsIds.Count
$current = 0

foreach ($entry in $uniqueDsIds.GetEnumerator()) {
    $current++
    $dsId = $entry.Key
    Write-T "Resolving $dsId ($current of $total) ..." -L INFO

    $resolved = $null
    for ($retry = 1; $retry -le 3; $retry++) {
        $pageFile = Join-Path $WorkDir "page_$dsId.html"
        & $CiExe --compressed --impersonate chrome146 -s -o $pageFile "https://support.lenovo.com/us/en/downloads/$dsId" 2>&1 | Out-Null

        if (Test-Path $pageFile) {
            $html = Get-Content $pageFile -Raw -ErrorAction SilentlyContinue
            Remove-Item $pageFile -Force -ErrorAction SilentlyContinue

            if ($html -and $html.Length -gt 500) {
                $anchor = $html.IndexOf('var customData')
                if ($anchor -ge 0) {
                    $braceStart = $html.IndexOf('{', $anchor)
                    if ($braceStart -ge 0) {
                        $jsonText = Extract-JsonObject -Text $html -StartBrace $braceStart
                        if ($jsonText) {
                            try {
                                $data = $jsonText | ConvertFrom-Json
                                $exe = $data.driver.body.DriverDetails.Files |
                                       Where-Object { $_.TypeString -eq 'EXE' } |
                                       Select-Object -First 1
                                if ($exe) {
                                    $resolved = [PSCustomObject]@{
                                        DsId   = $dsId
                                        Name   = $exe.Name
                                        URL    = $exe.URL
                                        SHA256 = $exe.SHA256
                                        Size   = $exe.Size
                                    }
                                    break
                                }
                            } catch { }
                        }
                    }
                }
            }
        }

        if ($retry -lt 3) { Start-Sleep -Seconds 5 }
    }

    if ($resolved) {
        $dsIdCache[$dsId] = $resolved
        Write-T "  OK: $($resolved.Name)" -L SUCCESS
    } else {
        Write-T "  FAILED" -L WARN
    }

    Start-Sleep -Seconds $ResolveDelay
}

Write-T ""
Write-T "Resolved: $($dsIdCache.Count) of $total" -L SUCCESS

# ═══════════════════════════════════════════════════════════════════════
# BUILD FINAL MAP
# ═══════════════════════════════════════════════════════════════════════
# machineType -> { model, winpe: { dsId, name, url, sha256, size, osId } }
# If multiple recipes exist (Win10 + Win11), keep the newest OS version's entry.
$osRank = @{ "7" = 7; "6" = 6; "5" = 5; "3" = 3; "2" = 2 }

$finalMap = @{}
foreach ($mt in $machineTypeMap.Keys) {
    $candidates = @()
    foreach ($entry in $machineTypeMap[$mt]) {
        if (-not $dsIdCache.ContainsKey($entry.dsId)) { continue }
        $resolved = $dsIdCache[$entry.dsId]
        $candidates += [PSCustomObject]@{
            model       = $entry.model
            osId        = $entry.osId
            dsId        = $entry.dsId
            name        = $resolved.Name
            url         = $resolved.URL
            sha256      = $resolved.SHA256
            size        = $resolved.Size
            winpeVersion = $entry.version
        }
    }
    if ($candidates.Count -eq 0) { continue }

    # Pick highest OS version
    $best = $candidates | Sort-Object { [int]$_.osId } -Descending | Select-Object -First 1

    $finalMap[$mt] = @{
        model = $best.model
        winpe = @{
            dsId    = $best.dsId
            name    = $best.name
            url     = $best.url
            sha256  = $best.sha256
            size    = $best.size
            osId    = $best.osId
            version = $best.winpeVersion
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# WRITE OUTPUT
# ═══════════════════════════════════════════════════════════════════════
$output = @{
    Generated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Count     = $finalMap.Count
    Models    = $finalMap
}

$output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding UTF8

Write-T ""
Write-T "================================================================" -L SUCCESS
Write-T " MAP BUILT: $($finalMap.Count) machine types" -L SUCCESS
Write-T " Output: $OutputFile" -L SUCCESS
Write-T "================================================================" -L SUCCESS
Write-T "Upload this file to gist 8211b75a38444caa68b8cebd7529376c" -L INFO
