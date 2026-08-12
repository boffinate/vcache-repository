#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
usage() { echo "usage: $0 <source-tag> <stage-dir> | $0 --verify|--describe <stage-dir>" >&2; exit 2; }
case ${1:-} in
  --verify)
    [[ $# -eq 2 ]] || usage
    exec python3 "$ROOT/tools/release.py" verify --stage "$2" --routes "$ROOT/routes.tsv"
    ;;
  --describe)
    [[ $# -eq 2 ]] || usage
    exec python3 "$ROOT/tools/release.py" describe --stage "$2" --routes "$ROOT/routes.tsv"
    ;;
  "") usage ;;
  *)
    [[ $# -eq 2 ]] || usage
    exec python3 "$ROOT/tools/release.py" fetch --tag "$1" --stage "$2" --routes "$ROOT/routes.tsv"
    ;;
esac
