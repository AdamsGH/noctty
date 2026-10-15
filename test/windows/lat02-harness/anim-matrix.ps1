#requires -Version 7.0
# MEASUREMENT ONLY (LAT-02): animated TUI (anim.exe) across builds, interleaved.
param([string]$Name = 'anim', [string]$Builds = 'mbase,mfix,mdedup', [int]$Reps = 2, [int]$Fps = 60, [int]$Seconds = 10, [int]$VsyncHz = 0)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-lat02'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
$list = $Builds.Split(',')
for ($rep = 1; $rep -le $Reps; $rep++) {
    $order = [string[]]$list.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
    foreach ($b in $order) {
        $run = Join-Path $out "$b-f$Fps-v$VsyncHz-r$rep"
        & pwsh -NoProfile -File (Join-Path $scratch 'anim-probe.ps1') -Bin (Join-Path $root "wt-lat02-$b\zig-out\bin") -Run $run -Echo (Join-Path $scratch 'anim.exe') -DelayMs $Fps -Count $Seconds -VsyncHz $VsyncHz -DriverTimeoutSeconds 120 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run"; continue }
        & python -I (Join-Path $scratch 'anim_analyze.py') $run | Write-Host
    }
}
Write-Host "anim done: $out"
