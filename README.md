# computer-use

Drive **macOS Computer Use** from Claude Code, Cursor, or any MCP client — by
brokering the **official OpenAI Codex Computer Use runtime**.

No binary patching. No code-signature re-signing. No team-identifier spoofing.
Computer Use runs inside your own, legitimately-signed Codex process, so it
passes OpenAI's sender authentication the way it was designed to.

> **Prior versions** of this repo patched OpenAI's `SkyComputerUseClient` and
> injected a DYLD hook that rewrote `kSecCodeInfoTeamIdentifier` to OpenAI's
> team id to defeat sender-auth. That approach brought signing hell, a hard
> macOS 26/27 (Tahoe) wall, and depended on bypassing OpenAI's auth. It has been
> **removed**. This is the broker rewrite.

## How it works

```
Claude Code / Cursor
        │  stdio MCP
        ▼
codex-computer-use-mcp        ← this repo (a small Python broker)
        │  inject runtime bootstrap into codex / codex-reply calls,
        │  otherwise transparent pass-through
        ▼
codex mcp-server              ← your official, signed Codex CLI
        │
        ▼
node_repl → import("@oai/sky")  ← the official Computer Use runtime
```

The broker spawns `codex mcp-server` as a child, proxies MCP JSON-RPC in both
directions (requests, responses, notifications, progress, and MCP elicitation),
and does exactly two things beyond pass-through:

1. On `codex` / `codex-reply` tool calls it appends an idempotent bootstrap
   instruction telling the Codex agent to load the Computer Use runtime with
   `globalThis.sky = (await import("@oai/sky")).sky;` inside `node_repl`.
2. It rewrites the `codex` / `codex-reply` tool descriptions so the client
   presents them as Computer Use entry points.

Because the actual UI actions execute inside Codex, sender authentication and
macOS TCC permissions are handled by Codex itself — nothing here forges an
identity or writes to the TCC database.

## Requirements

- macOS 15 or newer.
- The **Codex CLI** on your `PATH` (`codex --version`).
- The **OpenAI Computer Use plugin** installed in Codex (the broker discovers it
  under `~/.codex/plugins/cache/openai-bundled/computer-use/<version>/`).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

This installs a single Python file to `~/.local/bin/codex-computer-use-mcp` and
idempotently registers it (as `codex-computer-use`) in your Claude Code and
Cursor MCP configs. Restart Claude Code / Cursor afterward.

## Update

Re-run the same one-liner — the installer is idempotent, overwrites the broker
in place, and re-registers it without touching your other MCP servers:

```sh
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

Restart Claude Code / Cursor afterward. Check what you have with:

```sh
~/.local/bin/codex-computer-use-mcp --version
```

By default the installer tracks the latest `main`. To pin a specific release,
set `COMPUTER_USE_REF`:

```sh
COMPUTER_USE_REF=v2.0.0 curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/v2.0.0/install.sh | sh
```

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh -s -- --uninstall
```

## Configuration

| Env var | Purpose |
|---|---|
| `CODEX_COMPUTER_USE_CODEX` | Absolute path to the `codex` binary (default: first `codex` on `PATH`). |
| `CODEX_COMPUTER_USE_PLUGIN_ROOT` | Override the discovered Computer Use plugin root (must contain `skills/computer-use/SKILL.md` or the legacy `scripts/computer-use-client.mjs`). |

## Usage

Once registered, the client sees a `codex` (and `codex-reply`) tool titled
*Codex Computer Use*. Call it with a task; Codex inspects and operates macOS apps
via the accessibility tree, taking screenshots only when needed.

## Development

```sh
python3 -m pytest tests/      # unit + protocol + installer tests
```

- `bin/codex-computer-use-mcp` — the broker.
- `tests/` — unit tests, a fake Codex MCP server, and protocol/installer tests.
- `docs/broker-only-design.html` — the design spec for this rewrite.

## Known limitations

- **macOS only** (it rides your Codex install).
- The broker spawns `codex mcp-server`, which the Codex CLI currently marks
  **deprecated**. When it is removed upstream this broker will need to switch to
  the replacement command.
- If you'd rather not depend on OpenAI's bundled runtime at all, a fully
  independent, MIT-licensed reimplementation exists:
  [QwenLM/open-computer-use](https://github.com/QwenLM/open-computer-use).

## License

MIT.
