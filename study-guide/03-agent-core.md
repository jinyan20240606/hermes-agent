# 03 · 核心引擎：AIAgent 与 Turn Loop

> 目标：吃透 `AIAgent` 的组装方式、一次会话的完整相位划分，以及消息流不变量。

---

## 1. AIAgent 的组装方式

[`run_agent.py`](../run_agent.py:1) 是公共门面。`AIAgent` 由多个 mixin 拼装而成：

| Mixin | 文件 | 职责 |
|---|---|---|
| 构造 | [`agent/agent_init.py`](../agent/agent_init.py:1) | `init_agent()` |
| turn 门面 | [`agent/turn_facade.py`](../agent/turn_facade.py:1) | `run_conversation()` / `chat()` |
| 客户端生命周期 | [`agent/client_lifecycle.py`](../agent/client_lifecycle.py:1) | API client 建立/销毁 |
| 流式交付 | [`agent/stream_delivery.py`](../agent/stream_delivery.py:1) | 流式输出 |
| 会话持久化 | [`agent/session_persistence.py`](../agent/session_persistence.py:1) | 写库 |
| 压缩 | [`agent/compression_facade.py`](../agent/compression_facade.py:1) | 上下文压缩门面 |
| turn 租约 | [`agent/turn_facade_lease.py`](../agent/turn_facade_lease.py:1) | 跨进程会话 turn 租约 |

来源：[`agent/AGENTS.md`](../agent/AGENTS.md:7)

### 1.1 构造参数（约 60 个，常用的这些）

```python
AIAgent(
    base_url="...", api_key="...", provider="...",
    api_mode="chat_completions" | "codex_responses" | ...,
    model="",                       # 空 → 稍后从 config/provider 解析
    max_iterations=500,             # 与子代理共享
    enabled_toolsets=[...] / disabled_toolsets=[...],
    quiet_mode=False,
    save_trajectories=False,
    platform="cli" | "telegram" | ...,
    session_id="...",
    skip_context_files=False,
    skip_memory=False,
    credential_pool=None,
)
```

### 1.2 两个入口方法

```python
# 简单接口：返回最终响应字符串
response = agent.chat("帮我修 main.py 的 bug")

# 完整接口：返回 final_response + messages 等
result = agent.run_conversation(
    user_message="...",
    system_message=None,        # 省略则自动构建
    conversation_history=None,  # 省略则从 session 载入
    task_id=None,
)
```

`AIAgent.run_conversation` 会先取得 **session turn 租约**（`turn_facade_lease.py`），
再转发给 [`agent/conversation_loop.py`](../agent/conversation_loop.py:1) 的 `run_conversation`。

---

## 2. Turn Loop 的骨架

整个循环是**同步的**，带中断检查、预算追踪，以及一次「宽限调用」（grace call）：

```python
while (api_call_count < self.max_iterations and self.iteration_budget.remaining > 0) \
        or self._budget_grace_call:
    if self._interrupt_requested: break
    response = client.chat.completions.create(model=model, messages=messages, tools=tool_schemas)
    if response.tool_calls:
        for tc in response.tool_calls:
            messages.append(tool_result_message(handle_function_call(tc.name, tc.args, task_id)))
        api_call_count += 1
    else:
        return response.content
```

来源：[`agent/AGENTS.md`](../agent/AGENTS.md:23)

关键点：
- **iteration budget**：父代理与子代理共享；耗尽后仍有一次 `_budget_grace_call`
- **`max_iterations` 默认 500**
- 消息用 OpenAI 格式 `{"role": "system|user|assistant|tool", ...}`
- 推理内容存在 `assistant_msg["reasoning"]`

---

## 3. 相位拆分：`agent/turn_*.py`

**这是本项目最值得学习的工程模式**：每一次迭代的每个阶段都是一个独立 sibling 模块，
所以「改 overflow 处理」只会碰到一个约 600 行的文件，而不是在万行大文件里翻找。

| 相位模块 | 职责 |
|---|---|
| [`turn_preflight.py`](../agent/turn_preflight.py:1) / [`turn_preflight_gate.py`](../agent/turn_preflight_gate.py:1) | 预检（含预压缩判定） |
| [`turn_iteration_prep.py`](../agent/turn_iteration_prep.py:1) | 迭代准备（announce/begin/prepare/apply_retry_restarts） |
| [`turn_request_assembly.py`](../agent/turn_request_assembly.py:1) / [`turn_api_request.py`](../agent/turn_api_request.py:1) | 组装请求 |
| [`turn_api_call.py`](../agent/turn_api_call.py:1) | 发起 API 调用（含中断处理、限速守卫） |
| [`turn_api_error.py`](../agent/turn_api_error.py:1) | API 错误处理 |
| [`turn_response_intake.py`](../agent/turn_response_intake.py:1) | 规范化模型响应 |
| [`turn_response_check.py`](../agent/turn_response_check.py:1) | 响应校验 |
| [`turn_empty_response.py`](../agent/turn_empty_response.py:1) | 空响应处理 |
| [`turn_tool_round.py`](../agent/turn_tool_round.py:1) / [`turn_tool_validation.py`](../agent/turn_tool_validation.py:1) | 工具轮次（校验/封顶/去重/执行） |
| [`turn_overflow.py`](../agent/turn_overflow.py:1) | 上下文溢出 |
| [`turn_truncation.py`](../agent/turn_truncation.py:1) | 截断处理 |
| [`turn_scripted_prelude.py`](../agent/turn_scripted_prelude.py:1) | 首次模型调用前置的「脚本化工具调用」 |
| [`turn_context_compaction.py`](../agent/turn_context_compaction.py:1) | 上下文压实 |
| [`turn_recovery.py`](../agent/turn_recovery.py:1) / [`turn_recovery_autorecover.py`](../agent/turn_recovery_autorecover.py:1) / [`turn_recovery_codex.py`](../agent/turn_recovery_codex.py:1) | 恢复（含耗尽后的 wait-and-retry 阶梯） |
| [`turn_retry_state.py`](../agent/turn_retry_state.py:1) | 重试状态 |
| [`turn_stop_gates.py`](../agent/turn_stop_gates.py:1) | 停止门控 |
| [`turn_liveness.py`](../agent/turn_liveness.py:1) | 存活检测 |
| [`turn_usage.py`](../agent/turn_usage.py:1) | 用量统计 |
| [`turn_final_response.py`](../agent/turn_final_response.py:1) | 最终响应 |
| [`turn_finalizer.py`](../agent/turn_finalizer.py:1) | turn 收尾 |
| [`turn_summary.py`](../agent/turn_summary.py:1) | 摘要 |

查找某个相位的函数：`grep -rn "def X" agent/turn_*.py`。

> 这些相位在 `conversation_loop.py` 顶部**绑定 import 时**载入，这样源码树中途被替换时
> 不会在 turn 中途载入「版本错配」的相位
> （[`agent/conversation_loop.py`](../agent/conversation_loop.py:41)）。

---

## 4. 一次迭代的 8 个步骤（对照 `agent-loop.md`）

```text
run_conversation()
  1. 若未提供则生成 task_id
  2. 把 user 消息追加到对话历史
  3. 构建或复用已缓存的 system prompt
  4. 检查是否需要预检压缩（>50% 上下文）
  5. 从对话历史构建 API 消息
       - chat_completions: 直接用 OpenAI 格式
       - codex_responses:  转换为 Responses API input items
       - anthropic_messages: 经 anthropic_adapter.py 转换
  6. 注入临时 prompt 层（预算告警、上下文压力）
  7. 若在 Anthropic 上则加 prompt caching 标记
  8. 发起可中断的 API 调用
  9. 解析响应：
       - 有 tool_calls：执行 → 追加结果 → 回到第 5 步
       - 文本响应：持久化会话 → 必要时刷记忆 → 返回
```

来源：[`agent-loop.md`](../website/docs/developer-guide/agent-loop.md:59)

---

## 5. 消息格式与交替规则

### 5.1 格式

```python
{"role": "system", "content": "..."}
{"role": "user", "content": "..."}
{"role": "assistant", "content": "...", "tool_calls": [...]}
{"role": "tool", "tool_call_id": "...", "content": "..."}
```

### 5.2 严格交替（provider 会校验，畸形历史会被拒）

- system 之后：`User → Assistant → User → Assistant → ...`
- 工具调用期间：`Assistant(with tool_calls) → Tool → Tool → ... → Assistant`
- **绝不**两个 assistant 连续
- **绝不**两个 user 连续
- **只有** `tool` 角色可以有连续条目（并行工具结果）

来源：[`agent-loop.md`](../website/docs/developer-guide/agent-loop.md:94)

### 5.3 唯一的中途注入例外

`/steer` 是唯一合法的「循环中途合成的 user 消息」：它作为**独立 user 行**在 tool 结果之后送达
（`assistant(tool_calls) → tool → user` 在所有 provider 路径上合法）。
它**绝不**糊在已持久化的 tool 行上——那样 append-only 持久化会与实时请求产生分歧。
正因为这个约束，cron 投递活在自己的会话里（[`agent/AGENTS.md`](../agent/AGENTS.md:66)）。

---

## 6. 可中断的 API 调用

API 请求被包在 `_interruptible_api_call()` 里：真实 HTTP 调用跑在后台线程，主线程同时监听
「响应就绪 / 中断事件 / 超时」。

```text
┌────────────────────────────────────────────────────┐
│  主线程                         API 线程            │
│                                                    │
│   wait on:                     HTTP POST           │
│    - response ready     ───▶   to provider         │
│    - interrupt event                               │
│    - timeout                                       │
└────────────────────────────────────────────────────┘
```

来源：[`agent-loop.md`](../website/docs/developer-guide/agent-loop.md:110)

**停止的扇出规则**：一轮的硬中断只到达 `_active_children`；后台委派单元在派发时就已脱离，
所以每一个停止面（gateway `/stop` 的 busy 与 idle 路径、TUI `session.interrupt`、ACP `cancel`、
CLI `/stop`）都必须额外调用 `async_delegation.interrupt_for_session`
（[`tools/AGENTS.md`](../tools/AGENTS.md:147)）。

---

## 7. 工具调用执行（`agent/tool_executor.py`）

[`agent/tool_executor.py`](../agent/tool_executor.py:1) 负责顺序与并发派发：

- 每个调用的身份以 `_ToolCallRef` 传递
- 两种执行器最终汇入同一条 **observe → commit → project** 流水线，
  因此工具结果的 wire 形状只生产一次
- 函数第一个参数是父 `AIAgent`，`run_agent` 保留薄包装，并通过 `_ra()` 延迟触达

### 7.1 Agent 级工具（inline tools）

`todo`、`memory` 这类需要活 `AIAgent` 状态（stores、callbacks、session DB）的工具，
**绕过工具注册表**，在 `handle_function_call()` 之前被 [`agent/inline_tool_executors.py`](../agent/inline_tool_executors.py:1)
的 `INLINE_TOOL_EXECUTORS` 表拦截。

添加一个：在该表注册（**不要写 `if name == ...` 链**），
[`tools/todo_tool.py`](../tools/todo_tool.py:1) 是范例模式。

这个表取代了两条手工维护、已经漂移的 if/elif 链
（`invoke_tool` 与 `execute_tool_calls_sequential`）。

---

## 8. 消息流不变量（每次改动都会被对照审查）

来自 [`agent/AGENTS.md`](../agent/AGENTS.md:55)：

1. **Prompt caching 不得破坏。**
   绝不中途改动过去上下文、切换 toolsets、重载记忆、重建 system prompt。
   system prompt 在一次会话生命周期内**逐字节稳定**；唯一的上下文变更是 compression。
   必须中途注入内容时，搭 **user 消息或 tool 结果**的车：
   - skill slash 命令（[`agent/skill_commands.py`](../agent/skill_commands.py:1)）以 user 消息注入
   - 子目录 `AGENTS.md` 提示（[`agent/subdirectory_hints.py`](../agent/subdirectory_hints.py:1)）
     追加到 tool 结果（首尾截断，超过 `_MAX_HINT_CHARS = 32_000`）

2. **严格角色交替**（见 5.2），唯一例外是 `/steer`。

3. **Context files**（[`agent/prompt_builder.py`](../agent/prompt_builder.py:1)）
   只在启动时从 CWD 加载且有上限。绝不把安装树里的 `AGENTS.md` 当项目上下文加载；
   子目录提示会拒绝工作目录外的路径，避免 `~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md` 混入。

4. **`_last_resolved_tool_names` 是 `model_tools.py` 里的进程级全局变量。**
   [`tools/delegate_tool.py`](../tools/delegate_tool.py:1) 的 `_run_single_child()` 会在子代理执行前后
   save/restore 它；读取它的代码在子代理运行期间可能看到暂时陈旧的值。

---

## 9. 测试约定

- Loop/相位测试放 `tests/agent/`
- **patch 相位真正读取的绑定**（siblings 常在函数内 `from run_agent import X`）
- 断言**消息形状不变量**（交替性、system prompt 字节稳定），而不要快照 prompt 文本

---

## 10. 本篇小结与下一步

- `AIAgent` = facade + mixins；turn loop 在 `conversation_loop.py`，相位在 `agent/turn_*.py`。
- 一次迭代 8 步；消息严格交替；唯一例外是 `/steer`。
- Agent 级工具走 `INLINE_TOOL_EXECUTORS`，不走注册表。
- 缓存铁律是这里最重要的一条规矩。

下一步 → [`04-prompt-and-caching.md`](04-prompt-and-caching.md)：system prompt 怎么分层组装，缓存边界在哪里。
