@echo off
setlocal EnableExtensions DisableDelayedExpansion

:: Request a compact, readable console. Windows Terminal may ignore mode,
:: but the menu itself is designed to fit in a 30-line window anyway.
mode con: cols=110 lines=30 >nul 2>&1

title WinRE Manager - Menu

:: ========================================================================
:: WinRE Manager - interactive entry point
:: ========================================================================
:: This launcher is intentionally NOT elevated.
::
:: The .cmd itself is never relaunched elevated. Actions that need
:: administrator rights launch only the selected PowerShell process via
:: PowerShell Start-Process -Verb RunAs.
::
:: Menu presentation:
::   GREEN  = safe / recommended
::   CYAN   = information / recovery
::   BLUE   = maintenance / automation
::   YELLOW = live operation / confirmation
::   RED    = actual errors only
::
:: Consistency rules:
::   * Every option that launches an elevated action shows its own info
::     screen, then the UAC warning, then a `pause` gate. The operator
::     presses any key to continue or Ctrl+C to abort.
::   * The elevated launcher blocks until the elevated process exits, so
::     the menu re-renders against current disk state on return. A
::     completed backup makes the backup status indicator flip to
::     "Available"; deleting the last backup flips it back; installing or
::     removing the task updates the task-status indicator.
::
:: Menu entries:
::   Restore [8] and Clean up backups [C] are always shown. When no
::   default backup exists, the elevated screens check registered roots.
::   Restore also accepts an explicit backup path.
::   Update [U] is shown only when a newer version is available.
::
:: Update status is read from Check-Update.ps1, which performs a live
:: network check (GitHub Releases API, with a CHANGELOG.md fallback).
:: No cache is written. The check runs at most once per wrapper session;
:: the result is held in UPDATE_STATUS for the life of the session.
:: ========================================================================

:: ------------------------------------------------------------------------
:: ANSI colour support
:: ------------------------------------------------------------------------
for /F "delims=" %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"

set "RESET=%ESC%[0m"
set "BOLD=%ESC%[1m"
set "DIM=%ESC%[2m"

set "BLACK=%ESC%[30m"
set "WHITE=%ESC%[97m"
set "GRAY=%ESC%[90m"
set "RED=%ESC%[91m"
set "GREEN=%ESC%[92m"
set "YELLOW=%ESC%[93m"
set "BLUE=%ESC%[94m"
set "MAGENTA=%ESC%[95m"
set "CYAN=%ESC%[96m"

set "GREENBG=%ESC%[42m"
set "YELLOWBG=%ESC%[43m"
set "BLUEBG=%ESC%[44m"
set "CYANBG=%ESC%[46m"
set "MAGENTABG=%ESC%[45m"

:: ------------------------------------------------------------------------
:: Paths
:: ------------------------------------------------------------------------
set "SCRIPTS_DIR=%~dp0"
set "PROD_SCRIPT=%SCRIPTS_DIR%WinRE.ps1"
set "TEST_SCRIPT=%SCRIPTS_DIR%Test-WinRE.ps1"
set "UPDATE_CHECK_SCRIPT=%SCRIPTS_DIR%Check-Update.ps1"
set "CLEANUP_SCRIPT=%SCRIPTS_DIR%Cleanup-Backups.ps1"

set "LOGFILE=C:\ProgramData\OEM\Logs\WinRE-Manager.log"
set "TASK_NAME=Maintain Windows RE"

set "BACKUP_DEFAULT=C:\Backup\WindowsRE"

:: GitHub Releases page opened by the [U] menu option. Change here if the
:: repository moves or you prefer a different landing page.
set "RELEASES_URL=https://github.com/ArthurJDurand/WinRE-Manager/releases"

:: Stable installed copy used by the optional permanent maintenance task.
set "INSTALL_DIR=C:\ProgramData\OEM\WinRE-Manager"
set "INSTALLED_SCRIPT=%INSTALL_DIR%\WinRE.ps1"

:: ------------------------------------------------------------------------
:: PowerShell single-quoted-literal escaping
:: ------------------------------------------------------------------------
:: Values embedded inside single-quoted PowerShell string literals within
:: the Base64-encoded elevated commands. A literal apostrophe in any of
:: them must be doubled; the _ESC variables carry that substitution and
:: are what the TARGET_COMMAND builders consume.
set "PROD_SCRIPT_ESC=%PROD_SCRIPT:'=''%"
set "TEST_SCRIPT_ESC=%TEST_SCRIPT:'=''%"
set "INSTALLED_SCRIPT_ESC=%INSTALLED_SCRIPT:'=''%"
set "TASK_NAME_ESC=%TASK_NAME:'=''%"
set "CLEANUP_SCRIPT_ESC=%CLEANUP_SCRIPT:'=''%"
call :set_path_trust_helper

:: ------------------------------------------------------------------------
:: Preflight
:: ------------------------------------------------------------------------
if not exist "%PROD_SCRIPT%" (
    call :error_screen "Production script not found:" "%PROD_SCRIPT%"
    exit /b 1
)

if not exist "%TEST_SCRIPT%" (
    call :error_screen "Test harness not found:" "%TEST_SCRIPT%"
    exit /b 1
)

:: The update-check and cleanup helpers are optional. When missing, the
:: corresponding screens report that and the wrapper continues to function.

goto menu


:: ========================================================================
:: MAIN MENU
:: ========================================================================
:menu
cls
title WinRE Manager - Menu

:: ---- Backup presence (display only) ----
set "BACKUP_PRESENT=0"
if exist "%BACKUP_DEFAULT%\" (
    for /d %%D in ("%BACKUP_DEFAULT%\*") do (
        if exist "%%~fD\winre.wim" set "BACKUP_PRESENT=1"
    )
)

:: ---- Scheduled-task status ----
set "TASK_STATUS=%GRAY%Not installed%RESET%"
schtasks.exe /Query /TN "%TASK_NAME%" >nul 2>&1
if not errorlevel 1 set "TASK_STATUS=%GREEN%Installed%RESET%"

:: ---- Update status (session-cached) ----
if not defined UPDATE_STATUS_SET call :check_update_status

:: ---- Build the choice set ----
:: 1..8 fixed; C (clean up backups) fixed; U optional; Q fixed. The
:: errorlevel from choice.exe is the 1-based position in MENU_CHARS.
set "MENU_CHARS=12345678C"
set "RESTORE_EL=8"
set "CLEANUP_EL=9"
set "NEXT_EL=10"
set "UPDATE_EL=0"

if /I "%UPD_KIND%"=="UPDATE" set "MENU_CHARS=%MENU_CHARS%U"
if /I "%UPD_KIND%"=="UPDATE" set "UPDATE_EL=%NEXT_EL%"
if /I "%UPD_KIND%"=="UPDATE" set /a NEXT_EL+=1

set "MENU_CHARS=%MENU_CHARS%Q"
set "QUIT_EL=%NEXT_EL%"

:: ---- Render the menu ----
echo.
echo %CYAN%%BOLD%==============================================================================================%RESET%
echo %CYAN%%BOLD%                                      WinRE Manager%RESET%
echo %CYAN%%BOLD%==============================================================================================%RESET%
echo %DIM%%GRAY%                                 interactive launcher - not elevated%RESET%
echo.
set "BACKUP_STATUS=%YELLOW%Not found%RESET%"
if "%BACKUP_PRESENT%"=="1" set "BACKUP_STATUS=%GREEN%Available%RESET%"
echo  %GREENBG%%BLACK% BACKUP %RESET% %WHITE%Current: %RESET% %BACKUP_STATUS% %GRAY%     %RESET% %BLUEBG%%WHITE% TASK %RESET% %WHITE%Automatic maintenance: %RESET% %TASK_STATUS%
echo  %CYANBG%%BLACK% UPDATE %RESET% %WHITE%Version: %RESET% %UPDATE_STATUS%
echo.

echo  %GREEN%%BOLD%SAFETY%RESET% %GRAY%recommended before a live repair%RESET%
echo   %GREEN%%BOLD%[1]%RESET%  %WHITE%Back up current WinRE%RESET%                 %GRAY%preserve the active WIM%RESET%
echo   %GREEN%%BOLD%[C]%RESET%  %WHITE%Clean up old backups%RESET%                 %GRAY%delete saved WinRE images%RESET%
echo.
echo  %CYAN%%BOLD%DIAGNOSTICS%RESET% %GRAY%read-only / preview%RESET%
echo   [2]  %WHITE%Test harness%RESET%                         %GRAY%diagnostics and self-tests%RESET%
echo   [3]  %WHITE%Preview plan (DryRun)%RESET%                 %GRAY%calculate the plan; no changes%RESET%
echo   [4]  %WHITE%Show recent log%RESET%                       %GRAY%technical log + narrated entries%RESET%
echo.
echo  %BLUE%%BOLD%MAINTENANCE%RESET% %GRAY%optional unattended operation%RESET%
echo   [5]  %WHITE%Install automatic maintenance%RESET%         %GRAY%SYSTEM scheduled task%RESET%
echo   [6]  %WHITE%Remove automatic maintenance%RESET%          %GRAY%remove the scheduled task%RESET%
echo.
echo  %YELLOW%%BOLD%REPAIR%RESET% %GRAY%live WinRE operation%RESET%
echo   %YELLOWBG%%BLACK% LIVE %RESET% %YELLOW%%BOLD%[7]%RESET% %WHITE%Run WinRE Manager%RESET%                  %GRAY%real repair operation%RESET%
echo.
echo  %CYAN%%BOLD%RECOVERY%RESET% %GRAY%restore a saved WinRE image%RESET%
echo   %CYANBG%%BLACK% RESTORE %RESET% [8] %WHITE%Restore WinRE from backup%RESET%  %GRAY%select a saved image%RESET%
echo.

if /I "%UPD_KIND%"=="UPDATE" (
    echo  %YELLOW%%BOLD%UPDATE AVAILABLE%RESET% %GRAY%a newer version of WinRE Manager is available%RESET%
    echo   %YELLOWBG%%BLACK% GET %RESET% %YELLOW%%BOLD%[U]%RESET% %WHITE%Open releases page%RESET%        %GRAY%download the latest version%RESET%
    echo.
)

echo  %MAGENTA%%BOLD%[Q]%RESET%  %WHITE%Quit%RESET%                                      %GRAY%Backup default: %BACKUP_DEFAULT%%RESET%
echo %DIM%%GRAY%  Backups contain winre.wim; backup.json is optional. Each action validates its selection.%RESET%
choice /C %MENU_CHARS% /N /M "  Select an option: "
set "SEL=%errorlevel%"

:: ---- Dispatch ----
if "%SEL%"=="%QUIT_EL%" goto quit
if "%SEL%"=="1" goto run_backup
if "%SEL%"=="2" goto run_test
if "%SEL%"=="3" goto run_dry
if "%SEL%"=="4" goto show_log
if "%SEL%"=="5" goto install_task
if "%SEL%"=="6" goto remove_task
if "%SEL%"=="7" goto run_live_warning
if "%SEL%"=="%RESTORE_EL%" goto run_restore
if "%SEL%"=="%CLEANUP_EL%" goto cleanup_backups
if not "%UPDATE_EL%"=="0" if "%SEL%"=="%UPDATE_EL%" goto open_releases
goto menu


:: ========================================================================
:: BACKUP
:: ========================================================================
:: Destination is entered in the elevated PowerShell session, not here.
:: A path typed at a CMD prompt and later echoed is vulnerable to CMD's
:: '&' command-separator parsing; moving the prompt into PowerShell
:: eliminates that hazard entirely.
:run_backup
cls
title WinRE Manager - Backup

echo.
echo %GREEN%%BOLD%==============================================================================================%RESET%
echo %GREEN%%BOLD%                                  BACK UP CURRENT WinRE%RESET%
echo %GREEN%%BOLD%==============================================================================================%RESET%
echo.
echo %GREENBG%%BLACK% SAFE %RESET%  %WHITE%Recommended before a live repair.%RESET%
echo.
echo %WHITE%Creates a byte-for-byte copy of the currently registered WinRE image%RESET%
echo %WHITE%and records supporting metadata. It does not intentionally rebuild,%RESET%
echo %WHITE%replace, or reconfigure the active WinRE route.%RESET%
echo.
echo %GRAY%Default destination:%RESET% %WHITE%%BACKUP_DEFAULT%%RESET%
echo %YELLOW%For stronger protection, another physical disk, external drive,%RESET%
echo %YELLOW%or network storage is preferable to storing the backup only on C:.%RESET%
echo.
echo %WHITE%The destination is entered in the elevated PowerShell session.%RESET%
echo %WHITE%Press Enter there to use the default; type any other path to override.%RESET%
echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to begin.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "TARGET_COMMAND=$src='%PROD_SCRIPT_ESC%'; $q=[char]34; $default='%BACKUP_DEFAULT%'; Write-Host ''; Write-Host 'Backup destination' -ForegroundColor White; Write-Host ('  Press Enter for default: '+$default) -ForegroundColor DarkGray; Write-Host '  Or type a full path; another disk, external drive, or network share is preferred to C:.' -ForegroundColor DarkGray; Write-Host ''; $dest=Read-Host 'Destination'; if(-not $dest){ $dest=$default }; $dest=$dest.Trim(); Write-Host ''; Write-Host ('Using destination: '+$dest) -ForegroundColor Cyan; Write-Host ''; Write-Host 'Starting Backup as a child process...' -ForegroundColor Cyan; Write-Host ''; $dQ=$dest; if($dQ -match '(\\+)$'){ $dQ=$dQ+$Matches[1] }; $argLine='-NoProfile -ExecutionPolicy Bypass -File '+$q+$src+$q+' -Action Backup -BackupPath '+$q+$dQ+$q; try { $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -NoNewWindow -PassThru -Wait -ErrorAction Stop } catch { Write-Host ('Could not start Backup: '+$_.Exception.Message) -ForegroundColor Red; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true); exit 1 }; Write-Host ''; $code=$p.ExitCode; $color=if($code -eq 0){'Green'}elseif($code -eq 2){'Yellow'}elseif($code -eq 3){'Red'}else{'Yellow'}; Write-Host ('Backup finished. Exit code: '+$code) -ForegroundColor $color; Write-Host ''; Write-Host '  0 = success   1 = reboot required   2 = warning   3 = fatal' -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true)"
call :launch_elevated_command
goto menu


:: ========================================================================
:: CLEAN UP OLD BACKUPS
:: ========================================================================
:cleanup_backups
cls
title WinRE Manager - Clean Up Backups

echo.
echo %MAGENTA%%BOLD%==============================================================================================%RESET%
echo %MAGENTA%%BOLD%                                  CLEAN UP BACKUPS%RESET%
echo %MAGENTA%%BOLD%==============================================================================================%RESET%
echo.
echo %WHITE%Lists every valid backup under every registered backup location,%RESET%
echo %WHITE%shows per-backup size and the total, and lets you delete one,%RESET%
echo %WHITE%several, or all of them.%RESET%
echo.
echo %GRAY%Default location:%RESET% %WHITE%%BACKUP_DEFAULT%%RESET%
echo %GRAY%Additional roots are read from the manager config, if present.%RESET%
echo %GRAY%The listing is read-only until you type DELETE at the confirmation.%RESET%
echo.

if not exist "%CLEANUP_SCRIPT%" (
    echo %RED%%BOLD%Cleanup helper not found.%RESET%
    echo   %WHITE%%CLEANUP_SCRIPT%%RESET%
    echo.
    echo %YELLOW%Place Cleanup-Backups.ps1 beside this launcher and re-run.%RESET%
    echo.
    pause
    goto menu
)

if "%BACKUP_PRESENT%"=="1" (
    echo %GREEN%At least one backup is present under the default location.%RESET%
) else (
    echo %YELLOW%No backup found under the default location.%RESET%
    echo %YELLOW%The elevated session also checks registered backup locations.%RESET%
)
echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to continue.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "TARGET_COMMAND=$cleanup='%CLEANUP_SCRIPT_ESC%'; $q=[char]34; Write-Host ''; Write-Host 'Starting cleanup as a child process...' -ForegroundColor Cyan; Write-Host ''; $argLine='-NoProfile -ExecutionPolicy Bypass -File '+$q+$cleanup+$q; try { $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -NoNewWindow -PassThru -Wait -ErrorAction Stop } catch { Write-Host ('Could not start cleanup: '+$_.Exception.Message) -ForegroundColor Red; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true); exit 1 }; Write-Host ''; $code=$p.ExitCode; $color=if($code -eq 0){'Green'}else{'Yellow'}; Write-Host ('Cleanup finished. Exit code: '+$code) -ForegroundColor $color; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true)"
call :launch_elevated_command
goto menu


:: ========================================================================
:: RESTORE
:: ========================================================================
:: The backup directory is entered in the elevated PowerShell session, for
:: the same '&'-in-path reason as Backup. The pre-flight validity checks
:: (winre.wim required, backup.json optional) also run there.
:run_restore
cls
title WinRE Manager - Restore

echo.
echo %CYAN%%BOLD%==============================================================================================%RESET%
echo %CYAN%%BOLD%                                  RESTORE WinRE BACKUP%RESET%
echo %CYAN%%BOLD%==============================================================================================%RESET%
echo.
echo %CYANBG%%BLACK% RESTORE %RESET%  %WHITE%Put a previously captured WinRE image back into use.%RESET%
echo.
echo %WHITE%WinRE.ps1 validates the backup before replacing the active WIM and%RESET%
echo %WHITE%then re-registers and verifies WinRE.%RESET%
echo.
echo %YELLOW%Restore does not recreate a deleted recovery partition or invent a%RESET%
echo %YELLOW%replacement route. A usable current WinRE route must already exist.%RESET%
echo.

if "%BACKUP_PRESENT%"=="1" (
    echo %GRAY%At least one backup is present under the default location.%RESET%
    echo %GRAY%The elevated session will offer the newest backup as the default.%RESET%
) else (
    echo %YELLOW%No backup found under %BACKUP_DEFAULT%.%RESET%
    echo %YELLOW%The elevated session checks registered locations and allows an explicit path.%RESET%
)
echo.
echo %WHITE%The backup directory is entered in the elevated PowerShell session.%RESET%
echo.
echo %BOLD%Type RESTORE exactly to continue. Anything else cancels.%RESET%
echo.

set "CONFIRM="
set /p "CONFIRM=  Confirmation: "

if /I not "%CONFIRM%"=="RESTORE" (
    echo.
    echo %GREEN%Cancelled. No changes were made.%RESET%
    echo.
    pause
    goto menu
)

echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to begin.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "TARGET_COMMAND=$src='%PROD_SCRIPT_ESC%'; $q=[char]34; $default='%BACKUP_DEFAULT%'; $roots=@($default); $cfg='C:\ProgramData\OEM\WinRE-Manager\manager.json'; $cfgOk=$false; if(Test-Path -LiteralPath $cfg -PathType Leaf){ $cfgDir=Split-Path $cfg -Parent; $cfgParent=Split-Path $cfgDir -Parent; if((_T $cfgDir 'D') -and (_T $cfgParent 'D') -and (_T $cfg 'F')){ $cfgOk=$true } }; if($cfgOk){ try { $cj=Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; $cr=@(); if($cj.BackupCatalog -and $cj.BackupCatalog.Roots){ $cr=@($cj.BackupCatalog.Roots) } elseif($cj.BackupRoots){ $cr=@($cj.BackupRoots) }; foreach($r in $cr){ if($r -and ($roots -notcontains [string]$r)){ $roots+=[string]$r } } } catch {} }; $allBk=@(); foreach($r in $roots){ if(-not (Test-Path -LiteralPath $r -PathType Container)){ continue }; $subs=@(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending); foreach($d in $subs){ try { $dItem=Get-Item -LiteralPath $d.FullName -Force -ErrorAction Stop; if((($dItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0){ continue } } catch { continue }; if(-not (Test-Path -LiteralPath (Join-Path $d.FullName 'winre.wim') -PathType Leaf)){ continue }; $hasJ=Test-Path -LiteralPath (Join-Path $d.FullName 'backup.json') -PathType Leaf; $allBk += [PSCustomObject]@{ Path=$d.FullName; HasSidecar=$hasJ } } }; $latest=if($allBk.Count -gt 0){ $allBk[0].Path } else { $null }; Write-Host ''; Write-Host 'Backup directory' -ForegroundColor White; if($allBk.Count -gt 0){ Write-Host '  Available backups:' -ForegroundColor DarkGray; for($i=0;$i -lt $allBk.Count;$i++){ $tag=if($allBk[$i].HasSidecar){''}else{'  [WIM-ONLY, reduced verification]'}; $color=if($allBk[$i].HasSidecar){'DarkGray'}else{'Yellow'}; Write-Host ('  ['+($i+1)+'] '+$allBk[$i].Path+$tag) -ForegroundColor $color }; Write-Host '  Press Enter for newest, a number to select, or type a full path.' -ForegroundColor DarkGray } else { Write-Host '  No backup found under any registered root.' -ForegroundColor Yellow; Write-Host '  Type the full path to a backup directory.' -ForegroundColor DarkGray }; Write-Host ''; $path=Read-Host 'Path'; if(-not $path -and $latest){ $path=$latest } elseif($path -match '^\d+$'){ $n=[int]$path; if($n -ge 1 -and $n -le $allBk.Count){ $path=$allBk[$n-1].Path } }; if(-not $path){ Write-Host ''; Write-Host 'No backup directory specified. Nothing was launched.' -ForegroundColor Red; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true); exit 1 }; $path=$path.Trim(); if(-not (Test-Path -LiteralPath (Join-Path $path 'winre.wim') -PathType Leaf)){ Write-Host ''; Write-Host ('winre.wim not found at '+$path) -ForegroundColor Red; Write-Host ''; Write-Host 'Nothing was launched.' -ForegroundColor Yellow; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true); exit 1 }; if(-not (Test-Path -LiteralPath (Join-Path $path 'backup.json') -PathType Leaf)){ Write-Host ''; Write-Host ('WARNING: backup.json not found at '+$path) -ForegroundColor Yellow; Write-Host '         Proceeding with reduced verification (WIM-only restore).' -ForegroundColor Yellow }; Write-Host ''; Write-Host ('Selected source: '+$path) -ForegroundColor Cyan; Write-Host ''; Write-Host 'Starting Restore as a child process...' -ForegroundColor Cyan; Write-Host ''; $pQ=$path; if($pQ -match '(\\+)$'){ $pQ=$pQ+$Matches[1] }; $sQ=$src; if($sQ -match '(\\+)$'){ $sQ=$sQ+$Matches[1] }; $argLine='-NoProfile -ExecutionPolicy Bypass -File '+$q+$sQ+$q+' -Action Restore -BackupPath '+$q+$pQ+$q; try { $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -NoNewWindow -PassThru -Wait -ErrorAction Stop } catch { Write-Host ('Could not start Restore: '+$_.Exception.Message) -ForegroundColor Red; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true); exit 1 }; Write-Host ''; $code=$p.ExitCode; $color=if($code -eq 0){'Green'}elseif($code -eq 2){'Yellow'}elseif($code -eq 3){'Red'}else{'Yellow'}; Write-Host ('Restore finished. Exit code: '+$code) -ForegroundColor $color; Write-Host ''; Write-Host '  0 = success   1 = reboot required   2 = warning   3 = fatal' -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true)"
call :launch_elevated_command
goto menu


:: ========================================================================
:: OPEN RELEASES PAGE
:: ========================================================================
:: Opened only when Check-Update.ps1 reports an update is available. Opens
:: the default browser to the GitHub Releases page. Nothing is downloaded
:: by the wrapper; the operator chooses what to fetch.
:open_releases
cls
title WinRE Manager - Update Available

echo.
echo %YELLOW%%BOLD%==============================================================================================%RESET%
echo %YELLOW%%BOLD%                                  UPDATE AVAILABLE%RESET%
echo %YELLOW%%BOLD%==============================================================================================%RESET%
echo.
echo %WHITE%A newer version of WinRE Manager is available.%RESET%
echo.
echo %GRAY%Remote version:%RESET% %YELLOW%%BOLD%%UPD_DETAIL%%RESET%
echo.
echo %WHITE%The wrapper will open the GitHub Releases page in your default browser.%RESET%
echo %WHITE%Download the new files there and replace the local copies.%RESET%
echo.
echo %GRAY%Releases URL:%RESET% %WHITE%%RELEASES_URL%%RESET%
echo.

choice /C QO /N /M "  Open releases page? [O/Q]: "
if errorlevel 2 start "" "%RELEASES_URL%"
goto menu


:: ========================================================================
:: TEST HARNESS
:: ========================================================================
:run_test
cls
title WinRE Manager - Test Harness

echo.
echo %GREEN%%BOLD%==============================================================================================%RESET%
echo %GREEN%%BOLD%                                  TEST HARNESS - READ ONLY%RESET%
echo %GREEN%%BOLD%==============================================================================================%RESET%
echo.
echo %GREENBG%%BLACK% SAFE %RESET%  %WHITE%Diagnostics and self-tests only.%RESET%
echo.
echo %WHITE%Test-WinRE.ps1 runs elevated so partition, BitLocker, DISM and WinRE%RESET%
echo %WHITE%queries can return complete information. It does not intentionally%RESET%
echo %WHITE%modify WinRE, partitions, BitLocker, or Windows system state, but may%RESET%
echo %WHITE%create and remove its own test artifacts.%RESET%
echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to continue.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "TARGET_COMMAND=& '%TEST_SCRIPT_ESC%'"
call :launch_elevated_command
goto menu


:: ========================================================================
:: DRY RUN (with child-process runner and pause)
:: ========================================================================
:: WinRE.ps1 uses explicit `exit` statements. Appending `; Read-Host` or
:: relying on -NoExit both fail to keep the window open on the normal path.
:: The runner starts WinRE.ps1 -DryRun as a child process in the SAME
:: console (-NoNewWindow, -Wait, -PassThru), captures its exit code, prints
:: the code, and only then pauses for the operator.
:run_dry
cls
title WinRE Manager - DryRun

echo.
echo %CYAN%%BOLD%==============================================================================================%RESET%
echo %CYAN%%BOLD%                                  PLAN PREVIEW - DryRun%RESET%
echo %CYAN%%BOLD%==============================================================================================%RESET%
echo.
echo %GREENBG%%BLACK% SAFE %RESET%  %WHITE%Discovery, validation, sizing and planning only.%RESET%
echo.
echo %WHITE%WinRE.ps1 will calculate what a permitted live run would do.%RESET%
echo %WHITE%DryRun performs no live partition or WinRE changes.%RESET%
echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to continue.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "TARGET_COMMAND=$src='%PROD_SCRIPT_ESC%'; $q=[char]34; Write-Host ''; Write-Host 'Starting DryRun as a child process...' -ForegroundColor Cyan; Write-Host ''; try { $p=Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File '+$q+$src+$q+' -DryRun') -NoNewWindow -PassThru -Wait -ErrorAction Stop } catch { Write-Host ('Could not start DryRun: '+$_.Exception.Message) -ForegroundColor Red; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true); exit 1 }; Write-Host ''; $code=$p.ExitCode; $color=if($code -eq 0){'Green'}elseif($code -eq 2){'Yellow'}elseif($code -eq 3){'Red'}else{'Yellow'}; Write-Host ('DryRun finished. Exit code: '+$code) -ForegroundColor $color; Write-Host ''; Write-Host '  0 = success   1 = reboot required   2 = warning (deferred)   3 = fatal' -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true)"
call :launch_elevated_command
goto menu


:: ========================================================================
:: LIVE REPAIR
:: ========================================================================
:run_live_warning
cls
title WinRE Manager - Live Repair

echo.
echo %YELLOW%%BOLD%==============================================================================================%RESET%
echo %YELLOW%%BOLD%                                  LIVE REPAIR - CONFIRM%RESET%
echo %YELLOW%%BOLD%==============================================================================================%RESET%
echo.
echo %YELLOWBG%%BLACK% LIVE %RESET%  %WHITE%This is the real WinRE repair operation.%RESET%
echo.
echo %WHITE%WinRE Manager performs its own discovery, validation and fail-closed%RESET%
echo %WHITE%safety checks. If the plan is permitted, it may resize partitions,%RESET%
echo %WHITE%replace/create recovery storage, service the WinRE image, apply approved%RESET%
echo %WHITE%driver changes, and register/verify the resulting WinRE environment.%RESET%
echo.
echo %GREEN%%BOLD%When no repair is required, WinRE Manager takes the fast path and%RESET%
echo %GREEN%%BOLD%leaves the existing WinRE image and partition layout untouched.%RESET%
echo.
echo %GREENBG%%BLACK% RECOMMENDED %RESET% %WHITE%Back up the current WinRE first with option [1].%RESET%
echo %GRAY%The backup protects the current WIM from a failed replacement; it is not%RESET%
echo %GRAY%a substitute for a full-disk backup.%RESET%
echo.
echo %WHITE%Before continuing: save work, close disk-management/backup tools,%RESET%
echo %WHITE%avoid interruption during changes, and ensure stable power.%RESET%
echo.
echo %YELLOW%%BOLD%Type RUN exactly to continue. Anything else cancels.%RESET%
echo.

set "CONFIRM="
set /p "CONFIRM=  Confirmation: "

if /I not "%CONFIRM%"=="RUN" (
    echo.
    echo %GREEN%Cancelled. No changes were made.%RESET%
    echo.
    pause
    goto menu
)

echo.
echo %GREEN%%BOLD%Confirmation accepted.%RESET%
echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to start the live repair.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "TARGET_COMMAND=$src='%PROD_SCRIPT_ESC%'; $q=[char]34; Write-Host ''; Write-Host 'Starting live WinRE repair as a child process...' -ForegroundColor Cyan; Write-Host ''; $argLine='-NoProfile -ExecutionPolicy Bypass -File '+$q+$src+$q; try { $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -NoNewWindow -PassThru -Wait -ErrorAction Stop } catch { Write-Host ('Could not start WinRE Manager: '+$_.Exception.Message) -ForegroundColor Red; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true); exit 1 }; Write-Host ''; $code=$p.ExitCode; $color=if($code -eq 0){'Green'}elseif($code -eq 1){'Cyan'}elseif($code -eq 2){'Yellow'}elseif($code -eq 3){'Red'}else{'Yellow'}; Write-Host ('Live repair finished. Exit code: '+$code) -ForegroundColor $color; Write-Host ''; Write-Host '  0 = success   1 = reboot required   2 = warning   3 = fatal' -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true)"
call :launch_elevated_command
goto menu


:: ========================================================================
:: LOG VIEWER
:: ========================================================================
:show_log
cls
title WinRE Manager - Recent Log

echo.
echo %MAGENTA%%BOLD%==============================================================================================%RESET%
echo %MAGENTA%%BOLD%                                      RECENT LOG%RESET%
echo %MAGENTA%%BOLD%==============================================================================================%RESET%
echo.

if not exist "%LOGFILE%" (
    echo %YELLOW%No log file was found at:%RESET%
    echo.
    echo   %WHITE%%LOGFILE%%RESET%
    echo.
    pause
    goto menu
)

echo %GRAY%Showing the last 50 log entries.%RESET%
echo.
powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%LOGFILE%' -Tail 50"

echo.
echo %MAGENTA%%BOLD%==============================================================================================%RESET%
echo %CYAN%%BOLD%[O]%RESET% %WHITE%Open full log in Notepad%RESET%
echo %CYAN%%BOLD%[Q]%RESET% %WHITE%Return to menu%RESET%
echo.

choice /C OQ /N /M "  Selection [O/Q]: "
if errorlevel 2 goto menu
if errorlevel 1 start "" notepad.exe "%LOGFILE%"
goto menu


:: ========================================================================
:: INSTALL OPTIONAL PERMANENT MAINTENANCE TASK
:: ========================================================================
:install_task
cls
title WinRE Manager - Install Automatic Maintenance

echo.
echo %BLUE%%BOLD%==============================================================================================%RESET%
echo %BLUE%%BOLD%                             INSTALL AUTOMATIC MAINTENANCE%RESET%
echo %BLUE%%BOLD%==============================================================================================%RESET%
echo.
echo %WHITE%Creates an optional permanent Scheduled Task:%RESET% %CYAN%%TASK_NAME%%RESET%
echo %WHITE%Runs the normal WinRE.ps1 action as:%RESET% %GREEN%%BOLD%NT AUTHORITY\SYSTEM%RESET%
echo.
echo %WHITE%Schedule:%RESET% %GRAY%Startup (+5 minutes) and every 30 days at 03:00.%RESET%
echo %WHITE%Conditions:%RESET% %GRAY%start when available, no idle requirement,%RESET%
echo %WHITE%%GRAY%           battery allowed, no battery-stop, 24-hour time limit,%RESET%
echo %WHITE%%GRAY%           network not required (offline fallback supported).%RESET%
echo %WHITE%Concurrency:%RESET% %GRAY%ignore a new instance when one is already running.%RESET%
echo.
echo %WHITE%WinRE.ps1 is copied to the stable location:%RESET%
echo   %WHITE%%INSTALLED_SCRIPT%%RESET%
echo %GRAY%The installed copy is SHA256-verified and its location trust-checked.%RESET%
echo %GRAY%Untrusted existing permissions cause refusal; they are not changed.%RESET%
echo.
echo %YELLOW%Re-running this option refreshes the installed script and re-registers%RESET%
echo %YELLOW%the task. Removing the task does not delete the installed script.%RESET%
echo.
echo %BOLD%Type INSTALL to continue. Anything else cancels.%RESET%
echo.

set "CONFIRM="
set /p "CONFIRM=  Confirmation: "
if /I not "%CONFIRM%"=="INSTALL" (
    echo.
    echo %GREEN%Cancelled. No task was changed.%RESET%
    echo.
    pause
    goto menu
)

echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to install the task.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

call :set_task_install_command
call :launch_elevated_command
goto menu


:: ========================================================================
:: REMOVE OPTIONAL PERMANENT MAINTENANCE TASK
:: ========================================================================
:remove_task
cls
title WinRE Manager - Remove Automatic Maintenance

echo.
echo %BLUE%%BOLD%==============================================================================================%RESET%
echo %BLUE%%BOLD%                              REMOVE AUTOMATIC MAINTENANCE%RESET%
echo %BLUE%%BOLD%==============================================================================================%RESET%
echo.
echo %WHITE%Removes the permanent Scheduled Task:%RESET% %CYAN%%TASK_NAME%%RESET%
echo.
echo %GREENBG%%BLACK% SAFE %RESET% %WHITE%No WinRE, partition, BitLocker or WIM changes are made.%RESET%
echo.
echo %GRAY%The stable installed copy remains at:%RESET%
echo   %WHITE%%INSTALLED_SCRIPT%%RESET%
echo.
echo %BOLD%Type REMOVE to continue. Anything else cancels.%RESET%
echo.

set "CONFIRM="
set /p "CONFIRM=  Confirmation: "
if /I not "%CONFIRM%"=="REMOVE" (
    echo.
    echo %GREEN%Cancelled. No task was changed.%RESET%
    echo.
    pause
    goto menu
)

echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to remove the task.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

call :set_task_remove_command
call :launch_elevated_command
goto menu


:: ========================================================================
:: UPDATE STATUS SUBROUTINE
:: ========================================================================
:: Reads the live update status from Check-Update.ps1 and maps it to a
:: coloured display string. Result is stored in UPDATE_STATUS for the menu;
:: UPD_KIND carries the raw kind ("UPDATE" / "CURRENT" / "AHEAD" /
:: "ERROR") for the caller to decide whether to show the [U] entry.
:: No cache file is involved; the check runs once per wrapper session.
:check_update_status
set "UPDATE_STATUS=%GRAY%checking...%RESET%"
set "UPD_KIND="
set "UPD_DETAIL="

if not exist "%UPDATE_CHECK_SCRIPT%" (
    set "UPDATE_STATUS=%GRAY%not available%RESET%"
    set "UPDATE_STATUS_SET=1"
    goto :eof
)

set "UPDATE_RESULT="
for /f "delims=" %%R in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UPDATE_CHECK_SCRIPT%" 2^>nul') do (
    if not defined UPDATE_RESULT set "UPDATE_RESULT=%%R"
)

if not defined UPDATE_RESULT (
    set "UPDATE_STATUS=%GRAY%not available%RESET%"
    set "UPDATE_STATUS_SET=1"
    goto :eof
)

for /f "tokens=1,2 delims=|" %%A in ("%UPDATE_RESULT%") do (
    set "UPD_KIND=%%A"
    set "UPD_DETAIL=%%B"
)

if /I "%UPD_KIND%"=="UPDATE" (
    if defined UPD_DETAIL (
        set "UPDATE_STATUS=%YELLOW%%BOLD%Update available: %UPD_DETAIL%%RESET%"
    ) else (
        set "UPDATE_STATUS=%YELLOW%%BOLD%Update available%RESET%"
    )
) else if /I "%UPD_KIND%"=="CURRENT" (
    set "UPDATE_STATUS=%GREEN%Up to date%RESET%"
) else if /I "%UPD_KIND%"=="AHEAD" (
    set "UPDATE_STATUS=%CYAN%Dev build (ahead of release)%RESET%"
) else (
    set "UPDATE_STATUS=%GRAY%not available%RESET%"
)
set "UPDATE_STATUS_SET=1"
goto :eof


:: ========================================================================
:: ELEVATED POWERSHELL LAUNCHER
:: ========================================================================
:: All elevated actions route through this launcher. TARGET_COMMAND is
:: raw PowerShell text. The shared trust helper and JSON-serialized install
:: paths are prepended before UTF-16/Base64 encoding and handed to
:: Start-Process, so no shell quoting is ever performed on paths or
:: arguments. CMD assignments stay below 8191 characters; the encoded child
:: arguments are bounded separately below the Windows process limit.
::
:: -Wait makes the launcher block until the elevated process (and any
:: children it spawns) exits. The wrapper then returns to the menu, which
:: recomputes BACKUP_PRESENT, TASK_STATUS, and the update indicator
:: against the current disk state.
:launch_elevated_command

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$paths=@{Source=$env:PROD_SCRIPT;InstalledScript=$env:INSTALLED_SCRIPT;TaskName=$env:TASK_NAME}|ConvertTo-Json -Compress; $quote=[string][char]39; $prefix='$wrapperPaths=ConvertFrom-Json '+$quote+$paths.Replace($quote,($quote+$quote))+$quote+'; '; if(-not $env:PATH_TRUST_HELPER -or -not $env:TARGET_COMMAND){exit 1}; $b64=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix+[string]$env:PATH_TRUST_HELPER+'; '+[string]$env:TARGET_COMMAND)); $argsLine='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+$b64; if($argsLine.Length -gt 30000){ Write-Host 'Action is too long for the Windows process command line. Shorten the script path.' -ForegroundColor Red; exit 2 }; try { Start-Process -FilePath 'powershell.exe' -ArgumentList $argsLine -Verb RunAs -Wait -ErrorAction Stop; exit 0 } catch { exit 1 }"

set "LAUNCH_RESULT=%errorlevel%"

if not "%LAUNCH_RESULT%"=="0" (
    echo.
    echo %YELLOW%%BOLD%UAC was cancelled or the elevated process could not be started.%RESET%
    echo %GRAY%No change was initiated by this launcher.%RESET%
    echo.
    pause
)

exit /b %LAUNCH_RESULT%


:: ========================================================================
:: TASK COMMAND BUILDERS
:: ========================================================================
:: One wrapper copy of the ACL policy, used by Restore and Install.
:: Startup always overwrites any inherited PATH_TRUST_HELPER environment value.
:set_path_trust_helper
set "PATH_TRUST_HELPER=function _T($p,$k){ if(-not $p){ return $false }; $e=$false; if($k -eq 'F'){ $e=Test-Path -LiteralPath $p -PathType Leaf } else { $e=Test-Path -LiteralPath $p -PathType Container }; if(-not $e){ return $false }; $a=$null; try { $a=Get-Acl -LiteralPath $p -ErrorAction Stop } catch { return $false }; if(-not $a -or -not $a.Owner){ return $false }; $o=$null; try { if($a.Owner -is [System.Security.Principal.SecurityIdentifier]){ $o=$a.Owner.Value } elseif($a.Owner -is [System.Security.Principal.IdentityReference]){ $o=$a.Owner.Translate([System.Security.Principal.SecurityIdentifier]).Value } else { $os=[string]$a.Owner; if($os -match '^S-1-'){ $o=$os } else { $o=(New-Object System.Security.Principal.NTAccount($os)).Translate([System.Security.Principal.SecurityIdentifier]).Value } } } catch { return $false }; if(@('S-1-5-18','S-1-5-32-544') -notcontains $o){ return $false }; $ta=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'); $m=$null; if($k -eq 'F'){ $m=([int][System.Security.AccessControl.FileSystemRights]::WriteData) -bor ([int][System.Security.AccessControl.FileSystemRights]::AppendData) -bor ([int][System.Security.AccessControl.FileSystemRights]::Delete) -bor ([int][System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles) -bor ([int][System.Security.AccessControl.FileSystemRights]::TakeOwnership) -bor ([int][System.Security.AccessControl.FileSystemRights]::ChangePermissions) } else { $m=([int][System.Security.AccessControl.FileSystemRights]::Delete) -bor ([int][System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles) -bor ([int][System.Security.AccessControl.FileSystemRights]::TakeOwnership) -bor ([int][System.Security.AccessControl.FileSystemRights]::ChangePermissions) }; foreach($ace in $a.Access){ if($ace.AccessControlType -ne 'Allow'){ continue }; if(($ace.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0){ continue }; $s=$null; try { $s=$ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { return $false }; if($ta -contains $s){ continue }; if((([int]$ace.FileSystemRights) -band $m) -ne 0){ return $false } }; return $true }"
exit /b 0

:set_task_install_command
set "TARGET_COMMAND=$ErrorActionPreference='Stop'; $src=$wrapperPaths.Source; $dst=$wrapperPaths.InstalledScript; $name=$wrapperPaths.TaskName; $dstDir=Split-Path -Path $dst -Parent; function _Item($p){ try { return Get-Item -LiteralPath $p -Force -ErrorAction Stop } catch { if($_.CategoryInfo.Category -eq 'ObjectNotFound'){ return $null }; throw } }; function _Security($kind){ $a=New-Object ('Security.AccessControl.'+$kind+'Security'); $a.SetAccessRuleProtection($true,$false); $a.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544'))); foreach($s in @('S-1-5-18','S-1-5-32-544')){ $i=New-Object Security.Principal.SecurityIdentifier($s); $r=if($kind -eq 'Directory'){ New-Object Security.AccessControl.FileSystemAccessRule($i,'FullControl','ContainerInherit,ObjectInherit','None','Allow') }else{ New-Object Security.AccessControl.FileSystemAccessRule($i,'FullControl','Allow') }; [void]$a.AddAccessRule($r) }; return $a }; function _NewDirectory($p,$a){ if($PSVersionTable.PSEdition -eq 'Core'){ [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($p),$a) }else{ [IO.Directory]::CreateDirectory($p,$a) | Out-Null } }; function _Root($p){ $a=Get-Acl -LiteralPath $p -ErrorAction Stop; $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'); if($trusted -notcontains $a.GetOwner([Security.Principal.SecurityIdentifier]).Value){ throw ('Untrusted install volume owner: '+$p) }; $m=([int][Security.AccessControl.FileSystemRights]::Delete) -bor ([int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles) -bor ([int][Security.AccessControl.FileSystemRights]::TakeOwnership) -bor ([int][Security.AccessControl.FileSystemRights]::ChangePermissions); foreach($ace in $a.Access){ if($ace.AccessControlType -ne 'Allow' -or ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){ continue }; if(($trusted -notcontains $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value) -and (([int]$ace.FileSystemRights) -band $m)){ throw ('Untrusted install volume permissions: '+$p) } } }; function _Directories($p){ $root=[IO.Path]::GetPathRoot($p); $chain=@(); for($x=$p;$x;$x=Split-Path -Path $x -Parent){ $chain=@($x)+$chain }; foreach($x in $chain){ $e=_Item $x; if(-not $e){ if($x -eq $root){ throw ('Install volume is unavailable: '+$x) }; _NewDirectory $x (_Security 'Directory'); $e=_Item $x }; if(-not $e -or -not $e.PSIsContainer -or ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)){ throw ('Unsafe install directory: '+$x) }; if($x -eq $root){ _Root $x }elseif(-not (_T $x 'D')){ throw ('Untrusted install directory; existing permissions were not changed: '+$x) } } }; function _File($p){ $e=_Item $p; if(-not $e){ return $false }; if($e.PSIsContainer -or ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (_T $p 'F')){ throw ('Untrusted install file; existing permissions were not changed: '+$p) }; return $true }; function _Stage($s,$p,[ref]$created){ $r=$null; $w=$null; try { $r=[IO.File]::Open($s,'Open','Read','Read'); $a=_Security 'File'; if($PSVersionTable.PSEdition -eq 'Core'){ $w=[IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($p),[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::None,$a) }else{ $w=New-Object IO.FileStream($p,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::Read,4096,[IO.FileOptions]::None,$a) }; $created.Value=$true; $r.CopyTo($w); $w.Flush($true); $w.Dispose(); $w=$null; $r.Position=0; $h=(Get-FileHash -InputStream $r -Algorithm SHA256 -ErrorAction Stop).Hash; $copyHash=(Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash; if($h -notmatch '^[A-Fa-f0-9]{64}$' -or $copyHash -ne $h){ throw ('Install staging hash mismatch. Source='+$h+' Copy='+$copyHash) }; return $h }finally{ if($w){ $w.Dispose() }; if($r){ $r.Dispose() } } }; function _Publish($s,$d,$replace){ if($replace){ [IO.File]::Replace($s,$d,$null) }else{ [IO.File]::Move($s,$d) } }; function _OpenRead($p){ return [IO.File]::Open($p,'Open','Read','Read') }; function _DeleteStage($p){ [IO.File]::Delete($p) }; function _Failure($e){ Write-Host ''; Write-Host ('Automatic maintenance installation failed: '+$e.Exception.Message) -ForegroundColor Red; Write-Host 'Review the error before retrying.'; Write-Host 'Press any key to close this window...'; try { [void][Console]::ReadKey($true) } catch { }; exit 1 }; try { if(-not (Test-Path -LiteralPath $src -PathType Leaf -ErrorAction Stop)){ throw ('Production script not found: '+$src) }; _Directories $dstDir; $hadDestination=_File $dst; $stage=Join-Path $dstDir ('.WinRE-Install-'+[guid]::NewGuid().ToString('N')+'.tmp'); $stageCreated=$false; $publicationAttempted=$false; $held=$null; try { $srcHash=_Stage $src $stage ([ref]$stageCreated); if(-not (_File $stage)){ throw 'Install staging file disappeared.' }; _Directories $dstDir; if((_File $dst) -ne $hadDestination){ throw 'Install destination changed during preparation.' }; $publicationAttempted=$true; try { _Publish $stage $dst $hadDestination } catch { throw ('Install publication failed. Verify target='+$dst+'; retained staging path (if present)='+$stage+'; '+$_.Exception.Message) }; $stageCreated=$false; if(-not (_File $dst)){ throw 'Installed script disappeared.' }; $held=_OpenRead $dst; $dstHash=(Get-FileHash -InputStream $held -Algorithm SHA256 -ErrorAction Stop).Hash; if($srcHash -ne $dstHash){ throw ('Installed script hash mismatch. Source='+$srcHash+' Copy='+$dstHash) }; _Directories $dstDir; if(-not (_File $dst)){ throw 'Installed script failed final trust verification.' }; $q=[char]34; $argLine='-NoProfile -ExecutionPolicy Bypass -File '+$q+$dst+$q; $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine -WorkingDirectory $dstDir; $bootTrigger=New-ScheduledTaskTrigger -AtStartup; $bootTrigger.Delay='PT5M'; $monthlyTrigger=New-ScheduledTaskTrigger -Daily -At '03:00' -DaysInterval 30; $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest; $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 24); $settings.RunOnlyIfIdle=$false; $settings.RunOnlyIfNetworkAvailable=$false; $settings.IdleSettings.StopOnIdleEnd=$false; $settings.IdleSettings.RestartOnIdle=$false; Register-ScheduledTask -TaskName $name -Action $action -Trigger @($bootTrigger,$monthlyTrigger) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null; }finally{ if($held){ $held.Dispose() }; if($stageCreated -and -not $publicationAttempted){ try { if(_File $stage){ _DeleteStage $stage } } catch { Write-Warning ('Protected install staging file retained: '+$stage) } } }; } catch { _Failure $_ }; Write-Host ''; Write-Host 'Automatic WinRE maintenance installed.' -ForegroundColor Green; Write-Host ('Task:   '+$name); Write-Host 'Run as: NT AUTHORITY\SYSTEM'; Write-Host ('Script: '+$dst); Write-Host ('SHA256: '+$dstHash) -ForegroundColor DarkGray; Write-Host 'Schedule: startup (+5 minutes), every 30 days at 03:00.'; Write-Host 'Battery allowed; no idle or network requirement; 24-hour limit.'; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true)"
exit /b 0

:set_task_remove_command
set "TARGET_COMMAND=$ErrorActionPreference='Stop'; $name='%TASK_NAME_ESC%'; $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue; if($existing){ Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop; Write-Host ''; Write-Host ('Automatic WinRE maintenance removed: '+$name) -ForegroundColor Green } else { Write-Host ''; Write-Host ('No scheduled task named '+$name+' was found.') -ForegroundColor Yellow }; Write-Host ''; Write-Host 'The installed WinRE.ps1 copy was not removed.' -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][Console]::ReadKey($true)"
exit /b 0


:: ========================================================================
:: ERROR SCREEN
:: ========================================================================
:error_screen

cls
title WinRE Manager - Error

echo.
echo %RED%%BOLD%!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!%RESET%
echo %RED%%BOLD%!                              ERROR                             !%RESET%
echo %RED%%BOLD%!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!%RESET%
echo.
echo %RED%%BOLD%%~1%RESET%
echo.
echo   %WHITE%%~2%RESET%
echo.
echo %YELLOW%The launcher cannot continue until the required file is restored.%RESET%
echo.
pause
exit /b 0


:: ========================================================================
:: QUIT
:: ========================================================================
:quit
cls
title WinRE Manager

echo.
echo %CYAN%%BOLD%WinRE Manager closed.%RESET%
echo.

endlocal
exit /b 0
