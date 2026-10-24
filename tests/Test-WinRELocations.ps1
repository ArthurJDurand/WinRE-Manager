<#
.SYNOPSIS
    Real location-helper and deployment sequencing regressions for v50 patch 5.
.DESCRIPTION
    Imports the deployment-safety fixtures (and reruns their prerequisites),
    then replaces mocked location helpers with extracted production functions.
    Storage, filesystem metadata, WIM, native tools and persistence remain
    mocked. No production main, real storage query or filesystem write runs.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Test-DeploymentSafety.ps1') | Out-Null
$script:LocationPassed=0
foreach($name in @('ConvertFrom-WinRELocation','Get-WinRELocationFromInfo','Resolve-WinRELocationToPartition',
    'Get-WinREState','Test-WinRELocationMatches','Get-RegisteredDeploymentImage','Get-RegisteredWinREFingerprint',
    'Assert-RegisteredWinREUnchanged','Restore-PreviousWinRERoute','Invoke-BackupAction','Invoke-RestoreAction')) {
    $definition=$source.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $definition){throw "Missing production function $name"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:RecoveryId='\\?\Volume{44444444-4444-4444-4444-444444444444}\'
$script:OSId='\\?\Volume{33333333-3333-3333-3333-333333333333}\'
function Reset-LocationFixture {
    Reset-Fixture; Set-TransitionFixture
    $script:Fixture.OS | Add-Member -NotePropertyName DriveLetter -NotePropertyValue 'C' -Force
    $script:Fixture.Recovery.DriveLetter='R'
    $script:Fixture.OSVolume.UniqueId=$script:OSId
    $script:Fixture.Volume.UniqueId=$script:RecoveryId
    $script:Fixture.Volume | Add-Member -NotePropertyName DriveLetter -NotePropertyValue 'R' -Force
    $script:Fixture.OSVolume | Add-Member -NotePropertyName DriveLetter -NotePropertyValue 'C' -Force
    $script:Fixture.Record.OSVolumeId=$script:OSId
    $script:Fixture.Record.Mode='Managed'
    $script:Fixture.Route=@{Status='Enabled';Location='R:\Recovery\WindowsRE';Version='10.0.1.0'}
    $script:Fixture.Record.PreviousLocation=$script:Fixture.Route.Location
    $script:Fixture.FolderVolumeMismatch=$false
    $script:Fixture.AttributeFailure=$false
    $script:Fixture.ReparsePath=$null
    $script:Fixture.MissingPath=$null
    $script:Fixture.FileHashes=@{'R:\Recovery\WindowsRE\winre.wim'=('B'*64)}
    $script:Fixture.NoDirectImage=$false
    $script:Fixture.AfterFindUnresolved=$false
    $script:Fixture.AfterReadyUnresolved=$false
    $script:Fixture.RegistryLocation=$null
    $script:Fixture.InfoOverride=$null
    $script:Fixture.PrepareCalls=0
    $script:Fixture.Applicable=$true
    $script:Fixture.MountedImages=@()
    $script:Fixture.ReimagePaths=[Collections.Generic.List[string]]::new()
    $script:Fixture.LastRestoreTarget=$null
    $script:Fixture.LastRestoreHash=$null
}
function Location-Check {
    param($Name,[scriptblock]$Body)
    Reset-LocationFixture
    & $Body
    $script:LocationPassed++; Write-Output "PASS: $Name"
}
function Need {param($Condition,$Message) if(-not $Condition){throw $Message}}
function Join-Path { param($Path,$ChildPath) [IO.Path]::Combine([string]$Path,[string]$ChildPath) }
function Write-Narration { param($Message) }
function Remove-RestoreWorkspaceSafely {param($Path) $script:Calls.Add('GuardRestoreWorkspace'); return $true}
function New-Item {param($Path,$ItemType,[switch]$Force,$ErrorAction) $script:Calls.Add('MockCreateRestoreWorkspace')}
function Get-Partition {
    [CmdletBinding()]param($DiskNumber,$PartitionNumber,$Volume,$DriveLetter)
    if($PSBoundParameters.ContainsKey('DriveLetter')) {
        if($DriveLetter -eq 'R'){return $script:Fixture.Recovery}
        if($DriveLetter -eq 'C'){return $script:Fixture.OS}
        return $null
    }
    if($Volume){if($Volume.UniqueId -eq $script:RecoveryId){return $script:Fixture.Recovery}; return $script:Fixture.OS}
    if($PSBoundParameters.ContainsKey('PartitionNumber')){return $script:Fixture.Partitions | Where-Object {$_.PartitionNumber -eq $PartitionNumber -and $_.DiskNumber -eq $DiskNumber}}
    return $script:Fixture.Partitions
}
function Get-Volume {
    [CmdletBinding()]param($Partition,$DriveLetter,$UniqueId,$FilePath)
    if($FilePath){
        if($script:Fixture.FolderVolumeMismatch){return $script:Fixture.OSVolume}
        if($FilePath -like 'R:*'){return $script:Fixture.Volume}
        return $script:Fixture.OSVolume
    }
    if($Partition){if($Partition.PartitionNumber -eq 4){return $script:Fixture.Volume}; return $script:Fixture.OSVolume}
    if($DriveLetter -eq 'R' -or $UniqueId -eq $script:RecoveryId){return $script:Fixture.Volume}
    if($DriveLetter -eq 'C' -or $UniqueId -eq $script:OSId){return $script:Fixture.OSVolume}
    return $null
}
function Get-WinREPathAttributes {
    param($Path)
    if($script:Fixture.AttributeFailure){throw 'mock inaccessible registered folder'}
    if($Path -eq $script:Fixture.MissingPath){return $null}
    if($Path -eq $script:Fixture.ReparsePath){return ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)}
    return [IO.FileAttributes]::Directory
}
function Get-ItemProperty {param($Path,$Name,$ErrorAction) [pscustomobject]@{WinRELocation=$script:Fixture.RegistryLocation}}
function cmd {
    param($Switch,$Command)
    $global:LASTEXITCODE=0
    if($Command -like '*reagentc /info*'){
        if($script:Fixture.InfoOverride){return $script:Fixture.InfoOverride}
        return @("Windows RE status: $($script:Fixture.Route.Status)","Windows RE location: $($script:Fixture.Route.Location)",'Windows RE Version: 10.0.1.0')
    }
    if($Command -like '*reagentc /disable*'){
        $script:Calls.Add('DisableOriginalRoute'); $script:Fixture.Route.Status='Disabled'; $script:Fixture.OldRouteIntact=$false; return 'mock disabled'
    }
    if($Command -like '*reagentc /setreimage*'){
        $script:Calls.Add('RegisterTarget')
        if($Command -match '/path\s+"(?<path>[^"]+)"'){$path=$Matches.path}
        elseif($Command -match '/path\s+(?<path>.+?)\s+2>&1'){$path=$Matches.path}
        else{throw 'Mock could not read the registration path.'}
        if($path.EndsWith('\\')){$path=$path.Substring(0,$path.Length-1)}
        $script:Fixture.ReimagePaths.Add($path)
        $script:Fixture.Route.Location=$path
        return 'mock registered'
    }
    throw "Unexpected mocked native command $Command"
}
function Invoke-ReagentcEnable {
    param([switch]$AllowTempLetter,$Partition,$ReRegisterPath)
    $script:Calls.Add('EnableTarget'); $script:Fixture.LastReRegisterPath=$ReRegisterPath
    $script:Fixture.Route.Status='Enabled'; $script:Fixture.Route.Location=$ReRegisterPath
    return 'ok'
}
function Ensure-RecoveryPartitionAccess {
    param($TargetDir)
    $folder=ConvertFrom-WinRELocation -Location $TargetDir
    if(-not $folder){return $null}
    if($folder.Kind -eq 'DriveLetter'){return $folder.NormalizedPath}
    $letter=if(($folder.Kind -eq 'GlobalRoot' -and $folder.PartitionNumber -eq 3) -or $folder.VolumeId -eq $script:OSId){'C'}else{'R'}
    return "${letter}:\"+$folder.RelativePath
}
function Get-LiveWimHash {
    param($WimPath)
    if($WimPath -eq $script:Fixture.Record.CandidatePath){return $script:Fixture.Hash}
    if($WimPath -eq 'R:\Recovery\WindowsRE\winre.wim' -and $script:Fixture.TargetHash){return $script:Fixture.TargetHash}
    if($script:Fixture.NoDirectImage -and $WimPath -eq 'R:\Recovery\WindowsRE\winre.wim'){return $null}
    return $script:Fixture.FileHashes[$WimPath]
}
function Find-SuitableRecoveryPartition {
    param($RequiredWimSizeMB)
    $script:Calls.Add('FindTarget')
    if($script:Fixture.AfterFindUnresolved){$script:Fixture.Route.Location='unsupported-active-route'}
    return @{DiskNumber=0;PartitionNumber=4;DriveLetter='R';Partition=$script:Fixture.Recovery}
}
function Set-RecoveryPartitionReadyForWinRE {
    param($DiskNumber,$PartitionNumber)
    $script:Calls.Add('ReadyTarget'); $script:Fixture.PrepareCalls++
    if($script:Fixture.AfterReadyUnresolved){$script:Fixture.Route.Location='unsupported-active-route'}
    return $true
}

foreach($path in @('R:\Recovery\WindowsRE','\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE',($script:RecoveryId+'Recovery\WindowsRE'))) {
    Location-Check "real parser/resolver accepts $path" {
        $parsed=ConvertFrom-WinRELocation -Location $path
        Need ($parsed.RelativePath -eq 'Recovery\WindowsRE') 'Folder suffix was lost.'
        $part=Resolve-WinRELocationToPartition -Location $path
        Need ($part.DiskNumber -eq 0 -and $part.PartitionNumber -eq 4) 'Wrong resolved partition.'
    }
}
foreach($path in @('R:Recovery\WindowsRE','R:','\\server\share\Recovery','junk harddisk0\partition4\Recovery',
    'R:\Recovery\..\WindowsRE','R:\.\Recovery','R:\Recovery.','R:\Recovery ', 'R:\Recovery:stream',
    'R:\Recovery\*.wim','R:/Recovery','R:\%TEMP%','R:\Recovery!name',
    '\\?\Volume{not-a-guid}\Recovery','\\?\GLOBALROOT\device\harddisk0\partition999999999999\Recovery')) {
    Location-Check "real parser refuses ambiguous location $path" {
        Need ($null -eq (ConvertFrom-WinRELocation -Location $path)) 'Ambiguous location was accepted.'
        Need ($null -eq (Resolve-WinRELocationToPartition -Location $path)) 'Ambiguous location was resolved.'
    }
}
foreach($path in @('R:\Custom Recovery\WindowsRE','\\?\GLOBALROOT\device\harddisk0\partition4\Custom Recovery\WindowsRE',($script:RecoveryId+'Custom Recovery\WindowsRE'))) {
    Location-Check "state reader preserves complete location $path" {
        $script:Fixture.Route.Location=$path
        Need ((Get-WinREState).Location -eq $path) 'State reader truncated the directory.'
    }
}
Location-Check 'state reader ignores other recovery-image fields' {
    $script:Fixture.InfoOverride=@('Windows RE status: Enabled','Windows RE location:','Recovery image location: C:\Unrelated')
    Need ($null -eq (Get-WinREState).Location) 'Other recovery image was taken as the WinRE location.'
}
Location-Check 'native path argument quotes spaces without changing the directory' {
    Need ((ConvertTo-WinREPathArgument 'R:\Custom Recovery\WindowsRE') -ceq '"R:\Custom Recovery\WindowsRE"') 'Directory with spaces was not quoted.'
}
Location-Check 'native path argument doubles a root trailing backslash before its closing quote' {
    Need ((ConvertTo-WinREPathArgument 'R:\') -ceq '"R:\\"') 'Root trailing backslash would escape the closing quote.'
}
Location-Check 'native path argument refuses shell expansion aliases' {
    $refused=$false; try{ConvertTo-WinREPathArgument 'R:\%TEMP%' | Out-Null}catch{$refused=$true}
    Need $refused 'Shell-expanding path reached command construction.'
}
Location-Check 'state reader uses complete registry fallback without inventing a folder' {
    $script:Fixture.InfoOverride=@('Windows RE status: Disabled','Windows RE location:')
    $script:Fixture.RegistryLocation='R:\Custom Recovery'
    Need ((Get-WinREState).Location -eq 'R:\Custom Recovery') 'Registry folder was changed.'
}
foreach($reportedField in @('Blank','Absent')) {
    Location-Check "Enabled $reportedField location cannot use a stale registry route for deployment" {
        $script:Fixture.InfoOverride=@('Windows RE status: Enabled')
        if($reportedField -eq 'Blank'){$script:Fixture.InfoOverride += 'Windows RE location:'}
        $script:Fixture.RegistryLocation='C:\Recovery\WindowsRE'
        Need ($null -eq (Get-WinREState).Location) 'Stale registry value masked the unknown Enabled route.'
        $code=Invoke-PendingWinREDeployment -Record $script:Fixture.Record
        Need ($code -in @($EXIT_WARNING,$EXIT_FATAL)) 'An unknown Enabled route unexpectedly succeeded.'
        Need (-not $script:Calls.Contains('FindTarget') -and -not $script:Calls.Contains('ReadyTarget') -and
            -not $script:Calls.Contains('CopyToTarget') -and -not $script:Calls.Contains('DisableOriginalRoute')) 'Unknown Enabled route reached target selection or mutation.'
        Need $script:PendingDeploymentPresent 'The pending deployment lost ownership of its retained recovery material.'
    }
}
Location-Check 'invalid reported location cannot be hidden by a stale valid registry value' {
    $script:Fixture.InfoOverride=@('Windows RE status: Enabled','Windows RE location: R:\%TEMP%')
    $script:Fixture.RegistryLocation='C:\Recovery\WindowsRE'
    $observed=Get-WinREState
    Need ($observed.Location -eq 'R:\%TEMP%' -and $null -eq (Resolve-WinRELocationToPartition $observed.Location)) 'Stale registry location masked the invalid reported route.'
    $code=Invoke-PendingWinREDeployment -Record $script:Fixture.Record
    Need ($code -in @($EXIT_WARNING,$EXIT_FATAL) -and -not $script:Calls.Contains('FindTarget') -and -not $script:Calls.Contains('ReadyTarget') -and -not $script:Calls.Contains('CopyToTarget')) 'Masked location reached target preparation.'
}
Location-Check 'mixed root spellings match only the same partition and folder' {
    Need (Test-WinRELocationMatches 'R:\Recovery\WindowsRE' ($script:RecoveryId+'recovery\windowsre\')) 'Equivalent folder forms did not match.'
    Need (-not (Test-WinRELocationMatches 'R:\Recovery\WindowsRE' 'R:\OtherFolder')) 'Different folders compared equal.'
    Need (-not (Test-WinRELocationMatches 'R:\Recovery\WindowsRE' 'C:\Recovery\WindowsRE')) 'Different partitions compared equal.'
    Need (-not (Test-WinRELocationMatches 'R:\' 'R:\Recovery\WindowsRE')) 'Literal root was guessed to mean the standard folder.'
    Need (-not (Test-WinRELocationMatches 'invalid' 'invalid')) 'Identical invalid strings passed verification.'
}
Location-Check 'DOS directory mount mismatch cannot masquerade as drive-root partition' {
    $script:Fixture.FolderVolumeMismatch=$true
    Need ($null -eq (Resolve-WinRELocationToPartition 'R:\Recovery\WindowsRE')) 'Wrong underlying volume was accepted.'
}
foreach($path in @('R:\Recovery\WindowsRE','\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE',($script:RecoveryId+'Recovery\WindowsRE'))) {
    Location-Check "all root forms refuse a reparse folder: $path" {
        $script:Fixture.ReparsePath=$script:RecoveryId+'Recovery'
        Need ($null -eq (Resolve-WinRELocationToPartition $path)) 'Reparse folder was followed.'
    }
}
Location-Check 'unreadable folder metadata is not guessed safe' {
    $script:Fixture.AttributeFailure=$true
    Need ($null -eq (Resolve-WinRELocationToPartition 'R:\Recovery\WindowsRE')) 'Unverifiable metadata was accepted.'
}
Location-Check 'proven missing registered folder retains its known partition identity' {
    $script:Fixture.MissingPath=$script:RecoveryId+'Recovery'
    Need ((Resolve-WinRELocationToPartition 'R:\Recovery\WindowsRE').PartitionNumber -eq 4) 'A missing folder blocked repair of its known partition.'
}
Location-Check 'missing physical volume root is not treated as a repairable child absence' {
    $script:Fixture.MissingPath=$script:RecoveryId
    Need ($null -eq (Resolve-WinRELocationToPartition 'R:\Recovery\WindowsRE')) 'Missing volume root was accepted.'
}
Location-Check 'registered reader never substitutes a nested decoy WIM' {
    $script:Fixture.NoDirectImage=$true
    $script:Fixture.FileHashes['R:\Recovery\WindowsRE\Recovery\WindowsRE\winre.wim']=('D'*64)
    Need ($null -eq (Get-RegisteredDeploymentImage -WinREState $script:Fixture.Route)) 'Nested unrelated WIM was accepted.'
}
Location-Check 'literal partition-root route reads only the WIM at that root' {
    $script:Fixture.Route.Location='\\?\GLOBALROOT\device\harddisk0\partition4\'
    Need ($null -eq (Get-RegisteredDeploymentImage -WinREState $script:Fixture.Route)) 'Default folder was substituted for a root route.'
    $script:Fixture.FileHashes['R:\winre.wim']=('D'*64)
    Need ((Get-RegisteredDeploymentImage -WinREState $script:Fixture.Route).Hash -eq ('D'*64)) 'Literal root WIM was not read.'
}
Location-Check 'fingerprint accepts equivalent forms but rejects a folder switch with identical bytes' {
    $captured=Get-RegisteredWinREFingerprint -WinREState (Get-WinREState) -RegisteredWimPath 'R:\Recovery\WindowsRE\winre.wim' -RegisteredWimHash ('B'*64)
    $script:Fixture.Route.Location=$script:RecoveryId+'Recovery\WindowsRE'
    Need (Assert-RegisteredWinREUnchanged -Captured $captured -CalledFrom 'location regression') 'Equivalent route was falsely marked changed.'
    $script:Fixture.Route.Location='R:\OtherFolder'; $script:Fixture.FileHashes['R:\OtherFolder\winre.wim']=('B'*64)
    Need (-not (Assert-RegisteredWinREUnchanged -Captured $captured -CalledFrom 'location regression')) 'Folder switch with equal bytes was missed.'
}
foreach($mode in @('Managed','Preserved')) {
    Location-Check "actual DOS active-target deployment disables before copying ($mode)" {
        $script:Fixture.Record.Mode=$mode
        $code=Invoke-PendingWinREDeployment -Record $script:Fixture.Record
        Need ($code -eq $EXIT_SUCCESS) "DOS-form deployment did not commit (code=$code). $($script:Calls -join ', ')"
        Need ($script:Calls.IndexOf('DisableOriginalRoute') -ge 0 -and $script:Calls.IndexOf('DisableOriginalRoute') -lt $script:Calls.IndexOf('CopyToTarget')) 'Active target copy preceded disable.'
        Need (-not $script:PendingDeploymentPresent -and $script:Calls.Contains('RetireJournal')) 'Verified deployment did not retire journal.'
        if($mode -eq 'Preserved'){Need ($script:Fixture.SavedState.ForeignSourceAcceptedHash -eq ('A'*64) -and $script:Fixture.SavedState.CurrentImageHash -ne ('A'*64)) 'Preserved deployment invented ownership.'}
    }
}
foreach($point in @('Entry','AfterFind','AfterReady')) {
    Location-Check "unresolved Enabled route refuses target copying at $point" {
        if($point -eq 'Entry'){$script:Fixture.Route.Location='unsupported-active-route';$script:Fixture.Record.PreviousLocation=$script:Fixture.Route.Location}
        if($point -eq 'AfterFind'){$script:Fixture.AfterFindUnresolved=$true}
        if($point -eq 'AfterReady'){$script:Fixture.AfterReadyUnresolved=$true}
        $code=Invoke-PendingWinREDeployment -Record $script:Fixture.Record
        Need ($code -in @($EXIT_WARNING,$EXIT_FATAL)) 'Unresolved route unexpectedly succeeded.'
        Need (-not $script:Calls.Contains('CopyToTarget') -and -not $script:Calls.Contains('DisableOriginalRoute') -and -not $script:Calls.Contains('RegisterTarget')) 'Unresolved active route reached a mutation.'
        if($point -eq 'Entry'){Need (-not $script:Calls.Contains('FindTarget')) 'Unresolved entry reached selection.'}
        if($point -ne 'AfterReady'){Need (-not $script:Calls.Contains('ReadyTarget')) 'Unresolved route reached preparation.'}
        Need $script:PendingDeploymentPresent 'Pending source owner was lost.'
    }
}
Location-Check 'known partition with missing registered folder can be repaired from the pending candidate' {
    $script:Fixture.MissingPath=$script:RecoveryId+'Recovery'; $script:Fixture.NoDirectImage=$true
    Need ((Invoke-PendingWinREDeployment -Record $script:Fixture.Record) -eq $EXIT_SUCCESS) 'Repairable missing folder prevented verified deployment.'
    Need ($script:Calls.IndexOf('DisableOriginalRoute') -lt $script:Calls.IndexOf('CopyToTarget') -and -not $script:PendingDeploymentPresent) 'Missing-folder repair bypassed safe sequencing or retained an incomplete commit.'
}
Location-Check 'backup refuses a nested or OS fallback substitute for unreadable registered WIM' {
    $script:Fixture.NoDirectImage=$true
    $code=Invoke-BackupAction -BackupPath 'mock-backup-root'
    Need ($code -eq $EXIT_WARNING -and -not $script:Calls.Contains('CopyCandidate')) 'Backup did not stop at exact registered-source refusal.'
}

# Restore's file-copy provider remains mocked; the actual action must choose
# the exact registered file and supply its original expected backup hash.
function Deploy-WimTransactional {
    param($SourceWim,$TargetPath,$TargetDescription,$ExpectedSourceHash)
    $script:Calls.Add('RestoreTransactional')
    $script:Fixture.LastRestoreTarget=$TargetPath; $script:Fixture.LastRestoreHash=$ExpectedSourceHash
    $script:Fixture.FileHashes[$TargetPath]=$ExpectedSourceHash
    return $true
}
foreach($location in @('R:\Custom Recovery\WindowsRE','R:\','C:\Custom Recovery')) {
    Location-Check "Restore uses the exact registered folder: $location" {
        $script:Fixture.Route.Location=$location
        $script:Fixture.Encrypted=$false
        $script:Fixture.Paths['C:\MockBackup\backup.json']=$false
        $script:Fixture.FileHashes['C:\MockBackup\winre.wim']=('A'*64)
        $parsed=ConvertFrom-WinRELocation $location
        $target=Join-Path $parsed.NormalizedPath 'winre.wim'
        $script:Fixture.FileHashes[$target]=('B'*64)
        $code=Invoke-RestoreAction -BackupPath 'C:\MockBackup'
        Need ($code -eq $EXIT_SUCCESS -and $script:Fixture.LastRestoreTarget -eq $target) 'Restore redirected the backup to another folder or did not complete.'
        Need ($script:Fixture.LastRestoreHash -eq ('A'*64)) 'Restore lost its original expected backup hash.'
        $expectedRoute=if($location -like 'C:*'){$parsed.NormalizedPath}else{'\\?\GLOBALROOT\device\harddisk0\partition4\'+$parsed.RelativePath}
        Need ($script:Fixture.ReimagePaths.Count -eq 1 -and $script:Fixture.ReimagePaths[0] -eq $expectedRoute) 'Restore registered a different folder.'
    }
}
Location-Check 'previous-route restoration keeps a custom folder including spaces' {
    $script:Fixture.Route.Status='Disabled'; $script:Fixture.Route.Location='R:\Wrong Folder'
    Need (Restore-PreviousWinRERoute -PreviousState @{Status='Enabled';Location='R:\Custom Recovery\WindowsRE'}) 'Custom previous route did not restore.'
    Need ($script:Fixture.LastReRegisterPath -eq '\\?\GLOBALROOT\device\harddisk0\partition4\Custom Recovery\WindowsRE') 'Rollback repair lost the prior folder.'
}
Write-Output "WinRE location regressions: $script:LocationPassed passed. Real location and deployment functions; all providers mocked."
