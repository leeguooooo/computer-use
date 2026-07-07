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
#   1. Finds the Codex Computer Use plugin
#   2. Locates the SkyComputerUseClient binary
#   3. Verifies the binary matches a known version
#   4. Backs up the original
#   5. Applies 3 NOP patches that force the permission-branch to always succeed
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
  # Search priority: known installation paths
  for pattern in \
    "$HOME/.codex/plugins/cache/openai-bundled/computer-use/"*/"Codex Computer Use.app" \
    "/Applications/Codex.app/Contents/Resources/computer-use/"*/"Codex Computer Use.app" \
    "$HOME/Library/Application Support/Codex/plugins/"*/"Codex Computer Use.app"; do
    for candidate in $pattern; do
      if [[ -d "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
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
    err "Could not find Codex Computer Use.app.\n"
    detail "Expected locations:"
    detail "  ~/.codex/plugins/cache/openai-bundled/computer-use/*/Codex Computer Use.app"
    detail "  /Applications/Codex.app/Contents/Resources/computer-use/*/Codex Computer Use.app"
    detail ""
    detail "Make sure Codex is installed and has been used at least once."
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
  for entry in "${PATCHES[@]}"; do
    IFS=':' read -r offset expected_orig expected_new <<< "$entry"
    actual=$(xxd -s "$offset" -l 4 "$BINARY" | awk '{print $2$3$4$5}')
    if [[ "$actual" == "$expected_orig" ]]; then
      ok "Offset ${offset}: original bytes match (${expected_orig}) → needs patch"
    elif [[ "$actual" == "$expected_new" ]]; then
      ok "Offset ${offset}: already patched (${expected_new}) → skipping"
    else
      warn "Offset ${offset}: unexpected bytes ${actual} (expected ${expected_orig} or ${expected_new})"
      warn "This binary version may not be compatible with these patches."
    fi
  done

  # 3. Backup
  info ""
  info "3. Backing up original binary…"
  BACKUP_DIR="${HOME}/Desktop"
  BACKUP_FILE="${BACKUP_DIR}/SkyComputerUseClient.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$BINARY" "$BACKUP_FILE"
  ok "Backup saved: ${BACKUP_FILE}"

  # 4. Apply patches
  info ""
  info "4. Applying patches…"
  for entry in "${PATCHES[@]}"; do
    IFS=':' read -r offset expected_orig expected_new <<< "$entry"
    actual=$(xxd -s "$offset" -l 4 "$BINARY" | awk '{print $2$3$4$5}')
    if [[ "$actual" == "$expected_orig" ]]; then
      # Write the 4 NOP bytes at this offset
      printf '\x1f\x20\x03\xd5' | dd of="$BINARY" bs=1 seek=$((offset)) count=4 conv=notrunc 2>/dev/null
      # Verify
      written=$(xxd -s "$offset" -l 4 "$BINARY" | awk '{print $2$3$4$5}')
      if [[ "$written" == "$expected_new" ]]; then
        ok "Patched offset ${offset}: ${expected_new}"
      else
        err "Failed to patch offset ${offset}: wrote ${written}, expected ${expected_new}"
      fi
    elif [[ "$actual" == "$expected_new" ]]; then
      ok "Offset ${offset}: already patched, skipping"
    else
      warn "Offset ${offset}: unexpected bytes ${actual}, skipping this patch"
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

  # Verify
  detail "Verifying signatures…"
  codesign --verify --deep "${CUA_APP}" 2>/dev/null && ok "Signature verification passed"

  # 6. Post-install instructions
  info ""
  info "6. ${BOLD}Patch complete!${RESET}"
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
  info "To revert, restore the backup:"
  info "  sudo cp ${BACKUP_FILE} ${BINARY}"
  info "  codesign -s - --force --deep '${CUA_APP}'"
  info ""
  info "The original binary was also saved to:"
  info "  ${DIM}${BACKUP_FILE}${RESET}"
  info ""
}

main "$@"
