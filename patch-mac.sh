#!/usr/bin/env bash
# patch-mac.sh -- Persian/Arabic RTL support for Claude Desktop on macOS
#
# Clones Claude.app to ~/Applications/Claude-RTL.app, injects the RTL+Vazirmatn
# payload into the Electron renderer files, disables the ASAR integrity fuse, and
# re-signs with an ad-hoc signature. The original app is never modified.
#
# Usage:
#   ./patch-mac.sh          -- interactive menu
#   ./patch-mac.sh install  -- non-interactive install
#   ./patch-mac.sh restore  -- remove Claude-RTL.app
#
# Requirements: Node.js (npx on PATH), codesign (Xcode Command Line Tools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_JS="$SCRIPT_DIR/dist/rtl-payload-built.js"
ASAR_PKG='@electron/asar@4.2.0'
FUSES_PKG='@electron/fuses@2.1.1'
TARGET_APP="$HOME/Applications/Claude-RTL.app"
ASAR_PATH="$TARGET_APP/Contents/Resources/app.asar"
ASAR_BAK="$TARGET_APP/Contents/Resources/app.asar.bak"

# Files inside .vite/build/ that belong to the main process and must not be
# patched (they run in Node, not the Chromium renderer).
SKIP_FILES=(
    'index.js'
    'index.pre.js'
    'directMcpHost.js'
    'nodeHost.js'
    'shellPathWorker.js'
    'transcriptSearchWorker.js'
    'transcriptWorker.js'
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[RTL]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# ── Prerequisites ─────────────────────────────────────────────────────────────

check_prereqs() {
    command -v node  >/dev/null 2>&1 || die "Node.js not found. Install from https://nodejs.org/"
    command -v npx   >/dev/null 2>&1 || die "npx not found (comes with Node.js)."
    command -v codesign >/dev/null 2>&1 || die "codesign not found. Install Xcode Command Line Tools: xcode-select --install"
    [[ -f "$PAYLOAD_JS" ]] || die "Built payload not found at dist/rtl-payload-built.js. Run: npm run build"
}

# ── Find source Claude.app ────────────────────────────────────────────────────

find_claude() {
    local candidates=('/Applications/Claude.app' "$HOME/Applications/Claude.app")
    for c in "${candidates[@]}"; do
        [[ -d "$c" ]] && echo "$c" && return
    done
    die "Claude.app not found in /Applications or ~/Applications. Install Claude Desktop first: https://claude.ai/download"
}

# ── Install ───────────────────────────────────────────────────────────────────

do_install() {
    check_prereqs

    local src
    src="$(find_claude)"
    log "Source app: $src"
    log "Target app: $TARGET_APP"

    # Clone (or re-clone) the app bundle.
    if [[ -d "$TARGET_APP" ]]; then
        warn "Removing existing Claude-RTL.app for a clean clone..."
        rm -rf "$TARGET_APP"
    fi

    log "Cloning app bundle (this may take a moment)..."
    mkdir -p "$HOME/Applications"
    cp -R "$src" "$TARGET_APP"
    ok "Cloned to $TARGET_APP"

    # Back up the original ASAR.
    cp "$ASAR_PATH" "$ASAR_BAK"
    log "Backed up app.asar → app.asar.bak"

    # Extract ASAR.
    local tmp_src="$TARGET_APP/Contents/Resources/_app_src"
    rm -rf "$tmp_src"
    log "Extracting app.asar..."
    npx --yes "$ASAR_PKG" extract "$ASAR_PATH" "$tmp_src"

    # Find renderer files to patch.
    local vite_dir="$tmp_src/renderer/.vite/build"
    [[ -d "$vite_dir" ]] || die "Expected renderer at $vite_dir — Claude Desktop version may be unsupported."

    local patched=0
    while IFS= read -r -d '' js_file; do
        local base
        base="$(basename "$js_file")"

        # Skip main-process files.
        local skip=0
        for s in "${SKIP_FILES[@]}"; do
            [[ "$base" == "$s" ]] && skip=1 && break
        done
        [[ "$skip" -eq 1 ]] && continue

        # Skip already-patched files (idempotency).
        grep -q 'claude-rtl-font' "$js_file" 2>/dev/null && continue

        # Prepend the RTL payload.
        local tmp_file
        tmp_file="$(mktemp)"
        cat "$PAYLOAD_JS" "$js_file" > "$tmp_file"
        mv "$tmp_file" "$js_file"
        (( patched++ ))
    done < <(find "$vite_dir" -maxdepth 1 -name '*.js' -print0)

    [[ "$patched" -gt 0 ]] || die "No renderer files found to patch in $vite_dir"
    ok "Injected RTL payload into $patched renderer file(s)."

    # Repack ASAR.
    log "Repacking app.asar..."
    npx "$ASAR_PKG" pack "$tmp_src" "$ASAR_PATH"
    rm -rf "$tmp_src"
    ok "Repacked app.asar."

    # Disable Electron ASAR integrity fuse (hash no longer matches).
    log "Disabling ASAR integrity fuse..."
    npx --yes "$FUSES_PKG" write \
        --app "$TARGET_APP" \
        EnableEmbeddedAsarIntegrityValidation:disable \
    || warn "fuses write failed — app may refuse to launch. Try: codesign --remove-signature \"$TARGET_APP\""

    # Remove quarantine attribute so macOS doesn't block the modified bundle.
    xattr -cr "$TARGET_APP" 2>/dev/null || true

    # Ad-hoc code sign.
    log "Signing with ad-hoc signature..."
    codesign --force --deep --sign - "$TARGET_APP" \
    || die "codesign failed. You may need to grant Terminal full-disk access in System Settings."
    ok "Signed."

    echo ""
    ok "Done! Open Claude RTL from: $TARGET_APP"
    echo "   You can drag it to your Dock or Launchpad."
    echo "   To uninstall: $0 restore"
}

# ── Restore ───────────────────────────────────────────────────────────────────

do_restore() {
    if [[ ! -d "$TARGET_APP" ]]; then
        warn "Claude-RTL.app not found at $TARGET_APP — nothing to remove."
        return
    fi
    rm -rf "$TARGET_APP"
    ok "Removed $TARGET_APP. Original Claude.app is unchanged."
}

# ── Menu ──────────────────────────────────────────────────────────────────────

show_menu() {
    echo ""
    echo "  Claude Desktop RTL Patch — macOS"
    echo "  ─────────────────────────────────"
    echo "  1) Install  (creates ~/Applications/Claude-RTL.app)"
    echo "  2) Restore  (removes Claude-RTL.app)"
    echo "  3) Exit"
    echo ""
    read -rp "  Choose [1-3]: " choice
    case "$choice" in
        1) do_install ;;
        2) do_restore ;;
        3) exit 0 ;;
        *) warn "Invalid choice."; show_menu ;;
    esac
}

# ── Entry point ───────────────────────────────────────────────────────────────

case "${1:-menu}" in
    install) do_install ;;
    restore) do_restore ;;
    menu)    show_menu  ;;
    *)       die "Unknown command: $1. Use: install | restore | menu" ;;
esac
