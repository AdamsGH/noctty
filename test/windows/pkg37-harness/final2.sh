#!/usr/bin/env bash
# PKG-37: before/after (main 7171995da = mbase, final head = mfinal; mfix = first draft), all with LAT-02's
# measurement-only trace patch. Sequential; LAT-02's matrices plus the PKG-37 probes.
cd /c/Users/amant/.t3/worktrees/winghostty/_scratch-pkg37 || exit 1
B=mbase,mfinal
bash fingerprint.sh > G-fingerprint-before.txt
pwsh -NoProfile -File matrix.ps1 -Name G-v60 -Builds $B -Scenarios d0-ssh-steady,d20-ssh-steady,d55-ssh-burst-line -Reps 2 -Count 240 -VsyncHz 60 > G-v60.log 2>&1
pwsh -NoProfile -File matrix.ps1 -Name G-cursor -Builds $B -Scenarios d0-vt-cursor,d30-vt-cursor -Reps 2 -Count 200 -VsyncHz 60 -DriverScript lat-driver3.ps1 > G-cursor.log 2>&1
pwsh -NoProfile -File matrix.ps1 -Name G-saver -Builds $B -Scenarios d0-ssh-steady,d0-ssh-burst,d0-vt-cursor -Reps 2 -Count 200 -VsyncHz 60 -DriverScript lat-driver3.ps1 -Extra '--power-saver-rendering=on' > G-saver.log 2>&1
pwsh -NoProfile -File matrix.ps1 -Name G-v0 -Builds $B -Scenarios d0-ssh-steady,d30-ssh-burst-line -Reps 2 -Count 240 -VsyncHz 0 > G-v0.log 2>&1
pwsh -NoProfile -File flood-matrix.ps1 -Name G-flood -Builds $B -Reps 3 > G-flood.log 2>&1
pwsh -NoProfile -File anim-matrix.ps1 -Name G-anim-v0 -Builds $B -Reps 2 -Seconds 10 -VsyncHz 0 > G-anim-v0.log 2>&1
pwsh -NoProfile -File anim-matrix.ps1 -Name G-anim-v60 -Builds $B -Reps 2 -Seconds 10 -VsyncHz 60 > G-anim-v60.log 2>&1
pwsh -NoProfile -File probe-matrix.ps1 -Name G-held-v60 -Builds $B -Reps 2 -Tool held -Arg1 200 -Arg2 10 -VsyncHz 60 > G-held-v60.log 2>&1
pwsh -NoProfile -File probe-matrix.ps1 -Name G-anim-saver-v60 -Builds $B -Reps 2 -Tool anim -Arg1 60 -Arg2 10 -VsyncHz 60 -Extra '--power-saver-rendering=on' > G-anim-saver-v60.log 2>&1
pwsh -NoProfile -File probe-matrix.ps1 -Name G-held-expose -Builds mbase,mfix,mfinal -Reps 2 -Tool held -Arg1 200 -Arg2 10 -InvalidateMs 50 > G-held-expose.log 2>&1
pwsh -NoProfile -File probe-matrix.ps1 -Name G-held-expose-saver -Builds mbase,mfix,mfinal -Reps 2 -Tool held -Arg1 200 -Arg2 10 -InvalidateMs 50 -Extra '--power-saver-rendering=on' > G-held-expose-saver.log 2>&1
bash fingerprint.sh > G-fingerprint-after.txt
echo done > G.done
