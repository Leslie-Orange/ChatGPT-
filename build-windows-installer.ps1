#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDirectory = '',
    [switch]$SkipSelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot (Get-Date -Format 'yyyy-MM-dd')
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
if (-not (Test-Path -LiteralPath $iexpress -PathType Leaf)) {
    throw 'Windows IExpress packaging tool was not found.'
}

if (-not $SkipSelfTest) {
    & (Join-Path $projectRoot 'build-windows.ps1') -SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows core self-test failed; packaging stopped.'
    }
    & (Join-Path $projectRoot 'build-windows.ps1') -UiSelfTest
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows UI self-test failed; packaging stopped.'
    }
}

function New-IconFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.Drawing
    $source = $null
    $bitmap = $null
    $graphics = $null
    $icon = $null
    $stream = $null
    $hIcon = [IntPtr]::Zero
    try {
        $source = [Drawing.Image]::FromFile($SourcePath)
        $bitmap = [Drawing.Bitmap]::new(64, 64)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.DrawImage($source, [Drawing.Rectangle]::new(0, 0, 64, 64))
        $hIcon = $bitmap.GetHicon()
        $icon = [Drawing.Icon]::FromHandle($hIcon)
        $stream = [IO.File]::Create($DestinationPath)
        $icon.Save($stream)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $icon) { $icon.Dispose() }
        if ($hIcon -ne [IntPtr]::Zero) {
            if ($null -eq ('ChatGPTQuotaPetNativeMethods' -as [type])) {
                Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class ChatGPTQuotaPetNativeMethods
{
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@
            }
            [ChatGPTQuotaPetNativeMethods]::DestroyIcon($hIcon) | Out-Null
        }
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $source) { $source.Dispose() }
    }
}

$displayName = 'ChatGPT' + [char]0x989D + [char]0x5EA6 + [char]0x4EEA + [char]0x8868 + [char]0x76D8
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ChatGPTQuotaPet-installer-' + [Guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $tempRoot 'payload'
$sedPath = Join-Path $tempRoot 'ChatGPTQuotaPet.sed'
$tempOutput = Join-Path $tempRoot 'ChatGPTQuotaPet-Setup.exe'
$finalPath = Join-Path $OutputDirectory ($displayName + '.exe')

try {
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
    $payloadFiles = @(
        'ChatGPTQuotaPet.ps1',
        'Start-ChatGPTQuotaPet.cmd',
        'build-windows.ps1'
    )
    foreach ($fileName in $payloadFiles) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $fileName) -Destination (Join-Path $payloadRoot $fileName) -Force
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'macOS\AppIcon.png') -Destination (Join-Path $payloadRoot 'AppIcon.png') -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows-installer\Install-ChatGPTQuotaPet.ps1') -Destination (Join-Path $payloadRoot 'Install-ChatGPTQuotaPet.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows-installer\Uninstall-ChatGPTQuotaPet.ps1') -Destination (Join-Path $payloadRoot 'Uninstall-ChatGPTQuotaPet.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'windows-installer\install.cmd') -Destination (Join-Path $payloadRoot 'install.cmd') -Force
    New-IconFile -SourcePath (Join-Path $payloadRoot 'AppIcon.png') -DestinationPath (Join-Path $payloadRoot 'ChatGPTQuotaPet.ico')

    $fileTokens = @(
        'ChatGPTQuotaPet.ps1',
        'Start-ChatGPTQuotaPet.cmd',
        'build-windows.ps1',
        'AppIcon.png',
        'ChatGPTQuotaPet.ico',
        'Install-ChatGPTQuotaPet.ps1',
        'Uninstall-ChatGPTQuotaPet.ps1',
        'install.cmd'
    )
    $sourceEntries = for ($index = 0; $index -lt $fileTokens.Count; $index++) {
        '%FILE{0}%=' -f $index
    }
    $stringEntries = for ($index = 0; $index -lt $fileTokens.Count; $index++) {
        'FILE{0}={1}' -f $index, $fileTokens[$index]
    }
    $sedContent = @"
[Version]
Class=IEXPRESS
SEDVersion=3

[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=1
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=I
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$tempOutput
FriendlyName=ChatGPT Quota Dashboard
AppLaunched=install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=install.cmd
UserQuietInstCmd=install.cmd
SourceFiles=SourceFiles

[SourceFiles]
SourceFiles0=$payloadRoot

[SourceFiles0]
$($sourceEntries -join "`r`n")

[Strings]
$($stringEntries -join "`r`n")
"@
    Set-Content -LiteralPath $sedPath -Value $sedContent -Encoding Unicode

    $process = Start-Process -FilePath $iexpress -ArgumentList @('/N', $sedPath) -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempOutput -PathType Leaf)) {
        throw "IExpress packaging failed with exit code $($process.ExitCode)."
    }
    Copy-Item -LiteralPath $tempOutput -Destination $finalPath -Force
    Write-Output "Installer created: $finalPath"
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
