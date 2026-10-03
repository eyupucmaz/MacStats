#!/bin/bash
#
# build-app.sh — assemble, sign, and verify a versioned MacStats app bundle.

set -euo pipefail

APP_NAME="MacStats"
CONFIGURATION="release"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ASSET_CATALOG="${REPO_ROOT}/Sources/${APP_NAME}/Resources/Assets.xcassets"
SPM_RESOURCE_BUNDLE="${APP_NAME}_${APP_NAME}.bundle"
MIN_MACOS_VERSION="13.0"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "${REPO_ROOT}"

SOURCE_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)" \
    || die "could not read CFBundleShortVersionString from source Info.plist"
APP_VERSION="${APP_VERSION:-${SOURCE_APP_VERSION}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)}"
ARCHS="${ARCHS:-arm64 x86_64}"
RELEASE_STRICT="${RELEASE_STRICT:-0}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-none}"

SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "${APP_VERSION}" =~ ${SEMVER_PATTERN} ]] \
    || die "APP_VERSION must use MAJOR.MINOR.PATCH format without leading zeroes"
[[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER must be a positive integer"
case "${ARCHS}" in
    'arm64 x86_64'|arm64|x86_64) ;;
    *) die "ARCHS must be one of: 'arm64 x86_64', arm64, x86_64" ;;
esac
case "${RELEASE_STRICT}" in
    0|1) ;;
    *) die "RELEASE_STRICT must be 0 or 1" ;;
esac
if [ "${RELEASE_STRICT}" = 1 ]; then
    [[ "${SOURCE_APP_VERSION}" =~ ${SEMVER_PATTERN} ]] \
        || die "source CFBundleShortVersionString must use MAJOR.MINOR.PATCH format without leading zeroes"
    [ "${APP_VERSION}" = "${SOURCE_APP_VERSION}" ] \
        || die "APP_VERSION ${APP_VERSION} must exactly match source version ${SOURCE_APP_VERSION} in RELEASE_STRICT=1"
fi

# ---------------------------------------------------------------------------
# 1. Compile and resolve the SwiftPM products.
# ---------------------------------------------------------------------------
if [ "${ARCHS}" = 'arm64 x86_64' ]; then
    info "Building ${APP_NAME} (${CONFIGURATION}, Universal 2)…"
    swift build -c "${CONFIGURATION}" --arch arm64 --arch x86_64
    # Ask SwiftPM for the output directory: it moved from .build/apple/ to .build/out/
    # in newer toolchains.
    PRODUCT_DIR="$(swift build -c "${CONFIGURATION}" --arch arm64 --arch x86_64 --show-bin-path)"
else
    info "Building ${APP_NAME} (${CONFIGURATION}, ${ARCHS})…"
    swift build -c "${CONFIGURATION}" --arch "${ARCHS}"
    PRODUCT_DIR="$(swift build -c "${CONFIGURATION}" --arch "${ARCHS}" --show-bin-path)"
fi

EXECUTABLE="${PRODUCT_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${PRODUCT_DIR}/${SPM_RESOURCE_BUNDLE}"
[ -f "${EXECUTABLE}" ] || die "expected executable not found at ${EXECUTABLE}"

# ---------------------------------------------------------------------------
# 2. Assemble the bundle and stage release metadata.
# ---------------------------------------------------------------------------
info "Assembling ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
cp "${REPO_ROOT}/Info.plist" "${CONTENTS_DIR}/Info.plist"
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"

if [ -d "${RESOURCE_BUNDLE}" ]; then
    info "Copying resource bundle ${SPM_RESOURCE_BUNDLE}…"
    cp -R "${RESOURCE_BUNDLE}" "${RESOURCES_DIR}/"
elif [ "${RELEASE_STRICT}" = 1 ]; then
    die "SwiftPM resource bundle not found: ${RESOURCE_BUNDLE}"
else
    warn "SwiftPM resource bundle not found: ${RESOURCE_BUNDLE}"
fi

# ---------------------------------------------------------------------------
# 3. Compile the asset catalog.
# ---------------------------------------------------------------------------
compile_assets() {
    [ -d "${ASSET_CATALOG}" ] || {
        warn "no asset catalog at ${ASSET_CATALOG}"
        return 1
    }

    local actool
    if ! actool="$(xcrun --find actool 2>/dev/null)" || [ ! -x "${actool}" ]; then
        warn "actool is unavailable"
        return 1
    fi

    local partial_plist actool_log produced_icns
    partial_plist="$(mktemp -t macstats-actool-plist)"
    actool_log="$(mktemp -t macstats-actool-log)"
    if ! "${actool}" "${ASSET_CATALOG}" \
        --compile "${RESOURCES_DIR}" \
        --platform macosx \
        --minimum-deployment-target "${MIN_MACOS_VERSION}" \
        --app-icon AppIcon \
        --output-partial-info-plist "${partial_plist}" \
        --output-format human-readable-text > "${actool_log}" 2>&1
    then
        warn "actool failed:"
        sed 's/^/    /' "${actool_log}" >&2 || true
        rm -f "${partial_plist}" "${actool_log}"
        return 1
    fi

    produced_icns="$(find "${RESOURCES_DIR}" -maxdepth 1 -name '*.icns' -print -quit)"
    if [ -n "${produced_icns}" ] && [ "${produced_icns}" != "${RESOURCES_DIR}/AppIcon.icns" ]; then
        mv "${produced_icns}" "${RESOURCES_DIR}/AppIcon.icns"
    fi
    rm -f "${partial_plist}" "${actool_log}"
}

if ! compile_assets; then
    [ "${RELEASE_STRICT}" = 1 ] && die "asset compilation is required for a strict release"
fi

if [ ! -f "${RESOURCES_DIR}/Assets.car" ] || [ ! -f "${RESOURCES_DIR}/AppIcon.icns" ]; then
    if [ "${RELEASE_STRICT}" = 1 ]; then
        die "asset compilation did not produce Assets.car and AppIcon.icns"
    fi
    warn "bundle is missing Assets.car and/or AppIcon.icns"
fi

plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null || die "staged Info.plist is invalid"

# ---------------------------------------------------------------------------
# 4. Sign and verify the finished bundle.
# ---------------------------------------------------------------------------
# The bundle has no nested code (verify-app.sh enforces this), so one signature
# over the bundle is enough. Do not add --deep: if nested code is ever added,
# sign each item explicitly, inside out, before signing the bundle.
info "Signing…"
sign_args=(--force --options runtime --sign "${CODE_SIGN_IDENTITY}")
if [ "${CODE_SIGN_TIMESTAMP}" = 1 ]; then
    sign_args+=(--timestamp)
fi
codesign "${sign_args[@]}" "${APP_BUNDLE}"

bash "${REPO_ROOT}/Scripts/verify-app.sh" "${APP_BUNDLE}" "${APP_VERSION}" "${BUILD_NUMBER}" "${ARCHS}"

BUNDLE_SIZE="$(du -sh "${APP_BUNDLE}" | cut -f1)"
printf '\nBuilt and verified: %s (%s)\n' "${APP_BUNDLE}" "${BUNDLE_SIZE}"
