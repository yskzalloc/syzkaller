#!/usr/bin/env bash
#
# check_status.sh - Token-efficient status check for ongoing fuzzing experiments.
#
set -uo pipefail

SYZ_DIR="/home/debian-sid/syzkaller"
STATUS_FILE="$SYZ_DIR/experiment_status.json"
CACHE_DIR="/home/debian-sid/.cache/syz-crosvm"
RUNS_DIR="$CACHE_DIR/runs"

echo "=== Experiment Status Report ==="
echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

if [[ -f "$STATUS_FILE" ]]; then
    python3 -c "
import json, time, os, glob

with open('$STATUS_FILE') as f:
    s = json.load(f)

status = s.get('status', 'UNKNOWN')
round_num = s.get('current_round', '?')
total_rounds = s.get('total_rounds', '?')
backend = s.get('current_backend', '?')
start_ts = s.get('start_timestamp', 0)
elapsed_s = int(time.time() - start_ts) if start_ts else 0
elapsed_h = elapsed_s / 3600.0

sandbox = s.get('current_sandbox', '')
sb_str = f' | Sandbox: {sandbox}' if sandbox else ''
print(f'Campaign Status: {status} | Round: {round_num}/{total_rounds}{sb_str} | Backend: {backend}')
print(f'Elapsed Time:    {elapsed_h:.2f}h ({elapsed_s}s)')

# Check running syz-manager
pids = [line.strip() for line in os.popen('pgrep -x syz-manager').read().split() if line.strip()]
print(f'Active Manager:  {\"PID \" + \", \".join(pids) if pids else \"None (Idle/Transition)\"}')

# Find latest bench.json in runs directory
bench_files = glob.glob('$RUNS_DIR/*-*/bench.json')
if bench_files:
    latest_bench = max(bench_files, key=os.path.getmtime)
    run_name = os.path.basename(os.path.dirname(latest_bench))
    try:
        lines = open(latest_bench).read().strip().split('\n')
        # bench.json is concatenated JSON objects
        dec = json.JSONDecoder()
        text = open(latest_bench).read()
        i, n, snaps = 0, len(text), []
        while i < n:
            while i < n and text[i] in ' \t\r\n': i += 1
            if i >= n: break
            obj, end = dec.raw_decode(text, i)
            snaps.append(obj)
            i = end
        if snaps:
            last = snaps[-1]
            corpus = last.get('corpus', 0)
            cov = last.get('coverage', 0)
            execs = last.get('exec total', 0)
            crashes = last.get('crashes', 0)
            uptime = last.get('uptime', 1)
            rate = execs / uptime if uptime else 0.0
            print(f'Latest Metrics ({run_name}):')
            print(f'  Execs: {execs} ({rate:.1f} exec/s) | Coverage: {cov} | Corpus: {corpus} | Crashes: {crashes}')
    except Exception as e:
        print(f'  (Metrics parsing error: {e})')
else:
    print('  No bench data written yet.')
"
else
    echo "No status file found at $STATUS_FILE."
fi
