#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$displayName = 'ChatGPT' + [char]0x989D + [char]0x5EA6 + [char]0x4EEA + [char]0x8868 + [char]0x76D8
$productCode = 'ChatGPTQuotaPet'
$payloadRoot = $PSScriptRoot
$localAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($localAppData)) {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
}
$roamingAppData = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($roamingAppData)) {
    $roamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
}
$desktop = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    Join-Path $env:USERPROFILE 'Desktop'
} else {
    [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
}
$installRoot = Join-Path $localAppData $displayName
$startMenuRoot = Join-Path $roamingAppData 'Microsoft\Windows\Start Menu\Programs'
$startMenuFolder = Join-Path $startMenuRoot $displayName
$uninstallKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"

$payloadFiles = @(
    'ChatGPTQuotaPet.ps1',
    'Start-ChatGPTQuotaPet.cmd',
    'Start-ChatGPTQuotaPet.vbs',
    'build-windows.ps1',
    'AppIcon.png',
    'ChatGPTQuotaPet.ico',
    'Uninstall-ChatGPTQuotaPet.ps1'
)

foreach ($fileName in $payloadFiles) {
    $sourcePath = Join-Path $payloadRoot $fileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Missing installer payload: $fileName"
    }
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
foreach ($fileName in $payloadFiles) {
    Copy-Item -LiteralPath (Join-Path $payloadRoot $fileName) -Destination (Join-Path $installRoot $fileName) -Force
}

New-Item -ItemType Directory -Path $desktop -Force | Out-Null
New-Item -ItemType Directory -Path $startMenuFolder -Force | Out-Null
$wsh = New-Object -ComObject WScript.Shell
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
    $powershellPath = 'powershell.exe'
}
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $wscriptPath -PathType Leaf)) {
    $wscriptPath = 'wscript.exe'
}
$launchScript = Join-Path $installRoot 'Start-ChatGPTQuotaPet.vbs'
$uninstallScript = Join-Path $installRoot 'Uninstall-ChatGPTQuotaPet.ps1'
$iconPath = Join-Path $installRoot 'ChatGPTQuotaPet.ico'
$launchArguments = '//nologo "' + $launchScript + '"'
$uninstallArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $uninstallScript + '"'

function New-AppShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [AllowNull()][string]$IconLocation
    )

    $shortcut = $wsh.CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    if (-not [string]::IsNullOrWhiteSpace($IconLocation)) {
        $shortcut.IconLocation = $IconLocation
    }
    $shortcut.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
}

$appShortcutName = $displayName + '.lnk'
$appStartMenuShortcut = Join-Path $startMenuFolder $appShortcutName
$appDesktopShortcut = Join-Path $desktop $appShortcutName
$uninstallShortcut = Join-Path $startMenuFolder ($displayName + ' Uninstall.lnk')
New-AppShortcut -Path $appStartMenuShortcut -Target $wscriptPath -Arguments $launchArguments -WorkingDirectory $installRoot -IconLocation ($iconPath + ',0')
New-AppShortcut -Path $appDesktopShortcut -Target $wscriptPath -Arguments $launchArguments -WorkingDirectory $installRoot -IconLocation ($iconPath + ',0')
New-AppShortcut -Path $uninstallShortcut -Target $powershellPath -Arguments $uninstallArguments -WorkingDirectory $installRoot -IconLocation ($powershellPath + ',0')
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)

$fileBytes = 0L
foreach ($file in (Get-ChildItem -LiteralPath $installRoot -File -ErrorAction SilentlyContinue)) {
    $fileBytes += $file.Length
}
$estimatedSize = [int][Math]::Max(1, [Math]::Ceiling($fileBytes / 1KB))
New-Item -Path $uninstallKeyPath -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'DisplayName' -Value $displayName -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'DisplayVersion' -Value '1.0.0' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'Publisher' -Value $displayName -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'InstallLocation' -Value $installRoot -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'DisplayIcon' -Value ($iconPath + ',0') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'UninstallString' -Value ('"' + $powershellPath + '" ' + $uninstallArguments) -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'InstallDate' -Value (Get-Date -Format 'yyyyMMdd') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'EstimatedSize' -Value $estimatedSize -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null

if ($env:CHATGPT_QUOTA_PET_NO_LAUNCH -ne '1') {
    Start-Process -FilePath $wscriptPath -ArgumentList $launchArguments -WorkingDirectory $installRoot -WindowStyle Hidden
}
Write-Output ($displayName + ' installed to ' + $installRoot)
