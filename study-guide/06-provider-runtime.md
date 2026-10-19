# 06 · 模型 Provider 解析与 API 模式

> 目标：理解 `(provider, model)` 如何被解析成 `(api_mode, api_key, base_url)`，以及辅助模型的独立路由。

---

## 1. 一个共享的运行时解析器

Hermes 有一个**共享的 provider 运行时解析器**，被以下所有路径复用：

- CLI
- gateway
- cron 任务
- ACP
- 辅助模型调用（auxiliary）

来源：[`provider-runtime.md`](../website/docs/developer-guide/provider-runtime.md:9)

### 1.1 主实现文件

| 文件 | 职责 |
|---|---|
| [`hermes_cli/runtime_provider.py`](../hermes_cli/runtime_provider.py:1) | 凭证解析、自定义端点运行时解析 |
| [`hermes_cli/auth.py`](../hermes_cli/auth.py:1) | provider 注册表、`resolve_provider()` |
| [`hermes_cli/model_switch.py`](../hermes_cli/model_switch.py:1) | 共享的 `/model` 切换流水线（CLI + gateway） |
| [`agent/auxiliary_client.py`](../agent/auxiliary_client.py:1) | 辅助模型路由 |
| [`providers/`](../providers/) | ABC + 注册表入口（`ProviderProfile`、`register_provider`、`get_provider_profile`、`list_providers`） |
| [`plugins/model-providers/<name>/`](../plugins/model-providers/) | 每个 provider 一个插件，声明 `api_mode`、`base_url`、`env_vars`、`fallback_models` |

---

## 2. ProviderProfile：声明式设计

[`providers/base.py`](../providers/base.py:1) 的 docstring 点出了设计意图：

> 一个 `ProviderProfile` 把推理 provider 的**一切**集中声明：认证、端点、客户端怪癖、请求期怪癖。
> 传输层读这个对象，而不是接收 20+ 个布尔开关。
>
> **Provider profile 是声明式的**——它们描述 provider 的行为，
> **不拥有**客户端构建、凭证轮换、流式。那些留在 `AIAgent` 上。

关键字段（部分）：

```python
@dataclass
class ProviderProfile:
    name: str                        # 身份
    api_mode: str = "chat_completions"
    aliases: tuple = ()
    # ... 人类可读元数据、env_vars、base_url、fallback_models 等
```

有一个哨兵常量 `OMIT_TEMPERATURE`——用于「完全不发送 temperature」（Kimi 由服务端管理）。

---

## 3. Provider 的发现（三层 + 懒加载）

[`providers/__init__.py`](../providers/__init__.py:1) 描述了三处来源：

1. **内置插件**：`plugins/model-providers/<name>/`（随 hermes-agent 发布）
2. **用户插件**：`$HERMES_HOME/plugins/model-providers/<name>/`
3. **pip 安装插件**：分发暴露 `hermes_agent.plugins` entry point

每个插件目录包含：
- `__init__.py` — import 时调用 `register_provider(profile)`
- `plugin.yaml` — 清单（`name`、`kind: model-provider`、`version`、`description`）

### 3.1 懒发现 + profile 分层

发现是**懒的**：第一次调用 `get_provider_profile()` 或 `list_providers()` 时，
每进程 import 一次内置与 pip 插件；而 `$HERMES_HOME` 插件按**查找时绑定的 profile home**
加载进那个 home 自己的层，所以一个进程服务多个 profile（multiplex gateway、Desktop `serve`）
时，每个 profile 解析自己的安装。

**用户插件在同名冲突时覆盖内置插件**（last-writer-wins），
所以第三方可以 monkey-patch 或替换任何内置 profile，而无需改仓库。

### 3.2 向后兼容

`providers/*.py` 文件（除 `base.py` 与 `__init__.py`）仍通过 `pkgutil.iter_modules` 被发现，
让 out-of-tree 用户能往可编辑安装里丢单文件 profile。**新 profile 应优先插件布局。**

### 3.3 使用方式

```python
from providers import get_provider_profile
profile = get_provider_profile("nvidia")   # ProviderProfile 或 None
profile = get_provider_profile("kimi")     # 会检查 name + aliases
```

注册表内部用三个进程级字典：`_REGISTRY`（name → profile）、`_ALIASES`（alias → name）、
`_SOURCES`（name → "bundled" / "user" / "runtime"）。

---

## 4. 解析优先级（重要）

来自 [`provider-runtime.md`](../website/docs/developer-guide/provider-runtime.md:47)：

1. **显式 CLI/运行时请求**（最高）
2. **`config.yaml` 的 model/provider 配置**
3. **环境变量**
4. **provider 特定默认值或自动解析**

> **为什么这个顺序很重要**：Hermes 把「已保存的 model/provider 选择」当作正常运行的事实来源。
> 这防止一个过期的 shell export 静默覆盖用户上次在 `hermes model` 里选的端点。

---

## 5. 运行时解析的产物

```python
{
    "provider":  "...",
    "api_mode":  "chat_completions" | "codex_responses" | "anthropic_messages",
    "base_url":  "...",
    "api_key":   "...",
    "source":    "...",
    # 以及 provider 特定元数据，如 expiry/refresh 信息
}
```

为什么这重要：正是这个解析器让 Hermes 能在
`hermes chat`、网关消息处理、cron 新会话、ACP 编辑器会话、辅助模型任务之间共享认证/运行时逻辑。
（[`provider-runtime.md`](../website/docs/developer-guide/provider-runtime.md:103)）

---

## 6. 三种 API 模式

| API 模式 | 用于 | 客户端类型 |
|---|---|---|
| `chat_completions` | OpenAI 兼容端点（OpenRouter、自定义、多数 provider） | `openai.OpenAI` |
| `codex_responses` | OpenAI Codex / Responses API | `openai.OpenAI` + Responses 格式 |
| `anthropic_messages` | 原生 Anthropic Messages API | `anthropic.Anthropic`（经 adapter） |

模式决定：消息如何格式化、工具调用如何组织、响应如何解析、缓存/流式如何工作。
三种模式在 API 调用前后都收敛到**同一个内部消息格式**（OpenAI 风格的 `role`/`content`/`tool_calls`）。

### 6.1 模式解析顺序

来自 [`agent-loop.md`](../website/docs/developer-guide/agent-loop.md:53)：

1. 显式 `api_mode` 构造参数（最高优先）
2. provider 特定检测（如 `anthropic` provider → `anthropic_messages`）
3. base URL 启发式（如 `api.anthropic.com` → `anthropic_messages`）
4. 默认：`chat_completions`

---

## 7. Provider 家族（当前内置集）

来自 [`provider-runtime.md`](../website/docs/developer-guide/provider-runtime.md:60)：

AI Gateway (Vercel)、OpenRouter、Nous Portal、OpenAI Codex、Copilot / Copilot ACP、
Anthropic (native)、Google/Gemini、Alibaba/DashScope、DeepSeek、Z.AI、Kimi/Moonshot、
MiniMax、Kilo Code、Hugging Face、OpenCode Zen/Go、AWS Bedrock、Azure Foundry、NVIDIA NIM、
xAI (Grok)、Arcee、GMI Cloud、StepFun、Qwen OAuth、Xiaomi、Ollama Cloud、LM Studio、
Tencent TokenHub、Custom（`provider: custom`）、命名自定义 provider（config.yaml 的 `providers:` 字典）。

> 完整内置集请以 `plugins/model-providers/` 目录为准——这份清单会变。

---

## 8. 辅助模型（side-LLM）路由

这是 Hermes 的一个特色：很多「副任务」用独立的小模型跑，以省成本。

**辅助任务**包括：curator、vision、embedding、标题生成、session_search、压缩。

它们通过 [`agent/auxiliary_client.py`](../agent/auxiliary_client.py:1) 的 `_resolve_auto_route` 解析。
每个任务都可以在 config.yaml 的 `auxiliary:` 段下钉住自己的
`provider/model/base_url/reasoning_effort`。

### 8.1 辅助调用的三条通道 + hooks

每次物理尝试都汇入：
- `_relay_sync_completion`
- `_relay_async_completion`
- `_relay_sync_stream`

在这里，[`agent/auxiliary_hooks.py`](../agent/auxiliary_hooks.py:1) 会发出
`pre_auxiliary_call` / `post_auxiliary_call` 事件
（仅观察、fail-open、带 `aux_task`）。

> **关键不变量（#79733）**：主循环的 `pre/post_api_request` 事件**绝不为**辅助调用触发。

---

## 9. 推理内容的处理（实用细节）

OpenAI 兼容 relay 可能把 `reasoning` 或 `reasoning_content` 返回为字符串、文本 part 字典，
或「文本 part 与字符串片段」的列表。Hermes 在下列所有位置第一次做字符串操作**之前**先扁平化：
主 stream、Relay 记录、同步与异步辅助 stream、完成响应的推理抽取。

- 片段保留显式空白；规范化不添加字段内分隔符
- 主 stream 与 Relay 记录保留完整粗体推理标题之间的现有段落分隔
- **推理与可见答案是分离的**

`delta.reasoning_details` 是不透明的 provider 记录列表：主 stream 与 Relay 记录**按到达顺序追加**，
不扁平化、不合并、不改写。provider 可能在最后一个 delta 发出完整记录，也可能跨多个 delta；
没有新记录的 chunk 省略该字段。收集到的记录经响应规范化与 assistant 消息存储进入 session replay，
包括嵌套的 signed payload。
（[`provider-runtime.md`](../website/docs/developer-guide/provider-runtime.md:30)）

---

## 10. Fallback 模型与凭证池

- **Fallback 模型**与**凭证池（credential pool）**属于**解析链代码**。
  按根目录规则，它们是**用真实 import + 临时 `HERMES_HOME` 做 E2E 测试的**，不是 mock。
  （[`agent/AGENTS.md`](../agent/AGENTS.md:106)）
- 相关模块：[`agent/fallback_cooldown.py`](../agent/fallback_cooldown.py:1)、
  [`agent/credential_pool.py`](../agent/credential_pool.py:1)、
  [`agent/credential_pool_model_cooldowns.py`](../agent/credential_pool_model_cooldowns.py:1)、
  [`agent/auxiliary_fallback_recovery.py`](../agent/auxiliary_fallback_recovery.py:1)。

---

## 11. 模型元数据

[`agent/model_metadata.py`](../agent/model_metadata.py:1) 持有**上下文长度与能力**。
[`agent/models_dev.py`](../agent/models_dev.py:1) 集成 models.dev 注册表。

provider profile 自己也能 `fetch_models` 探测目录——用户代理用
`hermes-cli/<version>`（有些 provider 在 WAF 后面对默认的 `Python-urllib/<ver>` UA 返回 403）。

---

## 12. 添加一个新 Provider

官方指南：[`adding-providers.md`](../website/docs/developer-guide/adding-providers.md:1) +
[`model-provider-plugin.md`](../website/docs/developer-guide/model-provider-plugin.md:1)。

核心结论：在 `plugins/model-providers/<your-provider>/` 下新增一个调用 `register_provider()` 的插件，
**就足够**让 `runtime_provider.py` 认出来——**解析器本身不需要加分支**。

---

## 13. 本篇小结与下一步

- Provider 是**声明式** `ProviderProfile`，从三层来源懒发现，用户覆盖内置。
- 解析优先级：显式请求 > config.yaml > env > provider 默认。
- 三种 API 模式收敛到同一个内部消息格式。
- 辅助模型有自己的路由与 hooks，**不触发**主循环的 API 请求事件。
- Fallback 与凭证池必须用真实 import 做 E2E 测试。

下一步 → [`07-state-and-session.md`](07-state-and-session.md)：SQLite 状态库与会话血缘。
