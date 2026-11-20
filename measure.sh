#!/bin/bash
# Runs on the instance under test. Usage: sudo ./measure.sh [seconds]   (default 300)
# Writes ./out: system snapshot, mpstat, per-vCPU steal every second, and gap-detector output per vCPU.
set -u
SECS=${1:-300}
NCPU=$(nproc)
mkdir -p out && cd out

{ uname -a; echo "clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"; cat /proc/cmdline; } > system.txt
lscpu > lscpu.txt
lscpu -e=CPU,CORE,SOCKET,NODE > lscpu-e.txt
dnf install -y -q sysstat > /dev/null 2>&1 || yum install -y -q sysstat > /dev/null 2>&1

mpstat -P ALL 1 "$SECS" > mpstat.txt 2>&1 &

# Per-vCPU cumulative steal (USER_HZ ticks, usually 10 ms) once a second: "<epoch> cpu:steal ..."
( end=$((SECONDS + SECS)); while [ $SECONDS -lt $end ]; do
    echo "$(date +%s.%N) $(awk '/^cpu[0-9]/ {printf "%s:%s ", substr($1, 4), $9}' /proc/stat)"; sleep 1
  done ) > steal.txt &

# Gap detector: one busy loop pinned to each vCPU, logging "<epoch at gap end> <gap us>" for gaps over 5 ms
for c in $(seq 0 $((NCPU - 1))); do
  python3 - "$c" "$SECS" > gaps-$c.txt <<'PY' &
import os, sys, time
cpu, secs = int(sys.argv[1]), int(sys.argv[2])
os.sched_setaffinity(0, {cpu})
ns, rt = time.perf_counter_ns, time.time
last = ns(); end = last + secs * 10**9; gaps = []
while last < end:
    now = ns()
    if now - last > 5_000_000:
        gaps.append(f'{rt():.6f} {(now - last) // 1000}')
    last = now
print('\n'.join(gaps))
PY
done
wait
