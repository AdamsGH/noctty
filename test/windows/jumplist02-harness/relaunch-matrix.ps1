#requires -Version 7.0
# MEASUREMENT ONLY (PKG-73b): per build, a fresh portable copy launched
# -Launches times from the same path (launch 1 cold, later ones reuse the
# exe path and AppData). Builds alternate order per rep.
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $Builds = 'mbase',
    [string] $Case = 'colour-focused-type',
    [int] $Reps = 2,
    [int] $Launches = 3,
    [string[]] $Env = @()
)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\amant\.t3\worktrees\winghostty'
$scratch = Join-Path $root '_scratch-pkg37'
$out = Join-Path $scratch "runs\$Name"
[void](New-Item -ItemType Directory -Force -Path $out)
$list = $Builds.Split(','); $parts = $Case.Split('-')
$echo = if ($parts[2] -eq 'fast') { 'fastcat.exe' } elseif ($parts[2] -eq 'cd') { 'cdflood.exe' } else { 'lat-echo.exe' }
$writer = if ($parts[2] -eq 'cd') { 'fast' } else { $parts[2] }
for ($rep = 1; $rep -le $Reps; $rep++) {
    $order = [string[]]$list.Clone(); if ($rep % 2 -eq 0) { [array]::Reverse($order) }
    foreach ($b in $order) {
        $run = Join-Path $out "$b-$Case-r$rep"
        for ($l = 1; $l -le $Launches; $l++) {
            $relaunch = @(); if ($l -gt 1) { $relaunch = @('-Relaunch') }
            $envArg = @(); if ($Env.Count -gt 0) { $envArg = @('-Env', ($Env -join ',')) }
            & pwsh -NoProfile -File (Join-Path $scratch 'relaunch-probe.ps1') -Bin (Join-Path $root "wt-pkg37-$b\zig-out\bin") -Run $run -Echo (Join-Path $scratch $echo) -Style $parts[0] -Focus $parts[1] -Writer $writer -DriverTimeoutSeconds 120 @relaunch @envArg | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Host "FAILED $run launch $l"; break }
            $line = & python -I (Join-Path $scratch 'stall_analyze.py') $run | Select-Object -Last 1
            Write-Host "launch$l $line"
        }
    }
}
Write-Host "relaunch done: $out"
