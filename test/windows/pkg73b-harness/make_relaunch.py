r"""MEASUREMENT ONLY (PKG-73b): relaunch-probe.ps1 from contend-probe.ps1.

`-Relaunch` reuses an existing Run directory made by an earlier run of this
probe: the same portable noctty path (so a per-executable driver shader
cache is warm) and the same redirected AppData. The earlier run's trace
files move to `launch-<n>\` first. `-Env NAME=VALUE` entries reach noctty's
environment (for env-gated measurement switches).
"""
import pathlib

here = pathlib.Path(__file__).parent
s = (here / "contend-probe.ps1").read_bytes().decode("utf-8").replace("\r\n", "\n")


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)


rep("    [switch] $VsyncSync\n)", "    [switch] $VsyncSync,\n    [switch] $Relaunch,\n    [string[]] $Env = @()\n)\n# pwsh -File hands a [string[]] one comma-joined string.\n$Env=@($Env | ForEach-Object { $_ -split ',' } | Where-Object { $_ })")
rep("""    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
    $before=Startup-Fingerprint
    if($before.Hash -ne $BaselineHash) { throw 'Real startup-attempts.json differs from the adopted baseline; not launching.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $portable=Join-Path $Run 'app\\bin'; [void](New-Item -ItemType Directory -Path $portable)
    Get-ChildItem -LiteralPath $Bin -File | Where-Object { $_.Extension -in '.exe','.dll' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'app\\share') -Recurse }
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    Copy-Item -LiteralPath $Echo -Destination (Join-Path $Run 'lat-echo.exe')
    foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }""",
"""    $before=Startup-Fingerprint
    if($before.Hash -ne $BaselineHash) { throw 'Real startup-attempts.json differs from the adopted baseline; not launching.' }
    $portable=Join-Path $Run 'app\\bin'
    if($Relaunch) {
        if(-not (Test-Path -LiteralPath (Join-Path $portable 'noctty.portable'))) { throw 'Relaunch needs a Run made by this probe.' }
        $n=1; while(Test-Path -LiteralPath (Join-Path $Run "launch-$n")) { $n++ }
        $keep=Join-Path $Run "launch-$n"; [void](New-Item -ItemType Directory -Path $keep)
        foreach($f in 'latency.txt','render.json','driver.log','probes.txt','startup-state.json','gldiag.txt','threads.txt') { $src=Join-Path $Run $f; if(Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $keep } }
    } else {
        if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
        if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
        [void](New-Item -ItemType Directory -Path $Run)
        [void](New-Item -ItemType Directory -Path $portable)
        Get-ChildItem -LiteralPath $Bin -File | Where-Object { $_.Extension -in '.exe','.dll' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
        $share=Join-Path (Split-Path -Parent $Bin) 'share'
        if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'app\\share') -Recurse }
        Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
        Copy-Item -LiteralPath $Echo -Destination (Join-Path $Run 'lat-echo.exe')
        foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
    }""")
rep("""    $saved=@{}; foreach($k in 'LOCALAPPDATA',""", """    $envNames=@($Env | ForEach-Object { $_.Split('=',2)[0] })
    $saved=@{}; foreach($k in @($envNames)+@('LOCALAPPDATA',""")
rep("""'NOCTTY_LAT_VSYNC_SYNC') { $saved[$k]""", """'NOCTTY_LAT_VSYNC_SYNC')) { $saved[$k]""")
rep("""        if($VsyncSync) { $env:NOCTTY_LAT_VSYNC_SYNC='1' } else { $env:NOCTTY_LAT_VSYNC_SYNC=$null }""",
    """        if($VsyncSync) { $env:NOCTTY_LAT_VSYNC_SYNC='1' } else { $env:NOCTTY_LAT_VSYNC_SYNC=$null }
        $env:NOCTTY_GLDIAG_FILE=Join-Path $Run 'gldiag.txt'
        foreach($kv in $Env) { $pair=$kv.Split('=',2); [Environment]::SetEnvironmentVariable($pair[0],$pair[1]) }""")
rep("'NOCTTY_RENDER_TRACE_LIVE',", "'NOCTTY_RENDER_TRACE_LIVE','NOCTTY_GLDIAG_FILE',")
rep("    Remove-Item -LiteralPath $flood\n", "    for($i=0;$i -lt 20;$i++) { try { Remove-Item -LiteralPath $flood; break } catch { Start-Sleep -Milliseconds 250 } }\n")
rep("""    Log "trace bytes=$last"
""", """    Log "trace bytes=$last"
    # Thread list (start time, start module+offset); Q maps QPC to UTC.
    try {
        $proc=[Diagnostics.Process]::GetProcessById($p.pid)
        $mods=@($proc.Modules | ForEach-Object { [pscustomobject]@{N=$_.ModuleName;B=[int64]$_.BaseAddress;E=[int64]$_.BaseAddress+$_.ModuleMemorySize} })
        $lines=@("Q $([Diagnostics.Stopwatch]::GetTimestamp()) $([datetime]::UtcNow.Ticks) $([Diagnostics.Stopwatch]::Frequency)", "P $($proc.StartTime.ToUniversalTime().Ticks)")
        foreach($th in $proc.Threads) {
            $a=[int64]$th.StartAddress; $m=$mods | Where-Object { $a -ge $_.B -and $a -lt $_.E } | Select-Object -First 1
            $where=if($m){ $m.N+'+0x'+('{0:x}' -f ($a-$m.B)) } else { '0x{0:x}' -f $a }
            $lines+="T $($th.StartTime.ToUniversalTime().Ticks) $where $($th.Id)"
        }
        Set-Content -LiteralPath (Join-Path $Run 'threads.txt') -Value $lines
    } catch { Log "threads: $_" }
""")
rep("""        Copy-Item -LiteralPath $Echo -Destination (Join-Path $Run 'lat-echo.exe')
""", """        Copy-Item -LiteralPath $Echo -Destination (Join-Path $Run 'lat-echo.exe')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'stacksamp.exe') -Destination (Join-Path $Run 'stacksamp.exe')
""")
rep("""    if($h -eq [IntPtr]::Zero) { throw 'noctty surface not found.' }
""", """    if($h -eq [IntPtr]::Zero) { throw 'noctty surface not found.' }
    if($env:PKG73_SAMPLE_MS) {
        $sexe=Join-Path $Run 'stacksamp.exe'
        $scmd="`"$sexe`" $($p.pid) $($env:PKG73_SAMPLE_MS) 2 `"$(Join-Path $Run 'stacks.txt')`""
        [void][Lat]::Launch($sexe,$scmd,$Run,"WinSta0\\$([Lat]::DesktopName())",$job,[uint32]0x08000000)
        Log 'sampler started'
    }
""")
rep("'gldiag.txt','threads.txt')", "'gldiag.txt','threads.txt','stacks.txt')")
rep("""    $probes=[Lat]::Probe($host2,7,12000)
""", """    if($env:PKG73_NEWTAB_MS) {
        # New tabs (WM_COMMAND 1904 to the host) at the given offsets.
        $probes=@(); $done=0
        foreach($t in ($env:PKG73_NEWTAB_MS -split ';')) {
            $probes+=[Lat]::Probe($host2,7,[int]$t-$done); $done=[int]$t
            [void][Lat]::PostMessageW($host2,0x0111,[IntPtr]1904,[IntPtr]::Zero); Log "posted new tab at $t"
        }
        $probes+=[Lat]::Probe($host2,7,[Math]::Max(1000,12000-$done))
    } else {
        $probes=[Lat]::Probe($host2,7,12000)
    }
""")
rep("""    else { $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$cmdexe`" /d /c type `"$flood`"" }
""", """    elseif($env:PKG73_QUIET) { $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$cmdexe`" /d /k echo ready" }
    else { $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$cmdexe`" /d /c type `"$flood`"" }
""")
(here / "relaunch-probe.ps1").write_bytes(s.encode("utf-8"))
print("ok")
