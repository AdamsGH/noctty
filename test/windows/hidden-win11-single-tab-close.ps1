#requires -Version 7.0
<#
Portable, hidden-desktop measurement of closing the ONLY tab of a window
(TABX): the close button on the tab, and the keyboard close of the same tab
(a key bound to close_tab:this, which is what Ctrl+Shift+W runs). For each
case it records, from the action on, whether the host window stays up, whether
its tab button is still shown, whether a confirm prompt opened, and when the
process exited. Run with -Bin <source bin directory> -Run <new evidence
directory>. The run directory must not already exist.

Never switches desktops, injects real input or touches the clipboard: every
action is a posted window message. Nothing here copies, and the
configuration denies clipboard reads and writes and copy-on-select besides.
GetClipboardSequenceNumber (a counter, it reads no contents) is recorded
before and after, and the run fails when it moved. Optional
ExpectedStartupHash/ExpectedStartupModified pin an adopted baseline of the
real startup-attempts.json; either way it is fingerprinted before and after.
DriverTimeoutSeconds bounds the hidden driver and its owned process job.
Results contain only control geometry, label text, process IDs and
assertions. It exits 1 when a check fails, so it can be run against a build
that still has the problem to show what fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 300,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Ds {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo {
        public int cbSize, flags; public IntPtr active, focus, capture, menuOwner, moveSize, caret; public Rect caretRect;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,string l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(int thread,ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(int from,int to,bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll")] static extern int GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr dev,IntPtr mode,int flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job,int type,ref JobLimits limits,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr job,int type,out JobAccounting accounting,uint size,IntPtr returned);
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime,kernelTime,periodUserTime,periodKernelTime;
        public uint pageFaults,totalProcesses,activeProcesses,terminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime,jobTime; public uint flags;
        public UIntPtr minWorking,maxWorking; public uint activeProcesses;
        public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits basic; public IoCounters io;
        public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    public static IntPtr CreateOwnedJob() {
        var job=CreateJobObjectW(IntPtr.Zero,null);
        if(job==IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var limits=new JobLimits(); limits.basic.flags=0x2000; // KILL_ON_JOB_CLOSE
        if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf<JobLimits>())) {
            CloseHandle(job); throw new Exception("SetInformationJobObject failed");
        }
        return job;
    }
    public static uint StopOwnedJob(IntPtr job) {
        try {
            if(!TerminateJobObject(job,1)) throw new Exception("Terminate owned job failed");
            var deadline=DateTime.UtcNow.AddSeconds(5);
            do {
                JobAccounting accounting;
                if(!QueryInformationJobObject(job,1,out accounting,(uint)Marshal.SizeOf<JobAccounting>(),IntPtr.Zero))
                    throw new Exception("Query owned job failed");
                if(accounting.activeProcesses==0) return accounting.totalProcesses;
                System.Threading.Thread.Sleep(10);
            } while(DateTime.UtcNow<deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(job); }
    }
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") list.Add(h); return true;
        },IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr[] Surfaces(IntPtr host) {
        var list=new List<IntPtr>();
        EnumChildWindows(host,(c,p)=> { if(Class(c)=="noctty.win32") list.Add(c); return true; },IntPtr.Zero);
        return list.ToArray();
    }
    // The first child of `host` with the control ID, in the order Windows
    // enumerates them, or zero.
    public static IntPtr Child(IntPtr host,int id) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(host,(c,p)=> { if(GetDlgCtrlID(c)==id) { found=c; return false; } return true; },IntPtr.Zero);
        return found;
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static uint Dpi(IntPtr h) { return GetDpiForWindow(h); }
    public static Rect RectOf(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r; if(!GetWindowRect(h,out r)) throw new Exception("Window measurement failed"); return r; }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    public static int ClientWidth(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r; if(!GetClientRect(h,out r)) throw new Exception("Client measurement failed"); return r.Right-r.Left; }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    // Resizes `host` so its client area is `clientWidth` wide, keeping its position.
    public static void SetClientWidth(IntPtr host,int clientWidth) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect w; Rect c; GetWindowRect(host,out w); GetClientRect(host,out c);
            int frame=(w.Right-w.Left)-(c.Right-c.Left);
            if(!SetWindowPos(host,IntPtr.Zero,w.Left,w.Top,clientWidth+frame,w.Bottom-w.Top,0x14)) throw new Exception("SetWindowPos failed");
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static string Text(IntPtr h) {
        var sb=new StringBuilder(512); SendMessageW(h,0x0D,new IntPtr(512),sb); return sb.ToString();
    }
    public static void SetText(IntPtr h,string text) { SendMessageW(h,0x0C,IntPtr.Zero,text); }
    public static void Click(IntPtr h) { if(!PostMessageW(h,0xF5,IntPtr.Zero,IntPtr.Zero)) throw new Exception("BM_CLICK post failed"); }
    public static void Key(IntPtr h,int key) {
        if(!PostMessageW(h,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(h,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    // A left click at client point (x, y) of `h`, as three posted messages.
    public static void LeftClick(IntPtr h,int x,int y) {
        var pos=new IntPtr(((y&0xFFFF)<<16)|(x&0xFFFF));
        if(!PostMessageW(h,0x200,IntPtr.Zero,pos)) throw new Exception("Mouse-move post failed");
        if(!PostMessageW(h,0x201,new IntPtr(1),pos)) throw new Exception("Button-down post failed");
        if(!PostMessageW(h,0x202,IntPtr.Zero,pos)) throw new Exception("Button-up post failed");
    }
    public static void Chars(IntPtr h,string text) {
        foreach(char ch in text) if(!PostMessageW(h,0x102,new IntPtr(ch),new IntPtr(1))) throw new Exception("Char post failed");
    }
    // The window with the keyboard focus in the UI thread that owns `h`.
    public static IntPtr FocusOf(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid);
        var info=new GuiThreadInfo(); info.cbSize=Marshal.SizeOf<GuiThreadInfo>();
        if(!GetGUIThreadInfo(tid,ref info)) throw new Exception("GetGUIThreadInfo failed");
        return info.focus;
    }
    // Moves the keyboard focus of the UI thread that owns `h` to `h` without
    // injecting input: this thread joins that thread's input queue for the call.
    public static void FocusOn(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid); int me=GetCurrentThreadId();
        if(!AttachThreadInput(me,tid,true)) throw new Exception("AttachThreadInput failed");
        try { SetFocus(h); } finally { AttachThreadInput(me,tid,false); }
    }
    // Starts a process on the named desktop, with no console window.
    public static ProcessInfo Spawn(string app,string command,string cwd,string desktop) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        return pi;
    }
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        // Assign the suspended driver before it can spawn children. The job
        // owns only this launch and its descendants, including terminal shells.
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08004004,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if(!AssignProcessToJobObject(job,pi.process)||ResumeThread(pi.thread)==0xFFFFFFFF) {
            TerminateProcess(pi.process,1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume owned driver failed");
        }
        return pi;
    }
}
'@
function Startup-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function Copy-Portable([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}
if (-not $Driver) {
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Source Bin must contain noctty.exe.' }
    $before = Startup-Fingerprint
    $clipBefore = [Ds]::GetClipboardSequenceNumber()
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-Portable $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-tabx-' + [guid]::NewGuid().ToString('N')
    $desktop = [Ds]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero
    try {
        $job=[Ds]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -DesktopName "{4}" -Driver' -f $pwsh,$PSCommandPath,(Join-Path $Run 'source\bin'),$Run,$desktopName
        $pi=[Ds]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([Ds]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$code=0; [void][Ds]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[Ds]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
        [void][Ds]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $clipAfter=[Ds]::GetClipboardSequenceNumber()
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        @{ Before=$before; After=$after; Unchanged=$unchanged; ClipboardSequenceBefore=$clipBefore; ClipboardSequenceAfter=$clipAfter; ClipboardUnchanged=($clipBefore -eq $clipAfter); OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if ($clipBefore -ne $clipAfter) { throw "Clipboard sequence number moved ($clipBefore -> $clipAfter); stop launches and report it." }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host 'Hidden single-tab close: PASS'
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Ds]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
$desktopPath="WinSta0\$DesktopName"
$runClass='noctty-test-tabx-' + [guid]::NewGuid().ToString('N').Substring(0,8)
function Check([string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
function Wait-Until([scriptblock]$Predicate,[int]$Seconds=10) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do { if(& $Predicate) { return $true }; Start-Sleep -Milliseconds 50 } while([datetime]::UtcNow -lt $deadline)
    return [bool](& $Predicate)
}
# Control IDs (src/apprt/win32.zig): the tab buttons are 1000 + index, the
# confirm prompt's Allow button is 2003.
$Id=@{ Tab0=1000; Accept=2003 }
function Pane($h) {
    $all=@([Ds]::Surfaces($h)); $shown=@($all|Where-Object {[Ds]::Visible($_)})
    if($shown.Count) { return $shown[0] }
    if($all.Count) { return $all[0] }
    throw 'Host has no pane.'
}
function Launch-Case([string]$Name,[string[]]$Extra) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    $config=Join-Path $dir 'case.ghostty'
    # F5 runs what Ctrl+Shift+W runs by default (close_tab:this). A posted
    # Ctrl is invisible to GetKeyboardState, so the key is bound plain.
    @("working-directory = $dir",'single-instance = false','window-save-state = never',
      'copy-on-select = false','clipboard-read = deny','clipboard-write = deny',
      'keybind = f5=close_tab:this') + $Extra | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'
    $pi=[Ds]::Spawn($exe,('"{0}" --config-file="{1}" --single-instance=false --class={2}' -f $exe,$config,$runClass),$dir,$desktopPath)
    $script:processes.Add(@{Case=$Name;Pid=$pi.pid})
    $deadline=[datetime]::UtcNow.AddSeconds(25)
    do {
        $hosts=@([Ds]::Hosts($pi.pid))
        $ready=$false
        $ledger=Join-Path $dir 'startup-attempts.json'
        if(Test-Path -LiteralPath $ledger) {
            try {
                $attempts=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready=$attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if($ready -and $hosts.Count -and @([Ds]::Surfaces($hosts[0])).Count -gt 0) {
            [void][Ds]::ShowWindow($hosts[0],4)
            Start-Sleep -Milliseconds 1500
            return @{Pi=$pi; Pid=$pi.pid; Host=$hosts[0]}
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline)
    Close-Case @{Pi=$pi; Pid=$pi.pid}
    throw "Window startup failed for case $Name."
}
function Close-Case($case) {
    foreach($h in [Ds]::Hosts($case.Pid)) { [void][Ds]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if([Ds]::WaitForSingleObject($case.Pi.process,5000) -eq 258) {
        # The handle is this launch's own process: no name or pattern match.
        [void][Ds]::TerminateProcess($case.Pi.process,1)
        [void][Ds]::WaitForSingleObject($case.Pi.process,5000)
    }
    [void][Ds]::CloseHandle($case.Pi.thread); [void][Ds]::CloseHandle($case.Pi.process)
}
function Scaled([int]$base,[uint32]$dpi) { if($dpi -le 96){return $base}; return [int][Math]::Truncate($base*$dpi/96.0) }

# Does the close zone of the tab button draw a x? Counted by the pixels the
# zone is hit-tested at, not by looking: the hit test is what a click reaches.
# Performs `Action` ('x' or 'key') and samples the window for `Seconds`.
function Measure-Close($case,[string]$Action,[int]$Seconds=10) {
    $h=$case.Host; $dpi=[Ds]::Dpi($h)
    $tab=[Ds]::Child($h,$Id.Tab0)
    $tabShown=$tab -ne [IntPtr]::Zero -and [Ds]::Visible($tab)
    $tabRect=if($tabShown){[Ds]::RectOf($tab)}else{$null}
    $started=[datetime]::UtcNow
    if($Action -eq 'x') {
        if(-not $tabShown) { throw 'No tab button to click.' }
        $w=$tabRect.Right-$tabRect.Left; $ht=$tabRect.Bottom-$tabRect.Top
        [Ds]::LeftClick($tab,$w-(Scaled 12 $dpi),[int]($ht/2))
    } else {
        [Ds]::Key((Pane $h),0x74)        # F5: close_tab:this
    }
    $timeline=[Collections.Generic.List[object]]::new()
    $exitedAt=$null; $hostGoneAt=$null; $promptAt=$null; $tabGoneAt=$null
    do {
        $ms=[int]([datetime]::UtcNow-$started).TotalMilliseconds
        $alive=[Ds]::Alive($h)
        $vis=$alive -and [Ds]::Visible($h)
        $t=if($alive){[Ds]::Child($h,$Id.Tab0)}else{[IntPtr]::Zero}
        $tv=$t -ne [IntPtr]::Zero -and [Ds]::Visible($t)
        $a=if($alive){[Ds]::Child($h,$Id.Accept)}else{[IntPtr]::Zero}
        $av=$a -ne [IntPtr]::Zero -and [Ds]::Visible($a)
        $exited=[Ds]::WaitForSingleObject($case.Pi.process,0) -ne 258
        if($av -and $null -eq $promptAt) { $promptAt=$ms }
        if(-not $tv -and $null -eq $tabGoneAt) { $tabGoneAt=$ms }
        if(-not $alive -and $null -eq $hostGoneAt) { $hostGoneAt=$ms }
        if($exited -and $null -eq $exitedAt) { $exitedAt=$ms }
        $timeline.Add(@{Ms=$ms;HostAlive=$alive;HostVisible=$vis;TabShown=$tv;PromptShown=$av;ProcessExited=$exited})
        if($exited) { break }
        Start-Sleep -Milliseconds 100
    } while($ms -lt ($Seconds*1000))
    # Collapse the timeline to its changes.
    $changes=[Collections.Generic.List[object]]::new(); $prev=$null
    foreach($s in $timeline) {
        $key="$($s.HostAlive)|$($s.HostVisible)|$($s.TabShown)|$($s.PromptShown)|$($s.ProcessExited)"
        if($key -ne $prev) { $changes.Add($s); $prev=$key }
    }
    return @{ Action=$Action; TabShownBefore=$tabShown; Dpi=$dpi; TabPromptMs=$promptAt; TabGoneMs=$tabGoneAt; HostGoneMs=$hostGoneAt; ProcessExitedMs=$exitedAt; Changes=$changes }
}

$busy=@('command = cmd.exe /d /c ping -n 3600 127.0.0.1 >nul','shell-integration = none')
$idle=@('command = cmd.exe','shell-integration = detect')
$cases=@(
    @{ Name='idle-x';          Action='x';   Extra=$idle + 'confirm-close-surface = true' },
    @{ Name='idle-key';        Action='key'; Extra=$idle + 'confirm-close-surface = true' },
    @{ Name='busy-x';          Action='x';   Extra=$busy + 'confirm-close-surface = true' },
    @{ Name='busy-key';        Action='key'; Extra=$busy + 'confirm-close-surface = true' },
    @{ Name='busy-undo-off-x';   Action='x';   Extra=$busy + 'confirm-close-surface = true' + 'undo-timeout = 0s' },
    @{ Name='busy-undo-off-key'; Action='key'; Extra=$busy + 'confirm-close-surface = true' + 'undo-timeout = 0s' }
)
try {
    foreach($case in $cases) {
        $launched=Launch-Case $case.Name $case.Extra
        try {
            $result=Measure-Close $launched $case.Action
            $result.Name=$case.Name
            $script:samples.Add($result)
        } finally { Close-Case $launched }
    }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Posted window messages on a never-switched desktop; real pointer and keyboard input, the clipboard and visual composition are not exercised.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'single-tab-close-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){exit 1}
