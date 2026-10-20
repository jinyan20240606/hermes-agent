# 10 · 四个前端面：CLI / TUI / Desktop / Web

> 目标：讲清楚 Hermes 为什么有**四个**交互界面、它们各自被什么物理条件约束、
> 为什么三个界面共享同一个 Python 后端、以及"改一个界面会不会影响另一个"这个问题的完整答案。
>
> 读完之后你应该能：
>
> 1. 画出四个界面各自的进程树，并说出每一段进程间通信用什么协议；
> 2. 解释"`tui_gateway` 有三个消费者"这句话的实际含义与后果；
> 3. 判断一个新功能应该加在哪一面（以及为什么通常不该加在渲染层）；
> 4. 看懂 `contracts/` 那套"Python 声明、TypeScript 生成"的 wire 契约在防什么；
> 5. 说清 Desktop 的 `serve --port 0` 池化后端与 profile 作用域的坑；
> 6. 知道 dashboard 的 `/chat` 为什么是"内嵌真 TUI"而不是重写的聊天界面。

---

## 目录

- [§0 前置概念：为什么一个 agent 需要四个界面](#0-前置概念为什么一个-agent-需要四个界面)
- [§1 全景对照](#1-全景对照)
- [§2 共享内核 `tui_gateway`](#2-共享内核-tui_gateway)
- [§3 wire 契约：Python 声明，TypeScript 生成](#3-wire-契约python-声明typescript-生成)
- [§4 CLI 面（经典 REPL）](#4-cli-面经典-repl)
- [§5 TUI 面（`ui-tui` + `tui_gateway`）](#5-tui-面ui-tui--tui_gateway)
- [§6 Desktop 面（Electron）](#6-desktop-面electron)
- [§7 Web 面（dashboard）](#7-web-面dashboard)
- [§8 i18n 在各界面的分布](#8-i18n-在各界面的分布)
- [§9 跨界面的共同不变量](#9-跨界面的共同不变量)
- [§10 自检题](#10-自检题)
- [§11 小结与下一步](#11-小结与下一步)

---

## §0 前置概念：为什么一个 agent 需要四个界面

### 0.1 一个界面不够，但不是因为"好看"

如果你只写过一个命令行工具，会本能地认为"界面"是装饰。在这个项目里不是。

四个界面存在的根本原因是：**agent 的运行时间尺度和人的注意力尺度不匹配**。

| 场景 | 人的行为 | 需要的界面形态 |
|---|---|---|
| 我坐在终端前，连续问十个问题 | 秒级反馈，一直在看 | 终端里的 REPL |
| 我想看长输出、滚动历史、鼠标选中 | 需要富交互 | 全屏 TUI |
| 我想在开会时让它在后台跑任务，随时瞄一眼 | 后台常驻 + 系统托盘 + 原生通知 | 桌面应用 |
| 我想在另一台电脑的浏览器里看我的会话 | 远程访问，零安装 | Web dashboard |

同一个人在同一天可能用四种。但它们必须访问**同一批会话、同一份配置、同一套工具**——
否则你在桌面里开的会话，在终端里 `hermes --resume` 找不到，这个产品就废了。

### 0.2 每个界面被什么物理条件约束

这是理解后面所有设计取舍的关键。**每个界面的架构不是选出来的，是被约束逼出来的。**

| 界面 | 物理约束 | 直接后果 |
|---|---|---|
| **CLI** | 进程生命周期 = 一次对话；stdout 是唯一输出通道；键盘是唯一输入 | 不能有常驻服务；状态住内存；退出即销毁 |
| **TUI** | 终端只有字符网格，没有像素；有 ANSI 转义但表达力有限 | 必须用字符画布局（Ink/React 渲染到字符网格）；不能嵌入真实图片/富文本 |
| **Desktop** | 有真窗口、真文件系统、真通知、真进程管理；但要跨平台打包 | 需要 Electron 主进程（有 Node 能力）+ 渲染进程（有 DOM）；两端权限必须切开 |
| **Web** | 浏览器沙箱：没有文件系统、没有子进程、WS upgrade 不能设自定义 header | 后端必须是个 HTTP 服务；认证只能走 cookie 或 query param；终端能力只能靠 PTY 转发 |

注意最后一行那个细节——**"WS upgrade 不能设 `Authorization` header"** 这一条物理事实，
直接决定了 dashboard 的 `/api/pty?token=…` 为什么把 token 放在 query string 里。
后面 §7.3 会再遇到它。

### 0.3 三条铁律

整个多前端体系建立在三条规则上。它们的编号不重要，能背下来重要。

**铁律一：能力住在后端，界面只是视图。**

agent 的循环、工具执行、模型调用、会话持久化、slash 命令语义——全在 Python。
界面负责"把状态画出来"和"把用户意图翻译成一个请求"。

这条的推论很硬：**渲染层里出现任何业务判断都是 bug**。
TUI 里不该有"如果模型是 X 则用 Y 工具"；Desktop 里不该有"如果 profile 是 Z 则覆盖配置"。

**铁律二：一个后端，多个前端；后端的改动有三个消费者。**

`tui_gateway` 同时服务 TUI（stdio）、Desktop（WebSocket）、dashboard 的 `/chat`（HTTP + WS）。
所以在 `tui_gateway` 里改一个事件字段，你要同时想：Ink 会不会崩？Desktop 的
`gateway-contract.generated.ts` 会不会 tsc 报错？dashboard 的 sidecar 转发会不会丢字段？

**铁律三：能用现有界面的扩展点解决，就不要新建界面。**

想加一个"显示 token 用量的小面板"？加一个 Ink 组件（自动出现在 dashboard）。
想加一个"批量管理会话的表格"？加一个 dashboard 的 React 页面（它不构成第二个聊天面）。
想加"第三个聊天窗口"？不要——那是把同一个东西实现三遍。

### 0.4 四个必须先分清的词

| 词 | 指什么 | 关键点 |
|---|---|---|
| **surface（面）** | 一个用户可见的交互界面 | CLI / TUI / Desktop / Web 是四个面 |
| **backend（后端）** | 跑 agent 的 Python 进程 | `HermesCLI` 内嵌的、`tui_gateway`、`hermes serve` 都是后端 |
| **transport（传输）** | 前端和后端之间的字节通道 | stdio / WebSocket / HTTP / PTY |
| **rendering layer（渲染层）** | 只负责画的部分 | Ink（TS）/ React（TS）/ Rich（Py） |

**同一个后端可以换传输**：`tui_gateway` 既有 stdio 入口也有 WebSocket 入口，
两者调用**完全相同**的 `dispatch()`。这不是巧合，是设计（见 §2.3）。

---

## §1 全景对照

### 1.1 主表

| 面 | 入口命令 | 前端技术 | 后端进程 | 传输 | 内嵌 TUI？ | 生命周期 |
|---|---|---|---|---|---|---|
| **CLI** | `hermes` / `hermes --cli` | prompt_toolkit + Rich（Python） | 同进程 `HermesCLI` + `AIAgent` | 函数调用 | 否 | 随终端会话 |
| **TUI** | `hermes --tui` / `HERMES_TUI=1` | Node + Ink（TS/React 语法渲染到字符网格） | 独立 `python -m tui_gateway.entry` | stdio，换行分隔 JSON-RPC | 它本身就是 TUI | 随 Node 进程 |
| **Desktop** | `hermes serve`（由 Electron spawn） | Electron（主进程）+ React + nanostores | 同一个 `tui_gateway` | WebSocket `/api/ws` | **否**（自己的原生聊天界面） | 随 App；后端可池化复用 |
| **Web** | `hermes dashboard` | React + xterm.js | PTY 里跑**真实的 `hermes --tui`** | WebSocket `/api/pty` + `/api/ws` | **是**（真的是 TUI） | 随 dashboard 服务 |

先盯住两行：

- **Desktop 不内嵌 TUI**。它有自己用 React 写的聊天界面，只是复用 `tui_gateway` 当后端。
- **Web dashboard 内嵌 TUI**。它不重写聊天，而是开一个伪终端把 `hermes --tui` 跑起来，
  把 ANSI 字节流推给浏览器里的 xterm.js。

这两条一旦混了，就会写出"在 dashboard 里用 React 重写 transcript"这种被明确禁止的代码。

### 1.2 四张进程树

**CLI（一个进程，没有 IPC）：**

```text
shell
 └─ python cli.py                      ← 一个进程干完所有事
      ├─ HermesCLI（REPL 循环、slash 派发、渲染）
      └─ AIAgent（turn 循环、工具、provider）
```

**TUI（两进程，stdio）：**

```text
shell
 └─ hermes --tui
      ├─ node ui-tui/dist/entry.js     ← TypeScript 拥有屏幕
      │    └─ Ink 渲染 transcript / composer / prompts / activity
      └─ python -m tui_gateway.entry   ← Python 拥有 agent
           └─ AIAgent + tools + sessions
      ▲
      └── 两者之间：stdin/stdout 上的换行分隔 JSON-RPC
```

**Desktop（三进程，WebSocket）：**

```text
Hermes.app
 ├─ Electron main process             ← 拥有机器：进程生命周期、原生 FS/git/窗口、安装更新
 │    └─ spawn: hermes serve --host 127.0.0.1 --port 0
 ├─ Renderer process（React）          ← 拥有体验：导航、呈现、临时交互状态
 └─ python -m tui_gateway ...          ← 拥有工作：会话、工具、模型调用、流式
      ▲
      └── Renderer ⇄ /api/ws（JSON-RPC over WebSocket）
```

**Web dashboard（四进程，PTY + WS）：**

```text
hermes dashboard
 ├─ python hermes_cli/web_server.py   ← FastAPI：REST + /api/ws + /api/pty + SPA 静态文件
 ├─ （浏览器）React SPA
 │    ├─ 其它页面：调 REST
 │    └─ /chat 页：xterm.js ⇄ /api/pty
 └─ PTY 子进程：node ui-tui/dist/entry.js
      └─ python -m tui_gateway.entry
           └─ AIAgent
      ▲
      └── 额外一条反向 WS：tui_gateway → /api/pub（把事件镜像给 sidebar，见 §2.7）
```

**dashboard 的 `/chat` 是四层进程嵌套**。这就是为什么"dashboard 里终端起不来"是个
独立的故障域（可能是 Node 缺失、可能是 PTY 不可用、可能是 TUI 构建产物缺失）。

### 1.3 谁 spawn 谁，谁不能 spawn 谁

| 关系 | 是否发生 | 说明 |
|---|---|---|
| `hermes --tui` → Node → `tui_gateway` | 是 | Node 用 `spawn(python, ['-m','tui_gateway.entry'], {stdio:['pipe','pipe','pipe']})` |
| Desktop Electron → `hermes serve` | 是 | 每个 (连接, profile) 一个，`--port 0` 让 OS 分配端口 |
| `hermes serve` → SPA | **否** | `HERMES_SERVE_HEADLESS=1` 让 `mount_spa()` 直接关掉前端 |
| `hermes serve` → `hermes dashboard` | **否** | 二者是独立面，谁都不启动谁 |
| `hermes dashboard` → `hermes --tui` | 是（经 PTY） | 但走的是 `_make_tui_argv` 的 argv 组装，不是 shell 字符串 |
| `hermes dashboard` → `hermes serve` | **否** | dashboard 自己就是 HTTP 服务 |

"`serve` 和 `dashboard` 共享 `cmd_dashboard` / `start_server` 但互不启动"这一条，
是从 `web/AGENTS.md` 到 `apps/desktop/src/AGENTS.md` 反复强调的。原因是历史：
早期 Desktop 直接调 `dashboard --no-open`，导致它依赖了 dashboard 的构建产物。
现在 `serve` 是解耦出来的名字，但**为了不 brick 旧版本用户，Desktop 保留了回退**（§6.6）。

### 1.4 同一条用户消息，在四个界面里的等价路径

这是理解"共享后端"的最快方式。用户输入「帮我看下这个 bug」：

| 界面 | 前端做的事 | 传输 | 后端入口 | 流回前端的形式 |
|---|---|---|---|---|
| CLI | prompt_toolkit 收一行 | 无 | `HermesCLI._process_one_input` → `AIAgent.chat()` | Rich 直接 print 到 stdout |
| TUI | composer 收一行 | `prompt.submit` | `tui_gateway` 方法 → agent | `message.delta` 事件 → Ink 重绘 |
| Desktop | React composer 收一行 | `prompt.submit` | 同一个 `tui_gateway` 方法 | 同一个 `message.delta` 事件 → React setState |
| Web `/chat` | xterm 把按键字节写进 PTY | 原始字节 | PTY 里的 TUI 进程收到 | PTY 吐出的 ANSI 字节 → xterm 解析 |

最后一行值得停一下：**Web 面耦合的不是"消息"，是"按键"**。
它在 PTY 里跑的是完整 TUI，所以它连 `prompt.submit` 这个 RPC 都看不到——
它看到的是 Ink 渲染出来的字符。这就是"内嵌真 TUI"的字面含义。

### 1.5 代码体量地图

光看代码分布就能看出哪一面是"主战场"：

| 位置 | 文件数 | 行数量级 | 职责 |
|---|---|---|---|
| `cli.py` | 1 | 1,782 | `HermesCLI` 外观类（facade） |
| `hermes_cli/cli_*mixin.py` | 16 | ~17,200 | CLI 的 mixin 行为（第 17 个 `CLIProcessNotificationsMixin` 在 `cli_process_notifications.py`，文件名不匹配 `*mixin.py`） |
| `hermes_cli/` 其余 | 很多 | — | 子命令、配置、skin、update、profiles |
| `tui_gateway/` | 106 | ~43,500 | 共享后端（方法、事件、契约、会话） |
| ├─ `server.py` | 1 | 3,692 | facade：方法表、事件表、`_profile_scoped` |
| ├─ `methods_*.py` | 32 | ~14,180 | 按主题拆的 RPC 方法实现 |
| └─ `contracts/` | 20 | ~8,400 | wire 契约（Pydantic 模型） |
| `ui-tui/src/` | 362 | — | TUI 的 Ink 源码 |
| `apps/desktop/src/` | 2,878 | — | Desktop 渲染进程 |
| `apps/desktop/electron/` | 283（非测试） | — | Desktop 主进程 |
| `web/src/` | 220 | — | Dashboard SPA（20 个页面） |
| `hermes_cli/web_routers/` | 27 | — | Dashboard 后端路由（一文件一面） |

一个反直觉的数字：**`tui_gateway` 比整个 CLI 大一个数量级。**
因为它是三个界面的公共后端，还额外承担了 TUI 特有的富交互（overlay、widget、
subagent 面板、connectors 卡片、bot relay、voice……）。

---

## §2 共享内核 `tui_gateway`

### 2.1 为什么是它成为共享内核

三个需求撞在一起，只剩一个答案：

1. **TUI 需要一个能说"给我发事件"的后端**，因为 Ink 是异步渲染的，不能阻塞在同步调用里。
2. **Desktop 需要同一个后端**，否则它会和 TUI 行为分叉（同一个 `/compress` 在两边不一样，用户会疯）。
3. **dashboard 需要同一个后端**，但它是通过 PTY 间接用的。

所以 `tui_gateway` 的定位是：**把 `AIAgent` 同步的 turn 循环，包装成一个异步、
可订阅、可反问用户的服务端**。

```text
             ┌──────────────────────────────────────────┐
TUI  ──stdio──▶                                          │
Desktop ──WS──▶        tui_gateway（Python 进程）          │
dashboard ──PTY──▶  （PTY 里就是 TUI，所以还是 stdio）      │
             │        ├─ dispatch(method, params)         │
             │        ├─ sessions / profiles / auth       │
             │        └─ AIAgent（同步 turn 循环）         │
             └──────────────────────────────────────────┘
```

**"三个消费者"的实际意思是**：你在 `server.py` 里改的任何一个事件 payload、
任何一个方法的返回结构，都会被这三条路径同时消费。所以 §3 那套契约才不是过度工程。

### 2.2 进程模型与入口

- 入口模块：`python -m tui_gateway.entry`
- facade：[`tui_gateway/server.py`](../tui_gateway/server.py:1)，3,692 行
- 方法实现：`tui_gateway/methods_*.py`，32 个文件
- 事件：`tui_gateway/event_publisher.py` + `event_replay.py`
- 反问用户的请求：`tui_gateway/server_requests.py`
- wire 定义：`tui_gateway/contracts/`

为什么 `server.py` 能保持 3,692 行而不爆炸？因为下面这个机制。

### 2.3 `method_ctx.bind_module`：在运行时"换掉模块全局"

这是本项目最不寻常的一段元编程，不懂它你会看不懂 `methods_*.py` 为什么能直接写
`_sessions[...]`（那是 `server.py` 的全局变量）。

拆开模块时的问题是：`methods_config.py` 里的函数想访问 `server.py` 的 `_sessions`、
`_ok`、`_err` 这些模块全局。常规做法是 `from tui_gateway import server` 然后
`server._sessions`——但那会造成循环导入，而且破坏了"每个方法直接读写裸全局"的可读性。

[`tui_gateway/method_ctx.py`](../tui_gateway/method_ctx.py:22) 的解法：

```python
def rebind(fn, g: dict, _seen=None):
    """复制 fn，把它的 globals 换成 g；闭包里的同模块函数也一起重绑。"""
    ...
    real = types.FunctionType(fn.__code__, g, fn.__name__, fn.__defaults__, closure)
```

用 `types.FunctionType` 拿同一份字节码，配一个**不同的 globals 字典**（就是
`vars(server)`）重新造一个函数对象。结果是：

- 函数体一个字符都没变；
- 里面的 `global X` 依然改的是 `server` 的模块状态；
- 拆分文件在模块级**永远不 import server**（server 把自己传进来），所以没有循环导入。

三个必须知道的坑，注释里都写了：

1. **`@contextlib.contextmanager` 装饰过的函数**要特殊处理：`contextlib` 包了一层 wrapper，
   真正要重绑的是 `__wrapped__` 里那个 generator，然后用 `contextmanager` 重新包。
   代码里用 `_CM_HELPER_CODE` 做身份比对，专门识别这种情况。
2. **闭包里的 cell** 如果装的是同模块的函数，也要递归 `rebind`，否则
   "装饰器工厂在 import 时产出的 handler"会指向旧模块的函数对象。
3. **`_seen` 去重**：函数互相引用会无限递归，用 id 做记忆。

配套的 [`HandlerRegistry`](../tui_gateway/method_ctx.py:53) 做延迟注册：

```python
class HandlerRegistry:
    def method(self, name):        # 就是 @method 的 drop-in
        def dec(fn):
            self._pending.append((name, fn))
            return fn
        return dec

    def profile_scoped(self, fn):  # 就是 @_profile_scoped 的 drop-in
        fn._hermes_profile_scoped = True   # 先打标记
        return fn

    def install(self, server):
        for name, fn in self._pending:
            real = rebind(fn, vars(server))
            if getattr(fn, "_hermes_profile_scoped", False):
                real = server._profile_scoped(real)   # 安装时才真正包一层
            server.register_method(name, real)
```

注意 `profile_scoped` 只是**打个标记**，真正的装饰在 `install()` 里做。
原因：装饰器必须在 server 的作用域里执行才能拿到正确的 `_session_profile_runtime_scope`。

> 记忆点：`methods_*.py` 里写的是"正常代码"，`server.py` 在 import 末尾调用
> `bind_module(globals(), server)` 把它搬进自己的命名空间。所以你 grep 一个方法名时，
> 定义在 `methods_x.py`，运行时的 `__module__` 却可能是 `tui_gateway.server`。

### 2.4 传输：stdio 与 WebSocket 调用同一个 dispatch

[`tui_gateway/ws.py`](../tui_gateway/ws.py:1) 的 docstring 把这件事说得最清楚：

> 复用 `tui_gateway.server.dispatch` **逐字**，所以每个 RPC、slash 命令、审批流、
> agent 事件拿到的 handler 都和 Ink 走 stdio 时完全一样。wire 协议和 stdio 相同
> （双向换行分隔 JSON-RPC；accept 之后立刻发 `gateway.ready`）。

```text
stdio 路径：Ink  ←→  import json 逐行读写
WS 路径：   React ←→  每帧一条 JSON 文本
                     ↓
              同一个 dispatch(method, params)
```

由此得到两个可测试性好处：

- **两边不会行为分叉**：新增方法只要 `dispatch` 认，两种传输都立刻能用。
- **测试只需打一处**：`tests/tui_gateway/` 里的用例覆盖 `dispatch`，就同时覆盖 stdio 和 WS。

WS 侧还多两件事：

1. **`gateway.ready`**：accept 后立刻发，携带 skin、版本、能力等启动信息。客户端靠它
   判断"后端是活的、我知道你支持什么"。
2. **scale-to-zero 心跳**：dashboard / desktop / TUI 客户端每 15 秒 ping 一次；
   WS 层节流到**每个进程每 5 秒最多写一次**标记文件的 mtime
   （`_DASHBOARD_CLIENT_TOUCH_MIN_INTERVAL_S = 5.0`）。网关进程读这个 mtime
   判断"有没有客户端连着"，没有就自动缩容。注意这是**跨进程**通信，用的是文件 mtime，
   不是 socket——因为两个进程之间已经没有直接连接了。

### 2.5 三种帧：call / request / event

JSON-RPC 是**对等**协议。这个项目把它两边都用满了：

| 方向 | 帧类型 | 用途 | 例子 |
|---|---|---|---|
| client → server | **method call** | 客户端调方法 | `prompt.submit`、`session.list` |
| server → client | **request** | **后端反问用户** | `approval`、`clarify`、`sudo`、`secret`、`vault.*`、`connection`、desktop read/act bridges |
| server → client | **event** | 单向通知 | `message.delta`、`tool.start`、`message.complete` |

第二种是本项目最容易被忽略的一半。人类直觉里"JSON-RPC"是"客户端调服务端"，
但 agent 必须能反问：**"我要执行这个命令，你批准吗？"**

#### 2.5.1 request 的 id 规则

`srq-<12 hex>`。为什么不是自增整数？

> 字符串永远不会和客户端自己生成的整数 id 撞；随机部分保证"compute host 子进程的请求"
> 和"父进程的请求"落到同一个 socket 时也能区分。

这解释了一个真实架构：**agent 可能跑在远端 compute host 上**，而 socket 在本地。
两边都必须能安全地发 id。

#### 2.5.2 `send()` 是阻塞的

```text
agent 线程                          renderer
   │                                  │
   │── request(approval, srq-a1b2) ──▶│
   │   （阻塞，等同一 id 的响应帧）      │
   │                                  │ 用户点"批准"
   │◀── response(id=srq-a1b2) ────────│
   │  继续                               │
```

[`server_requests.py`](../tui_gateway/server_requests.py:1) 的注释强调：**没有成对的
`*.request` 通知 + `*.respond` 方法，也没有每种请求自己的 `*.expire`。**
一个 `send()` + 一个响应帧，超时/取消统一发一条 `request.cancel {id, method, reason}`。

统一的好处：**新增一种"问用户"只需要加一个契约，不需要在客户端加一套新的协议配对**。
现在有 approval / clarify / sudo / secret / vault / connection / preview / terminal /
window / tour / MCP 同意 十几种，全靠这一套。

#### 2.5.3 重连：`open_requests`

断线时还挂着的请求怎么办？不靠"事件重放"来恢复，而是：

```python
session.resume / session.activate / session.events.since
    └─ 返回 open_requests(sid)   # 还没被回答的请求列表
```

共享的 TypeScript channel 把它们**当作刚到达的请求重新分发**，所以渲染层代码
不需要区分"新请求"和"重连后恢复的请求"。
注释里点明了这样设计的原因：*通知重放环永远不必承载"一个还在等答案的问题"*。

#### 2.5.4 batch clarify 的 per-question lock

一次 clarify 可以问多个问题。语义：

- 每个问题一把 `clarify.lock`（`lock_answer()`）；
- **答案在所有问题都被 lock 之前仍可修改**；
- 已 lock 的答案**能扛住超时**；
- 最后一个 lock 用完整答案集 resolve 整个请求。

这是一个"表单提交"语义，不是"逐题问答"语义。

#### 2.5.5 window-owned bridge 与 `NOT_SHOWN_CODE = 4404`

有些问题只有**正在显示这个会话的那个窗口**能回答：
`preview.read` / `preview.act` / `terminal.read` / `window.read` / `tour`。

其它连着的窗口看到这个请求时，回一个 `NOT_SHOWN_CODE = 4404` 表示"我这儿没显示它"。
[`server_requests.py:26`](../tui_gateway/server_requests.py:112) 附近的关键规则：

> **一次 decline 不结算请求**——真正的 owner 还可能回答。
> 直到**所有**连着该会话的客户端都 decline 了，才立刻用 `NOT_SHOWN_MESSAGE` 结算，
> 而不是让 agent 干等到 deadline（#119333）。

这条修的是一个很具体的体验 bug：用户开了三个窗口，agent 问一个只有 A 能回答的问题，
B 和 C 都 decline 了，但 A 刚好在后台没渲染——于是用户盯着"等待中"三分钟。

#### 2.5.6 capability 声明与 fail fast

客户端**每个连接说一次**它支持 server→client requests：

```json
{"method": "client.capabilities", "params": {"server_requests": true}}
```

由共享 channel 在 `gateway.ready` 时自动发。没发过的 WebSocket 客户端 = 比这半个协议
更老的 app build，它会**静默丢弃** request 帧。

所以 [`send()`](../tui_gateway/server_requests.py:129) 对这种客户端
**直接返回和"错误响应"一样的 `None`，连帧都不写**（#112548）。

对比一下两种实现的代价：

| 做法 | 旧客户端体验 | agent 体验 |
|---|---|---|
| 照发，等超时 | 用户看不到卡片，一直转圈 | 白等 clarify 的 300 秒 |
| **fail fast** | 立刻收到"无人可问" | 立即可恢复 |

注意这里没有"兼容模式"——**不认识就不发**。这是 §6.6 那条"不要为兼容性携带过去"
的一个正面例子。

### 2.6 事件：seq、epoch、重放上界

[`tui_gateway/event_replay.py`](../tui_gateway/event_replay.py:1) 解决的是
"WebSocket 断了 3 秒，重连后缺的那几条 token 事件怎么办"。

机制：

```text
每条 event 帧（经 server.write_json / _emit）
  ├─ 打上 per-session 单调递增 seq
  ├─ 存进该 session 的小环形缓冲
  └─ 发给所有连着的 transport

重连客户端 → session.events.since(sid, last_seq) → 拿回所有更新的
```

四条不变量（注释里逐条写了）：

| 不变量 | 含义 |
|---|---|
| **stdio TUI 不受影响** | `seq` 只加在 event 帧上；Ink 忽略未知字段 |
| **不会乱序** | 一把锁同时保护计数器和缓冲；`write_json` 本身按 transport 串行化写 |
| **内存有界** | 每 session 最多 512 条 **且** 4 MiB 序列化后字节；全进程最多 64 个 session、共 64 MiB；FIFO 淘汰 |
| **不能撒谎** | 被淘汰或从未保留（超大）的帧会留下 **truncation watermark**，重连客户端据此**重新拉全量**而不是相信有洞的重放 |

还有一个细节值得单独记：**`_REPLAY_EPOCH = uuid.uuid4().hex`**。

seq 计数器是**进程内**的。重启后从 1 重新开始，而客户端还握着高水位（比如 97）。
于是 `events_since(sid, 97)` 会永远返回空、`truncated=False`——客户端以为"没有新事件"，
实际上已经错过了全部。epoch 让客户端一看到就换掉、重置水位。

**为什么快照要冻结成 bytes？**

> 把重放环和活的事件对象解耦：调用方事后修改对象，不能让已经计入配额的缓存条目变大或变样。

这是很实际的内存安全考虑。如果不冻结，你算的 4 MiB 只是"当时的 4 MiB"。

### 2.7 sidecar publisher：dashboard 的侧信道

dashboard 的 `/chat` 是**四层进程嵌套**。sidebar 想显示"当前工具在干什么"，
但事件发生在最里层的 `tui_gateway` 里，而 dashboard 服务在最外层。

[`tui_gateway/event_publisher.py`](../tui_gateway/event_publisher.py:1) 的解法：

```text
tui_gateway.entry 启动时
  └─ 开一条反向 WS 到 dashboard 的 /api/pub
       └─ 每条 emit 镜像一份：换行分隔 JSON（无 JSON-RPC 信封）
            └─ /api/pub 原样广播字节 → /api/events → sidebar
```

传输方式很原始（就转发字节），但三个设计点很讲究：

1. **失败必须静默**：agent 循环**绝不能被 sidecar 阻塞**。
2. **`send` 跑在 daemon 线程**，`write` 入队即返回，**队列满了就丢**
   （`_QUEUE_MAX = 256`）。
3. **WS 一旦死了，后续所有 write 直接短路**（`_dead` 标志）。

这是一个"可观测性可以降级，主流程不能降级"的标准范式。

### 2.8 方法目录：32 个 `methods_*.py`

按主题拆，每个文件一个领域。清单（便于 grep）：

```text
methods_bot_relay          methods_browser_control   methods_browser
methods_complete           methods_complete_helpers  methods_config
methods_config_set         methods_connectors        methods_connectors_account
methods_display            methods_display_watch     methods_free_tier
methods_groups             methods_i18n              methods_images
methods_onboarding         methods_profiles          methods_projects
methods_prompt             methods_session           methods_session_branch
methods_session_control    methods_session_foreign   methods_session_interrupt
methods_session_model_guard methods_shared_metrics   methods_slash
methods_start_chat         methods_subagents         methods_tools
methods_vault              methods_voice
```

体量最大的几个（说明复杂度在哪）：

| 文件 | 行数 | 领域 |
|---|---|---|
| `methods_session.py` | 2,364 | 会话 CRUD、list/resume/activate、事件 |
| `methods_tools.py` | 2,011 | 工具/工具集/toolset 切换、`_profile_scoped_rpc` |
| `methods_prompt.py` | 1,455 | 提交、打断、排队 |
| `methods_voice.py` | 795 | 语音输入/输出 |
| `methods_profiles.py` | 747 | profile 列表与切换 |

加方法时的规则（来自 `tui_gateway/AGENTS.md`）：

> 新 RPC = 新的 `methods_<topic>.py` 或现有主题 sibling 里一条
> **注册进表**——不要 `if method == ...` 链。

### 2.9 profile scope：`@_profile_scoped`

这是 `tui_gateway` 最深的一口井，也是 §14 会重复讲的（那里讲网关版本）。

**问题**：`hermes serve` 一个进程可能同时服务**多个 profile**（Desktop 池化后端、
dashboard 多 profile）。而 `os.environ` 只有**启动 profile** 的值。

[`tui_gateway/server.py:604`](../tui_gateway/server.py:604) 的 docstring 把三个具体症状
写得很明白：

> 只绑 home 会让 `get_secret` 停在启动进程的 `os.environ` 上：
> 对 secondary profile 调用 `config.get full` 会返回 **default profile 展开后的密钥**；
> 而 `config.set` 会把 secondary 的 `.env` 修改**发布进共享的进程环境**。

所以作用域必须**三件一起绑**：

```text
HERMES_HOME      → 配置、状态库、skills 路径
secret scope     → ${VAR} 展开、provider 凭证、.env 读写
terminal policy  → TERMINAL_*（backend、cwd、sandbox）
```

只绑第一件的状态有专门的名字：**half-bound（半绑定）**。

#### 作用域从哪里来

```python
def wrapper(rid, params):
    if params.get("profile"):
        home = _profile_home(params["profile"])
    else:
        # 没有 profile 参数，但有 session_id 指向活会话 → 用那个会话的 profile_home
        session = _sessions.get(params.get("session_id"))
        profile_home = session.get("profile_home")
    with _session_profile_runtime_scope({"profile_home": profile_home}):
        return handler(rid, params)
```

第二个分支修的是一个具体 bug（#85669）：

> TUI 和 Desktop 的环境派发器只带 `session_id` 调 session-bound RPC。
> 于是从"聚焦的 worker 会话"发起的 `config.set` 会**持久化进 LAUNCH profile 的
> config.yaml**，而 worker 自己的没变。

#### 启动 profile 的两种情况

| 情况 | 行为 | 理由 |
|---|---|---|
| 单 profile 进程 | **不加作用域** | 保持 `os.environ` 优先级（systemd / `op run` 注入的凭证要能用） |
| 已激活 multiplex | **绑自己的作用域** | 用激活时冻结的环境快照，**绝不用**可能被 secondary 污染的环境态（#107422） |

"冻结"这个词很重要：一旦多 profile 开始跑，启动 profile 也必须从快照读，
否则某个 secondary 的上下文写入 `os.environ` 后，default profile 会读到别人的密钥。

#### 静态检查的写法

`tui_gateway/AGENTS.md` 给的自检命令：

```bash
rg -n "^(async )?def " tui_gateway/methods_*.py | rg -v _profile_scoped
```

凡是读写 home / config / `.env` 的方法必须在装饰器下面。
**探针要用两个磁盘上的 home**，且 `.env` 里放一个只在 secondary 存在的变量名，
断言：secondary 的值能解析、launch profile 的值不能解析、`os.environ` 事后没变。

#### 离线路径也要绑

不只是 RPC。以下路径的调用者都是"无作用域的收割者 / Timer / atexit / 池线程"：

| 路径 | 绑在哪 |
|---|---|
| `session_lifecycle.py::_finalize_session` | 围绕 `on_session_end`、memory commit、`agent.close()` |
| `session_lifecycle.py::_teardown_session` | 同上 |
| 后台线程 | `agent.memory_provider.spawn_context_thread`，**不要裸 `threading.Thread`** |
| 子进程 | `tools/environments/local.py::served_profile_child_env`（`hermes -p X` worker、`key_cmd`、浏览器驱动），**不要 `dict(os.environ)`** |

### 2.10 新增一个 RPC 的完整步骤

把 §2 和 §3 合起来看，一次新增是五步：

1. **声明契约**：在 `tui_gateway/contracts/<topic>.py` 里加
   `method("my.thing", params=MyParams, result=MyResult, doc="...")`。
2. **实现方法**：在 `tui_gateway/methods_<topic>.py` 里
   `@_registry.method("my.thing")`，需要碰 profile 状态就再加 `@_registry.profile_scoped`。
3. **重新生成**：跑 `scripts/gen_gateway_contracts.py`（会同时更新 TS 与 OpenRPC JSON）。
4. **接前端**：TUI 在 `ui-tui/src` 调 `gw.request('my.thing', ...)`；
   Desktop 在 `apps/desktop/src` 调 `requestGateway('my.thing', ...)`。
   `tsc` 会告诉你字段对不对。
5. **测试**：Python 契约过期测试会失败一次，确认生成物已提交。

如果这一步是"问用户一个问题"，第 4 步改成三处：
`_ask("<method>", sid, params, timeout)`（emitter）+
`apps/desktop/.../server-requests.ts` +
`ui-tui/src/app/createServerRequestHandler.ts`，
契约里用 `server_request(...)` 而不是 `method(...)`。

---

## §3 wire 契约：Python 声明，TypeScript 生成

### 3.1 要防的是什么

三个前端 + 一个后端，如果 wire 是"约定俗成"的，会发生这些事：

- 后端把 `session_id` 改名成 `sid`，TS 那边运行时才炸（`undefined` 传给 RPC）；
- 后端多返回一个字段，没人用，三年后没人敢删；
- 后端漏返回一个字段，前端渲染 `undefined` 而不是报错；
- 客户端多传一个拼错的参数，后端默默忽略，行为诡异。

手工同步解决不了——因为**没有一个地方的代码同时看见两边**。

### 3.2 解决方案：Python 是唯一真相源

```text
tui_gateway/contracts/*.py        ← 人写（Pydantic 模型）
        │
        ├─ scripts/gen_gateway_contracts.py
        │     ├─ apps/shared/src/gateway-contract.generated.ts
        │     └─ apps/shared/src/gateway-contract.openrpc.json
        │
        └─ 运行时（server.py dispatch）用它做校验
```

[`contracts/registry.py`](../tui_gateway/contracts/registry.py:1) 的 docstring：

> 三张表，由 `contracts.*` 主题模块在 import 时填充，被 `server.py`（运行时校验）和
> `scripts/gen_gateway_contracts.py`（TS + OpenRPC 渲染）读取。
> **用 `@method` 注册一个在这里没有契约的名字，会在 import 时失败：wire 上没有未声明的面。**

三张表：

| 表 | 条目类型 | 内容 |
|---|---|---|
| `METHODS` | `MethodContract(name, params, result, doc)` | 客户端能调的方法 |
| `SERVER_REQUESTS` | `ServerRequestContract(...)` | 后端能反问的问题 |
| `EVENTS` | `EventContract(name, payload \| None, doc)` | 后端能推的事件 |

`_declare()` 还会拒绝**重复声明**（`"contract declared twice"`）。

### 3.3 四个基类

[`contracts/base.py`](../tui_gateway/contracts/base.py:1)：

| 类 | 用途 | 默认行为 |
|---|---|---|
| `Params` | 方法/请求的入参 | `extra="forbid"` |
| `Result` | 方法/请求的出参 | `extra="forbid"` |
| `Payload` | 事件的负载 | `extra="forbid"` |
| `WireEnum` | 枚举的基类 | 值即 wire 值 |
| `OpenModel` | **生产者拥有的 dict**（如工具返回的任意 JSON） | 允许额外字段 |

`extra="forbid"` 是核心选择。它的效果是：**任何一边多写一个字段，立刻报错**。
如果允许额外字段，契约就退化成"文档"，而不是"约束"。

`OpenModel` 是唯一的逃生门，且理由明确：**有些 dict 的内容由生产者（比如工具返回值）
决定，契约不可能枚举**。

五条建模规则（base.py docstring）：

1. 每个方法一对 `Params`/`Result`；每个 server request 一对；每个事件一个 `Payload`。
2. 默认 `extra="forbid"`；只有生产者拥有的 dict 用 `OpenModel`。
3. 可选字段用 `X | None = None`，不要用 `Optional` + 隐式默认。
4. 枚举继承 `WireEnum`，**不要**用裸 `str` 当枚举。
5. 不要在这些模型里放逻辑——它们是**声明**。

### 3.4 18 个 topic 模块

```text
base.py                                         # 四个基类
registry.py                                     # 三张表 + 装饰器
common.py                                       # 跨主题共用的小模型
sessions.py                                     # 会话 CRUD / resume / events
prompt_voice.py                                 # 提交、打断、语音
tools_commands.py                               # 工具、slash 命令目录
tools_mcp_plugins.py                            # MCP、插件、skills hub
config_free_tier_control.py                     # 配置、free tier、控制
display.py                                      # 显示偏好、watch
connectors.py                                   # 连接器（账号、OAuth）
connectors_operation.py                         # 连接器长操作
profiles_vault_complete_foreign_subagents.py    # profile / vault / 补全 / 外来会话 / 子代理
groups_bot_relay.py                             # 群组、bot relay
projects_pets.py                                # 项目、宠物（彩蛋面）
billing_delegation_pets.py                      # 计费、委托
i18n.py                                         # 多语言
liveness.py                                     # 心跳/存活
events.py                                       # 全部事件 payload
server_requests.py                              # 全部反问用户的请求
```

注意最后两个是"汇总型"：所有事件在一处，所有 server request 在一处。
好处是"新加一个事件"有唯一正确的位置，且 diff 一眼能看完。

### 3.5 三道校验闸

| 闸 | 时机 | 行为 |
|---|---|---|
| **注册闸** | `import` 时 | `@method` 注册没有契约的名字 → 直接抛 |
| **入参闸** | 每次 dispatch | 未知参数 key → 返回 `4000` + key path |
| **出参闸** | 每次 handler 返回 / 每次 emit | `HERMES_TEST_ISOLATION=1` 时抛 `ContractViolation`；生产只记日志 |

为什么出参闸在生产只记日志？因为**契约不该让用户的会话崩掉**。
但测试环境要抛——这样契约漂移在 CI 里是硬失败。

`4000` 那个错误码值得记：它不是笼统的"bad request"，而是**带 key path**，
告诉你**哪个字段**不被接受。这让"前端多发了一个字段"这种问题一眼可定位。

### 3.6 生成器为什么不支持全部 JSON Schema

[`scripts/gen_gateway_contracts.py`](../scripts/gen_gateway_contracts.py:1)：

> Python-only（Python CI lane 没有 Node）：Pydantic 的 `model_json_schema()` 输出由
> **一个刻意做小的 JSON-Schema 子集渲染器**走一遍——object/properties/required、
> 基础类型、enum、const、anyOf-with-null、array/items、`$ref`、oneOf + discriminator、
> additionalProperties。
> **其它任何东西在生成时抛错**，所以不支持的模型要在模型上修，绝不在输出层绕过。

这个决定很硬核：**故意让生成器"能力不足"，逼模型保持简单。**
如果生成器什么都能处理，就会有人写出前端根本表达不了的模型。

### 3.7 一个字段端到端移动是什么样

假设你把 `session.list` 结果里的 `title` 改名为 `name`：

```text
1. 改 contracts/sessions.py 的 SessionListResult
2. python scripts/gen_gateway_contracts.py
3. tests/tui_gateway/contracts/test_generated.py 通过（生成物已更新）
4. cd ui-tui && npm run typecheck        → Ink 里读 .title 的地方报错
5. cd apps/desktop && npx tsc --noEmit   → React 里读 .title 的地方报错
6. dashboard 的 web/src 也吃 apps/shared → 同样报错
```

**这就是为什么这套契约是值得的**：一次改名，五个消费者在编译期全部被告知，
而不是等用户报告"会话列表显示 undefined"。

---

## §4 CLI 面（经典 REPL）

### 4.1 技术栈

来自 [`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:5)：

| 库 | 干什么 |
|---|---|
| **Rich** | 渲染 banner、面板、表格、markdown、颜色 |
| **prompt_toolkit** | 读取输入、补全、多行编辑、历史、`patch_stdout` |
| **`KawaiiSpinner`** | [`agent/display.py:829`](../agent/display.py:829)：调用 API / 执行工具时的动画与 `┊` 活动流 |

`KawaiiSpinner` 有一组预置动画（dots / bounce / grow / arrows / star / moon / pulse /
brain / sparkle）和两套颜文字（waiting / thinking）。这不是趣味装饰——它承担一个
实际功能：**让用户知道进程没死**。agent 一次 turn 可能跑几十秒，没有反馈用户会 Ctrl-C。

### 4.2 `HermesCLI` 与 17 个 mixin

[`cli.py:894`](../cli.py:894) 是一个纯 facade：

```python
class HermesCLI(CLIInitMixin, CLITuiRuntimeMixin, CLIProcessNotificationsMixin,
                CLIAgentSetupMixin, CLICommandsMixin, CLIBillingMixin,
                CLITuiMixin, CLIStatusBarMixin, CLIVoiceMixin,
                CLIModelSwitchMixin, CLISessionMixin, CLIStreamMixin,
                CLIModalMixin, CLITerminalMixin, CLIInfoMixin,
                CLILoopsMixin, CLIChatTurnMixin):
    """Interactive REPL for the Hermes Agent."""
```

17 个 mixin，逐条说明职责（按行数降序）：

| Mixin | 文件 | 行数 | 管什么 |
|---|---|---|---|
| `CLICommandsMixin` | `cli_commands_mixin.py` | 2,442 | 各 slash 命令的 `_handle_*_command` 实现 |
| `CLITuiMixin` | `cli_tui_mixin.py` | 2,339 | **widgets、keybindings、panel 布局、overlay** |
| `CLIModalMixin` | `cli_modal_mixin.py` | 1,299 | 模态框（审批、clarify、sudo、secret、连接） |
| `CLIStatusBarMixin` | `cli_status_bar_mixin.py` | 1,248 | 底部状态栏（model / token / 时间 / 提示） |
| `CLISessionMixin` | `cli_session_mixin.py` | 1,158 | 会话切换、resume、save、history |
| `CLIBillingMixin` | `cli_billing_mixin.py` | 1,085 | 订阅、充值、用量、登录 |
| `CLIInfoMixin` | `cli_info_mixin.py` | 1,044 | `/status`、`/context`、`/tools`、`/insights` 等信息面板 |
| `CLIModelSwitchMixin` | `cli_model_switch_mixin.py` | 957 | `/model` 选择器与切换逻辑 |
| `CLIAgentSetupMixin` | `cli_agent_setup_mixin.py` | 878 | 构造/重建 `AIAgent`、toolsets、provider 解析 |
| `CLIVoiceMixin` | `cli_voice_mixin.py` | 843 | 语音录制/播放 |
| `CLIStreamMixin` | `cli_stream_mixin.py` | 807 | 流式输出的 CLI 侧消费 |
| `CLILoopsMixin` | `cli_loops_mixin.py` | 752 | `/loop`、`/goal`、主动循环 |
| `CLIChatTurnMixin` | `cli_chat_turn_mixin.py` | 746 | 单次 turn 的执行与后处理 |
| `CLITerminalMixin` | `cli_terminal_mixin.py` | 668 | 终端相关（清屏、title、mouse、粘贴） |
| `CLITuiRuntimeMixin` | `cli_tui_runtime_mixin.py` | 493 | **run-loop 阶段**：输入派发、启动、信号、关闭 |
| `CLIInitMixin` | `cli_init_mixin.py` | 456 | `__init__` 的各个阶段 |
| `CLIProcessNotificationsMixin` | `cli_process_notifications.py` | — | 后台进程完成通知 |

`CLITuiRuntimeMixin` 的主循环骨架（[`cli_tui_runtime_mixin.py:31`](../hermes_cli/cli_tui_runtime_mixin.py:31)）：

```text
_tui_process_loop()
  ├─ _tui_print_startup()                # banner、欢迎、警告
  ├─ _tui_startup_prewarm_and_warnings() # 预热 agent、skin
  ├─ _tui_startup_background_maintenance()
  ├─ _tui_build_application()            # prompt_toolkit Application
  ├─ _tui_install_signal_handlers()
  └─ 循环:
       ├─ _tui_idle_tick()               # 空闲时：通知、spinner、状态栏刷新
       ├─ _tui_process_one_input(line)
       │    └─ 是 slash → _tui_run_slash_input()
       │       否则     → 一个 turn
       └─ _tui_after_turn()              # 记忆、压缩检查、队列
```

注意名字里都有 `_tui_` 前缀——虽然这是"经典 CLI"，但它的组件框架就是
prompt_toolkit 的 `Application`（内部代号沿用 "tui"）。**这和 `hermes --tui` 是两个东西**，
别混。

### 4.3 启动：TUI 还是经典 CLI 是怎么决定的

[`hermes_cli/main.py:284`](../hermes_cli/main.py:284) 的 `_wants_tui_early()`，
优先级严格有序：

```text
1. argv 里有 --cli          → 经典 CLI（绝对优先，能覆盖一切）
2. HERMES_TUI=1 或 --tui / --native / --tui-native → TUI
3. 不是真 TTY（stdin+stdout 都必须是）           → 经典 CLI
4. display.interface 配置                         → 按配置
```

第 3 条的注释解释了一个**必须记住**的坑：

> TTY 闸对无头 spawner（kanban worker、cron、管道里的 `chat -q`）是**承重的**：
> 一个 `display.interface: tui` 的默认值曾经在这里启动 TUI，而 TUI 的
> "no TTY 直接 exit 0" 会让任务**什么都没做就成功退出**。

这是一类典型事故：**"优雅退出"变成了"静默失败"**。
显式 `--tui` 仍然会走到那个"有信息量的 bail-out"，但默认配置不会。

`_is_tui_chat_launch()` 还额外加了一个限制：只有 chat 命令（`None` 或 `chat`）才能启 TUI。
注释说明如果不管，`mcp serve` / `gateway` / `acp` / `cron` 会被误判，
导致 wrapper 预热一次 MCP 发现、TUI gateway 又跑一次，**同一个 stdio MCP server
被启动两份，其中一份整场会话都空转**。

### 4.4 Slash 派发：查表 + 命名约定，没有 elif 阶梯

这是 CLI 面最重要的机制。[`cli.py:1174`](../cli.py:1174) 的 `process_command()`：

```text
process_command(command, redispatch=False)
  │
  ├─ 1. 规范化
  │     cmd_lower = command.lower().strip()   # 只用于匹配
  │     cmd_original = command.strip()        # 参数保留大小写
  │
  ├─ 2. 别名解析（走中央注册表 hermes_cli/commands.py）
  │     base_word = cmd_lower.split()[0].lstrip("/")
  │     cmd_def   = resolve_command(base_word)
  │     canonical = cmd_def.name if cmd_def else base_word
  │
  ├─ 3. 埋点（redispatch=True 时不重复计数）
  │     record_slash_command(command=canonical, surface="cli")
  │
  ├─ 4. 插件 pre_command 钩子（只观察，忽略返回值，绝不抛）
  │
  ├─ 5. 一次性 /resume 提示解除武装（#34584）
  │     if canonical not in {"resume", "sessions"}: self._pending_resume_sessions = None
  │
  ├─ 6. 查派发表
  │     entry = _slash_handler(canonical)
  │     有 → handler(cmd_original) 或 handler()
  │          返回值 is not False（False 表示退出 REPL）
  │     无 → _process_unregistered_slash(...)
```

#### `_SLASH_DISPATCH` 的形状

[`cli.py:1139`](../cli.py:1139)：

```python
# canonical command -> (method name, pass cmd_original?)
_SLASH_DISPATCH: dict[str, tuple[str, bool]] = {
    "exit": ("_cmd_exit", True), "quit": ("_cmd_exit", True),
    "help": ("_cmd_help", True),
    "palette": ("_open_command_palette", False),
    ...
}
```

两个字段：

- **method name**：`getattr(self, method_name)`，所以 monkeypatch 有效（注释明说了）；
- **pass_arg**：要不要把原始命令行传进去（`/model gpt-5` 需要，`/verbose` 不需要）。

#### 命名约定回退

[`cli.py:1163`](../cli.py:1163)：

```python
@classmethod
def _slash_handler(cls, canonical: str) -> tuple[str, bool] | None:
    entry = cls._SLASH_DISPATCH.get(canonical)
    if entry is None:
        name = f"_handle_{canonical.replace('-', '_')}_command"
        if callable(getattr(cls, name, None)):
            entry = (name, True)
    return entry
```

所以新增一个命令有两条路：

| 路 | 何时用 |
|---|---|
| 在 `_SLASH_DISPATCH` 加一行 | 方法名/参数传递方式与约定不符 |
| 直接写 `_handle_<name>_command(self, cmd)` | 符合约定，**零注册** |

[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:30) 那句加粗的话：

> **There is no `elif` ladder — do not add one.**

为什么值得写进 AGENTS.md？因为一个 100+ 命令的 REPL，elif 阶梯会长成 3000 行的
单函数，圈复杂度爆表，改一个命令要读完全部。查表 + 约定是唯一可维护的形状。

#### 未注册命令的优先级

[`cli.py:1206`](../cli.py:1206) `_process_unregistered_slash()`，**严格按顺序**：

```text
1. quick_commands（config.yaml 里用户自己定义的）
2. plugins（插件注册的 slash handler）
3. skill bundles（技能包）
4. skill commands（单个技能）
5. prefix expansion（前缀/别名展开，可能歧义报错）
```

每一层的语义：

| 层 | 来源 | 两种类型 |
|---|---|---|
| `quick_commands` | `config.yaml` 的 `quick_commands` | `type: exec` 跑 shell 片段；`type: alias` 重新派发（`redispatch=True`） |
| `plugins` | 插件 manifest | 插件提供 handler |
| `skill_bundles` | 技能包目录 | 一组技能的组合 |
| `skill_commands` | `~/.hermes/skills/` | 技能派生命令 |
| prefix expansion | 上述所有 + 内置 | `/hea` → `/heartbeat` |

**顺序本身是设计**：用户自定义优先于插件，插件优先于技能。
如果你写了一个 `/deploy` quick command，它不会被同名的 skill 抢走。

一个必须知道的约束（[`hermes_cli/AGENTS.md`](../hermes_cli/AGENTS.md:33)）：

> Skill slash 命令（`agent/skill_commands.py`）扫描 `~/.hermes/skills/`，
> 作为 **user message** 注入，**绝不**注入 system prompt（prompt caching）。

这是第 04 篇讲过的缓存铁律在 CLI 面的体现：技能展开的正文是**这一轮的用户消息**，
不是系统提示的一部分，所以不会破坏前缀缓存。

### 4.5 交互规则（三条硬规则）

#### 规则一：所有交互式菜单选择器用 curses

[`hermes_cli/curses_ui.py`](../hermes_cli/curses_ui.py:1)，范例
[`hermes_cli/tools_config.py`](../hermes_cli/tools_config.py:1)。

为什么不都用 prompt_toolkit？因为**"选择器"和"输入行"是两种交互**：
多选、方向键移动、模糊过滤、分组标题——这些在 curses 里是自然的，
在 prompt_toolkit 的行内模式里要手搓状态机。

`curses_ui.py` 提供的核心件：

| 函数 | 作用 |
|---|---|
| `radio_item_plain()` | 单选行渲染 |
| `_filter_indices()` / `_fuzzy_score()` | 模糊过滤 |
| `_draw_radio_item()` | 带光标的行绘制 |
| `set_menu_navigation_handler()` | 让 TUI 层能接管导航键（返回 token） |
| `reset_menu_navigation_handler(token)` | 归还 |

那个 token 机制是为了**嵌套安全**：菜单里再开菜单，退出内层要恢复外层的 handler。

#### 规则二：绝不在 spinner/display 代码里输出 `\033[K`

```python
# 错误
print(f"\r{line}\033[K")

# 正确
print(f"\r{line}{' ' * pad}")
```

`\033[K` 是 ANSI 的 "erase to end of line"。在 prompt_toolkit 的 `patch_stdout`
环境下它会**泄漏成字面量 `?[K`**——用户屏幕上出现乱码。

原因：`patch_stdout` 把 stdout 重定向进 prompt_toolkit 的渲染缓冲，而它的转义序列
解析器只认自己产生的那批。你的裸 `\033[K` 被当成普通文本转义处理，`\033` 变成一个
不可打印字符，`[K` 原样输出。

空格填充没有这个问题，因为它是纯文本。代价是要自己算 padding 宽度——
所以 `agent/display.py` 里有一堆 `_clip()` / `_tail_trunc()` / `_oneline()` 工具函数。

#### 规则三：包装型 CLI 通过受保护 hooks 扩展，不要 override `run()`

[`cli_tui_mixin.py`](../hermes_cli/cli_tui_mixin.py:132) 的 `CLITuiMixin` 提供了一整套
`_get_*_fragments()` / `_tui_handle_*()` 钩子。清单按用途分组：

**布局与渲染：**

| 钩子 | 作用 |
|---|---|
| `_get_tui_prompt_fragments()` | 输入框提示符片段 |
| `_get_tui_prompt_symbols()` | 提示符符号 |
| `_build_tui_style_dict()` | 样式表 |
| `_apply_tui_skin_style()` | 应用当前 skin |
| `_build_tui_layout_children()` | 整页布局子元素 |
| `_get_extra_tui_widgets()` | 额外 widget |
| `_tui_hint_text()` / `_tui_placeholder_text()` | 提示/占位文案 |
| `_tui_input_rule_height()` | 输入框上下分隔线的位置 |
| `_tui_spinner_loop()` | 动画循环 |

**浮层片段（每个返回一组 fragment）：**

`_get_slash_confirm_display_fragments`、`_get_approval_display_fragments`、
`_get_clarify_display_fragments`、`_get_model_picker_display_fragments`、
`_get_command_palette_display_fragments`、`_get_sudo_display_fragments`、
`_get_secret_display_fragments`、`_get_connection_display_fragments`、
`_get_stash_panel_display_fragments`

**按键处理：**

`_register_extra_tui_keybindings`、`_tui_handle_tab`、`_tui_handle_ctrl_c`、
`_tui_handle_ctrl_d`、`_tui_handle_ctrl_l`、`_tui_handle_ctrl_q`、`_tui_handle_ctrl_v`、
`_tui_handle_ctrl_z`、`_tui_handle_alt_v`、`_tui_handle_double_escape`、
`_tui_handle_escape_modal`、`_tui_handle_open_in_editor`、
`_tui_handle_ignored_terminal_sequence`

**状态机：**

`_tui_cancel_foreground_ui`、`_tui_clear_blocking_overlays`、`_tui_clear_or_exit`、
`_tui_restore_stash_payload`、`_tui_recall_without_recollapse`

为什么不能 override `run()`？因为 `run()` 里有：信号处理、终端模式恢复、
关闭看门狗、`patch_stdout` 的进入/退出、异常兜底。包装者 override 它，
等于把这些**全部重写一遍**，然后每次上游修 bug 都要重新抄。

用 hooks 的话，上游新增一个阶段，包装者自动获得。

### 4.6 配置系统：三个 loader，用错就是"CLI 看得见网关看不见"

| Loader | 使用者 | 合并 `DEFAULT_CONFIG`？ | 额外行为 |
|---|---|---|---|
| `load_cli_config()` | CLI（`cli.py`） | **是** | CLI 专用默认值 |
| `load_config()` | `hermes tools` / `hermes setup` / 大多数子命令 | **是** | — |
| `load_user_config_effective()` | **网关运行时、TUI gateway、cron、`hermes send`、doctor** | **否** | 用户文件 + 托管 overlay + `${VAR}` 展开 + model-key 规范化 |

第三个的"否"是关键。它意味着：**用户文件里没写的 key，这里就是没有**——
不会凭空出现一个默认值,让"未设置"和"设成了默认值"无法区分。

诊断口诀（原文就是这句）：

> 「CLI 看到某 key 而网关看不到（或反之）」= 你用错了 loader，检查 `DEFAULT_CONFIG` 覆盖。

#### 配置写入只有一个缝

```text
atomic_config_write(...)     → 局部写：只改指定 key，拒绝"因遗漏而删除"
atomic_config_replace(...)   → 全状态写：明确替换整份
```

**绝不对 config 路径调 `yaml.dump` / `yaml.safe_dump`。**
CI 有专门的 lint（`scripts/check_config_yaml_writers.py`）拦这个。

为什么这么严？因为 `yaml.dump` 会丢掉：注释、键顺序、锚点/别名、块标量风格。
用户手写的 `config.yaml` 里那些注释是有价值的，一次 `dump` 全没了。
更糟的是"读-改-写"模式下，如果读的时候用了带默认值的 loader，
写回时会把所有默认值**固化**进用户文件。

### 4.7 Skin 引擎：skin 是纯数据

[`hermes_cli/skin_engine.py`](../hermes_cli/skin_engine.py:1)：

| 函数 | 作用 |
|---|---|
| `SkinConfig`（`:14`） | 一份 skin 的数据结构（颜色、图标、分隔符……） |
| `_BUILTIN_SKINS`（`:63`） | 内置皮肤字典 |
| `load_skin(name)`（`:424`） | 加载：用户 `~/.hermes/skins/*.yaml` → 内置 → default |
| `get_active_skin()`（`:433`） | 带缓存地取当前 skin |
| `set_active_skin(name)`（`:449`） | `/skin` 命令用 |
| `get_active_skin_name()`（`:462`） | 取名字 |
| `init_skin_from_config(config)`（`:470`） | 启动时从 `display.skin` 初始化 |

两个设计点：

1. **新增一个 skin 不需要改代码**。放一个 YAML 到 `~/.hermes/skins/` 就行。
2. **缺值从 `default` 继承**（`load_skin` 的 `or _BUILTIN_SKINS["default"]`）。
   所以一个 skin 只需声明它想改的字段。

内置皮肤：`default`、`ares`、`mono`、`slate`。

Skin 的影响面比想象的大：它同时影响 CLI 的 Rich 渲染、TUI 的主题（通过 `gateway.ready`
传给 Ink）、以及 dashboard 的 `apps/shared/src/skin.ts`。
所以 `SkinConfig` 是**跨三个前端的共享数据契约**——这也是它必须是纯数据的原因。

### 4.8 退出与 `-q`

两个独立机制，机构都在 sibling 里：

**退出看门狗** —— [`hermes_cli/cli_shutdown.py`](../hermes_cli/cli_shutdown.py:1)：

> 经典 CLI 的关闭与一次性收尾助手：进程 session-id 同步、延迟 agent 启动、
> **退出看门狗**、清理步骤、session-finalize 通知、终端输入模式重置。

"看门狗"意味着关闭是**有超时的**：某个清理步骤卡住（比如网络请求），
进程不能永远不退出。同时必须有**一次性收尾**（`_cleanup_done` 这类标志），
因为 `atexit` + 信号 + 正常返回可能都触到同一条路径。

**单次查询** —— [`hermes_cli/cli_single_query.py`](../hermes_cli/cli_single_query.py:1)：

> 单次查询（`-q` / one-shot）助手：kanban goal 循环、**退出码映射**、静默单次查询 runner、
> 图片路由、信号处理器、单次模式编排器。

`hermes -q "..."` 是**脚本接口**，所以：

- 输出必须可预测（不能有 spinner 污染 stdout）；
- **退出码有语义**（成功/失败/被中断要能区分，脚本靠这个判断）；
- 不能交互（不能等审批；要么预授权要么失败）。

---

## §5 TUI 面（`ui-tui` + `tui_gateway`）

### 5.1 `ui-tui` 的结构

```text
ui-tui/
├── packages/hermes-ink/       # 定制的 Ink（React 渲染到字符网格）
├── src/
│   ├── entry.tsx              # Node 入口（#!/usr/bin/env node --max-old-space-size=8192 --expose-gc）
│   ├── app.tsx                # 顶层应用
│   ├── gatewayClient.ts       # 808 行：spawn python、stdio JSON-RPC、attached socket
│   ├── gatewayTypes.ts        # 从 contracts 生成的类型的使用方
│   ├── components/            # 41 个 Ink 组件
│   ├── app/                   # 40+ 个状态模块（stores、handlers、hooks）
│   ├── hooks/                 # useCompletion 等
│   ├── app/slash/             # 本地 slash 命令注册表（8 个分组）
│   ├── i18n/                  # TUI 侧文案（只发英文，见 §8）
│   ├── lib/                   # 终端模式、graceful exit、内存监控
│   ├── protocol/              # wire 相关
│   └── sdk/                   # 轻量类型
├── vitest.config.ts
└── package.json
```

362 个 `.ts`/`.tsx` 文件。**41 个组件**（部分关键件）：

| 组件 | 对应界面元素 |
|---|---|
| `messageLine.tsx` | 一条消息 |
| `streamingAssistant.tsx` / `streamingMarkdown.tsx` | 流式输出 |
| `thinking.tsx` | 工具活动流（`┊`） |
| `prompts.tsx` | 审批 / clarify / sudo / secret |
| `maskedPrompt.tsx` | 掩码输入（密钥） |
| `modelPicker.tsx` | 模型选择器 |
| `activeSessionSwitcher.tsx` | 会话切换 |
| `agentsPanel.tsx` / `agentsOverlay.tsx` | 子代理面板 |
| `todoPanel.tsx` | 待办列表 |
| `goalBar.tsx` | 目标进度条 |
| `queuedMessages.tsx` | 排队中的消息 |
| `connectorsOverlay.tsx` | 连接器 |
| `pluginsHub.tsx` / `skillsHub.tsx` | 插件/技能中心 |
| `billingOverlay.tsx` / `subscriptionOverlay.tsx` | 计费 |
| `petSprite.tsx` / `petPicker.tsx` | 宠物（彩蛋面） |
| `banner.ts` | 启动横幅 |

### 5.2 启动链

```text
hermes --tui
  └─ hermes_cli/main_tui_launch.py
       └─ _make_tui_argv(tui_dir, tui_dev)   ← 决定跑什么
            │
            ├─ ① --dev 且 HERMES_TUI_DIR 设了 → 报错退出（"prebuilt 没有源码可热更"）
            ├─ ② HERMES_TUI_DIR 里有 dist/entry.js → node --expose-gc <那个>
            ├─ ③ _find_bundled_tui() 找到 hermes_cli/tui_dist/entry.js → node --expose-gc <那个>
            ├─ ④ 否则 _ensure_tui_workspace() 确保 ui-tui/ 存在，npm install / build
            └─ ⑤ --dev → tsx src；否则 node dist
```

②③ 在 ④ **之前**，`main_tui_launch.py:166` 的注释说明这是一个真实事故（#56665）：

> 一个预构建安装（Docker 镜像、Nix 构建、或之前 `npm run build` 过）会带
> `hermes_cli/tui_dist/entry.js`，但**从不带 `ui-tui/` 目录**（那个目录只在 git
> checkout 里存在）。所以"先要求 workspace 存在"会让每个预构建的 dashboard Chat tab
> 连接在还没机会试它自己已有的 bundled entry.js 之前就硬退出。

然后是 `ui-tui/src/entry.tsx` 自己做的三件事：

```typescript
if (!process.stdin.isTTY) {
  console.log(messages().chatBits.entry.noTty)
  process.exit(0)          // ← 就是 §4.3 说的"静默失败"风险点
}

resetTerminalModes()       // 上一次 kill -9 可能留下 mouse/focus/paste 模式
setupGracefulExit()        // 信号/未捕获错误时也重置终端
```

`resetTerminalModes()` 那行注释很实在：**"如果上一个 TUI 崩了或被 kill -9，
这个终端标签页可能还开着 mouse/focus/paste 模式"**——用户回到 shell 后
发现鼠标变成转义序列乱码。这是终端应用的经典坑。

### 5.3 Slash 命令的三段流

这是 TUI 面最值得细看的部分。完整流程（[`ui-tui/src/app/createSlashHandler.ts`](../ui-tui/src/app/createSlashHandler.ts:30)）：

```text
用户输入 "/compress"
  │
  ├─ parseSlashCommand()  → { name: "compress", arg: "" }
  ├─ flight = ++slashFlightRef.current     ← 竞态守卫：旧请求的响应被丢弃
  ├─ sid = 当前会话 id
  │
  ├─【第一段：本地注册表】findSlashCommand(name)
  │    └─ 命中 → 直接跑（/help /quit /clear /resume /copy /paste /mouse /density …）
  │         └─ countTyped() 上报 shared_metrics.slash_command
  │         └─ return true  ← 到此为止，不碰后端
  │
  ├─【第二段：widget app 注册表】getWidgetApp(name)
  │    └─ 命中 → launchWidget()
  │
  ├─【第三段：catalog 别名/前缀解析】
  │    ├─ catalog.canon 里有精确别名 → handler(`${canonical}${argTail}`, typed)
  │    └─ 否则做分层评分（prefix 优于 substring）
  │         ├─ 唯一最佳匹配 → 重新 handler()
  │         └─ 多个 → "ambiguous command: ..."
  │
  └─【第四段：带给后端】gw.request('slash.exec', { command, session_id })
       │
       ├─ 成功 → handleDispatch(响应)
       │    ├─ {type:"exec"|"plugin"}  → 打印 output
       │    ├─ {type:"alias"}          → 重新 handler(`/${target}${argTail}`, false)
       │    ├─ {type:"skill"}          → send(message, true, display)
       │    ├─ {type:"send"}           → 可能先 sys(notice)，再 send
       │    └─ {type:"prefill"}        → 把文本填进 composer（不提交）
       │
       └─ 失败 → shouldFallbackToDispatch(err) ?
            ├─ 是 → gw.request('command.dispatch', {...}) 再 handleDispatch
            └─ 否 → sys("error: ...")，不fallback
```

#### 为什么会话要"四段"

每一段都是一个不同的所有权边界：

| 段 | 所有者 | 例子 | 为什么在这里 |
|---|---|---|---|
| 一 | **Ink 进程** | `/mouse`、`/density`、`/copy` | 纯显示/终端行为，后端完全不知道这些概念 |
| 二 | **widget 注册表** | 用户放在 `$HERMES_HOME/tui-widgets` 的 app | 静态表构建之后才注册，必须查活的注册表 |
| 三 | **catalog（后端数据的本地镜像）** | 别名、前缀 | 需要 `complete.slash` 的数据，但展开是纯字符串操作 |
| 四 | **Python 后端** | `/compress`、`/model`、技能命令 | 需要 agent、配置、文件系统 |

第 2 段的注释解释了它为什么不能合并进第 1 段：

> Registry-first fallback：在静态命令表构建**之后**注册的 widget app
> （来自 `$HERMES_HOME/tui-widgets`、`/widgets-reload`）直接从活注册表派发。

第 3 段的分层评分（注释里说移植自 grok-cli）有个精细规则：

> 只有**最佳层**存活——一次 substring 命中**绝不**把一次无歧义的 prefix 命中
> 拓宽成"ambiguous command"抱怨。
> 描述层的命中（score ≥ 3）属于补全菜单的范畴，**绝不**在这里自动执行命令。

翻译：`/hea` 应该解析成 `/heartbeat`（prefix）；但如果用户打 `/beat`，
它是 substring 命中——也能找到 `/heartbeat`，但**只在不引起歧义时**才自动执行。
而"描述文本里包含 beat"的命中只出现在补全菜单里，不会被回车直接执行。

#### 失败回退为什么这么窄

[`ui-tui/src/app/userMessages.ts`](../ui-tui/src/app/userMessages.ts:199)：

```typescript
export const shouldFallbackToDispatch = (err: unknown): boolean => {
  const { code, message } = rpcShape(err)

  if (code === RPC_NOT_DISPATCHABLE) {        // 4018
    return NOT_MINE_REFUSAL_RE.test(message ?? '')
  }
  if (code !== undefined) return false

  // 老后端没有 code，保持历史行为，除非明确是 helper 故障
  return !/slash worker|timed out|not connected|not running/.test(message ?? '')
}
```

`NOT_MINE_REFUSAL_RE` 精确匹配两句话：

```text
^skill command: use command\.dispatch for \/
use command\.dispatch for \/snapshot restore
```

注释解释了为什么必须这么窄：

> `slash.exec` 用**恰好**这些文案回 4018 表示它**不拥有**这个命令。
> 其它所有 4018 都来自 `slash.exec` 已经转发过的 `command.dispatch` handler
> （`/retry`、`/undo`、`/compress`、`/queue`、bundles）：**再派发一次会把变异命令跑两遍**。

这是一个"回退不能太宽"的教科书案例：`/compress` 已经开始压缩了，
如果因为某个无关的 4018 又 dispatch 一次，用户的历史会被压缩两遍。

还有一条：**helper 超时/崩溃（5030）必须原样显示**。

> 回退的 "not a quick/plugin/bundle/skill command" 拒绝文案**曾经埋掉了真正的原因**，
> 让用户以为命令不存在。

#### 谁在计数

```typescript
/** 用户打的命令在客户端计一次：网关不再统计 slash.exec，
 *  所以本地处理的 /resume、/skin、overlay 也能被计入。
 *  fire-and-forget；后端负责把原始名字规范化。 */
export function reportSlashCommand(gw, name, sid): void {
  gw.request('shared_metrics.slash_command', { command: name, ...(sid ? { session_id: sid } : {}) })
    .catch(() => undefined)
}
```

`typed` 参数的三个语义（注释写得很细）：

- `typed = false` → 程序化调用（选择器重新发 `/model <x>`）和**后端的 alias 重新派发**；
- **前缀/别名展开保留 `typed`**，所以用户打的 `/hea` 在解析成 `/heartbeat` 后**只计一次**。

### 5.4 key surfaces 表

| 界面元素 | Ink 组件 | Gateway 方法 / 事件 |
|---|---|---|
| 聊天流式 | `app.tsx` + `messageLine.tsx` | `prompt.submit` → `message.delta` / `message.complete` |
| 工具活动 | `thinking.tsx` | `tool.start` / `tool.generating` / `tool.complete` |
| 审批 | `prompts.tsx` | server→client request `approval` → 响应 `{choice}` |
| Clarify / sudo / secret | `prompts.tsx`、`maskedPrompt.tsx` | server→client requests `clarify` / `sudo` / `secret` |
| 会话选择器 | `activeSessionSwitcher.tsx` | `session.list` / `session.resume` |
| Slash 命令 | 本地 handler + fallthrough | `slash.exec` → `_SlashWorker`；`command.dispatch` |
| 补全 | `useCompletion` hook | `complete.slash`、`complete.path` |
| 主题 | `theme.ts` + `branding.tsx` | `gateway.ready` 携带 skin 数据 |
| 连接器操作（desktop 卡片也用） | — | `connection.request` → `connection.update`* → `connection.respond {op_id}`；`connectors.operation.status` |

补全那一行有个很实际的陷阱（`tui_gateway/AGENTS.md`）：

> 在非本地的 `terminal.backend` 下，`complete.path` **通过会话的 terminal backend**
> 列目录——**绝不是 gateway 主机**。后者同名目录树看起来是对的，但是错的。

这是"看起来对但实际错"的典型：你在远端容器里工作，补全列出了宿主机的文件，
你选了，然后工具在容器里找不到。

### 5.5 `_SlashWorker` 与 `_PENDING_INPUT_COMMANDS`

有些命令跑在**持久子进程**里（[`server.py:255`](../tui_gateway/server.py:255) 的
`_SlashWorker`）。为什么？因为 slash 命令可能构造 `AIAgent`（比如 `/context` 需要
真实 token 统计），那会污染主进程状态。

但有 17 个命令**不能**在 worker 里跑——它们要往 `_pending_input` 队列塞东西，
而 **slash worker 没有那个队列的读者**：

```python
_PENDING_INPUT_COMMANDS = frozenset({
    "retry", "queue", "q", "steer", "plan", "goal", "loop", "proactive",
    "moa", "undo", "learn", "init", "compress", "compact",
    "initiate-setup", "initiate_setup",
})
_WORKER_BLOCKED_COMMANDS = frozenset({"snapshot", "snap"})
```

所以 `slash.exec` 把这些命令**路由到 `command.dispatch`**。这正好解释了 §5.3 里
那个"4018 且文案是 use command.dispatch"的分支——那不是错误，是**约定好的移交**。

还有一个 `/context` 的特殊案例值得记（`methods_slash.py` 的注释）：

> 本地会话的 `/context` 在**进程内**回答：slash worker 是个 CLI 子进程，
> 它的 `self.agent` 只在第一次 chat prompt 时惰性构建，**slash 命令永远不构建它**，
> 所以对任何本地会话它都答 "(._.）No active agent"（#81251 / #93280）。

而 `tools` / `help` 保持旧路由，因为 `_format_live_tools_output` 读 `session["agent"]`，
对无 agent 会话"在这里服务会更差，不是更好"。

**这三条判断（哪些在本地、哪些在 worker、哪些走 dispatch）没有统一规则，
只有"这个命令需要什么"的具体分析。** 新增 slash 命令时要先问：它需要 agent 吗？
需要 pending queue 吗？需要显示层状态吗？

### 5.6 子代理快照

`subagent.list({session_id})` 的语义（`tui_gateway/AGENTS.md` 有一整节）：

```json
{
  "subagents": [...],     // 可读的花名册
  "delegations": []       // 异步完成单元：不是 agent，没有精确 generation 权限
}
```

三条关键规则：

1. **花名册跟随"对话"，不是"会话 id"**。
   Records = 精确 owner 的记录 **+** durable lineage
   （`owner_agent_session_id` → compression tip）属于本会话 agent 的子进程。
   原因：**Desktop 重连/resume 会重新铸造 UI session id，压缩会轮换 key，
   而子进程还在跑**（#114909）。
2. **控制（`steer` / `interrupt` / `tail`）钉死在精确的 session record + transport 上**。
3. **子进程权限在 RPC 时对"owner 会话的活 transport slot"解析**，
   所以每个已认证的重新挂载路径（`prompt.submit`、队列 drain、resume、activate、
   viewer failover）自动带着它，**不需要 registry 记账**。

第 3 条后面那句禁令很重要：

> **绝不要在 attach 点加 per-record transport 同步**；外来或已退休的 generation
> 保持不可控。

`subagent.tail` 返回 `{subagent_id, available, text, truncated}`，
**最后 16 KiB** 活子进程已有 transcript。三个限制：

- 只轮询选中项（不批量拉）；
- 缺失/已完成/外来的子进程返回 unavailable 空快照；
- **不打开任何客户端提供的路径**（安全）。

### 5.7 开发命令

```bash
cd ui-tui
npm install       # 首次
npm run dev       # watch 模式（重建 hermes-ink + tsx --watch）
npm start         # 生产
npm run build     # 完整构建（hermes-ink + tsc）
npm run typecheck # tsc --noEmit
npm run lint      # eslint
npm run fmt       # prettier
npm test          # vitest
```

Python 测试在 `tests/tui_gateway/`，用 `scripts/run_tests.sh`。

一条测试边界规则（`tui_gateway/AGENTS.md`）：

> 一个断言 `package.json` / `.ts` 源码的 **Python 测试**在 JS-only PR 上不会运行——
> 把 JS 侧的断言留在 vitest 里。

这条来自整体测试规则（第 15 篇会展开）：**不要写读源码做断言的测试**。
如果你要验证"某个 TS 文件里有某个导出"，那是 change-detector，不是行为契约。

---

## §6 Desktop 面（Electron）

Desktop 有一份独立的工程判断指南：
[`apps/desktop/AGENTS.md`](../apps/desktop/AGENTS.md:1)（"judgment guide, not an inventory"）
+ [`apps/desktop/src/AGENTS.md`](../apps/desktop/src/AGENTS.md:1)（后端契约、palette、Bot Mode）
+ `DESIGN.md`（视觉与交互契约）+ `ENGINEERING.md`（长文推导）。

### 6.1 三方职责

[`apps/desktop/AGENTS.md:13`](../apps/desktop/AGENTS.md:13)：

> Desktop 是它自己的原生聊天界面。**它不是浏览器 dashboard，也不内嵌 TUI。**
> 三方，各自对一件事权威：

| 方 | 拥有什么 |
|---|---|
| **Electron 主进程** | **机器**：进程生命周期、原生文件系统/git/窗口、安装更新、**窄而类型化的能力桥** |
| **Renderer** | **体验**：导航、呈现、临时交互状态 |
| **Agent 后端** | **工作**：会话、工具、模型调用、流式 |

**保持缝干净**的具体含义：

- renderer **绝不**直接够 Node/Electron；
- 原生能力通过**刻意设计的能力**到达，**不是通用逃生舱**
  （不能给 renderer 一个 `exec(cmd)`）；
- agent 行为在 gateway 后面，**绝不在 React 里重实现**。

### 6.2 按权威决定状态归属

第一条问题永远是「**谁被允许对这块状态是正确的**」，而不是「存在哪里方便」。

| 状态 | 权威 | renderer 里的副本是什么 |
|---|---|---|
| 任何其它 Hermes 界面也能改的东西（会话、配置、profile） | **后端** | **缓存** |
| 机器与运行时事实（端口、进程 pid、后端版本、安装路径） | **Electron** | 镜像 |
| 纯属本窗口呈现的东西（滚动位置、折叠状态） | **Renderer** | 真实状态 |

推论（这四条决定了代码往哪个目录放）：

- 共享 renderer 状态住在 **feature 拥有的小 store**（nanostores atom），不是一个大 store；
- 请求形状、想要失效的服务器数据住在 **query 层**；
- 短命交互细节留在组件里；
- **不能触发重绘的热协调留在 `ref` 里**。

**持久化状态必须在自己的 key 里声明作用域**：

```text
全局？        所有 profile 共享
连接？        这个后端连接
profile？     这个 profile
存储会话？    这个已保存会话
项目？        这个项目
窗口？        这个窗口
```

作用域错了的具体后果：**一个 profile 的设置渗透到另一个**。
这类 bug 极难复现，因为要开两个 profile 才看得见。

它还给出了一组写入原则：

> 合并，不要覆盖；乐观地画、可见地回滚；过期的异步结果绝不覆盖更新的意图
> （generation 计数、request token）；只有前台面发布到共享视图；
> 合并表面更新，但立刻刷终端状态转换；no-op 保持引用相等。

最后那条 `no-op 保持引用相等` 是 React 性能的关键：
如果你每次返回新对象，`useSyncExternalStore` / `memo` 全部失效。

### 6.3 上下文切换是 re-home，不是 reboot

```text
连接/模式 apply  →  SOFT re-home
                    shell 保留，gateway-bound stores 显式清空，然后重连

运行时 HERMES_HOME 变化 → HARD re-home
                    整个 reload

活 profile 切换  →  合并列表，后台 profile 继续流式
```

**换过之后，active socket、profile、connection atoms 必须一致。**

这三个 atom 是三个独立的状态，分别更新。如果更新顺序错了或者漏了一个，
就会出现"UI 显示 profile A，但 socket 连着 profile B"——然后所有操作都写错地方。

"显式清空"这两个字很关键：不是"等新数据覆盖旧数据"，而是主动清。
因为**如果新连接失败，你不希望还显示旧 profile 的会话列表**。

### 6.4 跨一切都是 observable ladder

这是 Desktop 最抽象也最有用的一条：

> 每个缝（版本、profile、local/remote/cloud、更老的后端）**按策略解析成一条有序阶梯**：
> **优先级作为数据**，候选只在被探过后才可信，
> 一次失败的读取落到下一级，但**一次失败的权威写入必须显式失败或回滚**，
> 缺失能力**不是**暂时性故障，重试有界并以可恢复的出口结束。

拆成六条可执行规则：

| 规则 | 反例 |
|---|---|
| 优先级作为**数据**，不是 if 链 | 五层嵌套 `if (x) else if (y)` |
| 候选**先探后信** | 读到 `undefined` 就当空对象用 |
| 读失败 → 下一级；**写失败 → 报错或回滚** | 写失败静默忽略 |
| 缺失能力 ≠ 暂时故障 | "重试三次还是没有这个功能" |
| 重试有界，**结尾有恢复入口** | 无限重试 + 转圈 |
| 一次 **connection test 要测你实际会用的那条腿** | 测 `/health` 然后走 WS |

两个具体例子：

- **OAuth 网关连接每次拨号都铸新 ticket**（只有确认的 401/403 才算需要重新认证）。
  单次 ticket 重放会失败，所以"缓存 ticket"是错的。
- **`persist:` 分区名不包含任何 Electron 会变的东西**。分区名是持久化键，
  如果它包含版本号，升级一次所有 OAuth token 全丢。

### 6.5 guest 内容绝不自己打开东西

这是一个真实的 GHSA 记录（`GHSA-9f4c-93c8-jc8g`）：

```text
三层防御，缺一不可：

① setWindowOpenHandler      拒绝一切 window.open
② webview                    没有 allowpopups 属性
③ guest 的 target="_blank"
     只能通过 persist:hermes-preview guest preload 的"可信点击桥"
     到达 hermes:openExternal，且只允许 http: / https:
```

为什么需要三层？因为每一层都能被单独绕过：

- artifact iframe 里的链接可以调 `window.open` → 被 ① 拦；
- `<webview>` 有自己的一套 → 靠 ② 关掉 popup 能力；
- guest 进程里的 `<a target="_blank">` 不走 renderer 的 handler → 只能通过
  guest preload 里的**显式桥**，且白名单只放 `http:`/`https:`（挡 `file:`、`javascript:`）。

### 6.6 兼容性：不要在兼容性上携带过去

> Desktop 与其运行时**按不同时钟更新**，所以一次改动可能遇到更老的后端。

具体场景：用户三个月没更新 Hermes CLI，但 Desktop 自动更新了。
于是新 App + 旧后端。

规则（三条一起读）：

1. **保留当前 feature**（不要让新 App 丢掉能力）；
2. **把 fallback 收窄并绑到已识别的更老 runtime**；
3. **用测试覆盖它**。

然后是最重要的一句：

> **一个悄悄降级它本该保护的 feature 的 fallback，比它替代的崩溃更糟。**

因为崩溃用户会报 bug，静默降级用户会以为"这功能就这样"。

#### 唯一的 backward-compat 单点

[`apps/desktop/electron/backend-command.ts`](../apps/desktop/electron/backend-command.ts:1)：

```text
正常路径（永远）：
  hermes [--profile <slug>] serve --host 127.0.0.1 --port 0

只有在"解析出的 runtime 不认识 serve"时：
  改写为 hermes [--profile <slug>] dashboard --no-open
  → 产出完全相同的 headless gateway，serve 只是解耦后的名字
```

三个实现细节：

**① 检测 `serve` 时不能直接 `args.includes('serve')`**

```javascript
const VALUE_FLAGS = new Set(['-m', '--profile', '-p'])
// 这些 flag 吃掉下一个 token；子命令是第一个"不是这些值"的裸 token
```

因为 `--profile serve` 或 `-p serve` 会让 `includes('serve')` 误判。
`--profile=serve` 不会撞（那是不同字符串），但两个 token 的形式会。

**② profile 参数必须过 `backendProfileArg()`**

```javascript
// 非 slug 值（数字 roster id、显示名）绝不能跨进 spawn argv：
// CLI 曾经把它 str() 强制成一个幻影 profiles/0 目录（#88842）
```

`profiles/0` 这个 bug 很典型：一个数字 id 被当成 profile 名，创建了一个
名字是 `"0"` 的 profile 目录，然后所有配置都在那里，用户的真 profile 没变。

**③ 保留所有其它参数**

包括前导的 `-m hermes_cli.main` 和任何 `--profile <name>`。
也就是说这是**改写**（rewrite），不是**重建**（rebuild）。

### 6.7 后端管理：池化的 `serve --port 0`

[`apps/desktop/src/AGENTS.md`](../apps/desktop/src/AGENTS.md:6)：

> 每个 **(connection, profile)** 一个 `hermes serve --port 0` 后端，
> 设置 `HERMES_DESKTOP=1`。

四个设计点：

| 点 | 为什么 |
|---|---|
| **`--port 0`** | 让 OS 分配端口。写死端口会和用户自己的 `hermes serve` / 其它 App 实例冲突 |
| **每个 (connection, profile) 一个** | 一个后端进程服务多 profile 会踩 §2.9 那口井 |
| **远程连接单进程服务多 profile** | 远程模式下进程数不能随 profile 线性增长；靠 `?profile=` 参数路由 |
| **每个 REST 调用带 `?profile=`** | 同上：RPC 没有"我属于哪个 profile"的隐式上下文 |

#### scope 修复必须做双向探针

`AGENTS.md` 明确要求：**环境绑定的 launch home 作主，override 绑定的作 secondary**。
两边都要有测试。

原因：只测一边会漏掉一类路径。比如：

- `get_hermes_home()` 读的是 override → 只在 override 测试能覆盖；
- `get_secret()` 读的是 `os.environ` → 只在 env 测试能覆盖。

只测一边，另一边的泄漏在 CI 里不可见。

### 6.8 Slash palette 的策展

Desktop 有一份由 Python 生成的 registry 快照（`desktop-slash-registry.json`，
由 `scripts/dump_desktop_slash_registry.py` 产出），加上一份本地策展表。

三个判定函数（[`apps/desktop/src/lib/desktop-slash-commands.ts`](../apps/desktop/src/lib/desktop-slash-commands.ts:1)）：

| 函数 | 决定什么 | 语义 |
|---|---|---|
| `isDesktopSlashCommand(command, arg)` | **执行** | true 除非是"已知无桌面面"的命令 |
| `isDesktopSlashSuggestion(command)` | **发现**（popover/补全） | 别名默认隐藏（避免重复） |
| `isDesktopSlashExtensionCommand(command)` | **扩展命令** | 不是 Hermes 内置的 → 是 skill / quick command → **一律放行** |

## 为什么要三个而不是一个

因为"能不能执行"和"该不该出现在菜单里"是两件事：

- `/model` 可以执行，但 `hidden`（不出现在 popover，靠 `/model` 直接开选择器）；
- 别名可以执行，但不在 popover 里占一行；
- 用户自己装的 skill **必须**既能执行也能被发现——否则装了等于没装。

`isDesktopSlashExtensionCommand` 的实现只有一句核心判断：

```typescript
return !isKnownHermesSlashCommand(normalized)
```

`apps/desktop/src/AGENTS.md` 给这条加了硬规则：

> palette 策展**隐藏噪音**（terminal-only / messaging-only 内置命令），
> **绝不隐藏用户激活的扩展**。
> 如果你收紧 `desktop-slash-commands.ts`，保持 `isDesktopSlashExtensionCommand`
> 流入两条路径。

测试命令也写在那里：

```bash
cd apps/desktop
npx vitest run src/lib/desktop-slash-commands.test.ts
```

#### `TS_ONLY_NO_DESKTOP_SURFACE` 与冷启动缺口

`REGISTRY_DESKTOP_SURFACE` 来自那份 JSON 快照。但有一小撮命令 **Python registry 从来没听过**，
因为它们只在 Ink 进程里存在：

```typescript
export const TS_ONLY_NO_DESKTOP_SURFACE = {
  advanced:        [],
  'composer-voice': [],
  messaging:       [],
  settings:        ['/pets'],
  terminal:        ['/density', '/details', '/logs', '/mouse']
}
```

注释解释：`/density`、`/details`、`/logs`、`/mouse` 是 Ink 进程本地的显示开关
（其中三个通过 `server.py::_TUI_EXTRA` 被广告出去）；`/pets` 是 desktop 自己
`/pet` action 的复数拼写错误，指向 sidebar 而不是当作未知 skill 落下去。

`_TUI_EXTRA` 的实际内容（[`server.py:3554`](../tui_gateway/server.py:3554)）：

```python
_TUI_EXTRA: list[tuple[str, str, str]] = [
    ("/density", "Toggle compact display mode", "TUI"),
    ("/logs", "Show recent gateway log lines", "TUI"),
    ("/mouse", "Set mouse tracking preset [on|off|toggle|wheel|buttons|all]", "TUI"),
    ("/sessions", "Switch between live TUI sessions", "TUI"),
]
```

#### `registryDerivedSpecs()` 修的那个 bug

> 没有本地 spec 的 registry 行：有真实 unavailable 原因 → 阻断；
> **`null` 行是"被提供的"内置命令**（`/context`、`/usage`…）→ 变成普通 `exec` spec。
> 这样 desktop 离线也能认出每个 registry 命令——否则在第一次 `commands.catalog`
> 往返之前（或面对一个 `complete.slash` 行不带 `kind` 的更老 gateway），
> `/context` 会被读成 skill：Skills 分组、粘贴时带 skill chip、走扩展派发（#116159）。

这个 bug 的形态值得记：**冷启动时缺数据类型信息 → 分类降级 → 用户看到 `/context`
出现在 Skills 组里**。修法不是加特判，而是**给 registry 行一个默认的 "
offered built-in" 语义**。

#### 精确别名逃生门

`isDesktopSlashSuggestionWithOptions(command, { exactAlias })`：

> 用户**精确**打出的别名（`/reset`，不是浏览用的前缀）必须显示，
> 否则空的 "no matches" popover 读起来像"这个命令不存在"，而回车仍然会执行它（#57641）。

同时它被 `isDesktopSlashCommand` 门控——所以 canonical 没有桌面面的别名
（比如 `/reload_mcp`）**仍然隐藏**。

这是一个"UI 说没有，但行为有"的经典不一致，修法是让 UI 在**精确匹配**时让步。

### 6.9 Bot Mode：一个 bot = 一个永久会话

这是 Desktop 里唯一被明确写"**not open for re-litigation**"的不变量。

`apps/desktop/src/AGENTS.md` 的原文：

> 每个 bot 是一个有持久身份的 Hermes **profile**。这个不变量反复回归，
> 每次让用户丢掉对话历史，**不是例行 PR 可以重新讨论的**。

#### 身份定义

```text
身份 = (profile, session title 恰好等于 "Bot Chat")
```

**只有这两个**。state DB 的 `UNIQUE(title)` 索引让这一对成为一个"最多一行"的注册表。

#### 点击一个 bot 的完整流程

```text
1. 每次都解析注册表
   session.list { title: "Bot Chat", include_hidden: true }
     ├─ 索引化，不依赖窗口
     ├─ hidden 行也能解析（canonical chat 永远是 hidden）
     └─ compression lineage 解析到活的 tip
   行存在 → 打开它。这就是全部 happy path。

2. 没有行 → 创建它
   ├─ 标题 "Bot Chat"
   ├─ 出生即 hidden
   └─ 用 bot 的 intro 起头
   ├─ 创建时 "adopts-before-minting"：重跑一次查找，
   │  所以并发/已存在行会被打开，绝不 fork
   └─ 因为 set_session_title 会静默丢弃冲突标题（返回 0 行），
      这正是 2026-08 无限 fork 循环的起点
```

#### 为什么"没有 session-id pin"

> 旧设计在 `ui_meta['hermes-bots'].chat` 里存一个指针……

存 id 的问题是：**id 会变**。压缩会轮换 session key、resume 会重新铸造 UI session id。
一个 id 指针迟早指向不存在的行——然后代码"没找到就新建"，于是开始 fork。

改成"按名字解析"，就把身份变成了**幂等查询**。

五轮硬化的记录：`#88690` / `#90732` / `#90751` / `#91791` / `#92042`。
这么多次说明一个事：**这类"隐式身份"的 bug 不会一次修完**。

还有一条策略：**recency 绝不赢**。也就是说，"最近用过的那个 Bot Chat"不能作为
身份解析的依据——必须走 `(profile, title)` 精确查询。

`profiles.list` 返回 `canonical_session`，让前端不必自己算。

### 6.10 Nous free tier：状态是拉取的，绝不在 renderer 里 latch

> `free_tier.status` / `free_tier.ack_notice` 是**唯一**真相源：
> ready 屏和 own-key 条渲染同一个 `notice_pending` 状态，
> **没有 localStorage latch**，每个入口都打开那一个登录对话框。
> 按 `free_tier_row` / `free_tier` 分支，**绝不**按 provider 显示名。

三个"绝不"各有具体理由：

| 绝不 | 理由 |
|---|---|
| 不在 localStorage latch | 用户在另一台设备/另一个窗口里已经看过了，latch 会让这台永远不显示 |
| 不按 provider 显示名分支 | 显示名是 i18n 的、会被改的；`free_tier_row` 是稳定标识 |
| 只有一个登录对话框 | 多个入口 = 多个状态机 = 状态不一致 |

### 6.11 尊重注意力 + 性能

#### 注意力

> 绝不因为后台**发生了**什么而导航、移动焦点、打开界面。**提供，不要劫持。**

具体规则：

- 加载周边状态是**不同体验**：empty / loading / reconnecting / degraded-stale /
  exhausted-recovery **各需自己的诚实文案与出路**。
  用一个 "Loading..." 覆盖五种状态是不诚实的。
- 键盘所有权跟随焦点；**一个 cancel 手势只做一件事**
  （Esc 不能既关面板又打断 agent，用户会不知道发生了什么）。
- 昂贵、有状态的界面（终端、活工具）**隐藏时保持存活**。**可见性不是生命周期。**

最后一条是 Electron 特有的陷阱：如果你在 `display: none` 时销毁终端组件，
切回来会重建——所有 PTY 状态、滚动位置、进行中的工具输出全部丢失。

#### 性能

> 让我感觉瞬间。

工程手段（都在 `apps/desktop/AGENTS.md` 里）：

| 手段 | 用在哪 |
|---|---|
| 乐观绘制 + 可见回滚 | 发消息、切会话 |
| generation counter / request token | 过期响应不得覆盖新意图 |
| 只有前台面发布进共享视图 | 避免后台 tab 抢渲染 |
| 合并表面更新，**立刻刷终端状态转换** | 流式 token 合并；`running → done` 不合并 |
| no-op 保持引用相等 | 避免无谓重渲染 |

### 6.12 taste test

交活之前自问七条（原文在 `apps/desktop/AGENTS.md:152`）：

1. 每块状态是否住在它的权威处、作用域是否最窄？
2. 一个后台事件会不会偷走前台或用户焦点？
3. 每个 resolver 是否有一个家、一条被验证的阶梯、一个有界可恢复的结尾？
4. local / remote / profile 三种路由是否仍然一致？
5. 异步失败后是否留下一个可用的 UI 和一条前进的路？
6. 热交互在真实负载下是否仍然便宜？
7. 改动是否通过 `DESIGN.md` 清单并且**更新了所有 locale**？

第 7 条特别容易被忘：**Desktop 的文案有多个语言包**，
只改英文会导致其它语言出现英文混排。

---

## §7 Web 面（dashboard）

### 7.1 四层结构

```text
浏览器
 └─ React SPA（web/src，20 个页面）
      └─ /chat 页：xterm.js Terminal（WebGL 渲染器）
           │ onData   → 按键 → WebSocket
           │ onResize → \x1b[RESIZE:cols;rows
           │ write()  ← PTY 输出字节 → VT100 解析
           ▼
      WebSocket /api/pty?token=<session>
           ▼
 FastAPI 的 pty_ws（hermes_cli/web_routers/chat_ws.py）
           ▼
 POSIX PTY → node ui-tui/dist/entry.js → tui_gateway + AIAgent
```

`web/src/pages/ChatPage.tsx` 的文件头注释就是这张图（用 ASCII 画的）。
它挂载的 xterm addon 有四个：

| addon | 作用 |
|---|---|
| `@xterm/addon-webgl` | WebGL 渲染器（字符量大时性能关键） |
| `@xterm/addon-fit` | 容器驱动 resize |
| `@xterm/addon-unicode11` | 宽字符宽度（CJK、emoji） |
| `@xterm/addon-web-links` | 点击链接 |

没有 `unicode11` 的话，中文和 emoji 的列宽算错，整个 TUI 布局会错位。

### 7.2 PTY 细节：四个必须知道的点

#### ① `PTY_HOST_ENV` 让 Ink 知道宿主是谁

[`hermes_cli/pty_bridge.py`](../hermes_cli/pty_bridge.py:28)：

```python
PTY_HOST_ENV = "HERMES_PTY_HOST"
PTY_HOST_DASHBOARD = "dashboard"
```

注释：

> 告诉子 TUI 它是被 dashboard 的 xterm.js 托管的。Ink 用这个来跳过它为"原生模拟器"
> 做的 focus-in 时 erase+repaint——原生终端会合并隐藏 tab 的输出，
> 而 **xterm.js 从不丢帧**，所以在 dashboard 下那次重绘是**每次 OS 切应用时的可见闪烁**。

这是一个"同一个 TUI，在不同宿主下需要不同渲染策略"的例子。注意它是**环境变量**，
不是命令行参数——因为它描述的是"环境事实"，不是"用户意图"。

#### ② 原生 Windows 不支持，报错要说清楚

```python
if not _PTY_BRIDGE_AVAILABLE:
    await ws.send_text(
        "\r\n\x1b[31mChat unavailable: the embedded terminal requires a "
        "POSIX PTY, which native Windows Python doesn't provide.\x1b[0m\r\n"
        "\x1b[33mInstall Hermes inside WSL2 to use the dashboard's /chat "
        "tab — the rest of the dashboard works here.\x1b[0m\r\n")
    await ws.close(code=1011)
```

三段信息缺一不可：**什么坏了**（POSIX PTY）、**为什么**（native Windows Python 不提供）、
**怎么办**（装进 WSL2）、**以及什么还能用**（dashboard 其它部分）。

`pty_bridge.py` 的模块 docstring 也写了：native Windows 需要单独的
ConPTY/`pywinpty` 实现，本项目没有做。

#### ③ resize 走带内信号

帧是**原始 PTY 字节**。那 resize 怎么传？不能占一个"帧类型"，因为 PTY 字节流是连续的。

解法（[`hermes_cli/web_server_chat.py:43`](../hermes_cli/web_server_chat.py:43)）：

```python
_RESIZE_RE = re.compile(rb"\x1b\[RESIZE:(\d+);(\d+)\]")
```

客户端发 `\x1b[RESIZE:120;40]`，服务端**拦截**这一段（不写进 PTY），
改用 `TIOCSWINSZ` ioctl 应用到子进程（[`pty_bridge.py:254`](../hermes_cli/pty_bridge.py:254)）。

为什么用 CSI 序列而不是自定义帧？因为 PTY 通道必须是**单一字节流**——
多路复用会引入帧边界，而 xterm 的 `onData` 天然是字节。

#### ④ keep-alive PTY 会话

[`hermes_cli/pty_session.py`](../hermes_cli/pty_session.py:1) 解决的问题：

> 一个 PTY 进程**比创建它的 WebSocket 活得久**：单个 drain task 总是把 PTY 读进一个
> **有界 RingBuffer**，有 socket 连着时转发给它。用同一个不透明 token 重连
> 会重放缓冲并恢复实时。

机制：

```text
PtySession
 ├─ RingBuffer(capacity)      # 只保留最近 N 字节；truncated 标志
 ├─ drain task                # 永远在读 PTY
 └─ attached socket（可空）
```

三个关闭码/信号：

| 常量 | 值 | 含义 |
|---|---|---|
| `WS_CLOSE_SUPERSEDED` | **4409** | 另一个连接接管了这个 PTY |
| `WS_CLOSE_PROCESS_EXITED` | **4410** | PTY 子进程退出了 |
| `TUI_FORCE_REDRAW` | `b"\x0c"` | Ctrl-L：重连后让 TUI 重画 |

**为什么需要 `TUI_FORCE_REDRAW`**：重放 RingBuffer 出来的是"从中间开始"的
ANSI 流。TUI 并不知道自己刚被重放，它的屏幕状态和 `RingBuffer` 的起点不匹配。
发一个 `\x0c`（Ctrl-L）触发完整重绘，就把两边对齐了。

`RingBuffer` 的 `truncated` 标志同理——如果缓冲区已经覆盖了旧内容，
客户端知道"你看到的不是全部"。

### 7.3 认证：为什么 token 在 query param 里

[`hermes_cli/web_server.py:387`](../hermes_cli/web_server.py:387)：

```python
_SESSION_HEADER_NAME = "X-Hermes-Session-Token"
_SESSION_TOKEN = _resolve_session_token()   # :386
```

`_resolve_session_token()`：

```python
return os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN") or secrets.token_urlsafe(32)
```

来自环境变量（供 Dashboard 的 SSH bootstrap 用）或每次启动新生成（`:380` 附近的注释：
"它随服务器生命周期结束"）。

#### 三个认证入口

```python
def _has_valid_session_token(request) -> bool:
    session_header = request.headers.get(_SESSION_HEADER_NAME, "")
    if session_header and hmac.compare_digest(session_header.encode(), _SESSION_TOKEN.encode()):
        return True
    auth = request.headers.get("authorization", "")
    return hmac.compare_digest(auth.encode(), f"Bearer {_SESSION_TOKEN}".encode())
```

**专用 header 而非只用 `Authorization` 的理由**（注释原文）：

> 专用 header 避免和已经使用 `Authorization` 的反向代理冲突（Caddy `basic_auth`）；
> 老的 Bearer 路径保留给更早的 dashboard bundle。

#### query param 只允许一个路径

```python
_QUERY_TOKEN_API_PATHS = frozenset({"/api/files/download"})
```

注释：

> 也可以通过 `?token=` 认证的路由（OS shell 或新标签页打开的下载链接，
> 无法设置 header）。**保持很窄。**

那 `/api/pty?token=` 怎么解释？它是 **WebSocket**，不走这个 REST 检查——
`web/AGENTS.md` 说得很直接：

> 认证用与 REST 相同的临时 `_SESSION_TOKEN`，**作为 query param 传**，
> 因为**浏览器无法在 WS upgrade 上设 `Authorization`**。

这是一个协议限制，不是设计选择。浏览器的 `new WebSocket(url)` 不接受 header 参数。

#### gated 模式与 loopback 模式的差别

```python
def _require_token(request):
    if getattr(request.app.state, "auth_required", False):
        ok = request.state.session is not None       # gated：已验证的 cookie 会话
    else:
        ok = _has_valid_session_token(request)       # loopback：SPA 注入的 token
    if not ok:
        raise HTTPException(401)
```

注释解释了为什么 gated 模式下**不能**要求 token：

> gated 模式下 token **不被注入**（用 cookie 认证），而 `gated_auth_middleware`
> 已经把没有验证 `request.state.session` 的一切 401 掉了——这里再要求那个不存在的 token
> 会让每个 `_require_token` 端点**在门后不可达**。

这是一个"双重认证互相否决"的经典陷阱。

#### 公开路径的单一来源

```python
from hermes_cli.dashboard_auth.public_paths import PUBLIC_API_PATHS as _PUBLIC_API_PATHS
```

> 不需要 session token 的端点；`/api/` 下其它一切都在下面被门控。
> **与 OAuth 门共享**，这样两个 allowlist 不会漂移
> （`/api/status` 曾经在 OAuth 门下 401，破坏了 portal 探针）。

"两个 allowlist 会漂移"是这个 bug 的本质：认证有两层（session token 和 OAuth），
各有自己的白名单。修法是**合并成一个常量**。

### 7.4 `dashboard` vs `serve`

```text
共享：cmd_dashboard / start_server
独立：谁都不启动谁

dashboard：
  ├─ _resolve_dashboard_web_dist(args, headless_backend=False)
  │    ├─ 没设 HERMES_WEB_DIST 且没 --skip-build → _build_web_ui()
  │    └─ --skip-build → 验证 index.html 存在（否则启动后全是 404，见 #23817）
  └─ mount_spa(app)  → 挂 SPA

serve：
  ├─ _resolve_dashboard_web_dist(args, headless_backend=True)
  │    └─ os.environ["HERMES_SERVE_HEADLESS"] = "1"   ← 必须在 import web_server 之前
  └─ mount_spa(app)  → 走 headless 分支
```

`HERMES_SERVE_HEADLESS=1` 时 `mount_spa()` 的行为
（[`hermes_cli/web_server_dashboard.py:103`](../hermes_cli/web_server_dashboard.py:103)）：

```python
if os.environ.get("HERMES_SERVE_HEADLESS") == "1":
    @application.get("/{full_path:path}")
    async def no_frontend(full_path: str):
        gated = bool(getattr(application.state, "auth_required", False))
        if full_path == "" and not gated:
            # 只返回一个带 token 的空白页！
            return HTMLResponse(
                "<!doctype html><html><head><script>"
                f"window.__HERMES_SESSION_TOKEN__={json.dumps(_server()._SESSION_TOKEN)};"
                "window.__HERMES_AUTH_REQUIRED__=false;"
                f"</script></head><body>{_HEADLESS_MSG}</body></html>")
        return JSONResponse({"error": _HEADLESS_MSG}, status_code=404)
    return
```

那个"根路径返回带 token 的空白页"不是漏洞，是修 bug 的补丁（`#94227`、`#95575`）：

> Desktop 的 token 握手：Electron shell 启动时 fetch `/` 并读
> `window.__HERMES_SESSION_TOKEN__` 来给 `/api/ws` 认证。
> 当 headless 对每个路径都 404 时，一个 spawn token 不再匹配的 renderer
> （比如 `hermes update` 之后）会**白屏**。
> 在精确的根路径上服务一个只有 token 的页面，**但仅当 auth gate 关闭时**：
> gated serve 上 token 绝不能在未认证时可读。

注意那个 `full_path == ""` 和 `not gated` 两个条件都必需。少任何一个都是漏洞。

### 7.5 什么可以做成结构化 React

`web/AGENTS.md` 的界线：

> **结构化 React UI 围绕 TUI 是可以的，当它不构成第二个聊天面时。**
> Sidebar widget、inspector、摘要、状态面板（`ChatSidebar`、`ModelPickerDialog`、
> `ToolCall`）补充内嵌 TUI。
> **保持它们的状态独立于 PTY 子进程的会话**，并**非破坏性地**呈现失败，
> 让终端窗格继续工作。

"非破坏性"的具体含义：sidebar 的 API 调用失败了，显示一个错误条，
**不能**把整个页面替换成错误页——因为终端窗格还在跑一个长任务。

反过来，那句被加粗的禁令：

> **不要在 React 里重实现主聊天体验。** transcript、composer/输入流
> （包括 slash 命令行为）、PTY 支持的终端属于内嵌 TUI；
> **加到 Ink 的东西会自动出现在这里**。
> 如果你在给 dashboard 重建 transcript 或 composer——停下，去扩展 Ink。

"加到 Ink 的东西会自动出现在这里"是这句话的核心论据。
如果你重写一遍，你就要维护两份 transcript 渲染、两份 slash 行为、两份滚动逻辑。

### 7.6 Routers：一文件一面

```text
hermes_cli/web_routers/（27 个文件）
├── __init__.py
├── _common.py                     # 共用 helper
├── actions.py                     analytics.py
├── audio.py                       chat_workspaces.py
├── chat_ws.py                     chat_ws_errors.py
├── config_env.py                  cron.py
├── dashboard_ui.py                display.py
├── files.py                       git.py
├── local_models.py                mcp.py
├── memory_providers.py            messaging.py
├── models.py                      oauth.py
├── ops.py                         profiles.py
├── sessions.py                    shared_metrics.py
├── skills.py                      status.py
└── tools.py
```

规则（`web/AGENTS.md`）：

> **Routers 一文件一面**；一个新面是新的 `web_routers/<surface>.py`，
> 不是长大的 `web_server.py`。

`web_server.py` 还有 1,711 行，其中一部分是**必须留在这里的**：
`_SESSION_TOKEN`、`_require_token`、`_has_valid_session_token`、
`mount_spa` 的调用、`_DASHBOARD_EMBEDDED_CHAT_ENABLED` 这类"单例状态"。

`chat_ws.py` 开头有一段值得学的模式：

```python
# 测试 monkeypatch 在 web_server 上的 helper/state 留在那里，
# 通过 late-binding 缝到达（cycle-safe）。
_active_session_file_for_channel = late("_active_session_file_for_channel", "hermes_cli.web_server_chat")
_profile_scope = late("_profile_scope", "hermes_cli.web_server_profiles")
_resolve_chat_argv_async = late("_resolve_chat_argv_async", "hermes_cli.web_server_chat")
```

`late(...)` 让"测试在 facade 上打的 patch"在**调用时**生效。这是"拆分模块但不破坏
monkeypatch 缝"的标准做法（跟 `hermes_cli/AGENTS.md` 里说的 late-bind 是同一招）。

#### `/api/pty` 的路由体量

`pty_ws` 这一个 handler 覆盖了十几种情况。从代码里能数出来：

| 情况 | 处理 |
|---|---|
| `_ws_gate()` 失败 | 直接返回（认证/来源检查） |
| POSIX PTY 不可用 | 发红色说明 + close 1011 |
| `?resume=` 但被规范化成别的 | `send_json({"type":"resume","id":...})` 告诉客户端滚动到底（#93518） |
| `?cwd=` 是死路径/相对路径 | **fail closed**，绝不用 launch dir |
| 未知/非法 profile | 清理 active-session marker 再报错 |
| Node/npm 缺失（`_make_tui_argv` 里 `sys.exit(1)`） | 同上清理 + 报错 |
| PM 无法提供 node（`InstallError`） | 报错（remedy 文案自带修复方法） |
| `?attach=` token | 走 keep-alive session 路径（RingBuffer + 重放） |
| 无 attach | 传统 1:1 socket↔PTY，断开即杀 |

「死路径 fail closed」那条注释：

```python
# 一个选中的 workspace 只适用于 FRESH chat；resumed session 保留自己的 cwd
```
```python
except HTTPException:  # dead/relative path: fail closed, never the launch dir
```

"never the launch dir" 很重要：如果路径无效就回退到启动目录，用户会在一个
不相关的工作区里执行工具——比报错危险得多。

---

## §8 i18n 在各界面的分布

三个事实：

### ① `.tui.yaml` / `.desktop.yaml` 对核心是不透明的

核心只做 **parse / flatten / serve**，不理解 key 的语义。
好处：TUI / Desktop 可以自由加文案，不需要改 Python。

### ② TUI 在 TypeScript 里只发英文

```text
locales/<lang>.tui.yaml          ← bundled 语言包（打包进发行版）
        │
        └─ surface_catalog 服务的内容
             └─ 但 TUI 运行时只发英文 key
```

也就是说：**TUI 的代码里写的是英文文案 key，翻译由语言包提供**。
所以 `ui-tui/src/i18n/en/` 下面那一堆文件是"英文原文"，不是"英文翻译"。

### ③ bundled id 的本地语言名有两份，必须一致

- [`agent/i18n_languages.py`](../agent/i18n_languages.py:1)
- [`apps/shared/src/i18n.ts`](../apps/shared/src/i18n.ts:1)

Python 端和后端共用一份；TS 端和两个前端共用一份。改一边忘了另一边，
语言选择器里就会出现"日本語"和 "Japanese" 混排。

这也是 §6.12 taste test 第 7 条（"更新所有 locale"）的来源。

---

## §9 跨界面的共同不变量

把四篇的内容压缩成能被引用的规则。

### 9.1 能力标志 vs 特判

判断"这个平台/界面支持 X 吗"时，**看能力标志，不看身份**。

反面例子（§5.3 提到的）：`draft_stream_is_message` 硬编码 Slack 判断。
正面例子：`BasePlatformAdapter` 上的六个能力标志、`adapter_supports_push()`。

同理在界面层：判断"能不能流式"看 `stream_is_message_for_chat()`，
不看"这是不是 Telegram"。

### 9.2 一幅真源

| 东西 | 唯一真源 | 消费者 |
|---|---|---|
| slash 命令定义 | `hermes_cli/commands.py::COMMAND_REGISTRY` | CLI、网关、TUI、Desktop、help 文案 |
| wire 契约 | `tui_gateway/contracts/*.py` | 运行时校验、TS 生成、OpenRPC |
| skin | `hermes_cli/skin_engine.py::SkinConfig` | CLI、TUI、dashboard |
| 公开 API 路径 | `dashboard_auth/public_paths.py::PUBLIC_API_PATHS` | session token 门、OAuth 门 |
| desktop palette 的权威列 | Python registry（TS 侧是快照） | `desktop-slash-registry.json` |

**每一行都对应一个"曾经漂移过"的事故。**

### 9.3 禁止 change-detector 测试

不要写"断言源码里有某个字符串/某个导出存在"的测试。理由：

- 它在重构时误报（文件拆了，字符串还在，但测试找不到）；
- 它在真 bug 时不报（字符串在，但逻辑把值传错了）；
- 它在 JS-only PR 上不运行（Python 测试断言 TS 源码）。

正确的替代：测**行为契约**。想验证"slash 命令能被派发"，就真的调一次 `process_command()`。

### 9.4 Python 测试与 TS 测试的边界

| 断言对象 | 测试放哪 |
|---|---|
| Python 行为（路由、PTY bridge、dispatch） | `tests/hermes_cli/`、`tests/tui_gateway/` |
| TS/JS 行为（palette 三函数、slash handler、React） | `web/` 或 `ui-tui/` 或 `apps/desktop/` 的 vitest |
| 跨语言契约 | 生成器 + 过期测试（`tests/tui_gateway/contracts/test_generated.py`） |

### 9.5 三处不能"顺手加个特判"的地方

1. **`tui_gateway` 的事件/方法**：三个消费者。加字段要过契约。
2. **`mount_spa` 的 headless 分支**：少一个 `not gated` 就是 token 泄漏。
3. **`_wants_tui_early` 的 TTY 闸**：去掉它，cron / kanban worker / `chat -q` 会静默成功空转。

---

## §10 自检题

### A. 全局与进程模型

1. 四个界面分别用什么传输？各是几进程？
2. 哪一面内嵌了 TUI，哪一面没有？为什么？
3. "`tui_gateway` 有三个消费者"具体是哪三个？改一个事件字段会影响谁？
4. `hermes serve` 和 `hermes dashboard` 共享什么？谁启动谁？
5. 为什么 dashboard 的 `/chat` 是"四层进程嵌套"？列出这四层。

### B. 约束推导

6. 为什么 `/api/pty?token=` 把 token 放在 query string，而不是 header？
7. 为什么 dashboard 需要 `@xterm/addon-unicode11`？不加会怎样？
8. 为什么原生 Windows 的 `/chat` 不可用？报错文案为什么要有四段信息？
9. `PTY_HOST_ENV=dashboard` 让 Ink 跳过了什么？为什么在 xterm.js 下那是个闪烁而不是必要重绘？

### C. `tui_gateway` 内部

10. `method_ctx.rebind()` 用 `types.FunctionType` 做了什么？它避免了什么问题？
11. 为什么 `HandlerRegistry.profile_scoped()` 只打标记，真正装饰在 `install()` 里？
12. 三种帧分别是什么方向？哪些是"后端反问用户"？举四个例子。
13. `srq-<12 hex>` 的两个设计理由是什么？
14. 一次 `send()` 等待期间，agent 线程处于什么状态？
15. 重连时"还没被回答的问题"是怎么恢复的？为什么不靠事件重放？
16. batch clarify 的 lock 语义是什么？为什么"已 lock 的答案能扛住超时"重要？
17. `NOT_SHOWN_CODE = 4404` 时，一次 decline 会不会结算请求？什么时候才结算？
18. 为什么 `send()` 对没声明 `server_requests` 能力的客户端**连帧都不写**？对比"照发等超时"的代价。
19. `_REPLAY_EPOCH` 解决的是什么具体故障？
20. 重放环的四个内存上界分别是什么？为什么要冻结成 bytes？
21. 什么是 truncation watermark？客户端拿到它应该做什么？
22. sidecar publisher 的三条"降级不阻塞主流程"措施是什么？
23. `@_profile_scoped` 绑的是哪三件东西？只绑第一件的状态叫什么？
24. 没有 `profile` 参数但有 `session_id` 时，作用域从哪来？这修的是哪个 bug？
25. 单 profile 进程为什么**不加**作用域？多 profile 激活后为什么必须从冻结快照读？
26. 哪些离线路径也需要绑作用域？举四个。

### D. wire 契约

27. 为什么 wire 由 Python 声明、TS 生成，而不是反过来或手写两份？
28. `extra="forbid"` 的效果是什么？什么时候用 `OpenModel`？
29. 三道校验闸分别是什么时机、什么行为？
30. 为什么出参闸在生产只记日志、测试里抛异常？
31. 生成器"刻意做小"的好处是什么？不支持的模型应该在哪修？
32. 把一个字段改名，五个消费者分别在哪一步被告知？

### E. CLI

33. `HermesCLI` 有几个 mixin？最大的三个分别管什么？
34. `_SLASH_DISPATCH` 的值是什么形状？两个字段各自什么含义？
35. 新增一个 slash 命令的两条路分别是什么？为什么"绝不要加 elif 阶梯"？
36. 未注册 slash 的五层优先级顺序是什么？为什么用户自定义排第一？
37. Skill slash 命令注入的是 user message 还是 system prompt？为什么？
38. 为什么 spinner 里不能输出 `\033[K`？正确的替代写法是什么？
39. 三个 config loader 分别谁在用？用错会有什么症状？
40. 为什么绝不对 config 路径调 `yaml.dump`？CI 用什么拦？
41. `atomic_config_write` 和 `atomic_config_replace` 的区别是什么？
42. `SkinConfig` 为什么必须是纯数据？它同时影响哪三处？
43. `_wants_tui_early` 的四级优先级？TTY 闸为什么是"承重"的？
44. 包装型 CLI 为什么不能 override `run()`？应该用什么？

### F. TUI

45. `ui-tui` 的技术栈是什么？"TypeScript 拥有屏幕，Python 拥有 agent"的含义？
46. `_make_tui_argv` 的四级查找顺序？为什么预构建检查在 workspace 准备之前？
47. `resetTerminalModes()` 修的是什么用户可见问题？
48. slash 命令的四段流分别由谁拥有？各举一个命令。
49. 为什么 widget app 要在"静态表之后"单独查一次活注册表？
50. 分层评分里"只有最佳层存活"是什么意思？用 `/hea` 和 `/beat` 说明。
51. `shouldFallbackToDispatch` 为什么只认两种 4018 文案？放宽会有什么后果？
52. 为什么 helper 超时（5030）必须原样显示，不能 fallback？
53. `reportSlashCommand` 为什么在客户端计数？`typed=false` 的三种情况是什么？
54. `_PENDING_INPUT_COMMANDS` 里的命令为什么不能在 slash worker 里跑？
55. 本地会话的 `/context` 为什么必须在进程内回答？`tools`/`help` 为什么不改？
56. `subagent.list` 的花名册为什么"跟随对话"而不是"跟随 session id"？
57. 子进程权限为什么不靠 registry 记账，而是在 RPC 时解析活 transport slot？
58. 为什么"不能写断言 TS 源码的 Python 测试"？

### G. Desktop

59. 三方职责分别是什么？"保持缝干净"的三条具体含义？
60. 判断状态归属的第一条问题是什么？举三类状态各自的权威。
61. 持久化状态不声明作用域的后果是什么？
62. SOFT re-home 和 HARD re-home 分别对应什么变化？换过之后哪三个 atom 必须一致？
63. "显式清空 gateway-bound stores"为什么比"等新数据覆盖"好？
64. observable ladder 的六条规则？"失败的写"和"失败的读"处理为什么不同？
65. 为什么 OAuth 网关连接每次拨号都要铸新 ticket？
66. guest 内容的三层防御分别拦什么？
67. 为什么"悄悄降级 feature 的 fallback 比崩溃更糟"？
68. `serve` → `dashboard --no-open` 回退的三个实现细节？为什么不能 `args.includes('serve')`？
69. `backendProfileArg()` 修的是哪个 bug（`profiles/0`）？
70. 为什么每个 (connection, profile) 一个 `serve --port 0`？远程模式为什么不同？
71. scope 修复为什么必须双向探针？
72. 三个 palette 判定函数分别决定什么？为什么不能合并成一个？
73. `TS_ONLY_NO_DESKTOP_SURFACE` 为什么需要存在？`/pets` 为什么在里面？
74. `registryDerivedSpecs()` 修的那个 bug（#116159）的完整链路是什么？
75. 精确别名逃生门（#57641）解决的是什么 UI 与行为不一致？
76. Bot Mode 的身份是什么？为什么"没有 session-id pin"？
77. "adopts-before-minting"在防什么？`set_session_title` 返回 0 行意味着什么？
78. free tier 的三个"绝不"分别防什么？
79. "可见性不是生命周期"针对的是什么具体实现错误？
80. taste test 第 7 条（更新所有 locale）为什么特别容易漏？

### H. Web

81. `/chat` 的四层结构？每层之间是什么传输？
82. `_SESSION_HEADER_NAME` 为什么不用只用 `Authorization`？
83. `_QUERY_TOKEN_API_PATHS` 为什么只有一项？
84. gated 模式下为什么 `_require_token` 不能要求 session token？
85. `PUBLIC_API_PATHS` 为什么要两层认证共享？
86. `HERMES_SERVE_HEADLESS=1` 时，根路径返回什么？两个必要条件是什么？
87. keep-alive PTY 的 `RingBuffer` + `TUI_FORCE_REDRAW` 是怎么配合的？
88. `WS_CLOSE_SUPERSEDED=4409` 和 `WS_CLOSE_PROCESS_EXITED=4410` 分别什么场景？
89. `?cwd=` 是死路径时为什么必须 fail closed？
90. 什么可以做成结构化 React，什么不行？判据是什么？
91. `late(...)` 这个 late-binding 缝是为了保住什么？

### I. i18n 与测试边界

92. 核心对 `.tui.yaml` / `.desktop.yaml` 了解多少？
93. "TUI 在 TS 里只发英文"是什么意思？
94. bundled 语言名为什么有两份？不同步会怎样？
95. 能力标志与特判的区别？各举一个例子。
96. 为什么 change-detector 测试"在重构时误报、在真 bug 时不报"？
97. Python 断言 TS 源码的测试在哪种 PR 上不运行？应该放哪？

---

## §11 小结与下一步

### 六条核心结论

1. **四个界面是被物理约束逼出来的，不是审美选择。**
   终端没有像素 → 字符网格；浏览器没有进程 → PTY 转发；WS upgrade 没有 header → token 进 query。

2. **`tui_gateway` 是三个界面的公共后端，所以它的 wire 必须有契约。**
   Python 声明 → TS 生成 → 编译期发现漂移。这是一个"故意不被绕过的约束"。

3. **CLI 的 slash 派发是"查表 + 命名约定"，不是 elif 阶梯。**
   未注册命令有五层优先级（quick → plugin → bundle → skill → prefix），
   因为用户自定义必须赢过内置。

4. **TUI 的 slash 有四个所有权段。**
   本地显示 → widget 注册表 → catalog 别名展开 → 后端。回退只认两种 4018 文案，
   因为放宽会让变异命令跑两遍。

5. **Desktop 的核心是"按权威放状态"+"re-home 而非 reboot"+"提供而非劫持"。**
   它的 `serve --port 0` 池化后端和 `?profile=` 路由，是 §2.9 那口 profile 作用域井的
   直接后果。

6. **dashboard 内嵌的是真 TUI。**
   transcript、composer、slash 行为都归 Ink；React 只做"围绕终端的结构化补充"。
   在 dashboard 里重写聊天是被明确禁止的。

### 一句话给别人讲明白

> Hermes 有四个界面，但它们不是四个产品：CLI 是进程内的经典 REPL，TUI 是 Node/Ink
> 前端加一个 Python JSON-RPC 后端，Desktop 是 Electron 自己的聊天界面复用同一个后端，
> dashboard 则是把这个 TUI 塞进伪终端再推进浏览器。后端的 wire 用 Python 写一次、
> 生成给 TypeScript，所以三个前端不会各说各话。

### 下一步

- [`11-plugins-skills-mcp.md`](11-plugins-skills-mcp.md)：三大扩展体系。
  本轮的 `_TUI_EXTRA`、skill slash 命令、`commands.catalog` 里的 skill 派生项都会在那里闭合。
- [`12-cron-and-kanban.md`](12-cron-and-kanban.md)：定时任务与看板。
  本篇的"TTY 闸对 cron 承重"会在那里再出现一次。
- [`13-subagents-delegation.md`](13-subagents-delegation.md)：子代理与委托。
  §5.6 的 `subagent.list` / lineage / transport slot 在那里展开。
- [`14-profiles-and-multiplex.md`](14-profiles-and-multiplex.md)：profile 与多路复用。
  §2.9 这口井的完整版本。
- [`15-invariants-and-conventions.md`](15-invariants-and-conventions.md)：全部不变量汇总。
