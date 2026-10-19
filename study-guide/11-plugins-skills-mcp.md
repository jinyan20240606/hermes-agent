# 11 · 扩展体系：插件 / 技能 / MCP

> 目标：分清三条扩展路径，理解「插件绝不碰核心」这条铁律，掌握技能编写标准。

---

## 1. 三条扩展路径对照

| 路径 | 扩展什么 | 位置 | 发现机制 |
|---|---|---|---|
| **插件（Plugins）** | 工具、hooks、CLI 子命令、平台适配、provider | `plugins/<name>/`、`~/.hermes/plugins/`、`./.hermes/plugins/`、pip entry points | `PluginManager`（[`hermes_cli/plugins.py`](../hermes_cli/plugins.py:1)） |
| **技能（Skills）** | 行为知识、流程、脚本 | `skills/`（内置）、`optional-skills/`（已发布未激活）、`~/.hermes/skills/` | skill 索引 + `skill_view` |
| **MCP** | 外部工具服务器 | config 中的 MCP server | [`tools/mcp_tool_*.py`](../tools/mcp_tool.py:1) |

**选择顺序（Footprint Ladder）**：扩展现有代码 → CLI 命令 + skill →
服务门控工具 → 插件 → 目录里的 MCP server → 最后才是新核心工具。

---

## 2. 插件系统

### 2.1 铁律：插件绝不碰核心

来自 [`plugins/AGENTS.md`](../plugins/AGENTS.md:7)（Teknium，2026 年 5 月）：

> 插件住在自己的目录里，在我们提供的 ABCs / hooks / `ctx` 表面上工作。
> 插件**不得**修改 `run_agent.py`、`cli.py`、`gateway/run.py`、`hermes_cli/main.py` 等。
> 如果它需要框架缺少的能力，**拓宽通用的插件表面**（新 hook、新 ctx 方法）让插件使用它——
> 绝不把插件特定逻辑硬编码进核心。

推论：
- 插件 setup 走 `hermes memory setup` → `provider.post_setup(hermes_home, config)`，
  **不是**平行的顶层命令
- **一个没有具体消费者的 hook 是投机性基础设施，会被拒绝**

### 2.2 插件类型与发现

来自 [`plugins/AGENTS.md`](../plugins/AGENTS.md:69)：

| 类型 | 位置 | 发现 | 备注 |
|---|---|---|---|
| **通用（General）** | `plugins/<name>/`、`~/.hermes/plugins/`、`./.hermes/plugins/`、pip entry points | `PluginManager`，**later-wins** | `register(ctx)` 注册 hooks（`pre_tool_call`、`post_tool_call`、`pre_llm_call`、`post_llm_call`、`on_session_start`、`on_session_end`）、工具（`ctx.register_tool`）、CLI 子命令（`ctx.register_cli_command`）、语言包 |
| **记忆 provider** | `plugins/memory/<name>/` | bundled → `$HERMES_HOME/plugins/` → `./.hermes/plugins/` → entry points；**bundled-first** | 按名字经 `memory.provider` 激活，所以掉进来的目录**不能遮蔽**随附的（与通用插件相反）。实现 `MemoryProvider` ABC |
| **模型 provider** | `plugins/model-providers/<name>/` | `providers/__init__.py._discover_providers()`，**懒** | `__init__.py` 在 load 时调 `providers.register_provider(ProviderProfile(...))`；**last-writer-wins** |
| **上下文引擎 / 图像生成 / 其它** | `plugins/context_engine/`、`plugins/image_gen/` 等 | ABC + 编排器 + 每插件目录 | 接入 [`agent/context_engine.py`](../agent/context_engine.py:1)、[`agent/image_gen_provider.py`](../agent/image_gen_provider.py:1) |
| **平台适配器** | `plugins/platforms/<name>/adapter.py` | gateway | token 锁与作用域 secret 规则见 [`gateway/AGENTS.md`](../gateway/AGENTS.md:1)（`irc`、`feishu` 是范本） |

### 2.3 发现时机的陷阱

`discover_plugins()` **只作为 import `model_tools.py` 的副作用**运行。
不先 import `model_tools.py` 就读插件状态的代码必须显式调 `discover_plugins()`（幂等）。

- Hooks 从 `model_tools.py`（pre/post tool）与 `run_agent.py`（生命周期）调用
- 非强制的 `discover_plugins()` 在 `_discovered` 上短路
- 每条 mid-run 加载路径（任何界面的 install/enable/update、`reload-plugins`）
  都跑 `discover_plugins(force=True)`
- `PluginManager.on_plugin_loaded` 在那个 sweep 里为新加载的插件触发，带激活摘要
  （handlers 立即生效；tools/prompt 下一会话；`deferred.mcp_servers` 直到 `mcp.reload`）
- **绝不**从 RPC 发这个事件

### 2.4 生命周期 hooks 在 owning profile 的作用域下触发

`on_session_start`/`on_session_end`/`sync_turn`/`shutdown` 从 turn（已绑定）**以及**
驱逐、关闭、`tui_gateway` teardown、cron 完成（由调用方绑定）触发。

一个进程服务多个 profile，所以：
- provider **绝不**把 `initialize()` 时的 `hermes_home` 缓存成「那个」home
  ——按每次调用交给它的 home 给状态做 key（`hermes_home_key()`）
- **绝不**为凭证读 `os.environ`（用 `agent.secret_scope.get_secret`，`check_fn` 也是）
- 后台工作通过 `agent.memory_provider.spawn_context_thread` 启动，**绝不**裸 `threading.Thread`
- 平台插件**绝不**改 `os.environ`

### 2.5 插件 host 边界（`plugins.isolation: host`）

`in_process`（默认）把用户插件 import 进 Hermes。
`host` 让每个非内置插件在**每 profile 一个 host 进程**里跑
（[`hermes_cli/plugin_host.py`](../hermes_cli/plugin_host.py:1) 父侧、
`plugin_host_child.py` 子侧、`plugin_host_wire.py` 分帧 JSON 协议）。

不变量：
- **每条用户代码 import 路径都路由到 host 或拒绝**
- **不能跨界的东西是一张表**：`plugin_isolation.HOST_UNSUPPORTED_CTX_METHODS`
  （活 gateway / adapter 对象）。运行时拒绝与静态审计都读它
- **host 永不 spawn host**
- **当操作员钉住时，隔离方不能退出**：`isolation_mode()` / `host_launcher()` 通过托管 overlay 读，
  所以 `/etc/hermes/config.yaml` 胜过 profile 自己的 config
- 插件保持**租户无感**：没有新 API，同一个 `ctx`

### 2.6 插件目录（`plugin-catalog/`）

**唯一**的 out-of-tree 插件发现系统：
- 每个条目一个 YAML，**强制 40 位 hex SHA pin**，人工通过 PR 合并
- [`plugin-catalog/README.md`](../plugin-catalog/README.md:1) = 准入策略
- `removed.yaml` 是 kill list——每条安装路径（CLI、dashboard、TUI）都拒绝匹配
- catalog 出处住在 installer 拥有的 `.install-metadata.json` 记录上，**绝不在树里**
  （树的 `.hermes-catalog.json` 只是 Desktop 读的便利副本；Python **绝不**信任它——
  仓库可以伪造）

### 2.7 什么能进这个树（策略）

来自 [`plugins/AGENTS.md`](../plugins/AGENTS.md:17)：

- **不再新增树内 memory provider**（`plugins/memory/` 已关闭）
- **不再新增第三方产品插件**（可观测性后端、供应商 SaaS 连接器、分析面板、付费服务绑定——
  作为独立插件仓库发布）
- Eclipse 参考/文档伙伴插件住在 `hermes-example-plugins` 仓库，不在这里

---

## 3. 技能系统

### 3.1 两个表面

- **`skills/`** — 内置，默认加载，按类别组织
  （`apple`、`autonomous-ai-agents`、`creative`、`devops`、`email`、`media`、
  `note-taking`、`productivity`、`research`、`social-media`、`software-development`、`web`）
- **`optional-skills/`** — 重/小众技能，已发布但**未激活**，
  经 `hermes skills install official/<category>/<skill>` 安装
  （适配器 [`tools/skills_hub_official.py`](../tools/skills_hub_official.py:1) 的 `OptionalSkillSource`）

**审查 skill PR 时**：检查目标目录——重依赖或小众技能归 `optional-skills/`。

### 3.2 SKILL.md frontmatter

```yaml
name: ...
description: ...        # ≤ 60 字符，一句话，以句号结尾
version: ...
author: ...
license: ...
platforms: [macos]      # OS 门控
metadata:
  hermes:
    tags: ...
    category: ...
    related_skills: ...
    config: ...         # 技能需要的 config.yaml 设置（存 skills.config.<key>）
```

顶层 `tags:` / `category:` 也被接受，由 loader 从 `metadata.hermes.*` 镜像。

### 3.3 编写标准（硬性，由测试强制）

来源：[`skills/AGENTS.md`](../skills/AGENTS.md:24)，
由 `tests/skills/test_authoring_standards.py` 强制执行：

1. **`description` ≤ 60 字符、一句话、以句号结尾。** 陈述能力而非实现；
   禁营销词（"powerful"、"comprehensive"、"seamless"、"advanced"）；不要重复 name
2. **散文里用反引号引用原生 Hermes 工具**（`terminal`、`web_extract`、`read_file`、`patch`、
   `search_files`、`vision_analyze`、`browser_navigate`、`delegate_task`）。
   **绝不**提及 agent 已包装的 shell 工具：`grep` → `search_files`，`cat`/`head`/`tail` → `read_file`，
   `sed`/`awk` → `patch`，`find`/`ls` → `search_files target='files'`
3. **`platforms:` 门控要对照实际脚本 import 审计。** POSIX 专属原语（硬编码 `/tmp`、`fcntl`、
   `termios`、`os.setsid`、`os.kill(pid, 0)`、`/proc`、`signal.SIGKILL`、bash heredoc、`osascript`、
   `apt`、`systemctl`）需要平台声明。**先修跨平台**（`tempfile.gettempdir`、`pathlib.Path`、
   `psutil.pid_exists`），只在依赖真与平台绑定时收窄门控
4. **`author` 先署真人。** 外部贡献者真名 + GitHub handle 在前，"Hermes Agent" 在后
5. **现代章节顺序**：`# <Skill> Skill`、2–3 句引言、`## When to Use`、`## Prerequisites`、
   `## How to Run`、`## Quick Reference`、`## Procedure`、`## Pitfalls`、`## Verification`。
   复杂技能 ~200 行，简单 ~100 行
6. **`scripts/`、`references/`、`templates/`。** 不要让模型每次调用都内联写解析器或非平凡逻辑——
   发一个 helper 脚本并用 skill-relative 路径引用它
7. **测试放 `tests/skills/test_<skill>_skill.py`**，仅 stdlib + pytest + `unittest.mock`，无实时网络
8. **`.env.example` 新增内容放在清晰分隔的块里**

### 3.4 加载技能的方式（缓存铁律的体现）

**技能 slash 命令**（[`agent/skill_commands.py`](../agent/skill_commands.py:1)）
扫描 `~/.hermes/skills/`，**以 user 消息注入**，绝不注入系统提示。

**`offset`/`limit` 分页在技能加载工具上被禁止**——agent 必须完整读一个 skill。

### 3.5 `<available_skills>` 索引

skills 索引是 system prompt 的一部分（回看 [`04-prompt-and-caching.md`](04-prompt-and-caching.md)）。
当索引变化时，差异通过**一次性 note 通道**（走 user 消息）送达，
只在差异变化时发送——这样不需要重建 system prompt 就能让索引更新。

### 3.6 Curator（技能生命周期）

见 [`08-memory-context-compression.md`](08-memory-context-compression.md) § 8。

核心不变量：**只碰 `created_by: "agent"` 的技能**；**永不删除**（归档是上限）；
被 pin 的技能豁免一切自动转移与 LLM 审查。
`skill_manage(action="delete")` 拒绝被 pin 的技能，但 patch/edit/write_file/remove_file 仍工作，
这样 agent 能继续改进它们。

---

## 4. MCP（Model Context Protocol）

### 4.1 代码形状

[`tools/mcp_tool.py`](../tools/mcp_tool.py:1) 是门面，兄弟模块：
`mcp_tool_config`、`mcp_tool_discovery`、`mcp_tool_transport`、`mcp_tool_registration`、
`mcp_tool_content`、`mcp_tool_errors`、`mcp_tool_handlers`。

发现：`tools.mcp_tool_discovery.discover_mcp_tools()` 读 MCP server 配置，
注册来自外部 server 的工具。

### 4.2 MCP 信任是**每 profile 的记录**

来自 [`tools/AGENTS.md`](../tools/AGENTS.md:109)：

- `mcp_tool_registration.py::_record_scope_trust` 以 home 为 key 记录信任
- **次要 profile 绝不采纳启动 profile 对同名 server 的信任**
- `mcp_tool_handlers.py::_trust_gate_check` 查询调用会话的 profile

### 4.3 MCP 相关的目录

- [`optional-mcps/`](../optional-mcps/) — 可选 MCP server
- [`mcp_serve.py`](../mcp_serve.py:1) — 把 Hermes 自身作为 MCP server 暴露

---

## 5. 扩展时的「在哪里打补丁」

- 通用插件通过 `ctx` 注册 → 在 `ctx` 方法上打补丁
- 记忆 provider 通过真实发现路径加载 → 用临时 `HERMES_HOME` 测
- 模型 provider 的 discovery 在 `providers/__init__.py` → 在那打补丁
- **内部 import 路径不是 API**：`<stem>_<topic>` 移动不提供兼容 shim，
  老路径现在抛 `ImportError`，在 `hermes plugins list` 里显示为插件的 load error

---

## 6. 测试约定

- 测试放 `tests/plugins/`、`tests/skills/`
- 用**真实发现**加载，配临时 `HERMES_HOME`
- 断言**行为**（工具被注册、hook 以期望 kwargs 触发），**不是数量**
- 兼容测试**通过真实发现路径加载冻结的插件**并断言结果——
  绝不断言精确的 registry/catalog 数量、绝不做源码阅读测试

---

## 7. 本篇小结与下一步

- **插件绝不碰核心**；需要能力就拓宽通用表面。
- 三种插件发现语义不同：通用 later-wins、memory bundled-first、model-provider last-writer-wins。
- **技能标准是硬性的**：60 字符描述、反引号工具名、平台门控审计、真人署名。
- MCP 信任是**每 profile 记录**，不跨 profile 继承。

下一步 → [`12-cron-and-kanban.md`](12-cron-and-kanban.md)：定时任务与多 agent 工作队列。
