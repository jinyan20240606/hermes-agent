# 13 · 子代理与委派

> 目标：理解 `delegate_task` 的隔离模型、同步/后台两条路径、以及停止扇出与生命周期的坑。

---

## 1. 入口：`delegate_task`

[`tools/delegate_tool.py`](../tools/delegate_tool.py:1) 是核心实现（+ 若干 `delegate_tool_*.py` 兄弟）。

**做什么**：spawn 一个带**隔离上下文 + 隔离终端会话**的子代理。
父代理**等待摘要**，除非 `background=true`。

- `background=true` 时立即返回一个 delegation id，
  并通过 **async-delegation completion queue** 把结果重新注入

长文 API 文档：[`subagent-lifecycle-api.md`](../website/docs/developer-guide/subagent-lifecycle-api.md:1)。

---

## 2. 两种调用形状

### 形状 1：单个

```python
delegate_task(goal="...", context="...", toolsets=[...])
```

### 形状 2：批量

```python
delegate_task(tasks=[...])
```

并发被 `delegation.max_concurrent_children` 限制（默认 3）。

---

## 3. 后台批次的「完成单元（completion units）」

来自 [`tools/AGENTS.md`](../tools/AGENTS.md:130)：

- 一个后台批次**默认作为一个** completion 返回
- 开启 `delegation.independent_completions` 后，它被拆成 completion **单元**
  （`delegate_tool_dispatch._units_of`）：
  - 共享一个 `group` 的任务**合并**并一起上报
  - 每个未分组任务**自己单独**上报，完成即报

### 3.1 单元与容量的关系（容易搞错）

- 一次调用的单元**共享一个池 slot**（`async_delegation._dispatch` 里的 `slot_key`）
  ——**绝不**把单元计入容量
- 执行器按**活跃单元数**定尺寸
- 卡住时钟在这 runner **启动**时起算，所以排队的单元永不被判定为卡住

---

## 4. 角色（Roles）

| 角色 | 保留的工具 | 说明 |
|---|---|---|
| **`leaf`**（默认） | 无 `delegate_task`、`clarify`、`memory`、`send_message`、`cronjob`、`start_chat`；**保留 `execute_code`** | 叶子 |
| **`orchestrator`** | 保留 `delegate_task` | 由 `delegation.orchestrator_enabled` 门控，由 `delegation.max_spawn_depth` 限制（默认 2） |

---

## 5. 配置旋钮（`delegation:`）

```yaml
delegation:
  max_concurrent_children: 3
  independent_completions: false
  max_spawn_depth: 2
  child_timeout_seconds: ...
  orchestrator_enabled: ...
  subagent_auto_approve: ...
  inherit_mcp_toolsets: ...
  max_iterations: ...
```

---

## 6. 子进程（Child Processes）

### 6.1 生命周期

- 子进程的后台进程**在它的 teardown 时被杀**，它们的通知在父进程里被**抑制**

### 6.2 handoff（移交所有权）

- `process_manage(action="handoff")`（**仅子进程可用**）在 registry 锁下
  把 `ProcessSession.owner_task_id` 翻转为父进程
  （`process_registry.transfer_ownership`），这样 completion 按**新 owner** 路由与回收

### 6.3 结果上的账目

- 未移交的遗留进程落在结果上作为 `orphaned_processes`
- 已退出但从未被读取的 notify 进程作为 `unread_completions`
- 都由 `_ChildRun.account_background_processes` 在 `cleanup` 杀掉它们**之前**计算

---

## 7. 子内核（Child Kernels）

子进程的 `execute_code` 内核以 `<parent-owner>::child::<child-session-id>` 为 key：

- 在子进程运行期间对 `max_session_kernels` 的 LRU 上限**钉住**
- 由 `cleanup` 销毁（`code_kernel.shutdown_kernels_for_delegated_child`）
- **绝不让**已结束子进程的内核霸占上限

---

## 8. `output_schema`

一次重试后仍未命中：

- 保持 `status: completed`
- 原始文本放在 `summary` 里
- 加 `schema_valid: false` / `schema_errors` / `schema_note`

> **绝不丢弃子进程的结果。**

---

## 9. 持久性（Durability）

**后台委派是进程本地的。**

必须熬过重启的工作要用：
- `cronjob`，或
- `terminal(background=True, notify_on_complete=True)`

---

## 10. Heartbeat

`heartbeat=N` 在同一次 spawn 上会发一个 `heartbeat` 事件
（completion queue 上的类型；只含 delta 输出；`HEARTBEAT_MIN_SECONDS` 下限；
所有 session 共用一个守护定时线程，在 `process_registry.py::ProcessRegistry._heartbeat_loop`）。

> **每个渲染 `watch_match` 的界面都必须渲染 `heartbeat`**：
> `process_registry_notifications.py`、`gateway/run.py::_drain_gateway_watch_events`、
> `tui_gateway/session_notifications.py::_DEDUP_EXTRA_FIELDS`。

---

## 11. 停止扇出（Stop Fan-out）——最容易漏的一环

- 一轮的**硬中断只到达 `_active_children`**
- 后台单元在派发时是**脱离**的

所以**每一个**停止面都必须额外调用 `async_delegation.interrupt_for_session`：

| 停止面 | 位置 |
|---|---|
| gateway `/stop` | busy **与** idle 两条路径 |
| TUI | `session.interrupt` |
| ACP | `cancel` |
| CLI | `/stop`（经 `interrupt_all`） |

**深度 > 0 的委派永远是同步的**（`_model_background_value`），
所以停止会通过子进程自己的 `_active_children` 扇出递归下去。

被中断条目的 `summary` 是子进程**最后一段真实 assistant 文本**（`_build_result_entry`）。

---

## 12. 隔离机制：`delegation_context.py`

[`agent/delegation_context.py`](../agent/delegation_context.py:1) 是关键模块：

| 符号 | 用途 |
|---|---|
| `DELEGATED_CHILD_ENV_MARKER` | 标记被委派的子进程；**值是被围栏的 Kanban board root，不是一个裸 flag** |
| `is_delegated_child_context()` | 是否在委派子进程上下文中 |
| `is_delegated_child_process_context()` | 进程级判断（影响 vision 重复计数默认上限） |
| `is_dispatcher_owned_worker_context()` | 是否 dispatcher 拥有的 worker |
| `owned_kanban_task()` | 解析**本进程拥有的** kanban 任务（用于 prompt 注入门控） |

### 12.1 子进程的重要规则

- 子进程的后台进程在 teardown 时被杀，通知在父进程中被抑制
- 子进程的 `execute_code` 内核独立管理（见 §7）
- 子进程通过 `served_profile_child_env` / `build_subprocess_env` 获得清洗过的环境，
  **绝不用 `dict(os.environ)`**

---

## 13. `_last_resolved_tool_names` 的全局性

[`tools/delegate_tool.py`](../tools/delegate_tool.py:1) 的 `_run_single_child()`
在子代理执行前后 **save/restore** `_last_resolved_tool_names`
（[`model_tools.py`](../model_tools.py:1) 里的进程级全局）。

> **推论**：读取它的代码在子代理运行期间可能看到**暂时陈旧**的值。

---

## 14. 子代理快照（TUI/Desktop 的只读视图）

来自 [`tui_gateway/AGENTS.md`](../tui_gateway/AGENTS.md:92)：

- `subagent.list({session_id})` 返回 `{subagents, delegations}` 给**调用 transport 的活会话**
- roster 是**只读**的，跟随**对话**：exact-owner 记录 + 那些持久血缘
  （`owner_agent_session_id` → 压缩 tip）是本会话 agent 的子进程
  ——因为 Desktop 重连/恢复会重铸 UI session id，而压缩会轮换 key，但子进程继续跑（#114909）
- 控制（`steer` / `interrupt` / `tail`）钉在**精确的会话记录与 transport** 上
- 子进程权限在 RPC 时**针对拥有会话的活 transport slot**解析，所以每条已认证的
  reattach 路径都携带它，无需 registry 记账
- `subagent.tail` 返回活子进程现存 transcript 的**最后 16 KiB**；
  缺失/已结束/外来的子进程返回不可用的空快照；**不打开任何客户端提供的路径**
- 「`last_tool` 是最后**启动**的工具，不是 in-flight 指示器」
- 异步 completion 单元**不是** agent，缺少精确 generation 权限；`delegations` 保持空数组以兼容 wire

---

## 15. 测试约定

- 委派相关的 E2E 用**真实 import** + 临时 `HERMES_HOME`
- 断言行为契约（结果路由、生命周期、stop 扇出），而非工具数量
- 子进程 env 隔离是安全边界，值得测试

---

## 16. 本篇小结与下一步

- `delegate_task` 提供**隔离上下文 + 隔离终端**的子代理；同步或后台两条路。
- **完成单元共享一个池 slot**，绝不按单元计容量。
- **停止扇出必须显式调用 `interrupt_for_session`**——硬中断到不了脱离的后台单元。
- 后台委派是**进程本地**的；要持久化就用 cron 或后台终端进程。

下一步 → [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)：Profile 与多路复用的完整规则。
