#requires -Version 7.0
<#
Portable, hidden-desktop measurement of how noctty answers an installer's
Restart Manager close (WM_QUERYENDSESSION / WM_ENDSESSION with
ENDSESSION_CLOSEAPP), the way Inno Setup asks for it: RmStartSession,
RmRegisterResources on the files Setup replaces, RmGetList, RmShutdown without
the force flag, RmEndSession. Run with -Bin <source bin directory> -Run <new
evidence directory>; -Cases picks cases (comma-separated, all by default). The
run directory must not already exist.

Cases (each its own portable copy, restoring a seeded session of two windows:
the first with two tabs, the second of them split, the second with one tab):
  idle-two-windows  nothing running: RmShutdown returns 0, noctty exits 0 and
                    the saved session still holds both windows, tabs and split.
  busy-always       confirm-close-surface = always, and
  busy-ping         `ping -t localhost` in every pane with the default
                    confirm-close-surface: RmShutdown returns
                    ERROR_FAIL_SHUTDOWN (351) at once, noctty keeps running,
                    shows no prompt, keeps the foreground where it was, and the
                    saved session is the one written at the query.
  settings-dirty    Settings open with an unsaved font size: declined, and the
                    edit is still there.
  cancel            an accepted query (sent to every window) and then
                    WM_ENDSESSION(FALSE): every window stays, the session lock
                    stays held, and a later save still writes the file. A
                    Restart Manager close then still succeeds.
  signout           WM_QUERYENDSESSION and WM_ENDSESSION(TRUE) without
                    ENDSESSION_CLOSEAPP, as a sign-out sends them: noctty saves,
                    latches (a later checkpoint writes nothing) and does not
                    quit by itself (Windows ends the process).
  restartable       registration for Setup's restart: not restartable at
                    start; after an accepted query the session owner is
                    restartable in RmGetList and GetApplicationRestartSettings
                    returns its --config-file and --class with flags 11
                    (RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT);
                    WM_ENDSESSION(FALSE) removes it; a second instance of the
                    copy (not the session owner) agrees and is not restartable.
  restartable-busy  confirm-close-surface = always: the declining owner is not
                    restartable.
  restartable-install-running
                    another noctty's in-app Install is running Setup (the
                    copy's update state names a staged installer whose file a
                    shared-read handle holds, which refuses write access as a
                    running image does): the owner agrees and is not
                    restartable; once the handle is closed, it is again, and
                    a read-only leftover installer does not stop it.
These three only list (RmGetList) and send the query and end messages
themselves; they never call RmShutdown.

Safety. Only this run's portable copies are registered with Restart Manager:
their noctty.exe and DLLs, never OpenConsole.exe (an RmUnknownApp that fails
every non-forced shutdown). Leaving it out models the registration set the
planned installer exclusion (RMCLOSE-4) produces; today Setup still registers
it. Before
RmShutdown the script checks that Restart Manager lists exactly the copy it
started (PID and start time, read fresh) and aborts otherwise. It never calls
RmShutdown with the force flag, RmRestart (which starts on the visible
desktop) or anything that copies, and never switches desktops or injects
input: keys are posted messages to this run's own windows. Every process runs
on a new private desktop inside an owned kill-on-close job, with LOCALAPPDATA
and APPDATA redirected, single instance off and a class of its own. The real
startup-attempts.json is fingerprinted, the PowerShell history guard runs and
the clipboard sequence number is compared before and after. Only exact PIDs
this script started are ended. Results hold window counts, process IDs, file
times and assertions. It exits 1 when a check fails, so it can be run against
a build that still has the problems to show what fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [string] $Cases = '',
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 900,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class Rm {
    [StructLayout(LayoutKind.Sequential)] public struct UniqueProcess { public int Pid; public uint StartLow, StartHigh; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct ProcessInfo {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string AppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string ServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmStartSession(out uint h, int flags, StringBuilder key);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmRegisterResources(uint h, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nSvc, string[] svcs);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint count, [In, Out] ProcessInfo[] info, out uint reasons);
    [DllImport("rstrtmgr.dll")] static extern int RmShutdown(uint h, uint flags, IntPtr status);
    [DllImport("rstrtmgr.dll")] public static extern int RmEndSession(uint h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern int GetApplicationRestartSettings(IntPtr process, StringBuilder cmd, ref int size, out int flags);
    // What the process registered with RegisterApplicationRestart: its
    // HRESULT (0x80070490, not found, when nothing is registered), command
    // line and flags.
    public static object[] RestartSettings(IntPtr process) {
        var cmd=new StringBuilder(1100); int size=1100, flags=0;
        int hr=GetApplicationRestartSettings(process,cmd,ref size,out flags);
        return new object[] { hr, hr==0 ? cmd.ToString() : null, flags };
    }
    public static ProcessInfo[] List(uint h, out int err) {
        uint needed=0, count=0, reasons; var list=new ProcessInfo[0];
        err=RmGetList(h,out needed,ref count,null,out reasons);
        if(err==234) { list=new ProcessInfo[needed]; count=needed; err=RmGetList(h,out needed,ref count,list,out reasons); }
        if(count<list.Length) Array.Resize(ref list,(int)count);
        return list;
    }
    public static DateTime StartTime(ProcessInfo info) {
        return DateTime.FromFileTimeUtc(((long)info.Process.StartHigh<<32)|info.Process.StartLow);
    }
    public class Sample { public long Ms; public int Hosts; public bool Alive, Prompt; public IntPtr Foreground; }
    // RmShutdown, without the force flag, on a thread of this process (so on
    // this desktop), sampling the copy's windows every 50 ms until it returns.
    public static int Shutdown(uint h, int pid, IntPtr process, List<Sample> timeline, out long elapsed) {
        int result=-1; var t=new Thread(()=> { result=RmShutdown(h,0,IntPtr.Zero); });
        var sw=System.Diagnostics.Stopwatch.StartNew(); t.Start();
        while(!t.Join(50)) timeline.Add(Take(sw.ElapsedMilliseconds,pid,process));
        elapsed=sw.ElapsedMilliseconds;
        timeline.Add(Take(elapsed,pid,process));
        return result;
    }
    public static Sample Take(long ms, int pid, IntPtr process) {
        var hosts=Windows(pid,"noctty.win32.host"); bool prompt=false;
        foreach(var host in hosts) if(PromptShown(host)) prompt=true;
        return new Sample { Ms=ms, Hosts=hosts.Length, Alive=WaitForSingleObject(process,0)==258, Prompt=prompt, Foreground=GetForegroundWindow() };
    }
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint ms);
    delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,string l);
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Windows(int pid, string cls) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)==cls) list.Add(h); return true; },IntPtr.Zero);
        return list.ToArray();
    }
    public static IntPtr Child(IntPtr parent,int id) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(parent,(c,p)=> { if(GetDlgCtrlID(c)==id) { found=c; return false; } return true; },IntPtr.Zero);
        return found;
    }
    // The close prompt's accept button (control 2003) is shown.
    public static bool PromptShown(IntPtr host) { var a=Child(host,2003); return a!=IntPtr.Zero && IsWindowVisible(a); }
    // A message sent and answered within 5 s; null when it was not.
    public static long? Send(IntPtr h,uint m,long w,long l) {
        IntPtr result;
        if(SendMessageTimeoutW(h,m,new IntPtr(w),new IntPtr(l),0x2,5000,out result)==IntPtr.Zero) return null;
        return result.ToInt64();
    }
    public static void Key(IntPtr h,int key) {
        if(!PostMessageW(h,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(h,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    public static string Text(IntPtr h) { var sb=new StringBuilder(512); SendMessageW(h,0x0D,new IntPtr(512),sb); return sb.ToString(); }
    public static void SetText(IntPtr h,string text) { SendMessageW(h,0x0C,IntPtr.Zero,text); }
}
'@
if (-not $Driver) {
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds `
        -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified `
        -DesktopPrefix 'noctty-rm-' -Label 'Hidden Restart Manager close' -PassDesktopName -GuardClipboard `
        -DriverArguments @("-Cases `"$Cases`"")
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
$script:checks=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
$results=[ordered]@{ Cases=[ordered]@{} }
$runClass='noctty-test-rm-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$closeApp=1
$Msg=@{ Close=0x10; QueryEndSession=0x11; EndSession=0x16; DisplayChange=0x7E }

# Two windows: the first with two tabs, the second of them split in two; the
# second with one tab.
function Session-Json([string]$Cwd) {
    $pane=@{ pane=@{ cwd=$Cwd } }
    $single=@{ selected_leaf=0; layout=@{ root=0; nodes=@($pane) } }
    $split=@{ selected_leaf=1; layout=@{ root=0; nodes=@(@{ split=@{ axis='horizontal'; ratio=0.5; first=1; second=2 } },$pane,$pane) } }
    $w1=@{ selected_tab=0; x=100; y=100; width=900; height=600; state='normal'; tabs=@($single,$split) }
    $w2=@{ selected_tab=0; x=300; y=200; width=900; height=600; state='normal'; tabs=@($single) }
    return (@{ schema_version=1; windows=@($w1,$w2) } | ConvertTo-Json -Depth 12 -Compress)
}
# The saved session's windows, each as the pane count of each of its tabs:
# '[1,2] [1]' is the seeded session.
function Session-Shape([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $doc=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $windows=foreach($w in @($doc.windows)) {
        $tabs=foreach($t in @($w.tabs)) { @(@($t.layout.nodes) | Where-Object { $null -ne $_.pane }).Count }
        '[' + (@($tabs) -join ',') + ']'
    }
    return (@($windows) -join ' ')
}
$seededShape='[1,2] [1]'
function Mtime([string]$Path) { if(Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).LastWriteTimeUtc } return $null }

function Start-Case([string]$Name,[string[]]$Config) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    Set-Content -LiteralPath (Join-Path $dir 'session-state.json') -Value (Session-Json $dir) -NoNewline -Encoding utf8NoBOM
    $cfg=Join-Path $dir 'case.ghostty'
    (@('command = cmd.exe /d /k','single-instance = false','window-save-state = always',
       'copy-on-select = false','clipboard-read = deny','clipboard-write = deny') + $Config) | Set-Content -LiteralPath $cfg
    $exe=Join-Path $dir 'noctty.exe'
    $pi=[HiddenLocal]::Spawn($exe,('"{0}" --config-file="{1}" --single-instance=false --class={2}' -f $exe,$cfg,$runClass),$dir,"WinSta0\$DesktopName")
    try { $p=[Diagnostics.Process]::GetProcessById($pi.pid); [void]$p.Handle }
    finally { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
    $script:processes.Add(@{ Case=$Name; Pid=$p.Id; StartTime=$p.StartTime.ToUniversalTime().ToString('o') })
    $case=@{ Name=$Name; Dir=$dir; Process=$p; State=(Join-Path $dir 'session-state.json') }
    $ok=Wait-Until {
        $ready=$false
        $ledger=Join-Path $dir 'startup-attempts.json'
        if(Test-Path -LiteralPath $ledger) {
            try { $a=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts; $ready=$a.Count -gt 0 -and $a[-1].phase -eq 'ready' } catch { }
        }
        $ready -and @([HiddenLocal]::Hosts($p.Id)).Count -ge 2
    } 30
    $hosts=@([HiddenLocal]::Hosts($p.Id))
    if(-not $ok) { Stop-Case $case; throw "Case ${Name}: the restored session did not open (hosts $($hosts.Count))." }
    foreach($h in $hosts) { if([HiddenLocal]::WindowDesktop($h) -ne $DesktopName) { Stop-Case $case; throw "Case ${Name}: a window is not on the private desktop." } }
    $case.Hosts=$hosts
    # The shells print their first prompts.
    Start-Sleep -Seconds 5
    return $case
}
# Ends the case's own process if it is still running: the exact PID, with its
# start time and image checked again first. The owned job is the backstop.
function Stop-Case($case) {
    $p=$case.Process
    if($p.HasExited) { return }
    $q=Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if(-not $q) { return }
    if($q.StartTime -ne $p.StartTime -or $q.Path -ne $p.Path) { throw 'Exact process identity changed during cleanup.' }
    $p.Kill(); [void]$p.WaitForExit(5000)
}
function Pane($h) {
    $all=@([HiddenLocal]::Surfaces($h))
    if(-not $all.Count) { throw 'Host has no pane.' }
    return $all[0]
}
# Asks Restart Manager to close the copy, as Setup does, and records what
# happens until it returns.
function Rm-Close($case) {
    $p=$case.Process
    $out=[ordered]@{}
    $key=[Text.StringBuilder]::new(64); [uint32]$h=0
    $err=[Rm]::RmStartSession([ref]$h,0,$key); if($err) { throw "RmStartSession failed: $err" }
    try {
        $files=@(Get-ChildItem -LiteralPath $case.Dir -File | Where-Object { $_.Extension -in '.exe','.dll' -and $_.Name -ne 'OpenConsole.exe' } | ForEach-Object FullName)
        $out.Registered=@($files | ForEach-Object { Split-Path -Leaf $_ })
        $err=[Rm]::RmRegisterResources($h,[uint32]$files.Count,[string[]]$files,0,[IntPtr]::Zero,0,$null); if($err) { throw "RmRegisterResources failed: $err" }
        [int]$listErr=0
        $listed=@([Rm]::List($h,[ref]$listErr))
        if($listErr) { throw "RmGetList failed: $listErr" }
        $out.Listed=@($listed | ForEach-Object { @{ Pid=$_.Process.Pid; Type=$_.ApplicationType; Restartable=$_.Restartable } })
        # Only the copy this case started, read fresh, may be closed.
        $fresh=Get-Process -Id $p.Id -ErrorAction SilentlyContinue
        $mine=$listed.Count -eq 1 -and $null -ne $fresh -and -not $p.HasExited -and $listed[0].Process.Pid -eq $p.Id -and
            $fresh.Path -eq $p.Path -and [Math]::Abs(([Rm]::StartTime($listed[0]) - $fresh.StartTime.ToUniversalTime()).TotalMilliseconds) -lt 1000
        if(-not $mine) { throw "Restart Manager lists something other than this case's copy ($(@($listed | ForEach-Object { $_.Process.Pid }) -join ',')); not shutting down." }
        $timeline=[Collections.Generic.List[Rm+Sample]]::new(); [long]$elapsed=0
        $out.ForegroundBefore=[Rm]::GetForegroundWindow().ToInt64()
        $out.Result=[Rm]::Shutdown($h,$p.Id,$p.Handle,$timeline,[ref]$elapsed)
        $out.Ms=$elapsed
        $out.PromptSeen=@($timeline | Where-Object Prompt).Count -gt 0
        $out.ForegroundChanged=@($timeline | Where-Object { $_.Foreground.ToInt64() -ne $out.ForegroundBefore }).Count -gt 0
        $changes=@(); $last=$null
        foreach($s in $timeline) { $k="$($s.Hosts)/$($s.Alive)/$($s.Prompt)"; if($k -ne $last) { $changes+=@{ Ms=$s.Ms; Hosts=$s.Hosts; Alive=$s.Alive; Prompt=$s.Prompt }; $last=$k } }
        $out.Timeline=$changes
    } finally { [void][Rm]::RmEndSession($h) }
    return $out
}
# The session lock (session-state.json.lock) is held by the copy.
function Lock-Held([string]$State) {
    try {
        $stream=[IO.File]::Open("$State.lock",[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    } catch [IO.FileNotFoundException] { return $false } catch [IO.IOException] { return $true }
    try { $stream.Lock(0,1); $stream.Unlock(0,1); return $false } catch [IO.IOException] { return $true } finally { $stream.Dispose() }
}
function Send-All($case,[uint32]$Message,[long]$W,[long]$L) {
    return @(@([HiddenLocal]::Hosts($case.Process.Id)) | ForEach-Object { [Rm]::Send($_,$Message,$W,$L) })
}
# Restart Manager's view of the copy's processes, without shutting anything
# down: each listed PID with its RmGetList bRestartable. Throws when it lists a
# process this run did not start (exact PID and start time, read fresh).
function Rm-Restartable($case,[Diagnostics.Process[]]$Ours) {
    $key=[Text.StringBuilder]::new(64); [uint32]$h=0
    $err=[Rm]::RmStartSession([ref]$h,0,$key); if($err) { throw "RmStartSession failed: $err" }
    try {
        $files=@(Get-ChildItem -LiteralPath $case.Dir -File | Where-Object { $_.Extension -in '.exe','.dll' -and $_.Name -ne 'OpenConsole.exe' } | ForEach-Object FullName)
        $err=[Rm]::RmRegisterResources($h,[uint32]$files.Count,[string[]]$files,0,[IntPtr]::Zero,0,$null); if($err) { throw "RmRegisterResources failed: $err" }
        [int]$listErr=0
        $listed=@([Rm]::List($h,[ref]$listErr))
        if($listErr) { throw "RmGetList failed: $listErr" }
        $out=@{}
        foreach($entry in $listed) {
            $p=@($Ours | Where-Object { $_.Id -eq $entry.Process.Pid })
            $fresh=Get-Process -Id $entry.Process.Pid -ErrorAction SilentlyContinue
            $mine=$p.Count -eq 1 -and $null -ne $fresh -and $fresh.Path -eq $p[0].Path -and
                [Math]::Abs(([Rm]::StartTime($entry) - $fresh.StartTime.ToUniversalTime()).TotalMilliseconds) -lt 1000
            if(-not $mine) { throw "Restart Manager lists a process this run did not start ($($entry.Process.Pid))." }
            $out[[int]$entry.Process.Pid]=$entry.Restartable
        }
        return $out
    } finally { [void][Rm]::RmEndSession($h) }
}
function Restart-Settings([Diagnostics.Process]$P) {
    $r=[Rm]::RestartSettings($P.Handle)
    return [ordered]@{ Hr=('0x{0:X8}' -f $r[0]); Line=$r[1]; Flags=$r[2] }
}
# One argument as CommandLineToArgvW reads it back (what the restart
# registration quotes).
function Quote-Arg([string]$Arg) {
    if($Arg.Length -and $Arg -notmatch '[ \t\r\n"]') { return $Arg }
    $sb=[Text.StringBuilder]::new('"'); $slashes=0
    foreach($ch in $Arg.ToCharArray()) {
        if($ch -eq '\') { $slashes++; continue }
        if($ch -eq '"') { [void]$sb.Append([char]'\',2*$slashes+1) } elseif($slashes) { [void]$sb.Append([char]'\',$slashes) }
        $slashes=0; [void]$sb.Append($ch)
    }
    if($slashes) { [void]$sb.Append([char]'\',2*$slashes) }
    return $sb.Append('"').ToString()
}
$notFound='0x80070490'

$all=@('idle-two-windows','busy-always','busy-ping','settings-dirty','cancel','signout','restartable','restartable-busy','restartable-install-running')
$selected=if($Cases) { @($Cases -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $all }
foreach($name in $selected) { if($all -notcontains $name) { throw "Unknown case $name." } }

foreach($name in $selected) {
    $r=[ordered]@{}
    switch($name) {
        'idle-two-windows' {
            $case=Start-Case $name @()
            try {
                $r.ShapeBefore=Session-Shape $case.State
                $r.Rm=Rm-Close $case
                $exited=$case.Process.WaitForExit(10000)
                $r.Exited=$exited; if($exited) { $r.ExitCode=$case.Process.ExitCode }
                $r.ShapeAfter=Session-Shape $case.State
                Check "${name}: RmShutdown succeeds" ($r.Rm.Result -eq 0) 0 $r.Rm.Result
                Check "${name}: noctty exits 0" ($exited -and $r.ExitCode -eq 0) 'exit 0' $(if($exited){$r.ExitCode}else{'running'})
                Check "${name}: no prompt" (-not $r.Rm.PromptSeen) $false $r.Rm.PromptSeen
                Check "${name}: the saved session keeps both windows, their tabs and the split" ($r.ShapeAfter -eq $seededShape) $seededShape $r.ShapeAfter
                $r.LockFreeAfter=-not (Lock-Held $case.State)
                Check "${name}: the session lock is free once it has exited" $r.LockFreeAfter $true $r.LockFreeAfter
            } finally { Stop-Case $case }
        }
        { $_ -in 'busy-always','busy-ping' } {
            $config=if($name -eq 'busy-always') { @('confirm-close-surface = always') } else { @('command = cmd.exe /d /k ping -t localhost') }
            $case=Start-Case $name $config
            try {
                $before=Mtime $case.State
                $r.Rm=Rm-Close $case
                Start-Sleep -Milliseconds 1500
                $after=Mtime $case.State
                $r.SessionRewritten=($null -ne $after -and $after -gt $before)
                $r.ShapeAfter=Session-Shape $case.State
                $r.Alive=-not $case.Process.HasExited
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                $r.PromptAfter=@(@([HiddenLocal]::Hosts($case.Process.Id)) | Where-Object { [Rm]::PromptShown($_) }).Count -gt 0
                Check "${name}: declined (ERROR_FAIL_SHUTDOWN)" ($r.Rm.Result -eq 351) 351 $r.Rm.Result
                Check "${name}: declined at once" ($r.Rm.Ms -lt 2000) '< 2000 ms' $r.Rm.Ms
                Check "${name}: noctty keeps running with both windows" ($r.Alive -and $r.Hosts -eq 2) 'alive, 2 windows' "alive=$($r.Alive), $($r.Hosts) windows"
                Check "${name}: no prompt, during or after" (-not $r.Rm.PromptSeen -and -not $r.PromptAfter) $false "$($r.Rm.PromptSeen)/$($r.PromptAfter)"
                Check "${name}: the foreground stays where it was" (-not $r.Rm.ForegroundChanged) $false $r.Rm.ForegroundChanged
                Check "${name}: the query wrote the session as it was" ($r.SessionRewritten -and $r.ShapeAfter -eq $seededShape) "rewritten, $seededShape" "$($r.SessionRewritten), $($r.ShapeAfter)"
            } finally { Stop-Case $case }
        }
        'settings-dirty' {
            $case=Start-Case $name @('keybind = f8=open_config')
            try {
                [Rm]::Key((Pane $case.Hosts[0]),0x77)
                $ok=Wait-Until { @([Rm]::Windows($case.Process.Id,'noctty.win32.settings')).Count -gt 0 -and [Rm]::Child(@([Rm]::Windows($case.Process.Id,'noctty.win32.settings'))[0],402) -ne [IntPtr]::Zero } 15
                if(-not $ok) { throw "${name}: Settings did not open." }
                $settings=@([Rm]::Windows($case.Process.Id,'noctty.win32.settings'))[0]
                $edit=[Rm]::Child($settings,402)
                $original=[Rm]::Text($edit)
                $typed=if($original -eq '17') { '18' } else { '17' }
                [Rm]::SetText($edit,$typed)
                Start-Sleep -Milliseconds 800
                $r.Rm=Rm-Close $case
                Start-Sleep -Milliseconds 800
                $r.Alive=-not $case.Process.HasExited
                $r.SettingsOpen=@([Rm]::Windows($case.Process.Id,'noctty.win32.settings')).Count -eq 1
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                $r.EditKept=$r.SettingsOpen -and ([Rm]::Text([Rm]::Child($settings,402)) -eq $typed)
                Check "${name}: declined" ($r.Rm.Result -eq 351) 351 $r.Rm.Result
                Check "${name}: declined at once" ($r.Rm.Ms -lt 2000) '< 2000 ms' $r.Rm.Ms
                Check "${name}: noctty, both windows and Settings stay open" ($r.Alive -and $r.Hosts -eq 2 -and $r.SettingsOpen) 'alive, 2 windows, Settings' "alive=$($r.Alive), $($r.Hosts) windows, Settings=$($r.SettingsOpen)"
                Check "${name}: the unsaved edit survives" $r.EditKept $typed $r.EditKept
            } finally { Stop-Case $case }
        }
        'cancel' {
            $case=Start-Case $name @()
            try {
                $r.Queries=@(Send-All $case $Msg.QueryEndSession 0 $closeApp)
                $queried=Mtime $case.State
                $r.Ends=@(Send-All $case $Msg.EndSession 0 $closeApp)
                Start-Sleep -Milliseconds 1500
                $r.Alive=-not $case.Process.HasExited
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                $r.LockHeld=Lock-Held $case.State
                # A later save: the display-change checkpoint, past its one-second throttle.
                [void](Send-All $case $Msg.DisplayChange 32 0)
                $saved=Wait-Until { $m=Mtime $case.State; $null -ne $m -and $m -gt $queried } 5
                $r.LaterSave=$saved
                Check "${name}: every window agrees to the query" (@($r.Queries | Where-Object { $_ -ne 1 }).Count -eq 0 -and $r.Queries.Count -eq 2) '1,1' ($r.Queries -join ',')
                Check "${name}: every window stays after WM_ENDSESSION(FALSE)" ($r.Alive -and $r.Hosts -eq 2) 'alive, 2 windows' "alive=$($r.Alive), $($r.Hosts) windows"
                Check "${name}: the session lock stays held" $r.LockHeld $true $r.LockHeld
                Check "${name}: later saves still write" $saved $true $saved
                # Still closes for the next request.
                $r.Rm=Rm-Close $case
                $exited=$case.Process.WaitForExit(10000)
                $r.ShapeAfter=Session-Shape $case.State
                Check "${name}: a later Restart Manager close still succeeds" ($r.Rm.Result -eq 0 -and $exited) '0, exited' "$($r.Rm.Result), exited=$exited"
                Check "${name}: and keeps the session" ($r.ShapeAfter -eq $seededShape) $seededShape $r.ShapeAfter
            } finally { Stop-Case $case }
        }
        'signout' {
            $case=Start-Case $name @()
            try {
                Start-Sleep -Milliseconds 1200
                $before=Mtime $case.State
                $r.Queries=@(Send-All $case $Msg.QueryEndSession 0 0)
                $r.Ends=@(Send-All $case $Msg.EndSession 1 0)
                $ended=Mtime $case.State
                $r.Saved=$null -ne $ended -and $ended -gt $before
                $r.ShapeAfter=Session-Shape $case.State
                Start-Sleep -Milliseconds 1500
                [void](Send-All $case $Msg.DisplayChange 32 0)
                Start-Sleep -Milliseconds 1500
                $r.LatchedAfter=(Mtime $case.State) -eq $ended
                $r.Alive=-not $case.Process.HasExited
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                Check "${name}: every window agrees" (@($r.Queries | Where-Object { $_ -ne 1 }).Count -eq 0 -and $r.Queries.Count -eq 2) '1,1' ($r.Queries -join ',')
                Check "${name}: the session is saved as it ends" ($r.Saved -and $r.ShapeAfter -eq $seededShape) "saved, $seededShape" "$($r.Saved), $($r.ShapeAfter)"
                Check "${name}: and latched: a later checkpoint writes nothing" $r.LatchedAfter $true $r.LatchedAfter
                Check "${name}: noctty does not quit by itself" ($r.Alive -and $r.Hosts -eq 2) 'alive, 2 windows' "alive=$($r.Alive), $($r.Hosts) windows"
            } finally { Stop-Case $case }
        }
        'restartable' {
            $case=Start-Case $name @()
            $second=$null
            try {
                $p=$case.Process
                $expected=(Quote-Arg ('--config-file=' + (Join-Path $case.Dir 'case.ghostty'))) + ' ' + (Quote-Arg "--class=$runClass")
                $r.AtStart=Restart-Settings $p
                $r.ListedAtStart=(Rm-Restartable $case @($p))[$p.Id]
                $r.Queries=@(Send-All $case $Msg.QueryEndSession 0 $closeApp)
                $r.Accepted=Restart-Settings $p
                $r.ListedAccepted=(Rm-Restartable $case @($p))[$p.Id]
                $r.Ends=@(Send-All $case $Msg.EndSession 0 $closeApp)
                $r.Cancelled=Restart-Settings $p
                $r.ListedCancelled=(Rm-Restartable $case @($p))[$p.Id]
                Check "${name}: not restartable at start" ($r.AtStart.Hr -eq $notFound -and $r.ListedAtStart -eq $false) "$notFound, False" "$($r.AtStart.Hr), $($r.ListedAtStart)"
                Check "${name}: every window agrees to the query" (@($r.Queries | Where-Object { $_ -ne 1 }).Count -eq 0 -and $r.Queries.Count -eq 2) '1,1' ($r.Queries -join ',')
                Check "${name}: the agreeing owner is restartable" ($r.ListedAccepted -eq $true) $true $r.ListedAccepted
                Check "${name}: with its config file and class, and flags 11" ($r.Accepted.Hr -eq '0x00000000' -and $r.Accepted.Line -ceq $expected -and $r.Accepted.Flags -eq 11) "$expected / 11" "$($r.Accepted.Hr) $($r.Accepted.Line) / $($r.Accepted.Flags)"
                Check "${name}: WM_ENDSESSION(FALSE) removes the registration" ($r.Cancelled.Hr -eq $notFound -and $r.ListedCancelled -eq $false) "$notFound, False" "$($r.Cancelled.Hr), $($r.ListedCancelled)"

                # A second instance of the same copy: the session lock is held,
                # so it is not the owner and opens a window of its own.
                $exe=Join-Path $case.Dir 'noctty.exe'
                $cfg=Join-Path $case.Dir 'case.ghostty'
                $pi=[HiddenLocal]::Spawn($exe,('"{0}" --config-file="{1}" --single-instance=false --class={2}' -f $exe,$cfg,$runClass),$case.Dir,"WinSta0\$DesktopName")
                try { $second=[Diagnostics.Process]::GetProcessById($pi.pid); [void]$second.Handle }
                finally { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
                $script:processes.Add(@{ Case="$name-second"; Pid=$second.Id; StartTime=$second.StartTime.ToUniversalTime().ToString('o') })
                $secondCase=@{ Name="$name-second"; Dir=$case.Dir; Process=$second }
                if(-not (Wait-Until { @([HiddenLocal]::Hosts($second.Id)).Count -ge 1 } 30)) { throw "${name}: the second instance opened no window." }
                foreach($h in @([HiddenLocal]::Hosts($second.Id))) { if([HiddenLocal]::WindowDesktop($h) -ne $DesktopName) { throw "${name}: a second-instance window is not on the private desktop." } }
                Start-Sleep -Seconds 3
                $r.SecondQueries=@(Send-All $secondCase $Msg.QueryEndSession 0 $closeApp)
                $r.SecondAccepted=Restart-Settings $second
                $listed=Rm-Restartable $case @($p,$second)
                $r.SecondListed=$listed[$second.Id]
                $r.OwnerStillLock=Lock-Held $case.State
                [void](Send-All $secondCase $Msg.EndSession 0 $closeApp)
                Check "${name}: the second instance agrees" (@($r.SecondQueries | Where-Object { $_ -ne 1 }).Count -eq 0 -and $r.SecondQueries.Count -ge 1) '1' ($r.SecondQueries -join ',')
                Check "${name}: and is not restartable" ($r.SecondAccepted.Hr -eq $notFound -and $r.SecondListed -eq $false) "$notFound, False" "$($r.SecondAccepted.Hr), $($r.SecondListed)"
            } finally {
                if($second) { Stop-Case @{ Process=$second } }
                Stop-Case $case
            }
        }
        'restartable-busy' {
            $case=Start-Case $name @('confirm-close-surface = always')
            try {
                $p=$case.Process
                $r.Queries=@(Send-All $case $Msg.QueryEndSession 0 $closeApp)
                $r.Declined=Restart-Settings $p
                $r.Listed=(Rm-Restartable $case @($p))[$p.Id]
                [void](Send-All $case $Msg.EndSession 0 $closeApp)
                Check "${name}: declined" (@($r.Queries | Where-Object { $_ -ne 0 }).Count -eq 0 -and $r.Queries.Count -eq 2) '0,0' ($r.Queries -join ',')
                Check "${name}: and not restartable" ($r.Declined.Hr -eq $notFound -and $r.Listed -eq $false) "$notFound, False" "$($r.Declined.Hr), $($r.Listed)"
            } finally { Stop-Case $case }
        }
        'restartable-install-running' {
            # No update check may rewrite the state the case writes.
            $case=Start-Case $name @('auto-update = off')
            $held=$null
            try {
                $p=$case.Process
                $setup=Join-Path $Run "$name\staged-setup.exe"
                Set-Content -LiteralPath $setup -Value 'not a program' -NoNewline
                $state=[ordered]@{ staged_version='1.3.999'; staged_kind='installer'; staged_installer_path=$setup; staged_sha256='00' } | ConvertTo-Json -Compress
                Set-Content -LiteralPath (Join-Path $case.Dir 'update-state.json') -Value $state -NoNewline -Encoding utf8NoBOM
                $held=[IO.File]::Open($setup,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                $r.Queries=@(Send-All $case $Msg.QueryEndSession 0 $closeApp)
                $r.Running=Restart-Settings $p
                $r.ListedRunning=(Rm-Restartable $case @($p))[$p.Id]
                [void](Send-All $case $Msg.EndSession 0 $closeApp)
                $held.Dispose(); $held=$null
                # Setup has exited: the same owner registers again.
                $r.QueriesAfter=@(Send-All $case $Msg.QueryEndSession 0 $closeApp)
                $r.After=Restart-Settings $p
                $r.ListedAfter=(Rm-Restartable $case @($p))[$p.Id]
                [void](Send-All $case $Msg.EndSession 0 $closeApp)
                # A read-only leftover also refuses write access, but no Setup
                # runs from it: an unrelated upgrade still restarts the owner.
                (Get-Item -LiteralPath $setup).IsReadOnly=$true
                $r.QueriesReadOnly=@(Send-All $case $Msg.QueryEndSession 0 $closeApp)
                $r.ReadOnly=Restart-Settings $p
                $r.ListedReadOnly=(Rm-Restartable $case @($p))[$p.Id]
                [void](Send-All $case $Msg.EndSession 0 $closeApp)
                (Get-Item -LiteralPath $setup).IsReadOnly=$false
                Check "${name}: every window agrees" (@($r.Queries | Where-Object { $_ -ne 1 }).Count -eq 0 -and $r.Queries.Count -eq 2) '1,1' ($r.Queries -join ',')
                Check "${name}: and the owner is not restartable while that Setup runs" ($r.Running.Hr -eq $notFound -and $r.ListedRunning -eq $false) "$notFound, False" "$($r.Running.Hr), $($r.ListedRunning)"
                Check "${name}: once it has exited, the owner is restartable again" ($r.After.Hr -eq '0x00000000' -and $r.After.Flags -eq 11 -and $r.ListedAfter -eq $true) '0x00000000 / 11, True' "$($r.After.Hr) / $($r.After.Flags), $($r.ListedAfter)"
                Check "${name}: a read-only leftover installer does not stop the restart" ($r.ReadOnly.Hr -eq '0x00000000' -and $r.ReadOnly.Flags -eq 11 -and $r.ListedReadOnly -eq $true) '0x00000000 / 11, True' "$($r.ReadOnly.Hr) / $($r.ReadOnly.Flags), $($r.ListedReadOnly)"
            } finally {
                if($held) { $held.Dispose() }
                if(Test-Path -LiteralPath $setup) { (Get-Item -LiteralPath $setup).IsReadOnly=$false }
                Stop-Case $case
            }
        }
    }
    $results.Cases[$name]=$r
}

$results.Processes=$script:processes
$results.Checks=$script:checks
$results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Run 'restart-manager-results.json')
$failed=@($script:checks | Where-Object { -not $_.Passed })
foreach($c in $script:checks) { Write-Host ("{0} {1} (expected {2}, actual {3})" -f $(if($c.Passed){'PASS'}else{'FAIL'}),$c.Name,$c.Expected,$c.Actual) }
if($failed.Count) { exit 1 }
exit 0
