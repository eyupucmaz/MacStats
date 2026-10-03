#!/bin/bash
# Literal workflow snippets and generated probe scripts are intentionally single-quoted.
# shellcheck disable=SC2016

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
    local release_action='softprops/action-gh-release@efb35369e0ad2afab669f228072c1b0d510eae64 # v3.0.3 (Node 24)'

    require_literal "${workflow}" "${release_action}" \
        'release action is pinned to the verified Node 24 commit'
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
    require_literal "${workflow}" 'there are no SMC or fan writes' \
        'release body discloses that MacStats never writes to the SMC or fans'
    require_literal "${workflow}" 'does not control fans' \
        'release body discloses that fan control is not included'
    require_literal "${workflow}" 'App Mixer' \
        'release body names the App Mixer'
    require_literal "${workflow}" 'asks for audio-capture permission' \
        'release body discloses the App Mixer audio-capture permission prompt'
    require_literal "${workflow}" 'macOS 14.2 or later' \
        'release body discloses the App Mixer macOS requirement'
    forbid_literal "${workflow}" 'is monitoring-only' \
        'release body does not claim the app is monitoring-only'
    require_literal "${workflow}" 'ad-hoc signed and is not notarized' \
        'release body discloses signing and notarization status'
    require_literal "${workflow}" 'drag `MacStats.app` to Applications' \
        'release body includes drag-to-Applications installation'
    require_literal "${workflow}" 'Control-click' \
        'release body includes the Gatekeeper Control-click path'
    require_literal "${workflow}" 'Open Anyway' \
        'release body includes the Gatekeeper Open Anyway path'
    require_literal "${workflow}" 'shasum -a 256 -c MacStats-${{ env.RELEASE_VERSION }}-universal.dmg.sha256' \
        'release body derives the checksum filename from the release version'
    require_literal "${workflow}" 'RELEASE_VERSION: ${{ needs.build.outputs.version }}' \
        'publish job takes the release version from the validated tag'
    require_literal "${workflow}" 'git merge-base --is-ancestor "${tag_commit}" origin/main' \
        'release tag must be an ancestor of origin/main'
    forbid_literal "${workflow}" '0.1.0' \
        'release workflow does not hard-code a release version'
    if /usr/bin/awk '
        /^permissions:/ { top = 1; next }
        top && /^[^ ]/ { top = 0 }
        top && /contents: write/ { found = 1 }
        END { exit !found }
    ' "${REPO_ROOT}/${workflow}"; then
        fail 'release workflow does not grant contents: write workflow-wide'
    else
        pass 'release workflow does not grant contents: write workflow-wide'
    fi
    if [ "$(/usr/bin/grep -c 'contents: write' "${REPO_ROOT}/${workflow}")" -eq 1 ]; then
        pass 'exactly one release job requests contents: write'
    else
        fail 'exactly one release job requests contents: write'
    fi
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
        'https://github.com/eyupucmaz/MacStats/releases' \
        'README links to the GitHub releases'
}

test_version_comes_from_info_plist() {
    local file

    for file in '.github/workflows/ci.yml' 'Makefile'; do
        require_literal "${file}" "PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist" \
            "${file} reads the release version from Info.plist"
        forbid_literal "${file}" '0.1.0' \
            "${file} does not hard-code a release version"
    done
}

test_ci_hardening() {
    local file

    require_literal '.github/workflows/ci.yml' 'shellcheck Scripts/*.sh Tests/*.sh' \
        'CI runs shellcheck over every release and test script'
    for file in '.github/workflows/ci.yml' '.github/workflows/release.yml'; do
        require_literal "${file}" 'sudo xcode-select -s "${XCODE_APP}/Contents/Developer"' \
            "${file} pins the Xcode toolchain"
        require_literal "${file}" 'swift --version' \
            "${file} logs the Swift toolchain version"
        require_literal "${file}" 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1 (Node 24)' \
            "${file} pins upload-artifact to the verified Node 24 commit"
    done
}

test_release_gates() {
    local workflow='.github/workflows/release.yml'
    local file

    require_literal "${workflow}" 'bash Scripts/require-ci-success.sh "${GITHUB_REPOSITORY}" "${tag_commit}"' \
        'release requires CI to have passed on the tagged commit'
    require_literal "${workflow}" 'actions: read' \
        'release build job may read the CI runs of the tagged commit'
    require_literal "${workflow}" 'environment: release' \
        'publish job deploys through the protected release environment'
    require_literal "${workflow}" 'if [ "${GITHUB_REF}" != "refs/tags/${RELEASE_TAG}" ]; then' \
        'release runs only from the tag ref the release environment accepts'
    if /usr/bin/awk '
        /^permissions:/ { top = 1; next }
        top && /^[^ ]/ { top = 0 }
        top && /actions:/ { found = 1 }
        END { exit !found }
    ' "${REPO_ROOT}/${workflow}"; then
        fail 'release workflow does not grant actions access workflow-wide'
    else
        pass 'release workflow does not grant actions access workflow-wide'
    fi

    for file in '.github/workflows/ci.yml' '.github/workflows/release.yml' 'Makefile'; do
        require_literal "${file}" 'bash Scripts/build-number.sh' \
            "${file} derives the build number from the commit history"
        forbid_literal "${file}" 'GITHUB_RUN_NUMBER' \
            "${file} does not use the CI run number as the build number"
    done
    require_literal '.github/workflows/ci.yml' 'fetch-depth: 0' \
        'CI packaging checks out the full history for the build number'

    forbid_literal 'Scripts/build-app.sh' 'codesign --deep' \
        'build-app.sh does not sign with codesign --deep'
    forbid_literal 'Scripts/build-app.sh' '--force --deep' \
        'build-app.sh signing arguments do not include --deep'
    require_literal 'Scripts/verify-app.sh' 'ALLOWED_ENTITLEMENTS=()' \
        'the shipped entitlement allowlist is empty'
}

# A fake gh that replays canned `gh api --jq` output: response file N answers call N,
# `default` answers later calls, and a `fail` file makes every call fail.
write_fake_gh() {
    printf '%s\n' \
        '#!/bin/bash' \
        'count=$(( $(cat "${MACSTATS_GH_COUNT}") + 1 ))' \
        'printf '\''%s\n'\'' "${count}" > "${MACSTATS_GH_COUNT}"' \
        'printf '\''%s\n'\'' "$*" >> "${MACSTATS_GH_LOG}"' \
        '[ -f "${MACSTATS_GH_RESPONSES}/fail" ] && exit 1' \
        'response="${MACSTATS_GH_RESPONSES}/${count}"' \
        '[ -f "${response}" ] || response="${MACSTATS_GH_RESPONSES}/default"' \
        'cat "${response}"' \
        > "$1/gh"
    chmod +x "$1/gh"
}

run_require_ci_success() {
    local case_root="$1"
    shift
    printf '0\n' > "${case_root}/count"
    : > "${case_root}/gh.log"
    if PATH="${case_root}/bin:${PATH}" \
        MACSTATS_GH_COUNT="${case_root}/count" \
        MACSTATS_GH_LOG="${case_root}/gh.log" \
        MACSTATS_GH_RESPONSES="${case_root}/responses" \
        CI_WAIT_SECONDS=0 CI_WAIT_ATTEMPTS=3 CI_MISSING_ATTEMPTS=2 \
        /bin/bash "${REPO_ROOT}/Scripts/require-ci-success.sh" "$@" \
        > "${case_root}/output.log" 2>&1
    then
        return 0
    else
        return $?
    fi
}

new_ci_case() {
    local case_root="${TEST_ROOT}/ci-gate/$1"
    mkdir -p "${case_root}/bin" "${case_root}/responses"
    write_fake_gh "${case_root}/bin"
    : > "${case_root}/responses/default"
    printf '%s\n' "${case_root}"
}

test_require_ci_success() {
    local sha='0123456789abcdef0123456789abcdef01234567'
    local repo='eyupucmaz/MacStats'
    local case_root status

    case_root="$(new_ci_case success)"
    printf '%s\n' '11 completed failure' '12 completed success' > "${case_root}/responses/default"
    if run_require_ci_success "${case_root}" "${repo}" "${sha}" && \
        /usr/bin/grep -Fq "repos/${repo}/actions/workflows/ci.yml/runs?head_sha=${sha}&event=push" "${case_root}/gh.log"
    then
        pass 'CI gate accepts a commit with a successful push run of ci.yml'
    else
        fail 'CI gate accepts a commit with a successful push run of ci.yml'
    fi

    case_root="$(new_ci_case failure)"
    printf '%s\n' '21 completed failure' '22 completed cancelled' > "${case_root}/responses/default"
    if run_require_ci_success "${case_root}" "${repo}" "${sha}"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ] && [ "$(cat "${case_root}/count")" = 1 ] && \
        /usr/bin/grep -Fq 'did not succeed' "${case_root}/output.log"
    then
        pass 'CI gate rejects a commit whose CI runs all failed, without waiting'
    else
        fail 'CI gate rejects a commit whose CI runs all failed, without waiting'
    fi

    case_root="$(new_ci_case pending-then-success)"
    printf '%s\n' '31 in_progress none' > "${case_root}/responses/1"
    printf '%s\n' '31 completed success' > "${case_root}/responses/default"
    if run_require_ci_success "${case_root}" "${repo}" "${sha}" && [ "$(cat "${case_root}/count")" = 2 ]; then
        pass 'CI gate waits for a running CI run and accepts its success'
    else
        fail 'CI gate waits for a running CI run and accepts its success'
    fi

    case_root="$(new_ci_case pending-forever)"
    printf '%s\n' '41 queued none' > "${case_root}/responses/default"
    if run_require_ci_success "${case_root}" "${repo}" "${sha}"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ] && [ "$(cat "${case_root}/count")" = 3 ] && \
        /usr/bin/grep -Fq 'is still running' "${case_root}/output.log"
    then
        pass 'CI gate gives up after CI_WAIT_ATTEMPTS checks of a pending run'
    else
        fail 'CI gate gives up after CI_WAIT_ATTEMPTS checks of a pending run'
    fi

    case_root="$(new_ci_case missing)"
    if run_require_ci_success "${case_root}" "${repo}" "${sha}"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ] && [ "$(cat "${case_root}/count")" = 2 ] && \
        /usr/bin/grep -Fq 'has no push run' "${case_root}/output.log"
    then
        pass 'CI gate rejects a commit that never ran CI after CI_MISSING_ATTEMPTS checks'
    else
        fail 'CI gate rejects a commit that never ran CI after CI_MISSING_ATTEMPTS checks'
    fi

    case_root="$(new_ci_case api-failure)"
    : > "${case_root}/responses/fail"
    if run_require_ci_success "${case_root}" "${repo}" "${sha}"; then status=0; else status=$?; fi
    if [ "${status}" -ne 0 ] && /usr/bin/grep -Fq 'could not list' "${case_root}/output.log"; then
        pass 'CI gate fails closed when the runs API is unavailable'
    else
        fail 'CI gate fails closed when the runs API is unavailable'
    fi

    case_root="$(new_ci_case invalid-sha)"
    if run_require_ci_success "${case_root}" "${repo}" 'v0.2.0'; then status=0; else status=$?; fi
    if [ "${status}" -eq 64 ] && [ "$(cat "${case_root}/count")" = 0 ]; then
        pass 'CI gate requires a full commit SHA before calling the API'
    else
        fail 'CI gate requires a full commit SHA before calling the API'
    fi
}

test_build_number() {
    local repo_dir="${TEST_ROOT}/build-number/repo"
    local clone_dir="${TEST_ROOT}/build-number/shallow"
    local output status message

    mkdir -p "${repo_dir}"
    git -C "${repo_dir}" init -q
    for message in one two three; do
        git -C "${repo_dir}" -c user.name=probe -c user.email=probe@example.invalid \
            -c commit.gpgsign=false commit -q --allow-empty -m "${message}"
    done

    if output="$(/bin/bash "${REPO_ROOT}/Scripts/build-number.sh" "${repo_dir}" 2>&1)" && \
        [ "${output}" = 3 ]
    then
        pass 'build number is the number of commits reachable from HEAD'
    else
        fail 'build number is the number of commits reachable from HEAD'
    fi

    git clone -q --depth 1 "file://${repo_dir}" "${clone_dir}"
    if output="$(/bin/bash "${REPO_ROOT}/Scripts/build-number.sh" "${clone_dir}" 2>&1)"; then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -ne 0 ] && printf '%s\n' "${output}" | /usr/bin/grep -Fq 'shallow clone'; then
        pass 'build number refuses a shallow clone'
    else
        fail 'build number refuses a shallow clone'
    fi
}

# Builds a minimal signed MacStats.app that satisfies every other verify-app.sh check.
make_probe_app() {
    local app="$1"
    local entitlements="${2:-}"
    local contents="${app}/Contents"
    local sign_args=(--force --options runtime --sign -)

    mkdir -p "${contents}/MacOS" "${contents}/Resources/MacStats_MacStats.bundle"
    printf 'int main(void) { return 0; }\n' | \
        xcrun clang -arch arm64 -x c - -o "${contents}/MacOS/MacStats"
    cp "${REPO_ROOT}/Info.plist" "${contents}/Info.plist"
    : > "${contents}/Resources/Assets.car"
    : > "${contents}/Resources/AppIcon.icns"
    if [ -n "${entitlements}" ]; then
        sign_args+=(--entitlements "${entitlements}")
    fi
    codesign "${sign_args[@]}" "${app}" 2>/dev/null
}

run_verify_app() {
    local script="$1"
    local app="$2"
    local output="$3"
    local version

    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${REPO_ROOT}/Info.plist")"
    if /bin/bash "${script}" "${app}" "${version}" 1 arm64 > "${output}" 2>&1; then
        return 0
    else
        return $?
    fi
}

test_verify_app_allowlist() {
    local probe_root="${TEST_ROOT}/verify-app"
    local entitlements="${probe_root}/audio.entitlements"
    local allowing_script="${probe_root}/verify-app-allowing-audio-input.sh"
    local entitlement='com.apple.security.device.audio-input'
    local status

    mkdir -p "${probe_root}"
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict>' \
        "<key>${entitlement}</key><true/>" \
        '</dict></plist>' \
        > "${entitlements}"
    sed "s/^ALLOWED_ENTITLEMENTS=()\$/ALLOWED_ENTITLEMENTS=(${entitlement})/" \
        "${REPO_ROOT}/Scripts/verify-app.sh" > "${allowing_script}"

    make_probe_app "${probe_root}/plain/MacStats.app"
    if run_verify_app "${REPO_ROOT}/Scripts/verify-app.sh" "${probe_root}/plain/MacStats.app" \
        "${probe_root}/plain.log"
    then
        pass 'verify-app accepts a signed app without entitlements'
    else
        sed 's/^/    /' "${probe_root}/plain.log" >&2
        fail 'verify-app accepts a signed app without entitlements'
    fi

    make_probe_app "${probe_root}/entitled/MacStats.app" "${entitlements}"
    if run_verify_app "${REPO_ROOT}/Scripts/verify-app.sh" "${probe_root}/entitled/MacStats.app" \
        "${probe_root}/entitled.log"
    then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -ne 0 ] && /usr/bin/grep -Fq "allowlist in Scripts/verify-app.sh: ${entitlement}" \
        "${probe_root}/entitled.log"
    then
        pass 'verify-app rejects and names an entitlement missing from the allowlist'
    else
        fail 'verify-app rejects and names an entitlement missing from the allowlist'
    fi

    if /usr/bin/grep -Fqx "ALLOWED_ENTITLEMENTS=(${entitlement})" "${allowing_script}" && \
        run_verify_app "${allowing_script}" "${probe_root}/entitled/MacStats.app" \
            "${probe_root}/allowed.log"
    then
        pass 'verify-app accepts an entitlement once it is added to the allowlist'
    else
        sed 's/^/    /' "${probe_root}/allowed.log" >&2 || true
        fail 'verify-app accepts an entitlement once it is added to the allowlist'
    fi

    make_probe_app "${probe_root}/nested/MacStats.app"
    cp "${probe_root}/nested/MacStats.app/Contents/MacOS/MacStats" \
        "${probe_root}/nested/MacStats.app/Contents/Resources/helper"
    codesign --force --options runtime --sign - "${probe_root}/nested/MacStats.app" 2>/dev/null
    if run_verify_app "${REPO_ROOT}/Scripts/verify-app.sh" "${probe_root}/nested/MacStats.app" \
        "${probe_root}/nested.log"
    then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -ne 0 ] && /usr/bin/grep -Fq 'unexpected nested code' "${probe_root}/nested.log" && \
        /usr/bin/grep -Fq 'Contents/Resources/helper' "${probe_root}/nested.log"
    then
        pass 'verify-app rejects nested code that build-app.sh would not sign explicitly'
    else
        fail 'verify-app rejects nested code that build-app.sh would not sign explicitly'
    fi
}

next_minor_version() {
    local major minor
    IFS=. read -r major minor _ <<< "$1"
    printf '%s.%s.0\n' "${major}" "$((minor + 1))"
}

test_strict_source_version_validation() {
    local probe_root fake_bin swift_log output status source_version next_version
    probe_root="${TEST_ROOT}/build-probe"
    fake_bin="${probe_root}/fake-bin"
    swift_log="${probe_root}/swift.log"
    output="${probe_root}/output.log"
    source_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${REPO_ROOT}/Info.plist")"
    next_version="$(next_minor_version "${source_version}")"

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
        APP_VERSION="${source_version}" BUILD_NUMBER=1 RELEASE_STRICT=1 \
        /bin/bash "${probe_root}/Scripts/build-app.sh" > "${output}" 2>&1
    then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -eq 89 ] && [ -s "${swift_log}" ]; then
        pass "strict source version ${source_version} from Info.plist is accepted before compilation"
    else
        fail "strict source version ${source_version} from Info.plist is accepted before compilation"
    fi

    : > "${swift_log}"
    if PATH="${fake_bin}:${PATH}" MACSTATS_SWIFT_LOG="${swift_log}" \
        APP_VERSION="${next_version}" BUILD_NUMBER=1 RELEASE_STRICT=1 \
        /bin/bash "${probe_root}/Scripts/build-app.sh" > "${output}" 2>&1
    then
        status=0
    else
        status=$?
    fi
    if [ "${status}" -ne 0 ] && [ ! -s "${swift_log}" ] && \
        /usr/bin/grep -Fq "must exactly match source version ${source_version}" "${output}"; then
        pass "strict requested version ${next_version} is rejected before swift build"
    else
        fail "strict requested version ${next_version} is rejected before swift build"
    fi

    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0${source_version}" \
        "${probe_root}/Info.plist"
    : > "${swift_log}"
    if PATH="${fake_bin}:${PATH}" MACSTATS_SWIFT_LOG="${swift_log}" \
        APP_VERSION="${source_version}" BUILD_NUMBER=1 RELEASE_STRICT=1 \
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
test_version_comes_from_info_plist
test_ci_hardening
test_release_gates
test_require_ci_success
test_build_number
test_verify_app_allowlist
test_strict_source_version_validation
test_detach_failure_handling

if [ "${FAILURES}" -ne 0 ]; then
    printf '%s release safety test(s) failed.\n' "${FAILURES}" >&2
    exit 1
fi

printf 'All release safety tests passed.\n'
