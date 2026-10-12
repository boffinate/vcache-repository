#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "failed: $*" >&2; exit 1; }

mkdir "$TMP/bin"
cp "$ROOT/scripts/fixtures/gh-dispatch" "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

run() { PATH="$TMP/bin:$PATH" "$ROOT/scripts/dispatch-publish.sh" "$@"; }

output=$(run --release vinyl-42.3.7 --revision 2 --dry-run debian-13-amd64)
[[ $output == *'source_tag=vinyl-42.3.7-r2-debian-13-amd64'* ]] || fail "canonical tag was not dispatched"

if FAKE_IMMUTABLE=false run --release vinyl-42.3.7 --revision 2 --dry-run debian-13-amd64 >/dev/null 2>&1; then
  fail "mutable producer release was accepted"
fi
if FAKE_MIXED=1 run --release vinyl-42.3.7 --revision 2 --dry-run debian-13-amd64 ubuntu-26.04-amd64 >/dev/null 2>&1; then
  fail "targets from different tag commits were accepted"
fi
if run --release vinyl-42.3.7 --revision 02 --dry-run debian-13-amd64 >/dev/null 2>&1; then
  fail "non-canonical revision was accepted"
fi
if run --release vinyl-42.3.7 --dry-run debian-13-amd64 >/dev/null 2>&1; then
  fail "missing explicit revision was accepted"
fi

printf 'ok - dispatch release verification\n'
