# 02 · 入口点与运行形态

> **读法**：这一篇回答第一个具体问题：**「`hermes` 这个命令敲下去，操作系统到底启动了谁？」**
> 顺序是：**§0 前置**（入口是什么、为什么有 6 个）→ **§1 三个可执行命令** → **§2 `hermes` 的启动序列**
> （本篇最长、最重要）→ **§3 子命令体系** → **§4~§8 五条分支路径** → **§9 其它入口** → **§10 对照表**
> → **§11 陷阱** → **§12 自检**。
>
> 读完你应该能回答：**「`hermes --tui` 和 `hermes gateway run` 差在哪一步分叉？各自有几个进程？」**

**本篇相对旧版新增**：§0 前置概念、§2 逐行启动序列（含 4 条快速通道）、§3 子命令的表面/内核分界、
§5 TUI 的环境变量契约表、§7 PTY 桥的字节协议、§10 十二维对照表、§11 六个常见误判。

---

## 0. 前置概念

### 0.1 什么是「入口点」

Python 项目不像前端有 `index.html`。用户敲的 `hermes` 是**安装时写进 `bin/` 的一个小脚本**，
它只做一件事：`import 某个模块，调用某个函数`。这个「模块:函数」的映射就写在
[`pyproject.toml`](../pyproject.toml:557) 的 `[project.scripts]` 里：

```toml
[project.scripts]
hermes       = "hermes_cli.main:main"    # 主命令
hermes-agent = "agent.legacy_cli:main"   # 历史入口
hermes-acp   = "acp_adapter.entry:main"  # 编辑器集成
```

前端类比：**这就是 `package.json` 的 `"bin"` 字段**。`npm i -g` 之后 `mycli` 能跑，
和 `pip install` 之后 `hermes` 能跑，是同一个机制（生成一个带 shebang 的 wrapper）。

**关键推论**：`hermes` 这个名字背后**没有魔法**。所有行为的起点都是
[`hermes_cli/main.py`](../hermes_cli/main.py:3519) 的 `main()`。想知道「某功能从哪进」，
先看这个函数，别在 `cli.py` 里瞎翻。

### 0.2 入口层只做四件事

这是全仓库最硬的边界之一（[`01-architecture-overview.md`](01-architecture-overview.md) §2.2 已给出）：

```text
解析参数  →  准备 profile / 配置  →  构建或复用 AIAgent  →  渲染结果
```

两条禁止：

| 禁止 | 为什么 | 反例（如果有人这么写） |
|---|---|---|
| agent 行为下沉到入口层 | 6 个入口会各写一遍，行为发散 | 在 `cmd_chat` 里手动拼 system prompt |
| 渲染逻辑上浮到 agent | `AIAgent` 就不知道什么叫「终端」了 | 在 `conversation_loop` 里 `print()` 彩色文字 |

那「工具执行到一半」这种进度怎么告诉界面？**回调注入**。
`AIAgent.__init__` 收一大类 callback（`stream_delta_callback`、`tool_progress_callback`、
`clarify_callback`……），内核只负责调 `self.xxx_callback(...)`，怎么显示由外壳决定。
详见 [`01-architecture-overview.md`](01-architecture-overview.md) §2.2。

### 0.3 为什么非要 6 个入口

因为**内核对「用户在哪」一无所知**，而「用户在哪」决定了三件事：进程模型、I/O 协议、生命周期。

| 用户在哪 | 输入是 | 输出是 | 进程活多久 |
|---|---|---|---|
| 终端 | 键盘（prompt_toolkit） | 终端 ANSI | 用户退出为止 |
| Telegram | webhook / 长轮询 | 平台 API | 常驻（systemd） |
| VS Code | stdio JSON-RPC | stdio JSON-RPC | 编辑器会话 |
| 桌面应用 | Electron IPC → WebSocket | 同左 | 随 app 关 |
| Dashboard 浏览器 | xterm.js 字节流 | 同左 | 随标签页 |
| 批量脚本 | JSONL 文件 | JSONL 文件 | 跑完就退 |

内核对这 6 行**一行都不用改** —— 这就是「核心窄腰、能力长在边缘」（[`01-architecture-overview.md`](01-architecture-overview.md) §4.2）。

### 0.4 进程拓扑速查

先记住这张表，后面所有细节都挂在这上面：

| 入口 | Python 进程数 | 额外进程 | 通信方式 |
|---|---|---|---|
| `hermes`（经典 CLI） | 1 | 0（工具子进程另算） | 进程内函数调用 |
| `hermes --tui` | 1（`tui_gateway`）+ 1（Node） | 0 | stdio 换行 JSON-RPC |
| `hermes gateway run` | 1（常驻） | 0 | 平台 SDK 回调 |
| `hermes serve` | 1（`serve` 后端） | 1（Electron，另起） | WebSocket / HTTP |
| `hermes dashboard` | 1（web server） | N（每个 `/api/pty` 一个 PTY 子进程） | WebSocket + PTY 字节流 |
| `hermes acp` | 1 | 0 | stdio JSON-RPC |

---

## 1. 三个可执行命令

### 1.1 `hermes` — 唯一的主入口

[`hermes_cli/main.py`](../hermes_cli/main.py:3519) 的 `main()` 是**所有分支的总闸**：
CLI、TUI、gateway、dashboard、serve、ACP、cron、约 60 个子命令，全部从这里出去。

为什么不做成多个 script？因为**启动期的脏活必须只做一次**（见 §2.1）：进程标题、UTF-8、
TLS 根证书、字节码清理、更新欠账恢复。多入口就会重复实现、逐渐漂移。

### 1.2 `hermes-agent` — 历史入口，仍可用

[`agent/legacy_cli.py`](../agent/legacy_cli.py:60) 的 `main(argv=None, *, run=None)` 是一个**极薄的参数壳**：

```python
def main(argv=None, *, run=None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    positional = " ".join(args.prompt).strip()
    query = args.query or positional or None
    if query is None and not args.list_tools:
        parser.print_help()
        return 0
    if run is None:
        from run_agent import main as run   # ← 延迟到真的要用才 import
    run(...)
```

注意两点，都很有教学价值：

- **`run` 参数可注入**：`python run_agent.py` 会把自己的 `main` 传进来，避免同一模块被 import 两次。
  这是「可测试的入口」的标准写法。
- **没有任何 flag 就不跑**：直接打印 help 返回 0，不会意外开一个会话。

它**不经过** `hermes_cli/main.py`，所以不做 §2.1 的启动期清理。这就是「legacy」的含义：
能用，但不再是推荐路径。

### 1.3 `hermes-acp` — 编辑器集成

[`acp_adapter/entry.py`](../acp_adapter/entry.py:163) 的 `main()` 自己处理 `--version` / `--check` /
`--setup` / `--setup-browser` 四个元操作，然后：

```python
_setup_logging()   # 日志必须走 stderr
_load_env()

# Ensure the project root is on sys.path so ``from run_agent import AIAgent`` works
project_root = str(Path(__file__).resolve().parent.parent)
if project_root not in sys.path:
    sys.path.insert(0, project_root)

# This console script bypasses hermes_cli.main, which does the same.
from agent.ssl_verify import install_truststore
install_truststore()
```

**`bypasses hermes_cli.main, which does the same` 这行注释是本篇的缩影**：凡是绕过 `main()` 的入口，
都必须自己补上 `main()` 做过的那几件事（TLS、UTF-8、profile）。漏一个就是一类线上 bug。
`hermes-acp` 补了 TLS，说明它被踩过。

ACP 的协议细节见 [`website/docs/developer-guide/acp-internals.md`](../website/docs/developer-guide/acp-internals.md:1)，
本篇 §8 只讲入口侧。

---

## 2. `hermes` 的启动序列（逐行）

这一节按 [`main()`](../hermes_cli/main.py:3519) 的**真实执行顺序**展开。**顺序本身就是设计**，
很多注释都在解释「为什么必须在这里」而不是别处。

### 2.1 阶段 A：进程自愈（无参数、无配置、不 import 重型模块）

```python
def main():
    _set_process_title()          # 1
    _warn_if_unsupervised_pid1()  # 2
    _advertise_agent_env()        # 3
```

| 步骤 | 做什么 | 为什么在这里 |
|---|---|---|
| [`_set_process_title()`](../hermes_cli/main.py:210) | 让 `ps`/`top` 显示 `hermes` 而不是 `python3.13` | 纯装饰，但必须**第一件事**：之后任何 fork 都继承新名字 |
| `_warn_if_unsupervised_pid1()` | 容器里 PID 1 且无 init 时告警 | 用户会在 Dockerfile 里写 `CMD ["hermes", "gateway", "run"]`，僵尸进程无人回收 |
| `_advertise_agent_env()` | 标记「我是 agent 环境」 | 让子进程/工具知道自己被 agent 驱动 |

`_set_process_title` 的降级链值得一读（三档，全都不抛异常）：

```python
try:
    import setproctitle; setproctitle.setproctitle("hermes"); return
except ImportError:
    pass
# Linux: ctypes prctl(PR_SET_NAME) —— 只改 15 字符的 comm
# macOS: pthread_setname_np —— 只影响 lldb/top，不影响 ps aux
# Windows: no-op（.exe 本来就叫 hermes.exe）
```

**「Never fatal」** 是这里的设计要求：装饰性功能绝不能拦住真正的启动。

接着是环境修复：

```python
from hermes_cli.stdio import configure_windows_stdio
configure_windows_stdio()                      # Windows 强制 UTF-8，其他平台 no-op

from hermes_cli import _stdio_repaired
if _stdio_repaired:                            # 只在「本机 locale 坏到必须修」时才真做
    os.environ.setdefault("PYTHONUTF8", "1")
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")

from agent.ssl_verify import install_truststore
install_truststore()                           # 统一 TLS 信任源，Never raises
```

`_stdio_repaired` 那个 `if` 是本仓库的典型风格：**只在坏环境上动手**。
健康的 UTF-8 主机完全不会继承 `PYTHONUTF8`，也就不会改变用户子进程的行为。

### 2.2 阶段 B：安装环境自愈

```python
_cleanup_quarantined_exes()                   # Windows 更新残留的 hermes.exe.old.*
_sweep_stale_bytecode_if_checkout_changed()   # checkout 变了 → 清一次 __pycache__
_recover_update_debts_on_startup()            # 「上次更新欠下的重启」
```

三条都在治同一类病：**原地升级留下的不一致状态**。

- 第 2 条为什么必要？因为 `__pycache__` 是按 `(mtime, size)` 校验的，而 `git checkout` 会让
  **源文件 mtime 变新但内容相同**、或者**内容变了但 mtime 因批量操作变得相同**。后者会复用旧字节码，
  症状是「改了代码但没生效」，且极难 debug。所以这里用「checkout 指纹变了就全量清一次」的粗粒度方案。
- 第 3 条「update debt」：更新过程中被 kill 的 gateway 需要重启。这是一个**持久化的待办列表**，
  不是内存重试 —— 因为跨进程、跨重启。

然后（注意这个例外）：

```python
if _first_positional_argv() != "update":
    maybe_run_boot_bootstrap(install_root())   # 自举依赖
```

**`hermes update` 要跳过 bootstrap**。理由很直白：`update` 的工作就是修环境，
如果 bootstrap 觉得环境不对先去装东西，可能把「正在更新的环境」改坏。**自指操作要排除自己**。

### 2.3 阶段 C：依赖体检 + 4 条快速通道

```python
from hermes_cli.venv_sync import check_runtime
problem = check_runtime(install_root())
if problem:
    print(f"⚠ {problem}", file=sys.stderr)     # 只警告，不拦
```

「只警告不拦」是刻意选择：**包管理器出问题不该让用户连 `hermes --version` 都跑不了**。

接下来是四条快速通道，**顺序有意义**：

```python
if _try_termux_fast_tui_launch():  return   # 手机 TUI
if _try_termux_fast_cli_launch():  return   # 手机 CLI / --version / oneshot
if _try_fast_serve_launch():       return   # 桌面冷启动
if _try_fast_chat_launch():        return   # 普通交互 chat
```

为什么要快速通道？[`_try_fast_chat_launch`](../hermes_cli/main.py:3160) 的 docstring 给了数字：

> Building all ~40 subcommand parsers costs **~140ms** the chat path never uses.

140ms 在交互式启动里是能感觉到的（终端提示符延迟）。所以做法是：
**用一个只含 chat 参数的小 parser（[`_light_chat_parser`](../hermes_cli/main.py:3106)）先试；**
**只要有一点不确定，就返回 `False`，走完整路径。**

四条通道的「不确定」判定几乎一样，这是刻意的对称：

| 通道 | 触发条件 | 必须放弃（返回 False）的情形 |
|---|---|---|
| [`_try_termux_fast_tui_launch`](../hermes_cli/main.py:3267) | Termux + TUI | `-h/--help`、非 chat 子命令、解析后不想开 TUI |
| [`_try_termux_fast_cli_launch`](../hermes_cli/main.py:3212) | Termux + CLI | `-h`、TUI 请求、非 chat 且无 `--oneshot` |
| [`_try_fast_serve_launch`](../hermes_cli/main.py:3121) | `argv[0] == "serve"` | 有 `-h`、有容器路由、出现未知参数 |
| [`_try_fast_chat_launch`](../hermes_cli/main.py:3160) | 任意平台 chat | `-h`、容器路由、TUI 请求、首个位置参数不是 `chat`/空 |

**四条通道都先检查容器路由**，注释写得很明白：

```python
# Container routing must win: NixOS container mode forwards EVERY invocation.
if get_container_exec_info():
    return False
```

因为容器模式要把**所有**调用（包括 `--help`、拼错的 flag）转发进容器，
让宿主 argparse 先吃掉参数就错了。

每条通道都有逃生阀：`HERMES_DISABLE_FAST_CHAT_LAUNCH=1` 等。
**性能优化永远要能关掉**，否则它变成一个无法复现的幽灵 bug 源。

> 注意 `_try_fast_*` 命中后**直接 `return`**，不会设 `set_process_surface()`。
> 这是一个真实的取舍：快速通道省掉了整个 CLI 树，也省掉了观测标记。

### 2.4 阶段 D：完整解析

```python
parser, subparsers = _build_cli_parser()

# NixOS 容器模式：必须在 parse_args 之前
container_info = get_container_exec_info()
if container_info:
    from hermes_cli.main_container import exec_in_container
    exec_in_container(container_info, sys.argv[1:])
    sys.exit(1)   # 不可达：execvp 替换进程或抛异常

args = _parse_cli_args(parser, subparsers, sys.argv[1:])
```

[`_parse_cli_args`](../hermes_cli/main.py:3474) 是为 **CPython bpo-9338** 打的补丁，
文档里只有一行但信息密度很高：

```python
"""Parse ``argv`` with the bpo-9338 subparser-routing workaround.

On Python <3.11 argparse fails to route subcommand tokens when the parent
has nargs='?' optionals (--continue): "unrecognized arguments: model".
When argv holds a known subcommand token, set subparsers.required=True to
force routing; if that fails (``hermes -c model`` — 'model' is the session
name) fall back to the default behaviour.
"""
```

翻译成人话：`hermes -c model` 里的 `model` 是**会话名**，不是 `hermes model` 子命令；
但 `hermes model` 又确实是子命令。两者的 argv 形状一模一样，argparse 只能靠「有没有已知子命令 token」
+「强制 required 会不会报错」这两步猜。**这是 CLI 设计里经典的歧义**，这里选择了「先按子命令解释，
失败再按会话名解释」。

### 2.5 阶段 E：分发

```python
if args.version:
    cmd_version(args); return

# --yolo 必须在 plugin discovery 之前
if getattr(args, "yolo", False):
    os.environ["HERMES_YOLO_MODE"] = "1"

_prepare_agent_startup(args)

if getattr(args, "oneshot", None):
    _run_oneshot_from_args(args)

from hermes_cli.observability.shared_metrics_disabled import set_process_surface
set_process_surface(args.command)

if args.command is None:
    _default_to_chat(args); return

if hasattr(args, "func"):
    rc = args.func(args)
    if isinstance(rc, int) and rc != 0:
        sys.exit(rc)
else:
    parser.print_help()
```

四件事值得单独说：

**① `--yolo` 的时序**。源码注释：

```python
# --yolo must be set *before* plugin discovery: tools.approval freezes
# _YOLO_MODE_FROZEN at import; set later (inside cmd_chat) it does nothing.
```

这是 **「import 即固化」** 的典型陷阱：`tools/approval.py` 在模块顶层读一次环境变量存成常量。
之后改 `os.environ` 完全无效。所以必须「在任何 import 之前设好」，且 `cmd_chat` 里又设一遍作为
**安全网**（因为有人会直接调 `cmd_chat`）。

**② [`_prepare_agent_startup`](../hermes_cli/main.py:2928) 的开关条件**：

```python
if not (args.command in _AGENT_COMMANDS or _agent_subcommand_selected(args)):
    return
```

其中：

```python
_AGENT_COMMANDS  = {None, "chat", "acp", "rl"}
_AGENT_SUBCOMMANDS = {
    "cron":    ("cron_command",    {"run", "tick"}),
    "gateway": ("gateway_command", {"run"}),
    "mcp":     ("mcp_action",      {"serve"}),
}
```

含义：**只有「可能跑一个 agent turn」的命令才做插件/MCP/hook 发现**。
所以 `hermes hooks list`、`hermes cron list`、`hermes gateway status` 这类内省命令
**零发现成本、零 hook 同意弹窗**。源码注释：

> gated so introspection commands ... pay no discovery cost and trigger no consent prompts
> for hooks the user is still inspecting.

这是很好的产品直觉：**你在看配置的时候，配置不该反过来动你**。

**③ `_is_tui_chat_launch` 与「双重 MCP 发现」**。TUI 后端会自己做 MCP 发现，
所以 launcher 不能再做一遍。注释记录了一个真实事故：

```python
# Bare `hermes`/`hermes chat` with a TUI display config was previously missed
# here, so the wrapper pre-warmed its own MCP discovery while the TUI
# gateway (spawned moments later) ran a second one — an idle stdio MCP
# server copy held dead for the whole session.
```

**两个进程各发现一次 → 一个 stdio MCP server 实例白占一整个会话。** 这类 bug 不会报错，
只会让用户觉得「MCP 有点慢/内存有点高」。

**④ 退出码约定**：

```python
# A handler's int return code becomes the exit code (None = success).
```

`None` = 0，`int` = 退出码。这让 handler 可以完全不碰 `sys.exit`，可测试性好得多。

### 2.6 阶段 F：没有子命令 → chat

```python
def _default_to_chat(args) -> None:
    """No subcommand given: run chat."""
    _promote_top_level_resume(args)   # 顶层 --resume/-c 提升成 chat 参数
    _set_chat_arg_defaults(args)
    cmd_chat(args)
```

所以 `hermes`、`hermes -c`、`hermes --resume abc` 三者等价于 `hermes chat ...`。
**裸命令就是最常用命令**，这是 CLI 的通用惯例（`git` → 无、`docker` → help、`hermes` → chat）。

另外 `main()` 里还有一句：

```python
if (args.resume or args.continue_last) and args.command is None:
    args.command = "chat"
```

它在分发**之前**就把 `command` 补成 `"chat"` —— 目的是让
`set_process_surface(args.command)` 和 `_prepare_agent_startup` 看到正确的 surface。
**参数归一化要早于依赖它的判断**。

---

## 3. 子命令体系

### 3.1 规模

| 指标 | 数量 | 验证方式 |
|---|---|---|
| `hermes_cli/subcommands/*.py` 文件 | 65 个 | `ls hermes_cli/subcommands/*.py \| wc -l` |
| `build_*_parser` 函数 | **65 个**（一个文件一个 parser） | `grep -c "^def build_.*_parser" hermes_cli/subcommands/*.py` |
| 斜杠命令 `CommandDef` | 103 条 | `grep -c "CommandDef(" hermes_cli/commands.py` |

`hermes_cli/main.py` 里 **没有一条 `add_argument`**（`grep` 结果为 0）。
这是刻意的：**参数定义全部下沉到 `subcommands/<topic>.py`**，
`main.py` 只保留 `build_*_parser` 的 import 列表和调度逻辑。

前端类比：`main.py` ≈ `router/index.ts`（只做路由表），`subcommands/*.py` ≈ 每个 route 的页面。
路由文件里不该写业务逻辑。

### 3.2 三层调度

看清这三层，就不会在错误的地方找代码：

```text
第 1 层  console script    →  hermes_cli.main:main
第 2 层  argparse dispatch →  args.func(args)         （set_defaults(func=cmd_xxx)）
第 3 层  业务实现          →  hermes_cli/<topic>.py 或 hermes_cli/subcommands/<topic>.py
```

`cmd_xxx` 通常**极短**，只做「参数搬运 + 延迟 import」。
例如 [`cmd_gateway`](../hermes_cli/main.py:1839)：

```python
def cmd_gateway(args):
    _sync_bundled_skills_quietly()
    from hermes_cli.gateway import gateway_command
    ...
```

`_sync_bundled_skills_quietly()` 是「顺手把 bundled skills 同步一下」，不阻塞、不报错。
然后**才** import 真正的实现 —— 因为 `hermes_cli.gateway` 会拉进进程管理、systemd 生成等一大堆东西。

### 3.3 子命令分类（按「会不会跑 agent」）

| 类别 | 代表 | 做插件/MCP 发现？ | 典型耗时 |
|---|---|---|---|
| **跑 agent** | `chat`、`acp`、`rl`、`gateway run`、`cron run/tick`、`mcp serve` | 是 | 百 ms~秒 |
| **配置** | `config`、`model`、`tools`、`skills`、`plugins`、`skin`、`profile` | 否 | 十 ms |
| **内省/诊断** | `status`、`doctor`、`logs`、`usage`、`insights`、`sessions`、`hooks list` | 否 | 十 ms |
| **运维** | `update`、`backup`、`uninstall`、`migrate`、`verify`、`security` | 否 | 秒（会下载/复制） |
| **服务面** | `dashboard`、`serve`、`gui`、`webhook`、`slack`、`whatsapp` | 部分（headless 前置） | 秒 |
| **实验/专用** | `moa`、`journey`、`curator`、`pets`、`claw`、`peer`、`worktree` | 视实现 | — |

这张表的实用价值：**排查「启动慢」时，先确认落在哪一行**。
`hermes hooks list` 慢 = bug；`hermes chat` 慢 = 可能需要预热。

### 3.4 斜杠命令是另一套注册表

**别把子命令和斜杠命令搞混**。它们的区别是结构性的：

| | 子命令 | 斜杠命令 |
|---|---|---|
| 输入 | `hermes <name>` | 会话里敲 `/<name>` |
| 注册表 | argparse subparsers（65 个 `build_*_parser`） | [`COMMAND_REGISTRY`](../hermes_cli/commands.py:45)（103 条 `CommandDef`） |
| 派发 | `args.func(args)` | [`HermesCLI._SLASH_DISPATCH`](../cli.py:894) + `_handle_<name>_command` 约定 |
| 消费者 | 只有 CLI | CLI + 网关 + TUI + Desktop + 帮助文本 + 自动补全 + Telegram 菜单 |

`CommandDef` 的字段比旧文档列的多得多（[`hermes_cli/commands.py`](../hermes_cli/commands.py:45)）：

```python
@dataclass
class CommandDef:
    name: str                      # 不带斜杠："background"
    description: str
    category: str                  # "Session" / "Configuration" / "Tools & Skills" / "Info" / "Exit"
    aliases: tuple[str, ...] = ()  # ("bg",)
    args_hint: str = ""            # "<prompt>" / "[name]"
    subcommands: tuple[str, ...] = ()
    cli_only: bool = False
    gateway_only: bool = False
    gateway_config_gate: str | None = None   # 配置 dotpath
    busy_policy: str = "reject"              # reject | dispatch | interrupt_then_dispatch
    busy_handler: str | None = None
    execute: str | None = None               # 指向 slash_exec.EXECUTORS 的 key
    argument_mode: str | None = None         # 桌面 composer: options|text|mixed
    desktop: str | None = None               # None=提供；"hidden"=能跑但不显示
    desktop_subcommands: tuple[str, ...] | None = None
```

`busy_policy` 是最容易被忽略、但最影响体验的一个：**agent 正在跑的时候敲 `/xxx` 会怎样**。
三档见 [`gateway/run_busy.py`](../gateway/run_busy.py:910)：

- `dispatch` → 照常执行（`_PLAIN_COMMANDS`，[`gateway/run_busy.py`](../gateway/run_busy.py:910)）
- `reject` → 回「Agent is running」
- `interrupt_then_dispatch` → 先中断（`/stop`、`/new`、`/reset`）

这也是为什么网关侧的处理器要登记在 `_IDLE_COMMANDS` / `_PLAIN_COMMANDS` 两张表里
（[`gateway/run_busy.py`](../gateway/run_busy.py:916)）—— **单表表达不了「忙时怎么办」**。

添加命令的四步（[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:31) 原文）：

1. `COMMAND_REGISTRY` 加 `CommandDef(...)`
2. 对应 `cli_*_mixin.py` 加 `_handle_mycommand_command(self, cmd_original)`
   （或显式 `_SLASH_DISPATCH` 条目）
3. 网关侧 `gateway/slash_commands_*.py` 加 `_handle_mycommand_command(self, event)`，
   并登记进 `_IDLE_COMMANDS` 或 `_PLAIN_COMMANDS`
4. 持久化设置走 `cli.py` 的 `save_config_value()`

**铁律：不许写 `elif` 阶梯**（[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:31) 明确写了
`There is no elif ladder — do not add one.`）。新增命令只加表项，不加分支。

---

## 4. 分支路径 A：经典 CLI（`hermes` / `hermes chat`）

### 4.1 分叉点：`_resolve_use_tui`

[`cmd_chat`](../hermes_cli/main.py:1735) 的第一件事就是判断「经典 CLI 还是 TUI」：

```python
use_tui = False if stream_json_requested(args) else _resolve_use_tui(args)
```

[`_resolve_use_tui`](../hermes_cli/main_tui_launch.py:500) 的优先级是**严格有序**的，
顺序错了就是 bug：

```python
def _resolve_use_tui(args) -> bool:
    if getattr(args, "cli", False):                         # 1. --cli 最高
        return False
    if getattr(args, "tui", False) or getattr(args, "tui_native", False):
        return True                                          # 2. --tui 次之
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False                                         # 3. 非 TTY 强制经典
    if os.environ.get("HERMES_TUI") == "1":
        return True                                          # 4. 环境变量
    iface = (load_config().get("display", {}) or {}).get("interface", "cli")
    return iface.strip().lower() == "tui"                     # 5. 配置文件
```

三个「为什么」：

- **为什么 `stream_json_requested` 在 `_resolve_use_tui` 之外？**
  因为结构化 stdout 是**非交互协议**，它连 `HERMES_TUI=1` 都要压过去。
- **为什么 TTY 门控在 env 之前？** docstring 解释：
  ```python
  # The TTY gate is load-bearing: ambient preferences must never hijack a piped
  # ``hermes chat -q`` (kanban workers, cron) — the Ink no-TTY bail-out exits 0 and
  # the worker dies with a protocol violation.
  ```
  翻译：环境里导出了 `HERMES_TUI=1`（很正常，用户就是 TUI 党），
  然后 kanban worker 跑 `hermes chat -q "..."`，管道不是 TTY → Ink 直接 exit 0 →
  **worker 以为成功但其实什么都没干**。所以「非 TTY 一律经典」必须优先于环境变量。
- **为什么 `--tui` 放在 TTY 之前？** 显式 flag 是用户的明确意愿，允许它失败（报错比静默降级好）。

### 4.2 首次运行守卫

```python
from hermes_cli.free_tier_bootstrap import run_bootstrap
run_bootstrap(announce=False)

provider_configured = _has_any_provider_configured()
if not use_tui and not provider_configured:
    _first_run_setup_guard(args)      # 经典 CLI 弹向导
    return
```

注意 `not use_tui` 这个条件 + 注释：

```python
# The TUI owns its first-run state: it renders "Setup Required" with in-place /setup.
# The classic prompt only fronts the classic CLI.
```

**同一个「没配 provider」状态，两个面各自负责**。这不是重复，是职责划分：
TUI 是 React 应用，能画漂亮的首启页；CLI 只能用 prompt_toolkit 弹问句。
**如果你在 CLI 里给 TUI 用户弹问句，就是在错误的地方做正确的功能。**

### 4.3 环境变量「标量」注入

这几个 flag 不改参数，改的是**进程环境**，因为下游读环境：

```python
if getattr(args, "yolo", False):
    os.environ["HERMES_YOLO_MODE"] = "1"          # 安全网，见 §2.5
if getattr(args, "ignore_rules", False):
    os.environ["HERMES_IGNORE_RULES"] = "1"
if getattr(args, "source", None):
    os.environ["HERMES_SESSION_SOURCE"] = args.source
    os.environ["HERMES_SESSION_SOURCE_EXPLICIT"] = "1"
```

`HERMES_SESSION_SOURCE_EXPLICIT` 的注释值很高：

```python
# Explicit flag, not a label inherited from a parent TUI/Desktop session — one-shot
# runs must keep it (see agent.session_source.session_source_for).
```

**「显式传入」和「从父会话继承」必须可区分**。否则子进程无法判断
「我这个 source 是用户说的，还是别人替我填的」，而这个区别决定了能不能被覆盖。

### 4.4 passthrough 表：`_CHAT_PASSTHROUGH`

[`hermes_cli/main.py`](../hermes_cli/main.py:1726)：

```python
# args attr -> (kwarg, default) passed through to _launch_tui / cli.main.
_CHAT_PASSTHROUGH = (
    ("provider", None), ("toolsets", None), ("skills", None), ("verbose", None),
    ("quiet", False), ("query", None), ("image", None), ("resume", None),
    ("worktree", False), ("checkpoints", False), ("pass_session_id", False),
    ("max_turns", None),
)
```

**一张表同时服务两条路径**（TUI 与 CLI）。这是表驱动的好处：
新增一个 chat 参数 → 只加一行 → 两条路径都拿到。

```python
passthrough = {k: getattr(args, k, d) for k, d in _CHAT_PASSTHROUGH}
if use_tui:
    _launch_tui(passthrough.pop("resume"), tui_dev=..., native_mode=..., **passthrough)
```

注意 `pop("resume")` —— 因为 `_launch_tui` 的第一个位置参数就是 resume id，
剩下的才走 `**kwargs`。**同一个表，两种调用形状**。

### 4.5 进入 `HermesCLI`

经典路径最后是：

```python
kwargs = {
    "model": args.model, "reasoning": ..., "toolsets": ...,
    "query": args.query, "oneshot": bool(args.oneshot_exit),
    "run_budget": ..., "output_format": ..., "ignore_rules": ...,
    **{k: getattr(args, k, d) for k, d in _CHAT_PASSTHROUGH},
}
kwargs = {k: v for k, v in kwargs.items() if v is not None}   # ← 丢掉 None

from cli import main as cli_main
cli_main(**kwargs)
```

`{k: v ... if v is not None}` 这一行有讲究：**「没传」和「传了 None」要区分**。
如果无脑传 `model=None`，`HermesCLI` 就无法用 `kwargs.get("model", CONFIG_DEFAULT)` 的默认值逻辑 ——
因为 key 存在。**过滤 `None` 是 Python 里表达「可选参数」的标准做法。**

`cli.main` → [`HermesCLI`](../cli.py:894)（17 个 mixin）→ REPL 循环。
这部分见 [`10-surfaces-cli-tui-desktop-web.md`](10-surfaces-cli-tui-desktop-web.md)。

### 4.6 单发模式（`--oneshot` / `-z`）

在 §2.5 里 `--oneshot` 会在**子命令分发之前**被截走：

```python
if getattr(args, "oneshot", None):
    _run_oneshot_from_args(args)
```

[`_run_oneshot_from_args`](../hermes_cli/main.py:3084) 的 docstring：

> Bypasses cli.py entirely; `_run_and_exit_oneshot` never returns.

**完全绕过 `cli.py`** —— 不建 `HermesCLI`、不建 prompt_toolkit、不渲染 banner。
这对脚本/CI/子代理调用是决定性的：它要的是「纯 stdout = 最终回答」。

但有个真实坑，注释留了案发现场：

```python
# -z honors --resume/-c/--in exactly like chat (#105892): normalize BEFORE the
# oneshot exit path takes over, else the flags parse fine but silently do nothing
# and the turn starts a fresh session (every wire request loses all history).
_resolve_chat_session_args(args, use_tui=False)
```

**flag 解析成功但静默失效**是最恶心的一类 bug：没有报错，只是「历史丢了」。
根因是 oneshot 路径提前 `return`，跳过了 chat 路径里的归一化步骤。
修复方式不是复制一遍，而是**把归一化提到分叉之前**。

[`run_oneshot`](../hermes_cli/oneshot.py:238) 还做了一件狠事：

```python
logging.disable(logging.CRITICAL)   # 静默所有 stdlib logger
```

因为 stdout 必须是纯回答，任何日志漏到 stdout 都会污染协议。**协议通道要独占。**

---

## 5. 分支路径 B：TUI（`hermes --tui`）

### 5.1 `_launch_tui` 不是 exec，是 fork+wait

[`_launch_tui`](../hermes_cli/main_tui_launch.py:350) 的 docstring 说 `Replace current process with the TUI.`，
但实现是 `subprocess.call(argv, cwd=..., env=env)` —— **父进程还在，在等子进程**。

为什么？因为退出后还要做事：

```python
finally:
    os.unlink(active_session_file)         # 清理临时文件
    if wt_info:
        _cleanup_worktree(wt_info)         # 清理 worktree

if code == 42:                             # TUI 请求升级
    from hermes_cli.relaunch import relaunch
    print("\n☤ Launching update...\n")
    relaunch(["update"], preserve_inherited=False)
```

两个设计点：

- **退出码 42 = 升级请求**。用退出码传递「非错误」的意图，是 Unix 的老手法（比 IPC 简单）。
  `preserve_inherited=False` 又很关键：不能把 `--tui` 带进 `hermes update`。
- **`finally` 里清理**：worktree 是真实资源（git worktree add 出来的目录），必须清。

### 5.2 环境变量契约（这是 TUI 的真正接口）

`_launch_tui` 的实质工作是**用环境变量把一个会话描述传给 Node 子进程**。
前端类比：这相当于 `window.__INITIAL_STATE__`，只不过走 `env` 而不是 `<script>`。

| 变量 | 来源 | 用途 |
|---|---|---|
| `HERMES_CWD` | 当前目录 / `--worktree` | 会话工作目录（**每次启动的目录是唯一真相**） |
| `HERMES_TUI_CWD` | 同上（仅 local 后端） | TUI 在 `session.create` 里发的 cwd |
| `TERMINAL_CWD` | 同上 | 工具终端的默认 cwd |
| `HERMES_TUI_PROVIDER` / `HERMES_INFERENCE_PROVIDER` | `--provider` | provider |
| `HERMES_MODEL` / `HERMES_INFERENCE_MODEL` | `--model` | 模型 |
| `HERMES_TUI_TOOLSETS` / `HERMES_TUI_SKILLS` | `--toolsets` / `--skills` | 启用集 |
| `HERMES_TUI_QUERY` / `HERMES_TUI_IMAGE` | `--query` / `--image` | 首轮输入 |
| `HERMES_TUI_RESUME` | `--resume` | 续接会话 |
| `HERMES_TUI_ACTIVE_SESSION_FILE` | `mkstemp` | 用于退出后打印摘要 |
| `HERMES_TUI_NATIVE` | `display.tui_native` | 原生模式开关 |
| `HERMES_ACCEPT_HOOKS` | `--accept-hooks` | hook 同意 |
| `NODE_OPTIONS` | 计算 | V8 堆上限 |

`HERMES_CWD` 的注释是一课：

```python
# The directory this launch was invoked from is the source of truth. An inherited
# HERMES_CWD (exported by an outer `hermes --tui`, or by the user's own shell) merely
# names *a* real directory, so the is_dir() repair in _apply_tui_python_env keeps it
# and the gateway starts in last session's project. `--worktree` still wins below.
```

事故模式：外层 TUI 导出了 `HERMES_CWD`，用户在 shell 里 `cd` 到另一个项目再 `hermes --tui`，
结果内层 TUI 开在**上个会话的项目**里。修复是「启动目录覆盖继承值」，
而不是「相信环境变量」—— 因为**环境变量只说明「存在过的某个目录」，不说明「你现在在哪」**。

`NODE_OPTIONS` 那段也很实在：

```python
# Generous V8 heap (8GB target; default cap can fatal-OOM on long sessions),
# sized below the cgroup limit by _resolve_tui_heap_mb() so V8 exits
# gracefully instead of being reaped silently.
```

`_resolve_tui_heap_mb()` 会读 cgroup 限额。**在容器里给 V8 设一个比容器还大的堆，
结果就是被 OOM killer 静默干掉**（没有 JS 栈、没有日志）。所以要「略小于容器限额」，
让 V8 自己 OOM 报错。

还有个「不改用户参数」的细节：

```python
# Token-level merge respects a user-supplied --max-old-space-size.
_tokens = env.get("NODE_OPTIONS", "").split()
if not any(t.startswith("--max-old-space-size=") for t in _tokens):
    _tokens.append(f"--max-old-space-size={_resolve_tui_heap_mb()}")
```

以及一句必须记住的注记：

```python
# --expose-gc is NOT added here: Node rejects it in NODE_OPTIONS;
# _make_tui_argv() passes it as a direct flag.
```

**`NODE_OPTIONS` 只接受一部分 flag。** 想加 `--expose-gc` 必须进 argv。

### 5.3 Python 侧的 bootstrap：`tui_gateway/entry.py`

Node 起来后会 spawn Python 侧 [`tui_gateway/main`](../tui_gateway/entry.py:273)：

```python
def main():
    # stdout is this process's JSON-RPC client channel: peer-less global broadcasts belong on it.
    server._stdio_is_rpc_channel = True
    server.install_tui_message_injector()
    _close_rpc_stdin_on_exec()
    _install_sidecar_publisher()

    begin_process("tui")
    set_process_surface("tui_gateway")           # ← 三消费方共用同一个 surface 名
    install_truststore()

    # The heartbeat row lets the orphan sweep tell "live but idle" from "truly orphaned",
    # so it must start BEFORE the sweep.
    server._start_backend_heartbeat_refresher()
    server._schedule_startup_orphan_sweep()

    ensure_mcp_discovery_started()               # 后台线程

    _write_or_exit({"jsonrpc": "2.0", "method": "event",
                    "params": {"type": "gateway.ready", "payload": {
                        "skin": resolve_skin(), "change_events": True,
                        "replay_epoch": replay_epoch()}}},
                   "startup write failed (broken stdout pipe before first event)")

    server._ensure_skin_watcher()
    prewarm_picker_cache_async()

    while True:
        raw = sys.stdin.readline()
        ...
```

五个要点：

**① `stdout` 是协议通道，一字节都不能脏。** 所以：
- `_stdio_is_rpc_channel = True`（让广播走对地方）
- 日志走 stderr（`acp_adapter` 也一样）
- `_write_or_exit` 在**第一条事件就写失败**时直接退出，而不是继续跑一个「客户端听不到」的服务器

**② 心跳必须早于孤儿清扫。** 注释：
> The heartbeat row lets the orphan sweep tell "live but idle" from "truly orphaned",
> so it must start BEFORE the sweep.

顺序反了 → 清扫器把**正在启动的自己**当成孤儿杀掉。这类「初始化顺序」bug 只能靠注释守住。

**③ `gateway.ready` 是握手事件。** 它带 `change_events` 与 `replay_epoch`：
- `change_events=True` → 客户端可以停掉旧的轮询
- `replay_epoch` → WS 重连检测（同一个 epoch 说明后端没重启，可以增量重放）

**④ MCP 发现有「两个 owner」。** [`mcp_discovery_in_flight`](../tui_gateway/entry.py:205) 的注释
记录了一个具体缺陷：

```python
# There are two independent discovery-thread owners by surface: the stdio ``hermes --tui`` path
# spawns ITS thread here, while the desktop app + dashboard WebSocket sidecar (``tui_gateway/ws.py``)
# and ``hermes dashboard`` spawn theirs via hermes_cli.mcp_startup...
# checking only the entry thread left the desktop/dashboard surfaces with no late refresh,
# so a slow MCP server's tools never surfaced for the whole session (#51587).
```

**同一个逻辑在两个进程模型里有两个 owner，任何「是否在飞」的判断都必须查两边。**
这是「一后端多前端」架构的典型税。

**⑤ 主循环是 `sys.stdin.readline()`。** 同步阻塞、逐行。
不是 asyncio —— 因为 agent 本身是同步的，事件循环会引入不必要的复杂性。

传输层的完整规格（方法表、`srq-<n>`、`request.cancel`、`client.capabilities`）见
[`tui_gateway/AGENTS.md`](../tui_gateway/AGENTS.md:9) 与 §10 篇。这里只记住一句话：

> **TypeScript 拥有屏幕，Python 拥有会话、工具、模型调用与斜杠逻辑。**

### 5.4 三个消费者

```text
hermes --tui        ──stdio──┐
Desktop (Electron)  ──WS─────┤──→  tui_gateway 后端  ──→  AIAgent
Dashboard /chat     ──WS/PTY─┘
```

改 `tui_gateway` **等于改三个产品**。这是本仓库最容易吃亏的地方：
在 `hermes --tui` 里验证通过，不代表 Desktop 没事（它走 WebSocket、有 `client.capabilities` 协商）。

---

## 6. 分支路径 C：消息网关（`hermes gateway run`）

### 6.1 入口链

```text
hermes gateway run
  → hermes_cli/main.py:main()
  → args.func = cmd_gateway
  → hermes_cli/gateway.py:gateway_command()
  → gateway/run.py:main()
  → gateway/run.py:start_gateway()      # async
```

`gateway/__main__.py` **不存在**，所以旧文档里的「`python -m gateway.run`」是唯一可行的
module 形式；`python cli.py --gateway` 是老写法。**推荐永远是 `hermes gateway run`**。

### 6.2 `start_gateway()` 的两个「必须在这里」

[`start_gateway`](../gateway/run.py:5750) 开头：

```python
async def start_gateway(config=None, replace=False, verbosity=0, force=False) -> bool:
    """...; False if it failed to start (non-zero exit so systemd can auto-restart).
    ``replace`` kills any existing instance first (avoids restart-loop deadlocks);
    ``force`` starts without consulting the host owner at all."""

    # Set here (not at import) so incidental gateway.run imports from CLI code don't poison it.
    os.environ["HERMES_EXEC_ASK"] = "1"

    # Messaging-only defaults belong to startup, not incidental imports by the TUI.
    configured_cwd = os.environ.get("TERMINAL_CWD", "")
    ...
```

**两个注释都在说同一件事：不要在 import 时产生副作用。**
`gateway/run.py` 会被 CLI 代码偶然 import（比如 `hermes status` 想读点东西），
如果那时就设 `HERMES_EXEC_ASK=1` 或改 `TERMINAL_CWD`，TUI/CLI 的行为就被污染了。

这是 §2.5「`--yolo` 必须在 import 前设」的**镜像问题**：
- `--yolo` 是「import 时会读取并固化」→ 必须早设
- `HERMES_EXEC_ASK` 是「import 时不该设」→ 必须晚设

**判断标准只有一个：这个环境变量的读取点在哪。** 读在模块顶层 → 早设；只被运行时读 → 晚设。

### 6.3 返回值语义

`start_gateway()` 返回 `bool`，`False` = 启动失败 → **非零退出码** → systemd 才会重启。
如果失败也返回 0，systemd 会认为「正常结束」，静默不重启，服务就永远死了。

### 6.4 30 个相位文件

`gateway/run.py` 是门面，相位在 `run_*.py`（共 30 个）：

| 主题 | 文件 |
|---|---|
| 启动 / 关闭 | [`run_startup.py`](../gateway/run_startup.py:1)、[`run_shutdown.py`](../gateway/run_shutdown.py:1)、[`run_shutdown_session_end.py`](../gateway/run_shutdown_session_end.py:1) |
| 适配器 | [`run_adapters.py`](../gateway/run_adapters.py:1) |
| 入站 | [`run_inbound.py`](../gateway/run_inbound.py:1)、[`run_inbound_consumer.py`](../gateway/run_inbound_consumer.py:1)、[`run_inbound_media.py`](../gateway/run_inbound_media.py:1)、[`run_inbound_unauthorized.py`](../gateway/run_inbound_unauthorized.py:1) |
| 回合 | [`run_turn.py`](../gateway/run_turn.py:1)、[`run_turn_runner.py`](../gateway/run_turn_runner.py:1)、[`run_turn_followup_ack.py`](../gateway/run_turn_followup_ack.py:1)、[`run_turn_runner_approval_settle.py`](../gateway/run_turn_runner_approval_settle.py:1)、[`run_turn_runner_clarify_delivery.py`](../gateway/run_turn_runner_clarify_delivery.py:1) |
| 忙时策略 | [`run_busy.py`](../gateway/run_busy.py:1) |
| 目标循环 | [`run_goals.py`](../gateway/run_goals.py:1) |
| 通知 | [`run_notifications.py`](../gateway/run_notifications.py:1)、[`run_notifications_ownership.py`](../gateway/run_notifications_ownership.py:1) |
| 派发/队列 | [`run_delivery_queue_watch.py`](../gateway/run_delivery_queue_watch.py:1) |
| 心跳 | [`run_heartbeat_acceptance.py`](../gateway/run_heartbeat_acceptance.py:1)、[`run_heartbeat_restore.py`](../gateway/run_heartbeat_restore.py:1) |
| 插件 | [`run_plugin_injection.py`](../gateway/run_plugin_injection.py:1)、[`run_plugin_rewire.py`](../gateway/run_plugin_rewire.py:1) |
| profile | [`run_profile_reconcile.py`](../gateway/run_profile_reconcile.py:1) |
| 其它 | `run_common.py`、`run_agent_cache.py`、`run_config_loaders.py`、`run_idle_gates.py`、`run_voice.py`、`run_watchers.py`、`run_topics.py` |

不需要背，只需要知道**「找网关某功能 → 先按主题 grep `run_*.py`」**，
而不是从 `run.py` 第 1 行开始读。

### 6.5 双消息守卫

旧文档提到的「双消息守卫」在 [`gateway/run_busy.py`](../gateway/run_busy.py:910)：

```python
_PLAIN_COMMANDS = (...)   # 忙时也能跑
_IDLE_COMMANDS  = (...)   # 只在空闲时跑
```

配合 §3.4 的 `busy_policy`：`CommandDef.busy_policy` 是**声明**，
`_IDLE_COMMANDS` / `_PLAIN_COMMANDS` 是**两张分派表**（`_command_handler_table`）。

为什么表格要分两张而不是一张带 flag？
因为**默认值是 reject**。如果一张表 + `default="reject"`，新增命令忘了登记就自动 reject ——
这其实是对的。但分成两张表让「忙时可用」成为显式白名单，**审计时能一眼看完**。

### 6.6 profile 隔离的重灾区

网关是**一个进程服务多个 profile** 的地方（[`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)）。
所有不在 turn 内运行的代码（启动探针、驱逐、ticker、延迟回调、RPC 方法、线程跳转、子进程）
都必须**显式绑定** profile scope，因为 `os.environ`、模块全局、import 时值都持有「启动 profile」。

网关侧的绑定点与缝见 [`gateway/AGENTS.md`](../gateway/AGENTS.md:1) § Profile scope。

### 6.7 平台适配器

`gateway/platforms/*.py` 共 36 个 Python 文件（约 20 个平台，其余是基类/helper）。
每个适配器自己挑基础 toolset（Telegram → `messaging`）。

新增平台看 [`gateway/platforms/ADDING_A_PLATFORM.md`](../gateway/platforms/ADDING_A_PLATFORM.md:1)。
本篇只提一个入口侧的坑：**deferred 平台**。

[`_resolve_deferred_platform_cli_command`](../hermes_cli/main.py:2860) 的注释：

```python
"""Materialize the deferred platform whose top-level CLI command matches.

Bundled platforms are *deferred* entries (no gateway SDK imports at startup), so a platform's
``register_cli_command`` side effect only runs on import; ``discover_plugins()`` alone leaves
``hermes photon`` failing with ``invalid choice``. Importing just the matching platform keeps
startup cheap.
"""
```

**「延迟 import 省启动时间」和「CLI 子命令靠 import 注册」是天生冲突的。**
解法：发现阶段只记录 loader，然后在「未知子命令慢路径」上按名字**只 import 那一个**。
这是「懒加载 + 副作用注册」组合时的通用补丁模式。

---

## 7. 分支路径 D：Dashboard 与 Serve

### 7.1 同一个 `cmd_dashboard`，一个开关分出两个产品

[`cmd_dashboard`](../hermes_cli/main.py:2712) 同时服务 `hermes dashboard` 与 `hermes serve`：

```python
# `serve` is the headless backend: no UI build, no SPA mount, neutral
# ready sentinel. Resolved once and threaded through the re-exec, the
# build gate, and start_server.
_headless_backend = getattr(args, "headless_backend", False)
```

「Resolved once and threaded through」值得学：**一个布尔决定，只读一次，然后显式传递**。
不要在下游反复 `getattr(args, ...)` —— 一旦 re-exec，args 就是新进程的了。

`serve` 与 `dashboard` 的最后一步**是同一个函数**：

```python
start_server(
    host=args.host, port=args.port,
    open_browser=not args.no_open,
    allow_public=getattr(args, "insecure", False),
    initial_profile=..., headless=_headless_backend,
    isolated=..., ssh_session_token=..., ssh_owner_nonce=...,
    start_mcp_discovery_after_bind=...,
    ssh_lock_path=...,
)
```

区别只在参数：

| | `dashboard` | `serve` |
|---|---|---|
| `headless` | False | **True** |
| 构建前端产物 | 是 | 否 |
| 挂 SPA | 是 | 否 |
| ready 哨兵 | 普通 | **中性**（不承诺 UI 可用） |
| 打开浏览器 | 默认是 | 否 |
| 谁启动它 | 用户 | Desktop（`before-quit` 时杀掉） |

### 7.2 生命周期差异（最容易被误解的一点）

- **`hermes serve`**：Desktop spawn 出来的**无头控制平面后端**，随应用退出而退出。**设计如此。**
- **`hermes gateway run`**：**独立存活**。serve 的 `/api/gateway/*` 以 **detached** 方式 spawn 它，
  所以 `before-quit` 的 SIGTERM 到不了它 → **机器人继续运行**。

问题：为什么这样设计？因为「关掉桌面应用」和「关掉我的 Telegram 机器人」是两件完全不同的事。
用户关 app 是为了不看屏幕，不是为了停服务。

这条差异在 [`gateway/AGENTS.md`](../gateway/AGENTS.md:78) 有记录，也是
「`ps` 里为什么还挂着一个 gateway」的标准答案。

### 7.3 `/api/pty`：Dashboard 的 Chat 标签页怎么「内嵌 TUI」

**不重写，而是把真实 TUI 塞进 PTY。**

```python
# /api/pty spawns ``hermes --tui`` behind a pseudo-terminal and forwards bytes +
# resize escapes to xterm.js.  POSIX uses pty_bridge (fcntl/termios); native
# Windows uses win_pty_bridge (pywinpty/ConPTY); same surface, no handler guards.
```

（[`hermes_cli/web_server_chat.py`](../hermes_cli/web_server_chat.py:28)）

整条链路：

```text
React (xterm.js)  ←WS bytes→  FastAPI handler  ←read/write→  PtyBridge  ←PTY→  hermes --tui (Node)
```

要点：

| 细节 | 位置 | 说明 |
|---|---|---|
| 平台桥接 | [`pty_bridge.py`](../hermes_cli/pty_bridge.py:111) / [`win_pty_bridge.py`](../hermes_cli/win_pty_bridge.py:1) | POSIX 用 `ptyprocess`，Windows 用 ConPTY |
| 统一导入 | [`web_server_chat.py`](../hermes_cli/web_server_chat.py:31) | `try: win → WinPtyBridge; else → PtyBridge`，**import 期决定，handler 里不判断** |
| resize 协议 | [`web_server_chat.py`](../hermes_cli/web_server_chat.py:43) | `_RESIZE_RE = re.compile(rb"\x1b\[RESIZE:(\d+);(\d+)\]")` |
| resize 应用 | [`pty_bridge.py`](../hermes_cli/pty_bridge.py:253) | `resize(cols, rows)` → `TIOCSWINSZ` |
| 读分片超时 | `_PTY_READ_CHUNK_TIMEOUT = 0.2` | 避免阻塞事件循环 |
| 空闲退避 | `_PTY_IDLE_BACKOFF = 0.05` | 「a quiet terminal does not spin the event loop」 |
| 会话池 | `PTY_REGISTRY = PtySessionRegistry(ttl=30*60, max_sessions=16, buffer_cap=1MB, ...)` | 支持断线重连续上同一个 PTY |

**为什么要发明 `\x1b[RESIZE:c;r]` 这个私有转义？**
因为 xterm.js 的 resize 是**浏览器事件**，而 PTY 的尺寸是**内核 ioctl**。
中间没有标准协议，只能用一条「混在字节流里的伪 ANSI 序列」当带内信号（in-band signal），
服务端拦截后不转发给 PTY，而是转成 `TIOCSWINSZ`。

**为什么 `import` 期决定桥接实现？** 见 [`web_server_chat.py`](../hermes_cli/web_server_chat.py:31) 注释：
`same surface, no handler guards`。**平台分支只在最外层出现一次**，
后面所有 handler 都面对同一个 `PtyBridge` 接口。这是「把 if 集中在边界」的标准做法。

**一个前端开发者必须知道的结论**（[`web/AGENTS.md`](../web/AGENTS.md:7)）：

> 不要在 React 里重实现主聊天体验 —— 加到 Ink 里会自动出现在这里。

因为你在 React 里撒的任何「聊天增强」都只服务于一个面，而 Ink 的改动同时出现在
TUI / Desktop / Dashboard 三个面。

### 7.4 Dashboard 的开销控制

`dashboard` 启动时做了一串「可选优化」，每条都有失败兜底：

```python
apply_nofile_soft_limit()                    # 提高 fd 上限（PTY 很吃 fd）
_mcp_discovery_after_bind = _dashboard_prepare_runtime(args, _headless_backend)
_maybe_setup_dashboard_auth_interactively(args)
```

注释解释了两处顺序的不可交换性：

```python
# Apply the final process/profile policy after dashboard routing, but before
# importing the web server or opening dashboard state. Applying it before a
# named-profile re-exec could leak that profile's higher limit into the
# machine/default dashboard, whose lower policy intentionally cannot undo it.
```

**资源上限是「只能升不能降」的进程属性。** 在两个 profile 之间做 re-exec 时，
如果先升后切，新 profile 的更低限额就设不回去了 —— 所以必须**切完再设**。

---

## 8. 分支路径 E：ACP（编辑器）

### 8.1 入口结构

```text
hermes-acp
  → acp_adapter/entry.py:main()
      ├─ --version / --check / --setup / --setup-browser   → 直接返回
      └─ _setup_logging() → _load_env() → sys.path 注入 → install_truststore()
         → 启动 stdio JSON-RPC 服务器
```

`acp_adapter/` 共 14 个 `.py`（含 `__init__.py`），其中 13 个是功能模块：
`server.py`、`session.py`、`events.py`、`permissions.py`、`tools.py`、`content.py`、
`commands.py`、`auth.py`、`edit_approval.py`、`model_catalog.py`、`provenance.py`、
`entry.py`、`__main__.py`。

### 8.2 三件入口自检

| 事项 | `hermes main()` 做过 | `acp_adapter/entry.py` 是否补做 |
|---|---|---|
| TLS 信任源 | `install_truststore()` | ✅ 有（含注释说明「bypasses」） |
| UTF-8 stdio | `configure_windows_stdio()` | ❌ 未补 |
| 字节码/更新欠账 | `_sweep_*` / `_recover_*` | ❌ 未补 |
| profile 作用域 | 由 `main()` 与各分支处理 | 需自行保证 |

**这张表就是用来说明「多入口的成本」的。** 每新增一个 console script，就有一份
「`main()` 做过的 5 件事」的清单需要核对。

### 8.3 ACP 与 MCP 的分工（一句话）

- **MCP**：agent ↔ **工具/数据**（Hermes 既当 client 也当 server）
- **ACP**：编辑器 ↔ **agent**（Hermes 当 server，被 VS Code / Zed / JetBrains 驱动）

所以 `hermes mcp serve`（[`mcp_serve.py`](../mcp_serve.py:1)）和 `hermes-acp` 是**两个方向完全相反**的服务器。

---

## 9. 其它入口

| 入口 | 文件 | 形态 | 用途 |
|---|---|---|---|
| 批量轨迹生成 | [`batch_runner.py`](../batch_runner.py:867) | 多进程 Pool + JSONL | 训练数据生成、回归评测 |
| mini SWE runner | [`mini_swe_runner.py`](../mini_swe_runner.py:1) | 单任务/JSONL | 在 local/docker/modal 里跑 SWE 任务 |
| MCP server | [`mcp_serve.py`](../mcp_serve.py:1) | stdio MCP | 把消息会话暴露成 MCP 工具（9 个 tool + `channels_list`） |
| Python 库 | `from run_agent import AIAgent` | 进程内 | 嵌进自己的程序 |
| 单个 query | [`hermes_cli/oneshot.py`](../hermes_cli/oneshot.py:238) | 进程内 | `-z` / 子代理 / 脚本 |

### 9.1 `batch_runner.py` 的入口细节

```python
# hermes_bootstrap must be the very first import — UTF-8 stdio on Windows, no-op on POSIX.
try:
    import hermes_bootstrap
except ModuleNotFoundError as exc:
    # Partial ``hermes update`` (git reset landed, ``uv pip install -e .`` did not).
    if exc.name != "hermes_bootstrap":
        raise  # the bootstrap exists but cannot load: skipping it would skip PM activation
```

这段 `except` 的写法很精妙，值得学：

| 情形 | 行为 | 理由 |
|---|---|---|
| 没有 `hermes_bootstrap` 模块 | 静默跳过 | 用户可能只是没装全，不该崩 |
| 有模块但加载时缺**别的**依赖 | **重新抛** | 否则会跳过 PM 激活，后面全崩且难查 |

**区分「我不需要这个模块」和「我需要但坏了」** —— 这是宽泛 `except ImportError` 最大的坑。

`batch_runner` 的默认值是「训练场景」而不是「聊天场景」：

```python
model="anthropic/claude-sonnet-4.6",
base_url="https://openrouter.ai/api/v1",
max_turns=10, num_workers=4,
```

`max_turns=10`（不是无限）、`num_workers=4`（不是 CPU 数）—— **批量跑要控成本、控并发**。

### 9.2 `mcp_serve.py` 的定位

docstring 写得很清楚：

```python
"""Hermes MCP Server — expose messaging conversations as MCP tools (`hermes mcp serve`).

A stdio MCP server letting any MCP client (Claude Code, Cursor, Codex, ...) list
conversations, read history, send messages, poll live events, and manage approvals.

Client config: {"mcpServers": {"hermes": {"command": "hermes", "args": ["mcp", "serve"]}}}
"""
```

注意最后那行配置：**消费者是别的 agent**。也就是说
`hermes` 在这里**退化成别人的工具**，而不是自己跑 agent。

---

## 10. 十二维对照表

把六条主路径放在一起看，分叉点就清楚了：

| 维度 | 经典 CLI | TUI | Gateway | Serve | Dashboard | ACP |
|---|---|---|---|---|---|---|
| 启动命令 | `hermes` / `hermes chat` | `hermes --tui` | `hermes gateway run` | `hermes serve` | `hermes dashboard` | `hermes-acp` |
| 分叉函数 | `cmd_chat` | `_launch_tui` | `cmd_gateway` | `cmd_dashboard(headless=True)` | `cmd_dashboard` | `acp_adapter.entry:main` |
| Python 进程 | 1 | 1 (+Node) | 1（常驻） | 1 | 1 (+N PTY children) | 1 |
| 协议 | 无 | stdio JSON-RPC | 平台 SDK | WS/HTTP | WS + PTY bytes | stdio JSON-RPC |
| stdout 用途 | 用户输出 | **协议** | 日志 | WS | WS | **协议** |
| 生命周期 | 用户退出 | Node 退出 | systemd/常驻 | 随 Desktop | 用户 `Ctrl-C` | 编辑会话 |
| agent 实例 | 1/session | 1/session | 1/session | 1/session | 1/PTY | 1/session |
| 状态存储 | `SessionDB` | 同 | 同 | 同 | 同 | 同 |
| 首启向导 | 有（CLI 弹问句） | TUI 自己画 | 无 | 无 | 有（交互 auth） | `--setup` |
| 插件发现 | 有 | **网关侧做** | 有 | 有 | 有 | 有 |
| 忙时策略 | 不适用 | 客户端处理 | `busy_policy` | 不适用 | 客户端处理 | 编辑器处理 |
| 典型失败 | provider 未配 | 非 TTY 被降级 | 端口/profile 冲突 | app 退出即死 | PTY 平台不支持 | stdout 被日志污染 |

三条从表里读出来的规律：

1. **一切「协议型」入口的 stdout 都不能被日志污染**（TUI、ACP）。
2. **一切「常驻型」入口都要能返回失败让进程管理器重启**（Gateway）。
3. **一切「代理型」入口的生命周期由父进程决定**（Serve、Dashboard 的 PTY）。

---

## 11. 六个常见误判

| 症状 | 错误归因 | 真正原因 | 定位 |
|---|---|---|---|
| `hermes ...` 启动慢 | 「agent 太重」 | 构建 65 个 subparser（~140ms），或非 chat 命令走了插件发现 | §2.3、§3.3 |
| 改了代码没生效 | 「缓存没清」 | `__pycache__` 与 checkout 不一致 | `_sweep_stale_bytecode_if_checkout_changed`（§2.2） |
| MCP server 白占内存 | 「MCP 泄露」 | 双重发现（launcher + TUI gateway） | `_is_tui_chat_launch`（§2.5） |
| 脚本里 `hermes chat -q` 什么都没干 | 「agent 没回答」 | 环境导出 `HERMES_TUI=1`，非 TTY 被 Ink 拒绝后 exit 0 | `_resolve_use_tui` 的 TTY 门控（§4.1） |
| `-z --resume` 历史丢失 | 「resume 坏了」 | oneshot 提前 return，跳过参数归一化 | `_resolve_chat_session_args`（§4.6） |
| 关掉桌面应用后机器人还在跑 | 「没清理干净」 | `gateway` 是 detached 的，**设计如此** | §7.2 |

这六条覆盖了「入口层」99% 的困惑。它们共同的特征是：
**代码没错，是「顺序」「时序」「生命周期」错了。**

---

## 12. 自检题

不看文档回答，答不上就回去读对应节：

1. `hermes` 这个命令背后执行的第一个 Python 函数是哪个？文件+函数名。（§0.1）
2. `[project.scripts]` 里有几个入口？分别指向哪？（§0.1、§1）
3. `main()` 里 `--yolo` 为什么要设两次？（§2.5）
4. 哪四类命令**不会**做插件/MCP 发现？为什么内省命令必须跳过？（§2.5、§3.3）
5. 快速通道什么时候必须返回 `False`？为什么容器路由必须最先判断？（§2.3）
6. 为什么非 TTY 要**优先于** `HERMES_TUI=1` 判断？（§4.1）
7. `_CHAT_PASSTHROUGH` 一张表怎么服务两条路径？（§4.4）
8. `_launch_tui` 为什么不是 `os.exec*`？（§5.1）
9. `gateway.ready` 里 `replay_epoch` 有什么用？（§5.3）
10. `HERMES_EXEC_ASK=1` 为什么不能在 import 时设，而 `--yolo` 必须早设？（§6.2）
11. `start_gateway()` 返回 `False` 意味着什么？为什么必须非零退出？（§6.3）
12. `/api/pty` 的 `\x1b[RESIZE:c;r]` 是给谁看的？为什么不直接转发？（§7.3）
13. 关掉 Desktop 之后 Telegram 机器人为什么还在？（§7.2）
14. 想在 `NODE_OPTIONS` 里加 `--expose-gc`，为什么不行？（§5.2）

---

## 13. 本篇小结

一句话版本：

> **`hermes` 是一个进程内的“总闸”：它先做进程自愈（§2.1~§2.2），再用 4 条快速通道抄近路（§2.3），
> 否则走完整 argparse（§2.4），最后按「会不会跑 agent」决定是否做插件发现（§2.5），
> 然后分成六条完全不同的进程形态（§4~§8）——但它们最终都构造同一个 `AIAgent`。**

三张必须记住的表：

- **§0.4 进程拓扑**（几个进程、怎么通信）
- **§3.3 子命令分类**（是否会跑 agent → 是否会做发现）
- **§10 十二维对照表**（分叉函数、协议、生命周期）

下一章 → [`03-agent-core.md`](03-agent-core.md)：穿过入口层，进入 `AIAgent` 与 turn loop 的正中央。
