"""MEASUREMENT ONLY (LAT-02): build anim-probe.ps1 from lat-driver2.ps1.

The outer half (portable copy, private desktop, AppData redirection, baseline
check) is reused unchanged. The outer half copies -Echo into the run dir as
lat-echo.exe; pass anim.exe there. The driver runs it inside noctty as
`anim.exe <fps> <seconds> anim.txt ready`, with fps from -DelayMs and the
duration from -Count, waits for it, and asks noctty for its traces.
"""
import pathlib

here = pathlib.Path(__file__).parent
src = (here / "lat-driver2.ps1").read_text(encoding="utf-8")
head, _ = src.split("# --- Driver, on the private desktop ---", 1)

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
    $animLog=Join-Path $Run 'anim.txt'; $ready=Join-Path $Run 'anim-ready.txt'
    $args2=@('--window-save-state=never','--confirm-close-surface=false','--auto-update=off','--window-width=100','--window-height=30','--window-position-x=200','--window-position-y=200')
    $exe=Join-Path $Bin 'noctty.exe'
    $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$(Join-Path $Run 'lat-echo.exe')`" $DelayMs $Count `"$animLog`" `"$ready`""
    Log "launch: $cmd"
    $p=[Lat]::Launch($exe,$cmd,$Run,"WinSta0\$([Lat]::DesktopName())",$job,[uint32]2147483648)
    $deadline=[datetime]::UtcNow.AddSeconds(30); $h=[IntPtr]::Zero
    while([datetime]::UtcNow -lt $deadline) {
        $h=[Lat]::Surface($p.pid)
        if($h -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $ready)) { break }
        Start-Sleep -Milliseconds 100
    }
    if($h -eq [IntPtr]::Zero) { throw 'noctty surface not found.' }
    if(-not (Test-Path -LiteralPath $ready)) { throw 'anim never became ready.' }
    Start-Sleep -Milliseconds (1500 + 1000 * $Count + 1000)
    $trace=Join-Path $Run 'latency.txt'
    if(-not [Lat]::PostMessageW($h,0x8008,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'snapshot post failed' }
    $deadline=[datetime]::UtcNow.AddSeconds(10); $last=-1
    while([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if(Test-Path -LiteralPath $trace) { $len=(Get-Item -LiteralPath $trace).Length; if($len -gt 0 -and $len -eq $last) { break }; $last=$len }
    }
    Log "trace bytes=$last"
    [void][Lat]::StopOwnedJob($job)
    exit 0
} catch {
    Log "ERROR $_"
    exit 1
}
'''
(here / "anim-probe.ps1").write_text(head + driver, encoding="utf-8", newline="\n")
print("ok")
