Set shell = CreateObject("WScript.Shell")
scriptPath = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & "\Invoke-HostAdapterChangeHook.ps1"
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """"
shell.Run command, 0, False
