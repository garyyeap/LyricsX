#!/usr/bin/env bash
# Resolve the next GitHub Release tag and artifact name for branch-based CI.
#
# Inputs (env):
#   BRANCH_NAME   release | beta | canary
#   GITHUB_SHA    full commit SHA
#   GITHUB_OUTPUT path to GitHub Actions output file (optional)
#
# Outputs (stdout and GITHUB_OUTPUT when set):
#   tag_name, version, artifact_name, release_name, prerelease, target_branch, rolling_tag

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../release/lib.sh
source "${HERE}/../release/lib.sh"
cd "$(repo_root)"

require_env BRANCH_NAME GITHUB_SHA

SHORT_SHA="${GITHUB_SHA:0:7}"

plist_version() {
    plist_buddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST_PATH"
}

stable_base_from_plist() {
    local version
    version="$(plist_version)"
    case "$version" in
        *-*) printf '%s\n' "${version%%-*}" ;;
        *)   printf '%s\n' "$version" ;;
    esac
}

latest_stable_tag() {
    local tag
    while IFS= read -r tag; do
        if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
    done < <(git tag -l 'v*' --sort=-v:refname)
    return 1
}

latest_beta_tag() {
    local tag
    while IFS= read -r tag; do
        if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
    done < <(git tag -l 'v*' --sort=-v:refname)
    return 1
}

increment_patch_version() {
    local version="${1#v}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"
    printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
}

resolve_release_version() {
    local latest base
    if latest="$(latest_stable_tag)"; then
        base="$(increment_patch_version "${latest#v}")"
    else
        base="$(increment_patch_version "$(stable_base_from_plist)")"
    fi
    printf '%s\n' "$base"
}

resolve_beta_version() {
    local latest base number
    if latest="$(latest_beta_tag)"; then
        if [[ "$latest" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-beta\.([0-9]+)$ ]]; then
            base="${BASH_REMATCH[1]}"
            number="$((BASH_REMATCH[2] + 1))"
            printf '%s-beta.%s\n' "$base" "$number"
            return 0
        fi
    fi

    base="$(stable_base_from_plist)"
    printf '%s-beta.1\n' "$base"
}

resolve_canary_base() {
    local latest
    if latest="$(latest_beta_tag)"; then
        if [[ "$latest" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-beta\.[0-9]+$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    if latest="$(latest_stable_tag)"; then
        printf '%s\n' "${latest#v}"
        return 0
    fi

    stable_base_from_plist
}

resolve_canary_build_id() {
    local base date_stamp
    base="$(resolve_canary_base)"
    date_stamp="$(date -u +%Y.%m.%d)"
    printf '%s-canary-%s.%s\n' "$base" "$date_stamp" "$SHORT_SHA"
}

case "$BRANCH_NAME" in
    release)
        VERSION="$(resolve_release_version)"
        TAG_NAME="v${VERSION}"
        ARTIFACT_NAME="LyricsX-${TAG_NAME}.zip"
        RELEASE_NAME="${TAG_NAME}"
        PRERELEASE="false"
        ROLLING_TAG="false"
        ;;
    beta)
        VERSION="$(resolve_beta_version)"
        TAG_NAME="v${VERSION}"
        ARTIFACT_NAME="LyricsX-${TAG_NAME}.zip"
        RELEASE_NAME="${TAG_NAME}"
        PRERELEASE="true"
        ROLLING_TAG="false"
        ;;
    canary)
        VERSION="$(resolve_canary_build_id)"
        TAG_NAME="v$(resolve_canary_base)-canary"
        ARTIFACT_NAME="LyricsX-v${VERSION}.zip"
        RELEASE_NAME="v${VERSION}"
        PRERELEASE="true"
        ROLLING_TAG="true"
        ;;
    *)
        die "Unsupported branch for release CI: '${BRANCH_NAME}'"
        ;;
esac

log_info "Resolved branch=${BRANCH_NAME} tag=${TAG_NAME} release=${RELEASE_NAME} artifact=${ARTIFACT_NAME} prerelease=${PRERELEASE} rolling_tag=${ROLLING_TAG}"

printf 'tag_name=%s\n' "$TAG_NAME"
printf 'version=%s\n' "$VERSION"
printf 'artifact_name=%s\n' "$ARTIFACT_NAME"
printf 'release_name=%s\n' "$RELEASE_NAME"
printf 'prerelease=%s\n' "$PRERELEASE"
printf 'target_branch=%s\n' "$BRANCH_NAME"
printf 'rolling_tag=%s\n' "$ROLLING_TAG"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        printf 'tag_name=%s\n' "$TAG_NAME"
        printf 'version=%s\n' "$VERSION"
        printf 'artifact_name=%s\n' "$ARTIFACT_NAME"
        printf 'release_name=%s\n' "$RELEASE_NAME"
        printf 'prerelease=%s\n' "$PRERELEASE"
        printf 'target_branch=%s\n' "$BRANCH_NAME"
        printf 'rolling_tag=%s\n' "$ROLLING_TAG"
    } >> "$GITHUB_OUTPUT"
fi
