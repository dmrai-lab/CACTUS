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
| `5597078` | `np.atleast_1d` around four `np.loadtxt` calls | `np.loadtxt` yields a 0-d array for a one-line file, so any resume that came down to a single outstanding strand died with `TypeError: iteration over a 0-d array`. Affects both `meta_grid` and `bake_mesh_pickle`. |

## Known upstream behaviour NOT changed here

**`grow -substep growth` leaks memory without bound.** Measured on cross45: ~400 GB consumed per 14
minutes of work, spread over ~40 spawned workers at ~21 GB each; `n_cores` does not control the worker
count. When memory runs out the pool does not crash, it **wedges** — the original cross45 attempt sat at
strand 386 holding 129 GB in the parent having burned 4 CPU seconds in 2.9 hours.

This is left alone deliberately: fixing it means understanding the growth step's allocation pattern, which
is a much larger change than a thin delta allows. It is handled operationally instead — see
`prod/CROSSING-NOTES.md` for the batched runners that bound the exposure, and note that killing a pool can
leave a truncated `.npz`, so strand files must be validated before meshing.

Two further consequences of the same design, also unaddressed here: a from-scratch run hands the whole
missing list to `meta_grid`, which allocates per strand before doing any work (409 strands wedged it at
276 GB against 2 CPU seconds), and killing `meta_grid` leaves its pool children reparented to init still
holding their allocations.

## Keeping up with upstream

```bash
git remote -v            # origin = dmrai-lab/CACTUS, upstream = Juanitovh/CACTUS
git fetch upstream && git log --oneline HEAD..upstream/main
```
