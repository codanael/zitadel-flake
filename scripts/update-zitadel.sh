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

resolve() {   # $1 = marker, $2 = attribute, $3 = file
  local marker="$1" attr="$2" file="$3" out got
  set_hash "$marker" "$FAKE" "$file"
  out="$(nix build ".#$attr" --no-link 2>&1 || true)"
  got="$(printf '%s' "$out" | sed -n 's/.*got: *\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | head -1)"
  if [ -z "$got" ]; then
    echo "Could not resolve $marker via $attr" >&2
    printf '%s\n' "$out" | tail -30 >&2
    exit 1
  fi
  set_hash "$marker" "$got" "$file"
  echo "  $marker = $got" >&2
}

resolve goModules         zitadel.goModules                 "$DEFAULT_NIX"
resolve protobufGenerated zitadel.protobufGenerated         "$DEFAULT_NIX"
resolve consoleProtobuf   zitadel.console.consoleProtobuf   "$CONSOLE_NIX"
resolve protoProtobuf     zitadel.console.protoProtobuf     "$CONSOLE_NIX"
resolve clientPnpmDeps    zitadel.console.client            "$CONSOLE_NIX"
resolve consolePnpmDeps   zitadel.console                   "$CONSOLE_NIX"

UPDATE_APPLIED=true
echo "updated=true"
