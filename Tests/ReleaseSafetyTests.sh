#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

pass() {
    printf 'ok - %s\n' "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

require_literal() {
    local file="$1"
    local literal="$2"
    local description="$3"

    if /usr/bin/grep -Fq -- "${literal}" "${REPO_ROOT}/${file}"; then
        pass "${description}"
    else
        fail "${description}"
    fi
}

forbid_literal() {
    local file="$1"
    local literal="$2"
    local description="$3"

    if /usr/bin/grep -Fq -- "${literal}" "${REPO_ROOT}/${file}"; then
        fail "${description}"
    else
        pass "${description}"
    fi
}

test_release_workflow_policy() {
    local workflow='.github/workflows/release.yml'

    require_literal "${workflow}" 'GH_TOKEN: ${{ github.token }}' \
        'release lookup receives the Actions token'
    require_literal "${workflow}" 'gh api --silent "repos/${GITHUB_REPOSITORY}"' \
        'release lookup proves repository API access before interpreting absence'
    require_literal "${workflow}" 'release_lookup_status=$?' \
        'release lookup captures the API failure status'
    require_literal "${workflow}" 'HTTP/[0-9.]+ 404' \
        'release lookup recognizes only an HTTP 404 as absence'
    require_literal "${workflow}" 'exit "${release_lookup_status}"' \
        'release lookup propagates unexpected API failures'
    require_literal "${workflow}" 'overwrite_files: false' \
        'release publication cannot overwrite an existing asset'
    require_literal "${workflow}" 'generate_release_notes: true' \
        'generated release notes remain enabled'
    require_literal "${workflow}" 'body: |' \
        'release publication has an explicit body'
    require_literal "${workflow}" 'monitoring-only' \
        'release body discloses monitoring-only scope'
    require_literal "${workflow}" 'ad-hoc signed and is not notarized' \
        'release body discloses signing and notarization status'
    require_literal "${workflow}" 'drag `MacStats.app` to Applications' \
        'release body includes drag-to-Applications installation'
    require_literal "${workflow}" 'Control-click' \
        'release body includes the Gatekeeper Control-click path'
    require_literal "${workflow}" 'Open Anyway' \
        'release body includes the Gatekeeper Open Anyway path'
    require_literal "${workflow}" 'shasum -a 256 -c' \
        'release body includes checksum verification'
    forbid_literal "${workflow}" 'gh release view' \
        'release lookup does not treat every gh release view failure as absence'
}

test_documented_shell_validation() {
    local loop='for script in Scripts/*.sh; do bash -n "$script"; done'
    local old_command='bash -n Scripts/'"*.sh"
    local file

    for file in \
        '.github/workflows/ci.yml' \
        '.github/workflows/release.yml' \
        'README.md' \
        'CONTRIBUTING.md' \
        'docs/superpowers/plans/2026-09-04-public-preview-release.md'
    do
        require_literal "${file}" "${loop}" "${file} parses every release script independently"
        forbid_literal "${file}" "${old_command}" "${file} has no ineffective wildcard syntax check"
    done

    require_literal 'README.md' \
        'https://github.com/eyupucmaz/MacStats/releases/tag/v0.1.0' \
        'README links directly to the v0.1.0 prerelease'
    require_literal 'docs/superpowers/plans/2026-09-04-public-preview-release.md' \
        'https://github.com/eyupucmaz/MacStats/releases/tag/v0.1.0' \
        'implementation plan requires the fixed preview tag URL'
}

test_strict_source_version_validation() {
    local probe_root fake_bin swift_log output status
    probe_root="${TEST_ROOT}/build-probe"
    fake_bin="${probe_root}/fake-bin"
    swift_log="${probe_root}/swift.log"
    output="${probe_root}/output.log"

    mkdir -p "${probe_root}/Scripts" "${fake_bin}"
    cp "${REPO_ROOT}/Scripts/build-app.sh" "${probe_root}/Scripts/build-app.sh"
    cp "${REPO_ROOT}/Info.plist" "${probe_root}/Info.plist"
    printf '%s\n' \
        '#!/bin/bash' \
        'printf '\''%s\n'\'' "$*" >> "${MACSTATS_SWIFT_LOG}"' \
        'exit 89' \
        > "${fake_bin}/swift"
    chmod +x "${fake_bin}/swift"

    : > "${swift_log}"
    if PATH="${fake_bin}:${PATH}" MACSTATS_SWIFT_LOG="${swift_log}" \
        APP_VERSION=0.1.0 BUILD_NUMBER=1 RELEASE_STRICT=1 \
        /bin/bash "${probe_root}/Scripts/build-app.sh" > "${output}" 2>&1
    then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -eq 89 ] && [ -s "${swift_log}" ]; then
        pass 'strict source version 0.1.0 is accepted before compilation'
    else
        fail 'strict source version 0.1.0 is accepted before compilation'
    fi

    : > "${swift_log}"
    if PATH="${fake_bin}:${PATH}" MACSTATS_SWIFT_LOG="${swift_log}" \
        APP_VERSION=0.2.0 BUILD_NUMBER=1 RELEASE_STRICT=1 \
        /bin/bash "${probe_root}/Scripts/build-app.sh" > "${output}" 2>&1
    then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -ne 0 ] && [ ! -s "${swift_log}" ] && \
        /usr/bin/grep -Fq 'must exactly match source version 0.1.0' "${output}"; then
        pass 'strict requested/source version mismatch fails before swift build'
    else
        fail 'strict requested/source version mismatch fails before swift build'
    fi

    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 00.1.0' \
        "${probe_root}/Info.plist"
    : > "${swift_log}"
    if PATH="${fake_bin}:${PATH}" MACSTATS_SWIFT_LOG="${swift_log}" \
        APP_VERSION=0.1.0 BUILD_NUMBER=1 RELEASE_STRICT=1 \
        /bin/bash "${probe_root}/Scripts/build-app.sh" > "${output}" 2>&1
    then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -ne 0 ] && [ ! -s "${swift_log}" ] && \
        /usr/bin/grep -Fq 'source CFBundleShortVersionString must use MAJOR.MINOR.PATCH format without leading zeroes' "${output}"; then
        pass 'strict source version grammar rejects leading zeroes before swift build'
    else
        fail 'strict source version grammar rejects leading zeroes before swift build'
    fi
}

prepare_verify_release_probe() {
    local probe_root="$1"
    local fake_bin="$2"
    local mount_point="$3"
    local dmg_name='MacStats-0.1.0-universal.dmg'

    mkdir -p "${probe_root}/Scripts" "${probe_root}/dist" "${fake_bin}"
    mkdir -p "${mount_point}/MacStats.app"
    ln -s /Applications "${mount_point}/Applications"
    cp "${REPO_ROOT}/Scripts/verify-release.sh" "${probe_root}/Scripts/verify-release.sh"
    printf '%s\n' \
        '#!/bin/bash' \
        'exit "${MACSTATS_VERIFY_APP_STATUS:-0}"' \
        > "${probe_root}/Scripts/verify-app.sh"
    printf 'release-probe\n' > "${probe_root}/dist/${dmg_name}"
    (
        cd "${probe_root}/dist" || exit 1
        shasum -a 256 "${dmg_name}" > "${dmg_name}.sha256"
    )
    printf '%s\n' \
        '#!/bin/bash' \
        'case "${1:-}" in' \
        '    attach)' \
        "        printf '<?xml version=\"1.0\" encoding=\"UTF-8\"?>\\n'" \
        "        printf '<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\\n'" \
        "        printf '<plist version=\"1.0\"><dict><key>system-entities</key><array><dict>\\n'" \
        "        printf '<key>dev-entry</key><string>/dev/disk99</string>\\n'" \
        "        printf '<key>mount-point</key><string>%s</string>\\n' \"\${MACSTATS_TEST_MOUNT_POINT}\"" \
        "        printf '</dict></array></dict></plist>\\n'" \
        '        ;;' \
        '    detach)' \
        "        printf '%s\\n' \"\$*\" >> \"\${MACSTATS_DETACH_LOG}\"" \
        '        exit "${MACSTATS_DETACH_STATUS:-1}"' \
        '        ;;' \
        '    *) exit 64 ;;' \
        'esac' \
        > "${fake_bin}/hdiutil"
    chmod +x "${fake_bin}/hdiutil"
}

test_detach_failure_handling() {
    local probe_root fake_bin mount_point detach_log output status expected_detaches
    probe_root="${TEST_ROOT}/verify-probe"
    fake_bin="${probe_root}/fake-bin"
    mount_point="${probe_root}/mounted/MacStats"
    detach_log="${probe_root}/detach.log"
    output="${probe_root}/output.log"
    expected_detaches="${probe_root}/expected-detaches.log"

    prepare_verify_release_probe "${probe_root}" "${fake_bin}" "${mount_point}"
    printf '%s\n' 'detach /dev/disk99' 'detach -force /dev/disk99' > "${expected_detaches}"
    : > "${detach_log}"

    if PATH="${fake_bin}:${PATH}" \
        MACSTATS_TEST_MOUNT_POINT="${mount_point}" \
        MACSTATS_DETACH_LOG="${detach_log}" \
        MACSTATS_DETACH_STATUS=1 \
        MACSTATS_VERIFY_APP_STATUS=0 \
        /bin/bash "${probe_root}/Scripts/verify-release.sh" 0.1.0 1 > "${output}" 2>&1
    then
        status=0
    else
        status=$?
    fi

    if [ "${status}" -ne 0 ] && cmp -s "${expected_detaches}" "${detach_log}" && \
        /usr/bin/grep -Fq '/dev/disk99' "${output}"; then
        pass 'two detach failures make successful verification fail and report the exact device'
    else
        fail 'two detach failures make successful verification fail and report the exact device'
    fi

    : > "${detach_log}"
    if PATH="${fake_bin}:${PATH}" \
        MACSTATS_TEST_MOUNT_POINT="${mount_point}" \
        MACSTATS_DETACH_LOG="${detach_log}" \
        MACSTATS_DETACH_STATUS=1 \
        MACSTATS_VERIFY_APP_STATUS=23 \
        /bin/bash "${probe_root}/Scripts/verify-release.sh" 0.1.0 1 > "${output}" 2>&1
    then
        status=0
    else
        status=$?
    fi

    if [ "${status}" -eq 23 ] && cmp -s "${expected_detaches}" "${detach_log}"; then
        pass 'detach failure preserves an earlier non-zero verification status'
    else
        fail 'detach failure preserves an earlier non-zero verification status'
    fi
}

TEST_ROOT="$(mktemp -d -t macstats-release-safety)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

test_release_workflow_policy
test_documented_shell_validation
test_strict_source_version_validation
test_detach_failure_handling

if [ "${FAILURES}" -ne 0 ]; then
    printf '%s release safety test(s) failed.\n' "${FAILURES}" >&2
    exit 1
fi

printf 'All release safety tests passed.\n'
