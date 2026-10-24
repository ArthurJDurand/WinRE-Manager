<#
.SYNOPSIS
    Isolated v50 patch 5 deployment safety regression tests.
.DESCRIPTION
    Extracts named functions with the PowerShell parser. Every storage,
    WinRE, WIM, trust and journal provider is mocked. No production main
    flow, real storage command, DISM operation, or journal write executes.
    These checks supplement disposable-machine failure/boot testing.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$productionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\WinRE.ps1'
$tokens = $null
$parseErrors = $null
$source = [System.Management.Automation.Language.Parser]::ParseFile($productionPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Production source has parse errors.' }
foreach ($name in @('ConvertFrom-WinRELocation', 'ConvertTo-WinREPathArgument', 'ConvertFrom-DeploymentJson', 'Test-DeploymentPathWithoutReparse', 'Assert-DeploymentCandidate', 'Read-PendingDeployment', 'Write-PendingDeployment', 'Get-RecoveryLayoutAssessment', 'Get-RecoveryPartitions', 'Find-SuitableRecoveryPartition', 'Ensure-AdequateRecoveryPartition')) {
    $definition = $source.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Required production function missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$WinREFreeSpaceMiB = 250
$NewPartitionFilesystemMiB = 30
$NewPartitionIncrementMiB = 100
$NewPartitionMinimumMiB = 1000
$MaxManagedRecoveryPartitionMiB = 2048
$PendingDeploymentPath = 'C:\ProgramData\OEM\WinRE-Manager\pending-deployment.json'
$PendingDeploymentDir = 'C:\ProgramData\OEM\WinRE-Manager\PendingDeployment'
$script:Passed = 0

function Reset-Fixture {
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:Fixture = @{
        Disk = [pscustomobject]@{ Number = 0; UniqueId = 'disk-identity'; PartitionStyle = 'GPT' }
        OS = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; Offset = [int64]1048576 }
        Recovery = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 4; Size = [int64](1200MB); GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; MbrType = 0; DriveLetter = $null }
        Volume = [pscustomobject]@{ UniqueId = 'volume-identity'; FileSystem = 'NTFS'; SizeRemaining = [int64](250MB) }
        OSVolume = [pscustomobject]@{ UniqueId = 'volume-identity'; FileSystem = 'NTFS'; SizeRemaining = [int64](100GB) }
        Encrypted = $false
        RecoveryEncrypted = $false
        WimBytes = [int64](900MB)
        Hash = ('A' * 64)
        Paths = @{}
        Attributes = @{}
        Untrusted = @{}
        VolumeThrows = $false
        EnumerationFailure = $null
        SelectorHasRoom = $true
        SelectorRequiredBytes = $null
        ProbeThrows = $false
        DropWrite = $false
        JournalCorruptField = $null
        JournalCorruptValue = $null
        PathHashes = @{}
        Record = @{
            SchemaVersion = 1; OperationId = '6fb381c0-1886-481c-83ee-f732ef646e6e'
            Mode = 'Preserved'; Phase = 'Prepared'; ExpectedSourceHash = ('A' * 64)
            CandidatePath = 'C:\ProgramData\OEM\WinRE-Manager\PendingDeployment\pending.wim'; OSDiskId = 'disk-identity'
            OSVolumeId = 'volume-identity'; OSPartitionOffset = [int64]1048576
            PreviousStatus = 'Enabled'; PreviousLocation = 'mock-old-route'; PreviousHash = ('B' * 64)
            DesiredStateId = 'test-dsi'; LocalInputsId = 'test-inputs'; DriverVersion = 'test-driver'
            PriorManagedHash = ('C' * 64); LineageId = 'test-lineage'; DeployedWinREMetadata = '10.0.0.0|0'
        }
    }
    $script:Fixture.Active = $script:Fixture.Recovery
    $script:Fixture.Partitions = @($script:Fixture.OS, $script:Fixture.Recovery)
    $script:Fixture.Content = $script:Fixture.Record | ConvertTo-Json -Depth 5
    $script:DryRun = $false
    $script:PendingDeploymentPresent = $false
    $script:ResumeTaskShouldPersist = $false
    $script:PendingDeployment = $null
    $script:GeometryRestoreFailed = $false
    $script:nonFatalWarning = $false
    $script:DeploymentCandidateLock = $null
    $script:LocalInputsId = 'test-inputs'
}

# Provider mocks: any operation occurs against the in-memory fixture only.
function Get-OSDisk { $script:Calls.Add('Get-OSDisk'); return $script:Fixture.Disk }
function Get-OSPartition { $script:Calls.Add('Get-OSPartition'); return $script:Fixture.OS }
function Get-Disk { [CmdletBinding()]param($Number) return $script:Fixture.Disk }
function Get-Partition {
    [CmdletBinding()]
    param($DiskNumber, $PartitionNumber)
    $script:Calls.Add('Get-Partition')
    if ($PSBoundParameters.ContainsKey('PartitionNumber')) { return ($script:Fixture.Partitions | Where-Object { $_.PartitionNumber -eq $PartitionNumber }) }
    if ($script:Fixture.EnumerationFailure) {
        if ($script:Fixture.EnumerationFailure -eq 'Terminating') { throw 'Injected selector enumeration failure' }
        if ($script:Fixture.EnumerationFailure -eq 'Partial') { $script:Fixture.Recovery }
        Write-Error 'Injected selector enumeration failure'
        return
    }
    return ($script:Fixture.Partitions | Where-Object { $_.DiskNumber -eq $DiskNumber })
}
function Test-RecoveryPartitionHasRoom {
    param($DiskNumber, $PartitionNumber, $Letter, $RequiredBytes)
    $script:Calls.Add('CheckSelectorRoom')
    $script:Fixture.SelectorRequiredBytes = $RequiredBytes
    return $script:Fixture.SelectorHasRoom
}
function Resolve-WinRELocationToPartition {
    param($Location)
    $script:Calls.Add('Resolve-Route')
    if ([string]::IsNullOrEmpty($Location) -or $Location -eq 'mock-unresolvable-route') { return $null }
    if ($Location -eq 'mock-osfallback-route') { return $script:Fixture.OS }
    if ($Location -like '*GLOBALROOT*' -or $Location -eq 'mock-target-route') { return $script:Fixture.Recovery }
    return $script:Fixture.Active
}
function Get-Volume {
    param($Partition, $ErrorAction)
    $script:Calls.Add('Get-Volume')
    if ($script:Fixture.VolumeThrows) { throw 'mock inaccessible volume' }
    if ($Partition.PartitionNumber -eq 3) { return $script:Fixture.OSVolume }
    return $script:Fixture.Volume
}
function Test-VolumeEncrypted {
    param($MountPoint)
    $script:Calls.Add('CheckOSBitLocker')
    if ($MountPoint -eq $env:SystemDrive) { return $script:Fixture.Encrypted }
    return $script:Fixture.RecoveryEncrypted
}
function Get-Item {
    param($LiteralPath, [switch]$Force, $ErrorAction, $ErrorVariable)
    $script:Calls.Add("Get-Item:$LiteralPath")
    if ($ErrorVariable) { Set-Variable -Name $ErrorVariable -Value @() -Scope 1 }
    if ($script:Fixture.Paths.ContainsKey($LiteralPath) -and -not $script:Fixture.Paths[$LiteralPath]) { return $null }
    $attributes = if ($script:Fixture.Attributes.ContainsKey($LiteralPath)) { $script:Fixture.Attributes[$LiteralPath] } else { [IO.FileAttributes]::Normal }
    return [pscustomobject]@{ Length = $script:Fixture.WimBytes; Attributes = $attributes }
}
function Test-Path {
    param($LiteralPath, $PathType, $ErrorAction)
    $script:Calls.Add("Test-Path:$LiteralPath")
    if ($script:Fixture.ProbeThrows -and $LiteralPath -eq $PendingDeploymentPath) { throw 'mock journal probe denied' }
    if ($script:Fixture.Paths.ContainsKey($LiteralPath)) { return $script:Fixture.Paths[$LiteralPath] }
    return $true
}
function Get-LiveWimHash {
    param($WimPath)
    $script:Calls.Add("Get-Hash:$WimPath")
    if ($script:Fixture.PathHashes.ContainsKey($WimPath)) { return $script:Fixture.PathHashes[$WimPath] }
    return $script:Fixture.Hash
}
function Test-PathTrustedForSystem { param($Path, $Kind) $script:Calls.Add("Trust:$Kind`:$Path"); return (-not $script:Fixture.Untrusted.ContainsKey($Path)) }
function Test-DeploymentStoreTrusted { param($Path) return (Test-PathTrustedForSystem -Path $Path -Kind Directory) }
function Set-DeploymentFileSecurity { param($Path) $script:Calls.Add("ProtectFile:$Path") }
function Get-Content {
    param($LiteralPath, [switch]$Raw, $ErrorAction)
    $script:Calls.Add("Read:$LiteralPath")
    if ($LiteralPath -eq "$env:SystemDrive\Recovery\OEM\$StateFileName") { return $script:Fixture.StateContent }
    return $script:Fixture.Content
}
function Initialize-DeploymentJournalDirectory { param([switch]$IncludeCandidateDirectory) $script:Calls.Add('Initialize-JournalDirectory') }
function Write-FileAtomically {
    param($Path, $Content)
    $script:Calls.Add('Atomic-JournalWrite')
    if (-not $script:Fixture.DropWrite) {
        if ($script:Fixture.JournalCorruptField) {
            $mutant = $Content | ConvertFrom-Json
            $mutant.($script:Fixture.JournalCorruptField) = $script:Fixture.JournalCorruptValue
            $Content = $mutant | ConvertTo-Json -Depth 5
        }
        $script:Fixture.Content = $Content
        $script:Fixture.Paths[$Path] = $true
    }
}
function Write-Log { param($Message, $Level) $script:Calls.Add("Log:$Message") }

# A mistakenly added mutation must throw rather than reaching a real cmdlet.
foreach ($name in @('Set-Partition', 'Resize-Partition', 'Remove-Partition', 'New-Partition', 'Format-Volume', 'Invoke-DriveLetterAssignment', 'Invoke-DriveLetterRemoval', 'Disable-WinRE', 'Invoke-ReAgentC', 'Mount-WindowsImage', 'Dismount-WindowsImage')) {
    Set-Item -Path "Function:$name" -Value ([scriptblock]::Create("throw 'Unexpected mocked mutation: $name'"))
}

function Assert-Case {
    param([string]$Name, [scriptblock]$Body)
    Reset-Fixture
    & $Body
    $script:Passed++
    Write-Output "PASS: $Name"
}
function Assert-True { param($Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $caught = $null
    try { & $Body } catch { $caught = $_ }
    if (-not $caught -or ($Pattern -and $caught.Exception.Message -notlike "*$Pattern*")) { throw "Expected error matching '$Pattern'; actual: $caught" }
}
function Get-Assessment { Get-RecoveryLayoutAssessment -WinREState @{ Status = 'Enabled'; Location = 'mock-route' } -WimPath 'mock-registered.wim' }

Assert-Case 'selector reuses an exact GPT WIM-plus-250 target below the creation minimum' {
    $script:Fixture.Disk.Number = 5
    $script:Fixture.OS.DiskNumber = 5
    $script:Fixture.Recovery.DiskNumber = 5
    $script:Fixture.Recovery.DriveLetter = 'R'
    $script:Fixture.Recovery.Size = [int64](850MB)
    $target = Find-SuitableRecoveryPartition -RequiredWimSizeMB 600
    Assert-True ($target -and $target.DiskNumber -eq 5 -and $target.PartitionNumber -eq 4 -and $target.DriveLetter -eq 'R') 'The GPT target on the actual OS disk was not reused.'
    Assert-True ($script:Fixture.SelectorRequiredBytes -eq 850MB) 'Selection changed the existing WIM-plus-250 reuse requirement.'
}
Assert-Case 'selector retains MBR 0x27 recovery discovery' {
    $script:Fixture.Recovery.DriveLetter = 'R'
    $script:Fixture.Recovery.GptType = $null
    $script:Fixture.Recovery.MbrType = 0x27
    Assert-True ((Find-SuitableRecoveryPartition -RequiredWimSizeMB 900).PartitionNumber -eq 4) 'The MBR recovery type was excluded.'
}
Assert-Case 'selector permits creation after a successful inventory with no recovery type' {
    $script:Fixture.Partitions = @($script:Fixture.OS)
    Assert-True ($null -eq (Find-SuitableRecoveryPartition -RequiredWimSizeMB 900)) 'A legitimate empty typed inventory was not represented as no target.'
    Assert-True (-not $script:Calls.Contains('CheckSelectorRoom')) 'A nonexistent target reached volume inspection.'
}
Assert-Case 'selector excludes a label-only recovery partition' {
    $script:Fixture.Recovery.GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $script:Fixture.Recovery | Add-Member -NotePropertyName FileSystemLabel -NotePropertyValue 'Recovery'
    Assert-True ($null -eq (Find-SuitableRecoveryPartition -RequiredWimSizeMB 900)) 'A label-only partition qualified as dedicated recovery.'
    Assert-True (-not $script:Calls.Contains('CheckSelectorRoom')) 'Label-only recovery reached volume inspection.'
}
Assert-Case 'selector excludes the OS partition even when recovery type-coded' {
    $script:Fixture.Recovery.PartitionNumber = $script:Fixture.OS.PartitionNumber
    $script:Fixture.Partitions = @($script:Fixture.Recovery)
    Assert-True ($null -eq (Find-SuitableRecoveryPartition -RequiredWimSizeMB 900)) 'The OS partition qualified as a dedicated recovery target.'
    Assert-True (-not $script:Calls.Contains('CheckSelectorRoom')) 'The OS partition reached recovery-volume inspection.'
}
Assert-Case 'selector retains relocation for multiple recovery-typed partitions' {
    $second = $script:Fixture.Recovery.PSObject.Copy()
    $second.PartitionNumber = 5
    $script:Fixture.Partitions += $second
    Assert-True ($null -eq (Find-SuitableRecoveryPartition -RequiredWimSizeMB 900)) 'Multiple typed partitions were silently reduced to one target.'
    Assert-True (-not $script:Calls.Contains('CheckSelectorRoom')) 'An ambiguous target reached volume inspection.'
}
foreach ($failure in @('NonTerminating', 'Terminating', 'Partial')) {
    Assert-Case "selector rejects $failure partition inventory failure before target inspection" {
        # Even a caller using Continue must not turn a provider error into
        # absence. Partial output must not make an incomplete inventory usable.
        $ErrorActionPreference = 'Continue'
        $script:Fixture.Recovery.DriveLetter = 'R'
        $script:Fixture.EnumerationFailure = $failure
        Assert-Throws { Find-SuitableRecoveryPartition -RequiredWimSizeMB 900 } 'Injected selector enumeration failure'
        Assert-True (-not $script:Calls.Contains('CheckSelectorRoom')) 'An incomplete inventory reached target inspection.'
    }
}

Assert-Case 'reuse accepts existing partition below the 1000 MiB creation minimum' {
    $script:Fixture.WimBytes = [int64](600MB)
    $script:Fixture.Recovery.Size = [int64](900MB)
    Assert-True (Get-Assessment).Suitable 'A suitable existing 900 MiB partition was incorrectly subjected to the creation minimum.'
}
Assert-Case 'reuse accepts exact WIM plus 250 MiB without creation overhead/rounding' {
    $script:Fixture.Recovery.Size = [int64](1150MB)
    Assert-True (Get-Assessment).Suitable 'The exact reuse boundary should pass.'
}
Assert-Case 'reuse rejects total size one byte below its threshold' {
    $script:Fixture.Recovery.Size = [int64](1150MB - 1)
    Assert-True (-not (Get-Assessment).Suitable) 'The total-size boundary failed open.'
}
Assert-Case 'reuse rejects effective available space one byte below its threshold' {
    $script:Fixture.Volume.SizeRemaining = [int64](250MB - 1)
    Assert-True (-not (Get-Assessment).Suitable) 'The available-space boundary failed open.'
}
Assert-Case 'HP 14s preserved image fails the existing reuse rule' {
    $script:Fixture.WimBytes = [int64](968.6 * 1MB)
    $script:Fixture.Recovery.Size = [int64](1.08 * 1GB)
    $script:Fixture.Volume.SizeRemaining = [int64](114.6 * 1MB)
    Assert-True (-not (Get-Assessment).Suitable) 'The undersized HP partition was accepted.'
}
Assert-Case 'assessment accepts exactly 2048 MiB and rejects a single byte above' {
    $script:Fixture.Recovery.Size = [int64](2048MB)
    Assert-True (Get-Assessment).Suitable 'The protection ceiling must permit its exact boundary.'
    $script:Fixture.Recovery.Size++
    Assert-True (-not (Get-Assessment).Suitable) 'An oversized partition was accepted.'
}
Assert-Case 'assessment rejects non-NTFS recovery' {
    $script:Fixture.Volume.FileSystem = 'FAT32'
    Assert-True (-not (Get-Assessment).Suitable) 'Non-NTFS recovery was accepted.'
}
Assert-Case 'assessment rejects OS-fallback' {
    $script:Fixture.Active = $script:Fixture.OS
    Assert-True (-not (Get-Assessment).Suitable) 'An OS-hosted route was accepted as dedicated.'
}
Assert-Case 'assessment rejects multiple recovery partitions' {
    $script:Fixture.Partitions += [pscustomobject]@{ DiskNumber = 0; PartitionNumber = 5; GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; MbrType = 0 }
    Assert-True (-not (Get-Assessment).Suitable) 'Multiple recovery partitions were accepted.'
}
Assert-Case 'assessment rejects an active route on another disk' {
    $script:Fixture.Recovery.DiskNumber = 1
    Assert-True (-not (Get-Assessment).Suitable) 'A route outside the OS disk was accepted.'
}
Assert-Case 'assessment fails closed when volume enumeration throws' {
    $script:Fixture.VolumeThrows = $true
    $assessment = Get-Assessment
    Assert-True (-not $assessment.Suitable -and $assessment.Reason -like '*indeterminate*') 'Unreadable volume was accepted or misreported.'
}
Assert-Case 'assessment invokes only read providers and assigns no drive letters' {
    Assert-True (Get-Assessment).Suitable 'Fixture should be suitable.'
    $unexpected = @($script:Calls | Where-Object { $_ -notmatch '^(Get-OSDisk|Get-OSPartition|Resolve-Route|Get-Partition|Get-Item:|Get-Volume|CheckOSBitLocker)' })
    Assert-True ($unexpected.Count -eq 0) "Assessment invoked an unexpected provider: $($unexpected -join ', ')"
}
foreach ($encryptedState in @($true, $null)) {
    Assert-Case 'assessment refuses encrypted or indeterminate dedicated target' {
        $script:Fixture.RecoveryEncrypted = $encryptedState
        Assert-True (-not (Get-Assessment).Suitable) 'Unverified encrypted dedicated route was accepted.'
    }
}
foreach ($entry in @(@{ Wim = 600; Bucket = 1000 }, @{ Wim = 900; Bucket = 1200 }, @{ Wim = 969; Bucket = 1300 })) {
    Assert-Case "creation retains $($entry.Wim) MiB WIM -> $($entry.Bucket) MiB bucket" {
        $script:Fixture.Disk = $null
        $result = Ensure-AdequateRecoveryPartition -RequiredWimSizeMB $entry.Wim
        Assert-True ($null -eq $result) 'Sizing probe should stop at mocked absent OS disk.'
        Assert-True (@($script:Calls | Where-Object { $_ -like "*dynamic size $($entry.Bucket) MiB" }).Count -eq 1) 'The creation sizing recipe changed.'
    }
}

Assert-Case 'canonical trusted candidate with matching bytes and OS identity validates' { Assert-DeploymentCandidate -Record $script:Fixture.Record }
Assert-Case 'managed mode shares candidate validation without foreign ownership inference' {
    $script:Fixture.Record.Mode = 'Managed'
    Assert-DeploymentCandidate -Record $script:Fixture.Record
}
foreach ($entry in @(@{ Field = 'SchemaVersion'; Value = 2 }, @{ Field = 'OperationId'; Value = '' }, @{ Field = 'OperationId'; Value = [guid]::Empty.ToString() }, @{ Field = 'Mode'; Value = 'ForeignOwned' }, @{ Field = 'Phase'; Value = 'Finished' }, @{ Field = 'ExpectedSourceHash'; Value = ('A' * 63) })) {
    Assert-Case "candidate rejects invalid $($entry.Field)" {
        $script:Fixture.Record[$entry.Field] = $entry.Value
        Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'Invalid pending deployment'
    }
}
Assert-Case 'candidate rejects a changed hash' {
    $script:Fixture.Hash = ('C' * 64)
    Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'original expected hash'
}
Assert-Case 'candidate rejects missing/unreadable hash' {
    $script:Fixture.Hash = $null
    Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'original expected hash'
}
foreach ($path in @('C:\Temp\WinREWork\pending.wim', 'C:\ProgramData\OEM\WinRE-Manager\PendingDeployment\..\PendingDeployment\pending.wim', '\\server\share\pending.wim')) {
    Assert-Case "candidate rejects noncanonical path $path" {
        $script:Fixture.Record.CandidatePath = $path
        Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'trusted, fixed deployment file'
    }
}
Assert-Case 'candidate accepts case-insensitive canonical Windows path' {
    $script:Fixture.Record.CandidatePath = 'c:\PROGRAMDATA\OEM\winre-manager\PENDINGDEPLOYMENT\PENDING.WIM'
    Assert-DeploymentCandidate -Record $script:Fixture.Record
}
foreach ($path in @('C:\ProgramData\OEM\WinRE-Manager\PendingDeployment\pending.wim', 'C:\ProgramData\OEM\WinRE-Manager\PendingDeployment', 'C:\ProgramData\OEM')) {
    Assert-Case "candidate rejects reparse point at $path" {
        $script:Fixture.Attributes[$path] = [IO.FileAttributes]::ReparsePoint
        Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'trusted, fixed deployment file'
    }
}
foreach ($path in @($PendingDeploymentDir, (Join-Path $PendingDeploymentDir 'pending.wim'))) {
    Assert-Case "candidate rejects untrusted path $path" {
        $script:Fixture.Untrusted[$path] = $true
        Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'trusted, fixed deployment file'
    }
}
foreach ($entry in @(@{ Field = 'OSDiskId'; Value = 'other-disk' }, @{ Field = 'OSVolumeId'; Value = 'other-volume' }, @{ Field = 'OSPartitionOffset'; Value = [int64]2097152 })) {
    Assert-Case "candidate rejects mismatched $($entry.Field)" {
        $script:Fixture.Record[$entry.Field] = $entry.Value
        Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'different or indeterminate OS'
    }
}
Assert-Case 'candidate rejects indeterminate OS disk identity' {
    $script:Fixture.Disk = $null
    Assert-Throws { Assert-DeploymentCandidate -Record $script:Fixture.Record } 'different or indeterminate OS'
}

Assert-Case 'reading a valid journal arms preservation before returning it' {
    $record = Read-PendingDeployment
    Assert-True ($record.OperationId -eq $script:Fixture.Record.OperationId) 'Journal operation changed.'
    Assert-True ($script:PendingDeploymentPresent -and $script:ResumeTaskShouldPersist) 'A pending operation did not protect recovery material.'
}
Assert-Case 'missing journal returns null without inventing a pending operation' {
    $script:Fixture.Paths[$PendingDeploymentPath] = $false
    Assert-True ($null -eq (Read-PendingDeployment)) 'A missing journal should return null.'
}
Assert-Case 'journal probe failure retains the recovery task' {
    $script:Fixture.ProbeThrows = $true
    Assert-Throws { Read-PendingDeployment } 'ancestry is unsafe'
    Assert-True $script:ResumeTaskShouldPersist 'A journal probe error disarmed the recovery task.'
}
Assert-Case 'malformed journal JSON throws with preservation already armed' {
    $script:Fixture.Content = '{invalid-json'
    Assert-Throws { Read-PendingDeployment } ''
    Assert-True ($script:PendingDeploymentPresent -and $script:ResumeTaskShouldPersist) 'Malformed journal lost preservation flags.'
}
Assert-Case 'journal reparse ancestor throws with preservation already armed' {
    $script:Fixture.Attributes['C:\ProgramData\OEM'] = [IO.FileAttributes]::ReparsePoint
    Assert-Throws { Read-PendingDeployment } 'ancestry is unsafe'
    Assert-True $script:ResumeTaskShouldPersist 'Unsafe journal lost the recovery-task preservation flag.'
}
foreach ($path in @('C:\ProgramData\OEM', 'C:\ProgramData\OEM\WinRE-Manager', $PendingDeploymentPath)) {
    Assert-Case "journal refuses untrusted path $path" {
        $script:Fixture.Untrusted[$path] = $true
        Assert-Throws { Read-PendingDeployment } '*trust*'
        Assert-True $script:PendingDeploymentPresent 'Untrusted journal lost preservation flag.'
    }
}
Assert-Case 'journal write is atomically read back and candidate-validated' {
    Write-PendingDeployment -Record $script:Fixture.Record
    Assert-True ($null -ne $script:PendingDeployment -and $script:PendingDeployment.OperationId -eq $script:Fixture.Record.OperationId) 'Journal write was not committed in memory after readback.'
    Assert-True (@($script:Calls | Where-Object { $_ -eq 'Atomic-JournalWrite' }).Count -eq 1) 'Expected one atomic journal write.'
}
Assert-Case 'journal write detects stale phase from failed replacement' {
    $script:Fixture.DropWrite = $true
    $script:Fixture.Record.Phase = 'Copied'
    Assert-Throws { Write-PendingDeployment -Record $script:Fixture.Record } 'read-back verification failed'
}
Assert-Case 'journal readback rejects a preservation-to-ownership mode change' {
    $script:Fixture.JournalCorruptField = 'Mode'
    $script:Fixture.JournalCorruptValue = 'Managed'
    Assert-Throws { Write-PendingDeployment -Record $script:Fixture.Record } 'read-back'
}
Assert-Case 'DryRun journal write does not write or probe storage' {
    $script:DryRun = $true
    Write-PendingDeployment -Record $script:Fixture.Record
    Assert-True ($script:Calls.Count -eq 0) 'DryRun journal write invoked a provider.'
}

# Transition tests import the actual orchestration and completion bodies.
# The candidate-lock provider is mocked; no real candidate file is opened.
foreach ($name in @('Complete-PendingWinREDeployment', 'Invoke-PendingWinREDeployment', 'Start-WinREDeployment', 'Invoke-LastResortOSFallback')) {
    $definition = $source.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Required transition function missing: $name" }
    $text = $definition.Extent.Text
    . ([scriptblock]::Create($text))
}
$EXIT_SUCCESS = 0
$EXIT_REBOOT_REQUIRED = 1
$EXIT_WARNING = 2
$EXIT_FATAL = 3
$StateFileName = 'mock-winre-state.json'
$CheckpointFile = 'mock-checkpoint.json'

function Set-TransitionFixture {
    $script:Fixture.Active = $script:Fixture.OS
    $script:Fixture.Route = @{ Status = 'Enabled'; Location = 'mock-old-route' }
    $script:Fixture.RouteHash = ('B' * 64)
    $script:Fixture.TargetHash = $null
    $script:Fixture.Ready = $true
    $script:Fixture.CopyOK = $true
    $script:Fixture.DisableOK = $true
    $script:Fixture.RegisterOK = $true
    $script:Fixture.EnableResult = 'ok'
    $script:Fixture.OldRouteIntact = $true
    $script:Fixture.RestoreOK = $false
    $script:Fixture.StateWriteOK = $true
    $script:Fixture.StateReadOK = $true
    $script:Fixture.RetireOK = $true
    $script:Fixture.SourceUnchanged = $true
    $script:Fixture.FindTarget = $true
    $script:Fixture.CreateResult = $null
    $script:Fixture.CreateMutates = $false
    $script:Fixture.RouteAfterCreate = $null
    $script:Fixture.AttributesOK = $true
    $script:Fixture.GateOK = $true
    $script:Fixture.LKGOK = $true
    $script:Fixture.CopyCorrupt = $false
    $script:Fixture.Encrypted = $true
    $script:Fixture.OldImageReadable = $true
    $script:Fixture.FallbackCopyOK = $true
    $script:Fixture.FallbackHash = $null
    $script:Fixture.Recovery | Add-Member -NotePropertyName Guid -NotePropertyValue 'mock-target-guid' -Force
    $script:Fixture.Recovery | Add-Member -NotePropertyName Offset -NotePropertyValue ([int64](100GB)) -Force
}
function Open-DeploymentCandidateReadLock {
    param($Path)
    $script:Calls.Add('CandidateReadLock')
    $lock = [pscustomobject]@{}
    $lock | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:Calls.Add('ReleaseCandidateLock') }
    return $lock
}
function Get-WinREState { $script:Calls.Add('Get-WinREState'); return $script:Fixture.Route.Clone() }
function Test-WinRELocationMatches { param($LocationA, $LocationB) return ([string]$LocationA -eq [string]$LocationB) }
function Get-RegisteredDeploymentImage {
    param($WinREState)
    $script:Calls.Add('Get-RegisteredImage')
    if ($WinREState.Location -eq 'mock-osfallback-route') {
        if ($script:Fixture.FallbackHash) { return @{ Path = 'mock-osfallback.wim'; Hash = $script:Fixture.FallbackHash } }
        return $null
    }
    if ($WinREState.Location -like '*GLOBALROOT*' -or $WinREState.Location -eq 'mock-target-route') {
        if ($script:Fixture.TargetHash) { return @{ Path = 'mock-target.wim'; Hash = $script:Fixture.TargetHash } }
        return $null
    }
    if ($script:Fixture.OldImageReadable) { return @{ Path = 'mock-old.wim'; Hash = $script:Fixture.RouteHash } }
    return $null
}
function Test-PreservedCandidateApplicability {
    param($Record)
    $script:Calls.Add('ReadOnlyApplicabilityGate')
    if (-not $script:Fixture.GateOK) { throw 'mock applicability refused' }
}
function Get-RegisteredWinREFingerprint { param($WinREState, $RegisteredWimPath, $RegisteredWimHash) return @{ Captured = $true } }
function Assert-RegisteredWinREUnchanged { param($Captured, $CalledFrom) $script:Calls.Add('RecheckOriginalRoute'); return $script:Fixture.SourceUnchanged }
function Find-SuitableRecoveryPartition {
    param($RequiredWimSizeMB)
    $script:Calls.Add('FindTarget')
    if ($script:Fixture.FindTarget) { return @{ DiskNumber = 0; PartitionNumber = 4; DriveLetter = 'R'; Partition = $script:Fixture.Recovery } }
    return $null
}
function Ensure-AdequateRecoveryPartition {
    param($RequiredWimSizeMB, $ProtectedSourcePath, $ExpectedSourceHash, [switch]$PrepareBeforeDisable)
    $script:Calls.Add("CreateTarget:Protected=$ProtectedSourcePath,Hash=$ExpectedSourceHash,Prepare=$PrepareBeforeDisable")
    if ($script:Fixture.CreateMutates) {
        $script:PendingDeployment.Phase = 'MutationStarted'
        $script:Fixture.OldRouteIntact = $false
    }
    if ($script:Fixture.RouteAfterCreate) { $script:Fixture.Route = $script:Fixture.RouteAfterCreate.Clone() }
    return $script:Fixture.CreateResult
}
function Set-RecoveryPartitionReadyForWinRE { param($DiskNumber, $PartitionNumber) $script:Calls.Add('ReadyTarget'); return $script:Fixture.Ready }
function Deploy-WimToPartition {
    param($Partition, $SourceWim, $ExpectedSourceHash)
    $script:Calls.Add('CopyToTarget')
    if ($script:Fixture.CopyOK) { $script:Fixture.TargetHash = $ExpectedSourceHash }
    return $script:Fixture.CopyOK
}
function cmd {
    param($Switch, $Command)
    $global:LASTEXITCODE = 0
    if ($Command -like '*reagentc /disable*') {
        $script:Calls.Add('DisableOriginalRoute')
        if ($script:Fixture.DisableOK) { $script:Fixture.Route.Status = 'Disabled'; $script:Fixture.OldRouteIntact = $false }
        else { $global:LASTEXITCODE = 1 }
    } elseif ($Command -like '*reagentc /setreimage*') {
        $script:Calls.Add('RegisterTarget')
        if ($script:Fixture.RegisterOK) {
            if ($Command -like '*GLOBALROOT*') { $script:Fixture.Route.Location = 'mock-target-route'; $script:Fixture.RouteHash = $script:Fixture.TargetHash }
            else { $script:Fixture.Route.Location = 'mock-osfallback-route'; $script:Fixture.RouteHash = $script:Fixture.FallbackHash }
        }
        else { $global:LASTEXITCODE = 1 }
    } else { throw "Unexpected mocked native command: $Command" }
    return 'mock reagentc output'
}
function Invoke-ReagentcEnable {
    param([switch]$AllowTempLetter, $Partition, $ReRegisterPath)
    $script:Calls.Add('EnableTarget')
    if ($script:Fixture.EnableResult -eq 'ok') { $script:Fixture.Route.Status = 'Enabled' }
    return $script:Fixture.EnableResult
}
function Test-PreviousDeploymentRoute { param($Record) $script:Calls.Add('VerifyPreviousRoute'); return $script:Fixture.OldRouteIntact }
function Restore-PreviousWinRERoute {
    param($PreviousState)
    $script:Calls.Add('RestorePreviousRoute')
    if ($script:Fixture.RestoreOK) {
        $script:Fixture.Route = @{ Status = 'Enabled'; Location = 'mock-old-route' }
        $script:Fixture.RouteHash = ('B' * 64)
        $script:Fixture.OldRouteIntact = $true
    }
    return $script:Fixture.RestoreOK
}
function Set-RecoveryPartitionAttributes { param($DiskNumber, $PartitionNumber, $Style) $script:Calls.Add('VerifyTargetAttributes'); return $script:Fixture.AttributesOK }
function Write-WinREState {
    param([string]$Hash, $DriverVersion, $DesiredStateId, $PendingReboot, $UsedOSFallback, $RepairAttempts, $LastEnableResult, $EnableFailureAttempts,
        $DeployedDiskNumber, $DeployedPartitionNumber, $DeployedWinREMetadata, $LocalInputsId, [string]$ForeignSourceAcceptedHash, $LineageId)
    $script:Calls.Add('WriteState')
    if (-not $script:Fixture.StateWriteOK) { throw 'mock state persistence failed' }
    $state = @{ CurrentImageHash = $Hash; ForeignSourceAcceptedHash = $ForeignSourceAcceptedHash; DesiredStateId = $DesiredStateId;
        UsedOSFallback = $UsedOSFallback; PendingReboot = $PendingReboot; DeployedDiskNumber = $DeployedDiskNumber; DeployedPartitionNumber = $DeployedPartitionNumber }
    if (-not $script:Fixture.StateReadOK) { $state.CurrentImageHash = 'wrong-readback-hash' }
    $script:Fixture.SavedState = $state
    $script:Fixture.StateContent = $state | ConvertTo-Json
}
function Remove-Item {
    param($LiteralPath, [switch]$Force, $ErrorAction)
    if ($LiteralPath -ne $PendingDeploymentPath) { throw "Unexpected mocked removal: $LiteralPath" }
    $script:Calls.Add('RetireJournal')
    if (-not $script:Fixture.RetireOK) { throw 'mock journal retirement failed' }
    $script:Fixture.Paths[$LiteralPath] = $false
}
function Remove-ItemIfExist { param($Path) $script:Calls.Add("Cleanup:$Path"); $script:Fixture.Paths[$Path] = $false }
function Clear-PartitionDeferral { $script:Calls.Add('ClearDeferral') }
function Write-PartitionDeferral { param($DesiredStateId, $Reason, $Category) $script:Calls.Add("Deferral:$Category") }
function Read-PartitionDeferral { param($CurrentDesiredStateId) return $script:Fixture.Deferral }
function Set-RunSummaryField { param($Field, $Value) $script:Calls.Add("Summary:$Field=$Value") }
function Add-RunSummaryLine { param($Field, $Line) $script:Calls.Add("SummaryLine:$Field=$Line") }
function New-DirectoryIfNotExists { param($Path) $script:Calls.Add('EnsureDirectory') }
function Deploy-WimTransactional {
    param($SourceWim, $TargetPath, $TargetDescription, $ExpectedSourceHash)
    if ($TargetDescription -eq 'last-resort OS-fallback') {
        $script:Calls.Add('CopyToOSFallback')
        if ($script:Fixture.FallbackCopyOK) { $script:Fixture.FallbackHash = $ExpectedSourceHash }
        return $script:Fixture.FallbackCopyOK
    }
    $script:Calls.Add('RefreshManagedLKG')
    return $script:Fixture.LKGOK
}
function Sync-DeploymentCandidate { param($Path) $script:Calls.Add('FlushCandidateToDisk') }
function Remove-UnjournaledDeploymentCopy {
    $script:Calls.Add('DiscardUnjournaledCopy')
    if (-not $script:Fixture.Paths[$PendingDeploymentPath]) { $script:Fixture.Paths[$script:Fixture.Record.CandidatePath] = $false }
}
function Remove-CompletedServicingWorkspace { param($Path) $script:Calls.Add('PostCommitWorkspaceCleanup') }
function Remove-StrayRecoveryPartitions {
    param($OSDiskNumber)
    $script:Calls.Add('PostCommitStrayCleanup')
    if ($script:Fixture.ContainsKey('StrayCleanupOK')) { return $script:Fixture.StrayCleanupOK }
    return $true
}
function Test-VolumeEncrypted {
    param($MountPoint)
    $script:Calls.Add('CheckOSBitLocker')
    if ($MountPoint -eq $env:SystemDrive) { return $script:Fixture.Encrypted }
    return $script:Fixture.RecoveryEncrypted
}
function Copy-Item {
    param($LiteralPath, $Destination, $ErrorAction)
    $script:Calls.Add('StageIndependentCopy')
    $script:Fixture.Paths[$Destination] = $true
    if ($script:Fixture.CopyCorrupt) { $script:Fixture.PathHashes[$Destination] = ('D' * 64) }
}
function Get-WimServicingMetadata { param($WimPath) return @{ Version = '10.0.0.0'; SPBuild = 0 } }

function Assert-Retained {
    Assert-True ($script:PendingDeploymentPresent -and $script:ResumeTaskShouldPersist) 'Failure lost journal/task ownership.'
    Assert-True (-not @($script:Calls | Where-Object { $_ -eq "Cleanup:$($script:Fixture.Record.CandidatePath)" }).Count) 'Failure deleted its independent candidate.'
}

Assert-Case 'separate target is copied and verified before disabling original route' {
    Set-TransitionFixture
    $code = Invoke-PendingWinREDeployment -Record $script:Fixture.Record
    Assert-True ($code -eq $EXIT_SUCCESS) 'Dedicated deployment should succeed.'
    Assert-True ($script:Calls.IndexOf('CopyToTarget') -lt $script:Calls.IndexOf('DisableOriginalRoute')) 'Original route was disabled before target preparation.'
    Assert-True ($script:Calls.IndexOf('WriteState') -lt $script:Calls.IndexOf('RetireJournal')) 'Journal retired before state persistence.'
    Assert-True ($script:Calls.IndexOf('RetireJournal') -lt $script:Calls.IndexOf("Cleanup:$($script:Fixture.Record.CandidatePath)")) 'Candidate was released before journal retirement.'
    Assert-True ($script:Fixture.SavedState.CurrentImageHash -eq ('C' * 64) -and $script:Fixture.SavedState.ForeignSourceAcceptedHash -eq ('A' * 64)) 'Preserved WIM became manager-owned.'
    Assert-True (-not $script:ResumeTaskShouldPersist -and -not $script:PendingDeploymentPresent) 'Successful commit left pending ownership.'
    Assert-True (@($script:Calls | Where-Object { $_ -like 'SummaryLine:WorkPerformed=Copied and hash-verified*' }).Count -eq 1) 'A successful copy was missing from the work summary or reported twice.'
    Assert-True ($script:Calls.Contains('SummaryLine:WorkPerformed=Verified dedicated WinRE registration, image bytes, servicing capacity and saved state.')) 'Completed verification was omitted from the work summary.'
}
Assert-Case 'pending resume refuses to overwrite a newly registered different image' {
    Set-TransitionFixture
    $script:Fixture.RouteHash = ('D' * 64)
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Changed registered image must defer.'
    Assert-True (-not $script:Calls.Contains('FindTarget') -and -not $script:Calls.Contains('DisableOriginalRoute') -and -not $script:Calls.Contains('RestorePreviousRoute')) 'Changed registered source was mutated.'
    Assert-Retained
}
foreach ($mode in @('Managed','Preserved')) {
    Assert-Case "indeterminate WinRE status is fatal before $mode target preparation" {
        Set-TransitionFixture
        $script:Fixture.Record.Mode = $mode
        $script:Fixture.Route.Status = 'Unknown'
        Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'Unknown WinRE state must remain fatal.'
        Assert-True (-not $script:Calls.Contains('FindTarget') -and -not $script:Calls.Contains('ReadOnlyApplicabilityGate') -and -not $script:Calls.Contains('DisableOriginalRoute')) 'Unknown WinRE state reached target preparation.'
        Assert-Retained
    }
}
Assert-Case 'preserved expected hash is never retained as CurrentImageHash' {
    Set-TransitionFixture
    $script:Fixture.Record.PriorManagedHash = ('A' * 64)
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Preserved deployment should succeed.'
    Assert-True ([string]::IsNullOrEmpty($script:Fixture.SavedState.CurrentImageHash)) 'Ambiguous positive ownership was not cleared.'
}
Assert-Case 'preserved deployment with no prior manager hash commits an empty ownership field' {
    Set-TransitionFixture
    $script:Fixture.Record.PriorManagedHash = $null
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Preserved deployment without prior ownership should succeed.'
    Assert-True ([string]::IsNullOrEmpty($script:Fixture.SavedState.CurrentImageHash)) 'Foreign deployment manufactured ownership.'
}
Assert-Case 'managed deployment commits ownership and refreshes only its managed LKG' {
    Set-TransitionFixture
    $script:Fixture.Record.Mode = 'Managed'
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Managed deployment should succeed.'
    Assert-True ($script:Fixture.SavedState.CurrentImageHash -eq ('A' * 64) -and [string]::IsNullOrEmpty($script:Fixture.SavedState.ForeignSourceAcceptedHash)) 'Managed ownership state is wrong.'
    Assert-True ($script:Calls.Contains('RefreshManagedLKG') -and -not $script:Calls.Contains('ReadOnlyApplicabilityGate')) 'Current managed image used the wrong servicing/gate path.'
    Assert-True (@($script:Calls | Where-Object { $_ -like 'SummaryLine:WorkPerformed=Copied and hash-verified*' }).Count -eq 1) 'Managed copy-only deployment did not report its actual copy.'
}
Assert-Case 'failure copying unused target preserves original enabled route' {
    Set-TransitionFixture
    $script:Fixture.CopyOK = $false
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Intact original route should produce warning.'
    Assert-True (-not $script:Calls.Contains('DisableOriginalRoute') -and -not $script:Calls.Contains('RegisterTarget')) 'Copy failure switched the active route.'
    Assert-True (-not @($script:Calls | Where-Object { $_ -like 'SummaryLine:WorkPerformed=*' }).Count) 'Failed copy reported work as completed.'
    Assert-Retained
}
Assert-Case 'applicability refusal makes no target mutation or route switch' {
    Set-TransitionFixture
    $script:Fixture.GateOK = $false
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Preflight refusal should warn.'
    Assert-True (-not $script:Calls.Contains('FindTarget') -and -not $script:Calls.Contains('DisableOriginalRoute')) 'Applicability refusal continued into deployment.'
    Assert-Retained
}
Assert-Case 'registration failure with unrecoverable prior route is fatal and retained' {
    Set-TransitionFixture
    $script:Fixture.RegisterOK = $false
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'Lost route must be fatal.'
    Assert-True $script:Calls.Contains('RestorePreviousRoute') 'Prior route restoration was not attempted.'
    Assert-Retained
}
Assert-Case 'registration failure with verified restored prior route warns and retains' {
    Set-TransitionFixture
    $script:Fixture.RegisterOK = $false
    $script:Fixture.RestoreOK = $true
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Verified restored route should warn.'
    Assert-Retained
}
Assert-Case 'enable requiring reboot retains journal and candidate' {
    Set-TransitionFixture
    $script:Fixture.EnableResult = 'reboot'
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_REBOOT_REQUIRED) 'Reboot result was lost.'
    Assert-Retained
}
foreach ($failure in @('StateWriteOK', 'StateReadOK', 'RetireOK')) {
    Assert-Case "$failure failure retains verified new route without rollback" {
        Set-TransitionFixture
        $script:Fixture[$failure] = $false
        Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'Commit persistence failure must be fatal.'
        Assert-True ($script:Fixture.Route.Status -eq 'Enabled' -and $script:Fixture.Route.Location -eq 'mock-target-route') 'A good route was undone after persistence failure.'
        Assert-True (-not $script:Calls.Contains('RestorePreviousRoute')) 'Persistence failure attempted to undo a good route.'
        Assert-Retained
    }
}
Assert-Case 'interrupted post-enable deployment commits without another disable/copy cycle' {
    Set-TransitionFixture
    $script:Fixture.Route = @{ Status = 'Enabled'; Location = 'mock-target-route' }
    $script:Fixture.TargetHash = ('A' * 64)
    $script:Fixture.Record.Phase = 'Registered'
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Interrupted enabled deployment did not commit.'
    Assert-True (-not $script:Calls.Contains('DisableOriginalRoute') -and -not $script:Calls.Contains('CopyToTarget')) 'Resume repeated a completed route switch.'
    Assert-True (-not @($script:Calls | Where-Object { $_ -like 'SummaryLine:WorkPerformed=Copied*' }).Count) 'Commit recovery falsely reported another image copy.'
    Assert-True ($script:Calls.Contains('SummaryLine:WorkPerformed=Verified dedicated WinRE registration, image bytes, servicing capacity and saved state.')) 'Commit recovery omitted its verification work.'
}
Assert-Case 'capacity deferral retains candidate without disabling route or falling back' {
    Set-TransitionFixture
    $script:Fixture.FindTarget = $false
    $script:Fixture.CreateResult = @{ Status = 'Deferred'; Reason = 'post-shrink free space below minimum (mock)'; RetrySuppressible = $true }
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Capacity deferral should warn.'
    Assert-True ($script:Calls.Contains('Deferral:Capacity') -and -not $script:Calls.Contains('DisableOriginalRoute')) 'Capacity refusal switched the route.'
    Assert-Retained
}
Assert-Case 'creation failure after mutation cannot be reported as an untouched preflight refusal' {
    Set-TransitionFixture
    $script:Fixture.FindTarget = $false
    $script:Fixture.CreateMutates = $true
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'Mutated, unverified route should be fatal.'
    Assert-Retained
}
Assert-Case 'target that is already active is disabled before replacing its bytes' {
    Set-TransitionFixture
    $script:Fixture.Active = $script:Fixture.Recovery
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Active-target deployment should succeed.'
    Assert-True ($script:Calls.IndexOf('DisableOriginalRoute') -lt $script:Calls.IndexOf('CopyToTarget')) 'Active WIM was replaced before disabling its route.'
}
Assert-Case 'source drift after target preparation refuses original route switch' {
    Set-TransitionFixture
    $script:Fixture.SourceUnchanged = $false
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Intact drifted original route should warn.'
    Assert-True (-not $script:Calls.Contains('DisableOriginalRoute')) 'Changed source was disabled.'
    Assert-Retained
}
Assert-Case 'Start stages independent bytes and commits durable journal before target work' {
    Set-TransitionFixture
    $script:Fixture.Paths[$PendingDeploymentPath] = $false
    $script:Fixture.Paths[$script:Fixture.Record.CandidatePath] = $false
    $code = Start-WinREDeployment -SourceWim 'mock-original.wim' -Mode Preserved -ExpectedSourceHash ('A' * 64) -DesiredStateId 'test-dsi' -PriorState @{ CurrentImageHash = ('C' * 64) }
    Assert-True ($code -eq $EXIT_SUCCESS) 'Start/deploy pipeline should succeed.'
    Assert-True ($script:Calls.IndexOf('StageIndependentCopy') -lt $script:Calls.IndexOf('Atomic-JournalWrite')) 'Journal preceded independent source copy.'
    Assert-True ($script:Calls.IndexOf('StageIndependentCopy') -lt $script:Calls.IndexOf('FlushCandidateToDisk') -and $script:Calls.IndexOf('FlushCandidateToDisk') -lt $script:Calls.IndexOf('Atomic-JournalWrite')) 'Candidate was not durably flushed before journal commit.'
    Assert-True ($script:Calls.IndexOf('Atomic-JournalWrite') -lt $script:Calls.IndexOf('FindTarget')) 'Target work began without a verified durable journal.'
}
Assert-Case 'backoff cannot downgrade a previously lost active route to warning' {
    Set-TransitionFixture
    $script:Fixture.Record.Phase = 'MutationStarted'
    $script:Fixture.Route.Status = 'Disabled'
    $script:Fixture.OldRouteIntact = $false
    $script:Fixture.Deferral = @{ Category = 'Execution'; RetryAfterUtc = [DateTime]::UtcNow.AddMinutes(30).ToString('o'); Reason = 'mock post-deletion failure' }
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'Backoff hid the unresolved route loss.'
    Assert-True (-not $script:Calls.Contains('FindTarget') -and -not $script:Calls.Contains('DisableOriginalRoute')) 'Backoff still performed expensive target work.'
    Assert-Retained
}
Assert-Case 'fresh capacity refusal cannot downgrade an unresolved prior route loss' {
    Set-TransitionFixture
    $script:Fixture.Record.Phase = 'MutationStarted'
    $script:Fixture.Route.Status = 'Disabled'
    $script:Fixture.OldRouteIntact = $false
    $script:Fixture.FindTarget = $false
    $script:Fixture.CreateResult = @{ Status = 'Deferred'; Reason = 'mock changed geometry'; RetrySuppressible = $false }
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'Fresh preflight refusal hid a prior route loss.'
    Assert-Retained
}
Assert-Case 'future execution retry backoff avoids expensive target work' {
    Set-TransitionFixture
    $script:Fixture.Deferral = @{ Category = 'Execution'; RetryAfterUtc = [DateTime]::UtcNow.AddHours(1).ToString('o'); Reason = 'mock transient failure' }
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Execution backoff should warn.'
    Assert-True (-not $script:Calls.Contains('FindTarget') -and -not $script:Calls.Contains('DisableOriginalRoute')) 'Backoff repeated target work.'
    Assert-Retained
}
Assert-Case 'expired execution retry permits a new verified attempt' {
    Set-TransitionFixture
    $script:Fixture.Deferral = @{ Category = 'Execution'; RetryAfterUtc = [DateTime]::UtcNow.AddHours(-1).ToString('o'); Reason = 'mock expired failure' }
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Expired backoff prevented retry.'
    Assert-True $script:Calls.Contains('FindTarget') 'Expired execution failure was never retried.'
}
Assert-Case 'capacity marker never supplies execution backoff' {
    Set-TransitionFixture
    $script:Fixture.Deferral = @{ Category = 'Capacity'; RetryAfterUtc = [DateTime]::UtcNow.AddHours(1).ToString('o'); Reason = 'mock prior capacity refusal' }
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Capacity marker suppressed actual capacity reassessment.'
}
Assert-Case 'Start refuses changed original bytes before copying or writing journal' {
    Set-TransitionFixture
    $script:Fixture.Paths[$PendingDeploymentPath] = $false
    $script:Fixture.Hash = ('D' * 64)
    Assert-Throws { Start-WinREDeployment -SourceWim 'mock-original.wim' -Mode Preserved -ExpectedSourceHash ('A' * 64) -DesiredStateId 'test-dsi' } 'Original deployment source hash'
    Assert-True (-not $script:Calls.Contains('StageIndependentCopy') -and -not $script:Calls.Contains('Atomic-JournalWrite')) 'Changed original bytes were staged/committed.'
}
Assert-Case 'Start refuses corrupted independent copy before journal or partition work' {
    Set-TransitionFixture
    $script:Fixture.Paths[$PendingDeploymentPath] = $false
    $script:Fixture.Paths[$script:Fixture.Record.CandidatePath] = $false
    $script:Fixture.CopyCorrupt = $true
    Assert-Throws { Start-WinREDeployment -SourceWim 'mock-original.wim' -Mode Preserved -ExpectedSourceHash ('A' * 64) -DesiredStateId 'test-dsi' } 'Independent candidate copy failed'
    Assert-True (-not $script:Calls.Contains('Atomic-JournalWrite') -and -not $script:Calls.Contains('FindTarget')) 'A corrupt independent copy reached partition work.'
}
Assert-Case 'Start warns without copying when protected staging lacks capacity' {
    Set-TransitionFixture
    $script:Fixture.Paths[$PendingDeploymentPath] = $false
    $script:Fixture.Paths[$script:Fixture.Record.CandidatePath] = $false
    $script:Fixture.OSVolume.SizeRemaining = [int64](931MB)
    Assert-True ((Start-WinREDeployment -SourceWim 'mock-original.wim' -Mode Preserved -ExpectedSourceHash ('A' * 64) -DesiredStateId 'test-dsi') -eq $EXIT_WARNING) 'Insufficient protected staging capacity should defer.'
    Assert-True (-not $script:Calls.Contains('StageIndependentCopy') -and -not $script:Calls.Contains('FindTarget')) 'Staging refusal continued into deployment.'
}
Assert-Case 'Start refuses to overwrite an existing pending owner' {
    Set-TransitionFixture
    Assert-Throws { Start-WinREDeployment -SourceWim 'mock-original.wim' -Mode Preserved -ExpectedSourceHash ('A' * 64) -DesiredStateId 'test-dsi' } 'pending deployment already owns'
    Assert-True (-not $script:Calls.Contains('StageIndependentCopy') -and -not $script:Calls.Contains('Atomic-JournalWrite')) 'Existing pending operation was overwritten.'
}
Assert-Case 'Start adopts only an already matching protected orphan candidate' {
    Set-TransitionFixture
    $script:Fixture.Paths[$PendingDeploymentPath] = $false
    Assert-True ((Start-WinREDeployment -SourceWim 'mock-original.wim' -Mode Preserved -ExpectedSourceHash ('A' * 64) -DesiredStateId 'test-dsi') -eq $EXIT_SUCCESS) 'Matching protected orphan should be recoverable.'
    Assert-True (-not $script:Calls.Contains('StageIndependentCopy')) 'Existing matching protected candidate was unnecessarily overwritten.'
}
Assert-Case 'Start DryRun has no provider effects' {
    $script:DryRun = $true
    Assert-True ((Start-WinREDeployment -SourceWim 'mock-original.wim' -Mode Preserved -ExpectedSourceHash ('A' * 64) -DesiredStateId 'test-dsi') -eq $EXIT_SUCCESS) 'DryRun Start should succeed.'
    Assert-True (@($script:Calls | Where-Object { $_ -notmatch '^(Log:|Summary:)' }).Count -eq 0) 'DryRun invoked a storage provider.'
}

function Set-FallbackFixture {
    Set-TransitionFixture
    $script:Fixture.Encrypted = $false
    $script:Fixture.OldRouteIntact = $false
    $script:Fixture.OldImageReadable = $false
    $script:Fixture.Route.Status = 'Disabled'
    $script:PendingDeploymentPresent = $true
    $script:ResumeTaskShouldPersist = $true
    $script:PendingDeployment = $script:Fixture.Record
}
foreach ($entry in @(@{ Label = 'encrypted'; Value = $true }, @{ Label = 'indeterminate'; Value = $null })) {
    Assert-Case "last-resort fallback refuses $($entry.Label) OS BitLocker state" {
        Set-FallbackFixture
        $script:Fixture.Encrypted = $entry.Value
        Assert-True (-not (Invoke-LastResortOSFallback -Record $script:Fixture.Record)) 'Fallback accepted an encrypted/unknown OS volume.'
        Assert-True (-not $script:Calls.Contains('CopyToOSFallback') -and -not $script:Calls.Contains('Atomic-JournalWrite')) 'Refused fallback mutated recovery data.'
        Assert-Retained
    }
}
Assert-Case 'last-resort fallback refuses unverified geometry restoration' {
    Set-FallbackFixture
    $script:GeometryRestoreFailed = $true
    Assert-True (-not (Invoke-LastResortOSFallback -Record $script:Fixture.Record)) 'Fallback ignored unverified geometry.'
    Assert-True (-not $script:Calls.Contains('CopyToOSFallback')) 'Geometry refusal still copied fallback bytes.'
}
Assert-Case 'last-resort fallback retains an intact previous enabled route' {
    Set-FallbackFixture
    $script:Fixture.OldRouteIntact = $true
    Assert-True (-not (Invoke-LastResortOSFallback -Record $script:Fixture.Record)) 'An intact previous route was replaced.'
    Assert-True (-not $script:Calls.Contains('CopyToOSFallback')) 'Intact route refusal still copied fallback bytes.'
}
Assert-Case 'last-resort fallback retains any current enabled readable route' {
    Set-FallbackFixture
    $script:Fixture.Route.Status = 'Enabled'
    $script:Fixture.OldImageReadable = $true
    Assert-True (-not (Invoke-LastResortOSFallback -Record $script:Fixture.Record)) 'A readable enabled route was unnecessarily replaced.'
    Assert-True (-not $script:Calls.Contains('DisableOriginalRoute')) 'Readable enabled route was disabled.'
}
Assert-Case 'last-resort fallback refuses indeterminate WinRE status' {
    Set-FallbackFixture
    $script:Fixture.Route.Status = 'Unknown'
    Assert-True (-not (Invoke-LastResortOSFallback -Record $script:Fixture.Record)) 'Unknown status reached fallback.'
}
foreach ($location in @($null, 'mock-unresolvable-route')) {
    $routeLabel = if ($null -eq $location) { 'blank' } else { 'unsupported' }
    Assert-Case "last-resort fallback refuses an Enabled $routeLabel route before mutation" {
        Set-FallbackFixture
        $script:Fixture.Route.Status = 'Enabled'
        $script:Fixture.Route.Location = $location
        Assert-True (-not (Invoke-LastResortOSFallback -Record $script:Fixture.Record)) 'Unresolved Enabled route reached fallback.'
        Assert-True (-not $script:Calls.Contains('Atomic-JournalWrite') -and -not $script:Calls.Contains('DisableOriginalRoute') -and
            -not $script:Calls.Contains('CopyToOSFallback')) 'Unresolved Enabled route reached journal mutation, disable or WIM copying.'
        Assert-Retained
    }
    Assert-Case "orchestration refuses an Enabled $routeLabel route appearing after failed creation" {
        Set-FallbackFixture
        $script:Fixture.Record.Mode = 'Managed'
        $script:Fixture.Route.Status = 'Enabled'
        $script:Fixture.FindTarget = $false
        $script:Fixture.CreateMutates = $true
        $script:Fixture.RouteAfterCreate = @{ Status = 'Enabled'; Location = $location }
        Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'An unresolved post-mutation route was not fatal.'
        Assert-True (@($script:Calls | Where-Object { $_ -like 'CreateTarget:*' }).Count -eq 1) 'The after-creation route-change fixture did not exercise actual orchestration.'
        Assert-True ($script:Fixture.Record.Phase -eq 'MutationStarted' -and -not $script:Calls.Contains('DisableOriginalRoute') -and
            -not $script:Calls.Contains('CopyToOSFallback') -and -not $script:Calls.Contains('CopyToTarget')) 'Creation failure continued into unresolved-route deployment.'
        Assert-Retained
    }
}
Assert-Case 'last-resort fallback can repair an Enabled known partition with an unreadable WIM' {
    Set-FallbackFixture
    $script:Fixture.Route.Status = 'Enabled'
    Assert-True (Invoke-LastResortOSFallback -Record $script:Fixture.Record) 'A known active partition with an unreadable WIM could not use last-resort recovery.'
    Assert-True ($script:Calls.Contains('DisableOriginalRoute') -and $script:Calls.Contains('CopyToOSFallback') -and
        $script:Fixture.Route.Location -eq 'mock-osfallback-route') 'Known-partition fallback did not complete the verified route switch.'
    Assert-Retained
}
Assert-Case 'verified preserved fallback remains degraded and retains independent recovery material' {
    Set-FallbackFixture
    Assert-True (Invoke-LastResortOSFallback -Record $script:Fixture.Record) 'Fully decrypted last-resort fallback should verify.'
    Assert-True ($script:Fixture.SavedState.UsedOSFallback -and $script:Fixture.SavedState.CurrentImageHash -eq ('C' * 64) -and $script:Fixture.SavedState.ForeignSourceAcceptedHash -eq ('A' * 64)) 'Fallback state lost layout or ownership distinction.'
    Assert-True ($script:Fixture.Route.Status -eq 'Enabled' -and $script:Fixture.Route.Location -eq 'mock-osfallback-route') 'Fallback route did not verify.'
    Assert-True ($script:Calls.Contains('Summary:OperatingMode=OS-FALLBACK') -and $script:Calls.Contains('Deferral:Execution')) 'Fallback was reported as converged dedicated recovery.'
    Assert-Retained
}
Assert-Case 'preserved fallback clears a prior hash equal to its foreign bytes' {
    Set-FallbackFixture
    $script:Fixture.Record.PriorManagedHash = ('A' * 64)
    Assert-True (Invoke-LastResortOSFallback -Record $script:Fixture.Record) 'Preserved fallback should verify.'
    Assert-True ([string]::IsNullOrEmpty($script:Fixture.SavedState.CurrentImageHash)) 'Foreign fallback bytes became positively manager-owned.'
}
Assert-Case 'managed fallback preserves managed ownership without foreign acceptance' {
    Set-FallbackFixture
    $script:Fixture.Record.Mode = 'Managed'
    Assert-True (Invoke-LastResortOSFallback -Record $script:Fixture.Record) 'Managed fallback should verify.'
    Assert-True ($script:Fixture.SavedState.CurrentImageHash -eq ('A' * 64) -and [string]::IsNullOrEmpty($script:Fixture.SavedState.ForeignSourceAcceptedHash)) 'Managed fallback ownership was misclassified.'
}
foreach ($failure in @('StateWriteOK', 'StateReadOK')) {
    Assert-Case "fallback $failure failure retains verified route and material" {
        Set-FallbackFixture
        $script:Fixture[$failure] = $false
        Assert-Throws { Invoke-LastResortOSFallback -Record $script:Fixture.Record } '*state*'
        Assert-True ($script:Fixture.Route.Status -eq 'Enabled' -and $script:Fixture.Route.Location -eq 'mock-osfallback-route') 'Fallback persistence failure destroyed a verified route.'
        Assert-Retained
    }
}
Assert-Case 'fallback copy failure cannot register or enable unverified bytes' {
    Set-FallbackFixture
    $script:Fixture.FallbackCopyOK = $false
    Assert-Throws { Invoke-LastResortOSFallback -Record $script:Fixture.Record } 'Last-resort WIM copy failed'
    Assert-True (-not $script:Calls.Contains('RegisterTarget') -and -not $script:Calls.Contains('EnableTarget')) 'Failed fallback copy still switched registration.'
    Assert-Retained
}
Assert-Case 'orchestration keeps verified fallback after fallback state failure' {
    Set-FallbackFixture
    $script:Fixture.FindTarget = $false
    $script:Fixture.CreateMutates = $true
    $script:Fixture.StateWriteOK = $false
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_FATAL) 'Fallback persistence failure must be fatal.'
    Assert-True ($script:Fixture.Route.Status -eq 'Enabled' -and $script:Fixture.Route.Location -eq 'mock-osfallback-route') 'Parent failure handling lost verified fallback.'
    Assert-True (-not $script:Calls.Contains('RestorePreviousRoute')) 'Parent failure handling attempted to undo verified fallback.'
    Assert-Retained
}
Assert-Case 'post-commit stray cleanup warning does not undo verified deployment' {
    Set-TransitionFixture
    $script:Fixture.StrayCleanupOK = $false
    Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'Post-commit cleanup failure should warn.'
    Assert-True ($script:Fixture.Route.Status -eq 'Enabled' -and -not $script:PendingDeploymentPresent -and -not $script:Calls.Contains('RestorePreviousRoute')) 'Post-commit cleanup warning affected the committed route.'
}

# Evaluate the actual main-flow predicates, without running their bodies.
# Ownership alone must not bypass layout or observed registration status.
$fastAssignment = $source.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'nothingToDo' }, $true)
$enableAssignment = $source.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'needEnableOnly' }, $true)
if (-not $fastAssignment -or -not $enableAssignment) { throw 'Main-flow predicates missing.' }
$fastPredicate = [scriptblock]::Create($fastAssignment.Right.Extent.Text)
$enablePredicate = [scriptblock]::Create($enableAssignment.Right.Extent.Text)
foreach ($case in @(
    @{Name='current managed adequate dedicated';Foreign=$false;Status='Enabled';Suitable=$true;Recovery=$true;Inject=$false;Fast=$true;Enable=$false},
    @{Name='accepted foreign adequate dedicated';Foreign=$true;Status='Enabled';Suitable=$true;Recovery=$true;Inject=$false;Fast=$true;Enable=$false},
    @{Name='accepted foreign OS-fallback';Foreign=$true;Status='Enabled';Suitable=$false;Recovery=$false;Inject=$false;Fast=$false;Enable=$false},
    @{Name='accepted foreign undersized dedicated';Foreign=$true;Status='Enabled';Suitable=$false;Recovery=$true;Inject=$false;Fast=$false;Enable=$false},
    @{Name='current managed OS-fallback';Foreign=$false;Status='Enabled';Suitable=$false;Recovery=$false;Inject=$false;Fast=$false;Enable=$false},
    @{Name='disabled adequate foreign dedicated';Foreign=$true;Status='Disabled';Suitable=$true;Recovery=$true;Inject=$false;Fast=$false;Enable=$true},
    @{Name='indeterminate adequate dedicated';Foreign=$true;Status='Unknown';Suitable=$true;Recovery=$true;Inject=$false;Fast=$false;Enable=$false},
    @{Name='dedicated image needing servicing';Foreign=$false;Status='Enabled';Suitable=$true;Recovery=$true;Inject=$true;Fast=$false;Enable=$false}
)) {
    Assert-Case "main predicates: $($case.Name)" {
        $script:ForeignSourceAccepted=$case.Foreign
        $WinREState=@{Status=$case.Status}; $layoutAssessment=@{Suitable=$case.Suitable}
        $activeOnRecovery=$case.Recovery; $needInject=$case.Inject
        Assert-True ((& $fastPredicate) -eq $case.Fast) 'Fast path bypassed a required condition.'
        Assert-True ((& $enablePredicate) -eq $case.Enable) 'Enable-only path bypassed a required condition.'
    }
}

function Test-ForeignFallthroughModeBinding {
    param($Ast)
    $assignment = $Ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'deploymentMode' }, $true)
    if (-not $assignment) { return $false }
    $branch = $assignment.Right.Find({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] }, $true)
    if (-not $branch -or $branch.Clauses.Count -ne 1 -or -not $branch.ElseClause) { return $false }
    $conditionVariables = @($branch.Clauses[0].Item1.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    $preserved = @($branch.Clauses[0].Item2.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
    $managed = @($branch.ElseClause.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
    if ($conditionVariables.Count -ne 1 -or $conditionVariables[0].VariablePath.UserPath -ne 'Script:ForeignSourceAccepted' -or
        $preserved.Count -ne 1 -or $preserved[0].Value -ne 'Preserved' -or $managed.Count -ne 1 -or $managed[0].Value -ne 'Managed') { return $false }
    $call = $Ast.Find({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst] -or $node.GetCommandName() -ne 'Start-WinREDeployment') { return $false }
        for ($i = 1; $i -lt ($node.CommandElements.Count - 1); $i++) {
            if ($node.CommandElements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $node.CommandElements[$i].ParameterName -eq 'Mode' -and
                $node.CommandElements[$i + 1] -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.CommandElements[$i + 1].VariablePath.UserPath -eq 'deploymentMode') { return $true }
        }
        return $false
    }, $true)
    return ($null -ne $call)
}
Assert-Case 'accepted-foreign common deployment fallthrough passes Preserved mode to Start' {
    Assert-True (Test-ForeignFallthroughModeBinding -Ast $source) 'Accepted foreign enable-only fallthrough could enter managed deployment.'
}
Assert-Case 'foreign fallthrough binding rejects hardcoded managed mode despite comments' {
    $assignment = $source.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'deploymentMode' }, $true)
    $mutated = $source.Extent.Text.Replace($assignment.Extent.Text, '$deploymentMode = ''Managed'' <# if ($Script:ForeignSourceAccepted) { ''Preserved'' } #>')
    $mutantTokens = $null
    $mutantErrors = $null
    $mutant = [System.Management.Automation.Language.Parser]::ParseInput($mutated, [ref]$mutantTokens, [ref]$mutantErrors)
    Assert-True ($mutantErrors.Count -eq 0 -and -not (Test-ForeignFallthroughModeBinding -Ast $mutant)) 'Comment-only preservation satisfied the ownership trap regression.'
}

$definition = $source.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PreservedCandidateApplicability' }, $true)
if (-not $definition) { throw 'Preservation applicability helper is missing.' }
. ([scriptblock]::Create($definition.Extent.Text))
function Get-WindowsImage {
    param([switch]$Mounted, $ErrorAction)
    if (-not $Mounted) { throw 'Unexpected mocked image query.' }
    return $script:Fixture.MountedImages
}
function Mount-WindowsImage {
    param($ImagePath, $Index, $Path, [switch]$ReadOnly, $ErrorAction)
    if (-not $ReadOnly -or $Index -ne 1) { throw 'Preservation tried to mount writable bytes or a different image index.' }
    $script:Calls.Add('MountPreservedReadOnly')
    $script:Fixture.MountedImages = @([pscustomobject]@{ Path = $Path; ImagePath = $ImagePath; ImageIndex = $Index })
}
function Dismount-WindowsImage {
    param($Path, [switch]$Discard, $ErrorAction)
    if (-not $Discard) { throw 'Preservation tried to save image changes.' }
    $script:Calls.Add('DiscardPreservedMount')
    $script:Fixture.MountedImages = @()
    if ($script:Fixture.TamperAfterDiscard) { $script:Fixture.PathHashes[$script:Fixture.Record.CandidatePath] = ('D' * 64) }
}
function Test-StorageDriverApplicability {
    param($MountDir)
    if ($script:Fixture.ReplaceMountedWithUnrelated) {
        $script:Fixture.MountedImages = @([pscustomobject]@{ Path=$MountDir; ImagePath='unrelated-image.wim'; ImageIndex=1 })
    }
    return @{ Applicable = $script:Fixture.Applicable; Reason = 'mock storage verdict' }
}

Assert-Case 'preserved applicability mounts read-only and always discards' {
    $script:Fixture.Applicable = $true
    Test-PreservedCandidateApplicability -Record $script:Fixture.Record
    Assert-True ($script:Calls.Contains('MountPreservedReadOnly') -and $script:Calls.Contains('DiscardPreservedMount')) 'Preservation omitted read-only mount or discard.'
    Assert-True (@($script:Calls | Where-Object { $_ -like 'Get-Hash:*' }).Count -eq 2) 'Preservation did not verify original expected bytes before and after its mount.'
}
Assert-Case 'preserved applicability refusal still discards without saving' {
    $script:Fixture.Applicable = $false
    Assert-Throws { Test-PreservedCandidateApplicability -Record $script:Fixture.Record } 'storage applicability refused'
    Assert-True ($script:Calls.Contains('DiscardPreservedMount') -and @($script:Fixture.MountedImages).Count -eq 0) 'Refused preservation left its image mounted.'
}
Assert-Case 'matching interrupted preservation mount is discarded before a fresh read-only check' {
    $script:Fixture.Applicable = $true
    $script:Fixture.MountedImages = @([pscustomobject]@{ Path = (Join-Path $PendingDeploymentDir 'preserve_mount'); ImagePath = $script:Fixture.Record.CandidatePath; ImageIndex = 1 })
    Test-PreservedCandidateApplicability -Record $script:Fixture.Record
    Assert-True ($script:Calls.IndexOf('DiscardPreservedMount') -lt $script:Calls.IndexOf('MountPreservedReadOnly')) 'Interrupted mount was not discarded before verification.'
    Assert-True (@($script:Calls | Where-Object { $_ -eq 'DiscardPreservedMount' }).Count -eq 2) 'Both old and fresh mounts were not discarded.'
}
Assert-Case 'unrelated image at preservation mount is left untouched and refused' {
    $script:Fixture.MountedImages = @([pscustomobject]@{ Path = (Join-Path $PendingDeploymentDir 'preserve_mount'); ImagePath = 'unrelated-image.wim'; ImageIndex = 1 })
    Assert-Throws { Test-PreservedCandidateApplicability -Record $script:Fixture.Record } 'unrelated mounted image'
    Assert-True (-not $script:Calls.Contains('MountPreservedReadOnly') -and -not $script:Calls.Contains('DiscardPreservedMount')) 'An unrelated mounted image was changed.'
}
Assert-Case 'preservation rejects any post-mount change to expected candidate bytes' {
    $script:Fixture.Applicable = $true
    $script:Fixture.TamperAfterDiscard = $true
    Assert-Throws { Test-PreservedCandidateApplicability -Record $script:Fixture.Record } 'original expected hash'
}
Assert-Case 'preservation cleanup leaves an unrelated replacement mount untouched' {
    $script:Fixture.Applicable = $true
    $script:Fixture.ReplaceMountedWithUnrelated = $true
    Assert-Throws { Test-PreservedCandidateApplicability -Record $script:Fixture.Record } 'unrelated image appeared'
    Assert-True (-not $script:Calls.Contains('DiscardPreservedMount')) 'Cleanup discarded an unrelated replacement image.'
}

# Use the real selector with the real pending-deployment orchestration.
# A failed inventory must bypass Ensure-AdequateRecoveryPartition entirely;
# its independent geometry preflight is not a reason to replace a target
# that could have been reused if enumeration had succeeded.
$definition = $source.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-SuitableRecoveryPartition' }, $true)
. ([scriptblock]::Create($definition.Extent.Text))
foreach ($failure in @('NonTerminating', 'Terminating', 'Partial')) {
    Assert-Case "pending deployment retains the old route without replacement after $failure inventory failure" {
        Set-TransitionFixture
        $script:Fixture.Record.Mode = 'Managed'
        $script:Fixture.EnumerationFailure = $failure
        Assert-True ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_WARNING) 'An intact original route should produce a retained warning.'
        Assert-True (-not @($script:Calls | Where-Object { $_ -like 'CreateTarget:*' }).Count) 'A failed inventory triggered partition creation/replacement.'
        Assert-True (-not $script:Calls.Contains('ReadyTarget') -and -not $script:Calls.Contains('CopyToTarget') -and
            -not $script:Calls.Contains('DisableOriginalRoute') -and -not $script:Calls.Contains('RegisterTarget')) 'An inventory failure reached target or route mutation.'
        Assert-True ($script:Fixture.Record.Phase -eq 'Prepared' -and $script:Fixture.Route.Status -eq 'Enabled' -and
            $script:Fixture.Route.Location -eq 'mock-old-route') 'Inventory failure changed the pending phase or original route.'
        Assert-Retained
    }
}

Write-Output "Deployment safety regression tests: $script:Passed passed, 0 failed. All storage/WinRE/WIM/journal providers mocked."
