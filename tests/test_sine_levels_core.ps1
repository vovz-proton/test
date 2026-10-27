# =============================================================================
#  tests/test_sine_levels_core.ps1 - проверка логики окна уровней ЦАП без железа.
#
#  Проверяются: сборка команд DA1/DB1/DA2/DB2, разбор строк прибора, сеанс
#  связи (ACK, ERR, тайм-аут, склейка строк), модель синусоид, сводка и
#  сохранение настроек. COM-порт не открывается: связь подставная.
#
#  Запуск:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_sine_levels_core.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'tools/sine-levels-core.ps1')

# Настройки теста не должны трогать файл настоящей программы.
$script:SineSettingsPath = Join-Path $env:TEMP ('prof-kip-sine-levels-test-' + [guid]::NewGuid().ToString('N') + '.json')

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

function Assert-Near {
  param([double]$Expected, [double]$Actual, [double]$Tolerance, [string]$Message)
  if ([math]::Abs($Expected - $Actual) -gt $Tolerance) {
    throw ('{0} (ожидалось {1:N4}, получено {2:N4})' -f $Message, $Expected, $Actual)
  }
}

function Assert-Match {
  param([string]$Pattern, [string]$Text, [string]$Message)
  if ($Text -notmatch $Pattern) { throw ('{0}: "{1}" не содержит /{2}/' -f $Message, $Text, $Pattern) }
}

function Assert-Throws {
  param([scriptblock]$Body, [string]$Message)
  $thrown = $false
  try { & $Body } catch { $thrown = $true }
  if (-not $thrown) { throw $Message }
}

function New-FakeSineLink {
  <# Связь с прибором без COM-порта: Write запоминает команды, Drain отдаёт очередь. #>
  $link = [pscustomobject]@{
    Written = New-Object System.Collections.Generic.List[string]
    Out     = New-Object System.Collections.Generic.List[string]
    Closed  = $false
  }
  Add-Member -InputObject $link -MemberType ScriptMethod -Name Write -Value {
    param([string]$Text)
    if ($this.Closed) { throw 'Порт закрыт' }
    $this.Written.Add($Text)
  }
  Add-Member -InputObject $link -MemberType ScriptMethod -Name Drain -Value {
    if ($this.Closed) { return '' }
    $text = ($this.Out -join '')
    $this.Out.Clear()
    return $text
  }
  Add-Member -InputObject $link -MemberType ScriptMethod -Name Close -Value {
    $this.Closed = $true
  }
  return $link
}

function Get-EventKinds {
  param($Events)
  return (@($Events) | ForEach-Object { $_.Kind })
}

# =============================================================================
#  Команды
# =============================================================================

Write-Host ''
Write-Host 'Команды уровней'

Test-Case 'команды собираются по протоколу' {
  Assert-Equal 'DA12048' (Format-SineCommand -Name A1 -Value 2048) 'A1'
  Assert-Equal 'DB10000' (Format-SineCommand -Name B1 -Value 0) 'B1=0'
  Assert-Equal 'DA24095' (Format-SineCommand -Name A2 -Value 4095) 'A2'
  Assert-Equal 'DB20001' (Format-SineCommand -Name B2 -Value 1) 'B2=1'
  Assert-Equal 'F08000' (Format-SineCommand -Name F -Value 8000) 'частота'
  Assert-Equal 'F00100' (Format-SineCommand -Name F -Value 100) 'частота 100'
  Assert-Equal 'F20000' (Format-SineCommand -Name F -Value 20000) 'частота 20000'
  Assert-Equal 'PH+450' (Format-SineCommand -Name PH -Value 450) 'фаза +45'
  Assert-Equal 'PH-045' (Format-SineCommand -Name PH -Value -45) 'фаза −4,5'
  Assert-Equal 'PH+000' (Format-SineCommand -Name PH -Value 0) 'фаза 0'
}

Test-Case 'недопустимые уровни отклоняются' {
  Assert-Throws { Format-SineCommand -Name A1 -Value 4096 } '4096 должен быть вне диапазона'
  Assert-Throws { Format-SineCommand -Name A1 -Value -1 } '−1 должен быть вне диапазона'
  Assert-Throws { Format-SineCommand -Name X1 -Value 100 } 'неизвестное имя'
  Assert-Throws { Format-SineCommand -Name F -Value 99 } 'частота ниже диапазона'
  Assert-Throws { Format-SineCommand -Name F -Value 20001 } 'частота выше диапазона'
  Assert-Throws { Format-SineCommand -Name PH -Value 451 } 'фаза выше диапазона'
  Assert-Throws { Format-SineCommand -Name PH -Value -451 } 'фаза ниже диапазона'
}

Test-Case 'по умолчанию уровни как в прошивке' {
  $defaults = Get-SineDefaults
  Assert-Equal 2048 $defaults.A1 'A1'
  Assert-Equal 1000 $defaults.B1 'B1'
  Assert-Equal 2048 $defaults.A2 'A2'
  Assert-Equal 1000 $defaults.B2 'B2'
  Assert-Equal 8000 $defaults.F 'F'
  Assert-Equal 0 $defaults.PH 'PH'
  Assert-Equal 'A1=2048, B1=1000, A2=2048, B2=1000' (Get-SineLevelsText -Levels $defaults) 'текст уровней'
  Assert-Match 'F=8000' (Get-SineParamsText -Params $defaults) 'текст частоты'
  Assert-Match 'PH=\+0,0°' (Get-SineParamsText -Params $defaults) 'текст фазы'
  $unknown = @{ A1 = 10; B1 = $null; A2 = 30; B2 = 40 }
  Assert-Equal 'A1=10, B1=—, A2=30, B2=40' (Get-SineLevelsText -Levels $unknown) 'неизвестное значение'
}

# =============================================================================
#  Разбор строк
# =============================================================================

Write-Host ''
Write-Host 'Разбор строк прибора'

Test-Case 'ACK уровней содержит имя и код' {
  $event = ConvertFrom-SineLine -Line 'ACK=DA12048'
  Assert-Equal 'ack' $event.Kind 'вид'
  Assert-Equal 'A1' $event.Name 'имя'
  Assert-Equal 2048 $event.Value 'значение'
  $event = ConvertFrom-SineLine -Line 'ACK=DB24095'
  Assert-Equal 'B2' $event.Name 'B2'
  Assert-Equal 4095 $event.Value 'B2 значение'
  $event = ConvertFrom-SineLine -Line 'ACK=F09000'
  Assert-Equal 'ack' $event.Kind 'F вид'
  Assert-Equal 'F' $event.Name 'F имя'
  Assert-Equal 9000 $event.Value 'F значение'
  $event = ConvertFrom-SineLine -Line 'ACK=PH+225'
  Assert-Equal 'PH' $event.Name 'PH имя'
  Assert-Equal 225 $event.Value 'PH значение'
  $event = ConvertFrom-SineLine -Line 'ACK=PH-045'
  Assert-Equal -45 $event.Value 'PH отрицательная'
  $event = ConvertFrom-SineLine -Line 'ACK=PH+000'
  Assert-Equal 0 $event.Value 'PH ноль'
}

Test-Case 'ACK прочих команд не путается с уровнем' {
  $event = ConvertFrom-SineLine -Line 'ACK=PL020'
  Assert-Equal 'ack' $event.Kind 'вид'
  Assert-Equal 'PL020' $event.Name 'имя'
  Assert-True ($null -eq $event.Value) 'значения нет'
  $event = ConvertFrom-SineLine -Line 'ACK=CS'
  Assert-Equal 'CS' $event.Name 'CS'
}

Test-Case 'ERR содержит причину и код' {
  $event = ConvertFrom-SineLine -Line 'ERR=F30000,RANGE'
  Assert-Equal 'error' $event.Kind 'F RANGE вид'
  Assert-Equal 'F' $event.Name 'F RANGE имя'
  Assert-Equal 30000 $event.Value 'F RANGE значение'
  Assert-Equal 'RANGE' $event.Reason 'F RANGE причина'
  $event = ConvertFrom-SineLine -Line 'ERR=PH+999,RANGE'
  Assert-Equal 'PH' $event.Name 'PH RANGE имя'
  Assert-Equal 999 $event.Value 'PH RANGE значение'
  $event = ConvertFrom-SineLine -Line 'ERR=PH-999,RANGE'
  Assert-Equal -999 $event.Value 'PH RANGE отрицательная'
  $event = ConvertFrom-SineLine -Line 'ERR=DB11000,RANGE'
  Assert-Equal 'error' $event.Kind 'вид'
  Assert-Equal 'B1' $event.Name 'имя'
  Assert-Equal 1000 $event.Value 'значение'
  Assert-Equal 'RANGE' $event.Reason 'причина'
  $event = ConvertFrom-SineLine -Line 'ERR=FORMAT'
  Assert-Equal 'error' $event.Kind 'FORMAT'
  Assert-Equal 'FORMAT' $event.Name 'имя FORMAT'
  $event = ConvertFrom-SineLine -Line 'ERR IMAGE'
  Assert-Equal 'error' $event.Kind 'ERR IMAGE'
  Assert-Equal 'IMAGE' $event.Reason 'причина IMAGE'
}

Test-Case 'состояние и телеметрия разбираются' {
  $event = ConvertFrom-SineLine -Line 'STATE=SCAN'
  Assert-Equal 'state' $event.Kind 'вид'
  Assert-Equal 'SCAN' $event.State 'состояние'
  $event = ConvertFrom-SineLine -Line 'Z=-1234,X=1.234567'
  Assert-Equal 'telemetry' $event.Kind 'вид'
  Assert-Equal -1234 $event.Z 'Z'
  Assert-Equal '1.234567' $event.X 'X'
  $event = ConvertFrom-SineLine -Line 'Z=5,X=NA'
  Assert-Equal 'NA' $event.X 'X=NA'
}

Test-Case 'приветствие, прошивка и режим загрузки' {
  $event = ConvertFrom-SineLine -Line 'Hello from PortProfMini'
  Assert-Equal 'hello' $event.Kind 'вид'
  Assert-Equal 'PortProfMini' $event.Name 'имя прибора'
  $event = ConvertFrom-SineLine -Line 'Hello! fw 1.6'
  Assert-Equal 'hello' $event.Kind 'Hello!'
  $event = ConvertFrom-SineLine -Line 'Firmware 1.002'
  Assert-Equal 'firmware' $event.Kind 'вид'
  Assert-Equal '1.002' $event.Name 'версия'
  foreach ($line in @('UPD READY', 'R000064', 'DONE')) {
    Assert-Equal 'boot' (ConvertFrom-SineLine -Line $line).Kind ('режим загрузки: ' + $line)
  }
}

Test-Case 'пустые и посторонние строки' {
  Assert-True ($null -eq (ConvertFrom-SineLine -Line '   ')) 'пустая строка'
  Assert-True ($null -eq (ConvertFrom-SineLine -Line $null)) 'null'
  $event = ConvertFrom-SineLine -Line 'какой-то мусор'
  Assert-Equal 'text' $event.Kind 'посторонняя строка'
}

# =============================================================================
#  Сеанс связи
# =============================================================================

Write-Host ''
Write-Host 'Сеанс связи'

Test-Case 'ACK снимает ожидание и запоминает уровень' {
  $link = New-FakeSineLink
  $session = New-SineSession -Link $link
  $text = Send-SineParam -Session $session -Name A1 -Value 2048
  Assert-Equal 'DA12048' $text 'отправленная команда'
  Assert-Equal 1 $link.Written.Count 'команд записано'
  Assert-Equal 1 $session.Pending.Count 'ожиданий'

  $link.Out.Add("ACK=DA12048`r`n")
  $events = Receive-SineEvents -Session $session
  Assert-Equal 1 @($events).Count 'событий'
  Assert-Equal 'ack' @($events)[0].Kind 'вид события'
  Assert-Equal 2048 $session.Acked.A1 'подтверждённый A1'
  Assert-Equal 0 $session.Pending.Count 'ожиданий после ACK'
}

Test-Case 'ACK частоты и фазы попадают в сеанс' {
  $link = New-FakeSineLink
  $session = New-SineSession -Link $link
  Assert-Equal 'F09000' (Send-SineParam -Session $session -Name F -Value 9000) 'команда частоты'
  Assert-Equal 'PH-225' (Send-SineParam -Session $session -Name PH -Value -225) 'команда фазы'
  $link.Out.Add("ACK=F09000`r`nACK=PH-225`r`n")
  $events = Receive-SineEvents -Session $session
  Assert-Equal 2 @($events).Count 'событий'
  Assert-Equal 9000 $session.Acked.F 'частота подтверждена'
  Assert-Equal -225 $session.Acked.PH 'фаза подтверждена'
  Assert-Equal 0 $session.Pending.Count 'ожиданий нет'
}

Test-Case 'ERR снимает ожидание, но не подтверждает значение' {
  $link = New-FakeSineLink
  $session = New-SineSession -Link $link
  Send-SineParam -Session $session -Name B1 -Value 4095 | Out-Null
  $link.Out.Add("ERR=DB14095,RANGE`r`n")
  $events = Receive-SineEvents -Session $session
  Assert-Equal 1 @($events).Count 'событий'
  Assert-Equal 'error' @($events)[0].Kind 'вид'
  Assert-Equal 'RANGE' @($events)[0].Reason 'причина'
  Assert-True ($null -eq $session.Acked.B1) 'B1 не подтверждён'
  Assert-Equal 0 $session.Pending.Count 'ожиданий после ERR'
}

Test-Case 'молчание прибора даёт тайм-аут' {
  $link = New-FakeSineLink
  $session = New-SineSession -Link $link
  Send-SineParam -Session $session -Name A2 -Value 1000 | Out-Null
  $session.Pending[0].Time = [datetime]::UtcNow.AddSeconds(-5)
  $events = Receive-SineEvents -Session $session -AckTimeoutMs 100
  Assert-Equal 'timeout' @($events)[0].Kind 'вид'
  Assert-Equal 'DA21000' @($events)[0].Text 'команда'
  Assert-Equal 0 $session.Pending.Count 'ожиданий'
}

Test-Case 'склеенные и разорванные строки собираются' {
  $link = New-FakeSineLink
  $session = New-SineSession -Link $link
  Send-SineParam -Session $session -Name B2 -Value 300 | Out-Null

  $link.Out.Add('ACK=DB2')
  $events = Receive-SineEvents -Session $session
  Assert-Equal 0 @($events).Count 'неполная строка не событие'

  $link.Out.Add("0300`r`nSTATE=RE")
  $events = Receive-SineEvents -Session $session
  Assert-Equal 1 @($events).Count 'ACK и начало состояния'
  Assert-Equal 'ack' @($events)[0].Kind 'ACK'
  Assert-Equal 300 $session.Acked.B2 'B2'

  $link.Out.Add("ADY`r`n")
  $events = Receive-SineEvents -Session $session
  Assert-Equal 1 @($events).Count 'окончание состояния'
  Assert-Equal 'READY' $session.State 'состояние'
}

Test-Case 'телеметрия и приветствие попадают в сеанс' {
  $link = New-FakeSineLink
  $session = New-SineSession -Link $link
  $link.Out.Add("Hello from PortProfMini`r`nFirmware 1.002`r`nZ=12,X=0.000000`r`n")
  $events = Receive-SineEvents -Session $session
  Assert-Equal 3 @($events).Count 'событий'
  Assert-Equal 'PortProfMini' $session.Hello 'имя'
  Assert-Equal '1.002' $session.Firmware 'версия'
  Assert-Equal 12 $session.Z 'Z'
  Assert-Equal '0.000000' $session.X 'X'
  Assert-True ($null -ne $session.LastRx) 'время приёма'
}

Test-Case 'закрытый сеанс не принимает команды' {
  $link = New-FakeSineLink
  $session = New-SineSession -Link $link
  Close-SineSession -Session $session
  Assert-True $link.Closed 'связь закрыта'
  Assert-Throws { Send-SineParam -Session $session -Name A1 -Value 1 } 'отправка в закрытый сеанс'
  $events = Receive-SineEvents -Session $session
  Assert-Equal 0 @($events).Count 'событий нет'
}

# =============================================================================
#  Модель
# =============================================================================

Write-Host ''
Write-Host 'Модель синусоид'

Test-Case 'период ЦАП повторяет формулу прошивки' {
  $wave = Get-SineWaveform -Offset 2048 -Amplitude 1000 -Sign 1
  Assert-Equal 32 $wave.Count 'точек'
  Assert-Equal 2048 $wave[0] 'нулевая точка'
  Assert-Equal 3048 $wave[8] 'максимум'
  Assert-Equal 1048 ($wave | Measure-Object -Minimum).Minimum 'минимум'
  $wave2 = Get-SineWaveform -Offset 2048 -Amplitude 1000 -Sign -1
  Assert-Equal 1048 $wave2[8] 'ЦАП2 в противофазе'
}

Test-Case 'ограничение 0…4095 обрезает крайние точки' {
  $wave = Get-SineWaveform -Offset 4000 -Amplitude 1000 -Sign 1
  Assert-Equal 4095 ($wave | Measure-Object -Maximum).Maximum 'верх'
  Assert-Equal 3000 ($wave | Measure-Object -Minimum).Minimum 'низ'
  $wave = Get-SineWaveform -Offset 100 -Amplitude 1000 -Sign 1
  Assert-Equal 0 ($wave | Measure-Object -Minimum).Minimum 'низ обрезан'
}

Test-Case 'сводка считает диапазоны и разностный сигнал' {
  $summary = Get-SineSummary -A1 2048 -B1 1000 -A2 2048 -B2 1000 -Vref 3.3
  Assert-Equal 1048 $summary.Code1Min 'ЦАП1 мин'
  Assert-Equal 3048 $summary.Code1Max 'ЦАП1 макс'
  Assert-True (-not $summary.HasClip) 'без ограничения'
  Assert-Equal 2000 $summary.DiffAmplitude 'амплитуда разности'
  Assert-Equal 0 $summary.DiffOffset 'смещение разности'
  Assert-Near 1.6117 $summary.VDiffAmplitude 0.001 'вольты разности'
  Assert-Near 1.6504 $summary.V1Offset 0.001 'вольты смещения'
}

Test-Case 'сводка учитывает фазу и частоту' {
  $summary = Get-SineSummary -A1 2048 -B1 1000 -A2 2048 -B2 1000 -Vref 3.3 -Frequency 12000 -PhaseTenths 450
  Assert-Near 1847.76 $summary.DiffAmplitude 0.05 'амплитуда при 45°'
  Assert-Near 1.4892 $summary.VDiffAmplitude 0.002 'вольты при 45°'
  Assert-Equal 12000 $summary.Frequency 'частота'
  Assert-Equal 450 $summary.PhaseTenths 'фаза'
  $summary = Get-SineSummary -A1 2048 -B1 1000 -A2 2048 -B2 1000 -PhaseTenths -450
  Assert-Near 1847.76 $summary.DiffAmplitude 0.05 'амплитуда при −45°'
  $summary = Get-SineSummary -A1 2048 -B1 1000 -A2 2048 -B2 1000 -PhaseTenths 0
  Assert-Equal 2000 $summary.DiffAmplitude 'амплитуда без фазы'
}

Test-Case 'сводка помечает ограничение и не считает вольты при Vref=0' {
  $summary = Get-SineSummary -A1 4000 -B1 1000 -A2 100 -B2 500 -Vref 3.3
  Assert-True $summary.Clip1 'ЦАП1 обрезан'
  Assert-True $summary.Clip2 'ЦАП2 обрезан'
  Assert-Equal 4095 $summary.Code1Max 'верх ЦАП1'
  Assert-Equal 0 $summary.Code2Min 'низ ЦАП2'
  $summary = Get-SineSummary -A1 2048 -B1 1000 -A2 2048 -B2 1000 -Vref 0
  Assert-True ($null -eq $summary.V1Min) 'вольты не считаются'
}

# =============================================================================
#  Настройки
# =============================================================================

Write-Host ''
Write-Host 'Настройки'

Test-Case 'настройки сохраняются и читаются' {
  Save-SineSettings -Port 'COM52' -Vref 2.5 -Levels @{ A1 = 1; B1 = 2; A2 = 3; B2 = 4 } -Frequency 12000 -PhaseTenths -225
  $settings = Read-SineSettings
  Assert-Equal 'COM52' $settings.Port 'порт'
  Assert-Near 2.5 $settings.Vref 0.0001 'VREF'
  Assert-Equal 1 $settings.Levels.A1 'A1'
  Assert-Equal 2 $settings.Levels.B1 'B1'
  Assert-Equal 3 $settings.Levels.A2 'A2'
  Assert-Equal 4 $settings.Levels.B2 'B2'
  Assert-Equal 12000 $settings.Levels.F 'частота'
  Assert-Equal -225 $settings.Levels.PH 'фаза'
}

Test-Case 'битый файл настроек не ломает программу' {
  [System.IO.File]::WriteAllText($script:SineSettingsPath, '{ это не json', (New-Object System.Text.UTF8Encoding $false))
  $settings = Read-SineSettings
  Assert-Equal 2048 $settings.Levels.A1 'значение по умолчанию'
  Assert-Near 3.3 $settings.Vref 0.0001 'VREF по умолчанию'
}

Test-Case 'недопустимые значения из файла игнорируются' {
  $data = '{"port":"COM7","vref":99,"a1":5000,"b1":-1,"a2":10,"b2":20,"f":50,"ph":999}'
  [System.IO.File]::WriteAllText($script:SineSettingsPath, $data, (New-Object System.Text.UTF8Encoding $false))
  $settings = Read-SineSettings
  Assert-Equal 'COM7' $settings.Port 'порт'
  Assert-Near 3.3 $settings.Vref 0.0001 'VREF отброшен'
  Assert-Equal 2048 $settings.Levels.A1 'A1 отброшен'
  Assert-Equal 1000 $settings.Levels.B1 'B1 отброшен'
  Assert-Equal 10 $settings.Levels.A2 'A2 принят'
  Assert-Equal 20 $settings.Levels.B2 'B2 принят'
  Assert-Equal 8000 $settings.Levels.F 'F отброшена'
  Assert-Equal 0 $settings.Levels.PH 'PH отброшена'
}

# -----------------------------------------------------------------------------
#  Итог
# -----------------------------------------------------------------------------

try { Remove-Item -LiteralPath $script:SineSettingsPath -Force -ErrorAction Stop } catch { }

Write-Host ''
Write-Host ('Пройдено: {0}, провалено: {1}' -f $script:passed, $script:failed)
if ($script:failed -gt 0) {
  Write-Host ''
  foreach ($failure in $script:failures) { Write-Host ('  - ' + $failure) }
  exit 1
}
Write-Host 'Все проверки логики уровней ЦАП прошли.'
exit 0
