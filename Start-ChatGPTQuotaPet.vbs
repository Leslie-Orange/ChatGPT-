Option Explicit

Dim shell
Dim fileSystem
Dim scriptDirectory
Dim scriptPath
Dim powerShellPath
Dim commandLine
Dim index

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(scriptDirectory, "ChatGPTQuotaPet.ps1")
powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fileSystem.FileExists(powerShellPath) Then
    powerShellPath = "powershell.exe"
End If

commandLine = Quote(powerShellPath) & " -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Quote(scriptPath)
For index = 0 To WScript.Arguments.Count - 1
    commandLine = commandLine & " " & Quote(WScript.Arguments(index))
Next

' WindowStyle 0 keeps the PowerShell process and this launcher invisible.
shell.Run commandLine, 0, False

Function Quote(value)
    Quote = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
