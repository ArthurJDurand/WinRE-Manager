<#
.SYNOPSIS
    Correct the log level shown for the "could not determine the directory"
    variant of the v50 resume-task protected-path guard. The code logs it at
    WARN, not INFO.
#>

$ErrorActionPreference = 'Stop'
$repoRoot  = $PSScriptRoot
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$path      = Join-Path $repoRoot 'docs\troubleshooting.md'

if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Not found: $path" }

$text = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n")

$find = '[INFO] Register-ResumeTask: could not determine the directory containing ''<PSCommandPath>'' - skipping the temporary resume task (the repair pipeline itself is unaffected)'
$repl = '[WARN] Register-ResumeTask: could not determine the directory containing ''<PSCommandPath>'' - skipping the temporary resume task (the repair pipeline itself is unaffected)'

$count = ([regex]::Matches($text, [regex]::Escape($find))).Count
if ($count -eq 0) {
    Write-Host 'Find string not present - already fixed or wording differs from expectation.' -ForegroundColor Yellow
    exit 1
}
if ($count -gt 1) { throw "Find string appears $count times (expected 1)." }

$text = $text.Replace($find, $repl)
$text = $text.Replace("`n", "`r`n")
[System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
Write-Host 'OK    troubleshooting.md :: resume-task dir-unreadable log level INFO -> WARN' -ForegroundColor Green

$verify = [System.IO.File]::ReadAllText($path)
if (-not $verify.Contains('[WARN] Register-ResumeTask: could not determine the directory containing')) {
    Write-Host 'FAIL: new wording not present' -ForegroundColor Red
    exit 3
}
Write-Host 'OK    verification: corrected line present' -ForegroundColor Green
