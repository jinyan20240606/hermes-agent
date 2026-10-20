# 14 · Profile 与多路复用隔离

> **读法**：这一篇讲的是 Hermes 里**最反直觉、也最容易写出静默数据泄漏**的主题。
>
> 一句话概括：**一个进程可以同时服务多个 profile，而"当前是哪个 profile"这件事，
> 不能用 `os.environ` 表达。** 一旦有人写成 `dict(os.environ)`、读一个 import 时的常量、
> 或者裸起一个 `threading.Thread`，代码就会在**没有任何报错**的情况下，
> 把 A 用户的凭证、配置、终端策略、甚至记忆写到 B 的账户里。
>
> 读完你应该能：
> - 说清 `profile` 到底是什么（它是**租户**，不是用户、不是配置档）；
> - 分清**三种 home**（读、进程资产、路由判定）各自该用哪个，以及混用会出什么事故；
> - 解释为什么 `get_secret()` 在 multiplex 下**必须抛异常**而不是回退到 `os.environ`；
> - 指出「半绑定」是什么，以及为什么它是本项目最高频的 bug 形状；
> - 说出 clone 为什么要在 `profiles/.<name>.staging-<pid>` 里建、最后只用一个 `os.rename` 发布；
> - 用「两个磁盘 home + 一个只存在于次要 profile 的 `.env` 名字」写出一个探测测试。

---

## 本篇相对旧版新增

| 旧版（238 行） | 新版 |
|---|---|
| Profile 是什么 8 行 | 补「租户 vs 用户 vs 配置档」三者的区别、`_PROFILE_DIRS` 的九个目录与各自用途、隔离岛原则的完整推论 |
| 两种绑定方式 2 行表格 | 补「绑定时机决定可见范围」的推理、`_apply_profile_override()` 的六条分支（sticky profile、`HERMES_HOME` 已是 profile 形态、sudo、恢复命令）、以及为什么它必须在任何模块 import **之前**跑 |
| `hermes_constants` API 一张表 | 补**三种 home 语义**的完整推导（#119242）、`pin_process_hermes_home` 的长 docstring 逐句拆解、为什么 pin **不能**折叠进 `get_process_hermes_home` |
| `hermes_home_key` 一行 | 补 `_HOME_KEY_CACHE` 为什么存在（`Path.resolve()` 是 syscall，registry 每次 lookup 都走它）、为什么"不存在时不缓存"、`normcase` 与 Windows 大小写 |
| 存活性 12 行 | 补 6 个身份标记逐个理由、**悬空 symlink 也算身份**、**空 `.env` 不算 servable** 的完整推理、tombstone 为什么放在 profile **目录旁**、`mkdir_under_hermes_home` 的双重拒绝 |
| 模式解析 8 行 | 补 flag 的**三态**（`None` / `True` / 被退役的 `False`）、`resolve_multiplex_mode` 的完整判定顺序、`guard` vs `default` vs `retired-opt-out` 三种 `source`、持久化与一次性 marker、CLI/dashboard 为什么必须读 `served_profiles` 记录 |
| Secret 作用域 12 行 | 补**一个进程布尔 + 两个 ContextVar**的分工（`_MULTIPLEX_ACTIVE` / `_MULTIPLEX_CONTEXT` / `_SECRET_SCOPE`）、`serves_routed_profile()` 的三条件、`_GLOBAL_ENV_EXACT` 白名单哲学、`UnscopedSecretError` 的文案设计（`str(exc)` vs `__notes__`） |
| 无 | **§8 终端作用域**（`TERMINAL_*` 的 refusal scope、`build_profile_terminal_scope` 的全量投影） |
| 绑定缝 6 行 | 补 turn 内 vs turn 外的完整清单（release/eviction、shutdown、媒体投递、deferred callback、RPC、cron tick）、`_release_profile_runtime_scope_tokens` 的「释放顺序」 |
| 线程/子进程 10 行 | 补 `spawn_context_thread` 的 `copy_context()` 机制、`served_profile_child_env` 的三种模式、`strip_launch_profile_env` 的残渣名单（含 #107695、#113270） |
| clone 7 行 | 补 staging → rename 的原子发布理由、symlink 实体化、`_CLONE_ALL_HISTORY_EXCLUDE_ROOT` 为什么排除 `cron`、`--clone-channels` 的拒绝条件 |
| 陷阱表 7 行 | 每条补「后果 + 怎么发现 + 怎么修」，并新增两条（import 时读 home、从 env 读 multiplex profile 值） |
| 无 | **§13 在哪里打补丁**（按症状定位文件的表） |
| 无 | §15 自检题 52 道 |

---

## 0. 前置概念

### 0.1 什么是 profile

先把三个容易混的概念分开：

| 概念 | 是什么 | 在 Hermes 里 |
|---|---|---|
| **用户（user）** | 一个人 | 不是 Hermes 的一等概念（multiplex 明确不认证终端用户，见 `website/docs/developer-guide/multiplexing-gateway.md` § Non-goals） |
| **配置档（config profile）** | 一套设置 | 不是；配置档是 profile 的**一部分** |
| **租户（tenant）** | 一套**完全隔离的身份**：配置 + 凭证 + 记忆 + 会话 + 定时任务 + 工作区 | **就是 profile** |

一个 profile 里装的是：

```
<HERMES_HOME>/
├── config.yaml          # 行为配置
├── .env                 # 凭证（只有凭证！）
├── SOUL.md              # 人格
├── profile.yaml         # profile 元数据（描述、显示名）
├── auth.json            # OAuth / 凭证池
├── state.db             # 会话 / 消息 / 状态
├── active_profile       # 仅 default profile：粘性当前 profile 名
├── memories/            # 记忆（MEMORY.md / USER.md）
├── sessions/            # 会话落盘目录
├── skills/              # 技能
├── skins/               # 主题
├── logs/                # 日志
├── plans/               # 计划
├── workspace/           # 工作区
├── cron/                # 定时任务（jobs.json）
├── home/                # 工具子进程的 HOME（Docker/容器场景）
└── profiles/            # 仅 default profile：所有命名 profile 的父目录
    ├── coder/
    ├── writer/
    └── .deleted/        # tombstone 目录
```

前九个目录是 [`hermes_cli/profiles.py:34`](../hermes_cli/profiles.py:34) 的 `_PROFILE_DIRS`，
每个新 profile 创建时都会 bootstrap 出来。

> **`home/` 为什么存在？** 见 [`hermes_constants.py`](../hermes_constants.py:696) 的
> `get_subprocess_home()`：**宿主机上**工具子进程保留真实的 `HOME`（这样 `gh`、`git`、
> `ssh` 的 CLI 凭证仍然可见）；**容器里** `HOME` 持久化到 `home/`，否则每次重启容器都丢。
> 这个分化是全项目最容易踩坑的隐性约定之一。

### 0.2 为什么需要多 profile

三个真实动机：

1. **人格与凭证彻底分开。** 「工作」和「私人」两个 agent 用不同的 Telegram bot、不同的
   API key、不同的记忆库。共用一套就会出现「私人记忆泄漏进工作回复」。
2. **并发。** 两个 profile 可以同时跑两个 gateway（历史上），或者一个 gateway 同时服务两者
   （现在，见 §6）。
3. **可复制起点。** `hermes profile create writer --clone` 从当前 profile 复制一份配置
   与人格，之后两条线**各自演化**。

### 0.3 关键设计：profile 是「隔离岛」

> **没有活的配置继承。**

`--clone` 只在**创建那一刻**复制一次文件；之后源 profile 改了 `config.yaml`，
clone 出来的不会跟着变。这是**故意**的：

- 活继承需要一个「父解析链」，每一次读配置都要问「我是不是被某个父 profile 覆盖了」；
- 一旦允许活继承，"隔离"就不再是可以通过读磁盘验证的性质，而是要靠推理；
- multiplex 下一个进程服务 N 个 profile，活继承会把解析成本乘以 N。

对应到根 `AGENTS.md` 的那句「**the isolation is often the design**（隔离常常就是设计本身）」：
看到一个"缺失的继承"时，先去 `git log -p -S "<symbol>"` 确认它是不是故意的。

### 0.4 四层隔离：进程 / 线程 / 协程 / ContextVar

这是理解整个模块的地基。把「当前 profile」想象成一个**变量**，那么：

| 层 | 共享范围 | 能不能用来表达「当前 profile」 | 为什么 |
|---|---|---|---|
| **进程环境**（`os.environ`） | 进程内**所有线程** | ❌ 绝对不能 | 一个进程服务 N 个 profile，但 `os.environ` 只有一份 |
| **模块全局**（`MODULE_GLOBAL`） | 进程内所有线程 | ❌ 绝对不能 | 同上，而且它在 **import 时**就冻结了 |
| **线程局部**（`threading.local`） | 单个线程 | ⚠️ 能用但错误 | 协程会在**同一个线程**里交替运行，切换时不会帮你换值 |
| **ContextVar** | 一个**执行上下文**（一个 task 及其子 task） | ✅ 正确答案 | `asyncio` 任务、`copy_context().run()`、线程池 worker 都能正确携带 |

所以 Hermes 的选择是：

- **profile 归属** → `ContextVar`（`_HERMES_HOME_OVERRIDE`）
- **凭证映射** → `ContextVar`（`_SECRET_SCOPE`）
- **终端策略** → `ContextVar`（`_hermes_terminal_scope`）
- **部署模式**（这个进程是不是 multiplexer） → **普通模块全局**（这是进程级事实，不是 per-task 值）

一句话：**per-task 的东西放 ContextVar，per-process 的东西放全局。混了就是 bug。**

### 0.5「default」这个词有两层含义

这是**极易误解**的一处，[`tui_gateway/AGENTS.md:54`](../tui_gateway/AGENTS.md:54) 专门写了一句：

> The launch profile is a profile: **"default" means the launch home, never `~/.hermes`**.

意思：

- 用户视角的 "default profile" = `~/.hermes`（根目录）；
- 但一个**以 `hermes -p coder` 启动**的 `serve` 进程，它自己的"启动 profile"是 `coder`。
  在这个进程里给一个 session 做 scope 时，**"没有指定 profile"指的是 coder 的 home**，
  不是 `~/.hermes`。

代码里对应的函数是 [`hermes_cli/profiles.py:2100`](../hermes_cli/profiles.py:2100) 的
`get_active_profile_name()`：它**从 `HERMES_HOME` 反推**当前是哪个 profile
（`default` / `profiles/<name>` 里的 name / 其他路径则返回 `"custom"`）。

---

## 1. 代码形状

### 1.1 文件与行数

| 文件 | 行数 | 职责 |
|---|---|---|
| [`hermes_cli/profiles.py`](../hermes_cli/profiles.py:1) | 2570 | profile 的**全部生命周期**：命名校验、目录解析、列表、创建、克隆、删除、改名、导出、导入、wrapper 脚本、存活性判定 |
| [`hermes_constants.py`](../hermes_constants.py:1) | 1414 | home 解析（三种语义）、`hermes_home_key`、profile 身份/tombstone、`mkdir_under_hermes_home`、子进程 HOME、scratch 目录 |
| [`agent/secret_scope.py`](../agent/secret_scope.py:1) | 452 | **凭证作用域**：`get_secret` 的 fail-closed、`.env` 词法解析 + 缓存、`serves_routed_profile` |
| [`tools/terminal_scope.py`](../tools/terminal_scope.py:1) | 213 | **终端作用域**：`TERMINAL_*` 的全量投影 + refusal scope |
| [`hermes_cli/profile_channels.py`](../hermes_cli/profile_channels.py:1) | 533 | clone 时的**消息通道剥离**（按所有权判定） |
| [`hermes_cli/gateway_multiplex_mode.py`](../hermes_cli/gateway_multiplex_mode.py:1) | 342 | boot 时结算 `multiplex_profiles` 的三态 + guard 原因 |
| [`hermes_cli/gateway_multiplex_served.py`](../hermes_cli/gateway_multiplex_served.py:1) | 126 | 「活着的 multiplexer 服务了哪些 profile」的唯一答案 |
| [`tui_gateway/launch_profile_policy.py`](../tui_gateway/launch_profile_policy.py:1) | 208 | **启动 profile 也是一个租户**：启动 env 冻结、eager 激活、launch scope |

### 1.2 一张图

```
             ┌──────────────────────────────────────────────┐
             │  hermes_cli/main.py::_apply_profile_override │  ← 在任何模块 import 之前
             │  单 profile 命令：os.environ["HERMES_HOME"]=… │
             └───────────────────┬──────────────────────────┘
                                 │
      ┌──────────────────────────┴───────────────────────────┐
      │                                                       │
┌─────▼──────────────────┐                    ┌───────────────▼────────────────┐
│ 单 profile 进程         │                    │ multiplex 进程                  │
│ （CLI / cron worker）   │                    │ （gateway / serve / dashboard） │
│                        │                    │                                │
│ HERMES_HOME = profile  │                    │ os.environ["HERMES_HOME"]       │
│ 所有读都指向它           │                    │   = 启动 profile（永不改）        │
│                        │                    │ 每个 task 用 ContextVar 绑定      │
└────────────────────────┘                    └───────────────┬────────────────┘
                                                              │
                                    ┌─────────────────────────┴──────────────────┐
                                    │  set_hermes_home_override(home)            │
                                    │  set_secret_scope(profile .env + sources)  │
                                    │  install_profile_terminal_scope(home)      │
                                    └────────────────────────────────────────────┘
```

---

## 2. 三种 home 语义（本篇最核心的一节）

`hermes_constants.py` 里有**三个**看起来都在"回答进程 home"的函数。它们**必须**分开，
因为它们的调用者问的是三个不同的问题。

### 2.1 `get_hermes_home()` —— 「**读**这个任务该去哪读写」

[`hermes_constants.py:111`](../hermes_constants.py:111)：

```python
def get_hermes_home() -> Path:
    """Hermes home: context-local override → HERMES_HOME env var → platform default."""
    override = get_hermes_home_override()
    if override:
        return _expand_hermes_home(override)
    if not os.environ.get("HERMES_HOME", "").strip():
        _warn_profile_fallback_once()
    return get_process_hermes_home()
```

优先级：**ContextVar override > `HERMES_HOME` > 平台默认**。

这是**绝大多数代码该用的**。config、`state.db`、skills、memory、SOUL、sessions、kanban、
goals、plugin 发现、MCP 启动——全都通过它解析路径，于是**只要绑了 override，整条链路自动正确**。

`_expand_hermes_home` 会做 `expanduser` + `expandvars`，所以 `~/foo` 和 `$BAR/foo` 都能用。

### 2.2 `get_process_hermes_home()` —— 「**这个进程自己**是谁」

[`hermes_constants.py:160`](../hermes_constants.py:160)：

```python
def get_process_hermes_home() -> Path:
    """Hermes home of the running process, ignoring task overrides.

    For process-level assets (theme YAML, dashboard plugin manifests) that must stay visible while a
    request is scoped to another profile (e.g. embedded ``/chat`` under ``--open-profile``). Follows
    ``HERMES_HOME`` live on purpose: routed-profile DECISIONS compare against
    :func:`get_routing_process_hermes_home` instead (#119242).
    """
```

两个要点：

1. **忽略 override。** 「进程级资产」（主题 YAML、dashboard 插件清单）即使在一个
   被 scope 到别的 profile 的请求里，也必须能看到启动 profile 的那份。
2. **故意 live 跟 `HERMES_HOME`。** 不加缓存、不 pin。为什么？因为嵌入宿主可能
   在运行时改它（见 2.3）。

### 2.3 `get_routing_process_hermes_home()` —— 「**做路由判定**时，基准是谁」

[`hermes_constants.py:199`](../hermes_constants.py:199)：

```python
def get_routing_process_hermes_home() -> Path:
    """Launch home for routed-profile decisions: the pinned home, else get_process_hermes_home()."""
    pinned = _PINNED_PROCESS_HERMES_HOME
    return _expand_hermes_home(pinned) if pinned else get_process_hermes_home()
```

它 = **pin 优先，否则同 `get_process_hermes_home()`**。

### 2.4 为什么必须分出第三个：`#119242` 的完整故事

场景：**Hermes WebUI** 是一个嵌入宿主，它把每一轮要服务的 profile **镜像进
`os.environ["HERMES_HOME"]`**（为了让那些还在直接读环境变量的老代码能工作）。

于是：

- WebUI 自己启动时是 `HERMES_HOME=/home/u/.hermes`；
- 用户打开 `?profile=coder`，WebUI 把 `os.environ["HERMES_HOME"]` 改成
  `/home/u/.hermes/profiles/coder`；
- 现在某段代码要判定「**这个任务是不是在服务别人的 profile？**」
  （`serves_routed_profile()`）。它拿 override 和 `get_process_hermes_home()` 比：
  override=`coder`，process home 也被镜像成了 `coder` → **相等 → 判定"不是 routed"**。

后果（docstring 里写得很直白）：

> that turn's MCP connections fall back to bare, cross-profile names

也就是：**MCP server 的名字不再加 profile 前缀，两个 profile 的 MCP 工具互相串。**

修法就是 `pin_process_hermes_home()`：

[`hermes_constants.py:176`](../hermes_constants.py:176)：

```python
def pin_process_hermes_home(path: str | Path | None) -> None:
    """Pin the home this process serves as its own profile, for "is this task routed?" decisions.

    ... ``None`` clears the pin.

    Process-global on purpose: it names the process's own identity, not a per-task value. It is NOT
    folded into :func:`get_process_hermes_home`: :func:`get_hermes_home` falls back to that for
    tasks carrying no override, and the host's mirror exists precisely so those readers see the
    served profile. Hosts that never mutate ``HERMES_HOME`` need not call this (no-op).
    """
```

**逐句拆解最后那段，因为它是全模块最容易改错的一处：**

1. **「Process-global on purpose」**：pin 描述的是"这个进程自己是谁"，是进程级事实。
   如果做成 ContextVar，每个 task 都会看到不同的"自己"，判定就崩了。
2. **「It is NOT folded into `get_process_hermes_home()`」**：**不要**把 pin 合并进去。
   为什么？因为 `get_hermes_home()` 在没有 override 时会 fallback 到
   `get_process_hermes_home()`。如果合并了，那么"没有 override 的 task"就会看到
   **pin 的 home**，而不是宿主意镜像进去的 home——**镜像就白做了**。
3. **「Hosts that never mutate `HERMES_HOME` need not call this」**：普通 CLI / gateway
   不需要调用它，`get_routing_process_hermes_home()` 会正常退化到
   `get_process_hermes_home()`。

### 2.5 三者的使用规则（记这一张表就够）

| 你要做的事 | 用哪个 | 反例（会出什么事故） |
|---|---|---|
| 读写 config / state.db / skills / memory / sessions | `get_hermes_home()` | 用 `get_process_hermes_home()` → 次要 profile 的会话写进 default 的库 |
| 读进程级资产（主题、dashboard 插件清单、安装目录） | `get_process_hermes_home()` | 用 `get_hermes_home()` → 被服务 profile 看不到自己的主题，退化到别人的 |
| 判定「这个 task 是不是在服务别的 profile」 | `get_routing_process_hermes_home()` | 用 `os.environ["HERMES_HOME"]` → WebUI 镜像让它永远返回 False（#119242） |
| 给用户看路径 | `display_hermes_home()` | 直接打绝对路径 → 泄漏用户名，且容器内外显示不一致 |

**HX001**：路径用 `get_hermes_home()`，文本用 `display_hermes_home()`。
**永远不要硬编码 `~/.hermes`。** 唯一的例外是 `_get_profiles_root()`
（[`hermes_cli/profiles.py:283`](../hermes_cli/profiles.py:283)），它**故意**锚定到
`get_default_hermes_root()` 而不是当前 `HERMES_HOME`——否则 `coder profile list`
就看不到别的 profile 了：

```python
def _get_profiles_root() -> Path:
    """Named-profiles root, anchored to the hermes root (NOT the current HERMES_HOME, which
    may itself be a profile) so ``coder profile list`` sees all profiles."""
    return _get_default_hermes_home() / "profiles"
```

---

## 3. 两种绑定方式

### 3.1 方式 A：import 前改环境变量（单 profile 命令）

[`hermes_cli/main.py:595`](../hermes_cli/main.py:595) 的 `_apply_profile_override()`，
在 `main.py` 的**模块级**被调用（`:667`），也就是**任何其他模块 import 之前**：

```python
_apply_profile_override()
```

它的六条分支（按代码顺序）：

1. **扫描 `-p` / `--profile`**（`_scan_profile_flag`），把它从 `sys.argv` 里**摘掉**，
   免得 argparse 报错。
2. **没有显式 flag，但 `HERMES_HOME` 已经是 profile 形态**
   （`Path(hermes_home_env).parent.name == "profiles"`）→ **直接返回，信任它**。
   这是给 systemd / 容器 / 父进程显式指定的场景。
3. **没有显式 flag，也不是 supervisor/desktop-ssh/s6 场景** → 读
   `<root>/active_profile`（粘性 profile）。这是 `hermes profile use coder` 的机制：
   文件里写 `coder\n`，下一次裸跑 `hermes` 就自动进入 coder。
4. **解析路径**：`resolve_profile_env(profile_name)`。
   注意它保留 `HERMES_HOME` 的**词法拼写**（[`hermes_cli/profiles.py:2553`](../hermes_cli/profiles.py:2553)），
   因为 `PYTHONPATH` 里 Hermes 自己的条目是用同一种拼写写的（#82581 junction 后续）。
5. **错误处理**：profile 不存在时，如果是「恢复类命令」（`profile list`、`profile use` 等），
   降级到 default 并打 warning；否则 `sys.exit(1)`。
6. **`os.environ["HERMES_HOME"] = hermes_home`**。

> **为什么必须"在任何模块 import 之前"？**
> 因为很多模块在 import 时就 `get_hermes_home()` 并缓存到模块常量里（比如某些路径常量）。
> 如果它们在 `HERMES_HOME` 设好之前被 import，那些常量就永久指向平台默认
> ——**这个进程再也回不来了**。这也是 §12 陷阱表里「import 时读 home」的来源。

### 3.2 方式 B：按活动绑 ContextVar（multiplex）

[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md) 的原文：

> The multiplex gateway and the Desktop/dashboard `serve` backend instead bind the active
> profile per activity via a contextvar override while `os.environ["HERMES_HOME"]` keeps the
> launch profile — **a module constant or import-time read there freezes to the launch profile**.

机制：

```python
from hermes_constants import set_hermes_home_override, reset_hermes_home_override

token = set_hermes_home_override(str(profile_home))
try:
    ...  # 这里所有的 get_hermes_home() 都返回 profile_home
finally:
    reset_hermes_home_override(token)
```

`set_hermes_home_override` 的 docstring（[`hermes_constants.py:26`](../hermes_constants.py:26)）
只有一句，但很重要：

> **Deliberately does not mutate `os.environ`** (shared by every thread in the process).

### 3.3 推论一：模块常量会冻结到启动 profile

这是**整个 multiplex 设计的成本**。举例：

```python
# 反例
THEME_PATH = get_hermes_home() / "skins" / "default.yaml"   # ← import 时求值
```

在 multiplex 进程里，这个常量永远是**启动 profile** 的主题路径。次要 profile 的请求
拿到的是别人的主题。

正确形状是**在调用时求值**：

```python
def theme_path() -> Path:
    return get_hermes_home() / "skins" / "default.yaml"
```

同理，`gateway/AGENTS.md` 里那句：

> `hooks/` paths resolve at call time (a module constant freezes to the first importer).

### 3.4 推论二：单 profile 命令也可以有 override

不要把「方式 A」和「方式 B」理解成两个互斥的世界。`serve` 后端在一个
**单 profile 语义的进程**里，通过 `?profile=` 给某个请求装 override——这时
`_MULTIPLEX_ACTIVE` 可能是 `False`，但 override 存在。

这正是 `serves_routed_profile()` 要检查三个条件的原因（见 §7.3）。

---

## 4. `hermes_home_key` 与进程级每 profile 槽位

### 4.1 为什么需要 key

有些东西**必须**是进程级共享的（一个 MCP 发现结果、一个工具注册表 overlay、
一个 `check_fn` 缓存），但它们的内容**又是 per-profile 的**。

解法：**一个字典，key 是 profile home 的规范化字符串**。

[`hermes_constants.py:129`](../hermes_constants.py:129)：

```python
def hermes_home_key(path: str | Path | None = None) -> str:
    """Stable registry key for a Hermes home/profile dir.

    ``strict=False`` so profiles whose directories don't exist yet still get a key.

    The resolved value is remembered per input path. A directory that does
    not exist yet is resolved without touching the cache, because the answer
    can change once it is created (e.g. part of the path turns out to be a symlink).
    """
```

三个细节：

1. **缓存 `_HOME_KEY_CACHE`**（[`hermes_constants.py:126`](../hermes_constants.py:126)）。
   注释解释得很清楚：

   > `Path.resolve()` is a filesystem call, and this function sits under every `ToolRegistry`
   > lookup through `current_scope_key()`, so without this the registry pays a syscall per lookup.

   一个进程只会看到少数几个 home 路径，所以这个 dict 很小。

2. **只有 `strict=True` 成功（真存在）才进缓存。** 目录不存在时用 `strict=False`
   解析但**不缓存**——因为等它被创建后答案可能变（路径中间某段可能是 symlink）。

3. **`os.path.normcase`。** 在 Windows 上把大小写折叠、把 `/` 变 `\`。
   所以 `/a/B` 和 `/a/b` 得到同一个 key（Windows 上它们确实同一个目录）。

`reset_hermes_home_key_cache()`（`:155`）是给测试用的：测试移动了磁盘上的 home 之后
必须清掉，否则 key 还是旧的。

### 4.2 全局槽位清单

所有"一个进程 + 多个 profile"的槽位，都以 `hermes_home_key()` 为维度：

| 槽位 | 位置 | 为什么必须 per-profile |
|---|---|---|
| 工具注册表 overlay（插件注册的工具） | `tools/registry.py` | 两个 profile 装了不同插件，工具集必须不同 |
| `check_fn` 缓存 | [`tools/registry.py:228`](../tools/registry.py:228) | `check_fn` 回答"这个工具可用吗"，而可用性取决于该 profile 的凭证/配置 |
| MCP 发现结果 | `tools/mcp_tool_discovery.py` | 两个 profile 连不同的 MCP server |
| 浏览器 / 图像生成 / TTS / 转录 / 视频 / 搜索 / secret source 注册表 | 各自的 registry | 同类 plugin 的 per-profile overlay |

### 4.3 `check_fn` 缓存的完整形状（`#111151`）

[`tools/registry.py:228`](../tools/registry.py:228) 的缓存 key 是 `(fn, scope)`，
而 `scope` 由一段专门的逻辑算出来（`:281-291`）：

```python
try:
    from agent.secret_scope import serves_routed_profile
    from hermes_constants import get_hermes_home_override
    if not serves_routed_profile():
        return None
    override = get_hermes_home_override()
    return str(Path(override).expanduser().resolve()) if override else CHECK_FN_CACHE_BYPASS
except Exception:
    # Fail closed: bypass both cache layers rather than aliasing requests
    # whose multiplex profile identity could not be resolved.
    return CHECK_FN_CACHE_BYPASS
```

三个设计决定：

1. **单 profile（`serves_routed_profile()` 为 False）→ `scope=None`**，
   缓存全进程共享一份。这保持了 single-profile 进程的字节级行为不变。
2. **routed 且 override 存在 → 用 resolve 后的路径当 scope。**
   所以两个 profile 各有独立缓存。
3. **routed 但拿不到 override → `CHECK_FN_CACHE_BYPASS`**（完全绕过两级缓存）。
   为什么不是"用 None 当 key"？因为那会把"身份不明"的请求**混进单 profile 的缓存**，
   拿别人的可用性判定。**身份不明就 fail closed。**

还有一处很细的处理（[`tools/registry.py:294`](../tools/registry.py:294)）：
`_run_check_fn_uncached` 捕获 `UnscopedSecretError` 时，**不是**看"哪个分支调用了它"，
而是看**catch 现场的活 scope**：

```python
except UnscopedSecretError:
    # The verdict comes from the LIVE scope at the catch site, not from which registry branch
    # ran the probe: ``no_cache_check_fn`` probes skip the cache-scope lookup entirely, so a
    # branch-derived hint misreported every boot-time uncached probe as a lost scope (#110635).
    if current_secret_scope() is None:
        # Expected fail-closed probe: ... No traceback, so this
        # cannot be mistaken for a crashed check_fn (#100697).
        logger.debug(...)
    else:
        # The caller IS scoped but the read still failed closed: the probe dropped the scope on
        # the way to get_secret (a bare thread/executor hop) — a spawn-site bug, kept loud.
        logger.warning(...)
```

两句话总结：

- **boot 时**（还没有任何 scope）→ 这是**预期的** fail-closed，只打 debug，不打 traceback；
- **scope 在但在 get_secret 前丢了** → 这是 **spawn 站点 bug**，必须打 warning 带 traceback。

---

## 5. Profile 的身份、存活性与 tombstone

### 5.1 两个不同的谓词，别混

| 谓词 | 文件 | 回答的问题 | 谁在用 |
|---|---|---|---|
| `named_profile_has_identity` | [`hermes_constants.py:323`](../hermes_constants.py:323) | 「这个目录**声称**自己是 profile 吗？」 | 列表、服务、tick、`-p` 解析 |
| `named_profile_has_servable_identity` | [`hermes_constants.py:330`](../hermes_constants.py:330) | 「这个目录值得让**整个宿主机**改变姿态吗？」 | eager 激活判定 |

### 5.2 六个身份标记

[`hermes_constants.py:318`](../hermes_constants.py:318)：

```python
_PROFILE_IDENTITY_MARKERS = ("config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db")
```

注释是这一节的核心：

> A directory under `profiles/` is a profile only when something identifies it as one.
> Runtime side-effects (cron heartbeats, log rotation, caches) create dirs that carry
> none of these; a pre-tombstone ghost shell or a stray infrastructure dir must never be
> listed, served, ticked, or seeded with the default install's credentials.

注意这句 **「or seeded with the default install's credentials」**——这就是
`#95188` / `#94823` / `#99392` 三个事故的根：

一个**无标记的幽灵目录**如果被"温柔地"当成 profile：
`hermes update` 会往里 seed `.env` → 它**变成**真 profile → 下次就被服务了。
**一次善意的写入把一个幽灵变成了真实的租户。**

### 5.3 悬空 symlink 也算身份

```python
def named_profile_has_identity(profile_home: str | Path) -> bool:
    # A dangling symlinked marker (clone/migration leftover) is still an identity claim:
    # ``is_file()`` follows links, so it alone would make such a profile unlistable.
    home = Path(profile_home)
    return any((home / marker).is_file() or (home / marker).is_symlink() for marker in _PROFILE_IDENTITY_MARKERS)
```

`Path.is_file()` **跟随**符号链接：如果 `.env` 是指向一个已被删除文件的 symlink，
`is_file()` 返回 False。只看 `is_file()` 会让这个 profile **凭空消失**（列不出来、
`-p` 解析失败），但它的 `skills/`、`memories/` 还在磁盘上——用户数据"不见了"。

所以额外的 `is_symlink()` 是一个**保守的"仍声称身份"**判断。

### 5.4 空 `.env` 不算 servable（`#` 类：崩溃 create 的壳）

[`hermes_constants.py:330`](../hermes_constants.py:330)：

```python
def named_profile_has_servable_identity(profile_home: str | Path) -> bool:
    """Stricter than named_profile_has_identity: is this dir a profile a host should change
    its own posture for?

    An EMPTY ``.env`` is all a crashed ``hermes profile create`` leaves behind, and it is enough for
    ``named_profile_has_identity``. Listing such a shell is harmless; counting it as a second tenant
    is not — it flips the whole host's credential reads fail-closed at the next boot. Every other
    marker, and a non-empty or symlinked ``.env``, still counts.
    """
```

**为什么"算第二个租户"这么严重？**

回顾 §7 会讲的 eager 激活：host 启动时如果发现有 ≥2 个 servable home，
就 `set_multiplex_active(True)`。而一旦激活：

- 所有**没有装 scope** 的 `get_secret()` 调用 → **抛 `UnscopedSecretError`**；
- 启动 profile 的凭证从"活的 `os.environ`"改成"激活时冻结的快照"。

也就是说：**一个崩溃留下的空壳目录，足以让整个宿主机在下次启动时切换成 fail-closed 模式。**
如果宿主里还有一小段代码没走 scope，它当场就崩。

所以：**`_servable_profile_homes()` 用更严的谓词，只有 `default` 无条件算。**

### 5.5 tombstone 放在目录**旁**，不放在里面

```python
# Tombstone lives beside the profile dir (not inside) so a stale mkdir or rmtree cannot erase it.
_DELETED_PROFILES_DIR = ".deleted"


def profile_tombstone_path(profile_home: Path) -> Path:
    return profile_home.parent / _DELETED_PROFILES_DIR / profile_home.name
```

为什么不在 `profiles/<name>/.deleted` 里放个文件？

- 一个**迟到的进程**（还持有旧的 home 路径）可能 `mkdir -p` 重建目录，
  或者 `rmtree` 再建——**里面**的标记会被擦掉；
- 放在**旁边**的 `profiles/.deleted/<name>` 不会被任何写 profile 内容的代码碰到。

`mark_named_profile_deleted` / `clear_named_profile_deleted` / `named_profile_is_deleted`
就是这三个操作。

### 5.6 枚举是**纯读**：`mkdir_under_hermes_home`

[`hermes_constants.py:380`](../hermes_constants.py:380)：

```python
def mkdir_under_hermes_home(path: str | Path) -> Path:
    """Create *path*, but never materialize a deleted/missing named profile."""
    target = Path(path)
    assert_named_profile_home_live(target)
    target.mkdir(parents=True, exist_ok=True)
    return target
```

`assert_named_profile_home_live`（`:370`）做的事：

```python
home = named_profile_home(path)
if home is not None and (named_profile_is_deleted(home) or not home.exists()):
    raise FileNotFoundError(
        f"Named profile home does not exist: {home}. "
        "Create the profile explicitly before using it."
    )
```

**为什么这么重要（`#94590`）？**

想象这条链：

1. 用户 `hermes profile delete coder` → 目录删除 + tombstone 写入。
2. 一个**正在运行**的次要进程（比如它的 cron ticker）遍历到了 coder 的 home。
3. 它要写 `state.db`，于是调 `Path(...).mkdir(parents=True, exist_ok=True)`。
4. **目录被重建了**（空壳）。
5. 下一次 `_iter_named_profile_dirs()` ……它没有身份标记，所以还是不会被列出。
   但如果某处"温柔地" seed 了 `.env` → 它**回来了**，带着**默认 profile 的凭证**。

所以规则是：**服务/枚举路径绝不 mkdir 一个命名 profile home。**
`SessionDB`、logging、cron（`_ensure_cron_dir`）都走 `mkdir_under_hermes_home`。

对应地，`profiles_to_serve()` 的 docstring（[`hermes_cli/profiles.py:1151`](../hermes_cli/profiles.py:1151)）写着：

> **Pure directory read: never creates a profile dir (#94590).**

### 5.7 名字语法

[`hermes_constants.py:320`](../hermes_constants.py:320)：

```python
PROFILE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
```

注释：**「every profile-directory gate imports this one object」**——单一权威。
`hermes_cli/profiles.py:29` 里那个 `_PROFILE_ID_RE` 只是 legacy 别名。

`normalize_profile_name`（[`hermes_cli/profiles.py:355`](../hermes_cli/profiles.py:355)）
还有一条容易漏的规则：

```python
if not isinstance(name, str):
    raise ValueError(
        "profile name must be a string, got "
        f"{type(name).__name__}: {name!r}"
    )
```

为什么对**非字符串**这么严格？docstring 说：

> a numeric profile id (e.g. a DB row id or a falsy sentinel) silently coerced via `str()` becomes a
> real on-disk profile directory (`profiles/0/`, `#88842`).

也就是：某处把数据库行 id `0` 传进来，`str(0)` → `"0"` → **磁盘上真的多了一个 profile**。

### 5.8 目录形状 → profile 名

`named_profile_home`（`:264`）向上遍历父目录，找 `profiles/<name>` 形状：

```python
for candidate in (current, *current.parents):
    if (candidate.parent.name == "profiles" and not candidate.name.startswith(".")
            and _is_hermes_profiles_root(candidate.parent)):
        return candidate
    if candidate.name == ".hermes":  # default home: a coincidental profiles/ ancestor is not a root
        return None
```

两个防误判：

- **名字不能以 `.` 开头**：否则 `profiles/.deleted/coder` 会被当成 profile `coder`。
- **`profiles/` 的父目录必须"确实是 Hermes home"**（`_is_hermes_profiles_root`，`:242`）：
  接受 `~/.hermes` 布局、带 Hermes home 标记文件的根、带 `.deleted/` 目录的根、或默认根。
  否则 `/home/u/projects/myapp/profiles/web` 这种**普通项目的 profiles 目录**会被误判。

`profile_name_for_home`（`:280`）再加一条：

> The default home is the Hermes root itself, so its **basename is an installation detail**
> (`.hermes` on POSIX and commonly `hermes` on Windows), not the profile id `default`.

所以 default 的判定是**路径比相等**，不是比 basename。

---

## 6. 多路复用模式解析

### 6.1 flag 的三种状态

`gateway.multiplex_profiles`（也接受顶层 `multiplex_profiles`）在
[`gateway/config.py`](../gateway/config.py) 里解析，`GatewayConfig` 会保留**三态**：

| 状态 | 含义 | 谁决定 |
|---|---|---|
| `True` | 显式开 | config.yaml / `GATEWAY_MULTIPLEX_PROFILES` |
| `False` | 显式关 —— **已退役** | 同上，但会被 warn 后当成"未设" |
| `None` | 未设 | 默认情形 → boot 时结算 |

**为什么 `False` 是"退役"而不是"关掉"？**

[`hermes_cli/gateway_multiplex_mode.py:43`](../hermes_cli/gateway_multiplex_mode.py:43)：

```python
RETIRED_OPT_OUT_REASON = (
    "gateway.multiplex_profiles: false is retired and was rewritten to true; one gateway per host "
    "serves every profile. A per-profile gateway is `gateway.standalone: true` in that profile's "
    "config (temporary shim) or `--force`."
)
```

模块 docstring（`:1-17`）说得更完整：

> An explicit `false` is RETIRED (multiplex-only ruling): it parses, it is logged, and it is then
> resolved exactly like an unset key. **The key itself survives because it is still the RUNTIME
> mode flag every scoped code path reads** (`config.multiplex_profiles`) — what it can no longer do
> is pin a second gateway process onto this host.

所以：

- **作为拓扑选择**：`false` 不再生效（不能因此起第二个 gateway 进程）；
- **作为运行时标志**：代码里 `if config.multiplex_profiles:` 仍然读它，而且 boot 会把它写成 `True`。

`gateway.standalone: true`（[`hermes_cli/profiles.py:1080`](../hermes_cli/profiles.py:1080)）
是**临时**向后兼容垫片，专门给"还没修完的 multiplexing 缺口"用（per-profile stop/restart、
次要 profile 的 WhatsApp bridge、dashboard scoping）。每个提到它的界面都会打
`STANDALONE_DEPRECATION_NOTICE`，**防止有人把它当前长期方案来建**。

还有一个细节：**default profile 永远不是 standalone**（它就是宿主），
如果有人在 default 的 config 里写了这个 key，会 warn 一次然后忽略：

```python
_STANDALONE_DEFAULT_WARNING = (
    "gateway.standalone is ignored on the default profile: it is the host gateway")
```

### 6.2 `resolve_multiplex_mode` 的完整判定顺序

[`hermes_cli/gateway_multiplex_mode.py:228`](../hermes_cli/gateway_multiplex_mode.py:228)。
**顺序是有意义的**，从上到下逐条短路：

```
resolve_multiplex_mode(config)
│
├─ 1. standalone_launcher_decision(config)          # 启动 profile 自己配了 gateway.standalone
│      → MultiplexDecision(False, "guard", STANDALONE_PROFILE_REASON)
│      ⚠ 这一条会**改写** config.multiplex_profiles = False
│
├─ 2. current 为真（显式 true）                       # 永不被二次猜测
│      → MultiplexDecision(True, "config")
│
├─ 3. retired_opt_out = (current is False)          # 记住，但不当结论
│
├─ 4. implicit_multiplex_blocker()                  # 见 6.3
│      └─ 抛异常 → blocker = "preflight failed (...)"  # 坏掉的预检不能拖死 gateway
│
├─ 5. blocker 存在
│      → MultiplexDecision(False, "guard", blocker)
│
├─ 6. retired_opt_out 且无 blocker
│      → MultiplexDecision(True, "retired-opt-out", RETIRED_OPT_OUT_REASON)
│
└─ 7. 其余（未设且无 blocker）
       → MultiplexDecision(True, "default", "gateway.multiplex_profiles unset; default applies")
```

**第 1 条为什么排在最前？** 因为 `gateway.standalone: true` 是**per-profile 的明确意图**，
即使 default 的 config 说 `true` 也不该把它拖进来。

**第 2 条为什么不检查 blocker？** docstring：

> An explicit `true` is never second-guessed.

显式就是显式。guard 只服务于**隐式默认**。

返回的 `MultiplexDecision`（`:99`）：

```python
@dataclass(frozen=True)
class MultiplexDecision:
    enabled: bool
    # "config" (config.yaml / env override — explicit), "default" (implicit default applied),
    # "guard" (implicit default refused; ``reason`` names the blocker).
    source: str
    reason: str = ""
```

`source` 其实是四种：`"config"` / `"default"` / `"guard"` / `"retired-opt-out"`。
它决定后面怎么 log、怎么持久化、要不要打 boxed warning。

### 6.3 `implicit_multiplex_blocker` 的五个 blocker

[`hermes_cli/gateway_multiplex_mode.py:124`](../hermes_cli/gateway_multiplex_mode.py:124)：

```
implicit_multiplex_blocker()
│
├─ 1. _standalone_launcher()                       → STANDALONE_PROFILE_REASON
├─ 2. len(profiles_to_serve(multiplex=True, include_parked=True)) < 2
│                                                   → SINGLE_PROFILE_REASON
├─ 3. _host_supports_migration()                    → 宿主原因（s6 容器等）
├─ 4. plan.standalone_secondaries 非空
│        → "profile(s) 'a' (pid 12), 'b' (launchd ...) still run their own gateway;
│           fold them with `hermes gateway migrate --multiplex`"
└─ 5. plan.blocked                                  → "; ".join(plan.blockers)
```

几条注释值得单独抄出来：

**关于第 2 条**：

```python
# Cheap and first: a single-profile install has nothing to multiplex, and the fail-closed secret
# scope the multiplexer arms buys it nothing. (Also keeps every embedded/test runner off the
# service-manager probes below.) Create a second profile and restart to start serving it.
```

注意 `include_parked=True`：**parked 的 profile 也算**。为什么？注释：

> Parking is reversible without a host restart, so keep the reconcile watcher alive.

也就是：一个被 `hermes -p X gateway stop` park 掉的 profile，随时可能被 unpark，
**不需要重启宿主**。所以它仍然算"有第二个租户"。

**关于"启动 profile 的身份不是 blocker"**：

```python
# The launching profile's IDENTITY is deliberately not a blocker: multiplex-only means "the one
# host process", whichever profile started it. Gating on ``active == 'default'`` made a host
# whose only gateway runs under a named profile permanently standalone — and every lifecycle
# verb built on "the default's multiplexer" blind to the process actually serving the host.
```

这条很重要：**谁能开启 multiplex，不取决于它是哪个 profile。** 早先的实现在
`active == "default"` 上做了门控，导致"只有一个 gateway 但跑在命名 profile 下"的机器
**永久 standalone**。

**每一条 blocker 都是暂时的、可修的**：

> Every blocker here is a TRANSIENT, fixable condition, which is why this function is now also
> the whole answer for an explicit `gateway.multiplex_profiles: false` ...: **the host converges
> the moment the blocker is gone.**

这就是为什么 `false` 可以安全退役：未设路径**并不乐观**，它会在真有 blocker 时保持 standalone
并说明原因，blocker 一消失就自动收敛。

### 6.4 三种 log 行为

[`hermes_cli/gateway_multiplex_mode.py:271`](../hermes_cli/gateway_multiplex_mode.py:271)：

| `source` | 日志 | 持久化 | 用户可见 |
|---|---|---|---|
| `"retired-opt-out"` | `warning` + 改写 config + 打 boxed notice | ✅ + 一次性 marker `.multiplex_opt_out_rewritten` | ✅ |
| `"guard"` + `SINGLE_PROFILE_REASON` | `info`（"Single-profile install…"） | ❌ | ❌（没东西可喊） |
| `"guard"` 其他原因 | `warning`（"This gateway stays standalone: …"） | ✅ 写进 `gateway_state.json` 的 `multiplex_standalone_reason` | ✅ boxed warning 列出**没被服务的 profile** |
| `"default"` | `info`（"Serving every profile on this host…"） | ✅（把 unset 写成显式 `true`） | ❌ |

`persist_resolved_default`（`:171`）的两条硬规则：

1. **guard 拒绝时绝不写。**
   > the file must not say true while the runtime is standalone
2. **`retired-opt-out` 时写一个一次性 marker**，让 `hermes update` 的总结再打一次 notice
   然后删掉它——保证这次翻转**在两个界面上都不静默**。

### 6.5 CLI / dashboard 为什么**不能**用合并默认值

[`hermes_cli/gateway_multiplex_mode.py:79`](../hermes_cli/gateway_multiplex_mode.py:79)：

```python
def default_gateway_multiplexes(default_home: Optional[Path] = None) -> bool:
    """Does the default profile's gateway serve every profile? For CLI/dashboard processes: the LIVE
    gateway's ``served_profiles`` record when one runs (it settled the unset default itself), else
    the explicit flag, else False — an unset flag is decided by the gateway at boot, never guessed
    here.
    """
```

读顺序：**活的 `served_profiles` 记录 → 显式 flag → False**。

为什么记录优先？[`hermes_cli/gateway_multiplex_served.py:1`](../hermes_cli/gateway_multiplex_served.py:1)
的模块 docstring 给了两条理由：

> the default `config.yaml` plus `GATEWAY_MULTIPLEX_PROFILES` as seen by the *CLI* process is only a
> guess (`hermes -p coder ...` loads coder's `.env`, so an **env-only opt-in on the default profile
> is invisible to it**, and an **allowlist edited after start flips the guess before the restart**).

也就是两种"猜错"：

1. **CLI 进程看不到 default 的环境变量。** 你跑的是 `hermes -p coder gateway status`，
   这个进程加载的是 `coder/.env`，default 的 `.env` 根本不在环境里；
2. **配置可能在启动后被改了。** 用户改了 `config.yaml`，但 gateway 还是老状态直到重启。

而且注意 `recorded_served_profiles()` 返回 `None` 和 `[]` 的**区别**
（[`hermes_cli/gateway_multiplex_served.py:33`](../hermes_cli/gateway_multiplex_served.py:33)）：

> Callers fall back to config derivation only on `None`: **an empty list is an authoritative
> "serves nobody else"**.

还有一个活性的判定细节（`live_default_gateway_pid`，`:19`）：

> A launch-service gateway can be live with no `gateway.pid` at all, and a stale record whose PID
> was recycled by an unrelated process must not make its `served_profiles` authoritative.
> **Never key this off the record's `updated_at`: an idle gateway never advances it.**

三个失败形状，一次说完：

1. 只信 `gateway.pid` → launchd/systemd 托管的 gateway 没有 pid 文件，会被判"没在跑"；
2. 只信 pid 文件内容 → PID 被无关进程回收，会读到别人的记录；
3. 只信 `updated_at` → **空闲 gateway 永远不更新它**，会被判"过期"。

正确做法：`gateway.status.live_gateway_pid_for_home`——pid 文件 + 锁 + runtime 记录，
**每一项都要对着活进程验证**（启动时间、命令行、home）。

### 6.6 谁会去调 `set_multiplex_active(True)`

| 调用点 | 时机 |
|---|---|
`GatewayRunner.__init__` | gateway 启动，`config.multiplex_profiles` 为真 |
| `load_gateway_config_for_runner()`（[`gateway/run.py:1831`](../gateway/run.py:1831)） | 在**重新加载**主配置之前（scope miss 不能落到启动 profile 的 `os.environ`） |
| `activate_multi_profile_hosting()`（[`tui_gateway/launch_profile_policy.py:46`](../tui_gateway/launch_profile_policy.py:46)） | `serve` / dashboard 第一次服务第二个 home |
| `activate_multi_profile_hosting_eagerly()`（`:71`） | host **启动最后一步**，若磁盘上已有 ≥2 个 servable home |
| `set_multiplex_active` 的自动 pin | 激活时顺带 pin 启动 home |

`load_gateway_config_for_runner` 的 docstring 值得整段读（[`gateway/run.py:1831`](../gateway/run.py:1831)）：

```python
"""Load gateway config for the process-level GatewayRunner. An UNSET ``multiplex_profiles`` is
settled first by ``resolve_multiplex_mode`` ... Multiplexed: set multiplex-active, then reload
under the default root's ``_profile_runtime_scope`` — **not ``get_hermes_home()``, which is the
named launcher when a profile-scoped process started the host.** A scope miss must not fall
through to that process's ``os.environ``. Off -> identical to ``load_gateway_config()``.

The probe load above only decides whether this process is a multiplexer. The primary config is
the scoped reload: multiplex must already be active (a scope miss must not fall through to the
launching profile's ``os.environ``) and **the home must be the default root, not
``get_hermes_home()`` — a named launcher's home is not the owner of the primary adapter map.**
"""
```

两个反直觉点：

1. **先加载一次（probe），再加载一次（scoped）。** 第一次只是为了决定"我是不是
   multiplexer"；第二次才是真正的配置，而且必须在**已经激活 + 已绑 default scope**之后。
2. **第二次绑的是 default root，不是 `get_hermes_home()`。** 因为启动 profile 可能是
   `coder`，但 primary adapter map 的 owner 永远是 **default**。

---

## 7. Secret 作用域（本篇最重要的一节）

### 7.1 反面教材：为什么不能 union 进 `os.environ`

[`agent/secret_scope.py:1-11`](../agent/secret_scope.py:1) 的模块 docstring：

> The multiplexing gateway serves many profiles from one process; each profile's `.env` keys
> **cannot** be unioned into `os.environ` (profile A's keys would leak into profile B's turns and
> subprocesses). This module is a fail-closed, context-local secret scope.

三种泄漏路径：

1. **turn 之间**：A 的 `OPENAI_API_KEY` 留在环境里，B 的 turn 读到了它 → 账单算错人；
2. **子进程**：`subprocess.run(..., env=dict(os.environ))` → 子进程拿到所有人的 key；
3. **授权判定**：`FEISHU_ALLOWED_USERS` 泄漏 → B 的允许名单被 A 的覆盖 →
   **静默拒绝 B 的所有发送者**（`#86905`）。

第 3 条特别毒，因为它**不报错**：用户只是发现"机器人不理我"。

### 7.2 一个进程布尔 + 两个 ContextVar

| 名称 | 类型 | 描述什么 | 谁设 |
|---|---|---|---|
| `_MULTIPLEX_ACTIVE` | `bool`（模块全局） | **这个进程是不是 multiplexer**（部署模式） | gateway 启动、`activate_multi_profile_hosting` |
| `_MULTIPLEX_CONTEXT` | `ContextVar[bool]` | **这个 task 是不是在服务别的 profile**（进程本身不是 multiplexer） | desktop cron ticker 这类场景 |
| `_SECRET_SCOPE` | `ContextVar[_BoundScope]` | 当前 task 的凭证映射 + 它属于哪个 home | 每个 turn / RPC / tick |

[`agent/secret_scope.py:32-38`](../agent/secret_scope.py:32) 对 `_MULTIPLEX_CONTEXT` 的解释：

> Context-local counterpart: a task serving a profile OTHER than the process's own, inside a
> process that is not a multiplexer as a whole — **the desktop backend's cron ticker firing a
> sibling profile's job**. Every isolation keyed on `is_multiplex_active()` (the routed-dotenv
> guard, `get_secret`'s fail-closed miss, subprocess scrubbing, passthrough) applies inside it
> while the process's own turns keep single-profile semantics.

举一个具体场景：桌面 app 的后端是一个**单 profile 进程**。它有一个 cron ticker，
要跑 `writer` profile 的定时任务。这时：

- 进程整体**不是** multiplexer（`_MULTIPLEX_ACTIVE` = False，因为它自己的 turn 要保持
  单 profile 语义：活的 `os.environ` 优先）；
- 但这个 ticker **这一次执行**在服务别人的 profile → 必须开所有隔离。

所以 `is_multiplex_active()`（`:78`）：

```python
def is_multiplex_active() -> bool:
    """True in a multiplexing process, or for a task running under multiplex semantics."""
    return _MULTIPLEX_ACTIVE or _MULTIPLEX_CONTEXT.get()
```

**一个 bool 回答两种语义。** 所有隔离判定都只查这一个函数。

### 7.3 `set_multiplex_active` 里的自动 pin（`#119242` 的解药）

[`agent/secret_scope.py:41`](../agent/secret_scope.py:41)：

```python
def set_multiplex_active(active: bool) -> None:
    global _MULTIPLEX_ACTIVE, _AUTO_PINNED_HOME
    from hermes_constants import (
        get_routing_process_hermes_home, pin_process_hermes_home, process_hermes_home_is_pinned,
    )
    _MULTIPLEX_ACTIVE = bool(active)
    if _MULTIPLEX_ACTIVE:
        if not process_hermes_home_is_pinned():
            _AUTO_PINNED_HOME = get_routing_process_hermes_home()
            pin_process_hermes_home(_AUTO_PINNED_HOME)
    elif _AUTO_PINNED_HOME is not None:
        if get_routing_process_hermes_home() == _AUTO_PINNED_HOME:
            pin_process_hermes_home(None)
        _AUTO_PINNED_HOME = None
```

**激活时**：如果宿主**已经** pin 了，就不抢（`process_hermes_home_is_pinned()`）；
否则自己 pin 住当前的 routing home，并记在 `_AUTO_PINNED_HOME` 里。

**停用时只释放自己创建的那个 pin**：

> Deactivation releases only the pin activation itself created — a transient toggle
> (`gateway_migrate._multiplex_read_mode`, a cron worker restoring the caller's mode) must not
> drop the host's explicit pin (#119242).

这是"**所有权**"模式的一个标准写法——**谁创建，谁释放；别释放不是你的。**
后半句 `if get_routing_process_hermes_home() == _AUTO_PINNED_HOME` 还额外防了
"别人在我们激活期间又 pin 了别的东西"的情况：那时不该清，因为当前 pin 已经不是我们的了。

### 7.4 `serves_routed_profile()` 的三条件

[`agent/secret_scope.py:93`](../agent/secret_scope.py:93)：

```python
def serves_routed_profile() -> bool:
    if is_multiplex_active():
        return True
    from hermes_constants import (
        get_hermes_home_override, get_routing_process_hermes_home, hermes_home_key)
    own = hermes_home_key(get_routing_process_hermes_home())
    bound = _SECRET_SCOPE.get()
    if bound is not None and bound.profile_home and hermes_home_key(bound.profile_home) != own:
        return True
    override = get_hermes_home_override()
    return override is not None and hermes_home_key(override) != own
```

三个条件任一成立即为 True：

1. **进程/task 在 multiplex 语义下**；
2. **装了一个"外来的" secret scope**——用 `_BoundScope.profile_home`（**provenance**）判定；
3. **HERMES_HOME override 指向外来 home**。

**条件 2 为什么要存在？** `_BoundScope` 的 docstring（`:83`）：

> An installed secret scope plus the home it was built for, when the binder declared one — **the
> provenance `serves_routed_profile` needs when the binding deliberately skips the HERMES_HOME
> override** (kanban spawn-env builds, MCP owner scopes).

有两个地方**故意不装 override**（因为它们只是"造一个子进程环境"，不是"在这个 task 里执行"），
但仍然需要让下游知道"这是别人的 profile"。所以它们用 `set_secret_scope(..., profile_home=...)`
打上 provenance。

**为什么用 `hermes_home_key()` 而不是直接比字符串？** 因为 Windows 大小写、symlink、
尾斜杠都会让"同一个目录"字符串不同。

### 7.5 `get_secret` 的完整分支（这是全篇最该背下来的函数）

[`agent/secret_scope.py:219`](../agent/secret_scope.py:219)：

```python
def get_secret(name: str, default: Optional[str] = None) -> Optional[str]:
    if _is_global_env(name):
        return _environ_or(name, default)
    bound = _SECRET_SCOPE.get()
    if bound is not None:
        val = bound.mapping.get(name)
        if val is not None:
            return val
        return default if serves_routed_profile() else _environ_or(name, default)
    if is_multiplex_active():
        raise UnscopedSecretError(...)
    return _environ_or(name, default)
```

画成表：

| 是不是全局变量 | 装了 scope | scope 命中 | multiplex active | 返回 |
|---|---|---|---|---|
| ✅ | — | — | — | `os.environ` / `default` |
| ❌ | ✅ | ✅ | — | scope 里的值 |
| ❌ | ✅ | ❌ | ✅（routed） | **`default`**（绝不读 `os.environ`） |
| ❌ | ✅ | ❌ | ❌（非 routed） | `os.environ` / `default` |
| ❌ | ❌ | — | ✅ | **抛 `UnscopedSecretError`** |
| ❌ | ❌ | — | ❌ | `os.environ` / `default` |

**第 3 行是最反直觉的一格。** 装了 scope 但 key 不在 scope 里，routed 时返回 `default`
（通常是 `None`），**不去 `os.environ` 找**。为什么？

> a leaked allowlist skips the allow-all check and silently rejects every secondary-profile
> sender (#86905)

也就是：如果 B 的 scope 里没有 `FEISHU_ALLOWED_USERS`，回退读环境变量就会读到 **A 的**
允许名单（因为 A 是启动 profile）。结果不是"多给了权限"，而是**B 的用户全被拒**。

**第 4 行说明 scope 是 `.env` 的 overlay，不是眼罩。** docstring：

> single-profile deployments inject credentials via the process env (systemd, `op run`), so the
> scope must stay a `.env` overlay, not a blindfold (otherwise cron 401s).

单 profile 场景下，凭证可能**只存在于进程环境**里（systemd `Environment=`、`op run`、
Compose），文件里没有。如果 scope 命中失败就返回 `None`，那些部署的 cron 会全部 401。

### 7.6 `UnscopedSecretError` 的文案是**为终端用户写的**

[`agent/secret_scope.py:115`](../agent/secret_scope.py:115)：

```python
class UnscopedSecretError(RuntimeError):
    """A secret was read in multiplex mode with no scope installed.

    The fix is to wrap the call path in ``set_secret_scope(...)`` (the per-turn / per-adapter
    profile scope), **not to widen the global allowlist**.

    ``str(exc)`` is the ONE sentence an end user can act on; the developer diagnosis
    (which secret, which doc) rides ``__notes__`` so tracebacks and logs keep it.
    """
```

`__init__` 传进去的是一句**用户能执行**的话：

```python
f"Hermes could not read {what} (an internal profile-scoping bug on the multiplexed "
"gateway, not your configuration). Run `hermes gateway restart`; if it keeps happening, "
"report it with `hermes debug share`."
```

三个设计点：

1. **明确说"不是你的配置问题"**——否则用户会去翻 `.env`、改 key，浪费一小时；
2. **给两个具体动作**（restart / debug share）；
3. **技术细节走 `add_note`**（Python 3.11 的 `__notes__`），这样 traceback 和日志里还在，
   但**不会**糊在用户脸上。

还有一个向后兼容的小把戏（`:129`）：

```python
# Older callers passed the whole developer sentence positionally
# (``UnscopedSecretError("get_secret('X') called with no scope ...")``); a secret
# name never contains whitespace, so treat such a string as the detail.
if secret_name and not developer_detail and any(ch.isspace() for ch in secret_name):
    secret_name, developer_detail = "", secret_name
```

**key 名永远不含空白**，所以"带空白的第一个参数"一定是老式的一声明。

### 7.7 全局白名单的哲学

[`agent/secret_scope.py:170-206`](../agent/secret_scope.py:170)：

```python
# Genuinely-global env vars: process/deployment settings, NOT profile secrets.
# They keep reading os.environ even in multiplex mode (routing them through the
# fail-closed path would wrongly crash). **Keep this tight — when in doubt a
# value is a profile secret.** Membership is exact name OR prefix.
```

名单分三类：

**（1）Hermes 运行时 / 部署**

```
HERMES_HOME, HERMES_PROFILE, HERMES_GATEWAY_LOCK_DIR,
HERMES_MAX_ITERATIONS, HERMES_API_TIMEOUT,
HERMES_REDACT_SECRETS, HERMES_NOUS_TIMEOUT_SECONDS, _HERMES_GATEWAY
```

**（2）OS / 解释器**

```
PATH, HOME, USER, LANG, LC_ALL, TZ, PWD, SHELL, TMPDIR,
VIRTUAL_ENV, PYTHONPATH, SSL_CERT_FILE
```

**（3）三类"看起来像 profile，其实不是"的**

```
# Kanban paths (per-board, not per-profile-secret)
HERMES_KANBAN_DB, HERMES_KANBAN_WORKSPACES_ROOT, HERMES_KANBAN_BOARD
```

```python
# API-server LISTENER settings — deployment config (compose/systemd env),
# which the scoped runner reload must keep seeing or containers silently
# lose the api_server platform. **API_SERVER_KEY is a credential: NOT here.**
# See #64674, #69379.
API_SERVER_ENABLED, API_SERVER_HOST, API_SERVER_PORT, API_SERVER_CORS_ORIGINS
```

```python
# Relay-connector ROUTING stamps injected by managed deploys. Every reader
# (gateway.config, relay_url()/registration/self-provision) must resolve
# the SAME value or the adapter registers while the platform is absent
# from config. **GATEWAY_RELAY_SECRET/_ID/_DELIVERY_KEY and IDP_* are auth
# material and deliberately stay profile-scoped.**
GATEWAY_RELAY_URL, GATEWAY_RELAY_ENDPOINT, GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS,
GATEWAY_RELAY_PLATFORMS, GATEWAY_RELAY_BOT_IDS, GATEWAY_RELAY_ROUTE_KEYS,
GATEWAY_RELAY_INSTANCE_ID, GATEWAY_RELAY_WAKE_URL, GATEWAY_RELAY_DISPLAY_NAME
```

三条"为什么不是 secret"的判据：

| 判据 | 例子 |
|---|---|
| **它是"往哪里连"，不是"用什么身份连"** | `GATEWAY_RELAY_URL` vs `GATEWAY_RELAY_SECRET` |
| **所有 profile 必须看到同一个值，否则行为不一致** | `API_SERVER_PORT`（端口只有一个） |
| **它是路径 / 板子标识，不是凭证** | `HERMES_KANBAN_DB` |

前缀名单：

```python
_GLOBAL_ENV_PREFIXES = (
    "HERMES_KANBAN_",
    "HERMES_TELEGRAM_",   # tuning knobs (batch delays, fallback toggles) — NOT the token
    "TERMINAL_",          # terminal/sandbox backend settings
)
```

注意 `HERMES_TELEGRAM_` 后面的注释——**"NOT the token"**。因为 token 叫
`TELEGRAM_BOT_TOKEN`（不带 `HERMES_` 前缀），不会误命中。

> **`TERMINAL_` 为什么在全局名单里，但终端策略又是 per-profile 的？**
> 因为 `get_secret` 里的 `TERMINAL_*` 只是**兜底**：真正的读取走
> `tools/terminal_scope.terminal_env()`，它在装了 scope 时**只看 scope**（见 §8）。
> 这里放进全局名单是为了"没装 scope 的代码路径不要炸"，不是为了给它们权威值。

### 7.8 `.env` 的唯一词法器

[`agent/secret_scope.py:350`](../agent/secret_scope.py:350) 的 `load_env_file`：

> **THE ``.env`` tokenizer**: every reader (profile scope, `hermes_cli.config.load_env`, the
> dashboard scrub, skill secret capture, managed .env, setup prompts) parses through here so
> **no two boundaries disagree on which keys/values a file defines**. Dict only — never touches
> `os.environ`.

为什么"唯一"这么重要？因为 `.env` 的语义有一堆边界情况：

| 情况 | 处理 |
|---|---|
| `export KEY=v` | 去掉 `export ` |
| `KEY="a b"` | 去引号 |
| `KEY="a\"b"` | 反转义 |
| `KEY='a\b'` | **单引号内不转义**（字面） |
| `KEY=v # comment` | 去掉注释（`#` 前必须有空白） |
| `KEY=v#nocomment` | **保留**（`#` 前没空白） |
| BOM | 剥掉（否则第一个 key 带 BOM，**永远匹配不到**） |
| 非法 UTF-8 | 退回 latin-1（与 `env_loader._load_dotenv_with_fallback` 一致） |

如果两个地方对 `KEY=v#x` 的理解不同，就会出现"写入时 strip 了、读取时没 strip"这类
**静默不一致**。

**缓存（`_ENV_FILE_CACHE`）的设计值得单独看**（`:298-312`）：

> **FRESHNESS**: every call still **OPENS** the file and keys on `utils.file_signature` of that
> descriptor's `fstat` (mtime_ns, size, inode, ctime_ns — **ctime can't be backdated, so a
> pinned-timestamp rewrite is still seen**), re-checked after the read. The open keeps
> **close-to-open revalidation on NFS**, a vanished/unreadable file **fails the open and is never
> cached** (a transient EACCES must not become "this profile has no secrets"), and the descriptor
> **pins one inode** so a symlink repointed mid-read can't file one file's contents under
> another's identity.

四个威胁，四个对策：

| 威胁 | 对策 |
|---|---|
| 文件被改写但 mtime 被伪造（`touch -d`） | 用 `ctime_ns`（**内核维护，不能回退**） |
| NFS 上客户端缓存过期 | **每次 open**（close-to-open 一致性） |
| 临时 `EACCES` 被缓存成"没凭证" | 打不开就**不缓存** |
| symlink 在读的过程中被重指 | 用**同一个 fd** 的两次 `fstat` 比对 |

最后一行代码还处理了"读的过程中文件被改写"：

```python
settled = file_signature(os.fstat(handle.fileno())) == fingerprint
...
if settled:
    _ENV_FILE_CACHE[key] = (fingerprint, dict(secrets))
```

**读到了新内容，但不按旧指纹存**——下次还会重读。

### 7.9 `build_profile_secret_scope` 的四层叠加

[`agent/secret_scope.py:390`](../agent/secret_scope.py:390)：

```python
secrets = load_env_file(Path(hermes_home) / ".env")           # ① profile 自己的 .env
external_secrets = get_secret_source_values(Path(hermes_home)) # ② 外部 secret 源
secrets.update(...)                                            #    （vault / 1Password / sh -c）
# ③ default profile 的 allow_all_users 桥接（只对 process home）
secrets.setdefault("GATEWAY_ALLOW_ALL_USERS", bridged)
# ④ 管理员托管的 .env，**最后、带 override**
secrets.update(load_managed_env())
```

**第 ③ 层的理由**（`:401-403`）：

```python
# The DEFAULT profile's config.yaml allow_all_users grant lives only in os.environ (bridged by
# gateway.config_loader); scoped gate readers under multiplex never fall to os.environ, so seed it
# into that profile's own mapping. A secondary never inherits it (#80099 class).
```

也就是：`allow_all_users` 是**从 config.yaml 桥接进 `os.environ`** 的，
而 multiplex 下的 scope 读取**不会**落到 `os.environ`。所以必须把它**显式塞进 default 的 scope**。
`_is_process_home()`（`:421`）保证只有 default 拿得到，次要 profile 不会继承。

**第 ④ 层的理由**（`:408-414`）：

```python
# Administrator-managed ``.env`` LAST, with override: the launch process applies it that way
# (``env_loader._apply_managed_env``) so **policy beats a user's own value**. Under multiplex
# semantics ``get_secret`` never reads ``os.environ`` on a scope miss, so a scope built from
# the profile files alone would drop a managed-only credential and **let the user's value win a
# managed-vs-user collision** (#111187 review). Every multiplex-authoritative scope — gateway
# turn, routed cron fire, external worker — is built here, so **managed authority is composed
# once, not restored by each consumer**.
```

一句话：**管理策略优先于用户自己的值**，而且这个"谁赢"的裁决只在**一处**做。

### 7.10 `refresh_installed_secret_scope`：scope 是冻结的，但要能补水

[`agent/secret_scope.py:432`](../agent/secret_scope.py:432)：

```python
def refresh_installed_secret_scope(hermes_home: Path) -> bool:
    """Fold a fresh build of *hermes_home*'s secrets into the INSTALLED scope, in place.

    A scope is frozen when installed, but a fire can learn of new values afterwards: **a routed
    cron fire's first agent build discovers plugin secret sources**, and under multiplex semantics
    the reload that follows is hydrate-only (never ``os.environ``), so nothing else would carry
    those values into the scope this fire already holds.
    """
```

关键实现细节：

```python
# REPLACE, don't merge: the rebuild is the profile's current truth, so a name a source has
# stopped supplying (rotated, revoked, source removed) must disappear from the fire's scope
# rather than survive as the stale value dict.update() would keep.
rebuilt = build_profile_secret_scope(hermes_home)
scope.update(rebuilt)
for name in [n for n in scope if n not in rebuilt]:
    scope.pop(name, None)
```

两件事：

1. **先 update，再删旧的**——顺序保证并发读者**永远看不到"被清空的 scope"**；
2. **用 replace 语义，不是 merge 语义**——否则**被撤销的凭证**会作为 stale 值一直活着。
   这是一个安全属性：撤销必须真的撤销。

---

## 8. 终端作用域（`TERMINAL_*`）

这一节旧版没有，但它是"半绑定"的另一半，不讲就讲不透。

### 8.1 为什么 `TERMINAL_*` 也要作用域

[`tools/terminal_scope.py:1-9`](../tools/terminal_scope.py:1)：

> Multiplexed surfaces (gateway, dashboard/TUI, cron) serve several profiles from one process;
> **mirroring terminal settings into `os.environ` let the first profile pin its backend onto
> everyone else (sandbox escape)**.

具体事故形状（`#68559` + `hermes_cli/env_loader.py:792` 的 docstring）：

1. A 的 turn 把 `TERMINAL_ENV=ssh` + `TERMINAL_SSH_HOST=...` 桥接进 `os.environ`；
2. B 的 turn 把 `TERMINAL_ENV=local` 桥接进去，但**没有**碰 `TERMINAL_SSH_*`；
3. 现在环境里是 `TERMINAL_ENV=local` + 一堆残留的 `TERMINAL_SSH_*`；
4. 或者反过来：B 想本地跑，结果**用了 A 的 SSH 主机** → **在别人的机器上执行命令**。

`sandbox escape` 这个词不是夸张——如果 A 的终端是 docker 容器、B 是 local，
B 的命令就会在**宿主机**上跑，而用户以为在沙箱里。

### 8.2 三个状态

```python
# None = no scope bound (process-env behavior); dict = complete policy; Refusal = resolution failed.
_terminal_scope_var: ContextVar = ContextVar("hermes_terminal_scope", default=None)
```

`terminal_env(name, default)`（`:75`）的语义：

```python
scope = _terminal_scope_var.get()
if scope is None:
    return os.environ.get(name, default)     # 没 scope：老行为
enforce_no_refusal()                          # refusal：抛
value = scope.get(name)
return default if value is None else str(value)   # 有 scope：**只看 scope**
```

**「有 scope 时缺失的 key 返回 `default`，绝不回退 `os.environ`」**——和 `get_secret` 的
第 3 格完全同构。这就是整个模块的共同形状。

### 8.3 为什么是"全量投影"

`build_profile_terminal_scope`（`:89`）的 docstring：

> Projection: `DEFAULT_CONFIG['terminal']` ← profile `.env` TERMINAL_* ← *env_overlay*
> ← profile `config.yaml` `terminal:`. **Total by construction, so a bound scope never widens
> back to ambient authority.**

"Total（全量）"是关键词：scope 里必须**包含每一个 `TERMINAL_*` 的最终值**，
包括"用户没设、用默认值"的那些。否则 `scope.get(name)` 返回 `None`——如果代码把它当成
"用环境变量"，就又漏了。

所以 `_TOOL_LEVEL_DEFAULTS`（`:27`）补齐那些默认值住在 `terminal_tool.py` 而不是
`DEFAULT_CONFIG` 里的键：

```python
_TOOL_LEVEL_DEFAULTS: dict[str, Any] = {
    "cwd": ".", "ssh_host": "", "ssh_user": "", "ssh_port": 22, "ssh_key": "",
    "docker_orphan_reaper": True, "docker_persist_across_processes": True,
    "sandbox_dir": "", "lifetime_seconds": 300, "docker_shared_container_key": "",
    "home_mode": "auto",
}
```

### 8.4 refusal scope

[`tools/terminal_scope.py:39`](../tools/terminal_scope.py:39)：

```python
class TerminalPolicyRefusal(dict[str, str]):
    """Marker scope (empty dict subclass) installed when policy resolution failed."""
```

`install_profile_terminal_scope`（`:196`）**永不抛异常**：

```python
try:
    return set_terminal_scope(build_profile_terminal_scope(hermes_home, env_overlay=env_overlay))
except TerminalPolicyUnavailable as exc:
    logger.warning("terminal policy unavailable: %s", exc)
    return _terminal_scope_var.set(TerminalPolicyRefusal(str(exc)))
```

为什么"构建失败"要变成"装一个拒绝标记"而不是"抛"？因为**构建**发生在 turn 开始，
而**使用**发生在真正执行命令时。如果构建就抛，整个 turn 失败；装 refusal 则让 turn 正常跑，
只在**真要执行终端命令时**抛 `TerminalPolicyUnavailable`。

执行路径（`terminal_tool`、`execute_code`）在 spawn 前调 `enforce_no_refusal()`：

> under a refusal scope the profile's terminal policy could not be resolved, and running with the
> launch process's ambient policy is **exactly the authority leak this module closes**
> (#68559 requires refusal, not fallback).

`target_home` 的"半绑定"在这里又一次出现：`config.yaml` 存在但**解析不了**时必须 fail closed，
所以 `build_profile_terminal_scope` **直接读文件**而不是 `read_raw_config()`
（后者把"缺失"和"解析失败"都变成 `{}`）。

### 8.5 `TERMINAL_CWD` 的占位符解析

[`tools/terminal_scope.py:174`](../tools/terminal_scope.py:174) 的
`_resolve_scope_cwd_placeholder` 解决一个很隐蔽的问题：

> Without it a routed turn's `resolve_agent_cwd()` falls back to **the multiplexer PROCESS cwd
> (wherever `hermes gateway` was launched)**, so the system prompt, context-file discovery and the
> local terminal all run in a directory the profile's standalone gateway would never have used.

也就是：`terminal.cwd` 没显式设时，**standalone gateway** 会在 import 时算出一个
（local 后端 → `$HOME`；docker + workspace mount → 宿主机 cwd；其他 → 不设），
而 multiplex 下的 scope 是**新构建的**，没有这个历史 → 只能落到进程 cwd。

结果是：**同一个 profile，standalone 跑和 multiplex 跑，工作目录不一样。**
系统提示里的目录、`AGENTS.md` 的发现、本地终端的 cwd 全都偏了。

---

## 9. 作用域绑定缝（binding seams）

### 9.1 turn 内：`_profile_runtime_scope`

[`gateway/run.py:1788`](../gateway/run.py:1788)：

```python
@_contextmanager
def _profile_runtime_scope(
    profile_home: Path, prepared_secret_scope: Optional[dict] = None, *,
    hydrate_secrets: bool = True):
    """Scope config/skills/memory AND credentials to a profile for one turn (multiplexed path only).
    ``set_hermes_home_override`` is a contextvar (reaches the agent worker via ``copy_context()``);
    ``set_secret_scope`` makes the profile ``.env`` the credential source **without mutating
    ``os.environ``**, so subprocesses never inherit cross-profile secrets."""
```

结构（顺序很重要）：

```
home_token     = set_hermes_home_override(str(profile_home))
secret_token   = set_secret_scope(secrets, profile_home=str(profile_home))   # ← 带 provenance
with install_and_reset_profile_terminal_scope(Path(profile_home)):
    yield
# finally: 先 reset secret，再 reset home
```

注意 `set_secret_scope(..., profile_home=...)`——**这里是外来的 home，必须打 provenance**，
因为如果 `_MULTIPLEX_ACTIVE` 意外为 False（比如某些测试场景），
`serves_routed_profile()` 还能靠这个标记认出"这是别人的 profile"。

`_async_profile_runtime_scope`（`:1824`）只是把 secret 文件的加载挪到线程池：

```python
secrets = await asyncio.to_thread(_load_profile_secret_scope, Path(profile_home))
```

> **为什么不能直接在事件循环里读？** 因为 `_load_profile_secret_scope` 可能触发
> `hydrate_profile_secret_sources`——那是一个**子进程**（`op run`、`bws`、`sh -c`），
> 有 30s 预算并持有进程级锁。在事件循环里等它 = 整个 gateway 卡住。

### 9.2 turn 内：`_standalone_launch_scope`（`#112878`）

这是最容易漏的一条。场景：**gateway 是 standalone 的**（`multiplex_profiles` 关），
但进程里跑了一个 **native hosted room**，它服务第二个 profile，于是调了
`activate_multi_profile_hosting()` → `set_multiplex_active(True)`。

现在：

- **standalone gateway 自己的普通 turn 以前是"没有 scope"的**（因为 flag 是关的）；
- 但 `get_secret` 现在 fail closed；
- 于是**gateway 自己的 turn 也开始抛 `UnscopedSecretError`**。

解法（[`gateway/run_turn.py:2310`](../gateway/run_turn.py:2310)）：

```python
@staticmethod
def _standalone_launch_scope():
    """Scope for a standalone gateway's own (launch-profile) work: a no-op until the process hosts
    another profile home, then the launch profile's OWN runtime scope."""
    from tui_gateway.launch_profile_policy import launch_profile_scope_if_multiplexed
    return launch_profile_scope_if_multiplexed()
```

而 `launch_profile_scope_if_multiplexed`（[`tui_gateway/launch_profile_policy.py:184`](../tui_gateway/launch_profile_policy.py:184)）：

```python
if not is_multiplex_active():
    return contextlib.nullcontext()
from hermes_constants import get_process_hermes_home
return launch_profile_runtime_scope(get_process_hermes_home())
```

**单 profile 时返回 `nullcontext()`**——字节级不变，`gateway/AGENTS.md` 里那句
"callers assert the returned object is literally a `nullcontext`"就是在守这个性质。

**为什么要 assert 字面量？** 因为如果哪天有人"顺手"改成别的 no-op 对象，
单 profile 行为就变了，而且**测试测不出来**（行为相同但对象不同）。

### 9.3 启动 profile 的 secret scope 优先级（反直觉的一格）

[`tui_gateway/launch_profile_policy.py:129`](../tui_gateway/launch_profile_policy.py:129)：

```python
def launch_secret_scope(launch_home: str | Path) -> dict[str, str]:
    """... 

    PRECEDENCE, and it is not the process's: ``<launch home>/.env`` (plus hydrated external
    sources) **WINS over the env**. For a key present in both, an unscoped read returned the
    ambient ``os.environ`` value before activation and returns the ``.env`` value after — so
    **activation is not purely "stricter" for the launch tenant, it also changes which of the
    launch profile's own two values it sees.** Env-only keys (systemd ``Environment=``,
    ``op run``, Compose) are unaffected: nothing in the files shadows them.
    """
    scope = {k: v for k, v in _launch_env().items() if not _is_global_env(k)}
    scope.update(build_profile_secret_scope(Path(launch_home)))
    return scope
```

也就是说：**`.env` 覆盖环境变量**（`update` 在后）。

| 场景 | 激活前 | 激活后 |
|---|---|---|
| key 只在 `os.environ`（systemd / `op run`） | 环境变量值 | 环境变量值（文件里有不了） |
| key 只在 `.env` | 环境变量里没有 → `None`？ | `.env` 值 |
| key **两边都有** | **环境变量值** | **`.env` 值** ← 变了！ |
| key 两边都没有 | `None` | `None` |

第 3 行是那一句"activation is not purely stricter"。所以**不要**假设"打开 multiplex
之后启动 profile 的凭证完全不变"——如果一个 key 同时在 `.env` 和 systemd 里，
**gateway 重启前后读到的值不同**。

### 9.4 启动 env 的冻结时机

[`tui_gateway/launch_profile_policy.py:33`](../tui_gateway/launch_profile_policy.py:33)：

```python
def capture_launch_env() -> dict[str, str]:
    """Freeze the process env as the launch profile's own; the first capture wins.

    Called at activation, immediately **before the first secondary home is registered as
    served — the last moment ambient env is provably the launch profile's**.
    """
    global _snapshot
    with _lock:
        if _snapshot is None:
            _snapshot = dict(os.environ)
        return dict(_snapshot)
```

**"first capture wins"** 是关键：后续 `os.environ` 被污染了也不影响这份快照。

而 `_launch_env()`（`:112`）区分两种时机：

```python
def _launch_env() -> dict[str, str]:
    """The launch profile's env: frozen once multiplexing is active; **the LIVE process env
    before** (no secondary has run yet, so it is provably the launch profile's, and freezing it
    early would miss values the launch process still bridges at startup)."""
    from agent.secret_scope import is_multiplex_active
    return capture_launch_env() if is_multiplex_active() else dict(os.environ)
```

为什么激活前用 live？因为启动过程还在往里桥接值（`gateway.config_loader` 会桥
`GATEWAY_ALLOW_ALL_USERS`、`TERMINAL_*` 等）。**提前冻结 = 漏掉这些桥接值。**

### 9.5 eager 激活（`activate_multi_profile_hosting_eagerly`）

[`tui_gateway/launch_profile_policy.py:71`](../tui_gateway/launch_profile_policy.py:71)。
旧行为是**懒激活**（第一次收到 `?profile=B` 请求才激活），有三个问题：

```python
# Activation used to be lazy and one-way — it fired the first time a *request* asked for a second
# home. Everything the host had already done by then (idle-reaper ticks, cron start, adapter
# connects, MCP discovery) ran under single-profile assumptions and is never re-scoped, and the
# launch profile's env had already been mutated by then, so ``capture_launch_env`` froze a
# polluted snapshot.
```

三个问题：

1. **已经做过的事不会被重做**（idle-reaper flush、cron 启动、adapter connect、MCP 发现
   都按单 profile 假设跑过了）；
2. **冻结的快照已被污染**（某个次要请求可能已经改过 `os.environ`）；
3. **懒激活太晚**——错误已经写进磁盘了。

所以：

> One `hermes serve` / `hermes gateway run` per host means the process knows at boot whether it
> can be asked for a second home: **decide there, once. Call it as the LAST boot step.**

**为什么必须是"最后一步"？**

> the frozen snapshot is the only source for launch keys with no `.env` to rebuild from, so
> **every credential the boot still injects must already be in `os.environ`.**

也就是：boot 过程中还有若干步骤会往环境里注入凭证（keychain 解锁、`op run` 预取、
managed `.env` 应用……）。如果你在它们之前冻结，那些 key **在这个进程的余生里都不存在了**。

**为什么故意不读 `gateway.multiplex_profiles: false`？**

```python
# ``gateway.multiplex_profiles: false`` is deliberately NOT consulted: it is retired as a
# topology opt-out, and a multi-home host that skipped activation because of a stale ``false``
# would **serve a second profile with the LAUNCH profile's credentials** — the exact fail-open
# this guard exists to prevent.
```

这是"退役"这件事**为什么安全**的最终答案：如果还尊重 `false`，那么一个写死 `false` 的
宿主机在服务第二个 profile 时，所有 fail-closed 守卫都是**关着的**。

**一个可读性很强的细节**：`_servable_profile_homes()`（`:54`）在枚举失败时 fail closed：

```python
except Exception:
    logger.warning(
        "Could not enumerate this host's profile homes; activating multi-profile hosting "
        "fail-closed (unscoped credential reads will raise instead of borrowing the launch "
        "profile's)", exc_info=True)
    activate_multi_profile_hosting()
    return True
```

> An unreadable profiles directory fails CLOSED: **we cannot prove the host is single-profile**,
> and the lazy backstop only fires once a request has already been answered.

---

## 10. 线程与子进程

### 10.1 后台线程：`copy_context()`

`ContextVar` **不会**自动传播到 `threading.Thread`。所以：

[`agent/memory_provider.py:29`](../agent/memory_provider.py:29)：

```python
def spawn_context_thread(target: Callable[..., Any], *, name: str, daemon: bool = True,
                         args: tuple = (), kwargs: Optional[dict[str, Any]] = None) -> threading.Thread:
    """Unstarted thread running *target* under the spawner's contextvars (see :func:`ctx_bound`).
    **Every memory-provider background job (prefetch, sync, writer loops) must go through this.**"""
    return threading.Thread(target=ctx_bound(target), args=args, kwargs=kwargs, name=name, daemon=daemon)
```

`ctx_bound` 的实现就是一行：

```python
ctx = contextvars.copy_context()
return lambda *args, **kwargs: ctx.run(fn, *args, **kwargs)
```

**`copy_context()` 是快照。** 之后父上下文再改，子线程看不到；反之亦然。
这正是我们要的：**后台任务看到的是"派发那一刻"的 profile。**

`title_generator.py` 是标准范例（`tui_gateway/AGENTS.md` 里点名了它）。

### 10.2 子进程：`served_profile_child_env`

[`tools/environments/local.py:386`](../tools/environments/local.py:386)。这个函数参数不多，
但每个分支都有理由：

```python
def served_profile_child_env(
    base: Mapping[str, str] | None = None, *, target_home: str | Path | None = None,
    inherit_credentials: bool = False,
) -> dict[str, str]:
```

执行顺序：

```
1. env = dict(base) 或 hermes_subprocess_env(inherit_credentials=...)
2. target = target_home or get_hermes_home_override() or ""
3. 若 target:
     env["HERMES_HOME"] = target
     apply_scratch_tmp_env(env)         # TMPDIR 跟着被服务的 home 走，像 HOME 一样
     若 _is_routed_home(target):
         strip_launch_profile_env(env, target)   # 删掉启动 profile 的残渣
         _scrub_credentials(env, inherit_credentials=False)  # 洗掉所有凭证
4. 若 inherit_credentials:
     若 target:  secrets = build_profile_secret_scope(Path(target))
     否则:       secrets = current_secret_scope()
                 若 None 且 multiplex → **抛 UnscopedSecretError**
     env.update(secrets)
```

**第 3 步为什么"无差别洗凭证"？** docstring：

> a key systemd / Compose / the shell injected into the launch process **was never recorded in
> `.env` or a source snapshot**, so a **name-based strip cannot see it** and the target overlay
> cannot remove it.

也就是：基于名字的剥离（"删掉启动 `.env` 里的所有 key"）**看不见**那些
"从父进程环境继承来、从来没经过 `.env` 的"凭证。所以必须先**按类别全洗**，
再按需加回。

**第 4 步的 `UnscopedSecretError`** 是关键的设计选择：

```python
raise UnscopedSecretError(
    "", "served_profile_child_env(inherit_credentials=True) called with no target home and "
    "no profile secret scope bound while multiplexing is on; the child would inherit the "
    "launch profile's credentials. Bind the profile scope (or pass target_home) at the spawn site.")
```

**"minting with the launch environ would sign in as the wrong profile."**
比如 `hermes -p X auth add`——如果拿启动 profile 的凭证去签字，**给错误的人开了授权**。

### 10.3 `strip_launch_profile_env` 的残渣名单

[`tools/environments/local.py:458`](../tools/environments/local.py:458)：

```python
residue_names = {
    key.upper() for key in
    set(load_env_file(launch_home / ".env"))       # ① 启动 .env 现在的 key
    | set(launch_dotenv_keys())                     # ② 本进程**曾经**加载过的所有 dotenv key
    | set(TERMINAL_CONFIG_ENV_MAP.values())         # ③ 所有可能的 TERMINAL_* 桥接名
    | set(source_supplied_names())                  # ④ 外部 secret 源曾提供过的名字
    if not _is_global_env(key.upper()) or key.upper().startswith("TERMINAL_")} - managed_names
```

四个来源，各自堵一个洞：

| 来源 | 堵的洞 |
|---|---|
| ① 当前 `.env` | 正常情况 |
| ② `launch_dotenv_keys()` | **boot 后从 `.env` 里删掉/改名的 key**，`os.environ` 里还留着旧值，而重解析文件已经看不见它了（`#107695`） |
| ③ `TERMINAL_CONFIG_ENV_MAP.values()` | `TERMINAL_*` **不是从 `.env` 来的**，是从 `config.yaml` 桥接来的；不列出来就漏 |
| ④ `source_supplied_names()` | 外部源（vault、1Password）写进 `os.environ` 的名字；**"launch 的源提供过的名字不是目标 profile 该看到的"** |

减去 `managed_names`：

> The administrator-managed `.env` is **NOT residue**: its values are policy for every profile
> (`_apply_managed_env` applies it last, with override, so it beats the user's own `.env`) — leave
> them in place.

`or key.upper().startswith("TERMINAL_")` 这个例外也值得看：`TERMINAL_*` 在
`_is_global_env` 里是**全局**的，但这里要**特别保留在残渣集合里**——因为它们虽然是全局名，
但**值是 per-profile 的**（见 §8.1）。

最后还有一行（`:499`）：

```python
# Authorization gates are the one residue a name list cannot see: a unit-file ``Environment=``
# or an operator export never appears in the launch ``.env``, the secret scrub ignores
# non-credentials, and the target's own ``.env`` rarely defines the key to overwrite it (#113270).
return strip_profile_gate_env(env)
```

**授权闸门**（`*_ALLOWED_USERS`、`*_ALLOW_ALL_USERS`、`group_policy`、`allow_bots`）
是名字清单**看不到**的残渣，因为：

- 它可能来自 systemd unit 的 `Environment=` → 不在 `.env` 里；
- 它**不是凭证** → `_scrub_credentials` 不会删；
- 目标 profile 的 `.env` 里**通常不写**这些 key → 不会被覆盖。

后果：**次要 profile 用启动 profile 的允许名单判授权** → 要么放进了不该放的人，
要么（更常见）**拒绝了所有合法用户**（`#86905`）。

### 10.4 `contextvars` 不跨进程边界

这是最容易忘的一条。`ContextVar` 是**同一个进程内**的执行上下文概念：

- `subprocess.Popen(env=...)` 只接受**字符串字典**；
- 你不能"把 contextvar 传过去"；
- 所以**必须在 spawn 之前把值解析成字典**。

`served_profile_child_env` 就是那个解析点。

### 10.5 `HF_` 的教训：不要用 `dict(os.environ)`

反例：

```python
env = dict(os.environ)          # ← 钉住启动 profile
env["HERMES_HOME"] = target
```

看起来"我改了 HERMES_HOME 呀"。但：

- `OPENAI_API_KEY` 还是启动 profile 的；
- `TERMINAL_ENV` 还是启动 profile 的；
- `FEISHU_ALLOWED_USERS` 还是启动 profile 的；
- 所有 `HERMES_*` 调优也是启动 profile 的。

**改了 home 只改了"路径解析"，没改"凭证与策略"。** 这就是 `hermes_cli/AGENTS.md`
里说的**半绑定**：

> **A method that sets only `get_hermes_home_override()` is half-bound**: config paths resolve to
> the right profile while credentials and `TERMINAL_*` policy still come from the launch profile.

---

## 11. Profile 的创建、克隆与删除

### 11.1 原子发布：staging + rename

[`hermes_cli/profiles.py:1378`](../hermes_cli/profiles.py:1378) 的 `create_profile`：

```python
# Build in a hidden sibling and publish with one rename: a running multiplexer rescans profiles/
# on every create and every 30 s, and ``_iter_named_profile_dirs`` only lists valid ids (no leading
# dot), so it can never adopt the half-copied tree and start adapters on credentials the strip
# below has not removed yet.
staging = _clone_staging_dir(profile_dir)
try:
    if clone_all and source_dir:
        _clone_all_into(source_dir, staging, canon)
    else:
        _bootstrap_profile_dir(staging, source_dir, sync_imports=sync_imports)
    ...
    if source_dir is not None and not clone_channels:
        stripped = strip_channel_settings(staging, include_state=clone_all, source_dir=source_dir)
    _finish_profile_layout(staging, no_skills=no_skills, clone_all=clone_all, description=description)
    os.rename(staging, profile_dir)
except BaseException:
    shutil.rmtree(staging, ignore_errors=True)
    raise
```

`_clone_staging_dir`（`:1464`）：

```python
staging = profile_dir.parent / f".{profile_dir.name}.staging-{os.getpid()}"
```

两个性质：

1. **以 `.` 开头** → `_iter_named_profile_dirs` 的 `_PROFILE_ID_RE.match(entry.name)` 不匹配
   （正则要求首字符是 `[a-z0-9]`）→ **隐形的**；
2. **在同一个父目录下** → 同一个文件系统 → `os.rename` 是**原子**的（不会 `EXDEV`）。

**为什么这段注释里提到 "start adapters on credentials the strip below has not removed yet"？**
这是最严重的一种竞态：

1. clone 从 default 复制了一份 `.env`（**含 Telegram bot token**）；
2. 一个正在运行的 multiplexer **每 30s 扫一次** `profiles/`；
3. 如果它在中途看到了这个目录 → **启动一个 adapter，用同一个 bot token 去 polling**；
4. 两个进程抢同一个 bot → Telegram 侧随机分发消息 → **消息丢一半**；
5. 然后 strip 才把 token 删掉（但 adapter 已经在跑了）。

staging 目录以 `.` 开头，让第 3 步**不可能发生**。

### 11.2 symlink 必须先实体化

[`hermes_cli/profiles.py:1216`](../hermes_cli/profiles.py:1216)：

```python
# Files a clone edits in place after copying. A ``--clone-all`` copy preserves symlinks
# (``symlinks=True``), so a symlinked source ``.env`` would otherwise be edited **THROUGH the link**
# and the channel stripping would mutate the SOURCE profile. These are materialized as real files first.
_CLONE_MATERIALIZE = (".env", "config.yaml", "auth.json", "SOUL.md")
```

`_materialize_symlinked_files`（`:1222`）做的事：把 symlink 换成真实副本（悬空链接则丢弃）。

**如果不做**：用户的 `~/.hermes/.env` 是指向 `~/secrets/hermes.env` 的 symlink，
clone 出来之后 strip 通道设置，会**直接改掉源文件** → **生产 gateway 的 token 被删了**。

同一个坑还有 Windows 的 NTFS junction（`:1238` 的 `_junction_target` +
`:1255` 的 `_copytree_keep_junctions`）：

> `shutil.copytree(symlinks=True)` that re-creates NTFS junctions as junctions instead of
> traversing them. A `skills/foo` junction into a `skills.external_dirs` root copied as a physical
> tree is **a second same-named candidate** and `_locate_skill` refuses to guess (#113471).

### 11.3 `--clone-all` 排除什么

三个集合，各有理由：

**（1）任何源都排除：历史与会重复执行的东西**

[`hermes_cli/profiles.py:85`](../hermes_cli/profiles.py:85)：

```python
_CLONE_ALL_HISTORY_EXCLUDE_ROOT: frozenset[str] = frozenset({
    "state.db", "state.db-wal", "state.db-shm", "sessions", "backups", "state-snapshots", "checkpoints",
    "cron",
})
```

`cron` 的理由最狠：

```python
# ``cron`` is scheduled work bound to the source profile and its origin channel: a clone
# that inherits jobs.json runs every job twice (two gateways, same job ids, double spend,
# duplicate deliveries) the moment its gateway starts.
```

**双倍花钱 + 双倍投递**，而且 job id 相同 → 去重机制也失效。

**（2）只在源是 default 时排除：基础设施**

```python
_CLONE_ALL_DEFAULT_EXCLUDE_ROOT = frozenset({
    "hermes-agent", ".worktrees", "profiles", "bin", "node_modules",
    ".hermes-runtime", "node",
}) | LOCAL_RUNTIME_ROOT_DIRS
```

`LOCAL_RUNTIME_ROOT_DIRS` = `{"models", "runtimes", "node"}`（[`hermes_constants.py:209`](../hermes_constants.py:209)）。

理由（注释）：GGUF 权重几十 GB、llama.cpp 运行时二进制、托管 Node——**都能按需重下**，
而且**只从 default 根解析**。

**为什么"只在源是 default 时"排除？** 注释说得很清楚：

> Named profiles never hold these at root, so the gate avoids silently dropping user data from a
> named-profile source.

也就是：如果一个**命名** profile 的根下**碰巧**有个叫 `node/` 的目录（比如用户存了自己的
node 项目），**不能**当基础设施删掉。

**（3）always 排除的运行时身份**

[`hermes_cli/profiles.py:44`](../hermes_cli/profiles.py:44)：

```python
_CLONE_ALL_STRIP: list[str] = [
    "gateway.pid", "gateway_state.json", "processes.json",
    "bot-desktop/launcher.pid", "bot-desktop/env", "bot-desktop/rfb.sock",
    "bot-desktop/lease.json", "bot-desktop/lease.lock",
    "bot-desktop/browser-profile/DevToolsActivePort",
    "bot-desktop/browser-profile/SingletonLock",
    "bot-desktop/browser-profile/SingletonCookie",
    "bot-desktop/browser-profile/SingletonSocket",
]
```

注释里那句话值得抄：

> Copied verbatim, `screen stop` on the clone would kill **the source's X server**. Browser user
> data stays, but Chromium's process markers must not let the clone attach to the source's
> **live browser**.

也就是：

- `bot-desktop/launcher.pid` 里是**源**的 pid + 启动时间 → clone 执行 `screen stop`
  会去**杀源的进程**；
- Chromium 的 `SingletonLock` / `SingularCookie` / `DevToolsActivePort` 指向**源**的浏览器实例 →
  clone 会连到**源的活浏览器**（同一个用户 profile，cookie 全共享）。

第 4 个文件 `SingletonSocket` 是 Chromium 的 socket，连上去就能**控制源的浏览器**。

### 11.4 通道剥离：按**所有权**判定

[`hermes_cli/profile_channels.py`](../hermes_cli/profile_channels.py) 是这块的权威。核心思想：

> 不要手写 `TELEGRAM_BOT_TOKEN` 清单。去**插件注册表**问"这个平台的凭证 key 有哪些"。

`strip_channel_settings`（`:412`）：

```python
def strip_channel_settings(profile_dir: Path, *, include_state: bool, source_dir: Optional[Path] = None) -> dict[str, list[str]]:
    """Strip channel credentials/identity from a freshly cloned profile, judged in ``source_dir``'s
    plugin scope. ``include_state`` also drops the runtime state ``--clone-all`` copied."""
    index = ChannelKeyIndex(source_dir)
    stripped = dict(strip_channel_env_file(profile_dir / ".env", index))
    config_paths = strip_channel_config(profile_dir / "config.yaml", index)
    if include_state:
        for entry in channel_state_entries(profile_dir, index):
            _remove_entry(entry)
    return stripped
```

四类要剥的东西：

| 类别 | 例子 | 在哪 |
|---|---|---|
| **凭证 key** | `TELEGRAM_BOT_TOKEN`、`SLACK_BOT_TOKEN` | `.env` |
| **授权策略** | `TELEGRAM_ALLOWED_USERS`、`GATEWAY_ALLOW_ALL_USERS` | `.env` / config |
| **平台配置段** | `platforms.telegram.*` | `config.yaml` |
| **运行时配对状态** | WhatsApp session、Matrix store、pairing | 目录 |

**为什么必须在"源的插件作用域"里评估？**

[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md)：

> channels (`profile_channels.py`: ownership-based inventory evaluated in **the SOURCE's plugin
> scope** — adapter-declared keys + canonical/alias prefixes + `GATEWAY_ALLOW*`/`GATEWAY_RELAY_*`;
> prefixes **shared with tools** (`TWILIO_`/`EMAIL_`, plus a plugin platform's
> `shared_env_prefixes`) are stripped **only when the source runs that adapter**; never a hand
> list; a platform that left core keeps its ownership from its `LEFT_CORE` row while the plugin is
> absent).

三个层次：

1. **adapter 声明的 key** + **canonical/alias 前缀**（`TELEGRAM_` / `TG_`）
   + `GATEWAY_ALLOW*` / `GATEWAY_RELAY_*`；
2. **与工具共享的前缀**（`TWILIO_` 既可能是消息通道也可能是语音工具；`EMAIL_` 同理）
   → **只有当源真的运行了那个 adapter 时**才剥。否则会把用户给 `twilio` 工具配的
   `TWILIO_ACCOUNT_SID` 一起删掉；
3. **已经离开 core 变成插件的平台** → 靠 `LEFT_CORE` 记录继续认领所有权，
   即使那个插件现在没装。

### 11.5 `--clone-channels` 的拒绝

默认行为是**剥掉**通道。想复制得显式 `--clone-channels`，而且它在一种情况下**被拒**：

[`hermes_cli/profile_channels.py:458`](../hermes_cli/profile_channels.py:458)：

```python
def clone_channels_refusal(source_dir: Path, source_label: str) -> Optional[str]:
    """Why ``--clone-channels`` must be refused for ``source_dir``: a live multiplexer already serves
    the source, so the copied bot would be **parked as a duplicate credential at once** (the same
    finding the migrate preflight reports)."""
    served = recorded_served_profiles()
    if not served or len(served) < 2 or normalize_profile_name(source_label) not in {...}:
        return None
    platforms = channel_platforms_configured(source_dir)
    if not platforms:
        return None
    return (
        f"--clone-channels would copy {', '.join(platforms)} from '{source_label}', which the running "
        "multiplexed gateway already serves: the bot can only belong to one profile, so the copy would be "
        "parked as a duplicate credential. ..."
    )
```

判定四步：

1. 有活着的 multiplexer 吗？
2. 它服务**≥2** 个 profile 吗？（单 profile 不需要管）
3. 源 profile 在它的服务集里吗？
4. 源**真的配了**通道吗？

四条全中才拒。

这个拒绝**放在 `create_profile` 里**，所以 CLI、REST、TUI 三条入口**自动一致**
（[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md)：`its live-multiplexer refusal lives in
create_profile (CLI, REST and TUI all go through it)`）。

### 11.6 删除：tombstone 先于删除？

`delete_profile`（[`hermes_cli/profiles.py:1826`](../hermes_cli/profiles.py:1826)）的步骤
（按注释与调用推断）：

1. **停掉这个 profile 的后端**（`_stop_profile_backends`、`_stop_gateway_process`、
   `_stop_bot_desktop`）；
2. **清理服务注册**（`_cleanup_gateway_service`，s6 / systemd / launchd）；
3. **写 tombstone**；
4. **`rmtree`**（`_rmtree_with_retry` + `_rmtree_make_writable`，处理 Windows 只读文件）；
5. **purge 身份**（`_purge_identity` → `profile_identity.purge_profile_identity`）；
6. **删 wrapper 脚本**。

`_purge_identity` 的返回值和语义（`:1516`）：

```python
def _purge_identity(canon: str) -> bool:
    """Settle a deleted profile's durable identity (``profile_identity.purge_profile_identity``).

    False means the filesystem delete happened but the identity settlement did not — the caller
    reports that as a **pending settlement** rather than a clean success."""
```

**"pending settlement"** 这个概念很重要：有些清理是**跨存储**的（比如 Honcho 侧的
profile 记录、授权侧的身份），它是**可失败**的。失败时的正确做法不是"报错回滚"
（文件已经删了，回滚不了），而是**如实报告"部分完成"**。

### 11.7 改名的重定向

`rename_profile`（`:2437`）之后会调 `_retarget_active_profile`（`:2092`）：

```python
def _retarget_active_profile(old: str, new: str, message: str) -> None:
    """If the sticky active profile is *old*, point it at *new* and print *message*. Never raises."""
    with contextlib.suppress(Exception):
        if get_active_profile() == old:
            set_active_profile(new)
            print(message)
```

**为什么要重定向？** 因为 `active_profile` 文件里存的是**名字**，不是路径。
如果不改，用户下次裸跑 `hermes` 会看到"Saved profile 'old' no longer exists"
（见 §3.1 第 5 条分支）。

### 11.8 创建后的通知

```python
_maybe_register_gateway_service(canon)   # s6 容器里注册成 s6 service
_notify_multiplexer(canon)               # 告诉活着的 multiplexer 立刻服务它
```

`notify_multiplexer_profiles_changed`（[`hermes_cli/gateway_multiplex_served.py:109`](../hermes_cli/gateway_multiplex_served.py:109)）：

> Tell the live default multiplexer that `profiles/` changed (``profile_name`` was created or
> deleted) so it **hot-serves / unroutes it now** instead of at its next periodic rescan. Returns
> the served-profile list the gateway answered with, or **None when no multiplexer answered**...
> **Never raises.**

"never raises" + "None 表示没人应答"是标准形状：调用方（`create_profile`）**不应该**
因为"没有活着的 multiplexer"而失败——那是完全正常的状态。

---

## 12. 陷阱清单（每条都有真实事故形状）

| # | 陷阱 | 后果 | 怎么发现 |
|---|---|---|---|
| 1 | 只设 `get_hermes_home_override()` | **半绑定**：配置对了，凭证与 `TERMINAL_*` 仍是启动 profile 的 | 次要 profile 用到了别人的 API key；或终端跑在别人的 ssh 主机上 |
| 2 | 裸 `threading.Thread` | 丢 contextvars → 静默落到启动 profile，或 fail closed 抛异常 | 后台任务写进了 default 的 memory；或后台任务报 `UnscopedSecretError` |
| 3 | `dict(os.environ)` / `os.environ.copy()` | 钉住启动 profile 的所有凭证与调优 | 子进程用错 key；子进程 rtad 别人的 allowlist |
| 4 | import 时读 home（模块常量） | 冻结到启动 profile | 次要 profile 看不到自己的主题 / hook 路径 |
| 5 | 硬编码 `~/.hermes` | 违反 HX001；容器 / 自定义 root / profile 模式下全错 | `grep -rn 'Path.home() / ".hermes"'` |
| 6 | turn 外读 profile 状态不绑 scope | 静默的默认 profile 泄漏 | eviction 把次要 profile 的记忆 flush 进 default 的库 |
| 7 | 从 `os.environ` 读 multiplex 下的 profile env | 泄漏的 allowlist / 错误凭证 | 次要 profile 的发送者全被拒（`#86905`） |
| 8 | `try get_secret / except UnscopedSecretError: os.getenv(...)` | **回退泄漏**：本该抛的地方读了别人 | 这个形状本身就是 bug；改用它共享的 reader |
| 9 | 用 `get_process_hermes_home()` 做路由判定 | 宿主镜像 `HERMES_HOME` 时永远判"不是 routed"（`#119242`） | MCP 工具名没有 profile 前缀，两个 profile 互相串 |
| 10 | 在事件循环里调 `hydrate_profile_secret_sources` | 事件循环卡 30s（同步子进程） | gateway 周期性卡顿，latency 尖峰 |
| 11 | 从 `os.environ["HERMES_HOME"]` 反推"当前 profile" | 次要请求里读到启动 profile 的名字 | 会话 key 落到 `agent:main` 而不是 `agent:<name>` |
| 12 | 在 `serve` 里懒激活而不是 eager | boot 期间做的所有事都没被 scope | 启动后的第一次 reaper flush 写错 profile |

### 12.1 每条的具体修法

**#1 半绑定 → 用 `_profile_runtime_scope` / `_session_profile_runtime_scope`**

不要自己拼 token。用现成的上下文管理器，它一次性绑三样：

```python
with _profile_runtime_scope(profile_home):     # home + secret + terminal
    ...
```

TUI/RPC 侧用 [`tui_gateway/model_switch.py:134`](../tui_gateway/model_switch.py:134) 的
`_session_profile_runtime_scope(session)`。

**#2 裸线程 → `spawn_context_thread`**

```python
from agent.memory_provider import spawn_context_thread
spawn_context_thread(fn, name="my-job").start()
```

**#3 `dict(os.environ)` → `served_profile_child_env`**

```python
from tools.environments.local import served_profile_child_env
env = served_profile_child_env(target_home=str(home), inherit_credentials=True)
```

**#4 import 时常量 → 改成函数**

```python
# 反例
HOOKS_DIR = get_hermes_home() / "hooks"

# 正确
def hooks_dir() -> Path:
    return get_hermes_home() / "hooks"
```

**#6 turn 外路径 → 查 `gateway/AGENTS.md` 的绑定缝表**

`_run_release_in_profile_scope`（eviction）、`_finalize_session`（shutdown）、
`_media_delivery_scope`（delivery）、deferred callback（picker / reaction）、
notifier、outbound webhook——每一个都在表里。

**#8 回退泄漏 → 用共享 reader**

`gateway/AGENTS.md`：

> Never re-implement the reader in an adapter (the `try get_secret / except
> UnscopedSecretError: os.getenv` shape **drifts into a fallback-after-miss leak**); **import the
> shared one**.

共享 reader 是 `gateway.platforms._shared.get_scoped_secret`（adapters import it as
`_get_scoped_secret`）和 `platform_gate_env`（`authz_mixin.py` import as `_auth_env`）。

### 12.2 探测方法（照抄就能用）

`tui_gateway/AGENTS.md` 给了一个可执行的探测：

> Probe with **two on-disk homes and a `.env` name present only in the secondary**: call the method
> for that session and assert **the secondary's value resolves and the launch profile's does not**,
> and that **`os.environ` is unchanged afterwards**.

写成测试的形状：

```python
def test_rpc_method_is_profile_scoped(tmp_path, monkeypatch):
    launch = tmp_path / "launch";  launch.mkdir()
    second = tmp_path / "second";  second.mkdir()
    (launch / ".env").write_text("SECOND_ONLY=no\n")
    (second / ".env").write_text("SECOND_ONLY=yes\n")

    monkeypatch.setenv("HERMES_HOME", str(launch))
    os.environ.pop("SECOND_ONLY", None)          # 确保不是从进程环境捡到的

    result = call_method_for_session(session_with_profile_home=second)

    assert result["SECOND_ONLY"] == "yes"        # 次要 profile 的值解析到了
    assert "SECOND_ONLY" not in os.environ       # 而且**没有**污染进程环境
```

三条断言各自堵一个洞：

1. `"yes"` → scope 真的装上了；
2. 启动 profile 的值**没有**被返回 → 不是靠"读了环境变量，恰好环境变量里是 launch 的"；
3. `os.environ` 未变 → 没有人偷偷写 `os.environ`（这是 `#107422` 类的守卫）。

---

## 13. 在哪里打补丁（按症状定位）

| 症状 | 文件 | 符号 |
|---|---|---|
| 新命令 `-p X` 解析不到 / 走进错的 profile | [`hermes_cli/main.py:595`](../hermes_cli/main.py:595) | `_apply_profile_override` |
| `profile list` 看不到某个目录 | [`hermes_constants.py:318`](../hermes_constants.py:318) | `_PROFILE_IDENTITY_MARKERS` |
| 删掉的 profile 又出现了 | [`hermes_constants.py:380`](../hermes_constants.py:380) | `mkdir_under_hermes_home` |
| 某个路径函数没跟着 override 走 | 调用点 | 该用 `get_hermes_home()` 而不是 `get_process_hermes_home()` |
| 「是不是 routed」判错 | [`agent/secret_scope.py:93`](../agent/secret_scope.py:93) | `serves_routed_profile` |
| 凭证读到了别人的 | [`agent/secret_scope.py:219`](../agent/secret_scope.py:219) | `get_secret` |
| `.env` 解析边界不一致 | [`agent/secret_scope.py:350`](../agent/secret_scope.py:350) | `load_env_file` |
| 终端跑在了错的机器 / 沙箱 | [`tools/terminal_scope.py:75`](../tools/terminal_scope.py:75) | `terminal_env` |
| 子进程 env 里有别人的 key | [`tools/environments/local.py:386`](../tools/environments/local.py:386) | `served_profile_child_env` |
| 子进程 env 有别人的 `TERMINAL_*` / allowlist | [`tools/environments/local.py:458`](../tools/environments/local.py:458) | `strip_launch_profile_env` |
| gateway 该 multiplex 却 standalone | [`hermes_cli/gateway_multiplex_mode.py:124`](../hermes_cli/gateway_multiplex_mode.py:124) | `implicit_multiplex_blocker` |
| CLI 显示的 multiplex 状态和实际不一致 | [`hermes_cli/gateway_multiplex_served.py:33`](../hermes_cli/gateway_multiplex_served.py:33) | `recorded_served_profiles` |
| `serve` 服务第二个 home 时没 fail closed | [`tui_gateway/launch_profile_policy.py:71`](../tui_gateway/launch_profile_policy.py:71) | `activate_multi_profile_hosting_eagerly` |
| RPC 方法读到启动 profile 的配置 | [`tui_gateway/server.py:604`](../tui_gateway/server.py:604) | `_profile_scoped` |
| clone 出来的 profile 抢源 bot | [`hermes_cli/profile_channels.py:412`](../hermes_cli/profile_channels.py:412) | `strip_channel_settings` |
| clone 覆盖了源的 `.env` | [`hermes_cli/profiles.py:1222`](../hermes_cli/profiles.py:1222) | `_materialize_symlinked_files` |
| 热服务看到了半成品 profile | [`hermes_cli/profiles.py:1464`](../hermes_cli/profiles.py:1464) | `_clone_staging_dir` |
| `check_fn` 缓存串 profile | [`tools/registry.py:325`](../tools/registry.py:325) | `_check_fn_cached` |

---

## 14. 测试约定

[`tests/AGENTS.md`](../tests/AGENTS.md) 的通用规则 + 本篇特有的：

| 规则 | 理由 |
|---|---|
| 用**两个临时 home**，不要碰 `~/.hermes` | 测试永远不写用户状态 |
| 至少一个 key **只存在于次要 profile** | 否则"读到了启动 profile 的值"也会让测试通过（假绿） |
| 断言 `os.environ` 在操作后**未变** | 抓 `#107422` 这类"偷偷写环境变量" |
| 断言单 profile 路径返回的**正是** `nullcontext()` | 保住字节级不变 |
| 用 `reset_hermes_home_key_cache()` 清缓存 | 测试移动了磁盘 home，缓存会骗人 |
| 用 `invalidate_env_file_cache()` 清 `.env` 缓存 | 同上 |
| 不要 fake `sys.platform` | 平台的真实差异必须在那个平台测 |

**不该测什么：**

- 不要测"`_PROFILE_IDENTITY_MARKERS` 里有 6 个元素"——这是 **change-detector**，
  加一个标记就会红，但不代表有 bug；
- 要测的是行为：**"带 `config.yaml` 的目录会被列出，空目录不会"**。

**值得单独测的一类：** 子进程 env 隔离。因为它跨越了 `contextvars` 的边界
（进程内 → 进程外），是最容易"看起来对、实际错"的地方。测法：

```python
env = served_profile_child_env(target_home=str(second), inherit_credentials=False)
assert "OPENAI_API_KEY" not in env       # 被洗掉了
assert env["HERMES_HOME"] == str(second)
assert "SECOND_ONLY" not in env          # inherit=False 不加回
```

再补一个 `inherit_credentials=True` 的对照，断言 **次要 profile 的** key 加回来了、
**启动 profile 的**没有。

---

## 15. 自检题

### A 组：概念

1. 用一句话定义 profile。它和"用户"、"配置档"分别差在哪？
2. 「隔离岛」具体指什么？`--clone` 之后改源 profile 的配置，克隆体会变吗？
3. `os.environ` 为什么不能用来表达"当前 profile"？给两个具体事故。
4. `threading.local` 为什么也不行？协程的什么特性让它失效？
5. 哪些东西该放 ContextVar，哪些该放普通模块全局？举本篇的例子。
6. 在 `hermes -p coder serve` 这个进程里，"default profile"指的是谁？
7. `get_active_profile_name()` 是怎么反推当前 profile 的？返回 `"custom"` 意味着什么？

### B 组：三种 home

8. 写出 `get_hermes_home()` 的三级优先级。
9. `get_process_hermes_home()` 为什么要**忽略** override？
10. `pin_process_hermes_home()` 解决的是哪一类问题？复述 `#119242` 的完整链条。
11. 为什么 pin **不能**折叠进 `get_process_hermes_home()`？
12. `get_routing_process_hermes_home()` 和 `get_process_hermes_home()` 什么时候不同？
13. 下面四个场景各该用哪个函数：读主题 YAML / 判断"是否 routed" / 打开 `state.db` / 打印给用户？
14. `_get_profiles_root()` 为什么**故意**锚定 root 而不是当前 `HERMES_HOME`？

### C 组：绑定

15. `_apply_profile_override()` 为什么必须在任何模块 import 之前跑？
16. 它信任已有的 `HERMES_HOME` 的条件是什么？
17. `active_profile` 是怎么工作的？为什么改名时要重定向它？
18. 复述"模块常量会冻结到启动 profile"的完整机制，并给一个反例。
19. 单 profile 命令里会出现 override 吗？什么时候？
20. 什么是**半绑定**？它漏掉了哪两样东西？
21. 半绑定最典型的症状是什么？

### D 组：key 与槽位

22. `hermes_home_key()` 为什么需要缓存？为什么"不存在的目录"不缓存？
23. `normcase` 在 Windows 上做了什么？不做的后果是什么？
24. 举三个必须 per-profile 的进程级槽位，并说明它们为什么不能共享。
25. `check_fn` 缓存的 `scope` 有哪三种取值？各自含义？
26. 为什么"routed 但拿不到 override"要**完全绕过**缓存，而不是用 `None` 当 key？
27. `_run_check_fn_uncached` 怎么区分"boot 时预期失败"和"spawn 站点 bug"？

### E 组：身份与存活性

28. 列出六个身份标记。为什么需要这么多？
29. 悬空 symlink 为什么算身份？只看 `is_file()` 会出什么错？
30. `named_profile_has_servable_identity` 比 `named_profile_has_identity` 多了什么？
31. 一个空的 `.env` 怎么会让整个宿主机 fail closed？完整推导一遍。
32. tombstone 为什么放在 profile 目录**旁边**而不在里面？
33. `mkdir_under_hermes_home` 的两个拒绝条件是什么？`#94590` 的完整事故链？
34. 为什么 `normalize_profile_name` 对非字符串输入这么严格？`profiles/0/` 是怎么产生的？
35. `named_profile_home()` 的两个防误判是什么？`profiles/.deleted/coder` 会怎样？
36. `profile_name_for_home()` 怎么判定 default？为什么不比 basename？

### F 组：模式解析

37. `multiplex_profiles` 的三态分别是什么？`False` 为什么被"退役"？
38. 退役之后 flag 还能用吗？为什么保留这个 key？
39. `gateway.standalone: true` 是什么？为什么每个界面都要打 deprecation notice？
40. 复述 `resolve_multiplex_mode` 的七步判定顺序。为什么 standalone 排第一？
41. 显式 `true` 为什么不做 guard 检查？
42. 列出五个 implicit blocker。每个分别对应什么现实场景？
43. 为什么 parked 的 profile 也算"有第二个租户"？
44. 为什么"启动 profile 的身份"不是 blocker？早先的实现在这里出了什么问题？
45. `"config"` / `"default"` / `"guard"` / `"retired-opt-out"` 四种 source 各自的日志与持久化行为？
46. CLI 为什么不能直接用合并默认值？两种"猜错"分别是什么？
47. `recorded_served_profiles()` 返回 `None` 和 `[]` 有什么区别？
48. 判断 gateway 活着有哪三个错误做法？正确做法验证哪三项？

### G 组：secret / terminal scope

49. 为什么不能把多个 profile 的 `.env` union 进 `os.environ`？三条泄漏路径。
50. `_MULTIPLEX_ACTIVE` 和 `_MULTIPLEX_CONTEXT` 分别描述什么？给一个只用后者的场景。
51. `set_multiplex_active(False)` 释放 pin 的两个条件是什么？为什么要有第二个？
52. `serves_routed_profile()` 的三个条件分别堵什么洞？
53. `_BoundScope.profile_home` 是干什么的？哪两处故意不装 override 却需要它？
54. 背出 `get_secret` 的六格表。
55. "装了 scope 但 key 不在 scope 里"，routed 时为什么返回 `default` 而不是读环境变量？`#86905` 的链条？
56. 非 routed 时为什么又要回退到 `os.environ`？不回退会出什么问题？
57. `UnscopedSecretError` 为什么把技术细节放 `__notes__`？`str(exc)` 里那句话的三个设计点是什么？
58. `_GLOBAL_ENV_EXACT` 的三条判据各举一例。`API_SERVER_KEY` 为什么不在里面？
59. `HERMES_TELEGRAM_` 前缀为什么安全？token 叫什么？
60. `load_env_file` 的缓存防了哪四个威胁？`ctime_ns` 特别在哪？
61. `build_profile_secret_scope` 的四层分别是什么？为什么 managed `.env` 要**最后、带 override**？
62. `refresh_installed_secret_scope` 为什么用 replace 语义而不是 merge？
63. `TERMINAL_*` 为什么会造成 sandbox escape？完整事故链？
64. `TerminalPolicyRefusal` 为什么比"直接抛"好？
65. 「全量投影」为什么是必须的？缺失的 key 会怎样？
66. `_resolve_scope_cwd_placeholder` 解决什么问题？不解决会怎样？

### H 组：线程 / 子进程 / clone

67. `copy_context()` 是快照还是引用？这个选择带来什么后果？
68. `served_profile_child_env` 的四步分别做什么？
69. 为什么第 3 步要"无差别洗凭证"而不是"按名字剥"？
70. `inherit_credentials=True` 但既没 target 也没 scope 时为什么抛异常？举一个实际后果。
71. `strip_launch_profile_env` 的四个残渣来源各堵什么洞？`#107695` 和 `#113270` 分别对应哪个？
72. 为什么 managed `.env` 的 key **不剥**？
73. `TERMINAL_*` 在 `_is_global_env` 里是全局的，为什么又要特别保留在残渣集合里？
74. `contextvars` 为什么不跨进程？实践含义是什么？
75. clone 为什么用 `profiles/.<name>.staging-<pid>`？两个性质分别防什么？
76. "start adapters on credentials the strip below has not removed yet" 是哪个竞态？完整时序？
77. symlink 的 `.env` 不先实体化会出什么事故？
78. `--clone-all` 为什么排除 `cron/`？继承 `jobs.json` 的后果？
79. 为什么 `_CLONE_ALL_DEFAULT_EXCLUDE_ROOT` 只在源是 default 时生效？
80. `bot-desktop/launcher.pid` 和 Chromium 的 `SingletonLock` 各会造成什么？
81. 通道剥离为什么必须"按所有权"而不是"手写清单"？`TWILIO_` 的特殊性在哪？
82. `--clone-channels` 被拒的四个条件？
83. 删除 profile 时"pending settlement"是什么意思？为什么不回滚？

### 参考答案要点（自查用）

- **5**：per-task → ContextVar（home / secret / terminal）；per-process → 全局（`_MULTIPLEX_ACTIVE`、`_PINNED_PROCESS_HERMES_HOME`）。
- **11**：因为 `get_hermes_home()` 在无 override 时 fallback 到它；折叠会让宿主的镜像失效。
- **26**：用 `None` 会把"身份不明"混进单 profile 缓存，拿到别人的可用性判定。
- **31**：空 `.env` → 算 identity → eager 激活认为有 2 个租户 → `set_multiplex_active(True)` → 所有未 scope 的 `get_secret` 抛异常。
- **55**：不回退是防止读到启动 profile 的 allowlist，那会**静默拒绝**次要 profile 的所有发送者。
- **56**：单 profile 部署靠进程环境注入凭证（systemd / `op run`），文件里没有；不回退会让 cron 全部 401。
- **69**：systemd / Compose / shell 注入的 key 从来没进过 `.env`，基于名字的剥离看不见它。
- **76**：multiplexer 每 30s 扫 `profiles/`；目录一出现就起 adapter；此时 strip 还没跑 → 两个进程抢一个 bot token。

---

## 16. 小结

九句话：

1. **profile 是租户，不是配置档**；它是**隔离岛**，没有活的配置继承。
2. **`os.environ` 只能表达"启动 profile"**；per-task 的归属必须走 ContextVar。
3. **三种 home 必须分开**：`get_hermes_home()`（读）、`get_process_hermes_home()`（进程资产）、
   `get_routing_process_hermes_home()`（路由判定）。混用是 `#119242`。
4. **半绑定是本项目最常见的 bug 形状**：只设 home override，漏掉 secret scope 与 terminal scope。
5. **`get_secret` 在 multiplex 下必须 fail closed**，而且"scope 命中失败"时**不能**回退到
   `os.environ`——回退不是放宽，是**静默拒绝合法用户**（`#86905`）。
6. **进程级每 profile 槽位一律以 `hermes_home_key()` 为 key**；拿不到身份时**绕过缓存**而不是共用。
7. **身份判定要保守，存活性判定要更保守**：悬空 symlink 算身份，空 `.env` 不算 servable。
8. **clone 是"隐藏 staging + 一次 rename"**，因为一个运行中的 multiplexer 每 30s 就会去认领新目录。
9. **线程用 `spawn_context_thread`，子进程用 `served_profile_child_env`**——contextvars 不跨这两个边界。

### 面试/讲给别人听的 60 秒版本

> Hermes 的 profile 是**完全隔离的租户**：独立的配置、凭证、记忆、会话、定时任务。
> 历史上一个 profile 一个进程，现在默认**一个 gateway 进程服务所有 profile**。
>
> 这带来一个核心难题：**"当前是哪个 profile"不能用 `os.environ` 表达**，因为一个进程
> 要同时服务多个。所以 Hermes 用了三层：
>
> 1. **ContextVar 的 home override** —— 所有路径解析自动跟着走；
> 2. **ContextVar 的 secret scope** —— `get_secret()` 从它读，读不到就**抛异常**而不是
>    回退到环境变量（回退会静默拒绝合法用户）；
> 3. **ContextVar 的 terminal scope** —— `TERMINAL_*` 是全量投影，缺失的 key 用默认值，
>    绝不回退（否则一个 profile 的 ssh 后端会泄漏给所有 profile）。
>
> 而 `os.environ["HERMES_HOME"]` **永远是启动 profile**，只用来回答"这个进程自己是谁"——
> 而且这个判定要用 `get_routing_process_hermes_home()`，因为嵌入宿主可能把被服务的
> profile 镜像进环境变量。
>
> 最容易错的不是"怎么 spawn"，而是**在 turn 之外**的路径：eviction、shutdown、
> 延迟回调、RPC、后台线程、子进程——**每一条都必须显式绑定作用域**，否则就是静默的
> 跨租户数据泄漏。

---

下一步 → [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md)：
所有不变量与规范的速查总表（HX001 / HX002 / HX003 / HX004 / HX005 / HX012 ……）。
