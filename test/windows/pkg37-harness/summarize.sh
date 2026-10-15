#!/usr/bin/env bash
# PKG-37: pool the G (final head) matrices into results-G.txt.
cd /c/Users/amant/.t3/worktrees/winghostty/_scratch-pkg37 || exit 1
{
echo "##### PKG-37 final: main 7171995da (mbase) vs ce0dcfc2f (mfinal); mfix = first draft 12b710eee; all + LAT-02 measurement-only trace patch"
cat G-fingerprint-before.txt G-fingerprint-after.txt
echo "##### G-v60: emulated 60 Hz, ssh-like reader, 2 runs x 240 keys"
python -I aggregate.py runs/G-v60 display swap
python -I counts.py runs/G-v60
echo "##### G-cursor: arrow keys, emulated 60 Hz"
python -I analyze_cursor.py runs/G-cursor
echo "##### G-saver: power-saver-rendering=on, emulated 60 Hz"
python -I aggregate.py runs/G-saver display
python -I counts.py runs/G-saver
echo "##### G-v0: hidden desktop, real SwapBuffers"
python -I aggregate.py runs/G-v0 swap
echo "##### G-flood: #310 case"
grep -v "^$" G-flood.log
echo "##### G-anim: 60 fps synchronized-output TUI, 10 s (v0, v60)"
grep frames G-anim-v0.log G-anim-v60.log
echo "##### G-anim-saver-v60: same TUI under power-saver-rendering=on"
grep frames G-anim-saver-v60.log
python -I gaps.py runs/G-anim-saver-v60/*
echo "##### G-held-v60: synchronized output held 200 ms across 4 writes, 10 cycles"
grep cycles G-held-v60.log
echo "##### G-held-expose: same, child invalidated every 50 ms (an expose)"
grep cycles G-held-expose.log
echo "##### G-held-expose-saver: same under power-saver-rendering=on"
grep cycles G-held-expose-saver.log
} > results-G.txt 2>&1
wc -l results-G.txt
