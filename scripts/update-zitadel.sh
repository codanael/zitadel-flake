#!/usr/bin/env bash
#   ./scripts/update-zitadel.sh --check   detect only, no changes
#   ./scripts/update-zitadel.sh           apply the update
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEFAULT_NIX="pkgs/zitadel/default.nix"
CONSOLE_NIX="pkgs/zitadel/console.nix"
FAKE="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

current_version() {
  sed -n 's/^  version = "\([^"]*\)";.*/\1/p' "$DEFAULT_NIX" | head -1
}

# Not /releases/latest: upstream ships v3 patches after v4 ones, which would cause a downgrade.
latest_candidate() {
  local cur="$1"
  curl -sSf "https://api.github.com/repos/zitadel/zitadel/releases?per_page=100" \
    | python3 -c '
import json, sys, re
cur = sys.argv[1]
def key(v): return tuple(int(x) for x in v.split("."))
best = None
for r in json.load(sys.stdin):
    if r["draft"] or r["prerelease"]:
        continue
    m = re.fullmatch(r"v(\d+\.\d+\.\d+)", r["tag_name"])
    if not m:
        continue
    v = m.group(1)
    if key(v) > key(cur) and (best is None or key(v) > key(best)):
        best = v
print(best or "")
' "$cur"
}

bump_kind() {
  [ "${1%%.*}" != "${2%%.*}" ] && echo major || echo minor
}

CUR="$(current_version)"
NEW="$(latest_candidate "$CUR")"

if [ -z "$NEW" ]; then
  echo "current=$CUR"
  echo "updated=false"
  echo "No upstream version newer than $CUR." >&2
  exit 1
fi

KIND="$(bump_kind "$CUR" "$NEW")"
echo "current=$CUR"
echo "latest=$NEW"
echo "kind=$KIND"

if [ "${1:-}" = "--check" ]; then
  echo "updated=false"
  exit 0
elif [ -n "${1:-}" ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

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

echo "updated=true"
