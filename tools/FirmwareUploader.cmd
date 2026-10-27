@echo off
rem ===========================================================================
rem  Prof_KIP_v5 firmware uploader - launcher with a VISIBLE console.
rem
rem  Same window as FirmwareUploader.bat, but this console stays open while the
rem  uploader runs and keeps PowerShell error messages on screen. Use it when
rem  the usual launcher (FirmwareUploader.bat / .vbs) opens nothing: the reason
rem  will be printed here.
rem
rem  ASCII only on purpose: the file must work in any console code page.
rem ===========================================================================
setlocal EnableExtensions

set "SCRIPT=%~dp0FirmwareUploader.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%SCRIPT%" (
  echo.
  echo FirmwareUploader.ps1 was not found next to this file:
  echo   %~dp0
  echo.
  echo Keep FirmwareUploader.cmd together with FirmwareUploader.ps1,
  echo upload-ui.ps1 and upload-core.ps1 in one folder ^(tools^).
  echo.
  pause
  exit /b 1
)

echo Starting the uploader window. PowerShell messages, if any, appear below.
echo Close the uploader window to return to this console.
echo.

"%PS%" -NoProfile -Sta -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Exit code: %RC%
  echo See also: %TEMP%\Prof_KIP_v5-uploader-error.log
  echo.
  pause
)
exit /b %RC%
