# ASCII-only source. Single-quoted strings throughout.
# No here-strings. No nested code fences.

$bt = '`'

$batch = @(
    @{
        Path = '.github\ISSUE_TEMPLATE\bug_report.md'
        Edits = @(
            @{
                Tag   = 'BR-DriveLetter-Bailouts'
                Note  = 'Add the two drive-letter bail-out log signatures to bug_report.md'
                Guard = 'Invoke-DriveLetterAssignment: target partition <n>/<m> no longer exists'
                FindLines = @(
                    'and the current drive letters reported by ' + $bt + 'Get-PSDrive -PSProvider FileSystem' + $bt + ' and ' + $bt + 'net use' + $bt + '.'
                )
                ReplLines = @(
                    'and the current drive letters reported by ' + $bt + 'Get-PSDrive -PSProvider FileSystem' + $bt + ' and ' + $bt + 'net use' + $bt + '.'
                    '- ' + $bt + 'Invoke-DriveLetterAssignment: target partition <n>/<m> no longer exists' + $bt + ' -- the target partition was removed mid-search. Include what deleted it (a concurrent tool, an operator action, or a failed prior step) and the current partition inventory from ' + $bt + 'Get-Partition' + $bt + '.'
                    '- ' + $bt + 'Invoke-DriveLetterAssignment: target disk <n> is <offline|status>' + $bt + ' -- the disk holding the target partition went offline or is not Online. Include the disk state from ' + $bt + 'Get-Disk -Number <n> | Format-List' + $bt + ' and whether the disk came back online after the run.'
                )
            }
        )
    }
    @{
        Path = 'CHANGELOG.md'
        Edits = @(
            @{
                Tag   = 'CL-v47p3-OpeningLine'
                Note  = 'Reframe v47 patch 3 opening line: three -> several hardening changes'
                Guard = 'and several hardening changes across the three map builders'
                FindLines = @(
                    'and three hardening changes in the map builders'
                )
                ReplLines = @(
                    'and several hardening changes across the three map builders'
                )
            }
        )
    }
)

$overallFailed = $false

foreach ($file in $batch) {
    $path   = $file.Path
    $backup = "$path.bak"

    Write-Host ("=== {0} ===" -f $path)

    if (-not (Test-Path $path)) {
        Write-Host "FAIL path not found: $path"
        $overallFailed = $true
        continue
    }

    Copy-Item $path $backup -Force

    $bytes  = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }

    $crlf = ([char]13).ToString() + ([char]10).ToString()
    $lf   = ([char]10).ToString()
    $nl   = if ($text.Contains($crlf)) { $crlf } else { $lf }

    Write-Host ("BOM: {0}" -f $hasBom)
    Write-Host ("EOL: {0}" -f $(if ($nl -eq $crlf) { 'CRLF' } else { 'LF' }))

    $activeEdits = @()
    $fail = $false
    foreach ($edit in $file.Edits) {
        $findStr = $edit.FindLines -join $nl
        $replStr = $edit.ReplLines -join $nl

        if ($text.Contains($edit.Guard)) {
            Write-Host ("SKIP [{0}] {1}" -f $edit.Tag, $edit.Note)
            continue
        }
        $idx = $text.IndexOf($findStr)
        if ($idx -lt 0) {
            Write-Host ("FAIL [{0}] anchor not found" -f $edit.Tag)
            $fail = $true
            break
        }
        if ($text.IndexOf($findStr, $idx + 1) -ge 0) {
            Write-Host ("FAIL [{0}] anchor found multiple times" -f $edit.Tag)
            $fail = $true
            break
        }
        $activeEdits += @{ Tag = $edit.Tag; Note = $edit.Note; Find = $findStr; Repl = $replStr }
    }

    if ($fail) {
        Copy-Item $backup $path -Force
        Remove-Item $backup -Force
        $overallFailed = $true
        Write-Host ""
        continue
    }

    foreach ($edit in $activeEdits) {
        $before = $text
        $text = $text.Replace($edit.Find, $edit.Repl)
        if ($text -eq $before) {
            Write-Host ("FAIL [{0}] no change after Replace" -f $edit.Tag)
            Copy-Item $backup $path -Force
            Remove-Item $backup -Force
            $overallFailed = $true
            break
        }
        Write-Host ("OK   [{0}] {1}" -f $edit.Tag, $edit.Note)
    }

    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($hasBom))
    Remove-Item $backup -Force

    if ($path -like '*.ps1') {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $path).Path, [ref]$null, [ref]$parseErrors)
        if ($null -eq $parseErrors -or $parseErrors.Count -eq 0) {
            Write-Host 'PASS parser check'
        } else {
            Write-Host 'FAIL parser check:'
            $parseErrors | ForEach-Object { Write-Host ("  {0}" -f $_.Message) }
        }
        $finalBytes = [System.IO.File]::ReadAllBytes($path)
        if ($finalBytes.Length -ge 4) {
            $byteStr = '{0:X2} {1:X2} {2:X2} {3:X2}' -f $finalBytes[0], $finalBytes[1], $finalBytes[2], $finalBytes[3]
            Write-Host ("First 4 bytes: {0}" -f $byteStr)
            if ($hasBom) {
                if ($finalBytes[0] -eq 0xEF -and $finalBytes[1] -eq 0xBB -and $finalBytes[2] -eq 0xBF -and $finalBytes[3] -ne 0xEF) {
                    Write-Host 'PASS BOM check (single BOM, as expected)'
                } else {
                    Write-Host 'FAIL BOM check'
                }
            } else {
                if ($finalBytes[0] -ne 0xEF) {
                    Write-Host 'PASS BOM check (no BOM, as expected)'
                } else {
                    Write-Host 'FAIL BOM check (unexpected BOM)'
                }
            }
        }
    }
    Write-Host ""
}

if ($overallFailed) {
    Write-Host "One or more files were skipped due to a missing anchor. See FAIL lines above."
    Write-Host "Edit script complete. Delete this script from the repo root before committing."
    exit 1
}

Write-Host "Batch complete. Delete this script from the repo root before committing."
exit 0
