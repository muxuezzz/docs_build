#!/usr/bin/env bash
# 构建 astral 系离线文档站点（ruff / uv / ty）。
#
# 用法: build-astral.sh <ruff|uv|ty> <源码目录> <输出目录>
#
# 前提:
#   - ruff/uv/ty 上游代码已 checkout，并应用 patches/<项目>/offline.patch
#   - 已安装 uv（Python 由 uv 管理，版本见各仓库 pyproject 的 requires-python）
#   - ruff / uv 额外需要 Rust 工具链：ruff 用 `cargo dev generate-docs` 导出规则页，
#     uv 用 `cargo dev generate-*-reference` 生成参考页；ty 不需要
set -euo pipefail

project=${1:?用法: build-astral.sh <ruff|uv|ty> <源码目录> <输出目录>}
src=${2:?用法: build-astral.sh <ruff|uv|ty> <源码目录> <输出目录>}
out=${3:?用法: build-astral.sh <ruff|uv|ty> <源码目录> <输出目录>}

src=$(cd "$src" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)

cd "$src"

case "$project" in
  ruff)
    # README -> docs/index.md，再由 cargo dev 导出规则页与 mkdocs.generated.yml
    # （仓库里的 mkdocs.yml 只是 INHERIT: mkdocs.generated.yml，所以离线化改在 mkdocs.template.yml）
    # 注意 transform_readme.py 会原地改写 README.md，重复执行会失败，所以先判断是否已转换。
    if grep -q "user-images.githubusercontent.com/1309177/232603516" README.md; then
      echo "[build] ruff: 转换 README.md 为 mkdocs 形式"
      uv run scripts/transform_readme.py --target mkdocs
    else
      echo "[build] ruff: README.md 已是 mkdocs 形式，跳过转换"
    fi
    echo "[build] ruff: 生成规则页与 mkdocs.generated.yml（需要 Rust）"
    uv run scripts/generate_mkdocs.py
    ;;
  uv)
    # 这些参考页不入库，必须由 cargo dev 现场生成
    echo "[build] uv: 生成 CLI / 选项 / 环境变量 / 预览特性参考页"
    cargo --locked dev generate-options-reference
    cargo --locked dev generate-cli-reference
    cargo --locked dev generate-env-vars-reference
    cargo --locked dev generate-preview-features-reference
    ;;
  ty)
    # 参考页已入库，无需额外生成
    ;;
  *)
    echo "未知项目: $project（只支持 ruff / uv / ty）" >&2
    exit 2
    ;;
esac

echo "[build] $project: mkdocs build --strict"
uv run --only-group=docs mkdocs build --strict -f mkdocs.yml

built="$src/site/$project"
if [ ! -f "$built/index.html" ]; then
  echo "构建完成但没有生成 $built/index.html" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -a "$built/." "$out/"

echo "[build] 完成，文件数: $(find "$out" -type f | wc -l)，体积: $(du -sh "$out" | cut -f1)"
