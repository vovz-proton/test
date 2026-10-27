# =============================================================================
#  tests/test_upload_ui.ps1 - проверка окна прошивальщика без железа.
#
#  Окно создаётся, но не показывается: проверяются обработчики кнопок,
#  тексты статусов, полоса 0..100 %, отмена и блокировка элементов на время
#  работы. Прибор подставной (тот же протокол, что у Core/Src/firmware_update.c).
#
#  Нажатие кнопки вызывается через Start-UploaderJob: PerformClick не срабатывает
#  у невидимого окна, а проводку кнопки проверяет отдельный тест.
#
#  Запуск:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_upload_ui.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $root 'tools/upload-core.ps1')
. (Join-Path $root 'tools/upload-ui.ps1')

$script:passed = 0
$script:failed = 0
$script:failures = New-Object System.Collections.Generic.List[string]

function Test-Case {
  param([string]$Name, [scriptblock]$Body)
  try {
    & $Body
    $script:passed++
    Write-Host ('  [ OK ]  ' + $Name)
  } catch {
    $script:failed++
    $script:failures.Add(('{0}: {1}' -f $Name, $_.Exception.Message))
    Write-Host ('  [FAIL]  ' + $Name + ' -> ' + $_.Exception.Message)
  }
}

function Assert-True {
  param($Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  if ($Expected -ne $Actual) { throw ('{0} (ожидалось "{1}", получено "{2}")' -f $Message, $Expected, $Actual) }
}

function Assert-Match {
  param([string]$Pattern, [string]$Text, [string]$Message)
  if ($Text -notmatch $Pattern) { throw ('{0}: "{1}" не содержит /{2}/' -f $Message, $Text, $Pattern) }
}

# -----------------------------------------------------------------------------
#  Подставной прибор
# -----------------------------------------------------------------------------

function New-UiFake {
  param([string]$Mode = 'boot', [int]$CancelAfterWrites = 0)

  $dev = [pscustomobject]@{
    PortName = 'COM99'; Mode = $Mode; CancelAfterWrites = $CancelAfterWrites
    Queue = (New-Object System.Collections.Generic.List[string])
    InUpload = $false; Records = 0; Eof = $false; Writes = 0; Telemetry = 0; Closed = $false
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Emit -Value {
    param([string]$text) $this.Queue.Add($text)
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Handle -Value {
    param([string]$line)
    if ($line.StartsWith(':')) {
      if (-not $this.InUpload) { return }
      $type = [Convert]::ToInt32($line.Substring(7, 2), 16)
      if ($type -eq 1) { $this.Eof = $true; return }
      if ($type -eq 0) {
        $this.Records++
        if (($this.Records % 64) -eq 0) { $this.Emit(('R{0:D6}' -f $this.Records)) }
      }
      return
    }
    if ($line -eq 'ID') { if ($this.InUpload) { $this.Emit('UPD 1.6') }; return }
    if ($line -eq 'BT') {
      if ($this.Mode -eq 'busy') { $this.Emit('ERR=BT,BUSY'); return }
      if ($this.Mode -eq 'running') { return }
      $this.InUpload = $true; $this.Records = 0; $this.Eof = $false
      $this.Emit('ACK=BT'); $this.Emit('UPD READY'); return
    }
    if ($line -eq 'GO') {
      if (-not $this.InUpload) { return }
      if (-not $this.Eof -or $this.Records -eq 0) { $this.Emit('ERR IMAGE'); return }
      $this.InUpload = $false; $this.Emit('DONE'); return
    }
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Write -Value {
    param([string]$text)
    $this.Writes++
    if ($this.CancelAfterWrites -gt 0 -and $this.Writes -ge $this.CancelAfterWrites) {
      if ($script:uiForCancel) { $script:uiForCancel.CancelRequested = $true }
    }
    foreach ($part in [regex]::Split($text, "`r`n|`n|`r")) {
      $line = $part.Trim()
      if ($line.Length -gt 0) { $this.Handle($line) }
    }
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name ReadLines -Value {
    param([int]$Milliseconds)
    $out = New-Object System.Collections.Generic.List[string]
    if ($this.Mode -eq 'running') {
      if ($this.Telemetry -eq 0) { $out.Add('Hello! fw 1.6') }
      $this.Telemetry++
      $out.Add(('Z={0},X=1.999990' -f (-1234 + $this.Telemetry)))
    }
    if ($this.Queue.Count -gt 0) {
      foreach ($item in $this.Queue) { $out.Add($item) }
      $this.Queue.Clear()
    } elseif ($out.Count -eq 0 -and $Milliseconds -gt 0) {
      Start-Sleep -Milliseconds 5
    }
    return ,$out.ToArray()
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Close -Value { $this.Closed = $true }

  return $dev
}

# Порт «найден», чтобы окно выбрало COM99 и работало через подставную связь.
function Find-UploadInstrumentPort {
  return [pscustomobject]@{ Port = 'COM99'; Name = 'Fake STM32 Virtual COM Port (COM99)'; Status = 'OK' }
}

$script:fakeMode = 'boot'
$script:fakeCancelAfter = 0
$script:fakeCalls = 0
$script:uiForCancel = $null

$factory = {
  param($portName)
  $script:fakeCalls++
  if ($script:fakeCalls -eq 1) {
    return (New-UiFake -Mode $script:fakeMode -CancelAfterWrites $script:fakeCancelAfter)
  }
  return (New-UiFake -Mode 'running')
}

function New-TestWindow {
  # Настройки прошлых запусков могут подставить файл: для теста задаём поле явно.
  param([string]$File)
  $script:fakeCalls = 0
  $ui = New-UploaderWindow -DefaultFolder (Join-Path $root 'build') -TransportFactory $factory
  $ui.TxtFile.Text = ''
  if ($File) { $ui.TxtFile.Text = $File }
  [System.Windows.Forms.Application]::DoEvents()
  return $ui
}

function Invoke-UiUpload {
  param($Ui, [string]$File)
  if ($null -ne $File) { $Ui.TxtFile.Text = $File }
  [System.Windows.Forms.Application]::DoEvents()
  Start-UploaderJob -Ui $Ui
  [System.Windows.Forms.Application]::DoEvents()
  return $Ui
}

$script:firmware = Join-Path $root 'build/Prof_KIP_v5.hex'

# =============================================================================
#  Тесты
# =============================================================================

Write-Host ''
Write-Host 'Окно и начальное состояние'

Test-Case 'окно создаётся со всеми элементами' {
  $ui = New-TestWindow -File $null
  Assert-True ($null -ne $ui.Form) 'форма'
  Assert-True ($null -ne $ui.TxtFile) 'поле файла'
  Assert-True ($null -ne $ui.BtnBrowse) 'кнопка обзора'
  Assert-True ($null -ne $ui.CmbPort) 'список портов'
  Assert-True ($null -ne $ui.Progress) 'полоса'
  Assert-True ($null -ne $ui.LblStage) 'этап'
  Assert-True ($null -ne $ui.Log) 'журнал'
  Assert-Equal 'Залить прошивку' $ui.BtnFlash.Text 'подпись кнопки'
  Assert-Equal 0 $ui.Progress.Value 'начальный процент'
  Assert-True (-not $ui.Busy) 'окно свободно'
  Assert-Match 'Prof_KIP_v5' $ui.Form.Text 'заголовок окна'
  $ui.Form.Dispose()
}

Test-Case 'кнопка «Залить» связана с заливкой' {
  $ui = New-TestWindow -File $null
  Assert-True ($ui.BtnFlash.Enabled) 'кнопка активна'
  # WinForms хранит обработчики в EventHandlerList: ищем подписку на EventClick.
  $flags = [System.Reflection.BindingFlags]'NonPublic,Instance'
  $eventsProperty = [System.ComponentModel.Component].GetProperty('Events', $flags)
  $list = $eventsProperty.GetValue($ui.BtnFlash)
  $keyField = [System.Windows.Forms.Control].GetField('EventClick', [System.Reflection.BindingFlags]'NonPublic,Static')
  $handler = $null
  if ($list -and $keyField) { $handler = $list[$keyField.GetValue($null)] }
  Assert-True ($null -ne $handler) 'обработчик Click подключён'
  $ui.Form.Dispose()
}

Test-Case 'порт прибора подставляется автоматически' {
  $ui = New-TestWindow -File $null
  Assert-Equal 'COM99' ([string]$ui.CmbPort.SelectedItem) 'выбранный порт'
  Assert-Match 'подключён' $ui.LblPortInfo.Text 'подпись о приборе'
  $ui.Form.Dispose()
}

Test-Case 'сведения о файле показываются в окне' {
  if (-not (Test-Path -LiteralPath $script:firmware)) { throw 'нет build/Prof_KIP_v5.hex' }
  $ui = New-TestWindow -File $script:firmware
  Assert-Match 'HEX' $ui.LblFileInfo.Text 'тип файла'
  # Разделитель тысяч зависит от локали (в ru-RU это неразрывный пробел).
  # Точные числа зависят от текущей сборки: проверяем формат и правдоподобный
  # объём, иначе тест ломается от любой правки кода.
  Assert-Match '2[0-9]\s\d{3}\s+байт кода' $ui.LblFileInfo.Text 'размер кода'
  Assert-Match '1[0-9]\d{2}\s+записей' $ui.LblFileInfo.Text 'число записей'
  $ui.Form.Dispose()
}

Test-Case 'непригодный файл подсвечивается в окне' {
  $bad = Join-Path $env:TEMP 'ui-bad.hex'
  [System.IO.File]::WriteAllText($bad, ":1000000000400020B1580008614900086349000819`r`n", (New-Object System.Text.UTF8Encoding $false))
  $ui = New-TestWindow -File $bad
  Assert-Match 'не подходит' $ui.LblFileInfo.Text 'подпись о проблеме'
  $ui.Form.Dispose()
}

Write-Host ''
Write-Host 'Нажатие «Залить прошивку»'

Test-Case 'без файла — сообщение и порт не открывается' {
  $ui = New-TestWindow -File $null
  [void](Invoke-UiUpload -Ui $ui -File $null)
  Assert-Match 'не выбран' $ui.LblStage.Text 'статус'
  Assert-Equal 0 $script:fakeCalls 'порт открываться не должен'
  Assert-True (-not $ui.Busy) 'окно осталось свободным'
  $ui.Form.Dispose()
}

Test-Case 'несуществующий файл — сообщение' {
  $ui = New-TestWindow -File $null
  [void](Invoke-UiUpload -Ui $ui -File (Join-Path $env:TEMP 'no-such-ui.hex'))
  Assert-Match 'не найден' $ui.LblStage.Text 'статус'
  Assert-Equal 0 $script:fakeCalls 'порт открываться не должен'
  $ui.Form.Dispose()
}

Test-Case 'файл без конца — отказ до отправки' {
  $bad = Join-Path $env:TEMP 'ui-noeof.hex'
  $lines = @(Get-Content -LiteralPath $script:firmware -Encoding ascii | Select-Object -First 40)
  [System.IO.File]::WriteAllLines($bad, $lines, (New-Object System.Text.UTF8Encoding $false))
  $ui = New-TestWindow -File $null
  [void](Invoke-UiUpload -Ui $ui -File $bad)
  Assert-Match 'не подходит' $ui.LblStage.Text 'статус'
  Assert-Equal 0 $script:fakeCalls 'порт открываться не должен'
  $ui.Form.Dispose()
}

Test-Case 'успешная заливка: 100 %, «Готово», окно разблокировано' {
  $script:fakeMode = 'boot'
  $script:fakeCancelAfter = 0
  $ui = New-TestWindow -File $null
  $script:uiForCancel = $ui
  [void](Invoke-UiUpload -Ui $ui -File $script:firmware)

  Assert-Equal 100 $ui.Progress.Value 'процент'
  Assert-Equal 'Готово' $ui.LblStage.Text 'этап'
  Assert-Match 'телеметрия' $ui.LblDetail.Text 'подробности'
  Assert-Equal 'Залить прошивку' $ui.BtnFlash.Text 'подпись кнопки вернулась'
  Assert-True (-not $ui.Busy) 'окно свободно'
  Assert-True $ui.TxtFile.Enabled 'поле файла доступно'
  Assert-True $ui.CmbPort.Enabled 'список портов доступен'
  Assert-True ($script:fakeCalls -ge 2) 'порт открывался повторно после перезапуска'
  Assert-Match 'DONE' $ui.Log.Text 'журнал содержит DONE'
  $ui.Form.Dispose()
}

Test-Case 'прибор занят: «Ошибка» и понятная причина' {
  $script:fakeMode = 'busy'
  $script:fakeCancelAfter = 0
  $ui = New-TestWindow -File $null
  [void](Invoke-UiUpload -Ui $ui -File $script:firmware)

  Assert-Equal 'Ошибка' $ui.LblStage.Text 'этап'
  Assert-Match 'BUSY' $ui.LblDetail.Text 'причина'
  Assert-True (-not $ui.Busy) 'окно свободно'
  Assert-Equal 'Залить прошивку' $ui.BtnFlash.Text 'подпись кнопки вернулась'
  $ui.Form.Dispose()
  $script:fakeMode = 'boot'
}

Test-Case 'отмена во время передачи' {
  $script:fakeMode = 'boot'
  $script:fakeCancelAfter = 12
  $ui = New-TestWindow -File $null
  $script:uiForCancel = $ui
  [void](Invoke-UiUpload -Ui $ui -File $script:firmware)

  Assert-Equal 'Отменено' $ui.LblStage.Text 'этап'
  Assert-True ($ui.Progress.Value -lt 100) 'полоса не дошла до конца'
  Assert-True (-not $ui.Busy) 'окно свободно'
  Assert-Match 'Отменено' $ui.Log.Text 'журнал'
  $ui.Form.Dispose()
  $script:fakeCancelAfter = 0
}

Write-Host ''
Write-Host ('Пройдено: {0}, провалено: {1}' -f $script:passed, $script:failed)
if ($script:failed -gt 0) {
  Write-Host ''
  foreach ($failure in $script:failures) { Write-Host ('  - ' + $failure) }
  exit 1
}
Write-Host 'Все проверки окна прошли.'
exit 0
