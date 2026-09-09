#!/usr/bin/env bash
# Resolve the next GitHub Release tag and artifact name for branch-based CI.
#
# Inputs (env):
#   BRANCH_NAME   release | beta | canary
#   GITHUB_SHA    full commit SHA
#   GITHUB_OUTPUT path to GitHub Actions output file (optional)
#
# Outputs (stdout and GITHUB_OUTPUT when set):
#   tag_name, version, artifact_name, release_name, prerelease, target_branch,
#   rolling_tag, channel_line, plist_version

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../release/lib.sh
source "${HERE}/../release/lib.sh"
cd "$(repo_root)"

require_env BRANCH_NAME GITHUB_SHA

SHORT_SHA="${GITHUB_SHA:0:7}"

fetch_channel_refs() {
    git fetch origin release beta master --tags --quiet 2>/dev/null || true
}

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

merged_branch_tip() {
    local tip="${1:-HEAD}"
    if git rev-parse -q --verify "${tip}^2" >/dev/null 2>&1; then
        git rev-parse "${tip}^2"
        return 0
    fi
    printf '%s\n' "$tip"
}

closest_release_line_merge_base() {
    local tip="$1"
    local mb_release mb_master dist_release dist_master

    mb_release="$(git merge-base "$tip" origin/release 2>/dev/null || true)"
    mb_master="$(git merge-base "$tip" origin/master 2>/dev/null || true)"

    if [ -n "$mb_release" ] && [ -n "$mb_master" ]; then
        dist_release="$(git rev-list --count "${mb_release}..${tip}" 2>/dev/null || echo 999999)"
        dist_master="$(git rev-list --count "${mb_master}..${tip}" 2>/dev/null || echo 999999)"
        if [ "$dist_master" -lt "$dist_release" ]; then
            printf '%s\n' "$mb_master"
            return 0
        fi
        printf '%s\n' "$mb_release"
        return 0
    fi

    if [ -n "$mb_release" ]; then
        printf '%s\n' "$mb_release"
        return 0
    fi

    if [ -n "$mb_master" ]; then
        printf '%s\n' "$mb_master"
        return 0
    fi

    return 1
}

detect_version_line() {
    local tip merged_tip mb_beta mb_stable dist_beta dist_stable

    tip="${1:-HEAD}"
    merged_tip="$(merged_branch_tip "$tip")"

    mb_beta="$(git merge-base "$merged_tip" origin/beta 2>/dev/null || true)"
    if ! mb_stable="$(closest_release_line_merge_base "$merged_tip")"; then
        if [ -n "$mb_beta" ]; then
            printf 'beta\n'
        else
            printf 'stable\n'
        fi
        return 0
    fi

    if [ -z "$mb_beta" ]; then
        printf 'stable\n'
        return 0
    fi

    dist_beta="$(git rev-list --count "${mb_beta}..${merged_tip}" 2>/dev/null || echo 999999)"
    dist_stable="$(git rev-list --count "${mb_stable}..${merged_tip}" 2>/dev/null || echo 999999)"

    if [ "$dist_beta" -lt "$dist_stable" ]; then
        printf 'beta\n'
        return 0
    fi

    if [ "$dist_beta" -gt "$dist_stable" ]; then
        printf 'stable\n'
        return 0
    fi

    # Tied distance: commits based on the same master-line point are stable-line work.
    mb_master_ref="$(git merge-base "$merged_tip" origin/master 2>/dev/null || true)"
    if [ -n "$mb_master_ref" ] && [ "$mb_beta" = "$mb_master_ref" ] && [ "$mb_stable" = "$mb_master_ref" ]; then
        printf 'stable\n'
        return 0
    fi

    # Otherwise prefer beta when the beta series is ahead of the master-line stable series.
    if [ "$(beta_base_version)" != "$(stable_base_on_master_line "$merged_tip")" ]; then
        printf 'beta\n'
    else
        printf 'stable\n'
    fi
}

stable_base_on_master_line() {
    local tip mb tag
    tip="$(merged_branch_tip "${1:-HEAD}")"
    mb="$(git merge-base "$tip" origin/master 2>/dev/null || true)"
    if [ -z "$mb" ]; then
        stable_base_from_plist
        return 0
    fi

    while IFS= read -r tag; do
        if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if git merge-base --is-ancestor "$tag" "$mb" 2>/dev/null; then
                printf '%s\n' "${tag#v}"
                return 0
            fi
        fi
    done < <(git tag -l 'v*' --sort=-v:refname)

    stable_base_from_plist
}

stable_base_for_commit() {
    stable_base_on_master_line "$1"
}

beta_base_version() {
    local latest
    if latest="$(latest_beta_tag)"; then
        if [[ "$latest" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-beta\.[0-9]+$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    stable_base_from_plist
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

fetch_channel_refs

BUILD_TIP="$GITHUB_SHA"
CHANNEL_LINE="release"
CANARY_BASE=""

case "$BRANCH_NAME" in
    release)
        VERSION="$(resolve_release_version)"
        CHANNEL_LINE="stable"
        TAG_NAME="v${VERSION}"
        ARTIFACT_NAME="LyricsX-${TAG_NAME}.zip"
        RELEASE_NAME="${TAG_NAME}"
        PRERELEASE="false"
        ROLLING_TAG="false"
        ;;
    beta)
        VERSION="$(resolve_beta_version)"
        CHANNEL_LINE="beta"
        TAG_NAME="v${VERSION}"
        ARTIFACT_NAME="LyricsX-${TAG_NAME}.zip"
        RELEASE_NAME="${TAG_NAME}"
        PRERELEASE="true"
        ROLLING_TAG="false"
        ;;
    canary)
        CHANNEL_LINE="$(detect_version_line "$BUILD_TIP")"
        if [ "$CHANNEL_LINE" = "beta" ]; then
            CANARY_BASE="$(beta_base_version)"
        else
            CANARY_BASE="$(stable_base_for_commit "$BUILD_TIP")"
        fi
        VERSION="${CANARY_BASE}-canary-$(TZ=Asia/Shanghai date +%Y.%m.%d).${SHORT_SHA}"
        TAG_NAME="v${CANARY_BASE}-canary"
        ARTIFACT_NAME="LyricsX-v${VERSION}.zip"
        RELEASE_NAME="v${VERSION}"
        PRERELEASE="true"
        ROLLING_TAG="true"
        ;;
    *)
        die "Unsupported branch for release CI: '${BRANCH_NAME}'"
        ;;
esac

PLIST_VERSION="$VERSION"

log_info "Resolved branch=${BRANCH_NAME} channel_line=${CHANNEL_LINE} tag=${TAG_NAME} release=${RELEASE_NAME} artifact=${ARTIFACT_NAME} plist=${PLIST_VERSION} prerelease=${PRERELEASE} rolling_tag=${ROLLING_TAG}"

printf 'tag_name=%s\n' "$TAG_NAME"
printf 'version=%s\n' "$VERSION"
printf 'artifact_name=%s\n' "$ARTIFACT_NAME"
printf 'release_name=%s\n' "$RELEASE_NAME"
printf 'prerelease=%s\n' "$PRERELEASE"
printf 'target_branch=%s\n' "$BRANCH_NAME"
printf 'rolling_tag=%s\n' "$ROLLING_TAG"
printf 'channel_line=%s\n' "$CHANNEL_LINE"
printf 'plist_version=%s\n' "$PLIST_VERSION"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        printf 'tag_name=%s\n' "$TAG_NAME"
        printf 'version=%s\n' "$VERSION"
        printf 'artifact_name=%s\n' "$ARTIFACT_NAME"
        printf 'release_name=%s\n' "$RELEASE_NAME"
        printf 'prerelease=%s\n' "$PRERELEASE"
        printf 'target_branch=%s\n' "$BRANCH_NAME"
        printf 'rolling_tag=%s\n' "$ROLLING_TAG"
        printf 'channel_line=%s\n' "$CHANNEL_LINE"
        printf 'plist_version=%s\n' "$PLIST_VERSION"
    } >> "$GITHUB_OUTPUT"
fi
