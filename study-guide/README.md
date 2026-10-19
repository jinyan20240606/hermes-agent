# Hermes Agent 源码精读学习集

> 面向「自上而下、广而深」的 2 天速成式架构精读材料。
> 所有结论均来自仓库源码、各层 `AGENTS.md` 与 `website/docs/developer-guide/` 原始文档，
> 每篇正文都标注了可跳转的源码锚点，便于你对照阅读。

---

## 一、这套材料解决什么问题

Hermes Agent 是一个「核心窄腰 + 边缘生长」的成熟 Agent 框架，代码量大、分层细、不变量（invariant）多。
直接读代码容易在 274 个 `tools/*.py`、上百个 `agent/*.py` 兄弟模块里迷路。

这套文档的做法是：

1. **先给骨架**：一张架构地图、一份分层职责表、一条完整数据流。
2. **再钻纵深**：每个子系统单独成篇，讲清「谁调用谁」「关键不变量是什么」「改哪里会踩坑」。
3. **最后给索引**：一份「按症状查代码」的速查表，和一份 2 天时间表。

---

## 二、两天学习路线图

### Day 1 — 打通主干（自顶向下）

| 时段 | 阅读顺序 | 目标 | 产出 |
|---|---|---|---|
| 上午 1 | [`01-architecture-overview.md`](01-architecture-overview.md) → [`02-entrypoints.md`](02-entrypoints.md) | 建立全局地图，认清 4 类入口 | 能画出「用户输入 → AIAgent → 返回」的框图 |
| 上午 2 | [`03-agent-core.md`](03-agent-core.md) | 吃透 turn loop 与 `agent/turn_*.py` 相位拆分 | 能背出一次迭代的 8 个相位 |
| 下午 1 | [`04-prompt-and-caching.md`](04-prompt-and-caching.md) → [`05-tools-system.md`](05-tools-system.md) | 理解「缓存神圣」不变量 + 工具注册/发现/分发 | 能解释为什么不能在会话中改 system prompt |
| 下午 2 | [`06-provider-runtime.md`](06-provider-runtime.md) → [`07-state-and-session.md`](07-state-and-session.md) | Provider 解析链 + SQLite 会话存储 | 能说清 `(provider, model) → (api_mode, key, base_url)` |
| 晚上 | [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) | 通览所有「说话算数」的不变量清单 | 形成review意识 |

### Day 2 — 铺开边缘（横向广度）

| 时段 | 阅读顺序 | 目标 |
|---|---|---|
| 上午 1 | [`08-memory-context-compression.md`](08-memory-context-compression.md) | 记忆 provider / 上下文引擎 / 压缩三层机制 |
| 上午 2 | [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md) | 网关双消息守卫、流式交付契约、平台适配 |
| 下午 1 | [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md) | 四个前端面共享同一后端的方式 |
| 下午 2 | [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) → [`12-cron-and-kanban.md`](12-cron-and-kanban.md) | 扩展体系与调度体系 |
| 下午 3 | [`13-subagents-delegation.md`](13-subagents-delegation.md) → [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md) | 子代理委派 + 多 Profile 隔离 |
| 收尾 | [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) + 速查表 | 定点复习 |

---

## 三、文档清单

| 编号 | 文档 | 主题 | 关键源码 |
|---|---|---|---|
| 01 | [`01-architecture-overview.md`](01-architecture-overview.md) | 架构地图与设计哲学 | `run_agent.py`, `model_tools.py` |
| 02 | [`02-entrypoints.md`](02-entrypoints.md) | 5 类运行形态与入口 | `cli.py`, `gateway/run.py`, `acp_adapter/` |
| 03 | [`03-agent-core.md`](03-agent-core.md) | AIAgent 与 turn loop | `agent/conversation_loop.py`, `agent/turn_*.py` |
| 04 | [`04-prompt-and-caching.md`](04-prompt-and-caching.md) | 系统提示分层与缓存 | `agent/prompt_builder.py`, `agent/system_prompt.py` |
| 05 | [`05-tools-system.md`](05-tools-system.md) | 工具注册/发现/分发/toolsets | `tools/registry.py`, `toolsets.py` |
| 06 | [`06-provider-runtime.md`](06-provider-runtime.md) | Provider 解析与 3 种 API 模式 | `hermes_cli/runtime_provider.py`, `providers/` |
| 07 | [`07-state-and-session.md`](07-state-and-session.md) | SQLite 状态库与会话血缘 | `hermes_state.py`, `hermes_state_*.py` |
| 08 | [`08-memory-context-compression.md`](08-memory-context-compression.md) | 记忆/上下文引擎/压缩 | `agent/memory_manager.py`, `agent/context_compressor.py` |
| 09 | [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md) | 消息网关与平台适配 | `gateway/run.py`, `gateway/platforms/base.py` |
| 10 | [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md) | CLI / TUI / Desktop / Web | `cli.py`, `tui_gateway/`, `apps/desktop/`, `web/` |
| 11 | [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) | 插件/技能/MCP 扩展 | `hermes_cli/plugins.py`, `skills/`, `tools/mcp_tool*.py` |
| 12 | [`12-cron-and-kanban.md`](12-cron-and-kanban.md) | 定时任务与看板调度 | `cron/scheduler.py`, `hermes_cli/kanban.py` |
| 13 | [`13-subagents-delegation.md`](13-subagents-delegation.md) | 子代理与并行委派 | `tools/delegate_tool.py`, `agent/subagent_lifecycle.py` |
| 14 | [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md) | Profile 隔离与多路复用 | `hermes_cli/profiles.py`, `agent/secret_scope.py` |
| 15 | [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) | 不变量总表与代码规范 | 各层 `AGENTS.md` |

---

## 四、两条铁律（先记住这两条，再看其它）

> 整个框架几乎每一个设计决策，都是这两条之一的推论。

1. **逐会话的 prompt caching 神圣不可侵犯。**
   任何中途修改历史上下文、切换 toolset、重载记忆、重建 system prompt 的行为，都会破坏已缓存的前缀，
   成倍推高用户成本。**唯一的例外是上下文压缩（compression）。**
   需要中途注入内容时，只能搭「user 消息」或「tool 结果」的车，绝不碰 system prompt。

2. **核心是窄腰，能力长在边缘。**
   每一个模型工具都会在每一次 API 调用中发送，所以新增「核心工具」的门槛极高。
   新能力优先走：扩展现有代码 → CLI 命令 + skill → 服务门控工具 → 插件 → 目录里的 MCP server →
   最后才是新核心工具。

---

## 五、如何使用源码锚点

文档中的引用格式为「方括号链接文字 + 圆括号相对路径:行号」，例如：
[`agent/conversation_loop.py`](../agent/conversation_loop.py:1)。
在支持跳转的编辑器里可直接点击定位到具体行，用于对照阅读。

> 注意：行号基于写作时的仓库状态。若 `main` 已前进，请以符号名为准（文档同时给出了符号名）。

---

## 六、快速上手命令（边读边跑）

```bash
# 依赖与环境（项目规定必须走 PM，不要裸 pip/uv）
source ./activate          # fish: activate.fish / PowerShell: activate.ps1
python -m pm.build_env --source . --out .venv --group dev --group test

# 运行测试（永远用脚本，不要裸 pytest）
scripts/run_tests.sh tests/agent/
scripts/run_tests.sh -v --tb=long

# 全量 lint / 健康检查
python scripts/check
```

约定：`scripts/run_tests.sh` 会强制 CI 同构环境（清空凭证变量、`TZ=UTC`、`HERMES_HOME` 指向临时目录、
按文件做子进程隔离），因此它才是唯一可信的测试入口。
