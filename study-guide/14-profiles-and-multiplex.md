# 14 · Profile 与多路复用隔离

> 目标：掌握 Hermes 最深的工程主题——「一个进程服务多个 profile」。
> 这一章的不变量密度最高，值得反复读。

---

## 1. Profile 是什么

每个 profile（`hermes -p <name>`）拥有独立的：

- `HERMES_HOME`（含 `state.db`、`config.yaml`、`.env`、`logs/`、`skills/`、`SOUL.md`）
- 配置与凭证
- 记忆
- 会话
- 网关 PID

多个 profile 可以**并发运行**。

**关键设计**：Profile 是**隔离岛（islands on purpose）**——没有活的配置继承。
`--clone` 只在创建时复制一次（且排除消息通道）。

---

## 2. 两种 Profile 绑定方式（务必分清）

来自 [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:146)：

| 方式 | 场景 | 机制 |
|---|---|---|
| **单 profile 命令** | `hermes -p x <cmd>` | `_apply_profile_override()`（[`hermes_cli/main.py`](../hermes_cli/main.py:1)）在任何模块 import **之前**设 `HERMES_HOME` |
| **多路复用** | multiplex gateway、Desktop/dashboard `serve` | 按**活动**用 contextvar override 绑定活跃 profile，而 `os.environ["HERMES_HOME"]` **保持启动 profile** |

> **推论**：在 multiplex 下，模块常量或 import 时读取会**冻结到启动 profile**。
> 这正是「绝不硬编码 `~/.hermes`」和「绝不 import 时读 home」规则的来源。

---

## 3. `hermes_constants.py` 的核心 API

| 函数 | 语义 |
|---|---|
| `get_hermes_home()` | 权威 home（读用）：contextvar override → `HERMES_HOME` → 平台默认 |
| `display_hermes_home()` | **仅展示**：把 home 相对用户主目录格式化 |
| `set_hermes_home_override(path)` / `reset_hermes_home_override(token)` | contextvar 覆盖 |
| `get_hermes_home_override()` | 读覆盖 |
| `hermes_home_key(path=None)` | 规范化 home key（用于进程级每 profile 槽位） |
| `get_process_hermes_home()` | 进程级 home |
| `pin_process_hermes_home(path)` | 钉住进程 home（嵌入宿主用） |
| `get_routing_process_hermes_home()` | 路由判定用的进程 home |
| `get_default_hermes_root()` | 默认根 |
| `named_profile_home()` / `profile_name_for_home()` | profile 目录 ↔ 名 |
| `named_profile_is_live()` / `named_profile_has_identity()` / `named_profile_has_servable_identity()` | 存活性/身份 |
| `named_profile_is_deleted()` / `mark_named_profile_deleted()` | tombstone |
| `mkdir_under_hermes_home()` | 安全建目录（拒绝已删除的命名 profile） |

**规则**（HX001）：路径用 `get_hermes_home()`，文本用 `display_hermes_home()`。
`_get_profiles_root()` 是**故意** HOME 锚定的。

---

## 4. Profile 的存活性与身份

`profiles.py::profiles_to_serve(multiplex=True)` = **默认 profile + `profiles/` 下每个 live 目录**。

**live 的定义**：携带**身份标记**（`hermes_constants.named_profile_has_identity`：
`config.yaml` / `.env` / `SOUL.md` / `profile.yaml` / `auth.json` / `state.db` 之一）
且**未被 tombstone**。

- 无标记目录（cron/log 副作用的壳、游离的基础设施目录）
  **永不被列出、服务、tick、`.env` 回填或经 `-p` 解析**（#95188、#99392）
- `profile create` 只在它**同时被 tombstone** 时替换它
  （活的无标记目录可能存用户文件——fail closed，**绝不 rmtree**）
- 悬空的 symlink 标记**仍**算身份（`is_symlink()`）
- `tools/bot_mode_probe._roster` 用同一谓词
- **没有 allowlist**（`gateway.multiplex_profile_allowlist` 在 config v43 retired）

**枚举是纯读**：绝不从被服务路径 `mkdir` 一个 profile home
（`SessionDB`、logging、cron 都走 `mkdir_under_hermes_home` / `_ensure_cron_dir`，
它们拒绝已删除或缺失的命名 profile，#94590）。

---

## 5. 多路复用模式解析

- `gateway.multiplex_profiles` **默认开**
- 但 `GatewayConfig` 保持 flag 为**未设的 `None`**
- `gateway_multiplex_mode.resolve_multiplex_mode` **每次 boot 结算一次**
  （从 `load_gateway_config_for_runner` 调用）：
  默认 profile + ≥ 2 profiles + 无独立次要网关 + 无 preflight blocker + 可迁移宿主 → `True`；
  否则 `False` + 记录原因
- 显式值直接透传
- CLI/dashboard reader 用 `default_gateway_multiplexes`（活的 `served_profiles` 记录，
  然后显式 flag）——**绝不**用合并默认值，那会猜一个只有网关能做的裁决

---

## 6. Profile 创建与克隆

- clone 建在 `profiles/.<name>.staging-<pid>`（隐藏 → 对 `_iter_named_profile_dirs` 与
  hot-serve rescan 不可见），strip 之后用一个 `os.rename` 发布
- symlink 的 `.env`/`config.yaml` 会**先实体化**，所以 clone 绝不写穿到源
- `--clone` 排除消息通道；`--clone-channels` 显式 opt-in，
  其 live-multiplexer 拒绝在 `create_profile` 里（CLI、REST、TUI 都走它）
- 通道清单按**所有权**在**源**的插件作用域里评估
  （adapter 声明的 key + canonical/alias 前缀 + `GATEWAY_ALLOW*`/`GATEWAY_RELAY_*`）；
  与工具共享的前缀（`TWILIO_`/`EMAIL_`）只在源运行那个适配器时被剥离——**绝不用手写清单**

---

## 7. Secret 作用域（最重要的一节）

### 7.1 fail-closed 的 `get_secret`

[`agent/secret_scope.py`](../agent/secret_scope.py:1) 的 `get_secret`：

- **只在 `set_multiplex_active(True)` 之后**才 fail closed（`UnscopedSecretError`）
- 设置它的位置：gateway、cron、migrate、`serve`
- **新的 multi-home 宿主也必须设**，否则每个守卫都**静默关闭**

隔离是**profile 之间**的；子进程通过 `copy_context` 继承；
子进程的 `UnscopedSecretError` 是 **spawn 站点 bug**，
**绝不是** `os.getenv` 回退的理由。

### 7.2 被委派的子进程标记

[`agent/delegation_context.py`](../agent/delegation_context.py:1) 的 `DELEGATED_CHILD_ENV_MARKER`，
其值是**被围栏的 Kanban board root**，不是裸 flag。

### 7.3 作用域按 profile **活动**绑定（HX002/HX004/HX005/HX012）

> 每个在 turn **之外**运行的代码（boot 探测、驱逐、ticker、延迟回调、RPC 方法、线程跳转、
> 子进程 spawn）都必须**显式绑定所属 profile 的作用域**。
> `os.environ`、模块全局、import 时值持有的是**启动 profile 的**，所以未绑定的读取是**静默的默认 profile 泄漏**。

绑定缝：
- `gateway/run.py::_profile_runtime_scope(home)`
- `run_agent_cache.py::_run_release_in_profile_scope`
- `run_shutdown.py::_finalize_session`
- `tui_gateway/server.py::@_profile_scoped`
- `tui_gateway/methods_tools.py::_profile_scoped_rpc`
- tokens 来自 `model_switch.py::_profile_runtime_scope_tokens(profile_home)`（home + secret scope + terminal scope **一起**）

> **半绑定的陷阱**：只设 `get_hermes_home_override()` 是**半绑定的**——
> 配置路径解析到正确 profile，但凭证与 `TERMINAL_*` 策略仍来自启动 profile。

### 7.4 后台线程

- **绝不**裸 `threading.Thread`
- 用 `agent.memory_provider.spawn_context_thread`（复制 contextvars）
  ——`title_generator.py` 是范例形状

### 7.5 子进程

- 用 [`tools/environments/local.py`](../tools/environments/local.py:1) 的
  `served_profile_child_env(target_home=, inherit_credentials=)`，
  **绝不** `dict(os.environ)`
- `os.environ.copy()` 会钉住启动 profile
- **contextvars 不跨进程边界**，所以要在 `Popen` 之前解析

---

## 8. 一个进程，多个 profile 的全局槽位

所有进程级每 profile 槽位都以 `hermes_constants.hermes_home_key()` 为 key，
**绝不**用单个 flag：

- MCP 发现（`mcp_startup.py`）
- 工具注册表 overlay
- `check_fn` 缓存（[`tools/registry.py`](../tools/registry.py:1) 的 `_check_fn_cache`）

---

## 9. 「一个启动 home 身份」

「这个任务服务路由 profile 吗？」的比较对象是
`hermes_constants.get_routing_process_hermes_home()`，
**绝不** live 读 `os.environ["HERMES_HOME"]`：

- `agent/secret_scope.py::serves_routed_profile` 与 `_is_process_home`
- `tools/environments/local.py::_is_routed_home`
- `hermes_cli/env_loader.py::_process_hermes_home`

一个把被服务 profile 每轮镜像进 env var 的嵌入宿主（Hermes WebUI）用
`pin_process_hermes_home()` 钉住自己的 home；没有 pin 时 resolver 就是
`get_process_hermes_home()` 不变。

> **不要再加另一个直接拿 `get_process_hermes_home()` 比较的路由决策**——
> 那个 resolver 是给进程级资产的。

---

## 10. 网关侧的多路复用细节

完整的 profile 作用域规则（身份规范化、接收/交付适配器、token 锁、env 读取 fail-closed）
见 [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md) § 7。

### 10.1 TUI/RPC 侧的 profile 作用域

来自 [`tui_gateway/AGENTS.md`](../tui_gateway/AGENTS.md:52)：

- 一个 `serve` 进程可能托管来自多个 profile home 的会话
- **启动 profile 也是一个 profile**：「default」意思是启动 home，**绝不是 `~/.hermes`**
- 第一个被托管的非启动 home 翻转 `launch_profile_policy.py` → `set_multiplex_active(True)`
- **每个**读或写 home/config/.env 派生状态的方法都在 `server.py::@_profile_scoped` 下运行
  （从活会话的 `profile_home` 解析，或 sessionless 调用用显式 `profile` 参数）
- 工具/agent 构造走 `methods_tools.py::_profile_scoped_rpc`
- off-turn 路径用 `session_lifecycle.py::_finalize_session` / `_teardown_session`
  进入 `_session_profile_runtime_scope(session)` 包裹 `on_session_end`、记忆提交、`agent.close()`

**探测方法**：用两个磁盘 home 与一个只存在于次要 profile 的 `.env` 名字；
为该会话调方法，断言次要的值解析到而启动 profile 的没有，且之后 `os.environ` 未变。

---

## 11. 已知的 profile 相关陷阱清单

| 陷阱 | 后果 |
|---|---|
| 只设 `get_hermes_home_override()` | **半绑定**——凭证/terminal 策略仍来自启动 profile |
| 裸 `threading.Thread` | 丢作用域 → 静默落到默认 profile 或 fail closed |
| `dict(os.environ)` / `os.environ.copy()` | 钉住启动 profile |
| import 时常量读 home | 冻到启动 profile |
| `Path.home()/.hermes` | 硬编码，违反 HX001 |
| 在 turn 外读 profile 状态不绑作用域 | 静默的默认 profile 泄漏 |
| 从 `os.environ` 读 multiplex 下的 profile env | 泄漏的 allowlist / 错误凭证 |

---

## 12. 本篇小结与下一步

- Profile 是**隔离岛**；两种绑定方式（import 前 env vs 按活动 contextvar）。
- **作用域必须在每个 turn 外的路径上显式绑定**——这是最大的一类 bug。
- `get_secret` 只在 `set_multiplex_active(True)` 后 fail closed。
- 全局槽位以 `hermes_home_key()` 为 key。
- 路由判定用 `get_routing_process_hermes_home()`，绝不 live 读 `HERMES_HOME`。

下一步 → [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md)：所有不变量与规范的速查总表。
