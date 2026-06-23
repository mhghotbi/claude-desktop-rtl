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

# Top-level .vite/build/*.js files that run in Node (no DOM) and must not receive
# the renderer RTL payload. The Electron main entry (package.json "main", usually
# index.pre.js) is resolved separately — see soguy/claude-desktop-rtl-mac patch.sh.
SKIP_FILES=(
    'index.js'
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

    # Renderer/preload bundles live under .vite/build/ inside app.asar (not
    # renderer/.vite/build — that path does not exist). Matches soguy's patch.sh.
    local vite_dir="$tmp_src/.vite/build"
    [[ -d "$vite_dir" ]] || die ".vite/build/ not found in extracted ASAR at $vite_dir — Claude Desktop version may be unsupported."

    local main_basename=''
    if [[ -f "$tmp_src/package.json" ]]; then
        main_basename="$(node -p "require('$tmp_src/package.json').main || ''" 2>/dev/null || true)"
        main_basename="$(basename "$main_basename")"
    fi

    local patched=0 skipped=0
    while IFS= read -r -d '' js_file; do
        local base
        base="$(basename "$js_file")"

        # Skip Electron main-process entry — RTL payload there prevents windows from opening.
        if [[ -n "$main_basename" && "$base" == "$main_basename" ]]; then
            log "Skipping $base (Electron main process)"
            (( skipped++ )) || true
            continue
        fi

        # Skip other Node-only bundles (workers, large main bundle).
        local skip=0
        for s in "${SKIP_FILES[@]}"; do
            [[ "$base" == "$s" ]] && skip=1 && break
        done
        if [[ "$skip" -eq 1 ]]; then
            log "Skipping $base (Node / no DOM)"
            (( skipped++ )) || true
            continue
        fi

        # Skip already-patched files (idempotency).
        if grep -q 'claude-rtl-font' "$js_file" 2>/dev/null; then
            (( skipped++ )) || true
            continue
        fi

        # Prepend the RTL payload.
        local tmp_file
        tmp_file="$(mktemp)"
        cat "$PAYLOAD_JS" "$js_file" > "$tmp_file"
        mv "$tmp_file" "$js_file"
        (( patched++ ))
    done < <(find "$vite_dir" -maxdepth 1 -name '*.js' -print0)

    if [[ "$patched" -eq 0 && "$skipped" -eq 0 ]]; then
        die "No .js files found in $vite_dir — Claude Desktop structure may have changed."
    fi
    [[ "$patched" -gt 0 ]] || die "No renderer files found to patch in $vite_dir (all skipped or already patched)."
    ok "Injected RTL payload into $patched renderer file(s)."
    [[ "$skipped" -gt 0 ]] && log "Skipped $skipped file(s)."

    # Repack ASAR.
    log "Repacking app.asar..."
    npx "$ASAR_PKG" pack "$tmp_src" "$ASAR_PATH"
    rm -rf "$tmp_src"
    ok "Repacked app.asar."

    # Disable Electron ASAR integrity fuse (hash no longer matches).
    log "Disabling ASAR integrity fuse (EnableEmbeddedAsarIntegrityValidation=off)..."
    local fuse_out fuse_rc=0
    fuse_out="$(npx --yes "$FUSES_PKG" write \
        --app "$TARGET_APP" \
        EnableEmbeddedAsarIntegrityValidation=off 2>&1)" || fuse_rc=$?
    if [[ "$fuse_rc" -ne 0 ]]; then
        warn "fuses write failed — app may refuse to launch."
        while IFS= read -r line; do [[ -n "$line" ]] && log "    $line"; done <<< "$fuse_out"
        warn "Try: codesign --remove-signature \"$TARGET_APP\" then re-run install."
    else
        local fuse_probe
        fuse_probe="$(npx --yes "$FUSES_PKG" read --app "$TARGET_APP" 2>/dev/null || true)"
        if grep -q 'EnableEmbeddedAsarIntegrityValidation.*Disabled' <<< "$fuse_probe"; then
            ok "ASAR integrity fuse disabled."
        else
            warn "Fuse write succeeded but re-probe still shows enabled — app may refuse to launch."
        fi
    fi

    # Remove quarantine attribute so macOS doesn't block the modified bundle.
    xattr -cr "$TARGET_APP" 2>/dev/null || true

    # Ad-hoc code sign.
    log "Signing with ad-hoc signature..."
    codesign --force --deep --sign - "$TARGET_APP" \
    || die "codesign failed. You may need to grant Terminal full-disk access in System Settings."
    ok "Signed."

    echo ""
    ok "Done! Claude RTL is at: $TARGET_APP"
    echo "   (User Applications — not /Applications. Launchpad may not list it until you open it once.)"
    echo ""
    echo "   Open now:  open \"$TARGET_APP\""
    echo "   Or Finder: Go → Home → Applications → Claude-RTL"
    echo "   Drag Claude-RTL.app to the Dock to keep it handy."
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
