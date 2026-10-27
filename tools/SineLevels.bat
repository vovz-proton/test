@echo off
rem ===========================================================================
rem  Prof_KIP_v5 DAC sine levels - launch the window.
rem
rem  Double-click this file: the window opens, this console closes.
rem  It starts Windows PowerShell hidden, so only the slider window is visible.
rem  Keep SineLevels.ps1, sine-levels-ui.ps1 and sine-levels-core.ps1 in the
rem  same folder.
rem
rem  ASCII only on purpose: the file must work in any console code page.
rem  For a launch without any console flash use SineLevels.vbs.
rem ===========================================================================
setlocal EnableExtensions

set "SCRIPT=%~dp0SineLevels.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SCRIPT%" goto missing
if not exist "%PS%" set "PS=powershell.exe"

start "" "%PS%" -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" %*
if errorlevel 1 goto failed
exit /b 0

:missing
echo.
echo SineLevels.ps1 was not found next to this file:
echo   %~dp0
echo.
echo Keep SineLevels.bat together with SineLevels.ps1,
echo sine-levels-ui.ps1 and sine-levels-core.ps1 in one folder (tools).
echo.
pause
exit /b 1

:failed
echo.
echo Could not start PowerShell:
echo   %PS%
echo.
echo Check that Windows PowerShell is installed and allowed by policy.
echo.
pause
exit /b 1
