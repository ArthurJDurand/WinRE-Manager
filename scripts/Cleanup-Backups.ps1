<#
.SYNOPSIS
    Interactive backup cleanup for WinRE Manager.

.DESCRIPTION
    Lists every valid backup under every registered backup root, shows
    per-backup size and the total, and lets the operator delete one,
    several, or all of them.

    Root discovery: the manager config file at
        C:\ProgramData\OEM\WinRE-Manager\manager.json
    carries the catalogue of backup roots used on this machine. Cleanup
    reads that catalogue and enumerates every root, and always includes the
    default C:\Backup\WindowsRE. If -BackupPath is supplied explicitly,
    only that single root is used.

    The manager config is trusted only when the directory containing it,
    its immediate parent, and the config file itself all pass
    Test-PathTrustedForSystem: the ACL owner is SYSTEM or Administrators,
    and no Allow ACE grants a modify-capable right (Delete,
    DeleteSubdirectoriesAndFiles, TakeOwnership, ChangePermissions on a
    directory; those plus WriteData and AppendData on a file) to a
    principal outside SYSTEM, Administrators, or TrustedInstaller. An
    untrusted, unreadable, or unparseable config is treated as absent; the
    default root is then used alone. This mirrors the v50 patch 3 trust
    model in WinRE.ps1's Get-ManagerConfig and Set-ManagerConfig.

    The listing is read-only until the operator confirms deletion with the
    word DELETE. Deletion uses Remove-Item -LiteralPath -Recurse -Force and
    is verified: each deletion is followed by a Test-Path that must return
    false for the operation to be considered successful.

    Empty-directory cleanup after deletion:
      - Timestamped subdirectories (leaf matches yyyy-MM-dd_HHmmss) that are
        empty are removed.
      - The default root C:\Backup\WindowsRE is removed if it is empty.
      - C:\Backup is then removed if it too is empty.
      - A drive root is never removed.
      - A reparse point is never recursed through: Remove-Item -Recurse
        on a directory junction or symlink can traverse into the target
        on some PowerShell builds, so the link itself is skipped and its
        target is left untouched.
      - A non-empty directory is never removed.

    Launched elevated by the wrapper's existing elevated-command mechanism.

    This script never modifies WinRE, partitions, BitLocker, drive letters,
    the state file, or anything outside the selected backup directories.

.PARAMETER BackupPath
    Restrict cleanup to this single root directory. When omitted, every root
    in the manager config catalogue is used, plus the default
    C:\Backup\WindowsRE.

.PARAMETER NonInteractive
    When supplied, lists backups and exits without prompting or waiting.
#>
param(
    [string]$BackupPath,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DefaultBackupPath = 'C:\Backup\WindowsRE'
$ManagerConfigPath = 'C:\ProgramData\OEM\WinRE-Manager\manager.json'

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

# v50 patch 3: shared trust-validation helper. Mirrors production's
# Test-PathTrustedForSystem. Validates both the owner (SYSTEM or
# Administrators) and the effective DACL (no Allow ACE grants a
# modify-capable right to a principal outside SYSTEM, Administrators,
# or TrustedInstaller). The modify-capable mask differs by Kind: on a
# directory, WriteData and AppendData are excluded because on a
# directory they mean only create-new-file / create-new-subdirectory;
# on a file, both are included because they permit modifying the
# file's content. The owner check alone does not establish that the
# DACL prevents untrusted modification; the mask check closes that
# gap.
#
# Duplicated here rather than dot-sourcing WinRE.ps1, because this
# script runs standalone and dot-sourcing would execute the
# production pipeline. Kept in lockstep with production's copy.
function Test-PathTrustedForSystem {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('File','Directory')][string]$Kind
    )
    if (-not $Path) { return $false }
    $exists = if ($Kind -eq 'File') {
        Test-Path -LiteralPath $Path -PathType Leaf
    } else {
        Test-Path -LiteralPath $Path -PathType Container
    }
    if (-not $exists) { return $false }
    $acl = $null
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { return $false }
    if (-not $acl -or -not $acl.Owner) { return $false }
    $ownerSid = $null
    try {
        $ownerRef = $acl.Owner
        if ($ownerRef -is [System.Security.Principal.SecurityIdentifier]) {
            $ownerSid = $ownerRef.Value
        } elseif ($ownerRef -is [System.Security.Principal.IdentityReference]) {
            $ownerSid = $ownerRef.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } else {
            $ownerStr = [string]$ownerRef
            if ($ownerStr -match '^S-1-') {
                $ownerSid = $ownerStr
            } else {
                $ownerSid = (New-Object System.Security.Principal.NTAccount($ownerStr)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
        }
    } catch { return $false }
    $trustedOwnerSids = @('S-1-5-18','S-1-5-32-544')
    if ($trustedOwnerSids -notcontains $ownerSid) { return $false }
    $trustedAceSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    if ($Kind -eq 'File') {
        $writeCapableMask = ([int][System.Security.AccessControl.FileSystemRights]::WriteData) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::AppendData) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::Delete) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::TakeOwnership) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::ChangePermissions)
    } else {
        $writeCapableMask = ([int][System.Security.AccessControl.FileSystemRights]::Delete) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::TakeOwnership) -bor
                            ([int][System.Security.AccessControl.FileSystemRights]::ChangePermissions)
    }
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        $aceSid = $null
        try {
            $aceSid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            Write-Host "Test-PathTrustedForSystem: could not resolve the SID for an ACE on '$Path' (IdentityReference='$($ace.IdentityReference)') - fail closed" -ForegroundColor Yellow
            return $false
        }
        if ($trustedAceSids -contains $aceSid) { continue }
        if (((([int]$ace.FileSystemRights) -band $writeCapableMask)) -ne 0) {
            return $false
        }
    }
    return $true
}

# Resolve the set of roots to enumerate. If -BackupPath is supplied
# explicitly, use only that. Otherwise read the manager config (owner-
# checked) and always include the default root.
function Get-BackupRoots {
    param([string]$ExplicitPath)

    if ($ExplicitPath) { return @($ExplicitPath) }

    $roots = [System.Collections.Generic.List[string]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (Test-Path -LiteralPath $ManagerConfigPath -PathType Leaf) {
        $configDir = Split-Path $ManagerConfigPath -Parent
        $configTrusted = $true
        foreach ($anc in @($configDir, (Split-Path $configDir -Parent))) {
            if (-not $anc) { continue }
            if (-not (Test-Path -LiteralPath $anc -PathType Container)) { continue }
            if (-not (Test-PathTrustedForSystem -Path $anc -Kind 'Directory')) { $configTrusted = $false; break }
        }
        # v50 patch 3: also check the config file itself. A non-admin
        # who can pre-create manager.json inside a SYSTEM-owned
        # directory would pass the ancestor checks but supply hostile
        # content. The file-level check refuses that.
        if ($configTrusted -and -not (Test-PathTrustedForSystem -Path $ManagerConfigPath -Kind 'File')) {
            $configTrusted = $false
        }
        if ($configTrusted) {
            try {
                $raw = Get-Content -LiteralPath $ManagerConfigPath -Raw -ErrorAction Stop
                if ($raw) {
                    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
                    $catalogRoots = @()
                    if ($cfg.BackupCatalog -and $cfg.BackupCatalog.Roots) {
                        $catalogRoots = @($cfg.BackupCatalog.Roots | Where-Object { $_ } | ForEach-Object { [string]$_ })
                    } elseif ($cfg.BackupRoots) {
                        $catalogRoots = @($cfg.BackupRoots | Where-Object { $_ } | ForEach-Object { [string]$_ })
                    }
                    foreach ($r in $catalogRoots) {
                        if ($r -and $seen.Add($r)) { [void]$roots.Add($r) }
                    }
                }
            } catch {
                Write-Host "Could not read the manager config at $ManagerConfigPath : $_" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "Manager config at $ManagerConfigPath failed the v50 patch 3 trust check (owner or effective ACL of an ancestor directory or of the config file itself); using the default backup root only." -ForegroundColor DarkGray
        }
    }

    if ($seen.Add($DefaultBackupPath)) { [void]$roots.Add($DefaultBackupPath) }

    return @($roots.ToArray())
}

# Remove a directory if and only if it exists, is a container, is not a
# drive root, is not a reparse point, and is actually empty. Returns $true
# only when a removal occurred. Every uncertainty returns $false (the
# caller interprets that as "left in place").
function Remove-IfEmptyDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Path) { return $false }
    if ($Path -match '^[A-Za-z]:\\?$') { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    } catch { return $false }
    try {
        $inner = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    } catch { return $false }
    if ($inner.Count -ne 0) { return $false }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

Write-Header 'WinRE Manager - Clean Up Backups'

$roots = Get-BackupRoots -ExplicitPath $BackupPath
# v50 patch 3: determine whether the default root is in the requested
# scope. The default hierarchy (C:\Backup\WindowsRE, C:\Backup) is only
# cleaned up when the default root is actually being processed, so an
# explicit -BackupPath E:\MyBackups does not touch C:\Backup.
$defaultInScope = $false
foreach ($r in $roots) {
    if ($r -and ([System.StringComparer]::OrdinalIgnoreCase.Equals(([string]$r).TrimEnd('\'), $DefaultBackupPath.TrimEnd('\')))) {
        $defaultInScope = $true; break
    }
}
if (-not $roots -or $roots.Count -eq 0) {
    Write-Host 'No backup roots to inspect.' -ForegroundColor Yellow
    if (-not $NonInteractive) { Write-Wait }
    exit 0
}

Write-Host 'Backup roots:' -ForegroundColor Gray
foreach ($r in $roots) { Write-Host "  $r" -ForegroundColor Gray }
Write-Host 'A valid backup contains both winre.wim and backup.json.' -ForegroundColor DarkGray
Write-Host ''

# Enumerate backups across all roots.
$backups = @()
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    try {
        $subdirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)
    } catch {
        Write-Host "Could not enumerate $root : $_" -ForegroundColor Red
        continue
    }
    foreach ($dir in $subdirs) {
        # v50 patch 3: reject reparse-point candidates during discovery.
        # A junction or symlink under a backup root is not a valid backup
        # directory, and the deletion path uses Remove-Item -Recurse which
        # must not traverse a reparse point. This matches the helper's
        # own stated policy on empty-directory cleanup.
        try {
            $dItem = Get-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop
            if (($dItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-Host ("  Skipping reparse point: {0}" -f $dir.FullName) -ForegroundColor DarkGray
                continue
            }
        } catch {
            Write-Host ("  Skipping unreadable candidate: {0}" -f $dir.FullName) -ForegroundColor DarkGray
            continue
        }
        $wim  = Join-Path $dir.FullName 'winre.wim'
        $json = Join-Path $dir.FullName 'backup.json'
        if (-not (Test-Path -LiteralPath $wim -PathType Leaf)) { continue }
        # v50 patch 3: accept WIM-only backups (missing or unreadable
        # sidecar) and mark them so the operator can see the state. The
        # production restore action handles WIM-only with reduced
        # verification; the cleanup helper must be able to list and
        # delete them rather than silently ignoring them.
        $hasSidecar = $false
        try { if (Test-Path -LiteralPath $json -PathType Leaf) { $hasSidecar = $true } } catch { }

        $size = 0
        try { $size = (Get-Item -LiteralPath $wim -Force -ErrorAction Stop).Length } catch { }

        $sidecar = $null
        if ($hasSidecar) {
            try {
                $sidecar = Get-Content -LiteralPath $json -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch { $hasSidecar = $false }
        }

        $backups += [PSCustomObject]@{
            Name         = $dir.Name
            Path         = $dir.FullName
            Root         = $root
            HasSidecar   = $hasSidecar
            WimSizeBytes = $size
            WimSize      = Format-Size $size
            ManagerVer   = if ($sidecar -and $sidecar.ManagerVersion)  { $sidecar.ManagerVersion }  else { $null }
            BackupTime   = if ($sidecar -and $sidecar.BackupTime)      { $sidecar.BackupTime }      else { $null }
            SourceHash   = if ($sidecar -and $sidecar.SourceWimHash)   { $sidecar.SourceWimHash }   else { $null }
        }
    }
}

if ($backups.Count -eq 0) {
    Write-Host 'No valid backups found.' -ForegroundColor Green
    Write-Host 'A valid backup contains winre.wim; backup.json is optional.' -ForegroundColor DarkGray
    # v50 patch 3: run the empty timestamp-directory pruning loop even
    # when no valid backups exist, so a root with stale empty timestamp
    # directories from a previous interrupted run is cleaned up.
    $timestampLeafPatternEarly = '^\d{4}-\d{2}-\d{2}_\d{6}$'
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try { $subdirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop) } catch { continue }
        foreach ($dir in $subdirs) {
            if ($dir.Name -notmatch $timestampLeafPatternEarly) { continue }
            if (Remove-IfEmptyDirectory -Path $dir.FullName) {
                Write-Host ("  Removed empty backup directory: {0}" -f $dir.FullName) -ForegroundColor DarkGray
            }
        }
    }
    if ($defaultInScope) {
        if (Remove-IfEmptyDirectory -Path $DefaultBackupPath) {
            Write-Host ("  Removed empty default root: {0}" -f $DefaultBackupPath) -ForegroundColor DarkGray
        }
        $defaultParent = $null
        try { $defaultParent = Split-Path -Path $DefaultBackupPath -Parent } catch { }
        if (Remove-IfEmptyDirectory -Path $defaultParent) {
            Write-Host ("  Removed empty backup parent: {0}" -f $defaultParent) -ForegroundColor DarkGray
        }
    }
    if (-not $NonInteractive) { Write-Wait }
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
    if (-not $b.HasSidecar) { Write-Host " [WIM-ONLY, no sidecar]" -NoNewline -ForegroundColor Yellow }
    Write-Host ("   {0}" -f $b.WimSize) -NoNewline -ForegroundColor Gray
    Write-Host ("   " + $b.Root) -NoNewline -ForegroundColor DarkGray
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
    $numbers = [System.Collections.Generic.List[int]]::new()
    $backupCount = @($backups).Count
    foreach ($token in ($sel -split '\s+')) {
        $number = 0
        if (-not [int]::TryParse($token, [ref]$number)) { continue }
        if ($number -lt 1 -or $number -gt $backupCount) { continue }
        if (-not $numbers.Contains($number)) { $numbers.Add($number) }
    }
    if ($numbers.Count -eq 0) {
        Write-Host ''
        Write-Host 'No matching backups selected.' -ForegroundColor Yellow
        Write-Wait
        exit 0
    }
    foreach ($number in $numbers) {
        $toDelete += $backups[$number - 1]
    }
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
    # v50 patch 3: revalidate reparse-point status immediately before
    # deletion. The discovery-time check was a snapshot; the directory
    # could have been replaced between discovery and deletion.
    try {
        $bItem = Get-Item -LiteralPath $b.Path -Force -ErrorAction Stop
        if (($bItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Host ("  Skipping reparse point (refusing to recurse): {0}" -f $b.Name) -ForegroundColor Red
            $failCount++
            continue
        }
    } catch {
        Write-Host ("  Could not stat {0}: {1}" -f $b.Name, $_.Exception.Message) -ForegroundColor Red
        $failCount++
        continue
    }
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

# Empty-directory cleanup.
#
# 1. Timestamped subdirectories under each root that are empty are removed.
#    Non-timestamped directories are left alone even if empty, because they
#    may have been created by the operator rather than by a backup run.
#
# 2. The default hierarchy is walked bottom-up: C:\Backup\WindowsRE is
#    removed if empty, then C:\Backup is removed if it too is empty.
#    Both steps are no-ops if the directory is not empty, does not exist,
#    is a drive root, or is a reparse point.
$timestampLeafPattern = '^\d{4}-\d{2}-\d{2}_\d{6}$'
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    try {
        $subdirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)
    } catch { continue }
    foreach ($dir in $subdirs) {
        if ($dir.Name -notmatch $timestampLeafPattern) { continue }
        if (Remove-IfEmptyDirectory -Path $dir.FullName) {
            Write-Host ("  Removed empty backup directory: {0}" -f $dir.FullName) -ForegroundColor DarkGray
        }
    }
}

# v50 patch 3: only touch the default hierarchy when it is in the
# requested scope. An explicit -BackupPath E:\MyBackups must not
# prune empty directories under C:\Backup.
if ($defaultInScope) {
    if (Remove-IfEmptyDirectory -Path $DefaultBackupPath) {
        Write-Host ("  Removed empty default root: {0}" -f $DefaultBackupPath) -ForegroundColor DarkGray
    }
    $defaultParent = $null
    try { $defaultParent = Split-Path -Path $DefaultBackupPath -Parent } catch { }
    if (Remove-IfEmptyDirectory -Path $defaultParent) {
        Write-Host ("  Removed empty backup parent: {0}" -f $defaultParent) -ForegroundColor DarkGray
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
if ($failCount -gt 0) { exit 1 } else { exit 0 }
