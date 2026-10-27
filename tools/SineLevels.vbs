' ===========================================================================
'  Prof_KIP_v5 DAC sine levels - silent launcher (no console window).
'  Double-click this file. Optional argument: COM port, e.g. COM52.
'  ASCII only on purpose.
' ===========================================================================
Option Explicit

Dim shell, fso, base, command, i

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base = fso.GetParentFolderName(WScript.ScriptFullName)

If Not fso.FileExists(base & "\SineLevels.ps1") Then
  MsgBox "SineLevels.ps1 not found next to this file.", 16, "Prof_KIP_v5: DAC sine levels"
  WScript.Quit 1
End If

command = "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden" & _
          " -File """ & base & "\SineLevels.ps1"""

For i = 0 To WScript.Arguments.Count - 1
  command = command & " """ & WScript.Arguments(i) & """"
Next

shell.Run command, 0, False
