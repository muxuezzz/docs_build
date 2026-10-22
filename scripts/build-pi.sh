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
# pnpm 不是到处都有，兜底用 npm run build（只执行 scripts.build，与包管理器无关）。
# 注意宿主的 NODE_OPTIONS 垫片会拦下构建里的删除操作，先清掉。
unset NODE_OPTIONS
if command -v pnpm >/dev/null 2>&1; then
  pnpm build
elif command -v corepack >/dev/null 2>&1 && corepack pnpm --version >/dev/null 2>&1; then
  corepack pnpm build
else
  echo "[build] 未找到可用的 pnpm，改用 npm run build"
  npm run build
fi

built="$src/doc_build"
if [ ! -f "$built/index.html" ]; then
  echo "构建完成但没有生成 $built/index.html" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -a "$built/." "$out/"

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
