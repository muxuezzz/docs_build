#!/usr/bin/env bash
# 构建 Pi 中文文档（rspress 静态站点）。
#
# 用法: build-pi.sh <源码目录> <输出目录>
#
# 前提: 已 checkout Q-Peppa.github.io，并在源码目录执行过 pnpm install。
set -euo pipefail

src=${1:?用法: build-pi.sh <源码目录> <输出目录>}
out=${2:?用法: build-pi.sh <源码目录> <输出目录>}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

cd "$src"

echo "[build] rspress build"
pnpm build

built="$src/doc_build"
if [ ! -f "$built/index.html" ]; then
  echo "构建完成但没有生成 $built/index.html" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -a "$built/." "$out/"

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
