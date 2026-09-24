#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
NIX_FILE="$REPO_ROOT/nix/gala.nix"
TIME_BIN=/usr/bin/time

usage() {
  cat <<'USAGE'
Usage: tools/bench_transpile.sh [options]

The benchmark corpus is derived from nix/gala.nix. Every selected non-test
.gala file is staged under a disposable directory outside the repository.

Binary options:
  --release-bin PATH       Released gala binary
  --local-bin PATH         Local gala binary
  --bootstrap-bin PATH     Local gala_bootstrap binary
  --binary PATH            Generic binary; bootstrap is inferred by name
  --release PATH           Alias for --release-bin
  --local PATH             Alias for --local-bin
  --bootstrap PATH         Alias for --bootstrap-bin
  --bin PATH               Alias for --binary

Execution options:
  --goroot PATH            Go SDK root; defaults to go env GOROOT
  --gomaxprocs N           GOMAXPROCS for every measured invocation
  --repetitions N          Measured repetitions (default: 5)
  --mode MODE              per-package, batch, or both (default: per-package)
  --order ORDER            lexicographic, rotated, or randomized
  --seed N                 Order seed (default: 1)
  --filter REGEX           Keep matching staged-relative input paths
  --quick-smoke            Keep stdlib inputs and examples/hello.gala
  --smoke                  Alias for --quick-smoke
  --gc-mode MODE           default, tuned, or both (default: tuned)
  --cache-mode MODE        cold, warm, or both (default: cold)
  --scan MODE              auto, yes, or no for full batch mode
  --output DIR             Result directory; must be outside the repository
  -o DIR                   Alias for --output
  --keep-stage             Keep disposable stages for inspection

Comparison and profiling options:
  --baseline PATH          Prior result directory or summary.tsv
  --allow-output-mismatch  Do not fail when output hashes disagree
  --profile                Run a separate profiling pass after timing
  --profile-kind KIND      phase, cpu, heap, or all (default: phase)
  --profile-dir DIR        Profiling output directory
  -h, --help               Show this help

The result directory contains run.env, manifest.tsv, results.tsv,
  output-manifest.tsv, summary.tsv, summary.txt, aggregate.tsv,
  aggregate-summary.tsv, order.tsv, and optional
comparison and profiling files. Timing uses /usr/bin/time -v and never drops
shared Go, GALA, Bazel, Nix, or operating-system caches.
USAGE
}

die() {
  printf 'bench_transpile.sh: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'bench_transpile.sh: warning: %s\n' "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

safe_component() {
  local value=${1:-}
  value=${value//[^A-Za-z0-9_.-]/_}
  printf '%s' "$value"
}

absolute_path() {
  local value=$1
  case "$value" in
    /*) printf '%s' "$value" ;;
    *) printf '%s/%s' "$PWD" "$value" ;;
  esac
}

join_lines() {
  local separator=$1
  shift
  local result=
  local value
  for value in "$@"; do
    if [[ -n "$result" ]]; then
      result+="$separator"
    fi
    result+="$value"
  done
  printf '%s' "$result"
}

if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
  die 'bash 4 or newer is required'
fi

RELEASE_BIN=
LOCAL_BIN=
BOOTSTRAP_BIN=
MODE=per-package
ORDER=rotated
ORDER_SEED=1
REPETITIONS=5
GOMAXPROCS=
GOROOT=
FILTER=
QUICK_SMOKE=0
GC_MODE=tuned
CACHE_MODE=cold
SCAN_OVERRIDE=auto
OUTPUT=
BASELINE=
ALLOW_OUTPUT_MISMATCH=0
PROFILE=0
PROFILE_KIND=phase
PROFILE_DIR=
KEEP_STAGE=0

declare -a BIN_KIND BIN_PATH BIN_LABEL BIN_SCAN

add_binary() {
  local requested_kind=$1
  local requested_path=$2
  local requested_label=${3:-}
  local path kind label base
  [[ -n "$requested_path" ]] || die 'binary path cannot be empty'
  path=$(absolute_path "$requested_path")
  [[ -f "$path" ]] || die "binary does not exist: $requested_path"
  [[ -x "$path" ]] || die "binary is not executable: $requested_path"
  path=$(CDPATH= cd -- "$(dirname -- "$path")" && pwd -P)/${path##*/}
  base=${path##*/}
  if [[ "$requested_kind" == auto ]]; then
    if [[ "$base" == *bootstrap* ]]; then
      kind=bootstrap
    else
      kind=gala
    fi
  else
    kind=$requested_kind
  fi
  if [[ -z "$requested_label" ]]; then
    label=$kind
    local suffix=2
    while :; do
      local duplicate=0
      local existing
      for existing in "${BIN_LABEL[@]}"; do
        if [[ "$existing" == "$label" ]]; then
          duplicate=1
          break
        fi
      done
      if (( duplicate == 0 )); then
        break
      fi
      label="$kind$suffix"
      suffix=$((suffix + 1))
    done
  else
    label=$requested_label
  fi
  BIN_KIND+=("$kind")
  BIN_PATH+=("$path")
  BIN_LABEL+=("$label")
  BIN_SCAN+=(0)
}

while (($#)); do
  case "$1" in
    --release-bin|--release|--release-binary)
      (($# >= 2)) || die "$1 requires a path"
      RELEASE_BIN=$2
      add_binary gala "$RELEASE_BIN" release
      shift 2
      ;;
    --local-bin|--local|--local-binary)
      (($# >= 2)) || die "$1 requires a path"
      LOCAL_BIN=$2
      add_binary gala "$LOCAL_BIN" local
      shift 2
      ;;
    --bootstrap-bin|--bootstrap|--bootstrap-binary)
      (($# >= 2)) || die "$1 requires a path"
      BOOTSTRAP_BIN=$2
      add_binary bootstrap "$BOOTSTRAP_BIN" bootstrap
      shift 2
      ;;
    --binary|--bin|--compiler)
      (($# >= 2)) || die "$1 requires a path"
      add_binary auto "$2"
      shift 2
      ;;
    --goroot)
      (($# >= 2)) || die '--goroot requires a path'
      GOROOT=$2
      shift 2
      ;;
    --goroot=*)
      GOROOT=${1#*=}
      shift
      ;;
    --gomaxprocs)
      (($# >= 2)) || die '--gomaxprocs requires a value'
      GOMAXPROCS=$2
      shift 2
      ;;
    --gomaxprocs=*)
      GOMAXPROCS=${1#*=}
      shift
      ;;
    -j)
      (($# >= 2)) || die '-j requires a value'
      GOMAXPROCS=$2
      shift 2
      ;;
    --repetitions|--reps)
      (($# >= 2)) || die "$1 requires a value"
      REPETITIONS=$2
      shift 2
      ;;
    --repetitions=*)
      REPETITIONS=${1#*=}
      shift
      ;;
    --mode)
      (($# >= 2)) || die '--mode requires a value'
      MODE=$2
      shift 2
      ;;
    --mode=*)
      MODE=${1#*=}
      shift
      ;;
    --order)
      (($# >= 2)) || die '--order requires a value'
      ORDER=$2
      shift 2
      ;;
    --order=*)
      ORDER=${1#*=}
      shift
      ;;
    --seed)
      (($# >= 2)) || die '--seed requires a value'
      ORDER_SEED=$2
      shift 2
      ;;
    --seed=*)
      ORDER_SEED=${1#*=}
      shift
      ;;
    --filter)
      (($# >= 2)) || die '--filter requires a regular expression'
      FILTER=$2
      shift 2
      ;;
    --filter=*)
      FILTER=${1#*=}
      shift
      ;;
    --quick-smoke|--smoke)
      QUICK_SMOKE=1
      shift
      ;;
    --gc-mode|--gc)
      (($# >= 2)) || die "$1 requires a value"
      GC_MODE=$2
      shift 2
      ;;
    --gc-mode=*)
      GC_MODE=${1#*=}
      shift
      ;;
    --cache-mode|--cache)
      (($# >= 2)) || die "$1 requires a value"
      CACHE_MODE=$2
      shift 2
      ;;
    --cache-mode=*)
      CACHE_MODE=${1#*=}
      shift
      ;;
    --scan)
      (($# >= 2)) || die '--scan requires auto, yes, or no'
      SCAN_OVERRIDE=$2
      shift 2
      ;;
    --scan=*)
      SCAN_OVERRIDE=${1#*=}
      shift
      ;;
    --output|-o)
      (($# >= 2)) || die "$1 requires a directory"
      OUTPUT=$2
      shift 2
      ;;
    --output=*)
      OUTPUT=${1#*=}
      shift
      ;;
    --baseline)
      (($# >= 2)) || die '--baseline requires a path'
      BASELINE=$2
      shift 2
      ;;
    --baseline=*)
      BASELINE=${1#*=}
      shift
      ;;
    --allow-output-mismatch)
      ALLOW_OUTPUT_MISMATCH=1
      shift
      ;;
    --profile)
      PROFILE=1
      shift
      ;;
    --profile-kind)
      (($# >= 2)) || die '--profile-kind requires a value'
      PROFILE_KIND=$2
      shift 2
      ;;
    --profile-kind=*)
      PROFILE_KIND=${1#*=}
      shift
      ;;
    --profile-dir)
      (($# >= 2)) || die '--profile-dir requires a directory'
      PROFILE_DIR=$2
      shift 2
      ;;
    --profile-dir=*)
      PROFILE_DIR=${1#*=}
      shift
      ;;
    --keep-stage)
      KEEP_STAGE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 0)) || die 'positional arguments are not supported'
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ ${#BIN_PATH[@]} -gt 0 ]] || die 'provide at least one of --release-bin, --local-bin, --bootstrap-bin, or --binary'
[[ "$MODE" == per-package || "$MODE" == batch || "$MODE" == both ]] || die '--mode must be per-package, batch, or both'
[[ "$ORDER" == lexicographic || "$ORDER" == rotated || "$ORDER" == randomized ]] || die '--order must be lexicographic, rotated, or randomized'
[[ "$GC_MODE" == default || "$GC_MODE" == tuned || "$GC_MODE" == both ]] || die '--gc-mode must be default, tuned, or both'
[[ "$CACHE_MODE" == cold || "$CACHE_MODE" == warm || "$CACHE_MODE" == both ]] || die '--cache-mode must be cold, warm, or both'
[[ "$SCAN_OVERRIDE" == auto || "$SCAN_OVERRIDE" == yes || "$SCAN_OVERRIDE" == no ]] || die '--scan must be auto, yes, or no'
[[ "$PROFILE_KIND" == phase || "$PROFILE_KIND" == cpu || "$PROFILE_KIND" == heap || "$PROFILE_KIND" == all ]] || die '--profile-kind must be phase, cpu, heap, or all'
[[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die '--repetitions must be a positive integer'
[[ "$ORDER_SEED" =~ ^[0-9]+$ ]] || die '--seed must be a non-negative integer'
if [[ -n "$GOMAXPROCS" ]]; then
  [[ "$GOMAXPROCS" =~ ^[1-9][0-9]*$ ]] || die '--gomaxprocs must be a positive integer'
fi

for dependency in awk cat cmp cp diff dirname env find git mkdir mktemp rm sha256sum sort stat tr wc; do
  require_cmd "$dependency"
done
[[ -x "$TIME_BIN" ]] || die "missing dependency: $TIME_BIN"
if ! "$TIME_BIN" -v /bin/true >/dev/null 2>&1; then
  die "$TIME_BIN does not support -v"
fi

if [[ -z "$GOMAXPROCS" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    GOMAXPROCS=$(nproc)
  elif command -v getconf >/dev/null 2>&1; then
    GOMAXPROCS=$(getconf _NPROCESSORS_ONLN)
  else
    GOMAXPROCS=1
  fi
fi
[[ "$GOMAXPROCS" =~ ^[1-9][0-9]*$ ]] || die 'could not determine a valid GOMAXPROCS'

if [[ -z "$GOROOT" ]]; then
  require_cmd go
  GOROOT=$(go env GOROOT)
fi
GOROOT=$(absolute_path "$GOROOT")
[[ -d "$GOROOT" ]] || die "GOROOT does not exist: $GOROOT"
[[ -d "$GOROOT/src" ]] || die "GOROOT has no src directory: $GOROOT"

GIT_COMMIT=$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null) || die 'the repository has no readable Git HEAD'
GIT_DESCRIBE=$(git -C "$REPO_ROOT" describe --always --dirty 2>/dev/null || printf 'unknown')
GIT_STATUS_BEFORE="${TMPDIR:-/tmp}/gala-bench-git-status.$$"
trap 'rm -f -- "$GIT_STATUS_BEFORE"' EXIT
git -C "$REPO_ROOT" status --porcelain=v1 > "$GIT_STATUS_BEFORE"
if [[ -s "$GIT_STATUS_BEFORE" ]]; then
  GIT_STATE=dirty
else
  GIT_STATE=clean
fi
GIT_STATUS_SHA256=$(sha256sum "$GIT_STATUS_BEFORE" | awk '{print $1}')

TMP_BASE=${TMPDIR:-/tmp}
[[ -d "$TMP_BASE" ]] || die "temporary directory does not exist: $TMP_BASE"
TMP_BASE=$(CDPATH= cd -- "$TMP_BASE" && pwd -P)

if [[ -z "$OUTPUT" ]]; then
  OUTPUT=$(mktemp -d "$TMP_BASE/gala-transpile-results.XXXXXX")
else
  OUTPUT=$(absolute_path "$OUTPUT")
  mkdir -p "$OUTPUT"
  OUTPUT=$(CDPATH= cd -- "$OUTPUT" && pwd -P)
fi
case "$OUTPUT" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) die "output must be outside the repository: $OUTPUT" ;;
esac
if [[ -n "$PROFILE_DIR" ]]; then
  PROFILE_DIR=$(absolute_path "$PROFILE_DIR")
  mkdir -p "$PROFILE_DIR"
  PROFILE_DIR=$(CDPATH= cd -- "$PROFILE_DIR" && pwd -P)
  case "$PROFILE_DIR" in
    "$REPO_ROOT"|"$REPO_ROOT"/*) die "profile output must be outside the repository: $PROFILE_DIR" ;;
  esac
fi

TMP_ROOT=$(mktemp -d "$TMP_BASE/gala-transpile-bench.XXXXXX")
case "$TMP_ROOT" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) die "temporary stage must be outside the repository: $TMP_ROOT" ;;
esac
cleanup() {
  if [[ -n "${GIT_STATUS_BEFORE:-}" ]]; then
    case "$GIT_STATUS_BEFORE" in
      "${TMPDIR:-/tmp}"/gala-bench-git-status.*) rm -f -- "$GIT_STATUS_BEFORE" ;;
    esac
  fi
  if (( KEEP_STAGE == 0 )) && [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]]; then
    case "$TMP_ROOT" in
      "$TMP_BASE"/gala-transpile-bench.*) rm -rf -- "$TMP_ROOT" ;;
    esac
  fi
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/lists" "$TMP_ROOT/stages" "$TMP_ROOT/runtime" "$TMP_ROOT/orders" "$TMP_ROOT/probe" "$TMP_ROOT/prime" "$TMP_ROOT/values"
mkdir -p "$OUTPUT/logs" "$OUTPUT/profiles"
ACTIVE_STAGE="$TMP_ROOT/active-stage"

SOURCE_GEN_BEFORE="$TMP_ROOT/source-gen.before"
SOURCE_GALA_BEFORE="$TMP_ROOT/source-gala.before"
find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -type f -name '*.gen.go' -print 2>/dev/null | sort > "$SOURCE_GEN_BEFORE"
if [[ -d "$REPO_ROOT/.gala" ]]; then
  find "$REPO_ROOT/.gala" -type f -print 2>/dev/null | sort > "$SOURCE_GALA_BEFORE"
else
  : > "$SOURCE_GALA_BEFORE"
fi

NIX_PACKAGE_FILE="$TMP_ROOT/nix-packages.txt"
awk '
  match($0, /stdlibPkgs[[:space:]]*=[[:space:]]*\[/) {
    inside = 1
    sub(/^.*\[/, "")
  }
  inside {
    line = $0
    sub(/#.*/, "", line)
    gsub(/[",]/, "", line)
    count = split(line, fields, /[[:space:]]+/)
    for (i = 1; i <= count; i++) {
      if (fields[i] ~ /^[[:alnum:]_.-]+$/) print fields[i]
    }
    if ($0 ~ /\]/) exit
  }
' "$NIX_FILE" > "$NIX_PACKAGE_FILE"
[[ -s "$NIX_PACKAGE_FILE" ]] || die "could not derive stdlibPkgs from $NIX_FILE"
mapfile -t ALL_PACKAGES < "$NIX_PACKAGE_FILE"
((${#ALL_PACKAGES[@]} > 0)) || die 'the derived package list is empty'

if (( QUICK_SMOKE )) && [[ -z "$FILTER" ]]; then
  FILTER='^(std/|examples/hello\.gala$)'
fi

matches_filter() {
  local value=$1
  if [[ -z "$FILTER" ]]; then
    return 0
  fi
  if [[ "$value" =~ $FILTER ]]; then
    return 0
  fi
  return 1
}

read_package_name() {
  local source_path=$1
  local value
  value=$(awk '$1 == "package" { print $2; exit }' "$source_path")
  value=${value//$'\r'/}
  printf '%s' "${value:-unknown}"
}

INPUT_RECORDS="$TMP_ROOT/input-records.tsv"
: > "$INPUT_RECORDS"
LIST_DIR="$TMP_ROOT/lists"
declare -a PKG_LABELS PKG_NAMES PKG_LIST_FILES STAGE_SOURCE_DIRS
PKG_COUNT=0
declare -A PKG_INDEX_BY_LABEL PKG_DIR_BY_LABEL PKG_NAME_BY_LABEL PKG_LIST_BY_LABEL
declare -A REL_SOURCE REL_PKGDIR REL_PKGNAME REL_HASH REL_BYTES
declare -A SEEN_SOURCE_DIR

add_input() {
  local rel=$1
  local package_dir=$2
  local package_name=$3
  local source_path=$4
  REL_SOURCE["$rel"]=$source_path
  REL_PKGDIR["$rel"]=$package_dir
  REL_PKGNAME["$rel"]=$package_name
  printf '%s\t%s\t%s\t%s\n' "$rel" "$package_dir" "$package_name" "$source_path" >> "$INPUT_RECORDS"
}

add_package() {
  local label=$1
  local source_dir=$2
  local package_name=$3
  local list_file=$4
  local index=$PKG_COUNT
  PKG_COUNT=$((PKG_COUNT + 1))
  PKG_LABELS+=("$label")
  PKG_NAMES+=("$package_name")
  PKG_LIST_FILES+=("$list_file")
  PKG_INDEX_BY_LABEL["$label"]=$index
  PKG_DIR_BY_LABEL["$label"]=$source_dir
  PKG_NAME_BY_LABEL["$label"]=$package_name
  PKG_LIST_BY_LABEL["$label"]=$list_file
  if [[ -z ${SEEN_SOURCE_DIR["$source_dir"]+x} ]]; then
    SEEN_SOURCE_DIR["$source_dir"]=1
  fi
}

for package_dir in "${ALL_PACKAGES[@]}"; do
  case "$package_dir" in
    ''|.|..|*/*|*[!A-Za-z0-9_.-]*) die "unsafe package name derived from nix/gala.nix: $package_dir" ;;
  esac
  package_path="$REPO_ROOT/$package_dir"
  [[ -d "$package_path" ]] || die "package directory from nix/gala.nix does not exist: $package_dir"
  STAGE_SOURCE_DIRS+=("$package_dir")
  package_list="$LIST_DIR/package-$package_dir.tsv"
  : > "$package_list"
  package_count=0
  shopt -s nullglob
  for source_path in "$package_path"/*.gala; do
    [[ -f "$source_path" ]] || continue
    base_name=${source_path##*/}
    [[ "$base_name" == *_test.gala ]] && continue
    rel_path="$package_dir/$base_name"
    matches_filter "$rel_path" || continue
    package_name=$(read_package_name "$source_path")
    add_input "$rel_path" "$package_dir" "$package_name" "$source_path"
    printf '%s\t%s\n' "$rel_path" "$package_dir" >> "$package_list"
    package_count=$((package_count + 1))
  done
  if (( package_count > 0 )); then
    label=$(safe_component "$package_dir")
    add_package "$label" "$package_dir" "$package_name" "$package_list"
  fi
done
shopt -u nullglob

if (( QUICK_SMOKE )) && [[ -f "$REPO_ROOT/examples/hello.gala" ]]; then
  if matches_filter examples/hello.gala; then
    hello_list="$LIST_DIR/hello.tsv"
    : > "$hello_list"
    hello_name=$(read_package_name "$REPO_ROOT/examples/hello.gala")
    add_input examples/hello.gala examples "$hello_name" "$REPO_ROOT/examples/hello.gala"
    printf '%s\t%s\n' examples/hello.gala hello >> "$hello_list"
    add_package hello examples "$hello_name" "$hello_list"
    STAGE_SOURCE_DIRS+=(examples)
  fi
fi

((${#PKG_LABELS[@]} > 0)) || die 'no selected non-test .gala files remain after filtering'

hash_file() {
  local path=$1
  if [[ -f "$path" ]]; then
    sha256sum "$path" | awk '{print $1}'
  else
    printf 'MISSING'
  fi
}

file_bytes() {
  local path=$1
  if [[ -f "$path" ]]; then
    wc -c < "$path" | tr -d '[:space:]'
  else
    printf 'NA'
  fi
}

clean_stage() {
  local stage=$1
  find "$stage" -type f -name '*.gen.go' -delete 2>/dev/null || true
  find "$stage" -type d -name '.gala' -prune -exec rm -rf -- {} + 2>/dev/null || true
}

new_stage() {
  local stage=$1
  case "$stage" in
    "$TMP_ROOT/active-stage"|"$TMP_ROOT"/stages/*) rm -rf -- "$stage" ;;
    *) die "refusing to reset a stage outside the disposable root: $stage" ;;
  esac
  mkdir -p "$stage"
  local metadata_file
  for metadata_file in gala.mod go.mod go.sum; do
    if [[ -f "$REPO_ROOT/$metadata_file" ]]; then
      cp -p "$REPO_ROOT/$metadata_file" "$stage/$metadata_file"
    fi
  done
  if [[ -f "$REPO_ROOT/internal/stdlib/BUILD.bazel" ]]; then
    mkdir -p "$stage/internal/stdlib"
    cp -p "$REPO_ROOT/internal/stdlib/BUILD.bazel" "$stage/internal/stdlib/BUILD.bazel"
  fi
  local source_dir
  for source_dir in "${STAGE_SOURCE_DIRS[@]}"; do
    mkdir -p "$stage/$source_dir"
    if [[ "$source_dir" == examples ]]; then
      if [[ -f "$REPO_ROOT/examples/hello.gala" ]]; then
        cp -p "$REPO_ROOT/examples/hello.gala" "$stage/examples/hello.gala"
      fi
    else
      cp -a "$REPO_ROOT/$source_dir/." "$stage/$source_dir/"
    fi
  done
  clean_stage "$stage"
}

MANIFEST_STAGE="$ACTIVE_STAGE"
new_stage "$MANIFEST_STAGE"
SEARCH_PATH="$MANIFEST_STAGE"

INPUT_MANIFEST="$OUTPUT/input-manifest.tsv"
MANIFEST="$OUTPUT/manifest.tsv"
printf '%s\n' $'input_path\tstaged_path\tsha256\tbytes\tpackage_dir\tpackage_name\tsearch_paths\tgoroot' > "$INPUT_MANIFEST"
while IFS=$'\t' read -r rel_path package_dir package_name source_path; do
  staged_path="$SEARCH_PATH/$rel_path"
  [[ -f "$staged_path" ]] || die "staged input is missing: $staged_path"
  input_hash=$(hash_file "$source_path")
  input_bytes=$(file_bytes "$source_path")
  REL_HASH["$rel_path"]=$input_hash
  REL_BYTES["$rel_path"]=$input_bytes
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$source_path" "$staged_path" "$input_hash" "$input_bytes" "$package_dir" "$package_name" "$SEARCH_PATH" "$GOROOT" >> "$INPUT_MANIFEST"
done < "$INPUT_RECORDS"
cp "$INPUT_MANIFEST" "$MANIFEST"
sha256sum "$MANIFEST" | awk '{print $1}' > "$OUTPUT/manifest.sha256"

PACKAGE_MANIFEST="$OUTPUT/package-manifest.tsv"
printf '%s\n' $'base_order\tpackage_dir\tpackage_label\tpackage_name\tinput_count' > "$PACKAGE_MANIFEST"
for package_index in "${!PKG_LABELS[@]}"; do
  package_label=${PKG_LABELS[$package_index]}
  package_count=$(wc -l < "${PKG_LIST_FILES[$package_index]}" | tr -d '[:space:]')
  printf '%s\t%s\t%s\t%s\t%s\n' "$((package_index + 1))" "${PKG_DIR_BY_LABEL[$package_label]}" "$package_label" "${PKG_NAME_BY_LABEL[$package_label]}" "$package_count" >> "$PACKAGE_MANIFEST"
done

new_runtime() {
  local runtime=$1
  mkdir -p "$runtime/home" "$runtime/gala-home" "$runtime/gocache" "$runtime/gomodcache" "$runtime/gopath" "$runtime/gotmp" "$runtime/xdg-cache"
}

binary_probe() {
  local binary_index=$1
  local binary_path=${BIN_PATH[$binary_index]}
  local binary_kind=${BIN_KIND[$binary_index]}
  local binary_label=${BIN_LABEL[$binary_index]}
  local probe_dir="$TMP_ROOT/probe/$binary_label"
  new_runtime "$probe_dir/runtime"
  if (cd "$probe_dir" && env HOME="$probe_dir/runtime/home" GALA_HOME="$probe_dir/runtime/gala-home" GOCACHE="$probe_dir/runtime/gocache" GOMODCACHE="$probe_dir/runtime/gomodcache" GOPATH="$probe_dir/runtime/gopath" GOTMPDIR="$probe_dir/runtime/gotmp" XDG_CACHE_HOME="$probe_dir/runtime/xdg-cache" GOROOT="$GOROOT" GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local "$binary_path" --help > "$probe_dir/help.txt" 2>&1); then
    :
  else
    printf '%s\n' 'help probe failed' > "$probe_dir/help.status"
  fi
  if (cd "$probe_dir" && env HOME="$probe_dir/runtime/home" GALA_HOME="$probe_dir/runtime/gala-home" GOCACHE="$probe_dir/runtime/gocache" GOMODCACHE="$probe_dir/runtime/gomodcache" GOPATH="$probe_dir/runtime/gopath" GOTMPDIR="$probe_dir/runtime/gotmp" XDG_CACHE_HOME="$probe_dir/runtime/xdg-cache" GOROOT="$GOROOT" GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local "$binary_path" version > "$probe_dir/version.txt" 2>&1); then
    :
  else
    printf '%s\n' 'version probe unavailable' > "$probe_dir/version.status"
  fi
  if [[ "$binary_kind" == gala ]]; then
    if (cd "$probe_dir" && env HOME="$probe_dir/runtime/home" GALA_HOME="$probe_dir/runtime/gala-home" GOCACHE="$probe_dir/runtime/gocache" GOMODCACHE="$probe_dir/runtime/gomodcache" GOPATH="$probe_dir/runtime/gopath" GOTMPDIR="$probe_dir/runtime/gotmp" XDG_CACHE_HOME="$probe_dir/runtime/xdg-cache" GOROOT="$GOROOT" GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local "$binary_path" transpile-package --help > "$probe_dir/transpile-package-help.txt" 2>&1); then
      help_text=$(<"$probe_dir/transpile-package-help.txt")
      if [[ "$help_text" == *--scan* ]]; then
        BIN_SCAN[$binary_index]=1
      fi
    fi
  fi
}

for binary_index in "${!BIN_PATH[@]}"; do
  binary_probe "$binary_index"
done

BINARIES_MANIFEST="$OUTPUT/binaries.tsv"
printf '%s\n' $'label\tkind\tpath\tsha256\tbytes\tversion_output\tprobe_help' > "$BINARIES_MANIFEST"
for binary_index in "${!BIN_PATH[@]}"; do
  binary_label=${BIN_LABEL[$binary_index]}
  binary_path=${BIN_PATH[$binary_index]}
  binary_hash=$(hash_file "$binary_path")
  binary_bytes=$(file_bytes "$binary_path")
  version_file="$TMP_ROOT/probe/$binary_label/version.txt"
  help_file="$TMP_ROOT/probe/$binary_label/help.txt"
  version_hash=$(hash_file "$version_file")
  help_hash=$(hash_file "$help_file")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$binary_label" "${BIN_KIND[$binary_index]}" "$binary_path" "$binary_hash" "$binary_bytes" "$version_hash" "$help_hash" >> "$BINARIES_MANIFEST"
done

GO_VERSION=
if [[ -x "$GOROOT/bin/go" ]]; then
  GO_VERSION=$("$GOROOT/bin/go" version 2>&1 || true)
elif command -v go >/dev/null 2>&1; then
  GO_VERSION=$(go version 2>&1 || true)
fi
UNAME_VALUE=$(uname -a 2>&1 || printf 'unknown')
TIME_VERSION=$("$TIME_BIN" --version 2>&1 | awk 'NR == 1 {print; exit}')
BAZEL_VERSION=unavailable
if command -v bazel >/dev/null 2>&1; then
  BAZEL_VERSION=$(bazel --version 2>&1 | awk 'NR == 1 {print; exit}' || printf 'unavailable')
fi
NIX_VERSION=unavailable
if command -v nix >/dev/null 2>&1; then
  NIX_VERSION=$(nix --version 2>&1 | awk 'NR == 1 {print; exit}' || printf 'unavailable')
fi
FLAKE_LOCK_SHA256=unavailable
if [[ -f "$REPO_ROOT/flake.lock" ]]; then
  FLAKE_LOCK_SHA256=$(hash_file "$REPO_ROOT/flake.lock")
fi
NIX_FILE_SHA256=$(hash_file "$NIX_FILE")

RUN_ENV="$OUTPUT/run.env"
printf '%s\n' \
  "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "repo_root=$REPO_ROOT" \
  "git_commit=$GIT_COMMIT" \
  "git_describe=$GIT_DESCRIBE" \
  "git_state=$GIT_STATE" \
  "git_status_sha256=$GIT_STATUS_SHA256" \
  "nix_file=$NIX_FILE" \
  "nix_file_sha256=$NIX_FILE_SHA256" \
  "flake_lock_sha256=$FLAKE_LOCK_SHA256" \
  "nix_version=$NIX_VERSION" \
  "bazel_version=$BAZEL_VERSION" \
  "go_version=$GO_VERSION" \
  "goroot=$GOROOT" \
  "platform=$UNAME_VALUE" \
  "time_tool=$TIME_BIN" \
  "time_version=$TIME_VERSION" \
  "stage_root=$TMP_ROOT" \
  "manifest_stage=$MANIFEST_STAGE" \
  "search_paths=$SEARCH_PATH" \
  "output=$OUTPUT" \
  "repetitions=$REPETITIONS" \
  "order=$ORDER" \
  "order_seed=$ORDER_SEED" \
  "gomaxprocs=$GOMAXPROCS" \
  "gc_mode=$GC_MODE" \
  "cache_mode=$CACHE_MODE" \
  "scan_override=$SCAN_OVERRIDE" \
  "profile=$PROFILE" \
  "profile_kind=$PROFILE_KIND" \
  "page_cache=shared OS page cache; no cache dropping performed" \
  "selected_packages=$(join_lines , "${PKG_LABELS[@]}")" \
  "selected_input_count=$(wc -l < "$INPUT_RECORDS" | tr -d '[:space:]')" \
  "baseline=${BASELINE:-none}" > "$RUN_ENV"

RESULTS="$OUTPUT/results.tsv"
OUTPUT_MANIFEST="$OUTPUT/output-manifest.tsv"
ORDERS="$OUTPUT/order.tsv"
PRIMES="$OUTPUT/priming.tsv"
PROFILE_RESULTS="$OUTPUT/profile-results.tsv"
SUMMARY="$OUTPUT/summary.tsv"
SUMMARY_TEXT="$OUTPUT/summary.txt"
AGGREGATE="$OUTPUT/aggregate.tsv"
IDENTITY="$OUTPUT/output-identity.tsv"
COMPARISON="$OUTPUT/comparison.tsv"
BASELINE_OUTPUT_COMPARISON="$OUTPUT/baseline-output-comparison.tsv"
printf '%s\n' $'run_id\tbinary\tbinary_kind\tmode\tgc_mode\tcache_mode\trepetition\torder_index\tpackage\tinput_count\tstatus\twall_seconds\twall_display\tuser_seconds\tsystem_seconds\trss_kb\ttime_exit_status\toutput_set_sha256\tstdout_log\tstderr_log\ttime_log\tanalyzer_cache_root\tcache_generation\tpage_cache\tgogc\tgomemlimit\tgomaxprocs\tsearch_paths\tgoroot' > "$RESULTS"
printf '%s\n' $'run_id\tsource_path\tstaged_path\toutput_path\tsha256\tbytes\tpackage_dir\tpackage_name\tstatus\tbinary\tbinary_kind\tmode\tgc_mode\tcache_mode\trepetition\torder_index\tsearch_paths\tgoroot\tinput_sha256\tinput_bytes\toutput_set_sha256' > "$OUTPUT_MANIFEST"
printf '%s\n' $'variant\tmode\tgc_mode\tcache_mode\trepetition\torder_index\tpackage' > "$ORDERS"
printf '%s\n' $'run_id\tbinary\tmode\tgc_mode\tcache_mode\tpackage\tinput_count\tstatus\twall_seconds\twall_display\tuser_seconds\tsystem_seconds\trss_kb\ttime_exit_status\tstdout_log\tstderr_log\ttime_log' > "$PRIMES"
printf '%s\n' $'binary\tmode\tgc_mode\tpackage\tstatus\twall_seconds\twall_display\tuser_seconds\tsystem_seconds\trss_kb\tprofile_kind\tprofile_artifact\tstdout_log\tstderr_log\ttime_log' > "$PROFILE_RESULTS"

RUN_SERIAL=0
RUN_FAILURE_COUNT=0
PRIMING_FAILURE_COUNT=0
PROFILE_FAILURE_COUNT=0
OUTPUT_MISMATCH_COUNT=0
declare -A GROUP_ID_BY_KEY
declare -A GROUP_TOTAL GROUP_SUCCESS GROUP_FAILURE GROUP_WALL GROUP_USER GROUP_SYSTEM GROUP_RSS
declare -a GROUP_ORDER GROUP_KEY GROUP_PACKAGE
GROUP_NEXT_ID=0

CURRENT_BINARY_INDEX=0
CURRENT_BINARY_LABEL=
CURRENT_BINARY_KIND=
CURRENT_MODE=
CURRENT_GC=
CURRENT_CACHE=

last_group_id() {
  local key=$1
  local id
  if [[ -z ${GROUP_ID_BY_KEY[$key]+x} ]]; then
    id=$GROUP_NEXT_ID
    GROUP_NEXT_ID=$((GROUP_NEXT_ID + 1))
    GROUP_ID_BY_KEY["$key"]=$id
    GROUP_ORDER+=("$id")
    GROUP_KEY+=("$key")
    GROUP_TOTAL[$id]=0
    GROUP_SUCCESS[$id]=0
    GROUP_FAILURE[$id]=0
    GROUP_WALL[$id]=''
    GROUP_USER[$id]=''
    GROUP_SYSTEM[$id]=''
    GROUP_RSS[$id]=''
  fi
  LAST_GROUP_ID=${GROUP_ID_BY_KEY[$key]}
}

add_group_value() {
  local key=$1
  local status=$2
  local wall=$3
  local user=$4
  local system=$5
  local rss=$6
  local id
  last_group_id "$key"
  id=$LAST_GROUP_ID
  GROUP_TOTAL[$id]=$(( ${GROUP_TOTAL[$id]-0} + 1 ))
  if [[ "$status" == 0 ]]; then
    GROUP_SUCCESS[$id]=$(( ${GROUP_SUCCESS[$id]-0} + 1 ))
    if [[ "$wall" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      GROUP_WALL[$id]="${GROUP_WALL[$id]}$wall"$'\n'
    fi
    if [[ "$user" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      GROUP_USER[$id]="${GROUP_USER[$id]}$user"$'\n'
    fi
    if [[ "$system" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      GROUP_SYSTEM[$id]="${GROUP_SYSTEM[$id]}$system"$'\n'
    fi
    if [[ "$rss" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      GROUP_RSS[$id]="${GROUP_RSS[$id]}$rss"$'\n'
    fi
  else
    GROUP_FAILURE[$id]=$(( ${GROUP_FAILURE[$id]-0} + 1 ))
  fi
}

time_field() {
  local time_file=$1
  local label=$2
  if [[ ! -f "$time_file" ]]; then
    printf 'NA'
    return
  fi
  awk -v label="$label" '
    {
      position = index($0, label)
      if (position > 0) {
        value = substr($0, position + length(label))
        sub(/^:[[:space:]]*/, "", value)
        print value
        exit
      }
    }
  ' "$time_file"
}

wall_seconds() {
  local raw=${1:-NA}
  raw=${raw//[[:space:]]/}
  if [[ "$raw" == NA || -z "$raw" ]]; then
    printf 'NA'
    return
  fi
  if [[ "$raw" == *:* ]]; then
    awk -F: -v value="$raw" 'BEGIN { count = split(value, parts, ":"); total = 0; multiplier = 1; for (i = count; i >= 1; i--) { total += parts[i] * multiplier; multiplier *= 60 } printf "%.9f\n", total }'
  else
    awk -v value="$raw" 'BEGIN { print value }'
  fi
}

run_timed() {
  local stage=$1
  local runtime=$2
  local gc=$3
  local logbase=$4
  local profile_kind=$5
  local profile_artifact=$6
  shift 6
  local stdout_log="$logbase.stdout"
  local stderr_log="$logbase.stderr"
  local time_log="$logbase.time"
  mkdir -p "$(dirname -- "$stdout_log")"
  local -a env_command=(env -u GALA_PROFILE -u GALA_CPUPROFILE -u GALA_HEAP_DUMP_DIR -u GALA_HEAP_DUMP_BAND_MB)
  local effective_gogc=unset
  local effective_gomemlimit=unset
  if [[ "$gc" == tuned ]]; then
    env_command+=(GOGC=300 GOMEMLIMIT=6GiB)
    effective_gogc=300
    effective_gomemlimit=6GiB
  fi
  env_command+=(
    "HOME=$runtime/home"
    "GALA_HOME=$runtime/gala-home"
    "GOCACHE=$runtime/gocache"
    "GOMODCACHE=$runtime/gomodcache"
    "GOPATH=$runtime/gopath"
    "GOTMPDIR=$runtime/gotmp"
    "XDG_CACHE_HOME=$runtime/xdg-cache"
    "GALA_KEEP_STALE_CACHES=1"
    "GOROOT=$GOROOT"
    "GOPROXY=off"
    "GOSUMDB=off"
    "GOTOOLCHAIN=local"
    "GOMAXPROCS=$GOMAXPROCS"
  )
  case "$profile_kind" in
    phase) env_command+=(GALA_PROFILE=1) ;;
    cpu) env_command+=("GALA_CPUPROFILE=$profile_artifact") ;;
    heap) env_command+=("GALA_HEAP_DUMP_DIR=$profile_artifact" GALA_HEAP_DUMP_BAND_MB=250) ;;
    all) env_command+=(GALA_PROFILE=1 "GALA_CPUPROFILE=$profile_artifact/heap.pprof" "GALA_HEAP_DUMP_DIR=$profile_artifact" GALA_HEAP_DUMP_BAND_MB=250) ;;
  esac
  if (cd "$stage" && "$TIME_BIN" -v -o "$time_log" "${env_command[@]}" "$@") > "$stdout_log" 2> "$stderr_log"; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
  LAST_WALL_DISPLAY=$(time_field "$time_log" 'Elapsed (wall clock) time (h:mm:ss or m:ss)')
  LAST_WALL_SECONDS=$(wall_seconds "$LAST_WALL_DISPLAY")
  LAST_USER_SECONDS=$(time_field "$time_log" 'User time (seconds)')
  LAST_SYSTEM_SECONDS=$(time_field "$time_log" 'System time (seconds)')
  LAST_RSS_KB=$(time_field "$time_log" 'Maximum resident set size (kbytes)')
  LAST_TIME_STATUS=$(time_field "$time_log" 'Exit status')
  [[ -n "$LAST_WALL_DISPLAY" ]] || LAST_WALL_DISPLAY=NA
  [[ -n "$LAST_WALL_SECONDS" ]] || LAST_WALL_SECONDS=NA
  [[ -n "$LAST_USER_SECONDS" ]] || LAST_USER_SECONDS=NA
  [[ -n "$LAST_SYSTEM_SECONDS" ]] || LAST_SYSTEM_SECONDS=NA
  [[ -n "$LAST_RSS_KB" ]] || LAST_RSS_KB=NA
  [[ -n "$LAST_TIME_STATUS" ]] || LAST_TIME_STATUS=NA
  LAST_STDOUT_LOG=$stdout_log
  LAST_STDERR_LOG=$stderr_log
  LAST_TIME_LOG=$time_log
  LAST_EFFECTIVE_GOGC=$effective_gogc
  LAST_EFFECTIVE_GOMEMLIMIT=$effective_gomemlimit
}

make_mapping() {
  local rel_file=$1
  local stage=$2
  local output_root=$3
  local mapping_file=$4
  mkdir -p "$(dirname -- "$mapping_file")"
  : > "$mapping_file"
  mkdir -p "$output_root"
  local rel_path package_label staged_path output_path
  while IFS=$'\t' read -r rel_path package_label; do
    [[ -n "$rel_path" ]] || continue
    staged_path="$stage/$rel_path"
    output_path="$output_root/${rel_path%.gala}.gen.go"
    mkdir -p "$(dirname -- "$output_path")"
    printf '%s\t%s\t%s\t%s\n' "$rel_path" "$staged_path" "$output_path" "$package_label" >> "$mapping_file"
  done < "$rel_file"
}

make_batch_rel_file() {
  local order_file=$1
  local output_file=$2
  mkdir -p "$(dirname -- "$output_file")"
  : > "$output_file"
  local package_label list_file rel_path
  while IFS= read -r package_label; do
    [[ -n "$package_label" ]] || continue
    list_file=${PKG_LIST_BY_LABEL[$package_label]}
    if [[ -f "$list_file" ]]; then
      while IFS=$'\t' read -r rel_path _; do
        printf '%s\t%s\n' "$rel_path" "$package_label" >> "$output_file"
      done < "$list_file"
    fi
  done < "$order_file"
}

make_order() {
  local repetition=$1
  local salt=$2
  local output_file=$3
  local -a ordered=("${PKG_LABELS[@]}")
  local count=${#ordered[@]}
  local i j temporary offset seed
  case "$ORDER" in
    lexicographic)
      mapfile -t ordered < <(printf '%s\n' "${ordered[@]}" | sort)
      ;;
    rotated)
      offset=$(( (repetition - 1 + salt) % count ))
      for ((i = 0; i < count; i++)); do
        printf '%s\n' "${ordered[$(((i + offset) % count))]}"
      done > "$output_file"
      return
      ;;
    randomized)
      seed=$(( (ORDER_SEED + repetition * 104729 + salt) % 2147483647 ))
      (( seed > 0 )) || seed=1
      for ((i = count - 1; i > 0; i--)); do
        seed=$(( (seed * 48271) % 2147483647 ))
        j=$(( seed % (i + 1) ))
        temporary=${ordered[$i]}
        ordered[$i]=${ordered[$j]}
        ordered[$j]=$temporary
      done
      ;;
  esac
  printf '%s\n' "${ordered[@]}" > "$output_file"
}

join_csv() {
  local mapping_file=$1
  local column=$2
  awk -F '\t' -v column="$column" 'BEGIN { first = 1 } { if (!first) printf ","; printf $column; first = 0 } END { if (first) exit 1 }' "$mapping_file"
}

run_invoke() {
  local binary_index=$1
  local stage=$2
  local runtime=$3
  local gc=$4
  local mode=$5
  local mapping_file=$6
  local logbase=$7
  local profile_kind=${8:-none}
  local profile_artifact=${9:-}
  local binary_path=${BIN_PATH[$binary_index]}
  local binary_kind=${BIN_KIND[$binary_index]}
  local inputs_csv outputs_csv
  inputs_csv=$(join_csv "$mapping_file" 1)
  outputs_csv=$(join_csv "$mapping_file" 3)
  [[ -n "$inputs_csv" && -n "$outputs_csv" ]] || die 'internal error: empty benchmark invocation'
  local -a command
  if [[ "$binary_kind" == bootstrap ]]; then
    command=("$binary_path" -inputs "$inputs_csv" -outputs "$outputs_csv" -search "$stage" -goroot "$GOROOT")
  else
    command=("$binary_path" transpile-package --inputs "$inputs_csv" --outputs "$outputs_csv" --search "$stage" --goroot "$GOROOT")
    if [[ "$mode" == batch ]]; then
      if [[ "$SCAN_OVERRIDE" == yes ]]; then
        [[ ${BIN_SCAN[$binary_index]} == 1 ]] || die 'scan requested for a binary whose transpile-package help did not advertise --scan'
        command+=(--scan)
      elif [[ "$SCAN_OVERRIDE" == auto ]]; then
        if [[ ${BIN_SCAN[$binary_index]} == 1 ]]; then
          command+=(--scan)
        else
          die "batch mode requires --scan, but ${BIN_LABEL[$binary_index]} does not support it; use per-package mode for this binary"
        fi
      fi
    fi
  fi
  run_timed "$stage" "$runtime" "$gc" "$logbase" "$profile_kind" "$profile_artifact" "${command[@]}"
}

append_prime() {
  local package_label=$1
  local input_count=$2
  local stage=$3
  local logbase=$4
  local mapping_file=$5
  local status=$6
  local set_file="$logbase.output-set.tsv"
  : > "$set_file"
  local rel_path staged_path output_path output_hash
  while IFS=$'\t' read -r rel_path staged_path output_path _; do
    output_hash=$(hash_file "$output_path")
    printf '%s\t%s\n' "$rel_path" "$output_hash" >> "$set_file"
  done < "$mapping_file"
  sort -t $'\t' -k1,1 "$set_file" -o "$set_file"
  local output_set_hash
  output_set_hash=$(hash_file "$set_file")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$RUN_SERIAL" "$CURRENT_BINARY_LABEL" "$CURRENT_MODE" "$CURRENT_GC" "$CURRENT_CACHE" "$package_label" "$input_count" "$status" \
    "$LAST_WALL_SECONDS" "$LAST_WALL_DISPLAY" "$LAST_USER_SECONDS" "$LAST_SYSTEM_SECONDS" "$LAST_RSS_KB" "$LAST_TIME_STATUS" \
    "$LAST_STDOUT_LOG" "$LAST_STDERR_LOG" "$LAST_TIME_LOG" >> "$PRIMES"
  if [[ "$status" != 0 ]]; then
    PRIMING_FAILURE_COUNT=$((PRIMING_FAILURE_COUNT + 1))
  fi
}

append_result() {
  local package_label=$1
  local repetition=$2
  local order_index=$3
  local stage=$4
  local runtime=$5
  local mapping_file=$6
  local logbase=$7
  local cache_generation=$8
  local status=$9
  local input_count=${10}
  local set_file="$logbase.output-set.tsv"
  : > "$set_file"
  local rel_path staged_path output_path package_label_from_mapping output_hash
  while IFS=$'\t' read -r rel_path staged_path output_path package_label_from_mapping; do
    [[ -n "$rel_path" ]] || continue
    output_hash=$(hash_file "$output_path")
    printf '%s\t%s\n' "$rel_path" "$output_hash" >> "$set_file"
  done < "$mapping_file"
  sort -t $'\t' -k1,1 "$set_file" -o "$set_file"
  local output_set_hash
  output_set_hash=$(hash_file "$set_file")
  RUN_SERIAL=$((RUN_SERIAL + 1))
  local run_id
  run_id=$(printf 'run-%06d' "$RUN_SERIAL")
  local analyzer_cache_root="$stage/.gala/cache"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$CURRENT_BINARY_LABEL" "$CURRENT_BINARY_KIND" "$CURRENT_MODE" "$CURRENT_GC" "$CURRENT_CACHE" "$repetition" "$order_index" "$package_label" "$input_count" "$status" \
    "$LAST_WALL_SECONDS" "$LAST_WALL_DISPLAY" "$LAST_USER_SECONDS" "$LAST_SYSTEM_SECONDS" "$LAST_RSS_KB" "$LAST_TIME_STATUS" "$output_set_hash" "$LAST_STDOUT_LOG" "$LAST_STDERR_LOG" "$LAST_TIME_LOG" \
    "$analyzer_cache_root" "$cache_generation" 'shared OS page cache; unchanged' "$LAST_EFFECTIVE_GOGC" "$LAST_EFFECTIVE_GOMEMLIMIT" "$GOMAXPROCS" "$stage" "$GOROOT" >> "$RESULTS"
  while IFS=$'\t' read -r rel_path staged_path output_path package_label_from_mapping; do
    [[ -n "$rel_path" ]] || continue
    output_hash=$(hash_file "$output_path")
    local package_dir=${REL_PKGDIR[$rel_path]}
    local package_name=${REL_PKGNAME[$rel_path]}
    local input_hash=${REL_HASH[$rel_path]-NA}
    local input_bytes=${REL_BYTES[$rel_path]-NA}
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$run_id" "${REL_SOURCE[$rel_path]}" "$staged_path" "$output_path" "$output_hash" "$(file_bytes "$output_path")" "$package_dir" "$package_name" "$status" "$CURRENT_BINARY_LABEL" "$CURRENT_BINARY_KIND" \
      "$CURRENT_MODE" "$CURRENT_GC" "$CURRENT_CACHE" "$repetition" "$order_index" "$stage" "$GOROOT" "$input_hash" "$input_bytes" "$output_set_hash" >> "$OUTPUT_MANIFEST"
  done < "$mapping_file"
  if [[ "$status" != 0 ]]; then
    RUN_FAILURE_COUNT=$((RUN_FAILURE_COUNT + 1))
  fi
  add_group_value "$CURRENT_BINARY_LABEL|$CURRENT_MODE|$CURRENT_GC|$CURRENT_CACHE|$package_label" "$status" "$LAST_WALL_SECONDS" "$LAST_USER_SECONDS" "$LAST_SYSTEM_SECONDS" "$LAST_RSS_KB"
  add_group_value "$CURRENT_BINARY_LABEL|$CURRENT_MODE|$CURRENT_GC|$CURRENT_CACHE|__all__" "$status" "$LAST_WALL_SECONDS" "$LAST_USER_SECONDS" "$LAST_SYSTEM_SECONDS" "$LAST_RSS_KB"
}

run_profile() {
  local package_label=$1
  local stage=$2
  local runtime=$3
  local mapping_file=$4
  local logbase=$5
  local artifact_dir="$logbase.artifacts"
  if [[ -n "$PROFILE_DIR" ]]; then
    artifact_dir="$PROFILE_DIR/$(safe_component "$CURRENT_BINARY_LABEL-$CURRENT_MODE-$package_label")"
  fi
  mkdir -p "$artifact_dir"
  local artifact=''
  case "$PROFILE_KIND" in
    cpu) artifact="$artifact_dir/cpu.pprof" ;;
    heap)
      artifact="$artifact_dir/heap"
      mkdir -p "$artifact"
      ;;
    all) artifact="$artifact_dir" ;;
    phase) artifact="$artifact_dir/phase.txt" ;;
  esac
  run_invoke "$CURRENT_BINARY_INDEX" "$stage" "$runtime" "$CURRENT_GC" batch "$mapping_file" "$logbase" "$PROFILE_KIND" "$artifact"
  local profile_status=$LAST_STATUS
  if [[ "$PROFILE_KIND" == phase ]]; then
    cp -- "$LAST_STDERR_LOG" "$artifact"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$CURRENT_BINARY_LABEL" batch "$CURRENT_GC" "$package_label" "$profile_status" "$LAST_WALL_SECONDS" "$LAST_WALL_DISPLAY" "$LAST_USER_SECONDS" "$LAST_SYSTEM_SECONDS" "$LAST_RSS_KB" "$PROFILE_KIND" "$artifact" "$LAST_STDOUT_LOG" "$LAST_STDERR_LOG" "$LAST_TIME_LOG" >> "$PROFILE_RESULTS"
  if [[ "$profile_status" != 0 ]]; then
    PROFILE_FAILURE_COUNT=$((PROFILE_FAILURE_COUNT + 1))
  fi
  clean_stage "$stage"
}

run_variant() {
  local binary_index=$1
  local mode=$2
  local gc=$3
  local cache=$4
  local binary_label=${BIN_LABEL[$binary_index]}
  local variant_id
  variant_id=$(safe_component "$binary_label-$mode-$gc-$cache")
  local context="$OUTPUT/work/$variant_id"
  mkdir -p "$context"
  CURRENT_BINARY_INDEX=$binary_index
  CURRENT_BINARY_LABEL=$binary_label
  CURRENT_BINARY_KIND=${BIN_KIND[$binary_index]}
  CURRENT_MODE=$mode
  CURRENT_GC=$gc
  CURRENT_CACHE=$cache
  local warm_stage='' warm_runtime=''
  if [[ "$cache" == warm ]]; then
    warm_stage="$ACTIVE_STAGE"
    warm_runtime="$TMP_ROOT/runtime/$variant_id-warm"
    new_stage "$warm_stage"
    new_runtime "$warm_runtime"
    make_order 1 0 "$TMP_ROOT/orders/$variant_id-prime"
    if [[ "$mode" == per-package ]]; then
      while IFS= read -r package_label; do
        [[ -n "$package_label" ]] || continue
        package_index=${PKG_INDEX_BY_LABEL[$package_label]}
        rel_file="$TMP_ROOT/prime/$variant_id-$package_label.tsv"
        mapping_file="$TMP_ROOT/prime/$variant_id-$package_label.mapping.tsv"
        output_root="$context/prime/$package_label"
        logbase="$context/prime-logs/$package_label"
        make_mapping "${PKG_LIST_FILES[$package_index]}" "$warm_stage" "$output_root" "$mapping_file"
        run_invoke "$binary_index" "$warm_stage" "$warm_runtime" "$gc" per-package "$mapping_file" "$logbase" none ''
        input_count=$(wc -l < "${PKG_LIST_FILES[$package_index]}" | tr -d '[:space:]')
        append_prime "$package_label" "$input_count" "$warm_stage" "$logbase" "$mapping_file" "$LAST_STATUS"
      done < "$TMP_ROOT/orders/$variant_id-prime"
    else
      batch_rel="$TMP_ROOT/prime/$variant_id-batch.tsv"
      make_batch_rel_file "$TMP_ROOT/orders/$variant_id-prime" "$batch_rel"
      mapping_file="$TMP_ROOT/prime/$variant_id-batch.mapping.tsv"
      output_root="$context/prime/batch"
      logbase="$context/prime-logs/batch"
      make_mapping "$batch_rel" "$warm_stage" "$output_root" "$mapping_file"
      run_invoke "$binary_index" "$warm_stage" "$warm_runtime" "$gc" batch "$mapping_file" "$logbase" none ''
      append_prime __batch__ "$(wc -l < "$batch_rel" | tr -d '[:space:]')" "$warm_stage" "$logbase" "$mapping_file" "$LAST_STATUS"
    fi
  fi
  local repetition package_label order_index package_index rel_file mapping_file output_root logbase stage runtime cache_generation batch_rel
  for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
    salt=0
    [[ "$mode" == batch ]] && salt=1000003
    order_file="$TMP_ROOT/orders/$variant_id-r$repetition"
    make_order "$repetition" "$salt" "$order_file"
    if [[ "$mode" == batch ]]; then
      order_line=0
      while IFS= read -r package_label; do
        [[ -n "$package_label" ]] || continue
        order_line=$((order_line + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$variant_id" "$mode" "$gc" "$cache" "$repetition" "$order_line" "$package_label" >> "$ORDERS"
      done < "$order_file"
      batch_rel="$OUTPUT/work/$variant_id/orders/r$repetition.tsv"
      make_batch_rel_file "$order_file" "$batch_rel"
      if [[ "$cache" == cold ]]; then
        stage="$ACTIVE_STAGE"
        runtime="$TMP_ROOT/runtime/$variant_id-r$repetition-batch"
        new_stage "$stage"
        new_runtime "$runtime"
        cache_generation=cold-fresh-r$repetition
      else
        stage=$warm_stage
        runtime=$warm_runtime
        cache_generation=warm-primed
      fi
      output_root="$OUTPUT/work/$variant_id/outputs/r$repetition/batch"
      logbase="$OUTPUT/work/$variant_id/logs/r$repetition/batch"
      mapping_file="$OUTPUT/work/$variant_id/mappings/r$repetition/batch.tsv"
      make_mapping "$batch_rel" "$stage" "$output_root" "$mapping_file"
      run_invoke "$binary_index" "$stage" "$runtime" "$gc" batch "$mapping_file" "$logbase" none ''
      input_count=$(wc -l < "$batch_rel" | tr -d '[:space:]')
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$variant_id" "$mode" "$gc" "$cache" "$repetition" 0 __batch__ >> "$ORDERS"
      append_result __batch__ "$repetition" 0 "$stage" "$runtime" "$mapping_file" "$logbase" "$cache_generation" "$LAST_STATUS" "$input_count"
      if [[ "$cache" == cold ]]; then
        clean_stage "$stage"
      fi
      continue
    fi
    order_line=0
    while IFS= read -r package_label; do
      [[ -n "$package_label" ]] || continue
      order_line=$((order_line + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$variant_id" "$mode" "$gc" "$cache" "$repetition" "$order_line" "$package_label" >> "$ORDERS"
      if [[ "$mode" == per-package ]]; then
        package_index=${PKG_INDEX_BY_LABEL[$package_label]}
        rel_file="${PKG_LIST_FILES[$package_index]}"
        if [[ "$cache" == cold ]]; then
          stage="$ACTIVE_STAGE"
          runtime="$TMP_ROOT/runtime/$variant_id-r$repetition-p$package_index"
          new_stage "$stage"
          new_runtime "$runtime"
          cache_generation=cold-fresh-r$repetition
        else
          stage=$warm_stage
          runtime=$warm_runtime
          cache_generation=warm-primed
        fi
        output_root="$OUTPUT/work/$variant_id/outputs/r$repetition/$package_label"
        logbase="$OUTPUT/work/$variant_id/logs/r$repetition/$package_label"
        mapping_file="$OUTPUT/work/$variant_id/mappings/r$repetition/$package_label.tsv"
        make_mapping "$rel_file" "$stage" "$output_root" "$mapping_file"
        run_invoke "$binary_index" "$stage" "$runtime" "$gc" per-package "$mapping_file" "$logbase" none ''
        input_count=$(wc -l < "$rel_file" | tr -d '[:space:]')
        append_result "$package_label" "$repetition" "$order_line" "$stage" "$runtime" "$mapping_file" "$logbase" "$cache_generation" "$LAST_STATUS" "$input_count"
        if [[ "$cache" == cold ]]; then
          clean_stage "$stage"
        fi
      else
        batch_rel="$OUTPUT/work/$variant_id/orders/r$repetition.tsv"
        make_batch_rel_file "$order_file" "$batch_rel"
        if [[ "$cache" == cold ]]; then
          stage="$ACTIVE_STAGE"
          runtime="$TMP_ROOT/runtime/$variant_id-r$repetition-batch"
          new_stage "$stage"
          new_runtime "$runtime"
          cache_generation=cold-fresh-r$repetition
        else
          stage=$warm_stage
          runtime=$warm_runtime
          cache_generation=warm-primed
        fi
        output_root="$OUTPUT/work/$variant_id/outputs/r$repetition/batch"
        logbase="$OUTPUT/work/$variant_id/logs/r$repetition/batch"
        mapping_file="$OUTPUT/work/$variant_id/mappings/r$repetition/batch.tsv"
        make_mapping "$batch_rel" "$stage" "$output_root" "$mapping_file"
        run_invoke "$binary_index" "$stage" "$runtime" "$gc" batch "$mapping_file" "$logbase" none ''
        input_count=$(wc -l < "$batch_rel" | tr -d '[:space:]')
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$variant_id" "$mode" "$gc" "$cache" "$repetition" 0 __batch__ >> "$ORDERS"
        append_result __batch__ "$repetition" 0 "$stage" "$runtime" "$mapping_file" "$logbase" "$cache_generation" "$LAST_STATUS" "$input_count"
        if [[ "$cache" == cold ]]; then
          clean_stage "$stage"
        fi
      fi
    done < "$order_file"
  done
  if [[ "$cache" == warm ]]; then
    clean_stage "$warm_stage"
  fi
  if (( PROFILE )); then
    if [[ "$mode" == batch ]]; then
      profile_rel="$OUTPUT/work/$variant_id/profile-order.tsv"
      make_order 1 0 "$profile_rel"
      make_batch_rel_file "$profile_rel" "$OUTPUT/work/$variant_id/profile-rel.tsv"
      profile_stage="$ACTIVE_STAGE"
      profile_runtime="$TMP_ROOT/runtime/$variant_id-profile"
      new_stage "$profile_stage"
      new_runtime "$profile_runtime"
      profile_mapping="$OUTPUT/work/$variant_id/profile-mapping.tsv"
      make_mapping "$OUTPUT/work/$variant_id/profile-rel.tsv" "$profile_stage" "$context/profiles/batch" "$profile_mapping"
      run_profile __batch__ "$profile_stage" "$profile_runtime" "$profile_mapping" "$context/profiles/batch"
    else
      profile_order="$OUTPUT/work/$variant_id/profile-order.txt"
      make_order 1 0 "$profile_order"
      while IFS= read -r package_label; do
        [[ -n "$package_label" ]] || continue
        package_index=${PKG_INDEX_BY_LABEL[$package_label]}
        profile_stage="$ACTIVE_STAGE"
        profile_runtime="$TMP_ROOT/runtime/$variant_id-profile-$package_label"
        new_stage "$profile_stage"
        new_runtime "$profile_runtime"
        profile_mapping="$OUTPUT/work/$variant_id/profile-$package_label.mapping.tsv"
        make_mapping "${PKG_LIST_FILES[$package_index]}" "$profile_stage" "$context/profiles/$package_label" "$profile_mapping"
        run_profile "$package_label" "$profile_stage" "$profile_runtime" "$profile_mapping" "$context/profiles/$package_label"
      done < "$profile_order"
    fi
  fi
}

MODE_LIST=()
if [[ "$MODE" == both ]]; then
  MODE_LIST=(per-package batch)
else
  MODE_LIST=("$MODE")
fi
GC_LIST=()
if [[ "$GC_MODE" == both ]]; then
  GC_LIST=(default tuned)
else
  GC_LIST=("$GC_MODE")
fi
CACHE_LIST=()
if [[ "$CACHE_MODE" == both ]]; then
  CACHE_LIST=(cold warm)
else
  CACHE_LIST=("$CACHE_MODE")
fi

for binary_index in "${!BIN_PATH[@]}"; do
  for mode in "${MODE_LIST[@]}"; do
    for gc in "${GC_LIST[@]}"; do
      for cache in "${CACHE_LIST[@]}"; do
        run_variant "$binary_index" "$mode" "$gc" "$cache"
      done
    done
  done
done

summarize_numbers() {
  local values=$1
  local metric=$2
  local value_file="$TMP_ROOT/values/$metric"
  printf '%s' "$values" > "$value_file"
  sort -n "$value_file" | awk '
    {
      values[NR] = $1
      sum += $1
    }
    END {
      if (NR == 0) {
        print "0 NA NA NA NA 0"
        exit
      }
      if (NR % 2 == 1) median = values[(NR + 1) / 2]
      else median = (values[NR / 2] + values[NR / 2 + 1]) / 2
      p95_index = int((95 * NR + 99) / 100)
      if (p95_index < 1) p95_index = 1
      printf "%d %.9f %.9f %.9f %.9f %.9f\n", NR, median, values[p95_index], values[1], values[NR], sum / NR
    }
  '
}

write_aggregates() {
  local aggregate="$OUTPUT/aggregate.tsv"
  printf '%s\n' $'binary\tmode\tgc_mode\tcache_mode\trepetition\tn_success\tn_failure\tinput_count\twall_seconds\tuser_seconds\tsystem_seconds\trss_kb_max' > "$aggregate"
  awk -F '\t' '
    NR == 1 { next }
    {
      key = $2 "\034" $4 "\034" $5 "\034" $6 "\034" $7
      if (!(key in seen)) {
        seen[key] = 1
        order[++count] = key
        binary[key] = $2
        mode[key] = $4
        gc[key] = $5
        cache[key] = $6
        repetition[key] = $7
      }
      input_count[key] += $10
      if ($11 == 0) success[key]++; else failure[key]++
      wall[key] += $12
      user[key] += $14
      sys[key] += $15
      if ($16 > rss[key]) rss[key] = $16
    }
    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%.9f\t%.9f\t%.9f\t%.9f\n", binary[key], mode[key], gc[key], cache[key], repetition[key], success[key] + 0, failure[key] + 0, input_count[key] + 0, wall[key] + 0, user[key] + 0, sys[key] + 0, rss[key] + 0
      }
    }
  ' "$RESULTS" | sort -t $'\t' -k1,1 -k2,2 -k3,3 -k4,4 -k5,5n >> "$aggregate"
}

write_aggregate_summary() {
  local aggregate_summary="$OUTPUT/aggregate-summary.tsv"
  printf '%s\n' $'binary\tmode\tgc_mode\tcache_mode\trepetitions\twall_median\twall_p95\tuser_median\tuser_p95\tsystem_median\tsystem_p95\trss_kb_median\trss_kb_p95' > "$aggregate_summary"
  local binary mode gc cache repetition key wall_values user_values system_values rss_values wall_stats user_stats system_stats rss_stats
  while IFS=$'\t' read -r binary mode gc cache repetition _; do
    [[ "$binary" == binary ]] && continue
    [[ -n "$binary" ]] || continue
    key="$binary|$mode|$gc|$cache"
    if [[ -n "${AGGREGATE_SEEN[$key]+x}" ]]; then
      continue
    fi
    AGGREGATE_SEEN[$key]=1
    wall_values=$(awk -F '\t' -v b="$binary" -v m="$mode" -v g="$gc" -v c="$cache" 'NR > 1 && $1 == b && $2 == m && $3 == g && $4 == c { print $9 }' "$AGGREGATE")
    user_values=$(awk -F '\t' -v b="$binary" -v m="$mode" -v g="$gc" -v c="$cache" 'NR > 1 && $1 == b && $2 == m && $3 == g && $4 == c { print $10 }' "$AGGREGATE")
    system_values=$(awk -F '\t' -v b="$binary" -v m="$mode" -v g="$gc" -v c="$cache" 'NR > 1 && $1 == b && $2 == m && $3 == g && $4 == c { print $11 }' "$AGGREGATE")
    rss_values=$(awk -F '\t' -v b="$binary" -v m="$mode" -v g="$gc" -v c="$cache" 'NR > 1 && $1 == b && $2 == m && $3 == g && $4 == c { print $12 }' "$AGGREGATE")
    wall_stats=$(summarize_numbers "$wall_values" "aggregate-wall-$(safe_component "$key")")
    user_stats=$(summarize_numbers "$user_values" "aggregate-user-$(safe_component "$key")")
    system_stats=$(summarize_numbers "$system_values" "aggregate-system-$(safe_component "$key")")
    rss_stats=$(summarize_numbers "$rss_values" "aggregate-rss-$(safe_component "$key")")
    read -r repetitions _ _ _ _ _ <<< "$wall_stats"
    read -r _ wall_median wall_p95 _ _ _ <<< "$wall_stats"
    read -r _ user_median user_p95 _ _ _ <<< "$user_stats"
    read -r _ system_median system_p95 _ _ _ <<< "$system_stats"
    read -r _ rss_median rss_p95 _ _ _ <<< "$rss_stats"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$binary" "$mode" "$gc" "$cache" "$repetitions" "$wall_median" "$wall_p95" "$user_median" "$user_p95" "$system_median" "$system_p95" "$rss_median" "$rss_p95" >> "$aggregate_summary"
  done < "$AGGREGATE"
}

declare -A AGGREGATE_SEEN

write_summary() {
  local rows_file="$TMP_ROOT/summary.rows"
  : > "$rows_file"
  local group_id key n_success n_total failures wall_stats user_stats system_stats rss_stats
  for group_id in "${GROUP_ORDER[@]}"; do
    key=${GROUP_KEY[$group_id]}
    IFS='|' read -r binary_label mode gc cache package_label <<< "$key"
    n_success=${GROUP_SUCCESS[$group_id]}
    n_total=${GROUP_TOTAL[$group_id]}
    failures=${GROUP_FAILURE[$group_id]}
    wall_stats=$(summarize_numbers "${GROUP_WALL[$group_id]}" "wall-$group_id")
    user_stats=$(summarize_numbers "${GROUP_USER[$group_id]}" "user-$group_id")
    system_stats=$(summarize_numbers "${GROUP_SYSTEM[$group_id]}" "system-$group_id")
    rss_stats=$(summarize_numbers "${GROUP_RSS[$group_id]}" "rss-$group_id")
    read -r _ wall_median wall_p95 _ _ _ <<< "$wall_stats"
    read -r _ user_median user_p95 _ _ _ <<< "$user_stats"
    read -r _ system_median system_p95 _ _ _ <<< "$system_stats"
    read -r _ rss_median rss_p95 _ _ _ <<< "$rss_stats"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$binary_label" "$mode" "$gc" "$cache" "$package_label" "$n_success" "$n_total" "$failures" "$wall_median" "$wall_p95" "$user_median" "$user_p95" "$system_median" "$system_p95" "$rss_median" "$rss_p95" >> "$rows_file"
  done
  printf '%s\n' $'binary\tmode\tgc_mode\tcache_mode\tpackage\tn_success\tn_total\tfailures\twall_median\twall_p95\tuser_median\tuser_p95\tsystem_median\tsystem_p95\trss_kb_median\trss_kb_p95' > "$SUMMARY"
  sort -t $'\t' -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 "$rows_file" >> "$SUMMARY"
  awk -F '\t' 'NR == 1 { print "binary mode gc cache package n wall_median wall_p95 user_median user_p95 system_median system_p95 rss_kb_median rss_kb_p95"; next } { printf "%s %s %s %s %s %s %s %s %s %s %s %s %s %s\n", $1, $2, $3, $4, $5, $6, $9, $10, $11, $12, $13, $14, $15, $16 }' "$SUMMARY" > "$SUMMARY_TEXT"
}

write_aggregates
write_summary
write_aggregate_summary

write_identity() {
  local sorted_file="$TMP_ROOT/output-manifest.sorted"
  sort -t $'\t' -k2,2 -k1,1 "$OUTPUT_MANIFEST" > "$sorted_file"
  printf '%s\n' $'source_path\thash_count\thashes\tidentity' > "$IDENTITY"
  local previous_source=''
  local count=0
  local hashes=''
  local first_hash=''
  local mixed=0
  local source_path hash
  flush_identity() {
    if [[ -z "$previous_source" ]]; then
      return
    fi
    local identity=same
    if (( mixed )); then
      identity=different
      OUTPUT_MISMATCH_COUNT=$((OUTPUT_MISMATCH_COUNT + 1))
    fi
    printf '%s\t%s\t%s\t%s\n' "$previous_source" "$count" "$hashes" "$identity" >> "$IDENTITY"
  }
  while IFS=$'\t' read -r run_id source_path staged_path output_path output_hash output_bytes package_dir package_name status binary binary_kind mode gc cache repetition order_index search_paths goroot input_hash input_bytes output_set_hash; do
    [[ "$status" == 0 ]] || continue
    if [[ "$source_path" != "$previous_source" ]]; then
      flush_identity
      previous_source=$source_path
      count=0
      hashes=''
      first_hash=''
      mixed=0
    fi
    if [[ -z "$first_hash" ]]; then
      first_hash=$output_hash
    elif [[ "$output_hash" != "$first_hash" ]]; then
      mixed=1
    fi
    if [[ -z "$hashes" ]]; then
      hashes=$output_hash
    else
      hashes="$hashes,$output_hash"
    fi
    count=$((count + 1))
  done < "$sorted_file"
  flush_identity
}

write_identity

compare_baseline() {
  [[ -n "$BASELINE" ]] || return 0
  local baseline_summary
  if [[ -d "$BASELINE" ]]; then
    baseline_summary="$BASELINE/summary.tsv"
  else
    baseline_summary=$BASELINE
  fi
  [[ -f "$baseline_summary" ]] || die "baseline summary does not exist: $baseline_summary"
  printf '%s\n' $'binary\tmode\tgc_mode\tcache_mode\tpackage\tbaseline_n_success\tcurrent_n_success\tbaseline_wall_median\tcurrent_wall_median\twall_median_delta_percent\tbaseline_wall_p95\tcurrent_wall_p95\twall_p95_delta_percent' > "$COMPARISON"
  awk -F '\t' '
    NR == FNR {
      if (FNR > 1) {
        key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
        baseline_n[key] = $6
        baseline_median[key] = $9
        baseline_p95[key] = $10
      }
      next
    }
    FNR > 1 {
      key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
      bmed = baseline_median[key]
      bp95 = baseline_p95[key]
      if (bmed == "") bmed = "NA"
      if (bp95 == "") bp95 = "NA"
      median_delta = "NA"
      p95_delta = "NA"
      if (bmed != "NA" && $9 != "NA" && bmed != 0) median_delta = (($9 - bmed) / bmed) * 100
      if (bp95 != "NA" && $10 != "NA" && bp95 != 0) p95_delta = (($10 - bp95) / bp95) * 100
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, baseline_n[key], $6, bmed, $9, median_delta, bp95, $10, p95_delta
    }
  ' "$baseline_summary" "$SUMMARY" > "$COMPARISON"
  local baseline_manifest
  if [[ -d "$BASELINE" ]]; then
    baseline_manifest="$BASELINE/output-manifest.tsv"
  else
    baseline_manifest=''
  fi
  printf '%s\n' $'source_path\tbaseline_sha256\tcurrent_sha256\tmatch' > "$BASELINE_OUTPUT_COMPARISON"
  if [[ -n "$baseline_manifest" && -f "$baseline_manifest" ]]; then
    awk -F '\t' '
      NR == FNR {
        if (FNR > 1 && $9 == 0) baseline[$2] = $5
        next
      }
      FNR > 1 && $9 == 0 {
        match = baseline[$2] == $5 ? "yes" : "no"
        if (match == "no") mismatch++
        printf "%s\t%s\t%s\t%s\n", $2, baseline[$2], $5, match
      }
      END { if (mismatch > 0) exit 3 }
    ' "$baseline_manifest" "$OUTPUT_MANIFEST" > "$BASELINE_OUTPUT_COMPARISON" || {
      warn 'baseline output hashes differ; see baseline-output-comparison.tsv'
      OUTPUT_MISMATCH_COUNT=$((OUTPUT_MISMATCH_COUNT + 1))
    }
  fi
}

if [[ -n "$BASELINE" ]]; then
  compare_baseline
fi

SOURCE_GEN_AFTER="$TMP_ROOT/source-gen.after"
SOURCE_GALA_AFTER="$TMP_ROOT/source-gala.after"
find "$REPO_ROOT" -path "$REPO_ROOT/.git" -prune -o -type f -name '*.gen.go' -print 2>/dev/null | sort > "$SOURCE_GEN_AFTER"
if [[ -d "$REPO_ROOT/.gala" ]]; then
  find "$REPO_ROOT/.gala" -type f -print 2>/dev/null | sort > "$SOURCE_GALA_AFTER"
else
  : > "$SOURCE_GALA_AFTER"
fi
SOURCE_POLLUTION="$OUTPUT/source-pollution.txt"
{
  printf '%s\n' 'source .gen.go file-list diff:'
  diff -u "$SOURCE_GEN_BEFORE" "$SOURCE_GEN_AFTER" || true
  printf '%s\n' 'source .gala file-list diff:'
  diff -u "$SOURCE_GALA_BEFORE" "$SOURCE_GALA_AFTER" || true
  printf '%s\n' 'git status diff:'
  git -C "$REPO_ROOT" status --porcelain=v1 > "$TMP_ROOT/source-status.after"
  diff -u "$GIT_STATUS_BEFORE" "$TMP_ROOT/source-status.after" || true
} > "$SOURCE_POLLUTION"
if ! cmp -s "$SOURCE_GEN_BEFORE" "$SOURCE_GEN_AFTER" || ! cmp -s "$SOURCE_GALA_BEFORE" "$SOURCE_GALA_AFTER" || ! cmp -s "$GIT_STATUS_BEFORE" "$TMP_ROOT/source-status.after"; then
  warn "source-tree state changed during benchmark; see $SOURCE_POLLUTION"
  RUN_FAILURE_COUNT=$((RUN_FAILURE_COUNT + 1))
fi

printf 'results: %s\n' "$OUTPUT"
printf 'manifest: %s\n' "$MANIFEST"
printf 'summary: %s\n' "$SUMMARY_TEXT"
printf 'source pollution check: %s\n' "$SOURCE_POLLUTION"
if (( OUTPUT_MISMATCH_COUNT > 0 && ALLOW_OUTPUT_MISMATCH == 0 )); then
  die "output hashes differ across runs ($OUTPUT_MISMATCH_COUNT records); use --allow-output-mismatch only when intentional"
fi
if (( RUN_FAILURE_COUNT > 0 )); then
  die "benchmark completed with $RUN_FAILURE_COUNT failed or polluted measured runs; see $RESULTS"
fi
if (( PRIMING_FAILURE_COUNT > 0 )); then
  die "warm-cache priming failed $PRIMING_FAILURE_COUNT times; see $PRIMES"
fi
if (( PROFILE_FAILURE_COUNT > 0 )); then
  die "profiling failed $PROFILE_FAILURE_COUNT times; see $PROFILE_RESULTS"
fi
