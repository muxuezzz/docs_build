#!/usr/bin/env bash
# 从本地工作副本导出「离线化」补丁。
#
# 用法: scripts/make-patches.sh [源码根目录]
#   默认源码根目录: $DOCS_SRC，否则 /d/tmp/aaaupdate/docs
#
# 期望的目录布局:
#   <源码根目录>/vllm-ascend   —— vllm-project/vllm-ascend 的本地克隆
#   <源码根目录>/recipes       —— vllm-project/recipes 的本地克隆
#   <源码根目录>/ruff|uv|ty    —— astral-sh/ruff|uv|ty 的本地克隆
#   <源码根目录>/vllm-omni     —— vllm-project/vllm-omni 的本地克隆
#   <源码根目录>/litellm-docs  —— BerriAI/litellm-docs 的本地克隆
#
# Q-Peppa.github.io（Pi 文档）不需要补丁，因此不在列表里。
# 只导出已跟踪文件的改动（git diff），未跟踪文件不会进补丁。
set -euo pipefail

src_root=${1:-${DOCS_SRC:-/d/tmp/aaaupdate/docs}}
out_root=$(cd "$(dirname "$0")/.." && pwd)/patches

if [ ! -d "$src_root" ]; then
  echo "源码根目录不存在: $src_root" >&2
  exit 1
fi

for name in vllm-ascend recipes ruff uv ty vllm-omni litellm-docs; do
  repo="$src_root/$name"
  if [ ! -d "$repo/.git" ]; then
    echo "跳过（不是 git 仓库）: $repo" >&2
    continue
  fi

  mkdir -p "$out_root/$name"
  target="$out_root/$name/offline.patch"

  # 新增的模板/静态资源（如 overrides/partials/source.html、public/logos/*.png）
  # 默认是未跟踪状态，直接 git diff 抓不到。这里只把这几类新文件用
  # intent-to-add 标记进来，其余未跟踪文件（产物 zip、lock 文件等）一律忽略。
  untracked=$(git -C "$repo" ls-files --others --exclude-standard \
    | grep -E '(^|/)(overrides|\.overrides)/|^public/logos/' || true)
  if [ -n "$untracked" ]; then
    git -C "$repo" add -N -- $untracked >/dev/null 2>&1 || true
    echo "提示: $repo 纳入 $(echo "$untracked" | wc -l) 个新增模板文件" >&2
  fi

  # 有些项目的构建钩子会就地重写文档源文件（vllm-omni 的 generate_examples /
  # generate_api_readme / awesome-nav），这些是构建副产物，本地跑过一次构建就脏了，
  # 不能写进补丁，否则会把构建机的临时结果带给 CI。
  excludes=()
  case "$name" in
    vllm-omni)
      excludes=(
        ':(exclude)docs/user_guide/examples'
        ':(exclude)docs/api'
        ':(exclude)docs/generated'
        ':(exclude)docs/.nav.yml'
      )
      ;;
  esac

  git -C "$repo" diff --binary --no-color -- . ${excludes[@]+"${excludes[@]}"} > "$target"

  if [ -s "$target" ]; then
    echo "已更新 $target ($(grep -c '^diff --git' "$target" || true) 个文件)"
  else
    echo "警告: $repo 没有未提交改动，$target 为空" >&2
  fi

  if [ -n "$(git -C "$repo" diff --cached --name-only)" ]; then
    echo "提示: $repo 存在已暂存的改动，它们不会写入补丁（请先 git add -p / git reset）" >&2
  fi
done

echo
echo "完成。确认无误后提交："
echo "  git -C \"$(cd "$out_root/.." && pwd)\" add patches && git commit -m 'update offline patches'"
