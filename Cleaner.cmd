@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem ===========================================================================
rem  Cleaner launcher - double-click to start Cleaner.
rem
rem    Cleaner.cmd          start normally
rem    Cleaner.cmd /admin   start with administrator rights (Windows asks first)
rem
rem  Cleaner.ps1 and CleanerEngine.psm1 must be in the same folder as this file.
rem ===========================================================================

set "CLEANER_DIR=%~dp0"
set "CLEANER_PS1=%~dp0Cleaner.ps1"
set "CLEANER_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "CLEANER_VERB=open"
if /i "%~1"=="/admin" set "CLEANER_VERB=runas"
if /i "%~1"=="-admin" set "CLEANER_VERB=runas"

if not exist "%CLEANER_PS1%" goto :missing_files
if not exist "%CLEANER_DIR%CleanerEngine.psm1" goto :missing_files
if not exist "%CLEANER_PS%" goto :missing_powershell

rem Start Cleaner in its own hidden console, so no PowerShell window stays open.
"%CLEANER_PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$q = [char]34; $arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $q + $env:CLEANER_PS1 + $q; try { Start-Process -FilePath $env:CLEANER_PS -ArgumentList $arguments -WindowStyle Hidden -Verb $env:CLEANER_VERB -ErrorAction Stop; exit 0 } catch { exit 1 }"
if errorlevel 1 goto :start_failed
exit /b 0

:missing_files
echo.
echo   Cleaner could not start: Cleaner.ps1 and CleanerEngine.psm1 must be
echo   in the same folder as this file:
echo   "%CLEANER_DIR%"
echo.
pause
exit /b 1

:missing_powershell
echo.
echo   Cleaner could not start: Windows PowerShell was not found here:
echo   "%CLEANER_PS%"
echo.
pause
exit /b 1

:start_failed
echo.
echo   Cleaner did not start. If Windows asked for administrator rights
echo   and you chose No, simply run Cleaner.cmd again.
echo.
timeout /t 6 >nul
exit /b 1
