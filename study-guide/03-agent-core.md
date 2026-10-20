# 03 · 核心引擎：AIAgent 与 Turn Loop

> **读法**：这是全套材料里**代码密度最高**的一章。顺序是：
> **§0 前置**（先建立「一次 turn 是什么」的心智模型）→ **§1 AIAgent 的结构** → **§2 turn 的三层调用栈**
> → **§3 相位流水线的运行机制**（本篇最有价值的一节，解释「32 个文件怎么拼成一个循环」）
> → **§4 一轮迭代的完整时序** → **§5 工具轮次** → **§6 中断与预算** → **§7 消息流不变量**
> → **§8 失败与收尾** → **§9 自检**。
>
> 读完你应该能回答：**「模型说『我要调用 read_file』之后，到结果被塞回 messages，中间经过哪些函数？」**

**本篇相对旧版新增**：§1.2 真实 `__init__` 构造链、§2 `_LoopState` + `_run_phase` 的自省机制
（旧版完全没有，但这是理解本模块的钥匙）、§3.3 verdict 协议、§4 完整时序图（含 retry 内层循环）、
§5 工具派发五级优先表、§6 预算/租约/宽限调用、§8 失败矩阵、§10 自检题。

---

## 0. 前置概念

### 0.1 三个词必须先分清

仓库里 `turn`、`iteration`、`conversation` 三个词的用法是严格区分的，混用会看不懂代码：

| 词 | 含义 | 边界 | 代码 |
|---|---|---|---|
| **conversation** | 一次会话的**全部**消息历史 | 从建会话到关会话 | `session_id`、`SessionDB` |
| **turn** | 用户说一句话 → agent 给出最终答复 | 一次 `run_conversation()` 调用 | `turn_id`、`_LoopState` |
| **iteration** | turn 内的一次模型调用 | 一次 HTTP 请求 +（可能）一轮工具 | `api_call_count` |

关系：**1 conversation = N turn；1 turn = M iteration（M ≥ 1）**。

前端类比：conversation ≈ 整个聊天室的历史；turn ≈ 你发一条消息到对方回完；
iteration ≈ 对方「思考一次」，中间可能去查资料（工具）再思考。

**为什么这个区分重要**：因为预算、租约、压缩的计量单位各不相同：

| 机制 | 计量单位 | 为什么 |
|---|---|---|
| `max_iterations` / `IterationBudget` | **iteration** | 防止无限工具循环 |
| session turn 租约（`turn_facade_lease`） | **turn** | 防止两个进程同时写同一会话 |
| 上下文压缩 | **conversation** 的消息数组 | 压缩的是整段历史 |

### 0.2 一次 turn 里 agent 到底在做什么

剥掉所有工程包装（[`agent/AGENTS.md`](../agent/AGENTS.md:21) 给了等价伪代码）：

```python
while (api_call_count < max_iterations and iteration_budget.remaining > 0) or budget_grace_call:
    response = llm(messages, tools)
    if response.tool_calls:
        for tc in response.tool_calls:
            messages.append(tool_result(handle_function_call(tc.name, tc.args)))
        api_call_count += 1
    else:
        return response.content
```

**真身就是这 8 行**。本篇后面所有内容，都是「这 8 行要健壮地跑在真实世界里，需要补什么」。

需要补的东西，一一对应真实世界的病：

| 真实世界的病 | 补的东西 | 在哪 |
|---|---|---|
| 网络会断、限速会来 | retry 内层循环 | §4.3 |
| 上下文会爆 | preflight 压缩网关 | §4.2 |
| 用户会中途喊停 | 中断事件 + 检查点 | §6.2 |
| 进程会被杀 | 工具调用**先持久化再执行** | §5.2 |
| 模型会幻想不存在的工具 | 工具名校验 | §5.1 |
| 模型会返回空、会截断 | 空响应/截断恢复 | §8 |
| 两个进程会抢同一会话 | 跨进程 turn 租约 | §6.1 |
| 500 轮之后要能解释花了多少钱 | 用量统计 + 收尾 | §8.3 |

**先记住这张表**，后面的文件清单就有意义了。

### 0.3 为什么是同步的

`AIAgent.run_conversation()` 是**完全同步**的函数，没有 `async`。

前端对比：这不是「老土」，是刻意选择。

| 维度 | 同步（本仓库） | asyncio |
|---|---|---|
| 中断 | 事件 + 检查点，任意线程可设 | 需要 `CancelledError` 传播，易吞 |
| 工具 | 直接阻塞调用（`subprocess`、`requests`） | 要 `run_in_executor` 包一层 |
| 调试 | 栈就是调用栈 | 需要 `await` 链追踪 |
| 网关 | 用线程池承载多会话 | 天然并发 |

所以分工是：**内核同步，外壳异步**。`GatewayRunner` / ACP server 是 `async` 的，
它们把同步的 `run_conversation` 丢进线程池（[`02-entrypoints.md`](02-entrypoints.md) §6、§8）。

---

## 1. AIAgent 的结构

### 1.1 门面 + 14 个 mixin

[`run_agent.py`](../run_agent.py:214)：

```python
class AIAgent(
    ClientLifecycleMixin, StreamDeliveryMixin, StatusOutputMixin, ApiRequestHooksMixin,
    ApiErrorSummaryMixin, InterruptControlMixin, TurnExplainersMixin, ActivityTrackingMixin,
    RateLimitCreditsMixin, SessionPersistenceMixin, CompressionFacadeMixin, TurnFacadeMixin,
    VisionMessagePrepMixin, ReasoningParamsMixin,
):
    """AI Agent with tool calling capabilities."""
```

14 个 mixin，每个负责一个横切主题：

| Mixin | 文件 | 职责 |
|---|---|---|
| `ClientLifecycleMixin` | [`agent/client_lifecycle.py`](../agent/client_lifecycle.py:1) | API client 建立/销毁/切换 provider |
| `StreamDeliveryMixin` | [`agent/stream_delivery.py`](../agent/stream_delivery.py:1) | 流式 delta 的交付与消费 |
| `StatusOutputMixin` | [`agent/status_output.py`](../agent/status_output.py:1) | `_vprint` / `_safe_print` / 状态行 |
| `ApiRequestHooksMixin` | [`agent/api_request_hooks.py`](../agent/api_request_hooks.py:1) | `pre/post_api_request` 钩子 |
| `ApiErrorSummaryMixin` | [`agent/api_error_summary.py`](../agent/api_error_summary.py:1) | 错误归类与摘要 |
| `InterruptControlMixin` | [`agent/interrupt_control.py`](../agent/interrupt_control.py:1) | `_interrupt_requested` 等 |
| `TurnExplainersMixin` | [`agent/turn_explainers.py`](../agent/turn_explainers.py:1) | 「为什么停了」的可读解释 |
| `ActivityTrackingMixin` | [`agent/activity_tracking.py`](../agent/activity_tracking.py:1) | `_touch_activity` 心跳（网关超时防线） |
| `RateLimitCreditsMixin` | [`agent/rate_limit_credits.py`](../agent/rate_limit_credits.py:1) | 限速/额度处理 |
| `SessionPersistenceMixin` | [`agent/session_persistence.py`](../agent/session_persistence.py:1) | 写库、增量持久化 |
| `CompressionFacadeMixin` | [`agent/compression_facade.py`](../agent/compression_facade.py:1) | 压缩门面 |
| `TurnFacadeMixin` | [`agent/turn_facade.py`](../agent/turn_facade.py:1) | `run_conversation` / `chat` |
| `VisionMessagePrepMixin` | [`agent/vision_message_prep.py`](../agent/vision_message_prep.py:1) | 图片消息预处理 |
| `ReasoningParamsMixin` | [`agent/reasoning_params.py`](../agent/reasoning_params.py:1) | reasoning effort 参数映射 |

**为什么要拆 14 个？** 因为 `run_agent.py` 曾经是一个万行 god file。
拆分标准是「横切主题」，不是「功能模块」—— `stream_delivery` 贯穿整个 turn，
`session_persistence` 也贯穿整个 turn，它们是**正交的**，所以必须是 mixin 而不是相位。

### 1.2 `__init__` 是一个转发器

[`run_agent.py`](../run_agent.py:280)：

```python
def __init__(self, ...约 60 个参数...):
    init_kwargs = {k: v for k, v in locals().items() if k not in ("self", "tool_delay")}
    from agent.agent_init import init_agent
    init_agent(self, **init_kwargs)
```

`locals()` 收集全部参数再转交 —— **一个参数都不用手写两遍**。这是 god file 拆分时
避免「加参数忘了某处」的标准手法。

[`agent/agent_init.py`](../agent/agent_init.py:2361) 的 `init_agent` 用**表驱动**做赋值：

```python
_PASSTHROUGH_PARAMS = (...)          # 直接 setattr
_GATEWAY_IDENTITY_PARAMS = (...)     # 网关身份相关
```

而不是 60 行 `self.x = x`。**表驱动 > 重复语句**，这是本仓库反复出现的模式
（对比 [`02-entrypoints.md`](02-entrypoints.md) §4.4 的 `_CHAT_PASSTHROUGH`）。

### 1.3 两个入口方法

```python
# 简单接口：返回最终响应字符串
response = agent.chat("帮我修 main.py 的 bug")

# 完整接口：返回 result dict
result = agent.run_conversation(
    user_message="...",
    system_message=None,        # 省略则自动构建/复用
    conversation_history=None,  # 省略则从 session 载入
    task_id=None,
)
```

[`chat`](../agent/turn_facade.py:220) 的实现只有一行：

```python
def chat(self, message: str, stream_callback=None) -> str:
    return self.run_conversation(message, stream_callback=stream_callback)["final_response"]
```

**`run_conversation` 返回 dict 而不是字符串**，因为调用方需要知道「成功了吗」「为什么停」
「用了多少 token」。`chat` 是给不在乎这些的调用方的糖。

### 1.4 常用构造参数

约 60 个参数里，日常会碰的：

```python
AIAgent(
    base_url="...", api_key="...", provider="...",
    api_mode="chat_completions" | "codex_responses" | "anthropic_messages" | "codex_app_server",
    model="",                    # 空 → 稍后从 config/provider 解析
    max_iterations=500,          # 与子代理共享预算
    enabled_toolsets=[...] / disabled_toolsets=[...],
    quiet_mode=False,
    platform="cli" | "telegram" | ...,
    session_id="...",
    skip_context_files=False,    # True → 不注入 AGENTS.md/SOUL.md
    skip_memory=False,           # True → 不注入记忆
    credential_pool=None,
)
```

`skip_context_files` / `skip_memory` 在 cron 里会被置 True（[`12-cron-and-kanban.md`](12-cron-and-kanban.md)）——
**定时任务的 agent 不该继承你此刻的项目上下文**。

---

## 2. turn 的三层调用栈

一次 turn 从外壳调用进来，会穿过三层：

```text
外壳（CLI / Gateway / TUI / ACP）
  │
  ├─[1] AIAgent.run_conversation          ← TurnFacadeMixin：准入、租约、作用域
  │       agent/turn_facade.py:22
  │
  ├─[2] conversation_loop.run_conversation ← 边界导出、失败 turn 收尾
  │       agent/conversation_loop.py:1709
  │
  └─[3] _run_conversation_turn            ← 真正的 while 循环
          agent/conversation_loop.py:1547
```

### 层 [1]：`TurnFacadeMixin.run_conversation`

[`agent/turn_facade.py`](../agent/turn_facade.py:22) 做的是「**进入 turn 前的社会治理**」，
按 docstring：

> Turn admission around `conversation_loop.run_conversation`: durable cross-process session turn
> lease + refresher thread and liveness watchdog, relay/accounting/portal scopes, and balanced
> start/finish marks.

具体顺序（这段代码值得逐行读，它是「一个 turn 的仪式」）：

```python
try:
    _review_queue.note_turn_started()                      # ① 平衡计数

    admission = admit_durable_turn_lease(...)              # ② 跨进程租约
    if admission.early_result is not None:
        carry_unadmitted_user_message(...)                 # ③ 没进 turn 也要保住用户消息
        return admission.early_result

    relay_lease = SESSION_COORDINATOR.acquire_conversation(...)   # ④ 中继作用域
    relay_turn  = SESSION_COORDINATOR.begin_turn(relay_lease, ...)
    start_task_run(**task_context)                         # ⑤ 观测

    token         = set_conversation_context(self._conversation_root_id())    # ⑥ ContextVar
    affinity_token = set_affinity_scope(...)
    acct_token    = set_accounting_context(db, session_id)

    with bind_subagent_parent(self), scoped_runtime_main({}), track_in_interrupt_scope(self):
        if lease is not None:
            lease.start()                                   # ⑦ 启动心跳线程
        result = run_conversation(...)                      # ⑧ 进层 [2]
finally:
    ...每个 token 都无条件 reset...
```

四个必须理解的点：

**① `note_turn_started()` 必须是 try 的第一句。**
这样 `finally` 里的 `note_turn_finished()` 才能平衡**每一个**退出路径（包括早退）。
注释直说了：`First statement of the try so the finally's note_turn_finished balances every exit.`

**② `admit_durable_turn_lease` 失败也要保住用户消息。**
`carry_unadmitted_user_message` —— 因为「用户的这句话」已经被平台确认收到了，
如果 turn 没跑就把消息丢了，用户在界面上会看到自己说的话蒸发。

**③ 租约是「持久化 + 跨进程」的，不是内存锁。**
[`admit_durable_turn_lease`](../agent/turn_facade_lease.py:297) 的注释解释了一个非显然的设计：

```python
# A session id without a row still takes the lease: client-addressed ids (API server
# X-Hermes-Session-Id, /v1/runs session_id, fingerprint-derived chat ids) are not
# process-unique, and the first turn creates the row mid-turn, so a second writer would
# otherwise find the row, take an unheld lease and interleave its turn into this one.
```

**「会话行还不存在」也必须占锁。** 否则第一个 turn 正在建行，第二个写者进来看到
「行存在但没人持锁」→ 两个 turn 交错写同一个会话。

holder 字符串里带的东西也很有意思：

```python
holder = f"pid={os.getpid()}{holder_namespace_token()}:turn={relay_turn_id}:platform={platform}"
```

`pid` + **pidns token** —— 因为容器里不同 namespace 的 PID 1 会撞。这是
「用 PID 做进程身份」的经典坑。

**④ ContextVar 有六个，且必须逐个 reset。**
`token`（portal 会话）、`affinity_token`（host 声明的亲和域）、`acct_token`（用量记账）……
注释：

```python
# Scope tokens start None: early returns leave the try before the set_*() calls and
# the finally resets each one unconditionally.
```

`None` 初始值 + 无条件 reset = 无论在哪一步失败都不会泄漏作用域。

### 层 [2]：`conversation_loop.run_conversation`

[`agent/conversation_loop.py`](../agent/conversation_loop.py:1709) 只有 60 行，但它承担两件
「必须覆盖所有出口」的职责：

```python
agent._turn_user_intervened = False
with native_turn_images(user_message):
    try:
        result = _run_conversation_turn(...)
    finally:
        end_voice_turn_route(agent)

result = export_current_turn_boundary(agent, result, user_message)
result["user_intervened"] = bool(agent._turn_user_intervened)
_close_durable_failed_turn(agent, result)
return result
```

**① `export_current_turn_boundary` 的存在理由**（docstring 原文）：

> Every envelope that leaves the loop — success, partial/error, interrupt, retry-exhausted,
> tool-limit, preflight timeout, codex runtime — passes through here, so the
> `{turn_id, current_turn_user_idx}` pair is stamped beside the exact `messages` it addresses,
> after every history rewrite including post-turn micro-compaction.

翻译：**这个 turn 从哪条消息开始**，必须在**所有历史改写完成之后**才盖戳。
因为在压缩之后，索引会变。如果先盖戳后压缩，`current_turn_user_idx` 就指向错的行。

**② `_close_durable_failed_turn` 治的是什么病**（docstring 是极好的案例）：

```python
"""Append a Hermes-authored assistant boundary when a failed turn left ``user`` as the
durable conversation tail (in place, on ``result["messages"]`` and in SessionDB).

The terminal-failure paths (content-policy refusal, ``_Trunc.end_turn``, retry exhaustion,
interrupt before any assistant text) persist the accepted user row and return without
reaching ``finalize_turn``; the next prompt then appends a second user row and
``repair_message_sequence`` merges the failed request into the new one.
"""
```

翻译：turn 失败了、用户消息已经落库、但没有 assistant 行收尾 → 下一条用户消息会
**两个 user 连排** → 序列修复逻辑会把上次失败的请求并进这次 → **模型看到「一句话问了两个问题」**。

解法：**失败也要写一条 assistant 边界的行**（内容是 `failed_turn_notice(...)`）。
这是「append-only 日志必须永远有合法尾巴」的必然要求。

它还有两个精妙的排除条件：

```python
if result.get("compression_exhausted") or result.get("compression_deferred") \
        or result.get("failure_reason") == "context_overflow":
    return
```

**上下文溢出不能补写** —— 往一个已经超限的会话里再 append 一行，就是 #1630 那个增长死循环。

以及幂等性：

```python
if db.latest_conversation_role(session_id) != "user":
    return
```

**以「库里真实的尾巴」为幂等键**，而不是内存标志位。这样重投递、或者尾巴已被另一个写者
关掉的情况，都是 no-op。

### 层 [3]：`_run_conversation_turn`

[`agent/conversation_loop.py`](../agent/conversation_loop.py:1547) 是 while 循环所在地。
它的结构（简化后仍是真实形状）：

```python
# ---- A. per-turn 重置 ----
agent._last_compaction_in_place = agent._last_compression_attempt_recorded = False
begin_fast_mode_turn(agent, conversation_history)
agent._try_refresh_env_client_credentials()      # 采用 .env 的新凭据

# ---- B. 构建 turn context（会 mutate agent）----
try:
    _ctx = build_turn_context(agent, user_message, system_message, ...)
except PreflightCompressionTimedOut as e:
    return _preflight_timeout_result(agent, e, conversation_history)

# ---- C. per-turn 状态清零（网关会缓存 agent 跨 turn）----
agent._delivered_interim_texts = set()
agent._incremental_persistence_failed = False
agent._last_persistence_error_cause = None
agent._compression_adoption_failed = False
agent._ephemeral_reasoning_off = False
agent._auth_pool_refresh_counts = {}
agent._last_turn_usage = None

# ---- D. 建 _LoopState ----
s = _LoopState(...)

# ---- E. 特殊 runtime 直通 ----
if agent.api_mode == "codex_app_server" and (r := _codex_app_server_turn(agent, s)): return r

# ---- F. 脚本化前奏（在第一次模型调用之前）----
_prelude_action, _prelude_result = play_prelude(agent, s, prelude)
if _prelude_action == "return": return _prelude_result

# ---- G. 主循环 ----
while _prelude_action != "break" and (
    (s.api_call_count < agent.max_iterations and agent.iteration_budget.remaining > 0)
    or agent._budget_grace_call
):
    ...

# ---- H. 收尾 ----
result = finalize_turn(agent, **{...inspector 反射取字段...})
```

**为什么 B 和 C 都必要？** B 构建「这个 turn 的上下文」，C 清「上个 turn 的残留」。
注释给出根因：

```python
# Per-turn agent state (the gateway caches agents across turns, so none of this may
# leak into the next message)
```

**网关把 agent 对象缓存起来跨 turn 复用**（省构造成本）。代价是：**所有 turn 级状态必须显式清零**。
这是一条很容易被新代码破坏的隐含契约 —— 你加一个 `self._my_flag`，忘了在 C 里清，
就变成一个「第一次正常、第二次开始行为不对」的 bug。

**为什么 E 要在 F 之前？** `codex_app_server` 模式下整个 turn 交给子进程，
连 prelude 都不该由主循环播放。

**H 里那段 `inspect.signature` 反射**：

```python
result = finalize_turn(agent, **{
    name: getattr(s, name)
    for name in inspect.signature(finalize_turn).parameters if name != "agent"
})
```

这是 `_run_phase` 的**同款手法**（§3.2）：用函数签名决定传什么，而不是手写参数表。
好处是加一个参数只改函数签名，不改调用点。

---

## 3. 相位流水线的运行机制（本篇最关键的一节）

旧版文档给了 32 个文件的名字，但**没解释它们怎么拼成一个循环**。这一节补上。

### 3.1 33 个 `turn_*.py`

```bash
$ ls agent/turn_*.py | wc -l
33
```

按职责分组（数字是文件数）：

| 组 | 文件 | 何时跑 |
|---|---|---|
| **准入/上下文** | `turn_facade.py`、`turn_facade_lease.py`、`turn_context.py` | turn 开始前 |
| **迭代骨架** | `turn_iteration_prep.py`、`turn_retry_state.py` | 每次迭代 |
| **请求装配** | `turn_request_assembly.py`、`turn_api_request.py` | 每次迭代 |
| **守卫** | `turn_preflight.py`、`turn_preflight_gate.py`、`turn_liveness.py` | 请求前 |
| **调用** | `turn_api_call.py` | 每次迭代 |
| **错误** | `turn_api_error.py`、`turn_loop_errors.py`、`turn_failure_copy.py` | 出错时 |
| **响应** | `turn_response_intake.py`、`turn_response_check.py`、`turn_empty_response.py`、`turn_truncation.py` | 响应后 |
| **工具** | `turn_tool_round.py`、`turn_tool_validation.py` | 有 tool_calls 时 |
| **压缩** | `turn_context_compaction.py`、`turn_overflow.py` | 压力超阈值时 |
| **恢复** | `turn_recovery.py`、`turn_recovery_autorecover.py`、`turn_recovery_codex.py` | 重试耗尽后 |
| **停止判定** | `turn_stop_gates.py` | 模型给出文本时 |
| **前奏** | `turn_scripted_prelude.py` | 首次模型调用前 |
| **收尾** | `turn_final_response.py`、`turn_finalizer.py`、`turn_summary.py`、`turn_usage.py` | turn 结束 |
| **杂** | `turn_author.py`、`turn_explainers.py` | 辅助 |

### 3.2 核心机制：`_LoopState` + `_run_phase`

这是理解整个模块的钥匙。**循环里的「局部变量」被显式做成一个 dataclass**：

[`agent/conversation_loop.py`](../agent/conversation_loop.py:1381)：

```python
class _LoopState:
    """Every local the turn loop threads through the phase helpers in ``agent/turn_*.py``.

    Helpers take the loop locals they need as keyword arguments named like these fields and
    return a verdict whose non-``action``/``result`` fields carry the same names;
    :func:`_run_phase` passes and copies them back by name, so a new helper input/output
    needs a field here and nothing else."""
```

拆成三句话：

1. 每个相位函数**不要**拿整个 `agent` 就该够了吗？不够 —— 它们需要「循环的局部状态」：
   `messages`、`api_call_count`、`compression_attempts`、`final_response`……
2. 如果把这些全挂在 `self` 上，会污染 agent 的跨 turn 状态（见 §2 层 [3] C 的教训）。
3. 所以：**做成一个 `_LoopState` 对象，按名字传递**。

`_run_phase` 是执行器：

```python
def _run_phase(fn, agent, state: _LoopState, **extra):
    """Call phase helper ``fn`` with the loop locals it names, copy its verdict fields back."""
    params = _PHASE_PARAMS.get(fn)
    if params is None:
        params = _PHASE_PARAMS[fn] = tuple(
            p for p in inspect.signature(fn).parameters if p != "agent"
        )
    verdict = fn(agent, **{n: extra[n] if n in extra else getattr(state, n) for n in params})
    latched = _LATCHED_VERDICT_FIELDS.get(getattr(fn, "__name__", ""), ())
    for f in fields(verdict):
        if f.name in ("action", "result"):
            continue
        value = getattr(verdict, f.name)
        if f.name not in latched:
            setattr(state, f.name, value)
        elif value:
            setattr(state, f.name, True)     # ← 锁存：只能置 True，不能被清 False
    return verdict
```

三个设计点，每一个都是为了避免一类 bug：

**① 按签名反射传参（`_PHASE_PARAMS` 缓存）。**
一个相位函数声明了哪些参数，就收到哪些。**不需要参数表，也不需要 `**kwargs` 大杂烩**。
加一个输入 → 只改函数签名 + 在 `_LoopState` 加字段。

**② verdict 的字段按名字回写（`setattr(state, f.name, value)`）。**
相位函数返回一个 `XxxVerdict` dataclass，除了 `action` / `result` 之外的字段，
**名字与 `_LoopState` 的字段一一对应**，自动回写。

这就是 docstring 里那句「a new helper input/output needs a field here and nothing else」。

**③ 锁存字段（`_LATCHED_VERDICT_FIELDS`）。**

```python
_LATCHED_VERDICT_FIELDS = {"handle_api_error": frozenset({"_provider_overflow_recovery_pending"})}
```

`_provider_overflow_recovery_pending` 是「provider 说溢出了，别再信本地估算」的旗标。
它**只能被置 True，不能被清 False** —— 因为清掉它的正道是「压缩后重建的请求确实低于阈值」，
而不是「某个 error handler 顺手返回了 False」。

**这是一条极精细的规则**：普通的字段回写是覆盖，但有些字段是「一旦发生就必须记住」。
用一个字典声明哪些是锁存的，比在每个 handler 里写 `if not x: x = ...` 清楚一万倍。

### 3.3 verdict 协议：`action` 六选一

所有相位返回的 verdict 都有 `action` 字段，取值固定：

| `action` | 调用方行为 | 出现场景 |
|---|---|---|
| `"fallthrough"` | 继续下一个相位 | 正常路径、无操作 |
| `"continue"` | **回到 while 顶部**（重新迭代） | 需要重试、prelude 还有步骤 |
| `"break"` | **跳出 while**，进 finalize | 预算耗尽、持久化失败、护栏停机 |
| `"return"` | **直接返回 `result`** | 终态（超时、错误、特殊 runtime） |

看真实调用点（[`agent/conversation_loop.py`](../agent/conversation_loop.py:1651)）：

```python
if _run_phase(begin_iteration, agent, s).action == "break":
    break
_run_phase(prepare_iteration, agent, s)
_run_phase(assemble_api_request, agent, s)

_pg = _run_phase(run_preflight_gate, agent, s)
if _pg.action == "return":   return _pg.result
if _pg.action == "break":    break
if _pg.action == "continue": continue
_run_phase(announce_api_call, agent, s)
```

**`fallthrough` 是默认值，所以不必写分支。** 只有异常路径才需要判断 —— 这让主路径读起来
像一条直线。

**注意 `break` 和 `return` 的区别**：
- `break` → 走 `finalize_turn`（会补写失败边界、算用量、写总结）
- `return` → **跳过 finalize**，直接返回

所以 `return` 只用于「finalize 也做不了什么」的场景，比如 preflight 压缩超时
（此时已经没有可压缩的预算了）。

### 3.4 内层 retry 循环

主循环里还有一层：

```python
s.api_start_time, s.retry_count, s.max_retries = time.time(), 0, agent._api_max_retries
s._retry, s.finish_reason, s.response, s.api_kwargs = TurnRetryState(), "stop", None, None
s.api_request_id = agent._current_api_request_id = f"{s.turn_id}:api:{s.api_call_count}"

early_result = _run_api_retry_loop(agent, s)
if early_result is not None:
    return early_result
```

[`_run_api_retry_loop`](../agent/conversation_loop.py:1497)：

```python
while s.retry_count < s.max_retries:
    _ng = _run_phase(nous_rate_limit_guard, agent, s)   # ① 限速守卫
    if _ng.action == "return": return _ng.result
    ...
```

四层嵌套，从外到内：

```text
_run_conversation_turn        ← 主循环（iteration）
  └─ _run_api_retry_loop      ← 一次迭代内的重试（retry）
       └─ perform_api_call    ← 一次 HTTP 请求
            └─ _interruptible_api_call  ← 线程封装
```

**为什么要两层而不是一层？** 因为语义不同：

| | 迭代（iteration） | 重试（retry） |
|---|---|---|
| 触发 | 有 tool_calls，要再问模型 | 网络错误、限速、5xx |
| 消耗预算 | 是（`iteration_budget.consume()`） | 否 |
| 消息数组变化 | 追加 assistant + tool 行 | 不变 |
| 上限 | `max_iterations`（500） | `agent._api_max_retries` |

**关键：重试不吃迭代预算。** 否则网络抖动几次就把 agent 的「思考次数」耗完了。

`api_request_id` 的格式也值得注意：

```python
f"{s.turn_id}:api:{s.api_call_count}"
```

**可读的追踪 id**：`turn-abc:api:3` = 这个 turn 的第 3 次 API 调用。
出问题时 grep 日志直接能定位。

### 3.5 相位为什么在 import 时绑定

[`agent/conversation_loop.py`](../agent/conversation_loop.py:41)：

```python
# Phase helpers of the turn loop, bound at import so a source-tree swap cannot load a
# skewed phase mid-turn.
from agent.turn_api_call import handle_api_interrupt, nous_rate_limit_guard, perform_api_call
from agent.turn_api_error import handle_api_error
...
```

**「源码树中途被替换时，不会在 turn 中途载入版本错配的相位」**。

场景：`hermes update` 正在 `git checkout`，而你的 agent 正在跑一个长 turn。
如果相位是**函数内 import**，那么下一轮迭代就会 import 到**新版本**的相位，
而 `_LoopState` 的字段结构还是旧的 → 崩溃或行为错乱。

**import 时绑定 = 一个 turn 内所有相位版本一致。**

对比：siblings 通常在**函数内**延迟 import 门面（避免循环依赖）。这里是**反例**，
而且有明确理由。**规则总有例外，但例外必须写清为什么。**

---

## 4. 一轮迭代的完整时序

### 4.1 主循环体逐行

[`_run_conversation_turn`](../agent/conversation_loop.py:1648) 的循环体，按真实顺序：

```python
while ... :
    # ① 迭代开始
    if _run_phase(begin_iteration, agent, s).action == "break": break
    _run_phase(prepare_iteration, agent, s)

    # ② 装配请求（消息数组 → API 格式）
    _run_phase(assemble_api_request, agent, s)

    # ③ 前置守卫（压缩、溢出、上下文窗口检查）
    _pg = _run_phase(run_preflight_gate, agent, s)
    if _pg.action == "return":   return _pg.result
    if _pg.action == "break":    break
    if _pg.action == "continue": continue

    # ④ 宣告 + 重置重试状态
    _run_phase(announce_api_call, agent, s)
    s.api_start_time, s.retry_count, s.max_retries = time.time(), 0, agent._api_max_retries
    s._retry, s.finish_reason, s.response, s.api_kwargs = TurnRetryState(), "stop", None, None
    s.api_request_id = agent._current_api_request_id = f"{s.turn_id}:api:{s.api_call_count}"

    # ⑤ 内层重试循环（真正发 HTTP）
    early_result = _run_api_retry_loop(agent, s)
    if early_result is not None: return early_result

    # ⑥ 重试重启（如 fallback 切换了 provider/model）
    _rs = _run_phase(apply_retry_restarts, agent, s)
    if _rs.action == "break":    break
    if _rs.action == "continue": continue

    # ⑦ 响应归一化 + 校验
    try:
        _ri = _run_phase(normalize_model_response, agent, s)
        if _ri.action == "return":   return _ri.result
        if _ri.action == "continue": continue

        # ⑧ 二选一：有工具 → 工具轮次；无工具 → 文本收尾
        _v = _run_phase(
            run_tool_round if s.assistant_message.tool_calls else finish_text_response, agent, s
        )
        if _v.action == "return":   return _v.result
        if _v.action == "break":    break
        if _v.action == "continue": continue
    except Exception as e:
        if _run_phase(handle_outer_loop_error, agent, s, e=e).action == "break": break
```

**⑧ 那个三元表达式是整个循环的心脏**：

```python
run_tool_round if s.assistant_message.tool_calls else finish_text_response
```

**「有工具就继续转，没工具就收工」** —— 这就是 §0.2 那 8 行伪代码的第 6~8 行。

### 4.2 时序图

```text
┌─ 外壳 ───────────────────────────────────────────────────────────┐
│ run_conversation(user_message)                                    │
└──────────────┬───────────────────────────────────────────────────┘
               ▼
┌─ 层1 TurnFacadeMixin ────────────────────────────────────────────┐
│ note_turn_started → admit_durable_turn_lease → relay scope        │
│ → ContextVar set × 3 → lease.start()（心跳线程）                   │
└──────────────┬───────────────────────────────────────────────────┘
               ▼
┌─ 层2 conversation_loop.run_conversation ─────────────────────────┐
│ _turn_user_intervened = False                                     │
│ with native_turn_images(user_message):                            │
└──────────────┬───────────────────────────────────────────────────┘
               ▼
┌─ 层3 _run_conversation_turn ─────────────────────────────────────┐
│                                                                   │
│  A. per-turn 重置（compaction flags / fast_mode / .env 刷新）      │
│  B. build_turn_context  ← 可能抛 PreflightCompressionTimedOut      │
│  C. 7 个 turn 级状态清零（网关会缓存 agent）                        │
│  D. s = _LoopState(...)                                           │
│  E. codex_app_server 直通？（是 → return）                         │
│  F. play_prelude(...)   ← 脚本化工具调用，在首次模型调用之前         │
│                                                                   │
│  ┌──── while 迭代预算未耗尽 ────────────────────────────────────┐  │
│  │ begin_iteration                                              │  │
│  │ prepare_iteration                                            │  │
│  │ assemble_api_request      ← messages → provider 格式          │  │
│  │ run_preflight_gate        ← 压缩/溢出守卫，可 continue/break   │  │
│  │ announce_api_call                                            │  │
│  │ ┌── _run_api_retry_loop（retry ≤ _api_max_retries）───────┐   │  │
│  │ │ nous_rate_limit_guard                                   │   │  │
│  │ │ build_api_request                                       │   │  │
│  │ │ perform_api_call → _interruptible_api_call（线程）       │   │  │
│  │ │ check_api_response                                      │   │  │
│  │ │ handle_api_error（4xx/5xx/溢出 → 重试或终止）             │   │  │
│  │ └─────────────────────────────────────────────────────────┘   │  │
│  │ apply_retry_restarts      ← fallback 切换后在同一 turn 重来    │  │
│  │ normalize_model_response  ← 三种 API 模式统一成 OpenAI 形状    │  │
│  │                                                              │  │
│  │  has tool_calls?                                             │  │
│  │   ├─ 是 → run_tool_round → continue                           │  │
│  │   └─ 否 → finish_text_response → return                       │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  H. finalize_turn(...)                                            │
└──────────────┬───────────────────────────────────────────────────┘
               ▼
┌─ 层2（后半）──────────────────────────────────────────────────────┐
│ export_current_turn_boundary  ← 盖 {turn_id, current_turn_user_idx}│
│ _close_durable_failed_turn    ← 失败时补 assistant 边界            │
└──────────────┬───────────────────────────────────────────────────┘
               ▼
┌─ 层1（finally）──────────────────────────────────────────────────┐
│ lease.stop_refresher → join → clear_interrupt → release            │
│ reset ContextVar × 3 → note_turn_finished                          │
└───────────────────────────────────────────────────────────────────┘
```

### 4.3 `assemble_api_request` 干什么

三种 API 模式在内部**统一成 OpenAI 格式**，只在发出前一刻转换：

| `api_mode` | 转换 | 文件 |
|---|---|---|
| `chat_completions` | 无需转换 | — |
| `codex_responses` | messages → Responses API `input` items | [`agent/codex_responses_adapter.py`](../agent/codex_responses_adapter.py:1) |
| `anthropic_messages` | messages → Anthropic blocks | `anthropic_adapter` |
| `codex_app_server` | 整个 turn 交给子进程 | [`agent/codex_runtime.py`](../agent/codex_runtime.py:1) |

**「内核只认一种格式」** 是这层的全部意义。工具、压缩、持久化全都按 OpenAI 形状写，
只有 `assemble_api_request` 和 `normalize_model_response` 知道 provider 差异。

前端类比：这就像你在业务层永远用 `Date` 对象，只在 fetch 的 `serialize()` 里转 ISO 字符串。

### 4.4 响应归一化里的真实世界防御

[`agent/turn_response_intake.py`](../agent/turn_response_intake.py:1) 的 docstring：

> normalize the raw provider response into the assistant message, splice agent-as-provider
> projections, fire `post_api_request`, relay reasoning to the progress callback, and apply the
> incomplete-scratchpad / Codex-incomplete continuation guards.

注意 `splice agent-as-provider projections` —— 除了真模型，还有「agent 冒充 provider」的
投影路径（用于 relay / 回放）。**归一化层要同时处理两个来源**。

还有一个典型的真实世界补丁：

```python
def _coerce_content_text(raw):
    """Some OpenAI-compatible servers (llama-server) return content as dict/list, which
    crashes downstream ``.strip()``; normalize to str (multimodal lists → text parts)."""
```

注释直接点名 `llama-server`。**「OpenAI 兼容」在实践中等于「大致兼容」**，
所以有一层专门的类型强转。

---

## 5. 工具轮次

### 5.1 五个步骤（`run_tool_round`）

[`agent/turn_tool_round.py`](../agent/turn_tool_round.py:46) 的 docstring 就给了核心不变量：

> Execute one tool round in the exact original order. **Persist-before-execute is a durability
> invariant**: resume must see the executed block if a destructive tool restarts Hermes; a failed
> canonical append ends the turn rather than running tools from process-only state.

五个阶段：

```text
① 校验      validate_tool_calls        → 名字存在吗？参数能解析吗？
② 规整      expand_local_tool_batches   → 本地批量桥接展开
            _deduplicate_tool_calls / _cap_delegate_task_calls
            normalize_provider_tool_call_ids
③ 落库      stage_tool_call_message + append_message
            _flush_messages_to_session_db    ← 执行前！
④ 执行      _execute_tool_calls
⑤ 善后      compress_after_tool_results（可能触发压缩）
            _touch_activity
```

### 5.2 「先落库再执行」为什么是不变量

代码里有两道检查：

```python
try:
    _tool_turn_persisted = agent._flush_messages_to_session_db(messages, conversation_history)
except Exception as exc:
    _tool_turn_persisted = False
    agent._last_persistence_error_cause = classify_persistence_error(exc)

if _tool_turn_persisted is False:
    # Canonical append failed: never project the row or run tools from process-only
    # state; break rather than retry. No recorded cause means genuinely unknown.
    if agent._last_persistence_error_cause is None:
        agent._last_persistence_error_cause = "unknown"
    _turn_exit_reason = "session_persistence_failed"
    final_response = ""
    failed = True
    return _verdict("break")
```

**落库失败就直接结束 turn，绝不执行工具。**

原因：如果先执行了 `rm -rf`，然后落库失败，`resume` 时会看到「模型要求删，但没有任何执行记录」，
于是**再删一次**。对破坏性工具，这是灾难。

第二道防线在工具执行**之后**：

```python
if getattr(agent, "_incremental_persistence_failed", False):
    # Tool result could not be made canonical: never send the in-memory result to
    # the model or project later events from this turn.
    _turn_exit_reason = "session_persistence_failed"
    return _verdict("break")
```

**工具结果落不了库，就不要把它交给模型** —— 否则模型基于「不存在于历史里的结果」继续推理，
一旦重启，历史里没有这条结果，模型后续的推理就失去了依据。

### 5.3 无效工具名：混合批次的处理

```python
# Mixed batch: the assistant message keeps EVERY emitted call (each tool_call needs a
# matching result) while only valid ones dispatch.
_invalid_batch_calls = [
    tc for tc in assistant_message.tool_calls if tc.function.name not in agent.valid_tool_names
] if _tvv.mixed_invalid_batch else []

if _invalid_batch_calls:
    for tc in _invalid_batch_calls:
        append_message(messages, {
            "role": "tool", "name": tc.function.name,
            "tool_call_id": coalesce_tool_call_id(tc),
            "content": _invalid_tool_name_error_content(tc.function.name, agent.valid_tool_names),
        })
    assistant_message.tool_calls = [
        tc for tc in assistant_message.tool_calls if tc.function.name in agent.valid_tool_names
    ]
```

**核心约束：每个 `tool_call` 必须有且仅有一个对应的 `tool` 结果行。**
所以无效调用不能简单「过滤掉」，必须**补一条错误结果**。

这是 OpenAI 协议的结构性要求。违反它的报错通常长这样：
`messages with role 'tool' must be a response to a preceding message with 'tool_calls'`。

`_invalid_tool_name_error_content` 会把**可用工具名列表**回给模型 —— 让模型下一轮能自我纠正。

### 5.4 工具派发的五级优先级

[`agent/tool_executor.py`](../agent/tool_executor.py:1661) 的 docstring 直接列出：

> Pick the execute callable for one sequential call and start its spinner. Precedence:
> inline agent-level tools, delegate_task, context-engine tools, memory-provider tools,
> then the registry.

| 优先级 | 类型 | 例子 | 为什么在前面 |
|---|---|---|---|
| 1 | **inline agent 级工具** | `todo_list`、`memory`、`clarify` | 需要活 `AIAgent` 状态，不走注册表 |
| 2 | **`delegate_task`** | 子代理 | 需要特殊 spinner 与生命周期 |
| 3 | **context-engine 工具** | 压缩引擎自带的工具 | 由 `context_compressor` 提供 |
| 4 | **memory-provider 工具** | `hindsight_retain`、`honcho_search` | 由插件式 memory manager 提供 |
| 5 | **注册表工具** | 其余全部 | `model_tools.handle_function_call` |

**为什么 inline 工具要绕过注册表？** 因为它们需要 `agent._todo_store`、`agent.clarify_callback`
这类**只存在于活对象上**的东西。注册表的签名是 `fn(args, task_id)`，装不下。

[`agent/inline_tool_executors.py`](../agent/inline_tool_executors.py:298) 用表声明：

```python
_RAW_INLINE_TOOL_EXECUTORS: dict[str, InlineToolExecutor] = {
    "todo_list": _tool("tools.todo_tool", "todo_tool", ("todos", "todos"), ("merge", "merge", False),
                       store=lambda agent, ctx: agent._todo_store),
    "message_agent": _tool("tools.bot_mode_dm", "message_agent_tool", ...),
    "session_search": _session_search,
    "memory": _memory,
    "clarify": _tool("tools.clarify_tool", "clarify_tool", ("questions", "questions"),
                     callback=lambda agent, ctx: agent.clarify_callback),
    ...
    "delegate_task": lambda agent, args, ctx: agent._dispatch_delegate_task(args),
}
```

**「Order is the historical if/elif order of `execute_tool_calls_sequential`」** ——
这行注释说明：这张表是从两条已经漂移的手写 `if/elif` 链合并来的
（`invoke_tool` 与 `execute_tool_calls_sequential`）。

注释也记录了它们**仍然不完全一致**的地方：

```python
# ``invoke_tool`` (concurrent path) consults the memory manager right after these three
# names and before the remaining inline tools; ``message_agent`` falls through to the
# registry there (Bot Mode DM is only injected into the sequential path's schema).
```

**这是并发路径与顺序路径的真实差异**，不是可以随便抹平的冗余。改这里之前必须理解两条路径。

### 5.5 `_ToolCallRef`：一次调用的身份

[`agent/tool_executor.py`](../agent/tool_executor.py:272)：

```python
@dataclass
class _ToolCallRef:
    """Identity of one tool call as every hook / result message sees it: the (possibly
    middleware-rewritten) name and args, the task, the pairing id and the request trace."""
    name: str
    args: dict
    task_id: str
    call_id: str
    trace: list
```

**「middleware 改写过的名字和参数」** —— 关键在「改写过的」。
工具调用会经过 middleware（权限、审计、参数变换），之后**所有下游（hook、结果行）看到的是同一份**。

如果没有这个对象，就会出现「hook 看到原始参数、执行看到改写参数、结果行记的是又一个版本」，
审计就废了。

### 5.6 中断检查在工具之间

```python
for i, tool_call in enumerate(tool_calls, 1):
    if getattr(agent, "_incremental_persistence_failed", False):
        return
    # Check interrupt BEFORE each tool so a "stop" during the previous one skips the rest.
    if agent._interrupt_requested:
        if not _skip_remaining_sequential(agent, messages, tool_calls[i - 1:], ...):
            return
        break
```

**注意是「每个工具之前」，不是「每个工具之中」。**
一个 `bash` 命令跑到一半，中断不会杀死它 —— 这是刻意的：**半途杀死外部进程会留下不可预期的状态**。

而且被跳过的工具也要**补结果行**（`_skip_remaining_sequential`），否则又违反 §5.3 的配对规则。
内容里那句 `interrupt_skip_wording(agent)` 会根据 surface 给出不同措辞。

### 5.7 两个「回血」特例

```python
# Refund the iteration when the ONLY tool was execute_code (programmatic tool
# calling) — cheap RPC-style calls shouldn't eat the budget.
if {tc.function.name for tc in assistant_message.tool_calls} == {"execute_code"}:
    agent.iteration_budget.refund()
```

`execute_code` 是「模型写一段代码去调用多个工具」，本质是把多轮的往返压成一轮。
如果它也吃预算，那就失去了意义 —— 所以退一次。

以及 `_budget_grace_call`（§6.3）。

---

## 6. 中断、预算、租约

### 6.1 三层「停」的机制

| 机制 | 粒度 | 谁设 | 效果 |
|---|---|---|---|
| `agent._interrupt_requested` | 立即 | 任意线程 | 下次检查点生效 |
| `iteration_budget` | 迭代 | 循环自己 consume | 预算耗尽后只允许一次宽限调用 |
| turn lease | turn | 跨进程 | 两个进程不能同时写同一会话 |

**它们互不替代**。一个 turn 可以被「用户喊停」，「预算耗尽」，或「租约被另一个进程持着」。

### 6.2 可中断的 API 调用

真实 HTTP 请求跑在**后台线程**，主线程同时等三件事：

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

[`perform_api_call`](../agent/turn_api_call.py:67) 的 docstring 只有一句
「Issue the request (see `_should_stream` for the streaming decision)」，
真正的线程封装在 `AIAgent._interruptible_api_call` / `_interruptible_streaming_api_call`
（mixin 上，经 `agent.chat_completion_helpers` 调用）。

为什么要线程？因为 `requests.post()` 无法被打断。**「可中断」必须由一个能被唤醒的等待者实现**，
而不是靠 socket 超时。

**停止的扇出规则**（[`tools/AGENTS.md`](../tools/AGENTS.md:147)）：
一轮的硬中断只到达 `_active_children`；**后台委派单元在派发时就已脱离**。
所以每个停止面都必须额外调 `async_delegation.interrupt_for_session`：

| 停止面 | 位置 |
|---|---|
| gateway `/stop`（busy 路径） | `gateway/run_busy.py` |
| gateway `/stop`（idle 路径） | 同上 |
| TUI `session.interrupt` | `tui_gateway/methods_session_control.py` |
| ACP `cancel` | `acp_adapter/server.py` |
| CLI `/stop` | `hermes_cli/cli_commands_mixin.py` |

**漏掉任何一个，后台子代理就会继续烧钱。**

### 6.3 预算与宽限调用

[`agent/iteration_budget.py`](../agent/iteration_budget.py:25) 只有 35 行：

```python
class IterationBudget:
    """Thread-safe iteration counter; ``execute_code`` (programmatic tool calling)
    iterations are refunded via :meth:`refund` so they don't eat into the budget."""

    def __init__(self, max_total: int):
        self.max_total = max_total
        self._used = 0
        self._lock = threading.Lock()

    def consume(self) -> bool:
        with self._lock:
            if self._used >= self.max_total:
                return False
            self._used += 1
            return True

    def refund(self) -> None:
        with self._lock:
            if self._used > 0:
                self._used -= 1
```

docstring 里有两个数字，**旧文档容易搞错**：

> The parent's cap is `max_iterations` (default 500), each subagent's
> `delegation.max_iterations` (default 50), so total iterations across parent + subagents
> can exceed the parent's cap.

**父 500、子 50，且总迭代数可以超过父的 500** —— 因为每个 agent 有自己的计数器。
不是「共享一个池子」，而是「各自有上限」。

**宽限调用**（grace call）：

```python
while (s.api_call_count < agent.max_iterations and agent.iteration_budget.remaining > 0) \
        or agent._budget_grace_call:
```

条件末尾的 `or agent._budget_grace_call` 允许**预算耗尽后再跑一次**。
由 [`turn_truncation.py`](../agent/turn_truncation.py:635) 在响应被截断时置位：

```python
fallback gets exactly one grace call (``_budget_grace_call`` is consumed by the next ...)
```

然后在 [`turn_iteration_prep.py`](../agent/turn_iteration_prep.py:408) 里消费：

```python
if agent._budget_grace_call:
    ...
    agent._budget_grace_call = False
```

**语义**：「模型答到一半被截断了」→ 给它一次机会把话说完，不算预算。
这是「用户体验优先于预算严格」的取舍。

### 6.4 `restart_count`：一个反直觉的计数器

`_LoopState` 里有：

```python
# Backstop for the refunding restarts (redirect / rebuilt-for-fallback). Unlike
# ``retry_count`` (rebound to 0 each iteration) this survives across iterations until a
# response arrives, so a runaway interrupt/redirect that keeps re-arming a restart flag
# cannot refund the iteration budget forever and hold the turn lease indefinitely.
restart_count: int = 0
```

问题：有些路径会「重启这次迭代且退还预算」（用户 redirect、fallback 重建）。如果
每次重启都退款，一个不断 redirect 的用户可以让 turn **永不结束** —— 而它还持着租约，
于是整个会话被锁死。

`restart_count` 是**跨迭代存活**的反制。注意 `_LoopState` 里几乎其他所有字段都是「每次迭代rebind」，
这个字段明确写着「Unlike retry_count (rebound to 0 each iteration)」。

**「退款 + 无限重来」是资源系统的经典漏洞**，这是补丁。

### 6.5 外循环错误次数

```python
_MAX_OUTER_LOOP_ERRORS = 8
```

外层 `try/except` 捕获任何异常，交给 `handle_outer_loop_error`。但**不能无限重试** ——
一个必然抛异常的代码路径会变成 100% CPU 死循环。8 次后放弃。

`_LoopState` 里的对应字段注释带了 issue 号：`_outer_error_count: int = 0  # outer-loop exceptions this turn (#92450)`。

---

## 7. 消息流不变量

这一节的内容**每次改动都会被对照审查**（[`agent/AGENTS.md`](../agent/AGENTS.md:55)）。

### 7.1 格式

```python
{"role": "system",    "content": "..."}
{"role": "user",      "content": "..."}
{"role": "assistant", "content": "...", "tool_calls": [...]}
{"role": "tool",      "tool_call_id": "...", "name": "...", "content": "..."}
```

推理内容存在 `assistant_msg["reasoning"]`（不是单独的 role）。

### 7.2 严格交替

```text
system → user → assistant → user → assistant → ...
                    ↓（有工具时）
              assistant(tool_calls) → tool → tool → ... → assistant
```

| 规则 | 违反后果 |
|---|---|
| 绝不两个 `assistant` 连续 | provider 400 |
| 绝不两个 `user` 连续 | 语义错误，且部分 provider 拒绝 |
| **只有** `tool` 可以连续（并行工具结果） | — |
| 每个 `tool_call` 必须有一个 `tool` 结果 | 400 |

前端类比：这像一个**严格状态机**的 `allowedTransitions` 表。
所有 `append_message` 的调用点都在隐式维护它。

### 7.3 唯一的中途注入例外：`/steer`

```text
assistant(tool_calls) → tool → user
```

这个形状**在所有 provider 路径上都合法**（因为 `tool` 之后本来就该是 `assistant`，
插一个 `user` 等于「用户打断了」）。

为什么需要这个例外？因为用户在 agent 干活时想说「别改那个文件」。

两条铁律：

- **必须作为独立 `user` 行**，不能糊到已持久化的 `tool` 行上 —— append-only 持久化会让
  实时请求与历史分叉。
- **不能糊进 system prompt** —— 那会破坏缓存（§7.4）。

推论：**cron 投递活在自己的会话里**（[`12-cron-and-kanban.md`](12-cron-and-kanban.md)），
因为它无法满足「独立 user 行」的时序要求。

### 7.4 Prompt caching 不得破坏

这是全仓库第一条铁律。在一次会话生命周期内：

| 允许 | 禁止 |
|---|---|
| compression（唯一的上下文变更） | 中途改过去上下文 |
| 追加 user / assistant / tool 行 | 切换 toolsets |
| | 重载记忆 |
| | 重建 system prompt |

**必须中途注入内容时，搭车走 user 消息或 tool 结果**：

| 内容 | 搭车方式 | 文件 |
|---|---|---|
| skill slash 命令 | user 消息 | [`agent/skill_commands.py`](../agent/skill_commands.py:1) |
| 子目录 `AGENTS.md` 提示 | **追加到 tool 结果** | [`agent/subdirectory_hints.py`](../agent/subdirectory_hints.py:1) |
| 脚本化前奏 | 正常 assistant/tool 行 | [`agent/turn_scripted_prelude.py`](../agent/turn_scripted_prelude.py:1) |
| `/steer` | 独立 user 行 | 见 §7.3 |

子目录提示的限额：`_MAX_HINT_CHARS = 32_000`，**首尾截断**（保留开头和结尾，切中间），
且截断会记日志而不是弹警告。

**脚本化前奏**（`turn_scripted_prelude`）是很好的正面例子，它的 docstring 逐条证明了自己合规：

> It runs before any provider call, so the rows sit between this turn's user message and the first
> model call: nothing cached is mutated, the system prompt is untouched, no user row is added, and
> roles alternate `user -> assistant(tool_calls) -> tool -> ... -> assistant(model)`. No API call is
> counted and no `pre/post_api_request` hook fires for a step.

**「写一个新机制时，逐条论证它如何不违反缓存铁律」** —— 这个文档习惯值得抄。

### 7.5 Context files 的加载边界

[`agent/prompt_builder.py`](../agent/prompt_builder.py:1)：

- **只在启动时从 CWD 加载**（不是每次请求）
- 有上限（`CONTEXT_FILE_MAX_CHARS` / 动态上限 / `context_file_max_chars`）
- **绝不把安装树里的 `AGENTS.md` 当项目上下文加载**（PR #64611）
- 子目录提示拒绝工作目录之外的路径

最后一条治的是：跑到一个子目录，然后 `~/.codex/AGENTS.md` 或 `~/.claude/CLAUDE.md`
被当成项目规则混进 prompt。**「用户的全局配置」不是「这个项目的规则」。**

### 7.6 一个进程级全局的陷阱

```python
_last_resolved_tool_names   # model_tools.py 里的模块级全局
```

[`tools/delegate_tool.py`](../tools/delegate_tool.py:1) 的 `_run_single_child()` 在子代理
执行前后 **save/restore** 它。

后果：**读取它的代码在子代理运行期间可能看到暂时陈旧的值**。

这是「用全局变量缓存派生数据」的代价。为什么还留着？因为每次重新解析工具名很贵
（要遍历注册表 + toolset 展开）。取舍是：接受一个狭窄窗口的陈旧读，换取性能。

---

## 8. 失败与收尾

### 8.1 失败矩阵

| 失败类型 | 检出点 | `_turn_exit_reason` | 后续 |
|---|---|---|---|
| 网络/限速/5xx | `handle_api_error` | — | 内层 retry；耗尽后走恢复阶梯 |
| 上下文溢出（provider 报） | `handle_api_error` + `_provider_overflow_recovery_pending` | `context_overflow` | 压缩后重来；**不补写失败边界** |
| 本地估算溢出 | `run_preflight_gate` | `context_overflow` | 同上 |
| 压缩超时 | `build_turn_context` / preflight | — | `return`，跳过 finalize |
| 工具名非法 | `validate_tool_calls` | — | 补错误结果行，continue |
| 参数解析失败 | `_parse_tool_call` | — | 补错误结果行，continue |
| **落库失败（执行前）** | `run_tool_round` | `session_persistence_failed` | `break`，**不执行工具** |
| **落库失败（执行后）** | `run_tool_round` | `session_persistence_failed` | `break`，**不把结果给模型** |
| 工具护栏触发 | `_tool_guardrail_halt_decision` | `guardrail_halt` | 生成可读解释并 `break` |
| 模型返回空 | `turn_empty_response` | — | 重试或补提示 |
| 响应被截断 | `turn_truncation` | — | 设 `_budget_grace_call` 再试一次 |
| 收尾时停在 `tool` 行 | `finalize_turn` | `pending_tool_result` | 合成可见的 assistant 收尾（见下） |
| 外循环异常 | `handle_outer_loop_error` | — | 最多 8 次 |
| 用户中断 | 各检查点 | — | 关掉未完成的 tool 序列 |

### 8.2 「静默停止」这个具体的 bug

[`agent/turn_finalizer.py`](../agent/turn_finalizer.py:543) 有一段注释，是很好的产品思考样本：

```python
# A non-interrupted turn that fell out of the loop after a tool result, with no
# follow-up assistant text, is the Desktop/TUI "silent stop" (#55316, #54756): the
# composer returns to ready (or keeps spinning) while the durable transcript ends
# at a raw ``tool`` row — the user never learns the turn stopped, and the next user
# message lands as ``tool → user``. Interrupted tails keep
# ``close_interrupted_tool_sequence``; this is the non-interrupt sibling. Mint the
# exit reason, fail the turn, and synthesize the visible close so the tail close in
# ``_persist_step`` persists an assistant row.
```

三个症状连在一起：

1. 用户看到一个「就停在那里」的界面
2. 历史里最后一行是 `tool`（没有 assistant）
3. 下一条用户消息变成 `tool → user` 这个形状

修复：**合成一条 assistant 行**，把「为什么停了」写出来。

**「失败也要有可读的结局」** —— 这是 agent 产品的体验底线。

### 8.3 `finalize_turn` 做什么

[`agent/turn_finalizer.py`](../agent/turn_finalizer.py:525)：

```python
def finalize_turn(
    agent, *, final_response, api_call_count, interrupted, failed, messages, conversation_history,
    effective_task_id, turn_id, user_message, original_user_message, _should_review_memory,
    _turn_exit_reason, _pending_verification_response=None,
    _pending_verification_response_previewed=False,
):
```

顺序（从 §4.1 的 `break` 出来之后）：

1. `_resolve_budget_fallback` — 预算耗尽时决定用「候选答案」还是「空」
2. 静默停止检测（§8.2）
3. 持久化最后一步
4. 用量统计
5. 记忆复审钩子（`_should_review_memory`）
6. 组装 result dict

**result dict 的键**是外壳契约，值得记住：

| 键 | 含义 |
|---|---|
| `final_response` | 最终文本（可能为空） |
| `messages` | 完整消息数组 |
| `completed` | 是否正常完成 |
| `failed` | 是否失败 |
| `interrupted` | 是否被中断 |
| `error` | 错误文本 |
| `failure_reason` | 归类（如 `context_overflow`） |
| `partial` | 是否是部分结果 |
| `compression_exhausted` / `compression_deferred` | 压缩相关终态 |
| `turn_id` / `current_turn_user_idx` | 边界（§2 层 [2]） |
| `user_intervened` | 本 turn 中用户是否干预过 |

### 8.4 停止门控：`apply_stop_gates`

模型给出文本了，但**不一定该停**。三个门：

[`agent/turn_stop_gates.py`](../agent/turn_stop_gates.py:105)：

```python
def apply_stop_gates(agent, final_msg, *, final_response, messages, conversation_history,
                     pending_verification_response, pending_verification_response_previewed):
    """Run verify-on-stop → pre_verify hook → kanban stop guard, in that order. Nudges
    are user-role rows appended only after the assistant answer row, so role alternation
    holds."""
```

| 门 | 场景 | 行为 |
|---|---|---|
| verify-on-stop | 有未验证的代码改动 | 追加 nudge，继续一轮 |
| `pre_verify` hook | 插件要求再验证 | 同上 |
| kanban stop guard | kanban worker 必须以 board 工具收尾 | 最多 nudge 两次 |

**「nudge 是追加在 assistant 答案行之后的 user 行」** —— 这样交替性成立。
再一次：**任何注入都必须找一个合法的消息形状**。

kanban 那条尤其有产品意义（[`12-cron-and-kanban.md`](12-cron-and-kanban.md) 详述）：

```
Workers must end with a terminal board tool (kanban_complete / kanban_block / ...)
... so nudge once or twice first.
```

**worker 不调 `kanban_complete` 就等于任务卡在板子上**，所以要提醒它。

### 8.5 用量与摘要

- [`agent/turn_usage.py`](../agent/turn_usage.py:1) — token 用量
- [`agent/turn_summary.py`](../agent/turn_summary.py:166) — `format_turn_summary()` 生成
  「用了多久、跑了多少工具、改了多少行」的一行摘要

`_extract_line_deltas(tool_name, result)` 会从工具结果里解析 `+12/-3` 这样的行变更数 ——
**摘要要具体，才有人看**。

---

## 9. 测试约定

| 约定 | 原因 |
|---|---|
| Loop/相位测试放 `tests/agent/` | 与源码树镜像 |
| **patch 相位真正读取的绑定** | sibling 常在函数内 `from run_agent import X`，patch 在定义处会静默失效 |
| 断言**消息形状不变量**（交替性、system prompt 字节稳定） | 不要快照 prompt 文本（一改文案就红） |
| 用 `scripts/run_tests.sh`，不用裸 `pytest` | 环境隔离、`HERMES_HOME` 指向临时目录 |

「断言形状而非文本」具体怎么做：

```python
# 好：断言结构
assert [m["role"] for m in messages] == ["system", "user", "assistant", "tool", "assistant"]

# 差：快照全文
assert messages[0]["content"] == "...8000 字的 system prompt..."   # 改一个词就挂
```

**因为 prompt 会频繁微调，但它「三层结构 + 字节稳定」这个契约不该变。**

---

## 10. 自检题

1. `conversation` / `turn` / `iteration` 的边界分别在哪？预算和租约各按哪个计量？（§0.1）
2. `AIAgent.__init__` 为什么用 `locals()` 转发而不是逐个赋值？（§1.2）
3. 一次 `run_conversation` 穿过的三层函数分别叫什么？（§2）
4. `admit_durable_turn_lease` 为什么「会话行不存在也要占锁」？（§2 层 [1]）
5. `export_current_turn_boundary` 为什么必须在**所有历史改写之后**才盖戳？（§2 层 [2]）
6. `_close_durable_failed_turn` 治的是什么形状的 bug？为什么上下文溢出要排除？（§2 层 [2]）
7. 网关缓存 agent 跨 turn，代价是什么？（§2 层 [3] C）
8. `_LoopState` + `_run_phase` 解决了什么问题？「锁存字段」解决什么？（§3.2）
9. verdict 的 `break` 和 `return` 有什么区别？（§3.3）
10. 为什么 `_api_max_retries` 的重试**不消耗**迭代预算？（§3.4）
11. 相位为什么在 import 时绑定，而 sibling 通常延迟 import？（§3.5）
12. `run_tool_round` 里「先落库再执行」的灾难场景是什么？（§5.2）
13. 无效工具名的调用为什么不能直接过滤掉？（§5.3）
14. inline 工具为什么不走注册表？（§5.4）
15. `restart_count` 防的是什么漏洞？（§6.4）
16. `/steer` 为什么必须作为独立 user 行？（§7.3）
17. 要在 turn 中途注入一段内容，有哪几种合法搭车方式？（§7.4）
18. 「静默停止」的三个症状分别是什么？（§8.2）

---

## 11. 本篇小结

一句话版本：

> **一次 turn = 准入（租约/作用域）→ 构建 context → `_LoopState` → while 循环（每次迭代：
> 装配→守卫→重试调用→归一化→工具轮次或文本收尾）→ finalize → 边界盖戳 → 释放租约。**

五张必须记住的表：

- **§0.2 真实世界的病 → 补的东西**（决定了为什么有 33 个 turn 文件）
- **§3.1 相位分组**
- **§3.3 verdict 四态**（`fallthrough`/`continue`/`break`/`return`）
- **§5.4 工具派发五级优先级**
- **§7.2 消息交替规则**

三条最容易踩的坑：

1. **在网关场景加 `self._x` 但忘了 per-turn 清零**（§2 层 [3] C）
2. **注入内容不进 user/tool 行而进 system prompt**（§7.4，直接毁缓存）
3. **把相位 import 改成函数内延迟**（§3.5，升级中途会版本错配）

下一章 → [`04-prompt-and-caching.md`](04-prompt-and-caching.md)：system prompt 的三层结构，
以及「为什么它必须逐字节稳定」。
