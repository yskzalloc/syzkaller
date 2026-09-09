#!/usr/bin/env bash
#
# run_experiments.sh - Orchestrate 3 repetitions of 12h fuzzing for QEMU, crosvm,
#                      and Firecracker on AArch64 under identical VM shapes.
#
set -uo pipefail

SYZ_DIR="/home/debian-sid/syzkaller"
STATUS_FILE="$SYZ_DIR/experiment_status.json"
ORCH_LOG="$SYZ_DIR/experiment_orchestrator.log"
CACHE_DIR="/home/debian-sid/.cache/syz-crosvm"
RUNS_DIR="$CACHE_DIR/runs"

mkdir -p "$SYZ_DIR" "$RUNS_DIR"

log() {
    local msg="[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg" | tee -a "$ORCH_LOG"
}

TOTAL_ROUNDS=3
DURATION="12h"
SANDBOXES=("setuid" "none" "namespace")
BACKENDS=("qemu" "crosvm" "firecracker")

log "======================================================================"
log "Starting Multi-Hypervisor Fuzzing Experiment Campaign (AArch64)"
log "Test Matrix: ${#SANDBOXES[@]} Sandboxes x ${#BACKENDS[@]} Backends x ${TOTAL_ROUNDS} Repetitions x ${DURATION}"
log "======================================================================"

for round in $(seq 1 $TOTAL_ROUNDS); do
    for sandbox in "${SANDBOXES[@]}"; do
        for backend in "${BACKENDS[@]}"; do
            log ">>> [Round $round/$TOTAL_ROUNDS] Starting backend: $backend (sandbox: $sandbox) for $DURATION"
            
            # Record state in STATUS_FILE
            python3 -c "
import json, time
state = {
    'total_rounds': $TOTAL_ROUNDS,
    'current_round': $round,
    'current_sandbox': '$sandbox',
    'current_backend': '$backend',
    'duration': '$DURATION',
    'start_timestamp': time.time(),
    'start_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'status': 'RUNNING'
}
with open('$STATUS_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
            
            # Execute syz.sh with -sandbox for this backend
            cd "$SYZ_DIR"
            ./syz.sh -sandbox "$sandbox" "$backend" "$DURATION" >> "$ORCH_LOG" 2>&1
            rc=$?
            
            log ">>> [Round $round/$TOTAL_ROUNDS] Backend $backend ($sandbox) finished (rc=$rc)"
            
            # Update state
            python3 -c "
import json, time
try:
    with open('$STATUS_FILE') as f:
        state = json.load(f)
except Exception:
    state = {}
if 'history' not in state:
    state['history'] = []
state['history'].append({
    'round': $round,
    'sandbox': '$sandbox',
    'backend': '$backend',
    'finish_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'exit_code': $rc
})
state['status'] = 'ROUND_TRANSITION'
with open('$STATUS_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
            # 15s cooldown between runs
            sleep 15
        done
    done
done

log "All $TOTAL_ROUNDS rounds completed successfully across all backends!"
python3 -c "
import json
try:
    with open('$STATUS_FILE') as f:
        state = json.load(f)
except Exception:
    state = {}
state['status'] = 'COMPLETED'
with open('$STATUS_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
