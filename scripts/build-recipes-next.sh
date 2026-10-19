#!/usr/bin/env bash
# 构建 vLLM Recipes 的 Next.js 静态站点（输出 out/）。
#
# 用法: build-recipes-next.sh <源码目录> <输出目录> [站点根地址]
#
# 前提: 已 checkout 上游代码、应用 patches/recipes/offline.patch（含 output: 'export'），
#       并在源码目录执行过 pnpm install。
set -euo pipefail

src=${1:?用法: build-recipes-next.sh <源码目录> <输出目录> [站点根地址]}
out=${2:?用法: build-recipes-next.sh <源码目录> <输出目录> [站点根地址]}
site_url=${3:-http://vllm-recipes/docx.cw.com/}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ "$out" = "$src/out" ]; then
  echo "输出目录不能是源码自带的 out/ 目录，请换一个路径" >&2
  exit 1
fi

cd "$src"

export NEXT_TELEMETRY_DISABLED=1
export NEXT_PUBLIC_SITE_URL="$site_url"

echo "[build] next build (NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL)"
pnpm build

if [ ! -f "$src/out/index.html" ]; then
  echo "next build 未生成 out/index.html，检查 next.config.mjs 是否已开启 output: 'export'" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -a "$src/out/." "$out/"

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
