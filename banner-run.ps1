#requires -Version 7.0
<#
Hidden-desktop run of the host banner, A/B.

  pwsh -NoProfile -File banner-run.ps1 -Side base=<bin dir> -Side after=<bin dir> -Run <new dir>

Every side is a bin directory holding noctty.exe (its sibling 'share' is copied too).
Each case copies the side into its own portable folder (noctty.portable marker),
LOCALAPPDATA/APPDATA point into the run folder, and everything runs on a desktop
created for this run, never the interactive one. Per case it raises a banner and
records: banner child (control 1913) visibility, whether it is the topmost child,
its rect against the terminal surface's, PrintWindow of the banner child, whether
the banner's own GDI paint and the terminal's reach the banner rect (GetDC +
PtVisible), the UIA name, F6 focus landing, keyboard/mouse dismissal and the .info
expiry. Checks that the real startup-attempts.json and PSReadLine history are unchanged.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $Side,
    [Parameter(Mandatory)] [string] $Run,
    [string[]] $Case,
    [switch] $Driver,
    [ValidateRange(30,3600)] [int] $DriverTimeoutSeconds = 1500,
    [string] $ExpectedStartupHash = '7b4f9aa31731df822e3ec13f8381e76dc759455abbf8bb458f74e10bf5e2bb9c'
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
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    public static void ClickCentre(IntPtr target) { Rect r; GetClientRect(target, out r); Click(target, (r.Right-r.Left)/2, (r.Bottom-r.Top)/2); }
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint param, out uint value, uint ini);
    [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo { public int cbSize, flags; public IntPtr active, focus, capture, menuOwner, moveSize, caret; public Rect caretRect; }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(int tid, ref GuiThreadInfo info);
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
    public static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") list.Add(h); return true; },IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr Surface(IntPtr h) { IntPtr found=IntPtr.Zero;
        EnumChildWindows(h,(c,p)=> { if(Class(c)=="noctty.win32" && IsWindowVisible(c)) found=c; return true; },IntPtr.Zero); return found; }
    public static int SurfaceCount(IntPtr h) { int n=0;
        EnumChildWindows(h,(c,p)=> { if(Class(c)=="noctty.win32" && IsWindowVisible(c)) n++; return true; },IntPtr.Zero); return n; }
    public static IntPtr Child(IntPtr h, int id) { IntPtr found=IntPtr.Zero;
        EnumChildWindows(h,(c,p)=> { if(GetDlgCtrlID(c)==id) found=c; return true; },IntPtr.Zero); return found; }
    public static void Key(IntPtr target,int key) {
        if(!PostMessageW(target,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(target,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    public static void Click(IntPtr target,int x,int y) {
        var lp=new IntPtr((y<<16)|(x&0xFFFF));
        PostMessageW(target,0x200,IntPtr.Zero,lp);
        PostMessageW(target,0x201,new IntPtr(1),lp);
        PostMessageW(target,0x202,IntPtr.Zero,lp);
    }
    public static IntPtr Focus(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid);
        var info=new GuiThreadInfo{ cbSize=Marshal.SizeOf<GuiThreadInfo>() };
        return GetGUIThreadInfo(tid,ref info) ? info.focus : IntPtr.Zero;
    }
    public static uint MessageDuration() { uint v; return SystemParametersInfoW(0x2016,0,out v,0) ? v : 0; }
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
    [StructLayout(LayoutKind.Sequential)] public struct Pt { public int X, Y; }
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref Pt p);
    // Fraction of sampled points of a screen rect where GDI paint by window `w` reaches the screen.
    public static string Reach(IntPtr w, Rect r) {
        IntPtr dc=GetDC(w); if(dc==IntPtr.Zero) return "nodc";
        int total=0, hit=0;
        try {
            for(int y=r.Top; y<r.Bottom; y+=3) for(int x=r.Left; x<r.Right; x+=4) {
                var p=new Pt{X=x,Y=y}; ScreenToClient(w,ref p); total++; if(PtVisible(dc,p.X,p.Y)) hit++;
            }
        } finally { ReleaseDC(w,dc); }
        return hit+"/"+total;
    }
    public static string Topmost(IntPtr host) { var top=GetWindow(host,5); return top==IntPtr.Zero ? "none" : Class(top)+"#"+GetDlgCtrlID(top); }
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(uint c);
    [DllImport("user32.dll")] static extern int FillRect(IntPtr dc, ref Rect r, IntPtr b);
    [StructLayout(LayoutKind.Sequential)] struct BitmapInfoHeader { public int size,width,height; public short planes,bitCount; public int compression,sizeImage,xppm,yppm,clrUsed,clrImportant; }
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BitmapInfoHeader bi, uint usage);
    public class Shot { public int W,H; public byte[] Bgra; public bool Ok; }
    // Top-down 32bpp BGRA capture of a window through PrintWindow, over a magenta fill.
    public static Shot Capture(IntPtr w, uint flags) {
        Rect r; if(!GetWindowRect(w,out r)) throw new Exception("GetWindowRect failed");
        int cw=Math.Max(1,r.Right-r.Left), ch=Math.Max(1,r.Bottom-r.Top);
        IntPtr screen=GetDC(IntPtr.Zero); IntPtr dc=CreateCompatibleDC(screen); IntPtr bmp=CreateCompatibleBitmap(screen,cw,ch);
        IntPtr old=SelectObject(dc,bmp);
        try {
            var all=new Rect{Left=0,Top=0,Right=cw,Bottom=ch}; var brush=CreateSolidBrush(0x00FF00FF); FillRect(dc,ref all,brush); DeleteObject(brush);
            bool ok=PrintWindow(w,dc,flags);
            var bi=new BitmapInfoHeader{ size=Marshal.SizeOf<BitmapInfoHeader>(), width=cw, height=-ch, planes=1, bitCount=32 };
            var bits=new byte[cw*ch*4];
            SelectObject(dc,old); old=IntPtr.Zero;
            if(GetDIBits(dc,bmp,0,(uint)ch,bits,ref bi,0)==0) throw new Exception("GetDIBits failed");
            return new Shot{ W=cw, H=ch, Bgra=bits, Ok=ok };
        } finally { if(old!=IntPtr.Zero) SelectObject(dc,old); DeleteObject(bmp); DeleteDC(dc); ReleaseDC(IntPtr.Zero,screen); }
    }
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    // Copy a window's current pixels through its own DC, which reads what it last painted and asks it for nothing.
    public static Shot Blt(IntPtr w) {
        Rect r; if(!GetWindowRect(w,out r)) throw new Exception("GetWindowRect failed");
        int cw=Math.Max(1,r.Right-r.Left), ch=Math.Max(1,r.Bottom-r.Top);
        IntPtr src=GetDC(w); IntPtr dc=CreateCompatibleDC(src); IntPtr bmp=CreateCompatibleBitmap(src,cw,ch);
        IntPtr old=SelectObject(dc,bmp);
        try {
            bool ok=BitBlt(dc,0,0,cw,ch,src,0,0,0x00CC0020);
            var bi=new BitmapInfoHeader{ size=Marshal.SizeOf<BitmapInfoHeader>(), width=cw, height=-ch, planes=1, bitCount=32 };
            var bits=new byte[cw*ch*4];
            SelectObject(dc,old); old=IntPtr.Zero;
            if(GetDIBits(dc,bmp,0,(uint)ch,bits,ref bi,0)==0) throw new Exception("GetDIBits failed");
            return new Shot{ W=cw, H=ch, Bgra=bits, Ok=ok };
        } finally { if(old!=IntPtr.Zero) SelectObject(dc,old); DeleteObject(bmp); DeleteDC(dc); ReleaseDC(w,src); }
    }
    public static void SaveBmp(Shot s, string path) {
        using(var f=new System.IO.FileStream(path,System.IO.FileMode.Create)) using(var bw=new System.IO.BinaryWriter(f)) {
            int stride=s.W*4, size=stride*s.H;
            bw.Write((byte)'B'); bw.Write((byte)'M'); bw.Write(54+size); bw.Write(0); bw.Write(54);
            bw.Write(40); bw.Write(s.W); bw.Write(-s.H); bw.Write((short)1); bw.Write((short)32); bw.Write(0); bw.Write(size); bw.Write(2835); bw.Write(2835); bw.Write(0); bw.Write(0);
            bw.Write(s.Bgra);
        }
    }
    // Pixel statistics: untouched (magenta), distinct colours, the most common colour and how many pixels differ from it.
    public static string Stats(Shot s) { return StatsIn(s, 0, 0, s.W, s.H); }
    // Same, for the sub-rect [x0,x1) x [y0,y1) of a capture.
    public static string StatsIn(Shot s, int x0, int y0, int x1, int y1) {
        var counts=new Dictionary<int,int>(); int magenta=0, n0=0;
        x0=Math.Max(0,x0); y0=Math.Max(0,y0); x1=Math.Min(s.W,x1); y1=Math.Min(s.H,y1);
        for(int y=y0;y<y1;y++) for(int x=x0;x<x1;x++) { int i=y*s.W+x; n0++; int c=(s.Bgra[i*4+2]<<16)|(s.Bgra[i*4+1]<<8)|s.Bgra[i*4]; if(c==0xFF00FF) magenta++; int n; counts.TryGetValue(c,out n); counts[c]=n+1; }
        int bg=0, bgCount=-1; foreach(var kv in counts) if(kv.Value>bgCount) { bg=kv.Key; bgCount=kv.Value; }
        return string.Format("ok={0} {1}x{2} untouched={3} colours={4} dominant=#{5:X6} notDominant={6}", s.Ok, x1-x0, y1-y0, magenta, counts.Count, bg, n0-bgCount);
    }
}
'@

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
function Uia-Name([IntPtr]$w) {
    try {
        $e = [System.Windows.Automation.AutomationElement]::FromHandle($w)
        return "{0} '{1}' offscreen={2} focusable={3}" -f $e.Current.ControlType.ProgrammaticName, $e.Current.Name, $e.Current.IsOffscreen, $e.Current.IsKeyboardFocusable
    } catch { return "uia-error $($_.Exception.GetType().Name)" }
}
function Uia-HasInvoke([IntPtr]$w) {
    try {
        $e = [System.Windows.Automation.AutomationElement]::FromHandle($w)
        $o = $null
        return $e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$o)
    } catch { return $false }
}
function Uia-Invoke([IntPtr]$w) {
    try {
        $e = [System.Windows.Automation.AutomationElement]::FromHandle($w)
        $p = $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $p.Invoke(); return 'invoked'
    } catch { return "uia-error $($_.Exception.GetType().Name)" }
}
function Startup-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function History-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Length=(Get-Item -LiteralPath $path).Length }
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
    $before = Startup-Fingerprint; $histBefore = History-Fingerprint
    if ($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) { throw 'Real startup state differs from the adopted baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-banner-' + [guid]::NewGuid().ToString('N')
    $desktop = [Hd]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero; [uint32]$code=1
    try {
        $job=[Hd]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $sideArgs = '-Side "' + (($sides.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ',') + '"'
        $caseArgs = if ($Case) { '-Case "' + ($Case -join ',') + '"' } else { '' }
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" {2} -Run "{3}" {4} -Driver' -f $pwsh,$PSCommandPath,$sideArgs,$Run,$caseArgs
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
        $after=Startup-Fingerprint; $histAfter = History-Fingerprint
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $histUnchanged=$histBefore.Exists -eq $histAfter.Exists -and $histBefore.Hash -eq $histAfter.Hash
        @{ Before=$before; After=$after; Unchanged=$unchanged; HistoryUnchanged=$histUnchanged; OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        Write-Host ("Real startup-attempts.json unchanged: {0}; PSReadLine history unchanged: {1}" -f $unchanged, $histUnchanged)
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code." }
    Get-Content -LiteralPath (Join-Path $Run 'results.txt') | Write-Host
    exit
}

# ---- driver: runs only on the new desktop; children inherit it ----
[void][Hd]::SetThreadDpiAwarenessContext([IntPtr](-4))
$sides = Parse-Sides $Side
$out = [Collections.Generic.List[string]]::new()
$script:ownedPids = [Collections.Generic.List[object]]::new()
function Say([string]$s) { $out.Add($s); }

function Start-Case([string]$Name, [string]$Bin, [string[]]$Extra) {
    $case = Join-Path $Run $Name
    [void](New-Item -ItemType Directory -Path $case)
    $dir = Join-Path $case 'bin'
    Copy-Portable $Bin $dir
    $config = Join-Path $dir 'banner.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false','window-save-state = never',
      'confirm-close-surface = false','cursor-style-blink = false','keybind = f9=undo',
      'keybind = f10=launch_layout:does-not-exist','keybind = f7=start_search') + $Extra | Set-Content -LiteralPath $config
    $render = Join-Path $case 'render.json'
    $env:NOCTTY_RENDER_TRACE_FILE = $render; $env:NOCTTY_RENDER_TRACE_LIVE = '1'
    try {
        $p = Start-Process -FilePath (Join-Path $dir 'noctty.exe') -ArgumentList @("--config-file=`"$config`"") -WorkingDirectory $dir -PassThru
    } finally { Remove-Item Env:NOCTTY_RENDER_TRACE_FILE, Env:NOCTTY_RENDER_TRACE_LIVE -ErrorAction SilentlyContinue }
    $script:ownedPids.Add(@{ Pid=$p.Id; Start=$p.StartTime })
    $deadline = [Environment]::TickCount64 + 30000
    $h = [IntPtr]::Zero; $s = [IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 200
        $hosts = @([Hd]::Hosts($p.Id)); if ($hosts.Count) { $h = $hosts[0]; $s = [Hd]::Surface($h) }
        if ($p.HasExited) { throw "noctty exited early ($Name)" }
    } while ($s -eq [IntPtr]::Zero -and [Environment]::TickCount64 -lt $deadline)
    if ($s -eq [IntPtr]::Zero) { throw "no terminal surface ($Name)" }
    Start-Sleep -Seconds 2
    return @{ Proc=$p; Host=$h; Surface=$s; Dir=$case; Render=$render }
}
function Stop-Case($c) {
    foreach ($h in [Hd]::Hosts($c.Proc.Id)) { [void][Hd]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
    if (-not $c.Proc.WaitForExit(8000)) {
        $p = Get-Process -Id $c.Proc.Id -ErrorAction Stop
        if ($p.StartTime -eq $c.Proc.StartTime) { Stop-Process -Id $p.Id -Force } else { throw 'Exact process identity changed during cleanup.' }
    }
}
function Swaps($c) {
    [void][Hd]::PostMessageW($c.Surface, 0x8008, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 300
    for ($i = 0; $i -lt 5; $i++) {
        try { $j = Get-Content -LiteralPath $c.Render -Raw -ErrorAction Stop | ConvertFrom-Json; return "swaps=$($j.swap_buffers_count) paintRetries=$($j.paint_retry_count) paintDraws=$($j.paint_draw_count) focusChanges=$($j.surface_focus_change_count)" } catch { Start-Sleep -Milliseconds 50 }
    }
    return 'no-trace'
}
function Wait-Banner($c, [bool]$Visible, [int]$TimeoutMs = 3000) {
    $deadline = [Environment]::TickCount64 + $TimeoutMs
    do {
        $b = [Hd]::Child($c.Host, 1913)
        if ($b -ne [IntPtr]::Zero -and ([Hd]::IsWindowVisible($b) -eq $Visible)) { return $true }
        Start-Sleep -Milliseconds 50
    } while ([Environment]::TickCount64 -lt $deadline)
    return $false
}
# Colour counts of repeated PrintWindow(banner, 2) captures 150 ms apart: a
# banner that keeps repainting, or loses its text, shows up as varying counts.
function Banner-Samples($c, [int]$N) {
    $b = [Hd]::Child($c.Host, 1913); $counts = @()
    for ($i = 0; $i -lt $N; $i++) {
        $shot = if ($env:BANNER_SAMPLE_BLT) { [Hd]::Blt($b) } else { [Hd]::Capture($b, 2) }
        $stats = [Hd]::Stats($shot)
        $n = [int]($stats -replace '.*colours=(\d+).*', '$1')
        if ($n -lt 60) {
            $counts += ($stats -replace '.*(colours=\d+ dominant=#\w+ notDominant=\d+).*', '$1')
            [Hd]::SaveBmp($shot, (Join-Path $c.Dir ("sample-{0}-{1}.bmp" -f $N, $i)))
        } else { $counts += $n }
        Start-Sleep -Milliseconds 100
    }
    return ($counts -join ',')
}
function Measure-Banner($c, [string]$Label) {
    $b = [Hd]::Child($c.Host, 1913)
    $s = [Hd]::Surface($c.Host)
    $br = [Hd+Rect]::new(); [void][Hd]::GetWindowRect($b, [ref]$br)
    $sr = [Hd+Rect]::new(); [void][Hd]::GetWindowRect($s, [ref]$sr)
    $shot = [Hd]::Capture($b, 2)
    [Hd]::SaveBmp($shot, (Join-Path $c.Dir "$Label-banner-flags2.bmp"))
    $hr = [Hd+Rect]::new(); [void][Hd]::GetWindowRect($c.Host, [ref]$hr)
    $hostShots = @{}
    foreach ($flags in @(0, 2)) {
        $hostShots[$flags] = [Hd]::Capture($c.Host, [uint32]$flags)
        [Hd]::SaveBmp($hostShots[$flags], (Join-Path $c.Dir "$Label-host-flags$flags.bmp"))
    }
    Say ("  [{0}] panes={15} visible={1} topmost={2} dpi={3} banner=({4},{5})-({6},{7}) {8}x{9} surface=({10},{11})-({12},{13}) bannerTop-surfaceTop={14}" -f $Label,
        [Hd]::IsWindowVisible($b), [Hd]::Topmost($c.Host), [Hd]::GetDpiForWindow($c.Host),
        $br.Left, $br.Top, $br.Right, $br.Bottom, ($br.Right-$br.Left), ($br.Bottom-$br.Top), $sr.Left, $sr.Top, $sr.Right, $sr.Bottom, ($br.Top-$sr.Top), [Hd]::SurfaceCount($c.Host))
    Say ("      GDI reach over the banner rect: banner={0} terminal={1}" -f [Hd]::Reach($b, $br), [Hd]::Reach($s, $br))
    Say ("      PrintWindow(banner, 2): {0}" -f [Hd]::Stats($shot))
    foreach ($flags in @(0, 2)) {
        Say ("      PrintWindow(host, {0}) over the banner rect: {1}" -f $flags, [Hd]::StatsIn($hostShots[$flags], $br.Left-$hr.Left, $br.Top-$hr.Top, $br.Right-$hr.Left, $br.Bottom-$hr.Top))
    }
    Say ("      UIA: {0}" -f (Uia-Name $b))
    foreach ($id in 1914, 1915) {
        $btn = [Hd]::Child($c.Host, $id)
        if ($btn -ne [IntPtr]::Zero -and [Hd]::IsWindowVisible($btn)) {
            $r = [Hd+Rect]::new(); [void][Hd]::GetWindowRect($btn, [ref]$r)
            Say ("      button {0}: {1}x{2} UIA {3} invoke={4}" -f $id, ($r.Right-$r.Left), ($r.Bottom-$r.Top), (Uia-Name $btn), (Uia-HasInvoke $btn))
        }
    }
}

$cases = [ordered]@{
    'info' = @{ Extra=@('auto-update = off'); Key=120 }
    'error' = @{ Extra=@('auto-update = off'); Key=121 }
    'search-open' = @{ Extra=@('auto-update = off'); Key=120; Pre=@(118) }
    'tab-bar-never' = @{ Extra=@('auto-update = off','window-show-tab-bar = never'); Key=121 }
    'decoration-none' = @{ Extra=@('auto-update = off','window-decoration = none'); Key=121 }
    'padding-40' = @{ Extra=@('auto-update = off','window-padding-x = 40','window-padding-y = 40'); Key=121 }
    'update' = @{ Extra=@('auto-update = check'); Key=0 }
    'light' = @{ Extra=@('auto-update = off','window-theme = light'); Key=121 }
    'split-after-banner' = @{ Extra=@('auto-update = off','keybind = f8=new_split:down'); Key=121 }
}
$selected = if ($Case) { @($Case | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) } else { @($cases.Keys) }
Say ("SPI_GETMESSAGEDURATION = {0} s" -f [Hd]::MessageDuration())
try {
    foreach ($name in $sides.Keys) {
        foreach ($caseName in $selected) {
            $spec = $cases[$caseName]
            Say ("== {0} / {1}" -f $name, $caseName)
            $c = Start-Case "$name-$caseName" $sides[$name] $spec.Extra
            try {
                foreach ($k in @($spec.Pre)) { if ($k) { [Hd]::Key($c.Surface, $k); Start-Sleep -Milliseconds 1500 } }
                Say ("  before: topmost={0} banner visible={1}" -f [Hd]::Topmost($c.Host), [Hd]::IsWindowVisible([Hd]::Child($c.Host, 1913)))
                $raisedAt = [Environment]::TickCount64
                if ($spec.Key) { [Hd]::Key($c.Surface, $spec.Key) }
                $shown = Wait-Banner $c $true $(if ($caseName -eq 'update') { 30000 } else { 3000 })
                Say ("  banner child became visible: {0}" -f $shown)
                Start-Sleep -Milliseconds 400
                Measure-Banner $c 'raised'
                if ($name -ne 'base' -and $shown) {
                    if ($caseName -eq 'info') {
                        Say ("  terminal while the banner is up: {0}" -f (Swaps $c)); Start-Sleep -Milliseconds 1500
                        Say ("  terminal 1.5 s later:            {0}" -f (Swaps $c))
                        $gone = Wait-Banner $c $false 15000
                        Start-Sleep -Milliseconds 500
                        Say ("  terminal after the banner went:  {0}" -f (Swaps $c))
                        Say ("  .info expired: {0} after {1} ms" -f $gone, ([Environment]::TickCount64 - $raisedAt))
                        # Move to a 96-DPI monitor and raise again.
                        [void][Hd]::SetWindowPos($c.Host, [IntPtr]::Zero, 3940, 571, 1280, 800, 0x0014)
                        Start-Sleep -Milliseconds 1500
                        [Hd]::Key($c.Surface, 121)
                        [void](Wait-Banner $c $true 3000); Start-Sleep -Milliseconds 400
                        Measure-Banner $c 'moved-96dpi'
                    }
                    if ($caseName -eq 'error') {
                        Start-Sleep -Seconds 7
                        Say ("  error still up after 7 s: {0}" -f [Hd]::IsWindowVisible([Hd]::Child($c.Host, 1913)))
                        # F6 from the terminal until focus lands on the banner, then Escape.
                        $landed = $false
                        for ($i = 0; $i -lt 4 -and -not $landed; $i++) {
                            $target = [Hd]::Focus($c.Host); if ($target -eq [IntPtr]::Zero) { $target = $c.Surface }
                            [Hd]::Key($target, 117); Start-Sleep -Milliseconds 300
                            $landed = [Hd]::GetParent([Hd]::Focus($c.Host)) -eq [Hd]::Child($c.Host, 1913)
                        }
                        Say ("  F6 landed on a banner button: {0} (focus={1} #{2})" -f $landed, [Hd]::Class([Hd]::Focus($c.Host)), [Hd]::GetDlgCtrlID([Hd]::Focus($c.Host)))
                        if ($landed) {
                            Measure-Banner $c 'focused'
                            [Hd]::Key([Hd]::Focus($c.Host), 0x1B); Start-Sleep -Milliseconds 400
                            Say ("  Escape on the focused banner hid it: {0}; focus now {1}" -f (-not [Hd]::IsWindowVisible([Hd]::Child($c.Host, 1913))), [Hd]::Class([Hd]::Focus($c.Host)))
                        }
                    }
                    if ($caseName -eq 'update' -and $shown) {
                        Say ("  terminal under the notice:          {0}" -f (Swaps $c))
                        [Hd]::Key($c.Surface, 121); Start-Sleep -Milliseconds 600
                        Say ("  terminal after the banner shrank:   {0}" -f (Swaps $c))
                        Measure-Banner $c 'message-over-notice'
                        $landed = $false
                        for ($i = 0; $i -lt 4 -and -not $landed; $i++) {
                            $target = [Hd]::Focus($c.Host); if ($target -eq [IntPtr]::Zero) { $target = $c.Surface }
                            [Hd]::Key($target, 117); Start-Sleep -Milliseconds 300
                            $landed = [Hd]::GetParent([Hd]::Focus($c.Host)) -eq [Hd]::Child($c.Host, 1913)
                        }
                        Say ("  F6 landed on a banner button: {0} (#{1})" -f $landed, [Hd]::GetDlgCtrlID([Hd]::Focus($c.Host)))
                        if ($landed) {
                            [Hd]::Key([Hd]::Focus($c.Host), 0x1B); Start-Sleep -Milliseconds 500
                            Say ("  Escape closed the message; the notice is back: {0}; focus now {1}" -f [Hd]::IsWindowVisible([Hd]::Child($c.Host, 1914)), [Hd]::Class([Hd]::Focus($c.Host)))
                            Measure-Banner $c 'notice-again'
                        }
                    }
                    if ($caseName -eq 'light') {
                        $close = [Hd]::Child($c.Host, 1915)
                        Say ("  UIA Invoke on the close button: {0}" -f (Uia-Invoke $close)); Start-Sleep -Milliseconds 500
                        Say ("  ... hid the banner: {0}; focus {1}" -f (-not [Hd]::IsWindowVisible([Hd]::Child($c.Host, 1913))), [Hd]::Class([Hd]::Focus($c.Host)))
                    }
                    if ($caseName -eq 'split-after-banner') {
                        Say ("  banner samples before the split: {0}" -f (Banner-Samples $c 30))
                        [Hd]::Key($c.Surface, 119); Start-Sleep -Milliseconds 3000
                        Measure-Banner $c 'after-split'
                        Say ("  banner samples after the split:  {0}" -f (Banner-Samples $c 31))
                    }
                    if ($caseName -in @('tab-bar-never','padding-40')) {
                        $b = [Hd]::Child($c.Host, 1913)
                        Say ("  terminal before the click: {0}" -f (Swaps $c))
                        [Hd]::ClickCentre([Hd]::Child($c.Host, 1915)); Start-Sleep -Milliseconds 400
                        Say ("  terminal after the click:  {0}" -f (Swaps $c))
                        Say ("  click on the close button hid it: {0}; focus now {1}" -f (-not [Hd]::IsWindowVisible($b)), [Hd]::Class([Hd]::Focus($c.Host)))
                    }
                }
            } catch { Say ("  ERROR: {0}" -f $_) } finally { Stop-Case $c }
        }
    }
} finally {
    $remaining = @($script:ownedPids | Where-Object { $q = Get-Process -Id $_.Pid -ErrorAction SilentlyContinue; $q -and $q.StartTime -eq $_.Start })
    if ($remaining.Count) { Say "WARNING: $($remaining.Count) owned process(es) still running" }
    $out | Set-Content -LiteralPath (Join-Path $Run 'results.txt')
}
