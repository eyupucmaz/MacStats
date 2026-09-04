#!/bin/bash
#
# build-app.sh — assemble a real macOS .app bundle for MacStats.
#
# `swift build` only produces a bare Mach-O executable. MacStats is a menubar
# agent: LSUIElement, the bundle identifier, the icon and launch-at-login via
# SMAppService all require a genuine .app bundle, so this script builds one.
#
# Output: dist/MacStats.app
#
set -euo pipefail

APP_NAME="MacStats"
CONFIGURATION="release"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/.build/${CONFIGURATION}"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ASSET_CATALOG="${REPO_ROOT}/Sources/${APP_NAME}/Resources/Assets.xcassets"
SPM_RESOURCE_BUNDLE="${APP_NAME}_${APP_NAME}.bundle"
MIN_MACOS_VERSION="13.0"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "${REPO_ROOT}"

# ---------------------------------------------------------------------------
# 1. Compile
# ---------------------------------------------------------------------------
info "Building ${APP_NAME} (${CONFIGURATION})…"
swift build -c "${CONFIGURATION}"

EXECUTABLE="${BUILD_DIR}/${APP_NAME}"
[ -f "${EXECUTABLE}" ] || die "expected executable not found at ${EXECUTABLE}"

# ---------------------------------------------------------------------------
# 2. Assemble the bundle skeleton
# ---------------------------------------------------------------------------
info "Assembling ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cp "${REPO_ROOT}/Info.plist" "${CONTENTS_DIR}/Info.plist"
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

# The SwiftPM-generated resource bundle must sit next to the executable's
# bundle so Bundle.module can find it at runtime.
if [ -d "${BUILD_DIR}/${SPM_RESOURCE_BUNDLE}" ]; then
    info "Copying resource bundle ${SPM_RESOURCE_BUNDLE}…"
    cp -R "${BUILD_DIR}/${SPM_RESOURCE_BUNDLE}" "${RESOURCES_DIR}/"
else
    warn "SwiftPM resource bundle ${SPM_RESOURCE_BUNDLE} not found in ${BUILD_DIR} — Bundle.module lookups will fail at runtime."
fi

# ---------------------------------------------------------------------------
# 3. Compile the asset catalog (best effort)
# ---------------------------------------------------------------------------
ICON_PRODUCED=0

compile_assets() {
    if [ ! -d "${ASSET_CATALOG}" ]; then
        warn "no asset catalog at ${ASSET_CATALOG} — skipping Assets.car."
        return 1
    fi

    local actool
    if ! actool="$(xcrun --find actool 2>/dev/null)" || [ ! -x "${actool}" ]; then
        warn "actool not available (Command Line Tools only?) — the app will ship without Assets.car or an icon."
        return 1
    fi

    # An .appiconset with only a Contents.json and no image files makes actool
    # fail. Detect that and compile the catalog without --app-icon instead.
    local appicon_args=()
    local iconset="${ASSET_CATALOG}/AppIcon.appiconset"
    if [ -d "${iconset}" ] && \
       [ -n "$(find "${iconset}" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print -quit)" ]; then
        appicon_args=(--app-icon AppIcon)
    else
        warn "AppIcon.appiconset contains no image files — building without an app icon."
        warn "Drop 16/32/128/256/512pt @1x+@2x PNGs into ${iconset} to get one."
    fi

    local partial_plist
    partial_plist="$(mktemp -t macstats-actool-plist)"
    local actool_log
    actool_log="$(mktemp -t macstats-actool-log)"

    if "${actool}" "${ASSET_CATALOG}" \
        --compile "${RESOURCES_DIR}" \
        --platform macosx \
        --minimum-deployment-target "${MIN_MACOS_VERSION}" \
        --output-partial-info-plist "${partial_plist}" \
        --output-format human-readable-text \
        ${appicon_args[@]+"${appicon_args[@]}"} > "${actool_log}" 2>&1
    then
        info "Compiled asset catalog into ${RESOURCES_DIR}/Assets.car"
        # actool names the .icns after the icon set; normalise it to AppIcon.icns
        # so it matches CFBundleIconFile in Info.plist.
        local produced_icns
        produced_icns="$(find "${RESOURCES_DIR}" -maxdepth 1 -name '*.icns' -print -quit)"
        if [ -n "${produced_icns}" ]; then
            [ "${produced_icns}" = "${RESOURCES_DIR}/AppIcon.icns" ] || mv "${produced_icns}" "${RESOURCES_DIR}/AppIcon.icns"
            ICON_PRODUCED=1
        fi
        rm -f "${partial_plist}" "${actool_log}"
        return 0
    else
        warn "actool failed; continuing without Assets.car. Output:"
        sed 's/^/    /' "${actool_log}" >&2 || true
        rm -f "${partial_plist}" "${actool_log}"
        return 1
    fi
}

compile_assets || true

if [ "${ICON_PRODUCED}" -eq 0 ]; then
    # Keep the bundle honest: do not advertise an icon file that isn't there.
    plutil -remove CFBundleIconFile "${CONTENTS_DIR}/Info.plist" >/dev/null 2>&1 || true
    plutil -remove CFBundleIconName "${CONTENTS_DIR}/Info.plist" >/dev/null 2>&1 || true
    warn "No AppIcon.icns produced — MacStats will use the generic application icon."
    warn "(This does not affect the menubar item, which is drawn from an SF Symbol.)"
fi

plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null || die "Info.plist is not a valid property list"

# ---------------------------------------------------------------------------
# 4. Ad-hoc code signature
# ---------------------------------------------------------------------------
info "Ad-hoc signing…"
codesign --force --deep --sign - --options runtime "${APP_BUNDLE}"
codesign --verify --verbose=1 "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 5. Report
# ---------------------------------------------------------------------------
BUNDLE_SIZE="$(du -sh "${APP_BUNDLE}" | cut -f1)"

cat <<EOF

Built: ${APP_BUNDLE}  (${BUNDLE_SIZE})

Run it:
    open "${APP_BUNDLE}"

Install it:
    cp -R "${APP_BUNDLE}" /Applications/

Gatekeeper caveat
-----------------
This bundle is signed ad-hoc (\`--sign -\`) and is NOT notarized. macOS will
refuse the first launch with "cannot be opened because the developer cannot be
verified". To open it anyway:

    * right-click (or Control-click) the app in Finder and choose "Open", then
      confirm in the dialog; or
    * System Settings > Privacy & Security > "Open Anyway"; or
    * remove the quarantine flag yourself:
          xattr -dr com.apple.quarantine "${APP_BUNDLE}"

Building it locally as above never sets the quarantine flag, so \`open\` works
straight away; the warning applies to copies you download or share.
EOF
