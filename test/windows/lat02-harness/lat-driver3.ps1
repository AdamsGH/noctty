#requires -Version 7.0
<#
MEASUREMENT ONLY (LAT-01): keystroke-to-present latency on a private desktop.

Outer mode copies a built noctty (Bin) into a NEW Run directory with
noctty.portable beside it, redirects LOCALAPPDATA and APPDATA into Run, creates
a private desktop and starts this script again on it (-Driver). The driver
starts noctty running lat-echo.exe, posts WM_KEYDOWN/WM_KEYUP pairs to the
noctty.win32 child on a schedule (the target's own TranslateMessage types the
character), QPC-stamps each post, then asks noctty to dump its latency trace.
The real startup-attempts.json is checked against the adopted baseline before
and after every run. Nothing is shown on the interactive desktop, nothing
takes the foreground, the clipboard is never touched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [string] $Echo = (Join-Path $PSScriptRoot 'lat-echo-v3.exe'),
    [int] $DelayMs = 0,
    [ValidateSet('vt','records','ssh')] [string] $Mode = 'vt',
    [ValidateSet('steady','burst','cursor')] [string] $Pattern = 'steady',
    [int] $Count = 240,
    [int] $Seed = 1,
    [ValidateSet('primary','right60')] [string] $Monitor = 'primary',
    [ValidateSet('bundled','inbox')] [string] $ConPty = 'bundled',
    [ValidateSet('plain','line','tui')] [string] $Style = 'plain',
    [string[]] $Extra = @(),
    [switch] $Driver,
    [int] $DriverTimeoutSeconds = 240,
    [int] $VsyncHz = 0,
    [switch] $VsyncSync
)
$ErrorActionPreference = 'Stop'
$BaselineHash = '7b4f9aa31731df822e3ec13f8381e76dc759455abbf8bb458f74e10bf5e2bb9c'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class Lat {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime,jobTime; public uint flags; public UIntPtr minWorking,maxWorking;
        public uint activeProcesses; public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits basic; public IoCounters io; public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime,kernelTime,periodUserTime,periodKernelTime;
        public uint pageFaults,totalProcesses,activeProcesses,terminatedProcesses;
    }
    public delegate bool EnumWindow(IntPtr h,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder value,int length,out int needed);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow c,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumWindow c,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code,uint type);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr p,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr p,out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr p);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j,int t,ref JobLimits l,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p,uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr j,uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr j,int t,out JobAccounting a,uint size,IntPtr r);
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);
    public static IntPtr CreateOwnedJob() {
        var j=CreateJobObjectW(IntPtr.Zero,null); if(j==IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var l=new JobLimits(); l.basic.flags=0x2000;
        if(!SetInformationJobObject(j,9,ref l,(uint)Marshal.SizeOf<JobLimits>())) { CloseHandle(j); throw new Exception("Job limit failed"); }
        return j;
    }
    public static uint StopOwnedJob(IntPtr j) {
        try {
            if(!TerminateJobObject(j,1)) throw new Exception("Owned job termination failed");
            var deadline=DateTime.UtcNow.AddSeconds(5);
            do { JobAccounting a;
                if(!QueryInformationJobObject(j,1,out a,(uint)Marshal.SizeOf<JobAccounting>(),IntPtr.Zero)) throw new Exception("Owned job accounting failed");
                if(a.activeProcesses==0) return a.totalProcesses; Thread.Sleep(10);
            } while(DateTime.UtcNow<deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(j); }
    }
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job,uint flags) {
        // A GUI target must not get STARTF_USESHOWWINDOW/SW_HIDE, or its first
        // ShowWindow hides it and the renderer never presents.
        bool gui=(flags&0x80000000u)!=0; flags&=0x7FFFFFFFu;
        var s=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=gui?0:1,show=0 }; ProcessInfo p;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags|0x4,IntPtr.Zero,cwd,ref s,out p))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if(!AssignProcessToJobObject(job,p.process)||ResumeThread(p.thread)==0xFFFFFFFF) {
            TerminateProcess(p.process,1); CloseHandle(p.thread); CloseHandle(p.process); throw new Exception("Owned launch assignment/resume failed");
        }
        return p;
    }
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr Surface(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") EnumChildWindows(h,(c,q)=> { if(Class(c)=="noctty.win32") found=c; return true; },IntPtr.Zero);
            return true;
        },IntPtr.Zero); return found;
    }
    public static string Dump() {
        var sb=new StringBuilder();
        EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id); sb.Append(id).Append(':').Append(Class(h)).Append(' '); return true; },IntPtr.Zero);
        return sb.ToString();
    }
    public static string DesktopName() {
        var name=new StringBuilder(256); int needed;
        if(!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),2,name,name.Capacity*2,out needed)) throw new Exception("Driver desktop identity unavailable");
        return name.ToString();
    }
    // One scheduled key message. Due is in Stopwatch (QPC) ticks.
    public class Ev { public long Due; public bool Down; public int Index; public int Vk; public long Posted; }
    // Posts every event at its due time; returns the QPC read just before each PostMessage.
    public static void Play(IntPtr h, List<Ev> evs) {
        timeBeginPeriod(1);
        Thread.CurrentThread.Priority=ThreadPriority.Highest;
        evs.Sort((a,b)=>a.Due.CompareTo(b.Due));
        foreach(var e in evs) {
            for(;;) {
                long now=Stopwatch.GetTimestamp(); long left=e.Due-now;
                if(left<=0) break;
                long ms=left*1000/Stopwatch.Frequency;
                if(ms>=2) Thread.Sleep((int)(ms-1)); else Thread.SpinWait(50);
            }
            uint scan=MapVirtualKeyW((uint)e.Vk,0);
            long l=1L|((long)scan<<16);
            if(!e.Down) l|=0xC0000000L;
            // LAT-02: arrow keys carry the extended-key bit, as on a real keyboard.
            if(e.Vk>=0x21 && e.Vk<=0x28) l|=1L<<24;
            e.Posted=Stopwatch.GetTimestamp();
            if(!PostMessageW(h,e.Down?0x100u:0x101u,new IntPtr(e.Vk),new IntPtr(l))) throw new Exception("Key post failed");
        }
    }
}
'@

function Startup-Fingerprint {
    $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if(-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false; Hash=$null; Modified=$null } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}

if(-not $Driver) {
    $Bin=(Resolve-Path -LiteralPath $Bin).Path; $Run=[IO.Path]::GetFullPath($Run)
    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
    $before=Startup-Fingerprint
    if($before.Hash -ne $BaselineHash) { throw 'Real startup-attempts.json differs from the adopted baseline; not launching.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $portable=Join-Path $Run 'app\bin'; [void](New-Item -ItemType Directory -Path $portable)
    Get-ChildItem -LiteralPath $Bin -File | Where-Object { $_.Extension -in '.exe','.dll' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'app\share') -Recurse }
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    Copy-Item -LiteralPath $Echo -Destination (Join-Path $Run 'lat-echo.exe')
    foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
    $desktopName='noctty-lat01-'+[guid]::NewGuid().ToString('N')
    $desktop=[Lat]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $saved=@{}; foreach($k in 'LOCALAPPDATA','APPDATA','NOCTTY_LATENCY_TRACE_FILE','NOCTTY_RENDER_TRACE_FILE','NOCTTY_RENDER_TRACE_LIVE','NOCTTY_CONPTY','NOCTTY_LAT_VSYNC_HZ','NOCTTY_LAT_VSYNC_SYNC') { $saved[$k]=[Environment]::GetEnvironmentVariable($k) }
    $job=[IntPtr]::Zero; $pi=$null; $code=1
    try {
        $job=[Lat]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $env:NOCTTY_LATENCY_TRACE_FILE=Join-Path $Run 'latency.txt'
        $env:NOCTTY_RENDER_TRACE_FILE=Join-Path $Run 'render.json'; $env:NOCTTY_RENDER_TRACE_LIVE='1'
        if($ConPty -eq 'inbox') { $env:NOCTTY_CONPTY='inbox' } else { $env:NOCTTY_CONPTY=$null }
        if($VsyncHz -gt 0) { $env:NOCTTY_LAT_VSYNC_HZ="$VsyncHz" } else { $env:NOCTTY_LAT_VSYNC_HZ=$null }
        if($VsyncSync) { $env:NOCTTY_LAT_VSYNC_SYNC='1' } else { $env:NOCTTY_LAT_VSYNC_SYNC=$null }
        $pwsh=(Get-Command pwsh.exe).Source
        $argList=@('-NoProfile','-NonInteractive','-File',"`"$PSCommandPath`"",'-Bin',"`"$portable`"",'-Run',"`"$Run`"",
            '-DelayMs',$DelayMs,'-Mode',$Mode,'-Pattern',$Pattern,'-Count',$Count,'-Seed',$Seed,'-Monitor',$Monitor,'-ConPty',$ConPty,'-Style',$Style,'-Driver')
        if($Extra.Count -gt 0) { $argList+=@('-Extra',(($Extra | ForEach-Object { "`"$_`"" }) -join ',')) }
        $command="`"$pwsh`" "+($argList -join ' ')
        $pi=[Lat]::Launch($pwsh,$command,$Run,"WinSta0\$desktopName",$job,0x08004000)
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while([Lat]::WaitForSingleObject($pi.process,500) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw 'Hidden driver timeout; owned job will be stopped.' }
        }
        [uint32]$code=0; [void][Lat]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        foreach($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k,$saved[$k]) }
        $cleanupError=$null
        if($job -ne [IntPtr]::Zero) { try { [void][Lat]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Lat]::CloseHandle($pi.thread); [void][Lat]::CloseHandle($pi.process) }
        [void][Lat]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        @{Before=$before;After=$after} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if($after.Hash -ne $before.Hash -or $after.Modified -ne $before.Modified) { throw 'Real startup state changed; stop launches.' }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Driver failed ($code); see $Run\driver.log" }
    Write-Host "run complete: $Run"
    exit 0
}

# --- Driver, on the private desktop ---
$log=Join-Path $Run 'driver.log'
function Log([string]$m) { Add-Content -LiteralPath $log -Value ("{0:o} {1}" -f [datetime]::UtcNow,$m) }
try {
    if(-not ([Lat]::DesktopName()).StartsWith('noctty-lat01-',[StringComparison]::Ordinal)) { throw 'Driver is not on the private desktop.' }
    if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable'))) { throw 'Portable marker missing.' }
    foreach($dir in @('LOCALAPPDATA','APPDATA')) {
        $value=[Environment]::GetEnvironmentVariable($dir)
        if(-not $value -or -not [IO.Path]::GetFullPath($value).StartsWith($Run.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'AppData isolation failed.' }
    }
    $job=[Lat]::CreateOwnedJob()
    if($env:LAT01_PROBE_DESKTOP) {
        $probeOut=Join-Path $Run 'deskprobe.txt'
        $dp=[Lat]::Launch($env:LAT01_PROBE_DESKTOP,"`"$($env:LAT01_PROBE_DESKTOP)`" `"$probeOut`"",$Run,"WinSta0\$([Lat]::DesktopName())",$job,0x08000000)
        [void][Lat]::WaitForSingleObject($dp.process,5000)
        Log ("null-desktop child: " + (Get-Content -LiteralPath $probeOut -Raw))
        Log ("driver desktop: " + [Lat]::DesktopName())
        exit 0
    }
    $echoLog=Join-Path $Run 'echo.txt'; $ready=Join-Path $Run 'echo-ready.txt'
    $pos=if($Monitor -eq 'right60') { @('--window-position-x=4000','--window-position-y=600') } else { @('--window-position-x=200','--window-position-y=200') }
    $args2=@('--window-save-state=never','--confirm-close-surface=false','--auto-update=off','--window-width=100','--window-height=30')+$pos+$Extra
    $exe=Join-Path $Bin 'noctty.exe'
    $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$(Join-Path $Run 'lat-echo.exe')`" $DelayMs $Mode `"$echoLog`" `"$ready`" $Style"
    Log "launch: $cmd"
    # Always name the private desktop: a child started with a null lpDesktop
    # from this driver lands on the Default desktop (measured 2026-10-14).
    $p=[Lat]::Launch($exe,$cmd,$Run,"WinSta0\$([Lat]::DesktopName())",$job,[uint32]2147483648)
    $deadline=[datetime]::UtcNow.AddSeconds(30); $h=[IntPtr]::Zero
    while([datetime]::UtcNow -lt $deadline) {
        $h=[Lat]::Surface($p.pid)
        if($h -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $ready)) { break }
        Start-Sleep -Milliseconds 100
    }
    if($h -eq [IntPtr]::Zero) { Log ("pid={0} windows: {1}" -f $p.pid,[Lat]::Dump()); throw 'noctty surface not found.' }
    if(-not (Test-Path -LiteralPath $ready)) { throw 'lat-echo never became ready.' }
    Log "surface=0x$('{0:X}' -f $h.ToInt64())"
    Start-Sleep -Milliseconds 2500

    $rng=[Random]::new($Seed); $f=[Diagnostics.Stopwatch]::Frequency
    $evs=[Collections.Generic.List[Lat+Ev]]::new()
    $t=[Diagnostics.Stopwatch]::GetTimestamp()+[long]($f/2)
    for($i=0;$i -lt $Count;$i++) {
        $vk=0x41+($i % 26)
        # LAT-02 cursor: 40 letters, then Left/Right alternating; each arrow's
        # echo (ESC[D / ESC[C) only moves the cursor.
        if($Pattern -eq 'cursor' -and $i -ge 40) { $vk=if((($i-40) % 2) -eq 0) { 0x25 } else { 0x27 } }
        # Key hold times of real typing: 50-110 ms; a fast burst rolls keys
        # (the next key goes down before the previous one is released).
        if($Pattern -ne 'burst') { $gap=83+$rng.Next(0,43); $hold=50+$rng.Next(0,61) }
        else { $gap=if(($i % 6) -eq 0 -and $i -gt 0) { 420+$rng.Next(0,80) } else { 30+$rng.Next(0,12) }; $hold=40+$rng.Next(0,51) }
        if($i -gt 0) { $t+=[long]($gap*$f/1000) }
        $evs.Add([Lat+Ev]@{Due=$t;Down=$true;Index=$i;Vk=$vk})
        $evs.Add([Lat+Ev]@{Due=$t+[long]($hold*$f/1000);Down=$false;Index=$i;Vk=$vk})
    }
    [Lat]::Play($h,$evs)
    $lines=foreach($e in $evs) { if($e.Down) { "D {0} {1} {2}" -f $e.Index,$e.Posted,$e.Vk } else { "U {0} {1} {2}" -f $e.Index,$e.Posted,$e.Vk } }
    Set-Content -LiteralPath (Join-Path $Run 'keys.txt') -Value $lines
    Start-Sleep -Milliseconds 1500
    $trace=Join-Path $Run 'latency.txt'
    if(-not [Lat]::PostMessageW($h,0x8008,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'snapshot post failed' }
    $deadline=[datetime]::UtcNow.AddSeconds(10); $last=-1
    while([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if(Test-Path -LiteralPath $trace) { $len=(Get-Item -LiteralPath $trace).Length; if($len -gt 0 -and $len -eq $last) { break }; $last=$len }
    }
    Log "trace bytes=$last"
    [void][Lat]::StopOwnedJob($job)
    exit 0
} catch {
    Log "ERROR $_"
    exit 1
}
