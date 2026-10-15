"""MEASUREMENT ONLY (LAT-01): build flood-probe.ps1 from lat-driver2.ps1.

The outer half (portable copy, private desktop, AppData redirection, baseline
check) is reused unchanged; the driver half is replaced: noctty runs
`cmd /c type <50 MB file>`, the host gets a jump resize 1.5 s in, and the UI
thread is probed with WM_NULL every 7 ms (the #310 measurement).
"""
import pathlib

here = pathlib.Path(__file__).parent
src = (here / "lat-driver2.ps1").read_text(encoding="utf-8")
head, _ = src.split("# --- Driver, on the private desktop ---", 1)

head = head.replace(
    """    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);""",
    """    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
    [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint t,out IntPtr result);
    // Probes h with WM_NULL every intervalMs for durationMs; returns each probe's round trip in ms.
    public static double[] Probe(IntPtr h,int intervalMs,int durationMs,IntPtr resizeTarget,int resizeAtMs,int w,int hgt) {
        timeBeginPeriod(1);
        var res=new List<double>(); var f=(double)Stopwatch.Frequency;
        long start=Stopwatch.GetTimestamp(); bool resized=false;
        while(true) {
            long now=Stopwatch.GetTimestamp(); double el=(now-start)*1000.0/f;
            if(el>=durationMs) break;
            if(!resized && el>=resizeAtMs) {
                // Jump resize from another thread, so a stalled pump cannot hold the prober.
                var t=new Thread(()=>SetWindowPos(resizeTarget,IntPtr.Zero,0,0,w,hgt,0x0016)); t.IsBackground=true; t.Start();
                resized=true;
            }
            IntPtr r; long a=Stopwatch.GetTimestamp();
            SendMessageTimeoutW(h,0,IntPtr.Zero,IntPtr.Zero,0,20000,out r);
            res.Add((Stopwatch.GetTimestamp()-a)*1000.0/f);
            Thread.Sleep(intervalMs);
        }
        return res.ToArray();
    }""")

driver = r'''# --- Driver, on the private desktop ---
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
    $flood=Join-Path $Run 'flood.txt'
    $line=('0123456789abcdefghijklmnopqrstuvwxyz' * 3)+"`r`n"
    $sb=[Text.StringBuilder]::new(); for($i=0;$i -lt 4096;$i++) { [void]$sb.Append($line) }
    $chunk=[Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $fs=[IO.File]::Create($flood); try { while($fs.Length -lt 50MB) { $fs.Write($chunk,0,$chunk.Length) } } finally { $fs.Dispose() }
    $pos=@('--window-position-x=200','--window-position-y=200')
    $args2=@('--window-save-state=never','--confirm-close-surface=false','--auto-update=off','--window-width=100','--window-height=30')+$pos
    $exe=Join-Path $Bin 'noctty.exe'
    $cmdexe=Join-Path $env:SystemRoot 'System32\cmd.exe'
    $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$cmdexe`" /d /c type `"$flood`""
    Log "launch: $cmd"
    $p=[Lat]::Launch($exe,$cmd,$Run,"WinSta0\$([Lat]::DesktopName())",$job,[uint32]2147483648)
    $deadline=[datetime]::UtcNow.AddSeconds(30); $h=[IntPtr]::Zero
    while([datetime]::UtcNow -lt $deadline) { $h=[Lat]::Surface($p.pid); if($h -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 50 }
    if($h -eq [IntPtr]::Zero) { throw 'noctty surface not found.' }
    $host2=[Lat]::GetAncestor($h,2)
    $probes=[Lat]::Probe($host2,7,12000,$host2,1500,1600,1000)
    Set-Content -LiteralPath (Join-Path $Run 'probes.txt') -Value ($probes | ForEach-Object { $_.ToString('F3',[Globalization.CultureInfo]::InvariantCulture) })
    [void][Lat]::PostMessageW($h,0x8008,[IntPtr]::Zero,[IntPtr]::Zero)
    Start-Sleep -Milliseconds 1500
    [void][Lat]::StopOwnedJob($job)
    exit 0
} catch {
    Log "ERROR $_"
    exit 1
}
'''
(here / "flood-probe.ps1").write_text(head + driver, encoding="utf-8", newline="\n")
print("ok")
