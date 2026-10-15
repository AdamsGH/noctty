@echo off
cd /d "%~dp0"
call C:\Users\amant\.t3\worktrees\winghostty\wt-pkg37\scripts\dev-windows.cmd cl /nologo /W4 /WX /O2 thwalk.c /Fe:thwalk.exe > compile-thwalk.log 2>&1
