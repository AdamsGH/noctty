#requires -Version 7.0
# MEASUREMENT ONLY (LAT-02): #310's acceptance case (50 MB `type`, jump resize
# 1.5 s in, WM_NULL probes every 7 ms), interleaved across builds. Adapted
# from LAT-01's flood-matrix.ps1 (paths only).
param([string]$Name = 'flood', [string]$Builds = 'mbase,mfix', [int]$Reps = 3)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-lat02'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
$list = $Builds.Split(',')
for ($rep = 1; $rep -le $Reps; $rep++) {
    $order = [string[]]$list.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
    foreach ($b in $order) {
        $run = Join-Path $out "$b-r$rep"
        & pwsh -NoProfile -File (Join-Path $scratch 'flood-probe.ps1') -Bin (Join-Path $root "wt-lat02-$b\zig-out\bin") -Run $run -Echo (Join-Path $scratch 'lat-echo.exe') | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run"; continue }
        & python -I (Join-Path $scratch 'flood_summary.py') $run | Write-Host
    }
}
Write-Host "flood done: $out"
