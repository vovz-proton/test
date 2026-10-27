# =============================================================================
#  upload-com.ps1 - обновление ПО прибора по COM-порту из командной строки.
#
#  Использует то же ядро, что и окно прошивальщика (tools/upload-core.ps1),
#  поэтому протокол, проверки файла и тайм-ауты совпадают с графической версией.
#  Для работы с окном см. tools/FirmwareUploader.vbs.
#
#  Порядок:
#    1. BT  - прибор входит в режим загрузки (синус стоп, область загрузки стёрта);
#    2. файл .hex передаётся построчно, прибор пишет его во временную область;
#    3. GO  - прибор считает контрольную сумму, ставит маркер, перезапускается;
#    4. встроенный копировщик переносит новое ПО на место приложения;
#    5. скрипт ждёт возвращения порта и телеметрии - это и есть проверка успеха.
#
#  Примеры:
#    ./tools/upload-com.ps1
#    ./tools/upload-com.ps1 -File build/mechanics/Prof_KIP_v5.hex
#    ./tools/upload-com.ps1 -File build/Prof_KIP_v5.bin
# =============================================================================
param(
  [string]$File = 'build/Prof_KIP_v5.hex',
  [int]$SendTimeoutSec = 240,
  [int]$VerifySec = 45,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-UploadFailure {
  param([string]$Message)
  Write-Host ''
  Write-Host ('ОШИБКА: ' + $Message) -ForegroundColor Red
  exit 1
}

$root = Split-Path $PSScriptRoot -Parent
if (-not [System.IO.Path]::IsPathRooted($File)) { $File = Join-Path $root $File }
if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
  Write-UploadFailure ('Файл прошивки не найден: ' + $File)
}

. (Join-Path $PSScriptRoot 'upload-core.ps1')

$plan = Get-UploadFirmwarePlan -Path $File
if (-not $plan.IsValid) {
  Write-UploadFailure ('Файл прошивки не подходит: ' + ($plan.Errors -join ' '))
}

Write-Host ('Файл  : {0} ({1}, {2} записей, {3} байт данных)' -f $plan.FileName, $plan.Kind.ToUpperInvariant(), $plan.DataRecords, $plan.PayloadBytes)

$found = Find-UploadInstrumentPort
if (-not $found) {
  $ports = @(Get-UploadComPorts)
  $hint = 'Последовательных портов нет.'
  if ($ports.Count -gt 0) { $hint = 'Доступные порты: ' + ($ports -join ', ') + '.' }
  Write-UploadFailure ('COM-порт прибора не найден (VID_0483:PID_5740). Подключите USB платы. ' + $hint)
}
Write-Host ('Порт  : {0} ({1})' -f $found.Port, $found.Name)

$script:lastStage = ''
$script:lastBucket = -1
$result = Invoke-FirmwareUpload -Plan $plan -PortName $found.Port `
  -Options @{ SendTimeoutSec = $SendTimeoutSec; VerifyTimeoutSec = $VerifySec } `
  -OnProgress {
    param($percent, $stage, $detail)
    $bucket = [math]::Floor($percent / 10)
    if ($stage -ne $script:lastStage -or $bucket -ne $script:lastBucket) {
      $script:lastStage = $stage
      $script:lastBucket = $bucket
      Write-Host ('  [{0,3}%] {1} - {2}' -f $percent, $stage, $detail)
    }
  } `
  -OnLog {
    param($text)
    if (-not $Quiet) { Write-Host ('         ' + $text) }
  }

if ($result.Success) {
  Write-Host ''
  Write-Host ('ГОТОВО за {0:N1} с: {1}' -f ($result.DurationMs / 1000.0), $result.Message) -ForegroundColor Green
  if ($result.Telemetry) { Write-Host ('  телеметрия: ' + $result.Telemetry) }
  exit 0
}

Write-UploadFailure (('Заливка не удалась: ' + $result.Message) + '')
