# 08 · 记忆、上下文引擎与上下文压缩

> **这一章讲什么**：三个最容易被混为一谈的子系统——**记忆（memory）**、**上下文引擎（context engine）**、
> **压缩（compression）**——各自解决什么问题、边界在哪、内部怎么实现，以及它们如何与全书最重要的一条
> 不变量共存：**prompt 缓存的前缀不可变，压缩是唯一被批准的破坏点**。
>
> **怎么读**：如果你只想知道三者区别，读 §1；如果你想改压缩行为，读 §5～§10；如果你想写一个记忆 provider
> 或上下文引擎插件，读 §2、§3。
>
> **相对旧版的改动**：旧版 269 行、9 节，只列出了「有什么」。这一版补上了**为什么这样写**：压缩的四个
> phase 逐步拆解、阈值公式的三种退化场景、失败分类与冷却阶梯、lean tail 的来历、usage anchor 为什么用
> 内容指纹而不是行号、`_SUMMARY_ROUTE_PIN` 为什么必须是 ContextVar、micro-compaction 默认关闭的理由。
> 全篇从 269 行扩到约 1700 行，新增 §0 前置概念、§5 全流程、§6 阈值数学、§7 anchor 细节、
> §8 失败模式、§9 三条非主线压缩路径、§12 自检题。

---

## 目录

- [§0 前置概念：上下文为什么会满](#0-前置概念上下文为什么会满)
- [§1 三方职责与文件地图](#1-三方职责与文件地图)
- [§2 记忆：内容层](#2-记忆内容层)
- [§3 上下文引擎：策略层](#3-上下文引擎策略层)
- [§4 双层压缩：两个独立运作的安全网](#4-双层压缩两个独立运作的安全网)
- [§5 `compress()` 全流程：四个 phase](#5-compress-全流程四个-phase)
- [§6 阈值数学：什么时候触发](#6-阈值数学什么时候触发)
- [§7 usage anchor：token 计量的唯一可信来源](#7-usage-anchortoken-计量的唯一可信来源)
- [§8 失败模式、冷却与刹车](#8-失败模式冷却与刹车)
- [§9 三条非主线压缩路径](#9-三条非主线压缩路径)
- [§10 与血缘、持久化的交界](#10-与血缘持久化的交界)
- [§11 Curator：技能生命周期](#11-curator技能生命周期)
- [§12 自检题](#12-自检题)
- [§13 小结与下一步](#13-小结与下一步)

---

## §0 前置概念：上下文为什么会满

如果你是从前端转过来的，先建立一个直觉模型。

### 0.1 LLM 是纯函数，对话是「每次重发一遍」

一次 API 调用的输入长这样：

```json
{
  "model": "claude-sonnet-4",
  "system": "<系统提示词，几千 token>",
  "tools": [ ... 55 个工具 schema，几千到几万 token ... ],
  "messages": [
    {"role": "user", "content": "帮我修这个 bug"},
    {"role": "assistant", "content": null, "tool_calls": [...]},
    {"role": "tool", "tool_call_id": "...", "content": "<读文件的全文，可能 20K token>"},
    {"role": "assistant", "content": "我改了 X"},
    ... 几百条 ...
  ]
}
```

模型**没有记忆**。它不会「记住上一轮」。每一轮都是把**整个 messages 数组重新发一遍**。

这带来两个直接后果：

1. **成本随轮次平方增长**。第 N 轮要重新发送前 N-1 轮的全部内容。
2. **窗口会满**。`model` 有硬上限（比如 200K token），到达时 provider 返回 400，会话直接失败。

前端类比：想象你的状态管理不是 `store`，而是**每次渲染都把整个 action 历史序列化后发给后端**。
前 10 分钟很爽（可回溯、可重放），第 500 个 action 之后 payload 就炸了。

### 0.2 Prompt caching：provider 侧的「前缀缓存」

为了不让上面那件事贵到无法使用，provider 提供了 **prompt caching**：

```text
请求 1: [A B C D]           → 缓存 miss，按全价计费，同时在 [A B C D] 末尾打一个缓存点
请求 2: [A B C D E]         → [A B C D] 命中缓存（按 1/10 价格计），只有 E 全价
请求 3: [A B C D E F]       → [A B C D E] 命中缓存
请求 4: [A B C D X E F]     → ✗ 全 miss！因为第 5 个位置变了，后面全部失效
```

关键点：**匹配是字节级前缀匹配**。改动中间任何一个字符，从那个位置往后全部失效。

前端类比：这是 `React.memo` + 结构共享，但**更严格**——不是「引用相等」，是「序列化后逐字节相等」。
你在数组中间 `splice` 进一个元素，后面所有的 memo 全部失效。

所以 Hermes 有一条贯穿全书的铁律（见 [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md)）：

> **每会话的 system prompt 只构建一次；中途不换 toolset、不重载记忆、不改过去的 context。
> 唯一的例外是上下文压缩。**

这一章讲的就是那个「唯一的例外」。

### 0.3 三个词的区别，一句话版本

| 词 | 一句话 | 前端类比 |
|---|---|---|
| **记忆** | 跨会话的长期知识，进 system prompt | `localStorage` / IndexedDB |
| **上下文引擎** | 决定「什么时候压实、怎么压实」的策略对象 | 一个 `useReducer` + 策略函数 |
| **压缩** | 真正把中间的 messages 换成一段摘要 | 列表虚拟化 + 归档 |

注意：**压缩是唯一合法破坏缓存的地方**。所以压缩本身要尽量少发生、发生时要一次做对、
失败时要有刹车（否则每轮都尝试、每轮都失败，既烧钱又破坏缓存）。

### 0.4 四个必须分清的概念

初学者最容易把这四个混成一个。它们是**四层不同的东西**：

```text
┌─────────────────────────────────────────────────────────────┐
│ ① 用户可见的对话历史（UI 上的气泡）                            │
│    → display projection，永不丢失（见 §10）                    │
├─────────────────────────────────────────────────────────────┤
│ ② 持久化的 messages 表（active/compacted 双投影）              │
│    → 07 篇讲的 session DB                                     │
├─────────────────────────────────────────────────────────────┤
│ ③ 本次请求实际发送的 messages 数组（prompt）                   │
│    → 可能是 ② 的子集/重排（select_context / 压缩）             │
├─────────────────────────────────────────────────────────────┤
│ ④ 跨会话记忆（MEMORY.md / USER.md / 外部 provider）            │
│    → 进 system prompt 的 volatile 层，不在 messages 里         │
└─────────────────────────────────────────────────────────────┘
```

**压缩只改 ③，并且把改动同步回 ②**（archive + insert）。它**不改 ①**，也**不碰 ④**。

这一条极其重要：用户翻聊天记录时，看到的是完整的①；模型看到的是压缩后的③。
两者故意不一致。

---

## §1 三方职责与文件地图

### 1.1 职责矩阵

| 维度 | 记忆（Memory） | 上下文引擎（Context Engine） | 压缩（Compression） |
|---|---|---|---|
| **解决什么** | 跨会话知识：用户偏好、项目事实、"上次说的那个方案" | 何时压实、按什么策略压实、追踪 token 用量 | 具体动作：剪枝、选边界、调 LLM 写摘要、拼装 |
| **ABC / 入口** | [`agent/memory_provider.py`](../agent/memory_provider.py:1) | [`agent/context_engine.py`](../agent/context_engine.py:48) | [`agent/context_compressor.py`](../agent/context_compressor.py:1) |
| **编排者** | [`agent/memory_manager.py`](../agent/memory_manager.py:391) | agent 初始化时二选一 | [`agent/compression_facade.py`](../agent/compression_facade.py:218) |
| **配置键** | `memory.provider` | `context.engine` | `compression:` 段 |
| **默认实现** | 内置 store（`MEMORY.md`/`USER.md`） | `"compressor"` → `ContextCompressor` | 就在 `ContextCompressor` 里 |
| **可插件化** | 是（`plugins/memory/<name>/`） | 是（`plugins/context_engine/<name>/`） | 否（随引擎） |
| **同时启用几个** | 内置 + **最多 1 个**外部 | **恰好 1 个** | 1 个引擎内 1 套 |
| **作用位置** | system prompt 的 volatile 层 | 决定 `messages` 的形状 | 改写 `messages` 数组 |
| **破坏缓存？** | 否（会话内冻结） | 否（决策层） | **是——唯一被许可的一个** |

一句话记忆法：

> **记忆是内容层，引擎是策略层，压缩是执行层。**

### 1.2 文件地图（带行数）

`agent/` 下与本章直接相关的模块共 21 个，合计约 14,000 行。按职责分组：

**记忆（3 个）**

| 文件 | 行数 | 作用 |
|---|---|---|
| [`agent/memory_provider.py`](../agent/memory_provider.py:1) | 206 | `MemoryProvider` ABC + 契约常量 |
| [`agent/memory_manager.py`](../agent/memory_manager.py:391) | 985 | 扇出编排：init / prefetch / sync / tool / hooks |
| [`plugins/memory/__init__.py`](../plugins/memory/__init__.py:1) | — | provider 发现（bundled-first） |

**上下文引擎（1 个）**

| 文件 | 行数 | 作用 |
|---|---|---|
| [`agent/context_engine.py`](../agent/context_engine.py:48) | 250 | `ContextEngine` ABC + `sanitize_memory_context` + 状态消息 |

**压缩核心（6 个）**

| 文件 | 行数 | 作用 |
|---|---|---|
| [`agent/context_compressor.py`](../agent/context_compressor.py:1) | **5852** | 主实现：阈值、剪枝、边界、摘要、finalize |
| [`agent/context_compressor_prellm.py`](../agent/context_compressor_prellm.py:20) | 92 | 调 LLM 之前的跳过决策 |
| [`agent/context_compressor_summary.py`](../agent/context_compressor_summary.py:29) | 103 | 摘要调用的路由 pin 与取消回滚 |
| [`agent/context_compressor_telemetry.py`](../agent/context_compressor_telemetry.py:23) | 139 | 每次尝试的遥测快照 |
| [`agent/compression_marker.py`](../agent/compression_marker.py:1) | 86 | 不可被模型模仿的省略标记 |
| [`agent/compression_facade.py`](../agent/compression_facade.py:218) | 328 | 宿主侧 `_compress_context` 包装 |

**压缩执行（6 个）**

| 文件 | 行数 | 作用 |
|---|---|---|
| [`agent/conversation_compression.py`](../agent/conversation_compression.py:1) | **4564** | 提交栅栏、租约、超时、fallback 链、归档 |
| [`agent/conversation_compression_archive.py`](../agent/conversation_compression_archive.py:1) | — | 归档写入 |
| [`agent/conversation_compression_codex.py`](../agent/conversation_compression_codex.py:1) | — | Codex 原生路径 |
| [`agent/conversation_compression_manual.py`](../agent/conversation_compression_manual.py:69) | 163 | 手动 `/compress` 唯一入口 |
| [`agent/conversation_compression_reply_anchor.py`](../agent/conversation_compression_reply_anchor.py:1) | — | 回复锚点 |
| [`agent/conversation_compression_telemetry.py`](../agent/conversation_compression_telemetry.py:1) | — | 遥测 |

**旁路与辅助（5 个）**

| 文件 | 行数 | 作用 |
|---|---|---|
| [`agent/micro_compaction.py`](../agent/micro_compaction.py:39) | 521 | 滚动微压实（默认关闭） |
| [`agent/native_compaction.py`](../agent/native_compaction.py:1) | 421 | OpenAI Responses 服务端压实 |
| [`agent/turn_context_compaction.py`](../agent/turn_context_compaction.py:1) | 507 | turn 开始时的压实决策 |
| [`agent/usage_anchor.py`](../agent/usage_anchor.py:1) | 203 | token 计量的可信锚点 |
| [`agent/manual_compression_feedback.py`](../agent/manual_compression_feedback.py:1) | 96 | 手动压缩的用户可见文案 |

**策展（2 个）**

| 文件 | 行数 | 作用 |
|---|---|---|
| [`agent/curator.py`](../agent/curator.py:1) | — | 技能生命周期调度 |
| [`agent/curator_backup.py`](../agent/curator_backup.py:1) | — | 归档前的备份与回滚 |

> **为什么要拆这么碎**：`context_compressor.py` 单文件 5852 行已经逼近 2000 行的硬上限数倍，
> 因为它是一个**已有超限单元**，按 [`AGENTS.md`](../AGENTS.md) 的 ratchet 规则「只能降不能升」。
> 新功能一律进 sibling，见 [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) 的
> 「Facade + Siblings」一节。

---

## §2 记忆：内容层

### 2.1 两个记忆系统，别搞混

Hermes 里「记忆」有两个完全不同的东西：

| | **内置 store** | **外部 provider** |
|---|---|---|
| 存储 | `~/.hermes/MEMORY.md` + `USER.md`（Markdown） | 由 provider 决定（向量库、SQLite、远端服务……） |
| 写入方式 | `memory` 工具，模型显式调用 | `sync_turn()` 自动 + provider 自己的工具 |
| 读取方式 | 会话开始时整份读进 system prompt | `prefetch()` 每轮按 query 检索 |
| 进 prompt 的位置 | volatile 层 | volatile 层（`system_prompt_block()`）+ 每轮上下文 |
| 数量限制 | 1 个 | 内置 + **最多 1 个外部** |

**为什么外部只允许一个**：见 [`agent/memory_manager.py`](../agent/memory_manager.py:391) 的 docstring——
"tool-schema bloat, conflicting backends"（工具 schema 膨胀、后端互相冲突）。

每多一个 provider 就是多几份工具 schema 进入**每一次** API 请求。这与「core 是窄腰」的不变量直接冲突。

### 2.2 ABC 生命周期

[`agent/memory_provider.py`](../agent/memory_provider.py:84) 的 `MemoryProvider` 定义了这条链：

```text
initialize(session_id, hermes_home=..., agent_context=...)
   ↓
system_prompt_block()      ← 一次性，静态文本，进 system prompt
   ↓
每轮: on_turn_start(turn_number, message, ...)
      prefetch(query, session_id)        ← 返回本轮要注入的召回上下文
   ↓
每轮结束: sync_turn(user_content, assistant_content, ...)   ← 非阻塞
          queue_prefetch(query, session_id)                 ← 为下一轮预取
   ↓
工具调用: get_tool_schemas() / handle_tool_call(name, args)
   ↓
可选 hooks: on_session_end / on_session_switch / on_pre_compress /
            on_delegation / on_memory_write / on_turn_start
   ↓
shutdown()
```

**只有 `get_tool_schemas()` 是 `@abstractmethod`**，其余都有默认实现（大多是空操作）。
这是刻意的：让 provider 可以只实现自己关心的部分。

#### 关键设计：`prefetch()` 必须快

docstring 写得很明确：

> Must be fast — recall in the background and return cached results.

原因：`prefetch()` 在**每一轮**的请求构建路径上。如果它做一次向量检索（100～500ms）或一次
远端 HTTP（1～3s），用户就会感觉到每一轮都卡。所以约定是：

```text
本轮: prefetch() 立刻返回上一轮 queue_prefetch() 预备好的结果
本轮结束: queue_prefetch() 在后台线程真检索，结果缓存起来
```

这是**典型的 stale-while-revalidate**：召回结果晚一轮，换取零延迟。

#### `system_prompt_block()` 必须是静态的

docstring：

> STATIC system-prompt text; "" to skip. Recalled context goes through prefetch(), not here.

为什么强调 STATIC：它在会话开始时进 system prompt。如果它随着状态变化（比如"当前有 3 条相关记忆"），
system prompt 就变了 → 缓存全失效。

这就是「记忆在会话内冻结」的具体含义：**写入可以发生，但读进 prompt 的快照不变**。
所以 `memory` 工具写完记忆后，模型在本会话内看不到更新——它需要相信自己的写入成功
（工具返回里会确认）。下次新会话才会读到。

### 2.3 后台线程必须携带 contextvars

这是 profile 隔离的核心实现细节，也是全书最容易被踩的坑之一。

```python
# agent/memory_provider.py:21
def ctx_bound(fn):
    ctx = contextvars.copy_context()
    return lambda *a, **kw: ctx.run(fn, *a, **kw)

# agent/memory_provider.py:29
def spawn_context_thread(target, *, name, daemon=True, args=(), kwargs=None):
    """每个 memory-provider 后台任务（prefetch、sync、writer loop）都必须走这里。"""
    return threading.Thread(target=ctx_bound(target), ...)
```

**为什么**：Hermes 支持多 profile 同时运行（一个 gateway 进程服务多个 profile，
见 [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)）。profile 的隔离不是靠全局变量，
而是靠 **ContextVar 作用域的 `HERMES_HOME` 覆盖**。

而 Python 的 `threading.Thread` **不继承调用者的 contextvars**——新线程从**空的 context** 开始。
所以：

```python
# 错误写法：后台线程会静默落到默认 profile
threading.Thread(target=provider.prefetch, ...)

# 正确写法：显式把当前 context 绑进去
spawn_context_thread(provider.prefetch, ...)
```

后果有多严重：在 secrets 读取上会 **fail closed**（拒绝读，报错但安全）；
在路径解析上会**静默写进默认 profile 的数据库**（数据串了，但没有任何报错）。

> 这条规则适用于**所有**后台线程，不止 memory：gateway 的 ticker、cron 的调度器、
> curator 的后台任务都一样。裸 `threading.Thread` 就是丢作用域。

### 2.4 内置 store 的哨兵值

```python
# agent/memory_provider.py:44
CORE_MEMORY_PROVIDER_SENTINELS = frozenset({"", "default", "builtin", "built-in", "none"})
```

`is_core_memory_provider(name)` 判断 `memory.provider` 选的是内置 store 还是外部插件。

**为什么需要这个**：内置 store 是**核心代码**，不是插件。所以 doctor、migration、依赖刷新、
`hermes memory` 子命令都**绝不能把它当插件去查找**。如果用户在配置里写了 `builtin`，
不能被理解成"去 `plugins/memory/builtin/` 目录找"。

哨兵集合包含 5 种写法，是因为不同年代的配置、文档、示例写过不同的值。这是一个
**向后兼容的入口宽容**设计——入口宽、内核严。

### 2.5 记忆 provider 的发现顺序（bundled-first）

[`plugins/memory/__init__.py`](../plugins/memory/__init__.py:1) 的 docstring 说得很直白：

```text
bundled → $HERMES_HOME/plugins/ → ./.hermes/plugins/（需 opt-in）
        → hermes_agent.memory_providers entry points
```

> Precedence is deliberately the REVERSE of PluginManager's later-source-wins:
> bundled wins, then user, project, entry point — a provider is activated by name
> (memory.provider, one at a time), so a directory dropped into the working tree
> must never shadow a shipped provider. Changing this order is a breaking change.

**这是全书唯一一个「后面的不覆盖前面的」的插件发现**。理由链条：

1. provider 是**按名字激活**的（`memory.provider: "byterover"`），不是按目录扫描自动启用。
2. 如果你 `cd` 进一个陌生仓库，里面恰好有 `.hermes/plugins/byterover/`，那它**不应该**
   劫持你已配置的 byterover——你会把自己的数据写进陌生人的后端。
3. 所以：**bundled 最优先**，用户目录次之，项目目录必须显式 opt-in
   （`HERMES_ENABLE_PROJECT_PLUGINS`）且排最后。

对比通用插件系统是 later-wins（用户目录覆盖 bundled），因为通用插件的语义是"覆盖/修补"，
而 memory provider 的语义是"选择某个具体后端"。

#### 发现时不 import

```python
# plugins/memory/__init__.py
def _is_memory_provider_dir(path: Path) -> bool:
    """Cheap text heuristic (no import): __init__.py mentions the memory provider contract."""
    source = init_file.read_text(errors="replace", encoding="utf-8-sig")[:8192]
    return "register_memory_provider" in source or "MemoryProvider" in source or _defines_memory_provider(path)
```

**为什么要两段式**（先看前 8KB 文本，再看 AST）：

- **不 import**：`import` 一个第三方 provider 包会执行它的顶层代码——可能连数据库、
  读 API key、甚至起线程。`hermes doctor` 只是列个表，不该有这些副作用。
- **先看文本再解析 AST**：纯文本判定是纳秒级；AST 解析是毫秒级。
  8KB 窗口能覆盖 99% 的 provider 文件头（import + class 定义）。
- **回退到 AST**：文件头有超长 docstring 时文本判定会漏，所以用
  `_defines_memory_provider()` 解析顶层定义，仍然**不执行**。

### 2.6 `on_pre_compress`：压缩前的记忆抢救

这是记忆与压缩之间**唯一**的交点，也是最精妙的一处。

```python
# agent/memory_provider.py:37
PRE_COMPRESS_CHECKPOINT_API_VERSION = 2
```

`MemoryManager.on_pre_compress()`（[`agent/memory_manager.py`](../agent/memory_manager.py:807)）的语义：

```text
压缩即将发生
  → 通知每个 provider："这段 messages 马上要被摘要掉了，你有什么要抢救的？"
  → provider 可以把关键事实写进自己的长期存储
  → provider 返回一段文本，这段文本会被塞进摘要 prompt 的 "memory context" 区
```

所以 provider 有两个抢救通道：

1. **写进自己的库**（长期，下次会话召回）
2. **返回文本进摘要 prompt**（短期，这次压缩的摘要在生成时就包含它）

#### v1 vs v2 的契约差异

```python
# agent/memory_manager.py:29
_LEGACY_PRE_COMPRESS_API_VERSION = 1
```

| 版本 | 签名 | 拿到什么 | 失败语义 |
|---|---|---|---|
| **v1**（旧） | `on_pre_compress(self, messages)` | 原始 transcript | best-effort，失败只记日志 |
| **v2**（当前） | `on_pre_compress(self, messages, **kwargs)`，可选收 `require_checkpoint=` | `evidence_messages`（宿主规范化后的列表） | 支持 checkpoint 语义 |

v2 的关键在于 **`require_checkpoint`**：

```python
# agent/memory_manager.py:807（简化）
def on_pre_compress(self, messages, *, evidence_messages=None, require_checkpoint=False, ...):
    ...
    for provider in self._providers:
        try:
            result = provider.on_pre_compress(provider_messages, **kwargs)
            checkpoint_succeeded = checkpoint_succeeded or is_checkpoint_provider
        except Exception as e:
            logger.debug(...)
            if require_checkpoint and is_checkpoint_provider:
                raise
    if require_checkpoint and not checkpoint_succeeded:
        raise RuntimeError(
            f"No active memory provider completed pre-compress checkpoint API v{checkpoint_api_version}"
        )
```

当 `compression.checkpoint_required: true` 时：

- **必须**至少一个 v2 provider 成功完成 checkpoint，否则**整个压缩放弃**，
  保留未压缩的 transcript。
- 这是一个 **fail-closed** 设计：宁可上下文超限报错，也不接受「记忆没落盘就被摘要掉」。

#### 为什么要检查签名是否接受关键字

```python
# agent/memory_manager.py:51
def _accepts_require_checkpoint(fn) -> bool:
    """True if fn can receive the require_checkpoint keyword (unreadable signatures -> False).

    Bare-shape v2 providers (on_pre_compress(self, messages)) would raise TypeError on the
    keyword, which the host would re-raise as a checkpoint failure despite a successful write.
    """
```

这段注释说了一个很隐蔽的 bug 类别：

- provider 声明 `pre_compress_checkpoint_api_version() → 2`（想用新契约）
- 但它的 `on_pre_compress` 签名是**裸的** `(self, messages)`，没说 `**kwargs`
- 宿主传 `require_checkpoint=True` → `TypeError`
- 宿主在 `require_checkpoint` 模式下把这个 `TypeError` 当"checkpoint 失败"往上抛
- 结果：**写入明明成功了，压缩却被拒绝**

所以宿主先 `inspect.signature()` 探测。探测不到（C 实现的 callable、奇怪的 proxy）就**保守地不传**。

#### 红action 边界

```python
messages, evidence_messages = _redact_for_provider(messages or [], evidence_messages)
```

在把 transcript 交给**任何** provider 之前，先做敏感信息脱敏。因为 provider 可能是第三方插件，
可能把内容发到远端。这是 egress 边界。

### 2.7 外部 prefetch 的超时与溢出

```python
# agent/memory_manager.py:33
_SYNC_DRAIN_TIMEOUT_S = 5.0
# agent/memory_manager.py:34
_EXTERNAL_PREFETCH_TIMEOUT_S = 8.0
```

- **prefetch 8 秒**：外部 provider 可能要做网络检索。8 秒是「慢但还能忍」的上限。
  超时后返回空字符串（这一轮不注入召回），但**不阻塞本轮**。
- **shutdown drain 5 秒**：退出时必须把待写的数据刷出去。
  5 秒后放弃，并**精确报告放弃了什么**（`abandoned_writes` / `abandoned_prefetches` 计数），
  而不是假装成功。

```python
# agent/memory_manager.py（__init__ 参数校验）
timeout = _EXTERNAL_PREFETCH_TIMEOUT_S if timeout is None else float(timeout)
if timeout <= 0:
    raise ValueError("external_prefetch_timeout must be positive")
```

`timeout <= 0` 直接抛错而不是"禁用"。**0 和 None 语义不同**：None 是"用默认值"，
0 是"我配错了"。让错误尽早暴露。

#### 溢出落盘

`prefetch` 的返回值会进 prompt。如果 provider 返回了 200KB 的检索结果，
直接把 prompt 撑爆。所以：

```python
from tools.hook_output_spill import get_spill_config, spill_if_oversized
```

超大输出被写到临时文件，prompt 里只放一个指针。这是 **hook 输出的通用处理方式**，
不止 memory 用。

### 2.8 单 worker 串行化写

```python
# agent/memory_manager.py:398（__init__）
# Single-worker background executor for end-of-turn sync/prefetch, created lazily so
# the builtin-only path spawns no threads; one worker serializes a provider's writes.
self._sync_executor: Optional[ThreadPoolExecutor] = None
```

两个设计点：

1. **lazy 创建**：只用内置 store 的用户**一个线程都不多起**。这是「窄腰」哲学的体现——
   不为没有的功能付代价。
2. **单 worker**：同一个 provider 的写入必须串行（否则它会看到自己的写冲突）。
   不同 provider 之间本来也只有 1 个外部，所以整体就是串行的。

代价：如果一次 `sync_turn` 很慢（远端 API 2s），后续的 sync 会排队。这可以接受，因为
它们在后台、且每轮只入队一次。

### 2.9 策略：`plugins/memory/` 已对内置 provider 关闭

[`plugins/AGENTS.md`](../plugins/AGENTS.md:19) 记录的政策：

> 新的内置 memory provider 不再进这个目录。新 provider 作为**独立仓库**实现同一个
> `MemoryProvider` ABC，通过 `hermes memory setup` / `post_setup()` 集成。

理由与「三方产品不进核心树」的规则一致：memory 后端竞争激烈（向量库、知识图谱、
各家 SaaS），把它们塞进核心树会让核心变成维护地狱。

目前 `plugins/memory/` 下只剩 `byterover` 和 `retaindb` 两个作为**示例/参考实现**，
外加 `config_schema.py` 和 `query_rewrite.py` 两个共享工具。

### 2.10 记忆在 prompt 里的确切位置

```text
system prompt
├── stable 层      ← 身份、"你是 Hermes"、核心规则（每会话构建一次）
├── context 层     ← 项目上下文文件（AGENTS.md 等）
└── volatile 层    ← MEMORY.md 快照 + USER.md 快照 + 外部 provider 的 system_prompt_block()
messages
└── ...（可能含 prefetch 召回内容，作为某条 user/assistant 消息的一部分）
```

volatile 层虽然叫 volatile，但在**同一会话内是冻结的**。名字来自"每次会话构建时可变"，
不是"每轮可变"。

#### `sanitize_memory_context()`

记忆内容进入 egress（压缩摘要 prompt）前必须脱敏：

```python
# agent/context_engine.py:20-25
MEMORY_CONTEXT_MAX_CHARS = 6_000
_MEMORY_CONTEXT_HEAD_CHARS = 4_000
_MEMORY_CONTEXT_TAIL_CHARS = 1_500

def sanitize_memory_context(memory_context: str) -> str:
    """Prepare provider context for a context-engine/LLM egress boundary."""
    sanitized = redact_sensitive_text(memory_context.strip(), force=True, redact_url_credentials=True)
    if len(sanitized) <= MEMORY_CONTEXT_MAX_CHARS:
        return sanitized
    return elide_middle(sanitized, _MEMORY_CONTEXT_HEAD_CHARS, _MEMORY_CONTEXT_TAIL_CHARS)
```

三个细节：

| 细节 | 为什么 |
|---|---|
| `force=True` | 即使配置里关了通用脱敏，这个边界也**强制**脱敏 |
| `redact_url_credentials=True` | `https://user:pass@host` 里的凭证必须抹掉 |
| `elide_middle(4000, 1500)` | 头和尾通常是最有信息量的（标题 + 结论），中间是细节。砍中间最划算 |

`4000 + 1500 = 5500 < 6000`，留 500 给省略标记本身。
这个预算在 [`agent/compression_marker.py`](../agent/compression_marker.py:60) 的
`ELISION_MARKER_MAX_LEN` 里也是同一个道理：**标记本身要占空间，不能假设能塞进去**。

---

## §3 上下文引擎：策略层

### 3.1 ABC 与六个 token 字段

```python
# agent/context_engine.py:48
class ContextEngine(ABC):
    # Token state: engines MUST maintain these; run_agent.py reads them directly.
    last_prompt_tokens: int = 0
    last_completion_tokens: int = 0
    last_total_tokens: int = 0
    threshold_tokens: int = 0
    context_length: int = 0
    compression_count: int = 0
```

注意注释：**`run_agent.py` 直接读这些属性**。这是一个**隐式契约**——不是方法调用，
是属性读取。所以任何引擎实现都必须维护它们，否则 turn loop 里的判断会读到 0。

这是 ABC 设计里的一个取舍：为了性能和简单，用了公开属性而非 getter。
代价是契约藏在注释里，而不是类型系统里。

### 3.2 两个抽象方法 + 一个必选的决策方法

```python
@abstractmethod
def update_from_response(self, usage: dict[str, Any]) -> None: ...

@abstractmethod
def should_compress(self, prompt_tokens: int | None = None) -> bool: ...

@abstractmethod
def compress(self, messages, current_tokens=None, focus_topic=None,
             force=False, memory_context="") -> list[dict]: ...
```

三个都是 abstract，但 `compress()` 的签名有个细节：

```python
"""...Older engines may omit optional parameters — the host filters them by signature."""
```

宿主用签名探测来调用（类似 §2.6 的 `_accepts_require_checkpoint`）。
这是同一个模式的复用：**新参数是可选的，老实现不能因为不认识关键字而崩**。

### 3.3 `should_compress_info()`：为什么要返回 reason

```python
# agent/context_engine.py:88
def should_compress_info(self, prompt_tokens=None) -> tuple[bool, str | None]:
    """Return (should_compress, reason).
    reason is None unless compression is needed but blocked..."""
    return self.should_compress(prompt_tokens), None
```

ABC 的默认实现返回 `None`，但 `ContextCompressor` 覆盖了它（见 §8）。

**为什么要区分「不需要压缩」和「需要但被挡住」**：

- 前者是正常的，静默。
- 后者是**异常状态**：上下文已经超阈值了，但压缩因为冷却/熔断被阻止。
  如果静默，用户会看到会话突然开始报 400 错误，却不知道为什么。

所以 `should_compress_info()` 返回的 reason 会被上层转成警告：

```text
"cooldown:240"          → 摘要模型上次失败，还要等 240 秒
"structural_backoff:87" → 重复的无效压缩，退避 87 秒
"ineffective"           → 连续 2 次压缩后 token 没降，熔断
```

### 3.4 `prune_tool_results_only()`：独立的低成本触发

```python
# agent/context_engine.py:110
def prune_tool_results_only(self, messages, current_tokens=None) -> tuple[list[dict], int]:
    """Deterministically trim old tool-result payloads without an LLM call.

    Runs on a low, cost-oriented trigger independent of should_compress() so
    large-window engines reclaim re-sent tool output long before full compaction.
    Returns (messages, n_pruned); the default no-op keeps older engines safe.
    """
    return messages, 0
```

这是**最关键的一个非抽象方法**。它解决的场景：

> 我用的是 1M 上下文的模型。阈值 50% = 500K token。我永远不会到 500K。
> 但我在第 20 轮时，前面有 15 个读了 20KB 文件的 tool 结果，每轮重发 = 300K token/轮。
> 全额付费，但不触发压缩。

所以有一个**独立的、极低成本的**触发点：只做确定性剪枝（把老 tool 结果换成一行摘要），
不调 LLM、不改摘要、不破坏前缀里的 system prompt。

配置键：

```yaml
compression:
  proactive_prune_tokens: 0            # 0 = 关闭（默认）
  proactive_prune_min_result_chars: 8000
  proactive_prune_min_reclaim_tokens: 4096
```

`min_reclaim_tokens: 4096` 的含义：如果剪枝只能省 500 token，不值得破坏一次缓存。
**必须省够一个缓存重建的成本才动手**。

> **注意**：即使是"只剪枝"，它也改变 messages 的中间部分 → 破坏缓存。
> 所以它必须由 `proactive_prune_tokens` 阈值门控，且默认关闭。默认关闭是因为
> 大多数人不开这个选项时，普通压缩已经够用；开了这个选项的用户是明确知道自己要什么的。

### 3.5 `select_context()`：不改历史，只改本次请求

```python
# agent/context_engine.py:121
def select_context(self, request_messages, *, conversation_messages=None,
                   incoming_message=None, budget_tokens=0) -> list[dict]:
    """Optionally *select* (replace) the context for THIS request, pre-generation.

    Runs on every provider request (also retries), independent of should_compress():
    compress() shrinks over-long context, this swaps in a different one
    (retrieval, topic routing, branch switching). Return None to leave the request unchanged.
    The returned list is request-only — it MUST NOT ...
    """
```

这是给**高级引擎**的逃生口。典型用法：

- 检索式引擎：根据当前问题从历史里检索最相关的 20 条，而不是全部按时间顺序带上
- 主题路由：检测到话题切换，换一套上下文
- 分支切换：从另一条会话线拿上下文

**关键约束：`request-only`**。返回的列表**只用于这一次请求**，不写回持久化，
不影响下一轮。这让它可以随便"试错"而不破坏状态。

默认实现是 `return None`（保持请求不变），所以不实现这个方法的引擎零成本。

### 3.6 引擎发现与选择

```python
# agent/agent_init.py:1896
def _select_context_engine(_agent_cfg):
    """Config-driven context engine: ``context.engine`` → plugins/context_engine/<name>/ → ..."""
```

解析顺序：

```text
1. context.engine == "compressor"（默认）→ 内置 ContextCompressor
2. plugins/context_engine/<name>/ 目录（bundled 优先，用户目录次之）
3. 通用插件系统（register_context_engine()），且 name 必须匹配
4. 都找不到 → 回退到内置，并 warn
```

[`plugins/context_engine/__init__.py`](../plugins/context_engine/__init__.py:1) 的 docstring：

> Separate from the general plugin system: ``context.engine`` in config.yaml names the active
> engine (default ``"compressor"``, the built-in ContextCompressor), so a user-installed engine
> needs no ``plugins.enabled`` entry to be selectable.

**为什么不走 `plugins.enabled`**：引擎是**单选**的（`context.engine` 只填一个名字）。
如果还要用户去 `plugins.enabled` 里再加一遍，就是两处配置同步问题。
按名字激活 = 一处配置。

> **插件引擎永不自动激活。** 这是有意的：上下文引擎决定了模型看到什么，
> 一个自动激活的第三方引擎可能把用户的数据发到别处。必须是用户显式写出名字。

### 3.7 可见状态消息

```python
# agent/context_engine.py:33
def automatic_compaction_status_message(engine, *, phase, default_message, **context) -> str | None:
    """Host-visible status for an automatic compaction event; None = emit nothing.

    Engines suppress via emit_automatic_compaction_status = False or
    customize via get_automatic_compaction_status_message(...).
    """
```

三个 phase：

| phase | 时机 | 宿主位置 |
|---|---|---|
| `turn_start` | turn 开始的 preflight | [`agent/turn_context_compaction.py`](../agent/turn_context_compaction.py:230) |
| `pre_api` | 每次 API 调用前的压力检查 | [`agent/turn_preflight.py`](../agent/turn_preflight.py:130) |
| `idle` | 空闲触发的压实 | [`agent/turn_context_compaction.py`](../agent/turn_context_compaction.py:134) |

`emit_automatic_compaction_status = False` 让引擎可以静默常规的后台维护，
但**警告、错误和手动 `/compress` 仍然会显示**。这是「静默正常、喧哗异常」的通用原则。

---

## §4 双层压缩：两个独立运作的安全网

### 4.1 全景图

```text
                        ┌──────────────────────────────────┐
   入站消息 ───────────► │  Gateway Session Hygiene         │  ctx × 85%（默认）
   （Telegram/          │  在 agent 之前，粗估             │  或 messages >= 5000 硬阀门
    Discord/…）          │  跨进程、跨重启                  │
                        └──────────────┬───────────────────┘
                                       ▼
                        ┌──────────────────────────────────┐
                        │  Agent ContextCompressor         │  ctx × 50%（默认，可配）
                        │  turn 循环内，真实 token          │  每 model 可覆盖
                        │  四个触发点                      │
                        └──────────────┬───────────────────┘
                                       ▼
                        ┌──────────────────────────────────┐
                        │  Provider 硬上限                 │  400 报错
                        │  → 溢出恢复（reactive）           │  最后一层
                        └──────────────────────────────────┘
```

三者是**递进**的，不是互斥的：

1. **hygiene** 防止"隔夜积攒的巨大会话"在第一次请求就炸
2. **compressor** 负责常规上下文管理
3. **溢出恢复** 兜住"上面全都没救到"的情况

### 4.2 网关卫生（85%）

位置：[`gateway/run_turn.py`](../gateway/run_turn.py:738) 的 `_hmwa_hygiene_plan()`。

```python
_compress_token_threshold = int(_hyg_context_length * hs.threshold_pct)
_warn_token_threshold = int(_hyg_context_length * 0.95)
_msg_count = len(history)
```

默认 `threshold_pct = 0.85`，另有一个 95% 的**警告**阈值（只警告，不压缩）。

#### token 来源的三级优先

```python
if session_entry.last_prompt_tokens > 0:
    _approx_tokens, _token_source = session_entry.last_prompt_tokens, "actual"
elif _anchored is not None:
    _approx_tokens, _token_source = _anchored, "anchored"
else:
    _approx_tokens, _token_source = estimate_messages_tokens_rough(history), "estimated"
```

| 优先级 | 来源 | 可信度 | 失效场景 |
|---|---|---|---|
| 1 | `last_prompt_tokens` | **真实**（provider 报的） | 网关重启后丢失 |
| 2 | persisted usage anchor | **真实 + 增量** | anchor 与 transcript 不匹配时失效 |
| 3 | 粗略字符估算 | **偏高 30–50%** | 永远可用 |

注释里有一句关键的话：

```python
# rough estimate (runs 30-50% high, which only fires hygiene early — safe). Do NOT compensate
# with a threshold multiplier.
```

**为什么偏高是安全的**：估算偏高 → 压缩提前触发 → 浪费一次压缩，但不会失败。
估算偏低 → 压缩延迟 → 可能到 provider 硬上限 → 会话崩。

所以**永远选保守方向**。而且**不要**用「乘 0.7 补偿」的方式修正——
那会让高估变成精确估计，一旦某类内容（图片、CJK、代码）的实际比例不同，就从"偏保守"
变成"偏乐观"，方向错了。

#### 硬消息数阀门

```python
# Hard safety valve: force compression at an extreme message count regardless of tokens,
# breaking the disconnect → no token data → no compression spiral. 5000 clears 1M+ sessions.
_needs_compress = _approx_tokens >= _compress_token_threshold or _msg_count >= hs.hard_msg_limit
```

`hs.hard_msg_limit = 5000`（可配置）。

这解决了一个具体的死循环：

```text
连接断开 → 没有 provider usage 数据 → last_prompt_tokens = 0
        → 只能靠估算 → 估算如果因为某种原因偏低
        → 不触发压缩 → 继续变大 → 更容易断
```

5000 条消息对任何模型都太大了（除非是极简对话），所以这条硬线几乎不可能误伤。

#### 三道跳过门

即使 `_needs_compress` 为 True，还有三道门：

```python
# 门 1：DB 持久化的失败冷却
_getter = getattr(..., "get_compression_failure_cooldown", None)
if _cooldown_state and _cooldown_state.get("remaining_seconds", 0) > 0:
    _needs_compress = False

# 门 2：已有压缩在进行中
if _needs_compress and await self._session_has_compression_in_flight(session_key):
    _needs_compress = False
```

**门 1 为什么必须持久化到 DB**：

```python
# The in-memory dict was reset on every restart, re-triggering the same failing compression and
# wedging session storage (#74136).
```

一个会失败的压缩（比如摘要模型配额用完）如果冷却只在内存里，那么：
网关每重启一次 → 内存清空 → 立刻重试 → 再失败 → 再进冷却。
用户看到的是"每次重启都卡一分钟然后失败"。

**门 2 为什么必要**：

```python
# A prior compression still holds the durable lock (e.g. a shielded worker left by /stop):
# another attempt would wait up to 600s behind a commit the fence will refuse.
```

一个被 `/stop` 中断的压缩可能留下一个还活着的 shielded worker（它持有租约）。
新的压缩尝试会在租约上等待最多 600 秒，然后因为 fence 拒绝而失败。
**不如直接跳过**——反正结果一样，但省了 10 分钟。

### 4.3 为什么网关阈值（85%）比 agent（50%）高

这不是随手定的数字。如果网关也用 50%：

```text
长网关会话，上下文一直维持在 40-60% 区间
→ 每一轮入站消息都让 token 从 49% 变 50.1%
→ 每轮都触发压缩
→ 每轮都破坏一次缓存
→ 成本翻 5-10 倍
```

85% 的含义是：**「我只在真的很危险时才动手」**。常规管理交给 agent 的 50%——
它在循环内、有真实 token、能更早更聪明地做。

一句话：**hygiene 是最后一道保险，不是日常维护。**

### 4.4 agent 侧的四个触发点

| 触发点 | 位置 | 输入 | 特点 |
|---|---|---|---|
| **turn 开始 preflight** | [`agent/turn_context_compaction.py:230`](../agent/turn_context_compaction.py:230) | 上一轮的真实 token / anchor | 最常见 |
| **idle** | [`agent/turn_context_compaction.py:134`](../agent/turn_context_compaction.py:134) | 墙钟间隔 | opt-in，长时间空闲后 |
| **pre-API 压力** | [`agent/turn_preflight.py:100`](../agent/turn_preflight.py:100) | `request_pressure_tokens` | 每次 API 调用前 |
| **post-tool** | turn 循环内 | 工具结果注入后 | 大工具输出后立即 |

四个点都**先问 usage anchor**（§7），并且都过 `should_compress_info()` 的刹车。

#### `should_defer_preflight_to_real_usage()`

这是一个非常反直觉但要紧的方法：

```python
# agent/context_compressor.py:2975
def should_defer_preflight_to_real_usage(self, rough_tokens: int) -> bool:
    """True when a whole-context ROUGH estimate over threshold must wait ONE request for the
    provider's real usage. Callers skip this for usage-anchored figures...
    """
    if rough_tokens < self.threshold_tokens:
        return False
    if self.awaiting_real_usage_after_compression:
        return True
    if self.last_real_prompt_tokens >= self.threshold_tokens:
        return False
    return not self._provider_omits_usage
```

翻译成规则：

> 如果这个数字是**粗略估算**，而且我们**从来没有**收到过这个 transcript 的真实计数，
> 那就**先发一次请求**，看 provider 报多少，再决定要不要压缩。

为什么？因为粗估偏高 30–50%。在 50% 阈值下，一个真实的 38% 会被估成 52% → 误触发压缩 →
破坏缓存、烧一次摘要调用、模型丢细节。**一次请求的代价远小于一次不必要的压缩。**

三个例外：

1. `awaiting_real_usage_after_compression`：刚压缩完，`last_real_prompt_tokens` 是**压缩前**的
   旧值，不能用。所以压缩后第一轮必须等新数据（叫 latch，闩锁）。
2. `last_real_prompt_tokens >= threshold`：已经有真实证据超了，不用等。
3. `_provider_omits_usage`：provider 压根不报 usage（某些本地模型）。那就只能靠估算，
   否则**永远不会压缩**（#2153）。

---

## §5 `compress()` 全流程：四个 phase

这是全章的核心。`compress()` 在 [`agent/context_compressor.py:5534`](../agent/context_compressor.py:1)，
约 110 行，但每个分支都有来历。我们逐 phase 拆。

### 5.1 签名与参数语义

```python
def compress(
    self,
    messages: list[dict[str, Any]],
    current_tokens: Optional[int] = None,
    focus_topic: Optional[str] = None,
    force: bool = False,
    memory_context: str = "",
    bypass_cooldown: bool = False,
) -> list[dict[str, Any]]:
```

| 参数 | 语义 | 谁传 |
|---|---|---|
| `messages` | 当前 transcript | 所有调用方 |
| `current_tokens` | provider 报的 prompt token（含 system + tools） | turn loop |
| `focus_topic` | 手动 `/compress <focus>` 的重点 | 用户 |
| `force` | 清掉失败冷却 + 跳过可行性检查 | **仅手动** `/compress` |
| `memory_context` | provider 在 `on_pre_compress` 返回的文本 | memory manager |
| `bypass_cooldown` | 冷却期间也跑一次，但**不清冷却** | provider 证明溢出后的恢复 |

`force` 与 `bypass_cooldown` 的区别很微妙：

- `force=True`：用户说"我现在就要压"。所以**清掉冷却**（下次失败重新计时），
  并且跳过所有"这次压了可能没用"的预判。
- `bypass_cooldown=True`：系统说"provider 明确报了溢出，我知道在冷却，但必须试一次"。
  **不清冷却**（如果又失败，冷却继续生效），且受调用方的重试预算约束。

### 5.2 Phase 0：入口守卫与状态

```python
from agent.conversation_compression import _raise_if_stale_attempt

_raise_if_stale_attempt(self)
telemetry = self._begin_compress_attempt(current_tokens, force)
```

**`_raise_if_stale_attempt`** 是整章最容易被忽略、但最重要的安全机制。它解决的问题：

```text
attempt A 开始压缩（慢，30 秒）
  ↓
超时处理认为 A 卡住了，启动 attempt B（fallback 路由）
  ↓
A 突然返回了（它其实没死，只是慢）
  ↓
A 试图把自己的结果写进 compressor 的共享状态
```

如果 A 写成功了，就会覆盖 B 的状态（`_previous_summary`、冷却、错误字段），
导致 B 的提交使用了 A 的摘要 → 数据错乱。

所以每次写入共享状态前都要检查"我还是当前 owner 吗"：

```python
# agent/conversation_compression.py:290
def _raise_if_stale_attempt(compressor):
    """Raise when the calling attempt is no longer the compressor's working owner."""
```

注释解释了为什么必须在**多个点**检查：

```python
# A detached stale attempt must not even reset per-call state the fallback owns. Staleness that
# arises mid-compress is caught by the write-point gates below; this covers stale-at-entry.
```

**入口**检查一次（覆盖"进来时就已经过期"），**Phase 3 前**再检查一次（覆盖"phase 1-2 期间过期"），
**LLM 调用后**再检查一次（覆盖"调用期间过期"）。

### 5.3 Phase 0.5：消息数下限

```python
_min_for_compress = self._protect_head_size(messages) + 3 + 1
if n_messages <= _min_for_compress:
    self._structural_no_op_result(telemetry, "insufficient_messages", ...)
    return messages
```

至少需要：protected head + 3 条 tail + 1 条可压缩的中间消息。

**为什么是这个数**：head 不能被压（它是稳定前缀的一部分，压了等于破坏缓存），
tail 是"最近的上下文"（模型正在用的）。中间必须有东西可压，否则是空操作。

注意 `_structural_no_op_result` 是"**结构性的**无操作"——意思是"这次没压不是失败，
是本来就没得压"。它和"压缩失败"在遥测里是两个不同的 `failure_class`，因为**前者不该触发冷却**。

### 5.4 Phase 1：剪枝旧工具结果（不调 LLM）

```python
canonical_messages = self._drop_blank_echoes(messages)
messages, pruned_count = self._prune_old_tool_results(
    messages, protect_tail_count=self.protect_last_n, protect_tail_tokens=self.tail_token_budget,
)
```

两个变量很关键：

- `canonical_messages`：**未剪枝**的副本。用于「压缩 no-op / abort 时原样返回」和 finalize。
  保证**失败时历史无损**。
- `messages`：**剪枝后**的副本。后续所有边界计算都在它上面做。

注释点出了为什么必须分开：

```python
# Unpruned copy for no-op/abort returns (history stays lossless) and finalize; head/tail are
# assembled and measured from the pruned copy (#61932).
```

#### `_prune_old_tool_results()` 的三个 pass

```python
# agent/context_compressor.py:3277
def _prune_old_tool_results(self, messages, protect_tail_count,
                            protect_tail_tokens=None, min_prune_chars=_PRUNE_MIN_CHARS):
    """Project old tool-result bodies to bounded summaries without rewriting tool-call arguments."""
```

**Pass 1：去重**（`_dedupe_tool_results`）——完全相同的 tool 结果只留一份。

**Pass 2：降级旧 tool 结果**

```python
pruned += sum(
    self._demote_tool_result_at(result, i, call_id_to_tool, min_prune_chars, protected_skills)
    for i in range(max(0, prune_boundary))
)
```

把 `prune_boundary` 之前的 tool 结果换成一行摘要，比如：

```text
[read_file] src/agent/loop.py (28,431 chars)
```

**关键：tool_call 的 arguments 永不改写**

```python
# Tool-call arguments are canonical execution records and are never rewritten;
# summary input is bounded separately by _render_tool_call_for_summary().
```

为什么：tool 调用参数是**执行记录**。如果模型在后续轮次看到被截断的参数，
它可能以为"我当初就是这么调的"，然后基于错误参数重试。

**Pass 3：退休 tail 里的图片**

```python
pruned += _retire_stale_tool_result_images(result, spared=spared)
```

为什么 tail 里的图片也要处理：

```python
# Re-sent embeds otherwise make compression look ineffective and trip anti-thrash.
# Newest frames stay live for follow-up QA.
```

一个 base64 图片可能几 MB。如果它在"受保护的 tail"里，每轮重发 = 请求体超限。
而且它会让"压缩后 token 没降"→ 触发抗抖动熔断（§8）。

#### 保护清单：三样东西不能被剪

| 保护对象 | 代码 | 理由 |
|---|---|---|
| **pending tool round** | `_spared_pending_tool_round(result)` | 模型刚请求、还没读的输出。剪了它，模型会重跑（有副作用）或瞎猜 |
| **刚加载的 skill** | `_collect_protected_skill_names(result, prune_boundary)` | 剪了 skill 内容，模型还以为指令在上下文里（#32106） |
| **新图片** | `_retire_stale_tool_result_images(..., spared=spared)` | 保留最新的，供追问 |

`spared`（pending round）还有一个例外：

```python
# unless it alone exceeds the tail's hard share of the input budget ... the #61932
# single-200KB-read case, which must still give way.
```

一次读了 200KB，即使在 pending round 里，也必须让步——否则整个请求发不出去。

#### `_PRUNE_MIN_CHARS = 200`

```python
# Shared floor; the clarify summary cap must stay strictly BELOW it so a preserved
# user answer is never re-summarized away on a later prune pass.
_PRUNE_MIN_CHARS = 200
```

小于 200 字符的 tool 结果不值得剪（标记本身就 60+ 字符）。
而 clarify（向用户提问）的答案必须**严格小于 200**——这样它在下一轮会被"保留原文"而不是被摘要掉。

#### pressure demote：连保护的 tail 也压

```python
if protect_tail_tokens is not None and protect_tail_tokens > 0 and result:
    pruned += self._pressure_demote_tail(...)
```

如果 tail 本身超了 `tail_token_budget`，连 tail 里的老 tool 结果也要降级。
这处理了"一个巨大的 tail"的情况。

### 5.5 Phase 2：选边界

```python
compress_start, compress_end = self._compress_window(messages)
if compress_start >= compress_end:
    self._record_compression_regions(...)
    self._structural_no_op_result(telemetry, "no_compressible_window", ...)
    return canonical_messages
```

```python
# agent/context_compressor.py:5292
def _compress_window(self, messages):
    compress_start = self._align_boundary_forward(messages, self._protect_head_size(messages))
    compress_end = self._find_tail_cut_by_tokens(messages, compress_start)
    ...
```

#### head 边界

`_protect_head_size(messages)`：protected head 的条数（`protect_first_n` = 3，加上 system）。

`_align_boundary_forward`：**向前对齐**。如果切点落在 assistant/tool 对之间，
必须往前后挪到一个合法边界——否则会产生孤立的 `tool` 消息（没有对应的 `tool_calls`），
provider 会直接 400。

#### tail 边界：按 token 预算，不按条数

```python
# agent/context_compressor.py:2231
@property
def tail_token_budget(self) -> int:
    if self._tail_token_budget is None:
        if getattr(self, "tail_mode", "lean") == "lean":
            # Lean mode: tail is a small clamped recency window; the summary carries continuity.
            budget = max(LEAN_TAIL_FLOOR_TOKENS, min(LEAN_TAIL_CAP_TOKENS, int(self.context_length * 0.025)))
        else:
            budget = int(self.threshold_tokens * self.summary_target_ratio)
        if self.context_length > 0:
            budget = min(budget, int(self.context_length * TAIL_MAX_CONTEXT_FRACTION))
        self._tail_token_budget = max(1, budget)
    return self._tail_token_budget
```

两种 tail 模式：

| 模式 | 公式 | 含义 |
|---|---|---|
| `"lean"`（默认） | `clamp(10000, 25000, ctx × 2.5%)`，再 `min(ctx × 20%)` | 小窗口 + 摘要承担连续性 |
| `"legacy"` | `threshold_tokens × summary_target_ratio(0.20)` | 老行为，尾巴很大 |

#### `TAIL_MAX_CONTEXT_FRACTION = 0.20` 的来历

```python
# Hard share of the window the verbatim tail may occupy, applied after either formula. The lean
# floor alone is 61% of a 16K window and 122% of an 8K one, so on a local 27B the "protected"
# tail WAS the whole request and every compaction pass summarised six rows and reclaimed nothing.
```

这是一个**真实故障的复盘**：

```text
本地 27B 模型，context_length = 8K
LEAN_TAIL_FLOOR_TOKENS = 10000 > 8000
→ tail 预算 = 10000（floor 生效）
→ 但整个窗口只有 8000
→ "受保护的 tail" = 全部消息
→ 每次压缩都只压 6 条，什么都省不下来
→ 每次都失败，每次都触发熔断
```

`0.20` 的硬上限把这种情况拉回合理区间：8K 窗口 → tail 最多 1600 token。

**教训**：任何"绝对下限"（floor）都必须再叠一个"相对上限"（fraction）。
否则在小规模输入下，floor 会超过整体。

#### role 碰撞修正

```python
# A role collision can merge the summary into the first tail row; keep an actionable user
# event out of that slot by retaining an older assistant/tool bridge.
latest_actionable_idx = self._find_last_user_message_idx(messages, 0)
if compress_end == latest_actionable_idx:
    bridge_idx = latest_actionable_idx - 1
    ...
```

场景：摘要要插在 tail 的第一条之前。如果 tail 第一条恰好是"用户的新问题"，
而摘要的 role 也是 user（或摘要被 merge 进去），就会产生**两条连续 user 消息**
或**摘要吃掉了用户的问题**。

所以：如果切点正好落在最后一条用户消息上，把切点往前挪一条（保留一个 assistant/tool 作为桥）。

### 5.6 Phase 2.5：lean 模式的 tail demote 与 handoff 扫描

```python
# Lean mode demotes stale tail tool results before summary generation so stubs exist even if it aborts.
if getattr(self, "tail_mode", "lean") == "lean":
    messages = self._demote_stale_tail_tools(messages, compress_end)

scan = self._scan_window_handoffs(messages, compress_start, compress_end, turns_to_summarize)
```

`_demote_stale_tail_tools` 的注释很关键：**在生成摘要之前**做。

为什么：如果摘要生成失败并 abort，我们希望**至少 tail 的降级已经生效**（有收益）。
如果放在后面，一旦 abort，什么都没做。

Docker 类比：先做不可回滚的、必然有益的小改动；把"可能失败的大改动"放后面。

`_LEAN_TAIL_KEEP_TOOL_ROUNDS = 6`：tail 里最新的 6 轮 tool 结果保持完整，
更老的降级成 stub。

#### handoff 扫描

```python
if not turns_to_summarize:
    # Window is only handoff rows (#59496): skip the aux call; _previous_summary is KEPT —
    # it came from this transcript.
    self._structural_no_op_result(telemetry, "empty_post_handoff_window", ...)
    return canonical_messages
```

如果中间窗口全是"上一次压缩留下的摘要行"，那没什么可总结的——
摘要已经在 `_previous_summary` 里了。**跳过 LLM 调用**（省钱），
但**保留** `_previous_summary`（它来自这段 transcript，是有效的）。

### 5.7 Phase 3：生成摘要

```python
_raise_if_stale_attempt(self)   # 第二次检查

feasibility_skip = not force and (
    self._fallback_streak_skip(telemetry)
    or self._feasibility_skip(telemetry, turns_to_summarize, compress_start, compress_end)
)
summary = None
if not feasibility_skip:
    summary = self._summarize_window(...)
    if not summary and self._abort_on_summary_failure(...):
        return canonical_messages
if not summary:
    summary = self._fallback_summary_for_window(...)
```

#### 两个 pre-LLM 跳过（[`context_compressor_prellm.py`](../agent/context_compressor_prellm.py:20)）

**跳过 A：摘要模型被 bench（`_fallback_streak_skip`）**

```python
if self._fallback_compression_streak < 2:
    self._set_fallback_probe_at(0.0)
    return False
now = time.time()
if self._fallback_probe_at and now >= self._fallback_probe_at:
    self._set_fallback_probe_at(0.0)
    return False   # 探测：再给它一次机会
```

规则：

- 连续 2 次摘要 fallback（比如 auxiliary 模型一直失败）→ bench 它
- bench 期间用**确定性 fallback 摘要**（不调 LLM）
- `_ANTI_THRASH_RECOVERY_SECONDS = 300` 后**探测一次**
- 探测成功 → 重置 streak
- 探测失败 → 再 bench 300 秒

**为什么 streak 要持久化（`_fallback_probe_at` 写进 session 行）**：

```python
# Wall clock: the deadline is persisted on the session row so a gateway rebuild resumes the window.
```

网关每轮可能重建 compressor 对象（缓存淘汰）。如果 deadline 只在内存，
每次重建都从 0 开始 → 每轮都探测一次 → 每轮都失败 → 每轮都烧一次调用。

**跳过 B：中间太小，不值得（`_feasibility_skip`）**

```python
_FEASIBILITY_SKIP_MIDDLE_FRACTION = 0.10

if self._ineffective_compression_count < 1:
    return False
middle_tokens = ...
if middle_tokens >= int(self.threshold_tokens * _FEASIBILITY_SKIP_MIDDLE_FRACTION):
    return False
```

条件：**有过至少 1 次"压缩了但没用"的记录**，且**中间窗口 < 阈值的 10%**。

场景：阈值 100K，中间只有 8K。压掉这 8K 换成 1K 摘要，省 7K——对 100K 的请求是 7%，
不值得破坏缓存 + 花一次摘要调用。**直接确定性 drop 就好**。

注意：`_feasibility_skip` **只读计数器，从不写**（docstring: "reads the counter, never writes"）。
因为它是在 Phase 3 的决策路径上，不该改变状态。

#### `_summarize_window()`：路由 pin 与取消回滚

```python
# agent/context_compressor_summary.py:60
def _summarize_window(self, messages, turns_to_summarize, scan, focus_topic, memory_context, bypass_cooldown):
    from agent.context_compressor import take_deterministic_summary_pin
    if take_deterministic_summary_pin():
        ...
        return None   # None → Phase 4 用确定性 fallback
    summary_kwargs = {
        "focus_topic": focus_topic or self._derive_auto_focus_topic(messages),
        "memory_context": memory_context,
    }
    try:
        return self._generate_summary(turns_to_summarize, **summary_kwargs)
    except AuxiliaryExplicitCancellation:
        if _caller_attempt_is_current(self):
            self._previous_summary = scan.previous_summary_before
            self._summary_has_user_turn = scan.has_user_turn_before
        raise
```

三个关键点：

1. **确定性 pin**：如果之前的尝试在**所有路由**上都卡住了，`DETERMINISTIC_SUMMARY_ROUTE`
   哨兵被设置 → 直接跳过 LLM，用 fallback。这是"别再试了"的信号。
2. **focus_topic 自动推导**：`_derive_auto_focus_topic(messages)` 扫描用户消息推断主题。
   只在真的要生成摘要时才调用（`focus_topic or ...` 短路）。
3. **取消时回滚**：`AuxiliaryExplicitCancellation` 是"被中断"。此时 `_scan_window_handoffs`
   可能已经修改了 self-heal 状态，必须恢复到 scan 之前（`previous_summary_before`）。
   否则中止的尝试会留下"半改"的状态。

#### `_generate_summary()`：迭代摘要

```python
# agent/context_compressor.py:3977
def _generate_summary(self, turns_to_summarize, focus_topic=None, memory_context="", bypass_cooldown=False):
    """Structured summary of the turns (iterative update when a previous summary exists); None if all attempts fail."""
    prompt_started_at = time.monotonic()
    if self._compression_cancelled():
        raise AuxiliaryExplicitCancellation()
    if prompt_started_at < self._summary_failure_cooldown_until and not bypass_cooldown:
        return None
```

**迭代摘要**是核心设计：如果 `_previous_summary` 存在，prompt 不是"总结这些对话"，
而是"**把新的这些轮次合并进已有的摘要**"。

为什么：会话可能压缩 10 次。如果每次都独立生成摘要，第 10 次的摘要只有第 9-10 次的信息，
前面的全丢了。迭代是**增量维护**，信息不衰减。

代价：一旦某次摘要有损，损失会被后续所有迭代继承。所以有 `_defrag`（§9.2）和
fallback 的 `_previous_summary` 更新（§8）。

#### Ghost-skill 防御

```python
# Ghost-skill defense: LLMs paraphrase [SKILL_PRUNED] markers away; collect the names
# deterministically BEFORE the call (from the turn LIST, not the bounded text), re-inject after.
_pruned_skill_names = list(dict.fromkeys(
    _collect_ghosted_skill_names(turns_to_summarize) + _extract_pruned_skill_names(self._previous_summary or "")
))[:_MAX_PRUNED_SKILL_MARKERS]
```

问题：Phase 1 把 `skill_view` 的完整内容降级成 `[SKILL_PRUNED: foo; reload with skill_view(name='foo')]`。
LLM 在生成摘要时**会把这个标记改写成"技能 foo 曾被加载"**之类的自然语言——标记丢了。
然后模型以为自己知道 foo 的内容，实际不知道。

解决：**确定性收集 + 确定性重注入**。

```python
summary = _reinject_pruned_skill_markers(summary, _pruned_skill_names)
```

```python
# The ONE canonical prune marker; emit sites and presence checks must use the same string so
# they cannot drift.
SKILL_PRUNED_MARKER_PREFIX = "[SKILL_PRUNED:"

def _skill_pruned_marker(skill_name: str) -> str:
    return (f"{SKILL_PRUNED_MARKER_PREFIX} content lost in compression; "
            f"reload with skill_view(name='{skill_name}')]")
```

注释记录了一个真实 bug：原 PR 发出 `[SKILL_PRUNED:` 但检查 `[SKILL_PRUNED]`，
导致"检查永远不命中 → 永远重复注入"。

**教训**：emit 和 check 必须用**同一个函数**生成字符串，不能各写一遍字面量。

#### `_SUMMARY_INPUT_MAX_CHARS = 160_000`

```python
# Prompt-side char cap on the serialized turn block (~40K tokens; head+tail kept,
# see _bound_summary_input). NEVER add a max_tokens wire cap on the summary call.
_SUMMARY_INPUT_MAX_CHARS = 160_000
```

两条规则：

1. **输入侧封顶**：160K 字符 ≈ 40K token。超了就用 `_bound_summary_input` 保留头尾。
2. **绝不加 wire 上的 `max_tokens`**：

```python
# agent/context_compressor.py:3903
# NO max_tokens: Anthropic/NIM wires forward it and a hard cap truncates summaries
# (thinking models burn it on reasoning).
```

如果加了 `max_tokens`：
- Anthropic / NIM 会真的按这个数截断
- reasoning 模型会把预算烧在思考上，正文被截断
- 截断的摘要（`finish_reason == "length"`）会被判为失败（下一段）

#### `_call_summary_llm()`：三种必须当失败处理的情况

```python
# agent/context_compressor.py:3890
def _call_summary_llm(self, prompt, prompt_started_at) -> str:
```

**情况 1：空内容**

```python
if not content.strip():
    raise RuntimeError(f"Context compression LLM returned empty content {where}")
```

```python
# Some OpenAI-compatible proxies (e.g. cmkey.cn, one-api channels) return a well-formed HTTP 200
# with an empty or whitespace-only ``content`` instead of an error or empty ``choices``. That
# payload passes ``_validate_llm_response`` (a ``message`` exists), so it reaches here and would
# otherwise be stored as a prefix-only summary with no body — silently wiping the compacted turns
# and making the model forget the in-progress task (#11978, #11914).
```

这是**中间层代理的典型陷阱**：HTTP 200 + `{"choices":[{"message":{"content":""}}]}`。
看起来合法，实际是空的。如果不拦，它会成为一个"只有前缀没有正文"的摘要 →
**整个中间部分被永久删除**。

**情况 2：拒答**

```python
if _is_refusal_response(response, content):
    raise RuntimeError(f"Context compression LLM returned refusal content {where}")
```

模型说"我无法帮你总结这个"。这也不能当摘要存。

**情况 3：截断**

```python
if _response_finish_reason(response) == "length":
    raise RuntimeError(
        f"Context compression summary was truncated ({_TRUNCATED_SUMMARY_MARKER}): generation hit the output "
        f"token cap and the summary is incomplete {where}"
    )
```

注释（这段值得完整读）：

```python
# A finish_reason of "length" means the summarizer hit its output token cap mid-generation: the text
# present is PARTIAL. Persisting a partial summary as the compaction checkpoint silently truncates
# the conversation's memory — the cut-off text replaces the real middle turns AND is fed back into
# every subsequent iterative update prompt, compounding the loss across compactions.
```

"compounding the loss across compactions" 是关键：因为摘要是**迭代**的，
一个截断的摘要会成为下次迭代的输入 → 下次的摘要基于残缺信息 → 损失放大。

**情况 4：`aux_interrupt_protection()`**

```python
# Compression is atomic: protect the in-flight summary call from a mid-turn gateway interrupt.
# Without this, an incoming user message aborts the summary and compression falls back to a degraded
# static marker, losing the real handoff (#23975). Re-entrant: a main-model retry
# (_generate_summary recursion) re-enters harmlessly.
with aux_interrupt_protection():
    response = call_llm(**call_kwargs)
```

问题：用户在你压缩时发了一条新消息。网关想中断当前处理。如果中断了摘要调用，
压缩会退化成静态 fallback 摘要（只列出消息条数），**真实的交接信息全丢**。

所以压缩期间**抑制中断**。用户的输入会排队，等压缩提交完再处理。

#### `_SUMMARY_ROUTE_PIN`：为什么必须是 ContextVar

这是本章最精妙的一处设计。看 [`agent/context_compressor.py:51`](../agent/context_compressor.py:51) 附近的长注释：

```python
_SUMMARY_ROUTE_PIN: ContextVar[Optional[dict]] = ContextVar(...)
_PINNED_ROUTE_FIELDS = ("provider", "model", "base_url", "api_key", "api_mode", "timeout")
```

**为什么不能放成 compressor 的属性**：

1. **detached stalled worker 仍然活着**。超时后宿主认为"这个尝试死了"，
   启动 fallback 尝试。但原 worker 并没有死（它只是慢），它还在跑。
   如果路由 pin 在 compressor 属性上，两个尝试会互相覆盖。
2. **compressor 对象被共享**。同一会话的不同代码路径可能拿到同一个 compressor。

ContextVar 的正确语义：**每个执行上下文（线程/async task）有自己的值**。
所以：
- attempt A 在自己的 context 里 pin 了 fallback 路由
- attempt B 在自己的 context 里 pin 了确定性路由
- 互不干扰，即使它们共享同一个 compressor 对象

```python
# agent/context_compressor.py:98
DETERMINISTIC_SUMMARY_ROUTE = {"provider": "__deterministic__", "model": "__deterministic__"}
```

哨兵值，表示"不要调 LLM"。

#### `_apply_summary_route()`：一个隐蔽的 fallback bug

```python
# agent/context_compressor_summary.py:30
def _apply_summary_route(self, call_kwargs, pinned=None):
    """Pin the summary route onto call_kwargs for both compression entry points.

    After a fallback, an omitted route is NOT "use the main model": call_llm re-resolves
    auxiliary.compression from config — the model that just failed — and a second fallback
    is refused, so every later attempt aborts (#123362). Name the main runtime explicitly.
    """
```

逻辑树：

```text
有 pinned（stall fallback 指定的路由）？
  → 先清掉 provider/model/base_url/api_key/api_mode（keyless pin 自己要解析凭证）
  → 再整体 update
有 summary_model？
  → 只设 model
没有 fallen_back？
  → 什么都不做（用 auxiliary 默认路由）
已经 fallback 过了？
  → 显式设置全部 5 个字段为当前主运行时
```

那个 `#123362` 的 bug 是这样：

```text
auxiliary.compression 配的是 model X
X 失败 → fallback 到主模型 Y
下一次压缩：call_kwargs 没指定 model
  → call_llm 重新解析 auxiliary.compression = X
  → 又用 X，又失败
  → 但 fallback 只允许一次
  → 每次尝试都 abort
```

**教训**：在 fallback 链上，"省略参数"不等于"用默认值"，而是"重新解析配置"。
必须**显式命名**已切换到的目标。

### 5.8 Phase 4：拼装

```python
compressed = self._assemble_compressed(messages, compress_start, compress_end, scan, summary)
return self._finalize_compressed(compressed, canonical_messages, n_messages, spare_pending_images, pruned_count)
```

#### `_assemble_compressed()`

```python
def _assemble_compressed(self, messages, compress_start, compress_end, scan, summary):
    compressed = self._assemble_head(messages, compress_start)
    tail_messages = self._assemble_tail(messages, compress_end, scan.tail_start, scan.summary_indices)
    summary_role, merge_into_tail, force_user_leading, first_tail_visible_idx = (
        self._summary_placement(compressed, tail_messages, compress_start)
    )
    if not merge_into_tail:
        compressed.append({
            "role": summary_role,
            "content": summary + "\n\n" + _SUMMARY_END_MARKER,
            COMPRESSED_SUMMARY_METADATA_KEY: True,
            COMPRESSED_SUMMARY_HAS_USER_TURN_KEY: bool(self._summary_has_user_turn),
        })
    ...
```

**结构**：`head + [summary] + tail`

#### 结束标记的存在理由

```python
_SUMMARY_END_MARKER = "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"
```

```python
# End marker stops weak models treating the quoted summary as fresh input (#11475) or
# regurgitating it (#33256).
```

弱的模型会：
- 把摘要里的"请修复 X"当成**新的用户请求**，去做一遍
- 或者把摘要原文再输出一遍

结束标记是给模型的强提示：上面是历史，下面才是你要回应的。

#### `_COMPRESSION_NOTE`：注进 system prompt 的说明

```python
_COMPRESSION_NOTE = "[Note: Some earlier conversation turns have been compacted into a handoff summary to preserve context space. The current session state may still reflect earlier work, so build on that summary and state rather than re-doing work. Your persistent memory (MEMORY.md, USER.md) remains fully authoritative regardless of compaction.]"
```

它被追加到 **head 的第一条 system 消息**（只加一次，`if self._COMPRESSION_NOTE not in ...`）。

三段语义：
1. **告知**：早前的轮次被压实了
2. **行为指引**：基于摘要继续，不要重做
3. **权威性声明**：持久记忆（MEMORY.md/USER.md）不受压缩影响

第 3 点很重要：压缩只压 **messages**，不碰 system prompt 里的记忆。所以"用户叫什么"
这类信息在压缩后仍然可靠。

#### `merge_into_tail` 的优化

如果 tail 的第一条是**可吸收的行**（比如一条 assistant 消息），摘要可以直接 merge 进去，
省掉一条独立消息。

`force_user_leading` 是修复路径：某些情况下需要一条 role=user 的非空行，
此时摘要必须 merge 进第一个**模板可见**的 user 行。

#### `_finalize_compressed()`：六个收尾动作

```python
def _finalize_compressed(self, compressed, messages, n_messages, spare_pending_images, pruned_count=0):
    """Post-assembly cleanup: orphan pairs, media, savings, markers, replay prune, mem trim."""
```

**① 清理孤儿 tool 对**

```python
compressed = self._sanitize_tool_pairs(compressed)
```

删掉 tool 结果后，可能有 assistant 的 `tool_calls` 没有对应结果，或反之。
provider 会拒绝这种结构。

**② 重新追加"在途用户任务"**

```python
# Single-prompt cron shape: the only live instruction sits in the protected head, BEFORE the
# handoff, and SUMMARY_PREFIX reads that as "nothing to do" — restate it past the boundary
# (#100818).
compressed = self._reappend_inflight_user_task(compressed, self._find_inflight_user_task(messages))
```

cron 的单 prompt 会话：只有一个用户消息（那个 cron 任务），它在 head 里。
压缩后，摘要的 `SUMMARY_PREFIX` 说"上面是历史"，模型看 head 里的任务以为"已经做完了"。
所以把这个任务**在边界之后再说一遍**。

**③ 剥离历史媒体**

```python
compressed = _strip_historical_media(compressed, spared=spared)
```

```python
# Replace image parts in all compressed messages before the newest image-bearing user turn with a
# short text placeholder. Without this, tail messages keep their original multi-MB base-64 image
# payloads forever, which can push every subsequent API request past the provider's body-size limit
# and wedge the session. Port of Kilo-Org/kilocode#9434.
```

"wedged the session"：请求体超限 → 每次 400 → 会话彻底不可用（且压缩也救不了，
因为压缩本身也要发请求）。

**④ like-for-like 的节省统计**

```python
# Like-for-like savings: current_tokens includes system prompt/tool schemas, new_estimate is
# messages-only; comparing them fakes ~96% savings and kills the anti-thrashing guard.
pre_estimate = estimate_messages_tokens_rough(messages)
saved_estimate = pre_estimate - estimate_messages_tokens_rough(compressed)
```

如果拿 `current_tokens`（含 system + tools）和 `estimate(compressed)`（只有 messages）比，
会算出 96% 的节省。这个假数字会让**抗抖动守卫失效**（它以为每次压缩都很有效）。

所以必须**同口径比较**：messages 估 vs messages 估。而且注释说：

```python
# Message-only savings are diagnostic; the verdict belongs to the next provider prompt count.
```

真正的"有效性"判断权交给**下一次 provider 的真实上报**，不是本地估算。

**⑤ 剥离持久化标记**

```python
# Invariant (#57491): no compacted message leaves compress() with a persistence marker.
_strip_persistence_markers(compressed)
```

`_DB_PERSISTED_MARKER`（`_db_persisted`）是"这行已经写进 DB"的内部标记。
它绝不能出现在发给 provider 的 content 里，也不能进下一轮。

**⑥ 清理 stale reasoning replay**

```python
_pruned_replay = _prune_stale_reasoning_replay(compressed)
```

某些 provider（DeepSeek/Qwen）会把 reasoning 放在 `reasoning_content` 里，
下一轮要原样回放。但如果那个 assistant 消息已被压缩掉，回放就变成"无源的思考"。

**⑦ 内存归还**

```python
try:
    from hermes_cli.mem_trim import trim_memory
    trim_memory(reason="post-compression")
except Exception as exc:
    logger.debug("post-compression memory trim failed: ...")
```

```python
# A successful compaction just freed the largest allocation a long session ever drops (the
# compressed-away message dicts), which makes this the natural point to hand allocator pages
# back to the OS. #76905's trim lifecycle covers the gateway/TUI housekeeping loops but not the
# CLI compression path, so RSS keeps the pre-compaction high-water mark until exit. (#70782)
```

Python 的 glibc malloc 不会把释放的内存还给 OS（它会留着给后续分配用）。
在压缩这个"释放最多内存"的时刻，显式 `malloc_trim` 把页面还给 OS。

三个保护：**平台门控**（只有 glibc）、**限流**、**失败只 debug**。
最后一条最重要：**压缩绝不能因为内存整理失败而失败**。

**⑧ 重置 micro 状态**

```python
# Batch marker holds MORE history than the rolling summary: reset micro state so it can't
# supersede/defrag content it lacks; the next micro pass rehydrates from the batch marker.
self._reset_micro_compact_cursor_state()
self._reset_proactive_prune_rearm()
```

一次 batch 压缩后，`_previous_summary` 掌握的**历史比滚动摘要多**。
如果还保留 micro 的旧 cursor 和滚动摘要，下次 micro pass 可能用信息更少的状态去覆盖更全的摘要。

所以重置，让下次 micro pass 从 batch marker **重新 hydrate**。

---

## §6 阈值数学：什么时候触发

### 6.1 三个常量

```python
# agent/model_metadata.py:272
MINIMUM_CONTEXT_LENGTH = 64_000

# agent/context_compressor.py:2717-2718
_MIN_CTX_TRIGGER_RATIO = 0.85

# agent/context_compressor.py:1150-1151
_SMALL_CTX_WINDOW_LIMIT = 512_000
_SMALL_CTX_THRESHOLD_PERCENT = 0.75
```

### 6.2 `_compute_threshold_tokens()`

```python
# agent/context_compressor.py:2768
@staticmethod
def _compute_threshold_tokens(context_length, threshold_percent, max_tokens=None) -> int:
    effective_window = ContextCompressor._effective_input_window(context_length, max_tokens)
    pct_value = int(effective_window * threshold_percent)
    floored = max(pct_value, MINIMUM_CONTEXT_LENGTH)
    trigger_cap = int(effective_window * ContextCompressor._MIN_CTX_TRIGGER_RATIO)
    if effective_window > 0 and floored > pct_value and floored > trigger_cap:
        floored = max(pct_value, trigger_cap)
    if effective_window > 0 and floored >= effective_window:
        return max(1, min(trigger_cap, effective_window - 1))
    return floored
```

逐步拆解：

**步骤 1：算"可用输入预算"**

```python
def _effective_input_window(context_length, max_tokens):
    effective_window = context_length - (max_tokens or 0)
    return effective_window if effective_window > 0 else context_length
```

provider 的窗口同时装输入和输出。如果 `max_tokens=65536`（要求最多输出 64K），
那输入只能用 `context_length - 65536`。

不扣这个的话：200K 窗口、max_tokens 64K、阈值 50% → 触发点 100K。
但实际输入上限只有 136K，模型输出 64K 时 100K + 64K = 164K > 200K？不，其实够。
真正的坑是 `#43547`：自定义 provider 上 max_tokens 很大时，
输入预算比原始窗口小得多，基于全窗口的阈值会让**请求先 400，压缩还没触发**。

**步骤 2：百分比**

```python
pct_value = int(effective_window * threshold_percent)
```

**步骤 3：应用绝对下限**

```python
floored = max(pct_value, MINIMUM_CONTEXT_LENGTH)
```

```python
# ...floored at MINIMUM_CONTEXT_LENGTH so large-context models don't compress prematurely at 50%.
```

1M 窗口 × 50% = 500K。但如果配的是 128K 模型，"50%"=64K 正好。
下限 64K 的含义：**任何模型的触发点不应低于 64K token**。

为什么：小模型配 50% 可能只有 20K，那是"还没聊几句就压"。64K 是经验上的"够用了"。

**步骤 4：下限的退化修复**

```python
# BUT that floor degenerates at small windows: for a model whose context_length is at/below the
# minimum (e.g. a 64K local model), max(0.5*64000, 64000) == 64000 makes the threshold equal
# the ENTIRE window — auto-compression can never fire because the provider rejects the request
# before usage reaches 100% (#14690).
```

64K 窗口：`max(32000, 64000) = 64000` = 整个窗口。
到 64000 时请求已经 400 了，压缩永远不触发 → **会话卡死**。

修复：如果 floor 生效了，就把它压在 `85%` 以内。

```python
if floored > pct_value and floored > trigger_cap:
    floored = max(pct_value, trigger_cap)
```

`floored > pct_value` 判断"floor 是绑定项"（也就是说百分比算出来的更小）。
只有这种情况才压。如果百分比本来就 > 85%，那是用户显式意图，不压：

```python
# An explicit threshold_percent above 85% is user intent; not capped.
```

**步骤 5：百分比 >= 100% 的兜底**

```python
if effective_window > 0 and floored >= effective_window:
    return max(1, min(trigger_cap, effective_window - 1))
```

有人把 `threshold_percent: 1.2` 配进去了。`1.2 × window` 永远达不到。
退回到 85%。

### 6.3 三个数值例子

**例 1：Claude 200K，max_tokens 8192，阈值 50%**

```text
effective_window = 200000 - 8192 = 191808
pct_value = 95890
floored = max(95890, 64000) = 95890
trigger_cap = 163036
floored > pct_value? 95890 > 95890 → False（floor 不绑定）
→ 结果 95890
```

**例 2：本地 64K，no max_tokens，阈值 50%**

```text
effective_window = 64000
pct_value = 32000
floored = max(32000, 64000) = 64000
trigger_cap = 54400
floored > pct_value (True) and floored > trigger_cap (64000 > 54400, True)
→ floored = max(32000, 54400) = 54400
```

结果 54400（85%）。压缩能触发了。

**例 3：本地 8K，阈值 50%**

```text
effective_window = 8000
pct_value = 4000
floored = max(4000, 64000) = 64000
floored >= effective_window (64000 >= 8000, True)
→ return max(1, min(6800, 7999)) = 6800
```

结果 6800（85%）。

### 6.4 `_effective_threshold_percent()`：小窗口提升

```python
# agent/context_compressor.py:2754
@staticmethod
def _effective_threshold_percent(context_length, threshold_percent) -> float:
    """Raise-only small-context threshold floor: models under 512K trigger at >= 75%."""
    if context_length and context_length < _SMALL_CTX_WINDOW_LIMIT:
        return max(threshold_percent, _SMALL_CTX_THRESHOLD_PERCENT)
    return threshold_percent
```

规则：**窗口 < 512K 时，阈值至少 75%**（只能升不能降）。

为什么小窗口要用更高的百分比：

| 窗口 | 50% 触发点 | 剩给对话的余量 | 问题 |
|---|---|---|---|
| 1M | 500K | 500K | 够 |
| 200K | 100K | 100K | 够 |
| 32K | 16K | 16K | 压一次就剩 8K，很快又要压 |
| 8K | 4K | 4K | 每 2 轮压一次，缓存永远重建 |

小窗口上频繁压缩的代价（缓存重建 + 摘要调用 + 信息损失）**大于**"撑到接近满"的风险。
所以 8K 模型宁可用到 75%（6K）再压。

注意 `_SMALL_CTX_WINDOW_LIMIT = 512_000` 这个分界：512K 以下都算"小"。
这不是说 400K 窗口小，而是说"400K 上 50% = 200K，压缩频率仍然偏高"。

### 6.5 `resolve_model_threshold()`：三层优先级

```python
# agent/context_compressor.py:2823
self._base_threshold_percent = resolve_model_threshold(model, self.model_thresholds, threshold_percent, provider)
```

优先级（[`agent/context_compressor.py:2657`](../agent/context_compressor.py:1) 附近）：

```text
1. model_thresholds 里对该 model 的覆盖（最长子串匹配胜出）
2. 全局 compression.threshold_percent（配置）
3. 代码默认 0.50
```

然后叠加 `_effective_threshold_percent` 的 75% floor（只升不降）。

```python
# Per-model overrides (longest substring match wins); floor applied on top.
# Raw config value, before override/floor; fallback when switching to a model with no override.
self._config_threshold_percent = threshold_percent
```

`_config_threshold_percent` 单独保存，是为了 `update_model()` 切换模型时能回退：

```python
# agent/context_compressor.py:2873
# _config_threshold_percent (the raw config value snapshotted above), so switching small -> large
# ...
```

场景：全局配 0.5，`model_thresholds: {"gpt-4": 0.8}`。
- 切到 gpt-4 → 0.8
- 切到 claude → 回到 0.5（不是 0.8）

### 6.6 全部阈值参数速查

| 参数 | 默认 | 位置 | 含义 |
|---|---|---|---|
| `threshold_percent` | 0.50 | `__init__` | 主触发点 |
| ABC 默认 | 0.75 | [`context_engine.py:68`](../agent/context_engine.py:68) | 插件引擎的默认 |
| 小窗口 floor | 0.75 | `_SMALL_CTX_THRESHOLD_PERCENT` | < 512K 时生效 |
| floor 触发上限 | 0.85 | `_MIN_CTX_TRIGGER_RATIO` | floor 绑定时的 cap |
| `protect_first_n` | 3 | `__init__` | head 保留条数（不含 system） |
| `protect_last_n` | 20 | `__init__` | tail 保留条数上限（token 才是真边界） |
| ABC 默认 last | 6 | [`context_engine.py:70`](../agent/context_engine.py:70) | 插件引擎默认 |
| `tail_mode` | "lean" | `__init__` | lean / legacy |
| lean tail floor | 10000 | `LEAN_TAIL_FLOOR_TOKENS` | |
| lean tail cap | 25000 | `LEAN_TAIL_CAP_TOKENS` | |
| lean tail 比例 | 2.5% | 硬编码 | `ctx × 0.025` |
| tail 窗口上限 | 20% | `TAIL_MAX_CONTEXT_FRACTION` | 最终硬 cap |
| `summary_target_ratio` | 0.20 | `__init__` | legacy 模式用 |
| 摘要输出上限 | 10000 | `_SUMMARY_TOKENS_CEILING` | 摘要自己别成压力源 |
| 摘要输出比例 | 5% | `ctx × 0.05` | 与上限取 min |
| 摘要输入上限 | 160K chars | `_SUMMARY_INPUT_MAX_CHARS` | ≈40K token |
| 最小窗口 | 64000 | `MINIMUM_CONTEXT_LENGTH` | |

---

## §7 usage anchor：token 计量的唯一可信来源

### 7.1 问题：token 从哪来

你需要知道"现在上下文用了多少 token"才能在正确的时机压缩。有四个来源：

| 来源 | 准确度 | 可用性 |
|---|---|---|
| provider 报的 `prompt_tokens` | **精确** | 只在**收到响应后**才有 |
| 持久化的 anchor | **精确 + 增量估算** | 需要匹配 |
| 粗略字符估算 | ±30–50% | 永远可用 |
| 消息条数 | 无意义 | 永远可用（只做硬阀门） |

问题：**在发请求之前，我们想知道会不会超**。但精确数字只有发完才知道。

### 7.2 anchor 的设计

anchor 就是"上一次 provider 上报时的快照 + 之后追加部分的估算"：

```python
# agent/usage_anchor.py:67
def capture_usage_anchor(prompt_tokens, completion_tokens, messages) -> Optional[dict]:
    last = messages[-1]
    return {
        "prompt_tokens": pt,
        "completion_tokens": max(0, ct),
        "base_count": len(messages),
        "base_last_role": last.get("role"),
        "base_last_fp": message_fingerprint(last),
        "base_prefix_fp": _priced_prefix_fingerprint(messages, len(messages)),
    }
```

六个字段的作用：

| 字段 | 作用 |
|---|---|
| `prompt_tokens` | provider 报的输入 token |
| `completion_tokens` | provider 报的输出 token（上一轮回复已经在历史里了） |
| `base_count` | 当时 transcript 有几条 |
| `base_last_role` | 最后一条的 role（快速预判） |
| `base_last_fp` | 最后一条的内容指纹 |
| `base_prefix_fp` | **整个被计价前缀**的指纹 |

消费时：

```python
def anchored_context_tokens(messages, anchor, *, charge_stale_thinking=True) -> Optional[int]:
    if not _anchor_matches(messages, anchor):
        return None
    total = int(anchor["prompt_tokens"]) + int(anchor.get("completion_tokens") or 0)
    delta = messages[int(anchor["base_count"]):]
    if delta and delta[0].get("role") == "assistant":
        delta = delta[1:]   # 上一轮的回复已在 completion_tokens 里
    if delta:
        total += estimate_messages_tokens_rough(delta, charge_stale_thinking=charge_stale_thinking)
    return total
```

### 7.3 为什么用内容指纹，而不是行号或 `id()`

```python
# agent/usage_anchor.py:1-15（docstring）
# 指纹而非 id() 的原因：#99421 / #104462
```

三个方案对比：

| 方案 | 问题 |
|---|---|
| **行号（row id）** | transcript 会被重写（resume merge、压缩、rewind）。行号会变，或指向不同内容 |
| **`id()`（对象身份）** | 对象每轮从 DB 重新加载 → 新对象 → `id()` 不同 |
| **内容指纹** | 只有内容变了才失效——**这正是我们想要的语义** |

```python
# agent/usage_anchor.py:31
_FINGERPRINT_KEYS = ("role", "content", "api_content", "tool_call_id", "tool_calls")

def message_fingerprint(msg) -> Optional[str]:
    """Stable digest of one transcript message over its provider-visible, persisted fields."""
    payload = {k: msg.get(k) for k in _FINGERPRINT_KEYS if msg.get(k) is not None}
    raw = json.dumps(payload, sort_keys=True, default=str, ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8", "replace")).hexdigest()
```

五个字段的选取原则（注释）：

```python
# Identity of a priced message = the provider-visible fields that round-trip the session DB
# byte-for-byte. Display/persistence metadata (timestamps, row ids, display kinds) is rewritten
# on reload and would only ever fail the match closed.
```

- `role` / `content` / `api_content`：provider 看到的内容
- `tool_call_id` / `tool_calls`：工具调用的身份
- **不含** `timestamp`、`_row_id`、`display_kind`：这些每次加载都会被重写

`sort_keys=True` + `separators=(",", ":")`：保证同一个 dict 序列化成同一个字符串
（Python 3.7+ dict 保序，但**嵌套** dict 的顺序不保证，所以必须排序）。

### 7.4 `base_prefix_fp`：为什么需要整个前缀的指纹

```python
# agent/usage_anchor.py:46
def _priced_prefix_fingerprint(messages, base_count) -> Optional[str]:
    """Stable digest of the whole provider-priced prefix.

    The last priced message fingerprint proves only that one row survived at
    ``base_count - 1``. A compaction can preserve that row while rewriting the
    earlier prefix, so the anchor must also bind to the full priced prefix it
    represents.
    """
```

这是本章最精细的一个 bug 修复。场景：

```text
压缩前: [A, B, C, D, E]   base_count=5，anchor 记下 D/E 的指纹
压缩后: [A, B', SUM, D, E]  D 和 E 还在原位置（base_count-1 和 base_count-2）
        但前面的 B 被改写成了 B'，中间插入了摘要
```

只检查 `base_last_fp`（最后一条）会**误判 anchor 仍然有效**。
但实际的 prompt 前缀已经全变了 → provider 的缓存 miss，且真实 token 数也变了。

所以必须对**整个前缀**算指纹。

代价：每次 `anchored_context_tokens()` 调用要算 `base_count` 次 sha256。
对 200 条消息的会话，就是 200 次 sha256（每次几微秒）= 1ms 左右。可接受。

### 7.5 持久化：为什么写在 session 行上

```python
# agent/usage_anchor.py:26
USAGE_ANCHOR_MODEL_CONFIG_KEY = "_usage_anchor"

def persist_usage_anchor(agent, anchor) -> None:
    """Write (or clear, None) the session row's anchor blob. Best-effort: the row may not exist yet."""
    patcher = getattr(getattr(agent, "_session_db", None), "patch_session_model_config", None)
    patcher(session_id, {USAGE_ANCHOR_MODEL_CONFIG_KEY: _serialize(anchor)})
```

存在 `sessions.model_config` 的 JSON blob 里（07 篇讲的 `model_config` 列）。

收益：**新进程能恢复**。

| 场景 | 没有持久化 | 有持久化 |
|---|---|---|
| `hermes --resume` | 第一轮必须等一个请求 | 立刻知道 |
| desktop 每轮 `serve` | 每轮都等一个请求 | 立刻知道 |
| gateway 重启 | token 数据丢失，退化成估算 | anchor 还在 |

### 7.6 恢复时的 fail-closed

```python
def restore_usage_anchor(agent, conversation_history) -> None:
    """On a resumed session, adopt the persisted anchor when conversation_history still carries
    the priced prefix; otherwise clear the stale blob so it can never suppress compression."""
    anchor = _serialize(getter(session_id, USAGE_ANCHOR_MODEL_CONFIG_KEY, None))
    if anchor is None:
        return
    if _anchor_matches(conversation_history, anchor):
        agent._usage_anchor = anchor
    else:
        persist_usage_anchor(agent, None)   # 清掉脏数据
```

注意 `else` 分支：**主动清掉**。

为什么不能只"不用它"而要"删掉它"：如果一个过期的 anchor 一直存在，
下一个进程恢复时又会读它、又匹配不上、又不用……虽然行为正确，但每次都要算指纹、
而且**永远不会更新**（因为没有新 anchor 写入时旧的不动）。

更危险的是：如果某个代码路径忘了检查匹配，就会用过期 anchor → **低估 token** →
不触发压缩 → 溢出。

所以：**匹配不上就删，宁可没有。**

### 7.7 什么时候清除 anchor

| 事件 | 为什么 |
|---|---|
| **压缩** | 前缀已变，anchor 必然不匹配（但 `_anchor_matches` 也会挡住，双保险） |
| **会话重置 / `/new` / `/reset`** | transcript 全新 |
| **rewind / 编辑重发** | transcript 尾部被截断，`base_count` 越界 |
| **codex native 压缩** | 服务端改了上下文 |

### 7.8 没有 anchor 时：等一个请求

回顾 §4.4 的 `should_defer_preflight_to_real_usage()`：

```text
没有 anchor（first request / rewind / reloaded history）且粗估超阈值
→ 不动手，先发这次请求
→ 拿到真实 usage → capture anchor
→ 下次再判断
```

**为什么这个决策是对的**：

- 粗估偏高 30-50%。在 50% 阈值下，真实 38% 会估成 52%。
- 一次请求的代价 = 正常情况下一次请求（本来就要发）。
- 一次不必要压缩的代价 = 一次摘要 LLM 调用 + 全部缓存失效 + 信息损失。

而且有兜底：如果这次请求真的超了，provider 返回溢出错误 → **reactive 恢复**（§8.6）。

### 7.9 `_provider_omits_usage` 例外

```python
return not self._provider_omits_usage
```

有些 provider（某些本地 ollama 配置）**永远不报 usage**。
如果还坚持"等真实数据"，那就**永远不会压缩**（`#2153`）。
所以一旦探测到 provider 不报 usage，就直接用估算（永远 defer=False）。

这是 **fail-open 的一个例外**：宁可误压缩，也不能永不压缩（后者必然导致会话卡死）。

---

## §8 失败模式、冷却与刹车

这是本章最"工程"的一节。压缩是**唯一**会破坏缓存的机制，所以它的失败处理必须极其克制。

### 8.1 失败分类表

```python
# agent/context_compressor.py:689
class _SummaryFailureKind(...)
```

| 类别 | 触发 | 是否 terminal（必须 abort） | 冷却 |
|---|---|---|---|
| 访问/配额（401/403/quota） | `_SUMMARY_PERMANENT_QUOTA_MARKERS` 命中 | **是** | 长 |
| 网络（连接错误） | 传输层 | **是** | 阶梯 |
| 截断（`finish_reason=length`） | 输出上限 | **是** | 阶梯（独立计数器） |
| 空内容 | 代理返回空洞 | **是** | 阶梯 |
| 拒答 | 模型拒绝 | **是** | 阶梯 |
| 过载（429）/ 503 | provider overload | 前几次是，`>=3` 次后降级为 fallback | 阶梯 |
| 超时 / 卡住 | 无进展 | 否 | 阶梯（60/300/900） |

### 8.2 为什么这些必须 terminal

```python
# agent/context_compressor.py:5329
"""Abort (messages unchanged) on a terminal failure or when configured to; True when aborted.
Access/quota, network, truncated and empty-content failures ALWAYS abort (#29559); an overload
aborts only until the sustained-overload escalation (#123167); otherwise
``abort_on_summary_failure`` decides between abort and the static fallback."""
```

逻辑：这些失败说明**摘要调用从根本上不可用**（配额用完、网络断、输出被截）。
如果降级成"静态 fallback 摘要"，你会得到一份很差的摘要（只列消息条数），
而且它会被**迭代继承**到后续所有压缩。

对比"超时"：超时可能只是这次慢。下次可能成功。所以超时**不** terminal，
走冷却 + 静态 fallback（至少这次有点收益）。

### 8.3 超时冷却阶梯

```python
# agent/context_compressor.py:791
# Timeouts escalate 60s -> 300s -> 900s: structural repeat offenders back off longer.
_TIMEOUT_COOLDOWN_LADDER = (60, 300, 900)
```

```python
def _next_timeout_cooldown(compressor, counter="_consecutive_timeout_failures") -> int:
    n = getattr(compressor, counter, 0) + 1
    setattr(compressor, counter, n)
    return _TIMEOUT_COOLDOWN_LADDER[min(n, len(_TIMEOUT_COOLDOWN_LADDER)) - 1]
```

**为什么是阶梯而不是固定值**：

- 固定 60 秒：一个确定的结构性问题（比如这个 model 的压缩路由永远超时）
  → 每 60 秒重试一次 → 一天重试 1440 次 → 每次都烧配额和缓存
- 阶梯：第一次 60 秒（可能是偶发），第二次 300 秒（可能持续），第三次 900 秒（大概率结构性）

**为什么计数器要分离**：

```python
# ``counter`` stays separate per failure class: the timeout streak also arms the deterministic stall
# fallback (``_prior_timeout_failures``), which a truncation must not trigger.
```

`_consecutive_timeout_failures` 这个计数器还驱动"确定性 fallback"（§8.4）。
如果截断也加这个计数器，那么"3 次截断"会导致"以后都跳过 LLM"——这是错的，
因为截断换个 max_tokens 或换个模型就好了。

所以截断有自己的计数器（`_consecutive_truncation_failures` 之类），
走**同样的阶梯**但**不触发确定性 fallback**。

### 8.4 确定性 fallback：从"重试"到"放弃 LLM"

```python
# agent/context_compressor.py:98
DETERMINISTIC_SUMMARY_ROUTE = {"provider": "__deterministic__", "model": "__deterministic__"}
```

```python
# agent/context_compressor_summary.py:68
if take_deterministic_summary_pin():
    self._last_summary_error = (
        "summary model stalled on every route; deterministic fallback summary inserted"
    )
    return None
```

触发条件：**超时类失败累计到一定程度**（`_prior_timeout_failures`）。

语义：**别再试了**。这次压缩用确定性摘要（`_build_static_fallback_summary`），
不调任何 LLM。

为什么这比"继续重试"好：

```python
# 长会话 + 摘要模型永远超时
# → 每次压缩都等 60-900 秒
# → 用户每轮都卡
# → 而且 transcript 在等的时候继续增长
# → 最后溢出，会话废掉
```

确定性 fallback 的结果虽然差（"之前有 47 条消息被压缩，涉及 X、Y 工具"），
但**压缩会发生**，上下文会缩小，会话能继续。

### 8.5 抗抖动（anti-thrash）

```python
# agent/context_compressor.py:3019
def _tripped(self) -> bool:
    """Only provider-confirmed ineffective compactions trip the breaker.

    A static fallback still reclaims the window, so blocking on it lets the prompt run into the
    provider's hard limit. The fallback streak instead benches the failing summary model
    (``_fallback_streak_skip``), which is what stops a paid fallback loop (#63008).
    """
    return self._ineffective_compression_count >= 2
```

规则：**连续 2 次"压缩了但 token 没降"** → 熔断。

什么算"没降"：注释（§5.8 ④）说得很清楚——**以 provider 下一次真实上报为准**，
不是本地估算：

```python
# Message-only savings are diagnostic; the verdict belongs to the next provider prompt count.
```

`_ineffective_compression_count` 怎么加：

```text
压缩前记录 last_real_prompt_tokens = R1
提交压缩
下一轮 provider 报 R2
如果 R2 >= R1 → ineffective++  
否则 → 重置为 0
```

什么情况下会"压了不降"：

| 场景 | 原因 |
|---|---|
| tail 太大，压掉的被 tail 的图片抵消 | 固定 |
| 摘要本身 10K token，压掉 8K | 净增 |
| system prompt + tool schema 占大部分 | messages 降了但 total 没降 |
| 压缩后 tail 里有巨大 tool 结果 | 见 §5.5 pressure demote |

**为什么不阻断 fallback 摘要**：docstring 明说——静态 fallback 仍然回收窗口。
如果因为"上次无效"就彻底不压，prompt 会长到 provider 硬上限。

所以熔断只阻断**付费的 LLM 摘要**，不阻断"确定性 drop"。
后者由 `_fallback_streak_skip` 的 bench 机制处理。

### 8.6 熔断的可恢复性

```python
# agent/context_compressor.py:3061
# Anti-thrash back-off must not be permanent: after _ANTI_THRASH_RECOVERY_SECONDS blocked, allow ONE
...
_ANTI_THRASH_RECOVERY_SECONDS = 300.0
```

熔断 300 秒后允许**一次**探测。如果这次有效 → 完全恢复。如果还是无效 → 再 300 秒。

**为什么必须有恢复机制**：一次"无效"可能是偶然的（比如那一轮刚好有个巨大 tool 结果进来）。
永久熔断会让会话在长跑中完全失去压缩能力。

### 8.7 `abort_on_summary_failure` 配置

```yaml
compression:
  abort_on_summary_failure: true
```

含义：**宁可会话冻结，也不接受降级摘要**。

冻结的表现（docstring）：

```python
"Summary generation failed — aborting compression (compression.abort_on_summary_failure=true). "
"%d message(s) preserved unchanged. Conversation is frozen until the next /compress or /new."
```

适用人群：对摘要质量极度敏感的用户（比如长跑的研究任务，宁可手动介入）。

### 8.8 abort 时必须回滚

```python
# Roll back the self-heal rehydration so the aborted attempt is a true no-op (#57835). Only the
# attempt still owning summary work may roll back: a detached stale attempt (reachable here via
# the deterministic summary pin) must not revert the fallback's _previous_summary.
from agent.conversation_compression import _caller_attempt_is_current

if _caller_attempt_is_current(self):
    self._previous_summary = previous_summary_before_scan
```

`_scan_window_handoffs` 会做"self-heal rehydration"——从 transcript 里找到上次的摘要行，
恢复 `_previous_summary`。这是一个**有副作用的读**。

如果这次压缩 abort 了，这个副作用必须撤销，否则：
- 一次中止的尝试改变了 compressor 状态
- 下次尝试基于一个"并没有真的发生"的状态

但还是那句：**只有当前 owner 才能回滚**。一个过期的 detached attempt 不能撤销
fallback 已经推进的状态。

### 8.9 过载升级（#123167）

```python
# agent/context_compressor.py:800
# Sustained-overload escalation (#123167): ONE overload aborts so a later retry can still win
# (#115906), but if every summary attempt keeps aborting the transcript only grows until the
# session exits compression_exhausted and the gateway auto-resets — bounded middle-window loss
# becomes a total session wipe, just deferred. After this many consecutive overload aborts in one
# session the overload stops counting as terminal and compress() commits the deterministic
# fallback instead.
_CONSECUTIVE_OVERLOAD_ABORT_ESCALATION = 3
```

这是一个非常深入的分析。逐句：

1. **一次过载应该 abort**：provider 过载是暂时的，abort 让"下次重试"还有机会赢
2. **但如果每次都 abort**：transcript 只增不减 → 会话走到 `compression_exhausted` →
   **gateway 自动 reset 会话**
3. **对比**："丢掉中间窗口"（降级摘要）vs "丢掉整个会话"（reset）
4. 所以：**连续 3 次过载 abort 后，降级为确定性 fallback**

"bounded middle-window loss becomes a total session wipe, just deferred" ——
这句话点出了一类常见的架构陷阱：**为了避免小损失而死守，最终导致大损失**。

同样属于"从 0 到 1 再到放弃"的三段式：`_TIMEOUT_COOLDOWN_LADDER` 是时间维度的，
这个是**语义维度**的。

#### 计数器必须持久化

```python
# The streak is durable per session (the gateway binds a fresh compressor on every turn / cache
# eviction, so a memory-only budget restarted at zero)
```

同 `_fallback_probe_at` 的理由：compressor 对象可能每轮重建。
内存计数器永远是 0 → 永远到不了 3 → 永远在 abort。

重置条件：
- 一次成功摘要
- 一次完成的边界（包括降级 fallback，否则恢复后仍然是降级态）
- 运行时切换（换模型了，重新开始）

### 8.10 一次压缩尝试的完整安全网

把 §8 的东西串起来：

```text
compress() 被调用
│
├─ _raise_if_stale_attempt()          ← 我不是 owner 就直接抛
├─ 消息数不足？ → structural_no_op（不算失败）
├─ should_compress_info() 说被挡？
│    ├─ cooldown:<s>                 ← 摘要失败冷却
│    ├─ structural_backoff:<s>       ← 无效压缩退避
│    └─ ineffective                  ← 熔断
│
├─ Phase 1 剪枝（本地，不会失败）
├─ Phase 2 选边界（本地）
├─ Phase 2.5 lean tail demote（本地，先做出必然的收益）
├─ _raise_if_stale_attempt()          ← 第二次
├─ Phase 3 摘要：
│    ├─ 被 bench？ → 确定性 fallback
│    ├─ 中间太小？ → 确定性 drop
│    ├─ 冷却中且非 bypass？ → 返回 None → fallback
│    ├─ 调 LLM（aux_interrupt_protection 保护）
│    │    ├─ 空/拒答/截断 → terminal → abort（历史不变）
│    │    ├─ 超时 → 阶梯冷却 → fallback
│    │    ├─ 过载 → 前 3 次 abort，之后 fallback
│    │    └─ 成功 → 迭代更新 _previous_summary
│    └─ _raise_if_stale_attempt()     ← 第三次（写入前）
│
├─ Phase 4 拼装（本地）
└─ _finalize_compressed（本地）
     └─ 提交时：lease / fence / archive（07 篇 §6、本章 §10）
```

**注意 lease/fence 的位置**：不在 `compress()` 里，在**宿主**的提交路径
（[`agent/compression_facade.py`](../agent/compression_facade.py:218) +
[`agent/conversation_compression.py`](../agent/conversation_compression.py:1)）。

理由（[`agent/AGENTS.md`](../agent/AGENTS.md:83)）：

> never a prune committed outside the lease/fence.

`compress()` 是**纯计算**：输入 messages，输出新 messages。它不知道数据库、不知道租约。
提交是宿主的事。这样 `compress()` 可测试、可重放、可干跑（`--preview`）。

### 8.11 超时的两层预算

[`agent/compression_facade.py`](../agent/compression_facade.py:48)：

```python
def _report_compression_timeout(agent, *, idle, waited, since_progress, total_ceiling,
                                 total_exhausted, progress_observed) -> None:
    """Host-side timeout bookkeeping: log, activity stamp, cooldown ladder, user warning."""
```

```python
# agent/compression_facade.py:55
if total_exhausted:
    logger.warning("Context compression reached its total ceiling after %.1fs ...")
else:
    logger.warning("Context compression made no progress for %.1fs (total wait %.1fs, ceiling %.1fs) ...")
```

两层：

| 预算 | 含义 | 为什么需要 |
|---|---|---|
| **idle**（无进展） | 多久没收到进展信号 | 卡死检测 |
| **total ceiling** | 总耗时上限 | 一个慢但"有进展"的调用不能无限拖 |

"进展"是什么：流式 token。每次收到 chunk 就 tick 一下（`fence.seconds_since_progress()`）。
这样：
- **卡住**（一个 token 都不来）：idle 时间一到就判超时
- **极慢**（每秒 1 个 token）：idle 不触发，但 ceiling 会兜住

单用 idle 的问题：极慢的调用永远不会被 idle 判超时。
单用 ceiling 的问题：一个正常但需要 5 分钟的摘要会被误杀。

#### 为什么超时也要进冷却阶梯

```python
# Same timeout cooldown ladder as summary-LLM timeouts: avoid re-burning the full idle budget every turn.
```

如果每次超时都是"等满 idle 预算 → 超时 → 下一轮再来"，用户每轮都要等 60 秒。
进冷却阶梯后：第一次等 60 秒，之后 60 秒内直接跳过（立即返回），用户不会感觉到卡。

#### 超时也必须走 `_touch_activity`

```python
touch = getattr(agent, "_touch_activity", None)
if callable(touch):
    touch("context compression timed out", provenance=ActivityProvenance.AGENT_COMPRESSION_TIMEOUT)
```

`_touch_activity` 是"这个会话还活着"的心跳。压缩超时也是一种活动
（否则 gateway 的 liveness 检测可能误判会话僵死而重连/重置）。

`provenance` 参数区分"为什么活着"——用于诊断。

---

## §9 三条非主线压缩路径

主线是 `ContextCompressor.compress()`。但还有三条路径，各自解决特定场景。

### 9.1 原生压实（`native_compaction.py`）

```python
"""Native OpenAI Responses server-side compaction on supported OpenAI routes.

``context_management=[{"type": "compaction", "compact_threshold": N}]`` makes the server
summarize older context into an opaque ``compaction`` item once the input crosses N tokens.
Deliberately narrow: gpt-5.6 on api.openai.com or the ChatGPT Codex backend, plus gpt-6-astra
(and its ``-900k`` picker alias) on official Codex OAuth. The local compressor
stays armed as fallback (native threshold clamped below the local trigger); compaction items
ride the ``codex_reasoning_items`` sidecar. No transport imports (shared gate, no cycles).
"""
```

#### 它做什么

OpenAI Responses API 支持**服务端压实**：你在请求里带一个参数，
服务端在输入超过阈值时**自己**把老内容换成一段不透明的 `compaction` item。

优点：不需要本地调摘要 LLM，服务端做，快且免费（相对）。

#### 为什么"故意窄"

```python
def is_native_compaction_model(model, *, provider=None, base_url=None) -> bool:
    return _ELIGIBLE_MODEL_MARKER in (model or "").lower() or (
        is_astra_model(model)
        and (provider or "").strip().lower() == "openai-codex"
        and is_official_codex_base_url(base_url or "")
    )
```

`_ELIGIBLE_MODEL_MARKER = "gpt-5.6"`，`is_direct_openai_route` 只认 `api.openai.com`
或 Codex backend。

理由：这个能力依赖**服务端的特定实现**。任何第三方代理（one-api、各种中转）都可能：
- 不支持这个参数 → 400
- 支持但行为不同 → 上下文被"压实"成垃圾
- 声称支持但静默忽略 → 本地以为服务端管了，结果什么都没压

所以**只对确定知道的官方路由开启**。

#### 阈值必须低于本地触发点

```python
LOCAL_TRIGGER_SAFETY_MARGIN = 8_192

def resolve_compact_threshold(configured_threshold, local_trigger_tokens=None) -> int:
    local = _positive_int(local_trigger_tokens)
    upper = None if local is None else max(
        1_024, local - LOCAL_TRIGGER_SAFETY_MARGIN if local > LOCAL_TRIGGER_SAFETY_MARGIN else int(local * 0.8))
    ...
    return max(1_024, min(configured, upper))
```

```python
# Native compaction fires this far below the local trigger so the server gets the first shot.
```

设计意图：**让服务端先动手**。如果本地先触发，服务端压实就永远用不上。

`- 8192` 或 `× 0.8`（取较大值）：窗口很小时，减 8192 可能变成负数，所以用比例兜底。

#### 与 `checkpoint_required` 冲突时禁用

```python
# Server-side compaction is a lossy boundary the provider owns (no pre-compress checkpoint
# can run first), so the checkpoint-aware compressor stays authoritative.
if getattr(agent, "compression_checkpoint_required", False) is True:
    _warn_native_compaction_suppressed_by_checkpoint_gate()
    return None
```

如果用户要求"压缩前必须有记忆 checkpoint"，那服务端压实**绝对不能启用**——
因为它是**服务端**做的，本地没有机会跑 `on_pre_compress`。

这是一个**正确性优先于性能**的选择。

#### 每请求重新检查

```python
"""Every gate is re-checked per request so a mid-session model switch or the in-session
kill switch (``agent.codex_responses_native_compaction = False``) takes effect next call."""
```

不在会话开始时算一次就缓存。因为：
- 用户可能在会话中途切模型
- 可能有 kill switch（运行时关闭）

### 9.2 微压实（`micro_compaction.py`）

```python
"""Micro-compaction mixin for ContextCompressor.

Rolling per-exchange summarization that folds old user/assistant exchanges into a single
summary marker between turns. OFF by default: every pass rewrites the prompt prefix and
breaks the provider prompt cache.
"""
```

#### 它做什么

不是"到阈值才动手"，而是**每 N 轮**把最老的一个完整交换（一次 user + assistant + tools）
合并进一个**滚动摘要**。

```text
第 1 轮: [U1, A1]                          → 不压（只有 1 个交换）
第 2 轮: [U1, A1, U2, A2]                  → 不压
第 3 轮: [U1, A1, U2, A2, U3, A3]          → 把 U1/A1 折进滚动摘要
         [SUM(U1,A1), U2, A2, U3, A3]
第 4 轮: [SUM, U2, A2, U3, A3, U4, A4]     → 把 U2/A2 折进去
         [SUM(U1..U2), U3, A3, U4, A4]
```

#### 为什么默认关闭

注释一句话解释：**every pass rewrites the prompt prefix and breaks the provider prompt cache**。

每次 micro pass 都改写前缀 → 每 N 轮一次缓存全 miss。
对于"上下文本来就够用"的用户，这是纯损失。

所以它是给"极端长会话、宁愿牺牲缓存也要控制上下文"的用户准备的。

配置：

```yaml
compression:
  micro_compact: false
  micro_compact_every_n_turns: 1
  micro_compact_defrag_threshold_tokens: 2000
```

#### 与 batch 压缩的交互

```python
# Batch marker holds MORE history than the rolling summary: reset micro state so it can't
# supersede/defrag content it lacks; the next micro pass rehydrates from the batch marker.
self._reset_micro_compact_cursor_state()
```

batch 压缩后，`_previous_summary` 包含的信息比滚动摘要多。
如果 micro 还用旧滚动摘要去"supersede"，就是**用少的信息覆盖多的信息**。

所以重置，让下次 micro pass 从 batch marker 重新 hydrate：

```python
def _resolve_compact_cursor(self, messages, head_end, tail_start) -> int:
    if head_end < self._micro_compact_cursor < tail_start:
        return self._micro_compact_cursor
    summaries = (i for i in range(head_end, tail_start) if self._is_context_summary_message(messages[i]))
    last = max(summaries, default=-1)
    cursor = last + 1 if last >= head_end else head_end
    if last >= head_end:
        # Resumed session: rehydrate the rolling summary from the surviving marker so the next
        # pass merges, not replaces.
        recovered = self._rolling_summary_from_marker(messages[last].get("content"))
        if recovered:
            self._micro_compact_rolling_summary = recovered
            # Rehydration proves containment: this marker (batch or micro) becomes
            # supersede/defrag-eligible; unabsorbed markers never get the key.
            messages[last][_cc().MICRO_COMPACT_MARKER_KEY] = True
```

`MICRO_COMPACT_MARKER_KEY` 的语义很细：**只有"已经被吸收进滚动摘要"的 marker 才能被 supersede**。
未吸收的 marker 不打这个 key，所以永远不会被覆盖。

#### 交换边界的严格定义

```python
def _find_one_exchange(self, messages, start, tail_start):
    """Find the next complete exchange (full agent turn) starting at *start*...
    Spans assistant+tool rows up to the next user message; user turns are never absorbed
    (alternation safety, verbatim user text)."""
    ...
    # Boundary must close the turn: a mid-turn stop at tail_start would put the assistant marker
    # beside assistant/tool rows. Any other role is a safe splice (avoids wedging the cursor).
    boundary = messages[idx] if idx < len(messages) else None
    if not isinstance(boundary, dict) or boundary.get("role") in ("assistant", "tool"):
        return None
```

三条约束：

1. **user 消息永不被吸收**——用户的原文必须保留（可能与后续追问相关）
2. **必须是完整交换**——不能从 assistant 中间切开（会产生孤立 tool）
3. **边界必须闭合**——切点后面不能紧跟 assistant/tool（否则 marker 和它们混在一起）

这是"**宁可这轮不压，也不要产生非法结构**"。

#### 输出截断的保护

```python
if _cc()._response_finish_reason(response) == "length":
    logger.warning(
        "micro-summarization output hit the token cap (finish_reason=length) — discarding partial summary",
    )
    return None
```

同 batch 的理由：部分合并会让滚动摘要丢尾巴，而它会成为下次合并的基础 → 损失放大。

注意这里**是有 max_tokens 的**：

```python
"max_tokens": min(1500, self.max_summary_tokens or 1500),
```

与 batch 相反（batch 绝不设 max_tokens）。理由：micro 的摘要是**滚动小摘要**，
目标是 1-2K token。设上限让模型知道要压缩。而 batch 的摘要承载整个会话历史，
不能让 wire 层截断——所以靠 prompt 里的 budget 说明而不是 max_tokens。

#### defrag

```python
def _needs_defrag(self) -> bool:
    return estimate_tokens_rough(self._micro_compact_rolling_summary) >= self._micro_compact_defrag_threshold_tokens
```

滚动摘要会随着每次合并变长。超过 2000 token 时，把**它自己**再总结一次
（`_defrag_rolling_summary`），重写 marker 内容。

注意它是 **transcript-shape-neutral**：

```python
"""Re-summarize the rolling summary text and rewrite the marker in place.
Transcript-shape-neutral (no splice, no cursor move). Returns True when it rewrote."""
```

不改消息数量、不移动 cursor，只替换一条消息的 content。副作用最小。

#### 一个复杂的缓存失效问题

```python
entry["content"] = self._render_micro_marker_content(fresh_summary)
entry.pop(_cc()._DB_PERSISTED_MARKER, None)
# Sibling of the finalize_turn pop site (#75170): this pop also strips the marker from a LIVE
# dict in place, so the bounded flush-scan cursor would identity-skip the rewritten marker and
# the defragged summary would never reach state.db.
self._flush_scan_cursor_invalidated = True
```

这段注释揭示了一个**性能优化导致的正确性 bug**：

会话落盘用的是"有界增量扫描"：记住上次 flush 到哪个对象（按 `id()`），
下次从这里继续，只扫新对象。这是为了避免每轮重扫全部历史。

但如果我在**原地修改**了一个已经扫过的 dict：
- `id()` 没变 → 扫描器认为"已经处理过了" → 跳过
- 结果：修改永远不落盘

两个解法：

| 解法 | 做法 | 适用 |
|---|---|---|
| **打破身份** | 建一个新 dict（新 `id()`） | 大多数场景（`_fresh_compaction_message_copy`） |
| **置失效标志** | 设 `_flush_scan_cursor_invalidated = True`，让 finalizer 下次全扫 | 必须在原地改（因为要让已持有的引用看到新内容） |

这里必须选后者，因为滚动摘要的 marker 可能被多处引用。

**教训**：任何"基于对象身份的增量优化"都必须在"原地修改"时失效。
这是一个通用的编程陷阱，不是 Hermes 特有的。

### 9.3 手动 `/compress`（`conversation_compression_manual.py`）

```python
"""Manual ``/compress`` core shared by the CLI, gateway, TUI and ACP surfaces.

Manual compression is the ONE sanctioned history mutation (prompt-cache invariant): each surface
parses its own flags and renders its own text, but the sequence — split for ``here [N]``,
estimate, run ``agent._compress_context(force=True)``, detect a lock-skip, rejoin the verbatim
tail, summarize — lives here so ``--preview`` / ``--aggressive`` and the lock-skip wording cannot
drift per surface again.
"""
```

**一个实现，四个界面**。各界面只负责：
1. 解析自己的 argv（CLI 的 `args`、TUI 的命令、gateway 的消息文本、ACP 的请求）
2. 调 `compress_now()`
3. 安装返回的 `after_messages`
4. 渲染 `render_compress_result()`

#### 参数语法

```python
# agent/conversation_compression_manual.py:22
@dataclass
class CompressRequest:
    preview: bool = False
    aggressive: bool = False
    partial: bool = False
    keep_last: int = 2
    focus_topic: Optional[str] = None
```

```python
# hermes_cli/partial_compress.py
DEFAULT_KEEP_LAST = 2
MAX_KEEP_LAST = 100
```

| 语法 | 含义 |
|---|---|
| `/compress` | 全量压缩 |
| `/compress <topic>` | 全量压缩，重点保留 topic 相关内容 |
| `/compress here [N]` | 只压到"倒数第 N 个交换"之前，保留最近 N 个交换原文 |
| `/compress up to here [N]` | 同上（别名） |
| `/compress --keep N` / `-k N` | 同上（flag 形式） |
| `/compress --preview` / `--dry-run` | 只报告会压什么，不改任何东西 |
| `/compress --aggressive` | **拒绝**（见下） |

`MAX_KEEP_LAST = 100`：防止 `/compress here 9999` 变成一个"什么都没做"的空操作
（`_coerce_keep` 会 clamp 到 100）。

#### 为什么 `--aggressive` 被拒绝

```python
AGGRESSIVE_UNSUPPORTED = (
    "--aggressive is not supported; use '/compress here [N]' to keep only recent exchanges, "
    "or /undo to drop turns.")
```

```python
# Every surface renders the same refusal; hard truncation has no persistence path outside the
# guarded _compress_context rotation, so --aggressive is refused rather than mis-parsed as a focus topic.
```

原因：**硬截断没有安全的持久化路径**。

所有历史改写都必须走 `_compress_context` 的 rotation（归档旧行 + 插入新行），
因为那里有 lease/fence/血缘管理。如果允许"直接删掉前面的消息"，
数据库里的 `active=1` 行就少了一段，但会话血缘、usage anchor、tool 对关系全部失配。

所以：**功能不存在，比存在但会破坏数据好**。

注意注释的第二半："rather than mis-parsed as a focus topic"——
如果 `--aggressive` 不被识别为 flag，它会被当成 focus topic（"请重点保留 aggressive 这个词"），
用户会得到一个荒谬的结果。所以要**显式拒绝**。

#### `compress_now()` 的完整流程

```python
def compress_now(agent, history, request, *, system_message=None, task_id="default",
                 skip_without_window=False, snapshot_is_current=None) -> CompressResult:
    before = list(history)
    before_tokens = estimate_request_tokens(agent, before)
    head, tail = before, []
    if request.partial:
        head, tail = split_history_for_partial_compress(before, request.keep_last)
        if not tail:   # degenerate split
            head = before
    if request.preview:
        report = summarize_compress_preview(...)
        return CompressResult("preview", before, before, ...)
    ...
    compressed, _ = agent._compress_context(
        head, system_message, approx_tokens=before_tokens, focus_topic=request.focus_topic,
        force=True, defer_context_engine_notification=True, ...)
```

关键点逐个：

**① `estimate_request_tokens` 而不是 `estimate_messages_tokens`**

```python
def estimate_request_tokens(agent, messages) -> int:
    """Transcript + system prompt + tool schemas: a transcript-only figure understates real request
    pressure and can even appear to grow after a dense handoff summary replaces many short turns (#6217)."""
    return estimate_request_tokens_rough(
        list(messages), system_prompt=getattr(agent, "_cached_system_prompt", "") or "",
        tools=getattr(agent, "tools", None) or None)
```

`#6217` 描述的现象：用 messages-only 估算时，一次压缩后 token **看起来变多了**。
因为 20 条短消息（每条约 50 token 的开销）被换成 1 条长摘要（3000 token）。
真实的请求压力（含 system + tools）是下降的，但 messages-only 是上升的。

**② `system_message=None` 是有意的**

```python
# ``system_message=None`` makes ``_compress_context`` rebuild the prompt; passing the cached prompt
# duplicated the identity block (#15281).
```

如果传 `_cached_system_prompt`，`_compress_context` 内部可能又拼一次身份块 →
**system prompt 里出现两遍"你是 Hermes"**。

**③ `skip_without_window` 只给 gateway**

```python
"""``skip_without_window`` (gateway) answers ``nothing_to_do`` when the local compressor sees no
summarizable middle; the in-process surfaces leave it off because ``_compress_context`` still does
useful work there — codex_app_server native compaction, and the phase-1 tool-result prune /
blank-echo drop that ``Compressor.compress`` commits even when no summary window exists."""
```

差异：

| 界面 | 行为 |
|---|---|
| **gateway** | 没窗口就返回 `nothing_to_do`（用户在 Telegram 里发 `/compress`，不该等 10 秒然后告诉他"其实什么都没做"） |
| **CLI/TUI/ACP** | 照跑。因为 Phase 1 的剪枝和 blank-echo drop **仍然有收益**，而且 codex 原生压实可能生效 |

**④ tail 的行 id 处理（最精细的一段）**

```python
# An in-place commit archives every durable row under the lease watermark, the kept tail's included,
# so it must store the tail again itself. It gets copies because the insert writes row ids onto them.
# A copy keeps its source's row id only while the source is unchanged since it was loaded (marker
# present): a resume merge rewrote the row and dropped the marker, and its id no longer bounds what
# the row holds.
tail_rows = []
for m in tail:
    row = _fresh_compaction_message_copy(m)
    if not m.get(_DB_PERSISTED_MARKER):
        # A rewritten row's id does not bound the archive, but it and any row a merge
        # folded into it were still in the compressor's input. Keep them named so the
        # commit archives those originals instead of cloning them beside the tail.
        dropped = row.pop("_row_id", None)
        if isinstance(dropped, int) and not isinstance(dropped, bool) and dropped > 0:
            absorbed = [*(row.get("_absorbed_row_ids") or ())]
            if dropped not in absorbed:
                absorbed.append(dropped)
            row["_absorbed_row_ids"] = absorbed
    tail_rows.append(row)
```

背景（结合 07 篇）：

- 原地压缩会**归档 watermark 以下的所有行**，包括"被保留的 tail"
- 所以 tail 必须**重新插入**（否则它被归档了就丢了）
- 插入会写新的 row id 到 dict 上 → 所以必须用**副本**

`_DB_PERSISTED_MARKER` 是"这行确实来自 DB 且未被改写"的证明：

| 情况 | marker | 处理 |
|---|---|---|
| 从 DB 加载后未变 | 有 | 保留 `_row_id` → 归档时按 id 找到原行 |
| resume merge 重写过 | 无 | 把 `_row_id` 挪进 `_absorbed_row_ids` → 归档时仍能找到它 |

第二条是通过 `_absorbed_row_ids` 表达"这一行吸收了哪些历史行"。这样归档时
"原来那些行"会被正确处理（归档而不是克隆）。

**⑤ lock-skip 的类型钉住**

```python
# Type-pinned (is True / str): bare truthiness is fooled by MagicMock auto-attributes on test doubles.
lock_signal = getattr(agent, "_compression_skipped_due_to_lock", None)
if lock_signal is True or isinstance(lock_signal, str):
```

如果用 `if lock_signal:`，一个 `MagicMock` 的自动属性会返回一个 truthy 的 Mock →
误判成"锁被跳过"。

**教训**：从"可能不存在的对象"读标志时，用**类型判断**而不是真值判断。

**⑥ 未打戳就重新拼 tail**

```python
# Stamped copies mean the commit (in place or rotated) stored the tail and already returned head + tail.
# A no-op or a rolled-back commit leaves them unstamped, and the tail is then only in the caller's dicts.
if tail and not all(row.get(_DB_PERSISTED_MARKER) is True for row in tail_rows):
    compressed = rejoin_compressed_head_and_tail(compressed, tail)
```

三种结果：

| 结果 | tail 是否已落盘 | 需要 rejoin |
|---|---|---|
| 提交成功（原地/rotation） | 是（打戳） | 否 |
| no-op | 否 | **是** |
| 提交回滚 | 否 | **是** |

**⑦ `snapshot_is_current` 回调**

```python
"""``snapshot_is_current`` validates the host's snapshot after durable lease admission, before the
summarizer runs; the normal timeout/fallback pipeline remains in charge of the attempt."""
```

时序很关键：

```text
获取租约（可能等 600 秒）
  ↓
检查 snapshot 是否还是当前的   ← 这里
  ↓
调摘要 LLM（30-60 秒）
  ↓
提交
```

如果在拿到租约后发现"我的历史快照已经过期了"（比如另一个进程写了新消息），
就立刻放弃，而不是花 60 秒生成一个基于旧数据的摘要。

---

## §10 与血缘、持久化的交界

### 10.1 压缩如何写入数据库

详细机制在 [`07-state-and-session.md`](07-state-and-session.md) §7/§8。这里给出**压缩视角的摘要**：

```text
compress()            纯计算，返回新的 messages 列表
   ↓
宿主（_compress_context）
   ↓
获取 lease（session_turn_leases）
   ↓
archive_and_compact()：
   ├─ 旧行 → active=0（+ projection='compacted'）
   ├─ 新行 → active=1
   └─ 同一事务
   ↓
释放 lease
```

两种提交方式：

| 方式 | session id | 适用 |
|---|---|---|
| **原地（in-place）** | **不变** | 默认。保持单一稳定 id |
| **rotation（拆新会话）** | 新建子会话 | 需要独立血缘时 |

`agent/AGENTS.md` 明确：

> In-place compaction keeps a single stable session id.

**为什么默认原地**：会话 id 变了意味着用户要"切到新会话"，所有引用（bookmark、
外部链接、cron 绑定）都失效。原地压缩对用户不可见。

### 10.2 双投影：`active/compacted`

```text
messages 表
├─ session_id = 'abc'  AND active = 1              → 模型看到的
├─ session_id = 'abc'  AND active = 0              → 历史（被压掉了）
└─ session_id = 'abc'  AND active = 1, display_*   → UI 看到的
```

**关键**：压缩**不删数据**。旧行还在，只是 `active=0`。

这带来三个能力：

1. **UI 能看到完整历史**（`display_*` 投影）
2. **可以事后审计**（为什么模型忘了那件事？去看被归档的行）
3. **可以恢复**（`/rewind`）

### 10.3 `display_*` 三列的作用

「被压缩掉的工具输出」在 UI 上应该显示什么？

- 显示原文？太吵（20KB 的文件内容）
- 显示"已压缩"？信息太少

所以有 `display_content` / `display_kind` / `display_metadata` 三列。
工具重试场景下写 `display_metadata` 保留细节，同时 `announced` 一次性告知用户。

这是第 5 个"不破坏缓存地传信息"的范式（前四个见 04/05 篇）。

### 10.4 压缩产生的血缘标记

`model_config` 里有三个标记（详 07 篇 §7）：

| 标记 | 含义 |
|---|---|
| `_branched_from` | `/branch` 产生 |
| `_reset_from` | `/new` 产生 |
| `_delegate_from` | 子代理产生 |

压缩本身**不加**这些标记（它是原地操作）。但如果压缩**rotation** 了，
新会话会有 `parent_session_id` + 父行 `end_reason='compression'`。

### 10.5 压缩与会话恢复

```python
# agent/hermes_state_messages.py:1677
def _resume_lineage_ids(...)
```

resume 时的血缘重建（VERIFIED 血缘，#114271）必须理解"哪一段是压缩后的"。
否则会出现"resume 后模型看到的是压缩前的 transcript"或"看到两代内容拼接"。

### 10.6 压缩与 `_system_prompts` 内容寻址

07 篇讲过：`system_prompts(hash, prompt)` 表让 `sessions.system_prompt_hash`
和 `session.model_config.tool_names` 能引用同一份 prompt 内容。

压缩**不改 system prompt**（除了追加 `_COMPRESSION_NOTE`）。

**但 `_COMPRESSION_NOTE` 确实改了 system prompt 的字节！**

这是一个需要仔细理解的例外：

```python
for i in range(compress_start):
    msg = _fresh_compaction_message_copy(messages[i])
    if i == 0 and msg.get("role") == "system":
        if self._COMPRESSION_NOTE not in _content_text_for_contains(existing):
            msg["content"] = _append_text_to_content(existing, sep + self._COMPRESSION_NOTE)
```

- 它在 `messages[0]`（对话里的第一条 system）上追加，**不是** `_cached_system_prompt`
- 它**只加一次**（幂等检查）
- 而且这个 `messages[0]` 本来就是 messages 的一员，不是 API 的 `system` 参数

所以严格说：`_cached_system_prompt` 没变（API 的 `system` 字段没变），
但 messages 数组变长了。缓存本来就因为压缩失效了，所以无所谓。

**为什么不在 `_cached_system_prompt` 上加**：那会违反"每会话构建一次"的铁律，
而且 compression 可能发生多次，每次加一段就重复了。

---

## §11 Curator：技能生命周期

Curator 不是压缩，但它同在 `agent/` 下且"后台维护"语义相近，容易被混。

### 11.1 它做什么

```python
"""Curator — background skill maintenance orchestrator.

Inactivity-triggered (no cron daemon): when the agent is idle and the last run is older than
``interval_hours``, ``maybe_run_curator()`` auto-transitions lifecycle states from activity
timestamps, optionally forks an AIAgent that may pin/archive/consolidate/patch skills via
skill_manage, and persists scheduler state in ``.curator_state``.

Invariants: only curator-managed skills are touched; never delete, only archive (recoverable);
pinned skills bypass all auto-transitions; the fork uses the auxiliary client and never touches
the main session's prompt cache.
"""
```

三条不变量，逐条解释：

**① only curator-managed skills are touched**

```python
# 由 skill_manage 写入的显式标记 created_by: agent
# 绝不从"它在哪个目录"推断
```

为什么不按目录推断：用户手写的技能和 agent 创建的技术上可以放一起。
按位置推断会误伤用户的文件。

**② never delete, only archive**

归档到 `~/.hermes/skills/.archive/`，可以 `restore`。
「永不删除」是几乎所有自动清理系统的正确默认——
你不知道用户在哪个 git 仓库里引用了这个文件。

**③ the fork uses the auxiliary client and never touches the main session's prompt cache**

```python
# 如果要跑 LLM（consolidate），fork 一个独立 AIAgent
# 它用 auxiliary 路由（便宜的模型）
# 它不碰主会话的 messages → 主会话缓存不受影响
```

这是缓存铁律的又一次体现：**任何后台 LLM 工作都不能进主会话的上下文**。

### 11.2 时间参数

```python
DEFAULT_INTERVAL_HOURS, DEFAULT_MIN_IDLE_HOURS = 24 * 7, 2   # 7 天 / 2 小时
DEFAULT_STALE_AFTER_DAYS, DEFAULT_ARCHIVE_AFTER_DAYS = 14, 30
DEFAULT_CONSOLIDATE = False
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `interval_hours` | 168（7 天） | 多久跑一次 |
| `min_idle_hours` | 2 | agent 空闲多久才跑 |
| `stale_after_days` | 14 | 多少天没用 → `stale` |
| `archive_after_days` | 30 | 多少天没用 → `archived` |
| `consolidate` | false | 是否让 LLM 合并/改写技能 |

状态机：

```text
active ──14 天未用──► stale ──30 天未用──► archived（移到 .archive/）
   ▲                    │                      │
   └────────────────────┴──────────────────────┘
        pinned 豁免一切；被使用则回到 active
```

### 11.3 遥测侧车

```python
"""Skill usage telemetry + provenance for the Curator: a sidecar ``~/.hermes/skills/.usage.json``
keyed by skill name (never frontmatter — keeps telemetry out of user-authored SKILL.md and off
bundled/hub skills).

Counter bumps are best-effort (DEBUG-logged failures never break the tool call); writes are atomic
under a cross-process lock.
"""
```

三个设计决策：

| 决策 | 理由 |
|---|---|
| **不进 frontmatter** | 用户的 SKILL.md 不该被机器改脏 |
| **best-effort 自增** | 遥测失败绝不能导致 skill 调用失败 |
| **跨进程锁 + 原子写** | 多个 Hermes 进程（多 profile）可能同时写 |

### 11.4 CLI 与备份

```
hermes curator status | run | pause | resume
hermes curator pin | unpin
hermes curator archive | restore | prune
hermes curator backup | rollback
```

`curator_backup.py` 提供备份/回滚。
「归档可恢复」+「有回滚」= 双保险。

---

## §12 自检题

### 前置概念

1. 为什么 LLM 每次请求都要重发整个 messages 数组？这带来哪两个直接后果？
2. prompt caching 的匹配粒度是什么？为什么改动中间一条消息会让后面全部失效？
3. 「记忆」「上下文引擎」「压缩」各解决什么问题？各自的输入输出是什么？
4. 用户看到的对话历史和模型看到的 messages，为什么故意不一致？
5. Hermes 的缓存铁律是什么？唯一的例外是什么？

### 记忆

6. 内置 memory store 和外部 provider 的存储位置、写入方式、读取方式各有什么不同？
7. 为什么最多只能有一个外部 memory provider？这与「core 是窄腰」有什么关系？
8. `prefetch()` 为什么必须快？stale-while-revalidate 在这里怎么体现？
9. `system_prompt_block()` 为什么必须是 STATIC 的？如果它随状态变化会怎样？
10. `ctx_bound` / `spawn_context_thread` 解决什么问题？普通 `threading.Thread` 在 profile 隔离下会发生什么（两种后果）？
11. `CORE_MEMORY_PROVIDER_SENTINELS` 为什么包含 5 种写法？为什么内置 store 不能当插件查找？
12. memory provider 发现为什么是 bundled-first 而通用插件是 later-wins？
13. 发现 provider 时为什么先看 8KB 文本再回退 AST，而不直接 import？
14. `on_pre_compress` 的两个抢救通道是什么？
15. v1 和 v2 checkpoint 契约的差别？`require_checkpoint=True` 时失败会怎样？
16. `_accepts_require_checkpoint` 防的是什么 bug？如果不做签名探测会怎样？
17. `_EXTERNAL_PREFETCH_TIMEOUT_S = 8.0` 和 `_SYNC_DRAIN_TIMEOUT_S = 5.0` 分别保护什么？超时后会发生什么？
18. 为什么 `external_prefetch_timeout <= 0` 要抛错而不是禁用？
19. `sanitize_memory_context` 的三个细节（force / url credentials / elide_middle）各防什么？
20. 为什么 `MEMORY_CONTEXT_MAX_CHARS = 6000` 而头尾只占 5500？

### 上下文引擎

21. `ContextEngine` 的六个 token 字段为什么是公开属性而不是方法？代价是什么？
22. `should_compress_info()` 为什么要返回 reason？三种 reason 各代表什么状态？
23. `prune_tool_results_only()` 解决什么场景？为什么它独立于 `should_compress()`？
24. `proactive_prune_min_reclaim_tokens = 4096` 的含义是什么？
25. `select_context()` 的「request-only」约束为什么重要？
26. 为什么插件上下文引擎永不自动激活？
27. 三个 status phase（turn_start / pre_api / idle）分别在哪里触发？
28. `emit_automatic_compaction_status = False` 时什么仍会显示？

### 双层压缩

29. 网关卫生和 agent 压缩器的默认阈值分别是多少？为什么网关更高？
30. 网关的 token 来源三级优先是什么？为什么粗估偏高是"安全"的？为什么不用乘数补偿？
31. `hard_msg_limit = 5000` 解决什么死循环？
32. 网关压缩冷却为什么必须持久化到 DB？（#74136）
33. "已有压缩在进行中"为什么要跳过？（600 秒租约 + fence 拒绝）
34. agent 侧的四个触发点分别是什么？

### compress() 全流程

35. `_raise_if_stale_attempt` 解决什么并发问题？为什么要在入口、Phase 3 前、LLM 调用后各检查一次？
36. `canonical_messages` 和 `messages` 为什么要分成两份？
37. Phase 1 的三个 pass 各做什么？
38. 为什么 tool_call 的 arguments 永不改写？
39. 三样不能被剪的东西是什么？各自理由？
40. `_PRUNE_MIN_CHARS = 200` 与 clarify 的答案上限为什么必须严格小于它？
41. `TAIL_MAX_CONTEXT_FRACTION = 0.20` 是从什么真实故障里得出的？floor 为什么必须叠 fraction？
42. lean 模式（默认）的 tail 预算公式是什么？legacy 呢？
43. Phase 2 的 role 碰撞修正解决什么问题？
44. 为什么 lean 的 tail demote 要在生成摘要**之前**做？
45. `_fallback_streak_skip` 的 bench / probe 机制怎么运作？为什么 deadline 要持久化？
46. `_feasibility_skip` 的两个条件是什么？为什么说它"只读不写"？
47. `_SUMMARY_ROUTE_PIN` 为什么必须是 ContextVar 而不是 compressor 属性？两个理由。
48. `_apply_summary_route` 里"省略 model 不等于用默认值"是怎么回事？（#123362）
49. 迭代摘要（`_previous_summary`）的好处和风险各是什么？
50. Ghost-skill 防御为什么要"确定性收集 + 确定性重注入"？emit/check 用同一函数的原因？
51. `_SUMMARY_INPUT_MAX_CHARS = 160_000` 管输入，而"NEVER add max_tokens"管输出，各自的理由是什么？
52. 三种必须 terminal 的失败是什么？为什么截断必须 terminal（"compounding the loss"）？
53. `_SUMMARY_END_MARKER` 防的是哪两种弱模型行为？
54. `_COMPRESSION_NOTE` 的三段语义是什么？为什么它不改 `_cached_system_prompt`？
55. `_reappend_inflight_user_task` 解决什么 cron 场景？
56. 为什么"节省率"必须同口径比较？用 current_tokens 比会算出多少？
57. `trim_memory` 为什么在压缩后调用？三个保护是什么？
58. batch 压缩后为什么必须重置 micro 状态？

### 阈值数学

59. `_compute_threshold_tokens` 的 5 个步骤各做什么？
60. 64K 窗口 + 50% 阈值，如果不做 floor 修复会发生什么？（#14690）
61. 8K 窗口的最终触发点是多少？算一遍。
62. `_effective_threshold_percent` 为什么"只能升不能降"？
63. 小窗口为什么应该用更高的百分比？用 8K 窗口算一下 50% vs 75% 的差别。
64. `_config_threshold_percent` 为什么要单独保存？
65. `model_thresholds` 的匹配规则是什么？

### usage anchor

66. 为什么需要 anchor，而不是直接用 provider 报的 token 或直接估算？
67. anchor 的六个字段各是什么作用？
68. 为什么用内容指纹而不是行号或 `id()`？
69. `_FINGERPRINT_KEYS` 为什么是这五个？为什么排除 timestamp / row id / display_kind？
70. `base_prefix_fp` 防的是什么误判？如果只检查最后一条会怎样？
71. anchor 保存到哪里？三个需要持久化的场景。
72. 恢复时"匹配不上就删"而不是"匹配不上就不用"，为什么？
73. 五个清除 anchor 的事件。
74. `should_defer_preflight_to_real_usage` 的三个例外各是什么？
75. 为什么"等一个请求"比"立刻压缩"更划算？算一下代价对比。

### 失败模式

76. 七种失败分类分别怎么处理？哪些 terminal？
77. 为什么超时走阶梯冷却（60/300/900）而不是固定值？
78. 为什么超时和截断要用**不同的计数器**？
79. 确定性 fallback（`DETERMINISTIC_SUMMARY_ROUTE`）什么时候触发？为什么它比"继续重试"好？
80. 抗抖动的判据是什么？为什么"有效性"要由 provider 下一次上报裁决？
81. 熔断为什么不阻断 fallback 摘要，却要 bench 摘要模型？
82. 抗抖动为什么必须有 300 秒恢复机制？
83. `abort_on_summary_failure` 的适用人群？
84. abort 时为什么必须回滚 `_previous_summary`？为什么只有 owner 能回滚？
85. 过载升级（#123167）的推理链是什么？"bounded middle-window loss becomes a total session wipe" 说的是什么？
86. 为什么过载 streak 必须持久化？
87. idle 预算和 total ceiling 分别解决什么？单用其中一个会怎样？
88. 超时为什么也要 `_touch_activity`？

### 三条旁路

89. 原生压实为什么"故意窄"？只对哪些路由开启？
90. 原生阈值为什么必须低于本地触发点？
91. `checkpoint_required` 与原生压实为什么冲突？
92. micro-compaction 默认关闭的理由是什么？
93. micro 的交换边界三条约束是什么？
94. micro 有 max_tokens 而 batch 没有，为什么？
95. `_flush_scan_cursor_invalidated` 这个标志防的是什么？两种解法（打破身份 / 失效标志）各适用什么场景？
96. 手动的 `--aggressive` 为什么被拒绝？拒绝而不是忽略的理由（"mis-parsed as a focus topic"）？
97. `estimate_request_tokens` 与 `estimate_messages_tokens` 的差别？#6217 描述的"越压越多"是怎么回事？
98. `skip_without_window` 为什么只给 gateway？
99. lock-skip 的检测为什么要 `is True or isinstance(str)` 而不是真值判断？
100. `snapshot_is_current` 的检查时序为什么在"取租约之后、调 LLM 之前"？
101. tail 的 `_DB_PERSISTED_MARKER` 与 `_absorbed_row_ids` 分别表达什么？

### 交界与 Curator

102. 原地压缩和 rotation 对 session id 的影响？为什么默认原地？
103. 压缩为什么"不删数据"？三个由此带来的能力。
104. 压缩 rotation 时产生什么血缘标记？
105. Curator 的三条不变量。
106. 为什么 curator 不能按目录推断"这是 agent 创建的技能"？
107. curator 的 LLM 工作为什么不能进主会话？
108. `.usage.json` 为什么不写进 frontmatter？为什么自增要 best-effort？

---

## §13 小结与下一步

### 六条核心结论

1. **三个子系统，三层职责**。记忆是内容层（跨会话、进 system prompt、会话内冻结）；
   上下文引擎是策略层（何时压、怎么压、追踪 token，可插件化但永不自动激活）；
   压缩是执行层（改写 messages，是**唯一**被批准的缓存破坏点）。

2. **压缩的算法是四段流水线，不是"调个 LLM 总结一下"**。
   Phase 1 先做不花 LLM 的剪枝（必然有收益），Phase 2 按 token 预算选边界（保护 head 和 tail），
   Phase 3 才调摘要模型（迭代更新，失败有多级降级），Phase 4 拼装 + 七项收尾清理。
   每一段都可以独立失败并优雅退化。

3. **阈值不是一个百分比，是一套带三重保护的公式**。
   `(window - max_tokens) × pct`，下限 64K，floor 绑定时压到 85%，小窗口再抬到至少 75%，
   百分比 >= 100% 时退回 85%。每个修正都对应一个真实的"会话卡死"故障。

4. **token 计量必须建立在 provider 证据之上**。
   usage anchor = 真实计数 + 内容指纹绑定的位置 + 增量估算。
   没有 anchor 时**等一个请求**，而不是用偏高 30-50% 的估算去误触发压缩。

5. **失败处理的核心是"分维度、分梯度、可恢复"**。
   五类失败各有策略（terminal / abort / fallback / bench）；
   时间维度有 60/300/900 阶梯；语义维度有"3 次过载后降级"；
   所有熔断都有探测恢复点。**宁可降级，也不让会话卡死；但绝不接受会放大损失的降级**（截断的摘要）。

6. **压缩是纯计算，提交是宿主的事**。
   `compress()` 不知道数据库、不碰租约，只做 messages → messages。
   归档、lease、fence、血缘全在宿主侧。这让压缩可测试、可 `--preview`、可重放，
   也让"绝不在 lease/fence 之外提交剪枝"这条不变量有地方落地。

### 一句话给别人讲明白

> Hermes 的上下文管理是三层保险：网关在 85% 兜底（怕隔夜积压），
> agent 在 50% 常规管理（有真实 token、能更早更聪明），provider 溢出是最后一层。
> 压缩本身分四步：先免费剪枝、再按 token 预算选边界、再调便宜的辅助模型写迭代摘要、
> 最后清理孤儿消息和图片。它之所以复杂，是因为它是**唯一**允许破坏 prompt 缓存的地方——
> 所以每一次触发都要克制（有 anchor 才动手、估算偏高要等证据）、
> 每一次失败都要有刹车（阶梯冷却、熔断、bench、确定性 fallback），
> 但同时又绝不能因为过度保守而让会话永久卡死。

### 下一步

→ [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md)：消息网关与 ~20 个平台适配器的完整机制，
包括本章提到的 Session Hygiene 在网关侧的完整位置、消息守卫、流式输出与 token 锁。
