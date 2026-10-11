<#
.SYNOPSIS
    Interactive backup cleanup for WinRE Manager.

.DESCRIPTION
    Lists every valid backup under a destination directory (a subdirectory
    containing both winre.wim and backup.json), shows per-backup size and
    the total, and lets the operator delete one, several, or all of them.

    The listing is read-only until the operator confirms deletion with the
    word DELETE. Deletion uses Remove-Item -LiteralPath -Recurse -Force and
    is verified: each deletion is followed by a Test-Path that must return
    false for the operation to be considered successful.

    Launched elevated by the wrapper's existing elevated-command mechanism.

    This script never modifies WinRE, partitions, BitLocker, drive letters,
    the state file, or anything outside the selected backup directories.

.PARAMETER BackupPath
    Root directory containing timestamped backup subdirectories.
    Default: C:\Backup\WindowsRE.

.PARAMETER NonInteractive
    When supplied, lists backups and exits without prompting.
#>
param(
    [string]$BackupPath = 'C:\Backup\WindowsRE',
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TiB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KiB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Write-Header {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Magenta
    Write-Host ("  $Title") -ForegroundColor Magenta
    Write-Host ('=' * 78) -ForegroundColor Magenta
    Write-Host ''
}

function Write-Wait {
    Write-Host ''
    Write-Host 'Press any key to close this window...'
    [void][System.Console]::ReadKey($true)
}

Write-Header 'WinRE Manager - Clean Up Backups'

Write-Host "Backup location: $BackupPath" -ForegroundColor Gray
Write-Host 'A valid backup contains both winre.wim and backup.json.' -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
    Write-Host "No backup directory found at $BackupPath" -ForegroundColor Yellow
    Write-Wait
    exit 0
}

try {
    $subdirs = @(Get-ChildItem -LiteralPath $BackupPath -Directory -ErrorAction Stop)
} catch {
    Write-Host "Could not enumerate $BackupPath : $_" -ForegroundColor Red
    Write-Wait
    exit 1
}

$backups = @()
foreach ($dir in $subdirs) {
    $wim  = Join-Path $dir.FullName 'winre.wim'
    $json = Join-Path $dir.FullName 'backup.json'
    if (-not (Test-Path -LiteralPath $wim  -PathType Leaf)) { continue }
    if (-not (Test-Path -LiteralPath $json -PathType Leaf)) { continue }

    $size = 0
    try { $size = (Get-Item -LiteralPath $wim -Force -ErrorAction Stop).Length } catch { }

    $sidecar = $null
    try {
        $sidecar = Get-Content -LiteralPath $json -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { }

    $backups += [PSCustomObject]@{
        Name         = $dir.Name
        Path         = $dir.FullName
        WimSizeBytes = $size
        WimSize      = Format-Size $size
        ManagerVer   = if ($sidecar -and $sidecar.ManagerVersion)  { $sidecar.ManagerVersion }  else { $null }
        BackupTime   = if ($sidecar -and $sidecar.BackupTime)      { $sidecar.BackupTime }      else { $null }
        SourceHash   = if ($sidecar -and $sidecar.SourceWimHash)   { $sidecar.SourceWimHash }   else { $null }
    }
}

if ($backups.Count -eq 0) {
    Write-Host 'No valid backups found.' -ForegroundColor Green
    Write-Host 'A valid backup contains both winre.wim and backup.json.' -ForegroundColor DarkGray
    Write-Wait
    exit 0
}

$backups    = $backups | Sort-Object Name -Descending
$totalBytes = ($backups | Measure-Object -Property WimSizeBytes -Sum).Sum

Write-Host 'Backups found:' -ForegroundColor White
Write-Host ''
$idx = 0
foreach ($b in $backups) {
    $idx++
    Write-Host ("  [{0,2}] " -f $idx) -NoNewline -ForegroundColor Cyan
    Write-Host $b.Name              -NoNewline -ForegroundColor White
    Write-Host ("   {0}" -f $b.WimSize) -NoNewline -ForegroundColor Gray
    if ($b.ManagerVer) {
        Write-Host ("   ({0})" -f $b.ManagerVer) -ForegroundColor DarkGray
    } else {
        Write-Host ''
    }
}
Write-Host ''
Write-Host ("Total: {0} across {1} backup(s)." -f (Format-Size $totalBytes), $backups.Count) -ForegroundColor Gray
Write-Host ''

if ($NonInteractive) {
    Write-Host 'Non-interactive mode: listing only.' -ForegroundColor DarkGray
    Write-Wait
    exit 0
}

Write-Host 'Enter backup number(s) to delete, space-separated.' -ForegroundColor White
Write-Host '  ALL  - delete every backup listed above'              -ForegroundColor Green
Write-Host '  Q    - cancel and return to the menu'                -ForegroundColor Green
Write-Host ''

$sel = Read-Host 'Selection'
if (-not $sel) {
    Write-Host ''
    Write-Host 'Cancelled. No backups were deleted.' -ForegroundColor Green
    Write-Wait
    exit 0
}
$sel = $sel.Trim()

if ($sel -ieq 'Q') {
    Write-Host ''
    Write-Host 'Cancelled. No backups were deleted.' -ForegroundColor Green
    Write-Wait
    exit 0
}

$toDelete = @()

if ($sel -ieq 'ALL') {
    $toDelete = $backups
} else {
    $numbers = @()
    foreach ($t in ($sel -split '\s+')) {
        $n = 0
        if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $backups.Count) {
            $numbers += $n
        }
    }
    $numbers = $numbers | Select-Object -Unique
    if ($numbers.Count -eq 0) {
        Write-Host ''
        Write-Host 'No matching backups selected.' -ForegroundColor Yellow
        Write-Wait
        exit 0
    }
    $toDelete = $numbers | ForEach-Object { $backups[$_ - 1] }
}

Write-Host ''
Write-Host 'The following backups will be deleted:' -ForegroundColor Yellow
foreach ($b in $toDelete) {
    Write-Host ("  {0}" -f $b.Path) -ForegroundColor White
}
Write-Host ''
Write-Host 'Type DELETE exactly to confirm. Anything else cancels.' -ForegroundColor White
Write-Host ''
$confirm = Read-Host 'Confirmation'

if ($confirm -cne 'DELETE') {
    Write-Host ''
    Write-Host 'Cancelled. No backups were deleted.' -ForegroundColor Green
    Write-Wait
    exit 0
}

Write-Host ''
$okCount   = 0
$failCount = 0
foreach ($b in $toDelete) {
    try {
        Remove-Item -LiteralPath $b.Path -Recurse -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $b.Path)) {
            Write-Host ("  Deleted: {0}" -f $b.Name) -ForegroundColor Green
            $okCount++
        } else {
            Write-Host ("  Could not confirm deletion: {0}" -f $b.Name) -ForegroundColor Red
            $failCount++
        }
    } catch {
        Write-Host ("  Could not delete {0}: {1}" -f $b.Name, $_.Exception.Message) -ForegroundColor Red
        $failCount++
    }
}

Write-Host ''
if ($failCount -eq 0) {
    Write-Host 'Cleanup complete.' -NoNewline -ForegroundColor Green
    Write-Host (" $okCount backup(s) removed.") -ForegroundColor Gray
} else {
    Write-Host 'Cleanup finished with errors.' -NoNewline -ForegroundColor Yellow
    Write-Host (" $okCount deleted, $failCount failed.") -ForegroundColor Gray
    Write-Host 'A backup may be in use by another process.' -ForegroundColor DarkGray
    Write-Host 'Close any tools that might have it open and try again.' -ForegroundColor DarkGray
}
Write-Wait
exit 0
