# =============================================================================
#  _bomtest.ps1 - проверка кодировки и синтаксиса всех .ps1 проекта.
#
#  Windows PowerShell 5.1 читает файл без метки порядка байтов (BOM) как ANSI:
#  в русской системе это CP1251, поэтому кириллица в .ps1 без BOM превращается
#  в мусор, а скрипт может вообще не разобраться. Этот скрипт проверяет, что
#  каждый .ps1 в tools и tests сохранён в UTF-8 с BOM и разбирается парсером.
#
#  Запуск:
#    powershell -NoProfile -ExecutionPolicy Bypass -File tools\_bomtest.ps1
#    powershell ... -File tools\_bomtest.ps1 -Quiet
# =============================================================================
param([switch]$Quiet)

$root = Split-Path $PSScriptRoot -Parent
$folders = @((Join-Path $root 'tools'), (Join-Path $root 'tests'))
$files = @(Get-ChildItem -Path $folders -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object FullName)
if ($files.Count -eq 0) {
  Write-Host 'Файлы .ps1 не найдены.'
  exit 1
}

$problems = 0
foreach ($file in $files) {
  $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

  $errors = $null
  $tokens = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)

  $relative = $file.FullName.Substring($root.Length + 1)
  $notes = New-Object System.Collections.Generic.List[string]
  if (-not $hasBom) { $notes.Add('нет BOM, кириллица будет испорчена') }
  if ($errors -and $errors.Count -gt 0) { $notes.Add(('ошибок разбора: {0}' -f $errors.Count)) }

  if ($notes.Count -gt 0) {
    $problems++
    Write-Host ('  [ОШИБКА] {0}: {1}' -f $relative, ($notes -join '; '))
    if ($errors) {
      foreach ($item in ($errors | Select-Object -First 3)) { Write-Host ('      ' + $item.Message) }
    }
  } elseif (-not $Quiet) {
    Write-Host ('  [ OK ]   ' + $relative)
  }
}

if ($problems -gt 0) {
  Write-Host ('Проблемных файлов: {0}.' -f $problems)
  exit 1
}
Write-Host ('Проверено файлов: {0}. Кодировка и синтаксис в порядке.' -f $files.Count)
exit 0
