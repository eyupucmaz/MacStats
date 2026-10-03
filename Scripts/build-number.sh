#!/bin/bash
#
# build-number.sh — print the CFBundleVersion for the checked-out commit.
#
# Usage: bash Scripts/build-number.sh [repository-directory]
#
# The build number is the number of commits reachable from HEAD. It is
# reproducible for a given commit and grows along main, unlike a CI run number.
# A shallow clone would report a wrong count, so it is rejected; check out with
# full history (actions/checkout `fetch-depth: 0`).

set -euo pipefail

usage() {
    printf 'usage: %s [repository-directory]\n' "$0" >&2
    exit 64
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [ "$#" -gt 1 ]; then usage; fi
REPOSITORY_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

shallow="$(git -C "${REPOSITORY_DIR}" rev-parse --is-shallow-repository)" \
    || die "not a git repository: ${REPOSITORY_DIR}"
[ "${shallow}" = false ] \
    || die "shallow clone; fetch the full history (actions/checkout fetch-depth: 0) to derive the build number"

commit_count="$(git -C "${REPOSITORY_DIR}" rev-list --count HEAD)" \
    || die "could not count the commits reachable from HEAD"
[[ "${commit_count}" =~ ^[1-9][0-9]*$ ]] || die "unexpected commit count: ${commit_count}"

printf '%s\n' "${commit_count}"
