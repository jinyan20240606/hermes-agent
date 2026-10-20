# 13 · 子代理与委派（Subagents & Delegation）

> **读法**：这一篇讲的是一件听起来很简单的事——「让一个 agent 把活分给另一个 agent」。
> 但真正难的不是「怎么 spawn」，而是下面四个问题：
>
> 1. **子代理看到什么？**（上下文隔离）
> 2. **子代理能用什么？**（工具隔离）
> 3. **结果怎么回来？**（投递与生命周期）
> 4. **停止时能不能停干净？**（扇出 —— 本篇最容易漏的一环）
>
> 第 4 点尤其反直觉：**一处「停止」代码写得对，不代表能停下来。**
> Hermes 有 5 个停止入口，漏一个就是「用户按了停止，子代理还在继续跑并花钱」。
>
> 读完你应该能：
> - 说清 `leaf` 与 `orchestrator` 的差别，以及为什么「角色由深度推导」而不是模型自己声明；
> - 解释「一个后台批次默认只回一条消息」到底省了什么；
> - 指出 `slot_key` 为什么必须存在（不存在的后果是「拆分完成单元后容量突然翻倍」）；
> - 说出至少 5 个必须调用 `interrupt_for_session` 的入口；
> - 解释为什么「后台委派是进程本地的」，以及要跨重启该用什么。

---

## 本篇相对旧版新增

| 旧版（232 行） | 新版 |
|---|---|
| 入口 2 段 | 补 12 个文件的职责表与真实行数、`_build_child_agent` 的完整构造参数、11 个 `DELEGATE_BLOCKED_TOOLS` 逐条理由 |
| 两种调用形状 10 行 | 补隐藏的 legacy 形状、`_strip_model_hidden_task_fields`（为什么 `acp_command` 必须对模型隐藏）、`_oneshot_spawn_budget` |
| 完成单元 15 行 | 补 `_units_of` 的完整实现语义、`_Batch.replace()` 手法、`_dispatch_background` 的三条降级路径（`no_async` / `at_capacity` / `inline`） |
| 角色表 5 行 | 补「能力由深度推导」的原因（`_normalize_role` 只记日志、`role` 参数被忽略）、`orchestrator` 重加 `delegation` toolset 的双重保险 |
| 配置 10 行 | 补每个旋钮的默认值来源、`_knob` 的三级回退（config > env > default）、`_HIGH_CONCURRENCY_WARNED` 的一次性告警 |
| 子进程 15 行 | 补 `handoff` 的锁内语义、`account_background_processes` 的三类账目、`unread_completions` 的用途 |
| 子内核 5 行 | 补 key 的形状与「为什么不能让已结束的内核占用 LRU 上限」 |
| `output_schema` 8 行 | 补「一次重试」的边界、`schema_note`、为什么坚持 `status: completed` |
| 无 | **§7 异步委派的持久账本**（`async_delegations` 表、7 天保留、投递 claim、`dropped` 收敛、孤儿 sweep） |
| 无 | **§8 陈旧检测**（`progress_fn` 三信号、450s/1200s 双阈值、`_STALL_GRACE_SECONDS=120`、为什么不用墙钟） |
| 无 | **§9 实时控制三件套**（`list`/`steer`/`stop`）+ `_owns_subagent_record` 的两级所有权 |
| 停止扇出 15 行 | 补 5 个入口的完整清单 + 为什么「深度>0 永远是同步」+ `_attach_child` 的「已到达的 stop」补偿 |
| 无 | **§11 子代理的 prompt 是怎么造的**（`_build_child_system_prompt` 的四个段落、为什么不把 goal 放进 system prompt） |
| 无 | **§12 两个隐蔽的进程级全局**（`_last_resolved_tool_names` 的 save/restore、`_BATCH_ORDINALS`） |
| 无 | **§13 插件视角的稳定契约**（`SubagentLaunchRequest` / `SubagentHandle` / HMAC capability、9 个状态、为什么不用 AIAgent 对象） |
| 测试 4 行 | 补「为什么子进程 env 隔离值得单独测」与「不该测什么」 |
| 无 | §16 自检题 48 道 |

---

## 0. 前置概念

### 0.1 为什么 agent 需要「子代理」

单个 agent 有两个硬约束：

**（1）上下文窗口有限。** 一个「研究 5 个竞品」的任务，如果在一个会话里做完，
中间过程（5×20 次网页抓取）会塞满上下文，还挤掉了后续推理的空间。

**（2）串行慢。** 5 个独立子任务本可以并行，但一个 agent 只能一条一条做。

子代理同时解决两者：**每个子代理有自己的窗口，多个子代理同时跑。**

### 0.2 「委派」到底隔离了什么

初学者容易以为「子代理 = 同一个 agent 换了个提示词」。实际隔离的维度多得多：

| 隔离项 | 说明 |
|---|---|
| **对话历史** | 子代理**看不到**父代理的任何消息；只知道 `goal` + `context` |
| **system prompt** | 全新的、精简的（不是父的完整人格 + 技能 + 记忆） |
| **terminal 会话** | 独立的 `task_id`，独立的进程/沙箱 |
| **file-ops 缓存** | 独立的读写记录（所以「父读过这个文件」不会传给子） |
| **记忆** | `skip_memory=True` —— 不读也不写 |
| **项目上下文文件** | `skip_context_files=True`（但 workspace 的 `AGENTS.md` 会被**显式**注入，见 §11） |
| **工具集** | 父的工具集**减去**黑名单（不是加法） |
| **模型请求 id / 缓存** | 独立的会话，独立的前缀缓存 |

只有两样东西**有意共享**：
- **凭证池**（`_resolve_child_credential_pool`）—— 为了在限流时轮换；
- **进程**（同步/后台都是在同一个 Python 进程的线程里，见 §6）。

### 0.3 「同步」与「后台」的真正区别

初学者常以为差别是「等不等」。实际差别是**结果回到哪里**：

| | 同步 | 后台 |
|---|---|---|
| 工具调用的返回值 | 包含结果 | 只包含 `delegation_id` 和提示 |
| 结果如何出现 | 就在这次 tool call 的返回里 | **作为一条新消息**，在父 agent **结束当前 turn 之后** |
| 父 agent 的上下文 | 立即被结果填充 | 暂时不含结果 |
| 父进程崩溃 | 结果一起丢 | 有持久账本，可恢复（§7） |

这就解释了 schema 里那句加粗的话：

> Background results are delivered only BETWEEN your turns:
> finish whatever does not depend on them, then give a one-line status and END YOUR TURN.
> **Never wait or poll** on transcripts, artifact files, or CI for a child.

如果模型「在 turn 里等」，它等的是自己——因为结果要等它结束 turn 才注入。

### 0.4 什么是「扇出（fan-out）」

一个父 agent 生成 N 个子任务是 fan-out；N 个子任务的结果汇回父 agent 是 fan-in。

本篇的「停止扇出」指的是：用户按停止时，那个信号必须**递归地**传到整棵树上。
难点在于：**有些节点是「脱离（detached）」的**——它们不在父的 `_active_children` 列表里，
所以「遍历活动子节点」的朴素做法到不了它们。

---

## 1. 代码形状

`delegate_task` 是典型的 **facade + 兄弟**结构：`tools/delegate_tool.py` 门面 + 8 个
`delegate_tool_*.py` 兄弟共 **4,414 行**，加上 `async_delegation*.py`（1,309 行）
和 `agent/` 侧两个契约文件（600 行），**合计 6,323 行**。

| 文件 | 行数 | 职责 |
|---|---|---|
| [`tools/delegate_tool.py`](../tools/delegate_tool.py:1) | 803 | 门面：`delegate_task()`、工具 schema、`_build_child_agent`、`_run_single_child` |
| [`tools/delegate_tool_child_run.py`](../tools/delegate_tool_child_run.py:1) | 1090 | `_ChildRun`：跑一个已建好的子代理，处理心跳/超时/失败/清理 |
| [`tools/delegate_tool_config.py`](../tools/delegate_tool_config.py:1) | 602 | 配置旋钮 + 子代理的 provider/凭证解析 |
| [`tools/delegate_tool_dispatch.py`](../tools/delegate_tool_dispatch.py:1) | 477 | 批次执行 + 后台拆分（`_Batch`、`_units_of`、`_dispatch_background`） |
| [`tools/delegate_tool_progress.py`](../tools/delegate_tool_progress.py:1) | 436 | 进度事件、子代理 system prompt、失败文案 |
| [`tools/delegate_tool_results.py`](../tools/delegate_tool_results.py:1) | 410 | 结果条目组装、摘要预算、工具名 save/restore |
| [`tools/delegate_tool_registry.py`](../tools/delegate_tool_registry.py:1) | 310 | 活动子代理注册表：`list`/`steer`/`stop`、所有权判定 |
| [`tools/delegate_tool_tasks.py`](../tools/delegate_tool_tasks.py:1) | 162 | 任务列表规范化、图片、schema 校验 |
| [`tools/delegate_tool_toolsets.py`](../tools/delegate_tool_toolsets.py:1) | 124 | 子代理工具集解析（黑名单 + 复合展开 + 角色） |
| [`tools/async_delegation.py`](../tools/async_delegation.py:1) | 1238 | 后台注册表、持久账本、投递 claim、陈旧监控、孤儿 sweep |
| [`tools/async_delegation_recovery_hints.py`](../tools/async_delegation_recovery_hints.py:1) | 71 | 崩溃恢复时的 transcript 尾巴 + git 快照 |
| [`agent/subagent_lifecycle.py`](../agent/subagent_lifecycle.py:1) | 416 | **插件用的稳定契约**（不可变 dataclass，不是 `AIAgent`） |
| [`agent/delegation_context.py`](../agent/delegation_context.py:1) | 184 | 上下文判定（delegated child / kanban 所有权 / 围栏） |

工具注册（[`delegate_tool.py:789`](../tools/delegate_tool.py:789)）：

```python
registry.register(
    name="delegate_task",
    toolset="delegation",
    schema=DELEGATE_TASK_SCHEMA,
    handler=...,
    check_fn=check_delegate_requirements,   # 永远 True：没有外部依赖
    emoji="🔀",
    dynamic_schema_overrides=_build_dynamic_schema_overrides,
)
```

`dynamic_schema_overrides` 很关键（[`:661`](../tools/delegate_tool.py:661)）：

> 每次 `get_definitions()` 都按用户**真实的限制**重写描述。

即：模型看到的 `tasks` 描述里写的是「最多 N 个并行」，N 是**这个用户配的**
（`delegation.max_concurrent_children`），不是硬编码的 3 或 10。
否则模型会以为可以开 10 个，然后在运行时被拒。

---

## 2. 入口与调用形状

### 2.1 签名

```python
def delegate_task(
    goal=None, context=None, tasks=None, max_iterations=None, role=None,
    background=None, output_schema=None, images=None,
    action=None, subagent_id=None, message=None,
    parent_agent=None, credentials_cfg=None,
) -> str
```

看起来参数很多，但**对模型暴露的只有一小部分**。看 schema 的 `properties`
（[`:696`](../tools/delegate_tool.py:696)）：只有 `tasks`、`action`、`subagent_id`、`message`。

其余的是：
- **legacy**：`goal` / `context` / `output_schema`（老 transcript 的形状），
  代码注释明说「Both unadvertised on purpose (old transcripts only); do not re-add」；
- **内部调用者**：`credentials_cfg`（`/review` 传给 `auxiliary.review` 的独立路由）。

### 2.2 形状 A：单任务

```json
{"tasks": [{"goal": "重构 auth 模块，拆出 token 刷新逻辑"}]}
```

注意即使单任务也走 `tasks` 数组（`minItems: 1`）。
单元素数组 = 一个子代理。这是为了**统一代码路径**：
批量与单个只差数组长度，后面所有逻辑（并发、完成单元、结果聚合）都不用分支。

### 2.3 形状 B：批量

```json
{"tasks": [
  {"goal": "研究竞品 A", "group": "research"},
  {"goal": "研究竞品 B", "group": "research"},
  {"goal": "写迁移脚本"}
]}
```

`group` 是**投递分组**，不是**执行依赖**。schema 里写得很清楚：

> This does not order execution; if B needs A's output, dispatch B after A returns.

这是一个高频误解：用户很容易把 `group` 当成「先后顺序」。
所以 schema 用一整句否认它。

### 2.4 隐藏字段的剥离

模型可能从上下文里学到 `acp_command` / `acp_args`（内部才用的字段）。
如果模型传了它们，就等于让模型**指定任意可执行文件**。

[`:782`](../tools/delegate_tool.py:782)：

```python
_MODEL_HIDDEN_TASK_FIELDS = {"acp_command", "acp_args"}

def _strip_model_hidden_task_fields(tasks):
    """Drop trusted-config-only task fields from model-supplied tasks..."""
```

这是**信任边界**：`acp_command` 只能来自 `config.yaml`（用户写的），
不能来自模型（模型可能被 prompt 注入）。

### 2.5 one-shot 会话的子代理预算

[`delegate_tool.py:458`](../tools/delegate_tool.py:458)：

```python
def _oneshot_spawn_budget(parent_agent, requested: int) -> Optional[str]:
    """Charge *requested* children against the finite one-shot session's total
    (delegation.oneshot_max_children); the error text tells the model to do the work inline."""
```

场景：`hermes -p "重构这个模块"` 这种**一次性**调用。
默认 `oneshot_max_children = 2`。

为什么限制？因为一次性会话没有用户盯着，一个「失控的模型」可能扇出 50 个子代理，
每个都花钱，而没人能中途叫停。

错误文案也值得学（[`:470`](../tools/delegate_tool.py:470)）：

> Do the remaining work yourself in this session — reviewing your own diff
> and running the tests inline is expected here, not a delegated review.

它不只是说「不行」，还**告诉模型应该怎么做**。这比「budget exceeded」有用得多。

---

## 3. 子代理的构造

### 3.1 `_build_child_agent` 做了什么

[`:194`](../tools/delegate_tool.py:194)。按顺序：

**（1）推导深度与角色**

```python
child_depth = getattr(parent_agent, "_delegate_depth", 0) + 1
max_spawn = _get_max_spawn_depth()
effective_role = "orchestrator" if _get_orchestrator_enabled() and child_depth < max_spawn else "leaf"
```

注意 **`role` 参数被完全忽略**（[`:226`](../tools/delegate_tool.py:226) 注释：

> Role is depth-derived: a child may delegate iff the kill switch is on and
> depth budget remains below max_spawn_depth. **The `role` arg is ignored.**

为什么？因为「我能不能再委派」是一个**权限问题**，不能由模型自己声明。
如果模型可以在 task 里写 `role: orchestrator`，那就绕过了 `max_spawn_depth`。

而 `_normalize_role`（[`:97`](../tools/delegate_tool.py:97)）仍存在，
只是用于「把非法值收敛成 leaf 并记 warning」——一个宽容的入口约定。

**（2）解析工具集**

```python
child_toolsets, child_disabled_toolsets = _resolve_child_toolsets(parent_agent, toolsets, effective_role)
```

详见 §4。

**（3）构建 system prompt**

```python
child_prompt = _build_child_system_prompt(
    goal, context, workspace_path=_resolve_workspace_hint(parent_agent),
    role=effective_role, max_spawn_depth=max_spawn, child_depth=child_depth,
)
```

注意 `goal` 被传进去了，但**不是**放进 system prompt 正文（见 §11.2）。

**（4）解析运行时（provider/model/key）**

```python
rt = _resolve_child_runtime(parent_agent, delegation_cfg, parent_api_key, model=model, ...)
```

支持 override（`delegation.provider` / `delegation.model` / `delegation.base_url` / ...）。
注释说明（[`:236`](../tools/delegate_tool.py:236)）：

> General delegation behavior (reasoning, compression, capabilities) stays global.
> Only fallback policy follows the owner of a per-call route such as `auxiliary.review`.

即：`/review` 用的是 `auxiliary.review` 的 fallback 链，不是 `delegation` 的。
因为 `auxiliary.review` 可能配了不同的 fallback（比如更便宜）。

**（5）开一个专用的 SessionDB 句柄**

这是 #81267 的修复（[`:123`](../tools/delegate_tool.py:123)）：

```python
def _open_child_session_db(parent_agent):
    """DEDICATED SessionDB handle for the child, or None: the parent's handle can be closed
    by its own lifecycle while a background child still flushes (transcript silently dropped).
    It MUST open the same db FILE as the parent's handle (non-launch profiles),
    else lineage / session_search break; released by the child's close() via _owns_session_db."""
```

两个约束：

- **必须专用**：父的句柄可能在 `cron run_job` 的 `finally`、gateway 会话结束、`/new` 时被关；
  后台子代理还在写 → 后续每次写都打到一个关闭的句柄 → **transcript 静默丢失**。
- **必须指向同一个文件**：如果开 `SessionDB()`（无参数），会打开**启动 profile** 的 `state.db`，
  于是子代理的 transcript 落到了错误的 profile，`parent_session_id` lineage 断了，
  `session_search` 也搜不到。

**（6）在 `delegated_child_context()` 里构造**

```python
with delegated_child_context():
    child = AIAgent(..., side_agent=True, skip_context_files=True, skip_memory=True,
                    clarify_callback=None, session_db=child_session_db,
                    parent_session_id=parent_sid, ...)
```

为什么在 context 里？因为 `AIAgent.__init__` 会调 `set_current_session_id(child.session_id)`，
污染进程级的 session 身份。`delegated_child_context`（[`delegation_context.py:28`](../agent/delegation_context.py:28)）会：

```python
token = _DELEGATED_CHILD_CONTEXT.set(True)
try:
    with scoped_current_session_id(session_id):
        yield
finally:
    _DELEGATED_CHILD_CONTEXT.reset(token)
```

`scoped_current_session_id` 在退出时恢复父的 session id。
docstring 特别说（[`:30`](../agent/delegation_context.py:30)）：

> Even a context entered without an id must restore the parent's session ContextVar
> (child construction calls `set_current_session_id`).

即：**即使没有 id 也要恢复**。否则「构造完子代理后，父的 session 身份变成了子的」。

**（7）缓存 TTL 从 1h 降到 5m**

[`delegate_tool.py:146`](../tools/delegate_tool.py:146)：

```python
def _apply_child_cache_ttl(child):
    """A delegated child never uses the 1h cache tier. The tier is priced for a person who
    steps away between turns (2x write vs 1.25x for 5m, #14971); a subagent calls every few
    seconds for minutes and is gone, so it pays the 2x on every tool result and never
    collects the retention."""
```

这是一笔真实的钱：1h 缓存的写入成本是 5m 的约 1.6 倍（2x vs 1.25x）。
人类用户「离开 20 分钟再回来」能吃到 1h 缓存的好处；子代理「每几秒一次、跑几分钟就死」
只付了贵的那部分，永远吃不到。

**（8）压缩阈值可选**

[`:157`](../tools/delegate_tool.py:157)：

```python
def _child_compression_cap_tokens(raw):
    """Validated ``delegation.compression_threshold_tokens``: an int >= 16000, or None for "no cap".
    Unset / ``0`` / ``false`` / ``null`` mean no subagent-specific cap...
    A bool ``true`` (YAML) would coerce to 1 and make every call compress;
    a string like ``"200k"`` would silently read as no cap. Both are config errors."""
```

这段注释点出了 YAML 的两个陷阱：

- `compression_threshold_tokens: true`（有人以为是「开启」）→ `int(True) = 1` →
  **每次调用都压缩**（灾难）；
- `compression_threshold_tokens: "200k"` → 字符串 → 读成「没有上限」→ 静默失效。

所以校验必须严格，且**错误时退回默认而不是猜**。

**（9）弱引用父代理**

```python
child._delegate_parent_ref = weakref.ref(parent_agent)
```

注释（[`:306`](../tools/delegate_tool.py:306)）：

> weakref so a finished parent can be collected while a detached child record lingers in the registry.

如果用强引用：注册表里一个残留的子代理记录会让整个父 `AIAgent`（含所有工具、DB 句柄）
永远不被 GC。用一个弱引用，父可以死，子代理记录变成 `None` 后由 lineage 回退（§9.3）。

**（10）注册 + 触发 `subagent_start` hook**

```python
_attach_child(parent_agent, child)      # interrupt propagation
_safe_progress(child_progress_cb, "subagent.spawn_requested", preview=goal)
_invoke_hook("subagent_start", ...)     # 插件生命周期钩子
```

注意 `spawn_requested` **在** `subagent_start` **之前**：因为子代理可能在线程池里
排队好几秒（池满时），UI 需要先知道「请求已发出」。

---

## 4. 工具隔离

### 4.1 十一条黑名单

[`delegate_tool_toolsets.py:14`](../tools/delegate_tool_toolsets.py:14)：

```python
DELEGATE_BLOCKED_TOOLS = frozenset([
    "delegate_task",   # no recursive delegation
    "clarify",         # no user interaction
    "memory",          # no writes to shared MEMORY.md
    "send_message",    # no cross-platform side effects
    "cronjob_manage",  # no scheduling more work in the parent's name
    "start_chat",
])
```

六个名字，但展开成「整组工具集」时可能覆盖更多工具。

逐条讲为什么：

| 工具 | 为什么必须禁 |
|---|---|
| `delegate_task` | 无限递归 → 指数级 spawn。但见 §4.3：orchestrator 角色**有意**放开 |
| `clarify` | 子代理**不能问用户**。它没有 transport，问谁都收不到回答 → 会卡死 |
| `memory` | 记忆是**共享的** `MEMORY.md`。20 个子代理并发写 → 冲突 + 污染 |
| `send_message` | 子代理不能替父发消息给用户。否则「我让子代理查个资料，它给客户发了条消息」 |
| `cronjob_manage` | 子代理不能以父的名义排新任务。否则失控的扇出会在**未来**继续花钱 |
| `start_chat` | 同上：不能开新对话 |

注意 `send_message` 的注释是「no cross-platform side effects」——
这是**外部副作用**原则：子代理可以做本地、可回滚的事，不能做对外不可撤销的事。

### 4.2 工具集是「交集」不是「并集」

[`:81`](../tools/delegate_tool_toolsets.py:81)：

> Children **never gain tools the parent lacks**: explicit `toolsets` are intersected
> with the parent's (composite-expanded) set, else the parent's enabled set is inherited.

这是安全的基本方向：子代理是父的**降级**，不是升级。
如果子代理能获得父没有的工具，那就成了权限提升。

但「交集」有个坑：父用的是复合工具集（如 `hermes-cli`），
子代理请求的是 `web`。裸名字交集会拒绝（因为「web」不在 {「hermes-cli」} 里）。

所以 `_expand_parent_toolsets`（[`:39`](../tools/delegate_tool_toolsets.py:39)）：

```python
def _expand_parent_toolsets(parent_toolsets: set) -> set:
    """Add every toolset whose tools are a subset of the parent's tools: a parent on a
    composite like ``hermes-cli`` must still let a child request ``web``/``terminal``;
    bare name intersection would reject them. Both sides use the RESOLVED static surface:
    a composite's ``includes`` are tools the parent genuinely holds, and the child
    never gains a tool the parent lacks."""
```

关键在最后一句：展开是**按工具集合的包含关系**，不是「按名字的 includes」。
这样仍然保证「子不获得父没有的工具」——因为展开只加入**工具子集**。

### 4.3 角色：leaf 与 orchestrator

`leaf`（默认）不能委派；`orchestrator` 可以。

**开放条件**（[`:229`](../tools/delegate_tool.py:229)）：

```python
effective_role = "orchestrator" if _get_orchestrator_enabled() and child_depth < max_spawn else "leaf"
```

两个条件**同时**满足：
1. `delegation.orchestrator_enabled`（总开关，默认？见配置）；
2. `child_depth < max_spawn`（深度还有余量，默认 `max_spawn_depth = 2`）。

深度语义（[`delegate_tool_config.py:21`](../tools/delegate_tool_config.py:21)）：

```python
MAX_DEPTH = 1  # flat by default: parent (0) -> child (1); deeper needs max_spawn_depth
```

- `parent` 的 depth 是 0；
- 它的子代理 depth = 1；
- 如果 `max_spawn_depth = 2`，那 depth=1 的子代理可以再委派，depth=2 的不能。

**为什么要两道门？** 因为 `orchestrator_enabled` 是「这个功能要不要开」，
`max_spawn_depth` 是「开了之后能开多深」。分开后可以：
- 完全关掉（扁平，永远只有一个层级）；
- 或者开着但只允许两层。

**工具集的双重保险**（[`:117`](../tools/delegate_tool_toolsets.py:117)）：

```python
if effective_role == "orchestrator":
    inherited_disabled = [name for name in inherited_disabled if name != "delegation"]
    if "delegation" not in child_toolsets:
        child_toolsets.append("delegation")
```

两件独立的事：
1. 从**继承的 disabled** 里去掉 `delegation`（父可能因为自己的角色把它禁了）；
2. 如果 `delegation` 不在 enabled 里，**显式加回来**。

为什么两件都要？因为 `enabled_toolsets` 与 `disabled_toolsets` 是两个独立通道，
最终生效是「enabled ∩ ¬disabled」。只做一件可能被另一件抵消。

注释也说明了这是 **role-granted, not inherited**：
不是「父能委派所以子也能」，而是「角色允许所以给」。

### 4.4 `kanban` 永远被禁

[`:122`](../tools/delegate_tool_toolsets.py:122)：

```python
child_disabled_toolsets = list(
    dict.fromkeys(inherited_disabled + _blocked_toolsets_for_role(effective_role) + ["kanban"])
)
```

`kanban` 无条件加进 disabled。

理由见 [`12-cron-and-kanban.md`](12-cron-and-kanban.md) §12.5：
「工具访问权不是所有权」。如果子代理拿到了 `kanban_complete`，
它可能把父的任务标记完成。

而 `_strip_blocked_tools` 也会去掉 `kanban` 这个**复合工具集**（[`:60`](../tools/delegate_tool_toolsets.py:60)）：

```python
blocked_toolset_names = {"delegation", "kanban"} | {...}
```

两个层级（工具集级 + 单工具级）都封，因为 `kanban` 可能以不同粒度出现。

---

## 5. 两种执行路径

### 5.1 同步：`_run_children_parallel`

[`delegate_tool_dispatch.py:119`](../tools/delegate_tool_dispatch.py:119)：

```python
def _run_children_parallel(batch, results, *, honor_parent_interrupt):
    """Run the batch's children in parallel... Polls futures with a short ``wait()`` timeout
    instead of ``as_completed()`` so a wedged child cannot block the parent forever after
    an interrupt; on parent interrupt the still-pending children are reported ``interrupted``
    and abandoned (they already got the interrupt signal)."""
```

两个细节：

**（1）不用 `as_completed()`，用短超时的 `wait()`。**

为什么？因为 `as_completed()` 会一直阻塞到下一个 future 完成。
如果父被中断了，而已有一个子代理永久卡住，父就永远醒不来（无法检查中断信号）。

用 `wait(timeout=short)` 就能「每 N 百毫秒醒来看看有没有中断」。

**（2）用 `DaemonThreadPoolExecutor`。**

[`:126`](../tools/delegate_tool_dispatch.py:126)：

```python
# Daemon workers (tools.daemon_pool): the `with` block still joins normally, but if the
# parent is interrupted while a child is wedged, the abandoned worker must not block
# interpreter exit.
```

普通线程池的 worker 是**非 daemon** 的：解释器退出时会等它们。
一个卡在阻塞 I/O 的 worker 会让 `hermes` 进程**退不出去**。
daemon 线程不会——进程可以直接走。

### 5.2 后台：`_dispatch_background`

[`:417`](../tools/delegate_tool_dispatch.py:417)。三条路径：

```
① wake_sid is None  → 同步执行，note="no_async"
   为什么？这个会话类型无法接收「脱离的完成消息」
   （比如一次性 CLI、cron），那就只能同步等

② 第一个 unit 被拒（池满）→ 整批同步执行，note="at_capacity"
   为什么整批？因为「一半后台一半前台」会让结果分两处出现，
   模型很难理解

③ 后面的 unit 被拒 → 那个 unit 内联跑，结果放进 inline_results
   为什么不用①？因为这时已经有 unit 在后台了，同步会阻塞父
   而「静默丢掉一个任务」更不可接受
```

第 ③ 条值得细看（[`:460`](../tools/delegate_tool_dispatch.py:460)）：

> Later units of an admitted call share its slot and cannot be capacity-rejected;
> a scheduler failure runs the unit inline so **no task is silently dropped**.

### 5.3 完成单元（Completion Units）

默认：**一次调用 = 一条完成消息**。

开 `delegation.independent_completions: true` 后，按 `group` 拆分（[`:370`](../tools/delegate_tool_dispatch.py:370)）：

```python
def _units_of(batch):
    """Partition the call's children into async units: one per distinct task ``group``
    (first-appearance order) and one per ungrouped task..."""
    if not _get_independent_completions():
        return [batch]
    members = {}
    for i, t, c in batch.children:
        g = t.get("group")
        key = ("g", str(g)) if g not in (None, "") else ("i", i)
        members.setdefault(key, []).append((i, t, c))
    return [replace(batch, children=ch, group=(key[1] if key[0] == "g" else None))
            for key, ch in members.items()]
```

**关键手法：`replace(batch, children=ch)`。**

dataclass 的 `replace()` 复制出新的 `_Batch`，只换 `children`。
它**共享** `task_list` / `live_writers` / `live_paths` / origin 信息。

好处：
- 每个 unit 只 join 自己的 children（快的不等慢的）；
- 但结果的 `task_index` 仍然索引**整个调用的** goals（所以摘要格式统一）。

为什么默认关闭？源码注释直白（[`:375`](../tools/delegate_tool_dispatch.py:375)）：

> A per-task flurry of completions (one new turn each) fragmented orchestrators
> that had no plan for it.

即：一个编排者本来期待「一批结果一起回来然后我综合」，
结果收到 8 条独立消息，每条都触发一个新 turn，它就被打散了。

### 5.4 `slot_key`：容量记账的陷阱

这是本篇最容易搞错的地方。

**问题**：如果一次调用拆成 8 个 unit，它们算 8 个并发槽吗？

**答案**：不算。

[`async_delegation.py:764`](../tools/async_delegation.py:764)：

```python
"""...``slot_key`` names the pool slot the unit occupies
(default: its own id); the units of one delegate_task call share the first unit's id
so splitting a call into per-group completions never consumes more capacity than the call did."""
```

实现（[`:790`](../tools/async_delegation.py:790)）：

```python
with _records_lock:
    active_slots = {r.get("slot_key") or r["delegation_id"]
                    for r in _records.values() if r.get("status") in _ACTIVE_STATES}
    if record["slot_key"] not in active_slots and len(active_slots) >= max_async_children:
        return {"status": "rejected", "error": capacity_error}
    _records[delegation_id] = record
    live_units = sum(1 for r in _records.values() if r.get("status") in _LIVE_STATES)
```

注意三件事：

1. **容量按 slot 数算**（`len(active_slots)`），不是按 record 数；
2. 已经在这个 slot 里的 unit **不受容量限制**（`record["slot_key"] not in active_slots` 才检查）；
3. **池大小按 unit 数**（`live_units`）来定，不是按 slot 数。

第 3 点很重要（[`:796`](../tools/async_delegation.py:796)）：

> Units of one call share a slot, so live units can exceed slots:
> **size the pool by units or a unit queues behind a full pool and the stale monitor kills it
> before its child ever starts.**

即：如果池按 slot 定大小（3），但实际有 8 个 unit 要跑，
那 5 个 unit 会在队列里等；而陈旧监控**只在 runner 启动后才计时**
（[`:806`](../tools/async_delegation.py:806)）……

等一下，如果只在启动后计时，排队的就不会被判为卡住，那不就没问题了吗？
注释说的是「reverse」：如果池太小，unit 排队 → **但父 agent 已经拿到 dispatched 回复了**，
用户在等 8 条结果，实际只有 3 条在跑，另外 5 条在排队——延迟不可接受。
所以把池放大到能同时跑所有 unit。

### 5.5 `_dispatch_background` 的 detach 时机

[`:446`](../tools/delegate_tool_dispatch.py:446)：

```python
# The worker can start before admission returns. Detach only this unit:
# unsubmitted units must still receive parent stops while a fallback runs.
for _, _, child in unit.children:
    _detach_child(parent_agent, child)
dispatch = _dispatch_unit(unit, unit_id, slot_key, routing)
if dispatch.get("status") == "dispatched":
    ...
_restore_parent_cancellation(unit)
```

时序很微妙：

1. **提交前 detach**：因为 worker 可能在 `_dispatch_unit` 返回前就启动了。
   如果不 detach，父的 `interrupt()` 会扇出到这个「正在变成后台」的子代理。
2. **被拒则 restore**（`_restore_parent_cancellation`）：
   这个 unit 要内联跑，它仍然是父的同步子代理，必须能被父停止。
3. **还没提交的 unit 不 detach**：如果整批 fallback 到同步，它们需要接收停止。

`_attach_child` 还有一个补偿机制（[`delegate_tool_child_run.py:64`](../tools/delegate_tool_child_run.py:64)）：

```python
def _attach_child(parent_agent, child):
    """Register the child for parent interrupt propagation.

    ``interrupt()`` fans out to a SNAPSHOT of ``_active_children``; a child attached after the stop
    landed (a fan-out still building its siblings, a turn that has not reached its iteration check yet)
    would otherwise start with no signal and run to completion as an orphan. Mirror a pending stop here
    so the whole spawn tree dies with its parent."""
    if hasattr(parent_agent, "_active_children"):
        _with_children_lock(parent_agent, "append", child)
    if getattr(parent_agent, "_interrupt_requested", False) is not True:
        return
    # 父已经请求中断 → 立即把 stop 传给这个刚附上的子代理
```

这就是所谓 **「迟到者补偿」**：一个在 stop 之后才 attach 的子代理，
会立即收到 stop 信号，而不是「因为错过快照而变成孤儿」。

注意软/硬中断的区分（[`:75`](../tools/delegate_tool_child_run.py:75)）：

> Same soft/hard split as `interrupt()`'s own fan-out: a hard stop cancels, a soft one redirects.

- **硬中断**：`_signal_child_stop` —— 真的停（取消工具、退出循环）；
- **软中断**：`child.interrupt(message)` —— 把消息塞进去让它**转向**（用户说「不，改成做 X」）。

---

## 6. 进程与资源

### 6.1 后台委派是**进程本地**的

这是最需要记住的一条。原文（[`tools/AGENTS.md`](../tools/AGENTS.md:130)）：

> **Durability:** background delegation is process-local;
> work that must survive restart uses `cronjob` or
> `terminal(background=True, notify_on_complete=True)`.

含义：子代理跑在**父进程的线程**里。父进程死了（Ctrl-C、gateway 重启、机器重启），
子代理的线程也没了。

但——等等，「持久账本」不是存在 `state.db` 吗？

**账本持久的是「结果」，不是「执行」。**
如果父进程中途死了，账本能告诉你「这个委派没有结果」（status = `unknown`，§7.5），
但**不会**让子代理继续跑完。

所以：
- 需要**结果不丢** → 后台委派 + 账本（可以）；
- 需要**任务跑完** → `cronjob` 或 `terminal(background=True)`（必须是独立进程）。

### 6.2 子代理的后台进程在 teardown 被杀

`cleanup`（[`delegate_tool_child_run.py:1045`](../tools/delegate_tool_child_run.py:1045)）的最后：

```python
if not close_deferred:
    _close_child(child, "Failed to close child agent after delegation")
```

`_close_child` 调 `child.close()`，它会关掉：
- terminal 沙箱；
- browser daemon；
- **后台进程**；
- httpx 客户端。

dtor 的 docstring 说明了意图：

> Close tool resources ... so **subagent subprocesses don't outlive the delegation**.

为什么？因为一个子代理起了 `npm run dev` 起了个服务器，然后结束了。
如果不杀，那个服务器会一直占端口，用户下次启动会「端口被占用」——而且找不到是谁占的。

### 6.3 `handoff`：主动移交

但有时你**想要**留下的进程。所以有（[`AGENTS.md:130`](../tools/AGENTS.md:130)）：

> `process_manage(action="handoff")` (children only) flips
> `ProcessSession.owner_task_id` to the parent under the registry lock
> (`process_registry.transfer_ownership`) so the completion routes and reaps by the new owner.

语义：

- 子代理起了一个长任务（比如「跑完整的测试套件，30 分钟」）；
- 子代理自己要结束了；
- 它调 `handoff`，把进程的所有权转给**父**；
- 于是：
  - 父的 teardown 才会杀它（而不是子的）；
  - 完成通知发到**父**的会话（用户能看到）；
  - 父的结果条目里有 `handed_off_processes`。

为什么必须在**注册表锁**下翻转？因为同时可能有人在读 `owner_task_id`（路由通知）。
如果不加锁，一个通知可能被路由到「旧的 owner（正在死的子代理）」→ 通知丢失。

### 6.4 三类进程账目

[`delegate_tool_child_run.py:990`](../tools/delegate_tool_child_run.py:990)：

```python
def account_background_processes(self, entry):
    """Name the child's background processes on the result BEFORE ``cleanup`` kills them:
    handed-off ones now belong to the parent (their completion lands in the parent's chat);
    anything else still running is about to be terminated, and the parent must hear that
    from the runtime rather than trust a child's "watcher running"."""
```

结果条目上可能出现三个字段：

| 字段 | 含义 | 之后的命运 |
|---|---|---|
| `handed_off_processes` | 已移交的 | 继续跑，由父管理 |
| `orphaned_processes` | 还在跑但没移交 | **即将被杀** |
| `unread_completions` | 已退出但没人读过输出 | 输出被丢弃 |

最后一句很重要：**「父必须从运行时听到这个，而不是相信子代理说的『watcher 在跑』」**。

因为子代理的自我报告不可靠（schema 里也说了 "Child summaries are SELF-REPORTS"）。
一个子代理说「我起了个 watcher」，实际可能已经崩了；或者反过来，
它不知道自己的进程即将被 teardown 杀掉。

### 6.5 子内核的 LRU 钉住

[`AGENTS.md:130`](../tools/AGENTS.md:130)：

> **Child kernels:** a child's `execute_code` kernels are keyed
> `<parent-owner>::child::<child-session-id>`, pinned against the `max_session_kernels` LRU cap
> while the child runs and disposed by `cleanup` (`code_kernel.shutdown_kernels_for_delegated_child`)
> — never let a finished child's kernel squat the cap.

`execute_code` 是持久内核（Jupyter 式的，变量在多次调用间保留）。
内核有 LRU 上限（不能无限多，每个都是内存 + 进程）。

问题：一个 20 分钟的子代理每 10 秒调一次 `execute_code`，
如果它的内核被 LRU 踢掉，变量就没了，代码会莫名其妙失败。

所以：**子代理运行期间它的内核被 pin 住**（不参与 LRU 淘汰）。
子代理结束后 `cleanup` 显式销毁它。

`cleanup` 里（[`:1076`](../tools/delegate_tool_child_run.py:1076)）：

```python
with _quiet("Failed to dispose child execute_code kernels: %s"):
    from tools.code_kernel import shutdown_kernels_for_delegated_child
    shutdown_kernels_for_delegated_child(str(getattr(child, "session_id", "") or ""))
```

「否则一个已结束的子代理的内核会一直占着上限」——
用户开了 10 次委派，`max_session_kernels = 5`，那真正需要的会话内核全被挤掉。

---

## 7. 异步委派的持久账本

这是旧版文档完全缺失的部分，但它解释了「后台委派在真实环境里怎么活下来」。

### 7.1 表与保留策略

存在 `<home>/state.db` 的 `async_delegations` 表（[`async_delegation.py:96`](../tools/async_delegation.py:96)）。

常量（[`:40`](../tools/async_delegation.py:40)）：

```python
_MAX_RETAINED_COMPLETED = 50         # 内存里保留的已完成记录
_DURABLE_RETENTION_SECONDS = 7 * 24 * 60 * 60    # 账本保留 7 天
_MAX_DURABLE_PENDING = 1000          # 待投递上限
_MAX_DELIVERY_ATTEMPTS = 8           # 投递重试上限
_MAX_COMPLETION_REPLAY_AGE_S = 48 * 3600.0       # 超过 48h 不再重放
_CLAIM_LEASE_S = 300.0               # 投递 claim 租期
```

为什么 48h 而不是 7 天？

> `48h keeps weekend results deliverable`.

即：周五晚上跑的委派，周一早上用户回来还能看到结果。
超过 48h 就「没人等了」，重放只会让一个全新会话突然收到一条两天前的消息（很困惑）。

### 7.2 投递状态机

`delivery_state` 的取值：

```
pending ──claim──> (claimed) ──complete──> delivered
   │                    │
   │                    ├──release──> pending（重试）
   │                    ├──defer────> pending（不消耗重试次数）
   │                    ├──drop─────> dropped（目标永久消失）
   │                    └──requeue──> pending（接收者无法确认所有者）
   │
   └──attempts >= 8 ──> dropped
```

五个函数，每个的语义都很讲究：

**（1）`claim_completion_delivery`**（[`:438`](../tools/async_delegation.py:438)）

```sql
UPDATE async_delegations SET delivery_claim=?, delivery_claimed_at=?,
       delivery_attempts=delivery_attempts+1, updated_at=?
 WHERE delegation_id=? AND delivery_state='pending'
   AND (delivery_claim IS NULL OR delivery_claimed_at < ?)   -- 租期过期可抢
```

注意 **attempts 在 claim 时 +1**，不是成功时。
为什么？因为「claim 后进程崩了」也要算一次尝试——否则一个每次崩溃的投递会无限重试。

**（2）`defer_completion_delivery`**（[`:495`](../tools/async_delegation.py:495)）

```sql
delivery_attempts=MAX(0, delivery_attempts-1)
```

「退回 pending 但**不消耗**尝试次数」。

什么时候用？当「这次没投递」不是因为失败，而是因为**时机不对**
（比如接收方在忙）。这不该惩罚。

**（3）`drop_completion_delivery`**（[`:504`](../tools/async_delegation.py:504)）

docstring：

> Terminally drop a claimed completion whose target is **permanently gone**
> (the spawning session ended at an explicit user boundary such as `/new` or reset).
> `dropped` — not `delivered` — **keeps the ack honest**;
> not `pending` keeps restart recovery from replaying it into a fail-closed drop forever.

`dropped` vs `delivered` 的区别是**诚实性**：
- 标 `delivered` → 谎称用户看到了；
- 标 `dropped` → 承认「没送到，且不会送了」。

如果一个投递永远失败（目标会话被 `/new` 清掉了），标成 `delivered` 会让
「投递成功率」指标说谎；而且 `pending` 会让它在每次重启时重放，永远失败。

**（4）`requeue_admitted_completion`**（[`:526`](../tools/async_delegation.py:526)）

场景：投递已经 `delivered`，但接收的 turn **无法确认自己是所有者**
（比如它是刚恢复的会话，不知道这个委派是不是自己的）。

```python
exhausted = ... WHERE ... state='delivered' AND delivery_attempts>=?
if exhausted.rowcount == 1: return False   # 收敛到 dropped
reopened = ... SET delivery_state='pending' ... WHERE delivery_state='delivered' AND event_json IS NOT NULL
```

「把已确认的投递退回去」听起来很危险，但这里是必要的：
**宁可重投一次让正确的会话收到，也不要错误地投给错误的会话**。

而 attempts 上限（8）保证这个循环会收敛。

**（5）`is_interim_delegation_event`**（[`:454`](../tools/async_delegation.py:454)）

```python
def is_interim_delegation_event(evt):
    """An early per-task notice for a batch that is still running. It shares the batch's
    ``delegation_id`` but is NOT the durable completion: it must never claim, acknowledge or
    dedup against the final result's row (independent review reproduced exactly that loss)."""
    return evt.get("type") == "async_delegation" and bool(evt.get("task_failure_notice"))
```

这是一个真实的 bug：批次的「某个任务失败了」的**早期通知**与**最终结果**
共享同一个 `delegation_id`。

如果早期通知走了完整的 claim/ack 流程：
- 它 claim 了那一行；
- 它 ack 了 → `delivery_state='delivered'`；
- 真正的最终结果来了 → 发现已 delivered → **被丢弃**。

结果：用户看到「任务 2 失败了」，永远看不到「任务 1 成功了、总结是 X」。

修法：给早期通知打标记（`task_failure_notice`），让它**不走**持久投递流程。

### 7.3 崩溃恢复：`recover_abandoned_delegations`

[`:260`](../tools/async_delegation.py:260)：

```python
def recover_abandoned_delegations() -> int:
    """Classify records whose owning process disappeared as outcome unknown; children a
    multi-child unit had already recorded (``record_unit_child``) are replayed with their real results."""
```

判决依据（[`:246`](../tools/async_delegation.py:246)）：

```python
def _owner_liveness():
    """``alive(owner_pid, owner_started_at)`` over the shared drift-tolerant start-time comparator"""
```

又一次是 **`(pid, 启动时间)`**（和 kanban 一样，见 [`12-cron-and-kanban.md`](12-cron-and-kanban.md) §12.2）。
裸 pid 会被复用。

分类结果：

| 情况 | 结果 |
|---|---|
| owner 活着 | 跳过（还在跑） |
| owner 死了，没有已记录的子结果 | `status: unknown`，error 说明「owner 退出前没记录终态」 |
| owner 死了，但部分子结果已记录 | `unknown` + `results`（已完成的真实结果 + 其余 `unknown`） |

后者就是 `record_unit_child` 的价值（[`:216`](../tools/async_delegation.py:216)）：

> Durable record ONE finished child of a still-running multi-child unit on the unit's own row,
> so a crash before the unit joins loses only the children that had not finished.

**每个子代理一完成就落盘**，而不是等整个 unit join 完。
这样崩溃时损失最小化。

`_record_finished_child`（[`delegate_tool_dispatch.py:111`](../tools/delegate_tool_dispatch.py:111)）的注释解释得更极端：

> ...so an owner death before the unit's join — **or anywhere before its durable completion write,
> the whole remaining window for a one-child unit** — loses only children still running,
> never finished work (#116000).

「单子代理 unit 的剩余窗口」= 它跑完之后、写终态之前的那几毫秒到几秒。
在那一小段里崩溃，如果不逐子记录，就等于白跑了。

### 7.4 恢复提示：transcript 尾巴 + git 快照

[`:284`](../tools/async_delegation.py:284)：

```python
# Verbatim transcript tails + a git snapshot of the owner's cwd, so the parent can
# continue or re-dispatch from the event alone instead of opening files (#116000).
from tools.async_delegation_recovery_hints import git_state_hint, transcript_tails
if tails := transcript_tails(diagnostics["task_transcripts"]):
    diagnostics["transcript_tails"] = tails
if hint := git_state_hint(task.get("owner_cwd")):
    diagnostics["git_state_hint"] = hint
```

为什么需要这个？因为「owner 死了，结果未知」这个信息**不足以行动**。
父 agent 需要知道：
- 那个子代理做到哪了？（transcript 尾巴）
- 工作目录变成什么样了？（git 状态）

有了这两个，父可以：
- 判断「它其实做完了，只是没来得及汇报」→ 自己去验证；
- 或者「它做到一半」→ 从当前状态继续，而不是从零重跑。

### 7.5 孤儿 sweep

[`:362`](../tools/async_delegation.py:362)：

```python
def sweep_orphaned_completions(target_queue, *, now=None) -> int:
    """Offer this home's completions whose owner died after THIS process started (#97202).

    Startup replay (``restore_undelivered_completions``) covers owners that died before
    the process started; this covers the rest while it runs."""
```

两个时机，互补：

| 机制 | 覆盖的时间窗 |
|---|---|
| 启动重放（`restore_undelivered_completions`） | owner 在**本进程启动之前**死的 |
| 孤儿 sweep（`sweep_orphaned_completions`） | owner 在**本进程已经在跑时**死的 |

#97202 是后者：一个 desktop reload 后，旧进程死了，新进程已经在跑，
但启动重放只跑一次（在启动那一刻），于是那个完成就一直躺在 pending 里。

`sweep` 的条件很谨慎（[`:386`](../tools/async_delegation.py:386)）：

```sql
WHERE state NOT IN ('running','finalizing') AND delivery_state='pending'
  AND event_json IS NOT NULL
  AND updated_at < ?                                   -- 空闲超过 _ORPHAN_STALE_S(60s)
  AND (delivery_claim IS NULL OR delivery_claimed_at < ?)   -- 没有活的 claim
```

`updated_at < now - 60s` 是为了「不打扰刚被碰过的行」。

### 7.6 与 `restored` 标记的配合

[`:310`](../tools/async_delegation.py:310)：

```python
"""...Restored events are stamped ``restored=True`` in memory only: they came from a PREVIOUS
process, so drains without an ownership filter must leave them for a consumer that can prove
ownership. Rows older than ``_MAX_COMPLETION_REPLAY_AGE_S`` are terminally dropped instead of
replaying a turn nobody is waiting on."""
```

`restored=True` 是一个**显式的怀疑标记**：

- 一个刚从重启恢复的会话，不能「顺手收下」别人的结果；
- 只有能**证明所有权**的消费者（`session_key` / `origin_session_id` 匹配）才能收。

#64484 就是这个 bug：新会话在启动几秒后「继承」了一个死会话的委派结果，
用户看到一条自己不认识的「任务完成」消息。

---

## 8. 陈旧检测：为什么不用墙钟

### 8.1 双阈值

[`delegate_tool.py:106`](../tools/delegate_tool.py:106)：

```python
_HEARTBEAT_INTERVAL = 30  # seconds between parent activity heartbeats during delegation
# Stale-heartbeat thresholds (cycles of _HEARTBEAT_INTERVAL with no progress). Progress =
# iteration, current_tool OR last_activity_ts advancing; an in-flight model wait refreshes
# last_activity_ts, so slow models are not "idle". Idle stays tight so a truly wedged child
# doesn't mask the gateway timeout; in-tool is much higher so legitimately long
# tools can finish.
_HEARTBEAT_STALE_CYCLES_IDLE = 15      # 450s idle between turns → stale
_HEARTBEAT_STALE_CYCLES_IN_TOOL = 40   # 1200s stuck on same tool → stale
```

| 情形 | 阈值 | 理由 |
|---|---|---|
| 空闲（不在工具里） | 450s | 正常的一轮应该几秒到几十秒；7.5 分钟没动静就是死了 |
| 在工具里 | 1200s | `npm install`、`pytest`、`docker build` 可能跑 10 分钟，正常 |

**为什么「在工具里」要宽松 2.7 倍？** 因为工具执行时长是**幂律分布**的：
大部分 1 秒，少数 10 分钟。用一个值无法同时满足「快速发现死锁」和「不误杀长编译」。

### 8.2 三个进度信号

注释里的 `Progress = iteration, current_tool OR last_activity_ts advancing`。

`last_activity_ts` 特别重要（[`delegate_tool_dispatch.py:307`](../tools/delegate_tool_dispatch.py:307)）：

> `last_activity_ts` is ticked by `_touch_activity` on **every streamed chunk**
> ("receiving stream response"), every tool transition, and every API-call start/completion
> — so a child streaming a long response is alive even though `api_call_count` only advances
> when the call completes.

即：**不要只看 `api_call_count`**。一个模型生成 5000 token 的回答可能花 90 秒，
这期间 `api_call_count` 不变（因为调用还没完成），但它在**流式输出**——它在活着。

如果只看 `api_call_count`，正常的慢模型会被误杀。

### 8.3 `_STALE_RESULT_GRACE_SECONDS`

[`delegate_tool.py:113`](../tools/delegate_tool.py:113)：

```python
# After the stale verdict ends the wait, keep polling the worker this long for its real
# result (#113222): a child that already wrote its final answer often finishes unwinding a
# moment later, and that recorded result must be collected instead of a synthesized timeout.
_STALE_RESULT_GRACE_SECONDS = 2.0
```

场景：
1. 子代理写完了最终答案（内容已经在内存里）；
2. 它在做收尾（关工具、flush 日志）；
3. 此时 stale 判定触发，父决定「超时」；
4. 但 2 秒后子代理真的返回了。

如果父立刻合成一个「timeout」条目，那份**已经写好的答案就丢了**。
所以再等 2 秒，优先收真实结果。

### 8.4 后台侧：`_stale_monitor_loop`

[`async_delegation.py:74`](../tools/async_delegation.py:74)：

```python
# A runner wedged before returning never reaches its finalizer, so it would show
# "dispatched" forever. No wall-clock timeout (heavy work must never be killed for
# taking long): one monitor thread samples per-dispatch PROGRESS via an injected
# ``progress_fn``; a frozen child is interrupted, given a grace window to unwind via
# the normal finalize path, and only force-finalized (terminal ``stalled`` event)
# if it never returns. Thresholds mirror delegate_tool's sync heartbeat monitor.
_STALE_CHECK_INTERVAL = 30.0
_STALE_IDLE_SECONDS = 450.0
_STALE_IN_TOOL_SECONDS = 1200.0
_STALL_GRACE_SECONDS = 120.0
```

一个**单例监控线程**服务所有委派（`_ensure_stale_monitor`），每 30 秒扫一遍。

时序：

```
冻结检测 → 发 interrupt（子代理有机会走正常 finalize，产出真实结果）
         → 等 120 秒
         → 还没返回 → 强制 finalize 成 stalled
```

**为什么 120 秒 grace？** 因为一个被中断的子代理可能要：
- 取消正在跑的 HTTP 请求；
- 等工具返回；
- flush transcript；
- 执行 `on_session_end` hook。

这些可能是秒级的。

### 8.5 `_context` 的复制

[`async_delegation.py:784`](../tools/async_delegation.py:784)：

```python
# The one stale-monitor thread serves every profile and starts with an empty Context;
# a forced finalization runs under the dispatcher's so it settles the same state.db.
"_context": contextvars.copy_context(),
```

问题：监控线程是一个**共用的**线程，它有自己空的 ContextVar 上下文。
如果它强制 finalize（写 DB），`get_hermes_home()` 会返回**启动 profile**。

修法：在 dispatch 时 `copy_context()` 存下来，强制 finalize 时用 `ctx.run(...)`
在那个被保存的上下文里跑。

---

## 9. 实时控制

### 9.1 三个动作

`action` 参数（[`delegate_task.py:747`](../tools/delegate_tool.py:747)）：

| 动作 | 作用 | 返回值 |
|---|---|---|
| `list` | 列出活动子代理 | ids/goals/status/transcripts |
| `steer` | 向一个子代理塞入纠正文本（**不停它**） | 是否被接受 |
| `stop` | 提前结束一个（**部分结果仍返回**） | 是否找到 |

控制动作**同步执行**，且**绕过**暂停门、深度限制、异步派发
（[`:485`](../tools/delegate_tool.py:485)）：

> `action` list/steer/stop run synchronously and bypass the pause gate, depth limit and async dispatch.

为什么？因为「你已经被禁止 spawn 了，所以不能停止已经在跑的」是荒谬的。

### 9.2 `steer` 的语义

[`delegate_tool_registry.py:124`](../tools/delegate_tool_registry.py:124)：

```python
def steer_subagent(subagent_id, text, *, owner_session_id=None, owner_transport=None,
                   owner_session_record=None) -> bool:
    """Queue steering text into a running subagent without stopping it.

    AIAgent.steer() appends the text to the child's last tool result at its next iteration
    boundary — the current tool call is never cut. True iff the text was QUEUED while the
    child still accepted work; False for unknown/closed id, ownership mismatch, no live agent,
    or empty text. ``owner_session_id=None`` keeps the in-process helper contract; gateway
    callers must pass exact authority. Acceptance and completion are linearized by the registry
    lock: if acceptance wins but no delivery boundary remains, the text lands in the entry as
    ``missed_steer``."""
```

三个要点：

1. **附在「最后一个 tool result」上**，不是作为新消息。
   为什么？因为这保持了 `user/assistant` 的角色交替，也不污染 assistant 的输出。
   模型看到的是「工具返回结果 + 一句附注」，自然会调整下一步。
2. **当前工具调用不会被切** —— 这是软中断与硬中断的本质区别。
3. **`missed_steer`**：接受了但没送到（子代理恰好结束了）。
   这比「静默丢弃」好——父能看到「我那句纠正没生效」。

### 9.3 所有权：两级判定

[`:213`](../tools/delegate_tool_registry.py:213)：

```python
def _owns_subagent_record(record, parent_agent) -> bool:
    """Tier 1: identity — the ``_delegate_parent_ref`` weakref chain reaches *parent_agent*
    (fast path while the parent AIAgent survives the run).
    Tier 2: durable lineage — the record's ``owner_agent_session_id`` matches the caller's
    ``session_id`` after resolving compression-rotation lineage on both sides.
    Tier 2 exists because the identity chain is BRITTLE across parent rebuilds:
    the CLI sets ``self.agent = None`` mid-session (route change, credential refresh, /model,
    MoA one-shots) and builds a NEW AIAgent while the child keeps a weakref to the old one.
    Delivery routes by durable session id; control must use the same spine or running children
    go invisible/unsteerable."""
```

**为什么会「孩子看不见」？**

```
t=0   父 AIAgent A 存在，子代理持有 weakref(A)
t=10  用户 /model 切到另一个模型 → CLI 重建 AIAgent → 父变成 B
      A 被 GC（没有其他引用）
t=20  子代理的 _delegate_parent_ref() → None
      → Tier 1 失败 → 子代理「不属于任何人」→ 无法 steer/stop
```

修法：Tier 2 —— 用**持久化的 session id** 判定。
`owner_agent_session_id` 是存在 record 里的字符串，不依赖对象存活。

而「resolving compression-rotation lineage」指的是：
上下文压缩会**轮换 session key**（见 [`08-memory-context-compression.md`](08-memory-context-compression.md)）。
所以比较时要把两边都解析到「当前 tip」再比。

### 9.4 `_is_descendant_of`：只能管自己的子树

[`:179`](../tools/delegate_tool_registry.py:179)：

```python
def _is_descendant_of(child_agent, parent_agent, max_hops=8) -> bool:
    """True when *child_agent* sits below *parent_agent* in the spawn tree (walks the
    ``_delegate_parent_ref`` weakref chain stamped at build time). Identity only —
    a parent may steer/stop its own children and grandchildren, never a sibling tree
    owned by another conversation."""
    ...
```

最后一句是**权限边界**：
- 你的子代理、孙子 → 你能管；
- 别人的子代理 → 你不能管（即使你能看到它的 id）。

`max_hops=8` 是一个防御性的上限，防止弱引用链出现环（理论上不该有，
但一个 bug 可能造出环，那这个循环会挂死）。

### 9.5 操作员的暂停开关

[`:39`](../tools/delegate_tool_registry.py:39)：

```python
def set_spawn_paused(paused: bool) -> bool:
    """Globally block/unblock NEW delegate_task spawns (active children keep running)."""
```

注意 **`NEW spawns`**：已经在跑的**不受影响**。

为什么？因为暂停的目的是「止血」（别再生新的了），
而不是「杀掉正在干活的」（那会丢工作）。

入口（[`delegate_task.py:499`](../tools/delegate_tool.py:499)）：

```python
if is_spawn_paused():
    return tool_error(
        "Delegation spawning is paused. Clear the pause via the TUI "
        "(`p` in /agents) or the `delegation.pause` RPC before retrying."
    )
```

错误信息里带了**怎么解除**，这是好文案的标准。

---

## 10. 停止扇出：本篇最容易漏的一环

### 10.1 问题

原文（[`tools/AGENTS.md:130`](../tools/AGENTS.md:130)）：

> **Stop fan-out:** a turn's hard interrupt reaches only `_active_children`;
> **background units are detached at dispatch**, so every stop surface
> (gateway `/stop` busy AND idle paths, TUI `session.interrupt`, ACP `cancel`,
> CLI `/stop` via `interrupt_all`) calls `async_delegation.interrupt_for_session` too.

拆解：

1. 父 agent 的 `interrupt()` 遍历 `_active_children`（一个列表）；
2. 但后台委派的子代理在派发时被 **`_detach_child`** 移出了这个列表（§5.5）；
3. 所以**硬中断到不了它们**；
4. 必须额外调用 `interrupt_for_session`，它遍历的是 `async_delegation` 的 `_records`。

**这就是「两个注册表」造成的问题**：同一批子代理，前期在 A 表，后期在 B 表。
停止逻辑必须同时查两张表。

### 10.2 五个入口

| 停止面 | 位置 | 备注 |
|---|---|---|
| gateway `/stop`（busy 路径） | `gateway/run.py` | 有 turn 在跑时 |
| gateway `/stop`（idle 路径） | `gateway/run.py` | 没有 turn 但在等结果时 |
| TUI | `tui_gateway` 的 `session.interrupt` | |
| ACP | `acp_adapter` 的 `cancel` | 编辑器发起的取消 |
| CLI | `cli.py` 的 `/stop` → `interrupt_all` | 用 `interrupt_all` 而不是 per-session |

**为什么 gateway 要两个路径？**

- **busy**：用户在一个 turn 中间按停止 → 要中断当前 turn；
- **idle**：turn 已结束，后台委派还在跑 → 用户按停止 → 没有 turn 可中断，
  但用户显然想停掉那个后台任务。

如果只做 busy 路径，就会出现「我按了停止，它还在跑」（因为 turn 已经结束了）。

**为什么 CLI 用 `interrupt_all` 而不是 `interrupt_for_session`？**

因为 CLI 是**单会话**进程：所有委派都属于这一个会话。
`interrupt_all`（[`async_delegation.py:1202`](../tools/async_delegation.py:1202)）更简单、更彻底。

而在 gateway（多会话）里必须用 `interrupt_for_session`，
否则「A 用户按停止，把 B 用户的子代理也杀了」。

### 10.3 深度 > 0 永远是同步

[`delegate_tool.py:772`](../tools/delegate_tool.py:772)：

```python
def _model_background_value(args, parent_agent=None) -> bool:
    """Background flag for the MODEL-facing dispatch path (registry fallback).
    Top-level delegations always run in the background — the model does not choose —
    for single tasks and fan-out batches alike (one async unit, one consolidated result);
    an orchestrator subagent (depth > 0) is the exception since it needs its workers'
    results within its own turn. The live path is ``run_agent._dispatch_delegate_task``;
    this mirrors it for the rare case the intercept is bypassed. Direct Python callers
    keep the synchronous default."""
    return not getattr(parent_agent, "_delegate_depth", 0) > 0
```

即：`depth == 0`（顶层）→ 后台；`depth > 0`（orchestrator 的子代理）→ 同步。

**两个理由**：

1. **语义**：一个 orchestrator 的任务是「扇出 → 综合 → 汇报」。
   如果它扇出的子代理是后台的，它就得结束 turn 才能拿到结果——
   但它是**子代理**，结束 turn 就等于结束自己。
2. **停止扩散**：因为深度>0 的子代理是**同步**的，它们挂在
   自己的父（那个 orchestrator）的 `_active_children` 上。
   于是停止信号可以**递归地**扇出：用户停 → 顶层父 → orchestrator → 它的 worker。

第 2 点是文档里明说的（[`AGENTS.md:130`](../tools/AGENTS.md:130)）：

> Depth>0 delegations are always synchronous (`_model_background_value`),
> so the stop recurses through the child's own `_active_children` fan-out.

即：只有**最顶层**需要特殊处理（因为它 detach 了）；
更深的层级靠普通的 `_active_children` 递归就够了。

### 10.4 被中断条目的 `summary`

[`AGENTS.md:130`](../tools/AGENTS.md:130)：

> an interrupted entry's `summary` is the child's last real assistant text
> (`_build_result_entry`).

即：即使用户中途停了，也能看到「它做到哪了、想到什么」。

这比 `summary: null` 好得多——父 agent 可以用这部分信息决定「要不要换个方式重试」。

### 10.5 为什么「停止扇出」值得单独一节

因为它是**静默失败**的典型：

- 用户按了停止；
- UI 显示「已停止」；
- **子代理还在跑，还在花钱**；
- 结果在 5 分钟后作为一条新消息出现 → 用户困惑「我不是停了吗？」

而这类 bug 极难在开发中发现，因为你必须**同时**：
1. 触发后台委派；
2. 在它 detach 之后；
3. 从五个入口之一停止；
4. 观察网络调用是否还在发生。

所以它被写进了 `AGENTS.md` 的硬性清单。

---

## 11. 子代理的 prompt

### 11.1 四段结构

[`delegate_tool_progress.py:178`](../tools/delegate_tool_progress.py:178)：

```python
def _build_child_system_prompt(goal, context=None, *, workspace_path=None, role="leaf",
                                max_spawn_depth=2, child_depth=1) -> str:
    """Focused system prompt for a child agent. role='orchestrator' appends a
    delegation-capability block (modeled on OpenClaw's buildSubagentSystemPrompt);
    its depth note is literal truth grounded in the passed config so the LLM
    can't confabulate nesting."""
```

构造顺序：

```
[1] "You are a focused subagent working on a specific delegated task."
[2] CONTEXT: <context>                     （若有）
[3] WORKSPACE PATH: <path>                 （若有）
    + 该 workspace 的 AGENTS.md / CLAUDE.md / .cursorrules 内容
[4] _COMPLETION_INSTRUCTIONS
[5] （仅 orchestrator）_ORCHESTRATOR_BLOCK + 深度说明
```

### 11.2 为什么 goal 不进 system prompt

[`:185`](../tools/delegate_tool_progress.py:185)：

```python
# The goal is the child's first user turn (see ``_ChildRun.await_child``).
# Keeping it out of the system prompt avoids sending OAuth Anthropic the
# same task in both roles, while preserving the normal user-turn contract.
```

两个理由，第二个更重要：

1. **不重复**：Anthropic 的 OAuth 通道会把 system prompt 与 user turn 分别计费/缓存，
   同一个任务写两遍是浪费。
2. **保持「user turn 契约」**：模型的训练分布是「system 说规则，user 说任务」。
   如果把任务写进 system，模型可能把它当成「长期角色设定」而不是「这次要做的事」。

### 11.3 项目上下文文件的显式注入

[`:197`](../tools/delegate_tool_progress.py:197)：

```python
# Project context files (AGENTS.md / CLAUDE.md / .cursorrules ...) via the SAME discovery/
# priority/cap logic as the main agent's prompt: children are built with skip_context_files=True,
# so without this a subagent works in a repo blind to its conventions. SOUL.md is skipped
# (identity belongs to the parent).
```

这是一个精巧的设计：

- 子代理 `skip_context_files=True`（因为它不该继承**父所在目录**的上下文）；
- 但它在**自己的 workspace** 里应该知道那个项目的规则；
- 所以**显式**加载 `workspace_path` 下的上下文文件。

`skip_soul=True` 是因为 `SOUL.md` 是**身份**（人格/偏好），
应该属于父，不该被子继承——否则 20 个子代理都用同一个人格，很怪。

### 11.4 完成指令里的两条实质性约束

[`:146`](../tools/delegate_tool_progress.py:146)：

```python
_COMPLETION_INSTRUCTIONS = (
    "\nComplete this task using the tools available to you. When finished, provide a clear, concise summary of:\n"
    "- What you did\n- What you found or accomplished\n- Any files you created or modified\n- Any issues encountered\n\n"
    "Important workspace rule: Never assume a repository lives at /workspace/... or any other container-style path "
    "unless the task/context explicitly gives that path. If no exact local path is provided, discover it first before "
    "issuing git/workdir-specific commands.\n\n"
    "Keep your final summary tight: lead with outcomes, prefer bullet points over paragraphs, and don't replay your "
    "whole process. Your response is returned to the parent agent as a summary, and overlong summaries crowd out the "
    "parent's context window."
)
```

两条**实质性**约束（不是套话）：

**（1）不要假设路径。**

模型很容易从训练数据里学到「项目在 `/workspace/`」。但 Hermes 跑在用户的真实机器上，
路径是 `/Users/x/project`。如果子代理盲目 `cd /workspace && git status`，会失败或跑到错误的地方。

**（2）摘要要短，因为它是**父的上下文预算**。**

这句解释了为什么：`overlong summaries crowd out the parent's context window`。
20 个子代理每个回 2000 字 = 40000 字进父的窗口——比整个任务还大。

配合 `_apply_summary_budget`（[`delegate_tool_results.py`](../tools/delegate_tool_results.py:290)）：

```python
entry["summary_full_path"] = spill_path
```

摘要超长时会被截断，**全文落盘**，路径记在 `summary_full_path` 里。
这样：父拿到短摘要（省窗口），但需要细节时可以读文件（不丢信息）。

### 11.5 orchestrator 的深度说明

[`:211`](../tools/delegate_tool_progress.py:211)：

```python
child_note = _LEAF_CHILDREN_NOTE if child_depth + 1 >= max_spawn_depth else _NESTED_CHILDREN_NOTE
parts.append(
    _ORCHESTRATOR_BLOCK
    + f"NOTE: You are at depth {child_depth}. The delegation tree is capped at max_spawn_depth={max_spawn_depth}. "
    + child_note
)
```

注释里的理由：

> its depth note is literal truth grounded in the passed config so the LLM **can't confabulate nesting**.

即：如果不告诉模型「你在第 1 层，上限是 2 层」，它可能会：
- 以为自己能无限委派 → 规划一个 5 层的任务 → 实际在第 2 层失败；
- 或者以为自己不能再委派 → 放弃本来可以的并行。

把**真实数字**写进 prompt，是被验证过的有效做法。

---

## 12. 两个隐蔽的进程级全局

### 12.1 `_last_resolved_tool_names`

[`model_tools.py:173`](../model_tools.py:173)：

```python
_last_resolved_tool_names: list[str] = []
```

这是一个**进程级全局**：最后一次工具解析的结果。它被 `execute_code` 等地方读取。

问题：构造一个子代理会触发工具解析 → 全局被改成**子的**工具列表。
如果父随后调 `execute_code`，它会看到子的工具（少了 `delegate_task`、`memory` 等）。

修法（[`delegate_tool_results.py:303`](../tools/delegate_tool_results.py:303)）：

```python
def _build_child_preserving_parent_tools(**kwargs):
    """Build a child without leaking its resolved toolset into the parent."""
    with _CHILD_CONSTRUCTION_LOCK:
        parent_tool_names = list(model_tools._last_resolved_tool_names)
        try:
            child = _build_child_agent(**kwargs)
        finally:
            model_tools._last_resolved_tool_names = parent_tool_names
    child._delegate_saved_tool_names = parent_tool_names
    return child
```

三件事：

1. **`_CHILD_CONSTRUCTION_LOCK`**：因为这是进程级全局，多个并发构造（两个父代agent 同时委派）
   会互相踩。构造必须串行化。
2. **save/restore**：构造期间无论成功失败都恢复。
3. **`_delegate_saved_tool_names`**：存到子上，供 `cleanup` 再恢复一次。

为什么需要第 3 点？因为子代理**运行期间**还会再次触发工具解析。
`cleanup`（[`delegate_tool_child_run.py:1061`](../tools/delegate_tool_child_run.py:1061)）：

```python
# Restore the parent's tool names so the process-global is correct for
# any subsequent execute_code calls or other consumers.
saved_tool_names = getattr(child, "_delegate_saved_tool_names", None)
if isinstance(saved_tool_names, list):
    model_tools._last_resolved_tool_names = list(saved_tool_names)
```

**推论（旧版文档提到了，值得展开）**：
在子代理运行期间，读这个全局的代码可能看到**暂时陈旧**的值——
实际上是「子的」工具列表。所以任何**依赖它做安全判断**的代码都是错的。

### 12.2 `_BATCH_ORDINALS`

[`delegate_tool_progress.py:234`](../tools/delegate_tool_progress.py:234)：

```python
_BATCH_ORDINALS: dict[str, dict[str, int]] = {}
_BATCH_ORDINALS_LOCK = threading.Lock()

def format_batch_tag(delegation_id, parent_agent=None) -> str:
    """Short human tag for a delegation batch: the parent's first fan-out is ``set 1``, its next distinct
    ...
```

它的作用是给人类看的标签：`[set 1 2/5]`。

为什么需要全局字典？因为「这是这个父的第几次扇出」——这个信息不属于任何单个对象，
它是**父子关系的计数**。

为什么用锁？因为多个子代理的进度回调可能并发触发（不同线程）。

这个全局是**良性**的（只是显示），但它和 12.1 是同一类东西：
**进程级可变状态 + 多线程 = 必须显式同步**。

---

## 13. 插件视角：稳定契约

`agent/subagent_lifecycle.py` 是给**插件**用的 API，与内部实现**解耦**。

### 13.1 为什么不用 `AIAgent` 对象

模块 docstring（[`:1`](../agent/subagent_lifecycle.py:1)）：

> Public, plugin-safe lifecycle API for delegated Hermes subagents:
> **immutable contracts, not `AIAgent` objects**. Plugins obtain it via
> `PluginContext.subagent_lifecycle`.

如果插件拿到 `AIAgent`：
- 它可以调任意方法（包括内部的、不稳定的）；
- 内部重构会破坏插件；
- 插件可能**改** agent 的状态。

不可变 dataclass 把面收窄到「读」：契约版本、id、状态、结果。

### 13.2 契约与限制

[`:24`](../agent/subagent_lifecycle.py:24)：

```python
PUBLIC_CONTRACT_VERSION = 1
_MAX_GOAL_CHARS = 16_000
_MAX_CONTEXT_CHARS = 32_000
_MAX_METADATA_BYTES = 8_192
_MAX_RESULT_CHARS = 32_000
_TERMINAL_RETENTION_SECONDS = 3_600
```

**为什么每个字段都有上限？** 因为插件是第三方代码。
一个 bug 的插件传一个 10MB 的 `context`，会让整个进程内存暴涨。
在**入口**处拒绝（抛 `SubagentLifecycleError`）比事后诊断容易。

### 13.3 九个状态

```python
class SubagentState(str, enum.Enum):
    PENDING = "PENDING"                    # 已接受，未启动
    STARTING = "STARTING"                  # 正在构造
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    INTERRUPTED = "INTERRUPTED"
    CANCEL_REQUESTED = "CANCEL_REQUESTED"  # 已请求取消，还没生效
    CANCELLED = "CANCELLED"
    UNKNOWN = "UNKNOWN"                    # 无法判定（owner 消失）
```

`CANCEL_REQUESTED` 与 `CANCELLED` 分开很重要：
- `CANCEL_REQUESTED`：请求已发出，子代理还在收尾；
- `CANCELLED`：真的停了。

合并成一个状态会让调用方无法区分「还在收尾」和「已经没了」。

### 13.4 HMAC capability

[`:393`](../agent/subagent_lifecycle.py:393)：

```python
@staticmethod
def _capability(subagent_id, parent_session_id, created_at) -> str:
    ...
    return hmac.new(_SECRET, value, hashlib.sha256).hexdigest()
```

`SubagentHandle` 带一个 `capability` 字段（[`:74`](../agent/subagent_lifecycle.py:74)）。
每次操作校验（[`:339`](../agent/subagent_lifecycle.py:339)）：

```python
expected = self._capability(handle.subagent_id, handle.parent_session_id, handle.created_at)
if not hmac.compare_digest(handle.capability, expected):
    ...
```

**为什么需要这个？** 因为插件可能自己「猜」一个 `subagent_id`
（比如它是从日志里看到的，或者从另一个插件的报告里拿到的）。

`capability` 是一个 HMAC：只有**真正创建**那个子代理的代码才拿到了它。
所以「拿到 handle」= 「被授权操作它」。

这是 **capability-based security**（能力安全）的经典模式，比「检查调用者身份」
更简单（不需要维护 ACL）。

用 `hmac.compare_digest` 而不是 `==` 是为了**时序攻击**防护
（逐字节比较会在第一个不同处提前返回，泄露前缀）。

### 13.5 `contract_version` 校验

[`:205`](../agent/subagent_lifecycle.py:205)：

```python
("contract_version", lambda v: type(v) is int and v == PUBLIC_CONTRACT_VERSION),
```

`type(v) is int` 而不是 `isinstance(v, int)`：因为 `True` 是 `int` 的实例，
`isinstance(True, int) == True`。用 `type()` 排除 bool 是一个常见但必要的严格性。

---

## 14. 配置总表

| 键 | 默认 | 作用 | 备注 |
|---|---|---|---|
| `delegation.max_concurrent_children` | 10 | 并行子代理数（前台与后台共用） | >10 时告警「成本线性增长」 |
| `delegation.independent_completions` | `false` | 拆成 per-group 完成单元 | 开启后模型可能被打散 |
| `delegation.max_spawn_depth` | 1 | 委派树最大深度 | 1 = 扁平（只能一层） |
| `delegation.orchestrator_enabled` | — | 是否允许 orchestrator 角色 | 与深度**同时**满足才生效 |
| `delegation.child_timeout_seconds` | `None` | 子代理**不活动**超时 | `None` = 无（靠心跳陈旧检测） |
| `delegation.subagent_auto_approve` | `false` | 子代理的危险命令自动批准 | 默认**拒绝** |
| `delegation.inherit_mcp_toolsets` | — | 子代理是否继承父的 MCP 工具集 | 显式指定 `toolsets` 时补充 |
| `delegation.max_iterations` | 250 | 子代理的迭代预算 | 调用方传的值**被忽略** |
| `delegation.oneshot_max_children` | 2 | 一次性会话的总子代理数 | `0` = 无限 |
| `delegation.worktree_isolation` | `false` | 每个子代理独立 git worktree | 仅 git + 本地后端 |
| `delegation.compression_threshold_tokens` | `None` | 子代理压缩的绝对上限 | 必须 ≥ 16000 |
| `delegation.pause` | — | 操作员暂停开关（RPC） | 只挡新 spawn |

环境变量（`_knob` 的三级回退）：

```
delegation.<key> > <ENV> > default
```

见 [`delegate_tool_config.py:61`](../tools/delegate_tool_config.py:61)：

```python
def _knob(key, env_var, parse, default, invalid_msg):
    """delegation.<key> > <env_var> > default. A config value that fails ``parse`` logs
    ``invalid_msg`` (``%r`` = the value) and yields the default; an env value that
    fails is silently ignored."""
```

**注意不对称**：config 值非法 → 记 warning；env 值非法 → 静默忽略。

为什么？因为 `config.yaml` 是用户手写的，警告能帮他改；
而 env 可能是 CI 系统注入的，用户改不了，警告只是噪音。

### 14.1 子代理的危险命令审批

[`delegate_tool_config.py:35`](../tools/delegate_tool_config.py:35)：

```python
# Subagent worker threads don't inherit the CLI's threading.local approval
# callback, so prompt_dangerous_approval() would fall back to input() and
# deadlock the parent's prompt_toolkit TUI. Every worker gets a non-interactive
# callback via ThreadPoolExecutor(initializer=...): deny by default, approve when
# delegation.subagent_auto_approve is true. Both warn for audit.
```

这是一个**死锁**问题：

```
主线程：prompt_toolkit 占着终端，等待用户输入
worker 线程：调用 input()  ← 也想要终端
→ 两个线程抢同一个 stdin → 死锁
```

修法：worker 线程用**非交互**回调（`_subagent_auto_deny` / `_subagent_auto_approve`）。

默认 deny 是**安全默认**：一个 20 个子代理并行跑的批，如果每个都能弹审批框，
用户会被淹没（而且会盲点「允许」）。

`subagent_auto_approve: true` 是显式的 YOLO 选择，且**仍然打 warning**（审计）。

---

## 15. 崩溃与边界情况

### 15.1 池满时的降级矩阵

| 场景 | 行为 |
|---|---|
| 会话不支持异步完成 | 整批同步，`note: "no_async"` |
| 池满，第一个 unit 被拒 | 整批同步，`note: "at_capacity"` |
| 池满，后续 unit 被拒 | 那个 unit 内联，结果进 `inline_results` |
| runner 抛异常 | 单个 `status: "error"` / 批 `results: []` |
| 父被中断 | 未完成的子代理标 `interrupted` 并放弃 |
| 子代理超时 | `status: "timeout"` + 分相诊断 |
| 陈旧判定 | `status: "timeout"`，error 说明「无进展」 |
| 陈旧但 2s 内返回 | 收**真实结果**而不是合成的 timeout |
| schema 未满足 | `status: "completed"` + `schema_valid: false` |
| owner 崩溃 | `status: "unknown"` + 恢复提示 |

### 15.2 超时诊断的分相

[`delegate_tool_child_run.py:918`](../tools/delegate_tool_child_run.py:918)：

```python
# A timeout BEFORE any API call is a black box without a diagnostic dump.
before_first_call = is_timeout and child_api_calls == 0
```

两个阶段的错误文案完全不同：

**`before_first_llm_call`**：

> the child never reached its first LLM request
> (prompt construction, credential resolution, or transport may be stuck)

**`after_llm_calls`**：

> a stalled provider request or an unresponsive network request

这个区分直接指向**不同的排查方向**：
- 前者：检查凭证、base_url、模型名；
- 后者：检查网络、provider 状态。

而且 `before_first_call` 时会 dump 一个诊断文件
（`_dump_subagent_timeout_diagnostic`），因为「零 API 调用」是彻底的黑盒。

### 15.3 `last_event_age`

[`:959`](../tools/delegate_tool_child_run.py:959)：

```python
# How long the child had been silent when the wait ended: distinguishes a slow provider from a runaway
# without transcript forensics (#116001).
"last_event_age": _child_last_event_age(child) if is_timeout else None,
```

一个数字就能回答「它是慢还是卡」：
- `last_event_age` 很小（比如 3 秒）→ 它在输出，只是慢；
- `last_event_age` 很大（比如 400 秒）→ 它真的没动。

不用去翻 transcript。

### 15.4 关闭延迟（`close_deferred`）

[`:964`](../tools/delegate_tool_child_run.py:964)：

```python
close_deferred = is_timeout and not future.done()
if close_deferred:
    _defer_close_after_timeout(child, future)
```

问题：超时了，但 worker 线程**还在跑**。
如果此时父线程调 `child.close()`，就会和 worker 的 `finally` 路径**并发**操作同一个对象。

所以：`close_deferred = True` → 不关，等 worker 自己结束。
`cleanup` 里（[`:1072`](../tools/delegate_tool_child_run.py:1072)）：

```python
if not close_deferred:
    _close_child(child, "Failed to close child agent after delegation")
```

代价：资源（沙箱、浏览器）晚一点释放。收益：不 race。

---

## 16. 测试约定

### 16.1 位置

`tests/tools/`（[`tools/AGENTS.md`](../tools/AGENTS.md:158)）：

> Test the handler through the registry (real dispatch), not the bare function only;
> assert contracts ("every registered tool has a toolset", "no schema description names
> a tool from another toolset") rather than tool counts.

### 16.2 为什么要「通过 registry 测」

直接测 `delegate_task(...)` 会漏掉：
- schema 与 handler 的参数名不一致（模型传 `tasks`，handler 期待别的）；
- `check_fn` 返回 False 导致工具被隐藏；
- `dynamic_schema_overrides` 的生成逻辑。

而这些都是**真实的失败源**。

### 16.3 契约测试 vs 计数测试

```python
# ✅ 契约：每个注册工具都有归属
def test_every_tool_has_toolset():
    for name in registry.all_names():
        assert registry.toolset_for(name), name

# ❌ 计数：每加一个工具就红
assert len(registry.all_names()) == 55
```

第二类是根 `AGENTS.md` 明确禁止的「变更检测器」。

### 16.4 子进程 env 隔离值得单独测

[`tools/AGENTS.md`](../tools/AGENTS.md:100)：

> a child that acts FOR the served profile ... uses
> `environments/local.py::served_profile_child_env(target_home=, inherit_credentials=)`:
> launch-profile `.env` / `TERMINAL_*` residue dropped (`strip_launch_profile_env`),
> the target home pinned, only the target's own secrets overlaid.
> `os.environ.copy()` / `dict(os.environ)` pins the launch profile;
> **contextvars do not cross process boundaries, so resolve before `Popen`.**

最后一句是测试要点：**ContextVar 不过进程边界**。
所以「在 ContextVar 里设置了正确的 home」不代表子进程拿到的是它——
必须在 `Popen` 之前**解析成字符串**并显式放进 env。

而 `UNSCOPED_SECRET` 的报错意味着「spawn 点有 bug」，不是「加个 fallback」。

### 16.5 E2E

[`AGENTS.md`](../tools/AGENTS.md:158)：

> Approval/security-boundary tools are E2E'd with real imports against a temp `HERMES_HOME`
> (see `tests/tools/test_approval_config_readonly.py`).

为什么 approval 类要 E2E？因为它们的正确性依赖**真实的 config 加载 + 真实的注册表状态**，
mock 掉任何一环都会让测试变成「测试 mock」。

---

## 17. 自检题

### A 组：隔离

1. 委派隔离了哪 9 个维度？哪两个是**有意共享**的？
2. 为什么子代理不能有 `clarify`？会怎么失败？
3. 为什么 `memory` 被禁？如果允许，20 个并发子代理会发生什么？
4. 为什么 `cronjob_manage` 被禁？这个禁令防的是「现在」还是「未来」？
5. `send_message` 的禁令注释是 "no cross-platform side effects" —— 这条原则怎么表述？
6. 为什么子代理的工具集是「交集」而不是「并集」？这条保证了什么？
7. `_expand_parent_toolsets` 为什么需要 `resolve_toolset` 而不是简单的名字集合？
8. 为什么 `kanban` 对子代理无条件禁用？和「工具访问权不是所有权」是什么关系？
9. 子代理为什么 `skip_context_files=True` 却仍注入 workspace 的 `AGENTS.md`？
10. 为什么 `skip_soul=True`？
11. `_apply_child_cache_ttl` 为什么把 1h 降到 5m？算一笔账。
12. `delegation.compression_threshold_tokens: true` 会发生什么？为什么？

### B 组：角色与深度

13. `role` 参数为什么被忽略？如果模型能声明 `orchestrator` 会绕过什么？
14. `max_spawn_depth = 1`（默认）意味着几层？
15. 成为 orchestrator 需要同时满足哪两个条件？
16. 为什么工具集要「双重保险」（从 disabled 去掉 + 加回 enabled）？
17. `_ORCHESTRATOR_BLOCK` 里的深度说明为什么必须写真实数字？
18. `_normalize_role` 保留着做什么？既然 `role` 被忽略。

### C 组：执行路径

19. 同步路径为什么不用 `as_completed()`？
20. 为什么用 `DaemonThreadPoolExecutor`？不用会怎样？
21. 后台派发的三条降级路径分别是什么条件？
22. 为什么「第一个 unit 被拒」要整批同步，而「后续 unit 被拒」只内联那个？
23. 完成单元默认是几个？开启拆分后怎么分？
24. `replace(batch, children=ch)` 为什么共享 `task_list`？
25. `slot_key` 解决什么问题？如果不共享 slot 会怎样？
26. 池为什么按 **unit 数**而不是 slot 数定大小？
27. `_record_finished_child` 为什么要在每个子代理完成时就落盘？
28. `detach` 为什么要「提交前」做，而「被拒后」要 restore？

### D 组：持久化与恢复

29. 后台委派是进程本地的——那持久账本持久的是什么？
30. 要「任务跑完」而不是「结果不丢」，该用什么？
31. `_MAX_COMPLETION_REPLAY_AGE_S` 为什么是 48h？
32. `defer` 与 `release` 的区别？各在什么时候用？
33. `dropped` 与 `delivered` 的区别为什么叫「keeps the ack honest」？
34. `is_interim_delegation_event` 防的具体 bug 是什么？画一遍时序。
35. `record_unit_child` 把「单子代理 unit 的剩余窗口」缩短到多小？
36. 崩溃恢复为什么要附 transcript 尾巴 + git 快照？
37. 孤儿 sweep 覆盖哪个时间窗？启动重放覆盖哪个？
38. `restored=True` 为什么是一个「怀疑标记」？#64484 是什么现象？
39. 为什么 `(pid, 启动时间)` 而不是裸 pid？

### E 组：陈旧与控制

40. 双阈值 450s / 1200s 分别在什么时候用？为什么差 2.7 倍？
41. 为什么不能只看 `api_call_count`？
42. `_STALE_RESULT_GRACE_SECONDS = 2.0` 在救什么？
43. 后台监控为什么先 interrupt 再等 120 秒，而不是直接强杀？
44. `_context = copy_context()` 为什么必须存？
45. `steer` 的文本附在哪里？为什么不是新消息？
46. `missed_steer` 是什么情况？
47. `_owns_subagent_record` 的两级判定各解决什么问题？举出 Tier 1 失败的时序。
48. `_is_descendant_of` 的权限边界是什么？`max_hops=8` 防什么？
49. `set_spawn_paused` 为什么不影响已运行的子代理？

### F 组：停止扇出

50. 为什么「一轮的硬中断只到 `_active_children`」是个问题？
51. 列出五个停止入口。
52. gateway 为什么要 busy 和 idle 两条路径？
53. 为什么 CLI 用 `interrupt_all` 而 gateway 用 `interrupt_for_session`？
54. 深度 > 0 为什么永远同步？两个理由。
55. 被中断条目的 `summary` 为什么不是 null？
56. `_attach_child` 的「迟到者补偿」防什么？

### G 组：全局与契约

57. `_last_resolved_tool_names` 为什么必须 save/restore 两次？
58. 在子代理运行期间读这个全局会看到什么？为什么危险？
59. 插件为什么不拿 `AIAgent` 对象？
60. `PUBLIC_CONTRACT_VERSION` 与 `contract_version` 校验的意义？
61. `CANCEL_REQUESTED` 与 `CANCELLED` 为什么分开？
62. HMAC capability 防什么？为什么用 `compare_digest`？
63. `type(v) is int` 而不是 `isinstance(v, int)`，为什么？
64. `_knob` 为什么对 config 非法值告警、对 env 非法值静默？

---

<details>
<summary><b>参考答案要点</b></summary>

1. 对话历史、system prompt、terminal 会话、file-ops 缓存、记忆、项目上下文、工具集、模型请求/缓存、迭代预算。共享：凭证池、进程。
2. 它没有 transport，问谁都收不到回答 → 卡到超时。
3. 记忆是共享 `MEMORY.md`，并发写冲突 + 20 份无关内容污染用户记忆。
4. 未来：它能在父的名义下排新任务，失控扇出会在**之后**继续花钱。
5. 子代理可以做本地、可回滚的事；不能做对外不可撤销的事。
6. 子代理是父的降级，永不获得父没有的工具（防权限提升）。
7. 父可能用复合工具集（`hermes-cli`），子请求 `web`；裸名字交集会误拒。展开按工具集合包含关系，仍保证不越权。
8. `kanban` 工具会把「工具可见」误当「拥有任务」，子代理可能 `kanban_complete` 父的任务。
9. 它不该继承父所在目录的规则，但应知道自己 workspace 的规则。
10. `SOUL.md` 是身份（人格），属于父；20 个子代理共用一个人格不合理。
11. 1h 写入约 2x，5m 约 1.25x；子代理几分钟就死，付贵的写入却吃不到保留收益。
12. YAML `true` → `int(True)=1` → 每次调用都压缩。所以校验拒绝 bool。
13. 绕过 `max_spawn_depth` 与 `orchestrator_enabled` —— 模型自我授权。
14. 一层：parent(0) → child(1)，child 不能再委派。
15. `orchestrator_enabled` 为真 **且** `child_depth < max_spawn_depth`。
16. `enabled` 与 `disabled` 是两个通道，最终 `enabled ∩ ¬disabled`；只改一处会被另一处抵消。
17. 否则模型 confabulate 嵌套层数：规划 5 层（实际 2 层失败）或放弃本可并行的层级。
18. 宽容入口：非法角色收敛为 leaf 并记 warning，而不是抛错。
19. `as_completed()` 会阻塞到下一个完成；父被中断时若有卡死的子代理，父永远醒不来。
20. 普通池的 worker 非 daemon，解释器退出会等它们；卡在 I/O 的 worker 让进程退不出去。
21. `no_async`（会话不支持）、`at_capacity`（第一个 unit 被拒）、`inline`（后续 unit 被拒）。
22. 整批同步避免「结果分两处出现」；后续内联因为已有后台 unit，且静默丢任务更糟。
23. 默认 1 个（整批）；开启后按 `group` 分，未分组各成一个。
24. 结果条目的 `task_index` 索引整个调用的 goals，摘要格式统一。
25. 一次调用拆成 8 个 unit 不该算 8 个并发槽；不共享则容量凭空翻倍并互相挤掉。
26. 8 个 unit 共享 1 个 slot，但池必须能同时跑 8 个，否则 5 个排队、结果迟迟不来。
27. 崩溃时这部分子结果能重放，只丢未完成的。
28. 提交前 detach 防「worker 已启动但仍收到父的 stop」；被拒后 restore 因为要内联跑、仍需能被停。
29. 只持久「结果与状态」，不持久「执行」。父死了子代理也死了。
30. `cronjob` 或 `terminal(background=True, notify_on_complete=True)`。
31. 让周五晚上的结果周一早上还能送达。
32. `defer` 不消耗尝试次数（时机不对）；`release` 消耗（失败重试）。
33. `delivered` 会谎称用户看到；`dropped` 承认没送到且不会再送，指标不说谎。
34. 早期「任务 2 失败」通知与最终结果共享 `delegation_id`；早期通知 claim+ack 那一行 → 最终结果被判重复而丢弃。
35. 从「unit 全部完成后」缩到「每个子代理完成的那一刻」。
36. 「结果未知」不足以行动；有了 transcript 尾巴与 git 状态，父能判断「其实做完了」或「从哪继续」。
37. sweep：owner 在**本进程已运行时**死的；启动重放：owner 在**本进程启动前**死的。
38. 来自**上一个进程**，本进程的消费者不能证明所有权；否则新会话继承死会话的结果。
39. PID 会复用；裸 pid 存活检查会把「任务卡住」误判为「还在跑」。
40. 空闲 450s（正常一轮几秒）；在工具里 1200s（长编译/测试可能 10 分钟）。
41. 慢模型流式生成 90 秒期间 `api_call_count` 不变，会被误杀；`last_activity_ts` 每 chunk 刷新。
42. 子代理已写好答案正在收尾时被判定超时；再等 2 秒收真实结果而非合成 timeout。
43. 让子代理走正常 finalize 产出真实结果；120s 是收尾（取消请求、flush、hook）的宽限。
44. 单例监控线程有空的 Context，强制 finalize 会写**启动 profile** 的 state.db。
45. 附在最后一个 tool result 上；保持 user/assistant 交替且不污染 assistant 输出。
46. 接受时还有活着的边界，但传之前子代理已结束。
47. Tier 1 弱引用链（快）；Tier 2 session id lineage（防父重建）。时序：`/model` 重建 AIAgent → 旧父被 GC → `_delegate_parent_ref()` 为 None。
48. 只能管自己的子树（子/孙），不能管别人的；`max_hops=8` 防弱引用链出现环时挂死。
49. 目的是止血（别新增），不是丢弃正在干的工作。
50. 后台 unit 在派发时被 detach，不在 `_active_children` 里，硬中断到不了。
51. gateway `/stop` busy、gateway `/stop` idle、TUI `session.interrupt`、ACP `cancel`、CLI `/stop`→`interrupt_all`。
52. busy 有 turn 可中断；idle 时 turn 已结束但后台还在跑，用户仍想停。
53. CLI 单会话（更彻底更简单）；gateway 多会话，不能杀别人的。
54. ①orchestrator 结束 turn 就等于结束自己，必须当场拿结果；②同步才能靠 `_active_children` 递归扇出。
55. 让父能看到「做到哪、想到什么」，可决定换法重试。
56. 在 stop 之后才 attach 的子代理会错过快照，立即补发 stop 避免变成孤儿。
57. 构造期 save/restore（防泄漏给父）+ 运行期 cleanup 再恢复（运行期再次被改）。
58. 看到的是**子的**工具列表；任何据此做安全判断的代码都是错的。
59. 会耦合内部实现、可调内部方法、可能改 agent 状态。
60. 契约版本变化时明确拒绝，而不是「长得像就用」。
61. 收尾中 vs 真的没了；合并后调用方无法区分。
62. 防插件伪造/猜测 `subagent_id` 操作别人的子代理；`compare_digest` 防时序攻击。
63. `isinstance(True, int) == True`，`type()` 排除 bool。
64. config 是用户手写的（可改）；env 可能来自 CI（改不了），警告只是噪音。

</details>

---

## 18. 小结

压缩成十句话：

1. **子代理是父的降级**：工具集取交集、11 个工具被禁、`kanban` 无条件禁、记忆与项目上下文隔离。
2. **角色由深度推导，不由模型声明**；`role` 参数被忽略是为了不让模型自我授权。
3. **同步与后台的真正区别是「结果回到哪里」**：后台结果只在 turn **之间**注入，
   所以 schema 反复强调「END YOUR TURN，不要 poll」。
4. **完成单元共享 `slot_key`**：拆分投递不会让容量翻倍；但池按 unit 数定大小，
   否则排在队里的 unit 迟迟不开始。
5. **两个注册表 = 停止扇出的根本难点**：活动时在 `_active_children`，
   后台时在 `async_delegation._records`，五个停止入口必须两边都查。
6. **深度 > 0 永远同步**：既因为 orchestrator 必须当场拿结果，
   也因为这样停止能靠普通的 `_active_children` 递归扇出。
7. **后台委派是进程本地的**：账本保「结果不丢」，不保「任务跑完」；
   要跑完用 cron 或后台终端进程。
8. **不用墙钟超时，用进度**：`iteration` / `current_tool` / `last_activity_ts` 三信号，
   双阈值（空闲 450s / 工具中 1200s），先 interrupt 再等 120s grace。
9. **一切不可变契约化**：插件拿到的是 dataclass + HMAC capability，
   不是 `AIAgent`；每个字段都有上限。
10. **进程级全局必须显式 save/restore + 加锁**：
    `_last_resolved_tool_names` 是典型，运行期读到的是子的工具列表。

**下一篇** → [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)：
profile 是什么、`HERMES_HOME` 怎么解析、一个进程怎么服务多个 profile，
以及为什么「作用域」这个词在本篇（`delegated_child_context`）
和下一篇（`_profile_cron_scope`）都是同一个主题。
