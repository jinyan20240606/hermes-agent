# 07 · 状态持久化与会话

> **读法**：这一篇回答「我关掉终端，为什么下次还能接着聊？」。
> 顺序是：**§0 前置**（数据库 / 事务 / WAL 是什么）→ **§1 文件地图**（1 门面 + 33 兄弟模块）
> → **§2 库放哪里**（`get_hermes_home()` 与 profile 隔离）→ **§3 表结构逐张解剖**
> → **§4 读写两条路径**（只读池 vs 单写者）→ **§5 WAL 与降级**
> → **§6 并发、锁与租约** → **§7 会话血缘**（parent / branch / reset / delegate）
> → **§8 消息表的双投影** → **§9 三套 FTS 索引** → **§10 健康、修复与测试隔离**
> → **§11 自检题** → **§12 小结**。
>
> 读完你应该能回答：**「为什么 CLI 和 Telegram 看到的是同一段对话？为什么压缩之后
> `hermes sessions list` 里多了一行，而旧的那行还在？」**

**本篇相对旧版新增**：§0 的四个前置概念（状态是什么 / 事务 / WAL / 单写者）、
§2 `_default_db_path()` 的 import-time 快照陷阱与 `mkdir_under_hermes_home` 的 deleted-profile 保护、
§3 完整 12 张表 + `system_prompts` 内容寻址、§4 `_read_ctx` 降级链与 `_execute_write` 的
重试分类矩阵、§5 `apply_wal_with_fallback` 的全部结局（含 WAL-reset bug 与 cross-VM FS）、
§6 进程内 registry 的代际（generation）回收、§7 四种 child 的判别与 `_resume_lineage_ids` 的
VERIFIED 血缘、§8 `active` / `compacted` / `display_*` 三组列、§9 cjk_unicode61 的动机、
§10 结构损坏闩锁（latch）与 live-system guard 的 ancestry 判据。

---

## 0. 前置概念

### 0.1 「状态」到底是什么

一个 agent 进程里有四种东西，初学者常常混为一谈：

| 层 | 存在哪 | 丢了会怎样 | 本篇讲不讲 |
|---|---|---|---|
| **内存态**：`messages` list、当前 turn 的中间变量 | Python 堆 | 进程崩溃就没了 | 不讲（03 篇） |
| **上下文态**：`_stored_system_prompt`、缓存断点 | `AIAgent` 属性 | 重建即可，只影响成本 | 不讲（04 篇） |
| **持久态**：会话行、消息行、token 用量 | `state.db`（SQLite） | **用户的对话历史永久消失** | **本篇** |
| **配置态**：`config.yaml`、`.env` | 文本文件 | 下次启动行为变了 | 不讲（06/14 篇） |

所以本篇讲的是**唯一的真相来源（source of truth）**：

```text
LLM 是无状态的
      ↓
每一轮都把整个 messages 数组重新发一遍（03 篇 §0）
      ↓
那这个数组从哪来？进程刚启动时是空的
      ↓
只能从磁盘读回来 —— 这就是 state.db
```

**关键推论**：`state.db` 不是「日志」或「缓存」，它是**唯一的对话真相**。
内存里的 `messages` 只是它的一份工作副本。这也解释了一句代码里反复出现的话：

> *"the durable transcript is the authority, the warm (in-memory) history only has to agree with it."*
> —— [`hermes_state_rewind.py`](../hermes_state_rewind.py:1)

`/undo` 之所以要校验「内存和磁盘的用户轮次是否一致」，就是因为**磁盘才是权威**：
如果内存和磁盘不一致，说明有别的东西（另一个进程、一次崩溃恢复）改过磁盘，
这时候盲目按内存回退会写出更错的历史。

### 0.2 为什么是 SQLite，而不是 JSON 文件

早期版本是「每会话一个 JSONL 文件」，后来换成了单个 SQLite 库
（[`hermes_state.py`](../hermes_state.py:2) 的 docstring 明说 *"replaces the earlier
per-session JSONL file approach"*）。换成 SQLite 换来四件 JSON 文件做不到的事：

1. **跨会话检索**。`session_search` 工具要在一万条历史消息里按关键词找。
   JSONL 只能全量扫盘 + 自己写倒排索引；SQLite 有 FTS5。
2. **原子性**。「写入这条 assistant 消息」和「`message_count + 1`」必须一起成功。
   JSONL 追加一行成功、更新计数失败 → 计数永久偏移。
3. **并发**。gateway 在写、Desktop 在读、cron 在写。JSONL 只能自己搞文件锁。
4. **结构化查询**。「列出所有 `source='telegram'` 且 `ended_at IS NULL` 的会话」
   —— SQL 一行，JSONL 要全量反序列化。

前端类比：JSONL ≈ `localStorage` 里存一个数组；SQLite ≈ 上了一个 IndexedDB，
还自带事务和索引。

### 0.3 事务是什么（一分钟版）

```sql
BEGIN IMMEDIATE;              -- 我要写，先把写锁拿下
  INSERT INTO messages ...;   -- 插入消息
  UPDATE sessions SET message_count = message_count + 1 WHERE id = ?;
COMMIT;                       -- 要么两条都生效，要么都不生效
```

如果中间进程被 kill，SQLite 会**整体回滚**，库还是事务开始前的样子。

`BEGIN IMMEDIATE` 和 `BEGIN`（默认 DEFERRED）的区别很重要：

- `BEGIN`（DEFERRED）：先声明「我要事务」，但**真正拿写锁是在第一条写语句执行时**。
  所以在事务中间才撞锁，前面读到的数据可能已经过期。
- `BEGIN IMMEDIATE`：**在 BEGIN 那一刻就拿写锁**。冲突立刻暴露，不会写到一半才发现。

这就是 [`hermes_state.py`](../hermes_state.py:995) 里 `_execute_write` 的 docstring 说的：

> *"BEGIN IMMEDIATE takes the WAL write lock up front so contention surfaces immediately."*

**代价**：既然锁是提前拿的，那么在拿到锁之前的等待期间，别的事务可能改了数据。
所以 `_execute_write` 在锁冲突时会**重跑整个回调**，这就要求回调必须**幂等**（可安全重放）：

> *"the WHOLE callback retried — `fn` must stay idempotent under retry."*

前端类比：像 `fetch` 的自动重试。如果你的 POST 不是幂等的，重试就会创建两条记录。
所以 Hermes 的写回调里不做「先读后判再写」的脆弱逻辑，而尽量用
`INSERT ... ON CONFLICT DO UPDATE` 或 `WHERE ... AND ended_at IS NULL` 这种
**重复执行结果不变**的形状。

### 0.4 WAL 是什么，为什么「单写者」不是缺陷

SQLite 有两种日志模式：

```text
DELETE 模式（回滚日志）
 写事务开始 → 把原页复制到 state.db-journal → 改 state.db → COMMIT 时删 journal
 问题：读者需要 SHARED 锁，写者在提交期间持 EXCLUSIVE → 读者被挡住

WAL 模式（预写日志）
 写事务 → 追加新页到 state.db-wal（append-only）→ COMMIT 只写一个提交帧
 读者继续读 state.db 里的旧快照（-shm 共享内存索引帮它找到该看哪些帧）
 检查点（checkpoint）时把 WAL 里的页合并回 state.db
```

WAL 带来的是**读写不互斥**：读者永远能读到一个一致快照，不会被写者阻塞。

但它没有改变 SQLite 的根本约束：**任何时刻只有一个写者**。
这不是 SQLite 的偷懒，是它用来保证「不需要分布式协调就能正确」的设计选择。
Hermes 的所有并发代码，都是在**承认单写者**的前提下做排队、退避、降级。

前端类比：WAL ≈ 乐观并发 + append-only 的 redo log（像 Git 的 commit 日志），
DELETE 模式 ≈ 悲观锁 + 就地改（像直接改文件再靠 undo 栈回滚）。

### 0.5 四个必须记住的数字

| 常量 | 值 | 位置 | 含义 |
|---|---|---|---|
| `_WRITE_PATIENCE_S` | 20s | [`hermes_state.py:484`](../hermes_state.py:484) | 常规写入最多等锁 20 秒 |
| `_TRANSCRIPT_WRITE_PATIENCE_S` | 60s | 同上 | **转录**写入（失败会让整个 turn 失败）等 60 秒 |
| `_ACTIVITY_WRITE_PATIENCE_S` | 0.5s | 同上 | 心跳类「可有可无」的写入只等半秒 |
| `_COMPRESSION_BUSY_WAIT_S` | 5s | [`hermes_state.py:496`](../hermes_state.py:496) | 撞上他人的压缩锁最多等 5 秒 |

**为什么是三个不同的耐心值？** 因为「写失败」的后果不一样：

```text
转录写（append_message）  → 失败 = 用户的对话丢了 = 整个 turn 报错
                          → 值得等 60 秒

常规写（end_session 等）   → 失败 = 状态标记没更新，可重试
                          → 等 20 秒

心跳写（last_activity_at） → 失败 = 侧边栏排序旧了一点
                          → 半秒，超时就跳过，下一个心跳窗口再写
```

代码里的原话：「*observation-only activity writes sit on the response-critical path
and get a sub-second one*」——纯观测性的写入处在**响应关键路径**上，绝不能为了它让用户多等。

---

## 1. 文件地图（1 个门面 + 33 个兄弟模块，按主题找代码）

[`hermes_state.py`](../hermes_state.py:461) 的 `SessionDB` 是**门面 + MRO 组合器**：
它本身几乎不含业务逻辑，只是把 16 个 mixin 拼起来，再加上连接管理。

```python
class SessionDB(
    SessionSessionsMixin, SessionFtsSetupMixin, SessionSearchMixin, SessionSchemaMixin,
    SessionPortabilityMixin, SessionTelegramTopicsMixin, SessionCompressionMixin,
    SessionGatewayMixin, SessionMaintenanceMixin, SessionUsageMixin, SessionTitlesMixin,
    SessionMessagesMixin, SessionCoverageMixin, SessionRewindMixin, SessionProfileRepairMixin,
    SessionToolRetriesMixin,
):
    """SQLite-backed session storage with FTS5 search; many reader threads, one writer (WAL)."""
```

按主题分组：

| 分组 | 模块 | 职责 |
|---|---|---|
| **骨架** | [`hermes_state.py`](../hermes_state.py:461) | `SessionDB` 门面：连接、读写原语、`close()` |
| | [`hermes_state_common.py`](../hermes_state_common.py:283) | `SCHEMA_SQL`、`SCHEMA_VERSION`、共享 SQL 片段 |
| | [`hermes_state_schema.py`](../hermes_state_schema.py:922) | `_init_schema()`、列对账、数据迁移 |
| **CRUD** | [`hermes_state_sessions.py`](../hermes_state_sessions.py:459) | 会话行的增改查、生命周期标记、删除级联 |
| | [`hermes_state_messages.py`](../hermes_state_messages.py:389) | 消息写入/替换/恢复装配 |
| | [`hermes_state_identity.py`](../hermes_state_identity.py:1) | `message_uid` / `tool_call_uid` 编解码 |
| | [`hermes_state_ids.py`](../hermes_state_ids.py:56) | 会话 id 铸造（**唯一的形状权威**） |
| **检索** | [`hermes_state_fts.py`](../hermes_state_fts.py:1) | 三套 FTS 索引的 DDL 与 CJK 分词器 |
| | [`hermes_state_search.py`](../hermes_state_search.py:1) | 查询入口、FTS5 语法净化、上下文窗口 |
| | [`hermes_state_timeline.py`](../hermes_state_timeline.py:1) | 只读 prompt 索引与有界跳转 |
| **压缩** | [`hermes_state_compression.py`](../hermes_state_compression.py:1) | 血缘链、冷却计数、压缩锁、turn 租约 |
| | [`hermes_state_coverage.py`](../hermes_state_coverage.py:1) | 就地压缩时「哪些行被保留」的解析 |
| **网关** | [`hermes_state_gateway.py`](../hermes_state_gateway.py:1) | 路由索引、peer、孤儿、心跳、handoff |
| | [`hermes_state_telegram.py`](../hermes_state_telegram.py:1) | Telegram DM topic 模式 |
| **运维** | [`hermes_state_wal.py`](../hermes_state_wal.py:254) | journal 模式策略与降级 |
| | [`hermes_state_registry.py`](../hermes_state_registry.py:1) | 进程内共享写连接的代际注册表 |
| | [`hermes_state_readpool.py`](../hermes_state_readpool.py:1) | 只读连接预算（防 EMFILE） |
| | [`hermes_state_holders.py`](../hermes_state_holders.py:1) | 「谁还持有这个库/被删的侧文件」的进程判据 |
| | [`hermes_state_lockowners.py`](../hermes_state_lockowners.py:49) | `/proc/locks` 解析：**谁**拿着写锁 |
| | [`hermes_state_lockguard.py`](../hermes_state_lockguard.py:1) | OFD 锁守卫，防误 `close()` 取消文件锁 |
| | [`hermes_state_pidns.py`](../hermes_state_pidns.py:1) | PID 命名空间戳记（容器场景） |
| | [`hermes_state_maintenance.py`](../hermes_state_maintenance.py:322) | 保留期裁剪、归档、VACUUM |
| **恢复** | [`hermes_state_repair.py`](../hermes_state_repair.py:1) | schema 修复、备份、可写性预检 |
| | [`hermes_state_dbfile.py`](../hermes_state_dbfile.py:656) | 文件层：头探测、隔离、被删 WAL 捕获 |
| | [`hermes_state_health.py`](../hermes_state_health.py:60) | 结构损坏闩锁（进程级） |
| | [`hermes_state_errors.py`](../hermes_state_errors.py:1) | 异常类型与错误分类谓词 |
| | [`hermes_state_user_copy.py`](../hermes_state_user_copy.py:1) | 面向用户的一句话解释表 |
| **其它** | [`hermes_state_portability.py`](../hermes_state_portability.py:1) | 导入/导出 |
| | [`hermes_state_rewind.py`](../hermes_state_rewind.py:45) | `/undo`、`/retry` 的持久化回退 |
| | [`hermes_state_titles.py`](../hermes_state_titles.py:1) | 标题生成与权威等级 |
| | [`hermes_state_usage.py`](../hermes_state_usage.py:1) | token/费用核算（含后台合并写线程） |
| | [`hermes_state_tool_retries.py`](../hermes_state_tool_retries.py:19) | 工具卡片「重试」结果（写进 `display_metadata`） |
| | [`hermes_state_profile_repair.py`](../hermes_state_profile_repair.py:1) | 跨 profile 错位行的发现与搬迁 |
| | [`hermes_state_guard.py`](../hermes_state_guard.py:23) | live-system guard + 最近初始化错误 |

**找代码的方法**（与仓库 `AGENTS.md` 一致）：`grep -rn "def name" hermes_state_*.py`，
不要读门面。

---

## 2. 库文件放在哪里（最重要的路径规则）

### 2.1 解析顺序

```text
get_hermes_home()
  ① context-local override（ContextVar）
  ② HERMES_HOME 环境变量
  ③ 平台默认：macOS/Linux → ~/.hermes；Windows → %LOCALAPPDATA%\hermes
```

[`hermes_constants.py:111`](../hermes_constants.py:111)：

```python
def get_hermes_home() -> Path:
    """Hermes home: context-local override → ``HERMES_HOME`` env var → platform default."""
    override = get_hermes_home_override()
    if override:
        return _expand_hermes_home(override)
    if not os.environ.get("HERMES_HOME", "").strip():
        _warn_profile_fallback_once()   # ← 见 §2.4
    return get_process_hermes_home()
```

**推论（HX001 规则）**：

```python
# ❌ 错
db = SessionDB(db_path=Path.home() / ".hermes" / "state.db")

# ✅ 对
db = SessionDB()   # 内部调用 _default_db_path()
```

### 2.2 `_default_db_path()` 的 import-time 快照陷阱

[`hermes_state.py:176`](../hermes_state.py:176) 有一行很巧妙的代码：

```python
# Import-time snapshot lets _default_db_path() detect a re-pointed DEFAULT_DB_PATH
# (tests monkeypatch the constant directly).
DEFAULT_DB_PATH = _IMPORT_DEFAULT_DB_PATH = get_hermes_home() / "state.db"
```

然后在 [`hermes_state.py:198`](../hermes_state.py:198)：

```python
def _default_db_path() -> Path:
    """Default state DB path at CALL time: a re-pointed ``DEFAULT_DB_PATH`` wins, else
    ``get_hermes_home()`` is resolved fresh (a runtime HERMES_HOME redirect works regardless of import)."""
    return DEFAULT_DB_PATH if DEFAULT_DB_PATH != _IMPORT_DEFAULT_DB_PATH else get_hermes_home() / "state.db"
```

三种情况，逐一分析：

| 场景 | `DEFAULT_DB_PATH` | 返回 | 为什么 |
|---|---|---|---|
| 正常生产 | 等于 import 时快照 | **重新解析** `get_hermes_home()` | 进程运行中 `HERMES_HOME` 被改（gateway 切 profile）也能跟上 |
| 测试 monkeypatch 常量 | ≠ 快照 | 直接用 patch 的值 | 测试想精确控制路径 |
| 进程启动后换了 profile 目录 | 等于快照 | 新 profile 的路径 | ✅ 正确行为 |

**这是一个「不能只在 import 时算一次」的典型例子。**
前端类比：模块顶层 `const API_BASE = window.location.origin` —— 如果之后发生了
SSR 或 iframe 重定向，这个常量就过时了。正确做法是**用到时才读**。

### 2.3 Profile = 隔离岛

```text
<hermes root>/
├── state.db                        ← default profile
├── config.yaml
├── logs/
└── profiles/
    ├── coder/
    │   ├── state.db                ← coder profile（自己的库！）
    │   └── config.yaml
    └── writer/
        └── state.db
```

**一个 `hermes serve` 进程可以同时服务多个 profile**，每个 profile 有自己的 `state.db`。
所以 `SessionDB` 对象必须**绑定到它创建时的 profile**，不能在多个 profile 之间复用。

[`agent/turn_facade_lease.py`](../agent/turn_facade_lease.py:34) 和 `tools.configure`
的重建逻辑都在守这条规矩：

> *"In-session agent rebuilds (Bot Chat capability refresh and `tools.configure`) must retain
> that session's database handle and bind its profile home during construction. Releasing the
> outgoing agent must not close the handle inherited by its replacement."*

翻译成人话：

```text
旧 agent 被替换 → 新 agent 继承同一个 db 句柄
❌ 如果释放旧 agent 时 close() 了 → 新 agent 拿着死连接 → 整个会话炸
```

这就是为什么 [`hermes_state.py:1521`](../hermes_state.py:1521) 的 `close()` 开头是：

```python
if self._shared_registry_owned:
    from hermes_state_registry import release
    release(self)     # ← 只减引用计数，不真的关
    return
```

### 2.4 一个会被忽略的警告：profile fallback

[`hermes_constants.py:100`](../hermes_constants.py:100) 附近有一段告警文案：

> *"profile is {active!r}. Falling back to {fallback_home}, which is the DEFAULT profile —
> not {active!r}. Any data this process writes will land in the wrong profile.
> The subprocess spawner should pass HERMES_HOME explicitly"*

它只在「环境里没有 `HERMES_HOME`，但磁盘上有个 active-profile 标记」时触发。

**为什么这不是小事**：一个子进程如果丢了 `HERMES_HOME`，它的 `get_hermes_home()`
会回退到**默认 profile**。于是子代理写的会话、cron 写的记录，全部落在
**错的库**里。用户看到的是「我在 coder profile 里跑的子代理，结果会话跑到 default 去了」。

所以规则是：**任何 spawn 子进程的地方都必须显式传 `HERMES_HOME`**。
改 `HOME` 环境变量**不是**选 profile 的安全方式（它只影响「平台默认值」这一层）。

### 2.5 `hermes_home_key()`：给全局槽位用的规范化键

[`hermes_constants.py:129`](../hermes_constants.py:129)：

```python
def hermes_home_key(path: str | Path | None = None) -> str:
    """Stable registry key for a Hermes home/profile dir.

    ``strict=False`` so profiles whose directories don't exist yet still get a key.
    ...A directory that does not exist yet is resolved without touching the cache, because the answer
    can change once it is created (e.g. part of the path turns out to be a symlink).
    """
```

两个细节值得学：

1. **为什么需要这个函数**：`Path.resolve()` 是一次 **syscall**，而这个函数在
   `ToolRegistry` 每次查找时都会被调用（经 `current_scope_key()`）。所以有
   `_HOME_KEY_CACHE`（每个进程只看得到少数几个 home 路径）。
2. **为什么「不存在的目录不缓存」**：目录还没创建时 `resolve(strict=True)` 会失败，
   只能 `strict=False` 宽松解析。但一旦目录被创建，路径里某一段可能是符号链接，
   解析结果就变了。所以「不存在」的答案**不能缓存**。

**这条规则值得抄进任何做路径记忆的代码里。**

### 2.6 `mkdir_under_hermes_home()`：不许复活已删除的 profile

[`hermes_state.py:682`](../hermes_state.py:682)：

```python
# Never materialize a deleted/archived named profile's home: a multiplexer or Desktop backend
# still holding the profile's route would otherwise re-scaffold it on the next turn (#94590).
mkdir_under_hermes_home(self.db_path.parent)
```

场景：用户删了 profile `coder`。但 Desktop 后端的路由表里还留着 `coder` 的一条记录。
下一轮消息来了，后端尝试打开 `profiles/coder/state.db`。

- 用 `Path.mkdir(parents=True, exist_ok=True)` → **把 `profiles/coder/` 重新创建出来**，
  于是「已删除」的 profile 幽灵般复活，用户删了三次它出现三次。
- 用 `mkdir_under_hermes_home()` → **拒绝**，抛错，路由层把这次请求标为无效。

这是「**删除必须是幂等的**」这条通用原则的一个具体实现。

---

## 3. 表结构逐张解剖（schema v31）

版本号在同一处定义（[`hermes_state_common.py:283`](../hermes_state_common.py:283)）：

```python
SCHEMA_VERSION = 31
```

整个 `SCHEMA_SQL` 在 [`hermes_state_common.py:372`](../hermes_state_common.py:372) 开始。
一共 12 张表，按用途分四类：**内容**、**路由**、**并发**、**元数据**。

### 3.1 `sessions` —— 会话行（表宽 60+ 列）

[`hermes_state_common.py:382`](../hermes_state_common.py:382)。列非常多，但可以按语义分组：

```sql
CREATE TABLE IF NOT EXISTS sessions (
    -- ① 身份
    id            TEXT PRIMARY KEY,        -- 形如 20260815_143022_a1b2c3
    source        TEXT NOT NULL,           -- 'cli' / 'telegram' / 'cron' / 'subagent' / ...
    created_source TEXT,                   -- 原始来源（source 可变，这个不变）
    parent_session_id TEXT,                -- ← 血缘，见 §7

    -- ② 平台路由（网关用）
    user_id, session_key, chat_id, chat_type, thread_id, display_name, origin_json,
    expiry_finalized INTEGER DEFAULT 0,

    -- ③ 模型与提示词
    model, model_config,                   -- model_config 是 JSON（含 _branched_from 等标记）
    system_prompt,                         -- 遗留列，迁移后为 NULL，见 §3.2
    system_prompt_hash,                    -- ← 指向 system_prompts 表
    tool_names,                            -- tools[] 引脚（JSON），重建 agent 时沿用

    -- ④ 时间与统计
    started_at REAL NOT NULL, ended_at REAL, end_reason TEXT,
    message_count, tool_call_count, api_call_count,
    input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens,
    last_activity_at, last_activity_description, last_activity_provenance,

    -- ⑤ 成本归属（账单核对用）
    billing_provider, billing_base_url, billing_mode,
    estimated_cost_usd, actual_cost_usd, cost_status, cost_source, pricing_version,

    -- ⑥ 工作区快照
    cwd, git_branch, git_repo_root, git_metadata_generation,

    -- ⑦ 标题
    title, title_source,

    -- ⑧ 压缩状态机（见 §7.3）
    compression_failure_cooldown_until, compression_failure_error,
    compression_fallback_streak, compression_ineffective_count,
    compression_recovery_deadline, compression_overload_streak,

    -- ⑨ 跨进程交接
    handoff_state, handoff_platform, handoff_error,

    -- ⑩ 列表 UI 状态
    archived, auto_archived, pinned, hidden, last_read_at, rewind_count,

    profile_name, transport_profile,

    FOREIGN KEY (parent_session_id) REFERENCES sessions(id),
    FOREIGN KEY (system_prompt_hash) REFERENCES system_prompts(hash)
);
```

**值得单独说明的几列**：

| 列 | 为什么存在 |
|---|---|
| `source` vs `created_source` | `source` 会随交接变化（CLI 会话被 gateway 接手），`created_source` 保留「谁生的」 |
| `model_config` | 一个 JSON 大杂烩：`_branched_from`、`_reset_from`、`_delegate_from` 都塞这里（见 §7.2） |
| `compression_*` 六个列 | 压缩失败后的**退避状态机**（冷却到何时、连续失败几次、是否被判无效）——存在行里才能跨进程生效 |
| `handoff_state` | 「CLI 会话转给 Telegram」这类跨表面交接的中间态 |
| `hidden` vs `archived` | `archived`=用户归档；`hidden`=自动隐藏（如空会话） |
| `git_metadata_generation` | 工作区元数据的版本号，避免每轮都跑 `git` 命令 |

### 3.2 `system_prompts` —— 内容寻址的提示词共享

[`hermes_state_common.py:377`](../hermes_state_common.py:377)：

```sql
CREATE TABLE IF NOT EXISTS system_prompts (
    hash   TEXT PRIMARY KEY,     -- sha256(system_prompt)
    prompt TEXT NOT NULL
);
```

写入路径（[`hermes_state.py:511`](../hermes_state.py:511)）：

```python
@staticmethod
def _store_system_prompt(conn, system_prompt: Optional[str]) -> Optional[str]:
    if system_prompt is None:
        return None
    prompt_hash = hashlib.sha256(system_prompt.encode("utf-8")).hexdigest()
    conn.execute(
        "INSERT OR IGNORE INTO system_prompts (hash, prompt) VALUES (?, ?)",
        (prompt_hash, system_prompt),
    )
    return prompt_hash
```

**为什么要把 system prompt 拆出去？**

system prompt 是 25-40K 字符（04 篇 §2）。如果每个会话行都存一份：

```text
1000 个会话 × 35KB = 35MB，而且 99% 的会话用的是同一份提示词
```

内容寻址后：**同一个 hash 只存一份**，`sessions` 行只存 64 字节的 hex。
回读时用 `_session_row_dict`（[`hermes_state.py:531`](../hermes_state.py:531)）把
`_system_prompt_resolved` 字段换回来：

```python
for column in ("system_prompt", "tool_names"):
    if f"_{column}_resolved" in data:
        resolved = data.pop(f"_{column}_resolved")
        if column in data:
            data[column] = resolved
```

**回收**：`_delete_unreferenced_system_prompts`（[`hermes_state.py:523`](../hermes_state.py:523)）
在没有任何会话引用时删掉 —— 注意它**同时检查两个引用方**：

```sql
DELETE FROM system_prompts WHERE NOT EXISTS (
    SELECT 1 FROM sessions WHERE sessions.system_prompt_hash = system_prompts.hash
) AND NOT EXISTS (
    SELECT 1 FROM sessions WHERE sessions.tool_names = system_prompts.hash
)
```

`tool_names` 也指向 `system_prompts`？是的 —— 因为工具列表引脚也是一段可能重复的
JSON 文本，用同一个内容寻址表存。这是「**一张内容表服务多个引用列**」的复用。

前端类比：这是 CDN 的 content-addressed storage（`/assets/<sha256>.js`）。
同一个文件只存一份，任何地方引用 hash。

**迁移的容错设计**（[`hermes_state_schema.py:188`](../hermes_state_schema.py:188)）：

```python
def _dedupe_legacy_system_prompts(self, cursor) -> None:
    """...Any ``OperationalError`` mid-loop returns instead of raising: partial migration is safe
    (the legacy column stays a read fallback; next init resumes), whereas propagating
    left the version below 25 and re-ran this on every open (gateway crash loop)."""
```

**这是迁移代码的教科书式写法**：

```text
❌ 抛异常 → schema_version 停在 24 → 下次启动又跑一遍 → 每次都崩 → 网关崩溃循环
✅ 打日志后 return → 部分行已迁移、部分还用旧列 → 下次启动继续迁移
```

「**迁移必须是可以中途停下、下次继续的**」——这条在所有长期运行的系统里都成立。

### 3.3 `messages` —— 消息行（27 列 + 双投影）

[`hermes_state_common.py:449`](../hermes_state_common.py:449)：

```sql
CREATE TABLE IF NOT EXISTS messages (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id    TEXT NOT NULL REFERENCES sessions(id),
    role          TEXT NOT NULL,
    content       TEXT,                 -- 可能是 JSON 字符串（多模态 parts）
    tool_call_id  TEXT, tool_calls TEXT, tool_name TEXT,
    effect_disposition TEXT,
    timestamp     REAL NOT NULL,
    token_count INTEGER, finish_reason TEXT,

    -- 推理内容：不同 provider 四种形状（06 篇 §9）
    reasoning, reasoning_content, reasoning_details,
    codex_reasoning_items, codex_message_items,

    platform_message_id TEXT,           -- 平台原始 id，用于引用/回复
    observed INTEGER DEFAULT 0,

    -- 压缩标记
    _compressed_summary INTEGER NOT NULL DEFAULT 0,
    active    INTEGER NOT NULL DEFAULT 1,   -- ← 见 §8
    compacted INTEGER NOT NULL DEFAULT 0,

    api_content TEXT,                   -- 实际发给 API 的字节（可能与 content 不同）
    display_kind TEXT, display_metadata TEXT,
    display_identity BLOB, display_order INTEGER,

    -- 身份（schema v31 新增，见 §3.4）
    message_uid TEXT, absorbed_message_uids TEXT,
    tool_call_uids TEXT, tool_call_uid TEXT
);
```

**逐组解释**：

| 组 | 关键点 |
|---|---|
| `content` vs `api_content` | 模型看到的 vs UI 显示的可以不同。`api_content` 保存「实际发出去的字节」用于精确复现 |
| 五种 reasoning 列 | 不是冗余，是**五种 wire 格式**各占一列（OpenAI `reasoning_content`、Anthropic signed `reasoning_details`、Codex `codex_reasoning_items`……）。06 篇 §9 有全表 |
| `tool_call_id` + `tool_calls` + `tool_name` | 一个 assistant 行可以带多个 tool_call；对应的 tool 结果行用 `tool_call_id` 指回去 |
| `observed` | 「这条不是用户发的，是 gateway 观测到的」 |
| `_compressed_summary` | 这一行是压缩产生的摘要（不是原始对话） |
| `display_*` | 前端渲染用的投影（§8.2） |

**为什么 `content` 可能是 JSON 字符串？**
SQLite 只能绑标量。多模态消息（`[{type:"text"},{type:"image_url"}]`）
用**哨兵前缀 + JSON** 编码（[`hermes_state_messages.py:136`](../hermes_state_messages.py:136)）：

```python
@classmethod
def _encode_content(cls, content: Any) -> Any:
    """Serialize list/dict content (multimodal parts) as a sentinel-prefixed JSON string (sqlite3 binds
    only scalars). Lone UTF-16 surrogates (unsanitized web-scraped tool results) are scrubbed here: left
    raw, sqlite3 raises UnicodeEncodeError and the session silently stops persisting.
    """
```

注意后半句：**孤立 UTF-16 代理对**（比如网页爬回来的坏字符）会让 `sqlite3` 抛
`UnicodeEncodeError`，而 `_execute_write` 的重试逻辑不认识这个错误
→ **整个会话静默停止持久化**。所以在**编码点**就洗掉（[`hermes_state_messages.py:109`](../hermes_state_messages.py:109)）：

```python
def _scrub_surrogates(value: Any) -> Any:
    """Lone surrogates make sqlite3 raise UnicodeEncodeError and abort the whole write."""
    return _sanitize_surrogates(value) if isinstance(value, str) else value
```

**教训**：「静默停止持久化」是最难查的一类 bug。所以**在所有写入口做一次数据清洗**，
而不是指望上层都干净。

### 3.4 身份列：`message_uid` / `tool_call_uid`

[`hermes_state_identity.py:1`](../hermes_state_identity.py:1)：

> *"Durable message-identity columns for SessionDB (schema v31): the codec between the live identity keys
> (``agent.message_metadata``) and the ``message_uid`` / ``absorbed_message_uids`` / ``tool_call_uids`` /
> ``tool_call_uid`` columns, shared by the transcript writers, restore, and transcript repair."*

**问题是什么**：`messages.id` 是 SQLite 的 AUTOINCREMENT，**换一个库就变了**。
但内存里的消息 dict 需要在多次 flush 之间保持身份：

```text
第 1 次 flush：[用户消息A, 助手消息B]     → 写入 row 1, 2
第 2 次 flush：[用户消息A, 助手消息B, 工具C] → 前两条是「同一批」，不该重复写
```

如果只按 `id` 判断，第 2 次 flush 时内存里的 A、B 还没有 id。所以需要一个
**独立于数据库的稳定 id**：`message_uid`。

```text
message_uid      每一「次出现」的唯一 id（mint 一次，跨 flush 稳定）
absorbed_message_uids  被 alternation repair 合并进这一行的其它行的 uid
tool_call_uid    某个具体 tool_call 的稳定 id（一个 assistant 行可以有多个）
tool_call_uids   同上，JSON 数组
```

`absorbed_message_uids` 的存在揭示了一个真实场景：`agent/transcript_repair.py`
会把相邻的两条 user 消息合并成一条（满足 OpenAI 的 role 交替要求）。
合并后，**被吃掉的那条的身份不能丢** —— 否则下一次 flush 会以为它没写过，再写一遍。
所以它被记进 `absorbed_message_uids`。

### 3.5 `session_model_usage` —— 按模型的用量分解

[`hermes_state_common.py:482`](../hermes_state_common.py:482)：

```sql
CREATE TABLE IF NOT EXISTS session_model_usage (
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    model TEXT NOT NULL,
    billing_provider TEXT NOT NULL DEFAULT '',
    billing_base_url TEXT NOT NULL DEFAULT '',
    billing_mode TEXT NOT NULL DEFAULT '',
    task TEXT NOT NULL DEFAULT '',
    api_call_count, input_tokens, output_tokens,
    cache_read_tokens, cache_write_tokens, reasoning_tokens,
    estimated_cost_usd, actual_cost_usd,
    cost_status, cost_source, first_seen, last_seen,
    PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task)
);
```

**为什么不用 `sessions` 上的那几列？** 因为一个会话可以用多个模型：

```text
主模型 deepseek-v4.1              → 80% 的 token
辅助模型（记忆抽取、标题生成）gpt-5-mini → 15%
压缩模型 qwen3-30b                → 5%
```

`task` 列区分用途（`main` / `compression` / `title` / `memory` …），
`billing_*` 三列区分「同一个模型经不同渠道计费」。

**主键是 6 列联合键** —— 意味着每次 API 调用要 UPSERT 到这 6 个维度的唯一格子里。
这解释了为什么用量写入要走**后台合并写线程**（[`hermes_state.py:509`](../hermes_state.py:509)）：

```python
# Accounting workers retire when idle so a bound-method target can't keep an abandoned SessionDB alive.
_TOKEN_WRITER_IDLE_SECONDS = 30.0
```

以及 [`hermes_state.py:1586`](../hermes_state.py:1586)：

```python
# queue_token_counts() is a deque append; a single-writer thread applies deltas in
# order, coalescing consecutive deltas whose route fields are EQUAL (so the merged
# UPDATE equals applying them sequentially). Exact readers call flush_token_counts().
```

**设计要点**：token 计数不是「每轮结束写一次」，而是**边流边累积**（流式响应里
每个 chunk 都带 usage）。如果每来一个 delta 就写库，一个 3000 token 的响应会写几百次。
所以：内存 deque 累加 + 后台线程合并 + 相同路由的连续 delta 折叠成一次 UPDATE。

`_TOKEN_WRITER_IDLE_SECONDS = 30.0` 是为了「空闲 30 秒后线程自己退出」——
否则一个被抛弃的 `SessionDB` 会因为线程持有绑定方法而**永远不被 GC**。

### 3.6 路由与并发四表

```sql
-- 网关路由索引：session_key → 该用哪个会话
CREATE TABLE gateway_routing (
    scope TEXT NOT NULL DEFAULT '',
    session_key TEXT NOT NULL,
    entry_json TEXT NOT NULL,
    updated_at REAL NOT NULL,
    PRIMARY KEY (scope, session_key)
);

-- 每后端心跳（多后端共享一个库时，避免误判别的后端「死了」）
CREATE TABLE gateway_heartbeats (
    backend_id TEXT PRIMARY KEY,
    pid INTEGER NOT NULL, started_at REAL NOT NULL, last_heartbeat REAL NOT NULL,
    profile TEXT NOT NULL DEFAULT '', host TEXT NOT NULL DEFAULT ''
);

-- 压缩锁（跨进程）
CREATE TABLE compression_locks (
    session_id TEXT PRIMARY KEY,
    holder TEXT NOT NULL, acquired_at REAL NOT NULL, expires_at REAL NOT NULL
);

-- turn 租约（跨进程）
CREATE TABLE session_turn_leases (
    conversation_id TEXT PRIMARY KEY,
    holder TEXT NOT NULL, acquired_at REAL NOT NULL, expires_at REAL NOT NULL
);
```

`gateway_heartbeats` 的注释（[`hermes_state_common.py:551`](../hermes_state_common.py:551)）解释了动机：

> *"The startup orphan sweep (sessions.startup_orphan_reap) consults this table to avoid reaping
> rows whose owning backend is still alive but just idle (multi-backend state.db shared by isolated
> serve processes)."*

**场景**：Desktop 和 CLI 各有一个 `hermes serve` 进程，共享同一个 `state.db`。
CLI 进程启动时要做「清理上次没关干净的会话」，但它**不能杀掉 Desktop 还在用的会话**。
判据不是「这个会话多久没动」，而是「**拥有它的后端还活着吗**」。

### 3.7 `conversation_generations` —— 一个不许回收的计数表

[`hermes_state_common.py:544`](../hermes_state_common.py:544)，注释长达 20 行，值得完整理解：

```sql
CREATE TABLE conversation_generations (
    source TEXT NOT NULL,
    session_key TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (source, session_key)
);
```

**问题**：Prompt cache 的亲和性作用域（04 篇 §4 的 cache key）需要区分
「同一个 Telegram 聊天里的**不同对话**」。`session_key` 是 per-chat 的，会跨对话复用。

**错误的解法**：数会话行。`SELECT COUNT(*) FROM sessions WHERE session_key=? AND end_reason IN (...)`。

**为什么错**：`delete_session()` 和批量裁剪会删掉已结束的行。于是计数会**倒回去**，
一个已经退休的 cache 作用域 id 被重新发给一个新对话 → **新对话命中旧对话的缓存** →
上下文串味（这是 04 篇说的「220K 会话命中率掉到 1%」的同类问题）。

**正确解法**：一个**只增不减**的计数器，且**永不 GC**：

> *"These rows are deliberately NEVER garbage-collected, including when every session row for the peer
> is gone. Collecting one resets that peer to 'no generation', so its next boundary writes generation = 1
> again and re-issues a `gwk_` scope a retired conversation already used — exactly the ABA this table
> exists to close."*

**ABA 问题**：值从 A 变 B 又变回 A，观察者以为「没变过」。
计数器从 1 涨到 2 再被删除重置成 1，新的对话就拿到了旧对话的身份。

**代价分析**（注释里也写了）：「One (TEXT, TEXT, INTEGER) row per routing peer is the intended,
bounded cost.」——每个路由 peer 一行，**天然有界**，所以永不回收是正确的权衡。

**这条设计值得记住**：当「可以删除」会破坏一个不变量时，就**不要删除**，
先算清楚「不删除的成本是否有界」。

### 3.8 `async_delegations` —— 异步委派的结果投递

[`hermes_state_common.py:582`](../hermes_state_common.py:582)。重点不在列，而在两处注释。

```sql
CREATE TABLE async_delegations (
    delegation_id TEXT PRIMARY KEY,
    origin_session TEXT NOT NULL,
    ...
    state TEXT NOT NULL,                 -- dispatched / completed / failed ...
    delivery_state TEXT NOT NULL DEFAULT 'pending',
    delivery_attempts INTEGER NOT NULL DEFAULT 0,
    delivered_at REAL,
    owner_pid INTEGER, owner_started_at INTEGER,   -- ← 谁在负责投递
    task_json TEXT, result_json TEXT,
    delivery_claim TEXT, delivery_claimed_at REAL, -- ← 投递认领（防重复投递）
    origin_session_id TEXT NOT NULL DEFAULT ''
);
```

**第一处注释**解释了为什么 `origin_session_id` 要显式出现在**规范 schema**里：

> *"Mirrors the delegation tool's own CREATE TABLE (`tools/async_delegation.py`
> `_initialize_schema`). Keeping the canonical fresh-install shape identical to the tool's avoids a
> silent schema drift: the tool's lazy `ALTER TABLE ADD COLUMN` used to be the only source of this
> column, so two databases at the same `schema_version` had different `async_delegations` shapes
> depending on whether the delegation tool had ever run, breaking rebuild/replay pipelines (#94691)."*

**教训**：**同一个 schema_version 必须对应同一个物理形状**。
如果某个列是「某个功能跑过才有」，那么「新建的库」和「老库升级来的库」形状不同，
所有依赖 schema 的工具（备份/恢复/重放/导出）都会出错。所以**惰性建表要合并进规范 schema**。

**第二组列**（`delivery_claim` + `delivery_claimed_at`）实现的是「**至少一次投递 + 幂等去重**」：

```text
投递前先认领（写 claim）→ 投递 → 标记 delivered
                    ↓
         崩溃在中间 → claim 过期 → 另一个进程重新认领
```

而接收端的去重靠 `delegation_id`（[`hermes_state_messages.py:423`](../hermes_state_messages.py:423)）：

```python
def append_delegation_delivery(self, session_id, content, metadata) -> int:
    """Record a detached API result once, between client turns, including replay after rotation.

    The event's unit id, not its text or active flag, is the identity. Check and insert
    share the writer transaction, so independent gateway processes cannot duplicate it.
    """
```

**「检查 + 插入在同一个事务里」** 是去重的唯一正确做法。分成两步做（先 SELECT
发现不存在，再 INSERT）在并发下必然重复。

### 3.9 `state_meta` —— 键值元数据

```sql
CREATE TABLE state_meta (key TEXT PRIMARY KEY, value TEXT);
```

里面放的东西（从各处注释汇总）：

| key | 用途 |
|---|---|
| `_STATE_DB_GENERATION_KEY` | 库文件代际戳（`uuid4().hex`），用于检测「库被别人换掉了」 |
| `store_instance_id` / `store_created_at_utc` | 库的来源溯源（区分「新建」和「被清零后重建」） |
| `fts_stale` / `fts_cjk_stale` | FTS 索引已废弃（上次损坏后主动 detach） |
| `fts_rebuild_high_water` / `fts_rebuild_progress` | 重建的进度边界（见 §9.3） |
| `fts_storage_version` | FTS **布局**版本（与 `SCHEMA_VERSION` 独立，见下） |
| `message_uid_backfill` / `message_uid_backfill_id` | 身份列回填的完成标记与游标 |

**一个重要的设计**（[`hermes_state_common.py:292`](../hermes_state_common.py:292)）：

> *"FTS storage-layout version, tracked INDEPENDENTLY of `SCHEMA_VERSION` in the
> `state_meta` key `fts_storage_version`. The main schema version advances freely on open
> (so future migrations always land); the FTS *layout* only reaches the current version when a DB
> is either born fresh or explicitly optimized via `hermes sessions optimize-storage`."*

翻译：

```text
SCHEMA_VERSION: 打开时立刻升到最新（保证新代码能用新列）
FTS_STORAGE_VERSION: 不主动升（升级 FTS 布局要重建整个索引，几十分钟）
                     → 用户显式跑 `hermes sessions optimize-storage` 才升
```

**为什么要分开？** 因为两种「升级」的成本差三个数量级：

| 升级类型 | 成本 | 能不能自动做 |
|---|---|---|
| 加一列（`ALTER TABLE ADD COLUMN`） | 毫秒 | ✅ 可以，启动时做 |
| 重建 FTS 索引（10GB 库） | 分钟到小时 | ❌ 不能，必须用户选择时机 |

**通用原则**：**把「便宜的兼容升级」和「昂贵的重构」用两个版本号分开**，
否则你要么阻塞启动，要么永远不敢加列。

### 3.10 索引：为什么分成 `SCHEMA_SQL` 和 `DEFERRED_INDEX_SQL`

```sql
-- SCHEMA_SQL 内（[`hermes_state_common.py:612`](../hermes_state_common.py:612)）
CREATE INDEX idx_sessions_source ON sessions(source);
CREATE INDEX idx_sessions_parent ON sessions(parent_session_id);
CREATE INDEX idx_messages_session ON messages(session_id, timestamp);
CREATE INDEX idx_messages_assistant_calls_by_session
    ON messages(session_id) WHERE role = 'assistant' AND tool_calls IS NOT NULL;

-- DEFERRED_INDEX_SQL（[`hermes_state_common.py:635`](../hermes_state_common.py:635)）
-- "Indexes on later-added columns must run AFTER _reconcile_columns(), or executescript fails on legacy DBs."
CREATE INDEX idx_messages_session_active ON messages(session_id, active, timestamp);
CREATE INDEX idx_messages_display_page
    ON messages(session_id, display_order, active DESC, id DESC)
    WHERE active = 1 OR compacted = 1;
```

**为什么延迟？** 老库的 `messages` 表**没有 `active` 列**。`_init_schema` 的顺序是：

```python
cursor.executescript(SCHEMA_SQL)      # ① 建表（IF NOT EXISTS，老库不动）
self._reconcile_columns(cursor)       # ② ALTER TABLE ADD COLUMN，补齐缺失列
...
self._execute_ddl_skipping_settled_triggers(cursor, DEFERRED_INDEX_SQL)   # ③ 才能建依赖新列的索引
```

如果把这个索引放在 `SCHEMA_SQL` 里，`executescript` 会在**第 ② 步之前**执行，
在老库上直接报 `no such column: active` → **整个启动失败**。

**这是一个典型的「DDL 顺序依赖」问题**。前端类比：给已有数据的表加 NOT NULL 列，
必须先加可空列 → 回填 → 再加约束，不能一步到位。

`idx_messages_assistant_calls_by_session` 用**部分索引**（`WHERE`），因为
「assistant 且有 tool_calls」的行在一万条消息里只占一小部分，全表索引太浪费。
注释也解释了为什么它可以放在 `SCHEMA_SQL` 里：「role and tool_calls are base columns」。

### 3.11 `schema_read_probe_statements()`：从 DDL 反推探针

[`hermes_state_schema.py:168`](../hermes_state_schema.py:168)：

```python
def schema_read_probe_statements() -> tuple:
    """SELECT statements that fail iff a live store is behind SCHEMA_SQL. Read-only opens skip
    ``_reconcile_columns()`` (no DDL against another profile's live DB), so healing callers
    run these afterwards: a missing table/column raises at prepare time. Derived from
    SCHEMA_SQL (a hand-maintained list went stale within days). Columns are
    table-qualified: an unqualified double-quoted identifier that fails to resolve silently
    degrades to a string literal (SQLite misfeature) and would pass on the stale store."""
```

三个知识点：

1. **为什么要有这个**：只读打开（跨 profile 聚合）**不能**跑 `_reconcile_columns`
   —— 那是对别的 profile 的活库做 DDL。所以只读打开后要**探测**一下
   「这个库是不是落后于我的 schema」。
2. **为什么不手写清单**：注释说得很直白 ——「a hand-maintained list went stale within days」。
   从 `SCHEMA_SQL` **自动解析**（用内存库跑一遍 `executescript` 再 `PRAGMA table_info`）才不会腐烂。
3. **为什么列名必须带表名前缀**：这是 SQLite 的一个坑 —— 如果 `"active"` 解析不到，
   SQLite 会把它**当成字符串字面量**而不是报错。于是 `SELECT "active" FROM messages`
   在缺列的库上也「成功」了，返回一堆字符串 `"active"`。加上表名前缀 `messages."active"`
   就变成硬错误。

**通用教训**：**「手抄的清单一定会腐烂」，能从权威来源派生的就别手写。**
同一份代码里 [`hermes_state_common.py:177`](../hermes_state_common.py:177) 的
`_READ_PROBE_STATEMENTS` 缓存就是这个派生的结果。

---

## 4. 读写两条路径

`SessionDB` 有**两条完全不同的路径**：读走只读连接池，写走唯一的写连接。

```text
                    ┌─────────────────────────────────┐
   _read_one/_read_all ──► _read_ctx()                │
                    │      ├─ 有池化只读连接 → 直接用（WAL 下不加锁）
                    │      ├─ 池空 → 开新的（需 permit）
                    │      └─ 开不出/没 permit → 降级到写连接 + self._lock（慢但正确）
                    └─────────────────────────────────┘

   _execute_write ───► self._lock + BEGIN IMMEDIATE + commit
                       （全进程只有一个写连接）
```

### 4.1 为什么读要单独一条路径

[`hermes_state.py:597`](../hermes_state.py:597)：

```python
# Read-path split (WAL only): reads borrow from a BOUNDED read-only pool so they
# never queue behind writer flushes on self._lock (see _read_ctx); unbounded
# per-thread connections pinned fds for the process lifetime and hit EMFILE.
self._read_pool: queue.LifoQueue[sqlite3.Connection] = queue.LifoQueue(maxsize=_READ_POOL_MAX)
```

**问题一：读者排队**。如果读也走 `self._lock`，那么一个 5 秒的写事务会让
所有侧边栏轮询卡 5 秒。WAL 模式下读者本来不需要等写者，所以用**独立连接**。

**问题二：fd 耗尽**。每个 SQLite 连接至少 1 个 fd。如果「每个线程开一个连接」，
一个 200 线程的 gateway 就是 200 个 fd。而 ulimit 常见是 1024 甚至 256。
所以池是**有界的**（LIFO，8 个）。

[`hermes_state_readpool.py:44`](../hermes_state_readpool.py:44) 还有一层**进程级**上限：

```python
# Ceiling ALIVE in this PROCESS across every state.db (a multiplexed gateway
# opens one per profile); three profiles' worth, then readers degrade likewise.
# ...(#98573) Past it, readers on the (N+1)th file degrade to their writer connection
# instead of opening descriptors, which is the same trade _READ_POOL_MAX
# makes and for the same reason: a slow read path is recoverable, a process-wide EMFILE is not.
_READ_POOL_PROCESS_MAX = 24
```

**为什么「每个库 8 个」还不够？** 一个 gateway 服务 5 个 profile → 5 个库 × 8 = 40 个。
所以再加一层「整个进程最多 24 个」。

还有第三层：[`hermes_state_readpool.py:56`](../hermes_state_readpool.py:56)

```python
# Descriptors kept in reserve for everything that is NOT this module (httpx
# sockets, terminal pipes, log files): the EMFILE SQLite pushes over surfaces elsewhere.
# The #98573 report is exactly that case: ~20 state.db descriptors were not the whole 256,
# they were the share that pushed httpx and terminal pipes over, and the EMFILE
# surfaced in tools/terminal_tool.py rather than here.
_FD_HEADROOM_RESERVE = 64
```

**这是最值得学的一点**：报错发生在 `terminal_tool.py`，但根因在 state.db 的连接数。
所以修的时候不是去改 terminal_tool，而是让 state.db **主动给别的模块留出 64 个 fd 余量**。

> **「降级而不是崩溃」**：拿不到 permit 时，`_read_ctx` 退到写连接加锁。
> 读取慢一点是可恢复的；进程级 EMFILE 是不可恢复的。

### 4.2 `_read_ctx` 的三条分岔

[`hermes_state.py:921`](../hermes_state.py:921)：

```python
@contextmanager
def _read_ctx(self) -> Iterator[sqlite3.Connection]:
    """Yield a connection for read-only statements: a pooled read-only
    connection with NO lock under WAL; otherwise (non-WAL, open failure,
    ceiling reached) the writer connection under self._lock — deliberate
    degradation: slower beats EMFILE, which the supervisor cannot see."""
    conn = self._checkout_read_conn()
    if conn is not None:
        try:
            yield conn
        finally:
            # ...归还到池；池已关（close() 发生了）则自己关掉
        return
    with self._lock:
        if self._conn is None:  # close() raced a still-unwinding reader
            self._reopen_after_close_locked(context="read")
        conn = cast(sqlite3.Connection, self._conn)
        if self._wal_active or self.read_only:  # WAL: no SHARED-lock wait
            yield conn
            return
        # DELETE-mode writer connection: wait out a sibling's commit like a pooled reader would.
        previous_ms = conn.execute("PRAGMA busy_timeout").fetchone()[0]
        conn.execute(f"PRAGMA busy_timeout={int(_READ_BUSY_TIMEOUT_S * 1000)}")
        try:
            yield conn
        finally:
            with suppress(sqlite3.Error):
                conn.execute(f"PRAGMA busy_timeout={previous_ms}")
```

三条分岔：

| 路径 | 条件 | 加锁 | 为什么 |
|---|---|---|---|
| **A. 池化只读连接** | WAL 且拿到 permit | **不加** | WAL 读者永不阻塞 |
| **B. 写连接（WAL）** | 池不可用 | `self._lock` | 会与写者互相等待，但只能这样 |
| **C. 写连接（DELETE 模式）** | 文件系统不支持 WAL | `self._lock` + 临时 `busy_timeout=5s` | DELETE 模式读者需要 SHARED 锁 |

**注意路径 C 里那个 `PRAGMA` 的 save/restore**：

```python
previous_ms = conn.execute("PRAGMA busy_timeout").fetchone()[0]
conn.execute(f"PRAGMA busy_timeout={int(_READ_BUSY_TIMEOUT_S * 1000)}")
try:
    yield conn
finally:
    with suppress(sqlite3.Error):
        conn.execute(f"PRAGMA busy_timeout={previous_ms}")
```

为什么要临时调高？[`hermes_state.py:191`](../hermes_state.py:191)：

> *"SQLite busy handler budget for reads. Under DELETE (rollback-journal) mode a reader needs a SHARED
> lock, which every commit from another process blocks across its journal+db fsyncs; the writer
> connection's 1 s timeout exists for writes (they retry at application level) and starved readers
> into 'database is locked' (dashboard 503s, `hermes sessions list` crashes) under a busy gateway."*

**这是「同一个连接服务两种用途」时的经典陷阱**：连接的 `busy_timeout` 是为写设置的（1 秒，
因为写会在应用层重试），但读需要更长的耐心（5 秒，因为读**不会**在应用层重试）。
所以**借用时要临时改，还回去要改回**。

### 4.3 `_execute_write`：一个必须读懂的循环

[`hermes_state.py:995`](../hermes_state.py:995) 是整个模块最重要的函数。它的结构：

```text
while True:
    raise_if_db_corrupt()                       # 库已判损坏 → 直接拒绝
    with self._lock:
        raise_if_db_replaced()                  # 文件被换掉了 → 拒绝
        if self._conn is None: reopen()         # close() 抢跑的补救
        BEGIN IMMEDIATE
        try:
            fn_started = True
            result = fn(conn)
            commit()
        except: rollback(); raise
    # 成功
    write_count += 1
    if write_count % 50 == 0: wal_checkpoint(PASSIVE)
    if write_count % 1000 == 0: fts_merge()
    return result

except SessionCompressionInProgressError:   → 短等（5s）后重试，超时则拒绝
except sqlite3.Error as exc:
    ├─ "no more rows" 且还在预算内        → 重试
    ├─ is_sqlite_lock_error:
    │     ├─ 还在预算内                    → 抖动睡眠后重试
    │     └─ 预算耗尽                      → log_write_lock_holders() + 抛「谁的锁」
    ├─ "disk i/o" 且 fn 未开始 且 只重试过 0 次 → 重试（同一连接！）
    ├─ DatabaseError:
    │     ├─ FTS 破损                       → 原子 detach FTS 索引后重试
    │     └─ 结构损坏                       → halt_db_corrupt() 闩锁
    └─ 其它                                 → 抛
```

逐个分支看「为什么」：

**(a) 为什么 `raise_if_db_replaced()` 必须在锁内**

[`hermes_state.py:1016`](../hermes_state.py:1016) 的注释：

> *"the replaced/generation live probe runs INSIDE the lock below, not here. `close()` mutates `_conn`
> and `_db_sidecar_identity` under that same lock, ending the WAL generation (SQLite unlinks the
> `-wal`/`-shm` sidecars on a clean close). A lock-free probe that races `close()` can observe the
> mid-teardown state — sidecars already unlinked while `_db_sidecar_identity` is not yet cleared —
> and misclassify this process's OWN clean close as an externally deleted generation, raising a sticky
> `DeletedWalGenerationError` that permanently refuses later writes (#105567)."*

**这个 bug 的形状很典型**：

```text
线程 A: close()          → 先 unlink -wal/-shm，再清 _db_sidecar_identity
线程 B: 检查文件被换了吗？→ 看到 sidecar 没了，但 identity 还在
                          → 判定「库被外部删了！」
                          → 抛 sticky 错误，此后所有写都失败
```

修法不是「加个 flag」，而是**让检查和它检查的状态在同一把锁下**。

**(b) 为什么 `disk i/o` 重试要「同一连接」**

```python
# Retry on the SAME connection: close()+reopen would cancel this process's
# POSIX locks for every sibling (howtocorrupt §2.2).
ioerr_begin_retried = True
continue
```

**这条反直觉但极其重要**：在 POSIX 上，`fcntl` 锁是**属于进程 + 文件描述符**的。
关闭**任何一个**指向该文件的 fd，都会释放**这个进程在该文件上的所有锁**
（这正是 `fcntl` 的历史缺陷）。而 SQLite 的 WAL 一致性依赖这些锁。

所以：**永远不要用「关了重开」来「修复」SQLite 的临时错误**。这会让别的进程
以为你已经退出了，去 checkpoint / unlink 侧文件，而你还在用被删的 inode。

同一个道理催生了 [`hermes_state_lockguard.py`](../hermes_state_lockguard.py:1)：

> *"SQLite protects a live WAL generation with two POSIX advisory locks: a SHARED lock on the main
> file's lock range and a shared lock on the DMS byte of `state.db-shm`. A sibling process may
> checkpoint and unlink `-wal`/`-shm` at its close only after taking both EXCLUSIVE. POSIX locks
> are per process, so any `open()`/`close()` of those two files inside the holder — a raw probe,
> a plugin, a tool reading `~/.hermes` — cancels both (sqlite.org/howtocorrupt.html §2.2) and the
> next foreign close strands the holder on a deleted generation (`DeletedWalGenerationError`)."*

所以它用 **OFD 锁**（Open File Description locks，Linux 3.15+）"复制"了一份锁，
OFD 锁挂在 open file description 上而不是进程上，因此不会被误 `close()` 取消。

**这条规则对任何在 Hermes 里读 `state.db` 的插件都成立**：
**不要用裸 `open()` 去探 `state.db` / `-shm`**，用提供的 API。

**(c) 三种 `sqlite3` 错误为什么要分开处理**

| 错误 | 含义 | 处理 |
|---|---|---|
| `no more rows` | 争用下的瞬时引擎错误（某些构建抛成 `InterfaceError`） | 重试 |
| `database is locked` | 别人持有写锁 | 抖动重试，耗尽后报告**持有者** |
| `disk I/O error` | 可能是 WAL 转换的毫秒级窗口，也可能是真故障 | **只在回调未开始时**重试一次 |
| `not a database` / `malformed` | 可能是「库被外部换掉」 | 先检查 replaced，再考虑修复 |
| FTS shadow 表损坏 | 是**派生数据**坏了，主表还好 | 原子 detach FTS，重试 |
| 其它 `DatabaseError` | 结构性损坏 | 闩锁 + 拒绝所有写 |

**FTS 那一分支的定义**（[`hermes_state_health.py:49`](../hermes_state_health.py:49)）：

```python
def is_structural_corruption_error(exc: BaseException) -> bool:
    """Canonical B-tree/schema/freelist damage: a corrupt/NOTADB error SQLite does not scope to
    the FTS index, and not the malformed-schema case the web open path repairs."""
    return (
        isinstance(exc, sqlite3.DatabaseError)
        and not is_fts_scoped_corruption_error(exc)
        and not is_malformed_schema_error(exc)
        and classify_persistence_error(exc) == "corrupt"
    )
```

**「FTS 坏了 ≠ 库坏了」是这里最重要的区分**。FTS 是从 `messages` 表派生的索引，
坏了可以丢掉重建（`hermes sessions optimize-storage`）。所以：

```text
结构损坏  → 闩锁，写全部拒绝，要求用户恢复（数据可能真的丢了）
FTS 损坏  → 自动 detach 索引，写继续，搜索暂时退化
schema 畸形 → 网页打开路径可以就地修复
```

**(d) 为什么 `log_write_lock_holders()` 只写日志不写错误消息**

[`hermes_state.py:1076`](../hermes_state.py:1076)：

```python
# Say what actually happened, not disk/permission damage. The holder goes to
# the log, not the message: classify_persistence_error() buckets by phrase and
# a holder's argv (a worktree named fix-corrupt-db) would flip the bucket.
```

**精妙之处**：错误消息会被 `classify_persistence_error()` 按**关键词**分类，
分类结果决定了「给用户看什么建议」。如果错误消息里包含持有者的命令行参数，
而那个参数恰好包含 `corrupt` → 分类器会误判成「库损坏」→ 给用户完全错误的自救指引。

**所以：机器可读的分类输入必须只含系统生成的部分，不含用户可控内容。**

### 4.4 写锁持有者是怎么找出来的

[`hermes_state_lockowners.py:1`](../hermes_state_lockowners.py:1)：

> *"The 'database is locked for over Ns' failure names the victim but not the holder, and the
> open-descriptor scan (`hermes_state_holders`) cannot tell a reader from the one writer: every
> Hermes process has the DB open. SQLite's unix VFS takes `fcntl` byte-range locks whose offsets
> encode the lock kind, and the kernel exports them with the owning pid, so the holder can be named
> at the moment the deadline passes."*

实现是解析 `/proc/locks`（[`hermes_state_lockowners.py:49`](../hermes_state_lockowners.py:49)），
并按 SQLite 的偏移约定翻译：

```python
# sqlite/src/os_unix.c: UNIX_SHM_BASE = (22 + SQLITE_SHM_NLOCK) * 4 = 120; WAL lock i sits at BASE + i.
_SHM_LOCK_NAMES = {
    120: "WAL write",
    121: "WAL checkpoint",
    122: "WAL recover",
    128: "shm dead-man switch",
}
# Rollback-journal / exclusive locks on the main file live in the pending-byte page (1 GiB).
_PENDING_BYTE = 0x40000000
_MAIN_LOCK_NAMES = {
    _PENDING_BYTE: "PENDING",
    _PENDING_BYTE + 1: "RESERVED",
}
```

**这是「不要只看症状」的绝佳例子**：所有 Hermes 进程都打开 `state.db`，
所以「谁开着这个文件」毫无信息量。但**只有写者**持有 `-shm` 的 120 号字节锁。
解析这个偏移，就能在超时那一刻指名道姓。

**注意平台限制**：只有 Linux 有 `/proc/locks`。macOS 上这功能降级（日志里没有持有者）。

---

## 5. WAL 与降级：一个必须承认「文件系统不可靠」的地方

### 5.1 WAL 需要什么，什么文件系统给不了

[`hermes_state_wal.py:25`](../hermes_state_wal.py:25)：

```python
# WAL needs mmap shared memory + fcntl byte-range locks. Network filesystems (NFS, SMB/CIFS, some FUSE,
# WSL1) raise ``locking protocol``; ZFS corrupts the -shm file under concurrent bursts (COW + mmap) ->
# ``disk I/O error``. Either would silently break everything on state.db/kanban.db, so fall back to
# DELETE (readers block on writes).
# "not authorized": some FUSE mounts block the WAL pragma outright.
_WAL_INCOMPAT_MARKERS = ("locking protocol", "not authorized", "disk i/o error")
```

WAL 的 `-shm` 需要**跨进程一致的共享内存**。这在本地 ext4/APFS 上成立，
在网络上不成立：

| 场景 | 后果 |
|---|---|
| `state.db` 放在 NFS/SMB 挂载上 | `locking protocol` 错误，或**静默拒绝**（停在 DELETE） |
| ZFS 上并发写突发 | `-shm` 被写坏 → `disk I/O error` |
| Docker Desktop / OrbStack / Podman bind mount | **零填充页，完全静默**（见下） |
| WSL1 | `locking protocol` |
| 某些 FUSE 挂载 | `not authorized` |

**最危险的是「静默」那一类**（[`hermes_state_wal.py:177`](../hermes_state_wal.py:177)）：

> *"Docker Desktop / OrbStack / Podman expose host bind mounts to the guest as `fuse.virtiofs` or `9p`.
> WAL's `-shm` file must be coherent shared memory for every opener; across the VM boundary it is not,
> and under write pressure the failure is SILENT (zero-filled pages), so the reactive
> `_WAL_INCOMPAT_MARKERS` fallback in `_enable_wal` never gets a signal — WAL must be refused before
> the pragma."*

所以有一条**主动探测**：

```python
_CROSS_VM_FSTYPES = frozenset({"virtiofs", "fuse.virtiofs", "9p", "9p2000", "9p2000.l", "9p2000.u"})
```

读 `/proc/self/mountinfo` 判断文件系统的类型，命中就**根本不去设 WAL**。

**「被动兜底不够，有些失败是静默的」** —— 这条在任何涉及文件系统/网络的设计里都适用。

### 5.2 `apply_wal_with_fallback()` 的全部分支

[`hermes_state_wal.py:254`](../hermes_state_wal.py:254)。这是决策树，值得完整画出来：

```text
apply_wal_with_fallback(conn)
│
├─ configured = resolve_journal_mode()          # config: database.journal_mode（wal|delete，默认 wal）
│
├─ ① 这个 SQLite 有 WAL-reset bug？
│   └─ 是 → _apply_delete_for_wal_reset_bug()   # 新库不给 WAL；已是 WAL 的库保留并告警
│
├─ ② 读磁盘上当前的 journal_mode（_on_disk_journal_mode）
│   ├─ "wal"          → companions + return "wal"（**绝不降级**）
│   ├─ configured=delete → 校验后用 DELETE
│   ├─ None（探测失败）→ 视为「别人持有」，不碰文件 → return "wal"（假设）
│   └─ "delete" / 新库 → 继续
│
├─ ③ 在 cross-VM FS 上？
│   └─ 是 → 拒绝启用 WAL（库里原本是 DELETE 就保持 DELETE）
│
└─ ④ 真的去设 WAL → 失败则按 marker 降级到 DELETE
```

**最关键的一条不变量**（[`hermes_state_wal.py:265`](../hermes_state_wal.py:265)）：

> *"Invariant on every path: never downgrade to DELETE if the on-disk header reports WAL or cannot be
> read — other gateway/cron/worker connections may hold the DB open, and a live downgrade destroys
> their uncheckpointed commits."*

**为什么「热降级」是灾难**：

```text
进程 A 在 WAL 模式下有 500 个未 checkpoint 的帧在 state.db-wal 里
进程 B 把库切成 DELETE 模式
→ B 认为 journal 文件不需要了 → WAL 文件被丢弃
→ A 的 500 个已提交事务**全部消失**
```

所以：**模式是文件级属性，不能由单个进程「按自己的想法」改。**
要改只能「确认没有别人」+「明确的操作路径」。

### 5.3 为什么「有 WAL-reset bug 的版本不给新库用 WAL」

[`hermes_state_wal.py:131`](../hermes_state_wal.py:131)：

```python
def is_sqlite_wal_reset_vulnerable(version_info: Optional[tuple] = None) -> bool:
    """True when the linked SQLite has the WAL-reset bug (3.7.0–3.51.2; fixed 3.51.3+, backports 3.50.7 /
    3.44.6). Pre-WAL libraries are safe. https://sqlite.org/wal.html#walresetbug"""
```

而 [`hermes_state_wal.py:269`](../hermes_state_wal.py:269) 有一段很诚实的自我修正记录：

> *"An earlier revision of the lock-cancellation fix (#71724) reverted it on the theory that DELETE was
> 'the mode that corrupts', but that comparison was confounded: the clean WAL result came from
> SQLite 3.53.1, which carries BOTH the WAL-reset fix AND 3.51.0's defenses against close()-broken
> POSIX locks, so it says nothing about 3.50.4. Re-measured on the actually-bundled 3.50.4 with the
> lock fix in place, WAL and DELETE are both clean (0/3 each) — i.e. there is no evidence that WAL is
> safer here, and upstream still documents the WAL-reset bug as real through 3.51.2..."*

**这段值得全文读三遍**，因为它示范了：

1. **承认之前的实验设计有混杂变量**（用 3.53.1 的结果推断 3.50.4 是无效的）。
2. **在真实版本上重做实验**（bundled 3.50.4，0/3 vs 0/3）。
3. **在没有证据时保持保守**（上游仍认为 bug 真实存在 → 新库不进 WAL）。

### 5.4 macOS 的两个额外 PRAGMA

[`hermes_state_wal.py:103`](../hermes_state_wal.py:103)：

```python
def _apply_macos_checkpoint_barrier(conn) -> None:
    """Enable ``PRAGMA checkpoint_fullfsync`` on macOS. Apple's ``fsync(2)`` guarantees neither
    data-on-platter nor ordering, so without ``F_FULLFSYNC`` a launchd shutdown can turn a
    "durable" checkpoint into a malformed ``state.db``. Checkpoint boundaries only
    (~+0.1 ms/commit vs ~+4 ms for ``fullfsync=1``)."""
```

[`hermes_state_wal.py:117`](../hermes_state_wal.py:117)：

```python
def _enforce_macos_synchronous_full(conn) -> None:
    """Enforce ``PRAGMA synchronous=FULL`` on macOS: with NORMAL a WAL checkpoint
    racing process termination leaves half-written btree pages (``btreeInitPage
    error 11``). Called after every WAL activation so a prior NORMAL never sticks."""
```

**这是「操作系统撒谎」的经典案例**：Darwin 的 `fsync()` 只保证数据到了**驱动缓存**，
不保证到盘。所以必须用 `F_FULLFSYNC`（对应 `checkpoint_fullfsync`）。

而第二个函数的名字里有 **"so a prior NORMAL never sticks"** —— 说明曾经有过
「某处设了 NORMAL，然后在同一条连接上又开了 WAL」的顺序问题。
所以它**每次 WAL 激活后都重新强制一遍**。

### 5.5 checkpoint 策略：PASSIVE，永不 TRUNCATE

[`hermes_state.py:1551`](../hermes_state.py:1551)：

```python
elif not self.read_only and not generation_lost:  # PASSIVE, not TRUNCATE (see docstring)
    try:
        # Every cron run_agent opens+closes a transient SessionDB, so a TRUNCATE here fires
        # a full WAL reset many times/hour, racing the gateway's long-lived writer on large
        # WAL databases and tearing hot B-tree pages -- the #45383 corruption this class's
        # own periodic checkpoint was already made PASSIVE to avoid. TRUNCATE belongs only
        # on a sole-opener/quiescent connection.
        self._conn.execute("PRAGMA wal_checkpoint(PASSIVE)")
```

三种 checkpoint：

| 模式 | 做什么 | 会阻塞别人吗 |
|---|---|---|
| `PASSIVE` | 尽力把 WAL 帧刷回主文件，**不等待读者/写者** | 不阻塞 |
| `FULL` | 等到所有读者都前进后才 checkpoint | 会等 |
| `TRUNCATE` | `FULL` + **把 WAL 文件截断为 0 字节** | 会等，且改变文件 |

**场景**：cron 每小时跑一次 `run_agent`，每次开一个临时 `SessionDB`，用完 `close()`。
如果 `close()` 里做 `TRUNCATE`，那么每小时都强制一次「WAL 文件重构」。
而 gateway 的长驻写者还持着旧的 WAL 帧引用 → **B 树页被撕裂**（issue #45383）。

**所以规则是**：

```text
临时连接 close() → PASSIVE（尽力而为，不等别人）
唯一的打开者 + 静默     → 才允许 TRUNCATE（`hermes db optimize` 这种）
```

### 5.6 周期性 checkpoint 与 WAL 大小上限

```python
# PASSIVE WAL checkpoint every N successful writes.
_CHECKPOINT_EVERY_N_WRITES = 50
```

```python
# Bounded FTS ``'merge'`` (ms of lock each) instead of ``'optimize'`` (9-18s per index on a 10GB
# DB, longer than a writer's patience); up to _COMMANDS_PER_PASS per index, stopping on no-progress.
_FTS_MERGE_EVERY_N_WRITES, _FTS_MERGE_MAX_PAGES_PER_INDEX, _FTS_MERGE_COMMANDS_PER_PASS = 1000, 500, 4
```

**为什么要主动 checkpoint？** 如果只等 SQLite 自己（默认 1000 页阈值），
WAL 文件会一直涨。而且读者越多，自动 checkpoint 越难成功（需要读者前进）。

**为什么 FTS 用 `merge` 而不是 `optimize`？**

```text
optimize:  把整个索引合并成最优形态 —— 10GB 库上 9-18 秒，比写者的耐心还长
merge:     每次合并有限页数 —— 500 页，几毫秒
```

`_FTS_MERGE_COMMANDS_PER_PASS = 4` 又是「一页里做几个 command」，防止一次持锁太久。

而 WAL 本身也有硬上限（[`hermes_state_wal.py:31`](../hermes_state_wal.py:31)）：

```python
# SQLite's default journal_size_limit is -1 (unlimited); see _apply_wal_size_limit.
_WAL_SIZE_LIMIT_BYTES = 64 * 1024 * 1024  # 64 MiB
```

对应的注释（[`hermes_state_wal.py:86`](../hermes_state_wal.py:86)）：

> *"Bound the WAL so it returns space after big transactions. With the default (-1) a checkpointed WAL
> is reused in place, never truncated, so `state.db-wal` keeps the high-water mark of the largest
> transaction ever (a 3 GB optimize left a 3 GB WAL)."*

**这条是纯粹的运维经验**：一次大操作会永久占据磁盘空间，除非你设 `journal_size_limit`。

---

## 6. 并发、锁与租约

Hermes 的并发模型有三层，从内到外：

```text
① 进程内：threading.Lock（self._lock）+ 进程内共享 SessionDB 注册表
② 跨进程同机：SQLite 的写锁 + compression_locks / session_turn_leases 行锁
③ 跨进程跨机（容器）：pidns 戳记 + TTL
```

### 6.1 进程内：为什么需要「共享 SessionDB 注册表」

[`hermes_state_registry.py:1`](../hermes_state_registry.py:1)：

> *"Each bare `SessionDB()` mints its own writer connection, lock, close-time WAL checkpoint
> and token writer thread, and one connection's close-time checkpoint can race another's
> growth (lost/reordered-page-write corruption). This module owns that boundary: one shared
> `SessionDB` per resolved path per process, refcounted, with generation-aware retirement
> when the file is replaced (snapshot restore, recovery swap)."*

**问题场景**：

```python
# gateway 里两个地方各自打开
db1 = SessionDB()      # 写连接 1
db2 = SessionDB()      # 写连接 2  ← 同一个文件！
db1.close()            # 触发 PASSIVE checkpoint
                       # 同时 db2 正在写 → 页被重排/丢失
```

SQLite 的设计假设「同一个文件每个进程一个写连接」。违反它的后果是**静默的数据损坏**，
不是崩溃。所以 Hermes 在进程内强制「每个路径只有一个共享实例」。

生命周期规则（注释里列了 8 条，挑三条最重要的）：

```text
- acquire(path): 返回当前代际并 +1 引用计数
- 共享实例的 close() 只 release 一个引用，不真的拆连接
- 文件 inode 变了（快照恢复、恢复替换）→ 旧代际 RETIRE（不再借出），
  但仍然活着直到所有持有者释放
```

**「拆解必须在注册表锁之外做」**（第 5 条）：

> *"All teardown happens OUTSIDE the registry lock: a final release's WAL checkpoint must
> never stall acquisition for every state.db."*

因为最终释放会做 `PRAGMA wal_checkpoint`，可能耗时几百毫秒。如果在锁内做，
**所有其他库的 acquire 都被卡住**。

**`_TeardownBarrier`**（[`hermes_state_registry.py:48`](../hermes_state_registry.py:48)）解决一个很细的竞态：

> *"A path can own more than one close at a time: the current generation's final release and a
> retired generation's drain are admitted independently under `_lock` and only meet at the lifecycle
> mutex. One event per path is honest only if the LAST admitted teardown settles it. Signalling on the
> first lets `close_all()` return and `acquire()` publish a replacement while an older handle is still
> inside `PRAGMA wal_checkpoint`/sidecar unlink — the exact overlap (#102827) this registry exists
> to forbid."*

图：

```text
close_all() 开始
  ├─ 代际 A 的最终释放 → 已 admitted，正在 checkpoint
  └─ 退休代际 B 的 drain → 已 admitted，正在 checkpoint
       ↓
如果用「一个 event」并在第一个完成时 set()
  → close_all() 返回 → 上层认为「都关完了」→ 打开新代际
  → 但 B 还在 checkpoint / unlink 侧文件 → 重叠！
```

所以 barrier 用**计数**，只有最后一个 `pending` 归零才 `set()`。

### 6.2 跨进程：写锁的抖动重试

[`hermes_state.py:477`](../hermes_state.py:477)：

```python
# ── Write-contention tuning ──
# SQLite's deterministic busy handler convoys under many hermes processes: keep its
# timeout short (1s) and retry with random jitter. Patience is TIME-based (a sibling
# legitimately holds the lock for seconds: checkpoint at close, VACUUM, recovery, FTS
# optimize); attempt-counted budgets destroyed turns on a healthy store.
```

三个决定：

1. **SQLite 的 busy handler 只给 1 秒**（[`hermes_state.py:792`](../hermes_state.py:792)
   的 `timeout=1.0`）。
   **为什么**：SQLite 的 busy handler 是**确定性**的（固定间隔重试）。
   多个进程同时等锁时，它们会**同步重试** → 形成「护航队（convoy）」，
   谁都拿不到锁。短超时 + 应用层随机抖动可以打散。
2. **预算是「时间」不是「次数」**。
   **为什么**：一个兄弟进程合情合理地持锁 3 秒（关库时的 checkpoint、VACUUM）。
   如果是「重试 10 次」，10 × 0.15s = 1.5s 就放弃了 → 健康的库也让 turn 失败。
3. **抖动区间随等待时间变宽**（[`hermes_state.py:497`](../hermes_state.py:497)）：

```python
_WRITE_RETRY_MIN_S, _WRITE_RETRY_MAX_S = 0.020, 0.150  # fast jitter for the first _SLOW_AFTER_S
_WRITE_RETRY_SLOW_AFTER_S = 2.0
_WRITE_RETRY_SLOW_MIN_S, _WRITE_RETRY_SLOW_MAX_S = 0.250, 1.000
```

即：

```text
前 2 秒：每次重试间隔 20-150ms（快速响应，可能马上就通了）
2 秒后：间隔 250-1000ms（避免把 CPU 全烧在争抢上）
```

### 6.3 `compression_locks`：压缩期间的写入闸门

压缩是**唯一合法的「改写历史」操作**（04 篇铁律）。它必须独占会话：

```sql
CREATE TABLE compression_locks (
    session_id TEXT PRIMARY KEY,
    holder TEXT NOT NULL,       -- "pid=1234:pidns=...:host=..." 之类
    acquired_at REAL NOT NULL,
    expires_at REAL NOT NULL
);
```

**一个必须在同一事务里完成的「抢占」**（[`hermes_state_compression.py:61`](../hermes_state_compression.py:61)）：

```python
def _claim_lease_row(conn, table, key_col, key, holder, now, expires_at, stale):
    """Single-transaction lease claim: DELETE a stale holder's row (``stale(holder,
    expires_at)``), INSERT OR IGNORE ours, then SELECT to confirm ownership (INSERT OR
    IGNORE gives no rowcount signal). Returns ``(acquired, reclaimed_holder)``."""
    reclaimed_holder = None
    row = conn.execute(f"SELECT holder, expires_at FROM {table} WHERE {key_col} = ?", (key,)).fetchone()
    if row is not None and stale(row["holder"], row["expires_at"]):
        conn.execute(f"DELETE FROM {table} WHERE {key_col} = ? AND holder = ?", (key, row["holder"]))
        reclaimed_holder = row["holder"]
    conn.execute(
        f"INSERT OR IGNORE INTO {table} ({key_col}, holder, acquired_at, expires_at) VALUES (?, ?, ?, ?)",
        (key, holder, now, expires_at))
    owner = conn.execute(f"SELECT holder FROM {table} WHERE {key_col} = ?", (key,)).fetchone()
    return owner is not None and owner["holder"] == holder, reclaimed_holder
```

四个细节：

1. **整个函数在一个事务里**（调用者用 `_execute_write` 包住）——
   否则「删旧的」和「插新的」之间会有窗口。
2. **`INSERT OR IGNORE` 不给 rowcount**，所以必须再 `SELECT` 确认自己拿到了。
   这是一个常常被忘的坑：`cursor.rowcount` 在 `OR IGNORE` 命中冲突时不可靠。
3. **`DELETE ... AND holder = ?`** —— 只在「我确认它是过期的那一个」时才删。
   防止删除别人刚刚重新抢到的锁（TOCTOU）。
4. **`stale()` 判据是「过期 or 持有者明确死亡」**（[`hermes_state_messages.py:114`](../hermes_state_messages.py:114)）：

```python
def _stale_holder(row, now: float) -> bool:
    """A lock/lease row whose holder is expired or a provably dead local process."""
    from hermes_state import _compression_lock_holder_process_is_dead
    return float(row["expires_at"]) <= now or _compression_lock_holder_process_is_dead(row["holder"])
```

而「明确死亡」的判据**极其保守**（[`hermes_state.py:139`](../hermes_state.py:139)）：

> *"True only when a `pid=<n>` lock holder's local PID is provably gone. Reclaim on kernel proof only:
> unstructured/same-process holders (another thread's live lease) and any probe doubt keep the lease
> until TTL expiry (PID reuse must never steal a live lease; a wrongly-kept one self-heals)."*

**「PID 复用必须永不偷取活租约」**：如果进程 A 死了，它的 PID 被进程 B 复用，
那么「PID 存在」≠「持有者还活着」。反过来的错误更严重：**偷走一个活租约**会导致
两个进程同时压缩同一个会话 → 历史被改两次 → 数据损坏。
所以宁可「错误地保留」（等到 TTL 自然过期，自愈）。

### 6.4 `session_turn_leases`：一次 turn 只有一个 owner

[`agent/turn_facade_lease.py:1`](../agent/turn_facade_lease.py:1)：

> *"One process at a time may load -> run -> flush a session shared through state.db (Desktop, CLI
> resume, gateway, background delivery)."*

```python
LEASE_TTL_SECONDS = 300.0
LEASE_WAIT_SECONDS = 1800.0
```

`300` 秒的 TTL 意味着持有者必须**每 60 秒续租一次**（[`agent/turn_facade_lease.py:52`](../agent/turn_facade_lease.py:52)
的 `refresh_interval` 默认 60）。而 `1800` 秒是**等待**别人释放的上限（用户可能在看长回复）。

**最微妙的一点**（[`agent/turn_facade_lease.py:47`](../agent/turn_facade_lease.py:47)）：

```python
# Wall clock, same as the row's expires_at, never later than it: the row's committed expiry at
# admission, then a timestamp taken BEFORE each successful renewal (the store stamps expiry
# before its lock wait). Only a successful renewal moves it.
self._authority_deadline = ...
```

**为什么「取时间戳要在续租之前」？**
因为续租可能阻塞在写锁上等 3 秒。如果续租成功后才取时间戳，
这 3 秒会被算进「我有权写到什么时候」→ 本地认为还有效，但数据库里的行已经过期了
→ 另一个进程合法地抢走了租约 → **两个进程同时写**。

所以：**本地时钟的权威必须永远 ≤ 数据库里记录的权威**。

**租约丢失怎么办**（[`agent/turn_facade_lease.py:23`](../agent/turn_facade_lease.py:23)）：

```python
# ``tool_reason`` for a lost session turn lease: attributes the stop to the lease, not the user (#112647).
_REASON_LEASE_LOST = "session turn lease lost"
```

它把中断原因归因给**租约**而不是用户。因为 UI 上「用户取消」和「租约丢失」应该有不同的文案。

### 6.5 PID 命名空间：容器场景的必须品

[`hermes_state_pidns.py:1`](../hermes_state_pidns.py:1)：

> *"A `pid=<n>` holder is relative to its writer's PID namespace; a reader in a sibling namespace
> (two containers on one volume, systemd `PrivatePIDs=`) sees a live holder as absent and would
> reclaim its unexpired row. Holders are stamped with `pidns=<inode of /proc/self/ns/pid>` and a
> foreign stamp is never probed."*

场景：

```text
容器 A（PID namespace 1）：进程 42 持有压缩锁，写成 "pid=42"
容器 B（PID namespace 2）：检查 "pid=42 存在吗？" → 在自己命名空间里查到的是**另一个进程**
                          → 判定「42 还活着」→ 不回收（错误但安全）
                          或者判定「42 不存在」→ 回收（错误且危险！）
```

所以持有者字符串里带上了**命名空间戳记**：

```text
pid=42:pidns=4026531836
```

规则：

```text
同命名空间（戳记相同） → 可以探测 PID
异命名空间（戳记不同） → 永不探测，只等 TTL
无戳记（老版本写的）   → 按策略降级（保守：等 TTL）
```

### 6.6 `_timeout` 帮助函数：给用户看的锁报告

[`hermes_state.py:846`](../hermes_state.py:846)：

```python
if now >= deadline:
    log_write_lock_holders(self.db_path, self._WRITE_PATIENCE_S)
    raise
```

`log_write_lock_holders` 内部会调 `parse_proc_locks`，输出类似：

```text
state.db write lock held for 20s by pid=48231 (WAL write) — likely VACUUM, a large
checkpoint, or an older pre-update process
```

**这个信息价值极高**：用户不用猜「是谁卡住了我」，日志里直接写。

---

## 7. 会话血缘（lineage）

### 7.1 五种 `parent_session_id` 关系

`sessions.parent_session_id` 一列承载了**五种语义完全不同**的关系：

```text
                     ┌───────────────────────────────────────┐
                     │  parent (end_reason='compression')    │
                     └──────────────┬────────────────────────┘
                                    │
        ┌───────────────┬───────────┴────────┬─────────────────┐
        ▼               ▼                    ▼                 ▼
   压缩续篇           /branch 分支        /new 重置          子代理
 (真正延续同一对话)   (新对话,共享历史)   (新对话,不共享)    (工具性运行)
        │               │                    │                 │
  _delegate_from     _branched_from      _reset_from       _delegate_from
    = null            = parent_id         = parent_id     = 父 session
```

判别标记全在 `sessions.model_config` 这个 JSON 列里：

| 标记 | 含义 | 出现在 |
|---|---|---|
| `_branched_from` | `/branch` 创建的副本 | 子行 |
| `_reset_from` | `/new` 重置（历史不带过去） | 子行 |
| `_delegate_from` | 子代理运行 | 子行 |

而「压缩续篇」没有标记 —— 它的判据是**父行的 `end_reason == 'compression'`**。

### 7.2 判别逻辑：`_LISTABLE_CHILD_SQL`

[`hermes_state_common.py:239`](../hermes_state_common.py:239) 定义了这个共享谓词，
`_session_filter_where`（[`hermes_state_sessions.py:112`](../hermes_state_sessions.py:112)）用它：

```python
"""Shared ``sessions s`` WHERE builder so counts line up with listed rows. ``exclude_children``
hides sub-agent runs and compression continuations but keeps branch/reset children
(``_LISTABLE_CHILD_SQL``); ``include_subagents`` re-admits the sub-agent runs only
(``sessions.show_subagents``). Clause order is part of the SQL text contract."""
```

**注意最后一句：「Clause order is part of the SQL text contract」**。
这不只是风格问题 —— 有些测试和 trace harness 会 **pin SQL 文本**（空白也算），
所以子句顺序不能随便调。

而 `/branch` 的识别有**两条 OR 起来的判据**（[`hermes_state_sessions.py:128`](../hermes_state_sessions.py:128)）：

> *"Branch sessions are identified two ways, OR'd for robustness: 1. A stable `_branched_from` marker
> in `model_config`, written by `/branch` at creation time. This survives the parent being reopened
> and re-ended with a different `end_reason` (e.g. tui_shutdown overwriting 'branched'), which
> otherwise hides the branch — see issue #20856. 2. The legacy heuristic (parent ended with 'branched'
> before the child started), covering branch sessions created before the marker existed."*

**这是一个「引入新机制后必须保留旧路径」的典型**：

```text
老库：没有 _branched_from 标记 → 只能靠启发式（父行 end_reason='branched' 且时间在前）
新库：有标记 → 精确
两者 OR → 新老库都能正确列出
```

而且注释解释了**为什么启发式不可靠**：`tui_shutdown` 会把 `branched`
覆写成 `tui_shutdown` → 启发式失效 → 所以新机制必须存在。

### 7.3 `_resume_lineage_ids()`：恢复时到底加载哪些行

[`hermes_state_messages.py:1677`](../hermes_state_messages.py:1677)：

```python
def _resume_lineage_ids(self, session_id: str) -> list[str]:
    """Session ids a display resume materializes: the VERIFIED compression lineage (root → tip; each
    hop's parent ended ``compression`` and the child is a genuine continuation), or the session alone
    for anything else — an explicit ``/branch`` copy, an API fork, a reset child, or a plain session.
    The raw parent walker ``_session_lineage_root_to_tip`` is intentionally NOT used here: it crosses
    fork/reset boundaries and misclassifies API forks (parent ended ``branched``, no marker) as
    compression lineages. Shared with the resume guard so it counts exactly what a resume loads."""
```

**核心洞察**：恢复会话时需要**沿压缩链向上收集**所有历史（因为压缩把旧行留在了祖先会话里）。
但**不能沿 fork/reset 边界收集** —— 那些是**不同的对话**。

```python
while len(chain) < 100:  # defensive bound, same as _session_lineage_root_to_tip
    if not self._is_compression_child_row(current):
        break
    parent = self.get_session(current["parent_session_id"])
    if not parent or parent["id"] in seen:
        break
```

两个防御：

- `len(chain) < 100`：防止病态数据里的超长链
- `parent["id"] in seen`：**防止环**

**为什么会有环？** 如果两行互相是对方的 parent（数据被手工改坏、或者某个 bug 写错），
朴素实现会**无限循环**直到 OOM。

而 `_CHAIN_CAP` 是另一个更大的限制（[`hermes_state_compression.py:81`](../hermes_state_compression.py:81)）：

```python
# Defensive bound on the forward compression-chain walk; ``seen`` guards cycles.
# 100 truncated real compression lineages (~180 deep), stranding root→tip walks
# on a stale mid id (#125041). Named so tests can simulate the REAL walk.
_CHAIN_CAP = 1000
```

**这是一条极好的教训**：最初设的 100 是基于「不可能这么深」的直觉，
但真实用户的压缩链达到 **180 深**（一个长期运行、反复压缩的会话）。
于是 `100` 的界限把 root→tip 的遍历截断在中间 → 恢复时只加载了半截历史。

**「防御性上限」的数值必须来自真实数据，而不是直觉。**

### 7.4 压缩血缘的双向 SQL

[`hermes_state_sessions.py:48`](../hermes_state_sessions.py:48) 用 `WITH RECURSIVE` 同时向两个方向走：

```sql
WITH RECURSIVE
  ancestors(id) AS (
    SELECT ?                                  -- 起点
    UNION
    SELECT parent.id
    FROM ancestors a
    JOIN sessions child ON child.id = a.id
    JOIN sessions parent ON parent.id = child.parent_session_id
    WHERE parent.end_reason = 'compression'    -- ← 只有压缩边
  ),
  descendants(id) AS (
    SELECT ?
    UNION
    SELECT child.id
    FROM descendants d
    JOIN sessions parent ON parent.id = d.id
    JOIN sessions child ON child.parent_session_id = parent.id
    WHERE parent.end_reason = 'compression'
  ),
  lineage(id) AS (
    SELECT id FROM ancestors UNION SELECT id FROM descendants
  )
```

**为什么两个方向都要？**

```text
用户打开一个中间代际的会话（比如从 /branch 出来的、或者历史 URL）
  → 向前：需要祖先的行（被压缩归档的）
  → 向后：需要后代的行（压缩续篇里新增的）
  → 合起来才是「这条对话的完整视图」
```

而 [`hermes_state_sessions.py:154`](../hermes_state_sessions.py:154) 的
`_expand_compression_lineage_ids` 用 SQL 做同样的事，但**带了完整的 child 过滤**：

```python
child_filter = (
    f"{_sql_json_extract('child.model_config', '$._branched_from')} IS NULL "
    f"AND {_sql_json_extract('child.model_config', '$._delegate_from')} IS NULL "
    f"AND NOT ({_RESET_CHILD_SQL.format(a='child')}) "
    "AND COALESCE(child.source, '') != 'tool'"
)
```

**这就是「压缩续篇」的精确定义**：

```text
父 ended with 'compression'
AND 子 不是 branch
AND 子 不是 delegate
AND 子 不是 reset
AND 子 不是 tool 会话
```

四条例外缺一不可。少一条就会把「/branch 出来的新对话」误当成「压缩续篇」，
于是两个对话的历史被混在一起。

### 7.5 `_CHAIN_STEP_SQL`：向前走一步时的优先级

[`hermes_state_compression.py:29`](../hermes_state_compression.py:29)：

```sql
SELECT child.id
FROM sessions parent JOIN sessions child ON child.parent_session_id = parent.id
WHERE parent.id = ?
  AND parent.end_reason = 'compression'
  AND ...（四条过滤）
ORDER BY
  CASE
    WHEN child.end_reason = 'compression' THEN 0    -- ① 自己也压缩过的（更靠后）
    WHEN child.ended_at IS NULL THEN 1              -- ② 还活着的
    ELSE 2                                          -- ③ 其它
  END,
  {_sql_session_last_active("child")} DESC,
  child.started_at DESC,
  child.id DESC
LIMIT 1
```

**为什么优先选「自己也压缩过」的子行？** 因为那意味着链条更长，
沿着它走能直接到 **tip**（当前活跃的末日代际）。

注释还解释了一个陷阱（[`hermes_state_compression.py:25`](../hermes_state_compression.py:25)）：

> *"A reset fork is a separate user-visible conversation (`_LISTABLE_CHILD_SQL` already surfaces it as
> its own row), so following it here would hijack the lineage tip projection onto the reset sibling
> and make the real continuation invisible (#114271)."*

即：如果不过滤 reset fork，那么「找这个会话的最新续篇」会返回**用户 `/new` 出来的那个新对话**
→ 用户在 A 会话里，界面显示的却是 B 会话的内容。

### 7.6 `end_session()` 的「first stamp wins」

[`hermes_state_sessions.py:520`](../hermes_state_sessions.py:520)：

```python
def end_session(self, session_id: str, end_reason: str) -> None:
    """Mark a session ended; the first end_reason wins (a compression split must keep
    ``'compression'`` even if a stale end_session() lands later); reopen_session() to re-end."""
    self._execute_write(lambda conn: self._end_and_bump(
        conn, "UPDATE sessions SET ended_at = ?, end_reason = ? WHERE id = ? AND ended_at IS NULL",
        (time.time(), end_reason, session_id), session_id, end_reason,
    ))
```

关键在 `AND ended_at IS NULL`：

```text
压缩进程： UPDATE ... SET ended_at=now, end_reason='compression'   ✅ 成功
UI 进程： UPDATE ... SET ended_at=now, end_reason='tui_shutdown'   ❌ 0 rows（已结束）
```

**为什么必须这样**：如果 UI 的关闭覆盖了 `'compression'`，
那么血缘判据（`parent.end_reason == 'compression'`）就失效了
→ 压缩续篇被当成普通孤儿会话 → **整条对话历史断裂**。

`_end_and_bump` 还做了一件事：**只有真的改动了行才推进对话代际**（§3.7）：

```python
def _end_and_bump(self, conn, sql, params, session_id, reason) -> int:
    """Run an end-stamp UPDATE; only a boundary this call actually wrote advances the
    conversation generation (a no-op must not rotate the peer). Returns rowcount."""
    changed = conn.execute(sql, params).rowcount
    if changed:
        self._bump_conversation_generation(conn, session_id, reason)
    return changed
```

**「no-op 不能推进代际」**：如果一个过期的 `end_session` 落地（0 行改动）却推进了计数器，
那么当前对话的 cache 作用域会**莫名失效** → 命中率下跌。

### 7.7 `end_reason` 的三类

[`hermes_state_common.py:178`](../hermes_state_common.py:178)：

```python
_RESET_END_REASONS = ("session_reset", "session_switch", "idle", "daily", "suspended", "resume_pending_expired")
_BOUNDARY_END_REASONS = frozenset(_RESET_END_REASONS) | {"new_session"}
_RECOVERABLE_END_REASONS = ("agent_close", "ws_orphan_reap", "superseded_by_resume", "startup_orphan_reap")
```

| 类别 | 含义 | 后果 |
|---|---|---|
| `compression` | 被压缩拆分了 | **血缘边**，续篇继承历史 |
| `_RESET_END_REASONS` | 对话边界（重置/切换/空闲/跨天/挂起） | **推进代际**，新对话不继承 |
| `_RECOVERABLE_END_REASONS` | 非正常结束（进程崩溃/孤儿回收） | **可以重新打开**继续 |
| 其它（`tui_close`、`cli_close`、`webhook_complete`…） | 显式关闭 | 需要 host 证明才能重开 |

[`hermes_state_compression.py:87`](../hermes_state_compression.py:87) 的
`reopen_if_explicitly_closed` 专门处理最后一类：

> *"Clear an explicit-close stamp (`tui_close`, `cli_close`, `webhook_complete`, ...) from a session
> a HOST has just proven is still routed to it, returning the reason cleared or None (#106459).
> Narrow twin of `reopen_session()`: automatic stamps are left to publish (#88197); `compression`,
> boundary (reset reasons, CLI `new_session`) and stamps with a published continuation own lineage
> elsewhere and are never touched."*

**它拒绝处理的三类**：

```text
automatic stamps   → 让它们自己 publish（有别的机制管）
'compression'      → 血缘归别人管，不能清
boundary reasons   → 那是真正的对话边界，不能清
有 published continuation 的 → 已经分叉了，不能清
```

而它的 UPDATE 是**条件式的**（`WHERE ended_at = ? AND end_reason = ?`）：

> *"The UPDATE is conditional on the exact stamp read, so a close landing between read and write survives."*

**这是「比较并交换（CAS）」在 SQL 里的写法**。如果不带条件，
读到 `tui_close` 之后、写之前，另一个进程把它改成了 `cli_close`，
那么这次 UPDATE 会把别人的新标记**清掉**。

---

## 8. 消息表的双投影

### 8.1 `active` / `compacted`：为什么一行可以「活着」和「归档」同时存在

[`website/docs/developer-guide/session-storage.md:72`](../website/docs/developer-guide/session-storage.md:72)：

> *"In-place compaction archives old rows with `active=0` and inserts the retained context as `active=1`
> rows. A protected message can therefore legitimately appear in both generations with identical
> content and timestamp. Do not delete these archive rows as duplicates. Diagnose duplicate *live*
> writes using `active=1`, and check the database's profile as well as the session ID when
> investigating history that appears to revert."*

**两种压缩方式并存**：

| 方式 | 做法 | `parent_session_id` |
|---|---|---|
| **拆分会话**（split） | 新建一个会话行，旧的 `end_reason='compression'` | 有 |
| **就地压缩**（in-place） | 同会话行内，旧行 `active=0, compacted=1`，新行 `active=1` | 无 |

就地压缩留下的状态：

```text
messages 表 for session X:
  id=1  role=user      content="..."  active=0  compacted=1   ← 归档
  id=2  role=assistant content="..."  active=0  compacted=1   ← 归档
  id=3  role=user      content="摘要..." active=1              ← 保留的摘要
  id=4  role=user      content="..."  active=1  compacted=1   ← 受保护的原消息（两代都有！）
```

第 4 行是**受保护消息**（最近的用户轮次，不能被压掉）。它既出现在归档代际里，
也出现在活跃代际里，**内容和时间戳完全相同**。

**所以诊断规则**（注释里给了）：

```text
看到重复行  → 先看 active。都是 active=1 才是真的重复写
            一条 active=0 + 一条 active=1 → 正常的两代归档
```

**还有一条**：「check the database's profile as well as the session ID」——
如果历史「看起来回退了」，可能是**你连到了错的 profile 的库**。

### 8.2 `display_*` 列：给前端的第三个投影

```sql
display_kind TEXT,        -- 'async_delegation_complete' / 'hidden' / ...
display_metadata TEXT,    -- JSON：任意 UI 元数据
display_identity BLOB,    -- 内容哈希（存储无关的身份）
display_order INTEGER     -- 显示顺序（可能被重算）
```

`display_metadata` 是最活跃的一列，它承载：

| 用途 | 键 | 见 |
|---|---|---|
| 工具卡片「重试」结果 | `retried` | [`hermes_state_tool_retries.py:17`](../hermes_state_tool_retries.py:17) |
| 排队中的 prompt | `_queued_prompt` | [`hermes_state_common.py:80`](../hermes_state_common.py:80) |
| 消息被 API 独占（不显示） | `MODEL_ONLY_DISPLAY_METADATA_KEY` | [`hermes_state_messages.py:14`](../hermes_state_messages.py:14) |

**注意一个设计选择**（[`hermes_state_tool_retries.py:1`](../hermes_state_tool_retries.py:1)）：

> *"a card's Retry (the start_chat handoff card) records its outcome on the original tool row's
> `display_metadata`. The row the model replays stays byte-identical, so the cached prefix survives;
> a reload shows the outcome, and `announced` tells the model once, on the next user turn (the
> reactions pattern)."*

**这里踩到了 04 篇的铁律**：模型 replay 的消息必须**字节相同**才能命中缓存。
所以「重试成功」这个信息**不能改 `content`**，只能写成 `display_metadata`
（模型看不到，UI 能看到）。

而模型最终怎么知道？**通过 `announced` 标志 + 下一轮的用户消息**：

```python
def take_unannounced_tool_retries(self, session_id: str) -> list[dict[str, Any]]:
    """``{result, tool_name}`` for each retry the model has not heard about yet, marked announced."""
```

**这是「不破坏缓存地传递信息」的第三个范式**（04 篇 §5 讲了四个）：
写进模型的不可见侧信道 + 在下一个合法的注入点告诉它。

**性能细节**（[`hermes_state_tool_retries.py:52`](../hermes_state_tool_retries.py:52)）：

```python
# Every turn of every desktop chat asks. The LIKE pre-filter skips the JSON parse on rows that cannot hold
# the key (nearly all of them); json_extract still decides.
f"AND display_metadata LIKE '%\"{key}\"%' "
f"AND {_sql_json_extract('display_metadata', '$.' + key)} IS NOT NULL ORDER BY id")
```

先用 `LIKE` 粗筛（可以用不上索引，但能在解析 JSON 前排除 99.9% 的行），
再用 `json_extract` 精确判定。注释还说了「Read first so those turns never take the write lock」——
**先读一遍，没有待宣告的就直接返回，不进入写事务**。因为每轮都会问，
绝大多数轮次答案是「没有」，不能让这些轮次白白抢写锁。

### 8.3 `api_content`：为什么需要存两份内容

```sql
api_content TEXT,   -- 实际发给 API 的字节（可能与 content 不同）
```

场景：`content` 里是 `@file` 引用、富文本、或被 turn override 改过的展示版本；
而**真正序列化进 `turn/start` 的字符串**是另一份。

Codex 的输入所有权规则依赖这个（[`website/docs/developer-guide/session-storage.md:81`](../website/docs/developer-guide/session-storage.md:81)）：

> *"At the runtime splice boundary, Hermes excludes only that leading item when it exactly matches
> the text serialized into `turn/start`, including rich-input coercion."*

**「恰好匹配」需要精确的字节**，所以必须存一份 `api_content`。

---

## 9. 三套 FTS 索引

### 9.1 为什么是三个而不是一个

| 索引 | 分词器 | 适合 | 不适合 |
|---|---|---|---|
| `messages_fts` | `unicode61` | 西文单词 | CJK |
| `messages_fts_trigram` | `trigram` | 子串匹配、CJK ≥3 字 | **1-2 字的 CJK 词** |
| `messages_fts_cjk` | `cjk_unicode61`（自研） | CJK 1-2 字 | — |

`trigram` 的致命缺陷（[`hermes_state_fts.py:33`](../hermes_state_fts.py:33)）：

> *"The trigram tokenizer needs >=3 chars per query term, so 1-2 char CJK terms (ubiquitous in
> Korean/Chinese: 일본, 구글, 项目, ...) fall through to a LIKE full-table scan — measured 3-6s CPU per
> query on multi-GB installs and the dominant base cost of session_search on CJK workloads."*

「项目」只有 2 个字 → trigram 无法索引 → 退化到 `LIKE '%项目%'` 全表扫 → **每次 3-6 秒 CPU**。

解决方案是**自研分词器**（[`hermes_state_fts.py:35`](../hermes_state_fts.py:35)）：

> *"`cjk_unicode61` (native/fts5_cjk/, a ~250-line loadable FTS5 tokenizer with no dependencies) wraps
> unicode61: maximal CJK runs are re-emitted as overlapping character bigrams (Lucene CJKAnalyzer
> semantics), everything else passes through unchanged. FTS5 phrase semantics turn a query term's
> consecutive bigrams into exact substring matching down to 2 chars at index speed."*

即：

```text
文本 "项目管理系统"
     ↓ cjk_unicode61 切成重叠的 bigram
["项目", "目管", "管理", "理系", "系统"]
     ↓ 查询 "项目管理" 也被切成 ["项目", "目管", "管理"]
     ↓ FTS5 的 phrase 语义要求这几个 bigram **连续出现**
     → 等价于子串匹配 "项目管理"，但是走索引
```

**这是一个「用短语语义模拟子串匹配」的漂亮技巧**，值得单独记一笔。

### 9.2 「派生索引损坏不能拖垮主表」

三套索引都是 `external-content`（内容在 `messages` 表里，索引只存倒排）：

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts_cjk USING fts5(
    content, tool_name, tool_calls,
    content='messages_fts_cjk_src',      -- ← 视图，不是 messages 表本身
    content_rowid='id',
    tokenize='cjk_unicode61'
);
```

注意 `content='messages_fts_cjk_src'` 指向一个**视图**：

```sql
CREATE VIEW IF NOT EXISTS messages_fts_cjk_src AS
    SELECT id, role, content, tool_name, tool_calls
    FROM messages
    WHERE role <> 'tool';
```

**为什么要隔一个视图？** 因为 external-content 表在更新/删除时，
SQLite 会**从 content 表读回旧值**构造 `'delete'` 命令。如果 content 源是
「会变化的东西」（比如带 `WHERE id > 某个游标`），读回的值和当初索引的值不一致
→ 索引与存储漂移 → `checksum mismatch`。

[`hermes_state_common.py:308`](../hermes_state_common.py:308)：

> *"Tool results are often multi-megabyte machine payloads. The base FTS index stores only a bounded
> prefix of every tool row; tool rows are skipped by default in search... The projection below is
> STABLE — it depends only on the row being written, never on mutable `state_meta` markers — which is
> what keeps the external-content integrity checker and the trigger 'delete'/'update' commands in
> agreement with the stored index forever."*

而 `FTS_STORAGE_VERSION` 的演进史（[`hermes_state_common.py:298`](../hermes_state_common.py:298)）就是
三次修正「漂移」的过程：

```text
1 = v23 external-content layout with a tool-row-excluded trigram
2 = trigram also excludes structured tool_calls JSON
3 = messages_fts source aligned to a stable projection view (messages_fts_src):
    always-truncate tool rows to the prefix, no moving high-water boundary
```

**版本 3 的注释点明了根因**：

> *"The external-content source now reads back EXACTLY what the triggers indexed, so the rank=1
> 'integrity-check' probe cannot drift from the stored index (the recurring fts5 'checksum mismatch' /
> leaked-token failures)."*

### 9.3 高水位标记与「陈旧索引」

重建 10GB 库的索引要几十分钟。如果中途失败，索引是**半成品**。
所以用一个「高水位 + 进度」的标记对（[`hermes_state_fts.py:56`](../hermes_state_fts.py:56)）：

```sql
CREATE TRIGGER IF NOT EXISTS messages_fts_cjk_insert AFTER INSERT ON messages
WHEN new.role <> 'tool'
   AND (new.id > COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                           WHERE key = 'fts_cjk_rebuild_high_water'), -1)
     OR new.id <= COALESCE((SELECT CAST(value AS INTEGER) FROM state_meta
                            WHERE key = 'fts_cjk_rebuild_progress'), -1))
BEGIN
    INSERT INTO messages_fts_cjk(rowid, content, tool_name, tool_calls)
    VALUES (new.id, new.content, new.tool_name, new.tool_calls);
END;
```

语义是：

```text
重建范围：id ∈ (progress, high_water]  ← 这一段由重建器负责
触发器负责：id > high_water 或 id <= progress  ← 这两段由触发器负责
```

于是**重建期间**新写入的行也进索引，且**不会和重建器重复处理**。

**如果分词器加载不了怎么办**（[`hermes_state_fts.py:24`](../hermes_state_fts.py:24)）：

> *"The table exists ONLY when the tokenizer loads; a process that cannot load it drops the cjk
> triggers (writes keep working; the index goes stale until the next optimize-storage)."*

**「丢掉索引，保住主表」** 是这里一贯的取舍：

```text
索引坏了 → 搜索退化（用户可感知，但可恢复）
主表坏了 → 对话丢失（不可恢复）
所以永远优先保主表
```

而「陈旧」本身也是一个持久状态（`fts_stale` / `fts_cjk_stale` 在 `state_meta` 里）：

```python
if self._fts_stale:
    # A prior process detached FTS after corruption; stay detached until a full rebuild.
    self._drop_all_fts_triggers(cursor)
if not fts5_available:
    # Existing FTS triggers would still fire though this runtime cannot read their
    # targets. Drop only the triggers; a future FTS5 runtime recreates them.
    self._drop_fts_triggers(cursor)
```

**「触发器也要一起 drop」** 是关键：如果只标记「索引陈旧」但触发器还在，
那么每次写都会尝试更新一个坏索引 → 每次写都失败。

### 9.4 查询输入净化

[`hermes_state_search.py:38`](../hermes_state_search.py:38)：

```python
# Characters FTS5's query grammar rejects outside a quoted phrase (anything missing
# reaches MATCH raw and raises -> zero results). ``%`` is deliberately excluded: the
# CJK LIKE fallback needs it literal (that path escapes wildcards itself).
_FTS5_SPECIAL_CHARS = '+{}():"^@/#&|~[]<>,;!?$=\\\''
```

**问题**：用户搜 `C++` → FTS5 语法错误 → 整个 `session_search` 抛异常。

**为什么 `%` 被排除在外**？因为 CJK 走的是 `LIKE` 回退路径，那条路径**需要 `%` 是字面量**
（它自己会转义 `%` 和 `_`）。如果在这里也把它当特殊字符剥掉，用户搜 `100%` 就搜不到了。

**「同一个净化函数服务两条不同的查询路径」时的陷阱**：两条路径的特殊字符集**不同**，
必须显式排除差异。

另外还有长度上限（[`hermes_state_common.py:329`](../hermes_state_common.py:329)）：

```python
# Cap on user-controlled FTS5 query input before sanitizer processing.
MAX_FTS5_QUERY_CHARS = 2_048
```

**「在任何用户可控输入进入解析器之前先截断」** —— 这是防 ReDoS / 防超长查询的标准做法。

### 9.5 `_CONTEXT_WINDOW_SQL`：给搜索结果配上下文

[`hermes_state_search.py:60`](../hermes_state_search.py:60)：

```sql
WITH target AS (
    SELECT session_id, timestamp, id FROM messages WHERE id IN ({ids})
)
SELECT t.id AS match_id, m.role, m.content
FROM target t JOIN messages m ON m.id IN (
    t.id,
    (SELECT p.id FROM messages p
     WHERE p.session_id = t.session_id AND (p.timestamp, p.id) < (t.timestamp, t.id)
     ORDER BY p.timestamp DESC, p.id DESC LIMIT 1),   -- 前一条
    (SELECT n.id FROM messages n
     WHERE n.session_id = t.session_id AND (n.timestamp, n.id) > (t.timestamp, t.id)
     ORDER BY n.timestamp, n.id LIMIT 1)              -- 后一条
)
ORDER BY t.id, m.timestamp, m.id
```

技巧在**元组比较** `(p.timestamp, p.id) < (t.timestamp, t.id)`：

```text
只按 timestamp 排序 → 同一毫秒内的多条消息顺序不定 → 可能跳错邻居
按 (timestamp, id) 排序 → 完全确定
```

而且它用 `idx_messages_session(session_id, timestamp)` 索引做**索引定位**，
不是扫整个会话。注释也说了：「Indexed neighbor seeks avoid scanning whole sessions for a
sparse set of hits.」

---

## 10. 健康、修复与测试隔离

### 10.1 结构损坏闩锁（latch）

[`hermes_state_health.py:1`](../hermes_state_health.py:1)：

> *"A structurally corrupt state.db used to show up as an empty or partial Desktop sidebar,
> green readiness and a 500 from `/api/sessions`: every surface guessed on its own and none said
> 'the store is damaged' (#72046). This module is the single place that fact is recorded."*

**问题**：库坏了以后，各个面**各自**给出不同的错误：

```text
Desktop 侧边栏：空的（看起来像「没有会话」）
健康检查：绿色（看起来一切正常）
/api/sessions：500（看起来是接口 bug）
```

用户在三个地方得到三个互相矛盾的信号 —— 这是最糟的失败模式。

**解法**：一个**进程级、按路径**的闩锁：

```python
STORAGE_OK = "ok"
STORAGE_CORRUPT = "corrupt"

def mark_storage_corrupt(db_path, reason) -> None:
    """Latch *db_path* as corrupt for the life of this process (idempotent)."""
```

**三条设计决定**（都在 docstring 里）：

1. **只闩锁「结构性损坏」**，不闩锁 FTS 损坏和 schema 畸形（那两种有各自的修复路径）。
2. **永不自动清除**：「a store that flickers between 'ok' and 'corrupt' is the silent failure
   this replaces.」
3. **不写磁盘标记**：「No marker is written to disk: the file it would describe is the one that is
   damaged.」—— 你没法把一个「这个文件坏了」的标记写进那个坏文件里。

**「不写磁盘标记」这句是神来之笔**：它指出了「用被损坏的对象保存关于它损坏的元数据」这个逻辑矛盾。

### 10.2 打开流程的七道防御

`_open_writer()`（[`hermes_state.py:677`](../hermes_state.py:677)）在真正 `connect` 之前做了七件事：

```text
① mkdir_under_hermes_home()          不复活已删除的 profile（§2.6）
② preflight_db_writability()         只读文件/权限问题 → 给出可操作的消息，而不是
                                     "attempt to write a readonly database"
③ quarantine_cross_process_lock()    跨进程锁：串行化「检查 → 隔离 → 建表 → 提交」
④ has_invalid_sqlite_header_preopen  零字节/无头文件 → 隔离为 .corrupt 备份，重建新库
⑤ refuse_deleted_wal_generation()    别人的 -wal 被删了但还持有 → 拒绝，不制造新 WAL
⑥ _secure_state_db_files(create_main=True)  0600 权限（umask 022 会留 0644）
⑦ apply_wal_with_fallback()          §5.2
```

**第 ③ 步的注释**（[`hermes_state.py:687`](../hermes_state.py:687)）：

> *"Serialize zero-byte check, quarantine, connect and schema commit so concurrent openers don't race
> the absent-path -> schema-commit window."*

场景：两个进程同时首次启动，`state.db` 不存在。

```text
进程 A: 检查"不存在" → 开始建表
进程 B: 检查"不存在" → 也开始建表      ← 两个进程同时 executescript(SCHEMA_SQL)
        → 一个成功，另一个撞 table already exists / database is locked
```

**第 ⑥ 步的注释**值得完整读（[`hermes_state.py:244`](../hermes_state.py:244)）：

> *"SQLite otherwise creates `state.db`, `-wal`, and `-shm` according to the process umask
> (commonly 0644 under 0022)... Existing files are tightened with `chmod(2)` on the path: opening the
> file and closing that descriptor would drop every POSIX `fcntl` lock the process holds on its inode —
> including the locks of an already-open SQLite connection to the same database. A lock-losing close in
> one process lets a sibling's connection take the shared-memory DMS exclusively at its own close,
> checkpoint, and unlink the sidecars while long-lived holders (gateway, desktop `hermes serve`) keep
> using the deleted inodes."*

**注意它用的是 `chmod(2)` 而不是 `os.fchmod(fd)`** —— 因为 `chmod` 路径调用**根本不打开文件**，
所以不会释放锁。而 `open()` + `fchmod()` + `close()` 会。

**这是「安全加固」和「正确性」冲突时的一个真实取舍**：
直觉上 `fchmod` 更安全（不跟随符号链接、没有 TOCTOU），但在这里它会破坏锁。
所以改用 `os.lstat` 检查符号链接 + `os.chmod` 路径调用。

**第 ④ 步的隔离消息**（[`hermes_state.py:777`](../hermes_state.py:777)）也值得看：

```python
msg = (
    f"state.db was empty or damaged ({zsize} bytes) and has been {where}; Hermes started with a "
    "fresh, empty session database. To bring old sessions back, run "
    f"`hermes sessions recover --source {qpath or self.db_path} --inspect-only`, or restore a "
    "snapshot with `/snapshot list` then `/snapshot restore <id>` (terminal `hermes` chat only)."
)
```

**「告诉用户数据在哪、怎么救」** 是错误消息的金标准。不说「出错了」，
而是说「我把坏文件移到了 A，你可以用命令 B 从 A 恢复」。

### 10.3 错误消息的统一文案表

[`hermes_state_user_copy.py:1`](../hermes_state_user_copy.py:1)：

> *"One table keyed by `classify_persistence_error`'s cause bucket feeds every surface (CLI banner,
> gateway home-channel warning, TUI/Desktop RPC errors) so they agree on what happened, what to do,
> and a machine-readable `code` a GUI can attach a 'Run doctor' button to."*

结构是：

```text
classify_persistence_error(exc) → bucket（"corrupt" / "locked" / "readonly" / "unknown" / ...）
                                        ↓
describe_storage_failure(cause) → {gloss, action, code}   ← 一句话解释 + 建议 + 机器码
                                        ↓
CLI banner / gateway 警告 / TUI RPC 错误 —— 三处同一套文案
```

而 [`hermes_state.py:378`](../hermes_state.py:378) 的 `format_session_db_unavailable`
还额外识别**网络驱动器**：

```python
if any(m in cause.lower() for m in _WAL_INCOMPAT_MARKERS):
    if failure.cause == "unknown":
        gloss, action = _NETWORK_DRIVE_GLOSS, _NETWORK_DRIVE_ACTION.replace("{profile_arg}", profile_arg)
```

> *"Network filesystems (NFS/SMB/FUSE/ZFS) cannot host SQLite's write-ahead log: when the raw cause
> carries one of those markers the message names the network-drive suspicion, because
> `hermes doctor --fix` cannot repair a mount — only moving the file can."*

**「doctor 修不了一个挂载点」** —— 这个洞察决定了建议必须是「把文件移到本地盘」，
而不是「跑 doctor」。

### 10.4 live-system guard：测试不能碰生产库

[`hermes_state_guard.py:1`](../hermes_state_guard.py:1)：

> *"Every SessionDB construction resolves its path through `_ensure_test_isolation` so a pytest-context
> process (env OR ancestry) can never open a production state.db; env-based so subprocess children
> are protected too."*

判据是**三条 OR**（[`hermes_state_guard.py:54`](../hermes_state_guard.py:54)）：

```python
def _running_under_pytest() -> bool:
    """True when this process (or a parent test process) is a pytest run."""
    return bool(
        os.environ.get("PYTEST_CURRENT_TEST")
        or os.environ.get("PYTEST_VERSION")
        or os.environ.get(_TEST_ISOLATION_MARKER_ENV)    # HERMES_TEST_ISOLATION，我们自己的
    )
```

**为什么需要自己定义 `HERMES_TEST_ISOLATION`？**（[`hermes_state_guard.py:45`](../hermes_state_guard.py:45)）

> *"Unlike `PYTEST_*` (owned by pytest, and routinely scrubbed by tests that rebuild a child
> environment), this marker is OURS: it declares 'this process tree is running under Hermes test
> isolation', and it inherits into subprocess children by default — so a child that received the
> patched `HERMES_HOME` also received the marker, and a child that resolves a production DB while
> carrying it is, by definition, an isolation escape (#82770)."*

**场景**：某测试用 `subprocess` 启动一个子进程，并**重建了完整环境**（`env={...}`）。
如果它忘了把 `PYTEST_*` 带过去，子进程就"看起来不像测试"了 → 然后它打开了生产库。

**解法**：用一个**我们自己拥有、且默认继承**的标记。
"默认继承" 意味着：即使子进程重建环境，只要它是从测试进程 fork/exec 出来的，
`os.environ` 里就有这个标记（除非显式删除）。

**逃逸舱两个**（[`hermes_state_guard.py:23`](../hermes_state_guard.py:23)）：

```python
_STATE_DB_GUARD_BYPASS_ENV = "HERMES_STATE_DB_GUARD_BYPASS"   # 给必须访问活库的子进程
# 进程内：@pytest.mark.live_system_guard_bypass
```

**警告**（文档里也写了）：一个导出了这个变量的 shell 会把它传给**之后每一次** pytest 运行。

**为什么 guard 放在 `SessionDB.__init__` 最开头**（[`hermes_state.py:582`](../hermes_state.py:582)）：

```python
_ensure_test_isolation(self.db_path)  # before any connection/pragma/mkdir
```

注释说 "before any connection/mkdir/pragma/byte probe" —— 因为**任何一项**都可能造成伤害：

```text
mkdir   → 创建目录
pragma  → 可能改 journal 模式（见 §5.2，热降级会破坏别人）
byte probe → 打开文件（会取消本进程的锁，§5.4）
```

### 10.5 恢复路径速查

| 症状 | 命令 | 内部做什么 |
|---|---|---|
| 打开失败，不知道原因 | `hermes doctor` | `collect_state_db_stats()` + 持有者列举 |
| 库被隔离成 `.corrupt` | `hermes sessions recover --source <path> --inspect-only` | 只读取，判断能救多少 |
| 索引损坏 | `hermes sessions optimize-storage` | 重建 FTS，升 `fts_storage_version` |
| 库太大 | `hermes db optimize` | VACUUM（只在 freelist 比例够时） |
| 会话跑到错的 profile | `hermes sessions repair-profiles` | `hermes_state_profile_repair.py` |
| journal 模式不对 | `hermes sessions journal-mode` | 见 [`hermes_cli/sessions_cmd_journal_mode.py`](../hermes_cli/sessions_cmd_journal_mode.py:1) |

**VACUUM 的阈值**（[`hermes_state_common.py:290`](../hermes_state_common.py:290)）：

```python
# Auto-maintenance only VACUUMs when at least this fraction of the database file is reclaimable
# (`PRAGMA freelist_count / PRAGMA page_count`). Below it a full rewrite costs more I/O than it returns
# — pruning a handful of small sessions on a dense multi-GB state.db should never rewrite the whole file
# to reclaim a few MB (#54189).
AUTO_VACUUM_MIN_FREELIST_RATIO = 0.25
```

**「VACUUM = 重写整个文件」** 是很多人不知道的：删了 100MB 的行，VACUUM 要**重写 5GB**。
所以必须有阈值（25%）。

### 10.6 跨 profile 错位修复

[`hermes_state_profile_repair.py:1`](../hermes_state_profile_repair.py:1)：

> *"Every `state.db` belongs to exactly one profile (`<root>/state.db` → `default`,
> `<root>/profiles/<name>/state.db` → `name`) and every gateway session key encodes the profile that
> owns the conversation (`agent:main:…` for the default, `agent:<name>:…` for a named one).
> The per-profile store model (#88734) is forward-only: it routes NEW writes to the right store but
> never touched rows that had already landed in the wrong one, and the identity fences
> (`_INHERIT_PARENT_META_SQL`, `_recovered_row_allowed_for_active_profile`) only refuse to
> *widen* damage that already exists. This module is the backward-looking half."*

**「forward-only 修复」的诚实命名**：新代码只保证**新的写落到对的地方**，
已经写错的不管。修复模块是**另一个独立的东西**，因为它要动用户数据。

而搬迁的原子性（[`hermes_state_profile_repair.py:17`](../hermes_state_profile_repair.py:17)）：

> *"Moving a session between two stores is two single-store transactions — copy into the target, then
> delete from the source — because a crash between them leaves a *duplicate*, which the next run settles
> idempotently (`import_moved_session` reports `present`; the delete only proceeds when the target holds
> at least as many messages). The reverse order would lose the row."*

**这是分布式事务的经典取舍**：

```text
先删后拷 → 崩在中间 → 数据永久丢失 ❌
先拷后删 → 崩在中间 → 数据重复 → 下次运行可幂等收敛 ✅
```

**「在不可原子化的场景里，选择可收敛的失败模式」** —— 这条原则值得反复引用。

---

## 11. 自检题

1. `get_hermes_home()` 的三层解析顺序是什么？为什么「改 `HOME` 来选 profile」是错的？
2. `DEFAULT_DB_PATH` 为什么要有 `_IMPORT_DEFAULT_DB_PATH` 这个「import 时的快照」？
   `_default_db_path()` 怎么判断该用哪个？
3. `hermes_home_key()` 为什么「不存在的目录不缓存」？
4. `mkdir_under_hermes_home()` 和 `Path.mkdir(parents=True, exist_ok=True)` 的行为差异，
   会导致什么用户可见的 bug？
5. `system_prompts` 表用内容寻址解决了什么问题？`_delete_unreferenced_system_prompts`
   为什么检查两个引用列？
6. `_dedupe_legacy_system_prompts` 在中途撞锁时为什么「return 而不是 raise」？
   如果 raise 会发生什么？
7. `SCHEMA_VERSION` 和 `FTS_STORAGE_VERSION` 为什么要分开？各自什么时候升级？
8. 为什么 `DEFERRED_INDEX_SQL` 不能合并进 `SCHEMA_SQL`？
9. `schema_read_probe_statements()` 为什么必须给列名加表名前缀？不加会发生什么？
10. `_read_ctx` 的三条分岔各是什么？为什么「降级到写连接」比「返回错误」好？
11. `_READ_POOL_MAX`（8）之外为什么还要 `_READ_POOL_PROCESS_MAX`（24）和
    `_FD_HEADROOM_RESERVE`（64）？三者各防的是什么？
12. 路径 C（DELETE 模式）为什么临时把 `busy_timeout` 从 1 秒改成 5 秒，还完再改回？
13. `_execute_write` 的 `BEGIN IMMEDIATE` 为什么要求回调「幂等」？
14. 「库被换掉」的检查为什么必须在 `self._lock` 内做？在锁外做会产生什么 sticky 错误？
15. `disk i/o error` 的重试为什么必须「同一连接」？`close()` + 重开会造成什么？
16. FTS 损坏和结构性损坏的处理为什么不同？各自的后果是什么？
17. 为什么「锁持有者」只写日志不写错误消息？
18. `apply_wal_with_fallback` 在什么情况下会拒绝降级到 DELETE？为什么「热降级」是灾难？
19. WAL-reset bug 影响哪些 SQLite 版本？为什么「bundled 3.50.4 上测出 0/3 损坏」还不够？
20. 为什么 macOS 要额外设 `checkpoint_fullfsync` 和 `synchronous=FULL`？
21. `close()` 为什么用 `PASSIVE` 而不是 `TRUNCATE` checkpoint？
22. `_WRITE_PATIENCE_S` / `_TRANSCRIPT_WRITE_PATIENCE_S` / `_ACTIVITY_WRITE_PATIENCE_S`
    三个值为什么不同？
23. 写重试为什么是「时间预算」而不是「次数预算」？抖动为什么前 2 秒快、之后慢？
24. 进程内 registry 为什么必须存在？「每个调用各自 `SessionDB()`」会造成什么？
25. `_TeardownBarrier` 为什么用计数而不是单个 event？
26. `_claim_lease_row` 里为什么 `INSERT OR IGNORE` 之后还要再 `SELECT` 一次？
    `DELETE` 为什么带 `AND holder = ?`？
27. `_compression_lock_holder_process_is_dead` 为什么「宁可错误地保留租约」？
    PID 复用会带来什么风险？
28. `DurableTurnLease` 为什么「本地权威截止时间必须 ≤ 数据库里的」？
    续租成功后再取时间戳会有什么后果？
29. PID 命名空间戳记解决了什么问题？为什么「异命名空间永不探测 PID」？
30. 五种 `parent_session_id` 关系分别怎么判别？「压缩续篇」的四条例外是什么？
31. `/branch` 为什么需要「标记 + 启发式」两条 OR 判据？
32. `_resume_lineage_ids` 和 `_session_lineage_root_to_tip` 的区别是什么？
    前者为什么不用后者？
33. 为什么 `_CHAIN_CAP` 从 100 改成了 1000？这个数字应该怎么定？
34. `end_session()` 的 `AND ended_at IS NULL` 保护了什么？被覆盖会怎样？
35. `_end_and_bump` 为什么「no-op 不能推进代际」？
36. `_RESET_END_REASONS` / `_BOUNDARY_END_REASONS` / `_RECOVERABLE_END_REASONS`
    三类分别是什么语义？`reopen_if_explicitly_closed` 为什么拒绝处理其中两类？
37. 就地压缩为什么会让同一条消息出现两次？诊断重复写入的正确判据是什么？
38. 「重试成功」为什么不能写进 `content`？通过什么通道告诉模型？
39. 为什么需要 `api_content` 这一列？
40. `trigram` 分词器对 CJK 的缺陷是什么？`cjk_unicode61` 用什么技巧解决？
41. FTS 的 `content=` 为什么指向一个**视图**而不是 `messages` 表？
42. `fts_*_rebuild_high_water` / `_progress` 这对标记是怎么让「重建期间写入」安全的？
43. 为什么「分词器加载失败时要 drop 触发器」而不只是标记陈旧？
44. `_FTS5_SPECIAL_CHARS` 为什么故意**不包含** `%`？
45. `_CONTEXT_WINDOW_SQL` 为什么用 `(timestamp, id)` 元组比较而不是 `timestamp`？
46. 结构损坏闩锁为什么「永不自动清除」？为什么「不写磁盘标记」？
47. `_secure_state_db_files` 为什么用 `os.chmod(path)` 而不是 `fchmod(fd)`？
48. live-system guard 为什么需要自有的 `HERMES_TEST_ISOLATION` 标记，而不只靠 `PYTEST_*`？
49. 迁移两条库之间的会话时，为什么「先拷后删」而不是「先删后拷」？
50. `AUTO_VACUUM_MIN_FREELIST_RATIO = 0.25` 这个阈值在防什么？

---

## 12. 小结与下一步

**六条最重要的结论**：

1. **`state.db` 是唯一的对话真相**，内存里的 `messages` 只是工作副本。
   `/undo` 要先校验「内存和磁盘一致」，就是因为磁盘才是权威。
2. **路径必须走 `get_hermes_home()`，且必须在调用时解析**（不是 import 时）。
   `HOME` 不是选 profile 的方式；子进程必须显式传 `HERMES_HOME`。
3. **一个库只有一个写者**。所有并发代码都在这个前提下做排队、抖动退避、降级
   （读降级到写连接而不是报错）。**永远不要用 `close()` + 重开来"修复"临时错误**。
4. **`parent_session_id` 有五种语义**，靠 `model_config` 里的三个标记 + 父行
   `end_reason` 区分。只有「父 ended with compression 且子不是 branch/reset/delegate/tool」
   才是真正的压缩续篇。
5. **派生数据（FTS）坏了可以丢，主表坏了才要闩锁**。这个优先级贯穿整个模块：
   丢索引 → 搜索退化；丢主表 → 对话消失。
6. **错误消息要给出「数据在哪 + 怎么救」**，而不是「出错了」。
   而机器可读的分类输入必须只含系统生成的内容（不能把用户的工作区名字混进去）。

**下一篇** → [`08-memory-context-compression.md`](08-memory-context-compression.md)：
记忆 provider、上下文引擎、以及**压缩** —— 也就是本章反复提到的那个
「唯一合法的历史改写操作」到底怎么做的。
