#!/bin/bash
#
# package-dmg.sh — package a verified MacStats app as a universal DMG.

set -euo pipefail

usage() {
    printf 'usage: %s <semantic-version>\n' "$0" >&2
    exit 64
}

[ "$#" -eq 1 ] || usage
VERSION="$1"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/MacStats.app"
VERIFY_APP="${REPO_ROOT}/Scripts/verify-app.sh"
DMG_NAME="MacStats-${VERSION}-universal.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
CHECKSUM_PATH="${DMG_PATH}.sha256"
STAGING_DIR=""
MOUNT_DEVICE=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [ -n "${MOUNT_DEVICE}" ]; then
        hdiutil detach "${MOUNT_DEVICE}" >/dev/null 2>&1 || true
    fi
    if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
        rm -rf -- "${STAGING_DIR}"
    fi
    exit "${status}"
}

trap cleanup EXIT INT TERM

[ -d "${APP_BUNDLE}" ] || die "app bundle not found: ${APP_BUNDLE}"
[ -f "${APP_BUNDLE}/Contents/Info.plist" ] || die "Info.plist not found in staged app"

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_BUNDLE}/Contents/Info.plist")"
[[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]] || die "staged app build number must be a positive integer"
bash "${VERIFY_APP}" "${APP_BUNDLE}" "${VERSION}" "${BUILD_NUMBER}"

STAGING_DIR="$(mktemp -d -t macstats-dmg)"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/MacStats.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create -ov -format UDZO -fs HFS+ -volname "MacStats ${VERSION}" \
    -srcfolder "${STAGING_DIR}" "${DMG_PATH}"

(
    cd "${DIST_DIR}"
    shasum -a 256 "MacStats-${VERSION}-universal.dmg" \
        > "MacStats-${VERSION}-universal.dmg.sha256"
)

printf 'Packaged: %s\n' "${DMG_PATH}"
