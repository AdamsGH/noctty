#requires -Version 7.0
# MEASUREMENT ONLY (LAT-01): #310's acceptance case (50 MB `type`, jump resize,
# WM_NULL probes every 7 ms), interleaved across builds.
param([string]$Name = 'flood', [string]$Builds = 'mmain,mfix', [int]$Reps = 3)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-lat01'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
$list = $Builds.Split(',')
for ($rep = 1; $rep -le $Reps; $rep++) {
    $order = [string[]]$list.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
    foreach ($b in $order) {
        $run = Join-Path $out "$b-r$rep"
        & pwsh -NoProfile -File (Join-Path $scratch 'flood-probe.ps1') -Bin (Join-Path $root "wt-lat01-$b\zig-out\bin") -Run $run | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run"; continue }
        $p = Get-Content -LiteralPath (Join-Path $run 'probes.txt') | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) } | Sort-Object
        $n = $p.Count
        Write-Host ("{0,-10} n={1} p50={2:F1} p99={3:F1} max={4:F1} over100ms={5}" -f "$b-r$rep", $n, $p[[int]($n/2)], $p[[int]([Math]::Min($n-1, [Math]::Round(0.99*($n-1))))], $p[$n-1], @($p | Where-Object { $_ -gt 100 }).Count)
    }
}
