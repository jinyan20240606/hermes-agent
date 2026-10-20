# 04 · 系统提示构建与 Prompt Caching

> **读法**：这一篇讲的是全仓库**第一条铁律**。顺序是：
> **§0 前置**（什么是 prompt caching，为什么它值钱）→ **§1 一个核心分离**（缓存态 vs 临时态）
> → **§2 三层结构**（stable / context / volatile，真实代码逐段）→ **§3 稳定性校验**
> → **§4 缓存策略（4 个断点）** → **§5 「不重建又要更新」的四个范式** → **§6 铁律清单**
> → **§7 陷阱** → **§8 自检**。
>
> 读完你应该能回答：**「我想让 agent 在会话中途知道一件新事，有几种做法？哪种会烧掉用户的缓存？」**

**本篇相对旧版新增**：§0 缓存的经济学、§2.1 `build_system_prompt_parts` 逐段解剖、
§2.3 worktree 排序的完整推理、§3 `_stored_prompt_matches_runtime` 的逐字段判定、
§4.3 `register_stable_prefix` 的 builder 声明机制、§5 四个范式的对照表、§7 六个陷阱。

---

## 0. 前置概念

### 0.1 为什么这是一个「钱」的问题

[`01-architecture-overview.md`](01-architecture-overview.md) §0.1 说过：LLM API **无状态**，
每次都要把整段历史重传。

一个 200K token 的会话，第 100 轮请求要重传：

```text
system prompt      ≈  8K token
历史消息           ≈ 180K token
工具 schema        ≈  6K token
─────────────────────────────
本次输入           ≈ 194K token
```

假设输入价 \$3/M token：**每轮 \$0.58**。如果每轮都全价，一个长会话能烧掉几十美元。

**Prompt caching 就是把这 194K 里的「前缀」缓存起来，命中部分按 1/10 甚至 1/20 计价。**

### 0.2 缓存的匹配规则：前缀，字节级

三家主流实现（Anthropic / OpenAI / Gemini）的语义高度一致：

```text
请求 A:  [system][user1][asst1][user2]
请求 B:  [system][user1][asst1][user2][asst2][user3]
                ↑_______________↑
                这一段完全相同 → 命中缓存

请求 C:  [system'][user1][asst1][user2]
          ↑ 只改了一个字
                 ↓
        从 system' 那里就断掉了 → 全部重算
```

**两条硬规则**：

1. **匹配是前缀式的**（不是「找出所有公共片段」）
2. **匹配是字节级的**（不是语义级的，甚至不是 token 级的）

所以：

| 改动 | 后果 |
|---|---|
| 在 system prompt 中间加一句 | 从那一句起全部失效 |
| 在 system prompt **末尾**加一句 | 前面的前缀**仍然有效**，只有末尾那段重算 |
| 把 `Platform: cli` 改成 `Platform: tui` | 从那一行起全部失效（如果它在中间） |
| 时间戳精确到秒 | **每轮都失效** |

**这就是本仓库所有设计决策的物理来源。**

### 0.3 「缓存命中率」是本仓库的观测指标

代码里真的在记录（[`hermes_cli/observability/shared_metrics_efficiency.py`](../hermes_cli/observability/shared_metrics_efficiency.py:1)）：

```python
from hermes_cli.observability.shared_metrics_efficiency import record_cache_break, record_prompt_rebuild
```

`record_cache_break(agent, reason)` 里的 reason 是**枚举**，每个值对应一类破坏原因：

| reason | 触发场景 |
|---|---|
| `"toolset_change"` | 中途切换工具集 |
| `"compression"` | 压缩（**唯一合法**） |
| … | 见 §7 |

**「缓存破坏」被当作一个可度量的事件**，而不是「大概变慢了」。这是把性能约束变成工程约束的关键一步。

---

## 1. 一个核心分离：缓存态 vs 临时态

[`website/docs/developer-guide/prompt-assembly.md`](../website/docs/developer-guide/prompt-assembly.md:9) 的定义：

| | 缓存态（cached） | 临时态（ephemeral） |
|---|---|---|
| 何时构建 | **一次会话构建一次** | **每次 API 调用** |
| 生命周期 | 跨 turn 复用，压缩时才重建 | 单次请求 |
| 内容 | system prompt 三层 | 预算告警、上下文压力提示、per-turn note |
| 代价 | 变更 = 缓存全废 | 变更 = 免费（本来就不在缓存里） |

**这个分离决定了一切**：token 用量、缓存命中率、会话连续性、记忆正确性。

前端类比：这就像 React 的 `useMemo` vs 每次渲染都算的值。区别是这里的「渲染」要花钱。

三个主文件：

| 文件 | 职责 |
|---|---|
| [`agent/system_prompt.py`](../agent/system_prompt.py:1) | 三层组装 |
| [`agent/prompt_builder.py`](../agent/prompt_builder.py:1) | 各段的具体渲染 + context files |
| [`agent/prompt_caching.py`](../agent/prompt_caching.py:1) | 缓存断点标记（纯函数，无 AIAgent 依赖） |

注意 `prompt_caching.py` 的 docstring 第一句：**`Anthropic prompt caching strategy — pure functions, no AIAgent dependency.`**

**纯函数是刻意的**：它要能被三处调用（主循环、压缩、子代理），不能反过来依赖 agent。

---

## 2. 三层结构

### 2.1 docstring 与真实代码的差异（先看官方定义）

[`agent/system_prompt.py`](../agent/system_prompt.py:1)：

```python
"""System-prompt assembly for :class:`AIAgent`.

Built once per session and reused across turns (only context compression
triggers a rebuild) so the upstream prefix cache stays warm.  Three tiers are
joined with ``\\n\\n``: ``stable`` (identity, guidance, env hints, coding brief,
platform hints), ``context`` (workspace snapshot, caller ``system_message``,
context files) and ``volatile`` (skills index, memory, USER.md, external memory
provider, timestamp line).  See ``references/system-prompt-invariant.md``.
"""
```

### 2.2 `build_system_prompt_parts` 逐段解剖

[`agent/system_prompt.py`](../agent/system_prompt.py:734) 是真正的组装点。按代码顺序：

```python
def build_system_prompt_parts(agent, system_message=None) -> dict[str, str]:
    # Model context window scales the context-file caps; stable per conversation.
    _cc_len = getattr(getattr(agent, "context_compressor", None), "context_length", None)
    _ctx_len = _cc_len if isinstance(_cc_len, int) and _cc_len > 0 else None
```

**第一行就有信息**：context file 的上限由 **context window 动态决定**（大窗口模型可以塞更多项目文档）。

#### stable 层

```python
    stable_parts, _soul_loaded = _identity_parts(agent, _ctx_len)
```

[`_identity_parts`](../agent/system_prompt.py:544)：

```python
wants_soul = agent.load_soul_identity or not agent.skip_context_files
_soul_content = _pb.load_soul_md(ctx_len, home_override=_agent_home(agent)) if wants_soul else None
return ([_soul_content], True) if _soul_content else ([DEFAULT_AGENT_IDENTITY], False)
```

**`SOUL.md`（人格文件）或硬编码默认身份**。`skip_context_files=True` 时（子代理、cron）
用默认身份 —— 详见 §2.4。

```python
    _help_guidance_slot = len(stable_parts)
    stable_parts.append(HERMES_AGENT_HELP_GUIDANCE_NO_SKILLS)
    stable_parts.extend(_guidance_parts(agent))

    skills_prompt = _skills_prompt(agent)
    if "skill_view" in (agent.valid_tool_names or set()) and "- hermes-agent:" in skills_prompt:
        stable_parts[_help_guidance_slot] = HERMES_AGENT_HELP_GUIDANCE
```

**这段「占位 → 事后回填」的技巧很值得学**。原因写在注释里：

```python
# The skill_view() pointer dangles without skill tools OR without the
# hermes-agent skill installed, so the variant is chosen after the skills
# index is built; this slot holds its position.
```

问题：指引文本要引用 `skill_view` 工具和 `hermes-agent` 技能，但那段文本在 skills 索引**之前**。
解法：**先放占位符，记住索引位置，等索引建好再回填**。

为什么不用「先建索引再放指引」？因为**位置是承诺**（§2.3 会讲为什么顺序不能乱），
临时改变顺序会导致前缀不稳定。

```python
    stable_parts.extend(_alibaba_identity_part(agent))
    # Pinned skills are per-agent constants (resolved once), so they live in the stable prefix.
    stable_parts.extend(_auto_load_parts(agent))

    environment_hints = _pb.build_environment_hints()
    coding_prefix_parts, coding_workspace_parts, coding_trailing_parts = _coding_parts(agent)
    stable_parts.extend(coding_prefix_parts)
    post_workspace_parts = _post_workspace_parts(agent)
```

**注意 `coding_parts` 被拆成三段**：`prefix` / `workspace` / `trailing`。
这不是为了可读性，是为了 §2.3 的排序技巧 —— `workspace` 段必须先让位于 context 文件。

#### context 层

```python
    context_parts: list[str] = []
    # ephemeral_system_prompt is injected at API-call time only, never cached.
    if system_message is not None:
        context_parts.append(system_message)
    context_parts.extend(_context_files_part(agent, _ctx_len, _soul_loaded))
    if coding_workspace_parts:
        context_parts.extend([*coding_workspace_parts, *coding_trailing_parts, *post_workspace_parts])
    else:
        # Preserve the stable placement for non-workspace sessions; there is no
        # worktree snapshot whose later position would improve their prefix.
        stable_parts.extend([*coding_trailing_parts, *post_workspace_parts])
```

`if/else` 的两个分支都在**同一层**做完，但落到不同 tier。注释解释了：

**有 workspace 快照** → workspace 相关片段进 context（排在项目文件之后）
**无 workspace 快照** → 留在 stable（因为提前没有好处）

#### volatile 层

```python
    # Skills are runtime-mutable, so the index leads the volatile band: on a longest-prefix
    # backend an unchanged index stays inside the reused prefix; a changed one re-prefills from here.
    volatile_parts: list[str] = [skills_prompt, *_memory_parts(agent)]

    # Plugin sections are confined to one coarse anchor in the volatile tail so
    # a resumed process can reconstruct the stable prefix without re-running plugins.
    volatile_parts.extend(_plugin_section_blocks(_frozen_plugin_prompt_sections(agent), "after_memory"))

    # The profile line names this home's path, so it rides in the volatile tier: the stable
    # prefix then stays byte-identical across every profile (and home) on the host.
    volatile_parts.append(_active_profile_line(agent))
    volatile_parts.append(_timestamp_line(agent))

    if environment_hints:
        environment_hints = environment_hints.replace(
            _pb.RUNTIME_ENVIRONMENT_HEADING, "> " + _pb.RUNTIME_ENVIRONMENT_HEADING)
        volatile_parts.append(
            f"{_pb.RUNTIME_ENVIRONMENT_HEADING}\n\n{environment_hints}\n\n{_pb.RUNTIME_ENVIRONMENT_END}")
```

四条关键注释，每条都是「为什么这个块在这里」：

| 块 | 为什么在 volatile 的**这个位置** |
|---|---|
| skills 索引 | 「runtime-mutable，所以打头」→ 不变的索引能留在复用前缀里；变了只从这重算 |
| plugin sections | 「confine to one coarse anchor」→ 恢复进程能重建 stable 前缀而不用重跑插件 |
| profile 行 | 「names this home's path」→ 放在 volatile，stable 才能跨 profile 字节一致 |
| runtime environment | 「keep after all user/plugin prose」→ 引用的 host 示例不能遮蔽真正的锚 |

#### 返回

```python
    return {"stable": _join_tier(stable_parts),
            "context": _join_tier(context_parts),
            "volatile": _join_tier(volatile_parts)}
```

`_join_tier`：

```python
def _join_tier(parts):
    """Join non-empty parts; None/blank entries are dropped."""
    return "\n\n".join(p.strip() for p in parts if p and p.strip())
```

`p.strip()` —— **每个块首尾空白被去掉**。这保证了「块内容不变 → 输出字节不变」，
不受上游渲染函数的偶然换行影响。

### 2.3 顺序为什么是 stable → context → volatile

三层拼接（[`build_system_prompt`](../agent/system_prompt.py:800)）：

```python
return "\n\n".join(p for p in (parts["stable"], parts["context"], parts["volatile"]) if p)
```

**为什么 volatile 必须最后？**

因为 volatile 是「最可能在重建时变化」的部分。缓存是**最长公共前缀**：

```text
build 1:  [stable 8K][context 4K][volatile 2K]
build 2:  [stable 8K][context 4K][volatile 2K']   ← volatile 变了
                                  ↑
                        前 12K 仍然命中
```

如果 volatile 放最前：

```text
build 1:  [volatile 2K][stable 8K][context 4K]
build 2:  [volatile 2K'][stable 8K][context 4K]
          ↑
      第一字节就变了 → 14K 全部重算
```

**这就是「stable → context → volatile」的物理意义：把最稳定的放在最前面。**

#### worktree 排序技巧

[`build_system_prompt_parts`](../agent/system_prompt.py:734) 的 docstring：

> Worktree-dependent blocks follow project context so a shared context file can remain in the
> longest common prefix across worktrees.

具体场景：同一个仓库的两个 git worktree（`feature-a/` 和 `feature-b/`）。

| 顺序方案 | worktree A 的前缀 | worktree B 的前缀 | 公共前缀 |
|---|---|---|---|
| 项目文件前、cwd 后 | `[AGENTS.md][cwd=/a]` | `[AGENTS.md][cwd=/b]` | 只有 `AGENTS.md` |
| **cwd 后**（本仓库） | `[AGENTS.md]` | `[AGENTS.md]` | **整个 context block** |

python 代码里的体现就是 `coding_workspace_parts` 被推后到 context 层（`_context_files_part` 之后）。

### 2.4 `skip_context_files` 的语义

```python
def _context_files_part(agent, _ctx_len, soul_loaded):
    if agent.skip_context_files:
        return []
```

设置后：

| 影响 | 说明 |
|---|---|
| 不加载 `SOUL.md` | 改用 `DEFAULT_AGENT_IDENTITY` |
| 不加载项目 `AGENTS.md` / `CLAUDE.md` / `.cursorrules` | — |
| 不加载子目录提示 | — |

谁用？**子代理委派**（[`13-subagents-delegation.md`](13-subagents-delegation.md)）、**cron**
（[`12-cron-and-kanban.md`](12-cron-and-kanban.md)）。

为什么？**子代理不该继承父代理的项目上下文** —— 它是被派去干一件具体事的，
继承上下文既浪费 token 又可能误导（父代理在 `/repo-x`，子代理的任务是查 `~/.hermes/logs`）。

cron 的 `_identity_parts` 注释说明了更细的取舍：

```python
"""SOUL.md (primary identity; cron keeps the persona while skipping cwd
instructions, scoped to the agent's OWN home) or the default identity."""
```

**cron 保留人格（SOUL.md），但跳过 cwd 指令** —— 因为「你是谁」跨任务是稳定的，
「你在哪个项目」不是。这靠 `agent.load_soul_identity` 这个独立开关实现。

### 2.5 三层内容全表

| Tier | 块 | 变率 | 谁会影响它 |
|---|---|---|---|
| **stable** | identity（SOUL.md / DEFAULT） | 几乎不变 | 用户编辑 SOUL.md（需新会话） |
| | `TASK_COMPLETION_GUIDANCE` | 不变 | 配置 `_task_completion_guidance` |
| | `PARALLEL_TOOL_CALL_GUIDANCE` | 不变 | 配置 `_parallel_tool_call_guidance` |
| | tool guidance block | 会话内不变 | `valid_tool_names` |
| | `STEER_CHANNEL_NOTE` | 不变 | 有工具时才有 |
| | `TOOL_USE_ENFORCEMENT_GUIDANCE` | 不变 | 模型门控（GPT/Codex 系） |
| | `GOOGLE_MODEL_OPERATIONAL_GUIDANCE` | 不变 | gemini/gemma 模型 |
| | `execution_guidance_text(...)` | 不变 | 模型门控 |
| | `ASYNC_HANDOFF_GUIDANCE` | 不变 | 有 `delegate_task` 时 |
| | `HERMES_AGENT_HELP_GUIDANCE(_NO_SKILLS)` | 不变 | 占位回填（§2.2） |
| | alibaba identity part | 不变 | 阿里路由 |
| | pinned skills（`_auto_load_parts`） | 不变 | `--skills` |
| | coding prefix | 不变 | — |
| | platform hints | 不变 | `platform_hints.<p>` 配置 |
| **context** | caller `system_message` | 每 turn 可能变 | 调用方 |
| | context files（`AGENTS.md` 等） | 会话内不变 | CWD 内容 |
| | coding workspace 段 | 会话内不变 | worktree / cwd |
| **volatile** | `<available_skills>` 索引 | **运行时可突变** | 装/删技能 |
| | `MEMORY.md` 快照 | **冻结**（见 §5） | 压缩边界 |
| | `USER.md` 快照 | **冻结** | 压缩边界 |
| | external memory provider block | 冻结 | 压缩边界 |
| | plugin sections | 冻结（fail-open） | 压缩边界 |
| | profile 行 | 不变 | profile |
| | timestamp 行 | **只到「天」** | 见 §3.2 |
| | runtime environment | 会话内不变 | cwd / 后端 |

### 2.6 「Frozen」二字的含义

`MEMORY.md` / `USER.md` 快照在会话期间**冻结** —— 不随记忆写入而中途变化。

[`invalidate_system_prompt`](../agent/system_prompt.py:812) 是**唯一**解冻点：

```python
def invalidate_system_prompt(agent) -> None:
    """Force a rebuild on the next turn (after compression): reload memory from
    disk and clear the frozen plugin snapshot ..."""
    agent._cached_system_prompt = None
    agent._cached_system_prompt_static = None
    if hasattr(agent, "_plugin_system_prompt_sections_snapshot"):
        agent._plugin_system_prompt_sections_previous = agent._plugin_system_prompt_sections_snapshot
        del agent._plugin_system_prompt_sections_snapshot
    if agent._memory_store:
        agent._memory_store.load_from_disk()
```

三个动作，各有理由：

| 动作 | 为什么 |
|---|---|
| 清 `_cached_system_prompt` | 下次 turn 重建 |
| 清 `_cached_system_prompt_static` | 静态前缀也变了（断点位置要重算） |
| **`_plugin_system_prompt_sections_previous` = 旧快照** | **fail-open**：插件渲染抛异常时回退到上次好字节，而不是消失 |
| `load_from_disk()` | 让本次会话写入的记忆在重建时被捕获 |

plugin 那句注释值得完整读一遍：

```python
"""... clears the frozen plugin-section snapshot so plugins re-render at the
same boundary (maintainer-directed, #95681 arc): a plugin section is just another prompt block carrying
state — freezing it while memory, skills, and guidance refresh would recreate the stale-block disease
inside plugin-land. The previous bytes are stashed so a plugin whose render RAISES falls back to its
last good section instead of vanishing (fail-open guard, not a freeze).
"""
```

**「stale-block disease」** —— 只解冻一部分、冻结另一部分，就产生了「有的块新、有的块旧」的病。
所以插件的处理是「**在同一个边界全量重渲染 + 失败回退旧字节**」，而不是「永久冻结」。

**「fail-open guard, not a freeze」** 这六个字是本仓库的通用态度：
**降级要好于消失**。

---

## 3. 稳定性校验

构建一次之后，prompt 会被**持久化进 SessionDB**。下一个 turn 恢复时要判断：
**还能不能直接用存的字节？**

### 3.1 `_restore_or_build_system_prompt`

[`agent/conversation_loop.py`](../agent/conversation_loop.py:741)：

```python
def _restore_or_build_system_prompt(agent, system_message, conversation_history):
    """Restore the cached system prompt from the session DB or build it fresh.

    Mutates ``agent._cached_system_prompt`` and persists a freshly-built prompt on first
    build. Row states ``missing``/``null``/``empty``/``present`` are logged and DB
    failures log at WARNING so silent prefix-cache misses show in ``agent.log``."""
```

**「silent prefix-cache misses show in agent.log」** —— 缓存未命中是**静默**的
（不会报错，只是账单变贵），所以要让它可见。

流程：

```python
stored_prompt = None
stored_state = "missing"
if conversation_history and agent._session_db:
    try:
        session_row = agent._session_db.get_session(agent.session_id)
        if session_row is not None:
            raw_prompt = session_row.get("system_prompt")
            stored_state = "null" if raw_prompt is None else ("empty" if raw_prompt == "" else "present")
            stored_prompt = raw_prompt or None
    except Exception as exc:
        logger.warning(
            "Session DB get_session failed for system-prompt restore (session=%s): %s. "
            "Falling back to fresh build — prefix cache will miss for this turn.",
            agent.session_id, exc,
        )

if stored_prompt and _stored_prompt_matches_runtime(agent, stored_prompt):
    ...  # 复用
```

四种行状态被分开记录：`missing` / `null` / `empty` / `present`。
**为什么区分 `null` 和 `empty`？** 因为它们是不同的历史 bug 留下的痕迹，
分开统计才能定位是哪一代代码写的。

### 3.2 `_stored_prompt_matches_runtime` 逐字段

[`agent/conversation_loop.py`](../agent/conversation_loop.py:883)：

```python
def _stored_prompt_matches_runtime(agent, prompt: str) -> bool:
    """Return False when the persisted runtime-identity lines are stale."""
    # Model/provider identity, then cwd drift.
    for label, attr in (("Model", "model"), ("Provider", "provider")):
        stored = identity_line_value(prompt, label)
        current = str(getattr(agent, attr, "") or "").strip()
        if stored and stored != current:
            return False

    stored_sid = identity_line_value(prompt, "Session ID")
    if stored_sid and getattr(agent, "pass_session_id", False) and stored_sid != agent.session_id:
        return False

    # Compare against resolve_agent_cwd() — the SAME resolver used to build the
    # prompt — so TERMINAL_CWD sessions are not falsely rejected.
    stored_cwd = runtime_host_value(prompt, "Current working directory")
    if stored_cwd and stored_cwd != str(resolve_agent_cwd()):
        return False

    # Platform is deliberately NOT an identity field ...
    return True
```

**四条判定，第三条最关键。**

`Model` / `Provider` 变了 → 重建。因为换模型后「针对某个模型的操作指引」也该换。

`Session ID` 变了 → 重建。注释解释了场景：

```python
# A prompt stamped for another session (a /branch child copies its parent's bytes) must not
# tell the model a foreign Session ID.  Checked only when the trailer is on: with it off, a
# "Session ID:" line in project text would read as a mismatch and rebuild every turn.
```

`/branch` 会**复制父会话的字节**。如果不检查，子会话的 prompt 里写着父会话的 ID。

第二个从句同样重要：**只在 trailer 开启时才检查**。否则项目文本里恰好有一行
`Session ID: xxx` 就会被误判为不匹配 → **每轮都重建**（灾难）。

`cwd` 变了 → 重建。但注意用的是**同一个 resolver**：

```python
# Compare against resolve_agent_cwd() — the SAME resolver used to build the
# prompt — so TERMINAL_CWD sessions are not falsely rejected.
```

**「用同一个解析器」是这类比对的通用原则。** 如果构建用 `resolve_context_cwd()`、
校验用 `resolve_agent_cwd()`，两者在 `TERMINAL_CWD` 场景下会给出不同值 → 每轮误判重建。

`Platform` **不**参与判定：

```python
# Platform is deliberately NOT an identity field: a surface switch does not invalidate the
# stored bytes, it only makes their interface section out of date, and that is corrected by
# agent.surface_switch.stage_surface_switch_note without touching the cached prefix (#104414).
```

**这是 §5 的第一个范式**，下面详说。

### 3.3 timestamp 行：只到「天」

[`_timestamp_line`](../agent/system_prompt.py:489)：

```python
def _timestamp_line(agent) -> str:
    """Date-only so the prompt is byte-stable for the day; zone + offset so
    tools needn't guess EST vs EDT. Long-lived sessions get an "as of" line on
    rebuild days (the cache prefix is already invalidated at that boundary)."""
```

**为什么只到天？** 如果精确到分钟，**每一轮 prompt 都不同** → 缓存永远不命中。

**为什么要给时区+偏移？** 注释：`so tools needn't guess EST vs EDT`。
模型需要知道「现在几点」，但也需要知道「是哪个时区」，否则算时间是错的。

**长会话的「as of」行**，注释是一段完整的设计论证：

```python
# Second line (maintainer design, salvaging #96224's anchor): long-lived sessions — Bot Mode
# forever-chats, messenger channels people never close — span many days and many compactions. A lone
# birth date leads the model to believe it is still living in that old day. The prompt is rebuilt at
# every compaction boundary, so stamp the rebuild day too: 'started' stays anchored and byte-stable, 'as
# of' refreshes exactly when the cache prefix is already being invalidated (compaction), so the added
# line costs no extra cache churn. Same-day sessions skip the second line entirely — nothing to correct,
# and the single-line shape stays byte-identical for the day (prefix-cache safe).
```

拆成四个决策：

| 决策 | 理由 |
|---|---|
| 加第二行 | 只有「started」会让模型以为自己还活在那一天 |
| 只在**跨天**时加 | 同一天没事要纠正，单行才能保持字节一致 |
| 在**重建边界**刷新 | 那时缓存已经被压缩破坏了，「顺手更新」不要额外代价 |
| 措辞「as of the last context rebuild」+「trust this over the start date」 | 明确优先级，避免模型在两行里摇摆 |

**这是「把可变信息挂在本来就不可变的边界上」的教科书案例。**

`_bot_chat_timeless_prompt` 还有一个特例：

```python
if getattr(agent, "_bot_chat_timeless_prompt", False):
    timestamp_line = f"Timezone: {', '.join(_bits)}" if _bits else ""
```

Bot Mode 的「永恒聊天」**连日期都不给**。因为给一个日期只会让它随着时间变得陈旧。

### 3.4 trailer 行

```python
trailer = (("Session ID", agent.session_id if agent.pass_session_id else None),
           ("Model", agent.model),
           ("Provider", agent.provider),
           ("Platform", agent.platform))
return timestamp_line + "".join(f"\n{label}: {value}" for label, value in trailer if value)
```

四个标签，`Session ID` 是可选的（`pass_session_id`）。
**空值被跳过** —— 这也是 §3.2 里「builder omits an empty trailer line」的来源。

---

## 4. 缓存策略：4 个断点

### 4.1 Anthropic 的 `cache_control`

Anthropic 的缓存是**显式标记**式的：你在请求里给消息块加 `cache_control`，
最多 4 个断点。

[`agent/prompt_caching.py`](../agent/prompt_caching.py:1)：

```python
"""Anthropic prompt caching strategy — pure functions, no AIAgent dependency.

Default layout: 4 cache_control breakpoints — the static system prefix, the end of the
system prompt, and the last 2 non-system messages (without a static prefix: one system
breakpoint plus the last 3 messages). All markers share one TTL (5m or 1h).
"""
```

两个布局：

```text
有 static_system_prefix:
  [static prefix ┃][……system 剩余……┃][非system 倒数第2 ┃][非system 最后1 ┃]
      断点1              断点2              断点3            断点4

无 static_system_prefix:
  [……system prompt……┃][倒数第3 ┃][倒数第2 ┃][最后1 ┃]
        断点1            断点2      断点3     断点4
```

**「最后 2 条非 system 消息」** —— 因为对话在增长，最新的消息最可能被下次请求用到。
这是一个**滚动窗口**：断点随对话往前推。

`static_system_prefix` 就是 [`build_system_prompt`](../agent/system_prompt.py:800) 里存的：

```python
agent._cached_system_prompt_static = parts["stable"]
```

**stable 层单独存一份**，因为断点1 要精确落在 stable/context 的边界上。

### 4.2 `apply_anthropic_cache_control` 的幂等性

```python
def apply_anthropic_cache_control(api_messages, cache_ttl="5m", native_anthropic=False,
                                  static_system_prefix=None, tool_part_markers=True):
    """... Idempotent: prior decoration is stripped from a per-message copy first, so a second
    call (or messages a prior call already planned) can never accumulate past 4 markers (#90971).
    Returns a shallow list copy with deep copies of modified messages."""
    messages = _strip_prior_decoration(list(api_messages))
```

**两件事必须同时成立**：

1. **先剥掉已有标记**（`_strip_prior_decoration`）—— 否则重复调用会累积超过 4 个 → 400
2. **深拷贝被改的消息** —— 否则会污染 `agent.messages` 里持久化的那一份

第 2 点很关键：

```python
messages[0] = copy.deepcopy(messages[0])
```

**持久化的消息不带 `cache_control`**，标记只在请求的副本上。否则：
- 存进 DB 的是「带 Anthropic 私有字段的消息」
- 切到 OpenAI 时那些字段会被当垃圾
- 长度计算/压缩会被污染

### 4.3 builder 声明的稳定前缀（`register_stable_prefix`）

这是本仓库一个精妙的机制。[`agent/prompt_cache_boundary.py`](../agent/prompt_cache_boundary.py:1)：

```python
"""Builder-declared stable prefixes for Anthropic prompt caching.

Skill/webhook/cron builders concatenate a large static scaffold with a small volatile
tail into one user-message string. Only the builder knows where the tail begins, so it
registers the stable prefix here and the cache planner places a breakpoint at that
boundary. Re-parsing marker strings at request time is deliberately avoided: markers
can legitimately appear inside skill bodies, and any delimiter heuristic then shrinks
the cached prefix or absorbs volatile bytes. Process-local by design: any miss falls
back to the whole-message policy.
"""
```

**问题**：skill slash 命令会拼出一个巨大的 user 消息：

```text
[8000 字的 skill 正文][50 字的「用户刚才问的是…」]
      ↑ 稳定，可缓存         ↑ 每轮不同
```

如果整条消息算一个块，那么「每轮不同」的尾巴会让**整条消息**都无法命中。

**解法**：builder 在拼接时就把「稳定前缀」登记进去：

```python
register_stable_prefix(prefix)
```

请求时，`find_stable_prefix(content)` 找出最长匹配的已登记前缀，把它切成
`[scaffold, tail]` 两个 text part，标记打在 scaffold 上。

**为什么不靠分隔符猜？** docstring 直说了：

> markers can legitimately appear inside skill bodies, and any delimiter heuristic then
> shrinks the cached prefix or absorbs volatile bytes.

**skill 正文里可能就含有你用来当分隔符的字符串。** 任何启发式都会出错 ——
所以让**唯一知道边界的人**（builder）来声明。

存储上也有细节：

```python
_MAX_ENTRIES = 32
_MAX_CHARS = 4 * 1024 * 1024

while len(_prefixes) > _MAX_ENTRIES:
    _prefixes.popitem(last=False)
while len(_prefixes) > 1 and sum(map(len, _prefixes)) > _MAX_CHARS:
    _prefixes.popitem(last=False)
```

**两个上限**（条目数 + 总字符数），因为「一个条目可能是一整篇 skill 正文」。
而 `> 1` 保证**最新那条永不淘汰**（否则刚登记的立刻被赶走 = 白登记）。

`find_stable_prefix` 还有个陷阱防护：

```python
"""Longest registered *proper* prefix of ``content`` with a non-whitespace tail.

The tail must be non-whitespace so the split never yields an empty text
block (Anthropic rejects it with HTTP 400). A hit refreshes the entry's LRU
position so a scaffold fired every minute by cron is not evicted by a
burst of one-off skill invocations.
"""
```

**「tail 不能是空白」** —— 否则会切出一个空 text block，Anthropic 直接 400。

**「命中要刷新 LRU」** —— cron 每分钟发同一条 scaffold，一次性的 skill 调用不该把它挤掉。

### 4.4 `_split_unmarked_scaffolds`：一个更隐蔽的坑

[`agent/prompt_caching.py`](../agent/prompt_caching.py:73)：

```python
def _split_unmarked_scaffolds(messages):
    """Send every registered scaffold message as [scaffold, tail] parts, marked or not (in place).

    Provider caches key on content, and two text parts are different content from one string:
    a skill message split while it held a breakpoint must keep the same parts after the rolling
    marker window moves past it, or the next request re-writes the whole scaffold (#81867).
    Each hit refreshes the scaffold's registry LRU slot, so a scaffold still in history stays
    registered and the failover stripper can still recognise its split.
    """
```

问题：断点是**滚动的**。第 5 轮时，第 2 轮的那条 skill 消息已经不在「最后 2 条」里了，
所以不再被标记。**但它的形状不能变回去！**

因为：

```text
轮 N:   content = [part1(scaffold), part2(tail)]    ← 两个 part
轮 N+1: content = "scaffold+tail" (一个字符串)      ← 形状变了
```

**「两个 text part」和「一个字符串」在 provider 看来是不同的内容** —— 即使文本完全一样。
形状一变，缓存就断。

所以规则是：**一旦某条消息被切分过，就永远保持切分形状**，无论当前是否带标记。

### 4.5 TTL 的限制

```python
def effective_cache_ttl(ttl, *, model="", provider="") -> str:
    """Clamp a requested cache TTL to what the destination route supports (``None`` → ``5m``).

    Qwen/Alibaba routes drop ``1h`` (→ ``5m``) except on ``MEASURED_1H_PROVIDERS`` minus
    ``NO_1H_TIER_MODELS``; that check runs BEFORE the generic Qwen clamp, which would swallow it.
    """
```

**「请求 1h 但路由只支持 5m」必须夹紧。** 否则：
- 要么请求被拒
- 要么被静默降级但你按 1h 的成本预期做规划

注意那句**「that check runs BEFORE the generic Qwen clamp, which would swallow it」**：
两个 clamp 的**顺序**决定了能否走后门。这类细节只能靠代码注释传承。

### 4.6 一个真实的 provider 陷阱

```python
def envelope_tool_part_cache_markers_supported(provider, base_url) -> bool:
    """Whether the envelope-layout route honors part-level markers on role:tool.

    OpenRouter/Nous Portal relocate a part-level ``cache_control`` onto the ``tool_result``
    block; LiteLLM-style proxies copy parts verbatim, so it lands at ``tool_result.content[0]``
    (non-retryable 400). There, role:tool carries no part markers and the budget reallocates.
    """
    from agent.agent_runtime_helpers import _is_litellm_route
    return not _is_litellm_route((provider or "").strip().lower(), base_url or "")
```

链路：

```text
你发:      {"role":"tool", "content":[{"type":"text","text":"...", "cache_control":{...}}]}
              ↓
OpenRouter:  把它搬进 tool_result block         → 合法
LiteLLM:     原样复制 parts                     → cache_control 落到 content[0]
              ↓
Anthropic:   不认这个位置的 cache_control       → HTTP 400（不可重试）
```

**「不可重试的 400」** 是最贵的一类 bug —— 重试也没用，只能改代码。

解法（[`_apply_cache_marker`](../agent/prompt_caching.py:39)）：

```python
if role == "tool" and not native_anthropic and not tool_part_markers:
    # LiteLLM-style envelope: a part marker → tool_result.content[0] → non-retryable 400.
    return
```

**在这条路由上，`role:tool` 不带 part 标记，预算重新分配到别处。**

还有一条更细的：

```python
if (role == "tool" and native_anthropic) or content is None or content == "":
    # Native role:tool: top-level marker, the adapter moves it inside tool_result. Empty
    # content: no part can carry it, and OpenRouter rejects a top-level marker on role:tool
    # (silent hang) and ignores it on empty assistant turns — skip those on the envelope.
    if not (role in ("tool", "assistant") and not native_anthropic):
        msg["cache_control"] = cache_marker
```

**`(silent hang)`** —— OpenRouter 对 `role:tool` 的顶层标记不是报错，是**挂住不返回**。
这是最难查的一类故障。

---

## 5. 「不重建又要更新」的四个范式

这是本篇最有实践价值的部分。**当你想让 agent 中途知道新信息，有四种合法做法。**

### 范式总表

| # | 范式 | 通道 | 生效时机 | 代表实现 |
|---|---|---|---|---|
| 1 | **一次性 note 走 user 消息** | 追加一条 user 行 | 下一个 turn | surface 切换、skills 索引差异 |
| 2 | **搭 tool 结果的车** | 追加到 tool 结果尾部 | 同一轮内 | 子目录 `AGENTS.md` 提示 |
| 3 | **挂到重建边界** | 改 prompt，等压缩 | 下次压缩 | memory / USER 快照、plugin sections |
| 4 | **声明稳定前缀** | 请求时切分 | 立即（请求级） | `register_stable_prefix` |

### 范式 1：一次性 note（surface 切换）

[`agent/surface_switch.py`](../agent/surface_switch.py:1) 的 docstring 是一段完整的事故复盘：

```python
"""Surface switch without a prompt rebuild (#104414).

A surface switch (desktop <-> TUI, a session resumed under a different host) changes only which
interface renders the reply, but the surface guidance and the ``Platform:`` trailer are embedded
in the persisted system prompt.  Rebuilding for it diverged the prompt within its first blocks,
so the ENTIRE request behind it re-prefilled — a 220K-token session came back at a 1% cache hit.
The stored bytes are therefore kept and the CURRENT surface's guidance is delivered on the
per-turn user-message channel instead: that lands after the cached prefix and is stamped into the
byte-stable ``api_content`` sidecar so later turns replay it unchanged.  The prompt itself
converges at the next rebuild boundary (compaction).
"""
```

**数字在这里：220K token 会话，缓存命中率掉到 1%。**

为什么？因为 surface guidance 和 `Platform:` trailer 在 prompt **中间**（stable 层的 platform hints
+ volatile 层的 trailer）。改它 = 从中间断掉 = 后面的 220K 全部重算。

解法三步：

1. **保留存储的字节**（不重建）
2. **当前 surface 的指引走 per-turn user 消息**
3. 写进 `api_content` sidecar，让后续 turn 原样重放

**「stamped into the byte-stable `api_content` sidecar so later turns replay it unchanged」**
这一句是关键：note 本身也必须**字节稳定**，否则它自己变成新的缓存破坏源。

为什么 note 能稳定？因为它只在那一个 turn 生成一次，然后作为历史消息被原样重发。

注释里还有一句关于 parse 的细节：

```python
_SURFACE_NAME_END = " — any earlier interface guidance"
# Closes the surface name in the note; platform names are free-form for plugin platforms, so the
# terminator (not ".") delimits the parse.
```

**不能用 `.` 当终结符** —— 插件平台的名字是自由文本，可能包含点。

以及一个性能保护：

```python
# Only the newest note matters, and the note is re-stamped on the switch turn, so a bounded tail
# scan is enough; without a bound every turn of a never-switched session walks the whole transcript.
_NOTE_SCAN_TAIL = 200
```

**只在末尾 200 条里扫** —— 否则一个从未切换过 surface 的长会话每轮都要遍历全文。

### 范式 1b：skills 索引差异

[`agent/skills_index_delta.py`](../agent/skills_index_delta.py:1)：

```python
"""Skills that change mid-conversation reach the model without a prompt rebuild.

The ``<available_skills>`` index lives in the system prompt, and a conversation keeps those bytes
for its whole life so the provider prefix cache stays warm (#104414). A skill installed, created or
removed after the prompt was built (hub install, ``skill_manage``, the curator, a plugin going
live, a change made by another process) therefore never reached the index the model routes on
until compaction rebuilt the prompt. Every turn compares the index the prompt carries with the
index the session would build now and delivers the difference on the per-turn user-message note
channel, behind the cached prefix (ported from cloudflare/cloudflare-os#267).
"""
```

**问题**：你在会话里装了一个新技能，但 system prompt 里的 `<available_skills>` 是旧的 →
模型不知道有这个技能 → 不会去用。

**解法**：每轮比对「prompt 里带着的索引」vs「现在会构建的索引」，差异走 note 通道。

两个设计约束：

```python
"""Each note states the FULL difference against the prompt, so the prompt plus the newest note is the
complete record of what the model was told. A fresh agent (the gateway builds one per turn) reads that record back
from the transcript once; a long-lived agent (CLI, TUI, Desktop) keeps it on itself. A note is sent
only when the difference changes.
"""
```

| 约束 | 为什么 |
|---|---|
| note 写**全量差异**（不是增量） | 「prompt + 最新 note」就是完整记录，不需要重放所有历史 note |
| 只在差异**变化**时发送 | 否则每轮都追加一条相同的 note，浪费 token |

第二条还顺带解决了「fresh agent vs long-lived agent」的差异：
网关每 turn 新建 agent（从 transcript 读回记录），CLI/TUI 是长命对象（自己存着）。
**全量差异 + 只在变化时发** 让两种模型都能工作。

`_NOTE_PREFIX` 的措辞也值得学：

```python
_NOTE_PREFIX = "[System: The skills available in this conversation changed after its system prompt was built."
_ADDED_HEAD = "Now available (load with skill_view(name) when relevant, like the skills listed in the system prompt):"
_REMOVED_HEAD = "No longer available:"
_ACCURATE_AGAIN = " The skills listed in the system prompt are accurate again; earlier skill-change notes are superseded."
```

三件事：
1. `[System: ...]` 前缀让模型知道这是系统消息（不是用户说的）
2. 明确说「system prompt 里那份已经过时了」
3. `_ACCURATE_AGAIN` 明确作废之前的 note（避免模型累积矛盾信息）

### 范式 2：搭 tool 结果的车

子目录 `AGENTS.md` 提示（[`agent/subdirectory_hints.py`](../agent/subdirectory_hints.py:1)）：
当工具访问了某个子目录，把该目录的 `AGENTS.md` 追加到**工具结果**尾部。

为什么可以这样做？因为 tool 结果本来就是每轮新内容，**不参与前缀缓存**。

限额：`_MAX_HINT_CHARS = 32_000`，**首尾截断**（保留开头和结尾）。
截断会记日志，但**不弹聊天提示**（否则每次读文件都刷屏）。

安全约束：**拒绝工作目录之外的路径** —— 防止 `~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md` 混入。

### 范式 3：挂到重建边界

memory / USER 快照、plugin sections：**存储时就冻结，只在压缩边界解冻**。

代价：本次会话写入的记忆，本轮不会立刻出现在 prompt 里。
收益：整个会话的 prompt 字节稳定。

**这是「延迟一致」的取舍，而且是有意的**：

| | 立刻可见 | 缓存 |
|---|---|---|
| 不冻结 | ✅ | ❌ 每次写记忆都废缓存 |
| 冻结 | ❌（下次压缩才见） | ✅ |

选冻结的理由：记忆写入通常不是「这一轮必须马上用到」的信息；
而缓存破坏是每轮都付费的。

例外：cron / 子代理用 `skip_memory=True` 直接不注入（连冻结都不需要）。

### 范式 4：声明稳定前缀

见 §4.3。这是**唯一**在「请求级」操作缓存布局而不改内容的方式。

### 四条判据：该选哪个范式？

```text
信息必须在这一轮就看到吗？
  ├─ 是 → 能搭 tool 结果吗？（范式 2）
  │        ├─ 是 → 用范式 2
  │        └─ 否 → 范式 1（user note）
  └─ 否 → 下次压缩看到可以吗？
           ├─ 可以 → 范式 3（冻结 + 边界解冻）
           └─ 不行且是「切分问题」→ 范式 4
```

**永远不要的第五种做法**：直接改 `agent._cached_system_prompt`。那会**静默**地用掉用户的预算。

---

## 6. 铁律清单（背下来）

[`agent/AGENTS.md`](../agent/AGENTS.md:57) 的原文。

### 禁止

| 禁止 | 具体含义 | 后果 |
|---|---|---|
| 改动过去上下文 | 唯一的例外是 compression | 从改动点起全部重算 |
| 中途切换 toolsets | 工具 schema 是**每次 API 调用都发送**的 | 工具区变了 → 前缀断 |
| 中途重载记忆 | MEMORY/USER 快照在会话内冻结 | 同上 |
| 中途重建 system prompt | 除非 compression 触发 | 全部重算 |

### 允许的注入通道

| 通道 | 代表 | 位置 |
|---|---|---|
| **user 消息** | skill slash 命令 | 追加在合法位置 |
| **tool 结果** | 子目录 `AGENTS.md` 提示 | 截断到 32K |
| **一次性 note（走 user 通道）** | surface 切换、skills 索引差异 | 字节稳定，可重放 |
| **脚本化前奏** | 内置 prompt 的预置工具调用 | 正常 assistant/tool 行 |

### 「toolset 中途切换」为什么是重罪

`get_tool_definitions()` 的结果**每次都放在请求的 `tools` 字段**（[`05-tools-system.md`](05-tools-system.md)）。

```text
请求 N:   messages=[...] + tools=[55 个 schema]
请求 N+1: messages=[...] + tools=[42 个 schema]   ← 中途切了 toolset
```

工具区在**请求结构的哪个位置**取决于 provider，但无论在哪，`tools` 变了就意味着
「这次请求的某个早期部分变了」。对 Anthropic 这种把 `tools` 放在最前的实现，
等于**全废**。

所以 slash 命令里任何「改系统提示状态」的操作**默认延迟到下一个会话**，
只有 `--now` 才立刻生效（[`02-entrypoints.md`](02-entrypoints.md) §3.4）。

---

## 7. 六个陷阱

| # | 陷阱 | 症状 | 正解 |
|---|---|---|---|
| 1 | 时间戳精确到秒/分 | 每轮缓存全 miss，账单暴涨 | 只到天（§3.3） |
| 2 | 中途重建 prompt 改个小地方 | 220K 会话命中率掉到 1% | 走 note 通道（§5 范式 1） |
| 3 | `role:tool` 加 part 级 cache_control | LiteLLM 路由 **400**；OpenRouter **静默挂起** | `envelope_tool_part_cache_markers_supported`（§4.6） |
| 4 | 切分过的 scaffold 变回字符串 | 缓存莫名不命中 | `_split_unmarked_scaffolds`（§4.4） |
| 5 | 在 project 文本里放 `Session ID: xxx` | trailer 关闭时每轮误判重建 | 只在 `pass_session_id` 时校验（§3.2） |
| 6 | 构建用 A resolver、校验用 B resolver | `TERMINAL_CWD` 场景每轮误判 | 用同一个 resolver（§3.2） |

第 2 条最值得展开：**「小改动导致大损失」的杠杆效应**。

```text
改一处 10 个字符的 platform hint
  ↓
stable 层中段变了
  ↓
从那里往后的 stable + context + volatile 全部重算
  ↓
再加上整个历史消息（它们的前缀也断了）
  ↓
220K token × 全价
```

**这就是为什么「延迟失效」是默认行为，而不是「立刻生效」。**

---

## 8. i18n（顺带记住）

[`agent/i18n.py`](../agent/i18n.py:1) + `i18n_layers.py` + `i18n_languages.py`：

`t(key)` 的解析顺序：

```text
plugin packs（后注册者胜）
  → user overlay <home>/locales/<lang>.yaml（profile 作用域）
    → bundled locales/<lang>.yaml
      → 同上但用 en
        → 裸 key
```

| 细节 | 说明 |
|---|---|
| 缓存 | 每个 `(home, lang)` 只缓存一份**合并后**的字典 |
| 失效 | `reset_language_cache()` 清空全部 |
| 谁调用 | 每个 pack 注册、`config set display.language` |

**「合并后缓存」而不是「每层缓存」**：因为查找要按顺序穿透，合并一次比每次查找都穿透快得多。

`display.language` 变更会清缓存 —— 因为缓存键里含 lang，理论上不需要，但**清空更安全**
（避免 home override 文件被外部改了却看不到）。

---

## 9. 自检题

1. 为什么 LLM 的缓存是「前缀 + 字节级」的？这对 prompt 结构意味着什么？（§0.2）
2. 为什么 volatile 层必须放在最后？如果放最前会怎样？（§2.3）
3. `build_system_prompt_parts` 里那个「占位 → 回填」技巧解决什么问题？（§2.2）
4. worktree 排序技巧的收益具体是什么？（§2.3）
5. `skip_context_files` 影响哪三样东西？谁在用？cron 为什么「保留 SOUL 但跳过 cwd」？（§2.4）
6. 「Frozen」指什么？唯一的解冻点在哪？解冻时为什么要 `stash previous`？（§2.6）
7. `_stored_prompt_matches_runtime` 校验哪四个字段？`Platform` 为什么被排除？（§3.2）
8. timestamp 为什么只到「天」？「as of」行只在什么时候出现？为什么那时加不额外收费？（§3.3）
9. 4 个 cache_control 断点分别落在哪？为什么「最后 2 条非 system 消息」而不是固定的？（§4.1）
10. `apply_anthropic_cache_control` 为什么必须深拷贝被改的消息？（§4.2）
11. `register_stable_prefix` 为什么不用分隔符启发式？（§4.3）
12. 为什么「切分过的 scaffold 不能变回字符串」？（§4.4）
13. LiteLLM 路由上给 `role:tool` 加 part 标记会发生什么？（§4.6）
14. surface 切换为什么不能重建 prompt？那个 220K 会话的命中率掉到多少？（§5）
15. skills 索引差异 note 为什么写「全量差异」而不是增量？（§5 范式 1b）
16. 要让 agent 中途知道一件新事，四种合法做法分别是什么？（§5 总表）
17. 为什么「中途切 toolset」是最重的一条禁令？（§6）

---

## 10. 本篇小结

一句话版本：

> **system prompt 一次会话只构建一次、三层排列（stable → context → volatile，最稳的在前），
> 存进 DB 后逐字节复用；一切「中途更新的需求」都走 user 消息 / tool 结果 / 重建边界 / 前缀声明
> 这四个通道，绝不动已缓存的字节。**

五张必须记住的表：

- **§0.2 改动位置 → 缓存后果**
- **§2.5 三层内容全表**
- **§4.1 4 个断点的两种布局**
- **§5 四个范式 + 判据流程**
- **§6 铁律清单**

三个最容易犯的错：

1. 加了一个「精确时间」信息到 prompt → 每轮 miss
2. 为了让某个状态立刻生效去重建 prompt → 用户的账单翻十倍
3. 以为「文本一样就命中」→ 忘了 part 形状也是内容

下一章 → [`05-tools-system.md`](05-tools-system.md)：工具如何自注册、被过滤、被分发。
