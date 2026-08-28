#!/usr/bin/env bash
# Stamp channel build versions into app Info.plist files for CI builds.
#
# Inputs (env):
#   VERSION   resolved display version (e.g. 1.9.0-canary-2026.08.28.abc1234)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../release/lib.sh
source "${HERE}/../release/lib.sh"
cd "$(repo_root)"

require_env VERSION

MAIN_PLIST="LyricsX/Supporting Files/Info.plist"
HELPER_PLIST="LyricsXHelper/Info.plist"
BUILD_NUMBER="$(TZ=Asia/Shanghai date +%Y%m%d%H%M)"

stamp_plist() {
    local plist="$1"
    plist_buddy -c "Set :CFBundleShortVersionString ${VERSION}" "$plist"
    plist_buddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$plist"
}

stamp_plist "$MAIN_PLIST"
stamp_plist "$HELPER_PLIST"

log_info "Stamped CFBundleShortVersionString=${VERSION} CFBundleVersion=${BUILD_NUMBER}"
