# 自己的 Hermes · 使用指南

配套文档：**《安装指南》**（`SELF-INSTALL-GUIDE.md`，安装与验收）。

> 更新：2026-10-21

## 目录

| 章 | 内容 |
|---|---|
| §1 | 日常：建链、分支命名、查数/日志、k8s、其它约定 |
| §2 | 切换模型（每实例独立）|
| §3 | 常见问题（按症状查）|
| §4 | 可选：注册到 QCM |
| §5 | 归属、跨 agent 互发、红线、状态桥 |

---

## 用哪台：日常用你自己的实例，什么情况找 root

**日常开发工作全部走你自己那套实例**（《安装指南》快速路径装出来的那个，机器人是你自己申请的 bot，群里 @ 它就行）：

- 建链 / 看卡 / 派活 / 写代码 / 跑测试 / 出文档 / 发 MR —— 都在自己实例里做；
- 分支名、ai4se 需求归属、极库云文档作者 = **你本人**（SSO 用你自己的令牌，见 《安装指南》§2.1）；
- 模型自己切（§2）、配置自己改、网关自己重启；**别人的实例不要动，别人也不会动你的**。

**找 root 的 `@geo小牛马Plus`（群：唐中英、tzy的小牛马、geo小牛马Plus）只在这几种场景**：

| 场景 | 典型说法 |
|---|---|
| **共享资产 / 团队口径** | "分支命名规范现在是什么"、"两个实例为什么给出不同分支名"、"共享术语表加一个词"、"基线技能要加一个" |
| **要改共享代码或安装器** | `/opt/kanban-kit` 的流程脚本、`/opt/hermes-team` 的 onboard/verify、模型矩阵；加白名单群或账号 |
| **线上只读取证**（你自己没配通道时） | 查线上 MySQL / Kibana / Jaeger / APM、判影响面、要聚合计数 |
| **你自己实例出问题、修不动** | 网关起不来、`--kit-check` 报 rc=3、ai4se/SSO 归属异常、`EACCES` 权限问题 |
| **装 / 重装 / 迁移 / 批量操作** | onboard 报错、teardown 后重装、换机器、换端点批量切换 |
| **凭据操作** | 换模型 key、代某人写文档（需审批，令牌绝不进聊天） |

一句话：**你自己的活在自己实例里做完；碰到"共享的、跨人的、线上一手证据、或你自己修不动"的，再 @root。**
在群里 @ 它时带上：**你的账号 + 现象 + 报错原文 + 已经试过什么**，它一次就能给到位。

## 1. 日常怎么用

### 1.1 建链（研发 / 排查）

```bash
source ~/hermes/kanban/board.env
/opt/kanban-kit/bin/kanban-dev-flow.sh '【测试】一句话需求' --scope backend \
  --demand-no <需求号> --slug-en "media sync dedup version convergence"   # ★建议传 --slug-en
/opt/kanban-kit/bin/kanban-debug-flow.sh '媒体同步版本不收敛导致重复发稿'   # 排查修复 6 卡链（复现→根因→修复→验证→评审→提交）
/opt/kanban-kit/bin/ops-flow.sh '近 2 小时发布失败率抬升'                    # 问题排查 8 卡链
hermes kanban list                                                          # 看卡
```

两条链（研发 / 排查修复）共用同一套分支与提交流程：开发 `wt/…`、MR 源干净名 `feat-…`/`fix-…`；提交卡用 **git 语义搬运**（本地 WIP 快照 + 噪声黑名单 → `cherry-pick -n` → 一笔正式 commit），不再逐文件 cp + sha256。

卡建好后，网关自动派给你自己的角色（默认 60 秒一次，`dispatch_interval_seconds` 可调；角色：pm / architect / backend-dev / frontend-dev / qa / reviewer / release-manager / data / ops）。

### 1.2 分支命名（团队 AI4SE 规范，别再手写）

- **统一形态**：`feat-<需求号>[-<任务号>]-<英文短名>`，**不带 `-be`/`-fe`**。
  - 例：`feat-1060020-fix-media-sync-version-convergence-error`
  - 前缀统一用 **`feat`**：ai4se 默认正则 `feat(ure)?[-_]` 两种都认，团队口径定 `feat`，**不再用 `feature-`**。
  - 无需求号：`feat-<英文短名>-<hash>`；紧急修复可 `--branch-prefix fix`/`hotfix`（此时 ai4se 反解要显式带 `--demand`）。
  - 开发卡用 `wt/feat-…`（只改文件、不 commit）；提交卡用干净名 `feat-…`（语义搬运 → 一笔 commit → push → MR）。
- **英文名来源**：`--slug-en`（推荐）→ 共享术语表 + 模型翻译（自动回灌）→ 拼音（仅模型不可用时；链会 fail-closed 拒建）。
- **硬约束**：≤60 字符、全小写 ASCII、3~6 词、无连续连字符；**建了就不要改名**（改名 = 新 MR + ai4se 断链）。
- **自检**：`python3 /opt/kanban-kit/lib/branch_name.py --self-test`（`kanban-kit.sh sync` 会自动跑）。

### 1.3 查数据 / 查日志（一行一条）

```bash
/opt/geo-kit/geo-db.sh --info                                   # 探活
/opt/geo-kit/geo-db.sh "SELECT COUNT(*) FROM media"              # 查数（只读）
less /opt/geo-kit/README-geo-logs.md                             # ES / Jaeger / APM 的现成命令
```

- 大表别做全量 COUNT，先给时间窗/渠道过滤。
- 只给聚合与抽样；要明细先说明用途（红线见 §5.3）。

### 1.4 k8s 只读排查（共享配置，装完即用）

全组共用 `/etc/kube/readonly.conf`（身份 `plat-arch-readonly`），**不用自己准备 kubeconfig**。

开通只要两件事（第 ① 条命令 `onboard.sh` 会自动做完）：

| # | 条件 | 谁做 |
|---|---|---|
| ① | 给账号 **ACL 授权**（文件 `r` + 目录 `x`）| 自动（`onboard.sh` → `kube-readonly-onboard.sh`）|
| ② | `.env` 写入 `KUBECONFIG=/etc/kube/readonly.conf` | 自动 |

> **ACL 的好处**：权限在每次打开文件时判定，**立即生效** —— 不需要重登、不需要重启网关、不需要重载用户会话。
> 补开/体检：`sudo bash /opt/hermes-team/kube-readonly-onboard.sh <账号> [--check|--revoke]`
> （老机器没有 `setfacl` 时回退到组 `hermes-kube`，那种方式才需要重载用户会话）

验证（三条都要过）：

```bash
kubectl config current-context                  # plat-arch-context
kubectl get pods -n plat-arch | head            # 能列出 pod
kubectl auth can-i create pods -n plat-arch     # no（服务端判决）
```

权限边界：

- ✅ 命名空间 `plat-arch` 内 `get/list/watch`（pod/job/deployment/service/ingress/hpa 等，**含 secrets**）—— **红线：Secret 内容查到即弃，禁止贴进聊天/文档/卡评论，也不要整段转发 kubectl 原始输出**
- ❌ 集群级（`get ns`、`get pods -A`）→ `Forbidden`；无任何写权限
- ⚠️ 全员共用同一个 ServiceAccount，集群审计**无法归因到人**；要归因需每人单独签发只读身份
- ⚠️ 轮换只改 `/etc/kube/readonly.conf` 一处，各实例无需改动

### 1.5 其它约定

- 建 ai4se 需求（`--ai4se-new-demand`）时，**极库云各项目的必填属性不同**：链脚本默认带「需求类型 + 状态」，要改就用 `--ai4se-demand-status` / `--ai4se-demand-attr '名=值'` / `--ai4se-demand-data '<json>'`（踩坑见 §3）。
- 改了 `~/.hermes/.env` **通常不用重启网关**（`.env` 每轮热加载）；没生效再 `systemctl --user restart hermes-gateway`。
  - 例外：k8s 权限走 **ACL**，同样即时生效；只有老机器回退「组授权」时，附加组才需要重载用户会话。
- 同标题重复建链是安全的：7 张卡都有各自的幂等键，第二次会返回已有链，不会多出一套下游卡。

## 2. 切换模型（每个实例自己切，互不影响）

### 2.1 三层结构（先理解再动手）

| 层 | 位置 | 谁维护 | 作用 |
|---|---|---|---|
| **默认矩阵**（按端点自动选） | `model-matrix-zyuncs.json`（智企，新实例默认）／`model-matrix.json`（360 智脑，仅 root）／`model-matrix-cn.json`（全国内，合规/成本优先） | owner | 9 个角色各用哪个模型 |
| **个人偏好** | `~/.hermes/model-overrides.json`（600，只有你和 root 能读） | **你自己** | 覆盖矩阵里某几个角色的模型 |
| **生效位置** | `~/.hermes/config.yaml` + `~/.hermes/profiles/<9 个角色>/config.yaml`（共 10 份） | 脚本写 | 网关**启动时**读它 |

**新实例默认矩阵（智企 zyuncs，9 个角色）**：

| 角色 | 模型 | 角色 | 模型 |
|---|---|---|---|
| architect | `openai/gpt-6.1-sol-cpr` | data | `openai/gpt-6.1-sol-cpr` |
| pm | `anthropic/claude-sonnet-5-cpr` | qa | `z-ai/glm-5.3-flash` |
| backend-dev | `anthropic/claude-sonnet-5.5-cpr` | ops | `z-ai/glm-5.3-flash` |
| frontend-dev | `anthropic/claude-sonnet-5.5-cpr` | release-manager | `deepseek/deepseek-v4.1-flash` |
| reviewer | `anthropic/claude-opus-5.5-cpr` | — | — |

切换脚本：`/opt/hermes-team/switch-model.sh`（只改**你自己**，不动别人的、也不改矩阵）。
矩阵按你 `config.yaml` 里的 `base_url` **自动匹配**；端点不同模型名不同，写错就是 401/403。

### 2.2 命令清单

```bash
bash /opt/hermes-team/switch-model.sh --list                 # ① 看：每个角色现在用什么、来源（默认矩阵/个人）
bash /opt/hermes-team/switch-model.sh --models               # ② 看：当前端点可选模型（数量随端点变化，以输出为准）
bash /opt/hermes-team/switch-model.sh --endpoints            # ③ 看：可切换的端点（360zhinao / zyuncs）

bash /opt/hermes-team/switch-model.sh --set reviewer=openai/gpt-6-astra --dry-run   # ④ 预演（不落盘）
bash /opt/hermes-team/switch-model.sh --set reviewer=openai/gpt-6-astra             # ⑤ 真切（可多组：a=m1 b=m2）
bash /opt/hermes-team/switch-model.sh --set-all z-ai/glm-5.3-flash                  # ⑥ 一把梭：9 个角色同一个模型
bash /opt/hermes-team/switch-model.sh --reset                                       # ⑦ 撤销个人偏好，回默认矩阵

bash /opt/hermes-team/switch-model.sh --endpoint zyuncs         # ⑧ 换整条端点（连带矩阵与模型名规则）
bash /opt/hermes-team/switch-model.sh --endpoint 360zhinao      # ⑨ 换回 360 智脑
```

### 2.3 标准流程（照这个顺序，五分钟）

```bash
# 1) 现状（记下你现在的模型，方便回滚）
bash /opt/hermes-team/switch-model.sh --list

# 2) 预演：只看差异，不写任何文件
bash /opt/hermes-team/switch-model.sh --set backend-dev=anthropic/claude-sonnet-5.5-cpr --dry-run
#    每行写清 变更=default: 旧 → 新；末尾打印「（dry-run：未落盘）」

# 3) 真切
bash /opt/hermes-team/switch-model.sh --set backend-dev=anthropic/claude-sonnet-5.5-cpr

# 4) 重启你自己的网关（配置只在启动时读，不重启 = 没生效）
systemctl --user restart hermes-gateway

# 5) 复核
bash /opt/hermes-team/switch-model.sh --list        # 该角色「来源」= 个人
systemctl --user status hermes-gateway --no-pager | head -5
#    再在推推里问它一句，能正常回 = 新模型可用
```

**回滚**（三种粒度，任选）：

```bash
bash /opt/hermes-team/switch-model.sh --set backend-dev=<原来的模型>   # 单角色改回
bash /opt/hermes-team/switch-model.sh --reset                          # 全撤个人偏好 → 回默认矩阵
ls ~/.hermes/config.yaml.bak-*-model                                   # 每次落盘都留备份，可直接拷回
```

### 2.4 换端点（360 智脑 ↔ 智企 zyuncs）

```bash
bash /opt/hermes-team/switch-model.sh --endpoints                    # 看两个端点与模型名规则
bash /opt/hermes-team/switch-model.sh --endpoint zyuncs --dry-run    # 预演（模型名会自动带 -cpr）
bash /opt/hermes-team/switch-model.sh --endpoint zyuncs              # 切端点 + 矩阵 + 模型名
bash /opt/hermes-team/update-model-key.sh                            # 换该端点对应的 key（主 .env + 9 个 profile .env 一起改）
systemctl --user restart hermes-gateway
```

- **为什么必须用 `update-model-key.sh` 改 key**：每个实例有 10 份 `.env`（主 + 9 个角色 profile）。只改主 `.env` → 那 9 个角色起来就是 **401**。
- 它支持：`--check [账号]`（只体检，不打印值）、`--from-file <600 的文件>`、`<账号> --copy-from root`（复用另一实例已输入的 key）。
- 新 key 只从**隐藏输入**或 600 文件读，**不回显、不落日志**。

| 端点 | base_url | 模型名规则 |
|---|---|---|
| 360 智脑 | `https://api.360.cn/v1` | 不带 `-cpr` |
| 智企 zyuncs | `https://llm.api.zyuncs.com/v1` | **必须带 `-cpr`**，写错报 `403 Permission deny` |

## 3. 常见问题（按症状查）

### 3.1 装坏了 / 机器人不回话 / 环境

| 现象 | 怎么办 |
|---|---|
| 机器人不回话，日志 `No messaging platforms enabled` | 没装推推插件 → 重跑第 ① 条命令 |
| 通道不通 / 推推接口超时 | 机器人账号被填成昵称了 → 重跑第 ② 条命令（自动纠正） |
| 日志 `Permission denied: '~/.local/state/hermes'` | 家目录里有 root 建的目录 → 跑 `verify.sh` 看提示 |
| **`ai4se: command not found` / `Permission denied`** | ai4se 曾装成 `…/node_modules/ai4se → /root/.ai4se/…`（非 root 穿不进 `/root`）→ 已修为 `/opt/ai4se` 共享副本；`verify.sh` 会查这项 |
| **基线技能不全 / 查库报 bws 或 mysql 缺失** | `sudo bash /opt/hermes-team/baseline-skills.sh sync`；工具链用 `kit-check` 看缺什么 |
| 改了 `.env` 没反应 | 多数情况已热加载；仍无反应 → `systemctl --user restart hermes-gateway` |
| `hermes kanban list` 是空的 | 还没建卡，或看板不对 → `hermes kanban boards switch geo` |
| `env: 'node': Permission denied`（exit 126） | 共享 node 路径不可读 → 找管理员（已修） |
| 机器人回 `⚠️ Something went wrong…` | **会话上下文太长**，不是装坏了 → 发 `/new` 开新会话；已落盘的脚本/文件不受影响 |

### 3.2 建链 / worker / 分支名

| 现象 | 怎么办 |
|---|---|
| **建链跑到一半静默退出、退出码 2、没有任何报错** | 缺依赖 helper（`hermes_operator.py`）。**2 是 python3 的「文件不存在」，不是链的业务码 3**，所以没提示 → `sudo bash /opt/hermes-team/kanban-kit.sh render` 后重跑。（新版脚本已改成：缺 helper 时**显式报错 + 退出 3**） |
| **建链 rc=3「config.yaml 与团队基线不一致」** | 看**差异键**：只有模型/端点键 = 闸门旧版 → `sudo bash /opt/hermes-team/kanban-kit.sh render <你>`（切模型不会打停建链）；差的是别的键 = 真被改过，按提示恢复 |
| **worker 报 `gopls: Permission denied`（exit 126）** | 历史上 gopls 只有 root 能穿（软链进 `/root`）→ 已修：`/opt/gopls/gopls` 共享副本 + `/usr/local/bin/gopls`；验收 `gopls version`（应报 v0.23.0）。仍不可用就退回 `grep + nl` 取证 |
| **worker 里 `hermes kanban list` 报 `cannot mutate Kanban tasks`（rc=1）** | 该命令在读之前会跑一个写事务（recompute_ready），被平台子上下文闸门拦下 → 已修（子上下文跳过该副作用）。同时**卡正文已改为用 `kanban_list` / `kanban_show` / `kanban_comment` 工具**，按工具走最稳 |
| **`ai4se_map_add.py` 报 `ok: true` 但映射没变 / 家目录多出 `${HERMES_HOME:-…}` 怪目录** | 渲染把 shell 变量塞进了 Python 字符串（不展开）→ 已修（`.py` 不再被 sed 参数化 + 写完回读校验 + 路径含 `$` 即 exit 3）。已中招：删掉那个字面量目录，重跑 `kanban-kit.sh render <你>` |
| **分支名是拼音 / 建链被拒（exit 3，提示拼音兜底）** | 没给英文名来源：建链加 `--slug-en "3~6 个英文词"`；或你的实例模型 key 不通导致"模型翻译"不可用（`kit-check` + 看 `.env`） |
| **两个实例对同一标题给出不同分支名** | 该词还没回灌共享表 → 跑一次 `sudo bash /opt/hermes-team/kanban-kit.sh sync`（自动合并）；仍不同 = 有冲突，看 `CONFLICT` 行并改共享表 |

### 3.3 模型与端点

| 现象 | 怎么办 |
|---|---|
| **切了模型但回话还是老模型 / 报 `403 Permission deny` / 401** | 403 = 模型名与端点不匹配（zyuncs 必须带 `-cpr`）；401 = key 不对，或只改了主 `.env`（漏了 9 个 profile）；完全没变 = 没重启网关 → §2.3 / §2.4 |
| **跑了 `--dry-run`，`--list` 里的来源却变了** | 旧版 bug（已修）：用现版 `switch-model.sh`；已误写的偏好用 `--reset` 撤掉 |

### 3.4 ai4se / 归属 / 状态桥

| 现象 | 怎么办 |
|---|---|
| **落库/建文档失败**：`请确保已安装并完成登录` / 401 / `errcode 408` / 文档【创建人】不是你 | 本人没登录极库云 SSO（或令牌过期）→ 见 《安装指南》§2.1：`qihoo-sso-cli auth add <你> --manual`；代写场景跑 `sso-refresh-all.sh --check` |
| **bot ↔ bot 互相收不到 / 日志 `Unauthorized user: bot-xxxx`** | 跨 agent 互发要**双向白名单**：双方各自把对方账号加进自己的 `TUITUI_ALLOWED_USERS` → 见 §5.2 |
| **`ai4se` 报 `用户文件不存在: ~/.config/ai4se/users/<你>.env`（CONFIG）** | 链脚本会注入 `AI4SE_USER=<账号>`，而 ai4se 对它 **fail-closed**（不回退全局身份）→ 缺这个文件**所有** ai4se 命令都报 CONFIG。修（一条）：`sudo bash /opt/hermes-team/tooling-onboard.sh $(id -un)`（会建 `users/<你>.env`，600） |
| **建 ai4se 需求报 `errno 3000 状态是必填属性`** | 各项目必填属性不同（geo 6515 必填「状态」，合法值如 `AI初评`）。可覆盖：`--ai4se-demand-status` ／ `--ai4se-demand-attr '名=值'` ／ `--ai4se-demand-data '<json>'`。⚠️ 报 3000 时服务端**可能已建记录** → 先 `ai4se query demand --docid <URL> --json` 查重再重跑 |
| **跑一次 ai4se，业务仓库就多出未提交改动**（`.claude/commands/opsx/*.md` 被换成短文件） | ai4se 的 shim 自愈曾**静默覆盖被 git 跟踪的项目自有命令** → 已打本地补丁（见 RUNBOOK「ai4se 链路踩坑」）：被 git 跟踪 / 非 ai4se 内容的文件**跳过 + 告警**，日志出现 `[ai4se] 跳过 shim 自愈` 属正常；要临时整体关闭用 `AI4SE_NO_SHIM_HEAL=1`。若你的仓库已被改脏：`git checkout -- .claude/commands/opsx/` |
| **ai4se 需求状态一直停在「AI初评」**（`createTime == updateTime`，建完再没动过） | 状态桥**四要素**缺一条（hooks 段 / consent / 重启网关 / 映射表可写）→ 见 **§5.5**；紧急兜底：`python3 ~/.hermes/scripts/kanban_ai4se_bridge.py --align --tenant <租户>`（幂等，按看板现状对齐） |

## 4. 可选：注册到 QCM

```bash
sudo bash /opt/hermes-team/onboard.sh --qcm      # 装的时候顺手注册
sudo bash /opt/hermes-team/qcm-onboard.sh        # 单独注册；加 --check 只看状态
```
- 服务名 = **你自己的机器人名**（小写化，如 `geo小牛马plus`），注册**面板(91xx) + A2A(99xx)** 两个地址。
- 凭据共用管理员那份（你目录里不存 QCM token）；续租由管理员侧 cron 统一跑，你不用管。
- ⚠️ 本机到 QCM 的网络还没开通，注册会报 `register errror` —— 先让管理员开通。

## 5. 归属 · 跨 agent 互发 · 红线

### 5.1 极库云 SSO 归属（机制一句话）

本机 `qihoo-sso-cli` 是 **Node 版单令牌**实现、**不读 `SSO_USER`**；有效身份 = 被选中令牌 JWT 里的 `username`。
`SSO_USER` = **声明作者**（+ fail-closed 闸门 + 留痕），**不授予身份**。
所以：**归属要修的是"本人有没有登录 / 有没有自己的令牌"，不是去改 `SSO_USER`**。

团队工具：

```bash
sudo bash /opt/hermes-team/sso-identity-onboard.sh <账号>   # 代写场景：给某人配独立 HOME 身份
bash /opt/hermes-team/sso-whoami.sh <账号>                  # 照妖镜：0=一致 / 1=不一致 / 2=取不到
bash /opt/hermes-team/sso-refresh-all.sh --check            # 查各人令牌有效期与归属（不写文件）
```

### 5.2 跨 agent 互发（bot ↔ bot）：**双向白名单**

两个 bot 之间要能互相收到消息，**必须双方各自**把对方账号加进自己的 `TUITUI_ALLOWED_USERS`（在 `~/.hermes/.env`）。**只加一边 = 只能单向通**。

被拦的表现是网关日志一行 WARNING（在**网关层**就把消息丢了，比插件的 bot 门槛更靠前）：

```
WARNING gateway.run: Unauthorized user: bot-xxxxx (<机器人昵称>) on tuitui
```

自检（拿服务端为准的 `robot_account` 与自己的 `.env` 对账，不打印任何凭据）：

```bash
set -a; . ~/.hermes/.env; set +a
python3 - <<'PY'
import json, os, ssl, urllib.request
u = "https://im.live.360.cn:8282/robot/prop/get?appid=%s&secret=%s" % (
    os.environ["TUITUI_BOT_APPID"], os.environ["TUITUI_BOT_SECRET"])
c = ssl.create_default_context(); c.check_hostname = False; c.verify_mode = ssl.CERT_NONE
d = json.loads(urllib.request.urlopen(u, timeout=20, context=c).read())
d = d.get("data") if isinstance(d, dict) and isinstance(d.get("data"), dict) else d
print("服务端 robot_name=%s robot_account=%s" % (d.get("robot_name"), d.get("robot_account")))
print(".env TUITUI_BOT_ACCOUNT=%s" % os.environ.get("TUITUI_BOT_ACCOUNT"))
PY
```

然后互加：`vi ~/.hermes/.env` → `TUITUI_ALLOWED_USERS=<你自己>,<对方 bot 账号>`。

- 已知账号：`bot-eYXqtigb`=geo小牛马Plus（root）｜`bot-1aQMkqsE`=tzy的小牛马（tangzhongying1）｜`bot-QiFxz7lR`=geo小牛马｜`bot-0fwz7858`=GEO项目龙虾。
- 角色 profile 里的 `platforms.tuitui.extra.allow_from` 是**历史键**，推推插件读的是 `TUITUI_ALLOWED_USERS` / `allowed_users`，**别再往 `allow_from` 里加人**。

### 5.3 红线（别踩）

1. **禁止部署系统级共享令牌** `/etc/qihoo-sso-cli/token.json` —— 优先级最高，会覆盖全员身份。
2. **不要设** `SSO_ACCESS_TOKEN` / `SSO_REFRESH_TOKEN` —— 服务端不认（实测 408），且会误导排查。
3. 「代某人写」只用**独立 HOME 注入**（`sso-identity-onboard.sh`），属**凭据操作**：要有明确场景与审批，令牌**绝不**进聊天/文档/卡评论。
4. `SSO_USER` 一律称「**声明作者**」，别当身份开关。
5. **生产写操作**（改数据/改配置/发版）必须**先获批 + 先写 change_record**；查库只用只读账号。
6. **谁的网关谁重启**；别人的家目录不要动。

### 5.4 A2A：本机侧口径 = **仅入站**

各实例 `platforms.a2a.extra.port=99xx` 开着，但**出站要凭据**（`config.yaml` 的 `a2a_agents` 里登记对端 `url` + `bearer`，对端再把我们加进 `A2A_PEER_TOKENS`）。本机**不代发** peer token（凭据不进别人目录）→ 所以口径定为：**A2A 仅入站**。要开某实例出站 = 一次凭据操作，需 owner 批准。

### 5.5 状态桥生效四要素（卡状态 → ai4se 需求状态）

链建完需求后，**卡的状态流转靠 shell 钩子推进极库云需求状态**（`~/.hermes/scripts/kanban_ai4se_bridge.py`）。
四要素**缺任一条** → 桥就是**死代码**：需求状态永远停在建完那一刻
（现象：`demandStatus` 一直是「AI初评」、后端 `createTime == updateTime`、`hermes hooks list` 空的）。

| # | 要素 | 满足条件 | 怎么补 |
|---|---|---|---|
| ① | `hooks:` 段 | `$HERMES_HOME/config.yaml` 里有 3 个 `kanban_task_*`（claimed/completed/blocked）→ 桥脚本 | `sudo bash /opt/hermes-team/kanban-onboard.sh <你>`（新版已自动注入） |
| ② | consent（授权） | `hooks_auto_accept: true`，或进程里有 `HERMES_ACCEPT_HOOKS=1` | `hermes config set hooks_auto_accept true`；否则 `hermes hooks doctor` 会明确报 `not allowlisted — hook will NOT fire at runtime` |
| ③ | 重启网关 | 网关**启动时间 ≥ config 修改时间** | `systemctl --user restart hermes-gateway`（gateway **只在启动时**执行 `register_from_config`，改完配置不重启 = 没生效） |
| ④ | 映射表**可写** | `~/.hermes/kanban/ai4se_map.json` 属主是**你本人** | `sudo chown $(id -un): ~/.hermes/kanban/ai4se_map.json`（属主是 root 时你改不动 → 桥推不动；链收尾自检会报 ④ ✗） |

**取舍（②）**：`hooks_auto_accept: true` = 自动信任**未来所有** shell 钩子（包括后来别人加的）。
不想开就把 `HERMES_ACCEPT_HOOKS=1` 写进 `.env`（等价、作用域更窄），或每次交互式加 `hermes --accept-hooks`。
> 注：**gateway / cron 这类非交互运行不会弹授权提示** → 只靠 `hermes --accept-hooks` 手工跑是**不够**的。

自检：
```bash
hermes hooks list     # 应列出 3 个 kanban 事件，且不能有 not allowlisted
```
链脚本每次收尾会自动打「状态桥（kanban→ai4se）生效自检」；✗ 会直接给出**修法 + 结论**（不再让你以为配了其实是死的）。

事后兜底（钩子没生效、或网关重启期间丢了事件 → 状态落后）：**按看板卡现状对齐，幂等**
```bash
python3 ~/.hermes/scripts/kanban_ai4se_bridge.py --align --tenant <租户> --dry-run   # 先看会推到哪
python3 ~/.hermes/scripts/kanban_ai4se_bridge.py --align --tenant <租户>             # 真推（只补无需额外参数的阶段）
```
