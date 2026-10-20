# 09 · 消息网关与多平台适配

> 目标：把"网关"这个长驻进程从头到尾讲清楚——它为什么存在、一条消息从进来到出去经过什么、
> 为什么会有两个消息守卫、流式交付的四条铁律从哪来、以及网关最深的那口井：
> **一个进程服务多个 profile 时的身份与作用域问题**。
>
> 读完之后你应该能：给一个没接触过这个项目的人画出网关的数据流图，解释任何一条"网关 bug"
> 大概率落在哪一层，以及知道新增一个平台要改哪几个文件。

---

## 目录

- [§0 前置概念：为什么会有"网关"这种东西](#0-前置概念为什么会有网关这种东西)
- [§1 网关是什么：职责聚合与代码形状](#1-网关是什么职责聚合与代码形状)
- [§2 启动与装配](#2-启动与装配)
- [§3 入站路径全链路](#3-入站路径全链路)
- [§4 双消息守卫（本篇第一个必须记住的东西）](#4-双消息守卫本篇第一个必须记住的东西)
- [§5 流式交付契约](#5-流式交付契约)
- [§6 出站、交付队列与投递台账](#6-出站交付队列与投递台账)
- [§7 后台进程通知](#7-后台进程通知)
- [§8 生命周期 vs 桌面应用](#8-生命周期-vs-桌面应用)
- [§9 Profile 作用域（网关最深的部分）](#9-profile-作用域网关最深的部分)
- [§10 `/login`](#10-login)
- [§11 平台目录](#11-平台目录)
- [§12 Slash 命令在网关](#12-slash-命令在网关)
- [§13 测试约定](#13-测试约定)
- [§14 自检题](#14-自检题)
- [§15 小结与下一步](#15-小结与下一步)

---

## §0 前置概念：为什么会有"网关"这种东西

### 0.1 CLI 是一次调用，网关是长驻服务

前面几篇讲的都是"一次对话"。

```
hermes "帮我看看这个 bug"
  └─ 进程启动 → 读配置 → 建 AIAgent → 调一次 API → 打印 → 进程退出
```

这个模型有几个隐含前提：

- **有人在终端前面按回车**（有输入触发）
- **进程活着的时候用户在等**（同步）
- **输出写到哪里很清楚**（stdout）

消息网关把这三条全部推翻：

| 前提 | 网关的现实 |
|---|---|
| 有终端 | 没有终端。输入来自 Telegram 的 webhook / Discord 的 websocket |
| 用户等着 | 用户可能 3 小时才回一句；进程必须一直在 |
| 输出到 stdout | 输出必须发回某个具体聊天窗口 |

所以网关的形态注定是**一个长时间运行的守护进程**，它：

1. 同时维护 N 条到各平台的连接
2. 每条连接上收到消息 → 找到该消息属于哪个"会话" → 跑一次 agent → 把结果发回去
3. 中间还要处理"用户连发三条""用户发 /stop""用户点按钮""定时任务到点了"

### 0.2 为什么不能"每个平台写一个 agent"

假设你给 Telegram 写一个 bot，给 Discord 写一个 bot。最直接的写法是：

```python
# telegram_bot.py（假想的错误做法）
agent = AIAgent(...)
reply = agent.run(user_text)
bot.send_message(chat_id, reply)
```

这会在三个地方立刻爆炸：

**第一，会话状态在内存里。** `AIAgent` 持有 `messages` 列表。你在 Telegram 进程里
建的 agent，Discord 进程完全看不到。用户在两个平台上是两个人——这看起来还行，
但如果用户同时在 Telegram 私聊和群聊里说话呢？如果网关重启了呢？

**第二，配置、密钥、记忆、技能要读好几遍。** 每个进程各自读 `config.yaml`、
各自 `.env`、各自初始化记忆 provider、各自扫描 skills 目录。同一个机器上跑两份 = 两份内存、
两份 8 秒的记忆 prefetch、两份 MCP 连接。

**第三，平台差异会污染核心。** Telegram 消息上限 4096 字符、Discord 2000、
Slack 用 Block Kit、Signal 几乎纯文本。如果 agent 核心要管这些，核心就没有边界了。

所以架构上的答案是 **窄腰**：

```
        Telegram   Discord   Slack   WhatsApp   Email   IRC   ...（20+）
            \         |        |        |        |      /
             \        |        |        |        |     /
              ┌───────▼────────▼────────▼────────▼─────┐
              │       平台适配器（adapter）             │  ← 平台知识全在这里
              └───────────────────┬────────────────────┘
                                  │ 统一的事件对象 MessageEvent
              ┌───────────────────▼────────────────────┐
              │        GatewayRunner（路由 + 守卫）     │
              └───────────────────┬────────────────────┘
                                  │ 一个 session_key
              ┌───────────────────▼────────────────────┐
              │      AIAgent 核心（与 CLI 完全同一份）   │
              └────────────────────────────────────────┘
```

**关键点**：`AIAgent` 那一层完全不知道 Telegram 的存在。它只知道"收到了用户文本，
我该调模型、调工具、返回文本"。平台差异被 `BasePlatformAdapter` 子类吸收掉。

这就是 AGENTS.md 里说的"核心是窄腰，能力在边缘"。

### 0.3 消息平台和终端不一样在哪里

这是初学者最容易踩的坑：**把消息平台当终端用**。

| 差异 | 终端 | 消息平台 | 后果 |
|---|---|---|---|
| 能不能"更新"已发出的内容 | 能（重绘） | 大多不能，只能发新消息或 edit | 流式输出要设计"草稿"机制 |
| 消息大小上限 | 无限 | 2000~4096 字符 | 长回复必须切分 |
| 速率限制 | 无 | 有的很严（Slack stream API ~20/min） | 不能每 100ms 发一帧 |
| 送达确认 | 无 | 有但不可靠（超时 ≠ 没送到） | 重发可能导致重复 |
| 消息顺序 | 天然有序 | 异步、可能乱序 | 需要 id 对账 |
| 是否有"线程/话题" | 无 | 有（Slack thread、Telegram topic） | session_key 要多一维 |
| 是否有多人 | 无 | 群聊 | 需要区分"谁在说话" |
| 用户身份 | 就是你自己 | 可能是陌生人 | 必须做授权 |

后面几节讲的所有设计，几乎都是这八个差异的直接后果。

### 0.4 本篇会反复出现的四个词

先给一句话版本，后面遇到再展开：

1. **adapter（适配器）**：一个平台一个类，负责"平台 API ↔ 统一 `MessageEvent`"的双向翻译。
2. **session_key（会话键）**：一个字符串，唯一标识"这段对话"。同一个 key 复用同一个 agent。
3. **guard（守卫）**：防止同一会话同时跑两个 agent 的锁。
4. **profile（档位）**：一套独立的配置/密钥/记忆/会话库。一个网关进程可以服务多个 profile。

---

## §1 网关是什么：职责聚合与代码形状

### 1.1 职责清单

网关做了这些事（顺序大致就是启动顺序）：

| 职责 | 代码位置 |
|---|---|
| 读配置（**原始 YAML**，不走 `DEFAULT_CONFIG`） | [`gateway/config.py`](../gateway/config.py:1) |
| 装配适配器（插件优先，内置兜底） | [`gateway/run_adapters.py`](../gateway/run_adapters.py:1) |
| 连接各平台 + 重连看护 | `run_adapters.py` + `run_watchers.py` |
| 入站事件准入（授权、忽略频道、插件钩子） | [`gateway/run_inbound.py`](../gateway/run_inbound.py:1) |
| 会话身份解析（哪个 bot 收的 / 谁可准入 / 在哪跑） | [`gateway/session_identity.py`](../gateway/session_identity.py:1) |
| 忙碌时的命令派发 | [`gateway/run_busy.py`](../gateway/run_busy.py:1) |
| turn 执行（含 session hygiene 压缩） | [`gateway/run_turn.py`](../gateway/run_turn.py:1) |
| 流式消费与最终交付对账 | [`gateway/stream_consumer.py`](../gateway/stream_consumer.py:1) |
| 后台进程完成通知 | [`gateway/run_notifications.py`](../gateway/run_notifications.py:1) |
| cron tick 与投递队列排空 | `run_idle_gates.py` + [`gateway/run_delivery_queue_watch.py`](../gateway/run_delivery_queue_watch.py:1) |
| 崩溃后恢复（未发出的回复） | [`gateway/delivery_ledger.py`](../gateway/delivery_ledger.py:1) |
| 状态发布（`gateway_state.json`） | [`gateway/status.py`](../gateway/status.py:1) |
| 优雅关闭（排空、通知、释放锁） | [`gateway/run_shutdown.py`](../gateway/run_shutdown.py:1) |

> **注意**：网关**不**负责 cron 任务本身的调度逻辑（那是 `cron/`，见 12 篇），
> 它只是**驱动 ticker**——每 N 秒调一次"该跑的跑一下"。

### 1.2 代码形状：facade + 30 个兄弟

[`gateway/run.py`](../gateway/run.py:1) 有 **6082 行**，是 `GatewayRunner` 类的主体。
但它不是全部——重活都被拆到了 `run_*.py` 兄弟里，通过 **MRO 混入**绑回 `GatewayRunner`。

完整清单（30 个）：

| 文件 | 行数 | 主题 |
|---|---|---|
| `run_adapters.py` | 1958 | 适配器实例化、连接、重连看护、多 profile 适配器、身份规范化 |
| `run_agent_cache.py` | 1113 | agent 实例缓存（LRU / 空闲 TTL / 内存压力驱逐） |
| `run_busy.py` | 1420 | 忙碌路径：命令分类、跨进程 active-session 槽位 |
| `run_common.py` | — | 共用小工具 |
| `run_config_loaders.py` | 577 | 各类配置读取（busy 模式、reasoning、超时、fallback） |
| `run_delivery_queue_watch.py` | 78 | cron 投递队列的文件戳监视 |
| `run_goals.py` | 512 | 目标（`/goal`）循环 |
| `run_heartbeat_acceptance.py` | — | 心跳接受 |
| `run_heartbeat_restore.py` | 79 | 重启后恢复心跳 |
| `run_idle_gates.py` | 66 | 空闲时该做什么（tick、排空） |
| `run_inbound.py` | 2046 | 入站全链路（准入 → 命令 → agent） |
| `run_inbound_consumer.py` | — | 准入后插件 consume 钩子 |
| `run_inbound_media.py` | — | 入站媒体（图/音频/视频）处理 |
| `run_inbound_unauthorized.py` | 113 | 未授权用户处理（配对码 / 拒绝） |
| `run_notifications.py` | 2061 | 后台进程 watcher + 通知注入 |
| `run_notifications_ownership.py` | 231 | 通知的归属判定 |
| `run_plugin_injection.py` | 244 | 插件注入 |
| `run_plugin_rewire.py` | 126 | 插件重载后重新接线 |
| `run_profile_reconcile.py` | 500 | 多 profile 适配器对账 |
| `run_shutdown.py` | 2265 | 关闭（排空、清理、释放锁） |
| `run_shutdown_session_end.py` | 64 | 会话结束收尾 |
| `run_startup.py` | 1879 | 启动序列（恢复、暖机、补偿投递） |
| `run_topics.py` | 644 | Telegram topic / 会话话题 |
| `run_turn.py` | 4368 | turn 执行主体（含 hygiene 压缩三级 token 来源） |
| `run_turn_followup_ack.py` | 60 | 后续消息的 ack |
| `run_turn_runner.py` | 2001 | `TurnRunner`（真正的执行循环） |
| `run_turn_runner_approval_settle.py` | 84 | 审批结果落地 |
| `run_turn_runner_clarify_delivery.py` | 184 | clarify 问题投递 |
| `run_voice.py` | 456 | 语音消息 |
| `run_watchers.py` | 248 | 各类后台看护任务 |

会话相关（不在 `run_*` 前缀里，但同属网关）：

| 文件 | 行数 | 主题 |
|---|---|---|
| `session.py` | 1352 | `SessionSource`、`SessionEntry`、`build_session_key()` |
| `session_identity.py` | 273 | `RoutingIdentity`（身份三问） |
| `session_transcript.py` | 682 | 会话记录读写 |
| `session_persistence.py` | 533 | 持久化 |
| `session_recovery.py` | 449 | 崩溃恢复 |
| `session_state.py` | 269 | 每会话可变状态 |
| `session_context.py` | 224 | `HERMES_SESSION_*` ContextVar |
| `session_lifecycle.py` | 251 | 生命周期 |
| `session_prompt_pin.py` | 81 | system prompt 钉住 |
| `session_stall.py` | 76 | 卡死检测 |
| `session_db_recovery.py` | 169 | 会话 DB 恢复 |

> **为什么拆这么碎？** 根 AGENTS.md 的 rachet 规则：文件 ≤ 2000 行、函数 ≤ 300 行、
> 圈复杂度 ≤ 20。已经超了的单元只能"往下走"（把函数搬到兄弟文件抵消增长），
> 不能"往上走"。所以你会看到 `run.py` 6082 行（存量，只能降）而 `run_idle_gates.py`
> 只有 66 行。

**找代码的正确姿势**：不要在 `run.py` 里翻，用

```bash
grep -rn "def _handle_message" gateway/run_*.py
```

### 1.3 一个容易踩的坑：网关读原始 YAML

AGENTS.md 里明写：

> 网关读用户 YAML **原始文件**（`run.py` + `config.py`），**不**经过 `DEFAULT_CONFIG`。

意思是：CLI 那边有一套"默认配置 + 用户覆盖"的合并逻辑，网关不用那套。
它是直接读 `config.yaml` 的原始内容，做自己的解析。

**症状**：你在 CLI 里测某个 key 生效，网关里却不生效（或反之）。

**原因**：你在两边用了不同的 loader。改配置读取逻辑时，先确认调用方是哪个。

---

## §2 启动与装配

### 2.1 启动序列（简化）

```
1. 解析启动 profile + HERMES_HOME
2. load_gateway_config_for_runner()
     ├─ load_gateway_config()          ← 探针：判断本进程是不是 multiplexer
     ├─ resolve_multiplex_mode()       ← 未设置时决定默认值（默认 on）
     └─ 若 multiplex：set_multiplex_active(True) 再在默认 root 的作用域下重新加载
3. 建设备注册表：对每个 enabled 平台实例化 adapter
     ├─ 插件注册表优先（platform_registry）
     └─ 内置兜底（_BUILTIN_ADAPTERS）
4. 连接各 adapter（connect()/start()），失败的进重连队列
5. 启动暖机（_startup_warmup）、恢复（_recover_unclean_sessions）
6. 补偿投递（_redeliver_pending_obligations）
7. 启动 idle ticker（cron tick + 交付队列排空）
8. 进入主循环，等信号
```

### 2.2 适配器注册表：插件优先，内置兜底

[`gateway/run_adapters.py:1886`](../gateway/run_adapters.py:1886)：

```python
def _instantiate_adapter(self, platform: Platform, config: Any):
    """Instantiate the adapter for a platform: plugin registry first, then built-ins."""
    from gateway.platform_registry import platform_registry
    if platform_registry.is_registered(platform.value):
        adapter = platform_registry.create_adapter(platform.value, config)
        if adapter is None:   # registered but failed — never fall through to built-ins
            logger.error(...)
        return adapter        # ← 注意：返回 None 也不再兜底
    return _instantiate_builtin_adapter(platform, config)
```

**关键语义**：注册了但创建失败 → **返回 None，不再兜底内置**。

为什么？因为"注册了"意味着这个平台名已经由插件接管。如果插件坏了就偷偷回退到内置实现，
你会得到一个**旧版本的、行为和插件完全不同的** adapter 在跑，而日志里只有一个 error。
静默降级比明确失败更难查。

内置表（[`gateway/run.py:3314`](../gateway/run.py:3314)）是 `{Platform: (module, class, requirement_check, warning)}`：

```python
_BUILTIN_ADAPTERS = {
    Platform.WHATSAPP_CLOUD: ("whatsapp_cloud", "WhatsAppCloudAdapter",
                              "check_whatsapp_cloud_requirements",
                              "WhatsApp Cloud: aiohttp/httpx missing — reinstall hermes-agent"),
    Platform.SIGNAL:  ("signal", "SignalAdapter", "check_signal_requirements", ...),
    Platform.WEIXIN:  ("weixin", "WeixinAdapter", ...),
    Platform.API_SERVER: ("api_server", "APIServerAdapter", ...),
    Platform.WEBHOOK: ("webhook", "WebhookAdapter", ...),
    Platform.MSGRAPH_WEBHOOK: ("msgraph_webhook", "MSGraphWebhookAdapter", ...),
    Platform.BLUEBUBBLES: ("bluebubbles", "BlueBubblesAdapter", ...),
    Platform.QQBOT: ("qqbot", "QQAdapter", ...),
    Platform.YUANBAO: ("yuanbao", "YuanbaoAdapter", "WEBSOCKETS_AVAILABLE", ...),
}
```

注意第四个元素是**给用户看的可执行提示**："装个 websockets"、"重新安装 hermes-agent"。
这是有意的设计：适配器起不来时，`hermes gateway status` 要能直接告诉用户怎么办，
而不是只写 `ImportError`。

### 2.3 每个平台一个基础 toolset

agent 拿到哪些工具不是全局固定的。网关按平台配置 `platform_toolsets`：

```yaml
platform_toolsets:
  cli: [terminal, files, ...]
  gui: [terminal, files, ...]
  telegram: [messaging, ...]     # ← Telegram 上不需要 terminal 之类
```

解析在 [`gateway/run_turn.py:2387`](../gateway/run_turn.py:2387)：

```python
def _resolve_enabled_toolsets_for_source(...):
    """Enabled toolsets for an agent run, honoring an adapter toolsets_for_source() override
    (a secondary profile's own admin list wins; everything outside the parent's bounds is
    dropped, not trusted)."""
```

三层优先级：

1. **adapter 的 `toolsets_for_source()` 覆盖**（次要 profile 自己的管理列表）——
   但会被**父级 bounds 裁剪**（"dropped, not trusted"：不能因为子 profile 写了
   `terminal` 就真的给它）
2. 用户配置的 `platform_toolsets[platform]`
3. 内建默认

> **为什么这条重要**：这是"能力在边缘"的具体实现。Telegram 上不给你 terminal 工具，
> 不是因为代码里 `if platform == telegram: remove("terminal")`，而是因为
> `platform_toolsets.telegram` 里没列它。

### 2.4 失败的可观测性：状态上报

每个 adapter 的连接状态都写进 `gateway_state.json`（[`gateway/status.py`](../gateway/status.py:1)），
key 形如 `<profile>:<platform>`，value 含 `platform_state`（connected / fatal / disabled）、
`error_code`、`error_message`。

这样 `hermes gateway status --profile X` 和 dashboard 都能显示"为什么这个频道是死的"。

**反例**（明确指出不允许的写法）：静默跳过。见 §9.7 的
`_note_unserved_secondary_platform`——一个平台没被服务时，**必须**留下一条状态记录，
哪怕是 `disabled`。

---

## §3 入站路径全链路

这是网关最核心的流程。一条用户消息从"平台 API 事件"变成"agent 的一次 turn"，
中间经过 **7 个阶段**。

### 3.1 全景图

```
① 平台 API 事件（webhook 回调 / websocket frame）
        │  适配器自己解析成 MessageEvent
        ▼
② BasePlatformAdapter.handle_message(event)              ← gateway/platforms/base.py:4038
        ├─ event._gateway_accepted = False               （回执清零）
        ├─ 无 handler？打一次 error 日志并丢弃            （#102260）
        ├─ allow_gateway_control → coerce_plaintext_gateway_command()
        ├─ _drop_unresolved(event)                       ← 身份解析失败则丢弃
        ├─ Telegram DM：_apply_topic_recovery()
        ├─ session_key = _event_session_key(event)
        ├─ 内部控制事件：derived key ≠ expected key → 丢弃
        ├─ _heal_stale_session_lock(session_key)         ← 守卫自愈
        ├─ session_key in _active_sessions?
        │     ├─ 是 → ③ _handle_message_while_active()   （守卫 1）
        │     └─ 否 → _start_session_processing()        （同步装守卫再 spawn）
        ▼
③ （异步任务）_handle_message(event)                     ← gateway/run_inbound.py:1285
        ├─ _hm_admit_event(event)                        ← 准入（7 道门）
        ├─ _hm_estop_gate()                              ← 全局急停
        ├─ _quick_key = _session_key_for_source(source)
        ├─ _hm_pending_reply_intercepts()                ← update/clarify/slash-confirm 回复
        ├─ _hm_evict_idle_stale_agent() / _hm_evict_reaped_agent()
        ├─ 正在跑？→ _hm_handle_running_session_message() （守卫 2）
        ├─ _hm_dispatch_idle_commands()                  ← idle 态 slash 命令
        ├─ _claim_active_session_slot()                  ← 跨进程槽位（max_concurrent_sessions）
        ├─ 记账：turn.agent = _AGENT_PENDING_SENTINEL
        ├─ _begin_session_run_generation()               ← 代际号
        ├─ run_post_admission_hook()                     ← 插件 consume
        ├─ _handle_message_with_agent()                  → ④
        └─ finally: 恢复 model override / 清 durable marker / 释放槽位与 lease
        ▼
④ _handle_message_with_agent(...)                        → TurnRunner
        ├─ get_or_create_session()                       ← 复用或新建 session_id
        ├─ 恢复/新建 AIAgent（缓存命中则复用）
        ├─ 装配 system prompt、记忆、工具
        ├─ 跑 turn（流式）
        └─ 交付最终结果（见 §5、§6）
        ▼
⑤ 流式消费 StreamConsumer（若平台支持）
        ▼
⑥ 最终发送 + 投递台账记账（delivery_ledger）
        ▼
⑦ 会话收尾（可能触发记忆提取、压缩、清理）
```

### 3.2 阶段②：`handle_message` 的细节

[`gateway/platforms/base.py:4038`](../gateway/platforms/base.py:4038)：

```python
async def handle_message(self, event: MessageEvent) -> None:
    """Process an incoming message; returns quickly by spawning a background
    task so new messages (and interrupts) can arrive while an agent runs."""
    event._gateway_accepted = False
    if not self._message_handler:
        ...
        return
```

两个要点：

**(a) `_gateway_accepted` 回执**。这是一个"守住"的布尔值，handler 返回 `None`
**不代表**事件被接受了。事件被接受必须有明确证据：`event._gateway_accepted = True`。

为什么需要它？见 §7：后台通知的注入要求"adapter 真的接收了"，否则调用方要重试。
如果只看"handler 没抛异常"就当作成功，一个"没找到 handler 所以直接 return"的路径
会被误判为投递成功 → 事件永久丢失。

**(b) 同步装守卫再 spawn**：

```python
# Guard installed synchronously BEFORE the task spawns so a second message can't race in.
event._gateway_accepted = self._start_session_processing(event, session_key)
```

这行注释很关键。如果写成：

```python
# 错误写法
asyncio.create_task(self._process(event, session_key))
```

那么在 `create_task` 和任务真正开始执行之间有一个窗口。第二条消息在这个窗口里到达，
看到 `_active_sessions` 里没有 key，就也会 spawn 一个任务 → **同一个会话两个 agent 并行**。
两个 agent 各自加载历史、各自写库、互相覆盖。

所以守卫必须**同步**装上（在 async 事件循环里，同步代码之间不会被打断）。

### 3.3 阶段③：`_hm_admit_event` 的七道门

[`gateway/run_inbound.py:167`](../gateway/run_inbound.py:167)：

```python
async def _hm_admit_event(self, event):
    """Ingress gates for ``_handle_message``; None when dropped, else
    ``(event, source, is_internal)``."""
```

准入顺序（顺序本身就是设计）：

| # | 门 | 作用 | 为什么在这个位置 |
|---|---|---|---|
| 0 | `reset_session_vars()` | 清掉 `HERMES_SESSION_*` ContextVar | 任务是用 `copy_context()` 创建的，可能带着**另一条消息**的身份 |
| 1 | `_canonicalize(source)` + `profile_route_rejected` 检查 | 身份解析；路由到未服务 profile 则丢弃 | **必须在派生任何 key 之前** |
| 2 | Slack 忽略频道 | 被屏蔽的频道绝不进入配对/授权/session 状态 | 要排在授权之前 |
| 3 | 启动恢复队列 | 启动尚未完成时不处理真实消息，先排队 | 否则会基于半初始化的状态跑 turn |
| 4 | 内部事件直接放行 | `is_internal=True`（后台通知）跳过后续用户门 | 内部事件没有"用户" |
| 5 | 用户授权 | 未授权 → 配对码 / 一次性拒绝 / 忽略 | 放在忽略频道之后（见 §3.4） |
| 6 | bot 循环防护 | 防止两个 bot 互相回复 | 最后一道 |

**门 0 的注释值得抄下来**：

```python
# 🔴 Cross-session leak guard: this per-message task was create_task()'d with a copy of the
# spawning context, which may carry ANOTHER message's HERMES_SESSION_* ContextVars; until
# _set_session_env binds ours a subprocess would read the foreign identity. Reset to _UNSET.
```

ContextVar 是"会跟着 `copy_context()` 走"的。适配器的事件循环处理消息 A 时设了
`HERMES_SESSION_ID=A`，然后 `create_task()` 处理消息 B，B 的上下文里就带着 A 的 session id。
如果 B 的 turn 在这之前 fork 了一个子进程（比如 terminal 工具），子进程会读到 A 的身份 →
**跨会话串台**。

**门 1 的严格布尔检查**：

```python
# Strict boolean marker: require the literal True so duck-typed test/internal sources with
# dynamic attributes are not mistaken for a rejection.
if getattr(source, "profile_route_rejected", False) is True:
```

用 `is True` 而不是 `if ...`：测试里的 `MagicMock` 任何属性都是 truthy，
`if getattr(source, "profile_route_rejected", False)` 会把 mock 当成"被拒绝"，
把所有测试全丢弃。

### 3.4 门 2 的顺序为什么重要

注释原文：

```python
# Ignored-channel guard runs FIRST — before startup-restore queueing, plugin hooks, auth,
# and session setup — so an ignored channel can never reach pairing/auth/session state.
```

假设顺序反了（先授权再查忽略频道）：一个被封频道里的陌生用户发消息 →
先触发配对流程 → 生成了一个配对码、写了配对状态、可能还给对方发了一条消息。
然后才被"忽略频道"拦住。结果是：**你封了频道，但配对系统里多了垃圾，而且你给被封频道发了消息**。

所以"最便宜的、最绝对的拒绝"要排最前面。

### 3.5 授权失败的分支

[`gateway/run_inbound.py:237`](../gateway/run_inbound.py:237)：

```python
if not self._is_user_authorized_for_source(source):
    if source.user_id is None:
        # No user identity (Telegram service messages, channel forwards, anonymous admin
        # posts, sender_chat): can't be paired but may be authorized via a chat allowlist.
        return None
    pairable_dm = source.chat_type == "dm" and not getattr(source, "is_bot", False)
    behavior = self._get_unauthorized_dm_behavior(source.platform, profile=source.profile) \
               if pairable_dm else None
    if behavior == "pair":
        await self._hm_offer_pairing_code(source)
    elif behavior == "decline":
        await self._hm_send_unauthorized_decline(source)
    elif pairable_dm:
        await self._hm_report_ignored_dm(source)
    else:
        logger.warning(...)
    return None
```

四条分支的语义：

| 情况 | 行为 | 理由 |
|---|---|---|
| 没有 `user_id` | 静默丢弃（debug 日志） | Telegram 服务消息、频道转发、匿名管理员——**配对不了**，但可能被 chat allowlist 放行过 |
| 可配对的 DM（非 bot） | 按 `behavior` 配置：`pair` 发配对码 / `decline` 发一次性拒绝 / 其他只记日志 | 私聊是唯一合理的配对入口 |
| 群聊里的陌生人 | 只记 warning，不回复 | 群聊回复会变成噪音 |
| 发消息的是 bot | 不配对 | "A bot cannot pair, and answering one mid-cooldown is outbound traffic"——回一个 bot 会产生出站流量，可能触发回环 |

### 3.6 阶段③剩余部分：为什么要有"代际号"

```python
_run_generation = self._begin_session_run_generation(_quick_key)
...
finally:
    self._release_running_agent_state(_quick_key, run_generation=_run_generation)
    self._release_turn_lease(_quick_key, _run_generation)
```

`run_generation` 是一个递增整数，每开始一个 turn 就 +1。

**要解决的问题**：turn N 被 `/stop` 或驱逐了，它的 `finally` 还在排队执行。
如果此时 turn N+1 已经启动并注册了新的 agent 状态，那么 N 的 `finally` 执行
`_release_running_agent_state(_quick_key)` 会把 **N+1 的状态清掉**。

注释写得很清楚：

```python
# Release only this turn's generation. Eviction may immediately admit a replacement
# through the cold path; an unconditional release here would then clear the replacement
# sentinel/agent and lease. Reset/stop release their stale slot before installing a
# successor, preserving reset-zombie cleanup without granting gen-N successor authority.
```

这是典型的 **ABA 问题**：用"代际号 / epoch"给每个操作打上"我是第几代"的戳，
释放时只释放自己那一代。

同样的代际保护也用在：
- `_restore_pending_one_turn_model_override`（`/model --once` 的恢复）
- `_release_turn_lease`（turn 租约按 `(routing key, run generation)` 做 key）
- agent 缓存驱逐（"entries from generations OLDER than the current one"）

### 3.7 `_AGENT_PENDING_SENTINEL`

```python
# Claim this session before any await: many awaits sit between here and _run_agent
# registering the real AIAgent; without this sentinel a second message during any of them
# passes the "already running" guard and spins up a duplicate agent for the same session.
_claim_state.turn.agent = _AGENT_PENDING_SENTINEL
```

`_claim_state.turn.agent` 正常应该是一个 `AIAgent` 对象。但在这条消息的 turn 开始
到 agent 真正创建之间，有一串 `await`（读配置、载入会话、初始化记忆……）。

如果这期间第二条消息到达，它查 `turn.agent` 发现是 `None`（还没建），
判断"没在跑"，于是也启动一个 turn → 重复 agent。

`sentinel`（哨兵对象）的作用：**把"未开始"和"正在开始中"区分开**。
`None` = 空闲；`_AGENT_PENDING_SENTINEL` = 有人正在路上。

这个小技巧在并发代码里非常常见，值得记住。

---

## §4 双消息守卫（本篇第一个必须记住的东西）

[`gateway/AGENTS.md:20`](../gateway/AGENTS.md:20) 的说法是"两个顺序守卫"。
实际上它们拦的是**同一批命令**，但在**两个不同的层**，且**行为不同**。

### 4.1 守卫 1：适配器层的 `_active_sessions`

位置：[`gateway/platforms/base.py:1989`](../gateway/platforms/base.py:1989)

```python
self._active_sessions: dict[str, asyncio.Event] = {}
self._pending_messages: dict[str, MessageEvent] = {}
```

逻辑（`handle_message` 里）：

```python
if session_key in self._active_sessions:
    self._heal_stale_session_lock(session_key)     # ← 先自愈
if session_key in self._active_sessions:
    await self._handle_message_while_active(event, session_key)
    return
```

**自愈**（`_heal_stale_session_lock`）：如果守卫存在但拥有它的 task 已经结束（异常退出没清理），
就清掉守卫。没有自愈的话，一次异常会让这个会话**永久卡死**。

### 4.2 `_handle_message_while_active` 的三个分支

[`gateway/platforms/base.py:4080`](../gateway/platforms/base.py:4080)：

```
                   ┌─────────────────────────────┐
                   │ 消息到达，会话正忙           │
                   └──────────────┬──────────────┘
                                  ▼
              ┌───────────────────────────────────────┐
              │ ① 是可解析的 slash 命令？              │
              │    should_bypass_active_session(cmd)  │
              └───────────┬───────────────────────────┘
                    是    │    否
          ┌───────────────┴───────────────┐
          ▼                               ▼
┌──────────────────────┐    ┌──────────────────────────────┐
│ is_interrupt_then_    │    │ ② 没有命令 + 有 pending       │
│ dispatch(cmd)?        │    │    clarify 文本拦截？         │
│  /stop /new /reset    │    └───────────┬──────────────────┘
│  → _dispatch_active_  │          是    │    否
│    session_command()  │    ┌───────────┴──────────┐
│  其他 → _dispatch_    │    ▼                      ▼
│    inline_reply()     │  内联派发          ┌──────────────────┐
└──────────────────────┘  (clarify 答案)     │ ③ _busy_session_  │
                                              │   handler（runner │
                                              │   提供）          │
                                              └────────┬─────────┘
                                                       ▼
                                              ┌──────────────────┐
                                              │ ④ 图片：排队不打断│
                                              │ ⑤ 文本：debounce  │
                                              │    或合并入队     │
                                              └──────────────────┘
```

**分支①的核心注释（务必背下来）**：

```python
# Bypass commands run inline: queued they'd leak as user text (/new) or deadlock
# (/approve, /deny — the agent is blocked on Event.wait).  Dispatch inline by
# calling the message handler directly and sending the response.  Do NOT use
# _process_message_background — it manages session lifecycle and its cleanup
# races with the running task (split-brain, see PR #4926).
```

这里有两个独立的死法：

- **泄漏成用户文本**：`/new` 被排队成"下一条用户消息"，turn 结束后 agent 看到用户说了
  `/new`，把它当普通文本处理。
- **死锁**：`/approve` 到达时 agent 正阻塞在 `Event.wait()` 等审批结果。
  如果 `/approve` 进队列，要等 turn 结束才被处理；但 turn 结束的前提是审批被批准。
  **互等**。

**为什么不能用 `_process_message_background()`**：那个函数会管理会话生命周期
（装守卫、卸守卫、清理状态）。当前正有一个 turn 持有守卫，你再走一遍生命周期管理，
两边的清理逻辑会互相踩 → "split-brain"（PR #4926）。

### 4.3 `should_bypass_active_session` 的真实语义

这个函数名**严重低估**了它的作用范围。

[`hermes_cli/commands.py:488`](../hermes_cli/commands.py:488)：

```python
def should_bypass_active_session(command) -> bool:
    """..."""
```

它的实际行为是：**任何能在命令注册表里解析出来的命令都返回 True**。

不是"只有 `/stop` 这几个"，而是"所有合法命令"。

为什么？因为一条命令如果被排队等待，而当前 turn 因为任何原因（等待审批、等待用户输入、
长时间工具调用）迟迟不结束，这条命令就悬在半空。而网关的安全网会在某些情况下
**丢弃排队消息** → 用户收到零字符响应（#5057）。相关 issue 编号在注释里排成一串：
#5057 / #6252 / #10370 / #4665。

**所以**：`/status`、`/help`、`/model` 这些"只读"命令也是 mid-run 派发的。

### 4.4 `busy_policy` 三值

命令定义在 [`hermes_cli/commands.py:45`](../hermes_cli/commands.py:45) 的 `CommandDef`：

```python
@dataclass(frozen=True)
class CommandDef:
    name: str
    ...
    busy_policy: str = "reject"      # dispatch | reject | interrupt_then_dispatch
    busy_handler: ... = None
```

合法值集合在 [:80](../hermes_cli/commands.py:80)：

```python
VALID_BUSY_POLICIES = {"dispatch", "reject", "interrupt_then_dispatch"}
```

| 值 | 语义 | 谁用 |
|---|---|---|
| `dispatch` | 忙碌时仍派发，不打断当前 turn | 大多数只读/控制命令（`/status`、`/busy`、`/help`…） |
| `reject` | 忙碌时拒绝（提示"正在忙"） | 会改写会话的重命令 |
| `interrupt_then_dispatch` | **先取消当前 turn，再派发** | `/stop`、`/new`、`/reset` |

判定函数（[:482](../hermes_cli/commands.py:482)）：

```python
def is_interrupt_then_dispatch(command) -> bool:
    ...
```

这条路叫 **cancel-handoff**：取消 → 等待旧 turn 让出 → 派发新命令。

### 4.5 两张命令表

[`gateway/run_busy.py:910`](../gateway/run_busy.py:910)：

**`_PLAIN_COMMANDS`（22 个，mid-run 也能工作）**：

```
status  context  restart  approve  deny  pause  agents  bg  btw  kanban
subgoal  heartbeat  busy  yolo  verbose  footer  help  commands  profile
login  update  version
```

**`_IDLE_COMMANDS`（31 个，只在空闲时处理）**：

```
topic  whoami  platform  stop  reasoning  memory  skills  fast  approvals
model  codex-runtime  personality  suggestions  save  retry  sethome
compress  usage  topup  insights  reload-mcp  reload-skills  bundles
debug  title  resume  sessions  branch  rollback  diff  goal  loop
refine  review  voice
```

> **注意这两张表的语义和 `busy_policy` 不是一回事**：
> `_PLAIN_COMMANDS` / `_IDLE_COMMANDS` 是 **runner 侧**的分组（"这条命令处理时需不需要
> 会话空闲"）；`busy_policy` 是**命令定义侧**的声明（"忙的时候怎么办"）。
> 两者配合，但不要混为一谈。

处理表本身是**查表**，不是 if 链（[:924](../gateway/run_busy.py:924)）：

```python
_command_handler_table  # dict[str, handler]
_BUSY_SPECIAL_HANDLERS  # dict[str, handler]
```

### 4.6 守卫 2：runner 侧

守卫 1 处理"适配器层"，但有些事件**不是**从 `handle_message` 进来的：

- 后台进程完成通知（synthetic event）
- 定时任务的多轮延续
- 心跳

这些会直接进 `_handle_message`。所以 runner 也有一层：

```python
if self._is_session_running(_quick_key):
    self._hm_evict_reaped_agent(_quick_key)
if self._is_session_running(_quick_key):
    return await self._hm_handle_running_session_message(event, source, _quick_key)
```

注意先 `_evict_reaped_agent`：如果记账说"在跑"但 agent 对象实际已被回收（另一个线程驱逐了），
先修正状态再判定。

### 4.7 跨进程槽位

`_claim_active_session_slot`（[`gateway/run_busy.py:232`](../gateway/run_busy.py:232)）
不只是进程内的锁，它调 `hermes_cli.active_sessions.try_acquire_active_session`。

为什么需要跨进程？因为**同一个会话可能被多个进程服务**：

- 网关进程
- `hermes serve`（桌面后端）
- TUI 的 `tui_gateway`
- 一个手动 `hermes --resume` 的 CLI

它们都可能对同一个 `state.db` 里的同一个 session 跑 turn。进程内锁拦不住。

槽位里有 `max_concurrent_sessions` 限制（全局并发上限），超出时返回
`gateway.busy.*` 的提示文本。

**写入者身份**（`live_session_id`）解决一个具体问题：如果本进程泄漏了一个 lease
（异常路径跳过了 release），下一次 turn 应该能**重新获取自己的**条目，而不是被永久挡在外面。
注释里的 #94595 就是这个。

---

## §5 流式交付契约

### 5.1 先理解两种流式语义

消息平台上"流式输出"有两种完全不同的实现：

**A. 草稿模式（Telegram 形状）**

```
草稿消息（可反复编辑）：「正在思考...」→「正在思考...你好」→「你好，我」
最终消息（单独一条）： 「你好，我是 Hermes。」
```

草稿是**临时的**，最终答案是**新发一条**。Telegram 的 `sendMessageDraft` 就是这个语义。

**B. 流即消息（Slack 原生流式形状）**

```
一条消息：「你好」→「你好，我」→「你好，我是 Hermes。」   ← 同一条消息被不断更新
```

流本身就是最终消息，没有"另发一条"。

代码里用 `draft_stream_is_message` 标记后者。

### 5.2 `draft_stream_is_message` 是 Slack 专属的

[`gateway/relay/adapter.py:175`](../gateway/relay/adapter.py:175)：

```python
# Stream-is-the-message marker read by the stream consumer to keep ONE draft
# stream per turn instead of bumping draft_id at tool boundaries. SLACK-ONLY:
# the base send_draft contract is Telegram-shaped (draft clears, final is a
# separate real send); setting this for any "draft" connector intercepted the
# turn-final into draft(final=true) and no history message was ever posted.
# A future platform with this semantic should advertise it via the descriptor.
self.draft_stream_is_message = (
    str(getattr(descriptor, "platform", "") or "").lower() == "slack"
)
```

这段注释是在记录一次**事故**：曾经对所有 "draft" 类型的 connector 都设了这个标志，
结果在 Telegram 形状的平台上，turn 的最终发送被转成了 `draft(final=true)` ——
而草稿**不会留在历史里**。于是用户看到了流式输出，但聊天记录里**什么都没有**。

现在的做法：硬编码 `== "slack"`，注释明说"未来有同样语义的平台应该通过 descriptor 声明"。
即：**当前是技术债，但明确标注了正确的演进方向**。

### 5.3 四条不变量

[`gateway/AGENTS.md:30`](../gateway/AGENTS.md:30)。每一条都来自一次真实的重复消息/冻结流事故
（NS-658 canary ledger，hermes#85796 / gateway-gateway#210）。

#### 不变量 1：草稿帧前缀稳定

> 第 N 帧必须是第 N+1 帧的字符串前缀。
> 绝不每 tick 修改草稿——不做 fence 闭合、不做光标后缀、不在工具边界重置段状态、
> 不做 mrkdwn 转换。非前缀帧会强制整快照重扫（"stacked copies"）。
> finalize 路径仍可变换真正的最终消息。

**为什么**：平台侧的渲染是基于"增量"的。如果你发的是

```
第 1 帧: "```python\nprint(1)"
第 2 帧: "```python\nprint(1)\n```"        ← 闭合了 fence
```

第 2 帧不是第 1 帧的前缀。平台无法计算"新增了什么"，只能把整段重画。
Slack 在这种情况下的表现是**堆叠的副本**（stacked copies）——看起来像同一条答案出现了三次。

**允许**：在 `finalize` 那一次做真正的变换（比如把 markdown 从标准语法转成平台语法）。
**不允许**：在每帧上做。

#### 不变量 2：消费方声明最终结果，适配器永不猜测

> `finish(final_text)` 携带完成的 `final_response`（含 verifier footer、completion explainer）。
> **新的流后增强必须搭这个 payload 的车**——在 seal 之后改 `final_response` 会重新打开
> `delivered_final_matches` 不匹配 → 纠正性重复发送。

拆开看：

- `finish(final_text)` 是唯一的"这是最终答案"的信号。
- 如果要加"这轮花了多少钱""有几个工具调用失败"之类的增强，**必须**把它们加进
  `finish()` 的 payload 里。
- 如果你在流已经 seal（封口）之后又去改 `final_response`，就会出现：
  - 消费方以为发出的是 X
  - 网关对账时看到最终是 Y
  - 不匹配 → 触发"纠正性发送" → 用户收到两条

#### 不变量 3：中间发送必须带 `metadata["_interim_send"] = True`

> 任何消费方侧的 `adapter.send()` 如果不是 turn 最终（commentary、段尾刷新）都必须设置它，
> 否则 seal 拦截会用中间文本封住活流。seal 拦截在**两个出口**（`send()` 与
> `send_for_platform()`）都存在；新增出口需要同样两处检查。

看代码（[`gateway/relay/adapter.py:1438`](../gateway/relay/adapter.py:1438)）：

```python
async def send(self, chat_id, content, reply_to=None, metadata=None):
    send_metadata = dict(metadata or {})
    explicit_platform = send_metadata.pop("_relay_logical_platform", None)
    # Consumer-declared interim send (commentary, tail flush): NOT the turn-final,
    # so it must never trigger seal-interception (sealing the live stream with
    # interim text orphans the true final into a plain duplicate).
    # Gateway-internal marker; strip before the wire.
    _interim = bool(send_metadata.pop("_interim_send", False))
    # Seal-interception is checked BEFORE the explicit-platform branch: an open
    # stream absorbs the turn-final whichever door it arrives through.
    seal = await self._absorb_into_open_draft(chat_id, content, send_metadata, _interim)
    if seal is not None:
        return seal
    ...
```

和 `send_for_platform()`（[:1341](../gateway/relay/adapter.py:1341)）：

```python
_sfp_metadata = dict(metadata or {})
# Gateway-internal interim marker (see send()): strip before the wire.
_interim = bool(_sfp_metadata.pop("_interim_send", False))
# The delivery resolver calls THIS method directly, bypassing send() — an
# open native stream must absorb the turn-final here too.
seal = await self._absorb_into_open_draft(chat_id, content, _sfp_metadata, _interim)
```

**两个出口都要检查**的原因是：定时任务/持久化投递走 `send_for_platform()`，
**绕过** `send()`。只在一个地方检查，另一条路径上的最终结果就不会被活流吸收 →
用户看到冻结的流 + 一条重复的完整消息。

网关侧有个便捷函数（[`gateway/run.py:486`](../gateway/run.py:486)）：

```python
def _interim_metadata(metadata=None) -> dict:
    """Mark a mid-turn status/advisory send as NOT the turn-final.

    Stream-is-the-message adapters seal the live stream with the first unmarked send to an armed (chat, turn)
    key, so every mid-turn send MUST carry this marker. Gateway-internal; adapters strip it before the wire."""
    merged = dict(metadata or {})
    merged["_interim_send"] = True
    return merged
```

注意最后一句："**适配器在出网前把它剥掉**"。这个标志是网关内部协议，不应该出现在
平台 API 请求里。

一个真实的踩坑例子（[`gateway/relay/adapter.py:2229`](../gateway/relay/adapter.py:2229)）：

```python
def _prompt_reply_metadata(self, event) -> dict[str, Any]:
    """Thread metadata so prompt acks land where the prompt lives. Marked INTERIM:
    acks fire while the approval turn's OWN draft stream is open and carry only
    placement metadata, so send()'s single-open-stream fallback sealed the live
    draft with the ack text (frozen stream + duplicate final on every approval turn)."""
    meta: dict[str, Any] = {"_interim_send": True}
```

一句 `prompt_expired` 的 ack 忘了打 interim 标记 → 每个审批 turn 都以"流被 ack 文本冻住 +
最终答案重复一条"结束。

#### 不变量 4：用编辑对账，绝不用普通发送

> 一条在已封流旁边投递最终结果的通道（排队的后续、带媒体的最终），先在消费方的
> `message_id` 上试 `edit_message`；只有在没有可编辑消息时才用普通 `send()`。
> 已封的原生流就是普通消息——`chat.update` 可以工作（已实测）。

原因：一条消息被 seal 之后，它在平台上就是一条**普通消息**。直接 edit 它，
既不会重复也不会冻流。如果你用 `send()`，用户就多看见一条。

### 5.4 对账：`delivered_final_matches` 三态

[`gateway/stream_consumer.py:330`](../gateway/stream_consumer.py:330)：

```python
def delivered_final_matches(self, final_text: str) -> Optional[bool]:
    """Tri-state reconcile of the recorded turn-final payload against ``final_text`` (a
    *successful* finalize edit can still carry a stale preview, so call success alone
    must not confirm delivery).  True: recorded payload (or an earlier segment /
    commentary) matches.  False: payload differs, or payload-less split.  None: nothing
    recorded on a legacy/ambiguous path (caller trusts flags)."""
```

三态设计：

| 返回 | 含义 | 调用方动作 |
|---|---|---|
| `True` | 已交付，且内容对得上 | 不再发送 |
| `False` | 没交付 / 交付的是别的内容 | **必须**纠正式发送 |
| `None` | 老路径没记录 payload | 信任内部标志（legacy trust） |

**中间那句最重要**："a *successful* finalize edit can still carry a stale preview"。

意思是：`edit_message()` 返回成功 ≠ 用户看到的是正确内容。可能这次 edit 带的是
上一个 tick 的草稿内容（竞态：finalize 读到的是旧的累积缓冲区）。

所以**不能**用"API 调用成功"作为交付证据，必须用**内容对账**。

`:355` 有个关键的细节：

```python
# ``_already_sent`` gates the match: draft frames set ``_last_sent_text`` but
# deliberately not ``_already_sent``.
if self._already_sent and self.has_delivered_text(final_text):
    return True
```

草稿帧会更新 `_last_sent_text`（用于去重），但**故意不设** `_already_sent`。
因为草稿是"临时的"——它可能被平台丢弃、可能用户没看到。只有真正作为最终消息发出去，
才算 `_already_sent`。

`:357`：

```python
# Only a timed-out full-final send that MAY have landed keeps legacy trust.
return None if self._delivery_ambiguous else False
```

`_delivery_ambiguous` 的语义：整体最终发送**超时**了。超时意味着"可能到了"。
这时如果重发，可能产生重复；如果不发，可能丢消息。代码选择 `None`（信任内部标志，
即不重发）——因为**重复比丢失更让用户困扰**。

这个选择值得注意：它是一个**有意的不对称**，不是疏忽。

### 5.5 Slack 的平台真相

[`gateway/AGENTS.md`](../gateway/AGENTS.md:56) 附近记录的三个反直觉事实：

1. **`chat.*Stream` 说的是标准 markdown，不是 mrkdwn。**
   Slack 的普通消息用 mrkdwn（`*bold*`），但流式 API 用的是标准 markdown（`**bold**`）。
   搞混了就是一堆 `**` 露在屏幕上。

2. **`stopStream.markdown_text` 是追加的。**
   不是覆盖。如果你把完整文本再传一遍，用户会看到两遍。

3. **`startStream` / `stopStream` 是 Tier 2 限流（~20 次/分钟）。**
   所以**不能**每 200ms 调一次。这就是为什么流式要"保持一条流"而不是每帧重开。

### 5.6 契约测试

`tests/gateway/test_stream_final_contract.py`——**做变异检查**。

"变异检查"的意思是：它不只测正常路径，还会故意构造违反不变量的行为（比如发一个非前缀帧），
断言系统能检测出来。这样如果有人"优化"掉了守卫，测试会红。

### 5.7 一个实现细节：per-chat 探测

[`gateway/stream_consumer.py:229`](../gateway/stream_consumer.py:229)：

```python
def _stream_is_message(self) -> bool:
    """Whether THIS chat's transport treats the stream as the message: per-chat probe
    first (a relay adapter's class attribute only reflects its primary identity), else
    the legacy attribute; both on the CLASS (MagicMock-safe)."""
    probe = getattr(type(self.adapter), "stream_is_message_for_chat", None)
    if not callable(probe):
        return getattr(self.adapter, "draft_stream_is_message", False) is True
    try:
        return probe(self.adapter, str(self.chat_id)) is True
    except Exception:
        return False
```

为什么不能只用类属性？因为一个 relay adapter 可能同时为一个 Slack 聊天和一个 Telegram 聊天
服务（多平台 relay）。类属性只能反映"主身份"。

[`gateway/relay/adapter.py:304`](../gateway/relay/adapter.py:304)：

```python
def stream_is_message_for_chat(self, chat_id: str) -> bool:
    """Per-chat stream-is-the-message semantic (see ``draft_stream_is_message``).
    A Slack primary must not impose seal semantics on a Telegram chat (its
    turn-final would become draft(final=true) — no history message), nor a
    Telegram primary deny a Slack chat native streaming. Platform-name inference
    is deliberate; a descriptor field is the eventual contract."""
    return str(self._descriptor_for_chat(str(chat_id)).platform or "").lower() == "slack"
```

"Platform-name inference is deliberate" = 作者知道这是权宜之计，并写下来了。
这种"承认技术债"的注释比假装完美的注释有用得多。

注意 `probe` 在**类**上取（`type(self.adapter)`）而不是实例上：测试里的 `MagicMock`
对任何属性访问都返回一个 mock 对象，`callable(mock)` 是 True，会导致误判。
从类上取能拿到真实的未绑定函数（或 `None`）。

---

## §6 出站、交付队列与投递台账

### 6.1 出站的三条路

| 路径 | 谁用 | 代码 |
|---|---|---|
| `adapter.send()` | 交互式 turn 的最终回复 | 各 adapter |
| `adapter.send_for_platform()` | 定时任务、持久化投递（无新鲜入站事件） | relay 等 |
| 投递队列（`cron/deliveries.db`） | 重启安全的 worker | `run_delivery_queue_watch.py` |

### 6.2 为什么 cron 投递要走队列

问题：一个 cron job 跑在什么进程里？

如果跑在网关进程内，网关重启 → job 结果丢失。
如果跑在独立 worker 进程里，worker 跑完后怎么把结果发出去？它没有平台连接。

答案：**worker 把结果写进 `cron/deliveries.db`，网关负责排空这个队列**。

[`gateway/run_delivery_queue_watch.py:1`](../gateway/run_delivery_queue_watch.py:1)：

```python
"""Wake the restart-safe cron delivery drain when a worker writes the queue (#117307).

A restart-safe worker runs its job outside the gateway, queues the final send in
``cron/deliveries.db`` and polls that row once a second; the gateway drained the
queue only on its housekeeping tick, so a turn that ended in 8 s reached the user
a minute later. Between ticks the housekeeping thread now stats the queue file
(and its WAL) and drains as soon as either changed. The tick's own drain stays
as the fallback for anything the stat cannot see.
"""
```

**这是一个很好的"延迟诊断"样本**：
- 症状：8 秒跑完的任务，用户 1 分钟后才收到
- 原因：排空只在每 N 秒的 housekeeping tick 里做
- 修法：在 tick 之间**监视文件戳**（`st_mtime_ns` + `st_size`），一变就排空
- 保底：tick 自己的排空仍然保留（stat 看不见的东西）

实现（[:28](../gateway/run_delivery_queue_watch.py:28)）：

```python
class DeliveryQueueWatch:
    """Stamp-compare every served profile's queue file; ``drain`` when a stamp moved.

    The watch never resets itself after draining: the drain's own status writes
    move the stamp once more and cost one empty pass, after which the stamp is
    stable, while a worker that enqueued during the drain still moves it again.
    """
```

注意它监视的是 **`path` 和 `path-wal` 两个文件**。因为 SQLite 在 WAL 模式下，
新行先写进 `-wal` 文件，主 db 文件可能几十秒都不变。只监视主文件会漏掉。

而且要注意"排空之后不重置"的理由：排空本身会写状态行 → 又动了戳 → 多跑一次空排空。
这个"一次多余的空跑"是**故意接受的成本**，比"排空期间有 worker 入队但被吞掉"好得多。

### 6.3 投递台账（delivery ledger）

[`gateway/delivery_ledger.py:1`](../gateway/delivery_ledger.py:1) 有一个信息密度极高的 docstring：

```python
"""Durable delivery-obligation ledger for gateway final responses (rows in the shared
``state.db``; WAL, owner pid + process-start liveness, bounded retention) so a crash
between finalize and platform ACK cannot lose a response silently.
```

要解决的问题："turn 跑完了，最终回复准备好了，然后进程崩溃在'发出'和'确认'之间"。

五个检查点：

| 状态 | 什么时候写 | 崩溃后怎么处理 |
|---|---|---|
| `pending` | 任何发送之前 | **从未开始** → 直接重发 |
| `attempting` | 就在 `await send()` 之前 | **可能已经到了** → 重发时**必须带可见标记** |
| `delivered` | 只在 `SendResult.success` | 剪除 |
| `failed` | 明确被拒 | 重启是重试边界，也标记后重发 |
| `abandoned` | 尝试次数超限 / 过期 | 短暂保留后剪除 |

关键设计原则（docstring 原文）：

```python
# Crash semantics (never silently resend an ambiguous send)
```

`attempting` 的重发要带可见标记：

```python
RECOVERED_MARKER = "♻️ Recovered reply — the gateway restarted during delivery, so this may be a duplicate:\n\n"
RECONNECTED_MARKER = ("♻️ Recovered reply — the messaging platform reconnected after the original "
                      "delivery failed, so this may be a duplicate:\n\n")
```

**为什么用标记而不是"精确一次"**：分布式系统里"精确一次"需要对方配合（幂等键）。
消息平台大多不支持。所以选择**诚实的至少一次**（at-least-once）：可能重复，
但重复是可见的、可解释的，而不是静默的。

`FLOOD_MARKER`（第三条）针对限流：一条长回复被切成多条请求发，中途被 flood control 拒绝，
前几条可能已经到了。

限制（都是"不是配置"的，注释说明了理由）：

```python
MAX_ATTEMPTS = 3
STALE_AFTER_SECONDS = 24 * 60 * 60
_RETENTION_SECONDS = 7 * 24 * 60 * 60
_MAX_ROWS = 500
```

最后一条原则：

```python
# Everything is best-effort: ledger failures must never block a send;
# callers wrap every call in try/except.
```

**台账坏了不能阻止发消息**。这是一个明确的优先级：正确性 > 可观测性。

### 6.4 空回复与"沉默叙述"

[`gateway/delivery.py:24`](../gateway/delivery.py:24)：

```python
_SILENCE_NARRATION = re.compile(
    r'^[\s*_~`]*\(?\s*(silent|silence|no\s+response|no\s+reply)\s*\.?\)?[\s*_~`]*$'
    r'|^[\s*_~`]*[\U0001F507\.\u2026]+[\s*_~`]*$',
    re.IGNORECASE,
)
```

这个正则识别：`(silent)`、`*silent*`、`🔇`、`...`、`.`

为什么要它？因为模型有时会用这些**叙述**来表示"这轮我不该说话"。
如果原样发出去，群聊里就会出现一条莫名其妙的 `(silent)`。

两个防御点：
- 长度上限 64（`len(stripped) <= 64`），避免把一段真的在讨论"沉默"的文本误杀
- 正则**锚定**（`^...$`），所以"the system was silent for a while" 不会匹配

### 6.5 长消息切分

[`gateway/delivery.py:21`](../gateway/delivery.py:21)：

```python
# Cap before gateway-level truncation of cron output for non-chunking platform delivery.
# Telegram's hard API limit is 4096; the headroom covers the "full output saved to …" footer.
# Adapters that split long messages natively (splits_long_messages) bypass this entirely.
MAX_PLATFORM_OUTPUT = 4000
```

两个细节：

1. **4000 而不是 4096**：留 96 字符给脚注（"完整输出已保存到 /tmp/xxx"）。
2. **`splits_long_messages` 的 adapter 绕过这个限制**：它能自己切，不需要网关预截断。

这个"能力标志"的模式（`supports_code_blocks` / `supports_status_text` /
`supports_async_delivery` / `splits_long_messages` / `typed_command_prefix` /
`supports_inchannel_continuable`）在 [`BasePlatformAdapter:1922`](../gateway/platforms/base.py:1922)
上集中声明。新平台只需要声明这些布尔值，不用改任何核心代码。

---

## §7 后台进程通知

### 7.1 场景

agent 调 `terminal(background=true, notify_on_complete=true)` 启动一个长任务（比如编译）。
turn 结束了，但进程还在跑。几分钟后它跑完了——用户需要被告知。

这会**触发一个全新的 turn**（不是简单地发一条消息），因为：
- agent 需要看到"任务完成了，输出是这个"，然后决定怎么汇报
- 用户可能接着追问，需要上下文

### 7.2 watcher 的装配

[`gateway/run_notifications.py`](../gateway/run_notifications.py:1) 的 `arm_process_watcher`
在网关循环上装一个看护任务，轮询进程注册表。

详细程度由配置 `display.background_process_notifications` 控制（off / errors / all 之类）。

### 7.3 注入需要"回执"，不是"返回 None"

[`gateway/wake.py:79`](../gateway/wake.py:79)：

```python
async def admit_internal_event(adapter: Any, event: Any) -> None:
    """Require a concrete adapter admission, not merely a handler returning None.

    The public handler return stays unchanged. This receipt means scheduled/queued,
    not model execution, authorization of a later turn, or successful outbound delivery.
    """
    event._gateway_accepted = False
    await adapter.handle_message(event)
    if event._gateway_accepted is not True:
        raise WakeNotAccepted("internal wake not accepted by adapter")
```

注意回执的**精确语义**（这个 docstring 写得很讲究）：

> This receipt means **scheduled/queued**, not model execution, authorization of a later
> turn, or successful outbound delivery.

即：回执只表示"这个事件被接收进了处理管道"，**不表示**：
- 模型真的跑了
- 后续 turn 被授权了
- 出站投递成功了

为什么这个区分重要？因为调用方（watcher）用这个回执决定"要不要重试"。
如果把"已排队"当成"已完成"，就不会重试，而实际可能后面失败了。
如果把"已排队"当成"没收到"，就会重复注入。

### 7.4 非推送适配器（`api_server`）要自 POST

[`gateway/wake.py:1`](../gateway/wake.py:1)：

```python
"""Wake an existing agent session from a background completion event. Push-capable adapters
(``supports_async_delivery``) get a synthetic ``MessageEvent(internal=True)`` via handle_message;
stateless adapters (API server) would run that under a ``build_session_key()`` key that never
matches the raw ``X-Hermes-Session-Id`` real turns use (invisible parallel session), so we self-POST
``/v1/chat/completions`` with the raw id header to resume the REAL session.
```

问题：`api_server` 的会话键是客户端传来的 `X-Hermes-Session-Id` 原始值。
如果走 `handle_message`，会经过 `build_session_key()` 生成一个 `agent:...` 形状的 key，
**永远匹配不上**真实会话 → 创建一个看不见的平行会话。

所以对这类适配器，代码改成**自我 HTTP POST**，带上原始 header。

**例外**：async-delegation 完成事件。

```python
Exception: async-delegation completions: the CLIENT owns the next turn, so they are never
self-POSTed as a new ``role=user`` prompt (could cross a pending human-confirmation gate);
instead ``persist_delegation_delivery`` writes a durable DELIVERY row
(``display_kind="async_delegation_complete"``, read by TUI/desktop pollers).
```

为什么？因为异步委派完成后，**客户端**（桌面应用/TUI）会自己发起下一轮。
如果你还自己 POST 一个 `role=user` 的 prompt，可能会**跨过**一个正在等待的人工确认门
（用户还没点"允许"，你就替他发了一条消息）。

而且它可能把"任务完成"这个事实告诉模型，让模型以为用户说了这句话。

修法：写一条**只用于显示**的投递行，让前端 poller 去读。

```python
Async delegation UUIDs identify one producer completion. Process session IDs include the
persisted spawn epoch so a reused ID is a distinct incarnation; legacy events without
``started_at`` are delivered undeduplicated rather than risk suppressing a real completion.
```

`run_notifications.py` 里的这条（[:1235](../gateway/run_notifications.py:1235)）也在讲同一个
取舍：**宁可重复，不可静默丢弃**。

### 7.5 失败必须抛，不能吞

```python
# Failures RAISE (after bounded retries on transient errors) so callers can rewind
# cursors / retry instead of silently losing the event.
```

```python
WAKE_TURN_TIMEOUT_SECONDS = 600.0

# Backoff between retries on transient failures. The API server has no per-session lock
# (concurrent turns are last-writer-wins) but DOES enforce a global max_concurrent_runs cap
# via HTTP 429, which is worth waiting out.
_RETRY_DELAYS_SECONDS = (2.0, 5.0, 10.0)
```

600 秒超时：自我 POST 是同步跑完整个 turn（`stream=false`），长工具调用的 turn 不能被腰斩。

三档退避 `(2, 5, 10)`：只会等 429 这类**值得等**的错误。

### 7.6 被拒时的退款

[`gateway/AGENTS.md`](../gateway/AGENTS.md:59) 提到：

> 被拒绝准入会退还每个已认领的 batch sibling，且不消耗尝试次数

"batch sibling"：进程注册表里一批相关的完成事件（比如一个 bash 脚本里并行起的 5 个进程，
一起监控）。watcher 一次认领它们，如果一个都注入不了要全部退还，下次重试时一起再来。
如果不退还，其中几个就永久丢了；如果消耗尝试次数，几次失败后整批被标 `abandoned`。

### 7.7 一个真实的平台踩坑：Discord 的"回复到旧消息"

[`gateway/run_notifications.py:1193`](../gateway/run_notifications.py:1193)：

```python
# The queued event's ``message_id`` is the message that STARTED the process, and the
# persisted origin carries the same stale id. A synthetic completion is not a reply to
# it: by delivery time the user has often continued elsewhere, and an event anchored
# there makes the finished job's reply quote that old message on every reply-anchoring
# platform (#52694: a background completion visibly replying to a stale Discord DM
# message). Routing is unaffected — topic lanes carry thread_id and the anchor-less
# synthetic-send branches are covered (#87051); the original id rides metadata for
# debugging only.
```

使用 `replace_source(source, message_id=None)` 把 source 的 message_id 清掉，
原值放进 metadata 只用于调试。

这是"**语义正确性**"的典型例子：技术上回复那条旧消息没问题，但用户看到的是
"任务完成"消息挂着一条 3 小时前的引用——非常困惑。

---

## §8 生命周期 vs 桌面应用

### 8.1 两个进程，两种生命周期

| 进程 | 命令 | 生命周期 |
|---|---|---|
| `hermes serve` | 控制平面，桌面 spawn 的子进程 | **随应用而死** |
| 消息网关 | `gateway run` | **存活于应用之后** |

这不是 bug，是**设计**。

### 8.2 为什么网关要 detached

如果网关是 `hermes serve` 的子进程：
- 用户关掉桌面窗口 → backend 收到 `before-quit` → SIGTERM → 网关死
- 但用户的 Telegram bot 也就死了
- 用户从手机发消息，没人回

所以 serve 后端的 `/api/gateway/*` 端点以 **detached** 方式 spawn 网关：

[`hermes_cli/web_server_gateway.py:519`](../hermes_cli/web_server_gateway.py:519)：

```python
detach = {"creationflags": windows_detach_flags()} if sys.platform == "win32" \
         else {"start_new_session": True}
proc = subprocess.Popen(
    cmd, cwd=str(PROJECT_ROOT), stdin=subprocess.DEVNULL,
    stdout=log_file, stderr=subprocess.STDOUT, env=action_env, **detach,
)
```

- POSIX：`start_new_session=True`（新 session，脱离父进程的进程组；SIGTERM 到不了它）
- Windows：`DETACHED_PROCESS` 标志

### 8.3 两条"不要去修"的警告

[`gateway/AGENTS.md`](../gateway/AGENTS.md:76)：

> **不要**为了"修复 gateway 随应用而死"而把网关重新挂到 backend 下；
> **也不要**为了"修复更新锁"而扩大 tree-kill。

第二条说的是：`hermes update` 需要重启正在运行的网关。它用的机制是"找到 PID，
发送信号"。有人可能想"那我 tree-kill 整棵进程树更保险"——
但网关是 detached 的，它的"进程树"里可能有**用户自己启动的子进程**（后台任务）。
杀掉整棵树会误杀用户的工作。

### 8.4 代码身份校验

[`gateway/status.py:793`](../gateway/status.py:793)：

```python
def _process_code_identity():
    """Code identity of THIS process for ``gateway_state.json`` (restart picked up new code?).

    ``gateway_state.json`` lets `hermes update` (and the dashboard) prove whether a running gateway actually
    ...
    """
    return {"code_sha": identity.get("sha"), "code_version": identity.get("version")}
```

网关把自己跑的是哪个 commit/version 写进 `gateway_state.json`。

为什么需要？因为"更新成功"和"网关真的换了新代码"是两件事：
- `git pull` 成功 → 磁盘上是新代码
- 网关重启成功 → 内存里是新代码

如果网关重启失败（比如旧进程没死），它还在跑旧代码，但 `hermes update` 以为成功了。
有了 `code_sha`，update 可以校验"你报的 sha 和我期望的一致吗"。

在多机器/fleet 场景下，这让"整个 fleet 都更新了吗"变成一个可查询的问题。

---

## §9 Profile 作用域（网关最深的部分）

### 9.1 先理解 profile 是什么

一个 profile 是**一套完全独立的 Hermes 状态**：

```
~/.hermes/                      ← default profile
├── config.yaml
├── .env
├── state.db
├── memory/
└── skills/

~/.hermes/profiles/work/        ← "work" profile
├── config.yaml
├── .env
├── state.db
├── memory/
└── skills/
```

隔离是**故意的**：不同 profile 的记忆不互相污染、密钥不互相泄漏、会话库不互相看见。

### 9.2 一个进程服务多个 profile

`gateway.multiplex_profiles: true`（默认开启）时，**一个网关进程**服务所有 profile。

为什么这么做？因为：
- 每个 profile 一个进程 = N 份 Python 解释器、N 份记忆 provider、N 份 MCP 连接
- 而且每个 profile 可能配了**同一个** Telegram bot token → 冲突

所以：一个进程，一个 adapter 集合，但每轮 turn 在**对应 profile 的作用域**下跑。

### 9.3 根因：`os.environ` 只有默认 profile 的值

这是整个 §9 的核心事实，也是所有 profile bug 的根源：

> 在 `gateway.multiplex_profiles` 下，**`os.environ` 持有默认 profile 的值**；
> 次要 profile 的 `.env` 只存在于它的 secret scope 里。

为什么？因为 `os.environ` 是**进程全局**的。进程启动时加载了默认 profile 的 `.env`。
次要 profile 的 `.env` 不能也塞进 `os.environ`——那样两个 profile 的
`TELEGRAM_BOT_TOKEN` 会互相覆盖（后写的赢），而且子进程会继承到错误的值。

所以次要 profile 的密钥放在一个 **ContextVar 绑定的 secret scope** 里。
读取必须走 `get_scoped_secret()`，不能直接 `os.getenv()`。

### 9.4 身份三问：`RoutingIdentity`

[`gateway/session_identity.py:1`](../gateway/session_identity.py:1)：

```python
"""..."""
```

`resolve_identity`（[:184](../gateway/session_identity.py:184)）
**对每个事件只回答一次**三个问题：

1. **哪个 bot 收到它？** → `transport_profile`
2. **谁可以准入？** → `authorization_home`
3. **它在哪运行？** → `runtime_profile` / `runtime_home`

答案是一个**冻结的** dataclass（[:42](../gateway/session_identity.py:42)）：

```python
@dataclass(frozen=True)
class RoutingIdentity:
    transport_profile: str          # 收到事件的 bot 属于哪个 profile
    runtime_profile: str            # turn 应该在哪个 profile 下跑
    authorization_home: Path        # 授权检查读哪个 home 的 allowlist
    runtime_home: Path              # 会话/记忆/技能读哪个 home
    multiplexed: bool
    transport: Optional[...]        # weakref 到 live adapter
    transport_inferred: bool        # transport 是推断的还是确定的
```

**为什么必须冻结 + 只解析一次**：如果每个消费者各自读 `source.profile` / `os.environ`，
它们会在不同的时刻得到不同的答案（尤其是在 await 之后作用域已经退出）。
钉一个不可变对象在 source 上，所有下游读同一个快照。

**钉在哪里**：`source` 上的一个私有属性（`_IDENTITY_ATTR = "_identity"`，[:25](../gateway/session_identity.py:25)），
wire 不可见（不会被序列化进 token、不会被发到平台）。

**`transport_profile ≠ runtime_profile` 是正常的**：共享 bot 收到的消息，
可能路由到某个卫星 profile 去执行。这时：
- `transport_profile` = 共享 bot 的 profile（比如 `default`）
- `runtime_profile` = 实际执行的 profile（比如 `work`）

### 9.5 规范化缝：在派生 key 之前

**必须有**的规则：**每条 ingress 路径在派生 key 之前调用规范化缝**。

已知的缝：

| 缝 | 位置 | 覆盖什么 |
|---|---|---|
| 适配器侧 | [`platforms/base.py:2454`](../gateway/platforms/base.py:2454) `_canonicalize` | 新鲜事件、批量合并、忙碌路径、控制命令、回调 |
| runner 侧（适配器） | [`run_adapters.py:1683`](../gateway/run_adapters.py:1683) `_canonicalize` | 主要/次要 profile 的消息与忙碌路径 |
| runner 侧（入站门） | [`run_inbound.py:190`](../gateway/run_inbound.py:190) | 内部构造的 source（voice、内部事件） |

**为什么 runner 侧也要有**：因为有些路径**绕过**适配器的 `handle_message`：
- voice 路径自己构造 `SessionSource`
- 内部事件（后台通知）自己构造
- Discord interaction passthrough 直接调 `handle_message`

这些 source 从未经过适配器的 `build_source`，所以没有 transport provenance。
入站门是"共享的 fail-closed 门"。

```python
# Identity FIRST. Most adapters canonicalize at their own ingress; internal/voice paths
# construct SessionSource directly, so this is the shared fail-closed gate. Strict boolean
# marker: require the literal True so duck-typed test/internal sources with dynamic
# attributes are not mistaken for a rejection.
if getattr(_config, "multiplex_profiles", False):
    self._canonicalize(source)
if getattr(source, "profile_route_rejected", False) is True:
    logger.warning(
        "Dropping inbound message because its explicit profile route "
        "targets an unserved profile"
    )
    return None
```

**"绝不被 key 成 `agent:main`"**：如果身份解析失败（路由到未服务的 profile），
事件必须**丢弃**，不能"降级到默认 profile"。降级的后果是：work profile 的用户消息
跑在 default profile 的记忆/密钥里——既泄漏又丢数据。

### 9.6 接收适配器 vs 交付适配器

[`gateway/authz_mixin.py`](../gateway/authz_mixin.py:1) 有两个函数：

#### `_intake_adapter_for(source)`（[:254](../gateway/authz_mixin.py:254)）

返回**收到**事件的 bot。解析顺序：
1. live transport ref（`source._transport_adapter_ref`，weakref）
2. relay socket
3. 身份的 `transport_profile` 对应的 adapter

**对没有 live provenance 的 source fail closed 到 `None`**。

为什么 fail closed？因为如果没有 provenance，就无法确定"哪个 bot 的 allowlist 该用于准入"。
随便选一个 = 可能用 bot A 的 allowlist 放行 bot B 的陌生人。

#### `_delivery_adapter_for(source)`（[:285](../gateway/authz_mixin.py:285)）

返回**回答**的 bot。逻辑：
1. 已知接收 bot → 用接收 bot（同一通道回复最自然）
2. 否则通过 `_adapters_for_profile` 找 `(platform, runtime_profile)` 的**唯一 owner**
3. 只在 `transport_inferred` 为真时才用 unique-owner 回退（否则 fail closed）

#### 两条禁令

> **绝不读 `self.adapters[platform]`**；**绝不加第三个 resolver**。

第一条的后果：`self.adapters` 是**默认 profile 的** adapter 映射。用它在 multi-profile 下
会回复到错误的 bot。
第二条的后果：第三个 resolver 会漂移，和前面两个的逻辑不一致。

#### 拓扑矩阵

`tests/gateway/test_multiplex_transport_matrix.py`（不变量测试）：

| 拓扑 | runtime | intake | delivery |
|---|---|---|---|
| 每凭证 bot，无路由 | owner | owner 适配器 | owner 适配器 |
| 共享凭证 → 卫星（`profile_routes`） | routed | 接收适配器 | 接收适配器 |
| 共享 bot → 拥有自己 bot 的 profile | routed | 接收适配器 | 接收适配器 |
| 次要拥有的 bot → `default`（`bot_profile`） | default (`agent:main`) | 接收适配器 | 接收适配器 |
| 恢复/手工构造，无 live provenance | 存储的 `source.profile` | **`None`** | `(platform, runtime)` 唯一 owner |

第三行值得单独看：共享 bot 收到消息，但目标 profile **有自己的 bot**。
这时执行在 routed profile，但回复走**共享 bot**（因为消息是从那儿来的）。
如果回复走目标 profile 自己的 bot，用户会在一个他从没说过话的 bot 里收到答案。

### 9.7 身份要熬过进程重启

内存里的 identity 在重启后消失。但**投递**需要知道"哪个 bot 可以向这条 lane 投递"。

持久化（[`gateway/session.py:482`](../gateway/session.py:482) 的 `SessionEntry`）：

- **路由索引**里有 `transport_profile`
- **`sessions` 表**有一个 `transport_profile` 列（可空）

两条信息的职责分工：

> - **命名空间**说这条 lane 在哪**运行**（session key 的前缀，比如 `work:telegram:dm:...`）
> - **列**说哪个 bot 可以向它**投递**

为什么不能只存一个？因为一个 `work:` 前缀的会话，可能是共享 bot 收到的（投递走共享 bot），
也可能是 work 自己的 bot 收到的（投递走 work 的 bot）。命名空间无法区分。

### 9.8 唯一凭证的锁

如果两个 profile 配了**同一个** Telegram bot token，两个都连上去会发生什么？
Telegram 只允许一个连接者，先连的赢，后连的收到 409 并重试循环。
用户看到的是"bot 随机地在这个 profile 和那个 profile 之间跳"。

解法：**机器级 scope lock**（[`gateway/status.py:1565`](../gateway/status.py:1565)）：

```python
def acquire_scoped_lock(scope: str, identity: str,
                        metadata: Optional[dict] = None) -> tuple[bool, Optional[dict]]:
    """Acquire a machine-local lock keyed by scope + identity (one Telegram token across homes)."""
```

适配器在 `connect()`/`start()` 里 acquire，在 `disconnect()`/`stop()` 里 release。
范本：[`plugins/platforms/irc/adapter.py`](../plugins/platforms/irc/adapter.py:1)。

两个实现细节值得记：

**(a) 自己的 PID 永远自我重入**（`status.py:1586` 附近的注释）：

```python
# Our own PID: always self-reacquire. start_time guards reuse of OTHER PIDs; requiring
# equality here rejects reconnects when the on-disk record has start_time null.
```

`start_time` 是用来防 **PID 复用**的（进程 A 死了，PID 被进程 B 拿到）。
但对**自己的 PID** 不需要这个检查——我还活着，这个 lock 就是我的。
严格的 `start_time` 相等检查会导致：磁盘上记录是旧版本写的（`start_time: null`），
我自己重新获取时比对失败 → **网关把自己认成"别人占了它的 token"**（#81468）。

**(b) 释放时不检查 start_time**（[:1613](../gateway/status.py:1613)）：

```python
def release_scoped_lock(scope: str, identity: str) -> None:
    """Release a scope lock owned by this PID. No start_time equality check: on-disk null vs a live
    fingerprint would wedge reconnects."""
```

同样的理由，但方向相反：检查会导致 lock 永远释放不掉。

还有一个"脏记录"处理（[:1581](../gateway/status.py:1581)）：

```python
existing = _read_json_file(lock_path)
if existing is None and lock_path.exists():
    # Empty/invalid JSON: previous process died between O_EXCL create and json.dump().
    _unlink_quietly(lock_path)
```

`O_EXCL` 创建 + 写 JSON 是两步。中间崩溃 → 留下一个空文件。
空的 lock 文件会让所有后续进程都以为"被占用"→ 永久死锁。

### 9.9 作用域化读取：`get_scoped_secret`

[`gateway/platforms/_shared.py:22`](../gateway/platforms/_shared.py:22)：

```python
def get_scoped_secret(name: str, default: Any = None, *, external_fallback: bool = False) -> Any:
    """Scope-aware credential read with the default-profile startup fallback.

    An installed profile secret scope is authoritative: a scoped miss returns
    ``default`` (never borrow another profile's value from ``os.environ``).
    The DEFAULT profile constructs and sends *unscoped* under multiplexing,
    where a bare ``get_secret`` raises ``UnscopedSecretError``; there
    ``os.environ`` is that profile's own value, so fall back to it.
    """
```

三种情况，三种行为：

| 情况 | 作用域已安装？ | 读到什么 |
|---|---|---|
| multiplex 下的次要 profile | 是 | 作用域里的值；**miss 返回 default** |
| multiplex 下的默认 profile（unscoped） | 否 | `os.environ`（那**就是**它自己的值） |
| 单 profile 部署 | 否 | `os.environ`（同上） |

**关键规则（fail closed）**：

> **作用域已安装 + multiplex 激活 → 作用域 miss 返回 `default`，绝不返回 `os.environ`**

为什么？`os.environ` 里可能有**另一个** profile 的桥接值。泄漏的 allowlist 会：
1. 跳过 "allow all" 检查（因为以为已经配了白名单）
2. **静默拒绝**每个次要 profile 的发送者（因为 `os.environ` 里的白名单是默认 profile 的人）

这就是 #86905：用户配了 `TELEGRAM_ALLOWED_USERS` 在 work profile 的 `.env` 里，
但 bot 拒绝他所有消息，因为读到的是 default profile 的白名单。

### 9.10 授权门也必须作用域化

`get_scoped_secret` 是给凭证用的。授权（allowlist）用另一个：

[`gateway/platforms/_shared.py:69`](../gateway/platforms/_shared.py:69)：

```python
def platform_gate_env(name: str, default: str = "") -> str:
    """Allow/deny gate env read with per-profile isolation, always stripped.

    With a profile secret scope installed AND multiplexing active, a scoped miss returns ``default``
    instead of falling through to ``os.environ``, which may hold ANOTHER profile's first-writer
    bridged value (the YAML→env bridges are first-writer-wins; allowlist leak, #72348).
    Single-profile deployments behave exactly like ``os.getenv``.
    """
```

注意 "**YAML→env bridges are first-writer-wins**" 这句话。这是另一个陷阱：
`apply_yaml_bridge` 把 YAML 配置**写进** `os.environ`（很多平台 SDK 只认环境变量）。
"first-writer-wins" 意思是：第一个写的值留下来，后来的写不进。

所以在 multiplex 下，默认 profile 的 YAML 桥接值先占了 `os.environ`，
次要 profile 的桥接**不会**覆盖它。任何 `os.getenv` 读到的都是默认 profile 的。

`authz_mixin.py:51-53` 说明它怎么 import（这个细节重要）：

```python
from gateway.platforms._shared import (
    _decode_json_list_literal, _extra_or_secret, platform_gate_env as _auth_env,
)
```

用 `as _auth_env` 重命名，是为了让代码里到处都是 `_auth_env(...)` 而不是
`platform_gate_env(...)`，在 review 时一眼能看出"这是授权门读取"。

`authz_mixin.py:35-48` 是四张 env 表：

```python
_ALLOWED_USERS_ENV   # <PLATFORM>_ALLOWED_USERS
_ALLOW_ALL_ENV       # <PLATFORM>_ALLOW_ALL_USERS
_GROUP_USER_ENV      # 群聊用户策略
_GROUP_CHAT_ENV      # 群聊策略
_ALLOW_BOTS_ENV      # 是否允许 bot 发言（含 #4466 Slack Workflow Builder 注释）
```

### 9.11 绝对禁止的写法

> **绝不**在适配器里重新实现 reader——
> `try get_secret / except UnscopedSecretError: os.getenv` 这种形状会漂移成"miss 后回退"的泄漏。

拆解这个反面模式：

```python
# 错误写法
def _read_token(name):
    try:
        return get_secret(name)           # 正确：作用域感知
    except UnscopedSecretError:
        return os.getenv(name)            # ← 灾难
```

看起来"抛异常就回退"很合理。但 `UnscopedSecretError` 只在"没有作用域"时抛。
在 multiplex 的次要 profile 里，如果代码路径意外没装作用域，某些情况下
`get_secret` 可能**不抛**而是返回默认值；而在另一些情况下抛 → 回退到 `os.environ` →
读到默认 profile 的值。

**这个分支的存在本身就意味着"有时候会读错"**。正确做法：用共享的那个函数，
它的三分支逻辑已经处理了所有情况。

### 9.12 作用域按 profile **活动**绑定，不是按 turn

[`gateway/run.py:1787`](../gateway/run.py:1787)：

```python
@_contextmanager
def _profile_runtime_scope(profile_home: Path, prepared_secret_scope=None, *,
                           hydrate_secrets: bool = True):
    """Scope config/skills/memory AND credentials to a profile for one turn (multiplexed path only).
    ``set_hermes_home_override`` is a contextvar (reaches the agent worker via ``copy_context()``);
    ``set_secret_scope`` makes the profile ``.env`` the credential source without mutating
    ``os.environ``, so subprocesses never inherit cross-profile secrets."""
```

它做三件事：
1. `set_hermes_home_override(str(profile_home))`——home 路径
2. `set_secret_scope(secrets, profile_home=str(profile_home))`——密钥
3. `install_and_reset_profile_terminal_scope(Path(profile_home))`——**terminal 策略**

第三件事的注释：

```python
# Install the routed profile's COMPLETE terminal policy, never ambient TERMINAL_* a prior turn set.
# Without it terminal_tool reads the process-global TERMINAL_* vars a previous profile's turn may have
# pinned (first-writer-wins backend leak; #68559).
```

`TERMINAL_*` 环境变量（`TERMINAL_BACKEND`、`TERMINAL_CWD`…）也是进程全局的。
profile A 的 turn 把它设成 `docker`，profile B 的 turn 就会在 docker 里跑。
所以每轮要**完整安装**该 profile 的 terminal 策略，而不是"没设就用默认"。

#### 哪些路径需要作用域

不只有 turn。**每一条**触碰会话 home、secrets 或 terminal scope 而栈上没有 turn 的路径都要：

| 路径 | 位置 | 后果 |
|---|---|---|
| 释放与驱逐 | [`run_agent_cache.py:861`](../gateway/run_agent_cache.py:861) `_run_release_in_profile_scope` | 见下 |
| 关闭 | `run_shutdown.py::_finalize_session` | 同上 |
| turn 后媒体投递 | [`platforms/base.py:3619`](../gateway/platforms/base.py:3619) `_media_delivery_scope` | 媒体存到错误的 profile 目录 |
| 延迟回调 | pickers、reactions | 在命令时捕获路由 home，回调里重入作用域 |
| 通知器与外发 webhook | — | 用错密钥 |

`_run_release_in_profile_scope` 的 docstring 把两个陷阱都点出来了：

```python
"""Call ``target(*args)`` under the profile that OWNS ``session_key``.

Threads start with an EMPTY context, so a bare thread would commit end-of-session memory
(provider ``on_session_end`` reads credentials/home at call time) under the launch profile.
And the LRU-cap eviction runs inside the REQUESTING turn, whose agent may belong to another
profile — so "some scope is present" is not enough either.
"""
```

**陷阱 1（空上下文）**：`threading.Thread` **不继承** contextvars（`copy_context` 是
`asyncio` 的事）。所以在裸线程里跑的 `on_session_end` 看不到 turn 的作用域 →
读到启动 profile 的 home/密钥 → **把 work profile 的记忆写进 default 的库**。

**陷阱 2（错误的作用域）**：LRU 驱逐发生在**发起请求的 turn** 里。如果那个 turn 是
profile A 的，而被驱逐的 agent 属于 profile B，那么"有作用域"（A 的）反而更糟——
它会用 A 的 home 去收尾 B 的 agent。

**正确做法**：从 `session_key` 的**命名空间**推出 owner，再进它的作用域：

```python
owner = store._profile_home_for_key(session_key) if session_key else None
owner_home = Path(owner) if owner else get_default_hermes_root()
if current_secret_scope() is None or \
   hermes_home_key(get_hermes_home()) != hermes_home_key(owner_home):
    scope = _profile_runtime_scope(owner_home)
```

注意 `get_default_hermes_root()` 作为 fallback，注释解释了为什么不是 `get_hermes_home()`：

```python
# a named profile's home, else the DEFAULT profile (``agent:main:`` keys), which is the
# root Hermes dir even when the gateway was launched under a named profile.
```

`agent:main:` 前缀的 key 属于**默认** profile，即使网关是从 `--profile work` 启动的。

### 9.13 `multiplex_profiles: false` 不是"永不设作用域"

这是最容易误解的一条。

**误解**：关掉 multiplex，就只有一个 profile，不需要作用域。

**现实**：原生托管的 room 会在网关进程内**翻转进程级守卫**：
`tui_gateway/launch_profile_policy.py::activate_multi_profile_hosting`。

即：一个"单 profile"的网关进程，可能在运行时被要求服务另一个 profile 的托管房间。

[`run_adapters.py:1785`](../gateway/run_adapters.py:1785) 就是为此存在：

```python
def _standalone_scoped(self, handler):
    """Standalone twin of the ``_make_default_profile_*`` wrappers: run ``handler`` under
    ``_standalone_launch_scope`` so slash commands and turns keep resolving the launch profile's
    credentials after a hosted room flipped the process-wide guard (#112878). Decided per event:
    activation happens after the adapters were wired."""
    async def _handler(*args):
        with self._standalone_launch_scope():
            return await handler(*args)
    return _handler
```

注意 "Decided per event: activation happens after the adapters were wired"：
判定发生在**每个事件**处理时，而不是接线时。因为翻转可能在接线之后发生。

而 `_primary_message_handler()`（[:1773](../gateway/run_adapters.py:1773)）就是那个分岔：

```python
def _primary_message_handler(self):
    """Return the correctly scoped handler for a primary adapter."""
    if self._multiplex_on():
        return self._make_default_profile_message_handler()
    return self._standalone_scoped(self._handle_message)
```

### 9.14 hooks 与 observers 按被服务的 profile 注册

- **注册键含 profile**（幂等性）：同一个 hook 在 profile A 和 B 各注册一次，
  用 `(hook_name, profile)` 做幂等键，不会互相覆盖。
- **`hooks/` 路径在调用时解析**：不能存成模块常量。因为模块常量会在**第一个 importer**
  的 profile 下冻结。

```python
# 错误写法
HOOKS_DIR = get_hermes_home() / "hooks"      # ← import 时就冻在启动 profile 上

# 正确写法
def _hooks_dir():
    return get_hermes_home() / "hooks"       # ← 每次调用时解析（跟着作用域走）
```

这跟 07 篇讲的 `_default_db_path` 是同一类 bug：**import 快照**。

### 9.15 YAML 桥接在 multiplex 下永不进 `os.environ`

`apply_yaml_bridge`（[`_shared.py:189`](../gateway/platforms/_shared.py:189)）：

```python
def apply_yaml_bridge(cfg: dict, spec) -> dict | None:
    """Table-driven ``apply_yaml_config_fn`` body: for each ``(yaml_key, ENV_VAR, kind)`` row seed the
    original YAML value into the returned ``extra`` and bridge it to env through ``yaml_env_setter``
    (env wins; skipped under a secondary profile's scope). ``None`` when nothing matched."""
```

"**skipped under a secondary profile's scope**"：次要 profile 的 YAML 不做桥接。
它的值只进 `extra`（运行时通过 `extra_or_secret` 读）。

原因还是同一个：`os.environ` 是全局的，first-writer-wins，桥接进去就是泄漏。

而 `extra_or_secret`（[:106](../gateway/platforms/_shared.py:106)）是"唯一"的 per-profile 设置读取：

```python
def extra_or_secret(extra, key, env, default="", *, blank_is_unset=True):
    """The ONE per-profile setting reader: explicit env ``env`` → the profile's YAML
    ``config.extra[key]`` → ``default``.
    ...
    keeping the documented env-over-YAML contract (an explicit ``DISCORD_ALLOW_MENTION_EVERYONE=false``
    beats ``everyone: true``, #108440; ``TELEGRAM_REACTIONS=true`` beats the stock ``reactions: false``,
    #109032).
    """
```

三个易错点它都处理了：
1. **空字符串算未设置**（`blank_is_unset`）
2. **YAML 里的显式 `False` / `0` 是真值**（不能因为 falsy 就跳到 default）
3. **env 优先于 YAML**（有 issue 编号背书）

### 9.16 未服务的平台要报告，不要静默

[`run_adapters.py:1201`](../gateway/run_adapters.py:1201)：

```python
def _note_unserved_secondary_platform(self, profile_name: str, platform: Platform) -> None:
    """Report unpaired WhatsApp or secondary-only Relay. Log the reason and remedy and stamp a
    ``<profile>:<platform>`` status entry so ``hermes gateway status --profile X`` and the
    dashboard show *why* the channel is dead instead of nothing at all."""
```

两种情况的文案：

**WhatsApp 未配对**：
```
WhatsApp is not paired; pair it: hermes -p work whatsapp
```
→ 状态 `disabled` / `whatsapp_unpaired`

**共享入站（api_server/webhook 之类）在次要 profile 上**：
```
[MULTIPLEX] Profile 'work': telegram is enabled but not served — telegram is process-level
shared ingress owned by the default profile under multiplex. Enable and configure telegram
on the default profile (it serves every profile), or disable it in profile 'work'.
```
→ 状态 `disabled` / `multiplex_shared_ingress`

注意第二次调用会**提前返回**（`if (profile_name, platform) in noted: return`），
避免日志刷屏。

`SHARED_LISTENER_MIRROR_PLATFORMS`（[`gateway/config.py:315`](../gateway/config.py:315)）：

```python
SHARED_LISTENER_MIRROR_PLATFORMS = frozenset({"api_server", "webhook"})
# Path a client appends to ``<default listener>/p/<profile>`` to reach each mirror.
SHARED_LISTENER_MIRROR_PATHS: dict[str, str] = {"api_server": "/v1", "webhook": "/webhooks/<route>"}
```

这两个平台**只能有一个监听端口**（否则端口冲突）。所以次要 profile 的
`api_server` 不是自己起一个，而是通过默认监听器的 `/p/<profile>/v1` 路径访问。

### 9.17 "这个任务服务路由 profile 吗？"

判定必须比较 `hermes_constants.get_routing_process_hermes_home()`，
**绝不** live 读 `os.environ["HERMES_HOME"]`。

为什么？因为"网关进程的 HERMES_HOME"可能是 `~/.hermes/profiles/work`（用户用
`--profile work` 启动），而它服务的路由 profile 是 `default`。
live 读环境变量会得到启动 profile，判定就错了。

### 9.18 一个会计细节：cron 的 profile gate

[`gateway/run.py:1665`](../gateway/run.py:1665) 的 `_cron_profile_gate` 有一段非常好的注释：

```python
"""Tick ``home`` this cycle unless ANOTHER gateway process owns it.

Same stand-down the serve/Desktop ticker applies (``hermes_cli/web_server.py``): a host that
has not finished converging onto the one host gateway (``hermes gateway migrate --multiplex``)
may still run profile B's own gateway, and without this both it and this process race B's
``cron/.tick.lock``. The lock stops a simultaneous double-run but not the race: when this
process wins, B's delivery leaves through ``SharedRouteAdapters``/fail-closed instead of B's
live adapters.

The liveness answer is compared against our OWN pid, never used bare: this process holds the
launch home's ``gateway.pid`` and publishes every served profile in ``served_profiles``, so a
bare ``_check_gateway_running`` reports "running" for every home we serve — standing us down
from all of them and stopping cron host-wide.
"""
```

三个层次的洞察：

1. **文件锁不够**：`.tick.lock` 只防"同时跑两次"。它防不住"我跑了 B 的 tick，
   但 B 的 adapter 不在我这个进程里"——结果 B 的投递走 fail-closed，静默失败。

2. **"谁是 owner"要看 PID**：不能只看"有没有 gateway 在跑"。

3. **最精妙的一层**：本进程持有 launch home 的 `gateway.pid`，并且把服务的所有 profile
   都发布在 `served_profiles` 里。所以一个裸的"检查 gateway 是否运行"会对**每个**
   它服务的 home 都返回"running"——包括它自己。如果不和自己的 PID 比对，
   本进程会把自己从所有 profile 上 stand down，导致**全机的 cron 停摆**。

这是一个极好的"自指检测"案例。

### 9.19 日志路由

[`run.py:1692`](../gateway/run.py:1692)：

```python
def _enable_multiplex_log_routing(config) -> bool:
    """Route agent.log/errors.log/gateway.log records to their owning profile (inert single-profile).
    ``setup_logging(mode="gateway")`` binds file handlers to the launch home, so under multiplexing
    every secondary profile's records would land in the default profile's logs.
    """
```

`setup_logging` 在启动时把 file handler 绑到启动 home 的路径上。这在单 profile 下没问题，
但 multiplex 下所有 profile 的日志都写进默认 profile 的 `agent.log`。

修法：等服务 profile 集合确定后，把静态 handler 换成 **profile 路由器**
（#99440 的 primitive，桌面 cron ticker 用的是同一个）。

注释里还有一句"inert for single-profile gateways（`enable_profile_log_routing` is a no-op
below two homes）"——一个函数在不需要时是 no-op，比调用方到处 if 好。

### 9.20 §9 速查：什么时候你踩到了 profile 作用域 bug

看到这些症状，先怀疑身份/作用域：

| 症状 | 可能的根因 |
|---|---|
| 次要 profile 的用户被拒（"unauthorized"） | allowlist 读到了 `os.environ`（默认 profile 的） |
| 记忆/会话跑到了错误的 profile | 某个异步路径没装作用域（线程/延迟回调/驱逐） |
| 回复出现在错误的 bot 里 | 用了 `self.adapters[platform]` 而不是 `_delivery_adapter_for` |
| 两个 profile 抢同一个 bot | 缺 token lock |
| `hermes gateway status` 里某频道"什么都没有" | 缺 `_note_unserved_secondary_platform` |
| terminal 在错误的 backend 里跑 | 缺 `install_and_reset_profile_terminal_scope` |
| 日志全在默认 profile 目录 | 缺 `_enable_multiplex_log_routing` |
| 全机 cron 停了 | `_cron_profile_gate` 把自己 stand down 了 |
| 事件被 key 成 `agent:main` | 身份解析失败但没丢弃（漏了 fail-closed） |

---

## §10 `/login`

### 10.1 它是什么

`/login` 让用户从聊天窗口里完成 Nous 账号的登录（OAuth device flow 之类）。
这是一个"离 turn"的命令：它不跑 agent，而是走一段独立的交互。

### 10.2 三重限制

[`gateway/slash_commands_login.py:64`](../gateway/slash_commands_login.py:64)：

```python
async def _handle_login_command(self, event) -> str:
    src = event.source
    platform = str(getattr(src.platform, "value", src.platform)).lower()
    paired_dm = (
        getattr(src, "chat_type", None) in {"dm", "private"}
        and bool(getattr(src, "chat_id", None))
        and platform not in _LOGIN_BLOCKED_PLATFORMS
    )
    if not paired_dm:
        return anon_auth.LOGIN_DM_ONLY
```

三层：

1. **必须是配对好的 DM**（`dm` / `private` + 有 `chat_id`）
2. **平台不在黑名单**（`_LOGIN_BLOCKED_PLATFORMS`）
3. **如果是受限策略，必须管理员**：

```python
policy = policy_for_runner_source(self, src)
if policy.enabled and not policy.is_admin(getattr(src, "user_id", None)):
    return anon_auth.LOGIN_NOT_ALLOWED
```

为什么这么严？因为 `/login` **绑定整个安装**的 `providers.nous`。
在一个共享网关里，任何能用 bot 的人都能执行 `/login` = 他能改所有用户的 provider 凭证。

所以 `allow_admin_from` 必须配好。

### 10.3 私有的单 worker executor

```python
def _login_executor(self):
    executor = getattr(self, "_login_exec", None)
    if executor is None or getattr(executor, "_shutdown", False):
        executor = self._login_exec = concurrent.futures.ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="hermes-login")
    return executor
```

`max_workers=1` + 专用前缀。

**为什么不共享线程池**：登录流程会**长时间阻塞**（等待用户在浏览器里完成授权，
可能几分钟）。如果它占了共享池的一个 worker，而共享池被其他阻塞任务占满，
整个网关就卡住了。

单 worker 还有一个语义作用：**天然串行化**。同时只有一个登录尝试在跑。

### 10.4 每进程一次

```python
key = (str(getattr(src.platform, "value", src.platform)), str(src.chat_id),
       str(getattr(src, "user_id", "") or ""))
lock, attempts = self._login_registry()
# The private executor has one worker and the live attempt may be polling on it for the
# code's full lifetime. Trip its hook before queueing the local state read, otherwise a
# replacement command would wait behind the very attempt it needs to stop.
with lock:
    live = attempts.get(_LOGIN_SINGLE)
    if live is not None and live.key != key:
        return anon_auth.LOGIN_BUSY_ELSEWHERE
    if live is not None:
        live.cancelled = True
```

`_LOGIN_SINGLE` 是一个"单例键"——全进程只有一个登录尝试。
如果有人从另一个聊天发起，直接返回 `LOGIN_BUSY_ELSEWHERE`。

注意那段注释的精妙：单 worker executor 意味着"如果活跃尝试正在轮询（占着 worker），
新的状态读取会**排在它后面**"。所以必须**先**给活跃尝试设 `cancelled = True`
（一个 hook，它在下次轮询时会看到），**再**排队读本地状态。
顺序反了就死锁：新命令等 worker 空闲，旧尝试等用户授权，用户被新命令挡着没法操作。

### 10.5 完成后驱逐 welcome agent

登录完成后，如果一个 agent 还停在 `nous/welcome` 模型上，要**驱逐**它
（而不是写 model 覆盖）。

为什么？因为 model 是 agent 构建时决定的（07 篇讲过 system prompt 缓存，
04 篇讲过 model 解析）。写覆盖会：
- 让 agent 处于"prompt 是为旧 model 构建的、model 已经换了"的不一致状态
- 而且下次 session 恢复时覆盖还在

正确做法是让它下次重建。

---

## §11 平台目录

### 11.1 内置适配器（`gateway/platforms/`，36 个 .py）

**真正的平台**（9 个）：

```
signal  weixin  bluebubbles  qqbot  whatsapp_cloud  yuanbao  webhook  msgraph_webhook  api_server
```

**辅助模块**：

| 文件 | 作用 |
|---|---|
| `base.py`（4933 行） | `BasePlatformAdapter` 抽象基类——**所有**平台逻辑的共同部分 |
| `_shared.py` | 作用域化读取、YAML 桥接、通用小工具（见 §9） |
| `event.py` | `MessageEvent` / `MessageType` / `SessionSource` 的定义 |
| `helpers.py` | 入站去重、held-inbound 移交 |
| `media_cache.py` | 媒体文件缓存 |
| `shared_ingress.py` | 共享入站（multiplex 镜像） |
| `whatsapp_common.py` | WhatsApp 两个变体共用 |
| `yuanbao_media.py` / `yuanbao_proto.py` / `yuanbao_sticker.py` | 元宝平台细节 |
| `signal_format.py` / `signal_rate_limit.py` | Signal 格式化与限流 |
| `msgraph_webhook.py` | MS Graph webhook（Teams/Outlook） |
| `tcp_site.py` | 本地 TCP 站点 |
| `webhook_coalesce.py` / `webhook_filters.py` | webhook 合并与过滤 |
| `_http_client_limits.py` | HTTP 客户端连接池限额 |
| `access_policy_mixin.py` | 访问策略混入 |
| `base_exec_approval.py` | 执行审批（危险命令） |

**`api_server` 的六个子模块**（说明它有多复杂）：

```
api_server.py                   主适配器
api_server_openai_routes.py     OpenAI 兼容路由（/v1/chat/completions）
api_server_memory_sessions.py   记忆管理器跨请求停放（见下）
api_server_request_options.py   每请求选项
api_server_room_dispatch.py     托管房间派发
api_server_room_grants.py       房间授权
api_server_run_idempotency.py   幂等
api_server_runs.py              run 管理
api_server_turn_boundary.py     turn 边界
api_server_fire_startup.py      fire 启动
```

### 11.2 插件平台（`plugins/platforms/`，21 个）

```
a2a  buzz  dingtalk  discord  email  feishu  google_chat  irc  line  matrix
mattermost  ntfy  photon  raft  simplex  slack  sms  teams  telegram  wecom  whatsapp
```

**注意这不是"内置 vs 第三方"的分野**，而是"核心树 vs 插件树"。`telegram`、`discord`、
`slack` 这些主力平台都是**插件**。

为什么？因为：
1. 核心树要保持窄（AGENTS.md 的"不做第三方产品的载体"）
2. 插件可以独立发布、独立版本
3. `_BUNDLED_DEFAULT_ON_KINDS`（[`hermes_cli/plugins_cmd.py:798`](../hermes_cli/plugins_cmd.py:798)）
   包含 `platform`，所以随包发布的平台插件**默认启用**

```python
_BUNDLED_DEFAULT_ON_KINDS = frozenset({"backend", "platform", "model-provider"})
```

即：bundled 的 platform 插件不需要用户手动 enable。

### 11.3 `api_server` 的特殊性：每请求重建 agent，但不重建 memory provider

这是本篇最值得单独讲的一个设计。

**背景**：`api_server` 是 OpenAI 兼容的 HTTP 端点。每个 HTTP 请求都是独立的：

- 每请求的回调（流式响应写到 HTTP）
- 每请求的 model 路由（请求头里带 model）
- 每请求的临时 prompt（请求体里带 system message）

所以它**不能**用 agent 缓存（缓存的是"整个会话一个 agent"）。每个请求新建一个 `AIAgent`。

**问题**：记忆 provider 也是新建的。而外部记忆 provider 的工作原理是：

```
turn N：  用户说话 → provider.prefetch() 启动后台召回
          → turn N 结束，召回结果还存在 provider 实例里，等下次用
turn N+1：注入上次的召回结果 → 再启动新的召回
```

如果每个请求都新建 provider：
- 上一轮的召回结果**丢了**（在已销毁的实例里）
- 而且每次 init 都会重跑 provider 的启动（对嵌入式 daemon 来说是**重启**，
  还会杀掉正在进行的 retain 操作）

**解法**：[`gateway/platforms/api_server_memory_sessions.py:1`](../gateway/platforms/api_server_memory_sessions.py:1)

```python
"""Memory-provider continuity across api_server requests (#120116).
...
This registry keeps one initialised ``MemoryManager`` per (profile home, session id): a request
checks the session's manager out before building its agent (``AIAgent(memory_manager=...)``
skips provider init) and checks it back in when the turn ends. Check-out is exclusive, so two
concurrent requests on one session never share a manager; the loser's fresh manager is shut down
when it checks in behind the winner. Idle entries and LRU overflow are shut down under the owning
profile's scope, like the gateway agent cache's eviction.
"""
```

四个设计点：

1. **key = `(profile home, session id)`**——不同 profile 的同名 session 不能共用
2. **独占 check-out**——两个并发请求不能共享一个 manager（manager 是有状态的：prefetch 结果、
   drain 队列）。输了的一方在自己 check-in 时把自己新建的那个关掉
3. **turn 的 `finally` 里 check-in**——保证异常路径也归还
4. **空闲/溢出时在 owner 的 profile 作用域下关闭**——同 §9.12

**没有它会怎样**：上一轮排队的 recall 永远到不了下一个请求（#120116）。
具体表现是"跨会话记忆在 API 模式下完全不工作"，而且不报错。

### 11.4 新增一个平台要做什么

见 [`gateway/platforms/ADDING_A_PLATFORM.md`](../gateway/platforms/ADDING_A_PLATFORM.md:1)。

大致清单（不需要改任何核心文件）：

1. 写一个 `BasePlatformAdapter` 子类
2. 声明能力布尔值：`supports_code_blocks` / `supports_status_text` /
   `supports_async_delivery` / `splits_long_messages` / `typed_command_prefix` /
   `supports_inchannel_continuable`
3. 实现 `connect()` / `disconnect()` / `send()` / `send_draft()`（可选）
4. 实现平台事件 → `MessageEvent` 的转换
5. 用 `get_scoped_secret` 读凭证、`platform_gate_env` 读授权
6. 用 `extra_or_secret` 读设置
7. `connect()` 里 `acquire_scoped_lock()`，`disconnect()` 里 `release_scoped_lock()`
8. 在 `connect()` 里调用 `self._canonicalize(source)`（或确保通过 `build_source`）
9. 注册到 `platform_registry`

**不需要**改的：`run.py`、`run_inbound.py`、`run_turn.py` 等任何核心文件。
如果发现需要改核心，说明设计漏了——先查是不是可以用能力标志表达。

---

## §12 Slash 命令在网关

### 12.1 按名字查表，没有 if 链

[`gateway/run_busy.py:924`](../gateway/run_busy.py:924)：

```python
_command_handler_table   # dict[str, handler]
_BUSY_SPECIAL_HANDLERS   # dict[str, handler]
```

AGENTS.md 明说：**没有 `if canonical == ...` 链**。

为什么？因为命令有 ~103 个（见 05/02 篇）。if 链会：
- 无法静态检查（"这个命令有 handler 吗"）
- 新命令容易漏
- 每次加命令都改同一个巨型函数（合并冲突）

### 12.2 命令注册表

[`hermes_cli/commands.py:83`](../hermes_cli/commands.py:83) 的 `COMMAND_REGISTRY`。

每个 `CommandDef` 的完整字段（[:45](../hermes_cli/commands.py:45) 附近）：

| 字段 | 作用 |
|---|---|
| `name` | 规范名 |
| `aliases` | 别名 |
| `description` | 帮助文本 |
| `category` | 分组（用于 `/help`、desktop 命令面板） |
| `busy_policy` | `dispatch` / `reject` / `interrupt_then_dispatch` |
| `busy_handler` | 忙碌时的特殊处理 |
| `gateway_config_gate` | 网关里是否可见（按配置） |
| `desktop_subcommands` | 桌面端的子命令 |

### 12.3 三个界面共用一份注册表

CLI（`/help` 列表）、TUI（命令面板）、Desktop（slash palette）、网关（派发）——
全部读 `COMMAND_REGISTRY`。

这就是"能力在边缘，注册在中心"的具体体现：**数据在中心，行为在各处**。

### 12.4 新增命令

完整步骤见 [`hermes_cli/AGENTS.md:42`](../hermes_cli/AGENTS.md:42)。核心几点：

1. 在 `COMMAND_REGISTRY` 加一个 `CommandDef`（声明 `busy_policy`）
2. 在网关的 `_IDLE_COMMANDS` 或 `_PLAIN_COMMANDS` 里归类
3. 在 `_command_handler_table` 或对应的 mixin 里实现
4. 如果它需要"在 agent 阻塞时到达"，确认 `should_bypass_active_session` 覆盖它
   （现在覆盖所有可解析命令，所以默认就有）
5. 加不变量测试

---

## §13 测试约定

### 13.1 位置

测试放 `tests/gateway/`。

### 13.2 三条硬规则

1. **适配器测试用假 transport 走真实交付路径**。
   不要 mock `send()`，要 mock 更底层的 transport（HTTP 客户端 / websocket）。
   这样 `send_with_retry`、切分、限流、delivery ledger 记账都在测试里跑。
   直接 mock `send()` 的测试永远发现不了"忘了打 `_interim_send`"。

2. **绝不**断言硬编码的平台清单或命令数量。
   根规则：禁 change-detector 测试。
   ```python
   # 错误
   assert len(PLATFORMS) == 26
   # 正确
   assert Platform.TELEGRAM in PLATFORMS
   ```

3. **session-key 与守卫行为值得写不变量测试**。
   比如 `tests/gateway/test_multiplex_transport_matrix.py` 的拓扑矩阵——
   每一行是一个"必须永远成立"的事实，不是因为某次实现碰巧如此。

### 13.3 平台 API 怪癖放哪里

> 平台 API 怪癖放在 connector 注释 + 测试里，不放在散文里。

意思是：Slack 的 `stopStream.markdown_text` 是追加的——这条知识应该在
`plugins/platforms/slack/` 的代码注释里，和一个测试里（测试验证"传两次不会重复"）。
如果只写在某个文档里，改代码的人看不到。

（本文档里引用这些，只是**索引**，不是权威来源。）

### 13.4 平台特定行为用 marker

按根 AGENTS.md：`@pytest.mark.platforms(...)`，**绝不** fake `sys.platform`。
原因：fake 出来的分支从不和真实平台一致，测试通过但线上挂。

---

## §14 自检题

按主题分组。答案在正文对应小节。

### A. 为什么需要网关

1. CLI 的三条隐含前提是什么？网关推翻了哪三条？
2. "每个平台一个 agent 进程"会在哪三个方面爆炸？
3. 画出"平台 → 适配器 → GatewayRunner → AIAgent"的四层结构，标出哪层知道平台细节。
4. 消息平台和终端有哪八个关键差异？各举一个由此产生的设计。

### B. 代码形状

5. `gateway/run_*.py` 有多少个？`run.py` 有多少行？为什么要拆？
6. rachet 规则对文件大小和函数复杂度分别是什么限制？
7. 网关读配置走 `DEFAULT_CONFIG` 吗？不走会导致什么症状？
8. 适配器实例化时，"插件注册了但创建失败"会回退到内置吗？为什么？

### C. 启动

9. 启动序列的 8 个步骤是什么？
10. `_BUILTIN_ADAPTERS` 的第四个元组元素是什么？为什么在那里？
11. `platform_toolsets` 的三层优先级是什么？为什么子 profile 的 toolsets 要"被裁剪"而不是"被信任"？
12. 一个平台连不上时，用户从哪里能看到原因？

### D. 入站

13. `handle_message` 里"同步装守卫再 spawn"防的是什么？如果改成 `create_task` 再装呢？
14. `_hm_admit_event` 的七道门按顺序列出来。为什么"忽略频道"要排在"授权"前面？
15. 门 0 的 `reset_session_vars()` 防的是什么？给一个具体的串台场景。
16. 用 `getattr(x, "attr", False) is True` 而不是 `if getattr(...)` 的原因是什么？
17. 授权失败的四条分支各是什么？为什么"没有 `user_id`"直接静默丢弃？
18. `_AGENT_PENDING_SENTINEL` 解决什么问题？`None` 和 `sentinel` 语义有什么不同？
19. `run_generation` 解决什么问题？举一个 ABA 的具体时序。

### E. 双守卫

20. 两个守卫分别在哪一层？各自拦什么？
21. `/new` 被排队会怎样？`/approve` 被排队会怎样？两者是同一类问题吗？
22. 为什么不能用 `_process_message_background()` 处理 bypass 命令？
23. `should_bypass_active_session` 的真实语义是什么（不是名字表面）？为什么所有命令都 bypass？
24. `busy_policy` 三个值分别是什么？谁用 `interrupt_then_dispatch`？
25. `_PLAIN_COMMANDS` 和 `_IDLE_COMMANDS` 和 `busy_policy` 是同一套分类吗？
26. 为什么除了进程内锁还需要跨进程槽位？哪四个进程可能碰同一个 session？
27. `live_session_id` 在槽位里起什么作用？

### F. 流式

28. "草稿模式"和"流即消息"的区别是什么？Telegram 和 Slack 各是哪种？
29. `draft_stream_is_message` 为什么硬编码成 Slack？曾经设成所有 draft connector 会怎样？
30. 四条不变量逐条复述，并给每条一个"违反后的症状"。
31. 为什么 seal 拦截要在 `send()` **和** `send_for_platform()` 两处都做？
32. `_interim_send` 是给谁看的？出网前要做什么？
33. `delivered_final_matches` 为什么是**三态**而不是布尔？`None` 对应什么情况？
34. "`edit_message` 返回成功 ≠ 已交付"的原因是什么？
35. `_delivery_ambiguous` 时为什么选"不重发"？这个取舍的不对称性在哪？
36. Slack 流式 API 的三个反直觉事实是什么？
37. `_stream_is_message` 为什么要 per-chat 探测而不是用类属性？为什么要从**类**上取 `probe`？

### G. 出站

38. cron 投递为什么不直接由 worker 发？
39. `DeliveryQueueWatch` 为什么监视 `-wal` 文件？
40. 为什么排空后不重置戳（接受一次多余空跑）？
41. delivery ledger 的五个状态各是什么？`attempting` 的重发为什么要带标记？
42. 为什么选"诚实的至少一次"而不是"精确一次"？
43. `MAX_PLATFORM_OUTPUT = 4000` 而不是 4096 的原因？哪类 adapter 绕过它？

### H. 通知

44. 后台进程完成时为什么要开新 turn，而不是发一条消息？
45. `admit_internal_event` 的回执精确表示什么？（四个"不表示"）
46. 为什么 `api_server` 的唤醒要自我 POST？不这么做会创建什么？
47. async-delegation 完成事件为什么**不**自我 POST？可能跨过什么？
48. 为什么"宁可重复不可静默丢弃"？（两处例子）
49. 被拒准入时为什么要退还 batch sibling 且不消耗尝试次数？
50. Discord 后台完成消息为什么会引用一条 3 小时前的消息？怎么修的？

### I. 生命周期

51. `hermes serve` 和 `gateway run` 的生命周期差异是什么？谁 spawn 谁？
52. POSIX 和 Windows 分别用什么方式 detach？
53. 两条"不要去修"的警告各是什么？各自的错误修法会造成什么？
54. `code_sha` 写进 `gateway_state.json` 解决什么问题？

### J. Profile 作用域

55. 在 multiplex 下，`os.environ` 持有哪个 profile 的值？为什么不能把所有 profile 的 `.env` 都塞进去？
56. `RoutingIdentity` 的六个字段各是什么？身份三问分别对应哪几个字段？
57. 为什么 identity 要冻结 + 每事件只解析一次？如果每个消费者各读各的会怎样？
58. 已知的三个规范化缝在哪？为什么 runner 侧也要有（不只适配器侧）？
59. 身份解析失败时为什么必须**丢弃**而不是降级到默认 profile？降级的两个后果是什么？
60. `_intake_adapter_for` 对没有 live provenance 的 source fail closed 到 `None`，为什么不能"选一个最像的"？
61. 两条 resolver 禁令是什么？各违反会怎样？
62. 复述五拓扑矩阵。
63. 为什么 `SessionEntry` 要同时有 key 命名空间和 `transport_profile` 列？
64. token lock 的两个"反直觉"实现细节是什么？各自防的是哪个 bug？
65. 空 lock 文件为什么会造成永久死锁？在哪处理的？
66. `get_scoped_secret` 的三种情况分别读到什么？为什么 scoped miss 不能回退到 `os.environ`？
67. #86905 的具体症状是什么？
68. "YAML→env bridges are first-writer-wins" 是什么意思？导致什么问题？
69. 为什么禁止 `try get_secret / except: os.getenv` 这种写法？它"看起来"合理在哪？
70. `_profile_runtime_scope` 做哪三件事？为什么第三件（terminal scope）不能省？
71. `_run_release_in_profile_scope` 的两个陷阱分别是什么？用裸 `threading.Thread` 会怎样？
72. 为什么 owner fallback 用 `get_default_hermes_root()` 而不是 `get_hermes_home()`？
73. `multiplex_profiles: false` 时还需要作用域吗？什么情况下会需要？
74. hooks 的路径为什么不能在模块级计算？
75. `apply_yaml_bridge` 在次要 profile 下做什么？为什么？
76. `extra_or_secret` 处理的三个易错点是什么？
77. 未服务的平台"报告不要静默"具体怎么落地？
78. `SHARED_LISTENER_MIRROR_PLATFORMS` 为什么只能有一个监听端口？次要 profile 怎么访问？
79. "这个任务服务路由 profile 吗"为什么要用 `get_routing_process_hermes_home()`？
80. `_cron_profile_gate` 的三层洞察是什么？最精妙的"自指"陷阱是什么？
81. 日志路由在什么条件下生效？为什么单 profile 下是 no-op？

### K. `/login`

82. `/login` 的三重限制是什么？为什么这么严？
83. 为什么用私有单 worker executor 而不是共享池？（两个理由）
84. "先设 cancelled 再排队读状态"的顺序为什么不能反？
85. 登录完成后为什么驱逐 agent 而不是写 model 覆盖？

### L. 平台

86. 列出 9 个内置平台和 21 个插件平台。主力平台（telegram/discord/slack）属于哪一类？
87. `_BUNDLED_DEFAULT_ON_KINDS` 是什么？为什么 `platform` 在里面？
88. `api_server` 为什么不能复用 agent 缓存？它每请求重建什么、不重建什么？
89. `ApiServerMemorySessions` 的 key 是什么？为什么要独占 check-out？
90. 没有 `ApiServerMemorySessions` 会有什么症状？（要具体）
91. 新增一个平台需要改核心文件吗？列出大致步骤。

### M. 命令与测试

92. 为什么用查表而不是 if 链？
93. 一份注册表被哪四个界面共用？
94. 为什么适配器测试要 mock transport 而不是 mock `send()`？
95. 为什么不能断言平台数量？

### N. 综合

96. 一个用户报告"我在 work profile 里被 bot 拒绝访问"。列出你会检查的至少五个地方。
97. 一个用户报告"我的流式输出结束时会重复一条完整答案"。哪条不变量可能被违反？怎么确认？
98. 一个用户报告"cron 任务跑完了但消息晚了一分钟"。两处可能的根因？
99. 一个用户报告"桌面关掉后 bot 就不回消息了"。错的修法是什么？正确应该检查什么？
100. 一个开发者说"我要在适配器里直接 `os.getenv("TELEGRAM_TOKEN")` 更简单"。用三点反驳。
101. 如果让你给网关加一个"Slack 表情回应也要作为输入"的功能，你会改哪里？会不会改核心？
102. 为什么 `gateway/run_shutdown.py` 有 2265 行？关个机为什么这么复杂？（提示：台账、lease、排空、通知）

---

## §15 小结与下一步

### 六条核心结论

1. **网关 = 长驻进程 + 适配器 + 统一路由**。它的存在是因为 CLI 的三条隐含前提（有终端、
   同步等待、输出到 stdout）在消息平台上全不成立。适配器吸收平台差异，核心保持窄腰。

2. **双守卫是必须的**：适配器层的 `_active_sessions` 挡"同时两个 agent"，
   runner 层挡"绕过适配器的事件"。守卫必须**同步**装上再 spawn。
   任何"agent 阻塞时必须到达"的命令要**内联派发**，绝不走 `_process_message_background()`。

3. **`should_bypass_active_session` 的语义比名字大得多**：所有可解析命令都 mid-run 派发，
   绝不入队。入队的后果是零字符响应（#5057）。

4. **流式四条不变量来自真实事故**。前缀稳定、消费方声明最终结果、interim 要打标、
   用 edit 对账。seal 拦截必须在 `send()` 和 `send_for_platform()` **两个**出口。

5. **交付要诚实**。`delivered_final_matches` 三态（不是布尔）、delivery ledger 的
   `attempting` 带可见标记、宁可重复不可静默丢弃。这些都是"分布式投递没有精确一次"的
   现实妥协。

6. **Profile 作用域是网关最深的坑**。`os.environ` 只有默认 profile 的值；
   身份每事件解析一次并钉住；凭证/授权/terminal/hooks/logs 全部要作用域化；
   **每一条**没有 turn 的异步路径都要显式进作用域。

### 一句话给别人讲明白

> 网关是一个长驻多路复用器：它用适配器把 20 多个消息平台翻译成统一事件，
> 用 session_key 把消息归到会话，用两个守卫保证同一会话不并发，
> 用流式契约和投递台账保证回复不重复不丢失，
> 并且在一个进程里服务多个 profile 时，靠"每事件解析一次身份 + 所有读取显式进作用域"
> 来避免跨 profile 的静默泄漏。

### 下一步

- 想了解四个前端面（CLI / TUI / Desktop / Web）各自怎么和这套东西交接
  → [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md)
- 想看 profile 和 multiplex 的整体设计（不只网关侧）
  → [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)
- 想看 hygiene 压缩（网关侧的 85% 安全网）的完整机制
  → [`08-memory-context-compression.md`](08-memory-context-compression.md)
- 想自己写一个平台适配器
  → [`../gateway/platforms/ADDING_A_PLATFORM.md`](../gateway/platforms/ADDING_A_PLATFORM.md)
- 想看长文背景
  → [`../website/docs/developer-guide/gateway-internals.md`](../website/docs/developer-guide/gateway-internals.md)
