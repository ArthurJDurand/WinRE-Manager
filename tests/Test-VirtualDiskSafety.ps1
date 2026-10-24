<#
.SYNOPSIS
    Isolated checks of virtual-OS eligibility and non-OS recovery sweep safety.
.DESCRIPTION
    Extracts the actual production topology gate, hypervisor detector, recovery
    sweep and workspace selector without running production main. All storage,
    CIM, filesystem probes, waits and deletion providers are mocked.
    No actual disk queries, partition changes, VM calls or native tools run.
    Native-boot VHDX remains refused under the current production policy;
    these checks do not claim that recovery boot inside native VHDX is tested.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$productionPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WinRE.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($productionPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Production parse failed.' }
foreach ($name in @('Test-NativeBootVirtualTopology', 'Test-RunningInVirtualMachine', 'Remove-StrayRecoveryPartitions', 'Get-WorkDirCandidates')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing production function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$script:Passed = 0
$MaxManagedRecoveryPartitionMiB = 2048
$InternalWorkspaceBusTypes = @('ATA', 'SATA', 'NVMe', 'RAID', 'SAS', 'Spaces', 'Virtual', 'File Backed Virtual', 'SCM')
$recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
function Reset-Fixture {
    $script:F = @{
        OS = [pscustomobject]@{ DiskNumber = 7; PartitionNumber = 3; DriveLetter = $env:SystemDrive.TrimEnd(':'); IsBoot = $true; IsSystem = $false; GptType = ''; MbrType = 0 }
        Disks = @([pscustomobject]@{ Number = 7; BusType = 'SCSI'; IsOffline = $false }, [pscustomobject]@{ Number = 8; BusType = 'NVMe'; IsOffline = $false })
        Partitions = @{}
        Volumes = @()
        Manufacturer = 'ASUS'; Model = 'System Product Name'
        CimThrows = $false; EnumerationThrows = $false; VerificationThrows = $false
        DeleteThrows = $false; DeleteSurvives = $false
        InventoryReads = 0; RecoveryReads = 0; VerificationReads = 0
        Deletes = [Collections.Generic.List[string]]::new()
        Logs = [Collections.Generic.List[string]]::new()
    }
    $script:DryRun = $false
    $script:nonFatalWarning = $false
}
function New-MockRecovery {
    param([int]$DiskNumber = 8, [int64]$Size = 1000MB, [switch]$LabelOnly)
    [pscustomobject]@{
        DiskNumber = $DiskNumber; PartitionNumber = 4; Size = $Size
        GptType = $(if ($LabelOnly) { '' } else { $recoveryType }); MbrType = 0
    }
}
function Check {
    param([string]$Name, [scriptblock]$Body)
    Reset-Fixture
    & $Body
    $script:Passed++
    Write-Output "PASS: $Name"
}
function Write-Log { param($Message, $Level) $script:F.Logs.Add([string]$Message) }
function Get-OSPartition { return $script:F.OS }
function Get-Disk {
    [CmdletBinding()]
    param([int]$Number)
    if ($PSBoundParameters.ContainsKey('Number')) { return $script:F.Disks | Where-Object { $_.Number -eq $Number } }
    $script:F.InventoryReads++
    if ($script:F.EnumerationThrows) { throw 'Mock disk inventory failure.' }
    return $script:F.Disks
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName)
    if ($ClassName -ne 'Win32_ComputerSystem') { throw "Unexpected CIM provider: $ClassName" }
    if ($script:F.CimThrows) { throw 'Mock computer-system metadata failure.' }
    [pscustomobject]@{ Manufacturer = $script:F.Manufacturer; Model = $script:F.Model }
}
function Get-RecoveryPartitions {
    param([int]$DiskNumber)
    $script:F.RecoveryReads++
    return @($script:F.Partitions[$DiskNumber]) | Where-Object { $null -ne $_ }
}
function Get-Partition {
    [CmdletBinding()]
    param([int]$DiskNumber, [string]$DriveLetter)
    if ($PSBoundParameters.ContainsKey('DriveLetter')) {
        if ($DriveLetter -eq $script:F.OS.DriveLetter) { return $script:F.OS }
        return [pscustomobject]@{ DiskNumber = 8; PartitionNumber = 3; DriveLetter = $DriveLetter; IsBoot = $false; IsSystem = $false; GptType = ''; MbrType = 0 }
    }
    $script:F.VerificationReads++
    if ($script:F.VerificationThrows) { throw 'Mock post-deletion inventory failure.' }
    return @($script:F.Partitions[$DiskNumber]) | Where-Object { $null -ne $_ }
}
function Get-Volume { [CmdletBinding()]param() return $script:F.Volumes }
function Test-Path { [CmdletBinding()]param($LiteralPath, $PathType) return $false }
function Get-Item { [CmdletBinding()]param($LiteralPath, [switch]$Force) throw 'No mocked workspace path exists.' }
function Start-Sleep { param($Seconds) }
function Remove-Partition {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($script:F.DeleteThrows) { throw 'Mock partition deletion failure.' }
        $script:F.Deletes.Add("$($InputObject.DiskNumber)/$($InputObject.PartitionNumber)")
        if (-not $script:F.DeleteSurvives) {
            $script:F.Partitions[$InputObject.DiskNumber] = @($script:F.Partitions[$InputObject.DiskNumber] | Where-Object { $_.PartitionNumber -ne $InputObject.PartitionNumber })
        }
    }
}
function Assert-SuppressedSweep {
    $result = Remove-StrayRecoveryPartitions -OSDiskNumber 7
    if ($result -ne $true -or $script:F.InventoryReads -ne 0 -or $script:F.RecoveryReads -ne 0 -or $script:F.Deletes.Count -ne 0) {
        throw 'Suppressed sweep reached disk inventory or mutation.'
    }
}
function Assert-PreservedSweep {
    $result = Remove-StrayRecoveryPartitions -OSDiskNumber 7
    if ($result -ne $true -or $script:F.Deletes.Count -ne 0 -or $script:F.VerificationReads -ne 0) {
        throw 'Protected recovery partition reached deletion or post-deletion verification.'
    }
}

Check 'Hyper-V SCSI OS disk retains repair eligibility and suppresses the other-disk sweep' {
    $script:F.Manufacturer = 'Microsoft Corporation'; $script:F.Model = 'Virtual Machine'
    if ((Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Ordinary Hyper-V OS disk was refused.' }
    Assert-SuppressedSweep
}
Check 'VirtualBox SATA OS disk retains repair eligibility and suppresses the other-disk sweep' {
    $script:F.Disks[0].BusType = 'SATA'
    $script:F.Manufacturer = 'innotek GmbH'; $script:F.Model = 'VirtualBox'
    if ((Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Ordinary VirtualBox OS disk was refused.' }
    Assert-SuppressedSweep
}
Check 'native file-backed OS with a visible physical disk is still refused by current policy' {
    $script:F.Disks[0].BusType = 'File Backed Virtual'
    $result = Test-NativeBootVirtualTopology
    if (-not $result.IsNativeBootVirtual -or $result.HostBusTypes -notcontains 'NVMe') { throw 'Existing native-VHDX refusal changed.' }
}
Check 'file-backed OS with only virtual peer disks retains current repair eligibility' {
    $script:F.Disks[0].BusType = 'File Backed Virtual'; $script:F.Disks[1].BusType = 'Virtual'
    if ((Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Virtual-only topology was refused.' }
}
Check 'file-backed OS fails closed when disk inventory throws' {
    $script:F.Disks[0].BusType = 'File Backed Virtual'; $script:F.EnumerationThrows = $true
    if (-not (Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Indeterminate inventory was allowed.' }
}
Check 'file-backed OS fails closed when another disk bus is unreadable' {
    $script:F.Disks[0].BusType = 'File Backed Virtual'; $script:F.Disks[1].BusType = $null
    if (-not (Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Unknown peer bus was allowed.' }
}
Check 'unresolved OS partition fails closed' {
    $script:F.OS = $null
    if (-not (Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Missing OS partition was allowed.' }
}
Check 'unresolved OS disk fails closed' {
    $script:F.Disks = @($script:F.Disks[1])
    if (-not (Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Missing OS disk was allowed.' }
}
Check 'unreadable OS bus fails closed' {
    $script:F.Disks[0].BusType = $null
    if (-not (Test-NativeBootVirtualTopology).IsNativeBootVirtual) { throw 'Missing OS bus was allowed.' }
}
Check 'empty hypervisor metadata suppresses the sweep before disk access' {
    $script:F.Manufacturer = '  '; $script:F.Model = ''
    Assert-SuppressedSweep
}
Check 'failed hypervisor query suppresses the sweep before disk access' {
    $script:F.CimThrows = $true
    Assert-SuppressedSweep
}
Check 'physical-machine sweep preserves the running OS disk' {
    $script:F.Disks = @($script:F.Disks[0]); $script:F.Partitions[7] = @(New-MockRecovery -DiskNumber 7)
    Assert-PreservedSweep
    if ($script:F.RecoveryReads -ne 0) { throw 'OS disk recovery inventory was swept.' }
}
Check 'physical-machine sweep preserves a mounted VHDX peer disk' {
    $script:F.Disks[1].BusType = 'File Backed Virtual'; $script:F.Partitions[8] = @(New-MockRecovery)
    Assert-PreservedSweep
    if ($script:F.RecoveryReads -ne 0) { throw 'Mounted VHDX reached recovery inventory.' }
}
Check 'physical-machine sweep preserves a USB disk' {
    $script:F.Disks[1].BusType = 'USB'; $script:F.Partitions[8] = @(New-MockRecovery)
    Assert-PreservedSweep
    if ($script:F.RecoveryReads -ne 0) { throw 'Unsupported bus reached recovery inventory.' }
}
Check 'physical-machine sweep preserves an unknown-bus disk' {
    $script:F.Disks[1].BusType = $null; $script:F.Partitions[8] = @(New-MockRecovery)
    Assert-PreservedSweep
    if ($script:F.RecoveryReads -ne 0) { throw 'Unknown bus reached recovery inventory.' }
}
Check 'physical-machine sweep preserves a recovery partition above 2048 MiB' {
    $script:F.Partitions[8] = @(New-MockRecovery -Size 2049MB)
    Assert-PreservedSweep
    if (-not $script:nonFatalWarning) { throw 'Oversized partition did not require operator review.' }
}
Check 'physical-machine sweep preserves a label-only recovery match' {
    $script:F.Partitions[8] = @(New-MockRecovery -LabelOnly)
    Assert-PreservedSweep
}
Check 'eligible internal recovery deletion is verified against fresh mocked inventory' {
    $script:F.Partitions[8] = @(New-MockRecovery)
    $result = Remove-StrayRecoveryPartitions -OSDiskNumber 7
    if ($result -ne $true -or ($script:F.Deletes -join ',') -ne '8/4' -or $script:F.VerificationReads -ne 1) { throw 'Eligible deletion or its read-back verification changed.' }
}
Check 'a successful deletion provider cannot hide a surviving partition' {
    $script:F.Partitions[8] = @(New-MockRecovery); $script:F.DeleteSurvives = $true
    $result = Remove-StrayRecoveryPartitions -OSDiskNumber 7
    if ($result -ne $false -or -not $script:nonFatalWarning -or $script:F.VerificationReads -ne 1) { throw 'Unconfirmed deletion was reported successful.' }
}
Check 'post-deletion inventory failure is not reported as confirmed deletion' {
    $script:F.Partitions[8] = @(New-MockRecovery); $script:F.VerificationThrows = $true
    $result = Remove-StrayRecoveryPartitions -OSDiskNumber 7
    if ($result -ne $false -or -not $script:nonFatalWarning -or $script:F.VerificationReads -ne 1) { throw 'Failed read-back was reported successful.' }
}
Check 'a partition deletion failure is reported without success' {
    $script:F.Partitions[8] = @(New-MockRecovery); $script:F.DeleteThrows = $true
    $result = Remove-StrayRecoveryPartitions -OSDiskNumber 7
    if ($result -ne $false -or -not $script:nonFatalWarning -or $script:F.Deletes.Count -ne 0) { throw 'Failed deletion was reported successful.' }
}
Check 'DryRun describes eligible deletion without calling its provider' {
    $script:F.Partitions[8] = @(New-MockRecovery); $script:DryRun = $true
    Assert-PreservedSweep
    if (-not @($script:F.Logs | Where-Object { $_ -match 'Would delete stray recovery partition disk 8 part 4' }).Count) { throw 'DryRun lost its deletion preview.' }
}
Check 'SCSI workspace eligibility includes the OS volume and excludes a peer SCSI volume' {
    $script:F.Disks[1].BusType = 'SCSI'
    $script:F.Volumes = @(
        [pscustomobject]@{ DriveType = 'Fixed'; FileSystem = 'NTFS'; DriveLetter = $script:F.OS.DriveLetter; FileSystemLabel = 'Windows'; SizeRemaining = [int64]20GB },
        [pscustomobject]@{ DriveType = 'Fixed'; FileSystem = 'NTFS'; DriveLetter = 'Z'; FileSystemLabel = 'Peer'; SizeRemaining = [int64]100GB }
    )
    $candidates = @(Get-WorkDirCandidates)
    if ($candidates.Count -ne 1 -or -not $candidates[0].IsOSVolume -or $candidates[0].DiskNumber -ne 7) { throw 'Guest OS SCSI workspace admission or peer exclusion changed.' }
}

Write-Output "Virtual disk safety regression tests: $script:Passed passed, 0 failed. All disk, CIM and deletion providers mocked."
