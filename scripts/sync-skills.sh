#!/usr/bin/env bash
# ============================================================
# sync-skills.sh — 同步/更新工作区技能（E:/drama）
#
# 行为:
#   1. 从上游仓库重新拉取全部来源（main 最新）
#   2. 在暂存区组装完成后，原子替换 .agents/skills/（失败则保留现有版本）
#   3. 重建 .workbuddy/skills 链接（Windows: junction / Linux: symlink）
#   4. 重新生成 skills-lock.json
#   5. 校验全部技能 frontmatter
#
# 用法:
#   bash scripts/sync-skills.sh                # 全量同步
#   bash scripts/sync-skills.sh --copy         # .workbuddy/skills 用复制代替链接
#   bash scripts/sync-skills.sh --link claude  # 额外为 .claude/skills 建链接
#
# 依赖: curl / tar / node（Git Bash 下 node 须在 PATH）
#
# 注意（在 WorkBuddy/CodeBuddy 的 AI 会话中运行时）:
#   环境存在 safe-delete 保护，bash 的 rm/unlink/rmdir 被接管，单次批量删除
#   超过阈值（约 50 个文件）会被拦截并要求用户确认。若 AI 运行本脚本被阻断，
#   请在自己的普通终端里执行一次即可正常完成。
# ============================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGE=".skills-staging"
BUILD="$STAGE/build-skills"
MANIFEST="$STAGE/manifest.tsv"
SKILLS_DIR=".agents/skills"
MODE=link
EXTRA_DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE=copy ;;
    --link)
      shift || true
      if [ $# -lt 1 ]; then echo "用法: --link <agent目录标识，如 claude>"; exit 2; fi
      case "$1" in
        claude) EXTRA_DIRS+=(".claude/skills") ;;
        *) EXTRA_DIRS+=(".$1/skills") ;;
      esac
      ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
  shift
done

parse_sha() {
  if command -v node >/dev/null 2>&1; then
    node -e "let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{try{const j=JSON.parse(s);if(j.sha){console.log(j.sha)}else{process.exit(1)}}catch(e){process.exit(1)}})"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,json;print(json.load(sys.stdin)['sha'])"
  else
    python -c "import sys,json;print(json.load(sys.stdin)['sha'])"
  fi
}

fetch_sha() {
  local repo="$1" resp sha token creds
  resp="$(curl -s --max-time 30 "https://api.github.com/repos/$repo/commits/main" || true)"
  sha="$(printf '%s' "$resp" | parse_sha 2>/dev/null || true)"
  if [ -z "$sha" ] && command -v git >/dev/null 2>&1; then
    creds="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null || true)"
    token="$(printf '%s' "$creds" | grep '^password=' | cut -d= -f2 || true)"
    if [ -n "$token" ]; then
      resp="$(curl -s --max-time 30 -H "Authorization: token $token" "https://api.github.com/repos/$repo/commits/main" || true)"
      sha="$(printf '%s' "$resp" | parse_sha 2>/dev/null || true)"
    fi
  fi
  printf '%s' "$sha"
}

take_skills() {
  local dir="$1" pattern="$2" repo="$3" sha="$4" license="$5"
  shopt -s nullglob
  local p name n=0
  for p in "$dir"/$pattern; do
    [ -d "$p" ] || continue
    name="$(basename "$p")"
    cp -r "$p" "$BUILD/"
    printf '%s\t%s\t%s\t%s\n' "$repo" "$sha" "$license" "$name" >> "$MANIFEST"
    n=$((n+1))
  done
  shopt -u nullglob
  echo "   ← $n 个技能"
}

install_source() {
  local repo="$1" license="$2"
  local sha tarball exdir srcroot
  echo "== 拉取 $repo"
  sha="$(fetch_sha "$repo")"
  [ -n "$sha" ] || { echo "   !! 获取 commit 失败（网络/限流）"; return 1; }
  echo "   commit: ${sha:0:12}"
  tarball="$STAGE/${repo//\//_}.tar.gz"
  exdir="$STAGE/x_${repo//\//_}"
  curl -sL --max-time 240 "https://codeload.github.com/$repo/tar.gz/$sha" -o "$tarball"
  rm -rf "$exdir"; mkdir -p "$exdir"
  tar xzf "$tarball" -C "$exdir"
  srcroot="$(ls -d "$exdir"/*/ | head -1)"
  case "$repo" in
    dart-lang/skills)              take_skills "$srcroot/skills" '*' "$repo" "$sha" "$license" ;;
    flutter/agent-plugins)         take_skills "$srcroot/skills" 'flutter-*' "$repo" "$sha" "$license" ;;
    full-stack-skills/rust-skills) take_skills "$srcroot/skills" '*' "$repo" "$sha" "$license" ;;
    ariaramin/flutter-skills)      take_skills "$srcroot/skills" 'dart-flutter-ffi-systems-engineering' "$repo" "$sha" "$license" ;;
    dickwu/apple-design-skill)
      mkdir -p "$BUILD/apple-design"
      cp -r "$srcroot/SKILL.md" "$srcroot/references" "$srcroot/scripts" "$srcroot/README.md" "$BUILD/apple-design/"
      printf '%s\t%s\t%s\t%s\n' "$repo" "$sha" "$license" "apple-design" >> "$MANIFEST"
      echo "   ← 1 个技能 (apple-design)"
      ;;
    *) echo "   !! 未知来源"; return 1 ;;
  esac
}

echo "### 1/5 准备暂存区"
rm -rf "$STAGE"
mkdir -p "$BUILD"
: > "$MANIFEST"

echo "### 2/5 拉取全部来源"
install_source "dart-lang/skills"              "BSD-3-Clause" || { echo "!! 同步中止：保留现有技能，请检查网络后重跑"; exit 1; }
install_source "flutter/agent-plugins"         "BSD-3-Clause" || { echo "!! 同步中止：保留现有技能，请检查网络后重跑"; exit 1; }
install_source "full-stack-skills/rust-skills" "Apache-2.0"   || { echo "!! 同步中止：保留现有技能，请检查网络后重跑"; exit 1; }
install_source "ariaramin/flutter-skills"      "MIT"           || { echo "!! 同步中止：保留现有技能，请检查网络后重跑"; exit 1; }
install_source "dickwu/apple-design-skill"     "未标注"        || { echo "!! 同步中止：保留现有技能，请检查网络后重跑"; exit 1; }

echo "### 3/5 替换 $SKILLS_DIR"
rm -rf "$SKILLS_DIR"
mkdir -p .agents
mv "$BUILD" "$SKILLS_DIR"

echo "### 4/5 重建链接"
if [ "$MODE" = "copy" ]; then
  rm -rf ".workbuddy/skills"; mkdir -p ".workbuddy/skills"
  cp -r "$SKILLS_DIR/." ".workbuddy/skills/"
  echo "复制完成 → .workbuddy/skills"
else
  node scripts/create-links.mjs ".workbuddy/skills"
fi
for d in "${EXTRA_DIRS[@]}"; do
  [ -n "$d" ] || continue
  node scripts/create-links.mjs "$d"
done

echo "### 5/5 生成 lock 与校验"
node scripts/make-lock.mjs "$MANIFEST" > skills-lock.json
echo "   技能总数: $(wc -l < "$MANIFEST")"
node scripts/validate-skills.mjs

rm -rf "$STAGE"
echo ""
echo "✅ 同步完成（来源与 commit 见 skills-lock.json）"
