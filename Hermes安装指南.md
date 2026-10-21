# 自己的 Hermes · 安装指南

机器 **10.41.211.243**；用**你自己的账号** login（root 登不上）。全程约 10 分钟，其中拉代码 2~4 分钟。

> 更新：2026-10-21

## 快速路径（只想装起来，看完这一段就够）

```bash
ssh <你的账号>@10.41.211.243
sudo bash /opt/hermes-team/onboard.sh --name <中文名>   # ① 铺环境
bash ~/hermes/setup-me.sh                              # ② 填 3 个值（模型 key + 推推 appid/secret）
sudo bash /opt/hermes-team/kanban-onboard.sh --clone    # ③ 看板 + 拉代码
sudo bash /opt/hermes-team/kanban-kit.sh render         # ④ 铺流程脚本
bash /opt/hermes-team/verify.sh                         # ⑤ 验收：问题 0 项
```
装完再手动做一件事：**本人登录一次极库云 SSO**（§2.1），否则建需求/写文档会 401 或记错人。

**本文只管装机器**（§0–§4 + 验收/重装）。装完怎么用（建链、查数、k8s、切模型、红线）→ **《使用指南》** `HERMES-USAGE-GUIDE.md`。

## 装在哪、和 root 什么关系

日常开发全部走**你自己那套实例**（机器人是你自己申请的 bot）。只有这几类再找 root：**共享资产/口径、改共享脚本、线上只读取证、你自己修不动、装/重装/迁移、凭据操作**。群里 @ 它时带上：账号 + 现象 + 报错原文 + 已试过什么。

## 0. 先做两件事

1. **申请 ACL**：内网访问这台机器需要权限 → <https://sec.corp.qihoo.net/addorder/xiangyun_vpn>。没批之前 `ssh` 连不上（不是机器问题）。
2. **准备 3 个值**（见第 2 节），第 ② 条命令里填；**做完 §2.1 的 SSO 登录**。

## 1. 安装细节（命令见顶部「快速路径」）

五条命令和逐行注释都在顶部，这里只讲每条要注意什么：

- **通用**：账号参数可省略（默认就是你自己）；只有**别人替你跑**时才要写账号。
- **k8s 只读排查**：① 装环境时**自动开通**（ACL 授权，即时生效）；个别没开成的由 root 补一条 `sudo bash /opt/hermes-team/kube-readonly-onboard.sh <你>`（见 《使用指南》§1.4）。
- **① 铺环境**：默认写**智企 zyuncs**（`--endpoint 360zhinao` 可改成 360 智脑）。端点决定你该拿哪把 key，见 §2.2 ——**先定端点，再要 key**。
- **① 附带**：已把 **21 个基线技能**（查库 / 查日志 / 监控 / 生产纪律）铺进 `~/.hermes/skills/`，只读工具包在 `/opt/geo-kit/`（全局一份）。核对与补齐：

```bash
bash /opt/hermes-team/baseline-skills.sh check              # 期望「缺 0」；有缺口就下面一条
sudo bash /opt/hermes-team/baseline-skills.sh sync          # 幂等；在你自己那份上改过的技能不会被覆盖
bash /opt/hermes-team/baseline-skills.sh kit-check          # bws / mysql 是否就绪（查库脚本要用）
```
  - **查库**：`/opt/geo-kit/geo-db.sh "SELECT ..."`，MySQL 只读账号，凭据从你 `.env` 的 `BWS_ACCESS_TOKEN` 取，脚本自己读，不用你填。
  - **查日志**：Kibana/ES、Jaeger、APM/Pyroscope 免凭据，命令见技能 `geo-online-troubleshooting`；`kubectl` 走**共享只读配置** `/etc/kube/readonly.conf`（不读 owner 的 `~/.kube/config`，也不用你自己准备），开通见 《使用指南》§1.4。
  - 技能在**网关下次启动**时加载（① 之前你就装了网关的，重启一次自己的网关即可；这一步只影响你自己）。
- **① 参数**：`--name` 只用于台账/README 显示，可省；git 身份、ai4se、采集器都用**登录名**。
- **②** 会提示你输一次 sudo 密码（为了开 `enable-linger`，让网关注销后仍运行）。
- **④ 别省**：③ 的收尾已经会自动帮你跑一次 render，④ 是显式兜底（也是「清空重来」后唯一必须补的一步）。
  - 为什么必须 render：流程脚本依赖 `~/.hermes/scripts/` 下的 helper。**少了它们，建链会在身份解析处静默退出、退出码 2、没有任何提示**（详见 《使用指南》§3）。
  - 幂等：随时可以再跑一次，只覆盖共享脚本，不动你的配置/看板。

## 2. 要填的 3 个值（第 ② 条命令里填）

| 值 | 从哪来 |
|---|---|
| **模型 API key** | 你自己的（**每人一把，别填成别人的**）。**端点与 key 绑定**：新实例默认走**智企 zyuncs** → key 必须是智企签发的（root 那台才用智脑 key），详见 §2.2 |
| **推推机器人 appid** | 推推里搜「**推推机器人助手**」→ 发 `/新建`，它会给你建一个**你自己的**机器人并回你 appid |
| **推推机器人 secret** | 同上，和 appid 一起给你 |

- 机器人账号（`bot-xxxxxxxx`）**不用你找**：脚本拿 appid/secret 问服务端，自动写回。
- 值会**逐项回显**给你核对（密字段只印「长度 N + 末 4 位」）；不想回显就加 `--hide`。
- 只检查、不改任何东西：`bash ~/hermes/setup-me.sh --check`。

### 2.1 ⚠️ 归属：请**本人登录一次极库云 SSO**（谁写的文档才记谁名下）

有效身份 = `~/.qihoo-sso-cli/auth/config.json` 里那把令牌的 `username`；`SSO_USER` 只是「声明作者」，不授予身份。

```bash
qihoo-sso-cli auth add <你的登录名> --manual    # 令牌落在你自己家目录（600）
qihoo-sso-cli auth status                       # 应显示  <你>: [Valid] (expires: …)
editor-cli spaces                               # 能列出空间 = 极库云落库/建文档通道通了
```

- **一个账号做一次就够**；位置在**第 ② 条之后、第 ③ 条之前**。
- 不做也能装完，但 `verify.sh` 会亮 1 项；建需求/写文档会 401 或【创建人】记成默认人。
- 机制、以及「代某人写」的独立身份做法 → 《使用指南》§5.1。

### 2.2 端点与 key 的对应关系（别拿错 key）

| 端点 | base_url | key | 模型名规则 | 适用 |
|---|---|---|---|---|
| **智企 zyuncs（新实例默认）** | `https://llm.api.zyuncs.com/v1` | 智企签发的 key | 按 zyuncs 矩阵（部分模型**必须带 `-cpr`**） | `onboard.sh` 现在默认写这个端点；`kanban-onboard.sh` 会把 9 个角色的连接参数也对齐到它 |
| 360 智脑（**仅 root 实例**） | `https://api.360.cn/v1` | 360 智脑签发的 key（**与智企不通用**） | 不带 `-cpr` | owner 那台 `@geo小牛马Plus` 保持这个端点；新建实例不要选它 |

- **实测**：拿 360 的 key 打智企端点 → `401 Unauthorized`（反向同理）。所以**先定端点，再要对应 key**，两边不能混用。
- 变量名固定是 `HERMES_CUSTOM_API_360_CN_API_KEY`（历史命名，两个端点都用它）：**换端点不换变量名，只换值**（用 《使用指南》§2.4 的 `update-model-key.sh`，它会一次改主 `.env` + 9 个 profile `.env`）。
- 新实例默认已是智企，一般**不用切**；确实要回到 360 智脑（仅排障/对齐 owner）：`switch-model.sh --endpoint 360zhinao` → `update-model-key.sh` 换成智脑 key → 重启自己网关（《使用指南》§2.4）。

## 3. 装完长这样

| 装了什么 | 位置/表现 |
|---|---|
| 你的 Hermes 配置 | `~/.hermes/config.yaml`（模型端点=智企 zyuncs + `api_mode=chat_completions`、推推开关+只要你本人、A2A 端口）；`~/.hermes/model-endpoint.json` 记着端点，`switch-model.sh --list` 会显示 |
| 凭据 | `~/.hermes/.env`（600，只有你能读；含 `SSO_USER=<你>` = **声明作者**，不是身份开关） |
| 网关（用户级） | `systemctl --user status hermes-gateway`；linger=yes 保证注销后仍在跑 |
| 推推插件 | `~/.hermes/plugins/tuitui`（缺了机器人就不回话：日志报 `No messaging platforms enabled`） |
| **基线技能（21 个）** | `~/.hermes/skills/`：查库/查日志/监控/告警/生产纪律 + 推推/凭据/ai4se 等；清单 `/opt/hermes-team/skills-baseline/MANIFEST.tsv` |
| **只读查库工具包** | `/opt/geo-kit/`（`geo-db.sh` MySQL 只读、`sr-db.sh`、`README-geo-logs.md`）——全局一份，凭据走你 `.env` |
| 看板 | 共享代码 `/opt/kanban-kit`，**你自己一套看板** `geo`；环境 `~/hermes/kanban/board.env` |
| **流程脚本 / 依赖脚本** | `~/hermes/kanban/bin/`（8 个流程脚本）+ `~/.hermes/scripts/`（20+ helper，含 `branch_name.py`/`hermes_operator.py`/`geelib_publish.py`/`chain_identity.sh`/`sso_identity.sh`）——**由第 ④ 条 render 安装** |
| **9 个角色** | `~/.hermes/profiles/<角色>/`（pm/architect/backend-dev/frontend-dev/qa/reviewer/ops/release-manager/data）；各角色模型见 **《使用指南》§2.1 矩阵表**，可用 `switch-model.sh` 覆盖。**矩阵只对新实例生效；root 固定 360 智脑** |
| **共享分支术语表** | `/opt/kanban-kit/glossary-shared.tsv`（root 维护；你的实例只读） |
| **ai4se CLI** | 全局 `/usr/local/bin/ai4se` → `/opt/ai4se`（共享只读副本，**非 root 可用**）；你自己的身份在 `~/.config/ai4se/env`（用户名 + endpoint + 个人令牌） |
| **极库云 SSO** | `~/.qihoo-sso-cli/auth/config.json`（本人登录后才存在，600）——**归属靠它**，见 §2.1 |
| 代码 | `~/Source/adgit/geo/geo`（用你自己的 adgit 身份 clone） |
| 用量上报 | `~/.hermes-token-reporter/` + 你的 crontab 一行（只扫你自己的库） |
| AI 会话采集器 | 用户级服务 `ai-usage-collector.service`（没有 Codex/Claude 会话目录时**待命**，不占内存） |
| **k8s 只读** | `/etc/kube/readonly.conf`（单文件共享，ACL 授权）+ `.env` 的 `KUBECONFIG`；装完即用 |
| 端口 | A2A `99xx` + 面板 `91xx`（安装时分配，重跑不改号） |

> 只读共享物，别改：`/opt/hermes-team/`（脚本）、`/opt/kanban-kit`、`/opt/geo-kit`、`/opt/hermes-plugins`、`/opt/codex`、`/opt/ai-usage-collector`、`/opt/node`、`/opt/ai4se`。
> 你**自己**的东西（`~/.hermes/`、`~/hermes/`、`~/Source/`）归你，可以自己调；共享脚本要改找 owner，别拷一份改了自己跑（`--kit-check` 会拒）。

## 4. 验收（四条都过才算装好）

```bash
bash /opt/hermes-team/verify.sh <你的账号>            # 期望：问题 0 项（项数随你装了什么浮动）
bash /opt/hermes-team/baseline-skills.sh check        # 期望：缺 0（个人改过 1~2 个属正常，不算错）
bash /opt/hermes-team/baseline-skills.sh kit-check    # 期望：geo-db.sh/sr-db.sh/README 可见 + bws/mysql 就绪
qihoo-sso-cli auth status && editor-cli spaces        # username = 你本人；能列出空间
```

`verify.sh` 会机械核对（这几项是真查的，不是看表）：

- `ai4se` 非 root 可执行 + `ai4se ping` 通（服务端可达）
- `~/.hermes/scripts/` 依赖脚本 + `~/hermes/kanban/bin/` 流程脚本**齐不齐**（缺了会告诉你跑 render）
- **基线技能就位**（`baseline-skills.sh check` 缺 0 才算过）
- `TUITUI_BOT_ACCOUNT` 与推推服务端 `/robot/prop/get` 返回的 `robot_account` **一致**
- **极库云 SSO**：系统级共享令牌没被部署、环境没被注入 `SSO_ACCESS_TOKEN`、**归属 = 本人**
- 家目录里没有 root 占用的路径（否则你的网关会 EACCES）

> ⚠️ **没做 §2.1 的 SSO 登录时，verify 会亮 1 项**（"极库云 SSO 未就绪：落库/建文档会失败"）——这是**有意的**，别当误报。
> （实测：SSO 未就绪时会亮 1 项；本人配好身份后 0 问题。）

再在推推里**私聊你自己的机器人**发一句「你好」，有回复即全通。

## 5. 装完不工作？先看这 5 条

| 现象 | 怎么办 |
|---|---|
| 机器人不回话，日志 `No messaging platforms enabled` | 插件没装上 → 重跑第 ① 条 |
| 通道不通 / 推推接口超时 | appid 填成昵称了 → 重跑第 ② 条（会自动纠正）|
| `Permission denied: '~/.local/state/hermes'` | 家目录里有 root 建的目录 → 跑 `verify.sh` 看提示 |
| **建链静默退出、退出码 2、无报错** | 缺 helper（`hermes_operator.py`）→ `sudo bash /opt/hermes-team/kanban-kit.sh render` |
| `ai4se: command not found` / `Permission denied` | 共享副本没就位 → `verify.sh` 会查这项 |

更多症状按分类查 → 《使用指南》§3。

## 6. 真出问题了，贴这三样

```bash
systemctl --user status hermes-gateway --no-pager | head -20
journalctl --user -u hermes-gateway -n 80 --no-pager | tail -40
bash /opt/hermes-team/verify.sh
```

## 7. 想清空重来

```bash
sudo bash /opt/hermes-team/teardown.sh     # 只归档、不硬删（归档目录会告诉你），然后从第 ① 条重走
```

⚠️ **重装必须补 render**：`teardown.sh` 归档的是**整个** `~/.hermes`（含 `~/.hermes/scripts/` 的 helper）和 `~/hermes`（含 `~/hermes/kanban/bin` 的流程脚本）。而 `onboard.sh → setup-me.sh → kanban-onboard.sh` 里只有 **kanban-onboard 收尾**会自动 render：

- 只跑到 `setup-me.sh` 就去建链 → **静默退出、退出码 2**（《使用指南》§3 第一条）。
- 兜底一条命令：`sudo bash /opt/hermes-team/kanban-kit.sh render`。
- 重装后**基线技能也会回来**（第 ① 步自动铺）；缺就用 `baseline-skills.sh sync`。

---

**下一步**：装完先看《使用指南》§1（日常怎么用）；出问题先看《使用指南》§3（按症状查）。
