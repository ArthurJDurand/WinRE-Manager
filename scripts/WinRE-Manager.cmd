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
::     completed backup makes Restore [8] and Clean up backups [C]
::     appear; deleting the last backup hides both; installing or
::     removing the task updates the task-status indicator.
::
:: Conditional menu entries:
::   Restore [8] and Clean up backups [C] are shown only when at least
::   one default-location backup is present.
::   Update [U] is shown only when a newer version is available.
::   All three entries, when visible, are dynamically assigned their
::   choice positions so the menu always matches the choice set exactly.
::
:: Update status is read from Check-Update.ps1, which caches the remote
:: version string for 24 hours. To force a fresh check, delete
:: %TEMP%\WinRE-Manager-remote-version.txt and re-open the wrapper.
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
:: Behaviour toggles
:: ------------------------------------------------------------------------
:: Controls visibility of the backup-related menu entries - Restore [8]
:: and Clean up backups [C]. Default 1 = show only when a default-location
:: backup is present. Set to 0 to always show both entries, even when no
:: default-location backup exists.
set "HIDE_BACKUP_ACTIONS_WHEN_NONE=1"

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
:: corresponding menu entries are hidden and the wrapper continues to
:: function normally.

goto menu


:: ========================================================================
:: MAIN MENU
:: ========================================================================
:menu
cls
title WinRE Manager - Menu

:: ---- Backup presence ----
set "BACKUP_PRESENT=0"
if exist "%BACKUP_DEFAULT%\" (
    for /d %%D in ("%BACKUP_DEFAULT%\*") do (
        if exist "%%~fD\winre.wim" if exist "%%~fD\backup.json" set "BACKUP_PRESENT=1"
    )
)

:: ---- Scheduled-task status ----
set "TASK_STATUS=%GRAY%Not installed%RESET%"
schtasks.exe /Query /TN "%TASK_NAME%" >nul 2>&1
if not errorlevel 1 set "TASK_STATUS=%GREEN%Installed%RESET%"

:: ---- Update status (session-cached) ----
if not defined UPDATE_STATUS_SET call :check_update_status

:: ---- Determine which conditional options are visible ----
:: Restore [8] and Clean up backups [C] share one condition: at least one
:: default-location backup exists. The toggle overrides it to always-show.
set "SHOW_BACKUP_ACTIONS=0"
if "%BACKUP_PRESENT%"=="1" set "SHOW_BACKUP_ACTIONS=1"
if "%HIDE_BACKUP_ACTIONS_WHEN_NONE%"=="0" set "SHOW_BACKUP_ACTIONS=1"

set "SHOW_UPDATE=0"
if /I "%UPD_KIND%"=="UPDATE" set "SHOW_UPDATE=1"

:: ---- Build the choice set dynamically ----
:: MENU_CHARS is the string choice.exe matches against; each character is
:: one acceptable keypress. The corresponding errorlevel is the character's
:: 1-based position in the string. We track positions as we build.
set "MENU_CHARS=1234567"
set "NEXT_EL=8"
set "RESTORE_EL=0"
set "CLEANUP_EL=0"
set "UPDATE_EL=0"

if "%SHOW_BACKUP_ACTIONS%"=="1" set "MENU_CHARS=%MENU_CHARS%8"
if "%SHOW_BACKUP_ACTIONS%"=="1" set "RESTORE_EL=%NEXT_EL%"
if "%SHOW_BACKUP_ACTIONS%"=="1" set /a NEXT_EL+=1

if "%SHOW_BACKUP_ACTIONS%"=="1" set "MENU_CHARS=%MENU_CHARS%C"
if "%SHOW_BACKUP_ACTIONS%"=="1" set "CLEANUP_EL=%NEXT_EL%"
if "%SHOW_BACKUP_ACTIONS%"=="1" set /a NEXT_EL+=1

if "%SHOW_UPDATE%"=="1" set "MENU_CHARS=%MENU_CHARS%U"
if "%SHOW_UPDATE%"=="1" set "UPDATE_EL=%NEXT_EL%"
if "%SHOW_UPDATE%"=="1" set /a NEXT_EL+=1

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
if "%SHOW_BACKUP_ACTIONS%"=="1" echo   %GREEN%%BOLD%[C]%RESET%  %WHITE%Clean up old backups%RESET%                 %GRAY%delete saved WinRE images%RESET%
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

if "%SHOW_BACKUP_ACTIONS%"=="1" (
    echo  %CYAN%%BOLD%RECOVERY%RESET% %GRAY%restore a saved WinRE image%RESET%
    echo   %CYANBG%%BLACK% RESTORE %RESET% [8] %WHITE%Restore WinRE from backup%RESET%  %GREEN%default backup available%RESET%
    echo.
)

if "%SHOW_UPDATE%"=="1" (
    echo  %YELLOW%%BOLD%UPDATE AVAILABLE%RESET% %GRAY%a newer version of WinRE Manager is available%RESET%
    echo   %YELLOWBG%%BLACK% GET %RESET% %YELLOW%%BOLD%[U]%RESET% %WHITE%Open releases page%RESET%        %GRAY%download the latest version%RESET%
    echo.
)

echo  %MAGENTA%%BOLD%[Q]%RESET%  %WHITE%Quit%RESET%                                      %GRAY%Backup default: %BACKUP_DEFAULT%%RESET%
if "%SHOW_BACKUP_ACTIONS%"=="1" echo %DIM%%GRAY%  Restore accepts any directory containing winre.wim and backup.json.%RESET%
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
if not "%RESTORE_EL%"=="0" if "%SEL%"=="%RESTORE_EL%" goto run_restore
if not "%CLEANUP_EL%"=="0" if "%SEL%"=="%CLEANUP_EL%" goto cleanup_backups
if not "%UPDATE_EL%"=="0" if "%SEL%"=="%UPDATE_EL%" goto open_releases
goto menu


:: ========================================================================
:: BACKUP
:: ========================================================================
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
echo %BOLD%Press Enter to use the default, or type another destination path.%RESET%
echo.

set "BACKUP_DEST="
set /p "BACKUP_DEST=  Destination: "
if "%BACKUP_DEST%"=="" set "BACKUP_DEST=%BACKUP_DEFAULT%"

echo.
echo %CYAN%Selected destination:%RESET% %WHITE%%BACKUP_DEST%%RESET%
echo.
echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to begin.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "BACKUP_DEST_ESC=%BACKUP_DEST:'=''%"
set "TARGET_COMMAND=& '%PROD_SCRIPT_ESC%' -Action Backup -BackupPath '%BACKUP_DEST_ESC%'"
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
echo %WHITE%Lists every valid backup under the default location, shows per-backup%RESET%
echo %WHITE%size and the total, and lets you delete one, several, or all of them.%RESET%
echo.
echo %GRAY%Default location:%RESET% %WHITE%%BACKUP_DEFAULT%%RESET%
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

echo %YELLOWBG%%BLACK% UAC %RESET% %WHITE%Approve the Windows UAC prompt to continue.%RESET%
echo %GRAY%Press any key to continue, or press Ctrl+C to abort.%RESET%
echo.
pause

set "TARGET_COMMAND=& '%CLEANUP_SCRIPT_ESC%'"
call :launch_elevated_command
goto menu


:: ========================================================================
:: RESTORE
:: ========================================================================
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

:: Newest valid backup under the default location. Names are
:: yyyy-MM-dd_HHmmss, which sort lexicographically equal to chronologically.
set "LATEST_BACKUP="
for /f "delims=" %%D in ('dir /b /ad /o-n "%BACKUP_DEFAULT%" 2^>nul') do (
    if not defined LATEST_BACKUP if exist "%BACKUP_DEFAULT%\%%D\winre.wim" if exist "%BACKUP_DEFAULT%\%%D\backup.json" set "LATEST_BACKUP=%BACKUP_DEFAULT%\%%D"
)

if defined LATEST_BACKUP (
    echo %BOLD%Enter a backup directory, or press Enter for the newest.%RESET%
    echo %GRAY%Newest backup:%RESET% %WHITE%%LATEST_BACKUP%%RESET%
) else (
    echo %BOLD%Enter the full path to a backup directory.%RESET%
    echo %YELLOW%No backup found under %BACKUP_DEFAULT%.%RESET%
)
echo.

set "RESTORE_SRC="
set /p "RESTORE_SRC=  Backup directory: "
if "%RESTORE_SRC%"=="" if defined LATEST_BACKUP set "RESTORE_SRC=%LATEST_BACKUP%"
if "%RESTORE_SRC%"=="" (
    echo.
    echo %RED%%BOLD%No backup directory specified.%RESET%
    echo.
    pause
    goto menu
)

if not exist "%RESTORE_SRC%\winre.wim" (
    echo.
    echo %RED%%BOLD%Backup WIM not found.%RESET%
    echo   %WHITE%%RESTORE_SRC%\winre.wim%RESET%
    echo.
    echo %YELLOW%Nothing was launched. Check the backup directory and try again.%RESET%
    echo.
    pause
    goto menu
)

if not exist "%RESTORE_SRC%\backup.json" (
    echo.
    echo %RED%%BOLD%Backup metadata not found.%RESET%
    echo   %WHITE%%RESTORE_SRC%\backup.json%RESET%
    echo.
    echo %YELLOW%Nothing was launched. Check the backup directory and try again.%RESET%
    echo.
    pause
    goto menu
)

echo.
echo %YELLOW%%BOLD%RESTORE CONFIRMATION%RESET%
echo %WHITE%The current registered WinRE WIM will be replaced only after the%RESET%
echo %WHITE%PowerShell validation succeeds.%RESET%
echo.
echo %CYAN%Selected source:%RESET% %WHITE%%RESTORE_SRC%%RESET%
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

set "RESTORE_SRC_ESC=%RESTORE_SRC:'=''%"
set "TARGET_COMMAND=& '%PROD_SCRIPT_ESC%' -Action Restore -BackupPath '%RESTORE_SRC_ESC%'"
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

set "TARGET_COMMAND=& '%PROD_SCRIPT_ESC%'"
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
echo %GRAY%The installed copy is SHA256-verified before the task is registered.%RESET%
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
:: Reads the cached update status from Check-Update.ps1 (or fetches if the
:: cache is stale) and maps it to a coloured display string. Result is
:: stored in UPDATE_STATUS for the menu; UPD_KIND carries the raw kind
:: ("UPDATE" / "CURRENT" / "AHEAD" / "ERROR") for the caller to decide
:: whether to show the [U] entry.
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
:: raw PowerShell text; it is Base64-encoded before being handed to
:: Start-Process, so no shell quoting is ever performed on paths or
:: arguments.
::
:: -Wait makes the launcher block until the elevated process (and any
:: children it spawns) exits. The wrapper then returns to the menu, which
:: recomputes BACKUP_PRESENT, TASK_STATUS, and the conditional entries
:: against the current disk state. A completed backup therefore makes
:: Restore [8] and Clean up backups [C] appear; deleting the last backup
:: hides both; installing or removing the task updates the task-status
:: indicator.
:launch_elevated_command

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$b64=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$env:TARGET_COMMAND)); if(-not $b64){exit 1}; try { Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $b64) -Verb RunAs -Wait -ErrorAction Stop; exit 0 } catch { exit 1 }"

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
:set_task_install_command
set "TARGET_COMMAND=$ErrorActionPreference='Stop'; $src='%PROD_SCRIPT_ESC%'; $dst='%INSTALLED_SCRIPT_ESC%'; $dstDir=Split-Path -Path $dst -Parent; if(-not (Test-Path -LiteralPath $src -PathType Leaf)){ throw ('Production script not found: '+$src) }; if(-not (Test-Path -LiteralPath $dstDir)){ New-Item -Path $dstDir -ItemType Directory -Force | Out-Null }; Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; $srcHash=(Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash; $dstHash=(Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash; if($srcHash -ne $dstHash){ throw ('Install copy hash mismatch. Source='+$srcHash+' Copy='+$dstHash) }; $name='%TASK_NAME_ESC%'; $q=[char]34; $argLine='-NoProfile -ExecutionPolicy Bypass -File '+$q+$dst+$q; $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine -WorkingDirectory $dstDir; $bootTrigger=New-ScheduledTaskTrigger -AtStartup; $bootTrigger.Delay='PT5M'; $monthlyTrigger=New-ScheduledTaskTrigger -Daily -At '03:00' -DaysInterval 30; $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest; $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 24); $settings.RunOnlyIfIdle=$false; $settings.RunOnlyIfNetworkAvailable=$false; $settings.IdleSettings.StopOnIdleEnd=$false; $settings.IdleSettings.RestartOnIdle=$false; Register-ScheduledTask -TaskName $name -Action $action -Trigger @($bootTrigger,$monthlyTrigger) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null; Write-Host ''; Write-Host 'Automatic WinRE maintenance installed.' -ForegroundColor Green; Write-Host ''; Write-Host ('Task:   '+$name) -ForegroundColor White; Write-Host ('Run as: NT AUTHORITY\SYSTEM') -ForegroundColor White; Write-Host ('Script: '+$dst) -ForegroundColor White; Write-Host ('SHA256: '+$dstHash) -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Schedule:' -ForegroundColor White; Write-Host '  Startup (+5 minutes)' -ForegroundColor DarkGray; Write-Host '  Every 30 days at 03:00' -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Conditions:' -ForegroundColor White; Write-Host '  Start when available' -ForegroundColor DarkGray; Write-Host '  No idle requirement' -ForegroundColor DarkGray; Write-Host '  Battery operation allowed' -ForegroundColor DarkGray; Write-Host '  Execution time limit: 24 hours' -ForegroundColor DarkGray; Write-Host '  Network not required' -ForegroundColor DarkGray; Write-Host ''; Write-Host 'Press any key to close this window...'; [void][System.Console]::ReadKey($true)"
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
