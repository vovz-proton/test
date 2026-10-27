# =============================================================================
#  FirmwareUploader.ps1 - прошивальщик Prof_KIP_v5: окно для выбора файла
#  прошивки и заливки её в прибор по USB (COM-порт), без ST-LINK.
#
#  Запуск:
#    - двойной щелчок по FirmwareUploader.vbs (без окна консоли) или
#      FirmwareUploader.cmd;
#    - вручную: powershell -NoProfile -Sta -ExecutionPolicy Bypass -File tools\FirmwareUploader.ps1
#    - сразу с файлом прошивки:
#        ... -File tools\FirmwareUploader.ps1 -Firmware build\Prof_KIP_v5.hex
#
#  Протокол и раскладка флеша описаны в docs/USB_PROTOCOL.md и README.md.
# =============================================================================
param(
  [string]$Firmware,
  [string]$Port
)

$ErrorActionPreference = 'Stop'
$toolsRoot = $PSScriptRoot
$projectRoot = Split-Path $toolsRoot -Parent
$errorLog = Join-Path $env:TEMP 'Prof_KIP_v5-uploader-error.log'

function Show-UploaderFailure {
  param([string]$Text)
  try {
    [System.IO.File]::WriteAllText($errorLog, $Text, (New-Object System.Text.UTF8Encoding $true))
  } catch { }
  try {
    $message = "Не удалось запустить прошивальщик:`r`n`r`n{0}`r`n`r`nПодробности: {1}" -f $Text, $errorLog
    [void][System.Windows.Forms.MessageBox]::Show($message, 'Прошивальщик Prof_KIP_v5',
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
  } catch {
    Write-Error $Text
  }
}

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
} catch {
  Write-Error ('Не удалось загрузить WinForms: ' + $_.Exception.Message)
  exit 1
}

try {
  . (Join-Path $toolsRoot 'upload-core.ps1')
  . (Join-Path $toolsRoot 'upload-ui.ps1')

  $defaultFolder = Join-Path $projectRoot 'build'
  if (-not (Test-Path -LiteralPath $defaultFolder)) { $defaultFolder = $projectRoot }

  $ui = New-UploaderWindow -FirmwarePath $Firmware -PortName $Port -DefaultFolder $defaultFolder
  [void]$ui.Form.ShowDialog()
} catch {
  Show-UploaderFailure (($_ | Out-String).Trim())
  exit 1
}
