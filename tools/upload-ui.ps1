# =============================================================================
#  upload-ui.ps1 - окно прошивальщика Prof_KIP_v5 (WinForms).
#
#  Файл подключается через точку после upload-core.ps1:
#      . tools/upload-core.ps1
#      . tools/upload-ui.ps1
#      $ui = New-UploaderWindow -DefaultFolder tools/../build
#      [void]$ui.Form.ShowDialog()
#
#  Окно: выбор файла прошивки, выбор COM-порта прибора, кнопка «Залить»,
#  полоса 0..100 %, текущий этап, подробности этапа и журнал обмена.
#  Работа идёт в этом же потоке, а окно перерисовывается через DoEvents:
#  поэтому во время заливки кнопка превращается в «Отменить».
# =============================================================================

$script:UploaderColors = @{
  Text  = [System.Drawing.Color]::FromArgb(32, 32, 32)
  Muted = [System.Drawing.Color]::FromArgb(105, 105, 105)
  Ok    = [System.Drawing.Color]::FromArgb(0, 120, 60)
  Error = [System.Drawing.Color]::FromArgb(190, 35, 35)
  Busy  = [System.Drawing.Color]::FromArgb(20, 70, 150)
  Warn  = [System.Drawing.Color]::FromArgb(170, 110, 0)
  Bg    = [System.Drawing.Color]::FromArgb(246, 247, 250)
  Accent = [System.Drawing.Color]::FromArgb(0, 102, 180)
}

$script:UploaderSettingsPath = Join-Path $env:LOCALAPPDATA 'Prof_KIP_v5\uploader-settings.json'

# -----------------------------------------------------------------------------
#  Настройки между запусками (последний файл и порт)
# -----------------------------------------------------------------------------

function Read-UploaderSettings {
  $settings = @{ LastFile = $null; LastPort = $null; LastFolder = $null }
  try {
    if (Test-Path -LiteralPath $script:UploaderSettingsPath) {
      $json = [System.IO.File]::ReadAllText($script:UploaderSettingsPath, [System.Text.Encoding]::UTF8)
      $data = $json | ConvertFrom-Json
      foreach ($key in @('LastFile', 'LastPort', 'LastFolder')) {
        if ($data.PSObject.Properties.Name -contains $key -and $data.$key) { $settings[$key] = [string]$data.$key }
      }
    }
  } catch { }
  return $settings
}

function Save-UploaderSettings {
  # Настройки нужны только для удобства: любая ошибка записи молча игнорируется.
  param([hashtable]$Settings)
  try {
    $folder = Split-Path $script:UploaderSettingsPath -Parent
    if ($folder -and -not [System.IO.Directory]::Exists($folder)) {
      [void][System.IO.Directory]::CreateDirectory($folder)
    }
    $json = $Settings | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($script:UploaderSettingsPath, $json, (New-Object System.Text.UTF8Encoding $false))
  } catch { }
}

# -----------------------------------------------------------------------------
#  Мелкие помощники для элементов управления
# -----------------------------------------------------------------------------

function New-UploaderLabel {
  param(
    [string]$Text,
    [System.Drawing.Font]$Font = $null,
    [System.Drawing.Color]$Color = $null,
    [switch]$Wrap
  )
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.AutoSize = $true
  $label.Anchor = [System.Windows.Forms.AnchorStyles]::Left
  if ($Font) { $label.Font = $Font }
  if ($Color) { $label.ForeColor = $Color }
  $label.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 4)
  if ($Wrap) { $label.AutoSize = $false; $label.AutoEllipsis = $true }
  return $label
}

function New-UploaderGroup {
  param([string]$Text)
  $group = New-Object System.Windows.Forms.GroupBox
  $group.Text = ' ' + $Text + ' '
  $group.Dock = [System.Windows.Forms.DockStyle]::Fill
  $group.AutoSize = $true
  $group.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $group.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 8)
  $group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
  return $group
}

function Get-UploaderStatusKind {
  param([string]$Stage)
  if ($Stage -eq 'Ошибка') { return 'error' }
  if ($Stage -eq 'Готово') { return 'ok' }
  if ($Stage -eq 'Прошивка залита') { return 'ok' }
  if ($Stage -eq 'Отменено') { return 'warn' }
  return 'busy'
}

# -----------------------------------------------------------------------------
#  Обновление частей окна
# -----------------------------------------------------------------------------

function Add-UploaderLog {
  param($Ui, [string]$Text)
  if ($null -eq $Text) { return }
  $stamp = (Get-Date).ToString('HH:mm:ss')
  $Ui.Log.AppendText(('[{0}] {1}{2}' -f $stamp, $Text, [Environment]::NewLine))
  $Ui.Log.SelectionStart = $Ui.Log.TextLength
  $Ui.Log.ScrollToCaret()
}

function Set-UploaderProgressColor {
  <#
    Цвет полосы: обычный, красный при ошибке, жёлтый при отмене.
    Используется сообщение ProgressBar PBM_SETSTATE (Windows 7 и новее);
    если оно недоступно, вид полосы просто остаётся обычным.
  #>
  param($Ui, [int]$State)

  try {
    if (-not ([System.Management.Automation.PSTypeName]'ProfKip.Win32Progress').Type) {
      Add-Type -Namespace ProfKip -Name Win32Progress -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.IntPtr wParam, System.IntPtr lParam);
'@
    }
    if ($Ui.Progress.IsHandleCreated) {
      [void][ProfKip.Win32Progress]::SendMessage($Ui.Progress.Handle, 0x0410, [IntPtr]$State, [IntPtr]::Zero)
    }
  } catch { }
}

function Set-UploaderStatus {
  param($Ui, [int]$Percent, [string]$Stage, [string]$Detail, [string]$Kind = 'busy')

  if ($Percent -lt 0) { $Percent = 0 }
  if ($Percent -gt 100) { $Percent = 100 }
  $colors = $script:UploaderColors

  # Обновляем только изменившиеся поля и сразу их перерисовываем:
  # во время передачи события идут часто, и отложенная перерисовка даёт устаревший текст.
  if ($Ui.Progress.Value -ne $Percent) {
    $Ui.Progress.Value = $Percent
    $Ui.Progress.Refresh()
  }
  $percentText = '{0} %' -f $Percent
  if ($Ui.LblPercent.Text -ne $percentText) {
    $Ui.LblPercent.Text = $percentText
    $Ui.LblPercent.Refresh()
  }
  if ($Ui.LblStage.Text -ne $Stage) {
    $Ui.LblStage.Text = $Stage
    $Ui.LblStage.Refresh()
  }
  if ($Ui.LblDetail.Text -ne $Detail) {
    $Ui.LblDetail.Text = $Detail
    $Ui.LblDetail.Refresh()
  }

  switch ($Kind) {
    'ok'    { $Ui.LblStage.ForeColor = $colors.Ok;    $Ui.LblPercent.ForeColor = $colors.Ok;    Set-UploaderProgressColor $Ui 1 }
    'error' { $Ui.LblStage.ForeColor = $colors.Error; $Ui.LblPercent.ForeColor = $colors.Error; Set-UploaderProgressColor $Ui 2 }
    'warn'  { $Ui.LblStage.ForeColor = $colors.Warn;  $Ui.LblPercent.ForeColor = $colors.Warn;  Set-UploaderProgressColor $Ui 3 }
    default { $Ui.LblStage.ForeColor = $colors.Busy;  $Ui.LblPercent.ForeColor = $colors.Busy;  Set-UploaderProgressColor $Ui 1 }
  }

  # Перерисовать окно и дать сработать нажатиям (кнопка «Отменить»).
  [System.Windows.Forms.Application]::DoEvents()
}

function Update-UploaderFileInfo {
  param($Ui)

  $colors = $script:UploaderColors
  $path = [string]$Ui.TxtFile.Text
  if ($path.Trim().Length -eq 0) {
    $Ui.LblFileInfo.Text = 'Файл не выбран. Нажмите «Обзор…» и укажите .hex из папки build.'
    $Ui.LblFileInfo.ForeColor = $colors.Muted
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $Ui.LblFileInfo.Text = 'Файл не найден.'
    $Ui.LblFileInfo.ForeColor = $colors.Error
    return
  }

  $plan = Get-UploadFirmwarePlan -Path $path
  if ($plan.IsValid) {
    $text = '{0}, {1:N0} байт кода, {2} записей' -f $plan.Kind.ToUpperInvariant(), $plan.PayloadBytes, $plan.DataRecords
    if ($null -ne $plan.FirstAddress -and $null -ne $plan.LastAddress) {
      $text += (', 0x{0:X8}..0x{1:X8}' -f $plan.FirstAddress, $plan.LastAddress)
    }
    if ($plan.Warnings.Count -gt 0) { $text += '  (' + ($plan.Warnings -join ' ') + ')' }
    $Ui.LblFileInfo.Text = $text
    $Ui.LblFileInfo.ForeColor = $colors.Ok
  } else {
    $Ui.LblFileInfo.Text = 'Файл не подходит: ' + ($plan.Errors -join ' ')
    $Ui.LblFileInfo.ForeColor = $colors.Error
  }
}

function Update-UploaderPorts {
  param($Ui)

  $colors = $script:UploaderColors
  $previous = [string]$Ui.CmbPort.SelectedItem
  $ports = @(Get-UploadComPorts)
  $found = Find-UploadInstrumentPort

  $Ui.CmbPort.BeginUpdate()
  try {
    $Ui.CmbPort.Items.Clear()
    foreach ($port in $ports) { [void]$Ui.CmbPort.Items.Add($port) }
    if ($found -and ($ports -notcontains $found.Port)) { [void]$Ui.CmbPort.Items.Add($found.Port) }
  } finally {
    $Ui.CmbPort.EndUpdate()
  }

  if ($found) {
    $Ui.CmbPort.SelectedItem = $found.Port
    $Ui.LblPortInfo.Text = 'Прибор подключён: ' + $found.Name
    $Ui.LblPortInfo.ForeColor = $colors.Ok
    return
  }

  if ($previous -and ($Ui.CmbPort.Items -contains $previous)) { $Ui.CmbPort.SelectedItem = $previous }
  elseif ($Ui.CmbPort.Items.Count -gt 0) { $Ui.CmbPort.SelectedIndex = 0 }

  if ($ports.Count -eq 0) {
    $Ui.LblPortInfo.Text = 'Последовательных портов нет. Подключите USB прибора.'
    $Ui.LblPortInfo.ForeColor = $colors.Error
  } else {
    $Ui.LblPortInfo.Text = 'Прибор не найден (VID_0483:PID_5740). Проверьте USB-кабель; порт можно выбрать вручную.'
    $Ui.LblPortInfo.ForeColor = $colors.Warn
  }
}

function Set-UploaderBusy {
  param($Ui, [bool]$Busy)

  $Ui.Busy = $Busy
  $Ui.TxtFile.Enabled = -not $Busy
  $Ui.BtnBrowse.Enabled = -not $Busy
  $Ui.CmbPort.Enabled = -not $Busy
  $Ui.BtnRefresh.Enabled = -not $Busy
  $Ui.BtnClear.Enabled = -not $Busy
  if ($Busy) {
    $Ui.BtnFlash.Text = 'Отменить'
    $Ui.BtnFlash.BackColor = $script:UploaderColors.Warn
  } else {
    $Ui.BtnFlash.Text = 'Залить прошивку'
    $Ui.BtnFlash.BackColor = $script:UploaderColors.Accent
  }
  [System.Windows.Forms.Application]::DoEvents()
}

# -----------------------------------------------------------------------------
#  Заливка по нажатию кнопки
# -----------------------------------------------------------------------------

function Start-UploaderJob {
  param($Ui)

  $colors = $script:UploaderColors

  # Во время работы кнопка служит для отмены.
  if ($Ui.Busy) {
    $Ui.CancelRequested = $true
    $Ui.BtnFlash.Text = 'Отмена…'
    Add-UploaderLog $Ui 'Запрошена отмена: останавливаюсь после текущего шага.'
    return
  }

  $path = ([string]$Ui.TxtFile.Text).Trim()
  if ($path.Length -eq 0) {
    Set-UploaderStatus $Ui 0 'Файл не выбран' 'Нажмите «Обзор…» и укажите .hex или .bin' 'error'
    Add-UploaderLog $Ui 'Ошибка: файл прошивки не выбран.'
    return
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    Set-UploaderStatus $Ui 0 'Файл не найден' $path 'error'
    Add-UploaderLog $Ui ('Ошибка: файл не найден: ' + $path)
    return
  }

  $plan = Get-UploadFirmwarePlan -Path $path
  if (-not $plan.IsValid) {
    $message = ($plan.Errors -join ' ')
    Set-UploaderStatus $Ui 0 'Файл не подходит' $message 'error'
    Add-UploaderLog $Ui ('Ошибка: файл не подходит: ' + $message)
    return
  }

  $port = [string]$Ui.CmbPort.SelectedItem
  if ($port.Length -eq 0) {
    $found = Find-UploadInstrumentPort
    if ($found) { $port = $found.Port }
  }
  if ($port.Length -eq 0) {
    Set-UploaderStatus $Ui 0 'Порт не выбран' 'Подключите прибор и обновите список портов' 'error'
    Add-UploaderLog $Ui 'Ошибка: COM-порт прибора не найден.'
    return
  }

  $Ui.CancelRequested = $false
  Set-UploaderBusy $Ui $true
  Set-UploaderStatus $Ui 0 'Подготовка' ('порт {0}, файл {1}' -f $port, $plan.FileName) 'busy'
  Add-UploaderLog $Ui '------------------------------------------------------------'
  Add-UploaderLog $Ui ('Заливка: {0} -> {1}' -f $path, $port)
  $detected = Find-UploadInstrumentPort
  if (-not $detected) {
    Add-UploaderLog $Ui ('Внимание: прибор по VID/PID не найден, работаю с выбранным портом ' + $port + '.')
  }

  $settings = Read-UploaderSettings
  $settings.LastFile = $path
  $settings.LastPort = $port
  $settings.LastFolder = Split-Path $path -Parent
  Save-UploaderSettings $settings

  try {
    $result = Invoke-FirmwareUpload -Plan $plan -PortName $port -TransportFactory $Ui.TransportFactory -Options $Ui.Options `
      -OnProgress {
        param($percent, $stage, $detail)
        Set-UploaderStatus $script:UploaderUi $percent $stage $detail (Get-UploaderStatusKind $stage)
      } `
      -OnLog {
        param($text)
        Add-UploaderLog $script:UploaderUi $text
      } `
      -ShouldStop {
        if ($script:UploaderUi.CancelRequested) { return $true }
        return $false
      }

    $seconds = '{0:N1}' -f ($result.DurationMs / 1000.0)
    if ($result.Cancelled) {
      Add-UploaderLog $Ui ('Отменено пользователем через {0} с.' -f $seconds)
    } elseif ($result.Success) {
      Add-UploaderLog $Ui ('Готово за {0} с. {1}' -f $seconds, $result.Message)
    } else {
      Add-UploaderLog $Ui ('Ошибка за {0} с: {1}' -f $seconds, $result.Message)
    }
  } catch {
    $message = $_.Exception.Message
    Add-UploaderLog $Ui ('Непредвиденная ошибка: ' + $message)
    Set-UploaderStatus $Ui $Ui.Progress.Value 'Ошибка' $message 'error'
  } finally {
    Set-UploaderBusy $Ui $false
    Update-UploaderPorts $Ui
    Update-UploaderFileInfo $Ui
  }
}

# -----------------------------------------------------------------------------
#  Сборка окна
# -----------------------------------------------------------------------------

function New-UploaderWindow {
  <#
    Собрать окно прошивальщика.

    Параметры:
      FirmwarePath     - файл прошивки, которым заполнить поле (необязательно);
      PortName         - COM-порт, который выбрать (необязательно);
      DefaultFolder    - папка для диалога выбора файла (обычно build);
      TransportFactory - точка подмены связи для автотестов; в обычной работе
                         не задаётся, и порт открывается через upload-core.ps1.

    Возвращает набор: Form, элементы управления и общее состояние в State.
  #>
  param(
    [string]$FirmwarePath,
    [string]$PortName,
    [string]$DefaultFolder,
    [scriptblock]$TransportFactory
  )

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $colors = $script:UploaderColors
  $fontNormal = New-Object System.Drawing.Font('Segoe UI', 9)
  $fontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
  $fontStage = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
  $fontPercent = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
  $fontMono = New-Object System.Drawing.Font('Consolas', 8.5)

  $settings = Read-UploaderSettings
  if (-not $DefaultFolder) {
    if ($settings.LastFolder -and (Test-Path -LiteralPath $settings.LastFolder)) { $DefaultFolder = $settings.LastFolder }
    else { $DefaultFolder = (Get-Location).Path }
  }

  # --- окно -----------------------------------------------------------------
  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'Прошивальщик Prof_KIP_v5 — обновление ПО прибора по USB'
  $form.ClientSize = New-Object System.Drawing.Size(820, 640)
  $form.MinimumSize = New-Object System.Drawing.Size(740, 560)
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.Font = $fontNormal
  $form.BackColor = $colors.Bg
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $form.KeyPreview = $true

  $root = New-Object System.Windows.Forms.TableLayoutPanel
  $root.Dock = [System.Windows.Forms.DockStyle]::Fill
  $root.ColumnCount = 1
  $root.RowCount = 5
  $root.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 10)
  [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # файл
  [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # порт
  [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # прогресс
  [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))  # журнал
  [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))   # кнопки
  $form.Controls.Add($root)

  # --- 1. файл прошивки ------------------------------------------------------
  $grpFile = New-UploaderGroup '1. Прошивка'
  $layFile = New-Object System.Windows.Forms.TableLayoutPanel
  $layFile.Dock = [System.Windows.Forms.DockStyle]::Fill
  $layFile.AutoSize = $true
  $layFile.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $layFile.ColumnCount = 3
  $layFile.RowCount = 2
  [void]$layFile.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 46)))
  [void]$layFile.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$layFile.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 104)))
  [void]$layFile.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
  [void]$layFile.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
  $grpFile.Controls.Add($layFile)

  $lblFile = New-UploaderLabel 'Файл:' -Color $colors.Text
  $lblFile.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $lblFile.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $lblFile.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblFile.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)

  $txtFile = New-Object System.Windows.Forms.TextBox
  $txtFile.Dock = [System.Windows.Forms.DockStyle]::Fill
  $txtFile.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 3)

  $btnBrowse = New-Object System.Windows.Forms.Button
  $btnBrowse.Text = 'Обзор…'
  $btnBrowse.Dock = [System.Windows.Forms.DockStyle]::Fill
  $btnBrowse.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
  $btnBrowse.Height = 24

  $lblFileInfo = New-Object System.Windows.Forms.Label
  $lblFileInfo.AutoSize = $false
  $lblFileInfo.Height = 20
  $lblFileInfo.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblFileInfo.AutoEllipsis = $true
  $lblFileInfo.ForeColor = $colors.Muted
  $lblFileInfo.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $lblFileInfo.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)

  $layFile.Controls.Add($lblFile, 0, 0)
  $layFile.Controls.Add($txtFile, 1, 0)
  $layFile.Controls.Add($btnBrowse, 2, 0)
  $layFile.Controls.Add($lblFileInfo, 0, 1)
  $layFile.SetColumnSpan($lblFileInfo, 3)
  $root.Controls.Add($grpFile, 0, 0)

  # --- 2. прибор -------------------------------------------------------------
  $grpPort = New-UploaderGroup '2. Прибор'
  $layPort = New-Object System.Windows.Forms.TableLayoutPanel
  $layPort.Dock = [System.Windows.Forms.DockStyle]::Fill
  $layPort.AutoSize = $true
  $layPort.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $layPort.ColumnCount = 3
  $layPort.RowCount = 2
  [void]$layPort.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 46)))
  [void]$layPort.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$layPort.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 104)))
  [void]$layPort.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
  [void]$layPort.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
  $grpPort.Controls.Add($layPort)

  $lblPort = New-UploaderLabel 'Порт:' -Color $colors.Text
  $lblPort.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblPort.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $lblPort.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)

  $cmbPort = New-Object System.Windows.Forms.ComboBox
  $cmbPort.Dock = [System.Windows.Forms.DockStyle]::Fill
  $cmbPort.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $cmbPort.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 3)

  $btnRefresh = New-Object System.Windows.Forms.Button
  $btnRefresh.Text = 'Обновить'
  $btnRefresh.Dock = [System.Windows.Forms.DockStyle]::Fill
  $btnRefresh.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)

  $lblPortInfo = New-Object System.Windows.Forms.Label
  $lblPortInfo.AutoSize = $false
  $lblPortInfo.Height = 20
  $lblPortInfo.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblPortInfo.AutoEllipsis = $true
  $lblPortInfo.ForeColor = $colors.Muted
  $lblPortInfo.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $lblPortInfo.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)

  $layPort.Controls.Add($lblPort, 0, 0)
  $layPort.Controls.Add($cmbPort, 1, 0)
  $layPort.Controls.Add($btnRefresh, 2, 0)
  $layPort.Controls.Add($lblPortInfo, 0, 1)
  $layPort.SetColumnSpan($lblPortInfo, 3)
  $root.Controls.Add($grpPort, 0, 1)

  # --- 3. ход заливки -------------------------------------------------------
  $grpProgress = New-UploaderGroup '3. Заливка'
  $layProgress = New-Object System.Windows.Forms.TableLayoutPanel
  $layProgress.Dock = [System.Windows.Forms.DockStyle]::Fill
  $layProgress.AutoSize = $true
  $layProgress.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $layProgress.ColumnCount = 2
  $layProgress.RowCount = 3
  [void]$layProgress.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$layProgress.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 118)))
  [void]$layProgress.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
  [void]$layProgress.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
  [void]$layProgress.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
  $grpProgress.Controls.Add($layProgress)

  $progress = New-Object System.Windows.Forms.ProgressBar
  $progress.Minimum = 0
  $progress.Maximum = 100
  $progress.Value = 0
  $progress.Dock = [System.Windows.Forms.DockStyle]::Fill
  $progress.Margin = New-Object System.Windows.Forms.Padding(0, 4, 10, 4)

  $lblPercent = New-Object System.Windows.Forms.Label
  $lblPercent.Text = '0 %'
  $lblPercent.Font = $fontPercent
  $lblPercent.ForeColor = $colors.Muted
  $lblPercent.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblPercent.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
  $lblPercent.Margin = New-Object System.Windows.Forms.Padding(0)

  $lblStage = New-Object System.Windows.Forms.Label
  $lblStage.Text = 'Готово к заливке'
  $lblStage.Font = $fontStage
  $lblStage.ForeColor = $colors.Text
  $lblStage.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblStage.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $lblStage.AutoEllipsis = $true
  $lblStage.Margin = New-Object System.Windows.Forms.Padding(0)

  $lblDetail = New-Object System.Windows.Forms.Label
  $lblDetail.Text = 'Выберите файл прошивки и нажмите «Залить прошивку».'
  $lblDetail.ForeColor = $colors.Muted
  $lblDetail.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblDetail.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $lblDetail.AutoEllipsis = $true
  $lblDetail.Margin = New-Object System.Windows.Forms.Padding(0)

  $layProgress.Controls.Add($progress, 0, 0)
  $layProgress.Controls.Add($lblPercent, 1, 0)
  $layProgress.Controls.Add($lblStage, 0, 1)
  $layProgress.SetColumnSpan($lblStage, 2)
  $layProgress.Controls.Add($lblDetail, 0, 2)
  $layProgress.SetColumnSpan($lblDetail, 2)
  $root.Controls.Add($grpProgress, 0, 2)

  # --- 4. журнал -------------------------------------------------------------
  $grpLog = New-UploaderGroup '4. Журнал'
  $log = New-Object System.Windows.Forms.TextBox
  $log.Multiline = $true
  $log.ReadOnly = $true
  $log.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $log.WordWrap = $false
  $log.Dock = [System.Windows.Forms.DockStyle]::Fill
  $log.Font = $fontMono
  $log.BackColor = [System.Drawing.Color]::White
  $log.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $grpLog.Controls.Add($log)
  $root.Controls.Add($grpLog, 0, 3)

  # --- 5. кнопки -------------------------------------------------------------
  $panelButtons = New-Object System.Windows.Forms.TableLayoutPanel
  $panelButtons.Dock = [System.Windows.Forms.DockStyle]::Fill
  $panelButtons.ColumnCount = 3
  $panelButtons.RowCount = 1
  $panelButtons.Margin = New-Object System.Windows.Forms.Padding(0)
  [void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 210)))
  [void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 170)))
  [void]$panelButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
  [void]$panelButtons.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

  $btnFlash = New-Object System.Windows.Forms.Button
  $btnFlash.Text = 'Залить прошивку'
  $btnFlash.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
  $btnFlash.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnFlash.BackColor = $colors.Accent
  $btnFlash.ForeColor = [System.Drawing.Color]::White
  $btnFlash.FlatAppearance.BorderSize = 0
  $btnFlash.Dock = [System.Windows.Forms.DockStyle]::Fill
  $btnFlash.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)

  $btnClear = New-Object System.Windows.Forms.Button
  $btnClear.Text = 'Очистить журнал'
  $btnClear.Dock = [System.Windows.Forms.DockStyle]::Fill
  $btnClear.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)

  $lblHint = New-Object System.Windows.Forms.Label
  $lblHint.Text = 'Прошивка по USB, без ST-LINK: прибор сам перезапустится через ~5 с.'
  $lblHint.ForeColor = $colors.Muted
  $lblHint.Dock = [System.Windows.Forms.DockStyle]::Fill
  $lblHint.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $lblHint.AutoEllipsis = $true

  $panelButtons.Controls.Add($btnFlash, 0, 0)
  $panelButtons.Controls.Add($btnClear, 1, 0)
  $panelButtons.Controls.Add($lblHint, 2, 0)
  $root.Controls.Add($panelButtons, 0, 4)

  # --- состояние и связи -----------------------------------------------------
  $ui = [pscustomobject]@{
    Form             = $form
    Busy             = $false
    CancelRequested  = $false
    TransportFactory = $TransportFactory
    Options          = @{}
    DefaultFolder    = $DefaultFolder
    TxtFile          = $txtFile
    BtnBrowse        = $btnBrowse
    LblFileInfo      = $lblFileInfo
    CmbPort          = $cmbPort
    BtnRefresh       = $btnRefresh
    LblPortInfo      = $lblPortInfo
    Progress         = $progress
    LblPercent       = $lblPercent
    LblStage         = $lblStage
    LblDetail        = $lblDetail
    Log              = $log
    BtnFlash         = $btnFlash
    BtnClear         = $btnClear
  }
  $script:UploaderUi = $ui

  # --- обработчики -----------------------------------------------------------
  $btnBrowse.Add_Click({
    $current = $script:UploaderUi
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Файл прошивки'
    $dialog.Filter = 'Прошивка (*.hex;*.bin)|*.hex;*.bin|Intel HEX (*.hex)|*.hex|Двоичный образ (*.bin)|*.bin|Все файлы (*.*)|*.*'
    $dialog.CheckFileExists = $true
    $dialog.CheckPathExists = $true
    $folder = $current.DefaultFolder
    $typed = [string]$current.TxtFile.Text
    if ($typed -and (Test-Path -LiteralPath (Split-Path $typed -Parent))) { $folder = Split-Path $typed -Parent }
    if (Test-Path -LiteralPath $folder) { $dialog.InitialDirectory = $folder }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $current.TxtFile.Text = $dialog.FileName
      $current.DefaultFolder = Split-Path $dialog.FileName -Parent
      $settings = Read-UploaderSettings
      $settings.LastFolder = $current.DefaultFolder
      $settings.LastFile = $dialog.FileName
      Save-UploaderSettings $settings
    }
  })

  $txtFile.Add_TextChanged({ Update-UploaderFileInfo -Ui $script:UploaderUi })
  $btnRefresh.Add_Click({ Update-UploaderPorts -Ui $script:UploaderUi })
  $btnFlash.Add_Click({ Start-UploaderJob -Ui $script:UploaderUi })
  $btnClear.Add_Click({ $script:UploaderUi.Log.Clear() })

  $form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:UploaderUi -and $script:UploaderUi.Busy) {
      $eventArgs.Cancel = $true
      $script:UploaderUi.LblDetail.Text = 'Идёт заливка: дождитесь окончания или нажмите «Отменить».'
      $script:UploaderUi.LblDetail.ForeColor = $script:UploaderColors.Warn
    }
  })

  # --- начальное заполнение --------------------------------------------------
  $startFile = $FirmwarePath
  if (-not $startFile -and $settings.LastFile -and (Test-Path -LiteralPath $settings.LastFile)) { $startFile = $settings.LastFile }
  if (-not $startFile -and $DefaultFolder) {
    # Обычный случай: только что собранная прошивка лежит в build.
    $built = Join-Path $DefaultFolder 'Prof_KIP_v5.hex'
    if (Test-Path -LiteralPath $built) { $startFile = $built }
  }
  if ($startFile) { $txtFile.Text = $startFile }

  Update-UploaderPorts -Ui $ui
  if ($PortName -and ($cmbPort.Items -contains $PortName)) { $cmbPort.SelectedItem = $PortName }

  Update-UploaderFileInfo -Ui $ui
  Add-UploaderLog $ui 'Прошивальщик Prof_KIP_v5. Порт прибора: VID_0483:PID_5740, 115200 8N1.'
  if ($txtFile.Text.Trim().Length -eq 0) {
    Add-UploaderLog $ui 'Файл прошивки не выбран: укажите .hex из папки build.'
  } else {
    Add-UploaderLog $ui ('Выбран файл: ' + $txtFile.Text)
  }

  return $ui
}
