#!/usr/bin/env bash
# PKG-37: run a .cmd at below-normal priority. `start /belownormal` hangs in
# this agent shell, so lower this bash's own priority class first; children
# created from a below-normal process inherit it.
# usage: lowprio.sh <script.cmd> [args...]
winpid=$(cat /proc/$$/winpid)
pwsh -NoProfile -Command "(Get-Process -Id $winpid).PriorityClass = 'BelowNormal'" || exit 1
S='C:\Users\amant\.t3\worktrees\winghostty\_scratch-pkg37'
script="$1"; shift
MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c "$S\\$script $*" </dev/null
