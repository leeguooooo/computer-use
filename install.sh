#!/bin/sh
set -eu

REPOSITORY="${COMPUTER_USE_REPOSITORY:-leeguooooo/computer-use}"
# Default to the latest on main; pin a release with COMPUTER_USE_REF=v2.0.0
REF="${COMPUTER_USE_REF:-main}"
RAW_BASE="${COMPUTER_USE_RAW_BASE:-https://raw.githubusercontent.com/${REPOSITORY}/${REF}}"
INSTALL_DIR="${COMPUTER_USE_INSTALL_DIR:-${HOME}/.local/share/codex-computer-use}"
BIN_DIR="${COMPUTER_USE_BIN_DIR:-${HOME}/.local/bin}"
TARGET="${BIN_DIR}/codex-computer-use-mcp"

info() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

uninstall() {
  if [ -x "$TARGET" ]; then
    "$TARGET" unconfigure --command "$TARGET"
    rm -f "$TARGET"
  else
    info "codex-computer-use-mcp is not installed at ${TARGET}"
  fi
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  info "Uninstalled codex-computer-use-mcp."
}

case "${1-}" in
  --uninstall)
    uninstall
    exit 0
    ;;
  "")
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v codex >/dev/null 2>&1 || fail "codex CLI is required"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
temporary="$(mktemp "${INSTALL_DIR}/.codex-computer-use-mcp.XXXXXX")"
trap 'rm -f "$temporary"' EXIT HUP INT TERM

if [ -n "${COMPUTER_USE_MCP_SOURCE:-}" ]; then
  [ -f "$COMPUTER_USE_MCP_SOURCE" ] \
    || fail "COMPUTER_USE_MCP_SOURCE does not exist: ${COMPUTER_USE_MCP_SOURCE}"
  cp "$COMPUTER_USE_MCP_SOURCE" "$temporary"
else
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  curl -fsSL "${RAW_BASE}/bin/codex-computer-use-mcp" -o "$temporary"
fi

chmod 755 "$temporary"
# Smoke-test that the broker itself runs. Do NOT gate on the OpenAI Computer Use
# plugin being present here: it is only needed at runtime, and requiring it now
# would block installing this tool before (or independently of) that plugin.
"$temporary" --help >/dev/null
mv "$temporary" "$TARGET"
trap - EXIT HUP INT TERM

"$TARGET" configure --command "$TARGET"

info ""
info "Installed: ${TARGET} ($("$TARGET" --version 2>/dev/null || echo version unknown))"
info "MCP server: codex-computer-use"
info "Restart Claude Code and Cursor so they reload MCP configuration."
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) info "Add ${BIN_DIR} to PATH if you want to run the broker directly." ;;
esac
