#!/usr/bin/env bash
#   ./scripts/update-zitadel.sh --check   detect only, no changes
#   ./scripts/update-zitadel.sh           apply the update
# GITHUB_TOKEN, if set, is sent as a bearer token (raises the GitHub API rate
# limit past the anonymous 60/hour-per-IP; optional, local runs work without it).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEFAULT_NIX="pkgs/zitadel/default.nix"
CONSOLE_NIX="pkgs/zitadel/console.nix"
FAKE="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# A mid-resolve() failure would otherwise leave fake hashes and a bumped
# version in the tree; a re-run would then read that bumped version as
# current and report "nothing newer". Restore on any non-success exit, but
# only once mutation has actually started (MUTATION_STARTED) — never touch
# a tree that already had unrelated uncommitted changes before this ran.
MUTATION_STARTED=false
UPDATE_APPLIED=false
cleanup_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$MUTATION_STARTED" = "true" ] && [ "$UPDATE_APPLIED" != "true" ]; then
    echo "Update did not complete: restoring flake.nix, flake.lock, $DEFAULT_NIX, $CONSOLE_NIX." >&2
    git checkout -- flake.nix flake.lock "$DEFAULT_NIX" "$CONSOLE_NIX" 2>/dev/null || true
  fi
}
trap cleanup_on_failure EXIT

current_version() {
  sed -n 's/^  version = "\([^"]*\)";.*/\1/p' "$DEFAULT_NIX" | head -1
}

# Not /releases/latest: upstream ships v3 patches after v4 ones, which would
# cause a downgrade. Prints two lines: the highest release still within
# $cur's major (or empty), then the highest release in a strictly newer
# major (or empty) — so a new major never silently freezes patches to the
# current one.
latest_candidate() {
  local cur="$1"
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl -sSf "${auth[@]}" "https://api.github.com/repos/zitadel/zitadel/releases?per_page=100" \
    | python3 -c '
import json, sys, re
cur = sys.argv[1]
def key(v): return tuple(int(x) for x in v.split("."))
cur_major = cur.split(".")[0]
same_best = None
major_best = None
for r in json.load(sys.stdin):
    if r["draft"] or r["prerelease"]:
        continue
    m = re.fullmatch(r"v(\d+\.\d+\.\d+)", r["tag_name"])
    if not m:
        continue
    v = m.group(1)
    if key(v) <= key(cur):
        continue
    if v.split(".")[0] == cur_major:
        if same_best is None or key(v) > key(same_best):
            same_best = v
    else:
        if major_best is None or key(v) > key(major_best):
            major_best = v
print(same_best or "")
print(major_best or "")
' "$cur"
}

bump_kind() {
  [ "${1%%.*}" != "${2%%.*}" ] && echo major || echo minor
}

CUR="$(current_version)"
CANDIDATES_RAW="$(latest_candidate "$CUR")"
readarray -t CANDIDATES <<< "$CANDIDATES_RAW"
NEW="${CANDIDATES[0]:-}"
MAJOR_AVAILABLE="${CANDIDATES[1]:-}"

if [ -z "$NEW" ]; then
  echo "current=$CUR"
  echo "updated=false"
  if [ -n "$MAJOR_AVAILABLE" ]; then
    echo "major_available=$MAJOR_AVAILABLE"
    echo "No newer $CUR.x release; a newer major ($MAJOR_AVAILABLE) exists upstream but is never auto-selected." >&2
  else
    echo "No upstream version newer than $CUR." >&2
  fi
  exit 1
fi

KIND="$(bump_kind "$CUR" "$NEW")"
echo "current=$CUR"
echo "latest=$NEW"
echo "kind=$KIND"
if [ -n "$MAJOR_AVAILABLE" ]; then
  echo "major_available=$MAJOR_AVAILABLE"
fi

if [ "${1:-}" = "--check" ]; then
  echo "updated=false"
  exit 0
elif [ -n "${1:-}" ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

MUTATION_STARTED=true
sed -i "s|github:zitadel/zitadel/v${CUR}|github:zitadel/zitadel/v${NEW}|" flake.nix
sed -i "s|^  version = \"${CUR}\";|  version = \"${NEW}\";|" "$DEFAULT_NIX"
nix flake update zitadel-src

LOCK_REF="$(python3 -c "import json;print(json.load(open('flake.lock'))['nodes']['zitadel-src']['original']['ref'])")"
if [ "$LOCK_REF" != "v${NEW}" ]; then
  echo "flake.lock points at $LOCK_REF, expected v${NEW}" >&2
  exit 1
fi

set_hash() {  # $1 = marker, $2 = value, $3 = file
  sed -i "s|\(= \)\"[^\"]*\"\(; *# @hash:$1\$\)|\1\"$2\"\2|" "$3"
}

get_hash() {  # $1 = marker, $2 = file
  sed -n "s|.*= \"\([^\"]*\)\"; *# @hash:$1\$|\1|p" "$2" | head -1
}

# Take the new hash only from the derivation actually being resolved.
#
# This used to scrape the first `got:` anywhere in nix's output. On a version
# bump *every* marker in the tree still holds the previous release's hash, so
# the build usually fails inside some other fixed-output derivation first, and
# whichever one lost the parallel race had its hash written into the marker
# being resolved. That silently corrupted the rest of the pass — each later
# resolve then tripped over the marker the previous one had poisoned — and only
# surfaced ~15 minutes later, in CI's Build step, as a bare hash mismatch.
#
# The expected `.drv` is evaluated up front (it is well defined: the placeholder
# below is part of the derivation), and anything that is not a mismatch on that
# exact path is now a hard failure rather than a guess.
resolve() {   # $1 = marker, $2 = attribute, $3 = file
  local marker="$1" attr="$2" file="$3" drv out got
  set_hash "$marker" "$FAKE" "$file"

  if ! drv="$(nix eval --raw ".#$attr.drvPath")" || [ -z "$drv" ]; then
    echo "Could not evaluate .#$attr while resolving $marker" >&2
    exit 1
  fi

  out="$(nix build ".#$attr" --no-link 2>&1 || true)"
  got="$(printf '%s\n' "$out" | awk -v want="$drv" '
    /hash mismatch in fixed-output derivation/ {
      cur = (index($0, want) > 0) ? want : ""
      next
    }
    cur == want && /got:/ {
      if (match($0, /sha256-[A-Za-z0-9+\/=]+/)) {
        print substr($0, RSTART, RLENGTH)
        exit
      }
    }')"

  if [ -z "$got" ]; then
    echo "Could not resolve $marker: no hash mismatch reported for $drv." >&2
    echo "The build failed for some other reason, or a dependency's hash is stale." >&2
    printf '%s\n' "$out" | tail -40 >&2
    exit 1
  fi

  set_hash "$marker" "$got" "$file"
  echo "  $marker = $got" >&2
}

# Strictly bottom-up, and always against the fixed-output derivation itself
# rather than something that consumes it: resolving `clientPnpmDeps` by
# building `zitadel.console.client` used to fail inside `protoProtobuf` (which
# `client` copies in) — while `protoProtobuf` in turn reuses `client.pnpmDeps`,
# a knot that only unties by addressing each FOD directly.
resolve goModules         zitadel.goModules                 "$DEFAULT_NIX"
resolve protobufGenerated zitadel.protobufGenerated         "$DEFAULT_NIX"
resolve consoleProtobuf   zitadel.console.consoleProtobuf   "$CONSOLE_NIX"
resolve clientPnpmDeps    zitadel.console.client.pnpmDeps   "$CONSOLE_NIX"

# fetchPnpmDeps fetches the whole workspace lockfile regardless of the
# --filter, so console's deps are byte-for-byte client's. Copy rather than
# spend a second full fetch; the verification pass below proves it.
PNPM_DEPS="$(get_hash clientPnpmDeps "$CONSOLE_NIX")"
if [ -z "$PNPM_DEPS" ]; then
  echo "Could not read back the clientPnpmDeps marker from $CONSOLE_NIX" >&2
  exit 1
fi
set_hash consolePnpmDeps "$PNPM_DEPS" "$CONSOLE_NIX"
echo "  consolePnpmDeps = $PNPM_DEPS (copied from clientPnpmDeps)" >&2

resolve protoProtobuf     zitadel.console.protoProtobuf     "$CONSOLE_NIX"

# Each resolve above is only as good as the state of the *other* markers at the
# moment it ran. Prove the set is mutually consistent before reporting success:
# every fixed-output derivation must now build. This is the same work CI's
# Build step would do — the store paths it produces are reused there — so it
# costs no extra wall clock, it just fails here, naming the derivation, instead
# of later as an unattributed mismatch.
if grep -qF "$FAKE" flake.nix "$DEFAULT_NIX" "$CONSOLE_NIX"; then
  echo "A placeholder hash survived the resolve pass:" >&2
  grep -nF "$FAKE" flake.nix "$DEFAULT_NIX" "$CONSOLE_NIX" >&2
  exit 1
fi

echo "Verifying the resolved hashes against a real build..." >&2
for attr in \
  zitadel.goModules \
  zitadel.protobufGenerated \
  zitadel.console.consoleProtobuf \
  zitadel.console.client.pnpmDeps \
  zitadel.console.pnpmDeps \
  zitadel.console.protoProtobuf
do
  echo "  .#$attr" >&2
  if ! nix build ".#$attr" --no-link; then
    echo "Verification failed: .#$attr does not build with the resolved hashes." >&2
    exit 1
  fi
done

UPDATE_APPLIED=true
echo "updated=true"
