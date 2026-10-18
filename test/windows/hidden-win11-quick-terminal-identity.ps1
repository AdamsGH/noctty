#requires -Version 7.0
<#
Portable, hidden-desktop integration regression for quick-terminal identity and
new-window placement (PKG-43). Run with -Bin <source bin directory> -Run <new
evidence directory>. The run directory must not already exist. Never switches
desktops, injects real input or registers a global hotkey: every action is an
in-app keybind driven by posted key messages. Optional
ExpectedStartupHash/ExpectedStartupModified pin an adopted baseline; otherwise
even an absent startup-state file is captured and checked unchanged.
DriverTimeoutSeconds bounds the hidden driver and its owned process job.
Results contain only window geometry, process IDs, window state and assertions.
It exits 1 when a check fails, so it can be run against a build that still has
the problem to show what fails.
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
public static class Qt {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    public class State { public Rect Rect; public uint Dpi; public bool Visible,Iconic,Zoomed,Topmost; }
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
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action,uint param,out Rect value,uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
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
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
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
    // Every terminal pane of a host, in the order Windows enumerates them.
    public static IntPtr[] Surfaces(IntPtr host) {
        var list=new List<IntPtr>();
        EnumChildWindows(host,(c,p)=> { if(Class(c)=="noctty.win32") list.Add(c); return true; },IntPtr.Zero);
        return list.ToArray();
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static Rect PrimaryWork() {
        Rect r; if(!SystemParametersInfoW(0x30,0,out r,0)) throw new Exception("SPI_GETWORKAREA failed"); return r;
    }
    public static State Read(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r;
            if(!GetWindowRect(h,out r)) throw new Exception("Window measurement failed");
            long ex=GetWindowLongPtr(h,-20).ToInt64();
            return new State { Rect=r,Dpi=GetDpiForWindow(h),Visible=IsWindowVisible(h),Iconic=IsIconic(h),Zoomed=IsZoomed(h),Topmost=(ex&8)!=0 };
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static void Move(IntPtr h,int x,int y,int w,int ht) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { if(!SetWindowPos(h,IntPtr.Zero,x,y,w,ht,0x14)) throw new Exception("SetWindowPos failed"); }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    // A key-down and key-up posted straight to a pane, the way the DPI harness
    // does. A keybind is not a global hotkey, so nothing is registered.
    public static void Key(IntPtr surface,int key) {
        if(!PostMessageW(surface,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(surface,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder value,int length,out int needed);
    // The name of the desktop of the thread that owns `h`.
    public static string WindowDesktop(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid); var name=new StringBuilder(256); int needed;
        if(tid==0 || !GetUserObjectInformationW(GetThreadDesktop((uint)tid),2,name,512,out needed)) throw new Exception("Window desktop query failed");
        return name.ToString();
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
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-Portable $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-qt-' + [guid]::NewGuid().ToString('N')
    $desktop = [Qt]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero
    try {
        $job=[Qt]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -DesktopName "{4}" -Driver' -f $pwsh,$PSCommandPath,(Join-Path $Run 'source\bin'),$Run,$desktopName
        $pi=[Qt]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([Qt]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$code=0; [void][Qt]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[Qt]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Qt]::CloseHandle($pi.thread); [void][Qt]::CloseHandle($pi.process) }
        [void][Qt]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        @{ Before=$before; After=$after; Unchanged=$unchanged; OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host 'Hidden quick terminal identity: PASS'
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Qt]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
function Rect-Array($r) { return @($r.Left,$r.Top,$r.Right,$r.Bottom) }
function Rect-Same($a,$b,[int]$Tolerance=2) {
    return [Math]::Abs($a.Left-$b.Left) -le $Tolerance -and [Math]::Abs($a.Top-$b.Top) -le $Tolerance -and [Math]::Abs($a.Right-$b.Right) -le $Tolerance -and [Math]::Abs($a.Bottom-$b.Bottom) -le $Tolerance
}
function Sample([string]$Name,$h) { $s=[Qt]::Read($h); $script:samples.Add(@{Name=$Name; State=$s}); return $s }
function Wait-Until([scriptblock]$Predicate,[int]$Seconds=10) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do { if(& $Predicate) { return $true }; Start-Sleep -Milliseconds 50 } while([datetime]::UtcNow -lt $deadline)
    return [bool](& $Predicate)
}
# The pane that is on screen in `$h`, or any pane when none is.
function Pane($h) {
    $all=@([Qt]::Surfaces($h)); $shown=@($all|Where-Object {[Qt]::Read($_).Visible})
    if($shown.Count) { return $shown[0] }
    if($all.Count) { return $all[0] }
    throw 'Host has no pane.'
}
function Press($pane,[int]$Key,[int]$SettleMs=700) { [Qt]::Key($pane,$Key); Start-Sleep -Milliseconds $SettleMs }
function Other-Hosts($case,$known) { return @([Qt]::Hosts($case.Process.Id)|Where-Object {$known -notcontains $_ -and @([Qt]::Surfaces($_)).Count -gt 0}) }
function Launch-Case([string]$Name,[string]$Extra='') {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    $config=Join-Path $dir 'identity.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false',
      'keybind = f10=toggle_quick_terminal','keybind = f9=new_split:right','keybind = f8=close_surface','keybind = f7=close_tab:this','keybind = f6=toggle_visibility','keybind = f5=new_window',
      'quick-terminal-screen = main','quick-terminal-autohide = false','quick-terminal-animation-duration = 0','quick-terminal-size = 25%', $Extra) | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'
    # An explicit lpDesktop: a child that a private-desktop driver starts with a null desktop can
    # land on the interactive desktop. The Process object holds its own handle before the launch
    # handles close, so it stays this launch's process.
    $pi=[Qt]::Spawn($exe,('"{0}" --config-file="{1}"' -f $exe,$config),$dir,"WinSta0\$DesktopName")
    try { $p=[Diagnostics.Process]::GetProcessById($pi.pid); [void]$p.Handle }
    finally { [void][Qt]::CloseHandle($pi.thread); [void][Qt]::CloseHandle($pi.process) }
    $script:processes.Add(@{Case=$Name;Pid=$p.Id;StartTime=$p.StartTime.ToUniversalTime().ToString('o');Executable=$p.ProcessName})
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    do {
        $hosts=@([Qt]::Hosts($p.Id))
        if($hosts.Count -and [Qt]::WindowDesktop($hosts[0]) -ne $DesktopName) { Close-Case @{Process=$p}; throw "Case $Name window is not on the private desktop." }
        $ready=$false
        $ledger=Join-Path $dir 'startup-attempts.json'
        if(Test-Path -LiteralPath $ledger) {
            try {
                $attempts=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready=$attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if($ready -and $hosts.Count -and @([Qt]::Surfaces($hosts[0])).Count -gt 0) {
            [void][Qt]::ShowWindow($hosts[0],4)
            Start-Sleep -Milliseconds 400
            return @{Process=$p; Host=$hosts[0]}
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline -and -not $p.HasExited)
    Close-Case @{Process=$p}
    throw "Window startup failed for case $Name."
}
function Close-Case($case) {
    foreach($h in [Qt]::Hosts($case.Process.Id)) { [void][Qt]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if(-not $case.Process.WaitForExit(5000)) {
        $p=Get-Process -Id $case.Process.Id -ErrorAction Stop
        if($p.StartTime -eq $case.Process.StartTime -and $p.Path -eq $case.Process.Path) { Stop-Process -Id $p.Id -Force }
        else { throw 'Exact process identity changed during cleanup.' }
    }
}
try {
    $work=[Qt]::PrimaryWork()

    # F041/F040: the quick terminal is its host. Hide and show every window
    # around a dismissed quick terminal first, while its first pane is still
    # there, then split it, close the pane it was created with, and toggle it.
    $case=Launch-Case 'identity'
    try {
        $main=$case.Host; $known=@($main)
        Press (Pane $main) 121 1500            # toggle_quick_terminal
        $qtHosts=@(Other-Hosts $case $known)
        Check 'quick terminal opened as a second host' ($qtHosts.Count -eq 1) 1 $qtHosts.Count
        if($qtHosts.Count -ne 1) { throw 'Quick terminal absent.' }
        $qt=$qtHosts[0]; $known=@($main,$qt)
        Start-Sleep -Milliseconds 600

        # Dismiss it, then hide and show every window: it stays dismissed.
        Press (Pane $qt) 121 1200
        Check 'quick terminal dismissed' (-not ([Qt]::Read($qt)).Visible) $false ([Qt]::Read($qt)).Visible
        Press (Pane $main) 117 800             # toggle_visibility: hide every window
        Check 'toggle_visibility hid the main window' (-not ([Qt]::Read($main)).Visible) $false ([Qt]::Read($main)).Visible
        Press (Pane $main) 117 1200            # toggle_visibility: show them again
        Check 'toggle_visibility showed the main window' ([Qt]::Read($main)).Visible $true ([Qt]::Read($main)).Visible
        Check 'toggle_visibility left the dismissed quick terminal hidden' (-not ([Qt]::Read($qt)).Visible) $false ([Qt]::Read($qt)).Visible

        # One that is on screen comes back with the rest.
        Press (Pane $main) 121 1500
        Check 'quick terminal shown again' ([Qt]::Read($qt)).Visible $true ([Qt]::Read($qt)).Visible
        Press (Pane $main) 117 800
        Check 'toggle_visibility hid both windows' (-not ([Qt]::Read($main)).Visible -and -not ([Qt]::Read($qt)).Visible) 'both hidden' @{Main=([Qt]::Read($main)).Visible; Qt=([Qt]::Read($qt)).Visible}
        Press (Pane $main) 117 1200
        Check 'toggle_visibility brought both back' (([Qt]::Read($main)).Visible -and ([Qt]::Read($qt)).Visible) 'both visible' @{Main=([Qt]::Read($main)).Visible; Qt=([Qt]::Read($qt)).Visible}

        $original=Pane $qt
        Press $original 120 1200               # new_split:right inside the quick terminal
        Check 'split opened inside the quick terminal' (@([Qt]::Surfaces($qt)).Count -eq 2) 2 @([Qt]::Surfaces($qt)).Count
        Press $original 119 1200               # close_surface: the pane the window was created with
        Check 'original pane closed' (-not [Qt]::Alive($original)) $true ([Qt]::Alive($original))
        Check 'quick terminal still has a pane' (@([Qt]::Surfaces($qt)).Count -eq 1) 1 @([Qt]::Surfaces($qt)).Count
        Check 'quick terminal host survived' ([Qt]::Alive($qt)) $true ([Qt]::Alive($qt))
        $remaining=Pane $qt
        [void](Sample 'qt-before-toggle' $qt)

        Press $remaining 121 1500              # toggle_quick_terminal: hide
        $hostsNow=@([Qt]::Hosts($case.Process.Id))
        Check 'toggle hides the quick terminal, no second one is made' ($hostsNow.Count -eq 2 -and -not ([Qt]::Read($qt)).Visible) 'two hosts, quick terminal hidden' @{Hosts=$hostsNow.Count; Visible=([Qt]::Read($qt)).Visible}
        Press $remaining 121 1500              # toggle_quick_terminal: show
        $hostsNow=@([Qt]::Hosts($case.Process.Id))
        Check 'toggle shows the same quick terminal' ($hostsNow.Count -eq 2 -and ([Qt]::Read($qt)).Visible) 'two hosts, quick terminal visible' @{Hosts=$hostsNow.Count; Visible=([Qt]::Read($qt)).Visible}
    } finally { Close-Case $case }

    # `close_tab:this` on the quick terminal's only tab keeps its (empty) host
    # and the surface for undo. The toggle dismisses the empty window, then
    # opens a fresh floating tab rather than showing the detached surface.
    $case=Launch-Case 'retained'
    try {
        $main=$case.Host; $known=@($main)
        Press (Pane $main) 121 1500
        $qtHosts=@(Other-Hosts $case $known)
        Check 'quick terminal opened' ($qtHosts.Count -eq 1) 1 $qtHosts.Count
        if($qtHosts.Count -eq 1) {
            $qt=$qtHosts[0]; $known=@($main,$qt)
            Start-Sleep -Milliseconds 600
            $detached=@([Qt]::Surfaces($qt))
            Press $detached[0] 118 1200        # close_tab:this
            $livePanes=@([Qt]::Surfaces($qt)|Where-Object {[Qt]::Read($_).Visible})
            Check 'host kept with no live pane' ([Qt]::Alive($qt) -and $livePanes.Count -eq 0) 'host alive, no visible pane' @{Alive=[Qt]::Alive($qt); VisiblePanes=$livePanes.Count}
            Press (Pane $main) 121 1500        # toggle_quick_terminal
            Check 'toggle dismissed the empty window' (-not ([Qt]::Read($qt)).Visible -and @([Qt]::Hosts($case.Process.Id)).Count -eq 2) 'hidden, two hosts' @{Visible=([Qt]::Read($qt)).Visible; Hosts=@([Qt]::Hosts($case.Process.Id)).Count}
            Press (Pane $main) 121 2000        # toggle_quick_terminal
            $panes=@([Qt]::Surfaces($qt)); $fresh=@($panes|Where-Object {$detached -notcontains $_})
            $live=@($panes|Where-Object {[Qt]::Read($_).Visible})
            Check 'toggle opened a fresh tab, not the detached surface' ($fresh.Count -eq 1 -and $live.Count -eq 1 -and $live[0] -eq $fresh[0] -and ([Qt]::Read($qt)).Visible) 'one new visible pane, window visible' @{Fresh=$fresh.Count; Live=$live.Count; Visible=([Qt]::Read($qt)).Visible}
            Check 'the fresh tab floats' ([Qt]::Read($qt)).Topmost $true ([Qt]::Read($qt)).Topmost
            Check 'still one quick terminal' (@([Qt]::Hosts($case.Process.Id)).Count -eq 2) 2 @([Qt]::Hosts($case.Process.Id)).Count
        }
    } finally { Close-Case $case }

    # F042: a new window from a minimized one starts on screen, at its
    # restored size, one cascade step off it.
    $case=Launch-Case 'new-window-minimized'
    try {
        $main=$case.Host; $known=@($main)
        [Qt]::Move($main,$work.Left+120,$work.Top+120,900,600); Start-Sleep -Milliseconds 500
        $restored=Sample 'source-restored' $main
        [void][Qt]::ShowWindow($main,7)        # SW_SHOWMINNOACTIVE
        Start-Sleep -Milliseconds 400
        Check 'source minimized' (([Qt]::Read($main)).Iconic) $true ([Qt]::Read($main)).Iconic
        Press (Pane $main) 116 2500            # new_window
        $created=@(Other-Hosts $case $known)
        Check 'new window opened' ($created.Count -eq 1) 1 $created.Count
        if($created.Count -eq 1) {
            $new=Sample 'new-window' $created[0]
            $step=[int][Math]::Round(32*$restored.Dpi/96.0)
            Check 'new window is wholly inside the work area' ($new.Visible -and -not $new.Iconic -and $new.Rect.Left -ge $work.Left -and $new.Rect.Top -ge $work.Top -and $new.Rect.Right -le $work.Right -and $new.Rect.Bottom -le $work.Bottom) (@('inside',$work.Left,$work.Top,$work.Right,$work.Bottom)) (Rect-Array $new.Rect)
            Check 'new window has the source restored size' ([Math]::Abs(($new.Rect.Right-$new.Rect.Left)-($restored.Rect.Right-$restored.Rect.Left)) -le 3 -and [Math]::Abs(($new.Rect.Bottom-$new.Rect.Top)-($restored.Rect.Bottom-$restored.Rect.Top)) -le 3) (@(($restored.Rect.Right-$restored.Rect.Left),($restored.Rect.Bottom-$restored.Rect.Top))) @(($new.Rect.Right-$new.Rect.Left),($new.Rect.Bottom-$new.Rect.Top))
            Check 'new window is one cascade step off the source' ([Math]::Abs($new.Rect.Left-($restored.Rect.Left+$step)) -le 2 -and [Math]::Abs($new.Rect.Top-($restored.Rect.Top+$step)) -le 2) @(($restored.Rect.Left+$step),($restored.Rect.Top+$step)) @($new.Rect.Left,$new.Rect.Top)
        }
    } finally { Close-Case $case }

    # F042: a new window from the quick terminal is an ordinary window, not
    # a topmost copy of the strip.
    $case=Launch-Case 'new-window-from-quick-terminal'
    try {
        $main=$case.Host; $known=@($main)
        Press (Pane $main) 121 1500
        $qtHosts=@(Other-Hosts $case $known)
        Check 'quick terminal opened' ($qtHosts.Count -eq 1) 1 $qtHosts.Count
        if($qtHosts.Count -eq 1) {
            $qt=$qtHosts[0]; $known=@($main,$qt)
            Start-Sleep -Milliseconds 600
            $strip=Sample 'quick-terminal' $qt
            Check 'quick terminal is topmost' $strip.Topmost $true $strip.Topmost
            Press (Pane $qt) 116 2500          # new_window
            $created=@(Other-Hosts $case $known)
            Check 'new window opened from the quick terminal' ($created.Count -eq 1) 1 $created.Count
            if($created.Count -eq 1) {
                $new=Sample 'new-window-from-quick-terminal' $created[0]
                Check 'new window is not topmost' (-not $new.Topmost) $false $new.Topmost
                Check 'new window is not on the quick terminal strip' (-not (Rect-Same $new.Rect $strip.Rect 8)) 'a different rect' (Rect-Array $new.Rect)
            }
        }
    } finally { Close-Case $case }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Posted unmodified keys and Win32 window state on a never-switched desktop; real pointer, shell input, a global hotkey and visual composition are not exercised.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'identity-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){exit 1}
