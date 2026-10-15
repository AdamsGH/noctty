@echo off
rem MEASUREMENT: ReleaseFast build of one tree. Usage: build-one.cmd <tree> <log>
cd /d "%~1" || exit /b 1
call scripts\dev-windows.cmd zig build -Demit-exe=true -Doptimize=ReleaseFast -Dcustom-shaders=true --summary none > "%~2" 2>&1
echo exit=%errorlevel%>> "%~2"
exit /b %errorlevel%
