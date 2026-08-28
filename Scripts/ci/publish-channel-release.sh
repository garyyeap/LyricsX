#!/usr/bin/env bash
# Create or update a GitHub Release for channel CI builds.
#
# Inputs (env):
#   TAG_NAME       e.g. v1.9.0-canary
#   RELEASE_NAME   release title
#   ARTIFACT_PATH  path to the zip to upload
#   PRERELEASE     true | false
#   ROLLING_TAG    true | false
#   GITHUB_SHA     commit to point the tag/release at

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../release/lib.sh
source "${HERE}/../release/lib.sh"

require_env TAG_NAME RELEASE_NAME ARTIFACT_PATH PRERELEASE ROLLING_TAG GITHUB_SHA
[ -f "$ARTIFACT_PATH" ] || die "Missing artifact: ${ARTIFACT_PATH}"

if ! command -v gh >/dev/null 2>&1; then
    die "gh CLI is required to publish channel releases"
fi

if gh release view "$TAG_NAME" >/dev/null 2>&1; then
    log_info "Updating existing release ${TAG_NAME} -> ${GITHUB_SHA}"
    EDIT_ARGS=(--title "$RELEASE_NAME" --target "$GITHUB_SHA")
    if [ "$PRERELEASE" = "true" ]; then
        EDIT_ARGS+=(--prerelease)
    else
        EDIT_ARGS+=(--prerelease=false)
    fi
    gh release edit "$TAG_NAME" "${EDIT_ARGS[@]}"
    gh release upload "$TAG_NAME" "$ARTIFACT_PATH" --clobber
else
    log_info "Creating release ${TAG_NAME}"
    CREATE_ARGS=(
        "$TAG_NAME"
        "$ARTIFACT_PATH"
        --target "$GITHUB_SHA"
        --title "$RELEASE_NAME"
    )
    if [ "$PRERELEASE" = "true" ]; then
        CREATE_ARGS+=(--prerelease)
    fi
    gh release create "${CREATE_ARGS[@]}"
fi

if [ "$ROLLING_TAG" = "true" ]; then
    log_info "Moving rolling tag ${TAG_NAME} to ${GITHUB_SHA}"
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git tag -fa "$TAG_NAME" "$GITHUB_SHA" -m "$RELEASE_NAME"
    git push -f origin "$TAG_NAME"
fi

log_info "Published ${TAG_NAME} (${RELEASE_NAME})"
