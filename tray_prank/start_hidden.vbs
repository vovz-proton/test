' Start the tray program without a console window (double-click this file).
' This file is ASCII-only on purpose: Windows Script Host reads .vbs as ANSI.
Option Explicit

Dim sh, fso, dir
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = dir

On Error Resume Next
sh.Run "pythonw.exe """ & dir & "\tray_prank.py""", 0, False
If Err.Number <> 0 Then
    Err.Clear
    sh.Run "python.exe """ & dir & "\tray_prank.py""", 0, False
    If Err.Number <> 0 Then
        MsgBox "Python not found. Install Python 3 or edit this file.", 48, "tray_prank"
    End If
End If
On Error GoTo 0
