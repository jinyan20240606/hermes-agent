# 07 · 状态持久化与会话

> 目标：理解 SQLite 状态库的结构、profile 隔离的路径解析、以及压缩如何产生会话血缘。

---

## 1. 一句话概览

Hermes 用 SQLite 数据库（默认 `~/.hermes/state.db`，实际是 `get_hermes_home() / "state.db"`）
持久化会话元数据、完整消息历史、模型配置，跨 CLI 与网关会话共享。
这**取代了**早期「每会话一个 JSONL 文件」的方案。

源码：[`hermes_state.py`](../hermes_state.py:1)（门面）+ 众多 `hermes_state_*.py` 兄弟模块
（schema、fts、search、compression、portability、gateway ...）。

关键设计（[`hermes_state.py`](../hermes_state.py:1) 的 docstring）：
- **WAL 模式**：并发读者 + 单写者
- **压缩通过 `parent_session_id` 链拆分会话**
- 会话带 source 标签（`'cli'`、`'telegram'` ...）
- Batch-runner / RL 轨迹存在别处

---

## 2. 兄弟模块地图（按主题找代码）

| 兄弟模块 | 主题 |
|---|---|
| [`hermes_state_schema.py`](../hermes_state_schema.py:1) | schema 定义（`SessionSchemaMixin`） |
| [`hermes_state_sessions.py`](../hermes_state_sessions.py:1) | 会话 CRUD |
| [`hermes_state_messages.py`](../hermes_state_messages.py:1) | 消息读写 |
| [`hermes_state_fts.py`](../hermes_state_fts.py:1) | FTS5 全文检索（含 CJK 扩展） |
| [`hermes_state_search.py`](../hermes_state_search.py:1) | 检索 API |
| [`hermes_state_compression.py`](../hermes_state_compression.py:1) | 压缩相关持久化 |
| [`hermes_state_wal.py`](../hermes_state_wal.py:1) | WAL 管理 |
| [`hermes_state_readpool.py`](../hermes_state_readpool.py:1) | 只读连接池 |
| [`hermes_state_guard.py`](../hermes_state_guard.py:1) | 生产库保护（测试隔离守卫） |
| [`hermes_state_errors.py`](../hermes_state_errors.py:1) | 错误分类 |
| [`hermes_state_health.py`](../hermes_state_health.py:1) | 健康/损坏标记 |
| [`hermes_state_portability.py`](../hermes_state_portability.py:1) | 导入导出 |
| [`hermes_state_timeline.py`](../hermes_state_timeline.py:1) | 时间线视图 |
| [`hermes_state_titles.py`](../hermes_state_titles.py:1) | 标题生成 |
| [`hermes_state_tool_retries.py`](../hermes_state_tool_retries.py:1) | 工具重试记录 |
| [`hermes_state_usage.py`](../hermes_state_usage.py:1) | 用量统计 |
| [`hermes_state_rewind.py`](../hermes_state_rewind.py:1) | 回退 |
| [`hermes_state_registry.py`](../hermes_state_registry.py:1) | 会话注册表 |

从门面 import 的关系可见：[`hermes_state.py`](../hermes_state.py:52) 把各 mixin 组合进 `SessionDB`。

---

## 3. Hermes Home 与 Profile 隔离（最重要的路径规则）

`get_hermes_home()` 是状态与配置的**权威文件系统解析器**。解析顺序：

1. context-local override（contextvar）
2. `HERMES_HOME` 环境变量
3. 平台默认（macOS/Linux：`~/.hermes`；Windows：`%LOCALAPPDATA%/hermes`）

**推论**：默认库永远是 `get_hermes_home() / "state.db"`，
调用方**不应**硬编码 `~/.hermes/state.db`
（[`session-storage.md`](../website/docs/developer-guide/session-storage.md:11)）。

### 3.1 命名 Profile

命名 profile 是**隔离目录**。名为 `coder` 的 profile 用 `<默认 Hermes 根>/profiles/coder/`，
因此拥有自己的 `state.db`、配置、日志与其它 profile 级状态。

**规则**：进程为某 profile 创建数据库、读配置、或启动子进程时，
必须保留或传递该 profile 的 `HERMES_HOME`；回退到默认根会把错误 profile 的状态混进操作。

### 3.2 CLI 启动时的 profile 解析

CLI 引导在 import 其余 Hermes 之前调用 `_apply_profile_override()`：
- 显式 `--profile`/`-p` 解析该 profile 并把解析出的目录写进 `HERMES_HOME`
- 无显式选择器时，保留 profile 特定的 `HERMES_HOME`；否则可用默认根的 active-profile 选择
- **`HOME` 只决定「没有 context override 或 HERMES_HOME 时」的平台默认值**
- **改 `HOME` 不是选择命名 profile 的安全方式**。丢掉了 `HERMES_HOME` 的子进程可能回退到默认 profile，
  所以子进程 spawner 应显式传递 `HERMES_HOME`

`display_hermes_home()` **只用于面向用户的文本**，它把解析出的 home 相对用户主目录格式化
（如 `~/.hermes/profiles/coder`），不提供另一套解析规则。

### 3.3 hermes_constants.py 的关键 API

| 函数 | 用途 |
|---|---|
| `get_hermes_home()` | 权威 home 解析（读用） |
| `display_hermes_home()` | 展示用文本 |
| `set_hermes_home_override()` / `reset_hermes_home_override()` | contextvar 覆盖 |
| `hermes_home_key(path=None)` | home 的规范化 key（用于全局槽位键） |
| `get_process_hermes_home()` / `pin_process_hermes_home()` | 进程级 home |
| `get_default_hermes_root()` | 默认根 |
| `named_profile_home()` / `named_profile_is_live()` / `named_profile_has_identity()` | profile 枚举 |
| `mkdir_under_hermes_home()` | 安全建目录（拒绝已删除的命名 profile） |

---

## 4. 测试隔离守卫（必须知道）

测试**必须**用临时 `HERMES_HOME` 或显式的临时 DB 路径。
**live-system guard** 会在测试上下文进程打开真实默认 Hermes 根或真实命名 profile 下的生产 `state.db` 时**先抛异常**，
防止 fixture 数据或 SQLite 副作用污染活的安装。

两个逃生舱（**禁止**在正常命令/开发 shell/应用配置里设置）：
- 环境变量 `HERMES_STATE_DB_GUARD_BYPASS=1`（给必须访问活库的子进程）
- 进程内标记 `@pytest.mark.live_system_guard_bypass`

> 一个导出该变量的 shell 会把 bypass 交给之后**每一次** pytest 运行。

---

## 5. 压缩与「世代」（generation）

在**原地压缩（in-place compaction）**中：

- 旧行被归档为 `active=0`
- 保留的上下文作为 `active=1` 行插入

**因此一个受保护消息可以合法地同时出现在两个世代**（内容与时间戳完全相同）。
**不要把这些归档行当重复删除。**

诊断：
- 用 `active=1` 诊断重复的**活**写入
- 调查「历史看起来回退了」时，**除了 session ID 还要检查数据库的 profile**

（[`session-storage.md`](../website/docs/developer-guide/session-storage.md:72)）

### 5.1 Desktop Profile 隔离与压缩世代

每个命名 profile 把自己的 transcript 存在自己的 `$HERMES_HOME/state.db` 里，
**即使一个 `hermes serve` 进程服务多个 profile**。

会话内的 agent 重建（Bot Chat 能力刷新、`tools.configure`）必须：
- 保留该会话的数据库句柄
- 在其构造期间绑定它的 profile home
- 释放旧 agent 时**不得**关闭被其替代者继承的句柄

`tools.configure` 从活会话的 `profile_home` 解析配置，即使客户端只给了 `session_id`。
（[`session-storage.md`](../website/docs/developer-guide/session-storage.md:56)）

---

## 6. 输入所有权（Codex 与网关异常路径）

### 6.1 Codex app-server 输入所有权

agent 在启动 Codex turn **之前**持久化已接受的用户输入。Codex 随后把该输入投影为前导
`userMessage` 通知。在运行时拼接边界，Hermes 只排除那个**恰好匹配**被序列化进 `turn/start`
的前导项（含 rich-input 强制转换）。后来或不匹配的用户事件保持完整。

这也适用于合成/无 key 输入；**不依赖平台消息 ID**。已有历史重复不会被改写。

### 6.2 网关异常路径的输入所有权

网关异常可能发生在 agent 构造**之前**，或输入已到达 SQLite **之后**。
网关在现有 `display_metadata` 侧车里给已接受输入一个 **owner 标记**，并让它走 agent 的正常持久化路径。

- **provider 消息永远不包含这个元数据**
- 平台标记把入站消息 ID 按平台、profile、scope、chat、thread 做命名空间化
- 原始 `platform_message_id` 保持不变，用于引用/回复解析
- 无 key 的 turn 会拿到一个新标记，即使文本与时间戳完全相同

异常写入器**只探测那个标记**，沿着已发布的 reroute 与规范化的活压缩后继、然后是压缩祖先查找。
活行与 compaction 归档都算数；被撤销的行、已观察输入、无关写入者不算数。
**一个无关进程写同一会话不能抑制这个 turn。**

> 这是**失败写入器仲裁（failure-writer arbitration）**，正常 agent 拥有的持久化不受影响。

---

## 7. FTS5 全文检索

[`hermes_state_fts.py`](../hermes_state_fts.py:1) 提供 `SessionFtsSetupMixin` 与
`load_fts5_cjk_extension`。这支撑了 `session_search` 工具——跨会话召回历史对话。

FTS 支撑的能力是 Hermes「闭环学习」的一部分：
Agent 能搜索自己过去的对话（[`README.md`](../README.md:26)）。

---

## 8. 会话血缘（compression 产生 parent/child）

压缩拆分会话时，用 `parent_session_id` 把新会话链到旧会话。
这就是「会话血缘」：

```text
session_A (被压缩)
   └─► session_B (parent_session_id = A)   ← active=1 的保留上下文
          └─► session_C (parent_session_id = B)
```

子代理的血缘是另一条链：`owner_agent_session_id` → 压缩 tip，
与进程内 `delegate_task(action="list")` 用的是同一条脊梁
（[`tui_gateway/AGENTS.md`](../tui_gateway/AGENTS.md:92)）。

---

## 9. 会话级锁与并发

[`hermes_state_lockguard.py`](../hermes_state_lockguard.py:1)、
[`hermes_state_lockowners.py`](../hermes_state_lockowners.py:1)、
[`hermes_state_holders.py`](../hermes_state_holders.py:1) 处理写锁与持有者识别。

配套概念：跨进程的 **session turn 租约**（[`agent/turn_facade_lease.py`](../agent/turn_facade_lease.py:1)），
保证一次 turn 只有一个owner，避免并发写。

---

## 10. 恢复与维护

| 模块 | 用途 |
|---|---|
| [`hermes_state_repair.py`](../hermes_state_repair.py:1) | 修复 |
| [`hermes_state_profile_repair.py`](../hermes_state_profile_repair.py:1) | profile 修复 |
| [`hermes_state_maintenance.py`](../hermes_state_maintenance.py:1) | 维护任务 |
| [`hermes_cli/cli_auto_maintenance.py`](../hermes_cli/cli_auto_maintenance.py:1) | CLI 自动维护（state-db / checkpoint） |
| [`hermes_state_dbfile.py`](../hermes_state_dbfile.py:1) | DB 文件层 |

文档：[`state-db-recovery.md`](../website/docs/developer-guide/state-db-recovery.md:1)。

---

## 11. 本篇小结与下一步

- 默认库是 `get_hermes_home() / "state.db"`，**绝不硬编码路径**。
- Profile 是隔离岛；`HOME` 不是选择 profile 的安全方式，子进程要显式传 `HERMES_HOME`。
- 压缩产生 `parent_session_id` 血缘；归档行（`active=0`）不是重复。
- 测试有 live-system guard，别在生产/开发 shell 里设 bypass。

下一步 → [`08-memory-context-compression.md`](08-memory-context-compression.md)：记忆、上下文引擎与压缩三兄弟。
