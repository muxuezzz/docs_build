#!/usr/bin/env bash
# 把 patches/<项目>/*.patch 依次应用到上游源码目录。
#
# 用法: apply-patches.sh <源码目录> <补丁目录>
# 例:   apply-patches.sh src patches/vllm-ascend
#
# 补丁按文件名字典序应用。优先 git apply --3way（容忍上下文漂移），
# 浅克隆下拿不到基础 blob 时退化为按上下文直接应用；两者都不行才失败。
set -euo pipefail

repo_dir=${1:?用法: apply-patches.sh <源码目录> <补丁目录>}
patch_dir=${2:?用法: apply-patches.sh <源码目录> <补丁目录>}

repo_dir=$(cd "$repo_dir" && pwd)
patch_dir=$(cd "$patch_dir" && pwd)

shopt -s nullglob
patches=("$patch_dir"/*.patch)
shopt -u nullglob

if [ ${#patches[@]} -eq 0 ]; then
  echo "未找到补丁，跳过: $patch_dir"
  exit 0
fi

cd "$repo_dir"

for p in "${patches[@]}"; do
  name=$(basename "$p")
  echo "==> 应用补丁 $name"

  if git apply --check --3way "$p" >/dev/null 2>&1; then
    git apply --3way --whitespace=nowarn "$p"
  elif git apply --check "$p" >/dev/null 2>&1; then
    echo "    (3-way 不可用，按上下文直接应用)"
    git apply --whitespace=nowarn "$p"
  else
    echo "::error title=补丁应用失败::${name} 无法应用，上游相关文件可能已变更。请在本地仓库执行 scripts/make-patches.sh 重新生成补丁。"
    exit 1
  fi
done

echo "补丁全部应用完成: $repo_dir"
