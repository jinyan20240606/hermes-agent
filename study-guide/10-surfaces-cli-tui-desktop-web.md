# 10 · 四个前端面：CLI / TUI / Desktop / Web

> 目标：理解四个界面如何共享同一个后端，以及各自的技术栈与职责边界。

---

## 1. 全景对照表

| 面 | 命令 | 前端技术 | 后端 | 说明 |
|---|---|---|---|---|
| **CLI** | `hermes` | prompt_toolkit + Rich | 进程内 `HermesCLI` + `AIAgent` | 经典 REPL |
| **TUI** | `hermes --tui` | Node/Ink（TS） | 独立 `tui_gateway` 进程（Python，stdio JSON-RPC） | 完全替代经典 CLI |
| **Desktop** | `hermes serve` | Electron + React | 同一个 `tui_gateway`（经 WebSocket） | 自己的原生渲染 |
| **Web** | `hermes dashboard` | React + xterm.js | PTY 里跑**真实的 `hermes --tui`** | 嵌入式，非重写 |

> **重要**：TUI / Desktop / Dashboard 共享 `tui_gateway`——改它有**三个消费者**。

---

## 2. CLI 面

技术栈（[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:18)）：
- **Rich** 渲染 banner/面板
- **prompt_toolkit** 处理输入与自动补全
- **KawaiiSpinner**（[`agent/display.py`](../agent/display.py:1)）动画与 `┊` 活动流

### 2.1 交互规则

- 所有交互式菜单选择器用 **curses**（[`hermes_cli/curses_ui.py`](../hermes_cli/curses_ui.py:1)；
  范例 [`hermes_cli/tools_config.py`](../hermes_cli/tools_config.py:1)）
- **绝不在 spinner/display 代码里输出 `\033[K`**（ANSI erase-to-EOL）——
  它会在 prompt_toolkit 的 `patch_stdout` 下泄漏成字面量 `?[K`。改用空格填充：
  `f"\r{line}{' ' * pad}"`
- 包装型 CLI 通过 [`cli_tui_mixin.py`](../hermes_cli/cli_tui_mixin.py:1) 的保护 hooks 扩展，
  **不**通过 override `run()`

### 2.2 配置系统（三个 loader，别用错）

来自 [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:99)：

| Loader | 使用者 | 是否合并 DEFAULT_CONFIG |
|---|---|---|
| `load_cli_config()` | CLI（`cli.py`） | 是 |
| `load_config()` | `hermes tools/setup`、大多数子命令 | 是 |
| `load_user_config_effective()` | 网关运行时、TUI gateway、cron、`hermes send`、doctor | **否**（用户文件 + 托管 overlay + `${VAR}` 展开 + model-key canon） |

> 「CLI 看到某 key 而网关看不到（或反之）」= 你用错了 loader，检查 `DEFAULT_CONFIG` 覆盖。

**配置 yaml 的写入只走一个缝**：`hermes_cli.config.atomic_config_write`
（拒绝「因遗漏而删除」）或显式的 `atomic_config_replace` 全状态路径。
**绝不**对配置路径调 `yaml.dump` / `yaml.safe_dump`——CI lint 会拒绝。

### 2.3 Skin 引擎

[`hermes_cli/skin_engine.py`](../hermes_cli/skin_engine.py:1)：skin 是**纯数据**（`SkinConfig`），
新增一个不需要改代码。
- `init_skin_from_config()` 在启动时读 `display.skin`
- `get_active_skin()`（带缓存）、`set_active_skin(name)`（`/skin`）
- `load_skin(name)`：用户 `~/.hermes/skins/*.yaml` → 内置 → default（缺值从 `default` 继承）
- 内置：`default`、`ares`、`mono`、`slate`

---

## 3. TUI 面（`tui_gateway` + `ui-tui`）

### 3.1 进程模型

```text
hermes --tui
  └─ Node (Ink)  ──stdio JSON-RPC──  Python (tui_gateway)
       │                                  └─ AIAgent + tools + sessions
       └─ 渲染 transcript、composer、prompts、activity
```

**TypeScript 拥有屏幕，Python 拥有 agent。** 绝不把 agent 行为搬进渲染层。

### 3.2 传输：三种帧

换行分隔 JSON-RPC，**点对点**：

| 方向 | 类型 | 用途 |
|---|---|---|
| client→server | method call | 客户端调方法 |
| server→client | **request** | agent 反问用户：`approval`、`clarify`、`sudo`、`secret`、`vault.*`、`connection`、desktop read/act bridges |
| server→client | `event` | 通知 |

- [`tui_gateway/server.py`](../tui_gateway/server.py:1) 是门面，方法在 `methods_*.py` 兄弟里
- `send()` 阻塞 agent 线程直到同 `srq-<n>` id 的响应帧到达
- `cancel*` 用 `request.cancel` 事件撤回
- `open_requests(sid)` 供 `session.resume` / `session.events.since` 重放，
  让重连客户端重新渲染仍打开的问题
- 客户端每连接说一次它能应答它们（`client.capabilities {server_requests: true}`，
  由共享 channel 在 `gateway.ready` 时发送）；没说过的是比 server→client requests 更老的 app build，
  `send()` 对它**快速失败**而不是让 agent 干等到超时

### 3.3 Wire 契约：Python 声明，TypeScript 生成

[`tui_gateway/contracts/`](../tui_gateway/contracts/) 是关键设计：

- 每个方法有 `Params` + `Result` 模型
- 每个 server→client request 有 `Params` + `Result`
- 每个事件有 `Payload`
- 每个都是**一个 Pydantic 类**，默认 `extra="forbid"`（约定由生产者拥有的 dict 用 `OpenModel`）
- `register_method` 在 import 时拒绝未声明的名字
- 派发器拒绝未知参数 key（`4000` + key path）
- `HERMES_TEST_ISOLATION=1` 下 handler 结果或 payload 不匹配模型会抛 `ContractViolation`（生产只记录）

生成物：
- [`apps/shared/src/gateway-contract.generated.ts`](../apps/shared/src/gateway-contract.generated.ts)
  （`RpcMethods`、`ServerRequestMap`、`BackendGatewayEventMap` + 每个值形状）
- `gateway-contract.openrpc.json`
- 由 [`scripts/gen_gateway_contracts.py`](../scripts/gen_gateway_contracts.py:1) 渲染
- `tests/tui_gateway/contracts/test_generated.py` 在它们过期时失败

**循环**：改模型 → 重新生成 → `tsc` 会向每个消费者显示字段移动了哪里。

### 3.4 关键界面映射

| 界面 | Ink 组件 | Gateway 方法 / 事件 |
|---|---|---|
| 聊天流式 | `app.tsx` + `messageLine.tsx` | `prompt.submit` → `message.delta` / `message.complete` |
| 工具活动 | `thinking.tsx` | `tool.start` / `tool.generating` / `tool.complete` |
| 审批 | `prompts.tsx` | server→client request `approval` → response `{choice}` |
| Clarify / sudo / secret | `prompts.tsx`, `maskedPrompt.tsx` | server→client requests |
| 会话选择器 | `sessionPicker.tsx` | `session.list` / `session.resume` |
| Slash 命令 | 本地 handler + fallthrough | `slash.exec` → `_SlashWorker`；`command.dispatch` |
| 补全 | `useCompletion` hook | `complete.slash`、`complete.path` |
| 主题 | `theme.ts` + `branding.tsx` | `gateway.ready` 携带 skin 数据 |

### 3.5 Slash 命令流

1. 内置客户端命令（`/help`、`/quit`、`/clear`、`/resume`、`/copy`、`/paste` ...）在 `app.tsx` 本地处理
2. 其它全部 → `slash.exec`，在持久 `_SlashWorker` 子进程中运行 →
   `command.dispatch` fallback，网关把它解析成 skill / alias / exec 指令
   （skill 命令解析成 `{type: "skill", message}`，作为普通 prompt 提交）

`commands.catalog` 与 `complete.slash` 已包含内置、用户 `quick_commands`、以及 skill 派生命令——
客户端不需要新的 RPC 就能看到 skills。

### 3.6 开发命令

```bash
cd ui-tui
npm install       # 首次
npm run dev       # watch 模式
npm start         # 生产
npm run build     # 完整构建
npm run typecheck # tsc --noEmit
npm run lint      # eslint
npm run fmt       # prettier
npm test          # vitest
```

---

## 4. Desktop 面

### 4.1 三方职责

- **Electron** 拥有机器：进程生命周期、原生文件系统/git/窗口、安装/更新、窄而类型化的能力桥
- **Renderer** 拥有体验：导航、呈现、临时交互状态
- **Agent 后端** 拥有工作：会话、工具、模型调用、流式

**保持缝干净**：renderer 绝不直接够 Node/Electron；
原生能力通过**刻意设计的能力**到达，不是通用逃生舱；agent 行为在 gateway 后面，绝不在 React 里重实现。

### 4.2 按权威决定状态归属

第一条问题永远是「**谁被允许对这块状态是正确的**」，而不是「存在哪里方便」：

- **后端**对「任何其它 Hermes 界面也能改的」事物权威 → renderer 的副本当作缓存
- **Electron** 对机器与运行时事实权威
- **Renderer** 只拥有纯属本窗口呈现的东西

推论：
- 共享 renderer 状态住在**feature 拥有的小 store** 里
- 请求形状、想要失效的服务器数据住在 **query 层**
- 短命交互细节留在组件里
- 不能触发重绘的热协调留在 **ref** 里

**持久化状态必须在自己的 key 里声明作用域**（全局？连接？profile？存储会话？项目？窗口？）——
作用域错了就是一个 profile 的设置渗透到另一个。

### 4.3 上下文切换是「re-home」，不是「reboot」

- 连接/模式 apply 是 **SOFT re-home**（shell 保留，gateway-bound stores 显式清空，然后重连）
- 运行时 `HERMES_HOME` 变化是 **HARD re-home**（reload）
- 活 profile 切换在后台 profile 继续流式时合并列表

换过之后，active socket、profile、connection atoms **必须一致**。

### 4.4 兼容性：不要在兼容性上携带过去

Desktop 与其运行时**按不同时钟更新**，所以一次改动可能遇到更老的后端：
保留当前 feature、把 fallback 收窄并绑到已识别的更老 runtime、用测试覆盖它。
**一个悄悄降级它本该保护的 feature 的 fallback，比它替代的崩溃更糟。**

### 4.5 尊重使用者的注意力

- 绝不因为后台**发生了**什么而导航、移动焦点、打开界面。**提供，不要劫持。**
- 加载周边状态是**不同体验**：empty、loading、reconnecting、degraded/stale、exhausted-recovery
  各需自己的诚实文案与出路
- 键盘所有权跟随焦点；一个 cancel 手势只做一件事
- 昂贵、有状态的界面（终端、活工具）隐藏时**保持存活**。可见性不是生命周期。

### 4.6 guest 内容绝不自己打开东西

artifact iframe 与 preview `<webview>` 绝不自行驱动 OS 浏览器（GHSA-9f4c-93c8-jc8g）：
`setWindowOpenHandler` 拒绝一切、webview 没有 `allowpopups`、
guest 的 `target="_blank"` 链接只能通过 `persist:hermes-preview` guest preload 的可信点击桥到达
`hermes:openExternal`，且**只允许 `http:`/`https:`**。

---

## 5. Web 面（Dashboard）

### 5.1 内嵌真实 TUI

[`hermes_cli/pty_bridge.py`](../hermes_cli/pty_bridge.py:1) +
[`web_server.py`](../hermes_cli/web_server.py:1) 的 `@app.websocket("/api/pty")`：

- [`web/src/pages/ChatPage.tsx`](../web/src/pages/ChatPage.tsx:1) 挂载 xterm.js `Terminal`
  + WebGL 渲染器 + `@xterm/addon-fit` + `@xterm/addon-unicode11`
- `/api/pty?token=…` 升级为 WebSocket；认证用与 REST 相同的临时 `_SESSION_TOKEN`，
  作为 query param 传递（浏览器无法在 WS upgrade 上设 `Authorization`）
- 服务端通过 `ptyprocess` spawn「`hermes --tui` 会 spawn 的东西」（POSIX PTY，WSL 可用，原生 Windows 不行）
- 帧是原始 PTY 字节；resize 以 `\x1b[RESIZE:<cols>;<rows>]` 传输，服务端用 `TIOCSWINSZ` 应用

> **不要在 React 里重实现主聊天体验。** transcript、composer、PTY 终端属于内嵌 TUI；
> 加到 Ink 的东西会自动出现在这里。若你在给 dashboard 重建 transcript 或 composer——停下，去扩展 Ink。

### 5.2 什么可以做成结构化 React

围绕 TUI 的结构化 React UI **在不构成第二个聊天面时**是可以的：
侧边栏 widget、inspector、摘要、状态面板（`ChatSidebar`、`ModelPickerDialog`、`ToolCall`）。
保持它们的状态独立于 PTY 子进程的会话，并**非破坏性地**呈现失败，让终端窗格继续工作。

### 5.3 dashboard vs serve

共享 `cmd_dashboard` / `start_server`，但**独立**——谁都不启动谁。
`serve` 是桌面 spawn 的无头后端（`headless_backend=True`：`cmd_dashboard` 跳过 `_build_web_ui`，
导出 `HERMES_SERVE_HEADLESS=1` 让 `mount_spa()` 禁用 SPA——只可达 JSON-RPC/WS/API）。

### 5.4 规则

- **认证**：每条新 REST 路由和 WS 端点用同一个 session token；绝不第二套方案
- **Routers 一文件一面**：新面是新的 `web_routers/<surface>.py`，不是长大的 `web_server.py`
- **测试**：Python 放 `tests/hermes_cli/`；JS 放 `web/` 的 vitest 套件

---

## 6. i18n 在各界面的分布

- `.tui.yaml` / `.desktop.yaml` pack 文件对核心而言是不透明的（只做 parse/flatten/serve）
- 对 `tui` 界面，bundled `locales/<lang>.tui.yaml` 是 `surface_catalog` 所服务内容的**底层**
  （TUI 在 TS 里只发英文）
- bundled id 的本地语言名在 [`agent/i18n_languages.py`](../agent/i18n_languages.py:1)，
  且必须与 [`apps/shared/src/i18n.ts`](../apps/shared/src/i18n.ts:1) 一致

---

## 7. Desktop 的 `src/AGENTS.md` 补充点

`apps/desktop/src/AGENTS.md` 覆盖后端契约、slash palette 策展、Bot Mode。
桌面还有自己的设计契约 [`DESIGN.md`](../apps/desktop/DESIGN.md:1) 与
工程长文 [`ENGINEERING.md`](../apps/desktop/ENGINEERING.md:1)。

---

## 8. 本篇小结与下一步

- 四面的**共享点**是 `tui_gateway`（TUI/Desktop/Dashboard 三消费者）。
- Dashboard **内嵌真实 TUI**，不要重写聊天。
- Desktop 的核心原则：**按权威放状态**、**re-home 而非 reboot**、**提供而非劫持**。
- 不要读源码做测试断言（根规则）。

下一步 → [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md)：三大扩展体系。
