#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  printf '%s\n' 'This entrypoint builds the Linux headless product on a Linux host.' >&2
  exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-release}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ "$configuration" != debug && "$configuration" != release ]]; then
  printf '%s\n' 'Usage: Scripts/build_linux.sh [debug|release] [conductor swift-build options]' >&2
  exit 2
fi
for tool in swift python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required tool missing: %s. See docs/linux.md.\n' "$tool" >&2
    exit 1
  fi
done

cd -- "$repo_root"
export REPOPROMPT_DEV_BUILD_CACHE_DISABLE=1
static_swift="${REPOPROMPT_LINUX_STATIC_SWIFT:-1}"
if [[ "$static_swift" != 0 && "$static_swift" != 1 ]]; then
  printf '%s\n' 'REPOPROMPT_LINUX_STATIC_SWIFT must be 0 or 1.' >&2
  exit 2
fi
build_options=(--product repoprompt-mcp --configuration "$configuration" --jobs "${SWIFT_JOBS:-4}")
if [[ "$configuration" == release && "$static_swift" == 1 ]]; then
  build_options+=(--static-swift-stdlib)
fi

# SwiftPM resolves one lockfile per checkout, and a Linux resolution drops the
# pins of dependencies only macOS declares. Restore the committed file so a
# Linux build leaves the worktree clean and the notice guardrails keep matching.
resolved="$repo_root/Package.resolved"
resolved_snapshot=""
restore_resolved() {
  if [[ -n "$resolved_snapshot" && -f "$resolved_snapshot" ]]; then
    if ! cmp -s "$resolved_snapshot" "$resolved"; then
      cp -p "$resolved_snapshot" "$resolved"
      printf '%s\n' 'Restored Package.resolved after the Linux dependency resolution.' >&2
    fi
    rm -f "$resolved_snapshot"
  fi
}
trap restore_resolved EXIT
if [[ -f "$resolved" ]]; then
  resolved_snapshot="$(mktemp "${TMPDIR:-/tmp}/repoprompt-package-resolved.XXXXXX")"
  cp -p "$resolved" "$resolved_snapshot"
fi

./conductor swift-build "${build_options[@]}" "$@"
