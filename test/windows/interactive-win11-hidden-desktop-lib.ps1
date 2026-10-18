# Shared by interactive-win11-stale-modes.ps1 and interactive-win11-mouse-input.ps1, which run
# their worker and a portable noctty copy on a newly created hidden desktop. Dot-source it.
# [HiddenDesktopNative] holds the desktop, process, owned-job and window plumbing both use;
# each harness keeps its own input and fixture code.

function Get-Fingerprint([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $item = Get-Item -LiteralPath $Path
    return "$($item.LastWriteTimeUtc.Ticks):$($item.Length):$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)"
}

if (-not ('HiddenDesktopNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class HiddenDesktopNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI {
        public int cb; public string reserved, desktop, title;
        public int x,y,xsize,ysize,xchars,ychars,fill,flags;
        public short show, cbReserved; public IntPtr reserved2, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process, thread; public int pid, tid; }
    public delegate bool EnumProc(IntPtr hwnd, IntPtr arg);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr security);
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
    public static string ClassOf(IntPtr hwnd) { var s=new StringBuilder(256); GetClassNameW(hwnd,s,256); return s.ToString(); }
    // The last top-level window of `cls` that process `pid` owns, in the order Windows enumerates
    // them, or zero.
    public static IntPtr TopWindow(int pid,string cls) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,a)=> { int p; GetWindowThreadProcessId(h,out p); if(p==pid && ClassOf(h)==cls) found=h; return true; },IntPtr.Zero);
        return found;
    }
    public static IntPtr Host(int pid) { return TopWindow(pid,"noctty.win32.host"); }
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
    $si = [HiddenDesktopNative+SI]::new()
    $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][HiddenDesktopNative+SI])
    $si.desktop = $Desktop
    $pi = [HiddenDesktopNative+PI]::new()
    $flags = if ($OwnerJob -ne [IntPtr]::Zero) { 0x08004004 } else { 0x08004000 }
    if (-not [HiddenDesktopNative]::CreateProcessW($Application, [Text.StringBuilder]::new($Command),
            [IntPtr]::Zero, [IntPtr]::Zero, $false, $flags, [IntPtr]::Zero, $Directory, [ref]$si, [ref]$pi)) {
        throw "CreateProcessW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    try {
        # Assign the suspended driver before its first instruction: every
        # descendant inherits containment even if the worker cannot finalize.
        if ($OwnerJob -ne [IntPtr]::Zero) {
            if (-not [HiddenDesktopNative]::AssignProcessToJobObject($OwnerJob, $pi.process)) {
                [void][HiddenDesktopNative]::TerminateProcess($pi.process, 1)
                throw 'Assigning suspended driver to owned job failed.'
            }
            if ([HiddenDesktopNative]::ResumeThread($pi.thread) -eq [uint32]::MaxValue) {
                [void][HiddenDesktopNative]::TerminateProcess($pi.process, 1)
                throw 'Resuming contained driver failed.'
            }
        }
    }
    finally {
        [void][HiddenDesktopNative]::CloseHandle($pi.thread)
        [void][HiddenDesktopNative]::CloseHandle($pi.process)
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
