# Stage-0 bootstrap pin

The stdlib is written in GALA, so compiling it needs a working GALA
transpiler. Building that transpiler from the working tree would recreate
the dependency cycle, so the build uses a **stage-0 compiler built from a
pinned, already-landed revision** of the repo.

The pin lives in `MODULE.bazel` in a marked block:

```starlark
# BEGIN gala_bootstrap_src (managed by tools/bootstrap/bump.sh)
# repo: <owner>/<name>
# rev: <40-hex>
# nix-hash: sha256-<base64>
http_archive(name = "gala_bootstrap_src", ...)
# END gala_bootstrap_src
```

- **Bazel** (`@gala_bootstrap_src`) builds the pinned tree's
  `//cmd/gala_bootstrap:gala_bootstrap` and uses it as the bootstrap
  toolchain, unless `--define=gala_bootstrap=local` selects the working
  tree instead.
- **Nix** (`nix/gala.nix`) parses `# repo`, `# rev`, and `# nix-hash` and
  builds the same pinned chain with `fetchFromGitHub`.

Both readers get the revision from the same block, and
`tools/bootstrap/bump.sh` is its only writer. The `# repo` line exists so
the pin can temporarily point at a fork (a PR branch that has landed the
prerequisites but is not merged upstream yet); it defaults to
`martianoff/gala`.

## Bumping

```sh
tools/bootstrap/bump.sh [--repo owner/name] <40-hex-commit>
```

The script fetches the archive, computes the `http_archive` sha256 and the
`fetchFromGitHub` (unpacked) SRI hash, rewrites the marked block, and prints
the verification steps:

1. `bazel build @gala_bootstrap_src//cmd/gala_bootstrap:gala_bootstrap`
2. `nix build .#gala`
3. `tools/bootstrap/fixpoint.sh`

The fixpoint check compares the stdlib Go emitted by the pinned stage-0
compiler with the one emitted by the working tree's compiler. If they
differ, either the change is unintended (fix it) or the compiler changed
the generated code (bump the pin to a commit containing the change).

## Reachability

- Pin only commits that remain reachable in the target repo.
- The repo merges PRs with merge commits, so a PR's commits stay reachable
  as second parents. **Do not squash-merge a PR whose commits are pinned.**
- Right after a merge, bump the pin to the merge commit (and, if the pin
  was on a fork, switch `--repo` back to `martianoff/gala`).

## Minimum capabilities of a pinned revision

`nix/gala.nix` needs the pinned tree to build `cmd/gala_bootstrap` with
batch mode (`--inputs/--outputs`). Bazel's fixpoint check additionally uses
the local `gala transpile-package --scan`. A revision older than those
changes fails the build loudly rather than producing wrong output.

## Phase 0 benchmark (same host, 8 vCPU)

Timing the 52 stdlib `.gala` files, `internal/stdlib/BUILD.bazel` targets,
`GOROOT` from the local Go SDK, three iterations each:

| mode | wall (median) | max RSS |
|---|---|---|
| `gala_bootstrap --inputs/--outputs`, default GC | 32.3 s | ~470 MB |
| `gala_bootstrap --inputs/--outputs`, `GOGC=300 GOMEMLIMIT=6GiB` | 26.3 s | ~900 MB |
| `gala transpile-package --scan` (single process, tuned GC) | 27.5 s | ~950 MB |

All three modes produced **byte-identical** `.gen.go` output
(`diff -r`). The tuned bootstrap is within noise of the full `gala` path,
so Nix uses the pinned `gala_bootstrap` for the local stdlib transpile
(cheaper, no embedded-stdlib copy needed) and keeps the pinned full `gala`
only as the `GOCACHE` seed for the final build.

The seed adds ~234 MB to the Nix store. On the benchmark host it turns a
Go-only `gala` rebuild from ~34 s (cold `GOCACHE`) into ~2.5 s, and a stdlib
edit from ~72 s into ~60 s (the transpile dominates), so it is kept.
