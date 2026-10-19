# 04 · 系统提示构建与 Prompt Caching

> 目标：理解「缓存神圣」这条铁律在代码里是怎么落地的，以及三层 system prompt 的边界。

---

## 1. 核心设计：缓存态 vs 临时态

Hermes 刻意分离两件事（[`prompt-assembly.md`](../website/docs/developer-guide/prompt-assembly.md:9)）：

- **可缓存的 system prompt 状态**（一次会话构建一次，跨 turn 复用）
- **API 调用时的临时附加层**（ephemeral，每轮可变）

这个分离决定了一切：token 用量、缓存命中率、会话连续性、记忆正确性。

主文件：
[`agent/system_prompt.py`](../agent/system_prompt.py:1)、
[`agent/prompt_builder.py`](../agent/prompt_builder.py:1)、
[`agent/prompt_caching.py`](../agent/prompt_caching.py:1)。

---

## 2. 三层结构（stable → context → volatile）

[`agent/system_prompt.py`](../agent/system_prompt.py:1) 的 docstring 说得很清楚：
**「每会话构建一次，跨 turn 复用（只有 context compression 会触发重建），以保持上游前缀缓存温热。」**

三层用 `\n\n` 拼接，最终顺序为 **stable → context → volatile**：

| Tier | 内容 |
|---|---|
| **stable** | identity（`SOUL.md` 或 fallback）、tool/model 指引、coding operating brief、platform hints |
| **context** | 调用方传入的 `system_message`、项目上下文文件（`.hermes.md` / `AGENTS.md` / `CLAUDE.md` / `.cursorrules`）、依赖 worktree 的 git workspace 快照、operator 指令、平台提示 |
| **volatile** | skills 索引、内置记忆快照（`MEMORY.md`）、用户画像快照（`USER.md`）、外部 memory provider block、timestamp/session/model/provider 行、运行时环境提示（host / home / **当前工作目录**） |

来源：[`prompt-assembly.md`](../website/docs/developer-guide/prompt-assembly.md:29)

### 2.1 顺序为什么重要（两个容易记错的点）

1. **skills 属于 stable 层**，而 **memory/profile 快照属于 volatile 层**
2. 但两者**都在缓存的 system prompt 里**——它们不是中途临时叠加的（那会破坏缓存）

### 2.2 worktree 排序技巧（长前缀复用）

context 层里，**共享的项目文件排在「任何指名当前 worktree 的内容」之前**。
这样同一项目在不同 git worktree 下运行的会话，能共享覆盖整个 context block 的 prompt 前缀，
而不是在第一条 cwd 相关行就断掉——那一段前缀正是「最长前缀 provider 缓存」会复用的部分。

没有 workspace 快照的会话，把尾随指引留在 stable 层；**运行时环境块永远结束 volatile 层**。

---

## 3. 存储提示的校验（`_stored_prompt_matches_runtime()`）

[`agent/conversation_loop.py`](../agent/conversation_loop.py:1) 里的 `_stored_prompt_matches_runtime()`
读取渲染出的 `# Hermes runtime environment` 边界后的第一段 host 信息，
并在绝对末尾有一个结束标记，以区分这个布局和「引用标题的 legacy prose」。

原因：运行时边界跟在所有项目/operator/记忆/插件文本之后，所以那些块里的示例不会伪装成运行时 cwd。

**`Platform:` 被刻意排除在 identity 字段之外**（#104414）：一次 surface 切换（desktop ↔ TUI）
保留已存储的字节，把当前 surface 的指引作为**一次性 note** 投递到 per-turn 的 user 消息通道
（[`agent/surface_switch.py`](../agent/surface_switch.py:1)），于是缓存前缀存活。

### 3.1 `<available_skills>` 索引也用同样机制

每轮都会把当前索引与会话「现在会构建的索引」比较
（[`agent/skills_index_delta.py`](../agent/skills_index_delta.py:1)，从 `build_turn_context` 调用，
所以长命 CLI/TUI/Desktop agent 也被覆盖，不只是 prompt 恢复时）。
差异（新增索引行、删除的名字）走同一个一次性 note 通道，且只在差异变化时发送。

进程内索引缓存以 skill 文件的签名为 key，所以另一个进程写的改动也能被看到。
索引本身在下一个重建边界（compaction）收敛。

> **这是「不破坏缓存但又能更新信息」的标准范式**，值得反复体会：
> 把可变信息放在 user 消息/tool 结果上，让 system prompt 保持字节稳定。

### 3.2 `skip_context_files`

当设置 `skip_context_files`（例如子代理委派）时，**不加载 SOUL.md**，改用硬编码的
`DEFAULT_AGENT_IDENTITY`。

---

## 4. 组装后的 system prompt 长什么样（层级示例）

来自 [`prompt-assembly.md`](../website/docs/developer-guide/prompt-assembly.md:66) 的简化视图：

```text
# Layer 1: Agent Identity (from ~/.hermes/SOUL.md)
You are Hermes, an AI assistant created by Nous Research.
...

# Layer 2: Tool-aware behavior guidance
Task-learned procedures, pitfalls, and task-specific preferences belong in skills.
Memory is the narrow exception for facts that apply to EVERY session.

# Tool-use enforcement (for GPT/Codex models only)
You MUST use your tools to take action — do not describe what you would do.

# Layer 3: Honcho static block (when active)

# Layer 4: Optional system message (from config or API)

# Layer 5: Frozen MEMORY snapshot
## Persistent Memory
- User prefers Python 3.12, uses pyproject.toml

# Layer 6: Frozen USER profile snapshot
## User Profile
- Name: Alice

# Layer 7: Skills index
## Skills (mandatory)
<available_skills>
  software-development:
    - code-review: Structured code review workflow
</available_skills>

# Layer 8: Context files (from project directory)
## AGENTS.md
This is the atlas project. Use pytest for testing.
```

注意「Frozen」二字：MEMORY / USER 快照在会话期间是**冻结**的，不随记忆写入而中途变化。

---

## 5. Context Files 的加载规则

来自 [`agent/AGENTS.md`](../agent/AGENTS.md:69)：

- 只从 **CWD** 在**启动时**加载
- 有字符上限：`CONTEXT_FILE_MAX_CHARS` / 由 context window 得出的动态上限 / 配置项 `context_file_max_chars`
- **绝不**把安装树里的 `AGENTS.md` 当项目上下文（PR #64611）
- 子目录提示会拒绝工作目录外的路径，避免 `~/.codex/AGENTS.md` / `~/.claude/CLAUDE.md` 混入

读取有超时保护：默认 5 秒（配置项 `context_file_read_timeout`），
因为在网络文件系统（iCloud Drive、OneDrive、NFS）上冷读可能无限阻塞，
会在第一轮 turn 之前就卡死 system prompt 组装
（[`agent/prompt_builder.py`](../agent/prompt_builder.py:36)）。

---

## 6. Prompt Caching 的具体策略

[`agent/prompt_caching.py`](../agent/prompt_caching.py:1) 是**纯函数**模块（不依赖 AIAgent）。

默认布局（Anthropic）：**4 个 `cache_control` 断点**

1. 静态 system 前缀
2. system prompt 末尾
3. + 4. 最后 2 条非 system 消息

若没有静态前缀：1 个 system 断点 + 最后 3 条消息。
**所有标记共享同一个 TTL（5 分钟或 1 小时）。**

### 6.1 长前缀查找

[`agent/prompt_cache_boundary.py`](../agent/prompt_cache_boundary.py:1) 的 `find_stable_prefix`
负责找出稳定前缀边界。

### 6.2 一个真实的 provider 陷阱

`envelope_tool_part_cache_markers_supported(provider, base_url)` 处理这个问题：
OpenRouter/Nous Portal 会把 part 级的 `cache_control` 迁移到 `tool_result` block 上；
LiteLLM 风格的代理会原样复制 parts，于是标记落到 `tool_result.content[0]`，
导致**不可重试的 400**。在这条路由上，`role:tool` 不携带 part 标记，预算重新分配。

来源：[`agent/prompt_caching.py`](../agent/prompt_caching.py:23)

---

## 7. 缓存铁律的完整清单（务必背下来）

来自 [`agent/AGENTS.md`](../agent/AGENTS.md:57)：

| 禁止 | 说明 |
|---|---|
| 改动过去上下文 | 唯一的例外是 compression |
| 中途切换 toolsets | 工具是每次 API 调用都发送的 |
| 中途重载记忆 | MEMORY/USER 快照在会话内冻结 |
| 中途重建 system prompt | 除非 compression 触发 |

| 允许的注入通道 | 说明 |
|---|---|
| **user 消息** | skill slash 命令（`agent/skill_commands.py`） |
| **tool 结果** | 子目录 `AGENTS.md` 提示（首尾截断，>32k 字符） |
| **一次性 note（走 user 通道）** | surface 切换指引、`<available_skills>` 索引差异 |

---

## 8. i18n 的一句话（顺带记住）

[`agent/i18n.py`](../agent/i18n.py:1) + `i18n_layers.py` + `i18n_languages.py`：
`t(key)` 的解析顺序是 **plugin packs（后注册者胜）→ user overlay
`<home>/locales/<lang>.yaml`（profile 作用域）→ bundled `locales/<lang>.yaml` → 同上但用 `en` → 裸 key**。
每个 `(home, lang)` 只缓存一份合并字典；`reset_language_cache()` 会清空全部
（每个 pack 注册、`config set display.language` 都会调用）。

---

## 9. 本篇小结与下一步

- system prompt 三层：**stable → context → volatile**，只构建一次、压缩时才重建。
- 需要中途更新信息时，**走 user 消息或 tool 结果**，绝不动 system prompt。
- Claude 缓存策略是 4 个断点共享一个 TTL；注意 LiteLLM 路由的 part 标记陷阱。
- Context files 只从 CWD 启动时加载，5 秒读超时保护。

下一步 → [`05-tools-system.md`](05-tools-system.md)：工具如何自注册、被过滤、被分发。
