#!/usr/bin/env bash
set -euo pipefail

# Codex Computer Use — permission bypass installer
#
# Patches the SkyComputerUseClient binary to skip its internal permission
# check, then triggers the macOS permission dialogs so the user only needs
# to click "Allow".
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
#
# What it does:
#   1. Finds Codex Computer Use.app
#   2. Patches 3 branch instructions → NOP inside SkyComputerUseClient
#   3. Ad-hoc re-signs the bundles
#   4. Launches the binary once to trigger macOS Accessibility + Screen
#      Recording permission dialogs → user just clicks Allow
#   5. Restarts Codex

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
# Permission-check function at vmaddr 0x100019a00. Three conditional
# branches that gate on the permission byte at struct offset 0x20.
# We replace each with NOP (1f 20 03 d5).

PATCHES=(
  "0x19a18:cd010054:1f2003d5"  # B.LE  → NOP
  "0x19a20:20040054:1f2003d5"  # B.EQ  → NOP
  "0x19a28:61040054:1f2003d5"  # B.NE  → NOP
)

read_hex() {
  od -A n -t x1 -j "$1" -N 4 "$2" 2>/dev/null | tr -d ' \n'
}

# ── macOS permission dialogs ───────────────────────────────────────────

# Launch SkyComputerUseClient briefly so macOS TCC shows the permission
# dialogs for Accessibility and Screen Recording. The user just clicks
# "Allow" on the system pop-ups.
trigger_permission_dialogs() {
  local binary="$1"

  # Check whether permissions are already granted by doing a quick probe
  local tccdb_db="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
  if [[ -f "$tccdb_db" ]]; then
    local bundle_id
    bundle_id=$(osascript -e "id of app \"SkyComputerUseClient\"" 2>/dev/null || true)
    if [[ -z "$bundle_id" ]]; then
      # Fallback: try to read from the app's Info.plist
      bundle_id=$(plutil -p "${INNER_APP}/Contents/Info.plist" 2>/dev/null | grep CFBundleIdentifier | awk -F'"' '{print $4}' || true)
    fi
    if [[ -n "$bundle_id" ]]; then
      local ax_granted
      ax_granted=$(sqlite3 "$tccdb_db" "SELECT count(*) FROM access WHERE client='${bundle_id}' AND service='kTCCServiceAccessibility' AND allowed=1" 2>/dev/null || true)
      local sr_granted
      sr_granted=$(sqlite3 "$tccdb_db" "SELECT count(*) FROM access WHERE client='${bundle_id}' AND service='kTCCServiceScreenCapture' AND allowed=1" 2>/dev/null || true)
      if [[ "${ax_granted:-0}" -gt 0 && "${sr_granted:-0}" -gt 0 ]]; then
        return 0  # already granted
      fi
    fi
  fi

  # Launch the binary in MCP mode; it will try to use AX/Screen Recording
  # APIs, which triggers the TCC dialogs.
  info ""
  info "5. Triggering macOS permission dialogs…"
  detail "A Terminal window will open briefly — this is normal."
  detail ""

  # Run in a new Terminal window so the user sees what's happening
  osascript <<EOF
tell application "Terminal"
  activate
  do script "${binary} mcp; exit"
  delay 3
  tell application "Terminal" to close first window
end tell
EOF

  info ""
  ok "${GREEN}Check for macOS permission pop-ups!${RESET}"
  info ""
  info "${BOLD}If you saw dialogs asking for permission:${RESET}"
  info "  Click ${BOLD}Allow${RESET} or ${BOLD}OK${RESET} on each one."
  info ""
  info "${BOLD}If nothing popped up:${RESET}"
  info "  Open System Settings manually (the window should already be open),"
  info "  go to Privacy & Security, and check if there are requests waiting."
}

# ── register the MCP server with agent clients ─────────────────────────

# The patched binary is itself a standalone MCP server (`… mcp` speaks
# MCP over stdio). Patching alone doesn't help non-Codex agents — they
# also need the server registered. Codex gets it from its plugin bundle;
# Claude Code and friends need an explicit entry.
#
# NOTE: "computer-use" is a RESERVED MCP server name in Claude Code and
# will not load, so we register under "mac-computer-use".
MCP_SERVER_NAME="mac-computer-use"
HOOK_DIR="${HOME}/.codex/computer-use"
HOOK_DYLIB="${HOOK_DIR}/team_hook.dylib"

# The client has a SECOND gate beyond the (cosmetic) NOP patch: it
# authenticates the caller by resolving the responsible process and calling
# SecCodeCopySigningInformation, then checking kSecCodeInfoTeamIdentifier
# against OpenAI's Apple team "2DC432GLL2". A non-Codex caller (Claude Code)
# fails with -10000 "Sender process is not authenticated".
#
# We bypass it WITHOUT patching by injecting a tiny DYLD interpose that
# rewrites the team id the gate sees. Build it here so the install is
# self-contained.
build_team_hook() {
  command -v clang >/dev/null 2>&1 || { warn "clang not found — skipping sender-auth hook (Xcode CLT needed)."; return 1; }
  mkdir -p "$HOOK_DIR"
  local src; src="$(mktemp -t team_hook).c"
  cat > "$src" <<'HOOKC'
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#define APPROVED_TEAM CFSTR("2DC432GLL2")
static OSStatus my_SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information) {
    OSStatus st = SecCodeCopySigningInformation(code, flags, information);
    if (st == errSecSuccess && information && *information) {
        CFStringRef cur = (CFStringRef)CFDictionaryGetValue(*information, kSecCodeInfoTeamIdentifier);
        if (cur == NULL || CFStringCompare(cur, APPROVED_TEAM, 0) != kCFCompareEqualTo) {
            fprintf(stderr, "[hook5] Injecting TeamIdentifier = 2DC432GLL2\n");
            CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, *information);
            CFDictionarySetValue(m, kSecCodeInfoTeamIdentifier, APPROVED_TEAM);
            CFRelease(*information);
            *information = m;
        }
    }
    return st;
}
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
_interpose_SecCodeCopySigningInformation __attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)&my_SecCodeCopySigningInformation,
    (const void *)(uintptr_t)&SecCodeCopySigningInformation
};
__attribute__((constructor)) static void team_hook_loaded(void) { fprintf(stderr, "[hook5] loaded\n"); }
HOOKC
  if clang -arch arm64 -dynamiclib -framework CoreFoundation -framework Security -o "$HOOK_DYLIB" "$src" 2>/dev/null; then
    codesign -s - -f "$HOOK_DYLIB" >/dev/null 2>&1
    rm -f "$src"
    ok "Built sender-auth hook: ${HOOK_DYLIB}"
    return 0
  fi
  rm -f "$src"
  warn "Failed to build sender-auth hook — non-Codex tool calls will hit -10000."
  return 1
}

register_mcp_server() {
  local binary="$1"

  info ""
  info "4. Registering Computer Use as an MCP server…"

  # Build the injection hook; if it succeeds we register with it so tool
  # calls actually pass the sender-authentication gate.
  local dyld_env=()
  if build_team_hook; then
    dyld_env=(-e "DYLD_INSERT_LIBRARIES=${HOOK_DYLIB}")
  fi

  local registered=false

  # Claude Code (and Claude-compatible CLIs that ship `claude`)
  if command -v claude >/dev/null 2>&1; then
    # Idempotent: drop any prior entry, then add fresh at user scope so
    # the tools are available across all projects.
    claude mcp remove "$MCP_SERVER_NAME" --scope user >/dev/null 2>&1 || true
    if claude mcp add "$MCP_SERVER_NAME" --scope user "${dyld_env[@]}" -- "$binary" mcp >/dev/null 2>&1; then
      ok "Registered with Claude Code (user scope) as '${MCP_SERVER_NAME}'"
      detail "Restart Claude Code for the new tools to appear."
      registered=true
    else
      warn "Found the 'claude' CLI but registration failed — add it manually (snippet below)."
    fi
  fi

  if [[ "$registered" == "false" ]]; then
    detail "No 'claude' CLI on PATH — configure your agent manually (snippet below)."
  fi

  # Always print a manual snippet for other MCP clients (Cursor, Cline,
  # Windsurf, etc.) — they each keep their own config file.
  info ""
  detail "For other MCP clients, add this stdio server to their config:"
  cat <<EOF
  "${MCP_SERVER_NAME}": {
    "command": "${binary}",
    "args": ["mcp"],
    "env": { "DYLD_INSERT_LIBRARIES": "${HOOK_DYLIB}" }
  }
EOF
  detail "(Don't name it \"computer-use\" — that name is reserved in Claude Code.)"
  detail "The DYLD_INSERT_LIBRARIES hook is what lets a non-Codex caller pass the"
  detail "sender-authentication gate; without it every tool call returns -10000."
}

# ── main ───────────────────────────────────────────────────────────────

main() {
  info ""
  info "Codex Computer Use — permission bypass installer"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
  detail "Size: $(stat -f%z "$BINARY") bytes"

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

  # 3. Patch (if needed)
  if [[ "$any_patched" == "false" ]]; then
    # 3a. Backup
    info ""
    info "3a. Backing up original binary…"
    BACKUP_DIR="${HOME}/Desktop"
    BACKUP_FILE="${BACKUP_DIR}/SkyComputerUseClient.bak.$(date +%Y%m%d-%H%M%S).$(stat -f%z "$BINARY")"
    cp "$BINARY" "$BACKUP_FILE"
    ok "Backup saved: ${BACKUP_FILE}"

    # 3b. Apply patches
    info ""
    info "3b. Applying patches…"
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

    # 3c. Re-sign
    info ""
    info "3c. Re-signing bundles…"
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
      warn "Signature verification warning (non-fatal)"
    fi
    info ""
    ok "${GREEN}Patches applied successfully!${RESET}"
  else
    info ""
    ok "${GREEN}All patches already applied.${RESET}"
  fi

  # 4. Register the MCP server with agent clients
  register_mcp_server "$BINARY"

  # 5. Trigger macOS permission dialogs
  trigger_permission_dialogs "$BINARY"

  # 6. Open System Settings as backup
  info ""
  info "6. Opening System Settings for manual setup (if needed)…"
  detail "If the permission pop-ups didn't appear, use the pane that just opened."
  # Try every known macOS URL scheme for the privacy panes
  for url in \
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Accessibility" \
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" \
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_ScreenCapture"; do
    open "$url" 2>/dev/null && break
  done 2>/dev/null || true

  # 7. Restart Codex
  info ""
  info "7. Restarting Codex…"
  detail "This picks up the patched binary and newly granted permissions."
  if pkill -9 "Codex" 2>/dev/null; then
    ok "Codex terminated — relaunch it manually from Applications."
  else
    detail "Codex wasn't running, or was already terminated."
    detail "Launch it from Applications when ready."
  fi

  # 8. Summary
  info ""
  info "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  info "${GREEN}  All done!${RESET}"
  info "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  info ""
  info "${BOLD}What just happened:${RESET}"
  info "  1. SkyComputerUseClient was patched (cosmetic self-check NOPs)"
  info "  2. Built team_hook.dylib (bypasses the sender-authentication gate)"
  info "  3. Registered as MCP server '${MCP_SERVER_NAME}' with the hook injected"
  info "  4. Permissions were requested from macOS"
  info "  5. System Settings opened as backup"
  info "  6. Codex was restarted"
  info ""
  info "${BOLD}Using it outside Codex (e.g. Claude Code):${RESET}"
  info "  Restart the agent, then the '${MCP_SERVER_NAME}' tools appear."
  info ""
  info "${BOLD}If you saw macOS pop-ups asking for permission:${RESET}"
  info "  ✓ Click ${BOLD}Allow${RESET} / ${BOLD}OK${RESET} on each one"
  info "  ✓ Then relaunch Codex and try Computer Use"
  info ""
  info "${BOLD}If NOTHING appeared:${RESET}"
  info "  Open System Settings → Privacy & Security"
  info "  Under Accessibility and Screen Recording, look for"
  info "  ${DIM}SkyComputerUseClient.app${RESET} in the list and check the box."
  info ""
  info "${BOLD}To revert:${RESET}"
  if [[ -n "${BACKUP_FILE:-}" && -f "${BACKUP_FILE:-}" ]]; then
    info "  sudo cp ${BACKUP_FILE} ${BINARY}"
    info "  codesign -s - --force --deep '${CUA_APP}'"
  fi
  info ""
}

main "$@"
