# =============================================================================
#  upload-core.ps1 - ядро обновления ПО прибора по COM-порту, без интерфейса.
#
#  Файл подключается через точку (dot-source) из:
#    - tools/FirmwareUploader.ps1  - прошивальщик с окном;
#    - tools/upload-com.ps1        - консольный скрипт;
#    - tests/test_upload_core.ps1  - тесты с подставным прибором.
#
#  Обмен повторяет протокол из docs/USB_PROTOCOL.md и Core/Src/firmware_update.c:
#    ПК -> BT            прибор: ACK=BT, затем UPD READY (область загрузки стёрта)
#    ПК -> строки HEX    прибор: каждые 64 записи "R000064"
#    ПК -> GO            прибор: DONE (образ принят, перезапуск) либо ERR/ERR IMAGE
#    ПК -> ID            прибор: UPD <версия> (только в режиме загрузки)
#
#  Ядро ничего не печатает само: весь вывод идёт через подписки OnLog/OnProgress,
#  поэтому один и тот же код обслуживает окно, консоль и тесты.
# =============================================================================

# Раскладка флеша прибора (STM32F373C8TX_FLASH.ld, README.md):
# приложение 0x08000000..0x080077FF (30 КБ, страницы 0..14), копировщик - страница
# 15 (0x08007800, обновлением не перезаписывается), область загрузки 0x08008000.
$script:UploadAppBase          = [uint32]0x08000000
$script:UploadAppSize          = 30720             # 30 КБ: больше приложению нельзя
$script:UploadBaudRate         = 115200             # USB CDC: значение справочное
$script:UploadVidPid           = 'VID_0483&PID_5740' # STM32 virtual COM port
$script:UploadRecordsPerReport = 64                 # как часто прибор шлёт R******
$script:UploadCancelMarker     = 'UPLOAD-CANCELLED'
$script:UploadHexMaxRecord     = 64                 # HEX_LINE_MAX_DATA в hex_line.h

# -----------------------------------------------------------------------------
#  COM-порты
# -----------------------------------------------------------------------------

function Get-UploadComPorts {
  <# Имена всех последовательных портов, которые видит Windows. #>
  try { return @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) }
  catch { return @() }
}

function Find-UploadInstrumentPort {
  <# Найти COM-порт прибора по VID/PID. $null, если прибор не подключён. #>
  $result = $null

  # Основной путь: PnP-устройства класса Ports с нужным VID/PID.
  try {
    $dev = Get-PnpDevice -PresentOnly -Class Ports -ErrorAction Stop |
           Where-Object { $_.InstanceId -match [regex]::Escape($script:UploadVidPid) } |
           Select-Object -First 1
    if ($dev) {
      $m = [regex]::Match([string]$dev.FriendlyName, '\((COM\d+)\)')
      if ($m.Success) {
        $result = [pscustomobject]@{
          Port   = $m.Groups[1].Value
          Name   = [string]$dev.FriendlyName
          Status = [string]$dev.Status
        }
      }
    }
  } catch { }

  # Запасной путь 1: WMI/CIM, если модуль PnpDevice недоступен.
  if (-not $result) {
    try {
      $cim = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
             Where-Object { $_.DeviceID -match [regex]::Escape($script:UploadVidPid) } |
             Select-Object -First 1
      if ($cim) {
        $m = [regex]::Match([string]$cim.Name, '\((COM\d+)\)')
        if ($m.Success) {
          $result = [pscustomobject]@{
            Port   = $m.Groups[1].Value
            Name   = [string]$cim.Name
            Status = [string]$cim.Status
          }
        }
      }
    } catch { }
  }

  # Запасной путь 2: реестр. Нужен там, где PnP и WMI закрыты политикой или
  # недоступны (например, в ограниченной учётной записи). SERIALCOMM перечисляет
  # только живые порты, а ветка Enum\USB хранит привязку VID/PID к номеру порта.
  # В Enum остаются записи и от прежних подключений, поэтому пересечение с
  # SERIALCOMM обязательно: иначе можно попасть на давно несуществующий COM.
  if (-not $result) {
    try {
      $live = New-Object System.Collections.Generic.List[string]
      $map = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM' -ErrorAction Stop
      foreach ($property in $map.PSObject.Properties) {
        if ($property.Name.StartsWith('PS')) { continue }
        if ([string]$property.Value -match '^COM\d+$') { $live.Add([string]$property.Value) }
      }
      if ($live.Count -gt 0) {
        $enumKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\' + $script:UploadVidPid
        foreach ($instance in @(Get-ChildItem -LiteralPath $enumKey -ErrorAction Stop)) {
          $props = Get-ItemProperty -LiteralPath $instance.PSPath -ErrorAction SilentlyContinue
          $name = [string]$props.FriendlyName
          $m = [regex]::Match($name, '\((COM\d+)\)')
          if ($m.Success -and $live.Contains($m.Groups[1].Value)) {
            $result = [pscustomobject]@{
              Port   = $m.Groups[1].Value
              Name   = $name
              Status = 'OK'
            }
            break
          }
        }
      }
    } catch { }
  }

  return $result
}

function New-UploadSerialLink {
  <# Открыть COM-порт и вернуть объект связи с методами Write/ReadLines/Close. #>
  param(
    [Parameter(Mandatory = $true)][string]$PortName,
    [int]$ReadTimeoutMs = 150,
    [int]$WriteTimeoutMs = 10000
  )

  $port = New-Object System.IO.Ports.SerialPort $PortName, $script:UploadBaudRate, 'None', 8, 'One'
  $port.ReadTimeout  = $ReadTimeoutMs
  $port.WriteTimeout = $WriteTimeoutMs
  $port.NewLine      = "`r`n"
  $port.DtrEnable    = $true          # прибор по DTR шлёт "Hello! fw <версия>"
  try { $port.ReadBufferSize = 8192 } catch { }

  try {
    $port.Open()
  } catch {
    try { $port.Dispose() } catch { }
    throw ('Не удалось открыть порт {0}: {1}' -f $PortName, $_.Exception.Message)
  }

  $link = [pscustomobject]@{ PortName = $PortName; Port = $port; Closed = $false }

  Add-Member -InputObject $link -MemberType ScriptMethod -Name Write -Value {
    param([string]$Text)
    $this.Port.Write($Text)
  }

  # Читает строки, пока они есть, но не дольше Milliseconds.
  # `return ,$array` не даёт PowerShell развернуть массив в поток.
  Add-Member -InputObject $link -MemberType ScriptMethod -Name ReadLines -Value {
    param([int]$Milliseconds)

    $lines = New-Object System.Collections.Generic.List[string]
    $deadline = [datetime]::UtcNow.AddMilliseconds($Milliseconds)
    try {
      while ($true) {
        if (-not $this.Port.IsOpen) { break }
        if ($this.Port.BytesToRead -gt 0) {
          try { $lines.Add($this.Port.ReadLine()) } catch { }
          if ($lines.Count -ge 5000) { break }
          continue
        }
        if ([datetime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 5
      }
    } catch { }   # порт пропал (например, после GO): отдаём то, что успели
    return ,$lines.ToArray()
  }

  Add-Member -InputObject $link -MemberType ScriptMethod -Name Close -Value {
    if ($this.Closed) { return }
    $this.Closed = $true
    try { if ($this.Port -and $this.Port.IsOpen) { $this.Port.Close() } } catch { }
    try { if ($this.Port) { $this.Port.Dispose() } } catch { }
  }

  return $link
}

# -----------------------------------------------------------------------------
#  Записи Intel HEX
# -----------------------------------------------------------------------------

function ConvertFrom-UploadHexLine {
  <# Разобрать одну запись Intel HEX. $null - строка не является корректной записью. #>
  param([string]$Text)

  $t = $Text.Trim()
  if ($t.Length -lt 11 -or -not $t.StartsWith(':')) { return $null }

  $m = [regex]::Match($t, '^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})((?:[0-9A-Fa-f]{2})*)([0-9A-Fa-f]{2})$')
  if (-not $m.Success) { return $null }

  $count = [Convert]::ToInt32($m.Groups[1].Value, 16)
  $dataText = $m.Groups[4].Value
  if ($dataText.Length -ne 2 * $count) { return $null }

  $bytes = New-Object 'byte[]' ($count + 5)
  $bytes[0] = [byte]$count
  $bytes[1] = [Convert]::ToByte($m.Groups[2].Value.Substring(0, 2), 16)
  $bytes[2] = [Convert]::ToByte($m.Groups[2].Value.Substring(2, 2), 16)
  $bytes[3] = [Convert]::ToByte($m.Groups[3].Value, 16)
  $data = New-Object 'byte[]' $count
  for ($i = 0; $i -lt $count; $i++) {
    $value = [Convert]::ToByte($dataText.Substring(2 * $i, 2), 16)
    $bytes[4 + $i] = $value
    $data[$i] = $value
  }
  $bytes[4 + $count] = [Convert]::ToByte($m.Groups[5].Value, 16)

  $sum = 0
  foreach ($b in $bytes) { $sum = ($sum + $b) -band 0xFF }
  if ($sum -ne 0) { return $null }   # сумма всех байт строки вместе с CC равна нулю

  return [pscustomobject]@{
    Count   = $count
    Address = (([int]$bytes[1] -shl 8) -bor [int]$bytes[2])
    Type    = [int]$bytes[3]
    Data    = $data
  }
}

function New-UploadHexRecord {
  <# Собрать запись Intel HEX: :LLAAAATTDD..CC #>
  param(
    [int]$Address,
    [int]$Type,
    [byte[]]$Data = @()
  )

  $bytes = New-Object System.Collections.Generic.List[byte]
  $bytes.Add([byte]$Data.Count)
  $bytes.Add([byte](($Address -shr 8) -band 0xFF))
  $bytes.Add([byte]($Address -band 0xFF))
  $bytes.Add([byte]$Type)
  foreach ($b in $Data) { $bytes.Add([byte]$b) }

  $sum = 0
  foreach ($b in $bytes) { $sum = ($sum + $b) -band 0xFF }
  $bytes.Add([byte]((0x100 - $sum) -band 0xFF))

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append(':')
  foreach ($b in $bytes) { [void]$sb.Append($b.ToString('X2')) }
  return $sb.ToString()
}

# -----------------------------------------------------------------------------
#  Проверка файла прошивки
# -----------------------------------------------------------------------------

function Set-UploadVectorInfo {
  <# Проверить таблицу векторов так же, как Firmware_ImageLooksValid() на приборе. #>
  param($Plan, [byte[]]$Bytes, [int]$Offset)

  if ($null -eq $Bytes -or $Bytes.Length -lt ($Offset + 8)) {
    $Plan.Errors.Add('В файле нет таблицы векторов по адресу 0x08000000.')
    return
  }

  $stack = [BitConverter]::ToUInt32($Bytes, $Offset)
  $entry = [BitConverter]::ToUInt32($Bytes, $Offset + 4)
  $Plan.StackPointer = $stack
  $Plan.EntryPoint   = $entry

  if ($stack -lt [uint32]0x20000010 -or $stack -gt [uint32]0x20004000) {
    $Plan.Errors.Add(('Начальный стек 0x{0:X8} не похож на адрес в RAM (0x20000010..0x20004000).' -f $stack))
  }
  if ($entry -lt $script:UploadAppBase -or $entry -ge ($script:UploadAppBase + $script:UploadAppSize)) {
    $Plan.Errors.Add(('Вектор сброса 0x{0:X8} вне приложения 0x08000000..0x080077FF.' -f $entry))
  }
  if (($entry -band 1) -eq 0) {
    $Plan.Errors.Add(('Вектор сброса 0x{0:X8} без Thumb-бита: это не код Cortex-M.' -f $entry))
  }
}

function Get-UploadBinPlan {
  <# План заливки для готового .bin: оборачиваем его в записи HEX по 16 байт. #>
  param($Plan)

  $bytes = [System.IO.File]::ReadAllBytes($Plan.Path)
  $size = $bytes.Length

  if ($size -le 0) { $Plan.Errors.Add('Файл пуст.'); return }

  # objcopy собирает .bin вместе с копировщиком: за приложением (30 КБ) лежит
  # страница 0x08007800. Прибору нужны только первые 30 КБ, остальное не пишем.
  if ($size -gt $script:UploadAppSize) {
    $Plan.Warnings.Add(('Файл {0:N0} байт: за областью приложения лежит копировщик, заливаю первые {1:N0} байт (30 КБ).' -f $size, $script:UploadAppSize))
    $size = $script:UploadAppSize
  }

  # Прибор пишет только целые полуслова: нечётный хвост дополняем 0xFF (как стёртый флеш).
  if (($size % 2) -ne 0) {
    $Plan.Warnings.Add('Нечётный размер: последний байт дополнен до полуслова значением 0xFF.')
    $padded = New-Object 'byte[]' ($size + 1)
    [Array]::Copy($bytes, $padded, $size)
    $padded[$size] = [byte]0xFF
    $bytes = $padded
    $size += 1
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add((New-UploadHexRecord -Address 0 -Type 4 -Data ([byte[]](0x08, 0x00))))   # база 0x08000000

  $address = 0
  while ($address -lt $size) {
    $chunk = [Math]::Min(16, $size - $address)
    $slice = New-Object 'byte[]' $chunk
    [Array]::Copy($bytes, $address, $slice, 0, $chunk)
    $lines.Add((New-UploadHexRecord -Address $address -Type 0 -Data $slice))
    $Plan.DataRecords++
    $address += $chunk
  }
  $lines.Add((New-UploadHexRecord -Address 0 -Type 1 -Data @()))                      # конец файла

  $Plan.Lines        = $lines.ToArray()
  $Plan.HasEof       = $true
  $Plan.PayloadBytes = [long]$size
  $Plan.FirstAddress = $script:UploadAppBase
  $Plan.LastAddress  = $script:UploadAppBase + $size - 1

  $null = Set-UploadVectorInfo -Plan $Plan -Bytes $bytes -Offset 0
}

function Get-UploadHexPlan {
  <# План заливки для Intel HEX: строки отправляются прибору как есть. #>
  param($Plan)

  $text = [System.IO.File]::ReadAllText($Plan.Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($text)) { $Plan.Errors.Add('Файл пуст.'); return }

  $raw = @([regex]::Split($text, "`r`n|`n|`r") | Where-Object { $_.Trim().Length -gt 0 })
  if ($raw.Count -eq 0) { $Plan.Errors.Add('В файле нет строк.'); return }

  $send = New-Object System.Collections.Generic.List[string]
  $vectorBytes = New-Object 'byte[]' 8
  $vectorFilled = New-Object 'bool[]' 8
  $extended = [uint32]0
  $firstAddress = $null
  $lastAddress  = $null
  $lineNumber = 0
  $badLines = 0

  foreach ($rawLine in $raw) {
    $lineNumber++
    $line = $rawLine.Trim()
    $record = ConvertFrom-UploadHexLine -Text $line
    if (-not $record) {
      $badLines++
      if ($badLines -le 5) {
        $Plan.Errors.Add(('Строка {0}: не запись Intel HEX или неверная контрольная сумма.' -f $lineNumber))
      }
      continue
    }

    if ($record.Count -gt $script:UploadHexMaxRecord) {
      $Plan.Errors.Add(('Строка {0}: {1} байт данных в записи, прибор принимает не больше {2}.' -f $lineNumber, $record.Count, $script:UploadHexMaxRecord))
    }

    switch ($record.Type) {
      4 {
        if ($record.Count -ne 2 -or $record.Address -ne 0) {
          $Plan.Errors.Add(('Строка {0}: запись старшего адреса должна быть :02000004XXXX.' -f $lineNumber))
        } else {
          $extended = [uint32](([uint64]$record.Data[0] -shl 24) -bor ([uint64]$record.Data[1] -shl 16))
        }
      }
      1 {
        if ($record.Count -ne 0 -or $record.Address -ne 0) {
          $Plan.Errors.Add(('Строка {0}: запись конца файла должна быть :00000001FF.' -f $lineNumber))
        } else {
          $Plan.HasEof = $true
        }
      }
      0 {
        $absolute = [uint64]$extended + [uint64]$record.Address
        if ($absolute -ge [uint64]$script:UploadAppBase) {
          $offset = [uint64]($absolute - [uint64]$script:UploadAppBase)
          if ($offset -lt [uint64]$script:UploadAppSize) {
            if (($offset + [uint64]$record.Count) -gt [uint64]$script:UploadAppSize) {
              $Plan.Errors.Add(('Строка {0}: данные по адресу 0x{1:X8} выходят за 30 КБ приложения.' -f $lineNumber, $absolute))
            } else {
              $Plan.DataRecords++
              $Plan.PayloadBytes += [long]$record.Count
              if ($null -eq $firstAddress -or $absolute -lt $firstAddress) { $firstAddress = $absolute }
              if ($null -eq $lastAddress -or ($absolute + [uint64]$record.Count - 1) -gt $lastAddress) { $lastAddress = $absolute + [uint64]$record.Count - 1 }
              for ($i = 0; $i -lt $record.Count; $i++) {
                $target = [int]($offset + $i)
                if ($target -lt 8) {
                  $vectorBytes[$target] = $record.Data[$i]
                  $vectorFilled[$target] = $true
                }
              }
            }
          } else {
            # Адреса от 30 КБ - это копировщик (0x08007800) или служебные записи.
            # Прибор их пропускает без ошибки, поэтому отправляем, но не считаем.
            $Plan.SkippedRecords++
          }
        } else {
          $Plan.SkippedRecords++
        }
      }
      default {
        if ($record.Type -eq 2 -or $record.Type -eq 3) {
          $Plan.Warnings.Add(('Строка {0}: запись типа 0{1} прибором не поддерживается.' -f $lineNumber, $record.Type))
        }
      }
    }

    $send.Add($line)
  }

  if ($badLines -gt 5) {
    $Plan.Errors.Add(('Всего некорректных строк: {0}.' -f $badLines))
  }
  if (-not $Plan.HasEof) {
    $Plan.Errors.Add('Нет записи конца файла (:00000001FF): прибор отклонит образ при GO.')
  }
  if ($Plan.DataRecords -eq 0) {
    $Plan.Errors.Add('Нет данных в области приложения 0x08000000..0x080077FF.')
  }

  $Plan.Lines = $send.ToArray()
  if ($null -ne $firstAddress) { $Plan.FirstAddress = [uint32]$firstAddress }
  if ($null -ne $lastAddress)  { $Plan.LastAddress  = [uint32]$lastAddress  }

  $allFilled = $true
  foreach ($filled in $vectorFilled) { if (-not $filled) { $allFilled = $false } }
  if ($allFilled) {
    $null = Set-UploadVectorInfo -Plan $Plan -Bytes $vectorBytes -Offset 0
  } elseif ($Plan.DataRecords -gt 0) {
    $Plan.Errors.Add('В файле нет данных начала приложения (0x08000000): не удаётся проверить таблицу векторов.')
  }
}

function Get-UploadFirmwarePlan {
  <#
    Разобрать и проверить файл прошивки (.hex или .bin).
    Возвращает объект: Lines (что отправлять), DataRecords, PayloadBytes, Errors,
    Warnings, IsValid. Проверки повторяют приёмник прибора, поэтому заведомо
    непригодный файл отсекается до отправки BT.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$Path)

  $plan = [pscustomobject]@{
    Path           = $Path
    FileName       = [System.IO.Path]::GetFileName($Path)
    Kind           = $null
    Lines          = @()
    DataRecords    = 0
    SkippedRecords = 0
    PayloadBytes   = [long]0
    FirstAddress   = $null
    LastAddress    = $null
    HasEof         = $false
    StackPointer   = $null
    EntryPoint     = $null
    Sha256         = $null
    Errors         = New-Object System.Collections.Generic.List[string]
    Warnings       = New-Object System.Collections.Generic.List[string]
    IsValid        = $false
  }

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $plan.Errors.Add(('Файл не найден: {0}' -f $Path))
    return $plan
  }

  try {
    $plan.Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  } catch { }

  $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($extension -eq '.bin') { $plan.Kind = 'bin' }
  elseif ($extension -eq '.hex' -or $extension -eq '.ihex') { $plan.Kind = 'hex' }

  try {
    if (-not $plan.Kind) {
      # Незнакомое расширение: смотрим содержимое.
      $head = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart()
      if ($head.StartsWith(':')) { $plan.Kind = 'hex' } else { $plan.Kind = 'bin' }
    }

    if ($plan.Kind -eq 'bin') { $null = Get-UploadBinPlan -Plan $plan }
    else { $null = Get-UploadHexPlan -Plan $plan }
  } catch {
    $plan.Errors.Add(('Не удалось разобрать файл: {0}' -f $_.Exception.Message))
  }

  $plan.IsValid = ($plan.Errors.Count -eq 0)
  return $plan
}

# -----------------------------------------------------------------------------
#  Служебные функции обмена
# -----------------------------------------------------------------------------

function Get-UploadLineKind {
  <# Классификация строки от прибора. #>
  param([string]$Line)

  if ($Line -match '^Z=')                 { return 'telemetry' }
  if ($Line -match '^Hello!')             { return 'hello' }
  if ($Line -match '^STATE=')             { return 'state' }
  if ($Line -match '^R\d+$')              { return 'progress' }
  if ($Line -match '^UPD\s+READY')        { return 'ready' }
  if ($Line -match '^UPD\s+TIMEOUT')      { return 'timeout' }
  if ($Line -match '^UPD\s+ERASE_ERR')    { return 'erase' }
  if ($Line -match '^UPD\s+(\S+)')        { return 'version' }
  if ($Line -match '^DONE')               { return 'done' }
  if ($Line -match '^ERR')                { return 'error' }
  if ($Line -match '^ACK=')               { return 'ack' }
  return 'other'
}

function Write-UploadLog {
  <# Отправить строку подписчику журнала (если он есть). #>
  param([hashtable]$Context, [string]$Text)

  if ($null -eq $Text) { return }
  $Context.Log.Add($Text)
  # Вывод подписки гасим: иначе, если подписка что-то возвращает (например,
  # Write-Host с аргументами или строку), это значение попало бы в разбор
  # ответов прибора и было бы принято за сигнал протокола.
  if ($Context.OnLog) { [void](& $Context.OnLog $Text) }
}

function Set-UploadStage {
  <# Обновить этап и процент, не давая полосе идти назад. #>
  param([hashtable]$Context, [int]$Percent, [string]$Stage, [string]$Detail)

  if ($Percent -lt $Context.Percent) { $Percent = $Context.Percent }
  if ($Percent -gt 100) { $Percent = 100 }
  if ($Percent -lt 0) { $Percent = 0 }
  $Context.Percent = $Percent
  $Context.Stage = $Stage
  $Context.Detail = $Detail
  # Вывод подписки гасим, чтобы он не попал в результат работы ядра.
  if ($Context.OnProgress) { [void](& $Context.OnProgress $Percent $Stage $Detail) }
}

function Add-UploadDeviceLine {
  <# Показать строку прибора в журнале, свернув поток телеметрии. #>
  param([hashtable]$Context, [string]$Line)

  $kind = Get-UploadLineKind $Line
  if ($kind -eq 'telemetry') {
    $Context.TelemetryCount++
    $Context.Telemetry = $Line
    if ($Context.TelemetryCount -eq 1 -or ($Context.TelemetryCount % 200) -eq 0) {
      Write-UploadLog $Context ('  телеметрия: {0}' -f $Line)
    }
    return
  }
  if ($kind -eq 'progress') {
    $Context.DeviceRecords = [int]$Line.Substring(1)
    Write-UploadLog $Context ('  прибор принял записей: {0}' -f $Context.DeviceRecords)
    return
  }
  Write-UploadLog $Context ('  {0}' -f $Line)
}

function Wait-UploadSignal {
  <#
    Читать строки прибора, пока обработчик не вернёт сигнал (строку) или не истечёт
    время. Возвращает сигнал либо $null по тайм-ауту. Pump вызывается каждый цикл,
    чтобы окно успевало перерисоваться и кнопка «Отменить» работала во время
    ожидания.
  #>
  param(
    [object]$Link,
    [int]$TimeoutMs,
    [scriptblock]$OnLine,
    [scriptblock]$Pump
  )

  $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ($true) {
    foreach ($line in $Link.ReadLines(120)) {
      if ($null -eq $line) { continue }
      $text = $line.Trim()
      if ($text.Length -eq 0) { continue }
      # Обработчик возвращает сигнал протокола; любое другое значение означает
      # «продолжай». Его собственный журнальный вывод гасится самим обработчиком.
      $signal = & $OnLine $text
      if ($null -ne $signal -and "$signal".Length -gt 0) { return $signal }
    }
    if ($Pump) { [void](& $Pump) }
    if ([datetime]::UtcNow -ge $deadline) { return $null }
  }
}

# -----------------------------------------------------------------------------
#  Основная операция: залить прошивку
# -----------------------------------------------------------------------------

function Invoke-FirmwareUpload {
  <#
    Залить прошивку в прибор по COM-порту.

    Параметры:
      Plan             - результат Get-UploadFirmwarePlan;
      PortName         - имя порта (COM7). Если не задано, порт ищется по VID/PID;
      Transport        - готовая связь (тесты); иначе открывается новая;
      TransportFactory - скриптблок, создающий связь вместо New-UploadSerialLink;
      Options          - тайм-ауты в секундах: ReadyTimeoutSec (ожидание
                         UPD READY), SendTimeoutSec (передача файла),
                         GoTimeoutSec (ожидание DONE), VerifyTimeoutSec (сколько
                         ждать телеметрию после перезапуска), VerifyDelaySec
                         (пауза перед первой попыткой), SkipVerify - не проверять
                         телеметрию вовсе;
      OnProgress       - { param($percent, $stage, $detail) } для полосы и статусов;
      OnLog            - { param($text) } для журнала;
      ShouldStop       - возвращает $true, если работу нужно прервать.

    Возвращает объект результата: Success, Cancelled, Message, Percent, Verified,
    DeviceRecords, VersionBefore, VersionAfter, Telemetry, DurationMs.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [string]$PortName,
    [object]$Transport,
    [scriptblock]$TransportFactory,
    [hashtable]$Options = @{},
    [scriptblock]$OnProgress,
    [scriptblock]$OnLog,
    [scriptblock]$ShouldStop
  )

  $opt = @{
    ReadyTimeoutSec  = 20
    SendTimeoutSec   = 240
    GoTimeoutSec     = 90
    VerifyTimeoutSec = 45
    VerifyDelaySec   = 3
    SkipVerify       = $false
  }
  if ($Options) { foreach ($key in $Options.Keys) { $opt[$key] = $Options[$key] } }

  # Мутабельное состояние: его меняют и вложенные скриптблоки-обработчики.
  $context = @{
    Percent        = 0
    Stage          = ''
    Detail         = ''
    OnLog          = $OnLog
    OnProgress     = $OnProgress
    Log            = New-Object System.Collections.Generic.List[string]
    DeviceRecords  = 0
    Telemetry      = $null
    TelemetryCount = 0
    VersionBefore  = $null
    VersionAfter   = $null
    Verified       = $false
    VerifiedPort   = $null
  }

  $result = [pscustomobject]@{
    Success       = $false
    Cancelled     = $false
    Message       = ''
    Percent       = 0
    DataRecords   = 0
    DeviceRecords = 0
    Verified      = $false
    Telemetry     = $null
    VersionBefore = $null
    VersionAfter  = $null
    DurationMs    = 0
    Log           = @()
  }

  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $link = $Transport
  $openedHere = $false

  # Без подписки ShouldStop работа не прерывается.
  $checkStop = {
    if ($ShouldStop -and (& $ShouldStop)) { throw $script:UploadCancelMarker }
  }

  try {
    if (-not $Plan) { throw 'Файл прошивки не выбран.' }
    if (-not $Plan.IsValid) { throw ('Файл прошивки не подходит: ' + (@($Plan.Errors) -join ' ')) }

    $lines = @($Plan.Lines)
    if ($lines.Count -eq 0) { throw 'В файле прошивки нет строк для отправки.' }

    Set-UploadStage $context 1 'Проверка файла' ('{0}: {1} записей, {2:N0} байт' -f $Plan.FileName, $Plan.DataRecords, $Plan.PayloadBytes)
    Write-UploadLog $context ('Файл: {0} ({1}, {2:N0} байт данных)' -f $Plan.FileName, $Plan.Kind.ToUpperInvariant(), $Plan.PayloadBytes)
    Write-UploadLog $context ('Строк для отправки: {0}, записей в области приложения: {1}' -f $lines.Count, $Plan.DataRecords)
    if ($null -ne $Plan.FirstAddress -and $null -ne $Plan.LastAddress) {
      Write-UploadLog $context ('Адреса: 0x{0:X8}..0x{1:X8}' -f $Plan.FirstAddress, $Plan.LastAddress)
    }
    if ($Plan.Sha256) { Write-UploadLog $context ('SHA256: {0}' -f $Plan.Sha256) }
    if ($Plan.SkippedRecords -gt 0) {
      Write-UploadLog $context ('Записей вне области приложения (копировщик): {0} - прибор их пропускает' -f $Plan.SkippedRecords)
    }
    foreach ($warning in $Plan.Warnings) { Write-UploadLog $context ('Внимание: ' + $warning) }

    # --- Порт -------------------------------------------------------------
    if (-not $link) {
      Set-UploadStage $context 3 'Поиск прибора' 'ищу COM-порт STM32 (VID_0483:PID_5740)'
      if (-not $PortName) {
        $found = Find-UploadInstrumentPort
        if (-not $found) {
          $available = Get-UploadComPorts
          if ($available.Count -gt 0) { $hint = 'Доступные порты: ' + ($available -join ', ') + '.' }
          else { $hint = 'Последовательных портов в системе нет.' }
          throw ('COM-порт прибора не найден (VID_0483:PID_5740). Подключите USB платы. ' + $hint)
        }
        $PortName = $found.Port
        Write-UploadLog $context ('Найден прибор: {0}' -f $found.Name)
      }
      Set-UploadStage $context 4 ('Открытие порта {0}' -f $PortName) '115200, 8N1'
      if ($TransportFactory) { $link = & $TransportFactory $PortName }
      else { $link = New-UploadSerialLink -PortName $PortName }
      $openedHere = $true
      Write-UploadLog $context ('Порт открыт: {0}' -f $PortName)
    } else {
      $PortName = $link.PortName
      Write-UploadLog $context ('Использую готовую связь: {0}' -f $PortName)
    }

    & $checkStop

    # --- Что уже на приборе? ---------------------------------------------
    Set-UploadStage $context 6 'Проверка связи с прибором' 'запрос ID'
    $link.Write("ID`r`n")
    $inUploadMode = $false
    foreach ($line in $link.ReadLines(400)) {
      if ($null -eq $line) { continue }
      $text = $line.Trim()
      if ($text.Length -eq 0) { continue }
      Add-UploadDeviceLine $context $text
      if ($text -match '^Hello!\s+fw\s+(\S+)') { $context.VersionBefore = $Matches[1] }
      elseif ($text -match '^UPD\s+(\S+)') {
        $inUploadMode = $true
        $context.VersionBefore = $Matches[1]
      }
    }
    if ($context.VersionBefore) {
      Write-UploadLog $context ('Версия на приборе: {0}' -f $context.VersionBefore)
    }

    & $checkStop

    # --- BT: прибор стирает область загрузки -------------------------------
    if ($inUploadMode) {
      Write-UploadLog $context 'Прибор уже в режиме загрузки: начинаю чистую повторную попытку.'
    }
    Set-UploadStage $context 8 'Перевод прибора в режим загрузки' 'команда BT, стирание области загрузки'
    $link.Write("BT`r`n")

    $readyMs = [int]$opt.ReadyTimeoutSec * 1000
    $btStarted = [datetime]::UtcNow
    $signal = Wait-UploadSignal -Link $link -TimeoutMs $readyMs -OnLine {
      param($line)
      $kind = Get-UploadLineKind $line
      if ($kind -eq 'ready')   { return 'ready' }
      if ($kind -eq 'timeout') { return 'timeout' }
      if ($kind -eq 'erase')   { return 'erase' }
      if ($kind -eq 'error')   { return ('error:' + $line) }
      if ($kind -eq 'version') {
        if ($line -match '^UPD\s+(\S+)') { $context.VersionBefore = $Matches[1] }
        return $null
      }
      if ($kind -eq 'telemetry') { $context.TelemetryCount++; $context.Telemetry = $line; return $null }
      Write-UploadLog $context ('  ' + $line)
      return $null
    } -Pump {
      $elapsed = [int]([datetime]::UtcNow - $btStarted).TotalSeconds
      Set-UploadStage $context 8 'Перевод прибора в режим загрузки' ('стирание области загрузки, {0} из {1} с' -f $elapsed, $opt.ReadyTimeoutSec)
    }

    if ($signal -eq 'ready') {
      Write-UploadLog $context 'Область загрузки стёрта, прибор готов принимать файл.'
    } elseif ($signal -eq 'timeout') {
      throw 'Прибор ответил UPD TIMEOUT: он не дождался данных и вышел из режима загрузки.'
    } elseif ($signal -eq 'erase') {
      throw 'Прибор ответил UPD ERASE_ERR: не удалось стереть область загрузки.'
    } elseif ($null -eq $signal) {
      throw ('Не дождался UPD READY за {0} с: прибор не вошёл в режим загрузки. Проверьте, что он в READY (не сканирует), и повторите.' -f $opt.ReadyTimeoutSec)
    } elseif ($signal -like 'error:*') {
      $text = $signal.Substring(6)
      if ($text -match 'BUSY') {
        throw ('Прибор отклонил BT (' + $text + '): он занят - идёт сканирование или позиционирование. Дождитесь STATE=READY или остановите сканирование командой CC и повторите.')
      }
      if ($text -match 'FAULT') {
        throw ('Прибор отклонил BT (' + $text + '): прибор в состоянии ошибки, движение выключено. Восстановление - перезапуск прибора.')
      }
      throw ('Прибор отклонил BT: ' + $text)
    } else {
      throw ('Неожиданный ответ прибора: ' + $signal)
    }

    # --- Передача файла ----------------------------------------------------
    $total = $lines.Count
    $chunkSize = 8
    $sendDeadline = [datetime]::UtcNow.AddSeconds([int]$opt.SendTimeoutSec)
    $sent = 0
    Set-UploadStage $context 12 'Передача прошивки' ('0 из {0} строк' -f $total)

    for ($index = 0; $index -lt $total; $index += $chunkSize) {
      $last = [Math]::Min($index + $chunkSize, $total) - 1
      $builder = New-Object System.Text.StringBuilder
      for ($i = $index; $i -le $last; $i++) { [void]$builder.Append($lines[$i]).Append("`r`n") }
      $link.Write($builder.ToString())
      $sent = $last + 1

      foreach ($line in $link.ReadLines(0)) {
        if ($null -eq $line) { continue }
        $text = $line.Trim()
        if ($text.Length -eq 0) { continue }
        $kind = Get-UploadLineKind $text
        if ($kind -eq 'error') { throw ('Прибор сообщил об ошибке приёма: ' + $text) }
        if ($kind -eq 'timeout') { throw 'Прибор ответил UPD TIMEOUT: приём прерван по тайм-ауту.' }
        if ($kind -eq 'telemetry') { $context.TelemetryCount++; continue }
        Add-UploadDeviceLine $context $text
      }

      $percent = 12 + [int][math]::Floor(76.0 * $sent / $total)
      $detail = '{0} из {1} строк, прибор принял записей: {2}' -f $sent, $total, $context.DeviceRecords
      Set-UploadStage $context $percent 'Передача прошивки' $detail

      & $checkStop
      if ([datetime]::UtcNow -gt $sendDeadline) {
        throw ('Превышено время передачи файла ({0} с): прибор не принимает данные.' -f $opt.SendTimeoutSec)
      }
    }

    # --- Итог приёма перед GO ---------------------------------------------
    Set-UploadStage $context 89 'Проверка принятого файла' ('передано строк: {0}' -f $sent)
    $expected = [int]$Plan.DataRecords
    $enough = $expected - $script:UploadRecordsPerReport
    $drainUntil = [datetime]::UtcNow.AddSeconds(4)
    while ([datetime]::UtcNow -lt $drainUntil) {
      if ($context.DeviceRecords -ge $enough) { break }
      $got = @($link.ReadLines(100))
      if ($got.Count -eq 0) { continue }
      foreach ($line in $got) {
        if ($null -eq $line) { continue }
        $text = $line.Trim()
        if ($text.Length -eq 0) { continue }
        $kind = Get-UploadLineKind $text
        if ($kind -eq 'error') { throw ('Прибор сообщил об ошибке приёма: ' + $text) }
        if ($kind -eq 'telemetry') { $context.TelemetryCount++; continue }
        Add-UploadDeviceLine $context $text
      }
      if ($context.DeviceRecords -ge $enough) { break }
    }
    if ($expected -ge $script:UploadRecordsPerReport) {
      if ($context.DeviceRecords -le 0) {
        Write-UploadLog $context 'Внимание: прибор ни разу не подтвердил приём записей (R******). Продолжаю: решение примет GO.'
      } else {
        # Счётчик прибора идёт кратно 64, поэтому последнее значение меньше общего числа записей.
        Write-UploadLog $context ('Прибор подтвердил приём: счётчик дошёл до {0} записей (счётчик кратен {1}, всего {2}).' -f $context.DeviceRecords, $script:UploadRecordsPerReport, $expected)
      }
    }

    & $checkStop

    # --- GO: прибор проверяет образ и перезапускается ----------------------
    Set-UploadStage $context 91 'Установка прошивки' 'команда GO: сумма, маркер, перезапуск'
    $link.Write("GO`r`n")

    $goMs = [int]$opt.GoTimeoutSec * 1000
    $goStarted = [datetime]::UtcNow
    $signal = Wait-UploadSignal -Link $link -TimeoutMs $goMs -OnLine {
      param($line)
      $kind = Get-UploadLineKind $line
      if ($kind -eq 'done')    { return 'done' }
      if ($kind -eq 'error')   { return ('error:' + $line) }
      if ($kind -eq 'timeout') { return 'timeout' }
      Add-UploadDeviceLine $context $line
      return $null
    } -Pump {
      $elapsed = [int]([datetime]::UtcNow - $goStarted).TotalSeconds
      Set-UploadStage $context 91 'Установка прошивки' ('прибор считает сумму образа, {0} с' -f $elapsed)
    }

    if ($null -eq $signal) {
      throw ('Не дождался ответа DONE за {0} с. Прибор, скорее всего, не принял образ: повторите заливку.' -f $opt.GoTimeoutSec)
    }
    if ($signal -like '*IMAGE*') {
      throw 'Прибор отклонил образ (ERR IMAGE): файл неполный или не подходит для этой прошивки. Прибор остался в режиме загрузки.'
    }
    if ($signal -eq 'timeout') {
      throw 'Прибор ответил UPD TIMEOUT при установке: нужна повторная попытка целиком, начиная с BT.'
    }
    if ($signal -like 'error:*') {
      throw ('Прибор обнаружил ошибки приёма: ' + $signal.Substring(6) + ' - повторите заливку.')
    }
    if ($signal -ne 'done') {
      throw ('Неожиданный ответ прибора на GO: ' + $signal)
    }

    Write-UploadLog $context 'Прибор принял образ (DONE) и перезапускается.'
    & $checkStop

    # --- Проверка: порт возвращается, идёт телеметрия ----------------------
    if ($opt.SkipVerify) {
      $result.Success = $true
      Set-UploadStage $context 100 'Готово' 'прошивка принята прибором'
    } else {
      Set-UploadStage $context 94 'Ожидание перезапуска прибора' 'прибор запускается и перечисляется заново'
      # Запоминаем порт заливки: номер у прибора не меняется, а открыть известный
      # порт надёжнее, чем искать его по реестру (кэш SERIALCOMM сразу после
      # переподключения устройства бывает пустым, хотя порт уже работает).
      $flashPort = $PortName
      if ($openedHere -and $link) { $link.Close() }
      $link = $null

      # Небольшая пауза перед первым открытием: прибор ещё копирует образ и держит
      # D+ в нуле, старый экземпляр устройства в это время разбирается. Замер на
      # реальной плате: новый порт появляется примерно через 2 с после DONE.
      $verifyLimit = [int]$opt.VerifyTimeoutSec
      $delay = [int]$opt.VerifyDelaySec
      if ($delay -gt ($verifyLimit - 2)) { $delay = $verifyLimit - 2 }
      if ($delay -lt 0) { $delay = 0 }
      $delayUntil = [datetime]::UtcNow.AddSeconds($delay)
      while ([datetime]::UtcNow -lt $delayUntil) {
        & $checkStop
        $left = [int][math]::Ceiling(([datetime]::UtcNow - $delayUntil).TotalSeconds * -1)
        Set-UploadStage $context 94 'Ожидание перезапуска прибора' ('прибор запускается, {0} с' -f $left)
        Start-Sleep -Milliseconds 200
      }

      $verifyDeadline = [datetime]::UtcNow.AddSeconds($verifyLimit)
      $verifyStarted = [datetime]::UtcNow
      $portSeen = $false
      while (-not $context.Verified -and [datetime]::UtcNow -lt $verifyDeadline) {
        & $checkStop

        # Кого открываем: сначала порт, через который шла заливка (номер у прибора
        # не меняется), затем - если он не открылся - найденный в системе.
        # Кэш SERIALCOMM сразу после переподключения устройства бывает пустым,
        # хотя порт уже работает, поэтому одного поиска по реестру недостаточно.
        $targets = New-Object System.Collections.Generic.List[string]
        if ($flashPort) { $targets.Add($flashPort) }
        $found = Find-UploadInstrumentPort
        if ($found -and $found.Port -and ($targets -notcontains $found.Port)) { $targets.Add($found.Port) }

        foreach ($target in $targets) {
          if ($context.Verified) { break }
          Set-UploadStage $context 96 'Проверка работы новой прошивки' ('открываю ' + $target)
          $probe = $null
          if ($TransportFactory) {
            try { $probe = & $TransportFactory $target } catch { }
          } else {
            try { $probe = New-UploadSerialLink -PortName $target -ReadTimeoutMs 200 } catch { }
          }
          if (-not $probe) { continue }

          if (-not $portSeen) {
            $portSeen = $true
            Write-UploadLog $context ('Порт снова открывается: ' + $target)
          }
          try {
            $probe.Write("ID`r`n")
            $waitUntil = [datetime]::UtcNow.AddMilliseconds(1500)
            while (-not $context.Verified -and [datetime]::UtcNow -lt $waitUntil) {
              $got = @($probe.ReadLines(200))
              if ($got.Count -eq 0) { continue }
              foreach ($line in $got) {
                if ($null -eq $line) { continue }
                $text = $line.Trim()
                if ($text.Length -eq 0) { continue }
                $kind = Get-UploadLineKind $text
                if ($kind -eq 'telemetry') {
                  $context.TelemetryCount++
                  $context.Telemetry = $text
                  $context.Verified = $true
                  $context.VerifiedPort = $target
                } elseif ($kind -eq 'hello') {
                  if ($text -match '^Hello!\s+fw\s+(\S+)') { $context.VersionAfter = $Matches[1] }
                  Write-UploadLog $context ('  ' + $text)
                } elseif ($kind -eq 'state' -or $kind -eq 'error') {
                  Write-UploadLog $context ('  ' + $text)
                }
              }
            }
          } catch {
            # Порт закрылся или пропал во время чтения - это нормально для фазы
            # переподключения, просто пробуем дальше.
          } finally {
            $probe.Close()
          }
        }

        if (-not $context.Verified) {
          $elapsed = [int]([datetime]::UtcNow - $verifyStarted).TotalSeconds
          Set-UploadStage $context 95 'Ожидание перезапуска прибора' ('порт ещё не отвечает, {0} из {1} с' -f $elapsed, $verifyLimit)
          Start-Sleep -Milliseconds 800
        }
      }

      if ($context.Verified) {
        Write-UploadLog $context ('Телеметрия: {0}' -f $context.Telemetry)
        if ($context.VersionAfter) { Write-UploadLog $context ('Версия на приборе после обновления: {0}' -f $context.VersionAfter) }
        $result.Success = $true
        $result.Verified = $true
        Set-UploadStage $context 100 'Готово' 'прибор работает, телеметрия идёт'
      } else {
        # Образ прибор принял (DONE), поэтому это не провал прошивки, а неподтверждённый запуск.
        $result.Success = $true
        $result.Verified = $false
        Write-UploadLog $context 'Внимание: порт или телеметрия не появились за отведённое время.'
        Write-UploadLog $context 'Образ принят прибором. Если телеметрии нет - отключите и подключите USB-кабель: прибор запустится с чистого состояния.'
        Set-UploadStage $context 100 'Прошивка залита' 'отключите и подключите USB-кабель, если прибора нет'
      }
    }

    if ($result.Verified -or $opt.SkipVerify) {
      $result.Message = 'Прошивка залита, прибор работает.'
    } else {
      $result.Message = 'Прошивка залита, но телеметрия не подтвердилась.'
    }
  }
  catch {
    $message = $_.Exception.Message
    $result.Success = $false
    if ($message -eq $script:UploadCancelMarker) {
      $result.Cancelled = $true
      $result.Message = 'Заливка отменена. Прибор выйдет из режима загрузки сам (тайм-аут 30 с).'
      Write-UploadLog $context 'Отменено пользователем.'
      Set-UploadStage $context $context.Percent 'Отменено' 'прибор выйдет из режима загрузки сам'
    } else {
      $result.Message = $message
      Write-UploadLog $context ('ОШИБКА: ' + $message)
      Set-UploadStage $context $context.Percent 'Ошибка' $message
    }
  }
  finally {
    if ($openedHere -and $link) { try { $link.Close() } catch { } }
    $stopwatch.Stop()
    $result.DurationMs = [int]$stopwatch.ElapsedMilliseconds
    $result.Percent = $context.Percent
    if ($Plan) { $result.DataRecords = [int]$Plan.DataRecords }
    $result.DeviceRecords = [int]$context.DeviceRecords
    $result.Telemetry = $context.Telemetry
    $result.VersionBefore = $context.VersionBefore
    $result.VersionAfter = $context.VersionAfter
    $result.Log = $context.Log.ToArray()
  }

  return $result
}
