# 02 · 入口点与运行形态

> 目标：认清 Hermes 的 5 类入口，理解它们如何复用同一个 `AIAgent` 内核。

---

## 1. 总览：一个内核，多个外壳

```text
                     ┌────────────────────────────────┐
   hermes (CLI) ──────┤                                │
   hermes gateway ────┤                                │
   hermes --tui ──────┤         AIAgent                │
   hermes serve ──────┤  (run_agent.py + agent/turn_*) │
   acp_adapter ───────┤                                │
   batch_runner ──────┤                                │
   Python library ────┤                                │
                     └────────────────────────────────┘
```

入口层的职责边界是固定的：**解析参数 → 准备 profile/配置 → 构建或复用 AIAgent → 渲染结果**。
agent 行为**绝不**下沉到入口层，也绝不从 agent 上浮到渲染层。

---

## 2. CLI 入口（`cli.py`）

### 2.1 门面结构

[`cli.py`](../cli.py:1) 持有 `HermesCLI`（REPL 循环、配置、slash 派发），行为分布在 mixins：

| Mixin | 职责 |
|---|---|
| [`hermes_cli/cli_commands_mixin.py`](../hermes_cli/cli_commands_mixin.py:1) | slash 命令处理 |
| [`hermes_cli/cli_stream_mixin.py`](../hermes_cli/cli_stream_mixin.py:1) | 流式输出 |
| [`hermes_cli/cli_status_bar_mixin.py`](../hermes_cli/cli_status_bar_mixin.py:1) | 状态栏 |
| [`hermes_cli/cli_tui_mixin.py`](../hermes_cli/cli_tui_mixin.py:1) | widgets、键绑定、面板 |
| [`hermes_cli/cli_tui_runtime_mixin.py`](../hermes_cli/cli_tui_runtime_mixin.py:1) | run-loop 相位（输入派发、启动、信号、关闭） |
| [`hermes_cli/cli_init_mixin.py`](../hermes_cli/cli_init_mixin.py:1) | `__init__` 相位 |
| [`hermes_cli/cli_billing_mixin.py`](../hermes_cli/cli_billing_mixin.py:1) | 计费 |

来源：[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:7)

模块级 helper 在主题兄弟模块里，由 `cli.py` 重新导出（保持 `cli.<name>` 是补丁缝）：
[`cli_config_load.py`](../hermes_cli/cli_config_load.py:1)（默认值 + YAML 合并）、
[`cli_render.py`](../hermes_cli/cli_render.py:1)（ANSI/skin 颜色）、
[`cli_terminal_input.py`](../hermes_cli/cli_terminal_input.py:1)、
[`cli_shutdown.py`](../hermes_cli/cli_shutdown.py:1)、
[`cli_single_query.py`](../hermes_cli/cli_single_query.py:1)。

### 2.2 技术栈

- **Rich**：渲染 banner 与面板
- **prompt_toolkit**：输入与自动补全
- **KawaiiSpinner**（[`agent/display.py`](../agent/display.py:1)）：API 调用动画与 `┊` 活动流

### 2.3 Slash 命令派发（无一例外不用 `elif` 阶梯）

[`hermes_cli/commands.py`](../hermes_cli/commands.py:1) 的 `COMMAND_REGISTRY`（`CommandDef` 列表）
是**单一事实来源**，所有派生物都从它生成：CLI 派发、网关已知命令、help 文本、Telegram BotCommand 菜单、
Slack 子命令表、自动补全、分类帮助。

```python
# 解析 → 派发的两步
name = resolve_command(raw)                 # 规范化（含别名）
method, pass_arg = HermesCLI._SLASH_DISPATCH[canonical]  # 显式表
# 否则回退到按命名约定的 _handle_<name>_command 方法
```

来源：[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:31)

`CommandDef` 字段：`name`（不带斜杠）、`description`、`category`、`aliases`、`args_hint`、
`cli_only`、`gateway_only`、`gateway_config_gate`。

### 2.4 添加一个命令的四步

1. 在 `COMMAND_REGISTRY` 加 `CommandDef(...)`
2. 在对应 `cli_*_mixin.py` 加 `_handle_mycommand_command(self, cmd_original)`
   （或显式 `_SLASH_DISPATCH` 条目）
3. 网关侧在 `gateway/slash_commands_*.py` 加处理器，并在
   [`gateway/run_busy.py`](../gateway/run_busy.py:1) 的 `_IDLE_COMMANDS` / `_PLAIN_COMMANDS` 中登记
4. 持久化设置走 [`cli.py`](../cli.py:1) 的 `save_config_value()`

**改系统提示状态的命令默认延迟失效（deferred invalidation），用 `--now` 立即生效**（缓存铁律的推论）。

---

## 3. 网关入口（`gateway/run.py`）

[`gateway/run.py`](../gateway/run.py:1) 是门面，相位在 `run_*.py`：
startup、adapters、inbound、turn、busy、goals、notifications、shutdown；
会话在 `session*.py`；slash 处理器在 `slash_commands_*.py` mixins；授权在
[`gateway/authz_mixin.py`](../gateway/authz_mixin.py:1)；平台适配器在 `platforms/<name>.py`，
共同基类 [`gateway/platforms/base.py`](../gateway/platforms/base.py:1)。

提供两个主要符号：

- `start_gateway()` — 启动所有已配置适配器
- `GatewayRunner` — 生命周期管理

运行方式：`python -m gateway.run` 或 `python cli.py --gateway`。

**关键差异**：网关直接读用户 YAML **原始文件**（`run.py` + `config.py`），**不**经过 `DEFAULT_CONFIG`。
所以「CLI 能看到某 key 但网关看不到」通常意味着你用错了 loader
（[`gateway/AGENTS.md`](../gateway/AGENTS.md:12)）。

每个适配器自己挑一个基础 toolset（如 Telegram → `"messaging"`）。

详见 [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md)。

---

## 4. TUI 入口（`hermes --tui` / `HERMES_TUI=1`）

```text
hermes --tui
  └─ Node (Ink)  ──stdio JSON-RPC──  Python (tui_gateway)
       │                                  └─ AIAgent + tools + sessions
       └─ 渲染 transcript、composer、prompts、activity
```

来源：[`tui_gateway/AGENTS.md`](../tui_gateway/AGENTS.md:9)

- **TypeScript 拥有屏幕**，**Python 拥有会话、工具、模型调用、slash 逻辑**。
  绝不把 agent 行为搬进渲染层。
- 传输是 **stdio 上的换行分隔 JSON-RPC**，点对点：
  - client→server：方法调用
  - server→client：**request**（agent 反问用户：approval / clarify / sudo / secret / vault.*）
  - server→client：**event** 通知
- 门面 [`tui_gateway/server.py`](../tui_gateway/server.py:1)，方法在 `methods_*.py` 兄弟里。

**同一个 `tui_gateway` 后端还服务于桌面应用与 dashboard `/chat`** —— 改这里影响三个消费方。

---

## 5. 桌面入口（`hermes serve`）

桌面应用是**自己独立**的原生聊天面，不嵌入浏览器 dashboard、也不嵌入 TUI。
三方各司其职（[`apps/desktop/AGENTS.md`](../apps/desktop/AGENTS.md:13)）：

- **Electron** 拥有机器：进程生命周期、原生文件系统/git/窗口、安装/更新、窄而类型化的能力桥
- **Renderer** 拥有体验：导航、呈现、临时交互状态
- **Agent 后端** 拥有工作：会话、工具、模型调用、流式

`hermes serve` 是桌面 spawn 出来的无头控制平面后端，随应用退出而退出（设计如此）。
而消息网关（`gateway run`）**独立存活**：serve 后端的 `/api/gateway/*` 以 detached 方式 spawn 它，
`before-quit` 的 SIGTERM 到不了它，所以机器人继续运行（[`gateway/AGENTS.md`](../gateway/AGENTS.md:78)）。

---

## 6. Dashboard 入口（`hermes dashboard`）

Dashboard **内嵌真实的 `hermes --tui`**，不是重写（[`web/AGENTS.md`](../web/AGENTS.md:7)）：

- [`hermes_cli/pty_bridge.py`](../hermes_cli/pty_bridge.py:1) + `web_server.py` 中的 `@app.websocket("/api/pty")`
- 前端 [`web/src/pages/ChatPage.tsx`](../web/src/pages/ChatPage.tsx:1) 挂载 xterm.js + WebGL 渲染器
- 服务端通过 `ptyprocess` spawn「`hermes --tui` 会 spawn 的东西」（POSIX PTY；WSL 可用，原生 Windows 不行）
- 帧是原始 PTY 字节；resize 以 `\x1b[RESIZE:<cols>;<rows>]` 传输，服务端拦截后用 `TIOCSWINSZ` 应用

**不要在 React 里重实现主聊天体验**——加到 Ink 里会自动出现在这里。

`dashboard` 与 `serve` 共享 `cmd_dashboard` / `start_server`，但彼此独立（谁也不启动谁）；
`serve` 是 `headless_backend=True`，只暴露 JSON-RPC/WS/API。

---

## 7. ACP 入口（`acp_adapter/`）

把 Hermes 作为编辑器原生 agent 暴露，走 stdio/JSON-RPC，服务于 VS Code / Zed / JetBrains。
相关文档：[`website/docs/developer-guide/acp-internals.md`](../website/docs/developer-guide/acp-internals.md:1)。

---

## 8. 其它入口

| 入口 | 文件 | 用途 |
|---|---|---|
| 批量轨迹生成 | [`batch_runner.py`](../batch_runner.py:1) | 训练数据生成 |
| Python 库 | `from run_agent import AIAgent` | 嵌入到自己的程序 |
| mini SWE runner | [`mini_swe_runner.py`](../mini_swe_runner.py:1) | 轻量 SWE 运行器 |
| MCP serve | [`mcp_serve.py`](../mcp_serve.py:1) | 把 Hermes 自身作为 MCP server |

---

## 9. 命令行速览

```bash
hermes              # 交互式 CLI，开始对话
hermes model        # 选择 LLM provider 与 model
hermes tools        # 配置启用哪些工具
hermes config set   # 设置单个配置值
hermes config get   # 打印单个配置值
hermes gateway      # 启动消息网关
hermes setup        # 完整 setup 向导
hermes update       # 更新到最新版
hermes doctor       # 诊断
hermes -p <name>    # 指定 profile
```

来源：[`README.md`](../README.md:109)

---

## 10. 本篇小结与下一步

- 入口层只做四件事：**解析 → 准备 → 构建 AIAgent → 渲染**。
- CLI 有 mixins + `COMMAND_REGISTRY`；网关有 `run_*.py` 相位 + 双消息守卫。
- TUI/Desktop/Dashboard 共享同一个 `tui_gateway` JSON-RPC 后端。
- `serve`（随应用退出）与 `gateway run`（独立存活）是两个不同的生命周期。

下一步 → [`03-agent-core.md`](03-agent-core.md)：进入 `AIAgent` 与 turn loop 的正中央。
