#requires -Version 7.0
<#
Profile matrix (PKG-76, G032): launches each shell profile noctty detects through a restored session
on a hidden desktop and checks what the profile really started, with no hook into the terminal core:

  * the spawn command line, read from the process tree under noctty (reduced to a redacted shape);
  * that automatic shell integration was injected (the PowerShell script on the command line);
  * the working directory the shell reports back with OSC 7, read from the session-state.json noctty
    saves when its window closes (a pane's last-known directory is seeded from the launch directory
    and refreshed by OSC 7, see automation.md);
  * that the profile key and directory round trip through that file.

cmd and Git Bash are also sent `pushd` / `cd` as posted keys, so the directory the file ends up with
can only have come from the shell. PowerShell panes are never typed into: a pwsh in a test pane
loads PSReadLine, whose history file is the real user's, and the harness proves it did not change.
Their directory is checked from the first prompt alone, by seeding the session with a path that has
a trailing separator, which a shell reporting its own directory does not.

A control case runs cmd.exe with `shell-integration = none` and expects the seed to survive, so the
directory checks above cannot pass by accident. WSL, SSH and any distribution are never started. A
profile that is not installed is reported as skipped, never as a pass.

Run with -Bin <directory holding noctty.exe, conpty.dll, OpenConsole.exe> -Run <new evidence
directory>. The binary must carry the measurement AUMID unless -AllowProductAumid is given (an
ephemeral CI runner). Exit 1 when a check fails. It never uses SendInput, takes the foreground or
copies anything; the clipboard sequence number is logged before and after.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [switch] $AllowProductAumid,
    [string[]] $Profile = @('cmd.exe', 'powershell.exe', 'pwsh.exe', 'git-bash'),
    [ValidateRange(30, 1800)] [int] $DriverTimeoutSeconds = 420
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-lib.ps1')

if (-not $Driver) {
    Assert-MeasureAumid (Join-Path (Resolve-Path -LiteralPath $Bin).Path 'noctty.exe') -AllowProductAumid:$AllowProductAumid
    $extra = @('-Profile', ($Profile -join ','))
    if ($AllowProductAumid) { $extra += '-AllowProductAumid' }
    Invoke-HiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds -ExtraArguments $extra -Label 'Hidden profile matrix'
    exit
}

# The driver: runs on the new desktop. Children get that desktop explicitly.
$Profile = @($Profile | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$desktopName = [HiddenWin]::CurrentDesktopName()
if (-not $desktopName.StartsWith('noctty-hw-')) { throw "Driver is not on its own desktop (found '$desktopName')." }
$job = [HiddenWin]::CreateOwnedJob()
$checks = [Collections.Generic.List[object]]::new()
$cases = [Collections.Generic.List[object]]::new()
function Check([string] $Case, [string] $Name, [bool] $Passed, $Expected, $Actual) {
    $checks.Add(@{ Case = $Case; Name = $Name; Passed = $Passed; Expected = $Expected; Actual = $Actual })
}
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)

function Test-Available([string] $Key) {
    switch ($Key) {
        'cmd.exe' { return [bool]$env:ComSpec -and (Test-Path -LiteralPath $env:ComSpec) }
        'powershell.exe' { return Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
        'pwsh.exe' { return [bool](Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue) }
        'git-bash' { return Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
        default { return $false }
    }
}
# Each profile (a session pane's `profile` is the key noctty lists it under): the process that must
# appear under noctty, the flags its command line must carry, and for a shell it is safe to type into
# the command that changes directory. `pushd` rather than `cd /d`: a user's AutoRun can define a `cd`
# macro that rejects /d, and this harness runs on machines that have one.
$expectations = @{
    'cmd.exe'        = @{ Name = 'cmd.exe'; Probe = 'echo ready> ready.txt'; Cd = 'pushd "{0}"'; Tokens = @() }
    'powershell.exe' = @{ Name = 'powershell.exe'; Cd = $null; Tokens = @('-NoExit', '-Command', 'integration.ps1') }
    'pwsh.exe'       = @{ Name = 'pwsh.exe'; Cd = $null; Tokens = @('-NoExit', '-Command', 'integration.ps1') }
    'git-bash'       = @{ Name = 'bash.exe'; Probe = 'echo ready> ready.txt'; Cd = "cd '{0}'"; Tokens = @('--login', '-i') }
}

function Start-Case([string] $Key, [string] $Suffix, [string[]] $ExtraConfig) {
    $name = ($Key -replace '[^A-Za-z0-9]', '_') + $Suffix
    $dir = Join-Path $Run "$name\bin"; Copy-PortableBin $Bin $dir
    $work = Join-Path $Run "$name\work"
    # The seed spells the directory with a trailing separator. A shell that reports its own directory
    # drops it, so the saved path differs from the seed only if OSC 7 reached noctty.
    $cwdA = Join-Path $work 'a'; $cwdB = Join-Path $work 'b'
    [void](New-Item -ItemType Directory -Force -Path $cwdA, $cwdB, (Join-Path $Run "$name\home"))
    $seed = $cwdA + '\'
    $node = @{ pane = @{ cwd = $seed; profile = $Key } }
    $session = @{ schema_version = 1; windows = @(@{ selected_tab = 0; tabs = @(@{ selected_leaf = 0; layout = @{ root = 0; nodes = @($node) } }) }) }
    Set-Content -LiteralPath (Join-Path $dir 'session-state.json') -Value ($session | ConvertTo-Json -Depth 12 -Compress) -NoNewline -Encoding utf8NoBOM
    $config = Join-Path $dir 'matrix.ghostty'
    (@('window-save-state = always', 'confirm-close-surface = false', 'single-instance = false', 'auto-update = off', 'window-width = 100', 'window-height = 30') + $ExtraConfig) | Set-Content -LiteralPath $config
    return @{ Key = $Key; Name = $name; Dir = $dir; Cwd = @{ A = $cwdA; B = $cwdB; Seed = $seed }; Config = $config; Home = (Join-Path $Run "$name\home") }
}

function Wait-Ready($Case, $Process) {
    $ledger = Join-Path $Case.Dir 'startup-attempts.json'
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while ([datetime]::UtcNow -lt $deadline -and -not $Process.HasExited) {
        $hosts = @([HiddenWin]::Hosts($Process.Id))
        $ready = $false
        if (Test-Path -LiteralPath $ledger) {
            try {
                $attempts = (Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready = $attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if ($ready -and $hosts.Count) {
            $surfaces = @([HiddenWin]::Surfaces($hosts[0]))
            if ($surfaces.Count -gt 0) { return @{ Host = $hosts[0]; Surface = $surfaces[0] } }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Window startup failed for $($Case.Key)."
}

# One launch. `Control` runs without shell integration and expects the seeded directory to survive.
function Invoke-Case([string] $Key, [switch] $Control) {
    $suffix = if ($Control) { '_control' } else { '' }
    $label = if ($Control) { "$Key (control)" } else { $Key }
    $case = Start-Case $Key $suffix $(if ($Control) { @('shell-integration = none') } else { @() })
    $expected = $expectations[$Key]
    $savedHome = $env:HOME; $savedHistfile = $env:HISTFILE
    # Git Bash takes its home from HOME: keep ~/.bash_history and its profile inside the run.
    $env:HOME = $case.Home; $env:HISTFILE = Join-Path $case.Home '.bash_history'
    $started = $null
    try {
        $started = Start-HiddenNoctty -Dir $case.Dir -DesktopName $desktopName -Job $job -StderrPath (Join-Path $Run "$($case.Name)\stderr.txt") -Arguments @(
            "--config-file=`"$($case.Config)`"", '--single-instance=false', "--class=noctty-test-pkg76-$runId-$($case.Name)")
        $ready = Wait-Ready $case $started.Process
        # The profile's own process appears under noctty (through ConPTY's host).
        $shell = $null; $deadline = [datetime]::UtcNow.AddSeconds(20)
        while ([datetime]::UtcNow -lt $deadline -and -not $shell) {
            $shell = Get-Descendants $started.Pid | Where-Object { $_.Name -ieq $expected.Name } | Select-Object -First 1
            if (-not $shell) { Start-Sleep -Milliseconds 200 }
        }
        Check $label "starts $($expected.Name) under noctty" ($null -ne $shell) $expected.Name ($(if ($shell) { $shell.Name } else { $null }))
        $full = if ($shell) { Get-RedactedCommandLine $shell.CommandLine @($Run) -MaxArgumentLength 4000 -MaxArguments 40 } else { '' }
        $shape = if ($shell) { Get-RedactedCommandLine $shell.CommandLine @($Run) } else { '' }
        if (-not $Control) {
            foreach ($token in $expected.Tokens) { Check $label "command line carries $token" ($full -like "*$token*") $token $shape }
        }
        Check $label 'command line has no -File or /c payload' (($full -notmatch '(^|\s)-File(\s|$)') -and ($full -notmatch '(^|\s)/c(\s|$)')) 'neither' $shape
        # Give the first prompt time to draw and send its OSC 7.
        Start-Sleep -Milliseconds 2500
        if ($expected.Cd -and -not $Control) {
            # A command typed before the shell reads input can be lost, so prove the shell is reading
            # first: it must create a marker before the real commands go in.
            $probe = Join-Path $case.Cwd.A 'ready.txt'
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            while ([datetime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $probe)) {
                Send-Text $ready.Surface $expected.Probe
                Send-Key $ready.Surface 0x0D 13
                Start-Sleep -Milliseconds 1500
            }
            Check $label 'the shell reads typed input' (Test-Path -LiteralPath $probe) 'ready.txt' ''
            Send-Text $ready.Surface ($expected.Cd -f $case.Cwd.B)
            Send-Key $ready.Surface 0x0D 13
            Start-Sleep -Milliseconds 1000
            Send-Text $ready.Surface 'echo ok> typed.txt'
            Send-Key $ready.Surface 0x0D 13
            Start-Sleep -Milliseconds 2000
            Check $label 'the typed command ran in the new directory' (Test-Path -LiteralPath (Join-Path $case.Cwd.B 'typed.txt')) 'typed.txt in b' (@(Get-ChildItem -LiteralPath $case.Cwd.B -Name) -join ',')
        }
        foreach ($h in [HiddenWin]::Hosts($started.Pid)) { [void][HiddenWin]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
        if (-not $started.Process.WaitForExit(15000)) { throw "noctty ($label) did not exit after WM_CLOSE" }
        $saved = Get-Content -LiteralPath (Join-Path $case.Dir 'session-state.json') -Raw | ConvertFrom-Json
        $pane = $saved.windows[0].tabs[0].layout.nodes[0].pane
        Check $label 'the profile key survives a close and save' ($pane.profile -eq $Key) $Key $pane.profile
        if ($Control) {
            Check $label 'without shell integration nothing refreshes the seeded directory' ($pane.cwd -ceq $case.Cwd.Seed) $case.Cwd.Seed $pane.cwd
        } else {
            $want = if ($expected.Cd) { $case.Cwd.B } else { $case.Cwd.A }
            Check $label 'the saved working directory is the one the shell reported' ($pane.cwd -ieq $want) $want $pane.cwd
        }
        $cases.Add(@{ Profile = $label; Result = 'ran'; Shape = $shape })
    } catch {
        Check $label 'harness execution' $false 'no error' $_.Exception.Message
    } finally {
        $env:HOME = $savedHome; $env:HISTFILE = $savedHistfile
        if ($started -and -not $started.Process.HasExited) {
            $p = Get-Process -Id $started.Pid -ErrorAction SilentlyContinue
            if ($p -and $p.StartTime -eq $started.StartTime) { Stop-Process -Id $p.Id -Force }
        }
    }
}

foreach ($key in $Profile) {
    if (-not $expectations.ContainsKey($key)) { throw "Unknown profile '$key'." }
    if (-not (Test-Available $key)) { $cases.Add(@{ Profile = $key; Result = 'skipped'; Reason = 'not installed on this machine' }); continue }
    Invoke-Case $key
}
if ($Profile -contains 'cmd.exe') { Invoke-Case 'cmd.exe' -Control }
$anyRan = @($cases | Where-Object { $_.Result -eq 'ran' }).Count
Check 'matrix' 'at least one profile ran' ($anyRan -gt 0) '>= 1' $anyRan
@{ Checks = $checks; Cases = $cases; Limit = 'Hidden desktop, posted keys only. WSL, SSH and PowerShell panes are not typed into; the directory of a PowerShell pane is checked from its first prompt.' } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'profile-matrix-results.json')
$failed = @($checks | Where-Object { -not $_.Passed })
if ($failed.Count) { exit 1 }
