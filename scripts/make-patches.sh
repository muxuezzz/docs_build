#!/usr/bin/env bash
# 从本地工作副本导出「离线化」补丁。
#
# 用法: scripts/make-patches.sh [源码根目录]
#   默认源码根目录: $DOCS_SRC，否则 /d/tmp/aaaupdate/docs
#
# 期望的目录布局:
#   <源码根目录>/vllm-ascend   —— vllm-project/vllm-ascend 的本地克隆
#   <源码根目录>/recipes       —— vllm-project/recipes 的本地克隆
#
# 只导出已跟踪文件的改动（git diff），未跟踪文件不会进补丁。
set -euo pipefail

src_root=${1:-${DOCS_SRC:-/d/tmp/aaaupdate/docs}}
out_root=$(cd "$(dirname "$0")/.." && pwd)/patches

if [ ! -d "$src_root" ]; then
  echo "源码根目录不存在: $src_root" >&2
  exit 1
fi

for name in vllm-ascend recipes; do
  repo="$src_root/$name"
  if [ ! -d "$repo/.git" ]; then
    echo "跳过（不是 git 仓库）: $repo" >&2
    continue
  fi

  mkdir -p "$out_root/$name"
  target="$out_root/$name/offline.patch"
  git -C "$repo" diff --binary --no-color > "$target"

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
