# 05 · 工具系统与 Toolsets

> **读法**：工具是 agent「能做事」的唯一途径。这一篇按数据流的**实际顺序**讲：
> **§0 前置**（tool call 到底是什么）→ **§1 文件地图** → **§2 注册** → **§3 发现**
> → **§4 可用性** → **§5 工具集** → **§6 定义装配** → **§7 Tool Search 渐进披露**
> → **§8 分发** → **§9 两条派发路径** → **§10 加工具** → **§11 硬规则** → **§12 自检**。
>
> 读完你应该能回答：**「我写了一个 Python 函数，想让模型能调用它，最少要改几个文件？
> 为什么改完之后模型还是看不见它？」**

**本篇相对旧版新增**：§0 前置、§2.3 冲突矩阵、§3 的 AST 缓存与包规则、§4.3 三种
`UnscopedSecretError` 分支、§5.6 `posture` 与 bundle 反向减法、§6 六阶段装配、
§7 整节 Tool Search、§8 的完整流水线、§9 两条派发路径的差异。

---

## 0. 前置概念

### 0.1 「工具」对模型来说是什么

模型本身**不能执行任何东西**。它只能输出一段结构化文本，说：

```json
{"name": "read_file", "arguments": {"path": "src/main.py"}}
```

**模型看到的「工具」只是两个东西**：

1. **一个 JSON Schema**（描述「这个工具叫什么、干什么、要什么参数」）
2. **一段说明**（`description`）

前端类比：这就像你给同事一份 API 文档。他不能直接调你的接口，但他可以按文档写一段调用代码，
然后**你**去执行。模型负责「按文档写出调用」，Hermes 负责「真的执行并把结果塞回去」。

### 0.2 为什么工具数量是成本问题

[`01-architecture-overview.md`](01-architecture-overview.md) §0.1 讲过 API 无状态。

**每个工具的 schema 在每一次 API 调用里都要发送一遍。**

一个中等复杂度的工具 schema ≈ 400~900 token：

```json
{"type":"function","function":{
  "name":"browser_click",
  "description":"Click an element on the page...",
  "parameters":{"type":"object","properties":{
     "ref":{"type":"string","description":"..."},
     "selector":{"type":"string","description":"..."}},
   "required":[]}}}
```

55 个核心工具 ≈ **25K~35K token**，每一轮都发。

这就是两条设计原则的物理来源：

| 原则 | 出处 |
|---|---|
| **核心工具的门槛极高** | 根 `AGENTS.md`：「核心是一条窄腰，能力活在边缘」 |
| **schema 描述要短** | 描述越短，每轮成本越低 |

也解释了 §7 的 **Tool Search**：MCP / 插件工具可以多到几百个，
必须**折叠**成三个桥接工具。

### 0.3 四条链路，先建立全局图

```text
① 注册（import 时）       tools/github_tool.py → registry.register(...)
                                    ↓
② 发现（import model_tools 时） discover_builtin_tools() → importlib.import_module
                                    ↓
③ 过滤（每次 get_tool_definitions）
      toolset 名  →  resolve_toolset()  →  {工具名}
                  →  registry.get_definitions()  →  check_fn 过滤  →  [schema]
                  →  _apply_dynamic_schemas()    →  sanitize        →  [schema]
                  →  tool_search 折叠
                                    ↓
④ 分发（模型要求调用时）    handle_function_call()
      inline 表 → registry.dispatch() → handler(args) → JSON 字符串
```

**四个阶段各有自己的「缓存」和「失效条件」**，这是本篇最容易混的地方。
先记住这张表：

| 阶段 | 缓存 | 什么时候失效 |
|---|---|---|
| 发现 | `~/.hermes/cache/tool_discovery_cache.json`（mtime+size） | 文件被改 |
| `check_fn` | `_check_fn_cache`（TTL ~30s，按 profile 作用域） | TTL 到期 / 手动 invalidate |
| 定义 | `_tool_defs_cache`（LRU 8 条，按 9 元组 key） | generation / config 改动 / 不同 toolset |
| 会话内 | `agent.tools`（构建一次） | **不失效**（04 篇铁律） |

---

## 1. 文件地图

| 文件 | 职责 | 依赖方向 |
|---|---|---|
| [`tools/registry.py`](../tools/registry.py:1) | 中央注册表、`check_fn` 缓存、分发 | **零内部依赖**（叶子） |
| [`model_tools.py`](../model_tools.py:1) | 触发发现、定义装配、`handle_function_call` | 依赖 registry + toolsets |
| [`toolsets.py`](../toolsets.py:1) | `TOOLSETS` 表、`_HERMES_CORE_TOOLS`、解析 | 依赖 registry（惰性） |
| [`tools/*.py`](../tools/) | 274 个工具实现，import 时自注册 | 依赖 registry |
| [`tools/tool_search*.py`](../tools/tool_search.py:1) | 渐进披露（折叠） | 依赖 toolsets + registry |
| [`agent/inline_tool_executors.py`](../agent/inline_tool_executors.py:1) | 需要活 agent 状态的工具 | 依赖 agent |
| [`tools/environments/`](../tools/environments/) | 终端后端 | — |

### 1.1 为什么 registry 必须零依赖

[`tools/registry.py:1`](../tools/registry.py:1)：

```python
"""Central registry for all hermes-agent tools: each tool file calls ``registry.register()``
at import to declare schema, handler, toolset membership and availability check;
``model_tools.py`` queries the registry instead of keeping parallel data structures.
Cycle-safe import chain: this module imports nothing from model_tools or tool files;
tools/*.py import it at module level; model_tools.py imports both; run_agent/cli import
model_tools."""
```

三角形：

```text
     tools/*.py  ──────►  tools/registry.py  ◄──────  model_tools.py
          │                     ▲                          │
          └─────────────────────┴──────────────────────────┘
                        （toolsets.py 惰性 import registry）
```

`registry.py` 是**叶子**：274 个工具文件都 import 它，它不能 import 任何工具文件，
否则立刻循环。这就是为什么它对 `hermes_constants` 也是**函数内延迟 import**
（[`_discovery_cache_path`](../tools/registry.py:144) 里那句
`Deferred import keeps tools/registry.py a no-deps leaf at import time`）。

**这是「多对一汇聚点」的标准形状**：把被所有人依赖的东西做到最小。

---

## 2. 注册

### 2.1 `register()` 的完整签名

[`ToolRegistry.register`](../tools/registry.py:666)：

```python
def register(
    self, name: str, toolset: str, schema: dict, handler: Callable,
    check_fn: Callable | None = None, requires_env: list | None = None, is_async: bool = False,
    description: str = "", emoji: str = "", max_result_size_chars: float | None = None,
    dynamic_schema_overrides: Callable | None = None, override: bool = False,
    scope: Optional[str] = None):
```

| 参数 | 作用 | 常见错误 |
|---|---|---|
| `name` | 模型看到的函数名（唯一） | 改名会破坏已保存的会话/提示 |
| `toolset` | 所属工具集 | 写了个不存在的 toolset → 永远不被暴露 |
| `schema` | **权威的**模型描述 | 描述里提及其它工具集的工具（§11） |
| `handler` | `handler(args, **kwargs) -> str` | 返回非字符串（§8.4） |
| `check_fn` | 可用性探测 | 用裸 `os.getenv`（§4.2） |
| `requires_env` | 环境变量清单（**仅 UI 展示**） | 误以为它会做拦截 |
| `is_async` | handler 是协程 | 忘了设 → 直接调用得到 coroutine 对象 |
| `description` | registry 元数据 | 以为它是模型看到的描述（见下） |
| `emoji` | spinner 图标 | — |
| `max_result_size_chars` | 单工具结果上限 | — |
| `dynamic_schema_overrides` | 每次装配时**浅合并**到 schema 的零参函数 | 用它做重活（每轮都跑） |
| `override` | 显式允许跨 toolset 覆盖 | 插件覆盖内置还需 operator opt-in |
| `scope` | profile 作用域（multiplex） | 非插件调用方不该传 |

### 2.2 `description=` 与 `schema["description"]` 的区别

这是旧版专门强调的一条，仍然成立：

[`get_definitions`](../tools/registry.py:843)：

```python
schema_with_name = {**entry.schema, "name": entry.name}
```

**它只把 `name` 塞进去，从不回填 `description`。**

所以：

| 位置 | 谁看 |
|---|---|
| `schema["description"]` | **模型** |
| `ToolEntry.description` | registry 元数据消费方（UI、诊断、`hermes tools`） |

`register` 的实现里有一行妥协：

```python
description=description or schema.get("description", ""),
```

**只做单向回退**（缺 `description=` 时用 schema 的），因为另一个方向没有消费者需求。

**结论：描述写在 `schema` 里。**

### 2.3 冲突矩阵（最容易忽略的一段）

`register` 的冲突处理是**二维**的：谁在注册 × 是否 `override`。

#### 前置：三方身份判定

```python
handler_owner = self._plugin_owner_of(handler)
caller_owner  = self._plugin_namespace_of_module(self._caller_module())
owner = caller_owner or handler_owner
if scope is None and owner is not None:
    scope = self._plugin_scope_of(owner)
```

**先看调用方模块**（`_caller_module()` 从栈里找），再退到 handler 所属模块。
为什么？因为插件可能注册一个**别人的函数**作为 handler，但代码是插件自己写的。

#### 情形一：插件试图遮蔽全局工具

```python
shadows_global = (owner is not None and scope is not None
                  and name not in target and name in self._tools)
if shadows_global:
    if not override:
        logger.error("Tool registration REJECTED: plugin %r attempted to shadow global tool %r "
                     "without override=True", owner, name)
        return
    if plugin_override_denied:
        raise PermissionError(_OVERRIDE_DENIED_MSG.format(owner=owner, name=name))
```

**两道闸门**：`override=True`（代码层面）+ `allow_tool_override`（运维层面）。
第二道是操作员在 `config.yaml` 里显式同意的。

#### 情形二：同名但不同 toolset

```python
if existing and existing.toolset != toolset:
    if override:
        ...
        logger.info("Tool '%s': toolset '%s' overriding existing toolset '%s' (override=True opt-in)", ...)
    else:
        # Reject every cross-toolset shadow (incl. MCP-to-MCP); same-toolset
        # re-registration (MCP reconnect/refresh) stays allowed.
        logger.error("Tool registration REJECTED: '%s' (toolset '%s') would shadow existing "
                     "tool from toolset '%s'. ...", ...)
        return
```

**注意注释里的例外**：`same-toolset re-registration` **允许**。
因为 MCP 服务器重连时会重新注册同名工具到同一个 toolset —— 那是刷新，不是覆盖。

#### 完整矩阵

| 调用方 | 同名工具来自 | `override` | 结果 |
|---|---|---|---|
| 非插件 | 同 toolset | 任意 | ✅ 允许（幂等刷新） |
| 非插件 | 其它 toolset | `False` | ❌ error log + **return**（静默放弃） |
| 非插件 | 其它 toolset | `True` | ✅ info log（可审计） |
| 插件 | 全局（跨 profile 遮蔽） | `False` | ❌ error log + return |
| 插件 | 全局 | `True` + 无 opt-in | 💥 `PermissionError` |
| 插件 | 全局 | `True` + 有 opt-in | ✅ |
| 插件 | 内置其它 toolset | `True` + 无 opt-in | 💥 `PermissionError` |
| 插件 | 内置其它 toolset | `True` + 有 opt-in | ✅ |

**为什么有的 `return` 有的是 `raise`？**

- 非插件冲突 → `return`（工具文件是程序自己的一部分，一个模块失败不该拖垮启动）
- 插件越权 → `raise`（这是**安全边界**，必须让加载器看见并隔离该插件）

#### 为什么必须在注册时校验 schema

```python
# Reject malformed schemas at registration, not at request time: a non-dict
# ``parameters`` (e.g. a list) serializes into every provider request and 400s the
# whole turn far from the offending plugin. Failing here names the culprit instead.
if not isinstance(schema, dict):
    raise ValueError(f"Tool {name!r}: schema must be a dict, got {type(schema).__name__}")
params = schema.get("parameters")
if params is not None and not isinstance(params, dict):
    raise ValueError(...)
```

**「fail far from the cause」是最难查的 bug 类型。** 一个插件的 `parameters` 写成了 list，
会导致**每一轮**请求都 400，而错误信息完全指不到那个插件。所以在注册点拦。

### 2.4 `ToolEntry` 与 `_generation`

[`ToolEntry`](../tools/registry.py:182) 是 `@dataclass(eq=False, slots=True)`。

**`eq=False` 是刻意的**：

```python
"""Metadata for one registered tool (identity semantics: restore/CAS paths compare ``is``)."""
```

`restore_registration` / CAS 路径要判断「这是不是同一个注册」，
用 `==` 会把「内容相同的两个 entry」误判为同一个。**用 `is` 才是对的**，而 `eq=False` 保证了
默认 `__eq__` 就是身份比较。

```python
self._generation += 1
```

每次注册/注销都 +1。它是 `_tool_defs_cache_key` 的一部分（§6.6），
**所以注册表一变，定义缓存立刻失效** —— 不需要任何显式的 invalidate 调用。

### 2.5 scope（profile 隔离）

```python
self._tools: dict[str, ToolEntry] = {}            # 内置 / 进程全局
self._scoped_tools: dict[str, dict[str, ToolEntry]] = {}   # 按 resolved HERMES_HOME 的插件覆盖层
```

```python
def _merged_tools(self, scope=None) -> dict[str, ToolEntry]:
    """Return global tools overlaid with one profile's plugin tools."""
    return {**self._tools, **self._scoped_tools.get(hermes_home_key(scope), {})}
```

**两层字典而不是「按 profile 分表」**：内置工具在所有 profile 里都一样，复制 20 份纯浪费。
插件工具才是 per-profile 的。

这和 [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md) 的 HX002/HX004 直接相关：
**注册发生在哪个 profile 作用域，决定了工具落在哪个 slot。**

---

## 3. 发现机制

### 3.1 为什么要「发现」而不是维护一个 import 列表

[`tools/AGENTS.md:12`](../tools/AGENTS.md:12)：

> Any `tools/*.py` with a top-level `registry.register()` is imported automatically — no
> manual import list.

**手工维护清单的必然结局是「有人加了文件但忘了加清单」。** 所以改成「文件存在 + 有注册调用 = 自动加载」。

### 3.2 AST 扫描

[`_module_registers_tools`](../tools/registry.py:69)：

```python
def _module_registers_tools(module_path: Path) -> bool:
    """True when the module body (or a module-level ``for``) calls ``registry.register(...)``.
    Only module-body statements count, so helpers registering inside a function are skipped;
    a text prefilter avoids ``ast.parse`` for files lacking both words."""
    try:
        source = module_path.read_text(encoding="utf-8-sig")
        if "registry" not in source or "register" not in source:
            return False
        tree = ast.parse(source, filename=str(module_path))
    except (OSError, SyntaxError):
        return False
    return any(
        _is_registry_register_call(stmt)
        or (isinstance(stmt, ast.For) and any(_is_registry_register_call(s) for s in stmt.body))
        for stmt in tree.body)
```

三个设计点：

| 设计 | 理由 |
|---|---|
| **只扫 `tree.body`** | 函数内的 `registry.register()` 是 helper，不该触发整包加载 |
| **允许 `for` 循环体** | 表驱动模块从一个循环注册多个工具（本仓库的主推风格） |
| **先做字符串预筛** | `"registry" not in source or "register" not in source` 时直接跳过，省掉 `ast.parse` |

`encoding="utf-8-sig"` 也是细节：Windows 上带 BOM 的文件用 `utf-8` 读会在开头留 `\ufeff`，
`ast.parse` 直接 `SyntaxError`。

### 3.3 磁盘缓存

```python
"""... The per-file AST scan costs ~145 ms over ~100 files, so verdicts are memoized on disk
keyed by ``(mtime_ns, size)``; a mismatch or corrupt cache re-scans that file. The write is
best-effort and atomic, so concurrent processes race harmlessly."""
```

**145 ms** 对每次启动都付是贵的（CLI 冷启动、网关重启、每个子代理进程）。

| 细节 | 理由 |
|---|---|
| key = `(mtime_ns, size)` | 比 hash 快，且对「编辑器保存」足够灵敏 |
| 单文件粒度失效 | 改一个文件只重扫一个 |
| 缓存损坏 → 全量重扫 | 而不是报错 |
| 原子写 + best-effort | 多进程并发写不会互相破坏，最坏是重扫 |

### 3.4 包的规则

```python
def _tool_module_candidates(tools_path: Path) -> list[Path]:
    """Flat ``tools/*.py`` modules plus the package entry point ``tools/<pkg>/tool.py``, in one
    sorted list. Only ``tool.py`` is scanned in a package, so every other file in it is a library
    by construction."""
```

```python
if len(rel_parts) > 1 and not (path.parent / "__init__.py").exists():
    # setuptools' package finder drops a directory without __init__.py, so this tool would
    # register from a checkout and vanish from an installed wheel.
    logger.warning("Skipping %s: package %s has no __init__.py", path, parent.name)
    continue
```

**「从源码能跑、装成 wheel 就消失」** 是最典型的打包事故。这里在发现阶段就拦住。

### 3.5 排除与容错

```python
if path.name in {"__init__.py", "registry.py", "mcp_tool.py"}:
    continue
```

`mcp_tool.py` 被排除是因为 MCP 工具**不能**在 import 时注册 —— 它们要先读配置、连服务器。
MCP 走独立的 `discover_mcp_tools()`（[`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md)）。

```python
try:
    importlib.import_module(mod_name)
    imported.append(mod_name)
except Exception as e:
    logger.warning("Could not import tool module %s: %s", mod_name, e)
```

**一个工具模块 import 失败不影响其它工具。** 这是「能力活在边缘」的运行时体现：
边缘坏了，核心还能跑。

### 3.6 三层发现顺序

```text
内置（discover_builtin_tools）
  → MCP（tools.mcp_tool_discovery.discover_mcp_tools）
    → 插件（hermes_cli.plugins.discover_plugins）
```

顺序有意义：**后注册者可以覆盖前面的**（配合 `override=True`）。
插件在最后，所以它有「用我的实现替换内置」的能力。

---

## 4. 可用性检查 `check_fn`

### 4.1 语义

```python
if entry.check_fn and not _memo_check(entry.check_fn, check_results):
    continue
```

`check_fn()` 返回 `True` = 这个工具**现在就可用**。

典型用途：

| 场景 | `check_fn` |
|---|---|
| 需要 API key | `bool(get_secret("BRAVE_API_KEY"))` |
| 需要二进制 | `shutil.which("ffmpeg")` |
| 需要服务在跑 | 探测 socket |
| 需要 opt-in | 读配置项 |

### 4.2 铁律：回答可达性，不回答界面

[`tools/AGENTS.md:55`](../tools/AGENTS.md:55)：

> **`check_fn` answers reachability/opt-in for the profile it runs under, never surface.**

反例（想做什么 vs 该做什么）：

| 错误做法 | 为什么错 | 正确做法 |
|---|---|---|
| `check_fn` 里判断 `agent.platform == "desktop"` | 一个进程服务多个 session | 用 `platforms=` 让 toolset 只在某平台出现（§5.5） |
| `check_fn` 里 `os.getenv("KEY")` | 拿的是**启动 profile** 的 `.env` | `agent.secret_scope.get_secret("KEY")` |
| 每小时才变的东西每轮都探测 | 每轮都付 I/O | TTL 缓存会兜住，但别设计成每次都要 I/O |

### 4.3 缓存的三层结构

```python
def _check_fn_cached(fn) -> bool:
    now = time.monotonic()
    if fn in _NO_CACHE_CHECK_FNS:
        return _run_check_fn_uncached(fn)
    scope = check_fn_cache_scope()
    if scope == CHECK_FN_CACHE_BYPASS:
        return _run_check_fn_uncached(fn)
    cache_key = (fn, scope)
    with _check_fn_cache_lock:
        _prune_check_fn_caches(now)
        cached = _check_fn_cache.get(cache_key)
        if cached is not None:
            return cached[1]
    ...
```

三层优先级：

```text
① no_cache_check_fn 装饰 → 永不缓存
② scope == BYPASS      → 永不缓存（连外层定义缓存也 bypass）
③ 否则                  → key = (fn, profile_scope)，TTL ~30s
```

#### 为什么 key 要带 profile

一次网关进程服务多个 profile。`brave_search` 的 key 可能在 profile A 有、profile B 没有。
只用 `fn` 做 key 会让 B 拿到 A 的答案。

#### 什么时候 BYPASS

[`check_fn_cache_scope`](../tools/registry.py:263)：

```python
"""... Browser-controller availability is request-bound (changes on every attach/detach),
so a fully bound browser-control request bypasses this cache AND model_tools' outer
definition cache (same sentinel) — one Browser session's live tools must not leak into
another."""
```

**「request-bound」** 是关键判据：**如果可用性在一个请求内就可能变，就不能缓存。**

```python
if all(str(get_session_env(k, "") or "").strip() for k in _BROWSER_IDENTITY_KEYS):
    from gateway.browser_control_broker import browser_control_enabled
    if browser_control_enabled():
        return CHECK_FN_CACHE_BYPASS
```

注意那个嵌套条件：**「identity 齐全」不等于「controller 已挂载」**。
`api_server` 在每个请求上都绑定 principal，所以只有扩展控制功能真的开着才 bypass
（注释里带 issue 号）。

#### 失败豁免（grace）

`_prune_check_fn_caches` 维护两个缓存：

```python
for cache, ttl, stamp in (
    (_check_fn_cache, _CHECK_FN_TTL_SECONDS, lambda v: v[0]),
    (_check_fn_last_good, _CHECK_FN_FAILURE_GRACE_SECONDS, lambda v: v)):
```

- `_check_fn_cache`：正常结果，短 TTL
- `_check_fn_last_good`：**上次成功**的结果，长 grace

为什么需要 grace？**探测本身可能临时失败**（网络抖动、服务重启）。
如果一次抖动就让工具消失，模型会突然「不会用这个工具了」，用户看到的是行为退化。
用上次成功的答案顶住，比「立刻消失」好。

### 4.4 `UnscopedSecretError` 的三种情况

[`_run_check_fn_uncached`](../tools/registry.py:294) 有整整 30 行注释在讲这一件事：

```python
except UnscopedSecretError:
    if current_secret_scope() is None:
        # Expected fail-closed probe: with multiplexing on, boot-time check_fns run before any
        # profile secret scope exists, so get_secret raises by design. No traceback, so this
        # cannot be mistaken for a crashed check_fn (#100697).
        logger.debug(...)
    else:
        # The caller IS scoped but the read still failed closed: the probe dropped the scope on
        # the way to get_secret (a bare thread/executor hop) — a spawn-site bug, kept loud.
        logger.warning(..., exc_info=True)
```

三种情况必须区分：

| 情况 | 判断 | 日志级别 | 含义 |
|---|---|---|---|
| 无 scope + 无 override | `current_secret_scope() is None` | **DEBUG** | 启动初期，设计如此 |
| 有 scope 但读失败 | `current_secret_scope() is not None` | **WARNING + traceback** | **spawn 点漏了作用域**，是 bug |
| 其它异常 | — | WARNING | check_fn 自己炸了 |

**「同一个异常，两种含义」** 是很典型的陷阱。如果统一按 WARNING + traceback 处理，
启动日志会被刷满假警报（#100697）；如果统一按 DEBUG，真正的 spawn bug 就永远看不见。
所以**在 catch 点重新查一次作用域**来判断，而不是依赖「哪个分支调用了我」。

那句注释还点明了反面：

```python
# The verdict comes from the LIVE scope at the catch site, not from which registry branch
# ran the probe: ``no_cache_check_fn`` probes skip the cache-scope lookup entirely, so a
# branch-derived hint misreported every boot-time uncached probe as a lost scope (#110635).
```

**别用「谁调用的」推断状态，用「现在的实际状态」。**

---

## 5. Toolsets

### 5.1 一个 toolset 是什么

`TOOLSETS` 是**单一字典**（[`toolsets.py:74`](../toolsets.py:74)），每项形如：

```python
"web": _ts("Web research and content extraction tools", ["web_search", "web_extract"]),
```

```python
def _ts(description, tools=(), includes=(), **extra):
    """One TOOLSETS entry (fresh lists per entry; extra keys such as posture pass through)."""
    return {"description": description, "tools": list(tools), "includes": list(includes), **extra}
```

| 字段 | 含义 |
|---|---|
| `tools` | 直接包含的工具名 |
| `includes` | 引用其它 toolset（递归展开） |
| `platforms` | 这个 toolset 为哪些 session 平台而存在 |
| `posture` | 「姿势」：按会话自动选择，不回写进平台配置 |
| `module` | 关联的模块名（少数条目） |

**`list(tools)` 而不是直接用**：`_ts` 的 docstring 明说 `fresh lists per entry`，
防止调用方的列表被共享修改。

### 5.2 `_HERMES_CORE_TOOLS`（55 个）

[`toolsets.py:11`](../toolsets.py:11) 的注释本身就是设计说明：

```python
# Shared tool list for CLI and all messaging platform toolsets (edit once, all
# platforms follow). Desktop GUI affordances are deliberately NOT here: they live in
# `desktop_ui`/`project`, enabled per desktop-sourced session by the GUI gateway
# (tui_gateway/server.py::_load_enabled_toolsets). HA, kanban and computer_use
# entries are further gated by their tools' check_fns.
```

55 个工具按类别：

| 类别 | 工具 |
|---|---|
| web | `web_search` `web_extract` |
| 终端 | `terminal` `process_manage` |
| 文件 | `read_file` `write_file` `patch` `search_files` |
| 多模态 | `vision_analyze` `image_generate` `text_to_speech` |
| skills | `skills_list` `skill_view` `skill_manage` |
| browser | `browser_navigate` `browser_snapshot` `browser_click` `browser_type` `browser_scroll` `browser_back` `browser_press` `browser_get_images` `browser_vision` `browser_console` `browser_cdp` `browser_dialog` `browser_vault_*`(5) `browser_exec` |
| 协作 | `todo_list` `memory` `session_search` `clarify` |
| 编排 | `execute_code` `delegate_task` `cronjob_manage` |
| kanban | `kanban_show` `kanban_list` `kanban_complete` `kanban_block` `kanban_request_review` `kanban_request_changes` `kanban_heartbeat` `kanban_comment` `kanban_create` `kanban_link` `kanban_unblock` `kanban_attach` `kanban_attach_url` `kanban_attachments` |
| 其它 | `computer_use` `manage_connections` |

三个注释要点：

1. **桌面 GUI 能力故意不在这里** → 它们在 `desktop_ui` / `project`，由 GUI 网关按会话折叠进来
2. **HA / kanban / computer_use 还有 `check_fn` 二级门控** → 在清单里 ≠ 一定可见
3. **`browser_exec` 的注释**：`replaces the other browser tools when browser.backend is "browser-use"`

第 3 点值得单独说：这不是靠运行时判断，而是靠 `_DYNAMIC_SCHEMA_REWRITERS`（§6.3）
把其它 browser 工具从**定义列表里删掉**。

### 5.3 三个构造 helper

```python
def _bundle(description, extras=()):
    """A `hermes-*` platform bundle: the shared core tools plus optional platform extras."""
    return _ts(description, _HERMES_CORE_TOOLS + list(extras))

def _core_without(*excluded, kanban=True):
    """_HERMES_CORE_TOOLS minus *excluded* (and, unless kanban=True, every kanban_* tool); order preserved."""
    return [t for t in _HERMES_CORE_TOOLS if t not in excluded and (kanban or not t.startswith("kanban_"))]
```

`_core_without` 的 `kanban=False` 是**按前缀整体排除**，因为 kanban 有 14 个工具，
逐个列不可维护。

`_CODING_TOOLS`：

```python
# Coding posture: everything you reach for while pairing on code; drops messaging,
# tts, image_gen, cron, kanban and computer-use.
_CODING_TOOLS = _core_without("image_generate", "text_to_speech", "cronjob_manage", "computer_use", kanban=False)
```

### 5.4 `posture` 的语义

```python
"coding": _ts("Coding-focused toolset: ...", _CODING_TOOLS, posture=True),
```

注释：

```python
# Coding posture, auto-selected in a code workspace (agent/coding_context.py).
# `desktop_ui` is folded in separately by the GUI gateway for desktop sessions.
# posture=True: per-session posture, never auto-recovered into platform tool
# config (see the non-configurable-toolset recovery loop in hermes_cli/tools_config.py).
```

**`posture` = 「这是会话的姿势，不是用户配置」。**

区别很重要：

| | 普通 toolset | `posture=True` |
|---|---|---|
| 谁决定启用 | 用户配置（`hermes tools`） | 环境（当前目录是不是代码库） |
| 会写回 `config.yaml` 吗 | 会 | **不会** |
| 换个会话还在吗 | 在 | 重新判断 |

如果 posture 被写回配置，用户在一个代码仓库里跑一次 `hermes`，
他的 Telegram bot 也会变成 coding 姿势 —— 那是错的。

### 5.5 `platforms` 与 `TOOLSET_SESSION_PLATFORMS`

```python
"catalog": _ts("Desktop catalog plugin/skill install requests through the approval card (GUI sessions only)",
               ["manage_catalog"], platforms=frozenset({"desktop"})),
```

```python
TOOLSET_SESSION_PLATFORMS = {name: spec["platforms"] for name, spec in TOOLSETS.items() if "platforms" in spec}
```

两个下游用途：

**用途 1：`"all"` 不包含平台门控的 toolset**

```python
if name in {"all", "*"}:
    all_tools: set = set()
    for toolset_name in get_toolset_names():
        if toolset_name not in TOOLSET_SESSION_PLATFORMS:
            all_tools.update(resolve_toolset(...))
    return sorted(all_tools)
```

注释：`"all"/"*" span every toolset so new toolsets are included automatically, except the ones a
session platform gates: a profile gets those only when its config names them.`

**用途 2：`enabled_toolsets=None` 的默认路径**

```python
else:
    from toolsets import TOOLSET_SESSION_PLATFORMS, get_all_toolsets
    for ts_name in get_all_toolsets():
        if ts_name not in TOOLSET_SESSION_PLATFORMS:
            tools.update(resolve_toolset(ts_name))
```

**无配置时不给任何平台专属工具。** 因为「没有点菜」不等于「全都要」——
桌面目录安装能力不该出现在 Telegram 里。

### 5.6 平台 bundle 与反向减法

约 22 个 `hermes-<platform>` bundle：`hermes-cli`、`hermes-telegram`、`hermes-discord`、
`hermes-slack`、`hermes-signal`、`hermes-email`、`hermes-matrix`、`hermes-feishu`、
`hermes-weixin`、`hermes-qqbot`、`hermes-wecom`、`hermes-yuanbao`、`hermes-sms`、
`hermes-webhook`、`hermes-api-server`、`hermes-acp`、`hermes-cron`、
`hermes-gateway`（唯一嵌套的聚合包）……

#### 只有 `hermes-gateway` 做 include 嵌套

```python
"hermes-gateway": _ts("Gateway toolset - union of all messaging platform tools", [],
    includes=["hermes-telegram", "hermes-discord", ..., "hermes-yuanbao"]),
```

`resolve_toolset` 用 `visited` 集合做循环检测：

```python
# Diamond include or cycle: [] silently — the tools are collected via another path.
if name in visited:
    return []
```

**菱形包含静默返回空**，因为另一条路径已经收集了。

#### 插件平台自动获得隐式 bundle

```python
def _plugin_platform_bundle(name: str) -> list[str]:
    """Implicit `hermes-<platform>` bundle for a registered plugin platform: core
    tools plus whatever the plugin registered under the platform name. [] otherwise."""
    if not name.startswith("hermes-"):
        return []
    platform_name = name[len("hermes-"):]
    if not platform_registry.is_registered(platform_name):
        return []
    tools = set(_HERMES_CORE_TOOLS)
    tools.update(e.name for e in _registry_call("get_all_entries", ()) if e.toolset == platform_name)
    return list(tools)
```

**加一个平台适配器，自动就有 `hermes-<name>` 工具集，不用改 `toolsets.py`。**
这是「能力活在边缘」的又一处落地。

#### 反向减法的陷阱（重要）

`disabled_toolsets: [hermes-telegram]` 想做什么？停掉 Telegram 专属工具。

但如果直接 `tools.difference_update(resolve_toolset("hermes-telegram"))`，
你会把**55 个核心工具也减掉** —— 因为 bundle = 核心 + extras。

解法（[`_apply_toolset_selection`](../model_tools.py:282)）：

```python
if disable and (name.startswith("hermes-") or (get_toolset(name) or {}).get("posture")):
    # Bundles/postures re-list the core tools without owning them;
    # subtracting the whole set would empty the list — remove only the non-core delta.
    resolved = sorted(bundle_non_core_tools(name))
    if not quiet_mode and name.startswith("hermes-") and name not in _WARNED_DISABLED_BUNDLES:
        logger.info("agent.disabled_toolsets contains platform-bundle name '%s'; core tools are "
                    "preserved and only its platform-specific tools (%s) are removed. "
                    "Bundle names usually belong in `toolsets:`, not `disabled_toolsets` (#33924).", ...)
```

```python
def bundle_non_core_tools(toolset_name: str) -> set[str]:
    """A bundle's tools minus _HERMES_CORE_TOOLS (one level of includes).

    Disabling a `core + extras` bundle must not strip the core tools every other
    toolset shares. One `includes` pass suffices (only hermes-gateway nests
    bundles)."""
```

**核心洞见：bundle 里的核心工具是「继承」来的，不是「拥有」的。**
停用一个 bundle 只能移除它**额外带来**的部分。

顺带还打印了一条使用建议：bundle 名通常该放 `toolsets:`（正面启用），不是 `disabled_toolsets:`。

### 5.7 启用的顺序保证

```python
"""Disabled toolsets are always subtracted LAST, so a tool in a disabled
toolset is stripped even when a composite (hermes-cli) re-enables it.
This ensures that even if a composite toolset (like hermes-cli) is enabled, any tools belonging to a
disabled toolset are strictly stripped out. See issue #17309."""
```

```text
① 启用列表（可能是复合的 hermes-cli，展开出 55 个）
② 禁用列表（严格减法，最后执行）
```

如果顺序反过来（先减后加），`toolsets: [hermes-cli]` + `disabled_toolsets: [browser]`
会把 browser 工具加回来。**减法必须最后。**

### 5.8 `CLIENT_SURFACE_TOOLSETS`

```python
CLIENT_SURFACE_TOOLSETS = frozenset({"project", "desktop_ui", "catalog"})
```

注释：

```python
# Toolsets a CLIENT adds to its own sessions (tui_gateway/server.py::_gui_surface_toolsets), never
# config: another surface lacking them made no configuration choice.
```

**逻辑：桌面版有、Telegram 没有，不代表用户在 Telegram 里「关掉了」它。**
所以它们不该出现在配置界面里，也不该被当作「未启用」。

### 5.9 旧名兼容

```python
_LEGACY_TOOLSET_MAP = {
    "web_tools": ["web_search", "web_extract"],
    "terminal_tools": ["terminal"],
    ...
}
```

老配置里的 toolset 名仍然能解析。同样还有工具名别名：

```python
_LEGACY_TOOL_ALIASES = {
    **dict.fromkeys(TODO_LEGACY_ALIASES, TODO_SCHEMA["name"]),
    "cronjob": "cronjob_manage", "process": "process_manage",
    "tour": "gui_tour", "tip": "show_tip",
}
```

注释：`Legacy tool-name aliases accepted at every dispatch seam (old sessions/saved prompts keep
working); schemas advertise only new names.`

**重命名工具是一次数据库迁移**：历史会话里存着 `"cronjob"`，重放时会请求一个不存在的名字。
别名层让旧会话继续工作，而新 schema 只用新名。

### 5.10 `resolve_toolset` 的三重 memo key

```python
_resolve_toolset_memo: dict[tuple[str, bool, int, int, str], list[str]] = {}

# Memo keyed on (name, include_registry, id(registry), registry generation, profile scope);
# engages only at the public entry (visited is None). The scope is part of the key because a
# multiplexed process resolves ``mcp-<server>`` per profile overlay: without it profile B got
# profile A's tool names for a server B never connected (#106005).
```

| key 分量 | 防的是什么 |
|---|---|
| `name` | 不同 toolset |
| `include_registry` | 静态视图 vs 含注册表 |
| `id(registry)` | 测试里换了 registry 实例 |
| `registry generation` | 注册表变了 |
| **`profile scope`** | **multiplex 串号** |

第 5 个是踩过坑的（注释带 issue 号）。**凡是有 per-profile 行为的缓存，key 必须含 scope。**

```python
external_call = visited is None
```

**只在外部入口 memo** —— 递归调用带 `visited`，此时结果依赖于调用路径，不能缓存。

`include_registry=False` 的用途也值得记：

```python
"""Platform reverse-mapping uses False so a registry-added tool cannot drop the
whole toolset from inference (see #49622 and ``_get_platform_tools``)."""
```

---

## 6. 定义装配：`get_tool_definitions()`

主入口 [`model_tools.py:214`](../model_tools.py:214)。完整流水线在 `_compute_tool_definitions`：

```text
①_选择   _select_tool_names(enabled, disabled)         → set[str]
②_过滤   registry.get_definitions(set)                 → check_fn 过滤 → list[schema]
③_动态   _apply_dynamic_schemas(...)                   → 重写/删除个别 schema
④_净化   sanitize_tool_schemas(...)                    → llama.cpp 兼容
⑤_折叠   assemble_tool_defs(...)                       → Tool Search
⑥_缓存   按 9 元组 key 缓存，返回浅拷贝
```

### 6.1 ①选择

```python
tools: set = set()
if enabled_toolsets is not None:
    enabled = list(enabled_toolsets)
    if (os.environ.get("HERMES_KANBAN_TASK") and not _is_delegated_child_context()
            and _is_dispatcher_owned_worker() and "kanban" not in enabled):
        enabled.append("kanban")
    _apply_toolset_selection(tools, enabled, quiet_mode, disable=False)
else:
    for ts_name in get_all_toolsets():
        if ts_name not in TOOLSET_SESSION_PLATFORMS:
            tools.update(resolve_toolset(ts_name))
if disabled_toolsets:
    _apply_toolset_selection(tools, disabled_toolsets, quiet_mode, disable=True)
```

**kanban 那个自动追加**很值得看：dispatcher 派生的 worker 即使 assignee profile 收窄了
chat 工具集，也必须拿到生命周期交接工具。否则 worker 干完活没法标记完成。

注释：`Dispatcher-spawned kanban workers always get the lifecycle handoff tools, even when the
assignee profile restricts its chat toolsets.`

**注意那个 `not _is_delegated_child_context()`** —— 委派子进程不加，因为它的活由父代理收尾。

### 6.2 ②过滤（`check_fn`）

```python
check_results: dict[Callable, bool] = {}
for name in sorted(tool_names):
    entry = entries_by_name.get(name)
    if not entry:
        continue
    if entry.check_fn and not _memo_check(entry.check_fn, check_results):
        continue
```

两个细节：

1. **`sorted(tool_names)`** —— 输出顺序确定，让 schema 数组字节稳定（04 篇的缓存铁律）
2. **`check_results` 局部 memo** —— 多个工具共享同一 `check_fn` 时本次装配只跑一次

### 6.3 ③动态 schema

```python
_DYNAMIC_SCHEMA_REWRITERS = {
    "execute_code": _rewrite_execute_code,
    "discord": _discord_rewriter("get_dynamic_schema_core"),
    "discord_admin": _discord_rewriter("get_dynamic_schema_admin"),
    "browser_navigate": _rewrite_browser_navigate,
    "browser_cdp": _rewrite_browser_cdp,
    "browser_exec": _compose_rewriters(_rewrite_browser_exec, _rewrite_input_tool_for_vault),
    "browser_type": _rewrite_input_tool_for_vault,
    "browser_vault_list": _rewrite_browser_vault,
    "browser_vault_fill": _rewrite_browser_vault,
    "delegate_task": _rewrite_delegate_task,
}
```

```python
def _apply_dynamic_schemas(tool_defs):
    """Apply _DYNAMIC_SCHEMA_REWRITERS in list order; the availability set is a
    snapshot taken before any rewrite (no rewriter's inputs are droppable)."""
    available = {t["function"]["name"] for t in tool_defs}
    out = []
    for td in tool_defs:
        rewrite = _DYNAMIC_SCHEMA_REWRITERS.get(td["function"]["name"])
        if rewrite is not None:
            td = rewrite(td, available)
        if td is not None:
            out.append(td)
    return out
```

**「可用集合在任何重写之前快照」** 是防顺序依赖的关键：

```text
若 A 的重写删掉了 B：available 里还有 B → B 仍能引用 B（错）
若 B 的重写删掉了 A：A 的重写已经跑过 → A 的引用消失（错）
```

先快照就没有这个问题。这是**「批量变换要用一致的输入视图」** 的通用原则。

四个真实用途：

| rewriter | 做什么 |
|---|---|
| `_rewrite_execute_code` | 把可用工具名写进 `execute_code` 的 description（模型知道沙箱里能调什么） |
| `_discord_rewriter` | 按 guild 的实际上限裁剪 `limit` 的 maximum |
| `_rewrite_browser_navigate` | 只在 `web_search` 可用时才推荐它 |
| `_rewrite_browser_exec` | `browser-use` 后端时**删除**其它 browser 工具 |
| `_rewrite_delegate_task` | 把并发上限、可用 profile 写进描述 |

这正好解释了 §11 那条铁律「schema 描述里不得提及其它 toolset 的工具名」的**反面**：
**允许**提，但必须**动态**提。

```python
# Each rewriter gets (tool definition, set of tool names that passed check_fn)
# and returns the (possibly replaced) definition, or None to drop the tool.
# Cross-references must use that set so the model never hears of an absent tool.
```

### 6.4 ④净化

```python
# Normalize schema shapes llama.cpp's grammar converter rejects (bare
# "type": "object", string-valued nodes from malformed MCP servers).
try:
    from tools.schema_sanitizer import sanitize_tool_schemas
    filtered_tools = sanitize_tool_schemas(filtered_tools)
except Exception as e:
    logger.warning("Schema sanitization skipped: %s", e)
```

**为什么需要「净化」？** 因为 schema 有三个来源，质量不一：

| 来源 | 质量 |
|---|---|
| 内置工具 | 手写，通常正确 |
| 插件 | 作者水平不一 |
| **MCP 服务器** | 第三方，可能产出畸形 JSON Schema |

`llama.cpp` 的 grammar converter 对 schema 很挑剔，
一个 `"type": "object"` 没有 `properties` 就可能整个请求失败。
在这里统一修形，比让每个后端自己容错便宜。

### 6.5 ⑤折叠（Tool Search）

见 §7。

### 6.6 ⑥缓存

```python
def _tool_defs_cache_key(enabled_toolsets, disabled_toolsets, skip_tool_search_assembly):
    """Memo key for get_tool_definitions, or None when caching must be bypassed.

    Covers every argument plus everything that changes the result without one:
    registry generation, config.yaml stat signature (dynamic schemas), kanban
    context, profile scope. check_fn results are TTL-cached in the registry."""
    profile_scope = check_fn_cache_scope()
    if profile_scope == CHECK_FN_CACHE_BYPASS:
        return None
    ...
    return (
        registry.current_scope_key(),
        frozenset(enabled_toolsets) if enabled_toolsets is not None else None,
        frozenset(disabled_toolsets) if disabled_toolsets else None,
        registry._generation,
        cfg_fp,
        bool(os.environ.get("HERMES_KANBAN_TASK")),
        bool(skip_tool_search_assembly),
        _is_delegated_child_context(),
        _is_dispatcher_owned_worker(),
        profile_scope,
    )
```

**九个分量，每个都是一个「会改结果但没有对应参数」的东西。**

这个函数是本篇最好的教材：**缓存 key 必须覆盖「所有影响输出的隐式输入」**。
少一个，就会出现“我改了配置但没生效”这类玄学 bug。

`cfg_fp = file_signature(cfg_stat)` 用的是 `config.yaml` 的 **mtime + size**，
所以 `hermes tools enable browser` 之后**下一次装配立刻生效**，不需要重启。

#### 三条必须记住的注释

**（1）为什么返回浅拷贝**

```python
# Cache the freshly-computed list, but hand callers a shallow copy so downstream mutations (e.g.
# run_agent appending memory/LCM tool schemas to self.tools) don't poison the cache. Without this, a
# long-lived Gateway process accumulates duplicate tool names across agent inits and providers that
# enforce unique tool names (DeepSeek, Xiaomi MiMo, Moonshot Kimi) reject the request with HTTP 400.
```

**「长命进程 + 缓存引用被改 = 名字不断累积」**。第 2 次 agent init 时，
`run_agent` 往列表里 append 记忆工具 → 缓存里也多了 → 第 3 次再多一份 → …
DeepSeek/Kimi 对重复工具名直接 400。

**（2）为什么 LRU 8 条**

```python
# Bound the cache with LRU eviction so a long-lived Gateway process doesn't accumulate entries
# unboundedly across the many distinct toolset/config fingerprints it sees over its lifetime (#19251).
```

一个网关可能服务几十个 profile × 几十种 toolset 组合。不做上限就是内存泄漏。

**（3）`_last_resolved_tool_names` 是进程全局**

```python
global _last_resolved_tool_names
_last_resolved_tool_names = [t["function"]["name"] for t in filtered_tools]
```

它给 `execute_code` 用（沙箱里可以调哪些工具）。**进程全局意味着并发时会串**。
[`tools/AGENTS.md:65`](../tools/AGENTS.md:65)：

> **`_last_resolved_tool_names`** is a process-global in `model_tools.py`; `_run_single_child()` in
> `delegate_tool.py` saves/restores it around child runs — readers may see it stale mid-delegation.

**一个已知的、被显式记录的妥协。** 委派时 save/restore，但中途读者可能看到旧值。
这类「已知不完美」必须写进文档，否则下一个人会以为是 bug。

---

## 7. Tool Search：渐进披露

### 7.1 问题

MCP 配置了 5 个服务器、每个 30 个工具 = 150 个工具。加上插件 = 200+。

```text
200 × 700 token ≈ 140K token 的 schema
```

一个 200K 上下文的模型，光工具定义就吃掉 70% —— 还没开始对话。

### 7.2 解法：三桥 + 目录

[`tools/tool_search.py:1`](../tools/tool_search.py:1)：

```python
"""Progressive tool disclosure ("tool search"): MCP/plugin tools and a curated set of
event-triggered core tools are replaced in the model-visible array by three bridge tools —
tool_search / tool_describe / tool_call. Invariants: core tools (``toolsets._HERMES_CORE_TOOLS``)
and session-gated GUI toolsets never defer unless named in ``defer``; ANY deferrable tool
activates the bridge (the listing scales with budget, not activation); the catalog is
stateless — rebuilt from the live tool-defs every assembly (a session-keyed one drifts and
silently drops tools); bridge calls route through ``model_tools.handle_function_call``."""
```

```text
折叠前:  [55 core] + [150 MCP] + [20 plugin]          → 225 个 schema
折叠后:  [55 core] + [tool_search, tool_describe, tool_call]  → 58 个 schema
                        ↑ 目录写在这三个的 description 里
```

### 7.3 谁可以被折叠

```python
def is_deferrable_tool_name(name, defer_tools=None) -> bool:
    """True if a tool is *eligible* for deferral: named in ``defer_tools`` (curated set or
    user override), OR an MCP tool, OR neither core nor a session-gated GUI surface (i.e. a
    plugin tool). Bridge names never defer."""
    if name in BRIDGE_TOOL_NAMES:
        return False
    if defer_tools is not None and name in defer_tools:
        return True
    if name in _core_tool_names():
        return False
    toolset = _registry_toolset(name)
    return toolset is not None and (
        toolset.startswith("mcp-") or toolset not in _DIRECT_SURFACE_TOOLSETS)
```

三条判据，按顺序：

| 判据 | 结果 |
|---|---|
| 是桥接工具本身 | 永不折叠 |
| 在 `defer` 清单里 | 折叠（**可以点名折叠核心工具**） |
| 是核心工具 | 永不折叠 |
| toolset 以 `mcp-` 开头 | 折叠 |
| toolset 不在 GUI 直连集合 | 折叠（插件工具） |
| 未注册 / 畸形 | 不折叠 |

**为什么核心工具默认不折叠？** 因为它们是「每个任务都大概率用到」的。
把 `read_file` 藏起来，模型每读一个文件都要先 `tool_search` —— 多一次往返。

`_DEFAULT_DEFERRED_TOOLS` 来自配置默认值（`DEFAULT_CONFIG["tools"]["tool_search"]["defer"]`），
是一个**精选清单**：那些「只在特定事件下才用」的核心工具（如 `cronjob_manage`、
`image_generate`）。

### 7.4 什么时候激活

```python
def should_activate(config, deferrable_tokens, context_length, *, connections_granted=False) -> bool:
    """``"off"`` never activates; ``"on"``/``"auto"`` activate whenever any deferrable tool
    exists ("auto" is reserved for a future budget-gated mode — do not distinguish them
    without that design). ``context_length`` is kept for caller compatibility."""
    if config.enabled == "off":
        return False
    if deferrable_tokens > 0:
        return True
    return connections_granted
```

**任何可折叠工具存在就激活。**

注意那句 **`"auto" is reserved for a future budget-gated mode — do not distinguish them without
that design`** —— 这是一个明确写下来的「暂不实现」约定，防止有人看到 `auto` 就以为是
「按预算决定」而去加逻辑。

`context_length` 参数是历史遗留（`kept for caller compatibility`），保留但它不门控。

### 7.5 tier 与 listing 降级

```python
listing_budget = listing_token_budget(config, context_length)
if config.listing != "off":
    listing, listing_form = build_catalog_listing_with_form(deferrable, max_tokens=listing_budget)
bridge = bridge_tool_schemas(len(deferrable), listing=listing, listing_form=listing_form, ...)
tier = 1 if listing_form in ("full", "names", "mixed") else 2
```

| tier | listing_form | 含义 |
|---|---|---|
| **1** | `full` | 完整目录（名字 + 描述）写进 description |
| **1** | `names` | 只有名字 |
| **1** | `mixed` | 超大服务器被压缩成摘要 |
| **2** | `groups` | 只给服务器摘要，全靠 search |
| **2** | `none` | 完全没有目录 |

```python
def listing_token_budget(config, context_length) -> int:
    """``min(listing_max_tokens, threshold_pct% of context)``; unknown context uses a 10K
    percentage leg (5% of a typical 200K window)."""
    pct_leg = (int(context_length * (config.threshold_pct / 100.0))
               if context_length and context_length > 0 else 10_000)
    return max(0, min(config.listing_max_tokens, pct_leg))
```

**目录预算 = 绝对上限（4000 token）与上下文百分比取小。**

这是「渐进披露」的核心：**能塞多少细节就塞多少，塞不下就降级**，而不是
「要么全塞要么不塞」。

### 7.6 catalog 必须无状态

```python
"""... the catalog is stateless — rebuilt from the live tool-defs every assembly (a
session-keyed one drifts and silently drops tools)"""
```

**「session-keyed 会漂移并静默丢工具」** —— 想象一下：
会话开始时建立目录，中途 MCP 服务器重连加了工具，会话内的目录不知道 →
模型永远搜不到新工具，而且没有任何报错。

每次从**当前 tool_defs** 重建，是唯一不会漂移的做法。

### 7.7 桥接调用如何回到正常派发

[`handle_function_call`](../model_tools.py:872)：

```python
# Tool Search bridge: tool_search / tool_describe are catalog reads handled
# inline; tool_call is unwrapped so every downstream hook (pre/post, edit
# approval, guardrails) sees the real tool name, never the bridge.
bridged = _dispatch_bridge_tool(function_name, function_args, enabled_toolsets, disabled_toolsets)
if bridged is not None:
    result, underlying = bridged
    if underlying is None:
        return _emit(result, duration_ms=_elapsed_ms(start))
    ...
    return handle_function_call(
        *underlying, **asdict(ids), user_task=user_task, ...)
```

**`tool_call` 被「解包」后递归调回 `handle_function_call`。**

为什么必须递归？因为下游有一整条流水线（hooks、审批、guardrail、观察）。
如果在桥接层直接调 `registry.dispatch()`，**所有安全机制都被绕过**。

注释写得很直白：`every downstream hook (pre/post, edit approval, guardrails) sees the real
tool name, never the bridge`。

`skip_pre_tool_call_hook` 等标志被**原样传递**，保证「单次触发」契约不被破坏。

### 7.8 两条限制

```python
# Bound the work one bridge call requests. Search is capped at the gateway's
# own limit: the connector search route answers 7 use_cases per request and
# returns HTTP 502 for 8 or more (measured 2026-09-09), and one local call
# maps to one gateway request. Describe has no such remote limit.
_MAX_QUERIES_PER_CALL = 7
_MAX_DESCRIBE_NAMES_PER_CALL = 10
```

**「measured 2026-09-09」** —— 一个实测得到的硬限制，写进代码并注明日期。
这类约束无法从文档推导，只能靠注释传承。

---

## 8. 分发：`handle_function_call()`

### 8.1 完整流水线

[`model_tools.py:872`](../model_tools.py:872)：

```text
模型 tool_call(name, args)
  │
  ①  参数矫正        coerce_tool_args(name, args)
  ②  别名归一        _LEGACY_TOOL_ALIASES
  ③  桥接解包        _dispatch_bridge_tool → 递归回 ①
  ④  connector 校验  is_connector_name / manage_connections 的会话授权
  ⑤  request 中间件  _apply_request_middleware（插件可改参数）
  ⑥  循环工具拒绝    _AGENT_LOOP_TOOLS 直接报错
  ⑦  前置守卫        _pre_dispatch_guards（pre_tool_call hook + ACP 编辑审批）
  ⑧  读循环计数重置  notify_other_tool_call
  ⑨  执行            _execute_tool → inline 表 或 registry.dispatch
  ⑩  后置 hook       _emit_post_tool_call_hook
  ⑪  结果变换        _apply_transform_tool_result_hook
  │
  └─► JSON 字符串
```

### 8.2 为什么「循环工具」要被拒绝

```python
_AGENT_LOOP_TOOLS = {"todo_list", "memory", "session_search", "delegate_task"}

if function_name in _AGENT_LOOP_TOOLS:
    return tool_error(f"{function_name} must be handled by the agent loop")
```

这四个工具**必须在 agent 循环里执行**，因为它们要：
- 改 agent 自己的状态（`todo_list`、`memory`）
- 或者启动一个子代理（`delegate_task`）

如果走到 registry 分发，说明调用路径错了（比如某个插件直接调 `handle_function_call`）。
**明确报错比让它「看起来能跑但状态不对」好。**

### 8.3 前置守卫：两道闸门

```python
def _pre_dispatch_guards(function_name, function_args, skip_pre_tool_call_hook, ids, middleware_trace):
    """Plugin pre_tool_call hook, then ACP edit approval.

    ``(args, None)`` to proceed (args possibly plugin-modified), or
    ``(args, (result, error_type, error_message))`` when blocked."""
```

**闸门 1：插件 `pre_tool_call` hook**

```python
# pre_tool_call fires exactly once per execution: one invoke_hook pass yields
# both the block message and modified args. skip=True: caller already fired it.
if not skip_pre_tool_call_hook:
    block_message, modified_args = _dispatch_pre_tool_call_hooks(...)
    if modified_args is not None:
        function_args = modified_args
```

**注意「一次 pass 同时返回 block 和 modified_args」**。
如果设计成两次调用（先问「拦不拦」再问「改不改」），插件作者就得写两遍逻辑，
而且两次调用之间状态可能变。

**闸门 2：ACP 编辑审批**

```python
# ACP/Zed edit approval before any file mutation. The requester is bound
# via ContextVar only for ACP sessions, so CLI/gateway paths are unaffected.
try:
    from acp_adapter.edit_approval import maybe_require_edit_approval
    edit_block_message = maybe_require_edit_approval(function_name, function_args)
    ...
except Exception as _edit_approval_err:
    logger.debug("ACP edit approval guard error: %s", _edit_approval_err)
    if function_name in {"write_file", "patch"}:
        return function_args, (tool_error("Edit approval denied: approval guard failed"), "edit_approval_error", None)
```

**异常处理是 fail-closed 的**：审批守卫自己崩了，写文件一律拒绝。

这是整个仓库里少数**故意 fail-closed** 的地方 —— 因为另一侧是「未经审批修改用户的文件」。

### 8.4 结果契约

所有 handler 返回 **JSON 字符串**。唯一例外是多模态信封：

```python
def _normalize_handler_result(name, result):
    """Results must be a string or the multimodal envelope; anything else becomes a
    string error so logging/hooks/budgeting/persistence never receive values they
    cannot slice or size."""
    if isinstance(result, str):
        return _bound_json_error_result(result)
    if (isinstance(result, dict) and result.get("_multimodal") is True
            and isinstance(result.get("content"), list)):
        return result
    ...
    return tool_error(f"Tool handler returned unsupported result type: {result_type}", ...)
```

```python
{"_multimodal": True, "content": [text, image_url, ...], "text_summary": str}
```

**「must be a string」不是洁癖**：下游有日志、hook、预算计算、持久化，
它们全都要 `len()` / 切片 / 正则。一个 dict 会在这里全炸。

### 8.5 错误边界三层

| 层 | 机制 | 上限 |
|---|---|---|
| handler 自己 | `tool_error(...)` | — |
| `_bound_json_error_result` | 修剪 JSON 里超大的 `error` 字段 | 2048 字符 |
| 日志 | `_MAX_LOGGED_ERROR_CHARS` | 8192 字符 |

```python
def _bound_json_error_result(result: str) -> str:
    """Trim an oversized ``error`` field in a JSON string result: handlers that
    ``json.dumps({"error": str(exc)})`` directly bypass ``tool_error``'s cap, so this runs
    at the dispatch boundary to stop unbounded errors stacking across retries."""
```

**「across retries」** 是关键：一次大错误进上下文，后续每轮都要重传它（04 篇）。
一个 50KB 的 traceback 会让整个会话的成本翻倍。

为什么日志留 8192 而上下文只留 2048？**日志给人看，上下文给模型看**，
人的耐心比模型的上下文宽。

### 8.6 异常转错误

```python
except Exception as e:
    logger.exception("Tool %s dispatch error: %s", name, _bound_error_text(str(e)))
    # Sanitize so framing tokens/CDATA/fences in exception text aren't structural noise.
    raw = f"Tool execution failed: {type(e).__name__}: {e}"
    try:
        from model_tools import _sanitize_tool_error
        sanitized = _sanitize_tool_error(raw)
    except Exception:
        sanitized = raw
    return tool_error(sanitized)
```

**「framing tokens / CDATA / fences」** —— 如果异常信息里含有 `<tool_result>` 或 ` ``` `，
模型可能把它当结构标记而不是内容。这是**提示注入的防御面**。

那句 `except Exception: sanitized = raw` 的注释也值得记：

```python
except Exception:
    sanitized = raw  # defensive: never let the sanitizer block error propagation
```

**「清理器崩了不能吞掉错误本身」。** 这是防御的防御。

### 8.7 插件 handler 的签名兼容

```python
# Plugin contract (plugins/AGENTS.md): optional context kwargs (task_id, session_id, user_task,
# parent_agent, ...) are signature-inspected like hook payloads, so a narrow ``handle(args)``
# plugin handler is not broken by every field the dispatcher injects (#68318).
kwargs = _kwargs_accepted_by(entry.handler, kwargs)
```

**分发器注入十几个上下文参数，但 handler 只声明它需要的。**

```python
def handle(args):                    # 老插件：完全不受影响
def handle(args, task_id=None):      # 需要 task_id 的就拿到
```

这和 React 的 props 有点像：父组件把一堆 props 传下来，子组件只用它解构的那几个。
**区别是这里做了运行时签名检查**，因为插件可能是不受控的第三方代码。

---

## 9. 两条派发路径

本仓库有**两条**工具执行路径，容易混：

| | 顺序路径 | 并发路径 |
|---|---|---|
| 场景 | 单 tool_call / 需要严格顺序 | 多个独立 tool_call |
| 入口 | `execute_tool_calls_sequential` | `invoke_tool` |
| inline 表 | `INLINE_TOOL_EXECUTORS`（全量） | `resolve_invoke_tool_executor`（有优先级） |

### 9.1 inline 表的存在理由

[`agent/inline_tool_executors.py:1`](../agent/inline_tool_executors.py:1)：

```python
"""Agent-level ("inline") tool executors shared by the sequential and concurrent tool paths.

These tools need live ``AIAgent`` state (stores, callbacks, session DB) and therefore
bypass the tool registry. Each executor is ``fn(agent, args, ctx) -> result``; the
table replaces two hand-maintained if/elif chains (``invoke_tool`` and
``execute_tool_calls_sequential``) that had drifted apart. Tool modules are imported
lazily at call time so ``patch("tools.x.y")`` in tests keeps working.
"""
```

**三句话，三个教训：**

1. **这些工具需要活的 agent 状态**（`agent._todo_store`、`agent.clarify_callback`）
2. **表替换了两条手写 if/elif 链** —— 而它们**已经漂移了**（drifted apart）
3. **工具模块在调用时惰性 import**，让测试里的 `patch("tools.x.y")` 仍然有效

第 2 点是本仓库最常引用的重构理由：**重复的分支逻辑必然漂移**。
把两条路径合并成一张表，是修 bug 而不是清理代码。

### 9.2 表里有什么

```python
_RAW_INLINE_TOOL_EXECUTORS = {
    "todo_list": _tool("tools.todo_tool", "todo_tool", ..., store=lambda agent, ctx: agent._todo_store),
    # Bot Mode teammate DM is injected, not registered: only a canonical Bot
    # Chat session carries the schema, and the tool re-gates on the title.
    "message_agent": _tool("tools.bot_mode_dm", "message_agent_tool", ...),
    "session_search": _session_search,
    "memory": _memory,
    "clarify": _tool("tools.clarify_tool", "clarify_tool", ..., callback=lambda agent, ctx: agent.clarify_callback),
    "read_terminal": _callback_tool(...),
    "desktop_preview": _desktop_preview,
    "drive_preview": _callback_tool(...),
    "annotate_preview": _callback_tool(...),
    ...
}
```

```python
INLINE_TOOL_EXECUTORS = {name: _coerced(name, executor) for name, executor in _RAW_INLINE_TOOL_EXECUTORS.items()}
```

`_coerced` 统一加参数矫正，**所以每条路径的参数处理一致**（而手写链做不到）。

### 9.3 并发路径的优先级

```python
# ``invoke_tool`` (concurrent path) consults the memory manager right after these three
# names and before the remaining inline tools; ``message_agent`` falls through to the
# registry there (Bot Mode DM is only injected into the sequential path's schema).
INVOKE_TOOL_PRE_MEMORY_MANAGER_NAMES = frozenset({"todo_list", "session_search", "memory"})

def resolve_invoke_tool_executor(agent, function_name):
    """Precedence: todo_list/session_search/memory, then memory-manager tools, then the
    remaining inline tools (``message_agent`` excluded)."""
    if function_name in INVOKE_TOOL_PRE_MEMORY_MANAGER_NAMES:
        return INLINE_TOOL_EXECUTORS[function_name]
    ...
```

```text
① todo_list / session_search / memory   ← 必须先于 memory manager
② memory manager 提供的工具              ← 动态注册的外挂
③ 其余 inline 工具                        ← 但排除 message_agent
④ registry.dispatch
```

**为什么这三个必须在 memory manager 之前？**
因为 memory manager（外部记忆 provider）可能也注册了同名工具。
内置实现必须优先，否则用户的记忆行为会被插件悄悄替换。

**为什么 `message_agent` 在并发路径被排除？**
因为 Bot Mode DM **只在顺序路径的 schema 里注入**。并发路径根本不该看到它。

---

## 10. 加工具：两条路

### 10.1 判断该走哪条（Footprint Ladder）

```text
我需要一个新能力
  │
  ├─ 现有的 terminal + read_file 能做吗？        → 用技能（skill）写清楚怎么做
  ├─ 只是我本地要用的？                          → 插件（~/.hermes/plugins/）
  ├─ 整个社区都会用，而且是外部服务？            → MCP 服务器（plugin-catalog）
  └─ 根本能力，无法通过其它方式获得？            → 核心工具（最后的选择）
```

根 `AGENTS.md`：

> **The core is a narrow waist; capability lives at the edges.** Every model tool is sent on
> every API call, so the bar for a new *core* tool is high.

### 10.2 插件路线（99% 的情况）

```text
~/.hermes/plugins/my-tool/
├── plugin.yaml
└── __init__.py
```

```python
# __init__.py
def register(ctx):
    ctx.register_tool(
        name="my_tool", toolset="my_plugin",
        schema={...}, handler=my_handler,
        check_fn=lambda: bool(get_secret("MY_KEY")),
    )
```

**不用碰 `tools/` 或 `toolsets.py`。** 插件工具集自动被 `resolve_toolset` 发现（§5.6）。

细节见 [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md)。

### 10.3 核心路线（两步，但门槛高）

**步骤 1：`tools/your_tool.py`**

```python
from agent.secret_scope import get_secret
from tools.registry import registry
import json

def check_requirements() -> bool:
    return bool(get_secret("EXAMPLE_API_KEY"))

def example_tool(param: str, task_id: str = None) -> str:
    return json.dumps({"success": True, "result": ...})

registry.register(
    name="example_tool",
    toolset="example",
    schema={"name": "example_tool", "description": "...", "parameters": {...}},
    handler=lambda args, **kw: example_tool(param=args.get("param", ""), task_id=kw.get("task_id")),
    check_fn=check_requirements,
    requires_env=["EXAMPLE_API_KEY"],
)
```

**步骤 2：`toolsets.py`**

```python
# 全平台默认：
_HERMES_CORE_TOOLS = [..., "example_tool"]

# 或只给某个工具集：
"example": _ts("Example capabilities", ["example_tool"]),
```

[`tools/AGENTS.md:40`](../tools/AGENTS.md:40)：

> **Required** — discovery registers the schema, but a tool is only exposed if a toolset names it.
> `_HERMES_CORE_TOOLS` is the default bundle every platform's base toolset inherits, not dead code.

**这是初学者最常卡住的地方**：写完 `registry.register()`，跑起来发现模型看不见。

```text
registry.register()  →  工具「存在」
toolset 收录         →  工具「可见」   ← 缺这一步等于没写
```

再补一句：**别忘了 `check_fn` 返回 False 也不可见。** 三步都要通过。

### 10.4 加完还要做三件事

| 事项 | 为什么 |
|---|---|
| 接入 `hermes tools` / `hermes setup` | 用户要能启用它、填 key |
| secrets 进 `OPTIONAL_ENV_VARS` | 让 `hermes setup` 指导用户 |
| 加测试 | §12 |

---

## 11. 硬规则清单

[`tools/AGENTS.md:44`](../tools/AGENTS.md:44) 的完整版。

| 规则 | 原因 | 反例 |
|---|---|---|
| **schema 描述里不得静态提及其它 toolset 的工具名** | 那个工具可能不可用，模型会幻觉调用 | `browser_navigate` 说「优先用 `web_search`」 |
| **路径用 `display_hermes_home()`** | schema 在 import 时构建；multiplex 下是启动 home | `f"{Path.home()}/.hermes/x"` |
| **状态文件用调用时的 `get_hermes_home()`** | 每个被服务的 profile 有自己的状态 | 模块级常量路径 |
| **教学类工具不加 `offset`/`limit` 分页** | 模型读完第 1 页就跳过其余 | `skills_list(offset=0, limit=20)` |
| **`check_fn` 只回答可达性** | 一进程多 session 多 profile | 判断 `platform == "desktop"` |
| **凭证用 `get_secret()`，不用 `os.getenv()`** | 后者拿启动 profile 的 `.env` | `os.getenv("KEY")` |
| **新工具接入现有 setup UX** | 而不是一个裸 env var | 让用户手动 export |
| **加后端 = 新 sibling / 表项** | 不是 `elif backend == ...` | `if backend=="docker": ... elif ...` |

### 11.1 「加后端 = 新表项」为什么重要

[`tools/AGENTS.md:81`](../tools/AGENTS.md:81)：

> Several tools front pluggable backends: terminal environments in `tools/environments/`
> (local, docker, ssh, modal, daytona, singularity), browser (`browser_tool_*.py`: cdp, cloud,
> install, lifecycle, session, real_profile, vision), MCP client (`mcp_tool_*.py`: config,
> discovery, transport, registration, content, errors), TTS (`tts_tool_providers.py`,
> `tts_command_provider.py`)... **Adding a backend = a new sibling or provider entry in the
> existing table, never an `elif` on a backend name (root shape rules).**

`elif` 链的问题不是丑，是**每一处新增都要改每一处判断**：

```text
if backend == "docker":      # 加 ssh 时这里要改
elif backend == "ssh":       # 加 modal 时这里要改
...
# 再加上：env 构建、能力探测、超时、清理 —— 每个都是独立的 elif 链
```

六个后端 × 五处判断 = 30 个需要同步修改的点。**表驱动把这个降到 1。**

### 11.2 三个工具特有的坑

**（1）`_last_resolved_tool_names` 是进程全局**（§6.6）

**（2）vision 的图片嵌入是历史，不是一次性负载**

[`tools/AGENTS.md:90`](../tools/AGENTS.md:90)：

> **Native vision embeds are history, not one-shot payloads.** `vision_tools.py::_vision_analyze_native`
> ... bake the image into a tool result that is re-sent on every later API call.

一张 1MB 的截图 base64 后 ≈ 350K 字符。**它进了 messages 就每轮都发。**
所以有 `vision_tools_history_budget.py`（`embed_target_bytes`、`max_calls_per_image`）。

**（3）每个 spawn 走同一个 env builder**

[`tools/AGENTS.md:98`](../tools/AGENTS.md:98)：

> **Every spawn goes through one env builder.** `environments/local.py::build_subprocess_env` ...
> `os.environ.copy()` / `dict(os.environ)` pins the launch profile; contextvars do not cross
> process boundaries, so resolve before `Popen`.

**「contextvars 不跨进程边界」** —— 这是 Python 的硬事实，也是 multiplex 最容易漏的地方。
子进程要么被显式传入环境变量，要么拿到父进程的 `os.environ`（= 启动 profile）。
详见 [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)。

---

## 12. 测试约定

| 约定 | 理由 |
|---|---|
| 放 `tests/tools/` | 镜像源码树（`tests/AGENTS.md`） |
| **通过 registry 测 handler**（真实派发） | 只测裸函数会漏掉参数矫正、hook、错误包装 |
| 断言**契约**而不是数量 | 「每个注册工具都有 toolset」「没有 schema 静态引用其它 toolset」 |
| 审批/安全边界用真实 import + 临时 `HERMES_HOME` 做 E2E | 假 mock 测不出作用域泄露 |

**为什么不能断言工具数量？** [`tools/AGENTS.md:75`](../tools/AGENTS.md:75)：

> `TOOLSETS` dict. Keys today: ... (**don't assert the list in tests**)

那是**变更检测器**（change detector），不是行为契约。加一个工具就让测试红，
团队会习惯性地去改测试而不是看代码 —— 测试就失去了意义。

**该断言的契约长什么样：**

```python
def test_every_registered_tool_has_a_toolset():
    for entry in registry.get_all_entries():
        assert entry.toolset, f"{entry.name} has no toolset"
        assert entry.name in resolve_toolset(entry.toolset)   # 真的被收录

def test_schema_descriptions_do_not_name_other_toolsets_tools():
    # 静态引用会让模型幻觉调用不可用的工具
    ...
```

---

## 13. 自检题

1. 模型「看到」一个工具，具体看到的是什么？（§0.1）
2. 为什么工具数量是成本问题？55 个工具大概多少 token？（§0.2）
3. 为什么 `tools/registry.py` 必须零内部依赖？它怎么对 `hermes_constants` 也保持零依赖？（§1.1）
4. `register()` 的 `description=` 和 `schema["description"]`，哪个给模型看？（§2.2）
5. 插件把内置工具的 `parameters` 写成 list 会怎样？为什么要在注册点拦？（§2.3）
6. 为什么 `ToolEntry` 是 `eq=False`？（§2.4）
7. 发现机制为什么要 AST 扫描而不是维护 import 清单？为什么允许模块级 `for`？（§3.2）
8. 145ms 的扫描怎么优化掉的？失效粒度是什么？（§3.3）
9. 包的发现规则是什么？忘记 `__init__.py` 会发生什么？（§3.4）
10. `check_fn` 的缓存 key 为什么必须含 profile？（§4.3）
11. 什么是 `CHECK_FN_CACHE_BYPASS`？判据是什么？（§4.3）
12. `UnscopedSecretError` 的三种情况怎么区分？为什么不能用「谁调用的」来推断？（§4.4）
13. `posture=True` 与普通 toolset 的区别？为什么 posture 不能写回配置？（§5.4）
14. `platforms=` 有哪两个下游用途？（§5.5）
15. 为什么禁用 `hermes-telegram` 不能直接 `difference_update`？（§5.6）
16. 为什么禁用列表必须最后执行？（§5.7）
17. `_tool_defs_cache_key` 的九个分量分别防什么？（§6.6）
18. 为什么 `get_tool_definitions` 返回浅拷贝？不返回会怎样？（§6.6）
19. Tool Search 折叠后是哪三个工具？为什么核心工具默认不折叠？（§7.2/§7.3）
20. `tool_call` 为什么必须递归回 `handle_function_call` 而不是直接 dispatch？（§7.7）
21. `_apply_dynamic_schemas` 为什么要在重写前快照 `available`？（§6.3）
22. 为什么 `pre_tool_call` hook 要「一次 pass 同时返回 block 和 modified_args」？（§8.3）
23. 审批守卫抛异常时为什么 fail-closed？（§8.3）
24. 为什么 handler 必须返回字符串？多模态例外是什么形状？（§8.4）
25. 顺序路径和并发路径的 inline 工具优先级有什么不同？为什么？（§9.3）
26. 写完 `registry.register()` 后模型还是看不见工具，最可能是哪三步中的哪一步？（§10.3）
27. 为什么「加后端 = 新表项」而不是 `elif`？（§11.1）

---

## 14. 本篇小结

一句话版本：

> **工具 = schema（给模型看）+ handler（真的执行）。274 个工具文件在 import 时自注册进一个
> 零依赖的注册表；toolset 决定可见性，`check_fn` 决定可用性；装配时经过选择 → 过滤 →
> 动态重写 → 净化 → 折叠 → 缓存六道工序；派发时先走 inline 表，再走 registry，
> 全程有 hook / 审批 / 错误边界。**

五张必须记住的表：

- **§0.3 四阶段与四种缓存**
- **§2.3 冲突矩阵**
- **§5.1 toolset 字段语义** + **§5.6 bundle 反向减法**
- **§6 六阶段装配** + **§6.6 九个缓存 key 分量**
- **§11 硬规则清单**

三个最容易犯的错：

1. 注册了工具但**没加进 toolset** → 模型永远看不见（无报错）
2. `check_fn` 里用 `os.getenv` 或判断 `platform` → multiplex 下串号
3. 在 schema 描述里静态提及其它工具的**名字** → 模型幻觉调用不存在的工具

下一章 → [`06-provider-runtime.md`](06-provider-runtime.md)：模型和 provider 怎么被解析出来，
以及为什么「provider」其实包含三层（路由、传输、鉴权）。
