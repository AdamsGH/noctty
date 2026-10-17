#requires -Version 7.0
<#
PKG-74 / D20 baseline and replacement regression harness (x64 and ARM64).
Requires a measure-AUMID portable directory with noctty.com,
noctty.exe, noctty.portable and share/ghostty. Does not build anything.
Run: ./test/windows/cli-com-forwarder.ps1 -BinDir <portable> -OutputDir <new-dir>
Alternatively -ExePath <portable/noctty.com>. Evidence is retained in OutputDir.

Every harness-created child specifies a private window station's Default
desktop. Console helpers use CREATE_NO_WINDOW; Ctrl+C uses a console event.
No profiles, typed shell commands, clipboard operations or real registration.
ActionOnly explicitly selects a hidden WinSta0 desktop for action-only checks;
it never runs the old shim's no-action child or claims full coverage.
#>
[CmdletBinding()]
param(
    [string] $BinDir,
    [string] $ExePath,
    [Parameter(Mandatory)] [string] $OutputDir,
    [ValidateRange(5,120)] [int] $TimeoutSeconds = 20,
    [ValidateRange(10,100)] [int] $VersionIterations = 10,
    [switch] $Driver,
    [string] $StationName,
    [string] $DesktopName = 'Default',
    [switch] $ActionOnly,
    [switch] $InheritHiddenDesktop,
    [string] $DesktopFixture,
    [switch] $ProveDesktopOnly,
    [switch] $DetachedOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'cli-com-native.cs')

function Get-StateMetadata([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Exists = $false } }
    $item = Get-Item -LiteralPath $Path
    return @{ Exists = $true; Bytes = $item.Length; ModifiedUtc = $item.LastWriteTimeUtc.ToString('o'); Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}
function Assert-Condition([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Wait-Condition([scriptblock] $Condition, [string] $Description) {
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 25
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timeout: $Description"
}
function Read-SharedText([string] $Path) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = [IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

if (-not $Driver) {
    Assert-Condition (-not ($ActionOnly -and $InheritHiddenDesktop)) 'Choose ActionOnly or InheritHiddenDesktop.'
    Assert-Condition (-not $ProveDesktopOnly -or ($InheritHiddenDesktop -and $DesktopFixture)) 'ProveDesktopOnly requires InheritHiddenDesktop and DesktopFixture.'
    if ($DesktopFixture) { $DesktopFixture = (Resolve-Path -LiteralPath $DesktopFixture).Path }
    if ($ExePath) {
        Assert-Condition ([IO.Path]::GetFileName($ExePath) -eq 'noctty.com') 'ExePath must name noctty.com.'
        $BinDir = Split-Path -Parent (Resolve-Path -LiteralPath $ExePath).Path
    }
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($BinDir)) 'Specify BinDir or ExePath.'
    $BinDir = (Resolve-Path -LiteralPath $BinDir).Path
    foreach ($required in @('noctty.com', 'noctty.exe', 'noctty.portable')) {
        Assert-Condition (Test-Path -LiteralPath (Join-Path $BinDir $required)) "Missing portable input: $required"
    }
    $sourceShare = Join-Path $BinDir 'share'
    if (-not (Test-Path -LiteralPath (Join-Path $sourceShare 'ghostty/themes'))) {
        $sourceShare = Join-Path (Split-Path -Parent $BinDir) 'share'
    }
    Assert-Condition (Test-Path -LiteralPath (Join-Path $sourceShare 'ghostty/themes')) 'Missing portable share/ghostty/themes tree.'
    $OutputDir = [IO.Path]::GetFullPath($OutputDir)
    Assert-Condition (-not (Test-Path -LiteralPath $OutputDir)) 'OutputDir must be new; evidence is never reset.'
    [void](New-Item -ItemType Directory -Path $OutputDir)
    $portable = Join-Path $OutputDir 'portable'
    Copy-Item -LiteralPath $BinDir -Destination $portable -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $portable 'share'))) {
        Copy-Item -LiteralPath $sourceShare -Destination (Join-Path $portable 'share') -Recurse
    }
    foreach ($name in @('appdata', 'localappdata', 'home')) {
        [void](New-Item -ItemType Directory -Path (Join-Path $OutputDir $name))
    }
    $class = 'noctty-test-pkg74-' + [guid]::NewGuid().ToString('N')
    # Isolated config supplies identity even for actions whose own options reject
    # GUI flags. Explicit flags are also supplied on the no-action GUI invocation.
    @(
        'single-instance = false'
        "class = $class"
        'renderer = d3d11-warp'
        'confirm-close-surface = false'
        'window-save-state = never'
        'shell-integration = none'
        'command = C:\Windows\System32\cmd.exe /d /q'
    ) | Set-Content -LiteralPath (Join-Path $portable 'config.ghostty') -Encoding utf8NoBOM
    $startupPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty/startup-attempts.json'
    $historyPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt'
    $startupBefore = Get-StateMetadata $startupPath
    $historyBefore = Get-StateMetadata $historyPath
    $clipboardBefore = [ComCliNative]::GetClipboardSequenceNumber()
    $batchStarted = [datetime]::UtcNow
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $station = 'noctty-pkg74-' + [guid]::NewGuid().ToString('N')
    $handles = $null
    $controller = $null
    $saved = @{}
    $failure = $null
    try {
        if ($ActionOnly -or $InheritHiddenDesktop) {
            $DesktopName = $station
            $station = 'WinSta0'
            $handles = @([IntPtr]::Zero, [ComCliNative]::HiddenDesktop($DesktopName, $InheritHiddenDesktop.IsPresent))
        } else { $handles = [ComCliNative]::PrivateDesktop($station) }
        foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'HOME', 'USERPROFILE', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'GHOSTTY_RESOURCES_DIR')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            $value = switch ($name) {
                APPDATA { Join-Path $OutputDir 'appdata' }
                LOCALAPPDATA { Join-Path $OutputDir 'localappdata' }
                GHOSTTY_RESOURCES_DIR { Join-Path $portable 'share/ghostty' }
                default { Join-Path $OutputDir 'home' }
            }
            [Environment]::SetEnvironmentVariable($name, $value)
        }
        $pwsh = (Get-Process -Id $PID).Path
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-BinDir', $portable,
            '-OutputDir', $OutputDir, '-Driver', '-StationName', $station,
            '-DesktopName', $DesktopName, '-TimeoutSeconds', "$TimeoutSeconds", '-VersionIterations', "$VersionIterations")
        if ($ActionOnly) { $arguments += '-ActionOnly' }
        if ($InheritHiddenDesktop) { $arguments += '-InheritHiddenDesktop' }
        if ($ProveDesktopOnly) { $arguments += '-ProveDesktopOnly' }
        if ($DesktopFixture) { $arguments += @('-DesktopFixture', $DesktopFixture) }
        $raw = ($arguments | ForEach-Object { [ComCliNative]::Quote($_) }) -join ' '
        $controller = [ComCliNative]::Launch($pwsh, $raw, $OutputDir, "$station\$DesktopName", 'files', $null,
            (Join-Path $OutputDir 'controller.stdout.txt'), (Join-Path $OutputDir 'controller.stderr.txt'), 0x08000000)
        Assert-Condition ($controller.Wait(($TimeoutSeconds * 12 + $VersionIterations * 5) * 1000)) 'Private controller timed out.'
        Assert-Condition ($controller.ExitCode -eq 0) 'Private controller failed; inspect bounded per-case results.json and private controller capture.'
    } catch { $failure = $_ }
    finally {
        if ($controller) { $controller.Dispose() }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        if ($handles) {
            [void][ComCliNative]::CloseDesktop($handles[1])
            if ($handles[0] -ne [IntPtr]::Zero) { [void][ComCliNative]::CloseWindowStation($handles[0]) }
        }
        $clock.Stop()
        $startupAfter = Get-StateMetadata $startupPath
        $historyAfter = Get-StateMetadata $historyPath
        $clipboardAfter = [ComCliNative]::GetClipboardSequenceNumber()
        $receipt = [ordered]@{
            StartedUtc = $batchStarted.ToString('o'); FinishedUtc = [datetime]::UtcNow.ToString('o'); ElapsedMs = $clock.Elapsed.TotalMilliseconds
            Architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
            StartupBefore = $startupBefore; StartupAfter = $startupAfter
            HistoryBefore = $historyBefore; HistoryAfter = $historyAfter
            ClipboardBefore = $clipboardBefore; ClipboardAfter = $clipboardAfter
            ClipboardUnchanged = $clipboardBefore -eq $clipboardAfter
            StartupUnchanged = ($startupBefore | ConvertTo-Json -Compress) -ceq ($startupAfter | ConvertTo-Json -Compress)
            HistoryUnchanged = ($historyBefore | ConvertTo-Json -Compress) -ceq ($historyAfter | ConvertTo-Json -Compress)
            ComBytes = (Get-Item -LiteralPath (Join-Path $portable 'noctty.com')).Length
            ComSha256 = (Get-FileHash -LiteralPath (Join-Path $portable 'noctty.com')).Hash
            Status = if ($failure) { 'Failed' } else { 'Passed' }
            Failure = if ($failure) { $failure.Exception.Message } else { $null }
            NativeErrorCode = if ($failure -and $failure.Exception.InnerException -is [ComponentModel.Win32Exception]) { $failure.Exception.InnerException.NativeErrorCode } else { $null }
            Coverage = if ($ProveDesktopOnly) { 'Windowless fixture setup proof only; product coverage owed' } elseif ($ActionOnly) { 'ActionOnly; no-action GUI/raw quoting owed' } else { 'Full' }
        }
        $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir 'isolation.json') -Encoding utf8NoBOM
        Assert-Condition ($receipt.StartupUnchanged -and $receipt.HistoryUnchanged) 'Real state metadata changed; stop launches and report.'
        Assert-Condition $receipt.ClipboardUnchanged 'WinSta0 clipboard sequence changed; stop launches and report.'
    }
    if ($failure) { throw $failure }
    Write-Host "COM CLI regression: $(if ($ProveDesktopOnly) { 'DESKTOP SETUP PROOF PASSED; product coverage owed' } elseif ($ActionOnly) { 'ACTION SUBSET PASSED; full coverage owed' } else { 'PASS' }); evidence=$OutputDir"
    return
}

$desktopPath = "$StationName\$DesktopName"
if ($DetachedOnly) { [void][ComCliNative]::FreeConsole() }
$desktopHandle = [ComCliNative]::DriverDesktop($StationName, $DesktopName, ($ActionOnly -or $InheritHiddenDesktop))
@{ Pid = $PID; DetachedOnly = $DetachedOnly.IsPresent; HasConsole = [ComCliNative]::HasConsole(); Desktop = $DesktopName; Station = $StationName } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir "driver-$($DetachedOnly.IsPresent).json") -Encoding utf8NoBOM
$com = Join-Path $BinDir 'noctty.com'
$gui = Join-Path $BinDir 'noctty.exe'
$results = [Collections.Generic.List[object]]::new()
$versionTimes = [Collections.Generic.List[double]]::new()
$script:caseIndex = 0
function Test-Case([string] $Name, [scriptblock] $Test) {
    $started = [datetime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $entry = [ordered]@{ Name = $Name; StartedUtc = $started.ToString('o'); Status = 'Failed'; Passed = $false; ElapsedMs = 0; Detail = $null }
    try { & $Test; $entry.Passed = $true; $entry.Status = 'Passed' }
    catch { $entry.Detail = $_.Exception.Message; throw }
    finally {
        $watch.Stop(); $entry.ElapsedMs = $watch.Elapsed.TotalMilliseconds
        $results.Add([pscustomobject]$entry)
        @{ Cases = @($results); Coverage = if ($ProveDesktopOnly) { 'SetupProofOnly' } elseif ($DetachedOnly) { 'DetachedOnly' } elseif ($ActionOnly) { 'ActionOnly' } else { 'Full' }; VersionIterations = $versionTimes.Count; VersionMedianMs = if ($versionTimes.Count) { ($versionTimes | Sort-Object)[[int][math]::Floor($versionTimes.Count / 2)] } else { $null } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir $(if ($DetachedOnly) { 'detached-results.json' } else { 'results.json' })) -Encoding utf8NoBOM
    }
}
function Invoke-Cli([string] $Raw, [string] $Mode = 'pipes', [string] $InputPath, [uint32] $Flags = 0x08000000) {
    $script:caseIndex++
    $out = Join-Path $OutputDir "case-$script:caseIndex.stdout.txt"
    $err = Join-Path $OutputDir "case-$script:caseIndex.stderr.txt"
    $child = [ComCliNative]::Launch($com, $Raw, $BinDir, $desktopPath, $Mode, $InputPath, $out, $err, $Flags)
    try {
        Assert-Condition ($child.Wait($TimeoutSeconds * 1000)) 'CLI timed out.'
        $stdout = if ($child.Output) { $child.Output.GetAwaiter().GetResult() } elseif (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) } else { '' }
        $stderr = if ($child.Error) { $child.Error.GetAwaiter().GetResult() } elseif (Test-Path -LiteralPath $err) { [IO.File]::ReadAllText($err) } else { '' }
        return @{ Code = $child.ExitCode; Out = $stdout; Err = $stderr }
    } finally { $child.Dispose() }
}
function Assert-Version($Result) {
    Assert-Condition ($Result.Code -eq 0 -and $Result.Out.Contains('Build Config') -and $Result.Out.Contains('- channel:') -and $Result.Err.Length -eq 0) 'Version output/status mismatch.'
}
function Test-NoHandles {
        Assert-Condition (-not [ComCliNative]::HasConsole()) 'No-handle test controller must have no console.'
        $child = [ComCliNative]::Launch($com, '+version', $BinDir, $desktopPath, 'none', $null, $null, $null, 8)
        try {
            Wait-Condition { $child.Exited -or @([ComCliNative]::Windows($desktopHandle, '#32770') | Where-Object { [ComCliNative]::Title($_) -eq 'noctty CLI action failed' }).Count -eq 1 } 'detached action failure or failure dialog'
            if (-not $child.Exited) {
                $dialog = @([ComCliNative]::Windows($desktopHandle, '#32770') | Where-Object { [ComCliNative]::Title($_) -eq 'noctty CLI action failed' })[0]
                Assert-Condition ([ComCliNative]::PostMessageW($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'Private error dialog close failed.'
            }
            Assert-Condition ($child.Wait($TimeoutSeconds * 1000)) 'Detached CLI did not return after closing its dialog.'
            Assert-Condition ($child.ExitCode -eq 1) "Detached CLI failure exit mismatch: $($child.ExitCode)."
        } finally { $child.Dispose() }
}
try {
    if ($ProveDesktopOnly -or ($InheritHiddenDesktop -and -not $DetachedOnly)) {
        Test-Case 'old shim passes inherited hidden desktop to windowless GUI fixture' {
            $fixtureBin = Join-Path $OutputDir 'fixture-bin'
            [void](New-Item -ItemType Directory -Path $fixtureBin)
            Copy-Item -LiteralPath $com -Destination (Join-Path $fixtureBin 'noctty.com')
            $fixtureExe = Join-Path $fixtureBin 'noctty.exe'
            Copy-Item -LiteralPath $DesktopFixture -Destination $fixtureExe
            [IO.File]::WriteAllText((Join-Path $fixtureBin 'noctty.portable'), '')
            $receiptPath = Join-Path $OutputDir 'desktop-fixture.json'
            $savedReceipt = $env:NOCTTY_COM_FIXTURE_RECEIPT
            $env:NOCTTY_COM_FIXTURE_RECEIPT = $receiptPath
            $launcher = $null; $fixtureChild = $null
            try {
                $launcher = [ComCliNative]::Launch((Join-Path $fixtureBin 'noctty.com'), '--single-instance=false --class=noctty-test-pkg74-fixture', $fixtureBin, $desktopPath, 'files', $null,
                    (Join-Path $OutputDir 'fixture-launch.stdout.txt'), (Join-Path $OutputDir 'fixture-launch.stderr.txt'), 0x08000000)
                Assert-Condition ($launcher.Wait(2000) -and $launcher.ExitCode -eq 0) 'Fixture no-action shim failed to return promptly.'
                Wait-Condition { Test-Path -LiteralPath $receiptPath } 'windowless desktop fixture receipt'
                $proof = Read-SharedText $receiptPath | ConvertFrom-Json
                Assert-Condition ($proof.windowless -and $proof.station -ceq $StationName -and $proof.desktop -ceq $DesktopName) 'Windowless fixture desktop/station mismatch.'
                $fixtureChild = [ComCliNative]::OwnedProcess([uint32]$proof.pid, $fixtureExe)
                Assert-Condition (-not $fixtureChild.Exited) 'Fixture did not outlive returning shim.'
                Assert-Condition ($fixtureChild.Wait(5000) -and $fixtureChild.ExitCode -eq 0) 'Windowless fixture did not exit naturally.'
            } finally {
                if ($fixtureChild) { $fixtureChild.Dispose() }; if ($launcher) { $launcher.Dispose() }
                $env:NOCTTY_COM_FIXTURE_RECEIPT = $savedReceipt
            }
        }
        if ($ProveDesktopOnly) { return }
    }
    if ($DetachedOnly) { Test-Case 'detached no-console/no-standard-handles' { Test-NoHandles }; return }
    Test-Case 'detached with stdout/stderr pipes' { Assert-Version (Invoke-Cli '+version' 'pipes' -Flags 8) }
    Test-Case 'detached no-console/no-standard-handles' {
        $pwsh = (Get-Process -Id $PID).Path
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-BinDir', $BinDir,
            '-OutputDir', $OutputDir, '-Driver', '-StationName', $StationName, '-DesktopName', $DesktopName, '-DetachedOnly', '-TimeoutSeconds', "$TimeoutSeconds")
        if ($ActionOnly) { $arguments += '-ActionOnly' }; if ($InheritHiddenDesktop) { $arguments += '-InheritHiddenDesktop' }
        $raw = ($arguments | ForEach-Object { [ComCliNative]::Quote($_) }) -join ' '
        $subcontroller = [ComCliNative]::Launch($pwsh, $raw, $OutputDir, $desktopPath, 'files', $null,
            (Join-Path $OutputDir 'detached-controller.stdout.txt'), (Join-Path $OutputDir 'detached-controller.stderr.txt'), 0x08000000)
        try {
            Assert-Condition ($subcontroller.Wait(($TimeoutSeconds + 10) * 1000) -and $subcontroller.ExitCode -eq 0) 'Console-less no-handle subcontroller failed.'
            $detachedReceipt = Join-Path $OutputDir 'detached-results.json'
            Assert-Condition (Test-Path -LiteralPath $detachedReceipt) 'Console-less subcontroller did not produce its required receipt.'
            $detachedResult = [IO.File]::ReadAllText($detachedReceipt) | ConvertFrom-Json
            Assert-Condition ($detachedResult.Cases.Count -eq 1 -and $detachedResult.Cases[0].Passed) 'Console-less subcontroller did not validate the no-handle case.'
        }
        finally { $subcontroller.Dispose() }
    }
    Test-Case 'stdout file and success exit code' { Assert-Version (Invoke-Cli '+version' 'files') }
    foreach ($mode in @('pipes', 'files')) {
        Test-Case "stderr $mode and failure exit code" {
            $result = Invoke-Cli '+pkg74-invalid-action' $mode
            Assert-Condition ($result.Code -eq 1 -and $result.Out.Length -eq 0 -and $result.Err.Contains('unknown CLI action')) 'Invalid-action stderr/status mismatch.'
        }
    }
    Test-Case 'stdin redirected to file' {
        $input = Join-Path $OutputDir 'stdin.txt'
        [IO.File]::WriteAllText($input, "stdin must not become argv or terminal input`n")
        Assert-Version (Invoke-Cli '+version' 'pipes' $input)
    }
    Test-Case 'Unicode and spaced config-file argument' {
        $config = Join-Path $OutputDir 'config 空間 😀.ghostty'
        [IO.File]::WriteAllText($config, "pkg74-invalid-field = true`n", [Text.UTF8Encoding]::new($false))
        $result = Invoke-Cli ('+validate-config ' + [ComCliNative]::Quote("--config-file=$config"))
        Assert-Condition ($result.Code -eq 1 -and $result.Out.Contains('pkg74-invalid-field') -and $result.Out.Contains('config 空間 😀.ghostty')) 'Unicode path did not reach real config validation.'
    }
    Test-Case 'list-themes with redirected stdout' {
        $result = Invoke-Cli '+list-themes'
        Assert-Condition ($result.Code -eq 0 -and $result.Out.Contains('0x96f (resources)') -and $result.Err.Length -eq 0) 'Plain theme listing mismatch.'
    }
    Test-Case 'list-themes with console stdout stays plain on Windows' {
        $result = Invoke-Cli '+list-themes' 'console' -Flags 0
        Assert-Condition ($result.Code -eq 0 -and [ComCliNative]::ConsoleText().Contains('0x96f (resources)')) 'Console theme listing compatibility mismatch.'
    }
    Test-Case 'Ctrl+C console event interrupts an action blocked on stdout' {
        $child = [ComCliNative]::Launch($com, '+show-config --default --docs --no-pager', $BinDir, $desktopPath, 'blocked', $null, $null, $null, 0)
        try {
            Wait-Condition { -not $child.Exited -and [ComCliNative]::Buffered($child) -ge 4096 } 'real config output fills stdout pipe'
            [ComCliNative]::CtrlC($child)
            Assert-Condition ($child.Wait($TimeoutSeconds * 1000)) 'Ctrl+C did not end the CLI action.'
            Assert-Condition ($child.ExitCode -eq 0xC000013Au) 'Ctrl+C exit code was not STATUS_CONTROL_C_EXIT.'
        } finally { $child.Dispose() }
    }
    for ($iteration = 0; $iteration -lt $VersionIterations; $iteration++) {
        Test-Case "version timing $iteration" {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Assert-Version (Invoke-Cli '+version')
            $watch.Stop(); $versionTimes.Add($watch.Elapsed.TotalMilliseconds)
        }
    }
    if ($ActionOnly) {
        $results.Add([pscustomobject]@{ Name = 'no-action raw quotes and Unicode title opens GUI and returns promptly'; Status = 'Owed'; Passed = $false; ElapsedMs = 0; Detail = 'ActionOnly explicitly excludes GUI launches; run full private-station mode.' })
        Test-Case 'action-only completion' { }
    } else { Test-Case 'no-action raw quotes and Unicode title opens GUI and returns promptly' {
        $config = [IO.File]::ReadAllText((Join-Path $BinDir 'config.ghostty'))
        $class = [regex]::Match($config, '(?m)^class = (.+)$').Groups[1].Value.Trim()
        $raw = '--single-instance=false --class=' + $class + ' --title="D20 ""quoted"" 空間 😀"'
        $child = [ComCliNative]::Launch($com, $raw, $BinDir, $desktopPath, 'files', $null, (Join-Path $OutputDir 'gui.stdout.txt'), (Join-Path $OutputDir 'gui.stderr.txt'), 0x08000000)
        $guiChild = $null
        try {
            Assert-Condition ($child.Wait(5000)) 'No-action shim did not return within 5 seconds.'
            Assert-Condition ($child.ExitCode -eq 0) 'No-action shim returned nonzero.'
            Wait-Condition { @([ComCliNative]::Windows($desktopHandle, 'noctty.win32.host')).Count -eq 1 } 'GUI host on private station desktop'
            $window = @([ComCliNative]::Windows($desktopHandle, 'noctty.win32.host'))[0]
            $guiChild = [ComCliNative]::WindowProcess($window, $gui)
            Wait-Condition { [ComCliNative]::Title($window).Contains('D20 "quoted" 空間 😀') } 'Unicode/doubled-quote title readback'
            Assert-Condition (-not $guiChild.Exited) 'GUI exited together with shim.'
            Assert-Condition ([ComCliNative]::PostMessageW($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) 'WM_CLOSE failed.'
            Assert-Condition ($guiChild.Wait($TimeoutSeconds * 1000)) 'Owned GUI did not close.'
        } finally { if ($guiChild) { $guiChild.Dispose() }; $child.Dispose() }
    } }
} finally {
    [void][ComCliNative]::CloseDesktop($desktopHandle)
}
