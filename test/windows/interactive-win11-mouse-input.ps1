#requires -Version 7.0
[CmdletBinding()]
param([string] $ExePath, [string] $RunRoot, [switch] $Worker,
      [ValidateSet('context-menu','ignore','copy')] [string] $RightClickAction = 'context-menu',
      [switch] $ObserveBaseline)
# No clipboard access, SendInput, cursor movement, or foreground changes.
# All messages target a portable instance on a newly created hidden desktop.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $ExePath) { $ExePath = Join-Path $repoRoot 'zig-out\bin\noctty.exe' }
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot ('.zig-cache\pkg26\mouse-' + [guid]::NewGuid().ToString('N')) }
function Get-Fingerprint([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $item = Get-Item -LiteralPath $Path
    return "$($item.LastWriteTimeUtc.Ticks):$($item.Length):$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)"
}

if (-not ('MouseInputNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class MouseInputNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI {
        public int cb; public string reserved, desktop, title;
        public int x,y,xsize,ysize,xchars,ychars,fill,flags;
        public short show, cbReserved; public IntPtr reserved2, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process, thread; public int pid, tid; }
    public delegate bool EnumProc(IntPtr hwnd, IntPtr arg);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr security);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateWindowStationW(string name, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32.dll")] public static extern bool CloseWindowStation(IntPtr station);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateProcessW(string application, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string cwd, ref SI startup, out PI info);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateJobObjectW(IntPtr security, string name);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr data, uint size, out uint returned);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool member);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    public static int[] JobPids(IntPtr job) {
        // This harness has few children. MORE_DATA fails closed rather than
        // truncating an unexpectedly large process list.
        int size=8+IntPtr.Size*256; IntPtr buffer=Marshal.AllocHGlobal(size);
        try {
            uint returned;
            if(!QueryInformationJobObject(job,3,buffer,(uint)size,out returned)) throw new Exception("Query owned job failed: "+Marshal.GetLastWin32Error());
            int count=Marshal.ReadInt32(buffer,4); var ids=new int[count];
            for(int i=0;i<count;i++) ids[i]=(int)Marshal.ReadIntPtr(buffer,8+i*IntPtr.Size);
            return ids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static int[] ReapOwnedJob(IntPtr job) {
        var stopped=new List<int>();
        for(int round=0;round<8;round++) {
            int[] ids=JobPids(job); if(ids.Length==0) return stopped.ToArray();
            foreach(int id in ids) {
                // Hold the exact process handle and freshly verify membership
                // before terminating. A reused PID outside our job is skipped.
                IntPtr handle=OpenProcess(0x00101001,false,id);
                if(handle==IntPtr.Zero) continue;
                try {
                    bool member;
                    if(!IsProcessInJob(handle,job,out member)) throw new Exception("Owned job membership query failed");
                    if(!member) continue;
                    uint code;
                    if(!GetExitCodeProcess(handle,out code)) throw new Exception("Owned process query failed");
                    if(code!=259) continue;
                    if(!TerminateProcess(handle,1)) {
                        if(!GetExitCodeProcess(handle,out code) || code==259) throw new Exception("Owned process termination failed");
                    } else stopped.Add(id);
                    if(WaitForSingleObject(handle,10000)!=0) throw new Exception("Owned process did not exit");
                } finally { CloseHandle(handle); }
            }
        }
        if(JobPids(job).Length!=0) throw new Exception("Owned job still has processes after cleanup");
        return stopped.ToArray();
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int capacity);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd,ref Point point);
    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint msg,UIntPtr wparam,IntPtr lparam);
    public static long Position(int x,int y) { return (long)((uint)(ushort)x | ((uint)(ushort)y<<16)); }
    public static IntPtr Menu(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,a)=> { int p; GetWindowThreadProcessId(h,out p); if(p==pid && ClassOf(h)=="#32768") found=h; return true; },IntPtr.Zero); return found;
    }
    public static string ClassOf(IntPtr hwnd) { var s=new StringBuilder(256); GetClassNameW(hwnd,s,256); return s.ToString(); }
    public static IntPtr Host(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,a)=> { int p; GetWindowThreadProcessId(h,out p); if(p==pid && ClassOf(h)=="noctty.win32.host") found=h; return true; },IntPtr.Zero);
        return found;
    }
    public static IntPtr Surface(IntPtr host) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(host,(h,a)=> { if(ClassOf(h)=="noctty.win32") found=h; return true; },IntPtr.Zero);
        return found;
    }
    public static void Send(IntPtr hwnd,uint msg,int value,long bits) {
        UIntPtr result;
        if(SendMessageTimeoutW(hwnd,msg,(UIntPtr)(uint)value,(IntPtr)bits,2,5000,out result)==IntPtr.Zero)
            throw new Exception("SendMessageTimeout failed: "+Marshal.GetLastWin32Error());
    }

}
'@
}

function Start-Hidden([string] $Application, [string] $Command, [string] $Directory, [string] $Desktop, [IntPtr] $OwnerJob = [IntPtr]::Zero) {
    $si = [MouseInputNative+SI]::new()
    $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][MouseInputNative+SI])
    $si.desktop = $Desktop
    $pi = [MouseInputNative+PI]::new()
    $flags = if ($OwnerJob -ne [IntPtr]::Zero) { 0x08004004 } else { 0x08004000 }
    if (-not [MouseInputNative]::CreateProcessW($Application, [Text.StringBuilder]::new($Command),
            [IntPtr]::Zero, [IntPtr]::Zero, $false, $flags, [IntPtr]::Zero, $Directory, [ref]$si, [ref]$pi)) {
        throw "CreateProcessW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    try {
        # Assign the suspended driver before its first instruction: every
        # descendant inherits containment even if the worker cannot finalize.
        if ($OwnerJob -ne [IntPtr]::Zero) {
            if (-not [MouseInputNative]::AssignProcessToJobObject($OwnerJob, $pi.process)) {
                [void][MouseInputNative]::TerminateProcess($pi.process, 1)
                throw 'Assigning suspended driver to owned job failed.'
            }
            if ([MouseInputNative]::ResumeThread($pi.thread) -eq [uint32]::MaxValue) {
                [void][MouseInputNative]::TerminateProcess($pi.process, 1)
                throw 'Resuming contained driver failed.'
            }
        }
    }
    finally {
        [void][MouseInputNative]::CloseHandle($pi.thread)
        [void][MouseInputNative]::CloseHandle($pi.process)
    }
    return [Diagnostics.Process]::GetProcessById($pi.pid)
}

function Stop-Owned([Diagnostics.Process] $Process, [string] $ExpectedPath, [datetime] $StartTime) {
    # Re-read the exact PID immediately before termination; reject PID reuse
    # and executable changes. No name/pattern or system-wide tree kill.
    $fresh = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
    if (-not $fresh) { return }
    if ($fresh.StartTime -ne $StartTime -or $fresh.Path -ne $ExpectedPath) { throw "PID identity changed: $($Process.Id)" }
    $fresh.Kill()
    if (-not $fresh.WaitForExit(10000)) { throw "Owned process $($fresh.Id) did not exit." }
}

if (-not $Worker) {
    $ExePath = (Resolve-Path -LiteralPath $ExePath).Path
    if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be fresh.' }
    $realStartup = Join-Path $env:LOCALAPPDATA 'noctty\startup-attempts.json'
    $before = Get-Fingerprint $realStartup
    [void](New-Item -ItemType Directory -Path $RunRoot)
    $RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
    Copy-Item -LiteralPath $ExePath -Destination (Join-Path $RunRoot 'noctty.exe')
    $bin = Split-Path -Parent $ExePath
    foreach ($name in @('conpty.dll', 'OpenConsole.exe', 'noctty.ico')) {
        $source = Join-Path $bin $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $RunRoot }
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $bin) 'share') -Destination (Join-Path $RunRoot 'share') -Recurse
    [IO.File]::WriteAllText((Join-Path $RunRoot 'noctty.portable'), '')
    $fixtureSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
class MouseRecorder {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle,uint mode);
    static int Main(string[] a) {
        uint mode;
        if(!GetConsoleMode(GetStdHandle(-10),out mode) || !SetConsoleMode(GetStdHandle(-10),(mode|512)&~(2u|4u))) return 11;
        if(GetConsoleMode(GetStdHandle(-11),out mode)) SetConsoleMode(GetStdHandle(-11),mode|4);
        File.WriteAllText(a[0]+".ready","yes");
        while(!File.Exists(a[0]+".enable")) Thread.Sleep(20);
        Console.Write("\x1b[?1003h\x1b[?1006h"); Console.Out.Flush();
        File.WriteAllText(a[0]+".enabled","yes");
        using(var input=Console.OpenStandardInput()) using(var log=new FileStream(a[0]+".bytes",FileMode.Create,FileAccess.Write,FileShare.ReadWrite)) {
            var bytes=new byte[256]; int count;
            while((count=input.Read(bytes,0,bytes.Length))>0) { log.Write(bytes,0,count); log.Flush(); }
        }
        return 0;
    }
}
'@
    $sourcePath = Join-Path $RunRoot 'mouse-recorder.cs'
    [IO.File]::WriteAllText($sourcePath, $fixtureSource)
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe "/out:$RunRoot\mouse-recorder.exe" $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Recorder compilation failed.' }
    $leaf = 'pkg26-' + [guid]::NewGuid().ToString('N')
    $desktop = [MouseInputNative]::CreateDesktopW($leaf, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktopW failed.' }
    [IO.File]::WriteAllText((Join-Path $RunRoot 'desktop.txt'), "WinSta0\$leaf")
    $job = [MouseInputNative]::CreateJobObjectW([IntPtr]::Zero, [NullString]::Value)
    if ($job -eq [IntPtr]::Zero) { throw 'CreateJobObject failed.' }
    try {
        $pwsh = (Get-Command pwsh.exe).Source
        $command = '"{0}" -NoProfile -NonInteractive -File "{1}" -Worker -RunRoot "{2}" -RightClickAction {3}' -f $pwsh, $PSCommandPath, $RunRoot, $RightClickAction
        if ($ObserveBaseline) { $command += ' -ObserveBaseline' }
        $driver = Start-Hidden $pwsh $command $RunRoot "WinSta0\$leaf" $job
        if (-not $driver.WaitForExit(90000)) { Stop-Owned $driver $pwsh $driver.StartTime; throw 'Mouse driver timed out.' }
        $result = Get-Content -Raw -LiteralPath (Join-Path $RunRoot 'result.json') | ConvertFrom-Json
        $result | ConvertTo-Json -Depth 5 | Write-Output
        if ($result.status -ne 'PASS') { throw 'Mouse assertions failed.' }
    }
    finally {
        try {
            $stopped = @([MouseInputNative]::ReapOwnedJob($job))
            [pscustomobject]@{ stoppedPids = $stopped; remainingPids = @([MouseInputNative]::JobPids($job)) } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunRoot 'cleanup.json')
        }
        finally {
            [void][MouseInputNative]::CloseHandle($job)
            [void][MouseInputNative]::CloseDesktop($desktop)
            if ((Get-Fingerprint $realStartup) -ne $before) { throw 'Real startup ledger changed.' }
            [pscustomobject]@{ sourceSha256 = (Get-FileHash -LiteralPath $ExePath).Hash; startup = $before; startupUnchanged = $true } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunRoot 'provenance.json')
        }
    }
    Write-Host 'mouse input: PASS; real startup ledger unchanged'
    return
}

$env:LOCALAPPDATA = Join-Path $RunRoot 'local'
$env:APPDATA = Join-Path $RunRoot 'roaming'
$env:GHOSTTY_RESOURCES_DIR = Join-Path $RunRoot 'share\ghostty'
$marker = Join-Path $RunRoot 'reports'
$exe = Join-Path $RunRoot 'noctty.exe'
$app = $null
$result = [ordered]@{ status = 'FAIL'; action = $RightClickAction; error = $null; observations = @() }
function Wait-File([string] $Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($app.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw "Marker timeout: $([IO.Path]::GetFileName($Path))" }
        Start-Sleep -Milliseconds 30
    }
}
function Read-Reports {
    if (-not (Test-Path -LiteralPath ($marker + '.bytes'))) { return '' }
    $stream = [IO.File]::Open($marker + '.bytes', 'Open', 'Read', 'ReadWrite')
    try { $reader = [IO.StreamReader]::new($stream); return $reader.ReadToEnd() }
    finally { $stream.Dispose() }
}
function Right-Click([int] $Mods) {
    [MouseInputNative]::Send($surface, 0x204, ($Mods -bor 2), [MouseInputNative]::Position(80,80))
    [void][MouseInputNative]::PostMessageW($surface, 0x205, [UIntPtr]$Mods, [IntPtr][MouseInputNative]::Position(80,80))
    Start-Sleep -Milliseconds 300
    $menu = [MouseInputNative]::Menu($app.Id)
    if ($menu -ne [IntPtr]::Zero) {
        [void][MouseInputNative]::PostMessageW($hostWindow, 0x1F, [UIntPtr]::Zero, [IntPtr]::Zero)
        [void][MouseInputNative]::PostMessageW($menu, 0x100, [UIntPtr]27, [IntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 200
    return ($menu -ne [IntPtr]::Zero)
}
try {
    $config = Join-Path $RunRoot 'config.ghostty'
    $text = "auto-update = off`nconfirm-close-surface = false`nwindow-save-state = never`nsingle-instance = false`ncopy-on-select = false`nright-click-action = $RightClickAction`n"
    $text += 'command = direct:"' + (Join-Path $RunRoot 'mouse-recorder.exe') + '" "' + $marker + '"' + "`n"
    [IO.File]::WriteAllText($config, $text, [Text.UTF8Encoding]::new($false))
    $app = Start-Hidden $exe ('"' + $exe + '" --config-file="' + $config + '"') $RunRoot ([IO.File]::ReadAllText((Join-Path $RunRoot 'desktop.txt')))
    $appStart = $app.StartTime
    Wait-File ($marker + '.ready')
    $hostWindow = [MouseInputNative]::Host($app.Id)
    $surface = [MouseInputNative]::Surface($hostWindow)
    if ($surface -eq [IntPtr]::Zero) { throw 'Hidden terminal surface missing.' }
    $menuShown = Right-Click 0
    $result.observations += "menu shown before reporting: $menuShown"
    if (-not $ObserveBaseline -and $menuShown -ne ($RightClickAction -eq 'context-menu')) { throw 'right-click-action menu policy failed.' }
    [IO.File]::WriteAllText($marker + '.enable', 'yes')
    Wait-File ($marker + '.enabled')
    Start-Sleep -Milliseconds 250
    [MouseInputNative]::Send($surface, 0x200, 0, [MouseInputNative]::Position(100,100))
    Start-Sleep -Milliseconds 200
    $reports = Read-Reports
    $result.observations += ('motion after menu: ' + $reports.Replace([string][char]27, '<ESC>'))
    if (-not $ObserveBaseline -and ($reports -match '\[<34;' -or $reports -notmatch '\[<35;')) { throw 'Phantom right drag or missing unpressed motion.' }
    $menuShown = Right-Click 0
    if (-not $ObserveBaseline -and $menuShown) { throw 'Mouse-reporting right click opened a menu.' }
    $menuShown = Right-Click 4
    if (-not $ObserveBaseline -and $menuShown -ne ($RightClickAction -eq 'context-menu')) { throw 'Shift override menu policy failed.' }
    [MouseInputNative]::Send($surface, 0x200, 0, [MouseInputNative]::Position(180,140))
    Start-Sleep -Milliseconds 200
    $reports = Read-Reports
    $lastMotion = [regex]::Matches($reports, '\x1b\[<(\d+);(\d+);(\d+)M') | Select-Object -Last 1
    if (-not $ObserveBaseline -and $lastMotion.Groups[1].Value -ne '35') { throw 'Shift right release left a pressed button.' }
    foreach ($message in @(0x20A, 0x20E)) {
        $point = [MouseInputNative+Point]::new(); $point.x = 300; $point.y = 200
        if (-not [MouseInputNative]::ClientToScreen($surface, [ref]$point)) { throw 'ClientToScreen failed.' }
        [MouseInputNative]::Send($surface, $message, (120 -shl 16), [MouseInputNative]::Position($point.x,$point.y))
        Start-Sleep -Milliseconds 200
        $reports = Read-Reports
        $wheel = [regex]::Matches($reports, '\x1b\[<(6[4-7]);(\d+);(\d+)M') | Select-Object -Last 1
        if (-not $wheel) { throw 'No wheel report.' }
        $result.observations += "wheel $message at cell $($wheel.Groups[2].Value),$($wheel.Groups[3].Value)"
        if (-not $ObserveBaseline -and $wheel.Groups[2].Value -eq $lastMotion.Groups[2].Value -and $wheel.Groups[3].Value -eq $lastMotion.Groups[3].Value) { throw 'Wheel reported stale mouse coordinates.' }
    }
    $result.status = 'PASS'
}
catch { $result.error = $_.Exception.Message }
finally {
    if ($app -and -not $app.HasExited) {
        [void][MouseInputNative]::PostMessageW([MouseInputNative]::Host($app.Id), 0x10, [UIntPtr]::Zero, [IntPtr]::Zero)
        if (-not $app.WaitForExit(10000)) { Stop-Owned $app $exe $appStart }
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RunRoot 'result.json')
}
if ($result.status -ne 'PASS') { exit 1 }

