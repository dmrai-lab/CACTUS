# dmrai-lab/CACTUS — what this fork changes, and why it exists

Fork of [Juanitovh/CACTUS](https://github.com/Juanitovh/CACTUS) (MIT). Upstream is the reference
implementation and the thing to cite:

> Villarreal-Haro et al., *CACTUS: a computational framework for generating realistic white matter
> microstructure substrates*, Frontiers in Neuroinformatics (2023). doi:10.3389/fninf.2023.1208073

## Why fork rather than patch locally

The substrates generated here feed a published replay-pack bank, so the generator has to be **pinnable**:
a substrate card must be able to name the commit that produced its meshes. Before this fork, the
`cross45` and `cross90` crossing substrates had been built by a generator that existed only as an
**uncommitted working-tree change** — `git checkout .` would have destroyed it, and nothing recorded what
had actually run. That is the problem this fork solves first (commit 1 below).

Three of the fixes here are also on the critical path rather than conveniences: each one stops the
pipeline outright, and upstream is a single-maintainer academic project whose last commit is
2026-03-23, so waiting on review would block substrate generation indefinitely.

**The intent is to stay a thin delta**, so every change can be offered upstream as a small PR. Please
resist restructuring — in particular the memory behaviour described below is worked around
*operationally*, not by rewriting the growth step.

## Divergence from upstream

| commit | change | why |
|---|---|---|
| `bb1b6d0` | `sample_spherical`: `int()` the point count, use `standard_normal((n, ndim))` | `np.random.randn(n, ndim)` is unsupported inside `@jit(nopython=True)` and fails on a float count. **This patch built cross45 and cross90** and was previously uncommitted. |
| `75c3f30` | `check_meshes`: remove `missing_strands.append(i)` from the pool worker | `missing_strands` is a local of `main()`, so the worker raised `NameError` on the first absent mesh — making `-substep mesh -run_case missing` unusable on any un-meshed run. The value was already returned and collected by the caller. |
| `565bf0b` | drop six unused imports from `meta_grid` | `subprocess`, `skimage.measure`, `pyvista`, `matplotlib.pyplot` (x2), `cv2`, `nibabel` -- zero live uses. Measured 245 -> 160 MB and 1.14 -> 0.82 s per import, i.e. ~3 GB across the 36 workers the growth step spawns. |
| `509a321` | `handle_temperature`: membership test instead of `try/except` | **Ends the growth-step memory leak.** Every new dict key raised `KeyError` inside `@jit(nopython=True)`, and numba does not free memory on the exception unwind path -- 80.2 bytes per raise, measured. Peak RSS on a real cross90 strand **15.345 -> 1.887 GB**, output bit-identical to the substrate on disk. Also applied to the unused `handle_temperature_new`, which carries the same pattern. |
| `5597078` | `np.atleast_1d` around four `np.loadtxt` calls | `np.loadtxt` yields a 0-d array for a one-line file, so any resume that came down to a single outstanding strand died with `TypeError: iteration over a 0-d array`. Affects both `meta_grid` and `bake_mesh_pickle`. |

## Known upstream behaviour NOT changed here

**`grow -substep growth` leaks memory without bound** -- root cause now identified. Measured on cross45
before diagnosis: ~400 GB consumed per 14 minutes of work across ~40 workers at ~21 GB RSS each. When
memory runs out the pool does not crash, it **wedges**: the original cross45 attempt sat at strand 386
holding 129 GB in the parent having burned 4 CPU seconds in 2.9 hours.

*Cause* (`meta_grid.py:403-406`): `handle_temperature` inserts dict keys with
`try: d[k] += 1 / except: d[k] = 1` inside an `@jit(nopython=True)` function. Every NEW key raises
`KeyError`, and numba's runtime does not free memory on the exception unwind path -- a measured **80.2
bytes per raised exception**, never returned. The function runs once per voxel per iteration (348 M times
for one cross90 strand), so the leak tracks work done: **173.6 MB per M voxels**, about 2.4 TB over a full
409-strand run. A 4-line membership test in its place cuts peak RSS from 15.3 GB to 1.81 GB with
bit-identical output.

*Two claims previously in this file were wrong and are corrected here.* `meta_grid` does NOT allocate per
strand before doing work. And `n_cores` does not merely fail to control the worker count -- it is **never
plumbed to the growth step at all**: `meta_grid.py:882` hardcodes `cpu_count()/2` (36 on this box) and
`meta_grid` has no `-n_cores` option; only step 1's `grid_initialization.py` reads the config value.
Batching the strand list to 12 helped because `n_pool` follows `len(inputs)`, so it ran 12 leaking workers
instead of 36, and each batch was a fresh process that discarded the leak.

*The wedge*, verified: `multiprocessing.Pool.map` never notices a SIGKILLed worker, so the parent blocks
indefinitely at `meta_grid.py:916`. With no swap and `vm.overcommit_memory=0`, `np.zeros` succeeds
virtually and the OOM killer strikes on page-touch, so `MemoryError` is never raised and the `try/except`
around that allocation (`:703-707`) can never fire.

Handled operationally for now -- see `prod/CROSSING-NOTES.md` for the batched runners. Killing a pool can
leave a truncated `.npz`, so strand files must be validated before meshing; pool children are daemonic but
daemon cleanup runs in the parent's `atexit`, so `SIGKILL`ing the parent orphans them, hence the `setsid`
plus process-group kill in `grow_in_batches.sh`.

## Keeping up with upstream

```bash
git remote -v            # origin = dmrai-lab/CACTUS, upstream = Juanitovh/CACTUS
git fetch upstream && git log --oneline HEAD..upstream/main
```
