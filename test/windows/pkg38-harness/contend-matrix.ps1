#requires -Version 7.0
# MEASUREMENT ONLY (PKG-38): contend-probe.ps1 across builds x cases,
# interleaved, build order alternating per rep. A case is
# <style>-<focus>[-saver], for example colour-focused or plain-unfocused-saver.
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $Builds = 'mbase',
    [string] $Cases = 'colour-focused',
    [int] $Reps = 2,
    [int] $VsyncHz = 0
)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-pkg37'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
$list = $Builds.Split(','); $caseList = $Cases.Split(',')
for ($rep = 1; $rep -le $Reps; $rep++) {
    foreach ($case in $caseList) {
        $parts = $case.Split('-')
        # <style>-<focus>-<writer>[-saver]; writer is type (cmd type) or fast (fastcat.exe).
        $extra = @(); if ($parts.Count -gt 3 -and $parts[3] -eq 'saver') { $extra = @('-Extra', '--power-saver-rendering=on') }
        $echo = if ($parts[2] -eq 'fast') { 'fastcat.exe' } else { 'lat-echo.exe' }
        $order = [string[]]$list.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
        foreach ($b in $order) {
            $run = Join-Path $out "$b-$case-v$VsyncHz-r$rep"
            & pwsh -NoProfile -File (Join-Path $scratch 'contend-probe.ps1') -Bin (Join-Path $root "wt-pkg37-$b\zig-out\bin") -Run $run -Echo (Join-Path $scratch $echo) -Style $parts[0] -Focus $parts[1] -Writer $parts[2] -VsyncHz $VsyncHz -DriverTimeoutSeconds 120 @extra | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run"; continue }
            & python -I (Join-Path $scratch 'lock_analyze.py') $run | Write-Host
        }
    }
}
Write-Host "contend done: $out"
