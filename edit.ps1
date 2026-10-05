# Confirm no stale harness-version references anywhere
Get-ChildItem -Path . -Recurse -Include *.md,*.ps1 -File |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -notlike '*.bak' } |
    Select-String -Pattern 'v24|v47 patch 2|v47\.2' -SimpleMatch |
    Select-Object Path, LineNumber, Line

# Confirm the changed-file set is exactly what we edited
git status --porcelain