#!/usr/bin/env bash
# Shared helpers for Scripts/ci/*.sh

log_info() {
    printf '\033[0;34m[INFO]\033[0m %s\n' "$*" >&2
}

log_error() {
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

require_env() {
    local name
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            die "Required environment variable is empty or unset: ${name}"
        fi
    done
}

plist_buddy() {
    /usr/libexec/PlistBuddy "$@"
}

repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# The numeric version every target shows. Info.plist only carries the
# $(MARKETING_VERSION) variable, so the value lives in the xcconfig.
marketing_version() {
    sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' "$(repo_root)/Config/Version.xcconfig"
}
