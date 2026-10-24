<#
.SYNOPSIS
    Isolated JSON, ACL and BitLocker-provider regressions for patch 5.
.DESCRIPTION
    Imports function definitions only. Native tools and ACL writes are mocked.
    Does not execute the production script or query/change real encryption.
#>
$ErrorActionPreference = 'Stop'
$parseErrors = $null
$tokens = $null
$path = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WinRE.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Production parse failed.' }
foreach ($name in @('ConvertFrom-DeploymentJson','Test-VolumeEncrypted','Test-VolumeAccessibleForResize','Test-DeploymentStoreTrusted','Set-DeploymentFileSecurity','Dismount-OwnedWinREImages','Remove-CompletedServicingWorkspace')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:passed = 0
function Check {
    param($Name, [scriptblock]$Body)
    $script:CmdletAvailable = $false; $script:CmdletThrows = $false; $script:Metadata = $null
    $script:BdeThrows = $false; $script:BdeText = 'Conversion Status: Fully Decrypted'
    $script:CmdletCalls = 0; $script:BdeCalls = 0; $script:Trusted = $true; $script:SafePath = $true
    $script:Acl = [pscustomobject]@{ Access = @() }; $script:WrittenAcl = $null
    $script:DryRun=$false; $script:ProgramLockStream=[object]::new(); $script:OwnsWimWork=$true
    $script:MountedImages=@(); $script:QueryCalls=0; $script:QueryThrows=$false
    $script:DismountCalls=[Collections.Generic.List[string]]::new(); $script:nonFatalWarning=$false
    $script:ResumeTaskShouldPersist=$false; $script:ChildReads=0
    & $Body
    $script:passed++
    Write-Output "PASS: $Name"
}
function Require { param($Value, $Message) if (-not $Value) { throw $Message } }
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'Get-BitLockerVolume') { if ($script:CmdletAvailable) { return [pscustomobject]@{ Name = $Name } }; return $null }
    return (Microsoft.PowerShell.Core\Get-Command -Name $Name -ErrorAction Stop)
}
function Get-BitLockerVolume { param($MountPoint, $ErrorAction) $script:CmdletCalls++; if ($script:CmdletThrows) { throw 'query failed' }; return $script:Metadata }
function manage-bde.exe { $script:BdeCalls++; if ($script:BdeThrows) { throw 'native provider unavailable' }; return $script:BdeText }
function Write-Log { param($Message, $Level) }
function Test-PathTrustedForSystem { param($Path, $Kind) return $script:Trusted }
function Test-DeploymentPathWithoutReparse { param($Path) return $script:SafePath }
function Get-Acl { param($LiteralPath, $ErrorAction) return $script:Acl }
function Set-Acl { param($LiteralPath, $AclObject, $ErrorAction) $script:WrittenAcl = $AclObject }
function Get-WindowsImage { param([switch]$Mounted,$ErrorAction) $script:QueryCalls++; if($script:QueryThrows){throw 'query failed'}; return $script:MountedImages }
function Dismount-WindowsImage { param($Path,[switch]$Discard,$ErrorAction) Require $Discard 'Cleanup attempted Save'; $script:DismountCalls.Add($Path) }
function Test-Path { param($LiteralPath) return $true }
function Get-WorkDirCandidates { return @{ Path='C:\mock\servicing' } }
function Get-ChildItem { param($LiteralPath,[switch]$Force,$ErrorAction) $script:ChildReads++; throw 'Unexpected filesystem inventory in mocked mount-guard test' }
$PendingDeploymentPath = 'C:\mock\pending-deployment.json'
$PendingDeploymentDir = 'C:\mock\PendingDeployment'

Check 'ISO UTC timestamps round-trip as exact strings on both PowerShell runtimes' {
    $stamp = '2026-10-23T12:34:56.1234567Z'
    $parsed = ConvertFrom-DeploymentJson -Json ('{"UpdatedUtc":"' + $stamp + '"}')
    Require ($parsed.UpdatedUtc -is [string] -and $parsed.UpdatedUtc -ceq $stamp) 'UTC timestamp changed type or text.'
}
foreach ($entry in @(@{ Name='Test-VolumeEncrypted'; Expected=$false }, @{ Name='Test-VolumeAccessibleForResize'; Expected=$true })) {
    Check "$($entry.Name) falls back when cmdlet is absent under ErrorAction Stop" {
        Require ((& $entry.Name -MountPoint 'mock:') -eq $entry.Expected) 'Absent-cmdlet fallback failed.'
        Require ($script:CmdletCalls -eq 0 -and $script:BdeCalls -eq 1) 'An unavailable cmdlet was called.'
    }
    Check "$($entry.Name) falls back when installed cmdlet throws" {
        $script:CmdletAvailable = $true; $script:CmdletThrows = $true
        Require ((& $entry.Name -MountPoint 'mock:') -eq $entry.Expected) 'Throwing-cmdlet fallback failed.'
    }
    Check "$($entry.Name) refuses an unknown explicit VolumeStatus" {
        $script:CmdletAvailable = $true
        $script:Metadata = [pscustomobject]@{ VolumeStatus='Unknown'; ProtectionStatus='Off'; LockStatus='Unlocked' }
        Require ($null -eq (& $entry.Name -MountPoint 'mock:')) 'Unknown status was accepted.'
        Require ($script:BdeCalls -eq 0) 'Unknown explicit status was weakened by text fallback.'
    }
    Check "$($entry.Name) returns indeterminate when both providers fail" {
        $script:BdeThrows = $true
        Require ($null -eq (& $entry.Name -MountPoint 'mock:')) 'Provider failure was treated as safe.'
    }
}
Check 'unlocked encrypted data can resize but cannot host accepted WinRE' {
    $script:CmdletAvailable = $true
    $script:Metadata = [pscustomobject]@{ VolumeStatus='FullyEncrypted'; ProtectionStatus='On'; LockStatus='Unlocked' }
    Require ((Test-VolumeEncrypted -MountPoint 'mock:') -eq $true) 'Encryption was missed.'
    Require ((Test-VolumeAccessibleForResize -MountPoint 'mock:') -eq $true) 'Unlocked resize was wrongly refused.'
}
foreach ($entry in @(@{Sid='S-1-5-18'; Allowed=$true},@{Sid='S-1-5-32-544'; Allowed=$true},@{Sid='S-1-5-11'; Allowed=$false})) {
    Check "deployment store create rights for $($entry.Sid)" {
        $script:Acl.Access = @([pscustomobject]@{ IdentityReference=[Security.Principal.SecurityIdentifier]::new($entry.Sid); PropagationFlags=0; AccessControlType=[Security.AccessControl.AccessControlType]::Allow; FileSystemRights=[Security.AccessControl.FileSystemRights]::WriteData })
        Require ((Test-DeploymentStoreTrusted -Path 'mock') -eq $entry.Allowed) 'Create-new rights trust decision was wrong.'
    }
}
Check 'store rejects shared trust failure' { $script:Trusted=$false; Require (-not (Test-DeploymentStoreTrusted -Path 'mock')) 'Untrusted store accepted.' }
Check 'store ignores inherit-only rights that do not apply to itself' {
    $script:Acl.Access = @([pscustomobject]@{ PropagationFlags=[Security.AccessControl.PropagationFlags]::InheritOnly; AccessControlType=[Security.AccessControl.AccessControlType]::Allow; FileSystemRights=[Security.AccessControl.FileSystemRights]::FullControl })
    Require (Test-DeploymentStoreTrusted -Path 'mock') 'Inherit-only rule applied to the directory.'
}
Check 'deployment file security explicitly sets trusted owner and two full-control rules' {
    Set-DeploymentFileSecurity -Path $PendingDeploymentPath
    Require ($script:WrittenAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'File owner was not Administrators.'
    Require $script:WrittenAcl.AreAccessRulesProtected 'File DACL still inherits.'
    $rules = @($script:WrittenAcl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))
    Require ($rules.Count -eq 2 -and @($rules | Where-Object { $_.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') }).Count -eq 0) 'File rules contain an unexpected principal.'
}
Check 'deployment ACL writes refuse arbitrary paths' {
    $failed=$false; try { Set-DeploymentFileSecurity -Path 'C:\other\user.txt' } catch { $failed=$true }
    Require ($failed -and $null -eq $script:WrittenAcl) 'An unrelated file ACL was modified.'
}
Check 'deployment ACL writes refuse reparse ancestry' {
    $script:SafePath=$false; $failed=$false
    try { Set-DeploymentFileSecurity -Path $PendingDeploymentPath } catch { $failed=$true }
    Require ($failed -and $null -eq $script:WrittenAcl) 'Unsafe ancestry reached an ACL write.'
}
foreach ($reason in @('DryRun','NoLock','NoOwnership')) {
    Check "final image cleanup does nothing for $reason" {
        if($reason -eq 'DryRun'){$script:DryRun=$true}
        if($reason -eq 'NoLock'){$script:ProgramLockStream=$null}
        if($reason -eq 'NoOwnership'){$script:OwnsWimWork=$false}
        Dismount-OwnedWinREImages -Workspace 'C:\mock\servicing'
        Require ($script:QueryCalls -eq 0 -and $script:DismountCalls.Count -eq 0) 'Cleanup ran without exclusive ownership or during DryRun.'
    }
}
Check 'final image cleanup matches exact mount path, source image and index' {
    $script:MountedImages=@(
        [pscustomobject]@{Path='C:\mock\servicing\mount';ImagePath='C:\mock\servicing\base.wim';ImageIndex=1},
        [pscustomobject]@{Path='C:\mock\PendingDeployment\preserve_mount';ImagePath='unrelated.wim';ImageIndex=1},
        [pscustomobject]@{Path='C:\mock\servicing\mount';ImagePath='C:\mock\servicing\base.wim';ImageIndex=2}
    )
    Dismount-OwnedWinREImages -Workspace 'C:\mock\servicing'
    Require ($script:DismountCalls.Count -eq 1 -and $script:DismountCalls[0] -eq 'C:\mock\servicing\mount') 'Cleanup touched an unrelated image/index.'
}
Check 'failed final mount enumeration retains recovery task' {
    $script:QueryThrows=$true
    Dismount-OwnedWinREImages -Workspace 'C:\mock\servicing'
    Require ($script:ResumeTaskShouldPersist -and $script:DismountCalls.Count -eq 0) 'Unknown mount state was treated as clean.'
}
Check 'completed workspace with mounted image is retained before inventory or deletion' {
    $script:MountedImages=@([pscustomobject]@{Path='C:\mock\servicing\mount'})
    Remove-CompletedServicingWorkspace -Path 'C:\mock\servicing'
    Require ($script:nonFatalWarning -and $script:ChildReads -eq 0) 'Mounted workspace was inventoried for removal.'
}
Check 'completed workspace is retained when mount enumeration fails' {
    $script:QueryThrows=$true
    Remove-CompletedServicingWorkspace -Path 'C:\mock\servicing'
    Require ($script:nonFatalWarning -and $script:ChildReads -eq 0) 'Unverifiable workspace was inventoried for removal.'
}
Write-Output "Deployment provider regressions: $script:passed passed. Native tools and ACL writes mocked."
