<#
.SYNOPSIS
    Isolated sequencing checks for the production partition preparation helper.
.DESCRIPTION
    Extracts Ensure-AdequateRecoveryPartition without running production main.
    All geometry, storage, native-tool, WinRE and journal providers are mocked.
    No real partition, filesystem, registration or encryption changes execute.
    These checks do not replace disposable-machine failure and boot testing.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$productionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\WinRE.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($productionPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Production parse failed.' }
$definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Ensure-AdequateRecoveryPartition' }, $true)
if (-not $definition) { throw 'Production helper missing.' }
. ([scriptblock]::Create($definition.Extent.Text))

$WinREFreeSpaceMiB = 250
$NewPartitionFilesystemMiB = 30
$NewPartitionIncrementMiB = 100
$NewPartitionMinimumMiB = 1000
$MaxManagedRecoveryPartitionMiB = 2048
$MinFreeSpaceGB = 3
$script:Passed = 0
function Reset-Fixture {
    $script:Calls = [Collections.Generic.List[string]]::new()
    $os = [pscustomobject]@{ DiskNumber=0; PartitionNumber=3; Offset=[int64]1MB; Size=[int64]230GB; Guid='os-guid'; DriveLetter='C' }
    $recovery = [pscustomobject]@{ DiskNumber=0; PartitionNumber=4; Offset=($os.Offset+$os.Size); Size=[int64]1000MB; Guid='old-recovery'; GptType='{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'; MbrType=0 }
    $script:F = @{
        Disk=[pscustomobject]@{Number=0; PartitionStyle='GPT'; Size=[int64]256GB}
        OS=$os; OldRecovery=$recovery; Partitions=@($os,$recovery)
        Active=$os; Status='Enabled'; Free=[int64]10GB; SourceResolves=$true; SourceOnRecovery=$false
        SourceChanged=$false; HashCalls=0; Drift=$false; ShrinkOK=$true; VerifyShrinkOK=$true
        DisableOK=$true; DeleteOK=$true; CreateOK=$true; FormatOK=$true; RestoreOK=$true
        OriginalSize=$os.Size
        Plan=@{
            Valid=$true; DeletableRecoveryPartitions=@($recovery); InterveningAnchor=$null
            RecoveryBytes=[int64]1000MB; UnallocatedBytes=0; ShrinkBytes=[int64]300MB; ExtendBytes=0
            PlannedOSPartitionSize=($os.Size-300MB); PlannedPartitionStart=($os.Offset+$os.Size-300MB)
            PlannedPartitionSize=[int64]1300MB; AlignedManagedExtentEnd=($recovery.Offset+$recovery.Size)
            AlignmentReserveBytes=0; SizeMinBytes=[int64]100GB; RequiresConsolidation=$false
        }
    }
    $script:DryRun=$false; $script:GeometryRestoreFailed=$false
    $script:ResumeTaskShouldPersist=$false; $script:PendingDeploymentPresent=$true
    $script:PendingDeployment=@{Phase='Prepared'}
    $script:tempDriveLetters=[Collections.Generic.List[string]]::new()
    $script:RegisteredSourceFingerprint=@{}
}
function Write-Log { param($Message,$Level) }
function Get-OSDisk { $script:F.Disk }
function Get-OSPartition { $script:F.OS }
function Get-Disk { [CmdletBinding()]param($Number) $script:F.Disk }
function Get-PartitionSupportedSize { [CmdletBinding()]param($DiskNumber,$PartitionNumber) [pscustomobject]@{SizeMin=[int64]100GB} }
function Get-PartitionPlan { param($OSDisk,$OSPartition,$Partitions,$SizeMinBytes,$BucketSizeBytes,$MaxRecoveryPartitionBytes) $script:F.Plan }
function Get-LiveWimHash {
    param($WimPath)
    $script:F.HashCalls++
    if($script:F.SourceChanged -and $script:F.HashCalls -gt 1){ return ('B'*64) }
    return ('A'*64)
}
function Get-Volume {
    [CmdletBinding()]param($FilePath,$Partition,$DriveLetter)
    if($PSBoundParameters.ContainsKey('FilePath')) {
        if($script:F.SourceResolves){ return [pscustomobject]@{IsSource=$true} }
        return $null
    }
    if($PSBoundParameters.ContainsKey('DriveLetter')){ return $null }
    [pscustomobject]@{SizeRemaining=$script:F.Free; Size=[int64]230GB; FileSystemLabel='mock'}
}
function Get-Partition {
    [CmdletBinding()]param($DiskNumber,$PartitionNumber,$Volume)
    if($Volume) { if($script:F.SourceOnRecovery){return $script:F.OldRecovery}; return $script:F.OS }
    if($PSBoundParameters.ContainsKey('PartitionNumber')) { return $script:F.Partitions | Where-Object {$_.PartitionNumber -eq $PartitionNumber} }
    return $script:F.Partitions
}
function Get-WinREState { @{Status=$script:F.Status; Location='mock-registered-route'} }
function Resolve-WinRELocationToPartition { param($Location) $script:F.Active }
function Format-PartitionRef { param($Partition) "mock disk/partition $($Partition.PartitionNumber)" }
function Test-VolumeEncrypted { param($MountPoint) $false }
function Write-PendingDeployment { param($Record) $script:Calls.Add("Journal:$($Record.Phase)") }
function Invoke-OSPartitionShrink {
    param($DiskNumber,$PartitionNumber,$InitialSizeBytes,$TargetSizeBytes,$DefragTarget)
    $script:Calls.Add('Shrink')
    if($script:F.ShrinkOK){$script:F.OS.Size=$TargetSizeBytes}
    @{Success=$script:F.ShrinkOK}
}
function Assert-PartitionSizeAfterResize {
    param($DiskNumber,$PartitionNumber,$ExpectedSizeBytes,[switch]$SuppressSuccessLog)
    return ($script:F.VerifyShrinkOK -and $script:F.OS.Size -eq $ExpectedSizeBytes)
}
function Restore-OSPartitionSize {
    param($Reason,$TargetSizeBytes,$DiskNumber,$PartitionNumber)
    $script:Calls.Add('RestoreGeometry')
    if($script:F.RestoreOK){$script:F.OS.Size=$TargetSizeBytes}else{$script:GeometryRestoreFailed=$true}
    $script:F.RestoreOK
}
function Assert-RegisteredWinREUnchanged { param($Captured,$CalledFrom) $script:Calls.Add('CheckRegisteredSource'); -not $script:F.Drift }
function cmd {
    param($Switch,$Command)
    if($Command -notlike '*reagentc /disable*'){throw "Unexpected native call: $Command"}
    $script:Calls.Add('Disable'); $global:LASTEXITCODE=0
    if($script:F.DisableOK){$script:F.Status='Disabled'}else{$global:LASTEXITCODE=1}
}
function diskpart { throw 'Unexpected diskpart fallback.' }
function Start-Sleep { param($Seconds) }
function Remove-Partition {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        $script:Calls.Add('DeleteOldPartition')
        if($script:F.DeleteOK){$script:F.Partitions=@($script:F.Partitions | Where-Object {$_.PartitionNumber -ne $InputObject.PartitionNumber})}
    }
}
function Restore-PreviousWinRERoute { param($PreviousState) $script:Calls.Add('RestoreRoute'); $script:F.Status=$PreviousState.Status; return $true }
function New-Partition {
    [CmdletBinding()]param($DiskNumber,$Offset,$Size,$GptType,$MbrType)
    $script:Calls.Add('CreatePartition')
    if(-not $script:F.CreateOK){throw 'Injected create failure.'}
    $p=[pscustomobject]@{DiskNumber=$DiskNumber;PartitionNumber=4;Offset=$Offset;Size=$Size;Guid='new-recovery';GptType=$GptType;MbrType=$MbrType}
    $script:F.Partitions+= $p
    return $p
}
function Assert-RecoveryPartitionLayout { param($DiskNumber,$PartitionNumber,$ExpectedOffsetBytes,$ExpectedSizeBytes,$ExpectedEndBytes,$BoundaryPartition) $true }
function Format-Volume {
    [CmdletBinding(SupportsShouldProcess)]param($Partition,$FileSystem,$NewFileSystemLabel,[switch]$Force)
    $script:Calls.Add('Format')
    if(-not $script:F.FormatOK){throw 'Injected format failure.'}
}
function Set-RecoveryPartitionAttributes { param($DiskNumber,$PartitionNumber,$Style) $true }
function Set-RecoveryPartitionReadyForWinRE { param($DiskNumber,$PartitionNumber) $true }
function Get-AvailableDriveLetter { 'R' }
function Invoke-DriveLetterAssignment { param($DiskNumber,$PartitionNumber,$PreferredLetter) 'R' }
function New-DirectoryIfNotExists { param($Path) $script:Calls.Add('CreateTargetDirectory') }
function Remove-OrphanPartition {
    param($DiskNumber,$PartitionNumber,$Reason,$TargetOSPartitionSizeBytes,$AnchorDiskNumber,$AnchorPartitionNumber)
    $script:Calls.Add('RemoveOrphan'); $script:F.Partitions=@($script:F.OS)
    $script:F.OS.Size=$TargetOSPartitionSizeBytes; return $true
}
function Invoke-OSPartitionExtend { throw 'Unexpected extension in shrink fixture.' }
function Remove-ItemIfExist { param($Path) throw 'Unexpected file cleanup.' }
function Set-Checkpoint { throw 'Unexpected checkpoint change.' }
function Require { param($Condition,$Message) if(-not $Condition){throw $Message} }
function Prepare { Ensure-AdequateRecoveryPartition -RequiredWimSizeMB 969 -ProtectedSourcePath 'mock-candidate.wim' -ExpectedSourceHash ('A'*64) -PrepareBeforeDisable }
function No-Destruction {
    Require (-not ($script:Calls -contains 'Disable') -and -not ($script:Calls -contains 'DeleteOldPartition') -and -not ($script:Calls -contains 'CreatePartition')) 'Reached disable/delete/create.'
}
function Check {
    param($Name,[scriptblock]$Body)
    Reset-Fixture
    & $Body
    $script:Passed++; Write-Output "PASS: $Name"
}

Check 'OS-hosted active route remains enabled while a new target is prepared' {
    $r=Prepare
    Require ($r.Status -eq 'Created' -and $script:F.Status -eq 'Enabled') 'Did not prepare target with old route enabled.'
    Require (-not ($script:Calls -contains 'Disable') -and ($script:Calls -contains 'DeleteOldPartition') -and ($script:Calls -contains 'CreatePartition')) 'Prepare-before-disable sequence failed.'
    Require ($script:Calls.IndexOf('Journal:MutationStarted') -lt $script:Calls.IndexOf('Shrink')) 'Geometry changed before durable journal.'
    Require ($script:PendingDeployment.ResizeTargetInitialSize -eq $script:F.OriginalSize -and $script:PendingDeployment.PlannedTargetSize -eq 1300MB -and $script:PendingDeployment.RecoveryInventoryJson) 'Journal lacks original geometry or deletion inventory.'
}
Check 'active dedicated partition in deletion set is disabled before deletion' {
    $script:F.Active=$script:F.OldRecovery; $r=Prepare
    Require ($r.Status -eq 'Created') 'Did not reach successful target creation.'
    Require ($script:Calls.IndexOf('Disable') -ge 0 -and $script:Calls.IndexOf('Disable') -lt $script:Calls.IndexOf('DeleteOldPartition')) 'Active recovery was deleted before disable.'
}
Check 'original expected hash is checked before shrink' {
    $r=Ensure-AdequateRecoveryPartition -RequiredWimSizeMB 969 -ProtectedSourcePath 'mock-candidate.wim' -ExpectedSourceHash ('B'*64) -PrepareBeforeDisable
    Require ($r.Status -eq 'Deferred' -and -not ($script:Calls -contains 'Shrink')) 'Hash mismatch reached resize.'; No-Destruction
}
Check 'source partition resolution failure refuses mutation' {
    $script:F.SourceResolves=$false; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and -not ($script:Calls -contains 'Shrink')) 'Unresolved source reached resize.'; No-Destruction
}
Check 'source in deletion set refuses mutation' {
    $script:F.SourceOnRecovery=$true; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and -not ($script:Calls -contains 'Shrink')) 'Disposable source reached resize.'; No-Destruction
}
Check 'unknown WinRE status refuses mutation' {
    $script:F.Status='Unknown'; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and -not ($script:Calls -contains 'Shrink')) 'Unknown status reached resize.'; No-Destruction
}
Check 'insufficient measured reserve defers before shrink' {
    $script:F.Free=[int64]3GB; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and $r.RetrySuppressible -and -not ($script:Calls -contains 'Shrink')) 'Reserve failure reached resize.'; No-Destruction
}
Check 'failed shrink retains enabled route and old partition' {
    $script:F.ShrinkOK=$false; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and $r.RetrySuppressible -and $script:F.Status -eq 'Enabled' -and $script:F.Partitions.Count -eq 2) 'Shrink failure did not preserve route.'; No-Destruction
}
Check 'post-shrink verification failure restores geometry before deferring' {
    $script:F.VerifyShrinkOK=$false; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and $script:Calls -contains 'RestoreGeometry' -and $script:F.OS.Size -eq $script:F.OriginalSize) 'Unverified shrink geometry was retained.'; No-Destruction
}
Check 'post-shrink candidate drift restores geometry before disable or deletion' {
    $script:F.SourceChanged=$true; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and $script:Calls -contains 'RestoreGeometry' -and $script:F.OS.Size -eq $script:F.OriginalSize) 'Changed source did not restore geometry.'; No-Destruction
}
Check 'registered source drift restores geometry before preparing target' {
    $script:F.Drift=$true; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and $script:Calls -contains 'RestoreGeometry' -and $script:F.OS.Size -eq $script:F.OriginalSize) 'Changed registered source did not restore geometry.'; No-Destruction
}
Check 'unverified restoration is exposed instead of claiming full rollback' {
    $script:F.SourceChanged=$true; $script:F.RestoreOK=$false; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and $script:GeometryRestoreFailed) 'Geometry failure was hidden.'; No-Destruction
}
Check 'failed deletion attempts route and geometry restoration before returning' {
    $script:F.Active=$script:F.OldRecovery; $script:F.DeleteOK=$false; $r=Prepare
    Require ($r.Status -eq 'Deferred' -and $script:Calls -contains 'RestoreGeometry' -and $script:Calls -contains 'RestoreRoute') 'Deletion failure did not attempt restoration.'
    Require (-not ($script:Calls -contains 'CreatePartition')) 'Creation ran while undeleted partition remained.'
}
Check 'creation failure after deletion is not reported as untouched deferral' {
    $script:F.Active=$script:F.OldRecovery; $script:F.CreateOK=$false; $r=Prepare
    Require ($null -eq $r -and $script:F.Status -eq 'Disabled' -and $script:F.Partitions.Count -eq 1 -and $script:Calls -contains 'RestoreGeometry') 'Post-deletion failure was misreported or not reached.'
    Require ($script:Calls.FindAll({param($c) $c -eq 'CreatePartition'}).Count -eq 3) 'Bounded creation retries changed.'
    Require ($script:PendingDeploymentPresent -and $script:PendingDeployment.Phase -eq 'MutationStarted') 'Pending recovery ownership was lost.'
}
Check 'format failure removes only the new orphan and retains journal' {
    $script:F.FormatOK=$false; $r=Prepare
    Require ($null -eq $r -and $script:Calls -contains 'RemoveOrphan' -and $script:PendingDeploymentPresent) 'Format failure lost pending recovery or orphan cleanup.'
}
Write-Output "Partition preparation regressions: $script:Passed passed. All storage and native providers mocked."
