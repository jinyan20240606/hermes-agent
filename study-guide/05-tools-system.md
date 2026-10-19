# 05 · 工具系统与 Toolsets

> 目标：理解工具的「注册 → 发现 → 过滤 → 分发」全链路，以及添加工具的正确姿势。

---

## 1. 五个关键文件

| 文件 | 职责 |
|---|---|
| [`tools/registry.py`](../tools/registry.py:1) | 中央注册表，**零依赖** |
| [`model_tools.py`](../model_tools.py:1) | 薄编排层：触发发现、`get_tool_definitions()`、`handle_function_call()` |
| [`toolsets.py`](../toolsets.py:1) | `TOOLSETS` 字典、`_HERMES_CORE_TOOLS`、平台预设 |
| [`tools/*.py`](../tools/) | 各工具实现，import 时自注册 |
| [`tools/environments/`](../tools/environments/) | 终端后端（local/docker/ssh/modal/daytona/singularity） |

---

## 2. 注册模型

每个工具模块在 **import 时**调用 `registry.register(...)`：

```python
registry.register(
    name="terminal",               # 唯一工具名（出现在 API schema）
    toolset="terminal",            # 所属工具集
    schema={...},                  # 面向模型的 schema（description + parameters）
    handler=handle_terminal,       # 执行函数
    check_fn=check_terminal,       # 可选：返回 True/False 表示可用性
    requires_env=["SOME_VAR"],     # 可选：需要的环境变量（用于 UI 展示）
    is_async=False,                # handler 是否为 async 协程
    description="Run commands",    # 可选 ToolEntry 元数据
    emoji="💻",                    # spinner/进度显示的 emoji
)
```

来源：[`tools-runtime.md`](../website/docs/developer-guide/tools-runtime.md:29)

每次调用创建一个 `ToolEntry`，存进单例 `ToolRegistry._tools`（以工具名为 key）。

### 2.1 两条重要规则

1. **跨 toolset 遮蔽会被拒绝**（带 error log），除非调用方显式传 `override=True`。
   插件覆盖内置工具还需操作员 opt-in：`plugins.entries.<plugin_id>.allow_tool_override: true`。
2. **`schema["description"]` 才是面向模型的权威描述。**
   单独的 `description=` 参数只填 `ToolEntry.description`（registry 元数据），
   `get_definitions()` 不会把它复制进缺少 description 的 schema。
   所以：**除非有意让 registry 消费方看到不同元数据，否则把描述只写在 schema 里。**

---

## 3. 发现机制：`discover_builtin_tools()`

[`model_tools.py`](../model_tools.py:1) 被 import 时调用 `discover_builtin_tools()`。
它用 **AST 解析**扫描每个 `tools/*.py`，找出含顶层 `registry.register()` 调用的模块，然后 import：

```python
def discover_builtin_tools(tools_dir=None):
    tools_path = Path(tools_dir) if tools_dir else Path(__file__).parent
    for path in sorted(tools_path.glob("*.py")):
        if path.name in {"__init__.py", "registry.py", "mcp_tool.py"}:
            continue
        if _module_registers_tools(path):   # AST 检查顶层 registry.register()
            importlib.import_module(f"tools.{path.stem}")
```

来源：[`tools-runtime.md`](../website/docs/developer-guide/tools-runtime.md:53)、
[`tools/registry.py`](../tools/registry.py:59)

要点：
- **AST 只匹配顶层调用**（不匹配函数内的），所以 `tools/` 里的 helper 模块不会被 import。
- 可选工具的 import 错误会被捕获记录，不影响其它工具加载。
- 工具是**整个包**时（如 `tools/connectors/`），只从 `tools/<pkg>/tool.py` 注册——
  这是包内唯一被发现的文件；包需要 `__init__.py`，否则发现会跳过并告警。

发现顺序：内置工具 → MCP 工具（`tools.mcp_tool_discovery.discover_mcp_tools()`）→
插件工具（`hermes_cli.plugins.discover_plugins()`）。

---

## 4. 可用性检查 `check_fn`

`check_fn` 返回 `True` 表示工具可用。常见检查：API key 存在、服务在运行、二进制已安装。

```python
if entry.check_fn:
    try:
        available = bool(entry.check_fn())
    except Exception:
        available = False   # 异常 = 不可用（fail-safe）
    if not available:
        continue            # 完全跳过这个工具
```

来源：[`tools-runtime.md`](../website/docs/developer-guide/tools-runtime.md:81)

三个关键行为：
- 检查结果**每次调用缓存**——多个工具共享同一 `check_fn` 时只跑一次
- `check_fn` 抛异常视为不可用（fail-safe）
- `is_toolset_available()` 检查工具集的 `check_fn`，用于 UI 展示与工具集解析

### 4.1 `check_fn` 的铁律（容易踩的坑）

来自 [`tools/AGENTS.md`](../tools/AGENTS.md:55)：

> **`check_fn` 回答的是「它运行所在 profile 的可达性/是否 opt-in」，绝不是「什么界面」。**

- 结果按 `hermes_home_key()` 做 TTL 缓存（`registry.py::_check_fn_cache`）
- 一个进程服务多个 session **且多个 profile**
- 探测必须通过 [`agent/secret_scope.get_secret`](../agent/secret_scope.py:1) 读凭证，
  **绝不**用裸 `os.getenv`（那会用启动 profile 的 `.env` 回答所有人）
- 无作用域的启动探测产生 `UnscopedSecretError` 时按 DEBUG 处理，而非 traceback

---

## 5. Toolsets（工具集）

[`toolsets.py`](../toolsets.py:1) 里是单一 `TOOLSETS` 字典。当前键包括（**不要在测试里断言清单**）：

```text
browser, clarify, code_execution, cronjob, debugging, delegation, discord,
discord_admin, feishu_doc, feishu_drive, file, image_gen, kanban, memory,
messaging, moa, rl, safe, search, session_search, skills, terminal, todo,
tts, video, vision, web, yuanbao
```

来源：[`tools/AGENTS.md`](../tools/AGENTS.md:72)

### 5.1 `_HERMES_CORE_TOOLS`

[`toolsets.py`](../toolsets.py:11) 里的 `_HERMES_CORE_TOOLS` 是**每个平台基础工具集继承的默认包**，
不是死代码。它包含 web、terminal、file、vision、skills、browser、tts、todo、memory、
session_search、clarify、execute_code、delegate_task、cronjob、kanban_*、computer_use、
manage_connections。

### 5.2 三种构造 helper

```python
def _ts(description, tools=(), includes=(), **extra): ...    # 单个 toolset 条目
def _bundle(description, extras=()): ...                     # hermes-* 平台包 = 核心 + 额外
def _core_without(*excluded, kanban=True): ...               # 核心减去若干（保留顺序）
```

### 5.3 平台预设（`hermes-<platform>`）

[`toolsets.py`](../toolsets.py:191) 定义了约 20 个平台包：
`hermes-acp`、`hermes-api-server`、`hermes-cli`、`hermes-cron`、`hermes-telegram`、`hermes-discord`、
`hermes-whatsapp`、`hermes-slack`、`hermes-signal`、`hermes-email`、`hermes-matrix`、
`hermes-gateway`（聚合包）等。

- `hermes-gateway` 是所有网关平台包的集合，是唯一做 `includes` 嵌套的
- 插件平台会自动获得隐式的 `hermes-<platform>` 包（见 `_bundle` 附近逻辑）
- 按平台启用/禁用：`hermes tools`（curses 界面）或 `config.yaml` 里的
  `tools.<platform>.enabled/disabled`

### 5.4 CLIENT_SURFACE_TOOLSETS

```python
CLIENT_SURFACE_TOOLSETS = frozenset({"project", "desktop_ui", "catalog"})
```

这些是**客户端给自己的会话加的工具集**（由
[`tui_gateway/server.py`](../tui_gateway/server.py:1) 的 `_gui_surface_toolsets` 折叠进来），
绝不来自配置——「另一个没有它们的界面并未做出配置选择」。

### 5.5 browser_exec 的替换语义

当 `browser.backend` 是 `browser-use` 时，**`browser_exec` 会替换掉其它浏览器工具**。

---

## 6. 过滤：`get_tool_definitions()`

主入口是 `model_tools.get_tool_definitions(enabled_toolsets, disabled_toolsets, quiet_mode)`：

1. **若提供了 `enabled_toolsets`**——只包含这些工具集的工具。每个工具集名经 `resolve_toolset()`
   展开（复合工具集展开为具体工具名）
2. 否则走默认 bundle + 平台预设

`resolve_toolset(name, visited, *, include_registry=True)` 在
[`toolsets.py`](../toolsets.py:368)，它：
- 处理 `includes` 嵌套（一次遍历足够，因为只有 `hermes-gateway` 嵌套）
- `TOOLSET_SESSION_PLATFORMS` 记录「该工具集为哪些 session 平台而存在」
- `include_registry=True` 时也纳入 registry 动态注册的工具

---

## 7. 分发：`handle_function_call()`

[`model_tools.py`](../model_tools.py:1) 暴露的 `handle_function_call()` 负责派发，
带 hooks 与 middleware。派发前的拦截顺序：

```text
模型 tool_call
   │
   ├─► agent/inline_tool_executors.py::INLINE_TOOL_EXECUTORS  ← todo / memory 等
   │       （需要活 AIAgent 状态，绕过 registry）
   │
   └─► model_tools.handle_function_call() → tools/registry.py → handler
```

所有 handler **返回 JSON 字符串**。唯一例外：给模型送像素的工具可以返回多模态信封：

```python
{"_multimodal": True, "content": [text, image_url, ...], "text_summary": str}
```

`registry._normalize_handler_result` 只接受这一种形状；其图片路径走
`vision_tools._native_tool_result_images`，**绝不**走私有的 vision 检查。

### 7.1 错误边界

- `_MAX_TOOL_ERROR_CHARS = 2048`：仅裁剪失控的插值异常
- `_bound_json_error_result`：对直接 `json.dumps({"error": str(exc)})` 的 handler 兜底，
  防止超大错误在重试间堆积
- 日志保留更长的前缀（`_MAX_LOGGED_ERROR_CHARS = 8192`）

---

## 8. 添加核心工具（仅当用户明确要贡献核心工具）

**自定义/本地工具不要改核心**：创建 `~/.hermes/plugins/<name>/plugin.yaml` + `__init__.py`，
调用 `ctx.register_tool(...)`。插件工具集会被自动发现，无需碰 `tools/` 或 `toolsets.py`。

若确实要加核心工具，两步：

### 步骤 1：`tools/your_tool.py`

```python
from agent.secret_scope import get_secret
from tools.registry import registry

def check_requirements() -> bool:
    return bool(get_secret("EXAMPLE_API_KEY"))

def example_tool(param: str, task_id: str = None) -> str:
    return json.dumps({"success": True, ...})

registry.register(
    name="example_tool",
    toolset="example",
    schema={"name": "example_tool", "description": "...", "parameters": {...}},
    handler=lambda args, **kw: example_tool(param=args.get("param", ""), task_id=kw.get("task_id")),
    check_fn=check_requirements,
    requires_env=["EXAMPLE_API_KEY"],
)
```

### 步骤 2：[`toolsets.py`](../toolsets.py:1)

把工具名加进 `_HERMES_CORE_TOOLS`（所有平台）或一个新 toolset。**这一步是必须的**——
发现机制只注册 schema，工具只有被某个 toolset 收录才会暴露。

---

## 9. 工具代码的硬规则（踩坑清单）

来自 [`tools/AGENTS.md`](../tools/AGENTS.md:44)：

| 规则 | 原因 |
|---|---|
| **schema 描述里不得提及其它 toolset 的工具名** | 那些工具可能不可用（缺 key、被禁用），模型会幻觉调用它们。交叉引用在 `model_tools.get_tool_definitions()` 里动态添加 |
| **schema 描述中的路径用 `display_hermes_home()`** | schema 在 import 时构建；multiplex 下显示的是启动 home，仅用于展示 |
| **状态文件用 `get_hermes_home()`（调用时）** | 绝不用 `Path.home()/.hermes` 或模块常量，这样每个被服务的 profile 有自己的状态 |
| **教学类工具不加 `offset`/`limit` 分页** | 模型只读第 1 页就跳过其余 |
| **新工具要接入现有 setup UX**（`hermes tools`、`hermes setup`、自动安装） | 而不是给个裸 env var；secrets 放 `OPTIONAL_ENV_VARS` |

---

## 10. 工具内的后端与 provider

若干工具前面挂着可插拔后端：

| 领域 | 位置 |
|---|---|
| 终端环境 | [`tools/environments/`](../tools/environments/)（local、docker、ssh、modal、daytona、singularity） |
| 浏览器 | [`tools/browser_tool_*.py`](../tools/browser_tool.py:1)（cdp、cloud、install、lifecycle、session、real_profile、vision） |
| MCP 客户端 | [`tools/mcp_tool_*.py`](../tools/mcp_tool.py:1)（config、discovery、transport、registration、content、errors） |
| TTS | [`tools/tts_tool_providers.py`](../tools/tts_tool_providers.py:1)、[`tts_command_provider.py`](../tools/tts_command_provider.py:1) |
| Skills hub 源 | [`tools/skills_hub_official.py`](../tools/skills_hub_official.py:1) |

**加后端 = 加一个新 sibling 或 provider 条目到现有表里，绝不写 `elif` 判断后端名。**

### 10.1 每个 spawn 都走同一个 env builder

`tools/environments/local.py::build_subprocess_env`（配合
`hermes_constants.apply_subprocess_home_env`、`env_passthrough.py::resolve_passthrough_value`）
是终端、`execute_code`、后台进程、委派子进程、ACP/MCP stdio 子进程获得环境的**唯一**方式。

为被服务的 profile 工作的子进程用
`served_profile_child_env(target_home=, inherit_credentials=)`：
丢弃启动 profile 的 `.env` / `TERMINAL_*` 残留，钉住目标 home，只覆盖目标自己的 secrets。

**`os.environ.copy()` / `dict(os.environ)` 会钉住启动 profile**；
contextvars 不跨进程边界，所以必须在 `Popen` 之前解析。

### 10.2 后台进程终止：先通知父进程

`process_registry_termination.py::ProcessTerminationMixin._terminate_host_pid`：
先快照后代 → 只对记录的父进程 SIGTERM → 等 `terminal.daemon_term_grace_seconds`
让它退出并回收自己的孩子 → 再对快照里的幸存者 SIGTERM → 最后 SIGKILL 忽略前两者的。

> **绝不先 SIGTERM 后代再杀父进程**：在浏览器 zygote 关闭中途杀掉它，
> 会把 exit 0 变成 SIGTRAP core dump。

---

## 11. 测试约定

- 测试放 `tests/tools/`
- **通过 registry（真实派发）测 handler**，而不是只测裸函数
- 断言**契约**（「每个注册的工具都有 toolset」「没有 schema 描述提及其它 toolset 的工具」），
  而不是工具数量
- 审批/安全边界工具用真实 import + 临时 `HERMES_HOME` 做 E2E

---

## 12. 本篇小结与下一步

- 工具链：**自注册（import 时）→ AST 发现 → toolset 过滤 → registry 分发**。
- `check_fn` 回答可达性，不回答界面；结果按 home 做 TTL 缓存。
- 加核心工具是 2 个文件，但**门槛很高**——先想 Footprint Ladder。
- Agent 级工具走 `INLINE_TOOL_EXECUTORS`，不走 registry。

下一步 → [`06-provider-runtime.md`](06-provider-runtime.md)：模型与 provider 是怎么被解析出来的。
