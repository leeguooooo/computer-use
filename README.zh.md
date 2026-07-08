**[English](./README.md)** · **中文**

# Codex Computer Use — 让任意 agent 都能用（含 sender 认证绕过）

对 OpenAI Codex 内置的「电脑使用」（Computer Use）插件做定制，让它在 macOS 上、以及 **Codex 以外的 agent（Claude Code 等）里**也能用。核心是越过客户端的 **sender 身份认证**（用一个 DYLD hook，不改二进制），并把它注册成通用 MCP server。

> 📖 **完整拆解**：从 Skyshot 到无障碍树、增量 diff、那道 `-10000` 签名门怎么实现、又怎么绕过接进 Claude Code —— 全文写在博客里：
> **[如何在 Claude Code 里用上 Codex 的 Computer Use](https://blog.leeguoo.com/zh/posts/codex-computer-use-teardown/)**

## 使用

**只需要两件事：运行命令 + 点 Allow。**

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

脚本会自动：

1. **刷新安装副本** —— 从 Codex bundled 的 `Codex Computer Use.app` 复制，避免 Codex 更新后继续复用旧的已 patch 副本
2. **验证** 二进制版本，备份原始文件
3. **打补丁** —— 把 3 条分支指令替换为 NOP（历史遗留，实为装饰性；详见「原理：两道门」）
4. **重签名** —— ad-hoc 签名内外两层 app bundle，并保留原始 service entitlements
5. **编译 sender-auth hook** —— 构建 `team_hook.dylib`（见下「第二道门」）
6. **注册 MCP** —— 把二进制注册成带 hook 的 MCP server，让 **Codex 和 Codex 以外的 agent（Claude Code 等）都走 hooked 路径**。脚本会在 `~/.codex/config.toml` 写入 `mac_computer_use`；检测到 `claude` CLI 时也会自动 `claude mcp add`（user scope，名字为 `mac-computer-use`，带 `DYLD_INSERT_LIBRARIES`）
7. **确保 AppleEvents** —— 写入用户级 Codex → Computer Use AppleEvents 授权，避免 `-1743`
8. **弹权限窗** —— 直接启动 `SkyComputerUseClient`，macOS 会自动弹出 Accessibility 和 Screen Recording 权限请求
9. **打开系统设置** —— 如果弹窗没出现，作为备选
10. **重启 Codex**

> **⚠️ hooked MCP server 刻意不叫 `computer-use`。** `computer-use` 在 Claude Code 里是**保留名**，会被静默拒绝加载，所以 Claude Code 里使用 `mac-computer-use`。Codex 里写入 `~/.codex/config.toml` 的名字是 `mac_computer_use`。注册后**重启 agent** 才能加载这批桌面控制工具（`list_apps` / `get_app_state` / `click` / `type_text` / `press_key` …）。

### Codex app 说明

Codex 可能同时暴露内置的 `computer-use@openai-bundled` 插件。如果通过这个内置插件调用时出现 sender-auth 或 AppleEvent 错误，例如 `-10000`、`-1743` 或 `-1712`，请运行 installer 并重启 Codex，然后使用 hooked 的 `mac_computer_use` MCP server。installer 会写入类似下面的配置：

```toml
[mcp_servers.mac_computer_use]
command = "/Users/you/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
args = ["mcp"]
startup_timeout_sec = 120
enabled = true

[mcp_servers.mac_computer_use.env]
DYLD_INSERT_LIBRARIES = "/Users/you/.codex/computer-use/team_hook.dylib"
```

### 第二道门：sender 身份认证（`team_hook.dylib`）

除了权限自检，`SkyComputerUseClient` 还有一道**调用方身份认证**：它解析调用方的 responsible 进程，用 `SecCodeCopySigningInformation` 取 `kSecCodeInfoTeamIdentifier` 和 `kSecCodeInfoIdentifier`，跟 OpenAI 的 Apple team `2DC432GLL2` 以及 OpenAI bundle id 白名单比对。非 Codex 调用方（Claude Code）会让**每个 tool 调用**都返回 `-10000 "Sender process is not authenticated"`。

绕过方式**不是**打二进制补丁，而是注入一个极小的 DYLD interpose（`hook/team_hook.c` → `team_hook.dylib`）：它 hook `SecCodeCopySigningInformation`，把返回字典里的 team id 和 bundle identifier 改写成允许的 OpenAI 调用方，让这道门始终看到 OpenAI 的签名。用 `DYLD_INSERT_LIBRARIES` 注入即可，`install.sh` 会自动编译并在注册 MCP 时带上。

> **注**：上面第 3 步那个「三处分支改 NOP」的补丁其实**只动了错误信息的描述函数**（`0x100019a00` 是 NSError 的 description getter），并不 gate 这道 sender 认证——真正让非 Codex 能用的是这个 hook。

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

见上文「第二道门：sender 身份认证」一节。客户端用 `SecCodeCopySigningInformation` 取调用方 responsible 进程的 `kSecCodeInfoTeamIdentifier` 和 `kSecCodeInfoIdentifier`，跟 OpenAI team `2DC432GLL2` 以及 OpenAI bundle id 白名单比对；不匹配就每个 tool 调用返回 `-10000`。用 `team_hook.dylib`（DYLD interpose）改写这两个字段即可绕过，**不动二进制**。

> 系统级权限（Accessibility + Screen Recording）由 macOS 内核和 `tccd` 强制，任何用户态手段都绕不过；补丁后首次启动触发的系统权限弹窗是正常行为，照常点「允许」。

## macOS 支持 / 已知限制

在三台机器上验证过(作者 + 两个协作 agent):

| macOS | 安装 / 打补丁 / 编 hook | `list_apps`(无 `-10000`) | `get_app_state` / 点击 |
|---|---|---|---|
| 15.x(Sonoma / Sequoia) | ✅ | ✅ | ✅ 完整,端到端跑通 |
| 26 / 27(Tahoe) | ✅ | ✅ | ⛔ 被系统挡住 |

sender 认证 hook 是**可移植**的 —— 每台机器上 `list_apps` 都能返回真实数据、无 `-10000`,绕过本身成立。剩下的取决于机器对代码签名有多严:

- **完整功能**需要整个 bundle 用**一致的** ad-hoc `--deep` 签名(安装脚本默认就是)。分开重签或剥掉 entitlements 会破坏 client↔Service 握手 → `get_app_state` 返回 `-10005`。别改默认签名。
- **强制库校验的机器**(ad-hoc `team_hook.dylib` 被 SIGKILL「Code Signature Invalid」,部分 macOS 15.x 会):用 **`CUA_HOOK_ENTITLEMENTS=1`** 重跑,它会把 `com.apple.security.cs.disable-library-validation` + `allow-dyld-environment-variables` **合并**进被启动的二进制,让 hook 能加载。默认不开 —— 在较新 macOS 上它可能牺牲掉 `get_app_state`。
- **macOS 26/27(Tahoe)**:只支持 `list_apps`。`get_app_state` / 点击失败(`-10005`、`SkyComputerUseService not valid -423`),因为 Service 要带受限私有 entitlements(`com.apple.private.tcc.manager.*`),ad-hoc 签名给不了(保留 → AMFI `-424`;剥掉 → `-423`/无权限)。要过这道只能放松 SIP/AMFI(`csrutil` / `amfi_get_out_of_my_way`,不建议)或用真 Apple 证书。

安装脚本避开了 POSIX 不兼容的 shell 语法,所以 `curl … | sh`(bash POSIX 模式)可直接用。

## 技术细节

| 项目 | 说明 |
|---|---|
| 目标文件 | `SkyComputerUseClient`（ARM64 Mach-O，`~/.codex/computer-use/…`） |
| `0x100019a00` | NSError **description getter**（错误文案映射，**非**权限门；老补丁的 3 个 NOP 落在这里） |
| `0x1000197a8` | NSError `_code` getter（`senderNotAuthenticated → -10000`） |
| 第二道门 | `SecCodeCopySigningInformation` → `kSecCodeInfoTeamIdentifier` + `kSecCodeInfoIdentifier` vs OpenAI team 和 bundle id 白名单 |
| 绕过方式 | `hook/team_hook.c` → `team_hook.dylib`，`DYLD_INSERT_LIBRARIES` 注入（`install.sh` 自动编译） |
| 必需 TCC 记录 | `com.openai.codex` → `com.openai.sky.CUAService` 的 AppleEvents 授权（`install.sh` 会写入用户 TCC 数据库） |
| NOP 指令 | `1f 20 03 d5`（ARM64 NOP） |
| 验证哈希 | `b7ad461bd5ead8c51b1e5a83e38915f6338872778d35dcb6123b74e9df9dcc47`（11841728 字节版） |

## 边界声明

这是在自己机器、自己安装的 Codex 上做的互操作与学习性逆向。系统级权限（辅助功能 / 屏幕录制）仍由 macOS TCC 强制，绕不过也不应绕。请在遵守你所在地区法律和相关服务条款的前提下使用。
