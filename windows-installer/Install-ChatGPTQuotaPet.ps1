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
$productRoot = Join-Path $localAppData $displayName
$installRoot = Join-Path $productRoot 'current'
$startMenuRoot = Join-Path $roamingAppData 'Microsoft\Windows\Start Menu\Programs'
$uninstallKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"

$payloadFiles = @(
    'ChatGPTQuotaPet.exe',
    'ChatGPTQuotaPet.ps1',
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

function Stop-ExistingApplication {
    param([Parameter(Mandatory)][string]$ScriptPath)

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return
    }

    $normalizedScriptPath = ([IO.Path]::GetFullPath($ScriptPath)).ToLowerInvariant()
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    } catch {
        return
    }

    foreach ($process in $processes) {
        if ($process.Name -notin @('powershell.exe', 'pwsh.exe')) {
            continue
        }
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }
        if ($commandLine.ToLowerInvariant().Contains($normalizedScriptPath)) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 250
}

foreach ($existingScriptPath in @(
        (Join-Path $productRoot 'ChatGPTQuotaPet.ps1'),
        (Join-Path $installRoot 'ChatGPTQuotaPet.ps1')
    )) {
    Stop-ExistingApplication -ScriptPath $existingScriptPath
}

function Copy-InstallPayload {
    param([Parameter(Mandatory)][string]$DestinationRoot)

    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    foreach ($fileName in $payloadFiles) {
        Copy-Item -LiteralPath (Join-Path $payloadRoot $fileName) -Destination (Join-Path $DestinationRoot $fileName) -Force
    }
}

try {
    Copy-InstallPayload -DestinationRoot $installRoot
} catch {
    $installRoot = Join-Path $productRoot ('current-' + [Guid]::NewGuid().ToString('N'))
    Copy-InstallPayload -DestinationRoot $installRoot
}

New-Item -ItemType Directory -Path $desktop -Force | Out-Null
New-Item -ItemType Directory -Path $startMenuRoot -Force | Out-Null
$legacyStartMenuFolder = Join-Path $startMenuRoot $displayName
Remove-Item -LiteralPath $legacyStartMenuFolder -Recurse -Force -ErrorAction SilentlyContinue
foreach ($oldLauncherPath in @(
        (Join-Path $productRoot 'Start-ChatGPTQuotaPet.cmd'),
        (Join-Path $installRoot 'Start-ChatGPTQuotaPet.cmd')
    )) {
    Remove-Item -LiteralPath $oldLauncherPath -Force -ErrorAction SilentlyContinue
}
$wsh = New-Object -ComObject WScript.Shell
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
    $powershellPath = 'powershell.exe'
}
$launchScript = Join-Path $installRoot 'ChatGPTQuotaPet.ps1'
$uninstallScript = Join-Path $installRoot 'Uninstall-ChatGPTQuotaPet.ps1'
$iconPath = Join-Path $installRoot 'ChatGPTQuotaPet.ico'
$launcherPath = Join-Path $installRoot 'ChatGPTQuotaPet.exe'
$launchArguments = ''
$uninstallArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $uninstallScript + '"'

function New-AppShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [AllowEmptyString()][string]$Arguments,
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
$appStartMenuShortcut = Join-Path $startMenuRoot $appShortcutName
$appDesktopShortcut = Join-Path $desktop $appShortcutName
$uninstallShortcut = Join-Path $startMenuRoot ($displayName + ' Uninstall.lnk')
New-AppShortcut -Path $appStartMenuShortcut -Target $launcherPath -Arguments $launchArguments -WorkingDirectory $installRoot -IconLocation ($iconPath + ',0')
New-AppShortcut -Path $appDesktopShortcut -Target $launcherPath -Arguments $launchArguments -WorkingDirectory $installRoot -IconLocation ($iconPath + ',0')
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
New-ItemProperty -Path $uninstallKeyPath -Name 'InstallLocation' -Value $productRoot -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'DisplayIcon' -Value ($iconPath + ',0') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'UninstallString' -Value ('"' + $powershellPath + '" ' + $uninstallArguments) -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'InstallDate' -Value (Get-Date -Format 'yyyyMMdd') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'EstimatedSize' -Value $estimatedSize -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallKeyPath -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null

if ($env:CHATGPT_QUOTA_PET_AUTOSTART -eq '1') {
    Start-Process -FilePath $launcherPath -WorkingDirectory $installRoot -WindowStyle Hidden
}
Write-Output ($displayName + ' installed to ' + $installRoot)
