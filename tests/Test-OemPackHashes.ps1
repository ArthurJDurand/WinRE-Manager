<#
.SYNOPSIS
    Isolated OEM checksum regressions using actual downloader and builder code.
.DESCRIPTION
    All network and filesystem providers are mocked. No builder main, package
    download, generated map write, WinRE operation or partition query runs.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path $PSScriptRoot -Parent
$script:Passed = 0
function Read-Ast {
    param($Path)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
    return $ast
}
function Function-Text {
    param($Ast,$Name)
    $node=$Ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if(-not $node){throw "Missing function $Name"}
    return $node.Extent.Text
}
function Check {
    param($Name,[scriptblock]$Body)
    & $Body
    $script:Passed++
    Write-Output "PASS: $Name"
}
$production=Read-Ast (Join-Path $repoPath 'scripts\WinRE.ps1')
$harness=Read-Ast (Join-Path $repoPath 'scripts\Test-WinRE.ps1')
$builder=Read-Ast (Join-Path $repoPath 'scripts\Build-LenovoWinPEMap.ps1')
$dellBuilder=Read-Ast (Join-Path $repoPath 'scripts\Build-DellWinPEMap.ps1')

function Invoke-DownloadFixtures {
    param($Source,$Label)
    . ([scriptblock]::Create((Function-Text $Source 'Invoke-OemPackDownload')))
    $script:DryRun=$false
    $GitHubHeaders=@{}; $NetworkTimeoutSeconds=15
    function Write-Log {param($Message,$Level)}
    function Say {param($Message,$Level)}
    function Test-Path {param($Path) return $script:HashFixture.Exists}
    function Get-Item {param($Path,[switch]$Force) return [pscustomobject]@{Length=$script:HashFixture.Length}}
    function Remove-Item {param($Path,[switch]$Force,$ErrorAction) $script:HashFixture.Exists=$false; $script:HashFixture.Deletes++}
    function Get-FileHash {
        param($Path,$Algorithm)
        $script:HashFixture.HashReads++
        return [pscustomobject]@{Hash=$(if($Algorithm -eq 'SHA256'){'A'*64}else{'B'*32})}
    }
    function Invoke-WebRequest {
        param($Uri,$OutFile,$Headers,[switch]$UseBasicParsing,$TimeoutSec,$ErrorAction)
        $script:HashFixture.Downloads++
        $script:HashFixture.Exists=$true
        if($script:HashFixture.Throws){throw 'mock request failed after writing partial bytes'}
    }
    function Start-Sleep {param($Seconds) throw 'Single-attempt fixture must not sleep'}
    $cases=@(
        @{Name='padded SHA256';SHA=(" `t"+('a'*64)+"`r`n");MD5=$null;OK=$true;Downloads=1},
        @{Name='padded MD5';SHA=$null;MD5=(' '+('b'*32)+' ');OK=$true;Downloads=1},
        @{Name='both padded digests';SHA=(' '+('a'*64)+' ');MD5=(' '+('b'*32)+' ');OK=$true;Downloads=1},
        @{Name='wrong SHA256';SHA=('C'*64);MD5=$null;OK=$false;Downloads=1},
        @{Name='wrong MD5';SHA=$null;MD5=('C'*32);OK=$false;Downloads=1},
        @{Name='whitespace-only SHA256';SHA='   ';MD5=$null;OK=$false;Downloads=0},
        @{Name='whitespace-only MD5';SHA=$null;MD5='   ';OK=$false;Downloads=0},
        @{Name='short SHA256';SHA=('A'*63);MD5=$null;OK=$false;Downloads=0},
        @{Name='internal SHA256 whitespace';SHA=(('A'*32)+' '+('A'*32));MD5=$null;OK=$false;Downloads=0},
        @{Name='nonhex SHA256';SHA=('G'*64);MD5=$null;OK=$false;Downloads=0},
        @{Name='short MD5';SHA=$null;MD5=('B'*31);OK=$false;Downloads=0},
        @{Name='missing hashes clean request';SHA=$null;MD5=$null;OK=$true;Downloads=1},
        @{Name='missing hashes failed partial request';SHA=$null;MD5=$null;OK=$false;Downloads=1;Throws=$true},
        @{Name='zero-byte download';SHA=$null;MD5=$null;OK=$false;Downloads=1;Length=0},
        @{Name='hashed bytes after request exception';SHA=('A'*64);MD5=$null;OK=$true;Downloads=1;Throws=$true},
        @{Name='second digest mismatch';SHA=('A'*64);MD5=('C'*32);OK=$false;Downloads=1},
        @{Name='invalid SHA256 cannot fall back to valid MD5';SHA=' ';MD5=('B'*32);OK=$false;Downloads=0}
    )
    foreach($case in $cases){
        Check "$Label downloader: $($case.Name)" {
            $script:HashFixture=@{Exists=$false;Length=4096;Throws=[bool]$case.Throws;Downloads=0;Deletes=0;HashReads=0}
            if($case.ContainsKey('Length')){$script:HashFixture.Length=$case.Length}
            $actual=Invoke-OemPackDownload -Url 'https://example.invalid/mock.cab' -DestinationPath 'mock-package.cab' `
                -ExpectedSHA256 $case.SHA -ExpectedMD5 $case.MD5 -MaxRetries 1
            if($actual -ne $case.OK -or $script:HashFixture.Downloads -ne $case.Downloads){
                throw "Unexpected acceptance or network attempt for $Label $($case.Name)"
            }
            if($case.Downloads -eq 0 -and ($script:HashFixture.Deletes -ne 0 -or $script:HashFixture.HashReads -ne 0)){
                throw 'Malformed supplied metadata touched the destination or hash provider'
            }
        }
    }
}
Invoke-DownloadFixtures $production 'production'
Invoke-DownloadFixtures $harness 'harness'

. ([scriptblock]::Create((Function-Text $builder 'ConvertTo-LenovoSHA256')))
$reportedHash=' 77b388581febd0716ea48d6b384c2649b6e3b47af4ad11b0162b3fdae4eb9299'
foreach($case in @(
    @{Name='observed 20JV DS121687 metadata';Value=$reportedHash;Expected=$reportedHash.Trim()},
    @{Name='surrounding whitespace';Value=("`t"+('A'*64)+"`r`n");Expected=('A'*64)},
    @{Name='valid lowercase';Value=('a'*64);Expected=('a'*64)},
    @{Name='missing digest';Value=$null;Expected=$null},
    @{Name='empty digest';Value='';Expected=''},
    @{Name='whitespace-only supplied digest';Value=' ';Throws=$true},
    @{Name='short digest';Value=('A'*63);Throws=$true},
    @{Name='internal whitespace';Value=(('A'*32)+' '+('A'*32));Throws=$true},
    @{Name='nonhex digest';Value=('G'*64);Throws=$true}
)){
    Check "builder checksum: $($case.Name)" {
        $threw=$false; $value=$null
        try{$value=ConvertTo-LenovoSHA256 -Value $case.Value -Context 'fixture'}catch{$threw=$true}
        if($threw -ne [bool]$case.Throws){throw 'Builder accepted malformed metadata or refused a valid digest'}
        if(-not $threw -and [string]$value -cne [string]$case.Expected){throw 'Builder did not preserve the normalized digest'}
    }
}
Check 'actual builder assignment normalizes before caching outside parser catches' {
    $call=$builder.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertTo-LenovoSHA256'},$true)
    if(-not $call){throw 'Builder does not call its checksum normalizer'}
    $assignment=$call
    while($assignment -and $assignment -isnot [Management.Automation.Language.AssignmentStatementAst]){$assignment=$assignment.Parent}
    if(-not $assignment -or $assignment.Left.Extent.Text -ne '$resolved.SHA256'){throw 'Checksum validation is not bound to resolved metadata'}
    $ancestor=$assignment.Parent
    while($ancestor){
        if($ancestor -is [Management.Automation.Language.TryStatementAst]){throw 'Checksum failure can be swallowed by the page-parser catch'}
        $ancestor=$ancestor.Parent
    }
    $resolved=[pscustomobject]@{SHA256=$reportedHash}; $dsId='DS121687'
    . ([scriptblock]::Create($assignment.Extent.Text))
    if($resolved.SHA256 -cne $reportedHash.Trim()){throw 'Actual builder assignment retained the observed leading space'}
}
. ([scriptblock]::Create((Function-Text $dellBuilder 'ConvertTo-DellChecksum')))
. ([scriptblock]::Create((Function-Text $dellBuilder 'Get-WinPEGeneration')))
foreach($algorithm in @('SHA256','MD5')){
    $length=if($algorithm -eq 'SHA256'){64}else{32}
    foreach($case in @(
        @{Name='surrounding whitespace';Value=("`t"+('A'*$length)+"`r`n");Expected=('A'*$length)},
        @{Name='valid lowercase';Value=('a'*$length);Expected=('a'*$length)},
        @{Name='missing digest';Value=$null;Expected=$null},
        @{Name='empty digest';Value='';Expected=''},
        @{Name='whitespace-only supplied digest';Value=' ';Throws=$true},
        @{Name='short digest';Value=('A'*($length-1));Throws=$true},
        @{Name='long digest';Value=('A'*($length+1));Throws=$true},
        @{Name='internal whitespace';Value=(('A'*($length/2))+' '+('A'*($length/2)));Throws=$true},
        @{Name='nonhex digest';Value=('G'*$length);Throws=$true}
    )){
        Check "Dell builder $algorithm checksum: $($case.Name)" {
            $threw=$false; $value=$null
            try{$value=ConvertTo-DellChecksum -Value $case.Value -Algorithm $algorithm -Context 'fixture'}catch{$threw=$true}
            if($threw -ne [bool]$case.Throws){throw 'Dell builder accepted malformed metadata or refused a valid digest'}
            if(-not $threw -and [string]$value -cne [string]$case.Expected){throw 'Dell builder did not preserve the normalized digest'}
        }
    }
}

# Execute the actual catalog parsing, newest-generation selection, publication
# and Current-alias blocks in memory. Builder main and file writes never run.
$dellCatalogCreation=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$catalog'},$true)
$dellPreserveWhitespace=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$catalog.PreserveWhitespace'},$true)
$dellCatalogLoad=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$catalog' -and $n.Member.Value -eq 'LoadXml'},$true)
$dellParseLoop=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'pkg'},$true)
$dellSelectionLoop=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'p' -and $n.Condition.Extent.Text -eq '$parsed'},$true)
$dellPublicationLoop=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'gen' -and $n.Condition.Extent.Text -eq '$packs.Keys'},$true)
$dellSort=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$allSorted'},$true)
$dellAlias=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($allSorted.Count -gt 0)')},$true)
foreach($node in @($dellCatalogCreation,$dellPreserveWhitespace,$dellCatalogLoad,$dellParseLoop,$dellSelectionLoop,$dellPublicationLoop,$dellSort,$dellAlias)){
    if(-not $node){throw 'Actual Dell map publication block unavailable'}
}
function Invoke-DellPublicationFixture {
    param([string]$CatalogText)
    $ErrorActionPreference='Continue' # Match the real builder's preference.
    function Get-Content {param($LiteralPath,[switch]$Raw) return $CatalogText}
    $xmlPath='mock-catalog.xml'
    . ([scriptblock]::Create($dellCatalogCreation.Extent.Text))
    . ([scriptblock]::Create($dellPreserveWhitespace.Extent.Text))
    . ([scriptblock]::Create($dellCatalogLoad.Extent.Text))
    $winpeAll=@($catalog.DriverPackManifest.DriverPackage)
    $base='https://example.invalid/'; $parsed=@(); $packs=@{}; $jsonPacks=@{}
    function Write-T {param($M,$L)}
    . ([scriptblock]::Create($dellParseLoop.Extent.Text))
    . ([scriptblock]::Create($dellSelectionLoop.Extent.Text))
    . ([scriptblock]::Create($dellPublicationLoop.Extent.Text))
    . ([scriptblock]::Create($dellSort.Extent.Text))
    . ([scriptblock]::Create($dellAlias.Extent.Text))
    return $jsonPacks
}
function New-DellCatalogFixtureEntry {
    param($SHA256,$MD5,$Date='2026-10-23',$Name='WinPE11.0-Drivers-A11.cab')
    return ('<DriverPackage type="winpe" path="fixture.cab" hashMD5="'+$MD5+'" dellVersion="A11" releaseID="fixture" dateTime="'+$Date+'" size="1"><Name>'+$Name+'</Name><Cryptography><Hash algorithm="SHA256">'+$SHA256+'</Hash></Cryptography></DriverPackage>')
}
Check 'actual Dell publication normalizes both selected digests and its Current alias' {
    $entry=New-DellCatalogFixtureEntry -SHA256 (' '+('a'*64)+' ') -MD5 (' '+('B'*32)+' ')
    $map=Invoke-DellPublicationFixture -Catalog ('<DriverPackManifest>'+$entry+'</DriverPackManifest>')
    foreach($key in @('WinPE11','Current')){
        if($map[$key].sha256 -cne ('a'*64) -or $map[$key].md5 -cne ('B'*32)){throw 'Published digest or Current alias was not normalized'}
    }
}
Check 'actual Dell publication retains genuinely absent digests' {
    $entry='<DriverPackage type="winpe" path="fixture.cab" dellVersion="A11" releaseID="fixture" dateTime="2026-10-23" size="1"><Name>WinPE11.0-Drivers-A11.cab</Name></DriverPackage>'
    $map=Invoke-DellPublicationFixture -Catalog ('<DriverPackManifest>'+$entry+'</DriverPackManifest>')
    if($map.WinPE11.sha256 -or $map.WinPE11.md5 -or $map.Current.sha256 -or $map.Current.md5){throw 'Absent digest was invented'}
}
Check 'actual Dell publication retains explicitly empty digests' {
    $entry=New-DellCatalogFixtureEntry -SHA256 '' -MD5 ''
    $map=Invoke-DellPublicationFixture -Catalog ('<DriverPackManifest>'+$entry+'</DriverPackManifest>')
    if($map.WinPE11.sha256 -cne '' -or $map.WinPE11.md5 -cne ''){throw 'Empty digest metadata was changed or refused'}
}
foreach($case in @(
    @{Name='malformed SHA256';SHA='ABC';MD5=('B'*32)},
    @{Name='malformed MD5';SHA=('A'*64);MD5='XYZ'},
    @{Name='whitespace-only SHA256';SHA=' ';MD5=('B'*32)},
    @{Name='whitespace-only MD5';SHA=('A'*64);MD5=' '}
)){
    Check "actual Dell publication refuses selected $($case.Name)" {
        $entry=New-DellCatalogFixtureEntry -SHA256 $case.SHA -MD5 $case.MD5
        $threw=$false
        try{$null=Invoke-DellPublicationFixture -Catalog ('<DriverPackManifest>'+$entry+'</DriverPackManifest>')}catch{$threw=$true}
        if(-not $threw){throw 'Malformed selected checksum reached published map objects'}
    }
}
Check 'actual Dell publication ignores malformed superseded catalog entries' {
    $old=New-DellCatalogFixtureEntry -SHA256 'bad-old-sha' -MD5 'bad-old-md5' -Date '2025-01-01'
    $new=New-DellCatalogFixtureEntry -SHA256 ('A'*64) -MD5 ('B'*32)
    $map=Invoke-DellPublicationFixture -Catalog ('<DriverPackManifest>'+$old+$new+'</DriverPackManifest>')
    if($map.WinPE11.sha256 -cne ('A'*64) -or $map.Current.md5 -cne ('B'*32)){throw 'Superseded bad metadata blocked or contaminated the selected pack'}
}
Check 'actual Dell publication ignores malformed unrecognized-generation entries' {
    $unused=New-DellCatalogFixtureEntry -SHA256 'bad-unused-sha' -MD5 'bad-unused-md5' -Name 'Unrecognized-Drivers.cab'
    $selected=New-DellCatalogFixtureEntry -SHA256 ('A'*64) -MD5 ('B'*32)
    $map=Invoke-DellPublicationFixture -Catalog ('<DriverPackManifest>'+$unused+$selected+'</DriverPackManifest>')
    if($map.Count -ne 2 -or $map.WinPE11.sha256 -cne ('A'*64)){throw 'Unpublished generation blocked or entered the map'}
}
Check 'actual Dell publication validates both fields outside catches before its file write' {
    $calls=@($dellBuilder.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertTo-DellChecksum'},$true))
    $write=$dellBuilder.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'WriteAllText'},$true)
    if($calls.Count -ne 2 -or -not $write){throw 'Dell publication validation or file-write binding unavailable'}
    $fields=@()
    foreach($call in $calls){
        $assignment=$call
        while($assignment -and $assignment -isnot [Management.Automation.Language.AssignmentStatementAst]){$assignment=$assignment.Parent}
        if(-not $assignment -or $assignment.Extent.EndOffset -ge $write.Extent.StartOffset){throw 'Validation does not precede publication'}
        $fields+=$assignment.Left.Extent.Text
        $ancestor=$assignment.Parent; $insideSelected=$false
        while($ancestor){
            if($ancestor -is [Management.Automation.Language.TryStatementAst]){throw 'Dell validation failure can be swallowed'}
            if([object]::ReferenceEquals($ancestor,$dellPublicationLoop)){$insideSelected=$true}
            $ancestor=$ancestor.Parent
        }
        if(-not $insideSelected){throw 'Dell checksum validation is not bound to selected published packs'}
    }
    if((($fields|Sort-Object)-join ',') -cne '$p.MD5,$p.SHA256'){throw 'Both selected checksum fields are not validated'}
}
Write-Output "OEM checksum regression tests: $script:Passed passed, 0 failed. All network and filesystem providers mocked."
