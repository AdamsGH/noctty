#requires -Version 7.0
<#
Host-safe `-Embedding` lifecycle (PKG-76, G050). Windows starts `noctty.exe -Embedding` to hand it a
delegated console (windows.md, "Default terminal"). This starts the same process with nothing to
hand it and checks what an idle handoff server does to a user's data:

  * it opens no window of its own and exits by itself once its five-second idle timer expires, with
    exit code 0 (the log line "terminal handoff server idle timeout" is the evidence of the path);
  * every state file that already existed is byte-identical afterwards: session-state.json,
    palette-mru.txt, update-state.json, jump-list-recents.json, startup-attempts.json and
    config.ghostty, in the portable directory and in the redirected LOCALAPPDATA\noctty;
  * nothing is quarantined (no *.corrupt* sibling) and no recovery ledger is created;
  * the Windows console delegation values in HKCU\Console\%%Startup are unchanged (read, never written).

It never changes the delegation registry, registers a COM class in the registry, or delivers a
handoff. Journeys that need a delegation change (show state, title, elevated consoles, unregister
residue) are not covered here; they need a machine that can be restored.

Run with -Bin <directory holding noctty.exe and its sibling files> -Run <new evidence directory>. The
binary must carry the measurement AUMID unless -AllowProductAumid is given (an ephemeral CI runner).
Exit 1 when a check fails. Opt in: nothing runs it automatically.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [switch] $AllowProductAumid,
    # Starts an ordinary instance instead, to show the oracle is not vacuous: it must open a host window.
    [switch] $NegativeControl,
    [ValidateRange(30, 600)] [int] $DriverTimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-lib.ps1')

if (-not $Driver) {
    Assert-MeasureAumid (Join-Path (Resolve-Path -LiteralPath $Bin).Path 'noctty.exe') -AllowProductAumid:$AllowProductAumid
    $extra = @(); if ($AllowProductAumid) { $extra += '-AllowProductAumid' }; if ($NegativeControl) { $extra += '-NegativeControl' }
    Invoke-HiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds -ExtraArguments $extra -Label 'Hidden embedding idle'
    exit
}

$desktopName = [HiddenWin]::CurrentDesktopName()
if (-not $desktopName.StartsWith('noctty-hw-')) { throw "Driver is not on its own desktop (found '$desktopName')." }
$job = [HiddenWin]::CreateOwnedJob()
$checks = [Collections.Generic.List[object]]::new()
function Check([string] $Name, [bool] $Passed, $Expected, $Actual) {
    $checks.Add(@{ Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual })
}
function Hash-Of([string] $Path) { if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null } }

$dir = Join-Path $Run 'embedding\bin'
Copy-PortableBin $Bin $dir
$stateDirs = @($dir, (Join-Path $env:LOCALAPPDATA 'noctty'))
[void](New-Item -ItemType Directory -Force -Path $stateDirs[1])
$session = '{"schema_version":1,"added_later":{"generation":7},"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\Windows","profile":"cmd.exe"}}]}}]}]}'
$seeds = [ordered]@{
    'session-state.json'    = $session
    'palette-mru.txt'       = "new_tab`nopen_config`n"
    'update-state.json'     = '{"schema_version":1}'
    'jump-list-recents.json' = '{"schema_version":1,"recents":[]}'
    'startup-attempts.json' = '{"schema_version":1,"attempts":[]}'
    'config.ghostty'        = "font-size = 13`n"
}
foreach ($stateDir in $stateDirs) {
    foreach ($name in $seeds.Keys) { Set-Content -LiteralPath (Join-Path $stateDir $name) -Value $seeds[$name] -NoNewline -Encoding utf8NoBOM }
}
# The files listed first are the ones a handoff server must leave alone; the ledger and the
# config are seeded only to prove it neither counts a start nor rewrites the config.
$before = @{}
foreach ($stateDir in $stateDirs) { foreach ($name in $seeds.Keys) { $before[(Join-Path $stateDir $name)] = Hash-Of (Join-Path $stateDir $name) } }
$listingBefore = @($stateDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File | ForEach-Object { $_.FullName } })

$startupKey = 'HKCU:\Console\%%Startup'
function Get-Delegation { if (Test-Path -LiteralPath $startupKey) { $p = Get-ItemProperty -LiteralPath $startupKey; return @{ Console = $p.DelegationConsole; Terminal = $p.DelegationTerminal } } return @{ Console = $null; Terminal = $null } }
$delegationBefore = Get-Delegation

$stderr = Join-Path $Run 'embedding\stderr.txt'
$classes = [Collections.Generic.HashSet[string]]::new()
$launchArguments = if ($NegativeControl) { @('--single-instance=false') } else { @('-Embedding', '--single-instance=false') }
$uniqueClass = "--class=noctty-test-pkg76-embedding-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$started = Start-HiddenNoctty -Dir $dir -DesktopName $desktopName -Job $job -StderrPath $stderr -Arguments ($launchArguments + $uniqueClass)
$sw = [Diagnostics.Stopwatch]::StartNew()
$closed = $false
while (-not $started.Process.HasExited -and $sw.Elapsed.TotalSeconds -lt 40) {
    foreach ($class in [HiddenWin]::TopLevelClasses($started.Pid)) { [void]$classes.Add($class) }
    # An ordinary instance has no idle timer: close it once the oracle has had time to see its window.
    if ($NegativeControl -and -not $closed -and $sw.Elapsed.TotalSeconds -gt 8) {
        $closed = $true
        foreach ($h in [HiddenWin]::Hosts($started.Pid)) { [void][HiddenWin]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
    }
    Start-Sleep -Milliseconds 100
}
$exited = $started.Process.HasExited
if (-not $exited) {
    $p = Get-Process -Id $started.Pid -ErrorAction SilentlyContinue
    if ($p -and $p.StartTime -eq $started.StartTime) { Stop-Process -Id $p.Id -Force }
}
$elapsed = $sw.Elapsed.TotalSeconds
$log = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }

Check 'the idle server exits by itself' $exited 'exited' $(if ($exited) { 'exited' } else { 'still running after 40 s' })
$exitCode = if ($exited) { Get-HiddenExitCode $started } else { $null }
Check 'exit code is 0' ($exitCode -eq 0) 0 $exitCode
Check 'it waited out the five-second idle timer' ($elapsed -ge 4.0) '>= 4 s' ([math]::Round($elapsed, 1))
Check 'it reports the idle timeout path' ($log -like '*terminal handoff server idle timeout*') 'terminal handoff server idle timeout' ($log.Length)
Check 'it opens no host window' (-not $classes.Contains('noctty.win32.host')) 'no noctty.win32.host' ($classes -join ',')
foreach ($path in $before.Keys) {
    Check ("unchanged: " + $path.Replace($Run, '<run>')) ((Hash-Of $path) -eq $before[$path]) $before[$path] (Hash-Of $path)
}
$added = @($stateDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File | ForEach-Object { $_.FullName } } | Where-Object { $listingBefore -notcontains $_ -and $_ -notlike '*\stderr.txt' })
Check 'no quarantine file appears' (@($added | Where-Object { $_ -like '*.corrupt*' }).Count -eq 0) 0 (@($added | Where-Object { $_ -like '*.corrupt*' }).Count)
$delegationAfter = Get-Delegation
Check 'console delegation values are unchanged' (($delegationBefore.Console -eq $delegationAfter.Console) -and ($delegationBefore.Terminal -eq $delegationAfter.Terminal)) 'same' 'same or changed (see results)'

@{ Checks = $checks; ElapsedSeconds = $elapsed; WindowClasses = @($classes); FilesAdded = @($added | ForEach-Object { $_.Replace($Run, '<run>') }); Limit = 'No handoff is delivered and no delegation value is changed. The server is started with --single-instance=false and a unique --class for isolation; Windows passes only -Embedding.' } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Run 'embedding-results.json')
$failed = @($checks | Where-Object { -not $_.Passed })
foreach ($f in $failed) { Write-Host ("FAIL {0}: expected {1}, got {2}" -f $f.Name, $f.Expected, $f.Actual) }
Write-Host ("{0} checks, {1} failed; ran {2:N1} s, added: {3}" -f $checks.Count, $failed.Count, $elapsed, (@($added | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
if ($NegativeControl) {
    # The control passes only when the window oracle saw the ordinary instance's host window.
    $fired = @($failed | Where-Object { $_.Name -eq 'it opens no host window' }).Count -eq 1
    Write-Host ("negative control: the window oracle {0}" -f $(if ($fired) { 'fired' } else { 'did NOT fire' }))
    if ($fired) { exit 0 } else { exit 1 }
}
if ($failed.Count) { exit 1 }
