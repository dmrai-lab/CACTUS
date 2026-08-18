#!/bin/bash
# Grow CACTUS strands in fixed-size BATCHES, driving meta_grid directly.
#
# `resume_growth_chunked.sh` recycles the worker pool when memory runs low, which is enough when only a
# handful of strands are outstanding. It is NOT enough for a from-scratch run: meta_grid is handed the
# whole missing list at once and allocates per-strand before doing any work, so a 409-strand list wedges
# instantly -- measured on cross90, 276 GB RSS against 2 CPU seconds in 7 minutes. Memory-based recycling
# never gets a chance because the process is already stuck by the time the threshold trips.
#
# So the list is split here and meta_grid is invoked per batch. Each batch is a fresh process, which also
# discards the leak. Completed strands are pickled to disk, so a killed batch costs at most that batch.
#
# Batches are always written with at least two ids: np.loadtxt returns a 0-d array for a single-line file
# and `list()` over it raises TypeError in meta_grid. A duplicate id is harmless -- growing a strand twice
# just rewrites the same pickle.
#
# Usage:  grow_in_batches.sh <run_dir> <config> [batch_size] [min_free_gb]
set -u
RUN_DIR="${1:?usage: grow_in_batches.sh <run_dir> <config> [batch] [min_free_gb]}"
CONFIG="${2:?}"
BATCH="${3:-12}"
MIN_FREE="${4:-120}"
VENV=/home/rutger/dmrai-ws/CACTUS/.venv

INNER=$(ls -d "$RUN_DIR"/*_00000 2>/dev/null | head -1)
[ -z "$INNER" ] && { echo "no <name>_00000 dir under $RUN_DIR"; exit 1; }
INIT=$(basename "$INNER").init
MISSING="$INNER/0_missing_axon_file.txt"

free_gb()  { free -g | awk '/^Mem:/{print $7}'; }
have()     { ls "$INNER"/meshes/pickles/*.npz 2>/dev/null | wc -l; }

cd "$INNER" || exit 1
source "$VENV/bin/activate"

# refresh the missing list once, through the tool, so ids come from its own accounting
# ALWAYS refresh, never reuse: a stale list re-grows strands that already exist, the pickle count then
# does not move, and the "added nothing" guard below reads that as failure and stops on the first batch.
rm -f "$MISSING"
python3 -m cactus1_substrate.workers.check_pickles -file "$INIT" -outfile 0_missing_axon_file.txt \
    >/dev/null 2>&1
mapfile -t IDS < "$MISSING"
echo "[batches] $(date +%H:%M:%S) ${#IDS[@]} strands to grow, batch=$BATCH, have=$(have)"

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
    slice=("${IDS[@]:$i:$BATCH}")
    # never a single-line file (0-d array crash in meta_grid)
    [ "${#slice[@]}" -eq 1 ] && slice+=("${slice[0]}")
    printf '%s\n' "${slice[@]}" > /tmp/batch_ids.txt

    before=$(have)
    # setsid: meta_grid spawns a multiprocessing pool, and killing only the parent leaves the children
    # ORPHANED and still holding their allocations -- measured, 48 orphans pinning 350 GB after one kill.
    # Its own process group can be signalled as a unit.
    setsid timeout 3600 python3 -m cactus1_substrate.workers.meta_grid \
        -file "$INIT" -missing_axon_file /tmp/batch_ids.txt -iterations 4 -grid_size 0.35 \
        >> "$RUN_DIR/grow_batches.log" 2>&1 &
    mg=$!
    wait "$mg"; rc=$?
    kill -9 -- "-$mg" 2>/dev/null      # reap anything the pool left behind
    after=$(have)
    echo "[batch $((i/BATCH+1))] $(date +%H:%M:%S) ids ${slice[0]}..${slice[-1]}  rc=$rc  strands $before -> $after  free=$(free_gb)GB"

    # a batch that grew nothing is not a memory problem; stop rather than spin through the whole list
    if [ "$after" = "$before" ]; then
        echo "  batch added nothing (rc=$rc) -- stopping so the reason gets looked at"
        break
    fi
    # belt and braces: sweep pool workers reparented to init, which the group kill can still miss.
    # Only sound while ONE substrate is running -- a concurrent mesh pass whose parent died would be
    # caught too. The recipe in CROSSING-NOTES.md runs them one at a time for this reason.
    ps -eo pid,ppid,args --no-headers | grep spawn_main | grep -v grep \
        | awk '$2==1 {print $1}' | while read -r p; do kill -9 "$p" 2>/dev/null; done
    i=$((i + BATCH))
done
echo "[done] $(date +%H:%M:%S) strands=$(have) free=$(free_gb)GB"
