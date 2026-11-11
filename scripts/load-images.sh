#!/usr/bin/env bash
# 从 GitHub Release 下载 crane 导出的镜像 tar，校验后导入本地容器运行时。
#
# 设计前提：本机到 registry 不通/不稳，但到 GitHub Release（或它的加速前缀）能下载。
# 所有下载都支持断点续传，合并后按 MANIFEST.tsv 里的 sha256 校验完整 tar。
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  bash scripts/load-images.sh [选项] [镜像引用或资产文件名 ...]

选项:
  --list                只列出 Release 里可用的镜像（默认行为）
  --all                 下载并导入 MANIFEST.tsv 里的全部镜像
  --repo OWNER/REPO     GitHub 仓库；默认从当前目录的 git remote 推断
  --tag TAG             Release tag，默认 images
  --dir DIR             本地缓存目录，默认 ./image-tarballs
  --mirror URL          下载加速前缀，拼在原始 URL 前面；也可写成含 {url} 的模板
  --runtime NAME        docker（默认）| podman | ctr | none
  --no-load             只下载、合并、校验，不导入
  -h, --help            显示本帮助

环境变量（等价于上面部分选项）:
  IMAGE_REPO  IMAGE_RELEASE_TAG  IMAGE_CACHE_DIR  IMAGE_MIRROR  IMAGE_RUNTIME
  IMAGE_GITHUB_TOKEN  私有仓库的 Release 资产需要认证；也可复用已有的 GH_TOKEN
  https_proxy / HTTPS_PROXY 由 curl 直接读取，需要走代理时照常设置即可

示例:
  bash scripts/load-images.sh --repo me/docs_build --list
  bash scripts/load-images.sh --repo me/docs_build --all
  bash scripts/load-images.sh --repo me/docs_build alpine:3.21 ghcr.io/foo/bar:v1
  IMAGE_MIRROR='https://your-mirror.example/' bash scripts/load-images.sh --all
EOF
}

REPO="${IMAGE_REPO:-}"
TAG="${IMAGE_RELEASE_TAG:-images}"
DIR="${IMAGE_CACHE_DIR:-./image-tarballs}"
MIRROR="${IMAGE_MIRROR:-}"
RUNTIME="${IMAGE_RUNTIME:-docker}"
DO_LOAD=1
MODE=""
refs=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --tag)     TAG="$2"; shift 2 ;;
    --dir)     DIR="$2"; shift 2 ;;
    --mirror)  MIRROR="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --list)    MODE=list; shift ;;
    --all)     MODE=all; shift ;;
    --no-load) DO_LOAD=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    -*)        echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    *)         refs+=("$1"); shift ;;
  esac
done
while [ "$#" -gt 0 ]; do refs+=("$1"); shift; done

case "$RUNTIME" in
  docker|podman|ctr|none) ;;
  *) echo "错误: --runtime 只能是 docker / podman / ctr / none" >&2; exit 2 ;;
esac

if [ -z "$REPO" ]; then
  url="$(git remote get-url origin 2>/dev/null || true)"
  REPO="$(printf '%s' "$url" | sed -E 's#\.git$##; s#^.*[/:]([^/]+/[^/]+)$#\1#')"
fi
if [ -z "$REPO" ]; then
  echo "错误: 无法推断仓库，请加 --repo OWNER/REPO" >&2
  exit 2
fi
if [ -z "$MODE" ] && [ "${#refs[@]}" -eq 0 ]; then MODE=list; fi

BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
mkdir -p "$DIR"

# 加速前缀有两种写法：纯前缀（拼在完整 URL 前）或含 {url} 的模板
mirror_url() {
  local url="$1"
  if [ -z "$MIRROR" ]; then
    printf '%s' "$url"
  elif [[ "$MIRROR" == *'{url}'* ]]; then
    printf '%s' "${MIRROR//\{url\}/$url}"
  else
    printf '%s' "${MIRROR%/}/$url"
  fi
}

TOKEN="${IMAGE_GITHUB_TOKEN:-${GH_TOKEN:-}}"
CURL_OPTS=(-fL --retry 5 --retry-delay 2 --connect-timeout 20
           --speed-time 60 --speed-limit 1024)
# 私有仓库的 browser_download_url 第一跳要带凭据，否则直接 404。
# 但走第三方加速前缀时绝不能带 token —— 那等于把凭据交给别人。
AUTH_OPTS=()
if [ -n "$TOKEN" ]; then
  if [ -n "$MIRROR" ]; then
    echo "警告: 使用加速前缀时不发送 Authorization 头（避免 token 泄露给第三方）；私有仓库请直连或手动下载" >&2
  else
    AUTH_OPTS=(-H "Authorization: Bearer $TOKEN")
  fi
fi

fsize() { wc -c < "$1" | tr -d '[:space:]'; }

fetch_url() {
  local name="$1" dest="$2" url
  url="$(mirror_url "${BASE_URL}/${name}")"
  printf '  下载 %s\n' "$url" >&2
  curl "${CURL_OPTS[@]}" "${AUTH_OPTS[@]}" -o "$dest" "$url"
}

# 已知期望大小时：完整则跳过，不完整则先续传，再不行就全量重下
fetch_resume() {
  local name="$1" dest="$2" expected="$3" url
  url="$(mirror_url "${BASE_URL}/${name}")"
  if [ -f "$dest" ] && [ "$(fsize "$dest")" = "$expected" ]; then
    return 0
  fi
  if [ -s "$dest" ]; then
    printf '  续传 %s\n' "$name" >&2
    if ! curl "${CURL_OPTS[@]}" "${AUTH_OPTS[@]}" -C - -o "$dest" "$url"; then
      rm -f "$dest"
    fi
  fi
  if [ ! -f "$dest" ] || [ "$(fsize "$dest")" != "$expected" ]; then
    printf '  下载 %s（%s 字节）\n' "$name" "$expected" >&2
    curl "${CURL_OPTS[@]}" "${AUTH_OPTS[@]}" -o "$dest" "$url"
  fi
  local got
  got="$(fsize "$dest")"
  if [ "$got" != "$expected" ]; then
    echo "错误: $name 大小不符（期望 $expected，实际 $got），已删除，重跑会重新下载" >&2
    rm -f "$dest"
    return 1
  fi
}

check_sha() {
  local file="$1" want="$2" got
  if command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$file" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  else
    got="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$file")"
  fi
  if [ "$got" != "$want" ]; then
    echo "错误: $(basename "$file") sha256 不匹配（期望 $want，实际 $got）" >&2
    return 1
  fi
}

win_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# tar 里的 RepoTags 是原始引用；重命名、@sha256 引用都需要导入后 retag
retag() {
  local cli="$1" ref="$2" want="$3" src=""
  if "$cli" image inspect "$want" >/dev/null 2>&1; then
    return 0
  fi
  if "$cli" image inspect "$ref" >/dev/null 2>&1; then
    src="$ref"
  else
    # crane 把 @sha256:... 引用的镜像打上 :i-was-a-digest
    src="$("$cli" images --format '{{.Repository}}:{{.Tag}}' \
          | grep -F ':i-was-a-digest' | head -n 1 || true)"
  fi
  if [ -n "$src" ]; then
    "$cli" tag "$src" "$want"
    echo "  重命名: $src -> $want"
  else
    echo "  警告: 导入后没找到 $want，用 $cli images 看看实际 tag" >&2
  fi
}

# MANIFEST.tsv 每次强制刷新；刷新失败时退回本地缓存，方便离线续传
if fetch_url "MANIFEST.tsv" "$DIR/MANIFEST.tsv.new"; then
  mv -f "$DIR/MANIFEST.tsv.new" "$DIR/MANIFEST.tsv"
else
  rm -f "$DIR/MANIFEST.tsv.new"
  if [ ! -f "$DIR/MANIFEST.tsv" ]; then
    echo "错误: 取不到 MANIFEST.tsv，也没有本地缓存。检查 --repo / --tag / --mirror" >&2
    exit 1
  fi
  echo "警告: 刷新 MANIFEST.tsv 失败，改用本地缓存" >&2
fi

if [ "$MODE" = "list" ]; then
  printf '%-46s %-30s %9s %5s %-13s %s\n' "镜像引用" "导入后名字" "大小" "分卷" "平台" "更新时间"
  while IFS=$'\t' read -r ref file size sha parts partsizes digest platform load_tag updated; do
    [[ -z "$ref" || "$ref" == \#* ]] && continue
    shown_tag="$load_tag"
    [ "$shown_tag" = "$ref" ] && shown_tag="(同上)"
    printf '%-46s %-30s %7s MB %5s %-13s %s\n' \
      "$ref" "$shown_tag" "$((size / 1048576))" "$parts" "$platform" "$updated"
  done < "$DIR/MANIFEST.tsv"
  exit 0
fi

declare -A seen=()
targets=()
while IFS=$'\t' read -r ref file size sha parts partsizes digest platform load_tag updated; do
  [[ -z "$ref" || "$ref" == \#* ]] && continue
  pick=0
  if [ "$MODE" = "all" ]; then
    pick=1
  elif [ "${#refs[@]}" -gt 0 ]; then
    for want in "${refs[@]}"; do
      if [ "$want" = "$ref" ] || [ "$want" = "$file" ] || [ "$want" = "${file%.tar}" ]; then
        pick=1
        break
      fi
    done
  fi
  if [ "$pick" = "1" ] && [ -z "${seen[$ref]:-}" ]; then
    seen["$ref"]=1
    targets+=("$ref|$file|$size|$sha|$parts|$partsizes|$load_tag")
  fi
done < "$DIR/MANIFEST.tsv"

if [ "${#targets[@]}" -eq 0 ]; then
  echo "错误: 没有匹配的镜像。用 --list 看可用列表，参数可填镜像引用或资产文件名" >&2
  exit 1
fi

printf 'Release: %s\n' "$BASE_URL"
printf '待处理: %s 个镜像，缓存目录: %s\n\n' "${#targets[@]}" "$DIR"

for row in "${targets[@]}"; do
  IFS='|' read -r ref file size sha parts partsizes load_tag <<< "$row"
  tar="$DIR/$file"
  echo "==> $ref"

  if [ "$parts" = "0" ]; then
    fetch_resume "$file" "$tar" "$size"
  else
    IFS=',' read -r -a psizes <<< "$partsizes"
    for ((i = 0; i < parts; i++)); do
      part="$(printf '%s.part%02d' "$file" "$i")"
      fetch_resume "$part" "$DIR/$part" "${psizes[$i]}"
    done
    if [ ! -f "$tar" ] || [ "$(fsize "$tar")" != "$size" ] || \
       ! check_sha "$tar" "$sha" 2>/dev/null; then
      printf '  合并 %s 卷 -> %s\n' "$parts" "$file"
      : > "$tar"
      for ((i = 0; i < parts; i++)); do
        cat "$DIR/$(printf '%s.part%02d' "$file" "$i")" >> "$tar"
      done
    fi
  fi

  check_sha "$tar" "$sha"
  echo "  校验通过: $file ($((size / 1048576)) MB)"

  if [ "$DO_LOAD" = "0" ] || [ "$RUNTIME" = "none" ]; then
    echo "  跳过导入，文件: $tar"
    continue
  fi

  case "$RUNTIME" in
    docker)
      docker load -i "$(win_path "$tar")"
      retag docker "$ref" "$load_tag"
      ;;
    podman)
      podman load -i "$(win_path "$tar")"
      retag podman "$ref" "$load_tag"
      ;;
    ctr)
      ctr -n k8s.io images import "$(win_path "$tar")"
      echo "  提示: containerd 没有 docker tag，镜像名沿用 MANIFEST.tsv 的 ref 列" >&2
      ;;
  esac
  echo "  完成: $load_tag"
done

echo
echo "全部完成。tar 缓存在 $DIR，重复执行会跳过已下载且大小正确的分卷。"
