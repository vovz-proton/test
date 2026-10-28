param([string]$PortName='COM6',[int]$TimeoutSec=600)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$device=Get-PnpDevice -PresentOnly -Class Ports | Where-Object {$_.InstanceId -eq 'USB\VID_0483&PID_5740\207237695746' -and $_.FriendlyName -match ('\('+[regex]::Escape($PortName)+'\)')}
if(-not $device){throw 'Selected port is not the expected STM32 board'}
$port=[IO.Ports.SerialPort]::new($PortName,115200)
$port.DtrEnable=$true;$port.ReadTimeout=500;$port.NewLine="`n"
try {
 $port.Open()
 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSec)
 while([DateTime]::UtcNow -lt $deadline){
  try{$line=$port.ReadLine().Trim()}catch [TimeoutException]{continue}
  if($line -match '^CAL='){Write-Host $line}
  if($line -match '^CAL=4,'){throw 'Measurement aborted; no valid speed result'}
  if($line -notmatch '^CAL=3,T_US=(\d+),PULSES=(\d+),L_UM=30850$'){continue}
  $us=[uint32]$Matches[1];$pulses=[uint32]$Matches[2]
  if(-not $us -or -not $pulses){throw 'Invalid zero measurement'}
  $seconds=$us/1000000.0
  $record=[ordered]@{
   captured_at_moscow=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTimeOffset]::UtcNow,'Russian Standard Time').ToString('o')
   source='STM32 hardware TIM5, reverse start to second confirmed closure edge'
   raw=$line;distance_mm=30.85;time_us=$us;time_s=$seconds;pulses=$pulses
   average_speed_mm_s=30.85/$seconds;pulses_per_mm=$pulses/30.85
   microsteps_per_full_step=256;full_steps_per_mm=$pulses/256.0/30.85
   commanded_pulse_hz=45175;steady_timer_pulse_hz=1000000.0/22
   notes='Includes acceleration and switching/setup time. Assumes no lost steps. Distance supplied by user.'
  }
  $dir=Join-Path $root 'calibration';New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $name='motor-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json'
  $json=$record|ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path $dir $name),$json)
  [IO.File]::WriteAllText((Join-Path $dir 'motor-latest.json'),$json)
  $note="`n## Измеренный проход $($record.captured_at_moscow)`nРасстояние: 30,85 мм; время: $seconds с; импульсов: $pulses.`nСредняя скорость: $($record.average_speed_mm_s) мм/с; импульсов/мм: $($record.pulses_per_mm).`nФайл: calibration/$name. Разгон включён во время измерения.`n"
  [IO.File]::AppendAllText((Join-Path $root 'docs/MOTOR_CALIBRATION.md'),$note)
  Write-Output ([pscustomobject]$record)
  return
 }
 throw 'Timed out; no completed measurement, no result saved'
} finally {if($port.IsOpen){$port.Close()};$port.Dispose()}