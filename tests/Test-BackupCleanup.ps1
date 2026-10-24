<#
.SYNOPSIS
    Isolated v50 patch 5 backup-cleanup regression checks.
.DESCRIPTION
    Extracts only Remove-BackupDirectorySafely from production using its AST.
    File mutations are restricted to a newly created temporary fixture tree.
    The standalone cleanup entry point is invoked only with -NonInteractive
    and an explicit fixture root. No real backup catalogue is consulted.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$cleanupPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Cleanup-Backups.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($cleanupPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ($parseErrors | Out-String) }
$helper = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Remove-BackupDirectorySafely'
}, $false))
if ($helper.Count -ne 1) { throw 'Expected exactly one production deletion helper.' }
. ([scriptblock]::Create($helper[0].Extent.Text))

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('WinRE-BackupCleanupTests-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = [System.IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
[void][System.IO.Directory]::CreateDirectory($fixtureRoot)
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}

function New-BackupFixture {
    param([string]$Name, [switch]$Sidecar)
    $directory = Join-Path $fixtureRoot $Name
    [void][System.IO.Directory]::CreateDirectory($directory)
    [System.IO.File]::WriteAllText((Join-Path $directory 'winre.wim'), 'test WIM bytes')
    if ($Sidecar) { [System.IO.File]::WriteAllText((Join-Path $directory 'backup.json'), '{malformed sidecar') }
    return $directory
}

function Assert-Refused {
    param([string]$Path, [string]$RootPath, [string]$Message)
    $refused = $false
    try { [void](Remove-BackupDirectorySafely -Path $Path -RootPath $RootPath) }
    catch { $refused = $true }
    Assert-True $refused $Message
}

# Fixture teardown never follows junctions or symlinks. The caller checks
# the absolute boundary before walking only this run's generated directory.
function Remove-FixtureTree {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not ($fullPath -eq $fixtureRoot -or $fullPath.StartsWith($fixtureRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Fixture teardown escaped its generated root: $fullPath"
    }
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) { [System.IO.Directory]::Delete($fullPath, $false) }
        else { [System.IO.File]::Delete($fullPath) }
        return
    }
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction Stop)) {
            Remove-FixtureTree -Path $child.FullName
        }
        [System.IO.Directory]::Delete($fullPath, $false)
    } else { [System.IO.File]::Delete($fullPath) }
}

try {
    $backup = New-BackupFixture 'operator chosen [1]'
    Assert-True (Remove-BackupDirectorySafely -Path $backup -RootPath $fixtureRoot) 'WIM-only backup with arbitrary literal directory name is deleted'
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'WIM-only backup directory was removed'

    $backup = New-BackupFixture 'malformed-sidecar' -Sidecar
    Assert-True (Remove-BackupDirectorySafely -Path $backup -RootPath $fixtureRoot) 'Malformed sidecar does not prevent guarded deletion'
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'Sidecar backup directory was removed'

    $backup = New-BackupFixture 'read-only-backup' -Sidecar
    foreach ($leaf in @('winre.wim', 'backup.json')) {
        [System.IO.File]::SetAttributes((Join-Path $backup $leaf), [System.IO.FileAttributes]::ReadOnly)
    }
    Assert-True (Remove-BackupDirectorySafely -Path $backup -RootPath $fixtureRoot) 'Genuine read-only backup files retain the previous Force deletion support'
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'Read-only backup directory was removed'

    $backup = New-BackupFixture 'relative-backup'
    Push-Location -LiteralPath $fixtureRoot
    try {
        Assert-True (Remove-BackupDirectorySafely -Path '.\relative-backup' -RootPath '.') 'Relative backup paths resolve against the PowerShell current location'
    } finally { Pop-Location }
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'Relative-root backup directory was removed'

    $backup = New-BackupFixture 'unexpected-file' -Sidecar
    [System.IO.File]::WriteAllText((Join-Path $backup 'valuable.txt'), 'retain this')
    Assert-Refused $backup $fixtureRoot 'Unexpected direct file refuses the entire deletion'
    Assert-True ((Get-ChildItem -LiteralPath $backup -Force).Count -eq 3) 'Inventory refusal leaves both backup files and unexpected file intact'

    $backup = New-BackupFixture 'unexpected-directory' -Sidecar
    $nested = Join-Path $backup 'personal'
    [void][System.IO.Directory]::CreateDirectory($nested)
    [System.IO.File]::WriteAllText((Join-Path $nested 'valuable.txt'), 'retain this')
    Assert-Refused $backup $fixtureRoot 'A subdirectory refuses the entire deletion'
    Assert-True ((Test-Path -LiteralPath (Join-Path $backup 'winre.wim')) -and (Test-Path -LiteralPath (Join-Path $nested 'valuable.txt'))) 'Subdirectory refusal preserves WIM and nested contents'

    $backup = New-BackupFixture 'hidden-unexpected-file'
    $hidden = Join-Path $backup 'hidden.txt'
    [System.IO.File]::WriteAllText($hidden, 'retain this')
    [System.IO.File]::SetAttributes($hidden, [System.IO.FileAttributes]::Hidden)
    Assert-Refused $backup $fixtureRoot 'Hidden unexpected file is included in the inventory and refused'
    Assert-True (Test-Path -LiteralPath (Join-Path $backup 'winre.wim')) 'Hidden-file refusal occurs before deleting WIM'

    $backup = New-BackupFixture 'wrong-root'
    Assert-Refused $backup (Join-Path $fixtureRoot 'different-root') 'Selected directory must be a direct child of the enumerated root'
    Assert-True (Test-Path -LiteralPath (Join-Path $backup 'winre.wim')) 'Root mismatch leaves backup intact'

    $empty = Join-Path $fixtureRoot 'not-a-backup'
    [void][System.IO.Directory]::CreateDirectory($empty)
    [System.IO.File]::WriteAllText((Join-Path $empty 'backup.json'), '{}')
    Assert-Refused $empty $fixtureRoot 'A vanished WIM refuses deletion rather than deleting the remaining sidecar'
    Assert-True (Test-Path -LiteralPath (Join-Path $empty 'backup.json')) 'Missing-WIM refusal preserves sidecar'

    $backup = New-BackupFixture 'inventory-changed'
    $script:changingBackup = $backup
    $script:inventoryReads = 0
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Force)
        if ($LiteralPath -eq $script:changingBackup) {
            $script:inventoryReads++
            if ($script:inventoryReads -eq 2) {
                [System.IO.File]::WriteAllText((Join-Path $LiteralPath 'backup.json'), '{}')
            }
        }
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop
    }
    try {
        Assert-Refused $backup $fixtureRoot 'A newly added allowed file after initial validation also stops deletion'
        Assert-True ((Test-Path -LiteralPath (Join-Path $backup 'winre.wim')) -and (Test-Path -LiteralPath (Join-Path $backup 'backup.json'))) 'Pre-delete inventory change leaves all files intact'
    } finally { Remove-Item -LiteralPath Function:\Get-ChildItem -ErrorAction Stop }

    $outside = New-BackupFixture 'junction-target'
    $backup = New-BackupFixture 'unexpected-junction'
    $junction = Join-Path $backup 'foreign'
    [void](New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop)
    Assert-Refused $backup $fixtureRoot 'A direct-child junction refuses deletion'
    Assert-True ((Test-Path -LiteralPath (Join-Path $backup 'winre.wim')) -and (Test-Path -LiteralPath (Join-Path $outside 'winre.wim'))) 'Junction refusal leaves candidate and target intact'

    $linked = Join-Path $fixtureRoot 'selected-junction'
    [void](New-Item -ItemType Junction -Path $linked -Target $outside -ErrorAction Stop)
    Assert-Refused $linked $fixtureRoot 'A selected directory junction is refused'
    Assert-True (Test-Path -LiteralPath (Join-Path $outside 'winre.wim')) 'Selected-junction target remains intact'

    $realRoot = Join-Path $fixtureRoot 'real-root'
    [void][System.IO.Directory]::CreateDirectory($realRoot)
    $realBackup = Join-Path $realRoot 'backup'
    [void][System.IO.Directory]::CreateDirectory($realBackup)
    [System.IO.File]::WriteAllText((Join-Path $realBackup 'winre.wim'), 'retain this')
    $rootLink = Join-Path $fixtureRoot 'root-junction'
    [void](New-Item -ItemType Junction -Path $rootLink -Target $realRoot -ErrorAction Stop)
    Assert-Refused (Join-Path $rootLink 'backup') $rootLink 'A junction in the backup root is refused'
    Assert-True (Test-Path -LiteralPath (Join-Path $realBackup 'winre.wim')) 'Root-junction refusal preserves real backup'

    $listingRoot = Join-Path $fixtureRoot 'listing-only'
    $timestamp = Join-Path $listingRoot '2026-10-23_123456'
    [void][System.IO.Directory]::CreateDirectory($timestamp)
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $listingOutput = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $cleanupPath -BackupPath $listingRoot -NonInteractive 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'NonInteractive empty-backup listing exits successfully'
    Assert-True (Test-Path -LiteralPath $timestamp -PathType Container) 'NonInteractive empty-backup listing never prunes an empty timestamp directory'
    Assert-True (($listingOutput | Out-String) -match 'listing only') 'NonInteractive empty-backup listing reports its read-only mode'

    Write-Host ("Backup cleanup regression checks: {0} passed." -f $script:passed)
} finally {
    Remove-FixtureTree -Path $fixtureRoot
}
