# GALA transpiler speed-up: third execution handoff

Date: 2026-09-25
Status: two additional allocation optimizations are implemented and pass all repository gates; no commit has been created.

This record continues `handoff-speed-up.md`, `handoff-speed-up-1.md`, and `handoff-speed-up-2.md`. The first handoff established the measurement protocol, the second recorded the accepted parser and transformer optimizations, and this handoff records the next inference and LSP-allocation reductions.

## Executive summary

Two low-risk improvements were added after the second handoff:

1. **Monomorphic Hindley-Milner fast paths** avoid recursively rebuilding type trees and schemes when the substitution is empty or a scheme has no quantified variables.
2. **LSP-only metadata is now opt-in** so ordinary CLI and batch transforms do not allocate variable maps, function-qualified keys, or lambda hint records that are immediately discarded.

Focused allocation results:

| Benchmark | Before | After | Result |
| --- | ---: | ---: | --- |
| `BenchmarkInferMonomorphicApplication` | 2,792 B/op, 55 allocs/op | 2,344 B/op, 39 allocs/op | 29.1% fewer allocations, 16.0% fewer bytes |
| `BenchmarkTypeEnvApplyEmpty` | 5,224 B/op, 103 allocs/op | 984 B/op, 4 allocs/op | 96.1% fewer allocations, 81.2% fewer bytes |
| `BenchmarkTransformNormalMetadata` | about 18,229 B/op, 506 allocs/op | about 17,826 B/op, 499 allocs/op | LSP-only allocation removed |
| `BenchmarkTransformLSPMetadata` | about 18,660 B/op, 510 allocs/op | about 18,660 B/op, 510 allocs/op | LSP behavior and cost preserved |

All 53 stdlib output hashes remained byte-identical. The full Bazel build, all 409 tests, the Nix smoke check, and `nix flake check` pass.

The corpus wall-clock comparison is not decision-quality evidence. A five-run old/new comparison showed a lower candidate median but a worse p95, while the harness grouped the binaries instead of alternating them. Treat the accepted evidence as the focused allocation reductions plus output identity, not as a new corpus wall-time speedup claim.

## Implemented improvements

### 1. Avoid no-op inference cloning

Changed:

- `internal/transpiler/infer/infer.go:23`
- `internal/transpiler/infer/infer.go:61`

`TypeEnv.Apply` now:

- preallocates the result map to the source environment size;
- shallow-copies the environment when the substitution is empty; and
- retains the existing scheme transformation path for non-empty substitutions.

The shallow copy is required. Returning the original environment would be incorrect because the `Let` branch adds bindings to the returned map.

`Inferer.instantiate` now returns a monomorphic scheme's type directly. Generic schemes still receive fresh type variables and continue through substitution.

This is safe because inference treats `Type` and `Scheme` values as immutable. Unification and substitution do not mutate their inputs.

Coverage and benchmarks were added in:

- `internal/transpiler/infer/infer_test.go:144`
- `internal/transpiler/infer/infer_test.go:167`

The existing polymorphic-let tests continue to prove that quantified variables receive fresh instantiations.

### 2. Skip LSP-only collection during ordinary transforms

Changed:

- `internal/transpiler/transformer/transformer.go:124`
- `internal/transpiler/transformer/transformer.go:149`
- `internal/transpiler/transformer/transformer.go:153`
- `internal/transpiler/transformer/declarations.go:615`
- `internal/transpiler/transformer/lambdas.go:93`

The public `Transform` and `TransformForLSP` methods now share a private `transform` method with an explicit `collectLSPMetadata` argument.

Normal transforms leave `lspVarTypes` and `lspLambdaParamHints` nil. Consequently:

- `recordLSPVarType` returns immediately;
- function-name scoping work is skipped;
- inferred lambda parameter hints are not constructed; and
- maps and slices allocated by an earlier LSP transform are released at normal-transform entry.

`TransformForLSP` initializes both collections before walking the tree and still returns partial metadata when transformation fails. This preserves the LSP behavior relied on by completion, hover, diagnostics, and inlay hints.

Regression coverage and benchmarks were added in:

- `internal/transpiler/transformer/lsp_scope_test.go:69`
- `internal/transpiler/transformer/lsp_scope_test.go:99`
- `internal/transpiler/transformer/lsp_scope_test.go:110`

The test pins all of the following:

- ordinary `Transform` does not retain LSP metadata;
- `TransformForLSP` still returns function-scoped variable types;
- `TransformForLSP` still returns inferred lambda parameter hints; and
- a normal transform after an LSP transform clears the metadata again.

## Measurement details

### Environment

Both before and after measurements used:

- host: Linux x86-64;
- CPU: Intel Core i7-1165G7;
- Go: `go1.26.7 linux/amd64`;
- Bazel: `9.2.0`;
- GOROOT: `/nix/store/4l04h8656as4i291mpcg38wz9m4k8acp-go-1.26.7/share/go`;
- `GOMAXPROCS=4`;
- `GOGC=300`;
- `GOMEMLIMIT=6GiB`; and
- a fresh isolated analyzer cache for every corpus repetition.

The binary under test was based on commit `471820eda02f7a39d662b10f95002d3f1e5cbd99` with the uncommitted changes described here.

### Focused commands

```sh
go test -run '^$' \
  -bench 'Benchmark(InferMonomorphicApplication|TypeEnvApplyEmpty)$' \
  -benchmem -count=5 \
  ./internal/transpiler/infer

go test -run '^$' \
  -bench '^BenchmarkTransform(Normal|LSP)Metadata$' \
  -benchmem -count=5 \
  ./internal/transpiler/transformer
```

`BenchmarkTypeEnvApplyEmpty` showed the clearest runtime effect, dropping from roughly 5.2–6.0 microseconds to roughly 1.1–1.7 microseconds per operation in these runs.

The monomorphic-application and transformer timings were noisy despite stable allocation counts. Do not quote their individual `ns/op` values as a statistically established speedup.

### Corpus artifacts

Initial three-run before/after artifacts:

- before: `/tmp/opencode/gala-speedup-next-baseline`
- candidate: `/tmp/opencode/gala-speedup-next-candidate`

These runs were separated by a substantial rebuild and did not retain a stable host-load relationship. The before median was 6.01 seconds and the candidate median was 8.44 seconds, but that result must not be interpreted as a regression or improvement from differently timed sessions.

A second five-run old/new comparison is stored at:

- `/tmp/opencode/gala-speedup-next-interleaved`

The directory name reflects the attempted comparison, but inspection showed two harness caveats:

1. both binaries were labeled `local` in `binaries.tsv` and `results.tsv`;
2. all five old-binary runs completed before all five candidate runs, so they were grouped rather than alternated.

Separating the first and second groups by the ordered binary manifest gives:

| Variant | Wall median | Wall p95 | RSS median | RSS p95 |
| --- | ---: | ---: | ---: | ---: |
| unchanged `471820ed` | 8.02 s | 8.25 s | 914,736 KiB | 944,412 KiB |
| candidate | 7.78 s | 9.86 s | 896,428 KiB | 959,220 KiB |

The candidate has a modestly lower median but worse p95 values. This run does not satisfy the handoff acceptance rule against a p95 regression and is not sufficiently controlled to establish a wall-time win. It does establish that the patch does not change generated output.

### Output identity

The candidate matched the unchanged baseline for all 53 selected stdlib inputs.

Comparison artifact:

- `/tmp/opencode/gala-speedup-next-candidate/baseline-output-comparison.tsv`

Every listed source path has identical baseline and candidate SHA-256 values.

The benchmark runner also reported no source-tree pollution:

- `/tmp/opencode/gala-speedup-next-candidate/source-pollution.txt`

## Validation completed

Passed focused Go tests:

```sh
go test -count=1 ./internal/transpiler/infer
go test -count=1 \
  -run 'Test(UnresolvedLocalIsStillRecordedAsABinding|TransformCollectsLSPMetadataOnlyForLSP)$' \
  ./internal/transpiler/transformer
```

Passed focused Bazel tests:

```sh
bazel test //internal/transpiler/infer:infer_test \
  --test_output=errors \
  --cache_test_results=no

bazel test //internal/transpiler/transformer:transformer_test \
  --test_output=errors \
  --cache_test_results=no \
  --test_filter='Test(UnresolvedLocalIsStillRecordedAsABinding|TransformCollectsLSPMetadataOnlyForLSP)$'

bazel test //internal/lsp:lsp_test \
  --test_output=errors \
  --cache_test_results=no \
  --test_filter='Test(Repro_InlayHintsOnEveryVal|InlayHints_Constructor|InlayHints_LambdaParamFromFieldChain)$'
```

Passed full Bazel build and test gates:

```sh
bazel build //... \
  --action_env=GOROOT="$GOROOT" \
  --action_env=PATH

bazel test //... \
  --test_output=errors \
  --verbose_failures \
  --cache_test_results=no \
  --action_env=GOROOT="$GOROOT" \
  --action_env=PATH
```

Results:

- 1,511 targets built successfully;
- 409 of 409 tests passed;
- the full transformer target passed in 114.1 seconds;
- the LSP target passed in 42.7 seconds; and
- the build target passed in 60.4 seconds.

Passed Nix gates:

```sh
nix build .#checks.x86_64-linux.smoke \
  --print-build-logs \
  --out-link /tmp/opencode/gala-speedup-next-smoke

nix flake check
```

Additional hygiene:

```sh
gofmt -w \
  internal/transpiler/infer/infer.go \
  internal/transpiler/infer/infer_test.go \
  internal/transpiler/transformer/declarations.go \
  internal/transpiler/transformer/lambdas.go \
  internal/transpiler/transformer/lsp_scope_test.go \
  internal/transpiler/transformer/transformer.go

git diff --check
```

The repository has no standalone lint or static-analysis target. The full Bazel build is the authoritative Go compile/typecheck gate; generated-Go formatting is covered by the transformer test suite.

## Files changed by this continuation

Performance code:

- `internal/transpiler/infer/infer.go`
- `internal/transpiler/transformer/declarations.go`
- `internal/transpiler/transformer/lambdas.go`
- `internal/transpiler/transformer/transformer.go`

Tests and benchmarks:

- `internal/transpiler/infer/infer_test.go`
- `internal/transpiler/transformer/lsp_scope_test.go`

Handoff:

- `handoff-speed-up-3.md`

## Unrelated working-tree state

Do not include or overwrite these pre-existing changes:

- modified `.gitignore`;
- untracked `handoff-language-features.md`;
- untracked `handoff-language-features-1.md`; and
- untracked `opencode.json`.

They are unrelated to this speed-up continuation and were preserved throughout.

No commit was created.

## Decisions

### Accepted

- **Monomorphic inference fast paths.** They remove stable, substantial allocation volume from the remaining inference hotspot without changing generic instantiation or environment-copy semantics.
- **Opt-in LSP metadata collection.** Normal compilation no longer pays for editor-only maps, qualified keys, or lambda hint records. The LSP allocation profile is unchanged and focused integration tests pass.
- **Focused benchmarks and regression coverage.** The allocation improvements are now measurable without relying on a noisy full-corpus wall-clock claim.

### Not accepted as evidence

- A universal corpus wall-time improvement. The available corpus runs are too noisy and not properly alternated.
- A p95 improvement. The grouped five-run candidate p95 regressed.
- A parser, analyzer, formatting, or GC-default change. This continuation did not touch those paths.

## Remaining work

### 1. Repair multi-binary benchmark labeling and ordering

Before using old/new corpus comparisons for decisions:

1. verify duplicate binaries of the same kind receive distinct labels;
2. prevent result and log paths from colliding;
3. alternate binary variants within each repetition;
4. preserve a stable randomized package order shared by paired variants; and
5. add a regression test or fixture for two binaries with the same kind.

The current `tools/bench_transpile.sh` should not be used for a formal A/B decision until this is fixed.

### 2. Re-run a decision-quality corpus comparison

After the harness fix, run at least nine randomized paired repetitions with:

- unchanged and candidate binaries in the same harness invocation;
- cold isolated application caches;
- separate timing and profiling passes;
- unchanged output identity checks; and
- median, p95, CPU, and RSS reported independently for each binary.

Do not accept the optimization on a median-only win if p95 or RSS materially regresses.

### 3. Continue transformer allocation work

The remaining measured transformer hotspot is still type-environment construction. The next low-risk candidates are:

- remove the dead per-file `strings.Split` that populates `sourceLines` in `internal/transpiler/transformer/transformer.go`;
- pre-size the environment and temporary collections in `buildTypeEnv`; and
- profile generic scheme conversion separately from monomorphic builtins and local functions.

These should be attempted one at a time with focused allocation benchmarks.

### 4. Re-profile before broader changes

A new candidate CPU and heap profile should confirm whether `buildTypeEnv`, resolver work, or analyzer parsing is now dominant. Do not start package-summary caching, output-pass reduction, GC changes, or broader parallelism from the old profile alone.

## Resume checklist

1. Check `git status` and preserve the unrelated files listed above.
2. Fix and test multi-binary labeling and paired ordering in `tools/bench_transpile.sh`.
3. Rebuild unchanged and candidate binaries from pinned commits/worktrees.
4. Run at least nine paired randomized cold-cache repetitions.
5. Compare output hashes for all 53 stdlib files.
6. Inspect phase, CPU, and heap profiles separately from timing runs.
7. Keep the inference and LSP changes only if correctness, p95, and RSS gates pass.
8. Consider the dead `sourceLines` split as the next isolated transformer improvement.
9. Run the full Bazel and Nix gates again before creating a commit.
