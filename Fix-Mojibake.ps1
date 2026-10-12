<#
.SYNOPSIS
    Mojibake detector and repair tool for the WinRE-Manager repository,
    restricted to documentation and configuration files.

.DESCRIPTION
    Scans every documentation and configuration file in the repository for:
      - Invalid UTF-8 byte sequences
      - A UTF-8 BOM (which should not be present on any document file)
      - CP1252-read-as-UTF-8 mojibake in punctuation, arrows, and emoji
      - Known lost-arrow patterns (a '?' character where a right-arrow used to be)

    Diagnose-only by default. With -Fix: prompts for confirmation (unless
    -Force), backs up every file it will touch into a timestamped folder,
    applies corrections via System.IO.File.WriteAllText with
    UTF8Encoding($false), and verifies the result.

    SCOPE -- the script deliberately excludes PowerShell scripts and CMD
    batch files (*.ps1, *.psm1, *.psd1, *.cmd, *.bat). Those files are
    UTF-8 WITH BOM per the project's encoding table, have their own review
    process, and are frozen at v50 patch 1. They must never be rewritten
    by this tool.

    ENCODING -- every file this script touches is documentation or config,
    all of which is UTF-8 WITHOUT BOM. The write path is therefore
    unconditional: System.IO.File.WriteAllText with UTF8Encoding($false).

    Every write goes through System.IO.File.WriteAllText. The script never
    calls Set-Content or Out-File without -Encoding. This guarantees the
    CP1252 default-codepage trap cannot recur.

.PARAMETER RepoPath
    Path to the WinRE-Manager repository root. If omitted, the script uses
    its own directory when that directory contains a .git folder; otherwise
    it falls back to the default path configured below.

.PARAMETER Fix
    Apply the fixes. Without this switch, the script only reports.

.PARAMETER Force
    With -Fix, skip the interactive confirmation prompt.

.PARAMETER Verify
    Diagnose only, but exit with a non-zero code if any issue is found.
    Suitable for CI.

.PARAMETER FileFilter
    Array of file patterns to scan. Defaults to the document-only set
    configured below. Overriding this parameter is NOT recommended; the
    default excludes PowerShell and CMD files by design.

.PARAMETER NoBackup
    With -Fix, skip the automatic backup. Not recommended.

.PARAMETER BackupDir
    Directory into which the timestamped backup folder is created.
    Defaults to the parent of the repo root.

.EXAMPLE
    .\Fix-Mojibake.ps1
    Diagnose only.

.EXAMPLE
    .\Fix-Mojibake.ps1 -Fix
    Diagnose, prompt, back up, fix, verify.

.EXAMPLE
    .\Fix-Mojibake.ps1 -Fix -Force -RepoPath 'C:\My\WinRE-Manager'
    Unattended fix.

.NOTES
    Version 1.2
    v1.2 restricts the tool to documentation and configuration files only.
    PowerShell scripts and CMD batch files are excluded by design; they
    carry a UTF-8 BOM and are frozen, so this tool must never touch them.

    This script is pure ASCII. All non-ASCII characters used in the
    mojibake tables are composed at runtime via [char] codes, so the script
    itself cannot be corrupted by any editor's encoding choice.
#>

[CmdletBinding()]
param(
    [string]$RepoPath,
    [switch]$Fix,
    [switch]$Force,
    [switch]$Verify,
    [string[]]$FileFilter,
    [switch]$NoBackup,
    [string]$BackupDir
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.2'

# =============================================================================
# CONFIG -- edit the default repo path if the repo moves.
# =============================================================================

$DefaultRepoPath = 'D:\GitHub\WinRE-Manager'

# Documentation and configuration files only.
# Deliberately excludes *.ps1, *.psm1, *.psd1, *.cmd, *.bat.
$DefaultFileFilter = @(
    '*.md', '*.txt', '*.json', '*.yml', '*.yaml', '*.xml', '*.config'
)

# Extension-less document files matched by exact filename.
$DefaultFileNameMatches = @(
    'LICENSE', 'LICENSE.txt', 'NOTICE', 'NOTICE.txt', 'AUTHORS', 'COPYING'
)

# Safety guard: if a caller overrides -FileFilter and includes any of these
# extensions, the script refuses to run. The frozen PowerShell and CMD
# files must never be rewritten by this tool.
$ForbiddenExtensions = @('.ps1', '.psm1', '.psd1', '.cmd', '.bat')

# =============================================================================
# Resolve repo path
# =============================================================================

$repo = $null
$repoSource = ''
if ($RepoPath) {
    $repo = $RepoPath
    $repoSource = 'from -RepoPath'
} elseif ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git'))) {
    $repo = $PSScriptRoot
    $repoSource = 'auto-detected (script sits inside the repo)'
} elseif (Test-Path -LiteralPath $DefaultRepoPath) {
    $repo = $DefaultRepoPath
    $repoSource = 'from default configuration'
} else {
    Write-Host 'ERROR: Could not resolve repo path.' -ForegroundColor Red
    Write-Host '  -RepoPath was not supplied'
    Write-Host '  Script is not inside a .git folder'
    Write-Host ('  Default path does not exist: ' + $DefaultRepoPath)
    exit 3
}

$repo = (Resolve-Path -LiteralPath $repo).Path

if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    Write-Host ('WARNING: ' + $repo + ' does not contain a .git directory.') -ForegroundColor Yellow
    Write-Host '         Continuing anyway. Press Ctrl+C within 3 seconds to abort.' -ForegroundColor Yellow
    Start-Sleep -Seconds 3
}

if (-not $FileFilter -or $FileFilter.Count -eq 0) { $FileFilter = $DefaultFileFilter }

# Guard: refuse to run if the filter would include PowerShell or CMD files.
foreach ($pat in $FileFilter) {
    $ext = [System.IO.Path]::GetExtension($pat).ToLowerInvariant()
    if ($ForbiddenExtensions -contains $ext) {
        Write-Host ('ERROR: -FileFilter includes ' + $pat + ', which is a PowerShell or CMD extension.') -ForegroundColor Red
        Write-Host '       This tool is restricted to documentation and configuration files.' -ForegroundColor Red
        Write-Host '       Those scripts carry a UTF-8 BOM and must never be rewritten by this tool.' -ForegroundColor Red
        exit 3
    }
}

# =============================================================================
# Encoding helpers
# =============================================================================

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

# =============================================================================
# CP1252 decoder -- maps each byte 0x00-0xFF to its Unicode codepoint as
# Windows CP1252 would decode it. Undefined bytes (0x81, 0x8D, 0x8F, 0x90,
# 0x9D) map to the corresponding C1 control codepoint, matching the
# historical Windows behaviour that produced the mojibake we are repairing.
# =============================================================================

$cp1252Map = @{}
for ($b = 0x00; $b -le 0x7F; $b++) { $cp1252Map[$b] = $b }
$cp1252Map[0x80] = 0x20AC
$cp1252Map[0x81] = 0x0081
$cp1252Map[0x82] = 0x201A
$cp1252Map[0x83] = 0x0192
$cp1252Map[0x84] = 0x201E
$cp1252Map[0x85] = 0x2026
$cp1252Map[0x86] = 0x2020
$cp1252Map[0x87] = 0x2021
$cp1252Map[0x88] = 0x02C6
$cp1252Map[0x89] = 0x2030
$cp1252Map[0x8A] = 0x0160
$cp1252Map[0x8B] = 0x2039
$cp1252Map[0x8C] = 0x0152
$cp1252Map[0x8D] = 0x008D
$cp1252Map[0x8E] = 0x017D
$cp1252Map[0x8F] = 0x008F
$cp1252Map[0x90] = 0x0090
$cp1252Map[0x91] = 0x2018
$cp1252Map[0x92] = 0x2019
$cp1252Map[0x93] = 0x201C
$cp1252Map[0x94] = 0x201D
$cp1252Map[0x95] = 0x2022
$cp1252Map[0x96] = 0x2013
$cp1252Map[0x97] = 0x2014
$cp1252Map[0x98] = 0x02DC
$cp1252Map[0x99] = 0x2122
$cp1252Map[0x9A] = 0x0161
$cp1252Map[0x9B] = 0x203A
$cp1252Map[0x9C] = 0x0153
$cp1252Map[0x9D] = 0x009D
$cp1252Map[0x9E] = 0x017E
$cp1252Map[0x9F] = 0x0178
for ($b = 0xA0; $b -le 0xFF; $b++) { $cp1252Map[$b] = $b }

function Get-Cp1252DecodedString {
    param([byte[]]$Bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $Bytes) {
        [void]$sb.Append([char]$cp1252Map[[int]$b])
    }
    return $sb.ToString()
}

function Get-MojibakeFor {
    param([int]$CodePoint)
    $real = [char]::ConvertFromUtf32($CodePoint)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($real)
    return (Get-Cp1252DecodedString -Bytes $bytes)
}

# General reverse-CP1252 mojibake repair. For each character whose CP1252
# codepoint could be a UTF-8 lead byte (0xC2-0xF4), gather the 1-3
# following characters, map them back to bytes via the reverse CP1252
# map, and try to decode the reconstructed bytes as strict UTF-8. If the
# decode succeeds and produces a single character, replace the sequence.
# Catches every class the hardcoded $targets list does not enumerate.
function Repair-RemainingMojibake {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }

    # Build reverse CP1252 map: codepoint -> byte. The forward map
    # ($cp1252Map) is injective, so the reverse is well-defined.
    $reverse = @{}
    foreach ($key in $cp1252Map.Keys) {
        $cp = [int]$cp1252Map[$key]
        if (-not $reverse.ContainsKey($cp)) { $reverse[$cp] = [int]$key }
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $sb  = New-Object System.Text.StringBuilder
    $len = $Text.Length
    $i   = 0
    while ($i -lt $len) {
        $cp0 = [int]$Text[$i]
        $matched = $false
        if ($reverse.ContainsKey($cp0)) {
            $b0 = $reverse[$cp0]
            $expected = 0
            if     ($b0 -ge 0xC2 -and $b0 -le 0xDF) { $expected = 2 }
            elseif ($b0 -ge 0xE0 -and $b0 -le 0xEF) { $expected = 3 }
            elseif ($b0 -ge 0xF0 -and $b0 -le 0xF4) { $expected = 4 }
            if ($expected -gt 0 -and ($i + $expected) -le $len) {
                $bytes = New-Object 'byte[]' $expected
                $bytes[0] = [byte]$b0
                $ok = $true
                for ($j = 1; $j -lt $expected; $j++) {
                    $cpj = [int]$Text[$i + $j]
                    if (-not $reverse.ContainsKey($cpj)) { $ok = $false; break }
                    $bj = $reverse[$cpj]
                    if ($bj -lt 0x80 -or $bj -gt 0xBF) { $ok = $false; break }
                    $bytes[$j] = [byte]$bj
                }
                if ($ok) {
                    try {
                        $decoded = $strictUtf8.GetString($bytes)
                        if ($decoded.Length -ge 1) {
                            [void]$sb.Append($decoded)
                            $i += $expected
                            $matched = $true
                        }
                    } catch { }
                }
            }
        }
        if (-not $matched) {
            [void]$sb.Append($Text[$i])
            $i++
        }
    }
    return $sb.ToString()
}

# =============================================================================
# Build the mojibake replacement table. This is the well-tested first
# pass. Anything not in this list is caught by Repair-RemainingMojibake,
# which runs after this table on every scan.
# =============================================================================

$targets = @(
    # ---- Punctuation ----
    @{ Code = 0x2014; Label = 'em-dash' }
    @{ Code = 0x2013; Label = 'en-dash' }
    @{ Code = 0x2019; Label = 'right-single-quote' }
    @{ Code = 0x2018; Label = 'left-single-quote' }
    @{ Code = 0x201D; Label = 'right-double-quote' }
    @{ Code = 0x201C; Label = 'left-double-quote' }
    @{ Code = 0x2026; Label = 'ellipsis' }
    @{ Code = 0x2022; Label = 'bullet' }
    @{ Code = 0x2192; Label = 'right-arrow' }
    @{ Code = 0x2190; Label = 'left-arrow' }
    @{ Code = 0x00A7; Label = 'section' }
    @{ Code = 0x00B7; Label = 'mid-dot' }
    @{ Code = 0x00AE; Label = 'registered' }
    @{ Code = 0x00A9; Label = 'copyright' }
    @{ Code = 0x00B0; Label = 'degree' }
    @{ Code = 0x2020; Label = 'dagger' }
    @{ Code = 0x2021; Label = 'double-dagger' }
    @{ Code = 0x2122; Label = 'trademark' }
    @{ Code = 0x2030; Label = 'permille' }
    @{ Code = 0x0152; Label = 'OE-ligature' }
    @{ Code = 0x0153; Label = 'oe-ligature' }
    @{ Code = 0x0160; Label = 'S-caron' }
    @{ Code = 0x0161; Label = 's-caron' }
    @{ Code = 0x017D; Label = 'Z-caron' }
    @{ Code = 0x017E; Label = 'z-caron' }
    @{ Code = 0x0178; Label = 'Y-diaeresis' }
    @{ Code = 0x201A; Label = 'single-low-quote' }
    @{ Code = 0x201E; Label = 'double-low-quote' }
    @{ Code = 0x2039; Label = 'left-angle-quote' }
    @{ Code = 0x203A; Label = 'right-angle-quote' }
    @{ Code = 0x02C6; Label = 'circumflex' }
    @{ Code = 0x02DC; Label = 'small-tilde' }
    @{ Code = 0x0192; Label = 'florin' }
    # ---- Emoji ----
    @{ Code = 0x1F4D6; Label = 'book-emoji' }
    @{ Code = 0x1F4BB; Label = 'laptop-emoji' }
    @{ Code = 0x1F3E2; Label = 'building-emoji' }
    @{ Code = 0x1F527; Label = 'wrench-emoji' }
    @{ Code = 0x1F496; Label = 'heart-emoji' }
    @{ Code = 0x1F389; Label = 'party-emoji' }
    @{ Code = 0x1F680; Label = 'rocket-emoji' }
    @{ Code = 0x1F916; Label = 'robot-emoji' }
    @{ Code = 0x1F4DD; Label = 'memo-emoji' }
    @{ Code = 0x1F512; Label = 'lock-emoji' }
    @{ Code = 0x1F511; Label = 'key-emoji' }
    @{ Code = 0x1F4A1; Label = 'bulb-emoji' }
    @{ Code = 0x1F3AF; Label = 'target-emoji' }
    @{ Code = 0x2705;  Label = 'checkmark-emoji' }
    @{ Code = 0x274C;  Label = 'cross-emoji' }
    @{ Code = 0x2B50;  Label = 'star-emoji' }
    @{ Code = 0x2728;  Label = 'sparkles-emoji' }
    @{ Code = 0x26A1;  Label = 'zap-emoji' }
)

$warnFull = [char]::ConvertFromUtf32(0x26A0) + [char]::ConvertFromUtf32(0xFE0F)
$warnBytes = [System.Text.Encoding]::UTF8.GetBytes($warnFull)
$warnMoji = Get-Cp1252DecodedString -Bytes $warnBytes

$mojiTable = New-Object System.Collections.ArrayList
[void]$mojiTable.Add(@{ Find = $warnMoji; Replace = $warnFull; Label = 'warn-emoji' })

foreach ($t in $targets) {
    $moji = Get-MojibakeFor -CodePoint $t.Code
    $real = [char]::ConvertFromUtf32($t.Code)
    if ($moji -ne $real) {
        [void]$mojiTable.Add(@{ Find = $moji; Replace = $real; Label = $t.Label })
    }
}

# =============================================================================
# Lost-arrow patterns -- literal '?' characters that replaced right-arrows
# when a file was written through CP1252 (which has no mapping for U+2192).
# =============================================================================

$arrowChar = [char]0x2192

$lostArrowPatterns = @(
    @{ Regex = 'v(\d+)\?v(\d+)';              Repl = ('v$1' + $arrowChar + 'v$2');         Label = 'vN?vN' }
    @{ Regex = 'v(\d+)\?(\d+)\b';             Repl = ('v$1' + $arrowChar + '$2');          Label = 'vN?N' }
    @{ Regex = 'disable\?enable';             Repl = ('disable' + $arrowChar + 'enable');  Label = 'disable?enable' }
    @{ Regex = '(Step \d+)\?(Step \d+)';      Repl = ('$1' + $arrowChar + '$2');           Label = 'Step N?Step N' }
)

# =============================================================================
# File enumeration
# =============================================================================

$allFiles = New-Object System.Collections.ArrayList
foreach ($pattern in $FileFilter) {
    $matched = Get-ChildItem -LiteralPath $repo -Filter $pattern -File -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\node_modules\\' }
    foreach ($f in $matched) {
        if (-not ($allFiles.FullName -contains $f.FullName)) {
            [void]$allFiles.Add($f)
        }
    }
}
foreach ($name in $DefaultFileNameMatches) {
    $candidate = Join-Path $repo $name
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $item = Get-Item -LiteralPath $candidate
        if (-not ($allFiles.FullName -contains $item.FullName)) {
            [void]$allFiles.Add($item)
        }
    }
}
$allFiles = @($allFiles | Sort-Object FullName)

if ($allFiles.Count -eq 0) {
    Write-Host 'No matching files found. Nothing to do.' -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# Scan each file
# =============================================================================

$scanResults = New-Object System.Collections.ArrayList

foreach ($f in $allFiles) {
    $rel = $f.FullName.Substring($repo.Length).TrimStart('\','/')
    $rawBytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)

    $validUtf8 = $true
    $text = $null
    try {
        $text = $Utf8Strict.GetString($rawBytes)
        if ($hasBom -and $text.Length -ge 1 -and [int]$text[0] -eq 0xFEFF) {
            $text = $text.Substring(1)
        }
    } catch {
        $validUtf8 = $false
        $text = Get-Cp1252DecodedString -Bytes $rawBytes
    }

    $mojiHits = New-Object System.Collections.ArrayList
    foreach ($m in $mojiTable) {
        $count = ([regex]::Matches($text, [regex]::Escape($m.Find))).Count
        if ($count -gt 0) {
            [void]$mojiHits.Add(@{ Label = $m.Label; Count = $count })
        }
    }

    $arrowHits = New-Object System.Collections.ArrayList
    foreach ($p in $lostArrowPatterns) {
        $count = ([regex]::Matches($text, $p.Regex)).Count
        if ($count -gt 0) {
            [void]$arrowHits.Add(@{ Label = $p.Label; Count = $count })
        }
    }

    $newText = $text
    foreach ($m in $mojiTable) {
        if ($newText.Contains($m.Find)) { $newText = $newText.Replace($m.Find, $m.Replace) }
    }
    foreach ($p in $lostArrowPatterns) {
        $newText = [regex]::Replace($newText, $p.Regex, $p.Repl)
    }
    # General decoder: catches every 2-, 3-, and 4-byte UTF-8 character
    # whose UTF-8 form was read as CP1252 and is not in $targets. Runs
    # after the hardcoded table so the well-tested replacements keep
    # their priority and only the residue is handled here.
    #
    # Iterated to a fixed point. The transformation is not idempotent in
    # isolation: some inputs produce output that itself contains a new
    # valid UTF-8 byte pattern the algorithm then transforms again on the
    # next pass. A single non-iterated call therefore leaves the file in
    # a state that the next scan flags as needing further repair, and the
    # file is stuck reporting [BAD] indefinitely. Iterating here means
    # the file is fully converged by the time it is written, and every
    # subsequent scan finds nothing left to change.
    $repairPasses = 0
    while ($repairPasses -lt 8) {
        $next = Repair-RemainingMojibake -Text $newText
        if ($next -eq $newText) { break }
        $newText = $next
        $repairPasses++
    }

    $changed = ($newText -ne $text) -or (-not $validUtf8) -or $hasBom

    [void]$scanResults.Add([PSCustomObject]@{
        Path      = $f.FullName
        Rel       = $rel
        Size      = $rawBytes.Length
        HasBom    = $hasBom
        ValidUtf8 = $validUtf8
        MojiHits  = $mojiHits
        ArrowHits = $arrowHits
        Original  = $text
        NewText   = $newText
        Changed   = $changed
    })
}

# =============================================================================
# Report
# =============================================================================

$cleanCount = 0
$badCount = 0
$totalMoji = 0
$totalArrows = 0
$invalidCount = 0
$bomCount = 0
$filesToFix = New-Object System.Collections.ArrayList

Write-Host ''
Write-Host ('WinRE-Manager document mojibake detector  v' + $ScriptVersion)
Write-Host '==============================================================================='
Write-Host ''
Write-Host 'Configuration'
Write-Host ('  Repo path:      ' + $repo)
Write-Host ('  Repo path from: ' + $repoSource)
Write-Host ('  Mode:           ' + $(if ($Fix) { 'FIX' } else { 'DIAGNOSE ONLY (use -Fix to apply)' }))
Write-Host ('  Scope:          documents and configuration only')
Write-Host ('                  (excludes .ps1 .psm1 .psd1 .cmd .bat by design)')
Write-Host ('  File filter:    ' + ($FileFilter -join ', '))
Write-Host ('  Files found:    ' + $allFiles.Count)
Write-Host ''
Write-Host 'Scan'
Write-Host '-------------------------------------------------------------------------------'

foreach ($r in $scanResults) {
    if (-not $r.Changed) {
        $cleanCount++
        Write-Host ('  [CLEAN] ' + $r.Rel)
        continue
    }

    $badCount++
    [void]$filesToFix.Add($r)

    Write-Host ('  [BAD]   ' + $r.Rel) -ForegroundColor Yellow

    if (-not $r.ValidUtf8) {
        $invalidCount++
        Write-Host '            INVALID UTF-8 (will be re-encoded as UTF-8 without BOM)' -ForegroundColor Red
    }
    if ($r.HasBom) {
        $bomCount++
        Write-Host '            UTF-8 BOM present (documents are UTF-8 without BOM; will be removed)' -ForegroundColor Yellow
    }

    foreach ($m in $r.MojiHits) {
        Write-Host ('            ' + $m.Label.PadRight(30) + ' x' + $m.Count)
        $totalMoji += $m.Count
    }
    foreach ($a in $r.ArrowHits) {
        Write-Host ('            lost-arrow ' + $a.Label.PadRight(17) + ' x' + $a.Count)
        $totalArrows += $a.Count
    }
}

Write-Host ''
Write-Host '==============================================================================='
Write-Host 'Summary'
Write-Host '==============================================================================='
Write-Host ('  Files scanned:                  ' + $scanResults.Count)
Write-Host ('  Files clean:                    ' + $cleanCount) -ForegroundColor Green
Write-Host ('  Files needing repair:           ' + $badCount) -ForegroundColor $(if ($badCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ('  Files with invalid UTF-8:       ' + $invalidCount) -ForegroundColor $(if ($invalidCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ('  Files with a stray UTF-8 BOM:   ' + $bomCount) -ForegroundColor $(if ($bomCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ('  Total mojibake instances:       ' + $totalMoji)
Write-Host ('  Total lost-arrow instances:     ' + $totalArrows)
Write-Host ''

if ($badCount -eq 0) {
    Write-Host 'All files clean. Nothing to do.' -ForegroundColor Green
    exit 0
}

if (-not $Fix) {
    Write-Host 'No changes written. Re-run with -Fix to apply.' -ForegroundColor Yellow
    if ($Verify) { exit 1 } else { exit 0 }
}

# =============================================================================
# Fix mode
# =============================================================================

if (-not $Force) {
    Write-Host ('About to modify ' + $badCount + ' file(s).') -ForegroundColor Yellow
    if (-not $NoBackup) {
        $tsPreview = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dirPreview = if ($BackupDir) { $BackupDir } else { Split-Path $repo -Parent }
        Write-Host ('A timestamped backup will be created at: ' + (Join-Path $dirPreview ('mojibake-backup-' + $tsPreview))) -ForegroundColor Yellow
    }
    $answer = Read-Host 'Continue? (yes/no)'
    if ($answer -notin @('yes','y','Y','YES','Yes')) {
        Write-Host 'Aborted by user. No changes written.' -ForegroundColor Yellow
        exit 0
    }
}

# ---- Backup ----
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupParent = if ($BackupDir) { $BackupDir } else { Split-Path $repo -Parent }
if (-not (Test-Path -LiteralPath $backupParent)) {
    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
}
$backupRoot = Join-Path $backupParent ('mojibake-backup-' + $ts)

if (-not $NoBackup) {
    Write-Host ''
    Write-Host ('Backing up to: ' + $backupRoot) -ForegroundColor Cyan
    foreach ($r in $filesToFix) {
        $rel = $r.Rel -replace '/', '\'
        $dest = Join-Path $backupRoot $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $r.Path -Destination $dest -Force
    }
    Write-Host ('Backed up ' + $filesToFix.Count + ' file(s).') -ForegroundColor Green
} else {
    Write-Host 'Backup skipped (-NoBackup).' -ForegroundColor Yellow
}

# ---- Apply ----
Write-Host ''
Write-Host 'Applying fixes (all documents written as UTF-8 without BOM)...'
$applied = 0
$failed = 0
foreach ($r in $filesToFix) {
    try {
        [System.IO.File]::WriteAllText($r.Path, $r.NewText, $Utf8NoBom)
        Write-Host ('  [FIXED] ' + $r.Rel) -ForegroundColor Green
        $applied++
    } catch {
        Write-Host ('  [FAIL]  ' + $r.Rel + ' -- ' + $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}
Write-Host ''
Write-Host ('Applied: ' + $applied + '   Failed: ' + $failed)

# ---- Verify ----
Write-Host ''
Write-Host 'Verifying...'
$stillBad = 0
foreach ($r in $filesToFix) {
    $rawBytes = [System.IO.File]::ReadAllBytes($r.Path)
    $valid = $true
    try { $null = $Utf8Strict.GetString($rawBytes) } catch { $valid = $false }
    if (-not $valid) {
        Write-Host ('  [STILL BAD] ' + $r.Rel + ' -- not valid UTF-8 after fix') -ForegroundColor Red
        $stillBad++
        continue
    }
    $hasBom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
    if ($hasBom) {
        Write-Host ('  [STILL BAD] ' + $r.Rel + ' -- UTF-8 BOM is still present') -ForegroundColor Red
        $stillBad++
        continue
    }
    $txt = [System.IO.File]::ReadAllText($r.Path)
    if ($txt.Length -ge 1 -and [int]$txt[0] -eq 0xFEFF) { $txt = $txt.Substring(1) }
    $remaining = 0
    foreach ($m in $mojiTable) {
        $remaining += ([regex]::Matches($txt, [regex]::Escape($m.Find))).Count
    }
    if ($remaining -gt 0) {
        Write-Host ('  [STILL BAD] ' + $r.Rel + ' -- ' + $remaining + ' mojibake remaining') -ForegroundColor Red
        $stillBad++
    }
}

Write-Host ''
if ($stillBad -eq 0) {
    Write-Host 'Verification passed. All repaired files are clean UTF-8 without BOM.' -ForegroundColor Green
    if (-not $NoBackup) {
        Write-Host ('Backup retained at: ' + $backupRoot) -ForegroundColor DarkGray
    }
    exit 2
} else {
    Write-Host ($stillBad + ' file(s) still have issues. Inspect and re-run.') -ForegroundColor Red
    exit 3
}
