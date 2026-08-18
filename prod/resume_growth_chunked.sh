#!/bin/bash
# Resume CACTUS radial growth in memory-bounded chunks.
#
# Why this exists: `grow -substep growth` leaks. Each worker's RSS climbs without bound as it walks
# strands -- measured on cross45, ~300 GB consumed for 38 strands -- until the box is exhausted and the
# whole pool wedges. That is what killed the original 2026-07-30 run: it stalled at strand 386 holding
# 129 GB in the parent and ~21 GB in each of 40 workers, having burned 4 CPU seconds in 2.9 hours.
#
# Completed strands are pickled to disk and `-run_case missing` re-reads what is already there, so the
# work is resumable at no cost. This runs it, watches free memory, kills the pool before it wedges, and
# starts a fresh one that picks up where the last left off.
#
# Usage:  resume_growth_chunked.sh <run_dir> <config> [min_free_gb]
set -u
RUN_DIR="${1:?usage: resume_growth_chunked.sh <run_dir> <config> [min_free_gb]}"
CONFIG="${2:?}"
MIN_FREE="${3:-120}"
VENV=/home/rutger/dmrai-ws/CACTUS/.venv
PICKLES="$RUN_DIR"/*_00000/meshes/pickles

count_pickles() { ls $PICKLES 2>/dev/null | wc -l; }
free_gb()       { free -g | awk '/^Mem:/{print $7}'; }
# -1 means "not known yet": the file is written by check_pickles during a run, so on a FRESH run it does
# not exist and an absent file must not read as "nothing left to do".
missing() {
    local f
    f=$(ls "$RUN_DIR"/*_00000/0_missing_axon_file.txt 2>/dev/null | head -1)
    if [ -z "$f" ]; then echo -1; else wc -l < "$f"; fi
}

cd "$RUN_DIR" || exit 1
for chunk in $(seq 1 40); do
    left=$(missing)
    echo "[chunk $chunk] $(date +%H:%M:%S)  pickles=$(count_pickles)  missing=$left  free=$(free_gb)GB"
    [ "$left" -eq 0 ] && { echo "ALL STRANDS GROWN"; break; }
    [ "$left" -lt 0 ] && echo "  (no missing-axon file yet -- first pass will create it)"

    setsid bash -c "source $VENV/bin/activate; cd '$RUN_DIR'; \
        yes '' | cactus1-substrates grow -config_file '$CONFIG' -substep growth -run_case missing" \
        >> "$RUN_DIR/growth_chunked.log" 2>&1 < /dev/null &

    # supervise: stop this chunk when memory runs low, when it finishes, or after 25 minutes
    for t in $(seq 1 150); do
        sleep 10
        # pgrep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` would append a second 0
        n=$(pgrep -c -f "CACTUS/.venv" 2>/dev/null); n=${n:-0}
        [ "$n" -eq 0 ] && { echo "  chunk exited on its own"; break; }
        f=$(free_gb)
        if [ "$f" -lt "$MIN_FREE" ]; then
            echo "  free=${f}GB < ${MIN_FREE}GB -> recycling the pool (progress is on disk)"
            break
        fi
    done

    pgrep -f "CACTUS/.venv" | while read -r p; do kill "$p" 2>/dev/null; done
    sleep 5
    pgrep -f "CACTUS/.venv" | while read -r p; do kill -9 "$p" 2>/dev/null; done
    sleep 5

    # a chunk that grew nothing means the remaining strands fail for a reason memory cannot fix
    now=$(count_pickles)
    if [ "${prev:-0}" = "$now" ] && [ "$chunk" -gt 1 ]; then
        echo "STALLED: chunk $chunk added no pickles (still $now). Not a memory problem; stopping."
        break
    fi
    prev=$now
done
echo "[done] $(date +%H:%M:%S) pickles=$(count_pickles) missing=$(missing) free=$(free_gb)GB"
