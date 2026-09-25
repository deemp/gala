# GALA transpiler speed-up: fourth execution handoff

Date: 2026-09-26
Status: three changes are implemented, pass all repository gates, and are committed on the `speed-up` branch together with this handoff.

This record continues `handoff-speed-up.md`, `handoff-speed-up-1.md`, `handoff-speed-up-2.md`, and `handoff-speed-up-3.md`. The first handoff established the measurement protocol, the second recorded the accepted parser and transformer optimizations, the third recorded inference and LSP allocation reductions, and this one records a per-file cache for the Hindley-Milner type environment — the hotspot that profile re-measurement identified as by far the largest remaining one.

## Executive summary

`buildTypeEnv` accounted for **26.1% of all CPU samples** in a stdlib transpile. It runs once per expression whose type the manual resolver cannot pin down, and it rebuilt its entire function half each time: a full re-conversion of every function signature in the file, including generic-parameter substitution and a fresh scheme allocation per function.

The function half depends only on file-level metadata, so it is now converted once per file and shared by pointer. Two guards keep that correct: an epoch counter bumped at every write to the state the conversion reads, and a check for a local binding that shadows an unqualified type name — `getType` answers from the scope chain *before* package metadata, so a local named like a type in a signature resolves differently.

Two smaller items shipped alongside it, both found by the same re-profile:

1. **Per-file function type-environment cache** — `buildTypeEnv` fell from 26.1% to 2.2% of samples.
2. **Shared builtin operator schemes and a right-sized environment map** — both call sites add ten operator keys immediately after building the map, so they were forcing a rehash on every expression inference.
3. **Removed the dead `sourceLines` split** flagged by the third handoff; the field was written per file and never read.

Corpus results, from three independent paired 9-repetition runs (see *Corpus comparison* for the caveat on magnitudes):

| Metric | Run 1 (seed 7) | Run 2 (seed 21) | Run 3 (seed 33) |
| --- | ---: | ---: | ---: |
| wall median | −27.1% | −49.7% | −33.2% |
| wall p95 | −15.3% | −46.3% | −27.6% |
| user median | −25.9% | −43.6% | −30.1% |
| user p95 | −19.0% | −44.3% | −24.5% |
| RSS median | −21.7% | −11.1% | −19.9% |
| RSS p95 | −15.3% | −24.2% | −25.1% |

Every metric improves in every run, which satisfies the acceptance rule the third handoff could not meet. All 53 stdlib outputs remained byte-identical in all three runs. The full Bazel build, all 409 tests, the Nix smoke check, and `nix flake check` pass.

## Re-profile that redirected the work

The third handoff's remaining-work list named `buildTypeEnv` as the next target but rated it "the remaining measured transformer hotspot", implying a modest share. Measuring first changed the plan. A cold-cache profile of the batch stdlib transpile (`--profile-kind all`, artifact preserved at `tmp/profiles/before-heap.pprof`) gave:

```
Duration: 9.40s, Total samples = 12.70s (135.10%)
    0.63s  4.96%  ...  runtime.mallocgcSmallScanNoHeader
    0.30s  2.36%  1.81s 14.25%  transformer.(*galaASTTransformer).toInferTypeMemoized
    0.13s  1.02%  2.34s 18.43%  runtime.gcDrain
    0.26s  2.05%  1.92s 15.12%  antlr.(*ParserATNSimulator).closureWork
    0.07s  0.55%  3.32s 26.14%  transformer.(*galaASTTransformer).buildTypeEnv
    0     0%     3.44s 27.09%  transformer.(*galaASTTransformer).inferExprType
    0     0%     3.52s 27.72%  transformer.(*galaASTTransformer).getExprTypeName
```

`buildTypeEnv` at 26.1% was larger than every other single non-GC function combined, and `inferExprType` was 96.5% `buildTypeEnv`. A line-level listing put essentially all of that 3.32s into the two loops, of which the `t.functions` loop was ~2.75s:

```
    20ms   60ms   267:   for name, meta := range t.functions {
    10ms  1.84s   268:       funcType := t.toInferTypeMemoized(transpiler.FuncType{...})
    1.84s (54.5%)              -> toInferTypeMemoized
    620ms (18.7%)              -> substituteTypeParams
    330ms ( 9.9%)              -> mapassign_faststr
    110ms                       scope valTypes loop, for contrast
```

The scope loop, which genuinely must run per call, was 110ms. Everything else was repeated work. That is why the change is a cache on the function half and not a micro-optimization of the loop.

## Implemented improvements

### 1. Cache the function-derived type environment per file

Changed:

- `internal/transpiler/transformer/bridge.go:292` — `buildTypeEnv` split into the cached function half and the per-call scope half.
- `internal/transpiler/transformer/bridge.go:357` — new `functionTypeEnv`.
- `internal/transpiler/transformer/bridge.go:410` — new `scopeShadowsFuncTypeNames`.
- `internal/transpiler/transformer/bridge.go:428` — new `invalidateTypeEnv`.
- `internal/transpiler/transformer/bridge.go:333` — new `scopeBindingCount`.
- `internal/transpiler/transformer/bridge.go:34` — `typeNameMemo` replaces the bare `map[string]string` memo.
- `internal/transpiler/transformer/bridge.go:44` — `normalizeTypeNameMemoized` records consulted names.
- `internal/transpiler/transformer/transformer.go:91` — five new state fields.
- `internal/transpiler/transformer/transformer.go:213` — invalidate at `Transform` entry.
- `internal/transpiler/transformer/transformer.go:843` — invalidate in `registerEmbeddedFSMetadata`.
- `internal/transpiler/transformer/declarations.go:1302` — invalidate on a new type alias.
- `internal/transpiler/transformer/declarations.go:1374` — invalidate after an import block is walked.
- `internal/transpiler/transformer/codec.go:334` — invalidate on a generated struct-meta type.

`buildTypeEnv` now merges a cached `fnEnv` with the current scope chain. The merge order is load-bearing and preserved: function names win over same-named local bindings, as they did when both halves were written into one map by two consecutive loops. Scope entries whose name is in `fnEnv` are now skipped outright rather than converted and then overwritten.

**Why sharing schemes by pointer is safe.** `infer` treats `Type` and `Scheme` as immutable values:

- `unify` returns a `Substitution`; `bind` returns `Substitution{v: t}`. Neither writes into a `TypeVariable`.
- `TypeEnv.Apply` always allocates a new map, so the `Let` branch's `newEnv[name] = scheme` never writes into a caller's environment.
- `Scheme.FreeTypeVars` deletes the quantified variables, so a cached scheme's variables are invisible to `generalize`.
- `instantiate` maps each quantified variable to a fresh `NewTypeVar()` per use, so a cached generic scheme stays an uninstantiated template no matter how many runs read it.

The consequence is that a cached scheme cannot accumulate bindings across inference runs, which is the only way caching one could be wrong.

**Two guards, both required.**

*Epoch.* The conversion reads `t.functions`, `t.typeMetas`, `t.typeAliases`, and the import manager. Several of those are written **mid-traversal**, not at `Transform` entry: a type alias is registered as its declaration is lowered, an import is added as the import block is walked, and generated struct-meta types appear during codec lowering. `invalidateTypeEnv` is therefore called at each of those five sites rather than only at entry. `ImportManager.AddTransitive` is deliberately *not* a site: it writes only `transitiveImports`, which `getType` never reads.

*Scope shadowing.* `getType` searches the scope chain before package metadata, so a local binding named like an unqualified type in a signature changes how that name normalizes. `functionTypeEnv` records every unqualified name the conversion normalized and refuses reuse when the current scope chain binds one of them. The scan iterates the chain's bindings rather than the name set, because a chain holds a handful of bindings while the name set holds every unqualified type mentioned by every signature in the file.

The trade-off is deliberate and worth stating: **while such a shadowing binding exists, the cache stays disabled**, which degrades to the pre-change behavior for that file. Narrowing it further — comparing the bound type against a recorded one — would only help a program that shadows a type name with a local, at the cost of a type comparison on a hot path. Correctness and the common case were preferred.

**A bug this design had first.** The initial version recorded only the names the scope happened to *answer* during the build. `TestFunctionTypeEnvRebuildsWhenScopeShadowsANormalizedName` caught that this is wrong: a name resolved from type metadata at build time can be answered from a scope binding later, and the cache would have been reused stale. The memo now records every unqualified name consulted, which is the conservative direction.

**One behavior change, strictly narrowing an existing nondeterminism.** A generic scheme's `Vars` was previously assembled by iterating the `tvMap` (random order) and is now assembled in `meta.TypeParams` order. `Vars` order is irrelevant to `instantiate` and to `FreeTypeVars`, and it is only observable through `Scheme.String()`. The previous output was a random permutation, so every previously possible rendering remains possible; the change only makes diagnostics deterministic. No golden test moved.

### 2. Share the builtin operator schemes, and size the map for them

Changed:

- `internal/transpiler/transformer/bridge.go:462` — `builtinTypeEnv`, built once.
- `internal/transpiler/transformer/bridge.go:480` — `addBuiltinsToEnv` copies from it.
- `internal/transpiler/transformer/bridge.go:311` — `buildTypeEnv` sizes the map to include those ten keys.

`addBuiltinsToEnv` previously allocated a dozen type nodes and a scheme per operator on every call, and then inserted ten keys into a map sized only for the rest — a rehash per inference. The heap profile showed the insert alone at 2.1% of allocated bytes. Measured A/B on `BenchmarkBuildTypeEnv`, which includes the insert because both real call sites make it:

| | ns/op | B/op | allocs/op |
| --- | ---: | ---: | ---: |
| without the size hint | 2183–2450 | 832 | 10 |
| with the size hint | 1651–1801 | 624 | 9 |

### 3. Remove the dead `sourceLines` split

Changed:

- `internal/transpiler/transformer/transformer.go` — the `sourceLines` field (was line 65) and the per-file `strings.Split` (was line 224) are both removed; neither has a remaining reference.
- `internal/transpiler/transformer/scoped_state.go:97` — dropped from `accumulatedStateFields`.

Flagged by the third handoff. `t.sourceLines` was assigned per file and never read anywhere in the repository; the only other references were the field declaration and the state-classification list. For a 3000-line stdlib file the split allocated a 3000-element string-header slice for nothing.

## Coverage and benchmarks

Added in `internal/transpiler/transformer/func_type_env_test.go` (257 lines, registered in `BUILD.bazel`):

- `TestFunctionTypeEnvIsReusedUntilInvalidated` — the same map is returned on an unchanged transformer, and each of `typeMetas`, `typeAliases`, `functions`, and a new import forces a rebuild.
- `TestFunctionTypeEnvRebuildsWhenScopeShadowsANormalizedName` — the regression that pinned the consulted-name bug above.
- `TestFunctionTypeEnvStaysReusedWithoutShadowing` — a scope full of ordinary local names does not cost the cache its reuse. This is the hot path.
- `TestBuildTypeEnvLetsFunctionNamesWinOverLocalBindings` — the merge order.
- `TestBuildTypeEnvKeepsDistinctScopesDistinct` — a binding added after the cache was built is visible, and an outer-only entry does not leak inward.
- `TestCachedGenericSchemeInstantiatesFreshPerUse` — two uses of a cached generic function at `int` and `string` infer independently, which is the property that makes sharing a generic scheme safe.
- `TestBuiltinsToEnvSharesOneSetOfSchemes` — the operator schemes are shared.
- `BenchmarkBuildTypeEnv`, `BenchmarkFunctionTypeEnvUncached`.

`TestEveryTransformerFieldIsClassified` in `scoped_state_test.go` is bidirectional, so the five new fields had to be added to `accumulatedStateFields` and the removed one deleted from it.

Focused allocation results, `-benchmem -count=5`:

| Benchmark | B/op | allocs/op | ns/op |
| --- | ---: | ---: | ---: |
| `BenchmarkBuildTypeEnv` | 624 | 9 | 1651–1801 |
| `BenchmarkFunctionTypeEnvUncached` | 4289 | 37 | 3730–7083 |

`BenchmarkFunctionTypeEnvUncached` invalidates before each iteration, so it measures precisely the work the cache removes on a two-function fixture. The real corpus has far more functions per file, so the gap there is wider than this fixture shows.

`internal/transpiler/transformer/binary_type_test.go:140` was updated for the `typeNameMemo` signature change; its existing assertion that the memo is build-local still holds and still guards the reusable scratch memo in `buildTypeEnv`.

## Profile after the change

A cold-cache profile of the same corpus (`--profile-kind all`, artifact at `tmp/profiles/after-heap.pprof`):

```
Duration: 5.56s, Total samples = 8.31s (149.49%)
    0.21s  2.53%  1.87s 22.50%  antlr.(*ParserATNSimulator).closureWork
    0.09s  1.08%  1.45s 17.45%  runtime.gcDrain
    0     0%     0.33s  3.97%  transformer.(*galaASTTransformer).getExprTypeName
    0     0%     0.29s  3.49%  transformer.(*galaASTTransformer).inferExprType
    0     0%     0.18s  2.17%  transformer.(*galaASTTransformer).buildTypeEnv
```

Percentages are the comparable figure; the absolute sample totals are not, because the profiled pass itself got faster. The type-inference path is no longer a target:

| | before | after |
| --- | ---: | ---: |
| `getExprTypeName` | 27.72% | 3.97% |
| `inferExprType` | 27.09% | 3.49% |
| `buildTypeEnv` | 26.14% | 2.17% |
| `runtime.gcDrain` | 18.43% | 17.45% |
| `antlr ... closureWork` | 15.12% | 22.50% |

`closureWork` rising to 22.5% is the removal of a competitor, not a regression: it is unchanged in absolute terms and is now the largest single non-GC function.

## Measurement details

### Environment

Both baseline and candidate used the harness's own recorded environment (`run.env` in each result directory):

- host: Linux 6.8.0-139-generic x86-64;
- CPU: Intel Core i7-1165G7 @ 2.80GHz, 8 hardware threads;
- Go: `go1.26.7 linux/amd64`;
- Bazel: `9.2.0`;
- GOROOT: `/nix/store/4l04h8656as4i291mpcg38wz9m4k8acp-go-1.26.7/share/go`;
- Nix: `nix (Determinate Nix 3.21.8) 2.34.8`;
- `GOMAXPROCS=8` (the harness default — the third handoff used 4, so its absolute seconds are not comparable with these);
- `GOGC=300`, `GOMEMLIMIT=6GiB` (harness `tuned` GC mode);
- cold application cache per repetition;
- `/usr/bin/time -v` for wall, user, system, and RSS.

### Binaries

- baseline: commit `500bf9b0d8395ccf0246c00d0247dedfe75cf31b` — the third handoff's commit, built by stashing only `internal/transpiler/transformer/`, so the baseline is that commit's transformer verbatim;
- candidate: the same commit plus the changes in this handoff.

Both were passed to a **single** `tools/bench_transpile.sh` invocation as `--release-bin` and `--local-bin`. This matters: the third handoff could not use the corpus for a decision because its old and new binaries were run in separate, non-alternated sessions and were both labeled `local`. Here the two binaries have different kinds, get distinct labels, alternate within each repetition, and share one randomized package order per repetition.

### Commands

```sh
go test -run '^$' \
  -bench 'Benchmark(BuildTypeEnv|FunctionTypeEnvUncached)$' \
  -benchmem -count=5 \
  ./internal/transpiler/transformer
```

```sh
tools/bench_transpile.sh \
  --release-bin tmp/bin/baseline \
  --local-bin tmp/bin/candidate \
  --repetitions 9 --mode batch --order randomized \
  --gc-mode tuned --cache-mode cold \
  -o <dir-outside-the-repository>
```

Repeated with seeds 7, 21, and 33. The harness refuses an output directory inside the repository, so result directories live under `/tmp/opencode/` and the small artifacts were copied into `tmp/ab-run/`.

### Corpus comparison

The harness must be run from the repository but writes outside it. Absolute seconds shift with host load between sessions, so the three runs disagree on magnitude: baseline wall medians of 8.04 s, 9.68 s, and 8.17 s for the same binary. What is stable is the sign and the direction of every metric within each run, because each run measured both binaries under the same load in one invocation.

| Run | Seed | Baseline wall med/p95 | Candidate wall med/p95 |
| --- | ---: | --- | --- |
| 1 | 7 | 8.04 s / 9.44 s | 5.86 s / 8.00 s |
| 2 | 21 | 9.68 s / 9.95 s | 4.87 s / 5.34 s |
| 3 | 33 | 8.17 s / 8.73 s | 5.46 s / 6.32 s |

Do not quote a single run's percentage as *the* speedup. The defensible claim is: **every one of the six metrics improves in all three runs, with wall-median reductions between 27% and 50%.**

### Output identity

All 53 selected stdlib inputs produced byte-identical output between baseline and candidate in **all three** runs, and each run's 18 hashes per file (9 repetitions × 2 binaries) collapsed to a single distinct value — so the two binaries agree with each other and are each self-consistent across repetitions. Artifacts:

- `tmp/ab-run/output-identity.tsv` (run 3)
- `tmp/ab-run/summary.txt`, `results.tsv`
- `tmp/ab-run/source-pollution.txt` — empty diff for source `.gen.go`, source `.gala`, and `git status` in every run.

No source-tree pollution was introduced; the transformer's output is unchanged, which is the strongest available evidence that a cache with two invalidation guards has not altered inference.

## Validation completed

Focused Go tests:

```sh
go test -count=1 -run 'Test(FunctionTypeEnv|BuildTypeEnv|CachedGenericScheme|BuiltinsToEnv|EveryTransformerField|TypeNameMemo|CachedTypeResolver)' \
  ./internal/transpiler/transformer
```

All pass. `go test ./internal/transpiler/transformer` has two failures —
`TestCodec_NoJsonSpecificHardcodingOutsideTypedCodegen` and
`TestSomeWrapSealedCaseNameOverlap` — that **also fail on the unmodified baseline** under bare
`go test`; the first scans for literals the change does not add, and the second needs
`collection_immutable` on a search path that only the Bazel test data provides. Both were
confirmed by stashing the change and re-running. They are not caused by this work.

Full Bazel gates:

```sh
bazel build //... --action_env=GOROOT="$GOROOT" --action_env=PATH
bazel test  //... --test_output=errors --cache_test_results=no \
  --action_env=GOROOT="$GOROOT" --action_env=PATH
```

- 1,511 targets built successfully;
- **409 of 409 tests passed**;
- `//internal/transpiler/transformer:transformer_test` passed in 94.0 s;
- `//internal/lsp:lsp_test` passed in 39.8 s;
- `//internal/transpiler/analyzer:analyzer_test` passed in 19.5 s;
- `//internal/transpiler/infer:infer_test` passed in 0.1 s.

Nix gates:

```sh
nix build .#checks.x86_64-linux.smoke --print-build-logs
nix flake check
```

`checks.x86_64-linux.smoke`, `.package`, `.gala-local` and `.stdlib-source-priority` all pass.

Hygiene:

```sh
gofmt -l <each changed .go file>   # no output
go vet ./internal/transpiler/transformer/
git diff --check
```

A note on `gofmt`: `gofmt -w` over the whole `transformer/` directory also reformatted twelve
files that were already unformatted upstream (`scope.go`, `sealed.go`, `call_context.go`,
`codec_typed.go`, and eight test files). Those changes were reverted — they are unrelated to
this work and would have buried it. The repository therefore still has those pre-existing
deviations, and `gofmt -l internal/transpiler/transformer/` is not empty on a clean tree.

## Files changed by this continuation

Performance code:

- `internal/transpiler/transformer/bridge.go`
- `internal/transpiler/transformer/transformer.go`
- `internal/transpiler/transformer/declarations.go`
- `internal/transpiler/transformer/codec.go`
- `internal/transpiler/transformer/scoped_state.go`

Tests and benchmarks:

- `internal/transpiler/transformer/func_type_env_test.go` (new)
- `internal/transpiler/transformer/binary_type_test.go`
- `internal/transpiler/transformer/BUILD.bazel`

Handoff:

- `handoff-speed-up-4.md`

Scratch (gitignored, not part of the change):

- `tmp/bin/` — the two binaries under comparison, deleted after the final run;
- `tmp/ab-run/` — the retained result artifacts;
- `tmp/profiles/` — before and after CPU profiles and the after-heap 500 MB band snapshot;
- `.gitignore` gained a `/tmp/` entry. Its pre-existing uncommitted `node_modules` and
  `ide/vscode` lines were left untouched.

## Unrelated working-tree state

These pre-existing changes were preserved and are **not** part of this work:

- `handoff-language-features.md` (untracked);
- `handoff-language-features-1.md` (untracked);
- `opencode.json` (untracked).

The `.gitignore` edit is included because this session added the `/tmp/` entry to it; the
`node_modules` and `ide/vscode` lines that were already there belong to someone else's work
and were left in place. A commit that wants to avoid touching `.gitignore` at all should drop
that one hunk and lose only the `tmp/` ignore rule.

## Decisions

### Accepted

- **Per-file function type-environment cache.** The largest single hotspot by profile, removed with an epoch counter plus a scope-shadowing guard, and covered by a test for each guard.
- **Shared builtin schemes and a right-sized map.** Free once the cache existed, and measured rather than assumed — the size hint is worth 25% on the per-call benchmark.
- **Dead `sourceLines` split removed.** Flagged by the previous handoff; confirmed dead by repository-wide search before deleting.
- **53/53 output identity plus a 409/409 test pass as the acceptance bar.** For a compiler change that shares inference state between runs, byte-identical output is worth more than any timing number.

### Not accepted as evidence

- **A single headline speedup percentage.** The three runs disagree between 27% and 50% on wall median because host load moved between sessions. The sign consistency across all six metrics in all three runs is the claim; no one run's number is.
- **Absolute seconds compared with `handoff-speed-up-3.md`.** `GOMAXPROCS` was 4 there and 8 here.
- **The absolute sample totals of the two profiles.** The profiled pass got faster, so total samples are not a fixed yardstick; only the percentages are comparable.
- **Tuning the environment for the change.** No GC default, cache, or parallelism knob was touched. The wins are algorithmic.

## Remaining work

### 1. ANTLR adaptive prediction is now the largest cost (22.5% of samples)

`ParserATNSimulator.closureWork` is almost entirely the left-recursive expression precedence
chain (`AndExpr` → `OrExpr` → `EqualityExpr` → `RelationalExpr` → `AdditiveExpr` → …). The
parser already runs SLL with an LL fallback (`internal/parser/parser.go:88`), and the profile
confirms no file is being parsed twice — `ParseLenient` costs 27.08% against
`parseSourceFileAttempt` at 26.84%, so the fallback is not firing on the corpus.

That closes the cheap options. What remains is a grammar or front-end change:

- reduce the depth of the precedence chain, or
- hand-write a Pratt/recursive-descent parser for expressions and keep ANTLR for
  declarations, or
- investigate whether the generated ATN can avoid full-context prediction for the operand
  decision.

This is a real opportunity but it is a large, high-risk change to the language front end, and
it must preserve parse-error positions and messages. It should be scoped on its own.

### 2. GC is still 17.5% of samples

The remaining allocators are now mostly ANTLR's (`NewATNConfig` 22.6% of allocated bytes,
`JMap.Put` 8.8%, `NewBaseSingletonPredictionContext` 6.3%, `JStore.Put` 4.5%). `buildTypeEnv`
is down to 4.4% of allocated bytes, all of it the per-call result map and the scope-half
schemes, both of which are required because callers mutate the returned environment. This work
is therefore coupled to item 1: reduce parser allocation and the GC share follows.

### 3. The type environment is still rebuilt per expression

`buildTypeEnv` is down to 2.2% of samples, but it still allocates a fresh map and a scheme per
scope binding on every call, because `addBuiltinsToEnv` writes into the result and `infer`'s
`Let` branch extends it. A copy-on-write environment, or having `infer` take the shared map
plus an overlay of additions, would remove it. Worth roughly 2% of CPU — low priority now
that the cache has taken the cost out of the function half.

### 4. Still do not trust the corpus harness for a decision without checking labeling

The three runs here were valid because the two binaries had *different kinds*
(`--release-bin` and `--local-bin`). The third handoff's remaining-work item 1 — duplicate
binaries of the same kind receiving colliding labels and colliding result paths — is
**unfixed**. Anyone comparing two `--local-bin` builds will hit it. That fix is still worth
making before the next A/B, and is independent of this change.

## Resume checklist

1. `git status` and preserve the unrelated untracked files listed above.
2. Before the next A/B, fix same-kind binary labeling and result-path collisions in `tools/bench_transpile.sh`, and add the two-binaries-of-one-kind fixture.
3. Re-profile before starting on the parser: confirm ANTLR is still ~22% and that `buildTypeEnv` has not crept back.
4. Treat the ANTLR precedence chain as its own scoped project with its own error-message regression corpus.
5. Keep the epoch guard honest: any new write to `t.functions`, `t.typeMetas`, `t.typeAliases`, or `importManager.Add`/`AddFromPackages` must call `invalidateTypeEnv`. `TestEveryTransformerFieldIsClassified` will not catch a missed call — a missed call is a silent stale-cache bug.
6. Re-run the full Bazel and Nix gates and a 9-rep paired corpus comparison before creating any further commit.
