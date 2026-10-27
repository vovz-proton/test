# =============================================================================
#  sine-levels-ui.ps1 - окно программы уровней ЦАП Prof_KIP_v5 (WinForms).
#
#  Файл подключается через точку после sine-levels-core.ps1:
#      . tools/sine-levels-core.ps1
#      . tools/sine-levels-ui.ps1
#      $ui = New-SineLevelsWindow
#      [void]$ui.Form.ShowDialog()
#
#  Окно: порт прибора, четыре ползунка (A1, B1, A2, B2), предпросмотр двух
#  синусоид с сеткой кодов и вольт, подтверждённые прибором уровни и журнал.
#  Изменения уходят на прибор сами через 0,1 с после остановки ползунка.
# =============================================================================

$script:SineColors = @{
  Text   = [System.Drawing.Color]::FromArgb(32, 32, 32)
  Muted  = [System.Drawing.Color]::FromArgb(105, 105, 105)
  Ok     = [System.Drawing.Color]::FromArgb(0, 120, 60)
  Error  = [System.Drawing.Color]::FromArgb(190, 35, 35)
  Busy   = [System.Drawing.Color]::FromArgb(20, 70, 150)
  Warn   = [System.Drawing.Color]::FromArgb(170, 110, 0)
  Bg     = [System.Drawing.Color]::FromArgb(246, 247, 250)
  Accent = [System.Drawing.Color]::FromArgb(0, 102, 180)
  Ch1    = [System.Drawing.Color]::FromArgb(0, 102, 180)
  Ch2    = [System.Drawing.Color]::FromArgb(214, 120, 0)
}

$script:SineStateNames = @{
  HOMING      = 'поиск концевика'
  POSITIONING = 'подготовка трассы'
  READY       = 'готов'
  SCAN        = 'сканирование'
  RETURN      = 'возврат'
  FAULT       = 'ошибка'
}

# -----------------------------------------------------------------------------
#  Помощники для элементов управления
# -----------------------------------------------------------------------------

function New-SineLabel {
  param(
    [string]$Text,
    [int]$X, [int]$Y, [int]$Width, [int]$Height = 20,
    [System.Drawing.Font]$Font = $null,
    [System.Nullable[System.Drawing.Color]]$Color = $null,
    [string]$Align = 'MiddleLeft'
  )
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.AutoSize = $false
  $label.Location = New-Object System.Drawing.Point $X, $Y
  $label.Size = New-Object System.Drawing.Size $Width, $Height
  $label.TextAlign = $Align
  $label.AutoEllipsis = $true
  if ($Font) { $label.Font = $Font }
  if ($Color.HasValue) { $label.ForeColor = $Color.Value }
  return $label
}

function New-SineButton {
  param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 32)
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Location = New-Object System.Drawing.Point $X, $Y
  $button.Size = New-Object System.Drawing.Size $Width, $Height
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(178, 186, 198)
  $button.BackColor = [System.Drawing.Color]::White
  $button.ForeColor = $script:SineColors.Text
  $button.UseVisualStyleBackColor = $false
  return $button
}

function New-SineLevelHandler {
  <#
    Обработчик одного ползунка или поля. GetNewClosure нужен, чтобы каждый
    обработчик запомнил СВОЁ имя: без него все четыре видят последнее.
  #>
  param([string]$Name)
  return {
    param($sender, $eventArgs)
    Set-SineUiLevel -Name $Name -Value ([int]$sender.Value)
  }.GetNewClosure()
}

# -----------------------------------------------------------------------------
#  Окно
# -----------------------------------------------------------------------------

function New-SineLevelsWindow {
  <#
    Создать окно (не показывать). TransportFactory - подстановка связи для
    тестов: scriptblock param($portName), возвращающий объект Write/Drain/Close.
  #>
  param(
    [string]$PortName,
    [scriptblock]$TransportFactory,
    [switch]$NoAutoConnect
  )

  $settings = Read-SineSettings
  $colors = $script:SineColors
  $formFont = [System.Drawing.Font]::new('Segoe UI', [single]9)

  $ui = @{}
  $script:SineUi = $ui

  $ui.Suppress = $false
  $ui.WarnedOffline = $false
  $ui.Instrument = $null
  $ui.TransportFactory = $TransportFactory
  $ui.AutoConnect = (-not $NoAutoConnect)
  $ui.InitialPort = $PortName
  $ui.PortName = $null
  $ui.LastQueued = @{ A1 = $null; B1 = $null; A2 = $null; B2 = $null; F = $null; PH = $null }
  $ui.Summary = $null
  $ui.LastState = $null
  $ui.UnknownLines = 0
  $ui.BootWarned = $false
  $ui.DeviceName = $null
  $ui.Firmware = $null
  $ui.ConnectionOk = $false

  # ---------------------------------------------------------------- форма
  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'Синусоиды ЦАП — Prof_KIP_v5'
  $form.ClientSize = New-Object System.Drawing.Size 1000, 700
  $form.MinimumSize = $form.Size
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.BackColor = $colors.Bg
  $form.Font = $formFont
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
  $ui.Form = $form

  $ui.Tip = New-Object System.Windows.Forms.ToolTip
  $ui.Tip.AutoPopDelay = 15000

  # ------------------------------------------------------------- верх
  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = [System.Windows.Forms.DockStyle]::Top
  $top.Height = 82
  $top.Width = 1000
  $top.BackColor = $colors.Bg
  $ui.Top = $top

  $lblPort = New-SineLabel -Text 'Порт:' -X 12 -Y 14 -Width 40
  $ui.PortCombo = New-Object System.Windows.Forms.ComboBox
  $ui.PortCombo.Location = New-Object System.Drawing.Point 54, 10
  $ui.PortCombo.Size = New-Object System.Drawing.Size 112, 26
  $ui.PortCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
  $ui.PortCombo.Font = $formFont

  $ui.BtnRefresh = New-SineButton -Text 'Обновить' -X 172 -Y 10 -Width 76 -Height 26
  $ui.BtnConnect = New-SineButton -Text 'Подключить' -X 254 -Y 10 -Width 112 -Height 26
  $ui.BtnConnect.Font = [System.Drawing.Font]::new('Segoe UI', [single]9)

  $ui.StatusLabel = New-SineLabel -Text '● Не подключено' -X 378 -Y 12 -Width 430 -Height 22 `
    -Color $colors.Muted
  $ui.StatusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

  $lblVref = New-SineLabel -Text 'VREF+:' -X 828 -Y 14 -Width 46
  $lblVref.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $ui.Vref = New-Object System.Windows.Forms.NumericUpDown
  $ui.Vref.Location = New-Object System.Drawing.Point 876, 10
  $ui.Vref.Size = New-Object System.Drawing.Size 66, 24
  $ui.Vref.DecimalPlaces = 3
  $ui.Vref.Minimum = [decimal]0
  $ui.Vref.Maximum = [decimal]20
  $ui.Vref.Increment = [decimal]0.1
  $ui.Vref.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
  $ui.Vref.Value = [decimal]$settings.Vref
  $ui.Vref.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $lblVrefUnit = New-SineLabel -Text 'В' -X 946 -Y 14 -Width 14
  $lblVrefUnit.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $ui.LblVref = $lblVref
  $ui.LblVrefUnit = $lblVrefUnit

  $ui.StateLabel = New-SineLabel -Text 'Состояние: —' -X 12 -Y 48 -Width 470 -Height 20 `
    -Color $colors.Muted
  $ui.TelemetryLabel = New-SineLabel -Text 'Z = —   X = —' -X 490 -Y 48 -Width 498 -Height 20 `
    -Color $colors.Muted -Align 'MiddleRight'
  $ui.TelemetryLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

  $top.Controls.AddRange(@($lblPort, $ui.PortCombo, $ui.BtnRefresh, $ui.BtnConnect,
      $ui.StatusLabel, $lblVref, $ui.Vref, $lblVrefUnit, $ui.StateLabel, $ui.TelemetryLabel))
  $ui.Tip.SetToolTip($lblVref, 'Опорное напряжение ЦАП (VREF+). Нужно только для пересчёта кодов в вольты; на прибор не передаётся.')
  $ui.Tip.SetToolTip($ui.Vref, 'Опорное напряжение ЦАП (VREF+). Нужно только для пересчёта кодов в вольты; на прибор не передаётся.')
  $ui.Tip.SetToolTip($ui.StateLabel, 'STATE прибор присылает при изменении состояния и после нового USB-подключения: запроса состояния в протоколе нет.')
  $ui.Tip.SetToolTip($ui.TelemetryLabel, 'Z — усреднённый знаковый код SDADC, X — расчётная координата двигателя в миллиметрах.')

  # ------------------------------------------------------------ содержимое
  $content = New-Object System.Windows.Forms.Panel
  $content.Dock = [System.Windows.Forms.DockStyle]::Fill
  $content.BackColor = $colors.Bg
  $ui.Content = $content

  $left = New-Object System.Windows.Forms.Panel
  $left.Dock = [System.Windows.Forms.DockStyle]::Left
  $left.Width = 424
  $left.BackColor = $colors.Bg
  $ui.Left = $left

  $preview = New-Object System.Windows.Forms.Panel
  $preview.Dock = [System.Windows.Forms.DockStyle]::Fill
  $preview.BackColor = [System.Drawing.Color]::White
  $preview.Add_Resize({ param($sender, $eventArgs) $sender.Invalidate() })
  try {
    $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    $property = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $flags)
    if ($property) { $property.SetValue($preview, $true) }
  } catch { }
  $ui.Preview = $preview
  $ui.Tip.SetToolTip($preview, 'Предпросмотр: ЦАП1 = A1 + B1·sin (синий), ЦАП2 = A2 − B2·sin (оранжевый). До 2 периодов по 125 мкс.')

  $summary = New-Object System.Windows.Forms.Panel
  $summary.Dock = [System.Windows.Forms.DockStyle]::Bottom
  $summary.Height = 102
  $summary.Width = 576
  $summary.BackColor = $colors.Bg
  $ui.SummaryPanel = $summary

  $ui.LblRanges = New-SineLabel -Text 'ЦАП1 — · ЦАП2 —' -X 4 -Y 2 -Width 560 -Height 20
  $ui.LblRanges.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $ui.LblDiff = New-SineLabel -Text 'ЦАП1 − ЦАП2: —' -X 4 -Y 24 -Width 560 -Height 20
  $ui.LblDiff.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $ui.LblClip = New-SineLabel -Text '—' -X 4 -Y 46 -Width 560 -Height 20
  $ui.LblClip.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $ui.LblNote = New-SineLabel -Text '—' `
    -X 4 -Y 70 -Width 560 -Height 20 -Font ([System.Drawing.Font]::new('Segoe UI', [single]8.25)) -Color $colors.Muted
  $ui.LblNote.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

  $summary.Controls.AddRange(@($ui.LblRanges, $ui.LblDiff, $ui.LblClip, $ui.LblNote))
  $content.Controls.Add($preview)
  $content.Controls.Add($summary)
  $content.Controls.Add($left)

  # ------------------------------------------------------------ ползунки
  $ui.Num = @{}
  $ui.Track = @{}
  $ui.Info = @{}

  $groupFont = [System.Drawing.Font]::new('Segoe UI', [single]9)
  $labelFont = [System.Drawing.Font]::new('Segoe UI', [single]9)
  $smallFont = [System.Drawing.Font]::new('Segoe UI', [single]8.25)

  foreach ($channel in @(
      @{ Number = '1'; Group = 0; Offset = 'A1'; Amplitude = 'B1'; Caption = 'ЦАП1 · A1 + B1·sin' },
      @{ Number = '2'; Group = 1; Offset = 'A2'; Amplitude = 'B2'; Caption = 'ЦАП2 · A2 − B2·sin' })) {

    $box = New-Object System.Windows.Forms.GroupBox
    $box.Text = ' ' + $channel.Caption + ' '
    $box.Location = New-Object System.Drawing.Point 4, (4 + $channel.Group * 166)
    $box.Size = New-Object System.Drawing.Size 416, 162
    $box.BackColor = $colors.Bg
    $box.Font = $groupFont
    $box.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $ui["Group$($channel.Number)"] = $box

    $rows = @(
      @{ Name = $channel.Offset; Caption = 'Смещение ' + $channel.Offset; Y = 28 },
      @{ Name = $channel.Amplitude; Caption = 'Амплитуда ' + $channel.Amplitude; Y = 68 }
    )

    foreach ($row in $rows) {
      $name = $row.Name
      $caption = $row.Caption
      $y = $row.Y

      $text = New-SineLabel -Text $caption -X 12 -Y ($y + 4) -Width 88 -Height 20 -Font $labelFont
      $track = New-Object System.Windows.Forms.TrackBar
      $track.Location = New-Object System.Drawing.Point 104, $y
      $track.Size = New-Object System.Drawing.Size 214, 30
      $track.Minimum = $script:SineCodeMin
      $track.Maximum = $script:SineCodeMax
      $track.SmallChange = 1
      $track.LargeChange = 64
      $track.TickStyle = [System.Windows.Forms.TickStyle]::None
      $track.Value = [int]$settings.Levels[$name]
      $track.Name = 'Track' + $name

      $num = New-Object System.Windows.Forms.NumericUpDown
      $num.Location = New-Object System.Drawing.Point 322, ($y + 4)
      $num.Size = New-Object System.Drawing.Size 76, 24
      $num.Minimum = [decimal]$script:SineCodeMin
      $num.Maximum = [decimal]$script:SineCodeMax
      $num.Increment = [decimal]1
      $num.Value = [decimal]$settings.Levels[$name]
      $num.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
      $num.Name = 'Num' + $name

      $box.Controls.AddRange(@($text, $track, $num))
      $ui.Num[$name] = $num
      $ui.Track[$name] = $track
      $ui.Tip.SetToolTip($track, 'Код ЦАП 0…4095. Изменение уходит на прибор автоматически.')
      $ui.Tip.SetToolTip($num, 'Точное значение 0…4095. Enter или стрелки применяют сразу.')
    }

    $info = New-SineLabel -Text '' -X 12 -Y 104 -Width 392 -Height 52 -Font $smallFont -Color $colors.Muted `
      -Align 'TopLeft'
    $info.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $box.Controls.Add($info)
    $ui.Info[$channel.Number] = $info

    $left.Controls.Add($box)
  }

  # Генератор: обе синусоиды с одной частотой и фаза ЦАП2 относительно ЦАП1.
  $gen = New-Object System.Windows.Forms.GroupBox
  $gen.Text = ' Генератор · частота и фаза ЦАП2 '
  $gen.Location = New-Object System.Drawing.Point 4, 336
  $gen.Size = New-Object System.Drawing.Size 416, 88
  $gen.BackColor = $colors.Bg
  $gen.Font = $groupFont
  $gen.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $ui.GroupGen = $gen

  $freqText = New-SineLabel -Text 'Частота, Гц' -X 12 -Y 24 -Width 88 -Height 20 -Font $labelFont
  $ui.Track['F'] = New-Object System.Windows.Forms.TrackBar
  $ui.Track['F'].Location = New-Object System.Drawing.Point 104, 20
  $ui.Track['F'].Size = New-Object System.Drawing.Size 214, 30
  $ui.Track['F'].Minimum = $script:SineFreqMin
  $ui.Track['F'].Maximum = $script:SineFreqMax
  $ui.Track['F'].SmallChange = 1
  $ui.Track['F'].LargeChange = 500
  $ui.Track['F'].TickStyle = [System.Windows.Forms.TickStyle]::None
  $ui.Track['F'].Value = [int]$settings.Levels['F']
  $ui.Track['F'].Name = 'TrackF'

  $ui.Num['F'] = New-Object System.Windows.Forms.NumericUpDown
  $ui.Num['F'].Location = New-Object System.Drawing.Point 322, 22
  $ui.Num['F'].Size = New-Object System.Drawing.Size 76, 24
  $ui.Num['F'].Minimum = [decimal]$script:SineFreqMin
  $ui.Num['F'].Maximum = [decimal]$script:SineFreqMax
  $ui.Num['F'].Increment = [decimal]1
  $ui.Num['F'].Value = [decimal]$settings.Levels['F']
  $ui.Num['F'].TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
  $ui.Num['F'].Name = 'NumF'

  $phaseText = New-SineLabel -Text 'Фаза ЦАП2, °' -X 12 -Y 54 -Width 88 -Height 20 -Font $labelFont
  $ui.Track['PH'] = New-Object System.Windows.Forms.TrackBar
  $ui.Track['PH'].Location = New-Object System.Drawing.Point 104, 50
  $ui.Track['PH'].Size = New-Object System.Drawing.Size 214, 30
  $ui.Track['PH'].Minimum = -$script:SinePhaseMax
  $ui.Track['PH'].Maximum = $script:SinePhaseMax
  $ui.Track['PH'].SmallChange = 1
  $ui.Track['PH'].LargeChange = 50
  $ui.Track['PH'].TickStyle = [System.Windows.Forms.TickStyle]::None
  $ui.Track['PH'].Value = [int]$settings.Levels['PH']
  $ui.Track['PH'].Name = 'TrackPH'

  $ui.Num['PH'] = New-Object System.Windows.Forms.NumericUpDown
  $ui.Num['PH'].Location = New-Object System.Drawing.Point 322, 52
  $ui.Num['PH'].Size = New-Object System.Drawing.Size 76, 24
  $ui.Num['PH'].DecimalPlaces = 1
  $ui.Num['PH'].Minimum = [decimal](-$script:SinePhaseMax / 10.0)
  $ui.Num['PH'].Maximum = [decimal]($script:SinePhaseMax / 10.0)
  $ui.Num['PH'].Increment = [decimal]0.5
  $ui.Num['PH'].Value = [decimal]([math]::Round($settings.Levels['PH'] / 10.0, 1))
  $ui.Num['PH'].TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
  $ui.Num['PH'].Name = 'NumPH'

  $gen.Controls.AddRange(@($freqText, $ui.Track['F'], $ui.Num['F'], $phaseText, $ui.Track['PH'], $ui.Num['PH']))
  $ui.Tip.SetToolTip($ui.Track['F'], 'Общая частота обеих синусоид: 100…20000 Гц. Прибор подтягивает её плавно.')
  $ui.Tip.SetToolTip($ui.Num['F'], 'Точная частота 100…20000 Гц. Обе синусоиды имеют одну частоту.')
  $ui.Tip.SetToolTip($ui.Track['PH'], 'Сдвиг фазы ЦАП2 относительно ЦАП1: −45…+45°. Изменяется плавно.')
  $ui.Tip.SetToolTip($ui.Num['PH'], 'Точная фаза ЦАП2 в градусах: −45,0…+45,0°.')
  $left.Controls.Add($gen)

  $ui.SyncA = New-Object System.Windows.Forms.CheckBox
  $ui.SyncA.Text = 'A2 = A1'
  $ui.SyncA.Location = New-Object System.Drawing.Point 12, 426
  $ui.SyncA.Size = New-Object System.Drawing.Size 120, 22
  $ui.SyncA.Font = $labelFont
  $left.Controls.Add($ui.SyncA)

  $ui.SyncB = New-Object System.Windows.Forms.CheckBox
  $ui.SyncB.Text = 'B2 = B1'
  $ui.SyncB.Location = New-Object System.Drawing.Point 148, 426
  $ui.SyncB.Size = New-Object System.Drawing.Size 120, 22
  $ui.SyncB.Font = $labelFont
  $left.Controls.Add($ui.SyncB)



  # ---------------------------------------------------------------- низ
  $bottom = New-Object System.Windows.Forms.Panel
  $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
  $bottom.Height = 168
  $bottom.Width = 1000
  $bottom.BackColor = $colors.Bg
  $ui.Bottom = $bottom

  $ui.BtnApply = New-SineButton -Text 'Применить всё' -X 12 -Y 8 -Width 128 -Height 32
  $ui.BtnApply.BackColor = $colors.Accent
  $ui.BtnApply.ForeColor = [System.Drawing.Color]::White
  $ui.BtnApply.Font = [System.Drawing.Font]::new('Segoe UI', [single]9, [System.Drawing.FontStyle]::Bold)
  $ui.BtnApply.FlatAppearance.BorderColor = $colors.Accent

  $ui.BtnReset = New-SineButton -Text 'Сброс: 2048/1000 · 8 кГц · 0°' -X 148 -Y 8 -Width 210 -Height 32
  $ui.BtnClearLog = New-SineButton -Text 'Очистить журнал' -X 366 -Y 8 -Width 128 -Height 32

  $ui.DeviceLabel = New-SineLabel -Text 'На приборе (по ACK): A1 = —, B1 = —, A2 = —, B2 = —, F = —, PH = —' `
    -X 12 -Y 46 -Width 976 -Height 20 -Color $colors.Muted -Font $smallFont
  $ui.DeviceLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $ui.Tip.SetToolTip($ui.DeviceLabel, 'Изменения уходят на прибор автоматически через 0,1 с. Прибор не сообщает текущие значения: известны только подтверждённые ACK.')
  $ui.Tip.SetToolTip($ui.BtnApply, 'Передать все шесть параметров сразу: A1, B1, A2, B2, частоту и фазу.')

  $log = New-Object System.Windows.Forms.RichTextBox
  $log.Location = New-Object System.Drawing.Point 12, 70
  $log.Size = New-Object System.Drawing.Size 976, 88
  $log.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $log.ReadOnly = $true
  $log.BackColor = [System.Drawing.Color]::White
  $log.ForeColor = $colors.Text
  $log.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $log.Font = [System.Drawing.Font]::new('Consolas', [single]8.25)
  $log.WordWrap = $true
  $log.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
  $log.DetectUrls = $false
  $log.HideSelection = $false
  $ui.Log = $log

  $bottom.Controls.AddRange(@($ui.BtnApply, $ui.BtnReset, $ui.BtnClearLog, $ui.DeviceLabel, $log))

  $form.Controls.Add($content)
  $form.Controls.Add($bottom)
  $form.Controls.Add($top)

  # -------------------------------------------------------- рисование
  $ui.FontAxis = [System.Drawing.Font]::new('Segoe UI', [single]8)
  $ui.FontLegend = [System.Drawing.Font]::new('Segoe UI', [single]8.75)
  $ui.PenGrid = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(228, 230, 235), [single]1)
  $ui.PenAxis = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(188, 192, 200), [single]1)
  $ui.PenCh1 = [System.Drawing.Pen]::new($colors.Ch1, [single]2)
  $ui.PenCh2 = [System.Drawing.Pen]::new($colors.Ch2, [single]2)
  $ui.PenOffset1 = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(110, $colors.Ch1), [single]1)
  $ui.PenOffset1.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
  $ui.PenOffset2 = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(110, $colors.Ch2), [single]1)
  $ui.PenOffset2.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
  $ui.BrushMuted = [System.Drawing.SolidBrush]::new($colors.Muted)
  $ui.BrushCh1 = [System.Drawing.SolidBrush]::new($colors.Ch1)
  $ui.BrushCh2 = [System.Drawing.SolidBrush]::new($colors.Ch2)
  $ui.BrushError = [System.Drawing.SolidBrush]::new($colors.Error)
  $ui.BrushOk = [System.Drawing.SolidBrush]::new($colors.Ok)

  $preview.Add_Paint({
      param($sender, $eventArgs)
      Draw-SinePreview -Graphics $eventArgs.Graphics -Area $sender.ClientRectangle
    })

  # ------------------------------------------------------------ таймеры
  $ui.SendTimer = New-Object System.Windows.Forms.Timer
  $ui.SendTimer.Interval = 100
  $ui.SendTimer.Add_Tick({ Invoke-SineApply })

  $ui.RxTimer = New-Object System.Windows.Forms.Timer
  $ui.RxTimer.Interval = 40
  $ui.RxTimer.Add_Tick({ Update-SineUi })

  # ---------------------------------------------------------- обработчики
  foreach ($name in $script:SineLevelNames) {
    $handler = New-SineLevelHandler -Name $name
    $ui.Num[$name].Add_ValueChanged($handler)
    $ui.Track[$name].Add_ValueChanged($handler)
  }

  $ui.Num['F'].Add_ValueChanged({ param($sender, $eventArgs) Set-SineUiFrequency -Value ([int]$sender.Value) })
  $ui.Track['F'].Add_ValueChanged({ param($sender, $eventArgs) Set-SineUiFrequency -Value ([int]$sender.Value) })
  $ui.Num['PH'].Add_ValueChanged({ param($sender, $eventArgs) Set-SineUiPhase -Tenths ([int][math]::Round([double]$sender.Value * 10.0)) })
  $ui.Track['PH'].Add_ValueChanged({ param($sender, $eventArgs) Set-SineUiPhase -Tenths ([int]$sender.Value) })

  $ui.SyncA.Add_CheckedChanged({
      $ui = $script:SineUi
      if (-not $ui -or $ui.Suppress) { return }
      $ui.Num['A2'].Enabled = (-not $ui.SyncA.Checked)
      $ui.Track['A2'].Enabled = (-not $ui.SyncA.Checked)
      if ($ui.SyncA.Checked) { Set-SineUiLevel -Name 'A2' -Value ([int]$ui.Num['A1'].Value) }
      else { Update-SineDerived }
    })

  $ui.SyncB.Add_CheckedChanged({
      $ui = $script:SineUi
      if (-not $ui -or $ui.Suppress) { return }
      $ui.Num['B2'].Enabled = (-not $ui.SyncB.Checked)
      $ui.Track['B2'].Enabled = (-not $ui.SyncB.Checked)
      if ($ui.SyncB.Checked) { Set-SineUiLevel -Name 'B2' -Value ([int]$ui.Num['B1'].Value) }
      else { Update-SineDerived }
    })

  $ui.Vref.Add_ValueChanged({ Update-SineDerived })

  $ui.BtnRefresh.Add_Click({ Update-SinePortList })
  $ui.BtnConnect.Add_Click({
      if ($script:SineSession) { Disconnect-SineInstrument }
      else { [void](Connect-SineInstrument) }
    })

  $ui.BtnApply.Add_Click({
      Add-SineLog 'передаю все шесть параметров на прибор' 'muted'
      Invoke-SineApply -Force
    })

  $ui.BtnReset.Add_Click({
      $ui = $script:SineUi
      $defaults = Get-SineDefaults
      $ui.Suppress = $true
      try {
        foreach ($name in $script:SineLevelNames) {
          $ui.Num[$name].Value = [decimal]$defaults[$name]
          $ui.Track[$name].Value = [int]$defaults[$name]
        }
        $ui.Num['F'].Value = [decimal]$defaults['F']
        $ui.Track['F'].Value = [int]$defaults['F']
        $ui.Num['PH'].Value = [decimal]0
        $ui.Track['PH'].Value = 0
      } finally { $ui.Suppress = $false }
      Update-SineDerived
      $ui.SendTimer.Stop()
      $ui.SendTimer.Start()
      Add-SineLog ('по умолчанию: ' + (Get-SineParamsText -Params $defaults)) 'muted'
    })

  $ui.BtnClearLog.Add_Click({ $ui.Log.Clear() })

  $form.Add_Shown({
      $ui = $script:SineUi
      if (-not $ui -or $ui.ShownOnce) { return }
      $ui.ShownOnce = $true

      Update-SinePortList
      if (-not $ui.AutoConnect) { return }
      $port = $ui.InitialPort
      if (-not $port -and $ui.Instrument) { $port = $ui.Instrument.Port }
      if ($port) {
        $ui.PortCombo.Text = $port
        [void](Connect-SineInstrument -PortName $port)
      } else {
        Set-SineStatus 'прибор не найден — подключите USB и нажмите «Обновить»' 'warn'
      }
    })

  $form.Add_FormClosing({
      $ui = $script:SineUi
      try { $ui.SendTimer.Stop(); $ui.RxTimer.Stop() } catch { }
      if ($script:SineSession) {
        try { Close-SineSession -Session $script:SineSession } catch { }
        $script:SineSession = $null
      }
      $savedPort = $ui.PortName
      if (-not $savedPort) { $savedPort = [string]$ui.PortCombo.Text }
      Save-SineSettings -Port $savedPort -Vref ([double]$ui.Vref.Value) -Levels (Get-SineUiLevels) -Frequency ([int]$ui.Num['F'].Value) -PhaseTenths ([int]$ui.Track['PH'].Value)
    })

  # --------------------------------------------------- начальное состояние
  $ports = @(Get-SineComPorts)
  foreach ($port in $ports) { [void]$ui.PortCombo.Items.Add($port) }
  # Порт выбираем только явно: подключаться к случайному COM-порту нельзя,
  # иначе ASCII-команды уйдут чужому устройству. Прибор ищется в Shown.
  $initial = $null
  if ($PortName) { $initial = $PortName }
  elseif ($settings.Port) { $initial = $settings.Port }
  if ($initial) { $ui.PortCombo.Text = $initial }

  Set-SineStatus '● Не подключено' 'muted'
  Update-SineDerived

  return $ui
}

# -----------------------------------------------------------------------------
#  Журнал и статус
# -----------------------------------------------------------------------------

function Add-SineLog {
  param([string]$Text, [string]$Kind = 'muted')
  $ui = $script:SineUi
  if (-not $ui -or -not $ui.Log) { return }

  $color = switch ($Kind) {
    'ok' { $script:SineColors.Ok }
    'error' { $script:SineColors.Error }
    'warn' { $script:SineColors.Warn }
    'busy' { $script:SineColors.Busy }
    'accent' { $script:SineColors.Accent }
    'text' { $script:SineColors.Text }
    default { $script:SineColors.Muted }
  }

  $box = $ui.Log
  $stamp = (Get-Date).ToString('HH:mm:ss')
  $box.SelectionStart = $box.TextLength
  $box.SelectionLength = 0
  $box.SelectionColor = $color
  $box.AppendText(('[{0}] {1}{2}' -f $stamp, $Text, "`n"))
  $box.SelectionColor = $box.ForeColor
  $box.SelectionStart = $box.TextLength
  $box.ScrollToCaret()

  if ($box.TextLength -gt 120000) {
    $box.Select(0, 40000)
    $box.SelectedText = ''
  }
}

function Set-SineStatus {
  param([string]$Text, [string]$Kind = 'muted')
  $ui = $script:SineUi
  if (-not $ui -or -not $ui.StatusLabel) { return }

  $color = switch ($Kind) {
    'ok' { $script:SineColors.Ok }
    'error' { $script:SineColors.Error }
    'warn' { $script:SineColors.Warn }
    'busy' { $script:SineColors.Busy }
    'accent' { $script:SineColors.Accent }
    default { $script:SineColors.Muted }
  }

  if ($ui.StatusLabel.Text -ne $Text) { $ui.StatusLabel.Text = $Text }
  if ($ui.StatusLabel.ForeColor -ne $color) { $ui.StatusLabel.ForeColor = $color }
  if ($ui.Tip) { $ui.Tip.SetToolTip($ui.StatusLabel, $Text) }
}

function Get-SineConnectionText {
  <# Подпись подключения: порт, имя прибора и версия прошивки, как их прислал прибор. #>
  $ui = $script:SineUi
  if (-not $ui -or -not $script:SineSession) { return '● Не подключено' }

  $parts = New-Object System.Collections.Generic.List[string]
  if ($ui.DeviceName) { $parts.Add([string]$ui.DeviceName) }
  if ($ui.Firmware) { $parts.Add('прошивка ' + $ui.Firmware) }

  if ($parts.Count -eq 0) { return ('● {0} — подключено' -f $ui.PortName) }
  return ('● {0} — {1}' -f $ui.PortName, ($parts -join ', '))
}

function Update-SineDeviceLine {
  $ui = $script:SineUi
  if (-not $ui -or -not $ui.DeviceLabel) { return }
  if (-not $script:SineSession) {
    $ui.DeviceLabel.Text = 'На приборе (по ACK): A1 = —, B1 = —, A2 = —, B2 = —, F = —, PH = —'
    return
  }
  $ui.DeviceLabel.Text = 'На приборе (по ACK): ' + (Get-SineParamsText -Params $script:SineSession.Acked)
}

# -----------------------------------------------------------------------------
#  Значения из окна
# -----------------------------------------------------------------------------

function Get-SineUiLevels {
  $ui = $script:SineUi
  if (-not $ui) { throw 'Окно ещё не создано' }
  return @{
    A1 = [int]$ui.Num['A1'].Value
    B1 = [int]$ui.Num['B1'].Value
    A2 = [int]$ui.Num['A2'].Value
    B2 = [int]$ui.Num['B2'].Value
  }
}

function Get-SineUiParams {
  <# Все шесть параметров из окна: четыре уровня, частота и фаза в десятых. #>
  $ui = $script:SineUi
  if (-not $ui) { throw 'Окно ещё не создано' }
  return @{
    A1 = [int]$ui.Num['A1'].Value
    B1 = [int]$ui.Num['B1'].Value
    A2 = [int]$ui.Num['A2'].Value
    B2 = [int]$ui.Num['B2'].Value
    F  = [int]$ui.Num['F'].Value
    PH = [int]$ui.Track['PH'].Value
  }
}

function Format-SineValue {
  param([object]$Value, [string]$Format = '0.000')
  if ($null -eq $Value) { return '—' }
  return ([double]$Value).ToString($Format, [System.Globalization.CultureInfo]::CurrentCulture)
}

function Set-SineUiLevel {
  <# Новое значение из ползунка/поля: обновить поля, связанный канал и отправить. #>
  param([string]$Name, [int]$Value)
  $ui = $script:SineUi
  if (-not $ui -or $ui.Suppress) { return }

  if ($Value -lt $script:SineCodeMin) { $Value = $script:SineCodeMin }
  if ($Value -gt $script:SineCodeMax) { $Value = $script:SineCodeMax }

  $ui.Suppress = $true
  try {
    if ([int]$ui.Num[$Name].Value -ne $Value) { $ui.Num[$Name].Value = [decimal]$Value }
    if ([int]$ui.Track[$Name].Value -ne $Value) { $ui.Track[$Name].Value = $Value }

    $partner = $null
    if ($Name -eq 'A1' -and $ui.SyncA.Checked) { $partner = 'A2' }
    elseif ($Name -eq 'A2' -and $ui.SyncA.Checked) { $partner = 'A1' }
    elseif ($Name -eq 'B1' -and $ui.SyncB.Checked) { $partner = 'B2' }
    elseif ($Name -eq 'B2' -and $ui.SyncB.Checked) { $partner = 'B1' }

    if ($partner) {
      if ([int]$ui.Num[$partner].Value -ne $Value) { $ui.Num[$partner].Value = [decimal]$Value }
      if ([int]$ui.Track[$partner].Value -ne $Value) { $ui.Track[$partner].Value = $Value }
    }
  } finally { $ui.Suppress = $false }

  Update-SineDerived
  $ui.SendTimer.Stop()
  $ui.SendTimer.Start()
}

function Set-SineUiFrequency {
  <# Новая частота: обновить поле и ползунок, затем плавно отправить. #>
  param([int]$Value)
  $ui = $script:SineUi
  if (-not $ui -or $ui.Suppress) { return }
  if ($Value -lt $script:SineFreqMin) { $Value = $script:SineFreqMin }
  if ($Value -gt $script:SineFreqMax) { $Value = $script:SineFreqMax }
  $ui.Suppress = $true
  try {
    if ([int]$ui.Num['F'].Value -ne $Value) { $ui.Num['F'].Value = [decimal]$Value }
    if ([int]$ui.Track['F'].Value -ne $Value) { $ui.Track['F'].Value = $Value }
  } finally { $ui.Suppress = $false }
  Update-SineDerived
  $ui.SendTimer.Stop()
  $ui.SendTimer.Start()
}

function Set-SineUiPhase {
  <# Новая фаза ЦАП2 в десятых градуса; поле показывает градусы. #>
  param([int]$Tenths)
  $ui = $script:SineUi
  if (-not $ui -or $ui.Suppress) { return }
  if ($Tenths -lt -$script:SinePhaseMax) { $Tenths = -$script:SinePhaseMax }
  if ($Tenths -gt $script:SinePhaseMax) { $Tenths = $script:SinePhaseMax }
  $ui.Suppress = $true
  try {
    if ([int]$ui.Track['PH'].Value -ne $Tenths) { $ui.Track['PH'].Value = $Tenths }
    $degrees = [decimal]([math]::Round($Tenths / 10.0, 1))
    if ([decimal]$ui.Num['PH'].Value -ne $degrees) { $ui.Num['PH'].Value = $degrees }
  } finally { $ui.Suppress = $false }
  Update-SineDerived
  $ui.SendTimer.Stop()
  $ui.SendTimer.Start()
}

function Update-SineDerived {
  <# Пересчитать подписи, предпросмотр и сводку по текущим четырём уровням. #>
  $ui = $script:SineUi
  if (-not $ui) { return }

  $params = Get-SineUiParams
  $vref = [double]$ui.Vref.Value
  $summary = Get-SineSummary -A1 $params.A1 -B1 $params.B1 -A2 $params.A2 -B2 $params.B2 `
    -Vref $vref -Frequency $params.F -PhaseTenths $params.PH
  $ui.Summary = $summary
  $levels = $params

  $a1 = $levels.A1; $b1 = $levels.B1
  $a2 = $levels.A2; $b2 = $levels.B2

  $ui.Info['1'].Text = ('Смещение A1 = {0} ({1} В) · амплитуда B1 = {2} ({3} В)' -f
    $a1, (Format-SineValue $summary.V1Offset), $b1, (Format-SineValue ($vref * $b1 / 4095.0))) +
    "`n" + ('ЦАП1: {0}…{1} кодов ({2}…{3} В)' -f
    $summary.Code1Min, $summary.Code1Max, (Format-SineValue $summary.V1Min), (Format-SineValue $summary.V1Max))

  $ui.Info['2'].Text = ('Смещение A2 = {0} ({1} В) · амплитуда B2 = {2} ({3} В)' -f
    $a2, (Format-SineValue $summary.V2Offset), $b2, (Format-SineValue ($vref * $b2 / 4095.0))) +
    "`n" + ('ЦАП2: {0}…{1} кодов ({2}…{3} В)' -f
    $summary.Code2Min, $summary.Code2Max, (Format-SineValue $summary.V2Min), (Format-SineValue $summary.V2Max))

  $ui.LblRanges.Text = ('ЦАП1 {0}…{1} ({2}…{3} В) · ЦАП2 {4}…{5} ({6}…{7} В)' -f
    $summary.Code1Min, $summary.Code1Max, (Format-SineValue $summary.V1Min), (Format-SineValue $summary.V1Max),
    $summary.Code2Min, $summary.Code2Max, (Format-SineValue $summary.V2Min), (Format-SineValue $summary.V2Max))

  $ui.LblDiff.Text = ('ЦАП1 − ЦАП2: амплитуда {0} кодов ({1} В) · смещение {2} кодов ({3} В)' -f
    ([int][math]::Round($summary.DiffAmplitude)), (Format-SineValue $summary.VDiffAmplitude),
    ($a1 - $a2), (Format-SineValue $summary.VDiffOffset))

  $issues = New-Object System.Collections.Generic.List[string]
  if ($levels.A1 - $levels.B1 -lt 0) { $issues.Add(('A1−B1 = {0} < 0' -f ($levels.A1 - $levels.B1))) }
  if ($levels.A1 + $levels.B1 -gt 4095) { $issues.Add(('A1+B1 = {0} > 4095' -f ($levels.A1 + $levels.B1))) }
  if ($levels.A2 - $levels.B2 -lt 0) { $issues.Add(('A2−B2 = {0} < 0' -f ($levels.A2 - $levels.B2))) }
  if ($levels.A2 + $levels.B2 -gt 4095) { $issues.Add(('A2+B2 = {0} > 4095' -f ($levels.A2 + $levels.B2))) }

  if ($issues.Count -gt 0) {
    $ui.LblClip.Text = 'Ограничение: ' + ($issues -join '; ') + ' — вершины обрезаны'
    $ui.LblClip.ForeColor = $script:SineColors.Error
  } else {
    $ui.LblClip.Text = 'Все точки в пределах 0…4095 — сигнал без ограничения'
    $ui.LblClip.ForeColor = $script:SineColors.Ok
  }

  $culture = [System.Globalization.CultureInfo]::CurrentCulture
  $phaseTenths = [int]$params.PH
  $phaseSign = '+'
  if ($phaseTenths -lt 0) { $phaseSign = '-'; $phaseTenths = -$phaseTenths }
  $ui.LblNote.Text = ('{0} Гц · 32 точки · обновление ЦАП {1} кГц · фаза ЦАП2 {2}{3}°' -f
    $params.F, (($params.F * 32 / 1000.0).ToString('0', $culture)),
    $phaseSign, (($phaseTenths / 10.0).ToString('0.0', $culture)))

  $ui.Preview.Invalidate()
}

# -----------------------------------------------------------------------------
#  Отправка на прибор
# -----------------------------------------------------------------------------

function Invoke-SineApply {
  <#
    Передать на прибор изменившиеся параметры. Force - передать все шесть
    (например, после подключения, когда значения на приборе неизвестны).
  #>
  param([switch]$Force)
  $ui = $script:SineUi
  if (-not $ui) { return }

  $ui.SendTimer.Stop()

  if (-not $script:SineSession) {
    if (-not $ui.WarnedOffline) {
      Add-SineLog 'прибор не подключён: ползунки пока меняют только предпросмотр' 'warn'
      $ui.WarnedOffline = $true
    }
    return
  }

  if ($Force) { $ui.LastQueued = @{ A1 = $null; B1 = $null; A2 = $null; B2 = $null; F = $null; PH = $null } }

  $params = Get-SineUiParams
  foreach ($name in $script:SineParamNames) {
    $value = [int]$params[$name]
    if ($ui.LastQueued[$name] -eq $value) { continue }

    try {
      $text = Send-SineParam -Session $script:SineSession -Name $name -Value $value
      $ui.LastQueued[$name] = $value
      Add-SineLog ('→ ' + $text) 'muted'
    } catch {
      Add-SineLog ('ошибка отправки {0}: {1}' -f $name, $_.Exception.Message) 'error'
      Disconnect-SineInstrument
      return
    }
  }

  $ui.WarnedOffline = $false
}

# -----------------------------------------------------------------------------
#  Подключение
# -----------------------------------------------------------------------------

function Update-SinePortList {
  $ui = $script:SineUi
  if (-not $ui) { return }

  $current = [string]$ui.PortCombo.Text
  $ui.PortCombo.BeginUpdate()
  try {
    $ui.PortCombo.Items.Clear()
    foreach ($port in @(Get-SineComPorts)) { [void]$ui.PortCombo.Items.Add($port) }
  } finally { $ui.PortCombo.EndUpdate() }

  if ($current) { $ui.PortCombo.Text = $current }

  $instrument = Find-SineInstrumentPort
  $ui.Instrument = $instrument
  if ($instrument) {
    if (-not $current) { $ui.PortCombo.Text = $instrument.Port }
    if (-not $script:SineSession) {
      Set-SineStatus ('● Не подключено — прибор найден: {0}' -f $instrument.Port) 'muted'
    }
  } elseif (-not $script:SineSession) {
    if ($current) { Set-SineStatus '● Не подключено' 'muted' }
    else { Set-SineStatus 'прибор не найден — выберите порт вручную' 'warn' }
  }
}

function Connect-SineInstrument {
  <# Открыть порт и начать обмен. Возвращает $true при успехе. #>
  param([string]$PortName)
  $ui = $script:SineUi
  if (-not $ui) { throw 'Окно ещё не создано' }
  if ($script:SineSession) { return $true }

  $name = $PortName
  if (-not $name) { $name = [string]$ui.PortCombo.Text }
  $match = [regex]::Match([string]$name, '(COM\d+)')
  if ($match.Success) {
    $name = $match.Groups[1].Value
  } else {
    Set-SineStatus ('не похоже на COM-порт: «{0}»' -f $name) 'warn'
    return $false
  }
  $ui.PortCombo.Text = $name

  Set-SineStatus ('Подключение к {0}…' -f $name) 'busy'
  try {
    if ($ui.TransportFactory) { $link = & $ui.TransportFactory $name }
    else { $link = New-SineSerialLink -PortName $name }
  } catch {
    Set-SineStatus ('{0}: {1}' -f $name, $_.Exception.Message) 'error'
    Add-SineLog ('не удалось открыть {0}: {1}' -f $name, $_.Exception.Message) 'error'
    return $false
  }

  $script:SineSession = New-SineSession -Link $link
  $ui.PortName = $name
  $ui.DeviceName = $null
  $ui.Firmware = $null
  $ui.LastQueued = @{ A1 = $null; B1 = $null; A2 = $null; B2 = $null; F = $null; PH = $null }
  $ui.WarnedOffline = $false
  $ui.BtnConnect.Text = 'Отключить'
  $ui.PortCombo.Enabled = $false
  $ui.BtnRefresh.Enabled = $false
  $ui.DeviceLabel.Text = 'На приборе (по ACK): A1 = —, B1 = —, A2 = —, B2 = —, F = —, PH = —'
  $ui.RxTimer.Start()

  Set-SineStatus (Get-SineConnectionText) 'ok'
  Add-SineLog ('порт {0} открыт; при первом изменении будут переданы все шесть параметров' -f $name) 'ok'
  return $true
}

function Disconnect-SineInstrument {
  param([switch]$Quiet)
  $ui = $script:SineUi

  if ($script:SineSession) {
    try { Close-SineSession -Session $script:SineSession } catch { }
    $script:SineSession = $null
    if (-not $Quiet) { Add-SineLog 'порт закрыт' 'muted' }
  }

  if (-not $ui) { return }
  try { $ui.SendTimer.Stop(); $ui.RxTimer.Stop() } catch { }
  $ui.LastQueued = @{ A1 = $null; B1 = $null; A2 = $null; B2 = $null; F = $null; PH = $null }
  $ui.DeviceName = $null
  $ui.Firmware = $null
  $ui.BtnConnect.Text = 'Подключить'
  $ui.PortCombo.Enabled = $true
  $ui.BtnRefresh.Enabled = $true

  if (-not $Quiet) {
    Set-SineStatus '● Не подключено' 'muted'
    $ui.StateLabel.Text = 'Состояние: —'
    $ui.StateLabel.ForeColor = $script:SineColors.Muted
    $ui.TelemetryLabel.Text = 'Z = —   X = —'
    $ui.LastState = $null
    Update-SineDeviceLine
  }
}

# -----------------------------------------------------------------------------
#  Приём телеметрии
# -----------------------------------------------------------------------------

function Update-SineUi {
  <# Тик таймера: забрать строки прибора и обновить окно. #>
  $ui = $script:SineUi
  if (-not $ui -or -not $script:SineSession) { return }
  $session = $script:SineSession

  $events = @()
  try {
    # Receive-SineEvents отдаёт массив одним объектом: @() вокруг него
    # завернул бы весь массив в один элемент и обработка увидела бы не строки,
    # а набор событий целиком.
    $events = Receive-SineEvents -Session $session
  } catch {
    Add-SineLog ('связь потеряна: ' + $_.Exception.Message) 'error'
    Disconnect-SineInstrument
    return
  }

  foreach ($event in $events) {
    switch ($event.Kind) {
      'ack' {
        Add-SineLog ('← ACK={0}' -f $event.Text.Substring(4)) 'ok'
        Update-SineDeviceLine
      }
      'error' {
        $reason = ''
        if ($event.Reason) { $reason = ' (' + $event.Reason + ')' }
        Add-SineLog ('← ' + $event.Text + $reason) 'error'
      }
      'timeout' {
        Add-SineLog ('нет ответа на ' + $event.Text + ': команда не подтверждена') 'warn'
      }
      'state' {
        if ($ui.LastState -ne $event.State) {
          Add-SineLog ('состояние: ' + $event.State) 'busy'
          $ui.LastState = $event.State
        }
        $ru = $script:SineStateNames[$event.State]
        if ($ru) { $ui.StateLabel.Text = ('Состояние: {0} — {1}' -f $event.State, $ru) }
        else { $ui.StateLabel.Text = ('Состояние: {0}' -f $event.State) }
        if ($event.State -eq 'FAULT') { $ui.StateLabel.ForeColor = $script:SineColors.Error }
        else { $ui.StateLabel.ForeColor = $script:SineColors.Muted }
      }
      'hello' {
        $ui.DeviceName = $event.Name
        Add-SineLog ('прибор: ' + $event.Text) 'accent'
        if ($ui.ConnectionOk) { Set-SineStatus (Get-SineConnectionText) 'ok' }
      }
      'firmware' {
        $ui.Firmware = $event.Name
        Add-SineLog ('прошивка ' + $event.Name) 'muted'
        if ($ui.ConnectionOk) { Set-SineStatus (Get-SineConnectionText) 'ok' }
      }
      'boot' {
        if (-not $ui.BootWarned) {
          Add-SineLog 'прибор в режиме обновления ПО: уровни сейчас не применяются' 'warn'
          $ui.BootWarned = $true
        }
      }
      'text' {
        if ($ui.UnknownLines -lt 6) {
          Add-SineLog ('прибор: ' + $event.Text) 'muted'
          $ui.UnknownLines++
        }
      }
    }
  }

  if ($null -ne $session.Z) {
    $x = [string]$session.X
    if ($x -eq 'NA' -or -not $x) {
      $ui.TelemetryLabel.Text = ('Z = {0}   X = NA' -f $session.Z)
    } else {
      $ui.TelemetryLabel.Text = ('Z = {0}   X = {1} мм' -f $session.Z, $x)
    }
  }

  # Прибор шлёт телеметрию 20 раз в секунду: молчание дольше 3 с — проблема.
  $age = 999.0
  if ($session.LastRx) { $age = ([datetime]::UtcNow - $session.LastRx).TotalSeconds }
  if ($age -gt 3) {
    if ($ui.ConnectionOk) {
      Set-SineStatus ('● {0} — нет данных' -f $ui.PortName) 'warn'
      $ui.ConnectionOk = $false
    }
  } else {
    if (-not $ui.ConnectionOk) {
      Set-SineStatus (Get-SineConnectionText) 'ok'
      $ui.ConnectionOk = $true
    }
  }
}

# -----------------------------------------------------------------------------
#  Предпросмотр
# -----------------------------------------------------------------------------

function Draw-SinePreview {
  <# Нарисовать две синусоиды по текущим уровням в области Area. #>
  param([System.Drawing.Graphics]$Graphics, [System.Drawing.Rectangle]$Area)

  $ui = $script:SineUi
  if (-not $ui -or -not $ui.PenCh1) { return }
  if ($Area.Width -lt 260 -or $Area.Height -lt 180) { return }

  $g = $Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear([System.Drawing.Color]::White)

  $padLeft = 50; $padRight = 64; $padTop = 30; $padBottom = 34
  [single]$plotX = $Area.X + $padLeft
  [single]$plotY = $Area.Y + $padTop
  [single]$plotW = $Area.Width - $padLeft - $padRight
  [single]$plotH = $Area.Height - $padTop - $padBottom
  [single]$plotRight = $plotX + $plotW
  [single]$plotBottom = $plotY + $plotH
  if ($plotW -lt 100 -or $plotH -lt 60) { return }

  $vref = [double]$ui.Vref.Value
  $a1 = [double]$ui.Num['A1'].Value
  $b1 = [double]$ui.Num['B1'].Value
  $a2 = [double]$ui.Num['A2'].Value
  $b2 = [double]$ui.Num['B2'].Value
  $frequency = [int]$ui.Num['F'].Value
  $phaseTenths = [int]$ui.Track['PH'].Value
  $phaseRad = [math]::PI * $phaseTenths / 1800.0

  # Сетка и подписи осей.
  foreach ($code in @(0, 1024, 2048, 3072, 4095)) {
    [single]$y = $plotBottom - ($code / 4095.0) * $plotH
    $g.DrawLine($ui.PenGrid, $plotX, $y, $plotRight, $y)
    $text = [string]$code
    $size = $g.MeasureString($text, $ui.FontAxis)
    $g.DrawString($text, $ui.FontAxis, $ui.BrushMuted, [single]($plotX - 6 - $size.Width), [single]($y - $size.Height / 2))
    if ($vref -gt 0) {
      $volts = ($vref * $code / 4095.0).ToString('0.00', [System.Globalization.CultureInfo]::CurrentCulture)
      $g.DrawString($volts, $ui.FontAxis, $ui.BrushMuted, [single]($plotRight + 6), [single]($y - $size.Height / 2))
    }
  }
  for ($i = 0; $i -le 16; $i++) {
    [single]$x = $plotX + $plotW * $i / 16.0
    $g.DrawLine($ui.PenGrid, $x, $plotY, $x, $plotBottom)
  }
  $g.DrawRectangle($ui.PenAxis, $plotX, $plotY, $plotW, $plotH)

  # Постоянные составляющие.
  [single]$yOffset1 = $plotBottom - ($a1 / 4095.0) * $plotH
  [single]$yOffset2 = $plotBottom - ($a2 / 4095.0) * $plotH
  $g.DrawLine($ui.PenOffset1, $plotX, $yOffset1, $plotRight, $yOffset1)
  $g.DrawLine($ui.PenOffset2, $plotX, $yOffset2, $plotRight, $yOffset2)

  # Два периода: 160 шагов достаточно для гладкой линии на экране.
  $samples = 161
  $points1 = New-Object 'System.Drawing.PointF[]' $samples
  $points2 = New-Object 'System.Drawing.PointF[]' $samples
  for ($i = 0; $i -lt $samples; $i++) {
    $phase = 4.0 * [math]::PI * $i / ($samples - 1)
    [single]$x = $plotX + $plotW * $i / ($samples - 1)
    $sin1 = [math]::Sin($phase)
    $sin2 = [math]::Sin($phase + $phaseRad)
    $points1[$i] = [System.Drawing.PointF]::new($x, [single]($plotBottom - (($a1 + $b1 * $sin1) / 4095.0) * $plotH))
    $points2[$i] = [System.Drawing.PointF]::new($x, [single]($plotBottom - (($a2 - $b2 * $sin2) / 4095.0) * $plotH))
  }

  $clip = [System.Drawing.RectangleF]::new($plotX, $plotY, $plotW, $plotH)
  $g.SetClip($clip)
  $g.DrawLines($ui.PenCh1, $points1)
  $g.DrawLines($ui.PenCh2, $points2)
  $g.ResetClip()

  # Легенда и подпись.
  [single]$legendY = [single]($Area.Y + 8)
  $g.DrawLine($ui.PenCh1, [single]12, $legendY + 7, [single]30, $legendY + 7)
  $g.DrawString('ЦАП1 = A1 + B1·sin', $ui.FontLegend, $ui.BrushCh1, [single]35, $legendY)
  $g.DrawLine($ui.PenCh2, [single]190, $legendY + 7, [single]208, $legendY + 7)
  $g.DrawString('ЦАП2 = A2 − B2·sin(θ+φ)', $ui.FontLegend, $ui.BrushCh2, [single]213, $legendY)

  $culture = [System.Globalization.CultureInfo]::CurrentCulture
  $periodUs = 1000000.0 / [math]::Max(1, $frequency)
  $caption = ('два периода по {0} мкс: {1} Гц, 32 точки' -f $periodUs.ToString('0.###', $culture), $frequency)
  $captionSize = $g.MeasureString($caption, $ui.FontAxis)
  $g.DrawString($caption, $ui.FontAxis, $ui.BrushMuted,
    [single]($plotX + $plotW / 2 - $captionSize.Width / 2), [single]($plotBottom + 8))
}
