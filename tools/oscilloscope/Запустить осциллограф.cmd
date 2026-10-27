@echo off
setlocal
set "PYTHONW=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\pythonw.exe"
if not exist "%PYTHONW%" (
  echo Не найден Python GUI runtime:
  echo %PYTHONW%
  echo Установите Python 3.12 x64 с Tkinter или поправьте путь в этом файле.
  pause
  exit /b 1
)
start "" "%PYTHONW%" "%~dp0scope_viewer.py"
endlocal
