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

- **Extracted external repositories.** The pinned Go SDK unpacks to ~207 MB.
  Before Bazel 9 that extraction happened once per output base.
  `--repository_cache` only cached the *downloaded archive*, not the unpacked
  result.
- **Compiled output.** GALA's generated Go instantiates a large number of Go
  generics, so intermediate `.a` archives are much bigger than the source they
  came from — often by two orders of magnitude. The linker discards almost all
  of it, but Bazel retains every intermediate as a declared action output.

## What the repo does about it

### A pinned Bazel 9.2.0

`//.bazelversion` pins Bazel 9.2.0, for the **repo contents cache**: a store of
*extracted* repository directories shared across workspaces, so a pinned
toolchain is unpacked once per version for the whole machine rather than once
per output base.

The version matters more than it looks. The flag was added in Bazel 8.3, but
there it defaults to the empty string — and an empty string means *disabled*:

```
bazel 8.8.0:  --repo_contents_cache (a path; default: "")
              "An empty string as argument requests the repo contents cache to
               be disabled."

bazel 9.2.0:  --repo_contents_cache (a path; default: see description)
              "... otherwise the default of `{--repository_cache}/contents`"
```

So on 8.x you get the cache only if you pass `--repo_contents_cache=<path>`
explicitly; from 9.x it is on by default. We pin 9.2.0 and rely on the default.

This requires [Bazelisk](https://github.com/bazelbuild/bazelisk), which reads
`.bazelversion`. A directly installed `bazel` binary ignores the file and keeps
whatever version it happens to be, so check `bazel --version`.

Running a directly installed **Bazel 8** against this repo does more than miss
the benefit: `MODULE.bazel.lock` is lockFileVersion 28, which Bazel 8 cannot
read, so it discards the lock and — under the default `--lockfile_mode=update`
— rewrites it back to version 16. The file then flip-flops depending on who
built last, and nothing in CI catches it.

To confirm the cache is actually being used, look for a `contents/` directory
next to the download cache after a fetch:

```shell
ls "$(bazel info output_base)/../cache/repos/v1/"
# content_addressable  contents
```

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
- **`--repository_cache` alone** for the extraction cost. It caches downloads,
  not unpacked directories. That is what the repo contents cache adds.
