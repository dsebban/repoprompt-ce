#!/usr/bin/env bash
# Build a QA DMG signed with the user's local self-signed identity.
#
# Usage: Scripts/qa_build.sh <label> [source-dir]
#
# The packaged app keeps the production bundle id and the "local-self-signed"
# signing mode, so on the machine whose local signing registry matches
# QA_SIGNING_CERT_SHA256 / QA_SIGNING_SERVICE_GENERATION it opens the same
# persistent Keychain storage as Scripts/install_local_production.sh builds.
# source-dir defaults to this checkout and may be any RepoPrompt CE checkout
# (for example a PR head that does not contain this script).
#
# Required environment:
#   QA_SIGNING_CERT_SHA1           SHA-1 of the self-signed code-signing certificate
#   QA_SIGNING_CERT_SHA256         SHA-256 of the same certificate
#   QA_SIGNING_SERVICE_GENERATION  secure-storage generation from the local registry
# Optional:
#   QA_SIGNING_P12_BASE64 / QA_SIGNING_P12_PASSWORD
#                                  import the identity into a temporary keychain (CI);
#                                  when unset the identity must already be in the
#                                  keychain search list (local builds)
#   QA_OUTPUT_DIR                  DMG destination (default: <source-dir>/.build/qa)
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require() { [[ -n "${!1:-}" ]] || fail "$1 is required"; }

(( $# >= 1 && $# <= 2 )) || fail "usage: $0 <label> [source-dir]"
QA_LABEL="$1"
SOURCE_DIR="$(cd "${2:-$(dirname "$0")/..}" && pwd)"
[[ "$QA_LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || fail "label must match [A-Za-z0-9._-]+"
[[ -x "$SOURCE_DIR/Scripts/package_app.sh" ]] || fail "not a RepoPrompt CE checkout: $SOURCE_DIR"
require QA_SIGNING_CERT_SHA1
require QA_SIGNING_CERT_SHA256
require QA_SIGNING_SERVICE_GENERATION

QA_OUTPUT_DIR="${QA_OUTPUT_DIR:-$SOURCE_DIR/.build/qa}"
DISPLAY_NAME="RepoPrompt CE QA"

TEMP_KEYCHAIN=""
ORIGINAL_KEYCHAINS=()
cleanup() {
    [[ -n "$TEMP_KEYCHAIN" ]] || return 0
    if (( ${#ORIGINAL_KEYCHAINS[@]} )); then
        security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || true
    fi
    security delete-keychain "$TEMP_KEYCHAIN" || true
}
trap cleanup EXIT

if [[ -n "${QA_SIGNING_P12_BASE64:-}" ]]; then
    require QA_SIGNING_P12_PASSWORD
    umask 077
    TEMP_KEYCHAIN="${RUNNER_TEMP:-$(mktemp -d)}/repoprompt-qa-signing.keychain-db"
    keychain_password="$(openssl rand -base64 24)"
    p12_path="$(mktemp)"
    printf '%s' "$QA_SIGNING_P12_BASE64" | base64 --decode > "$p12_path"
    security create-keychain -p "$keychain_password" "$TEMP_KEYCHAIN"
    security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN"
    security unlock-keychain -p "$keychain_password" "$TEMP_KEYCHAIN"
    security import "$p12_path" -k "$TEMP_KEYCHAIN" -f pkcs12 -P "$QA_SIGNING_P12_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    rm -f "$p12_path"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$TEMP_KEYCHAIN" >/dev/null
    while IFS= read -r keychain; do
        ORIGINAL_KEYCHAINS+=("$keychain")
    done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
    security list-keychains -d user -s "$TEMP_KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
fi

# A self-signed leaf is untrusted on a fresh runner, so `find-identity -v`
# would hide it; codesign only needs the private key.
security find-identity -p codesigning | grep -qi -- "$QA_SIGNING_CERT_SHA1" ||
    fail "signing identity $QA_SIGNING_CERT_SHA1 is not in the keychain search list"

COMMIT="$(git -C "$SOURCE_DIR" rev-parse --short=9 HEAD)"
# package_app.sh accepts N{1,4}(.N{1,2}){0,2}: day-of-year.hour.minute (UTC).
BUILD_NUMBER="${QA_BUILD_NUMBER:-$((10#$(date -u +%j))).$((10#$(date -u +%H))).$((10#$(date -u +%M)))}"

REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER" \
    LOCAL_SELF_SIGNED_RELEASE=1 \
    LOCAL_SIGNING_CERTIFICATE_SHA1="$QA_SIGNING_CERT_SHA1" \
    LOCAL_SIGNING_CERTIFICATE_SHA256="$QA_SIGNING_CERT_SHA256" \
    LOCAL_SIGNING_SERVICE_GENERATION="$QA_SIGNING_SERVICE_GENERATION" \
    SIGN_IDENTITY="$QA_SIGNING_CERT_SHA1" \
    "$SOURCE_DIR/Scripts/package_app.sh" release

APP_BUNDLE="$SOURCE_DIR/.build/release/RepoPrompt.app"
[[ -d "$APP_BUNDLE" ]] || fail "missing packaged app: $APP_BUNDLE"
[[ "$(plutil -extract RepoPromptSigningMode raw "$APP_BUNDLE/Contents/Info.plist")" == "local-self-signed" ]] ||
    fail "packaged app is missing the local self-signed signing-mode marker"

mkdir -p "$QA_OUTPUT_DIR"
STAGE_DIR="$(mktemp -d)"
ditto "$APP_BUNDLE" "$STAGE_DIR/$DISPLAY_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"
DMG="$QA_OUTPUT_DIR/RepoPrompt-CE-QA-$QA_LABEL-$COMMIT.dmg"
rm -f "$DMG"
hdiutil create -volname "$DISPLAY_NAME $QA_LABEL" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE_DIR"

printf 'QA DMG: %s\n' "$DMG"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "dmg=$DMG"
        echo "name=$(basename "$DMG" .dmg)"
    } >> "$GITHUB_OUTPUT"
fi
