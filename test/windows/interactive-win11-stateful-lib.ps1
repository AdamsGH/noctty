. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\interactive-win11-window-lib.ps1')

# Settling delay after promoting a stateful host window.
$script:STATEFUL_HOST_SETTLE_MS = 200

if (-not ('System.Drawing.Bitmap' -as [type])) {
    Add-Type -AssemblyName System.Drawing
}

function Send-StatefulMessage(
    [IntPtr] $Hwnd,
    [uint32] $Message,
    [UIntPtr] $WParam,
    [IntPtr] $LParam,
    [DateTime] $Deadline,
    [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
    [string] $Description
) {
    return Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message $Message -WParam $WParam -LParam $LParam -Deadline $Deadline -Process $Process -Description $Description
}

function Get-StatefulClassName([IntPtr] $Hwnd) {
    $value = [Text.StringBuilder]::new(128)
    [void][InteractiveWin11WindowNative]::GetClassNameW($Hwnd, $value, $value.Capacity)
    return $value.ToString()
}

function Find-StatefulHost([int] $ProcessId) {
    $script:StatefulPid = [uint32]$ProcessId
    $script:StatefulHost = [IntPtr]::Zero
    $callback = [InteractiveWin11WindowNative+EnumWindowsProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        $windowProcessId = [uint32]0
        [void][InteractiveWin11MessageNativeV2]::GetWindowThreadProcessId($hwnd, [ref]$windowProcessId)
        if ($windowProcessId -eq $script:StatefulPid -and (Get-StatefulClassName $hwnd) -eq 'noctty.win32.host') {
            $script:StatefulHost = $hwnd
            return $false
        }
        return $true
    }
    [void][InteractiveWin11WindowNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:StatefulHost
}

function Get-StatefulChildren([IntPtr] $Parent) {
    $script:StatefulChildren = [Collections.Generic.List[object]]::new()
    $callback = [InteractiveWin11WindowNative+EnumWindowsProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        if ([InteractiveWin11WindowNative]::IsWindowVisible($hwnd)) {
            $script:StatefulChildren.Add([pscustomobject]@{
                Hwnd = $hwnd
                Id = [InteractiveWin11WindowNative]::GetDlgCtrlID($hwnd)
                Class = Get-StatefulClassName $hwnd
            })
        }
        return $true
    }
    [void][InteractiveWin11WindowNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return @($script:StatefulChildren)
}

function Get-StatefulTabCount([IntPtr] $HostHwnd) {
    return @(Get-StatefulChildren $HostHwnd | Where-Object { $_.Id -ge 1000 -and $_.Id -lt 1900 }).Count
}

function Get-StatefulSurface([IntPtr] $HostHwnd) {
    return Get-StatefulChildren $HostHwnd | Where-Object Class -eq 'noctty.win32' | Select-Object -First 1
}

function Get-StatefulWindowRect([IntPtr] $Hwnd) {
    $rect = [InteractiveWin11WindowNative+RECT]::new()
    if (-not [InteractiveWin11WindowNative]::GetWindowRect($Hwnd, [ref]$rect)) { return $null }
    return $rect
}

function Set-StatefulEditText([IntPtr] $HostHwnd, [IntPtr] $Hwnd, [string] $Text, [DateTime] $Deadline, [Parameter(Mandatory)] [System.Diagnostics.Process] $Process) {
    $textPointer = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($Text)
    try {
        $result = Send-StatefulMessage $Hwnd 0x000C ([UIntPtr]::Zero) $textPointer $Deadline $Process 'WM_SETTEXT'
        if ($result -eq [UIntPtr]::Zero) { throw "WM_SETTEXT failed for hwnd=$Hwnd" }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($textPointer)
    }
    $enChange = 0x0300
    $controlId = [InteractiveWin11WindowNative]::GetDlgCtrlID($Hwnd)
    $command = [uint64]([uint32]$controlId -bor ([uint32]$enChange -shl 16))
    [void](Send-StatefulMessage $HostHwnd 0x0111 ([UIntPtr]$command) $Hwnd $Deadline $Process "WM_COMMAND EN_CHANGE id=$controlId")
}

function Show-StatefulHost([IntPtr] $HostHwnd) {
    [void][InteractiveWin11WindowNative]::ShowWindow($HostHwnd, 9)
    [void][InteractiveWin11WindowNative]::SetWindowPos($HostHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0043)
    [void][InteractiveWin11WindowNative]::SetForegroundWindow($HostHwnd)
    Start-Sleep -Milliseconds $script:STATEFUL_HOST_SETTLE_MS
}

function Get-StatefulPixelSamplePoints([InteractiveWin11WindowNative+RECT] $Rect) {
    $width = $Rect.Right - $Rect.Left
    $height = $Rect.Bottom - $Rect.Top
    foreach ($column in 1..4) {
        foreach ($row in 1..4) {
            [Drawing.Point]::new($Rect.Left + [int](($width * $column) / 5), $Rect.Top + [int](($height * $row) / 5))
        }
    }
}

function Get-StatefulPixel([IntPtr] $Hwnd) {
    # Names the window a screen-pixel wait reads, so Wait-InteractiveWin11Until
    # can record what was on screen there if the wait times out.
    $script:InteractiveWin11PixelWindow = $Hwnd
    $rect = [InteractiveWin11WindowNative+RECT]::new()
    if (-not [InteractiveWin11WindowNative]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw "GetWindowRect failed for hwnd=$Hwnd"
    }
    $bitmap = [Drawing.Bitmap]::new(1, 1)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $counts = @{}
        $bestColor = 0
        $bestCount = 0
        foreach ($point in Get-StatefulPixelSamplePoints $rect) {
            $graphics.CopyFromScreen($point.X, $point.Y, 0, 0, [Drawing.Size]::new(1, 1))
            $color = $bitmap.GetPixel(0, 0).ToArgb()
            $count = 1 + [int]($counts[$color])
            $counts[$color] = $count
            if ($count -gt $bestCount) { $bestColor = $color; $bestCount = $count }
        }
        return $bestColor
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if (-not ('StatefulPixelDiagnosticNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class StatefulPixelDiagnosticNative {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out uint value, int size);
    // DWMWA_CLOAKED: 0 when shown; -1 when DWM could not say.
    public static long Cloaked(IntPtr hwnd) {
        uint value;
        return DwmGetWindowAttribute(hwnd, 14, out value, 4) == 0 ? (long)value : -1L;
    }
    public static long InputAgeMilliseconds() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) return -1;
        return unchecked((uint)Environment.TickCount - info.dwTime);
    }
}
'@
}

# Pixel diagnostics go to the harness's logs, which the interactive job uploads.
$script:StatefulDiagnosticDirectory = $null

function Get-StatefulWindowFacts([IntPtr] $Hwnd) {
    # Handle, class and process only: never a window title or its contents.
    if ($Hwnd -eq [IntPtr]::Zero) { return $null }
    $processId = [uint32]0
    [void][InteractiveWin11WindowNative]::GetWindowThreadProcessId($Hwnd, [ref]$processId)
    $processName = $null
    try { $processName = (Get-Process -Id $processId -ErrorAction Stop).ProcessName } catch { $processName = $null }
    return [pscustomobject][ordered]@{
        Handle = '0x{0:X}' -f $Hwnd.ToInt64()
        Class = Get-StatefulClassName $Hwnd
        ProcessId = $processId
        ProcessName = $processName
    }
}

# Records what was on screen where a screen-pixel assertion looked: the window
# under each sample point, the foreground window, whether noctty's window was
# hung, cloaked or minimized, which other processes' windows lay above it, and
# a screenshot of the sampled rect. The screenshot is withheld when another
# process's window overlaps the rect, so the artifacts never carry another
# application's screen content; the metadata still names that window.
function Save-StatefulPixelDiagnostic([IntPtr] $Hwnd, [string] $Description, [string] $Directory = $script:StatefulDiagnosticDirectory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = [IO.Path]::GetTempPath() }
    [void][IO.Directory]::CreateDirectory($Directory)
    $slug = ($Description.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).TrimEnd('-') }
    $base = Join-Path $Directory ('pixel-diagnostic-{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'), $slug)
    $root = [StatefulPixelDiagnosticNative]::GetAncestor($Hwnd, 2)
    $rootFacts = Get-StatefulWindowFacts $root
    $rect = Get-StatefulWindowRect $Hwnd
    $samples = [Collections.Generic.List[object]]::new()
    $occluders = [Collections.Generic.List[object]]::new()
    if ($null -ne $rect) {
        $bitmap = [Drawing.Bitmap]::new(1, 1)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            foreach ($point in Get-StatefulPixelSamplePoints $rect) {
                $rgb = $null
                try {
                    $graphics.CopyFromScreen($point.X, $point.Y, 0, 0, [Drawing.Size]::new(1, 1))
                    $rgb = '{0:x6}' -f ($bitmap.GetPixel(0, 0).ToArgb() -band 0xFFFFFF)
                }
                catch { $rgb = "capture failed: $($_.Exception.Message)" }
                $nativePoint = [StatefulPixelDiagnosticNative+POINT]::new()
                $nativePoint.X = $point.X
                $nativePoint.Y = $point.Y
                $under = [StatefulPixelDiagnosticNative]::WindowFromPoint($nativePoint)
                $samples.Add([pscustomobject][ordered]@{
                    X = $point.X; Y = $point.Y; Rgb = $rgb
                    Window = Get-StatefulWindowFacts $under
                    Root = Get-StatefulWindowFacts ([StatefulPixelDiagnosticNative]::GetAncestor($under, 2))
                })
            }
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
        # GW_HWNDPREV walks up the z-order from noctty's top-level window. Only a
        # window DWM says is cloaked is left out; one it cannot answer for counts.
        $above = [StatefulPixelDiagnosticNative]::GetWindow($root, 3)
        for ($guard = 0; $above -ne [IntPtr]::Zero -and $guard -lt 4096; $guard++) {
            $aboveRect = Get-StatefulWindowRect $above
            if ([InteractiveWin11WindowNative]::IsWindowVisible($above) -and
                [StatefulPixelDiagnosticNative]::Cloaked($above) -le 0 -and $null -ne $aboveRect -and
                $aboveRect.Left -lt $rect.Right -and $aboveRect.Right -gt $rect.Left -and
                $aboveRect.Top -lt $rect.Bottom -and $aboveRect.Bottom -gt $rect.Top) {
                $facts = Get-StatefulWindowFacts $above
                if ($null -eq $rootFacts -or $facts.ProcessId -ne $rootFacts.ProcessId) { $occluders.Add($facts) }
            }
            $above = [StatefulPixelDiagnosticNative]::GetWindow($above, 3)
        }
    }
    $screenshot = $null
    $screenshotNote = $null
    if ($null -eq $rect) {
        $screenshotNote = 'not taken: the window rect could not be read'
    }
    elseif ($occluders.Count -ne 0) {
        $screenshotNote = "withheld: $($occluders.Count) window(s) of other processes overlap the sampled rect"
    }
    else {
        $width = [Math]::Max(1, $rect.Right - $rect.Left)
        $height = [Math]::Max(1, $rect.Bottom - $rect.Top)
        $capture = [Drawing.Bitmap]::new($width, $height)
        try {
            $captureGraphics = [Drawing.Graphics]::FromImage($capture)
            try {
                $captureGraphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $capture.Size)
                $screenshot = "$base.png"
                $capture.Save($screenshot, [Drawing.Imaging.ImageFormat]::Png)
            }
            catch { $screenshot = $null; $screenshotNote = "capture failed: $($_.Exception.Message)" }
            finally { $captureGraphics.Dispose() }
        }
        finally { $capture.Dispose() }
    }
    $foreground = Get-StatefulWindowFacts ([InteractiveWin11WindowNative]::GetForegroundWindow())
    $report = [ordered]@{
        Description = $Description
        TimeUtc = [DateTime]::UtcNow.ToString('o')
        Window = Get-StatefulWindowFacts $Hwnd
        Rect = if ($null -eq $rect) { $null } else { [ordered]@{ Left = $rect.Left; Top = $rect.Top; Right = $rect.Right; Bottom = $rect.Bottom } }
        Root = $rootFacts
        RootHung = [StatefulPixelDiagnosticNative]::IsHungAppWindow($root)
        RootCloaked = [StatefulPixelDiagnosticNative]::Cloaked($root)
        RootMinimized = [StatefulPixelDiagnosticNative]::IsIconic($root)
        RootVisible = [InteractiveWin11WindowNative]::IsWindowVisible($root)
        Foreground = $foreground
        InputAgeMilliseconds = [StatefulPixelDiagnosticNative]::InputAgeMilliseconds()
        Samples = @($samples)
        OtherProcessWindowsAbove = @($occluders)
        Screenshot = $screenshot
        ScreenshotNote = $screenshotNote
    }
    [IO.File]::WriteAllText("$base.json", ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $underCounts = @($samples | ForEach-Object {
            if ($null -eq $_.Root) { '<none>' } else { "$($_.Root.ProcessName)/$($_.Root.Class)" }
        } | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) x$($_.Count)" })
    $foregroundText = if ($null -eq $foreground) { '<none>' } else { "$($foreground.ProcessName)/$($foreground.Class)" }
    $screenshotText = if ($null -ne $screenshot) { $screenshot } else { $screenshotNote }
    return ("pixel diagnostic: foreground={0}; under the samples: {1}; hung={2}; cloaked={3}; other-process windows above={4}; screenshot={5}; report={6}.json" -f `
            $foregroundText, ($underCounts -join ', '), $report.RootHung, $report.RootCloaked, $occluders.Count, $screenshotText, $base)
}

function Start-StatefulApp($Layout, [string] $Exe, [string] $RepoRoot, [string] $Name, [string[]] $ExtraArguments = @(), [switch] $UseConfiguredCommand) {
    $stdout = Join-Path $Layout.Logs "$Name-stdout.log"
    $stderr = Join-Path $Layout.Logs "$Name-stderr.log"
    $script:StatefulDiagnosticDirectory = $Layout.Logs
    $arguments = @((Get-InteractiveWin11LaunchArguments -Layout $Layout -UseConfiguredCommand:$UseConfiguredCommand)) + @($ExtraArguments)
    $process = Start-Process -FilePath $Exe -ArgumentList $arguments `
        -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    return [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr }
}

function Wait-StatefulHost($Run, [DateTime] $Deadline) {
    $script:StatefulWaitProcess = $Run.Process
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'noctty host window' -Process $Run.Process -Condition {
        [IntPtr]::Zero -ne (Find-StatefulHost $script:StatefulWaitProcess.Id)
    }
    return Find-StatefulHost $Run.Process.Id
}

function Invoke-StatefulButton([IntPtr] $HostHwnd, [int] $ControlId, [DateTime] $Deadline, [Parameter(Mandatory)] [System.Diagnostics.Process] $Process) {
    $button = Get-StatefulChildren $HostHwnd | Where-Object Id -eq $ControlId | Select-Object -First 1
    if ($null -eq $button) { throw "No visible button with control ID $ControlId." }
    [void](Send-StatefulMessage $button.Hwnd 0x00F5 ([UIntPtr]::Zero) ([IntPtr]::Zero) $Deadline $Process "BM_CLICK id=$ControlId")
}

function Invoke-StatefulPostedCommand(
    [IntPtr] $Hwnd,
    [int] $Id,
    [DateTime] $Deadline,
    [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
) {
    Invoke-InteractiveWin11PostMessage `
        -Hwnd $Hwnd `
        -Message 0x0111 `
        -WParam ([UIntPtr]::new([uint64]$Id)) `
        -Deadline $Deadline `
        -Description "WM_COMMAND id=$Id" `
        -Process $Process
}

function Invoke-StatefulPaletteFirstRow([IntPtr] $HostHwnd, [DateTime] $Deadline, [Parameter(Mandatory)] [System.Diagnostics.Process] $Process) {
    $list = Get-StatefulChildren $HostHwnd | Where-Object Id -eq 2006 | Select-Object -First 1
    if ($null -eq $list) { throw 'No visible command-palette list.' }
    $coordinates = [IntPtr](4 -bor (4 -shl 16))
    [void](Send-StatefulMessage $list.Hwnd 0x0201 ([UIntPtr]::Zero) $coordinates $Deadline $Process 'WM_LBUTTONDOWN command-palette first row')
}

function Wait-StatefulSurface([IntPtr] $HostHwnd, $Run, [DateTime] $Deadline) {
    $script:StatefulSurfaceHost = $HostHwnd
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'terminal surface window' -Process $Run.Process -Condition {
        $surface = Get-StatefulSurface $script:StatefulSurfaceHost
        if ($null -eq $surface) { return $false }
        $rect = Get-StatefulWindowRect $surface.Hwnd
        return $null -ne $rect -and ($rect.Right - $rect.Left) -gt 100 -and ($rect.Bottom - $rect.Top) -gt 100
    }
    return Get-StatefulSurface $HostHwnd
}

function Close-StatefulHost([IntPtr] $HostHwnd, $Run, [DateTime] $Deadline) {
    $processHandle = $Run.Process.Handle
    $toleratedCloseError = [ref]0
    $closeSkipDetail = $null
    try {
        [void](Invoke-InteractiveWin11Message `
            -Hwnd $HostHwnd `
            -Message 0x0010 `
            -Deadline $Deadline `
            -Description 'WM_CLOSE to noctty' `
            -Flags $script:InteractiveWin11SmtoBlock `
            -ToleratedErrors @($script:InteractiveWin11ErrorInvalidWindowHandle) `
            -ObservedToleratedError $toleratedCloseError `
            -Process $Run.Process)
        if ($toleratedCloseError.Value -ne 0) {
            $closeSkipDetail = "WM_CLOSE was skipped after tolerated Win32 error $($toleratedCloseError.Value) for hwnd=$HostHwnd"
        }
    }
    catch {
        $sendError = $_
        $Run.Process.Refresh()
        if (-not $Run.Process.HasExited) {
            throw $sendError
        }
        Write-Warning "WM_CLOSE send raced noctty exit: $sendError"
    }
    try {
        Wait-InteractiveWin11Until -Deadline $Deadline -Description 'noctty graceful exit' -Condition { $Run.Process.Refresh(); $Run.Process.HasExited }
    }
    catch {
        if ($null -ne $closeSkipDetail) { throw "$($_.Exception.Message) ($closeSkipDetail)" }
        throw
    }
    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $Run.Process -ProcessHandle $processHandle
    if ($exitCode -ne 0) {
        $suffix = if ($null -ne $closeSkipDetail) { " ($closeSkipDetail)" } else { '' }
        throw "noctty exited with code $exitCode during graceful-close validation$suffix"
    }
}
