# The Windows 10 pre-release checklist must keep up with the code that branches on
# the Windows build, and the report-only workflow must stay what the checklist
# says it is. No GitHub-hosted image is Windows 10, so these contracts are what
# stops the checklist from going stale between releases.
$win10ChecklistPath = Join-Path $repoRoot 'docs\windows10-release-checklist.md'
$win10WorkflowPath = Join-Path $repoRoot '.github\workflows\windows10-branches.yml'
$win10Checklist = Get-Content -LiteralPath $win10ChecklistPath -Raw
$win10Workflow = Get-Content -LiteralPath $win10WorkflowPath -Raw

# Every function in src that compares the Windows build to something is a gate:
# find the function around each comparison and require the checklist to name it.
$win10GateComparison = [regex]'\bos_build\s*(?:>=|<=|>|<|==|!=)'
$win10GateFunctions = [Collections.Generic.SortedSet[string]]::new()
foreach ($zigFile in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Filter '*.zig' -Recurse -File) {
    $zigText = Get-Content -LiteralPath $zigFile.FullName -Raw
    foreach ($comparison in $win10GateComparison.Matches($zigText)) {
        # Tests assert on gates by setting `os_build`; they never compare it.
        $before = $zigText.Substring(0, $comparison.Index)
        $function = [regex]::Matches($before, '(?m)^\s*(?:pub\s+)?fn\s+(\w+)\s*\(') | Select-Object -Last 1
        if ($null -eq $function) { throw "A comparison of os_build in $($zigFile.Name) sits outside any function." }
        [void]$win10GateFunctions.Add($function.Groups[1].Value)
    }
}
if ($win10GateFunctions.Count -lt 3) {
    throw "Found only $($win10GateFunctions.Count) functions that compare os_build; the gate scan is out of date."
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
)
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
