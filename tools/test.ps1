param([string]$VcVars = 'C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root 'build/host-tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
  $sources=@('tests/test_firmware.c','Core/Src/ascii_output.c','Core/Src/hex_line.c','Core/Src/instrument_logic.c','Core/Src/motor.c','Core/Src/led_color.c','Core/Src/serial_protocol.c','Core/Src/instrument_app.c')
  $quoted=$sources | ForEach-Object { '"'+(Join-Path $root $_)+'"' }
  $line='cl /nologo /W4 /WX /std:c11 /D_CRT_SECURE_NO_WARNINGS /DBENCH_NO_MECHANICS=0 /I"'+$root+'/tests/mocks" /I"'+$root+'/Core/Inc" '+($quoted -join ' ')+' /Fe:firmware-tests.exe'
  $setup='call "'+$VcVars+'" >nul'
  @('@echo off',$setup,'if errorlevel 1 exit /b 1',$line,'exit /b %errorlevel%') | Set-Content -LiteralPath './compile.cmd' -Encoding ascii
  & cmd.exe /d /c 'compile.cmd'
  if($LASTEXITCODE -ne 0) { throw 'Host test compilation failed' }
  & './firmware-tests.exe'
  if($LASTEXITCODE -ne 0) { throw 'Host tests failed' }
  & node (Join-Path $root 'tests/test_waveform.js')
  if($LASTEXITCODE -ne 0) { throw 'Waveform model tests failed' }
  # Прошивальщик: ядро обмена и окно проверяются на подставном приборе, без железа.
  & powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $root 'tests/test_upload_core.ps1')
  if($LASTEXITCODE -ne 0) { throw 'Firmware uploader core tests failed' }
  & powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $root 'tests/test_upload_ui.ps1')
  if($LASTEXITCODE -ne 0) { throw 'Firmware uploader window tests failed' }
  # Окно уровней ЦАП: команды, разбор строк, модель синусоид и само окно.
  & powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $root 'tests/test_sine_levels_core.ps1')
  if($LASTEXITCODE -ne 0) { throw 'DAC level core tests failed' }
  & powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File (Join-Path $root 'tests/test_sine_levels_ui.ps1')
  if($LASTEXITCODE -ne 0) { throw 'DAC level window tests failed' }
} finally { Pop-Location }