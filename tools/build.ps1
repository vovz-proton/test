param([string]$ToolchainBin, [switch]$Mechanics, [switch]$LimitJog, [switch]$TravelCal, [switch]$LedOnly, [switch]$ShuttleTest, [switch]$MusicTest, [string]$OutputDirectory = 'build')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (!$ToolchainBin) {
    $cmd = Get-Command arm-none-eabi-gcc.exe -ErrorAction SilentlyContinue
    if ($cmd) { $ToolchainBin = Split-Path $cmd.Source }
    else {
        $candidate = Get-ChildItem 'D:/ST/STM32CubeIDE_1.17.0/STM32CubeIDE/plugins/*/tools/bin/arm-none-eabi-gcc.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) { $ToolchainBin = $candidate.DirectoryName }
    }
}
if (!$ToolchainBin) { throw 'Pass -ToolchainBin with the directory containing arm-none-eabi-gcc.exe' }
$gcc = Join-Path $ToolchainBin 'arm-none-eabi-gcc.exe'
$out = Join-Path $root $OutputDirectory
New-Item -ItemType Directory -Force -Path $out | Out-Null
$includes = @('Core/Inc','Drivers/STM32F3xx_HAL_Driver/Inc','Drivers/STM32F3xx_HAL_Driver/Inc/Legacy',
    'Drivers/CMSIS/Device/ST/STM32F3xx/Include','Drivers/CMSIS/Include','USB_DEVICE/App','USB_DEVICE/Target',
    'Middlewares/ST/STM32_USB_Device_Library/Core/Inc','Middlewares/ST/STM32_USB_Device_Library/Class/CDC/Inc')
# Размер важнее скорости: приложение обязано помещаться в 30 КБ (см. раскладку ниже).
# LTO + отказ от таблиц раскрутки дают ~4 КБ экономии по сравнению с обычной -Os.
$opt = @('-Os','-flto','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-fno-math-errno')
$common = @('-mcpu=cortex-m4','-mthumb','-mfpu=fpv4-sp-d16','-mfloat-abi=hard') + $opt + @('-g3',
    '-ffunction-sections','-fdata-sections','-DUSE_HAL_DRIVER','-DSTM32F373xC')
if ($MusicTest) { if ($ShuttleTest -or $TravelCal -or $LimitJog -or $Mechanics -or $LedOnly) { throw 'MusicTest requires a dedicated build' }; $common += '-DMOTOR_MUSIC_TEST=1' }
if ($ShuttleTest) { if ($TravelCal -or $LimitJog -or $Mechanics -or $LedOnly) { throw 'ShuttleTest requires a dedicated build' }; $common += '-DMOTOR_SHUTTLE_TEST=1' }
if ($LedOnly) { if ($TravelCal -or $LimitJog -or $Mechanics) { throw 'LedOnly cannot be combined with motor modes' }; $common += '-DMOTOR_DISABLED=1' }
if ($Mechanics) { $common += "-DBENCH_NO_MECHANICS=0" }
if ($TravelCal) { $common += '-DMOTOR_TRAVEL_CAL=1'; $LimitJog = $true }
if ($LimitJog) { $common += '-DMOTOR_LIMIT_JOG=1' }
foreach ($inc in $includes) { $common += '-I' + (Join-Path $root $inc) }
$sources = Get-ChildItem (Join-Path $root 'Core/Src'),(Join-Path $root 'Drivers/STM32F3xx_HAL_Driver/Src'),(Join-Path $root 'USB_DEVICE'),(Join-Path $root 'Middlewares') -Filter '*.c' -Recurse
$objects = @()
foreach ($src in $sources) {
    $relative = $src.FullName.Substring($root.Length+1)
    $object = Join-Path $out (($relative -replace '[\\/]','_') + '.o')
    $warnings = @('-Wall','-Wextra')
    if ($relative -match '^Core[\\/]') { $warnings += '-Werror' }
    else { $warnings += '-Wno-unused-parameter' }
    & $gcc @common @warnings '-std=gnu11' '-c' $src.FullName '-o' $object
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $relative" }
    $objects += $object
}
$startup = Join-Path $out 'startup.o'
& $gcc @common '-c' (Join-Path $root 'Core/Startup/startup_stm32f373c8tx.s') '-o' $startup
if ($LASTEXITCODE -ne 0) { throw 'Startup assembly failed' }
$objects += $startup
$elf = Join-Path $out 'Prof_KIP_v5.elf'
& $gcc @common @objects '-T' (Join-Path $root 'STM32F373C8TX_FLASH.ld') '--specs=nano.specs' '--specs=nosys.specs' '-Wl,--gc-sections' "-Wl,-Map=$out/Prof_KIP_v5.map" '-Wl,--start-group' '-lc' '-lm' '-Wl,--end-group' '-o' $elf
if ($LASTEXITCODE -ne 0) { throw 'Link failed' }
# Раскладка для обновления по USB (см. STM32F373C8TX_FLASH.ld): приложение <= 30 КБ,
# копировщик строго на 0x08007800. Проверка ловит случайную регенерацию .ld из CubeMX.
$nmExe = Join-Path $ToolchainBin 'arm-none-eabi-nm.exe'
$sizeExe = Join-Path $ToolchainBin 'arm-none-eabi-size.exe'
$stubLine = (& $nmExe $elf | Select-String -Pattern 'Firmware_CopyStub$' | Select-Object -First 1).Line
if (-not $stubLine -or $stubLine -notmatch '^08007800') {
    throw "Копировщик обновления должен лежать по адресу 0x08007800, получено: '$stubLine'. Проверьте регионы FLASH/COPYER в STM32F373C8TX_FLASH.ld"
}
$sizes = (& $sizeExe $elf) -split "`n" | Select-Object -Last 1
$numbers = [regex]::Matches($sizes, '\d+') | ForEach-Object { [int]$_.Value }
$textBytes = $numbers[0]; $dataBytes = $numbers[1]
$copyerBytes = 0
foreach ($row in (& $sizeExe -A $elf)) { if ($row -match '^\.copyer\s+(\d+)') { $copyerBytes = [int]$Matches[1] } }
$appBytes = $textBytes - $copyerBytes + $dataBytes
"Раскладка    : приложение $appBytes Б из 30720 (страницы 0..14), копировщик $copyerBytes Б на 0x08007800"
if ($appBytes -gt 30720) { throw "Приложение не помещается в 30 КБ: $appBytes Б. Уменьшите код или пересмотрите раскладку." }
& (Join-Path $ToolchainBin 'arm-none-eabi-objcopy.exe') '-O' 'ihex' $elf (Join-Path $out 'Prof_KIP_v5.hex')
if ($LASTEXITCODE -ne 0) { throw 'HEX export failed' }
& (Join-Path $ToolchainBin 'arm-none-eabi-objcopy.exe') '-O' 'binary' $elf (Join-Path $out 'Prof_KIP_v5.bin')
if ($LASTEXITCODE -ne 0) { throw 'BIN export failed' }
& (Join-Path $ToolchainBin 'arm-none-eabi-size.exe') $elf
