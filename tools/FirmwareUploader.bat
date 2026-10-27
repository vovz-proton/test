@echo off
rem ===========================================================================
rem  Prof_KIP_v5 firmware uploader - launch the window.
rem
rem  Double-click this file: the uploader window opens, this console closes.
rem  Drop a .hex / .bin file onto this file: it opens with that file selected.
rem
rem  It starts Windows PowerShell (powershell.exe) hidden, so only the
rem  uploader window is visible. The uploader itself is FirmwareUploader.ps1;
rem  keep it, upload-ui.ps1 and upload-core.ps1 in the same folder.
rem
rem  ASCII only on purpose: the file must work in any console code page.
rem  For a run with a visible console (error text stays on screen) use
rem  FirmwareUploader.cmd; for a launch without any console flash, use
rem  FirmwareUploader.vbs.
rem ===========================================================================
setlocal EnableExtensions

set "SCRIPT=%~dp0FirmwareUploader.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SCRIPT%" goto missing
if not exist "%PS%" set "PS=powershell.exe"

start "" "%PS%" -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" %*
if errorlevel 1 goto failed
exit /b 0

:missing
echo.
echo FirmwareUploader.ps1 was not found next to this file:
echo   %~dp0
echo.
echo Keep FirmwareUploader.bat together with FirmwareUploader.ps1,
echo upload-ui.ps1 and upload-core.ps1 in one folder (tools).
echo.
echo Tip: for the Desktop, create a SHORTCUT to this file instead of
echo copying it - the uploader needs the .ps1 files next to itself.
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
