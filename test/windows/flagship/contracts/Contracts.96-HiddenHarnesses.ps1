# The hidden-desktop harnesses added for PKG-76 (profile matrix, -Embedding idle) start real
# copies of noctty on ephemeral hosted runners, and the skip budget decides what CI may skip
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
    if ($name -eq 'hidden-win11-profile-matrix.ps1') { $hiddenContracts += @{
        File = $script
        Content = $text
        Pattern = "(?s)'--single-instance=false'.*?--class=noctty-test-pkg76"
        Kind = 'Text'
        Description = "$name starts every noctty with single-instance off and a unique class"
    } }
}
Invoke-ContractTable -Contracts $hiddenContracts

# Exercise extracted functions with managed native-call stand-ins, plus bounded native
# observations of this process and an empty job. No child, window, registry write or real state read.
function Get-HiddenFunction([string] $Text, [string] $Name) {
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if (-not $function) { throw "Missing hidden harness function $Name." }
    return $function.Extent.Text
}
$script:mutationControls = 0
function Assert-HiddenMutation([string] $Name, [string] $Original, [string] $Mutated, [scriptblock] $Validate) {
    if ($Original -ceq $Mutated) { throw "Mutation '$Name' changed no code." }
    & $Validate $Original
    $rejected = $false
    try { & $Validate $Mutated } catch { $rejected = $true }
    if (-not $rejected) { throw "Hidden harness contract accepted mutation '$Name'." }
    $script:mutationControls++
}

$launch = [regex]::Match($hiddenLibText, '(?ms)^    public static ProcessInfo Launch\(.*?^    }').Value
$createDesktop = [regex]::Match($hiddenLibText, '(?ms)^    public static IntPtr CreateInheritedDesktop\(.*?^    }').Value
$threadDesktop = [regex]::Match($hiddenLibText, '(?ms)^    public static string ThreadDesktopName\(.*?^    }').Value
$currentDesktop = [regex]::Match($hiddenLibText, '(?ms)^    public static string CurrentDesktopName\(.*?^    }').Value
$jobWindows = [regex]::Match($hiddenLibText, '(?ms)^    public static DesktopWindowObservation\[\] VisibleJobWindows\(.*?^    }').Value
$windowObservation = [regex]::Match($hiddenLibText, '(?ms)^    public sealed class DesktopWindowObservation.*?^    }').Value
$visibleWindows = [regex]::Match($hiddenLibText, '(?ms)^    public static string\[\] VisibleTopLevelClasses\(.*?^    }').Value
if (-not $launch -or -not $createDesktop -or -not $threadDesktop -or -not $visibleWindows) { throw 'The hidden native launch/desktop/window methods were not found.' }
function Test-HiddenNativeCode([string] $Methods) {
    $typeName = 'HiddenNativeContract' + [guid]::NewGuid().ToString('N')
    $support = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class TYPE_NAME {
    [StructLayout(LayoutKind.Sequential)] public struct Startup { public int cb, flags; public string desktop; public IntPtr error; }
    public struct ProcessInfo { public IntPtr process, thread; }
    public struct SecurityAttributes { public int length; public bool inherit; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    public static string Desktop; public static uint Flags; public static bool Inherit, DesktopInherit, Assigned, Resumed, AssignedBeforeResume, ThreadQueryFails, NameQueryFails;
    public static int CreatedDesktops;
    public static int ThreadError;
    public static bool EnumFails;
    static IntPtr CreateDesktopW(string n, IntPtr d, IntPtr m, int f, uint a, ref SecurityAttributes sa) { CreatedDesktops++; DesktopInherit = sa.inherit; return new IntPtr(9); }
    static void SetLastError(uint error) { Marshal.SetLastPInvokeError((int)error); }
    static IntPtr GetThreadDesktop(uint threadId) { if (ThreadQueryFails) { if (ThreadError != 0) SetLastError((uint)ThreadError); return IntPtr.Zero; } return new IntPtr(9); }
    static uint GetCurrentThreadId() { return 42; }
    static IntPtr GetDesktopWindow() { ThreadQueryFails = false; return new IntPtr(9); }
    static int[] JobProcessIds(IntPtr job) { return new int[] { 41, 42 }; }
    static bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed) { needed = 20; name.Append("contract-private"); return !NameQueryFails; }
    static IntPtr CreateFileW(string p, uint a, uint s, ref SecurityAttributes sa, uint d, uint f, IntPtr t) { return new IntPtr(3); }
    static bool CloseHandle(IntPtr h) { return true; }
    static bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi) {
        Desktop = si.desktop; Flags = flags; Inherit = inherit; pi = new ProcessInfo { process = new IntPtr(1), thread = new IntPtr(2) }; return true;
    }
    static bool AssignProcessToJobObject(IntPtr job, IntPtr process) { Assigned = job == new IntPtr(7) && process == new IntPtr(1); return Assigned; }
    static uint ResumeThread(IntPtr thread) { AssignedBeforeResume = Assigned; Resumed = true; return 1; }
    static bool TerminateProcess(IntPtr process, uint code) { return true; }
    static bool EnumWindows(EnumWindow cb, IntPtr p) { if (EnumFails) return false; for (int i = 1; i <= 4; i++) cb(new IntPtr(i), p); return true; }
    static int GetWindowThreadProcessId(IntPtr h, out int pid) { pid = h.ToInt32() == 4 ? 99 : 42; return 1; }
    static string Class(IntPtr h) { return h.ToInt32() == 1 ? "noctty.win32.host" : "#32770"; }
    static bool IsWindowVisible(IntPtr h) { return h.ToInt32() == 2 || h.ToInt32() == 4; }
METHODS
}
'@
    $type = Add-Type -TypeDefinition ($support.Replace('TYPE_NAME', $typeName).Replace('METHODS', $Methods)) -PassThru | Where-Object Name -eq $typeName
    $null = $type::CreateInheritedDesktop('contract-private')
    if ($type::CreatedDesktops -ne 1 -or -not $type::DesktopInherit) { throw 'Harness must create exactly one inheritable desktop handle.' }
    foreach ($stderr in @('', 'unused-stderr')) {
        $type::Assigned = $type::Resumed = $type::AssignedBeforeResume = $false
        $null = $type::Launch('unused.exe', 'unused', 'unused', 'WinSta0\contract-private', [IntPtr]7, $stderr)
        if ($type::Desktop -cne 'WinSta0\contract-private' -or -not $type::Inherit -or ($type::Flags -band 0x08000004) -ne 0x08000004 -or
            -not $type::Assigned -or -not $type::Resumed -or -not $type::AssignedBeforeResume) { throw 'Native launch lost desktop inheritance, explicit desktop, no-window/suspended flags or assign-before-resume.' }
    }
    if ($type::ThreadDesktopName(42) -cne 'contract-private') { throw 'Thread desktop name query failed.' }
    $type::ThreadQueryFails = $true
    [Runtime.InteropServices.Marshal]::SetLastPInvokeError(123)
    if ($null -ne $type::ThreadDesktopName(42)) { throw 'NULL/error-zero must mean unconnected, even after a stale error.' }
    if ($type::CurrentDesktopName() -cne 'contract-private') { throw 'Current thread was not connected before resolving its desktop.' }
    $type::ThreadError = 5
    foreach ($failure in @('ThreadQueryFails', 'NameQueryFails')) {
        $type.GetField($failure).SetValue($null, $true)
        $rejected = $false
        try { $null = $type::ThreadDesktopName(42) } catch { $rejected = $true }
        $type.GetField($failure).SetValue($null, $false)
        if (-not $rejected) { throw 'Desktop query error was silently accepted.' }
    }
    $classes = @($type::VisibleTopLevelClasses(42))
    if ($classes.Count -ne 1 -or $classes[0] -cne '#32770') { throw 'Visible-window enumeration lost the process/visibility filter or omitted a dialog.' }
    $windows = @($type::VisibleJobWindows([IntPtr]7))
    if ($windows.Count -ne 1 -or $windows[0].ProcessId -ne 42) { throw 'Default-desktop oracle must keep only visible owned-job windows, including dialogs.' }
    $type::EnumFails = $true
    $rejected = $false
    try { $null = $type::VisibleJobWindows([IntPtr]7) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Default-desktop window enumeration errors must fail closed.' }
}
$nativeCode = $launch + "`n" + $createDesktop + "`n" + $threadDesktop + "`n" + $currentDesktop + "`n" + $visibleWindows + "`n" + $windowObservation + "`n" + $jobWindows
Assert-HiddenMutation 'null native desktop' $nativeCode ($nativeCode.Replace('desktop = desktop', 'desktop = null')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'wrong native desktop' $nativeCode ($nativeCode.Replace('desktop = desktop', 'desktop = "Default"')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'child handle inheritance disabled' $nativeCode ($nativeCode.Replace('IntPtr.Zero, IntPtr.Zero, true, 0x08004004', 'IntPtr.Zero, IntPtr.Zero, false, 0x08004004')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'desktop handle not inheritable' $nativeCode ($nativeCode.Replace('inherit = true', 'inherit = false')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'desktop name query errors ignored' $nativeCode ($nativeCode.Replace('throw new Exception("Desktop name query failed: " + Marshal.GetLastWin32Error())', 'return "contract-private"')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'missing job assignment' $nativeCode ($nativeCode.Replace('!AssignProcessToJobObject(job, pi.process) || ', '')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'missing no-window flag' $nativeCode ($nativeCode.Replace('0x08004004', '0x00004004')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'hidden windows counted as UI' $nativeCode ($nativeCode.Replace(' && IsWindowVisible(h)', '')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'visible dialogs omitted' $nativeCode ($nativeCode.Replace('id == pid && IsWindowVisible(h)', 'id == pid && IsWindowVisible(h) && Class(h) == "noctty.win32.host"')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'stale thread last error retained' $nativeCode ($nativeCode.Replace('SetLastError(0);', '')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'unconnected native thread rejected' $nativeCode ($nativeCode.Replace('if (error == 0) return null;', 'if (error == 0) throw new Exception("unconnected");')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'current desktop never connected' $nativeCode ($nativeCode.Replace('if (GetDesktopWindow() == IntPtr.Zero)', 'if (false)')) ${function:Test-HiddenNativeCode}
Assert-HiddenMutation 'unrelated default window counted' $nativeCode ($nativeCode.Replace('ids.Contains(id) && ', '')) ${function:Test-HiddenNativeCode}

# Compile the real observer against a managed process/thread snapshot seam. Query
# failures only excuse a TID conclusively absent after refreshing the retained process.
$observerCode = ([regex]::Matches($hiddenLibText, '(?ms)^    (?:public sealed class DesktopObservation\b|static bool Conclusively(?:Thread)?Exited\(|public static DesktopObservation\[\] ObserveDesktopThreads\()[^\r\n]*\r?\n.*?^    }') |
    ForEach-Object Value) -join "`n"
function Test-HiddenThreadRace([string] $Methods) {
    $typeName = 'HiddenThreadRace' + [guid]::NewGuid().ToString('N')
    $support = @'
using System;
using System.Collections.Generic;
public static class TYPE_NAME {
    public static bool QueryFails, Vanished, RefreshFails, ProcessExited;
    public static int Lookups, Refreshes;
    public sealed class ProcessThread { public int Id; }
    public sealed class Process : IDisposable {
        bool retained, refreshed;
        public static Process GetProcessById(int id) { Lookups++; return new Process(); }
        public IntPtr Handle { get { retained = true; return new IntPtr(7); } }
        public string ProcessName { get { return "fixture"; } }
        public bool HasExited { get { return ProcessExited; } }
        public List<ProcessThread> Threads { get {
            if (!retained) throw new Exception("Process handle not retained");
            var threads = new List<ProcessThread>();
            if (!refreshed || !Vanished) threads.Add(new ProcessThread { Id = 11 });
            threads.Add(new ProcessThread { Id = 12 }); return threads;
        } }
        public void Refresh() { Refreshes++; if (RefreshFails) throw new Exception("Refresh failed"); refreshed = true; }
        public void Dispose() { }
    }
    static string ThreadDesktopName(uint tid) { if (tid == 11 && QueryFails) throw new Exception("Query failed"); return "private"; }
METHODS
}
'@
    $type = Add-Type -TypeDefinition ($support.Replace('TYPE_NAME', $typeName).Replace('METHODS', $Methods)) -PassThru | Where-Object Name -eq $typeName
    foreach ($fixture in @(
        @{ QueryFails = $false; Vanished = $false; Error = $false; ThreadExited = $false }
        @{ QueryFails = $true; Vanished = $true; Error = $false; ThreadExited = $true }
        @{ QueryFails = $true; Vanished = $false; Error = $true; ThreadExited = $false }
        @{ QueryFails = $true; Vanished = $true; RefreshFails = $true; Error = $true; ThreadExited = $false }
        @{ QueryFails = $true; ProcessExited = $true; Error = $false; ThreadExited = $false }
    )) {
        foreach ($field in @('QueryFails', 'Vanished', 'RefreshFails', 'ProcessExited')) { $type.GetField($field).SetValue($null, [bool]$fixture[$field]) }
        $type::Lookups = $type::Refreshes = 0
        $rows = @($type::ObserveDesktopThreads([int[]]@(41)))
        if ($rows.Count -ne 2 -or $type::Lookups -ne 1 -or [bool]$rows[0].Error -ne $fixture.Error -or
            $rows[0].ThreadExited -ne $fixture.ThreadExited -or $rows[0].Exited -ne [bool]$fixture.ProcessExited -or $rows[1].Desktop -cne 'private') {
            throw 'Observer lost the vanished/live/unexplained thread-query distinction.'
        }
        if ($fixture.QueryFails -and -not $fixture.ProcessExited -and $type::Refreshes -ne 1) { throw 'Thread disappearance requires a fresh retained-process enumeration.' }
    }
}
Assert-HiddenMutation 'thread snapshot not refreshed' $observerCode ($observerCode.Replace('process.Refresh();', '')) ${function:Test-HiddenThreadRace}
Assert-HiddenMutation 'live failed thread accepted as exited' $observerCode ($observerCode.Replace('if (thread.Id == threadId) return false;', 'if (thread.Id == threadId) return true;')) ${function:Test-HiddenThreadRace}

if (-not ('HiddenStartContract' -as [type])) {
    Add-Type @'
using System;
public class HiddenStartContract {
    public static int Launches;
    public DateTime StartTime = DateTime.UtcNow;
    public struct ProcessInfo { public int pid; public IntPtr thread, process; }
    public static ProcessInfo Launch(string a, string c, string w, string d, IntPtr j, string e) { Launches++; return new ProcessInfo { pid = 42 }; }
    public static HiddenStartContract GetProcessById(int pid) { return new HiddenStartContract(); }
    public static bool CloseHandle(IntPtr p) { return true; }
}
'@
}
$startFunction = (Get-HiddenFunction $hiddenLibText 'Start-HiddenNoctty').Replace('[HiddenWin]', '[HiddenStartContract]').Replace('[Diagnostics.Process]', '[HiddenStartContract]')
function Test-HiddenPrelaunchMetadata([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fail in @($false, $true)) {
        $script:prelaunchMetadataCalls = 0; $script:prelaunchRunnerCalls = 0; [HiddenStartContract]::Launches = 0
        function Assert-HiddenRunner { $script:prelaunchRunnerCalls++ }
        function Assert-HiddenDesktop {
            $script:prelaunchMetadataCalls++
            if ([HiddenStartContract]::Launches -ne 0) { throw 'Metadata ran after launch.' }
            if ($fail) { throw 'fixture prelaunch metadata failure' }
        }
        function Test-Path { return $true }
        $blocked = $false
        try { $null = Start-HiddenNoctty -Dir 'C:\fixture' -Arguments @('unused') -DesktopName 'private' -Job ([IntPtr]7) }
        catch { $blocked = $_.Exception.Message -ceq 'fixture prelaunch metadata failure' }
        if ($blocked -ne $fail -or $script:prelaunchMetadataCalls -ne 1 -or $script:prelaunchRunnerCalls -ne 1 -or
            [HiddenStartContract]::Launches -ne [int](-not $fail)) { throw 'Prelaunch metadata must execute before and block a failed launch.' }
    }
}
Assert-HiddenMutation 'prelaunch metadata removed' $startFunction ($startFunction -replace '(?m)^\s+Assert-HiddenDesktop[^\r\n]*', '') ${function:Test-HiddenPrelaunchMetadata}
$prelaunchCall = [regex]::Match($startFunction, '(?m)^    Assert-HiddenDesktop[^\r\n]*').Value
$lateMetadata = ($startFunction.Replace($prelaunchCall, '')).Replace('    $process =', "$prelaunchCall`n    `$process =")
Assert-HiddenMutation 'prelaunch metadata moved after launch' $startFunction $lateMetadata ${function:Test-HiddenPrelaunchMetadata}

if (-not ('HiddenDriverContract' -as [type])) {
    Add-Type @'
using System;
public static class HiddenDriverContract {
    public static string Local, Roaming, Desktop;
    public static int Waits, Stops, ExitReads;
    public static uint ExitCode;
    public static bool ExitQueryFails;
    public struct ProcessInfo { public int pid; public IntPtr thread, process; }
    public static uint GetClipboardSequenceNumber() { return 0; }
    public static IntPtr CreateInheritedDesktop(string n) { return new IntPtr(1); }
    public static IntPtr CreateOwnedJob() { return new IntPtr(2); }
    public static string CurrentDesktopName() { return "Default"; }
    public static ProcessInfo Launch(string a, string c, string w, string desktop, IntPtr j, string e) {
        Local = Environment.GetEnvironmentVariable("LOCALAPPDATA"); Roaming = Environment.GetEnvironmentVariable("APPDATA"); Desktop = desktop;
        return new ProcessInfo { pid = 1 };
    }
    public static uint WaitForSingleObject(IntPtr p, uint ms) { return Waits++ == 0 ? 258u : 0u; }
    public static bool GetExitCodeProcess(IntPtr p, out uint code) { ExitReads++; code = ExitCode; return !ExitQueryFails; }
    public static uint StopOwnedJob(IntPtr j) { Stops++; return 0; }
    public static bool CloseHandle(IntPtr p) { return true; }
    public static bool CloseDesktop(IntPtr d) { return true; }
}
'@
}
$driverFunction = (Get-HiddenFunction $hiddenLibText 'Invoke-HiddenDriver').Replace('[HiddenWin]', '[HiddenDriverContract]')
function Test-HiddenDriverCode([string] $Code) {
    . ([scriptblock]::Create($Code))
    $script:driverRunnerGuardCalled = $false
    function Assert-HiddenRunner { $script:driverRunnerGuardCalled = $true }
    function Get-RealStateFingerprints { return @{ Startup = @{}; History = @{} } }
    function Get-FileFingerprint { return @{ Exists = $true; Hash = 'managed fixture' } }
    function Test-SameFingerprint { return $true }
    function Copy-PortableBin { }
    $script:defaultOracleCalls = 0; $script:metadataCalls = 0; $script:oracleThrows = $false
    function Assert-HiddenDefaultDesktop { $script:defaultOracleCalls++; if ($script:oracleThrows) { throw 'Hidden desktop fixture visible default window' } }
    function Assert-HiddenDesktop { $script:metadataCalls++ }
    [HiddenDriverContract]::Waits = [HiddenDriverContract]::Stops = [HiddenDriverContract]::ExitReads = 0
    [HiddenDriverContract]::ExitCode = 0; [HiddenDriverContract]::ExitQueryFails = $false
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ('noctty-hidden-contract-' + [guid]::NewGuid().ToString('N'))
    $savedLocal = $env:LOCALAPPDATA; $savedRoaming = $env:APPDATA
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'bin')
        Set-Content -LiteralPath (Join-Path $fixture 'bin\noctty.exe') -Value ''
        $runPath = Join-Path $fixture 'run'
        Invoke-HiddenDriver -Script 'unused.ps1' -Bin (Join-Path $fixture 'bin') -Run $runPath -TimeoutSeconds 1 -Label 'managed isolation fixture' 6>$null
        if (-not $script:driverRunnerGuardCalled) { throw 'Driver lost the hosted-runner gate.' }
        if ($script:defaultOracleCalls -ne 2) { throw 'Outer default-desktop oracle must run during polling and after driver exit.' }
        if ($script:metadataCalls -lt 1) { throw 'Outer polling must collect thread desktop metadata.' }
        if ([HiddenDriverContract]::Local -cne (Join-Path $runPath 'localappdata') -or
            [HiddenDriverContract]::Roaming -cne (Join-Path $runPath 'appdata') -or
            [HiddenDriverContract]::Desktop -notmatch '^WinSta0\\noctty-hw-[0-9a-f]{32}$') { throw 'Driver launch lost run-scoped app data or explicit desktop.' }
        if ($env:LOCALAPPDATA -cne $savedLocal -or $env:APPDATA -cne $savedRoaming) { throw 'Driver did not restore its environment.' }
        if ([HiddenDriverContract]::Stops -ne 1) { throw 'Driver must clean up its owned job.' }
        $script:defaultOracleCalls = 0; $script:metadataCalls = 0; $script:oracleThrows = $true
        [HiddenDriverContract]::Waits = [HiddenDriverContract]::Stops = [HiddenDriverContract]::ExitReads = 0
        $blocked = $false
        try {
            Invoke-HiddenDriver -Script 'unused.ps1' -Bin (Join-Path $fixture 'bin') -Run (Join-Path $fixture 'run-failure') -TimeoutSeconds 1 -Label 'managed oracle failure fixture' 6>$null
        } catch { $blocked = $_.Exception.Message -ceq 'Hidden desktop fixture visible default window' }
        if (-not $blocked -or [HiddenDriverContract]::Stops -ne 1 -or [HiddenDriverContract]::Waits -ne 1 -or
            [HiddenDriverContract]::ExitReads -ne 0 -or $script:metadataCalls -ne 0 -or $script:defaultOracleCalls -ne 1) {
            throw 'Default-desktop failure must immediately clean up the owned job without continuing driver polling/metadata/exit checks.'
        }
        if ($env:LOCALAPPDATA -cne $savedLocal -or $env:APPDATA -cne $savedRoaming) { throw 'Oracle failure did not restore the driver environment.' }
        $script:oracleThrows = $false
        foreach ($failure in @('nonzero', 'query-failure')) {
            [HiddenDriverContract]::ExitCode = $(if ($failure -eq 'nonzero') { 7 } else { 0 })
            [HiddenDriverContract]::ExitQueryFails = $failure -eq 'query-failure'
            [HiddenDriverContract]::Waits = [HiddenDriverContract]::Stops = [HiddenDriverContract]::ExitReads = 0
            $blocked = $false
            try {
                Invoke-HiddenDriver -Script 'unused.ps1' -Bin (Join-Path $fixture 'bin') -Run (Join-Path $fixture $failure) -TimeoutSeconds 1 -Label 'managed exit failure fixture' 6>$null
            } catch {
                $expected = if ($failure -eq 'nonzero') { 'Hidden driver failed with exit 7;' } else { 'Hidden driver exit code query failed.' }
                $blocked = $_.Exception.Message.StartsWith($expected, [StringComparison]::Ordinal)
            }
            if (-not $blocked -or [HiddenDriverContract]::Stops -ne 1 -or [HiddenDriverContract]::ExitReads -ne 1) { throw 'Driver exit failures must reject success and clean the owned job.' }
            if ($env:LOCALAPPDATA -cne $savedLocal -or $env:APPDATA -cne $savedRoaming) { throw 'Exit failure did not restore the driver environment.' }
        }
    } finally {
        $env:LOCALAPPDATA = $savedLocal; $env:APPDATA = $savedRoaming
        if ([IO.Path]::GetDirectoryName($fixture) -eq [IO.Path]::GetTempPath().TrimEnd('\', '/') -and
            (Split-Path -Leaf $fixture) -match '^noctty-hidden-contract-[0-9a-f]{32}$') { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
}
Assert-HiddenMutation 'driver desktop null' $driverFunction ($driverFunction.Replace('"WinSta0\$desktopName"', '$null')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'driver runner gate removed' $driverFunction ($driverFunction.Replace('    Assert-HiddenRunner', '')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'outer window oracle removed' $driverFunction ($driverFunction -replace '(?m)^\s+Assert-HiddenDefaultDesktop[^\r\n]*', '') ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'outer thread metadata removed' $driverFunction ($driverFunction -replace '(?m)^\s+Assert-HiddenDesktop[^\r\n]*', '') ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'nonzero driver exit accepted' $driverFunction ($driverFunction.Replace('if ($code -ne 0)', 'if ($false)')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'driver exit API failure accepted' $driverFunction ($driverFunction.Replace("throw 'Hidden driver exit code query failed.'", '$null = 0')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'owned driver job cleanup removed' $driverFunction ($driverFunction.Replace('$ownedProcessCount = [HiddenDriverContract]::StopOwnedJob($job)', '$ownedProcessCount = 0')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'original LOCALAPPDATA inherited' $driverFunction ($driverFunction.Replace("Join-Path `$Run 'localappdata';", '$oldLocal;')) ${function:Test-HiddenDriverCode}
Assert-HiddenMutation 'original APPDATA inherited' $driverFunction ($driverFunction.Replace("Join-Path `$Run 'appdata'", '$oldRoaming')) ${function:Test-HiddenDriverCode}

$runnerGuard = Get-HiddenFunction $hiddenLibText 'Assert-HiddenRunner'
function Test-HiddenRunnerGuard([string] $Code) {
    . ([scriptblock]::Create($Code))
    $savedActions = $env:GITHUB_ACTIONS; $savedRunner = $env:RUNNER_ENVIRONMENT
    try {
        foreach ($fixture in @(@('true', 'github-hosted', $false), @('true', 'self-hosted', $true), @('', '', $true), @('', 'github-hosted', $true))) {
            $env:GITHUB_ACTIONS = $fixture[0]; $env:RUNNER_ENVIRONMENT = $fixture[1]
            $blocked = $false
            try { Assert-HiddenRunner } catch { $blocked = $true }
            if ($blocked -ne $fixture[2]) { throw 'Runner gate accepted a local/self-hosted launch or refused the hosted fixture.' }
        }
    } finally { $env:GITHUB_ACTIONS = $savedActions; $env:RUNNER_ENVIRONMENT = $savedRunner }
}
Assert-HiddenMutation 'self-hosted runner allowed' $runnerGuard ($runnerGuard.Replace("'github-hosted'", "'self-hosted'")) ${function:Test-HiddenRunnerGuard}
foreach ($script in $hiddenScripts) {
    $text = Remove-PowerShellComments (Get-Content -LiteralPath $script -Raw)
    if ($text -notmatch "(?m)^\. \(Join-Path .+ 'hidden-win11-lib.ps1'\)\r?\nAssert-HiddenRunner\r?\n" -or
        $text -notmatch '(?m)^\s+Assert-HiddenDesktop -Job \$job -DesktopName \$desktopName -ReceiptPath') {
        throw 'Hidden harness lost its entry runner gate or observed-thread desktop checks.'
    }
}

if (-not ('HiddenDesktopContract' -as [type])) {
    Add-Type @'
using System;
public static class HiddenDesktopContract {
    public static object[] Rows;
    public static bool QueryFails;
    public static int[] Seen;
    public static int ObserveCalls;
    public static int[] JobProcessIds(IntPtr job) { if (QueryFails) throw new Exception("fixture query failure"); return new int[] { 41, 42 }; }
    public static object[] ObserveDesktopThreads(int[] ids) { ObserveCalls++; Seen = ids; return Rows; }
}
'@
}
$desktopAssertion = (Get-HiddenFunction $hiddenLibText 'Assert-HiddenDesktop').Replace('[HiddenWin]', '[HiddenDesktopContract]')
function Test-HiddenDesktopAssertion([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fixture in @(
        @{ Desktop = 'noctty-hw-fixture'; Blocked = $false }
        @{ Desktop = 'Default'; Blocked = $true }
        @{ Desktop = $null; Blocked = $true }
        @{ Unconnected = $true; Blocked = $false }
        @{ Unconnected = $true; Error = 'query failed'; Blocked = $true }
        @{ Desktop = 'noctty-hw-fixture'; Error = 'query failed'; Blocked = $true }
        @{ Exited = $true; Error = 'query failed'; Blocked = $false }
        @{ Exited = $true; Desktop = 'Default'; Blocked = $true }
        @{ ThreadExited = $true; Blocked = $false }
        @{ ThreadExited = $true; Desktop = 'Default'; Blocked = $true }
        @{ Empty = $true; Blocked = $true }
        @{ QueryFails = $true; Blocked = $true }
    )) {
        $script:hiddenDesktopSamples = @{}
        [HiddenDesktopContract]::ObserveCalls = 0
        $receipts = [Collections.Generic.List[string]]::new()
        function Add-Content {
            param([Parameter(ValueFromPipeline)] [string] $Value, [string] $LiteralPath)
            process { $receipts.Add($Value) }
        }
        [HiddenDesktopContract]::QueryFails = [bool]$fixture.QueryFails
        [HiddenDesktopContract]::Rows = @(if (-not $fixture.Empty) { @{
            ProcessId = 41; ThreadId = 123; Desktop = $fixture.Desktop; Error = $fixture.Error; Exited = [bool]$fixture.Exited; ThreadExited = [bool]$fixture.ThreadExited; Unconnected = [bool]$fixture.Unconnected
        } })
        $blocked = $false
        try { Assert-HiddenDesktop -Job ([IntPtr]7) -DesktopName 'noctty-hw-fixture' -ReceiptPath 'unused.jsonl' -DriverPid 40 } catch { $blocked = $true }
        if ($blocked -ne $fixture.Blocked -or $receipts.Count -ne 1) { throw 'Desktop observation did not fail closed or preserve its metadata receipt.' }
        if (-not $fixture.QueryFails -and -not $fixture.Empty -and ([HiddenDesktopContract]::Seen -join ',') -ne '41,42,40') {
            throw 'Desktop observation omitted the driver or a job process.'
        }
        $receipt = $receipts[0] | ConvertFrom-Json
        if ($receipt.ExpectedDesktop -cne 'noctty-hw-fixture' -or (-not $fixture.QueryFails -and -not $fixture.Empty -and $receipt.Threads.Count -ne 1)) {
            throw 'Desktop receipt lost expected desktop or thread metadata.'
        }
        if (-not $blocked) {
            Assert-HiddenDesktop -Job ([IntPtr]7) -DesktopName 'noctty-hw-fixture' -ReceiptPath 'unused.jsonl' -DriverPid 40
            if ($receipts.Count -ne 1 -or [HiddenDesktopContract]::ObserveCalls -ne 1) { throw 'Thread metadata must be sampled at most once per second.' }
            foreach ($key in @($script:hiddenDesktopSamples.Keys)) { $script:hiddenDesktopSamples[$key] = [datetime]::UtcNow.AddSeconds(-2) }
            Assert-HiddenDesktop -Job ([IntPtr]7) -DesktopName 'noctty-hw-fixture' -ReceiptPath 'unused.jsonl' -DriverPid 40
            if ($receipts.Count -ne 2 -or [HiddenDesktopContract]::ObserveCalls -ne 2) { throw 'Thread metadata must resume sampling after one second.' }
        }
    }
}
Assert-HiddenMutation 'wrong observed desktop accepted' $desktopAssertion ($desktopAssertion.Replace('($row.Desktop -and $row.Desktop -cne $DesktopName)', '$false')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'live desktop query error ignored' $desktopAssertion ($desktopAssertion.Replace('$row.Error -or ', '')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'desktop receipt removed' $desktopAssertion ($desktopAssertion.Replace('Add-Content -LiteralPath $ReceiptPath', 'Out-Null')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'unconnected observation rejected' $desktopAssertion ($desktopAssertion.Replace(' -and -not $row.Unconnected', '')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'vanished thread observation rejected' $desktopAssertion ($desktopAssertion.Replace(' -and -not $row.ThreadExited', '')) ${function:Test-HiddenDesktopAssertion}
Assert-HiddenMutation 'metadata sampling unthrottled' $desktopAssertion ($desktopAssertion.Replace('.TotalSeconds -lt 1', '.TotalSeconds -lt 0')) ${function:Test-HiddenDesktopAssertion}

if (-not ('HiddenDefaultDesktopContract' -as [type])) {
    Add-Type @'
using System;
public static class HiddenDefaultDesktopContract {
    public static object[] Windows;
    public static bool QueryFails;
    public static object[] VisibleJobWindows(IntPtr job) { if (job != new IntPtr(7) || QueryFails) throw new Exception("fixture query failure"); return Windows; }
}
'@
}
$defaultAssertion = (Get-HiddenFunction $hiddenLibText 'Assert-HiddenDefaultDesktop').Replace('[HiddenWin]', '[HiddenDefaultDesktopContract]')
function Test-HiddenDefaultDesktopAssertion([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($fixture in @(@{ WindowCount = 0 }, @{ WindowCount = 1; Blocked = $true }, @{ QueryFails = $true; Blocked = $true })) {
        $receipts = [Collections.Generic.List[string]]::new()
        function Add-Content {
            param([Parameter(ValueFromPipeline)] [string] $Value, [string] $LiteralPath)
            process { $receipts.Add($Value) }
        }
        [HiddenDefaultDesktopContract]::QueryFails = [bool]$fixture.QueryFails
        [HiddenDefaultDesktopContract]::Windows = @(if ($fixture.WindowCount) { @{ ProcessId = 42; ThreadId = 123 } })
        $blocked = $false
        try { Assert-HiddenDefaultDesktop -Job ([IntPtr]7) -ReceiptPath 'unused.jsonl' } catch { $blocked = $true }
        if ($blocked -ne [bool]$fixture.Blocked -or $receipts.Count -ne [int][bool]$fixture.Blocked) { throw 'Default-desktop job-window oracle lost rejection or failure evidence.' }
    }
}
Assert-HiddenMutation 'visible default job window accepted' $defaultAssertion ($defaultAssertion.Replace('if ($windows.Count)', 'if ($false)')) ${function:Test-HiddenDefaultDesktopAssertion}

# Real native observation only: no process/window is created and no existing job is touched.
. $hiddenLib
$nativeRows = @([HiddenWin]::ObserveDesktopThreads([int[]]@($PID)))
if (-not $nativeRows.Count -or @($nativeRows | Where-Object { $_.Error -or (-not $_.Desktop -and -not $_.Unconnected -and -not $_.Exited -and -not $_.ThreadExited) }).Count) {
    throw 'Native observation of this PowerShell process produced query error rows.'
}
if (-not [HiddenWin]::CurrentDesktopName()) { throw 'Native current-desktop connection did not resolve.' }
$emptyJob = [HiddenWin]::CreateOwnedJob()
try {
    if (@([HiddenWin]::JobProcessIds($emptyJob)).Count -or @([HiddenWin]::VisibleJobWindows($emptyJob)).Count) { throw 'A new owned job must have no process or visible job window.' }
} finally { $null = [HiddenWin]::StopOwnedJob($emptyJob) }
Write-Host "Native no-launch desktop checks: $($nativeRows.Count) own-process threads ($(@($nativeRows | Where-Object Desktop).Count) connected, $(@($nativeRows | Where-Object Unconnected).Count) unconnected) without errors; empty job/process/window queries passed"

# The live Default-window control is hosted-only. Here its real functions run with
# managed Win32 and filesystem seams; the window C# is compiled, never invoked.
$controlPath = Join-Path $repoRoot 'test\windows\hidden-win11-desktop-control.ps1'
$controlText = Remove-PowerShellComments (Get-Content -LiteralPath $controlPath -Raw)
function Test-DesktopControlStructure([string] $Code) {
    if ($Code -notmatch "(?m)^\. \(Join-Path .+ 'hidden-win11-lib.ps1'\)\r?\nAssert-HiddenRunner\r?\n" -or
        $Code -notmatch "(?s)switch \(\`$Mode\).*?'Parent' \{ Invoke-DesktopControlParent -Run \`$Run \}.*?'Nested' \{ Invoke-DesktopControlNested -Run \`$Run \}.*?'Window' \{ Invoke-DesktopControlWindow \}" -or
        $Code -notmatch $hiddenForbidden) { throw 'Desktop control lost its entry gate, mode dispatch or prohibited-operation boundary.' }
}
Assert-HiddenMutation 'desktop control entry gate removed' $controlText ($controlText.Replace("Assert-HiddenRunner`n`$controlScript", "`$controlScript")) ${function:Test-DesktopControlStructure}
$controlFunctions = (@('Start-DesktopControlHelper', 'Invoke-DesktopControlNested', 'Invoke-DesktopControlParent', 'Invoke-DesktopControlWindow') |
    ForEach-Object { Get-HiddenFunction $controlText $_ }) -join "`n"
$controlAst = [Management.Automation.Language.Parser]::ParseInput($controlText, [ref]$null, [ref]$null)
$windowCode = $controlAst.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $n.Value.StartsWith("using System;`n") -and $n.Value.Contains('class HiddenDesktopControlWindow') }, $true).Value
if (-not $windowCode) { throw 'Desktop control window C# was not found.' }
if (-not ('HiddenDesktopControlWindow' -as [type])) { Add-Type -TypeDefinition $windowCode }
if (-not ('HiddenControlContract' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
public static class HiddenControlContract {
    public static int Gates, Creates, Launches, Waits, Runs;
    public static bool WrongWindow, MissingMember, OracleFails, StopFails;
    public static List<long> Stopped = new List<long>();
    public struct ProcessInfo { public int pid; public IntPtr process, thread; }
    public static string CurrentDesktopName() { return "Default"; }
    public static IntPtr CreateOwnedJob() { Creates++; return new IntPtr(7); }
    public static ProcessInfo Launch(string a, string c, string w, string d, IntPtr j, string e) {
        if (Gates == 0 || d != "WinSta0\\Default" || j != new IntPtr(7)) throw new Exception("Invalid control launch");
        Launches++; return new ProcessInfo { pid = c.EndsWith("Window") ? 42 : 41, process = new IntPtr(9) };
    }
    public static int[] JobProcessIds(IntPtr j) { return MissingMember ? new int[] { 41 } : new int[] { 41, 42 }; }
    public class Window { public int ProcessId; }
    public static Window[] VisibleJobWindows(IntPtr j) {
        if (OracleFails) throw new Exception("fixture oracle failure");
        return new Window[] { new Window { ProcessId = WrongWindow ? 99 : 42 } };
    }
    public static uint WaitForSingleObject(IntPtr p, uint ms) { return ms == 10000 || Waits++ > 0 ? 0u : 258u; }
    public static bool GetExitCodeProcess(IntPtr p, out uint code) { code = 0; return true; }
    public static uint StopOwnedJob(IntPtr j) { Stopped.Add(j.ToInt64()); if (StopFails) throw new Exception("fixture stop failure"); return 1; }
    public static bool CloseHandle(IntPtr p) { return true; }
    public static void Run() { Runs++; }
}
'@
}
$controlFunctions = $controlFunctions.Replace('[HiddenWin]', '[HiddenControlContract]').Replace('[HiddenDesktopControlWindow]::Run()', '[HiddenControlContract]::Run()')
function Test-DesktopControlFunctions([string] $Code) {
    . ([scriptblock]::Create($Code))
    $controlScript = 'C:\fixture\control.ps1'
    # Replace Add-Type only for the extracted window function. Its C# compiled above.
    function Add-Type { }
    foreach ($fixture in @(
        @{ Mode = 'Parent' }, @{ Mode = 'Nested' }, @{ Mode = 'Window' }
        @{ Mode = 'Parent'; WrongWindow = $true; Blocked = $true }
        @{ Mode = 'Parent'; MissingMember = $true; Blocked = $true }
        @{ Mode = 'Nested'; MissingMember = $true; Blocked = $true }
        @{ Mode = 'Parent'; OracleFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; StopFails = $true; Blocked = $true }
        @{ Mode = 'Nested'; StopFails = $true; Blocked = $true }
        @{ Mode = 'Parent'; Existing = $true; Blocked = $true }
        @{ Mode = 'Parent'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Nested'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Window'; GateFails = $true; Blocked = $true }
        @{ Mode = 'Helper'; GateFails = $true; Blocked = $true }
    )) {
        [HiddenControlContract]::Gates = [HiddenControlContract]::Creates = [HiddenControlContract]::Launches = [HiddenControlContract]::Waits = [HiddenControlContract]::Runs = 0
        [HiddenControlContract]::Stopped.Clear()
        foreach ($field in @('WrongWindow', 'MissingMember', 'OracleFails', 'StopFails')) { [HiddenControlContract].GetField($field).SetValue($null, [bool]$fixture[$field]) }
        $writes = @{}
        function Assert-HiddenRunner { [HiddenControlContract]::Gates++; if ($fixture.GateFails) { throw 'fixture runner gate' } }
        function Test-Path {
            param([string]$LiteralPath)
            if ($LiteralPath -eq 'C:\fixture\run') { return [bool]$fixture.Existing }
            return $true
        }
        function New-Item { }
        function Set-Content {
            param([Parameter(ValueFromPipeline)]$Value, [string]$LiteralPath)
            process { $writes[(Split-Path -Leaf $LiteralPath)] = $Value }
        }
        function Get-Content {
            param([string]$LiteralPath, [switch]$Raw)
            if ($LiteralPath.EndsWith('window-helper.json')) { return '{"WindowPid":42,"InnerMember":true}' }
            return '{"InnerJobCleanedUp":true,"OwnedProcessCount":1}'
        }
        $blocked = $false
        try {
            switch ($fixture.Mode) {
                'Parent' { Invoke-DesktopControlParent -Run 'C:\fixture\run' 6>$null }
                'Nested' { Invoke-DesktopControlNested -Run 'C:\fixture\run' }
                'Window' { Invoke-DesktopControlWindow }
                'Helper' { $null = Start-DesktopControlHelper -Job ([IntPtr]7) -Run 'C:\fixture\run' -HelperMode 'Nested' }
            }
        } catch { $blocked = $true }
        if ($blocked -ne [bool]$fixture.Blocked) { throw "Desktop control fixture $($fixture | ConvertTo-Json -Compress) lost its expected result." }
        if ($fixture.GateFails -or $fixture.Existing) {
            if ([HiddenControlContract]::Launches -or [HiddenControlContract]::Creates -or [HiddenControlContract]::Runs -or $writes.Count) { throw 'Blocked control must not launch, create jobs/windows or write receipts.' }
            continue
        }
        if ($fixture.Mode -eq 'Window') {
            if ([HiddenControlContract]::Gates -ne 2 -or [HiddenControlContract]::Runs -ne 1) { throw 'Window mode lost its entry/pre-window runner gate.' }
            continue
        }
        if ([HiddenControlContract]::Gates -ne 2 -or [HiddenControlContract]::Creates -ne 1 -or [HiddenControlContract]::Launches -ne 1 -or
            [HiddenControlContract]::Stopped.Count -ne 1 -or [HiddenControlContract]::Stopped[0] -ne 7) { throw 'Parent/nested control lost gate, owned job, helper launch or exact-job cleanup.' }
        if ($fixture.Mode -eq 'Parent') {
            $receipt = $writes['desktop-control-results.json'] | ConvertFrom-Json
            if (-not $receipt -or $receipt.Passed -ne (-not [bool]$fixture.Blocked) -or
                ($receipt.Passed -and ($receipt.WindowPid -ne 42 -or -not $receipt.DefaultOracleDetectedWindow -or -not $receipt.OuterJobContainsNestedWindow -or
                    -not $receipt.InnerJobCleanedUp -or -not $receipt.OuterJobCleanedUp))) { throw 'Parent control lost its sanitized result/cleanup receipt.' }
        } else {
            $receipt = $writes['nested-cleanup.json'] | ConvertFrom-Json
            if (-not $receipt -or $receipt.InnerJobCleanedUp -eq [bool]$fixture.StopFails) { throw 'Nested cleanup receipt lost success/failure evidence.' }
        }
    }
}
Assert-HiddenMutation 'desktop control mode gates removed' $controlFunctions ($controlFunctions -replace '(?m)^\s+Assert-HiddenRunner[^\r\n]*', '') ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control inner job removed' $controlFunctions ($controlFunctions.Replace('$inner = [HiddenControlContract]::CreateOwnedJob()', '$inner = [IntPtr]::Zero')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control outer membership ignored' $controlFunctions ($controlFunctions.Replace('$outerIds -contains $windowPid', '$true')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control default oracle removed' $controlFunctions ($controlFunctions.Replace('@([HiddenControlContract]::VisibleJobWindows($outer))', '@()')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control known window PID ignored' $controlFunctions ($controlFunctions.Replace('Where-Object ProcessId -eq $windowPid', 'Where-Object ProcessId -ne $windowPid')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control owned cleanup removed' $controlFunctions ($controlFunctions.Replace('[HiddenControlContract]::StopOwnedJob($inner)', '0').Replace('[HiddenControlContract]::StopOwnedJob($outer)', '0')) ${function:Test-DesktopControlFunctions}
Assert-HiddenMutation 'desktop control existing directory allowed' $controlFunctions ($controlFunctions.Replace("if (Test-Path -LiteralPath `$Run) { throw 'Run directory must be new.' }", '')) ${function:Test-DesktopControlFunctions}

$embeddingText = Remove-PowerShellComments (Get-Content -LiteralPath $hiddenScripts[1] -Raw)
$embeddingArguments = [regex]::Match($embeddingText, '(?ms)^\$uniqueClass =.*?(?=^Assert-EmbeddingDelegationSafe|^\$started =)').Value
function Test-EmbeddingArguments([string] $Code) {
    if (-not $Code) { throw 'Embedding argument construction missing.' }
    foreach ($control in @($false, $true)) {
        & {
            $NegativeControl = $control
            . ([scriptblock]::Create($Code))
            $marker = [array]::IndexOf($launchArguments, '-Embedding')
            if ($launchArguments[0] -cne '--single-instance=false' -or $launchArguments[1] -notmatch '^--class=noctty-test-pkg76-embedding-[0-9a-f]{8}$' -or
                ($control -and $marker -ne -1) -or (-not $control -and ($marker -ne 2 -or $launchArguments.Count -ne 3))) { throw 'Embedding isolation must precede the stop marker.' }
        }
    }
}
Assert-HiddenMutation 'embedding stop marker before isolation' $embeddingArguments ($embeddingArguments.Replace("`$launchArguments += '-Embedding'", "`$launchArguments = @('-Embedding') + `$launchArguments")) ${function:Test-EmbeddingArguments}
$embeddingAst = [Management.Automation.Language.Parser]::ParseInput($embeddingText, [ref]$null, [ref]$null)
$oracle = $embeddingAst.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Check' -and $node.CommandElements[1].Extent.Text -eq "'it opens no visible top-level window'" }, $true).Extent.Text
function Test-EmbeddingOracle([string] $Code) {
    if (-not $Code) { throw 'Embedding visible UI oracle missing.' }
    foreach ($class in @('', 'noctty.win32.host', '#32770')) {
        & {
            $classes = [Collections.Generic.HashSet[string]]::new()
            if ($class) { [void]$classes.Add($class) }
            function Check([string] $Name, [bool] $Passed, $Expected, $Actual) {
                if ($Passed -ne (-not [bool]$class)) { throw 'Embedding oracle accepted unexpected process UI.' }
            }
            . ([scriptblock]::Create($Code))
        }
    }
}
Assert-HiddenMutation 'host-only embedding oracle misses dialog' $oracle ($oracle.Replace('$classes.Count -eq 0', "-not `$classes.Contains('noctty.win32.host')")) ${function:Test-EmbeddingOracle}

$delegationGuard = Get-HiddenFunction $hiddenLibText 'Assert-EmbeddingDelegationSafe'
function Test-EmbeddingDelegationGuard([string] $Code) {
    . ([scriptblock]::Create($Code))
    foreach ($value in @($null, '', '{11111111-1111-1111-1111-111111111111}', '{33368c6f-d328-410c-b225-26dc9f12c728}', '33368C6F-D328-410C-B225-26DC9F12C728', 'missing-key', 'unreadable')) {
        function Get-ItemProperty {
            param($LiteralPath, $ErrorAction)
            if ($LiteralPath -cne 'HKCU:\Console\%%Startup' -or $ErrorAction -cne 'Stop') { throw 'Wrong delegation registry read.' }
            if ($value -eq 'missing-key') { throw [Management.Automation.ItemNotFoundException]::new('Fixture missing key') }
            if ($value -eq 'unreadable') { throw [UnauthorizedAccessException]::new('Fixture unreadable key') }
            return @{ DelegationTerminal = $value }
        }
        $blocked = $false
        try { Assert-EmbeddingDelegationSafe } catch { $blocked = $true }
        $expected = $value -like '*33368*-d328-410c-b225-26dc9f12c728*' -or $value -eq 'unreadable'
        if ($blocked -ne $expected) { throw 'Delegation guard failed to distinguish absent/unrelated selection from noctty or unreadable state.' }
    }
}
Assert-HiddenMutation 'real COM handoff CLSID unguarded' $delegationGuard ($delegationGuard.Replace('33368C6F-D328-410C-B225-26DC9F12C728', '11111111-1111-1111-1111-111111111111')) ${function:Test-EmbeddingDelegationGuard}
# Check the actual call sites as well as the callable guard; comments are already removed.
function Test-EmbeddingGuardCalls([string] $Code) {
    if ($Code -notmatch '(?m)^Assert-EmbeddingDelegationSafe\r?\n\s*if \(-not \$Driver\)' -or
        $Code -notmatch '(?m)^Assert-EmbeddingDelegationSafe\r?\n\$started = Start-HiddenNoctty') { throw 'Embedding launch lost the entry/prelaunch delegation guard.' }
}
Assert-HiddenMutation 'delegation guard call removed' $embeddingText ($embeddingText -replace '(?m)^Assert-EmbeddingDelegationSafe\r?\n', '') ${function:Test-EmbeddingGuardCalls}

$profileText = Remove-PowerShellComments (Get-Content -LiteralPath $hiddenScripts[0] -Raw)
$requiredProfileLoop = [regex]::Match($profileText, '(?ms)^foreach \(\$key in \$Profile\).*?^}').Value
$requiredProfileForwarding = [regex]::Match($profileText, '(?m)^    if \(\$RequireAll\)[^\r\n]*').Value
function Test-RequiredProfile([string] $Code) {
    foreach ($required in @($false, $true)) {
        & {
            $RequireAll = $required; $extra = @(); $Profile = @('missing.exe')
            $expectations = @{ 'missing.exe' = @{} }; $cases = [Collections.Generic.List[object]]::new()
            $script:requiredFailures = 0
            function Test-Available { return $false }
            function Check($Case, $Name, $Passed, $Expected, $Actual) { if (-not $Passed) { $script:requiredFailures++ } }
            function Invoke-Case { throw 'Unavailable profile must never launch.' }
            . ([scriptblock]::Create($Code))
            if (($extra -contains '-RequireAll') -ne $required -or $script:requiredFailures -ne [int]$required -or
                $cases.Count -ne 1 -or $cases[0].Result -cne 'skipped') { throw 'Required profile forwarding or missing-profile failure was lost.' }
        }
    }
}
$requiredProfileCode = $requiredProfileForwarding + "`n" + $requiredProfileLoop
Assert-HiddenMutation 'required-profile skip passes' $requiredProfileCode ($requiredProfileCode.Replace("Check `$key 'required profile is installed and detected' `$false", "Check `$key 'required profile is installed and detected' `$true")) ${function:Test-RequiredProfile}
Assert-HiddenMutation 'required-profile switch not forwarded' $requiredProfileCode ($requiredProfileCode.Replace("`$extra += '-RequireAll'", '$extra += ""')) ${function:Test-RequiredProfile}

# The negative control must forward its renderer and seed it before the stop marker.
$embeddingForwarding = [regex]::Match($embeddingText, '(?ms)^    \$extra = @\(\);.*?(?=^    Invoke-HiddenDriver)').Value
function Test-EmbeddingRendererForwarding([string] $Code) {
    $AllowProductAumid = $false; $NegativeControl = $true; $Renderer = 'd3d11-warp'
    . ([scriptblock]::Create($Code))
    $marker = [array]::IndexOf($extra, '-Renderer')
    if ($marker -lt 0 -or $extra[$marker + 1] -cne $Renderer -or $extra -notcontains '-NegativeControl') { throw 'Embedding negative control must forward its renderer.' }
}
Assert-HiddenMutation 'embedding renderer not forwarded' $embeddingForwarding ($embeddingForwarding.Replace("@('-Renderer', `$Renderer)", '@()')) ${function:Test-EmbeddingRendererForwarding}
$embeddingConfig = [regex]::Match($embeddingText, '(?m)^    ''config\.ghostty''\s*= (.*)$').Groups[1].Value
& {
    $Renderer = 'd3d11-warp'
    if ((& ([scriptblock]::Create($embeddingConfig))) -notmatch '(?m)^renderer = d3d11-warp$') { throw 'Embedding negative control config must select its renderer.' }
}

$gitFunctions = (Get-HiddenFunction $profileText 'Get-AvailableGitBash') + "`n" + (Get-HiddenFunction $profileText 'Test-Available')
function Test-GitBashDiscovery([string] $Code) {
    . ([scriptblock]::Create($Code))
    $savedRoot = $env:SystemRoot
    try {
        $env:SystemRoot = 'C:\Windows'
        $fixtures = @(
            @{ Git = 'C:\Custom\cmd\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ Git = 'C:\Custom\bin\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ Git = 'C:\Custom\mingw64\bin\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ Git = 'C:\Custom\ucrt64\bin\git.exe'; Files = @('C:\Custom\bin\bash.exe'); Expected = 'C:\Custom\bin\bash.exe' }
            @{ User = 'C:\PerUser'; Machine = 'C:\Machine'; Files = @('C:\PerUser\bin\bash.exe', 'C:\Machine\bin\bash.exe'); Expected = 'C:\PerUser\bin\bash.exe' }
            @{ User = 'C:\Removed'; Machine = 'C:\Machine'; Files = @('C:\Machine\bin\bash.exe'); Expected = 'C:\Machine\bin\bash.exe' }
            @{ Bash = 'C:\Cygwin\bin\bash.exe'; Expected = 'C:\Cygwin\bin\bash.exe' }
            @{ Bash = 'c:/WINDOWS/Sysnative/bash.exe'; Expected = $null }
            @{ Bash = 'C:\Users\fixture\WindowsApps\bash.exe'; Expected = $null }
            @{ Git = 'C:\Shim\git.exe'; Bash = 'C:\Windows\System32\bash.exe'; Expected = $null }
            @{ Expected = $null }
        )
        foreach ($fixture in $fixtures) {
            function Find-LocalShellOnPath([string] $Name) { if ($Name -eq 'git.exe') { return $fixture.Git }; return $fixture.Bash }
            function Get-GitInstallRoot($Hive) { if ($Hive -eq [Microsoft.Win32.RegistryHive]::CurrentUser) { return $fixture.User }; return $fixture.Machine }
            function Test-LocalShellFile([string] $Path) { return $fixture.Files -icontains $Path }
            if ((Get-AvailableGitBash) -ine $fixture.Expected -or (Test-Available 'git-bash') -ne [bool]$fixture.Expected) { throw 'Git Bash availability disagrees with supported app discovery.' }
        }
    } finally { $env:SystemRoot = $savedRoot }
}
Assert-HiddenMutation 'PATH git install ignored' $gitFunctions ($gitFunctions.Replace("Find-LocalShellOnPath 'git.exe'", '$null')) ${function:Test-GitBashDiscovery}
Assert-HiddenMutation 'per-user Git install ignored' $gitFunctions ($gitFunctions.Replace('[Microsoft.Win32.RegistryHive]::CurrentUser, ', '')) ${function:Test-GitBashDiscovery}
Assert-HiddenMutation 'WSL bash accepted' $gitFunctions ($gitFunctions.Replace('return $null }', 'return $bash }')) ${function:Test-GitBashDiscovery}
# The filesystem probe must reject unsafe shapes before it can query a path.
& {
    . ([scriptblock]::Create((Get-HiddenFunction $profileText 'Test-LocalShellFile')))
    $probes = [Collections.Generic.List[string]]::new()
    function Test-Path { $probes.Add('queried'); return $false }
    foreach ($path in @('\\server\share\bash.exe', '\??\UNC\server\bash.exe', '//server/share/bash.exe', 'relative\bash.exe', 'C:bash.exe')) {
        if (Test-LocalShellFile $path) { throw 'Unsafe Git Bash path was accepted.' }
    }
    if ($probes.Count -ne 0) { throw 'Unsafe Git Bash path reached the filesystem probe.' }
}
& {
    . ([scriptblock]::Create((Get-HiddenFunction $profileText 'Find-LocalShellOnPath')))
    $probes = [Collections.Generic.List[string]]::new()
    function Test-LocalShellFile([string] $Path) { $probes.Add($Path); return $Path -ieq 'C:\PKG76\last\git.exe' }
    $savedPath = $env:PATH
    try {
        $env:PATH = 'relative;\\server\share;"C:\PKG76\bin";C:\PKG76\last'
        if ((Find-LocalShellOnPath 'git.exe') -ine 'C:\PKG76\last\git.exe' -or $probes.Count -ne 2 -or
            $probes[0] -ine 'C:\PKG76\bin\git.exe') { throw 'Local PATH lookup lost quoting/order or queried an unsafe component.' }
    } finally { $env:PATH = $savedPath }
}

# Pin the actual executable workflow line, so a comment or reporting-only invocation cannot pass.
$skipWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\windows10-branches.yml') -Raw
function Test-HiddenWorkflowCoverage([string] $Code) {
    $profileCommand = [regex]::Match($Code, '(?m)^        run: (\./test/windows/hidden-win11-profile-matrix\.ps1[^\r\n]*)$').Groups[1].Value
    $controlCommand = [regex]::Matches($Code, '(?m)^        run: (\./test/windows/hidden-win11-embedding-idle\.ps1[^\r\n]*)$') |
        ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match ' -NegativeControl(?: |$)' }
    if ($profileCommand -notmatch ' -RequireAll(?: |$)' -or @($controlCommand).Count -ne 1 -or $controlCommand -notmatch ' -Renderer d3d11-warp(?: |$)') {
        throw 'Hosted workflow must require all profiles and run the embedding window negative control with WARP.'
    }
    foreach ($exclude in @('!hidden-evidence/**/*.exe', '!hidden-evidence/**/*.dll', '!hidden-evidence/**/*.pdb', '!hidden-evidence/**/share/**')) {
        if ($Code -notmatch ('(?m)^            ' + [regex]::Escape($exclude) + '\r?$')) { throw 'Hidden evidence upload must exclude copied binaries and resources.' }
    }
}
Assert-HiddenMutation 'workflow missing-profile coverage optional' $skipWorkflow ($skipWorkflow.Replace(' -RequireAll', '')) ${function:Test-HiddenWorkflowCoverage}
Assert-HiddenMutation 'workflow embedding negative control lost' $skipWorkflow ($skipWorkflow.Replace(' -NegativeControl', '')) ${function:Test-HiddenWorkflowCoverage}
Assert-HiddenMutation 'workflow binaries uploaded' $skipWorkflow ($skipWorkflow.Replace('!hidden-evidence/**/*.exe', 'hidden-evidence/**/*.exe')) ${function:Test-HiddenWorkflowCoverage}
function Test-SkipWorkflow([string] $Code) {
    $command = [regex]::Match($Code, '(?m)^        run: (\./scripts/check-test-skips\.ps1[^\r\n]*)$').Groups[1].Value
    if ($command -cne './scripts/check-test-skips.ps1 -TestLog ghostty-test.log -Runner windows-2022') { throw 'Windows 2022 workflow must enforce its skip budget.' }
}
Assert-HiddenMutation 'workflow reporting only' $skipWorkflow ($skipWorkflow.Replace('-Runner windows-2022', '-Runner windows-2022 -Report')) ${function:Test-SkipWorkflow}

# The skip budget, run on synthetic output of the test executable.
$skipScript = Join-Path $repoRoot 'scripts\check-test-skips.ps1'
$skipBudget = Join-Path $repoRoot 'test\windows\test-skip-budget.json'
$budget = Get-Content -LiteralPath $skipBudget -Raw | ConvertFrom-Json
if ($budget.schema_version -ne 1 -or -not $budget.familyPrefix) { throw 'test-skip-budget.json lost its schema version or family prefix.' }
if (-not $budget.runners.'windows-2022') { throw 'The enforcing Windows 2022 workflow needs a measured runner budget.' }
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
    function Invoke-SkipFixture([string] $Name, [string[]] $Lines, [string] $Runner = 'r', [switch] $Report) {
        $log = Join-Path $skipTemp "$Name.log"
        Set-Content -LiteralPath $log -Value $Lines
        $reportArguments = @(); if ($Report) { $reportArguments += '-Report' }
        $output = & pwsh -NoProfile -File $skipScript -TestLog $log -Runner $Runner -BudgetFile $fixtureBudget @reportArguments 2>&1 | Out-String
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
        @{ Name = 'all tests passed summary'; Exit = 0; Match = 'PASS'; Lines = @('1/1 font.b.test.runs...OK', 'All 1 tests passed.') }
        @{ Name = 'reporting an unknown runner'; Exit = 0; Match = 'font.a.test.allowed skip'; Runner = 'nowhere'; Report = $true; Lines = $okRun }
        @{ Name = 'reporting an incomplete log'; Exit = 1; Match = 'did not finish'; Report = $true; Lines = @('1/2 x...OK') }
        @{ Name = 'reporting malformed counts'; Exit = 1; Match = 'inconsistent'; Report = $true; Lines = @('1/1 x...OK', '2 passed; 0 skipped; 0 failed.') }
        @{ Name = 'reporting without tests'; Exit = 1; Match = 'no per-test lines'; Report = $true; Lines = @('some other output') }
        @{ Name = 'changing announced totals'; Exit = 1; Match = 'announced totals changed'; Lines = @('1/3 x...OK', '2/2 y...OK', 'All 2 tests passed.') }
        @{ Name = 'duplicate test index'; Exit = 1; Match = 'not sequential'; Lines = @('1/2 x...OK', '1/2 y...OK', 'All 2 tests passed.') }
        @{ Name = 'missing test result before header'; Exit = 1; Match = 'no result before'; Lines = @('1/2 x...some log', '2/2 y...OK', 'All 2 tests passed.') }
        @{ Name = 'missing result before summary'; Exit = 1; Match = 'no result before'; Lines = @('1/1 x...some log', 'All 1 tests passed.', 'OK') }
        @{ Name = 'test after summary'; Exit = 1; Match = 'follows the closing'; Lines = @('1/2 x...OK', 'All 2 tests passed.', '2/2 y...OK') }
        @{ Name = 'duplicate summary'; Exit = 1; Match = 'more than one closing'; Lines = @('1/1 x...OK', 'All 1 tests passed.', 'All 1 tests passed.') }
        @{ Name = 'failed test disguised by summary'; Exit = 1; Match = 'Parsed 0 Passed|Parsed 1 Failed'; Lines = @('1/1 x...FAIL (TestUnexpectedResult)', 'All 1 tests passed.') }
        @{ Name = 'complete failed run in report mode'; Exit = 1; Match = 'contains failed tests'; Report = $true; Lines = @('1/1 x...FAIL (TestUnexpectedResult)', '0 passed; 0 skipped; 1 failed.') }
        @{ Name = 'result without pending test'; Exit = 1; Match = 'result without a pending'; Lines = @('1/1 x...OK', 'SKIP', 'All 1 tests passed.') }
        @{ Name = 'malformed extra header'; Exit = 1; Match = 'Malformed per-test header'; Lines = @('1/1 x...OK', '2/1 missing result marker', 'All 1 tests passed.') }
    )
    foreach ($case in $skipCases) {
        $runner = if ($case.Runner) { $case.Runner } else { 'r' }
        $result = Invoke-SkipFixture ($case.Name -replace '\W', '-') $case.Lines -Runner $runner -Report:([bool]$case.Report)
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
Write-Host "Hidden harness and skip budget contracts: $($hiddenContracts.Count) static checks, $script:mutationControls mutation controls, $($skipCases.Count + 1) skip budget fixtures"
