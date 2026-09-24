# Handoff: GALA transpiler speed-up plan

## Objective

Determine where transpilation time is actually spent, then make the highest-confidence improvements without changing generated programs or diagnostics.

The investigation covers both paths that matter:

1. The Nix build of Gala itself, especially the stdlib transpilation performed by `nix/gala.nix`.
2. End-to-end project transpilation through `gala build`, `gala run`, `gala test`, `gala transpile`, and `gala transpile-package`.

The first deliverable is a reproducible measurement report. Code changes are gated on that report so that apparent wins are not caused by cache state, process startup, or the Go compiler.

## Current architecture

The normal Nix package builds the CLI from the working tree and transpiles the stdlib with the released Gala binary. The local escape hatch builds `cmd/gala_bootstrap` from the tree and transpiles all selected stdlib inputs in one batch. The relevant package outputs are declared in `flake.nix:35-40`.

The standard-library transpilation derivation is `localTranspiled` in `nix/gala.nix:245-330`:

- Release mode makes one `gala transpile-package` invocation per stdlib package.
- Local-bootstrap mode makes one `gala_bootstrap --inputs/--outputs` invocation for all packages.
- Both modes exclude `*_test.gala` from the transpilation inputs.
- Only the files required by `internal/stdlib/BUILD.bazel` are staged into the final output.

The direct transpiler pipeline is:

```text
GALA text
  -> ANTLR parse tree and doc comments
  -> RichAST and package metadata
  -> Go AST transformation
  -> Go AST printing and formatting
  -> embed and //line post-processing
  -> generated Go
```

`internal/transpiler/transpiler.go:489-554` is the orchestration point. The current phase profiler labels `parse`, `analyze`, `transform`, and `generate`; embed and line-directive post-processing currently occur after the `generate` timer, so their cost is not represented accurately.

`gala build` is a different orchestration path. `internal/build/builder.go:523-668` discovers all project `.gala` files, groups siblings by directory, and transpiles them in a loop with one `BatchAnalyzer`. It reads the source files again after hashing them, copies non-GALA files, rewrites imports, and later invokes Go tooling.

## Existing evidence and likely hotspots

The following are ranked hypotheses, not current measurements. Each must be confirmed with the protocol below.

### 1. Repeated package and sibling analysis

`internal/transpiler/analyzer/analyzer.go:1528-1557` extracts full metadata from all siblings for every target file. `analyzePackage` at `analyzer.go:2675-2945` parses candidates concurrently but runs the semantic `Analyze` calls serially because the analyzer has mutable per-call state.

For a package with N files, the remaining metadata and validation work can approach quadratic behavior even though parse results are cached. The most suspicious repeated operations are:

- Full sibling metadata extraction.
- Reconstructing merged symbol and qualifier indexes.
- Undefined-symbol checking at `internal/transpiler/analyzer/undefined_symbol.go:303-337`.
- Reconstructing transitive package metadata for each file.

The first optimization target should be an immutable package summary that is built once per package revision and reused by each file-specific analysis.

### 2. Allocation and garbage collection

The analyzer is allocation-heavy: ANTLR parse trees, maps, `RichAST` objects, merged metadata, and type-inference environments all contribute. A prior apex-shaped profile recorded in the codebase attributed roughly 44% of cumulative CPU samples to GC work. That measurement is historical and must not be treated as the current percentage.

`cmd/gala/commands/worker.go:28-56` sets `GOGC=300` and a 6 GiB memory limit for worker and transpile paths. `gala build` does not call that tuning helper (`cmd/gala/commands/build.go:49-92`), so the same source can have materially different allocation behavior depending on the entry point.

Measure GC time, allocation volume, peak RSS, and wall time before changing defaults. A GC improvement that doubles RSS may be unacceptable on a 4-vCPU/16-GiB runner.

### 3. Transformer lifetime and inference work

`internal/transpiler/transformer/transformer.go:138-195` resets most per-file state but does not reset `exprTypeCache`. `internal/build/builder.go:571-585` creates one transformer and reuses it across all files, while `cmd/gala/commands/transpile_package.go:141-145` creates a fresh transformer for each file.

This can retain AST nodes and inferred types for the entire project. The first safe experiment is to clear the expression cache at the start of each transform or use a fresh transformer per file, then compare CPU, allocations, and output.

Hindley-Milner fallback is another likely hotspot when manual inference cannot resolve an expression:

- `internal/transpiler/transformer/bridge.go:188-280` rebuilds a type environment for every fallback query.
- `internal/transpiler/infer/infer.go:160-174` copies environments during application.
- Generic function schemes are repeatedly converted from `RichAST` metadata.

This path should be instrumented separately from ordinary transform time rather than assumed to dominate every file.

### 4. Output formatting and source-map rewriting

The generator currently performs `format.Node` and then `format.Source` (`internal/transpiler/generator/generator.go:50-58`). `insertLineDirectives` then parses the formatted Go, walks its AST, rewrites markers, and formats the result again (`internal/transpiler/transpiler.go:661-767`).

Large generated files can therefore pay several full-buffer parse, print, split, join, and format passes. The current profiler does not cover all of this work. Only optimize this after adding explicit timers for:

- AST generation.
- Initial formatting.
- Embed-directive insertion.
- Line-directive parsing and rewriting.
- Final formatting.

### 5. Filesystem and child-process work outside the transpiler

A full `gala build` can be dominated by work outside semantic analysis:

- Source hashing reads every `.gala` file, followed by another read during transpilation (`internal/build/builder.go:459-498` and `598-617`).
- Non-GALA file copying walks the project tree (`internal/build/builder.go:651-655` and `deptranspiler.go`).
- Import rewriting rereads generated Go files (`internal/build/builder.go:963-1063`).
- `go mod tidy` and `go build` are child processes and do not appear in the in-process CPU profile.
- `generateGoMod` compares generated text with the tidied file and may rerun tidy unnecessarily (`internal/build/builder.go:1126-1188`).

Measure these separately from transpiler CPU. A faster transpiler is not useful if `go build` or `go mod tidy` dominates the user-visible command.

## Measurement protocol

### 1. Establish the toolchain

Record, rather than assume, the following for every run:

- Git commit and working-tree state.
- Gala version and compiler binary hash.
- Go version and `GOROOT`.
- Bazel version.
- Nixpkgs revision and build platform.
- `GOMAXPROCS`, `GOGC`, and `GOMEMLIMIT`.
- Whether the analyzer cache, Go cache, Bazel cache, and OS page cache are warm.
- Maximum resident set size.

Use temporary output locations so the repository is not polluted:

```sh
nix build .#gala --out-link /tmp/gala-result --print-build-logs
nix build .#gala-local --out-link /tmp/gala-local-result --print-build-logs
```

The normal release package is the production comparison. The local package is required for grammar/codegen work and exposes the batch-bootstrap path.

### 2. Build the benchmark corpus

Use the same package list and input-selection rule as `nix/gala.nix:116-138` and `245-330`: all non-test `.gala` files in the selected stdlib package directories. The current corpus is approximately 53 files across 19 packages; the exact manifest must be generated at benchmark time rather than copied from an older handoff.

Record a manifest containing:

- Absolute input path.
- SHA-256 and byte count.
- Package directory.
- Declared package name.
- Search-path order.
- `GOROOT`.
- Output path and output SHA-256.

Use these tiers:

| Tier | Fixture | Purpose |
|---|---|---|
| Floor | `examples/hello.gala` | Process, parser, and generator baseline |
| Small | `examples/language_ergonomics.gala` | Imports, inference, lambdas, and matching |
| Medium | `examples/kvstore.gala` | Sealed types, generics, and cross-package resolution |
| Large | `stream/stream.gala` | Large single-file transform and formatting |
| Codegen stress | `collection_immutable/array.gala` | Large generics and Go interop |
| Multi-file | `examples/multifile_lib_regress` | Sibling packages and cross-file metadata |
| Production batch | All selected non-test stdlib files | Nix/release/bootstrap comparison |
| Broad sweep | Top-level `examples/*.gala` | Correctness and pathological-case discovery |

The broad sweep is not a single timing number. Use it to identify outliers, then add any slow shape to a durable benchmark if it represents a real workload.

### 3. Compare execution modes

At minimum, measure:

1. Released `gala transpile-package`, one invocation per stdlib package.
2. Local `gala_bootstrap --inputs/--outputs` batch mode.
3. Local `gala transpile-package --scan`, if the built binary supports `--scan`.
4. Default GC.
5. `GOGC=300 GOMEMLIMIT=6GiB`.
6. Fresh process with empty analyzer cache.
7. Fresh process with warm on-disk analyzer cache.
8. Same process with warm in-memory `BatchAnalyzer` state.

The release binary currently used by the flake does not support `--scan`; do not assume that the local and release command surfaces are identical.

For a stable benchmark, run each timing pass without CPU or heap profiling. Run profiling as a separate pass because pprof and heap-band sampling change the result.

### 4. Time and resource capture

Use `/usr/bin/time -v` or an equivalent tool for every direct invocation. Capture:

- Elapsed wall time.
- User and system CPU time.
- Maximum RSS.
- Exit status.
- Output hash.
- Cache generation and compiler hash.

Use at least five repetitions for a quick comparison and preferably nine or eleven randomized-order repetitions for a decision-quality baseline. Report median and p95, not only the fastest run. Label OS page-cache state separately from application-cache state.

For direct CLI runs, use a temporary working directory and temporary `HOME`, `GALA_HOME`, `GOCACHE`, and `GOMODCACHE` locations. The analyzer cache is discovered relative to project/cwd state, so running from the repository root can accidentally reuse `.gala/cache`.

Example shape:

```sh
tmp=/tmp/gala-transpile-bench
mkdir -p "$tmp/run" "$tmp/home" "$tmp/gala-home" "$tmp/gocache" "$tmp/gomodcache"
cd "$tmp/run"
LC_ALL=C HOME="$tmp/home" GALA_HOME="$tmp/gala-home" \
  GOCACHE="$tmp/gocache" GOMODCACHE="$tmp/gomodcache" \
  /usr/bin/time -v /tmp/gala-result/bin/gala transpile-package \
    --inputs "$tmp/inputs.csv" \
    --outputs "$tmp/outputs.csv" \
    --search /path/to/gala \
    --goroot /path/to/go
```

Do not delete the user's shared `.gala`, Go, Bazel, or Nix caches to create a cold run. Use isolated temporary locations or a disposable environment.

### 5. Phase and CPU profiling

For per-file phase timing:

```sh
GALA_PROFILE=1 /tmp/gala-result/bin/gala transpile-package ...
```

For a CPU profile, use a separate output file per run:

```sh
GALA_CPUPROFILE=/tmp/gala.pprof \
  /tmp/gala-result/bin/gala transpile-package ...
go tool pprof -top -cum /tmp/gala.pprof
```

For heap pressure:

```sh
GALA_HEAP_DUMP_DIR=/tmp/gala-heaps \
GALA_HEAP_DUMP_BAND_MB=250 \
  /tmp/gala-result/bin/gala transpile-package ...
```

Use `go tool pprof -top`, `-tree`, and `-inuse_space`/`-alloc_space` views. A useful report must identify both the hottest call paths and the largest retained or allocated data structures.

There is a known measurement gap: `transpile-package` creates a `profiler.Summary` but does not add per-file profilers to it (`cmd/gala/commands/transpile_package.go:112-169`; `internal/transpiler/profiler/profiler.go:86-129`). The batch summary may therefore report zero files even though individual per-file logs are present. Fix or bypass this before treating batch summary output as authoritative.

`gala build` also needs a profiling entry point if the goal includes full project builds. The current build command does not start the CPU profile helper used by the direct transpile command, and the in-process profile cannot include `go mod tidy` or `go build` child CPU.

### 6. Existing benchmark and profile targets

Use the checked-in synthetic benchmark as a regression guard:

```sh
bazel test //internal/build:build_test \
  --test_output=all \
  --cache_test_results=no \
  --test_arg=-test.bench=Transpile_ParallelSibling \
  --test_arg=-test.benchtime=5x
```

Use the apex-shaped test to inspect transitive-package behavior:

```sh
bazel test //internal/build:build_test \
  --test_output=all \
  --cache_test_results=no \
  --test_arg=-test.run=TestTranspile_ApexShape \
  --test_arg=-test.cpuprofile=/tmp/apex.pprof \
  --test_arg=-test.v
go tool pprof -top -cum /tmp/apex.pprof
```

The synthetic test currently enforces loose 8-second cold and 4-second warm budgets. Treat those as regression thresholds, not as evidence that the production stdlib workload is fast.

## Optimization phases

### Phase 0: Instrumentation and benchmark harness

Make no semantic changes until the first report is complete.

- Add a reproducible benchmark script or test harness for the stdlib manifest and representative fixtures.
- Record output hashes and assert byte identity between release, bootstrap, and before/after runs.
- Add explicit timers around output post-processing, resolver/source scans, undefined-symbol indexing, and HM fallback.
- Add CPU/heap/phase output to the `gala build` path without changing normal output.
- Fix or clearly bypass the empty batch-summary behavior.
- Add a `testing.B` benchmark for the full transpiler-only portion of `Builder.Build`; exclude Go compilation from that benchmark and measure it separately.

Gate: a report that ranks at least the top three costs by wall time, CPU samples, and allocation/heap data.

### Phase 1: Low-risk allocation and entry-point fixes

These changes should be small and independently reversible:

- Apply the existing GC tuning helper to build/run/test entry points, preserving user-provided environment overrides.
- Reset or replace transformer state per file so `exprTypeCache` and other AST-keyed maps do not retain an entire project.
- Avoid repeated `AnalyzeGoPackage`, `AnalyzeGoFiles`, and resolver filesystem scans by introducing correctly keyed per-analyzer caches.
- Remove eager or repeated binary/cache initialization when a command does not need analysis, if profiling shows startup cost.

Validate output identity, diagnostic ordering, and peak RSS after each change.

### Phase 2: Package-level analysis summary

Build one immutable summary for each package revision containing:

- Package name and declaration indexes.
- Own type/function/method metadata.
- Direct GALA import edges.
- Go exports and Go type information.
- Package-level values and other symbols needed by file checks.

Then run file-specific work against the summary. Preserve per-file import sets, source positions, undefined-symbol eligibility, and diagnostics; do not share a mutable `galaAnalyzer` across goroutines.

The target is to remove repeated full sibling walks and repeated merged-index construction while retaining the current own-only cache projection and transitive dependency invalidation.

### Phase 3: I/O and incremental-build improvements

Measure before implementing:

- Read source bytes once and reuse them for hashing and transpilation.
- Narrow non-GALA copying to files required by the generated module and embeds.
- Collect embed requirements during generation instead of rescanning generated text.
- Determine whether `go mod tidy` reruns on unchanged projects because generated text differs from tidied text.
- If a separate tidy input hash is introduced, include all inputs that can change the result and preserve offline behavior.

Do not weaken cache invalidation for local replacement dependencies. Any change to the dependency hash must include replacement contents or explicitly document why they cannot affect output.

### Phase 4: Reduce redundant output passes

Only after Phase 0 proves output post-processing is material:

- Prefer canonical import construction in the AST.
- Attach source-map information structurally where feasible.
- Reduce the number of full `format.Source`/parse/split/join passes.
- Preserve exact `//line` placement, gofmt idempotence, generated headers, embed directives, and error behavior for unparseable output.

Every output change must be checked against byte-identical generated files and existing formatting tests.

### Phase 5: Parallelism

Sibling parsing is already parallel. Do not assume the full analyzer is safe for concurrent `Analyze` calls: it contains mutable per-call state.

The safe progression is:

1. Build immutable package/dependency snapshots.
2. Analyze independent packages concurrently after dependency discovery.
3. Transform independent files concurrently with fresh transformer state.
4. Use one bounded worker pool rather than nested pools.
5. Keep cache writes atomic and deterministic.

Measure contention with the existing four-action diagnostic and compare one worker, four workers, and the configured `GOMAXPROCS` value. A speedup on an idle machine is not sufficient if it regresses small CI runners or increases peak RSS.

## Expected implementation order

1. Instrumentation and corpus benchmark.
2. GC tuning and transformer-lifecycle fix.
3. Resolver/Go metadata memoization.
4. Immutable package summaries.
5. Source/I/O and tidy-cache improvements.
6. Output-pass reduction.
7. Package-level concurrency.

This order starts with measurements, takes low-risk wins first, and postpones invasive concurrency and formatting changes until their cost is demonstrated.

## Correctness and regression requirements

Every optimization must preserve:

- Generated Go byte identity for unchanged inputs, except for explicitly intended formatting changes.
- GALA diagnostics, source locations, duplicate-symbol behavior, and import-discipline checks.
- Undefined-symbol behavior and its stand-down conditions.
- Type inference and generic substitution.
- Go source-map line directives and stack-trace behavior.
- Embed directive placement.
- Bazel and Nix build parity.
- Offline `go mod tidy` behavior where currently supported.

Run the focused checks first, then the full authoritative suites:

```sh
bazel test //internal/build:build_test --test_output=all --cache_test_results=no
bazel test //internal/transpiler/... --test_output=errors --cache_test_results=no
bazel test //... --test_output=errors --verbose_failures
nix build .#checks.x86_64-linux.smoke --print-build-logs
nix flake check
```

Do not regenerate or edit `internal/parser/grammar/*.go`; those files are generated.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| GC tuning improves speed but exhausts RAM | Report RSS across worker counts and memory limits; cap the default based on measured CI headroom |
| Shared package summary changes diagnostics | Keep file-specific state separate and add fixture tests for sibling imports, duplicate declarations, and undefined symbols |
| Analyzer concurrency exposes mutable-state races | Parallelize only immutable snapshots first; use race-enabled focused tests before expanding scope |
| Cache key misses source changes | Treat cache correctness as a release blocker; test local replacements and dependency edits |
| Output optimization breaks line maps | Require byte/golden comparison and stack-trace/source-map regression tests |
| Benchmark is dominated by startup or Go compilation | Report transpiler-only and full-build timings separately |
| pprof changes the workload | Use separate timing and profiling passes |

## Acceptance criteria

The speed-up work is complete when:

- A checked-in or reproducible benchmark can regenerate the stdlib and representative fixture results.
- Every reported timing includes cache state, toolchain, repetitions, wall time, CPU time, and RSS.
- The top three costs are supported by CPU, phase, and allocation evidence.
- Any optimization has a before/after comparison with identical generated output or an explicitly documented output change.
- The full Bazel suite, Nix smoke check, and relevant transpiler tests pass.
- No new global mutable analyzer state or unsynchronized cache access is introduced.
- The final handoff records which optimizations landed, which were rejected, and the remaining bottlenecks.

No performance claim should be accepted from a single cached Nix invocation or a single profiler run.

## Execution progress — 2026-09-25

Phase 0 measurement and instrumentation is substantially complete. The detailed execution record, measured artifacts, landed changes, validation results, and remaining work are in `handoff-speed-up-1.md`.

Key findings so far: ANTLR prediction/allocation and transformer inference are the leading costs; output post-processing is below 1.2% of the measured full-corpus phase total; release, local, and bootstrap output hashes match for all 53 current stdlib inputs. Measurements remain smoke-quality until the planned repeated, randomized baseline is rerun.
