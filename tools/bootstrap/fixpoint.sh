#!/usr/bin/env bash
# Verify that the pinned stage-0 compiler and the working tree's bootstrap
# emit byte-identical stdlib Go. The stdlib is bootstrap-built, so a drift
# means the pin no longer matches the generator: either the change was
# unintended (fix it) or intended (bump the pin). See tools/bootstrap/README.md.
set -euo pipefail
cd "$(dirname "$0")/../.."

# .bazelrc forwards GOROOT to actions with a bare --action_env=GOROOT, so it
# must be in the client environment for the transpiler to resolve Go types.
if [ -z "${GOROOT:-}" ] && command -v go >/dev/null 2>&1; then
  GOROOT="$(go env GOROOT)"
  export GOROOT
fi
if [ -z "${GOROOT:-}" ]; then
  echo "warning: GOROOT is not set; the transpiler may lack Go type information" >&2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Default configuration: the pinned stage-0 compiler.
bazel build //internal/stdlib:generate_embedded
cp -f bazel-bin/internal/stdlib/embedded_gen.go "$tmp/pinned.go"

# 2. Working tree's bootstrap.
bazel build --define=gala_bootstrap=local //internal/stdlib:generate_embedded
if ! diff -u "$tmp/pinned.go" bazel-bin/internal/stdlib/embedded_gen.go > "$tmp/diff"; then
  echo "bootstrap fixpoint drifted: the working tree's gala_bootstrap emits" >&2
  echo "different stdlib Go than the pinned stage-0 compiler." >&2
  echo "If the generation change is intended, bump the pin to a revision that" >&2
  echo "contains it: tools/bootstrap/bump.sh <40-hex-commit>" >&2
  head -80 "$tmp/diff" >&2
  exit 1
fi
echo "bootstrap fixpoint OK"
