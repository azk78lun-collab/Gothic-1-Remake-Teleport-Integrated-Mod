Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
ps1Path = fso.GetParentFolderName(WScript.ScriptFullName) & "\TeleportModUI.ps1"
psCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1Path & """"
WshShell.Run psCommand, 0, False
