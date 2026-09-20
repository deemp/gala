#!/usr/bin/env bash
# Report (and optionally reclaim) disk used by Bazel output bases.
#
# Bazel keys its output base on the *path* of the workspace, so every git
# worktree of this repo gets its own multi-gigabyte output base under the
# Bazel root. They are never reclaimed when the worktree goes away, so a
# workflow that uses throwaway worktrees accumulates orphaned output bases
# indefinitely.
#
#   tools/bazel_gc.sh            # report every output base, newest first
#   tools/bazel_gc.sh --prune    # also delete the orphaned ones
#
# An output base is "orphaned" when the workspace recorded in its
# DO_NOT_BUILD_HERE marker no longer exists on disk. Live output bases and
# the shared install/ and cache/ directories are never touched.

set -euo pipefail

prune=0
for arg in "$@"; do
  case "$arg" in
    --prune) prune=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Prefer asking Bazel itself: the output user root is the grandparent of the
# output base. Falls back to the documented defaults when Bazel is unavailable
# or we are not inside a workspace.
root="${BAZEL_OUTPUT_USER_ROOT:-}"
if [ -z "$root" ] && command -v bazel >/dev/null 2>&1; then
  base="$(bazel info output_base 2>/dev/null || true)"
  if [ -n "$base" ]; then
    root="$(dirname "$base")"
  fi
fi
if [ -z "$root" ]; then
  user="${USERNAME:-${USER:-$(id -un)}}"
  if [ -d "/c/Users/$user/_bazel_$user" ]; then
    root="/c/Users/$user/_bazel_$user"      # Bazel's default on Windows
  else
    root="${HOME}/.cache/bazel/_bazel_$user" # ... and on Unix
  fi
fi

if [ ! -d "$root" ]; then
  echo "no Bazel output user root found at: $root" >&2
  exit 1
fi

echo "Bazel output user root: $root"
echo

total=0
orphan_total=0
orphans=()

for base in "$root"/*/; do
  name="$(basename "$base")"
  case "$name" in
    install|cache) continue ;;
  esac
  [ -d "$base" ] || continue

  size_mb="$(du -sm "$base" 2>/dev/null | cut -f1)"
  size_mb="${size_mb:-0}"
  total=$((total + size_mb))

  marker="$base/DO_NOT_BUILD_HERE"
  if [ -f "$marker" ]; then
    workspace="$(tr -d '\r\n' < "$marker")"
    # The marker stores a native path; normalise it for the test below.
    probe="$workspace"
    case "$probe" in
      [A-Za-z]:/*) probe="/$(echo "${probe:0:1}" | tr 'A-Z' 'a-z')/${probe:3}" ;;
    esac
    if [ -d "$probe" ]; then
      state="live"
    else
      state="ORPHAN"
      orphans+=("$base")
      orphan_total=$((orphan_total + size_mb))
    fi
  else
    workspace="(no marker)"
    state="unknown"
  fi

  printf '%-10s %8s MB  %-7s %s\n' "$name" "$size_mb" "$state" "$workspace"
done

echo
printf 'total: %d MB (%.1f GB) in output bases\n' "$total" "$(echo "$total" | awk '{print $1/1024}')"
printf 'orphaned: %d MB (%.1f GB) in %d output bases\n' \
  "$orphan_total" "$(echo "$orphan_total" | awk '{print $1/1024}')" "${#orphans[@]}"

if [ "${#orphans[@]}" -eq 0 ]; then
  exit 0
fi

if [ "$prune" -eq 0 ]; then
  echo
  echo "re-run with --prune to delete the orphaned output bases"
  exit 0
fi

echo
for base in "${orphans[@]}"; do
  echo "removing $(basename "$base")"
  rm -rf "$base"
done
