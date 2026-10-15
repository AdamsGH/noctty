#!/usr/bin/env bash
# LAT-02: final before/after measurements (main vs final head), sequential.
cd /c/Users/amant/.t3/worktrees/winghostty/_scratch-lat02 || exit 1
B=mbase,mfinal
bash fingerprint.sh > F-fingerprint-before.txt
pwsh -NoProfile -File matrix.ps1 -Name F-v60 -Builds $B -Scenarios d0-ssh-steady,d20-ssh-steady,d55-ssh-steady,d70-ssh-steady,d55-ssh-burst-line -Reps 2 -Count 240 -VsyncHz 60 > F-v60.log 2>&1
pwsh -NoProfile -File matrix.ps1 -Name F-cursor -Builds $B -Scenarios d0-vt-cursor,d30-vt-cursor -Reps 2 -Count 200 -VsyncHz 60 -DriverScript lat-driver3.ps1 > F-cursor.log 2>&1
pwsh -NoProfile -File matrix.ps1 -Name F-saver -Builds $B -Scenarios d0-ssh-steady,d0-ssh-burst,d0-vt-cursor -Reps 2 -Count 200 -VsyncHz 60 -DriverScript lat-driver3.ps1 -Extra '--power-saver-rendering=on' > F-saver.log 2>&1
pwsh -NoProfile -File matrix.ps1 -Name F-v0 -Builds $B -Scenarios d0-ssh-steady,d30-ssh-burst-line -Reps 2 -Count 240 -VsyncHz 0 > F-v0.log 2>&1
pwsh -NoProfile -File flood-matrix.ps1 -Name F-flood -Builds $B -Reps 3 > F-flood.log 2>&1
pwsh -NoProfile -File anim-matrix.ps1 -Name F-anim-v0 -Builds $B -Reps 2 -Seconds 10 -VsyncHz 0 > F-anim-v0.log 2>&1
pwsh -NoProfile -File anim-matrix.ps1 -Name F-anim-v60 -Builds $B -Reps 2 -Seconds 10 -VsyncHz 60 > F-anim-v60.log 2>&1
bash fingerprint.sh > F-fingerprint-after.txt
echo done > F.done
