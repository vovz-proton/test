# =============================================================================
#  tests/test_sine_levels_ui.ps1 - проверка окна уровней ЦАП без железа.
#
#  Окно создаётся, но не показывается: проверяются ползунки, синхронизация
#  каналов, отправка уровней (все четыре при первом изменении), подтверждения
#  ACK, предупреждение об ограничении, предпросмотр и отключение.
#  Прибор подставной: та же связь Write/Drain/Close, что у настоящего порта.
#
#  Запуск:
#    powershell -NoProfile -Sta -ExecutionPolicy Bypass -File tests/test_sine_levels_ui.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $root 'tools/sine-levels-core.ps1')
. (Join-Path $root 'tools/sine-levels-ui.ps1')

# Тест не должен зависеть от подключённого прибора и от файла настроек.
$script:SineSettingsPath = Join-Path $env:TEMP ('prof-kip-sine-levels-ui-test-' + [guid]::NewGuid().ToString('N') + '.json')
try { Remove-Item -LiteralPath $script:SineSettingsPath -Force -ErrorAction Stop } catch { }

function Find-SineInstrumentPort { return $null }

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

function New-FakeSineLink {
  <# Подставной прибор: на каждую команду отвечает ACK, телеметрию кладут в Out. #>
  $link = [pscustomobject]@{
    Written = New-Object System.Collections.Generic.List[string]
    Out     = New-Object System.Collections.Generic.List[string]
    Closed  = $false
  }
  Add-Member -InputObject $link -MemberType ScriptMethod -Name Write -Value {
    param([string]$Text)
    if ($this.Closed) { throw 'Порт закрыт' }
    $this.Written.Add($Text)
    $this.Out.Add("ACK=$Text`r`n")
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

function New-FakeFactory {
  param($Link)
  return { param($portName) $Link }.GetNewClosure()
}

function New-TestWindow {
  param($Link)
  $ui = New-SineLevelsWindow -PortName 'COM99' -TransportFactory (New-FakeFactory -Link $Link) -NoAutoConnect
  return $ui
}

function Close-TestWindow {
  param($Ui)
  if ($script:SineSession) { Disconnect-SineInstrument }
  $Ui.Form.Dispose()
}

# =============================================================================
#  Окно и начальное состояние
# =============================================================================

Write-Host ''
Write-Host 'Окно и начальное состояние'

Test-Case 'окно создаётся со всеми элементами' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Assert-True ($null -ne $ui.Form) 'форма'
  Assert-Match 'Синусоиды' $ui.Form.Text 'заголовок'
  foreach ($name in @('A1', 'B1', 'A2', 'B2')) {
    Assert-True ($null -ne $ui.Num[$name]) ('поле ' + $name)
    Assert-True ($null -ne $ui.Track[$name]) ('ползунок ' + $name)
  }
  Assert-True ($null -ne $ui.Preview) 'предпросмотр'
  Assert-True ($null -ne $ui.Log) 'журнал'
  Assert-True ($null -ne $ui.BtnApply) 'кнопка «Применить всё»'
  Assert-True ($null -ne $ui.SyncA) 'связь A'
  Assert-True ($null -ne $ui.SyncB) 'связь B'
  Assert-True ($null -ne $ui.GroupGen) 'группа генератора'
  Assert-True ($null -ne $ui.Num['F']) 'поле частоты'
  Assert-True ($null -ne $ui.Track['F']) 'ползунок частоты'
  Assert-True ($null -ne $ui.Num['PH']) 'поле фазы'
  Assert-True ($null -ne $ui.Track['PH']) 'ползунок фазы'
  Close-TestWindow -Ui $ui
}

Test-Case 'начальные значения и подписи' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Assert-Equal 2048 $ui.Num['A1'].Value 'A1'
  Assert-Equal 1000 $ui.Num['B1'].Value 'B1'
  Assert-Equal 2048 $ui.Num['A2'].Value 'A2'
  Assert-Equal 1000 $ui.Num['B2'].Value 'B2'
  Assert-Equal 2048 $ui.Track['A1'].Value 'ползунок A1'
  Assert-Match 'ЦАП1' $ui.Group1.Text 'группа 1'
  Assert-Match 'ЦАП2' $ui.Group2.Text 'группа 2'
  Assert-Match 'ЦАП1: 1048…3048' $ui.Info['1'].Text 'диапазон ЦАП1'
  Assert-Match '1048…3048' $ui.LblRanges.Text 'сводка диапазонов'
  Assert-Match '2000' $ui.LblDiff.Text 'амплитуда разности'
  Assert-Match 'пределах' $ui.LblClip.Text 'без ограничения'
  Assert-Equal 8000 $ui.Num['F'].Value 'частота'
  Assert-Equal 0 $ui.Track['PH'].Value 'фаза'
  Assert-Match '8000 Гц' $ui.LblNote.Text 'частота в подписи'
  Assert-Match '\+0,0°' $ui.LblNote.Text 'фаза в подписи'
  Assert-Match 'Не подключено' $ui.StatusLabel.Text 'статус'
  Close-TestWindow -Ui $ui
}

Test-Case 'ползунок и поле меняют друг друга' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  $ui.Track['A1'].Value = 2500
  Assert-Equal 2500 $ui.Num['A1'].Value 'поле за ползунком'
  Assert-True $ui.SendTimer.Enabled 'отправка запланирована'
  $ui.SendTimer.Stop()
  $ui.Num['B1'].Value = 700
  Assert-Equal 700 $ui.Track['B1'].Value 'ползунок за полем'
  $ui.SendTimer.Stop()
  Close-TestWindow -Ui $ui
}

Test-Case 'без прибора изменения не теряются, но и не отправляются' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  $ui.Num['A1'].Value = 3000
  Invoke-SineApply
  Assert-Equal 0 $link.Written.Count 'ничего не отправлено'
  Assert-Match 'не подключён' $ui.Log.Text 'предупреждение'
  Assert-Equal 3000 $ui.Num['A1'].Value 'значение в окне сохранилось'
  Invoke-SineApply
  $count = ([regex]::Matches($ui.Log.Text, 'прибор не подключён')).Count
  Assert-Equal 1 $count 'предупреждение не повторяется'
  Close-TestWindow -Ui $ui
}

# =============================================================================
#  Подключение и обмен
# =============================================================================

Write-Host ''
Write-Host 'Подключение и обмен'

Test-Case 'подключение к подставному прибору' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  $link.Out.Add("Hello from PortProfMini`r`n")
  $link.Out.Add("Firmware 1.002`r`n")
  $link.Out.Add("STATE=READY`r`n")
  $link.Out.Add("Z=-1234,X=1.999990`r`n")

  Assert-True (Connect-SineInstrument -PortName 'COM99') 'подключение'
  Assert-True ($null -ne $script:SineSession) 'сеанс'
  Assert-Equal 'Отключить' $ui.BtnConnect.Text 'подпись кнопки'
  Assert-True (-not $ui.PortCombo.Enabled) 'список портов заблокирован'
  Assert-True $ui.RxTimer.Enabled 'приём запущен'

  Update-SineUi
  Assert-Match 'COM99' $ui.StatusLabel.Text 'статус'
  Assert-Match 'PortProfMini' $ui.StatusLabel.Text 'имя прибора'
  Assert-Match '1\.002' $ui.StatusLabel.Text 'прошивка'
  Assert-Match 'READY' $ui.StateLabel.Text 'состояние'
  Assert-Match 'Z = -1234' $ui.TelemetryLabel.Text 'телеметрия'
  Assert-Match '1\.999990' $ui.TelemetryLabel.Text 'координата'
  Close-TestWindow -Ui $ui
}

Test-Case 'первое изменение передаёт все шесть параметров' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Connect-SineInstrument -PortName 'COM99' | Out-Null
  $ui.Num['A1'].Value = 3000
  Invoke-SineApply

  Assert-Equal 6 $link.Written.Count 'команд'
  Assert-Equal 'DA13000' $link.Written[0] 'A1'
  Assert-Equal 'DB11000' $link.Written[1] 'B1'
  Assert-Equal 'DA22048' $link.Written[2] 'A2'
  Assert-Equal 'DB21000' $link.Written[3] 'B2'
  Assert-Equal 'F08000' $link.Written[4] 'частота'
  Assert-Equal 'PH+000' $link.Written[5] 'фаза'

  Update-SineUi
  Assert-Match 'A1=3000' $ui.DeviceLabel.Text 'подтверждённый A1'
  Assert-Match 'F=8000' $ui.DeviceLabel.Text 'подтверждённая частота'
  Assert-Match 'PH=\+0,0°' $ui.DeviceLabel.Text 'подтверждённая фаза'
  Assert-Match 'ACK=DA13000' $ui.Log.Text 'журнал'
  Close-TestWindow -Ui $ui
}

Test-Case 'частота и фаза меняются и передаются' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Connect-SineInstrument -PortName 'COM99' | Out-Null
  Invoke-SineApply -Force
  Update-SineUi
  $link.Written.Clear()

  $ui.Num['F'].Value = 12000
  Assert-Equal 12000 $ui.Track['F'].Value 'ползунок частоты за полем'
  $ui.Track['PH'].Value = 225
  Assert-Equal 22.5 $ui.Num['PH'].Value 'поле фазы за ползунком'
  Invoke-SineApply
  Assert-Equal 2 $link.Written.Count 'две команды'
  Assert-True ($link.Written -contains 'F12000') 'частота передана'
  Assert-True ($link.Written -contains 'PH+225') 'фаза передана'
  Update-SineUi
  Assert-Match 'F=12000' $ui.DeviceLabel.Text 'частота подтверждена'
  Assert-Match 'PH=\+22,5°' $ui.DeviceLabel.Text 'фаза подтверждена'
  Assert-Match '12000 Гц' $ui.LblNote.Text 'частота в подписи'
  Assert-Match '\+22,5°' $ui.LblNote.Text 'фаза в подписи'

  $ui.Track['PH'].Value = -450
  Assert-Equal -45 $ui.Num['PH'].Value 'отрицательная фаза'
  Invoke-SineApply
  Assert-True ($link.Written -contains 'PH-450') 'отрицательная фаза передана'
  Close-TestWindow -Ui $ui
}

Test-Case 'следующее изменение передаёт только изменённое' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Connect-SineInstrument -PortName 'COM99' | Out-Null
  Invoke-SineApply -Force
  Update-SineUi
  $link.Written.Clear()

  $ui.Num['B1'].Value = 1100
  Invoke-SineApply
  Assert-Equal 1 $link.Written.Count 'одна команда'
  Assert-Equal 'DB11100' $link.Written[0] 'B1'
  Update-SineUi
  Assert-Match 'B1=1100' $ui.DeviceLabel.Text 'B1 подтверждён'
  Close-TestWindow -Ui $ui
}

Test-Case 'ошибка прибора видна в журнале' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Connect-SineInstrument -PortName 'COM99' | Out-Null
  $ui.Num['A2'].Value = 4000
  Invoke-SineApply
  $link.Out.Add("ERR=DA24000,RANGE`r`n")
  Update-SineUi
  Assert-Match 'RANGE' $ui.Log.Text 'причина ошибки'
  Close-TestWindow -Ui $ui
}

Test-Case 'синхронизация B2 = B1 передаёт оба канала' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Connect-SineInstrument -PortName 'COM99' | Out-Null
  Invoke-SineApply -Force
  Update-SineUi
  $link.Written.Clear()

  $ui.SyncB.Checked = $true
  Assert-Equal 1000 $ui.Num['B2'].Value 'B2 равно B1'
  Assert-True (-not $ui.Num['B2'].Enabled) 'поле B2 заблокировано'

  $ui.Num['B1'].Value = 1200
  Assert-Equal 1200 $ui.Num['B2'].Value 'B2 повторяет B1'
  Invoke-SineApply
  Assert-Equal 2 $link.Written.Count 'две команды'
  Assert-True ($link.Written -contains 'DB11200') 'B1 передан'
  Assert-True ($link.Written -contains 'DB21200') 'B2 передан'

  $ui.SyncB.Checked = $false
  Assert-True $ui.Num['B2'].Enabled 'поле B2 снова доступно'
  Close-TestWindow -Ui $ui
}

Test-Case 'ограничение сигнала видно в окне' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  $ui.Num['A1'].Value = 4000
  $ui.Num['B1'].Value = 1000
  Assert-Match 'Ограничение' $ui.LblClip.Text 'предупреждение'
  Assert-Match 'A1\+B1 = 5000' $ui.LblClip.Text 'причина'
  Assert-Equal $script:SineColors.Error.ToArgb() $ui.LblClip.ForeColor.ToArgb() 'красный цвет'
  Assert-Match '4095' $ui.Info['1'].Text 'обрезанный диапазон'
  Close-TestWindow -Ui $ui
}

Test-Case 'VREF пересчитывает вольты' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  $ui.Num['A1'].Value = 4000
  $ui.Vref.Value = [decimal]2.5
  Assert-Match '2[.,]44' $ui.Info['1'].Text 'вольты при 2,5 В'
  Assert-Match '2[.,]50' $ui.LblRanges.Text 'верхняя шкала'
  Close-TestWindow -Ui $ui
}

Test-Case 'отключение возвращает окно в исходное состояние' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  Connect-SineInstrument -PortName 'COM99' | Out-Null
  Disconnect-SineInstrument

  Assert-True ($null -eq $script:SineSession) 'сеанс закрыт'
  Assert-Equal 'Подключить' $ui.BtnConnect.Text 'подпись кнопки'
  Assert-True $ui.PortCombo.Enabled 'список портов доступен'
  Assert-Match 'Не подключено' $ui.StatusLabel.Text 'статус'
  Assert-Match 'A1 = —' $ui.DeviceLabel.Text 'уровни прибора неизвестны'
  Assert-True (-not $ui.RxTimer.Enabled) 'приём остановлен'
  Close-TestWindow -Ui $ui
}

Test-Case 'ошибка открытия порта показывается в окне' {
  $factory = { param($portName) throw 'порт занят' }.GetNewClosure()
  $ui = New-SineLevelsWindow -PortName 'COM99' -TransportFactory $factory -NoAutoConnect
  Assert-True (-not (Connect-SineInstrument -PortName 'COM99')) 'подключение не удалось'
  Assert-Match 'порт занят' $ui.StatusLabel.Text 'статус'
  Assert-Match 'порт занят' $ui.Log.Text 'журнал'
  $ui.Form.Dispose()
}

# =============================================================================
#  Предпросмотр
# =============================================================================

Write-Host ''
Write-Host 'Предпросмотр'

Test-Case 'предпросмотр рисует обе синусоиды' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  $ui.Num['A1'].Value = 2600
  $ui.Num['B1'].Value = 900
  $ui.Num['A2'].Value = 1800
  $ui.Num['B2'].Value = 1300

  $bitmap = New-Object System.Drawing.Bitmap 576, 348
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  Draw-SinePreview -Graphics $graphics -Area (New-Object System.Drawing.Rectangle 0, 0, 576, 348)
  $graphics.Dispose()

  $blue = 0
  $orange = 0
  for ($x = 0; $x -lt 576; $x += 3) {
    for ($y = 0; $y -lt 348; $y += 3) {
      $color = $bitmap.GetPixel($x, $y)
      if ($color.B -gt 120 -and $color.R -lt 80) { $blue++ }
      if ($color.R -gt 170 -and $color.G -gt 80 -and $color.G -lt 170 -and $color.B -lt 80) { $orange++ }
    }
  }
  $bitmap.Dispose()
  Assert-True ($blue -gt 20) ('синяя линия: ' + $blue)
  Assert-True ($orange -gt 20) ('оранжевая линия: ' + $orange)
  Close-TestWindow -Ui $ui
}

Test-Case 'предпросмотр не падает при обрезанном сигнале' {
  $link = New-FakeSineLink
  $ui = New-TestWindow -Link $link
  $ui.Num['A1'].Value = 4095
  $ui.Num['B1'].Value = 4095
  $ui.Num['A2'].Value = 0
  $ui.Num['B2'].Value = 4095

  $bitmap = New-Object System.Drawing.Bitmap 576, 348
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  Draw-SinePreview -Graphics $graphics -Area (New-Object System.Drawing.Rectangle 0, 0, 576, 348)
  $graphics.Dispose()
  $bitmap.Dispose()
  Assert-True $true 'рисование прошло'
  Close-TestWindow -Ui $ui
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
Write-Host 'Все проверки окна уровней ЦАП прошли.'
exit 0
