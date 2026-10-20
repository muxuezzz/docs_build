#!/usr/bin/env bash
# 构建 LiteLLM 文档站点（Docusaurus 3.8，离线版，输出 build/）。
#
# 用法: build-litellm-docs.sh <源码目录> <输出目录>
#
# 前提: 已 checkout 上游代码并应用 patches/litellm-docs/offline.patch，
#       Node >= 22.18（见 package.json engines）。
#
# 注意: 产物使用 / 开头的绝对资源路径（baseUrl: '/'），
#       不能双击 index.html 打开，需要静态服务器或部署到站点根目录。
set -euo pipefail

src=${1:?用法: build-litellm-docs.sh <源码目录> <输出目录>}
out=${2:?用法: build-litellm-docs.sh <源码目录> <输出目录>}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ "$out" = "$src/build" ]; then
  echo "输出目录不能是源码自带的 build/ 目录，请换一个路径" >&2
  exit 1
fi

cd "$src"

# NODE_OPTIONS 里若带着宿主注入的 --require，会让 webpack 子进程异常
unset NODE_OPTIONS

echo "[build] npm ci"
# 不能在 npm ci 之前设置 NODE_ENV=production，否则 npm 会跳过 devDependencies，
# 而 docusaurus 本体、dotenv 都在 dev 依赖里
npm ci --include=dev --no-audit --no-fund

export NODE_ENV=production
export NEXT_TELEMETRY_DISABLED=1

echo "[build] docusaurus build"
npm run build

if [ ! -f "$src/build/index.html" ]; then
  echo "docusaurus build 未生成 build/index.html" >&2
  exit 1
fi

# 构建脚本所在目录，用来找同目录的 localize-external-assets.py
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
py=${PYTHON:-python3}
command -v "$py" >/dev/null 2>&1 || py=python

rm -rf "$out"
mkdir -p "$out"
cp -a "$src/build/." "$out/"

# Docusaurus 没有 MkDocs 的 privacy 插件：正文里的远端图片、内嵌 iframe 会原样留在 HTML 里。
# 这里把它们抓到 assets/external/ 并改写链接，失败的保留原 URL（联网时仍能显示）。
echo "[build] 本地化外链资源"
"$py" "$here/localize-external-assets.py" "$out" --prefix assets/external --jobs 12 || true

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
