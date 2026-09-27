[CmdletBinding()]
param(
    [int]$HostPid = 0,
    [string]$StopEventName = "",
    [switch]$VisibleStartup
)

$CheckIntervalMs = 200
$TriggerCount = 2
$StartupTimeoutMs = 30000
$RecoveryTimeoutMs = 180000
$StartupStableChecks = 3
$StartupGraceMs = 4000
$RecoveryStableChecks = 5
$PostReadyDelayMs = 1200
$PostNextDelayMs = 500
$script:SpotifyExecutablePath = $null
$logRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA "Skiptify\Logs" }
$LogDirectory = $logRoot
$LogPath = Join-Path -Path $LogDirectory -ChildPath "skiptify.log"
$script:StopEvent = $null
$script:EngineMutex = $null
$script:StatusOutputEnabled = $HostPid -gt 0
$script:VisibleStartupRequested = [bool]$VisibleStartup
$script:StartupGraceUntilUtc = [DateTime]::MinValue

$IgnoredTitles = @(
    "Spotify Free"
)

if ($null -eq ("SpotifyControl" -as [type])) {
    Add-Type @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public class SpotifyControl
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out IntPtr result
    );

    const uint WM_APPCOMMAND = 0x0319;

    public static void Next(IntPtr hWnd)
    {
        Send(hWnd, new IntPtr(11 << 16));
    }

    public static void Play(IntPtr hWnd)
    {
        Send(hWnd, new IntPtr(46 << 16));
    }

    public static void Pause(IntPtr hWnd)
    {
        Send(hWnd, new IntPtr(47 << 16));
    }

    private static void Send(IntPtr hWnd, IntPtr command)
    {
        IntPtr result;
        const uint SMTO_ABORTIFHUNG = 0x0002;
        if (SendMessageTimeout(hWnd, WM_APPCOMMAND, hWnd, command, SMTO_ABORTIFHUNG, 1000, out result) == IntPtr.Zero)
        {
            throw new InvalidOperationException("Spotify window did not respond within 1000 ms.");
        }
    }
}
"@
}

if ($null -eq ("WindowControl" -as [type])) {
    Add-Type @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public class WindowControl
{
    private const uint WM_CLOSE = 0x0010;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    public const int SW_SHOWMINNOACTIVE = 7;

    public sealed class SpotifyWindowInfo
    {
        public int Id { get; set; }
        public IntPtr MainWindowHandle { get; set; }
        public string MainWindowTitle { get; set; }
        public bool Responding { get; set; }
        public bool HasExited { get; set; }
        public string Path { get; set; }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsHungAppWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint msg,
        IntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out IntPtr result);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static bool RestoreHiddenSpotifyWindow(bool visible)
    {
        bool restored = false;
        EnumWindows(delegate(IntPtr hWnd, IntPtr state)
        {
            if (IsWindowVisible(hWnd)) return true;
            var className = new StringBuilder(256);
            GetClassName(hWnd, className, className.Capacity);
            if (className.ToString() != "Chrome_WidgetWin_1") return true;
            var title = new StringBuilder(1024);
            GetWindowText(hWnd, title, title.Capacity);
            if (title.Length == 0) return true;
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            try
            {
                using (Process process = Process.GetProcessById((int)processId))
                {
                    if (!String.Equals(process.ProcessName, "Spotify", StringComparison.OrdinalIgnoreCase)) return true;
                    restored = ShowWindowAsync(hWnd, visible ? 9 : SW_SHOWMINNOACTIVE);
                    return !restored;
                }
            }
            catch { return true; }
        }, IntPtr.Zero);
        return restored;
    }

    public static bool RequestClose(IntPtr hWnd, uint timeoutMs)
    {
        if (hWnd == IntPtr.Zero) return false;
        IntPtr result;
        return SendMessageTimeout(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero,
            SMTO_ABORTIFHUNG, timeoutMs, out result) != IntPtr.Zero;
    }

    public static IntPtr FindSpotifyErrorWindow()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr state)
        {
            var title = new StringBuilder(256);
            GetWindowText(hWnd, title, title.Capacity);
            string text = title.ToString();
            if (text.IndexOf("Spotify.exe", StringComparison.OrdinalIgnoreCase) >= 0
                && text.IndexOf("Application Error", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static SpotifyWindowInfo GetSpotifyWindow()
    {
        Process[] processes = Process.GetProcessesByName("Spotify");
        try
        {
            foreach (Process process in processes)
            {
                try
                {
                    IntPtr handle = process.MainWindowHandle;
                    if (handle == IntPtr.Zero || !IsWindowVisible(handle)) continue;
                    var title = new StringBuilder(256);
                    GetWindowText(handle, title, title.Capacity);
                    return new SpotifyWindowInfo
                    {
                        Id = process.Id,
                        MainWindowHandle = handle,
                        MainWindowTitle = title.ToString(),
                        Responding = !IsHungAppWindow(handle),
                        HasExited = false,
                        Path = null
                    };
                }
                catch
                {
                    // A helper can exit while windows are enumerated.
                }
            }
            return null;
        }
        finally
        {
            foreach (Process process in processes)
            {
                try { process.Dispose(); } catch { }
            }
        }
    }
}
"@
}

function Write-SkiptifyLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message

    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
        }
        $incomingBytes = [Text.Encoding]::UTF8.GetByteCount($line + [Environment]::NewLine)
        if (Test-Path -LiteralPath $script:LogPath -PathType Leaf) {
            $current = Get-Item -LiteralPath $script:LogPath -ErrorAction Stop
            if ($current.Length + $incomingBytes -gt 1MB) {
                $archive = Join-Path $script:LogDirectory "skiptify.1.log"
                if (Test-Path -LiteralPath $archive -PathType Leaf) {
                    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $script:LogPath -Destination $archive -Force -ErrorAction Stop
            }
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # An unusual ACL or read-only profile should not stop monitoring. Use the
        # script directory as a fallback when the per-user log directory fails.
        if ($script:LogDirectory -ne $PSScriptRoot) {
            try {
                $script:LogDirectory = $PSScriptRoot
                $script:LogPath = Join-Path $PSScriptRoot "skiptify.log"
                Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
                return
            }
            catch {
            }
        }
        Write-Warning "Skiptify could not write to '$script:LogPath': $($_.Exception.Message)"
    }
}

function Write-SkiptifyStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Memulai", "Aktif", "Memulihkan", "Menghentikan", "Off", "Gagal", "Konflik", "OverlayPrepare", "OverlayRelease")]
        [string]$Status,
        [string]$Message = "",
        [string]$RecoveryId = "",
        [string]$EventName = "",
        [int]$ProcessId = 0,
        [IntPtr]$WindowHandle = [IntPtr]::Zero,
        $Process = $null
    )

    if (-not $script:StatusOutputEnabled) {
        return
    }

    try {
        $payload = [ordered]@{
            status = $Status
            message = $Message
            timestamp = (Get-Date).ToString("o")
        }
        if (-not [string]::IsNullOrWhiteSpace($RecoveryId)) { $payload.recoveryId = $RecoveryId }
        if (-not [string]::IsNullOrWhiteSpace($EventName)) { $payload.eventName = $EventName }
        if ($ProcessId -eq 0 -and $Process) {
            try { $ProcessId = [int]$Process.Id } catch { }
        }
        if ($WindowHandle -eq [IntPtr]::Zero -and $Process) {
            try { $WindowHandle = [IntPtr]$Process.MainWindowHandle } catch { }
        }
        if ($ProcessId -ne 0) { $payload.processId = $ProcessId }
        if ($WindowHandle -ne [IntPtr]::Zero) { $payload.windowHandle = [Int64]$WindowHandle }
        $json = [PSCustomObject]$payload | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($json)
        [Console]::Out.Flush()
    }
    catch {
        # Status reporting must never stop the Spotify worker.
    }
}

function Request-SkiptifyOverlay {
    param(
        [Parameter(Mandatory = $true)]
        $Process
    )

    # The legacy VBS launcher has no UI host and therefore never requests an
    # overlay. This keeps the original worker path unchanged for that launcher.
    if (-not $script:StatusOutputEnabled -or $null -eq $Process) {
        return $null
    }

    try {
        $windowHandle = [IntPtr]$Process.MainWindowHandle
        if ($windowHandle -eq [IntPtr]::Zero -or $Process.HasExited) {
            return $null
        }
    }
    catch {
        return $null
    }

    $recoveryId = [Guid]::NewGuid().ToString("N")
    $eventName = "Local\Skiptify.Overlay.Ready.$recoveryId"
    $readyEvent = $null
    try {
        $readyEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $eventName)
        $readyEvent.Reset() | Out-Null
    }
    catch {
        Write-SkiptifyLog "Overlay handshake event could not be created: $($_.Exception.Message)"
        return [PSCustomObject]@{ RecoveryId = $recoveryId; EventName = $eventName; Ready = $false; Cancelled = $false }
    }

    Write-SkiptifyStatus -Status "OverlayPrepare" -Message "Menyiapkan tampilan sementara." -RecoveryId $recoveryId -EventName $eventName -Process $Process
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    $cancelled = $false
    try {
        while ($stopwatch.ElapsedMilliseconds -lt 500) {
            if (Test-SkiptifyStopRequested) {
                $cancelled = $true
                break
            }
            try {
                if ($readyEvent.WaitOne(0)) {
                    $ready = $true
                    break
                }
            }
            catch {
                $cancelled = $true
                break
            }
            Start-Sleep -Milliseconds 10
        }
    }
    finally {
        try { $readyEvent.Dispose() } catch { }
    }

    if (-not $ready -and -not $cancelled) {
        Write-SkiptifyLog "Overlay preparation timed out after $($stopwatch.ElapsedMilliseconds) ms; using normal recovery."
    }

    [PSCustomObject]@{
        RecoveryId = $recoveryId
        EventName = $eventName
        Ready = $ready
        Cancelled = $cancelled
    }
}

function Test-SkiptifyStopRequested {
    if ($script:StopEvent) {
        try {
            if ($script:StopEvent.WaitOne(0)) {
                return $true
            }
        }
        catch {
            return $true
        }
    }

    if ($HostPid -gt 0) {
        try {
            return [Diagnostics.Process]::GetProcessById($HostPid).HasExited
        }
        catch {
            return $true
        }
    }

    return $false
}

function Initialize-SkiptifyControl {
    if (-not [string]::IsNullOrWhiteSpace($StopEventName)) {
        try {
            $script:StopEvent = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
        }
        catch {
            $script:StopEvent = $null
        }
    }

    try {
        $script:EngineMutex = New-Object System.Threading.Mutex($false, "Local\Skiptify.Engine.1.0")
        $acquired = $false
        try {
            $acquired = $script:EngineMutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            Write-SkiptifyStatus -Status "Konflik" -Message "Skiptify sudah berjalan."
            try { $script:EngineMutex.Dispose() } catch {}
            $script:EngineMutex = $null
            return $false
        }
        return $true
    }
    catch {
        Write-SkiptifyStatus -Status "Gagal" -Message "Tidak dapat mengunci proses Skiptify."
        return $false
    }
}

function Dispose-SkiptifyControl {
    if ($script:EngineMutex) {
        try { $script:EngineMutex.ReleaseMutex() } catch {}
        try { $script:EngineMutex.Dispose() } catch {}
        $script:EngineMutex = $null
    }
    if ($script:StopEvent) {
        try { $script:StopEvent.Dispose() } catch {}
        $script:StopEvent = $null
    }
}

function Get-SpotifyProcesses {
    @(Get-Process -Name Spotify -ErrorAction SilentlyContinue)
}

function Get-SpotifyWindowSnapshot {
    try {
        return [WindowControl]::GetSpotifyWindow()
    }
    catch {
        return $null
    }
}

function Test-SpotifyApplicationErrorWindow {
    try {
        return [WindowControl]::FindSpotifyErrorWindow() -ne [IntPtr]::Zero
    }
    catch {
        return $false
    }
}

function Test-SpotifyWindow {
    param(
        [Parameter(Mandatory = $true)]
        $Process,
        [switch]$RequireFreeTitle
    )

    try {
        if ($Process.MainWindowHandle -eq [IntPtr]::Zero -or -not $Process.Responding) {
            return $false
        }

        if ($RequireFreeTitle -and $Process.MainWindowTitle -ne "Spotify Free") {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-SpotifyMainWindow {
    $spotify = Get-SpotifyWindowSnapshot

    if ($spotify -and (Test-SpotifyWindow -Process $spotify) -and $spotify.MainWindowTitle -ne "") {
        return $spotify
    }

    return $null
}

function Get-SpotifyWindowByIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId,
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle,
        [switch]$RequireFreeTitle
    )

    $spotify = Get-SpotifyWindowSnapshot

    if (-not $spotify -or -not (Test-SpotifyWindow -Process $spotify -RequireFreeTitle:$RequireFreeTitle)) {
        return $null
    }

    try {
        if ($spotify.Id -ne $ProcessId -or [Int64]$spotify.MainWindowHandle -ne [Int64]$WindowHandle) {
            return $null
        }
    }
    catch {
        return $null
    }

    return $spotify
}

function Get-SpotifyWindowDescription {
    param($Process)

    if ($null -eq $Process) {
        return "PID=<none>; Handle=<none>; Title=<none>"
    }

    try {
        return "PID={0}; Handle={1}; Title='{2}'" -f $Process.Id, $Process.MainWindowHandle, $Process.MainWindowTitle
    }
    catch {
        return "PID=<unavailable>; Handle=<unavailable>; Title=<unavailable>"
    }
}

function New-SkiptifyResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Started", "CommandsSent", "TimedOut", "Failed", "Stopped")]
        [string]$Status,
        [string]$Reason,
        $Process
    )

    [PSCustomObject]@{
        Status = $Status
        Reason = $Reason
        Process = $Process
    }
}

function Start-SpotifyUri {
    param(
        [switch]$Visible,
        [switch]$Background
    )

    # Hidden can leave Spotify running without a discoverable window.
    $windowStyle = if ($Visible) { "Normal" } else { "Minimized" }
    # Cache the running executable before recovery kills its processes.
    # The URI remains a fallback for installations that cannot launch directly.
    $candidates = @($script:SpotifyExecutablePath)
    if ($env:APPDATA) {
        $candidates += Join-Path $env:APPDATA "Spotify\Spotify.exe"
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        try {
            $launchOptions = @{
                FilePath = $candidate
                WindowStyle = $windowStyle
                ErrorAction = 'Stop'
            }
            # STARTUPINFO alone does not prevent Spotify from showing its own
            # startup window before the polling loop can minimize it.
            if ($Background -and -not $Visible) {
                $launchOptions.ArgumentList = '--minimized'
            }
            Start-Process @launchOptions
            Write-SkiptifyLog "Spotify executable launched with window style '$windowStyle'; background=$Background."
            return $true
        }
        catch {
            Write-SkiptifyLog "Direct Spotify launch failed: $($_.Exception.Message)"
        }
    }

    try {
        Start-Process -FilePath "spotify:" -WindowStyle $windowStyle -ErrorAction Stop
        Write-SkiptifyLog "Spotify URI opened with window style '$windowStyle'."
        return $true
    }
    catch {
        Write-SkiptifyLog "Spotify URI failed to open: $($_.Exception.Message)"
        return $false
    }
}

function Stop-SpotifyProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Processes
    )

    $targets = @($Processes)
    foreach ($process in $targets) {
        try {
            if ($process.HasExited) {
                continue
            }

            $windowHandle = [IntPtr]$process.MainWindowHandle
            if ($windowHandle -ne [IntPtr]::Zero) {
                [WindowControl]::RequestClose($windowHandle, 1000) | Out-Null
            }
        }
        catch {
            # A process can disappear while the graceful request is sent.
        }
    }

    $remaining = @($targets | Where-Object {
        try { -not $_.HasExited } catch { $false }
    })
    if ($remaining.Count -gt 0) {
        Wait-SpotifyProcessesExit -Processes $remaining -TimeoutMs 1500
    }

    $remaining = @($targets | Where-Object {
        try { -not $_.HasExited } catch { $false }
    })
    if ($remaining.Count -gt 0) {
        Write-SkiptifyLog "Graceful Spotify close timed out for $($remaining.Count) process(es); forcing only those PIDs."
        foreach ($process in $remaining) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
    }
}

function Wait-SpotifyProcessesExit {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Processes,
        [int]$TimeoutMs = 5000
    )

    $ids = @($Processes | ForEach-Object { $_.Id })
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($ids.Count -gt 0 -and $stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        $ids = @($ids | Where-Object {
            try { -not (Get-Process -Id $_ -ErrorAction Stop).HasExited }
            catch { $false }
        })
        if ($ids.Count -gt 0) {
            Start-Sleep -Milliseconds 50
        }
    }
}

function Minimize-SpotifyWindow {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle
    )

    if ($WindowHandle -ne [IntPtr]::Zero -and -not [WindowControl]::IsIconic($WindowHandle)) {
        [WindowControl]::ShowWindowAsync($WindowHandle, [WindowControl]::SW_SHOWMINNOACTIVE) | Out-Null
    }
}

function Send-SpotifyAppCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Next", "Play", "Pause")]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [IntPtr]$WindowHandle
    )

    switch ($Command) {
        "Next"  { [SpotifyControl]::Next($WindowHandle) }
        "Play"  { [SpotifyControl]::Play($WindowHandle) }
        "Pause" { [SpotifyControl]::Pause($WindowHandle) }
    }
}

function Wait-ForSpotifyMainWindow {
    param(
        [int]$TimeoutMs = $StartupTimeoutMs,
        [int]$RequiredStableChecks = $StartupStableChecks,
        [bool]$MinimizeDuringWait = $true
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stableCount = 0
    $expectedProcessId = $null
    $expectedWindowHandle = $null
    $lastSnapshot = $null

    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-SkiptifyStopRequested) {
            return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima."
        }

        if (Test-SpotifyApplicationErrorWindow) {
            $reason = "Spotify menampilkan dialog error aplikasi."
            Write-SkiptifyLog "Spotify launch stopped because an Application Error dialog was detected."
            return New-SkiptifyResult -Status "Failed" -Reason $reason -Process $lastSnapshot
        }

        $snapshot = Get-SpotifyWindowSnapshot
        $lastSnapshot = $snapshot

        if ($snapshot -and $MinimizeDuringWait) {
            Minimize-SpotifyWindow -WindowHandle $snapshot.MainWindowHandle
        }

        if ($snapshot -and (Test-SpotifyWindow -Process $snapshot)) {
            try {
                $sameWindow = $snapshot.Id -eq $expectedProcessId -and [Int64]$snapshot.MainWindowHandle -eq [Int64]$expectedWindowHandle
                if ($sameWindow) {
                    $stableCount++
                }
                else {
                    $expectedProcessId = $snapshot.Id
                    $expectedWindowHandle = $snapshot.MainWindowHandle
                    $stableCount = 1
                }

                if ($stableCount -ge $RequiredStableChecks) {
                    return New-SkiptifyResult -Status "Started" -Process $snapshot
                }
            }
            catch {
                $stableCount = 0
                $expectedProcessId = $null
                $expectedWindowHandle = $null
            }
        }
        else {
            $stableCount = 0
            $expectedProcessId = $null
            $expectedWindowHandle = $null
        }

        Start-Sleep -Milliseconds $CheckIntervalMs
    }

    return New-SkiptifyResult -Status "TimedOut" -Reason "No responsive Spotify window became stable within $TimeoutMs ms." -Process $lastSnapshot
}

function Wait-ForSpotifyFreeReady {
    param(
        [int]$TimeoutMs = $RecoveryTimeoutMs,
        [int]$RequiredStableChecks = $RecoveryStableChecks,
        [switch]$IgnoreStop,
        [bool]$MinimizeDuringWait = $true
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stableCount = 0
    $expectedProcessId = $null
    $expectedWindowHandle = $null
    $lastSnapshot = $null

    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not $IgnoreStop -and (Test-SkiptifyStopRequested)) {
            return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima."
        }

        if (Test-SpotifyApplicationErrorWindow) {
            $reason = "Spotify menampilkan dialog error aplikasi."
            Write-SkiptifyLog "Spotify recovery stopped because an Application Error dialog was detected."
            return New-SkiptifyResult -Status "Failed" -Reason $reason -Process $lastSnapshot
        }

        $snapshot = Get-SpotifyWindowSnapshot
        $lastSnapshot = $snapshot

        if ($snapshot -and $MinimizeDuringWait) {
            Minimize-SpotifyWindow -WindowHandle $snapshot.MainWindowHandle
        }

        if ($snapshot -and (Test-SpotifyWindow -Process $snapshot -RequireFreeTitle)) {
            try {
                $sameWindow = $snapshot.Id -eq $expectedProcessId -and [Int64]$snapshot.MainWindowHandle -eq [Int64]$expectedWindowHandle
                if ($sameWindow) {
                    $stableCount++
                }
                else {
                    $expectedProcessId = $snapshot.Id
                    $expectedWindowHandle = $snapshot.MainWindowHandle
                    $stableCount = 1
                }

                if ($stableCount -ge $RequiredStableChecks) {
                    Write-SkiptifyLog "Spotify recovery ready after $stableCount stable checks: $(Get-SpotifyWindowDescription $snapshot)"
                    return New-SkiptifyResult -Status "Started" -Process $snapshot
                }
            }
            catch {
                $stableCount = 0
                $expectedProcessId = $null
                $expectedWindowHandle = $null
            }
        }
        else {
            $stableCount = 0
            $expectedProcessId = $null
            $expectedWindowHandle = $null
        }

        Start-Sleep -Milliseconds $CheckIntervalMs
    }

    $reason = "Spotify Free was not stable for $RequiredStableChecks checks within $TimeoutMs ms. Last seen: $(Get-SpotifyWindowDescription $lastSnapshot)"
    Write-SkiptifyLog "Recovery timed out: $reason"
    return New-SkiptifyResult -Status "TimedOut" -Reason $reason -Process $lastSnapshot
}

function Restore-SpotifyHiddenWindow {
    param([bool]$Visible)
    return [WindowControl]::RestoreHiddenSpotifyWindow($Visible)
}

function Start-SpotifySmooth {
    Write-SkiptifyLog "Spotify has no ready window; opening without playback commands."

    if (Test-SkiptifyStopRequested) {
        return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima."
    }

    $visibleStartup = $script:VisibleStartupRequested
    $restored = Restore-SpotifyHiddenWindow -Visible $visibleStartup
    if ($restored) {
        Write-SkiptifyLog "Restored an existing hidden Spotify window without launching another process."
    }
    elseif (-not (Start-SpotifyUri -Visible:$visibleStartup)) {
        return New-SkiptifyResult -Status "Failed" -Reason "Unable to open Spotify URI."
    }

    if (Test-SkiptifyStopRequested) {
        return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima."
    }

    $ready = Wait-ForSpotifyMainWindow -MinimizeDuringWait:(-not $visibleStartup)
    if ($ready.Status -eq "Stopped") {
        return $ready
    }
    if ($ready.Status -ne "Started") {
        $reason = "$($ready.Reason) Last seen: $(Get-SpotifyWindowDescription $ready.Process)"
        Write-SkiptifyLog "Startup failed: $reason"
        return New-SkiptifyResult -Status "Failed" -Reason $reason -Process $ready.Process
    }

    if (-not $visibleStartup) {
        Minimize-SpotifyWindow -WindowHandle $ready.Process.MainWindowHandle
    }
    # Spotify may expose a generic "Spotify" title for a few seconds while
    # its account/session UI settles. Do not interpret that startup state as an
    # advertisement and do not restart the process a second time.
    $script:StartupGraceUntilUtc = [DateTime]::UtcNow.AddMilliseconds($StartupGraceMs)
    Write-SkiptifyLog "Spotify startup completed: $(Get-SpotifyWindowDescription $ready.Process)"
    return $ready
}

function Restart-SpotifySmooth {
    Write-SkiptifyLog "Recovery started."

    $overlayRequest = $null
    $overlayRecoveryId = ""
    $handoffProcess = $null

    try {
        if (Test-SkiptifyStopRequested) {
            return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima."
        }

        $oldSpotify = Get-SpotifyMainWindow

        # Ask the desktop host to capture the visible Spotify window before any
        # playback command or process termination. The VBS launcher has no host
        # PID, so this remains a no-op for the legacy path.
        if ($oldSpotify) {
            $overlayRequest = Request-SkiptifyOverlay -Process $oldSpotify
            if ($overlayRequest) {
                $overlayRecoveryId = $overlayRequest.RecoveryId
                if ($overlayRequest.Cancelled) {
                    return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima sebelum Spotify dijeda." -Process $oldSpotify
                }
            }

            try {
                Send-SpotifyAppCommand -Command "Pause" -WindowHandle $oldSpotify.MainWindowHandle
            }
            catch {
                Write-SkiptifyLog "Could not pause Spotify before recovery: $($_.Exception.Message)"
            }
        }

        $overlayReady = $overlayRequest -and $overlayRequest.Ready
        Start-Sleep -Milliseconds 100

        $oldProcesses = @(Get-SpotifyProcesses)
        foreach ($process in $oldProcesses) {
            try {
                if ($process.Path) {
                    $script:SpotifyExecutablePath = $process.Path
                    break
                }
            }
            catch {
                # Some packaged installations do not expose their executable path.
            }
        }
        if (Test-SkiptifyStopRequested) {
            return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima sebelum Spotify dihentikan." -Process $oldSpotify
        }
        if ($oldProcesses.Count -gt 0) {
            try {
                Stop-SpotifyProcesses -Processes $oldProcesses
            }
            catch {
                $reason = "Could not stop Spotify during recovery: $($_.Exception.Message)"
                Write-SkiptifyLog "Recovery failed: $reason"
                return New-SkiptifyResult -Status "Failed" -Reason $reason -Process $oldSpotify
            }

            Wait-SpotifyProcessesExit -Processes $oldProcesses -TimeoutMs 5000
        }

        if (-not (Start-SpotifyUri -Background:(-not $overlayReady))) {
            $reason = "Unable to open Spotify URI during recovery."
            Write-SkiptifyLog "Recovery failed: $reason"
            return New-SkiptifyResult -Status "Failed" -Reason $reason
        }

        # If Spotify was already terminated when Off arrived, restore the app but
        # deliberately skip Next/Play so the user's session is not altered.
        if (Test-SkiptifyStopRequested) {
            $restored = Wait-ForSpotifyFreeReady -TimeoutMs ([Math]::Min(10000, $RecoveryTimeoutMs)) -RequiredStableChecks 3 -IgnoreStop -MinimizeDuringWait:$(-not $overlayReady)
            if ($restored.Status -eq "Started") {
                $handoffProcess = $restored.Process
                if (-not $overlayReady) {
                    Minimize-SpotifyWindow -WindowHandle $restored.Process.MainWindowHandle
                }
            }
            return New-SkiptifyResult -Status "Stopped" -Reason "Spotify dipulihkan tanpa perintah playback." -Process $restored.Process
        }

        $recoveryTimer = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $remainingMs = $RecoveryTimeoutMs - [int]$recoveryTimer.ElapsedMilliseconds
            if ($remainingMs -le $PostReadyDelayMs) {
                return New-SkiptifyResult -Status "TimedOut" -Reason "Spotify did not remain ready within the recovery deadline."
            }
            $ready = Wait-ForSpotifyFreeReady -TimeoutMs ($remainingMs - $PostReadyDelayMs) -MinimizeDuringWait:$(-not $overlayReady)
            if ($ready.Status -eq "Stopped") {
                # Spotify has already been launched after the old process was
                # terminated. Complete a short, stop-ignoring readiness wait so
                # closing the UI never leaves Spotify half-started.
                $restoreTimeout = [Math]::Min(10000, [Math]::Max(1000, $remainingMs))
                $restored = Wait-ForSpotifyFreeReady -TimeoutMs $restoreTimeout -RequiredStableChecks 3 -IgnoreStop -MinimizeDuringWait:$(-not $overlayReady)
                if ($restored.Status -eq "Started") {
                    $handoffProcess = $restored.Process
                    if (-not $overlayReady) {
                        Minimize-SpotifyWindow -WindowHandle $restored.Process.MainWindowHandle
                    }
                }
                return New-SkiptifyResult -Status "Stopped" -Reason "Spotify dipulihkan tanpa perintah playback." -Process $restored.Process
            }
            if ($ready.Status -ne "Started") {
                return $ready
            }

            $processId = $ready.Process.Id
            $windowHandle = $ready.Process.MainWindowHandle
            $handoffProcess = $ready.Process
            if (-not $overlayReady) {
                Minimize-SpotifyWindow -WindowHandle $windowHandle
            }

            Start-Sleep -Milliseconds $PostReadyDelayMs

            $confirmedSpotify = Get-SpotifyWindowByIdentity -ProcessId $processId -WindowHandle $windowHandle -RequireFreeTitle
            if ($confirmedSpotify) {
                $handoffProcess = $confirmedSpotify
                break
            }

            Write-SkiptifyLog "Spotify changed during the post-ready delay; waiting again. Last seen: $(Get-SpotifyWindowDescription (Get-SpotifyWindowSnapshot))"
        }

        if (Test-SkiptifyStopRequested) {
            return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima sebelum perintah playback." -Process $confirmedSpotify
        }

        try {
            Send-SpotifyAppCommand -Command "Next" -WindowHandle $windowHandle
            Write-SkiptifyLog "Next command sent: $(Get-SpotifyWindowDescription $confirmedSpotify)"
        }
        catch {
            $reason = "Could not send Next: $($_.Exception.Message)"
            Write-SkiptifyLog "Recovery failed: $reason"
            return New-SkiptifyResult -Status "Failed" -Reason $reason -Process $confirmedSpotify
        }

        Start-Sleep -Milliseconds $PostNextDelayMs

        if (Test-SkiptifyStopRequested) {
            return New-SkiptifyResult -Status "Stopped" -Reason "Permintaan berhenti diterima sebelum Play." -Process $confirmedSpotify
        }

        $playTarget = Get-SpotifyWindowByIdentity -ProcessId $processId -WindowHandle $windowHandle
        if (-not $playTarget) {
            $reason = "Spotify was unavailable or unresponsive before Play. Last seen: $(Get-SpotifyWindowDescription (Get-SpotifyWindowSnapshot))"
            Write-SkiptifyLog "Recovery failed: $reason"
            return New-SkiptifyResult -Status "Failed" -Reason $reason
        }
        $handoffProcess = $playTarget

        try {
            Send-SpotifyAppCommand -Command "Play" -WindowHandle $windowHandle
            Write-SkiptifyLog "Play command sent: $(Get-SpotifyWindowDescription $playTarget)"
        }
        catch {
            $reason = "Could not send Play: $($_.Exception.Message)"
            Write-SkiptifyLog "Recovery failed: $reason"
            return New-SkiptifyResult -Status "Failed" -Reason $reason -Process $playTarget
        }

        return New-SkiptifyResult -Status "CommandsSent" -Reason "Next and Play commands were sent; playback was not verified." -Process $playTarget
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($overlayRecoveryId)) {
            $handoffMessage = if ($handoffProcess) { "Tampilan Spotify baru siap." } else { "Pemulihan selesai tanpa jendela pengganti." }
            Write-SkiptifyStatus -Status "OverlayRelease" -Message $handoffMessage -RecoveryId $overlayRecoveryId -Process $handoffProcess
            Write-SkiptifyLog "Overlay handoff completed for recovery $overlayRecoveryId."
        }
    }
}

function Test-SpotifyTrackTitle {
    param([AllowNull()][string]$Title)

    return (-not [string]::IsNullOrEmpty($Title)) -and $Title.Contains(" - ")
}

function Invoke-Skiptify {
    $badCount = 0
    Write-SkiptifyLog "Skiptify started."
    Write-SkiptifyStatus -Status "Memulai" -Message "Menyiapkan pemantauan Spotify."

    if (Test-SkiptifyStopRequested) {
        Write-SkiptifyStatus -Status "Off" -Message "Pemantauan tidak diaktifkan."
        return 0
    }

    # Background/helper processes alone do not mean the application is ready.
    $spotifyWindow = Get-SpotifyMainWindow
    if (-not $spotifyWindow) {
        $startup = Start-SpotifySmooth
        if ($startup.Status -ne "Started") {
            if ($startup.Status -eq "Stopped") {
                Write-SkiptifyStatus -Status "Off" -Message "Pemantauan tidak diaktifkan."
                return 0
            }
            Write-SkiptifyStatus -Status "Gagal" -Message $startup.Reason
            Write-SkiptifyLog "Skiptify stopped after startup failure: $($startup.Reason)"
            return 1
        }
    }

    Write-SkiptifyStatus -Status "Aktif" -Message "Pemantauan Spotify aktif."

    while ($true) {
        if (Test-SkiptifyStopRequested) {
            Write-SkiptifyStatus -Status "Menghentikan" -Message "Menghentikan pemantauan."
            break
        }

        if ($script:StartupGraceUntilUtc -gt [DateTime]::UtcNow) {
            $badCount = 0
            Start-Sleep -Milliseconds $CheckIntervalMs
            continue
        }

        $spotify = Get-SpotifyWindowSnapshot

        if ($spotify) {
            try {
                $title = $spotify.MainWindowTitle
                $isIgnored = $title -in $IgnoredTitles
                $isTrackTitle = Test-SpotifyTrackTitle -Title $title

                if ((-not [string]::IsNullOrEmpty($title)) -and (-not $isTrackTitle) -and (-not $isIgnored)) {
                    $badCount++

                    if ($badCount -ge $TriggerCount) {
                        Write-SkiptifyStatus -Status "Memulihkan" -Message "Memulihkan Spotify."
                        $recovery = Restart-SpotifySmooth
                        $badCount = 0

                        if ($recovery.Status -eq "Stopped") {
                            Write-SkiptifyStatus -Status "Menghentikan" -Message $recovery.Reason
                            break
                        }

                        if ($recovery.Status -ne "CommandsSent") {
                            Write-SkiptifyStatus -Status "Gagal" -Message $recovery.Reason
                            Write-SkiptifyLog "Skiptify stopped after recovery $($recovery.Status): $($recovery.Reason)"
                            return 1
                        }

                        Write-SkiptifyStatus -Status "Aktif" -Message "Pemantauan Spotify aktif."

                        Start-Sleep -Milliseconds 750
                    }
                }
                else {
                    $badCount = 0
                }
            }
            catch {
                $badCount = 0
            }
        }
        else {
            $badCount = 0
        }

        Start-Sleep -Milliseconds $CheckIntervalMs
    }

    Write-SkiptifyStatus -Status "Off" -Message "Pemantauan berhenti."
    return 0
}

if ($MyInvocation.InvocationName -ne ".") {
    if (Initialize-SkiptifyControl) {
        try {
            $exitCode = Invoke-Skiptify
        }
        finally {
            Dispose-SkiptifyControl
        }
        if ($exitCode -ne 0) {
            exit $exitCode
        }
    }
}
