param([string]$Query='*IDN?',[string]$OutputFile='')
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class VisaScope {
[DllImport("visa64.dll")] public static extern int viOpenDefaultRM(out uint rm);
[DllImport("visa64.dll",CharSet=CharSet.Ansi)] public static extern int viOpen(uint rm,string address,uint mode,uint timeout,out uint session);
[DllImport("visa64.dll")] public static extern int viSetAttribute(uint session,uint attr,UIntPtr value);
[DllImport("visa64.dll")] public static extern int viWrite(uint session,byte[] bytes,uint count,out uint written);
[DllImport("visa64.dll")] public static extern int viRead(uint session,byte[] bytes,uint count,out uint read);
[DllImport("visa64.dll")] public static extern int viClose(uint session);
}
"@
[uint32]$rm=0;[uint32]$session=0
try {
$s=[VisaScope]::viOpenDefaultRM([ref]$rm);if($s -lt 0){throw "RM: $s"}
$s=[VisaScope]::viOpen($rm,'USB0::0x5656::0x0832::1474742912::INSTR',0,3000,[ref]$session);if($s -lt 0){throw "Open: $s"}
$s=[VisaScope]::viSetAttribute($session,0x3FFF001A,[UIntPtr]3000)
$bytes=[Text.Encoding]::ASCII.GetBytes($Query+"`n");[uint32]$n=0
$s=[VisaScope]::viWrite($session,$bytes,$bytes.Length,[ref]$n);if($s -lt 0){throw "Write: $s"}
if(-not $Query.Contains('?')){ "Command sent=$Query"; return }; $buffer=New-Object byte[] 1048576
$s=[VisaScope]::viRead($session,$buffer,$buffer.Length,[ref]$n)
"Query=$Query Status=$s Bytes=$n"
if($n -gt 0){if($OutputFile){[IO.File]::WriteAllBytes($OutputFile,$buffer[0..($n-1)]); "Saved=$OutputFile"}else{[Text.Encoding]::ASCII.GetString($buffer,0,$n)}}
} finally {if($session){[void][VisaScope]::viClose($session)};if($rm){[void][VisaScope]::viClose($rm)}}


