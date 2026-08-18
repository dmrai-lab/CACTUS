#!/bin/bash
# Wait for a substrate's growth to finish, then mesh it (both surfaces) and validate.
#
# The stages after growth are mechanical but must be run in order and with the right flags -- see
# CROSSING-NOTES.md for why each one is what it is:
#   * `-run_case all`, never `missing`: check_meshes raises NameError on any absent mesh (problem 2).
#   * two passes: the config's `inn_out` produces ONE surface, and a bundle needs both (problem 5).
# Validation is not optional here: a killed growth pool can leave a truncated .npz that only shows up
# as `zipfile.BadZipFile` in the middle of meshing (problem 4).
#
# Usage:  finish_substrate.sh <run_dir> <outer_config> <inner_config>
set -u
RUN_DIR="${1:?usage: finish_substrate.sh <run_dir> <outer_config> <inner_config>}"
OUTER_CFG="${2:?}"
INNER_CFG="${3:?}"
VENV=/home/rutger/dmrai-ws/CACTUS/.venv
INNER=$(ls -d "$RUN_DIR"/*_00000 2>/dev/null | head -1)
PICK="$INNER/meshes/pickles"

echo "[finish] $(date +%H:%M:%S) waiting for growth on $(basename "$RUN_DIR") to finish"
while pgrep -f "grow_in_batches.*$(basename "$RUN_DIR")" >/dev/null 2>&1; do sleep 60; done
echo "[finish] $(date +%H:%M:%S) growth done: $(ls "$PICK"/*.npz 2>/dev/null | wc -l) strands"

# Completeness first: growth can stop early (a wedged batch, a stalled pool), and meshing a partial
# substrate produces one that looks finished and is not. check_pickles rewrites the missing list from
# its own accounting, so an empty list is the tool's own statement that nothing is left.
echo "[finish] $(date +%H:%M:%S) checking every strand was grown"
rm -f "$INNER/0_missing_axon_file.txt"
( cd "$INNER" && source "$VENV/bin/activate" && \
  python3 -m cactus1_substrate.workers.check_pickles -file "$(basename "$INNER").init" \
      -outfile 0_missing_axon_file.txt >/dev/null 2>&1 )
CHECK_RC=$?
# check_pickles writes the list ONLY when something is missing, so an ABSENT file after a successful run
# means nothing is left -- the success case, not a failure. Distinguish the two by its exit status.
if [ "$CHECK_RC" != "0" ]; then
    LEFT=999
    echo "[finish] check_pickles itself failed (rc=$CHECK_RC) -- treating completeness as unknown"
elif [ -f "$INNER/0_missing_axon_file.txt" ]; then
    LEFT=$(wc -l < "$INNER/0_missing_axon_file.txt")
else
    LEFT=0
fi
echo "[finish] strands still missing: $LEFT"
if [ "$LEFT" != "0" ]; then
    echo "[finish] STOPPING -- growth is incomplete. Re-run grow_in_batches.sh; meshing now would give a"
    echo "         substrate that looks finished and is not."
    exit 1
fi

echo "[finish] $(date +%H:%M:%S) validating strand files before meshing"
BAD=$("$VENV/bin/python3" - "$PICK" <<'PY'
import glob, os, pickle, sys
import numpy as np
d = sys.argv[1]; bad = []
for f in sorted(glob.glob(os.path.join(d, "*.npz"))):
    try:
        z = np.load(f); z.files; z.close()
    except Exception:
        bad.append(f)
for f in sorted(glob.glob(os.path.join(d, "*.pbz2"))):
    try:
        with open(f, "rb") as fh: pickle.load(fh)   # plain pickle despite the extension
    except Exception:
        bad.append(f)
print(len(bad))
for f in bad: print(f, file=sys.stderr)
PY
)
echo "[finish] corrupt strand files: $BAD"
if [ "$BAD" != "0" ]; then
    echo "[finish] STOPPING -- quarantine those and regrow them (CROSSING-NOTES.md problem 4) before meshing"
    exit 1
fi

cd "$RUN_DIR" || exit 1
source "$VENV/bin/activate"
for cfg in "$OUTER_CFG" "$INNER_CFG"; do
    echo "[finish] $(date +%H:%M:%S) mesh pass with $cfg"
    yes '' | cactus1-substrates grow -config_file "$cfg" -substep mesh -run_case all \
        >> "$RUN_DIR/mesh_passes.log" 2>&1
    echo "[finish] $(date +%H:%M:%S)   rc=$? -> $(find "$RUN_DIR" -name '*.ply' | wc -l) plys total"
done

echo "[finish] $(date +%H:%M:%S) validating meshes"
/home/rutger/dmipy-venv/bin/python /home/rutger/dmrai-ws/CACTUS/prod/validate_meshes.py "$RUN_DIR" 40
echo "[finish] $(date +%H:%M:%S) loading as a bundle"
/home/rutger/dmipy-venv/bin/python /home/rutger/dmrai-ws/CACTUS/prod/load_bundle_check.py "$INNER" 2>&1 \
    | grep -v "warning: unclosed"
echo "[finish] $(date +%H:%M:%S) DONE"
