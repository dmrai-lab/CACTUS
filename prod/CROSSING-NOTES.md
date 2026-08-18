# Why cross45 / cross90 had no meshes, and what it took to get them

Both crossing substrates had completed *growth optimisation* (`optimized_final.txt` present) but zero PLY
meshes since 2026-07-30. Four separate problems, in the order they bite. Three are bugs in CACTUS itself
(upstream is `Juanitovh/CACTUS`; nothing has been reported there, that is a call for the maintainer of
this checkout).

## 1. `grow -substep growth` leaks memory until the pool wedges

Each worker's RSS climbs without bound as it walks strands. Measured on cross45: **~400 GB consumed per
14 minutes of work**, spread over ~40 spawned workers at ~21 GB each. When the box is exhausted the pool
does not crash, it *wedges* — the original run sat at strand 386 holding 129 GB in the parent, having
burned **4 CPU seconds in 2.9 hours**. That is what killed the 2026-07-30 attempt, and lowering
`n_cores` does not help because the worker count is not what `n_cores` controls.

Completed strands are pickled to disk and `-run_case missing` re-reads them, so the work is resumable at
no cost. `resume_growth_chunked.sh` runs growth, watches free memory, kills the pool before it wedges, and starts
a fresh one that picks up where the last left off. cross45 finished in ~8 chunks.

**That is only enough when a handful of strands are outstanding.** On a FROM-SCRATCH run it fails
differently: `meta_grid` is handed the whole missing list and allocates per strand before doing any work,
so 409 strands wedge it instantly -- cross90 sat at 276 GB RSS against **2 CPU seconds in 7 minutes**.
Memory-based recycling never gets a chance, because the process is stuck before the threshold trips. cross45
only ever *resumed*, which is why it never hit this.

Use `grow_in_batches.sh` for a fresh substrate: it splits the list and drives `meta_grid` per batch of 12,
each a fresh process (which also discards the leak). Measured effect -- worker RSS drops from ~21 GB to
~400 MB, because the allocation is per strand in the batch, not per strand in the file.

## 2. `check_meshes` crashes whenever a mesh is missing

`workers/check_meshes.py::try_read_ply` is a module-level function handed to a multiprocessing pool, and
on the missing-file branch it does:

```python
if not os.path.isfile(strand_file):
    missing_strands.append(i)      # NameError: local to main(), invisible in the worker
```

So `-substep mesh -run_case missing` raises `NameError` on any run where a mesh is genuinely absent —
which is every fresh run. This is why the main bundle succeeded and the crossings never could:
`run_prod.sh` meshes with **`-run_case all`**, which sets `command_check = None` and skips the check
entirely. Use `-run_case all` for meshing. It is also the correct thing here: every strand needs a mesh.

## 3. `meta_grid` crashes when exactly ONE strand is missing

```python
strands_id = list(np.loadtxt(args.missing_axon_file, dtype=int))
# TypeError: iteration over a 0-d array
```

`np.loadtxt` returns a 0-d array for a single-line file. Any resume that comes down to one strand dies.
Workaround: write the id twice into the missing-axon file and pass it with `-missing_axon_file`; growing
a strand twice is idempotent.

## 4. A killed pool can leave a truncated `.npz`

Recycling the pool (problem 1) risks killing a worker mid-write, which leaves a partial `.npz` that later
fails meshing with `zipfile.BadZipFile`. One of 406 strands was hit. **Always validate before meshing:**

```python
for f in glob.glob('*.npz'):
    try: z = np.load(f); z.files; z.close()
    except Exception: print('CORRUPT', f)
for f in glob.glob('*.pbz2'):
    try: pickle.load(open(f,'rb'))     # plain pickle despite the extension, NOT bz2
    except Exception: print('CORRUPT', f)
```

Move a corrupt pair aside and re-run growth for that id (via workaround 3).

## 5. The mesh step only makes the OUTER surface

`inn_out outer` in the config produces `strand_*_outer_erode_0.ply` and nothing else, but
`dmipy_sim.io.cactus._discover` pairs `strand_NNNNN_{inner,outer}_erode_N.ply` and a bundle needs both
(g-ratio, myelin). The working bundle has 366 of each because it was meshed twice. Run a second pass with
a config whose only change is `inn_out inner`.

## Recipe

```bash
cd prod/<name>
../grow_in_batches.sh $PWD <config>.txt 12 120          # 1,3: batched growth (fresh substrate)
../resume_growth_chunked.sh $PWD <config>.txt 120       #      or this, to top up a partial one
#    validate the .npz/.pbz2 pairs, regrow any corrupt ones                        # 4
source ../../.venv/bin/activate
yes '' | cactus1-substrates grow -config_file <config>.txt       -substep mesh -run_case all   # 2
yes '' | cactus1-substrates grow -config_file <config>_inner.txt -substep mesh -run_case all   # 5
python3 ../validate_meshes.py $PWD
```

Both `-run_case all`: `missing` cannot work for meshing (problem 2), and every strand needs a mesh anyway.

`cross45_lowmem.txt` is `cross45.txt` with `n_cores 8 -> 2`, and `cross45_inner.txt` is that with
`inn_out outer -> inner`; both are separate files so the originals are untouched. The worker count barely
responds to `n_cores`, but the smaller value does slow the leak.

Known limitation of `resume_growth_chunked.sh`: its liveness check matches any `CACTUS/.venv` process, so
running two substrates at once makes each wait its full 25-minute chunk timeout instead of noticing its own
chunk finished. Run them one at a time, or make the check match the config name.

## Separate: these meshes are not yet simulable

dmipy-sim's collision guard has an unbounded ratio `_EPS/_NUDGE = 6e-3 * box / feature_radius`, and past
~1 walkers pass through walls. Measured on the meshes actually generated here -- median edge **0.379 um**
in a 30 um box -- the ratio is **0.475** (feature radius = median edge) to **0.95** (half of it), against
0.16 on the geometry the engine is normally exercised with. At 1.33 a measured **0.95% of intra walkers
leave the axon**, which is at the 9.3e-3 Monte-Carlo floor the packs certify against, so it biases
`f_intra` rather than scattering.

That is dmrai-lab/dmipy-sim#53, fixed in its PR #54. **Meshes alone do not unblock CACTUS packs.**

Worth knowing when these are simulated: their smooth-vs-face normal divergence is median **13.1 deg** with
a worst case of 109 deg, against 3.1 deg on the Winther axons. The shading-normal reflection bug fixed in
dmipy-sim#42 was hitting this geometry considerably harder than anything else we have.

## 6. The loader's volume fractions are wrong for these substrates

Not a generation problem -- a consequence of what was generated. The crossing fibres run the full
`depth_lenght_bundle 100` while `lenght_side` is 30, so the meshes span **103.7 x 92.8 x 40.3 um** around
a 30 um voxel. `load_cactus_bundle` sums whole-mesh volumes and divides by the box, which is right for the
main bundle (34.0 x 32.4 x 32.3 um -- it fits) and wrong here:

| | reported | clipped to the voxel | |
|---|---|---|---|
| `f_intra` | 0.563 | **0.371** | 1.5x over |
| `f_myelin` | 0.352 | **0.246** | 1.4x over |
| `f_extra` | 0.085 | **0.383** | **4.5x under** |

`mesh_axon_master` sizes its per-pool walker counts from these, so a crossing pack would be mis-weighted
throughout, silently -- 0.563/0.352/0.085 reads as a plausible white-matter triple. Tracked as
dmrai-lab/dmipy-sim-private#6. Nothing is interpenetrating: fill over the region the fibres actually
occupy is 0.22, and the overhang is deliberate so walkers inside the voxel meet continuous fibres.

Also from the full-set check: **12 of 406** outer meshes report not-watertight, but all trivially so --
8 have ZERO boundary edges and a single non-manifold edge (a topological pinch, not a hole), and 4 have
two boundary edges, 0.01% of their edges. That is well inside `mesh_contains`'s repair tolerance
(`_MAX_BOUNDARY_EDGE_FRACTION` = 1%), and is the same two-edge-slit case its docstring cites for one of
the Winther axons. They are fine to simulate. Worth knowing anyway: a 12-mesh sample found none of them,
so sample first, then check the whole set before trusting a substrate.

## cross45, final state (validated)

406 strands, 406 outer + 406 inner meshes, loads as `CactusBundle(406 fibres, g=0.70, box=30 um, axis=x)`.

`validate_meshes.py` over 40 of the 812:

| | |
|---|---|
| watertight | 34/40 -- every failure trivial (<=2 boundary edges, one non-manifold edge) |
| free of degenerate vertex normals | 40/40 |
| <0.1% inverted corners | 37/40 |
| smooth-vs-face normal angle | median **14.9 deg**, worst mesh **153.7 deg** |
| median edge | 0.379 um |

A first 12-mesh sample reported 12/12 on all three counts, which was luck -- sample to get oriented, then
check the whole set.

**It is a real crossing, not just a loadable pile of meshes.** Taking each fibre's principal axis (SVD of
its centred vertices) and histogramming the angle in the xy plane gives two populations separated by
**47.4 deg**, against the configured `crossing_angle 45` -- one bundle near 0 deg, the other near 45.

These are rougher than the Winther axons (3.1 deg median, 0.01% inverted). That is the geometry the
shading-normal fix in dmipy-sim#42 protects: reflecting off an interpolated normal that far from the face
sends walkers through the wall, and before that fix a capped cylinder at 85 deg lost a third of its
ensemble. Simulating these without #42 would not have been meaningful.

## cross90, final state (validated)

409 strands, 409 outer + 409 inner meshes, loads as
`CactusBundle(409 fibres, g=0.70, box=30 um, axis=y)`. Grown by `grow_in_batches.sh` in 33 batches of 12
(every one rc=0, memory back to ~516 GB after each), then `finish_substrate.sh` ran the completeness gate,
the strand-file validation, both mesh passes and the bundle load unattended.

| | |
|---|---|
| strands missing / corrupt | 0 / 0 |
| watertight | 37/40 |
| free of degenerate vertex normals | 40/40 |
| <0.1% inverted corners | 39/40 |
| smooth-vs-face normal angle | median **15.3 deg**, worst mesh **174.2 deg** |
| median edge | 0.3815 um |
| `_EPS/_NUDGE` | 0.472 (fr = median edge) to 0.944 (half) |

Reported fractions are `f_intra` 0.555 / `f_myelin` 0.350 / `f_extra` 0.094 -- inflated by the same
whole-mesh-volume-over-box division as cross45 (#6); the voxel-clipped values will be lower.

**Both crossings are real.** Per-fibre principal axes give two populations separated by **47.4 deg** for
cross45 (config 45) and **91.6 deg** for cross90 (config 90), the few-degree spread being the configured
`dispersion 10`. cross45 reports `axis=x` and cross90 `axis=y`, which is just which mode the bundle-axis
estimator picks.
