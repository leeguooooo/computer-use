#!/usr/bin/env bash
set -euo pipefail

# opencua — patch installer
# Patches the SkyComputerUseClient binary inside Codex Computer Use to
# bypass the internal permission check, then ad-hoc re-signs the bundles.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
#
# The script:
#   1. Finds the Codex Computer Use plugin (all 3 known locations)
#   2. Locates the SkyComputerUseClient binary
#   3. Verifies the binary's permission-check bytes
#   4. Backs up the original binary to ~/Desktop
#   5. Applies 3 NOP patches that force the permission-branch to succeed
#   6. Ad-hoc re-signs the inner and outer app bundles
#   7. Prints post-install instructions for granting macOS permissions

BOLD=$(printf '\033[1m')
DIM=$(printf '\033[2m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
RED=$(printf '\033[31m')
RESET=$(printf '\033[0m')

info()  { printf "${BOLD}%s${RESET}\n" "$*"; }
ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
err()   { printf "  ${RED}✗${RESET} %s\n" "$*"; exit 1; }
detail(){ printf "  ${DIM}%s${RESET}\n" "$*"; }

# ── locate Codex Computer Use ──────────────────────────────────────────

find_cua_app() {
  for candidate in \
    "$HOME/.codex/computer-use/Codex Computer Use.app" \
    "$HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/Codex Computer Use.app" \
    "$HOME/.codex/plugins/cache/openai-bundled/computer-use/"*/"Codex Computer Use.app" \
    "/Applications/Codex.app/Contents/Resources/computer-use/"*/"Codex Computer Use.app"; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# ── patch offsets ──────────────────────────────────────────────────────
# These 3 file offsets correspond to the permission-switch branch instructions
# in the function at vmaddr 0x100019a00. Each is an ARM64 conditional branch
# instruction (B.LE, B.EQ, B.NE) that is replaced with NOP (1f 20 03 d5).

PATCHES=(
  "0x19a18:cd010054:1f2003d5"  # B.LE  → NOP
  "0x19a20:20040054:1f2003d5"  # B.EQ  → NOP
  "0x19a28:61040054:1f2003d5"  # B.NE  → NOP
)

# Read 4 bytes at an offset as a hex string (lowercase, no spaces, no ASCII).
read_hex() {
  od -A n -t x1 -j "$1" -N 4 "$2" 2>/dev/null | tr -d ' \n'
}

# ── main ───────────────────────────────────────────────────────────────

main() {
  info ""
  info "opencua — Codex Computer Use patch installer"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info ""

  # 1. Find the app
  info "1. Locating Codex Computer Use…"
  CUA_APP="$(find_cua_app)" || true
  if [[ -z "$CUA_APP" ]]; then
    cat >&2 <<EOF
  ✗ Could not find Codex Computer Use.app.

  Expected locations (checked in order):
    ~/.codex/computer-use/Codex Computer Use.app
    ~/.codex/.tmp/bundled-marketplaces/…/Codex Computer Use.app
    ~/.codex/plugins/cache/openai-bundled/computer-use/*/Codex Computer Use.app
    /Applications/Codex.app/Contents/Resources/…/Codex Computer Use.app

  Make sure Codex is installed and has been used at least once.
EOF
    exit 1
  fi
  ok "Found: ${CUA_APP}"

  INNER_APP="${CUA_APP}/Contents/SharedSupport/SkyComputerUseClient.app"
  BINARY="${INNER_APP}/Contents/MacOS/SkyComputerUseClient"

  if [[ ! -f "$BINARY" ]]; then
    err "Binary not found at: ${BINARY}"
  fi
  ok "Binary: ${BINARY}"

  BINARY_SIZE=$(stat -f%z "$BINARY")
  detail "Size: ${BINARY_SIZE} bytes"

  # 2. Verify original bytes
  info ""
  info "2. Verifying binary version…"
  all_match=true
  any_patched=false
  for entry in "${PATCHES[@]}"; do
    IFS=':' read -r offset expected_orig expected_new <<< "$entry"
    actual=$(read_hex "$offset" "$BINARY")
    if [[ "$actual" == "$expected_orig" ]]; then
      ok "Offset ${offset}: original bytes match → needs patch"
    elif [[ "$actual" == "$expected_new" ]]; then
      ok "Offset ${offset}: already patched → skipping"
      any_patched=true
    else
      warn "Offset ${offset}: unexpected bytes ${actual} (expected ${expected_orig} or ${expected_new})"
      all_match=false
    fi
  done

  if [[ "$all_match" == "false" ]]; then
    warn ""
    warn "One or more offsets don't match a known binary version."
    warn "Proceeding may corrupt the binary. Aborting for safety."
    exit 1
  fi

  if [[ "$any_patched" == "true" ]]; then
    info ""
    info "${GREEN}All patches already applied — nothing to do.${RESET}"
    info "If Computer Use still doesn't work, check the macOS permissions below."
    # still print the instructions
  else
    # 3. Backup
    info ""
    info "3. Backing up original binary…"
    BACKUP_DIR="${HOME}/Desktop"
    BACKUP_FILE="${BACKUP_DIR}/SkyComputerUseClient.bak.$(date +%Y%m%d-%H%M%S).${BINARY_SIZE}"
    cp "$BINARY" "$BACKUP_FILE"
    ok "Backup saved: ${BACKUP_FILE}"

    # 4. Apply patches
    info ""
    info "4. Applying patches…"
    for entry in "${PATCHES[@]}"; do
      IFS=':' read -r offset expected_orig expected_new <<< "$entry"
      actual=$(read_hex "$offset" "$BINARY")
      if [[ "$actual" == "$expected_orig" ]]; then
        printf '\x1f\x20\x03\xd5' | dd of="$BINARY" bs=1 seek=$((offset)) count=4 conv=notrunc 2>/dev/null
        written=$(read_hex "$offset" "$BINARY")
        if [[ "$written" == "$expected_new" ]]; then
          ok "Patched offset ${offset}: ${expected_new}"
        else
          err "Failed to patch offset ${offset}: wrote ${written}, expected ${expected_new}"
        fi
      fi
    done

    # 5. Re-sign
    info ""
    info "5. Re-signing bundles…"

    detail "Signing inner app (SkyComputerUseClient.app)…"
    codesign -s - --force --preserve-metadata=entitlements "${INNER_APP}" 2>/dev/null
    ok "Inner app signed"

    detail "Signing outer app (Codex Computer Use.app) with --deep…"
    codesign -s - --force --deep "${CUA_APP}" 2>/dev/null
    ok "Outer app signed"

    detail "Verifying signatures…"
    if codesign --verify --deep "${CUA_APP}" 2>/dev/null; then
      ok "Signature verification passed"
    else
      warn "Signature verification failed (non-fatal — app should still work)"
    fi

    info ""
    info "${GREEN}Patches applied successfully!${RESET}"
  fi

  # 6. Post-install instructions
  info ""
  info "${YELLOW}── Permission setup ──────────────────────${RESET}"
  info ""
  info "For Computer Use to actually function, you need to grant two permissions"
  info "to the SkyComputerUseClient app in System Settings:"
  info ""
  info "  1. ${BOLD}Accessibility${RESET}"
  info "     System Settings → Privacy & Security → Accessibility"
  info "     → Click '+' → navigate to:"
  info "       ${DIM}Codex Computer Use.app${RESET}"
  info "       ${DIM}  ↓ Contents/SharedSupport/${RESET}"
  info "       ${DIM}SkyComputerUseClient.app${RESET}"
  info "     → Select 'SkyComputerUseClient.app' → Open"
  info ""
  info "  2. ${BOLD}Screen Recording${RESET}"
  info "     System Settings → Privacy & Security → Screen Recording"
  info "     → Add the same ${DIM}SkyComputerUseClient.app${RESET}"
  info ""
  info "After adding both, restart Codex and try Computer Use."
  info ""
  info "${YELLOW}── Reverting ──────────────────────────────${RESET}"
  info ""
  if [[ -n "${BACKUP_FILE:-}" && -f "${BACKUP_FILE:-}" ]]; then
    info "To revert, restore the backup:"
    info "  sudo cp ${BACKUP_FILE} ${BINARY}"
    info "  codesign -s - --force --deep '${CUA_APP}'"
    info ""
    info "The original binary was saved to:"
    info "  ${DIM}${BACKUP_FILE}${RESET}"
  fi
  info ""
}

main "$@"
