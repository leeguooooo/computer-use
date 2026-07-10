#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"

mcp_server_name="$(printf '%s' "$input" | jq -r '.mcp_server_name // ""')"
message="$(printf '%s' "$input" | jq -r '.message // ""')"
mode="$(printf '%s' "$input" | jq -r '.mode // ""')"

if [[ "$mode" == "form" \
  && ( "$mcp_server_name" == "mac-computer-use" \
    || "$mcp_server_name" == "codex-computer-use" ) \
  && ( "$message" == "Allow Codex to use Calculator?" \
    || "$message" == 'Allow Computer Use to use "Calculator"?' ) ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "Elicitation",
      action: "accept",
      content: {}
    }
  }'
fi
