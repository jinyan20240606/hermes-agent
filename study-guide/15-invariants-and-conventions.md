# 15 · 不变量、代码规范与速查总表

> 目标：一页纸装下所有「说话算数」的规则。看代码/写 PR 前扫一眼。

---

## 1. 两条根铁律

| # | 铁律 | 推论 |
|---|---|---|
| 1 | **逐会话 prompt caching 神圣** | 绝不中途改历史/toolset/记忆/system prompt；唯一例外是压缩；注入只能走 user 消息或 tool 结果 |
| 2 | **核心是窄腰，能力长在边缘** | 新能力按 Footprint Ladder，最后才考虑新核心工具 |

---

## 2. Footprint Ladder（取能解决它的最高一级）

```text
1. 扩展现有代码
2. CLI 命令 + skill
3. 服务门控工具（check_fn 回答可达性/opt-in，绝不回答 per-session 表面）
4. 插件
5. 目录里的 MCP server
6. 新核心工具（必须：基础、广泛有用、否则够不着）
```

---

## 3. 全局工程规范（HX 系列）

| 规则 | 内容 | 违反后果 |
|---|---|---|
| HX001 | 路径用 `get_hermes_home()`，文本用 `display_hermes_home()`；**绝不硬编码 `~/.hermes`** | 每 profile 状态错乱 |
| HX002/HX004/HX005/HX012 | 每 profile 的进程级槽位以 `hermes_home_key()` 为 key；turn 外的路径必须显式绑作用域 | 静默的默认 profile 泄漏 |
| HX003 | **绝不**从 argv 子串推断进程身份；用 `gateway.status.looks_like_gateway_command_line` / `hermes_cli.update_cmd._hermes_holder_subcommand` | 误杀/误判进程 |
| HX013 | 测试里的非零 `time.sleep` 会被 ratchet 拒绝；用 `wait_until` / Event | CI 拒绝 |
| — | **facade + siblings**；siblings 函数内 late-import facade，模块级无环 | import 循环 |
| — | **在哪里被读，就在哪里 patch** | 补丁静默失效 |
| — | 无防御性杂音：无 `try/except: pass`、无「没人设的 flag」、无未 E2E 证实的死代码 | 维护债 |
| — | 依赖带上限（`>=floor,<next_major`；git URL 钉 40 位 SHA；Actions 钉 SHA + `# vN`） | CI 拒绝 |
| — | 改 `pyproject.toml` 后跑 `hermes pm lock` 并提交 `uv.lock`；**绝不**用裸 pip/uv 改 Hermes 环境 | 环境损坏 |
| — | 机器事实与可执行文件查找走 `hermes_platform` | 测试拒绝 |

### 3.1 尺寸 ratchet（`scripts/code_health/config.py`）

- 新函数：圈复杂度 ≤ 20、≤ 300 行、嵌套 ≤ 6
- 文件 ≤ 2000 行
- 已超标的单元**只能降**
- `# noqa` **不**豁免 ratchet 发现；用 `# health: allow <RULE> -- <why>`

### 3.2 Facade + siblings 三条潜规则

1. **按主题找代码**：`grep -rn "def name" <dir>/<stem>_*.py`
2. **siblings 延迟 import facade**（函数体内），**绝不**模块级循环
3. **在哪里被读，就在哪里 patch**

---

## 4. Agent / 消息流不变量

| 不变量 | 细节 |
|---|---|
| system prompt 逐字节稳定 | 只构建一次；只有压缩触发重建 |
| 严格角色交替 | 绝不两个同角色连排；唯一例外 `/steer`（独立 user 行，在 tool 结果之后） |
| 唯一上下文变更是压缩 | 其它注入走 user 消息 / tool 结果 / 一次性 note |
| context files 只从 CWD 启动时加载 | 有上限；绝不加载安装树的 `AGENTS.md`；子目录提示拒绝工作目录外路径 |
| `_last_resolved_tool_names` 是进程全局 | 子代理运行期间可能陈旧（`_run_single_child` save/restore） |
| skill slash 命令以 user 消息注入 | 绝不进 system prompt |
| `<available_skills>` 差异走一次性 note | 只在差异变化时发送 |

---

## 5. 工具不变量

| 不变量 | 细节 |
|---|---|
| 自注册在 import 时 | 顶层 `registry.register()` 被 AST 发现 |
| handler 返回 JSON 字符串 | 唯一例外是多模态信封 `{"_multimodal": True, ...}` |
| `check_fn` 回答可达性/opt-in | **绝不**回答「什么界面」；结果按 `hermes_home_key()` TTL 缓存 |
| schema 描述不点名其它 toolset 的工具 | 交叉引用在 `get_tool_definitions()` 动态加 |
| schema 描述路径用 `display_hermes_home()` | 状态文件用 `get_hermes_home()`（调用时） |
| 教学类工具无 offset/limit | 模型只读第 1 页 |
| Agent 级工具走 `INLINE_TOOL_EXECUTORS` | `todo`/`memory`，绕过 registry |
| 加后端 = 新 sibling / provider 条目 | **绝不** `elif` 判断后端名 |
| 每个 spawn 走同一 env builder | `build_subprocess_env` / `served_profile_child_env` |
| 后台进程终止先通知父进程 | 绝不先 SIGTERM 后代 |
| 表面能力是**会话**的属性 | 不是进程 env（`HERMES_DESKTOP=1` ≠ GUI 在看） |

---

## 6. 网关不变量

| 不变量 | 细节 |
|---|---|
| 双消息守卫 | 适配器 `_pending_messages` + runner 拦截；审批类命令必须绕过两者并内联派发 |
| 流式四条 | ①草稿帧前缀稳定 ②消费方声明最终 ③中间发送带 `_interim_send` ④用编辑对账 |
| 每事件一个身份，先规范化 | `resolve_identity`；在它之前不派生 key |
| 接收适配器 ≠ 交付适配器 | `_intake_adapter_for` / `_delivery_adapter_for`；绝不读 `self.adapters[platform]` |
| multiplex 下 env 读取 fail closed | 作用域 miss 返回 default，**绝不** `os.environ` |
| 作用域按 profile 活动绑定 | 不按 turn |
| 未服务要报告，不静默 | `_note_unserved_secondary_platform` |
| `serve` 随 app 死；`gateway run` 独立存活 | 别「修」这两个 |

---

## 7. Cron / Kanban 不变量

| 不变量 | 细节 |
|---|---|
| 不活动看门狗 | 是**不活动时间**，不是墙钟 |
| 每周期出现都记账 | 派发前推进 `next_run_at` + 打 `pending_slot`；绝不静默丢 slot |
| 一个 ticker 顺序迭代所有 profile | 在 `_profile_cron_scope` 下；**绝不** N 线程 |
| cron 归属不由 `multiplex_profiles` 门控 | 该 flag 门控适配器 |
| in-flight 状态按 `(home, job_id)` 做 key | 「每 profile 进程假设」是 bug 类别 |
| claim 用它注册时的 key 释放 | 传 `home=`；绝不从 key 一半重建 home |
| board 是硬边界，tenant 是软命名空间 | — |
| 通知从任务所属 profile 离开 | — |
| prompt 注入按**所有权**门控 | 不是工具访问权 |
| 后代围栏是**路径** | 不是 flag |

---

## 8. 测试规范（`tests/AGENTS.md`）

| 规则 | 内容 |
|---|---|
| **永远用 `scripts/run_tests.sh`** | 绝不用裸 `pytest`；它强制 CI 同构（清凭证、`TZ=UTC`、临时 `HERMES_HOME`、按文件子进程隔离） |
| 位置镜像源码树 | `tests/<top-level source dir>/` |
| 测试**绝不**写 `~/.hermes/` | 用 autouse `_isolate_hermes_home` fixture |
| **绝不**伪造宿主 OS | 用 `@pytest.mark.platforms(...)`，在真实宿主上测 |
| 一个 marker，多 spec | 绝不叠多个 `platforms()` 装饰器 |
| **绝不**写 change-detector 测试 | 不断言精确计数、模型清单、`_config_version` |
| **绝不**在测试里读源码 | 读 `.py`/`.ts` 文本测的是源码**形状**，被明令禁止 |
| 时间测试 | 墙钟边界 ≥ 2s，事件同步 |

---

## 9. 提交与 PR

- 合并前 rebase 到 `main`（从陈旧分支 squash 会静默回退更新的修复）
- 每个修复 1–2 个不变量测试，**在基线上证明是红的**
- 依赖改动用 `hermes pm lock` 并提交 `uv.lock`

---

## 10. 症状 → 代码 速查表

| 我想…… | 去哪里 |
|---|---|
| 找某个 turn 相位的实现 | `grep -rn "def X" agent/turn_*.py` |
| 找某个状态的读写 | `grep -rn "def name" hermes_state_*.py` |
| 找网关某相位 | `grep -rn "def name" gateway/run_*.py` |
| 找 CLI 某命令 | `hermes_cli/commands.py`（`COMMAND_REGISTRY`）→ 对应 `cli_*_mixin.py` |
| 加一个工具 | [`tools/registry.py`](../tools/registry.py:1) + [`toolsets.py`](../toolsets.py:1) |
| 加一个 provider | `plugins/model-providers/<name>/` + `register_provider()` |
| 加一个平台适配器 | [`ADDING_A_PLATFORM.md`](../gateway/platforms/ADDING_A_PLATFORM.md:1) |
| 加一个 slash 命令 | [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:42) § 添加一个命令 |
| 加一个 skill | [`creating-skills.md`](../website/docs/developer-guide/creating-skills.md:1) + `skills/AGENTS.md` |
| 加一个 memory provider | `plugins/memory/<name>/`（但新 provider 应独立仓库） |
| 加一个 context engine | `plugins/context_engine/<name>/` + `context.engine` |
| 找配置项的默认值 | `hermes_cli/config_defaults.py`（或 `config.py` 的 `DEFAULT_CONFIG`） |
| 找 env var 定义 | `hermes_cli/config.py` 的 `OPTIONAL_ENV_VARS` |
| 理解某不变量 | 对应目录的 `AGENTS.md` |
| 理解某子系统 | `website/docs/developer-guide/<topic>.md` |

---

## 11. 官方长文档索引（深挖用）

| 主题 | 文档 |
|---|---|
| 架构总览 | [`architecture.md`](../website/docs/developer-guide/architecture.md:1) |
| Agent 循环 | [`agent-loop.md`](../website/docs/developer-guide/agent-loop.md:1) |
| Prompt 组装 | [`prompt-assembly.md`](../website/docs/developer-guide/prompt-assembly.md:1) |
| 压缩与缓存 | [`context-compression-and-caching.md`](../website/docs/developer-guide/context-compression-and-caching.md:1) |
| 微压实 | [`micro-compaction.md`](../website/docs/developer-guide/micro-compaction.md:1) |
| Provider 运行时 | [`provider-runtime.md`](../website/docs/developer-guide/provider-runtime.md:1) |
| 添加 provider | [`adding-providers.md`](../website/docs/developer-guide/adding-providers.md:1) |
| 工具运行时 | [`tools-runtime.md`](../website/docs/developer-guide/tools-runtime.md:1) |
| 添加工具 | [`adding-tools.md`](../website/docs/developer-guide/adding-tools.md:1) |
| 会话存储 | [`session-storage.md`](../website/docs/developer-guide/session-storage.md:1) |
| 状态库恢复 | [`state-db-recovery.md`](../website/docs/developer-guide/state-db-recovery.md:1) |
| 网关内部 | [`gateway-internals.md`](../website/docs/developer-guide/gateway-internals.md:1) |
| 网关会话生命周期 | [`gateway-session-lifecycle.md`](../website/docs/developer-guide/gateway-session-lifecycle.md:1) |
| 多路复用网关 | [`multiplexing-gateway.md`](../website/docs/developer-guide/multiplexing-gateway.md:1) |
| 添加平台 | [`adding-platform-adapters.md`](../website/docs/developer-guide/adding-platform-adapters.md:1) |
| CLI 内部 | [`cli-internals.md`](../website/docs/developer-guide/cli-internals.md:1) |
| 扩展 CLI | [`extending-the-cli.md`](../website/docs/developer-guide/extending-the-cli.md:1) |
| 插件指南 | [`plugins/index.md`](../website/docs/developer-guide/plugins/index.md:1) |
| 记忆 provider 插件 | [`memory-provider-plugin.md`](../website/docs/developer-guide/memory-provider-plugin.md:1) |
| 模型 provider 插件 | [`model-provider-plugin.md`](../website/docs/developer-guide/model-provider-plugin.md:1) |
| 上下文引擎插件 | [`context-engine-plugin.md`](../website/docs/developer-guide/context-engine-plugin.md:1) |
| 创建技能 | [`creating-skills.md`](../website/docs/developer-guide/creating-skills.md:1) |
| Cron 内部 | [`cron-internals.md`](../website/docs/developer-guide/cron-internals.md:1) |
| 子代理 API | [`subagent-lifecycle-api.md`](../website/docs/developer-guide/subagent-lifecycle-api.md:1) |
| 观察者 hooks | [`observer-hooks.md`](../website/docs/developer-guide/observer-hooks.md:1) |
| ACP 内部 | [`acp-internals.md`](../website/docs/developer-guide/acp-internals.md:1) |
| 轨迹格式 | [`trajectory-format.md`](../website/docs/developer-guide/trajectory-format.md:1) |
| PM 依赖政策 | [`pm/AGENTS.md`](../pm/AGENTS.md:1) + [`package-management.md`](../website/docs/reference/package-management.md:1) |
| 贡献者规范 | [`contributing.md`](../website/docs/developer-guide/contributing.md:1) |
| 安全范围 | [`SECURITY.md`](../SECURITY.md:1) |

---

## 12. 全目录 `AGENTS.md` 索引（就近规则）

| 目录 | 何时读 |
|---|---|
| [`agent/AGENTS.md`](../agent/AGENTS.md:1) | 改 `run_agent.py` / `agent/` |
| [`tools/AGENTS.md`](../tools/AGENTS.md:1) | 改 `tools/`、`toolsets.py`、`model_tools.py` |
| [`gateway/AGENTS.md`](../gateway/AGENTS.md:1) | 改 `gateway/` |
| [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:1) | 改 `cli.py` / `hermes_cli/` |
| [`plugins/AGENTS.md`](../plugins/AGENTS.md:1) | 改 `plugins/` |
| [`skills/AGENTS.md`](../skills/AGENTS.md:1) | 改 `skills/` / `optional-skills/` |
| [`cron/AGENTS.md`](../cron/AGENTS.md:1) | 改 `cron/` / kanban |
| [`tui_gateway/AGENTS.md`](../tui_gateway/AGENTS.md:1) | 改 `tui_gateway/` / `ui-tui/` |
| [`web/AGENTS.md`](../web/AGENTS.md:1) | 改 `web/` / `web_routers/` |
| [`apps/desktop/AGENTS.md`](../apps/desktop/AGENTS.md:1) | 改 `apps/desktop/` |
| [`tests/AGENTS.md`](../tests/AGENTS.md:1) | 写/改测试 |
| [`pm/AGENTS.md`](../pm/AGENTS.md:1) | 改依赖/`pyproject.toml` |
| [`hermes_platform/AGENTS.md`](../hermes_platform/AGENTS.md:1) | 改宿主事实/解析器 |
| [`plugin-catalog/README.md`](../plugin-catalog/README.md:1) | 插件目录准入 |

> 这些 `AGENTS.md` 会在你于对应目录工作时**自动加载**；编辑前先读它。

---

## 13. 学习收尾自检（合上文档后能回答吗）

1. 用户输入到最终响应，经过哪几个主要模块？
2. 为什么不能在会话中途改 system prompt？唯一例外是什么？
3. 工具是怎么被发现的？加一个核心工具要改哪两个文件？
4. provider 解析的优先级顺序是什么？三种 API 模式是哪些？
5. 压缩为什么是双层？两个阈值各是多少？
6. 网关的「双消息守卫」拦什么？审批类命令为什么特殊？
7. 流式交付的四条不变量分别防止什么事故？
8. 为什么 cron 的 in-flight 状态要用 `(home, job_id)` 做 key？
9. 后台委派为什么需要显式调用 `interrupt_for_session`？
10. Multiplex 下为什么 `os.environ` 是危险的？

如果这 10 个问题都能顺畅回答，你已经掌握了 Hermes 的骨架与关键细节。
