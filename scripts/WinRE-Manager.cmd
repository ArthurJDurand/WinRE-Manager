@echo off
setlocal EnableExtensions DisableDelayedExpansion

title WinRE Manager - Menu

:: ================================================================
:: WinRE Manager - interactive entry point
:: ================================================================
:: This launcher is intentionally NOT elevated.
::
:: The menu opens immediately in the current (unelevated) console.
:: When you pick an action, the wrapper shows a warning screen and
:: then launches ONLY the selected PowerShell script, elevated, via
:: PowerShell's Start-Process -Verb RunAs.
::
:: The .cmd itself is NEVER relaunched elevated. There is therefore
:: exactly one menu window, always unelevated, always the one you
:: started. When an elevated action finishes, its elevated console
:: closes and you are returned to this menu.
::
:: No VBScript. No Windows Script Host. No temporary files.
::
:: The PowerShell scripts retain their own elevation guard as a
:: final safety net for direct invocation.
:: ================================================================

:: ----------------------------------------------------------------
:: ANSI colour support
:: ESC is obtained from CMD's prompt mechanism without modifying
:: the user's persistent console settings.
:: ----------------------------------------------------------------
for /F "delims=" %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"

set "RESET=%ESC%[0m"
set "BOLD=%ESC%[1m"
set "DIM=%ESC%[2m"

set "WHITE=%ESC%[97m"
set "GRAY=%ESC%[90m"
set "RED=%ESC%[91m"
set "GREEN=%ESC%[92m"
set "YELLOW=%ESC%[93m"
set "BLUE=%ESC%[94m"
set "MAGENTA=%ESC%[95m"
set "CYAN=%ESC%[96m"

:: ----------------------------------------------------------------
:: Paths
:: ----------------------------------------------------------------
set "SCRIPTS_DIR=%~dp0"
set "PROD_SCRIPT=%SCRIPTS_DIR%WinRE.ps1"
set "TEST_SCRIPT=%SCRIPTS_DIR%Test-WinRE.ps1"
set "LOGFILE=C:\ProgramData\OEM\Logs\WinRE-Manager.log"

:: ----------------------------------------------------------------
:: Preflight
:: ----------------------------------------------------------------
if not exist "%PROD_SCRIPT%" (
    call :error_screen "Production script not found:" "%PROD_SCRIPT%"
    exit /b 1
)
if not exist "%TEST_SCRIPT%" (
    call :error_screen "Test harness not found:" "%TEST_SCRIPT%"
    exit /b 1
)

:: ----------------------------------------------------------------
:: Main menu
:: ----------------------------------------------------------------
:menu
title WinRE Manager - Menu
cls

echo.
echo %CYAN%%BOLD%================================================================%RESET%
echo %CYAN%%BOLD%                        WinRE Manager%RESET%
echo %CYAN%%BOLD%================================================================%RESET%
echo %DIM%%GRAY%              launcher is not elevated%RESET%
echo.
echo %GREEN%  [1]%RESET% %WHITE%Test harness%RESET%      %GRAY%- read-only diagnostics and self-tests%RESET%
echo %YELLOW%  [2]%RESET% %WHITE%Preview (DryRun)%RESET%  %GRAY%- calculates the plan; makes no changes%RESET%
echo %RED%  [3]%RESET% %WHITE%Run for real%RESET%       %GRAY%- modifies partitions and WinRE%RESET%
echo %MAGENTA%  [4]%RESET% %WHITE%Show recent log%RESET%   %GRAY%- view or open the latest log%RESET%
echo %WHITE%  [5]%RESET% %WHITE%Quit%RESET%
echo.
echo %CYAN%%BOLD%================================================================%RESET%
echo.

choice /C 12345 /N /M "  Select an option [1-5]: "
set "SEL=%errorlevel%"

if "%SEL%"=="1" goto run_test
if "%SEL%"=="2" goto run_dry
if "%SEL%"=="3" goto run_live_warning
if "%SEL%"=="4" goto show_log
if "%SEL%"=="5" goto quit
goto menu


:: =================================================================
:: TEST HARNESS
:: =================================================================
:run_test
cls
title WinRE Manager - Test Harness

echo.
echo %GREEN%%BOLD%================================================================%RESET%
echo %GREEN%%BOLD%                    TEST HARNESS - READ ONLY%RESET%
echo %GREEN%%BOLD%================================================================%RESET%
echo.
echo %WHITE%The WinRE test harness will be launched with%RESET%
echo %WHITE%Administrator privileges so that BitLocker, partition and%RESET%
echo %WHITE%DISM queries return complete data.%RESET%
echo.
echo %GREEN%No changes will be made to partitions, WinRE, BitLocker, or state.%RESET%
echo.
echo %RED%%BOLD%----------------------------------------------------------------%RESET%
echo %RED%%BOLD%   A Windows UAC prompt will appear. Approve it to continue.%RESET%
echo %RED%%BOLD%----------------------------------------------------------------%RESET%
echo %GRAY%Test-WinRE.ps1 will run in a new elevated PowerShell window.%RESET%
echo %GRAY%This menu stays open behind it.%RESET%
echo.
echo %BOLD%Press any key to continue to the UAC prompt...%RESET%
pause >nul

set "TARGET_SCRIPT=%TEST_SCRIPT%"
set "TARGET_ARGS="
call :launch_elevated
goto menu


:: =================================================================
:: DRY RUN
:: =================================================================
:run_dry
cls
title WinRE Manager - DryRun Preview

echo.
echo %YELLOW%%BOLD%================================================================%RESET%
echo %YELLOW%%BOLD%                     PREVIEW - DRY RUN%RESET%
echo %YELLOW%%BOLD%================================================================%RESET%
echo.
echo %WHITE%WinRE.ps1 will be launched with Administrator privileges in%RESET%
echo %WHITE%%BOLD%DryRun%RESET%%WHITE% mode.%RESET%
echo.
echo %GREEN%The preview performs discovery, validation, sizing and planning.%RESET%
echo %GREEN%It will NOT shrink, delete, create, format, deploy, or re-register.%RESET%
echo.
echo %RED%%BOLD%----------------------------------------------------------------%RESET%
echo %RED%%BOLD%   A Windows UAC prompt will appear. Approve it to continue.%RESET%
echo %RED%%BOLD%----------------------------------------------------------------%RESET%
echo %GRAY%WinRE.ps1 -DryRun will run in a new elevated PowerShell window.%RESET%
echo %GRAY%This menu stays open behind it.%RESET%
echo.
echo %BOLD%Press any key to continue to the UAC prompt...%RESET%
pause >nul

set "TARGET_SCRIPT=%PROD_SCRIPT%"
set "TARGET_ARGS=-DryRun"
call :launch_elevated
goto menu


:: =================================================================
:: LIVE RUN - DESTRUCTIVE
:: =================================================================
:run_live_warning
cls
title WinRE Manager - LIVE RUN WARNING

echo.
echo %RED%%BOLD%!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!%RESET%
echo %RED%%BOLD%!                    WARNING - LIVE RUN                    !%RESET%
echo %RED%%BOLD%!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!%RESET%
echo.
echo %WHITE%%BOLD%This operation can modify the machine's disk layout and WinRE.%RESET%
echo.
echo If the manager's safety checks permit the operation, it may:
echo.
echo   %RED%*%RESET% Shrink C: or an intervening data partition
echo   %RED%*%RESET% Delete the current recovery partition
echo   %RED%*%RESET% Create and format a replacement recovery partition
echo   %RED%*%RESET% Mount and service a WinRE WIM
echo   %RED%*%RESET% Strip and inject drivers
echo   %RED%*%RESET% Deploy a new WinRE image
echo   %RED%*%RESET% Re-register and enable WinRE
echo.
echo %YELLOW%%BOLD%The script fails closed when its safety checks fail, but this%RESET%
echo %YELLOW%%BOLD%is still a real disk and recovery-environment operation.%RESET%
echo.
echo %CYAN%%BOLD%Before continuing:%RESET%
echo.
echo   %WHITE%*%RESET% Save your work.
echo   %WHITE%*%RESET% Close disk-management, backup and defragmentation tools.
echo   %WHITE%*%RESET% Do not interrupt the machine during partition changes.
echo   %WHITE%*%RESET% Ensure stable power.
echo.
echo %RED%%BOLD%There is no "undo" button for a disk-layout operation.%RESET%
echo.
echo %BOLD%To continue, type RUN exactly.%RESET%
echo %GRAY%Anything else cancels.%RESET%
echo.

set "CONFIRM="
set /p "CONFIRM=  Confirmation: "

if /I not "%CONFIRM%"=="RUN" (
    echo.
    echo %GREEN%Cancelled. No changes were made.%RESET%
    echo.
    timeout /t 2 /nobreak >nul
    goto menu
)

echo.
echo %GREEN%%BOLD%Confirmation accepted.%RESET%
echo.
echo %RED%%BOLD%----------------------------------------------------------------%RESET%
echo %RED%%BOLD%   A Windows UAC prompt will appear now. Approve it to start.%RESET%
echo %RED%%BOLD%----------------------------------------------------------------%RESET%
echo %GRAY%WinRE.ps1 will run in a new elevated PowerShell window.%RESET%
echo %GRAY%This menu stays open behind it.%RESET%
echo.
timeout /t 3 /nobreak >nul

set "TARGET_SCRIPT=%PROD_SCRIPT%"
set "TARGET_ARGS="
call :launch_elevated
goto menu


:: =================================================================
:: LOG VIEWER
:: =================================================================
:show_log
cls
title WinRE Manager - Log Viewer

echo.
echo %MAGENTA%%BOLD%================================================================%RESET%
echo %MAGENTA%%BOLD%                         RECENT LOG%RESET%
echo %MAGENTA%%BOLD%================================================================%RESET%
echo.

if not exist "%LOGFILE%" (
    echo %YELLOW%No log file was found at:%RESET%
    echo.
    echo   %WHITE%%LOGFILE%%RESET%
    echo.
    pause
    goto menu
)

echo %GRAY%Showing the last 40 entries:%RESET%
echo.
powershell.exe -NoProfile -Command "Get-Content -LiteralPath '%LOGFILE%' -Tail 40"

echo.
echo %MAGENTA%%BOLD%================================================================%RESET%
echo %WHITE%Full log:%RESET%
echo   %CYAN%%LOGFILE%%RESET%
echo.
echo %CYAN%%BOLD%  [O]%RESET% %WHITE%Open the full log in Notepad%RESET%
echo %CYAN%%BOLD%  [Q]%RESET% %WHITE%Return to the menu%RESET%
echo.

choice /C OQ /N /M "  Selection [O/Q]: "

if errorlevel 2 goto menu
if errorlevel 1 start "" notepad.exe "%LOGFILE%"
goto menu


:: =================================================================
:: ELEVATED POWERSHELL LAUNCHER
:: =================================================================
:: Launches ONLY the selected PowerShell script, elevated.
::
:: The .cmd is NOT relaunched. There is no second menu window.
::
:: Mechanism: powershell.exe -Command with Start-Process -Verb RunAs.
:: No VBScript, no Windows Script Host, no temp files.
::
:: Inputs (set by caller):
::   TARGET_SCRIPT  - full path to the .ps1 to run elevated
::   TARGET_ARGS    - optional argument string (may be empty)
::
:: Returns:
::   0 = elevation accepted, elevated process launched
::   1 = UAC cancelled or launch failed
:: =================================================================
:launch_elevated

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $a='-NoProfile -ExecutionPolicy Bypass -File '+$q+$env:TARGET_SCRIPT+$q; if($env:TARGET_ARGS){$a+=' '+$env:TARGET_ARGS}; try { Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"

set "LAUNCH_RESULT=%errorlevel%"

if not "%LAUNCH_RESULT%"=="0" (
    echo.
    echo %YELLOW%%BOLD%UAC was cancelled or the elevated process could not be started.%RESET%
    echo %GRAY%No changes were made by this launcher.%RESET%
    echo.
    timeout /t 2 /nobreak >nul
)
exit /b %LAUNCH_RESULT%


:: =================================================================
:: ERROR SCREEN
:: =================================================================
:error_screen

cls
title WinRE Manager - Error

echo.
echo %RED%%BOLD%!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!%RESET%
echo %RED%%BOLD%!                         ERROR                              !%RESET%
echo %RED%%BOLD%!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!%RESET%
echo.
echo %RED%%BOLD%%~1%RESET%
echo.
echo   %WHITE%%~2%RESET%
echo.
echo %YELLOW%The launcher cannot continue until the required file is restored.%RESET%
echo.
pause
exit /b 0


:: =================================================================
:: QUIT
:: =================================================================
:quit
cls
title WinRE Manager
echo.
echo %CYAN%%BOLD%WinRE Manager closed.%RESET%
echo.
endlocal
exit /b 0
