#!/bin/bash
#
# verify-app.sh — enforce the release invariants of a MacStats app bundle.
#
# Usage: bash Scripts/verify-app.sh <path-to-MacStats.app> <expected-version> <expected-build> [expected-archs]

set -euo pipefail

# Entitlements the signed app may carry, by key. Empty: MacStats ships without
# entitlements, so any entitlement in the signature fails verification.
#
# To ship an entitlement:
#   1. Create an entitlements plist and pass it to codesign in Scripts/build-app.sh
#      (`--entitlements <file>`).
#   2. Add its key here, for example:
#        ALLOWED_ENTITLEMENTS=(com.apple.security.device.audio-input)
#   3. Explain in the pull request why the app needs it (see CONTRIBUTING.md).
ALLOWED_ENTITLEMENTS=()

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

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then usage; fi

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

# Every language the app declares must ship its Info.plist strings (main bundle)
# and its string table (SwiftPM resource bundle). SwiftPM's native build system
# lays the resource bundle out flat; swiftbuild nests it in Contents/Resources.
LOCALIZATIONS=()
while LOCALIZATION="$(plutil -extract "CFBundleLocalizations.${#LOCALIZATIONS[@]}" raw -o - "${PLIST}" 2>/dev/null)"; do
    LOCALIZATIONS+=("${LOCALIZATION}")
done
[ "${#LOCALIZATIONS[@]}" -ne 0 ] || die "Info.plist lists no CFBundleLocalizations"
STRING_TABLES="${RESOURCES_DIR}/MacStats_MacStats.bundle"
if [ -d "${STRING_TABLES}/Contents/Resources" ]; then
    STRING_TABLES="${STRING_TABLES}/Contents/Resources"
fi
for LOCALIZATION in "${LOCALIZATIONS[@]}"; do
    [ -f "${RESOURCES_DIR}/${LOCALIZATION}.lproj/InfoPlist.strings" ] \
        || die "InfoPlist.strings is missing for localization '${LOCALIZATION}'"
    [ -f "${STRING_TABLES}/${LOCALIZATION}.lproj/Localizable.strings" ] \
        || die "Localizable.strings is missing for localization '${LOCALIZATION}'"
done

ACTUAL_ARCHS="$(normalize_arch_set "$(lipo -archs "${EXECUTABLE}")")"
NORMALIZED_EXPECTED_ARCHS="$(normalize_arch_set "${EXPECTED_ARCHS}")"
[ "${ACTUAL_ARCHS}" = "${NORMALIZED_EXPECTED_ARCHS}" ] || die "expected architectures '${NORMALIZED_EXPECTED_ARCHS}', found '${ACTUAL_ARCHS}'"

codesign --verify --strict --deep --verbose=2 "${APP_BUNDLE}"

# Everything except the main executable must be data: build-app.sh signs only the
# bundle, so nested code would need its own explicit signature first.
NESTED_CODE=()
while IFS= read -r -d '' bundle_file; do
    [ "${bundle_file}" = "${EXECUTABLE}" ] && continue
    if file -b "${bundle_file}" | grep -q 'Mach-O'; then
        NESTED_CODE+=("${bundle_file#"${APP_BUNDLE}/"}")
    fi
done < <(find "${CONTENTS_DIR}" -type f -print0)
if [ "${#NESTED_CODE[@]}" -ne 0 ]; then
    die "unexpected nested code; sign it explicitly in build-app.sh first: ${NESTED_CODE[*]}"
fi

ENTITLEMENTS_PLIST="$(mktemp -t macstats-entitlements)"
trap 'rm -f -- "${ENTITLEMENTS_PLIST}"' EXIT
codesign -d --entitlements - --xml "${APP_BUNDLE}" > "${ENTITLEMENTS_PLIST}" 2>/dev/null \
    || die "could not read the entitlements of ${APP_BUNDLE}"
UNEXPECTED_ENTITLEMENTS=()
if [ -s "${ENTITLEMENTS_PLIST}" ]; then
    plutil -convert xml1 "${ENTITLEMENTS_PLIST}" \
        || die "entitlements of ${APP_BUNDLE} are not a valid property list"
    # Read the top-level keys of the entitlements dictionary, one per line.
    while IFS= read -r entitlement; do
        allowed=0
        for allowed_entitlement in ${ALLOWED_ENTITLEMENTS[@]+"${ALLOWED_ENTITLEMENTS[@]}"}; do
            if [ "${entitlement}" = "${allowed_entitlement}" ]; then
                allowed=1
                break
            fi
        done
        [ "${allowed}" = 1 ] || UNEXPECTED_ENTITLEMENTS+=("${entitlement}")
    done < <(awk '
        /<dict>/ { depth++ }
        /<\/dict>/ { depth-- }
        depth == 1 && /<key>/ {
            sub(/.*<key>/, "")
            sub(/<\/key>.*/, "")
            print
        }
    ' "${ENTITLEMENTS_PLIST}")
fi
if [ "${#UNEXPECTED_ENTITLEMENTS[@]}" -ne 0 ]; then
    die "entitlements missing from the allowlist in Scripts/verify-app.sh: ${UNEXPECTED_ENTITLEMENTS[*]}"
fi

printf 'Verified: %s (version %s, build %s, architectures: %s)\n' \
    "${APP_BUNDLE}" "${EXPECTED_VERSION}" "${EXPECTED_BUILD}" "${ACTUAL_ARCHS}"
