#!/bin/bash
#
# require-ci-success.sh — fail unless the CI workflow succeeded for a commit.
#
# Usage: GH_TOKEN=... bash Scripts/require-ci-success.sh <owner/repo> <commit-sha>
#
# Looks up the push-triggered runs of the CI workflow for exactly <commit-sha>
# and succeeds only when one of them concluded `success`. Runs that are still
# queued or in progress are polled, so a tag pushed right after its commit
# reached main waits for CI instead of failing. The token needs `actions: read`.
#
# Environment:
#   CI_WORKFLOW_FILE     workflow file name to require (default: ci.yml)
#   CI_WAIT_ATTEMPTS     polls while a run is pending (default: 60)
#   CI_MISSING_ATTEMPTS  polls while no run exists yet (default: 6)
#   CI_WAIT_SECONDS      seconds between polls (default: 30)

set -euo pipefail

usage() {
    printf 'usage: %s <owner/repo> <commit-sha>\n' "$0" >&2
    exit 64
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [ "$#" -ne 2 ]; then usage; fi
REPOSITORY="$1"
COMMIT_SHA="$2"
CI_WORKFLOW_FILE="${CI_WORKFLOW_FILE:-ci.yml}"
CI_WAIT_ATTEMPTS="${CI_WAIT_ATTEMPTS:-60}"
CI_MISSING_ATTEMPTS="${CI_MISSING_ATTEMPTS:-6}"
CI_WAIT_SECONDS="${CI_WAIT_SECONDS:-30}"

[[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "${CI_WORKFLOW_FILE}" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || die "CI_WORKFLOW_FILE must be a workflow file name"
[[ "${CI_WAIT_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] || die "CI_WAIT_ATTEMPTS must be a positive integer"
[[ "${CI_MISSING_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] || die "CI_MISSING_ATTEMPTS must be a positive integer"
[[ "${CI_WAIT_SECONDS}" =~ ^[0-9]+$ ]] || die "CI_WAIT_SECONDS must be a non-negative integer"

RUNS_ENDPOINT="repos/${REPOSITORY}/actions/workflows/${CI_WORKFLOW_FILE}/runs?head_sha=${COMMIT_SHA}&event=push&per_page=100"
attempt=1

while :; do
    # One line per run: "<id> <status> <conclusion>".
    if ! runs="$(gh api "${RUNS_ENDPOINT}" \
        --jq '.workflow_runs[] | "\(.id) \(.status) \(.conclusion // "none")"')"
    then
        die "could not list ${CI_WORKFLOW_FILE} runs for ${COMMIT_SHA}"
    fi

    successful_run="$(printf '%s\n' "${runs}" | awk '$2 == "completed" && $3 == "success" { print $1; exit }')"
    if [ -n "${successful_run}" ]; then
        printf '%s run %s succeeded for %s.\n' "${CI_WORKFLOW_FILE}" "${successful_run}" "${COMMIT_SHA}"
        exit 0
    fi

    if [ -z "${runs}" ]; then
        state='has no push run yet'
        limit="${CI_MISSING_ATTEMPTS}"
    elif printf '%s\n' "${runs}" | awk '$2 != "completed" { found = 1 } END { exit !found }'; then
        state='is still running'
        limit="${CI_WAIT_ATTEMPTS}"
    else
        printf '%s\n' "${runs}" | sed 's/^/  run /' >&2
        die "${CI_WORKFLOW_FILE} did not succeed for ${COMMIT_SHA}; fix or re-run CI before releasing"
    fi

    if [ "${attempt}" -ge "${limit}" ]; then
        die "${CI_WORKFLOW_FILE} ${state} for ${COMMIT_SHA} after ${attempt} check(s); release only commits whose CI passed"
    fi
    printf '%s %s for %s; checking again in %ss (%s/%s).\n' \
        "${CI_WORKFLOW_FILE}" "${state}" "${COMMIT_SHA}" "${CI_WAIT_SECONDS}" "${attempt}" "${limit}"
    sleep "${CI_WAIT_SECONDS}"
    attempt=$((attempt + 1))
done
