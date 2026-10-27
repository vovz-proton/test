# =============================================================================
#  sine-levels-core.ps1 - логика окна уровней ЦАП Prof_KIP_v5.
#
#  Здесь нет WinForms: только обмен строками с прибором, разбор ответов,
#  сборка команд DA1/DB1/DA2/DB2, модель синусоид и сохранение настроек.
#  Окно - sine-levels-ui.ps1, запуск - SineLevels.ps1.
#
#  Протокол описан в docs/USB_PROTOCOL.md («Уровни ЦАП»):
#      DA1<4 цифры> - смещение A1,  DB1<4 цифры> - амплитуда B1,
#      DA2<4 цифры> - смещение A2,  DB2<4 цифры> - амплитуда B2.
#  Прибор отвечает ACK=<команда> или ERR=<команда>,RANGE и присылает
#  телеметрию Z=...,X=..., STATE=... Уровни ЦАП прибор не сообщает:
#  известны только те значения, которые подтверждены его ACK.
# =============================================================================

$script:SineCodeMin      = 0
$script:SineCodeMax      = 4095
$script:SineFreqMin      = 100
$script:SineFreqMax      = 20000
$script:SineFreqDefault  = 8000
$script:SinePhaseMax     = 450         # десятые градуса, ±45.0
$script:SineBaudRate     = 115200          # USB CDC: значение справочное
$script:SineVidPid       = 'VID_0483&PID_5740'  # STM32 virtual COM port
$script:SineAckTimeoutMs = 1500
$script:SineLevelNames   = @('A1', 'B1', 'A2', 'B2')
$script:SineParamNames   = @('A1', 'B1', 'A2', 'B2', 'F', 'PH')
$script:SineCommandPrefix = @{ A1 = 'DA1'; B1 = 'DB1'; A2 = 'DA2'; B2 = 'DB2' }
$script:SinePrefixName    = @{ DA1 = 'A1'; DB1 = 'B1'; DA2 = 'A2'; DB2 = 'B2' }
$script:SineSettingsPath  = Join-Path $env:LOCALAPPDATA 'Prof_KIP_v5\sine-levels.json'

# -----------------------------------------------------------------------------
#  Значения уровней
# -----------------------------------------------------------------------------

function Get-SineDefaults {
  <# Значения по умолчанию совпадают с DAC_SINE_*_DEFAULT в прошивке. #>
  return @{
    A1 = 2048; B1 = 1000; A2 = 2048; B2 = 1000
    F  = 8000; PH = 0
  }
}

function Get-SineLevelAt {
  <# Значение параметра из набора; $null, если неизвестно. #>
  param([hashtable]$Levels, [string]$Name)
  if (-not $Levels -or -not $Levels.ContainsKey($Name)) { return $null }
  return $Levels[$Name]
}

function Format-SineCommandText {
  <# Команда без проверки диапазона: нужна и для разбора ответа ERR=…4096 #>
  param([string]$Name, [int]$Value)
  $key = ([string]$Name).ToUpperInvariant()
  $invariant = [System.Globalization.CultureInfo]::InvariantCulture
  if ($script:SineCommandPrefix.ContainsKey($key)) {
    return $script:SineCommandPrefix[$key] + $Value.ToString('D4', $invariant)
  }
  if ($key -eq 'F') { return 'F' + $Value.ToString('D5', $invariant) }
  if ($key -eq 'PH') {
    $sign = '+'
    $tenths = $Value
    if ($tenths -lt 0) { $sign = '-'; $tenths = -$tenths }
    return 'PH' + $sign + $tenths.ToString('D3', $invariant)
  }
  throw ('Неизвестный параметр «{0}»: ожидались A1, B1, A2, B2, F или PH.' -f $Name)
}

function Format-SineCommand {
  <# Проверить диапазон и собрать команду: DA12048, F08000, PH+450. #>
  param([string]$Name, [int]$Value)
  $key = ([string]$Name).ToUpperInvariant()
  if ($script:SineCommandPrefix.ContainsKey($key)) {
    if ($Value -lt $script:SineCodeMin -or $Value -gt $script:SineCodeMax) {
      throw ('Код ЦАП вне диапазона {0}…{1}: {2}' -f $script:SineCodeMin, $script:SineCodeMax, $Value)
    }
  } elseif ($key -eq 'F') {
    if ($Value -lt $script:SineFreqMin -or $Value -gt $script:SineFreqMax) {
      throw ('Частота вне диапазона {0}…{1} Гц: {2}' -f $script:SineFreqMin, $script:SineFreqMax, $Value)
    }
  } elseif ($key -eq 'PH') {
    if ($Value -lt -$script:SinePhaseMax -or $Value -gt $script:SinePhaseMax) {
      throw ('Фаза вне диапазона −45,0…+45,0°: {0} десятых градуса' -f $Value)
    }
  } else {
    throw ('Неизвестный параметр «{0}»: ожидались A1, B1, A2, B2, F или PH.' -f $Name)
  }
  return Format-SineCommandText -Name $Name -Value $Value
}

function Get-SineLevelsText {
  <# Строка вида «A1=2048, B1=1000, …» для журнала и подписи. #>
  param([hashtable]$Levels)
  $parts = foreach ($name in $script:SineLevelNames) {
    $value = Get-SineLevelAt -Levels $Levels -Name $name
    if ($null -eq $value) { '{0}=—' -f $name } else { '{0}={1}' -f $name, $value }
  }
  return ($parts -join ', ')
}

function Get-SineParamsText {
  <# Все шесть параметров, включая частоту и фазу, для строки «На приборе». #>
  param([hashtable]$Params)
  $culture = [System.Globalization.CultureInfo]::CurrentCulture
  $parts = foreach ($name in $script:SineParamNames) {
    $value = Get-SineLevelAt -Levels $Params -Name $name
    if ($null -eq $value) { '{0}=—' -f $name }
    elseif ($name -eq 'PH') {
      $tenths = [int]$value
      $sign = '+'
      if ($tenths -lt 0) { $sign = '-'; $tenths = -$tenths }
      'PH={0}{1}°' -f $sign, ($tenths / 10.0).ToString('0.0', $culture)
    } else {
      '{0}={1}' -f $name, $value
    }
  }
  return ($parts -join ', ')
}

# -----------------------------------------------------------------------------
#  COM-порты
# -----------------------------------------------------------------------------

function Get-SineComPorts {
  <# Имена всех последовательных портов, которые видит Windows. #>
  try { return @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) }
  catch { return @() }
}

function Find-SineInstrumentPort {
  <# Найти COM-порт прибора по VID/PID. $null, если прибор не подключён. #>
  $result = $null

  # Основной путь: PnP-устройства через WMI/CIM.
  try {
    $cim = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
           Where-Object { $_.DeviceID -match [regex]::Escape($script:SineVidPid) } |
           Select-Object -First 1
    if ($cim) {
      $m = [regex]::Match([string]$cim.Name, '\((COM\d+)\)')
      if ($m.Success) {
        $result = [pscustomobject]@{ Port = $m.Groups[1].Value; Name = [string]$cim.Name; Status = [string]$cim.Status }
      }
    }
  } catch { }

  # Запасной путь: реестр. SERIALCOMM перечисляет только живые порты,
  # а ветка Enum\USB хранит привязку VID/PID к номеру порта.
  if (-not $result) {
    try {
      $live = New-Object System.Collections.Generic.List[string]
      $map = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM' -ErrorAction Stop
      foreach ($property in $map.PSObject.Properties) {
        if ($property.Name.StartsWith('PS')) { continue }
        if ([string]$property.Value -match '^COM\d+$') { $live.Add([string]$property.Value) }
      }
      if ($live.Count -gt 0) {
        $enumKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\' + $script:SineVidPid
        foreach ($instance in @(Get-ChildItem -LiteralPath $enumKey -ErrorAction Stop)) {
          $props = Get-ItemProperty -LiteralPath $instance.PSPath -ErrorAction SilentlyContinue
          $m = [regex]::Match([string]$props.FriendlyName, '\((COM\d+)\)')
          if ($m.Success -and $live.Contains($m.Groups[1].Value)) {
            $result = [pscustomobject]@{ Port = $m.Groups[1].Value; Name = [string]$props.FriendlyName; Status = 'OK' }
            break
          }
        }
      }
    } catch { }
  }

  return $result
}

function New-SineSerialLink {
  <#
    Открыть COM-порт и вернуть связь с методами Write, Drain, Close.
    Прибор по DTR отправляет приветствие, поэтому DTR включён.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$PortName,
    [int]$ReadTimeoutMs = 100,
    [int]$WriteTimeoutMs = 2000
  )

  $port = New-Object System.IO.Ports.SerialPort $PortName, $script:SineBaudRate, 'None', 8, 'One'
  $port.ReadTimeout    = $ReadTimeoutMs
  $port.WriteTimeout   = $WriteTimeoutMs
  $port.NewLine        = "`r`n"
  $port.DtrEnable      = $true
  $port.Encoding       = [System.Text.Encoding]::ASCII
  try { $port.ReadBufferSize = 16384 } catch { }

  try {
    $port.Open()
  } catch {
    try { $port.Dispose() } catch { }
    throw ('Не удалось открыть {0}: {1}' -f $PortName, $_.Exception.Message)
  }

  $link = [pscustomobject]@{ PortName = $PortName; Port = $port; Closed = $false }

  Add-Member -InputObject $link -MemberType ScriptMethod -Name Write -Value {
    param([string]$Text)
    if ($this.Closed) { throw 'Порт закрыт' }
    $this.Port.Write($Text)
  }

  Add-Member -InputObject $link -MemberType ScriptMethod -Name Drain -Value {
    if ($this.Closed) { return '' }
    $builder = New-Object System.Text.StringBuilder
    try {
      $guard = 0
      while ($this.Port.IsOpen -and $this.Port.BytesToRead -gt 0 -and $guard -lt 64) {
        [void]$builder.Append($this.Port.ReadExisting())
        $guard++
      }
    } catch { }
    return $builder.ToString()
  }

  Add-Member -InputObject $link -MemberType ScriptMethod -Name Close -Value {
    if ($this.Closed) { return }
    $this.Closed = $true
    try { if ($this.Port.IsOpen) { $this.Port.Close() } } catch { }
    try { $this.Port.Dispose() } catch { }
  }

  return $link
}

# -----------------------------------------------------------------------------
#  Разбор строк прибора
# -----------------------------------------------------------------------------

function ConvertFrom-SineLine {
  <#
    Одна строка от прибора -> событие:
      ack       - ACK=<команда> (для уровней Name=A1…B2, Value=код);
      error     - ERR=<команда>[,<причина>], ERR=FORMAT, ERR IMAGE;
      state     - STATE=READY/SCAN/…;
      telemetry - Z=…,X=…;
      hello     - Hello from … / Hello! …;
      firmware  - Firmware 1.002;
      boot      - UPD … / R000064 / DONE (режим обновления ПО);
      text      - всё остальное.
    $null для пустой строки.
  #>
  param([string]$Line)
  if ($null -eq $Line) { return $null }
  $text = ([string]$Line).Trim()
  if (-not $text) { return $null }

  $event = [pscustomobject]@{
    Kind = 'text'; Text = $text; Name = $null; Value = $null;
    Reason = $null; State = $null; Z = $null; X = $null
  }

  # ACK=DA12048 / ACK=PL020 / ACK=CS
  $m = [regex]::Match($text, '^ACK=(?<cmd>[A-Z][A-Z0-9_+\-]*)$')
  if ($m.Success) {
    $cmd = $m.Groups['cmd'].Value
    $event.Kind = 'ack'
    $event.Name = $cmd
    $level = [regex]::Match($cmd, '^(?<prefix>DA1|DB1|DA2|DB2)(?<value>[0-9]{4})$')
    if ($level.Success) {
      $event.Name = $script:SinePrefixName[$level.Groups['prefix'].Value]
      $event.Value = [int]$level.Groups['value'].Value
    } else {
      $freq = [regex]::Match($cmd, '^F(?<value>[0-9]{5})$')
      $phase = [regex]::Match($cmd, '^PH(?<sign>[+-])(?<value>[0-9]{3})$')
      if ($freq.Success) {
        $event.Name = 'F'
        $event.Value = [int]$freq.Groups['value'].Value
      } elseif ($phase.Success) {
        $event.Name = 'PH'
        $value = [int]$phase.Groups['value'].Value
        if ($phase.Groups['sign'].Value -eq '-') { $value = -$value }
        $event.Value = $value
      }
    }
    return $event
  }

  # ERR=DA14096,RANGE / ERR=CS,BUSY / ERR=FORMAT
  $m = [regex]::Match($text, '^ERR=(?<cmd>[A-Z][A-Z0-9_+\-]*)(?:,(?<reason>[A-Z_]+))?$')
  if ($m.Success) {
    $cmd = $m.Groups['cmd'].Value
    $event.Kind = 'error'
    $event.Name = $cmd
    if ($m.Groups['reason'].Success) { $event.Reason = $m.Groups['reason'].Value }
    $level = [regex]::Match($cmd, '^(?<prefix>DA1|DB1|DA2|DB2)(?<value>[0-9]{4})$')
    if ($level.Success) {
      $event.Name = $script:SinePrefixName[$level.Groups['prefix'].Value]
      $event.Value = [int]$level.Groups['value'].Value
    } else {
      $freq = [regex]::Match($cmd, '^F(?<value>[0-9]{5})$')
      $phase = [regex]::Match($cmd, '^PH(?<sign>[+-])(?<value>[0-9]{3})$')
      if ($freq.Success) {
        $event.Name = 'F'
        $event.Value = [int]$freq.Groups['value'].Value
      } elseif ($phase.Success) {
        $event.Name = 'PH'
        $value = [int]$phase.Groups['value'].Value
        if ($phase.Groups['sign'].Value -eq '-') { $value = -$value }
        $event.Value = $value
      }
    }
    return $event
  }

  # ERR IMAGE (режим обновления ПО)
  $m = [regex]::Match($text, '^ERR\s+(?<reason>[A-Z_]+)$')
  if ($m.Success) {
    $event.Kind = 'error'
    $event.Reason = $m.Groups['reason'].Value
    return $event
  }

  $m = [regex]::Match($text, '^STATE=(?<state>HOMING|POSITIONING|READY|SCAN|RETURN|FAULT)$')
  if ($m.Success) {
    $event.Kind = 'state'
    $event.State = $m.Groups['state'].Value
    return $event
  }

  $m = [regex]::Match($text, '^Z=(?<z>-?[0-9]+),X=(?<x>NA|-?[0-9]+(?:\.[0-9]+)?)$')
  if ($m.Success) {
    $event.Kind = 'telemetry'
    $event.Z = [int]$m.Groups['z'].Value
    $event.X = $m.Groups['x'].Value
    return $event
  }

  $m = [regex]::Match($text, '^Hello from (?<name>.+)$')
  if ($m.Success) {
    $event.Kind = 'hello'
    $event.Name = $m.Groups['name'].Value.Trim()
    return $event
  }

  $m = [regex]::Match($text, '^Hello!\s*(?<note>.*)$')
  if ($m.Success) {
    $event.Kind = 'hello'
    $event.Name = $m.Groups['note'].Value.Trim()
    return $event
  }

  $m = [regex]::Match($text, '^Firmware\s+(?<version>[0-9A-Za-z.\-]+)$')
  if ($m.Success) {
    $event.Kind = 'firmware'
    $event.Name = $m.Groups['version'].Value
    return $event
  }

  if ($text -match '^UPD\b' -or $text -match '^R[0-9]{6}$' -or $text -eq 'DONE') {
    $event.Kind = 'boot'
    return $event
  }

  return $event
}

# -----------------------------------------------------------------------------
#  Сеанс связи с прибором
# -----------------------------------------------------------------------------

function New-SineSession {
  <#
    Сеанс поверх связи с методами Write/Drain/Close. Порт не открывает:
    это делает New-SineSerialLink или подставная связь в тестах.
  #>
  param([Parameter(Mandatory = $true)][object]$Link)

  return [pscustomobject]@{
    Link          = $Link
    Buffer        = New-Object System.Text.StringBuilder
    Acked         = @{ A1 = $null; B1 = $null; A2 = $null; B2 = $null; F = $null; PH = $null }
    Pending       = New-Object System.Collections.Generic.List[object]
    State         = $null
    Z             = $null
    X             = $null
    Hello         = $null
    Firmware      = $null
    LastRx        = $null
    Lines         = 0
    Telemetry     = 0
    Closed        = $false
  }
}

function Send-SineParam {
  <# Отправить одну команду (уровень, частоту или фазу) и помнить её до ACK. #>
  param(
    [Parameter(Mandatory = $true)][object]$Session,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$Value
  )
  if ($Session.Closed) { throw 'Сеанс закрыт' }

  $text = Format-SineCommand -Name $Name -Value $Value
  try {
    $Session.Link.Write($text)
  } catch {
    throw ('Не удалось отправить {0}: {1}' -f $text, $_.Exception.Message)
  }

  $Session.Pending.Add([pscustomobject]@{
    Text = $text; Name = $Name; Value = $Value; Time = [datetime]::UtcNow
  })
  return $text
}

function Complete-SinePending {
  <# Снять ожидание ответа по команде (после ACK или ERR). #>
  param([object]$Session, [string]$Text)
  for ($i = 0; $i -lt $Session.Pending.Count; $i++) {
    if ($Session.Pending[$i].Text -eq $Text) {
      $Session.Pending.RemoveAt($i)
      return $true
    }
  }
  return $false
}

function Receive-SineEvents {
  <#
    Прочитать всё, что пришло, разобрать строки и вернуть массив событий.
    Команда без ответа дольше AckTimeoutMs даёт событие timeout.
  #>
  param(
    [Parameter(Mandatory = $true)][object]$Session,
    [int]$AckTimeoutMs = $script:SineAckTimeoutMs
  )

  $events = New-Object System.Collections.Generic.List[object]
  if ($Session.Closed) { return ,$events.ToArray() }

  $chunk = ''
  try { $chunk = [string]$Session.Link.Drain() } catch { $chunk = '' }

  if ($chunk) {
    [void]$Session.Buffer.Append($chunk)
    $text = $Session.Buffer.ToString()
    $parts = $text -split "`n"
    [void]$Session.Buffer.Clear()

    if (-not $text.EndsWith("`n")) {
      # Последний фрагмент строки ещё не дописан: оставляем его до следующего раза.
      if ($parts.Count -gt 0) { [void]$Session.Buffer.Append($parts[$parts.Count - 1]) }
      if ($parts.Count -le 1) { $parts = @() }
      else { $parts = $parts[0..($parts.Count - 2)] }
    }

    foreach ($part in $parts) {
      $line = $part.TrimEnd("`r").Trim()
      if (-not $line) { continue }

      $Session.Lines++
      $Session.LastRx = [datetime]::UtcNow
      $event = ConvertFrom-SineLine -Line $line
      if (-not $event) { continue }

      switch ($event.Kind) {
        'ack' {
          if ($event.Name -and $script:SineParamNames -contains $event.Name) {
            $Session.Acked[$event.Name] = $event.Value
            $text = Format-SineCommandText -Name $event.Name -Value $event.Value
            [void](Complete-SinePending -Session $Session -Text $text)
          }
        }
        'error' {
          if ($event.Name -and $script:SineParamNames -contains $event.Name) {
            $text = Format-SineCommandText -Name $event.Name -Value $event.Value
            [void](Complete-SinePending -Session $Session -Text $text)
          }
        }
        'state' { $Session.State = $event.State }
        'telemetry' { $Session.Z = $event.Z; $Session.X = $event.X; $Session.Telemetry++ }
        'hello' { $Session.Hello = $event.Name }
        'firmware' { $Session.Firmware = $event.Name }
      }

      $events.Add($event)
    }
  }

  # Защита от мусора без переводов строк.
  if ($Session.Buffer.Length -gt 16384) { [void]$Session.Buffer.Clear() }

  # Команды, на которые прибор так и не ответил.
  if ($Session.Pending.Count -gt 0) {
    $now = [datetime]::UtcNow
    $expired = @($Session.Pending | Where-Object { ($now - $_.Time).TotalMilliseconds -gt $AckTimeoutMs })
    foreach ($item in $expired) {
      [void]$Session.Pending.Remove($item)
      $events.Add([pscustomobject]@{
        Kind = 'timeout'; Text = $item.Text; Name = $item.Name; Value = $item.Value;
        Reason = $null; State = $null; Z = $null; X = $null
      })
    }
  }

  return ,$events.ToArray()
}

function Close-SineSession {
  <# Закрыть связь; повторный вызов безопасен. #>
  param([Parameter(Mandatory = $true)][object]$Session)
  if ($Session.Closed) { return }
  $Session.Closed = $true
  try { $Session.Link.Close() } catch { }
}

# -----------------------------------------------------------------------------
#  Модель синусоид
# -----------------------------------------------------------------------------

function Convert-SineCodeToVolts {
  <# Код ЦАП -> вольты при опорном напряжении Vref. #>
  param([double]$Code, [double]$Vref = 3.3)
  if ($Vref -le 0) { return $null }
  return $Vref * $Code / 4095.0
}

function Get-SineTable {
  <# Таблица синуса 32 точки из Core/Src/dac_sine.c (единицы 1/32767). #>
  return @(
      0,  6393, 12539, 18204, 23170, 27245, 30273, 32137,
    32767, 32137, 30273, 27245, 23170, 18204, 12539,  6393,
      0, -6393,-12539,-18204,-23170,-27245,-30273,-32137,
    -32767,-32137,-30273,-27245,-23170,-18204,-12539, -6393
  )
}

function Get-SineWaveform {
  <#
    Период ЦАП так, как его считает прошивка:
      код = clamp(A + Sign * B * sine[i] / 32767), деление с усечением.
    Sign = 1 для ЦАП1, -1 для ЦАП2. Points кратно 32 повторяет период.
  #>
  param(
    [int]$Offset = 2048,
    [int]$Amplitude = 1000,
    [ValidateSet(1, -1)][int]$Sign = 1,
    [int]$Points = 32
  )
  if ($Points -lt 1) { throw 'Points должен быть не меньше 1' }

  $table = Get-SineTable
  $result = New-Object 'int[]' $Points
  for ($i = 0; $i -lt $Points; $i++) {
    $sample = [int]$table[$i % 32]
    $delta = [int][math]::Truncate(($Amplitude * $sample) / 32767.0)
    $value = $Offset + $Sign * $delta
    if ($value -lt $script:SineCodeMin) { $value = $script:SineCodeMin }
    if ($value -gt $script:SineCodeMax) { $value = $script:SineCodeMax }
    $result[$i] = $value
  }
  return ,$result
}

function Get-SineSummary {
  <#
    Следствия из четырёх уровней для подписей и предпросмотра:
      Code1Min/Code1Max - что реально выйдет на ЦАП1 (с ограничением 0…4095);
      Raw1Min/Raw1Max   - что просили (может выходить за пределы);
      Clip1/Clip2       - сигнал ограничивается;
      DiffAmplitude     - амплитуда ЦАП1 − ЦАП2 с учётом фазы:
      DiffOffset        - смещение ЦАП1 − ЦАП2 = A1 − A2.
    Вольты считаются по Vref; при Vref <= 0 они $null.
  #>
  param(
    [double]$A1 = 2048, [double]$B1 = 1000,
    [double]$A2 = 2048, [double]$B2 = 1000,
    [double]$Vref = 3.3, [double]$Frequency = 8000, [int]$PhaseTenths = 0
  )

  $raw1Min = $A1 - $B1; $raw1Max = $A1 + $B1
  $raw2Min = $A2 - $B2; $raw2Max = $A2 + $B2

  $clip1 = ($raw1Min -lt $script:SineCodeMin) -or ($raw1Max -gt $script:SineCodeMax)
  $clip2 = ($raw2Min -lt $script:SineCodeMin) -or ($raw2Max -gt $script:SineCodeMax)

  $code1Min = [math]::Max($script:SineCodeMin, $raw1Min)
  $code1Max = [math]::Min($script:SineCodeMax, $raw1Max)
  $code2Min = [math]::Max($script:SineCodeMin, $raw2Min)
  $code2Max = [math]::Min($script:SineCodeMax, $raw2Max)

  $phaseRad = [math]::PI * $PhaseTenths / 1800.0
  $diffAmplitude = [math]::Sqrt(($B1 * $B1) + ($B2 * $B2) + (2.0 * $B1 * $B2 * [math]::Cos($phaseRad)))
  $diffOffset = $A1 - $A2

  return [pscustomobject]@{
    A1 = $A1; B1 = $B1; A2 = $A2; B2 = $B2; Vref = $Vref
    Frequency = $Frequency; PhaseTenths = $PhaseTenths
    Raw1Min = $raw1Min; Raw1Max = $raw1Max
    Raw2Min = $raw2Min; Raw2Max = $raw2Max
    Code1Min = $code1Min; Code1Max = $code1Max
    Code2Min = $code2Min; Code2Max = $code2Max
    Clip1 = $clip1; Clip2 = $clip2; HasClip = ($clip1 -or $clip2)
    DiffAmplitude = $diffAmplitude; DiffOffset = $diffOffset
    V1Offset = (Convert-SineCodeToVolts -Code $A1 -Vref $Vref)
    V2Offset = (Convert-SineCodeToVolts -Code $A2 -Vref $Vref)
    V1Min = (Convert-SineCodeToVolts -Code $code1Min -Vref $Vref)
    V1Max = (Convert-SineCodeToVolts -Code $code1Max -Vref $Vref)
    V2Min = (Convert-SineCodeToVolts -Code $code2Min -Vref $Vref)
    V2Max = (Convert-SineCodeToVolts -Code $code2Max -Vref $Vref)
    VDiffAmplitude = (Convert-SineCodeToVolts -Code $diffAmplitude -Vref $Vref)
    VDiffOffset = (Convert-SineCodeToVolts -Code $diffOffset -Vref $Vref)
  }
}

# -----------------------------------------------------------------------------
#  Настройки между запусками
# -----------------------------------------------------------------------------

function Read-SineSettings {
  <# Последний порт, VREF, уровни, частота и фаза. Ошибки чтения -> значения по умолчанию. #>
  $settings = [pscustomobject]@{
    Port   = $null
    Vref   = 3.3
    Levels = (Get-SineDefaults)
  }

  try {
    if (Test-Path -LiteralPath $script:SineSettingsPath) {
      $text = [System.IO.File]::ReadAllText($script:SineSettingsPath, [System.Text.Encoding]::UTF8)
      $data = $text | ConvertFrom-Json
      $names = $data.PSObject.Properties.Name

      if ($names -contains 'port' -and $data.port) { $settings.Port = [string]$data.port }
      if ($names -contains 'vref') {
        $vref = [double]$data.vref
        if ($vref -ge 0 -and $vref -le 20) { $settings.Vref = $vref }
      }
      foreach ($name in $script:SineParamNames) {
        $key = $name.ToLowerInvariant()
        if ($names -contains $key) {
          $value = [int]$data.$key
          $ok = $true
          if ($name -eq 'F') {
            $ok = ($value -ge $script:SineFreqMin -and $value -le $script:SineFreqMax)
          } elseif ($name -eq 'PH') {
            $ok = ($value -ge -$script:SinePhaseMax -and $value -le $script:SinePhaseMax)
          } else {
            $ok = ($value -ge $script:SineCodeMin -and $value -le $script:SineCodeMax)
          }
          if ($ok) { $settings.Levels[$name] = $value }
        }
      }
    }
  } catch { }

  return $settings
}

function Save-SineSettings {
  <# Сохранить последний порт, VREF, уровни, частоту и фазу; ошибки записи игнорируются. #>
  param(
    [string]$Port,
    [double]$Vref = 3.3, [double]$Frequency = 8000, [int]$PhaseTenths = 0,
    [hashtable]$Levels
  )
  try {
    if (-not $Levels) { $Levels = Get-SineDefaults }
    $data = [ordered]@{
      port = $Port
      vref = [math]::Round($Vref, 3)
      a1   = [int]$Levels['A1']
      b1   = [int]$Levels['B1']
      a2   = [int]$Levels['A2']
      b2   = [int]$Levels['B2']
      f    = [int]$Frequency
      ph   = [int]$PhaseTenths
    }
    $folder = Split-Path $script:SineSettingsPath -Parent
    if ($folder -and -not [System.IO.Directory]::Exists($folder)) {
      [void][System.IO.Directory]::CreateDirectory($folder)
    }
    $json = $data | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($script:SineSettingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
  } catch { }
}
