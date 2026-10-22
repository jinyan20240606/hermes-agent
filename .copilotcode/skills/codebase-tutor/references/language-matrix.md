# 语言对照与组织形状识别

目录：1. 通用排除规则　2. 各语言命令（Python / TS·JS / Go / Java·Kotlin / Rust）　3. 依赖方向统计　4. 六种组织形状识别

## 1. 通用排除规则

统计时一律排除：`.git` `node_modules` `vendor` `.venv` `venv` `target` `build` `dist` `out` `.next` `__pycache__`。
测试目录单列统计、不计入内核判断。

```bash
EXCL="-not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.venv/*' -not -path '*/target/*' -not -path '*/build/*' -not -path '*/dist/*'"
```

## 2. 各语言命令

| 语言 | 扩展名 | 测试位置（单列） | 入口线索 | 包清单 |
|---|---|---|---|---|
| Python | `py` | `tests/` `test_*.py` `*_test.py` | `if __name__ == "__main__"`、`[project.scripts]` / `console_scripts` | `pyproject.toml` `setup.py` |
| TS/JS | `ts` `tsx` `js` | `*.test.*` `*.spec.*` `__tests__/` | `package.json` 的 `bin` `main` `scripts`、`app.listen(` | `package.json` |
| Go | `go` | `*_test.go` | `cmd/*/main.go`、`func main()` | `go.mod` |
| Java/Kotlin | `java` `kt` | `src/test/` | `static void main`、`@SpringBootApplication`、`fun main` | `pom.xml` `build.gradle(.kts)` |
| Rust | `rs` | `tests/`、`#[cfg(test)]` | `src/main.rs`、`src/bin/`、`[[bin]]` | `Cargo.toml` |

### 入口查找

```bash
# Python
grep -rln '__name__ == "__main__"' --include=*.py . | grep -v tests
grep -n -A15 'project.scripts\|console_scripts' pyproject.toml setup.py 2>/dev/null
# TS/JS
python3 -c "import json;d=json.load(open('package.json'));print(d.get('bin'),d.get('main'),d.get('scripts'))"
# Go
grep -rln 'func main()' --include=*.go . | grep -v _test.go
# Java/Kotlin
grep -rlnE 'static void main|@SpringBootApplication|fun main' --include=*.java --include=*.kt .
# Rust
ls src/main.rs src/bin/ 2>/dev/null; grep -n -A3 '\[\[bin\]\]' Cargo.toml
```

### 被导入次数（找内核）

只统计本仓库模块，过滤掉标准库和第三方包。

```bash
# Python：顶层包名
grep -rhE '^(from|import) ' --include=*.py . | awk '{print $2}' | cut -d. -f1 | sort | uniq -c | sort -rn | head -20
# TS/JS：相对路径导入目标
grep -rhoE "from ['\"](\.\.?/[^'\"]+)['\"]" --include=*.ts --include=*.tsx --include=*.js . | sort | uniq -c | sort -rn | head -20
# Go：本模块路径（MOD 取自 go.mod 首行）
MOD=$(awk '/^module/{print $2}' go.mod); grep -rhoE "\"$MOD/[^\"]+\"" --include=*.go . | sort | uniq -c | sort -rn | head -20
# Java/Kotlin：本仓库包前缀（PKG 取最常见的 package 声明前两段）
PKG=$(grep -rhE '^package ' --include=*.java --include=*.kt . | awk '{print $2}' | cut -d. -f1-2 | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
grep -rhE "^import $PKG" --include=*.java --include=*.kt . | awk '{print $2}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head -20
# Rust：crate 内模块
grep -rhoE 'use crate::[a-z_]+' --include=*.rs . | sort | uniq -c | sort -rn | head -20
```

## 3. 依赖方向统计（画架构流转图）

把 `DIRS` 换成阶段 1 识别出的顶层模块，输出 `A -> B : 次数`，即依赖图的边。

```bash
# Python
DIRS="agent tools gateway cli"
for a in $DIRS; do for b in $DIRS; do [ "$a" = "$b" ] && continue
  n=$(grep -rhE "^(from|import) $b(\.|\s|$)" --include=*.py "$a" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && echo "$a -> $b : $n"; done; done
# TS/JS（monorepo 包名或 src 子目录）
for a in $DIRS; do for b in $DIRS; do [ "$a" = "$b" ] && continue
  n=$(grep -rhE "from ['\"][^'\"]*$b[/'\"]" --include=*.ts --include=*.tsx "$a" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && echo "$a -> $b : $n"; done; done
```

Go / Java / Rust 同理：在 A 目录中 grep 指向 B 的 import / use 语句计数。

解读：正常架构箭头只向下（外壳 → 内核 → 能力/状态 → 支撑）。出现反向边要单独标出；被所有模块依赖的那层是改动风险最高的地方。

## 4. 六种组织形状识别

```bash
# 最大文件（判断大泥球 / 门面）
find . -type f \( -name '*.py' -o -name '*.ts' -o -name '*.go' -o -name '*.java' -o -name '*.rs' \) \
  -not -path '*/node_modules/*' -not -path '*/test*' -exec wc -l {} + 2>/dev/null | sort -rn | sed -n '2,16p'
# 门面+兄弟：同前缀文件数（把 STEM 换成最大文件名去掉扩展名）
STEM=hermes_state; ls ${STEM}_*.* 2>/dev/null | wc -l
# Monorepo：多个包清单
find . -maxdepth 3 \( -name package.json -o -name go.mod -o -name Cargo.toml -o -name pyproject.toml -o -name pom.xml \) -not -path '*/node_modules/*'
# 分层：典型层名
find . -maxdepth 4 -type d \( -name controllers -o -name services -o -name repositories -o -name handlers -o -name models -o -name domain \) -not -path '*/node_modules/*'
# 插件化：插件/扩展目录
find . -maxdepth 3 -type d \( -name plugins -o -name extensions -o -name addons -o -name skills \) -not -path '*/node_modules/*'
```

| 形状 | 判据 | 读法 |
|---|---|---|
| 大泥球 | 1 个文件 >5000 行，其余很小 | 找作者架构文档，按函数名分段读 |
| 模块化 | 文件多在 200~500 行，按功能分目录 | 一个目录一件事，按目录读 |
| 门面+兄弟 | `X` 1000+ 行，旁边有 ≥5 个 `X_主题` 文件 | 不读门面，grep 兄弟文件 |
| 分层 MVC/洋葱 | 存在 controllers/services/repositories 等层 | 顺着路由 → 服务 → 存储往下找 |
| Monorepo | ≥2 个包清单 | 先画包间依赖图，再挑一个包当内核 |
| 插件化微内核 | 小 core + 大量 plugins/extensions | 只精读 core，挑 1 个插件当样例 |
