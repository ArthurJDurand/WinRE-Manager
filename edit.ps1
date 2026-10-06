# edit-docs-oneliners-v2.ps1 - remove broken Invoke-Expression forms from README.md and docs/index.md
[CmdletBinding()]
param([string]$RepoRoot = (Get-Location).Path)

$ErrorActionPreference = 'Stop'

function Say {
    param([string]$Status, [string]$Message)
    $color = switch ($Status) { 'OK'{'Green'} 'FAIL'{'Red'} 'WARN'{'Yellow'} default{'Cyan'} }
    Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $color
}

$bt = [string][char]96     # backtick
$dl = [string][char]36     # dollar
$em = [string][char]0x2014 # em-dash

function P { param([string]$s) return $s.Replace('@_BT_@', $bt).Replace('@_D_@', $dl).Replace('@_EM_@', $em) }

function Normalize-Eol {
    param([string]$s, [string]$eol)
    return (($s -replace "`r`n", "`n") -split "`n") -join $eol
}

$tailFind = @(
    '```powershell'
    'Invoke-RestMethod -Uri ''https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/main/scripts/Test-WinRE.ps1'' -UseBasicParsing | Invoke-Expression'
    '```'
    ''
    '**@_BT_@Invoke-Expression@_BT_@ cannot pass parameters.** For @_BT_@WinRE.ps1@_BT_@ with @_BT_@-DryRun@_BT_@ or any other switch, use the scriptblock form. Same current-session caveat, but the arguments work:'
    ''
    '```powershell'
    '& ([scriptblock]::Create((irm ''https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/main/scripts/WinRE.ps1'' -UseBasicParsing))) -DryRun'
    '```'
    ''
    'The save-and-run form is preferable for anything you care about: it isolates the script in a child process, keeps your shell open, and exposes @_BT_@@_D_@LASTEXITCODE@_BT_@:'
    ''
    '```powershell'
    '@_D_@p = "@_D_@env:TEMP\WinRE.ps1"'
    'Invoke-RestMethod -Uri ''https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/main/scripts/WinRE.ps1'' -UseBasicParsing -OutFile @_D_@p'
    'powershell -ExecutionPolicy Bypass -File @_D_@p -DryRun'
    '```'
)

$tailRepl = @(
    '```powershell'
    '@_D_@p = "@_D_@env:TEMP\WinRE.ps1"'
    'Invoke-RestMethod -Uri ''https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/main/scripts/WinRE.ps1'' -UseBasicParsing -OutFile @_D_@p'
    'powershell -ExecutionPolicy Bypass -File @_D_@p -DryRun'
    '```'
    ''
    'Substitute the @_BT_@Test-WinRE.ps1@_BT_@ URL to fetch the read-only harness, and drop @_BT_@-DryRun@_BT_@ to run for real. The save-and-run form isolates the script in a child process, keeps your shell open, and exposes @_BT_@@_D_@LASTEXITCODE@_BT_@ @_EM_@ the right shape for anything you care about.'
    ''
    '> **Do not pipe the fetched content to @_BT_@Invoke-Expression@_BT_@.** The script begins with a UTF-8 byte-order mark followed by a comment-based-help block. Piping the fetched text through @_BT_@Invoke-Expression@_BT_@ does not strip the BOM before parsing, so the parser does not recognize the help block as a comment and fails on its content. The save-and-run form handles the BOM correctly because the file parser does.'
)

$files = @(
    [PSCustomObject]@{
        Name       = 'README.md'
        IntroFind  = 'If you do not want to clone the repo, you can fetch and run either script directly. The script then runs in your current session @_EM_@ including its final @_BT_@exit@_BT_@ @_EM_@ so this form is convenient for a quick diagnostic but not for anything you need @_BT_@@_D_@LASTEXITCODE@_BT_@ from.'
        IntroRepl  = 'Save the script to a temp path and run it in a child process:'
        IntroGone  = 'If you do not want to clone the repo, you can fetch and run either script directly.'
    }
    [PSCustomObject]@{
        Name       = 'docs/index.md'
        IntroFind  = 'Runs the script in your current session @_EM_@ including its final @_BT_@exit@_BT_@ @_EM_@ so this form is convenient for a quick diagnostic but not for anything you need @_BT_@@_D_@LASTEXITCODE@_BT_@ from.'
        IntroRepl  = 'Save the script to a temp path and run it in a child process:'
        IntroGone  = 'Runs the script in your current session'
    }
)

Say ""

foreach ($f in $files) {
    $rel  = $f.Name
    $path = Join-Path $RepoRoot $rel
    Say "=== $rel ==="

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Say FAIL "File not found: $path"; exit 1 }

    $fullPath = (Resolve-Path -LiteralPath $path).Path
    $bytes    = [System.IO.File]::ReadAllBytes($fullPath)
    $preHash  = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
    Say INFO ("Pre-flight SHA256: {0}" -f $preHash)

    $hasBom  = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $encRead = New-Object System.Text.UTF8Encoding($false)
    $text    = $encRead.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $crlfCount = ([regex]::Matches($text, "`r`n")).Count
    $lfOnly    = ([regex]::Matches($text, "`n")).Count - $crlfCount
    Say INFO ("BOM: {0}  CRLF={1} LF-only={2}" -f $(if ($hasBom) { 'present' } else { 'absent' }), $crlfCount, $lfOnly)
    if ($crlfCount -gt 0 -and $lfOnly -gt 0) { Say FAIL "Mixed EOL - refusing."; exit 1 }
    $fileEol = if ($crlfCount -gt 0) { "`r`n" } else { "`n" }
    $fileEolEsc = [regex]::Escape($fileEol)

    # Build find/replace blocks in file EOL.
    $findIntro = Normalize-Eol (P $f.IntroFind) $fileEol
    $replIntro = Normalize-Eol (P $f.IntroRepl) $fileEol
    $findTail  = Normalize-Eol ((($tailFind  | ForEach-Object { P $_ }) -join "`n")) $fileEol
    $replTail  = Normalize-Eol ((($tailRepl  | ForEach-Object { P $_ }) -join "`n")) $fileEol

    # Pre-flight: both anchors must exist, and be unique.
    $h1 = ([regex]::Matches($text, [regex]::Escape($findIntro))).Count
    if ($h1 -eq 0) { Say FAIL "Intro anchor not found."; exit 1 }
    if ($h1 -gt 1) { Say FAIL ("Intro anchor not unique ({0} matches)." -f $h1); exit 1 }
    Say OK "Intro anchor found, unique."

    $h2 = ([regex]::Matches($text, [regex]::Escape($findTail))).Count
    if ($h2 -eq 0) { Say FAIL "Tail anchor not found."; exit 1 }
    if ($h2 -gt 1) { Say FAIL ("Tail anchor not unique ({0} matches)." -f $h2); exit 1 }
    Say OK "Tail anchor found, unique."

    # Compute expected EOL delta from the replacement blocks.
    $findEol = ([regex]::Matches($findIntro + $findTail, $fileEolEsc)).Count
    $replEol = ([regex]::Matches($replIntro + $replTail, $fileEolEsc)).Count
    $expectedDelta = $replEol - $findEol
    Say INFO ("Predicted EOL delta: {0}" -f $expectedDelta)

    $backup = "$fullPath.bak"
    Copy-Item -LiteralPath $fullPath -Destination $backup -Force

    $text = $text.Replace($findIntro, $replIntro)
    $text = $text.Replace($findTail, $replTail)

    $encWrite = New-Object System.Text.UTF8Encoding($hasBom)
    [System.IO.File]::WriteAllText($fullPath, $text, $encWrite)

    # Post-write checks.
    $vBytes  = [System.IO.File]::ReadAllBytes($fullPath)
    $vHasBom = ($vBytes.Length -ge 3 -and $vBytes[0] -eq 0xEF -and $vBytes[1] -eq 0xBB -and $vBytes[2] -eq 0xBF)
    if ($vHasBom -ne $hasBom) { Copy-Item -LiteralPath $backup -Destination $fullPath -Force; Say FAIL "BOM mismatch, restored."; exit 1 }

    $vText   = $encRead.GetString($vBytes)
    if ($vText.Length -gt 0 -and [int]$vText[0] -eq 0xFEFF) { $vText = $vText.Substring(1) }
    $vCrlf   = ([regex]::Matches($vText, "`r`n")).Count
    $vLfOnly = ([regex]::Matches($vText, "`n")).Count - $vCrlf
    $expectedCrlf = $crlfCount + $expectedDelta
    if ($vCrlf -ne $expectedCrlf -or $vLfOnly -ne $lfOnly) {
        Copy-Item -LiteralPath $backup -Destination $fullPath -Force
        Say FAIL ("EOL mismatch, restored. Pre: CRLF={0} LF={1}. Post: CRLF={2} LF={3}. Expected CRLF={4}." -f $crlfCount, $lfOnly, $vCrlf, $vLfOnly, $expectedCrlf)
        exit 1
    }
    Say OK ("Post-write EOL passed (CRLF={0}, delta {1})." -f $vCrlf, $expectedDelta)

    # Sanity: broken text gone, replacement text present.
    $checks = @(
        @{ Present = (P 'Save the script to a temp path and run it in a child process:'); Absent = $null },
        @{ Present = (P 'Do not pipe the fetched content to @_BT_@Invoke-Expression@_BT_@.'); Absent = $null },
        @{ Present = $null; Absent = (P '**@_BT_@Invoke-Expression@_BT_@ cannot pass parameters.**') },
        @{ Present = $null; Absent = 'Invoke-RestMethod -Uri ''https://raw.githubusercontent.com/ArthurJDurand/WinRE-Manager/main/scripts/Test-WinRE.ps1'' -UseBasicParsing | Invoke-Expression' },
        @{ Present = $null; Absent = $f.IntroGone }
    )
    foreach ($c in $checks) {
        if ($c.Present -and -not $vText.Contains($c.Present)) {
            Copy-Item -LiteralPath $backup -Destination $fullPath -Force
            Say FAIL ("Sanity: expected text not found: '{0}', restored." -f $c.Present); exit 1
        }
        if ($c.Absent -and $vText.Contains($c.Absent)) {
            Copy-Item -LiteralPath $backup -Destination $fullPath -Force
            Say FAIL ("Sanity: stale text still present: '{0}', restored." -f $c.Absent); exit 1
        }
    }
    Say OK "Content sanity passed."

    $postHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
    Say INFO ("Post-write SHA256: {0}" -f $postHash)
    Remove-Item -LiteralPath $backup -Force
    Say OK "Done."
    Say ""
}

exit 0
