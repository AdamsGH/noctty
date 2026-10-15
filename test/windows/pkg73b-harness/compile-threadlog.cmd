@echo off
rem MEASUREMENT ONLY (PKG-73b): build threadlog.dll.
cd /d "%~dp0"
call C:\Users\amant\.t3\worktrees\winghostty\wt-pkg37\scripts\dev-windows.cmd cl /nologo /W4 /WX /O2 /LD threadlog.c /Fe:threadlog.dll > compile-threadlog.log 2>&1
