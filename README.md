**English** · **[中文](./README.zh.md)**

# Codex Computer Use — use it from any agent (sender-auth bypass included)

A customization of OpenAI Codex's built-in **Computer Use** plugin so it works on macOS **and from agents other than Codex** (Claude Code, etc.). The core trick is getting past the client's **sender authentication** — with a small DYLD hook, no binary edit — and registering it as a generic MCP server.

> 📖 **Full teardown** — from Skyshot to the accessibility tree, incremental diffs, how the `-10000` signature gate is built, and how it's bypassed to plug into Claude Code — is on the blog:
> **[How to use Codex's Computer Use inside Claude Code](https://blog.leeguoo.com/en/posts/codex-computer-use-teardown/)**

## Install

**Two things: run the command, click Allow.**

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

The script automatically:

1. **Refreshes** the installed copy from Codex's bundled `Codex Computer Use.app` so stale patched copies do not survive across Codex updates.
2. **Verifies** the binary version and backs up the original.
3. **Patches** — replaces 3 branch instructions with NOPs (legacy step, actually cosmetic; see *How it works: two gates*).
4. **Re-signs** — ad-hoc signs both the inner and outer app bundles while preserving the original service entitlements.
5. **Builds the sender-auth hook** — compiles `team_hook.dylib` (see *Gate two* below).
6. **Registers the MCP server** — with the hook injected, so **Codex and non-Codex agents (Claude Code, etc.) can use the hooked path**. It writes `~/.codex/config.toml` as `mac_computer_use`; if the `claude` CLI is present it also runs `claude mcp add` at user scope as `mac-computer-use` with `DYLD_INSERT_LIBRARIES`.
7. **Ensures AppleEvents** — grants the user-level Codex → Computer Use AppleEvents permission needed to avoid `-1743`.
8. **Triggers the permission dialogs** — launches `SkyComputerUseClient` so macOS prompts for Accessibility + Screen Recording.
9. **Opens System Settings** — as a fallback if no dialog appears.
10. **Restarts Codex.**

> **⚠️ The hooked MCP server is intentionally not named `computer-use`.** Claude Code reserves that name and silently refuses it, so the installer uses `mac-computer-use` there. Codex receives `mac_computer_use` in `~/.codex/config.toml`. **Restart the agent** after registering so it loads the desktop-control tools (`list_apps` / `get_app_state` / `click` / `type_text` / `press_key` …).

### Codex app note

Codex may also expose the bundled `computer-use@openai-bundled` plugin. If calls through that built-in plugin fail with sender-auth or AppleEvent errors such as `-10000`, `-1743`, or `-1712`, use the hooked `mac_computer_use` MCP server after running the installer and restarting Codex. The installer writes a config block like:

```toml
[mcp_servers.mac_computer_use]
command = "/Users/you/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
args = ["mcp"]
startup_timeout_sec = 120
enabled = true

[mcp_servers.mac_computer_use.env]
DYLD_INSERT_LIBRARIES = "/Users/you/.codex/computer-use/team_hook.dylib"
```

### Gate two: sender authentication (`team_hook.dylib`)

Beyond the self-check, `SkyComputerUseClient` has a **caller authentication** step: it resolves the caller's responsible process, reads `kSecCodeInfoTeamIdentifier` and `kSecCodeInfoIdentifier` via `SecCodeCopySigningInformation`, and compares them against OpenAI's Apple team `2DC432GLL2` plus an approved OpenAI bundle id. A non-Codex caller (Claude Code) makes **every tool call** return `-10000 "Sender process is not authenticated"`.

The bypass is **not** a binary patch — it's a tiny DYLD interpose (`hook/team_hook.c` → `team_hook.dylib`) that hooks `SecCodeCopySigningInformation` and rewrites the team id plus bundle identifier in the returned dictionary to an approved OpenAI caller, so the gate always sees OpenAI's signature. Inject it with `DYLD_INSERT_LIBRARIES`; `install.sh` compiles it and wires it in at registration time.

> **Note:** the 3-NOP patch in step 3 only touches the **error-description getter** (`0x100019a00` is the NSError `description` getter); it does **not** gate this sender auth. The hook is what actually lets non-Codex agents in.

### After install

**Click Allow on the macOS dialogs** (it may prompt twice — Accessibility and Screen Recording), then wait for Codex to relaunch.

If no dialog appears, open System Settings → Privacy & Security → Accessibility / Screen Recording and enable `SkyComputerUseClient.app` in the list.

### Restore

```bash
sudo cp ~/Desktop/SkyComputerUseClient.bak.* /path/to/SkyComputerUseClient
codesign -s - --force --deep /path/to/Codex\ Computer\ Use.app
```

## How it works: two gates

Getting a non-Codex agent onto Computer Use means clearing **two** gates.

### Gate one: the self-check NOPs (actually cosmetic)

Historically this patch NOPs three conditional branches at `0x100019a00`:

```
ldrb   w9, [x20, #0x20]    ; read the enum discriminator
cmp    w9, #1
b.le   …                    ; ← replaced with NOP
cmp    w9, #2
b.eq   …                    ; ← replaced with NOP
cmp    w9, #3
b.ne   …                    ; ← replaced with NOP
```

**But disassembly confirms `0x100019a00` is the NSError `description` getter** (it reads the enum discriminator and returns the matching error text); the paired `0x1000197a8` is the `_code` getter. Those three NOPs only **scramble the error message** — they gate nothing. The earlier "the self-check always takes the success path" claim was wrong. It works inside Codex only because Codex already passes gate two.

### Gate two: sender authentication (the real gate)

See *Gate two* above. The client reads the caller's responsible-process `kSecCodeInfoTeamIdentifier` and `kSecCodeInfoIdentifier` via `SecCodeCopySigningInformation` and compares them to OpenAI team `2DC432GLL2` plus the approved OpenAI bundle-id list; a mismatch makes every tool call return `-10000`. `team_hook.dylib` (a DYLD interpose) rewrites both fields to pass it — **no binary edit**.

> System-level permissions (Accessibility + Screen Recording) are enforced by the macOS kernel and `tccd` — no userspace trick bypasses those. The system permission prompt on first launch after patching is expected; just click Allow.

## macOS support & known limitations

Validated across three machines (author + two collaborating agents):

| macOS | install / patch / build hook | `list_apps` (no `-10000`) | `get_app_state` / click |
|---|---|---|---|
| 15.x (Sonoma / Sequoia) | ✅ | ✅ | ✅ full — verified end-to-end |
| 26 / 27 (Tahoe) | ✅ | ✅ | ⛔ blocked by the OS |

The sender-auth hook is **portable** — `list_apps` returns real data with no `-10000` on every machine tested, which proves the bypass itself works. The rest depends on how strictly the machine enforces code signing:

- **Full function** needs one *consistent* ad-hoc `--deep` signature across the bundle (the installer default). Re-signing pieces separately or stripping entitlements breaks the client↔Service handshake → `get_app_state` returns `-10005`. Keep the default signing.
- **Enforced library validation** (the ad-hoc `team_hook.dylib` gets SIGKILL'd "Code Signature Invalid", seen on some macOS 15.x): re-run with **`CUA_HOOK_ENTITLEMENTS=1`**, which merges `com.apple.security.cs.disable-library-validation` + `allow-dyld-environment-variables` onto the launched binaries so the hook loads. Off by default — on newer macOS it can trade away `get_app_state`.
- **macOS 26/27 (Tahoe)**: `list_apps`-only. `get_app_state` / `click` fail (`-10005`, `SkyComputerUseService not valid -423`) because the Service needs restricted private entitlements (`com.apple.private.tcc.manager.*`) that ad-hoc signing can't carry (keep → AMFI `-424`; strip → `-423`/denied). Getting past this needs relaxing SIP/AMFI (`csrutil` / `amfi_get_out_of_my_way`, not recommended) or a real Apple cert.

The installer avoids POSIX-incompatible shell syntax, so `curl … | sh` (bash POSIX mode) works as-is.

## Technical details

| Item | Detail |
|---|---|
| Target binary | `SkyComputerUseClient` (ARM64 Mach-O, `~/.codex/computer-use/…`) |
| `0x100019a00` | NSError **description getter** (error-text mapping, **not** a permission gate; the old 3 NOPs land here) |
| `0x1000197a8` | NSError `_code` getter (`senderNotAuthenticated → -10000`) |
| Gate two | `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier` + `kSecCodeInfoIdentifier` vs OpenAI team and bundle-id allowlist |
| Bypass | `hook/team_hook.c` → `team_hook.dylib`, injected via `DYLD_INSERT_LIBRARIES` (compiled by `install.sh`) |
| Required TCC entry | `com.openai.codex` → `com.openai.sky.CUAService` for AppleEvents (`install.sh` ensures this in the user TCC database) |
| NOP instruction | `1f 20 03 d5` (ARM64 NOP) |
| Verified hash | `b7ad461bd5ead8c51b1e5a83e38915f6338872778d35dcb6123b74e9df9dcc47` (11841728-byte build) |

## Scope & disclaimer

This is interoperability and learning-oriented reverse engineering on your **own** machine and your **own** installed copy of Codex. System-level permissions (Accessibility / Screen Recording) are still enforced by macOS TCC and are neither bypassed nor should be. Use it in compliance with the laws of your jurisdiction and any applicable terms of service.
