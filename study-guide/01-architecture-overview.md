# 01 · 架构总览与设计哲学

> 目标：读完这一篇，你能在白板上画出 Hermes 的分层骨架，并说清每个模块「为什么存在」。

---

## 1. Hermes 是什么

Hermes Agent 是 Nous Research 出品的个人 AI Agent。同一套 **agent core** 同时驱动：

- CLI（`hermes`，基于 prompt_toolkit 的经典 REPL）
- TUI（`hermes --tui`，Ink/Node 前端 + Python JSON-RPC 后端）
- 消息网关（`hermes gateway`，Telegram / Discord / Slack 等约 20 个平台）
- Electron 桌面应用（`hermes serve` 作为无头后端）
- Dashboard（`hermes dashboard`，内嵌真实 TUI）
- ACP 适配器（VS Code / Zed / JetBrains）

它的差异化能力：**跨会话学习**（memory + skills）、**子代理委派**、**定时任务**、
**真实终端与浏览器驱动**。而它的扩展方式是**插件与技能**，不是把核心做大。

---

## 2. 一句话架构

```text
                ┌────────────────── 入口层（Entry Points）──────────────────┐
                │  CLI      Gateway     ACP      API Server     Batch/Library │
                └───────┬──────────┬────────┬──────────┬───────────┬─────────┘
                        └──────────┴───┬────┴──────────┴───────────┘
                                       ▼
                    ┌──────────────────────────────────────────┐
                    │        AIAgent（run_agent.py 门面）        │
                    │  Prompt Builder │ Provider 解析 │ Tool 分发 │
                    │  Compression    │ 3 API Modes  │ Registry  │
                    └────────┬──────────────────────────┬────────┘
                             ▼                          ▼
                ┌─────────────────────┐     ┌────────────────────────┐
                │  Session Storage    │     │     Tool Backends       │
                │  SQLite + FTS5      │     │ Terminal(7) / Browser(5)│
                │  hermes_state.py    │     │ Web(4) / MCP / File ... │
                └─────────────────────┘     └────────────────────────┘
```

来源：[`website/docs/developer-guide/architecture.md`](../website/docs/developer-guide/architecture.md:13)

**关键洞察**：平台差异只在入口层，`AIAgent` 自身是平台无关的
（[`architecture.md`](../website/docs/developer-guide/architecture.md:264) 的 “Platform-agnostic core”）。

---

## 3. Facade + Siblings 布局（最重要的工程约定）

项目里每个曾经的「上帝文件」都被拆成：

- 一个 **facade**（门面）：只保留公共入口点 + 其它包 import 的名字
- 若干 **siblings**（兄弟模块）：`<stem>_<topic>.py`，每个负责一个主题

典型对照：

| Facade | Siblings | 职责 |
|---|---|---|
| [`run_agent.py`](../run_agent.py:1) | `agent/turn_*.py`, `agent/conversation_loop.py` | AIAgent 组装与对话循环 |
| [`cli.py`](../cli.py:1) | `hermes_cli/cli_*_mixin.py` | CLI REPL 与各类交互 |
| [`hermes_state.py`](../hermes_state.py:1) | `hermes_state_*.py` | SQLite 会话/状态库 |
| [`gateway/run.py`](../gateway/run.py:1) | `gateway/run_*.py`, `gateway/session*.py` | 网关生命周期与派发 |
| [`tools/mcp_tool.py`](../tools/mcp_tool.py:1) | `tools/mcp_tool_*.py` | MCP 客户端 |
| [`hermes_cli/kanban.py`](../hermes_cli/kanban.py:1) | `hermes_cli/kanban_*.py` | 看板 CLI |

来源：[`AGENTS.md`](../AGENTS.md:1) § Facade + siblings layout

三条必须记住的潜规则：

1. **按主题找代码**：用 `grep -rn "def name" <dir>/<stem>_*.py`，不要通读 facade。
2. **siblings 延迟 import facade**：在函数体内 `from <facade> import name`，绝不在模块级形成循环。
3. **在哪里被读，就在哪里打补丁（patch）**：如果 sibling 在函数内 `from run_agent import X`，
   那么补丁要打在 `run_agent` 上；打在定义模块上会静默失效。

---

## 4. 目录职责表（Load-bearing 入口）

| 路径 | 职责 |
|---|---|
| [`run_agent.py`](../run_agent.py:1) | AIAgent 门面；turn loop 在 `agent/turn_*.py` |
| [`model_tools.py`](../model_tools.py:1) | 工具编排：`discover_builtin_tools()`、`handle_function_call()` |
| [`toolsets.py`](../toolsets.py:1) | `TOOLSETS` 字典、`_HERMES_CORE_TOOLS` |
| [`cli.py`](../cli.py:1) | `HermesCLI`（REPL、slash 派发）+ mixins |
| [`hermes_state.py`](../hermes_state.py:1) | SessionDB 门面；`hermes_state_*.py` 兄弟 |
| [`hermes_constants.py`](../hermes_constants.py:1) | `get_hermes_home()`、`display_hermes_home()` — profile 感知路径 |
| [`agent/`](../agent/) | turn 相位、providers、memory、compression、prompt builder |
| [`hermes_cli/`](../hermes_cli/) | CLI 子命令、setup、config、插件加载、更新器、web routers |
| [`tools/`](../tools/) | 工具实现 + `environments/` 后端 |
| [`gateway/`](../gateway/) | `run.py` 门面 + 平台适配 `platforms/` |
| [`plugins/`](../plugins/) | memory/、context_engine/、model-providers/、kanban/ 等 |
| [`skills/`](../skills/) | 内置技能；`optional-skills/` 是「已发布但未激活」 |
| [`ui-tui/`](../ui-tui/), [`tui_gateway/`](../tui_gateway/) | Ink 终端 UI + 其 Python JSON-RPC 后端 |
| [`apps/desktop/`](../apps/desktop/) | Electron 桌面应用（+ `apps/shared`） |
| [`web/`](../web/) | Dashboard SPA |
| [`cron/`](../cron/) | 定时任务调度器 |
| [`pm/`](../pm/), [`hermes_platform/`](../hermes_platform/) | 依赖/环境管理器；机器事实与可执行文件查找 |
| [`scripts/`](../scripts/) | check、run_tests.sh、code_health、ci |
| [`tests/`](../tests/) | Pytest 套件，镜像源码树 |

来源：[`AGENTS.md`](../AGENTS.md:1) § Project Structure

---

## 5. 六大设计原则

来自 [`architecture.md`](../website/docs/developer-guide/architecture.md:257)：

| 原则 | 实践含义 |
|---|---|
| **Prompt 稳定性** | System prompt 在会话期间不变。除显式用户操作（`/model`）外，不做任何破坏缓存的改动 |
| **可观测执行** | 每次工具调用对用户可见（CLI 走 spinner，网关走聊天消息） |
| **可中断** | API 调用与工具执行都可以被用户输入或信号中途取消 |
| **平台无关内核** | 一个 `AIAgent` 服务 CLI/gateway/ACP/batch/api-server；差异在入口层 |
| **松耦合** | MCP、插件、memory provider、RL 环境都走注册表 + `check_fn` 门控，不是硬依赖 |
| **Profile 隔离** | 每个 profile（`hermes -p <name>`）拥有独立的 HERMES_HOME、配置、记忆、会话、网关 PID |

---

## 6. 依赖链：为什么工具能「自注册」

```text
tools/registry.py        (零依赖 — 被所有工具文件 import)
       ↑
tools/*.py               (每个文件 import 时调用 registry.register())
       ↑
model_tools.py           (import registry + 触发工具发现)
       ↑
run_agent.py, cli.py, batch_runner.py, environments/
```

来源：[`architecture.md`](../website/docs/developer-guide/architecture.md:268)

因为注册发生在 **import 时**、且在创建任何 agent 实例之前，所以任何带顶层
`registry.register()` 的 `tools/*.py` 都会被自动发现——没有手工 import 清单要维护。

---

## 7. 一次请求的完整数据流（三种入口）

### CLI 会话

```text
用户输入 → HermesCLI.process_input()
  → AIAgent.run_conversation()
    → prompt_builder.build_system_prompt()
    → runtime_provider.resolve_runtime_provider()
    → API 调用（chat_completions / codex_responses / anthropic_messages）
    → 有 tool_calls？ → model_tools.handle_function_call() → 循环
    → 最终响应 → 显示 → 写入 SessionDB
```

### 网关消息

```text
平台事件 → Adapter.on_message() → MessageEvent
  → GatewayRunner._handle_message()
    → 授权用户 → 解析 session key → 建 AIAgent（带历史）
    → AIAgent.run_conversation() → 通过 adapter 回投递
```

### Cron 任务

```text
Scheduler tick → 从 jobs.json 载入到期任务
  → 建全新 AIAgent（无历史）→ 注入附加 skills 作为上下文
  → 跑 job prompt → 投递到目标平台 → 更新 job 状态与 next_run
```

来源：[`architecture.md`](../website/docs/developer-guide/architecture.md:139)

> 注意 cron 会话默认 `skip_memory=True`——记忆 provider 在 cron 中故意不运行
> （[`agent/AGENTS.md`](../agent/AGENTS.md:127)、[`cron/AGENTS.md`](../cron/AGENTS.md:87)）。

---

## 8. 规模感知（帮你建立「广度」预期）

| 维度 | 数量级 |
|---|---|
| `tools/*.py` | ~274 个文件（含大量 `_*` 兄弟模块） |
| 注册工具 | 70+ |
| Toolsets | ~28 个具名工具集（键会变，勿在测试里断言清单） |
| 终端后端 | 7 种（local, docker, ssh, modal, daytona, singularity, 及 Vercel Sandbox） |
| 浏览器后端 | 5 种 |
| API 模式 | 3 种（"chat_completions" / "codex_responses" / "anthropic_messages"） |
| 平台适配器 | 内置 ~8 + 插件 ~20 |
| 测试 | 约 2.5 万个、约 1250 个文件 |

---

## 9. 本篇小结与下一步

- 记住 **两条铁律**（缓存神圣 / 窄腰）。
- 记住 **facade + siblings** 与「在哪里读就在哪里 patch」。
- 记住 **依赖链** 决定了工具自注册的时机。

下一步 → [`02-entrypoints.md`](02-entrypoints.md)：认清 5 类运行形态，理解它们如何复用同一个内核。
