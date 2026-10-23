#!/usr/bin/env bash
# 构建 vLLM Recipes 的 MkDocs 遗留站点（Markdown 指南）。
#
# 用法: build-recipes-mkdocs.sh <源码目录> <输出目录> [站点根地址]
#
# 前提: 已 checkout 上游代码、应用 patches/recipes/offline.patch，
#       并装好仓库根目录的 requirements.txt。
set -euo pipefail

src=${1:?用法: build-recipes-mkdocs.sh <源码目录> <输出目录> [站点根地址]}
out=${2:?用法: build-recipes-mkdocs.sh <源码目录> <输出目录> [站点根地址]}
site_url=${3:-http://vllm-recipes.internal/}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

cd "$src"

# mkdocs.yml 里 site_url: !ENV READTHEDOCS_CANONICAL_URL 没有默认值，
# 环境变量缺失会直接报错，所以这里必须给值（离线场景下仅影响 canonical/sitemap）。
export READTHEDOCS_CANONICAL_URL="$site_url"

# 注意：mkdocs.yml 里上游写的是 strict: true，离线补丁已把它改成 false。
# 原因：privacy 插件会把正文里的外链资源抓到 assets/external/，上游任何一个外链
# 404（如 ajv 的 definition_schema.js）或超时（player.vimeo.com）都会升级成
# warning，strict 模式直接中止整站构建。这些是外链可用性问题，与站点内容无关。
# 想复现上游的严格行为，用 `mkdocs build --strict` 手动跑。
echo "[build] mkdocs build (site_url=$READTHEDOCS_CANONICAL_URL)"
mkdocs build --site-dir "$out"

if [ ! -f "$out/index.html" ]; then
  echo "构建完成但没有生成 index.html: $out" >&2
  exit 1
fi

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
