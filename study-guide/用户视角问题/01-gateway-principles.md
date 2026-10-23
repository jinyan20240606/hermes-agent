# 02 · 网关原理：推推机器人是怎么连上 Hermes 的，多用户上下文怎么隔离

> 记录时间：2026-10-23。背景：已在本机跑通 tuitui-platform 插件（推推机器人"测试"，AppID 683797575），
> 完成私聊问答验证。本文回答两个问题：
> ① 出站长连接是什么，为什么笔记本上不用任何网络配置就能跑；
> ② 网关怎么隔离不同用户的上下文，和直接在终端里用 CLI 有什么区别。
>
> **读完这篇你能**：画出"一条推推消息从手机到回复"的完整链路；说出 session key 的组成；
> 解释为什么两个人同时给机器人发消息不会串台。

---

## 一、先回顾：这台机器上网关是怎么搭起来的

装好的东西分三层，各司其职：

| 层 | 是什么 | 在哪 |
|---|---|---|
| 机器人本体（推推侧） | 在推推里私聊「推推机器人助手」发 `/创建` 创建，拿到 **AppID + Secret** | 存在推推服务器上 |
| 网关插件（Hermes 侧） | `tuitui-platform`，一个 platform 类型的插件 | `~/.hermes/plugins/tuitui-platform/` |
| 凭据配置 | `.env` 里的 `TUITUI_APPID` / `TUITUI_SECRET` | `~/.hermes/.env`（只进 .env，不进代码和日志） |

插件装好后 gateway 启动时做的事（对应日志 `~/.hermes/logs/gateway.log`）：

```
Connecting to tuitui...                        ← gateway 开始装配各平台适配器
Tuitui: receive loop started (appid=68***75)   ← 插件的 receive loop 起来了（appid 已脱敏）
✓ tuitui connected                             ← gateway 认为这个平台就绪
Tuitui: WebSocket connected                    ← WebSocket 握手完成
Gateway running with 1 platform(s)             ← 整个网关就绪，1 个平台在线
```

**插件是怎么被"发现"的**：`adapter.py` 最后有一个 `register(ctx)` 函数，调用
`ctx.register_platform(name="tuitui", adapter_factory=..., required_env=["TUITUI_APPID","TUITUI_SECRET"], ...)`。
gateway 启动时扫描插件目录 → 每个插件的 `register()` 把自己注册进平台注册表 → gateway 逐个检查
"这个平台的凭据齐不齐" → 齐的就 `connect()`。这就是**插件化微内核**的接入方式：推推的收发逻辑
全部住在插件里，Hermes 核心一行代码都不用改。

---

## 二、问题①：出站长连接，为什么不用公网 IP、不用开端口

### 2.1 先分清两种网络角色

| 角色 | 谁连谁 | 前提 | 例子 |
|---|---|---|---|
| **入站（监听）** | 别人连**到**你 | 你必须有公网可达的 IP + 开放端口，或做内网穿透 | 自己架网站、Telegram webhook 模式 |
| **出站（拨出）** | 你连**到**别人 | 只要你能上外网，NAT 后面也行 | 浏览器上网、微信收消息 |

笔记本在路由器 NAT 后面，没有公网 IP，外部主动连不进来——所以"监听端口等人来"的模式
在笔记本上根本不可行。推推插件选的是另一种：**长连接（WebSocket）由我们主动拨出去**。

### 2.2 收消息：一条拨出去的 WebSocket

`connect()` 的核心就是起一个后台任务 `_receive_loop`（adapter.py:848 附近），它做的事：

```python
async with websockets.connect(
    "wss://alarm.im.qihoo.net/callback/ws?auth=<appid>.<secret>",
    ping_interval=30, ...
) as ws:
    async for raw in ws:          # 挂在这里等服务器推消息
        await self._handle_frame(ws, raw)
```

关键点逐个拆：

- **认证在 URL 里**：`?auth=appid.secret`，连接建立那一刻就完成了身份验证。Secret 不经手第三方。
- **"长连接"**：这个 TCP 连接建好后一直挂着。推推服务器有新消息时，顺着这条**已经建立的连接**
  把消息推过来。不是轮询（每秒问一次"有我的消息吗"），也不是 webhook（推推来连你）。
- **为什么这不需要公网 IP**：TCP 连接是双向的。你拨出去的那条管道，服务器可以往回灌数据。
  消息是从服务器"流回来"的，不需要任何人能主动找到你的笔记本。
- **断了怎么办**：`_receive_loop` 是个 while 循环，连接断开（异常退出 async with）后按
  指数退避重连（1s → 2s → 4s ... 上限 60s），连上就重置。文档另有一条：超过 1 天没新消息
  平台会销毁收消息队列，重连会自动重建。

### 2.3 收到消息之后的两个关键动作（协议契约）

1. **3 秒内 ack**：收到 frame 先回 `{"ack": event_id}`，然后才开始处理。不 ack 平台会重发，
   所以 ack 和"交给 Agent 处理"解耦——Agent 跑 30 秒没关系，ack 是毫秒级的。
2. **幂等去重**：用 `event_id` 记"见过的"（`_already_seen`），ack 丢了导致的重发不会重复回复。

### 2.4 发消息：又是一条独立的 HTTP

回复不走那条 WebSocket，而是单独发 HTTP：

```
POST https://alarm.im.qihoo.net/message/custom/send?appid=&secret=
body: {"tousers": ["jinyan1"], "msgtype": "text", "text": {"content": "..."}}
```

**路由约定**：发送目标纯数字 → 群（`togroups`）；否则 → 用户域账号（`tousers`）。
收、发两条链路分离，好处是任何一边出问题另一边不背锅（出站失败可以重试，不影响收）。

### 2.5 验证：亲自看这两个连接

gateway 跑着的时候执行：

```bash
lsof -p $(pgrep -f "gateway run" | head -1) -iTCP -P | grep ESTABLISHED
```

能看到（2026-10-23 实测）：

```
TCP 10.18.127.127:56085->10.220.192.203:443 (ESTABLISHED)   ← 10.220.192.203 就是 alarm.im.qihoo.net
```

这条 ESTABLISHED 连接就是那条 WebSocket——由本机随机端口 56085 拨出去的。
而网关进程**自己监听的 TCP 端口数量是 0**（它唯一的"监听"是一个 Unix domain socket
`~/.hermes/gateway.sock`，本机进程间通信用）。公网上没有任何人能直接连到这个网关。

> **小白话**：微信视频通话里，你没开过路由器端口，但对方的声音能到你手机——因为连接是
> 你的手机拨出去的，声音顺着这条管子流回来。推推长连接是同一个道理。

### 2.6 对比：哪些平台只能用 webhook（监听）模式

需要平台"主动打过来一个 HTTP 请求"的平台（比如要接推推交互消息按钮）就必须暴露端口。
文档里推推交互按钮"要求反向 POST 回调 → 需要暴露端口，暂缓"，就是这个原因——
**笔记本场景下能出站的都不做、能拉取的不推送，是接入设计的第一原则**。

---

## 三、问题②：网关里不同用户的上下文隔离，是什么原理

### 3.1 先问"没有隔离会出什么事"

假设两个同事 A、B 同时用机器人：A 问"帮我看看项目的构建脚本"，B 发"把报告发给我"。
如果所有消息进同一个对话历史，模型看到的是一场四个人的混战聊天记录，谁的上下文都是错的。
**隔离的本质：给每个"对话"一个独立的 key，历史互不掺和。**

### 3.2 核心机制一：session key —— 决定"这是谁的对话"

每条消息进来，网关先造一个 `SessionSource`（这消息从哪个平台、哪个聊天、谁发的），
然后由**一个确定性函数**算出 session key（`gateway/session.py:685` `build_session_key`）：

```
<ns>:<platform>:<chat_type>[:<chat_id>][:<thread_id>][:<user>]
```

我们机器上的真实例子（今天推推私聊产生的）：

```
agent:main:tuitui:dm:jinyan1
 │     │      │      │     └─ 发送者域账号
 │     │      │      └─ 单聊
 │     │      └─ 平台名（插件注册的 name）
 │     └─ main = 默认 profile 的命名空间
 └─ agent = 命名空间前缀
```

规则的要点：

| 场景 | key 怎么变 | 效果 |
|---|---|---|
| 单聊 | 按聊天/发送者隔离 | A 和 B 的历史完全分开 |
| 群聊 | 群共享一个 session（默认），可按成员再分 | 群里对话有共同上下文 |
| 话题/线程 | 线程独立 key | 不同话题不串 |
| CLI / 网关 / cron | 各自的 key 空间 | 你的终端对话和推推对话**永远不混** |

**一切按 key 查库**：历史消息、模型选择、system prompt 覆盖，都以 session key 为主键。
隔离不是"内存里分了几个桶"，而是**数据层从 key 就分道了**。

### 3.2.1 动手验证（我们自己的库）

```bash
sqlite3 ~/.hermes/state.db "SELECT id, session_key, message_count FROM sessions ORDER BY started_at DESC LIMIT 3;"
```

实测输出：

```
20261023_160845_bb9232df | agent:main:tuitui:dm:jinyan1 | 3
```

这条就是今天推推私聊"你好你是谁"对应的会话行：key 里带着平台（tuitui）、
聊天类型（dm）、发送者（jinyan1）。你在 CLI 里聊的会话 key 形如 `agent:main:cli:...`，
两边天然不同行、不同历史。

### 3.3 核心机制二：Agent 实例是"每条消息现造的"

这是网关和 CLI 最大的架构差异：

| | CLI（终端里敲 hermes） | 网关 |
|---|---|---|
| Agent 生命周期 | 进 REPL 时建**一个**，之后每轮复用 | **每条消息**现建一个 Agent，用完即走 |
| 上下文从哪来 | 就在这个进程的内存里 | 从库里按 session key 把历史**重新装进**新 Agent |
| 记忆住在哪 | 进程内存 + 库 | **库才是事实之源**，内存只是缓存 |

为什么网关要这样设计：一个常驻进程要同时服务 N 个聊天，不可能给每个人常驻一个
内存里的 Agent 对象。所以网关的模型是 **"无状态进程 + 有状态数据库"**——
每个 Agent 实例都是"按 key 从库里拉出历史 → 跑一轮 → 结果落库 → 丢弃"。
好处是天然支持进程重启恢复、多平台并发；代价是每条消息有一次历史装载。

### 3.4 核心机制三：并发不踩踏 —— turn lease（轮次租约）

"每消息一个 Agent"解决了隔离，带来新问题：如果 B 的消息和 A 的消息几乎同时到、
或者 `/resume` 让两个聊天指向同一份历史，两边同时写一份 transcript 就乱了。

Hermes 的答案是**会话级租约**（`gateway/turn_lease.py`）：
「load history → run → flush」整段区域被一把锁保护，谁抢到谁跑，别人等待
（等超时就**失败关闭**——宁可让用户重发，不冒历史错乱的风险）。租约实体化在
库表 `session_turn_leases(conversation_id PRIMARY KEY, holder, acquired_at, expires_at)` 里。

结合代码注释里的场景：租约按"**解析后的 session_id**"而不是路由 key 加锁，
因为 key→session 的映射是多对一的（两个不同聊天可能 /resume 到同一个会话），
按 key 锁会漏。这是"先想清楚冲突面在哪，再决定锁的粒度"的范例。

### 3.5 核心机制四：多 bot / 多 profile（进阶，了解即可）

`gateway/AGENTS.md § Profile scope` 定义了更外层的隔离：**RoutingIdentity**。
每个入站事件先回答三件事——哪个 bot 收到的 / 谁有权限 / 在哪个 profile 的 HERMES_HOME 里跑，
回答一次、冻结在 source 上，后续所有 key 派生、授权检查、环境变量读取都以它为准。
多个 Hermes profile（每个有独立的 `~/.hermes-<name>/` 家目录、独立的密钥与记忆）可以由
**一个网关进程**复用服务（multiplex），环境变量读取 fail-closed：查不到本 profile 的值
绝不去借 `os.environ` 里别的 profile 的。今天我们没开 multiplex，属于 `agent:main:` 单命名空间。

### 3.6 和"直接在终端用 codex/CLI"的对比

| 维度 | 终端 CLI（含 codex 等终端 agent） | 网关 |
|---|---|---|
| 谁在用 | 一个终端窗口 = 一个人 | N 个用户 / N 个群，同一个进程 |
| Agent 生命周期 | 进程级：一次会话一个实例，长驻 | 每消息现建，用完丢弃 |
| 上下文住在哪 | 本进程内存（退出即失，靠 `--continue` 从库捞回） | 库是唯一事实，进程随时可死可换 |
| 身份 | 不需要——对面永远是你 | 每条消息要回答"这是谁"，白名单/配对码/管理员分层 |
| 会话隔离 | 天然（一人一终端） | session key 显式建模，群/线程/DM 各有规则 |
| 并发写入 | 天然串行（一个 REPL） | 租约序列化，防两个聊天同写一份历史 |
| 触发方式 | 人敲回车 | webhook / 长连接推送 / cron 到点 / API 调用 |

一句话：**CLI 的"上下文"是进程的副产品；网关把上下文变成一等公民（session key + 库），
于是同一个内核才能安全地同时属于很多人。** 这也是为什么推推私聊里聊的内容，
在 CLI 里 `hermes --continue` 看不到——它们的 key 根本不同。

---

## 四、小结

- **网关 = 一条出站 WS 收消息 + 一条 HTTP 发消息 + 按 key 隔离的会话存储**；插件只做"翻译"，核心流程共用。
- **出站长连接**：你拨出去的管道是双向的，服务器顺着它推消息，所以不需要公网 IP / 端口 / webhook。
- **上下文隔离三件套**：session key（确定哪份历史）→ 每消息重建 Agent（库里拉历史）→ turn lease（并发不踩踏）。
- **CLI vs 网关**：CLI 是"一个进程服务一个人"，网关是"一个进程服务所有人，靠 key 分身"。

---

## 五、动手题（自测是否真懂了）

1. `hermes gateway run` 跑起来后，执行
   `lsof -p $(pgrep -f "gateway run" | head -1) -iTCP -P | grep ESTABLISHED`
   找到连往 `10.220.192.203:443` 的那条——它是出站还是入站？关掉它重连会发生什么？
2. 用另一个推推账号给机器人发消息，看 `~/.hermes/logs/gateway.log` 出现什么？
   （答案方向：Unauthorized user + pairing 流程，参考本文 1.x 节与本机 15:57:32 那条日志。）
3. 如果把某条消息同时从 CLI 和推转发进同一 session（比如 /resume 指向同一会话），
   哪个机制保证不会写花历史？（提示：session_turn_leases 表。）
