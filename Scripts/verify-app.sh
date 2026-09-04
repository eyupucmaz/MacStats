#!/bin/bash
#
# verify-app.sh — enforce the release invariants of a MacStats app bundle.
#
# Usage: bash Scripts/verify-app.sh <path-to-MacStats.app> <expected-version> <expected-build> [expected-archs]

set -euo pipefail

usage() {
    printf 'usage: %s <path-to-MacStats.app> <expected-version> <expected-build> [expected-archs]\n' "$0" >&2
    exit 64
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

normalize_arch_set() {
    printf '%s\n' "$1" | tr ' ' '\n' | awk 'NF' | sort -u | paste -sd ' ' -
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage

APP_BUNDLE="$1"
EXPECTED_VERSION="$2"
EXPECTED_BUILD="$3"
EXPECTED_ARCHS="${4:-arm64 x86_64}"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
PLIST="${CONTENTS_DIR}/Info.plist"
EXECUTABLE="${CONTENTS_DIR}/MacOS/MacStats"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

[ -d "${APP_BUNDLE}" ] || die "app bundle not found: ${APP_BUNDLE}"
[ -f "${PLIST}" ] || die "Info.plist not found: ${PLIST}"
plutil -lint "${PLIST}" >/dev/null || die "Info.plist is invalid: ${PLIST}"

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}")"
[ "${BUNDLE_IDENTIFIER}" = 'com.eyupucmaz.MacStats' ] || die "unexpected bundle identifier: ${BUNDLE_IDENTIFIER}"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
[ "${APP_VERSION}" = "${EXPECTED_VERSION}" ] || die "expected version ${EXPECTED_VERSION}, found ${APP_VERSION}"

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"
[ "${BUILD_NUMBER}" = "${EXPECTED_BUILD}" ] || die "expected build ${EXPECTED_BUILD}, found ${BUILD_NUMBER}"

[ -x "${EXECUTABLE}" ] || die "executable is missing or not executable: ${EXECUTABLE}"
[ -d "${RESOURCES_DIR}/MacStats_MacStats.bundle" ] || die "SwiftPM resource bundle is missing"
[ -f "${RESOURCES_DIR}/Assets.car" ] || die "Assets.car is missing"
[ -f "${RESOURCES_DIR}/AppIcon.icns" ] || die "AppIcon.icns is missing"

ACTUAL_ARCHS="$(normalize_arch_set "$(lipo -archs "${EXECUTABLE}")")"
NORMALIZED_EXPECTED_ARCHS="$(normalize_arch_set "${EXPECTED_ARCHS}")"
[ "${ACTUAL_ARCHS}" = "${NORMALIZED_EXPECTED_ARCHS}" ] || die "expected architectures '${NORMALIZED_EXPECTED_ARCHS}', found '${ACTUAL_ARCHS}'"

codesign --verify --strict --deep --verbose=2 "${APP_BUNDLE}"

ENTITLEMENTS="$(codesign -d --entitlements :- "${APP_BUNDLE}" 2>&1)"
if printf '%s\n' "${ENTITLEMENTS}" | grep -q '<key>'; then
    die "unexpected entitlements in ${APP_BUNDLE}"
fi

printf 'Verified: %s (version %s, build %s, architectures: %s)\n' \
    "${APP_BUNDLE}" "${EXPECTED_VERSION}" "${EXPECTED_BUILD}" "${ACTUAL_ARCHS}"
