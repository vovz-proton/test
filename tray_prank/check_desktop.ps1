#Requires -Version 5.1
<#
    Самопроверка tray_prank на живом рабочем столе Windows.

    Что делает:
      1) запускает tray_prank.py (pythonw.exe, без консоли);
      2) создаёт СВОЁ окно с текстовым полем, делает его активным и нажимает
         клавишу «а» (скан-код клавиши F) — программа должна напечатать «хуйна»;
      3) запускает копию с --quit-after, дожидается прощального окна, читает его
         текст и сохраняет снимок в check_dialog.png;
      4) всё за собой закрывает и печатает итог.

    Если своё окно не удалось сделать активным, шаг 1 пропускается: в чужие окна
    скрипт не печатает.

    Запуск:  powershell -ExecutionPolicy Bypass -File .\check_desktop.ps1
#>
[CmdletBinding()]
param(
    [string]$Folder
)

$ErrorActionPreference = 'Stop'

if (-not $Folder) { $Folder = $PSScriptRoot }
if (-not $Folder) { $Folder = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Folder) { throw 'не удалось определить папку со скриптом, укажите её ключом -Folder' }

$csharp = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Nat
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr hWndParent, IntPtr hWndChildAfter, string lpszClass, string lpszWindow);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);

    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_SCANCODE = 0x0008;

    public static void PressScanKey(byte scan)
    {
        keybd_event(0, scan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        System.Threading.Thread.Sleep(30);
        keybd_event(0, scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void PressVk(byte vk)
    {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static string WindowText(IntPtr hWnd)
    {
        StringBuilder sb = new StringBuilder(1024);
        SendMessage(hWnd, 0x000D, (IntPtr)sb.Capacity, sb);   // WM_GETTEXT
        return sb.ToString();
    }

    public static string AllChildTexts(IntPtr hWnd)
    {
        List<string> parts = new List<string>();
        IntPtr child = IntPtr.Zero;
        while ((child = FindWindowEx(hWnd, child, null, null)) != IntPtr.Zero)
        {
            string text = WindowText(child);
            if (text.Length > 0) parts.Add(text);
        }
        return string.Join(" | ", parts.ToArray());
    }
}
'@

$expectedText = 'хуйна'
$expectedFarewell = 'Ну блин, не понравилось чтоли?'
$appClass = 'TrayPrankWndClass_v1'
$appTitle = 'Хуйна-трей'

$results = New-Object System.Collections.ArrayList

function Add-Result([string]$name, [string]$state, [string]$info) {
    [void]$results.Add([pscustomobject]@{ Name = $name; State = $state; Info = $info })
    $color = 'Gray'
    if ($state -eq 'OK') { $color = 'Green' }
    elseif ($state -eq 'ПРОПУСК') { $color = 'Yellow' }
    elseif ($state -eq 'ОШИБКА') { $color = 'Red' }
    Write-Host ("[{0}] {1}: {2}" -f $state, $name, $info) -ForegroundColor $color
}

function Pump([int]$milliseconds) {
    $end = (Get-Date).AddMilliseconds($milliseconds)
    while ((Get-Date) -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 25
    }
}

function Wait-Foreground([IntPtr]$handle, [int]$timeoutMs) {
    $end = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        if ([Nat]::GetForegroundWindow() -eq $handle) { return $true }
        Start-Sleep -Milliseconds 40
    }
    return $false
}

$pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $pythonw) { throw 'pythonw.exe не найден в PATH' }
$program = Join-Path $Folder 'tray_prank.py'
if (-not (Test-Path -LiteralPath $program)) { throw "не найден файл $program" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition $csharp -Language CSharp

$logFile = Join-Path $Folder 'check_app.log'
$started = New-Object System.Collections.ArrayList
$form = $null

try {
    Write-Host ''
    Write-Host '=== 1. Перехват клавиши «а» и печать ===' -ForegroundColor Cyan

    Remove-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
    $app1 = Start-Process -FilePath $pythonw `
        -ArgumentList @($program, '--debug') `
        -WorkingDirectory $Folder -PassThru -WindowStyle Hidden `
        -RedirectStandardError $logFile
    [void]$started.Add($app1)
    Start-Sleep -Milliseconds 1500

    if ($app1.HasExited) {
        Add-Result 'запуск программы' 'ОШИБКА' ("процесс завершился с кодом {0}" -f $app1.ExitCode)
    } else {
        Add-Result 'запуск программы' 'OK' 'работает, значок в трее добавлен, хук установлен'
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'tray_prank: проверка'
    $form.ClientSize = New-Object System.Drawing.Size(380, 90)
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(140, 140)
    $form.TopMost = $true
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.Dock = 'Fill'
    $box.Font = New-Object System.Drawing.Font('Consolas', 14)
    [void]$form.Controls.Add($box)
    $form.Show()
    [void]$box.Focus()

    $active = $false
    for ($i = 0; $i -lt 15 -and -not $active; $i++) {
        [Nat]::PressScanKey(0x38)          # короткое нажатие Alt разрешает смену активного окна
        [void]$form.Activate()
        [void][Nat]::SetForegroundWindow($form.Handle)
        $active = Wait-Foreground $form.Handle 400
    }

    if (-not $active) {
        Add-Result 'нажатие «а»' 'ПРОПУСК' 'не удалось сделать своё окно активным — в чужие окна не печатаем'
    } else {
        $box.Clear()                       # чтобы в измерение не попали чужие символы
        Pump 250
        [Nat]::PressScanKey(0x21)          # скан-код клавиши F: «а» в русской раскладке, «a» в английской
        Pump 1300
        $typed = $box.Text
        if ($typed -eq $expectedText) {
            Add-Result 'нажатие «а»' 'OK' ("в поле появилось «{0}»" -f $typed)
        } else {
            Add-Result 'нажатие «а»' 'ОШИБКА' ("ожидалось «{0}», получено «{1}»" -f $expectedText, $typed)
        }
    }

    if ($form) { $form.Close(); $form.Dispose(); $form = $null }
    if (-not $app1.HasExited) { Stop-Process -Id $app1.Id -Force }

    Write-Host ''
    Write-Host '=== 2. Прощальное окно при выходе ===' -ForegroundColor Cyan

    $app2 = Start-Process -FilePath $pythonw `
        -ArgumentList @($program, '--debug', '--quit-after', '2') `
        -WorkingDirectory $Folder -PassThru -WindowStyle Hidden `
        -RedirectStandardError (Join-Path $Folder 'check_app2.log')
    [void]$started.Add($app2)

    $dialog = [IntPtr]::Zero
    $end = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $end -and $dialog -eq [IntPtr]::Zero) {
        $dialog = [Nat]::FindWindow('#32770', $appTitle)
        if ($dialog -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 150 }
    }

    if ($dialog -eq [IntPtr]::Zero) {
        Add-Result 'прощальное окно' 'ОШИБКА' 'окно не появилось за 15 секунд'
    } else {
        $text = [Nat]::AllChildTexts($dialog)
        if ($text -like ('*' + $expectedFarewell + '*')) {
            Add-Result 'прощальное окно' 'OK' ("текст окна: «{0}»" -f $text)
        } else {
            Add-Result 'прощальное окно' 'ОШИБКА' ("текст окна: «{0}»" -f $text)
        }

        $rect = New-Object 'Nat+RECT'
        if ([Nat]::GetWindowRect($dialog, [ref]$rect)) {
            $w = $rect.Right - $rect.Left
            $h = $rect.Bottom - $rect.Top
            if ($w -gt 0 -and $h -gt 0) {
                $bmp = New-Object System.Drawing.Bitmap($w, $h)
                $gfx = [System.Drawing.Graphics]::FromImage($bmp)
                $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
                $shot = Join-Path $Folder 'check_dialog.png'
                $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
                $gfx.Dispose(); $bmp.Dispose()
                Add-Result 'снимок окна' 'OK' $shot
            }
        }

        [void][Nat]::PostMessage($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        $end = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $end -and -not $app2.HasExited) { Start-Sleep -Milliseconds 100 }
        if ($app2.HasExited) {
            Add-Result 'выход по кнопке ОК' 'OK' 'программа завершилась'
        } else {
            Add-Result 'выход по кнопке ОК' 'ОШИБКА' 'программа не завершилась'
        }
    }

    Write-Host ''
    Write-Host '=== 3. Меню значка в трее и выход через него ===' -ForegroundColor Cyan

    $log3 = Join-Path $Folder 'check_app3.log'
    $app3 = Start-Process -FilePath $pythonw `
        -ArgumentList @($program, '--debug') `
        -WorkingDirectory $Folder -PassThru -WindowStyle Hidden `
        -RedirectStandardError $log3
    [void]$started.Add($app3)
    Start-Sleep -Milliseconds 1500

    $wnd = [IntPtr]::Zero
    $end = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $end -and $wnd -eq [IntPtr]::Zero) {
        $wnd = [Nat]::FindWindow($appClass, $null)
        if ($wnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
    }

    if ($wnd -eq [IntPtr]::Zero) {
        Add-Result 'меню трея' 'ОШИБКА' 'скрытое окно программы не найдено'
    } else {
        # посылаем себе то же сообщение, которое приходит от значка при правом клике
        [void][Nat]::PostMessage($wnd, 0x8001, [IntPtr]::Zero, [IntPtr]0x0205)

        $menu = [IntPtr]::Zero
        $end = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $end -and $menu -eq [IntPtr]::Zero) {
            [System.Windows.Forms.Application]::DoEvents()
            $menu = [Nat]::FindWindow('#32768', $null)      # класс всплывающего меню
            if ($menu -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
        }

        if ($menu -eq [IntPtr]::Zero) {
            Add-Result 'меню трея' 'ОШИБКА' 'всплывающее меню не появилось'
        } else {
            Add-Result 'меню трея' 'OK' 'меню открылось'

            $rect = New-Object 'Nat+RECT'
            if ([Nat]::GetWindowRect($menu, [ref]$rect)) {
                $w = $rect.Right - $rect.Left
                $h = $rect.Bottom - $rect.Top
                if ($w -gt 0 -and $h -gt 0) {
                    $bmp = New-Object System.Drawing.Bitmap($w, $h)
                    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
                    $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
                    $shot = Join-Path $Folder 'check_menu.png'
                    $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
                    $gfx.Dispose(); $bmp.Dispose()
                    Add-Result 'снимок меню' 'OK' $shot
                }
            }

            # вниз, вниз (через разделитель) и Enter — это пункт «Выход»
            [Nat]::PressVk(0x28); Start-Sleep -Milliseconds 250
            [Nat]::PressVk(0x28); Start-Sleep -Milliseconds 250
            [Nat]::PressVk(0x0D)

            $dialog2 = [IntPtr]::Zero
            $end = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $end -and $dialog2 -eq [IntPtr]::Zero) {
                $dialog2 = [Nat]::FindWindow('#32770', $appTitle)
                if ($dialog2 -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 150 }
            }

            if ($dialog2 -eq [IntPtr]::Zero) {
                [Nat]::PressVk(0x1B)                            # Esc: закрыть меню, программу не трогаем
                Add-Result 'выход через меню' 'ОШИБКА' 'пункт «Выход» не сработал'
            } else {
                Add-Result 'выход через меню' 'OK' 'пункт «Выход» сработал'
                [void][Nat]::PostMessage($dialog2, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                $end = (Get-Date).AddSeconds(10)
                while ((Get-Date) -lt $end -and -not $app3.HasExited) { Start-Sleep -Milliseconds 100 }
                if ($app3.HasExited) {
                    Add-Result 'завершение программы' 'OK' 'программа закрылась'
                } else {
                    Add-Result 'завершение программы' 'ОШИБКА' 'программа не закрылась'
                }
            }
        }
    }

    Write-Host ''
    Write-Host '--- отладочный вывод программы ---' -ForegroundColor DarkGray
    foreach ($file in @($logFile, (Join-Path $Folder 'check_app2.log'), $log3)) {
        if (Test-Path -LiteralPath $file) {
            Get-Content -LiteralPath $file -Encoding UTF8 | Where-Object { $_ -ne '' } | ForEach-Object {
                Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray
            }
        }
    }
}
finally {
    if ($form) { try { $form.Close(); $form.Dispose() } catch { } }
    foreach ($process in $started) {
        try {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        } catch { }
    }
}

Write-Host ''
$failed = @($results | Where-Object { $_.State -eq 'ОШИБКА' }).Count
$skipped = @($results | Where-Object { $_.State -eq 'ПРОПУСК' }).Count
if ($failed -eq 0 -and $skipped -eq 0) {
    Write-Host 'ИТОГ: всё в порядке' -ForegroundColor Green
    exit 0
} elseif ($failed -eq 0) {
    Write-Host 'ИТОГ: ошибок нет, часть проверок пропущена' -ForegroundColor Yellow
    exit 0
} else {
    Write-Host ("ИТОГ: ошибок — {0}" -f $failed) -ForegroundColor Red
    exit 1
}
