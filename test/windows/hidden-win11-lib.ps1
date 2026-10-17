# Shared by the hidden-desktop harnesses that start portable copies of noctty
# (hidden-win11-profile-matrix.ps1, hidden-win11-embedding-idle.ps1). Dot-source it.
#
# Safety rules these harnesses keep (AGENTS.md, test/windows/README.md):
#   * Every process runs on a desktop this run creates; lpDesktop is explicit
#     for every CreateProcess, because a child of a driver on a private desktop
#     does not inherit it.
#   * Every noctty is a copy with a `noctty.portable` marker, with LOCALAPPDATA
#     and APPDATA redirected into the run directory.
#   * The real startup-attempts.json and the real PSReadLine history file are
#     checked by size, time and hash before and after, never read.
#   * The clipboard sequence number is logged before and after. Nothing here
#     can copy (no selection, no copy key, no OSC 52 answer).
#   * A noctty with the product AppUserModelID would replace the real taskbar
#     jump list, so the binary must carry the measurement AUMID unless
#     -AllowProductAumid says the machine is an ephemeral runner.

if (-not ('HiddenWin' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class HiddenWin {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeoutMs, out IntPtr result);
    public static bool Send(IntPtr h, uint m, long w, long l) {
        IntPtr result;
        return SendMessageTimeoutW(h, m, new IntPtr(w), new IntPtr(l), 2, 5000, out result) != IntPtr.Zero;
    }
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n, IntPtr dev, IntPtr mode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int type, ref JobLimits limits, uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr job, int type, out JobAccounting accounting, uint size, IntPtr returned);
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime, kernelTime, periodUserTime, periodKernelTime;
        public uint pageFaults, totalProcesses, activeProcesses, terminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime, jobTime; public uint flags;
        public UIntPtr minWorking, maxWorking; public uint activeProcesses;
        public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits basic; public IoCounters io;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    public static IntPtr CreateOwnedJob() {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var limits = new JobLimits(); limits.basic.flags = 0x2000; // KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>())) {
            CloseHandle(job); throw new Exception("SetInformationJobObject failed");
        }
        return job;
    }
    public static uint StopOwnedJob(IntPtr job) {
        try {
            if (!TerminateJobObject(job, 1)) throw new Exception("Terminate owned job failed");
            var deadline = DateTime.UtcNow.AddSeconds(5);
            do {
                JobAccounting accounting;
                if (!QueryInformationJobObject(job, 1, out accounting, (uint)Marshal.SizeOf<JobAccounting>(), IntPtr.Zero))
                    throw new Exception("Query owned job failed");
                if (accounting.activeProcesses == 0) return accounting.totalProcesses;
                System.Threading.Thread.Sleep(10);
            } while (DateTime.UtcNow < deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(job); }
    }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public bool inherit; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name, uint access, uint share, ref SecurityAttributes sa, uint disposition, uint flags, IntPtr template);
    // Starts a process suspended on an explicit desktop, assigns it to the owned job and resumes it.
    // stderrPath, when not empty, is created and becomes the child's standard error (its other
    // standard handles are null). PowerShell hands a $null string to .NET as "".
    public static ProcessInfo Launch(string app, string command, string cwd, string desktop, IntPtr job, string stderrPath) {
        // No STARTF_USESHOWWINDOW: a window hidden by the launcher takes no posted input, and this
        // desktop is never displayed anyway.
        var si = new Startup { cb = Marshal.SizeOf<Startup>(), desktop = desktop }; ProcessInfo pi;
        IntPtr err = IntPtr.Zero; bool inherit = false;
        if (!string.IsNullOrEmpty(stderrPath)) {
            var sa = new SecurityAttributes { length = Marshal.SizeOf<SecurityAttributes>(), inherit = true };
            err = CreateFileW(stderrPath, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero);
            if (err == new IntPtr(-1)) throw new Exception("Creating the stderr file failed: " + Marshal.GetLastWin32Error());
            si.flags |= 0x100; si.error = err; inherit = true;
        }
        bool created;
        try { created = CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, inherit, 0x08004004, IntPtr.Zero, cwd, ref si, out pi); }
        finally { if (err != IntPtr.Zero) CloseHandle(err); }
        if (!created) throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, pi.process) || ResumeThread(pi.thread) == 0xFFFFFFFF) {
            TerminateProcess(pi.process, 1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume owned process failed");
        }
        return pi;
    }
    static string Class(IntPtr h) { var s = new StringBuilder(128); GetClassNameW(h, s, 128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list = new List<IntPtr>(); EnumWindows((h, p) => { int id; GetWindowThreadProcessId(h, out id);
            if (id == pid && Class(h) == "noctty.win32.host") list.Add(h); return true;
        }, IntPtr.Zero); return list.ToArray();
    }
    // Every top-level window the process owns, whatever its class.
    public static string[] TopLevelClasses(int pid) {
        var list = new List<string>(); EnumWindows((h, p) => { int id; GetWindowThreadProcessId(h, out id);
            if (id == pid) list.Add(Class(h)); return true;
        }, IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr[] Surfaces(IntPtr host) {
        var list = new List<IntPtr>();
        EnumChildWindows(host, (c, p) => { if (Class(c) == "noctty.win32" && IsWindowVisible(c)) list.Add(c); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed);
    public static string CurrentDesktopName() {
        var name = new StringBuilder(256); int needed;
        if (!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), 2, name, 512, out needed)) return "";
        return name.ToString();
    }
    public static bool ContainsBytes(byte[] hay, byte[] needle) {
        int last = hay.Length - needle.Length;
        for (int i = 0; i <= last; i++) {
            if (hay[i] != needle[0]) continue;
            int j = 1; while (j < needle.Length && hay[i + j] == needle[j]) j++;
            if (j == needle.Length) return true;
        }
        return false;
    }
}
'@
}

function Get-FileFingerprint([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Exists = $false } }
    $item = Get-Item -LiteralPath $Path
    return @{ Exists = $true; Length = $item.Length; Modified = $item.LastWriteTimeUtc.ToString('o'); Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Test-SameFingerprint($A, $B) {
    return $A.Exists -eq $B.Exists -and $A.Hash -eq $B.Hash -and $A.Modified -eq $B.Modified
}

# The state a run must not touch on the machine it runs on: the real recovery ledger and the
# real PowerShell history file (a pwsh in a test pane loads PSReadLine). Metadata and a hash
# only; their contents are never read into the output.
function Get-RealStateFingerprints {
    $history = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    return @{
        Startup = Get-FileFingerprint (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json')
        History = Get-FileFingerprint $history
    }
}

# A copy of the product AUMID would replace the real jump list for every launch; the measurement
# build carries ".measure" after it (apply_aumid_isolate.py, never committed).
function Assert-MeasureAumid([string] $Exe, [switch] $AllowProductAumid) {
    if ($AllowProductAumid) { return }
    $needle = [Text.Encoding]::Unicode.GetBytes('io.github.amanthanvi.noctty.measure')
    if (-not [HiddenWin]::ContainsBytes([IO.File]::ReadAllBytes($Exe), $needle)) {
        throw 'noctty.exe does not carry the measurement AppUserModelID (io.github.amanthanvi.noctty.measure). A launch would replace the real taskbar jump list. Build with scripts that apply the measurement patch, or pass -AllowProductAumid on an ephemeral machine.'
    }
}

function Copy-PortableBin([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}

# Runs `-Script` again as a driver on a desktop created here, in an owned kill-on-close job, with
# LOCALAPPDATA and APPDATA redirected into `-Run`, then checks that nothing real changed.
function Invoke-HiddenDriver {
    param(
        [Parameter(Mandatory)] [string] $Script, [Parameter(Mandatory)] [string] $Bin, [Parameter(Mandatory)] [string] $Run,
        [Parameter(Mandatory)] [int] $TimeoutSeconds, [string[]] $ExtraArguments = @(), [Parameter(Mandatory)] [string] $Label
    )
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain noctty.exe.' }
    $before = Get-RealStateFingerprints
    $clipboardBefore = [HiddenWin]::GetClipboardSequenceNumber()
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-PortableBin $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata', 'appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-hw-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenWin]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal = $env:LOCALAPPDATA; $oldRoaming = $env:APPDATA
    $pi = $null; $job = [IntPtr]::Zero; $code = 1
    try {
        $job = [HiddenWin]::CreateOwnedJob()
        $env:LOCALAPPDATA = Join-Path $Run 'localappdata'; $env:APPDATA = Join-Path $Run 'appdata'
        $pwsh = (Get-Command pwsh.exe).Source
        $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver' -f $pwsh, $Script, (Join-Path $Run 'source\bin'), $Run
        foreach ($argument in $ExtraArguments) { $line += ' ' + $argument }
        # CREATE_NO_WINDOW (0x08000000) is part of Launch's flags.
        $pi = [HiddenWin]::Launch($pwsh, $line, $Run, "WinSta0\$desktopName", $job, '')
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([HiddenWin]::WaitForSingleObject($pi.process, 1000) -eq 258) {
            if ([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $TimeoutSeconds seconds; the owned process job will be closed." }
        }
        [uint32]$exit = 0; [void][HiddenWin]::GetExitCodeProcess($pi.process, [ref]$exit); $code = [int]$exit
    } finally {
        $env:LOCALAPPDATA = $oldLocal; $env:APPDATA = $oldRoaming
        $cleanupError = $null; $ownedProcessCount = 0
        if ($job -ne [IntPtr]::Zero) { try { $ownedProcessCount = [HiddenWin]::StopOwnedJob($job) } catch { $cleanupError = $_ } }
        if ($pi) { [void][HiddenWin]::CloseHandle($pi.thread); [void][HiddenWin]::CloseHandle($pi.process) }
        [void][HiddenWin]::CloseDesktop($desktop)
        $after = Get-RealStateFingerprints
        $clipboardAfter = [HiddenWin]::GetClipboardSequenceNumber()
        $startupUnchanged = Test-SameFingerprint $before.Startup $after.Startup
        $historyUnchanged = Test-SameFingerprint $before.History $after.History
        @{ Before = $before; After = $after; StartupUnchanged = $startupUnchanged; HistoryUnchanged = $historyUnchanged; OwnedJobCleanedUp = ($null -eq $cleanupError); OwnedProcessCount = $ownedProcessCount; ClipboardSequenceBefore = $clipboardBefore; ClipboardSequenceAfter = $clipboardAfter } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Run 'real-state.json')
        if (-not $startupUnchanged) { throw 'Real startup-attempts.json changed; stop launches and report it.' }
        if (-not $historyUnchanged) { throw 'The real PowerShell history file changed; stop launches and report it.' }
        if ($clipboardBefore -ne $clipboardAfter) { throw "Clipboard sequence number changed ($clipboardBefore -> $clipboardAfter); stop launches and report it." }
        if ($cleanupError) { throw $cleanupError }
    }
    # The driver has no console of its own: print what it recorded.
    foreach ($results in @(Get-ChildItem -LiteralPath $Run -Filter '*-results.json' -File)) {
        $document = Get-Content -LiteralPath $results.FullName -Raw | ConvertFrom-Json
        $total = @($document.Checks).Count
        foreach ($check in @($document.Checks | Where-Object { -not $_.Passed })) {
            Write-Host ("FAIL {0}{1}: expected {2}, got {3}" -f $(if ($check.Case) { "[$($check.Case)] " } else { '' }), $check.Name, $check.Expected, $check.Actual)
        }
        foreach ($case in @($document.Cases | Where-Object { $_.Result -eq 'skipped' })) { Write-Host ("SKIP [{0}] {1}" -f $case.Profile, $case.Reason) }
        Write-Host ("{0}: {1} checks" -f $results.Name, $total)
    }
    if ($code -ne 0) { throw "Hidden driver failed with exit $code; inspect the results in $Run." }
    Write-Host "${Label}: PASS"
}

# Starts a portable noctty on the driver's desktop. The returned object owns the process.
function Start-HiddenNoctty {
    param([Parameter(Mandatory)] [string] $Dir, [Parameter(Mandatory)] [string[]] $Arguments, [Parameter(Mandatory)] [string] $DesktopName, [Parameter(Mandatory)] [IntPtr] $Job, [string] $StderrPath)
    $exe = Join-Path $Dir 'noctty.exe'
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'noctty.portable'))) { throw 'Portable marker missing; launch blocked.' }
    $line = '"{0}" {1}' -f $exe, ($Arguments -join ' ')
    $pi = [HiddenWin]::Launch($exe, $line, $Dir, "WinSta0\$DesktopName", $Job, $StderrPath)
    $process = [Diagnostics.Process]::GetProcessById($pi.pid)
    [void][HiddenWin]::CloseHandle($pi.thread)
    return @{ Process = $process; Pid = $pi.pid; Handle = $pi.process; StartTime = $process.StartTime }
}

function Get-HiddenExitCode($Started) {
    [uint32]$code = 0
    if (-not [HiddenWin]::GetExitCodeProcess($Started.Handle, [ref]$code)) { return $null }
    return [int]$code
}

# A key as TranslateMessage would deliver it: the surface drops a WM_CHAR that no WM_KEYDOWN announced.
function Send-Key([IntPtr] $Hwnd, [int] $Vk, [int] $Char) {
    $scan = [HiddenWin]::MapVirtualKeyW([uint32]$Vk, 0)
    $down = [int64](1 -bor ([int64]$scan -shl 16)); $up = $down -bor 0xC0000000L
    $ok = [HiddenWin]::Send($Hwnd, 0x0100, $Vk, $down)
    if ($Char -ne 0) { $ok = [HiddenWin]::Send($Hwnd, 0x0102, $Char, $down) -and $ok }
    $ok = [HiddenWin]::Send($Hwnd, 0x0101, $Vk, $up) -and $ok
    if (-not $ok) { throw ('SendMessageTimeout to 0x{0:X} failed or timed out' -f $Hwnd.ToInt64()) }
}

# Letters, digits and space go as their own keys; everything else as VK_PACKET.
function Send-Text([IntPtr] $Hwnd, [string] $Text) {
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 13) { Send-Key $Hwnd 0x0D 13 }
        elseif (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x61 -and $code -le 0x7A) -or $code -eq 0x20) {
            Send-Key $Hwnd ([int][char]::ToUpperInvariant($ch)) $code
        }
        else { Send-Key $Hwnd 0xE7 $code }
        Start-Sleep -Milliseconds 15
    }
}

# Every descendant of `RootPid` with its name and command line. Callers reduce the command line to a
# redacted shape before anything is written down.
function Get-Descendants([int] $RootPid) {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
    $found = [Collections.Generic.List[object]]::new(); $queue = [Collections.Generic.Queue[int]]::new(); $queue.Enqueue($RootPid)
    while ($queue.Count) {
        $parent = $queue.Dequeue()
        foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $parent }) { $found.Add($child); $queue.Enqueue([int]$child.ProcessId) }
    }
    return $found.ToArray()
}

# A command line reduced to what a check needs: the run directory and the user profile become
# placeholders, and only the first arguments, each cut short, are kept.
function Get-RedactedCommandLine([string] $CommandLine, [string[]] $Roots, [int] $MaxArguments = 13, [int] $MaxArgumentLength = 80) {
    if (-not $CommandLine) { return '' }
    $text = $CommandLine
    foreach ($root in $Roots) { if ($root) { $text = $text.Replace($root, '<run>') } }
    $text = $text.Replace($env:USERPROFILE, '<user>')
    $parts = [regex]::Matches($text, '"[^"]*"|\S+') | ForEach-Object { $_.Value } | Select-Object -First $MaxArguments
    return ($parts | ForEach-Object { if ($_.Length -gt $MaxArgumentLength) { $_.Substring(0, $MaxArgumentLength) + '...' } else { $_ } }) -join ' '
}
