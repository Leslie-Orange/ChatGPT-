#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Probe,
    [switch]$SelfTest,
    [switch]$UiSelfTest
)

$scriptPath = Join-Path $PSScriptRoot 'ChatGPTQuotaPet.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "找不到 Windows 程序：$scriptPath"
}

if ($SelfTest) {
    & $scriptPath -SelfTest
    exit $LASTEXITCODE
}

if ($Probe) {
    & $scriptPath -Probe
    exit $LASTEXITCODE
}

if ($UiSelfTest) {
    & $scriptPath -UiSelfTest
    exit $LASTEXITCODE
}

Write-Output "Windows 版本已就绪：$scriptPath"
Write-Output '运行 Start-ChatGPTQuotaPet.cmd，或直接执行 Windows\ChatGPTQuotaPet.ps1。'
