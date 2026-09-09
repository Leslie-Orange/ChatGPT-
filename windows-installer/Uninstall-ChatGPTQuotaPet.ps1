#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$displayName = 'ChatGPT' + [char]0x989D + [char]0x5EA6 + [char]0x4EEA + [char]0x8868 + [char]0x76D8
$productCode = 'ChatGPTQuotaPet'
$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$roamingAppData = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($roamingAppData)) {
    $roamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
}
$desktop = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    Join-Path $env:USERPROFILE 'Desktop'
} else {
    [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
}
$startMenuFolder = Join-Path (Join-Path $roamingAppData 'Microsoft\Windows\Start Menu\Programs') $displayName
$uninstallKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"

Remove-Item -LiteralPath (Join-Path $desktop ($displayName + '.lnk')) -Force
Remove-Item -LiteralPath $startMenuFolder -Recurse -Force
Remove-Item -Path $uninstallKeyPath -Recurse -Force

$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
    $powershellPath = 'powershell.exe'
}
$escapedInstallRoot = $installRoot.Replace("'", "''")
$cleanupCommand = "Start-Sleep -Milliseconds 700; for (`$attempt = 0; `$attempt -lt 12; `$attempt++) { Remove-Item -LiteralPath '$escapedInstallRoot' -Recurse -Force -ErrorAction SilentlyContinue; if (-not (Test-Path -LiteralPath '$escapedInstallRoot')) { break }; Start-Sleep -Milliseconds 500 }"
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
Start-Process -FilePath $powershellPath -WindowStyle Hidden -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
Write-Output ($displayName + ' was uninstalled.')
