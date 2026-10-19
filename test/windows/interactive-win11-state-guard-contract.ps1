# Scratch-only controls. This script never launches noctty or reads real state.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-state-guard.ps1')

function Assert-Control {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-state-guard-contract-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$passed = 0
function New-Control {
    param([string] $Name, [scriptblock] $Reader = { [uint32] 17 })
    $root = Join-Path $scratch $Name
    $local = Join-Path $root 'local'
    $roaming = Join-Path $root 'roaming'
    $logs = Join-Path $root 'logs'
    $destinations = Join-Path $roaming 'Microsoft\Windows\Recent\CustomDestinations'
    New-Item -ItemType Directory -Force -Path (Join-Path $local 'noctty'), $destinations, $logs | Out-Null
    $startup = Join-Path $local 'noctty\startup-attempts.json'
    $product = Join-Path $destinations 'c2214d6ebc43ff3f.customDestinations-ms'
    [IO.File]::WriteAllText($startup, 'synthetic-startup')
    [IO.File]::WriteAllText($product, 'synthetic-product')
    return [pscustomobject]@{
        Root = $root; Local = $local; Roaming = $roaming; Logs = $logs
        Startup = $startup; Product = $product; Destinations = $destinations; Reader = $Reader
        Measure = Join-Path $destinations '251fcb42973017e3.customDestinations-ms'
    }
}
function Start-Control {
    param($Control)
    return Start-InteractiveWin11StateGuard -Harness 'scratch-state-control' -ReceiptDirectory $Control.Logs -LocalAppDataRoot $Control.Local -RoamingAppDataRoot $Control.Roaming -ClipboardSequenceReader $Control.Reader
}
function Assert-GuardFails {
    param($Guard, [string] $Expected)
    $message = ''
    try { Assert-InteractiveWin11StateGuard -Guard $Guard } catch { $message = $_.Exception.Message }
    Assert-Control ($message -like "*$Expected*") "Expected guard failure: $Expected"
}
try {
    $case = New-Control 'noop'
    $guard = Start-Control $case
    Assert-InteractiveWin11StateGuard $guard
    $receipt = Get-Content -LiteralPath (Join-Path $case.Logs 'state-after.json') -Raw | ConvertFrom-Json
    Assert-Control ($receipt.ClipboardBefore -eq 17 -and $receipt.ClipboardAfter -eq 17) 'No-op receipt lacks clipboard counters.'
    Assert-Control (Test-Path -LiteralPath (Join-Path $case.Logs 'state-before.json')) 'No-op lacks before receipt.'
    $passed++

    foreach ($name in @('Startup', 'Product')) {
        foreach ($kind in @('size', 'mtime')) {
            $case = New-Control "$name-$kind"
            $guard = Start-Control $case
            $path = $case.$name
            if ($kind -eq 'size') {
                $oldTime = [IO.File]::GetLastWriteTimeUtc($path)
                [IO.File]::AppendAllText($path, '-size-control')
                [IO.File]::SetLastWriteTimeUtc($path, $oldTime)
            } else {
                [IO.File]::SetLastWriteTimeUtc($path, [IO.File]::GetLastWriteTimeUtc($path).AddSeconds(-30))
            }
            $expected = if ($name -eq 'Product') { 'ProductJumpList metadata changed' } else { 'Startup metadata changed' }
            Assert-GuardFails $guard $expected
            $passed++
        }
    }

    $sequence = [pscustomobject]@{ Value = [uint32] 70 }
    $reader = { $sequence.Value }.GetNewClosure()
    $case = New-Control 'clipboard' $reader
    $guard = Start-Control $case
    $sequence.Value = [uint32] 71
    Assert-GuardFails $guard 'Clipboard sequence changed'
    $receipt = Get-Content -LiteralPath (Join-Path $case.Logs 'state-after.json') -Raw | ConvertFrom-Json
    Assert-Control ($receipt.ClipboardBefore -eq 70 -and $receipt.ClipboardAfter -eq 71) 'Changed clipboard counters not retained.'
    $passed++

    $case = New-Control 'created'
    $unrelated = Join-Path $case.Destinations 'unrelated.customDestinations-ms'
    $guard = Start-Control $case
    [IO.File]::WriteAllText($case.Measure, 'synthetic-measure')
    [IO.File]::WriteAllText($unrelated, 'synthetic-unrelated')
    Assert-InteractiveWin11StateGuard $guard
    Assert-Control (-not (Test-Path -LiteralPath $case.Measure)) 'Batch-created measurement file was not removed.'
    Assert-Control (Test-Path -LiteralPath $unrelated) 'An unrelated file was removed.'
    $receipt = Get-Content -LiteralPath (Join-Path $case.Logs 'state-after.json') -Raw | ConvertFrom-Json
    Assert-Control ($receipt.MeasureCleanup -eq 'removed-batch-created' -and $receipt.After.MeasureJumpList.CreationTimeUtc) 'Cleanup receipt lacks creation UTC.'
    $passed++

    $case = New-Control 'invariant-time'
    $guard = Start-Control $case
    [IO.File]::WriteAllText($case.Measure, 'synthetic-measure')
    $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ar-SA')
        Assert-InteractiveWin11StateGuard $guard
        Assert-Control (-not (Test-Path -LiteralPath $case.Measure)) 'Invariant timestamp cleanup failed under ar-SA.'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
    $passed++

    $case = New-Control 'preexisting'
    [IO.File]::WriteAllText($case.Measure, 'preexisting')
    $guard = Start-Control $case
    [IO.File]::AppendAllText($case.Measure, '-written-during-batch')
    Assert-InteractiveWin11StateGuard $guard
    Assert-Control (Test-Path -LiteralPath $case.Measure) 'Preexisting measurement file was removed.'
    $passed++

    foreach ($kind in @('creation', 'write')) {
        $case = New-Control "outside-$kind"
        $guard = Start-Control $case
        [IO.File]::WriteAllText($case.Measure, 'outside-interval')
        if ($kind -eq 'creation') { [IO.File]::SetCreationTimeUtc($case.Measure, [DateTime]::UtcNow.AddMinutes(-5)) }
        else { [IO.File]::SetLastWriteTimeUtc($case.Measure, [DateTime]::UtcNow.AddMinutes(-5)) }
        Assert-GuardFails $guard 'cleanup ownership is uncertain'
        Assert-Control (Test-Path -LiteralPath $case.Measure) 'Outside-interval measurement file was removed.'
        $passed++
    }

    # A finalizer failure must not skip the second protected file or clipboard.
    $case = New-Control 'multiple-failures'
    $guard = Start-Control $case
    [IO.File]::AppendAllText($case.Startup, 'changed')
    [IO.File]::AppendAllText($case.Product, 'changed')
    Assert-GuardFails $guard 'Startup metadata changed*ProductJumpList metadata changed'
    $passed++

    $case = New-Control 'reparse'
    $target = Join-Path $case.Root 'junction-target'
    $link = Join-Path $case.Local 'linked'
    New-Item -ItemType Directory -Path $target | Out-Null
    $junctionCreated = $false
    try { New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null; $junctionCreated = $true }
    catch { Write-Host 'state guard reparse control: SKIP (junction creation unavailable)' }
    if ($junctionCreated) {
        try {
            $message = ''
            try { Get-InteractiveWin11StateMetadata (Join-Path $link 'absent.json') | Out-Null } catch { $message = $_.Exception.Message }
            Assert-Control ($message -like '*reparse point*') 'Ancestor reparse path was accepted.'
            $passed++
        } finally { [IO.Directory]::Delete($link) }

        $guard = Start-Control $case
        New-Item -ItemType Junction -Path $case.Measure -Target $target -ErrorAction Stop | Out-Null
        try {
            Assert-GuardFails $guard 'MeasureJumpList metadata inspection failed*reparse point'
            Assert-Control (Test-Path -LiteralPath $case.Measure) 'Reparse measurement path was deleted.'
            Assert-Control (Test-Path -LiteralPath $target) 'Reparse target was deleted.'
            $passed++
        } finally { [IO.Directory]::Delete($case.Measure) }
    }

    # Execute only the composite's extracted finally block, with local stubs.
    # Parsing the composite does not execute its launch/build statements.
    $composite = Join-Path $PSScriptRoot 'interactive-win11-validate.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($composite, [ref]$tokens, [ref]$parseErrors)
    Assert-Control ($parseErrors.Count -eq 0) 'Composite parser errors.'
    $outer = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    Assert-Control ($outer.Count -eq 1) 'Expected one outer composite try/finally.'
    $body = $outer[0].Finally.Extent.Text
    $finalizer = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
    function Invoke-FinalizerControl {
        $windowsHarnessStateGuard = [pscustomobject]@{}
        $windowsHarnessHistoryGuard = [pscustomobject]@{}
        $originalMeasureAumid = $env:NOCTTY_INTERACTIVE_MEASURE_AUMID
        $savedMeasureAumid = 'state-control-original'
        $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
        $called = [Collections.Generic.List[string]]::new()
        function Assert-InteractiveWin11StateGuard { param($Guard) $called.Add('state'); throw 'state-control-failure' }
        function Assert-WindowsHarnessHistoryGuard { param($Guard) $called.Add('history'); throw 'history-control-failure' }
        $message = ''
        try {
            try { & $finalizer } catch { $message = $_.Exception.Message }
            Assert-Control (($called -join ',') -eq 'state,history') 'Composite skipped a guard after a failure.'
            Assert-Control ($message -like '*state-control-failure*history-control-failure*') 'Composite lost a guard failure.'
            Assert-Control ($env:NOCTTY_INTERACTIVE_MEASURE_AUMID -ceq $savedMeasureAumid) 'Composite did not restore measure environment.'
        } finally { $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = $originalMeasureAumid }
    }
    Invoke-FinalizerControl
    $passed++
    Write-Host "interactive-win11 state guard contracts: PASS ($passed controls; scratch-only)"
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -cne $expectedParent -or [IO.Path]::GetFileName($resolved) -notlike 'noctty-state-guard-contract-*') {
        throw 'Refusing unexpected scratch cleanup root.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
