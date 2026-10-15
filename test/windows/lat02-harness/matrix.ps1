#requires -Version 7.0
# MEASUREMENT ONLY (LAT-02): run lat-driver2.ps1 over builds x scenarios,
# interleaved, alternating build order per rep. Adapted from LAT-01's
# matrix2.ps1 (paths only).
param(
    [Parameter(Mandatory)] [string] $Name,
    [string[]] $Builds = @('mbase','mfix'),
    [string[]] $Scenarios = @('d0-ssh-steady'),
    [int] $Reps = 2,
    [int] $Count = 240,
    [string] $Monitor = 'primary',
    [string] $ConPty = 'bundled',
    [int] $VsyncHz = 0,
    [string] $DriverScript = 'lat-driver2.ps1',
    [string] $Extra = ''
)
$ErrorActionPreference = 'Stop'
# pwsh -File hands an array parameter one comma-joined string.
$Builds = @($Builds | ForEach-Object { $_.Split(',') }); $Scenarios = @($Scenarios | ForEach-Object { $_.Split(',') })
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-lat02'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
for ($rep = 1; $rep -le $Reps; $rep++) {
    foreach ($sc in $Scenarios) {
        $parts = $sc.Split('-')
        $delay = [int]$parts[0].Substring(1); $mode = $parts[1]; $pattern = $parts[2]; $style = if ($parts.Count -gt 3) { $parts[3] } else { 'plain' }
        $order = [string[]]$Builds.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
        foreach ($b in $order) {
            $bin = Join-Path $root "wt-lat02-$b\zig-out\bin"
            $run = Join-Path $out "$b-$sc-$Monitor-$ConPty-v$VsyncHz-r$rep"
            $seed = $rep * 100 + [Array]::IndexOf($Scenarios, $sc)
            & pwsh -NoProfile -File (Join-Path $scratch $DriverScript) -Bin $bin -Run $run -Echo (Join-Path $scratch 'lat-echo.exe') -DelayMs $delay -Mode $mode -Pattern $pattern -Count $Count -Seed $seed -Monitor $Monitor -ConPty $ConPty -Style $style -VsyncHz $VsyncHz @(if ($Extra) { @('-Extra', $Extra) }) | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run"; continue }
            & python -I (Join-Path $scratch 'analyze.py') $run --json (Join-Path $run 'summary.json') | Select-Object -First 1 | Write-Host
        }
    }
}
Write-Host "matrix done: $out"
