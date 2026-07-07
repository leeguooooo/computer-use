# Codex Computer Use — 权限绕过补丁

对 OpenAI Codex 内置的「电脑使用」（Computer Use）插件做二进制定制，绕过其内部的权限自检，让它在 macOS 上正常工作。

## 使用

**只需要两件事：运行命令 + 点 Allow。**

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

脚本会自动：

1. **定位** `Codex Computer Use.app`（依次检查 3 个已知位置）
2. **验证** 二进制版本，备份原始文件
3. **打补丁** —— 把 3 条权限检查分支指令替换为 NOP
4. **重签名** —— ad-hoc 签名内外两层 app bundle
5. **注册 MCP** —— 把补丁后的二进制注册成 MCP server，让 **Codex 以外的 agent（Claude Code 等）也能用**。检测到 `claude` CLI 时会自动 `claude mcp add`（user scope）
6. **弹权限窗** —— 直接启动 `SkyComputerUseClient`，macOS 会自动弹出 Accessibility 和 Screen Recording 权限请求
7. **打开系统设置** —— 如果弹窗没出现，作为备选
8. **重启 Codex**

> **⚠️ MCP server 名字必须是 `mac-computer-use`（或除 `computer-use` 外的任意名）** —— `computer-use` 在 Claude Code 里是**保留名**，会被静默拒绝加载。注册后**重启 agent** 才能加载这批桌面控制工具（`list_apps` / `click` / `type_text` / `press_key` …）。

### 之后

**在 macOS 弹窗上点「允许」/「Allow」**（可能会弹两次，分别针对辅助功能和屏幕录制），然后等 Codex 重启完成即可使用。

如果弹窗没有自动出现，打开系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制，应该能看到 `SkyComputerUseClient.app` 在列表中，勾上即可。

### 恢复

```bash
sudo cp ~/Desktop/SkyComputerUseClient.bak.* /path/to/SkyComputerUseClient
codesign -s - --force --deep /path/to/Codex\ Computer\ Use.app
```

## 原理

`SkyComputerUseClient` 内部有一段权限自检逻辑：

```
ldrb   w9, [x20, #0x20]    ; 读取权限状态字节
cmp    w9, #1
b.le   error_handler        ; ≤1 → 拒绝工作    ← 替换为 NOP
cmp    w9, #2
b.eq   continue             ; =2 → 继续        ← 替换为 NOP
cmp    w9, #3
b.ne   error_handler        ; ≠3 → 拒绝工作    ← 替换为 NOP
; … 正常执行路径 …
```

三处条件分支替换为 `NOP`（`1f 20 03 d5`）后，自检逻辑**始终走到成功路径**，不再因为权限状态字节异常而拒绝工作。

系统级权限（Accessibility + Screen Recording）由 macOS 内核和 `tccd` 强制，二进制自己无法绕过。补丁只移除了应用层「拒绝工作」的逻辑。补丁后首次启动会触发 macOS 系统权限弹窗，这是正常行为。

## 技术细节

| 项目 | 说明 |
|---|---|
| 目标文件 | `SkyComputerUseClient`（ARM64 Mach-O） |
| 补丁函数 | `0x100019a00` — 权限状态分发 |
| 结构体偏移 | `#0x20` — 权限状态字节 |
| 补丁指令 | `1f 20 03 d5`（ARM64 NOP） |
| 验证哈希 | `b7ad461bd5ead8c51b1e5a83e38915f6338872778d35dcb6123b74e9df9dcc47`（11841728 字节版） |

## 附：opencua（实验性）

`Sources/opencua/` 目录包含一个从零实现的 macOS UI 自动化 MCP 服务器（Swift，~600 行），功能类似 SkyComputerUseClient。目前仍在实验阶段。

```bash
swift build -c release
.build/release/opencua mcp
```
