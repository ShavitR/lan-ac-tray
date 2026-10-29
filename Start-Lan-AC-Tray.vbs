Option Explicit
Dim shell, fso, folder, runtime, script, command, codexRuntime
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
runtime = shell.ExpandEnvironmentStrings("%ProgramFiles%\PowerShell\7\pwsh.exe")
If Not fso.FileExists(runtime) Then
    runtime = shell.ExpandEnvironmentStrings("%ProgramFiles(x86)%\PowerShell\7\pwsh.exe")
End If
If Not fso.FileExists(runtime) Then
    codexRuntime = shell.ExpandEnvironmentStrings("%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe")
    If fso.FileExists(codexRuntime) Then runtime = codexRuntime Else runtime = "pwsh.exe"
End If
script = folder & "\LanAcTray.ps1"
command = """" & runtime & """ -NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File """ & script & """"
shell.Run command, 0, False
