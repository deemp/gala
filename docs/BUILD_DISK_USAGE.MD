# Build disk usage

Bazel builds of this repo are large, and without some care they grow without
bound. This page explains where the space goes and what to do about it.

## Why it grows

Bazel keys its **output base** on the *path* of the workspace. Every git
worktree — `.claude/worktrees/*`, a scratch clone under `C:/tmp`, anything —
gets its own complete output base, and nothing reclaims it when the worktree is
deleted. A full build of this repo is roughly 9 GB, so a handful of abandoned
worktrees is tens of gigabytes of dead cache.

Two further multipliers apply *inside* each output base:

- **Extracted external repositories.** The pinned Go SDK unpacks to ~207 MB,
  once per output base. Bazel has no mechanism today for sharing extracted
  repositories between output bases — `--repository_cache` caches the
  *downloaded archive*, and the repo contents cache does not help either (see
  below).
- **Compiled output.** GALA's generated Go instantiates a large number of Go
  generics, so intermediate `.a` archives are much bigger than the source they
  came from — often by two orders of magnitude. The linker discards almost all
  of it, but Bazel retains every intermediate as a declared action output.

## What the repo does about it

### A pinned Bazel 9.2.0

`//.bazelversion` pins Bazel 9.2.0. The reason is **reproducibility, not disk**.

There is no `.bazelversion` drift: without a pin, Bazelisk resolves whatever is
latest, so the version CI builds with changes under you. And `MODULE.bazel.lock`
is lockFileVersion 28, which Bazel 8 cannot read — a directly installed Bazel 8
discards the lock and, under the default `--lockfile_mode=update`, **rewrites it
back to version 16**, so the file flip-flops depending on who built last and
nothing in CI catches it.

The pin requires [Bazelisk](https://github.com/bazelbuild/bazelisk), which reads
`.bazelversion`. A directly installed `bazel` ignores the file and keeps
whatever version it happens to be, so check `bazel --version`.

#### The repo contents cache does not save disk — measured

Bazel 9 enables a **repo contents cache** by default at
`{--repository_cache}/contents`, described as holding fetched repo directories
"shareable across workspaces". That phrasing is easy to misread, so to be
explicit: it means the *fetch result* is reusable, **not** that bytes are shared
on disk.

Measured — two identical scratch workspaces, same Bazel 9.2.0, `fetch --all` in
each:

| | |
|---|---|
| wsA `external/` | 8,250 MB (cold fetch, 390 s) |
| wsB `external/` | 8,251 MB (warm fetch, 162 s — 2.4× faster) |
| files hardlinked between them | **0** |
| the contents cache itself | **7,498 MB — a third full copy** |

The second workspace got its own complete copy and the cache *added* 7.5 GB on
top, so the net effect on disk is **worse**. Bazel issue
[#27913](https://github.com/bazelbuild/bazel/issues/27913), asking for exactly
this cross-output-base storage sharing, is still open.

If disk matters more than fetch time on your machine, the cache is something to
turn **off**, in `.bazelrc.user`:

```
common --repo_contents_cache=
```

(An empty value disables it. For the same reason, the flag being present from
Bazel 8.3 was never useful either — there it defaults to empty already.)

### `tools/bazel_gc.sh`

Reports every output base with its size and owning workspace, and flags the ones
whose workspace no longer exists:

```shell
tools/bazel_gc.sh                 # report only, largest first
tools/bazel_gc.sh --prune         # delete the orphaned ones (asks first)
tools/bazel_gc.sh --prune --yes   # ... without asking
```

The shared `install/` and `cache/` directories are never touched. Live output
bases are never touched. Only bases whose recorded workspace is gone are
eligible, and `--prune` confirms before deleting because that test is only as
good as the path recorded in the marker.

Set `BAZEL_OUTPUT_USER_ROOT` if you build with a custom `--output_user_root`.

## What you can do locally

### Delete an output base along with its worktree

`bazel_gc.sh` cleans up what already leaked; the way to stop new leaks is to
remove a worktree's output base when you remove the worktree. From inside the
worktree, before deleting it:

```shell
bazel clean --expunge
```

### Share a disk cache

`--disk_cache` is content-addressed and shared by every output base, so a
pruned base repopulates from it instead of recompiling. The path is
machine-specific, so it belongs in `.bazelrc.user` (git-ignored, pulled in by
the `try-import` at the end of `.bazelrc`) rather than in the checked-in
config:

```
build --disk_cache=/path/to/a/shared/bazel-disk-cache
```

Note that a disk cache buys rebuild *speed*, not space — it is what makes
pruning output bases cheap enough to do routinely. Budget for it separately and
trim it when it grows.

The setting that would buy *space* is `--remote_download_outputs=minimal`
("build without the bytes"), which stops Bazel materialising intermediate action
outputs into the output base at all. It is documented against a remote cache,
and whether it is honoured with only a `--disk_cache` is not something this repo
has established — measure before relying on it, and expect to need a local cache
server such as [bazel-remote](https://github.com/buchgr/bazel-remote) if it is
not. That is why it is not enabled by default here.

### Windows: enable Developer Mode

Without permission to create symlinks, Bazel materialises runfiles trees by
**copying**. Every test binary then exists in three copies, and shared tooling
such as `gala_test_runner.exe` is duplicated into every single test's runfiles
tree — several hundred megabytes per build, around 30% of an output base.

Enabling Developer Mode (Settings → System → For developers) lets Bazel use
symlinks instead. `--enable_runfiles` in `.bazelrc` is load-bearing and must
stay: without runfiles trees the test wrappers cannot find their runner and
every test fails with "The system cannot find the path specified".

## Things that do not work

- **Pointing several worktrees at one output base** via `startup --output_base`.
  Bazel writes a `DO_NOT_BUILD_HERE` marker naming the owning workspace and
  re-creates the base when a different workspace claims it, so every switch
  becomes a full rebuild.
- **`--noenable_runfiles`** on Windows, as above.
- **Sharing extracted external repos between output bases.** Bazel has no
  mechanism for it. `--repository_cache` caches downloads, not unpacked
  directories, and the repo contents cache is a fetch-time optimisation that
  costs disk rather than saving it (measured above).
