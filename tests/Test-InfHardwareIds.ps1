<#
.SYNOPSIS
    Isolated INF parsing and storage-applicability regression checks.
.DESCRIPTION
    Extracts the actual production INF parser, controller enumerator and
    applicability checker. All INF/filesystem and PnP providers are mocked.
    The wstorvsc model line is the exact line 35 observed in the VM's original
    registered WinRE image; the minimal Manufacturer/model wrapper is a fixture.
    No production main flow, disk query, WIM mount or native tool runs.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$productionPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WinRE.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($productionPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Production parse failed.' }
foreach ($name in @('Get-HardwareIdsFromInf', 'Get-StorageControllerDevices', 'Test-StorageDriverApplicability')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing production function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:Passed = 0
$script:HyperVId = 'VMBUS\{ba6163d9-04a1-4d29-b605-72e2ffb1dc7f}'
$script:PhysicalId = 'PCI\VEN_1234&DEV_5678'
$script:HyperVInf = 'C:\mock-image\Windows\INF\wstorvsc.inf'
$script:PhysicalInf = 'C:\mock-image\Windows\INF\physical.inf'

function New-ModelInf {
    param([string[]]$Ids)
    @('[Manufacturer]', '%Microsoft%=Microsoft,NTamd64', '[Microsoft.NTamd64]',
      ('%DeviceDesc% = storvscDriveInstall, ' + ($Ids -join ', ')))
}
function Reset-Fixture {
    $observed = @('[Manufacturer]', '%Microsoft%=Microsoft,NTamd64', '[Microsoft.NTamd64]')
    while ($observed.Count -lt 34) { $observed += '' }
    $observed += '%DeviceDesc% = storvscDriveInstall, VMBUS\{ba6163d9-04a1-4d29-b605-72e2ffb1dc7f}'
    $script:F = @{
        InfContents = @{}
        InfReadThrows = $false; PnpThrows = $false
        InfDirectoryExists = $true
        Devices = @(
            [pscustomobject]@{
                FriendlyName = 'Microsoft Hyper-V SCSI Controller'
                InstanceId = 'VMBUS\{BA6163D9-04A1-4D29-B605-72E2FFB1DC7F}\{E1F07DBF-E113-4260-BECA-0F8F76DF34C1}'
                HardwareID = @($script:HyperVId); CompatibleID = @()
            },
            [pscustomobject]@{
                FriendlyName = 'Physical storage fixture'
                InstanceId = 'PCI\VEN_1234&DEV_5678\INSTANCE'
                HardwareID = @($script:PhysicalId); CompatibleID = @()
            }
        )
        Logs = [Collections.Generic.List[string]]::new()
    }
    $script:F.InfContents[$script:HyperVInf] = $observed
    $script:F.InfContents[$script:PhysicalInf] = @(New-ModelInf -Ids @($script:PhysicalId))
}
function Check {
    param([string]$Name, [scriptblock]$Body)
    Reset-Fixture
    & $Body
    $script:Passed++
    Write-Output "PASS: $Name"
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Applicable {
    param([bool]$Expected, [int]$Matched)
    $result = Test-StorageDriverApplicability -MountDir 'C:\mock-image'
    Assert-True ($result.Applicable -eq $Expected -and $result.Matched -eq $Matched -and $result.Controllers -eq 2) "Unexpected applicability result: $($result | ConvertTo-Json -Compress)"
}

# Replace every provider exercised by the imported production functions.
function Get-Content {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if ($script:F.InfReadThrows -or -not $script:F.InfContents.ContainsKey($LiteralPath)) { throw 'Mock INF read failure.' }
    return $script:F.InfContents[$LiteralPath]
}
function Get-PnpDevice {
    [CmdletBinding()]
    param([string]$Class, [switch]$PresentOnly)
    if ($Class -ne 'SCSIAdapter' -or -not $PresentOnly) { throw 'Unexpected PnP query.' }
    if ($script:F.PnpThrows) { throw 'Mock PnP enumeration failure.' }
    return $script:F.Devices
}
function Test-Path {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$PathType)
    if ($LiteralPath -ne 'C:\mock-image\Windows\INF' -or $PathType -ne 'Container') { throw 'Unexpected filesystem probe.' }
    return $script:F.InfDirectoryExists
}
function Get-ChildItem {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Filter, [switch]$File)
    if ($LiteralPath -ne 'C:\mock-image\Windows\INF' -or $Filter -ne '*.inf' -or -not $File) { throw 'Unexpected INF enumeration.' }
    foreach ($path in $script:F.InfContents.Keys) { [pscustomobject]@{ FullName = $path } }
}
function Write-Log {
    param($Message, $Level)
    $script:F.Logs.Add([string]$Message)
}

Check 'Observed wstorvsc line 35 produces its exact VMBUS ID' {
    Assert-True ($script:F.InfContents[$script:HyperVInf][34] -ceq ('%DeviceDesc% = storvscDriveInstall, ' + $script:HyperVId)) 'Observed model line drifted.'
    $ids = @(Get-HardwareIdsFromInf -InfPath $script:HyperVInf)
    Assert-True ($ids.Count -eq 1 -and $ids[0] -ceq $script:HyperVId) 'Actual parser missed the observed Hyper-V model ID.'
}
Check 'Actual controller/parser/applicability chain retains and matches Hyper-V storage' {
    $controllers = Get-StorageControllerDevices
    Assert-True ($controllers.Count -eq 2 -and $controllers[0].Ids -contains $script:HyperVId) 'Hyper-V controller was dropped or its IDs changed.'
    Assert-Applicable -Expected $true -Matched 2
}
Check 'Mixed-case VMBUS models and duplicate IDs remain case-insensitive' {
    $script:F.InfContents[$script:HyperVInf] = @(New-ModelInf -Ids @($script:HyperVId.ToUpperInvariant(), $script:HyperVId))
    $ids = @(Get-HardwareIdsFromInf -InfPath $script:HyperVInf)
    Assert-True ($ids.Count -eq 1) 'Case-insensitive de-duplication changed.'
    Assert-Applicable -Expected $true -Matched 2
}
Check 'All previously supported bus prefixes still parse unchanged' {
    $legacyIds = @('PCI\DEVICE', 'USB\DEVICE', 'ACPI\DEVICE', 'SCSI\DEVICE', 'IDE\DEVICE', 'SWC\DEVICE', 'ROOT\DEVICE', 'HDAUDIO\DEVICE', 'MONITOR\DEVICE', 'DISPLAY\DEVICE', 'MF\DEVICE')
    $script:F.InfContents[$script:HyperVInf] = @(New-ModelInf -Ids $legacyIds)
    $ids = @(Get-HardwareIdsFromInf -InfPath $script:HyperVInf)
    Assert-True ($ids.Count -eq $legacyIds.Count) 'Legacy prefix inventory changed.'
    foreach ($id in $legacyIds) { Assert-True ($ids -ccontains $id) "Legacy ID missing: $id" }
}
Check 'Multiple model IDs preserve both virtual and physical matches' {
    $script:F.InfContents[$script:HyperVInf] = @(New-ModelInf -Ids @($script:HyperVId, $script:PhysicalId))
    $script:F.InfContents.Remove($script:PhysicalInf)
    Assert-Applicable -Expected $true -Matched 2
}
Check 'A different VMBUS controller GUID does not satisfy the missing driver' {
    $script:F.InfContents[$script:HyperVInf] = @(New-ModelInf -Ids @('VMBUS\{11111111-1111-1111-1111-111111111111}'))
    Assert-Applicable -Expected $false -Matched 1
}
Check 'A physical driver alone does not exempt the guest storage controller' {
    $script:F.InfContents.Remove($script:HyperVInf)
    Assert-Applicable -Expected $false -Matched 1
}
Check 'A comment-only VMBUS ID cannot satisfy applicability' {
    $script:F.InfContents[$script:HyperVInf] = @('[Manufacturer]', '%Microsoft%=Microsoft,NTamd64', '[Microsoft.NTamd64]', ('; %DeviceDesc% = storvscDriveInstall, ' + $script:HyperVId))
    Assert-Applicable -Expected $false -Matched 1
}
Check 'An unreferenced model section cannot supply a VMBUS driver' {
    $script:F.InfContents[$script:HyperVInf] = @('[Manufacturer]', '%Microsoft%=Other,NTamd64', '[Microsoft.NTamd64]', ('%DeviceDesc% = storvscDriveInstall, ' + $script:HyperVId))
    Assert-Applicable -Expected $false -Matched 1
}
Check 'A bus-like prefix or bare GUID does not become a controller-wide exemption' {
    $script:F.InfContents[$script:HyperVInf] = @(New-ModelInf -Ids @('VMBUSX\{ba6163d9-04a1-4d29-b605-72e2ffb1dc7f}', '{ba6163d9-04a1-4d29-b605-72e2ffb1dc7f}'))
    Assert-Applicable -Expected $false -Matched 1
}
Check 'An INF without Manufacturer references cannot satisfy applicability' {
    $script:F.InfContents[$script:HyperVInf] = @('[Microsoft.NTamd64]', ('%DeviceDesc% = storvscDriveInstall, ' + $script:HyperVId))
    Assert-Applicable -Expected $false -Matched 1
}
Check 'Unreadable INFs remain fail-closed' {
    $script:F.InfReadThrows = $true
    Assert-True (@(Get-HardwareIdsFromInf -InfPath $script:HyperVInf).Count -eq 0) 'Unreadable INF produced IDs.'
    Assert-Applicable -Expected $false -Matched 0
}
Check 'Controller-enumeration failure remains indeterminate and refused' {
    $script:F.PnpThrows = $true
    $result = Test-StorageDriverApplicability -MountDir 'C:\mock-image'
    Assert-True (-not $result.Applicable -and $result.Controllers -eq 0 -and $result.Matched -eq 0) 'Failed enumeration was certified.'
}
Check 'Missing candidate INF directory remains refused' {
    $script:F.InfDirectoryExists = $false
    Assert-Applicable -Expected $false -Matched 0
}

Write-Output "All $script:Passed INF hardware-ID checks passed."
