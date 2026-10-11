#requires -Version 7.0
<#
G019 attribution: does herdr react to mouse clicks under noctty, and under
WezTerm as the comparison terminal? Supply a built Bin and a NEW Run directory.
Copies noctty into Run with noctty.portable; redirects HOME, USERPROFILE,
APPDATA and LOCALAPPDATA for every child (noctty, WezTerm, herdr), so herdr's
config, state and API socket live in Run and the maintainer's herdr server is
never touched. Everything runs on a private desktop; input is posted mouse
messages only. Skips WezTerm or herdr phases when they are not installed.

For each terminal and each herdr mode (default server/client, --no-session):
start herdr, wait for its API, read its console input mode and buffer geometry
(console-attach-info.c), split the pane, click into the right pane, and ask
herdr which pane is current. Then run the console observer
(console-input-records.c) in the same terminal in herdr's input mode (0x98,
no ENABLE_VIRTUAL_TERMINAL_INPUT) and with it (0x298) and record the
MOUSE/KEY records the same clicks produce. results.json holds everything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $Herdr = "$env:LOCALAPPDATA\Programs\Herdr\bin\herdr.exe",
    [string] $WezTerm = "$env:ProgramFiles\WezTerm\wezterm-gui.exe",
    [ValidatePattern('^[a-fA-F0-9]{64}$')] [string] $BaselineHash,
    [ValidateRange(60,900)] [int] $DriverTimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class HerdrMouse {
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
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string name,uint access,uint share,ref SecurityAttributes sa,uint disposition,uint flags,IntPtr template);
    // Runs a console program with no console of its own (CREATE_NO_WINDOW: a
    // headless conhost, which never goes through default-terminal delegation),
    // with stdout and stderr in outFile. A console program started from a
    // console-less driver would otherwise get a new console window, and on a
    // machine whose default terminal is delegated that allocation hands off.
    public static int RunCapture(string app,string command,string cwd,string outFile,IntPtr job,int timeoutMs) {
        var sa=new SecurityAttributes { length=Marshal.SizeOf<SecurityAttributes>(),inherit=1 };
        var file=CreateFileW(outFile,0x40000000,3,ref sa,2,0x80,IntPtr.Zero);
        if(file==new IntPtr(-1)) throw new Exception("Capture file failed: "+Marshal.GetLastWin32Error());
        try {
            var s=new Startup { cb=Marshal.SizeOf<Startup>(),flags=0x101,show=0,output=file,error=file,input=IntPtr.Zero }; ProcessInfo p;
            if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,true,0x08004004,IntPtr.Zero,cwd,ref s,out p))
                throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
            try {
                if(!AssignProcessToJobObject(job,p.process)||ResumeThread(p.thread)==0xFFFFFFFF) { TerminateProcess(p.process,1); throw new Exception("Capture launch assignment/resume failed"); }
                if(WaitForSingleObject(p.process,(uint)timeoutMs)!=0) { TerminateProcess(p.process,1); return -1; }
                uint code; GetExitCodeProcess(p.process,out code); return (int)code;
            } finally { CloseHandle(p.thread); CloseHandle(p.process); }
        } finally { CloseHandle(file); }
    }
    public delegate bool EnumWindow(IntPtr h,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder value,int length,out int needed);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow c,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumWindow c,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out Rect r);
    [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint t,out IntPtr result);
    // Tell a window it is active and focused, as a click on it would, without
    // touching the real foreground: WM_ACTIVATE(WA_ACTIVE) then WM_SETFOCUS.
    public static void Activate(IntPtr h) {
        IntPtr r; SendMessageTimeoutW(h,0x6,new IntPtr(1),IntPtr.Zero,2,2000,out r); SendMessageTimeoutW(h,0x7,IntPtr.Zero,IntPtr.Zero,2,2000,out r);
    }
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
    // show is the STARTUPINFO wShowWindow: SW_HIDE (0) for console and noctty
    // children, SW_SHOWNOACTIVATE (4) for WezTerm, which honours the startup
    // show state and keeps a hidden window's clicks from reaching its panes.
    // Every window lives on the private desktop either way.
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job,uint flags,short show) {
        var s=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=show }; ProcessInfo p;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags|0x4004,IntPtr.Zero,cwd,ref s,out p))
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
    // The visible top-level window of pid with class cls. WezTerm gives every
    // window it creates the --class name, dialogs and helpers included, so the
    // candidates are listed and the visible one with a real client area wins.
    public static IntPtr TopLevel(int pid,string cls) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)==cls && IsWindowVisible(h)) { Rect r; GetClientRect(h,out r); if(r.right-r.left>200 && r.bottom-r.top>100) found=h; }
            return found==IntPtr.Zero; },IntPtr.Zero); return found;
    }
    public static string Windows(int pid) {
        var sb=new StringBuilder();
        EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id); if(id==pid) { Rect r; GetClientRect(h,out r); sb.AppendFormat("{0:X}:{1}:{2}:{3}x{4} ",h.ToInt64(),Class(h),IsWindowVisible(h),r.right-r.left,r.bottom-r.top); } return true; },IntPtr.Zero);
        return sb.ToString();
    }
    public static string DesktopName() {
        var name=new StringBuilder(256); int needed;
        if(!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),2,name,name.Capacity*2,out needed)) throw new Exception("Driver desktop identity unavailable");
        return name.ToString();
    }
    static void Post(IntPtr h,uint m,long w,long l) { if(!PostMessageW(h,m,new IntPtr(w),new IntPtr(l))) throw new Exception("Mouse post failed"); }
    // A left click at client (x,y): move, press, release, as the window would see it.
    public static void Click(IntPtr h,int x,int y) {
        long l=((long)(y&0xFFFF)<<16)|(uint)(x&0xFFFF);
        Post(h,0x200,0,l); Thread.Sleep(40); Post(h,0x201,1,l); Thread.Sleep(60); Post(h,0x202,0,l);
    }
}
'@
function Startup-Fingerprint {
    $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if(-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false; Hash=$null; Modified=$null } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function Compile-Helper([string]$Source,[string]$Exe,[IntPtr]$Job,[string]$Root) {
    $compile=Join-Path $Run ((Split-Path -Leaf $Source)+'.cmd')
    @('@echo off',('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" > "{4}" 2>&1' -f
        (Join-Path $Root 'scripts\dev-windows.cmd'),$Source,$Exe,($Exe -replace '\.exe$','.obj'),($Exe -replace '\.exe$','.compile.log')),
        'exit /b %errorlevel%') | Set-Content -LiteralPath $compile -Encoding ascii
    $cp=[HerdrMouse]::Launch($env:ComSpec,('"{0}" /d /c ""{1}""' -f $env:ComSpec,$compile),$Root,$null,$Job,0x08000000,0)
    try {
        if([HerdrMouse]::WaitForSingleObject($cp.process,90000) -ne 0) { throw "Compilation timed out: $Source" }
        [uint32]$code=0; [void][HerdrMouse]::GetExitCodeProcess($cp.process,[ref]$code)
        if($code -ne 0 -or -not (Test-Path -LiteralPath $Exe)) { throw "Compilation failed ($code): $Source" }
    } finally { [void][HerdrMouse]::CloseHandle($cp.thread); [void][HerdrMouse]::CloseHandle($cp.process) }
}
if(-not $Driver) {
    $Bin=(Resolve-Path -LiteralPath $Bin).Path; $Run=[IO.Path]::GetFullPath($Run)
    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $compileJob=[HerdrMouse]::CreateOwnedJob()
    try {
        Compile-Helper (Join-Path $PSScriptRoot 'console-input-records.c') (Join-Path $Run 'console-input-records.exe') $compileJob $root
        Compile-Helper (Join-Path $PSScriptRoot 'console-attach-info.c') (Join-Path $Run 'console-attach-info.exe') $compileJob $root
    } finally { [void][HerdrMouse]::StopOwnedJob($compileJob) }
    $before=Startup-Fingerprint
    if($BaselineHash -and $before.Hash -ne $BaselineHash.ToLowerInvariant()) { throw 'Real startup state differs from the adopted baseline; stop launches.' }
    $portable=Join-Path $Run 'source\bin'; [void](New-Item -ItemType Directory -Path $portable)
    Get-ChildItem -LiteralPath $Bin -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'source\share') -Recurse }
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    foreach($dir in @('home','localappdata','appdata','tmp')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
    $desktopName='noctty-herdr-'+[guid]::NewGuid().ToString('N')
    $desktop=[HerdrMouse]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $saved=@{}; foreach($v in @('LOCALAPPDATA','APPDATA','HOME','USERPROFILE','TEMP','TMP','HERDR_SOCKET_PATH','WEZTERM_CONFIG_FILE','HERDR_WINDOWS_INPUT_TRACE')) { $saved[$v]=[Environment]::GetEnvironmentVariable($v) }
    $job=[IntPtr]::Zero; $pi=$null; $code=1
    try {
        $job=[HerdrMouse]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $env:HOME=Join-Path $Run 'home'; $env:USERPROFILE=Join-Path $Run 'home'; $env:TEMP=Join-Path $Run 'tmp'; $env:TMP=Join-Path $Run 'tmp'
        $env:HERDR_WINDOWS_INPUT_TRACE='1'
        $pwsh=(Get-Command pwsh.exe).Source
        $command='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Herdr "{4}" -WezTerm "{5}" -Driver' -f $pwsh,$PSCommandPath,$portable,$Run,$Herdr,$WezTerm
        $pi=[HerdrMouse]::Launch($pwsh,$command,$Run,"WinSta0\$desktopName",$job,0x08000000,0)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while([HerdrMouse]::WaitForSingleObject($pi.process,500) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw 'Hidden driver timeout; owned job will be stopped.' }
        }
        [uint32]$code=0; [void][HerdrMouse]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        foreach($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v,$saved[$v]) }
        $cleanupError=$null; $owned=0
        if($job -ne [IntPtr]::Zero) { try { $owned=[HerdrMouse]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][HerdrMouse]::CloseHandle($pi.thread); [void][HerdrMouse]::CloseHandle($pi.process) }
        [void][HerdrMouse]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        @{Before=$before;After=$after;Unchanged=$unchanged;OwnedJobCleanedUp=($null -eq $cleanupError);OwnedProcessCount=$owned} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if(-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "herdr mouse driver failed ($code); inspect results.json in Run." }
    Write-Host 'herdr mouse harness completed; inspect results.json.'; exit
}

# Driver: on the private desktop with sandboxed profile directories.
$driverDesktop=[HerdrMouse]::DesktopName()
if(-not $driverDesktop.StartsWith('noctty-herdr-',[StringComparison]::Ordinal)) { throw 'Driver is not on the task private desktop.' }
if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable'))) { throw 'Driver requires portable marker.' }
foreach($dir in @('LOCALAPPDATA','APPDATA','HOME','USERPROFILE')) {
    $value=[Environment]::GetEnvironmentVariable($dir)
    if(-not $value -or -not [IO.Path]::GetFullPath($value).StartsWith($Run.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Driver $dir isolation failed." }
}
$results=[ordered]@{Phases=[Collections.Generic.List[object]]::new()}
$runStart=Get-Date
# Every process this run launched or found under one it launched.
$knownPids=[Collections.Generic.HashSet[int]]::new()
$job=[HerdrMouse]::CreateOwnedJob()
$observer=Join-Path $Run 'console-input-records.exe'; $attachInfo=Join-Path $Run 'console-attach-info.exe'
$herdrConfigDir=Join-Path $env:APPDATA 'herdr'; [void](New-Item -ItemType Directory -Path $herdrConfigDir -Force)
@('onboarding = false','[terminal]','default_shell = "cmd.exe"','[update]','version_check = false','manifest_check = false',
  '[ui]','mouse_capture = true','[ui.toast]','delivery = "off"','[ui.sound]','enabled = false') |
    Set-Content -LiteralPath (Join-Path $herdrConfigDir 'config.toml')
$nocttyConfig=Join-Path $Bin 'herdr-mouse.ghostty'
@('shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false','keybind = clear','window-width = 160','window-height = 40') |
    Set-Content -LiteralPath $nocttyConfig
$wezConfig=Join-Path $Run 'wezterm.lua'
@("local wezterm = require 'wezterm'","return {","  check_for_updates = false,","  front_end = 'Software',","  initial_cols = 160,","  initial_rows = 40,",
  "  automatically_reload_config = false,","  window_close_confirmation = 'NeverPrompt',","  default_prog = { 'cmd.exe' },","  show_update_window = false,","}") |
    Set-Content -LiteralPath $wezConfig
$env:WEZTERM_CONFIG_FILE=$wezConfig
$nocttyExe=Join-Path $Bin 'noctty.exe'
$haveHerdr=Test-Path -LiteralPath $Herdr; $haveWezTerm=Test-Path -LiteralPath $WezTerm
$script:apiCalls=0
function Progress([string]$Text) { Add-Content -LiteralPath (Join-Path $Run 'progress.log') -Value ("{0} {1}" -f (Get-Date).ToString('HH:mm:ss.fff'),$Text) }
# The parameter must not be called $Args: that name is PowerShell's automatic
# unbound-arguments variable and binds nothing (AGENTS.md, 2026-09-14).
function Herdr-Api([string[]]$Arguments,[string]$Socket) {
    $old=$env:HERDR_SOCKET_PATH; $env:HERDR_SOCKET_PATH=$Socket
    $script:apiCalls++; $out=Join-Path $Run ("api-{0:D3}.txt" -f $script:apiCalls)
    try {
        $code=[HerdrMouse]::RunCapture($Herdr,('"{0}" {1}' -f $Herdr,($Arguments -join ' ')),$Run,$out,$job,15000)
        $raw=if(Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { $null }
        $text=if($null -eq $raw) { '' } else { ([string]$raw).TrimEnd() }
        $flat=[string]($text -replace '\s+',' ')
        Progress ("api {0} -> {1}: {2}" -f ($Arguments -join ' '),$code,$flat.Substring(0,[Math]::Min(300,$flat.Length)))
        return @{Exit=$code;Text=$text}
    } finally { $env:HERDR_SOCKET_PATH=$old }
}
function Wait-Window([scriptblock]$Find,[IntPtr]$Process,[int]$Seconds,[string]$What) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do { $h=& $Find; if($h -ne [IntPtr]::Zero) { return $h }
        if([HerdrMouse]::WaitForSingleObject($Process,0) -eq 0) { throw "$What exited before its window appeared." }
        Start-Sleep -Milliseconds 100 } while([datetime]::UtcNow -lt $deadline)
    throw "$What window did not appear."
}
function Child-Pids([int]$Parent,[string]$Name) {
    return @(Get-CimInstance Win32_Process -Filter "Name='$Name'" | Where-Object { $_.ParentProcessId -eq $Parent } | Select-Object -ExpandProperty ProcessId)
}
function Attach-Info([int]$ProcessId) {
    $out=Join-Path $Run ("attach-{0}.txt" -f $ProcessId)
    $p=[HerdrMouse]::Launch($attachInfo,('"{0}" {1} "{2}"' -f $attachInfo,$ProcessId,$out),$Run,"WinSta0\$driverDesktop",$job,0x08000000,0)
    try {
        if([HerdrMouse]::WaitForSingleObject($p.process,10000) -ne 0) { return @{Error='attach timeout'} }
        [uint32]$code=0; [void][HerdrMouse]::GetExitCodeProcess($p.process,[ref]$code)
        if($code -ne 0) { return @{Error="attach exit $code"} }
        $f=(Get-Content -LiteralPath $out -Raw).Trim().Split(',')
        return @{InputMode=[int]$f[0];InputModeHex=('0x{0:X}' -f [int]$f[0]);BufferWidth=[int]$f[1];BufferHeight=[int]$f[2];Window=@([int]$f[3],[int]$f[4],[int]$f[5],[int]$f[6]);OutputMode=[int]$f[7]}
    } finally { [void][HerdrMouse]::CloseHandle($p.thread); [void][HerdrMouse]::CloseHandle($p.process) }
}
# Launch `program args` inside a terminal; returns process info and the window to click.
function Start-Terminal([string]$Terminal,[string]$Program,[string]$Arguments) {
    if($Terminal -eq 'noctty') {
        $cmd='"{0}" --config-file="{1}" -e "{2}" {3}' -f $nocttyExe,$nocttyConfig,$Program,$Arguments
        $p=[HerdrMouse]::Launch($nocttyExe,$cmd,$Bin,"WinSta0\$driverDesktop",$job,0x08000000,0)
        $w=Wait-Window { [HerdrMouse]::Surface($p.pid) } $p.process 45 'noctty'
        return @{Process=$p;Window=$w;Pid=$p.pid}
    }
    $cls='noctty-g019-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $cmd='"{0}" --config-file "{1}" start --always-new-process --class {2} --cwd "{3}" -- "{4}" {5}' -f $WezTerm,$wezConfig,$cls,$Run,$Program,$Arguments
    $p=[HerdrMouse]::Launch($WezTerm,$cmd,$Run,"WinSta0\$driverDesktop",$job,0x08000000,4)
    $w=Wait-Window { [HerdrMouse]::TopLevel($p.pid,$cls) } $p.process 60 'WezTerm'
    Start-Sleep -Milliseconds 1500 # first paint on the software front end
    [HerdrMouse]::Activate($w); Start-Sleep -Milliseconds 300
    Progress ("wezterm windows: " + [HerdrMouse]::Windows($p.pid))
    return @{Process=$p;Window=$w;Pid=$p.pid}
}
function Click-Pane([IntPtr]$Window,[double]$FractionX,[double]$FractionY) {
    $r=New-Object HerdrMouse+Rect; [void][HerdrMouse]::GetClientRect($Window,[ref]$r)
    $x=[int](($r.right-$r.left)*$FractionX); $y=[int](($r.bottom-$r.top)*$FractionY)
    [HerdrMouse]::Click($Window,$x,$y); return @($x,$y)
}
function Read-Records([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)) { return @() }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream); try { $csv=$reader.ReadToEnd() } finally { $reader.Dispose() }
    $end=$csv.LastIndexOf("`n"); if($end -lt 0) { return @() }
    return @($csv.Substring(0,$end+1) | ConvertFrom-Csv | ForEach-Object { ($_.PSObject.Properties | Where-Object { $_.Value -ne '' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ' })
}
$terminals=@('noctty'); if($haveWezTerm) { $terminals+='wezterm' }
try {
    foreach($terminal in $terminals) {
        # Phase A: herdr itself, default (server+client) mode and monolithic mode.
        foreach($mode in @('default','no-session')) {
            $phase=[ordered]@{Terminal=$terminal;Program='herdr';Mode=$mode;Status='SKIPPED'}
            if(-not $haveHerdr) { $results.Phases.Add($phase); continue }
            $socket=Join-Path $Run ("herdr-{0}-{1}.sock" -f $terminal,$mode)
            $env:HERDR_SOCKET_PATH=$socket
            $t=$null
            try {
                $arguments=if($mode -eq 'no-session') { '--no-session' } else { '' }
                Progress "phase $terminal herdr ${mode}: start"
                $t=Start-Terminal $terminal $Herdr $arguments
                Progress "phase $terminal herdr ${mode}: terminal pid $($t.Pid) window $($t.Window)"
                $deadline=[datetime]::UtcNow.AddSeconds(45); $api=$null
                do { $api=Herdr-Api @('pane','list') $socket; if($api.Exit -eq 0) { break }; Start-Sleep -Milliseconds 300 } while([datetime]::UtcNow -lt $deadline)
                $phase.ApiReady=($api.Exit -eq 0); $phase.PaneListInitial=$api.Text
                if($api.Exit -ne 0) { $phase.Status='FAIL'; $phase.Error='herdr API never answered'; $results.Phases.Add($phase); continue }
                Start-Sleep -Milliseconds 1500
                $herdrPids=@(Child-Pids $t.Pid 'herdr.exe'); Progress "herdr client pids: $($herdrPids -join ',')"
                [void]$knownPids.Add([int]$t.Pid); foreach($hp in $herdrPids) { [void]$knownPids.Add([int]$hp) }
                foreach($hp in $herdrPids) { foreach($sp in @(Child-Pids $hp 'herdr.exe')) { [void]$knownPids.Add([int]$sp) } }
                if($terminal -eq 'wezterm' -and $herdrPids.Count -eq 0) {
                    # WezTerm may spawn through its own conpty host; take any herdr whose parent is a child of the GUI.
                    $kids=@(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $t.Pid } | Select-Object -ExpandProperty ProcessId)
                    $herdrPids=@(Get-CimInstance Win32_Process -Filter "Name='herdr.exe'" | Where-Object { $kids -contains $_.ParentProcessId } | Select-Object -ExpandProperty ProcessId)
                }
                $phase.HerdrClientPid=$herdrPids
                if($herdrPids.Count -gt 0) { $phase.Console=Attach-Info $herdrPids[0] }
                # The split target is the current pane's id from the API (there is no
                # HERDR_PANE_ID in this driver's environment).
                $paneId=$null
                try { $paneId=((ConvertFrom-Json $api.Text).result.panes | Where-Object { $_.focused } | Select-Object -First 1).pane_id } catch { }
                if(-not $paneId) { $paneId='w1:p1' }
                $split=Herdr-Api @('pane','split','--pane',$paneId,'--direction','right') $socket; $phase.Split=$split.Text
                Start-Sleep -Milliseconds 1200
                $phase.PaneListAfterSplit=(Herdr-Api @('pane','list') $socket).Text
                $phase.CurrentBefore=(Herdr-Api @('pane','current') $socket).Text
                $phase.ClickRight=Click-Pane $t.Window 0.85 0.55
                Start-Sleep -Milliseconds 800
                $phase.CurrentAfterRightClick=(Herdr-Api @('pane','current') $socket).Text
                $phase.ClickLeft=Click-Pane $t.Window 0.45 0.55
                Start-Sleep -Milliseconds 800
                $phase.CurrentAfterLeftClick=(Herdr-Api @('pane','current') $socket).Text
                if($herdrPids.Count -gt 0) { $phase.ConsoleAfter=Attach-Info $herdrPids[0] }
                $phase.Status=$(if($phase.CurrentAfterRightClick -ne $phase.CurrentBefore -and $phase.CurrentAfterLeftClick -ne $phase.CurrentAfterRightClick){'CLICKS-CHANGE-FOCUS'}else{'CLICKS-IGNORED'})
                foreach($log in @('herdr.log','herdr-client.log','herdr-server.log')) {
                    $lp=Join-Path $herdrConfigDir $log
                    if(Test-Path -LiteralPath $lp) { Copy-Item -LiteralPath $lp -Destination (Join-Path $Run ("{0}-{1}-{2}" -f $terminal,$mode,$log)) -Force }
                }
                if($mode -eq 'default') { [void](Herdr-Api @('server','stop') $socket); Start-Sleep -Milliseconds 800 }
                Progress "phase $terminal herdr ${mode}: $($phase.Status)"
            } catch { $phase.Status='FAIL'; $phase.Error=$_.Exception.Message; $phase.ErrorAt=$_.InvocationInfo.PositionMessage }
            finally {
                if($t) { [void][HerdrMouse]::CloseHandle($t.Process.thread); [void][HerdrMouse]::CloseHandle($t.Process.process) }
                # Each herdr instance ends with its terminal; the job stops leftovers at exit.
                Start-Sleep -Milliseconds 500
            }
            $results.Phases.Add($phase)
        }
        # Phase B: the observer in herdr's console input mode and with VT input,
        # then in herdr's mode but asking for SGR mouse itself: the positive
        # control that tells a terminal not receiving the clicks from a console
        # host that does not translate ENABLE_MOUSE_INPUT into a mouse request.
        foreach($variant in @(@{Mode='98';Vt=$false},@{Mode='298';Vt=$false},@{Mode='98';Vt=$true})) {
            $modeHex=$variant.Mode; $tag=$modeHex+$(if($variant.Vt){'-vtmouse'}else{''})
            $phase=[ordered]@{Terminal=$terminal;Program='observer';InputMode="0x$modeHex";VtMouseRequest=$variant.Vt;Status='FAIL'}
            $records=Join-Path $Run ("records-{0}-{1}.csv" -f $terminal,$tag); $ready=Join-Path $Run ("ready-{0}-{1}.txt" -f $terminal,$tag); $stop=Join-Path $Run ("stop-{0}-{1}.txt" -f $terminal,$tag)
            $t=$null
            try {
                Progress "phase $terminal observer ${tag}: start"
                $t=Start-Terminal $terminal $observer ('"{0}" "{1}" "{2}" {3}{4}' -f $records,$ready,$stop,$modeHex,$(if($variant.Vt){' vt-mouse'}else{''}))
                [void]$knownPids.Add([int]$t.Pid)
                $deadline=[datetime]::UtcNow.AddSeconds(30)
                while(-not (Test-Path -LiteralPath $ready) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
                $phase.Ready=(Get-Content -LiteralPath $ready -Raw).Trim()
                Start-Sleep -Milliseconds 800
                $phase.ClickRight=Click-Pane $t.Window 0.85 0.55
                Start-Sleep -Milliseconds 600
                $phase.ClickLeft=Click-Pane $t.Window 0.45 0.55
                Start-Sleep -Milliseconds 800
                $phase.Records=@(Read-Records $records)
                Set-Content -LiteralPath $stop -Value '' -NoNewline
                $phase.Status='DONE'
            } catch { $phase.Error=$_.Exception.Message }
            finally { if($t) { [void][HerdrMouse]::CloseHandle($t.Process.thread); [void][HerdrMouse]::CloseHandle($t.Process.process) } }
            $results.Phases.Add($phase)
        }
    }
} catch {
    $results.Infrastructure=@{Status='FAIL';Error=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage}
    Progress ("infrastructure failure: " + $_.Exception.Message)
} finally {
    $cleanupError=$null; $owned=0
    try { $owned=[HerdrMouse]::StopOwnedJob($job) } catch { $cleanupError=$_ }
    # herdr's server detaches from the client's job. Stop only a server this
    # run started: a herdr.exe whose parent chain reaches a process this run
    # launched (recorded in $knownPids), or whose command line names Run.
    # Never by name or start time: the maintainer's own herdr is out of scope.
    $leftover=@()
    $all=@(Get-CimInstance Win32_Process -Filter "Name='herdr.exe'")
    foreach($proc in $all) {
        $mine=($proc.CommandLine -and $proc.CommandLine -like "*$Run*")
        $parent=$proc.ParentProcessId; $hops=0
        while(-not $mine -and $parent -gt 0 -and $hops -lt 6) {
            if($knownPids.Contains([int]$parent)) { $mine=$true; break }
            $pp=$all | Where-Object { $_.ProcessId -eq $parent } | Select-Object -First 1
            if($null -eq $pp) { $pp=Get-CimInstance Win32_Process -Filter "ProcessId=$parent" -ErrorAction SilentlyContinue }
            if($null -eq $pp) { break }
            $parent=$pp.ParentProcessId; $hops++
        }
        if($mine) { $leftover+=$proc }
    }
    foreach($proc in $leftover) { Progress "stopping leftover herdr pid $($proc.ProcessId) started $($proc.CreationDate)"; Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
    $results.LeftoverHerdrStopped=@($leftover | ForEach-Object { $_.ProcessId })
    $results.OwnedProcessCount=$owned; $results.OwnedJobCleanedUp=($null -eq $cleanupError)
    $results.HerdrInstalled=$haveHerdr; $results.WezTermInstalled=$haveWezTerm
    $results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'results.json')
}
if($results.Contains('Infrastructure')) { exit 2 }
exit 0
