#requires -Version 7.0
<#
Console-API legacy-key regression. Supply a built Bin and a NEW Run directory.
Copies noctty into Run with noctty.portable and redirects both AppData roots.
All noctty windows and the driver live on a private desktop. No real input,
foreground changes, clipboard access, shell inside noctty, or protocol requests.
The child uses ReadConsoleInputW mode 0x98, with no kitty/MOK requests.
-Observe records every failure and returns success (infrastructure failures still
fail). -CompileOnly validates the C/C# harness without launching noctty.
-Synchronous permits an explicit comparison using sent rather than posted keys.
Results report UTF-16 code units, virtual keys and control bits, not console text.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Observe,
    [switch] $CompileOnly,
    [switch] $Synchronous,
    [switch] $Driver,
    [ValidateRange(10,300)] [int] $DriverTimeoutSeconds = 90
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class LegacyKeys {
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
    [StructLayout(LayoutKind.Sequential)] struct Message { public IntPtr hwnd; public uint message; public UIntPtr w; public IntPtr l; public uint time; public int x,y; public uint extra; }
    public delegate bool EnumWindow(IntPtr h,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow c,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumWindow c,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a,uint b,bool attach);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool PeekMessageW(out Message m,IntPtr h,uint a,uint b,uint remove);
    [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint t,out IntPtr result);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyExW(uint code,uint type,IntPtr layout);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] static extern int GetKeyboardLayoutList(int count,[Out] IntPtr[] layouts);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr LoadKeyboardLayoutW(string id,uint flags);
    [DllImport("user32.dll")] static extern bool UnloadKeyboardLayout(IntPtr layout);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern short VkKeyScanExW(char c,IntPtr layout);
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
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job) {
        var s=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo p;
        // Suspended creation establishes ownership before any child can start.
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08004004,IntPtr.Zero,cwd,ref s,out p))
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
    static void Send(IntPtr h,uint m,int w,long l) {
        IntPtr result; if(SendMessageTimeoutW(h,m,new IntPtr(w),new IntPtr(l),2,2000,out result)==IntPtr.Zero) throw new Exception("Timed key/control message failed");
    }
    static void Post(IntPtr h,uint m,int w,long l) {
        if(!PostMessageW(h,m,new IntPtr(w),new IntPtr(l))) throw new Exception("Key post failed");
    }
    public static void Key(IntPtr h,int vk,int character,bool ctrl,bool alt,bool shift,bool synchronous) {
        int pid; uint target=GetWindowThreadProcessId(h,out pid),current=GetCurrentThreadId(); Message message;
        PeekMessageW(out message,IntPtr.Zero,0,0,0); // Give this thread an input queue.
        if(target==0 || !AttachThreadInput(current,target,true)) throw new Exception("AttachThreadInput failed");
        var saved=new byte[256]; bool captured=false;
        try {
            captured=GetKeyboardState(saved); if(!captured) throw new Exception("GetKeyboardState failed");
            var state=new byte[256]; state[vk]=0x80;
            if(ctrl) state[0x11]=state[0xA2]=0x80;
            if(alt) state[0x12]=state[0xA4]=0x80;
            if(shift) state[0x10]=state[0xA0]=0x80;
            if(!SetKeyboardState(state)) throw new Exception("SetKeyboardState failed");
            long l=1L | ((long)MapVirtualKeyExW((uint)vk,0,GetKeyboardLayout(target))<<16);
            if(alt) l|=1L<<29;
            uint down=alt?0x104u:0x100u,up=alt?0x105u:0x101u;
            if(synchronous) {
                Send(h,down,vk,l); if(character>=0) Send(h,0x102,character,l); Send(h,up,vk,l|0xC0000000L);
            } else {
                Post(h,down,vk,l); if(character>=0) Post(h,0x102,character,l); Post(h,up,vk,l|0xC0000000L);
            }
            // Keep the shared modifier state until posted messages are consumed.
            Thread.Sleep(250);
        } finally {
            bool restored=!captured || SetKeyboardState(saved);
            bool detached=AttachThreadInput(current,target,false);
            if(!restored || !detached) throw new Exception("Keyboard state restore/detach failed");
        }
    }
    public class LayoutScope { public IntPtr Old,Current; public bool NewlyLoaded; }
    // Only the hidden target thread is activated; do not broadcast a change.
    public static LayoutScope UseLayout(IntPtr h,string id) {
        int pid; uint tid=GetWindowThreadProcessId(h,out pid);
        var layouts=new IntPtr[GetKeyboardLayoutList(0,null)]; GetKeyboardLayoutList(layouts.Length,layouts);
        var scope=new LayoutScope { Old=GetKeyboardLayout(tid),Current=LoadKeyboardLayoutW(id,0x80) };
        if(scope.Current==IntPtr.Zero) return null;
        scope.NewlyLoaded=Array.IndexOf(layouts,scope.Current)<0;
        IntPtr result;
        if(SendMessageTimeoutW(h,0x50,IntPtr.Zero,scope.Current,2,2000,out result)==IntPtr.Zero || GetKeyboardLayout(tid)!=scope.Current) {
            RestoreLayout(h,scope); return null;
        }
        return scope;
    }
    public static void RestoreLayout(IntPtr h,LayoutScope scope) {
        int pid; uint tid=GetWindowThreadProcessId(h,out pid); IntPtr result;
        if(SendMessageTimeoutW(h,0x50,IntPtr.Zero,scope.Old,2,2000,out result)==IntPtr.Zero || GetKeyboardLayout(tid)!=scope.Old)
            throw new Exception("Hidden target keyboard layout restore failed");
        if(scope.NewlyLoaded && !UnloadKeyboardLayout(scope.Current)) throw new Exception("Task-loaded keyboard layout unload failed");
    }
    public static int AltNonAscii(IntPtr h,bool synchronous) {
        var scope=UseLayout(h,"00000407"); if(scope==null) return -1;
        try {
            short scan=VkKeyScanExW('\u00f6',scope.Current);
            if(scan<0 || (scan>>8)!=0) return -1;
            Key(h,scan&255,0x00f6,false,true,false,synchronous); return 0x00f6;
        } finally { RestoreLayout(h,scope); }
    }
}
'@

function Startup-Fingerprint {
    $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if(-not (Test-Path -LiteralPath $path)) { throw 'Adopted real startup-state file is missing; no launches permitted.' }
    return @{ Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function Assert-AdoptedStartup($Fingerprint) {
    if($Fingerprint.Hash -ne '7b4f9aa31731df822e3ec13f8381e76dc759455abbf8bb458f74e10bf5e2bb9c' -or
        [datetime]::Parse($Fingerprint.Modified).ToUniversalTime() -ne [datetime]::Parse('2026-10-10T18:18:34Z').ToUniversalTime()) {
        throw 'Real startup state differs from the adopted baseline; stop launches.'
    }
}
if(-not $Driver) {
    $Bin=(Resolve-Path -LiteralPath $Bin).Path; $Run=[IO.Path]::GetFullPath($Run)
    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if(-not $CompileOnly -and -not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $compile=Join-Path $Run 'compile.cmd'; $helper=Join-Path $Run 'legacy-key-records.exe'
    @('@echo off',('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" > "{4}" 2>&1' -f
        (Join-Path $root 'scripts\dev-windows.cmd'),(Join-Path $PSScriptRoot 'legacy-key-records.c'),$helper,(Join-Path $Run 'legacy-key-records.obj'),(Join-Path $Run 'compile.log')),
        'exit /b %errorlevel%') | Set-Content -LiteralPath $compile -Encoding ascii
    $compileJob=[LegacyKeys]::CreateOwnedJob(); $cp=$null
    try {
        $cp=[LegacyKeys]::Launch($env:ComSpec,('"{0}" /d /c ""{1}""' -f $env:ComSpec,$compile),$root,$null,$compileJob)
        if([LegacyKeys]::WaitForSingleObject($cp.process,60000) -ne 0) { throw 'Helper compilation timed out.' }
        [uint32]$compileCode=0; [void][LegacyKeys]::GetExitCodeProcess($cp.process,[ref]$compileCode)
        if($compileCode -ne 0 -or -not (Test-Path -LiteralPath $helper)) { throw "Helper compilation failed ($compileCode); inspect Run/compile.log." }
    } finally {
        [void][LegacyKeys]::StopOwnedJob($compileJob)
        if($cp) { [void][LegacyKeys]::CloseHandle($cp.thread); [void][LegacyKeys]::CloseHandle($cp.process) }
    }
    if($CompileOnly) { Write-Host 'Legacy key harness C/C# compilation: PASS; no noctty launches.'; exit }
    $before=Startup-Fingerprint; Assert-AdoptedStartup $before
    $portable=Join-Path $Run 'source\bin'; [void](New-Item -ItemType Directory -Path $portable)
    Get-ChildItem -LiteralPath $Bin -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'source\share') -Recurse }
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
    $desktopName='noctty-legacy-'+[guid]::NewGuid().ToString('N')
    $desktop=[LegacyKeys]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA; $job=[IntPtr]::Zero; $pi=$null; $code=1
    try {
        $job=[LegacyKeys]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $command='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver' -f $pwsh,$PSCommandPath,$portable,$Run
        if($Observe) { $command+=' -Observe' }; if($Synchronous) { $command+=' -Synchronous' }
        $pi=[LegacyKeys]::Launch($pwsh,$command,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while([LegacyKeys]::WaitForSingleObject($pi.process,500) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw 'Hidden driver timeout; owned job will be stopped.' }
        }
        [uint32]$code=0; [void][LegacyKeys]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $owned=0
        if($job -ne [IntPtr]::Zero) { try { $owned=[LegacyKeys]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][LegacyKeys]::CloseHandle($pi.thread); [void][LegacyKeys]::CloseHandle($pi.process) }
        [void][LegacyKeys]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $unchanged=$before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        @{Before=$before;After=$after;Unchanged=$unchanged;OwnedJobCleanedUp=($null -eq $cleanupError);OwnedProcessCount=$owned} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if(-not $unchanged) { throw 'Real startup state changed; stop launches.' }; Assert-AdoptedStartup $after
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Legacy key driver failed ($code); inspect results.json in Run." }
    Write-Host 'Legacy key harness completed; inspect per-case results.json.'; exit
}

# Driver: every child inherits this private desktop and sandboxed AppData.
if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable'))) { throw 'Driver requires portable marker.' }
foreach($dir in @('LOCALAPPDATA','APPDATA')) {
    $value=[Environment]::GetEnvironmentVariable($dir)
    if(-not $value -or -not [IO.Path]::GetFullPath($value).StartsWith($Run.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Driver AppData isolation failed.' }
}
$checks=[Collections.Generic.List[object]]::new(); $job=[LegacyKeys]::CreateOwnedJob(); $terminal=$null; $probe=$null; $usLayout=$null
$records=Join-Path $Run 'records.csv'; $ready=Join-Path $Run 'ready.txt'; $stop=Join-Path $Run 'stop.txt'
function Read-Records { return @(Import-Csv -LiteralPath $records | ForEach-Object { @{CodeUnit=[int]$_.CodeUnit;VirtualKey=[int]$_.VirtualKey;ControlState=[uint32]$_.ControlState} }) }
function Capture-Key([string]$Name,[int]$VK,[int]$Character,[bool]$Ctrl,[bool]$Alt,[bool]$Shift,[int[]]$Expected,[switch]$FunctionKey,[switch]$NonAscii) {
    $offset=@(Read-Records).Count
    $unsupported=$false
    if($NonAscii) { $unsupported=[LegacyKeys]::AltNonAscii($surface,$Synchronous.IsPresent) -lt 0 }
    else { [LegacyKeys]::Key($surface,$VK,$Character,$Ctrl,$Alt,$Shift,$Synchronous.IsPresent) }
    Start-Sleep -Milliseconds 450
    $all=@(Read-Records); $actual=if($all.Count -gt $offset) { @($all[$offset..($all.Count-1)]) } else { @() }
    $units=@($actual | ForEach-Object { $_.CodeUnit })
    if($FunctionKey) { $pass=@($actual | Where-Object { $_.VirtualKey -eq $VK }).Count -gt 0 -and @($actual | Where-Object { $_.CodeUnit -ne 0 }).Count -eq 0 }
    else { $pass=($units -join ',') -ceq ($Expected -join ',') }
    if($NonAscii -and -not $unsupported) { $pass=$pass -and @($actual | Where-Object { ($_.ControlState -band 3) -ne 0 }).Count -eq 1 }
    $expectation=if($FunctionKey) { @{VirtualKey=$VK;CodeUnit=0} } else { @{CodeUnits=$Expected;AltRequired=$NonAscii.IsPresent} }
    $checks.Add(@{Name=$Name;Status=$(if($unsupported){'UNSUPPORTED'}elseif($pass){'PASS'}else{'FAIL'});Expected=$expectation;Records=$actual})
}
try {
    $config=Join-Path $Bin 'legacy-keys.ghostty'
    @('shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false','keybind = clear','window-width = 80','window-height = 24') |
        Set-Content -LiteralPath $config
    $exe=Join-Path $Bin 'noctty.exe'; $helper=Join-Path $Run 'legacy-key-records.exe'
    $command='"{0}" --config-file="{1}" -e "{2}" "{3}" "{4}" "{5}"' -f $exe,$config,$helper,$records,$ready,$stop
    $terminal=[LegacyKeys]::Launch($exe,$command,$Bin,$null,$job)
    $deadline=[datetime]::UtcNow.AddSeconds(15); $surface=[IntPtr]::Zero
    do {
        $surface=[LegacyKeys]::Surface($terminal.pid)
        if($surface -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $ready)) { break }
        if([LegacyKeys]::WaitForSingleObject($terminal.process,0) -eq 0) { throw 'Noctty exited before observer ready.' }
        Start-Sleep -Milliseconds 50
    } while([datetime]::UtcNow -lt $deadline)
    if($surface -eq [IntPtr]::Zero -or -not (Test-Path -LiteralPath $ready)) { throw 'Hidden surface/observer startup timed out.' }
    $probe=(Get-Content -LiteralPath $ready -Raw).Trim().Split(',')
    if($probe.Count -ne 2 -or $probe[1] -ne '152') { throw 'Console observer input mode was not 0x98.' }
    $usLayout=[LegacyKeys]::UseLayout($surface,'00000409')
    if($null -eq $usLayout) { throw 'Hidden target US keyboard layout could not be controlled.' }
    Start-Sleep -Milliseconds 400
    Capture-Key 'Ctrl+[' 0xDB 27 $true $false $false @(27)
    Capture-Key 'Ctrl+i' 0x49 9 $true $false $false @(9)
    Capture-Key 'Ctrl+m' 0x4D 13 $true $false $false @(13)
    Capture-Key 'Shift+Enter' 13 13 $false $false $true @(13)
    Capture-Key 'Ctrl+period' 0xBE 46 $true $false $false @(46)
    Capture-Key 'Ctrl+Escape' 27 27 $true $false $false @(27)
    Capture-Key 'Shift+Escape' 27 27 $false $false $true @(27)
    Capture-Key 'Alt+nonASCII' 0 -1 $false $true $false @(246) -NonAscii
    Capture-Key 'F13' 0x7C -1 $false $false $false @() -FunctionKey
    Capture-Key 'F24' 0x87 -1 $false $false $false @() -FunctionKey
} catch {
    $checks.Add(@{Name='Infrastructure';Status='FAIL';Error=$_.Exception.Message})
} finally {
    $cleanupError=$null; $owned=0
    if($usLayout) { try { [LegacyKeys]::RestoreLayout($surface,$usLayout) } catch { $checks.Add(@{Name='Infrastructure';Status='FAIL';Error=$_.Exception.Message}) } }
    if(Test-Path -LiteralPath $ready) { Set-Content -LiteralPath $stop -Value '' -NoNewline }
    try { $owned=[LegacyKeys]::StopOwnedJob($job) } catch { $cleanupError=$_; $checks.Add(@{Name='Owned job cleanup';Status='FAIL';Error=$_.Exception.Message}) }
    if($terminal) { [void][LegacyKeys]::CloseHandle($terminal.thread); [void][LegacyKeys]::CloseHandle($terminal.process) }
    @{InputMode=152;ProtocolsRequested=@();Delivery=$(if($Synchronous){'sent triples'}else{'posted triples'});ObserverPID=$(if($probe){[int]$probe[0]}else{$null});
        TerminalPID=$(if($terminal){$terminal.pid}else{$null});OwnedProcessCount=$owned;OwnedJobCleanedUp=($null -eq $cleanupError);Checks=@($checks)} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'results.json')
}
if(@($checks | Where-Object {$_.Name -eq 'Infrastructure' -or $_.Name -eq 'Owned job cleanup'}).Count -gt 0) { exit 2 }
if(-not $Observe -and @($checks | Where-Object {$_.Status -eq 'FAIL'}).Count -gt 0) { exit 1 }
exit 0
