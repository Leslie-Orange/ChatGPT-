#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Probe,
    [switch]$SelfTest,
    [switch]$UiSelfTest
)

Set-StrictMode -Version 2.0

$script:RefreshSeconds = 1
$script:TailBytes = 512KB
$userProfileRoot = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($userProfileRoot)) {
    $userProfileRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}
if ([string]::IsNullOrWhiteSpace($userProfileRoot)) {
    $userProfileRoot = (Get-Location).Path
}
$script:CodexHome = Join-Path $userProfileRoot '.codex'
$script:LiveSnapshot = $null
$script:FallbackSnapshot = $null
$script:ConnectionError = ''
$script:Footer = '正在连接本地额度接口…'
$script:PopupForm = $null
$script:TrayIcon = $null
$script:TrayIconImage = $null
$script:TrayMenu = $null
$script:RefreshTimer = $null
$script:AllowFormClose = $false
$script:SelfTestExitCode = 0
$script:ProbeExitCode = 1
$script:UiSelfTestExitCode = 1

$script:AppServer = [pscustomobject]@{
    ProcessBridge = $null
    NextId = 0
    InitializeId = $null
    PendingReadId = $null
    PendingSince = $null
    Ready = $false
    LastError = ''
}

function Get-ObjectValue {
    param(
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }

    return $null
}

function Convert-ToNumber {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        [double]$parsed = 0
        try {
            $styles = [Globalization.NumberStyles]::Float -bor [Globalization.NumberStyles]::AllowThousands
            if ([double]::TryParse(
                    [string]$Value,
                    $styles,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$parsed
                )) {
                return $parsed
            }
        } catch {
            return $null
        }
        return $null
    }

    try {
        return [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function Convert-ToDateTimeOffset {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value
    }
    if ($Value -is [DateTime]) {
        return [DateTimeOffset]$Value
    }

    try {
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        return $null
    }
}

function Get-QuotaWindow {
    param([AllowNull()][object]$RawValue)

    $used = Convert-ToNumber (Get-ObjectValue -Object $RawValue -Names @('used_percent', 'usedPercent'))
    $remaining = $null
    if ($null -ne $used) {
        $remaining = [Math]::Min(100.0, [Math]::Max(0.0, 100.0 - $used))
    }

    return [pscustomobject]@{
        Remaining = $remaining
        Used = $used
        ResetAt = Convert-ToNumber (Get-ObjectValue -Object $RawValue -Names @('resets_at', 'resetsAt'))
        WindowMinutes = Convert-ToNumber (Get-ObjectValue -Object $RawValue -Names @('window_minutes', 'windowDurationMins', 'window_duration_mins'))
    }
}

function New-QuotaSnapshot {
    param(
        [AllowNull()][object]$Limits,
        [Parameter(Mandatory)][DateTimeOffset]$SampledAt,
        [Parameter(Mandatory)][string]$SourceName
    )

    if ($null -eq $Limits) {
        return $null
    }

    $primary = Get-QuotaWindow (Get-ObjectValue -Object $Limits -Names @('primary'))
    $secondary = Get-QuotaWindow (Get-ObjectValue -Object $Limits -Names @('secondary'))
    if ($null -eq $primary.Used -and $null -eq $secondary.Used) {
        return $null
    }

    $plan = Get-ObjectValue -Object $Limits -Names @('plan_type', 'planType')
    if ($null -ne $plan) {
        $plan = [string]$plan
    }

    return [pscustomobject]@{
        PlanType = $plan
        Primary = $primary
        Secondary = $secondary
        SampledAt = $SampledAt
        SourceName = $SourceName
    }
}

function Read-TailLines {
    param([Parameter(Mandatory)][string]$Path)

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        $start = [Math]::Max(0L, [int64]$stream.Length - [int64]$script:TailBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $remaining = [int64]$stream.Length - $start
        $length = [int][Math]::Min([int64]$script:TailBytes, $remaining)
        if ($length -le 0) {
            return @()
        }

        $buffer = [byte[]]::new($length)
        $read = $stream.Read($buffer, 0, $length)
        if ($read -le 0) {
            return @()
        }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $lines = @($text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        [Array]::Reverse($lines)
        return $lines
    } catch {
        return @()
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-FileDateTimeOffset {
    param([Parameter(Mandatory)][IO.FileInfo]$File)

    try {
        return [DateTimeOffset]$File.LastWriteTime
    } catch {
        return [DateTimeOffset]::MinValue
    }
}

function Get-FallbackSnapshot {
    $sessions = Join-Path $script:CodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessions -PathType Container)) {
        return $null
    }

    $files = @(
        Get-ChildItem -LiteralPath $sessions -Filter 'rollout-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 24
    )

    foreach ($file in $files) {
        foreach ($line in (Read-TailLines -Path $file.FullName)) {
            if ($line -notlike '*"rate_limits"*') {
                continue
            }

            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                continue
            }

            $payload = Get-ObjectValue -Object $event -Names @('payload')
            $limits = Get-ObjectValue -Object $payload -Names @('rate_limits', 'rateLimits')
            if ($null -eq $limits) {
                continue
            }

            $sampledAt = Convert-ToDateTimeOffset (Get-ObjectValue -Object $event -Names @('timestamp'))
            if ($null -eq $sampledAt) {
                $sampledAt = Get-FileDateTimeOffset -File $file
            }
            $snapshot = New-QuotaSnapshot -Limits $limits -SampledAt $sampledAt -SourceName $file.Name
            if ($null -ne $snapshot) {
                return $snapshot
            }
        }
    }

    return $null
}

function Get-UnixSeconds {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
}

function Format-Percent {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return '—'
    }
    return ('{0:0}%' -f [double]$Value)
}

function Format-Caption {
    param(
        [AllowNull()][object]$Minutes,
        [Parameter(Mandatory)][string]$Fallback
    )

    if ($null -eq $Minutes) {
        return $Fallback
    }
    $rounded = [int][Math]::Round([double]$Minutes, 0, [MidpointRounding]::AwayFromZero)
    if ($rounded -le 0) {
        return $Fallback
    }
    if (($rounded % 1440) -eq 0) {
        return ('{0} 天窗口剩余' -f ($rounded / 1440))
    }
    if (($rounded % 60) -eq 0) {
        return ('{0} 小时窗口剩余' -f ($rounded / 60))
    }
    return ('{0} 分钟窗口剩余' -f $rounded)
}

function Format-Reset {
    param([AllowNull()][object]$Timestamp)

    if ($null -eq $Timestamp) {
        return '重置时间未知'
    }
    $seconds = [double]$Timestamp - (Get-UnixSeconds)
    if ($seconds -le 0) {
        return '窗口已到点，等待刷新'
    }
    $minutes = [int][Math]::Ceiling($seconds / 60.0)
    if ($minutes -lt 60) {
        return ('约 {0} 分钟后重置' -f $minutes)
    }
    $days = [int]($minutes / 1440)
    $hours = [int](($minutes % 1440) / 60)
    $rest = $minutes % 60
    if ($days -gt 0) {
        return ('约 {0} 天 {1} 小时后重置' -f $days, $hours)
    }
    return ('约 {0} 小时 {1} 分钟后重置' -f $hours, $rest)
}

function Format-ConsumptionRate {
    param(
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][double]$FallbackWindowMinutes,
        [Parameter(Mandatory)][double]$DisplayPeriodMinutes,
        [Parameter(Mandatory)][string]$Unit
    )

    if ($null -eq $Window.ResetAt -or $null -eq $Window.Used) {
        return '等待数据'
    }

    $windowMinutes = $FallbackWindowMinutes
    if ($null -ne $Window.WindowMinutes) {
        $windowMinutes = [double]$Window.WindowMinutes
    }
    $totalMinutes = [Math]::Max(1.0, $windowMinutes)
    $remainingMinutes = [Math]::Min(
        $totalMinutes,
        [Math]::Max(0.0, ([double]$Window.ResetAt - (Get-UnixSeconds)) / 60.0)
    )
    $elapsedMinutes = $totalMinutes - $remainingMinutes
    if ($elapsedMinutes -lt 1.0) {
        return '等待数据'
    }

    $used = [Math]::Min(100.0, [Math]::Max(0.0, [double]$Window.Used))
    $rate = $used / $elapsedMinutes * $DisplayPeriodMinutes
    if ([double]::IsNaN($rate) -or [double]::IsInfinity($rate)) {
        return '等待数据'
    }
    return ('{0:0.0}%/{1}' -f $rate, $Unit)
}

function Format-ShortError {
    param([AllowNull()][string]$ErrorMessage)

    if ([string]::IsNullOrEmpty($ErrorMessage)) {
        return ''
    }
    if ($ErrorMessage -match '(?i)codex' -and ($ErrorMessage -match '(?i)not found|找不到|executable')) {
        return '未找到 codex'
    }
    $oneLine = ($ErrorMessage -replace "`r?`n", ' ').Trim()
    if ($oneLine.Length -gt 22) {
        return $oneLine.Substring(0, 22)
    }
    return $oneLine
}

function Get-SnapshotFooter {
    param([Parameter(Mandatory)][object]$Snapshot)

    $ageMinutes = [Math]::Max(0.0, ([DateTimeOffset]::Now - $Snapshot.SampledAt).TotalMinutes)
    $format = if ($ageMinutes -ge 10) { 'MM-dd HH:mm' } else { 'HH:mm' }
    $localTime = $Snapshot.SampledAt.ToLocalTime().ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    $source = if ($Snapshot.SourceName -eq 'app-server') { '实时' } else { '快照' }
    $stale = if ($ageMinutes -ge 10) { ' · 可能过期' } else { '' }
    $shortError = Format-ShortError -ErrorMessage $script:ConnectionError
    $errorSuffix = if ($Snapshot.SourceName -eq 'app-server' -or [string]::IsNullOrEmpty($shortError)) { '' } else { ' · ' + $shortError }
    return '{0} {1}{2}{3}' -f $source, $localTime, $stale, $errorSuffix
}

function Get-PlanTitle {
    param([AllowNull()][object]$Snapshot)

    if ($null -ne $Snapshot -and $null -ne $Snapshot.PlanType) {
        $plan = ([string]$Snapshot.PlanType).Trim()
        if ($plan.Length -gt 0) {
            $title = [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($plan.ToLowerInvariant())
            return ($title + ' 额度')
        }
    }
    return '订阅额度'
}

function Test-AppServerRunning {
    $bridge = $script:AppServer.ProcessBridge
    if ($null -eq $bridge) {
        return $false
    }
    try {
        return [bool]$bridge.IsRunning
    } catch {
        return $false
    }
}

function Set-AppServerError {
    param([Parameter(Mandatory)][string]$Message)

    $script:AppServer.LastError = $Message
    $script:ConnectionError = $Message
}

function Get-CodexExecutable {
    $explicit = $env:CODEX_BIN
    if ([string]::IsNullOrWhiteSpace($explicit)) {
        $explicit = $env:CODEX_CLI_PATH
    }
    if (-not [string]::IsNullOrWhiteSpace($explicit) -and (Test-Path -LiteralPath $explicit -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $explicit).Path
    }

    $commands = @(Get-Command codex,codex.exe,codex.cmd -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        $pathProperty = $command.PSObject.Properties['Source']
        $path = if ($null -ne $pathProperty) { $pathProperty.Value } else { $null }
        if ([string]::IsNullOrWhiteSpace($path)) {
            $pathProperty = $command.PSObject.Properties['Path']
            $path = if ($null -ne $pathProperty) { $pathProperty.Value } else { $null }
        }
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    }
    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    $roamingAppData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($roamingAppData)) {
        $roamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    }
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $candidates += Join-Path $localAppData 'OpenAI\Codex\bin\codex.exe'
        $candidates += Join-Path $localAppData 'OpenAI\Codex\bin\codex.cmd'
    }
    if (-not [string]::IsNullOrWhiteSpace($roamingAppData)) {
        $candidates += Join-Path $roamingAppData 'npm\codex.cmd'
    }
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $candidates += Join-Path $userProfile '.local\bin\codex.exe'
        $candidates += Join-Path $userProfile '.local\bin\codex.cmd'
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function New-AppServerStartInfo {
    param([Parameter(Mandatory)][string]$Executable)

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $extension = [IO.Path]::GetExtension($Executable).ToLowerInvariant()
    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        $info.FileName = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { 'cmd.exe' } else { $env:ComSpec }
        $info.Arguments = '/d /s /c ""' + $Executable + '" app-server --listen stdio://"'
    } elseif ($extension -eq '.ps1') {
        $pwshCommand = Get-Command pwsh,powershell -ErrorAction SilentlyContinue | Select-Object -First 1
        $runner = if ($null -ne $pwshCommand) { $pwshCommand.Source } else { 'powershell.exe' }
        $info.FileName = $runner
        $info.Arguments = '-NoLogo -NoProfile -File "' + $Executable + '" app-server --listen stdio://'
    } else {
        $info.FileName = $Executable
        $info.Arguments = 'app-server --listen stdio://'
    }

    return $info
}

function Send-AppServerMessage {
    param([Parameter(Mandatory)][object]$Message)

    if (-not (Test-AppServerRunning)) {
        return
    }

    try {
        $line = $Message | ConvertTo-Json -Compress -Depth 12
        $script:AppServer.ProcessBridge.SendLine($line)
    } catch {
        Set-AppServerError -Message ('无法写入本地额度接口：' + $_.Exception.Message)
    }
}

function Stop-AppServer {
    $state = $script:AppServer
    if ($null -ne $state.ProcessBridge) {
        try { $state.ProcessBridge.Stop() } catch {}
        try { $state.ProcessBridge.Dispose() } catch {}
    }

    $state.ProcessBridge = $null
    $state.InitializeId = $null
    $state.PendingReadId = $null
    $state.PendingSince = $null
    $state.Ready = $false
}

function Ensure-ProcessBridgeType {
    if ($null -ne ('ChatGPTQuotaPetProcessBridge' -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

public sealed class ChatGPTQuotaPetBridgeMessage
{
    public string Kind { get; private set; }
    public string Data { get; private set; }

    public ChatGPTQuotaPetBridgeMessage(string kind, string data)
    {
        Kind = kind;
        Data = data;
    }
}

public sealed class ChatGPTQuotaPetProcessBridge : IDisposable
{
    private readonly ConcurrentQueue<ChatGPTQuotaPetBridgeMessage> messages = new ConcurrentQueue<ChatGPTQuotaPetBridgeMessage>();
    private readonly object gate = new object();
    private Process process;
    private DataReceivedEventHandler outputHandler;
    private DataReceivedEventHandler errorHandler;
    private EventHandler exitHandler;

    public bool IsRunning
    {
        get
        {
            lock (gate)
            {
                try { return process != null && !process.HasExited; }
                catch { return false; }
            }
        }
    }

    public void Start(string fileName, string arguments)
    {
        Stop();
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        var nextProcess = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        outputHandler = delegate(object sender, DataReceivedEventArgs args)
        {
            if (args.Data != null) messages.Enqueue(new ChatGPTQuotaPetBridgeMessage("stdout", args.Data));
        };
        errorHandler = delegate(object sender, DataReceivedEventArgs args)
        {
            if (args.Data != null) messages.Enqueue(new ChatGPTQuotaPetBridgeMessage("stderr", args.Data));
        };
        exitHandler = delegate(object sender, EventArgs args)
        {
            messages.Enqueue(new ChatGPTQuotaPetBridgeMessage("exited", null));
        };
        nextProcess.OutputDataReceived += outputHandler;
        nextProcess.ErrorDataReceived += errorHandler;
        nextProcess.Exited += exitHandler;
        lock (gate) { process = nextProcess; }
        try
        {
            if (!nextProcess.Start()) throw new InvalidOperationException("Process.Start 返回失败");
            nextProcess.StandardInput.AutoFlush = true;
            nextProcess.BeginOutputReadLine();
            nextProcess.BeginErrorReadLine();
        }
        catch
        {
            Stop();
            throw;
        }
    }

    public void SendLine(string line)
    {
        lock (gate)
        {
            if (process == null || process.HasExited) throw new InvalidOperationException("本地额度接口未运行");
            process.StandardInput.WriteLine(line);
        }
    }

    public bool TryDequeue(out ChatGPTQuotaPetBridgeMessage message)
    {
        return messages.TryDequeue(out message);
    }

    public void Stop()
    {
        Process oldProcess;
        lock (gate)
        {
            oldProcess = process;
            process = null;
        }
        if (oldProcess == null) return;
        try { if (outputHandler != null) oldProcess.OutputDataReceived -= outputHandler; } catch { }
        try { if (errorHandler != null) oldProcess.ErrorDataReceived -= errorHandler; } catch { }
        try { if (exitHandler != null) oldProcess.Exited -= exitHandler; } catch { }
        try { if (!oldProcess.HasExited) oldProcess.Kill(); } catch { }
        try { oldProcess.WaitForExit(1000); } catch { }
        try { oldProcess.Dispose(); } catch { }
        outputHandler = null;
        errorHandler = null;
        exitHandler = null;
    }

    public void Dispose()
    {
        Stop();
    }
}
'@
}

function Start-AppServer {
    Stop-AppServer
    $executable = Get-CodexExecutable
    if ($null -eq $executable) {
        Set-AppServerError -Message '未找到 codex，请确认 ChatGPT/Codex 已安装'
        return
    }

    Ensure-ProcessBridgeType
    $state = $script:AppServer
    $state.ProcessBridge = New-Object ChatGPTQuotaPetProcessBridge
    $startInfo = New-AppServerStartInfo -Executable $executable

    try {
        $state.ProcessBridge.Start($startInfo.FileName, $startInfo.Arguments)
    } catch {
        Set-AppServerError -Message ('无法启动本地额度接口：' + $_.Exception.Message)
        Stop-AppServer
        return
    }

    $state.NextId = 1
    $state.InitializeId = $state.NextId
    $state.PendingReadId = $null
    $state.PendingSince = $null
    $state.Ready = $false
    Send-AppServerMessage -Message ([ordered]@{
            jsonrpc = '2.0'
            id = $state.NextId
            method = 'initialize'
            params = [ordered]@{
                clientInfo = [ordered]@{ name = 'chatgpt-quota-pet-windows'; version = '1.0.0' }
                capabilities = [ordered]@{ experimentalApi = $true }
            }
        })
}

function Request-AppServerRead {
    $state = $script:AppServer
    if (-not $state.Ready -or $null -ne $state.PendingReadId) {
        return
    }
    $state.NextId++
    $state.PendingReadId = $state.NextId
    $state.PendingSince = [DateTimeOffset]::Now
    Send-AppServerMessage -Message ([ordered]@{
            jsonrpc = '2.0'
            id = $state.NextId
            method = 'account/rateLimits/read'
            params = $null
        })
}

function Invoke-AppServerRefresh {
    $state = $script:AppServer
    if ($null -ne $state.PendingSince -and ([DateTimeOffset]::Now - $state.PendingSince).TotalSeconds -gt 20) {
        Stop-AppServer
    }

    if (-not (Test-AppServerRunning)) {
        Start-AppServer
    } elseif ($state.Ready -and $null -eq $state.PendingReadId) {
        Request-AppServerRead
    }
}

function Handle-AppServerMessage {
    param([Parameter(Mandatory)][object]$Message)

    $state = $script:AppServer
    $method = Get-ObjectValue -Object $Message -Names @('method')
    if ([string]$method -eq 'account/rateLimits/updated') {
        $params = Get-ObjectValue -Object $Message -Names @('params')
        $limits = Get-ObjectValue -Object $params -Names @('rateLimits', 'rate_limits')
        $snapshot = New-QuotaSnapshot -Limits $limits -SampledAt ([DateTimeOffset]::Now) -SourceName 'app-server'
        if ($null -ne $snapshot) {
            $script:LiveSnapshot = $snapshot
            $script:ConnectionError = ''
            $script:Footer = Get-SnapshotFooter -Snapshot $snapshot
            Update-Ui
        }
        return
    }

    $messageId = Convert-ToNumber (Get-ObjectValue -Object $Message -Names @('id'))
    if ($null -eq $messageId) {
        return
    }
    $messageId = [int]$messageId

    if ($messageId -eq $state.InitializeId) {
        $errorObject = Get-ObjectValue -Object $Message -Names @('error')
        $errorText = Get-ObjectValue -Object $errorObject -Names @('message')
        if ($null -ne $errorText) {
            Set-AppServerError -Message ([string]$errorText)
            Stop-AppServer
            return
        }

        $state.InitializeId = $null
        $state.Ready = $true
        Send-AppServerMessage -Message ([ordered]@{
                jsonrpc = '2.0'
                method = 'initialized'
                params = [ordered]@{}
            })
        Request-AppServerRead
        return
    }

    if ($messageId -ne $state.PendingReadId) {
        return
    }

    $state.PendingReadId = $null
    $state.PendingSince = $null
    $result = Get-ObjectValue -Object $Message -Names @('result')
    $limits = Get-ObjectValue -Object $result -Names @('rateLimits', 'rate_limits')
    $snapshot = New-QuotaSnapshot -Limits $limits -SampledAt ([DateTimeOffset]::Now) -SourceName 'app-server'
    if ($null -ne $snapshot) {
        $script:LiveSnapshot = $snapshot
        $script:ConnectionError = ''
        $script:Footer = Get-SnapshotFooter -Snapshot $snapshot
        Update-Ui
        return
    }

    $errorObject = Get-ObjectValue -Object $Message -Names @('error')
    $errorText = Get-ObjectValue -Object $errorObject -Names @('message')
    if ($null -ne $errorText) {
        Set-AppServerError -Message ([string]$errorText)
    } else {
        Set-AppServerError -Message '额度接口没有返回数据'
    }
}

function Process-AppServerQueue {
    $bridge = $script:AppServer.ProcessBridge
    if ($null -eq $bridge) {
        return
    }
    $item = $null
    while ($bridge.TryDequeue([ref]$item)) {
        if ($null -eq $item) {
            continue
        }
        if ($item.Kind -eq 'stdout') {
            try {
                $message = $item.Data | ConvertFrom-Json -ErrorAction Stop
                Handle-AppServerMessage -Message $message
            } catch {
                continue
            }
        } elseif ($item.Kind -eq 'stderr') {
            $message = ([string]$item.Data).Trim()
            if ($message.Length -gt 0) {
                $script:AppServer.LastError = $message
            }
        } elseif ($item.Kind -eq 'exited') {
            if (-not (Test-AppServerRunning) -and [string]::IsNullOrEmpty($script:AppServer.LastError)) {
                Set-AppServerError -Message '本地额度接口已退出'
            }
            Stop-AppServer
        }
    }
}

function Get-CurrentSnapshot {
    if ($null -ne $script:LiveSnapshot) {
        return $script:LiveSnapshot
    }
    return $script:FallbackSnapshot
}

function Get-TrayText {
    $snapshot = Get-CurrentSnapshot
    if ($null -eq $snapshot) {
        return 'Codex 额度 · 等待数据'
    }
    $source = if ($snapshot.SourceName -eq 'app-server') { '实时' } else { '快照' }
    $text = 'Codex 额度 · 5h {0} · 7d {1} · {2}' -f (Format-Percent $snapshot.Primary.Remaining), (Format-Percent $snapshot.Secondary.Remaining), $source
    if ($text.Length -gt 63) {
        return $text.Substring(0, 63)
    }
    return $text
}

function Update-Ui {
    if ($null -ne $script:TrayIcon) {
        try { $script:TrayIcon.Text = Get-TrayText } catch {}
    }
    if ($null -ne $script:PopupForm -and -not $script:PopupForm.IsDisposed) {
        $script:PopupForm.Invalidate()
    }
}

function Refresh-Data {
    $script:FallbackSnapshot = Get-FallbackSnapshot
    Invoke-AppServerRefresh
    $display = Get-CurrentSnapshot
    if ($null -ne $display) {
        $script:Footer = Get-SnapshotFooter -Snapshot $display
    } else {
        $script:Footer = '正在连接本地额度接口…'
    }
    Update-Ui
}

function New-RoundedPath {
    param(
        [Parameter(Mandatory)][Drawing.Rectangle]$Rectangle,
        [Parameter(Mandatory)][int]$Radius
    )

    $diameter = $Radius * 2
    $path = New-Object -TypeName System.Drawing.Drawing2D.GraphicsPath
    [void]$path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    [void]$path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
    [void]$path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    [void]$path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Fill-RoundedRectangle {
    param(
        [Parameter(Mandatory)][Drawing.Graphics]$Graphics,
        [Parameter(Mandatory)][Drawing.Rectangle]$Rectangle,
        [Parameter(Mandatory)][Drawing.Brush]$Brush,
        [int]$Radius = 16
    )

    $path = New-RoundedPath -Rectangle $Rectangle -Radius $Radius
    $Graphics.FillPath($Brush, $path)
    $path.Dispose()
}

function Get-QuotaTint {
    param([AllowNull()][object]$Remaining)

    if ($null -eq $Remaining) {
        return [Drawing.Color]::FromArgb(150, 132, 138, 150)
    }
    if ([double]$Remaining -le 10) {
        return [Drawing.Color]::FromArgb(255, 240, 74, 77)
    }
    if ([double]$Remaining -le 30) {
        return [Drawing.Color]::FromArgb(255, 245, 153, 15)
    }
    return [Drawing.Color]::FromArgb(255, 20, 181, 138)
}

function Draw-QuotaRing {
    param(
        [Parameter(Mandatory)][Drawing.Graphics]$Graphics,
        [Parameter(Mandatory)][Drawing.Rectangle]$Rectangle,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][object]$Remaining,
        [Parameter(Mandatory)][Drawing.Color]$Tint
    )

    $basePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(35, 50, 65, 80), 5)
    $Graphics.DrawEllipse($basePen, $Rectangle)
    $basePen.Dispose()

    if ($null -ne $Remaining) {
        $progress = [Math]::Min(100.0, [Math]::Max(0.0, [double]$Remaining)) / 100.0
        if ($progress -gt 0) {
            $progressPen = New-Object Drawing.Pen($Tint, 5)
            $Graphics.DrawArc($progressPen, $Rectangle, -90, [single](360.0 * $progress))
            $progressPen.Dispose()
        }
    }

    $labelFont = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
    $labelBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(190, 45, 55, 70))
    $format = New-Object Drawing.StringFormat
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center
    $Graphics.DrawString($Label, $labelFont, $labelBrush, $Rectangle, $format)
    $format.Dispose()
    $labelBrush.Dispose()
    $labelFont.Dispose()
}

function Draw-QuotaCard {
    param(
        [Parameter(Mandatory)][Drawing.Graphics]$Graphics,
        [Parameter(Mandatory)][Drawing.Rectangle]$Rectangle,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Badge,
        [Parameter(Mandatory)][object]$Window,
        [Parameter(Mandatory)][double]$FallbackWindowMinutes,
        [Parameter(Mandatory)][double]$RatePeriodMinutes,
        [Parameter(Mandatory)][string]$RateUnit
    )

    $cardBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(135, 255, 255, 255))
    Fill-RoundedRectangle -Graphics $Graphics -Rectangle $Rectangle -Brush $cardBrush -Radius 19
    $cardBrush.Dispose()
    $cardPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(110, 255, 255, 255), 1)
    $cardPath = New-RoundedPath -Rectangle $Rectangle -Radius 19
    $Graphics.DrawPath($cardPen, $cardPath)
    $cardPath.Dispose()
    $cardPen.Dispose()

    $tint = Get-QuotaTint -Remaining $Window.Remaining
    $ringRect = [Drawing.Rectangle]::new($Rectangle.X + 15, $Rectangle.Y + 15, 52, 52)
    Draw-QuotaRing -Graphics $Graphics -Rectangle $ringRect -Label $Badge -Remaining $Window.Remaining -Tint $tint

    $titleFont = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
    $secondaryFont = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Regular)
    $percentFont = New-Object Drawing.Font('Microsoft YaHei UI', 17, [Drawing.FontStyle]::Bold)
    $rateFont = New-Object Drawing.Font('Microsoft YaHei UI', 8, [Drawing.FontStyle]::Bold)
    $primaryBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(220, 35, 45, 60))
    $secondaryBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(175, 75, 85, 100))
    $percentBrush = New-Object Drawing.SolidBrush($tint)

    $textX = $Rectangle.X + 82
    $Graphics.DrawString(
        (Format-Caption -Minutes $Window.WindowMinutes -Fallback $Title),
        $titleFont,
        $primaryBrush,
        [single]$textX,
        [single]($Rectangle.Y + 17)
    )
    $Graphics.DrawString(
        (Format-Reset -Timestamp $Window.ResetAt),
        $secondaryFont,
        $secondaryBrush,
        [single]$textX,
        [single]($Rectangle.Y + 44)
    )

    $rightFormat = New-Object Drawing.StringFormat
    $rightFormat.Alignment = [Drawing.StringAlignment]::Far
    $Graphics.DrawString(
        (Format-Percent $Window.Remaining),
        $percentFont,
        $percentBrush,
        [Drawing.RectangleF]::new($Rectangle.X + 254, $Rectangle.Y + 13, 87, 31),
        $rightFormat
    )
    $Graphics.DrawString(
        (Format-ConsumptionRate -Window $Window -FallbackWindowMinutes $FallbackWindowMinutes -DisplayPeriodMinutes $RatePeriodMinutes -Unit $RateUnit),
        $rateFont,
        $secondaryBrush,
        [Drawing.RectangleF]::new($Rectangle.X + 238, $Rectangle.Y + 48, 103, 20),
        $rightFormat
    )

    $rightFormat.Dispose()
    $percentBrush.Dispose()
    $secondaryBrush.Dispose()
    $primaryBrush.Dispose()
    $rateFont.Dispose()
    $percentFont.Dispose()
    $secondaryFont.Dispose()
    $titleFont.Dispose()
}

function Draw-Popup {
    param([Parameter(Mandatory)][Drawing.Graphics]$Graphics)

    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $client = $script:PopupForm.ClientSize
    $outerRect = [Drawing.Rectangle]::new(0, 0, $client.Width - 1, $client.Height - 1)
    $outerPath = New-RoundedPath -Rectangle $outerRect -Radius 20
    $background = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $outerRect,
        [Drawing.Color]::FromArgb(248, 248, 252, 255),
        [Drawing.Color]::FromArgb(244, 232, 239, 255),
        45
    )
    $Graphics.FillPath($background, $outerPath)
    $background.Dispose()

    $glowBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(32, 80, 165, 255))
    $Graphics.FillEllipse($glowBrush, [Drawing.Rectangle]::new(-90, -80, 220, 170))
    $glowBrush.Dispose()
    $purpleBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(25, 160, 125, 255))
    $Graphics.FillEllipse($purpleBrush, [Drawing.Rectangle]::new(285, 205, 190, 150))
    $purpleBrush.Dispose()

    $borderPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(150, 255, 255, 255), 1)
    $Graphics.DrawPath($borderPen, $outerPath)
    $borderPen.Dispose()
    $outerPath.Dispose()

    $iconRect = [Drawing.Rectangle]::new(17, 16, 38, 38)
    $iconBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $iconRect,
        [Drawing.Color]::FromArgb(255, 64, 145, 255),
        [Drawing.Color]::FromArgb(255, 110, 82, 235),
        45
    )
    $Graphics.FillEllipse($iconBrush, $iconRect)
    $iconBrush.Dispose()
    $gaugePen = New-Object Drawing.Pen([Drawing.Color]::White, 2)
    $Graphics.DrawArc($gaugePen, [Drawing.Rectangle]::new(25, 24, 22, 22), 205, 130)
    $Graphics.DrawLine($gaugePen, 36, 35, 41, 30)
    $gaugePen.Dispose()

    $titleFont = New-Object Drawing.Font('Microsoft YaHei UI', 14, [Drawing.FontStyle]::Bold)
    $titleBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(225, 28, 38, 52))
    $Graphics.DrawString((Get-PlanTitle -Snapshot (Get-CurrentSnapshot)), $titleFont, $titleBrush, 67, 21)
    $titleBrush.Dispose()
    $titleFont.Dispose()

    $buttonBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(95, 255, 255, 255))
    $buttonPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(155, 255, 255, 255), 1)
    $refreshRect = [Drawing.Rectangle]::new(309, 20, 30, 30)
    $closeRect = [Drawing.Rectangle]::new(347, 20, 30, 30)
    $Graphics.FillEllipse($buttonBrush, $refreshRect)
    $Graphics.DrawEllipse($buttonPen, $refreshRect)
    $Graphics.FillEllipse($buttonBrush, $closeRect)
    $Graphics.DrawEllipse($buttonPen, $closeRect)
    $buttonPen.Dispose()
    $buttonBrush.Dispose()
    $buttonFont = New-Object Drawing.Font('Segoe UI Symbol', 14, [Drawing.FontStyle]::Bold)
    $buttonTextBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(180, 42, 52, 68))
    $buttonFormat = New-Object Drawing.StringFormat
    $buttonFormat.Alignment = [Drawing.StringAlignment]::Center
    $buttonFormat.LineAlignment = [Drawing.StringAlignment]::Center
    $Graphics.DrawString('↻', $buttonFont, $buttonTextBrush, $refreshRect, $buttonFormat)
    $Graphics.DrawString('×', $buttonFont, $buttonTextBrush, $closeRect, $buttonFormat)
    $buttonFormat.Dispose()
    $buttonTextBrush.Dispose()
    $buttonFont.Dispose()

    $snapshot = Get-CurrentSnapshot
    $placeholder = [pscustomobject]@{
        Remaining = $null
        Used = $null
        ResetAt = $null
        WindowMinutes = $null
    }
    $primary = if ($null -ne $snapshot) { $snapshot.Primary } else { $placeholder }
    $secondary = if ($null -ne $snapshot) { $snapshot.Secondary } else { $placeholder }
    Draw-QuotaCard -Graphics $Graphics -Rectangle ([Drawing.Rectangle]::new(14, 72, 358, 82)) -Title '5 小时窗口剩余' -Badge '5h' -Window $primary -FallbackWindowMinutes (5 * 60) -RatePeriodMinutes 30 -RateUnit '30min'
    Draw-QuotaCard -Graphics $Graphics -Rectangle ([Drawing.Rectangle]::new(14, 164, 358, 82)) -Title '7 天窗口剩余' -Badge '7d' -Window $secondary -FallbackWindowMinutes (7 * 24 * 60) -RatePeriodMinutes (24 * 60) -RateUnit '天'

    $statusColor = if ($null -ne $snapshot -and $snapshot.SourceName -eq 'app-server') {
        [Drawing.Color]::FromArgb(255, 20, 181, 138)
    } else {
        [Drawing.Color]::FromArgb(255, 245, 153, 15)
    }
    $statusBrush = New-Object Drawing.SolidBrush($statusColor)
    $Graphics.FillEllipse($statusBrush, [Drawing.Rectangle]::new(20, 264, 7, 7))
    $statusBrush.Dispose()

    $footerFont = New-Object Drawing.Font('Microsoft YaHei UI', 8, [Drawing.FontStyle]::Regular)
    $footerBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(175, 75, 85, 100))
    $footerFormat = New-Object Drawing.StringFormat
    $footerFormat.Trimming = [Drawing.StringTrimming]::EllipsisCharacter
    $Graphics.DrawString($script:Footer, $footerFont, $footerBrush, [Drawing.RectangleF]::new(34, 258, 260, 20), $footerFormat)
    $badge = if ($null -eq $snapshot) { 'WAIT' } elseif ($snapshot.SourceName -eq 'app-server') { 'LIVE' } else { 'SNAPSHOT' }
    $badgeFont = New-Object Drawing.Font('Microsoft YaHei UI', 7, [Drawing.FontStyle]::Bold)
    $badgeBrush = New-Object Drawing.SolidBrush($statusColor)
    $badgeFormat = New-Object Drawing.StringFormat
    $badgeFormat.Alignment = [Drawing.StringAlignment]::Far
    $Graphics.DrawString($badge, $badgeFont, $badgeBrush, [Drawing.RectangleF]::new(294, 258, 76, 20), $badgeFormat)
    $badgeFormat.Dispose()
    $badgeBrush.Dispose()
    $badgeFont.Dispose()
    $footerFormat.Dispose()
    $footerBrush.Dispose()
    $footerFont.Dispose()
}

function Hide-Popup {
    if ($null -ne $script:PopupForm -and -not $script:PopupForm.IsDisposed -and $script:PopupForm.Visible) {
        $script:PopupForm.Hide()
    }
}

function Show-Popup {
    if ($null -eq $script:PopupForm -or $script:PopupForm.IsDisposed) {
        return
    }

    $cursor = [Windows.Forms.Cursor]::Position
    $screen = [Windows.Forms.Screen]::FromPoint($cursor)
    $area = $screen.WorkingArea
    $width = $script:PopupForm.Width
    $height = $script:PopupForm.Height
    $x = [Math]::Max($area.Left + 8, $area.Right - $width - 12)
    $y = [Math]::Max($area.Top + 8, $area.Bottom - $height - 12)
    $script:PopupForm.Location = [Drawing.Point]::new($x, $y)
    $script:PopupForm.Show()
    $script:PopupForm.Activate()
}

function Toggle-Popup {
    if ($null -ne $script:PopupForm -and $script:PopupForm.Visible) {
        Hide-Popup
    } else {
        Show-Popup
    }
}

function New-NotifyIconImage {
    param([AllowNull()][string]$IconPath)

    $target = [Drawing.Bitmap]::new(32, 32)
    $graphics = [Drawing.Graphics]::FromImage($target)
    $graphics.Clear([Drawing.Color]::Transparent)
    $source = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($IconPath) -and (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
            $source = [Drawing.Image]::FromFile($IconPath)
            $graphics.DrawImage($source, [Drawing.Rectangle]::new(0, 0, 32, 32))
        } else {
            $brush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 64, 145, 255))
            $graphics.FillEllipse($brush, [Drawing.Rectangle]::new(2, 2, 28, 28))
            $brush.Dispose()
            $pen = New-Object Drawing.Pen([Drawing.Color]::White, 2)
            $graphics.DrawArc($pen, [Drawing.Rectangle]::new(8, 8, 16, 16), 205, 130)
            $graphics.DrawLine($pen, 16, 17, 20, 13)
            $pen.Dispose()
        }

        $hIcon = $target.GetHicon()
        $nativeIcon = [Drawing.Icon]::FromHandle($hIcon)
        $result = [Drawing.Icon]$nativeIcon.Clone()
        $nativeIcon.Dispose()
        return $result
    } finally {
        if ($null -ne $source) {
            $source.Dispose()
        }
        $graphics.Dispose()
        $target.Dispose()
    }
}

function Initialize-Ui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    [Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $form = New-Object Windows.Forms.Form
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $form.ClientSize = [Drawing.Size]::new(386, 292)
    $form.BackColor = [Drawing.Color]::FromArgb(244, 249, 255)
    $form.Opacity = 0.98
    $form.KeyPreview = $true
    $regionPath = New-RoundedPath -Rectangle ([Drawing.Rectangle]::new(0, 0, 386, 292)) -Radius 20
    $form.Region = New-Object Drawing.Region($regionPath)
    $regionPath.Dispose()
    $form.Add_Paint({
        param($sender, $eventArgs)
        Draw-Popup -Graphics $eventArgs.Graphics
    })
    $form.Add_MouseDown({
        param($sender, $eventArgs)
        if ($eventArgs.Button -ne [Windows.Forms.MouseButtons]::Left) {
            return
        }
        if ($eventArgs.X -ge 309 -and $eventArgs.X -lt 339 -and $eventArgs.Y -ge 20 -and $eventArgs.Y -lt 50) {
            Refresh-Data
            return
        }
        if ($eventArgs.X -ge 347 -and $eventArgs.X -lt 377 -and $eventArgs.Y -ge 20 -and $eventArgs.Y -lt 50) {
            Hide-Popup
        }
    })
    $form.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $sender.Hide()
            $eventArgs.SuppressKeyPress = $true
        }
    })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $script:AllowFormClose) {
            $eventArgs.Cancel = $true
            $sender.Hide()
        }
    })
    $form.Add_Deactivate({
        param($sender, $eventArgs)
        if (-not $script:AllowFormClose) {
            $sender.Hide()
        }
    })
    $script:PopupForm = $form
}

function Initialize-Tray {
    $iconPath = Join-Path $PSScriptRoot '..\macOS\AppIcon.png'
    $script:TrayIconImage = New-NotifyIconImage -IconPath $iconPath
    $script:TrayIcon = New-Object Windows.Forms.NotifyIcon
    $script:TrayIcon.Icon = $script:TrayIconImage
    $script:TrayIcon.Visible = $true
    $script:TrayIcon.Text = 'Codex 额度 · 等待数据'

    $menu = New-Object Windows.Forms.ContextMenuStrip
    $showItem = $menu.Items.Add('显示额度')
    $refreshItem = $menu.Items.Add('立即刷新')
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $quitItem = $menu.Items.Add('退出')
    $menu.Add_Opening({
        Hide-Popup
    })
    $showItem.Add_Click({ Show-Popup })
    $refreshItem.Add_Click({ Refresh-Data })
    $quitItem.Add_Click({ Stop-Application })
    $script:TrayMenu = $menu
    $script:TrayIcon.ContextMenuStrip = $menu
    $script:TrayIcon.Add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) {
            Toggle-Popup
        }
    })
}

function Stop-Application {
    $script:AllowFormClose = $true
    if ($null -ne $script:RefreshTimer) {
        $script:RefreshTimer.Stop()
        $script:RefreshTimer.Dispose()
        $script:RefreshTimer = $null
    }
    Stop-AppServer
    if ($null -ne $script:PopupForm -and -not $script:PopupForm.IsDisposed) {
        try { $script:PopupForm.Close() } catch {}
        try { $script:PopupForm.Dispose() } catch {}
    }
    if ($null -ne $script:TrayIcon) {
        try { $script:TrayIcon.Visible = $false } catch {}
        try { $script:TrayIcon.Dispose() } catch {}
        $script:TrayIcon = $null
    }
    if ($null -ne $script:TrayMenu) {
        try { $script:TrayMenu.Dispose() } catch {}
        $script:TrayMenu = $null
    }
    if ($null -ne $script:TrayIconImage) {
        try { $script:TrayIconImage.Dispose() } catch {}
        $script:TrayIconImage = $null
    }
    try { [Windows.Forms.Application]::ExitThread() } catch {}
}

function Invoke-UiSelfTest {
    if ($env:OS -ne 'Windows_NT') {
        throw 'UI 自检只能在 Windows 上运行。'
    }

    try {
        Initialize-Ui
        Initialize-Tray
        Show-Popup
        if (-not $script:PopupForm.Visible) {
            throw '详情窗口无法显示'
        }
        Hide-Popup
        if ($script:PopupForm.Visible) {
            throw '详情窗口无法隐藏'
        }
        if ($null -eq $script:TrayIcon.ContextMenuStrip -or $script:TrayIcon.ContextMenuStrip.Items.Count -ne 4) {
            throw '系统托盘菜单未正确建立'
        }
        Write-Output 'Windows UI self-test passed.'
        $script:UiSelfTestExitCode = 0
    } finally {
        Stop-Application
    }
}

function Invoke-SelfTest {
    $now = [DateTimeOffset]::Now
    $limits = [pscustomobject]@{
        plan_type = 'plus'
        primary = [pscustomobject]@{
            used_percent = 24
            resets_at = $now.AddMinutes(30).ToUnixTimeSeconds()
            window_minutes = 300
        }
        secondary = [pscustomobject]@{
            used_percent = 76
            resets_at = $now.AddDays(4).ToUnixTimeSeconds()
            window_minutes = 10080
        }
    }
    $snapshot = New-QuotaSnapshot -Limits $limits -SampledAt $now -SourceName 'self-test'
    if ($null -eq $snapshot) { throw '无法建立测试快照' }
    if ([Math]::Abs($snapshot.Primary.Remaining - 76) -gt 0.001) { throw '5 小时剩余比例解析失败' }
    if ([Math]::Abs($snapshot.Secondary.Remaining - 24) -gt 0.001) { throw '7 天剩余比例解析失败' }
    if ((Format-Caption -Minutes 10080 -Fallback 'fallback') -ne '7 天窗口剩余') { throw '窗口标题格式化失败' }
    if ((Format-ShortError -ErrorMessage 'codex executable not found') -ne '未找到 codex') { throw '错误信息格式化失败' }
    Write-Output 'Windows self-test passed.'
    $script:SelfTestExitCode = 0
}

function Invoke-Probe {
    Start-AppServer
    $deadline = [DateTimeOffset]::Now.AddSeconds(8)
    while ([DateTimeOffset]::Now -lt $deadline -and $null -eq $script:LiveSnapshot) {
        Process-AppServerQueue
        Start-Sleep -Milliseconds 50
    }
    Process-AppServerQueue

    $snapshot = $script:LiveSnapshot
    if ($null -eq $snapshot) {
        $snapshot = Get-FallbackSnapshot
    }
    if ($null -ne $snapshot) {
        $result = [ordered]@{
            Status = 'ok'
            PlanType = $snapshot.PlanType
            FiveHourRemain = $snapshot.Primary.Remaining
            WeeklyRemain = $snapshot.Secondary.Remaining
            SampledAt = $snapshot.SampledAt.ToUniversalTime().ToString('o')
            SourceName = $snapshot.SourceName
        }
        $result | ConvertTo-Json -Depth 4
        Stop-AppServer
        $script:ProbeExitCode = 0
        return
    }

    $message = if ([string]::IsNullOrEmpty($script:AppServer.LastError)) { '没有找到可读取的 Codex 限额快照' } else { $script:AppServer.LastError }
    [ordered]@{ Status = 'unavailable'; Message = $message } | ConvertTo-Json -Depth 4
    Stop-AppServer
    $script:ProbeExitCode = 1
}

if ($SelfTest) {
    Invoke-SelfTest
    exit $script:SelfTestExitCode
}

if ($Probe) {
    Invoke-Probe
    exit $script:ProbeExitCode
}

if ($env:OS -ne 'Windows_NT') {
    throw '此版本只能在 Windows 上运行。'
}

if ($UiSelfTest) {
    Invoke-UiSelfTest
    exit $script:UiSelfTestExitCode
}

try {
    Initialize-Ui
    Initialize-Tray
    Refresh-Data

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = [int]($script:RefreshSeconds * 1000)
    $timer.Add_Tick({
        Process-AppServerQueue
        Refresh-Data
    })
    $script:RefreshTimer = $timer
    $timer.Start()
    [Windows.Forms.Application]::Run()
} finally {
    Stop-Application
}
