// Focused Win32 support for cli-com-forwarder.ps1. No product code is compiled.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public static class ComCliNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title;
        public int x,y,cx,cy,charsX,charsY,fill,flags;
        public short show,reservedBytes; public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct Security { public int length; public IntPtr descriptor; public int inherit; }
    public sealed class Child : IDisposable {
        public IntPtr Handle; public uint Pid; public long Created;
        public string Image; public IntPtr OutputRead;
        public Task<string> Output, Error;
        public bool Exited { get { return WaitForSingleObject(Handle,0)==0; } }
        public uint ExitCode { get { uint code; Check(GetExitCodeProcess(Handle,out code)); return code; } }
        public bool Wait(int ms) { return WaitForSingleObject(Handle,(uint)ms)==0; }
        public void Dispose() {
            if(Handle==IntPtr.Zero) return;
            Verify(this);
            if(!Exited) { Check(TerminateProcess(Handle,0xD20)); Wait(5000); }
            if(OutputRead!=IntPtr.Zero) CloseHandle(OutputRead);
            CloseHandle(Handle); Handle=IntPtr.Zero;
        }
    }
    delegate bool EnumWindow(IntPtr window,IntPtr parameter);
    delegate bool ControlHandler(uint kind);
    static readonly ControlHandler Control = kind => kind==0;
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string path,uint access,uint share,ref Security sa,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref Security sa,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool PeekNamedPipe(IntPtr pipe,IntPtr buffer,uint size,IntPtr read,out uint available,IntPtr left);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long created,out long exited,out long kernel,out long user);
    [DllImport("kernel32.dll")] static extern uint GetProcessId(IntPtr h);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr h,uint flags,StringBuilder image,ref uint length);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint exit);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetConsoleCtrlHandler(ControlHandler handler,bool add);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GenerateConsoleCtrlEvent(uint kind,uint group);
    [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList([Out] uint[] processes,uint count);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ReadConsoleOutputCharacterW(IntPtr h,[Out] char[] text,uint count,uint coordinate,out uint read);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateWindowStationW(string name,uint flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenDesktopW(string name,uint flags,bool inherit,uint access);
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32.dll")] public static extern bool CloseWindowStation(IntPtr station);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateDesktopW(string name,IntPtr device,IntPtr mode,uint flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll",SetLastError=true)] static extern bool EnumDesktopWindows(IntPtr desktop,EnumWindow callback,IntPtr parameter);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder name,int count);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint message,IntPtr w,IntPtr l);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder name,uint bytes,out uint needed);
    static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static Security Inheritable() { return new Security { length=Marshal.SizeOf(typeof(Security)),inherit=1 }; }
    public static string Quote(string value) {
        var result=new StringBuilder("\""); int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='"') { result.Append('\\',slashes*2+1).Append(c); slashes=0; continue; }
            result.Append('\\',slashes).Append(c); slashes=0;
        }
        return result.Append('\\',slashes*2).Append('"').ToString();
    }
    public static IntPtr[] PrivateDesktop(string name) {
        var station=CreateWindowStationW(name,0,0xF037F,IntPtr.Zero);
        if(station==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateWindowStationW failed");
        var original=GetProcessWindowStation(); var desktop=IntPtr.Zero;
        try {
            if(!SetProcessWindowStation(station)) throw new Win32Exception(Marshal.GetLastWin32Error(),"SetProcessWindowStation failed");
            desktop=CreateDesktopW("Default",IntPtr.Zero,IntPtr.Zero,0,0xF01FF,IntPtr.Zero);
            if(desktop==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateDesktopW failed");
        } catch { SetProcessWindowStation(original); CloseWindowStation(station); throw; }
        finally { Check(SetProcessWindowStation(original)); }
        return new [] {station,desktop};
    }
    // Setup-only diagnostic: request fewer rights, immediately close, never
    // change token privileges, security descriptors, or desktop visibility.
    public static int ProbeStationAccess(string name,uint desiredAccess) {
        var handle=CreateWindowStationW(name,0,desiredAccess,IntPtr.Zero);
        int error=Marshal.GetLastWin32Error();
        if(handle==IntPtr.Zero) return error;
        Check(CloseWindowStation(handle)); return 0;
    }
    public static void AssertStation(string expected) {
        var name=new StringBuilder(256); uint needed;
        Check(GetUserObjectInformationW(GetProcessWindowStation(),2,name,512,out needed));
        if(name.ToString()!=expected || expected=="WinSta0") throw new Exception("Private station identity mismatch");
    }
    static string ObjectName(IntPtr handle) {
        var name=new StringBuilder(256); uint needed;
        Check(GetUserObjectInformationW(handle,2,name,512,out needed)); return name.ToString();
    }
    public static IntPtr HiddenDesktop(string name,bool inherit=false) {
        if(!name.StartsWith("noctty-pkg74-",StringComparison.Ordinal)) throw new Exception("Unexpected hidden desktop name");
        var sa=Inheritable(); var pointer=IntPtr.Zero;
        try {
            if(inherit) { pointer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Security))); Marshal.StructureToPtr(sa,pointer,false); }
            var desktop=CreateDesktopW(name,IntPtr.Zero,IntPtr.Zero,0,0xF01FF,pointer);
            if(desktop==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Create hidden desktop failed");
            return desktop;
        } finally { if(pointer!=IntPtr.Zero) Marshal.FreeHGlobal(pointer); }
    }
    public static IntPtr DriverDesktop(string station,string desktop,bool actionOnly) {
        if(ObjectName(GetProcessWindowStation())!=station || ObjectName(GetThreadDesktop(GetCurrentThreadId()))!=desktop) throw new Exception("Driver station/desktop mismatch");
        if(actionOnly) {
            var input=OpenInputDesktop(0,false,1);
            if(input==IntPtr.Zero) throw new Win32Exception();
            try { if(station!="WinSta0" || ObjectName(input)==desktop || !desktop.StartsWith("noctty-pkg74-",StringComparison.Ordinal)) throw new Exception("Action-only desktop is not hidden"); }
            finally { CloseDesktop(input); }
        } else AssertStation(station);
        var handle=OpenDesktopW(desktop,0,false,0x41);
        if(handle==IntPtr.Zero) throw new Win32Exception(); return handle;
    }
    static IntPtr FileHandle(string path,bool input) {
        var sa=Inheritable();
        bool device=path=="NUL" || path=="CONOUT$" || path=="CONIN$";
        var h=CreateFileW(path,input?0x80000000u:0x40000000u,7,ref sa,(input || device)?3u:2u,0x80,IntPtr.Zero);
        if(h==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Capture open failed: "+Path.GetFileName(path));
        return h;
    }
    static Task<string> Drain(IntPtr handle) {
        return Task.Run(()=> {
            using(var stream=new FileStream(new SafeFileHandle(handle,true),FileAccess.Read,4096,false))
            using(var reader=new StreamReader(stream,new UTF8Encoding(false,true))) return reader.ReadToEnd();
        });
    }
    // mode: files, pipes, blocked (undrained stdout pipe), console, or none.
    // flags always include CREATE_SUSPENDED; console callers deliberately inherit
    // the CREATE_NO_WINDOW driver's private console. Never create a visible one.
    public static Child Launch(string image,string raw,string cwd,string desktop,string mode,string input,string output,string error,uint flags) {
        if(String.IsNullOrEmpty(desktop) || (desktop.StartsWith("WinSta0\\",StringComparison.OrdinalIgnoreCase) && !desktop.StartsWith("WinSta0\\noctty-pkg74-",StringComparison.Ordinal))) throw new Exception("An explicit isolated desktop is required");
        IntPtr stdin=IntPtr.Zero,stdout=IntPtr.Zero,stderr=IntPtr.Zero,outRead=IntPtr.Zero,errRead=IntPtr.Zero;
        var pi=new ProcessInfo(); bool created=false;
        try {
            var si=new Startup { cb=Marshal.SizeOf(typeof(Startup)),desktop=desktop,flags=1,show=0 };
            if(mode=="none") { si.flags|=0x100; si.input=new IntPtr(-1); si.output=new IntPtr(-1); si.error=new IntPtr(-1); }
            if(mode!="none") {
                stdin=FileHandle(String.IsNullOrEmpty(input)?"NUL":input,true);
                if(mode=="pipes" || mode=="blocked") {
                    var sa=Inheritable(); Check(CreatePipe(out outRead,out stdout,ref sa,4096)); Check(SetHandleInformation(outRead,1,0));
                    Check(CreatePipe(out errRead,out stderr,ref sa,4096)); Check(SetHandleInformation(errRead,1,0));
                } else if(mode=="console") {
                    stdout=FileHandle("CONOUT$",false); stderr=FileHandle("CONOUT$",false);
                } else { stdout=FileHandle(output,false); stderr=FileHandle(error,false); }
                si.flags|=0x100; si.input=stdin; si.output=stdout; si.error=stderr;
            }
            if(!CreateProcessW(image,new StringBuilder(Quote(image)+" "+raw),IntPtr.Zero,IntPtr.Zero,mode!="none",flags|4,IntPtr.Zero,cwd,ref si,out pi)) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateProcessW failed: "+Path.GetFileName(image));
            created=true;
            long born,exited,kernel,user; Check(GetProcessTimes(pi.process,out born,out exited,out kernel,out user));
            var child=new Child { Handle=pi.process,Pid=pi.pid,Created=born,Image=Path.GetFullPath(image) };
            Verify(child);
            if(mode=="pipes") { child.Output=Drain(outRead); outRead=IntPtr.Zero; }
            if(mode=="blocked") { child.OutputRead=outRead; outRead=IntPtr.Zero; }
            if(errRead!=IntPtr.Zero) { child.Error=Drain(errRead); errRead=IntPtr.Zero; }
            if(ResumeThread(pi.thread)==0xFFFFFFFF) throw new Win32Exception();
            return child;
        } catch { if(created) { TerminateProcess(pi.process,0xD20); CloseHandle(pi.process); } throw; }
        finally {
            if(pi.thread!=IntPtr.Zero) CloseHandle(pi.thread);
            foreach(var h in new[]{stdin,stdout,stderr,outRead,errRead}) if(h!=IntPtr.Zero) CloseHandle(h);
        }
    }
    public static void Verify(Child child) {
        long born,exit,kernel,user; Check(GetProcessTimes(child.Handle,out born,out exit,out kernel,out user));
        if(GetProcessId(child.Handle)!=child.Pid || born!=child.Created) throw new Exception("Owned process identity mismatch");
        if(!child.Exited) {
            var image=new StringBuilder(32768); uint size=(uint)image.Capacity;
            Check(QueryFullProcessImageNameW(child.Handle,0,image,ref size));
            if(!String.Equals(Path.GetFullPath(image.ToString()),child.Image,StringComparison.OrdinalIgnoreCase)) throw new Exception("Owned image identity mismatch");
        }
    }
    public static uint Buffered(Child child) { uint available; Check(PeekNamedPipe(child.OutputRead,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero)); return available; }
    public static void CtrlC(Child child) {
        Verify(child); var processes=new uint[256]; var count=GetConsoleProcessList(processes,256);
        if(count==0 || count>256 || Array.IndexOf(processes,child.Pid)<0) throw new Exception("CLI is not attached to the driver's console");
        Check(SetConsoleCtrlHandler(Control,true));
        // CTRL_C_EVENT is sent to this private console, never via GUI input.
        Check(GenerateConsoleCtrlEvent(0,0));
    }
    public static bool HasConsole() { return GetConsoleProcessList(new uint[1],1)!=0; }
    public static string ConsoleText() {
        var h=FileHandle("CONOUT$",true);
        try { var text=new char[32768]; uint read; Check(ReadConsoleOutputCharacterW(h,text,(uint)text.Length,0,out read)); return new string(text,0,(int)read); }
        finally { CloseHandle(h); }
    }
    public static IntPtr[] Windows(IntPtr desktop,string className) {
        var windows=new List<IntPtr>();
        bool ok=EnumDesktopWindows(desktop,(h,p)=> { var name=new StringBuilder(256); GetClassNameW(h,name,256); if(name.ToString()==className) windows.Add(h); return true; },IntPtr.Zero);
        int error=Marshal.GetLastWin32Error();
        if(!ok && error!=0) throw new Win32Exception(error,"EnumDesktopWindows failed");
        return windows.ToArray();
    }
    public static string Title(IntPtr window) { var name=new StringBuilder(1024); GetWindowTextW(window,name,1024); return name.ToString(); }
    public static Child WindowProcess(IntPtr window,string image) {
        uint pid; GetWindowThreadProcessId(window,out pid);
        return OwnedProcess(pid,image);
    }
    public static Child OwnedProcess(uint pid,string image) {
        var h=OpenProcess(0x101001,false,pid); if(h==IntPtr.Zero) throw new Win32Exception();
        try {
            long born,exit,kernel,user; Check(GetProcessTimes(h,out born,out exit,out kernel,out user));
            var child=new Child { Handle=h,Pid=pid,Created=born,Image=Path.GetFullPath(image) }; Verify(child); return child;
        } catch { CloseHandle(h); throw; }
    }
}
