#requires -Version 7.0
# MEASUREMENT ONLY (LAT-01): run lat-driver.ps1 over builds x scenarios, interleaved.
param(
    [Parameter(Mandatory)] [string] $Name,
    [string[]] $Builds = @('m131','m310','mmain'),
    [string[]] $Scenarios = @('d0-vt-steady','d30-vt-steady','d0-vt-burst','d30-vt-burst'),
    [int] $Reps = 2,
    [int] $Count = 240,
    [string] $Monitor = 'primary',
    [string] $ConPty = 'bundled',
    [string] $Suffix = 'bin',
    [int] $VsyncHz = 0
)
$ErrorActionPreference = 'Stop'
# pwsh -File hands an array parameter one comma-joined string.
$Builds = @($Builds | ForEach-Object { $_.Split(',') }); $Scenarios = @($Scenarios | ForEach-Object { $_.Split(',') })
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-lat01'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
$results = @()
for ($rep = 1; $rep -le $Reps; $rep++) {
    foreach ($sc in $Scenarios) {
        $parts = $sc.Split('-')
        $delay = [int]$parts[0].Substring(1); $mode = $parts[1]; $pattern = $parts[2]; $style = if ($parts.Count -gt 3) { $parts[3] } else { 'plain' }
        $order = [string[]]$Builds.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
        foreach ($b in $order) {
            $bin = Join-Path $root "wt-lat01-$b\zig-out\$Suffix"
            $run = Join-Path $out "$b-$sc-$Monitor-$ConPty-v$VsyncHz-r$rep"
            $seed = $rep * 100 + [Array]::IndexOf($Scenarios, $sc)
            & pwsh -NoProfile -File (Join-Path $scratch 'lat-driver2.ps1') -Bin $bin -Run $run -DelayMs $delay -Mode $mode -Pattern $pattern -Count $Count -Seed $seed -Monitor $Monitor -ConPty $ConPty -Style $style -VsyncHz $VsyncHz | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run"; continue }
            & python -I (Join-Path $scratch 'analyze.py') $run --json (Join-Path $run 'summary.json') | Select-Object -First 1 | Write-Host
        }
    }
}
Write-Host "matrix done: $out"
