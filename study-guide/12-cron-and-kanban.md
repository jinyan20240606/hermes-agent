# 12 · Cron 定时任务与 Kanban 多 Agent 队列

> 目标：理解「一等公民 agent 任务」的调度器，以及多 agent 协作的持久看板。
> 这一篇是**多 profile 假设被打破**的最典型案例，值得细读。

---

# 第一部分：Cron

## 1. 代码形状

| 文件 | 职责 |
|---|---|
| [`cron/jobs.py`](../cron/jobs.py:1) | job 存储 |
| [`cron/scheduler.py`](../cron/scheduler.py:1) | tick 循环（+ `scheduler_*.py` 兄弟） |
| [`cron/occurrences.py`](../cron/occurrences.py:1) | 出现次数记账 |
| [`tools/cronjob_tools.py`](../tools/cronjob_tools.py:1) | agent 用的 `cronjob` 工具 |

**Cron 任务是「一等 agent 任务」，不是 shell 任务。**

- 用户接口：`hermes cron list|add|edit|pause|resume|run|remove` 或 `/cron`
- 任务存 JSON
- 投递到任意平台
- 支持多种 schedule 格式、附加 skills 与脚本

长文：[`cron-internals.md`](../website/docs/developer-guide/cron-internals.md:1)。

---

## 2. Schedule 格式

| 格式 | 例子 |
|---|---|
| 时长 | `"30m"`、`"2h"`、`"1d"` |
| "every" 短语 | `"every 2h"`、`"every monday 9am"` |
| 5 字段 cron | `"0 9 * * *"` |
| ISO 一次性 | `"2026-06-01T09:00:00Z"` |

---

## 3. 每任务字段

| 字段 | 说明 |
|---|---|
| `skills` | 附加技能 |
| `model` / `provider` | 覆盖 |
| `script` | 预运行数据收集脚本，其 stdout 注入 prompt；`no_agent=True` 让脚本成为整个 job |
| `context_from` | 把 job A 的最后输出链进 job B 的 prompt |
| `workdir` | 用该目录的 `AGENTS.md`/`CLAUDE.md` 运行 |
| 多平台投递 | — |

---

## 4. 加固不变量（每一条都守着一个真实失败）

来自 [`cron/AGENTS.md`](../cron/AGENTS.md:17)。

### 4.1 不活动看门狗

- 默认 600 秒不活动，`HERMES_CRON_TIMEOUT` 可覆盖，`0` = 无限
- 是**不活动时间**，不是墙钟时间——卡住的会话被硬中断以免独占 scheduler，
  而长但有活动的 job 永不被切断
- 附加脚本（pre-run 或 `no_agent`）由脚本超时单独限制
  （`_DEFAULT_SCRIPT_TIMEOUT`，3600 秒）

### 4.2 追赶窗口

= 周期的一半，钳制在 120s–2h；错过的 one-shot 有 120s 宽限。

### 4.3 每个周期出现都要被记账

- `tick()` 在**派发之前**推进 `next_run_at`（跨 mid-run 崩溃至少一次），
  并在同一 save 中打 `pending_slot`
- 扫描发现 stamp 而 owner 已死 → **只恢复一次**该时刻（[`cron/occurrences.py`](../cron/occurrences.py:1)）
- executions ledger 的 `scheduled_instant` 阻止第二次触发
- `cron.catch_up_missed: false` 跳过已过宽限的错过，附带记录的原因
- **绝不静默丢弃一个 slot**（#107485）

### 4.4 每 home 的 tick 锁

`<home>/cron/.tick.lock` 防止跨进程对**该 profile 存储**的重复 tick；
**绝不**用 `~/.hermes/...` 字面量。

### 4.5 ticker 为整个 tick 绑定每个被服务 profile 的作用域

**包括 pre-loop 代码**：

[`cron/scheduler_provider.py`](../cron/scheduler_provider.py:1) 的 `_start_multiplex` 是
**一个 ticker** 顺序迭代 `profiles_to_serve()`，在 `_profile_cron_scope(home)` 下
（home + secret scope + terminal scope）——**绝不 N 个线程**（模块全局会 race）。

一个 tick 触碰的一切都在那个守卫内：store 打开、锁路径、backoff/失败计数（`_note_tick_failure`）、
job env 构造、以及已完成 job 的 `on_session_end` 刷新。

监督（`scheduler_thread.py::SupervisedTickerThread`）是**每被服务 home** 的，不是每进程：
网关 boot 时启动，为另一个网关已服务的 home 让位，profile 目录出现或被 tombstone 时重新枚举。

> **为什么**：在进入作用域之前打开的 store 会把次要 profile 的运行记录写进启动 profile 的 `jobs.json`。

### 4.6 Cron 归属**不**由 `gateway.multiplex_profiles` 门控

那个 flag 门控**适配器**；一个 host 网关进程无论如何 tick **每个** profile 的 store
（`run.py::_cron_tick_profile_homes`）。

> 把 tick 集门控在它上面，会让每个非启动 profile 的 job 留在一个没有 ticker 访问的 store 里。

### 4.7 「每 profile 进程假设」是一个 bug 类别

一个进程 tick N 个 home，所以任何以「本进程的 profile」为 key 的东西都是错的：

- in-flight 状态（`_running_job_ids`、`_running_since`、`_running_futures`、
  `_running_worker_pids`、`_running_fire_owners`、`_interrupted_job_ids`）
  以 `_inflight_key(job_id)` = `(home key, job id)` 为 key
  ——两个 profile **合法地**各有一个 `daily-brief`
- 并行池以 home 为 key（`cron.max_parallel_jobs` 是**每 profile** 的）
- stale-code yield gate 问 `scheduler_ownership.owns_cron_tick_for(home)` /
  `live_gateway_ticking(home)`，而不是进程级 runtime-lock 布尔
- 公开 accessor 仍报告 host 级 union（供关闭 drain），
  但**存活性消费者**（`jobs.py::_job_running_in_this_process`、`tools/cronjob_tools`）
  问 `is_job_running(job_id, home=...)`
  ——union 会让 profile A 的运行中 `daily-brief` 替 profile B 空闲的那个回答

### 4.8 一个 claim 必须用它注册时的 key 释放

cron 作用域是 ContextVar：
- `try_register_running_job` 在 ticker 线程内、`_profile_cron_scope` 里跑
- 而池 worker 的 `finally` 在 `ctx.run` **之外**，会解析到**启动 home**

所以必须传注册的 home（`release_running_job(job_id, home=...)`），
否则每个次要 profile 的 claim 泄漏——job 跳过一个触发窗，
直到 force-release 兜底扫除它，而 drain 看到幻影工作。

**绝不**从 key 的一半重建 home（`Path(key[0])`）——用 `_inflight_home_path`。

### 4.9 被 tick 的 home 离开集合时要回收状态

`register_ticked_homes` 每周期重新发布，并回收离去的 home 的并行池。
（池以前活到 `atexit`，所以每个曾被 tick 的 home 永远保留一个 ThreadPoolExecutor。）

### 4.10 host 网关为「运行自己网关的 profile」让位

`run.py::_cron_profile_gate` 让启动进程与 per-profile 网关避开同一个 store。
该 gate 拿存活性 PID 与 `os.getpid()` 比——本进程持有启动 `gateway.pid` **且**在
`served_profiles` 里发布每个被服务的 profile，所以裸存活性答案会把 cron 全 host 停下。

### 4.11 重启安全的外部 worker 自我引导

`_launch_external_cron_worker` 在子进程 `PYTHONPATH` 上钉住 checkout
（PM 安装时还钉住已提交代的 `site-packages`），并标 `_HERMES_CRON_WORKER_BOOT`。

子进程的包入口（[`cron/__init__.py`](../cron/__init__.py:1) → `cron/worker_bootstrap.py`，
在 `cron.jobs` import **之前**）随后跑 PM 的 `activate_dependencies`，
为 worker 生命周期租用已提交代，跑其 `.pth` 文件，在第一个第三方 import 前激活它。

**激活失败是致命的**：worker 在 ownership ack 之前退出（= 报告的派发失败），
而不是跑在一个 collector 可能删除的未租用代上。

### 4.12 其它

- Cron 会话传 `skip_memory=True`；记忆 provider **故意**不在 cron 期间运行
- Cron 执行有自己的 session
- 镜像 brief 是**在 turn 边界追加**的 user turn，保持角色交替
- ticker 在 `HERMES_DESKTOP=1` 的桌面 spawn 后端**也**运行——
  该 env var 意思是「由 app spawn」，不是「有 GUI 在看」
- 后台 `delegate_task` 是**进程本地**的；必须熬过重启的工作用 cron job 或
  `terminal(background=True, notify_on_complete=True)`

---

# 第二部分：Kanban

## 5. 什么是 Kanban

一个**持久 SQLite 支撑的看板**，让多个 profile / worker 协作。
- 用户：`hermes kanban <verb>`
- dispatcher spawn 的 worker 用专用 `kanban_*` toolset，
  所以它们的 schema 足迹在 kanban 任务外为**零**（footprint ladder 第 3 级）

---

## 6. 代码形状

- **CLI**：[`hermes_cli/kanban.py`](../hermes_cli/kanban.py:1) 门面 + 14 个 `kanban_*.py` 兄弟
  （`boards`、`db`、`db_connect`、`db_dispatch`、`db_notify`、`db_graph`（任务初始化与分解）、
  `workspace` ...）
- **工具**：[`tools/kanban_tools.py`](../tools/kanban_tools.py:1)
- **Dispatcher**：长命循环（默认 60 秒）
- **插件资产**：[`plugins/kanban/dashboard/`](../plugins/kanban/dashboard/)（web UI）
  + systemd unit

### 6.1 Verbs

```text
init, create, list (ls), show, assign, link, unlink, comment, attach, attachments,
attach-rm, complete, request-review, request-changes, reopen-review, block, unblock,
archive, tail
+ watch, stats, runs, log, assignees, heartbeat, notify-*, dispatch, daemon, gc
```

> **argparse 别名派发必须同时接受 `list` 和 `ls`**（根规则）。

### 6.2 工具清单

`kanban_show, kanban_complete, kanban_request_review, kanban_request_changes, kanban_block,
kanban_schedule, kanban_heartbeat, kanban_comment, kanban_create, kanban_link, kanban_attach,
kanban_attach_url, kanban_attachments`

平台若保存的选择启用了 `kanban`（`hermes tools enable kanban --platform <p>`；
默认关闭，在 `CONFIGURABLE_TOOLSETS`），则获得全套加 `kanban_list`/`kanban_unblock` 用于看板路由。

`check_fn` 读 schema 构建自己的选择（[`tools/kanban_toolset_context.py`](../tools/kanban_toolset_context.py:1)），
**不**只是 legacy 顶层 `toolsets` key。

### 6.3 Dispatcher

长命循环，**默认在网关内运行**（`kanban.dispatch_in_gateway: true`）：
- 回收陈旧 claim
- 提升 ready 任务
- 原子地 claim
- spawn 被分配的 profile

独立运行：[`plugins/kanban/systemd/hermes-kanban-dispatcher.service`](../plugins/kanban/systemd/hermes-kanban-dispatcher.service)。

> `kanban_db.connect` 是**自己的**连接 helper——**不要**把它 alias 到 `projects_db.connect`
> （一个按路径邻近性工作的生成器干过这事）。

---

## 7. Kanban 隔离模型（重要）

- **board 是硬边界**：worker 的环境里钉了 `HERMES_KANBAN_BOARD`，看不到其它 board
- **tenant 是 board 内的软命名空间**（workspace-path + memory-key 隔离，
  一个 fleet 服务多个业务）

### 7.1 自动 block

在 `kanban.failure_limit` 次连续非成功尝试后（默认 2），dispatcher 自动 block 该任务以停止 spin 循环。

worker 以 `KANBAN_TERMINAL_PROVIDER_EXIT_CODE`（78——凭证被撤销、模型没了）退出时，
**第一次尝试**就触发它，且**粘性**，因为没有任何重试能治愈它（#114587）。
worker 自己的 `failure_reason` 分类走 `cli._TERMINAL_PROVIDER_REASONS`。

### 7.2 进程身份

> `kanban --preserve-cache` 含 "serve"——**绝不**按 argv 子串分类进程（根规则，HX003）。

Worker 存活性是 `(worker_pid, worker_started_at)` ——claim 时记录的启动时间指纹
（`gateway.status.get_process_start_time`）——**绝不**裸 PID 存在性，
否则回收时会杀掉一个被复用的 PID。

---

## 8. 通知与 Prompt 注入的所有权规则

### 8.1 通知从任务所属 profile 离开

[`hermes_cli/kanban_db_notify.py`](../hermes_cli/kanban_db_notify.py:1) 的订阅携带 profile；
[`gateway/kanban_watchers_notifier.py`](../gateway/kanban_watchers_notifier.py:1)
在**那个** profile 的适配器与作用域下投递（`_notify_profile_filter`），
**绝不**用 multiplexer 的启动适配器。

fail-closed 跳过会在 WARNING 记录一次并带 remedy，**绝不**是裸 `continue`。

被派发的 worker 在**清洗过的**子环境里钉住 `HERMES_KANBAN_BOARD` 与 assignee 的 `HERMES_HOME`
（`build_subprocess_env` + `strip_launch_profile_env`）；它们**绝不**继承默认 profile 的 `.env`。

### 8.2 Prompt 注入点按所有权门控，而不是工具访问权

- 工具访问权（`kanban_show` 经 profile 的 toolset 可见）
- 继承的 `HERMES_KANBAN_TASK`（delegate 子进程、worker 旁边的 cron 运行）

**这两者都不是所有权。**

kanban 指引（`agent_init`、`system_prompt` fallback）与 stop nudge 通过
[`agent/delegation_context.py`](../agent/delegation_context.py:1) 的 `owned_kanban_task()` 解析任务；
其它 reader 把 env 读取与 `is_dispatcher_owned_worker_context()` 配对。

### 8.3 后代围栏是**路径**，不是 flag

被委派子进程的 Kanban 标记
（`agent/delegation_context.py::DELEGATED_CHILD_ENV_MARKER`）携带被围栏的 **board ROOT**；

`kanban_path_is_fenced(path)` 只拒绝在 dispatcher 钉住的 `HERMES_KANBAN_DB` 上
**或**那个 root 下的变更——这样对着 scratch `HERMES_HOME` 工作的子进程保留可写 board。

---

## 9. 测试约定

- 测试放 `tests/cron/`、`tests/hermes_cli/test_kanban*.py`、`tests/tools/test_kanban*.py`
- schedule 解析与追赶窗口是**纯函数**——当数据来测
- **绝不**断言 verb 清单或 toolset 大小
- 基于时间的测试用宽松边界（≥ 2s）与事件同步

---

## 10. 本篇小结与下一步

- Cron 是**一等 agent 任务**，默认在网关内 tick，**一个 ticker 顺序迭代所有 profile**。
- 「每 profile 进程假设」是 cron 的核心 bug 类别：一切 in-flight 状态按 `(home, job_id)` 做 key。
- Kanban 的 **board 是硬边界**、**tenant 是软命名空间**；
  通知与 prompt 注入按**所有权**而非工具访问权门控。

下一步 → [`13-subagents-delegation.md`](13-subagents-delegation.md)：子代理与并行委派。
