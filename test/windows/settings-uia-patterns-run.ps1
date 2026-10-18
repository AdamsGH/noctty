<#
.SYNOPSIS
    SET91 hidden-desktop UIA regression runner (no build step).
.DESCRIPTION
    Requires PowerShell 7 and an already staged portable MEASUREMENT build, with
    its AUMID isolated and HKCU registration disabled outside the tracked tree.
    Pass its verified SHA-256. The runner checks the measurement AUMID literal,
    copies the stage into a NEW output directory, and owns only that copy.

    Every child has explicit lpDesktop and CREATE_NO_WINDOW. A kill-on-close job
    owns the worker tree; retained process handles bound each UIA client. No
    desktop switch, global input, Narrator, history contents or clipboard content.
    Real startup/history metadata+hashes and clipboard counter bracket the batch.

    Results: summary.json, cases.json, per-control probe JSON, guard snapshots,
    and task-only portable config. Failures preserve artifacts. No cleanup of
    shared shell state is attempted; guard changes fail the run for inspection.
    Real Narrator/NVDA and performance measurements remain separate obligations.
.EXAMPLE
    ./settings-uia-patterns-run.ps1 -PortableExe C:/task/stage/noctty.exe `
        -ExpectedExeSha256 <verified-sha256> -OutputDirectory C:/task/set91-run-01
.EXAMPLE
    ./settings-uia-patterns-run.ps1 -CompileOnly
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $PortableExe,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedExeSha256,
    [string] $OutputDirectory,
    [switch] $CompileOnly,
    [Parameter(DontShow)][string] $WorkerDesktop
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ('Set91.Native' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Set91
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, Width, Height, XChars, YChars, Fill, Flags;
            public short Show, ReservedBytes;
            public IntPtr ReservedPointer, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInfo { public IntPtr Process, Thread; public int Pid, Tid; }
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits
        {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr Minimum, Maximum;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong R1, R2, R3, B1, B2, B3; }
        [StructLayout(LayoutKind.Sequential)]
        struct JobLimits
        {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
        }
        public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
        [StructLayout(LayoutKind.Sequential)]
        struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode,
            uint flags, uint access, IntPtr security);
        [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
        [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool GetUserObjectInformationW(IntPtr obj, int index, StringBuilder text,
            uint bytes, out uint needed);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
        [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y,
            int width, int height, uint flags);
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [StructLayout(LayoutKind.Sequential)]
        struct LastInput { public uint Size, Tick; }
        [DllImport("user32.dll", SetLastError = true)] static extern bool GetLastInputInfo(ref LastInput input);
        [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        public sealed class InputState
        {
            public ulong TickCount;
            public uint LastInputTick, IdleMilliseconds;
        }
        public static InputState ReadInput()
        {
            var input = new LastInput { Size = (uint)Marshal.SizeOf(typeof(LastInput)) };
            if (!GetLastInputInfo(ref input)) throw new Win32Exception(Marshal.GetLastWin32Error());
            ulong now = GetTickCount64();
            return new InputState { TickCount = now, LastInputTick = input.Tick,
                IdleMilliseconds = unchecked((uint)now - input.Tick) };
        }
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr w, IntPtr l,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
        static extern IntPtr ReadControlText(IntPtr hwnd, uint message, IntPtr w, StringBuilder text,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processSecurity,
            IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string cwd,
            ref StartupInfo startup, out ProcessInfo process);
        [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint ms);
        [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObjectW(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int info, ref JobLimits limits, int bytes);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        static string ObjectName(IntPtr handle)
        {
            var text = new StringBuilder(256);
            uint needed;
            if (!GetUserObjectInformationW(handle, 2, text, 512, out needed))
                throw new InvalidOperationException("Desktop lookup failed");
            return text.ToString();
        }
        public static void AssertDesktop(IntPtr hwnd, string expected)
        {
            int pid;
            uint tid = hwnd == IntPtr.Zero ? GetCurrentThreadId() : GetWindowThreadProcessId(hwnd, out pid);
            if (tid == 0 || expected == "Default" || ObjectName(GetThreadDesktop(tid)) != expected)
                throw new InvalidOperationException("Private desktop mismatch");
        }
        static string ClassName(IntPtr hwnd)
        {
            var text = new StringBuilder(256);
            GetClassNameW(hwnd, text, 256);
            return text.ToString();
        }
        public static IntPtr Top(int pid, string className)
        {
            IntPtr result = IntPtr.Zero;
            EnumWindows((hwnd, data) => {
                int owner;
                GetWindowThreadProcessId(hwnd, out owner);
                if (owner == pid && ClassName(hwnd) == className && IsWindowVisible(hwnd)) result = hwnd;
                return true;
            }, IntPtr.Zero);
            return result;
        }
        public static IntPtr Child(IntPtr parent, int id, string className)
        {
            IntPtr result = IntPtr.Zero;
            EnumChildWindows(parent, (hwnd, data) => {
                if ((id < 0 || GetDlgCtrlID(hwnd) == id) &&
                    (String.IsNullOrEmpty(className) || ClassName(hwnd) == className)) result = hwnd;
                return true;
            }, IntPtr.Zero);
            return result;
        }
        public static long Send(IntPtr hwnd, uint message, long w, long l)
        {
            IntPtr result;
            if (hwnd == IntPtr.Zero || SendMessageTimeoutW(hwnd, message, (IntPtr)w, (IntPtr)l,
                2, 5000, out result) == IntPtr.Zero) throw new InvalidOperationException("Window message timed out");
            return result.ToInt64();
        }
        public static bool FullyClipped(IntPtr hwnd, IntPtr viewport)
        {
            Rect control, clip;
            if (!GetWindowRect(hwnd, out control) || !GetWindowRect(viewport, out clip))
                throw new InvalidOperationException("Control geometry unavailable");
            return control.Bottom <= clip.Top || control.Top >= clip.Bottom ||
                control.Right <= clip.Left || control.Left >= clip.Right;
        }
        public static bool IsCloseButton(IntPtr hwnd)
        {
            // Inspect only this fixture button's bounded caption, never a window title.
            var text = new StringBuilder(32);
            IntPtr result;
            return ReadControlText(hwnd, 0xD, (IntPtr)text.Capacity, text, 2, 2000, out result) != IntPtr.Zero &&
                text.ToString() == "Close";
        }
        public static string Quote(string value)
        {
            // Windows CommandLineToArgvW quoting, including a trailing backslash.
            var text = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { text.Append('\\', slashes * 2 + 1); text.Append(c); }
                else { text.Append('\\', slashes); text.Append(c); }
                slashes = 0;
            }
            text.Append('\\', slashes * 2);
            return text.Append('"').ToString();
        }
        public static IntPtr CreateJob()
        {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            var limits = new JobLimits();
            limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(typeof(JobLimits))))
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new Win32Exception(error);
            }
            return job;
        }
        public sealed class OwnedProcess : IDisposable
        {
            public IntPtr Handle;
            public int Pid;
            public uint ExitCode()
            {
                uint code;
                if (!GetExitCodeProcess(Handle, out code)) throw new InvalidOperationException("Process status failed");
                return code;
            }
            public void Dispose()
            {
                if (Handle == IntPtr.Zero) return;
                // This retained CreateProcess handle cannot be confused by PID reuse.
                if (WaitForSingleObject(Handle, 0) == 258)
                {
                    if (!TerminateProcess(Handle, 1) || WaitForSingleObject(Handle, 5000) != 0)
                        throw new InvalidOperationException("Owned process termination failed");
                }
                CloseHandle(Handle);
                Handle = IntPtr.Zero;
            }
        }
        public static OwnedProcess Launch(string exe, string[] args, string desktop, string cwd, IntPtr job)
        {
            if (String.IsNullOrEmpty(desktop) || desktop == "Default")
                throw new InvalidOperationException("Explicit private desktop required");
            var command = new StringBuilder(Quote(exe));
            foreach (string arg in args) command.Append(' ').Append(Quote(arg));
            var startup = new StartupInfo();
            startup.Size = Marshal.SizeOf(typeof(StartupInfo));
            startup.Desktop = "WinSta0\\" + desktop;
            // Windows are shown normally on the private desktop. SW_HIDE
            // would override the app's first ShowWindow and hide the fixture.
            startup.Flags = 0;
            ProcessInfo info;
            // Suspended until job assignment; every console helper uses CREATE_NO_WINDOW.
            if (!CreateProcessW(exe, command, IntPtr.Zero, IntPtr.Zero, false,
                0x08004004, IntPtr.Zero, cwd, ref startup, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var owned = new OwnedProcess { Handle = info.Process, Pid = info.Pid };
            try
            {
                if (job != IntPtr.Zero && !AssignProcessToJobObject(job, info.Process))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (ResumeThread(info.Thread) == UInt32.MaxValue)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return owned;
            }
            catch { owned.Dispose(); throw; }
            finally { CloseHandle(info.Thread); }
        }
    }
}
"@
}
$client = Join-Path $PSScriptRoot 'settings-uia-patterns.ps1'
if ($CompileOnly) {
    & $client -CompileOnly
    'SET91 runner and native UIA client: compile-only PASS; runtime NOT RUN'
    return
}
if (-not $PortableExe -or -not $OutputDirectory -or -not $ExpectedExeSha256) {
    throw 'PortableExe, ExpectedExeSha256 and a new OutputDirectory are required.'
}
function Write-Json([string] $Path, $Value) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Wait-For([scriptblock] $Read, [string] $Description, [int] $Seconds = 15) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Read
        $ready = if ($value -is [IntPtr]) { $value -ne [IntPtr]::Zero } else { [bool]$value }
        if ($ready) { return $value }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $end)
    throw "Timeout: $Description"
}
function Ctl([IntPtr] $Parent, [int] $Id) {
    $hwnd = [Set91.Native]::Child($Parent, $Id, '')
    Assert-Contract ($hwnd -ne [IntPtr]::Zero) "Missing fixture control $Id"
    [Set91.Native]::AssertDesktop($hwnd, $WorkerDesktop)
    return $hwnd
}
function Click([IntPtr] $Hwnd) { [void][Set91.Native]::Send($Hwnd, 0xF5, 0, 0) }
function Get-GuardSnapshot {
    # Hash bytes without reading or printing history contents. Labels replace paths.
    $roam = [Environment]::GetFolderPath('ApplicationData')
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $paths = [ordered]@{
        startup = Join-Path $local 'noctty/startup-attempts.json'
        psreadline = Join-Path $roam 'Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt'
        documentsHistory = Join-Path $docs 'PowerShell/PSReadLine/ConsoleHost_history.txt'
    }
    $files = foreach ($label in $paths.Keys) {
        $item = Get-Item -LiteralPath $paths[$label] -ErrorAction SilentlyContinue
        if ($item) {
            [ordered]@{ label = $label; exists = $true; bytes = $item.Length
                mtime = $item.LastWriteTimeUtc.Ticks; sha256 = (Get-FileHash -LiteralPath $item.FullName).Hash }
        } else { [ordered]@{ label = $label; exists = $false } }
    }
    $destinations = @(Get-ChildItem -LiteralPath (Join-Path $roam 'Microsoft/Windows/Recent/CustomDestinations') `
        -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            [ordered]@{ name = $_.Name; bytes = $_.Length; mtime = $_.LastWriteTimeUtc.Ticks
                sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash }
        })
    return [ordered]@{ clipboard = [Set91.Native]::GetClipboardSequenceNumber(); input = [Set91.Native]::ReadInput(); files = @($files)
        destinations = $destinations }
}

if (-not $WorkerDesktop) {
    $PortableExe = (Resolve-Path -LiteralPath $PortableExe).Path
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    Assert-Contract (-not (Test-Path -LiteralPath $OutputDirectory)) 'OutputDirectory must not already exist.'
    Assert-Contract (-not $PortableExe.Contains('\zig-out\')) 'Use an already staged portable copy, never zig-out.'
    Assert-Contract ((Get-FileHash -LiteralPath $PortableExe).Hash -eq $ExpectedExeSha256) 'Measurement exe SHA-256 mismatch.'
    $stage = Split-Path -Parent $PortableExe
    Assert-Contract (Test-Path -LiteralPath (Join-Path $stage 'noctty.portable') -PathType Leaf) 'Portable marker missing.'
    foreach ($name in 'conpty.dll', 'OpenConsole.exe') {
        Assert-Contract (Test-Path -LiteralPath (Join-Path $stage $name) -PathType Leaf) "Stage is missing $name"
    }
    # A build identity check, not a substitute for the caller's measurement-patch verification.
    $binary = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($PortableExe))
    Assert-Contract ($binary.Contains("io.github.amanthanvi.noctty.measure`0")) 'Measurement AUMID literal missing.'
    Assert-Contract (-not $binary.Contains("io.github.amanthanvi.noctty`0")) `
        'Product AUMID literal remains (check the measurement toast AUMID as well).'
    $binary = $null
    Assert-Contract (-not $OutputDirectory.StartsWith($stage.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) `
        'OutputDirectory must be outside the source stage.'
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
    $before = Get-GuardSnapshot
    Write-Json (Join-Path $OutputDirectory 'guard-before.json') $before
    $savedLocal = $env:LOCALAPPDATA
    $savedRoam = $env:APPDATA
    $desktopHandle = [IntPtr]::Zero
    $job = [IntPtr]::Zero
    $worker = $null
    $failure = $null
    $workerCode = $null
    try {
        $copy = Join-Path $OutputDirectory 'portable'
        [void](New-Item -ItemType Directory -Path $copy)
        # Copy only a staged package; reject reparse points instead of following external data.
        Assert-Contract (@(Get-ChildItem -LiteralPath $stage -Recurse -Force | Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }).Count -eq 0) 'Source stage contains a reparse point.'
        Get-ChildItem -LiteralPath $stage -Force | Copy-Item -Destination $copy -Recurse
        $exe = Join-Path $copy (Split-Path -Leaf $PortableExe)
        Assert-Contract ((Get-FileHash -LiteralPath $exe).Hash -eq $ExpectedExeSha256) 'Copied exe hash mismatch.'
        $env:LOCALAPPDATA = Join-Path $OutputDirectory 'local'
        $env:APPDATA = Join-Path $OutputDirectory 'roam'
        [void](New-Item -ItemType Directory -Path $env:LOCALAPPDATA, $env:APPDATA)
        $desktopName = 'set91-' + [guid]::NewGuid().ToString('N')
        $desktopHandle = [Set91.Native]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
        Assert-Contract ($desktopHandle -ne [IntPtr]::Zero) 'CreateDesktop failed.'
        $job = [Set91.Native]::CreateJob()
        $workerArgs = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
            '-PortableExe', $exe, '-ExpectedExeSha256', $ExpectedExeSha256,
            '-OutputDirectory', $OutputDirectory, '-WorkerDesktop', $desktopName)
        $worker = [Set91.Native]::Launch((Join-Path $PSHOME 'pwsh.exe'), $workerArgs, $desktopName, $OutputDirectory, $job)
        Assert-Contract ([Set91.Native]::WaitForSingleObject($worker.Handle, 1200000) -eq 0) 'SET91 batch timed out.'
        $workerCode = $worker.ExitCode()
    }
    catch { $failure = $_.Exception.Message }
    finally {
        # Kill the owned worker tree before taking the final real-profile snapshot.
        if ($job -ne [IntPtr]::Zero) { [void][Set91.Native]::CloseHandle($job) }
        if ($worker) { $worker.Dispose() }
        if ($desktopHandle -ne [IntPtr]::Zero) { [void][Set91.Native]::CloseDesktop($desktopHandle) }
        $env:LOCALAPPDATA = $savedLocal
        $env:APPDATA = $savedRoam
        $after = Get-GuardSnapshot
        Write-Json (Join-Path $OutputDirectory 'guard-after.json') $after
        # Other apps may refresh existing jump lists while the maintainer uses
        # this shared host. Portable builds must create no destination, and the
        # real noctty destination must stay unchanged (lead's D12/#417 contract).
        $beforeNames = @($before.destinations | ForEach-Object { $_.name })
        $newDestinations = @($after.destinations | Where-Object { $_.name -notin $beforeNames })
        $realBefore = @($before.destinations | Where-Object name -eq 'c2214d6ebc43ff3f.customDestinations-ms')
        $realAfter = @($after.destinations | Where-Object name -eq 'c2214d6ebc43ff3f.customDestinations-ms')
        $inputDuringBatch = [uint64]$after.input.IdleMilliseconds -le ([uint64]$after.input.TickCount - [uint64]$before.input.TickCount)
        $clipboardChanged = $before.clipboard -ne $after.clipboard
        $clipboardPass = -not $clipboardChanged -or $inputDuringBatch
        $guardPass = $clipboardPass -and $newDestinations.Count -eq 0 -and
            ($before.files | ConvertTo-Json -Depth 8 -Compress) -ceq ($after.files | ConvertTo-Json -Depth 8 -Compress) -and
            ($realBefore | ConvertTo-Json -Depth 8 -Compress) -ceq ($realAfter | ConvertTo-Json -Depth 8 -Compress)
        Write-Json (Join-Path $OutputDirectory 'summary.json') ([ordered]@{
            pass = ($null -eq $failure -and $workerCode -eq 0 -and $guardPass)
            workerExit = $workerCode; guardPass = $guardPass; error = $failure
            clipboardBefore = $before.clipboard; clipboardAfter = $after.clipboard
            inputBefore = $before.input; inputAfter = $after.input; inputDuringBatch = $inputDuringBatch
            clipboardAttribution = $(if (!$clipboardChanged) { 'unchanged' } elseif ($inputDuringBatch) { 'unattributed maintainer activity' } else { 'changed during a batch with no input' })
            executableSha256 = $ExpectedExeSha256
            newDestinations = $newDestinations
        })
    }
    Assert-Contract $guardPass 'Real startup/history, shell destination metadata or clipboard sequence changed; stop launches and inspect guard artifacts.'
    Assert-Contract ($null -eq $failure) "Runner failed: $failure"
    Assert-Contract ($workerCode -eq 0) 'SET91 regression failed; inspect cases.json, per-control JSON and clipboard-activity.jsonl.'
    'SET91 regression PASS (18 controls, 30 operation cases; guard metadata unchanged)'
    return
}

# Worker mode is reached only by explicit private-desktop CreateProcess above.
[Set91.Native]::AssertDesktop([IntPtr]::Zero, $WorkerDesktop)
[void][Set91.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
Assert-Contract ((Get-FileHash -LiteralPath $PortableExe).Hash -eq $ExpectedExeSha256) 'Worker exe identity mismatch.'
Assert-Contract ($env:LOCALAPPDATA -eq (Join-Path $OutputDirectory 'local')) 'Worker LOCALAPPDATA mismatch.'
Assert-Contract ($env:APPDATA -eq (Join-Path $OutputDirectory 'roam')) 'Worker APPDATA mismatch.'
$fixture = Split-Path -Parent $PortableExe
$config = Join-Path $fixture 'config.ghostty'
$clip = [Set91.Native]::GetClipboardSequenceNumber()
$batchInput = [Set91.Native]::ReadInput()
$clipObserved = $clip
function Assert-ClipboardGuard {
    $sequence = [Set91.Native]::GetClipboardSequenceNumber()
    if ($sequence -eq $clip) { return }
    $inputNow = [Set91.Native]::ReadInput()
    $active = [uint64]$inputNow.IdleMilliseconds -le ([uint64]$inputNow.TickCount - [uint64]$batchInput.TickCount)
    if ($sequence -ne $script:clipObserved) {
        [ordered]@{ utc = [DateTimeOffset]::UtcNow.ToString('o'); before = $script:clipObserved; after = $sequence
            inputBefore = $batchInput; inputNow = $inputNow
            attribution = $(if ($active) { 'unattributed maintainer activity' } else { 'changed during a batch with no input' }) } |
            ConvertTo-Json -Depth 5 -Compress | Add-Content (Join-Path $OutputDirectory 'clipboard-activity.jsonl')
        $script:clipObserved = $sequence
    }
    Assert-Contract $active 'Clipboard changed during a batch with no input; stop launches and report.'
}
$process = $null
$settings = [IntPtr]::Zero
$hostWindow = [IntPtr]::Zero
$cleanupFailed = $false
$clippedChecks = 0
$results = [Collections.Generic.List[object]]::new()
$cases = @(
    @(201, 405, 'ComboBox', 'Window theme', 'window-theme'),
    @(201, 409, 'ComboBox', 'Cursor style', 'cursor-style'),
    @(201, 411, 'ComboBox', 'Window padding balance', 'window-padding-balance'),
    @(201, 426, 'CheckBox', 'Follow Windows accent color', 'accent-follow-system'),
    @(201, 410, 'CheckBox', 'Background blur (not supported on Windows)', 'background-blur'),
    @(202, 403, 'ComboBox', 'Close confirmation', 'confirm-close-surface'),
    @(202, 404, 'ComboBox', 'Copy on select', 'copy-on-select'),
    @(202, 407, 'CheckBox', 'Clipboard trimming', 'clipboard-trim-trailing-spaces'),
    @(203, 406, 'ComboBox', 'Shell integration', 'shell-integration'),
    @(206, 422, 'ComboBox', 'OSC 52 clipboard read requests', 'clipboard-read'),
    @(206, 423, 'ComboBox', 'OSC 52 clipboard write requests', 'clipboard-write'),
    @(206, 424, 'ComboBox', 'Clickable URL opening', 'link-url'),
    @(206, 425, 'ComboBox', 'Link preview popups (not supported on Windows)', 'link-previews'),
    @(206, 417, 'CheckBox', 'Terminal notifications', 'desktop-notifications'),
    @(206, 418, 'CheckBox', 'Clipboard-copy notification', 'app-notifications'),
    @(206, 419, 'CheckBox', 'Config-reload notification', 'app-notifications'),
    @(207, 420, 'ComboBox', 'Auto-update mode', 'auto-update'),
    @(207, 421, 'ComboBox', 'Auto-update channel', 'auto-update-channel')
)
function Start-Fixture {
    Assert-ClipboardGuard
    $class = 'noctty-test-set91-' + [guid]::NewGuid().ToString('N')
    $script:process = [Set91.Native]::Launch($PortableExe, @('--single-instance=false', "--class=$class"),
        $WorkerDesktop, $fixture, [IntPtr]::Zero)
    $script:hostWindow = Wait-For { [Set91.Native]::Top($process.Pid, 'noctty.win32.host') } 'host window' 30
    [Set91.Native]::AssertDesktop($hostWindow, $WorkerDesktop)
    $surface = Wait-For { [Set91.Native]::Child($hostWindow, -1, 'noctty.win32') } 'terminal surface'
    [Set91.Native]::AssertDesktop($surface, $WorkerDesktop)
    # Posted F9 only, never global input or text in a shell. Repost while startup settles.
    $script:settings = Wait-For {
        [void][Set91.Native]::PostMessageW($surface, 0x100, [IntPtr]0x78, [IntPtr]0x00430001)
        [void][Set91.Native]::PostMessageW($surface, 0x101, [IntPtr]0x78, [IntPtr]0xC0430001)
        [Set91.Native]::Top($process.Pid, 'noctty.win32.settings')
    } 'Settings window'
    [Set91.Native]::AssertDesktop($settings, $WorkerDesktop)
    Assert-Contract ([Set91.Native]::SetWindowPos($settings, [IntPtr]::Zero, 0, 0, 1200, 800, 0x16)) `
        'Could not size Settings for viewport regression coverage.'
    Start-Sleep -Milliseconds 300
}
function Stop-Fixture {
    if (-not $script:process) { return }
    try {
        if ([Set91.Native]::IsWindow($settings)) {
            [void][Set91.Native]::Send($settings, 0x10, 0, 0)
            $discard = [Set91.Native]::Child($settings, 306, '')
            if ($discard -ne [IntPtr]::Zero -and [Set91.Native]::IsWindowVisible($discard)) { Click $discard }
        }
        if ([Set91.Native]::IsWindow($hostWindow)) {
            [void][Set91.Native]::PostMessageW($hostWindow, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
            [void](Wait-For {
                [Set91.Native]::WaitForSingleObject($process.Handle, 0) -eq 0 -or
                    [Set91.Native]::Child($hostWindow, 2003, '') -ne [IntPtr]::Zero
            } 'fixture close or confirmation')
            # The Close confirmation case can have saved true/always. Accept only
            # this exact Close button after our WM_CLOSE, never another prompt.
            $accept = [Set91.Native]::Child($hostWindow, 2003, '')
            if ($accept -ne [IntPtr]::Zero -and [Set91.Native]::IsWindowVisible($accept) -and
                [Set91.Native]::IsCloseButton($accept)) {
                [Set91.Native]::AssertDesktop($accept, $WorkerDesktop)
                Click $accept
            }
        }
        if ([Set91.Native]::WaitForSingleObject($process.Handle, 5000) -ne 0) {
            $script:cleanupFailed = $true
            throw 'Fixture required forced termination; stop launches to avoid recovery-state contamination.'
        }
    }
    finally { $script:process.Dispose(); $script:process = $null }
}
function Select-Case($Case, [string] $Phase) {
    Click (Ctl $settings $Case[0])
    $hwnd = Ctl $settings $Case[1]
    # Focus scrolling is intentionally avoided; scroll the viewport with posted messages.
    $viewport = [Set91.Native]::Child($settings, -1, 'noctty.win32.settings.viewport')
    Assert-Contract ($viewport -ne [IntPtr]::Zero) 'Missing Settings viewport.'
    if ($viewport -ne [IntPtr]::Zero) {
        [Set91.Native]::AssertDesktop($viewport, $WorkerDesktop)
        [void][Set91.Native]::Send($viewport, 0x115, 6, 0)
        if ([Set91.Native]::FullyClipped($hwnd, $viewport)) {
            $clipped = Probe-Control $Case $hwnd "$Phase-clipped" $false
            Assert-Contract ([bool]$clipped.offscreen) 'Fully clipped field incorrectly reports UIA IsOffscreen=false.'
            $script:clippedChecks++
        }
        for ($step = 0; $step -lt 100 -and [Set91.Native]::FullyClipped($hwnd, $viewport); $step++) {
            [void][Set91.Native]::Send($viewport, 0x115, 1, 0)
        }
        Assert-Contract (-not [Set91.Native]::FullyClipped($hwnd, $viewport)) 'Could not scroll field into viewport.'
    }
    return $hwnd
}
function Probe-Control($Case, [IntPtr] $Hwnd, [string] $Phase, [bool] $ExerciseControl) {
    $path = Join-Path $OutputDirectory "control-$($Case[1])-$Phase.json"
    $clientArgs = @('-NoProfile', '-NonInteractive', '-File', $client, '-Hwnd', $Hwnd.ToInt64().ToString(),
        '-Desktop', $WorkerDesktop, '-Kind', $Case[2], '-ExpectedName', $Case[3], '-OutputPath', $path)
    if ($ExerciseControl) { $clientArgs += '-Exercise' }
    if ($Phase.EndsWith('-selection')) { $clientArgs += '-UseSelectionItem' }
    $probe = [Set91.Native]::Launch((Join-Path $PSHOME 'pwsh.exe'), $clientArgs, $WorkerDesktop, $OutputDirectory, [IntPtr]::Zero)
    try {
        Assert-Contract ([Set91.Native]::WaitForSingleObject($probe.Handle, 45000) -eq 0) 'UIA client timed out.'
        Assert-Contract (Test-Path -LiteralPath $path) 'UIA client produced no result.'
        $observed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-Contract (($probe.ExitCode() -eq 0) -eq [bool]$observed.pass) 'Client exit/result mismatch.'
        return $observed
    }
    finally { $probe.Dispose() }
}
try {
    foreach ($selectionMode in @($false, $true)) {
    foreach ($case in $cases) {
        if ($selectionMode -and $case[2] -ne 'ComboBox') { continue }
        $phase = if ($selectionMode) { 'selection' } else { 'value' }
        $record = [ordered]@{ id = $case[1]; kind = $case[2]; mode = $phase; pass = $false }
        try {
            # No PowerShell shell/profile or history. The process receives no typed commands.
            # Start the config-reload checkbox ON so its tested toggle turns notifications OFF
            # before Save; Settings save otherwise invokes a system toast even on a hidden desktop.
            $notifications = if ($case[1] -eq 419) { 'no-clipboard-copy,config-reload' } else { 'no-clipboard-copy,no-config-reload' }
            $seed = @('# SET91 unrelated sentinel must survive byte-for-byte', 'font-size = 12',
                'command = cmd.exe /d /q', 'renderer = d3d11', 'window-save-state = never',
                'confirm-close-surface = false', 'auto-update = off', 'auto-update-channel = tip',
                'desktop-notifications = false', "app-notifications = $notifications",
                'copy-on-select = false', 'clipboard-read = deny', 'clipboard-write = deny',
                'windows-job-object-kill-on-close = true', 'keybind = f9=open_config') -join "`n"
            [IO.File]::WriteAllText($config, $seed + "`n", [Text.UTF8Encoding]::new($false))
            Start-Fixture
            $hwnd = Select-Case $case "exercise-$phase"
            $save = Ctl $settings 301
            Assert-Contract (-not [Set91.Native]::IsWindowEnabled($save)) 'Fixture is already dirty.'
            $beforeHash = (Get-FileHash -LiteralPath $config).Hash
            $observed = Probe-Control $case $hwnd "exercise-$phase" $true
            $record.probe = $observed
            Assert-Contract $observed.pass 'UIA pattern/operation/name contract failed.'
            Assert-Contract (-not $observed.offscreen) 'Visible exercised field incorrectly reports UIA IsOffscreen=true.'
            $disabled = $case[1] -in 410, 425
            Assert-Contract ([bool]$observed.enabled -eq (-not $disabled)) 'Unexpected enabled state.'
            Assert-Contract ((Get-FileHash -LiteralPath $config).Hash -eq $beforeHash) 'UIA operation wrote config before Save.'
            if ($disabled) {
                Assert-Contract $observed.disabledRejected 'Unsupported field operation was not rejected.'
                Assert-Contract (-not [Set91.Native]::IsWindowEnabled($save)) 'Disabled operation dirtied pending config.'
                $record.disabledRejected = $true
            }
            else {
                Assert-Contract ([Set91.Native]::IsWindowEnabled($save)) 'UIA changed native state without pending config.'
                [void][Set91.Native]::Send($settings, 0x10, 0, 0)
                $keep = Ctl $settings 2
                Assert-Contract ([Set91.Native]::IsWindowVisible($keep)) 'Pending config did not produce dirty-close confirmation.'
                $record.pendingDirty = $true
                Click $keep
                Click $save
                [void](Wait-For { -not [Set91.Native]::IsWindowEnabled($save) } 'Save to commit pending config')
                $saved = [IO.File]::ReadAllText($config)
                Assert-Contract ($saved.Contains("# SET91 unrelated sentinel must survive byte-for-byte`nfont-size = 12`n")) 'Save damaged unrelated sentinel.'
                Assert-Contract ((Get-FileHash -LiteralPath $config).Hash -ne $beforeHash) 'Save did not change the portable config.'
                Assert-Contract ($saved -match ('(?m)^' + [regex]::Escape($case[4]) + '\s*=')) 'Save did not write the exercised config key.'
                $record.savedSha256 = (Get-FileHash -LiteralPath $config).Hash
                # A fresh app loads disk; reopening in the same app would only prove its cache.
                Stop-Fixture
                Start-Fixture
                $reopened = Probe-Control $case (Select-Case $case "reload-$phase") "reload-$phase" $false
                $record.reload = $reopened
                Assert-Contract ($reopened.pass -and $reopened.before -ceq $observed.after) 'Saved UIA state did not roundtrip through a fresh process.'
                $record.saveRoundtrip = $true
            }
            $record.pass = $true
        }
        catch { $record.error = $_.Exception.Message }
        finally {
            try { Stop-Fixture } catch { $record.pass = $false; $record.cleanupError = $_.Exception.Message }
            $results.Add($record)
            Write-Json (Join-Path $OutputDirectory 'cases.json') @($results.ToArray())
        }
        Assert-ClipboardGuard
        Assert-Contract (-not $cleanupFailed) 'Cleanup failed; stop batch and inspect the retained fixture.'
    }
    }
}
finally {
    try { Stop-Fixture }
    finally {
        Write-Json (Join-Path $OutputDirectory 'coverage.json') ([ordered]@{
            expectedControls = $cases.Count; expectedCases = $cases.Count + 12
            completedControls = @($results.id | Sort-Object -Unique).Count
            completedCases = $results.Count; passedCases = @($results | Where-Object { $_.pass }).Count
            clippedFieldChecks = $clippedChecks
        })
    }
}
Assert-Contract (@($results | Where-Object { -not $_.pass }).Count -eq 0) 'One or more SET91 cases failed.'
Assert-Contract ($clippedChecks -gt 0) 'No fully clipped field was observed; clipping coverage is missing.'
