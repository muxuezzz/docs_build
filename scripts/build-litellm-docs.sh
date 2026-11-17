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

# 脚本自身目录。必须在 cd 进源码目录之前解析：CI 用相对路径调用
# （bash build-tools/scripts/build-litellm-docs.sh src out/x），cd 之后相对路径失效。
# 反斜杠统一成 /，兼容 Git Bash 下的 Windows 风格路径。
self_path=${BASH_SOURCE[0]//\\//}
case "$self_path" in
  */*) script_dir=$(cd "${self_path%/*}" && pwd) ;;
  *)
    resolved=$(command -v "${BASH_SOURCE[0]}" 2>/dev/null || true)
    resolved=${resolved//\\//}
    case "$resolved" in
      */*) script_dir=$(cd "${resolved%/*}" && pwd) ;;
      *)   script_dir=$PWD ;;
    esac
    ;;
esac

src=${1:?用法: build-litellm-docs.sh <源码目录> <输出目录>}
out=${2:?用法: build-litellm-docs.sh <源码目录> <输出目录>}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

if [ "$out" = "$src/build" ]; then
  echo "输出目录不能是源码自带的 build/ 目录，请换一个路径" >&2
  exit 1
fi

# 外链本地化要用的脚本和解释器，先确认好：npm ci + build 要半小时，
# 等到末尾才发现脚本丢了等于白跑一遍。
localize="$script_dir/localize-external-assets.py"
if [ ! -f "$localize" ]; then
  echo "::error title=缺少外链本地化脚本::${localize} 不存在，离线包会残留外链" >&2
  exit 1
fi
py=${PYTHON:-python3}
command -v "$py" >/dev/null 2>&1 || py=python

# Git Bash / MSYS 下 pwd 给的是 /d/tmp/... 形式，原生 python.exe 打不开；有 cygpath 就转。
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

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

rm -rf "$out"
mkdir -p "$out"
cp -a "$src/build/." "$out/"

# Docusaurus 没有 MkDocs 的 privacy 插件：正文里的远端图片、内嵌 iframe 会原样留在 HTML 里。
# 这里把它们抓到 assets/external/ 并改写链接，失败的保留原 URL（联网时仍能显示）。
echo "[build] 本地化外链资源"
"$py" "$(native_path "$localize")" "$(native_path "$out")" \
  --prefix assets/external --jobs 12 || true

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
