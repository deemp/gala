#!/usr/bin/env bash
# Bump the pinned stage-0 compiler revision in MODULE.bazel.
#
# The marked block ("BEGIN/END gala_bootstrap_src") is the single source of
# truth for both Bazel (http_archive) and Nix (nix/gala.nix parses #rev and
# #nix-hash). This script is its only writer. See tools/bootstrap/README.md.
#
# Usage:
#   tools/bootstrap/bump.sh [--repo owner/name] <40-hex-commit>
#
# --repo defaults to the repo currently recorded in the block, so switching
# the stage-0 source (e.g. from a fork back to martianoff/gala) is explicit:
#   tools/bootstrap/bump.sh --repo martianoff/gala <rev>
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "$0")/../.." && pwd)"
module="$root/MODULE.bazel"

repo="$(sed -n 's/^# repo: //p' "$module" | head -1)"
repo="${repo:-martianoff/gala}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || { echo "error: --repo needs an owner/name argument" >&2; exit 2; }
      repo="$2"
      shift 2
      ;;
    --repo=*)
      repo="${1#--repo=}"
      shift
      ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "error: unknown flag $1" >&2
      exit 2
      ;;
    *)
      rev="$1"
      shift
      ;;
  esac
done

: "${rev:?usage: tools/bootstrap/bump.sh [--repo owner/name] <40-hex-commit>}"

case "$repo" in
  */*) ;;
  *) echo "error: --repo must be owner/name, got '$repo'" >&2; exit 2 ;;
esac
case "$rev" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "error: rev must be a full 40-char lowercase hex commit (got '$rev')" >&2; exit 2 ;;
esac

url="https://github.com/$repo/archive/$rev.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "bump: fetching $url"
curl -fsSL --retry 3 -o "$tmp/src.tar.gz" "$url"

hex="$(sha256sum "$tmp/src.tar.gz" | awk '{print $1}')"

if ! command -v nix >/dev/null 2>&1; then
  echo "error: nix is required to compute the fetchFromGitHub (unpacked) hash" >&2
  echo "       install Nix or run this on a machine that has it" >&2
  exit 1
fi
nix store prefetch-file --unpack --json --hash-type sha256 "$url" > "$tmp/prefetch.json"
nixhash="$(sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' "$tmp/prefetch.json")"
[ -n "$nixhash" ] || { echo "error: could not parse nix hash from $tmp/prefetch.json" >&2; exit 1; }

block="$tmp/block"
cat > "$block" <<EOF
# BEGIN gala_bootstrap_src (managed by tools/bootstrap/bump.sh)
# Stage-0 compiler: a previously landed revision used to build the stdlib.
# Bump policy: see CONTRIBUTING.MD "Bootstrapping".
# repo: $repo
# rev: $rev
# nix-hash: $nixhash
http_archive(
    name = "gala_bootstrap_src",
    urls = ["$url"],
    strip_prefix = "gala-$rev",
    sha256 = "$hex",
)
# END gala_bootstrap_src
EOF

if ! grep -q '^# BEGIN gala_bootstrap_src' "$module"; then
  echo "error: $module has no '# BEGIN gala_bootstrap_src' marker" >&2
  exit 1
fi

awk -v blockfile="$block" '
  /^# BEGIN gala_bootstrap_src/ {
    while ((getline line < blockfile) > 0) print line
    close(blockfile)
    skip = 1
    next
  }
  /^# END gala_bootstrap_src/ { skip = 0; next }
  !skip { print }
' "$module" > "$tmp/MODULE.bazel"

mv "$tmp/MODULE.bazel" "$module"

echo "bump: wrote pin"
echo "  repo:     $repo"
echo "  rev:      $rev"
echo "  sha256:   $hex"
echo "  nix-hash: $nixhash"
echo
echo "Next steps:"
echo "  1. bazel build @gala_bootstrap_src//cmd/gala_bootstrap:gala_bootstrap"
echo "  2. nix build .#gala"
echo "  3. tools/bootstrap/fixpoint.sh"
echo
echo "Reachability: the pinned commit must stay reachable in $repo."
echo "The repo merges PRs with merge commits, so do not squash-merge a PR"
echo "whose commits are pinned; bump to the merge commit right after."
