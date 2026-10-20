# 12 · Cron 定时任务与 Kanban 多 Agent 队列

> **读法**：这一篇讲两套「自己会跑起来」的系统。它们都不是「用户打字 → 模型回复」的模式，
> 而是**后台进程持续工作**。也正因为如此，它们是整个代码库里**并发与作用域 bug 最密集**的地方。
>
> 本篇的核心不是 API 清单，而是一个反复出现的结论：
>
> **「一个进程服务多个 profile」这条假设被打破时，所有以「本进程的 profile」为 key 的状态都是错的。**
>
> 读完你应该能：
> 1. 说清 cron 的一次 fire 在崩溃前后发生了什么（为什么不会漏、不会重）；
> 2. 解释为什么「不活动超时」比「墙钟超时」更适合 agent 任务；
> 3. 指出 `_inflight_key` 为什么必须带 home，以及不带会发生什么；
> 4. 解释 Kanban 的 board 硬边界与 tenant 软命名空间的区别；
> 5. 说清「工具访问权不是所有权」这句在防什么。

---

## 本篇相对旧版新增

| 旧版（304 行） | 新版 |
|---|---|
| 代码形状 4 行表格 | 补齐 `cron/` 全部 25+ 文件的职责，标出行数 |
| schedule 4 行表格 | 补 `parse_schedule` 的完整判定顺序、时区陷阱（#51021）、`in 30m` 与 `30m` 的语义差异 |
| 每任务字段 5 行 | 补 `_PAYLOAD_FIELDS`、`no_agent` 的校验、「至少一个 payload 字段」规则 |
| 12 条不变量列点 | 每条不变量扩成「现象 → 根因 → 事故号」三段，补 `_inflight_key` 源码、`release_running_job` 的 ContextVar 陷阱、`_MAX_ABANDONED_LOADERS` 之外的 worker bootstrap 细节 |
| 无 | **§4 一次 fire 的完整时间线**（把 12 条不变量串成一条可读的流程） |
| 无 | 投递队列（`delivery_queue.py`）的「宁可丢也不重」原则 |
| 无 | 配额停车（`quota_hold.py`）、不可达重试、事故分组（`incidents.py`）、降级状态（`store_health.py`）、生命周期守卫（`lifecycle_guard.py`） |
| 无 | blueprints（自动化目录）与非 cron 的 `on_jobs_changed` 钩子 |
| Kanban 6 节 | 补 `DEFAULT_WORKFLOW` 八列全表 + 人工移动矩阵 + 「review→todo 落到 ready」的已知怪癖、`KANBAN_TERMINAL_PROVIDER_EXIT_CODE=78` 的粘性语义、CAS claim 的 SQL 形状 |
| 隔离模型 2 段 | 补 `explicit_board_intent_is_pinned()`、`scrub_kanban_env()`、marker 从 flag 变路径的原因（scratch HERMES_HOME 事故） |
| 无 | §9 Kanban 的一次任务生命周期（create → dispatch → claim → run → review → done） |
| 测试 4 行 | 补「为什么 schedule 解析要当纯函数测」 |
| 无 | §11 自检题 52 道 |

---

## 0. 前置概念

### 0.1 什么是 cron

`cron` 是 Unix 的传统定时任务系统：你写一行 `0 9 * * *`，系统每天早上 9 点跑那个命令。
Hermes 借用了这个名字，但**语义变了**：

| | 传统 cron | Hermes cron |
|---|---|---|
| 跑什么 | 一条 shell 命令 | **一次完整的 agent turn**（有工具、有记忆、有会话） |
| 输出去哪 | 邮件 / 日志文件 | **任意平台**（Telegram、Discord、Slack……） |
| 失败怎么办 | 无感知 | 事故分组 + 告警去重 |
| 状态在哪 | 系统 crontab | **每个 profile 自己的 `jobs.json`** |

这个差异决定了后面所有复杂度：一个「跑 5 秒的 shell 命令」和一个「跑 5 分钟的 LLM 会话」
在可靠性上的要求完全不同。

### 0.2 为什么 cron 需要「多 profile」

Hermes 的 profile 是**完全隔离的租户**（见 [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)）：
每个 profile 有自己的 `HERMES_HOME`、自己的 `.env`、自己的 `config.yaml`、自己的技能。

用户可能有：
- `default`（个人）
- `coder`（工作）
- `client-a`（客户 A 的机器人）

每个 profile 都可能配了 `daily-brief` 这个 job。
**同一个名字，三个不同的 job。**

而为了省资源，一个 gateway 进程**服务所有 profile**（multiplex）。
于是：**一个进程里有三个 `daily-brief` 同时在跑。**

这就是本篇反复出现的那句话的来源。

### 0.3 什么是「至少一次」与「至多一次」

分布式系统定式：

- **at-most-once（至多一次）**：宁可漏，不可重。适用于「发消息」「扣款」。
- **at-least-once（至少一次）**：宁可重，不可漏。适用于「备份」「通知」。

cron 的两难：

- 如果先跑后记账 → 跑完崩溃 → 重启后**不知道跑过没有** → 只能再跑（可能会重复投递）；
- 如果先记账后跑 → 记账完崩溃 → **永远不跑**（漏了一个 slot）。

Hermes 的选择是**先推进 `next_run_at` 再派发**（at-most-once 优先），
然后用 `pending_slot` 标记 + 扫描恢复来**补偿**「记账了但没跑」的情况。
见 §4。

### 0.4 什么是 CAS（compare-and-swap）

Kanban 的 claim 用 SQLite 实现：

```sql
UPDATE tasks SET status='running', claim_lock=?, claim_expires=?
WHERE id=? AND status='ready' AND claim_lock IS NULL
```

如果两个 dispatcher 同时执行这条语句：
- 第一个改成功，`changes() = 1`；
- 第二个的 `WHERE` 不匹配（因为 `claim_lock` 已经有值了），`changes() = 0`。

**零行的那个就知道自己输了，直接放弃，不重试。**

这是「无分布式锁的互斥」：不需要 Redis、不需要协调者，
因为 SQLite 本身就是串行化写者。

---

# 第一部分：Cron

## 1. 代码形状

### 1.1 文件地图

`cron/` 目录有 **38 个 `.py`**，合计 **18,532 行**。按职责分组：

**核心**

| 文件 | 行数 | 职责 |
|---|---|---|
| [`cron/scheduler.py`](../cron/scheduler.py:1) | 4437 | tick 循环、job 执行、in-flight 状态、并行池 |
| [`cron/jobs.py`](../cron/jobs.py:1) | 3503 | job 存储（`jobs.json`）、schedule 解析、到期判定 |
| [`cron/scheduler_delivery.py`](../cron/scheduler_delivery.py:1) | 2131 | 投递到各平台、镜像到会话 |

**tick 的拆分**

| 文件 | 行数 | 职责 |
|---|---|---|
| [`cron/scheduler_tick.py`](../cron/scheduler_tick.py:1) | 184 | 单次 tick 的准入与派发（job 执行留在 `scheduler.py`） |
| [`cron/scheduler_provider.py`](../cron/scheduler_provider.py:1) | 674 | 调度器 provider 抽象 + `_start_multiplex`（多 profile 循环） |
| [`cron/scheduler_preflight.py`](../cron/scheduler_preflight.py:1) | 412 | 前置检查、`SharedRouteAdapters` |
| [`cron/scheduler_prompt.py`](../cron/scheduler_prompt.py:1) | 450 | prompt 组装（`context_from`、技能加载） |
| [`cron/scheduler_script.py`](../cron/scheduler_script.py:1) | 599 | 附加脚本执行与超时 |
| [`cron/scheduler_ownership.py`](../cron/scheduler_ownership.py:1) | 165 | 「本进程是否 tick 这个 home」 |
| [`cron/scheduler_failure_copy.py`](../cron/scheduler_failure_copy.py:1) | 148 | 失败文案 |

**可靠性**

| 文件 | 行数 | 职责 |
|---|---|---|
| [`cron/executions.py`](../cron/executions.py:1) | 562 | 每次尝试的持久审计账本（SQLite） |
| [`cron/occurrences.py`](../cron/occurrences.py:1) | — | 精确的调度身份（不依赖可变的 `jobs.json` stamp） |
| [`cron/incidents.py`](../cron/incidents.py:1) | 293 | 失败事故按签名去重 + ack |
| [`cron/delivery_queue.py`](../cron/delivery_queue.py:1) | 415 | 投递的持久交接（跨重启安全） |
| [`cron/quota_hold.py`](../cron/quota_hold.py:1) | 163 | provider 配额窗口关闭时停车 |
| [`cron/unreachable_retry.py`](../cron/unreachable_retry.py:1) | 166 | 不可达重试 |
| [`cron/store_health.py`](../cron/store_health.py:1) | 301 | 不可写 store 的降级状态 |
| [`cron/lifecycle_guard.py`](../cron/lifecycle_guard.py:1) | 1293 | 拒绝「在 gateway 内重启 gateway」的 job |
| [`cron/monitor.py`](../cron/monitor.py:1) | 186 | 监控 |

**产品层**

| 文件 | 行数 | 职责 |
|---|---|---|
| [`cron/blueprint_catalog.py`](../cron/blueprint_catalog.py:1) | 791 | 自动化模板目录（用户从不写裸 cron） |
| [`cron/suggestions.py`](../cron/suggestions.py:1) | 202 | 建议引擎 |
| [`cron/notepad.py`](../cron/notepad.py:1) | 166 | 记事本 |
| [`cron/bot_chat_delivery.py`](../cron/bot_chat_delivery.py:1) | 176 | Bot Mode 投递 |

工具与 CLI：

- [`tools/cronjob_tools.py`](../tools/cronjob_tools.py:1) —— agent 用的 `cronjob` 工具
- [`hermes_cli/cron.py`](../hermes_cli/cron.py:1) —— `hermes cron` 子命令

### 1.2 存储布局

[`cron/jobs.py:1`](../cron/jobs.py:1)：

> Cron job 存储：`~/.hermes/cron/jobs.json`；输出在 `~/.hermes/cron/output/{job_id}/{timestamp}.md`

关键常量（[`:89`](../cron/jobs.py:89)）：

```python
JOBS_FILE = CRON_DIR / "jobs.json"
OUTPUT_DIR = CRON_DIR / "output"
ONESHOT_GRACE_SECONDS = 120
TICKER_INTERVAL_SECONDS = 60
```

以及两个心跳文件（[`:97`](../cron/jobs.py:97)）：

```python
TICKER_HEARTBEAT_FILE = CRON_DIR / "ticker_heartbeat"
TICKER_SUCCESS_FILE = CRON_DIR / "ticker_last_success"
```

注释解释了为什么要两个：

> 每次 ticker 循环都 touch，这样 `hermes cron status` 能判断 ticker **线程**是活的，
> 而不只是 gateway **进程**存在。
> gateway 进程和（独立的）`hermes cron status` 进程共享它，
> 所以 status 能分辨 ticker 线程是否活着；
> 否则一个在活着的 gateway 里静默死掉的 ticker 会报告健康（#32612、#32895）。

`TICKER_INTERVAL_SECONDS = 60` 的注释说它是**单一事实来源**（[`:104`](../cron/jobs.py:104)）：

> ticker 间隔（`scheduler_provider.py`）和 `hermes cron status` 的陈旧阈值
> （`hermes_cli/cron.py`）的单一事实来源，这样它们永不漂移。

### 1.3 每个 profile 自己的 store

这是全篇第一个关键设计，[`cron/jobs.py:76`](../cron/jobs.py:76) 的注释：

> Cron 按设计是**每 profile** 的：锚在 `get_hermes_home()`（活跃 profile home），
> **不是** `get_default_hermes_root()` —— 共享根会把每个 profile 的 job 灌进一个 `jobs.json`，
> 并在 ticker 的 `HERMES_HOME` 下运行它们，**跨 profile 泄漏配置/凭证/技能**。
> 每个 profile 在自己的 `HERMES_HOME` 下拥有自己的 cron store，
> 一个 profile 作用域的 gateway 用**同一个** `HERMES_HOME` 运行该 profile 的 job ——
> 所以一个在 profile `coder` 里编写的 job 住在 `~/.hermes/profiles/coder/cron/jobs.json`，
> 并用 `coder` 的 `.env`、`config.yaml` 和技能执行。
> **不要**把它改成默认根：那会重新破坏 per-profile 隔离。见 #4707。

最后一句是一个**回归警告**。「看起来更合理」的写法（用共享根，省事）会静默破坏隔离。

### 1.4 作用域的注入方式：ContextVar 而非全局

既然每个 profile 有自己的 store，而一个进程要 tick 所有 profile，那「当前是哪个 store」必须是**动态的**。

[`cron/jobs.py:186`](../cron/jobs.py:186)：

```python
@contextlib.contextmanager
def use_cron_store(home: str | Path):
    """Route cron storage to ``home`` without mutating process globals."""
    token = _cron_store_override.set(
        _CronStorePaths.for_dir(Path(home).expanduser().resolve() / "cron"))
    try:
        yield
    finally:
        _cron_store_override.reset(token)
```

`_cron_store_override` 是 `ContextVar`（[`:126`](../cron/jobs.py:126)）。

**为什么不用全局变量？** 因为 ticker 是一个线程顺序遍历 N 个 profile，
但如果它改成线程池（或某个 job 内部起线程），全局变量会被并发改写。
ContextVar 的语义是「当前执行上下文的」，`copy_context()` 能带着走，互不干扰。

同样的理由适用于 `_profile_cron_scope`（[`scheduler_provider.py:119`](../cron/scheduler_provider.py:119)）：

```python
@contextlib.contextmanager
def _profile_cron_scope(home):
    """Scope the calling thread to one profile's home + cron store for the block."""
    from cron.jobs import use_cron_store
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override

    home_token = set_hermes_home_override(str(home))
    try:
        with use_cron_store(home):
            yield
    finally:
        reset_hermes_home_override(home_token)
```

它做**两件事**：
1. `set_hermes_home_override(home)` —— 让 `get_hermes_home()` 返回这个 profile；
2. `use_cron_store(home)` —— 让 cron 存储指向这个 profile 的 `cron/`。

为什么两件都要？因为 job 执行时会读 `config.yaml`、`.env`、技能目录——
这些都通过 `get_hermes_home()` 解析。只切 store 不切 home，
job 会用**错误的凭证**跑（读到启动 profile 的 key）。

---

## 2. Schedule 格式与解析

### 2.1 支持的五种形态

[`cron/jobs.py:787`](../cron/jobs.py:787) `parse_schedule` 的 docstring：

> 把 schedule 字符串解析成 `{"kind": "once"|"interval"|"cron", ...}`，
> 带 `run_at` / `minutes` / `expr`。
> `"30m"` 和 `"every 30m"` 是**循环间隔**；`"every monday 9am"` 和 `"0 9 * * *"` 是 cron；
> 一个 ISO 时间戳是**一次性**。

| 形态 | 例子 | 解析结果 |
|---|---|---|
| 裸时长 | `"30m"`、`"2h"`、`"1d"` | `interval`（**循环**） |
| `every` + 时长 | `"every 2h"` | `interval` |
| `every` + 自然语言 | `"every monday 9am"` | `cron`（转成表达式） |
| 无 `every` 的自然语言 | `"weekdays at 9am"` | `cron` |
| 5–6 字段 cron | `"0 9 * * *"` | `cron` |
| ISO 时间戳 | `"2026-02-03T14:00:00"` | `once` |
| `in` + 时长 | `"in 30m"` | `once`（**一次性**） |

### 2.2 判定顺序（有讲究）

源码的顺序不是随便排的：

```python
is_every = schedule_lower.startswith("every ")
rest = schedule[6:].strip() if is_every else schedule_lower
cron_expr = _natural_every_to_cron(rest)      # ① 自然语言 → cron
if cron_expr is not None: ...
if is_every:                                   # ② every + 时长
    return _interval_schedule(parse_duration(rest))

parts = schedule.split()                       # ③ 5+ 字段 cron 表达式
if len(parts) >= 5 and all(re.match(r'^[A-Za-z\d\*\-,/]+$', p) for p in parts[:5]):
    return _cron_schedule(...)

if 'T' in schedule or re.match(r'^\d{4}-\d{2}-\d{2}', schedule):   # ④ ISO
    ...

if schedule_lower.startswith("in "):           # ⑤ "in 30m" 一次性
    ...

with contextlib.suppress(ValueError):          # ⑥ 裸时长
    return _interval_schedule(parse_duration(schedule))
```

为什么 ① 在 ② 前面？因为 `every monday 9am` 也以 `every ` 开头，
但它不是时长。先试自然语言，失败才当时长。

为什么 ④ 在 ⑥ 前面？因为 `2026-02-03T14:00:00` 不可能是时长，
但 `parse_duration` 可能在奇怪的输入上抛错。顺序保证明确。

为什么 ⑤ 在 ⑥ 前面？因为 `in 30m` 如果先进 ⑥，`parse_duration("in 30m")` 会失败——
但其实这是「想要一次性」的显式写法。

**`"30m"` 与 `"in 30m"` 的语义差异**是文档化的（[`jobs.py:855`](../cron/jobs.py:855) 的注释）：

```python
# "in 30m"/"in 2h" 是显式的一次性按时长形式；裸时长（"30m"）按文档化的
# 工具契约是**循环**间隔。
```

这个设计有点反直觉，但它救了很多用户：用户说「30 分钟后提醒我」时打 `30m`，
如果它是 loop，就会每 30 分钟响一次。加了 `in ` 前缀就是明确的「只一次」。

### 2.3 时区陷阱（#51021）

ISO 时间戳解析的代码里有一段长注释（[`jobs.py:824`](../cron/jobs.py:824)）：

```python
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=_hermes_now().tzinfo)
```

注释解释：

> 朴素时间戳在**配置的 Hermes 时区**（不是服务器本地时区）里变成 aware：
> due-check 与 `hermes_time.now()` 比较。
> 在解析时就变成 aware，这样存储的值不依赖「检查时的系统时区是否匹配」。
> 如果服务器是 UTC 而 `now()` 在 Asia/Kolkata，存储的时刻会与用户墙钟意图差几个小时——
> 远到一次性 job 永远不会到期、循环 job 在错误时间触发。
> 用配置时区让「20:07」意味着**同一个时钟上的 20:07**，也就是调度器检查用的那个钟。

这是一个典型的「在边界上规范化」原则：**存的是绝对时刻，不是本地表示**。
一旦存了 `2026-02-03T14:00:00`（无时区），它到底是什么时刻就取决于谁去读它。

### 2.4 `"in 30m"` 的 DST 处理

```python
now = _hermes_now()
run_at = (now.astimezone(UTC) + timedelta(minutes=minutes)).astimezone(now.tzinfo)
```

注释：

> 时长测量的是**流逝时间**，不是跨 DST 转换的墙钟小时。

具体例子：现在是 01:30（DST 结束前的最后一小时），你要 `in 60m`。
如果按墙钟算，01:30 + 1 小时 = 02:30；但实际 DST 回退会让 02:30 在 2 小时后才到。
按 UTC 加 60 分钟再转回本地，得到的是真正 60 分钟后的墙钟时间（01:30 或 02:30，取决于方向）。

「提醒我 1 小时后」是人的意图，是**流逝时间**。

---

## 3. 每个 job 的字段

### 3.1 Payload 字段

[`cron/jobs.py:469`](../cron/jobs.py:469)：

```python
_PAYLOAD_FIELDS = frozenset({"prompt", "script", "skill", "skills", "no_agent"})
```

校验规则（[`:484`](../cron/jobs.py:484)）：

> 至少一个 payload 字段必须显式存在。`no_agent` 已经要求有 `script`。

以及（[`:477`](../cron/jobs.py:477)）：

```
"no_agent=True requires a script — with no agent and no script ..."
```

即：`no_agent=True` 但没有 `script` 是**无意义的空 job**（既不跑 agent 也不跑脚本）。
在创建时就拒绝，而不是等 tick 时报错。

### 3.2 全字段表

| 字段 | 说明 |
|---|---|
| `prompt` | 交给 agent 的提示 |
| `script` | 预运行数据收集脚本，**其 stdout 注入 prompt** |
| `no_agent` | `True` 时脚本**就是整个 job**（不调模型） |
| `skills` | 附加技能（加载进 prompt） |
| `skill` | 单个技能（同上，单数形式） |
| `model` / `provider` | 覆盖本次运行的模型路由 |
| `context_from` | 把 job A 的**最后输出**链进 job B 的 prompt |
| `workdir` | 用该目录的 `AGENTS.md`/`CLAUDE.md` 运行 |
| `deliver` | 投递目标（平台/会话） |
| `schedule` | 见 §2 |
| `repeat` | 重复次数限制 |
| `monitor_script` / `monitor_url` | 监控模式（与 `no_agent` 互斥，[`:1783`](../cron/jobs.py:1783)） |

### 3.3 `context_from` 的实现

[`cron/scheduler_prompt.py:129`](../cron/scheduler_prompt.py:129)：

```python
def _inject_context_from(job: dict, prompt: str) -> tuple[str, bool]:
    """Prepend the latest output of each ``context_from`` job; returns ``(prompt, injected)``."""
```

注意是 **prepend**，不是 append，也不是替换。

为什么？因为下游 job 的 prompt 通常是「基于上下文做判断」：

```yaml
job: summarize-then-alert
context_from: [fetch-metrics]
prompt: "如果上面的指标里有异常，发一条告警。"
```

如果 append，模型的指令在数据前面，容易「读着读着忘了要干什么」。

### 3.4 `no_agent` 的意义

一个 `no_agent=True` 的 job 完全绕过模型：

```
tick → 跑脚本 → 把 stdout 当结果 → 投递
```

这适用于纯确定性的任务：拉一个 API 检查磁盘、把某个文件同步到别处。
它**不花钱、不慢、不会幻觉**。

而且它是 Footprint Ladder 的实践：如果一件事不需要模型，
就不该让它经过 agent（见 [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) §2）。

### 3.5 生命周期守卫：拒绝「在 gateway 里重启 gateway」

[`cron/lifecycle_guard.py:1`](../cron/lifecycle_guard.py:1)：

> **gateway 生命周期守卫，用于 cron job 创建。**
>
> 一个从 gateway 内部重启/停止 gateway 的 cron job
> （`hermes gateway restart`、`launchctl kickstart ai.hermes.gateway`、
> `systemctl restart hermes-gateway`）会杀掉进程，supervisor 复活它，
> auto-resume 重跑那一轮：**SIGTERM-respawn 死循环**。
> `cron.jobs.create_job` 在**每条创建路径**上拒绝这种 spec。
> 模式是**命令形状的**——锚定在具体命令标识符上——所以它们不会在散文上误触发。**纵深防御层。**

这段值得逐句读：

1. **失败模式**：不是「job 失败一次」，而是**无限循环**——
   job 重启 gateway → gateway 重启后接着跑那个 job → 又重启……
2. **每条创建路径**：CLI、agent 工具、blueprint、导入——一处漏就有一条攻击面。
3. **命令形状**：不能只匹配字符串 `"restart"`，因为 prompt 里可能写「重启一下服务」这种散文。
   必须锚定 `hermes gateway restart` 这样的完整命令形状。
4. **纵深防御**：这不是唯一防线（还有审批门、权限），但这层很便宜。

`GatewayLifecycleBlocked(ValueError)` 是拒绝时抛的异常。

---

## 4. 一次 fire 的完整时间线

这一节把 §5 的 12 条不变量串成一条可读流程。**先读这一节，再去读不变量表。**

### 4.1 正常路径

```
[1] ticker 醒来（每 60s 或 profile 自定义）
      └─ _acquisition：拿 tick 锁 <home>/cron/.tick.lock
                        （同 profile 跨进程去重）
      └─ retirement.work() 准入：本进程是否在被退休？（滚动升级）

[2] 对每个需要服务的 profile（顺序，不并发）：
      with _profile_cron_scope(home):        # 绑 home + secret + terminal
        with use_cron_store(home):            # 切 cron store
          ── 前面这些**全部在守卫内**（§5.5）

[3] 扫描到期 job
      ├─ next_run_at <= now + skew？
      ├─ 宽限/追赶判定（§4.2）
      └─ is_job_runnable？

[4] 先推进后派发（at-most-once）
      save(job.next_run_at = 下一个时刻, pending_slot = <本次的绝对时刻>)
      ← 这一步和下面的 ticket 在**同一次 save**（§5.3）

[5] 去重登记
      try_register_running_job(job_id, owner=..., future=...)
      key = (home_key, job_id)                # ← 关键（§5.7）
      已在跑 → 跳过

[6] 提交到并行池
      _get_parallel_pool(max_workers)          # 池按 home keyed
      pool.submit(run_job, ...)

[7] job 执行（在池 worker 线程里）
      ├─ 构建 job env（在这个 profile 的 secret scope 下）
      ├─ 跑 script（若有）→ stdout 注入 prompt
      ├─ 加载 skills
      ├─ 注入 context_from
      ├─ 跑 agent turn（skip_memory=True）
      ├─ 不活动看门狗监控
      └─ 产出结果

[8] 投递
      ├─ 直接投递（存活的 adapter）
      └─ 或入 delivery_queue（跨重启安全 worker，§7）

[9] 记账
      executions ledger: status=completed, scheduled_instant=<绝对时刻>
      mark_job_run()
      on_session_end 刷新（在这个 profile 的作用域下！）

[10] 释放
      release_running_job(job_id, home=home)   # ← 必须带 home（§5.8）
      finally 保证
```

### 4.2 宽限与追赶

[`cron/jobs.py:942`](../cron/jobs.py:942)：

```python
_MIN_GRACE_SECONDS = 120
_MAX_GRACE_SECONDS = 7200

def _compute_grace_seconds(schedule: dict) -> int:
    """How late a job can be and still catch up rather than fast-forward: half the period, clamped
    to [120s, 2h], so daily jobs catch up but frequent jobs fast-forward quickly."""
    period_seconds = _schedule_cadence_seconds(schedule)
    if not period_seconds:
        return _MIN_GRACE_SECONDS
    return max(_MIN_GRACE_SECONDS, min(int(period_seconds) // 2, _MAX_GRACE_SECONDS))
```

这个公式很好，值得理解它为什么长这样：

| job 周期 | 一半 | 钳制后宽限 | 效果 |
|---|---|---|---|
| 每分钟 | 30s | 120s | 晚 2 分钟内仍补跑 |
| 每 10 分钟 | 5min | 5min | 晚 5 分钟内补跑 |
| 每小时 | 30min | 30min | 晚半小时内补跑 |
| 每天 | 12h | 2h（上限） | 晚 2 小时内补跑 |
| 每周 | 3.5d | 2h（上限） | 晚 2 小时内补跑 |

**为什么是「一半」？** 因为如果宽限超过周期，就可能出现「补跑上一次」和「该跑这一次」重叠，
两个 slot 同时到期。一半保证最多只会积压一个。

**为什么有 2h 上限？** 因为一个每天的任务如果晚了 12 小时才补跑，
用户看到的是「昨天的日报今天下午才来」——比不补更困惑。

**为什么有 120s 下限？** 因为 agent 任务本身可能有几秒的执行波动，
加上 ticker 是 60s 一拍；60s 的宽限会让「每 2 分钟」的任务经常被判定为过期。

### 4.3 lateness 三分类

[`cron/jobs.py:963`](../cron/jobs.py:963)：

```python
_LATE_DISPATCH_TOLERANCE_SECONDS = 300

def _classify_dispatch_lateness(lateness_seconds: float, grace_seconds: int) -> str:
    """``on_time`` (within ticker slack), ``late`` (within the catch-up grace window), or
    ``catch_up`` (beyond grace; accumulated misses skipped, executed once now)."""
    if lateness_seconds > grace_seconds:
        return "catch_up"
    if lateness_seconds > _LATE_DISPATCH_TOLERANCE_SECONDS:
        return "late"
    return "on_time"
```

三个状态的行为完全不同：

| 状态 | 条件 | 行为 |
|---|---|---|
| `on_time` | 晚 ≤ 300s | 正常跑（这只是 ticker 的正常抖动） |
| `late` | 300s < 晚 ≤ grace | 正常跑，但**标记为晚**（可在 UI 显示） |
| `catch_up` | 晚 > grace | **跳过积累的错过，现在只跑一次** |

注释里那句「accumulated misses skipped, executed once now」是关键：
如果机器关机了 3 天，一个日任务会错过 3 次。
补跑 3 次是灾难（3 份日报 + 3 条告警）。**只跑一次**才是用户想要的。

300s 的来源（[`:958`](../cron/jobs.py:958) 注释）：

> 一次循环派发在调度时刻这么多秒内渲染成「准时」：
> 一个忙碌的每分钟 ticker 可能滑几分钟——正常节奏，不是 gateway 停机。见 #99879。

### 4.4 崩溃恢复：`pending_slot` 与 occurrences

这是 at-most-once + 补偿的核心。

**`tick()` 在派发之前推进 `next_run_at`**（[`cron/AGENTS.md:24`](../cron/AGENTS.md:24)）：

> `tick()` 在派发**之前**推进 `next_run_at`（跨 mid-run 崩溃至多一次）
> 并在**同一次 save** 中打 `pending_slot`；
> 扫描发现 stamp 而 owner 已死 → **只恢复一次**该时刻（`cron/occurrences.py`）；
> executions ledger 的 `scheduled_instant` 阻止第二次触发；
> `cron.catch_up_missed: false` 跳过已过宽限的错过，附带记录的原因。
> **绝不静默丢弃一个 slot**（#107485）。

拆开看：

**(1) 为什么先推进？** 如果先跑后推进，跑到一半崩溃 → `next_run_at` 还是过去 → 重启后重跑。
先推进的话，崩溃后 `next_run_at` 已经是未来，**不会重跑**（at-most-once）。

**(2) 那漏了怎么办？** 这就是 `pending_slot`：
它在**同一次 save** 里被写上（所以「推进了但没标记」和「标记了但没推进」这两种中间态不存在）。
扫描时看到 `pending_slot` 指向的时刻，检查 owner 是否活着：
- 活着 → 在跑，跳过；
- 死了 → **恢复一次**那个时刻（不是无限重试）。

**(3) 为什么需要 `occurrences.py`？**

`cron/occurrences.py:1`：

> 精确的调度身份，**独立于可变的 `jobs.json` 派发 stamp**，加上 profile 本地的
> 陈旧调度追赶计数器标记。

`jobs.json` 里的字段是**可变的**：用户可能编辑 job、改 schedule、手动 `run`。
如果「这个 slot 跑过没有」依赖 `jobs.json` 的某个字段，那改动它就会让记账失真。

所以真正的记账在 **executions ledger**（SQLite）里，keyed by `(job_id, scheduled_instant)`：

```python
# cron/occurrences.py:23
def completed_occurrence(job, instant):
    """Unknown/failed/pruned attempts cannot prove completion: keep them eligible."""
```

注意这句 docstring：「未知/失败/被清理的尝试**不能证明完成**：保持它们可重试」。
即：只有 `status='completed'` 才算数。一个 `unknown` 的尝试意味着「可能跑了也可能没跑」——
系统选择让它**可重试**（倾向 at-least-once），而不是当成已完成。

还有一个时区抖动的细节（[`:30`](../cron/occurrences.py:30)）：

```python
# 一次偏移的提前 fire（见 claim_job_for_fire）合法地在其 slot 之前完成。
earliest_real = datetime.fromisoformat(instant) - timedelta(seconds=FIRE_CLAIM_SKEW_SECONDS)
```

即：允许「比计划早一点点完成」，因为 ticker 有 skew 容差。

---

## 5. 加固不变量：每条守着一个真实失败

来自 [`cron/AGENTS.md:17`](../cron/AGENTS.md:17)：
「每条守着一个真实失败；不解释清楚就不要弱化它」。

### 5.1 不活动看门狗（不是墙钟）

```python
# cron/scheduler.py:1196
def _cron_inactivity_seconds() -> float:
    """Parse HERMES_CRON_TIMEOUT (seconds). 0 = unlimited; bad input = 600. Shared by the
    inactivity monitor and the cwd-lock bound so they can't drift: the lock bound must stay >= the
    inactivity limit or waiters fail while a healthy holder runs."""
```

| 情况 | 值 |
|---|---|
| 未设置 | 600s |
| `HERMES_CRON_TIMEOUT=0` | 无限 |
| `HERMES_CRON_TIMEOUT=abc` | 600s（带 warning） |
| `HERMES_CRON_TIMEOUT=1800` | 1800s |

**为什么是「不活动」而不是「总时长」？**

[`cron/AGENTS.md:19`](../cron/AGENTS.md:19)：

> 它是**空闲时间**，不是墙钟时间——一个卡住的会话被硬中断以免独占调度器，
> 而一个长但**有活动**的 job 永不被切断。

具体场景：
- job A：跑了 4 小时，但每 30 秒都有工具调用 → **不该被杀**（它在正常工作）；
- job B：启动后卡在一个死锁的 HTTP 请求上，20 分钟没有任何输出 → **该被杀**。

墙钟超时无法区分这两种。而 agent 任务的时长差异巨大（一句话答完 vs 重构一个模块），
固定墙钟上限要么太短（误杀）要么太长（卡住的 job 占用并行槽 30 分钟）。

**脚本另有超时**（[`AGENTS.md:21`](../cron/AGENTS.md:21)）：

> 附加脚本（pre-run 或 `no_agent`）由脚本超时单独限制
> （`_DEFAULT_SCRIPT_TIMEOUT`，3600s）。

为什么脚本要单独限制？因为脚本不是 agent，没有「活动」可监控——
它要么退出要么不退出。所以用墙钟（1 小时）是合适的。

**docstring 里还有个更深的点**：

> 由不活动监控**和 cwd 锁上限**共享，这样它们不会漂移：
> 锁上限必须 ≥ 不活动限制，否则健康的持有者还在跑时，等待者就失败了。

即：两处都用了这个值，但一个是「杀」，一个是「等」。
如果各自算各自的值，改一处忘另一处 → 「job 明明还活着，锁却说超时了」。

### 5.2 追赶窗口

已在 §4.2 讲过。补一条：

`cron.catch_up_missed: false` 时的行为（[`AGENTS.md:27`](../cron/AGENTS.md:27)）：

> 跳过已过宽限的错过，**附带记录的原因**。

「附带记录的原因」很重要：如果静默跳过，用户会以为「没到点」。
记录原因后，`hermes cron list` / dashboard 能显示「这个 slot 因为超过宽限被跳过」。

### 5.3 每个循环出现都要被记账

见 §4.4。补充 #107485 的教训（[`AGENTS.md:28`](../cron/AGENTS.md:28)）：

> **绝不静默丢弃一个 slot**（#107485）。

这是「用户信任」问题：如果一个 job 该跑没跑、且没有任何记录，
用户永远不知道发生了什么，只能怀疑「cron 坏了」。

### 5.4 每 home 的 tick 锁

[`cron/AGENTS.md:29`](../cron/AGENTS.md:29)：

> `<home>/cron/.tick.lock` 防止跨进程对**该 profile 存储**的重复 tick；
> **绝不**用 `~/.hermes/...` 字面量。

两件事：
1. **锁按 home**，不是按进程/全局。因为两个不同的 gateway 可能同时服务不同的 profile。
2. **路径必须由 `get_hermes_home()` 推导**（HX001）。硬编码 `~/.hermes` 在多 profile 下直接错。

`_acquire_tick_lock_or_degrade`（[`scheduler_tick.py:44`](../cron/scheduler_tick.py:44)）：

```python
def _acquire_tick_lock_or_degrade(_sched):
    """The tick lock fd, or None when this tick must not run: another ticker holds the lock, or
    the store cannot be written (read-only/full/denied: the lock file cannot even be created), in
    which case the store is marked degraded and the MCP orphan sweep still runs."""
```

「降级但仍做能做的事」是个好模式：磁盘满了不能写 job，但 MCP 孤儿清理不需要写。

### 5.5 ticker 为整个 tick 绑定作用域（**包括 pre-loop 代码**）

这是全篇最重要的一条。原文（[`AGENTS.md:31`](../cron/AGENTS.md:31)）：

> **ticker 为整个 tick 绑定每个被服务 profile 的作用域，包括 pre-loop 代码。**
> `scheduler_provider.py::_start_multiplex` 是**一个** ticker 顺序迭代 `profiles_to_serve()`，
> 在 `_profile_cron_scope(home)` 下（home + secret scope + terminal scope）——
> **绝不是 N 个线程**（模块全局会 race）。
> 一个 tick 触碰的一切都在那个守卫内：store 打开、锁路径、backoff/失败计数器
> （`_note_tick_failure`）、job env 构造、以及已完成 job 的 `on_session_end` 刷新。

「**一个** ticker，顺序迭代」这个选择值得展开：

**为什么不用 N 个线程（每 profile 一个）？**

因为代码里有大量模块级全局状态：

```python
# cron/scheduler.py
_parallel_pools: dict[str, ThreadPoolExecutor] = {}
_running_job_ids: set = set()
_running_since: dict = {}
_running_futures: dict = {}
_parallel_pool_max_workers: dict[str, Optional[int]] = {}
```

如果 N 个线程各自 tick 各自的 profile，这些字典会被并发读写。
虽然每个都有锁，但**跨多个字典的一致性**很难保证（比如「加进 `_running_job_ids` 的同一临界区里也写了 `_running_since`」——
分线程后某个中间态就可见了）。

顺序迭代的代价是：一个 profile 的慢 tick 会拖慢其它 profile。
但 tick 本身应该是快的（扫描 + 提交，不等待 job 完成——job 在池里跑）。
所以这个权衡是合理的。

**「包括 pre-loop 代码」是什么意思？**

看 `_start_multiplex` 的结构（[`scheduler_provider.py:549`](../cron/scheduler_provider.py:549)）：

```python
initial_homes = _existing_profile_homes(profile_homes)
register_ticked_homes([_profile_entry(entry)[1] for entry in initial_homes])
logger.info("Multiplex cron scheduler started for %d profile(s): ...")
```

这些在**循环之前**执行。如果它们读 store 或写全局状态，
也必须已经在正确的作用域里——否则就是「用启动 profile 的作用域做了 N 个 profile 的初始化」。

**为什么 `on_session_end` 也要在守卫内？**

因为它是**插件 hook**（见 [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) §6.5）。
插件的 `on_session_end` 可能写自己的状态、可能读凭证。
如果它在守卫外触发，插件会读到启动 profile 的 `HERMES_HOME`。

模块注释里的事故描述（[`AGENTS.md:39`](../cron/AGENTS.md:39)）：

> **为什么**：一个在进入作用域**之前**打开的 store，会把次要 profile 的运行记录
> 写进启动 profile 的 `jobs.json`。

这就是「写错文件」级别的事故：profile A 的运行历史出现在了 profile B 的账本里。

### 5.6 Cron 归属**不**由 `gateway.multiplex_profiles` 门控

[`AGENTS.md:41`](../cron/AGENTS.md:41)：

> **Cron 归属不由 `gateway.multiplex_profiles` 门控。**
> 那个 flag 门控**适配器**；一个 host gateway 进程无论如何 tick **每个** profile 的 store
> （`run.py::_cron_tick_profile_homes`）。
> 把 tick 集门控在它上面，会让每个非启动 profile 的 job 留在一个没有 ticker 访问的 store 里。

这个 bug 的形状很典型：**两个概念被误认为一个**。

- `multiplex_profiles`：是否让**一个进程跑多个平台的适配器**（省 token/连接）；
- 「tick 哪些 store」：是否让这个进程**负责这些 profile 的定时任务**。

它们的答案可以不同：一个用户可能关掉 multiplex（每个 profile 自己起 gateway 适配器），
但仍然只跑一个 cron ticker。如果代码把两者绑定，那些 profile 的 job 就永远不跑。

**「留在一个没有 ticker 访问的 store 里」** 是最坏的失败形态：不报错、不告警，只是**静默不执行**。

### 5.7 「每 profile 进程假设」是一个 bug 类别

这是全篇的核心。原文（[`AGENTS.md:44`](../cron/AGENTS.md:44)）：

> **每 profile 进程假设是 bug 类别。**
> 一个进程 tick N 个 home，所以任何以「本进程的 profile」为 key 的东西都是错的。

列举的六份状态：

```python
_running_job_ids          # 正在跑哪些
_running_since            # 什么时候开始的
_running_futures          # 哪个 future 负责释放
_running_worker_pids      # 外部 worker 的 pid
_running_fire_owners      # 谁发起的
_interrupted_job_ids      # 被打断的
```

看源码（[`cron/scheduler.py:568`](../cron/scheduler.py:568)）：

```python
def _inflight_key(job_id: str, home: Optional[Path | str] = None) -> tuple:
    """``(home key, job id)`` — the identity of one in-flight cron run.

    ONE gateway process ticks every profile, so a job id alone is not unique: two profiles
    routinely carry identically named jobs (``daily-brief``) and sharing a key made the second
    profile's run read as a duplicate of the first and get skipped. ``home`` defaults to the
    active cron scope's home, which the ticker binds per profile for the whole tick.
    """
    return (hermes_home_key(home) if home is not None else hermes_home_key(_get_hermes_home()), job_id)
```

**事故的具体形状**：profile A 和 profile B 各有一个 `daily-brief`。
A 的在跑（key = `"daily-brief"`）。B 的到期了，`try_register_running_job("daily-brief")` 返回 `False`
（因为 key 已存在）→ B 的 job 被当成「重复」跳过。

用户看到的现象：**B 的 daily-brief 从来不发。**

修复后 key 是 `(home_key, "daily-brief")`，两者互不干扰。

**并行池也按 home**（[`scheduler.py:560`](../cron/scheduler.py:560) 上方注释）：

> 并行 cron job 的持久池：`tick()` 提交后返回；长 job 永不阻塞它。
> **按 profile home keyed**：一个 host gateway 复用每个 profile，
> 而 `max_parallel_jobs` 是**每 profile** 的配置键——
> 单个进程全局池会按「先 tick 的那个 profile」定大小，然后把这个限制强加给所有其它 profile。

`_get_parallel_pool`（[`:1210`](../cron/scheduler.py:1210)）：

```python
def _get_parallel_pool(max_workers: Optional[int]) -> concurrent.futures.ThreadPoolExecutor:
    """Return (or create) the persistent parallel pool for the ACTIVE profile. ..."""
    home = hermes_home_key(_remember_inflight_home(_get_hermes_home()))
    pool = _parallel_pools.get(home)
    if pool is None or _parallel_pool_max_workers.get(home) != max_workers:
        if pool is not None:
            pool.shutdown(wait=False, cancel_futures=False)
        pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=max_workers, thread_name_prefix="cron-parallel")
        _parallel_pools[home] = pool
        _parallel_pool_max_workers[home] = max_workers
    return pool
```

注意「`max_workers` 变了就重建池」：用户可以改配置，改了之后下一个 tick 生效。

**存活性查询也要按 home**（[`:774`](../cron/scheduler.py:774)）：

```python
def is_job_running(job_id: str, home: Optional[Path | str] = None) -> bool:
    """True when THIS process has an in-flight run of ``job_id`` FOR ``home`` ...
    The bare-id accessors above report the host-wide union so the shutdown drain and metrics see
    every profile's work. Liveness consumers must not: one process ticks every profile, so a
    ``daily-brief`` running in profile A would otherwise report profile B's idle ``daily-brief``
    as running and keep B's stale one-shot alive as a "possibly live run".
    """
```

这里有一个精细的分裂：

| 消费者 | 该用什么 | 为什么 |
|---|---|---|
| 关闭 drain、指标 | **union**（裸 id） | 它们要「这个进程还有多少活在跑」 |
| 存活性判断（`_job_running_in_this_process`、`cronjob` 工具） | `is_job_running(id, home=...)` | 它们问的是「**这个** job 在跑吗」 |

如果存活性判断也用 union：B 的一次性 job 因为 A 的同名 job 在跑而被认为「可能还活着」，
于是一直不重新 arm → 永远不跑了。

**stale-code yield gate 也用 per-home 谓词**（[`AGENTS.md:50`](../cron/AGENTS.md:50)）：

> 「陈旧代码让位」门问 `scheduler_ownership.owns_cron_tick_for(home)` /
> `live_gateway_ticking(home)`，而不是进程级 runtime-lock 布尔。

[`scheduler_ownership.py:1`](../cron/scheduler_ownership.py:1) 解释了为什么：

> 一个 host gateway 进程复用每个 profile，所以「gateway 是否拥有 profile X 的 cron」
> 不再能从启动 home 单独回答：
> `gateway.status.owns_gateway_runtime_lock` 是启动时设一次的进程全局布尔，
> 而 `is_gateway_runtime_lock_active` 背后的每个路径解析器都走
> `get_process_hermes_home()`，它**忽略**每 tick 的 `_profile_cron_scope` 覆盖。
> 所以当 ticker 被 scope 到某个别的 profile 时，两者都回答的是**启动 home**。
>
> 这里的两个谓词把这些问题分开：
> - `owns_cron_tick_for` —— 本进程是 host gateway **且** tick 那个 home。
> - `live_gateway_ticking` —— **另一个**活着的 host gateway 持有 runtime lock，
>   且它发布的 served set 覆盖那个 home。
>
> 每个探测失败都回答「否」：**所有权声明是确定性，绝不是猜测。**

最后一句是安全原则：**不确定就说没有**。

### 5.8 一个 claim 必须用它注册时的 key 释放

这是最容易写错的一条，也是 ContextVar 陷阱的教科书案例。

原文（[`AGENTS.md:56`](../cron/AGENTS.md:56)）：

> **一个 claim 必须用它注册时的 key 释放。**
> cron 作用域是 ContextVar：`try_register_running_job` 在 ticker 线程内、
> `_profile_cron_scope` 里跑，
> 而池 worker 的 `finally` 在 `ctx.run` **之外**，会解析到**启动 home**。
> 必须传注册的 home（`release_running_job(job_id, home=...)`），
> 否则每个次要 profile 的 claim **泄漏**——
> job 跳过一个触发窗，直到 force-release 兜底扫除它，而 drain 看到幻影工作。
> **绝不**从 key 的一半重建 home（`Path(key[0])`）——用 `_inflight_home_path`。

看源码的 docstring（[`scheduler.py:836`](../cron/scheduler.py:836)）：

```python
def release_running_job(job_id, home=None, *, owner=None) -> None:
    """Remove the registration unless an explicit ``owner`` has been replaced.

    ``home`` MUST be passed by any caller that does not run inside the same cron scope the claim
    was registered under. The scope is a ContextVar the ticker binds per profile: a pool worker
    releasing in a ``finally`` outside ``ctx.run`` resolves the default (launch) home instead, so
    the discard misses the real key and every secondary profile's claim leaks.
    """
```

**画一遍时序**：

```
ticker 线程（scope = profile B）
  ├─ with _profile_cron_scope(B):          # ContextVar: home = B
  │    ├─ try_register_running_job("x")    # key = (B, "x")
  │    └─ pool.submit(worker)              # ← 提交到线程池
  └─ 退出 scope 块                          # ContextVar 恢复为 launch home

池 worker 线程（新的空上下文，或继承提交时的？）
  └─ finally:
       release_running_job("x")            # key = (LAUNCH, "x")  ← 错！
                                            # (B, "x") 永远不释放
```

`ThreadPoolExecutor` 的 worker **不继承**提交时的 context（Go 的 goroutine 才继承；
Python 的线程是独立的）。所以 `_get_hermes_home()` 在 worker 里返回的是**启动 profile**。

**后果**：
1. `(B, "x")` 永远留在 `_running_job_ids` 里；
2. 下一次 B 的 `x` 到期 → `try_register` 返回 False → **跳过**；
3. 直到 `get_wedged_job_ids` 的 force-release 兜底（有一个 allowance 时长）才清除；
4. 期间 `drain` 看到「还有活在跑」，可能延迟关闭。

**还有第二个坑**：「绝不从 key 的一半重建 home」。

```python
# cron/scheduler.py:583
_inflight_home_paths: dict[str, Path] = {}

def _remember_inflight_home(home: Path) -> Path:
    """Record ``home`` under its key so a claim can be mapped back to a usable path."""
    _inflight_home_paths[hermes_home_key(home)] = home
    return home

def _inflight_home_path(home_key: str) -> Path:
    """Real home Path for an in-flight key's home half (falls back to the key itself)."""
    return _inflight_home_paths.get(home_key) or Path(home_key)
```

为什么不能 `Path(home_key)`？因为 `hermes_home_key` 会**规范化**——在 Windows 上会 lowercase。

```python
home_key = "c:/users/alice/.hermes"        # 小写
Path(home_key) = C:\Users\Alice\.hermes    # 文件系统上大小写敏感？
```

如果规范化改变了大小写，`Path(key)` 指向的路径在真实磁盘上**不存在**。
所以必须维护一张 `home_key → 真实 Path` 的表。

### 5.9 被 tick 的 home 离开集合时要回收状态

[`AGENTS.md:63`](../cron/AGENTS.md:63)：

> **当一个 home 离开集合时，它的状态被回收。**
> `register_ticked_homes` 每周期重新发布，并回收离去 home 的并行池；
> 池以前活到 `atexit`，所以每个曾被 tick 的 home 永远保留一个 `ThreadPoolExecutor` 和它的 worker 线程。

场景：你创建了 profile `temp`，跑了一周，然后删掉它。
`_parallel_pools["temp"]` 还在，里面有一个线程池 + N 个空闲线程。
如果用户反复创建/删除 profile，就是**线程泄漏**。

`scheduler_ownership.py:36` `register_ticked_homes(homes)` 每周期重新发布完整集合，
集合差 = 要回收的。

### 5.10 host gateway 为「运行自己 gateway 的 profile」让位

[`AGENTS.md:66`](../cron/AGENTS.md:66)：

> **host gateway 为一个跑自己 gateway 的 profile 让位。**
> `run.py::_cron_profile_gate`（`hermes_cli/web_server.py` 传的同一个门）
> 让启动进程与 per-profile gateway 避开同一个 store：
> tick 锁能阻止同时双跑，但阻止不了**竞态**，
> 而当启动进程赢了时，投递走 `SharedRouteAdapters`/fail-closed 而不是那个 profile 的活适配器。
> 该门把存活性 PID 与 `os.getpid()` 比 ——
> 本进程持有启动 `gateway.pid` **且**在 `served_profiles` 里发布每个被服务的 profile，
> 所以裸存活性答案会把 cron 全 host 停下。

这个 bug 的形状很有意思：**「我自己活着」被误读为「别人活着」**。

代码逻辑：
1. 检查「profile X 的 gateway 是否活着」；
2. 实现是「读 `gateway.pid`，看那个 PID 是否存活」；
3. 但**本进程**就是持有启动 `gateway.pid` 的进程；
4. 所以答案永远是「活着」→ 让位 → 所有 profile 的 cron 全停。

修复：比较存活性 PID 与 `os.getpid()`——如果是自己，就不是「别人在跑」。

### 5.11 重启安全的外部 worker 自我引导

这是最复杂的一条。背景：某些 job 需要在**gateway 重启后仍然存活**——
一个跑 20 分钟的 job 不应该因为 gateway 升级而死。

所以有「外部 worker」：在独立进程（甚至独立 systemd scope）里跑。

[`AGENTS.md:73`](../cron/AGENTS.md:73)：

> **重启安全的外部 worker 自己引导。**
> `_launch_external_cron_worker` 在子进程 `PYTHONPATH` 上钉住 checkout
> —— 在 PM 安装下还钉住已提交代的 `site-packages` —— 并标 `_HERMES_CRON_WORKER_BOOT`；
> 子进程的包入口（`cron/__init__.py` → `cron/worker_bootstrap.py`，
> 在 `cron.jobs` import **之前** —— `-m cron.scheduler` 会先跑包）随后跑 PM 的
> `activate_dependencies`，它为 worker 生命周期**租用**已提交代，
> 跑它的 `.pth` 文件，并在第一个第三方 import 前激活它。
> **激活失败是致命的**：worker 在 ownership ack 之前退出（= 报告的派发失败），
> 而不是跑在一个 collector 可能删除的未租用代上。

这段话涉及 Hermes 的「提交代（committed generation）」机制（见 [`06-provider-runtime.md`](06-provider-runtime.md)
或 `pm/AGENTS.md`）：

- 依赖被安装成一个个**不可变的代**；
- 一个「租约」保证某代在租期内不被垃圾回收；
- 如果 worker 起在一个没租用的代上，而同时 `hermes update` 清理了那代 → worker 跑到一半依赖消失。

**「激活失败是致命的」** 是关键决策：宁可**派发失败**（用户看到错误、可以重试），
也不要**跑在一个可能被删的代上**（表现为随机的 `ImportError`，极难诊断）。

后半段（[`AGENTS.md:82`](../cron/AGENTS.md:82)）：

> gateway 永不重跑 boot —— `hermes_bootstrap` 在它自己启动时已经做了（#122222）。
> worker 的 `__main__` import `hermes_bootstrap`（`finish_worker_boot`）
> 并在读 payload 之前跑 `run_agent` 的 interrupted-pull 恢复，
> **然后才**丢掉 marker：
> 一个源码更新后的 relaunch（`-I`，无 `PYTHONPATH`）或 restore 后 re-exec
> 必须**重放整个 worker**，绝不能落在 ack 之后而 payload 没了、依赖也没 boot。

「marker 什么时候丢」是一个经典的 **commit point** 问题：
marker 表示「boot 已完成」。如果提前丢，re-exec 后就不会重 boot → 缺依赖。
所以必须在**所有** boot 步骤之后才丢。

### 5.12 其它

**（1）Cron 会话传 `skip_memory=True`。**

[`AGENTS.md:87`](../cron/AGENTS.md:87)：

> Cron 会话传 `skip_memory=True`；记忆 provider **故意**不在 cron 期间运行。

为什么？因为 cron 是**无人值守**的批量任务。
如果每次 cron 都 `sync_turn` 到记忆，你的记忆库会被 100 份「今天的天气」污染。
记忆应该记录**用户与 agent 的交互**，不是定时脚本的输出。

**（2）Cron 执行有自己的 session。**

[`AGENTS.md:88`](../cron/AGENTS.md:88)：

> Cron 执行有自己的 session。符合条件的可继续投递可以镜像或种入面向回复的会话：
> origin、无 origin 的 home 回退、用户写的裸平台 home，或 opt-in 的显式目标。
> `all` 展开不获得 home 镜像资格。
> 镜像的 brief 被标为**在 turn 边界追加的 user turn**，保持角色交替。

「角色交替」是什么意思？LLM 的对话格式通常是 `user / assistant / user / assistant`。
如果 cron 结果直接 append 成 `assistant`，而前一条也是 `assistant`，就破了交替。
有些 provider 会报错，有些会静默扭曲行为。

所以镜像 brief 被包成 `user` turn。这也是 [`03-agent-core.md`](03-agent-core.md) 里
message-flow 不变量的一部分。

**（3）`HERMES_DESKTOP=1` 的 ticker。**

[`AGENTS.md:92`](../cron/AGENTS.md:92)：

> cron ticker 在 `HERMES_DESKTOP=1` 的桌面 spawn 后端里**也**运行
> —— 这个 env var 意思是「由 app spawn」，不是「有 GUI 在看」
> （根：能力是**会话的属性**）。

这是一个很常见的误判：开发者看到 `HERMES_DESKTOP=1` 就以为「有用户在看界面」，于是跳过后台任务。
但实际上这个变量只表示启动来源；用户可能把窗口关了但 app 还在跑。

**（4）后台 `delegate_task` 是进程本地的。**

[`AGENTS.md:94`](../cron/AGENTS.md:94)：

> 后台 `delegate_task` 是**进程本地**的；
> 必须熬过重启的工作用 cron job 或 `terminal(background=True, notify_on_complete=True)`。

这一句直接指向 [`13-subagents-delegation.md`](13-subagents-delegation.md)：
委派出去的子 agent 活在父进程的线程里，父进程死了就没了。

---

## 6. cron 的周边可靠性系统

这五个模块在旧版文档里完全缺失，但它们解释了「cron 在真实环境里怎么活下来」。

### 6.1 降级状态：`store_health.py`

[`cron/store_health.py:1`](../cron/store_health.py:1)：

> **不可写 cron store 的降级状态（ENOSPC、EROFS、EACCES）。**
>
> 磁盘满或只读挂载会让每个 store 写在每个 60s tick 上失败。
> 与其每个失败调用点一句 warning，每个 store 目录得到**一条内存记录**：
> 第一次失败的写设置它，后续的更新它，第一次落地的 `jobs.json` save 清除它。
> 当它被设置时，tick 跳过那些**只会失败**的 advance/claim 工作，
> 并最多每分钟重新探测一次 store。
> `probe_store` 也是 `hermes cron status` 和 `hermes doctor` 用的：
> 它们跑在另一个进程，所以读不到这个记录，也不能信任一个没人能写的目录里的标记。

三个设计点：

1. **一次记录，不是 N 条日志**。磁盘满时每个 tick 每 个 job 都会失败，
   日志会被刷爆，真正的问题被淹没。
2. **跳过注定失败的工作**。磁盘满时还去 claim job 是纯浪费 CPU 和日志。
3. **跨进程探测**。内存记录在别的进程看不到，所以 `status`/`doctor` 要**真的写一下试试**。

### 6.2 投递队列：宁可丢也不重

[`cron/delivery_queue.py:1`](../cron/delivery_queue.py:1)：

> **cron 投递通过活 gateway 适配器的 profile 本地持久交接。**
>
> 一个重启安全的 cron worker 在 gateway cgroup 之外执行。
> 它**不能拥有** relay/E2EE 适配器对象，所以它把最终发送排在这里。
> 一个 gateway **至多一次**地 claim 每一行。
> 如果那个 gateway 在 claim 之后死了，结果被标为 `unknown` 且**永不重试**：
> **丢失一次投递比重复一次可能已完成的发送更安全。**

这又是 at-most-once 的选择，理由写得很直白：
- 重复投递：用户收到两条相同的「磁盘满了」告警 → 困惑、不信任；
- 丢失投递：用户没收到 → 下一次 tick 还会检查（如果条件仍在）→ 自愈。

终态（[`delivery_queue.py:34`](../cron/delivery_queue.py:34)）：

```python
_TERMINAL = ("delivered", "failed", "unknown", "suppressed")
MAX_TERMINAL_DELIVERIES = 1000
```

`MAX_TERMINAL_DELIVERIES = 1000` 是一个上限，防止队列表无限增长。

### 6.3 配额停车：`quota_hold.py`

[`cron/quota_hold.py:1`](../cron/quota_hold.py:1)：

> **当一个 provider 的使用窗口已知关闭时，暂停 job 的 fire（#89376）。**
>
> 一个配额耗尽的 provider 用显式的 `retry after <N>s` 回答
> （Codex 429：来自 `hermes_cli.auth_codex._codex_quota_exhausted_error` 的 `AuthError`）。
> 当整个 fallback 链都不可用时，按 cadence 重新 fire **保证**会同样失败直到窗口重开
> —— 每次 fire 是一次用量探测 + 一条投递的失败告警。
> 失败 run 的告警说 job 被**暂停**；`mark_job_run` 随后把 `next_run_at` 停在恢复边界
> （或窗口内多个合法出现里的第一个），并打 `quota_hold_until`，
> 这样 stale-error re-arm（`cron.jobs._job_is_stale_error_recurring`）不会提前把 job 拉回来。

这段描述了一个非常具体的用户体验问题：

```
每 5 分钟跑一次 → 配额用完 → 每 5 分钟失败一次 → 每 5 分钟一条告警邮件
→ 用户睡觉时收到 96 封邮件
```

解法：读 `retry after N`，把 `next_run_at` 推到那个时间点，并标记 `quota_hold_until`。

而 `_job_is_stale_error_recurring`（[`jobs.py:980`](../cron/jobs.py:980)）里有一行配套：

```python
from cron.quota_hold import hold_active
if hold_active(job, now):
    return False  # deliberately parked past a provider usage window, not wedged (#89376)
```

即：「被配额停车」和「卡住了」是两回事。前者不该被 stale-error 恢复逻辑强行拉回来。

### 6.4 事故分组：`incidents.py`

[`cron/incidents.py:1`](../cron/incidents.py:1)：

> **带签名去重与 ack 的持久 cron 失败事故。**
>
> executions ledger 记录每次尝试；这个模块把**失败**按 `(job_id, error signature)` 分组，
> 这样同一个 job 用同一个错误失败时，一旦 ack 就不会每次 run 都重新 ping 操作员。
> 生命周期：`detected` → `alerted` → `closed`。
> **同一个 job + 同一个规范化错误解析到同一个 incident id**，
> 所以一个 closed 的 incident 保持 closed 直到错误文本变化并铸出新的一个。
> `alerted` 意味着一次失败 ping 真的到达了操作员
> （`alerted_at` = 最近一次到达的时间；调度器在 `cron.failure_repeat_alert_hours` 过去前不给重复）。

这是「告警疲劳」的标准解法：

- **签名化**：错误文本规范化（去掉时间戳、URL 里的 query、随机 id）→ hash；
- **分组**：同 job + 同签名 = 同一个 incident；
- **ack 语义**：用户说「我知道了」，这个 incident 就不再 ping——
  **直到错误变了**（那是新问题）；
- **重复间隔**：即使没 ack，也至少隔 N 小时才提醒一次。

与 `quota_hold` 的区别：配额停车是「我知道原因，等时间」；
incident 是「这是真的故障，但我不想每秒都被告知」。

### 6.5 不可达重试：`unreachable_retry.py`

与 `quota_hold` 互补：一个处理「provider 说窗口关闭」，一个处理「provider 完全连不上」。
`quota_hold.py:16` 的注释：

> `cron/unreachable_retry.py` 的补充：这个把 `next_run_at` 移出一个已知关闭的 provider 窗口。
> 任何到达模型的 run 会清除标记。

### 6.6 blueprints：用户从不写裸 cron

[`cron/blueprint_catalog.py:1`](../cron/blueprint_catalog.py:1)：

> **自动化 Blueprints —— 每个自动化一个 slot-schema 定义**，
> 每个表面都原生渲染它：dashboard 表单（`blueprint_form_schema`）、
> 预填的 `/blueprint` slash 命令（`blueprint_slash_command`）、agent 种子 prompt、docs 深链。
> `fill_blueprint` 把值校验成 `cron.jobs.create_job` 的 kwargs ——
> **没有第二个 job 引擎**。
> 用户从不输入原始 cron：`schedule_template` 固定重复规则；只有人类部分（时间、星期几）是 slots。

三个值得学的决策：

1. **同一份定义喂所有表面**。表单、slash 命令、agent prompt 都从 `AutomationBlueprint` 生成。
   如果各写各的，就会出现「表单能填的字段 slash 命令不支持」。
2. **`fill_blueprint` 只是校验 + 转换**，最终调 `create_job`。
   **没有第二个 job 引擎** —— 这是防止「模板系统长成一套平行实现」的关键纪律。
3. **用户不写 cron 表达式**。因为 `0 9 * * 1-5` 对普通人不可读，
   而「工作日 9 点」是可读的。`schedule_template` 保证生成的表达式是正确的。

### 6.7 非内置调度器：`CronScheduler` ABC

[`scheduler_provider.py:135`](../cron/scheduler_provider.py:135)：

```python
class CronScheduler(ABC):
    """Decides WHEN a due cron job fires. Only ``name`` + ``start`` are required; keep every other
    hook NON-abstract with a safe default (``test_abc_growth_stays_additive``)."""
```

「只有两个必须实现；其它 hook 保持非抽象且有安全默认」——这是 ABC 演化的标准做法：
如果每个新 hook 都是 `@abstractmethod`，所有已有实现都会立刻崩。

而 `test_abc_growth_stays_additive` 是一个元测试：它检查这个 ABC 没有新增抽象方法。

可用性检查的约束（[`:148`](../cron/scheduler_provider.py:148)）：

```python
def is_available(self) -> bool:
    """Whether this provider can run here. MUST NOT make network calls; False → built-in."""
```

「MUST NOT make network calls」是因为它在**启动路径**上被调用。
一个要联网 3 秒的检查会让每次 `hermes gateway` 启动都慢 3 秒。

第三方实现叫 `chronos`（[`website/docs/developer-guide/chronos-managed-cron-contract.md`](../website/docs/developer-guide/chronos-managed-cron-contract.md:1)）。

---

## 7. cron 的 CLI 与工具表面

### 7.1 `hermes cron`

[`hermes_cli/cron.py:972`](../hermes_cli/cron.py:972) 的派发表：

```python
_CRON_SUBCOMMANDS = {
    "list": ...,
    "status": ...,
    ...
    "edit": ...,
    "pause": ...,
    "resume": ...,
    "run": ...,
    "remove": ...,
}
_CRON_SUBCOMMANDS["add"] = _CRON_SUBCOMMANDS["create"]
_CRON_SUBCOMMANDS["rm"] = _CRON_SUBCOMMANDS["delete"] = _CRON_SUBCOMMANDS["remove"]
```

即六个主动词 + 三个别名：`add`=`create`、`rm`=`delete`=`remove`。

加上 `incident`、`notepad` 等子组（[`:362`](../hermes_cli/cron.py:362)、[`:932`](../hermes_cli/cron.py:932)）。

根 `AGENTS.md` 有一条相关规则：「argparse 别名派发必须同时接受长名和短名」——
`list`/`ls` 在 kanban 里就是这个模式。

### 7.2 `cronjob` 工具：一个压缩的动作式工具

[`tools/cronjob_tools.py:1`](../tools/cronjob_tools.py:1)：

> Cron job 管理工具：**一个压缩的、面向动作的 `cronjob_manage` 工具**
> （避免 schema/上下文膨胀）；`cronjob()` 对直接 Python 调用者仍可调用。

「避免 schema/上下文膨胀」指的是 [`05-tools-system.md`](05-tools-system.md) 里的核心约束：
**每个工具的 schema 每次请求都发送**。如果拆成 `cronjob_create`、`cronjob_list`、
`cronjob_pause`、`cronjob_resume`、`cronjob_run`、`cronjob_remove` 六个工具，
那就是六份 schema。

一个工具 + `action` 参数 = 一份 schema。这是「窄腰」原则的应用。

工具内部的 action 表（[`:957`](../tools/cronjob_tools.py:957)）：

```python
_JOBLESS_ACTIONS = {"create": _action_create, "list": _action_list}
# ...
"remove": _action_remove, "update": _action_update,
"run": _action_run, "run_now": _action_run, "trigger": _action_run,
```

注意 `run`/`run_now`/`trigger` 都指向同一个 handler——模型可能用任意一个词，
不必为措辞差异报错。

### 7.3 手动 `run` 的心跳

[`tools/cronjob_tools.py:21`](../tools/cronjob_tools.py:21)：

```python
_CRON_RUN_HEARTBEAT_INTERVAL = 10.0
_CRON_RUN_HEARTBEAT_CEILING = 6 * 3600.0
```

注释：

> 心跳节奏，让调用方的**不活动看门狗**在手动 `cronjob(action="run")` 进程内执行时保持不触发
> （远低于 `HERMES_AGENT_TIMEOUT`）。
> 镜像 `tools/environments/base.py::touch_activity_if_due` 的 10s 节奏
> （`delegate_task` 的心跳用 30s）—— 远低于 1800s 的默认 `HERMES_AGENT_TIMEOUT`。见 #76502。
>
> **硬上限**：`HERMES_CRON_TIMEOUT=0` 时，一个真正挂住的 run 会永久掩盖 gateway 看门狗；
> 超过这个值心跳停止，看门狗重新获得权威。

这是「心跳套娃」问题：

```
gateway 看门狗（监控 agent 是否卡住）
   └─ agent 调 cronjob(action="run")  ← 这个是同步阻塞的
        └─ 被触发的 cron job 自己跑很久
```

如果内层不做心跳，外层会以为 agent 卡住了，把它杀掉。
所以内层要定期 `touch`。

但内层如果**永远**心跳，外层就永远不杀——即使内层真的死了。
所以有 6 小时硬上限。

### 7.4 `run` 的 300s claim TTL 不够

`try_register_running_job` 的 docstring（[`scheduler.py:806`](../cron/scheduler.py:806)）：

> 原子地把 `job_id` 加进 in-flight 集合；已在中跑则返回 False（调用方必须跳过）。
> ticker + 手动 run 的**单一去重 owner**（fire claim 的 300s TTL 会被真实 job 超长存活）。
> 调用方**必须**在 `finally` 里配对 `release_running_job`。
> ...
> **这个单一去重 owner 由 ticker 的 `_submit_with_guard` 和手动 run（`tools/cronjob_tools`）共享**：
> 光靠 fire claim 阻止不了双 fire，因为它的 TTL（300s）经常被真实 job 超出，
> 之后一个手动 `cronjob(action='run')` 会成功 claim 并并发跑同一个 job
> （想法来自 #53395 by @izumi0uu）。

画一下事故：

```
t=0      ticker claim job（fire_claim TTL=300s），开始跑
t=400    用户手动 cronjob(action="run")
           → fire_claim 已过期（300s < 400s）
           → 成功 claim
           → 第二个实例开始跑
```

结果：两个实例同时跑同一个 job。如果这个 job 是「给客户发 invoice」，就发了两份。

修复：`_running_job_ids` 不靠 TTL，靠**显式释放**（`finally`）+ force-release 兜底（长时间才生效）。

---

## 8. cron 的配置项

从代码与文档中归纳（这些在 `config.yaml` 的 `cron:` 下）：

| 键 | 默认 | 作用 |
|---|---|---|
| `cron.catch_up_missed` | — | `false` 时跳过已过宽限的错过（带记录原因） |
| `cron.max_parallel_jobs` | — | **每 profile** 的并行 job 数 |
| `cron.failure_repeat_alert_hours` | — | incident 重复告警间隔 |
| `cron.inflight_max_minutes` | — | stale in-flight allowance 下限 |
| `cron.dispatch_in_gateway` | `true` | （kanban）dispatcher 是否跑在 gateway 内 |

环境变量：

| 变量 | 默认 | 作用 |
|---|---|---|
| `HERMES_CRON_TIMEOUT` | 600 | 不活动超时（秒）；`0` = 无限 |
| `HERMES_DESKTOP` | — | 表「由 app spawn」，不表「有 GUI」 |

---

# 第二部分：Kanban

## 9. 什么是 Kanban（以及为什么需要它）

### 9.1 一句话定义

[`kanban_db.py:1`](../hermes_cli/kanban_db.py:1)：

> **SQLite 支撑的 Kanban board，跨 profile 共享（跨 profile 协调原语）。**

三个关键词：
- **SQLite**：不是内存队列，是**持久**的；
- **跨 profile**：多个 profile 的 worker 协作；
- **协调原语**：它是「多 agent 一起干活」的基础设施，不只是个任务列表。

### 9.2 为什么需要它：cron 不够

cron 能回答「**什么时候**跑」，不能回答：

- 「这个任务**归谁**跑？」（多个 profile 都可能有能力）
- 「跑到一半的人**死了**怎么办？」
- 「做完要不要**复审**？」
- 「同一个任务会不会被**两个人**同时干？」

Kanban 就是这些问题的答案。它比 cron 多了**状态机**和**所有权**。

### 9.3 与 cron 的分工

| | cron | kanban |
|---|---|---|
| 触发 | 时间 | 人工/dispatcher/上游任务 |
| 谁跑 | 固定（job 属于一个 profile） | **动态**（assignee + 池） |
| 状态 | 无（每次独立） | 八列状态机 |
| 失败 | 重试 / incident | **自动 block**（防 spin） |
| 复审 | 无 | `review` / `request-changes` |
| 依赖 | `context_from`（数据流） | `task_links`（DAG） |

实际用法：**cron 决定「每天 9 点检查一次队列」，kanban 决定「队列里的活谁干」。**

### 9.4 schema

[`kanban_db.py:12`](../hermes_cli/kanban_db.py:12)：

> Schema：tasks、task_links、task_comments、task_events、task_runs、attachments、notify subs。

| 表 | 作用 |
|---|---|
| `tasks` | 任务本体（status、assignee、claim_lock、worker_pid…） |
| `task_links` | 任务间依赖（parent/child、blocks） |
| `task_comments` | 评论 |
| `task_events` | 事件流（状态变更、claim、spawn…） |
| `task_runs` | 每次执行尝试 |
| `attachments` | 附件 |
| `notify subs` | 通知订阅 |

### 9.5 存储位置

[`kanban_db.py:3`](../hermes_cli/kanban_db.py:3)：

> 住在共享 Hermes 根下：`default` board DB 在 `<root>/kanban.db`（pre-boards 向后兼容），
> 其它 board 在 `<root>/kanban/boards/<slug>/`；一个 board 上的 worker **永不**看到另一个。

注意：**共享根**，不是 profile home。因为它的目的就是**跨 profile**。
这与 cron 的「每 profile 自己的 store」正好相反——两者是有意为之。

---

## 10. 状态机：八列

### 10.1 `DEFAULT_WORKFLOW`

[`kanban_workflow.py:116`](../hermes_cli/kanban_workflow.py:116)：

```python
DEFAULT_WORKFLOW = Workflow(
    columns=(
        Column("triage", "Triage", "◇"),
        Column("todo", "Todo", "◻"),
        Column("scheduled", "Scheduled", "⏱", drag_target=False),
        Column("ready", "Ready", "▶"),
        Column("running", "Running", "●", drag_target=False),
        Column("blocked", "Blocked", "⊘"),
        Column("review", "Review", "◎", drag_target=False),
        Column("done", "Done", "✓"),
    ),
    ...
)
```

| 列 | key | 图标 | 可拖入 | 含义 |
|---|---|---|---|---|
| Triage | `triage` | ◇ | ✓ | 刚进来的原始任务，还没拆解 |
| Todo | `todo` | ◻ | ✓ | 拆解完，等待排期 |
| Scheduled | `scheduled` | ⏱ | ✗ | 定了唤醒时间（需要额外输入） |
| Ready | `ready` | ▶ | ✓ | 可被 claim |
| Running | `running` | ● | ✗ | 正在跑（**只能由内核设置**） |
| Blocked | `blocked` | ⊘ | ✓ | 卡住（等人/等依赖/等重试） |
| Review | `review` | ◎ | ✗ | 做完了，等复审（需要 reviewer） |
| Done | `done` | ✓ | ✓ | 完成 |

`drag_target=False` 的三列值得解释（源码注释 [`kanban_workflow.py:110`](../hermes_cli/kanban_workflow.py:110)）：

> `drag_target=False` 镜像 desktop 的 `LOCKED_COLUMNS`
> （review 需要 reviewer，scheduled 需要 wake time，running 是 kernel-only）。

即：**你可以把卡片拖到 Ready，但不能拖到 Running**——
因为「正在运行」意味着真有一个进程在处理它，不是人说了算的。

### 10.2 人工移动矩阵

```python
manual=_frozen_manual({
    "triage": ("todo", "ready"),
    "todo": ("triage", "scheduled", "ready"),
    "scheduled": ("triage", "todo", "ready"),
    "ready": ("triage", "todo", "scheduled", "blocked", "review", "done"),
    "running": ("triage", "todo", "scheduled", "ready", "blocked", "review", "done"),
    "blocked": ("triage", "todo", "scheduled", "ready", "done"),
    "review": ("triage", "todo", "ready", "done"),
    "done": ("triage", "todo", "ready"),
    ARCHIVED: ("triage", "todo", "ready"),
}),
```

这是一张**允许表**，不是状态转移的完整定义。`Workflow.can_move` 的 docstring（[`:65`](../hermes_cli/kanban_workflow.py:65)）：

> 当人类可以请求 `src -> dst` 时为 True。
> **归档永远允许**；`archived` 是合法源（恢复）。`src == dst` 不是移动。
>
> **Allowed ≠ guaranteed**：verb 仍然应用自己的门（parents open、completion evidence）。

最后一句是关键：这张表只说「人类可以请求」，不说「请求一定成功」。
比如你可以请求把 `todo` 移到 `ready`，但如果它还有没完成的父任务，verb 会拒绝。

### 10.3 已知怪癖：review → todo 落到 ready

代码注释（[`kanban_workflow.py:131`](../hermes_cli/kanban_workflow.py:131)）：

```python
# Known quirk kept for zero behavior change: review -> todo lands in ``ready``
# (reopen_review_task ignores the requested target). Phase 1 fixes it.
"review": ("triage", "todo", "ready", "done"),
```

这段注释值得学：**已知 bug 被显式记录，而不是被默默修掉**。
因为修它可能改变用户已有的工作流（有人可能依赖这个行为），所以推迟到「Phase 1」
（配上用户自定义列的模型）。

### 10.4 `archived` 不是列

[`kanban_workflow.py:29`](../hermes_cli/kanban_workflow.py:29)：

```python
# ``archived`` 在每个 workflow 之外：一个筛选开关，永远不是 board 列。
ARCHIVED = "archived"
```

`validate()` 会拒绝把 `archived` 当列（[`:99`](../hermes_cli/kanban_workflow.py:99)）：

```python
if ARCHIVED in keys:
    raise ValueError(f"{ARCHIVED!r} is reserved and cannot be a column")
```

为什么？因为归档是**视图层**的概念（「不看这些」），不是工作流的一步。
如果它是列，那 dashboard 就要为它画一个泳道，用户会想「把卡片拖进归档」——
但归档其实是终态+可恢复，语义不同。

### 10.5 「Phase 0」的纪律

[`kanban_workflow.py:8`](../hermes_cli/kanban_workflow.py:8)：

> Phase 0（本模块）只持有今天**被消费或被校验**的东西：
> 列清单（顺序、标签、CLI 图标、拖拽目标）和人工移动矩阵。
> 分散的状态副本（`VALID_STATUSES`、`BOARD_COLUMNS`、agent-tool 枚举、CLI 图标）从它派生，
> 且 `tests/plugins/test_kanban_workflow_matrix.py` **双向**把 `manual` 钉到活的 dashboard API。
>
> **内核语义故意不在这里建模** —— 既不是列对 dispatcher 意味着什么（可 claim、终态、父门），
> 也不是内核驱动的转移（约 20 处条件状态写：block 路由、crash/reclaim 返回、父重开、导入）。
> 两者与内核切换一起设计，所以这个模块**永不发布半个契约**。
>
> **纯数据 + 仅 stdlib**：`kanban_db` import 这个模块，永不反向。

「永不发布半个契约」是一个很好的架构纪律：
如果要重构的下一步会**改变**契约，那现在就别把当前状态固化成一个公开模块。

---

## 11. Dispatcher：谁在推动任务前进

### 11.1 四个动作

[`cron/AGENTS.md:116`](../cron/AGENTS.md:116)：

> **Dispatcher**：长命循环（默认 60s），
> 回收陈旧 claim、提升 ready 任务、原子地 claim、spawn 被分配的 profile。
> **默认在 gateway 内**运行（`kanban.dispatch_in_gateway: true`）。

一轮 tick 的四件事，顺序重要：

```
[1] 回收陈旧 claim（reclaim stale）
      └─ worker 死了？claim 过期？→ 释放，任务回 ready
[2] 提升 ready（promote）
      └─ 父任务都完成的 todo → ready
[3] 原子 claim
      └─ CAS: UPDATE ... WHERE status='ready' AND claim_lock IS NULL
[4] spawn
      └─ 起一个进程跑那个 assignee 的 profile
```

独立运行：[`plugins/kanban/systemd/hermes-kanban-dispatcher.service`](../plugins/kanban/systemd/hermes-kanban-dispatcher.service)。

### 11.2 CAS 的具体形状

[`kanban_db.py:2159`](../hermes_cli/kanban_db.py:2159) 附近：

```sql
UPDATE tasks
   SET status = 'running',
       claim_lock = ?,
       claim_expires = ?,
       ...
 WHERE id = ?
   AND status = 'ready'
   AND claim_lock IS NULL
```

`changes() = 0` 就是输。**不重试**——因为下一轮 tick 会再来。

`kanban_db.py:10` 的注释：

> **并发**：WAL + `BEGIN IMMEDIATE` + 对 `tasks.status`/`claim_lock` 的 compare-and-swap
> —— SQLite 串行化写者，所以一个 claimer 赢，输家看到零行（**无重试、无分布式锁**）。

三个技术点：

- **WAL**（write-ahead log）：允许读和写并发（否则读写互相阻塞）；
- **`BEGIN IMMEDIATE`**：立刻拿写锁，而不是等到第一条写语句（避免「读了之后才发现要升级锁」的死锁）；
- **CAS**：把互斥交给 SQLite 的行锁 + WHERE 条件。

### 11.3 自动 block：防止 spin 循环

[`cron/AGENTS.md:124`](../cron/AGENTS.md:124)：

> 在一个任务上 `kanban.failure_limit` 次连续非成功尝试后（默认 2），
> dispatcher **自动 block** 它，以停止 spin 循环。

`DEFAULT_FAILURE_LIMIT = 2`（[`kanban_db_dispatch.py:36`](../hermes_cli/kanban_db_dispatch.py:36)）。

「spin 循环」是什么？一个任务因为某种原因永远失败（比如代码有 bug、依赖的服务不存在），
dispatcher 每次 tick 都会重新 claim + spawn + 失败。一小时 60 次，一天 1440 次。
每次都是一次 LLM 调用（花钱）+ 一条日志。

2 次就 block 是保守的：第一次可能是瞬时故障，第二次仍然失败说明不是。

### 11.4 终态 provider 错误：第一次就 block

同一段注释的后半：

> 一个 worker 以 `KANBAN_TERMINAL_PROVIDER_EXIT_CODE`（78 —— 凭证被撤销、模型没了）
> 退出时，**第一次尝试**就触发它，且**粘性**，因为没有任何重试能治愈它（#114587）。
> worker 自己的 `failure_reason` 分类走 `cli._TERMINAL_PROVIDER_REASONS`。

```python
# hermes_cli/kanban_db.py:314
KANBAN_TERMINAL_PROVIDER_EXIT_CODE = 78
```

为什么 78？这是 `EX_CONFIG`（sysexits.h）——「配置错误」的标准退出码。

**为什么第一次就 block？** 因为「凭证被撤销」不是瞬时的。重试 2 次只是浪费 2 次启动时间
（每次可能 10 秒）和 2 条日志。而且用户需要**立刻看到**「你的 API key 失效了」，
不是「2 次尝试后我放弃了」。

**「粘性」** 意味着：即使有人手动 retry，也不会重置计数。
因为重试不可能成功——除非用户修了凭证，那应该走「unblock + 重新分配」。

### 11.5 `_reclaim_dead_workers`

[`kanban_db_dispatch.py:1146`](../hermes_cli/kanban_db_dispatch.py:1146)：

```python
def _reclaim_dead_workers(conn, board=None) -> _CrashSweep:
```

回收的判定条件（从多处注释归纳）：

- claim 过期（`claim_expires < now`）；
- 或 `worker_pid` 对应的进程已死（**且** 启动时间指纹不匹配）。

注意「启动时间指纹」——见 §12.2。

---

## 12. 隔离与身份

### 12.1 board 是硬边界，tenant 是软命名空间

[`cron/AGENTS.md:122`](../cron/AGENTS.md:122)：

> **隔离**：**board** 是硬边界 —— worker 的环境里钉了 `HERMES_KANBAN_BOARD`，
> 且**看不到其它 board**；**tenant** 是 board 内的**软命名空间**
> （workspace-path + memory-key 隔离，一个 fleet 服务多个业务）。

「硬」与「软」的区别：

| | board | tenant |
|---|---|---|
| 实现 | 环境变量钉住 DB 路径 | 路径/记忆 key 约定 |
| 越界后果 | **技术上不可达**（DB 文件不同） | 可能泄漏（如果代码写错） |
| 谁受益 | 不同客户/团队完全隔离 | 同一个 board 里区分业务线 |

为什么 tenant 不能也做硬？因为同一个 board 里的任务需要互相看见（依赖关系、评论）。
如果 tenant 之间完全不可见，就没法做「A 团队的活依赖 B 团队的输出」。

### 12.2 进程身份：`(pid, 启动时间)` 而不是裸 pid

[`cron/AGENTS.md:129`](../cron/AGENTS.md:129)：

> **进程身份注记**：`kanban --preserve-cache` 含 "serve" —— **绝不**按 argv 子串分类进程（根）。
> worker 存活性是 `(worker_pid, worker_started_at)` ——
> claim 时记录的启动时间指纹（`gateway.status.get_process_start_time`）——
> **绝不**裸 PID 存在性，否则一个被复用的 PID 在回收时被杀。

两个独立的规则：

**（1）不要按 argv 子串判断进程身份。**

`kanban --preserve-cache` 这个命令行里包含 "serve"（在 "preserve" 里）。
如果用 `"serve" in " ".join(argv)` 来判断「这是不是一个 serve 进程」，就会误判。

根 `AGENTS.md` 把这条提升成了全局规则（HX003）：

> **绝不从 argv 子串推断进程身份**；用
> `gateway.status.looks_like_gateway_command_line` /
> `hermes_cli.update_cmd._hermes_holder_subcommand`。

**（2）PID 会被复用。**

```
t=0     worker A 启动，pid=1234，claim 任务 X
t=10    worker A 崩溃
t=20    系统把 1234 分配给 vim
t=30    dispatcher 检查 "pid 1234 活着吗？" → 是 → 以为 worker A 还在跑
        → 不回收任务 X → 任务永远卡在 running
```

修复：记录 `(pid, 进程启动时间)`。启动时间是一个高精度的时间戳，
新进程几乎不可能有完全相同的值。

### 12.3 环境清洗

[`cron/AGENTS.md:138`](../cron/AGENTS.md:138)：

> 被派发的 worker 在**清洗过的**子环境里钉住 `HERMES_KANBAN_BOARD` 与 assignee 的
> `HERMES_HOME`（`build_subprocess_env` + `strip_launch_profile_env`）；
> 它们**绝不**继承默认 profile 的 `.env`。

「清洗」意味着：不只是「设置正确的值」，还要**删掉错误的**。
如果子进程继承了 `HERMES_HOME=/home/u/.hermes`，而我们只想覆盖它，
有些代码路径可能仍然读到了旧的（比如已经 import 的模块缓存了路径）。

`strip_launch_profile_env` 是显式删除。

### 12.4 通知从任务所属 profile 离开

[`cron/AGENTS.md:134`](../cron/AGENTS.md:134)：

> **通知从任务所属的 profile 离开。**
> `hermes_cli/kanban_db_notify.py` 的订阅**携带 profile**；
> `gateway/kanban_watchers_notifier.py` 在**那个** profile 的适配器与作用域下投递
> （`_notify_profile_filter`），**绝不**用 multiplexer 的启动适配器；
> 一个 fail-closed 跳过在 WARNING 记录一次并带 remedy，**绝不**是裸 `continue`。

两个要点：

**（1）用哪个 adapter 发通知？** 必须是**任务所属 profile 的**。

场景：profile `client-a` 的任务完成了。通知应该发到 client-a 的 Telegram bot。
如果用启动 profile 的 adapter，通知会发到**你自己的** Telegram——泄漏客户数据。

**（2）fail-closed 跳过要 log + remedy。**

```python
# ❌ 静默跳过
if not adapter:
    continue

# ✅ 记录 + 说明怎么修
if not adapter:
    logger.warning(
        "kanban notify skipped: profile %r has no %s adapter; "
        "enable it with `hermes gateway --profile %s` or remove the subscription",
        profile, platform, profile)
    continue
```

为什么「裸 `continue`」是错的？因为通知**静默丢失**是用户最难诊断的问题：
「我明明订阅了，为什么没收到？」

### 12.5 Prompt 注入门控：所有权 ≠ 工具访问权

这是全篇最微妙的一条。[`cron/AGENTS.md:141`](../cron/AGENTS.md:141)：

> **Prompt 注入点按所有权门控，不是按工具访问权。**
>
> 工具访问（`kanban_show` 通过一个 profile 的 toolset 可见）
> 和继承的 `HERMES_KANBAN_TASK`（delegate 子进程、worker 旁边的 cron run）
> **都不是所有权**。
>
> kanban 指引（`agent_init`、`system_prompt` fallback）和 stop nudge
> 通过 `agent/delegation_context.py::owned_kanban_task()` 解析任务；
> 其它 reader 把它们的 env 读取与 `is_dispatcher_owned_worker_context()` 配对。

看 `owned_kanban_task` 的实现（[`delegation_context.py:96`](../agent/delegation_context.py:96)）：

```python
def owned_kanban_task() -> str:
    """The board task this execution OWNS: ``HERMES_KANBAN_TASK`` for the dispatcher-owned
    worker, ``""`` otherwise. Tool access is not worker identity — a profile can expose the
    kanban toolset interactively, and children/cron runs inherit the env var — so every
    reader that turns the task id into worker behaviour (guidance, stop nudge, terminal
    outcomes) goes through this one helper."""
    if not is_dispatcher_owned_worker_context():
        return ""
    return (os.environ.get("HERMES_KANBAN_TASK") or "").strip()
```

**具体的事故场景**：

1. 一个 kanban worker 正在跑任务 X（`HERMES_KANBAN_TASK=X`）；
2. 这个 worker 里 agent 调用了 `delegate_task` → 子进程**继承**了 `HERMES_KANBAN_TASK=X`；
3. 这个 worker 里 agent 还触发了 cron job → 那个 job 也继承了同一个环境变量。

现在，子 agent 和 cron job 都会认为「我拥有任务 X」。后果：

- 系统提示里被注入「你在处理任务 X」的 kanban 指引 → **浪费上下文且误导**；
- 任务完成时，子 agent 可能调用 `kanban_complete` → **提前完成别人的任务**；
- stop nudge 会错误地提醒它们「别忘了完成任务 X」。

修复：一个**单一谓词** `is_dispatcher_owned_worker_context()`（[`:71`](../agent/delegation_context.py:71)）：

```python
def is_dispatcher_owned_worker_context() -> bool:
    """The single predicate every ``HERMES_KANBAN_*`` identity gate should use."""
    return not (is_delegated_child_process_context() or _NON_DISPATCHER_OWNED_CONTEXT.get())
```

而 `_NON_DISPATCHER_OWNED_CONTEXT` 是一个 **ContextVar**，用于「进程内但没有所有权」的上下文
（[`:60`](../agent/delegation_context.py:60)）：

```python
def enter_non_dispatcher_owned_context():
    """Mark in-process execution that does NOT own the dispatcher's Kanban task; without it
    a cron agent run inside a worker is misread as that worker (kanban toolset force-added,
    ``kanban_complete`` defaulting to its task). ContextVar-scoped rather than clearing
    os.environ, which the worker's claim heartbeat and concurrent readers share."""
```

**为什么用 ContextVar 而不是清 `os.environ`？**

因为 `os.environ` 是**进程共享**的。worker 的 claim heartbeat 线程还在读它。
如果 cron 运行时清掉 `HERMES_KANBAN_TASK`，worker 的心跳就会误以为「我不是 worker 了」。
ContextVar 只影响当前执行上下文（cron job 的那个线程栈）。

### 12.6 后代围栏是**路径**，不是 flag

[`cron/AGENTS.md:146`](../cron/AGENTS.md:146)：

> **后代围栏是路径，不是 flag。**
> 一个被委派子进程的 Kanban 标记（`agent/delegation_context.py::DELEGATED_CHILD_ENV_MARKER`）
> 携带**被围栏的 board ROOT**；
> `kanban_path_is_fenced(path)` **只**拒绝在 dispatcher 钉住的 `HERMES_KANBAN_DB` 上
> **或**那个 root 下的变更 ——
> 这样一个对着 scratch `HERMES_HOME` 工作的子进程保留可写 board。

这是「修复一个 bug 引入另一个 bug，再修正」的典型案例。

**第一版**：`DELEGATED_CHILD_ENV_MARKER=1` 表示「这是一个被委派的孩子，禁止一切 kanban 写」。

**目标**：防止子 agent 修改父 board（因为子 agent 可能误调 `kanban_complete`）。

**副作用**：一个子 agent 如果被要求「在这个临时目录里写一个 kanban 的 repro」，
它的写操作也被禁了——**即使那个 board 完全无关**。

`scrub_kanban_env` 的 docstring（[`:127`](../agent/delegation_context.py:127)）：

> 标记的值是**被围栏的 board ROOT**，所以围栏只适用于**这条血脉的 board**，
> 而不是后代碰到的每个 Kanban DB：
> 一个对着临时 `HERMES_HOME` 跑 repro 的孩子得到了一个静默只读的 board。
> 一个继承来的**路径值**标记被保留
> （一个搬了 `HERMES_HOME` 的孙子绝不能重新围栏到它的 scratch root 上、反而把真的解开）。

`kanban_path_is_fenced`（[`:141`](../agent/delegation_context.py:141)）：

```python
def kanban_path_is_fenced(path) -> bool:
    """Whether Kanban mutations at *path* ... are denied for this process: always for an
    in-process delegate child (the parent's own board); for a spawned descendant only when
    *path* is the dispatcher-pinned ``HERMES_KANBAN_DB`` or lies under the fenced root the
    marker carries. A legacy ``"1"`` marker fences everything."""
    if _DELEGATED_CHILD_CONTEXT.get():
        return True
    marker = os.environ.get(DELEGATED_CHILD_ENV_MARKER, "")
    if not marker:
        return False
    if marker == "1":
        return True
    ...
```

三种情况：
1. **进程内 delegate child** → 全禁（因为共享父的 board）；
2. **spawn 的后代 + 路径 marker** → 只禁那个 root；
3. **legacy `"1"` marker** → 全禁（向后兼容）。

注意最后一句注释（在 `scrub_kanban_env` 里）：

> 这是**协作式运行时作用域**，不是对直接 SQLite 访问的代码的**禁闭**。

这是诚实的：一个子进程如果直接用 `sqlite3` 打开 DB，绕过所有 Python 层检查，
这个围栏拦不住。它防的是**误操作**，不是**恶意代码**。

### 12.7 `explicit_board_intent_is_pinned`

[`delegation_context.py:78`](../agent/delegation_context.py:78)：

```python
def explicit_board_intent_is_pinned() -> bool:
    """Whether an explicit kanban ``board=`` argument must still resolve through the
    dispatcher-injected env pins (``HERMES_KANBAN_DB`` & friends) rather than
    its own board directory.

    True for in-process delegate children, descendants carrying
    :data:`DELEGATED_CHILD_ENV_MARKER`, and dispatched workers
    (``HERMES_KANBAN_TASK`` set). The pins are the "workers physically cannot
    see other boards" isolation, and :func:`kanban_path_is_fenced` checks the
    pinned path / fenced root — an explicit board that resolved elsewhere would
    also escape that fence. Outside these fences an explicit board is the
    caller's own intent and wins.
    """
```

即：**在围栏内，`board=` 参数被忽略**（强制用钉住的路径）。
否则「隔离」就有一个洞：worker 可以说 `board=other-team` 绕过去。

而**在围栏外**，`board=` 是用户的真实意图，应该尊重。

---

## 13. 一次 Kanban 任务的生命周期

把 §11–12 串起来。

```
[1] create（人或 agent）
      hermes kanban create "修一下登录页的样式问题"
      → status = triage

[2] 拆解（可选）
      kanban_create 支持子任务 / decompose
      → 父子关系写进 task_links

[3] 排期
      assign --profile coder
      状态 triage → todo（拆解完）→ ready（可 claim）

[4] dispatcher tick（每 60s）
      ├─ reclaim：检查所有 running 任务的 worker 是否还活着
      │           （pid + 启动时间指纹）
      ├─ promote：父任务全 done 的 todo → ready
      ├─ claim：CAS UPDATE ... WHERE status='ready' AND claim_lock IS NULL
      │         输的进程 changes()=0，静默放弃
      └─ spawn：起一个进程，env 钉住：
                 HERMES_KANBAN_BOARD=<board>
                 HERMES_KANBAN_DB=<db path>
                 HERMES_KANBAN_TASK=<task id>
                 HERMES_HOME=<assignee 的 home>
                 （清洗掉启动 profile 的 .env）

[5] worker 跑（一个 agent turn）
      ├─ 系统提示注入「你在处理任务 X」的指引（仅当 owned_kanban_task() 非空）
      ├─ 它用 kanban_* toolset（专用，schema 足迹在任务外为零）
      ├─ 心跳：kanban_heartbeat（刷 claim_expires）
      └─ 结束时调 kanban_complete / kanban_block / kanban_request_review

[6] 复审（可选）
      kanban_request_review → status = review
      人 review 后：
        - 通过 → done
        - 不通过 → kanban_request_changes → 回 ready（requeue）

[7] 失败处理
      ├─ 连续失败 < failure_limit：回 ready，下次重试
      ├─ 连续失败 >= 2：自动 block（停止 spin）
      └─ 退出码 78（provider 终态）：第一次就 block，且粘性

[8] 通知
      task_events → notify subs（携带 profile）
      → gateway/kanban_watchers_notifier.py 用**那个 profile 的** adapter 投递

[9] 完成后的数据
      tasks（终态）、task_runs（每次尝试）、task_events（完整审计）、
      task_comments（讨论）、attachments
```

### 13.1 为什么 worker 用专用 toolset

[`cron/AGENTS.md:100`](../cron/AGENTS.md:100)：

> dispatcher spawn 的 worker 用**专用的 `kanban_*` toolset**，
> 所以它们的 schema 足迹在 kanban 任务外为**零**（footprint ladder 第 3 级）。

这句话是 [`05-tools-system.md`](05-tools-system.md) 的直接应用：
- `kanban_*` 工具默认**不进**任何 profile 的工具列表；
- 只有 dispatcher spawn 的 worker（通过 env 标记识别）才获得它们；
- 所以普通对话的用户不会为 13 个 kanban 工具的 schema 付费。

### 13.2 工具清单

[`cron/AGENTS.md:108`](../cron/AGENTS.md:108)：

```
kanban_show, kanban_complete, kanban_request_review, kanban_request_changes,
kanban_block, kanban_schedule, kanban_heartbeat, kanban_comment, kanban_create,
kanban_link, kanban_attach, kanban_attach_url, kanban_attachments
```

外加（仅当平台保存的选择启用了 `kanban`）：
`kanban_list`、`kanban_unblock`（用于看板路由）。

注意 `kanban_list`/`kanban_unblock` 是**额外的**：
一个 worker 不需要「列出所有任务」（它只关心自己那个），也不需要「解除 block」
（那是人的决定）。这两个工具是给**交互式**使用者的。

默认关闭（[`AGENTS.md:112`](../cron/AGENTS.md:112)）：

> 平台若保存的选择启用了 `kanban`（`hermes tools enable kanban --platform <p>`；
> **默认关闭**，在 `CONFIGURABLE_TOOLSETS`）。

### 13.3 `check_fn` 读 schema 构建的选择

[`AGENTS.md:113`](../cron/AGENTS.md:113)：

> `check_fn` 读 schema 构建（`tools/kanban_toolset_context.py`）**自己的选择**，
> **绝不只是**旧的顶层 `toolsets` key。

这里的「schema 构建的自己的选择」指的是：工具是否可用取决于
「这次会话的 toolset 解析结果」，而不是「config.yaml 里的一个全局 key」。

为什么不读全局 key？因为一个 profile 可能通过多种方式获得 kanban：
- 全局 `toolsets: [kanban]`；
- 平台级 `hermes tools enable kanban --platform telegram`；
- dispatcher spawn（env 标记）。

如果 `check_fn` 只读第一种，那后两种就失效了。

### 13.4 `kanban_db.connect` 是自己的 helper

[`AGENTS.md:119`](../cron/AGENTS.md:119)：

> `kanban_db.connect` 是**它自己的**连接 helper ——
> **不要**把它 alias 到 `projects_db.connect`
> （一个按路径邻近性工作的生成器干过这事）。

「按路径邻近性工作的生成器」= AI 代码生成器。
它看到 `hermes_cli/` 下有两个 `*_db.py`，都有 `connect`，就以为可以复用。

但两者完全不同：
- `projects_db.connect` 连接的是项目数据库（每项目一个）；
- `kanban_db.connect` 连接的是共享 board（跨 profile）。

如果混用：worker 会打开**错误的 DB**，看到空任务列表，然后报告「没有任务」——
或者更糟，在项目 DB 里创建 kanban 表。

---

## 14. Kanban 的 CLI

### 14.1 代码形状

**门面 + 20 个兄弟**（`hermes_cli/kanban*.py` 共 21 个文件，合计 15,657 行）：

| 文件 | 行数 | 职责 |
|---|---|---|
| [`kanban_db.py`](../hermes_cli/kanban_db.py) | 4450 | DB 核心、schema、task 操作 |
| [`kanban_db_dispatch.py`](../hermes_cli/kanban_db_dispatch.py) | 3038 | dispatcher 的全部逻辑 |
| [`kanban.py`](../hermes_cli/kanban.py) | 1436 | CLI 门面 |
| [`kanban_db_connect.py`](../hermes_cli/kanban_db_connect.py) | 1297 | 连接/迁移 |
| [`kanban_db_workspace.py`](../hermes_cli/kanban_db_workspace.py) | 843 | workspace 管理（git worktree 等） |
| [`kanban_diagnostics.py`](../hermes_cli/kanban_diagnostics.py) | 834 | 诊断 |
| [`kanban_parser.py`](../hermes_cli/kanban_parser.py) | 477 | argparse 定义 |
| [`kanban_db_notify.py`](../hermes_cli/kanban_db_notify.py) | 441 | 通知订阅 |
| [`kanban_ops.py`](../hermes_cli/kanban_ops.py) | 410 | 操作 |
| [`kanban_transfer.py`](../hermes_cli/kanban_transfer.py) | 371 | 导入导出 |
| [`kanban_decompose.py`](../hermes_cli/kanban_decompose.py) | 343 | 任务拆解 |
| [`kanban_swarm.py`](../hermes_cli/kanban_swarm.py) | 300 | 多 worker 协作 |
| [`kanban_specify.py`](../hermes_cli/kanban_specify.py) | 241 | 规格化 |
| [`kanban_boards.py`](../hermes_cli/kanban_boards.py) | 219 | board 管理 |
| [`kanban_db_graph.py`](../hermes_cli/kanban_db_graph.py) | 214 | 任务初始化与分解 |
| [`kanban_db_boards.py`](../hermes_cli/kanban_db_boards.py) | 200 | board DB |
| [`kanban_pr_acceptance.py`](../hermes_cli/kanban_pr_acceptance.py) | 198 | PR 验收流程 |
| [`kanban_workflow.py`](../hermes_cli/kanban_workflow.py) | 142 | 列定义（纯数据） |
| [`kanban_output.py`](../hermes_cli/kanban_output.py) | 86 | 输出格式化 |
| [`kanban_resume_guard.py`](../hermes_cli/kanban_resume_guard.py) | 69 | 恢复前的守卫（防止重复接续同一任务） |
| [`kanban_pr_acceptance_store.py`](../hermes_cli/kanban_pr_acceptance_store.py) | 48 | PR 验收状态的持久化 |

### 14.2 Verbs 全表

[`cron/AGENTS.md:104`](../cron/AGENTS.md:104)：

```
init, create, list (ls), show, assign, link, unlink, comment, attach, attachments,
attach-rm, complete, request-review, request-changes, reopen-review, block, unblock,
archive, tail
+ watch, stats, runs, log, assignees, heartbeat, notify-*, dispatch, daemon, gc
```

分组理解：

**核心 CRUD**：`init`、`create`、`list`/`ls`、`show`、`archive`

**分配与关系**：`assign`、`link`、`unlink`、`assignees`

**协作**：`comment`、`attach`、`attachments`、`attach-rm`

**状态转移**：`complete`、`request-review`、`request-changes`、`reopen-review`、
`block`、`unblock`、`heartbeat`

**运维**：`watch`、`stats`、`runs`、`log`、`tail`、`dispatch`、`daemon`、`gc`

**通知**：`notify-*`

**别名规则**（[`kanban_parser.py:98`](../hermes_cli/kanban_parser.py:98)）：

```python
_cmd("list", [...], aliases=["ls"], help="List all boards with task counts"),
...
_cmd("list", [...], aliases=["ls"], help="List tasks"),
```

注意 `list`/`ls` 出现在**两个层级**（board 列表 + task 列表），都是一样的别名关系。
根 `AGENTS.md` 的规则：「argparse 别名派发必须同时接受 `list` 和 `ls`」。

### 14.3 `gc` 与 `archive` 的区别

- `archive`：把一个任务归档（状态变化，仍可恢复）；
- `gc`：垃圾回收（真的删除**已经归档且超期**的记录）。

这与 curator 的 `archive` / `purge` 是同构的（见 [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) §14.4）：
**归档是常规操作，删除需要显式且超期**。

---

## 15. Kanban 的插件资产

[`plugins/kanban/`](../plugins/kanban/) 包含：

- `dashboard/` —— web UI（看板视图）；
- `systemd/` —— `hermes-kanban-dispatcher.service`（独立 dispatcher）；
- 其它。

这是「核心 + 插件」分层的示例：
- **核心**（`hermes_cli/kanban*.py`）提供 DB 与逻辑；
- **插件**（`plugins/kanban/`）提供 UI 与部署资产。

为什么 UI 在插件里？因为不是所有用户都需要看板界面。
把它放核心会让 `hermes` 的依赖树多出 React 相关的东西。

---

## 16. 测试约定

### 16.1 位置

[`cron/AGENTS.md:153`](../cron/AGENTS.md:153)：

> `tests/cron/`、`tests/hermes_cli/test_kanban*.py`、`tests/tools/test_kanban*.py`。

### 16.2 schedule 解析当纯函数测

> schedule 解析与追赶窗口是**纯函数** —— **当数据来测**。

`parse_schedule` 不读磁盘、不联网、不看时间（除了 `_hermes_now()` 可注入）。
所以测试可以这样写：

```python
@pytest.mark.parametrize("spec,kind", [
    ("30m", "interval"),
    ("every 2h", "interval"),
    ("in 30m", "once"),
    ("0 9 * * *", "cron"),
    ("every monday 9am", "cron"),
    ("2026-02-03T14:00:00", "once"),
])
def test_parse_schedule_kinds(spec, kind):
    assert parse_schedule(spec)["kind"] == kind
```

这是「行为契约测试」的理想形态：**输入 → 输出**，没有 mock、没有 I/O。

### 16.3 禁止的形状

> **绝不**断言 verb 清单或 toolset 大小（根：no change-detectors）。

```python
# ❌ 每加一个 verb 就红，且不证明任何行为
assert len(KANBAN_VERBS) == 31

# ❌ 每加一个工具就红
assert len(kanban_toolset_tools()) == 13
```

这两条是根 `AGENTS.md` 明确禁止的「变更检测器测试」。

### 16.4 时间相关的测试

> 基于时间的测试用**宽松边界**（≥ 2s）与**事件同步**。

```python
# ❌ 在慢 CI 上随机失败
time.sleep(0.1)
assert ticker_ran

# ✅ 等事件，不等时间
assert event.wait(timeout=5.0)

# ✅ 如果必须等时间，用宽松边界
deadline = time.monotonic() + 5.0
while not done() and time.monotonic() < deadline:
    time.sleep(0.05)
assert done()
```

为什么「≥ 2s」？因为 CI 机器可能有负载尖峰。一个 `sleep(0.1)` 在本地稳定，
在共享 CI 上可能变成 500ms。

### 16.5 生命周期守卫的测试

`lifecycle_guard` 的模式是「命令形状」的，所以测试必须覆盖**误报**方向：

```python
# 该被拒
assert raises(GatewayLifecycleBlocked, "hermes gateway restart")
assert raises(GatewayLifecycleBlocked, "systemctl restart hermes-gateway")

# 不该被拒（散文）
assert not raises("帮我重启一下 gateway 服务看看")   # 中文散文
assert not raises("explain how `hermes gateway restart` works")  # 在解释它
```

第二条尤其重要：一个用户可能让 agent「解释 `hermes gateway restart` 做了什么」。
如果守卫匹配到散文里的命令，这个 job 就创建不了。

---

## 17. 自检题

### A 组：cron 基础

1. Hermes 的 cron 与 Unix cron 的三个本质差异是什么？
2. 为什么 cron store 必须锚在 `get_hermes_home()` 而不是 `get_default_hermes_root()`？#4707 是什么？
3. `TICKER_HEARTBEAT_FILE` 和 `TICKER_SUCCESS_FILE` 为什么要分开？
4. `"30m"` 与 `"in 30m"` 的语义差异？为什么这样设计不会让用户困惑？
5. `parse_schedule` 的判定顺序里，为什么自然语言要先于 `is_every` 处理？
6. 一个无时区的 ISO 时间戳在解析时被赋予哪个时区？如果赋服务器本地时区会怎样（#51021）？
7. `"in 60m"` 为什么按 UTC 加而不按本地墙钟加？
8. `_PAYLOAD_FIELDS` 包含哪些？「至少一个」这条规则的目的是什么？
9. `no_agent=True` 但没有 `script` 为什么在创建时就拒绝？
10. `lifecycle_guard` 为什么强调「命令形状」？它防的是什么循环？

### B 组：一次 fire

11. 正常 fire 的十步是什么（能说出顺序）？
12. 为什么 `next_run_at` 要在**派发之前**推进？这个选择牺牲了什么？
13. 牺牲的东西靠什么补偿？（两个机制）
14. `pending_slot` 为什么要和 `next_run_at` 在同一次 save 里写？
15. 宽限窗口公式是什么？为什么是「周期的一半」？为什么有 2h 上限和 120s 下限？
16. `on_time` / `late` / `catch_up` 的边界与行为差异？
17. 机器关机 3 天后重启，一个日任务会跑几次？为什么？
18. `_LATE_DISPATCH_TOLERANCE_SECONDS = 300` 在区分什么？
19. `completed_occurrence` 为什么不把 `unknown` 状态算作已完成？
20. 为什么真正的记账在 SQLite 而不是 `jobs.json`？

### C 组：加固不变量

21. 「不活动超时」与「墙钟超时」在什么场景下结论不同？举两个 job 的例子。
22. `_cron_inactivity_seconds` 为什么被两处共享（不活动监控 + cwd 锁上限）？
23. 附加脚本为什么用墙钟超时而不是不活动超时？
24. `<home>/cron/.tick.lock` 为什么按 home？如果全局一个锁会怎样？
25. `_acquire_tick_lock_or_degrade` 在磁盘满时还做什么？
26. `_start_multiplex` 为什么用「一个 ticker 顺序迭代」而不是「N 个线程」？代价是什么？
27. 「包括 pre-loop 代码」在说什么？如果不包括会发生什么？
28. `on_session_end` 的刷新为什么必须在 `_profile_cron_scope` 内？
29. `gateway.multiplex_profiles` 与「tick 哪些 store」为什么必须分开？
30. 如果错误地把它们绑定，用户看到的现象是什么？为什么最难诊断？
31. `_inflight_key` 的完整结构？两个 profile 都有 `daily-brief` 时，不带 home 会怎样？
32. 并行池为什么要按 home？`max_parallel_jobs` 是哪个层级的配置？
33. `is_job_running(id, home=)` 与 union accessor 分别服务谁？用错会怎样？
34. `owns_cron_tick_for` 与 `live_gateway_ticking` 分别回答什么问题？
35. `release_running_job` 的 ContextVar 陷阱：画一遍时序，说明哪一行解析到了错误的 home。
36. 为什么不能用 `Path(key[0])` 重建 home？`hermes_home_key` 做了什么规范化？
37. `register_ticked_homes` 每周期重新发布解决什么泄漏？
38. `_cron_profile_gate` 把存活性 PID 与 `os.getpid()` 比较，防的是哪个误判？
39. 外部 worker 的 bootstrap 为什么必须在 `cron.jobs` import **之前**跑？
40. 「marker 只在最后丢」防的是什么？
41. 为什么「激活失败是致命的」比「跑在未租用的代上」更好？

### D 组：cron 周边

42. `store_health` 为什么用「一条记录」而不是每次写失败都 log？
43. `probe_store` 为什么必须真的写一下？
44. `delivery_queue` 在 claim 后 gateway 死掉时标记什么？为什么不重试？
45. `quota_hold` 解决的用户体验问题是什么？举一个具体的数字。
46. `_job_is_stale_error_recurring` 里的 `hold_active` 检查在防什么？
47. `incidents` 的生命周期三态？为什么 ack 之后错误**变化**还会重新 ping？
48. blueprints 的「没有第二个 job 引擎」这条纪律防的是什么？
49. `CronScheduler.is_available()` 为什么不允许网络调用？
50. `_CRON_RUN_HEARTBEAT_CEILING = 6h` 为什么需要？

### E 组：Kanban

51. cron 不能回答、Kanban 能回答的四个问题是什么？
52. 为什么 kanban 的 DB 在**共享根**而 cron 的 store 在**profile home**？
53. 八列分别是什么？哪三列 `drag_target=False`，为什么？
54. `manual` 表和 `can_move()` 的「Allowed ≠ guaranteed」是什么意思？举例。
55. 为什么 `archived` 不能是列？
56. 「Phase 0 永不发布半个契约」在防什么？
57. Dispatcher 一轮的四步是什么？顺序为什么重要？
58. CAS claim 的 SQL 里哪两个条件保证互斥？如果两个 dispatcher 同时执行，输的那个怎么知道？
59. 为什么用 `(pid, 启动时间)` 而不是裸 pid？举一个 PID 复用的时间线。
60. 为什么不能按 argv 子串判断进程身份？`kanban --preserve-cache` 这个例子说明了什么？
61. 自动 block 的阈值是多少？为什么是 2 而不是 1？
62. 退出码 78 为什么第一次就 block？「粘性」是什么意思？
63. board「硬边界」与 tenant「软命名空间」的实现差异？为什么 tenant 不能也做硬？
64. 通知为什么要用**任务所属 profile** 的 adapter？用错会泄漏什么？
65. fail-closed 跳过为什么要 log + remedy，而不是裸 `continue`？
66. 「工具访问权不是所有权」—— 举出两个「不是所有权」的例子。
67. `owned_kanban_task()` 为什么是唯一的判定入口？如果各 reader 自己判断会怎样？
68. `_NON_DISPATCHER_OWNED_CONTEXT` 为什么用 ContextVar 而不是清 `os.environ`？
69. 后代围栏从 flag 改成路径，修的是什么事故？（scratch `HERMES_HOME`）
70. `scrub_kanban_env` 里「继承的路径值标记被保留」这一条在防什么？
71. `explicit_board_intent_is_pinned()` 在围栏内和围栏外的行为分别是什么？为什么？
72. `kanban_attach` 这类工具为什么默认不进普通 profile 的工具列表？
73. `check_fn` 为什么不读全局 `toolsets` key？
74. `kanban_db.connect` 为什么不能 alias 到 `projects_db.connect`？

### F 组：测试与综合

75. 为什么 schedule 解析适合当纯函数测？
76. 「断言 verb 清单」为什么是禁止的形状？
77. 时间相关测试的两个正确做法是什么？为什么「≥ 2s」而不是「精确 100ms」？
78. `lifecycle_guard` 的测试为什么必须覆盖「不该被拒」的方向？
79. 用一个具体场景说明：为什么「每 profile 进程假设」是本篇的核心 bug 类别？
80. 如果让你给 cron 加一个新能力（比如「job 之间传递文件」），你会先回答哪三个问题？

---

<details>
<summary><b>参考答案要点</b></summary>

1. 跑整个 agent turn 而非命令；投递到任意平台；失败有事故分组。存储也在每 profile 的 JSON。
2. 共享根会把所有 profile 的 job 灌进一个 `jobs.json`，并在 ticker 的 HERMES_HOME 下跑 → 跨 profile 泄漏配置/凭证/技能（#4707）。
3. 前者证明 ticker **线程**活着，后者证明最近一次 tick **成功**。一个活着的线程可能持续失败。
4. `30m` 循环，`in 30m` 一次性。因为「30 分钟后提醒我」是常见意图，`in` 给了明确表达。
5. 因为 `every monday 9am` 也以 `every ` 开头但不是时长。
6. 配置的 Hermes 时区。若用服务器本地时区，存储时刻与用户墙钟意图差几小时 → 一次性永不触发 / 循环错时（#51021）。
7. 时长是**流逝时间**，跨 DST 转换的墙钟小时 ≠ 流逝时间。
8. `prompt/script/skill/skills/no_agent`。防止创建一个既无 prompt 也无脚本的空 job。
9. 既不跑 agent 也不跑脚本 = 无意义，早失败优于 tick 时失败。
10. 命令形状避免在散文上误触发。防的是「job 重启 gateway → gateway 复活后重跑该 job」的 SIGTERM-respawn 死循环。
11. 见 §4.1 十步。
12. at-most-once（宁可漏不可重）。牺牲了「崩溃后自动重跑」。
13. `pending_slot` + 扫描恢复（owner 死亡则恢复一次）；executions ledger 的 `scheduled_instant` 防第二次。
14. 否则存在「推进了但没标记」的中间态，那个 slot 就永久消失了。
15. `max(120, min(period//2, 7200))`。一半防两个 slot 同时积压；2h 上限因为「昨天日报今天下午来」比不来更困惑；120s 下限因为 ticker 是 60s 一拍。
16. `on_time` ≤300s 正常；`late` ≤grace 正常但标记；`catch_up` >grace 只跑一次。
17. 一次。逾期的错过只补一次（`catch_up`）。
18. 「ticker 正常抖动」与「真的晚了」。
19. `unknown` 意味着可能跑了也可能没跑，不能证明完成 → 保持可重试（倾向 at-least-once）。
20. `jobs.json` 的 stamp 可变（用户编辑/手动 run），SQLite ledger 是 append-only 的事实。
21. 4 小时但持续有工具调用 → 不该杀；20 分钟无输出卡死 → 该杀。墙钟无法区分。
22. 一个杀一个等，若各算各的值就漂移：锁上限 < 不活动限制时，健康的持有者还在跑等待者就失败。
23. 脚本不是 agent，没有「活动」可监控，只有退出或不退出。
24. 不同 gateway 可能服务不同 profile；全局锁会让一个进程阻塞另一个。
25. 标记 store 降级、跳过注定失败的 advance/claim、仍跑 MCP 孤儿清理。
26. 模块级全局字典会被并发读写，跨字典一致性难保证。代价：一个 profile 的慢 tick 拖慢其它。
27. 循环之前的 `register_ticked_homes` / 日志等也必须已在正确作用域，否则用启动 profile 的作用域做了 N 个 profile 的初始化。
28. 它是插件 hook，插件会读 HERMES_HOME/凭证；在守卫外会读到启动 profile。
29. 一个管适配器多路复用，一个管「谁负责这些 profile 的定时任务」，答案可以不同。
30. 非启动 profile 的 job 永远不执行，不报错不告警——静默不执行最难诊断。
31. `(home_key, job_id)`。不带 home 时 B 的 job 被当成 A 的重复而跳过 → B 的 job 永不发。
32. `max_parallel_jobs` 是每 profile 配置；全局池会按先 tick 的 profile 定大小并强加给所有人。
33. drain/指标要 union；存活性判断要 per-home。用错会让 B 的一次性 job 因 A 的同名 job 在跑而被当成「还活着」，永不重新 arm。
34. 前者「本进程是 host gateway 且 tick 那个 home」；后者「另一个活着的 host gateway 覆盖那个 home」。
35. 见 §5.8 时序：提交到池后退出 scope，worker 的 finally 解析到 launch home。
36. `hermes_home_key` 会规范化（Windows 上 lowercase），`Path(key)` 可能是磁盘上不存在的路径。
37. 池以前活到 `atexit`，每个曾 tick 的 home 永远保留一个 ThreadPoolExecutor + 线程。
38. 「我自己活着」被误读为「别人的 gateway 活着」→ 所有 profile 的 cron 全停。
39. 因为 bootstrap 要在第一个第三方 import 前激活依赖代（`cron.jobs` import 依赖）。
40. 提前丢会让 re-exec 不重 boot → 缺依赖/payload 丢失。
41. 派发失败可见、可重试；跑在未租用代上表现为随机 ImportError，极难诊断。
42. 磁盘满时每个 tick 每 job 都失败，日志被刷爆，真问题被淹没。
43. 内存记录别的进程看不到，且不能信任一个没人能写的目录里的标记。
44. `unknown`。丢失一次投递比重复一次可能已完成的发送更安全。
45. 配额用完时每 5 分钟失败一次 + 一条告警 → 睡觉收 96 封邮件。停车到 `retry after` 边界。
46. 「被配额停车」不是「卡住」，不该被 stale-error 恢复逻辑强行拉回。
47. `detected → alerted → closed`。同样 job + 规范化错误 = 同一 incident；错误文本变化 = 新问题 = 新 incident（重新 ping 是应该的）。
48. 防止「模板系统长成一套平行实现」，导致表单能填的字段 create_job 不支持。
49. 它在启动路径上被调用，一个联网 3 秒的检查会让每次启动都慢 3 秒。
50. 否则 `HERMES_CRON_TIMEOUT=0` 时一个真正挂住的 run 会永久掩盖 gateway 看门狗。
51. 归谁跑、死了怎么办、要不要复审、会不会被两人同时干。
52. kanban 的目的是跨 profile 协调（所以共享）；cron 的目的是每 profile 隔离（所以分开）。
53. triage/todo/scheduled/ready/running/blocked/review/done。scheduled（需 wake time）、running（kernel-only）、review（需 reviewer）不可拖入。
54. 表只说「人类可以请求」，verb 仍应用自己的门。例：todo→ready 可请求，但父任务未完成会被拒。
55. 归档是视图层概念（筛选开关），不是工作流的一步；做成列会诱导「拖进归档」，但归档是终态+可恢复。
56. 如果下一步重构会改变契约，现在就把当前状态固化成公开模块会导致「半个契约」被依赖。
57. 回收 → 提升 → claim → spawn。顺序：先释放死 claim 才能让任务回 ready，先提升才能被 claim。
58. `WHERE id=? AND status='ready' AND claim_lock IS NULL`。输的 `changes()=0`。
59. PID 会复用：worker A 死 → pid 给 vim → 检查「pid 活着」→ 以为 worker A 还在 → 任务永远卡住。
60. `kanban --preserve-cache` 里 "preserve" 含 "serve"，子串匹配会误判为 serve 进程。
61. 2。第一次可能是瞬时故障，第二次仍失败说明不是。
62. 凭证撤销不瞬时，重试只会浪费启动时间；用户需要立刻看到原因。粘性 = 手动 retry 不重置计数。
63. board 靠不同 DB 文件（技术不可达）；tenant 靠路径/记忆 key 约定。tenant 不能硬因为同 board 内任务需要互相可见（依赖、评论）。
64. 用启动 profile 的 adapter 会把 client-a 的通知发到你自己的 bot → 泄漏客户数据。
65. 静默丢失是用户最难诊断的问题（「我订阅了为什么没收到」）。
66. ①交互式暴露 kanban toolset；②delegate 子进程/cron run 继承了 `HERMES_KANBAN_TASK`。
67. 如果各 reader 自己判断，会漏掉某些继承路径（比如 cron run 在 worker 旁边）→ 提前完成别人的任务。
68. `os.environ` 是进程共享的，worker 的 claim heartbeat 线程还在读它；清掉会让心跳误判。
69. 子 agent 对着 scratch HERMES_HOME 跑 repro 时 board 被静默变成只读。
70. 一个搬了 HERMES_HOME 的孙子不能重新围栏到 scratch root，否则把真的 board 解开围栏。
71. 围栏内：忽略 `board=`，强制走钉住的路径（否则隔离有洞）；围栏外：尊重调用者意图。
72. schema 足迹：13 个工具的 schema 每次请求都发送，普通对话不该付费。
73. 因为 kanban 可通过全局 toolsets / 平台级 enable / dispatcher env 三种方式获得，读单一 key 会漏。
74. 一个是项目 DB（每项目一个），一个是共享 board（跨 profile）；混用会打开错误 DB。
75. 无 I/O、无 mock、输入→输出。
76. 变更检测器：每加一个 verb 就红，且不证明任何行为。
77. 事件同步（`event.wait`）+ 宽松边界（≥2s）。CI 负载尖峰会让 100ms 变成 500ms。
78. 防过度匹配：用户可能让 agent「解释 `hermes gateway restart`」，匹配到散文就创建不了 job。
79. 一个进程 tick N 个 home → 所有以「本进程 profile」为 key 的状态（in-flight、池、存活性、锁、失败计数）都会串 profile。
80. ①数据放哪（per-profile 还是共享）②崩溃边界（文件要不要原子写）③跨 profile 可见性（谁该看到）。

</details>

---

## 18. 小结

压缩成九句话：

1. **cron 是「一等 agent 任务」**，不是 shell 命令——所以它的可靠性要求高一个量级。
2. **cron store 按 profile 隔离**（`get_hermes_home()`），**kanban DB 共享**（跨 profile 协调）——
   两个相反的决策，各自有明确理由。
3. **一次 fire 是 at-most-once + 补偿**：先推进 `next_run_at` 再派发，
   用 `pending_slot` + executions ledger 补偿「记账了但没跑」。
4. **不活动超时 ≠ 墙钟超时**：agent 任务时长差异巨大，只有「有没有活动」能区分「在干活」和「卡死」。
5. **一个 ticker 顺序迭代所有 profile**，整个 tick（含 pre-loop）在 `_profile_cron_scope` 内；
   绝不用 N 个线程，因为模块级全局会 race。
6. **「每 profile 进程假设」是核心 bug 类别**：in-flight 状态、并行池、存活性查询、
   yield gate 全部必须带 home。
7. **`release_running_job` 必须显式传 home**：池 worker 的 `finally` 在 ContextVar 作用域外，
   会解析到启动 home → claim 泄漏。
8. **Kanban：board 硬、tenant 软**；**工具访问权 ≠ 所有权**；
   **后代围栏是路径不是 flag**。
9. **进程身份用 `(pid, 启动时间)`，绝不按 argv 子串**——PID 会复用，子串会误匹配。

**下一篇** → [`13-subagents-delegation.md`](13-subagents-delegation.md)：
子 agent 怎么并行、怎么隔离上下文、为什么「后台委派是进程本地的」。
那篇会用到本篇的两个概念：**所有权判定**（delegation 与 kanban 共用 `delegation_context.py`）
和 **进程身份**（子进程的 env 清洗）。
