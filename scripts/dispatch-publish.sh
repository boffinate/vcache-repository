#!/usr/bin/env bash
# Maintainer driver for publication waves. Dispatches publish.yml once per
# target, self-approves the protected-environment gate through the GitHub API
# (the required reviewer is the maintainer running this script), and waits for
# each run before starting the next, because the publication concurrency group
# retains only one pending run. Requires an authenticated gh CLI; runs on a
# maintainer host, never in CI.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

REPO=boffinate/vcache-repository
PRODUCER=boffinate/vcache-packaging

usage() {
  cat >&2 <<'USAGE'
usage: dispatch-publish.sh [options] [target ...]
       dispatch-publish.sh --site

Publish every routes.tsv target (or only the named targets) from one producer
release wave, in order, one workflow run at a time.

options:
  --release <engine-id>  producer release prefix, for example vinyl-9.0.1;
                         default: the newest engine id with producer releases
  --site                 dispatch site.yml instead of any publication
  --no-approve           do not self-approve; wait for a browser approval
  --dry-run              print the planned dispatches and exit
  --yes                  skip the confirmation prompt
USAGE
  exit 2
}

die() { echo "error: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

RELEASE=
SITE_ONLY=0
APPROVE=1
DRY_RUN=0
ASSUME_YES=0
TARGETS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --release) [[ $# -ge 2 ]] || usage; RELEASE=$2; shift 2 ;;
    --site) SITE_ONLY=1; shift ;;
    --no-approve) APPROVE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

need gh
LOGIN=$(gh api user --jq .login) || die "gh is not authenticated"

confirm() {
  (( ASSUME_YES )) && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [[ $reply == y || $reply == Y ]] || die "aborted"
}

refuse_active_runs() {
  local workflow active
  for workflow in publish.yml site.yml; do
    active=$(gh run list -R "$REPO" --workflow "$workflow" --limit 10 \
      --json databaseId,status \
      --jq '[.[] | select(.status != "completed")] | length')
    [[ $active == 0 ]] || die "$workflow already has a queued, waiting, or running run"
  done
}

latest_run_id() {
  gh run list -R "$REPO" --workflow "$1" --limit 1 --json databaseId --jq '.[0].databaseId // 0'
}

# Approve the protected-environment gate when it appears, then hand off to
# gh run watch. A run whose fetch job fails never reaches the gate, so the
# loop also watches for completion.
watch_run() {
  local workflow=$1 previous=$2 run_id= status pending waited=0
  while [[ -z $run_id ]]; do
    (( waited <= 120 )) || die "dispatched $workflow run did not appear"
    sleep 5; waited=$((waited + 5))
    run_id=$(gh run list -R "$REPO" --workflow "$workflow" --limit 5 \
      --json databaseId,event \
      --jq "[.[] | select(.event == \"workflow_dispatch\" and .databaseId > $previous)] | .[0].databaseId // empty")
  done
  echo "run https://github.com/$REPO/actions/runs/$run_id"
  waited=0
  while :; do
    status=$(gh run view -R "$REPO" "$run_id" --json status --jq .status)
    [[ $status != completed ]] || break
    pending=$(gh api "repos/$REPO/actions/runs/$run_id/pending_deployments" \
      --jq '[.[] | select(.current_user_can_approve)] | .[0].environment.id // empty' 2>/dev/null) || pending=
    if [[ -n $pending ]]; then
      if (( APPROVE )); then
        if gh api --method POST "repos/$REPO/actions/runs/$run_id/pending_deployments" \
          -F "environment_ids[]=$pending" -f state=approved \
          -f "comment=dispatch-publish.sh wave approval by $LOGIN" >/dev/null; then
          echo "approved production deployment for run $run_id"
        else
          echo "could not self-approve; approve in the browser: https://github.com/$REPO/actions/runs/$run_id" >&2
        fi
      else
        echo "waiting for browser approval: https://github.com/$REPO/actions/runs/$run_id"
      fi
      break
    fi
    (( waited <= 2700 )) || die "run $run_id neither completed nor asked for approval"
    sleep 10; waited=$((waited + 10))
  done
  gh run watch -R "$REPO" "$run_id" --interval 15 --exit-status >/dev/null ||
    die "run $run_id failed: https://github.com/$REPO/actions/runs/$run_id -- fix the cause and re-dispatch the same target; publication retries are idempotent"
  echo "run $run_id succeeded"
}

if (( SITE_ONLY )); then
  [[ -z $RELEASE && ${#TARGETS[@]} -eq 0 ]] || die "--site takes no release or targets"
  if (( DRY_RUN )); then echo "would dispatch site.yml"; exit 0; fi
  refuse_active_runs
  confirm "Dispatch site.yml as $LOGIN?"
  previous=$(latest_run_id site.yml)
  gh workflow run -R "$REPO" site.yml
  watch_run site.yml "$previous"
  exit 0
fi

ALL_TARGETS=()
while IFS=$'\t' read -r target _; do
  [[ -n $target && $target != \#* ]] && ALL_TARGETS+=("$target")
done <"$ROOT/routes.tsv"
(( ${#ALL_TARGETS[@]} )) || die "routes.tsv lists no targets"

if (( ${#TARGETS[@]} == 0 )); then
  TARGETS=("${ALL_TARGETS[@]}")
else
  for target in "${TARGETS[@]}"; do
    for known in "${ALL_TARGETS[@]}"; do [[ $target == "$known" ]] && continue 2; done
    die "unknown target $target; routes.tsv allows: ${ALL_TARGETS[*]}"
  done
fi

if [[ -z $RELEASE ]]; then
  # Newest engine id with a live producer release for a known target. The
  # API's ISO-8601 timestamps are all UTC Zulu, so lexicographic comparison
  # orders them without host-dependent date parsing.
  best_time=
  while IFS=$'\t' read -r tag created; do
    for known in "${ALL_TARGETS[@]}"; do
      if [[ $tag == *-"$known" ]]; then
        engine=${tag%-"$known"}
        if [[ -z $best_time || $created > $best_time ]]; then
          best_time=$created
          RELEASE=$engine
        fi
      fi
    done
  done < <(gh api "repos/$PRODUCER/releases?per_page=100" \
    --jq '.[] | select((.draft or .prerelease) | not) | [.tag_name, .created_at] | @tsv')
  [[ -n $RELEASE ]] || die "no producer release matches any routes.tsv target"
  echo "discovered newest producer release wave: $RELEASE"
fi

MISSING=()
for target in "${TARGETS[@]}"; do
  gh api "repos/$PRODUCER/releases/tags/$RELEASE-$target" \
    --jq 'if .draft or .prerelease then error("draft") else .tag_name end' >/dev/null 2>&1 ||
    MISSING+=("$RELEASE-$target")
done
(( ${#MISSING[@]} == 0 )) || die "producer has no live release for: ${MISSING[*]}"

echo "planned dispatches, in order:"
for target in "${TARGETS[@]}"; do echo "  publish.yml  source_tag=$RELEASE-$target"; done
if (( DRY_RUN )); then exit 0; fi

refuse_active_runs
confirm "Dispatch ${#TARGETS[@]} publication run(s) as $LOGIN?"
for target in "${TARGETS[@]}"; do
  tag=$RELEASE-$target
  echo "== $tag =="
  previous=$(latest_run_id publish.yml)
  gh workflow run -R "$REPO" publish.yml -f "source_tag=$tag"
  watch_run publish.yml "$previous"
done
echo "wave complete: ${TARGETS[*]}"
