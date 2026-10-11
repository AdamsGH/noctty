param(
    [Parameter(Mandatory)] [string] $Tree,
    [Parameter(Mandatory)] [string] $Prefix,
    [Parameter(Mandatory)] [string] $Log
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $Tree 'build.zig'))) { throw 'Tree has no build.zig' }
$cmd = 'scripts\dev-windows.cmd zig build -Demit-exe=true -Doptimize=ReleaseFast --prefix "' + $Prefix + '" > "' + $Log + '" 2>&1'
$p = Start-Process -FilePath cmd.exe -ArgumentList @('/c', $cmd) -WorkingDirectory $Tree -WindowStyle Hidden -PassThru
try { $p.PriorityClass = 'BelowNormal' } catch { }
$p.WaitForExit()
"exit=$($p.ExitCode)" | Add-Content -LiteralPath $Log
exit $p.ExitCode
