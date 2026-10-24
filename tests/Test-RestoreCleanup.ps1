<#
.SYNOPSIS
    Isolated RestoreWork deletion and call-site regression checks.
.DESCRIPTION
    Loads only the cleanup helpers from WinRE.ps1 through its AST. Every
    filesystem mutation is confined to a new temporary fixture directory;
    no production pipeline, WinRE command, or storage cmdlet is invoked.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$productionPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WinRE.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($productionPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ($parseErrors | Out-String) }
foreach ($name in @('Test-DeploymentPathWithoutReparse', 'Remove-StagingDirectorySafely', 'Remove-RestoreWorkspaceSafely')) {
    $function = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $false))
    if ($function.Count -ne 1) { throw "Expected one production function: $name" }
    . ([scriptblock]::Create($function[0].Extent.Text))
}

$script:passed = 0
$script:DryRun = $false
$script:nonFatalWarning = $false
$script:capturedLogs = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    [void]$script:capturedLogs.Add("${Level}: $Message")
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}

$restoreFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RestoreAction'
}, $false)
$cleanupCalls = @($restoreFunction.Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-RestoreWorkspaceSafely'
}, $false))
Assert-True ($cleanupCalls.Count -eq 7) 'All seven RestoreWork cleanup sites call the guarded wrapper'
$rawRecursiveDeletes = @($restoreFunction.Body.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.CommandAst] -or $node.GetCommandName() -ne 'Remove-Item') { return $false }
    $recursive = @($node.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Recurse'
    }).Count -gt 0
    $targetsWorkspace = @($node.FindAll({
        param($nested)
        $nested -is [System.Management.Automation.Language.VariableExpressionAst] -and $nested.VariablePath.UserPath -eq 'restoreWorkDir'
    }, $false)).Count -gt 0
    return ($recursive -and $targetsWorkspace)
}, $false))
Assert-True ($rawRecursiveDeletes.Count -eq 0) 'Restore has no remaining raw recursive workspace deletion'
$preparationGuard = $cleanupCalls[0].Parent
while ($preparationGuard -and $preparationGuard -isnot [System.Management.Automation.Language.IfStatementAst]) {
    $preparationGuard = $preparationGuard.Parent
}
$guardThrows = @($preparationGuard.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ThrowStatementAst]
}, $false))
Assert-True ($guardThrows.Count -eq 1) 'Initial preparation aborts when guarded cleanup refuses the workspace'
$stagingFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-StagingDirectorySafely'
}, $false)
$stagingRemoveItemCalls = @($stagingFunction.Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Remove-Item'
}, $true))
Assert-True ($stagingRemoveItemCalls.Count -eq 0) 'The shared staging helper uses file and nonrecursive directory operations without a Remove-Item recursion prompt'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('WinRE-RestoreCleanupTests-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = [System.IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
[void][System.IO.Directory]::CreateDirectory($fixtureRoot)
function New-RestoreFixture {
    param([string]$Name)
    $directory = Join-Path $fixtureRoot $Name
    [void][System.IO.Directory]::CreateDirectory($directory)
    [System.IO.File]::WriteAllText((Join-Path $directory 'winre_rollback.wim'), 'rollback fixture bytes')
    return $directory
}
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
        foreach ($child in @(Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction Stop)) { Remove-FixtureTree $child.FullName }
        [System.IO.Directory]::Delete($fullPath, $false)
    } else { [System.IO.File]::Delete($fullPath) }
}

try {
    $missing = Join-Path $fixtureRoot 'missing'
    Assert-True (Remove-RestoreWorkspaceSafely -Path $missing) 'Missing RestoreWork is already clean'
    $empty = Join-Path $fixtureRoot 'empty'
    [void][System.IO.Directory]::CreateDirectory($empty)
    Assert-True (Remove-RestoreWorkspaceSafely -Path $empty) 'An empty RestoreWork can be removed'
    Assert-True (-not (Test-Path -LiteralPath $empty)) 'Empty workspace directory was removed'

    $workspace = New-RestoreFixture 'valid [1]'
    Assert-True (Remove-RestoreWorkspaceSafely -Path $workspace) 'Only the expected rollback WIM is accepted under a literal path'
    Assert-True (-not (Test-Path -LiteralPath $workspace)) 'Expected rollback WIM and workspace were removed'

    $workspace = New-RestoreFixture 'read-only'
    [IO.File]::SetAttributes((Join-Path $workspace 'winre_rollback.wim'), [IO.FileAttributes]::ReadOnly)
    Assert-True (Remove-RestoreWorkspaceSafely -Path $workspace) 'A genuine read-only rollback WIM retains Force cleanup support'

    $workspace = New-RestoreFixture 'unexpected'
    [System.IO.File]::WriteAllText((Join-Path $workspace 'personal.txt'), 'retain this')
    $script:nonFatalWarning = $false
    Assert-True (-not (Remove-RestoreWorkspaceSafely -Path $workspace)) 'Unexpected file refuses the entire workspace deletion'
    Assert-True ((Get-ChildItem -LiteralPath $workspace -Force).Count -eq 2) 'Unexpected-file refusal preserves the expected rollback WIM too'
    Assert-True $script:nonFatalWarning 'Cleanup refusal propagates a warning flag'
    Assert-True (($script:capturedLogs | Out-String) -match 'cleanup refused or failed') 'Cleanup refusal is logged'

    $workspace = New-RestoreFixture 'nested'
    $nested = Join-Path $workspace 'personal'
    [void][System.IO.Directory]::CreateDirectory($nested)
    [System.IO.File]::WriteAllText((Join-Path $nested 'valuable.txt'), 'retain this')
    Assert-True (-not (Remove-RestoreWorkspaceSafely -Path $workspace)) 'A subdirectory refuses workspace deletion'
    Assert-True ((Test-Path -LiteralPath (Join-Path $workspace 'winre_rollback.wim')) -and (Test-Path -LiteralPath (Join-Path $nested 'valuable.txt'))) 'Subdirectory refusal retains rollback WIM and nested data'

    $workspace = New-RestoreFixture 'junction-child'
    $outside = New-RestoreFixture 'junction-target'
    [void](New-Item -ItemType Junction -Path (Join-Path $workspace 'foreign') -Target $outside -ErrorAction Stop)
    Assert-True (-not (Remove-RestoreWorkspaceSafely -Path $workspace)) 'A child junction refuses workspace deletion'
    Assert-True ((Test-Path -LiteralPath (Join-Path $workspace 'winre_rollback.wim')) -and (Test-Path -LiteralPath (Join-Path $outside 'winre_rollback.wim'))) 'Child-junction refusal retains workspace and target data'

    $link = Join-Path $fixtureRoot 'selected-junction'
    [void](New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop)
    Assert-True (-not (Remove-RestoreWorkspaceSafely -Path $link)) 'A selected workspace junction is refused'
    Assert-True (Test-Path -LiteralPath (Join-Path $outside 'winre_rollback.wim')) 'Selected-junction target remains intact'

    $realParent = Join-Path $fixtureRoot 'real-parent'
    [void][System.IO.Directory]::CreateDirectory($realParent)
    $realWorkspace = Join-Path $realParent 'RestoreWork'
    [void][System.IO.Directory]::CreateDirectory($realWorkspace)
    [System.IO.File]::WriteAllText((Join-Path $realWorkspace 'winre_rollback.wim'), 'retain this')
    $parentLink = Join-Path $fixtureRoot 'parent-junction'
    [void](New-Item -ItemType Junction -Path $parentLink -Target $realParent -ErrorAction Stop)
    Assert-True (-not (Remove-RestoreWorkspaceSafely -Path (Join-Path $parentLink 'RestoreWork'))) 'A junction in the workspace ancestry is refused'
    Assert-True (Test-Path -LiteralPath (Join-Path $realWorkspace 'winre_rollback.wim')) 'Ancestor-junction refusal preserves target data'

    $workspace = New-RestoreFixture 'file-changes-to-directory'
    $script:changingWorkspace = $workspace
    $script:inventoryReads = 0
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Force)
        $snapshot = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop)
        if ($LiteralPath -eq $script:changingWorkspace) {
            $script:inventoryReads++
            if ($script:inventoryReads -eq 2) {
                $changedEntry = Join-Path $LiteralPath 'winre_rollback.wim'
                [IO.File]::Delete($changedEntry)
                [void][IO.Directory]::CreateDirectory($changedEntry)
                [IO.File]::WriteAllText((Join-Path $changedEntry 'valuable.txt'), 'retain this')
            }
        }
        return $snapshot
    }
    try {
        Assert-True (-not (Remove-RestoreWorkspaceSafely -Path $workspace)) 'A file changed to a nonempty directory after inspection is refused without recursion'
        Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'winre_rollback.wim\valuable.txt')) 'A file-to-directory replacement retains its nested data'
    } finally { Remove-Item -LiteralPath Function:\Get-ChildItem -ErrorAction Stop }

    $workspace = New-RestoreFixture 'child-added-after-final-inventory'
    $script:changingWorkspace = $workspace
    $script:inventoryReads = 0
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Force)
        $snapshot = @(Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop)
        if ($LiteralPath -eq $script:changingWorkspace) {
            $script:inventoryReads++
            if ($script:inventoryReads -eq 3) {
                [IO.File]::WriteAllText((Join-Path $LiteralPath 'new-data.txt'), 'retain this')
            }
        }
        return $snapshot
    }
    try {
        Assert-True (-not (Remove-RestoreWorkspaceSafely -Path $workspace)) 'A new child after the final empty inventory prevents directory deletion'
        Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'new-data.txt')) 'The nonrecursive final operation preserves a newly added child'
    } finally { Remove-Item -LiteralPath Function:\Get-ChildItem -ErrorAction Stop }

    $workspace = New-RestoreFixture 'dry-run'
    $script:DryRun = $true
    Assert-True (Remove-RestoreWorkspaceSafely -Path $workspace) 'DryRun reports its intended cleanup successfully'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'winre_rollback.wim')) 'DryRun leaves the rollback WIM intact'
    $script:DryRun = $false

    $driveRoot = [System.IO.Path]::GetPathRoot($fixtureRoot)
    Assert-True (-not (Remove-StagingDirectorySafely -Path $driveRoot -ExpectedLeafName 'winre_rollback.wim')) 'The staging helper refuses a drive root before deletion'
    Write-Host ("Restore cleanup regression checks: {0} passed." -f $script:passed)
} finally {
    $script:DryRun = $false
    Remove-FixtureTree $fixtureRoot
}
