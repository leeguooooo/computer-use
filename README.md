# Codex Computer Use — 让任意 agent 都能用（含 sender 认证绕过）

对 OpenAI Codex 内置的「电脑使用」（Computer Use）插件做定制，让它在 macOS 上、以及 **Codex 以外的 agent（Claude Code 等）里**也能用。核心是越过客户端的 **sender 身份认证**（用一个 DYLD hook，不改二进制），并把它注册成通用 MCP server。

## 使用

**只需要两件事：运行命令 + 点 Allow。**

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

脚本会自动：

1. **定位** `Codex Computer Use.app`（依次检查 3 个已知位置）
2. **验证** 二进制版本，备份原始文件
3. **打补丁** —— 把 3 条分支指令替换为 NOP（历史遗留，实为装饰性；详见「原理：两道门」）
4. **重签名** —— ad-hoc 签名内外两层 app bundle
5. **编译 sender-auth hook** —— 构建 `team_hook.dylib`（见下「第二道门」）
6. **注册 MCP** —— 把二进制注册成 MCP server 并注入 hook，让 **Codex 以外的 agent（Claude Code 等）也能用**。检测到 `claude` CLI 时自动 `claude mcp add`（user scope，带 `DYLD_INSERT_LIBRARIES`）
7. **弹权限窗** —— 直接启动 `SkyComputerUseClient`，macOS 会自动弹出 Accessibility 和 Screen Recording 权限请求
8. **打开系统设置** —— 如果弹窗没出现，作为备选
9. **重启 Codex**

> **⚠️ MCP server 名字必须是 `mac-computer-use`（或除 `computer-use` 外的任意名）** —— `computer-use` 在 Claude Code 里是**保留名**，会被静默拒绝加载。注册后**重启 agent** 才能加载这批桌面控制工具（`list_apps` / `click` / `type_text` / `press_key` …）。

### 第二道门：sender 身份认证（`team_hook.dylib`）

除了权限自检，`SkyComputerUseClient` 还有一道**调用方身份认证**：它解析调用方的 responsible 进程，用 `SecCodeCopySigningInformation` 取 `kSecCodeInfoTeamIdentifier`，跟 OpenAI 的 Apple team `2DC432GLL2` 比对。非 Codex 调用方（Claude Code）会让**每个 tool 调用**都返回 `-10000 "Sender process is not authenticated"`。

绕过方式**不是**打二进制补丁，而是注入一个极小的 DYLD interpose（`hook/team_hook.c` → `team_hook.dylib`）：它 hook `SecCodeCopySigningInformation`，把返回字典里的 team id 改写成 `2DC432GLL2`，让这道门始终看到 OpenAI 的签名。用 `DYLD_INSERT_LIBRARIES` 注入即可，`install.sh` 会自动编译并在注册 MCP 时带上。

> **注**：README 顶部那个「三处分支改 NOP」的补丁其实**只动了错误信息的描述函数**（`0x100019a00` 是 NSError 的 description getter），并不 gate 这道 sender 认证——真正让非 Codex 能用的是这个 hook。

### 之后

**在 macOS 弹窗上点「允许」/「Allow」**（可能会弹两次，分别针对辅助功能和屏幕录制），然后等 Codex 重启完成即可使用。

如果弹窗没有自动出现，打开系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制，应该能看到 `SkyComputerUseClient.app` 在列表中，勾上即可。

### 恢复

```bash
sudo cp ~/Desktop/SkyComputerUseClient.bak.* /path/to/SkyComputerUseClient
codesign -s - --force --deep /path/to/Codex\ Computer\ Use.app
```

## 原理：两道门

让非 Codex 的 agent 用上 Computer Use，需要越过**两道**关卡。

### 第一道：权限自检 NOP（其实是装饰性的）

历史上这个补丁把 `0x100019a00` 处三条条件分支改成 `NOP`：

```
ldrb   w9, [x20, #0x20]    ; 读取枚举 discriminator
cmp    w9, #1
b.le   …                    ; ← 替换为 NOP
cmp    w9, #2
b.eq   …                    ; ← 替换为 NOP
cmp    w9, #3
b.ne   …                    ; ← 替换为 NOP
```

**但经反汇编确认，`0x100019a00` 是 NSError 的 `description` getter**（读枚举 discriminator，返回对应错误文案），配套的 `0x1000197a8` 是 `_code` getter。这三个 NOP 只会**打乱报错文字**，并不 gate 任何权限——早期「自检始终走成功路径」的说法是错的。之所以在 Codex 里能用，是因为 Codex 本来就通过了第二道门。

### 第二道：sender 身份认证（真正的门）

见上文「第二道门：sender 身份认证」一节。客户端用 `SecCodeCopySigningInformation` 取调用方 responsible 进程的 `kSecCodeInfoTeamIdentifier`，跟 OpenAI team `2DC432GLL2` 比对；不匹配就每个 tool 调用返回 `-10000`。用 `team_hook.dylib`（DYLD interpose）改写 team id 即可绕过，**不动二进制**。

> 系统级权限（Accessibility + Screen Recording）由 macOS 内核和 `tccd` 强制，任何用户态手段都绕不过；补丁后首次启动触发的系统权限弹窗是正常行为，照常点「允许」。

## 技术细节

| 项目 | 说明 |
|---|---|
| 目标文件 | `SkyComputerUseClient`（ARM64 Mach-O，`~/.codex/computer-use/…`） |
| `0x100019a00` | NSError **description getter**（错误文案映射，**非**权限门；老补丁的 3 个 NOP 落在这里） |
| `0x1000197a8` | NSError `_code` getter（`senderNotAuthenticated → -10000`） |
| 第二道门 | `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier` vs team `2DC432GLL2` |
| 绕过方式 | `hook/team_hook.c` → `team_hook.dylib`，`DYLD_INSERT_LIBRARIES` 注入（`install.sh` 自动编译） |
| NOP 指令 | `1f 20 03 d5`（ARM64 NOP） |
| 验证哈希 | `b7ad461bd5ead8c51b1e5a83e38915f6338872778d35dcb6123b74e9df9dcc47`（11841728 字节版） |

## 附：opencua（实验性）

`Sources/opencua/` 目录包含一个从零实现的 macOS UI 自动化 MCP 服务器（Swift，~600 行），功能类似 SkyComputerUseClient。目前仍在实验阶段。

```bash
swift build -c release
.build/release/opencua mcp
```
