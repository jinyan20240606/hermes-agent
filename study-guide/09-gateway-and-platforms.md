# 09 · 消息网关与多平台适配

> 目标：理解网关的进程模型、双消息守卫、流式交付契约、以及 profile 作用域的复杂性。

---

## 1. 网关是什么

一个**长驻进程**，把约 20+ 个消息平台（Telegram、Discord、Slack、WhatsApp、Signal、Email、
Matrix、Feishu、IRC ...）接入同一个 `AIAgent` 内核。

职责聚合：
- 平台适配器（built-in `gateway/platforms/` + 插件 `plugins/platforms/`）
- 统一会话路由
- 用户授权（allowlist + DM 配对）
- slash 命令派发
- hook 系统
- cron tick
- 后台维护

长文文档：[`gateway-internals.md`](../website/docs/developer-guide/gateway-internals.md:1)。
新平台适配器指南：[`ADDING_A_PLATFORM.md`](../gateway/platforms/ADDING_A_PLATFORM.md:1)。

---

## 2. 代码形状

[`gateway/run.py`](../gateway/run.py:1) 是门面，相位在 `run_*.py`：

| 兄弟 | 主题 |
|---|---|
| `run_startup*` | 启动 |
| `run_adapters.py` | 适配器装配/规范化 |
| `run_inbound.py` | 入站事件准入 |
| `run_turn.py` | turn 执行（含 session hygiene） |
| `run_busy.py` | 忙碌时命令（`_IDLE_COMMANDS` / `_PLAIN_COMMANDS`） |
| `run_goals.py` | 目标 |
| `run_notifications.py` | 通知（后台进程 watcher） |
| `run_shutdown.py` | 关闭 |
| `session*.py` | 会话存储/缓存 |
| `slash_commands_*.py` | slash mixins |
| [`authz_mixin.py`](../gateway/authz_mixin.py:1) | 授权 |
| [`platforms/base.py`](../gateway/platforms/base.py:1) | 适配器基类 |

**关键差异**：网关读用户 YAML **原始文件**（`run.py` + `config.py`），**不**经过 `DEFAULT_CONFIG`。
「CLI 看到某 key 但网关看不到」通常是你用错了 loader。

每个适配器选一个**基础 toolset**（Telegram → `"messaging"`）。

---

## 3. 双消息守卫（必须理解）

Agent 正在运行时，一条入站消息要穿过**两个顺序守卫**
（[`gateway/AGENTS.md`](../gateway/AGENTS.md:20)）：

1. **基础适配器**（[`platforms/base.py`](../gateway/platforms/base.py:1)）：
   当 `session_key in self._active_sessions` 时，把消息排进 `_pending_messages`
2. **runner**（`run.py`/`run_busy.py`）：
   在它们到达 `running_agent.interrupt()` **之前**拦截
   `/stop`、`/new`、`/queue`、`/status`、`/approve`、`/deny`

> **关键规则**：任何必须在 agent 阻塞时（审批提示）到达 runner 的新命令，
> **必须绕过两个守卫并内联派发**——绝不走 `_process_message_background()`（它会与会话生命周期竞争）。

---

## 4. 流式交付契约（`draft_stream_is_message` 适配器）

带 `draft_stream_is_message = True` 的适配器（如 relay Slack 原生流式）**每轮保持一条累积的原生流**；
**流本身就是最终消息**。

四条不变量，每条都来自一次真实的重复最终消息事故（NS-658 canary ledger，
hermes#85796 / gateway-gateway#210）。违反任意一条都会重现重复或冻结的流：

1. **草稿帧前缀稳定。** 第 N 帧必须是第 N+1 帧的字符串前缀。
   绝不每 tick 修改草稿——不做 fence 闭合、不做光标后缀、不在工具边界重置段状态、不做 mrkdwn 转换。
   非前缀帧会强制整快照重扫（"stacked copies"）。finalize 路径仍可变换真正的最终消息。
2. **消费方声明最终结果；适配器永不猜测。** `finish(final_text)` 携带完成的 `final_response`
   （含 verifier footer、completion explainer）。**新的流后增强必须搭这个 payload 的车**——
   在 seal 之后改 `final_response` 会重新打开 `delivered_final_matches` 不匹配 → 纠正性重复发送。
3. **中间发送必须带 `metadata["_interim_send"] = True`。** 任何消费方侧的 `adapter.send()`
   如果不是 turn 最终（commentary、段尾刷新）都必须设置它，否则 seal 拦截会用中间文本封住活流。
   seal 拦截在**两个出口**（`send()` 与 `send_for_platform()`）都存在；新增出口需要同样两处检查。
4. **用编辑对账，绝不用普通发送。** 一条在已封流旁边投递最终结果的通道（排队的后续、带媒体的最终），
   先在消费方的 `message_id` 上试 `edit_message`；只有在没有可编辑消息时才用普通 `send()`。
   已封的原生流就是普通消息——`chat.update` 可以工作（已实测）。

来源：[`gateway/AGENTS.md`](../gateway/AGENTS.md:30)

Slack 的真相：`chat.*Stream` 说的是**标准 markdown**，不是 mrkdwn；
`stopStream.markdown_text` 是**追加**；`startStream`/`stopStream` 是 Tier 2（~20/min）。

契约测试：`tests/gateway/test_stream_final_contract.py`（做变异检查）。

---

## 5. 后台进程通知

`terminal(background=true, notify_on_complete=true)` 会在网关循环上装一个 watcher
（[`gateway/run_notifications.py`](../gateway/run_notifications.py:1) 的 `arm_process_watcher`），
完成时**开始一个新的 turn**。

- 详细程度由 `display.background_process_notifications` 控制
- 注入需要 `admit_internal_event` 回执（handler 返回 None **不算**接受）
- 被拒绝准入会退还每个已认领的 batch sibling，且不消耗尝试次数

---

## 6. 网关生命周期 vs 桌面应用（易踩的坑）

- `hermes serve`（控制平面，桌面 spawn 的子进程）**随应用而死**——设计如此
- 消息网关（`gateway run`）**存活于应用之后**：serve 后端的 `/api/gateway/*` 端点以 detached 方式 spawn 它
  （`start_new_session` / `DETACHED_PROCESS`），所以 `before-quit` 的 SIGTERM 到不了它，机器人继续跑

> **不要**为了「修复 gateway 随应用而死」而把网关重新挂到 backend 下；
> **也不要**为了「修复更新锁」而扩大 tree-kill。

网关把 `code_sha`/`code_version` 写进 `gateway_state.json`（[`gateway/status.py`](../gateway/status.py:1)），
让更新器能校验整个 fleet。

---

## 7. Profile 作用域（网关最复杂也最重要的部分）

**一个进程服务多个 profile**，这是所有 profile 相关 bug 的根源类别。

### 7.1 每个入站事件一个身份，且先规范化

[`gateway/session_identity.py`](../gateway/session_identity.py:1) 的 `resolve_identity`
**对每个事件只回答一次**「哪个 bot 收到它 / 谁可以准入 / 它在哪运行」，
并把冻结的 `RoutingIdentity` 钉在 source 上（wire 不可见）。

每条 ingress 路径在派生 key **之前**调用规范化缝：
- 适配器侧（`platforms/base.py::_canonicalize`）
- runner 侧（`run_adapters.py::_canonicalize`、`run_inbound.py::_hm_admit_event`）

**在它之前不得派生 key**；multiplexing 下未解析的身份（路由到未被服务的 profile）
会在到达的第一个缝处以一条 WARNING 丢弃，**绝不被 key 成 `agent:main`**。

注意 `transport_profile` ≠ `runtime_profile` 是正常的（共享 bot → 路由卫星）。

### 7.2 接收适配器 vs 交付适配器

[`authz_mixin.py`](../gateway/authz_mixin.py:1)：

- `_intake_adapter_for(source)`：**收到**事件的 bot（live transport ref → relay socket → 身份的 `transport_profile`）。
  它门控准入策略，对没有 live provenance 的 source **fail closed 到 `None`**。
- `_delivery_adapter_for(source)`：**回答**的 bot——已知时用接收 bot，
  否则通过 `_adapters_for_profile` 找 `(platform, runtime_profile)` 的唯一 owner。

> **绝不读 `self.adapters[platform]`**；**绝不加第三个 resolver**。

拓扑矩阵（`tests/gateway/test_multiplex_transport_matrix.py`）：

| 拓扑 | runtime | intake | delivery |
|---|---|---|---|
| 每凭证 bot，无路由 | owner | owner 适配器 | owner 适配器 |
| 共享凭证 → 卫星（`profile_routes`） | routed | 接收适配器 | 接收适配器 |
| 共享 bot → 拥有自己 bot 的 profile | routed | 接收适配器 | 接收适配器 |
| 次要拥有的 bot → `default`（`bot_profile`） | default (`agent:main`) | 接收适配器 | 接收适配器 |
| 恢复/手工构造，无 live provenance | 存储的 `source.profile` | **`None`** | `(platform, runtime)` 唯一 owner |

### 7.3 身份要能熬过进程重启

`SessionEntry.transport_profile`（路由索引 + `sessions.transport_profile` 列，可空）
持久化**接收 bot**，紧挨 key 命名空间：
- **命名空间**说这条 lane 在哪**运行**
- **列**说哪个 bot 可以向它**投递**

### 7.4 Token 锁

用唯一凭证（bot token、API key）连接的适配器在 `connect()`/`start()` 调用
`acquire_scoped_lock()`，在 `disconnect()`/`stop()` 调用 `release_scoped_lock()`，
这样两个 profile 不能共享一个凭证。范本：[`plugins/platforms/irc/adapter.py`](../plugins/platforms/irc/adapter.py:1)。

### 7.5 Multiplex 下 profile 级 env 读取必须 fail closed

这是最重要的一条（#72348、#86905）：

> 在 `gateway.multiplex_profiles` 下，**`os.environ` 持有默认 profile 的值**；
> 次要 profile 的 `.env` 只存在于它的 secret scope 里。

- **所有** profile 级 env 配置——凭证（`app_secret`、tokens）**和**授权
  （`FEISHU_ALLOWED_USERS`、`{PLATFORM}_ALLOW_ALL_USERS`、`GATEWAY_ALLOW_ALL_USERS`、
  `group_policy`、`allow_bots`）——都必须**作用域感知**地读
- 适配器通过 [`gateway/platforms/_shared.py`](../gateway/platforms/_shared.py:1) 的 `get_scoped_secret`
  （**唯一实现**；适配器以 `_get_scoped_secret` 名字 import）
- 网关授权通过 `_shared.platform_gate_env`（`authz_mixin.py` 以 `_auth_env` import）
- **作用域已安装 + multiplex 激活 → 作用域 miss 返回 `default`，绝不返回 `os.environ`**
  （泄漏的 allowlist 会跳过 allow-all 检查并静默拒绝每个次要 profile 的发送者，#86905）
- 未作用域的默认 profile 路径（`UnscopedSecretError`）与单 profile 部署**保留 `os.environ` 读取**——
  那**就是**该 profile 自己的值

> **绝不**在适配器里重新实现 reader——
> `try get_secret / except UnscopedSecretError: os.getenv` 这种形状会漂移成「miss 后回退」的泄漏。
> 用共享的那个。

### 7.6 作用域按 profile **活动**绑定，而不是按 turn

[`gateway/run.py`](../gateway/run.py:1) 的 `_profile_runtime_scope(home)` 包裹一个路由 turn；
同样的绑定包裹**每一条**触碰会话 home、secrets 或 terminal scope 而栈上没有 turn 的路径：

| 路径 | 位置 |
|---|---|
| 释放与驱逐 | `run_agent_cache.py::_run_release_in_profile_scope`（TTL、LRU、内存压力驱逐都走它） |
| 关闭 | `run_shutdown.py::_finalize_session` |
| turn 后媒体投递 | `platforms/base.py::_media_delivery_scope` |
| 延迟回调 | pickers、reactions（在命令时捕获路由 home，在回调里重入作用域） |
| 通知器与外发 webhook | — |

**为什么**：在启动作用域下做的驱逐会把次要 profile 的记忆写进默认 profile 的 store，**静默地**。

### 7.7 其它容易忽略的点

- `multiplex_profiles: false` **不是**「永不设作用域」：原生托管 room 在网关进程内翻转
  进程级守卫（`tui_gateway/launch_profile_policy.py::activate_multi_profile_hosting`）
- hooks 与 observers **按被服务的 profile 注册**（idempotence key 含 profile，
  且 `hooks/` 路径在**调用时**解析——模块常量会冻到第一个 importer）
- 适配器 YAML 在 multiplex 下**永不**进 `os.environ`（走 `apply_yaml_bridge`）
- 未被服务的平台**要报告，不要静默**（`_note_unserved_secondary_platform`）
- WhatsApp 桥是**每 profile** 的：已配对的次要 profile 得到自己的适配器与端口
- 「这个任务服务路由 profile 吗？」比较的是 `hermes_constants.get_routing_process_hermes_home()`，
  **绝不** live 读 `os.environ["HERMES_HOME"]`

---

## 8. `/login`（离 turn、仅限配对的 DM）

`GatewayLoginCommandsMixin` 拒绝在真实配对 DM 之外执行，
并绑定**整个安装**的 `providers.nous`，所以共享网关必须设置 `allow_admin_from`。

它在私有的单 worker `_login_executor`（**绝不**用共享池）上排空 `anon_auth.run_sign_in`，
每进程只允许一次尝试，完成后驱逐仍在 `nous/welcome` 上的 agent，而不是写 model 覆盖。

---

## 9. 平台目录一览

### 9.1 内置适配器（`gateway/platforms/`）

```text
signal, weixin, bluebubbles, qqbot, whatsapp_cloud, yuanbao, webhook, api_server
```

辅助模块：`base.py`、`_shared.py`、`event.py`、`helpers.py`、`media_cache.py`、
`shared_ingress.py`、`whatsapp_common.py`、`yuanbao_*.py`、`msgraph_webhook.py` 等。

### 9.2 插件平台（`plugins/platforms/`）

```text
a2a, buzz, dingtalk, discord, email, feishu, google_chat, irc, line, matrix,
mattermost, ntfy, photon, raft, simplex, slack, sms, teams, telegram, wecom, whatsapp
```

### 9.3 api_server 的特殊性

`api_server` 适配器**每请求重建 agent 但不重建 memory provider**：
它绕过 `TurnRunner` 和 agent 缓存（每请求回调、model 路由、临时 prompt），
所以 [`gateway/platforms/api_server_memory_sessions.py`](../gateway/platforms/api_server_memory_sessions.py:1)
在请求之间停放每个会话已初始化的 `MemoryManager`
（`_create_agent` 独占 check-out，turn 的 `finally` check-in，key 为 profile home + `agent.session_id`）。

**没有它，上一轮排队的 recall 永远到不了下一个请求**（#120116）。

---

## 10. Slash 命令在网关

处理器通过 `_command_handler_table` **按名字**查找；
命令登记在 [`gateway/run_busy.py`](../gateway/run_busy.py:1) 的 `_IDLE_COMMANDS` 或
`_PLAIN_COMMANDS`（后者可 mid-run 工作）。**没有 `if canonical == ...` 链。**

注册表与新增命令的完整步骤见 [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:42)。

---

## 11. 测试约定

- 测试放 `tests/gateway/`
- 适配器测试用**假 transport 走真实交付路径**
- **绝不**断言硬编码的平台清单或命令数量（根规则：禁 change-detector）
- session-key 与守卫行为**值得**写不变量测试
- 平台 API 怪癖放在 connector 注释 + 测试里，不放在散文里

---

## 12. 本篇小结与下一步

- 网关 = 长驻进程 + 适配器 + 双守卫 + 统一路由。
- **流式契约四条不变量**来自真实事故，务必遵守。
- **Profile 作用域**是网关最深的坑：`os.environ` 只有默认 profile 的值。
- 接收适配器 vs 交付适配器是两件事；身份每事件只解析一次。

下一步 → [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md)：四个前端面。
