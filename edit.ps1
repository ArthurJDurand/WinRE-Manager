# Add Discussions references to config.yml, README.md, CONTRIBUTING.md.
# EOL-safe: multi-line replacements are joined with the detected per-file EOL.

$crlf = ([char]13).ToString() + ([char]10).ToString()
$lf   = ([char]10).ToString()

$batch = @(
    @{
        Path = '.github\ISSUE_TEMPLATE\config.yml'
        Edits = @(
            @{ Tag = 'CFG';
               Find = '  - name: Security vulnerability';
               ReplLines = @(
                   '  - name: Questions and general discussion',
                   '    url: https://github.com/ArthurJDurand/WinRE-Manager/discussions',
                   '    about: Ask a question, share a deployment, or discuss the design. Not for bug reports or security disclosures.',
                   '  - name: Security vulnerability'
               ) }
        )
    }
    @{
        Path = 'README.md'
        Edits = @(
            @{ Tag = 'RM-DISC';
               Find = 'Bug reports and PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).';
               ReplLines = @(
                   'Bug reports and PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md).',
                   '',
                   'Questions and general discussion: [GitHub Discussions](https://github.com/ArthurJDurand/WinRE-Manager/discussions).'
               ) }
        )
    }
    @{
        Path = 'CONTRIBUTING.md'
        Edits = @(
            @{ Tag = 'CTB-DISC';
               Find = '## Bug reports';
               ReplLines = @(
                   '## Questions and general discussion',
                   '',
                   'For deployment help, "does this work on X", design discussions, and other content that isn''t a bug report or a feature request, use [GitHub Discussions](https://github.com/ArthurJDurand/WinRE-Manager/discussions). Bug reports and feature requests go to Issues, using the templates. Do not post security issues publicly — see [SECURITY.md](SECURITY.md).',
                   '',
                   '## Bug reports'
               ) }
        )
    }
)

$batchResults = @()

foreach ($file in $batch) {
    $path   = $file.Path
    $backup = "$path.bak"

    Write-Host ''
    Write-Host "=== $path ===" -ForegroundColor Cyan

    if (-not (Test-Path $path)) {
        $batchResults += "FAIL [$($file.Path)] file not found"
        continue
    }

    $bytes  = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $nl      = if ($text.Contains($crlf)) { $crlf } else { $lf }
    $nlLabel = if ($nl -eq $crlf) { 'CRLF' } else { 'LF' }
    Write-Host "Detected line ending: $nlLabel (BOM: $hasBom)"

    $resolved = @()
    $allPresent = $true
    foreach ($edit in $file.Edits) {
        $find = $edit.Find
        $repl = $edit.ReplLines -join $nl
        if (-not $text.Contains($find)) {
            $allPresent = $false
            $batchResults += "FAIL [$($edit.Tag)] anchor not found"
        }
        $resolved += [PSCustomObject]@{ Tag = $edit.Tag; Find = $find; Repl = $repl }
    }

    if (-not $allPresent) {
        $batchResults += "SKIPPED [$path] -- file untouched"
        continue
    }

    Copy-Item $path $backup -Force
    foreach ($edit in $resolved) { $text = $text.Replace($edit.Find, $edit.Repl) }
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($hasBom))
    Remove-Item $backup -Force

    foreach ($edit in $resolved) { $batchResults += "OK   [$($edit.Tag)]" }
}

Write-Host ''
$batchResults | ForEach-Object { Write-Host $_ }

if ($batchResults -match '^FAIL') {
    Write-Host ''
    Write-Host 'One or more anchors failed. No partial modifications.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Discussions references added.' -ForegroundColor Green
