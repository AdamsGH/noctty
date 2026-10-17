# The Windows 10 pre-release checklist must keep up with the code that branches on
# the Windows build, and the report-only workflow must stay what the checklist
# says it is. No GitHub-hosted image is Windows 10, so these contracts are what
# stops the checklist from going stale between releases.
$win10ChecklistPath = Join-Path $repoRoot 'docs\windows10-release-checklist.md'
$win10WorkflowPath = Join-Path $repoRoot '.github\workflows\windows10-branches.yml'
$win10Checklist = Get-Content -LiteralPath $win10ChecklistPath -Raw
$win10Workflow = Get-Content -LiteralPath $win10WorkflowPath -Raw

# Blanks every Zig comment, multi-line-string line, string literal and character literal, keeping
# the length, so an offset in the result is an offset in the source.
function Remove-ZigNonCode([string] $Text) {
    return [regex]::Replace($Text, '//[^\n]*|\\\\[^\n]*|''(?:\\.|[^''\\\n])''|"(?:\\.|[^"\\\n])*"', { param($m) ' ' * $m.Length })
}

# Every function whose body compares the Windows build to something, on either side of the
# operator, by name, by an OS_BUILD_ constant or through RtlGetVersion's field. Comparisons in test
# blocks do not count: tests only set the build to stand in for a machine.
function Get-WindowsBuildGateFunctions([string] $ZigText) {
    $code = Remove-ZigNonCode $ZigText
    $build = '(?:\bos_build\b|\bOS_BUILD_\w+\b|\bdwBuildNumber\b)'
    $comparison = [regex]('(?:' + $build + '\s*(?:>=|<=|==|!=|(?<![=\-])>|<)|(?:>=|<=|==|!=|(?<![=\-])>|<)\s*[\w.]*' + $build + ')')
    $containers = [regex]::Matches($code, '(?m)^[ \t]*(?:pub[ \t]+)?(?:inline[ \t]+)?fn[ \t]+(\w+)[ \t]*\(|^[ \t]*test[ \t]*(?:"|\{)')
    $found = [Collections.Generic.SortedSet[string]]::new()
    foreach ($hit in $comparison.Matches($code)) {
        $container = $containers | Where-Object { $_.Index -lt $hit.Index } | Select-Object -Last 1
        if ($null -eq $container) { throw 'A comparison of the Windows build sits outside any function.' }
        if ($container.Groups[1].Success) { [void]$found.Add($container.Groups[1].Value) }
    }
    return @($found)
}

# The scanner is part of the contract: each case below is a shape a gate can take.
foreach ($fixture in @(
        @{ Name = 'a forward comparison'; Zig = "fn gate(os_build: u32) bool { return os_build >= 22000; }"; Expect = @('gate') }
        @{ Name = 'a reversed comparison'; Zig = "fn rev(os_build: u32) bool { return 22000 <= os_build; }"; Expect = @('rev') }
        @{ Name = 'a comparison against a constant'; Zig = "fn k(x: u32) bool {`n    return x < c.OS_BUILD_WIN11_21H2;`n}"; Expect = @('k') }
        @{ Name = 'a comparison of RtlGetVersion output'; Zig = "fn probe() bool { return info.dwBuildNumber < 22621; }"; Expect = @('probe') }
        @{ Name = 'a comment'; Zig = "// os_build >= 22000 is only a comment`nfn nothing() void {}"; Expect = @() }
        @{ Name = 'a string'; Zig = "const text = `"os_build >= 22000`";`nfn nothing() void {}"; Expect = @() }
        @{ Name = 'a comparison in a test'; Zig = "fn plain() void {}`ntest `"x`" { try expect(os_build >= 1); }"; Expect = @() }
        @{ Name = 'an assignment'; Zig = "fn set(app: *App) void { app.os_build = c.OS_BUILD_WIN11_21H2; }"; Expect = @() }
    )) {
    $got = @(Get-WindowsBuildGateFunctions $fixture.Zig)
    if (($got -join ',') -ne ($fixture.Expect -join ',')) {
        throw "The Windows build gate scanner is wrong for $($fixture.Name): expected [$($fixture.Expect -join ',')], found [$($got -join ',')]."
    }
}

$win10GateFunctions = [Collections.Generic.SortedSet[string]]::new()
foreach ($zigFile in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Filter '*.zig' -Recurse -File) {
    foreach ($function in Get-WindowsBuildGateFunctions (Get-Content -LiteralPath $zigFile.FullName -Raw)) {
        [void]$win10GateFunctions.Add($function)
    }
}
if ($win10GateFunctions.Count -lt 3) {
    throw "Found only $($win10GateFunctions.Count) functions that compare the Windows build; the gate scan is out of date."
}

$win10BuildConstants = [regex]::Matches(
    (Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32\consts.zig') -Raw),
    '(?m)^pub const (OS_BUILD_\w+): u32 = (\d+);')
if ($win10BuildConstants.Count -lt 3) {
    throw 'src/apprt/win32/consts.zig no longer declares the OS_BUILD_ constants the checklist names.'
}

$win10RowIds = @([regex]::Matches($win10Checklist, '(?m)^\*\*(W10-\d{2}) ') | ForEach-Object { $_.Groups[1].Value })
if ($win10RowIds.Count -eq 0) { throw 'The Windows 10 checklist has no W10-nn rows.' }
$win10ExpectedIds = @(1..$win10RowIds.Count | ForEach-Object { 'W10-{0:D2}' -f $_ })

# The workflow's steps, with comments removed so that a comment cannot satisfy a pattern. Each one
# must stay in the job that runs unconditionally, because a green run is the evidence.
$win10Job = Get-YamlJobText -Content $win10Workflow -Name 'server-2022' -Source $win10WorkflowPath
function Get-Win10WorkflowStep([string] $Name) {
    $step = Get-YamlStepBlock -Content $win10Job -Name $Name -Source $win10WorkflowPath
    return (($step -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}
$win10WorkflowSteps = [ordered]@{
    'Require a Windows build below 22000'          = '(?s)-ge 22000\).*?throw'
    'Full Zig test suite'                          = '(?s)zig build test -Demit-test-exe=true -Dcustom-shaders=true --summary all.*?exit \$code'
    'noctty +version smoke'                        = '(?s)noctty\.com \+version.*?LASTEXITCODE -ne 0.*?throw'
    'Hidden-desktop WARP lifecycle smoke'          = 'Invoke-RendererParity\.ps1 -Binary \./renderer-smoke/bin/noctty\.exe -OutputDirectory \./renderer-smoke/evidence -WarpOnly'
    'Require the app to take the Windows 10 branch' = '(?s)Get-ChildItem -Path renderer-smoke/evidence -Recurse -Filter stderr\.txt.*?os_build=\(\\d\+\) integrated_titlebar=\(true\|false\).*?-ge 22000.*?throw'
}

$win10Contracts = @(
    @{
        File = $win10ChecklistPath
        Content = { ($win10RowIds -join ',') }
        Pattern = ('^' + [regex]::Escape($win10ExpectedIds -join ',') + '$')
        Kind = 'Text'
        Description = 'checklist rows are numbered W10-01 upward with no gap or repeat'
    }
    @{
        File = $win10ChecklistPath
        Content = { $win10Checklist }
        Pattern = ('(?m)^\| W10-01 to ' + [regex]::Escape($win10ExpectedIds[-1]) + ' ')
        Kind = 'Text'
        Description = 'the results table covers every checklist row'
    }
    @{
        File = $win10ChecklistPath
        Content = { $win10Checklist }
        Pattern = '\(\.\./\.github/workflows/windows10-branches\.yml\)'
        Kind = 'Text'
        Description = 'the checklist links the report-only Windows 10 workflow'
    }
    @{
        File = (Join-Path $repoRoot 'PACKAGING.md')
        Content = { Get-Content -LiteralPath (Join-Path $repoRoot 'PACKAGING.md') -Raw }
        Pattern = '(?s)### Release runbook.*docs/windows10-release-checklist\.md.*### WinGet'
        Kind = 'Text'
        Description = 'the release runbook links the Windows 10 checklist'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?m)^    runs-on: windows-2022\s*$'
        Kind = 'Text'
        Description = 'the Windows 10 workflow runs on the Server 2022 image, the only hosted one below build 22000'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?ms)^on:\s+schedule:.*?workflow_dispatch:\s+pull_request:\s+paths:\s+- \.github/workflows/windows10-branches\.yml\s*$'
        Kind = 'Text'
        Description = 'the Windows 10 workflow runs on a schedule and on demand, and on a pull request only for its own file'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?ms)^permissions:\s+contents: read\s*$'
        Kind = 'Text'
        Description = 'the Windows 10 workflow has read-only permissions'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?m)^    timeout-minutes: \d+\s*$'
        Kind = 'Text'
        Description = 'the Windows 10 workflow bounds its job'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Workflow }
        Pattern = '(?ms)- name: Setup Zig.*?with:\s+version: 0\.15\.2\s+use-cache: false'
        Kind = 'Text'
        Description = 'the Windows 10 workflow cannot restore failed Zig build caches'
    }
    @{
        File = $win10WorkflowPath
        Content = { $win10Job -replace '(?s)\n    steps:.*', '' }
        Pattern = '(?s)^(?!.*(?:continue-on-error|\n    if:))'
        Kind = 'Text'
        Description = 'the Windows 10 job does not ignore failures or skip itself'
    }
)
foreach ($step in $win10WorkflowSteps.Keys) {
    # The text is read here, not in a script block: a block run later cannot see this file's functions.
    $stepText = Get-Win10WorkflowStep $step
    $win10Contracts += @{
        File = "$win10WorkflowPath :: $step"
        Content = $stepText
        Pattern = $win10WorkflowSteps[$step]
        Kind = 'Text'
        Description = "the Windows 10 workflow's '$step' step runs its check"
    }
    $win10Contracts += @{
        File = "$win10WorkflowPath :: $step"
        Content = $stepText
        Pattern = '(?s)^(?!.*(?:continue-on-error|\n {8}if:))'
        Kind = 'Text'
        Description = "the Windows 10 workflow's '$step' step is unconditional and fails the job"
    }
}
foreach ($function in $win10GateFunctions) {
    $win10Contracts += @{
        File = $win10ChecklistPath
        Content = { $win10Checklist }
        Pattern = ('`' + [regex]::Escape($function) + '`')
        Kind = 'Text'
        Description = "the checklist's gate inventory names $function, which compares the Windows build"
    }
}
foreach ($constant in $win10BuildConstants) {
    $win10Contracts += @{
        File = $win10ChecklistPath
        Content = { $win10Checklist }
        Pattern = ('`' + [regex]::Escape($constant.Groups[1].Value) + '`')
        Kind = 'Text'
        Description = "the checklist's gate inventory names $($constant.Groups[1].Value)"
    }
}
Invoke-ContractTable -Contracts $win10Contracts
Write-Host "Windows 10 checklist: $($win10RowIds.Count) rows, $($win10GateFunctions.Count) gate functions ($($win10GateFunctions -join ', '))"
