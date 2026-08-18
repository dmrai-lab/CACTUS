"""Are the generated CACTUS meshes fit to simulate on?

Checks the properties that actually bit us on the Winther set, in the order they bite:

* **watertight** — ray-parity containment is undefined on an open surface, so seeding and volume
  fractions both depend on this (dmipy-sim#50).
* **smooth-vs-face normal divergence** — the reflection uses the interpolated vertex normal, and where
  that sits far from the face actually struck the walker can be sent through the wall. 85 degrees at a
  capped-cylinder rim cost 35% of the ensemble before dmipy-sim#42; a real axon should run a few degrees
  (axon06-inner: median 3.1, 0.01% of corners inverted).
* **degenerate vertex normals** — duplicate or non-manifold faces make the area-weighted sums cancel,
  leaving a normal that is numerical noise.
* **triangle scale vs the box** — sets `_EPS/_NUDGE` (dmipy-sim#53). Past 1, walkers leak.

Deliberately loads with `trimesh.load(process=False)`: these PLYs are written by CACTUS, not by the
Winther pipeline, so the ushort face-index wrap that `load_winther_axon` repairs does not apply. If a
mesh here reports the signature of that wrap (duplicate faces plus many non-manifold edges) it is a real
defect in the generated mesh, not a loading artifact.

Usage:  validate_meshes.py <dir-with-plys> [max_meshes]
"""
from __future__ import annotations

import glob
import os
import sys

import numpy as np
import trimesh

BOX_UM = 30.0          # lenght_side in the crossing configs


def divergence(V, F):
    """Angle between each triangle corner's smooth normal and its own face normal, in degrees."""
    tris = V[F]
    cr = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    vn = np.zeros((len(V), 3))
    for k in range(3):
        np.add.at(vn, F[:, k], cr)
    mag = np.linalg.norm(vn, axis=1)
    vnn = vn / np.maximum(mag[:, None], 1e-30)
    nrm = cr / np.maximum(np.linalg.norm(cr, axis=1, keepdims=True), 1e-30)
    cos = np.einsum("ij,ikj->ik", nrm, vnn[F])
    ang = np.degrees(np.arccos(np.clip(cos, -1, 1)))
    degenerate = int((mag < 1e-3 * np.median(mag)).sum())
    return ang, degenerate


def main():
    d = sys.argv[1]
    cap = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    files = sorted(glob.glob(os.path.join(d, "**", "*.ply"), recursive=True))
    if not files:
        print(f"  no PLYs under {d}")
        return
    step = max(1, len(files) // cap)
    sample = files[::step][:cap]
    print(f"  {len(files)} meshes, checking {len(sample)}")

    n_open = n_deg = n_inverted = 0
    edges, med_ang, max_ang = [], [], []
    for f in sample:
        m = trimesh.load(f, process=False)
        V = np.asarray(m.vertices, float)
        F = np.asarray(m.faces, np.int64)
        if len(F) == 0:
            print(f"  EMPTY: {os.path.basename(f)}")
            continue
        ang, deg = divergence(V, F)
        e = np.linalg.norm(V[F[:, 0]] - V[F[:, 1]], axis=1)
        edges.append(float(np.median(e)))
        med_ang.append(float(np.median(ang)))
        max_ang.append(float(ang.max()))
        n_open += (not m.is_watertight)
        n_deg += (deg > 0)
        n_inverted += ((ang > 90).mean() > 1e-3)

    print(f"  watertight            : {len(sample)-n_open}/{len(sample)}")
    print(f"  free of degenerate vn : {len(sample)-n_deg}/{len(sample)}")
    print(f"  <0.1% inverted corners: {len(sample)-n_inverted}/{len(sample)}")
    print(f"  smooth-vs-face angle  : median {np.median(med_ang):.1f} deg, worst mesh max {max(max_ang):.1f} deg")
    me = float(np.median(edges))
    print(f"  median edge           : {me:.4f} um  (mesh units as written)")
    for name, fr in (("fr = median edge", me), ("fr = half median edge", me / 2)):
        ratio = 6e-3 * BOX_UM / fr if fr else float("nan")
        flag = "  <-- LEAKS (dmipy-sim#53)" if ratio >= 1 else ""
        print(f"    _EPS/_NUDGE with {name:22s}: {ratio:6.3f}{flag}")


if __name__ == "__main__":
    main()
