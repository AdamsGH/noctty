#requires -Version 7.0
# MEASUREMENT ONLY (PKG-37): anim.exe (60 fps synchronized-output TUI) or
# held.exe (synchronized output held across writes) across builds,
# interleaved, through LAT-02's anim-probe.ps1. -Extra passes noctty flags
# (for example --power-saver-rendering=on).
param(
    [string]$Name = 'probe', [string]$Builds = 'mbase,mfix', [int]$Reps = 2,
    [ValidateSet('anim','held')] [string]$Tool = 'anim',
    [int]$Arg1 = 60, [int]$Arg2 = 10, [int]$VsyncHz = 0, [string]$Extra = '', [int]$InvalidateMs = 0
)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-pkg37'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
$list = $Builds.Split(',')
# anim-probe hands the tool (Arg1, Arg2) and waits 1.5 s + Arg2 s + 1 s:
# anim.exe reads (fps, seconds), held.exe (hold_ms, cycles), each cycle
# taking hold_ms + 100 ms, so hold_ms must stay below 900.
$count = $Arg2
$analyzer = if ($Tool -eq 'held') { 'held_analyze.py' } else { 'anim_analyze.py' }
for ($rep = 1; $rep -le $Reps; $rep++) {
    $order = [string[]]$list.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
    foreach ($b in $order) {
        $run = Join-Path $out "$b-$Tool-v$VsyncHz-r$rep"
        $extraArgs = @(); if ($Extra) { $extraArgs = @('-Extra', $Extra) }
        & pwsh -NoProfile -File (Join-Path $scratch 'anim-probe.ps1') -Bin (Join-Path $root "wt-pkg37-$b\zig-out\bin") -Run $run -Echo (Join-Path $scratch "$Tool.exe") -DelayMs $Arg1 -Count $count -VsyncHz $VsyncHz -DriverTimeoutSeconds 120 -InvalidateMs $InvalidateMs @extraArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run"; continue }
        & python -I (Join-Path $scratch $analyzer) $run | Write-Host
    }
}
Write-Host "$Tool done: $out"
