# opencua — Open Computer Use for macOS

A clean-room reimplementation of macOS UI automation (accessibility tree + CGEvent input, over MCP), plus a one-shot patcher for the Codex Computer Use plugin's permission check.

## What's inside

| Path | What |
|------|------|
| `Sources/opencua/` | Clean-room Swift reimplementation of SkyComputerUseClient (~600 LOC) |
| `cua-cli.sh` | CLI that drives either opencua or the stock SkyComputerUseClient via MCP |
| `install.sh` | **One-shot patch** for the bundled SkyComputerUseClient binary — bypasses the internal permission guard so Computer Use works without OpenAI's developer signature |
| `assets/blog/` | Reverse-engineering write-up (Chinese) |

## Quick install (patch)

If you have Codex installed, this patches the built-in Computer Use plugin:

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

The script finds `Codex Computer Use.app`, backs up the original binary, applies 3 NOP patches to the permission-check function at `0x100019a00`, and ad-hoc re-signs the bundles.

After patching, grant SkyComputerUseClient the following permissions in **System Settings → Privacy & Security**:

- **Accessibility** — for reading the UI tree and simulating input
- **Screen Recording** — for screenshots

Then restart Codex. Computer Use will work without OpenAI's original signature.

## Build opencua from source

```bash
swift build -c release
```

The binary lands at `.build/release/opencua`. Run it as an MCP server:

```bash
./opencua mcp
```

Or use the CLI:

```bash
./opencua state Finder
./opencua click Finder --x 300 --y 500
```

## Why does the patch exist?

The SkyComputerUseClient binary has a hard-coded permission check at the assembly level. It reads a permission byte from a struct at offset 0x20, then branches to different error-handling paths depending on the value. The patch replaces those 3 branch instructions with NOPs, forcing the code to always reach the "both granted" success path.

The binary still needs real macOS-level Accessibility + Screen Recording permissions (those are enforced by the kernel/tccd, not by the app). The patch only removes the app's own "you didn't grant permission, refuse to work" logic.
