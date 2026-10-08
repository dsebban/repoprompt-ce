#!/usr/bin/env bash
# Builds `rp-pi-durable` from Vendor/PiDurable/rp-pi-durable against the official pi monorepo
# (https://github.com/earendil-works/pi) at the commit pinned in pi-pin.json.
#
# Usage: Scripts/build_rp_pi_durable.sh [--pi-dir DIR] [--out DIR] [--target bun-<os>-<arch>] [--install] [--conformance]
#
#   --pi-dir DIR     pi checkout to build in (default: .build/rp-pi-durable/pi; cloned when missing)
#   --out DIR        output directory (default: .build/rp-pi-durable/<target or host>)
#   --target T       Bun compile target, e.g. bun-darwin-arm64. Cross-target downloads are unreliable;
#                    build each target natively where possible (plan §4).
#   --install        link the result as ~/.local/share/rp-pi-durable/current/bin/rp-pi-durable, a path
#                    RepoPrompt's Pi Durable locator searches
#   --conformance    run the faux-model ACP conformance script against the result
#
# Requires git, node/npm, and Bun >= 1.4 (1.3 lacks node:sqlite).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/Vendor/PiDurable/rp-pi-durable"
PIN_FILE="$PACKAGE_DIR/pi-pin.json"
PI_DIR="$ROOT_DIR/.build/rp-pi-durable/pi"
OUT_DIR=""
TARGET=""
INSTALL=0
CONFORMANCE=0

fail(){ echo "ERROR: $*" >&2; exit 1; }

while (( $# > 0 )); do
    case "$1" in
        --pi-dir) PI_DIR="${2:?--pi-dir needs a value}"; shift ;;
        --out) OUT_DIR="${2:?--out needs a value}"; shift ;;
        --target) TARGET="${2:?--target needs a value}"; shift ;;
        --install) INSTALL=1 ;;
        --conformance) CONFORMANCE=1 ;;
        --help|-h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift
done

for tool in git node npm bun; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool '$tool'"
done

pin_field(){ node -e 'const pin = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(pin[process.argv[2]]));' "$PIN_FILE" "$1"; }
PI_REPOSITORY="$(pin_field repository)"
PI_COMMIT="$(pin_field commit)"
MINIMUM_BUN="$(pin_field minimumBunVersion)"

bun_version="$(bun --version)"
node -e 'const [a, b] = process.argv.slice(1).map((v) => v.split(".").map(Number)); for (let i = 0; i < 3; i++) { if ((a[i] ?? 0) !== (b[i] ?? 0)) process.exit((a[i] ?? 0) > (b[i] ?? 0) ? 0 : 1); }' \
    "$bun_version" "$MINIMUM_BUN" || fail "Bun $bun_version is older than $MINIMUM_BUN (node:sqlite is required)"

if [[ ! -d "$PI_DIR/.git" ]]; then
    echo "==> Cloning $PI_REPOSITORY"
    mkdir -p "$(dirname "$PI_DIR")"
    git clone --filter=blob:none --no-checkout "$PI_REPOSITORY" "$PI_DIR"
fi
if [[ "$(git -C "$PI_DIR" rev-parse HEAD 2>/dev/null || true)" != "$PI_COMMIT" ]]; then
    echo "==> Checking out pi $PI_COMMIT"
    git -C "$PI_DIR" cat-file -e "$PI_COMMIT^{commit}" 2>/dev/null || git -C "$PI_DIR" fetch origin "$PI_COMMIT"
    git -C "$PI_DIR" checkout --quiet --detach "$PI_COMMIT"
fi

lock_stamp="$PI_DIR/node_modules/.rp-pi-durable-lock"
lock_hash="$(git -C "$PI_DIR" rev-parse "HEAD:package-lock.json")"
if [[ ! -f "$lock_stamp" || "$(cat "$lock_stamp")" != "$lock_hash" ]]; then
    echo "==> Installing pi dependencies (npm ci --ignore-scripts)"
    (cd "$PI_DIR" && npm ci --ignore-scripts --no-audit --no-fund)
    echo "$lock_hash" > "$lock_stamp"
fi

if ! compgen -G "$PI_DIR/packages/ai/src/providers/data/*.json" >/dev/null; then
    # pi-ai's generated model catalog is not committed; this fetches the providers' current model lists.
    echo "==> Hydrating pi-ai model data"
    (cd "$PI_DIR/packages/ai" && npm run --silent hydrate-model-data)
fi

echo "==> Staging packages/rp-pi-durable"
rm -rf "$PI_DIR/packages/rp-pi-durable"
mkdir -p "$PI_DIR/packages/rp-pi-durable"
(cd "$PACKAGE_DIR" && tar --exclude ./dist --exclude ./node_modules -cf - .) | (cd "$PI_DIR/packages/rp-pi-durable" && tar -xf -)

host_target="bun-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed -e 's/x86_64/x64/' -e 's/aarch64/arm64/')"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/.build/rp-pi-durable/${TARGET:-$host_target}}"
mkdir -p "$OUT_DIR"
echo "==> Compiling rp-pi-durable (${TARGET:-$host_target})"
(
    cd "$PI_DIR/packages/rp-pi-durable"
    bun build --compile --minify --conditions=source ${TARGET:+--target="$TARGET"} src/main.ts --outfile "$OUT_DIR/rp-pi-durable"
)
binary="$OUT_DIR/rp-pi-durable"

if [[ -z "$TARGET" || "$TARGET" == "$host_target" ]]; then
    echo "==> Smoke: $("$binary" --version --json)"
    if (( CONFORMANCE )); then
        node "$PACKAGE_DIR/test/conformance.mjs" "$binary"
    fi
fi

if (( INSTALL )); then
    version="$("$binary" --version)"
    install_root="$HOME/.local/share/rp-pi-durable"
    mkdir -p "$install_root/$version/bin"
    cp "$binary" "$install_root/$version/bin/rp-pi-durable.part"
    mv -f "$install_root/$version/bin/rp-pi-durable.part" "$install_root/$version/bin/rp-pi-durable"
    ln -sfn "$version" "$install_root/current"
    echo "==> Installed $install_root/current/bin/rp-pi-durable -> $version"
fi

echo "$binary"
