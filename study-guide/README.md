# Hermes Agent 源码精读学习集

> 面向「自上而下、广而深」的 2 天速成式架构精读材料。
> 所有结论均来自仓库源码、各层 `AGENTS.md` 与 `website/docs/developer-guide/` 原始文档，
> 每篇正文都标注了可跳转的源码锚点（`../path.py:行号`），便于对照阅读。

---

## 一、这套材料解决什么问题

Hermes Agent 是一个「核心窄腰 + 边缘生长」的成熟 Agent 框架：代码量大、分层细、
不变量（invariant）多。直接读代码很容易在几百个 `tools/*.py`、上百个 `agent/*.py`
兄弟模块里迷路，或者在改第一行代码时踩进一个「没有报错、但结果错」的坑。

这套文档的做法是三层递进：

1. **先给骨架**：一张架构地图、一份分层职责表、一条完整数据流。
2. **再钻纵深**：每个子系统单独成篇，讲清「谁调用谁」「关键不变量是什么」「改哪里会踩坑」。
3. **最后收口**：一份不变量总表、一份「按症状查代码」速查表、一套可打印的改代码前检查清单。

**写给谁**：刚学编程不久的前端开发者也能读懂。每篇都有 `§0 前置概念`
（这个子系统里最容易误解的 3~6 个名词），再逐层深入。

---

## 二、两天学习路线图

### Day 1 — 打通主干（自顶向下）

| 时段 | 阅读顺序 | 目标 | 产出 |
|---|---|---|---|
| 上午 1 | [`01-architecture-overview.md`](01-architecture-overview.md) → [`02-entrypoints.md`](02-entrypoints.md) | 建立全局地图，认清各类入口 | 能画出「用户输入 → AIAgent → 返回」的框图 |
| 上午 2 | [`03-agent-core.md`](03-agent-core.md) | 吃透 turn loop 与 `agent/turn_*.py` 相位拆分 | 能背出一次迭代的相位顺序 |
| 下午 1 | [`04-prompt-and-caching.md`](04-prompt-and-caching.md) → [`05-tools-system.md`](05-tools-system.md) | 理解「缓存神圣」不变量 + 工具注册/发现/分发 | 能解释为什么不能在会话中改 system prompt |
| 下午 2 | [`06-provider-runtime.md`](06-provider-runtime.md) → [`07-state-and-session.md`](07-state-and-session.md) | Provider 解析链 + SQLite 会话存储与血缘 | 能说清 `(provider, model) → (api_mode, key, base_url)` |
| 晚上 | [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) §1~§6 | 通览「机器会拦你」的全部规则（HX 全表 + CI） | 形成 review 意识 |

### Day 2 — 铺开边缘（横向广度）

| 时段 | 阅读顺序 | 目标 |
|---|---|---|
| 上午 1 | [`08-memory-context-compression.md`](08-memory-context-compression.md) | 记忆 provider / 上下文引擎 / 压缩三层机制 |
| 上午 2 | [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md) | 网关双消息守卫、流式交付契约、平台适配 |
| 下午 1 | [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md) | 四个前端面共享同一后端的方式 |
| 下午 2 | [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) → [`12-cron-and-kanban.md`](12-cron-and-kanban.md) | 扩展体系与调度体系 |
| 下午 3 | [`13-subagents-delegation.md`](13-subagents-delegation.md) → [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md) | 子代理委派 + 多 Profile 隔离（**全仓库最难的一篇**） |
| 收尾 | [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) §7~§13 + 自检题 | 收口、检查清单、84 道自检 |

> **时间不够的最小路径**：01 → 03 → 04 → 05 → 09 → 14 → 15。
> 这七篇覆盖了「主干 + 最难的不变量 + 全部规则」；其余按需查。

---

## 三、文档清单

| 编号 | 文档 | 行数 | 自检题 | 主题 | 关键源码 |
|---|---|---|---|---|---|
| 01 | [`01-architecture-overview.md`](01-architecture-overview.md) | 1051 | 8 | 架构地图与设计哲学 | `run_agent.py`, `model_tools.py` |
| 02 | [`02-entrypoints.md`](02-entrypoints.md) | 1322 | 14 | 各类运行形态与入口 | `cli.py`, `gateway/run.py`, `acp_adapter/` |
| 03 | [`03-agent-core.md`](03-agent-core.md) | 1472 | 18 | AIAgent 与 turn loop | `agent/turn_facade.py`, 33 个 `agent/turn_*.py` |
| 04 | [`04-prompt-and-caching.md`](04-prompt-and-caching.md) | 1165 | 17 | 系统提示分层与缓存 | `agent/prompt_builder.py`, `agent/surface_switch.py` |
| 05 | [`05-tools-system.md`](05-tools-system.md) | 1834 | 27 | 工具注册/发现/分发/toolsets | `tools/registry.py`, `toolsets.py` |
| 06 | [`06-provider-runtime.md`](06-provider-runtime.md) | 1696 | 30 | Provider 解析与 API 模式 | `hermes_cli/runtime_provider.py`, `plugins/model-providers/` |
| 07 | [`07-state-and-session.md`](07-state-and-session.md) | 2684 | 50 | SQLite 状态库与会话血缘 | `hermes_state.py`, 33 个 `hermes_state_*.py` |
| 08 | [`08-memory-context-compression.md`](08-memory-context-compression.md) | 3547 | 108 | 记忆/上下文引擎/压缩 | `agent/memory_*.py`, `agent/compression_*.py` |
| 09 | [`09-gateway-and-platforms.md`](09-gateway-and-platforms.md) | 2663 | 102 | 消息网关与平台适配 | `gateway/run.py`, 30 个 `run_*.py`, `gateway/platforms/` |
| 10 | [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md) | 2542 | 97 | CLI / TUI / Desktop / Web | `cli.py`, `tui_gateway/`, `apps/desktop/`, `web/` |
| 11 | [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md) | 2405 | 150 | 插件/技能/MCP 扩展 | `hermes_cli/plugins.py`, `skills/`, 18 个 `tools/mcp_tool*.py` |
| 12 | [`12-cron-and-kanban.md`](12-cron-and-kanban.md) | 2524 | 160 | 定时任务与看板调度 | `cron/scheduler.py`, 21 个 `hermes_cli/kanban*.py` |
| 13 | [`13-subagents-delegation.md`](13-subagents-delegation.md) | 2171 | 128 | 子代理与并行委派 | 9 个 `tools/delegate_tool*.py`, `agent/subagent_lifecycle.py` |
| 14 | [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md) | 2533 | 83 | Profile 隔离与多路复用 | `hermes_cli/profiles.py`, `agent/secret_scope.py` |
| 15 | [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md) | 2042 | 84 | 不变量总表、CI 与代码规范 | `scripts/code_health/config.py`, 15 个 `AGENTS.md` |
| **合计** | | **31,651** | **1,076** | 含本 README 218 行共 **31,869** 行 | |

**每篇的统一结构**（便于跳读）：

```text
篇首四问（读法 + 会学到什么）
  → 「本篇相对旧版新增」对照表
  → §0 前置概念（最容易误解的名词）
  → §1 代码形状（文件/行数表 + ASCII 图）
  → §2..§N 分节深入（每个机制：它解决什么问题 → 代码怎么做的 → 为什么不能换个做法）
  → 陷阱清单（症状 / 原因 / 修法 / 探测方法）
  → 「在哪里打补丁」症状→文件表
  → 自检题（本篇 8~160 道，全书 1,076 道）+ 答案要点
  → 小结 N 句 + 60 秒口述版
```

**体量参考**：15 篇正文 31,651 行、**1,243 个代码/图表块**（2,486 条围栏，全部成对）、
**1,076 道自检题**。全部代码锚点已通过脚本校验（路径存在、行号在文件范围内、
内部链接可解析），15 篇全部 `issues: 0`。

---

## 四、两条铁律（先记住这两条，再看其它）

> 整个框架几乎每一个设计决策，都是这两条之一的推论。

### 1. 逐会话的 prompt caching 神圣不可侵犯

任何中途修改历史上下文、切换 toolset、重载记忆、重建 system prompt 的行为，
都会破坏已缓存的前缀，**成倍推高用户成本**。**唯一的例外是上下文压缩（compression）。**
需要中途注入内容时，只能搭「user 消息」或「tool 结果」的车，绝不碰 system prompt。

**技术上为什么**：provider 侧的前缀缓存按「输入前缀逐字节相同」命中。
system prompt 在 messages[0]，它是**最前面**的那一段 —— 改它，后面所有内容都失去缓存。

**允许的注入方式**（完整清单）：

| 方式 | 为什么安全 |
|---|---|
| 追加 user 消息 / tool 结果 | 前缀没变 |
| `/steer` 作为独立 user 行（在 tool 结果之后） | `assistant(tool_calls) → tool → user` 在所有 provider 路径合法 |
| skill slash 命令以 user 消息注入 | 不碰 system prompt |
| 一次性 note（如 `<available_skills>` 差异） | 只在差异变化时发一次 |

### 2. 核心是窄腰，能力长在边缘

每一个模型工具都会在**每一次** API 调用中发送（`tools[]` 数组），
所以新增「核心工具」的门槛极高。新能力按 Footprint Ladder 走：

```text
1. 扩展现有代码
2. CLI 命令 + skill
3. 服务门控工具（check_fn 回答可达性/opt-in，绝不回答 per-session 表面）
4. 插件
5. 目录里的 MCP server
6. 新核心工具（必须：基础、广泛有用、否则够不着）
```

**取能解决它的最高一级**（数字越小足迹越小）。

---

## 五、如何使用源码锚点

文档中的引用格式为「方括号链接文字 + 圆括号相对路径:行号」，例如
[`agent/conversation_loop.py`](../agent/conversation_loop.py:1)。
在支持跳转的编辑器里可直接点击定位。

> **注意**：行号基于写作时的仓库状态。若 `main` 已前进，请以**符号名**为准
> （每处引用同时给了符号名，`grep -rn "def <name>"` 即可重新定位）。

---

## 六、快速上手命令（边读边跑）

```bash
# 依赖与环境（项目规定必须走 PM，不要裸 pip/uv）
source ./activate          # fish: activate.fish / PowerShell: activate.ps1
hermes --version

# 独立的测试解释器（全新构建，不是原地 sync；输出目录必须不存在）
python -m pm.build_env --source . --out .venv --group dev --group test

# 运行测试（永远用脚本，不要裸 pytest）
scripts/run_tests.sh tests/agent/
scripts/run_tests.sh -v --tb=long

# 全量 lint / 健康检查（= CI 的 lint lane 同构）
python scripts/check
python scripts/check --only health
python scripts/check --install-hook pre-push    # 每次 push 自动跑
```

约定：

- `scripts/run_tests.sh` 会强制 CI 同构（清空凭证变量、`TZ=UTC`、`LANG=C.UTF-8`、
  `HERMES_HOME` 指向临时目录、按文件子进程隔离），因此它是**唯一可信**的测试入口。
- `python scripts/check` 跑的检查项与 CI 的 lint lane 完全一致；hook 可以被 `--no-verify` 跳过，
  CI 不能。

---

## 七、按问题查文档

| 我想知道…… | 看 |
|---|---|
| 用户输入到最终响应经过哪些模块 | 01 → 03 |
| 为什么不能中途改 system prompt | 04 §缓存 + 15 §3.1 |
| 工具是怎么被发现和暴露的 | 05 |
| `(provider, model)` 怎么变成实际 API 调用 | 06 |
| 会话数据存在哪、血缘怎么连 | 07 |
| 记忆为什么不会跨 cron 生效 | 08 + 12 |
| 消息为什么被重复发送了 | 09 §流式四条 |
| Desktop / TUI / Web / CLI 怎么共享后端 | 10 |
| 插件和 skill 的边界在哪 | 11 |
| cron 为什么能把两件事跑在一起 | 12 |
| 子代理怎么被中断和收集 | 13 |
| 多个 profile 为什么不会串 | 14 |
| **这条规则为什么存在 / 违反会怎样** | **15** |
| 我要改代码，提交前该检查什么 | 15 §11 |
| 这个「缺失的功能」是 bug 还是设计 | 15 §9 |

---

## 八、阅读约定

| 记号 | 含义 |
|---|---|
| `#123456` | 仓库 issue/PR 号，`git log --oneline --grep="#123456"` 可找到原始改动 |
| `# health: allow <RULE> -- <why>` | code-health ratchet 的豁免语法，**必须写理由** |
| HX001~HX013 | lint 规则 ID，权威定义在 `scripts/code_health/config.py` |
| PS-P05 / PS-P06 | profile-scope 模式规则，正则在 `scripts/ci/profile_scope_patterns.json` |
| 「launch profile」 | 启动这个进程时所在的 profile（`os.environ` 装的是它的值） |
| 「served profile」 | 这个进程代为服务的其它 profile（只在 ContextVar 作用域里可见） |
| 「硬边界 / 软命名空间」 | 硬 = 物理上够不到；软 = 约定 + 过滤 |

---

## 九、延伸阅读

- **长文档**：`website/docs/developer-guide/`（每篇末尾都有对应条目）
- **规则原文**：15 个 `AGENTS.md`（在你进入对应目录时自动加载）
- **贡献规范**：[`contributing.md`](../website/docs/developer-guide/contributing.md:1)
  （rubric、Footprint Ladder、PR 流程）
- **安全范围**：[`SECURITY.md`](../SECURITY.md:1)（§2 信任模型 / §3 范围权威）
- **子系统归属**：[`codebase-ownership.md`](../website/docs/developer-guide/codebase-ownership.md:1)
