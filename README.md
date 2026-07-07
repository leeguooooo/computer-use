# Codex Computer Use — 权限绕过补丁

对 OpenAI Codex 内置的「电脑使用」（Computer Use）插件进行二进制定制，绕过其内部的权限自检，让它在 macOS 上正常工作。

## 原理

### 问题

Codex Computer Use 依赖一个名为 `SkyComputerUseClient` 的 Mach-O 二进制程序来操作 macOS 界面（读取无障碍树、模拟鼠标键盘输入、截图）。这个二进制内部有一段**权限自检逻辑**——它从一个结构体偏移 `0x20` 处读取权限状态字节，然后根据值跳转到不同的处理路径：

| 值 | 含义 | 路径 |
|---|---|---|
| 0 或 1 | 无权限 / 仅 Accessibility | 进入错误处理，拒绝工作 |
| 2 | Screen Recording 已授权 | 继续（但可能缺少 Accessibility） |
| 3 | **两者都已授权** | 正常执行 |

问题在于，即使你在系统设置里正确授予了 Accessibility 和 Screen Recording 权限，这个自检有时仍然会因为签名状态、TCC 数据库不一致等原因返回错误值，导致 Computer Use 拒绝工作。

### 解决方案

对二进制中的条件分支指令做 **3 处 NOP 填补**，使自检逻辑**始终走到「两者已授权」的成功路径**：

```
原始汇编（0x19a10 附近）：
  ldrb   w9, [x20, #0x20]    ; 读取权限字节
  cmp    w9, #1
  b.le   error_handler        ; ≤1 → 错误       ← 替换为 NOP
  cmp    w9, #2
  b.eq   continue             ; =2 → 继续        ← 替换为 NOP
  cmp    w9, #3
  b.ne   error_handler        ; ≠3 → 错误       ← 替换为 NOP
  ; … 正常执行路径 …

补丁后：
  ldrb   w9, [x20, #0x20]
  cmp    w9, #1
  nop                        ; 原来跳错误，现在什么也不做
  cmp    w9, #2
  nop                        ; 原来跳过 success，现在继续
  cmp    w9, #3
  nop                        ; 原来跳错误，现在什么也不做
  ; … 正常执行路径（无条件到达） …
```

之后用 `codesign` 重新签名，让 macOS 接受修改后的二进制。

### 注意事项

- **系统级权限仍需手动授予**——Accessibility 和 Screen Recording 是由 macOS 内核和 `tccd` 守护进程强制执行的，应用层代码无法绕过。补丁只移除了 SkyComputerUseClient 自己的「拒绝工作」逻辑。
- 如果 System Settings 里还没有 SkyComputerUseClient.app 的条目，需要先用一次 Computer Use 触发授权弹窗，或者手动拖入。

## 使用

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/computer-use/main/install.sh | sh
```

脚本会依次查找以下位置，找到第一个就执行补丁：

1. `~/.codex/computer-use/Codex Computer Use.app`（正在运行的最新版）
2. `~/.codex/.tmp/bundled-marketplaces/…/Codex Computer Use.app`（市场分发版）
3. `~/.codex/plugins/cache/…/Codex Computer Use.app`（插件缓存版）
4. `/Applications/Codex.app/Contents/Resources/…`（系统安装版）

执行流程：
1. 定位 `SkyComputerUseClient` 二进制
2. 验证 3 个偏移处的原始字节是否匹配已知版本
3. 备份原始二进制到桌面
4. 写入 3 个 NOP 指令（`1f 20 03 d5`）
5. 对内部 `SkyComputerUseClient.app` 和外部 `Codex Computer Use.app` 做 ad-hoc 重签名

### 补丁后

授予权限 → 重启 Codex：

1. **系统设置 → 隐私与安全性 → 辅助功能** → 添加 `SkyComputerUseClient.app`
2. **系统设置 → 隐私与安全性 → 屏幕录制** → 添加 `SkyComputerUseClient.app`

`SkyComputerUseClient.app` 路径：`Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app`

### 恢复

```bash
# 从桌面备份恢复
sudo cp ~/Desktop/SkyComputerUseClient.bak.* /path/to/SkyComputerUseClient
codesign -s - --force --deep /path/to/Codex\ Computer\ Use.app
```

## 技术细节

| 项目 | 说明 |
|---|---|
| 目标文件 | `SkyComputerUseClient`（ARM64 Mach-O） |
| 补丁函数 | `0x100019a00` — 权限状态分发函数 |
| 结构体偏移 | `#0x20` — 权限状态字节 |
| 补丁方式 | 3 条 ARM64 条件分支 → `NOP`（`1f 20 03 d5`） |
| 验证哈希 | 未补丁 `sha256:b7ad461bd5ead8c51b1e5a83e38915f6338872778d35dcb6123b74e9df9dcc47`（11841728 字节版）|

## 附：opencua（实验性）

`Sources/opencua/` 目录包含一个用 Swift 从头实现的 macOS UI 自动化 MCP 服务器（~600 行），功能与 SkyComputerUseClient 类似。目前仍在实验阶段，不替代补丁方案。

```bash
swift build -c release
.build/release/opencua mcp
```
