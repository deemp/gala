# GALA transpiler speed-up: second execution handoff

Date: 2026-09-25
Status: both selected optimizations are retained in the working tree and passed the repository gates; no commit was created.

This record continues `handoff-speed-up.md` and `handoff-speed-up-1.md`. The repository already contains the Phase 0 instrumentation and benchmark harness. Unrelated concurrent changes in `.gitignore`, `handoff-language-features*.md`, and `opencode.json` are preserved and are not part of this work.

## Selected approaches

1. **SLL-first parser with LL fallback** — reduce ANTLR full-context prediction allocations for valid source files while preserving the existing LL diagnostics and parse tree on fallback. Generated grammar files will not be edited.
2. **Transformer inference work reduction** — build one immutable per-file type-resolver snapshot and use a build-local memo for repeated type-name normalization during HM fallback. Neither snapshot will be shared across files or across concurrent analyzer work.

The second approach is limited to immutable import metadata and synchronous environment construction. Full HM environments, scopes, generic schemes, and diagnostics remain uncached.

## Progress log

### 2026-09-25 — initial continuation

- Inspected the current HEAD and confirmed the measured hotspots in the prior CPU/heap artifacts.
- Confirmed the current parser already isolates ANTLR prediction-context caches while sharing the mutex-protected DFA; the proposed parser change preserves that invariant.
- Confirmed the transformer already clears the AST-keyed expression cache at each transform. The new transformer work will be additive and independently benchmarked.
- Confirmed the working tree has only unrelated concurrent modifications; no speed-up files are currently modified.

## Acceptance gates

- Forced SLL and LL parse trees and diagnostics remain equivalent.
- Generated output hashes remain byte-identical for the 53-file stdlib corpus and representative fixtures.
- Parser and transformer focused tests pass, including malformed input and reused-transformer cases.
- Before/after wall time, CPU, allocation, and RSS are recorded from separate timing/profile passes.
- A candidate is rejected if it regresses correctness, materially worsens p95/RSS, or only improves an unmeasured microbenchmark.

## Planned next records

### 2026-09-25 — baseline and parser experiment

- Baseline artifact: `/tmp/gala-speedup-2-baseline` (current HEAD `975d4e8d`, 53 inputs, cold isolated application cache, tuned GC, `GOMAXPROCS=4`): 44.23 s wall, 77.23 s user CPU, 2.75 s system CPU, 1,401,712 KiB maximum RSS.
- Implemented SLL-first parsing in `internal/parser/parser.go`; each speculative attempt gets a fresh lexer/parser, isolated prediction-context cache, and SLL mode. Any syntax or lexical error discards the attempt and retries the same input in LL mode. Final blank-line checks and diagnostics run only on the retained result.
- Added forced-mode equivalence coverage to `internal/parser/parser_test.go`; `//internal/parser:parser_test` passes.
- Parser candidate artifact: `/tmp/gala-speedup-2-parser`: 18.92 s wall, 22.36 s user CPU, 1.35 s system CPU, 918,996 KiB maximum RSS. This is a one-pass smoke result, not yet a decision-quality claim; host load and the large difference require repeated randomized measurements.
- Independently compared the baseline and parser output manifests: 53/53 SHA-256 values match. The benchmark harness initially reported a false mismatch because its awk comparison used the reserved word `match`; the comparison logic was corrected in `tools/bench_transpile.sh` and `bash -n` passes.
### 2026-09-25 — transformer experiment and combined profile

- Added `cachedTypeResolver` to the transformer, reset it at transform entry, build it after explicit imports and actual package-name correction, and use it for simple-name resolution. Calls before the snapshot remain live and deliberately non-caching. Import slice construction is preallocated.
- Added a build-local normalized-name memo to `toInferType` conversions used by `buildTypeEnv`; tracing mode disables the memo to preserve trace multiplicity. Added lifecycle tests in `binary_type_test.go`.
- Focused transformer tests passed: `TestCachedTypeResolverLifecycle`, `TestTypeNameMemoIsBuildLocal`, type-inference regression, dot-import, cross-file alias, import, and scoped-state cases. Parser race testing passed with `go test -race -count=1 ./internal/parser`.
- Combined three-repetition artifact `/tmp/gala-speedup-2-combined-r3`: cold isolated cache, tuned GC, `GOMAXPROCS=4`, randomized order; median/p95 wall 10.42/10.63 s, user CPU 13.04/13.24 s, system CPU 1.10/1.25 s, maximum RSS median/p95 872,508/928,048 KiB. All 53 output hashes were identical within the candidate and matched the baseline.
- Combined one-pass profiling artifact `/tmp/gala-speedup-2-profile` reported 53 files in 11.51 s of batch file wall time: parse 1.189 s, analyze 3.838 s, transform 5.844 s, generate 0.340 s, and line post-processing 0.283 s. The separate CPU/heap artifacts are in `/tmp/gala-speedup-2-profiles/local-batch-__batch__`.
- The candidate CPU profile still shows `buildTypeEnv` as the largest transformer path, but the prior 10.65 s cumulative `buildTypeEnv` sample has fallen to 4.84 s in this pass; `closureCheckingStopState` is 1.89 s versus the prior 37.74 s artifact. These comparisons combine different profiling contexts and remain directional until a same-protocol baseline is rebuilt.
- The full transformer race command exceeded the 600-second tool timeout without reporting a failure; it remains a validation follow-up rather than a pass.
### 2026-09-25 — isolated attribution and GC checks

- Built clean-HEAD, parser-only, and transformer-only binaries in disposable worktrees. Three-repetition cold randomized results at `GOMAXPROCS=4` and tuned GC were: clean baseline median/p95 56.48/57.95 s, parser-only 17.97/18.74 s, transformer-only 33.95/34.69 s, combined 10.42/10.63 s. Median reductions versus clean baseline are approximately 68.2%, 39.9%, and 81.6%, respectively; these are corpus measurements, not universal transpilation guarantees.
- Transformer-only RSS was 1,488,160/1,493,296 KiB median/p95 in that run, higher than the clean baseline's 1,313,156/1,479,580 KiB. The combined candidate's RSS was lower in the same comparison, and all variants stayed well below the 16-GiB runner budget; transformer memory behavior remains a follow-up measurement rather than a reason to discard the wall-time win.
- Clean-HEAD same-protocol profile `/tmp/gala-speedup-2-baseline-profile` reported 34.726 s file wall, parse 10.348 s, analyze 15.145 s, transform 8.823 s. The candidate profile reported 11.51 s, parse 1.189 s, analyze 3.838 s, transform 5.844 s. CPU `closureCheckingStopState` was 33.52 s in the clean profile versus 1.89 s in the candidate profile.
- Candidate GC comparison at `GOMAXPROCS=4` over three cold repetitions: default GC median/p95 8.37/9.05 s and 753,248/845,800 KiB RSS; tuned GC 7.79/7.85 s and 753,996/818,552 KiB RSS. Tuned GC remains provisionally favorable, but this is not a reason to change unrelated build entry points yet.
- Candidate `GOMAXPROCS=1` measured 10.44/10.77 s wall and 1,346,544/1,385,936 KiB RSS; `GOMAXPROCS=8` measured 8.43/9.11 s and 821,520/848,036 KiB RSS. Parallelism and GC scheduling materially affect RSS, so the final report will retain these settings explicitly.
- The full `bazel test //internal/transpiler/...` suite passed all 12 targets, including the 83.8-second transformer corpus target.

### 2026-09-25 — final validation and decisions

- `bazel build //...` passed.
- `bazel test //... --test_output=errors --verbose_failures --cache_test_results=no` passed all 409 tests, including parser, analyzer, transformer, build, LSP, examples, and stdlib targets.
- `nix build .#checks.x86_64-linux.smoke --print-build-logs` passed; `nix flake check` passed on x86_64-linux.
- Final bootstrap-path artifact `/tmp/gala-speedup-2-bootstrap` completed local and bootstrap batch modes with 53/53 identical output hashes; bootstrap was 8.06 s and local 8.83 s in that one pass. Bootstrap and local output hashes also matched the clean baseline manifest.
- **Accepted:** SLL-first parsing with LL fallback. It removes most full-context prediction work on valid files, preserves forced-LL diagnostics in focused tests, passes the parser race test, and produced byte-identical output in every corpus run.
- **Accepted:** per-file transformer resolver snapshot plus build-local type-name memo. It reduced isolated transformer wall time by about 39.9% in the three-repetition comparison, preserved all output hashes, and passed the full transpiler suite. The snapshot is reset for reused transformers; no cross-file mutable state was introduced.
- **Not changed:** GC defaults for unrelated build entry points, package-summary concurrency, output formatting reduction, and broader parallelism. The measurements do not justify those additional changes yet.
- **Remaining bottleneck:** transformer inference still dominates the candidate phase profile (`buildTypeEnv` 4.84 s in the profiled pass); parser SLL residual prediction and analyzer work are next. Transformer-only RSS should be watched on constrained runners, although the combined candidate stayed below 1 GiB in the later GC run and all tested runs remained under the 16-GiB budget.
- The only uncommitted files related to this work are the parser/transformer sources and tests, the benchmark comparison fix, and this handoff. Unrelated concurrent files were not reverted. No commit was created.
