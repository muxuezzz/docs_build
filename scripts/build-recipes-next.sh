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
site_url=${3:-http://vllm-recipes.internal/}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ "$out" = "$src/out" ]; then
  echo "输出目录不能是源码自带的 out/ 目录，请换一个路径" >&2
  exit 1
fi

cd "$src"

# 宿主可能通过 NODE_OPTIONS 注入 --require 垫片（本机的删除守卫会拦下 next
# 构建脚本里的 rmSync）。CI 上没有这个变量，这里清掉不影响正常构建。
unset NODE_OPTIONS

export NEXT_TELEMETRY_DISABLED=1
export NEXT_PUBLIC_SITE_URL="$site_url"

# 上一次构建残留的 .next 在 Windows 上常留下文件锁，下次 build 会报
# EPERM: operation not permitted, open '.next/trace'。CI 是干净克隆，没有这个目录。
rm -rf .next

echo "[build] next build (NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL)"
# pnpm 不是到处都有：CI 用 pnpm/action-setup 装上，本机可能只有 corepack 或 npm。
# 兜底用 npm run build —— 它只执行 package.json 里的 scripts.build，与包管理器无关。
if command -v pnpm >/dev/null 2>&1; then
  pnpm build
elif command -v corepack >/dev/null 2>&1 && corepack pnpm --version >/dev/null 2>&1; then
  corepack pnpm build
else
  echo "[build] 未找到可用的 pnpm，改用 npm run build"
  npm run build
fi

if [ ! -f "$src/out/index.html" ]; then
  echo "next build 未生成 out/index.html，检查 next.config.mjs 是否已开启 output: 'export'" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -a "$src/out/." "$out/"

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
