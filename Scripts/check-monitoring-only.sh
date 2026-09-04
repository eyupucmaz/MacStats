#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly pattern='cmdWriteBytes|writeFanTarget|restoreAutoFanControl|manualModeKey|FanController'

if /usr/bin/grep -R -n -E "${pattern}" "${repo_root}/Sources/MacStats"; then
    printf 'error: shipping sources contain an SMC fan-write/control path\n' >&2
    exit 1
fi

printf 'Monitoring-only safety check passed.\n'
