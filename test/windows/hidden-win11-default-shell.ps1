#requires -Version 7.0
<#
Portable, hidden-desktop check of the shell a new terminal starts when `command`
is unset (PKG-49): PowerShell 7 if it is on PATH, else Windows PowerShell, else
cmd.exe, and cmd.exe in safe mode. Run with -Bin <directory holding a noctty.exe
and its share folder> and -Run <new evidence directory>.

Cases, each one launch of noctty with no `command` in its config:
  default           the machine as it is: expects pwsh.exe when it is on PATH
  no-pwsh           PATH without any pwsh.exe: expects powershell.exe
  restricted-51     the same, with the process execution policy Restricted: the
                    first prompt must appear with no warning from this app and
                    the injected shell integration must be on the command line (the
                    host's own PSReadLine and profile.ps1 errors are expected there)
  safe-mode         --safe-mode: expects cmd.exe whatever else is installed
Per case the results hold the shell's image name, whether the integration
payload is on its command line (a boolean; the command line itself is never
written), the time from launch until its screen stops changing (the first prompt), and the text of
that shell's own screen, read through its console (the screen of a terminal
this script started, never a user's).

Every file the app reads or writes is one this script creates beside a portable
copy (`noctty.portable`), with LOCALAPPDATA and APPDATA redirected into the run
directory: the real %LOCALAPPDATA%\noctty is never written or deleted, and only
the hash and time of its startup state file are read, before and after. Every
process starts on a private desktop named explicitly in STARTUPINFO, inside a
job this script owns. Nothing is typed and nothing can copy; the clipboard
sequence number is logged before and after and a change fails the run, as does a
change in the size or time of the real PSReadLine history file (metadata only).
Launch a build patched with a measurement AUMID only; -MeasureJumpListName names
that AUMID's jump-list file, which the script deletes only when it did not exist
before the run and was written during it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $Desktop,
    [string] $AttachExe,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 300,
    [ValidatePattern('^[0-9a-f]{16}\.customDestinations-ms$')] [string] $MeasureJumpListName,
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
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr dev,IntPtr mode,int flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job,int type,ref JobLimits limits,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
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
    public static IntPtr[] Windows(int pid,string cls) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)==cls) list.Add(h); return true;
        },IntPtr.Zero); return list.ToArray();
    }
    // Children are created suspended and always placed on the named desktop.
    // noWindow: CREATE_NO_WINDOW, for console helpers.
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job,bool noWindow) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        uint flags=0x00000004|(noWindow?0x08000000u:0u)|0x00000400u; // SUSPENDED, UNICODE_ENVIRONMENT
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if((job!=IntPtr.Zero && !AssignProcessToJobObject(job,pi.process))||ResumeThread(pi.thread)==0xFFFFFFFF) {
            TerminateProcess(pi.process,1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume failed");
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
# Size and time only; the contents of a shell history are never read.
function History-Metadata {
    $path = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    $item = Get-Item -LiteralPath $path
    return @{ Exists=$true; Length=$item.Length; Modified=$item.LastWriteTimeUtc.ToString('o') }
}
function Jump-List-Files {
    $dir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Recent\CustomDestinations'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.customDestinations-ms' -File | ForEach-Object { @{ Path=$_.FullName; Written=[DateTimeOffset]$_.LastWriteTimeUtc } })
}
function Copy-Portable([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}
# Compile a C helper without a window: the compile runs in the build shell with no console of its own.
function Compile-Helper([string] $Source, [string] $Exe, [IntPtr] $Job, [string] $Root) {
    $script = [IO.Path]::ChangeExtension($Exe, '.cmd')
    @('@echo off', ('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" > "{4}" 2>&1' -f
        (Join-Path $Root 'scripts\dev-windows.cmd'), $Source, $Exe, ($Exe -replace '\.exe$', '.obj'), ($Exe -replace '\.exe$', '.compile.log')),
        'exit /b %errorlevel%') | Set-Content -LiteralPath $script -Encoding ascii
    $pi = [Ds]::Launch($env:ComSpec, ('"{0}" /d /c ""{1}""' -f $env:ComSpec, $script), $Root, $null, $Job, $true)
    [void][Ds]::WaitForSingleObject($pi.process, 180000)
    [uint32]$code = 1; [void][Ds]::GetExitCodeProcess($pi.process, [ref]$code)
    [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process)
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $Exe)) { throw "Helper compile failed: $Source" }
}

if (-not $Driver) {
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    $source = (Resolve-Path -LiteralPath $Bin).Path
    if (-not (Test-Path -LiteralPath (Join-Path $source 'noctty.exe'))) { throw "No noctty.exe in $source." }
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    $before = Startup-Fingerprint
    $historyBefore = History-Metadata
    $clipboardBefore = [Ds]::GetClipboardSequenceNumber()
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    $jumpBefore = @(Jump-List-Files | ForEach-Object { $_.Path })
    $batchStart = [DateTimeOffset]::UtcNow
    Write-Host "Clipboard sequence before: $clipboardBefore"
    [void](New-Item -ItemType Directory -Path $Run)
    $copy = Join-Path $Run 'case\bin'
    Copy-Portable $source $copy
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $attach = Join-Path $Run 'console-attach-info.exe'
    $compileJob = [Ds]::CreateOwnedJob()
    try { Compile-Helper (Join-Path $PSScriptRoot 'console-attach-info.c') $attach $compileJob $root } finally { [void][Ds]::StopOwnedJob($compileJob) }
    $desktopName = 'noctty-ds-' + [guid]::NewGuid().ToString('N')
    $desktop = [Ds]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero; $code=1
    try {
        $job=[Ds]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -AttachExe "{4}" -Desktop "{5}" -Driver' -f $pwsh,$PSCommandPath,$copy,$Run,$attach,"WinSta0\$desktopName"
        $pi=[Ds]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job,$true)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([Ds]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$exit=0; [void][Ds]::GetExitCodeProcess($pi.process,[ref]$exit); $code=$exit
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[Ds]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
        [void][Ds]::CloseDesktop($desktop)
        $batchEnd = [DateTimeOffset]::UtcNow
        # Only the measurement AUMID's file, and only if this batch created it.
        $removed = @(); $otherNew = @()
        foreach ($f in Jump-List-Files) {
            if ($jumpBefore -contains $f.Path -or $f.Written -lt $batchStart -or $f.Written -gt $batchEnd) { continue }
            if ($MeasureJumpListName -and (Split-Path -Leaf $f.Path) -eq $MeasureJumpListName) {
                Remove-Item -LiteralPath $f.Path; $removed += $MeasureJumpListName
            } else { $otherNew += (Split-Path -Leaf $f.Path) }
        }
        $after=Startup-Fingerprint
        $historyAfter = History-Metadata
        $clipboardAfter=[Ds]::GetClipboardSequenceNumber()
        Write-Host "Clipboard sequence after: $clipboardAfter"
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $historyUnchanged=$historyBefore.Exists -eq $historyAfter.Exists -and $historyBefore.Length -eq $historyAfter.Length -and $historyBefore.Modified -eq $historyAfter.Modified
        @{ Before=$before; After=$after; Unchanged=$unchanged; HistoryUnchanged=$historyUnchanged; OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount; ClipboardSequenceBefore=$clipboardBefore; ClipboardSequenceAfter=$clipboardAfter; JumpListFilesRemoved=$removed; OtherNewJumpListFiles=$otherNew; BatchStartUtc=$batchStart.ToString('o'); BatchEndUtc=$batchEnd.ToString('o') } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if ($clipboardBefore -ne $clipboardAfter) { throw "Clipboard sequence number changed ($clipboardBefore -> $clipboardAfter); stop launches and report it." }
        if (-not $historyUnchanged) { throw 'Real PowerShell history metadata changed; stop launches and report it.' }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect results in $Run." }
    Write-Host 'Hidden default shell: PASS'
    exit
}

# Driver: runs only on the private desktop, inside the owned job.
$script:checks=[Collections.Generic.List[object]]::new()
$script:launches=[Collections.Generic.List[object]]::new()
function Check([string]$Case,[string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Case=$Case; Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
$shellNames = @('pwsh.exe','powershell.exe','cmd.exe')
# Names and ids only. The command line of a shell is tested for the integration
# payload inside this function and never returned.
function Find-Shell([int]$RootPid) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CommandLine)
    $ids = [Collections.Generic.HashSet[int]]::new(); [void]$ids.Add($RootPid)
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($p in $all) { if ($ids.Contains([int]$p.ParentProcessId) -and $ids.Add([int]$p.ProcessId)) { $grew = $true } }
    }
    foreach ($p in $all) {
        if ($ids.Contains([int]$p.ProcessId) -and $p.ProcessId -ne $RootPid -and $shellNames -contains $p.Name.ToLowerInvariant()) {
            $integration = ($null -ne $p.CommandLine) -and ($p.CommandLine -match 'integration\.ps1|__ghostty')
            return @{ Pid=[int]$p.ProcessId; Name=$p.Name.ToLowerInvariant(); Integration=$integration }
        }
    }
    return $null
}
function Read-Screen([int]$ShellPid,[string]$OutFile) {
    $pi = [Ds]::Launch($AttachExe,('"{0}" {1} "{2}" dump' -f $AttachExe,$ShellPid,$OutFile),(Split-Path -Parent $AttachExe),$Desktop,[IntPtr]::Zero,$true)
    try {
        [void][Ds]::WaitForSingleObject($pi.process,10000)
        [uint32]$code=1; [void][Ds]::GetExitCodeProcess($pi.process,[ref]$code)
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) { return $null }
        return @(Get-Content -LiteralPath $OutFile | Select-Object -Skip 1)
    } finally { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
}
function Launch-Case([string]$Case,[string]$Exe,[string[]]$ExtraArgs,[hashtable]$Env) {
    $dir = Split-Path -Parent $Exe
    @('window-save-state = never','confirm-close-surface = false','auto-update = off') | Set-Content -LiteralPath (Join-Path $dir 'config.ghostty')
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k,$Env[$k]) }
    $class = "noctty-test-pkg49-$([guid]::NewGuid().ToString('N').Substring(0,12))"
    $line = '"{0}" --single-instance=false --class={1} {2}' -f $Exe,$class,($ExtraArgs -join ' ')
    $record = @{ Case=$Case; Shell=$null; Integration=$null; PromptMs=$null; PromptLine=$null; Screen=@(); NocttyWarnings=@(); HostNoise=@() }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { $pi = [Ds]::Launch($Exe,$line,$dir,$Desktop,[IntPtr]::Zero,$false) }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k,$saved[$k]) } }
    try {
        $record.Pid = $pi.pid
        $shell = $null
        while ($clock.Elapsed.TotalSeconds -lt 30 -and $null -eq $shell) {
            if ([Ds]::WaitForSingleObject($pi.process,0) -eq 0) { break }
            $shell = Find-Shell $pi.pid
            if ($null -eq $shell) { Start-Sleep -Milliseconds 100 }
        }
        if ($shell) {
            $record.Shell = $shell.Name; $record.Integration = $shell.Integration
            $out = Join-Path $dir "screen-$Case.txt"
            # A prompt is the screen holding the same non-empty rows in two reads 750 ms apart: prompts are
            # themed (a starship prompt is `~ ❯`), so no pattern for them is trusted.
            $last = $null; $lastAt = 0
            while ($clock.Elapsed.TotalSeconds -lt 40) {
                Remove-Item -LiteralPath $out -ErrorAction Ignore
                $rows = Read-Screen $shell.Pid $out
                if ($rows) {
                    $text = @($rows | Where-Object { $_.Trim() })
                    $joined = $text -join "`n"
                    if ($text.Count -gt 0 -and $joined -eq $last -and ($clock.ElapsedMilliseconds - $lastAt) -ge 750) {
                        $record.PromptMs = $lastAt
                        $record.PromptLine = $text[-1]
                        $record.Screen = $text
                        break
                    }
                    if ($joined -ne $last) { $last = $joined; $lastAt = [int]$clock.ElapsedMilliseconds }
                }
                Start-Sleep -Milliseconds 250
            }
            # Lines from the shell host or the user's own profile are not ours: Windows PowerShell under Restricted
            # cannot load PSReadLine or a profile.ps1 in any terminal. A line naming this app is.
            $record.NocttyWarnings = @($record.Screen | Where-Object { $_ -match '(?i)noctty|integration (skipped|could not)|could not load' })
            $record.HostNoise = @($record.Screen | Where-Object { $_ -match '(?i)PSReadline|profile\.ps1|about_Execution_Policies|SecurityError|UnauthorizedAccess|FullyQualifiedErrorId|^\s*\+ |^At line:' })
        }
        if ([Ds]::WaitForSingleObject($pi.process,0) -ne 0) {
            foreach ($h in [Ds]::Windows($pi.pid,'noctty.win32.host')) { [void][Ds]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
            if ([Ds]::WaitForSingleObject($pi.process,8000) -ne 0) {
                # Our own handle from CreateProcess: the exact process we started.
                [void][Ds]::TerminateProcess($pi.process,1); [void][Ds]::WaitForSingleObject($pi.process,5000)
                $record.Terminated = $true
            }
        }
    } finally { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
    $script:launches.Add($record)
    return $record
}

try {
    $exe = Join-Path $Bin 'noctty.exe'
    $pathDirs = @($env:PATH -split ';' | Where-Object { $_ })
    $withPwsh = @($pathDirs | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'pwsh.exe') -PathType Leaf })
    $withoutPwsh = ($pathDirs | Where-Object { $withPwsh -notcontains $_ }) -join ';'
    $pwshOnPath = $withPwsh.Count -gt 0

    $r = Launch-Case 'default' $exe @() @{}
    Check 'default' "the first tab runs $(if($pwshOnPath){'pwsh.exe, which is on PATH'}else{'powershell.exe, as pwsh.exe is not on PATH'})" ($r.Shell -eq $(if($pwshOnPath){'pwsh.exe'}else{'powershell.exe'})) $(if($pwshOnPath){'pwsh.exe'}else{'powershell.exe'}) $r.Shell
    Check 'default' 'the shell integration payload is on its command line' ($r.Integration -eq $true) $true $r.Integration
    Check 'default' 'a prompt appears' ($null -ne $r.PromptMs) 'prompt' $r.PromptLine
    Check 'default' 'no warning from this app on the screen' ($r.NocttyWarnings.Count -eq 0) 0 $r.NocttyWarnings

    $r = Launch-Case 'no-pwsh' $exe @() @{ PATH = $withoutPwsh }
    Check 'no-pwsh' 'without pwsh.exe on PATH the first tab runs Windows PowerShell' ($r.Shell -eq 'powershell.exe') 'powershell.exe' $r.Shell
    Check 'no-pwsh' 'a prompt appears' ($null -ne $r.PromptMs) 'prompt' $r.PromptLine

    $r = Launch-Case 'restricted-51' $exe @() @{ PATH = $withoutPwsh; PSExecutionPolicyPreference = 'Restricted' }
    Check 'restricted-51' 'Windows PowerShell 5.1 starts under the Restricted policy' ($r.Shell -eq 'powershell.exe') 'powershell.exe' $r.Shell
    Check 'restricted-51' 'the integration payload is on its command line' ($r.Integration -eq $true) $true $r.Integration
    Check 'restricted-51' 'a prompt appears' ($null -ne $r.PromptMs) 'prompt' $r.PromptLine
    Check 'restricted-51' 'no warning from this app on the screen (the host and profile lines below it are Restricted behaviour in any terminal)' ($r.NocttyWarnings.Count -eq 0) 0 $r.NocttyWarnings

    $r = Launch-Case 'safe-mode' $exe @('--safe-mode') @{}
    Check 'safe-mode' 'safe mode starts cmd.exe although PowerShell is installed' ($r.Shell -eq 'cmd.exe') 'cmd.exe' $r.Shell
    Check 'safe-mode' 'a prompt appears' ($null -ne $r.PromptMs) 'prompt' $r.PromptLine
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    @{ PwshOnPath=$pwshOnPath; Checks=$script:checks; Launches=$script:launches; Limit='One window, one tab per launch; no input; the prompt time is from launch to the first prompt row on the shell screen, polled every 250 ms, on a debug-free ReleaseFast build.' } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'default-shell-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count -or $script:checks.Count -eq 0){exit 1}
