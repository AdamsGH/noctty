# The hidden-desktop harnesses added for PKG-76 (profile matrix, -Embedding idle) start real
# copies of noctty on a machine somebody uses, and the skip budget decides what CI may skip
# silently. Both are pinned here: the safety rules by what the files may contain, the budget script
# by running it on synthetic logs.
$hiddenLib = Join-Path $repoRoot 'test\windows\hidden-win11-lib.ps1'
$hiddenScripts = @(
    Join-Path $repoRoot 'test\windows\hidden-win11-profile-matrix.ps1'
    Join-Path $repoRoot 'test\windows\hidden-win11-embedding-idle.ps1'
)

# The text of a script without its comments, so a comment cannot satisfy or trip a pattern.
function Remove-PowerShellComments([string] $Text) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'A hidden harness does not parse.' }
    $builder = [Text.StringBuilder]::new($Text)
    foreach ($token in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        [void]$builder.Remove($token.Extent.StartOffset, $token.Extent.EndOffset - $token.Extent.StartOffset)
    }
    return $builder.ToString()
}
$hiddenForbidden = '(?s)\A(?!.*(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|Set-Clipboard|Get-Clipboard|SetClipboardData|Start-Process|Invoke-Item|Register-Default|Remove-Item\s+-Recurse))'
$hiddenLibText = Remove-PowerShellComments (Get-Content -LiteralPath $hiddenLib -Raw)
$hiddenContracts = @(
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)function Assert-MeasureAumid.*?io\.github\.amanthanvi\.noctty\.measure.*?throw'
        Kind = 'Text'
        Description = 'a launch is refused unless the binary carries the measurement AUMID, or the caller says it is an ephemeral runner'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)function Start-HiddenNoctty.*?noctty\.portable.*?throw.*?"WinSta0\\\$DesktopName"'
        Kind = 'Text'
        Description = 'every noctty copy is portable and is started on an explicit desktop'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = $hiddenForbidden
        Kind = 'Text'
        Description = 'the shared hidden-desktop library uses no real input, foreground, clipboard, Start-Process or recursive delete'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)GetClipboardSequenceNumber\(\).*?Clipboard sequence number changed'
        Kind = 'Text'
        Description = 'the clipboard sequence number is compared before and after a run'
    }
    @{
        File = $hiddenLib
        Content = { $hiddenLibText }
        Pattern = '(?s)StartupUnchanged.*?HistoryUnchanged.*?throw.*?real startup-attempts\.json changed.*?PowerShell history file changed'
        Kind = 'Text'
        Description = 'the real recovery ledger and PowerShell history are checked after a run'
    }
)
foreach ($script in $hiddenScripts) {
    $text = Remove-PowerShellComments (Get-Content -LiteralPath $script -Raw)
    $name = Split-Path -Leaf $script
    $hiddenContracts += @{
        File = $script
        Content = $text
        Pattern = '(?s)Assert-MeasureAumid.*?Invoke-HiddenDriver'
        Kind = 'Text'
        Description = "$name checks the AUMID before it starts anything"
    }
    $hiddenContracts += @{
        File = $script
        Content = $text
        Pattern = $hiddenForbidden
        Kind = 'Text'
        Description = "$name uses no real input, foreground, clipboard, Start-Process or recursive delete"
    }
    $hiddenContracts += @{
        File = $script
        Content = $text
        Pattern = "(?s)'--single-instance=false'.*?--class=noctty-test-pkg76"
        Kind = 'Text'
        Description = "$name starts every noctty with single-instance off and a unique class"
    }
}
Invoke-ContractTable -Contracts $hiddenContracts

# The skip budget, run on synthetic output of the test executable.
$skipScript = Join-Path $repoRoot 'scripts\check-test-skips.ps1'
$skipBudget = Join-Path $repoRoot 'test\windows\test-skip-budget.json'
$budget = Get-Content -LiteralPath $skipBudget -Raw | ConvertFrom-Json
if ($budget.schema_version -ne 1 -or -not $budget.familyPrefix) { throw 'test-skip-budget.json lost its schema version or family prefix.' }
foreach ($runner in $budget.runners.PSObject.Properties) {
    $limits = $runner.Value
    if ([int]$limits.maxTotalSkipped -lt @($limits.allowedSkips).Count) {
        throw "Budget for $($runner.Name) has a bad maxTotalSkipped."
    }
    $names = @($limits.allowedSkips)
    if (@($names | Select-Object -Unique).Count -ne $names.Count) { throw "Budget for $($runner.Name) lists a test twice." }
    foreach ($n in $names) {
        if (-not $n.StartsWith($budget.familyPrefix, [StringComparison]::Ordinal)) { throw "Budget for $($runner.Name) lists '$n', outside '$($budget.familyPrefix)'." }
    }
}
$skipTemp = Join-Path ([IO.Path]::GetTempPath()) ('noctty-skip-budget-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $skipTemp | Out-Null
try {
    $fixtureBudget = Join-Path $skipTemp 'budget.json'
    @{
        schema_version = 1; familyPrefix = 'font.'
        runners = @{ r = @{ maxTotalSkipped = 3; allowedSkips = @('font.a.test.allowed skip') } }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fixtureBudget
    function Invoke-SkipFixture([string] $Name, [string[]] $Lines, [string] $Runner = 'r') {
        $log = Join-Path $skipTemp "$Name.log"
        Set-Content -LiteralPath $log -Value $Lines
        $output = & pwsh -NoProfile -File $skipScript -TestLog $log -Runner $Runner -BudgetFile $fixtureBudget 2>&1 | Out-String
        return @{ Exit = $LASTEXITCODE; Output = $output }
    }
    $okRun = @('1/4 font.a.test.allowed skip...SKIP', '2/4 font.b.test.runs...OK', '3/4 other.test.skips...SKIP', '4/4 font.c.test.runs...OK', '2 passed; 2 skipped; 0 failed.')
    $skipCases = @(
        @{ Name = 'an allowed skip within budget'; Lines = $okRun; Exit = 0; Match = 'PASS' }
        @{ Name = 'a result printed after log output'; Exit = 0; Match = 'PASS'
           Lines = @('1/3 font.a.test.allowed skip...[font] (warn): some log', '[font] (warn): another', 'SKIP', '2/3 font.b.test.runs...OK', '3/3 other.test...OK', '2 passed; 1 skipped; 0 failed.') }
        @{ Name = 'a font test that starts skipping'; Exit = 1; Match = 'not on the .r. allowlist: font\.b\.test\.runs'
           Lines = @('1/3 font.a.test.allowed skip...SKIP', '2/3 font.b.test.runs...SKIP', '3/3 other.test...OK', '1 passed; 2 skipped; 0 failed.') }
        @{ Name = 'a total above the budget'; Exit = 1; Match = '4 tests skipped; the .r. budget is 3'
           Lines = @('1/5 font.a.test.allowed skip...SKIP', '2/5 x.one...SKIP', '3/5 x.two...SKIP', '4/5 x.three...SKIP', '5/5 x.four...OK', '1 passed; 4 skipped; 0 failed.') }
        @{ Name = 'a run that died before its closing line'; Exit = 1; Match = 'did not finish'
           Lines = @('1/4 font.a.test.allowed skip...SKIP', '2/4 font.b.test.runs...OK') }
        @{ Name = 'counts that disagree'; Exit = 1; Match = 'inconsistent'
           Lines = @('1/2 font.b.test.runs...OK', '2/2 font.c.test.runs...OK', '5 passed; 0 skipped; 0 failed.') }
        @{ Name = 'no per-test lines at all'; Exit = 1; Match = 'no per-test lines'
           Lines = @('some other output') }
    )
    foreach ($case in $skipCases) {
        $result = Invoke-SkipFixture ($case.Name -replace '\W', '-') $case.Lines
        if ($result.Exit -ne $case.Exit -or $result.Output -notmatch $case.Match) {
            throw "Skip budget fixture '$($case.Name)': expected exit $($case.Exit) matching /$($case.Match)/, got exit $($result.Exit): $($result.Output)"
        }
    }
    $unknown = Invoke-SkipFixture 'unknown-runner' $okRun 'nowhere'
    if ($unknown.Exit -eq 0 -or $unknown.Output -notmatch 'No budget for runner') { throw 'The skip budget accepted a runner it has no entry for.' }
}
finally {
    # The root was made above from the temp directory and a GUID: assert that before a recursive delete.
    if ($skipTemp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $skipTemp) -match '^noctty-skip-budget-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $skipTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Hidden harness and skip budget contracts: $($hiddenContracts.Count) static checks, $($skipCases.Count + 1) skip budget fixtures"
