# 01 · 架构总览与设计哲学

> **读法**：这一篇是全套材料的「地基」。如果你从没接触过 LLM agent，请按顺序读：
> **§0 前置概念**（补断层）→ **§1 它是什么** → **§2 分层骨架** → **§3 一次请求的完整旅行**（最重要的实操章）
> → **§4 两条铁律**（为什么这样设计）→ **§5~§10 工程细节与地图** → **§11 自检** → **§12~§13 附录**（术语表、读码命令）。
>
> 读完你应该能在白板上画出骨架，并能回答：**「我在终端里敲一句话，到屏幕上出现回答，中间发生了什么？」**

**本篇新增/加强的内容**（相对旧版）：§0 前置概念、§3.4 相位文件全表、§3.6 工具执行七步、
§3.9 失败恢复矩阵、§3.10 入口差异表、§4.1 system prompt 三层、§6.2 AST 发现机制、
§6.5 注册表 profile 分层、§7.4 profile 泄漏实例、§12 术语表、§13 读码命令。

---

## 0. 前置概念：5 个必须先打通的知识点

你写前端时最熟悉的模型是「请求 → 响应 → 存进 redux」。LLM agent 的模型**长得像，但有几处根本不同**。不先打通这几点，后面全是断层。

### 0.1 LLM API 是**无状态**的

你调一个 REST 接口，服务端记得你的 session。**LLM API 不记得**。

```
POST /v1/chat/completions
{
  "model": "claude-opus-4",
  "messages": [                      ← 整段对话历史，每次都要全量重传
    {"role": "system",    "content": "你是一个严谨的工程师..."},
    {"role": "user",      "content": "帮我修 main.py 的 bug"},
    {"role": "assistant", "content": "我先看看文件"},
    {"role": "user",      "content": "好"}
  ],
  "tools": [ ... ]                   ← 工具清单，也是每次都要全量重传
}
```

**推论**：所谓「对话记忆」根本不是模型的能力，而是**你的程序把 messages 数组攒起来，每次重新发一遍**。`AIAgent` 干的第一件事，就是维护这个数组。

前端类比：这就像你必须自己把整个 redux store 序列化后发给后端，后端才「知道」之前发生了什么。

### 0.2 Tool Calling：模型不会执行代码，只会**申请**执行

模型返回的不是「我执行了 ls」，而是一段结构化 JSON：

```json
{
  "role": "assistant",
  "content": null,
  "tool_calls": [
    {"id": "call_1", "type": "function",
     "function": {"name": "read_file", "arguments": "{\"path\": \"main.py\"}"}}
  ]
}
```

**真正执行 `read_file` 的是你的 Python 进程**。执行完，你把结果作为一条 `role: "tool"` 的消息塞回数组，再发给模型：

```json
{"role": "tool", "tool_call_id": "call_1", "content": "1: def main():\n2: ..."}
```

这个「模型申请 → 程序执行 → 结果回灌 → 模型继续」的闭环，就是 **agent loop**（见 §3.3）。Hermes 的 `tool_calls` 结构由 [`agent/conversation_loop.py`](../agent/conversation_loop.py:1709) 解析，执行入口是 [`model_tools.py`](../model_tools.py:872) 的 `handle_function_call()`。

### 0.3 Agent = 一个 while 循环 + 一堆 if

剥掉所有工程包装，agent 内核就这么点东西（[`agent/AGENTS.md`](../agent/AGENTS.md:21) 给出了等价的伪代码）：

```python
while 还没超预算 and 没被用户打断:
    response = llm(messages, tools)        # 一次网络请求
    if response.tool_calls:                # 模型要动手
        for tc in response.tool_calls:
            result = handle_function_call(tc.name, tc.args)
            messages.append({"role": "tool", ...})
        # 继续循环，让模型看结果
    else:                                  # 模型给出最终答复
        return response.content
```

Hermes 把这一圈的**每个相位**都拆成了独立文件（`agent/turn_*.py`，共 33 个），
所以「一次迭代」不是一个函数，而是一条文件流水线。**这是本仓库最反直觉、也最需要先建立的心理模型**。

### 0.4 Token、Context Window、Prompt Caching（这三者决定成本）

| 概念 | 是什么 | 为什么你必须在乎 |
|---|---|---|
| **Token** | 模型计费/计长的最小单位（约 0.75 个英文单词 / 0.5 个汉字） | 输入和输出都按 token 收钱 |
| **Context window** | 单次请求能装下的最大 token 数 | 装不下就要压缩（[`agent/context_compressor.py`](../agent/context_compressor.py:1)） |
| **Prompt caching** | 供应商会把请求的**前缀**缓存起来，命中部分按折扣计费 | 前缀只要变一个字节，缓存全废，成本翻数倍 |

因为 §0.1 说「每次全量重传」，一个长会话每轮都要重传大量重复内容 —— **缓存命中率直接决定用户账单**。这就是本仓库第一条铁律的来源（§4.1）。

### 0.5 Python 项目 vs 前端项目：只需知道这 5 点

| 前端习惯 | Python 这里 | 说明 |
|---|---|---|
| `import { x } from './a'` | `from a import x` | 语义相同，但 **import 会执行模块顶层代码**（这点极其关键，见 §6） |
| `package.json` scripts | `[project.scripts]`（[`pyproject.toml`](../pyproject.toml:557)） | 注册命令行的入口函数 |
| `index.ts` 统一 re-export | **facade 文件** | 同名套路，见 §5 |
| `async/await` 到处都是 | 顶层几乎**全同步** | agent loop 是同步的；异步只出现在网关/ACP 这类 I/O 服务层 |
| 一个进程一个 app | **一个进程服务多个 profile** | 见 §7 与 [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md) |

`pyproject.toml` 里有三个命令入口，值得先记住（[`pyproject.toml`](../pyproject.toml:557)）：

```toml
hermes       = "hermes_cli.main:main"   # 主命令：REPL / 子命令 / 网关 / dashboard
hermes-agent = "agent.legacy_cli:main"  # 历史入口，仍在
hermes-acp   = "acp_adapter.entry:main" # 编辑器集成
```

---

## 1. Hermes 是什么

Hermes Agent 是 Nous Research 出品的个人 AI Agent。它的核心特征不是「会聊天」，而是
**一个平台无关的 agent 内核，被 6 种外壳复用**：

| 外壳 | 命令 | 形态 |
|---|---|---|
| CLI（经典 REPL） | `hermes` | 进程内直接跑 `AIAgent` |
| TUI | `hermes --tui` | Node/Ink 前端 + 独立 Python `tui_gateway` |
| 消息网关 | `hermes gateway` | 常驻进程，接 ~20 个平台 |
| 桌面应用 | `hermes serve` | Electron 前端 + `tui_gateway` 后端 |
| Dashboard | `hermes dashboard` | PTY 里跑真实的 `hermes --tui` |
| 编辑器（ACP） | `hermes acp` | stdio JSON-RPC 服务器 |

差异化能力：**跨会话学习**（memory + skills）、**子代理委派**、**定时任务**、**真实终端与浏览器驱动**。
扩展方式是**插件与技能**，不是把核心做大。

> 这里的「6 种外壳」在 [`02-entrypoints.md`](02-entrypoints.md) 里逐个展开；前端面之间的技术栈差异在
> [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md)。

---

## 2. 分层骨架

### 2.1 一张图

```text
┌──────────────────── 入口层（Entry Points）─────────────────────┐
│  CLI        Gateway       ACP       API Server    Batch/Library │
│  cli.py     gateway/      acp_      api server    batch_runner  │
│             run.py        adapter/                              │
│  职责：解析参数 → 准备 profile/配置 → 构造 AIAgent → 渲染结果      │
└───────────────────────────┬────────────────────────────────────┘
                            ▼
┌──────────────────── 内核层（AIAgent）───────────────────────────┐
│  run_agent.py 只是门面；真身是 mixins + agent/*.py               │
│                                                                 │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌──────────────┐  │
│  │ Prompt     │ │ Provider   │ │ Tool       │ │ Compression  │  │
│  │ Builder    │ │ Runtime    │ │ Dispatch   │ │ & Caching    │  │
│  │ system_    │ │ runtime_   │ │ model_     │ │ context_     │  │
│  │ prompt.py  │ │ provider.py│ │ tools.py   │ │ compressor.py│  │
│  └────────────┘ └────────────┘ └────────────┘ └──────────────┘  │
│                                                                 │
│  turn loop：agent/conversation_loop.py + agent/turn_*.py (33 个) │
└──────────┬──────────────────────────────────┬───────────────────┘
           ▼                                  ▼
┌──────────────────────┐        ┌─────────────────────────────────┐
│ 状态层                │        │ 执行层（Tool Backends）          │
│ SessionDB            │        │ Terminal: 7 种后端               │
│ SQLite + FTS5 + WAL  │        │ Browser: 5 种后端                │
│ hermes_state.py      │        │ Web / File / MCP / Vision ...    │
└──────────────────────┘        └─────────────────────────────────┘
```

来源：[`website/docs/developer-guide/architecture.md`](../website/docs/developer-guide/architecture.md:13)

### 2.2 为什么非要分层：一条边界规则

入口层的职责边界是**固定的四步**，且只做这四步（[`02-entrypoints.md`](02-entrypoints.md)）：

```
解析参数 → 准备 profile/配置 → 构建或复用 AIAgent → 渲染结果
```

铁规则：

- **agent 行为绝不下沉到入口层**。CLI 不许自己拼 prompt、不许自己调模型。
- **渲染逻辑绝不上浮到 agent**。`AIAgent` 不知道什么是「终端」「Telegram 消息」。

那 `AIAgent` 怎么把「工具执行到一半了」这种进度告诉界面？—— **回调（callback）**。
`AIAgent.__init__` 收了约 60 个参数，其中一大类就是回调（[`run_agent.py`](../run_agent.py:236)）：

| 回调 | 触发时机 | CLI 用它做什么 | 网关用它做什么 |
|---|---|---|---|
| `stream_delta_callback` | 每个流式 token | 实时打印 | 边收边发消息 |
| `tool_progress_callback` | 工具执行中 | 更新 spinner | 发「正在执行 xxx」 |
| `clarify_callback` | 模型调 `clarify` 工具 | 弹输入框 | 发交互消息 |
| `step_callback` | 一整轮结束 | 状态栏 | 步骤追踪 |
| `status_callback` | 状态变化（思考/执行） | 状态栏 | 平台状态更新 |

**这就是「平台无关内核」的落地方式**：内核只调 `self.xxx_callback(...)`，具体怎么显示由外壳注入。

前端类比：`AIAgent` 像一个只定义 `props.onEvent` 的组件，UI 库（CLI/gateway/TUI）各自实现渲染。

---

## 3. 一次请求的完整旅行（本篇最重要的一节）

以 CLI 为例，从敲回车到看见回答。**每一行都对应真实代码**。

### 3.1 第一层：CLI 收输入

```text
用户敲 "修一下 main.py"
  → HermesCLI（[`cli.py`](../cli.py:894)，由 17 个 mixin 拼成）
  → 输入派发 / slash 命令判定
      · 以 "/" 开头 → 走 slash 注册表（不是 agent 回合）
      · 否则 → 构造/复用 AIAgent，进入一轮对话
```

`HermesCLI` 自己**几乎不写逻辑**。它的类定义直接罗列 17 个基类
（[`cli.py`](../cli.py:894)）：

```python
class HermesCLI(CLIInitMixin, CLITuiRuntimeMixin, CLIProcessNotificationsMixin,
                CLIAgentSetupMixin, CLICommandsMixin, CLIBillingMixin, CLITuiMixin,
                CLIStatusBarMixin, CLIVoiceMixin, CLIModelSwitchMixin, CLISessionMixin,
                CLIStreamMixin, CLIModalMixin, CLITerminalMixin, CLIInfoMixin,
                CLILoopsMixin, CLIChatTurnMixin):
```

挑几个常打交道的：

| Mixin | 文件 | 管什么 |
|---|---|---|
| `CLICommandsMixin` | [`cli_commands_mixin.py`](../hermes_cli/cli_commands_mixin.py:1) | slash 命令处理 |
| `CLIStreamMixin` | [`cli_stream_mixin.py`](../hermes_cli/cli_stream_mixin.py:1) | 流式输出 |
| `CLIChatTurnMixin` | [`cli_chat_turn_mixin.py`](../hermes_cli/cli_chat_turn_mixin.py:1) | 驱动一轮对话 |
| `CLIStatusBarMixin` | [`cli_status_bar_mixin.py`](../hermes_cli/cli_status_bar_mixin.py:1) | 状态栏 |
| `CLITuiRuntimeMixin` | [`cli_tui_runtime_mixin.py`](../hermes_cli/cli_tui_runtime_mixin.py:1) | run-loop 相位（输入派发/启动/信号/关闭） |
| `CLIInitMixin` | [`cli_init_mixin.py`](../hermes_cli/cli_init_mixin.py:1) | `__init__` 相位 |
| `CLISessionMixin` | [`cli_session_mixin.py`](../hermes_cli/cli_session_mixin.py:1) | 会话恢复与切换 |
| `CLIModelSwitchMixin` | [`cli_model_switch_mixin.py`](../hermes_cli/cli_model_switch_mixin.py:1) | `/model` |

MRO 从左到右，所以 `CLIInitMixin` 的同名方法优先级最高。**加行为时按主题挑 mixin，不要往 `cli.py` 里写**
（[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:7)）。

slash 命令本身也不走 `elif` 阶梯 —— 单一事实来源是
[`hermes_cli/commands.py`](../hermes_cli/commands.py:1) 的 `COMMAND_REGISTRY`，
CLI 派发、网关已知命令、help 文本、平台命令菜单全部由它派生。

### 3.2 第二层：构造 AIAgent（只发生一次）

```text
AIAgent.__init__                [`run_agent.py`](../run_agent.py:236)
  → 立刻转发给 init_agent()      [`agent/agent_init.py`](../agent/agent_init.py:2361)
       · 解析 api_mode（3 选 1）
       · 绑定约 60 个参数到实例
       · 建 IterationBudget（轮次预算，父子代理共享）
       · 建工具清单、会话状态、回调槽位
```

**关键点**：`__init__` 甚至不逐字段赋值，而是把 `locals()` 整个（去掉 `tool_delay`）原样交给
`init_agent()`（[`run_agent.py`](../run_agent.py:280)）：

```python
def __init__(self, ...):
    """Forwarder — see ``agent.agent_init.init_agent``."""
    init_kwargs = {k: v for k, v in locals().items() if k not in ("self", "tool_delay")}
    ...
    from agent.agent_init import init_agent
    init_agent(self, **init_kwargs)
```

签名与实现彻底分离：调用方只依赖 `AIAgent.__init__` 的签名，而 60 个参数怎么落地成实例属性，
全在 [`agent/agent_init.py`](../agent/agent_init.py:2361) 一处定义。`init_agent` 用
`_PASSTHROUGH_PARAMS` / `_GATEWAY_IDENTITY_PARAMS` 两张表批量 `setattr`，而不是写 60 行赋值——
**表驱动，不是 if 阶梯**。

这是本仓库的通用模式（facade 只留签名，实现在 sibling 里），见 §5。

> 注意 `render=False` 那类「一个 flag 控制全部渲染」不是随手加的：`quiet_mode` / `tool_progress_mode`
> 这些参数最终决定回调是否触发，而回调决定外壳能不能显示进度。§2.2 的回调表要配合这段读。

### 3.3 第三层：一轮 turn（`run_conversation`）

```text
AIAgent.run_conversation()          [`agent/turn_facade.py`](../agent/turn_facade.py:22)
  → 取跨进程 session turn lease（防同一会话被两个进程同时写）
  → 转发给 run_conversation()        [`agent/conversation_loop.py`](../agent/conversation_loop.py:1709)
      → _run_conversation_turn()     [`agent/conversation_loop.py`](../agent/conversation_loop.py:1547)
```

`run_conversation` 返回的是 **dict**，不是字符串：

```python
{
  "final_response": "修好了，原因是...",
  "messages": [ ... 完整历史 ... ],
  # 以及 usage / 状态等元数据
}
```

简单的 `agent.chat("...")` 只是包了一层，把 `final_response` 抠出来（[`agent/turn_facade.py`](../agent/turn_facade.py:220)）。

### 3.4 第四层：一次迭代的 9 个相位

「一次迭代」的 9 步（来源 [`website/docs/developer-guide/agent-loop.md`](../website/docs/developer-guide/agent-loop.md:59)）：

```text
1. 没有 task_id 就生成一个
2. 把用户消息 append 到 messages
3. 构建或复用【已缓存的】 system prompt        ← system_prompt.py
4. 预检压缩：上下文 > 50% 就先压              ← context_compressor.py
5. 把内部 messages 转换成当前 API 模式的格式   ← 3 种模式，见下
6. 注入临时层（预算告警、上下文压力提示）
7. Anthropic 上打 prompt cache 断点            ← prompt_caching.py
8. 发起【可中断】的 API 调用
9. 解析响应：
     · 有 tool_calls → 执行工具、append 结果、回到第 5 步
     · 是文本        → 落库、按需刷记忆、返回
```

对应文件（用 `grep -rn "def X" agent/turn_*.py` 定位，[`agent/AGENTS.md`](../agent/AGENTS.md:38)）：

| 相位 | 文件 |
|---|---|
| 预检 / 前置门 | `turn_preflight*.py`、`turn_preflight_gate.py` |
| 迭代准备 | `turn_iteration_prep.py` |
| 请求组装 | `turn_request_assembly.py`、`turn_api_request.py` |
| API 调用 | `turn_api_call.py` |
| API 错误 / 重试 | `turn_api_error.py`、`turn_retry_state.py`、`turn_recovery*.py` |
| 响应接收 / 校验 | `turn_response_intake.py`、`turn_response_check.py`、`turn_empty_response.py` |
| 工具轮 | `turn_tool_round.py`、`turn_tool_validation.py` |
| 溢出 / 截断 | `turn_overflow.py`、`turn_truncation.py` |
| 压缩 | `turn_context_compaction.py` |
| 脚本化前奏（内置工具在首次模型调用前的预播放） | `turn_scripted_prelude.py` |
| 存活检测 | `turn_liveness.py` |
| 停止门（预算耗尽 / 无进展 / 用户停止） | `turn_stop_gates.py` |
| turn 准入（跨进程租约 + watchdog） | `turn_facade_lease.py` |
| 收尾 | `turn_final_response.py`、`turn_finalizer.py`、`turn_summary.py`、`turn_usage.py` |
| 错误文案 / 解释 | `turn_failure_copy.py`、`turn_explainers.py`、`turn_loop_errors.py` |

> **为什么拆这么碎？** 因为每个相位都有独立的不变量和一堆边界情况（空响应、超时、限流、上下文溢出、
> 工具参数损坏……）。拆开后，改「溢出处理」只需要看一个约 600 行的文件，而不是在万行怪物里迷路。
> 这也是仓库的硬性规模约束（见 [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md)）。
>
> **读代码的实用技巧**：不要从 `conversation_loop.py` 从头读。先 `grep -rn "def <你关心的词>" agent/turn_*.py`，
> 直接跳到那一个相位，再顺着它的 import 往上下游看。

再补一个容易漏掉的事实：**消息角色交替是硬约束**（[`agent/AGENTS.md`](../agent/AGENTS.md:64)）。
provider 会校验序列，不合法直接拒绝请求。规则：

- 常态：`system → user → assistant → user → assistant → ...`
- 工具期：`assistant(tool_calls) → tool → tool → ... → assistant`
- **绝不能**连续两条 `user`，也**绝不能**连续两条 `assistant`
- 只有 `role: "tool"` 允许连续（并行工具结果）

唯一例外是 `/steer`：它作为一条**独立的 user 行**落在 tool 结果之后
（`assistant(tool_calls) → tool → user` 在所有 provider 路径上都合法），
而不是把文字糊到已经落库的那条 tool 行上 —— 否则只增不改的持久化会和实时请求分叉。

### 3.5 第五层：3 种 API 模式（同一内核，不同线格式）

```text
                     ┌─ chat_completions   (OpenAI 兼容，绝大多数供应商)
内部统一 messages ──→├─ codex_responses     (OpenAI Responses / Codex)
(OpenAI 格式)        └─ anthropic_messages  (Anthropic 原生，经 anthropic_adapter.py)
                     ↓ 调用
                     ↓ 转换回 OpenAI 格式
```

解析优先级（[`website/docs/developer-guide/agent-loop.md`](../website/docs/developer-guide/agent-loop.md:53)）：

1. 显式传入 `api_mode`（最高）
2. 按 provider 推断（`anthropic` → anthropic_messages）
3. 按 base_url 推断（`api.anthropic.com` → anthropic_messages）
4. 默认 `chat_completions`

**设计要旨**：无论走哪种模式，**内核内部只认一种消息格式**（§0.2 那种 OpenAI 风格 `role/content/tool_calls`）。
边界处转换，中间不留分叉。这是「窄腰」在数据格式上的体现。

### 3.6 第六层：工具真正被执行

模型要调工具后，调用链是：

```text
agent 层拦截（agent 级工具：todo / memory / session_search / delegate_task ...）
  实现：agent/tool_executor.py 查 agent/inline_tool_executors.py 的 INLINE_TOOL_EXECUTORS 表
  ↓ 没被拦截
handle_function_call()            [`model_tools.py`](../model_tools.py:872)
  ↓
  1. coerce_tool_args()   参数规整（模型有时给字符串化的 JSON）
  2. legacy alias 映射（老工具名 → 新工具名）
  3. Tool Search 桥（tool_search / tool_describe / tool_call 展开成真实工具名）
  4. request middleware（可改写参数，record trace）
  5. 前置守卫（危险命令判定、审批、写入保护）
  6. registry 里取 handler → 执行
  7. post_tool_call hook
  ↓
返回 JSON 字符串，被包成 {"role": "tool", "tool_call_id": ..., "content": ...}
```

三个值得记住的细节：

- **agent 级工具是「表驱动」的**。`todo`/`memory`/`session_search`/`delegate_task` 这类需要访问
  agent 自身状态的工具，在 [`agent/inline_tool_executors.py`](../agent/inline_tool_executors.py:1) 的
  `INLINE_TOOL_EXECUTORS` 字典里登记，由 [`agent/tool_executor.py`](../agent/tool_executor.py:1) 拦截执行。
  加一个新的就是加一行表项，**不是加一条 `if name == ...`**。
- **并发**：单工具调用直接在主线程跑；多个 `tool_calls` 走 `ThreadPoolExecutor` 并发，
  但结果**按原始顺序**回填（[`website/docs/developer-guide/agent-loop.md`](../website/docs/developer-guide/agent-loop.md:128)）。
  例外：标为 interactive 的工具（如 `clarify`）强制串行，否则会同时弹两个对话框。
- **每一层都可能短路**（返回错误、要求审批、被 hook 拒绝）。
  所以「工具执行成功」不是默认假设，而是每层都放行之后的结果。

这就是为什么工具系统值得单独一篇（[`05-tools-system.md`](05-tools-system.md)）。

### 3.7 第七层：落库

一轮结束，`SessionDB` 写入 SQLite（[`hermes_state.py`](../hermes_state.py:461)）：

- 会话行（`session_id`、source、model、profile…）
- 消息行
- 供全文检索的 FTS5 索引
- 压缩产生的**血缘**（parent/child session）

两个容易忽略的点：

- **WAL 模式**（[`hermes_state.py`](../hermes_state.py:461)）：多读者 + 单写者。
  这正是为什么网关可以一边让 TUI 读会话、一边自己写 —— 但也是为什么所有写必须走同一个出口。
- **会话行是「懒创建」的**。第一次真正用到它时才 `create_session`
  （[`run_agent.py`](../run_agent.py:313) 的 `_ensure_db_session`），
  这样只做模型探测、没发过消息的空会话不会在库里留下垃圾行。

细节见 [`07-state-and-session.md`](07-state-and-session.md)。

### 3.8 三条其他入口的对照

**网关消息**：

```text
平台事件 → Adapter.on_message() → MessageEvent
  → GatewayRunner._handle_message()      [`gateway/run.py`](../gateway/run.py:3353)
    → 授权用户 → 解析 session key → 带历史构造 AIAgent
    → run_conversation() → 通过 adapter 回投递
```

**Cron 任务**：

```text
Scheduler tick → 载入到期 job
  → 建全新 AIAgent（无历史）
  → 注入附加 skills 作为上下文
  → 跑 job prompt → 投递到目标平台 → 更新状态与 next_run
```

> 注意 cron 会话默认 `skip_memory=True` —— 记忆 provider 在 cron 中**故意不运行**
> （[`agent/AGENTS.md`](../agent/AGENTS.md:127)）。否则定时任务会把一堆自动化噪音写进你的长期记忆。

**ACP**：

```text
IDE ──stdio JSON-RPC──→ HermesACPAgent（acp_adapter/）
  → 同样是 run_conversation()，只是审批/进度走 ACP 的 session_update 事件
```

**三种入口最终都落在同一个 `run_conversation()` 上。** 这就是「平台无关内核」最硬的证据。

### 3.9 失败与恢复：为什么 turn loop 有 33 个文件

真实世界的模型调用会失败。Hermes 把这些失败**分层**处理，而不是写一个巨大的 `try/except`：

| 失败类型 | 现象 | 处理位置 |
|---|---|---|
| 瞬时网络/5xx | 请求失败可重试 | `turn_retry_state.py`、`turn_recovery.py` |
| 限流（429 + `Retry-After`） | 需要等 | 重试前等待，单次上限 600s（[`website/docs/user-guide/configuration.md`](../website/docs/user-guide/configuration.md:1231)） |
| 上下文溢出 | 请求超 context window | `turn_overflow.py` → 先压缩再重试 |
| 响应被 max_tokens 截断 | 半句话结束 | `turn_truncation.py` |
| 空响应 | 模型什么都没说 | `turn_empty_response.py` |
| 工具参数损坏 | JSON 不合法 | `coerce_tool_args()` + 丢弃并插入 marker 保持会话存活（[`run_agent.py`](../run_agent.py:221)） |
| 反复失败 | 需要降级 | `turn_recovery_autorecover.py`（耗尽后的等待-重试阶梯）、`fallback_model` |
| 工具死循环 | 同一调用反复失败 | 默认注入警告；无人值守的网关/cron 默认硬停（[`configuration.md`](../website/docs/user-guide/configuration.md:2064)） |

一个贯穿性设计：**「彻底失败」不是把会话搞崩，而是留下可恢复的痕迹**。
比如工具参数损坏时，Hermes 不会抛异常终止，而是把那段损坏的调用**丢掉**并插入一条说明性 marker
（`_TOOL_CALL_ARGUMENTS_CORRUPTION_MARKER`），让后续轮次继续可用。这是对「长会话很贵」的直接让步。

### 3.10 入口差异一览（同一个内核，不同的「谁负责渲染 / 谁负责授权」）

| 关注点 | CLI | Gateway | ACP |
|---|---|---|---|
| 谁建 AIAgent | `HermesCLI` | `GatewayRunner` | `HermesACPAgent` |
| 会话历史从哪来 | 进程内列表 + `--resume` 读库 | SessionStore（按 session key） | ACP session manager（+ 共享 state.db） |
| 用户鉴权 | 本机用户即授权 | 白名单 / DM pairing | 宿主机的 OS 用户账户 |
| 审批怎么弹 | 终端提示 | 聊天消息 | ACP 权限请求（多一档 `allow_session`） |
| 进度怎么显示 | spinner / 流式打印 | 边收边发消息 | `session_update` 事件 |
| 工作目录 | 进程 cwd | 会话上下文 | 编辑器 cwd，绑定到 task ID |

---

## 4. 两条铁律（后面所有设计都是它们的推论）

### 4.1 铁律一：逐会话的 prompt caching 神圣不可侵犯

回到 §0.4：每次请求都全量重传，缓存命中靠**前缀完全一致**。

于是下面这些操作全都会**击穿缓存**，把成本乘上去：

- 改历史消息（哪怕改一个字符）
- 中途换 toolset（工具清单变了 → 前缀变了）
- 重新加载记忆并重建 system prompt
- 任何时候重建 system prompt

**唯一被允许的例外是上下文压缩（compression）**。压缩是「一次性、显式、有意的缓存破坏」。

那「中途要注入内容」怎么办？只能搭便车（[`agent/AGENTS.md`](../agent/AGENTS.md:55)）：

| 想注入什么 | 允许的载体 |
|---|---|
| 技能 slash 命令 | 一条 **user 消息**（`agent/skill_commands.py`） |
| 子目录 `AGENTS.md` 提示 | 追加到 **tool 结果**（`agent/subdirectory_hints.py`） |
| `/steer` 中途插话 | tool 结果之后的**独立 user 行** |
| 预算告警 / 上下文压力 | **临时层**（不进持久历史） |

**绝不碰 system prompt。**

前端类比：把 system prompt 想成 CDN 上那个 `vendor.[hash].js`。你只要改它一个字节，hash 变、全量回源、
所有用户缓存失效。所以「运行期配置」只能塞进请求参数，不能改这个文件。

#### system prompt 的「三层」结构正是为缓存设计的

[`agent/system_prompt.py`](../agent/system_prompt.py:1) 开头的 docstring 直接把设计动机写出来了：

> Built once per session and reused across turns (only context compression triggers a rebuild)
> so the upstream prefix cache stays warm.

三层用 `\n\n` 拼起来，**从最稳定到最易变**：

| 层 | 内容 | 变化频率 |
|---|---|---|
| `stable` | 身份、行为指引、环境提示、编码简报、平台提示 | 会话内**字节级不变** |
| `context` | workspace 快照、调用方传入的 `system_message`、上下文文件（AGENTS.md 等） | 仅在压缩重建时变 |
| `volatile` | skills 索引、memory、USER.md、外部 memory provider、时间戳行 | 语义上「易变」，但**仍然每轮字节一致** |

**为什么把最易变的内容也放最后？** 因为前缀缓存是**从前往后**匹配的：只要前面的字节没变，
后面的内容即使在语义上「随时可能不同」，只要本次会话内实际字节没变，缓存就照样命中。
把易变层放末尾，是为了「万一真要变，也只让最短的后缀失效」。

注意那个时间戳行：它被特意做成**只到「天」**（[`agent/system_prompt.py`](../agent/system_prompt.py:490) 附近），
这样同一天内的多次重建得到完全相同的字节。**任何精度更高的时间戳都会每天击穿缓存。**

这一篇不展开 prompt 组装细节，见 [`04-prompt-and-caching.md`](04-prompt-and-caching.md)。

### 4.2 铁律二：核心是窄腰，能力长在边缘

每一个模型工具都会在**每一次** API 调用中随请求发送（§0.1）。工具越多：

- 每次请求的 token 越多（贵）
- 模型选错工具的概率越高（笨）
- 改一个工具的风险面越大（脆）

所以新增一个**核心**工具的门槛极高。优先级阶梯（[`AGENTS.md`](../AGENTS.md:1) § Footprint ladder）：

```text
扩展现有代码  →  CLI 命令 + skill  →  服务门控工具(check_fn)  →  插件  →  目录里的 MCP server  →  最后才是新核心工具
```

对照 [`toolsets.py`](../toolsets.py:11) 的 `_HERMES_CORE_TOOLS` 就能感受到这个「窄」：
核心清单是 **55 个**工具名（文件/终端/浏览器/搜索/记忆/todo/委派/看板…），
而 `TOOLSETS` 一共 **60 个条目**，绝大多数工具挂在具名 toolset 或插件里，**按会话勾选**才进入请求。

再加一层成本视角：55 个工具的 JSON Schema 每次请求都要随 `tools` 数组发送一遍。
这就是为什么 `check_fn` 门控（§6.4）和 toolset 裁剪（§6.6）不是「优化」，而是**默认必需**。

---

## 5. Facade + Siblings：全仓库最重要的工程约定

### 5.1 问题：上帝文件

一个文件两万行时，改一行要读一天、合并冲突天天有、测试跑不完。

### 5.2 解法：一个门面 + 一堆兄弟

```text
run_agent.py                 ← facade：只留公共入口 + 别人 import 的名字
agent/                       ← siblings（285 个文件，按主题命名）
  agent_init.py              ← 构造（__init__ 的真身）
  turn_facade.py             ← run_conversation / chat 的准入逻辑
  conversation_loop.py       ← 主循环
  turn_*.py                  ← 33 个相位文件
  system_prompt.py           ← prompt 组装（三层）
  context_compressor.py      ← 压缩
  memory_manager.py          ← 记忆编排
```

（provider 解析不在 `agent/`，而在 [`hermes_cli/runtime_provider.py`](../hermes_cli/runtime_provider.py:994)——
因为它是 CLI/网关/cron/ACP/辅助调用**共用**的，不属于 agent 内部。）

命名规律：`<stem>_<topic>.py`。找代码时**按主题 grep 兄弟文件，不要通读门面**：

```bash
grep -rn "def run_conversation" agent/*.py     # 找到 turn_facade.py + conversation_loop.py
grep -rn "def build_system_prompt" agent/*.py  # 找到 system_prompt.py
```

一个真实的「门面有多薄」的例子 —— [`run_agent.py`](../run_agent.py:214) 的
`AIAgent` 类体里几乎只有一个 docstring 和一个 `__init__`，其余全部来自 mixin：

```python
class AIAgent(
    ClientLifecycleMixin, StreamDeliveryMixin, StatusOutputMixin, ApiRequestHooksMixin,
    ApiErrorSummaryMixin, InterruptControlMixin, TurnExplainersMixin, ActivityTrackingMixin,
    RateLimitCreditsMixin, SessionPersistenceMixin, CompressionFacadeMixin, TurnFacadeMixin,
    VisionMessagePrepMixin, ReasoningParamsMixin,
):
    """AI Agent with tool calling capabilities."""
```

读懂这一行，你就知道「AIAgent 的能力」要往哪 14 个 mixin 里找。

### 5.3 三条潜规则（踩过坑才知道）

1. **兄弟在函数体内延迟 import 门面**，避免模块级循环依赖。
   ```python
   def some_sibling_fn(...):
       from run_agent import AIAgent     # ← 写在函数里，不在文件顶部
   ```
2. **在哪里被读，就在哪里打补丁（patch）**。
   如果兄弟文件在函数内 `from run_agent import X`，那么测试里 `patch("run_agent.X")` 有效，
   而 `patch("agent.turn_facade.X")` **会静默失效**。这是本项目最常见的测试假绿来源。
3. **没有 re-export 兼容层**。内部路径不是 API；移动符号必须同一 PR 内改完所有文档引用。

### 5.4 门面对照表

| Facade | Siblings | 职责 |
|---|---|---|
| [`run_agent.py`](../run_agent.py:214) | `agent/turn_*.py`（33 个）、`agent_init.py`、`conversation_loop.py` | AIAgent 组装与对话循环 |
| [`cli.py`](../cli.py:894) | `hermes_cli/cli_*_mixin.py`（17 个基类） | CLI REPL 与交互 |
| [`hermes_state.py`](../hermes_state.py:461) | `hermes_state_*.py` | SQLite 会话/状态库 |
| [`gateway/run.py`](../gateway/run.py:3353) | `gateway/run_*.py`、`gateway/session*.py` | 网关生命周期与派发 |
| [`model_tools.py`](../model_tools.py:1) | （单一职责已足够） | 工具发现与分发 |
| `tools/mcp_tool.py` | `tools/mcp_tool_*.py` | MCP 客户端 |
| `hermes_cli/kanban.py` | `hermes_cli/kanban_*.py` | 看板 CLI |

### 5.5 配套的规模硬约束

`scripts/code_health/config.py` 里对**每个单元**做棘轮（ratchet）限制：

| 指标 | 上限 |
|---|---|
| 函数圈复杂度 | ≤ 20 |
| 函数长度 | ≤ 300 行 |
| 嵌套深度 | ≤ 6 |
| 单文件行数 | ≤ 2000 行 |

已经超标的单元**只能变小不能变大**。所以你会看到「加功能 = 新开一个 sibling」这种反复出现的模式。
`# noqa` 不能豁免这类检查，只有 `# health: allow <RULE> -- <why>` 可以。

---

## 6. 工具为什么能「自注册」：依赖链与 import 副作用

这是初学者读这个仓库时**第二容易懵**的地方。

### 6.1 依赖链

```text
tools/registry.py          ← 零依赖叶子（被所有工具文件 import）
       ↑
tools/*.py                 ← 每个文件在【模块顶层】调用 registry.register(...)
       ↑
model_tools.py             ← import registry + 触发 discover_builtin_tools()
       ↑
run_agent.py / cli.py / batch_runner.py
```

来源：[`website/docs/developer-guide/architecture.md`](../website/docs/developer-guide/architecture.md:268)

注意这里 Python 与前端的一个根本差异：**`import` 不只声明依赖，它会执行模块顶层代码**。
所以「`tools/*.py` 里的 `registry.register(...)` 会自动生效」——
导入就是执行，执行就是注册。JS 的 ESM `import` 也有副作用（顶层语句会跑），
只是前端项目习惯把这种写法当成反模式；在这个仓库里，它是**刻意设计的发现机制**。

**为什么要先搞一个 AST 扫描，而不是直接 `import` 所有 `tools/*.py`？**
因为 `tools/` 里有大量**不是工具**的兄弟模块（`approval.py`、`process_registry.py`、
`credential_files.py`……）。无脑 import 会拉进一堆重依赖（playwright、docker SDK），
拖慢每次启动。AST 扫描只挑「顶层真的调了 `registry.register`」的文件去 import，
并用磁盘缓存把 ~145ms 的扫描成本摊掉。

### 6.2 自注册的机制（这一段值得逐行看）

[`tools/registry.py`](../tools/registry.py:96) 的 `discover_builtin_tools()` 做了一件聪明事：

1. 扫描 `tools/*.py` 和 `tools/<pkg>/tool.py`
2. 用 **AST 解析**判断该文件**模块体**里是否调用了 `registry.register(...)`
   （只有模块顶层或模块级 `for` 里算；函数里的注册不算——那只是 helper）
3. 把判定结果按 `(mtime_ns, size)` 缓存到磁盘（`<HERMES_HOME>/cache/tool_discovery_cache.json`），
   避免每次启动都跑约 145ms 的 AST 扫描
4. 对判定为「自注册」的模块执行 `importlib.import_module(...)`

**import 即注册** → 不需要任何手工 import 清单。新增一个工具文件，它自动出现。

### 6.3 注册时到底存了什么

每个工具注册成一个 `ToolEntry`（[`tools/registry.py`](../tools/registry.py:181)）：

```python
@dataclass(eq=False, slots=True)
class ToolEntry:
    name: str                    # 模型看到的工具名
    toolset: str                 # 归属工具集
    schema: dict                 # 给模型的 JSON Schema（名字 + 参数）
    handler: Callable            # 真正执行的函数
    check_fn: Optional[Callable] # 可用性探针（见 6.4）
    requires_env: list           # 依赖的环境变量
    is_async: bool
    description: str
    emoji: str
    max_result_size_chars: ...
    dynamic_schema_overrides: ... # 每次取 schema 时动态覆盖（如 delegate_task 的描述随限额变化）
```

注册时**立刻校验 schema 合法性**（`schema['parameters']` 必须是对象）——
因为一个坏 schema 会被序列化进每一次请求，然后在离错误很远的地方 400 报错（[`tools/registry.py`](../tools/registry.py:666)）。

### 6.4 `check_fn`：可用性门控

有些工具「代码在，但环境不支持」：Docker 没装、Modal SDK 缺失、Playwright 不可用。

`check_fn` 是零参探针，返回 `False` 时该工具**不出现在本次请求的 schema 里**。
探针结果带 TTL 缓存（因为探针可能很慢），并有「曾经可用则宽限」的策略，避免环境抖动导致工具闪断。

**这就是铁律二（§4.2）说的「服务门控工具」**：能力可以写，但只有探针通过才占用请求预算。

### 6.5 profile 隔离：注册表为什么是「分层」的

`ToolRegistry` 不是一个扁平字典，而是**两层**（[`tools/registry.py`](../tools/registry.py:427)）：

```python
self._tools: dict[str, ToolEntry]        = {}   # 进程级：内置工具
self._scoped_tools: dict[str, dict[str, ToolEntry]] = {}  # 按 HERMES_HOME 分层的插件覆盖
```

查表时 `_lookup(name, scope)` 先看当前 profile 的 overlay，再回落到全局。
所以同名的插件工具只在「加载它的那个 profile」里生效，不会污染别的 profile。
这又是「一个进程服务多个 profile」那条约束的落地细节（§7、[`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)）。

另外，插件要**覆盖**内置工具必须显式 `override=True`，否则注册会被拒绝并记 error
（[`tools/registry.py`](../tools/registry.py:666)）。这是防止插件偷偷替换核心能力的护栏。

### 6.6 工具集（toolset）：从「有哪些工具」到「这次给哪些」

```text
tools/registry.py     注册所有工具（全集，可能 70+）
        ↓
toolsets.py           TOOLSETS 字典：具名分组 + includes 组合 + posture
        ↓
model_tools.get_tool_definitions(enabled_toolsets, disabled_toolsets)
        ↓
本次请求的 tools 数组（真正发给模型的东西）
```

关键函数（[`toolsets.py`](../toolsets.py:74)）：

- `TOOLSETS`：`{"description", "tools", "includes"}` 的表
- `resolve_toolset(name)`：递归展开 `includes` 得到最终工具名列表（[`toolsets.py`](../toolsets.py:368)）
- `_HERMES_CORE_TOOLS`：CLI 与所有消息平台的共享核心清单（[`toolsets.py`](../toolsets.py:11)）

`get_tool_definitions()` 还做了一层重要缓存（[`model_tools.py`](../model_tools.py:214)）：
以「registry 代际号 + 配置指纹 + toolset 集合 + profile + kanban 上下文」为 key，最多缓存 8 条。
**注意它返回的是浅拷贝**——因为 `run_agent` 会往自己的列表里追加 memory/LCM schema，
共享引用会导致重复工具名，而 DeepSeek/Kimi/MiMo 这类供应商会因为重名直接 400。

---

## 7. 进程与线程模型（零基础最容易懵的一节）

不同的外壳，进程/线程模型完全不同。搞混了就会问出「为什么网关改了配置，CLI 看不到」这种问题。

### 7.1 CLI：单进程，几乎单线程

```text
python (hermes)
  └─ 主线程：prompt_toolkit 收输入 → run_conversation()（同步阻塞）
       └─ API 调用期间：内部再开一个线程做 HTTP，主线程盯「中断事件」
```

`_interruptible_api_call` 的结构（[`website/docs/developer-guide/agent-loop.md`](../website/docs/developer-guide/agent-loop.md:106)）：

```text
主线程等待三者之一：响应就绪 / 用户按了中断 / 超时
                    ↑
            API 线程：HTTP POST
```

被中断时，API 线程的响应**直接丢弃**，绝不写进历史（否则会污染下一轮的 messages）。

### 7.2 TUI / Desktop：两个进程，stdio JSON-RPC

```text
Node (Ink 前端) ──换行分隔 JSON-RPC over stdio──  Python (tui_gateway)
                                                      └─ AIAgent
```

设计原则一句话：**TypeScript 拥有屏幕，Python 拥有 agent。**

前端类比：这就是 **LSP**（Language Server Protocol）的形态——编辑器 spawn 一个子进程，
通过 stdin/stdout 传 JSON。你熟。

三种帧（[`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md)）：

| 方向 | 类型 | 用途 |
|---|---|---|
| client → server | method call | 客户端调方法 |
| server → client | **request** | agent 反问用户（审批、clarify、sudo、密钥） |
| server → client | `event` | 通知（流式 token、状态变化） |

注意中间那行：**agent 可以反问**。所以 `send()` 会**阻塞 agent 线程**，直到带同一个 `srq-<n>` id 的响应帧回来。

两个工程细节值得知道：

- **重连要能重放**：`open_requests(sid)` 让 `session.resume` / `session.events.since` 把「还开着的提问」
  重新吐给重连的客户端，否则你一刷新就再也回答不了那个审批。
- **旧客户端要快速失败**：客户端在 `gateway.ready` 时会声明
  `client.capabilities {server_requests: true}`。没声明的是比 server→client request 更老的版本，
  `send()` 对它直接失败，**而不是让 agent 干等到超时**。

### 7.3 网关：单进程，每会话一个 AIAgent，多平台并发

```text
python (hermes gateway)
  ├─ 事件循环：收各平台 webhook / 长连接消息
  ├─ 每个活跃会话一个 AIAgent（带自己的历史与预算）
  ├─ cron ticker
  └─ SessionDB（WAL：多读者 + 单写者）
```

**关键陷阱**：一个网关进程可能同时服务多个 profile。凡是「离开一轮对话之后」运行的代码
（启动探针、定时器、延迟回调、子进程），都必须**显式绑定所属 profile scope**——
`os.environ` 和模块全局变量里存的是**启动进程那个 profile** 的值，读错了就是静默的默认 profile 泄漏
（[`AGENTS.md`](../AGENTS.md:1) § Profile scope；细节 [`gateway/AGENTS.md`](../gateway/AGENTS.md:1)）。

### 7.4 profile 泄漏：一个具体例子

假设一个网关进程同时服务 `default` 和 `coder` 两个 profile：

```python
# 启动时：进程环境是 default profile
os.environ["HERMES_HOME"] = "/Users/x/.hermes"

async def later_callback():           # 10 分钟后，为 coder 会话触发的延迟回调
    home = get_hermes_home()          # ← 读到的是 default 的 home！
    db = SessionDB(home / "state.db") # ← 把 coder 的数据写进了 default
```

正确写法是**在进入这段代码的边界处显式绑定 scope**（contextvar + `copy_context`），
而不是依赖 `os.environ`。因为 `HERMES_HOME` 是**启动那一刻**的值，而回调运行时「当前会话」
早就换成另一个 profile 了。

`get_hermes_home()` 的解析顺序本身也说明了这点（[`hermes_constants.py`](../hermes_constants.py:111)）：

```text
context-local override  →  HERMES_HOME 环境变量  →  平台默认值
```

**第一优先级是 context-local override**，就是为了让异步边界能安全地改「当前是谁」。
这就是全仓库反复强调「不要从 argv 猜进程身份、不要用模块全局存 profile」的原因。

### 7.5 一张对照表

| 外壳 | 进程数 | agent 线程 | I/O 模型 | 状态在哪 |
|---|---|---|---|---|
| CLI | 1 | 主线程 | 同步 + 一个 API 线程 | 进程内 + SessionDB |
| TUI | 2（Node + Python） | gateway 工作线程 | async 事件循环 | Python 进程 + SessionDB |
| Desktop | 2（Electron + Python） | 同上 | WebSocket | 同上 |
| Dashboard | 1 PTY + 真实 TUI | 同 TUI | PTY 转发 | 同上 |
| Gateway | 1（常驻） | 每会话 | async 事件循环 | SessionDB（WAL） |
| ACP | 1（被 IDE spawn） | 工作线程 | async 事件循环 | SessionDB |

---

## 8. 状态到底存在哪

| 东西 | 位置 | 说明 |
|---|---|---|
| 配置 | `~/.hermes/config.yaml` | 三个 loader，别用错（见下方） |
| 密钥 | `~/.hermes/.env` | **只放 secrets**；行为配置进 config.yaml |
| 会话/消息/索引 | `~/.hermes/state.db` | SQLite + FTS5 + WAL |
| 工具发现缓存 | `~/.hermes/cache/tool_discovery_cache.json` | 见 §6.2 |
| 记忆 | 由 memory provider 决定 | 可以是文件，也可以是外部服务 |
| 技能 | `~/.hermes/skills/` + 仓库内置 `skills/` | 见 [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) |
| 日志 | `~/.hermes/logs/` | `hermes logs` |
| Profile 根目录 | `~/.hermes/profiles/<name>/` | 每个 profile 一整套上面这些东西 |

一句必须记住的边界（[`AGENTS.md`](../AGENTS.md:1)）：**`.env` 只放 secrets，行为配置进 `config.yaml`。**
为「非密钥配置」新增 `HERMES_*` 环境变量是明确被拒绝的做法。

**所有路径都必须 profile 感知**：用 `get_hermes_home()` 取路径、`display_hermes_home()` 取展示文本
（[`hermes_constants.py`](../hermes_constants.py:111)）。硬编码 `~/.hermes` 会被 CI lint 拒绝（HX001）。

**三个配置 loader 的坑**（[`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md)）：

| Loader | 谁在用 | 是否合并 DEFAULT_CONFIG |
|---|---|---|
| `load_cli_config()` | CLI | 是 |
| `load_config()` | `hermes tools/setup` 等子命令 | 是 |
| `load_user_config_effective()` | 网关运行时、TUI gateway、cron、doctor | **否** |

症状：「CLI 能看到某 key，网关看不到」= 用错 loader 了。

还有一条硬规则：**配置写入只有一个缝** —— `hermes_cli.config.atomic_config_write`
（或显式的全状态 `atomic_config_replace`）。**绝不**对配置路径直接 `yaml.dump`：
CI lint 会拒绝，因为它会「因遗漏而删除」用户没写的 key。

---

## 9. 目录职责表（load-bearing 入口）

| 路径 | 职责 | 规模 |
|---|---|---|
| [`run_agent.py`](../run_agent.py:214) | AIAgent 门面（真身在 `agent/`） | 门面 |
| [`model_tools.py`](../model_tools.py:1) | 工具发现 / schema 收集 / 分发 | 中 |
| [`toolsets.py`](../toolsets.py:1) | `TOOLSETS`、`_HERMES_CORE_TOOLS` | 中 |
| [`cli.py`](../cli.py:894) | `HermesCLI` + 17 个基类 mixin | 门面 |
| [`hermes_state.py`](../hermes_state.py:461) | `SessionDB`（SQLite/FTS5/WAL） | 门面 |
| [`hermes_constants.py`](../hermes_constants.py:111) | profile 感知路径 | 小 |
| [`agent/`](../agent/) | turn 相位、provider、memory、compression、prompt | ~285 个 py |
| [`tools/`](../tools/) | 工具实现 + `environments/` 后端 | ~274 个 py |
| [`tools/registry.py`](../tools/registry.py:427) | 注册表（零依赖叶子） | 单文件 |
| [`hermes_cli/`](../hermes_cli/) | 子命令、setup、config、插件、web routers | ~513 个 py |
| [`gateway/`](../gateway/) | 网关门面 + `platforms/` 适配 | ~130 个 py |
| [`acp_adapter/`](../acp_adapter/) | ACP 服务器（IDE 集成） | 小 |
| [`cron/`](../cron/) | 定时调度器 | 中 |
| [`plugins/`](../plugins/) | memory / context_engine / model-providers / kanban / platforms | 插件 |
| [`skills/`](../skills/)、[`optional-skills/`](../optional-skills/) | 内置技能 / 已发布未激活 | 内容 |
| [`ui-tui/`](../ui-tui/)、[`tui_gateway/`](../tui_gateway/) | Ink 前端 + Python JSON-RPC 后端 | 双端 |
| [`apps/desktop/`](../apps/desktop/) | Electron 桌面应用 | 前端 |
| [`web/`](../web/) | Dashboard SPA | 前端 |
| [`pm/`](../pm/)、[`hermes_platform/`](../hermes_platform/) | 依赖管理器；机器事实与可执行文件查找 | 基建 |
| [`scripts/`](../scripts/) | `check`、`run_tests.sh`、`code_health`、ci | 基建 |
| [`tests/`](../tests/) | Pytest，镜像源码树 | ~1250 文件 |

---

## 10. 规模感知（建立「广度」预期，别被吓到）

| 维度 | 量级 |
|---|---|
| `tools/*.py` | ~274 个文件（含大量 `_*` 兄弟模块） |
| `agent/*.py` | ~285 个文件 |
| `hermes_cli/*.py` | ~513 个文件 |
| `gateway/*.py` | ~130 个文件 + `platforms/` 36 个 |
| 注册工具 | 70+ |
| 核心工具清单 `_HERMES_CORE_TOOLS` | 55 个 |
| `TOOLSETS` 条目 | 60 个（键会变，勿在测试里断言全集） |
| 终端后端 | 7 种（local / docker / ssh / modal / daytona / singularity / Vercel Sandbox） |
| 浏览器后端 | 5 种 |
| API 模式 | 3 种 |
| 平台适配器 | 内置 ~8 + 插件 ~21 |
| 测试 | 约 2.5 万个 |

**不要试图读完。** 正确的读法是：先用 §3 的主干建立心理模型，然后**按症状查**
（[`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) 末尾的速查表）。

---

## 11. 本篇自检（能答出来说明地基打好了）

1. 为什么 LLM「不记得」上一句话？Hermes 靠什么补上这个能力？
2. 模型返回 `tool_calls` 之后，是谁真正执行了文件读取？执行结果以什么形式回到模型？
3. `run_agent.py` 里为什么找不到 turn loop 的实现？它在哪？
4. 为什么「中途改 system prompt」是不可接受的设计？如果非要注入内容，应该走什么载体？
5. 新增一个 `tools/xxx_tool.py`，为什么不需要在任何地方登记它？
6. `check_fn` 返回 `False` 时，工具是被「禁用」还是「不发送」？这对成本有什么影响？
7. TUI 为什么是两个进程？谁拥有屏幕、谁拥有 agent？
8. 网关里一个「离开一轮对话后运行的回调」为什么必须显式绑定 profile？

---

## 12. 附录 A：术语表（前端视角翻译）

| 术语 | 一句话解释 | 前端最接近的概念 |
|---|---|---|
| **agent** | 能自己决定调哪个工具、循环多轮的 LLM 程序 | 一个有状态机的事件处理器 |
| **turn** | 一次 `run_conversation()` 调用（用户说一句 → 得到最终答复） | 一次用户交互的完整事务 |
| **iteration** | turn 内部的一次模型调用（可能触发工具） | 事务里的一个 step |
| **tool / toolset** | 工具 / 具名工具分组 | 函数 + 按需 import 的模块组 |
| **tool_call** | 模型返回的「请帮我执行 X」结构化对象 | 一条要 dispatch 的 action |
| **system prompt** | 每次请求最前面的那段指令 | 全局配置 / 环境变量 |
| **compression** | 把中段历史总结成摘要，腾出 context window | 分页 + 服务端聚合 |
| **prompt caching** | 供应商缓存请求前缀，命中打折 | CDN / HTTP cache（但按前缀匹配） |
| **provider** | 提供模型的厂商/网关（OpenRouter、Anthropic…） | 后端 baseURL |
| **api_mode** | 与 provider 对话的线格式（3 种） | 不同的 API 版本 |
| **profile** | 一套完全隔离的 home/config/memory/session | 多租户 / 多个 localStorage 分区 |
| **skill** | 一段 `SKILL.md` 指令包，按需注入上下文 | 可按需 import 的文档型插件 |
| **MCP** | Model Context Protocol，接外部工具服务的标准 | 第三方 SDK 适配层 |
| **subagent** | 由 `delegate_task` 派生的子 agent，上下文隔离 | Web Worker（隔离上下文 + 受控通信） |
| **facade** | 只留公共入口的门面文件 | `index.ts` 的 re-export |
| **sibling** | 按主题拆出的兄弟模块 | `feature/` 下的小模块 |
| **check_fn** | 判断工具在当前环境是否可用的探针 | 特性开关 + 能力检测 |
| **WAL** | SQLite 的写前日志模式（多读单写） | 乐观并发控制的变体 |

---

## 13. 附录 B：动手读源码的 10 条命令

```bash
# 1. 主循环在哪
grep -rn "def run_conversation" agent/*.py

# 2. 某个相位在哪个文件
grep -rn "def .*overflow" agent/turn_*.py

# 3. 工具从哪注册
grep -rn "registry.register(" tools/*.py | head -20

# 4. 某个工具的实现
grep -rn "def .*_tool\b" tools/ | grep -i todo

# 5. 工具集怎么展开
grep -n "def resolve_toolset" -A20 toolsets.py

# 6. system prompt 三层怎么拼
grep -n "def build_system_prompt" -A30 agent/system_prompt.py

# 7. provider 怎么解析（注意：在 hermes_cli/ 不在 agent/）
grep -n "def resolve_runtime_provider" -A40 hermes_cli/runtime_provider.py

# 8. 会话表结构
grep -rn "CREATE TABLE" hermes_state*.py | head

# 9. 网关怎么处理一条消息
grep -rn "def _handle_message\|def handle_message" gateway/run*.py

# 10. 某个行为为什么存在（最重要的一条）
git log -p -S "符号名" --oneline | head -100
```

第 10 条是项目 rubric 反复强调的：**在判定「这是 bug」之前，先用 `git log -S` 查它的来意**。
很多看起来奇怪的隔离/缺失是**刻意设计**，删掉它才是 bug。

---

## 14. 小结与下一步

必须带走的四件事：

1. **agent = 无状态模型 + 你自己维护的 messages + 一个工具执行循环。** 所有复杂度都长在这个循环的边界上。
2. **两条铁律**：缓存神圣（只允许 compression 破坏）、核心窄腰（能力往边缘长）。
3. **facade + siblings + 就地 patch**，以及 **import 即注册** 的工具发现机制。
4. **平台无关**：入口层只做「解析参数 → 准备配置 → 建 agent → 渲染」，差异靠回调注入。

下一步 → [`02-entrypoints.md`](02-entrypoints.md)：把 §3.8 那三种入口逐个走通，理解它们如何复用同一个内核。

> **配套阅读建议**：本篇读完后先别看 03，先花 10 分钟执行附录 B 里的第 1、3、6 条命令。
> 亲手看到「`run_conversation` 不在 `run_agent.py` 里」「工具是自己注册的」「prompt 是三段拼的」，
> 比读十遍文字更有用。
