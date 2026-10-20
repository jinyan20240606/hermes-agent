# 11 · 扩展体系：插件 / 技能 / MCP

> **读法**：本篇回答一个核心问题——「我想让 Hermes 做它现在不会做的事，该动手改哪里？」
> 这不是一篇 API 手册，而是一篇**决策指南 + 源码地图**。每一节都先说清楚「为什么这样设计」，
> 再给出「代码在哪一行」。
>
> **读完你应该能**：
> 1. 拿到任何「加个能力」的需求，30 秒内判断它属于插件、技能还是 MCP；
> 2. 向别人解释为什么「插件不许改核心」不是洁癖而是架构约束；
> 3. 说清三种插件发现顺序为什么**故意不同**（later-wins / bundled-first / last-writer-wins）；
> 4. 写一个符合 8 条硬性标准的 SKILL.md，并知道每条标准是为了防哪种退化；
> 5. 解释 MCP 的信任为什么必须**按 profile 分别记录**。

---

## 本篇相对旧版新增

| 旧版（243 行，7 节） | 新版 |
|---|---|
| 三条路径一张表带过 | 补齐「扩展的到底是什么」这一层抽象，并给出 Footprint Ladder 的判定流程 |
| 「插件不碰核心」只有一句引用 | 补三条推论、`post_setup` 的设计动机、PR #5295 删掉 95 行 argparse 的完整故事 |
| 插件类型表 5 行 | 每种 kind 的发现顺序、为什么这样排、各自的坑（枚举不 import、lazy、manifest 不被 import） |
| 「发现时机陷阱」5 行 | 补 background discovery 与启动重叠约 150ms、`force=True` 的三类调用方、`suppress_plugin_discovery` 的 contextvar 动机（#123386） |
| hook 只有 6 个名字的举例 | **44 个 hook 全表**，按语义分 8 组，附返回值语义、`block` > `approve` 的优先级（#87420）、有界超时与 #6622 的死锁事故 |
| `PluginContext` 无 | 全表面清单 + 每个方法的关键约束（`override` 需要 `allow_tool_override`、`call_mcp` 默认拒绝、`inject_message` 的门控） |
| manifest 无 | v2 字段全表 + `_VALID_PLUGIN_KINDS` 5 值 + 未知字段的前向兼容策略 |
| host 隔离 5 行 | 三种模式、六条不变量、两张 ctx 表的区别、`HOST_OBJECT_BASES` 的「父进程造子类」手法、`HERMES_PLUGIN_HOST_PROCESS=1` 的自嵌套防护 |
| catalog 6 行 | 551 个 YAML、40 位 SHA 强制的理由、`removed.yaml` 的规范化比对、`.hermes-catalog.json` 为什么不可信 |
| 无 | packs / ledger / cadence / activation 摘要四个子系统 |
| 技能 4 小节 | 两表面 58/155 的真实数量、frontmatter 全字段、8 条标准逐条「为什么」、`<available_skills>` 与 delta note 通道的完整机制 |
| curator 3 行 | 四不变量 + `.usage.json` 字段 + `hermes curator` 13 个子命令 + `prune_builtins` 的精细语义 |
| MCP 3 小节 | 18 个文件的职责表、一背景 loop 的模型、OSV 恶意包预检、信任记录、熔断器、`optional-mcps/` 65 条、`hermes mcp serve` 反向暴露 |
| 无 | §16「在哪里打补丁」真表、§17 测试反模式、§18 自检题 46 道 |

---

## 0. 前置概念

### 0.1 一个 agent 为什么必须可扩展

如果你只写过一个「调 API 聊天」的程序，会觉得「扩展」这件事很陌生：所有代码都是你自己写的，
想加功能就改代码。但 Hermes 要面对的是真实的、成千上万种不同的用户环境：

- 有人要把 Hermes 接到公司内部的 Jira 上；
- 有人要它记住「我们团队的 commit message 格式」；
- 有人要它连自己的 PostgreSQL 只读副本；
- 有人要它跑在只能访问一个内网 MCP server 的机器上。

这些需求**不可能全部由核心团队实现**。如果每个需求都进核心，会发生三件坏事：

1. **启动变慢**：每个用户都要 import 所有人的代码；
2. **依赖爆炸**：接 Jira 需要 `jira` 包，跑在没网的机器上就装不上；
3. **风险聚合**：一个第三方插件的 bug 能让所有人的 `hermes` 起不来。

所以核心必须留出**稳定的扩展面**，让能力长在核心之外。

### 0.2 三种扩展手段的**本质区别**

这不是三个同义选项，它们扩展的是**完全不同的东西**：

| 手段 | 扩展的是什么 | 本质 | 类比 |
|---|---|---|---|
| **插件（Plugin）** | **代码** | 往进程里注入 Python 对象：工具、hook、provider、子命令 | 装一个 VSCode 扩展 |
| **技能（Skill）** | **知识** | 往上下文里注入 Markdown 指令：怎么做某件事 | 给新人一本 SOP 手册 |
| **MCP** | **协议** | 通过 JSON-RPC 让**另一个进程**提供工具 | 插一个 USB 设备 |

这个区分非常重要，因为**选错的代价不同**：

- 该用技能却写成插件 → 你得维护 Python 代码、跑测试、处理版本兼容，只为了一段「先读文件再改」的说明；
- 该用 MCP 却写成插件 → 你把一个本来能独立运行、独立重启的服务，硬塞进 agent 进程；
- 该用插件却写成技能 → 技能只能**告诉模型怎么做**，不能**真正连上那个 API**，模型会开始幻觉。

一句话记忆：

> **技能让模型更会做；插件让进程更有能力；MCP 让工具住在别处。**

### 0.3 「工具表面」与「上下文表面」

再补一个概念，后面反复要用：

- **工具表面（tool surface）**：模型能调用的函数列表。它是**每次 API 请求都全量发送**的，
  所以每加一个工具都在花用户的钱（详见 [`05-tools-system.md`](05-tools-system.md)）。
- **上下文表面（context surface）**：系统提示里塞进去的文字。`<available_skills>` 索引、
  记忆块、插件渲染的 prompt section 都在这里。它也是**进缓存前缀**的，
  所以改动它会破坏缓存（详见 [`04-prompt-and-caching.md`](04-prompt-and-caching.md)）。

插件可以往两个表面都加东西；技能只加上下文（通过 user 消息，见 §13.6）；MCP 只加工具表面。

### 0.4 「发现（discovery）」是什么意思

插件散落在四五个目录里（仓库内、用户家目录、项目目录、pip entry points），
Hermes 启动时必须**找到它们、import 它们、让它们注册东西**。这个过程叫发现。

发现的三个关键问题，本篇会反复回到：

1. **顺序**：同名插件谁赢？（三种 kind 的答案不同）
2. **时机**：什么时候扫描？扫早了没配置，扫晚了工具没注册上。
3. **作用域**：一个进程服务多个 profile（见 [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)），
   加载哪个 profile 的插件？

---

## 1. 三条路径全景对照

| 维度 | 插件 | 技能 | MCP |
|---|---|---|---|
| **物理位置** | [`plugins/`](../plugins/) 18 个目录<br>`~/.hermes/plugins/`<br>`./.hermes/plugins/`（需 `HERMES_ENABLE_PROJECT_PLUGINS`）<br>pip entry point `hermes_agent.plugins` | [`skills/`](../skills/)（12 类 / 58 个）<br>[`optional-skills/`](../optional-skills/)（23 类 / 155 个）<br>`~/.hermes/skills/` | [`optional-mcps/`](../optional-mcps/)（65 条 catalog）<br>`~/.hermes/config.yaml` 的 `mcp_servers:` |
| **扩展什么** | 工具、hook、CLI 子命令、slash 命令、provider、平台适配器、语言包 | 行为知识、流程、辅助脚本 | 外部工具（stdio / HTTP / SSE） |
| **形式** | Python 模块 + `plugin.yaml` | Markdown + frontmatter（+ `scripts/`） | 一个 MCP server 进程或 URL |
| **发现者** | [`PluginManager`](../hermes_cli/plugins.py:230) | `agent/prompt_builder.py` 扫盘 + `skill_view` | [`tools/mcp_tool_discovery.py`](../tools/mcp_tool_discovery.py:595) |
| **生效时机** | handler 立即；工具/prompt 下一会话；`deferred.mcp_servers` 等 `mcp.reload` | 立即（通过 user 消息注入） | 启动时连接，或 `lazy: true` 首次调用时 |
| **能改核心代码吗** | **绝对不能** | 不适用 | 不适用 |
| **跨 profile 隔离** | 可选 `plugins.isolation: host`（每 profile 一进程） | 按 `HERMES_HOME` 天然隔离 | 信任**按 profile 记录** |
| **失败影响** | `in_process` 下可拖垮宿主；`host` 下只死 host | 技能读不到，模型少一份知识 | 该 server 的工具消失，其它照常 |

### 1.1 三条路径的**代码守卫**在哪

读懂一张表不如记住三个「入口函数」：

```python
# 插件：唯一的加载入口
hermes_cli/plugins.py:1757      def discover_plugins(force: bool = False)
# 技能：索引构建（进系统提示）
agent/prompt_builder.py:1472    "<available_skills>..." 的拼接处
# 技能：按名加载（进 user 消息）
agent/skill_commands.py:227     def _load_skill_payload(...)
# MCP：唯一注册入口
tools/mcp_tool_discovery.py:595 def discover_mcp_tools(allowed_mcp_names=None)
```

### 1.2 一个需求走哪条路：判定流程

```
需求：「我要让 Hermes 能查我们的内部 Wiki」
        │
        ├─ 已经有 MCP server 了？ ────────────────────→ 走 MCP（配置一个 server）
        │
        ├─ 只是一套「怎么查」的流程/命令，模型能自己跑？ ──→ 走技能（写 SKILL.md + script）
        │
        ├─ 需要 Python 里调 SDK / 长连接 / 状态？ ──────→ 走插件（register_tool）
        │
        └─ 上面都不合适，且是普遍需求、别处无法实现？ ───→ 才考虑新核心工具（几乎总是错的）
```

---

## 2. Footprint Ladder：从最小足迹开始

根 [`AGENTS.md`](../AGENTS.md) 里的原话（改写自英文原文的层级顺序）：

> **Footprint ladder**（取能解决问题的最高一级）：
> 扩展现有代码 → CLI 命令 + 技能 → 服务门控工具（`check_fn` 回答可达性/是否启用，
> 绝不是每会话表面）→ 插件 → catalog 里的 MCP server → 新核心工具
> （只在「基础、广泛有用、别处无法实现」时）。

为什么是「最高一级」而不是「最方便的一级」？

因为**每一级都在增加永久成本**：

| 层级 | 一次性成本 | 永久成本 |
|---|---|---|
| 扩展现有代码 | 最小 | 无 |
| CLI 命令 + 技能 | 小 | 技能索引里多一行 |
| 服务门控工具 | 中 | 每次 API 请求都发这个工具的 schema |
| 插件 | 中 | 用户多一个可装可不装的东西 |
| MCP server | 大 | 一个额外进程 + 网络 + 认证 |
| **新核心工具** | 大 | **所有用户、每次请求都付 token** |

最后一行是关键：**核心工具是唯一让全体用户为你一个需求付费的选项**。所以门槛最高。

### 2.1 被明确拒绝的形态

[`AGENTS.md`](../AGENTS.md) 列了一张「即使做得很好也会被拒」的清单，其中与扩展相关的：

- **没有具体消费者的 hook** —— 投机性基础设施；
- **为不含秘密的配置新增 `HERMES_*` 环境变量** —— `.env` 只放秘密，行为放 `config.yaml`；
- **在 instructional tools 上加 `offset`/`limit` 分页** —— 见 §13.7；
- **改核心文件的插件** —— 必须做成独立插件仓库。

---

## 3. 插件铁律：绝不碰核心

### 3.1 原文

来自 [`plugins/AGENTS.md:7`](../plugins/AGENTS.md:7)，署名 Teknium，2026 年 5 月：

> 插件住在自己的目录里，在我们提供的 ABCs / hooks / `ctx` 表面上工作。
> 插件**不得**修改 `run_agent.py`、`cli.py`、`gateway/run.py`、`hermes_cli/main.py` 等。
> 如果它需要框架缺少的能力，**拓宽通用的插件表面**（新 hook、新 ctx 方法）让插件使用它——
> **绝不把插件特定逻辑硬编码进核心。**

### 3.2 三条推论

**推论一：安装体验必须走已有的门。**

如果插件需要用户填 API key，它**不能**自己加一个 `hermes myplugin-setup` 顶层命令。
正确做法是走 `hermes memory setup` 这类已有入口，由框架调用 `provider.post_setup(hermes_home, config)`。

为什么？因为「安装/配置」是**所有插件共享的体验**：要支持 CLI、TUI、Desktop 三个界面，
要有配置校验、要有密钥写进 `.env` 而不是 `config.yaml`、要能回滚。
每个插件自己重写一遍，就是 N 份不一致的实现。

**推论二：没有消费者的 hook 会被拒。**

一个 hook 一旦存在，就进了 `VALID_HOOKS`，成了**承诺**：以后不能删、不能改签名。
所以加 hook 的成本远高于加一个内部函数。PR #5295 就是这么处理 honcho 的：
它给插件加了一整段 argparse，用来在 CLI 里单独配置自己——删掉了 95 行，
改成让插件走 `post_setup()`。

**推论三：需要新能力 → 拓宽表面，而不是打洞。**

举个真实场景：某个插件想在工具调用前拦截并修改参数。
它不能去改 `model_tools.py`，而是应该请求一个 `pre_tool_call` 的返回值语义
（`{"action": "block"}` / `{"action": "approve"}` / 修改 args）。
这个 hook 已经在 [`hermes_cli/plugins.py:109`](../hermes_cli/plugins.py:109) 里，
且**所有插件都能用**。

### 3.3 这条铁律的技术理由

不是审美问题，是三个硬约束：

1. **prompt 缓存**（见 [`04-prompt-and-caching.md`](04-prompt-and-caching.md)）：
   插件若能在任意时刻改系统提示，缓存前缀就废了。所以插件的 prompt section
   只在**会话构建时**渲染一次（`render_system_prompt_sections`）。
2. **多 profile**：一个进程服务多个 profile。插件改全局状态 = 污染别人的 profile。
3. **可卸载**：`hermes plugins remove` 后必须干净。插件碰了核心，卸载就是不可能的。

---

## 4. 五种插件 kind 与它们的**不同**发现语义

这是全篇最容易记错的地方。来自 [`plugins/AGENTS.md:69`](../plugins/AGENTS.md:69)。

### 4.1 对照表

| Kind | 位置 | 发现者 | 顺序语义 |
|---|---|---|---|
| **General**（通用） | `plugins/<name>/`、`~/.hermes/plugins/`、`./.hermes/plugins/`、pip entry points | [`PluginManager`](../hermes_cli/plugins.py:230) | **later-wins**（后加载的覆盖先加载的） |
| **Memory provider** | `plugins/memory/<name>/` | [`plugins/memory/__init__.py`](../plugins/memory/__init__.py:1) | **bundled-first**（内置的赢） |
| **Model provider** | `plugins/model-providers/<name>/` | [`providers/__init__.py:635`](../providers/__init__.py:635) `_discover_providers()` | **last-writer-wins** |
| **Context engine / image-gen / 其它 provider** | `plugins/context_engine/`、`plugins/image_gen/` … | ABC + 编排器 + 每插件目录 | 单例，第二个注册被拒绝 |
| **Platform adapter** | `plugins/platforms/<name>/adapter.py` | gateway 启动路径 | token 锁 + 作用域 secret 规则 |

### 4.2 为什么 general 是 later-wins

用户想覆盖一个内置插件时，最自然的动作是：

```bash
cp -r plugins/kanban ~/.hermes/plugins/kanban
# 改一改
```

如果 bundled 赢，这个动作就静默失效了。所以 general 的规则是
**project > user > bundled**，[`plugins_discovery.py:222`](../hermes_cli/plugins_discovery.py:222)
的注释写得很直接：

> 后出现的源在 key 冲突时获胜（project > user > bundled）：`~/.hermes/plugins/<name>`
> 下同名的副本就是文档里说的覆盖内置插件的方式，并且会记日志。

**但有一个防伪检查**（同一个函数里）：

> 如果用户/项目的 manifest 声明了某个 bundled 插件的 key，而**目录名不同**，
> 那是冒名者，不是覆盖 —— 会被忽略。

为什么？想象你 `git clone` 了别人的插件仓库，它把自己的 `plugin.yaml` 里的 `name:` 写成 `kanban`。
如果不检查目录名，`hermes plugins enable kanban` 就会激活**一段完全不相关的代码**——
用户以为自己在启用内置的看板，实际启用了陌生人的东西。

### 4.3 为什么 memory 是 bundled-first

memory provider 的激活方式是**按名字**：

```yaml
memory:
  provider: retaindb
```

名字是用户配置里写死的。如果用户目录里恰好有个同名目录能覆盖内置的，
那么「我没装任何东西」的用户会被一个掉进来的目录静默改变行为。

所以 memory 的规则反过来（[`plugins/memory/__init__.py:119`](../plugins/memory/__init__.py:119)）：

> `(name, path)`：bundled，然后 user-installed，然后 project-local；**先到先得**。

还有一个实现细节值得学：**枚举时不 import**。
`discover_memory_providers()` 返回 `[(name, description, is_available)]`，
它**读目录和元数据**，不执行插件的 `__init__.py`。原因是
`hermes --help` 会列出可用 provider——你不想为了打印一个帮助菜单，
把 42 个 provider 的模块全 import 一遍（有些还会连数据库）。

同理，memory 插件的 `cli.py`（`register_cli(subparser)`）只由
`discover_plugin_cli_commands()` 为**当前激活的那个 provider** 挂载，
所以 `hermes --help` 永远干净。

### 4.4 为什么 model-provider 是 last-writer-wins 且**绝不被 PluginManager import**

`_discover_providers()` 的顺序是：

1. `plugins/model-providers/<name>/`（repo 内置）
2. legacy 的 `providers/<name>.py`（向后兼容）
3. `$HERMES_HOME/plugins/model-providers/`（per profile，**在查找时**才加载）

每一步都 import 模块，模块顶层调 `register_provider(ProviderProfile(...))`。
后来者覆盖先来者，所以用户能覆盖内置 profile。

关键陷阱在 [`plugins/AGENTS.md:75`](../plugins/AGENTS.md:75)：

> `PluginManager` 记录 `kind: model-provider` 的 manifest，但**不 import 它们**
> （否则会双重实例化）；没有 `kind:` 的 manifest 由来源启发式自动归类
> （`register_provider` + `ProviderProfile`）。

「双重实例化」意味着什么？如果 `PluginManager` 和 `providers._discover_providers()`
都 import 同一个模块，模块顶层的 `register_provider()` 会跑两次。
ProviderProfile 里可能有连接池、可能有缓存字典——两份实例 = 两份连接 = 配额翻倍。

### 4.5 单例类 provider：第二个注册被拒

`ctx.register_context_engine(engine)` 的 docstring（[`plugins.py:709`](../hermes_cli/plugins.py:709) 附近）：

> 注册（唯一的）`agent.context_engine.ContextEngine`，替换内置的 `ContextCompressor`；
> 第二次注册会带 warning 被拒绝。

上下文压缩是**整个会话只有一条路径**的东西，两个引擎同时存在没有意义
（谁先跑？谁的结果算数？）。同理 image-gen 是「每个 provider 一个名字」的注册表，
但一次生成只走一条。

---

## 5. 发现的三个时机问题

### 5.1 `discover_plugins()` 只是 import `model_tools.py` 的副作用

这是新手最容易踩的坑，[`plugins/AGENTS.md:79`](../plugins/AGENTS.md:79)：

> **发现时机陷阱**：`discover_plugins()` 只作为 import `model_tools.py` 的副作用运行。
> 不先 import `model_tools.py` 就读插件状态的代码，必须显式调用 `discover_plugins()`
> （幂等）。

为什么挂在 `model_tools.py` 上？因为工具注册必须发生在「agent 开始构建工具列表」之前，
而 `model_tools.py` 正是那个模块。所有真正跑 turn 的路径都会 import 它，
所以插件在正确时机被加载——**不需要在每个入口手动调用**。

但反过来说：任何**不跑 turn** 的代码（cron 调度器、`hermes plugins list`、
gateway 的平台事件、TUI 的 slash worker、query 模式）如果读插件状态，就可能看到空注册表。
这就是 #64178 记录的问题，解法是让 `invoke_hook()` 自己也懒发现：

```python
# hermes_cli/plugins.py:1864
def invoke_hook(hook_name: str, **kwargs: Any) -> list[Any]:
    """... Ensures plugins are discovered on first invocation so callers in processes that never
    explicitly call ``discover_plugins()`` (gateway platform events, TUI slash workers, query mode,
    cron) still fire callbacks registered by user plugins (tracking #64178)."""
    return _delivery_manager().invoke_hook(hook_name, **kwargs)
```

即：**调用 hook 这个动作本身就是一次懒发现**。

### 5.2 `force=True`：mid-run 加载

普通的 `discover_plugins()` 在 `_discovered` 标志上短路，所以调用一万次也只扫一次。
但有一类路径必须**重新扫**：

- 任何界面的 `install` / `enable` / `update` 成功后；
- `reload-plugins` 这个 RPC/命令。

它们调用 `discover_plugins(force=True)`，然后在这次扫描内部，
`PluginManager.on_plugin_loaded` 会带上**激活摘要**（[`hermes_cli/plugins_activation.py:31`](../hermes_cli/plugins_activation.py:31)）：

| 东西 | 什么时候真的生效 |
|---|---|
| handlers（hook 回调、slash 命令） | **立即** |
| tools、prompt sections | **下一会话** |
| `deferred.mcp_servers` | 直到 `mcp.reload` |

为什么工具不能立即生效？因为当前会话的工具列表已经发给模型了，
中途加入新工具会改变工具表面 → 破坏缓存前缀 → 而且模型可能看不懂突然出现的工具名。
（这与 [`04-prompt-and-caching.md`](04-prompt-and-caching.md) 的「缓存前缀神圣」是同一条铁律。）

**绝不从 RPC 发 `on_plugin_loaded`** —— 因为 RPC 可能在任意线程、任意 profile 作用域里执行，
而这个事件必须由**做扫描的那一次调用**发，否则订阅者会拿到错的作用域。

### 5.3 `suppress_plugin_discovery()`：用 contextvar 而不是环境变量

[`plugins_discovery.py:35`](../hermes_cli/plugins_discovery.py:35) 的注释讲了一个真实事故：

> 这个标志在调用方**读取某个 profile 的配置但不想让它的插件进入本进程**时设置：
> multiplex 预检会加载一个**已停用（parked）** profile 的 gateway 配置来跑重复凭证检查，
> 而 `load_gateway_config` 会在它运行的作用域内发现插件。import 它们就等于
> 为一个操作员已经从宿主里拿掉的 profile 跑了 `register()`（线程、DB 连接）（#123386）。

所以要一个开关来抑制。为什么不用环境变量？

> 用 **contextvar 而不是 env flag**：它绝不能泄漏到其它线程，也不能比这次读活得更久。

环境变量是**进程级**的：设了之后所有线程、所有后续请求都受影响。
而 contextvar 是**执行上下文级**的：退出 `with` 块就恢复，
`spawn_context_thread` 会把当前 context 复制给新线程但不会反向污染。

这个模式在 Hermes 里反复出现（profile 作用域、secret scope 都是），
是理解 [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md) 的预备知识。

### 5.4 后台发现：与启动时间重叠

[`plugins.py:1768`](../hermes_cli/plugins.py:1768) `start_background_plugin_discovery()`：

> 在守护线程里跑发现，与 CLI 启动的其余部分重叠（约 150ms）。
> 每个同步消费者都通过 `discover_plugins()` **join** 它，
> 所以没有人会看到半加载的注册表。

这是一个典型的「用并发换延迟但不牺牲正确性」的模式：
后台线程先跑，任何人要用的时候 `_join_background_discovery()` 等它完成。
如果后台已经跑完，join 立即返回；如果没跑，直接同步跑一遍。

---

## 6. 44 个 hook 全目录

`VALID_HOOKS`（[`hermes_cli/plugins.py:109`](../hermes_cli/plugins.py:109)）
是**唯一权威清单**。它有 44 个成员，且同时充当 shell hook 的允许列表。

> **读法提示**：不要试图背下来。记住分组的**语义边界**，需要时回来查。
> 分组是我的整理，代码里是按注释块排列的。

### 6.1 工具与消息变换（6 个）

| hook | 触发点 | 返回值语义 |
|---|---|---|
| `pre_tool_call` | 每次工具调用前 | `{"action": "block", "message"}` 否决，message 成为工具结果；`{"action": "approve", "message", "rule_key"}` 升级到人工审批；也能改 args |
| `post_tool_call` | 每次工具调用后 | 观察/记录 |
| `transform_tool_result` | 工具结果进入上下文前 | 返回替换字符串（第一个非 None 赢） |
| `transform_terminal_output` | 终端输出 | 同上 |
| `transform_llm_output` | 模型输出后 | 返回替换字符串（第一个非 None 赢）或 None |
| `pre_verify` | 每 turn 一次，当 agent 改过代码将要验证/收尾时 | `{"action": "continue", "message"}` 或 Claude-Code 风格 `{"decision": "block", "reason"}` 继续；其它值结束。受 `agent.max_verify_nudges` 限次 |

**`pre_tool_call` 的优先级是重点**（[`plugins.py:1976`](../hermes_cli/plugins.py:1976) 的 docstring）：

> 优先级是 `block` > `approve` > 无，**不是注册顺序**：
> 任何插件的合法否决都赢过早注册插件的人工确认请求（#87420）；
> 多个 `approve` 之间，第一个合法的赢。

为什么会出这个 bug？想象两个插件：
- 插件 A（安全扫描器）说「这个命令危险，**拦截**」；
- 插件 B（审计器）说「这个命令要**人工确认**」。

如果按注册顺序，A 先注册、B 后注册，那么结论变成「让人确认一下」——
一个本该被硬拦的破坏性命令，变成了用户可能点「同意」的弹窗。
**安全性必须不依赖于注册顺序。**

### 6.2 LLM 调用前后（6 个）

| hook | 触发点 |
|---|---|
| `pre_llm_call` / `post_llm_call` | 主对话的每次 LLM 调用 |
| `pre_api_request` / `post_api_request` | 每次**物理请求**（含重试） |
| `api_request_error` | 请求失败 |
| `transform_api_error_classification` | 失败后、`agent/error_classifier.classify_api_error()` **之前**，每失败一次调用一次 |

`transform_api_error_classification` 的返回值是：

```python
None 或 {
    "reason": <FailoverReason 名字>,       # 必需
    "retryable": bool,
    "should_compress": bool,
    "should_rotate_credential": bool,
    "should_fallback": bool,
    "message": str,
    "error_context": dict,
}
```

**隐私警告写在同一段注释里**：`error_message` / `error_body` 可能**未脱敏**。
一个想要「自动分类 429」的插件，也能看到用户 prompt 的片段。
这是 hook 表面有意为之的能力代价。

它也是唯一的 `SHELL_UNSUPPORTED_HOOKS` 成员：

```python
# hermes_cli/plugins.py:206
SHELL_UNSUPPORTED_HOOKS: set[str] = {"transform_api_error_classification"}
```

原因：`VALID_HOOKS` 兼作 **shell hook 的允许列表**（脚本形式的插件）。
但 shell 脚本的输出解析器**没有通道**表达这个 hook 的复杂指令结构，
所以它被**显式拒绝**而不是「接受但静默忽略输出」。
——静默忽略是更糟的选择：插件作者会以为自己的逻辑生效了。

### 6.3 辅助调用（2 个，与主对话严格分开）

| hook | 触发点 |
|---|---|
| `pre_auxiliary_call` | 每次辅助 LLM 调用的**每次物理 provider 尝试**之前 |
| `post_auxiliary_call` | 同上，之后 |

「辅助调用」= 标题生成、压缩、MoA、视觉、审批……（[`agent/auxiliary_hooks.py`](../agent/auxiliary_hooks.py)）。
payload 与 `pre/post_api_request` 同形，**外加 `aux_task`**。

为什么要分成独立事件？注释给了答案（#79733）：

> 独立事件，这样 turn 作用域的 `*_api_request` 订阅者**永远不会收到辅助流量**。

不做这个区分的后果：一个统计「本 turn 花了多少 token」的插件，
会把「给这段对话起标题」也算进去，然后用户看到「你这轮花了 5 万 token」——纯属噪声。

### 6.4 流式观察者（4 个，**不在 token 路径上**）

| hook | 触发点 |
|---|---|
| `on_stream_start` | 流开始 |
| `on_stream_delta` | 每个增量 |
| `on_stream_end` | 流结束 |
| `on_interim_message` | 中间消息 |

注释强调（[`plugins.py:113`](../hermes_cli/plugins.py:113) 附近）：

> 流式观察者（`agent.plugin_stream_hooks`），**在 token 路径之外**；
> payload 是不可变的规范化文本/生命周期，**不能变换流**。

这是性能与安全的双重设计：
- 不能变换 → 一个慢插件不会让流卡顿（它的输出被排队，见 `_QUEUE_MAX`）；
- 在 token 路径外 → 每个 delta 都同步调 N 个插件是不可能接受的。

### 6.5 会话与技能生命周期（7 个）

| hook | 触发点 |
|---|---|
| `on_session_start` | 会话开始 |
| `on_session_end` | 会话结束 |
| `on_session_finalize` | 会话归档/持久化收尾 |
| `on_session_reset` | `/new` 之类重置 |
| `on_skill_lifecycle` | 技能生命周期事实（插件可见本地技能名） |
| `subagent_start` / `subagent_stop` | 子 agent 起停（见 [`13-subagents-delegation.md`](13-subagents-delegation.md)） |
| `agent_loop_stopped` | 一个 turn 被中途打断（`/stop`，或 `/new` 的 running-agent 快速路径） |

**后四个会话 hook 的作用域问题**是本节最重要的技术点，
[`plugins/AGENTS.md:91`](../plugins/AGENTS.md:91) 说得很清楚：

> 生命周期 hook 在**拥有该 profile 的作用域**下触发，**由调用方绑定**。
> `on_session_start`/`on_session_end`/`sync_turn`/`shutdown` 从 turn（已绑定）
> **以及**从驱逐、关闭、`tui_gateway` teardown、cron 完成触发
> （由调用方通过 `_run_release_in_profile_scope`、`_session_profile_runtime_scope`、
> `_profile_cron_scope` 绑定）。

翻译成人话：**turn 内触发时，作用域是天然正确的**（因为跑 turn 的线程已经绑好了 profile）。
但「驱逐一个闲置会话」「网关关闭」「cron 跑完」这些动作发生在**没有 turn 的线程**里。
如果不显式绑，插件会读到**启动 profile** 的 `HERMES_HOME` 和密钥——
在多 profile 部署里，这是**数据串了别人的租户**。

`agent_loop_stopped` 的返回值被忽略（纯观察），payload 是
`session_key, platform, reason, invalidation_reason`。

### 6.6 审批与人工输入（4 个）

| hook | 触发点 | 说明 |
|---|---|---|
| `pre_approval_request` | 审批请求发出前 | 返回值忽略；**要否决请用 `pre_tool_call`** |
| `post_approval_response` | 审批结束 | 多 `choice` / `decided_by` |
| `on_human_input_request` | 向人提问前 | `tools/human_input_hooks.py` |
| `on_human_input_resolved` | 人回答后 | 同上 |

`pre_approval_request` 的 `surface` 取值很有意思，能看出审批系统被复用的范围：

```
"cli" | "gateway" | "smart" | "mcp-elicitation/<server>" | "mcp-trust/<server>" | "vault-payment"
```

也就是说：**CLI 审批、网关审批、MCP 的 elicitation、MCP 的信任门、vault 支付确认**
走的是同一套审批基础设施，只是 `surface` 不同。这样插件只需订阅一次就能看到所有人工决策。

### 6.7 网关与房间（4 个）

| hook | 触发点 | 返回值 |
|---|---|---|
| `pre_gateway_dispatch` | 每个入站 `MessageEvent`，在内建事件守卫之后、**认证/配对之前** | `{"action": "skip", "reason"}` 丢弃；`{"action": "rewrite", "text"}` 改写；`"allow"`/None 正常 |
| `post_gateway_admission` | 准入之后 | fail-open 消费 |
| `gateway_platform_event` | 平台原生事件（**规范化信封**，绝不是原始 SDK 对象） | 观察 |
| `on_room_member_activity` | 托管群聊成员的实时运行时事件 | 观察，按消费者排队 |

**`pre_gateway_dispatch` 在认证之前**这一点极其重要，因为它决定了它能被谁用：

- 好处：能在认证前做「这个群被拉黑了，直接丢」；
- 风险：它拿到的事件**尚未验证来源**，所以 payload 不能当成可信输入。

`gateway_platform_event` 已接线的具体事件（注释里列得很细）：

- Telegram：`reaction`、`message_edited`
- Discord：`message_edited`、`message_deleted`、`thread_created`、`thread_renamed`

并且明确写了政策：

> 其它事件类型和 hook 名字只在**有真实触发点与 payload 契约**时才加入；
> **不提前注册惰性的 `VALID_HOOKS` 表面**。

这又是「没有消费者的 hook 会被拒」的执行细节。

`on_room_member_activity` 的 payload 是**客户端安全的会话事件载荷（审批已脱敏）**，
且**绝不写入持久 room log**。为什么？因为房间日志是要回放的，
而运行时活动（reasoning delta 等）是易变的、量大的、且可能含未脱敏内容。

### 6.8 Kanban 与转录（6 个）

| hook | 触发点 | 关键约束 |
|---|---|---|
| `kanban_task_claimed` | **调度器**在 spawn 前 | 忽略返回值 |
| `kanban_task_completed` | **worker**（或驱动它的进程） | 多 `summary` |
| `kanban_task_blocked` | 同上 | 多 `reason` |
| `on_kanban_worker_spawned` | 调度器，PID 持久化后、**在 dispatch 锁内** | 必须快 |
| `on_kanban_worker_exited` | tick 派生（死 PID 回收） | 有 `exit_kind` |
| `on_kanban_worker_stale_claim` | TTL 过期 claim 被回收 | 活 PID 的延长**不**触发 |
| `on_kanban_task_updated` | 已提交的任务行写入 | 只给**字段名**，永不给值 |
| `on_kanban_dispatch_tick` | 每次 `dispatch_once`，**严格在锁释放之后** | 见下方事故 |
| `pre_transcription` | provider 解析后、**任何后端运行前** | 返回 dict 可改 `prompt`/`language`/`model`；`file_path` 只读 |

三个细节值得单独记：

**（1）kanban 任务观察者在 DB commit 之后触发**：

> 触发在 DB 提交之后，这样一个慢插件永远不会握住 SQLite 写锁。

这是一个通用的模式：**回调永远不要持有数据库锁**。

**（2）`on_kanban_dispatch_tick` 的锁位置改过一次**：

> 每次 dispatcher tick 在 `dispatch_once` 里触发一次，
> **严格在 board 的单写者 dispatch 锁释放之后**
> （#56066 的原始实现是在锁内触发——#64231 的处置强制要求改成锁后重移植），
> 这样一个慢订阅者永远不会延长写者的临界区。

即：同一个 hook，位置差几行，就是「慢插件拖垮整个调度器」和「慢插件只拖慢自己」的区别。

**（3）`task_updated` 只给字段名**：

> `changed_fields` —— **只有字段名，从不是值**。

隐私设计：任务描述里可能有敏感信息，而「哪些字段变了」足够驱动 UI 刷新，
不需要把内容广播给每个订阅者。

### 6.9 其它（2 个）

| hook | 触发点 | 说明 |
|---|---|---|
| `pre_command` | 已识别的 slash 命令 handler 之前（CLI 与 gateway 规范派发） | v1 **返回值被忽略**；返回指令形状的 dict 会打 debug 日志 |
| （同上，含 `pre_transcription`） | | |

`pre_command` 有两个刻意的排除（注释原文）：

> 为 gateway 的 **running-agent 拦截路径**（`/stop`、`/approve`、`busy_policy`）
> **故意不触发** —— 一个慢的/恶意的插件绝不能碰操作员的逃生舱。

这是整篇最值得抄的一条设计原则：**紧急控制路径必须是插件不可达的**。

### 6.10 hook 的调用是**有界**的

`_resolve_hook_callback_timeout()`（[`plugins.py:1125`](../hermes_cli/plugins.py:1125)）读
`plugins.hook_callback_timeout`，默认 30s，`<= 0` 表示……

`invoke_hook` 的 docstring（[`plugins.py:1867`](../hermes_cli/plugins.py:1867)）说：

> `_HOOK_TIMEOUT_BOUNDED_HOOKS` 里的热路径/观察者 hook 和策略 hook `pre_tool_call`
> 受 `plugins.hook_callback_timeout`（默认 30s）约束。
> 超时后 worker 被**遗弃（不 join）**，这样不会重新引入 #6622 的挂起。
> **超时或仍在运行的 `pre_tool_call` 回调 fail closed，返回 block 指令；其它有界 hook fail open（跳过）。**

两条结论：

1. **Python 不能杀线程**。所以「超时」只能是「不再等它」，那个 worker 会继续跑到自己结束。
   这是所有 Python 插件的物理限制，不是设计疏忽。
2. **fail-closed 只在安全路径上**。`pre_tool_call` 是安全门 → 不确定就拦。
   其它 hook 是增强 → 不确定就跳过（否则一个卡死的日志插件能让整个 agent 停摆）。

`plugins.load_timeout_seconds`（默认 10s，[`plugins_loader.py:40`](../hermes_cli/plugins_loader.py:40)）
是另一层：它是 **import + register() 的总时限**，超时的插件以具名原因被跳过。
[`plugins_loader.py:43`](../hermes_cli/plugins_loader.py:43) 还加了上限
`_MAX_ABANDONED_LOADERS = 8`：

> Python 不能杀线程，所以 worker 被遗弃为 daemon；这个上限约束**一个进程最多能累积多少**
> 被遗弃的加载器（#98382）——超过之后，后续加载被**拒绝**而不是内联执行。

「拒绝而不是内联执行」很关键：如果超限后改成同步加载，
一个恶意/卡死的插件就能让**主线程**永久阻塞——那才是真正的灾难。

---

## 7. `PluginContext`：插件能摸到的全部表面

`PluginContext`（[`hermes_cli/plugins.py:230`](../hermes_cli/plugins.py:230)）是插件与核心之间**唯一**的接口。
它的 docstring 只有一句：

> 给插件的门面，让它们能注册工具和 hook。

### 7.1 方法全表（按用途分组）

**身份与配置**

| 方法 | 行号 | 说明 |
|---|---|---|
| `plugin_id` | `:257` | 注册表用的有效 id（`manifest_key(manifest)`） |
| `has_plugin(plugin_id)` | `:261` | 另一个插件是否已加载启用（`requires_plugins` 的运行时探测） |
| `get_config(key, default)` | `:278` | 读 `plugins.entries.<id>.settings.<key>`，回退到旧的 `config` 子树 |
| `set_config(key, value)` | `:294` | 原子写一个值 |
| `profile_name` | — | 当前 profile 名 |
| `has_capability(capability)` | `:501` | 能力探测；**未知 id / 读不到同意 → False（fail closed）** |
| `state` | `:299` | profile 作用域的持久 JSON 门面（`PluginState`） |
| `llm` | `:377` | 受控的 LLM 调用门面（override 需操作员 `allow_*`） |
| `subagent_lifecycle` | — | 子 agent 生命周期门面 |
| `current_cron_execution` | — | 当前 cron 执行上下文 |

**注册东西**

| 方法 | 行号 | 关键约束 |
|---|---|---|
| `register_tool` | `:456` | `override=True` 覆盖内置工具需要 `plugins.entries.<id>.allow_tool_override: true` |
| `register_hook` | `:933` | hook 名必须在 `VALID_HOOKS` 里 |
| `register_cli_command` | `:633` | `hermes <name> ...`，在启动时接进 argparse 树，**不改 `main.py`** |
| `register_command` | `:647` | 会话内 slash `/name`；**与内置命令冲突则跳过** |
| `register_memory_provider` | `:723` | 按名字激活 |
| `register_platform` | `:777` | host 隔离下**不可用**（见 §9） |
| `register_locale_dir` | `:915` | 语言包目录 |
| `register_context_engine` | `:709` | 单例，第二个被拒 |
| `register_auxiliary_task` | — | 辅助任务槽 |
| `register_redaction_patterns` | — | 脱敏正则 |
| `on_unload(callback)` | `:449` | 卸载钩子 |

**运行时动作**

| 方法 | 行号 | 说明 |
|---|---|---|
| `dispatch_tool` | `:674` | 通过注册表派发（自动注入 `parent_agent`） |
| `call_mcp` | `:509` | 同步调 MCP 工具；**默认拒绝**（需 `mcp_allowlist`） |
| `inject_message` | `:603` | 往网关注入消息；受 `_gateway_injection_allowed()` 门控 |
| `spawn_task(coro)` | — | 在受控事件循环里起任务 |

### 7.2 `register_tool` 的 `override` 门

这是一个值得全文引用的安全设计（[`plugins.py:459`](../hermes_cli/plugins.py:459)）：

> `override=True` 会替换同名内置工具（没有它，被另一个 toolset 占用的名字会被拒绝），
> 并且需要操作员通过 `plugins.entries.<plugin_id>.allow_tool_override: true` 显式同意
> —— 否则任何已启用的插件都能静默替换 `write_file` 这样的特权内置工具。

想一下攻击场景：你安装了一个「markdown 格式化」插件。它在 `register()` 里写：

```python
ctx.register_tool("write_file", "files", schema, my_handler, override=True)
```

如果不需要同意，它就把**所有文件写入**导向自己的实现——可以把内容写到别处、可以记录到远端。
用户完全不会察觉，因为工具名没变。

同一个信任门模式也用在了 `ctx.llm` 的 provider/model override 上（#23194）。

### 7.3 `call_mcp` 是**每 server 授权**

[`plugins.py:509`](../hermes_cli/plugins.py:509)：

> 通过 `tools.mcp_tool` 的原生客户端同步调用 server 上的工具
> （同一套信任门、熔断器、重连——**绝不另开一条并行连接**）。
> 不在 `plugins.entries.<plugin_id>.mcp_allowlist` 里的 server 抛 `PermissionError`（**默认拒绝**）。
> `timeout` 夹到 1–600s；超过约 64KB 的结果被截断并加标记。

注释还写着未来的方向：

> 这是**每 server** 的授权，刻意不是对所有已配置 server 的**环境授权（ambient authority）**。
> TODO(#64228)：等声明的能力模型落地后，把每 server allowlist 换成它（每工具授权、过期、只读/读写）。

「ambient authority」是安全领域的核心概念：如果一个插件能调任何 MCP server，
那么它实际上拥有了用户配置的所有外部权限。默认拒绝让每个授权都是**显式的**。

### 7.4 `PluginState`：有配额的持久状态

[`plugins_state.py:134`](../hermes_cli/plugins_state.py:134)：

> 一个插件拥有的、原子的、**配额有界**的 JSON 键值状态。

- 路径：`$HERMES_HOME/plugin-data/<data_namespace>/state.json`
- 配额：`_PLUGIN_STATE_QUOTA_BYTES = 10 * 1024 * 1024`（10 MB，[`:19`](../hermes_cli/plugins_state.py:19)）
- 键规则：1–128 字符，字母/数字/`_`/`-`/`.`/`:`，且**不许含 `..`**

为什么要配额？因为 `~/.hermes` 是用户的家目录，不能让它变成一个插件可以无限写的磁盘。
为什么 `data_namespace` 要区分 `plugin_id` 和 `skill_namespace`？
因为便携插件（portable plugin）可能带着技能一起装，两者需要共享数据目录。

---

## 8. manifest（`plugin.yaml`）v2

### 8.1 五种 kind

```python
# hermes_cli/plugins_manifest.py:25
_VALID_PLUGIN_KINDS: set[str] = {"standalone", "backend", "exclusive", "platform", "model-provider"}
```

这五个和 §4 的「发现语义」不是一一对应关系，值得单独说清：

- `standalone`：普通的、自包含的插件；
- `backend`：随 Hermes **自动加载**的后端能力（不需要用户 enable）；
- `exclusive`：某个类别里**独占**的（如 context engine）；
- `platform`：平台适配器（**延迟加载**，只在对应平台启用时）；
- `model-provider`：模型 provider profile（**由 `providers` 自己发现，不由 `PluginManager` import**）。

### 8.2 已知字段

[`plugins_manifest.py:31`](../hermes_cli/plugins_manifest.py:31) 的
`_KNOWN_MANIFEST_FIELDS` 有 35 个字段。按用途分类：

**基本元数据**：`name`、`version`、`description`、`author`、`label`、`license`、`homepage`、`tags`

**版本与依赖**：`manifest_version`、`api_version`、`requires_hermes`、`python_runtime`、
`requires_plugins`、`python_dependencies`、`pip_dependencies`、`external_dependencies`

**能力声明**：`provides_tools`、`provides_hooks`、`provides_browser_providers`、
`provides_web_providers`、`provides_locales`、`hooks`、`capabilities`

**环境与配置**：`requires_env`、`optional_env`、`requires_auth`、`config_schema`、`platforms`

**事件契约约定**：`emits`、`listens`、`hermes`、`depends`（注释说是**保留**字段）

**kind**：`kind`

### 8.3 未知字段 = 前向兼容

[`plugins_manifest.py:27`](../hermes_cli/plugins_manifest.py:27) 的注释：

> 未知的 `plugin.yaml` 字段是前向兼容表面：**warn 然后继续加载**
> （v1 文件用 debug，v2+ 用 warning）。

为什么不是报错？因为一个插件可能同时支持多个 Hermes 版本。
新版加的字段，老版必须能忽略——否则插件作者被迫为每个版本发一个包。

为什么 v1 用 debug、v2+ 用 warning？因为 v1 的 `plugin.yaml` 里本来就有大量自由字段，
而 v2 是**契约化的**：声明了 `manifest_version: 2` 就意味着「我只用已知字段」，
出现未知字段说明作者写错了或拼错了。

### 8.4 `SUPPORTED_MANIFEST_VERSION = 2`

[`plugins_manifest.py:40`](../hermes_cli/plugins_manifest.py:40)。

v2 引入的核心是 `config_schema`：插件可以声明自己的配置项类型，
框架据此在设置界面渲染表单、校验写入。
[`plugins_manifest.py:42`](../hermes_cli/plugins_manifest.py:42) 的 `_CONFIG_SCHEMA_TYPES` 支持：
`str/string`、`int/integer`、`float/number`、`bool/boolean`、`list/array`、`dict/object`、`secret`。

`secret` 的注释值得注意：

> `secret` 值住在 `.env` 里（见 `hermes_cli.plugins_settings`），所以在 `config.yaml` 里的副本
> 只可能是一个走失的字符串。

这与根 `AGENTS.md` 的「`.env` is secrets only」完全一致。

---

## 9. 插件 host 隔离（`plugins.isolation: host`）

### 9.1 两种模式

[`plugin_isolation.py:28`](../hermes_cli/plugin_isolation.py:28)：

```python
ISOLATION_IN_PROCESS = "in_process"   # 默认
ISOLATION_HOST = "host"
```

模块 docstring（[`:1`](../hermes_cli/plugin_isolation.py:1)）解释了两个理由：

> `in_process`（默认）把每个插件 import 进 Hermes 进程，一如既往。
> `host` 把第三方插件代码**挡在它外面**：通用插件在**每 profile 一个** plugin-host 进程里加载
> （`hermes_cli/plugin_host`），只通过 `ctx` 与 Hermes 对话；
> 其它任何会在进程内 import 用户模块的路径（类别 provider、model-provider profile、
> dashboard 插件 API）都以具名理由**拒绝**。内置插件随 Hermes 发布，留在进程内。

第二个理由是这段里最容易被忽略的：

> 这后半部分才是**池化部署**需要的性质：一个服务多个 profile 的 Hermes 进程，
> **绝不能**和某个 profile 的插件代码共享解释器。
> 同一个边界也给单用户安装带来**崩溃隔离**（一个段错误的插件带走它的 host，而不是网关），
> 所以它是一个普通配置值，不是云专属开关。

也就是说：`host` 模式的两个收益是「多租户安全」和「崩溃隔离」，
而后者对单机用户同样有价值——这正是它不做成云专属开关的原因。

### 9.2 六条不变量

来自 [`plugins/AGENTS.md:109`](../plugins/AGENTS.md:109)。

**（1）每条用户代码 import 路径都路由到 host 或拒绝。**

列举的路径：
- 通用插件 → `plugins_loader`
- memory / context engine / cron provider → `load_instance`
- model-provider profile → `plugin_host_profiles.py`
- dashboard API → ASGI 桥

并且：

> `plugins/plugin_loader.load_plugin_module` **拒绝任何其它合成命名空间的 import**。
> **一个新的用户代码加载器必须做同样的事。**

最后一句是政策：这不是一张「已覆盖清单」，而是一条**新增代码必须遵守**的规则。
漏一条，`host` 模式就有一个洞。

**（2）不能跨界的东西是**一张表**。**

```python
# hermes_cli/plugin_isolation.py:35
HOST_UNSUPPORTED_CTX_METHODS: dict[str, str] = {
    "register_platform": "platform adapters run on the gateway's event loop with native SDK clients",
    "register_platform_handler": "the handler factory receives the platform's native SDK client",
    "register_telegram_handler": "the handler factory receives the native Telegram Application",
    "register_slack_action_handler": "the callback receives native slack_bolt ack/body objects",
    "register_dashboard_auth_provider": "dashboard auth is owned by the launch process, not a profile",
    "register_approval_transport": "approval transports hold the live approval request/response channel",
}
```

「一张表」的价值在注释里：

> 下面这些 ctx 表面表是运行时边界（`plugin_host_child` 拒绝这些方法）**和**静态审计
> （`plugin_isolation_audit`）的**单一事实来源**，所以「审计说池化安全」和「它能跑在 host 里」
> **不可能漂移**。

这是「同一份真值被两处消费」的经典应用。如果审计用一份手写清单、运行时用另一份 if-else，
半年后一定有一边漏了。

**（3）还有第二张表：可以跳过但不是错误。**

```python
# hermes_cli/plugin_isolation.py:46
HOST_SKIPPED_CTX_METHODS: dict[str, str] = {
    "register_cli_command": "`hermes <command>` subcommands are wired into the local CLI parser",
}
```

区别在哪？

- `UNSUPPORTED` = **拒绝**（插件不能加载 / 方法抛错）；
- `SKIPPED` = **跳过并警告，插件仍能加载**。

`register_cli_command` 属于后者：host 进程里没有 CLI parser，
但一个插件「想加 CLI 子命令」不代表它整体不可用——它只是这一项在 host 模式下不生效。
文档里的说法是：

> 只在进程内注册；在 host 里被**跳过**（带 warning，插件仍加载），
> 因为它们扩展的表面在服务器进程里不存在。

**（4）host 永不 spawn host。**

```python
# hermes_cli/plugin_isolation.py:86
HOST_PROCESS_ENV = "HERMES_PLUGIN_HOST_PROCESS"
```

`isolation_mode()` 的第一行（[`:91`](../hermes_cli/plugin_isolation.py:91)）：

```python
if os.environ.get(HOST_PROCESS_ENV) == "1":
    return ISOLATION_IN_PROCESS
```

如果不这样，host 进程读配置时看到 `isolation: host`，会**再 spawn 一个 host**，
而那个 host 又会 spawn…… 无限递归，机器卡死。

**（5）操作员钉住时，隔离方不能退出。**

[`plugins/AGENTS.md:124`](../plugins/AGENTS.md:124)：

> 被隔离的一方在操作员钉住时**不能选择退出**：`isolation_mode()` / `host_launcher()`
> 通过**托管 overlay**（`load_config_readonly`）读，所以 `/etc/hermes/config.yaml`
> 胜过 profile 自己的 config。**绝不要把这两个函数改成读原始用户配置。**

这是安全边界的典型形态：**被约束者不能修改约束**。
如果插件能通过改自己的 `$HERMES_HOME/config.yaml` 把 `isolation` 设回 `in_process`，
那这个隔离就只是装饰。

**（6）插件保持租户无感。**

> 没有新 API，同一个 `ctx`。每 profile 的环境来自 `served_profile_child_env`，
> 所以一个 host 只看到**它自己 profile 的**秘密。

这一条是产品决策：如果 host 模式要求插件改写代码（比如改用 `ctx.host.call(...)`），
那绝大多数插件不会支持它，隔离就成了空壳。所以协议层做了透明转发。

### 9.3 「父进程造子类」：`HOST_OBJECT_BASES`

这是整个隔离机制里最巧的部分（[`plugin_isolation.py:54`](../hermes_cli/plugin_isolation.py:54)）：

> 收对象的 ctx 方法和父进程要检查的 ABC。host 发送该对象的**方法表**，
> 父进程构建那个 ABC 的一个子类，其方法在 host 里运行。

11 个条目：

```
register_image_gen_provider        → agent.image_gen_provider:ImageGenProvider
register_video_gen_provider        → agent.video_gen_provider:VideoGenProvider
register_web_search_provider       → agent.web_search_provider:WebSearchProvider
register_browser_provider          → agent.browser_provider:BrowserProvider
register_terminal_environment_provider → agent.terminal_env_provider:TerminalEnvironmentProvider
register_secret_source             → agent.secret_sources.base:SecretSource
register_tts_provider              → agent.tts_provider:TTSProvider
register_transcription_provider    → agent.transcription_provider:TranscriptionProvider
register_context_engine            → agent.context_engine:ContextEngine
register_context_reference         → agent.context_references:ContextReferenceProvider
register_memory_provider           → agent.memory_provider:MemoryProvider
```

为什么需要这个技巧？考虑 `register_memory_provider(provider)`：
核心会做 `isinstance(provider, MemoryProvider)` 检查，然后调用 `provider.prefetch(...)`。

在 host 模式下，`provider` 对象住在**另一个进程**里。你不能传对象过去。
所以你传的是：**「它有哪些方法」的列表**。父进程据此动态造一个
`class RemoteProvider(MemoryProvider)`，每个方法是一个 RPC 调用。

这样 `isinstance` 检查通过，核心代码**一行都不用改**。

同一个注释块还说明了 hook 的限制：

> payload 携带活句柄（gateway runner、session store）的 hook，
> 在 host 里回调收到这些字段的**占位符**，所以用了它们的插件需要 `in_process`。

### 9.4 三种远程门面

```python
# hermes_cli/plugin_isolation.py:50
HOST_REMOTE_FACADES: frozenset[str] = frozenset({"state", "llm", "platform_actions", "subagent_lifecycle"})
```

这四个是**按方法调用**访问的活 ctx 门面，每次调用返回纯数据。
它们不走「造子类」的路子，而是直接方法转发——因为它们的接口本来就是
「调一个方法，拿一段 JSON」。

---

## 10. plugin-catalog：唯一的树外发现系统

### 10.1 基本形态

[`plugin-catalog/`](../plugin-catalog/) 有 **551** 个 YAML，每个条目一个文件。
[`plugins/AGENTS.md:52`](../plugins/AGENTS.md:52)：

> 树外插件的**唯一**发现系统。每条目一个 YAML，**强制 40 位 hex SHA pin**，
> 人工通过 PR 合并（`plugin-catalog/README.md` = 准入策略，
> 与 `website/docs/developer-guide/plugins/catalog-submission.md` 逐字镜像；
> `plugin-catalog-ci.yml` 会 clone 每个变更条目到它的 pin 并跑 `hermes plugins validate`）。

一个条目的实际形状（`plugin-catalog/0bull.yaml`）：

```yaml
name: 0bull
repo: https://github.com/0bull/agent-plugin
sha: 240890a71715375bc877b238491e414517e9d902
description: >-
  Control real iPhones rented from 0bull ...
maintainer: 0bull
tier: community
category: tools
version: "1.0.0"
platforms: []
capabilities:
  provides_tools: []
  ...
```

### 10.2 为什么强制 40 位 SHA

`plugin_packs.py` 里同一个规则，注释很直白（[`plugin_packs.py:1`](../hermes_cli/plugin_packs.py:1)）：

> 每个插件条目**必须** pin 一个精确的 40 字符 commit SHA；
> tag 和分支名会被拒绝，错误里会指名那个条目。

```python
_EXACT_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
```

理由：**tag 和分支是可变的**。你 review 了 `v1.2.0` 的代码并批准，
作者可以悄悄把 `v1.2.0` 移到另一段代码上。SHA 不可变——同一个 SHA 永远是同一棵树。

这是供应链安全的基本要求，也是 `sha` 出现在 CI 每个 pin 里的原因。

### 10.3 `removed.yaml`：kill list

[`plugin_catalog.py:218`](../hermes_cli/plugin_catalog.py:218)：

> `removed.yaml` 的 `removed:` 列表；缺失/格式错误 → 空。

[`plugins/AGENTS.md:55`](../plugins/AGENTS.md:55) 补充了执行细节：

> `removed.yaml` 是 kill list——**每条安装路径**（CLI、dashboard、TUI）都拒绝匹配
> （repo URL 按规范化的 `host/owner/repo` 比对，所以 `git@`/`ssh://`/`www.` 拼写都能匹配）；
> 只有 CLI 有一个响亮的 `--allow-removed`，它被记录在安装记录上，
> 并且是**唯一**能让已安装插件豁免 `update`、`enable` 和加载（`gate_manifest`）时同一检查的东西。

三个要点：

1. **路径全覆盖**。只在 CLI 拦，dashboard 装进去，等于没拦。
2. **URL 规范化比对**。攻击者会换拼写：`https://github.com/a/b`、
   `git@github.com:a/b.git`、`https://www.github.com/a/b` 是同一个仓库。
3. **豁免必须留痕**。`plugins_cmd_catalog.py:278`：

```python
if record.get("allow_removed") is True:
```

   带 `allow_removed` 的记录是「用户在安装时绕过了这个列表」——
   以后 `update` / `enable` / `load` 都据此放行，但**记录本身可审计**。

### 10.4 provenance 不能放在树里

[`plugins/AGENTS.md:60`](../plugins/AGENTS.md:60)：

> catalog 出处住在 installer 拥有的 `.install-metadata.json` 记录上
> （`catalog` 块，sha = 检出的 commit），**绝不在树里**：
> 树里的 `.hermes-catalog.json` 只是 Desktop 读的便利副本；
> **Python 从不信任它**（仓库可以伪造一个）。

这句话是整个 catalog 安全模型的枢纽。推理链：

1. 安装时，Hermes 从 catalog 拿到 `repo + sha`，检出，写 `.install-metadata.json`；
2. 如果 provenance 放在**仓库树里**，那么仓库作者可以自己在树里写一个
   `.hermes-catalog.json` 声称「我是官方 catalog 的 sha=xxx 版本」；
3. 于是 `hermes plugins update` 会认为「不需要更新」或「已经 pin 住了」；
4. 而 Desktop 读树里的副本做「Install here」按钮 —— 这是一个**只在 UI 层**的便利，
   所以它可以是副本；但**决策**必须在 installer 的记录上。

一句话：**树是别人可控的，installer 的元数据不是。**

### 10.5 loader 与 live refresh

[`plugin_catalog.py:201`](../hermes_cli/plugin_catalog.py:201)：

> catalog 目录里每个合法的 `*.yaml`（排除 `removed.yaml`），按文件名排序。

而 [`plugins/AGENTS.md:63`](../plugins/AGENTS.md:63) 说明了完整链路：

- `hermes_cli/plugin_catalog.py`：loader、从 `/docs/api/plugin-catalog.json` **实时刷新**
  （由 docs 构建发布）、树内回退；
- `hermes_cli/plugins_cmd_catalog.py`：解析、`.hermes-catalog.json` provenance sidecar、
  `search`/`info`/`validate`、`update` 时 re-pin、dashboard/TUI payload。

「实时刷新 + 树内回退」的意思是：**不需要升级 Hermes 就能拿到新条目**，
但离线时也能用内置副本。

最后一条规则：

> **绝不要加第二个名字索引**：裸名字通过 catalog 解析，否则报错。

为什么？因为两套索引必然不同步，然后用户会看到「`hermes plugins install foo`
在一台机器上能找到，在另一台上找不到」——而这种 bug 极难定位。

---

## 11. 四个周边子系统

这四个在旧版文档里完全缺失，但它们解释了「插件装完之后发生什么」。

### 11.1 packs：可分享的插件集合

[`plugin_packs.py:1`](../hermes_cli/plugin_packs.py:1)：

> 插件包 —— 声明式的、可分享的插件集合。
> 每个插件条目**必须**在 `ref` 里 pin 一个精确的 40 字符 commit SHA。

几个安全细节：

```python
# 秘密形状的键在 config seed 里被拒绝，并从导出里剥掉
_SECRET_KEY_RE = re.compile(r"(?i)(token|secret|passw(or)?d|api[_-]?key|private[_-]?key|credential|auth)")

# pack 永远不能设置的 plugins.entries.<id> 键（同意状态；allow_* 门也被拒绝）
_RESERVED_ENTRY_KEYS = frozenset({"granted_capabilities", "capabilities_consent"})

_MAX_PACK_BYTES = 1 * 1024 * 1024   # 一个 pack 是小 manifest，不是 payload
_FETCH_TIMEOUT = 15.0
```

`_RESERVED_ENTRY_KEYS` 是最重要的一条：**pack 不能替用户表达「我同意」**。
否则你导入一个别人的 pack，就把所有能力授权一次性给齐了——
同意必须是**本机用户**做出的。

秘密则通过每个插件的 `requires_env` 声明，在安装时提示输入。

### 11.2 ledger：注册所有权账本

[`plugins_ledger.py:1`](../hermes_cli/plugins_ledger.py:1)：

> 每次插件注册都用它的**逆操作**记录，这样强制重载 / 定向卸载能**逆序**回卷注册表。

为什么需要逆操作？因为注册表是散落的多个全局字典：
`registry`（工具）、`_cli_commands`、`_plugin_commands`、hook 回调列表、provider 注册表……

卸载插件不能靠「把名字删掉」，因为：
- 你可能**覆盖**了一个同名条目（要恢复旧的，而不是删除）；
- 顺序重要（后注册的先撤销，否则中间状态不一致）。

所以每次 `register_*` 都返回一个 `PluginRegistration` 句柄，
里面有 `finalize` / 逆操作，ledger 按顺序存，卸载时逆序执行。

### 11.3 cadence：更新检查的节奏

[`plugins_cadence.py:1`](../hermes_cli/plugins_cadence.py:1)：

> 插件更新检查节奏：**只读，通过 receipt 呈现**。
> 在网关启动 + 周期 tick 时运行，当 `plugins.auto_update_check_hours`
> （默认 24，0 禁用）说到期了，写一个 plugin-check receipt（`pm.receipt`，kind `plugin-check`），
> 有更新时记**一条可操作的日志**。应用更新仍然是**显式**的 ——
> `plugins.auto_apply: true`（默认 false）只对 **git 行插件**开通无人值守应用，
> 且和 `cmd_update` 一样受 scan 门控。

「只读 + 显式应用」是根 `AGENTS.md` 里「出站遥测没有 opt-in 门就不行」的同族原则：
**检查不等于替你决定**。默认不自动应用，因为插件更新可能带来新能力（新权限）。

### 11.4 activation：激活摘要

[`plugins_activation.py:31`](../hermes_cli/plugins_activation.py:31)
`plugin_activation_summary(manager, plugin_key)` 生成 §5.2 那张表里的三阶段摘要。

还有两个函数值得知道：

- `activate_plugin_now(name, in_process=True)`（[`:96`](../hermes_cli/plugins_activation.py:96)）
- `load_and_go_live(name)`（[`:130`](../hermes_cli/plugins_activation.py:130)）
- `notify_serve_backend(name, home)`（[`:186`](../hermes_cli/plugins_activation.py:186)）

最后一个暗示了一个真实约束：Desktop 的 `serve` 后端是**另一个进程**，
它有自己的插件注册表。所以「在 Desktop 里启用插件」需要**通知那个进程**，
而不只是更新本进程的状态。

---

## 12. 什么能进这个树（政策）与 left-core 迁移

### 12.1 三条禁令

来自 [`plugins/AGENTS.md:17`](../plugins/AGENTS.md:17)：

1. **不再新增树内 memory provider** —— `plugins/memory/` 已**关闭**。
   现在只有 `byterover`、`retaindb` 两个。
2. **不再新增第三方产品插件** —— 可观测性后端、供应商 SaaS 连接器、分析面板、
   付费服务绑定，作为**独立插件仓库**发布。
3. **Eclipse 参考/文档伙伴插件**住在 `hermes-example-plugins` 仓库，不在这里。

第 2 条的判断标准很实用：**如果一个插件的价值主要来自某个商业服务，它不该在树里**。
因为核心仓库的 CI 要为它跑测试、要处理它的依赖、要对它的 API 变化负责——
而那是供应商的责任。

### 12.2 left-core：从核心迁出，但不能让用户察觉

这是「能力搬到边缘」的真实执行机制。[`left_core_migration.py:5`](../hermes_cli/left_core_migration.py:5)：

> `LEFT_CORE` 命名 catalog 插件和一个只读谓词「这个 home 是否在用这个功能」。
> 契约是 memory provider 建立的那一套（`memory_provider_migration`，
> 这里的 helper 复用了它；memory 不是一行，因为它的插件名来自 `memory.provider`，
> 不是一张表）：
>
> - `hermes update` 为**每个共享该 venv 且使用该功能的** profile home 安装插件。
> - agent 启动和 gateway 启动对活跃 home **每进程重试一次**
>   （Desktop 用户通过 app 更新，永不运行 `hermes update`），遵守 `security.allow_lazy_installs`。
> - 一次失败尝试之后（catalog 未命中或不可达、安装失败），启动会跳过该行
>   `STARTUP_RETRY_SECONDS`，所以离线的机器只付一次网络往返，
>   而不是每次 `hermes chat` 都付；`hermes update` 总是重试。
> - 一个 home **最多自动获得一次**该插件（config.yaml 里的 `_left_core_installed`）：
>   之后的 `hermes plugins remove` 是用户的选择，**并且会一直有效**。

最后一条是精髓。如果「自动安装」每次都跑，用户删掉插件、重启、它又回来了——
这是最招人恨的软件行为。所以 `_left_core_installed` 是一次性标记：
装过一次之后再删，就是用户的决定。

`LEFT_CORE` 元组（[`:148`](../hermes_cli/left_core_migration.py:148)）的实际条目：

```python
LeftCoreFeature(
    plugin="homeassistant", label="Home Assistant", in_use=homeassistant_in_use,
    unchanged="HASS_TOKEN/HASS_URL, platforms.homeassistant and the ha_* tool names are unchanged",
    secret_env=("HASS_TOKEN",), private_env=("HASS_URL",),
    toolsets=("homeassistant",), off_platforms=("acp", "webhook"),
    platform="homeassistant",
    enable_env=("HASS_TOKEN",), channel_env_prefixes=("HASS_",),
)
```

`unchanged` 这个字段说明了一切：**迁移对用户必须是不可见的**。
环境变量名不变、配置节不变、工具名不变。用户升级后唯一的变化是
`~/.hermes/plugins/` 下多了一个目录。

---

## 13. 技能系统

### 13.1 两个表面

[`skills/AGENTS.md:6`](../skills/AGENTS.md:6)：

- **`skills/`** —— 内置，默认可加载，按类别组织；
- **`optional-skills/`** —— 更重 / 更小众的技能，**已发布但不激活**，
  通过 `hermes skills install official/<category>/<skill>` 安装
  （适配器 [`tools/skills_hub_official.py:34`](../tools/skills_hub_official.py:34) `OptionalSkillSource`）。

**实际统计**（`find`）：

| 目录 | 类别数 | SKILL.md 数 |
|---|---|---|
| `skills/` | 12 个内容类别 | **58** |
| `optional-skills/` | **23** | **155** |

`skills/` 的实际类别与数量：

```
apple 4 · autonomous-ai-agents 5 · creative 10 · devops 1 · email 2 · media 3
note-taking 1 · productivity 14 · research 4 · social-media 1
software-development 12 · web 1        （另有 index-cache/，是缓存不是技能）
```

`OptionalSkillSource` 的 docstring 把语义写得很清楚（[`:34`](../tools/skills_hub_official.py:34)）：

> 来自仓库 `optional-skills/` 目录的技能：官方（Nous 维护）但默认不激活
> —— 不在系统提示里，setup 时也不拷到 `~/.hermes/skills/`。
> 通过 Skills Hub 可发现，来源 `"official"`，信任级 `"builtin"`。

```python
SOURCE_ID = "official"
TRUST_LEVEL = "builtin"
OFFICIAL_REPO = "NousResearch/hermes-agent"
OPTIONAL_SKILLS_PREFIX = "optional-skills"
```

注意 `TRUST_LEVEL = "builtin"`：可选技能虽然默认不装，但**信任等级等同内置**。
因为它来自官方仓库，经过了同样的 review。

**审查技能 PR 时的判断**（[`skills/AGENTS.md:14`](../skills/AGENTS.md:14)）：

> 检查目标目录 —— 重依赖或小众技能归 `optional-skills/`。

为什么这么分？因为 `<available_skills>` 索引在**每个会话的系统提示**里。
58 个技能的索引已经不小；如果 155 个都在里面，就是纯 token 浪费。

### 13.2 SKILL.md frontmatter 全字段

```yaml
name: ...                          # 技能名（通常与目录名一致）
description: ...                   # ≤ 60 字符，一句话，句号结尾
version: ...
author: ...                        # 真人在前，工具在后
license: ...
platforms: [macos]                 # OS 门控；也可 [linux, macos]
metadata:
  hermes:
    tags: ...
    category: ...
    related_skills: ...
    config: ...                    # 技能需要的 config.yaml 设置
```

`config` 的语义（[`skills/AGENTS.md:20`](../skills/AGENTS.md:20)）：

> 技能需要的 `config.yaml` 设置 —— 存于 `skills.config.<key>`，
> **setup 时提示**，**加载时注入**。

这是一个很贴心的设计：技能不用自己写「请先设置 X」的说明，
它声明需求，框架在安装时问用户，在加载时把值交给模型。

**顶层 `tags:` / `category:` 也被接受**，由 loader 从 `metadata.hermes.*` 镜像。
为什么允许两种写法？因为早期技能用的是顶层字段，加 `metadata.hermes` 是为了
给 Hermes 专属元数据一个命名空间（将来可能有 `metadata.claude`、`metadata.other`）。

### 13.3 八条硬性标准（逐条讲「为什么」）

来源 [`skills/AGENTS.md:24`](../skills/AGENTS.md:24)，
由 `tests/skills/test_authoring_standards.py` **强制执行**。

**① `description` ≤ 60 字符、一句话、句号结尾。**

> 长描述会撑大列表，并在很多技能加载时稀释注意力。
> 陈述**能力**而非**实现**；禁营销词（"powerful"、"comprehensive"、"seamless"、"advanced"）；
> 不要重复 name。

检查方式就写在文档里：

```python
len(re.search(r'^description: (.*)$', text, re.M).group(1)) <= 60
```

为什么 60？因为 `<available_skills>` 是 `    - name: description` 一行一条，
58 条 × 超长描述 = 系统提示里一大块纯噪声。而「稀释注意力」是更实质的问题：
当 20 个技能都写 "A powerful, comprehensive tool for ..."，模型无法区分它们。

「陈述能力而非实现」的意思：
- ✅ `Fetch a web page and extract readable text.`
- ❌ `Uses httpx and BeautifulSoup to parse HTML.`

后者对模型选不选这个技能毫无帮助。

**② 散文里用反引号引用**原生 Hermes 工具**。**

允许的写法：`` `terminal` ``、`` `web_extract` ``、`` `read_file` ``、`` `patch` ``、
`` `search_files` ``、`` `vision_analyze` ``、`` `browser_navigate` ``、`` `delegate_task` ``。

> **绝不**提及 agent 已经包装过的 shell 工具：
> `grep` → `search_files`，`cat`/`head`/`tail` → `read_file`，
> `sed`/`awk` → `patch`，`find`/`ls` → `search_files target='files'`。

为什么这条是硬性的？因为技能是**给模型看的指令**。
如果你写「用 grep 搜索」，模型可能真的去 `terminal` 里跑 `grep`——
那就绕过了 `search_files` 的路径限制、忽略规则、结果截断、错误处理。
更糟的是在 Windows 上 `grep` 可能不存在。

> MCP 依赖在 `## Prerequisites` 里写清 setup。
> 第三方 CLI 和管道在**脚本文件里**没问题，但不能当作**头条表面**。

这个区分很精妙：脚本内部用 `grep` 完全合理（它是个可测试的 artifact），
但技能正文不该教模型直接手搓 shell。

**③ `platforms:` 门控要对照实际脚本 import 审计。**

POSIX 专属原语清单（文档里逐个列出）：

```
硬编码 /tmp · fcntl · termios · os.setsid · os.kill(pid, 0) · /proc
signal.SIGKILL · bash heredoc · osascript · apt · systemctl
```

> 需要平台声明。**先修跨平台**（`tempfile.gettempdir`、`pathlib.Path`、
> `psutil.pid_exists`、用 Python 过滤而不是 `grep`）；
> 只在依赖**真与平台绑定时**收窄门控。

为什么顺序是「先修再门控」？因为门控是**最后手段**：它让技能在别的平台上不可用。
如果一个 `platforms: [macos]` 只是因为作者顺手写了 `/tmp`，那 macOS 用户获得了便利，
Linux 用户被无谓地挡在门外。

**④ `author` 先署真人。**

> 外部贡献者的真名 + GitHub handle 在前，"Hermes Agent" 在后。
> 一个 authored by "Hermes Agent" 的 commit（他们用 Hermes 起草的）
> 会被替换成真人的名字 —— **credit the human, not the tool**。

这条是社区政策，但也是**质量信号**：有真名署名的技能，作者会对它的正确性负责。

**⑤ 现代章节顺序。**

```
# <Skill> Skill
2–3 句引言（它做什么、不做什么）
## When to Use
## Prerequisites
## How to Run
## Quick Reference
## Procedure
## Pitfalls
## Verification
```

> 复杂技能 ~200 行，简单 ~100 行。
> 砍掉引言废话、营销文案、以及 Prerequisites 里已经解释过的环境变量。

章节顺序为什么重要？因为**模型是跳读的**。它先看 `When to Use` 决定要不要用，
再看 `Quick Reference` 找命令，只有在真的执行时才读 `Procedure`。
如果 `Pitfalls` 藏在末尾的营销段落后面，模型会漏掉它——然后踩坑。

`## Verification` 尤其重要：它告诉模型**怎么知道自己做对了**。
没有这一节，模型会在「看起来完成了」时停下。

**⑥ `scripts/`、`references/`、`templates/`。**

> 不要让模型每次调用都内联写解析器或非平凡逻辑
> —— 发一个 helper 脚本，用**技能相对路径**引用它。

这一条直接对应成本：让模型现场写一个 JSON 解析器，
既费 token、又可能写错、又不能测试。而 `scripts/parse.py` 是：
零 token（只传路径）、可测试、可 review。

「技能相对路径」的意思是脚本里用 `Path(__file__).parent / "data"`，
而不是 `~/.hermes/skills/xxx/data`——后者在技能被安装到别处时就断了。

**⑦ 测试放 `tests/skills/test_<skill>_skill.py`。**

> 仅 stdlib + pytest + `unittest.mock`，**无实时网络**。

为什么禁实时网络？因为技能测试会在 CI 每 PR 跑。
一个依赖 GitHub API 的测试会在限流时红、在对方改 API 时红，
而作者以为是自己代码坏了。

**⑧ `.env.example` 新增内容放在清晰分隔的块里。**

> 贡献者的文件副本通常是过期的；技能自己块之外的编辑在 salvage 时**会被丢弃**。

这条是维护成本的现实妥协：`.env.example` 是一个所有人都要改的文件。
如果每人的修改混在一起，salvage（挑选合并）就变成手工考古。

### 13.4 技能如何进入上下文（两种完全不同的通道）

这是全篇最重要的机制之一，因为它直接体现缓存铁律。

**通道 A：`<available_skills>` 索引 → 系统提示**

[`agent/prompt_builder.py:1472`](../agent/prompt_builder.py:1472) 渲染：

```python
index_lines.append(f"  {category}: {cat_desc}" if cat_desc else f"  {category}:")
...
index_lines.append(f"    - {name}: {desc}" if desc else f"    - {name}")
```

然后拼进 `## Skills` 段落，并附上强指令：

> 在回复前，扫描下面的技能。如果一个技能匹配、或哪怕只是**部分**相关，
> **必须**用 `skill_view(name)` 加载它并遵循其指令。
> **宁可在不需要的上下文上多花，也不要漏掉关键步骤、陷阱或既有工作流。**

注意 `[names only]` 分支（[`:1458`](../agent/prompt_builder.py:1458)）：

```python
if category in demoted:
    index_lines.append(f"  {category} [names only]: {', '.join(...)}")
```

这是**注意力预算**的管理：当一个类别技能太多时，只列名字不列描述。

**通道 B：skill 的正文 → user 消息**

`agent/skill_commands.py` 负责把 `/skill-name 你的指令` 展开成一条 **user 消息**。
模块头的注释解释了为什么：

```python
# agent/skill_commands.py:46
_SKILL_INVOCATION_PREFIX = "[IMPORTANT: The user has invoked the "
_SINGLE_SKILL_INSTRUCTION = "The user has provided the following instruction alongside the skill invocation: "
```

关键点：**技能正文绝不进系统提示**。为什么？

1. 技能正文可能很长（~200 行）——进系统提示等于每次请求都发一遍；
2. 系统提示进缓存前缀，而技能是按需加载的——加载新技能会破坏缓存；
3. 用 user 消息注入，等于「用户刚刚说了这段话」，是对话历史的一部分，天然缓存友好。

### 13.5 `<available_skills>` 变了怎么办：delta note 通道

这是 [`agent/skills_index_delta.py`](../agent/skills_index_delta.py) 解决的问题，
它的 docstring 值得完整读：

> **会话中途变化的技能，不重建提示就能到达模型。**
>
> `<available_skills>` 索引住在系统提示里，而一段对话会在它整个生命周期里
> **保留那些字节**，这样 provider 的前缀缓存保持热（#104414）。
> 一个在提示构建**之后**安装、创建或删除的技能
> （hub install、`skill_manage`、curator、插件上线、另一个进程做的修改）
> 因此**永远到不了**模型用来路由的索引，直到压缩重建提示。
> 每个 turn 都比较「提示里携带的索引」与「这个会话现在会构建的索引」，
> 并把**差量**通过每 turn 的 user 消息 note 通道送达，位于缓存前缀之后
> （移植自 cloudflare/cloudflare-os#267）。
>
> 每条 note 陈述**相对于提示的完整差量**，所以「提示 + 最新的 note」
> 就是「模型被告知过什么」的完整记录。一个新的 agent（gateway 每 turn 构建一个）
> 从 transcript 里读回这条记录一次；长生命周期的 agent（CLI、TUI、Desktop）
> 把它保存在自己身上。**只有当差量变化时才发一条 note。**

这段话几乎是一个完整的分布式缓存一致性教程。拆解：

1. **问题**：系统提示是「快照」，但技能目录是「活的」。
2. **约束**：不能重建提示（破坏缓存）。
3. **解法**：在提示之后的追加区（user 消息）发送差量。
4. **正确性**：每条 note 都是**完整差量**（不是增量），所以「提示 + 最新 note」自洽。
   这样即使中间丢了消息，最新 note 也能纠正回来。
5. **效率**：只在差量变化时发。

具体的 note 文本（`_NOTE_PREFIX`）：

```
[System: The skills available in this conversation changed after its system prompt was built.
Now available (load with skill_view(name) when relevant, like the skills listed in the system prompt):
    - name: description
No longer available:
    - name
 The skills listed in the system prompt are accurate again; earlier skill-change notes are superseded.
]
```

`_NAMES_ONLY_RE` 处理 `[names only]` 行，`_row_name()` 处理 `plugin:skill` 形式的限定名
（注释：插件技能是限定的 `plugin:skill`，所以单个 `":"` 是名字的一部分）。

### 13.6 技能 slash 命令的缓存键

[`agent/skill_commands.py:21`](../agent/skill_commands.py:21) 有
`_skill_commands_by_key`，docstring（[`:1`](../agent/skill_commands.py:1)）提到
**多槽位缓存**（#104849）和 **Unicode 技能名**（#12351）。

多槽位缓存解决的是：同一个进程里有多个 `(home, platform, project)` 组合
（多 profile + 多平台），缓存的 key 必须包含这三者，否则 A profile 的技能列表会串到 B。

### 13.7 为什么技能加载工具禁止 `offset`/`limit`

[`skills/AGENTS.md:58`](../skills/AGENTS.md:58)：

> 技能加载工具上**没有** `offset`/`limit` 分页 —— agent 必须**完整**读一个技能。

这条在根 `AGENTS.md` 的「即使做得好也会被拒」清单里也出现了。理由：

1. 技能的价值在**完整性**。分页读一个「Procedure」技能，模型可能只看到前半段，
   漏掉 `## Pitfalls` 和 `## Verification`——然后自信地做错。
2. 分页会诱导模型**循环读**，每次都是一个工具调用 → 更多 token、更多延迟。
3. 技能本来就是为「一次性塞进上下文」设计的（~100–200 行）。

对比：`read_file` **应该**有分页，因为日志文件可能有几 MB。
区别在于**这个工具是 instructional 的还是 data 的**。

### 13.8 技能的其它守卫

`tools/` 下有 28 个 `skill*` 文件，其中几个值得点名：

| 文件 | 职责 |
|---|---|
| [`tools/skill_usage.py`](../tools/skill_usage.py:1) | 用量遥测 + provenance，`.usage.json` |
| [`tools/skill_manager_tool.py`](../tools/skill_manager_tool.py) | `skill_manage` 工具实现 |
| [`tools/skill_manager_guards.py`](../tools/skill_manager_guards.py) | 删除守卫、路径重定向检查、pinned 检查 |
| [`tools/skill_ledger.py`](../tools/skill_ledger.py) | 每次变更的审计账本 |
| [`tools/skills_guard.py`](../tools/skills_guard.py) | 技能内容安全检查 |
| [`tools/skills_ast_audit.py`](../tools/skills_ast_audit.py) | 脚本 AST 审计 |
| [`tools/skill_provenance.py`](../tools/skill_provenance.py) | `created_by` 来源判定 |
| [`tools/skills_hub*.py`](../tools/skills_hub.py) | 多源技能市场（official / github / clawhub / skillssh） |

`skill_manager_guards.py:143` 的 `_pinned_guard` docstring 说明了 pin 的精确语义：

> 如果 *name* 被 pin 或是 essential，返回拒绝消息，否则 None。
> **Pin 只守卫删除；patch/编辑仍然允许。**
> `ESSENTIAL_SKILLS` 是**永久 pinned**（系统提示依赖它们）。

而 `_validate_delete_target`（[`:105`](../tools/skill_manager_guards.py:105)）和
`_is_path_redirect`（[`:97`](../tools/skill_manager_guards.py:97)）防的是另一类攻击：
技能目录里放一个符号链接，删除操作就被重定向到 `~/.ssh`。

---

## 14. Curator：技能生命周期管理

### 14.1 定位

`agent/curator.py`（1212 行）+ `agent/curator_backup.py`（492 行）+ `hermes_cli/curator.py`。

[`skills/AGENTS.md:62`](../skills/AGENTS.md:62)：

> 跟踪 **agent 创建的技能**的用量并自动归档陈旧的那些；
> 归档到 `~/.hermes/skills/.archive/` 且**可恢复**。
> 核心 `agent/curator.py`（审查循环、自动转移、LLM 审查提示）+
> `agent/curator_backup.py`（运行前 tar.gz 快照）；
> CLI `hermes_cli/curator.py`；
> 遥测 `tools/skill_usage.py` 拥有 `~/.hermes/skills/.usage.json`；
> 配置 `curator:` —— `enabled, interval_hours, min_idle_hours, stale_after_days,
> archive_after_days, backup.*`；
> 它的 LLM 调用走 `auxiliary`。

### 14.2 `.usage.json` 字段

`tools/skill_usage.py:1`：

> 技能用量遥测 + provenance：Curator 的 sidecar `~/.hermes/skills/.usage.json`，
> 按技能名 keyed。

字段（`:349` 的默认记录）：

```python
{"created_by": None, "use_count": 0, "view_count": 0,
 "last_used_at": None, "last_viewed_at": None,
 "created_at": ..., "state": STATE_ACTIVE, "pinned": False, "archived_at": None}
```

加上 patch 相关：`patch_count`、`last_patched_at`、`patch_generation`。

状态三值（[`:35`](../tools/skill_usage.py:35)）：

```python
STATE_ACTIVE, STATE_STALE, STATE_ARCHIVED = "active", "stale", "archived"
```

`_VALID_STATES` 是这三者的集合——写入时校验，损坏的记录被丢弃而不是让整个文件失效
（`:370`：「非 dict 值被丢弃；缺失/损坏 → `{}`」）。

并发安全：`_usage_lock`（`:96`）序列化跨进程的读-改-写循环。
因为 CLI、gateway、curator 后台可能同时更新同一个文件。

### 14.3 `hermes curator` 的 13 个子命令

从 `_SUBCOMMANDS` 表（[`hermes_cli/curator.py:660`](../hermes_cli/curator.py:660)）读出的完整清单：

| 子命令 | 作用 |
|---|---|
| `status` | 当前状态（含 `archived=` 计数） |
| `run` | 跑一次（`--consolidate` 可开 LLM 合并 pass） |
| `pause` / `resume` | 暂停/恢复 |
| `pin` / `unpin` | 钉住/取消钉住 |
| `list-unmanaged` | 列出无 provenance 标记的技能 |
| `adopt` | 把无主技能交给 curator（`--all-unmanaged`、`--dry-run`、`--yes`） |
| `restore` | 恢复已归档技能 |
| `list-archived` | 列出已归档 |
| `archive` | 手动归档（移到 `.archive/`，**从提示中排除**） |
| `prune` | 批量归档闲置 ≥ N 天的 curator 管理技能（默认 30） |
| `backup` | 手动 tar.gz 快照（curator 每次真跑前也自动做） |
| `rollback` | 从快照恢复，或按 ledger 条目回滚**单次变更** |
| `ledger` | 列出每次变更的审计账本（所有角色：curator/agent/user） |
| `purge` | 删除超过 `archive_ttl_days` 的已归档技能（**显式，永不自作主张**） |

`adopt` 的 help 文本值得注意：

> 把无主技能交给 curator（provenance 是**用户的声明**）

即：curator 只碰 `created_by: "agent"` 的技能，但用户可以**声明**某个技能归 curator 管。

### 14.4 四条不变量

[`skills/AGENTS.md:73`](../skills/AGENTS.md:73)：

**（1）只碰 `created_by: "agent"` 的技能。**

> 内置 + hub 安装的**不可碰**。

为什么？因为用户明确安装了它们。curator 把它们归档，等于用户装了个东西然后它自己消失了。

**（2）`prune_builtins` 是一条窄缝。**

> `prune_builtins` 让**确定性**的闲置遍历归档内置技能，
> 但**绝不**把它们加进 LLM pass 的候选列表。

这个区分很精细：
- 确定性遍历 = 规则（N 天没用就归档），可预测、可恢复；
- LLM pass = 模型判断（「这两个技能重复了，合并吧」），不可预测。
- 让模型去改一个**用户装的内置技能**是不可接受的；但让规则把它标成 stale 是可接受的
  （因为它是 inactive，可以 restore）。

**（3）`skills.disabled` 的名字也排除。**

> 它们被 `skill_view` 拒绝 —— fork 只能被提供它**能读能写**的技能。

即：LLM pass 的候选列表 = `created_by: agent` ∩ ¬pinned ∩ ¬disabled ∩ ¬builtin。
如果给模型一个它读不了的技能，模型会报告「我无法访问这个文件」，纯浪费。

**（4）永不删除，归档是上限。**

> **永不删除 —— 归档是上限**；被 pin 的技能豁免一切自动转移与 LLM 审查；
> `skill_manage(action="delete")` 拒绝被 pin 的技能，但
> `patch`/`edit`/`write_file`/`remove_file` 仍工作，这样 agent 能继续改进它们。

这里最后一句话是精髓：**pin 保护的是「别让它消失」，不是「别动它」**。
如果 pin 连 patch 都禁掉，那 agent 发现 pinned 技能里有个错误命令时就无法修复——
只能告诉用户「你自己去改」。

`purge` 是唯一的删除路径，且：
- 只在 **显式** 调用时执行（无自动）；
- 需要确认；
- 记录进 ledger；
- 时间戳取 `archived_at` 与目录 mtime 的**较新者**
  （[`curator.py:442`](../hermes_cli/curator.py:442) 的注释：
  「在 `archived_at` 之前存档的，或者手动取消归档再重新归档后 `archived_at` 存活的；
  **绝不早于**两者任一说的时间清除」）。

### 14.5 curator 的模型路由

`agent/curator.py:1038` 的 docstring：

> Curator 是一个普通的**辅助任务槽**（`auxiliary.curator.*`），
> 所以它走规范的 aux-model 管道。优先级：
> 1. `auxiliary.curator.{provider,model}` 当两者都非 auto 时
> 2. 遗留的 `curator.auxiliary.{provider,model}`（已弃用）
> 3. ...

而 `agent/curator.py:147`：

> LLM 合并 pass —— **默认关闭**（只 prune，不起 aux-model fork）；
> `hermes curator run --consolidate` 每次调用可覆盖。

默认关闭是对的：一个后台 LLM 会花用户的钱。所以默认只跑**确定性规则**，
想要「合并重复技能」这种智能操作，用户显式开。

---

## 15. MCP（Model Context Protocol）

### 15.1 代码形状：18 个文件

[`tools/mcp_tool.py`](../tools/mcp_tool.py:1) 是门面（729 行），兄弟模块按主题拆分：

| 文件 | 行数 | 职责 |
|---|---|---|
| [`mcp_tool_discovery.py`](../tools/mcp_tool_discovery.py) | 850 | 读配置、`register_mcp_servers`、`discover_mcp_tools`、与磁盘配置对账 |
| [`mcp_tool_handlers.py`](../tools/mcp_tool_handlers.py) | 740 | 工具调用处理、信任门、熔断器 |
| [`mcp_tool.py`](../tools/mcp_tool.py) | 729 | 门面：SDK loader、`MCPServerTask`、共享状态、`_mcp_loop` |
| [`mcp_tool_transport.py`](../tools/mcp_tool_transport.py) | 695 | stdio / Streamable HTTP / SSE 传输 |
| [`mcp_tool_registration.py`](../tools/mcp_tool_registration.py) | 608 | 把 server 工具注册进 Hermes 注册表、信任记录 |
| [`mcp_tool_server_run.py`](../tools/mcp_tool_server_run.py) | 569 | server 启动/停止 |
| [`mcp_tool_config.py`](../tools/mcp_tool_config.py) | 566 | 配置解析、`mcp_servers` 读取 |
| [`mcp_tool_errors.py`](../tools/mcp_tool_errors.py) | 536 | 错误归一化 |
| [`mcp_tool_lifecycle.py`](../tools/mcp_tool_lifecycle.py) | 428 | 生命周期 |
| [`mcp_tool_content.py`](../tools/mcp_tool_content.py) | 332 | 内容块转换 |
| [`mcp_tool_sampling.py`](../tools/mcp_tool_sampling.py) | 323 | Sampling + Elicitation handler |
| [`mcp_tool_agent.py`](../tools/mcp_tool_agent.py) | 323 | agent 侧接口 |
| [`mcp_tool_loop.py`](../tools/mcp_tool_loop.py) | 308 | 事件循环管理 |
| [`mcp_tool_health.py`](../tools/mcp_tool_health.py) | 295 | 健康检查 |
| [`mcp_tool_schema.py`](../tools/mcp_tool_schema.py) | 265 | schema 转换 |
| [`mcp_tool_common.py`](../tools/mcp_tool_common.py) | 163 | 常量、`mcp_field` |
| [`mcp_tool_node_abi.py`](../tools/mcp_tool_node_abi.py) | 88 | Node 侧 ABI |
| [`mcp_tool_scope.py`](../tools/mcp_tool_scope.py) | 63 | 作用域 key |

### 15.2 核心模型：一个后台事件循环 + 每 server 一个 Task

`mcp_tool.py` 的 docstring 是理解全局的关键：

> MCP 客户端：连接 `~/.hermes/config.yaml` 里配置的 `mcp_servers`
> （stdio、Streamable HTTP 或 SSE），发现它们的工具并注册进 hermes 工具注册表。
> `mcp` 包是**可选的**（没装就 no-op）。
>
> **一个后台事件循环（`_mcp_loop`）在守护线程里把每个 server 跑成一个长生命周期 Task
> （`MCPServerTask`）**，这样传输层的 anyio cancel scope 在**同一个 Task** 里进入和退出；
> 每次 `_servers`/loop 变更都持 `_lock`。
> 这个模块保留 SDK loader、`MCPServerTask` 和所有共享状态；
> `mcp_tool_*` 兄弟们通过 `tools.mcp_tool`（`_core`）在调用时读回那些状态，
> 并且由各自的调用方直接 import。

两个"为什么"值得展开：

**（1）为什么每 server 一个 Task？**

因为 `anyio` 的 cancel scope 要求「进入和退出在同一个 Task」。
如果你用一个线程池，A 线程进入 scope、B 线程退出，anyio 会抛
`Attempted to exit cancel scope in a different task than it was entered in`。
而 MCP 的 stdio 传输依赖 anyio（`mcp` SDK 是 anyio-based）。

**（2）为什么状态在门面、逻辑在兄弟？**

门面的 `_servers`、`_lock`、`_mcp_loop` 是**共享可变状态**。
兄弟模块在**函数内部**`from tools import mcp_tool as _core` 再读 `_core._servers`。
这是根 `AGENTS.md` 里「siblings late-import the facade」的模式：
避免模块级循环导入，同时保证所有消费者看到**同一份**状态
（如果每个兄弟自己持有副本，就会出现「handlers 看到的 server 列表和 discovery 看到的不一样」）。

### 15.3 OSV 恶意包预检

[`mcp_tool.py:35`](../tools/mcp_tool.py:35)：

```python
_OSV_MALWARE_CHECK_TIMEOUT_S = 12.0
```

> stdio spawn 之前对 fail-open 的 OSV 恶意包预检的**墙钟**上限；
> 刚好**高于** `osv_check._TIMEOUT`（10s），所以它只在卡住的 SSL 握手打败那个超时时才生效。

预检函数 `_preflight_stdio_command`（[`:38`](../tools/mcp_tool.py:38)）：

> OSV 恶意包预检（在事件循环外，墙钟有界，超时则 fail-open），
> **然后**才做 cached-npx 替换。
> 预检必须看到**真实的** command/args：任何把 argv 改写成 wrapper 或已解析二进制的操作
> 都必须**在它之后**发生，否则检查会静默地检查 wrapper，变成 no-op
> （`_infer_ecosystem` 依赖命令 basename 是 npx/uvx/pipx）。

这段注释记录了一个非常隐蔽的 bug 类：**安全检查被优化绕过**。
如果你为了省一次网络请求，先把 `npx some-pkg` 换成 `/home/u/.hermes/npx-cache/abc/some-pkg`，
那 OSV 检查看到的是本地路径，永远查不到恶意包。

`fail-open` 也有讲究：预检失败（网络挂了）不应该让用户无法使用 MCP。
安全性的边界是「已知恶意包」而不是「无法验证就拒绝」——
后者会让离线机器完全不能用 MCP。

### 15.4 三种传输与 `lazy`

配置形状（`mcp_servers.<name>`）：

```yaml
mcp_servers:
  myserver:
    command: npx            # stdio
    args: ["-y", "some-mcp"]
    lazy: true              # 首次工具使用时才连接
  remote:
    url: https://mcp.example.com/mcp   # Streamable HTTP
    auth: oauth
    trust: untrusted
```

`lazy` 的语义（[`mcp_tool_discovery.py:210`](../tools/mcp_tool_discovery.py:210)）：

> 当 `mcp_servers.<name>.lazy` 把连接推迟到首次工具使用时为 True（**默认关闭**）。
> 按 server 由配置门控，遵循同样的**每 server** 模式。

为什么默认关闭？因为 eager 连接意味着「启动时就知道这个 server 有哪些工具」，
工具列表是准确的。lazy 省了启动时间，但代价是**第一次调用要等连接**，
而且工具列表可能是空的（如果工具发现也延迟）。

### 15.5 信任：**每 profile 的记录**

这是 [`tools/AGENTS.md:109`](../tools/AGENTS.md:109) 的三条规则：

- `mcp_tool_registration.py::_record_scope_trust` 以 **home 为 key** 记录信任
- **次要 profile 绝不采纳启动 profile 对同名 server 的信任**
- `mcp_tool_handlers.py::_trust_gate_check` 查询**调用会话的 profile**

具体的 trust 语义（[`mcp_tool.py:511`](../tools/mcp_tool.py:511)）：

```python
_TRUST_FULL, _TRUST_UNTRUSTED = "full", "untrusted"
```

> 信任分级门控（`trust: full | untrusted`）：在 untrusted server 上，
> 每个**写能力**工具都需要审批。
> ……缺失 trust = full；**无法识别 = untrusted**（一个已经警告过的 server，**永不扩大访问**）。

「无法识别 = untrusted」是 fail-closed 的正确形态：
用户写了个拼写错误 `trust: untrst`，不应该被当成 full。

`_trust_gate_check`（[`mcp_tool_handlers.py:60`](../tools/mcp_tool_handlers.py:60)）：

```python
trust = _core._server_trust_levels.get(_server_key(server_name), _core._TRUST_FULL)
if trust != _core._TRUST_UNTRUSTED or _tool_is_read_only(server_name, tool_name):
    return None
```

- 不是 untrusted → 放行；
- 是 untrusted 但工具声明了 `readOnlyHint=true` → 放行（只读没有破坏性）；
- 否则 → 审批。

审批失败的处理：

```python
except Exception as exc:
    logger.error(...)
    return tool_error(f"... was blocked: the approval system was unavailable (fail-closed).")
```

**fail-closed**：审批系统本身出错时，**拒绝**执行。
这是安全门的标准做法——「我不知道该不该批准」不等于「批准」。

拒绝后的提示还有一句精心设计的话：

> The command was NOT run. **Do not retry without explicit user direction.**

为什么加这句？因为模型在工具报错后常会重试。如果不明确禁止，
它会换个参数再试一次，而每次都会弹审批——变成骚扰用户。

### 15.6 熔断器

`_check_circuit_breaker`（[`mcp_tool_handlers.py:88`](../tools/mcp_tool_handlers.py:88)）：

> 打开状态时返回错误，否则 None 表示调用可继续。
> 冷却之后熔断器**半开**：下一次调用探测；成功则重置，失败则重新计数并重设冷却。

这是标准的电路熔断器三态（closed → open → half-open）。
为什么 MCP 特别需要它？因为 MCP server 是**外部进程**：
一个崩溃但没退出的 server 会让每次工具调用都等 30s 超时。
没有熔断器，模型会在一个死 server 上烧掉几十次超时。

### 15.7 工具名与连接 key 的作用域

`_server_key(name, scope=None, current=True)`（[`mcp_tool_scope.py:26`](../tools/mcp_tool_scope.py:26)）：

> *name* 由 *scope* 拥有时的连接 key（*current* 时用当前注册表作用域）。
> `None` scope（无 multiplexer）保持裸名字。

```python
return name if scope is None else (scope, name)
```

即 key 在单 profile 下是 `"myserver"`，多 profile 下是 `("profile_a", "myserver")`。

这解释了「为什么信任必须按 profile 记」：如果 key 只是名字，
那么 profile A 的用户批准了 `untrusted` 的 `filesystem` server，
profile B 的同名 server 会自动继承这个批准——**B 的用户从没同意过**。

`_key_name(key)` 反向取出名字部分，供需要展示的地方用。

### 15.8 与磁盘配置对账

`reconcile_mcp_servers_with_config()`（[`mcp_tool_discovery.py:649`](../tools/mcp_tool_discovery.py:649)）：

> 让**活的** server 集合与**磁盘上现在**的 `mcp_servers` 保持同步：拆掉……

这是「配置即真相」的实现。用户改了 `config.yaml` 后，不需要重启 Hermes：
- 新增的 server 被启动；
- 删除的 server 被拆掉（释放子进程）；
- 修改的 server 被重建。

`register_mcp_servers` 前面还有一个过滤器：

```python
servers = _config._filter_suspicious_mcp_servers(servers)
```

——**可疑 server 在注册前就被过滤**。这是一种静态防御：
一个配置里写着 `command: curl` + `args: ["evil.sh"]` 的 server，
不该被无脑 spawn。

### 15.9 `optional-mcps/`：65 条 catalog

[`optional-mcps/`](../optional-mcps/) 有 65 个目录 + 一个 `manifest.yaml`。
每个目录里是一个 `manifest.yaml`，形状（以 `airtable` 为例）：

```yaml
# Nous-approved MCP catalog entry.
# Presence in this directory = approval. Merged via PR review.
manifest_version: 1

name: airtable
connector_slug: airtable
description: >-
  Bases, tables, and records from your Airtable workspace.
source: https://support.airtable.com/articles/9897799762-using-the-airtable-mcp-server

transport:
  type: http
  url: https://mcp.airtable.com/mcp

auth:
  type: oauth

suggest:                    # Composer 建议触发（Desktop brand pills）
  keywords: [airtable]
  hosts: [airtable.com]

post_install: |
  On first connection Hermes opens a browser to authorize with
  Airtable (or run `hermes mcp login airtable`). ...
```

三个设计点：

1. **「Presence in this directory = approval」** —— 目录本身就是审批记录，
   合并进这个目录 = 经过 PR review。
2. **URL-only 的远程 server 不 spawn 本地进程**（注释明确写了）。
   这让「装一个 MCP」不会在你机器上跑陌生二进制。
3. **OAuth 2.1 + Dynamic Client Registration** 由 Hermes 的
   `mcp_oauth_manager` 处理（发现、PKCE、换 token、刷新）。
   所以 65 个条目里很多是「零配置登录」。

`post_install` 是给用户看的**安装后指引**——注意它教的是
`hermes mcp login airtable` 而不是「请去某网站拿 token」。

### 15.10 反向：`hermes mcp serve`

[`mcp_serve.py:1`](../mcp_serve.py:1)：

> **Hermes MCP Server —— 把消息会话暴露为 MCP 工具**（`hermes mcp serve`）。
>
> 一个 stdio MCP server，让**任何 MCP 客户端**（Claude Code、Cursor、Codex……）
> 列出会话、读历史、发消息、轮询实时事件、管理审批。
> 匹配 OpenClaw 的 9 工具 channel bridge 表面，外加 Hermes 特有的 `channels_list`。
> 客户端配置：
> `{"mcpServers": {"hermes": {"command": "hermes", "args": ["mcp", "serve"]}}}`

所以 Hermes 在 MCP 生态里是**双向的**：

```
Hermes 作为 client  →  连别人的 MCP server（拿到工具）
Hermes 作为 server  →  被别人连（暴露消息会话）
```

为什么需要反向？因为用户可能同时用 Claude Code 和 Hermes。
如果 Hermes 在 Telegram 上收到了消息，你想从 Claude Code 里看到并回复，
就需要 Hermes 暴露一个 MCP server。

一个 API 演化细节也写在注释里：

```python
# mcp 2.0 移除了 `mcp.server.fastmcp`；`mcp.server.MCPServer` 保留同样的
# `@server.tool()` / `run_stdio_async()` 表面（docstring → description，signature → input schema）。
```

这是 MCP SDK 自己的 breaking change，Hermes 通过 try/except 兼容两个版本。

---

## 16. 「我想改 X，该动哪里」速查表

这张表是本篇的实用输出。

| 我的需求 | 该动哪里 | 不该动哪里 |
|---|---|---|
| 加一个新工具给模型用 | 插件 `ctx.register_tool` | `model_tools.py`、`toolsets.py` |
| 加一个 hook | **先证明有真实消费者**，再在 `VALID_HOOKS` 加并接线 | 直接改 `run_agent.py` 加 if |
| 加一个 CLI 子命令 | 插件 `ctx.register_cli_command` | `hermes_cli/main.py` |
| 加一个 slash 命令 | 插件 `ctx.register_command` | `cli.py` 的 `_SLASH_DISPATCH` |
| 换掉上下文压缩器 | 插件 `ctx.register_context_engine`（单例） | `agent/compression*` |
| 加一个模型 provider | `plugins/model-providers/<name>/`，`register_provider` | `providers/__init__.py` 加分支 |
| 加一个记忆后端 | 插件 `ctx.register_memory_provider`（**不许进 `plugins/memory/`**） | `agent/memory_manager.py` |
| 加一个平台 | `plugins/platforms/<name>/adapter.py` | `gateway/run.py` |
| 教模型一套流程 | 写 SKILL.md（`skills/` 或 `optional-skills/`） | 任何 Python |
| 接一个外部 API | 先看 `optional-mcps/` 有没有；没有就做 MCP server 或插件 | 核心 |
| 改某个插件的内部 import 路径 | 修插件（内部路径**不是 API**） | 加 re-export shim |

### 16.1 「内部 import 路径不是 API」

[`plugins/AGENTS.md:149`](../plugins/AGENTS.md:149)：

> PR #102117 把内部实现搬进 `<stem>_<topic>` 兄弟模块。
> 那个让外部插件保住旧 import 路径的**临时兼容层**在 2026-09-14 窗口之后被移除；
> 旧路径现在抛 `ImportError`，在 `hermes plugins list` 里显示为插件的 **load error**。
> 插件建立在 `ctx` 和文档化的 ABC 上。
> **绝不为内部移动加 re-export shim。**
> `hermes_cli/plugin_compat.py` 只作为三个惰性 stub 存活，
> 那是在移除前就已经在跑的 updater 会 import 的。

这条政策很硬，但理由充分：

1. 每个 shim 都是一个**永久的 API 承诺**。shim 一多，重构就死。
2. 插件的正确依赖面是 `ctx` + ABC，不是内部模块。
3. `ImportError` 是**显式**失败，而不是「导入了但行为变了」的隐式失败。

**最后一句话是操作建议**：如果用户报告插件加载失败，
先看 `hermes plugins list` 里的 load error 是不是一堆 `ImportError`——
那是插件需要更新（改 import），不是 Hermes 有 bug。

### 16.2 兼容契约的七条

[`plugins/AGENTS.md:130`](../plugins/AGENTS.md:130)。核心论点是第一句：

> 兼容性是一份**行为契约**，不是一个单体的 `PLUGIN_API_VERSION`、
> 不是 manifest 级别的原生 `api:` 匹配、也不是无关载荷上的版本字面量。

逐条：

1. **Hook payload 以关键字字段追加**；回调做**签名检查**，所以老的窄签名只收到它声明的字段，
   `**kwargs` 回调拿到完整 payload。
2. **绝不删除或重命名 `PluginContext` 方法**；新参数可选、有默认值、尽量 keyword-only。
3. **未知的原生 manifest 字段被忽略**。
4. **新的 provider 方法有默认实现**；可选回调 kwargs 做签名检查，不无条件转发。
5. **只有带 wire 或持久化契约的能力才有本地 schema 版本**，
   且旧 state/config/session replay 被保留或迁移。
6. **弃用**：每进程一次 warning、文档化的替代 + 迁移说明、**至少 2 个后续 minor release** 才移除。
7. **兼容测试通过真实发现路径加载冻结的插件**并断言结果——
   绝不断言精确的 registry/catalog 数量、绝不做源码阅读测试、绝不「某个全局版本字面量变了」。

第 1 条的技术细节值得展开：`inspect.signature` 检查回调参数，
只传它**声明了**的字段。这样：
- 2024 年写的插件 `def on_session_start(session_id):` 仍然工作；
- 2026 年新增的 `profile_name` 字段不会让它崩（`TypeError: unexpected keyword`）。

如果无条件转发所有 kwargs，那**每加一个 payload 字段都是 breaking change**。

第 7 条是测试哲学：断言「插件加载后工具被注册了」而不是「注册表里有 47 个工具」。
后者每次核心加工具就红。

---

## 17. 测试约定

### 17.1 三个必须

[`plugins/AGENTS.md:157`](../plugins/AGENTS.md:157) 与
[`skills/AGENTS.md`](../skills/AGENTS.md:53)：

1. **测试放 `tests/plugins/`、`tests/skills/`。**
2. **用真实发现加载，配临时 `HERMES_HOME`。**
3. **断言行为**（工具被注册、hook 以期望 kwargs 触发），**不是数量**。

第 2 条为什么必须？因为插件发现读 `~/.hermes/plugins/`。
如果测试用真的 home，那么**开发者本机装的插件会影响测试结果**——
CI 上绿、本地红，或者反过来。而 `tests never write to ~/.hermes/` 是根 `AGENTS.md` 的硬规则。

第 3 条的反例（**禁止的形状**）：

```python
# ❌ 数量断言：核心每加一个工具就红
assert len(registry.list_tools()) == 47

# ❌ 源码阅读测试：重构就红，且不证明行为
src = Path("hermes_cli/plugins.py").read_text()
assert "def invoke_hook" in src

# ✅ 行为断言
assert registry.get_entry("my_tool", scope=scope) is not None
assert calls == [{"tool_name": "terminal", "args": {"command": "ls"}}]
```

### 17.2 兼容测试的正确形状

> 兼容测试**通过真实发现路径加载冻结的插件**并断言结果。

「冻结的插件」= 一个故意写成老版本风格的插件 fixture，
放在 `tests/` 里永不变。这样每次核心重构，它都会告诉你「你破坏了兼容性」。

如果只是断言「`VALID_HOOKS` 有 44 个成员」，那加一个 hook 就红，
而真正的破坏（比如某个 hook 不再被触发）反而测不出来。

### 17.3 技能的测试

[`skills/AGENTS.md:53`](../skills/AGENTS.md:53)：

> 测试放 `tests/skills/test_<skill>_skill.py`，仅 stdlib + pytest + `unittest.mock`，**无实时网络**。
> 运行 `scripts/run_tests.sh tests/skills/test_<skill>_skill.py -q`。

（注意：永远是 `scripts/run_tests.sh`，不是裸 `pytest`——见 [`tests/AGENTS.md`](../tests/AGENTS.md)。）

而 `tests/skills/test_authoring_standards.py` 是**元测试**：
它扫描所有 SKILL.md，检查 §13.3 的 8 条标准。
所以你写技能时不用记这些规则——CI 会告诉你。

---

## 18. 自检题

> 用法：先自己回答，再回去对照。答不上的题，说明那一节需要重读。

### A 组：路径选择

1. 一个需求：「让 Hermes 会用我们公司的 code review 清单」。走哪条路？为什么？
2. 一个需求：「让 Hermes 能查我们的内部 Prometheus」。走哪条路？两种方案各自代价是什么？
3. 一个需求：「自动给每个新会话起标题」。这该是插件还是核心？
4. Footprint Ladder 的六层是什么？为什么「新核心工具」排最后？
5. 什么情况下一个 hook 会被拒绝？举一个已发生的例子。

### B 组：插件铁律

6. 「插件绝不碰核心」的三条技术理由分别是什么？
7. 插件需要用户配置 API key 时，为什么不能自己加 `hermes myplugin-setup`？
8. `post_setup()` 是谁调用的？为什么不放在插件自己的 CLI 里？
9. 如果插件真的缺少一个能力，正确做法是什么？错误做法是什么？

### C 组：发现顺序

10. General 插件是 later-wins 还是 earlier-wins？为什么？
11. 「冒名者检查」防的是什么？它检查 manifest 的哪个字段与哪个字段的一致性？
12. Memory provider 为什么是 bundled-first？与 general 相反的动机是什么？
13. `discover_memory_providers()` 为什么不 import 插件？
14. Model provider 为什么**不能**被 `PluginManager` import？「双重实例化」的具体后果是什么？
15. `_discover_providers()` 的三步顺序是什么？为什么 `$HERMES_HOME` 的插件在**查找时**才加载？

### D 组：发现时机

16. `discover_plugins()` 通常由什么触发？（提示：不是显式调用）
17. 哪三类代码可能因为「没 import `model_tools.py`」而看到空注册表？`invoke_hook` 怎么修的？
18. `discover_plugins(force=True)` 被哪些路径调用？
19. 插件 mid-run 加载后，handlers / tools / `deferred.mcp_servers` 各自的生效时机？
20. 为什么工具不能「立即生效」？
21. `suppress_plugin_discovery()` 为什么用 contextvar 而不是环境变量？#123386 的场景是什么？
22. `start_background_plugin_discovery()` 如何保证没人看到半加载的注册表？

### E 组：hooks

23. `VALID_HOOKS` 有多少个？它除了「合法 hook 名」还兼作什么？
24. `pre_tool_call` 的 `block` / `approve` 优先级是什么？为什么**不能**按注册顺序？（#87420）
25. `transform_api_error_classification` 为什么在 `SHELL_UNSUPPORTED_HOOKS` 里？
26. `pre_auxiliary_call` 与 `pre_api_request` 为什么要分开？（#79733）
27. 流式观察者为什么「在 token 路径之外」且「不能变换流」？
28. `pre_gateway_dispatch` 在认证之前触发，这意味着它的 payload 能当可信输入吗？
29. `pre_command` **故意不**对哪些路径触发？为什么？
30. `on_kanban_dispatch_tick` 的触发点从锁内改到锁外，解决什么问题？（#56066 → #64231）
31. `kanban_task_updated` 为什么只给字段名不给值？
32. hook 超时后 worker 会被怎样处理？为什么不能 kill？哪些 hook fail-closed，哪些 fail-open？
33. `plugins.load_timeout_seconds` 与 `hook_callback_timeout` 有什么区别？
34. `_MAX_ABANDONED_LOADERS` 超限后为什么「拒绝」而不是「内联执行」？

### F 组：ctx 与 manifest

35. `register_tool(override=True)` 需要什么操作员配置？不做这个门会有什么攻击场景？
36. `call_mcp` 的授权粒度是什么？「ambient authority」为什么危险？
37. `PluginState` 的配额是多少？`data_namespace` 为什么要把 `plugin_id` 与 `skill_namespace` 组合？
38. `_VALID_PLUGIN_KINDS` 五个值分别是什么？`model-provider` 与其它四个的行为差异是什么？
39. manifest 里出现未知字段会怎样？v1 与 v2 的处理为什么不同？
40. `config_schema` 里的 `secret` 类型值最终存在哪里？

### G 组：隔离与 catalog

41. `plugins.isolation` 的两个值？`host` 模式的两个收益是什么（一个多租户、一个单机）？
42. `HOST_UNSUPPORTED_CTX_METHODS` 与 `HOST_SKIPPED_CTX_METHODS` 的区别？为什么要分成两张表？
43. 「一张表是运行时和静态审计的单一事实来源」这句话在防什么？
44. `HOST_OBJECT_BASES` 的「父进程造子类」手法解决了什么问题？为什么这比让插件改代码好？
45. `HERMES_PLUGIN_HOST_PROCESS=1` 防的是什么？
46. `isolation_mode()` 为什么必须读托管 overlay 而不是用户 config？
47. catalog 为什么强制 40 位 SHA？tag 有什么问题？
48. `removed.yaml` 的 URL 为什么要规范化成 `host/owner/repo`？
49. `.hermes-catalog.json` 与 `.install-metadata.json` 的分工是什么？Python 为什么不信任前者？
50. 为什么「绝不要加第二个名字索引」？

### H 组：技能与 curator

51. `skills/` 与 `optional-skills/` 的实际数量？为什么小众技能要放后者？
52. `description` 为什么限 60 字符？「陈述能力而非实现」的正反例各一个。
53. 为什么技能正文里不能写 `grep`、`cat`、`sed`？背后的架构原因是什么（不只是风格）？
54. `platforms:` 门控的处理顺序为什么是「先修跨平台，再收窄门控」？
55. `scripts/` 为什么优于「让模型现场写解析器」？三点理由。
56. 技能正文进入上下文的**两个通道**分别是什么？为什么正文绝不能进系统提示？
57. `<available_skills>` 在会话中途变化时，delta note 通道怎么做？为什么每条 note 要陈述「完整差量」？
58. 技能加载工具为什么禁止 `offset`/`limit`？为什么 `read_file` 反而应该有？
59. Curator 只碰哪一类技能？`prune_builtins` 的窄缝语义是什么？
60. 为什么 `skills.disabled` 里的名字要排除出 LLM pass？
61. pin 守卫的是「删除」还是「一切修改」？为什么这样设计？
62. `hermes curator purge` 的时间戳为什么取 `archived_at` 与 mtime 的较新者？

### I 组：MCP

63. MCP 为什么要「一个后台事件循环 + 每 server 一个 Task」？anyio 的哪个限制逼出了这个设计？
64. OSV 预检为什么必须在 cached-npx 替换**之前**？如果顺序反了会怎样？
65. `lazy: true` 的收益与代价分别是什么？为什么默认关闭？
66. 信任为什么必须按 profile 记录？如果只按 server 名记，会发生什么？
67. `trust: untrst`（拼写错误）会被当成什么？为什么？
68. `_trust_gate_check` 的 fail-closed 具体指什么？为什么拒绝消息里要写「不要重试」？
69. MCP 熔断器的三个状态怎么转换？
70. `optional-mcps/` 为什么对 URL-only 的远程 server 不 spawn 本地进程？
71. `hermes mcp serve` 把什么暴露成 MCP 工具？为什么会有这个反向需求？
72. 「内部 import 路径不是 API」的三条理由？用户报插件加载失败时，第一个该查什么？

### J 组：综合

73. 为什么说「技能让模型更会做；插件让进程更有能力；MCP 让工具住在别处」？
74. 三条扩展路径里，哪一条会改变工具表面？哪一条会改变上下文表面？哪一条两者都不改（只改协议）？
75. 如果让你设计一个新的扩展点（比如「自定义审批策略」），你会先回答哪三个问题？

---

<details>
<summary><b>参考答案要点</b>（先自己答，再展开）</summary>

1. 技能。它是一套流程/知识，模型能自己用文本工具执行。
2. 首选 MCP（已有一个 Prometheus MCP server 就直接配）；或写插件 `register_tool` 调 SDK。前者多一个进程/网络/认证但可独立重启；后者更紧耦合但零额外运维。
3. 这是普遍的、所有人受益的、且需要每 turn 触发的——核心（实际就是 `auxiliary` 的 titling 任务）。不满足「能力在边缘」的条件。
4. 扩展现有代码 → CLI+技能 → 服务门控工具 → 插件 → catalog MCP → 新核心工具。因为核心工具让全体用户每次请求付费。
5. 没有具体消费者。例：PR #5295 删掉了 honcho 的 95 行 argparse，改成走 `post_setup()`。
6. prompt 缓存前缀；多 profile 污染；可卸载性。
7. 因为安装/配置是共享体验：三界面、配置校验、密钥进 `.env`、可回滚。N 份实现必然不一致。
8. 框架（`hermes memory setup` 等）调用。因为它是统一入口，插件不该自己造入口。
9. 正确：拓宽通用表面（新 hook / 新 ctx 方法）。错误：硬编码进核心 / 改核心文件。
10. later-wins。因为 `cp -r plugins/kanban ~/.hermes/plugins/` 是最自然的覆盖方式。
11. manifest 的 `name` 与目录名。防「开启内置名字却激活陌生代码」。
12. bundled-first。因为激活是**按名字**（`memory.provider`），掉进来的同名目录不能静默改变行为。
13. 为了 `--help` 干净 + 避免 42 个 provider 的 import 副作用（连接、依赖）。
14. 会双重实例化：模块顶层 `register_provider()` 跑两次 → 两份连接池/缓存 → 配额翻倍。
15. 内置 → legacy `providers/<name>.py` → `$HERMES_HOME`（查找时）。因为 home 是 per profile 的，不能在进程级 discovery 时绑定。
16. import `model_tools.py` 的副作用。
17. cron 调度器、gateway 平台事件、TUI slash worker、query 模式。`invoke_hook` 自己懒发现（#64178）。
18. 任何界面的 install/enable/update；`reload-plugins`。
19. handlers 立即；tools/prompt 下一会话；`deferred.mcp_servers` 等 `mcp.reload`。
20. 工具表面已发送，中途改变会破坏缓存前缀且模型可能看不懂新工具名。
21. env 是进程级会泄漏；contextvar 随执行上下文退出而恢复。场景：multiplex 预检读 parked profile 的 gateway 配置（#123386）。
22. 每个同步消费者都 `_join_background_discovery()`。
23. 44 个；兼作 shell hook 的允许列表。
24. `block` > `approve`。否则安全拦截会被降级成「可选确认」，安全性依赖注册顺序（#87420）。
25. shell hook 的输出解析器没有通道表达它的复杂指令；显式拒绝优于静默忽略。
26. 否则 turn 作用域的 `*_api_request` 订阅者会收到辅助流量（标题、压缩），污染统计（#79733）。
27. 每 delta 同步调 N 个插件不可接受；不可变 payload 保证慢插件不能卡流。
28. 不能。它在认证/配对之前，来源未验证。
29. gateway 的 running-agent 拦截路径（`/stop`、`/approve`、`busy_policy`）。逃生舱不能被慢/恶意插件碰。
30. 慢订阅者延长 board 单写者的临界区（#56066 → #64231 强制锁后移植）。
31. 隐私：任务描述可能敏感；字段名足够驱动 UI。
32. 被遗弃（不 join），因为 Python 不能 kill 线程（#6622）。`pre_tool_call` fail-closed，其它有界 hook fail-open。
33. 前者是 import+register 的总时限（10s 默认），后者是单次 hook 回调（30s 默认）。
34. 内联执行会让主线程被卡死插件永久阻塞。
35. `plugins.entries.<id>.allow_tool_override: true`。否则任何插件能静默替换 `write_file`。
36. 每 server（`mcp_allowlist`，默认拒绝）。ambient authority = 拥有用户所有外部权限。
37. 10 MB。便携插件带技能，两者需共享数据目录。
38. `standalone`、`backend`、`exclusive`、`platform`、`model-provider`。`model-provider` 由 `providers` 自己发现，`PluginManager` 只记录不 import。
39. warn 后继续。v1 有大量自由字段（debug），v2 是契约（warning）。
40. `.env`（`config.yaml` 里的副本是走失的字符串）。
41. `in_process` / `host`。多租户：进程不共享解释器；单机：崩溃隔离。
42. UNSUPPORTED = 拒绝/插件不可用；SKIPPED = 警告并跳过、插件仍加载。因为「加 CLI 子命令」不代表插件整体不可用。
43. 「审计说池化安全」与「它能跑在 host 里」漂移。
44. 核心的 `isinstance` 检查与 ABC 方法调用不改一行代码。让插件改代码 → 绝大多数不支持 → 隔离成空壳。
45. host 里再 spawn host → 无限递归。
46. 被约束者不能修改约束；`/etc/hermes/config.yaml` 必须胜过 profile 自己的。
47. tag/分支可变，同一个 tag 能指向另一棵树；SHA 不可变。
48. `git@`/`ssh://`/`www.` 是同一仓库的不同拼写；不规范化就能绕过 kill list。
49. `.install-metadata.json` 是 installer 拥有的事实；`.hermes-catalog.json` 在树里（仓库可伪造），只给 Desktop 做便利读。
50. 两套索引必然不同步 → 「一台机器能装，另一台不能」的极难定位 bug。
51. 58 / 155。索引在每会话系统提示里，155 个全进就是纯 token 浪费。
52. 索引一行一条，长描述撑大提示并稀释注意力。✅ `Fetch a web page and extract readable text.` ❌ `Uses httpx and BeautifulSoup.`
53. 因为技能是给模型的指令；写 `grep` 会让模型绕过 `search_files` 的路径限制/忽略规则/截断/错误处理，且 Windows 上可能不存在。
54. 门控是最后手段（会让技能在别的平台不可用）；顺手写的 `/tmp` 不该牺牲 Linux 用户。
55. 零 token（只传路径）、可测试、可 review；且不会每次调用都写错。
56. 索引 → 系统提示；正文 → user 消息（`skill_commands`）。正文长、按需、进系统提示会破坏缓存且每次重发。
57. 每 turn 比较「提示里的索引」与「现在会构建的索引」，把差量放进 user note。完整差量保证「提示 + 最新 note」自洽，丢消息也能纠正。
58. 技能的价值在完整性（漏掉 Pitfalls/Verification 会自信做错）+ 分页诱导循环读。`read_file` 是 data 不是 instructional，可能有几 MB。
59. `created_by: "agent"`。`prune_builtins` 只让确定性遍历归档内置技能，绝不进 LLM pass 候选。
60. `skill_view` 拒绝它们，fork 只能拿到它能读能写的技能，否则纯浪费。
61. 只守卫删除。patch 仍需允许，否则 agent 发现 pinned 技能有错也无法修。
62. 防止手动取消归档再重新归档时被过早清除；绝不早于两个证据中较晚的那个。
63. anyio 的 cancel scope 必须同 Task 进入/退出；stdio 传输依赖 anyio。
64. 否则检查的是 wrapper 或本地缓存路径，`_infer_ecosystem` 看不到 npx/uvx/pipx，预检变成 no-op。
65. 收益：启动快。代价：首次调用等连接、工具列表可能为空。默认关因为工具列表准确性更重要。
66. 只按名字记 → profile A 的批准被 profile B 自动继承（B 的用户从没同意）。
67. `untrusted`。fail-closed：拼写错误不能扩大访问。
68. 审批系统不可用 → 拒绝执行。加「不要重试」因为模型会换参数重试，变成反复弹窗骚扰。
69. closed →（阈值失败）open →（冷却）half-open →（成功 reset / 失败重开）。
70. 让「装一个 MCP」不会在你机器上跑陌生二进制。
71. 消息会话（列出、读历史、发消息、轮询事件、管理审批）。因为用户可能同时用 Claude Code 与 Hermes，需要跨客户端看到同一批会话。
72. shim 是永久 API 承诺；插件的正确依赖面是 ctx+ABC；`ImportError` 是显式失败。先看 `hermes plugins list` 的 load error。
73. 三者改变的是不同层：注意力/知识、进程能力、协议边界。
74. 插件改工具表面（也可改上下文）；技能只改上下文（user 消息）；MCP 改工具表面但通过协议，进程边界不变。
75. ①谁受益（全体还是部分）②能否用现有表面③永久成本是什么（token/进程/运维/权限）。

</details>

---

## 19. 小结

把全篇压缩成八句话：

1. **三条路径扩展三种不同的东西**：代码（插件）、知识（技能）、协议（MCP）。
2. **Footprint Ladder 从最小足迹开始**，因为每一级都在增加永久成本，而核心工具让全体用户付费。
3. **插件绝不碰核心**——三条技术理由（缓存前缀、多 profile、可卸载），
   需要能力就拓宽通用表面，没有消费者的 hook 会被拒。
4. **五种 kind 的发现顺序故意不同**：general later-wins（方便覆盖）、
   memory bundled-first（名字激活不能被遮蔽）、model-provider last-writer-wins（用户覆盖内置）。
5. **44 个 hook 是一份承诺**，`block` > `approve`（安全不依赖顺序）、
   超时 fail-closed 只发生在安全路径、紧急控制路径对插件不可达。
6. **`host` 隔离的可靠性来自「一张表 + 造子类」**：运行时与静态审计共读一张表，
   父进程为远程对象动态造 ABC 子类，插件代码零修改。
7. **技能正文走 user 消息、索引走系统提示**，索引变了就用 delta note 补——
   整套机制只为了一件事：不破坏缓存前缀。
8. **MCP 的信任是按 profile 的记录**，因为多 profile 共享进程而信任不能被继承。

**下一篇** → [`12-cron-and-kanban.md`](12-cron-and-kanban.md)：
定时任务怎么可靠地跑、多 agent 工作队列怎么避免重复认领。
那篇会用到本篇的两个概念：**hook 的触发点位置决定性能**、**回调绝不持有数据库锁**。
