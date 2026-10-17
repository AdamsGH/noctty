#requires -Version 7.0
<#
Budget for the Zig tests that skip themselves (PKG-76, F207).

Some tests return error.SkipZigTest when the machine lacks something: the complex-script shaping tests
load system fonts such as "Arial Unicode MS", which a hosted runner does not have. `zig build test`
reports only a total ("74 skipped"), so a test that starts skipping in CI looks the same as one that
always did, and shaping regressions for Devanagari, Tibetan or Bengali pass unobserved.

This reads the per-test output of the test executable (`ghostty-test.exe`, run directly, prints
`N/M <qualified name>...OK|SKIP|FAIL`) and fails when
  * a test in the guarded family (names starting with `familyPrefix`) skips and is not on the runner's
    allowlist, or
  * the total number of skipped tests is above the runner's `maxTotalSkipped`, or
  * the log is incomplete (fewer lines than the `M` it announces), so a crash cannot pass as a budget.
An allowlisted test that runs is fine: the list is an upper bound, because a developer's machine has
more fonts than a runner. Lower the numbers when a skip goes away; raise them only with a reason in
the commit, since that is the decision this check exists to force.

  pwsh scripts/check-test-skips.ps1 -TestLog ghostty-test.log -Runner windows-2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TestLog,
    [Parameter(Mandatory)] [string] $Runner,
    [string] $BudgetFile = (Join-Path $PSScriptRoot '..\test\windows\test-skip-budget.json'),
    # Print the skipped tests of the guarded family and exit 0, to draft an allowlist for a new runner.
    [switch] $Report
)
$ErrorActionPreference = 'Stop'

$budget = Get-Content -LiteralPath $BudgetFile -Raw | ConvertFrom-Json
if ($budget.schema_version -ne 1) { throw "Unsupported budget schema $($budget.schema_version)." }
$prefix = [string]$budget.familyPrefix
$limits = $budget.runners.$Runner
if (-not $limits -and -not $Report) {
    throw "No budget for runner '$Runner'. Known runners: $(($budget.runners.PSObject.Properties.Name) -join ', ')."
}

$announced = 0
$parsed = [Collections.Generic.List[object]]::new()
foreach ($line in Get-Content -LiteralPath $TestLog) {
    # The runner prints a progress line per test; names contain spaces and may contain dots.
    $match = [regex]::Match($line, '^(\d+)/(\d+) (.*)\.\.\.(OK|SKIP|FAIL)\s*$')
    if (-not $match.Success) { continue }
    $announced = [int]$match.Groups[2].Value
    $parsed.Add([pscustomobject]@{ Index = [int]$match.Groups[1].Value; Name = $match.Groups[3].Value; Result = $match.Groups[4].Value })
}
$problems = [Collections.Generic.List[string]]::new()
if ($parsed.Count -eq 0) { $problems.Add('The log holds no per-test lines; run ghostty-test.exe directly and pass its output.') }
elseif ($parsed.Count -ne $announced) { $problems.Add("The log is incomplete: $($parsed.Count) of $announced tests were reported.") }

$skipped = @($parsed | Where-Object Result -eq 'SKIP')
$family = @($skipped | Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) })
Write-Host ("{0} tests, {1} skipped, {2} of them in '{3}'" -f $parsed.Count, $skipped.Count, $family.Count, $prefix)
if ($Report) {
    foreach ($test in $family) { Write-Host "  $($test.Name)" }
    exit 0
}

$allowed = @($limits.allowedSkips)
foreach ($test in $family) {
    if ($allowed -cnotcontains $test.Name) {
        $problems.Add("A test in '$prefix' skips and is not on the '$Runner' allowlist: $($test.Name)")
    }
}
if ($skipped.Count -gt [int]$limits.maxTotalSkipped) {
    $problems.Add("$($skipped.Count) tests skipped; the '$Runner' budget is $($limits.maxTotalSkipped).")
}
$stale = @($allowed | Where-Object { $name = $_; -not ($skipped | Where-Object { $_.Name -ceq $name }) })
if ($stale.Count -gt 0) {
    Write-Host "Allowlisted but not skipped here ($($stale.Count)); the list can shrink once every runner agrees:"
    foreach ($name in $stale) { Write-Host "  $name" }
}
if ($skipped.Count -lt [int]$limits.maxTotalSkipped) {
    Write-Host "Skipped $($skipped.Count) against a budget of $($limits.maxTotalSkipped); lower maxTotalSkipped if this holds on the runner."
}
foreach ($problem in $problems) { [Console]::Error.WriteLine("SKIP BUDGET: $problem") }
if ($problems.Count -gt 0) { exit 1 }
Write-Host "Skip budget for '$Runner': PASS"
