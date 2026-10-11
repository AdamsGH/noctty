#requires -Version 7.0
<#
Hidden-desktop A/B startup and idle cost measurement for noctty builds.

  pwsh -NoProfile -File measure.ps1 -Side base=<bin dir> -Side variant=<bin dir> -Run <new dir> -Runs 7

Every side is a directory holding noctty.exe (its sibling 'share' folder is copied
too). Each run copies the side into its own portable folder (noctty.portable
marker), redirects LOCALAPPDATA/APPDATA into the run folder, launches on a desktop
created for this run (never the interactive one) and measures:
  - launch to first successful swap (GetTickCount64 delta, bench stage trace) and
    process start (main) to first swap (render trace)
  - private bytes at the first swap (bench stage trace) and at idle
  - thread count, loaded GPU/composition modules, CPU time and context switches over
    a fixed idle window (per-thread raw perf counters of that exact PID)
Sides are interleaved per run. -BannerCheck also posts a keybind that raises the
"Nothing to undo." banner and diffs PrintWindow captures of the host.
Checks that the real startup-attempts.json is unchanged before and after.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $Side,
    [Parameter(Mandatory)] [string] $Run,
    [ValidateRange(1,100)] [int] $Runs = 7,
    [ValidateRange(2,120)] [int] $IdleSeconds = 10,
    [switch] $BannerCheck,
    [switch] $LayoutProbe,
    [switch] $Driver,
    [ValidateRange(30,3600)] [int] $DriverTimeoutSeconds = 900,
    [string] $ExpectedStartupHash
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Hd {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
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
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
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
        var limits=new JobLimits(); limits.basic.flags=0x2000;
        if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf<JobLimits>())) { CloseHandle(job); throw new Exception("SetInformationJobObject failed"); }
        return job;
    }
    public static uint StopOwnedJob(IntPtr job) {
        try {
            if(!TerminateJobObject(job,1)) throw new Exception("Terminate owned job failed");
            var deadline=DateTime.UtcNow.AddSeconds(5);
            do {
                JobAccounting a;
                if(!QueryInformationJobObject(job,1,out a,(uint)Marshal.SizeOf<JobAccounting>(),IntPtr.Zero)) throw new Exception("Query owned job failed");
                if(a.activeProcesses==0) return a.totalProcesses;
                System.Threading.Thread.Sleep(10);
            } while(DateTime.UtcNow<deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(job); }
    }
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") list.Add(h); return true; },IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr Surface(IntPtr h) { IntPtr found=IntPtr.Zero;
        EnumChildWindows(h,(c,p)=> { if(Class(c)=="noctty.win32") found=c; return true; },IntPtr.Zero); return found; }
    public static void Key(IntPtr surface,int key) {
        if(!PostMessageW(surface,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(surface,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop }; ProcessInfo pi;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08004004,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if(!AssignProcessToJobObject(job,pi.process)||ResumeThread(pi.thread)==0xFFFFFFFF) {
            TerminateProcess(pi.process,1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume owned driver failed");
        }
        return pi;
    }
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool PtVisible(IntPtr dc, int x, int y);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    // Would host GDI paint at this client point reach the screen, or is it clipped by a child window?
    public static bool HostPaintVisibleAt(IntPtr host, int x, int y) {
        IntPtr dc=GetDC(host); if(dc==IntPtr.Zero) throw new Exception("GetDC failed");
        try { return PtVisible(dc,x,y); } finally { ReleaseDC(host,dc); }
    }
    public static int[] ClientSize(IntPtr host) { Rect r; GetClientRect(host,out r); return new int[]{r.Right-r.Left, r.Bottom-r.Top}; }
    [StructLayout(LayoutKind.Sequential)] public struct Pt { public int X, Y; }
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Pt p);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    // Where the host paints banner text (client coordinates): top of the terminal content + 2 DIP, 24 DIP tall,
    // from x = 16 DIP to the right edge minus 16 DIP. Reports which sampled points of that band the host's own
    // GDI paint can reach (not clipped by a child window) as merged x ranges.
    public static string BannerBandMap(IntPtr host, int contentTopOverride) {
        var origin=new Pt(); ClientToScreen(host, ref origin);
        int top=int.MaxValue; int panes=0;
        EnumChildWindows(host,(c,p)=> { if(Class(c)=="noctty.win32" && IsWindowVisible(c)) { Rect r; GetWindowRect(c,out r); if(r.Top-origin.Y<top) top=r.Top-origin.Y; panes++; } return true; },IntPtr.Zero);
        if(panes==0) return "no visible pane";
        if(contentTopOverride>=0) top=contentTopOverride;
        double scale=GetDpiForWindow(host)/96.0; int cw=ClientSize(host)[0];
        int y0=top+(int)Math.Round(2*scale), y1=y0+(int)Math.Round(24*scale), x0=(int)Math.Round(16*scale), x1=cw-(int)Math.Round(16*scale);
        int total=0, visible=0; var ranges=new List<string>(); int start=-1, last=-1;
        for(int x=x0; x<x1; x+=2) {
            bool colVisible=false;
            for(int y=y0; y<y1; y+=3) { total++; if(HostPaintVisibleAt(host,x,y)) { visible++; colVisible=true; } }
            if(colVisible) { if(start<0) start=x; last=x; } else if(start>=0) { ranges.Add(start+"-"+last); start=-1; }
        }
        if(start>=0) ranges.Add(start+"-"+last);
        var kids=new List<string>();
        EnumChildWindows(host,(c,p)=> { if(!IsWindowVisible(c)) return true; Rect r; GetWindowRect(c,out r);
            int cy0=r.Top-origin.Y, cy1=r.Bottom-origin.Y, cx0=r.Left-origin.X, cx1=r.Right-origin.X;
            if(cy1>y0 && cy0<y1 && cx1-cx0>2) kids.Add(Class(c)+"["+cx0+","+cy0+" "+(cx1-cx0)+"x"+(cy1-cy0)+"]"); return true; },IntPtr.Zero);
        return "panes="+panes+" kidsInBand="+string.Join(",",kids)+" scale="+scale.ToString("0.##")+" contentTop="+top+" band="+y0+".."+y1+" x="+x0+".."+x1+" sampledPoints="+total+" hostPaintReaches="+visible+" columns["+string.Join(";",ranges)+"]";
    }
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    // Visible child of the host with the given control id (the banner's invisible UIA child is 1913).
    public static bool ChildVisible(IntPtr host, int id) { bool vis=false;
        EnumChildWindows(host,(c,p)=> { if(GetDlgCtrlID(c)==id && IsWindowVisible(c)) vis=true; return true; },IntPtr.Zero); return vis; }
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long v);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long v);
    public static double QpcSeconds() { long v,f; QueryPerformanceCounter(out v); QueryPerformanceFrequency(out f); return (double)v/f; }
    // Per-thread context-switch counters of one process (SystemProcessInformation, x64 layout:
    // process header 0x100 bytes, SYSTEM_THREAD_INFORMATION 0x50 bytes with ContextSwitches at +0x40).
    [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationThread(IntPtr h, int cls, out IntPtr info, int len, IntPtr ret);
    // Win32 start address (ThreadQuerySetWin32StartAddress) of every thread of the process.
    public static long[] ThreadStarts(int pid) {
        var ids=ThreadSwitches(pid).Keys; var list=new List<long>();
        foreach(int tid in ids) {
            IntPtr h=OpenThread(0x0840,false,(uint)tid); if(h==IntPtr.Zero) { list.Add(0); continue; }
            try { IntPtr a; list.Add(NtQueryInformationThread(h,9,out a,IntPtr.Size,IntPtr.Zero)==0?a.ToInt64():0); } finally { CloseHandle(h); }
        }
        return list.ToArray();
    }
    public static Dictionary<int,uint> ThreadSwitches(int pid) {
        int size=1<<22; IntPtr buf=IntPtr.Zero;
        try {
            while(true) {
                buf=Marshal.AllocHGlobal(size); int ret;
                int st=NtQuerySystemInformation(5,buf,size,out ret);
                if(st==unchecked((int)0xC0000004)) { Marshal.FreeHGlobal(buf); buf=IntPtr.Zero; size=Math.Max(size*2,ret+65536); continue; }
                if(st!=0) throw new Exception("NtQuerySystemInformation failed: 0x"+st.ToString("x"));
                break;
            }
            long off=0;
            while(true) {
                IntPtr e=IntPtr.Add(buf,(int)off);
                uint next=(uint)Marshal.ReadInt32(e,0); int n=Marshal.ReadInt32(e,4);
                long id=Marshal.ReadInt64(e,0x50);
                if(id==pid) {
                    var d=new Dictionary<int,uint>();
                    for(int i=0;i<n;i++) {
                        IntPtr t=IntPtr.Add(e,0x100+i*0x50);
                        if(Marshal.ReadInt64(t,0x28)!=pid) throw new Exception("Thread layout check failed");
                        d[(int)Marshal.ReadInt64(t,0x30)]=(uint)Marshal.ReadInt32(t,0x40);
                    }
                    return d;
                }
                if(next==0) throw new Exception("Process not found");
                off+=next;
            }
        } finally { if(buf!=IntPtr.Zero) Marshal.FreeHGlobal(buf); }
    }
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [StructLayout(LayoutKind.Sequential)] struct BitmapInfoHeader { public int size,width,height; public short planes,bitCount; public int compression,sizeImage,xppm,yppm,clrUsed,clrImportant; }
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BitmapInfoHeader bi, uint usage);
    public class Shot { public int W,H; public byte[] Bgra; }
    // Top-down 32bpp BGRA capture of a window through PrintWindow.
    public static Shot Capture(IntPtr host, uint flags) {
        Rect r; if(!GetWindowRect(host,out r)) throw new Exception("GetWindowRect failed");
        int w=r.Right-r.Left, h=r.Bottom-r.Top;
        IntPtr screen=GetDC(IntPtr.Zero); IntPtr dc=CreateCompatibleDC(screen); IntPtr bmp=CreateCompatibleBitmap(screen,w,h);
        IntPtr old=SelectObject(dc,bmp);
        try {
            PrintWindow(host,dc,flags);
            var bi=new BitmapInfoHeader{ size=Marshal.SizeOf<BitmapInfoHeader>(), width=w, height=-h, planes=1, bitCount=32 };
            var bits=new byte[w*h*4];
            SelectObject(dc,old); old=IntPtr.Zero;
            if(GetDIBits(dc,bmp,0,(uint)h,bits,ref bi,0)==0) throw new Exception("GetDIBits failed");
            return new Shot{ W=w, H=h, Bgra=bits };
        } finally { if(old!=IntPtr.Zero) SelectObject(dc,old); DeleteObject(bmp); DeleteDC(dc); ReleaseDC(IntPtr.Zero,screen); }
    }
    public static void SaveBmp(Shot s, string path) {
        using(var f=new System.IO.FileStream(path,System.IO.FileMode.Create)) using(var bw=new System.IO.BinaryWriter(f)) {
            int stride=s.W*4, size=stride*s.H;
            bw.Write((byte)'B'); bw.Write((byte)'M'); bw.Write(54+size); bw.Write(0); bw.Write(54);
            bw.Write(40); bw.Write(s.W); bw.Write(-s.H); bw.Write((short)1); bw.Write((short)32); bw.Write(0); bw.Write(size); bw.Write(2835); bw.Write(2835); bw.Write(0); bw.Write(0);
            bw.Write(s.Bgra);
        }
    }
    // Differing pixels in rows [top,bottom) with their bounding box.
    public static int[] Diff(Shot a, Shot b, int top, int bottom) {
        int w=Math.Min(a.W,b.W), h=Math.Min(Math.Min(a.H,b.H),bottom);
        int count=0, minx=int.MaxValue, miny=int.MaxValue, maxx=-1, maxy=-1;
        for(int y=Math.Max(0,top); y<h; y++) for(int x=0; x<w; x++) {
            int ia=(y*a.W+x)*4, ib=(y*b.W+x)*4;
            if(a.Bgra[ia]!=b.Bgra[ib]||a.Bgra[ia+1]!=b.Bgra[ib+1]||a.Bgra[ia+2]!=b.Bgra[ib+2]) { count++; if(x<minx)minx=x; if(y<miny)miny=y; if(x>maxx)maxx=x; if(y>maxy)maxy=y; }
        }
        return new int[] { count, count==0?0:minx, count==0?0:miny, count==0?0:maxx, count==0?0:maxy };
    }
}
'@

function Startup-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function Parse-Sides([string[]]$Specs) {
    $out = [ordered]@{}
    foreach ($s in ($Specs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
        $i = $s.IndexOf('=')
        if ($i -lt 1) { throw "Side must be name=binDir: $s" }
        $name = $s.Substring(0, $i); $dir = $s.Substring($i + 1)
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'noctty.exe'))) { throw "Side $name has no noctty.exe in $dir" }
        $out[$name] = (Resolve-Path -LiteralPath $dir).Path
    }
    return $out
}
function Copy-Portable([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}

if (-not $Driver) {
    $sides = Parse-Sides $Side
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    $before = Startup-Fingerprint
    if ($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) { throw 'Real startup state differs from the supplied baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-meas-' + [guid]::NewGuid().ToString('N')
    $desktop = [Hd]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero; [uint32]$code=1
    try {
        $job=[Hd]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $sideArgs = '-Side "' + (($sides.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ',') + '"'
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" {2} -Run "{3}" -Runs {4} -IdleSeconds {5} {6} {7} -Driver' -f $pwsh,$PSCommandPath,$sideArgs,$Run,$Runs,$IdleSeconds,$(if($BannerCheck){'-BannerCheck'}else{''}),$(if($LayoutProbe){'-LayoutProbe'}else{''})
        $pi=[Hd]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([Hd]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [void][Hd]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[Hd]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Hd]::CloseHandle($pi.thread); [void][Hd]::CloseHandle($pi.process) }
        [void][Hd]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        @{ Before=$before; After=$after; Unchanged=$unchanged; OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        Write-Host ("Real startup-attempts.json unchanged: {0}" -f $unchanged)
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code." }
    Write-Host 'Done.'
    exit
}

# ---- driver: runs only on the new desktop; children inherit it ----
[void][Hd]::SetThreadDpiAwarenessContext([IntPtr](-4))
$sides = Parse-Sides $Side
$results = [Collections.Generic.List[object]]::new()
$banner = [Collections.Generic.List[object]]::new()
$script:ownedPids = [Collections.Generic.List[object]]::new()

function Read-Stages([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $rows = @()
    try {
        foreach ($l in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
            if ($l.Trim()) { try { $rows += ($l | ConvertFrom-Json -ErrorAction Stop) } catch { } }
        }
    } catch { }
    return $rows
}
function Ctx-Sample([int]$ProcId) {
    $per = [Hd]::ThreadSwitches($ProcId)
    return @{ Per = $per; At = [Hd]::QpcSeconds() }
}
function Start-Case([string]$Name, [string]$Bin, [string]$Extra) {
    $case = Join-Path $Run $Name
    [void](New-Item -ItemType Directory -Path $case)
    $dir = Join-Path $case 'bin'
    Copy-Portable $Bin $dir
    $config = Join-Path $dir 'measure.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false','window-save-state = never',
      'confirm-close-surface = false','cursor-style-blink = false','keybind = f9=undo', $Extra) | Set-Content -LiteralPath $config
    $stages = Join-Path $case 'stages.jsonl'; $render = Join-Path $case 'render.json'
    $env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE = $stages
    $env:NOCTTY_RENDER_TRACE_FILE = $render
    try {
        $launch = [Environment]::TickCount64
        $p = Start-Process -FilePath (Join-Path $dir 'noctty.exe') -ArgumentList @("--config-file=`"$config`"") -WorkingDirectory $dir -PassThru
    } finally {
        Remove-Item Env:NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:NOCTTY_RENDER_TRACE_FILE -ErrorAction SilentlyContinue
    }
    $script:ownedPids.Add(@{ Pid=$p.Id; Start=$p.StartTime })
    return @{ Proc=$p; Launch=$launch; Stages=$stages; Render=$render; Dir=$dir; Case=$case }
}
function Wait-FirstSwap($c, [int]$TimeoutMs = 30000) {
    $deadline = [Environment]::TickCount64 + $TimeoutMs
    do {
        $row = @(Read-Stages $c.Stages | Where-Object { $_.stage -eq 'first_successful_swap' })
        if ($row.Count -gt 0) { return $row[0] }
        if ($c.Proc.HasExited) { throw 'noctty exited before the first swap.' }
        Start-Sleep -Milliseconds 20
    } while ([Environment]::TickCount64 -lt $deadline)
    throw 'No first swap within the timeout.'
}
function Stop-Case($c) {
    foreach ($h in [Hd]::Hosts($c.Proc.Id)) { [void][Hd]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
    if (-not $c.Proc.WaitForExit(8000)) {
        $p = Get-Process -Id $c.Proc.Id -ErrorAction Stop
        if ($p.StartTime -eq $c.Proc.StartTime) { Stop-Process -Id $p.Id -Force } else { throw 'Exact process identity changed during cleanup.' }
    }
}

$layouts = [Collections.Generic.List[object]]::new()
try {
    if ($LayoutProbe) {
        $first = @($sides.Keys)[0]
        $cases = @(
            @{ Name = 'default'; Extra = ''; Keys = @(); Top = 60; Wait = 1500 },
            @{ Name = 'tab-bar-never'; Extra = 'window-show-tab-bar = never'; Keys = @(); Top = 0; Wait = 1500 },
            @{ Name = 'decoration-none'; Extra = 'window-decoration = none'; Keys = @(); Top = 48; Wait = 1500 },
            @{ Name = 'padding-40'; Extra = "window-padding-x = 40`nwindow-padding-y = 40"; Keys = @(); Top = 60; Wait = 1500 },
            @{ Name = 'split-right'; Extra = 'keybind = f8=new_split:right'; Keys = @(119); Top = 60; Wait = 5000 },
            @{ Name = 'split-down'; Extra = 'keybind = f8=new_split:down'; Keys = @(119); Top = 60; Wait = 5000 },
            @{ Name = 'search-open'; Extra = 'keybind = f7=start_search'; Keys = @(118); Top = 60; Wait = 2500 },
            @{ Name = 'inspector'; Extra = 'keybind = f6=inspector:toggle'; Keys = @(117); Top = 123; Wait = 2500 }
        )
        foreach ($case in $cases) {
            $c = Start-Case "layout-$($case.Name)" $sides[$first] $case.Extra
            try {
                [void](Wait-FirstSwap $c); Start-Sleep -Seconds 2
                $h = @([Hd]::Hosts($c.Proc.Id))[0]; $s = [Hd]::Surface($h)
                foreach ($k in $case.Keys) { [Hd]::Key($s, $k); Start-Sleep -Milliseconds $case.Wait }
                [Hd]::Key($s, 120)   # F9 -> "Nothing to undo."
                for ($t = 0; $t -lt 40 -and -not [Hd]::ChildVisible($h, 1913); $t++) { Start-Sleep -Milliseconds 50 }
                Start-Sleep -Milliseconds 800
                $layouts.Add([pscustomobject]@{ Case = $case.Name; BannerChildVisible = [Hd]::ChildVisible($h, 1913); Map = [Hd]::BannerBandMap($h, [int]$case.Top) })
            } finally { Stop-Case $c }
        }
    }
    if ($Runs -gt 0 -and -not $LayoutProbe) {
    for ($i = 1; $i -le $Runs; $i++) {
        foreach ($name in $sides.Keys) {
            $c = Start-Case "$name-$i" $sides[$name] ''
            $p = $c.Proc
            try {
                $swap = Wait-FirstSwap $c
                Start-Sleep -Seconds 2
                $p.Refresh()
                $mods = @($p.Modules | ForEach-Object { $_.ModuleName } | Where-Object { $_ -match '(?i)^(d3d11|dcomp|d2d1|dwrite|dxgi|nvwgf2|nvd3|igd|ig9|amdxx|atidxx|d3d12)' } | Sort-Object -Unique)
                $starts = [Hd]::ThreadStarts($p.Id)
                $byModule = @{}
                $moduleList = @($p.Modules | ForEach-Object { @{ Name = $_.ModuleName; Lo = [int64]$_.BaseAddress; Hi = [int64]$_.BaseAddress + $_.ModuleMemorySize } })
                foreach ($a in $starts) {
                    $owner = ($moduleList | Where-Object { $a -ge $_.Lo -and $a -lt $_.Hi } | Select-Object -First 1).Name
                    if (-not $owner) { $owner = '(unknown)' }
                    $byModule[$owner] = 1 + [int]$byModule[$owner]
                }
                $threadOwners = (($byModule.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
                $threads0 = $p.Threads.Count; $priv0 = $p.PrivateMemorySize64; $ws0 = $p.WorkingSet64
                $ctx0 = Ctx-Sample $p.Id; $cpu0 = $p.TotalProcessorTime.TotalMilliseconds
                Start-Sleep -Seconds $IdleSeconds
                $ctx1 = Ctx-Sample $p.Id; $p.Refresh(); $cpu1 = $p.TotalProcessorTime.TotalMilliseconds
                $threads1 = $p.Threads.Count; $priv1 = $p.PrivateMemorySize64
                $delta = @{}; $total = [uint64]0
                foreach ($k in $ctx1.Per.Keys) { $d = [uint64]$ctx1.Per[$k] - $(if ($ctx0.Per.ContainsKey($k)) { [uint64]$ctx0.Per[$k] } else { [uint64]0 }); $delta[$k] = $d; $total += $d }
                $top = @($delta.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key):$($_.Value)" })
                $secs = $ctx1.At - $ctx0.At
                $rec = [ordered]@{
                    Side = $name; Run = $i; Pid = $p.Id
                    LaunchToFirstSwapMs = [int64]$swap.tick_ms - $c.Launch
                    PrivateBytesAtFirstSwap = [int64]$swap.private_bytes
                    ThreadsIdle = $threads0; ThreadsAfterIdle = $threads1
                    PrivateIdle = $priv0; PrivateAfterIdle = $priv1; WorkingSetIdle = $ws0
                    IdleSeconds = [math]::Round($secs, 2)
                    CtxSwitchesPerSec = [math]::Round($total / $secs, 1)
                    CpuMsPerSec = [math]::Round(($cpu1 - $cpu0) / $secs, 2)
                    TopThreadCtxDelta = ($top -join ' ')
                    GpuModules = ($mods -join ',')
                    ThreadStartModules = $threadOwners
                }
            } finally { Stop-Case $c }
            if (Test-Path -LiteralPath $c.Render) {
                try { $rec.ProcessStartToFirstSwapMs = [int64]((Get-Content -LiteralPath $c.Render -Raw | ConvertFrom-Json).process_start_to_first_swap_ms) } catch { $rec.ProcessStartToFirstSwapMs = $null }
            } else { $rec.ProcessStartToFirstSwapMs = $null }
            $results.Add([pscustomobject]$rec)
            Write-Host ("{0,-10} run {1}: first swap {2} ms, main->swap {3} ms, threads {4}, private {5:N0} MB, ctx/s {6}, cpu ms/s {7}" -f $name,$i,$rec.LaunchToFirstSwapMs,$rec.ProcessStartToFirstSwapMs,$rec.ThreadsIdle,($rec.PrivateIdle/1MB),$rec.CtxSwitchesPerSec,$rec.CpuMsPerSec)
        }
    }
    }
    if ($BannerCheck) {
        foreach ($name in $sides.Keys) {
            $c = Start-Case "$name-banner" $sides[$name] ''
            try {
                [void](Wait-FirstSwap $c); Start-Sleep -Seconds 2
                $hosts = @([Hd]::Hosts($c.Proc.Id)); $h = $hosts[0]; $s = [Hd]::Surface($h)
                if ($s -eq [IntPtr]::Zero) { throw 'Terminal child absent.' }
                $rect = [Hd+Rect]::new(); [void][Hd]::GetWindowRect($s, [ref]$rect); $hr = [Hd+Rect]::new(); [void][Hd]::GetWindowRect($h, [ref]$hr)
                $surfaceTop = $rect.Top - $hr.Top
                $cs = [Hd]::ClientSize($h)
                $probeX = [int]($cs[0] / 2)
                $probes = [ordered]@{
                    TabStripY30 = [Hd]::HostPaintVisibleAt($h, $probeX, 30)
                    BannerRowY75 = [Hd]::HostPaintVisibleAt($h, $probeX, 75)
                    DeepContentY400 = [Hd]::HostPaintVisibleAt($h, $probeX, 400)
                }
                $before = @{}; $after = @{}
                foreach ($flags in @(2, 0)) { $before[$flags] = [Hd]::Capture($h, [uint32]$flags) }
                [Hd]::Key($s, 120)   # F9 -> undo -> "Nothing to undo." host banner
                $bannerVisible = $false
                for ($t = 0; $t -lt 40 -and -not $bannerVisible; $t++) { Start-Sleep -Milliseconds 50; $bannerVisible = [Hd]::ChildVisible($h, 1913) }
                Start-Sleep -Milliseconds 1000
                # Probe again with the banner up: does a banner row get its own space, or does the terminal still cover it?
                $rect2 = [Hd+Rect]::new(); [void][Hd]::GetWindowRect($s, [ref]$rect2)
                $surfaceTopAfter = $rect2.Top - $hr.Top
                $probesAfter = [ordered]@{
                    TabStripY30 = [Hd]::HostPaintVisibleAt($h, $probeX, 30)
                    BannerRowY75 = [Hd]::HostPaintVisibleAt($h, $probeX, 75)
                    DeepContentY400 = [Hd]::HostPaintVisibleAt($h, $probeX, 400)
                }
                foreach ($flags in @(2, 0)) {
                    $after[$flags] = [Hd]::Capture($h, [uint32]$flags)
                    $d = [Hd]::Diff($before[$flags], $after[$flags], 0, [Math]::Max($surfaceTop, 1))
                    [Hd]::SaveBmp($before[$flags], (Join-Path $c.Case "banner-before-flags$flags.bmp")); [Hd]::SaveBmp($after[$flags], (Join-Path $c.Case "banner-after-flags$flags.bmp"))
                    $banner.Add([pscustomobject]@{ Side = $name; BannerChildVisible = $bannerVisible; SurfaceTopAfterPx = $surfaceTopAfter; HostPaintVisibleBefore = ($probes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '; HostPaintVisibleAfter = ($probesAfter.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '; PrintWindowFlags = $flags; SurfaceTopPx = $surfaceTop; BandDiffPixels = $d[0]; DiffBox = "$($d[1]),$($d[2])-$($d[3]),$($d[4])"; WindowSize = "$($before[$flags].W)x$($before[$flags].H)" })
                }
            } finally { Stop-Case $c }
        }
    }
} finally {
    $remaining = @($script:ownedPids | Where-Object { $q = Get-Process -Id $_.Pid -ErrorAction SilentlyContinue; $q -and $q.StartTime -eq $_.Start })
    function Med($vals) { $v = @($vals | Where-Object { $null -ne $_ } | Sort-Object); if ($v.Count -eq 0) { return $null }; $m = [int][math]::Floor($v.Count / 2); if ($v.Count % 2) { return $v[$m] } else { return ($v[$m-1] + $v[$m]) / 2 } }
    $summary = foreach ($g in ($results | Group-Object Side)) {
        [pscustomobject]@{
            Side = $g.Name; Runs = $g.Count
            MedianLaunchToFirstSwapMs = Med ($g.Group.LaunchToFirstSwapMs)
            MedianMainToFirstSwapMs = Med ($g.Group.ProcessStartToFirstSwapMs)
            MedianPrivateAtFirstSwapMB = [math]::Round((Med ($g.Group.PrivateBytesAtFirstSwap)) / 1MB, 1)
            MedianPrivateIdleMB = [math]::Round((Med ($g.Group.PrivateIdle)) / 1MB, 1)
            MedianThreads = Med ($g.Group.ThreadsIdle)
            MedianCtxSwitchesPerSec = Med ($g.Group.CtxSwitchesPerSec)
            MedianCpuMsPerSec = Med ($g.Group.CpuMsPerSec)
            GpuModules = ($g.Group | ForEach-Object GpuModules | Sort-Object -Unique) -join ' | '
        }
    }
    $gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) $($_.DriverVersion)" })
    @{ Results = $results; Summary = $summary; Banner = $banner; Layouts = $layouts; Gpu = $gpu; RemainingOwnedProcesses = $remaining.Count; IdleSeconds = $IdleSeconds
       Limit = 'Hidden desktop, portable copies, LOCALAPPDATA/APPDATA redirected. Window not foreground, so unfocused pacing applies equally to every side. GetTickCount64 resolution is about 15.6 ms.' } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'results.json')
    $summary | Format-Table -AutoSize | Out-String | Write-Host
    $banner | Format-Table -AutoSize | Out-String | Write-Host
    $layouts | Format-List | Out-String | Write-Host
    if ($remaining.Count) { Write-Host "WARNING: $($remaining.Count) owned process(es) still running" }
}
