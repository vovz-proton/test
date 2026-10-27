' ===========================================================================
'  Prof_KIP_v5 firmware uploader - silent launcher (no console window).
'  Double-click this file, or drop a .hex file onto it to pre-select it.
'  ASCII only on purpose.
' ===========================================================================
Option Explicit

Dim shell, fso, base, command, i

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

base = fso.GetParentFolderName(WScript.ScriptFullName)

If Not fso.FileExists(base & "\FirmwareUploader.ps1") Then
  MsgBox "FirmwareUploader.ps1 not found next to this file.", 16, "Prof_KIP_v5 uploader"
  WScript.Quit 1
End If

command = "powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden" & _
          " -File """ & base & "\FirmwareUploader.ps1"""

For i = 0 To WScript.Arguments.Count - 1
  command = command & " """ & WScript.Arguments(i) & """"
Next

shell.Run command, 0, False
