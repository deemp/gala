#!/usr/bin/env bash
# Report (and optionally reclaim) disk used by Bazel output bases.
#
# Bazel keys its output base on the *path* of the workspace, so every git
# worktree of this repo gets its own multi-gigabyte output base under the
# Bazel root. They are never reclaimed when the worktree goes away, so a
# workflow that uses throwaway worktrees accumulates orphaned output bases
# indefinitely.
#
#   tools/bazel_gc.sh                 # report every output base, largest first
#   tools/bazel_gc.sh --prune         # delete the orphaned ones (asks first)
#   tools/bazel_gc.sh --prune --yes   # ... without asking
#
# An output base is "orphaned" when the workspace recorded in its
# DO_NOT_BUILD_HERE marker no longer exists on disk. Live output bases and
# the shared install/ and cache/ directories are never touched.
#
# Set BAZEL_OUTPUT_USER_ROOT to point at a non-default Bazel root, e.g. when
# you build with an explicit --output_user_root.

set -euo pipefail

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

prune=0
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --prune) prune=1 ;;
    --yes|-y) assume_yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Bazel's default output user root, per platform. We deliberately do not shell
# out to `bazel info output_base` to discover this: inside a workspace that
# starts a server and does full module resolution just to print a disk report,
# and it gives the wrong answer entirely when --output_base is overridden.
root="${BAZEL_OUTPUT_USER_ROOT:-}"
if [ -z "$root" ]; then
  user="${USERNAME:-${USER:-$(id -un)}}"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) root="/c/Users/$user/_bazel_$user" ;;
    Darwin)               root="/private/var/tmp/_bazel_$user" ;;
    *)                    root="${HOME}/.cache/bazel/_bazel_$user" ;;
  esac
fi

if [ ! -d "$root" ]; then
  echo "no Bazel output user root at: $root" >&2
  echo "set BAZEL_OUTPUT_USER_ROOT if you build with a custom --output_user_root" >&2
  exit 1
fi

echo "Bazel output user root: $root"
echo

# Collect first so the report can be sorted by size — the thing you actually
# care about when you are looking for space to reclaim.
rows=()
orphans=()
total=0
orphan_total=0

for base in "$root"/*/; do
  name="$(basename "$base")"
  case "$name" in
    install|cache) continue ;;
  esac
  [ -d "$base" ] || continue

  # A build running in another worktree can make files vanish mid-walk, and an
  # unreadable directory is not a reason to abandon the whole report.
  size_mb="$(du -sm "$base" 2>/dev/null | cut -f1 || true)"
  size_mb="${size_mb:-0}"
  total=$((total + size_mb))

  marker="$base/DO_NOT_BUILD_HERE"
  if [ -f "$marker" ]; then
    workspace="$(tr -d '\r\n' < "$marker")"
    # The marker stores a native path, lower-cased on Windows; normalise it
    # enough to test for existence.
    probe="$workspace"
    case "$probe" in
      [A-Za-z]:/*) probe="/$(printf '%s' "${probe%%:*}" | tr 'A-Z' 'a-z')/${probe#?:/}" ;;
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

  rows+=("$(printf '%08d\t%s\t%s\t%s' "$size_mb" "$name" "$state" "$workspace")")
done

if [ "${#rows[@]}" -gt 0 ]; then
  printf '%s\n' "${rows[@]}" | sort -rn | while IFS=$'\t' read -r size name state workspace; do
    printf '%-10s %8s MB  %-7s %s\n' "$name" "$((10#$size))" "$state" "$workspace"
  done
  echo
fi

printf 'total:    %6d MB (%.1f GB) in output bases\n' \
  "$total" "$(echo "$total" | awk '{print $1/1024}')"
printf 'orphaned: %6d MB (%.1f GB) in %d output bases\n' \
  "$orphan_total" "$(echo "$orphan_total" | awk '{print $1/1024}')" "${#orphans[@]}"

if [ "${#orphans[@]}" -eq 0 ]; then
  exit 0
fi

if [ "$prune" -eq 0 ]; then
  echo
  echo "re-run with --prune to delete the orphaned output bases"
  exit 0
fi

# Deleting a multi-gigabyte output base is irreversible and the "workspace is
# gone" test above is only as good as the path in the marker, so confirm unless
# told not to.
if [ "$assume_yes" -eq 0 ]; then
  echo
  printf 'delete %d orphaned output base(s), %d MB? [y/N] ' \
    "${#orphans[@]}" "$orphan_total"
  read -r reply </dev/tty || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "aborted"; exit 0 ;;
  esac
fi

echo
failed=0
for base in "${orphans[@]}"; do
  name="$(basename "$base")"
  echo "removing $name"
  # A Bazel server outlives its workspace by hours of idle time and holds its
  # own files open, which is exactly the orphan case. Ask it to exit first, and
  # never let one stuck base abandon the rest.
  bazel --output_base="$base" shutdown >/dev/null 2>&1 || true
  if ! rm -rf "$base" 2>/dev/null; then
    echo "  could not fully remove $name (server still running?)" >&2
    failed=$((failed + 1))
  fi
done

if [ "$failed" -gt 0 ]; then
  echo
  echo "$failed output base(s) could not be fully removed; re-run later" >&2
  exit 1
fi
