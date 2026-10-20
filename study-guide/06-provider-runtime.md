# 06 · Provider 运行时与 API 模式

> **读法**：这一篇回答「我选了 `deepseek-v4.1`，凭什么就能发请求？」。顺序是：
> **§0 前置**（provider 其实包含三层）→ **§1 文件地图** → **§2 声明式的 `ProviderProfile`**
> → **§3 三层发现与 profile 分层** → **§4 解析阶梯（8 级）** → **§5 API 模式（4+1 种）**
> → **§6 传输层** → **§7 错误分类与 failover** → **§8 凭证池与冷却**
> → **§9 辅助模型** → **§10 推理内容的三种形状** → **§11 加 provider** → **§12 自检**。
>
> 读完你应该能回答：**「`provider: auto` 到底做了什么？为什么我的 key 在环境变量里却用了
> 另一个 key？」**

**本篇相对旧版新增**：§0 的三层模型、§2 `ProviderProfile` 的五个能力钩子、§3 的
`_HomeLayer` 与 1 秒 stamp 机制、§4 完整 8 级阶梯、§5.2 `determine_api_mode` 逐行、
§6 传输层与 `register_transport`、§7 `FailoverReason` 全表、§8 冷却与 reset 优化、
§10 `reasoning_details` 的不透明契约。

---

## 0. 前置概念

### 0.1 「Provider」不是一件事，而是三层

初学者最容易把 provider 当成一个字符串。实际上是**三层可独立变化的决策**：

```text
① 路由（route）      请求发到哪个 base_url？
                      api.deepseek.com / openrouter.ai / api.anthropic.com / localhost:11434
                                    ↓
② 协议（api_mode）   用哪种 wire format？
                      chat_completions / anthropic_messages / codex_responses / bedrock_converse
                                    ↓
③ 凭证（credential） 用哪个 key / token / OAuth 会话？
                      环境变量 / 池里的某个 key / 刷新后的 access_token / IAM
```

**三层可以错配**，这是无数 bug 的来源：

| 错配 | 症状 |
|---|---|
| 路由 = OpenRouter，协议 = `anthropic_messages` | OpenRouter 的 `/chat/completions` 收到 Anthropic 格式 → 400 |
| 路由 = Anthropic，凭证 = 别人的 key | 401，但错误信息说「模型不存在」 |
| 路由 = 本地 Ollama，凭证 = 云 key | 请求带着无意义的 `Authorization`，可能被 WAF 拦 |
| 协议 = `codex_responses`，但用了普通 key | 「不支持该端点」 |

**所以本仓库把三者分开建模**，然后用一个解析器（`resolve_runtime_provider`）统一决定。

前端类比：这就像 `fetch` 的 `url`、`headers`、`auth` —— 你可以换成任何组合，
但组合错了就是 404/401。

### 0.2 为什么需要「解析」而不是直接读配置

因为 `provider` 的合法取值有六种语义不同的东西：

| 取值 | 语义 |
|---|---|
| `"auto"`（或不设） | 自动探测：看配置、看环境、看已登录的 OAuth |
| `"deepseek"` | 一个**已知 provider 名**（有 `ProviderProfile`） |
| `"openai"` | 一个**别名**，会展开成某个实际 provider |
| `"custom"` | 一个**通用 OpenAI 兼容端点**，配置里另给 base_url |
| `"my-internal-llm"` | 一个**用户在 `providers:` 里定义的自定义 provider** |
| `"moa"` | 不是 provider，是一个**多模型编排模式** |

再加 OAuth 的四种（`nous`、`codex`、`xai`、`qwen`）、AWS 的 `bedrock`、
Azure 的 `azure-foundry`、Vertex……

**一个 `if/elif` 链不可能维护这个。** 所以是「阶梯（ladder）」：
一级一级试，第一个能给出完整 `(provider, api_mode, base_url, api_key)` 的就赢。

---

## 1. 文件地图

| 文件 | 职责 |
|---|---|
| [`hermes_cli/runtime_provider.py`](../hermes_cli/runtime_provider.py:1) | **解析阶梯**主实现 |
| [`hermes_cli/runtime_provider_custom.py`](../hermes_cli/runtime_provider_custom.py:1) | 自定义 provider 查找 |
| [`hermes_cli/runtime_provider_backends.py`](../hermes_cli/runtime_provider_backends.py:1) | Azure / OpenRouter / Bedrock / 外部进程 |
| [`hermes_cli/auth.py`](../hermes_cli/auth.py:1) | provider 注册表、`resolve_provider()`、OAuth |
| [`hermes_cli/providers.py`](../hermes_cli/providers.py:1) | `ProviderDef`、`determine_api_mode()` |
| [`providers/base.py`](../providers/base.py:1) | `ProviderProfile`（声明式） |
| [`providers/__init__.py`](../providers/__init__.py:1) | 发现 + profile 分层注册表 |
| [`plugins/model-providers/<name>/`](../plugins/model-providers/) | **41 个**内置 provider 插件 |
| [`agent/transports/`](../agent/transports/) | 各 `api_mode` 的格式转换 |
| [`agent/error_classifier.py`](../agent/error_classifier.py:1) | `FailoverReason` 枚举（37 种） |
| [`agent/credential_pool.py`](../agent/credential_pool.py:1) | 多凭证池 |
| [`agent/fallback_cooldown.py`](../agent/fallback_cooldown.py:1) | 主模型冷却 |
| [`agent/auxiliary_client.py`](../agent/auxiliary_client.py:1) | 副任务路由（4700+ 行） |

**注意 facade + siblings 的痕迹**：`runtime_provider.py` 的 docstring 明说

```python
"""... Custom-provider lookup lives in :mod:`hermes_cli.runtime_provider_custom`; Azure Foundry,
OpenRouter/bare-custom, Bedrock and external-process builders in
:mod:`hermes_cli.runtime_provider_backends` — both re-exported here so
``hermes_cli.runtime_provider.<name>`` imports and test patches keep working."""
```

### 1.1 为什么用「late-bound delegates」而不是 from-import

[`runtime_provider.py:37`](../hermes_cli/runtime_provider.py:37)：

```python
# Late-bound delegates, deliberately NOT module-level from-imports: this module is often imported
# lazily, so its first import can happen while a test has ``hermes_cli.config.load_config`` patched
# — a from-import would bind the MagicMock permanently and poison every later caller.
def load_config():
    return _config_mod.load_config()
```

**`from x import y` 在 import 时刻就把 `y` 绑死了。** 如果那一刻 `y` 是测试的 `MagicMock`，
之后所有调用都拿到 mock —— 而且是**永久性的**，因为模块已经进 `sys.modules` 了。

改成 `def load_config(): return _config_mod.load_config()` 之后，每次调用都重新查属性，
`patch` 就正常工作了。

**这是「懒加载模块 + 测试 patch」的必踩坑**，值得记住。

---

## 2. `ProviderProfile`：声明式

### 2.1 设计意图

[`providers/base.py:1`](../providers/base.py:1)：

```python
"""Provider profile base class.

A ProviderProfile declares everything about an inference provider in one place:
auth, endpoints, client quirks, request-time quirks. The transport reads this
instead of receiving 20+ boolean flags.

Provider profiles are DECLARATIVE — they describe the provider's behavior.
They do NOT own client construction, credential rotation, or streaming.
Those stay on AIAgent.
"""
```

**两条边界划得很清楚**：

| 归 profile | 归 AIAgent |
|---|---|
| auth 类型、base_url、env_vars | 客户端构建 |
| 请求期怪癖（reasoning 放哪） | 凭证轮换 |
| 消息格式转换的开关 | 流式处理 |
| 模型目录探测 | 重试 |

**「instead of receiving 20+ boolean flags」** —— 反例长这样：

```python
# 如果没有 profile
client = OpenAI(api_key=..., base_url=..., 
                send_temperature=False,           # Kimi
                reasoning_in_extra_body=True,     # OpenRouter
                reasoning_top_level=False,        # ...
                vision_in_tool_messages=True,     # Anthropic
                supports_cache_key=False,         # ...
                ... 还有 15 个)
```

**20 个布尔参数 = 20 个组合 = 不可能测完。** 一个 profile 对象把「某个 provider 的所有
怪癖」打包成一个可独立测试的单元。

### 2.2 字段分组

```python
@dataclass
class ProviderProfile:
    # ── Identity ─────────────────────────────────────────────
    name: str
    api_mode: str = "chat_completions"
    aliases: tuple = ()

    # ── Human-readable metadata ───────────────────────────────
    display_name: str = ""
    description: str = ""
    signup_url: str = ""
    hidden: bool = False

    # ── Auth & endpoints ─────────────────────────────────────
    env_vars: tuple = ()
    base_url: str = ""
    models_url: str = ""
    auth_type: str = "api_key"   # api_key|oauth_device_code|oauth_external|copilot|aws_sdk
    supports_health_check: bool = True
    supports_model_listing: bool = True
```

`hidden` 的注释特别值得读：

```python
# True when the provider is pre-release / not for public listing. Discovery surfaces (provider
# pickers, the setup provider list, the dashboard accounts tab) skip it unless ``listed()``
# says otherwise; resolution by name is untouched, so an explicit ``model.provider`` /
# ``hermes auth add <name>`` keeps working.
```

**「隐藏」只影响展示，不影响解析。** 这是一条重要区分：

| 层面 | 受 `hidden` 影响 |
|---|---|
| provider picker / 设置向导 | ✅ 不显示 |
| 配置里显式写 `provider: xxx` | ❌ 照常工作 |

如果 `hidden` 连解析都拦，内部测试 provider 就没法用了。

### 2.3 五个能力钩子

profile 通过**重写方法**来声明能力，而不是开一堆开关：

| 钩子 | 用途 | 例子 |
|---|---|---|
| `build_api_kwargs_extras(...) -> (extra_body, top_level)` | 请求参数放哪 | DeepSeek 的 `thinking` |
| `build_extra_body(...)` | 纯 `extra_body` 附加 | — |
| `build_client_kwargs_extras(...)` | SDK 客户端参数 | 超时、headers |
| `default_reasoning_config(model)` | 未设置时的默认推理配置 | Nous/OpenRouter 填 medium |
| `default_vision_model()` | 视觉默认模型 | — |
| `transform_messages(messages)` | 消息预处理 | — |
| `fetch_models(...)` | 探测模型目录 | — |
| `auth_handler` / `refresh_credential` / `classify_api_error` | 插件自有认证与错误分类 | — |

#### 为什么 `build_api_kwargs_extras` 返回**两个** dict

```python
def build_api_kwargs_extras(self, *, reasoning_config=None, **context) -> tuple[dict, dict]:
    """Provider-specific kwargs split between extra_body and top-level api_kwargs.

    Returns (extra_body_additions, top_level_kwargs).
    This split exists because some providers put reasoning config in
    extra_body (OpenRouter: extra_body.reasoning) while others put it
    as top-level api_kwargs (Kimi: api_kwargs.reasoning_effort).

    Default: ({}, {}).
    """
```

**同一个概念（推理强度）在不同 provider 放在不同的 JSON 位置。**

```json
// OpenRouter
{"extra_body": {"reasoning": {"effort": "high"}}}

// Kimi
{"reasoning_effort": "high"}
```

如果只有一个返回值，调用方就得到处判断「这个 provider 该放哪」——
那就把 profile 的职责又漏回主循环了。

#### DeepSeek 的真实例子

[`plugins/model-providers/deepseek/__init__.py`](../plugins/model-providers/deepseek/__init__.py:1)：

```python
"""DeepSeek provider profile.

V4 defaults to thinking ON when ``extra_body.thinking`` is unset, and then
requires ``reasoning_content`` to be echoed back on later turns (HTTP 400 after
the first tool call otherwise). This profile sets ``thinking`` explicitly and
maps effort onto DeepSeek's ``reasoning_effort``; V3 models are left untouched.
"""
```

**一个真实的、非直觉的协议契约**：

```text
① 不传 thinking → 服务端默认开
② 服务端开了 → 后续轮次必须回传 reasoning_content
③ 你不回传 → 第一个 tool call 之后 HTTP 400
```

所以 profile **必须显式发 `thinking`**，不管用户开没开。这是「显式覆盖一个有害的默认值」。

```python
def build_api_kwargs_extras(self, *, reasoning_config=None, model=None, **context):
    m = (model or "").strip().lower()
    versioned_v4_plus = m.startswith("deepseek-v") and not m.startswith("deepseek-v3")
    if not versioned_v4_plus and m not in _THINKING_CAPABLE_IDS:
        return {}, {}
    # Always set thinking explicitly (default enabled, matching the API default)
    # to avoid the reasoning_content echo trap on subsequent turns.
    extras, top_level = thinking_toggle_extras(
        reasoning_config, DEEPSEEK_V4_EFFORTS, DEEPSEEK_V4_OVERRIDES, always_emit_toggle=True)
    ...
```

`_THINKING_CAPABLE_IDS` 的注释解释了为什么需要这个额外集合：

```python
# Version-less canonical ids for thinking-capable DeepSeek models. The 2026-09 Flash
# refresh dropped the ``v<N>`` marker from the public id: ``GET /v1/models`` reports
# ``deepseek-flash`` and the API accepts it directly, so the generation check in
# ``build_api_kwargs_extras`` cannot recognise it.
```

**「版本检测靠名字前缀」这个技巧会随时间腐烂。** 服务端改个命名，逻辑就静默失效。
所以要维护一个例外集合，并且**注释写清为什么**。

### 2.4 `OMIT_TEMPERATURE` 哨兵

```python
# Sentinel for "omit temperature entirely" (Kimi: server manages it)
OMIT_TEMPERATURE = object()
```

为什么用 `object()` 而不是 `None`？

| 值 | 含义 |
|---|---|
| `None` | 没设置，用默认 |
| `0.0` | 显式设为零 |
| **`OMIT_TEMPERATURE`** | **完全不发这个字段** |

`None` 和 `0.0` 已经占用了「未设置」和「零」两个语义，第三个语义需要自己的哨兵。
用 `object()` 保证了它不等于任何其它值。

### 2.5 `hidden` 与 `listed()`

```python
def unlisted_provider_names() -> set[str]:
    """Registered profiles that discovery surfaces ... must not offer: pre-release ones the user
    has not opted into.

    Resolution never consults this: an unlisted profile still resolves, authenticates and serves
    turns by name. A raising ``listed()`` counts as unlisted, because a broken gate must never
    advertise a dark launch.
    """
```

**「a broken gate must never advertise a dark launch」** —— `listed()` 抛异常时**当作不列出**。
这是 fail-closed 的一个清晰案例：猜错方向的代价是「公开了一个没准备好的功能」，
比「少显示一个按钮」严重得多。

### 2.6 User-Agent 的 WAF 陷阱

```python
def _profile_user_agent() -> str:
    """Return a ``hermes-cli/<version>`` UA string, with a stable fallback.

    Used by ``ProviderProfile.fetch_models`` so the catalog probe is not
    served the default ``Python-urllib/<ver>`` UA — some providers
    (OpenCode Zen, etc.) sit behind a WAF that returns 403 for that.
    """
    try:
        from hermes_cli.version_info import get_version_info  # lazy: avoid layer cycle at import time
        return f"hermes-cli/{get_version_info().base_version}"
    except Exception:
        return "hermes-cli"
```

**「默认 UA 被 WAF 403」** 是抓包才能发现的问题。注释里写清了是哪家（OpenCode Zen），
以及降级值（`hermes-cli`，不带版本）。

`import` 是函数内延迟的 —— `get_version_info()` 会读 `pyproject.toml` 或包元数据，
在模块顶层做会把 `providers/base.py` 变成有导入副作用的模块。

---

## 3. 三层发现与 profile 分层

### 3.1 三个来源

[`providers/__init__.py:3`](../providers/__init__.py:3)：

```python
"""Provider module registry.

Provider profiles can live in three places:

1. Bundled plugins: ``plugins/model-providers/<name>/`` (shipped with hermes-agent)
2. User plugins: ``$HERMES_HOME/plugins/model-providers/<name>/``
3. Pip-installed plugins: distributions exposing a ``hermes_agent.plugins``
   entry point (``module:func`` callable or a self-registering ``module``)

Each plugin directory contains:
  - ``__init__.py`` — calls ``register_provider(profile)`` at import
  - ``plugin.yaml`` — manifest (name, kind: model-provider, version, description)
"""
```

**41 个内置 plugin**：`actual`、`ai-gateway`、`alibaba`、`alibaba-coding-plan`、`anthropic`、
`arcee`、`azure-foundry`、`bedrock`、`commandcode`、`copilot`、`copilot-acp`、`custom`、
`deepinfra`、`deepseek`、`fireworks`、`gemini`、`gmi`、`huggingface`、`kilocode`、
`kimi-coding`、`lmstudio`、`meta-ai`、`minimax`、`nebius-token-factory`、`nous`、`novita`、
`nvidia`、`ollama-cloud`、`openai-codex`、`opencode-zen`、`openrouter`、`qwen-oauth`、
`router`、`solstice`、`stepfun`、`tencent-tokenhub`、`upstage`、`vertex`、`xai`、`xiaomi`、
`zai`。

**每个 provider 一个目录 = 每个 provider 一个可独立测试的单元。**
加 provider 不需要改任何共享文件（§11）。

### 3.2 懒发现

```python
"""Discovery is lazy: the first call to ``get_provider_profile()`` or
``list_providers()`` imports the bundled and pip-installed plugins once per
process; the ``$HERMES_HOME`` plugins of the profile home bound at lookup time
load into that home's own layer, so one process serving several profiles
(multiplex gateway, Desktop ``serve``) resolves each profile's installs.
User plugins override bundled plugins on name collision, so third parties can
monkey-patch or replace any built-in profile without editing the repo."""
```

**两句话两个机制**：

1. **懒** —— 不 import 就不扫描，CLI 启动不为 41 个目录付代价
2. **`$HERMES_HOME` 插件按「查找时绑定的 home」加载** —— 这是 profile 分层

### 3.3 `_HomeLayer`：为什么不能用全局注册表

```python
@dataclass
class _HomeLayer:
    """The ``$HERMES_HOME/plugins`` providers of ONE profile home.

    One process serves many profiles (multiplex gateway, Desktop ``serve``) and each profile installs
    its own plugins, so user plugins are keyed by the home bound at lookup time instead of the home
    that happened to be bound at first discovery — that made a plugin installed in a secondary
    profile ``Unknown provider`` in Desktop while the same profile worked in a terminal (#88143).
    ``stamps`` are the plugin dirs' mtimes: a directory added by ``hermes plugins install`` while the
    process runs changes them, and the next lookup imports it without a restart.
    """
    registry: dict[str, ProviderProfile] = field(default_factory=dict)
    aliases: dict[str, str] = field(default_factory=dict)
    stamps: tuple = ()
    stamp_checked_at: float | None = None
```

**issue #88143 的场景**：profile B 装了一个 provider 插件，但在 Desktop 里报
`Unknown provider`，同一个 profile 在终端里却正常。

原因：**首次发现时绑定的 home 是默认 profile**。之后所有查找都看那一层的注册表。

**修法：注册表按 home 分层，查找时用当前绑定的 home。**

```python
_HOME_LAYERS: dict[str, _HomeLayer] = {}
_HOME_LAYERS_LOCK = threading.Lock()

# The layer a ``$HERMES_HOME`` plugin import registers into. A ContextVar, not a module global:
# two turn threads scanning two profile homes at once must not cross-register. Never a lock held
# across the import itself — a thread mid-``import hermes_cli.auth`` (whose import calls
# ``list_providers()``) would block on it while the scanning thread waits on that module's import lock.
_REGISTRATION_TARGET: ContextVar[_HomeLayer | None] = ContextVar("_provider_registration_target", default=None)
```

这段注释里有两个高级点：

**（1）为什么用 `ContextVar` 而不是模块全局**

两个 turn 线程同时扫描两个 profile home 时，全局变量会串号。

**（2）为什么不能在 import 期间持锁**

```text
线程 A: 持锁 → import plugin → 插件 import 了 hermes_cli.auth
线程 B: 正在 import hermes_cli.auth（持有 import lock）→ 它内部调用 list_providers()
                                          ↓
                              需要 _HOME_LAYERS_LOCK（A 持有）
                                          ↓
                                      死锁
```

**「持锁做 import」是死锁的经典配方。**

### 3.4 `register_provider` 的两种落点

```python
def register_provider(profile: ProviderProfile) -> None:
    """Register a provider profile by name and aliases.

    Later registrations with the same name replace earlier ones — so user
    plugins under ``$HERMES_HOME/plugins/model-providers/`` can override
    bundled profiles without editing repo code. A registration made while a
    ``$HERMES_HOME`` plugin is being imported lands in that home's layer.
    """
    global _PROVIDER_LIST_CACHE
    layer = _REGISTRATION_TARGET.get()
    if layer is not None:
        layer.registry[profile.name] = profile
        for alias in profile.aliases:
            layer.aliases[alias] = profile.name
    else:
        _REGISTRY[profile.name] = profile
        _SOURCES[profile.name] = _current_source or "runtime"
        ...
```

```text
_REGISTRATION_TARGET 有值？  →  写进那个 home 的层（用户插件）
                         否  →  写进进程全局（内置 / pip / 直接调用）
```

**「注册到哪一层」由 ContextVar 决定，而不是由调用者传参。**
因为插件代码是被动 import 的，它不知道自己是哪个 profile。

### 3.5 查找时三层优先级

```python
def lookup(n: str):
    canonical = layer.aliases.get(n) or _ALIASES.get(n, n)
    return layer.registry.get(canonical) or _REGISTRY.get(canonical)
```

```text
① 当前 home 层的别名 → 当前 home 层的注册表
② 否则 进程全局别名 → 进程全局注册表
```

**用户插件（home 层）优先于内置。** 这就是「第三方可以 monkey-patch 任何内置 profile」。

`list_providers()` 的合并逻辑：

```python
result = [p for p in _PROVIDER_LIST_CACHE if p.name not in layer.registry]
result.extend({id(p): p for p in layer.registry.values()}.values())
```

先去掉被 home 层覆盖的，再追加 home 层的。**注意用 `id(p)` 去重**，因为同一个对象
可能被多个别名指向。

### 3.6 1 秒 stamp 检查

```python
_PLUGIN_DIR_STAMP_TTL_SECONDS = 1.0

def _refresh_home_layer(layer, home, key, *, force=False) -> bool:
    """Re-stat the layer's plugin dirs when due (or *force*d); True when it stat'ed this call.

    Stamps are read before the scan: a plugin that lands mid-scan changes them and the next
    check picks it up. Checking on a short cadence keeps a newly installed plugin discoverable
    without making every model lookup perform two filesystem stats.
    """
```

**为什么是 1 秒？** 两个约束：

| 约束 | 要求 |
|---|---|
| `hermes plugins install` 之后不用重启就能用 | TTL 要短 |
| 每次模型查找不能都做两次 `stat` | TTL 不能是 0 |

**「stamp 在读目录之前取」** 这个顺序也有讲究：

```text
方案 A: 取 stamp → 扫描目录 → 存 stamp
   扫描期间装了插件 → 新插件没被扫到，但 stamp 是旧的 → 下次 TTL 到期会重扫 ✅

方案 B: 扫描目录 → 取 stamp → 存 stamp
   扫描期间装了插件 → 新插件没被扫到，stamp 是新的 → 永远不重扫 ❌
```

**「先记时间戳再干活」** 是这类增量扫描的通用正解。

还有一个 `#88143` 的细节：

```python
# Publish the completed layer -- stamps AND check time -- before auth
# sync: it calls list_providers(), which re-enters this function. An
# unpublished stamp rescanned forever; an unpublished check time
# re-stats the plugin dirs inside the TTL.
layer.stamps = stamps
layer.stamp_checked_at = now
if _discovered and not _discovering:
    _sync_auth_registry()
```

**重入安全**：`_sync_auth_registry()` 会回调 `list_providers()` → 又进 `_refresh_home_layer`。
如果此时 `stamps` 还没写，就会无限重扫。

### 3.7 扁平安装目录的 kind 门控

```python
def _declares_model_provider_kind(plugin_dir: Path) -> bool:
    """Whether ``plugin_dir``'s manifest declares ``kind: model-provider``.

    Only that kind is imported from the flat install directory — every other
    plugin there belongs to ``PluginManager``, which owns its lifecycle and
    consent flow. Parsed with ruamel.yaml when available, falling back to a line
    scan so provider discovery never hard-depends on it.
    """
```

`$HERMES_HOME/plugins/` 是**扁平**的（`hermes plugins install` 直接克隆到那），
里面有各种 kind 的插件。provider 发现只碰 `kind: model-provider` 的。

**为什么？** 因为其它 kind 的插件有**同意流程（consent flow）**。
如果 provider 发现顺手 import 了它们，就等于绕过用户授权。

`ruamel.yaml` 缺失时退化成逐行扫描 —— **「provider 发现不能硬依赖 YAML 库」**。

### 3.8 向后兼容：单文件 profile

```python
"""For backward compatibility, ``providers/*.py`` files (other than ``base.py``
and ``__init__.py``) are still discovered via ``pkgutil.iter_modules``.
This lets out-of-tree users drop a single-file profile into an editable
install without the plugin dir structure. New profiles should prefer the
plugin layout."""
```

**老路径留着，新代码指新路径。** 这是「迁移但不破坏」的标准做法。

### 3.9 注册后的 auth 镜像

```python
def _sync_auth_registry() -> None:
    """Mirror profiles into the ``hermes_cli`` snapshots (auth registry, picker catalog) that are loaded.

    ``hermes_cli.auth`` takes its own snapshot of ``list_providers()`` when it is imported. If a
    plugin's imports pull that module in while :func:`_discover_providers` is still running, the
    snapshot is partial and later plugins never reach the auth registry ("Unknown provider",
    #102123). Calling back into auth once discovery is complete closes that window. Looked up via
    ``sys.modules`` on purpose: this layer must never import ``hermes_cli`` (that would run auth's
    top-level code mid-scan and risk a circular import). Never raises: registration must not fail
    because of the auth mirror.
    """
    for module, attr in (
        ("hermes_cli.auth", "sync_plugin_provider_registry"),
        ("hermes_cli.models_catalog_static", "sync_plugin_provider_catalog"),
    ):
        sync = getattr(sys.modules.get(module), attr, None)
```

三个手法：

| 手法 | 理由 |
|---|---|
| `sys.modules.get(module)` 而不是 `import module` | 避免在扫描中途跑 auth 的顶层代码（循环 import） |
| 只镜像「已经加载」的模块 | 没加载的下次自己会拿最新的 |
| 永不抛异常 | 镜像失败不该让注册失败 |

**「只对已经在 `sys.modules` 里的模块做副作用」** 是一个很有用的模式：
你需要通知一个下游，但你不能主动加载它。

---

## 4. 解析阶梯（8 级）

### 4.1 完整阶梯

[`resolve_runtime_provider`](../hermes_cli/runtime_provider.py:994)：

```python
"""Resolve runtime provider credentials for agent execution. Ladder (order is behavior — each
rung returns or raises, else falls to the next):
  1. disabled-provider guard (``providers.<name>.enabled: false``)
  2. requested-name shortcuts: moa, anthropic@azure, azure-foundry, vertex
  3. named custom provider / llamacpp alias / bare-custom direct alias
  4. local-endpoint bypass (no explicit creds, config base_url at a non-cloud host)
  5. ``auth.resolve_provider`` → explicit --api-key/--base-url path
  6. credential pool (OpenRouter pool only without custom endpoint/override)
  7. OAuth specs (nous/codex/xai/qwen; "auto" swallows AuthError, logs, and stamps it on a
     keyless fallback as ``auth_error``) → minimax-oauth
     → external-process → anthropic env → bedrock → registry api_key providers
  8. OpenRouter / bare-custom fallback
  9. ``model.openai_runtime`` overlay (openai/openai-codex, named custom providers): rewrites the picked rung's
     api_mode to ``codex_app_server``; the rung's credential/endpoint is then not used
"""
```

**「order is behavior」** 这五个字是这一节的全部要点 —— 顺序不是实现细节，是规范。

### 4.2 为什么第 1 级是「禁用守卫」

```python
requested_provider = resolve_requested_provider(requested)
_raise_if_provider_disabled(requested_provider)
```

**在任何探测之前先检查用户是否明确禁用了它。**

如果不先查，`providers.openai.enabled: false` 之后，第 5 级仍然会在环境里找到
`OPENAI_API_KEY` 并用它发请求。**用户的明确意图必须压过一切自动探测。**

### 4.3 别名展开

```python
# Same alias expansion the auxiliary client applies, so ``provider: openai`` means one thing on
# every path (background review, curator, MoA slots, delegation) instead of "Unknown provider".
# The pre-expansion name is what the codex_app_server overlay judges: ``openai`` is eligible,
# the anonymous ``custom`` it expands to is not.
requested_alias = requested_provider
requested_provider, explicit_base_url = expand_direct_api_alias(requested_provider, explicit_base_url)
```

**同一个别名要在所有路径上含义一致。** 主循环展开成 A，辅助客户端展开成 B，
就会出现「主对话能跑，标题生成报 Unknown provider」。

**保留 `requested_alias`** 是因为第 9 级要判断「用户原本写的是什么」。
`openai` 可以走 codex overlay，但它展开后的匿名 `custom` 不行。

### 4.4 惰性阶梯

```python
def _ladder_rungs(requested_provider, explicit_api_key, explicit_base_url, target_model):
    """Ladder rungs 2-8, yielded lazily so each is evaluated only when the previous one returned
    nothing; the last rung (OpenRouter / bare-custom fallback) always yields a runtime."""
    yield _resolve_requested_shortcuts(...)
    yield _named_custom_rung(...)
    if not explicit_base_url and not explicit_api_key:
        yield _local_endpoint_bypass(...)
    provider = resolve_provider(...)
    model_cfg = _get_model_config()
    yield _resolve_explicit_runtime(...)
    yield _resolve_from_pool(...)
    ...
```

```python
runtime = next(r for r in _ladder_rungs(...) if r)
```

**用生成器而不是 list**：`next(...)` 拿到第一个非空就停，后面的 rung 完全不会执行。

如果写成 `[r for r in ... if r][0]`，**所有 rung 都会跑**，包括会发网络的 OAuth 刷新。
那不只是慢，还会**消耗 refresh token**。

### 4.5 第 4 级：本地端点旁路（重要）

```python
# If provider is "auto" (or unset) but config.yaml has an explicit base_url pointing at a custom/local
# endpoint (e.g. Ollama at localhost:11434), route through the OpenAI-compatible resolver instead of
# letting resolve_provider() pick up an ANTHROPIC_API_KEY or OPENAI_API_KEY from the environment and
# send the request to a cloud API. Fixes #3846.
if not explicit_base_url and not explicit_api_key:
    yield _local_endpoint_bypass(requested_provider, explicit_api_key, explicit_base_url)
```

**场景**：用户配了 `model.base_url: http://localhost:11434/v1`（Ollama），
但他机器上也有 `ANTHROPIC_API_KEY`。

如果第 5 级先跑，`resolve_provider("auto")` 看到 `ANTHROPIC_API_KEY` 就选了 Anthropic ——
**请求发到了云上**，而不是本地 Ollama。

**「配置里显式写的 base_url 是意图，环境变量只是线索」。**

### 4.6 第 5 级：显式凭证

```python
provider = resolve_provider(requested_provider, explicit_api_key=..., explicit_base_url=...)
```

这里处理的优先级（[`provider-runtime.md`](../website/docs/developer-guide/provider-runtime.md:47)）：

```text
① 显式 CLI/运行时参数（--api-key / --base-url）
② config.yaml 的 model/provider
③ 环境变量
④ provider 默认值 / 自动解析
```

**为什么 config.yaml 压过环境变量？**

```text
用户在 hermes model 里选了 deepseek
  ↓
某天他 source 了一个旧脚本，export 了 OPENAI_API_KEY
  ↓
如果 env 优先：请求突然发到 OpenAI，用的是别的模型
```

**「已保存的选择是事实来源，环境变量是线索」。**

### 4.7 第 7 级：OAuth 的 "auto" 特殊处理

```python
if provider in _OAUTH_RUNTIME_PROVIDERS:
    try:
        yield _resolve_oauth_runtime(provider, requested_provider, model_cfg, target_model)
    except AuthError as exc:
        # Auto-detected login with stale/revoked/benched credentials: fall through to the env-var
        # providers, but keep the error so a keyless fallback can still say what is wrong.
        if requested_provider != "auto":
            raise
        logger.info("%s; falling through to next provider.", _OAUTH_RUNTIME_PROVIDERS[provider].failure_msg)
        swallowed_auth_error = exc
```

**同一个 `AuthError`，两种情况**：

| `requested_provider` | 行为 |
|---|---|
| 用户明确写了 `nous` | **raise**（用户点名要这个，失败了要告诉他） |
| `auto` | **吞掉 + 记日志 + 继续往下**（自动探测失败是正常的） |

**并且错误被保存下来**（`swallowed_auth_error`），最后如果落到一个无 key 的 fallback，
可以把这个错误贴在结果上，让用户知道「其实是你那个 OAuth 过期了」。

**这是「降级但保留诊断信息」的标准做法。**

### 4.8 第 9 级：overlay 必须在阶梯之后

```python
# model.openai_runtime is applied ONCE, after the ladder: every rung (pool, OAuth store,
# explicit --api-key/--base-url, env key) hardcodes the wire api_mode for openai/openai-codex,
# so applying the opt-in inside one rung left the others on codex_responses (#115169).
api_mode = _maybe_apply_codex_app_server_runtime(
    provider=runtime.get("provider", ""), api_mode=runtime.get("api_mode", ""),
    model_cfg=_get_model_config(), requested_provider=requested_alias)
if api_mode != runtime.get("api_mode"):
    logger.info("model.openai_runtime=codex_app_server overrides the %s runtime (source=%s); its credential/endpoint "
                "is not used — the app-server authenticates with its own login", ...)
```

**一个「应用一次」的约定，写在注释里，防止下一个人把它挪进某一级。**

如果把 overlay 加在第 5 级，那么走第 7 级（OAuth）时就不会应用。
**「横切关注点放在阶梯之后，而不是某一级里」** —— 这是本仓库反复出现的模式。

### 4.9 无凭证拒绝

```python
def _raise_for_credentialless_bare_custom(requested_provider, runtime) -> None:
    """Reject a bare ``custom`` placeholder request that fell through the whole ladder to the
    OpenRouter default endpoint with no credential. ... an EMPTY key on a ``custom`` runtime is
    exactly the dead shape that otherwise dies at agent construction as ``No LLM provider
    configured``. Keyed on the literal request, not the resolved shape: local aliases
    (``ollama``, ``vllm``) are resolved tolerantly by ``/model`` direct-alias switching, which
    supplies the alias endpoint AFTER this call and must not fail here. Typed ``AuthError`` so
    every caller's fallback chain (CLI, gateway, TUI, cron) still advances (#17929).
    """
    if requested_provider != "custom" or runtime.get("provider") != "custom" or runtime.get("api_key"):
        return
    raise AuthError(...)
```

**「在这里报一个类型化的错，好过在 200 行后报一个模糊的错」**：
`No LLM provider configured` 完全指不出根因。

注意那句「keyed on the literal request, not the resolved shape」：
判断用的是**用户写的字面值** `"custom"`，而不是解析后的 provider。
因为 `ollama` 会被解析成 `custom`，但它的端点是在**这个调用之后**才提供的 ——
如果按解析结果判断，就会误杀。

### 4.10 解析产物

```python
{
    "provider":  "deepseek",
    "api_mode":  "chat_completions",
    "base_url":  "https://api.deepseek.com/v1",
    "api_key":   "sk-...",
    "source":    "config" | "explicit" | "pool" | "oauth" | "env" | "fallback" | ...,
    # 以及 provider 特定元数据
}
```

`source` 是排障的关键：`hermes auth status` 与日志都靠它回答「这个 key 从哪来的」。

---

## 5. API 模式

### 5.1 五种模式

| `api_mode` | wire protocol | 客户端 | 说明 |
|---|---|---|---|
| `chat_completions` | OpenAI `/chat/completions` | `openai.OpenAI` | 绝大多数 provider |
| `codex_responses` | OpenAI `/responses` | `openai.OpenAI` | Codex / Responses API |
| `codex_app_server` | 子进程 JSON-RPC | 自建 | Codex app-server（用它的登录态） |
| `anthropic_messages` | Anthropic `/messages` | `anthropic.Anthropic` | 原生 Anthropic |
| `bedrock_converse` | AWS Bedrock Converse | `boto3` | AWS 原生 |

[`agent/agent_init.py:380`](../agent/agent_init.py:380) 的合法值集合：

```python
"chat_completions", "codex_responses", "anthropic_messages", "bedrock_converse", ...
```

**注意还有插件注册的第 N 种** —— `register_transport()` 让 provider 插件能声明自己的方言（§6.4）。

### 5.2 `determine_api_mode` 逐行

[`hermes_cli/providers.py:371`](../hermes_cli/providers.py:371)：

```python
def determine_api_mode(provider: str, base_url: str = "", model: str = "") -> str:
    """API mode (wire protocol) for a provider/endpoint: host-mandated mode, then Nous dual-wire
    (model-derived — the overlay alone says openai_chat and would pin Claude on the wrong wire),
    then the known provider's transport, then bedrock, else ``chat_completions``."""
    if is_actual_route(provider, base_url):
        return "chat_completions"
    mandated = host_mandated_api_mode(base_url)
    if mandated is not None:
        return mandated
    if (provider or "").strip().lower() in {"nous", "nous-portal", "nousresearch"}:
        return nous_api_mode(model)
    pdef = get_provider(provider)
    if pdef is not None:
        if pdef.transport in TRANSPORT_TO_API_MODE:
            return TRANSPORT_TO_API_MODE[pdef.transport]
        from agent.transports import registered_api_modes
        return pdef.transport if pdef.transport in registered_api_modes() else "chat_completions"
    if provider == "bedrock":
        return "bedrock_converse"
    return "chat_completions"
```

六个判定，顺序即优先级：

| 序 | 判据 | 为什么在这个位置 |
|---|---|---|
| 1 | `is_actual_route` | 本地端点一定是 OpenAI 兼容 |
| 2 | `host_mandated_api_mode(base_url)` | **host 硬性规定压倒 provider 名** |
| 3 | Nous 双线 | **必须看 model**，不能只看 provider |
| 4 | `pdef.transport` 映射 | 已知 provider 的声明 |
| 5 | 插件注册的方言 | 允许第三方扩展 |
| 6 | bedrock / 默认 | 兜底 |

#### 第 2 级的含义

「host-mandated」= 这个 base_url 只支持一种协议。
例如 `api.anthropic.com` 只支持 `anthropic_messages`。

**为什么 host 压过 provider 名？** 因为你可以用 `provider: openai` 指到
`https://api.anthropic.com`（Anthropic 现在也提供 OpenAI 兼容端点，但反例更常见：
某些代理只用一种协议）。**实际发到哪台机器才是决定性的。**

#### 第 3 级：Nous 的双线

```python
return nous_api_mode(model)
```

注释解释了为什么必须看 model：

```python
# then Nous dual-wire (model-derived — the overlay alone says openai_chat and would pin Claude on the wrong wire)
```

Nous Portal 同时提供 OpenAI 和 Anthropic 两种 wire，**取决于你调哪个模型**。
只用 provider 判断，Claude 会被钉在错误的线上。

**这是「provider 不足以决定协议」的第一个真实案例。**

#### 第 5 级：插件方言

```python
# A plugin profile's transport IS its api_mode when a plugin registered that dialect.
from agent.transports import registered_api_modes
return pdef.transport if pdef.transport in registered_api_modes() else "chat_completions"
```

**「注册了就承认，没注册就回落」。** 不认识的方言不能静默传下去（会让下游 400），
也不能报错（会让 manifest 里写错的 provider 整个不可用）。

### 5.3 为什么所有模式收敛到同一内部格式

[`04-prompt-and-caching.md`](04-prompt-and-caching.md) 讲过消息流不变量。这里补一句：

```text
内部格式（OpenAI 风格）:  {"role": "...", "content": ..., "tool_calls": [...]}
              ↓ transport.convert_messages()
provider 原生格式
              ↓ HTTP
响应
              ↓ transport.normalize_response()
NormalizedResponse
```

**内部格式是唯一真相，provider 格式是方言。**

前端类比：AST 是唯一的，Babel 插件处理各种语法 —— 而不是让每个下游自己解析源码。

### 5.4 `NormalizedResponse`

[`agent/transports/base.py:1`](../agent/transports/base.py:1)：

```python
"""Abstract base for provider transports.
A transport owns one api_mode's data path (convert_messages -> convert_tools -> build_kwargs
-> normalize_response), NOT client construction, streaming, credentials, caching, interrupts
or retries — those stay on AIAgent."""
```

```python
class ProviderTransport(ABC):
    # Provider stop_reason -> OpenAI finish_reason. ``None`` means the provider
    # already speaks OpenAI vocabulary and map_finish_reason passes through.
    _STOP_REASON_MAP: Optional[dict[str, str]] = None

    @property
    @abstractmethod
    def api_mode(self) -> str: ...

    @abstractmethod
    def convert_messages(self, messages, **kwargs) -> Any:
        """Convert OpenAI-format messages to the provider-native structure."""

    @abstractmethod
    def convert_tools(self, tools) -> Any: ...

    @abstractmethod
    def build_kwargs(self, model, messages, tools=None, **params) -> dict:
        """Primary entry point: convert messages/tools and return kwargs ready for the provider SDK."""

    @abstractmethod
    def normalize_response(self, response, **kwargs) -> NormalizedResponse:
        """Normalize a raw provider response to NormalizedResponse (the only transport-layer return type)."""

    def validate_response(self, response) -> bool:
        """Optional structural validity check; default accepts everything."""
        return True

    def extract_cache_stats(self, response) -> Optional[dict[str, int]]:
        """Optional: ``{'cached_tokens', 'creation_tokens'}`` or None (default)."""
        return None

    def map_finish_reason(self, raw_reason: str) -> str:
        """Map a provider stop reason via ``_STOP_REASON_MAP`` (unknown -> 'stop'); passthrough when no map."""
        return raw_reason if self._STOP_REASON_MAP is None else self._STOP_REASON_MAP.get(raw_reason, "stop")
```

**「the only transport-layer return type」** —— 传输层只能返回 `NormalizedResponse`。
这条约束让上层不需要判断「我拿到的是哪种响应」。

`_STOP_REASON_MAP` 的 `None` vs `{}` 区分很微妙：

| 值 | 含义 | 行为 |
|---|---|---|
| `None` | 这个 provider 说的就是 OpenAI 词汇 | 原样传递 |
| `{}` | 有映射表但是空的 | 全部 → `"stop"` |
| 有内容 | 需要翻译 | 查表，未知 → `"stop"` |

**「`None` 表示不需要翻译」比「翻译一个恒等映射」更诚实** —— 它保住了未知值的原貌。

### 5.5 传输注册表

[`agent/transports/__init__.py:1`](../agent/transports/__init__.py:1)：

```python
"""Transport registry for provider response normalization.
    transport = get_transport("anthropic_messages")
    result = transport.normalize_response(raw_response)"""

_TRANSPORT_MODULES = ("anthropic", "codex", "chat_completions", "bedrock")

def get_transport(api_mode: str):
    """Return a transport instance for ``api_mode``, or None so callers can fall back to the legacy path."""
    # A directly-imported transport leaves the registry partial; (re)discover on first use and on misses.
    if not _discovered or api_mode not in _REGISTRY:
        _discover_transports()
    cls = _REGISTRY.get(api_mode)
    return None if cls is None else cls()
```

**「on misses 也重新发现」** —— 因为直接 import 某个 transport 会让注册表是部分的。
这是一个「自愈式注册表」：

```text
需要 X → 没有？→ 全部 import 一遍 → 再看有没有
```

`registered_api_modes()` 的 docstring 揭示了一个真实的 bug 类别：

```python
def registered_api_modes() -> frozenset:
    """Every api_mode with a registered transport, in-tree and plugin-supplied.

    ``register_transport`` is the public seam for a provider plugin that speaks
    its own dialect, but the api_mode gates elsewhere are closed literals — a
    plugin's mode was rejected there and rewritten to ``chat_completions``, with
    the dialect translation dropped and no error raised. Callers that validate an
    api_mode use this so a registered transport is accepted on every path.
    """
```

**「closed literals」** —— 别处有一堆

```python
if api_mode in {"chat_completions", "codex_responses", "anthropic_messages", "bedrock_converse"}:
```

硬编码集合。插件注册一个新方言，在这些地方会被**静默改写成** `chat_completions`，
**方言翻译就丢了，还不报错**。

修法：需要校验 api_mode 的地方统一用 `registered_api_modes()`。

**教训：任何「合法值集合」都应该导出一个权威来源，而不是散落的字面量。**

---

## 6. 错误分类与 failover

### 6.1 `FailoverReason`：为什么需要这么细

[`agent/error_classifier.py:34`](../agent/error_classifier.py:34) 有 **37 个**枚举值。
选几个解释为什么「HTTP 429」不够用：

```python
auth = "auth"                        # Transient auth (401/403) — refresh/rotate
auth_permanent = "auth_permanent"    # Auth failed after refresh — abort
billing = "billing"                  # 402 or confirmed credit exhaustion — rotate immediately
rate_limit = "rate_limit"            # 429 or quota-based throttling — backoff then rotate
upstream_rate_limit = "upstream_rate_limit"  # Aggregator's upstream model 429 — fallback model, key is healthy
upstream_blocked = "upstream_blocked"  # 403 from a WAF/CDN/proxy in front of the provider — key is healthy, fallback
```

**同样是 429 / 403，恢复策略完全不同：**

| reason | 谁的错 | 正确反应 |
|---|---|---|
| `rate_limit` | 你的 key 被限流 | 退避，然后**换 key** |
| `upstream_rate_limit` | 聚合商背后的模型被限流 | **换模型**；key 是好的，别换 |
| `upstream_blocked` | WAF 挡了你的 IP/UA | **换 provider**；key 完全没问题 |
| `auth` | token 临时失效 | 刷新 |
| `auth_permanent` | 刷新后还是不行 | **放弃** |

**如果只有一个 `rate_limit`，那么「换 key」和「换模型」会被混为一谈** ——
而换 key 会浪费掉一个好 key（`upstream_rate_limit` 场景）。

### 6.2 六种「不该 failover，该改请求」

```python
context_overflow = "context_overflow"  # Context too large — compress, not failover
payload_too_large = "payload_too_large"  # 413 — compress payload
image_too_large = "image_too_large"   # Native image part exceeds provider's per-image limit — shrink and retry
image_corrupt = "image_corrupt"       # Provider can't decode image bytes — strip and retry
role_alternation = "role_alternation"  # Strict chat template rejected adjacent same-role messages — merge
multimodal_tool_content_unsupported = "multimodal_tool_content_unsupported"  # downgrade to text and retry
reasoning_mandatory = "reasoning_mandatory"  # Route rejects reasoning: {enabled: false} — stop sending disable
```

**「换 provider」和「改请求」是两种完全不同的恢复方式。**

如果把它们混成一个 `retryable` 布尔值，你会：
- 对 `context_overflow` 换 provider（浪费一次调用，新 provider 也会溢出）
- 对 `role_alternation` 反复重试同一个请求（永远失败）

### 6.3 三个「不要重试同一个请求」

```python
content_policy_blocked = "content_policy_blocked"  # safety filter rejected this prompt — deterministic per-request, don't retry unchanged
ssl_cert_verification = "ssl_cert_verification"  # Deterministic TLS chain failure — fail fast with guidance
format_error = "format_error"        # 400 bad request — abort or strip + retry
```

**`deterministic per-request`** 是关键判据：同样的输入必然同样的结果。重试纯浪费。

### 6.4 provider 自有的错误分类

```python
classify_api_error: Callable[..., Any] | None = None
```

profile 字段的注释：

```python
# ``classify_api_error(error, *, status_code, error_code, message, body, model) -> Mapping | None``:
# consulted by ``agent.error_classifier.classify_api_error`` for THIS provider's failures only, after
# the generic ``transform_api_error_classification`` plugin hooks and before the built-in pipeline.
# Return ``{"reason": <FailoverReason name>, ...hint flags}`` to override, ``None`` to decline.
```

**三级顺序**：

```text
① 通用 plugin hooks（transform_api_error_classification）
② provider 自己的 classify_api_error
③ 内置分类管线
```

为什么 provider 的在中间？因为通用 hook 是全局策略，provider 的更具体，
内置的是兜底。

`None` 表示「我不认识这个错」，让内置管线处理 —— **不是「我不在乎」**。

---

## 7. 凭证池与冷却

### 7.1 凭证池

[`agent/credential_pool.py:1`](../agent/credential_pool.py:1)：

```python
"""Persistent multi-credential pool for same-provider failover."""
```

**场景**：你有三个 OpenRouter key，其中一个每月免费额度用完。

```text
请求 → 池选 key #1 → 402 billing → 标记冷却 → 换 key #2 → 成功
```

**关键点：换的是 key，不是 provider。** 因为 `billing` 是「这个账号没钱了」，
不是「这个服务挂了」。

### 7.2 模型级冷却

[`agent/credential_pool_model_cooldowns.py`](../agent/credential_pool_model_cooldowns.py:1)：

```python
class CredentialPoolModelCooldownMixin, model_cooldown_until
```

**冷却的粒度是 `(credential, model)`，不是 `credential`。**

为什么？因为 `model_entitlement`（这个账号不能用这个模型）不影响同账号的其它模型。
如果把整个 key 冷却掉，你损失了还在工作的模型。

### 7.3 主模型冷却与「等待 vs 切换」

[`agent/fallback_cooldown.py`](../agent/fallback_cooldown.py:1)：

```python
def switch_deferred_by_reset(agent, reason, reset_at) -> bool:
    """Opt-in ``fallback.min_switch_reset_seconds`` (default 0 = off, #117484): when the primary's
    rate limit reopens sooner than N seconds, switching model mid-task costs more than waiting, so
    the fallback walk is skipped and the retry loop's own backoff rides out the window. Only for
    rate-limit failovers leaving the primary with a valid future ``reset_at``."""
```

**一个反直觉的优化**：

```text
主模型被限流，reset_at = 20 秒后
  ↓
方案 A（默认）：切换到 fallback 模型
   成本：重建请求（不同模型可能不同 prompt/缓存全废）+ 上下文重新 prefill
  ↓
方案 B（opt-in）：等 20 秒
   成本：20 秒的墙钟时间
```

如果任务很长、上下文很大，**重建一次的成本远超 20 秒的等待**。

三个守卫条件（都不满足才等待）：

```python
if reason not in _RATE_LIMIT_FAILOVER_REASONS: return False   # 只有限流类
if getattr(agent, "_fallback_activated", False): return False  # 已经切过了，别再等
if delay is None or delay >= threshold: return False           # 等太久了不值得
```

### 7.4 `rate_limit` 的三种细分

```python
_RATE_LIMIT_FAILOVER_REASONS = frozenset({
    FailoverReason.rate_limit, FailoverReason.billing, FailoverReason.upstream_rate_limit})
```

**等一下，`billing` 也算？** 是的 —— 因为 `billing` 也可能是「配额用完了，下个月恢复」，
同样有 `reset_at`。**「这个窗口什么时候过去」比「错误叫什么」更重要。**

### 7.5 为什么这些必须做 E2E 测试

[`agent/AGENTS.md:106`](../agent/AGENTS.md:106)：

> **Fallback 模型**与**凭证池（credential pool）**属于**解析链代码**。
> 按根目录规则，它们是**用真实 import + 临时 `HERMES_HOME` 做 E2E 测试的**，不是 mock。

**为什么不能 mock？** 因为这些代码的正确性依赖于：

| 依赖 | mock 会漏掉什么 |
|---|---|
| 真实的 `HERMES_HOME` 路径解析 | profile 串号 |
| 真实的 `config.yaml` 读取 | 缓存失效时机 |
| 真实的凭证文件权限 | 权限错误 |
| 真实的 import 顺序 | 循环 import、部分注册表 |
| 真实的锁 | 死锁、重入 |

**「解析链代码」是一个明确的高风险类别**，因为它把配置、环境、文件、网络、锁全串起来了。

---

## 8. 辅助模型（side-LLM）

### 8.1 哪些任务是副任务

| 任务 | 为什么用小模型 |
|---|---|
| 会话标题生成 | 只是起个名字 |
| 上下文压缩（summary） | 总结不需要顶级模型 |
| `session_search` 重排 | 判断相关性 |
| vision 描述 | 有时用专门的视觉模型 |
| curator（技能整理） | 低频、可批量 |
| MoA 的 advisor / aggregator | 多模型投票 |
| 审批判断 | 二分类 |

**这些任务的成本加起来可能超过主对话本身**，所以值得独立路由。

### 8.2 两条自动链

[`agent/auxiliary_client.py:1`](../agent/auxiliary_client.py:1)：

```python
"""Shared auxiliary client router for side tasks (compression, search, vision, ...).

Text auto chain: main provider+model → OpenRouter → Nous Portal → custom endpoint →
native Anthropic → direct API-key providers → None. Vision auto chain: main
provider (if a supported vision backend) → OpenRouter → Nous → Anthropic → custom.
``auxiliary.free_only`` restricts the OpenRouter lane to ``:free`` SKUs. Codex OAuth is
in neither chain (undocumented, shifting allow-list): main provider or explicit
``auxiliary.<task>.provider`` only. HTTP 402 in call_llm() falls through the chain.
"""
```

三条值得注意的规则：

**（1）主 provider 优先**

```python
def _resolve_auto_route(main_runtime=None, task=None):
    """Full auto-detection chain... Priority: (1) main provider + main model, regardless of
    provider type ("auto" means "my main model for side tasks too"; explicit per-task overrides
    still win); (2) configured fallback policy — task chain, then the main agent's top-level chain;
    (3) OpenRouter → Nous → custom → Codex → API-key providers, only with no policy and no working
    main client."""
```

**`auto` 的含义是「副任务也用我的主模型」**，而不是「随便找个小模型」。
这符合直觉：如果用户花钱买了某个模型，不该偷偷换成别的。

**（2）Codex OAuth 不在自动链里**

```python
# Codex OAuth is in neither chain (undocumented, shifting allow-list): main provider or explicit
# ``auxiliary.<task>.provider`` only.
```

**「undocumented, shifting allow-list」** —— 对方随时可能改，不能依赖。

**（3）`free_only` 只约束 OpenRouter**

```python
# ``auxiliary.free_only`` restricts the OpenRouter lane to ``:free`` SKUs
```

因为只有 OpenRouter 有 `:free` 这种 SKU 标记。

### 8.3 三个 relay 通道

```python
_relay_sync_completion(...)     # 同步非流式
_relay_async_completion(...)    # 异步非流式
_relay_sync_stream(...)         # 同步流式
```

**所有物理尝试都汇入这三个函数** —— 包括重试、恢复阶梯、fallback。

```python
def _relay_sync_completion(client, kwargs, *, provider=None, api_mode=None, create=None):
    from agent.auxiliary_wire import prepare_chat_messages

    kwargs = prepare_chat_messages(client, kwargs)
    # The progress hook is installed per TASK, so every attempt (retries, recovery rungs, fallbacks)
    # must stream through _create_with_progress or the compression watchdog sees silence (#98466).
    # Recovery rungs / credential retries keep the task's ``no_progress_timeout`` window; the
    # first-token window uses this attempt's provider (fallbacks name theirs) for its stale timeout.
```

**「每一层都必须给 watchdog 发信号」** —— 否则压缩会以为卡死了然后超时。
这是「横切关注点必须覆盖所有分支」的例子。

### 8.4 hooks：为什么必须是独立事件

[`agent/auxiliary_hooks.py:1`](../agent/auxiliary_hooks.py:1)：

```python
"""Plugin events for auxiliary LLM calls (#79733).

``pre_auxiliary_call`` / ``post_auxiliary_call`` fire once per physical provider attempt at the
relay boundary ... carrying the ``pre_api_request`` / ``post_api_request`` payload shape plus
``aux_task``. They are deliberately DISTINCT events: the main-loop ``*_api_request`` events stay
turn-scoped, so observability plugins keyed on turn identity never see auxiliary traffic unless
they subscribe to these. Observer-only (returns ignored) and fail-open: a raising or hung
callback is logged and the auxiliary call proceeds untouched.
"""
```

**核心不变量（#79733）**：主循环的 `pre/post_api_request` **绝不为**辅助调用触发。

为什么？因为有个关键区别：

| | 主循环 API 请求 | 辅助调用 |
|---|---|---|
| 归属 | 某个 turn | 可能不属于任何 turn（cron、idle） |
| 数量 | 每 turn 几次 | 可能几十次（压缩、重排） |
| 是否算「对话的一部分」 | 是 | 不是 |

**如果混在一起**：
- 基于 turn 的成本统计会翻倍
- 一个「每 turn 只允许一次」的策略会被辅助调用打乱
- 遥测插件会看到不属于该 turn 的请求

所以是**两个不同的事件**，辅助事件额外带 `aux_task`。

**「observer-only + fail-open」**：回调抛异常或挂住，辅助调用照常进行。
理由：辅助调用是**内部基础设施**，不该被用户插件拖垮。

`_parent_turn_identity()` 的设计也值得看：

```python
def _parent_turn_identity() -> dict[str, str]:
    """``session_id`` / ``task_id`` / ``turn_id`` / ``platform`` of the main turn this auxiliary
    call runs under, or empty strings for turn-less callers (cron, gateway idle work)."""
```

**「turn-less callers」** 是被显式承认的存在。不是所有调用都在一个 turn 里。

---

## 9. 推理内容的三种形状

### 9.1 三种形状

OpenAI 兼容 relay 可能返回：

```json
// 形状 1：字符串
{"reasoning": "让我想想..."}

// 形状 2：文本 part 字典
{"reasoning": {"type": "text", "text": "让我想想..."}}

// 形状 3：混合列表
{"reasoning": [{"type": "text", "text": "让我"}, "想想...", {"type": "text", "text": "..."}]}
```

**同一个字段，三种类型。** 任何对它做字符串操作的地方都会在其中两种上炸。

### 9.2 规则：第一次字符串操作之前先扁平化

原文：

> Hermes 在下列所有位置第一次做字符串操作**之前**先扁平化：主 stream、Relay 记录、
> 同步与异步辅助 stream、完成响应的推理抽取。

**五个位置，每个都要处理。** 这就是「同一个怪癖在 N 处出现」的成本 ——
如果漏一处，就是「主对话正常但压缩输出是 dict 字符串」。

三条扁平化规则：

| 规则 | 理由 |
|---|---|
| 片段保留显式空白 | `"让我"` + `" 想想"` 拼起来要有空格 |
| 规范化**不添加**字段内分隔符 | 否则 `"a"+"b"` 变成 `"a b"`（凭空多空格） |
| 主 stream 与 Relay 保留段落分隔 | 粗体标题之间要空行 |

### 9.3 `reasoning_details` 是不透明的

原文：

> `delta.reasoning_details` 是不透明的 provider 记录列表：主 stream 与 Relay 记录**按到达顺序追加**，
> 不扁平化、不合并、不改写。provider 可能在最后一个 delta 发出完整记录，也可能跨多个 delta；
> 没有新记录的 chunk 省略该字段。

**四个「不」**：

```text
✅ 按到达顺序追加
❌ 不扁平化
❌ 不合并
❌ 不改写
```

为什么这么严格？因为 `reasoning_details` 里可能有 **signed payload**：

```json
{"type": "reasoning.text", "text": "...", "signature": "EqQBCgIYAhIM..."}
```

Anthropic 的 thinking block 签名必须**逐字回传**，否则下一轮被拒。

[`agent/anthropic_thinking_replay.py:31`](../agent/anthropic_thinking_replay.py:31)：

```python
_CARRIERS = ("reasoning_details", "anthropic_content_blocks", "_anthropic_content_blocks")
```

**三个载体**，因为不同的传输路径把签名放在不同的字段里。

### 9.4 为什么不能「合并相同类型的记录」

假设 provider 发了：

```json
[{"type": "reasoning.text", "text": "A", "signature": "sig1"},
 {"type": "reasoning.text", "text": "B", "signature": "sig2"}]
```

如果你合并成 `{"text": "AB", "signature": "sig1"}`，`sig2` 就丢了 ——
而服务端校验时可能要求逐块签名。

**「不透明」= 不要试图理解，只负责正确搬运。**

---

## 10. 模型元数据

[`agent/model_metadata.py:1`](../agent/model_metadata.py:1)：

```python
"""Model metadata, context lengths, and token estimation utilities.

Pure utility functions with no AIAgent dependency. Used by ContextCompressor
and run_agent.py for pre-flight context checks.
"""
```

| 关注点 | 位置 |
|---|---|
| 上下文长度 | `model_metadata.py` |
| 能力（vision、reasoning） | `model_metadata.py` + profile |
| 外部注册表 | `agent/models_dev.py`（models.dev） |
| provider 目录探测 | `ProviderProfile.fetch_models()` |

### 10.1 provider 前缀剥离

```python
_PROVIDER_PREFIXES: frozenset[str] = frozenset(
    value.lower()
    for profile in _list_providers()
    for value in (profile.name, *profile.aliases)
)
```

**模型名可能是 `provider/model` 形式**（`openrouter` 发 `xiaomi/mimo-v2.5`）。
要查表时得先剥掉前缀。

注意这是**模块级常量** —— 但注释说 `prefix routing queries the registry live`。
所以它是「快照 + 实时查询」的混合：常量用于快速判断「有没有前缀」，
具体解析时再查活的注册表。

### 10.2 聚合商的特殊性

[`providers/__init__.py:229`](../providers/__init__.py:229)：

```python
def routed_model_rejects_vision_tool_messages(provider: str, model: str) -> bool:
    """Whether an active route or its aggregator-targeted model rejects image tool parts.

    Routing aggregators such as ``openrouter`` send vendor-prefixed model IDs
    (for example, ``xiaomi/mimo-v2.5``), but their own profile cannot describe
    every routed provider's tool-message compatibility. Preserve the transport
    profile as the default and consult a registered target profile only for
    routing aggregators. Missing or unrecognized identities deliberately fail open.
    """
    ...
    target_name, separator, _ = str(model or "").strip().partition("/")
    if not separator or not target_name:
        return False
    target_profile = get_provider_profile(target_name.strip().lower())
    return target_profile is not None and target_profile.supports_vision_tool_messages is False
```

**聚合商是「provider 的 provider」**：OpenRouter 自己的 profile 不可能描述每一个
被路由的厂商的兼容性。

所以：**路由用聚合商的 profile，但能力检查要穿透到目标厂商。**

`if not separator: return False` —— 没有 `vendor/` 前缀就不穿透。
`fail open`（`return False` = 不拒绝）—— 认不出来就放行，因为拒绝会破坏本来能用的请求。

---

## 11. 加一个 provider

### 11.1 最小步骤（真的只有一步）

[`adding-providers.md`](../website/docs/developer-guide/adding-providers.md:1) +
[`model-provider-plugin.md`](../website/docs/developer-guide/model-provider-plugin.md:1)

```text
plugins/model-providers/<your-provider>/
├── __init__.py
└── plugin.yaml
```

```python
# __init__.py
from providers import register_provider
from providers.base import ProviderProfile

my_provider = ProviderProfile(
    name="my-provider",
    display_name="My Provider",
    description="My Provider — OpenAI-compatible",
    signup_url="https://my-provider.example/",
    env_vars=("MY_PROVIDER_API_KEY",),
    base_url="https://api.my-provider.example/v1",
    fallback_models=("my-model-large", "my-model-small"),
    default_aux_model="my-model-small",
)
register_provider(my_provider)
```

```yaml
# plugin.yaml
name: my-provider-provider
kind: model-provider
version: 1.0.0
description: My Provider
author: You
```

**就这些。`runtime_provider.py` 不需要加任何分支。**

### 11.2 为什么不需要改解析器

因为解析器只依赖三样东西：

| 依赖 | 从哪来 |
|---|---|
| `PROVIDER_REGISTRY` | `hermes_cli/auth.py`，会被 `_sync_auth_registry` 镜像 |
| `ProviderProfile` | §3 的注册表 |
| `api_mode` | `determine_api_mode()` 看 `api_mode` 字段 |

**新 provider 填好这三样就自动可用。** 这是「表驱动 + 声明式」的兑现。

### 11.3 什么时候需要重写方法

| 需求 | 重写 |
|---|---|
| 推理参数放在 `extra_body` | `build_api_kwargs_extras` |
| 推理参数放在顶层 | `build_api_kwargs_extras`（第二个返回值） |
| 完全不发 temperature | `fixed_temperature = OMIT_TEMPERATURE` |
| 自定义 OAuth 流程 | `auth_handler` / `refresh_credential` |
| 特殊错误分类 | `classify_api_error` |
| 自定义消息格式 | 注册自己的 transport（§5.5） |
| 视觉默认模型要动态探测 | `default_vision_model` |

### 11.4 五条要注意的事

| 注意 | 为什么 |
|---|---|
| `name` 要和 `hermes auth` 里的名字一致 | 否则用户看到两个名字 |
| `aliases` 是用户可能输入的名字 | 少了就 `Unknown provider` |
| `env_vars` 要加进 `OPTIONAL_ENV_VARS` | 让 `hermes setup` 指导用户 |
| `fetch_models` 用 `_profile_user_agent()` | 默认 UA 可能被 WAF 403 |
| secrets 走 `get_secret()` 而非 `os.getenv` | multiplex 下会串 profile |

---

## 12. 自检题

1. Provider 的三层分别是什么？举一个三层错配的症状。（§0.1）
2. 为什么 `provider` 的解析需要「阶梯」而不是 `if/elif`？（§0.2）
3. `ProviderProfile` 为什么比「20 个布尔参数」好？（§2.1）
4. `hidden` 影响什么、不影响什么？为什么要这样分？（§2.2）
5. `build_api_kwargs_extras` 为什么返回两个 dict？举例说明。（§2.3）
6. DeepSeek 为什么要「总是显式发送 thinking」？（§2.3）
7. `OMIT_TEMPERATURE` 为什么不能用 `None`？（§2.4）
8. `listed()` 抛异常时为什么当作「不列出」？（§2.5）
9. `_HomeLayer` 解决的是什么 bug？为什么不能用全局注册表？（§3.3）
10. 为什么注册目标用 `ContextVar`？为什么不能在 import 期间持锁？（§3.3）
11. 1 秒 stamp 检查为什么是 1 秒？为什么要在扫描之前取 stamp？（§3.6）
12. 扁平安装目录为什么只 import `kind: model-provider`？（§3.7）
13. 解析阶梯第 1 级为什么必须是「禁用守卫」？（§4.2）
14. 第 4 级「本地端点旁路」防的是什么具体事故？（§4.5）
15. 为什么 config.yaml 压过环境变量？（§4.6）
16. `"auto"` 模式下 OAuth 失败为什么要吞掉错误，显式指定时要 raise？（§4.7）
17. codex overlay 为什么必须放在阶梯之后？（§4.8）
18. `determine_api_mode` 的六个判定，为什么 host 压过 provider 名？（§5.2）
19. Nous 为什么必须按 model 决定 api_mode？（§5.2）
20. `_STOP_REASON_MAP` 的 `None` 和 `{}` 有什么区别？（§5.4）
21. `rate_limit` / `upstream_rate_limit` / `upstream_blocked` 的恢复策略各是什么？（§6.1）
22. 哪几种错误不该 failover 而该改请求？（§6.2）
23. 冷却粒度为什么是 `(credential, model)` 而不是 `credential`？（§7.2）
24. 「等待 vs 切换」的判据是什么？为什么有时等待更便宜？（§7.3）
25. 为什么 fallback 与凭证池必须用真实 import 做 E2E？（§7.5）
26. `"auto"` 在辅助模型里是什么意思？（§8.2）
27. 为什么辅助调用要有自己的 `pre_auxiliary_call` 而不能复用 `pre_api_request`？（§8.4）
28. 推理内容的三种形状是什么？为什么不能「合并相同类型的记录」？（§9）
29. 聚合商的能力检查为什么要穿透到目标厂商？（§10.2）
30. 加一个 provider 为什么只需要一个目录？（§11.2）

---

## 13. 本篇小结

一句话版本：

> **provider 是三层（路由 / 协议 / 凭证）。`ProviderProfile` 把它们声明式地打包；41 个插件
> 目录各自声明一个 provider，按 profile 分层懒发现；`resolve_runtime_provider` 用 8 级惰性
> 阶梯决定用哪套组合；错误被分成 37 种原因，因为「换 key」「换模型」「改请求」是三件
> 不同的事。**

五张必须记住的表：

- **§0.1 三层错配表**
- **§2.3 五个能力钩子**
- **§4.1 八级阶梯**
- **§5.2 `determine_api_mode` 六判定**
- **§6.1 `FailoverReason` 的代表性分类**

三个最容易犯的错：

1. 以为 `provider` 决定一切 → 忘了 host-mandated 和 model 决定 api_mode
2. 用 `os.getenv` 读 key → multiplex 下串 profile
3. 把「限流」当成一件事 → 换掉了本来健康的 key

下一章 → [`07-state-and-session.md`](07-state-and-session.md)：SQLite 状态库、WAL、
会话血缘与 `/branch`。
