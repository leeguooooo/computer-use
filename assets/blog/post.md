---
locale: zh
slug: codex-computer-use-teardown
section: editorial
title: Codex 怎么操作你的 Mac：从 Skyshot 到那道签名门
summary: 把 OpenAI 的 Codex Computer Use 从截图拆到汇编。它不是"看图点坐标"，而是一套无障碍树优先的原生 Swift 方案。记录它的架构、给模型看的那棵树、增量 diff、以及那道只认 OpenAI 签名的鉴权门是怎么实现的。
category: re-sec
tags: [computer-use, 逆向, macOS, accessibility, codex, mcp, 代码签名]
---

![侦探小猎犬拿放大镜拆一台 Mac，旁边是 UI 线框和无障碍树示意图](https://img.leeguoo.com/media/ec1886da-4235-4149-9581-f1928635bd70/cover.png)

我机器上装了 Codex 的 Computer Use 插件，用了一阵子，感觉它操作 App 比我见过的都稳：点得准、滚得对、很少点空。我想知道为什么，就把它拆了。

拆的过程没运行、没改二进制、没联网，纯静态读符号和字符串，读不动的地方再看反汇编。中途做了两件"动手"的事：一是通过官方 Codex 让它真跑一次，二是照着理解自己写了一个复刻版。下面是拆出来的东西，以及照着做时踩到的坑。

## 先给结论：它不靠"看图点坐标"

市面上很多 computer use 是这套路：截图 → 模型看图 → 输出像素坐标 → 点。纯视觉方案的毛病也明显：坐标会漂、小控件点不准、滚动之后失效、图还费 token。

Codex 走的是另一条：**无障碍树（Accessibility Tree）优先，截图只做兜底**。它主工具的自述字符串写得很直白：

> Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app.

每回合动手前，先取一次状态，同时拿到**截图**和**无障碍树**。有结构化控件就按树里的编号点（准、稳、便宜），实在没有再退回按像素点（通用）。这个"两条腿"的设计，是它体感好的根。

## 两个进程，一个叫 Sky 的代号

它不是脚本，是一套原生 macOS 应用，arm64 Swift，最低 macOS 14.4。拆开 `.app` 会看到两个可执行文件：

- `SkyComputerUseClient`（11MB）：MCP 前端。Codex 通过它暴露工具，随对话回合起落，短命。
- `SkyComputerUseService`（17MB）：常驻引擎。真正干截屏、遍历树、注入输入的活。

两者之间用 XPC + Mach port 通信（传输类叫 `ComputerUseIPCXPCTransport`，通道名 `CodexComputerUseIPC-1`），共享同一个 App Group 保活状态。另外还带了两个小 App：一个装在自动化期间防锁屏（`CUALockScreenGuardian`），一个引导权限授予。

内部代号是 **Sky**。截图加树的那份快照它叫 `Skyshot`，观察录制功能叫 `Skysight`，输入抽象前缀是 `SAI`。

为什么拆成两个进程？因为回合之间要保活状态：那棵树、事件流、权限授权都得在 service 侧留着，前端只做协议翻译。这也是后面"增量 diff"能成立的前提。

![一只小猎犬看着一半是截图、一半是缩进大纲树的屏幕](https://img.leeguoo.com/media/5f16faa5-50ac-461c-bc37-f5496942b1ef/skyshot.png)

## Skyshot：同一帧里，一张截图配一棵树

Skyshot 是整套方案里最值得抄的一点。

截图这边走 ScreenCaptureKit，抓完压成 JPEG，压得很小。我实测让它抓一个 TextEdit 窗口，回来的图是 586×488、23.5KB。小图省 token，但真正的信息载体不是图，是那棵树。

树这边是把系统无障碍 API 遍历到的真实控件，投影成一段给模型读的文本。它的类名直接叫 `LMReadableElement`（LM = Language Model）。截图只是让模型"看一眼确认"，具体点哪个、读什么值，都靠树。

## 给模型看的那棵树长什么样

光说没用，我让它对一个 TextEdit 窗口取了次状态，把真实返回抠出来（节选）：

```
Computer Use state (CUA App Version: 857)
<app_state>
App=/System/Applications/TextEdit.app/ (bundleID com.apple.TextEdit, pid 71221)
Window: "Untitled", App: TextEdit.
0 standard window Untitled, Secondary Actions: Raise
	1 scroll area Secondary Actions: Scroll Left, Scroll Right, Scroll Up, Scroll Down
		2 text entry area (settable, string) Value: <正文>, ID: First Text View
	21 container
		22 checkbox bold, Help: Bold text, Value: 0
	28 pop up button typeface, Help: Choose the typeface, Value: Helvetica
The focused UI element is 2 text entry area (settable, string) …
</app_state>
```

这段格式，就是它的"界面语言"。逐个字段拆开看：

| 元素 | 样例 | 含义 |
|---|---|---|
| 行首整数 | `2 text entry area …` | **元素编号**，click / set_value / scroll 都靠它定位 |
| 缩进（Tab） | 子节点比父节点多一层 | 编码树的深度 |
| 角色 | `standard window`、`pop up button` | 大白话，模型直接懂 |
| 括号特征 | `(settable, string)`、`(disabled, settable, float)` | 能不能设值、什么类型、是否禁用 |
| 字段 | `Value:`、`Help:`、`ID:` | 当前值、悬浮提示、控件标识 |
| Secondary Actions | `Raise`、`Show color panel` | 额外的无障碍动作，另有工具触发 |
| 末尾焦点 | `The focused UI element is 2 …` | 直接点出当前焦点，省模型一次推断 |

整扇富控件的 TextEdit 窗口，序列化完才 3.6KB。纯文本、行首编号、Tab 缩进、大白话角色，省 token、对 diff 友好、模型零学习成本。`(settable)` 这个括号很妙，它等于直接告诉模型"这个能不能改"，把后面的 set_value 和增量 diff 都串了起来。

## 十个工具，两种寻址

从前端二进制里能拉出完整的工具表，一共十个。核心那几个：

- `get_app_state`：取状态（截图 + 树），每回合必须先调一次。
- `click`：按编号点，或者按截图像素坐标点。
- `type_text` / `press_key`：打字、按组合键。
- `scroll`：按"页"滚某个元素，支持小数页。
- `set_value`：直接设某个可设值控件的值，不逐字敲。
- `perform_secondary_action`：触发上面那些 Secondary Actions。

`click` 这里有个细节：它同时收 `element_index` 和 `x/y`。这不是二选一的凑合，是刻意的降级链：能用结构就绝不用像素。`set_value` 也一样：与其一个键一个键模拟输入，不如直接把控件值设成目标，快、稳、还不受输入法干扰。它甚至让模型用"树里那段文本本身"来定位光标，文本不唯一时再给前后缀消歧。

## 只发变化的那部分：增量 diff

这条最省钱，也最容易被忽略。二进制里直接躺着这几句给模型的话：

```
The following is a diff from the previous accessibility tree
The following is a cumulative diff from the initial accessibility tree
There has been no change in the accessibility tree for …
```

第一次给完整树，之后每回合只发**差异**：相对上一回合，或相对初始态的累计差异；没变化就直接说"没变"。大型 App 的完整树可能上万 token，每回合重发就是烧钱。

能做 diff 的前提，是那个元素编号在回合之间**稳定**。这靠常驻 service 维护一套事务化、可失效的树结构（类名 `UIElementTreeTransaction`、`UIElementTreeInvalidationMonitor`）。纯视觉、无状态的方案做不了这件事，这正是双进程有状态架构换来的回报。

## 输入是怎么打进去的，以及那些不起眼的护栏

输入走 Core Graphics 事件合成，不是脆的 AppleScript：`CGEvent` / `CGEventSource` 合成鼠标键盘，字符串翻译成虚拟键序列（含修饰键、布局无关），对支持的控件还能直接发 `AXPress`。

真正拉开差距的是护栏，这些东西 demo 里根本用不上，长时间跑才知道疼：

- **焦点防抢占**（`SystemFocusStealPreventer`、`SyntheticAppFocusEnforcer`）：合成输入最大的坑是打到一半焦点被别的窗口或通知抢走，按键落到错误的 App。它专门有子系统钉住目标前台。
- **防锁屏**（`CUALockScreenGuardian`）：锁屏状态下，macOS 对无障碍隐藏所有 App 窗口。这条我后面复刻时亲身撞到了。
- **点亮 Electron**（`AXManualAccessibility`）：Chromium / Electron 默认不向无障碍暴露 DOM 树。它给这类 App 设 `AXManualAccessibility=true`，现场逼 Chromium 构建出树。所以 Codex 在浏览器、VS Code、Slack 里也能拿到结构化元素，而不只是截图。
- **捕获前高亮**：截图前先在屏幕上画个高亮框（IPC 消息里带 `CaptureAnimation` 系列），让你看得见"AI 正在看这里"。

## 它会自己停下来：确认策略

插件里附带的 `SKILL.md` 内嵌了一份挺克制的确认策略。因为 UI 动作有真实副作用（删数据、转账、发消息），它把风险动作切成四档：交给用户自己做、每次动手前必确认、初始 prompt 授权即可、始终允许。删云端数据、装新软件、金融交易、解验证码这些划在"必确认"。

它还分"用户亲手输入的指令"和"第三方内容里夹带的指令"：后者（网页、PDF、粘贴文本）一律当潜在恶意，永不视为授权。

这套东西我见它当场跑了一遍。我让官方 Codex 用 Computer Use 给微信联系人发条消息，它导航到了对话、聚焦了输入框，然后**主动停下**，回了一句"发消息给第三方要确认，请确认"。策略不是写在文档里好看的，是真会拦。

## 那道 -10000 的门：它怎么认出"是不是 OpenAI"

![门卫小猎犬用放大镜检查访客举起的 TEAM ID 工牌，旁边是通过与伪造两块牌子](https://img.leeguoo.com/media/3e9f4c74-bdda-4ca6-88a0-913852c21b28/authgate.png)

我一度想脱离 Codex、自己直接调它的 MCP。握手和 `tools/list` 都通，但一调真实动作，service 回了一句：

```
Computer Use server error -10000: Sender process is not authenticated
```

这道门就是它的核心防线：**只让 OpenAI 自己签名的 App 驱动**。我把校验逻辑扒到了汇编层，整条链是这样的：

**① 取对端身份，内核级、不可伪造。** `getsockopt(fd, …, LOCAL_PEERTOKEN)` 从 socket 拿对端的 audit token，再 `audit_token_to_pid` 换成 pid。audit token 由内核经 socket 提供，调用方没法靠"谎报 pid"冒充。

**② 穿透到 responsible 进程。** 直连的是个 CLI 助手（`com.openai.sky.CUAService.cli`，它本身不在白名单）。所以 service 会 `dlopen` + `dlsym` 一个私有 API，去解析"真正为这个助手负责的 App"，也就是 Codex / ChatGPT / Atlas。对应的键叫 `senderParentResponsibleIdentity`。这一步破掉了"我自己写个壳把助手包起来"的招。

**③ 取内核背书的代码对象。** 拿 audit token 调 `SecCodeCopyGuestWithAttributes`（call site 在 `0x10012b5bc` 一带），得到一个由系统代码签名子系统验证过的 SecCode。

**④ 读签名信息。** `SecCodeCopySigningInformation`（`0x10012a2cc`）之后，取两个字段：`kSecCodeInfoTeamIdentifier`（Apple 团队 ID）和 `kSecCodeInfoIdentifier`（bundle / 签名标识）。

**⑤ 比对。** 团队 ID 必须等于 `2DC432GLL2`（OpenAI 的开发者团队），bundle id 必须落在白名单里：`com.openai.codex`（含 alpha/beta/dev/nightly）、`com.openai.chat`、`com.openai.atlas`、`com.openai.sky.*`。命中放行，否则就是那句 -10000。

这道门为什么结实，值得单独说，因为它是一份不错的"怎么给 IPC 服务做调用方鉴权"的范本：

- audit token 来自内核，不是调用方发来的数据，冒充不了。
- SecCode 的签名信息由系统验证，未签名 / ad-hoc / 重签的二进制拿不出团队 ID `2DC432GLL2`。
- responsible 进程解析，让"套个壳"没用。
- 真正不可伪造的锚点是那个团队 ID。要伪造它，得有 OpenAI 真实的 Apple 开发者签名证书，那只有 Apple 发给 OpenAI。

一个实现上的小观察：它是读出 team + identifier 再做字符串比对，而不是用 `SecCodeCheckValidityWithErrors` 配一条 designated requirement 去匹配。因为 SecCode 基于 audit token、内核背书，这样也够可靠；团队 ID 那步才是真正的信任锚。更教科书的写法是补一条 requirement（`anchor apple generic and certificate leaf[subject.OU]="2DC432GLL2"`），但现有实现已经够硬了。

顺带说清楚：越过这道门，技术上"有办法"（把校验 NOP 掉、用 dlsym 挂钩让它恒返回 true、伪造签名），但那是在破一个厂商在专有软件上的访问控制，让它做设计上拒绝的事。这跟在自己机器上做学习性逆向是两码事，我没做，也不会做。

## 我照着写了一个，叫 opencua

![两只小猎犬并排，左边是成品、右边是手绘复刻版](https://img.leeguoo.com/media/465eb231-40d9-4a44-9f9e-54c025c152fd/clone.png)

拆到这，我想验证一件事：这套东西的核心，是不是用公开的 macOS API 就能复现。于是照着理解，用大概 600 行 Swift 写了个 clean-room 版本，叫 opencua：同样的无障碍树 + 截图 + CGEvent，零 OpenAI 代码，用我自己的签名。

在简单原生 App 上它几乎 1:1。我让它对 TextEdit 取状态，产出的树跟官方那次逐行对得上：

| | 官方 Codex | 我的 opencua |
|---|---|---|
| 根节点 | `0 standard window Untitled` | `0 standard window "Untitled 3"` |
| 文本区 | `2 text entry area (settable, string) Value: …` | `2 text entry area (settable) value=…` |
| 焦点 | `The focused UI element is 2` | `focused element index = 2` |

截图、点击、打字也都通了：我用它给 TextEdit 打了段带 `«»` 的文字（非 ASCII 也能注入），又点了一下 bold 复选框，回读确认值从 0 变成 1。观察 → 动作 → 再观察这个闭环，跑通了。

拆的过程里，有两条逆向结论被现实当场反证。一是我对 Chrome 取状态，窗口数返回 0、主窗口返回的是 App 自己，正是 Chromium 不点亮 `AXManualAccessibility` 就不暴露树。二是有一阵子对哪个 App 取状态都返回 0 个窗口，查了半天发现机器锁屏了：锁屏下 macOS 对无障碍隐藏全部窗口。这恰好解释了它为什么要带 `CUALockScreenGuardian`。

然后是真实世界的墙。我让 opencua 去操作微信：搜联系人、发消息。搜索框能聚焦、字能打进去，但搜索结果是一排虚拟化单元格，名字在渲染前根本不进无障碍，我的序列化器只抓到一堆空 `virtual_cell`，而官方版能稳定读出联系人名。差距就在这。

这次实测反而印证了拆解时的判断：这套东西的护城河不在算法。核心几百行就能复现，真正难的是那 20% 不起眼的生产级打磨：虚拟化列表、焦点管理、时序重试、各家自绘控件的特判。原型磨不出来，原版是这块磨了很久。

## 拆完之后我记住的几件事

如果要照着做一个自己的 macOS computer use，这几条是我会抄的：

- **无障碍树优先，截图兜底**，每个动作双寻址（编号 / 像素）。这是"点得准"的根。
- **有状态的双进程**：短命的前端 + 常驻的引擎。回合间保活树状态，是增量 diff 和稳定编号的前提。
- **树按增量 diff 发**：首次全量，之后只发差异。长任务的 token 成本，分水岭在这。
- **给模型的树用纯文本 + 行首编号 + Tab 缩进**，把"能不能改"编进括号里。
- **`AXManualAccessibility` 点亮 Chromium / Electron**，否则浏览器和一堆 Electron App 只能截图。
- **护栏是生产和 demo 的分界**：焦点防抢占、防锁屏、捕获前高亮、每 App 授权。
- **鉴权按调用方代码签名**：audit token 取身份 + SecCode 读团队 ID + responsible 进程解析。团队 ID 是不可伪造的锚点。

它"最好"不是因为模型更强，是工程把 accessibility 这套 API 吃透了。截图只是兜底，真正的载体是一棵可 diff、给模型读的无障碍树；再用焦点、锁屏、高亮、分级确认这些不起眼的东西把可靠性和信任撑起来。护城河在这些地方，不在 prompt。
