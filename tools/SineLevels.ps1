# =============================================================================
#  SineLevels.ps1 - окно для амплитуд и смещений синусоид ЦАП Prof_KIP_v5.
#
#  Запуск:
#    - двойной щелчок по SineLevels.vbs (без окна консоли) или SineLevels.bat;
#    - вручную: powershell -NoProfile -Sta -ExecutionPolicy Bypass -File tools\SineLevels.ps1
#    - сразу с портом:  ... -File tools\SineLevels.ps1 -Port COM52
#    - без автоподключения:  ... -File tools\SineLevels.ps1 -NoConnect
#
#  Уровни меняются командами DA1/DB1/DA2/DB2 и подтверждаются ACK прибора.
#  Протокол: docs/USB_PROTOCOL.md, раздел «Уровни ЦАП».
# =============================================================================
param(
  [string]$Port,
  [switch]$NoConnect
)

$ErrorActionPreference = 'Stop'
$toolsRoot = $PSScriptRoot
$errorLog = Join-Path $env:TEMP 'Prof_KIP_v5-sine-levels-error.log'

function Show-SineLevelsFailure {
  param([string]$Text)
  try {
    [System.IO.File]::WriteAllText($errorLog, $Text, (New-Object System.Text.UTF8Encoding $true))
  } catch { }
  try {
    $message = "Не удалось запустить программу уровней ЦАП:`r`n`r`n{0}`r`n`r`nПодробности: {1}" -f $Text, $errorLog
    [void][System.Windows.Forms.MessageBox]::Show($message, 'Prof_KIP_v5: уровни ЦАП',
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
  } catch {
    Write-Error $Text
  }
}

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
  try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }
} catch {
  Write-Error ('Не удалось загрузить WinForms: ' + $_.Exception.Message)
  exit 1
}

try {
  . (Join-Path $toolsRoot 'sine-levels-core.ps1')
  . (Join-Path $toolsRoot 'sine-levels-ui.ps1')

  $ui = New-SineLevelsWindow -PortName $Port -NoAutoConnect:$NoConnect
  try {
    [void]$ui.Form.ShowDialog()
  } finally {
    $ui.Form.Dispose()
  }
} catch {
  Show-SineLevelsFailure (($_ | Out-String).Trim())
  exit 1
}
