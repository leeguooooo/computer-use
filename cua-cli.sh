#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CUA="/Users/leo/.codex/plugins/cache/openai-bundled/computer-use/1.0.857/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
CUA="${CUA:-$DEFAULT_CUA}"
CUA_WAIT_SECONDS="${CUA_WAIT_SECONDS:-5}"

usage() {
  cat <<'EOF'
Usage:
  cua-cli.sh tools
  cua-cli.sh list-apps
  cua-cli.sh state <app>
  cua-cli.sh click <app> --element <id> [--count <n>] [--button left|right|middle]
  cua-cli.sh click <app> --x <num> --y <num> [--count <n>] [--button left|right|middle]
  cua-cli.sh type <app> <text>
  cua-cli.sh key <app> <key>
  cua-cli.sh scroll <app> <element_id> <up|down|left|right> [pages]
  cua-cli.sh raw <tool_name> <json_arguments>

Examples:
  ./cua-cli.sh list-apps
  ./cua-cli.sh state WeChat
  ./cua-cli.sh state '微信'
  ./cua-cli.sh click WeChat --x 300 --y 500
  ./cua-cli.sh type WeChat 'hello from cli'
  ./cua-cli.sh key WeChat Return
  ./cua-cli.sh raw get_app_state '{"app":"com.tencent.xinWeChat"}'

Environment:
  CUA=/path/to/SkyComputerUseClient  Override binary path.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

json_string() {
  jq -Rn --arg v "$1" '$v'
}

call_mcp() {
  local mode="$1"
  local tool_name="${2:-}"
  local payload="{}"
  local payload_json

  if [[ "$#" -ge 3 ]]; then
    payload="$3"
  fi

  need jq
  [[ -x "$CUA" ]] || die "SkyComputerUseClient is not executable: $CUA"

  payload_json="$(printf '%s' "$payload" | jq -c .)" || die "invalid JSON arguments: $payload"

  if [[ "$mode" == "tools" ]]; then
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cua-cli","version":"0"}}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      sleep "$CUA_WAIT_SECONDS"
    } | "$CUA" mcp | jq 'select(.id==2)'
  else
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cua-cli","version":"0"}}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
      jq -nc --arg name "$tool_name" --argjson arguments "$payload_json" \
        '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$name,arguments:$arguments}}'
      sleep "$CUA_WAIT_SECONDS"
    } | "$CUA" mcp | jq 'select(.id==2)'
  fi
}

require_args() {
  local have="$1"
  local want="$2"
  [[ "$have" -ge "$want" ]] || {
    usage >&2
    exit 2
  }
}

cmd="${1:-}"
[[ -n "$cmd" ]] || {
  usage
  exit 0
}
shift || true

case "$cmd" in
  -h|--help|help)
    usage
    ;;

  tools)
    call_mcp tools
    ;;

  list-apps)
    call_mcp call list_apps '{}'
    ;;

  state)
    require_args "$#" 1
    app="$1"
    call_mcp call get_app_state "$(jq -nc --arg app "$app" '{app:$app}')"
    ;;

  type)
    require_args "$#" 2
    app="$1"
    text="$2"
    call_mcp call type_text "$(jq -nc --arg app "$app" --arg text "$text" '{app:$app,text:$text}')"
    ;;

  key)
    require_args "$#" 2
    app="$1"
    key="$2"
    call_mcp call press_key "$(jq -nc --arg app "$app" --arg key "$key" '{app:$app,key:$key}')"
    ;;

  scroll)
    require_args "$#" 3
    app="$1"
    element="$2"
    direction="$3"
    pages="${4:-1}"
    call_mcp call scroll "$(jq -nc --arg app "$app" --arg element "$element" --arg direction "$direction" --argjson pages "$pages" \
      '{app:$app,element_index:$element,direction:$direction,pages:$pages}')"
    ;;

  click)
    require_args "$#" 2
    app="$1"
    shift

    element=""
    x=""
    y=""
    count="1"
    button="left"

    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --element)
          require_args "$#" 2
          element="$2"
          shift 2
          ;;
        --x)
          require_args "$#" 2
          x="$2"
          shift 2
          ;;
        --y)
          require_args "$#" 2
          y="$2"
          shift 2
          ;;
        --count)
          require_args "$#" 2
          count="$2"
          shift 2
          ;;
        --button)
          require_args "$#" 2
          button="$2"
          shift 2
          ;;
        *)
          die "unknown click option: $1"
          ;;
      esac
    done

    if [[ -n "$element" ]]; then
      payload="$(jq -nc --arg app "$app" --arg element "$element" --arg button "$button" --argjson count "$count" \
        '{app:$app,element_index:$element,mouse_button:$button,click_count:$count}')"
    elif [[ -n "$x" && -n "$y" ]]; then
      payload="$(jq -nc --arg app "$app" --arg button "$button" --argjson count "$count" --argjson x "$x" --argjson y "$y" \
        '{app:$app,x:$x,y:$y,mouse_button:$button,click_count:$count}')"
    else
      die "click requires either --element <id> or --x <num> --y <num>"
    fi

    call_mcp call click "$payload"
    ;;

  raw)
    require_args "$#" 2
    call_mcp call "$1" "$2"
    ;;

  *)
    die "unknown command: $cmd"
    ;;
esac
