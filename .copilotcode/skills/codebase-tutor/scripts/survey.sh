#!/usr/bin/env bash
# Codebase survey: language mix, directory volume, author docs, entry hints, shape evidence.
# Usage: run from the target repository root:  bash <skill>/scripts/survey.sh [max_rows]
set -u
ROWS="${1:-15}"
PRUNE='\( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv -o -name target -o -name build -o -name dist -o -name __pycache__ -o -name .next \) -prune'

section() { printf '\n===== %s =====\n' "$1"; }

section "1. 语言分布（按扩展名，排除依赖/产物目录）"
LANG_TABLE=$(eval "find . $PRUNE -o -type f -print" | sed -n 's/.*\.\([A-Za-z0-9]\{1,6\}\)$/\1/p' | sort | uniq -c | sort -rn)
echo "$LANG_TABLE" | head -"$ROWS"
MAIN_EXT=$(echo "$LANG_TABLE" | awk '$2 ~ /^(py|ts|tsx|js|go|java|kt|rs|rb|php|cs|swift|scala|ex|cpp|c)$/ {print $2; exit}')
echo "主语言扩展名推断: ${MAIN_EXT:-未知}"

section "2. 顶层目录体量（主语言文件数 / 全部文件数）"
if [ -n "${MAIN_EXT:-}" ]; then
  for d in */; do
    d="${d%/}"
    case "$d" in node_modules|vendor|.venv|venv|target|build|dist) continue;; esac
    m=$(eval "find \"$d\" $PRUNE -o -type f -name '*.$MAIN_EXT' -print" 2>/dev/null | wc -l | tr -d ' ')
    a=$(eval "find \"$d\" $PRUNE -o -type f -print" 2>/dev/null | wc -l | tr -d ' ')
    printf '%7s %7s  %s\n' "$m" "$a" "$d/"
  done | sort -rn | head -"$ROWS"
  echo "根目录主语言文件: $(ls -1 ./*."$MAIN_EXT" 2>/dev/null | wc -l | tr -d ' ')"
fi

section "3. 作者自述文档（阶段 0 必读）"
eval "find . -maxdepth 3 $PRUNE -o -type f \( -iname 'README*' -o -iname 'AGENTS.md' -o -iname 'CLAUDE.md' -o -iname '.cursorrules' -o -iname 'ARCHITECTURE*' -o -iname 'CONTRIBUTING*' -o -iname 'CHANGELOG*' -o -iname 'DESIGN*' \) -print" | awk -F/ '{print NF"\t"$0}' | sort -n | cut -f2- | head -40
for d in docs doc website/docs documentation; do
  [ -d "$d" ] && echo "文档目录: $d ($(find "$d" -type f -name '*.md*' | wc -l | tr -d ' ') 个 md)"
done

section "4. 包清单（多个 = 可能是 Monorepo）"
eval "find . -maxdepth 3 $PRUNE -o -type f \( -name package.json -o -name go.mod -o -name Cargo.toml -o -name pyproject.toml -o -name setup.py -o -name pom.xml -o -name build.gradle -o -name build.gradle.kts \) -print"

section "5. 入口线索"
case "${MAIN_EXT:-}" in
  py) grep -rlE '__name__ == .__main__.' --include=*.py . 2>/dev/null | grep -vE '/(tests?|node_modules|\.venv)/' | head -"$ROWS"
      grep -n -A12 -E '\[project.scripts\]|console_scripts' pyproject.toml setup.py 2>/dev/null | head -30 ;;
  ts|tsx|js) [ -f package.json ] && python3 -c "import json;d=json.load(open('package.json'));[print(k,':',d.get(k)) for k in ('main','bin','scripts')]" 2>/dev/null ;;
  go) grep -rl 'func main()' --include=*.go . 2>/dev/null | grep -v _test.go | head -"$ROWS" ;;
  java|kt) grep -rlE 'static void main|@SpringBootApplication|^fun main' --include=*.java --include=*.kt . 2>/dev/null | head -"$ROWS" ;;
  rs) ls src/main.rs src/bin 2>/dev/null; grep -n -A3 '\[\[bin\]\]' Cargo.toml 2>/dev/null ;;
  *) echo "未识别主语言，请参照 references/language-matrix.md 手动查找" ;;
esac

section "6. 最大的源码文件（判断大泥球 / 门面）"
if [ -n "${MAIN_EXT:-}" ]; then
  eval "find . $PRUNE -o -type f -name '*.$MAIN_EXT' -print" | grep -vE '(^|/)(tests?|__tests__|spec)/' \
    | xargs wc -l 2>/dev/null | grep -v ' total$' | sort -rn | head -"$ROWS"
fi

section "7. 门面+兄弟证据（同前缀文件 ≥5 个）"
if [ -n "${MAIN_EXT:-}" ]; then
  eval "find . $PRUNE -o -type f -name '*_*.$MAIN_EXT' -print" | grep -vE '/(tests?)/' \
    | sed -E 's#^(.*/)?([^/_]+(_[^/_]+)?)_[^/]*$#\1\2#' | sort | uniq -c | awk '$1>=5' | sort -rn | head -"$ROWS"
fi

section "8. 分层 / 插件化目录线索"
eval "find . -maxdepth 4 $PRUNE -o -type d \( -name controllers -o -name services -o -name repositories -o -name handlers -o -name models -o -name domain -o -name plugins -o -name extensions -o -name addons -o -name skills -o -name adapters -o -name providers \) -print" | head -30

section "9. 测试规模"
eval "find . $PRUNE -o -type f \( -name 'test_*' -o -name '*_test.*' -o -name '*.test.*' -o -name '*.spec.*' \) -print" | wc -l | xargs echo "测试文件数:"

printf '\n下一步：按主语言阅读 references/language-matrix.md 对应小节，继续阶段 0~8。\n'
