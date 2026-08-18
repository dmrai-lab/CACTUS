"""Can dmipy-sim actually load the generated substrate as a bundle?

Meshing "finishing" is not the same as the substrate being usable. `load_cactus_bundle` pairs
`strand_NNNNN_{inner,outer}_erode_N.ply`, derives volume fractions from the mesh volumes, and needs both
surfaces per strand -- so an outer-only run looks complete on disk and fails here.

Uses the PRIVATE engine: `bank_cactus.py` and most of `io/cactus.py` are private-only (public has just the
`CactusBundle` dataclass), and `UNIFICATION_PLAN.md` lists the port as a deferred scope decision.

Usage:  load_bundle_check.py <run_dir>     e.g. prod/cross45/cross45_00000
"""
from __future__ import annotations

import sys
import warnings

sys.path.insert(0, "/home/rutger/dmrai-ws/dmipy-sim-private")

import numpy as np  # noqa: E402

UM = 1e-6


def main():
    run_dir = sys.argv[1]
    from dmipy_sim.io.cactus import _discover, load_cactus_bundle

    found = _discover(f"{run_dir}/meshes/simulations")
    both = [i for i, d in found.items() if "inner" in d and "outer" in d]
    only_out = [i for i, d in found.items() if "outer" in d and "inner" not in d]
    only_in = [i for i, d in found.items() if "inner" in d and "outer" not in d]
    print(f"  strands discovered : {len(found)}")
    print(f"    with both surfaces: {len(both)}")
    print(f"    outer only        : {len(only_out)}")
    print(f"    inner only        : {len(only_in)}")
    if not both:
        print("  NOT LOADABLE: no strand has both surfaces -- run the inner mesh pass")
        return

    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        b = load_cactus_bundle(run_dir, g_ratio=0.7, scale=UM)
        warned = [str(x.message)[:110] for x in w]

    print(f"  loaded             : {b.summary() if hasattr(b, 'summary') else type(b).__name__}")
    for attr in ("n_fibres", "g_ratio", "f_intra", "f_myelin", "f_extra", "box_side"):
        if hasattr(b, attr):
            v = getattr(b, attr)
            print(f"    {attr:10s}: {v:.4f}" if isinstance(v, float) else f"    {attr:10s}: {v}")
    for x in warned[:4]:
        print(f"    warning: {x}")


if __name__ == "__main__":
    main()
