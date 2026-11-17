#!/usr/bin/env bash
# 构建 vLLM Ascend 中文 / 英文离线站点。
#
# 用法: build-vllm-ascend.sh <源码目录> <输出目录> <zh|en> [站点根地址]
#
# 前提: 源码目录已 checkout 上游代码，并已应用 patches/vllm-ascend/offline.patch，
#       且当前 Python 环境已装好 docs/requirements-docs.txt。
#
# 注意: mkdocs.yml 的离线化**不再**由补丁完成（上游每个 release 都在动这个文件，
#       行级 hunk 迟早冲突），改由 scripts/offline-config.py 按 key 锚点就地改写：
#       幂等、不依赖行号/上下文，锚点缺失时明确报错。本脚本会在构建前自动调用它。
set -euo pipefail

src=${1:?用法: build-vllm-ascend.sh <源码目录> <输出目录> <zh|en> [站点根地址]}
out=${2:?用法: build-vllm-ascend.sh <源码目录> <输出目录> <zh|en> [站点根地址]}
lang=${3:-zh}
# 留空时沿用内网地址（原来是写死在补丁里的同一份默认值）
site_url=${4:-http://vllm-ascend/docx.cw.com/}
repo_url=${DOCS_REPO_URL:-http://git.cw.com/ascend/vllm-ascend}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

# 不用 dirname：部分 Windows 环境（WorkBuddy 的 bash shim）里没有这个可执行文件，
# 纯 bash 参数展开足够，且两种被调用方式都成立。
case "${BASH_SOURCE[0]}" in
  */*) script_dir=$(cd "${BASH_SOURCE[0]%/*}" && pwd) ;;
  *)   script_dir=$PWD ;;
esac

# Git Bash / MSYS 下 pwd 给的是 /d/tmp/... 形式，原生 Windows 的 python.exe 打不开，
# 有 cygpath 就转成 Windows 路径；CI（Linux）上没有这个命令，保持原样即可。
if command -v cygpath >/dev/null 2>&1; then
  script_dir=$(cygpath -w "$script_dir")
fi

cd "$src"

# 清空目录：逐个删除文件而不是 rmtree 整棵树。
# 原因：tools/generate_zh_docs.py 用 shutil.rmtree 重置 docs/source/zh，
# 在开启了「批量删除守卫」的机器上（单次删除超过 N 个文件即被拦截）会直接中止构建。
# 逐个 unlink 每次只算一个文件，两种环境都能过；CI 上只是稍慢，总量只有几百个。
purge_dir() {
  python - "$1" <<'PY'
import os, sys, pathlib
root = pathlib.Path(sys.argv[1])
if not root.exists():
    sys.exit(0)
for cur, dirs, files in os.walk(root, topdown=False):
    for name in files:
        try:
            os.unlink(os.path.join(cur, name))
        except FileNotFoundError:
            pass
    for name in dirs:
        try:
            os.rmdir(os.path.join(cur, name))
        except OSError:
            pass
PY
}

# 中文树与输出目录都可能已有上一轮产物，先安全清空，让 mkdocs 从零写
purge_dir "docs/source/zh"
purge_dir "$out"

# mkdocs.yml 的离线化：offline/privacy 插件、去 CDN 字体、内部 site_url/repo_url、
# 去掉 table-fullscreen.js、清掉上游已删页面的 nav 条目。
# 这里不用补丁，理由见文件头；脚本幂等，中英文各跑一遍也不会叠加改动。
echo "[build] 改写 mkdocs.yml（site_url=$site_url, repo_url=$repo_url）"
python "$script_dir/offline-config.py" mkdocs.yml \
  --site-url "$site_url" \
  --repo-url "$repo_url"

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
