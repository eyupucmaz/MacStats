#!/bin/bash
#
# verify-release.sh — validate a MacStats DMG and its mounted contents.

set -euo pipefail

usage() {
    printf 'usage: %s <semantic-version> [expected-build]\n' "$0" >&2
    exit 64
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
VERSION="$1"
EXPECTED_BUILD="${2:-1}"
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "${VERSION}" =~ ${SEMVER_PATTERN} ]] || usage
[[ "${EXPECTED_BUILD}" =~ ^[1-9][0-9]*$ ]] || usage

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
VERIFY_APP="${REPO_ROOT}/Scripts/verify-app.sh"
DMG_NAME="MacStats-${VERSION}-universal.dmg"
CHECKSUM_NAME="${DMG_NAME}.sha256"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
CHECKSUM_PATH="${DIST_DIR}/${CHECKSUM_NAME}"
ATTACH_PLIST=""
MOUNT_DEVICE=""
MOUNT_POINT=""

attached_device_from_plist() {
    local entity_index candidate_device
    [ -n "${ATTACH_PLIST}" ] && [ -f "${ATTACH_PLIST}" ] || return 1

    for entity_index in {0..63}; do
        candidate_device="$(/usr/libexec/PlistBuddy -c "Print :system-entities:${entity_index}:dev-entry" "${ATTACH_PLIST}" 2>/dev/null || true)"
        if [ -n "${candidate_device}" ]; then
            printf '%s\n' "${candidate_device}"
            return 0
        fi
    done
    return 1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [ -z "${MOUNT_DEVICE}" ]; then
        MOUNT_DEVICE="$(attached_device_from_plist || true)"
    fi
    if [ -n "${MOUNT_DEVICE}" ]; then
        if ! hdiutil detach "${MOUNT_DEVICE}" >/dev/null 2>&1; then
            printf 'warning: could not detach %s normally; retrying with force\n' \
                "${MOUNT_DEVICE}" >&2
            if ! hdiutil detach -force "${MOUNT_DEVICE}" >/dev/null 2>&1; then
                printf 'error: could not detach mounted image device %s\n' \
                    "${MOUNT_DEVICE}" >&2
                if [ "${status}" -eq 0 ]; then
                    status=1
                fi
            fi
        fi
    fi
    if [ -n "${ATTACH_PLIST}" ] && [ -f "${ATTACH_PLIST}" ]; then
        rm -f -- "${ATTACH_PLIST}"
    fi
    exit "${status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -f "${DMG_PATH}" ] || die "DMG not found: ${DMG_PATH}"
[ -f "${CHECKSUM_PATH}" ] || die "checksum not found: ${CHECKSUM_PATH}"
if ! awk -v dmg_name="${DMG_NAME}" '
    NR == 1 && NF == 2 && length($1) == 64 && $1 ~ /^[0-9A-Fa-f]+$/ && $2 == dmg_name { valid = 1 }
    END { exit !(NR == 1 && valid) }
' "${CHECKSUM_PATH}"; then
    die "checksum must name only ${DMG_NAME}"
fi

(
    cd "${DIST_DIR}"
    shasum -a 256 -c "${CHECKSUM_NAME}"
)

ATTACH_PLIST="$(mktemp -t macstats-dmg-attach)"
hdiutil attach -readonly -nobrowse -plist "${DMG_PATH}" > "${ATTACH_PLIST}"
MOUNT_DEVICE="$(attached_device_from_plist)" || die "mounted image did not report a device entry"

for entity_index in {0..63}; do
    candidate_mount_point="$(/usr/libexec/PlistBuddy -c "Print :system-entities:${entity_index}:mount-point" "${ATTACH_PLIST}" 2>/dev/null || true)"
    [ -n "${candidate_mount_point}" ] || continue
    MOUNT_POINT="${candidate_mount_point}"
    break
done

[ -n "${MOUNT_POINT}" ] || die "mounted image did not report a mount point"
[ -d "${MOUNT_POINT}/MacStats.app" ] || die "mounted app bundle not found"
[ -L "${MOUNT_POINT}/Applications" ] || die "mounted Applications entry is not a symlink"
[ "$(readlink "${MOUNT_POINT}/Applications")" = '/Applications' ] || die "mounted Applications symlink has an unexpected target"

bash "${VERIFY_APP}" "${MOUNT_POINT}/MacStats.app" "${VERSION}" "${EXPECTED_BUILD}"

if xattr -p com.apple.quarantine "${MOUNT_POINT}/MacStats.app" >/dev/null 2>&1; then
    die "mounted app has a quarantine attribute"
fi

printf 'Verified release: %s (version %s, build %s)\n' \
    "${DMG_PATH}" "${VERSION}" "${EXPECTED_BUILD}"
