# =============================================================================
#  tests/test_upload_core.ps1 - проверка ядра обновления ПО без железа.
#
#  Подставной прибор повторяет поведение Core/Src/firmware_update.c:
#  ACK=BT -> UPD READY -> R****** каждые 64 записи -> DONE / ERR / ERR IMAGE.
#  Проверяются: разбор .hex/.bin, отсев плохих файлов до отправки, полоса
#  0..100 %, статусы, отмена, отказ прибора и подтверждение телеметрией.
#
#  Запуск:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_upload_core.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools\upload-core.ps1')

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

function New-FakeInstrument {
  <#
    Behaviour:
      ok            - штатный приём и DONE;
      busy          - на BT отвечает ERR=BT,BUSY;
      silent        - на BT не отвечает (не входит в режим загрузки);
      silent-after  - штатно, но после DONE порт молчит (нет телеметрии);
      image         - на GO отвечает ERR IMAGE;
      receive-error - на GO отвечает ERR 1 (ошибки приёма);
      running       - уже работающая прошивка: Hello! и телеметрия, BT не нужен.
  #>
  param([string]$Behaviour = 'ok')

  $dev = [pscustomobject]@{
    PortName       = 'COM99'
    Behaviour      = $Behaviour
    Closed         = $false
    Queue          = New-Object System.Collections.Generic.List[string]
    InUpload       = $false
    Records        = 0
    Errors         = 0
    SawEof         = $false
    Writes         = 0
    HexLines       = 0
    TelemetryIndex = 0
    Opened         = $true
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Emit -Value {
    param([string]$Text)
    $this.Queue.Add($Text)
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Handle -Value {
    param([string]$Line)

    if ($Line.StartsWith(':')) {
      $this.HexLines++
      if (-not $this.InUpload) { return }
      if ($Line.Length -gt 199) { $this.Errors++; return }          # как LINE_MAX на приборе
      $type = [Convert]::ToInt32($Line.Substring(7, 2), 16)
      if ($type -eq 1) { $this.SawEof = $true; return }
      if ($type -eq 0) {
        $this.Records++
        if (($this.Records % 64) -eq 0) { $this.Emit(('R{0:D6}' -f $this.Records)) }
      }
      return
    }

    if ($Line -eq 'ID') {
      if ($this.InUpload) { $this.Emit('UPD 1.6') }
      return
    }

    if ($Line -eq 'BT') {
      if ($this.Behaviour -eq 'busy') { $this.Emit('ERR=BT,BUSY'); return }
      if ($this.Behaviour -eq 'silent') { return }
      if ($this.Behaviour -eq 'running') { return }
      $this.InUpload = $true
      $this.Records = 0
      $this.Errors = 0
      $this.SawEof = $false
      $this.Emit('ACK=BT')
      $this.Emit('UPD READY')
      return
    }

    if ($Line -eq 'GO') {
      if (-not $this.InUpload) { return }
      if ($this.Behaviour -eq 'image') { $this.Emit('ERR IMAGE'); return }
      if ($this.Behaviour -eq 'receive-error') { $this.Errors++ }
      if ($this.Errors -gt 0) { $this.Emit(('ERR {0}' -f $this.Errors)); return }
      if (-not $this.SawEof -or $this.Records -eq 0) { $this.Emit('ERR IMAGE'); return }
      $this.InUpload = $false
      $this.Emit('DONE')
      return
    }
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Write -Value {
    param([string]$Text)
    if ($this.Closed) { throw 'порт закрыт' }
    $this.Writes++
    foreach ($part in [regex]::Split($Text, "`r`n|`n|`r")) {
      $line = $part.Trim()
      if ($line.Length -gt 0) { $this.Handle($line) }
    }
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name ReadLines -Value {
    param([int]$Milliseconds)

    $out = New-Object System.Collections.Generic.List[string]

    if ($this.Behaviour -eq 'running') {
      # Работающая прошивка: приветствие при открытии порта и поток Z=..
      if ($this.TelemetryIndex -eq 0) { $out.Add('Hello! fw 1.6') }
      $this.TelemetryIndex++
      $out.Add(('Z={0},X=1.999990' -f (-1234 + $this.TelemetryIndex)))
    }

    if ($this.Queue.Count -gt 0) {
      foreach ($item in $this.Queue) { $out.Add($item) }
      $this.Queue.Clear()
    } elseif ($out.Count -eq 0 -and $Milliseconds -gt 0) {
      Start-Sleep -Milliseconds 5
    }

    return ,$out.ToArray()
  }

  Add-Member -InputObject $dev -MemberType ScriptMethod -Name Close -Value {
    $this.Closed = $true
  }

  return $dev
}

# Порт прибора «подключается» только там, где это нужно тесту.
$script:fakePortVisible = $false
function Find-UploadInstrumentPort {
  if (-not $script:fakePortVisible) { return $null }
  return [pscustomobject]@{ Port = 'COM99'; Name = 'Fake STM32 Virtual COM Port (COM99)'; Status = 'OK' }
}

# -----------------------------------------------------------------------------
#  Образы прошивки для тестов
# -----------------------------------------------------------------------------

function New-TestFirmware {
  param(
    [string]$Name,
    [int]$Bytes = 2048,
    [switch]$NoEof,
    [switch]$BadChecksum,
    [switch]$BadVectors,
    [switch]$CrlfToLf,
    [switch]$ExtraBeyondApp
  )

  $image = New-Object 'byte[]' $Bytes
  for ($i = 0; $i -lt $Bytes; $i++) { $image[$i] = [byte]0xFF }
  if ($BadVectors) {
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x10000000), 0, $image, 0, 4)   # стек не в RAM
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x08000100), 0, $image, 4, 4)   # без Thumb-бита
  } else {
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x20004000), 0, $image, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]0x08000101), 0, $image, 4, 4)
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add((New-UploadHexRecord -Address 0 -Type 4 -Data ([byte[]](0x08, 0x00))))
  $offset = 0
  while ($offset -lt $Bytes) {
    $chunk = [Math]::Min(16, $Bytes - $offset)
    $slice = New-Object 'byte[]' $chunk
    [Array]::Copy($image, $offset, $slice, 0, $chunk)
    $lines.Add((New-UploadHexRecord -Address $offset -Type 0 -Data $slice))
    $offset += $chunk
  }
  if ($ExtraBeyondApp) {
    # Запись копировщика за пределами области приложения: прибор её пропускает.
    $lines.Add((New-UploadHexRecord -Address 0x7800 -Type 0 -Data ([byte[]](0x01, 0x02, 0x03, 0x04))))
  }
  if (-not $NoEof) { $lines.Add((New-UploadHexRecord -Address 0 -Type 1 -Data @())) }

  $text = ($lines -join "`r`n") + "`r`n"
  if ($BadChecksum) {
    # Портим последний символ (контрольную сумму) третьей строки файла.
    $rows = [regex]::Split($text, "`r`n")
    $index = 2
    $digits = '0123456789ABCDEF'
    $lastChar = $rows[$index].Substring($rows[$index].Length - 1, 1)
    $position = $digits.IndexOf($lastChar)
    if ($position -lt 0) { $position = 0 }
    $replacement = $digits.Substring(($position + 1) % 16, 1)
    $rows[$index] = $rows[$index].Substring(0, $rows[$index].Length - 1) + $replacement
    $text = ($rows -join "`r`n")
  }
  if ($CrlfToLf) { $text = $text.Replace("`r`n", "`n") }

  $path = Join-Path $env:TEMP $Name
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
  return $path
}

# -----------------------------------------------------------------------------
#  Прогон заливки на подставном приборе
# -----------------------------------------------------------------------------

function Invoke-TestUpload {
  param(
    [string]$PlanPath,
    [string]$Behaviour = 'ok',
    [string]$SecondBehaviour = '',
    [hashtable]$Options = @{},
    [scriptblock]$ShouldStop = $null,
    [switch]$VisiblePort
  )

  $script:fakeCalls = 0
  $script:fakePortVisible = [bool]$VisiblePort
  $script:firstBehaviour = $Behaviour
  $script:secondBehaviour = $SecondBehaviour
  $progress = New-Object System.Collections.Generic.List[object]
  $log = New-Object System.Collections.Generic.List[string]

  $opts = @{}
  foreach ($key in $Options.Keys) { $opts[$key] = $Options[$key] }
  if (-not $opts.ContainsKey('SkipVerify')) { $opts['SkipVerify'] = $true }

  $plan = Get-UploadFirmwarePlan -Path $PlanPath
  $result = Invoke-FirmwareUpload -Plan $plan -PortName 'COM99' -TransportFactory {
      param($portName)
      $script:fakeCalls++
      $behaviour = $script:firstBehaviour
      if ($script:fakeCalls -gt 1 -and $script:secondBehaviour) { $behaviour = $script:secondBehaviour }
      return (New-FakeInstrument -Behaviour $behaviour)
    } `
    -Options $opts `
    -OnProgress { param($percent, $stage, $detail) $progress.Add([pscustomobject]@{ Percent = $percent; Stage = $stage; Detail = $detail }) } `
    -OnLog { param($text) $log.Add($text) } `
    -ShouldStop $ShouldStop

  return [pscustomobject]@{
    Result       = $result
    Progress     = $progress
    Log          = $log
    FactoryCalls = $script:fakeCalls
  }
}

$script:firstBehaviour = 'ok'
$script:secondBehaviour = ''
$script:fakeCalls = 0

# =============================================================================
#  Тесты
# =============================================================================

Write-Host ''
Write-Host 'Разбор и проверка файла прошивки'

$script:firmware = New-TestFirmware -Name 'test_fw_ok.hex' -Bytes 2048

Test-Case 'корректный HEX принимается целиком' {
  $plan = Get-UploadFirmwarePlan -Path $script:firmware
  Assert-True $plan.IsValid ('ожидался годный файл, ошибки: ' + ($plan.Errors -join '; '))
  Assert-Equal 128 $plan.DataRecords 'число записей данных'
  Assert-Equal 2048 $plan.PayloadBytes 'объём данных'
  Assert-Equal 130 (@($plan.Lines).Count) 'строк для отправки (старший адрес + 128 записей + конец файла)'
  Assert-True $plan.HasEof 'признак конца файла'
  Assert-Equal ([uint32]0x08000101) $plan.EntryPoint 'вектор сброса'
  Assert-Equal ([uint32]0x20004000) $plan.StackPointer 'начальный стек'
}

Test-Case 'HEX с переводами строк LF тоже принимается' {
  $path = New-TestFirmware -Name 'test_fw_lf.hex' -Bytes 1024 -CrlfToLf
  $plan = Get-UploadFirmwarePlan -Path $path
  Assert-True $plan.IsValid ('ожидался годный файл, ошибки: ' + ($plan.Errors -join '; '))
  Assert-Equal 64 $plan.DataRecords 'число записей данных'
}

Test-Case 'записи за 30 КБ (копировщик) пропускаются без ошибки' {
  $path = New-TestFirmware -Name 'test_fw_copyer.hex' -Bytes 1024 -ExtraBeyondApp
  $plan = Get-UploadFirmwarePlan -Path $path
  Assert-True $plan.IsValid ('ожидался годный файл, ошибки: ' + ($plan.Errors -join '; '))
  Assert-Equal 1 $plan.SkippedRecords 'записей вне приложения'
  Assert-Equal 64 $plan.DataRecords 'записей в приложении'
}

Test-Case 'файл без записи конца отвергается до отправки' {
  $path = New-TestFirmware -Name 'test_fw_noeof.hex' -Bytes 1024 -NoEof
  $plan = Get-UploadFirmwarePlan -Path $path
  Assert-True (-not $plan.IsValid) 'файл без :00000001FF должен быть отвергнут'
  Assert-Match 'конца файла' ($plan.Errors -join ' ') 'сообщение об ошибке'
}

Test-Case 'неверная контрольная сумма строки отвергается с номером строки' {
  $path = New-TestFirmware -Name 'test_fw_badsum.hex' -Bytes 1024 -BadChecksum
  $plan = Get-UploadFirmwarePlan -Path $path
  Assert-True (-not $plan.IsValid) 'файл с битой суммой должен быть отвергнут'
  Assert-Match 'Строка \d+' ($plan.Errors -join ' ') 'сообщение указывает строку'
}

Test-Case 'неправдоподобная таблица векторов отвергается' {
  $path = New-TestFirmware -Name 'test_fw_badvec.hex' -Bytes 1024 -BadVectors
  $plan = Get-UploadFirmwarePlan -Path $path
  Assert-True (-not $plan.IsValid) 'файл с плохими векторами должен быть отвергнут'
  $text = $plan.Errors -join ' '
  Assert-Match 'стек' $text 'сообщение про стек'
  Assert-Match 'Thumb' $text 'сообщение про Thumb-бит'
}

Test-Case 'отсутствующий файл отвергается' {
  $plan = Get-UploadFirmwarePlan -Path (Join-Path $env:TEMP 'no-such-firmware.hex')
  Assert-True (-not $plan.IsValid) 'несуществующий файл не может быть годным'
  Assert-Match 'не найден' ($plan.Errors -join ' ') 'сообщение об отсутствии файла'
}

$realHex = Join-Path $root 'build/Prof_KIP_v5.hex'
$realBin = Join-Path $root 'build/Prof_KIP_v5.bin'

Test-Case 'реальная сборка build/Prof_KIP_v5.hex разбирается' {
  if (-not (Test-Path -LiteralPath $realHex)) { throw 'нет build/Prof_KIP_v5.hex - сначала соберите прошивку' }
  $plan = Get-UploadFirmwarePlan -Path $realHex
  Assert-True $plan.IsValid ('ожидался годный файл, ошибки: ' + ($plan.Errors -join '; '))
  # Числа зависят от текущей сборки, поэтому проверяем правдоподобие, а не точные
  # значения: иначе тест ломается от любой правки кода (так и вышло после смены
  # приветствия - записей стало 1502 вместо 1496).
  Assert-True ($plan.DataRecords -ge 1000 -and $plan.DataRecords -le 2000) ('записей в области приложения: ' + $plan.DataRecords)
  Assert-True ($plan.PayloadBytes -gt 20000 -and $plan.PayloadBytes -le 30720) ('объём кода: ' + $plan.PayloadBytes)
  Assert-True ($plan.SkippedRecords -ge 1) ('записей копировщика: ' + $plan.SkippedRecords)
  Assert-Equal 0x08000000 $plan.FirstAddress 'адрес начала образа'
  Assert-True ($plan.LastAddress -gt 0x08000000 -and $plan.LastAddress -lt 0x08007800) ('адрес конца кода: ' + ('0x{0:X8}' -f $plan.LastAddress))
}

Test-Case 'реальная сборка build/Prof_KIP_v5.bin обрезается до 30 КБ' {
  if (-not (Test-Path -LiteralPath $realBin)) { throw 'нет build/Prof_KIP_v5.bin - сначала соберите прошивку' }
  $plan = Get-UploadFirmwarePlan -Path $realBin
  Assert-True $plan.IsValid ('ожидался годный файл, ошибки: ' + ($plan.Errors -join '; '))
  Assert-Equal 30720 $plan.PayloadBytes 'в прибор уходит ровно 30 КБ'
  Assert-Equal 1920 $plan.DataRecords 'записей по 16 байт'
  Assert-True ($plan.Warnings.Count -gt 0) 'должно быть предупреждение об обрезке копировщика'
  Assert-Match 'копировщик' ($plan.Warnings -join ' ') 'предупреждение упоминает копировщик'
}

Write-Host ''
Write-Host 'Обмен с прибором'

Test-Case 'удачная заливка: 100 %, полоса не идёт назад' {
  $run = Invoke-TestUpload -PlanPath $script:firmware
  Assert-True $run.Result.Success ('ожидался успех, сообщение: ' + $run.Result.Message)
  Assert-True (-not $run.Result.Cancelled) 'не должно быть отмены'
  Assert-Equal 100 $run.Result.Percent 'итоговый процент'
  Assert-Equal 128 $run.Result.DeviceRecords 'прибор насчитал все записи'
  Assert-True ($run.Progress.Count -ge 5) 'слишком мало событий прогресса'

  $previous = -1
  foreach ($step in $run.Progress) {
    Assert-True ($step.Percent -ge $previous) ('процент уменьшился: {0} после {1}' -f $step.Percent, $previous)
    Assert-True ($step.Percent -ge 0 -and $step.Percent -le 100) ('процент вне 0..100: {0}' -f $step.Percent)
    Assert-True ($step.Stage.Length -gt 0) 'у этапа должно быть название'
    $previous = $step.Percent
  }
  Assert-Equal 100 $previous 'последнее событие прогресса'
  $stages = ($run.Progress | ForEach-Object { $_.Stage }) -join '|'
  Assert-Match 'Передача прошивки' $stages 'этап передачи'
  Assert-Match 'Готово' $stages 'финальный этап'
}

Test-Case 'вывод подписок не ломает разбор ответов прибора' {
  # Регрессия: если OnLog/OnProgress что-то возвращают, это значение не должно
  # приниматься за сигнал протокола (однажды приняли "ACK=BT" за ответ).
  $script:firstBehaviour = 'ok'
  $script:secondBehaviour = ''
  $script:fakePortVisible = $false
  $script:fakeCalls = 0
  $plan = Get-UploadFirmwarePlan -Path $script:firmware
  $result = Invoke-FirmwareUpload -Plan $plan -PortName 'COM99' `
    -TransportFactory { param($portName) $script:fakeCalls++; return (New-FakeInstrument -Behaviour 'ok') } `
    -Options @{ SkipVerify = $true } `
    -OnProgress { param($percent, $stage, $detail) return ('прогресс {0} {1}' -f $percent, $stage) } `
    -OnLog { param($text) return ('журнал: ' + $text) }

  Assert-True ($result -is [pscustomobject]) ('ядро должно вернуть один объект, а не массив: ' + $result.GetType().Name)
  Assert-True $result.Success ('ожидался успех, сообщение: ' + $result.Message)
  Assert-Equal 100 $result.Percent 'итоговый процент'
  Assert-Equal 128 $result.DeviceRecords 'прибор насчитал все записи'
}

Test-Case 'удачная заливка подтверждается телеметрией (порт вернулся)' {
  $script:firstBehaviour = 'ok'
  $script:secondBehaviour = 'running'
  $run = Invoke-TestUpload -PlanPath $script:firmware -VisiblePort -SecondBehaviour 'running' -Options @{ SkipVerify = $false; VerifyTimeoutSec = 5 }
  $script:secondBehaviour = ''
  Assert-True $run.Result.Success ('ожидался успех, сообщение: ' + $run.Result.Message)
  Assert-True $run.Result.Verified 'телеметрия должна подтвердить запуск'
  Assert-Match '^Z=' $run.Result.Telemetry 'строка телеметрии'
  Assert-Equal '1.6' $run.Result.VersionAfter 'версия из приветствия'
  Assert-True ($run.FactoryCalls -ge 2) 'порт должен открываться повторно после перезапуска'
  Assert-Match 'Готово' ($run.Progress[-1].Stage) 'финальный статус'
}

Test-Case 'прибор занят: ERR=BT,BUSY объясняется пользователю' {
  $run = Invoke-TestUpload -PlanPath $script:firmware -Behaviour 'busy'
  Assert-True (-not $run.Result.Success) 'ожидалась ошибка'
  Assert-Match 'BUSY' $run.Result.Message 'сообщение про занятость'
  Assert-Match 'READY' $run.Result.Message 'подсказка про READY'
  Assert-True ($run.Result.Percent -lt 100) 'полоса не должна доходить до 100 %'
  Assert-Match 'Ошибка' ($run.Progress[-1].Stage) 'статус ошибки'
}

Test-Case 'прибор молчит на BT: понятный тайм-аут' {
  $run = Invoke-TestUpload -PlanPath $script:firmware -Behaviour 'silent' -Options @{ SkipVerify = $true; ReadyTimeoutSec = 2 }
  Assert-True (-not $run.Result.Success) 'ожидалась ошибка'
  Assert-Match 'UPD READY' $run.Result.Message 'сообщение про ожидание готовности'
}

Test-Case 'прибор отверг образ: ERR IMAGE' {
  $run = Invoke-TestUpload -PlanPath $script:firmware -Behaviour 'image'
  Assert-True (-not $run.Result.Success) 'ожидалась ошибка'
  Assert-Match 'ERR IMAGE' $run.Result.Message 'сообщение про отказ образа'
}

Test-Case 'ошибки приёма на приборе: ERR n' {
  $run = Invoke-TestUpload -PlanPath $script:firmware -Behaviour 'receive-error'
  Assert-True (-not $run.Result.Success) 'ожидалась ошибка'
  Assert-Match 'ошибки приёма' $run.Result.Message 'сообщение про ошибки приёма'
}

Test-Case 'отмена во время передачи останавливает работу' {
  $script:stopCalls = 0
  $stop = { $script:stopCalls++; return ($script:stopCalls -ge 6) }
  $run = Invoke-TestUpload -PlanPath $script:firmware -ShouldStop $stop
  Assert-True $run.Result.Cancelled 'ожидалась отмена'
  Assert-True (-not $run.Result.Success) 'отмена не является успехом'
  Assert-True ($run.Result.Percent -ge 12 -and $run.Result.Percent -lt 100) ('процент при отмене: {0}' -f $run.Result.Percent)
  Assert-Match 'Отменено' ($run.Progress[-1].Stage) 'статус отмены'
}

Test-Case 'непригодный файл не открывает порт' {
  $bad = New-TestFirmware -Name 'test_fw_bad2.hex' -Bytes 1024 -NoEof
  $run = Invoke-TestUpload -PlanPath $bad
  Assert-True (-not $run.Result.Success) 'ожидалась ошибка'
  Assert-Equal 0 $run.FactoryCalls 'порт открываться не должен'
  Assert-Match 'не подходит' $run.Result.Message 'сообщение про непригодный файл'
}

Test-Case 'порт не найден: подсказка про USB' {
  $script:fakePortVisible = $false
  $plan = Get-UploadFirmwarePlan -Path $script:firmware
  $result = Invoke-FirmwareUpload -Plan $plan -Options @{ SkipVerify = $true } -OnProgress { param($p, $s, $d) } -OnLog { param($t) }
  Assert-True (-not $result.Success) 'ожидалась ошибка'
  Assert-Match 'VID_0483' $result.Message 'сообщение упоминает VID/PID прибора'
}

Test-Case 'заливка прошла, но телеметрии нет: предупреждение, не провал' {
  $script:firstBehaviour = 'ok'
  $script:secondBehaviour = 'silent-after'
  $run = Invoke-TestUpload -PlanPath $script:firmware -VisiblePort -SecondBehaviour 'silent-after' -Options @{ SkipVerify = $false; VerifyTimeoutSec = 2 }
  $script:secondBehaviour = ''
  Assert-True $run.Result.Success 'образ принят прибором - это успех'
  Assert-True (-not $run.Result.Verified) 'телеметрия не подтверждена'
  Assert-Match 'телеметрия' $run.Result.Message 'сообщение объясняет ситуацию'
}

Write-Host ''
Write-Host 'Классификация строк прибора'

Test-Case 'строки протокола распознаются' {
  $cases = @(
    @('ACK=BT', 'ack'),
    @('UPD READY', 'ready'),
    @('UPD TIMEOUT', 'timeout'),
    @('UPD ERASE_ERR', 'erase'),
    @('UPD 1.6', 'version'),
    @('R000064', 'progress'),
    @('DONE', 'done'),
    @('ERR=BT,BUSY', 'error'),
    @('ERR IMAGE', 'error'),
    @('STATE=READY', 'state'),
    @('Z=-1234,X=1.999990', 'telemetry'),
    @('Hello! fw 1.6', 'hello'),
    @('что-то иное', 'other')
  )
  foreach ($case in $cases) {
    $kind = Get-UploadLineKind $case[0]
    Assert-Equal $case[1] $kind ('строка "{0}"' -f $case[0])
  }
}

Test-Case 'HEX-запись собирается и разбирается обратно' {
  $data = [byte[]](1, 2, 3, 4, 5, 6, 7, 8)
  $record = New-UploadHexRecord -Address 0x0010 -Type 0 -Data $data
  $parsed = ConvertFrom-UploadHexLine -Text $record
  Assert-True ($null -ne $parsed) 'запись должна разбираться'
  Assert-Equal 8 $parsed.Count 'длина данных'
  Assert-Equal 0x0010 $parsed.Address 'адрес'
  Assert-Equal 0 $parsed.Type 'тип записи'
  Assert-True ($null -eq (ConvertFrom-UploadHexLine -Text (':00000001FE'))) 'запись с неверной суммой отвергается'
}

# =============================================================================
#  Итог
# =============================================================================

Write-Host ''
Write-Host ('Пройдено: {0}, провалено: {1}' -f $script:passed, $script:failed)
if ($script:failed -gt 0) {
  Write-Host ''
  foreach ($failure in $script:failures) { Write-Host ('  - ' + $failure) }
  exit 1
}
Write-Host 'Все проверки ядра прошли.'
exit 0
