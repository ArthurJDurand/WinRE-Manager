<#
.SYNOPSIS
    Isolated regression tests for the harness's production-source bindings.
.DESCRIPTION
    Parses source files and imports only the reader/checker and location
    helpers. Location fixtures replace every storage, registry, filesystem,
    and reagentc provider they exercise with in-memory implementations.
    Never starts the harness, imports production main flow, enumerates disks,
    changes WinRE, invokes network requests, or requires administrator rights.
    Mutation fixtures retain reassuring comments and unrelated valid code to
    prove that assertions bind executable operations rather than substrings.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoPath = Split-Path -Parent $PSScriptRoot
$harnessPath = Join-Path $repoPath 'scripts\Test-WinRE.ps1'
$productionPath = Join-Path $repoPath 'scripts\WinRE.ps1'
$script:Passed = 0

function Read-FunctionDefinition {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Parse errors in $Path" }
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if (-not $functionAst) { throw "Function $Name missing from $Path" }
    return $functionAst.Extent.Text
}

$bindingDefinition = Read-FunctionDefinition $harnessPath 'Get-ProductionBindingIssues'
. ([scriptblock]::Create($bindingDefinition))
$versionDefinition = Read-FunctionDefinition $harnessPath 'Get-ProductionScriptVersion'
$readerDefinition = Read-FunctionDefinition $harnessPath 'Get-ProductionFunctionText'

function Assert-Binding {
    param([string]$Name, [string]$FunctionName, [string]$Text, [string]$ExpectedIssue)
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "$Name produced an invalid mutation fixture" }
    $issues = @(Get-ProductionBindingIssues -FunctionName $FunctionName -FunctionText $Text)
    if ($ExpectedIssue) {
        if (-not @($issues | Where-Object { $_ -like "*$ExpectedIssue*" }).Count) { throw "$Name did not detect '$ExpectedIssue'; issues: $($issues -join '; ')" }
    } elseif ($issues.Count) { throw "$Name unexpectedly failed: $($issues -join '; ')" }
    $script:Passed++
    Write-Output "PASS: $Name"
}

function Assert-LocationCase {
    param([string]$Name, [scriptblock]$Case)
    & $Case
    $script:Passed++
    Write-Output "PASS: $Name"
}

function Get-ExecutableFunctionContract {
    param([string]$Text)
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'Invalid location helper contract' }
    # Token content retains literal values and variable names while ignoring
    # formatting and comments; it is stricter than a behavioral parity sample.
    return (($tokens | Where-Object { $_.Kind -notin @('Comment', 'NewLine', 'EndOfInput', 'LineContinuation') } |
        ForEach-Object { '{0}:{1}' -f $_.Kind, $_.Text }) -join "`n")
}

function Invoke-LocationParserFixtures {
    param([string]$SourcePath, [string]$SourceLabel)
    . ([scriptblock]::Create((Read-FunctionDefinition $SourcePath 'ConvertFrom-WinRELocation')))
    $volumeId = '11111111-2222-3333-4444-555555555555'
    $valid = @(
        @{ Name = 'GLOBALROOT complete folder'; Path = '\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE'; Kind = 'GlobalRoot'; Folder = 'Recovery\WindowsRE' },
        @{ Name = 'volume GUID complete folder'; Path = "\\?\Volume{$volumeId}\Custom folder\WinRE"; Kind = 'VolumeGuid'; Folder = 'Custom folder\WinRE' },
        @{ Name = 'drive-letter complete folder'; Path = 'R:\Recovery\WindowsRE'; Kind = 'DriveLetter'; Folder = 'Recovery\WindowsRE' },
        @{ Name = 'drive root is literal root'; Path = 'R:\'; Kind = 'DriveLetter'; Folder = '' },
        @{ Name = 'partition root is literal root'; Path = '\\?\GLOBALROOT\device\harddisk0\partition4\'; Kind = 'GlobalRoot'; Folder = '' },
        @{ Name = 'volume root is literal root'; Path = "\\?\Volume{$volumeId}\"; Kind = 'VolumeGuid'; Folder = '' }
    )
    foreach ($fixture in $valid) {
        Assert-LocationCase "$SourceLabel parser: $($fixture.Name)" {
            $parsed = ConvertFrom-WinRELocation -Location $fixture.Path
            if (-not $parsed -or $parsed.Kind -ne $fixture.Kind -or $parsed.RelativePath -cne $fixture.Folder -or
                $parsed.NormalizedPath -cne ($parsed.Root + $fixture.Folder)) {
                throw "Location parsing lost the exact registered folder: $($fixture.Path)"
            }
        }
    }
    # The production location suite covers the full malformed-path matrix.
    # These cases protect the harness companion's key drive-relative refusal.
    foreach ($invalid in @('R:', 'R:Recovery\WindowsRE')) {
        Assert-LocationCase "$SourceLabel parser rejects '$invalid'" {
            if ($null -ne (ConvertFrom-WinRELocation -Location $invalid)) { throw "Unsafe location accepted: $invalid" }
        }
    }
}

function Invoke-LocationStateFixtures {
    param([string]$SourcePath, [string]$SourceLabel, [switch]$ExpectRawInfo)
    foreach ($functionName in @('ConvertFrom-WinRELocation', 'Get-WinRELocationFromInfo', 'Get-WinREState')) {
        . ([scriptblock]::Create((Read-FunctionDefinition $SourcePath $functionName)))
    }
    # The extracted reader calls these providers; neither mock performs IO.
    function cmd { return $script:FixtureWinREInfo }
    function Get-ItemProperty {
        param([string]$Path, [string]$Name, [string]$ErrorAction)
        if ($Path -ne 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinRE' -or $Name -ne 'WinRELocation') {
            throw 'Unexpected registry provider request'
        }
        return [pscustomobject]@{ WinRELocation = $script:FixtureWinRERegistryLocation }
    }
    $paths = @('R:\Custom folder\WindowsRE', '\\?\Volume{11111111-2222-3333-4444-555555555555}\Recovery\WindowsRE',
        '\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE')
    foreach ($path in $paths) {
        $script:FixtureWinREInfo = @('Windows RE status: Enabled', "Windows RE location: $path", 'Windows RE Version: 10.0.26100.1000')
        $script:FixtureWinRERegistryLocation = $null
        Assert-LocationCase "$SourceLabel state preserves complete '$path'" {
            $actual = Get-WinREState
            if ($actual.Status -ne 'Enabled' -or $actual.Version -ne '10.0.26100.1000' -or $actual.Location -cne $path) {
                throw 'State extraction lost the registered folder, status, or version'
            }
            if ($ExpectRawInfo -and ((@($actual.RawInfo) -join "`n") -cne ($script:FixtureWinREInfo -join "`n"))) {
                throw 'Harness state reader lost its deliberate full raw output'
            }
        }
    }
    foreach ($locationField in @('blank', 'absent')) {
        $script:FixtureWinREInfo = @('Windows RE status: Enabled')
        if ($locationField -eq 'blank') { $script:FixtureWinREInfo += 'Windows RE location:' }
        $script:FixtureWinRERegistryLocation = 'R:\Recovery\WindowsRE'
        Assert-LocationCase "$SourceLabel Enabled state rejects stale registry fallback for $locationField location field" {
            $actual = Get-WinREState
            if ($actual.Status -ne 'Enabled' -or $null -ne $actual.Location) {
                throw 'A stale registry location disguised the missing Enabled WinRE route'
            }
        }
    }
    $script:FixtureWinREInfo = @('Windows RE status: Disabled')
    $script:FixtureWinRERegistryLocation = 'R:\Recovery\WindowsRE'
    Assert-LocationCase "$SourceLabel state retains complete registry fallback" {
        $actual = Get-WinREState
        if ($actual.Status -ne 'Disabled' -or $actual.Location -cne $script:FixtureWinRERegistryLocation) {
            throw 'Registry fallback lost the registered folder'
        }
    }
}

function Invoke-DiagnosticLocationFixtures {
    foreach ($functionName in @('ConvertFrom-WinRELocation', 'Get-WinRELocationFromInfo')) {
        . ([scriptblock]::Create((Read-FunctionDefinition $harnessPath $functionName)))
    }
    $tokens = $null
    $parseErrors = $null
    $diagnosticText = Read-FunctionDefinition $harnessPath 'Show-SystemDiagnostic'
    $diagnosticAst = [System.Management.Automation.Language.Parser]::ParseInput($diagnosticText, [ref]$tokens, [ref]$parseErrors)
    $diagnosticFunction = $diagnosticAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-SystemDiagnostic'
    }, $true)
    $statements = @($diagnosticFunction.Body.EndBlock.Statements)
    $checkIndex = -1
    for ($index = 0; $index -lt $statements.Count; $index++) {
        if ($statements[$index] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $statements[$index].Left.Extent.Text -eq '$reportedLocation') {
            $checkIndex = $index
            break
        }
    }
    if ($parseErrors.Count -gt 0 -or $checkIndex -lt 0 -or $checkIndex + 2 -ge $statements.Count -or
        $statements[$checkIndex + 1] -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
        $statements[$checkIndex + 1].Left.Extent.Text -ne '$parsedReportedLocation' -or
        $statements[$checkIndex + 2] -isnot [System.Management.Automation.Language.IfStatementAst]) {
        throw 'Could not isolate the actual diagnostic Check 2 statements'
    }
    # Execute the actual three statements from Show-SystemDiagnostic. No
    # restated verdict logic or other diagnostic/operational code is run.
    $checkText = ($statements[$checkIndex..($checkIndex + 2)] | ForEach-Object { $_.Extent.Text }) -join "`n"
    $checkBlock = [scriptblock]::Create($checkText)
    function Write-Host { param($Object, [switch]$NoNewline, $ForegroundColor) }
    function Record {
        param($Name, [bool]$Passed, $Detail, $State)
        $actualState = if ($State) { $State } elseif ($Passed) { 'PASS' } else { 'FAIL' }
        $script:DiagnosticLocationRecords.Add([pscustomobject]@{ Name = $Name; State = $actualState; Detail = $Detail })
    }
    $validPaths = @('R:\Recovery\WindowsRE', '\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE',
        '\\?\Volume{11111111-2222-3333-4444-555555555555}\Recovery\WindowsRE')
    $fixtures = @(
        foreach ($path in $validPaths) {
            @{ Name = "accepts exact '$path'"; Status = 'Enabled'; ExpectedState = 'PASS'; ExpectedPath = $path
                Info = @('Windows RE status: Enabled', "Windows RE location: $path") }
        }
        @{ Name = 'refuses Enabled blank native location'; Status = 'Enabled'; ExpectedState = 'FAIL'
            Info = @('Windows RE status: Enabled', 'Windows RE location:') }
        @{ Name = 'refuses Enabled invalid native location'; Status = 'Enabled'; ExpectedState = 'FAIL'
            Info = @('Windows RE status: Enabled', 'Windows RE location: R:\Recovery.') }
        @{ Name = 'does not substitute an unrelated recovery-image field'; Status = 'Enabled'; ExpectedState = 'FAIL'
            Info = @('Windows RE status: Enabled', 'Recovery image location: \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE') }
        @{ Name = 'SKIPs Disabled missing native location'; Status = 'Disabled'; ExpectedState = 'SKIP'
            Info = @('Windows RE status: Disabled') }
    )
    foreach ($fixture in $fixtures) {
        Assert-LocationCase "diagnostic Check 2 $($fixture.Name)" {
            $script:DiagnosticLocationRecords = [System.Collections.Generic.List[object]]::new()
            # A resolved/registry-derived state location cannot stand in for
            # the native field that this parser check is meant to validate.
            $wreState = @{ Status = $fixture.Status; RawInfo = $fixture.Info; Location = 'R:\Stale registry folder' }
            & $checkBlock
            if ($script:DiagnosticLocationRecords.Count -ne 1) { throw 'Check 2 did not record exactly one result' }
            $actual = $script:DiagnosticLocationRecords[0]
            if ($actual.Name -ne 'Parser: reagentc location' -or $actual.State -ne $fixture.ExpectedState) {
                throw "Check 2 returned $($actual.State) for $($fixture.Name)"
            }
            if ($fixture.ExpectedPath -and -not $actual.Detail.Contains($fixture.ExpectedPath)) {
                throw 'Check 2 lost the exact native registered folder'
            }
        }
    }
}

$vhdName = 'Test-NativeBootVirtualTopology'
$storageName = 'Get-StorageControllerDevices'
$vmName = 'Test-RunningInVirtualMachine'
$vhd = Read-FunctionDefinition $productionPath $vhdName
$storage = Read-FunctionDefinition $productionPath $storageName
$vm = Read-FunctionDefinition $productionPath $vmName
Assert-Binding 'current VHDX contract' $vhdName $vhd
Assert-Binding 'current storage-controller contract' $storageName $storage
Assert-Binding 'current hypervisor contract' $vmName $vm

$mutant = $vhd.Replace('Get-Disk -ErrorAction Stop |', 'Get-Disk -ErrorAction SilentlyContinue <# Get-Disk -ErrorAction Stop #> |')
$mutant = $mutant.Replace('$hostBusTypes = @()', '$hostBusTypes = @(); Get-Item irrelevant -ErrorAction Stop')
Assert-Binding 'unrelated Stop command and comment cannot protect disk enumeration' $vhdName $mutant 'does not carry -ErrorAction Stop'
$mutant = $vhd.Replace('$_.Number -ne $osDisk.Number', '$_.Number -eq $osDisk.Number <# Where-Object { $_.Number -ne $osDisk.Number } #>')
Assert-Binding 'comment cannot satisfy other-disk filter' $vhdName $mutant 'lacks the other-disk number filter'
$mutant = $vhd.Replace('} catch {' + "`r`n" + '        $result.IsNativeBootVirtual = $true', '} catch {' + "`r`n" + '        $result.IsNativeBootVirtual = $false <# IsNativeBootVirtual = $true #>')
if ($mutant -eq $vhd) { throw 'VHDX catch mutation did not apply' }
Assert-Binding 'unrelated fail-closed assignments cannot satisfy enumeration catch' $vhdName $mutant 'catch must set'
$mutant = $vhd.Replace('        return $result' + "`r`n" + '    }' + "`r`n" + '    foreach ($d in $otherDisks)', '        return $false' + "`r`n" + '    }' + "`r`n" + '    foreach ($d in $otherDisks)')
if ($mutant -eq $vhd) { throw 'VHDX catch return mutation did not apply' }
Assert-Binding 'return elsewhere cannot satisfy enumeration catch' $vhdName $mutant 'catch must set'

$mutant = $storage.Replace('return ,$result', 'return $result <# return ,$result #>')
Assert-Binding 'comment cannot preserve empty-array return shape' $storageName $mutant 'unary-comma return'
$mutant = $storage.Replace("-match '^SWD\\'", "-match '^OTHER\\' <# -match '^SWD\\' #>")
Assert-Binding 'comment cannot preserve executable software-device filter' $storageName $mutant 'software-device skip'
$mutant = $storage.Replace("\\' -or `$dev.InstanceId", "\\' -and `$dev.InstanceId")
if ($mutant -eq $storage) { throw 'Storage filter connective mutation did not apply' }
Assert-Binding 'software-device alternatives must remain an OR condition' $storageName $mutant 'software-device skip'

foreach ($signature in @('VMware', 'VirtualBox', 'innotek', 'Microsoft Corporation.*Virtual Machine', 'Xen', 'QEMU', 'Parallels', 'Bochs', 'KVM', 'bhyve')) {
    $mutant = $vm.Replace("'$signature'", "'changed-$signature' <# '$signature' #>")
    Assert-Binding "signature '$signature' in comment cannot satisfy executable array" $vmName $mutant 'signatures array differs'
}
$mutant = $vm.Replace('Get-CimInstance Win32_ComputerSystem -ErrorAction Stop', 'Get-CimInstance Win32_OperatingSystem -ErrorAction Stop <# Get-CimInstance Win32_ComputerSystem #>')
Assert-Binding 'comment cannot satisfy actual computer-system query' $vmName $mutant 'query must use'
$mutant = $vm.Replace('Get-CimInstance Win32_ComputerSystem -ErrorAction Stop', 'Get-CimInstance Win32_ComputerSystem -ErrorAction Continue <# -ErrorAction Stop #>')
Assert-Binding 'query must carry its own Stop argument' $vmName $mutant 'query must use'
$mutant = $vm.Replace('        return $null' + "`r`n" + '    }' + "`r`n" + '    if (-not $cs)', '        return $false <# return $null #>' + "`r`n" + '    }' + "`r`n" + '    if (-not $cs)')
if ($mutant -eq $vm) { throw 'VM catch mutation did not apply' }
Assert-Binding 'null return elsewhere cannot satisfy CIM catch' $vmName $mutant 'query must use'
$mutant = $vm.Replace('    $combined = "$mfg $mdl"', '    $combined = "$mfg" <# $combined = "$mfg $mdl" #>')
Assert-Binding 'comment cannot satisfy combined-string construction' $vmName $mutant 'combined-string assignment'
$mutant = $vm.Replace('foreach ($sig in $signatures)', 'foreach ($sig in $unrelated)')
Assert-Binding 'unused signatures array cannot satisfy match loop' $vmName $mutant 'not consumed'
$mutant = $vm.Replace('$combined -match $sig', '$combined -match $unrelated')
Assert-Binding 'loop must match its actual signature variable' $vmName $mutant 'not consumed'
$mutant = $vm.Replace('[string]::IsNullOrWhiteSpace($mfg) -and [string]::IsNullOrWhiteSpace($mdl)', '[string]::IsNullOrWhiteSpace($mfg) -or [string]::IsNullOrWhiteSpace($mdl)')
Assert-Binding 'empty-metadata guard must retain both-fields-empty condition' $vmName $mutant 'empty-metadata condition'

# A separate runspace supplies no script file, reproducing pasted/selection
# execution. ErrorAction Stop makes a Join-Path binding error fail the test.
$runspace = [powershell]::Create()
try {
    $code = '$ErrorActionPreference = ''Stop''; $PSScriptRoot = '''';' + "`n" + $versionDefinition + "`n" + $readerDefinition + "`n" + @'
$version = Get-ProductionScriptVersion
$body = Get-ProductionFunctionText -FunctionName 'Get-PartitionPlan'
if ($null -ne $version -or $null -ne $body) { throw 'Missing script root must return null from both readers' }
'readers returned null without throwing'
'@
    [void]$runspace.AddScript($code)
    $result = @($runspace.Invoke())
    if ($runspace.HadErrors -or $result.Count -ne 1 -or $result[0] -ne 'readers returned null without throwing') { throw "Missing-root reader regression failed: $($runspace.Streams.Error -join '; ')" }
    $script:Passed++
    Write-Output 'PASS: both production readers safely return null without a script directory'
} finally { $runspace.Dispose() }

foreach ($functionName in @('ConvertFrom-WinRELocation', 'Get-WinRELocationFromInfo', 'Get-WinREPathAttributes', 'Resolve-WinRELocationToPartition')) {
    Assert-LocationCase "location mirror executable contract: $functionName" {
        $productionContract = Get-ExecutableFunctionContract (Read-FunctionDefinition $productionPath $functionName)
        $harnessContract = Get-ExecutableFunctionContract (Read-FunctionDefinition $harnessPath $functionName)
        if ($productionContract -cne $harnessContract) { throw "Harness location mirror drifted: $functionName" }
    }
}
Assert-LocationCase 'state reader mirror differs only by deliberate RawInfo output' {
    $productionContract = Get-ExecutableFunctionContract (Read-FunctionDefinition $productionPath 'Get-WinREState')
    $harnessState = (Read-FunctionDefinition $harnessPath 'Get-WinREState').Replace('; RawInfo = $info', '')
    if ($productionContract -cne (Get-ExecutableFunctionContract $harnessState)) { throw 'Harness state-reader logic drifted' }
}
Invoke-LocationParserFixtures -SourcePath $harnessPath -SourceLabel 'harness'
Invoke-LocationStateFixtures -SourcePath $productionPath -SourceLabel 'production'
Invoke-LocationStateFixtures -SourcePath $harnessPath -SourceLabel 'harness' -ExpectRawInfo
Invoke-DiagnosticLocationFixtures

Write-Output "Harness binding regression tests: $script:Passed passed, 0 failed. No operational harness or production flow executed."
