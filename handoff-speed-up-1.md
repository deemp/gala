# GALA transpiler speed-up: execution handoff

Date: 2026-09-25
Status: Phase 0 measurement and instrumentation substantially complete; performance optimization is not yet decision-quality.

This file is the execution record for `handoff-speed-up.md`. The original plan remains the source of truth for the broader roadmap. No commit was created during this work.

## Executive summary

The first reproducible measurements are now available. On the 53-file, 19-package stdlib corpus, with an isolated application cache, `GOMAXPROCS=4`, `GOGC=300`, and `GOMEMLIMIT=6GiB`:

- A local batch transpilation took about 38–47 seconds depending on whether the pass was instrumented. The phase pass reported 44.137 seconds of batch wall time, 18.115 seconds in analysis, 13.718 seconds in parsing, and 11.700 seconds in transformation.
- The CPU profile identified ANTLR adaptive prediction/ATN simulation as the largest path: 37.74 seconds cumulative, 51.51% of samples. `runtime.mallocgc` accounted for 20.49 seconds cumulative, 27.97%, and `runtime.gcBgMarkWorker` accounted for 11.36 seconds, 15.50%.
- The heap profile recorded 8.24 GiB allocated during the pass. The largest allocation sources were ANTLR `NewATNConfig` (2.93 GiB), ANTLR `JMap.Put` (1.09 GiB), singleton prediction contexts (1.02 GiB), and transformer type-environment construction (about 1.25 GiB cumulative).
- The 750 MiB heap snapshot retained only 247.56 MiB in use. The large RSS is therefore dominated by transient allocation and GC pressure rather than one permanently retained package summary.
- Output post-processing is measurable but small in this corpus: generation was 304 ms and all line-directive phases together were about 285 ms across 53 files. It should not be the first optimization target.
- A released per-package run required 19 processes and 121.98 seconds aggregate in the one-pass comparison. A local bootstrap batch completed the same 53 inputs in 40.99 seconds. This is a useful architectural signal, but it is not a statistically valid speedup claim: it is one pass, the release binary is older, and the host was heavily loaded.
- Release, local, and bootstrap output manifests matched byte-for-byte for all 53 inputs after the harness was corrected to use relative source arguments and stage Go helper packages such as `go_interop`.

The evidence changes the priority order: parser prediction/allocation and transformer inference are the first optimization targets. Package-summary caching, formatting-pass reduction, and broad GC changes should wait for repeated measurements.

## Progress checklist

### Completed

- [x] Read the existing handoff and repository instructions.
- [x] Inspected the Nix, CLI, analyzer, transformer, generator, build, and profiler paths.
- [x] Used independent sub-agents for benchmark-harness research, instrumentation research, and baseline measurements.
- [x] Added `tools/bench_transpile.sh`, a standalone stdlib/fixture benchmark runner.
- [x] Added isolated cache, GC, process, ordering, manifest, output-hash, and source-pollution controls to the runner.
- [x] Repaired the empty `transpile-package` batch summary.
- [x] Added completion snapshots, repeated-label aggregation, deterministic file ordering, and writer-injected profiler reports.
- [x] Added post-processing phase timers for embed insertion and line-directive parsing, scanning, rewriting, and formatting.
- [x] Added batch summary plumbing to `gala_bootstrap` and the persistent worker.
- [x] Added top-level `gala build` phase profiling and CPU-profile startup/stop.
- [x] Clears the AST-keyed transformer expression cache at the start of each transform, preventing a reused transformer from retaining prior-file AST nodes.
- [x] Added focused profiler tests.
- [x] Ran focused Bazel tests and a successful stdlib release/local/bootstrap output comparison.
- [x] Collected separate phase, CPU, and heap profiles.

### In progress or not yet complete

- [x] Rebuild the binaries after the final transformer-cache change.
- [ ] Run the nine-repetition decision-quality baseline.
- [ ] Compare default GC against the tuned settings at one, four, and configured `GOMAXPROCS` values.
- [ ] Add a repeatable full-project transpiler-only `testing.B` benchmark and a before/after measurement for the transformer cache reset.
- [ ] Instrument parser cache reuse and analyzer duplicate parsing directly.
- [ ] Add explicit HM fallback counters/timers and resolver/import scan timers.
- [ ] Run the complete Bazel, Nix smoke, and flake validation suites.

## Environment and reproducibility

The latest full-corpus artifacts were produced with the following recorded environment. Each artifact's `run.env` is authoritative if it differs from this summary.

- Host: Linux x86-64, 4 physical cores / 8 logical CPUs, approximately 31 GiB RAM.
- Host Go: `go1.26.7 linux/amd64`.
- `GOROOT`: `/nix/store/4l04h8656as4i291mpcg38wz9m4k8acp-go-1.26.7/share/go`.
- Bazel: `9.2.0`.
- Nix: Determinate Nix 3.21.8, Nix 2.34.8.
- Measurement process: `GOMAXPROCS=4`, `GOGC=300`, `GOMEMLIMIT=6GiB`.
- Application caches: isolated per run; analyzer cache root was under the disposable staged source tree.
- OS page cache: shared and not dropped; this is explicitly not an OS-cold measurement.
- Go/Bazel version mismatch: Bazel-built binaries reported Go 1.25.5, while the host SDK used for type inference was Go 1.26.7.
- Working tree: dirty. Other concurrent work changed the Git index and added `handoff-language-features*.md` and `opencode.json`; those files are outside this speed-up work and must not be reverted.
- Latest full-run commit recorded by the runner: `05f027e37633bf2a6e34b5591a1be425560711bf` (`0.80.0-25-g05f027e3-dirty`).
- Earlier CPU artifact metadata recorded commit `b2250ca47fa0d6df6caa01369894b16e741c26aa`; the checkout changed during the session. Re-run the CPU profile after the final rebuild before using it for a final claim.

Observed binary hashes at the time of the runs:

```text
local Bazel gala:          c0b8456fee3135a3c7928c1c85a1a5488064d430a2980301cdbdc57066ff8d90
local Bazel bootstrap:     b847b9045ecf306f10d192a75019ac3e09171c797e5007862fcae39e0f172fcd
installed release gala:    10dd57e07bdd7874ac59a348ffce68d15bb6602fa25b7eaf38f5fc385201abae
```

The host was heavily loaded during measurements (load average approximately 9 on 8 logical CPUs). Treat all current timings as smoke/architecture evidence, not acceptance-quality medians or p95 values.

## Benchmark runner

Implementation: `tools/bench_transpile.sh:1`.

The runner:

- Parses the package list dynamically from `nix/gala.nix`.
- Includes all non-test `.gala` files in the listed stdlib directories and stages all listed package directories, including Go-only helper packages.
- Uses relative source arguments from the staged root so `//line` output hashes are stable.
- Uses disposable source, HOME, GALA_HOME, Go, module, temporary, and output directories.
- Removes staged `.gen.go` and `.gala` state for cold runs while retaining the cache for warm runs.
- Supports release per-package, local batch, bootstrap batch, GC modes, cold/warm cache modes, repetitions, ordering, filters, quick smoke, output baselines, and separate phase/CPU/heap profiles.
- Writes `manifest.tsv`, `results.tsv`, `aggregate.tsv`, `aggregate-summary.tsv`, `output-manifest.tsv`, `output-identity.tsv`, logs, and profile artifacts outside the repository.
- Fails on source-tree pollution and output mismatches unless explicitly allowed.

Important implementation fixes made during validation:

- Relative input paths are used for invocations; absolute paths remain in the manifest.
- Warm per-package priming retains the analyzer cache until the complete warm run finishes.
- Release binaries without `--scan` are rejected in batch mode with a clear per-package-mode message.
- Heap profile directories are created before invoking the watchdog.
- Phase profile stderr is copied to the advertised phase artifact.
- Aggregate reports sum all invocations in a repetition; they do not confuse a per-package median with total batch time.

Typical invocation:

```sh
bazel build //cmd/gala:gala //cmd/gala_bootstrap:gala_bootstrap

tools/bench_transpile.sh \
  --release-bin /home/eyjafjallajokull/.nix-profile/bin/gala \
  --local-bin bazel-bin/cmd/gala/gala_/gala \
  --bootstrap-bin bazel-bin/cmd/gala_bootstrap/gala_bootstrap_/gala_bootstrap \
  --goroot "$(go env GOROOT)" \
  --gomaxprocs 4 \
  --repetitions 9 \
  --mode both \
  --order randomized \
  --output /tmp/gala-speedup-decision-baseline
```

The release binary does not advertise `--scan`; use release in per-package mode and local/bootstrap in batch mode unless a release with scan support is supplied.

## Measurement artifacts

### Phase profile

Artifact: `/tmp/gala-speedup-phase-full/work/local-batch-tuned-cold/profiles/batch.artifacts/phase.txt`

The profile pass completed 53 files successfully. Its batch summary reported:

```text
Wall: 44.137s
File wall sum: 44.123s
analyze:                   18.115s  41.1%
parse:                     13.718s  31.1%
transform:                 11.700s  26.5%
generate:                   0.304s   0.7%
postprocess-line-format:    0.188s   0.4%
postprocess-line-parse:     0.077s   0.2%
postprocess-line-rewrite:   0.006s   0.0%
postprocess-line-scan:      0.014s   0.0%
```

The largest individual files were `collection_immutable/array.gala` (7.539s), `collection_mutable/array.gala` (3.833s), `concurrent/event_bus.gala` (3.338s), `validation/validated.gala` (2.721s), and `concurrent/future.gala` (2.616s).

### CPU profile

Artifact: `/tmp/gala-speedup-cpu/work/local-batch-tuned-cold/profiles/batch.artifacts/cpu.pprof`.

`go tool pprof -top -cum` reported:

- ANTLR `ParserATNSimulator.closureCheckingStopState`: 37.74s cumulative, 51.51%.
- `runtime.mallocgc`: 20.49s cumulative, 27.97%.
- `runtime.gcBgMarkWorker`: 11.36s cumulative, 15.50%.
- Transformer `getExprTypeName`: 10.89s cumulative, 14.86%.
- Transformer `buildTypeEnv`: 10.65s cumulative, 14.54%.
- Analyzer `parseFileCached`: 12.40s cumulative, 16.92%; this overlaps the parser path and must not be added to the ANTLR percentage.

These are cumulative CPU samples, not mutually exclusive wall-time percentages. The profile duration was 43.17s with 73.27s total samples (169.73% CPU), consistent with parallel sibling parsing.

### Heap profile

Artifacts: `/tmp/gala-speedup-heap-full/work/local-batch-tuned-cold/profiles/batch.artifacts/heap/heap_{250,500,750}MB.pb`.

The watchdog observed heap allocation crossings at approximately 330 MiB, 554 MiB, and 804 MiB. At the 750 MiB snapshot:

- `inuse_space` total: 247.56 MiB.
- Largest retained allocation: ANTLR `NewATNConfig`, 62.01 MiB.
- Other retained leaders: singleton prediction contexts (33 MiB), ANTLR `JMap.Put` (24.09 MiB), and common token objects (8.5 MiB).
- `alloc_space` total: 8,239.03 MiB.
- Largest cumulative allocation: ANTLR `NewATNConfig`, 2,932.77 MiB.
- Transformer `buildTypeEnv` cumulative allocation: about 1,251 MiB; `buildTypeResolver` about 398 MiB.

The low retained size relative to RSS supports transient allocation/GC pressure as the immediate memory problem. It does not prove that a future cache/summary design is unnecessary; it does show that retaining the current AST-keyed transformer cache is unlikely to be the main explanation for the observed RSS.

### Release/bootstrap comparison

Artifacts:

- `/tmp/gala-speedup-release-full`
- `/tmp/gala-speedup-bootstrap-full-2`
- `/tmp/gala-speedup-phase-full`

The corrected final comparison used the same relative source paths and staged Go helper packages:

```text
release per-package: 19 invocations, 53 inputs
aggregate wall:       121.98s
aggregate user CPU:   252.11s
aggregate system CPU: 13.20s
maximum process RSS:  1,142,932 KiB

bootstrap batch:       1 invocation, 53 inputs
wall:                  40.99s
user CPU:              70.72s
system CPU:            2.45s
maximum RSS:           1,369,160 KiB
```

Output hash comparison:

```text
release vs bootstrap: 53/53 matching output hashes
release vs local:     53/53 matching output hashes
```

The first bootstrap attempt exposed a harness omission: `go_interop` is a Go helper directory with no selected GALA input but is required to resolve `subprocess/async.gala`. The runner was corrected to stage every directory in the Nix stdlib list. The failed attempt is not a compiler result.

## Code changes landed in the working tree

These changes are present in the checkout but not committed.

### Profiler correctness

- `internal/transpiler/profiler/profiler.go:74` adds `ReportTo(io.Writer)` while preserving stderr wrappers.
- `internal/transpiler/profiler/profiler.go:125` snapshots completion before summary aggregation and adds repeated phase durations rather than overwriting labels.
- `internal/transpiler/profiler/profiler.go:195` reports file wall sum instead of mislabeling it as CPU time.
- `internal/transpiler/profiler/profiler_test.go:1` covers aggregation, deterministic ordering, completion snapshots, and writer injection.

### Per-file and batch profiling

- `internal/transpiler/transpiler.go:494` adds `TranspileWithSummary` without a global current-summary variable.
- `internal/transpiler/transpiler.go:681` adds line-directive leaf timers; embed insertion is timed separately.
- `cmd/gala/commands/transpile_package.go:112` now adds completed file profiles to its batch summary.
- `cmd/gala_bootstrap/main.go:103` reports bootstrap batch totals and summaries.
- `cmd/gala/commands/worker.go:386` reports worker batch summaries through the worker response writer.

### Build profiling

- `internal/build/builder.go:90` adds a nil-safe phase helper.
- `internal/build/builder.go:102` profiles workspace, stdlib, dependency, project, go.mod, target selection, and Go compilation stages.
- `cmd/gala/commands/build.go:81` starts/stops `GALA_CPUPROFILE` around `Builder.Build` and explicitly stops before the error exit path.

### Transformer lifetime

- `internal/transpiler/transformer/transformer.go:164` clears `exprTypeCache` at the start of every transform, or initializes it when absent. This releases AST keys from prior files when a transformer is reused by `gala build`.
- This change has not yet received a before/after allocation benchmark. Treat it as a correctness/memory-lifecycle improvement pending measurement, not as a proven speed win.

## Validation completed

Passed:

```text
bazel test //internal/transpiler/profiler:profiler_test
bazel test //cmd/gala/commands:commands_test
bazel test //cmd/gala_bootstrap:gala_bootstrap_test
bazel test //internal/build:build_test
bazel build //cmd/gala:gala //cmd/gala_bootstrap:gala_bootstrap
bash -n tools/bench_transpile.sh
```

The combined initial build-test invocation hit the 120-second tool timeout while Bazel was still building dependencies. The target was rerun alone with a longer timeout and passed in 65.2 seconds. A later focused transformer test invocation was user-aborted during grammar generation at about 24 seconds; it did not produce a test failure and must be rerun.

Not yet completed:

- Full `bazel test //...`.
- Full `bazel test //internal/transpiler/...` after the final edits.
- `nix build .#checks.x86_64-linux.smoke --print-build-logs`.
- `nix flake check`.
- A post-cache-reset benchmark and output-hash comparison.
- Race-enabled tests for any future analyzer/transformer parallelism.

## Prioritized remaining work

### 1. Establish a decision-quality baseline

Run the corrected runner after rebuilding both local binaries. Use nine or eleven repetitions, randomized complete-mode order, and separate timing/profile passes. Record median and p95 for:

1. release per-package;
2. local per-package;
3. local `--scan` batch;
4. bootstrap batch;
5. cold and warm application cache;
6. default GC and tuned GC;
7. `GOMAXPROCS=1`, `4`, and the configured runner value.

Do not use the current single-pass values as a release decision.

### 2. Validate the transformer cache reset

Add a focused `testing.B` benchmark for a reused transformer across a multi-file project. Compare:

- retained heap/RSS;
- allocations per file;
- CPU and wall time;
- byte-identical generated output.

Keep the reset if it reduces retained memory without a meaningful regression. If a fresh transformer is simpler and equally correct, prefer that over adding a new cache policy.

### 3. Instrument parser duplication

The CPU profile shows parser cost both through analyzer `parseFileCached` and the transpiler pipeline. Add counters for:

- parse calls by source path;
- parse-cache hits/misses;
- parse tree ownership;
- repeated sibling/import parses;
- bytes parsed per process.

Only then consider sharing parse trees or introducing a package parse snapshot. The trees are mutable and currently have lifecycle assumptions; do not cache them without ownership tests.

### 4. Instrument transformer inference and resolver work

Add explicit counters/timers for:

- `inferExprType` and `inferIfType` calls;
- HM fallback queries;
- `buildTypeEnv` calls and estimated environment size;
- generic scheme conversion;
- resolver/import filesystem scans;
- `AnalyzeGoPackage`/`AnalyzeGoFiles` cache hits and misses.

The existing profile already shows `buildTypeEnv` and `getExprTypeName` as material; the next step is to distinguish necessary repeated inference from redundant environment reconstruction.

### 5. Measure GC tuning on the full build path

`transpile-package` already applies the existing GC helper, but `gala build` does not. Measure a copied project under:

- default `GOGC=100` and no memory limit;
- `GOGC=300`, `GOMEMLIMIT=6GiB`;
- one and four workers/procs.

Only apply the helper to build/run/test entry points if wall time improves without violating the measured 4-vCPU/16-GiB RSS budget.

### 6. Finish build-level measurement

The new build phase timers cover top-level stages. Add focused sub-phase timing for project discovery, source hashing, cache check, file reads, non-GALA copy, embed copy, import rewrite, `go mod tidy`, and `go build`. Keep child-process wall time separate from in-process CPU samples.

### 7. Complete correctness and release gates

Before claiming an optimization:

- compare generated bytes across release, local, bootstrap, and before/after runs;
- retain diagnostic ordering and source locations;
- run focused cache/replacement tests;
- run full Bazel, Nix smoke, and flake checks;
- run race tests before any concurrency change.

## Current recommendation

Do not begin with output-pass reduction or package-summary concurrency. The measured evidence supports this order:

1. parser prediction/allocation reduction;
2. transformer inference environment/repeated schema work;
3. analyzer parse/import memoization;
4. source/I/O and tidy improvements;
5. package summaries;
6. formatting/output passes;
7. broader parallelism.

Keep all profiling disabled in normal operation. The landed instrumentation is intended to be zero-cost when `GALA_PROFILE` is unset; the benchmark harness must continue to keep pprof and heap passes separate from timing passes.

## Addendum — final validation pass

- `bazel build //cmd/gala:gala //cmd/gala_bootstrap:gala_bootstrap` passed after the transformer-cache change.
- The four non-corpus relevant targets passed together: `commands_test`, `gala_bootstrap_test`, `build_test`, and `profiler_test`.
- The focused transformer test, including `TestExprTypeCacheReset`, passed.
- The full transformer corpus target was still running when the 600-second command timeout interrupted it; no failure was reported. It remains a required gate.
- The repository-wide `bazel build //...` typecheck attempt was intentionally stopped at the user's request after 15 seconds; it was not a reported build failure and remains deferred.
- The post-change local batch smoke at `/tmp/gala-speedup-local-postcache` completed 53/53 files in 29.25s wall, 52.19s user, 1.88s system, and 1,507,896 KiB maximum RSS. Its output hashes matched the release manifest for all 53 files. This is not comparable to the earlier one-pass timings because host load and cache state varied; it is not evidence that the cache reset caused a speedup.
- The runner's aggregate smoke was rerun after fixing header handling; `aggregate-summary.tsv` now contains only data rows and reports summed per-repetition resources.
- `handoff-speed-up.md` contains a short progress pointer to this detailed execution record.

## Resume checklist

1. Check `git status` and preserve unrelated concurrent files.
2. Rebuild `//cmd/gala:gala` and `//cmd/gala_bootstrap:gala_bootstrap`.
3. Run `bash -n tools/bench_transpile.sh`.
4. Run a one-repetition local/batch smoke and inspect `aggregate-summary.tsv`.
5. Run the nine-repetition decision baseline.
6. Compare all output hashes before accepting any performance result.
7. Rerun the focused transformer test that was interrupted.
8. Run the full authoritative suites.
9. Update this file with final medians, p95 values, output identity, and accepted/rejected optimizations.
