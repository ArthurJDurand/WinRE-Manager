<#
.SYNOPSIS
    Isolated permanent-maintenance installer trust and publication regressions.
.DESCRIPTION
    Executes the actual CMD installer payload and shared trust helper. Static IO
    boundaries are replaced with in-memory providers; task providers are mocked.
    No installed copy, task, WinRE route, map, partition, VM or ACL is changed.
    A temporary CMD export probe executes only SET statements and an environment
    serializer. Its files are deleted individually after the probe.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path $PSScriptRoot -Parent
$wrapperPath = Join-Path $repoPath 'scripts\WinRE-Manager.cmd'
$lines = [IO.File]::ReadAllLines($wrapperPath)
$script:Passed = 0

function Check {
    param($Name,[scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Output "PASS: $Name"
}
function Parse-Text {
    param($Text)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
    return $ast
}
function Set-Value {
    param($Name,$Start=0)
    $prefix='set "'+$Name+'='
    for($i=$Start;$i -lt $lines.Count;$i++){
        if($lines[$i].StartsWith($prefix)){return $lines[$i].Substring($prefix.Length,$lines[$i].Length-$prefix.Length-1)}
    }
    throw "Missing CMD assignment $Name"
}
function Function-Node {
    param($Ast,$Name)
    $found=$Ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if(-not $found){throw "Missing actual payload helper $Name"}
    return $found
}

$helperText=Set-Value 'PATH_TRUST_HELPER'
$installLabel=[array]::IndexOf($lines,':set_task_install_command')
$installText=Set-Value 'TARGET_COMMAND' ($installLabel+1)
$installAst=Parse-Text $installText
$helperAst=Parse-Text $helperText
$main=$installAst.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if(-not (Test-Path -LiteralPath $src ')},$true)
if(-not $main){throw 'Actual installer main boundary not found'}
$uiOffset=$installText.IndexOf("Write-Host ''; Write-Host 'Automatic WinRE maintenance installed.'")
if($uiOffset -lt 0){throw 'Actual installer completion boundary not found'}
$installCore=$installText.Substring(0,$uiOffset)
$providerDefinitions=@()

# Keep each helper's control flow, guards, disposal, hashes and security policy.
# Replace only its static filesystem API call or corresponding WinPS constructor.
$providerReplacements=@{
    _NewDirectory=@{
        '[IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($p),$a)'='(_MockNewDirectory $p $a)'
        '[IO.Directory]::CreateDirectory($p,$a)'='(_MockNewDirectory $p $a)'
    }
    _Stage=@{
        "[IO.File]::Open(`$s,'Open','Read','Read')"='(_MockOpenSource $s)'
        '[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($p),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::None,$a)'='(_MockCreateStage $p $a)'
        'New-Object IO.FileStream($p,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::None,$a)'='(_MockCreateStage $p $a)'
    }
    _Publish=@{
        '[IO.File]::Replace($s,$d,$null)'='(_MockPublish $s $d $true)'
        '[IO.File]::Move($s,$d)'='(_MockPublish $s $d $false)'
    }
    _OpenRead=@{
        "[IO.File]::Open(`$p,'Open','Read','Read')"='(_MockOpenFinal $p)'
    }
    _DeleteStage=@{'[IO.File]::Delete($p)'='(_MockDeleteStage $p)'}
}
foreach($name in $providerReplacements.Keys){
    $definition=(Function-Node $installAst $name).Extent.Text
    foreach($old in $providerReplacements[$name].Keys){
        if(-not $definition.Contains($old)){throw "Static provider binding changed in $name : $old"}
        $definition=$definition.Replace($old,$providerReplacements[$name][$old])
    }
    [void](Parse-Text $definition)
    $providerDefinitions+=$definition
}
$providerDefinitions+='function _Failure($e){ throw $e }'
$instrumented=$installCore.Insert($main.Extent.StartOffset,(($providerDefinitions -join '; ')+'; '))
[void](Parse-Text ($helperText+'; '+$instrumented))

function New-Ace {
    param($Sid,$Rights,$Propagation='None',$Type='Allow')
    return [pscustomobject]@{
        IdentityReference=(New-Object Security.Principal.SecurityIdentifier($Sid))
        FileSystemRights=[Security.AccessControl.FileSystemRights]$Rights
        PropagationFlags=[Security.AccessControl.PropagationFlags]$Propagation
        AccessControlType=$Type
    }
}
function New-Node {
    param($Path,$Directory,$Owner='S-1-5-32-544',$Hash=('B'*64))
    $node=[pscustomobject]@{
        FullName=$Path;PSIsContainer=$Directory;Attributes=[IO.FileAttributes]::Normal
        Owner=$Owner;Access=@((New-Ace 'S-1-5-18' 'FullControl'),(New-Ace 'S-1-5-32-544' 'FullControl'))
        Hash=$Hash
    }
    $node|Add-Member ScriptMethod GetOwner {param($Type) return (New-Object Security.Principal.SecurityIdentifier($this.Owner))}
    return $node
}
function Assert-NewSecurity {
    param($Acl,$Kind)
    if(-not $Acl.AreAccessRulesProtected){throw 'New object inherited an uncontrolled ACL'}
    if($Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544'){throw 'New object owner not Administrators'}
    $rules=@($Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 2){throw 'New object did not have exactly two protected ACEs'}
    foreach($rule in $rules){
        if($rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'New object ACE was not SYSTEM/Admin FullControl'}
        $expected=if($Kind -eq 'Directory'){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
        if($rule.InheritanceFlags -ne $expected){throw 'New object inheritance incorrect'}
    }
}

function Invoke-InstallCase {
    param($Case)
    $root='C:\';$programData='C:\ProgramData';$oem='C:\ProgramData\OEM';$directory='C:\ProgramData\OEM\WinRE-Manager';$destination=$directory+'\WinRE.ps1'
    $source="D:\O'Brien & Tools\WinRE.ps1"
    $wrapperPaths=[pscustomobject]@{Source=$source;InstalledScript=$destination;TaskName="Maintain Windows RE & O'Brien"}
    $script:Fixture=@{
        Case=$Case;Items=@{};AclReads=@();DirectoryCreates=0;StageCreates=0;Copies=0;Flushes=0
        StageDeletes=0;Publishes=0;Registered=0;Held=0;Disposed=0;SourceDisposed=0;StageDisposed=0
        StagePath=$null;Root=$root;Directory=$directory;Destination=$destination;Expected=('A'*64)
        OriginalAcl=$null;Task='existing-task';StageRacePath=$null
    }
    $f=$script:Fixture
    foreach($p in @($root,$programData,$oem,$directory)){$f.Items[$p]=New-Node $p $true}
    $f.Items[$root].Owner='S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $f.Items[$source]=New-Node $source $false 'S-1-5-21-1-2-3-1001'
    if(-not $Case.New){$f.Items[$destination]=New-Node $destination $false;$f.OriginalAcl=$f.Items[$destination].Access}
    if($Case.MissingDirectories){[void]$f.Items.Remove($oem);[void]$f.Items.Remove($directory)}
    if($Case.MissingRoot){[void]$f.Items.Remove($root)}
    if($Case.SourceMissing){[void]$f.Items.Remove($source)}
    if($Case.BadOwner){$f.Items[$Case.BadOwner].Owner='S-1-5-21-1-2-3-1001'}
    if($Case.BadRights){$f.Items[$Case.BadRights].Access+=New-Ace 'S-1-5-21-1-2-3-1001' $Case.Rights}
    if($Case.Reparse){$f.Items[$Case.Reparse].Attributes=[IO.FileAttributes]::ReparsePoint}
    if($Case.NotDirectory){$f.Items[$Case.NotDirectory].PSIsContainer=$false}
    if($Case.DestinationDirectory){$f.Items[$destination].PSIsContainer=$true}
    if($Case.CreateOnly){$f.Items[$directory].Access+=New-Ace 'S-1-5-32-545' 'WriteData,AppendData'}
    if($Case.InheritOnly){$f.Items[$directory].Access+=New-Ace 'S-1-3-0' 'FullControl' 'InheritOnly'}
    if($Case.DenyAce){$f.Items[$directory].Access+=New-Ace 'S-1-5-21-1-2-3-1001' 'FullControl' 'None' 'Deny'}

    function Get-Item {
        param($LiteralPath,[switch]$Force,$ErrorAction)
        if($script:Fixture.Case.ItemThrows -eq $LiteralPath){throw 'mock provider enumeration failure'}
        if(-not $script:Fixture.Items.ContainsKey($LiteralPath)){Write-Error 'mock absent object' -Category ObjectNotFound -ErrorAction Stop}
        return $script:Fixture.Items[$LiteralPath]
    }
    function Test-Path {
        param($LiteralPath,$PathType,$ErrorAction)
        if(-not $script:Fixture.Items.ContainsKey($LiteralPath)){return $false}
        return ($script:Fixture.Items[$LiteralPath].PSIsContainer -eq ($PathType -eq 'Container'))
    }
    function Get-Acl {
        param($LiteralPath,$ErrorAction)
        $script:Fixture.AclReads+=$LiteralPath
        if($script:Fixture.Case.AclThrows -eq $LiteralPath){throw 'mock ACL provider failure'}
        if(-not $script:Fixture.Items.ContainsKey($LiteralPath)){throw 'mock ACL absent object'}
        return $script:Fixture.Items[$LiteralPath]
    }
    function _MockNewDirectory {
        param($Path,$Acl)
        Assert-NewSecurity $Acl 'Directory'
        if($script:Fixture.Case.DirectoryCreateFails){throw 'mock atomic directory creation failed'}
        $script:Fixture.DirectoryCreates++
        $owner=if($script:Fixture.Case.DirectoryCreateRace){'S-1-5-21-1-2-3-1001'}else{'S-1-5-32-544'}
        $script:Fixture.Items[$Path]=New-Node $Path $true $owner
    }
    function _MockOpenSource {
        param($Path)
        if($script:Fixture.Case.SourceOpenFails){throw 'mock source open failed'}
        $stream=[pscustomobject]@{Kind='Source';Position=0}
        $stream|Add-Member ScriptMethod CopyTo {
            param($Output)
            $script:Fixture.Copies++
            if($script:Fixture.Case.CopyFails){throw 'mock source copy failed'}
            $script:Fixture.Items[$Output.Path].Hash=$script:Fixture.Expected
        }
        $stream|Add-Member ScriptMethod Dispose {$script:Fixture.SourceDisposed++}
        return $stream
    }
    function _MockCreateStage {
        param($Path,$Acl)
        Assert-NewSecurity $Acl 'File'
        $f=$script:Fixture;$f.StagePath=$Path
        if($f.Case.StageCreateRace){
            $f.Items[$Path]=New-Node $Path $false 'S-1-5-21-1-2-3-1001' ('C'*64)
            $f.StageRacePath=$Path;throw 'mock CreateNew collision'
        }
        if($f.Case.StageCreateFails){throw 'mock protected file creation failed'}
        $f.StageCreates++;$f.Items[$Path]=New-Node $Path $false 'S-1-5-32-544' ('0'*64)
        $stream=[pscustomobject]@{Kind='Stage';Path=$Path}
        $stream|Add-Member ScriptMethod Flush {param($Durable) if(-not $Durable){throw 'Staging flush was not durable'};$script:Fixture.Flushes++}
        $stream|Add-Member ScriptMethod Dispose {$script:Fixture.StageDisposed++}
        return $stream
    }
    function Get-FileHash {
        param($LiteralPath,$InputStream,$Algorithm,$ErrorAction)
        $f=$script:Fixture
        if($Algorithm -ne 'SHA256'){throw 'Installer changed hash algorithm'}
        if($LiteralPath){
            if($f.Case.StageHashThrows){throw 'mock staging hash provider failed'}
            if($f.Case.StageUntrusted){$f.Items[$LiteralPath].Owner='S-1-5-21-1-2-3-1001'}
            if($f.Case.DestinationCreateRace){$f.Items[$f.Destination]=New-Node $f.Destination $false 'S-1-5-21-1-2-3-1001' ('C'*64)}
            $h=if($f.Case.StageHashMismatch){'C'*64}else{$f.Items[$LiteralPath].Hash}
        }elseif($InputStream.Kind -eq 'Source'){
            if($InputStream.Position -ne 0){throw 'Source hash was not rewound'}
            $h=if($f.Case.MalformedSourceHash){'bad-digest'}else{$f.Expected}
        }else{
            if($f.Case.FinalHashThrows){throw 'mock final hash provider failed'}
            $h=if($f.Case.FinalHashMismatch){'C'*64}else{$f.Items[$f.Destination].Hash}
        }
        return [pscustomobject]@{Hash=$h}
    }
    function _MockPublish {
        param($Stage,$Destination,$Replace)
        $f=$script:Fixture
        if($Replace -ne (-not $f.Case.New)){throw 'Wrong atomic publication mode'}
        if($f.Case.PublishFails){throw 'mock atomic publication failed'}
        if($f.Case.PartialReplaceFailure){[void]$f.Items.Remove($Destination);throw 'mock native ReplaceFile 1176: target removed, replacement remains'}
        if($f.Case.PublishCreateRace){$f.Items[$Destination]=New-Node $Destination $false 'S-1-5-21-1-2-3-1001' ('C'*64);throw 'mock Move destination already exists'}
        if($Replace){$f.Items[$Destination].Hash=$f.Items[$Stage].Hash}else{$f.Items[$Destination]=$f.Items[$Stage];$f.Items[$Destination].FullName=$Destination}
        [void]$f.Items.Remove($Stage);$f.Publishes++
        if($f.Case.FinalUntrusted){$f.Items[$Destination].Owner='S-1-5-21-1-2-3-1001'}
        if($f.Case.FinalAncestorUntrusted){$f.Items['C:\ProgramData\OEM'].Owner='S-1-5-21-1-2-3-1001'}
    }
    function _MockOpenFinal {
        param($Path)
        if($script:Fixture.Case.FinalOpenFails){throw 'mock final file sharing failure'}
        $script:Fixture.Held++
        $stream=[pscustomobject]@{Kind='Final';Position=0}
        $stream|Add-Member ScriptMethod Dispose {$script:Fixture.Disposed++}
        return $stream
    }
    function _MockDeleteStage {
        param($Path)
        if($Path -ne $script:Fixture.StagePath){throw 'Cleanup escaped its own staging file'}
        $script:Fixture.StageDeletes++;[void]$script:Fixture.Items.Remove($Path)
    }
    function New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory) return [pscustomobject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory}}
    function New-ScheduledTaskTrigger {param([switch]$AtStartup,[switch]$Daily,$At,$DaysInterval) return [pscustomobject]@{Delay=$null}}
    function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) if($UserId -ne 'S-1-5-18'){throw 'Task not SYSTEM'};return $UserId}
    function New-ScheduledTaskSettingsSet {
        param($MultipleInstances,[switch]$StartWhenAvailable,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit)
        return [pscustomobject]@{RunOnlyIfIdle=$true;RunOnlyIfNetworkAvailable=$true;IdleSettings=[pscustomobject]@{StopOnIdleEnd=$true;RestartOnIdle=$true}}
    }
    function Register-ScheduledTask {
        param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force,$ErrorAction)
        $f=$script:Fixture
        if($f.Held -ne 1 -or $f.Disposed -ne 0){throw 'Task registration did not hold the final read handle'}
        if($Action.Argument -ne ('-NoProfile -ExecutionPolicy Bypass -File "'+$f.Destination+'"')){throw 'Installed path quoting changed'}
        if($TaskName -ne "Maintain Windows RE & O'Brien"){throw 'Task name escaping changed'}
        if($f.Case.RegistrationFails){throw 'mock task registration failure'}
        $f.Registered++;$f.Task='new-task'
    }
    function Write-Warning {param($Message)}

    $failure=$null
    try{. ([scriptblock]::Create($helperText+'; '+$instrumented))}catch{$failure=$_}
    if([bool]$failure -eq [bool]$Case.OK){throw "Unexpected installer outcome for $($Case.Name): $failure"}
    if($Case.OK){
        if($f.Registered -ne 1 -or $f.Publishes -ne 1 -or $f.Task -ne 'new-task'){throw 'Successful install failed to publish/register once'}
        if($f.Items[$destination].Hash -ne $f.Expected){throw 'Published bytes differ'}
        if(-not $Case.New -and -not [object]::ReferenceEquals($f.Items[$destination].Access,$f.OriginalAcl)){throw 'Trusted existing destination ACL was changed'}
    }elseif($f.Registered -ne 0 -or $f.Task -ne 'existing-task'){throw 'Refusal changed the scheduled task'}
    if($Case.PriorPreserved -and $f.Items[$destination].Hash -ne ('B'*64)){throw 'Preparation failure changed the prior installed bytes'}
    if($Case.NoStaging -and $f.StageCreates -ne 0){throw 'Trust refusal began staging'}
    if($Case.StageCreateRace -and ($f.StageDeletes -ne 0 -or $f.Items[$f.StageRacePath].Hash -ne ('C'*64))){throw 'CreateNew refusal deleted or changed a raced file'}
    if($Case.PublishCreateRace -and $f.Items[$destination].Hash -ne ('C'*64)){throw 'Move collision overwrote a raced destination'}
    if($Case.StageRetained -and ($f.StageDeletes -ne 0 -or -not $f.Items.ContainsKey($f.StagePath) -or $f.Items[$f.StagePath].Hash -ne $f.Expected)){throw 'Publication failure removed the verified staging file'}
    if($Case.PartialReplaceFailure -and $f.Items.ContainsKey($destination)){throw 'Partial publication fixture failed to remove its destination'}
    if($Case.StageRetained -and -not $failure.Exception.Message.Contains($f.StagePath)){throw 'Publication failure did not report its retained staging path'}
    if($Case.OK -and $f.AclReads -notcontains $root){throw 'Successful install omitted the root-specific ACL check'}
    if($f.Held -ne $f.Disposed){throw 'Final held file was not disposed'}
    if($f.StageCreates -gt 0 -and $f.SourceDisposed -ne 1){throw 'Source stream not disposed'}
    if($f.StageCreates -gt 0 -and $f.StageDisposed -ne 1){throw 'Staging stream not disposed'}
    if($Case.OK -and $f.Flushes -ne 1){throw 'Successful install did not flush staging durably'}
}

$pd='C:\ProgramData';$oem='C:\ProgramData\OEM';$dir='C:\ProgramData\OEM\WinRE-Manager';$dest=$dir+'\WinRE.ps1'
$cases=@(
    @{Name='new installation';New=$true;OK=$true},
    @{Name='trusted existing installation preserves ACL';OK=$true},
    @{Name='new directories receive protected ACLs';New=$true;MissingDirectories=$true;OK=$true},
    @{Name='create-only directory rights remain acceptable';CreateOnly=$true;OK=$true},
    @{Name='inherit-only CREATOR OWNER remains acceptable';InheritOnly=$true;OK=$true},
    @{Name='deny ACE is not treated as an allow';DenyAce=$true;OK=$true},
    @{Name='untrusted volume root owner';BadOwner='C:\';NoStaging=$true;PriorPreserved=$true},
    @{Name='volume root permits parent replacement';BadRights='C:\';Rights='DeleteSubdirectoriesAndFiles';NoStaging=$true;PriorPreserved=$true},
    @{Name='volume root permits permission changes';BadRights='C:\';Rights='ChangePermissions';NoStaging=$true;PriorPreserved=$true},
    @{Name='volume root permits taking ownership';BadRights='C:\';Rights='TakeOwnership';NoStaging=$true;PriorPreserved=$true},
    @{Name='unreadable volume root ACL';AclThrows='C:\';NoStaging=$true;PriorPreserved=$true},
    @{Name='untrusted ProgramData owner';BadOwner=$pd;NoStaging=$true;PriorPreserved=$true},
    @{Name='untrusted OEM owner';BadOwner=$oem;NoStaging=$true;PriorPreserved=$true},
    @{Name='untrusted installation owner';BadOwner=$dir;NoStaging=$true;PriorPreserved=$true},
    @{Name='untrusted existing script owner';BadOwner=$dest;NoStaging=$true;PriorPreserved=$true},
    @{Name='parent permits deletion';BadRights=$oem;Rights='DeleteSubdirectoriesAndFiles';NoStaging=$true;PriorPreserved=$true},
    @{Name='directory permits permission changes';BadRights=$dir;Rights='ChangePermissions';NoStaging=$true;PriorPreserved=$true},
    @{Name='existing file permits content writes';BadRights=$dest;Rights='WriteData';NoStaging=$true;PriorPreserved=$true},
    @{Name='existing file permits delete';BadRights=$dest;Rights='Delete';NoStaging=$true;PriorPreserved=$true},
    @{Name='volume root reparse point';Reparse='C:\';NoStaging=$true;PriorPreserved=$true},
    @{Name='ProgramData reparse point';Reparse=$pd;NoStaging=$true;PriorPreserved=$true},
    @{Name='OEM reparse point';Reparse=$oem;NoStaging=$true;PriorPreserved=$true},
    @{Name='installation reparse point';Reparse=$dir;NoStaging=$true;PriorPreserved=$true},
    @{Name='destination reparse point';Reparse=$dest;NoStaging=$true;PriorPreserved=$true},
    @{Name='ancestor is a file';NotDirectory=$oem;NoStaging=$true;PriorPreserved=$true},
    @{Name='destination is a directory';DestinationDirectory=$true;NoStaging=$true;PriorPreserved=$true},
    @{Name='unreadable parent ACL';AclThrows=$oem;NoStaging=$true;PriorPreserved=$true},
    @{Name='unreadable file ACL';AclThrows=$dest;NoStaging=$true;PriorPreserved=$true},
    @{Name='filesystem provider failure';ItemThrows=$pd;NoStaging=$true;PriorPreserved=$true},
    @{Name='missing volume root';MissingRoot=$true;NoStaging=$true;PriorPreserved=$true},
    @{Name='missing source';SourceMissing=$true;NoStaging=$true;PriorPreserved=$true},
    @{Name='new directory creation failure';New=$true;MissingDirectories=$true;DirectoryCreateFails=$true;NoStaging=$true},
    @{Name='new directory precreation race';New=$true;MissingDirectories=$true;DirectoryCreateRace=$true;NoStaging=$true},
    @{Name='source open failure';SourceOpenFails=$true;PriorPreserved=$true},
    @{Name='staging CreateNew failure';StageCreateFails=$true;PriorPreserved=$true},
    @{Name='staging CreateNew collision leaves raced file';StageCreateRace=$true;PriorPreserved=$true},
    @{Name='copy failure preserves installed bytes';CopyFails=$true;PriorPreserved=$true},
    @{Name='staging hash mismatch preserves installed bytes';StageHashMismatch=$true;PriorPreserved=$true},
    @{Name='staging hash failure preserves installed bytes';StageHashThrows=$true;PriorPreserved=$true},
    @{Name='malformed computed source hash';MalformedSourceHash=$true;PriorPreserved=$true},
    @{Name='untrusted staging file is retained';StageUntrusted=$true;PriorPreserved=$true},
    @{Name='destination appears during preparation';New=$true;DestinationCreateRace=$true},
    @{Name='Move creation collision preserves raced bytes';New=$true;PublishCreateRace=$true;StageRetained=$true},
    @{Name='Replace failure before destination mutation';PublishFails=$true;PriorPreserved=$true;StageRetained=$true},
    @{Name='partial Replace failure retains candidate after target removal';PartialReplaceFailure=$true;StageRetained=$true},
    @{Name='Move failure retains candidate';New=$true;PublishFails=$true;StageRetained=$true},
    @{Name='final file sharing failure';FinalOpenFails=$true},
    @{Name='final hash mismatch refuses task registration';FinalHashMismatch=$true},
    @{Name='final hash provider failure';FinalHashThrows=$true},
    @{Name='final file trust failure';FinalUntrusted=$true},
    @{Name='final ancestor trust failure';FinalAncestorUntrusted=$true},
    @{Name='task provider failure disposes final held file';RegistrationFails=$true}
)
foreach($case in $cases){Check $case.Name {Invoke-InstallCase $case}}

Check 'shared helper has one CMD definition and unconditional initialization' {
    if(@($lines|Where-Object {$_ -like 'set "PATH_TRUST_HELPER=*'}).Count -ne 1){throw 'Wrapper helper is duplicated'}
    if(@($lines|Where-Object {$_ -match 'function _T\('}).Count -ne 1){throw 'Trust helper body is duplicated'}
    $call=[array]::IndexOf($lines,'call :set_path_trust_helper')
    $preflight=[array]::IndexOf($lines,':menu')
    if($call -lt 0 -or $call -ge $preflight){throw 'Helper initialization is not on the unconditional startup path'}
}
Check 'shared helper retains production owner and permission policy' {
    $production=[IO.File]::ReadAllText((Join-Path $repoPath 'scripts\WinRE.ps1'))
    $pnode=Function-Node (Parse-Text $production) 'Test-PathTrustedForSystem'
    $file='C:\policy\file.ps1';$directory='C:\policy'
    foreach($kind in @('File','Directory')){
        foreach($owner in @('S-1-5-18','S-1-5-32-544','S-1-5-21-1-2-3-1001')){
            foreach($rights in @('ReadAndExecute','WriteData','AppendData','Delete','DeleteSubdirectoriesAndFiles','ChangePermissions','TakeOwnership')){
                $node=New-Node $file ($kind -eq 'Directory') $owner
                $node.Access+=New-Ace 'S-1-5-21-1-2-3-1001' $rights
                function Test-Path {param($LiteralPath,$PathType) return $true}
                function Get-Acl {param($LiteralPath,$ErrorAction) return $node}
                function Write-Log {param($Message,$Level)}
                . ([scriptblock]::Create($helperText+'; '+$pnode.Extent.Text))
                $short=if($kind -eq 'File'){'F'}else{'D'}
                if((_T $file $short) -ne (Test-PathTrustedForSystem -Path $file -Kind $kind)){throw "Trust helper policy drift: $kind/$owner/$rights"}
            }
        }
    }
}
Check 'protected security descriptors contain SYSTEM/Admin only' {
    . ([scriptblock]::Create((Function-Node $installAst '_Security').Extent.Text))
    Assert-NewSecurity (_Security 'File') 'File'
    Assert-NewSecurity (_Security 'Directory') 'Directory'
}
Check 'atomic file and directory security APIs are available' {
    if($PSVersionTable.PSEdition -eq 'Core'){
        $methods=@([IO.FileSystemAclExtensions].GetMethods()|Where-Object {$_.Name -eq 'Create'})
        if(-not @($methods|Where-Object {$_.ToString() -match 'FileStream Create.+FileSecurity'}).Count){throw 'Protected CreateNew API missing'}
        if(-not @($methods|Where-Object {$_.ToString() -match 'Void Create.+DirectorySecurity'}).Count){throw 'Protected directory API missing'}
    }elseif(-not @([IO.FileStream].GetConstructors()|Where-Object {$_.ToString() -match 'FileSecurity'}).Count){throw 'Protected WinPS FileStream constructor missing'}
}
Check 'existing objects are never assigned security descriptors' {
    if($installText -match '\bSet-Acl\b|\.SetAccessControl\('){throw 'Installer mutates existing ACLs'}
    $directories=(Function-Node $installAst '_Directories').Extent.Text
    if(-not $directories.Contains('if(-not $e)') -or -not $directories.Contains('_NewDirectory $x')){throw 'Protected directory creation is not absence-gated'}
}
Check 'publish uses Replace for existing and Move for missing targets' {
    $publish=(Function-Node $installAst '_Publish').Extent.Text
    if(-not $publish.Contains('if($replace){ [IO.File]::Replace($s,$d,$null) }else{ [IO.File]::Move($s,$d) }')){throw 'Atomic publication changed'}
    if($installText.Contains('Copy-Item')){throw 'Unsafe direct overwrite was reintroduced'}
}
Check 'actual launcher prepends helper and bounds direct process arguments' {
    $launcher=@($lines|Where-Object {$_ -like 'powershell.exe*' -and $_.Contains('$env:PATH_TRUST_HELPER')})
    if($launcher.Count -ne 1 -or -not $launcher[0].Contains("`$prefix+[string]`$env:PATH_TRUST_HELPER+'; '+[string]`$env:TARGET_COMMAND")){throw 'Launcher does not share the helper'}
    if(-not $launcher[0].Contains('$argsLine.Length -gt 30000')){throw 'Direct CreateProcess command-line guard missing'}
}
Check 'actual launcher JSON prefix preserves literal paths and task names' {
    $line=@($lines|Where-Object {$_ -like 'powershell.exe*' -and $_.Contains('$env:PATH_TRUST_HELPER')})[0]
    $start=$line.IndexOf('-Command "')+10
    $launcherAst=Parse-Text ($line.Substring($start,$line.Length-$start-1))
    $assignments=@($launcherAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst]}|Select-Object -First 3)
    if($assignments.Count -ne 3){throw 'Actual launcher prefix assignments missing'}
    $names=@('PROD_SCRIPT','INSTALLED_SCRIPT','TASK_NAME');$previous=@{}
    $expected=@{Source="D:\O'Brien & %PATH% !\WinRE.ps1";InstalledScript="C:\ProgramData\O'Brien & !\WinRE.ps1";TaskName="Maintain O'Brien & %TEMP% !"}
    try{
        foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        $env:PROD_SCRIPT=$expected.Source;$env:INSTALLED_SCRIPT=$expected.InstalledScript;$env:TASK_NAME=$expected.TaskName
        . ([scriptblock]::Create((($assignments|ForEach-Object {$_.Extent.Text}) -join '; ')))
        . ([scriptblock]::Create($prefix))
        foreach($key in $expected.Keys){if($wrapperPaths.$key -cne $expected[$key]){throw "Actual launcher changed literal $key"}}
    }finally{foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}}
}
Check 'installer refusal prints the concrete error and exits after acknowledgement' {
    $failure=Function-Node $installAst '_Failure'
    $hosts=@($failure.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host'},$true))
    if(-not @($hosts|Where-Object {$_.Extent.Text.Contains('$e.Exception.Message')}).Count){throw 'Installer error UI omits the concrete exception'}
    $exits=@($failure.FindAll({param($n) $n -is [Management.Automation.Language.ExitStatementAst]},$true))
    if($exits.Count -ne 1 -or $exits[0].Extent.Text -ne 'exit 1'){throw 'Installer failure does not exit 1'}
    $pause=$failure.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'ReadKey'},$true)
    if(-not $pause -or $pause.Extent.StartOffset -ge $exits[0].Extent.StartOffset){throw 'Installer failure window closes before acknowledgement'}
    $handler=$installAst.Find({param($n) $n -is [Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text -eq '{ _Failure $_ }'},$true)
    if(-not $handler){throw 'Installer trust/preparation refusals are not routed through the visible failure UI'}
}
Check 'publication uncertainty retains staging and reports both paths' {
    if(-not $installText.Contains('$publicationAttempted=$true; try { _Publish')){throw 'Publication attempt is not recorded before native mutation'}
    if(-not $installText.Contains('if($stageCreated -and -not $publicationAttempted)')){throw 'Uncertain publication candidate can be removed by cleanup'}
    if(-not $installText.Contains("'Install publication failed. Verify target='+`$dst+'; retained staging path (if present)='+`$stage")){throw 'Uncertain publication does not name both recovery paths'}
}
Check 'all elevated action payloads parse after macro expansion and helper prepend' {
    foreach($line in $lines|Where-Object {$_ -like 'set "TARGET_COMMAND=*'}){
        $payload=$line.Substring(20,$line.Length-21)
        $payload=[regex]::Replace($payload,'%[A-Z_]+%',"D:\O''Brien & Tools\fixture")
        [void](Parse-Text ('$wrapperPaths=$null; '+$helperText+'; '+$payload))
    }
}

Check 'actual CMD export preserves shared helper and installer payload' {
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('WinRE-Install-Export-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporary)
    $cmdPath=Join-Path $temporary 'export.cmd';$jsonPath=Join-Path $temporary 'export.json'
    try{
        $serializer='$v=@{Helper=$env:PATH_TRUST_HELPER;Payload=$env:TARGET_COMMAND}; [IO.File]::WriteAllText($env:EXPORT_JSON,($v|ConvertTo-Json -Compress))'
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($serializer))
        $cmd=@('@echo off','setlocal EnableExtensions DisableDelayedExpansion','set "PATH_TRUST_HELPER=untrusted inherited text"','call :set_path_trust_helper',('set "EXPORT_JSON='+$jsonPath+'"'),$lines[$installLabel+1],('"'+(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')+'" -NoProfile -EncodedCommand '+$encoded),'exit /b',':set_path_trust_helper',('set "PATH_TRUST_HELPER='+$helperText+'"'),'exit /b 0')
        [IO.File]::WriteAllText($cmdPath,($cmd -join "`r`n"),(New-Object Text.UTF8Encoding($false)))
        & (Join-Path $env:WINDIR 'System32\cmd.exe') /d /q /c ('"'+$cmdPath+'"')
        if($LASTEXITCODE -ne 0){throw 'Read-only CMD export probe failed'}
        $actual=[IO.File]::ReadAllText($jsonPath)|ConvertFrom-Json
        if($actual.Helper -cne $helperText -or $actual.Payload -cne $installText){throw 'CMD changed or truncated exported PowerShell text'}
    }finally{
        if([IO.File]::Exists($cmdPath)){[IO.File]::Delete($cmdPath)}
        if([IO.File]::Exists($jsonPath)){[IO.File]::Delete($jsonPath)}
        [IO.Directory]::Delete($temporary,$false)
    }
}
Check 'CMD assignment and ordinary long source paths fit their distinct limits' {
    if(('set "TARGET_COMMAND='+$installText+'"').Length -gt 8191){throw 'CMD assignment exceeds 8191 characters'}
    foreach($sourceLength in @(45,1024)){
        $paths=@{Source=('D:\'+('a'*($sourceLength-13))+'\WinRE.ps1');InstalledScript='C:\ProgramData\OEM\WinRE-Manager\WinRE.ps1';TaskName='Maintain Windows RE'}|ConvertTo-Json -Compress
        $prefix='$wrapperPaths=ConvertFrom-Json '+[char]39+$paths.Replace("'","''")+[char]39+'; '
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix+$helperText+'; '+$installText))
        if(('-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$encoded).Length -gt 30000){throw "Supported $sourceLength-character source path exceeds launch guard"}
    }
}
Write-Output "PASS: $script:Passed permanent-maintenance installation regression checks ($($PSVersionTable.PSVersion))"
