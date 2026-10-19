# 08 · 记忆、上下文引擎与上下文压缩

> 目标：分清三个容易混淆的子系统——**记忆（memory）**、**上下文引擎（context engine）**、
> **压缩（compression）**——以及它们各自如何与「缓存铁律」共存。

---

## 1. 三者的区别（先立骨架）

| 子系统 | 解决的问题 | ABC / 实现 | 配置键 |
|---|---|---|---|
| **记忆** | 跨会话的长期知识（用户偏好、事实） | [`agent/memory_provider.py`](../agent/memory_provider.py:1) ABC + [`agent/memory_manager.py`](../agent/memory_manager.py:1) 编排 | `memory.provider` |
| **上下文引擎** | 何时/如何压实对话上下文、追踪用量 | [`agent/context_engine.py`](../agent/context_engine.py:1) ABC + [`agent/context_compressor.py`](../agent/context_compressor.py:1) 默认 | `context.engine` |
| **压缩** | 上下文超阈值时的实际处理（剪枝 + 摘要） | 引擎内部实现 + [`agent/compression_facade.py`](../agent/compression_facade.py:1) | `compression:` |

> 记忆是**内容**层，上下文引擎是**策略**层，压缩是**执行**层。

---

## 2. 记忆（Memory Providers）

### 2.1 ABC 与生命周期

[`agent/memory_provider.py`](../agent/memory_provider.py:1) 的 docstring：

> 插件位于 `plugins/memory/<name>/`，经 `memory.provider` 激活（**一次只能有一个外部 provider**）。
> 生命周期由 MemoryManager 驱动：
> `initialize → system_prompt_block / prefetch / sync_turn（每轮） → tool dispatch → shutdown`，
> 外加可选的 `on_*` hooks。

核心方法：`sync_turn`、`prefetch`、`shutdown`，以及可选的 `post_setup`。

### 2.2 内置 store 的哨兵值

```python
CORE_MEMORY_PROVIDER_SENTINELS = frozenset({"", "default", "builtin", "built-in", "none"})
```

`is_core_memory_provider(name)` 判断 `memory.provider` 选的是内置 store 还是外部插件。
**内置 store 是核心**：doctor、migration、依赖刷新绝不把它当插件查找。

### 2.3 后台线程必须带上 contextvars

这是 profile 隔离的一个关键实现细节：

```python
def ctx_bound(fn):
    ctx = contextvars.copy_context()
    return lambda *a, **kw: ctx.run(fn, *a, **kw)

def spawn_context_thread(target, *, name, daemon=True, args=(), kwargs=None):
    """每个 memory-provider 后台任务（prefetch、sync、writer loop）都必须走这里。"""
    return threading.Thread(target=ctx_bound(target), ...)
```

**为什么**：profile 隔离是「ContextVar 作用域的 HERMES_HOME 覆盖 + 每轮 secret scope」。
用空 context 启动的 worker 会**静默落到默认 profile**（或在 secrets 上 fail closed）。

> 这条规则适用于**所有**后台线程，不止 memory：裸 `threading.Thread` 会丢作用域。

### 2.4 记忆 provider 的发现（bundled-first，与其它插件相反）

[`plugins/memory/__init__.py`](../plugins/memory/__init__.py:1) 的解析顺序：

```text
bundled → $HERMES_HOME/plugins/ → ./.hermes/plugins/（需 opt-in）
        → hermes_agent.memory_providers entry points
```

**bundled-first**——因为 provider 是按名字激活的，所以用户丢进来的同名目录**不能遮蔽**随附的那个
（这与「通用插件」的 later-wins 相反）。枚举时**不 import**。

### 2.5 策略：核心不再新增内置 memory provider

来自 [`plugins/AGENTS.md`](../plugins/AGENTS.md:19)：`plugins/memory/` 已关闭，
新 provider 作为**独立仓库**实现同一个 `MemoryProvider` ABC，经 `hermes memory setup` / `post_setup()` 集成。

### 2.6 记忆在 prompt 中的位置

- 内置 MEMORY 快照（`MEMORY.md`）与 USER 画像（`USER.md`）属于 **volatile 层**
- 外部 memory provider 的 block 也在 volatile 层
- 都是**冻结**的（会话期间不随写入变化）——这是缓存铁律的要求
- 记忆内容进入 egress 前会做脱敏：
  [`agent/context_engine.py`](../agent/context_engine.py:25) 的 `sanitize_memory_context`
  会 redact 敏感文本与 URL 凭证，超长则首尾截断（6000 字符上限，头 4000 + 尾 1500）

---

## 3. 上下文引擎（Context Engine）

### 3.1 ABC

[`agent/context_engine.py`](../agent/context_engine.py:48) 的 `ContextEngine` 是**所有上下文引擎必须实现的基类**。

生命周期（docstring）：

```text
on_session_start()
  → 每个 API 响应调用 update_from_response()
  → 每轮 should_compress() / compress()
  → on_session_end()   ← 只在真实会话边界（CLI 退出、/reset、网关过期），绝不每轮
```

引擎负责：
- 决定何时压实触发（`should_compress()`）
- 执行压实（`compress()`）
- 可选暴露 agent 可调用的工具（如 `lcm_grep`）
- 追踪 API 响应的 token 用量

### 3.2 选择与解析

配置在 `config.yaml` 的 `context.engine`：

```yaml
context:
  engine: "compressor"    # 默认——内置有损摘要
  engine: "lcm"           # 示例——提供无损上下文的插件
```

解析顺序（[`context-compression-and-caching.md`](../website/docs/developer-guide/context-compression-and-caching.md:55)）：

1. 查 `plugins/context_engine/<name>/` 目录
2. 查通用插件系统（`register_context_engine()`）
3. 回退到内置 `ContextCompressor`

> **插件引擎永不自动激活**——用户必须显式把 `context.engine` 设为插件名。默认 `"compressor"` 永远用内置。

### 3.3 可见状态消息

`automatic_compaction_status_message(engine, phase=..., default_message=...)` 产生 host 可见的压实状态。
引擎可以通过 `emit_automatic_compaction_status = False` 抑制，
或用 `get_automatic_compaction_status_message(...)` 自定义。

---

## 4. 双层压缩系统（最容易记混的部分）

Hermes 有**两个独立运作**的压缩层：

```text
                     ┌──────────────────────────┐
  入站消息 ─────────► │   Gateway Session Hygiene │  在 85% 上下文触发
                     │   （agent 之前，粗估）     │  大会话的安全网
                     └─────────────┬────────────┘
                                   ▼
                     ┌──────────────────────────┐
                     │ Agent ContextCompressor  │  在 50% 触发（默认）
                     │ （循环内，真实 token）     │  常规上下文管理
                     └──────────────────────────┘
```

来源：[`context-compression-and-caching.md`](../website/docs/developer-guide/context-compression-and-caching.md:66)

### 4.1 网关会话卫生（85% 阈值）

位于 [`gateway/run_turn.py`](../gateway/run_turn.py:1)（搜索 "Session hygiene"）。
这是 agent 处理消息**之前**运行的**安全网**，防止会话在轮次之间长得过大时（例如
Telegram/Discord 隔夜累积）导致 API 失败。

- **阈值**：固定为模型上下文长度的 85%
- **token 来源**优先级：上一轮 API 报告的真实 token → 会话行上持久化的 usage anchor
  （真实计数 + 此后追加内容的增量；能扛住网关重启）→ 粗略的字符估算
  （`estimate_messages_tokens_rough`）
- **触发条件**：仅当 `len(history) >= 4` 且压缩已启用
- **目的**：兜住逃过 agent 自身压缩器的会话

> **为什么网关阈值比 agent 高**：设成 50%（与 agent 相同）会导致长网关会话**每一轮都过早压缩**。

### 4.2 Agent ContextCompressor（50% 阈值，可配置）

位于 [`agent/context_compressor.py`](../agent/context_compressor.py:1)。
这是**主压缩系统**，跑在 agent 的工具循环内，能拿到准确的、API 报告的 token 计数。

算法（[`agent/AGENTS.md`](../agent/AGENTS.md:83)）：

1. **优先剪枝旧工具结果**（不调用 LLM）
2. 然后挑选边界
3. 然后用 `auxiliary` 压缩模型生成**结构化摘要**

细节：
- 原地压实保持**单一稳定的 session id**
- 原生 Responses/Codex 压实路径是 provider 特定的
- 摘要流卡住会**在 `auxiliary.compression.fallback_chain` 上重试一次**
- 重复卡住（卡顿类失败已在冷却阶梯上）→ 通过同一管线以**确定性 fallback 摘要**结束
  （绝不在 lease/fence 之外提交剪枝）
- provider 证明溢出后有**失败冷却**

### 4.3 手动压缩

所有界面（CLI、gateway、TUI、ACP）的 `/compress` 都走
[`agent/conversation_compression_manual.py`](../agent/conversation_compression_manual.py:1)
的 `compress_now`——**一个解析器**处理 `here [N]` / focus / `--preview` / `--aggressive`。
各界面只解析自己的 argv、安装 `after_messages` 并渲染。

**压缩是唯一被批准的缓存破坏点**——保持它是唯一的一个。

---

## 5. Token 计量：usage anchor

每个压实门（turn 开始的 preflight、idle、pre-API 压力、post-tool）都**先问 usage anchor**
（[`agent/usage_anchor.py`](../agent/usage_anchor.py:1)）：

- provider 上一次的 prompt 与 completion token 计数
- **加上**「自那次响应以来追加的消息」的粗略估算

anchor 用**内容指纹**标识被计价的 transcript，所以它能扛住网关每轮从 DB 重读历史；
它被持久化在会话行上，所以新进程（`--resume`、desktop 每轮 `serve`）能在持久 transcript 仍匹配时恢复它。

**压实、会话重置、codex-native 压实都会清除它。**

对于内置引擎的 turn-start 与 pre-API 阈值门：没有 anchor 时（首个请求、rewind/编辑重发），
对整个上下文的粗略估算即使超阈，也会**等一个请求**拿到 provider 证据再决定。

来源：[`context-compression-and-caching.md`](../website/docs/developer-guide/context-compression-and-caching.md:107)

---

## 6. 压缩与会话血缘的关系

- 就地压实：旧行 `active=0` 归档，保留上下文 `active=1` 插入（见 [`07-state-and-session.md`](07-state-and-session.md)）
- 拆分会话时用 `parent_session_id` 形成血缘链
- 子代理血缘用 `owner_agent_session_id` → 压缩 tip 同一条脊梁

---

## 7. 相关兄弟模块速查

| 模块 | 用途 |
|---|---|
| [`agent/compression_facade.py`](../agent/compression_facade.py:1) | 压缩门面（`_compress_context`） |
| [`agent/conversation_compression.py`](../agent/conversation_compression.py:1) | 会话压缩 |
| [`agent/micro_compaction.py`](../agent/micro_compaction.py:1) | 微压实 |
| [`agent/native_compaction.py`](../agent/native_compaction.py:1) | provider 原生压实 |
| [`agent/turn_context_compaction.py`](../agent/turn_context_compaction.py:1) | turn 内压实 |
| [`agent/compression_marker.py`](../agent/compression_marker.py:1) | 压缩标记 |
| [`agent/context_compressor_prellm.py`](../agent/context_compressor_prellm.py:1) | LLM 前剪枝 |
| [`agent/context_compressor_summary.py`](../agent/context_compressor_summary.py:1) | 摘要生成 |
| [`agent/context_compressor_telemetry.py`](../agent/context_compressor_telemetry.py:1) | 遥测 |
| [`agent/conversation_compression_manual.py`](../agent/conversation_compression_manual.py:1) | 手动 `/compress` |

微压实专门文档：[`micro-compaction.md`](../website/docs/developer-guide/micro-compaction.md:1)。

---

## 8. Curator（技能生命周期，顺带一提）

[`agent/curator.py`](../agent/curator.py:1) + [`agent/curator_backup.py`](../agent/curator_backup.py:1)
实现技能 curator：跟踪 agent 创建技能的用量并自动归档陈旧者。

- 归档去 `~/.hermes/skills/.archive/`（可恢复）
- CLI：[`hermes_cli/curator.py`](../hermes_cli/curator.py:1) → `hermes curator status|run|pause|resume|pin|unpin|archive|restore|prune|backup|rollback`
- 遥测：[`tools/skill_usage.py`](../tools/skill_usage.py:1) 拥有 `~/.hermes/skills/.usage.json`
- 配置：`curator:` (`enabled, interval_hours, min_idle_hours, stale_after_days, archive_after_days, backup.*`)
- 它的 LLM 调用走 `auxiliary` 路由

不变量：只碰 `created_by: "agent"` 的技能；**永不删除**（归档是上限）；被 pin 的技能豁免一切自动转移。

---

## 9. 本篇小结与下一步

- **记忆**是内容层（provider ABC + manager 编排，bundled-first，一次一个外部 provider）。
- **上下文引擎**是策略层（ABC + `context.engine` 选择，插件永不自动激活）。
- **压缩**是执行层，**双层**：网关卫生 85% 安全网 + agent 压缩器 50% 主系统。
- 压缩是**唯一**被允许打破 prompt 缓存的机制。
- 所有 memory 后台线程必须走 `spawn_context_thread` 以携带 profile 作用域。

下一步 → [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md)：消息网关与平台适配的完整机制。
