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

  # 对比 HEAD 而不是「工作区 vs 暂存区」：
  # apply-patches.sh 用 git apply --3way，它会把应用结果写进暂存区，
  # 若只比 git diff，刚打完补丁的仓库会被误判为「无改动」并生成空补丁。
  # 加 --binary 保留 png / ico 等二进制新增文件。
  tmp="$target.tmp"
  git -C "$repo" diff HEAD --binary --no-color -- . ${excludes[@]+"${excludes[@]}"} > "$tmp"

  # 空结果绝不落盘：宁可留着上一版补丁，也不要用空文件把已有补丁冲掉
  if [ -s "$tmp" ]; then
    mv "$tmp" "$target"
    echo "已更新 $target ($(grep -c '^diff --git' "$target" || true) 个文件)"
  else
    rm -f "$tmp"
    echo "警告: $repo 与 HEAD 无差异，保留原补丁不动: $target" >&2
  fi
done

echo
echo "完成。确认无误后提交："
echo "  git -C \"$(cd "$out_root/.." && pwd)\" add patches && git commit -m 'update offline patches'"
