#!/usr/bin/env bash
# 构建 vLLM Ascend 中文 / 英文离线站点。
#
# 用法: build-vllm-ascend.sh <源码目录> <输出目录> <zh|en> [站点根地址]
#
# 前提: 源码目录已 checkout 上游代码，并已应用 patches/vllm-ascend/offline.patch，
#       且当前 Python 环境已装好 docs/requirements-docs.txt。
set -euo pipefail

src=${1:?用法: build-vllm-ascend.sh <源码目录> <输出目录> <zh|en> [站点根地址]}
out=${2:?用法: build-vllm-ascend.sh <源码目录> <输出目录> <zh|en> [站点根地址]}
lang=${3:-zh}
site_url=${4:-}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

cd "$src"

# 站点根地址：mkdocs.yml 的 site_url 走 !ENV [DOCS_SITE_URL, 默认值]，
# 但 tools/rtd_build.sh 的中文分支会无条件覆盖它。这里把那一行改成可覆盖，
# 使 CI 输入能同时作用于中英文构建。
if [ -n "$site_url" ]; then
  echo "[build] 覆盖站点根地址 -> $site_url"
  python - "$site_url" <<'PY'
import pathlib
import re
import sys

url = sys.argv[1]
script = pathlib.Path("tools/rtd_build.sh")
text = script.read_text(encoding="utf-8")
text, n = re.subn(
    r'^(\s*export DOCS_SITE_URL=).*$',
    lambda m: f'{m.group(1)}"{url}"',
    text,
    count=1,
    flags=re.M,
)
if n:
    script.write_text(text, encoding="utf-8")
    print("  - tools/rtd_build.sh 已更新")
else:
    print("  - 未找到 DOCS_SITE_URL 行，跳过（请检查补丁是否已应用）")
PY
  export DOCS_SITE_URL="$site_url"
fi

export DOCS_LANG="$lang"
export SITE_DIR="$out"

echo "[build] DOCS_LANG=$DOCS_LANG SITE_DIR=$SITE_DIR"
bash tools/rtd_build.sh

if [ ! -f "$out/index.html" ]; then
  echo "构建完成但没有生成 index.html: $out" >&2
  exit 1
fi

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
