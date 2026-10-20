# 15 · 不变量、代码规范与速查总表

> **这一篇怎么读。** 前面 14 篇讲「东西是怎么跑的」，这一篇讲「改它的时候什么会咬你」。
> 它是全系列的**收口**：把散落在 15 个 `AGENTS.md`、`scripts/code_health/config.py`、
> CI workflow 和无数条事故编号里的规则，压成几张可打印的表。
>
> 建议读法：
> 1. 先读 §0 搞清楚「不变量 / 规范 / HX 编号」三个词在这个仓库里的确切含义（10 分钟）；
> 2. 再读 §2 的 HX 编号全表 —— 这是**机器会拦你**的那部分，也是唯一有权威单点定义的；
> 3. 然后 §3 按子系统刷一遍分类不变量（这是**人会在 review 里拦你**的部分）；
> 4. 真要改代码时，直接跳到 §7 的检查清单和 §8 的症状→文件表；
> 5. 睡前用 §11 的 80 道自检题收尾。
>
> **本篇相对旧版新增**（旧版 241 行，是一张摘要卡）：

| 旧版 | 新版 |
|---|---|
| HX001/002/004/005/012 的说明**全部写错**（把 HX002 写成「profile 槽位 key」、HX004 写成「作用域绑定」、HX005 写成「作用域绑定」、HX012 写成「作用域绑定」） | §2 用 `scripts/code_health/config.py` 的 `Rule(...)` 原文逐条重建，附**检测器实现**与**精确排除集** |
| 只说「HX 系列」，没说 HX006~HX011、HX013 是什么 | §2 补全 **13 条 HX + 2 条 PS**，每条含 title / fix / 检测方式 / 作用域 |
| 「`# noqa` 不豁免 ratchet」一句话带过 | §4 拆开 `# noqa` 与 `# health: allow` 的**分工**、解析器为何只认真注释、为何行号不是身份 |
| 没有 CI 全貌 | §5 给出 `scripts/check` 的**九道 guard + ruff + health** 完整清单、退出码语义、hook 如何判 staged/commit |
| 没有「ratchet」的机制解释 | §6 讲清 per-unit cap、ENFORCEMENT 主开关、WARN_UNTIL_REPLAYED、`replay.py` 的证据链 |
| 没有「怎么判断缺失是设计还是 bug」 | §9 给出一套可执行流程（`git log -p -S` + rubric + 事故号考古） |
| 10 道自检题 | §11 **84 道**，分九组，附答案要点 |

---

## 0. 前置概念：三个词

### 0.1 什么叫「不变量」（invariant）

不是说「这段代码永远不变」。而是：

> **一条约束，它成立时不产生任何输出；它被违反时，系统会出现「没有报错、但结果错」的行为。**

这个仓库里 90% 的事故都是这一类：没有 traceback，没有异常日志，只有
「B profile 的消息进了 A profile 的库」「用户配的开关永远是 no-op」「交付了一条重复的最终消息」。
所以不变量必须写下来 —— 因为**测试只能覆盖它想到的那条路径**，
而违反不变量的方式通常是「另一个兄弟模块忘了做同样的事」。

举个例子（第 14 篇的 #119242 和本篇 §3.2 的 P33 是同一个形状）：

```python
# 看起来完全正常，review 也挑不出毛病
_RECONNECT_ATTENTION_AFTER_SECONDS = _int_env("HERMES_RECONNECT_ATTENTION_AFTER", 120)
```

它违反的不变量是「**import 时不捕获 profile 相关值**」（HX005）。
后果不是崩溃，而是：multiplex 下第二个 profile 用的还是**启动 profile** 的阈值，
`hermes config set agent.reconnect_attention_after ...` 永远不生效，直到重启。
没人会报这个 bug，因为没人知道它应该生效。

### 0.2 什么叫「规范」（convention）

规范是**形状**约束，不是**行为**约束。比如：

- 「sibling 模块在函数体内 late-import facade」——这是形状；
- 「新函数 CC ≤ 20」——这是形状；
- 「if/elif 阶梯改成 dict→handler」——这是形状。

形状规则的正当性来自一个经验：**这个仓库的 bug 在特定形状下更容易发生**。
`elif` 阶梯每加一支就要重新读一遍全部分支；`Path.home()/".hermes"` 在 multiplex 下必错。
所以规范不是审美，是**把已发生过的 bug 类型固化成形状禁令**。

### 0.3 什么叫「HX 编号」

`HX001` 到 `HX013` 是**代码健康检查器（code-health ratchet）的规则 ID**，
唯一权威定义在 [`scripts/code_health/config.py`](../scripts/code_health/config.py:66) 的 `RULES` 元组里。

关键点（初学者最容易误解的三件事）：

1. **HX 编号不是「文档章节号」，是 lint 规则 ID。** 你写 `# health: allow HX001 -- 理由`，
   得有检查器能识别；`HX` 之外的规则叫 `S110`、`BLE001`、`RUF006`、`PS-P05`（ruff 规则名或
   profile-scope 模式名）。
2. **同一份 `RULES` 里混了三种来源**：`source="ruff"`（跑 pinned ruff）、`source="ast"`
   （自家 AST 检查器）、`source="regex"`（profile-scope 模式库）。它们的豁免语法**一样**。
3. **`HX` 前缀只用于「这个仓库特有、ruff 不管」的规则。** 通用 Python 问题用 ruff 原生码
   （`S110` 静默吞异常、`BLE001` 裸 `except Exception`、`ASYNC230` async 里阻塞 IO）。

> 记住这个判断法：**看到 HX 编号，去 `config.py` 查；看到四个字母+数字，去 ruff 文档查；
> 看到 `PS-P0x`，去 `scripts/ci/profile_scope_patterns.json` 查。**

---

## 1. 代码形状：规范住在哪里

### 1.1 `AGENTS.md` 体系（15 个文件，1998 行）

规范的第一现场不是本文档，是各目录的 `AGENTS.md`。它们会**在你于该目录工作时自动加载**。

| 文件 | 行数 | 覆盖 | 本文对应篇 |
|---|---|---|---|
| [`AGENTS.md`](../AGENTS.md:1) | 169 | 全局：两条铁律、facade+siblings、跨目录规则、路由表 | 01 |
| [`agent/AGENTS.md`](../agent/AGENTS.md:1) | 152 | turn 相位、消息流不变量、压缩、模型/aux 解析、i18n、记忆 | 03/04/08 |
| [`tools/AGENTS.md`](../tools/AGENTS.md:1) | 181 | registry、发现、toolset、后端、vision、surface 能力 | 05 |
| [`gateway/AGENTS.md`](../gateway/AGENTS.md:1) | 211 | 双消息守卫、流式四条约、身份、intake/delivery、profile scope | 09 |
| [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:1) | 217 | CLI mixin、slash 注册表、配置系统、skin、update、profiles | 02/10/14 |
| [`cron/AGENTS.md`](../cron/AGENTS.md:1) | 155 | 调度器不变量、job 字段、kanban 派发 | 12 |
| [`tui_gateway/AGENTS.md`](../tui_gateway/AGENTS.md:1) | 152 | 进程模型、JSON-RPC、contracts、RPC 作用域、slash 流 | 10 |
| [`plugins/AGENTS.md`](../plugins/AGENTS.md:1) | 161 | 插件种类、catalog、host 隔离、兼容契约 | 11 |
| [`apps/desktop/AGENTS.md`](../apps/desktop/AGENTS.md:1) | 171 | `serve` 后端、slash 面板、Bot Mode | 10 |
| [`tests/AGENTS.md`](../tests/AGENTS.md:1) | 154 | runner、放置、OS marker、`wine2e`、禁止的测试形状 | 本文 §3.9 |
| [`skills/AGENTS.md`](../skills/AGENTS.md:1) | 79 | frontmatter、创作标准、curator | 11 |
| [`web/AGENTS.md`](../web/AGENTS.md:1) | 45 | dashboard 嵌真 TUI | 10 |
| [`pm/AGENTS.md`](../pm/AGENTS.md:1) | 28 | 依赖钉版策略、PM 所有权 | 本文 §3.8 |
| [`hermes_platform/AGENTS.md`](../hermes_platform/AGENTS.md:1) | 14 | 机器事实、解析器 | 本文 §3.7 |
| [`apps/desktop/src/AGENTS.md`](../apps/desktop/src/AGENTS.md:1) | 109 | 渲染进程内侧：`serve` 后端契约、会话/连接状态所有权、路由根要薄 | 10 |

### 1.2 这些文件自己也被约束

[`scripts/ci/check_agents_md_size.py`](../scripts/ci/check_agents_md_size.py:1) 是 CI 的一道 blocking guard，
理由写得很清楚：

> agent 在某目录启动时，拿到的是**从 git 根到该目录的整条 `AGENTS.md` 链**，
> `agent/prompt_builder.py` 把它当成**一个** project-context 块，再按
> **context window 的 6%** 截断（128k 模型上是 30,720 字符，小模型有 20k 下限）。

于是有两个上限：

| 常量 | 值 | 管什么 |
|---|---|---|
| `ROOT_MAX_CHARS` | `12_000` | 根 `AGENTS.md` 单独上限 —— 它在**每一条链**里，必须给子文件留空间 |
| `CHAIN_MAX_CHARS` | `30_000` | `root → 任意目录` 整条链的总字节 |
| `_MAX_HINT_CHARS` | 从 `agent/subdirectory_hints.py` **读源码取值**（当前 `32_000`） | 子目录 hint 被 append 到 tool result 时的截断 |

最后一条是「两处不能漂移」的典型手法：**脚本不硬编码 32000，而是 AST 读源码常量**。
如果哪天有人改了 `_MAX_HINT_CHARS`，CI 自动跟上。

> 推论：**遇到「规范太长放不下」时的正确解法是拆文档，不是调大上限。**
> 脚本注释原话：`Shrink a file (move long form to the developer guide or a sibling doc) instead of raising any number.`

### 1.3 一张图：规则的四层

```text
                         ┌─────────────────────────────┐
                         │  第 4 层：本文档（人读）      │  ← 你现在看的
                         │  为什么、事故号、怎么探测      │
                         └──────────────┬──────────────┘
                                        │ 引用
                         ┌──────────────▼──────────────┐
                         │  第 3 层：AGENTS.md（就近读） │  ← 15 个，自动加载
                         │  该目录的形状与不变量          │
                         └──────────────┬──────────────┘
                                        │ 固化
                         ┌──────────────▼──────────────┐
                         │  第 2 层：scripts/check      │  ← 本地 = CI
                         │  九个 guard + ruff + ratchet │
                         └──────────────┬──────────────┘
                                        │ 实现
                         ┌──────────────▼──────────────┐
                         │  第 1 层：config.py RULES    │  ← 机器可执行的单点
                         │  id / title / fix / 作用域    │
                         └─────────────────────────────┘
```

**只在第 3 层（文字）而不在第 2 层（机器）的规则，靠 review 落地；
只在第 1 层的规则，靠 CI 落地。** 判断一条规则有多硬，看它在第几层。

---

## 2. HX 编号全表（机器可执行的那部分）

权威来源：[`scripts/code_health/config.py`](../scripts/code_health/config.py:66) 的 `RULES`。
下表**逐字**对应代码里的 `Rule(id, title, fix, source, exclude=..., blocking=...)`。

### 2.1 全局开关与目标值

```python
ENFORCEMENT = "blocking"      # "blocking" | "advisory" | "off"
```

- 这个开关**从 main 读，从不从被测分支读**：CI 读 merge commit 的第一父提交；
  本地读 `origin/main`（回落到 merge-base）。**所以一个 PR 没法自己放宽自己的检查。**
- 单条规则可以用 `blocking=False` 单独降级。
- `blocking=False` 之外的降级通道是 `WARN_UNTIL_REPLAYED`（见 §6.3）。

```python
TARGETS = {
    "CC": 20,            # 圈复杂度（ruff C901 口径），每函数
    "FUNC_LINES": 300,   # 每函数行数
    "NESTING": 6,        # 单函数内嵌套控制流块
    "FILE_LINES": 2000,  # 每文件行数
}
```

### 2.2 排除集：为什么有些文件不受 profile 规则管

```python
TESTS = ("tests/*", "*/tests/*", "tests-js/*", "*/conftest.py")

# 一次性的、只服务单个 profile 的进程（CI/release 脚本、作为带作用域子进程运行的 skill 脚本、
# 安装器）：profile-scope 规则不适用于它们。
SINGLE_PROFILE = TESTS + ("scripts/*", "skills/*", "optional-skills/*", "evals/*", "setup.py")
```

这段注释值得记住：**规则的作用域本身就是设计的一部分**。
`scripts/` 下的脚本是「单 profile 一次性进程」，它的 `os.environ` 就是它自己的 profile，
所以 HX002/HX004/HX005/HX012/PS-P05/PS-P06 全部对它不适用。
HX001（硬编码 home）的排除集是 `SINGLE_PROFILE + ("hermes_constants.py",)` ——
后者是**定义** `get_hermes_home()` 的地方，它当然要碰 `.hermes`。

### 2.3 HX001 —— 硬编码 Hermes home

| 项 | 内容 |
|---|---|
| **title** | hardcoded Hermes home |
| **fix** | `get_hermes_home()` for paths, `display_hermes_home()` for user-facing text (`hermes_constants`); a path that deliberately lives under the user's home, not the profile (e.g. the profiles root), takes `# health: allow HX001 -- <why>` |
| **source** | `ast` |
| **exclude** | `SINGLE_PROFILE + ("hermes_constants.py",)` |
| **blocking** | `WARN_UNTIL_REPLAYED`（默认 `False` → 只警告） |

**检测器**（[`scripts/code_health/py_rules.py:278`](../scripts/code_health/py_rules.py:278)）抓两种形状：

```python
# 形状 A：Path.home() / ".hermes"      ← BinOp(Div) 的右操作数是 ".hermes…"
# 形状 B：Path("~/.hermes/x") / os.path.expanduser("~/.hermes/x")
```

它用了 `_hermes_home_path()` 做**精确组件判定**：`.hermes/x` 命中，
`.hermes-profile-exports` **不**命中（否则每次做 profile 导出的临时目录都会被误报）。
这是「grep 字符串 ≠ 判断路径组件」的正确写法。

**为什么是 HX001 而不是别的编号**：路径错位是这个仓库最古老、最普遍的一类 bug。
`~/.hermes/logs` 在 multiplex 下会变成「所有 profile 写同一个日志文件」。

**例外必须写理由**：`_get_profiles_root()` 是**故意** HOME-anchored 的
（profiles 根目录是所有 profile 的父目录，不是某个 profile 的 home）。
所以它写 `# health: allow HX001 -- ...`。

### 2.4 HX002 —— 新增 `HERMES_*` 环境变量

| 项 | 内容 |
|---|---|
| **title** | new `HERMES_*` environment variable |
| **fix** | behavioural settings go in `config.yaml`, secrets through the secret scope; `.env` is for credentials only |
| **source** | `ast` |
| **exclude** | `SINGLE_PROFILE` |

**这一条是本仓库最容易被违反、也最容易理解错的一条。** 它**不**是「profile 槽位 key」，
而是「**别再新增一个 `HERMES_*` 环境变量**」。

检测器（`py_rules.py:297`）的注释是关键：

```python
# Setting a variable introduces it as surely as reading one does.
for node in ast.walk(tree):
    read = _env_read_name(node)
    names = [read] if read else _env_write_names(node)
    if any(n.startswith("HERMES_") and n not in ctx.known_env for n in names):
        yield getattr(node, "lineno", 0)
```

- **写和读都算**：`os.environ["HERMES_FOO"] = ...` 一样被拦。
- **`ctx.known_env` 是基线**：由 `gitio.known_env_names(repo, base)` 从**基线 revision**
  扫出所有已存在的 `HERMES_*` 字面量。所以**历史遗留的能继续用，新增的不行**。

**正确的替代路径**（来自 fix 文本，三条）：

| 你想加的东西 | 正确位置 |
|---|---|
| 超时、阈值、开关、显示偏好 | `config.yaml`（`DEFAULT_CONFIG` 新键，见 §3.5） |
| 密钥、token、密码 | `.env` → `OPTIONAL_ENV_VARS` → 通过 secret scope 读 |
| 内部机制确实需要 env 镜像 | **在代码里 bridge**（`gateway_timeout`；`terminal.cwd` → `TERMINAL_CWD`），不要求用户设 |

根 `AGENTS.md` 的措辞是 `behaviour goes in config.yaml`，`.env` 是 secrets only。
rubric 里明确列为「rejected even when well-built」的第一条：

> **New `HERMES_*` env vars for non-secret config.** Reject "set X in your .env" docs unless X is a credential.

### 2.5 HX003 —— 用 argv 子串判断进程身份

| 项 | 内容 |
|---|---|
| **title** | process identity from argv substrings |
| **fix** | use `gateway.status.looks_like_gateway_command_line` / `hermes_cli.update_cmd._hermes_holder_subcommand` and match full cmdlines |
| **source** | `ast` |
| **blocking** | `WARN_UNTIL_REPLAYED` |

**检测器抓三类**（`py_rules.py:306`）：

```python
_SHELL_IDENTITY = ("pgrep -f", "ps aux", "ps -ef", "ps -eo")

# 1) `"xxx" in cmdline` / `"xxx" not in cmdline`  ← 字符串常量与含 cmdline 的表达式的 Compare
# 2) 任何**非 docstring**的字符串常量里出现 pgrep -f / ps aux / ps -ef / ps -eo
#    （即：你在拼接 shell 命令去查进程）
# 3) docstring/裸字符串表达式被排除 —— 散文描述这个模式不算违规
```

第 3 点是精细度：`py_rules.py` 自己第 37 行就有
`# health: allow HX003 -- the detector's own pattern list`，
所以检测器自己的 `_SHELL_IDENTITY` 元组是**数据**而非「命令」，不会被自己咬。

**为什么这是硬规则**：`kanban --preserve-cache` 里含子串 `"serve"`。
用 `"serve" in cmdline` 判断「这是不是一个 serve 进程」，会把 kanban 进程判成 serve，
然后杀掉它 / 给它发信号 / 认为它在服务某个 profile。

**正确做法**（三个权威入口）：

| 场景 | 用它 |
|---|---|
| 「这条命令行是不是 gateway？」 | `gateway.status.looks_like_gateway_command_line` |
| 「这个进程是不是某个 hermes 子命令的持有者？」 | `hermes_cli.update_cmd._hermes_holder_subcommand` |
| 「这个 pid 还活着吗（且不是复用）」 | `(pid, start_time)` 或 `gateway.status.live_gateway_pid_for_home` |

### 2.6 HX004 —— `UnscopedSecretError` 兜底到 `os.getenv`

| 项 | 内容 |
|---|---|
| **title** | `UnscopedSecretError` falls back to `os.getenv` |
| **fix** | bind the owning profile's secret scope at the spawn site; never read the launch profile's environment |
| **source** | `ast` |
| **exclude** | `SINGLE_PROFILE` |

检测器（`py_rules.py:323`）非常具体：

```python
if not isinstance(node, ast.ExceptHandler) or node.type is None:
    continue
if "UnscopedSecretError" not in ast.unparse(node.type):
    continue
for stmt in node.body:                     # except 体内任一环境变量读取 → 命中
    if any(_env_read_name(inner) for inner in ast.walk(stmt)):
        yield node.lineno
        break
```

**这是本仓库最典型的「看起来防御性很好、实际是漏洞」的写法**：

```python
# ❌ 检测器抓的就是这个形状
try:
    token = get_secret("DISCORD_BOT_TOKEN")
except UnscopedSecretError:
    token = os.getenv("DISCORD_BOT_TOKEN")     # ← 拿到的是启动 profile 的 token
```

为什么危险：`get_secret` 抛 `UnscopedSecretError` 的意思是
「**当前没有绑定任何 profile 的 secret scope，而进程处于 multiplex 状态**」。
这时候 `os.environ` 里装的是**启动 profile（default）** 的值。
兜底到 `os.getenv` 等于「拿不到本 profile 的凭证，那就用 default 的」——
在共享 bot 场景下就是**把 A 的身份发给 B 的用户**。

`gateway/AGENTS.md` 对这条有更长的措辞：

> Never re-implement the reader in an adapter (the `try get_secret / except UnscopedSecretError: os.getenv`
> shape drifts into a fallback-after-miss leak); import the shared one.

**正确做法**：在**spawn site**（构造子进程/构造适配器/进入回调）先绑好 owning profile 的 scope，
再读。子进程里拿到 `UnscopedSecretError` 是**spawn site 的 bug**，
绝不是「回退到 `os.getenv`」的理由（`agent/AGENTS.md` 原话）。

### 2.7 HX005 —— import 时捕获 home / config / env

| 项 | 内容 |
|---|---|
| **title** | home/config/env captured at import time |
| **fix** | resolve it at call time (`get_hermes_home()`, `load_config()`) or key the slot by `hermes_home_key()`; module constants hold the launch profile's value |
| **source** | `ast` |
| **exclude** | `SINGLE_PROFILE` |

检测器（`py_rules.py:442`）用 `_is_capture()` 判定「这是一个捕获表达式」：

```python
_CAPTURE_CALLS = {
    "get_hermes_home", "display_hermes_home",
    "load_config", "load_config_readonly", "read_raw_config",
    "get_secret", "getcwd", "expanduser",
    "_float_env", "_int_env", "_bool_env", ...
}
# 另外 Path.home 也算
```

然后看它是否出现在**模块级赋值**（或 class body 等 import 时求值的位置）。

**fix 给了两条合法出路**：

1. **调用时解析**：`get_hermes_home()` 每次调用都重新算（第 14 篇 §2.1）。
2. **按 `hermes_home_key()` 给槽位做 key**：允许缓存，但缓存必须按 home 分桶
   （第 14 篇 §4 的 `_HOME_KEY_CACHE` 就是这个形状）。

**判断口诀**：模块常量只能持有「**与 profile 无关**」的值。
任何 `HERMES_HOME`、任何 `config.yaml` 内容、任何 `.env` 值，都是 per-profile。

这一条和 PS-P33（§2.15）是同族但**不等价**：HX005 抓的是 `ast` 层面的
「模块级赋值里有捕获调用」；P33 是 `path_regex` 限定的
「`gateway|hermes_cli|agent|tools|cron|tui_gateway` 下的 `CONST = _float_env("HERMES_*")`」
正则模式，用来在 review 时给具体建议。两者会重叠——这是有意的，**重叠不会漏报**。

### 2.8 HX006 —— 子进程 / urlopen 没有 timeout

| 项 | 内容 |
|---|---|
| **title** | subprocess/urlopen without timeout |
| **fix** | pass `timeout=`; an asyncio `proc.communicate()` goes inside `asyncio.wait_for(..., timeout=...)` (a child or socket that never answers hangs forever); after `proc.kill()` reap with `proc.wait()`, never a bare `communicate()` (it blocks while a grandchild holds the pipe) |
| **source** | `ast` |
| **exclude** | `TESTS`（默认） |
| **blocking** | `True` |

这是**命中次数最多**的规则（28 处 `# health: allow HX006` 豁免）。
fix 文本里藏了两个独立的坑：

1. **`proc.kill()` 之后不能用裸 `communicate()`**：孙进程还握着管道时，`communicate()` 会一直阻塞。
   正确顺序是 `proc.kill()` → `proc.wait()`。
2. **asyncio 下的 `communicate()` 必须被 `asyncio.wait_for` 包住**：`proc.wait()` 是协程，
   没有 timeout 就永远等。

真实豁免例子（说明「什么时候可以 allow」）：

```python
# hermes_cli/_old_updater.py:158
# health: allow HX006 -- unbounded by design: the update's own supervised child
```

即：**这个子进程的持续时间就是更新的持续时间，给它加 timeout 是错的**。
这种豁免必须写清「为什么这里没有公平的上界」，否则 reviewer 会拒。

### 2.9 HX007 —— async def 里做同步 config I/O

| 项 | 内容 |
|---|---|
| **title** | sync config I/O inside async def |
| **fix** | `await asyncio.to_thread(load_config)` or read it before entering the event loop |
| **source** | `ast` |
| **blocking** | `True` |

`load_config()` 会读文件、解析 YAML、做 deepcopy（第 07 篇：cache 命中 265µs）。
在 event loop 里同步做这件事，会阻塞**整个 gateway 的所有协程**——包括所有平台的收消息、
心跳、ticker。

注意 ruff 里有一条同族但不完全覆盖的规则：
`ASYNC230`（async def 里 `open()`）、`ASYNC240`（async def 里阻塞 PH 调用）。
HX007 补的是 **config 专用**的那条。

### 2.10 HX008 —— `asyncio.get_event_loop()`

| 项 | 内容 |
|---|---|
| **title** | `asyncio.get_event_loop()` |
| **fix** | `asyncio.get_running_loop()` inside a coroutine; `asyncio.run()` at an entry point |
| **source** | `ast` |
| **blocking** | `True` |

`get_event_loop()` 在没有运行 loop 时（Python 3.12+）会 DeprecationWarning 甚至抛错；
在**有** loop 的线程里它返回当前 loop；在**另一个线程**里它会创建一个新 loop ——
然后你 `run_until_complete` 一个属于别的 loop 的 future 就死锁。

`get_running_loop()` 只能从协程内调用，语义精确：**「我确定我正在一个 loop 里」**。

### 2.11 HX009 —— `isinstance(r, Exception)` 检查 gather 结果

| 项 | 内容 |
|---|---|
| **title** | `isinstance(r, Exception)` on gather results |
| **fix** | check `BaseException`: `gather(return_exceptions=True)` also returns `CancelledError` |
| **source** | `ast` |
| **blocking** | `True` |

```python
results = await asyncio.gather(*tasks, return_exceptions=True)
for r in results:
    if isinstance(r, Exception):      # ❌ CancelledError 是 BaseException，漏掉
        ...
```

`asyncio.CancelledError` 在 Python 3.8+ 继承自 `BaseException` 而非 `Exception`。
漏掉它的后果：**取消被当成正常结果**，然后你把 `CancelledError` 对象当成 payload 用，
或者 `await` 一个已被取消的协程，或者把取消吞掉导致 shutdown 挂住。

### 2.12 HX010 —— `bool()` 包一个 config/env 字符串

| 项 | 内容 |
|---|---|
| **title** | `bool()` of a config/env string |
| **fix** | `bool("false")` is True. Is it set? `os.getenv("X") is not None` (or `!= ""` to treat empty as unset). A boolean flag? `is_truthy_value(...)`, which is False for any non-flag string such as a key |
| **source** | `ast` |
| **blocking** | `WARN_UNTIL_REPLAYED` |

这条 fix 文本是本仓库最精炼的一段规范散文，值得整段背下来。它区分了**三种不同的问题**：

| 你真正想问的 | 正确写法 | 为什么 |
|---|---|---|
| 「这个变量**设置了**吗？」 | `os.getenv("X") is not None` | `bool("")` 是 False，但「设置为空」和「没设置」不同 |
| 「空字符串算没设置吗？」 | `os.getenv("X") != ""` | 有些约定用空值表示关闭 |
| 「这个 flag **为真**吗？」 | `is_truthy_value(...)` | 见下 |

[`utils.py:25`](../utils.py:25)：

```python
TRUTHY_STRINGS = frozenset({"1", "true", "yes", "on"})

def is_truthy_value(value: Any, default: bool = False) -> bool:
    """Coerce bool-ish values using the project's shared truthy string set."""
    if value is None:
        return default
    if isinstance(value, str):
        return value.strip().lower() in TRUTHY_STRINGS
    return bool(value)
```

fix 文本里那句 `which is False for any non-flag string such as a key` 是重点：
**如果有人把一个 API key 误填进一个布尔配置位，`is_truthy_value` 会返回 False**
（因为 key 不在 truthy 集合里），而 `bool(key)` 会返回 True。
这就是为什么不能对「可能是任意字符串」的值用 `bool()`。

### 2.13 HX011 —— 对同一个名字写 if/elif 阶梯

| 项 | 内容 |
|---|---|
| **title** | if/elif ladder on one name |
| **fix** | use a dict/table → handler (`_SLASH_DISPATCH` is the shape) |
| **source** | `ast` |
| **exclude** | `()`（**不排除 tests**） |
| **blocking** | `True` |

这是本仓库唯一的「纯形状」规则，也是最彻底执行的：**连测试文件都不排除**。
（`tests/scripts/test_code_health_rules.py:267` 有个注释说
`` `>` keeps the fixtures off HX011 (an if/elif ladder on one name) `` ——
测试 fixture 都要绕开它，可见执行得多严。）

**为什么**：`elif` 阶梯有一个数学性质——加第 N 支时，你必须重新理解前 N-1 支的**顺序依赖**。
而 dict→handler 表的顺序是不重要的（或者显式排序的），加一支只需加一行。

**标准形状**（来自 `hermes_cli/AGENTS.md`）：

```python
# ✅ hermes_cli/cli.py 的 _SLASH_DISPATCH
_SLASH_DISPATCH = {
    "model":   ("_handle_model_command", True),
    "skills":  ("_handle_skills_command", True),
    ...
}
# process_command(): resolve_command() → 查表 → 拿到 (method_name, pass_arg)

# ✅ gateway 的 _command_handler_table：按名字查 handler
# ✅ cli.py 的 naming convention fallback：_handle_<name>_command
```

**唯一合法的 if 链**：`hermes_cli/AGENTS.md` 原话
`**There is no `elif` ladder — do not add one.**`

**边界**：HX011 抓的是「**对同一个名字**」的阶梯（`ctx.else` 里比较的还是同一个 `x`）。
对不同变量的连续 `if` 不算。所以它是有精确范围的形状检查，不是「禁止 if」。

### 2.14 HX012 —— 裸 `threading.Thread`

| 项 | 内容 |
|---|---|
| **title** | raw `threading.Thread` |
| **fix** | `spawn_context_thread(...)` so the thread keeps the caller's profile scope (ContextVars do not cross a bare `Thread`) |
| **source** | `ast` |
| **exclude** | `SINGLE_PROFILE` |
| **blocking** | `WARN_UNTIL_REPLAYED` |

**这是本仓库最重要的并发规则**，因为它是「三层隔离」里**唯一会静默失效**的一层
（第 14 篇 §0.3）。

`contextvars` 的语义：协程之间会继承（`asyncio.create_task` 复制当前 context），
但**裸 `threading.Thread` 不会**。它拿到的是**空 context**，也就是所有 ContextVar 的默认值：

```python
_SECRET_SCOPE: ContextVar[...] = ContextVar(...)   # default=None
_terminal_scope_var: ContextVar[...] = ContextVar(...)  # default=None
```

于是后台线程里读 `get_secret()` → scope 是 `None` → multiplex 下抛 `UnscopedSecretError`
（还好，fail closed）；读 terminal scope → `None` → 用**默认 backend**
（不好，语义错了但没报错）。

**正确写法**（[`agent/memory_provider.py:29`](../agent/memory_provider.py:29)）：

```python
def ctx_bound(fn):
    ctx = contextvars.copy_context()
    return lambda *args, **kwargs: ctx.run(fn, *args, **kwargs)

def spawn_context_thread(target, *, name, daemon=True, args=(), kwargs=None) -> threading.Thread:
    """Unstarted thread running *target* under the spawner's contextvars (see :func:`ctx_bound`).
    Every memory-provider background job (prefetch, sync, writer loops) must go through this."""
    return threading.Thread(target=ctx_bound(target), args=args, kwargs=kwargs,
                            name=name, daemon=daemon)
```

注意两个细节：

1. **`copy_context()` 是快照** —— 在 spawn 那一刻复制。之后 spawner 改 context，
   thread 看不到（这是正确的：thread 应该持有「我出生时的身份」）。
2. **返回的是未启动的 Thread** —— 调用方自己 `.start()`，保持「构造与启动分离」的常规语义。

### 2.15 PS-P05 / PS-P06 / P33 —— profile-scope 正则模式

这三条不在 `RULES` 的 HX 家族里，但同一张表：

| id | title | fix | source |
|---|---|---|---|
| `PS-P05` | child env built from `os.environ` | `served_profile_child_env()`; the child otherwise inherits the launch profile's home and secrets | regex（`pattern_id="P05"`） |
| `PS-P06` | raw platform credential getenv | read it through the profile's secret scope (`get_secret`) | regex（`pattern_id="P06"`） |

它们的正则在 [`scripts/ci/profile_scope_patterns.json`](../scripts/ci/profile_scope_patterns.json)。
P05 的实际正则（可读版）：

```text
subprocess.(Popen|run|check_output)\([^)]*env\s*=\s*(os.environ|dict(os.environ)|\{\*\*os.environ})
| env\s*=\s*os.environ\.copy\(\)
| spawn\([^)]*env:\s*process\.env
| env\s*=\s*dict\(os\.environ\)
| \{\*\*os\.environ\}
```

**这份 JSON 是本仓库最有价值的一份「事故分类学」**，值得单独读一遍。
它的 `meta` 里有 13 个 class（C1~C13）：

| class | 含义 |
|---|---|
| C1 | secret/home 在 turn scope 之外被读 |
| C2 | 子进程 env 从 `os.environ` 构造 |
| C3 | 侧工作者 / 次级入口只绑了 home |
| C4 | 引入了 per-profile key，消费者却读原始 name/id |
| C5 | adapter 配置优先级 + 裸 `os.getenv` 回退 |
| C6 | 启动 profile / 保留名的不对称 |
| C7 | 用裸 PID 或 argv 子串判进程身份 |
| C8 | 配置键注册表 vs 运行时读取者 |
| C9 | systemd/launchd unit 变体 + 迁移事务性 |
| C10 | 活着的 multiplexer 下做 profile 生命周期操作 |
| C11 | 裸线程生命周期 / 监督 |
| C12 | Desktop 拓扑 / 表面等价（CLI vs REST vs RPC） |
| C13 | kanban notifier 路由 / 静默 fail-closed |

而 `patterns[]` 里的每条都带 `why`（真实事故）：

```json
{
  "id": "P05", "class": "C2",
  "why": "Children inherit the launch process's HERMES_HOME and secrets: MCP stdio servers got the
          default vault, WhatsApp bridge.js ran the default's dm_policy, brv curated into the
          default's cloud account, execute_code skill scripts read the default's OAuth tokens.
          Four spawn sites fixed one at a time."
}
```

**「四个 spawn site 一个一个修」**这半句是全表的精华：同一个 bug 类型在仓库里有 N 个实例，
修一个不等于修完。这就是为什么规则要写成「形状禁令 + 检查器」，而不是「记一个教训」。

另外 P33 是**唯一一条不靠 `check_profile_scope_patterns.py` 的**——
它写在 JSON 里作为 review grep，因为它命中点太多（>50）：
`>50 ones are review greps, not lint`（`meta.selection`）。

### 2.16 速查：13 条 HX 一句话版

| id | 一句话 | 检测 | 默认阻断 |
|---|---|---|---|
| HX001 | 别硬编码 `~/.hermes`，路径用 `get_hermes_home()`，文本用 `display_hermes_home()` | ast | 否 |
| HX002 | 别新增 `HERMES_*` 环境变量（行为进 `config.yaml`，密钥进 secret scope） | ast | 是 |
| HX003 | 别用 argv 子串判进程身份 | ast | 否 |
| HX004 | `except UnscopedSecretError` 里绝不回退 `os.getenv` | ast | 是 |
| HX005 | import 时不捕获 home/config/env | ast | 是 |
| HX006 | 子进程 / urlopen 必须有 timeout；kill 后用 `wait()` 不用 `communicate()` | ast | 是 |
| HX007 | async def 里不做同步 config I/O | ast | 是 |
| HX008 | 用 `get_running_loop()` / `asyncio.run()`，不用 `get_event_loop()` | ast | 是 |
| HX009 | gather 结果用 `BaseException` 判，不是 `Exception` | ast | 是 |
| HX010 | 别 `bool()` 一个可能是 `"false"` 的字符串；用 `is_truthy_value` | ast | 否 |
| HX011 | 同一名字的 if/elif 阶梯改成 dict→handler | ast | 是 |
| HX012 | 别裸 `threading.Thread`，用 `spawn_context_thread` | ast | 否 |
| HX013 | 测试里别用墙钟 `sleep`，用 Event / `wait_until` | ast（仅 tests） | 是 |
| PS-P05 | 子进程 env 用 `served_profile_child_env()` | regex | 否 |
| PS-P06 | 平台凭证走 `get_secret`，不裸 `os.getenv` | regex | 否 |

### 2.17 HX013 —— 测试里的墙钟 sleep

| 项 | 内容 |
|---|---|
| **title** | wall-clock sleep in a test |
| **fix** | wait for the condition, not the clock: an Event the code under test sets (`threading.Event` / `asyncio.Event`, `.wait(timeout=)`), or poll with `tests.waiting.wait_until(predicate, timeout=...)` (`async_wait_until` in a coroutine; a poll loop's interval under a deadline or a `range(n)` bound passes); a stand-in that must hang blocks on an Event the test sets at teardown. `sleep(0)` to yield is fine. A delay that IS the behaviour under test takes `# health: allow HX013 -- <why>` |
| **source** | `ast` |
| **include** | `TESTS`（**只有**测试文件受管） |
| **blocking** | `True` |

fix 文本里区分了 **5 种情况**，这是全表最细的一条：

| 情况 | 判定 |
|---|---|
| `sleep(0)` 让出 CPU | ✅ 允许 |
| 等代码设置 Event（`threading.Event` / `asyncio.Event` + `.wait(timeout=)`） | ✅ 推荐 |
| 轮询 + `tests.waiting.wait_until(predicate, timeout=)` | ✅ 推荐 |
| 轮询 + 「在 deadline 下的 interval」或 `range(n)` 上界 | ✅ 允许（有界） |
| **延迟就是被测行为本身** | ✅ 但必须 `# health: allow HX013 -- why` |
| **固定非零 sleep 等异步效果** | ❌ 阻断 |

同时 `wait` 的工具已经内置（[`tests/waiting.py:1`](../tests/waiting.py:1)）：

```python
"""Wait for a condition instead of the clock (the HX013 fix)."""
def wait_until(predicate, timeout=DEFAULT_TIMEOUT, ...) -> T: ...
async def async_wait_until(predicate, timeout=DEFAULT_TIMEOUT, ...) -> T: ...
```

**为什么这条是 blocking 而不是 warn**：`tests/AGENTS.md` 说明了机制——
CI 的 flake policy 会重试失败的**文件**一次，重试通过的会打 `⚠ FLAKY`。
固定 sleep 是 flake 的头号来源；而 flake 会让「retry 通过」变成常态，
**掩盖真实 bug**。

### 2.18 事故号考古：规则背后的真实故障

下表把本篇出现的事故号与规则对上。**事故号不是装饰，是「这条规则为什么存在」的证据。**

| 事故号 | 规则 | 一句话 |
|---|---|---|
| #92554 | config writer guard | 每个新 writer 又用了 plain dumper，把用户注释清空，反复回归 |
| #94590 | HX001 / profile 枚举 | 枚举是纯读；从 served path 里 `mkdir` 会复活已删除的 profile |
| #107485 | cron 不变量 | 静默丢 slot |
| #107695 | 子进程 env | `launch_dotenv_keys()` 是第四个残渣来源 |
| #108935 | P11 | 36 个 cache 加了 key，仍漏掉 `browser_exec` / `computer_use` |
| #109954 | multiplex 迁移 | `gateway.auto_multiplex_migration` 是 opt-out |
| #110637 | 重启 | 停下再前台跑会盖上 CLI 的 PID，卡死每次 KeepAlive 重启 |
| #111151 | `check_fn` 缓存 | 缓存必须按 `(fn, scope)` |
| #111187 | secret scope | 管理员 managed `.env` 必须最后叠加且 override |
| #111866 | OS marker guard | 伪造 macOS 的测试对 macOS lane 不可见 |
| #112878 | standalone launch scope | 单 profile 也能有 scope |
| #113270 | 子进程 env | `strip_profile_gate_env` |
| #113471 | clone | NTFS junction |
| #114587 | kanban | 终端 provider 退出码 78 首轮即 sticky 阻断 |
| #114909 | TUI | Desktop 重连重置 UI session id，子代理仍在跑 |
| #115635 | P33 | import 时捕获 bridge 的 env，配置改了不生效 |
| #119242 | 三种 home | 宿主镜像 `HERMES_HOME` 的钉住语义 |
| #120116 | api_server 记忆 | 上一轮排队的 recall 到不了下一轮 |
| #122222 | cron worker boot | 源更新重启后必须重放整个 worker |
| #2796/#2810 | pm 钉版 | litellm 供应链投毒 |
| #9801 | pm 钉版 | SHA 钉版 + audit CI |
| #64611 | context files | 绝不把安装树的 `AGENTS.md` 当项目上下文 |
| #79733 | aux 调用 | aux 调用不得触发 turn 级 `pre/post_api_request` |
| #85265 / #92091 | gateway 生命周期 | 别「修」gateway 随 app 死；别扩大 tree-kill |
| #86905 / #72348 | scope fail-closed | 泄漏的 allowlist 会静默拒掉所有二级 profile 的发送者 |

> 读法：**事故号让你能 `git log --grep` 找到原始 PR，看到真实的复现和修复。**
> 这是本仓库最重要的知识获取方式之一（§9 会给完整流程）。

---

## 3. 分类不变量（人会在 review 里拦你的部分）

下面按子系统组织。每条都写成「**约束 × 违反后的样子 × 权威出处**」。
`AGENTS.md` 里有的，标注行号；本文前面篇目有的，标注篇号。

### 3.1 A 类：两条根铁律

| # | 铁律 | 推论 | 出处 |
|---|---|---|---|
| 1 | **逐会话 prompt caching 神圣** | 绝不中途改历史 / 切 toolset / 重载记忆 / 重建 system prompt；**唯一例外是压缩**；注入只能走 user 消息或 tool 结果 | [`AGENTS.md`](../AGENTS.md:1) 开头、[`agent/AGENTS.md`](../agent/AGENTS.md:55) |
| 2 | **核心是窄腰，能力长在边缘** | 新能力按 Footprint Ladder，最后才考虑新核心工具 | [`contributing.md`](../website/docs/developer-guide/contributing.md:119) |

**铁律 1 的完整例外清单**（只有这些）：

| 允许做什么 | 为什么不算破坏 |
|---|---|
| 压缩（compression） | 它是**唯一**被批准的上下文变更 |
| 追加新的 user 消息 / tool 结果 | 前缀没变，缓存前缀仍命中 |
| `/steer` 作为独立 user 行插在 tool 结果之后 | `assistant(tool_calls) → tool → user` 在所有 provider 路径上合法 |
| skill slash 命令以 user 消息注入 | 不碰 system prompt |
| 一次性 note（如 `<available_skills>` 差异） | 只在差异变化时发一次 |

**铁律 1 最常见的违规形态**：想「顺手更新一下 system prompt」。
比如「用户刚装了新 skill，把 skill 列表刷进 system prompt」——这会让**整个会话的缓存前缀作废**，
成本从「1x」变成「全量重算」。正确做法是发一条一次性 user note，或者等下个会话。

### 3.2 B 类：Agent / 消息流

| 不变量 | 细节 | 违反后 |
|---|---|---|
| system prompt 逐字节稳定 | 只构建一次；只有压缩触发重建 | 缓存前缀失效，成本暴涨 |
| 严格角色交替 | 绝不两个同角色连排；**唯一例外 `/steer`** | 部分 provider 直接 400 |
| 唯一上下文变更是压缩 | 其它注入走 user 消息 / tool 结果 / 一次性 note | 同上 |
| context files 只从 CWD 启动时加载 | 有上限；**绝不**加载安装树的 `AGENTS.md`（#64611）；子目录提示拒绝工作目录外路径 | 用户的 `~/.codex/AGENTS.md` 混进来 |
| `_last_resolved_tool_names` 是**进程全局** | 子代理运行期间可能陈旧（`_run_single_child` save/restore） | 子代理的工具集串到父代理 |
| skill slash 命令以 user 消息注入 | 绝不进 system prompt | 缓存破坏 |
| `<available_skills>` 差异走一次性 note | 只在差异变化时发送 | 每轮都发，浪费 token |
| **Agent 级工具走 `INLINE_TOOL_EXECUTORS`** | `todo` / `memory`，**绕过** `handle_function_call()` | 加一支 `if name == ...` 就是 HX011 |
| 子目录 hint 的截断**不进 chat status** | head+tail 截断超 `_MAX_HINT_CHARS = 32_000`；截断要**记日志**，不排队成 chat 状态警告 | 用户在 UI 里看到假警告 |
| Cron 交付在自己会话里 | 为了保持角色交替 | 同 3.2 第 2 行 |

**关于「为什么 `/steer` 是唯一例外」**，`agent/AGENTS.md` 给的解释值得抄下来：

> `assistant(tool_calls) → tool → user` is legal on every provider path —
> never smeared onto the already-persisted tool row, which append-only persistence would
> leave divergent from the live request.

即：**不能把 steer 内容拼到那行 tool 结果上**，因为持久化是 append-only 的，
拼上去之后「磁盘上的历史」和「实际发出的请求」就不一致了。

### 3.3 C 类：工具系统

| 不变量 | 细节 | 出处 |
|---|---|---|
| 自注册在 import 时 | 顶层 `registry.register()` 被 AST 发现；无需手工 import 列表 | [`tools/AGENTS.md`](../tools/AGENTS.md:9) |
| 整包形式的工具只扫 `tools/<pkg>/tool.py` | 包内其它 sibling 天生是库；包必须有 `__init__.py`，否则 discover 跳过并 warning | 同上 |
| handler 返回 **JSON 字符串** | 唯一例外是多模态信封 `{"_multimodal": True, "content": [text, image_url…], "text_summary": str}`，由 `registry._normalize_handler_result` 精确接受 | 同上 |
| 多模态的图片路径走 `vision_tools._native_tool_result_images` | 绝不自己写私有 vision 检查 | 同上 |
| `check_fn` 回答**可达性 / opt-in** | **绝不**回答「什么界面」；结果按 `hermes_home_key()` TTL 缓存 | [`tools/AGENTS.md`](../tools/AGENTS.md:55) |
| `check_fn` 探针用 `get_secret` | 绝不裸 `os.getenv`（那会给所有人启动 profile 的 `.env`） | 同上 |
| registry 在 catch site 用 `current_secret_scope()` 分类 `UnscopedSecretError` | boot 时无 scope 的探针记 **DEBUG**，不是 traceback | 同上（#111151） |
| schema 描述**不点名**其它 toolset 的工具 | 交叉引用在 `get_tool_definitions()` 动态加 | [`tools/AGENTS.md`](../tools/AGENTS.md:45) |
| schema 描述里的路径用 `display_hermes_home()` | schema 在 import 时构建 → multiplex 下显示 launch home（仅展示用） | 同上 |
| 状态文件用 `get_hermes_home()`（**调用时**） | 绝不 `Path.home()/.hermes`，绝不模块常量 | 同上 |
| 教学类工具**无** `offset`/`limit` | 模型只读第 1 页就跳过剩下 | 同上（也是 rubric 的一条） |
| GUI 专属工具进**命名 toolset** | `desktop_ui` / `project`，由 `_load_enabled_toolsets(platform)` 折入 | 同上 |
| 加后端 = 新 sibling 或 provider 表条目 | **绝不** `elif` 判断后端名 | [`tools/AGENTS.md`](../tools/AGENTS.md:86) |
| 远端后端的文件可见性问题在 **mount** 修 | 不是加一个工具 | 同上 |
| 新工具要接既有 setup UX | `hermes tools` / `hermes setup` / auto-install；secrets 进 `OPTIONAL_ENV_VARS` | [`tools/AGENTS.md`](../tools/AGENTS.md:67) |

**「表面能力是 SESSION 的属性，不是进程 env」** 这句话值得单独记：

> `HERMES_DESKTOP=1` ≠ GUI 在看。

它只表示「这个进程是 app 拉起来的」。谁在看屏幕是**会话**的属性，
要走命名 toolset + `_load_enabled_toolsets(platform)`。
用 `check_fn` 回答这个问题会**缓存错**（因为 `check_fn` 是按 home 缓存的进程级结果）。

### 3.4 D 类：网关

| 不变量 | 细节 |
|---|---|
| **双消息守卫** | ① base adapter 在 `_pending_messages` 排队（`session_key in _active_sessions`）② runner 在到达 `running_agent.interrupt()` 前拦截 `/stop /new /queue /status /approve /deny` |
| 审批类命令必须**绕过两者并内联派发** | 绝不走 `_process_message_background()`，它和 session 生命周期赛跑 |
| **流式四条**（见下） | 每条都来自一次真实的重复最终消息事故 |
| 每事件**一个**身份，先规范化 | `session_identity.resolve_identity`；在它之前不派生 key |
| 未解析身份（路由到未服务 profile）**丢一次 WARNING** | 绝不 key 进 `agent:main` |
| 接收适配器 ≠ 交付适配器 | `_intake_adapter_for` / `_delivery_adapter_for`；**绝不读 `self.adapters[platform]`**；绝不加第三个 resolver |
| 身份要能**跨进程存活** | `SessionEntry.transport_profile` 持久化接收 bot；namespace 说「在哪跑」，列说「谁可交付」 |
| token lock | 唯一凭证的 adapter 在 `connect()`/`start()` 取 `acquire_scoped_lock()`，在 `disconnect()`/`stop()` 释放 |
| multiplex 下 env 读取 **fail closed** | scope 已装 + multiplex 激活 → scoped miss 返回 **default**，绝不 `os.environ`（#86905） |
| 平台读取器**只有一份** | `gateway.platforms._shared.get_scoped_secret`；adapter 里绝不重实现（就是 HX004 那个形状） |
| 作用域按 **profile 活动**绑，不按 turn | turn、回调、驱逐、tick、shutdown、交付，全部要绑 |
| `multiplex_profiles: false` ≠「永远没有 scope」 | 原生 hosted room 会在 gateway 进程内翻进程级 guard；单 profile 走 `_standalone_launch_scope`（#112878） |
| 钩子 / observer 按 **served profile** 注册 | 幂等键含 profile；`hooks/` 路径调用时解析 |
| adapter YAML **绝不**进 `os.environ` | `apply_yaml_bridge` 只 seed `PlatformConfig.extra`；闸门读走 `platform_gate_env` |
| 未服务要报告，不静默 | `_note_unserved_secondary_platform`，一次 WARNING + runtime status |
| `serve` 随 app 死；`gateway run` 独立存活 | **别「修」这两个**（#85265 / #92091） |
| 一个 launch-home 身份 | 比较 `get_routing_process_hermes_home()`，绝不活读 `os.environ["HERMES_HOME"]` |

**流式四条**（`gateway/AGENTS.md:30`，来自 NS-658 canary ledger / #85796 / gateway-gateway#210）：

| # | 不变量 | 违反后的现象 |
|---|---|---|
| 1 | **草稿帧前缀稳定**：第 N 帧必须是第 N+1 帧的字符串前缀。绝不在每 tick 改草稿（不加闭合代码围栏、不加光标后缀、不在 tool 边界重置段状态、不做 mrkdwn 转换） | 非前缀帧迫使整快照重发 →「堆叠副本」 |
| 2 | **消费方声明最终**：`finish(final_text)` 带完整的 `final_response`（含 verifier footer）。新的流后增强**必须**走这个 payload | 封口后改 `final_response` → `delivered_final_matches` 不匹配 → 补发一条重复消息 |
| 3 | **中途发送带 `metadata["_interim_send"] = True`** | 否则封口拦截会用中途文本把活流封死。**两个出口**（`send()` 和 `send_for_platform()`）都有封口拦截；新出口需要同样两处检查 |
| 4 | **用 edit 对账，不用裸 send** | 已封口的 native stream 是普通消息，`chat.update` 可用（已实机验证） |

顺便记三条 Slack 实况（`gateway/AGENTS.md:55`）：

- `chat.*Stream` 说的是 **STANDARD markdown**，不是 mrkdwn；
- `stopStream.markdown_text` 是 **APPEND**；
- `startStream`/`stopStream` 是 Tier 2（~20/min）。

以及一个测试陷阱：**MagicMock adapter 会自动造出 truthy 属性**，
所以老测试里 `draft_stream_is_message` 可能假真 —— 要显式 `is True`。

### 3.5 E 类：配置与 CLI

| 不变量 | 细节 | 出处 |
|---|---|---|
| 新增 `config.yaml` 选项 → 加进 `DEFAULT_CONFIG` | **只在要主动迁移/变换时才 bump `_config_version`**；新键会自动 deep-merge | [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:75) |
| `.env` = **secrets only** | 加进 `OPTIONAL_ENV_VARS`，带 `description/prompt/url/password/category` | 同上 |
| 非密钥设置绝不进 `.env` | 需要内部镜像就**在代码里 bridge** | 同上（= HX002 的正向表述） |
| **一个 writer seam** | 所有 `config.yaml` 写入走 `atomic_config_write`（拒绝因省略而删除）或显式 `atomic_config_replace`（完整状态替换） | 同上 |
| 绝不 `yaml.dump` / `yaml.safe_dump` / `atomic_yaml_write` 写 config 路径 | `scripts/check_config_yaml_writers.py` 在 CI 拒绝 | 同上（#92554） |
| **三个 loader，要清楚自己在哪一个** | 见下表 | 同上 |
| 每个 `DEFAULT_CONFIG` 键都有运行时读者，每个读者都有注册条目 | 两种漂移都是静默的：没人读的旋钮 / 没注册的读者 | 同上 |
| 新根键也要进 `_KNOWN_ROOT_KEYS` | 否则不显示、不迁移 | 同上 |
| slash 命令**单一来源** | `hermes_cli/commands.py` 的 `COMMAND_REGISTRY`；别名加 `aliases` 元组，所有表面自动更新 | [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:42) |
| 改 system-prompt 状态的命令**默认延后** | 下个会话生效，`--now` opt-in | 同上 |
| 交互式菜单选择器一律 curses | `hermes_cli/curses_ui.py` | [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:36) |
| spinner/display 绝不输出 `\033[K` | prompt_toolkit 的 `patch_stdout` 下会漏成字面量 `?[K`；用空格填充 | 同上 |
| wrapper CLI 用 `cli_tui_mixin.py` 的受保护钩子扩展 | 不覆盖 `run()` | 同上 |
| 目标命令只有一个解析器 | `goal_command.dispatch_goal_command`；**别加表面专属 parser** | [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:64) |

**三个 loader**（最容易踩的坑）：

| loader | 谁用 | 合并 `DEFAULT_CONFIG`？ |
|---|---|---|
| `load_cli_config()`（`cli.py`） | CLI | CLI 默认 + 用户 YAML |
| `load_config()`（`hermes_cli/config.py`） | `hermes tools/setup`、多数子命令 | ✅ 合并 |
| `load_user_config_effective()`（`hermes_cli/config_effective.py`） | gateway 运行时、TUI gateway、cron、`hermes send`、doctor、`hermes_time`/`hermes_logging` | ❌ **不合并**（给 presence-sensitive 读者用） |

**症状**：「CLI 看得到这个键，gateway 看不到」→ 你在错的 loader 上，
或者 `DEFAULT_CONFIG` 缺这一项。`gateway/AGENTS.md` 也说了同一件事的另一面：
gateway 读**用户 YAML 原文**（raw），不走 `DEFAULT_CONFIG`。

### 3.6 F 类：Cron / Kanban

| 不变量 | 细节 |
|---|---|
| 不活动看门狗看的是**不活动时间**，不是墙钟 | 默认 600s idle，`HERMES_CRON_TIMEOUT` 覆盖，`0` = 无限；长但活跃的 job 绝不被打断；附挂脚本另有 `_DEFAULT_SCRIPT_TIMEOUT`（3600s） |
| **每周期出现都记账** | `tick()` 在**派发前**推进 `next_run_at` 并同一次保存里打 `pending_slot`；找到 stamp 但 owner 已死则**恢复一次**（`cron/occurrences.py`）；executions ledger 的 `scheduled_instant` 阻止二次触发；`cron.catch_up_missed: false` 跳过超期 miss 并记原因。**绝不静默丢 slot**（#107485） |
| 每 home 一把 tick 锁 | `<home>/cron/.tick.lock`；绝不是 `~/.hermes/...` 字面量 |
| **一个 ticker 顺序迭代所有 profile** | `scheduler_provider._start_multiplex` 在 `_profile_cron_scope(home)` 下顺序迭代 `profiles_to_serve()`；**绝不 N 线程**（模块全局会竞态） |
| tick 触及的一切都在 guard 内 | store 打开、锁路径、backoff/失败计数、job env 构造、`on_session_end` flush |
| 监督按 served home，不按进程 | `SupervisedTickerThread`：gateway 启动时起、为「别的 gateway 已在服务的 home」让位、profile 目录出现或被 tombstone 时重新枚举 |
| **cron 归属不由 `multiplex_profiles` 门控** | 那个 flag 门控 **adapter**；一个 host gateway 无论如何 tick 每个 profile 的 store（`run.py::_cron_tick_profile_homes`） |
| in-flight 状态按 `(home, job_id)` 做 key | 两个 profile 合法地都有 `daily-brief`；`cron.max_parallel_jobs` 是 per-profile |
| stale-code yield gate 问 `owns_cron_tick_for(home)` / `live_gateway_ticking(home)` | 不问进程全局 runtime-lock 布尔 |
| 公开访问器返回 host 级并集，但**存活性**消费者必须带 `home=` | `is_job_running(job_id, home=...)`；并集会让 A 的 running 回答 B 的 idle |
| **claim 用它注册时的 key 释放** | `release_running_job(job_id, home=...)`；绝不从 key 的一半重建 home（`hermes_home_key` 会 normcase，用 `_inflight_home_path`） |
| ticked-home 状态在 home 离场时回收 | `register_ticked_homes` 每周期重发布并收割离场 home 的并行池 |
| host gateway 为「自己跑 gateway 的 profile」让位 | `_cron_profile_gate`；比对存活 PID 与 `os.getpid()`（本进程持有 launch `gateway.pid` **且**在 `served_profiles` 里发布所有 served profile，裸存活答案会让 cron 全 host 停摆） |
| 重启安全的外部 worker 自我引导 | `_launch_external_cron_worker` 钉 checkout + committed generation 的 `site-packages`；`_HERMES_CRON_WORKER_BOOT`；激活失败即**致命**，在 ownership ack 前退出 |
| cron 会话 `skip_memory=True` | 记忆 provider 有意不在 cron 里跑 |
| 向后代 fence 是**路径**，不是 flag | `DELEGATED_CHILD_ENV_MARKER` 携带被围的 board ROOT；`kanban_path_is_fenced(path)` 只拒 dispatcher 钉死的 `HERMES_KANBAN_DB` 或该根之下 |
| kanban **board 是硬边界**，tenant 是软命名空间 | worker 环境钉 `HERMES_KANBAN_BOARD`，看不到别的 board |
| 通知从**任务所属 profile** 离开 | `_notify_profile_filter`；fail-closed 跳过时 WARNING 一次并给补救，绝不裸 `continue` |
| prompt 注入按**所有权**门控，不按工具访问权 | `owned_kanban_task()` / `is_dispatcher_owned_worker_context()` |
| worker 存活是 `(worker_pid, worker_started_at)` | 绝不裸 PID 存在性（PID 会复用） |
| 连续失败达 `kanban.failure_limit`（默认 2）自动 block | 终端 provider 退出码 78 首轮即 sticky 阻断（#114587） |

### 3.7 G 类：插件 / 技能

| 不变量 | 细节 |
|---|---|
| **插件绝不碰核心** | 不许改 `run_agent.py` / `cli.py` / `gateway/run.py` / `hermes_cli/main.py`；缺能力就**加宽通用插件表面**（新 hook、新 ctx 方法） |
| 没有具体消费者的 hook = 投机基建，拒绝 | 根 rubric 同款 |
| 插件 setup 走 `hermes memory setup` → `provider.post_setup()` | 不是并行顶层命令 |
| in-tree 政策 | 不加新的 in-tree memory provider；第三方产品插件不进核心树（独立 repo）；参考/示例插件在 `hermes-example-plugins` |
| catalog 是**唯一**发现系统 | 每个条目 40-hex SHA 钉版；`removed.yaml` 是 kill list；catalog 溯源在 installer 的 `.install-metadata.json`，**绝不在树里**（树里的 `.hermes-catalog.json` 只是给 Desktop 的便利副本，Python 从不信任） |
| **别加第二个名字索引** | 裸名走 catalog 或报错 |
| 发现时机 | `discover_plugins()` 只是 import `model_tools.py` 的副作用；无 force 的调用在 `_discovered` 上短路；**mid-run 的加载路径全部 `force=True`** |
| `on_plugin_loaded` 只从那次 sweep 里发 | 绝不从 RPC 发 |
| 辅助 LLM 调用发 `pre/post_auxiliary_call` | 绝不发 turn 级 `pre/post_api_request`（#79733） |
| 改默认值要配 migration guard | 以「已有配置」信号（`_explicitly_configured`）为 key |
| 生命周期钩子在 owning profile 的 scope 下触发，**由调用方绑定** | provider 绝不把 `initialize()` 时的 `hermes_home` 缓存成「那个」home |
| `plugins.isolation: host` | 每条 user-code import 路径都路由到 host 或拒绝；`HOST_UNSUPPORTED_CTX_METHODS` 是**同一张表**（运行时拒绝和静态审计都读它）；host 绝不 spawn host；隔离方不能在被 pin 时自己 opt out |
| 兼容契约是**行为**契约 | hook payload 以 keyword 字段增加；`PluginContext` 方法不删不改名；未知 manifest 字段忽略；弃用要 once-per-process warning + 文档 + ≥2 个 minor |
| 内部 import 路径**不是 API** | 移动符号意味着同 PR 修文档；**绝不为内部移动加 re-export shim** |
| skill `description` ≤ 60 字符，一句，句号结尾 | `tests/skills/test_authoring_standards.py` 硬执行 |
| skill 散文用**反引号**引用 Hermes 原生工具 | 绝不点名被包装的 shell 工具（`grep` → `search_files`，`cat` → `read_file`） |
| `platforms:` gating 要与脚本实际 import 对账 | POSIX-only 原语（硬编码 `/tmp`、`fcntl`、`termios`、`os.setsid`、`/proc`、`signal.SIGKILL`、`osascript`、`apt`、`systemctl`）必须有平台声明 |
| curator 只碰 `created_by: "agent"` 的 skill | bundled + hub 装的都不可碰；**绝不删除**，archive 是上限；pinned 豁免所有自动转移 |

### 3.8 H 类：依赖与环境（PM）

| 不变量 | 细节 |
|---|---|
| 所有依赖带**上限** | PyPI：`>=floor,<next_major`；pre-1.0：`<0.(minor+2)`；git URL：40 字符 SHA；GitHub Actions：SHA + `# vN` 注释；CI-only Python 依赖：`==exact` |
| 裸 `>=X.Y.Z` 被 CI 和 reviewer 拒绝 | #2810（bounds）、#9801（SHA 钉版 + audit CI） |
| 改 `pyproject.toml` 后跑 `hermes pm lock` | 重新 `source ./activate`，**同 PR 提交 `uv.lock`** |
| **绝不用裸 pip/uv 改 Hermes 环境** | 用 `pm.sync_venv([...], explicit=True)` / `hermes pm install` / `hermes pm repair` |
| PM 拥有 Hermes Python 依赖变更 | 调用方拿到的是解释器或工具路径，不是 uv |
| `[tool.uv] exclude-newer = "14 days"` 只覆盖**核心自己的依赖** | 插件 `python_dependencies` 用插件自己的策略；Teknium 的话：「插件不必遵守我们的 14 天规则」 |
| Nix 的 uv2nix 构建与无关用户项目独立拥有 | — |

**为什么钉版是安全规则而不是洁癖**：`pm/AGENTS.md` 给了两个来源——
litellm 供应链投毒（#2796/#2810）、Mai 2026 的 Mini Shai-Hulud 蠕虫。
上限不能 `>=` 就算了：它防的是「上游发了个 breaking major」。

### 3.9 I 类：测试

| 规则 | 内容 |
|---|---|
| **永远用 `scripts/run_tests.sh`** | 绝不用裸 `pytest`。它强制 CI 同构：清空凭证变量、`TZ=UTC`、`LANG=C.UTF-8`、`HERMES_HOME` → 临时目录、**按文件子进程隔离**（`scripts/run_tests_parallel.py`，无 xdist） |
| 位置镜像源码树 | `tests/<top-level source dir>/`；只有根级模块（`batch_runner`、`utils`、`hermes_constants`、打包）直接放 `tests/` |
| **文件名不带 issue 号** | 在模块 docstring 里引用：`test_89315_x.py` → `test_x.py` + "Regression for #89315" |
| **测试绝不写 `~/.hermes/`** | autouse `_isolate_hermes_home` fixture；profile 测试还要 mock `Path.home()` |
| `patch.object(Path, "home", ...)` 必须**同时**设 `HERMES_HOME` | 因为代码读的是 env var，不是 `Path.home()/.hermes` |
| **绝不伪造宿主 OS** | 用 `@pytest.mark.platforms(...)`，在真实宿主上测。判据：「**如果测试需要解释器相信自己不在这个 OS 上才能过，它就该在那个 OS 上**」 |
| **一个 marker，多个 spec** | `platforms("linux", "macos")` 是「任一」；**绝不叠多个 `platforms()` 装饰器**（conftest 在 collection 期硬拒） |
| 绝不裸 `skipif(sys.platform ...)` | OS lane 用 marker 解析决定 import 哪些文件；裸 skipif 会**在任何宿主上都不跑**，静默 |
| **绝不写 change-detector 测试** | 不断言精确计数、模型清单、`_config_version`。判据：「读起来像快照就删；读起来像两份数据之间的契约就留」 |
| **绝不在测试里读源码** | 读 `.py`/`.ts` 文本测的是源码**形状**；正确做法是把逻辑抽成纯函数/可 DI 的函数再调用 |
| 时间测试 | 墙钟边界 ≥ 2s；事件同步；绝不 `assert not _wait_until(...)` 这种竞态 |
| flake policy | 失败的**文件**在全新子进程里重试一次（`--file-retries`）；被信号杀死或文件超时的 worker **不重试**；retry 通过标 `⚠ FLAKY` 并打印两份输出 —— **那是 bug，不是噪音** |
| Python 测试别断言 `package.json` / `.ts` | `scripts/ci/classify_changes.py` 按改动文件挑 job：JS-only PR 不会跑 `tests/*.py` → PR 绿、main 红 |
| `wine2e` lane | 只在推 `wine2e/**` 分支时触发；用于真 Windows 进程拓扑 E2E；断言找 **gateway 祖先**（venv shim 让每次 spawn 都是 launcher/worker 链），不是直接父进程 |

**runner 的几个细节**（`tests/AGENTS.md` + `contributing.md`）：

```bash
python -m pm.build_env --source . --out .venv --group dev --group test   # 这是全新构建，不是原地 sync

scripts/run_tests.sh                                     # 全量
scripts/run_tests.sh tests/gateway/                      # 一个目录
scripts/run_tests.sh tests/agent/test_foo.py -k test_x   # runner 是文件粒度；-k 收窄
scripts/run_tests.sh -v --tb=long                        # pytest flags 透传
```

- 输出目录**必须不存在**（哪怕是空目录或 symlink）；重建要先停进程再手动删（PM 不删已存在的目标）。
- runner 会**清空 `PYTHONPATH`**，所以 PM shell 激活本身不提供 pytest。
- 输出在 checkout 之外时设 `HERMES_PYTHON` 指向它的解释器。
- 当 `tests/conftest.py` 把生产 `HERMES_HOME` 重定向到临时 home 时会设内部标记
  `HERMES_TEST_SANDBOX_HOME`，让重新 import 的 fixture 认得出自己的沙箱。
  **别自己设这个标记。**

### 3.10 J 类：宿主事实

| 不变量 | 细节 |
|---|---|
| 机器事实与可执行查找**走 `hermes_platform`** | `host.*` 是 OS family、原生架构、CPU 身份、WSL/container/Termux 的**唯一答案** |
| 原生架构用 `IsWow64Process2` → `platform.machine()` | **绝不只看 `PROCESSOR_ARCHITECTURE`**（x64-on-ARM64 模拟下它读成 AMD64） |
| 事实按进程缓存且**不接受环境变量输入** | 硬件识别器不能从 shell 设置 |
| 区分三种机器 | control host（跑这个 Python 的）/ 终端执行目标（SSH/容器）/ Desktop 客户端（另一台机器）；`host.*` 只回答**第一个** |
| 新的裸 `shutil.which` 或手写 known-path 表 | 会失败 `tests/test_managed_runtime_resolution.py`，除非带理由 allowlist |
| resolver 落在 `hermes_platform/resolver/` | 查找**绝不**安装、下载或启动任何东西 |

### 3.11 K 类：TypeScript（desktop / TUI / website）

| 规则 | 内容 |
|---|---|
| 特性自有的 nanostores | 优于穿线状态 |
| 路由根要薄 | — |
| 窄 hook + 同目录 action 模块 | — |
| `interface` 用于 props 和共享形状 | 不用 type alias 做 props |
| 表驱动 dispatch 优于条件阶梯 | 与 HX011 同源 |
| 目录约定 | `src/app` 路由、`src/store` atoms、`src/lib` 纯 helper |

### 3.12 L 类：安全

`SECURITY.md` 是**范围权威**。关键分界：

| 章节 | 是什么 | 怎么处理 |
|---|---|---|
| §2 | Trust Model（OS 级隔离边界、凭证作用域、进程内启发式、插件信任、外部表面） | 理解你跨的是哪条边界 |
| §3.1 | **In Scope** | **走私密渠道**（GitHub Security Advisories 或 security@nousresearch.com），**绝不**进公开 issue / PR / commit / comment |
| §3.2 | Out of Scope（加固类） | 普通公开工作 |
| §4 | Deployment Hardening | 运维侧 |

**报安全问题时必须指名你跨越的 §2 边界，并给 `main` 上的复现。**

已在代码里的防护（`contributing.md` § Existing Protections）：

| 层 | 实现 |
|---|---|
| sudo 密码管道 | `shlex.quote()` |
| 危险命令检测 | `tools/approval.py` 的正则 + 用户审批流 |
| cron 提示注入 | 扫描器阻断指令覆盖模式 |
| 写入拒绝列表 | 通过 `os.path.realpath()` 解析，防 symlink 绕过 |
| skills guard | hub 安装 skill 的安全扫描器 |
| 代码执行沙箱 | 子进程剥离 API keys |
| 容器加固 | Docker：drop 所有 capability、禁止提权、PID 限制 |

---

## 4. 豁免语法：`# noqa` 与 `# health: allow`

### 4.1 两者分工

| 语法 | 管谁 | 谁读 |
|---|---|---|
| `# noqa` | **ruff** 原生规则 | ruff |
| `# health: allow <RULE> -- <why>` | **code-health ratchet** 的全部规则（含 `source="ruff"` 的那些） | `scripts/code_health/report.py` |

关键细节在 `config.py` 的 `BLE001` 条目里：

```
" `# noqa` is ignored here: waive with `# health: allow BLE001 -- <why>`"
```

也就是说：**ratchet 跑 ruff 时带 `--ignore-noqa`**。
一条规则一旦进了 `RULES`，它的豁免权就从 ruff 转交给 `# health: allow`，
因为后者的格式强制你写**理由**。

### 4.2 为什么只认「真注释」

[`scripts/code_health/model.py:44`](../scripts/code_health/model.py:44)：

```python
# 1-based line -> text of the real comment tokens on it (allow directives live only here,
# so a string literal that happens to say "health: allow" waives nothing).
comments: dict[int, str] = field(default_factory=dict)
```

所以：

```python
x = "health: allow HX001 -- 我在一个字符串里，豁免无效"      # ← 无效
# health: allow HX001 -- 这是真注释，有效                   # ← 有效
```

这个设计堵的是「为了让检查器闭嘴，把豁免写进数据里」——
那样豁免就成了可以批量生成的噪音。

### 4.3 为什么行号不是发现的身份

`Hit` 的形状（`model.py:25`）：

```python
@dataclass(frozen=True)
class Hit:
    """A pattern-rule fingerprint: never a line number, so edits above don't move it."""
    rule: str
    scope: str
    text: str          # = FileMeasure.code_line(line_no)
```

而 `code_line()` 的定义（`model.py:51`）：

```python
def code_line(self, line_no: int) -> str:
    """The line's code with its comment removed and whitespace normalised: the identity of
    a violation, so editing or dropping a comment (an allow included) never makes old debt
    look new."""
```

**这条注释解释了整个 ratchet 的公平性设计**：老债是按「**代码指纹**」记的，不是按行号。
所以在文件顶部加一行 import、或者改掉一条注释，**不会**让旧违规看起来像新违规
（那样你就会被要求修一堆你根本没碰的代码）。

### 4.4 豁免的正确写法

```python
# health: allow HX006 -- unbounded by design: the update's own supervised child
proc.wait()
```

要素：

1. **规则 id 精确**：`HX006`，不是 `HX` 或 `HX6`。
2. **分隔符是 ` -- `**（空格、两个连字符、空格），与 `ALLOW_SYNTAX` 常量一致：
   `"# health: allow <RULE> -- <why>"`。
3. **`why` 必须解释「为什么这条规则在这里不适用」**，而不是重述规则。
   对照反例：`# health: allow HX006 -- 这里有 subprocess`（等于没说）。
4. **放同一行或紧邻上一行**（`report.py` 的实现是「该行或上一行」）。

**什么时候不该 allow**：如果理由能写成「我改一下形状就不违规了」，
那就改形状。allow 是给**设计上必需**的例外留的（更新进程无上界、
`_get_profiles_root()` 必须 HOME-anchored、延迟本身就是被测行为）。

---

## 5. CI：`scripts/check` 到底跑什么

### 5.1 一条命令 = CI 的 lint lane

```bash
python scripts/check                  # 全跑，对照与 origin/main 的 merge-base
python scripts/check --only health    # 只跑 code-health ratchet
python scripts/check --staged         # 判 index（pre-commit hook 用）
python scripts/check --commit REV     # 判一个 commit（pre-push hook 用）
python scripts/check --install-hook [pre-commit|pre-push]
python scripts/check --uninstall-hook
```

文档原话：`CI runs the same command (``.github/workflows/lint.yml``), so a green local run
means a green lint lane.`

**但注意诚实边界**：`Hooks are skippable (``--no-verify``); CI is not.`

### 5.2 全部检查项

`_CHECKS = (*_GUARDS, *_DIFF_GUARDS, "ruff", "health")`：

| 名字 | 状态 | 脚本 | 拦什么 |
|---|---|---|---|
| `footguns` | blocking | [`scripts/check-windows-footguns.py`](../scripts/check-windows-footguns.py:1) `--all` | Windows 会静默失效的模式（`signal.SIGKILL`、`os.kill(pid,0)`、`os.setsid`…） |
| `shebangs` | blocking | [`scripts/check_bash_shebangs.py`](../scripts/check_bash_shebangs.py:1) | 要求 PATH 解析的 Bash（Nix 等非 FHS 环境没有固定 `bin/bash`） |
| `no-tmp` | blocking | [`scripts/check_no_tmp_literals.py`](../scripts/check_no_tmp_literals.py:1) | 生产代码、skills、docs、prompts 里硬编码 `/tmp` |
| `config-writers` | blocking | [`scripts/check_config_yaml_writers.py`](../scripts/check_config_yaml_writers.py:1) | 绕过保留注释的 writer 写 `config.yaml` |
| `os-marker-fakes` | blocking | [`scripts/ci/check_os_marker_fakes.py`](../scripts/ci/check_os_marker_fakes.py:1) | 测试伪造 macOS 却没有 `platforms("macos")` marker |
| `agents-md` | blocking | [`scripts/ci/check_agents_md_size.py`](../scripts/ci/check_agents_md_size.py:1) | `AGENTS.md` 超过链上限 |
| `case-collisions` | blocking | [`scripts/check-case-collisions.py`](../scripts/check-case-collisions.py:1) | 忽略大小写后会撞的 tracked 路径 |
| `lazy-deps` | blocking | [`scripts/ci/check_lazy_deps_imports.py`](../scripts/ci/check_lazy_deps_imports.py:1) | 生产代码 import `tools.lazy_deps` 桩 |
| `profile-archives` | blocking | [`scripts/ci/check_profile_archive_boundary.py`](../scripts/ci/check_profile_archive_boundary.py:1) | profile 导出归档进入发布 |
| `blob-size` | blocking（**diff**） | [`scripts/ci/check_blob_size.py`](../scripts/ci/check_blob_size.py:1) | 大二进制 / 大新文件进仓库 |
| `ruff` | blocking | pinned ruff `check .` | ruff 规则集 |
| `health` | blocking | `python -m scripts.code_health` | HX + 尺寸 ratchet |

**下面这些不在 `scripts/check` 里，但 CI 有独立 lane**（不要以为本地绿=全绿）：

| 检查 | 位置 | 拦什么 |
|---|---|---|
| `check_profile_scope_patterns.py` | `lint.yml`（**advisory**，永远 exit 0） | profile-scope 危险形状；reviewer 逐条读 |
| `check_public_surface.py` | `lint.yml`（**advisory**） | 掉了公开名 / 掉了 `def test_` |
| `check_docs_drift.py` | 独立 | 新的 `DEFAULT_CONFIG` 键 / slash 命令没文档 |
| `prompt_surface.py` | `prompt-surface-diff.yml` + `tests/ci/test_prompt_surface.py` | prompt / tool schema 的**字节级**变化 |
| `check_subprocess_stdin.py` | 由 `tests/tools/test_subprocess_stdin_guard.py` 包成 pytest | TUI 上下文里 subprocess 没设 `stdin=`（#14036/#39257） |

### 5.3 每道 guard 的一句话理由

理解 guard 的最好方式是读它的 docstring —— 它们都在第一段写了「为什么」。

**`no-tmp`**：

> `/tmp` is not portable: Termux has no `/tmp` at all, native Windows has no such directory,
> macOS aliases it to `/private/tmp` (breaking naive path comparisons), and on most Linux
> distributions it is a RAM-backed tmpfs that fills under Hermes load.

正解：`hermes_constants.get_scratch_dir()` → `HERMES_HOME/cache/scratch`，
每个 Hermes 进程还把它导出为 `TMPDIR`/`TMP`/`TEMP`。
**prompts 和 skills 也必须这样引导模型**，因为 SKILL.md 里的字面 `/tmp`
会变成模型在**每个平台**执行的 `/tmp` 命令。

自动不报的形态：`${TMPDIR:-/tmp}`（shell fallback）、`/var/tmp`、`/private/tmp`、
`tmpfs`、`tmp_path`、`~/tmp`、**代码注释与 docstring**（Markdown 散文**不**豁免，
因为 docs 和 skills 是人+模型都会读的）。

**`config-writers`**：

> A PyYAML dump of a config path re-serialises the parsed dict and destroys every user comment
> — the #92554 class, which regressed several times because each new writer picked the plain
> dumper again.

**注意「regressed several times」**：这就是为什么它必须是 CI guard 而不是文档规则。

**`case-collisions`**：

> Two tracked paths that differ only by case coexist happily in a Linux checkout and silently
> break every clone on a case-insensitive host… Git itself won't stop the pair from landing.

比较键是**casefold 后的完整路径**（不是 basename）—— 因为在不区分大小写的文件系统上，
**整条路径**都不区分大小写。

**`blob-size`**：

> Every blob a merge adds stays in every clone forever, so a screenshot, a test database or an
> archive committed by mistake costs every contributor and every CI checkout from then on,
> even after a later commit deletes it.

它判的是「**新增的字节**」：纯重命名、复制、回退到已 tracked 版本，都不算（pack 里没多字节）。
`MAX_BYTES` / `.github/blob-size-allowlist.txt`（精确路径，CODEOWNERS 审）是唯一豁免通道。

**`agents-md`**：见 §1.2。

**`lazy-deps`**：

> ``tools/lazy_deps.py`` survives only as an old-updater stub that raises or stops for relaunch;
> pm.extras (available / ensure_import / ensure_and_bind) is the only lazy-install surface.

三重严格：tracked inventory 来自 `git ls-files`（绝不走过被 ignore 的残留）；
扫不到任何 `.py` 文件**也 FAIL**（绝不「什么都没扫 → 通过」）；
读不了/解析不了的文件**报错**而不是跳过。

**`profile-archives`**：

> ``.gitignore`` and ``.dockerignore`` are useful first-line filters, but both can be bypassed
> (for example with ``git add -f`` or a non-standard build context). This check is the blocking,
> executable policy at the CI and image publication boundaries. It intentionally checks the
> filesystem rather than Git's index so a generated archive cannot enter a build after checkout.

**`os-marker-fakes`**：

> A file whose tests only pass because they make the interpreter believe it is on macOS but that
> carries no marker is invisible to that lane: it is green on Linux over a faked branch and never
> imported on the host it exists for (#111866).

**`check_public_surface.py`** 的数字非常值得记（它是「为什么需要这个检查」的最佳论据）：

> The Sep 2026 whole-codebase refactor (PR #102117) opened with **1,703 public top-level names
> dropped across 341 modules, 1,000 public methods in 166, and 130 `def test_` deleted in 54 files**.
> Reviewers found ~30 of the names by hand; the rest surfaced as post-merge fixes.

规则很窄且**故意没有 allowlist 文件**：两侧都存在的模块里，公开顶层名（函数/类/模块级赋值/
re-export 的 import）或公开/dunder 方法**可以移动并 re-export 或弃用，绝不静默删除**。

**`prompt_surface.py`**：

> A one-line code change can rewrite either without the diff showing it (a guidance constant
> moves tiers, a toolset gains a tool, a dynamic rewriter edits a description).

它把 system prompt 和 `tools[]` 通过**生产代码**渲染到 `tests/fixtures/prompt_surface/`（committed）。
于是「一次 prompt 变更」变成一份**可 review 的真实 prompt 文本 diff**，
而且 repository ruleset 要求 core approval。

**`check_docs_drift.py`**：新 `DEFAULT_CONFIG` 键和 slash 命令必须有文档。
判据宽松（点路径、占位路径、YAML 例子三选一），落地时已有的缺口进 baseline，
**只有新缺口失败**；`--update` 会把 baseline 修剪到当前缺口。

### 5.4 hook 的机制（为什么它不会被绕过）

`scripts/check` 装出来的 hook 有两个设计点：

1. **hook 被整个 clone 的所有 worktree 共享**，所以「当前 checkout 的分支」不能决定任何事。
   它把**每个候选**（正在提交的 index、每个被推分支的 tip）**物化成一个临时树**，
   然后由**那个候选自己的 `scripts/check`** 来判。
2. **候选早于 `scripts/check` 存在** → 不判（而不是误判）。

`_checkout_tree` 的实现细节也值一提：

```python
env = {**os.environ, "GIT_DIR": git_dir, "GIT_WORK_TREE": str(root),
       "GIT_INDEX_FILE": str(Path(tmp) / "index")}
_git_in(env, "read-tree", tree)
# -f: on a case-insensitive filesystem paths that differ only by case are one file, and
# without it the second one aborts the snapshot before the case-collision guard runs
# (the guards read the index, which keeps both).
_git_in(env, "checkout-index", "-a", "-f")
```

**「case-collision guard 读的是 index」**这句是关键 —— 所以物化时带 `-f`，
否则第二个同名文件会在 checkout 阶段就 abort，guard 根本没机会跑。

另一个细节：hook 里找解释器时，先把 **repo 的 `.venv`**（本 worktree 的，再 main checkout 的）
放在 PATH 的裸 `python3` 之前，因为 `scripts/check` 需要 **Python 3.11+**（`tomllib`）。
脚本开头也自己检查：

```python
if sys.version_info < (3, 11):
    print(f"scripts/check needs Python 3.11+ ...; run it with the repo's virtualenv (.venv/bin/python scripts/check)", file=sys.stderr)
    raise SystemExit(2)
```

---

## 6. Ratchet 机制：为什么它比「静态阈值」温和

### 6.1 per-unit cap

`scripts/code_health/cli.py` 的 footer 就是一句话说明书：

> Each function and file has its own cap: **its value on main if it is already over target,
> otherwise the target**. New code meets the target; existing code may only go down.

所以：

| 情形 | 结果 |
|---|---|
| 新函数 CC = 25 | ❌ 超 target 20 → 阻断 |
| 老函数 CC = 40（main 上就是 40） | ✅ 允许，cap = 40 |
| 老函数 CC = 40 → 41 | ❌ 阻断（只能降） |
| 老函数 CC = 40 → 35 | ✅ 允许（并且新 cap = 35，**不能弹回去**） |

这就是「ratchet」的字面意思：**棘轮只能往一个方向转**。

### 6.2 增长怎么合法地摊平

`METRIC_FIX["FILE_LINES"]` 给了两条正路：

1. **同一个 PR 里把已有函数挪进新 sibling** —— `moved code keeps its cap`
   （即：挪走的代码在新文件里保留它原来的 cap，不会因为「换了个文件」就重置成 target）。
2. **新测试放进新的 `test_<stem>_<topic>.py`**。

加一句硬的：`new behaviour never goes into a facade`（[`AGENTS.md`](../AGENTS.md:114) 同款）。

### 6.3 `WARN_UNTIL_REPLAYED` 与 `replay.py`：规则怎么获得「阻断资格」

`config.py:61`：

> Heuristic rules print as warnings until a frozen replay
> (`python -m scripts.code_health.replay`) shows most of their hits on merged PRs are real
> problems; flip a rule to blocking with that evidence in the PR.
> Reviewers' samples put these between ~12% and ~60% precision.

`replay.py` 做的事（docstring）：

```bash
python -m scripts.code_health.replay --merged 2026-09-01..2026-09-30 --limit 300 --out <dir>
python -m scripts.code_health.replay --manifest <dir>/manifest.json --out <dir2>
```

- 样本 = 时间窗内合入 main 的**所有** PR，按 PR 号排序（**同一窗口永远选出同一批**，
  旧 PR 上新加一条评论不会打乱顺序）。
- 每次跑写 `manifest.json`（number/base/head），`--manifest` 可精确重放同一批（用来比较两个引擎版本）。
- 写 `replay.jsonl`（每 PR 一行），打印每规则总数 + 「至少一条阻断发现的 PR 数」。

**一个非常讲究的细节**（`replay.py:123`）：

> A range that was never measured is no evidence either way: it stays out of the totals and
> the denominator, and fails the run, so a "0 of N" verdict always means N measured PRs.

即：**「测不了」不等于「没问题」**。测不了的 PR 被单列并让整次 run 失败，
这样「0/N」里的 N 永远是「真的测过的 N」。

`pr_range()` 也很细：对 rebase-merge 的 PR，它用「PR 里 commit 的 subject 集合」
在 `--first-parent` 日志里数出连续匹配的个数 `k`，基就是 `head~max(k,1)`。
这是「rebase 之后 merge commit 的第一父不是 PR 的基」这个事实的正确处理。

### 6.4 测量失败也是失败

`model.py:47`：

```python
# Why this file could not be measured (unparseable, measurer failure): a measurement gap
# must fail the check, never read as "no findings".
error: str | None = None
```

以及 `METRIC_FIX["MEASURE"]`：

> the file must parse and measure (a file that cannot be measured cannot be judged);
> fix the syntax, or report the measurer bug

**这是整篇最值得学的一条工程直觉**：任何「检出率」工具都必须区分
「查了，没问题」和「没查成」。把二者混为一谈的工具，在关键时刻会给你假的绿。

---

## 7. 「不要加第二个 X」清单

这张表来自 15 篇的反复出现，是本仓库**最强的架构信号**。
每一条都对应一个真实事故：有人「顺手」写了第二个实现，然后两者漂移。

### 7.1 解析 / 读取类

| ❌ 不要加第二个 | ✅ 唯一实现 | 漂移的后果 |
|---|---|---|
| 第二个 home resolver | `get_hermes_home` / `get_process_hermes_home` / `get_routing_process_hermes_home`（三者语义不同，见第 14 篇 §2） | #119242：宿主镜像 env 时身份错乱 |
| 第二个平台凭证读取器 | `gateway.platforms._shared.get_scoped_secret`（adapter 里 import 成 `_get_scoped_secret`） | #86905：泄漏的 allowlist 静默拒掉所有二级 profile 发送者 |
| 第二个「谁是接收 bot / 谁是交付 bot」答案 | `_intake_adapter_for` / `_delivery_adapter_for` | 读 `self.adapters[platform]` 会把 B 的回复发到 A 的 bot |
| 第二个身份规范化 | `session_identity.resolve_identity` | 「两条 key 派生路径，一条 lane 被所有 bot 共享」(#88715) |
| 第二个 config writer | `atomic_config_write` / `atomic_config_replace` | #92554：用户注释被清空，反复回归 |
| 第二个 config loader 链 | 三个 loader 各管一段（见 §3.5） | 「CLI 看得到，gateway 看不到」 |
| 第二个 catalog 名字索引 | `hermes_cli/plugin_catalog.py` | 裸名解析分叉 |
| 第二个 goal parser | `goal_command.dispatch_goal_command` | 表面行为不一致 |
| 第二个 slash 命令注册表 | `hermes_cli/commands.py` 的 `COMMAND_REGISTRY` | 别名/帮助/补全分叉 |
| 第二个 memory provider 调用路径 | `agent/memory_provider.py` ABC + `agent/memory_manager.py` 编排 | provider 缓存错 home |
| 第二个 `/api` 认证方案 | web 的 session token（REST + WS 同一套） | 多一套 secret 要轮换 |
| 第二个 ledger / 第二套 setInterval | `cron/occurrences.py` + 一个 ticker | 双跑双花钱 |

### 7.2 绑定 / 作用域类

| ❌ 不要加第二个 | ✅ 唯一实现 |
|---|---|
| 第二个「这个任务是否服务 routed profile」判断 | `serves_routed_profile` / `_is_process_home` / `_is_routed_home`（全部比 `get_routing_process_hermes_home()`） |
| 第二个只设 `get_hermes_home_override()` 的装饰器 | `_profile_runtime_scope_tokens`（home + secret + terminal **三件套**） |
| 第二个子进程 env builder | `build_subprocess_env` / `served_profile_child_env` |
| 第二个「只绑 home」的侧工作者入口 | `_session_profile_runtime_scope` |
| 第二条进程级 registry cache 的 key 方案 | `hermes_home_key()` |
| 第二个裸线程启动点 | `spawn_context_thread` |
| 第二个 adapter 里「YAML → env」桥 | `_shared.apply_yaml_bridge` + `platform_gate_env` |

### 7.3 形状类

| ❌ 不要 | ✅ 要 |
|---|---|
| `elif` 阶梯（HX011） | dict → handler（`_SLASH_DISPATCH`） |
| `if name == ...` 链加 agent 级工具 | `INLINE_TOOL_EXECUTORS` 表 |
| `elif backend == ...` | 新 sibling 或 provider 表条目 |
| re-export shim（为内部移动） | 修文档 + 改调用点；内部路径不是 API |
| 第二个 `platforms()` 装饰器 | 一个 marker 多个 spec |
| 手写 known-path 表 | `hermes_platform/resolver/` |
| 手写进程身份判断 | `looks_like_gateway_command_line` |
| 手写 raw→overlay→expand | 用现成 loader |
| 表面专属 parser | 共享 dispatcher |

### 7.4 为什么这条清单有效

因为**漂移是渐进的**。第二个实现刚写出来时通常是对的，
问题出现在 6 个月后有人只改了其中一个。
`gateway/AGENTS.md` 的措辞最直白：

> Never derive a second answer next to the identity; extend the object.

「**extend the object**」是正解：不是加第二个解析器，而是给唯一那个对象加字段。

---

## 8. 症状 → 文件 速查表

### 8.1 找实现

| 我想…… | 去哪里 |
|---|---|
| 找某个 turn 相位 | `grep -rn "def X" agent/turn_*.py` |
| 找某个状态的读写 | `grep -rn "def name" hermes_state_*.py` |
| 找网关某相位 | `grep -rn "def name" gateway/run_*.py` |
| 找 CLI 某命令 | [`hermes_cli/commands.py`](../hermes_cli/commands.py:1) 的 `COMMAND_REGISTRY` → 对应 `cli_*_mixin.py` |
| 找 TUI 某 RPC 方法 | `tui_gateway/methods_*.py` |
| 找 provider 解析 | [`agent/auxiliary_client.py`](../agent/auxiliary_client.py:1) `_resolve_auto_route`；主链路见 `website/docs/developer-guide/provider-runtime.md` |
| 找配置项默认值 | [`hermes_cli/config_defaults.py`](../hermes_cli/config_defaults.py:1)（或 `config.py` 的 `DEFAULT_CONFIG`） |
| 找 env var 定义 | [`hermes_cli/config.py`](../hermes_cli/config.py:1) 的 `OPTIONAL_ENV_VARS` |
| 找某个不变量 | 对应目录的 `AGENTS.md`，再从 [`scripts/code_health/config.py`](../scripts/code_health/config.py:66) 对 HX 号 |
| 找子系统长文档 | [`codebase-ownership.md`](../website/docs/developer-guide/codebase-ownership.md:10) 的映射表 |
| 找某次事故 | `git log --oneline --grep="#<号>"` |

### 8.2 加东西

| 我要加…… | 步骤 | 必读 |
|---|---|---|
| 一个**核心工具** | `tools/your_tool.py`（顶层 `registry.register()`）+ `toolsets.py` 的 `_HERMES_CORE_TOOLS` 或新 toolset | [`tools/AGENTS.md`](../tools/AGENTS.md:23) |
| 一个**本地/自定义工具** | **不要改核心**：`~/.hermes/plugins/<name>/plugin.yaml` + `__init__.py` + `ctx.register_tool(...)` | [`plugins/AGENTS.md`](../plugins/AGENTS.md:69) |
| 一个 **provider** | `plugins/model-providers/<name>/` + `register_provider(ProviderProfile(...))` | [`adding-providers.md`](../website/docs/developer-guide/adding-providers.md:1) |
| 一个**平台适配器** | 照 [`ADDING_A_PLATFORM.md`](../gateway/platforms/ADDING_A_PLATFORM.md:1) 一步步走 | [`gateway/AGENTS.md`](../gateway/AGENTS.md:1) |
| 一个 **slash 命令** | ① `CommandDef` 进 `COMMAND_REGISTRY` ② `_handle_<name>_command` 放 mixin 或进 `_SLASH_DISPATCH` ③ gateway 侧 handler + `_IDLE_COMMANDS`/`_PLAIN_COMMANDS` ④ 持久设置走 `save_config_value()` | [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:53) |
| 一个 **skill** | `skills/<category>/<name>/SKILL.md`（或 `optional-skills/`）+ 创作标准八条 | [`creating-skills.md`](../website/docs/developer-guide/creating-skills.md:1)、[`skills/AGENTS.md`](../skills/AGENTS.md:24) |
| 一个 **memory provider** | `plugins/memory/<name>/` —— **但新 provider 应独立仓库** | [`memory-provider-plugin.md`](../website/docs/developer-guide/memory-provider-plugin.md:1) |
| 一个 **context engine** | `plugins/context_engine/<name>/` + 配置 `context.engine` | [`context-engine-plugin.md`](../website/docs/developer-guide/context-engine-plugin.md:1) |
| 一个 **配置键** | ① `DEFAULT_CONFIG` ② 运行时读者 ③ `_KNOWN_ROOT_KEYS`（新根） ④ 文档（否则 `check_docs_drift` 红） ⑤ 一个「在临时 config.yaml 里设它并断言行为」的测试 | [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:107) |
| 一个**环境变量** | 先问：它真是密钥吗？不是就进 `config.yaml`（HX002） | §2.4 |
| 一个 **benchmark / eval** | `evals/<topic>/` | [`evals/`](../evals/) 现有结构 |

### 8.3 修东西

| 症状 | 先去这里 |
|---|---|
| 本 profile 的配置/密钥串到别的 profile | §7.2 整张表；`agent/secret_scope.py`、`tools/terminal_scope.py` |
| 消息被重复发送 | §3.4 流式四条；`tests/gateway/test_stream_final_contract.py` |
| 审批提示卡住 | §3.4 双消息守卫 |
| cron job 不跑 / 双跑 | §3.6；`cron/occurrences.py`、`scheduler_ownership.py` |
| 记忆写进了错的库 | `_run_release_in_profile_scope`；`Path(_session_db.db_path).parent` 是 ground truth |
| 后台进程通知没到 | `run_notifications.py::arm_process_watcher` + `admit_internal_event` receipt |
| 测试本地过 CI 不过 | 几乎总是「没用 `scripts/run_tests.sh`」——凭证/时区/`HERMES_HOME`/子进程隔离四项 |
| 测试在 macOS lane 从未跑 | 裸 `skipif(sys.platform ...)`（§3.9） |
| 改了 prompt 但 PR 显示无 diff | `prompt_surface.py` 快照过期（§5.3） |
| `hermes update` 后行为变了 | `update_handoff.py` / `update_serve_obligations.py` 是 **FROZEN compat surface**，删名字会让发布中途变砖 |

---

## 9. 怎么判断「缺失的功能」是故意设计还是 bug

这是 rubric 里最长的一节（`contributing.md` § Before you call it a bug），
也是新手最容易撞墙的地方。**「这段代码看起来没写完」往往就是设计。**

### 9.1 四步流程

```text
1. 读 AGENTS.md（就近那一层）      —— 规则可能已经写明这个「缺失」是约束
        │ 没写？
        ▼
2. git log -p -S "<符号名>"        —— 看它是「从未存在」还是「被删掉」
        │ 还是不确定？
        ▼
3. 找事故号 / PR 号 → git log --grep
        │ 还是没有？
        ▼
4. 问（issue / Discussions）。问比发一个和设计对抗的 PR 便宜。
```

### 9.2 rubric 给的四种「不是 bug」

| 形态 | 例子（rubric 原文） | 你该怎么想 |
|---|---|---|
| **Intentional design, not a gap** | 有人提 PR 让 profile 继承 default 的活配置 —— 被关掉，因为「耦合 profile 正是设计要防的」，`--clone` 已经覆盖「从我默认配置开始」 | 问「这个隔离是不是**就是**设计」 |
| **前提不成立** | 一个「冷却期重新探测」的限流 PR —— 断路器只在**确认空桶**时跳，重探就是在锤一个已被证明是空的桶；另一个 usage 修复的新分支**永远不会执行**，因为更早的 guard 已经把状态 pop 了 | 「指不出 bug 显现的那一行 + 证明你的修改改变了那一行」，前提就没验证 |
| **缺失是故意的（load-bearing absence）** | 「补回」缺失的 `__init__.py` 让一个测试树变成可 import 的点分包，它 shadow 了真插件并在 import 时删掉了它的 `register()` | 缺失可能在承重 |
| **越界 / 复活已被否的方向** | 超出约定基线的 scope creep，或把 maintainer 已关的方向捡回来 —— 即使能跑也拒 | 剩下的部分另开一个聚焦的 follow-up |

### 9.3 通过线（throughline）

> **verify the claim AND the intent against the codebase before writing or merging a fix.**
> A reproduction on current `main` plus a line-level account beats a plausible rationale.

翻译成可执行的三问：

1. **能在当前 `main` 上复现吗？**（不是「理论上会」）
2. **能指出 bug 显现的**那一行**吗？**（不是「在这个文件附近」）
3. **你的修改改变了那一行的行为吗？**（不是「我加了一个分支」）

三问答不全 → 前提未验证 → 先去验证，别写代码。

### 9.4 `git log -p -S` 的具体用法

```bash
# 这个符号是什么时候引入/删除的，以及当时的完整改动
git log -p -S "MEDIA_DELIVERY_SCOPE" --  gateway/

# 只看引入/删除的提交标题（快）
git log --oneline -S "_RECONNECT_ATTENTION_AFTER_SECONDS"

# 按事故号找原始 PR
git log --oneline --grep="#115635"

# 某文件某行的最后一次改动
git log -L 155,175:gateway/run.py
```

`-S` 是 **pickaxe**：找「这个字符串的出现次数发生变化」的提交。
所以它同时找得到「加入」和「删除」——**这正是你要的**：
如果符号被删过，说明有人专门删它（可能带理由）。

### 9.5 关闭权限的边界（给 triage 用）

`AGENTS.md` 说明：triage sweeper **只能**以
`implemented_on_main` / `cannot_reproduce` / `incoherent` 三个理由关；
**基于品味的关闭是 maintainer 的判断**；有疑问时 PR 保持打开。

---

## 10. 每类不变量的探测方法

规则不能只靠读。下面每类给一个**可执行的探测动作**。

### 10.1 home / profile 泄漏

```python
# 两个磁盘 home + 只有 secondary 才有的 .env 名
def test_secondary_secret_does_not_leak(tmp_path, monkeypatch):
    launch = tmp_path / "launch"; launch.mkdir()
    second = tmp_path / "profiles" / "b"; second.mkdir(parents=True)
    (second / ".env").write_text("SOME_TOKEN=secondary-value\n")

    # 进入 secondary 的运行时作用域
    with _profile_runtime_scope(second):
        assert get_secret("SOME_TOKEN") == "secondary-value"

    # 退出后：启动 profile 的 os.environ 必须原封不动
    assert os.environ.get("SOME_TOKEN") != "secondary-value"
```

这是 `tui_gateway/AGENTS.md:72` 给的形状：
`Probe with two on-disk homes and a .env name present only in the secondary:
call the method for that session and assert the secondary's value resolves and the launch
profile's does not, and that os.environ is unchanged afterwards.`

### 10.2 消息流不变量

```python
# 断言形状，不断言文本快照
roles = [m["role"] for m in messages]
assert all(a != b for a, b in zip(roles, roles[1:])), "两个同角色连排"

system_prompts = [m["content"] for m in messages if m["role"] == "system"]
assert len(set(system_prompts)) == 1, "system prompt 中途变了"
```

`agent/AGENTS.md:145`：

> Assert message-shape invariants (alternation, byte-stable system prompt) rather than
> snapshotting prompt text.

### 10.3 进程/线程作用域

```python
# 在后台线程里读 scope
captured = {}
t = spawn_context_thread(lambda: captured.update(scope=current_secret_scope()), name="probe")
t.start(); t.join()
assert captured["scope"] is not None      # 裸 threading.Thread 这里会是 None
```

### 10.4 配置写入的注释保持

```bash
scripts/run_tests.sh tests/hermes_cli/test_config_yaml_comment_preservation.py
```

以及直接验：

```python
path.write_text("# 我的注释\nmodel:\n  name: x\n")
atomic_config_write(path, {**load_config(), "model": {"name": "y"}})
assert "# 我的注释" in path.read_text()
```

### 10.5 进程身份

```bash
# 找有没有用 argv 子串判身份的残留
rg -n '"serve" in |"gateway" in .*cmdline|cmdline.*"hermes"' --glob '!tests/*'
```

以及跑检查器自检：

```bash
scripts/run_tests.sh tests/scripts/test_code_health_rules.py -k "HX001 or HX003 or HX012"
```

### 10.6 cron slot 记账

```python
# 派发前 next_run_at 已推进 + pending_slot 已写
before = store.get_job(job_id)
tick(now=fixed_now)
after = store.get_job(job_id)
assert after["next_run_at"] > before["next_run_at"]
assert after["pending_slot"] is not None
```

### 10.7 prompt 表面

```bash
python scripts/ci/prompt_surface.py render       # 重新渲染快照
scripts/run_tests.sh tests/ci/test_prompt_surface.py
```

### 10.8 依赖上限

```bash
python scripts/check --only health               # 含 config 相关
grep -nE '"[a-z0-9_-]+>=[0-9.]+"' pyproject.toml # 应无命中（缺上界）
```

### 10.9 一次跑完全部

```bash
python scripts/check
```

`--only` 可以只跑一段：`footguns,shebangs,no-tmp,config-writers,os-marker-fakes,agents-md,case-collisions,lazy-deps,profile-archives,blob-size,ruff,health`。

---

## 11. 改代码前的检查清单

### 11.1 60 秒版

- [ ] 这条规则在哪个 `AGENTS.md`？（就近那一层读了没有）
- [ ] 我会新增 `HERMES_*` 吗？（HX002 → 换成 `config.yaml`）
- [ ] 我会在 import 时读 home/config/env 吗？（HX005 → 改调用时）
- [ ] 我用了裸 `threading.Thread` 吗？（HX012 → `spawn_context_thread`）
- [ ] 我写了 `except UnscopedSecretError: os.getenv(...)` 吗？（HX004 → 绑 scope）
- [ ] 我加了 `elif` 阶梯吗？（HX011 → dict→handler）
- [ ] 我在测试里 `sleep` 了吗？（HX013 → Event / `wait_until`）

### 11.2 profile 相关（做了才勾）

- [ ] turn **之外**的路径（boot 探测、驱逐、ticker、延迟回调、RPC、线程跳、子进程）都**显式绑**了 owning profile 的 scope？
- [ ] 绑定用的是**三件套**（home → secret → terminal），不是只设 override？
- [ ] 进程级槽位的 key 是 `hermes_home_key()`，**release 用的是同一个 key**？
- [ ] 子进程 env 走 `served_profile_child_env` / `build_subprocess_env`，不是 `dict(os.environ)`？
- [ ] 新加的 `check_fn` 读凭证走 `get_secret`，缓存按 `(fn, scope)`？
- [ ] 新增的多 home 宿主调了 `set_multiplex_active(True)`？（否则所有 fail-closed guard 静默关闭）

### 11.3 prompt / 缓存相关

- [ ] 我的改动会在会话中途改历史 / toolset / 记忆 / system prompt 吗？
- [ ] 如果必须注入内容，走的是 user 消息或 tool 结果吗？
- [ ] 我改了 system prompt 或 tool schema 吗？→ `prompt_surface.py render` + 提交快照 + 需要 core approval
- [ ] 我保持了严格角色交替吗？（`/steer` 之外没有同角色连排）

### 11.4 工具相关

- [ ] handler 返回 JSON 字符串（或多模态信封）？
- [ ] `check_fn` 只回答可达性/opt-in，没有回答「什么界面」？
- [ ] schema 描述没点名别的 toolset 的工具？
- [ ] schema 描述路径用 `display_hermes_home()`，状态文件用 `get_hermes_home()`（调用时）？
- [ ] 教学类工具没有 `offset`/`limit`？
- [ ] 新后端是 sibling / 表条目，不是 `elif`？
- [ ] 接进了既有 setup UX（`hermes tools` / `hermes setup`），密钥进 `OPTIONAL_ENV_VARS`？

### 11.5 配置相关

- [ ] 新键进了 `DEFAULT_CONFIG`？新根键进了 `_KNOWN_ROOT_KEYS`？
- [ ] 有**一个**运行时读者？（`rg -n '<key>' --glob '!tests'` 能命中）
- [ ] 有文档？（否则 `check_docs_drift` 红）
- [ ] 写入走 `atomic_config_write` / `atomic_config_replace`？
- [ ] 我没有 bump `_config_version`（除非真的要迁移/变换）？
- [ ] 我在对的 loader 上？（CLI vs 子命令 vs gateway 运行时）

### 11.6 测试相关

- [ ] 用的是 `scripts/run_tests.sh`？
- [ ] 测试放在镜像源码的目录？
- [ ] 没写 `~/.hermes/`？`patch.object(Path, "home")` 时**同时**设了 `HERMES_HOME`？
- [ ] 宿主相关行为用了 `@pytest.mark.platforms(...)`（一个 marker 多个 spec），没有伪造 `sys.platform`？
- [ ] 不是 change-detector（没断言精确计数 / 模型清单 / `_config_version`）？
- [ ] 没读源码文本？
- [ ] 时间断言有界（≥ 2s）且用事件同步？
- [ ] **在基线上证明过它是红的**？

### 11.7 提交前

- [ ] `python scripts/check` 绿
- [ ] PR 已 rebase 到最新 `main`（**陈分支 squash 会静默回退更新的修复**）
- [ ] 依赖改动用 `hermes pm lock`，`uv.lock` 同 PR 提交
- [ ] 1~2 个不变量测试（不是 10 个浅测试）
- [ ] 动了符号？同 PR 修了 `website/docs` / `skills/` / 每个 `AGENTS.md` 的引用？
- [ ] 动了 prompt surface？快照已重生成并提交？

### 11.8 安全敏感改动

- [ ] 用户输入进 shell → `shlex.quote()`
- [ ] 访问控制前 → `os.path.realpath()` 解析 symlink
- [ ] 没记录 secret
- [ ] 碰了文件路径/进程 → 考虑 macOS / Linux / WSL2 / 原生 Windows，跑了 `scripts/check-windows-footguns.py`
- [ ] 如果是 §3.1 范围的漏洞 → **走私密渠道，绝不进公开 issue/PR/commit/comment**

---

## 12. 自检题（84 道）

> 用法：先不看答案。答不出的题，回对应小节。
> 分组与前面章节一一对应。

### A 组：三个词与四层结构（1-8）

1. 「不变量」的判据是什么？为什么它比「不会变的代码」更准确？
2. 规范（convention）和不变量的区别是什么？举一个只属于规范、不属于不变量的例子。
3. HX 编号是什么东西的 ID？去哪里查权威定义？
4. `RULES` 里 `source` 有哪三种取值？各自由谁执行？
5. `PS-P05` 和 `HX006` 的命名差异说明了什么？
6. 规则的「四层」是哪四层？为什么说「判断一条规则有多硬，看它在第几层」？
7. `AGENTS.md` 会在什么时候自动加载？加载的是**单个**文件还是**一条链**？
8. 规范太长放不下时的正确和解法是什么？为什么不是调大上限？

### B 组：AGENTS.md 与形状（9-16）

9. 一共有多少个 `AGENTS.md`？哪两个在 `apps/desktop` 下？
10. `ROOT_MAX_CHARS` 和 `CHAIN_MAX_CHARS` 各是多少？为什么根文件单独设上限？
11. `_MAX_HINT_CHARS` 为什么由脚本**读源码**取值而不是硬编码？
12. facade + siblings 的三条潜规则是什么？
13. 「在哪里被读，就在哪里 patch」讲的是什么？举个会静默失败的 patch 例子。
14. 为什么 sibling 必须**在函数体内** late-import facade？
15. 「内部路径不是 API」的推论是什么？为什么禁止加 re-export shim？
16. 行为代码该放 sibling 还是 facade？新测试该怎么放？

### C 组：HX 规则（17-32）

17. 列出全部 13 条 HX 的编号与一句话含义。
18. 哪四条 HX 默认**不**阻断（`blocking=WARN_UNTIL_REPLAYED`）？
19. `ENFORCEMENT` 主开关的值从哪个 revision 读？为什么？
20. 为什么 HX002 的检测器**连写 `os.environ[..] = ..` 也拦**？
21. `ctx.known_env` 从哪来？这个机制对老代码意味着什么？
22. HX003 检测器为什么要**排除 docstring / 裸字符串表达式**？
23. HX004 抓的确切 AST 形状是什么？为什么这个「防御性写法」是漏洞？
24. HX005 的 `_CAPTURE_CALLS` 里有哪些代表性函数？fix 给的两条合法出路是什么？
25. HX006 的 fix 里那两个独立的坑分别是什么？
26. HX009 为什么必须用 `BaseException` 而不是 `Exception`？
27. HX010 区分了哪三种「你真正想问的问题」？`is_truthy_value` 对「一个 API key」返回什么？
28. HX011 的作用域为什么连 `tests/` 都不排除？
29. HX012 的 fix 为什么强调「ContextVars do not cross a bare Thread」？
30. HX013 的 `include` 是 `TESTS`，意味着**非测试文件里的 `sleep` 不受管**——为什么这是合理的？
31. `SINGLE_PROFILE` 包含哪些 glob？为什么 `scripts/` 下的代码不受 profile 规则管？
32. HX001 的排除集为什么额外包含 `hermes_constants.py`？

### D 组：豁免与 ratchet（33-42）

33. `# noqa` 和 `# health: allow` 各管谁？为什么进 `RULES` 的 ruff 规则要改用后者？
34. 豁免的精确语法是什么（含分隔符）？
35. 为什么「字符串字面量里的 `health: allow`」不生效？这个设计堵的是什么？
36. `Hit` 的身份是什么？为什么**不是行号**？`code_line()` 做了什么归一化？
37. per-unit cap 的四格规则是什么（新单元 / 老单元超target / 老单元继续增长 / 老单元下降）？
38. 老单元从 40 降到 35 之后，能不能再回到 40？为什么？
39. `WARN_UNTIL_REPLAYED` 的「晋升为阻断」需要什么证据？`replay.py` 怎么产生它？
40. `replay.py` 的样本为什么「同一窗口永远选出同一批」？这个性质有什么用？
41. 「测不了的 PR」在 replay 里怎么处理？为什么不能算进分母？
42. `FileMeasure.error` 为什么必须让 check 失败，而不能读成「没发现」？

### E 组：CI 与 guard（43-52）

43. `scripts/check` 包含哪九个 `_GUARDS`、哪**一个** diff guard、以及哪两项？
44. 本地 `scripts/check` 绿是否等于全 CI 绿？举两个不在它里面的检查。
45. `no-tmp` 为什么把 `/tmp` 当跨平台 bug？正解是什么？哪些形态自动不报？
46. `config-writers` 的 docstring 说这个类「regressed several times」——这条信息对「要不要加 CI 检查」有什么启发？
47. `blob-size` 判的是什么？纯重命名会被判吗？豁免通道是什么？
48. `lazy-deps` 在「扫不到任何文件」时为什么也要 FAIL？
49. `os-marker-fakes` 抓的是哪种测试？为什么这种测试在 macOS lane 上「从未跑过」？
50. `prompt_surface.py` 把什么渲染进 committed 快照？为什么这么做（一次 prompt 变更变成什么）？
51. `check_public_surface.py` 的事据是什么（三个数字）？它的规则为什么「故意没有 allowlist 文件」？
52. hook 为什么要把每个候选**物化成临时树**再判？`checkout-index` 为什么带 `-f`？

### F 组：分类不变量（53-68）

53. 两条根铁律是什么？铁律 1 的完整例外清单有哪些？
54. 为什么 `/steer` 必须作为独立 user 行，而不能拼到那行 tool 结果上？
55. 哪些东西「看起来该进 system prompt」但实际上只能走 user 消息 / 一次性 note？
56. `check_fn` 绝不能回答什么问题？如果能力真的随会话变化，正确做法是什么？
57. gateway 的「双消息守卫」是哪两道？审批类命令为什么必须绕过两者并内联派发？
58. 流式四条各防止什么事故？第 3 条说的「两个出口」是哪两个？
59. 「接收适配器」和「交付适配器」为什么不能是同一个概念？读 `self.adapters[platform]` 会怎样？
60. multiplex 下 scoped miss 该返回什么？为什么绝不回退 `os.environ`？
61. 「作用域按 profile 活动绑，不按 turn」——列举至少四个 turn 之外需要绑定的路径。
62. cron 的 in-flight 状态为什么要 `(home, job_id)` 做 key？`release` 时为什么必须传 `home=`？
63. cron 归属为什么不由 `multiplex_profiles` 门控？那个 flag 门控的是什么？
64. kanban 的「board 是硬边界，tenant 是软命名空间」分别指什么？
65. 「后代 fence 是路径，不是 flag」具体是什么机制？为什么这样设计？
66. 插件的兼容契约为什么是「行为契约」而不是一个 `PLUGIN_API_VERSION` 常量？
67. `plugins.isolation: host` 的四条不变量是什么？
68. `hermes_platform` 为什么要区分 control host / 终端执行目标 / Desktop 客户端？

### G 组：测试与依赖（69-76）

69. 为什么必须用 `scripts/run_tests.sh`？它强制哪四项 CI 同构条件？
70. 「绝不伪造宿主 OS」的判据原话是什么？纯函数怎么办？`skipif` 和 `platforms()` 的分工？
71. 为什么裸 `skipif(sys.platform != "win32")` 会「在任何宿主上都不跑」？
72. change-detector 的判据（「读起来像什么」）是什么？给一个「该保留」的例子。
73. 为什么禁止在测试里读源码？如果逻辑就是内联在 god-file 里怎么办？
74. `patch.object(Path, "home", ...)` 时为什么**还必须**设 `HERMES_HOME`？
75. 依赖钉版的四条格式规则是什么？为什么裸 `>=X.Y.Z` 被拒？
76. `exclude-newer = "14 days"` 覆盖谁？插件受约束吗？

### H 组：判断与操作（77-84）

77. 「不是 bug」的四种形态是什么？
78. 判断一个修复前提是否成立的「三问」是什么？
79. `git log -p -S "<symbol>"` 的 `-S` 语义是什么？为什么它能同时找到「加入」和「删除」？
80. triage sweeper 只能用哪三个理由关闭？基于品味的关闭由谁决定？
81. 「不要加第二个 X」清单为什么有效？「extend the object」是什么意思？
82. 探测 profile 泄漏的标准测试形状是什么（两个 home + 什么断言）？
83. 为什么「测量失败」必须让检查失败？这个原则还能推广到哪些场景？
84. 一个 PR 已经 rebase 到 `main` 了，为什么仍然要求**合并前**再 rebase 一次？

---

## 答案要点

**A 组**

1. 判据是「**成立时无输出、违反时静默出错**」。比「不变的代码」准确，因为它描述的是**失败方式**，而不是代码是否被修改。
2. 规范是**形状**约束（sibling late-import、CC ≤ 20、dict→handler）；不变量是**行为**约束（角色交替、scope fail-closed）。§0.2 的例子：`elif` 阶梯是规范（它不一定产生错误结果，只是让 bug 更容易发生）。
3. code-health ratchet 的 lint 规则 ID；权威定义在 `scripts/code_health/config.py` 的 `RULES`。
4. `ruff`（pinned ruff）/ `ast`（自家检查器）/ `regex`（profile-scope 模式库，`pattern_id` 指向 JSON）。
5. `HX` 是「仓库特有、ruff 不管」；`PS-Pxx` 是「profile-scope 模式库里的编号」，规则 id 带 `PS-` 前缀但正则在外部 JSON。
6. config.py（RULES）→ scripts/check（机器）→ AGENTS.md（就近人读）→ 本文档（为什么/事故号）。硬不硬看它在不在第 2 层（机器）。
7. 在「你于对应目录工作时」自动加载；加载的是从 git 根到该目录的**整条链**，被当成**一个** project-context 块再按 6% context window 截断。
8. 拆文档（把长文移到 developer guide 或 sibling doc），**不是调大任何数字**——因为上限来自模型的 context window，不是你能改的。

**B 组**

9. 15 个：根 + `agent/` `apps/desktop/` `apps/desktop/src/` `cron/` `gateway/` `hermes_cli/` `hermes_platform/` `plugins/` `pm/` `skills/` `tests/` `tools/` `tui_gateway/` `web/`。
10. `12_000` / `30_000`。根文件在**每一条链**里，必须给子文件留空间。
11. 因为它同时被 `agent/subdirectory_hints.py` 使用；读源码保证「脚本的上限」和「运行时实际截断」**永不漂移**。
12. ①按主题 grep `<dir>/<stem>_*.py` ②siblings 函数体内 late-import facade ③在哪里被读就在哪里 patch。
13. sibling 在函数内 `from <facade> import name` 时，**facade 是 seam**；patch 定义模块会静默失效（因为生产代码读的是 facade 上的名字）。
14. 避免模块级循环 import（facade 会 import siblings 的公开面）。函数体内 import 在调用时才解析。
15. 内部路径随时可动；shim 会让「已删除的旧路径」看起来仍受支持，把内部重构变成永久兼容负担。移动符号 = 同 PR 修文档 + 改调用点。
16. 行为一律进 sibling（facade 只留公开入口和别人 import 的名字）；新测试放进**新的** `test_<stem>_<topic>.py`（避免推高老测试文件的 FILE_LINES）。

**C 组**

17. 见 §2.16 表。
18. HX001 / HX003 / HX010 / HX012（`WARN_UNTIL_REPLAYED`，当前 `False`）。
19. 从 **base**（main）读，不是从被测分支：CI 读 merge commit 的**第一父**，本地读 `origin/main`（回落 merge-base）。所以 PR 不能放宽自己的检查。
20. 因为「设置一个变量和读一个变量一样地引入了它」。只拦读的话，`os.environ["HERMES_X"] = ...` 会漏。
21. `gitio.known_env_names(repo, base)` 从**基线 revision** 扫出的所有 `HERMES_*` 字面量。老代码能继续用，新增的不行——这是 ratchet 而非一刀切。
22. 否则「描述这个模式的字符串」和「真的去执行 pgrep」分不清。检测器自己的 `_SHELL_IDENTITY` 元组就是数据，不是命令。
23. `except` 的 type 含 `UnscopedSecretError` + handler 体内任一环境变量读取。它是漏洞因为 `UnscopedSecretError` 意味着「multiplex 且未绑 scope」，此时 `os.environ` 是**启动 profile** 的值 → 把 A 的身份发给 B 的用户。
24. `get_hermes_home` / `display_hermes_home` / `load_config` / `load_config_readonly` / `read_raw_config` / `get_secret` / `getcwd` / `expanduser` / `_float_env` / `_int_env` / `_bool_env`；`Path.home` 也算。出路：①调用时解析 ②按 `hermes_home_key()` 给槽位做 key。
25. ①`proc.kill()` 后裸 `communicate()` 会在孙进程握管道时阻塞 → 用 `wait()` ②asyncio 的 `proc.communicate()` 必须包在 `asyncio.wait_for(..., timeout=...)` 里。
26. `asyncio.CancelledError` 在 3.8+ 继承 `BaseException`；用 `Exception` 判会把取消当正常结果（吞掉取消 / 把 CancelledError 当 payload）。
27. ①设了吗（`is not None`）②空串算没设置吗（`!= ""`）③flag 为真吗（`is_truthy_value`）。对 API key：**False**（不在 `{"1","true","yes","on"}` 里）。
28. 因为它是纯形状规则，测试文件的 fixture 同样会变成难维护的阶梯；`tests/scripts/test_code_health_rules.py:267` 的注释显示连 fixture 都要绕开它。
29. ContextVar 不跨裸 Thread → 后台线程拿到**空 context** → secret scope 为 None（fail closed 但错）+ terminal scope 为 None（静默用默认 backend）。
30. 非测试的 `sleep` 可能是**产品行为**（退避、轮询间隔、限速）——那是有意的；测试里的固定 sleep 才是 flake 源。
31. `TESTS + scripts/*, skills/*, optional-skills/*, evals/*, setup.py`。这些是「一次性、只服务单 profile」的进程，`os.environ` 就是它自己的 profile。
32. 因为那是**定义** `get_hermes_home()` 的地方，它必须碰 `.hermes`；`_get_profiles_root()` 也故意 HOME-anchored（profiles 根是所有 profile 的父，不属于任何一个）。

**D 组**

33. `# noqa` → ruff 原生；`# health: allow` → ratchet（含 `source="ruff"` 的条目）。进 `RULES` 后 ratchet 用 `--ignore-noqa` 跑 ruff，豁免权转交，因为新语法**强制写理由**。
34. `# health: allow <RULE> -- <why>`，分隔符是「空格 连字符 连字符 空格」。
35. 因为豁免只认**真注释 token**（`FileMeasure.comments`）。堵的是「为了让检查器闭嘴而批量生成豁免数据」。
36. 身份是 `Hit(rule, scope, code_line(line_no))` —— 代码文本（去注释、空白归一化）。不是行号，因为**上方插一行 import 不该让老债看起来像新债**。
37. 新单元按 target；老单元超 target 则 cap = 自己在 main 上的值；老单元只能降；降完 cap 变低、不能弹回。
38. 不能——**ratchet 只能往一个方向转**。
39. `python -m scripts.code_health.replay` 在最近合入的 PR 上重放，证明「大多数命中是真问题」（reviewer 样本精度 ~12%~60%）；把证据写进晋升的 PR。
40. 样本 = 闭区间内合入 main 的**所有** PR，按 **PR 号**排序。所以同一窗口永远同一批（新评论不会重排）。性质：可复现、可比较两个引擎版本（`--manifest`）。
41. 单列、不进总数和分母、并让整次 run **失败**（exit 1）。这样「0/N」的 N 永远是「真的测过的 N」。
42. 因为「查了没问题」和「没查成」必须分开；否则工具在关键时刻给你假的绿。

**E 组**

43. guards：`footguns` `shebangs` `no-tmp` `config-writers` `os-marker-fakes` `agents-md` `case-collisions` `lazy-deps` `profile-archives`；diff guard：`blob-size`；另两项：`ruff`、`health`。
44. 不等。例子：`check_profile_scope_patterns.py`（advisory）、`check_public_surface.py`（advisory）、`check_docs_drift.py`、`prompt_surface.py`+`test_prompt_surface.py`、`check_subprocess_stdin.py`（包成 pytest）。
45. Termux 没有 `/tmp`；原生 Windows 没这个目录；macOS 别名到 `/private/tmp`（破坏朴素路径比较）；多数 Linux 发行版它是 RAM-backed tmpfs（Hermes 负载下会填满）。正解：`get_scratch_dir()` → `HERMES_HOME/cache/scratch`，并导出 `TMPDIR`/`TMP`/`TEMP`。自动不报：`${TMPDIR:-/tmp}`、`/var/tmp`、`/private/tmp`、`tmpfs`、`tmp_path`、`~/tmp`、代码注释/docstring。
46. 说明「文档规则」不足以阻止回归——**每个新 writer 都会顺手选 plain dumper**。因此必须是 CI guard。
47. 判「**新增的字节**」：超 `MAX_BYTES` 的二进制（git 的 `--numstat` 打 `- -`）、或新增的超大文本文件。纯重命名/复制/回退到已 tracked 版本**不**判。豁免：`.github/blob-size-allowlist.txt`（精确路径，CODEOWNERS 审）。
48. 因为「什么都没扫 → 通过」是最危险的假绿（inventory 建不起来时你也「没发现违规」）。
49. 抓「伪造 macOS 但没 `platforms("macos")` marker」的测试。OS lane 用 `list_os_marked_tests.py` 解析 marker 决定 **import 哪些文件**，没 marker 的文件根本不被 macOS lane import → 在 Linux 上用伪造分支绿，在真 macOS 上从未跑。
50. system prompt（生产代码 `build_system_prompt_parts` 组装）+ `tools[]` 数组。于是「一次 prompt 变更」变成**可 review 的真实 prompt 文本 diff**，且需要 core approval。
51. 1,703 个公开顶层名（341 模块）、1,000 个公开方法（166）、130 个 `def test_`（54 文件）。没有 allowlist 因为「维护一个 allowlist 本身就是负担」，规则足够窄就不需要。
52. 因为 hook 被所有 worktree 共享，当前 checkout 的分支不能决定任何事；必须由**每个候选自己的** `scripts/check` 判。`-f` 因为 case-collision guard 读的是 **index**，不带 `-f` 时第二个同名文件会在 checkout 阶段就 abort。

**F 组**

53. ①逐会话 prompt caching 神圣（唯一例外压缩）②核心窄腰、能力长在边缘。例外清单：压缩、追加 user 消息/tool 结果、`/steer` 独立 user 行、skill slash 命令以 user 消息注入、一次性 note。
54. 因为持久化是 **append-only**；拼到已持久化的 tool 行上，会让「磁盘历史」和「实际发出的请求」永久不一致。
55. 装新 skill 后的可用列表、目录提示、任何「状态变了要告诉模型」的东西 → user 消息或一次性 note。
56. 绝不回答「**什么界面 / 谁在看**」。能力真的随会话变化 → 命名 toolset + `_load_enabled_toolsets(platform)`（surface 是 SESSION 的属性）。
57. ①base adapter 用 `_pending_messages` 排队（`session_key in _active_sessions`）②runner 在 `running_agent.interrupt()` 前拦截 `/stop /new /queue /status /approve /deny`。审批必须绕过因为 agent 正被阻塞——走 `_process_message_background()` 会和 session 生命周期赛跑。
58. ①非前缀帧 → 堆叠副本 ②封口后改 final → 重复发送 ③中途发送没标记 → 用中途文本封口 ④不用 edit → 与已封口流并行时发重复。两个出口：`send()` 与 `send_for_platform()`。
59. 接收 = 谁收到这个事件（进 intake 策略：忽略频道、relay fronting、重派发）；交付 = 谁回答（通常就是接收方，否则 `(platform, runtime_profile)` 的唯一 owner）。读 `self.adapters[platform]` 会拿到 launch profile 的 adapter → B 的回复发到 A 的 bot；restored source 会「按启发式回落到 default bot」。
60. 返回 **default**（`extra_or_secret` 的默认值），绝不 `os.environ`。因为 `os.environ` 装的是 default profile 的值；泄漏一个 allowlist 会跳过 allow-all 检查并**静默拒掉**所有二级 profile 的发送者（#86905）。
61. 释放/驱逐（`_run_release_in_profile_scope`）、shutdown（`_finalize_session`）、turn 后媒体交付（`_media_delivery_scope`）、延迟回调（picker/reaction）、notifier、出站 webhook、cron tick、RPC 方法、线程跳、子进程 spawn。
62. 两个 profile 合法地都有 `daily-brief`；`release_running_job(job_id, home=...)` 因为池 worker 的 `finally` 在 `ctx.run` **之外**执行，会解析到**启动** home → 每个二级 profile 的 claim 泄漏（跳过窗口直到 force-release 扫掉，drain 看到幻影工作）。
63. 因为 flag 门控的是 **adapter**；一个 host gateway 无论如何 tick 每个 profile 的 store。把它门控到 flag 上会让「所有非启动 profile 的 job 待在一个没有 ticker 访问的 store 里」。
64. board = 硬边界（worker 环境钉 `HERMES_KANBAN_BOARD`，看不到别的 board）；tenant = board 内的软命名空间（workspace 路径 + memory key 隔离，一个 fleet 服务多家公司）。
65. `DELEGATED_CHILD_ENV_MARKER` 携带被围的 board **ROOT**；`kanban_path_is_fenced(path)` 只拒 dispatcher 钉的 `HERMES_KANBAN_DB` 或该 root 之下。这样在 scratch `HERMES_HOME` 里工作的子代理**保留可写 board**。
66. 因为 surface 是**加法**的：hook payload 加 keyword 字段、`PluginContext` 方法不删不改名、未知 manifest 字段忽略、新 provider 方法有默认实现。一个全局版本号会让「加一个字段」变成 breaking。
67. ①每条 user-code import 路径都路由到 host 或拒绝 ②不能跨的东西是**一张表**（`HOST_UNSUPPORTED_CTX_METHODS`，运行时拒绝与静态审计同读）③host 不 spawn host，且不在「模块 import 持锁」时启动 ④隔离方不能在 operator pin 时自己 opt out（走 managed overlay 读）。
68. 因为 `host.*` 只回答**跑这段 Python 的机器**；SSH/容器里的终端目标、另一台机器上的 Desktop 客户端都是不同机器，混用会导致「在 mac 上检查 linux 容器的路径」。

**G 组**

69. 强制：清空凭证变量、`TZ=UTC`（+ `LANG=C.UTF-8`）、`HERMES_HOME` → 临时目录、**按文件子进程隔离**（module 级 dict / ContextVar 不跨文件泄漏）。
70. 「如果测试需要解释器相信自己不在这个 OS 上才能通过，它就该在那个 OS 上（跑）」。纯函数：把平台当**数据**传入。`skipif` 只留给非宿主的条件（如 `os.geteuid() == 0`）；宿主一律 `platforms()`。
71. OS lane 用 `list_os_marked_tests.py` 解析 `platforms(...)` 决定 import 哪些文件；裸 `skipif` 的文件不会被那个 lane import，而全量 lane 又会 skip 它。
72. 「读起来像快照就删；读起来像两份数据之间的契约就留」。该留的例子：`assert raw["_config_version"] == DEFAULT_CONFIG["_config_version"]`（迁移到达最新）；`assert not (set(moonshot_models) & coding_plan_only_models)`（无泄漏）。
73. 读文本测的是**源码形状**：实现微妙坏了它仍可能过，正确的重构会让它失败，还挡结构性清理。逻辑在 god-file 里内联 → **那就是抽取的信号**，不是绕着它写正则。
74. 因为代码读的是 env var（`HERMES_HOME`），不是 `Path.home()/.hermes`；只 patch `Path.home` 不会改变 `get_hermes_home()` 的结果。
75. PyPI `>=floor,<next_major`；pre-1.0 `<0.(minor+2)`；git URL 40 字符 SHA；Actions SHA + `# vN`；CI-only Python 依赖 `==exact`。`>=` 不设上界防不住「上游发 breaking major」（litellm 投毒 #2796/#2810、Mini Shai-Hulud 蠕虫）。
76. 只覆盖**核心自己的依赖**（core `uv.lock` 里每个 registry 包）。插件走插件自己的策略；PM 生成插件 workspace 时把全局 cutoff 移到每个 core-locked 包上，所以插件专属包不被过滤，而插件仍不能把 core 包拖出窗口。

**H 组**

77. ①intentional design, not a gap ②前提不成立（复现不了 / 新分支永不执行）③缺失是故意的（load-bearing absence）④越界或复活已被否的方向。
78. ①能在当前 `main` 复现吗 ②能指出 bug 显现的**那一行**吗 ③你的修改改变了那一行的行为吗。
79. pickaxe：找「这个字符串的出现次数变化」的提交。所以加入和删除都命中——而「被删过」正是你需要的信息（有人专门删它，可能带理由）。
80. `implemented_on_main` / `cannot_reproduce` / `incoherent`；基于品味的关闭是 **maintainer 的判断**，有疑问时 PR 保持打开。
81. 因为它防的是**漂移**：第二个实现刚写时通常对，问题在 6 个月后有人只改了其中一个。「extend the object」= 给唯一那个对象加字段，而不是在旁边再写一个解析器。
82. 两个磁盘 home + 一个只存在于 secondary 的 `.env` 名；断言「secondary 的值解析出来」「launch 的值解析不出来」「`os.environ` 事后未变」。
83. 因为「查了没问题」和「没查成」混在一起会产出假绿。可推广到：覆盖率、迁移脚本、健康检查、任何「样本为空即通过」的循环。
84. 因为从**陈旧分支** squash 会**静默回退**更新的修复——Git 不会告诉你「你的分支缺了 main 上那 20 个提交」，它只会把你的版本当成最终结果。

---

## 13. 小结（九句）

1. **不变量**是「成立时无声、违反时静默出错」的约束；它们必须写下来，因为测试只覆盖想到的路径。
2. 规则有**四层**：`config.py`（机器单点）→ `scripts/check`（机器执行）→ `AGENTS.md`（就近人读）→ 本文档（为什么）。判硬度看层。
3. **HX001~HX013** 是 lint 规则 ID，不是章节号；权威定义只有 `scripts/code_health/config.py` 一处，13 条各自都能精确到 AST 形状。
4. **豁免要写理由**：`# health: allow <RULE> -- <why>`，只认真注释；ratchet 用 `--ignore-noqa` 跑 ruff，所以 `# noqa` 在这里无效。
5. **ratchet 是棘轮**：老债按代码指纹记账，只能降不能升；「测不了」永远失败，绝不读成「没问题」。
6. **规则晋升要证据**：`WARN_UNTIL_REPLAYED` + `replay.py` 在已合入 PR 上重放，证明命中大多是真问题。
7. **最强架构信号是「不要加第二个 X」**：第二个 resolver / reader / writer / parser / 身份判断，都会在半年后漂移。正解是 **extend the object**。
8. **缺失常常是设计**：先读 `AGENTS.md`，再 `git log -p -S`，再找事故号，最后才问。三问未过（能复现 / 指得出那一行 / 修改改变了那一行）就别写代码。
9. **提交前 60 秒**扫 §11.1 那七条；有 profile 涉及的，再扫 §11.2 那六条；其余按 §11 的清单走。

## 60 秒口述版

> Hermes 的规范分四层：`scripts/code_health/config.py` 是机器可执行的单点规则表（HX001~HX013 加两条 PS），
> `scripts/check` 把九道 guard、pinned ruff 和尺寸 ratchet 跑成与 CI 同构的一条命令，
> 各目录的 `AGENTS.md` 是就近人读的形状规范，而长文和事故号在 developer guide 和本文档里。
>
> 两条根铁律：**逐会话 prompt caching 神圣**（唯一例外压缩），**核心是窄腰、能力长在边缘**（Footprint Ladder）。
>
> 机器拦得住的是形状：别新增 `HERMES_*` env（HX002）、别在 import 时捕获 home/config/env（HX005）、
> 别用裸线程（HX012）、别在 `except UnscopedSecretError` 里回退 `os.getenv`（HX004）、
> 别写 if/elif 阶梯（HX011）、子进程要有 timeout（HX006）、测试里别墙钟 sleep（HX013）。
> 豁免必须写成 `# health: allow <RULE> -- 理由`。
>
> 机器拦不住、靠 review 的是行为：角色严格交替、流式四条（前缀稳定 / 消费方声明最终 / 中途发送带标记 / 用 edit 对账）、
> 双消息守卫、身份只解析一次、intake≠delivery、multiplex 下 scoped miss 返回 default 绝不回退 `os.environ`、
> 作用域按 profile 活动绑而不是按 turn、cron 的 in-flight 按 `(home, job_id)` 记账且 claim 用注册时的 key 释放。
>
> 遇到「这里好像没写完」，**先假定它是设计**：读 AGENTS.md → `git log -p -S` → 找事故号 → 再问。
> 提 PR 前跑 `python scripts/check`，rebase 到最新 `main`，带 1~2 个在基线上证明过是红的不变量测试。

---

## 索引

- **想看条目定义** → §2（HX 全表）
- **想看某目录的规范** → §3（A~L 类）+ §1.1 的 15 文件表
- **想查某条 CI 检查为什么存在** → §5.3
- **想理解 ratchet 语义** → §6
- **想避免「第二个实现」** → §7
- **想知道某症状去哪找** → §8
- **想判断这是不是 bug** → §9
- **想验证某类不变量** → §10
- **要改代码** → §11（清单）
- **要检验自己** → §12（84 题）+ 答案要点

前序篇目：
[`01 架构总览`](01-architecture-overview.md) ·
[`02 入口`](02-entrypoints.md) ·
[`03 Agent 核心`](03-agent-core.md) ·
[`04 Prompt 与缓存`](04-prompt-and-caching.md) ·
[`05 工具系统`](05-tools-system.md) ·
[`06 Provider 运行时`](06-provider-runtime.md) ·
[`07 状态与会话`](07-state-and-session.md) ·
[`08 记忆/上下文/压缩`](08-memory-context-compression.md) ·
[`09 网关与平台`](09-gateway-and-platforms.md) ·
[`10 四个前端面`](10-surfaces-cli-tui-desktop-web.md) ·
[`11 插件/技能/MCP`](11-plugins-skills-mcp.md) ·
[`12 Cron 与 Kanban`](12-cron-and-kanban.md) ·
[`13 子代理与委派`](13-subagents-delegation.md) ·
[`14 Profile 与多路复用`](14-profiles-and-multiplex.md)
