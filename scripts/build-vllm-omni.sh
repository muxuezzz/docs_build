#!/usr/bin/env bash
# 构建 vLLM-Omni 的 MkDocs 站点（离线版）。
#
# 用法: build-vllm-omni.sh <源码目录> <输出目录> [站点根地址]
#
# 前提:
#   - 已 checkout 上游代码并应用 patches/vllm-omni/offline.patch
#   - 已在当前环境安装文档依赖（等价于 .readthedocs.yml）
#   - 仓库必须是完整历史：git-revision-date-localized 要读取每个文件的提交时间
set -euo pipefail

src=${1:?用法: build-vllm-omni.sh <源码目录> <输出目录> [站点根地址]}
out=${2:?用法: build-vllm-omni.sh <源码目录> <输出目录> [站点根地址]}
site_url=${3:-http://vllm-omni.internal/}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

# 1) 历史完整性：浅克隆会让「最后更新」时间全部缺失
if [ "$(git -C "$src" rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
  echo "[warn] 浅克隆仓库，git-revision-date-localized 会丢时间；CI 请用 fetch-depth: 0" >&2
fi

# 2) MathJax / Mermaid 本地化（原实现从 unpkg 运行时拉取）
# 注意：不用 mktemp -d。它在这台 Windows 上返回 C:\... 形式的路径，
# GNU tar 会把 C: 当远端主机（"Cannot connect to C: resolve failed"）。
vendor="$src/docs/mkdocs/javascript/vendor"
scratch="$vendor/.scratch"
trap 'rm -rf "$scratch"' EXIT

if [ ! -f "$vendor/mathjax/tex-mml-chtml.js" ]; then
  echo "[build] 下载 MathJax 3.2.2 到 docs/mkdocs/javascript/vendor/"
  mkdir -p "$vendor/mathjax"
  curl -fsSL --retry 3 --max-time 120 \
    -o "$vendor/mathjax/tex-mml-chtml.js" \
    "https://unpkg.com/mathjax@3.2.2/es5/tex-mml-chtml.js"
  # 公式字形依赖 woff-v2 字体；缺失时浏览器回退系统字体（不联网、不卡顿）
  mkdir -p "$scratch"
  if curl -fsSL --retry 2 --max-time 180 -o "$scratch/mathjax.tgz" \
       "https://registry.npmjs.org/mathjax/-/mathjax-3.2.2.tgz" \
     && tar -xzf "$scratch/mathjax.tgz" -C "$scratch" \
        --strip-components=1 package/es5/output/chtml/fonts/woff-v2 2>/dev/null; then
    mkdir -p "$vendor/mathjax/output/chtml/fonts"
    cp -a "$scratch/es5/output/chtml/fonts/woff-v2" "$vendor/mathjax/output/chtml/fonts/"
    echo "[build] 已附带 woff-v2 字体: $(find "$vendor/mathjax/output/chtml/fonts/woff-v2" -type f | wc -l) 个"
  else
    echo "[warn] 字体包下载失败，公式将回退系统字体" >&2
  fi
  rm -rf "$scratch"
fi

if [ ! -f "$vendor/mermaid/mermaid.min.js" ]; then
  echo "[build] 下载 Mermaid 10.9.8 到 docs/mkdocs/javascript/vendor/"
  mkdir -p "$vendor/mermaid" "$scratch"
  if curl -fsSL --retry 3 --max-time 180 -o "$scratch/mermaid.tgz" \
       "https://registry.npmjs.org/mermaid/-/mermaid-10.9.8.tgz" \
     && tar -xzf "$scratch/mermaid.tgz" -C "$scratch" \
        --strip-components=2 package/dist/mermaid.min.js; then
    mv "$scratch/mermaid.min.js" "$vendor/mermaid/mermaid.min.js"
    echo "[build] 已附带 Mermaid: $(du -h "$vendor/mermaid/mermaid.min.js" | cut -f1)"
  else
    echo "Mermaid 下载失败" >&2
    exit 1
  fi
  rm -rf "$scratch"
fi

cd "$src"

echo "[build] mkdocs build (site_url=$site_url)"
# mkdocs 没有 --site-url 选项，补丁把 mkdocs.yml 的 site_url 改成读 OFFLINE_SITE_URL
export OFFLINE_SITE_URL="$site_url"
# 不用 --strict：构建结束再单独检查外链（audit-offline.py）
mkdocs build --site-dir "$out" 2>&1 | tail -40

# 外链本地化：material 的 privacy 插件下载时没有超时，一个不可达的域名就能把
# 整次构建挂死，所以改用这个脚本（并发下载、有超时、失败只降级）
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
py=${PYTHON:-python3}
command -v "$py" >/dev/null 2>&1 || py=python
echo "[build] 本地化外链资源"
"$py" "$here/localize-external-assets.py" "$out" --prefix assets/external --jobs 8 || true

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
