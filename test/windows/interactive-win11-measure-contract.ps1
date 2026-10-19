# No Zig build, executable launch, git commit, GUI, or user-profile access.
# The synthetic archive and non-PE executable exercise provenance checks only.
param([string] $LibraryPath = (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-measure-lib.ps1'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $LibraryPath
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Exercise the real binary-safe git boundary before replacing it for fixtures.
$libraryRepo = Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($LibraryPath)))
$liveHead = Get-InteractiveWin11MeasureHead $libraryRepo
$liveOriginal = Invoke-InteractiveWin11MeasureGit $libraryRepo @('show', "${liveHead}:src/apprt/win32_aumid.zig")
[void] (Get-InteractiveWin11MeasurePatchedBytes $liveOriginal)
$liveNotifier = Invoke-InteractiveWin11MeasureGit $libraryRepo @('show', "${liveHead}:src/apprt/win32.zig")
Assert-InteractiveWin11MeasureProductNotifierSource $liveNotifier
$liveTransport = [Text.Encoding]::UTF8.GetString((Invoke-InteractiveWin11MeasureGit $libraryRepo @('show', "${liveHead}:src/apprt/win32_toast_winrt.zig")))
foreach ($anchor in @('fns.create_string(aumid.ptr, aumid_len, &aumid_hs)', 'factory.vtbl.CreateToastNotifierWithId(factory.asRaw(), aumid_hs.?, &notifier_raw)')) {
    if (-not $liveTransport.Contains($anchor)) { throw 'Explicit product notifier argument flow changed; reassess command-finish coverage.' }
}

$fixtureRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ('.sandbox\interactive-measure-contract\' + [guid]::NewGuid().ToString('N'))
$script:measureContractHead = '1234567890123456789012345678901234567890'
$layout = Get-InteractiveWin11MeasureLayout $fixtureRoot -Head $script:measureContractHead
[void] [IO.Directory]::CreateDirectory($layout.Root)
[void] [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'src\apprt'))
$script:measureContractDirty = $false
$script:measureContractOriginal = [Text.Encoding]::UTF8.GetBytes(@'
const std = @import("std");
const aumid_wide = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");
pub const aumid_utf8 = "io.github.amanthanvi.noctty";
pub fn registerAumidDisplayName(alloc: std.mem.Allocator, portable: bool) void {
    _ = alloc;
    _ = portable;
}
'@.Replace("`r`n", "`n"))
$originalPath = Join-Path $fixtureRoot 'src\apprt\win32_aumid.zig'
[IO.File]::WriteAllBytes($originalPath, $script:measureContractOriginal)
$script:measureContractNotifier = [Text.Encoding]::UTF8.GetBytes('const aumid_utf16 = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");' + "`n" + 'win32_toast_winrt.WinrtToast.init(core_app.alloc, aumid_utf16)' + "`n")
$originalNotifierPath = Join-Path $fixtureRoot 'src\apprt\win32.zig'
[IO.File]::WriteAllBytes($originalNotifierPath, $script:measureContractNotifier)
$archiveStream = New-Object IO.MemoryStream
$zip = New-Object IO.Compression.ZipArchive($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $true)
foreach ($name in @('src/apprt/win32_aumid.zig', 'src/apprt/win32.zig', 'build.zig')) {
    $entry = $zip.CreateEntry($name)
    $entryStream = $entry.Open()
    try {
        $content = switch ($name) {
            'build.zig' { [Text.Encoding]::UTF8.GetBytes('// synthetic build input') }
            'src/apprt/win32.zig' { $script:measureContractNotifier }
            default { $script:measureContractOriginal }
        }
        $entryStream.Write($content, 0, $content.Length)
    }
    finally { $entryStream.Dispose() }
}
$zip.Dispose()
$script:measureContractArchive = $archiveStream.ToArray()
$archiveStream.Dispose()
[IO.File]::WriteAllBytes($layout.Archive, $script:measureContractArchive)
[IO.Compression.ZipFile]::ExtractToDirectory($layout.Archive, $layout.Source)
$patched = Get-InteractiveWin11MeasurePatchedBytes $script:measureContractOriginal
$patchedText = [Text.Encoding]::UTF8.GetString($patched)
if ([regex]::Matches($patchedText, 'io\.github\.amanthanvi\.noctty\.measure').Count -ne 2 -or
    -not $patchedText.Contains("void {`n    if (true) return; // MEASUREMENT ONLY`n")) {
    throw 'The explicit measurement patch is incomplete.'
}
$measuredSourcePath = Join-Path $layout.Source 'src\apprt\win32_aumid.zig'
[IO.File]::WriteAllBytes($measuredSourcePath, $patched)
$measuredNotifierPath = Join-Path $layout.Source 'src\apprt\win32.zig'
Assert-InteractiveWin11MeasureProductNotifierSource $script:measureContractNotifier
$sourceReceipt = [ordered]@{
    Schema = 2; Head = $script:measureContractHead; Patch = 'aumid-isolate-product-toast-v2'
    NotifierAumid = 'io.github.amanthanvi.noctty'
    ArchiveSHA256 = Get-InteractiveWin11MeasureHash $script:measureContractArchive
    OriginalAumidSHA256 = Get-InteractiveWin11MeasureHash $script:measureContractOriginal
    PatchedAumidSHA256 = Get-InteractiveWin11MeasureHash $patched
    OriginalNotifierSHA256 = Get-InteractiveWin11MeasureHash $script:measureContractNotifier
    MeasuredNotifierSHA256 = Get-InteractiveWin11MeasureHash $script:measureContractNotifier
}
[IO.File]::WriteAllText($layout.SourceReceipt, ($sourceReceipt | ConvertTo-Json))
[void] [IO.Directory]::CreateDirectory((Split-Path -Parent $layout.Exe))
[IO.File]::WriteAllText($layout.Exe, 'synthetic non-PE executable receipt fixture')
[IO.File]::WriteAllText($layout.Cli, 'synthetic non-PE console shim fixture')
$buildReceipt = [ordered]@{
    Schema = 2; State = 'complete'; Head = $script:measureContractHead; RepoRoot = $layout.Repo
    Patch = $sourceReceipt.Patch; Aumid = 'io.github.amanthanvi.noctty.measure'
    NotifierAumid = $sourceReceipt.NotifierAumid
    ArchiveSHA256 = $sourceReceipt.ArchiveSHA256
    OriginalAumidSHA256 = $sourceReceipt.OriginalAumidSHA256
    PatchedAumidSHA256 = $sourceReceipt.PatchedAumidSHA256
    OriginalNotifierSHA256 = $sourceReceipt.OriginalNotifierSHA256
    MeasuredNotifierSHA256 = $sourceReceipt.MeasuredNotifierSHA256
    SourceReceiptSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.SourceReceipt))
    Optimize = 'Debug'; ExePath = $layout.Exe
    ExeSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.Exe))
    CliPath = $layout.Cli
    CliSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.Cli))
}
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))

# Replace only the git boundary. No compiler/build function is called.
function Invoke-InteractiveWin11MeasureGit {
    param([string] $RepoRoot, [string[]] $Arguments)
    switch ($Arguments[0]) {
        'rev-parse' { return ,[Text.Encoding]::UTF8.GetBytes($script:measureContractHead) }
        'status' {
            if ($script:measureContractDirty) { return ,[Text.Encoding]::UTF8.GetBytes(' M build.zig') }
            return ,[byte[]]@()
        }
        'show' {
            if ($Arguments[1].EndsWith(':src/apprt/win32.zig')) { return ,$script:measureContractNotifier }
            return ,$script:measureContractOriginal
        }
        'archive' { return ,$script:measureContractArchive }
        default { throw 'Unexpected fixture git operation.' }
    }
}

$script:measureContractChecks = 0
function Assert-MeasureContractRejected {
    param([string] $Name, [scriptblock] $Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw "Receipt contract accepted $Name." }
    $script:measureContractChecks++
}
function Assert-MeasureFixture {
    Assert-InteractiveWin11MeasureBuild -RepoRoot $fixtureRoot -ExePath $layout.Exe
}

Assert-MeasureFixture
$script:measureContractChecks++
$nextGeneration = Get-InteractiveWin11MeasureLayout $fixtureRoot -Head 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
if ($nextGeneration.Root -eq $layout.Root -or -not [IO.File]::Exists($layout.Receipt)) { throw 'HEAD generations must preserve existing evidence.' }
$script:measureContractChecks++
Assert-MeasureContractRejected 'foreign executable' { Assert-InteractiveWin11MeasureBuild $fixtureRoot (Join-Path $fixtureRoot 'noctty.exe') }
$exeBytes = [IO.File]::ReadAllBytes($layout.Exe)
[IO.File]::AppendAllText($layout.Exe, 'tampered')
Assert-MeasureContractRejected 'changed executable' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($layout.Exe, $exeBytes)
$cliBytes = [IO.File]::ReadAllBytes($layout.Cli)
[IO.File]::AppendAllText($layout.Cli, 'tampered')
Assert-MeasureContractRejected 'changed sibling console shim' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($layout.Cli, $cliBytes)
$buildReceipt.SourceReceiptSHA256 = '0000000000000000000000000000000000000000000000000000000000000000'
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))
Assert-MeasureContractRejected 'unbound source receipt' { Assert-MeasureFixture }
$buildReceipt.SourceReceiptSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.SourceReceipt))
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))
[IO.File]::WriteAllBytes($measuredSourcePath, $script:measureContractOriginal)
Assert-MeasureContractRejected 'missing measurement patch' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($measuredSourcePath, $patched)
$withoutReturn = [Text.Encoding]::UTF8.GetBytes($patchedText.Replace("    if (true) return; // MEASUREMENT ONLY`n", ''))
[IO.File]::WriteAllBytes($measuredSourcePath, $withoutReturn)
Assert-MeasureContractRejected 'measurement constants without registration suppression' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($measuredSourcePath, $patched)
[IO.File]::WriteAllBytes($measuredNotifierPath, [Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($script:measureContractNotifier)).Replace('io.github.amanthanvi.noctty', 'io.github.amanthanvi.noctty.measure')))
Assert-MeasureContractRejected 'measurement notifier replacing the product notifier' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($measuredNotifierPath, $script:measureContractNotifier)
$buildReceipt.MeasuredNotifierSHA256 = '0000000000000000000000000000000000000000000000000000000000000000'
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))
Assert-MeasureContractRejected 'wrong notifier hash in receipt' { Assert-MeasureFixture }
$buildReceipt.MeasuredNotifierSHA256 = $sourceReceipt.MeasuredNotifierSHA256
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))
$buildInput = Join-Path $layout.Source 'build.zig'
$buildInputBytes = [IO.File]::ReadAllBytes($buildInput)
[IO.File]::AppendAllText($buildInput, 'tampered')
Assert-MeasureContractRejected 'changed other source' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($buildInput, $buildInputBytes)
$unexpected = Join-Path $layout.Source 'injected.zig'
[IO.File]::WriteAllText($unexpected, '// unexpected source')
Assert-MeasureContractRejected 'added source file' { Assert-MeasureFixture }
[IO.File]::Delete($unexpected)
[IO.File]::AppendAllText($originalPath, 'tampered')
Assert-MeasureContractRejected 'changed original AUMID bytes' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($originalPath, $script:measureContractOriginal)
$script:measureContractDirty = $true
Assert-MeasureContractRejected 'dirty tracked checkout' { Assert-MeasureFixture }
$script:measureContractDirty = $false
$savedHead = $script:measureContractHead
$script:measureContractHead = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
Assert-MeasureContractRejected 'stale HEAD' { Assert-MeasureFixture }
$script:measureContractHead = $savedHead
$sourceReceipt.Head = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
[IO.File]::WriteAllText($layout.SourceReceipt, ($sourceReceipt | ConvertTo-Json))
Assert-MeasureContractRejected 'stale source receipt' { Assert-MeasureFixture }
$sourceReceipt.Head = $savedHead
[IO.File]::WriteAllText($layout.SourceReceipt, ($sourceReceipt | ConvertTo-Json))
[IO.File]::AppendAllText($layout.Archive, 'tampered')
Assert-MeasureContractRejected 'changed archive' { Assert-MeasureFixture }
[IO.File]::WriteAllBytes($layout.Archive, $script:measureContractArchive)
$buildReceipt.State = 'building'
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))
Assert-MeasureContractRejected 'incomplete build' { Assert-MeasureFixture }
$buildReceipt.State = 'complete'
$buildReceipt.Aumid = 'io.github.amanthanvi.noctty'
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))
Assert-MeasureContractRejected 'product identity receipt' { Assert-MeasureFixture }
$buildReceipt.Aumid = 'io.github.amanthanvi.noctty.measure'
[IO.File]::WriteAllText($layout.Receipt, ($buildReceipt | ConvertTo-Json))
$heldLock = [IO.File]::Open((Join-Path $layout.Root 'build.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Assert-MeasureContractRejected 'in-progress build lock' { Assert-MeasureFixture } }
finally { $heldLock.Dispose() }
Assert-MeasureFixture
$script:measureContractChecks++
Write-Output "PASS: $script:measureContractChecks measurement provenance checks (synthetic fixtures; no build or runtime)."
