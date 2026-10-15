"""MEASUREMENT ONLY (PKG-38): build contend-probe.ps1 from lat-driver2.ps1.

The outer half (portable copy, private desktop named for every child,
AppData redirection, startup-attempts baseline check) is reused; the driver
half is replaced. noctty runs `cmd /d /c type <50 MB file>` (`-Style plain`:
LAT-01's flood lines; `-Style colour`: a colourised log, about ten SGR runs
per line), optionally loses focus (`-Focus unfocused`: a posted WM_KILLFOCUS
to the terminal child, which runs the surface's focusChanged(false)), the UI
thread is probed with WM_NULL every 7 ms for 12 s (no resize), then the
latency trace is dumped. `-Extra` flags reach noctty
(`--power-saver-rendering=on`).
"""
import pathlib

here = pathlib.Path(__file__).parent
src = (here / "lat-driver2.ps1").read_text(encoding="utf-8").replace("\r\n", "\n")
head, _ = src.split("# --- Driver, on the private desktop ---", 1)


def rep(text, old, new):
    assert text.count(old) == 1, old[:60]
    return text.replace(old, new)


head = rep(head, "[ValidateSet('plain','line','tui')] [string] $Style = 'plain',",
           "[ValidateSet('plain','line','tui','colour')] [string] $Style = 'plain',\n    [ValidateSet('focused','unfocused')] [string] $Focus = 'focused',\n    [ValidateSet('type','fast')] [string] $Writer = 'type',")
head = rep(head, "'-Style',$Style,'-Driver')", "'-Style',$Style,'-Focus',$Focus,'-Writer',$Writer,'-Driver')")
head = rep(head,
    """    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);""",
    """    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint flags);
    [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint t,out IntPtr result);
    // Probes h with WM_NULL every intervalMs for durationMs; returns each probe's round trip in ms.
    public static double[] Probe(IntPtr h,int intervalMs,int durationMs) {
        timeBeginPeriod(1);
        var res=new List<double>(); var f=(double)Stopwatch.Frequency;
        long start=Stopwatch.GetTimestamp();
        while((Stopwatch.GetTimestamp()-start)*1000.0/f < durationMs) {
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
    $sb=[Text.StringBuilder]::new()
    if($Style -eq 'colour') {
        $e=[char]27; $words=@('INFO','request','handled','in','12ms','path=/api/v1/items','status=200','user=alice','bytes=5120','trace=9f3c2a')
        for($i=0;$i -lt 2048;$i++) {
            [void]$sb.Append("$e[2m2026-10-15T08:$('{0:d2}' -f ($i % 60)):00.$('{0:d3}' -f $i)Z$e[0m ")
            for($w=0;$w -lt $words.Count;$w++) { [void]$sb.Append("$e[38;5;$((($i+$w*7) % 200)+16)m$($words[$w])$e[0m ") }
            [void]$sb.Append("`r`n")
        }
    } else {
        $line=('0123456789abcdefghijklmnopqrstuvwxyz' * 3)+"`r`n"
        for($i=0;$i -lt 4096;$i++) { [void]$sb.Append($line) }
    }
    $chunk=[Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $fs=[IO.File]::Create($flood); try { while($fs.Length -lt 50MB) { $fs.Write($chunk,0,$chunk.Length) } } finally { $fs.Dispose() }
    $pos=@('--window-position-x=200','--window-position-y=200')
    $args2=@('--window-save-state=never','--confirm-close-surface=false','--auto-update=off','--window-width=100','--window-height=30')+$pos+$Extra
    $exe=Join-Path $Bin 'noctty.exe'
    $cmdexe=Join-Path $env:SystemRoot 'System32\cmd.exe'
    # -Writer fast: the outer half copied -Echo (fastcat.exe) to lat-echo.exe.
    if($Writer -eq 'fast') { $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$(Join-Path $Run 'lat-echo.exe')`" `"$flood`"" }
    else { $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$cmdexe`" /d /c type `"$flood`"" }
    Log "launch: $cmd"
    $p=[Lat]::Launch($exe,$cmd,$Run,"WinSta0\$([Lat]::DesktopName())",$job,[uint32]2147483648)
    $deadline=[datetime]::UtcNow.AddSeconds(30); $h=[IntPtr]::Zero
    while([datetime]::UtcNow -lt $deadline) { $h=[Lat]::Surface($p.pid); if($h -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 50 }
    if($h -eq [IntPtr]::Zero) { throw 'noctty surface not found.' }
    if($Focus -eq 'unfocused') { Start-Sleep -Milliseconds 200; [void][Lat]::PostMessageW($h,0x0008,[IntPtr]::Zero,[IntPtr]::Zero); Log 'posted WM_KILLFOCUS' }
    $host2=[Lat]::GetAncestor($h,2)
    $probes=[Lat]::Probe($host2,7,12000)
    Set-Content -LiteralPath (Join-Path $Run 'probes.txt') -Value ($probes | ForEach-Object { $_.ToString('F3',[Globalization.CultureInfo]::InvariantCulture) })
    $trace=Join-Path $Run 'latency.txt'
    [void][Lat]::PostMessageW($h,0x8008,[IntPtr]::Zero,[IntPtr]::Zero)
    $deadline=[datetime]::UtcNow.AddSeconds(15); $last=-1
    while([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if(Test-Path -LiteralPath $trace) { $len=(Get-Item -LiteralPath $trace).Length; if($len -gt 0 -and $len -eq $last) { break }; $last=$len }
    }
    Log "trace bytes=$last"
    [void][Lat]::StopOwnedJob($job)
    Remove-Item -LiteralPath $flood
    exit 0
} catch {
    Log "ERROR $_"
    exit 1
}
'''
(here / "contend-probe.ps1").write_bytes((head + driver).encode("utf-8"))
print("ok")
