#!/usr/bin/env bash
# 把 patches/<项目>/*.patch 依次应用到上游源码目录。
#
# 用法: apply-patches.sh <源码目录> <补丁目录>
# 例:   apply-patches.sh src patches/vllm-ascend
#
# 补丁按文件名字典序应用，每一份都按下面的顺序逐级降级，命中即止：
#
#   0. 规范化       补丁若含 CRLF（Windows 上 core.autocrlf=true 的产物），
#                   先转成 LF 副本再应用，否则 git apply 会逐行不匹配
#   1. git apply --3way   有基线 blob 时能真正做三方合并，容许上下文和行号漂移
#   2. git apply          上下文严格匹配（浅克隆拿不到 blob 时的常规路径）
#   3. patch -p1 -F3      允许每个 hunk 的上下文最多错 3 行，兜住「上游只在
#                         hunk 旁边插了几行」这类 git apply 不肯接受的小漂移
#
# 三级都不成立才失败。每一级都不接受「带冲突地应用」：
# 出现 <<<<<<< 标记、index 里有 unmerged 条目、或留下 .rej 都立即报错退出，
# 不会把半成品文件留给后面的 mkdocs / npm 构建。
set -euo pipefail

repo_dir=${1:?用法: apply-patches.sh <源码目录> <补丁目录>}
patch_dir=${2:?用法: apply-patches.sh <源码目录> <补丁目录>}

repo_dir=$(cd "$repo_dir" && pwd)
patch_dir=$(cd "$patch_dir" && pwd)

shopt -s nullglob
patches=("$patch_dir"/*.patch)
shopt -u nullglob

if [ ${#patches[@]} -eq 0 ]; then
  echo "未找到补丁，跳过: $patch_dir"
  exit 0
fi

# patch(1) 在 Ubuntu runner 上都有；Git for Windows 把它放在 usr/bin，
# 极简 PATH（含本机那套 bash shim）里可能查不到，这里多探几个位置。
find_patch_cmd() {
  local cand
  for cand in patch patch.exe /usr/bin/patch /usr/bin/patch.exe; do
    if command -v "$cand" >/dev/null 2>&1; then
      command -v "$cand"
      return 0
    fi
  done
  return 1
}
patch_bin=$(find_patch_cmd || true)
if [ -z "$patch_bin" ]; then
  echo "::notice title=缺少 patch 命令::未找到 patch(1)，上下文漂移时无法做 fuzz 兜底（不影响正常构建）"
fi

work_dir=''
cleanup() {
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

# git.exe 是原生 Windows 程序，不认 MSYS 的 /d/tmp/... 路径（会报 can't open patch）；
# cygpath 只在 Git Bash 里存在，Linux runner 上没有，此时原样返回。
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w -- "$1"
  else
    printf '%s' "$1"
  fi
}

# 补丁里有没有 CRLF：read -r 会保留行尾的 \r，命中即说明有
has_crlf() {
  local line
  while IFS= read -r line; do
    case $line in
      *$'\r') return 0 ;;
    esac
  done < "$1"
  return 1
}

# 把补丁规范化为 LF 副本，结果放在 cur_patch（bash 读写用）
# 与 cur_patch_git（传给 git.exe 的原生路径）
cur_patch=''
cur_patch_git=''
normalize_patch() {
  local src=$1 line
  if ! has_crlf "$src"; then
    cur_patch=$src
  else
    if [ -z "$work_dir" ]; then
      work_dir=$(mktemp -d)
    fi
    cur_patch=$work_dir/$(basename "$src")
    {
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "${line%$'\r'}"
      done < "$src"
    } > "$cur_patch"
    echo "::notice title=补丁含 CRLF::$(basename "$src") 已按 LF 规范化后应用（常见于 Windows 的 core.autocrlf）"
  fi
  cur_patch_git=$(native_path "$cur_patch")
}

# 列出补丁会碰到的文件（纯 bash，避免依赖 grep/awk —— 本机 shim 环境里会缺）
list_patch_targets() {
  local line
  while IFS= read -r line; do
    case $line in
      '+++ b/'*) printf '%s\n' "${line#+++ b/}" ;;
    esac
  done < "$1"
}

has_conflict_marker() {
  local line
  while IFS= read -r line; do
    case $line in
      '<<<<<<< '*) return 0 ;;
    esac
  done < "$1"
  return 1
}

# git 3-way 冲突时会把条目留在 index 里，这是最权威的判据
unmerged_files() {
  git diff --name-only --diff-filter=U 2>/dev/null || true
}

# 逐文件检查冲突标记，命中就打印 ::error 并以 1 返回
check_clean_after_apply() {
  local name=$1 target conflicted
  conflicted=$(unmerged_files)
  if [ -n "$conflicted" ]; then
    echo "::error title=补丁产生合并冲突::${name} 在以下文件上无法自动合并："
    printf '    %s\n' $conflicted
    echo "    本地排查：cd ${repo_dir} && git apply --3way -v ${cur_patch_git}"
    return 1
  fi
  while IFS= read -r target; do
    [ -e "$target" ] || continue
    if has_conflict_marker "$target"; then
      echo "::error title=补丁留下冲突标记::${target} 内含 <<<<<<< 标记，构建结果不可用"
      echo "    还原：cd ${repo_dir} && git checkout -- ${target}"
      return 1
    fi
  done < <(list_patch_targets "$cur_patch")
  return 0
}

# 把 git apply --check --3way 的失败原因翻成人话，用于日志
explain_3way_failure() {
  case $1 in
    *"lacks the necessary blob"*) echo "浅克隆缺少基线 blob" ;;
    *"does not match index"*)     echo "工作区与 index 不一致（有未提交改动）" ;;
    *"with conflicts"*)           echo "与上游内容合并冲突" ;;
    *"does not exist"*)           echo "目标文件不存在" ;;
    *)                            echo "上下文不匹配" ;;
  esac
}

# 依次尝试三级策略，成功返回 0
apply_one() {
  local name=$1
  local err plain_err patch_out line reason

  if err=$(git apply --check --3way "$cur_patch_git" 2>&1); then
    git apply --3way --whitespace=nowarn "$cur_patch_git"
    if [ "$shallow_repo" = true ]; then
      # 缺基线 blob 时 git 会静默退回严格匹配，日志别谎报成三方合并
      echo "    ✓ 应用成功（浅克隆：3-way 已降级为严格匹配）"
    else
      echo "    ✓ 三方合并成功"
    fi
    return 0
  fi
  reason=$(explain_3way_failure "$err")

  if plain_err=$(git apply --check "$cur_patch_git" 2>&1); then
    echo "    ✓ 按上下文直接应用（3-way 不可用：${reason}）"
    git apply --whitespace=nowarn "$cur_patch_git"
    return 0
  fi

  # 两级 git apply 都失败，把原始原因带出来，省得再去本地复现
  echo "    两级 git apply 均失败，原始输出："
  printf '      [3way] %s\n' "$err"
  printf '      [plain] %s\n' "$plain_err"

  if [ -z "$patch_bin" ]; then
    echo "::error title=补丁应用失败::${name} 无法应用（${reason}），且环境里没有 patch 命令可做 fuzz 兜底。"
    echo "    在本地仓库执行 scripts/make-patches.sh 重新生成补丁。"
    return 1
  fi

  # 第三级：先 dry-run，确认能带 fuzz 合上再动文件，避免弄脏工作区
  if ! "$patch_bin" -p1 --batch --forward --no-backup-if-mismatch -F3 \
        --dry-run -i "$cur_patch" >/dev/null 2>&1; then
    # 已应用过的补丁（反向 dry-run 能过）视为完成，方便本地重复执行
    if "$patch_bin" -p1 --batch --reverse -F3 --dry-run -i "$cur_patch" >/dev/null 2>&1; then
      echo "::notice title=补丁已应用::${name} 当前源码已包含该改动，跳过"
      return 0
    fi
    echo "::error title=补丁应用失败::${name} 无法应用（${reason}），fuzz 兜底（-F3）也合不上。"
    case $reason in
      *"目标文件不存在"*)
        echo "    补丁要改的文件不在源码树里，通常是 ref 与补丁不匹配（比如用 main 的补丁去打旧 tag）。" ;;
      *)
        echo "    上游相关行被实质改写过，需要重新生成补丁：scripts/make-patches.sh" ;;
    esac
    echo "    本地排查：cd ${repo_dir} && git apply --3way -v ${cur_patch_git}"
    return 1
  fi

  if ! patch_out=$("$patch_bin" -p1 --batch --forward --no-backup-if-mismatch -F3 -i "$cur_patch" 2>&1); then
    echo "::error title=补丁应用失败::${name} dry-run 通过但实际应用失败："
    printf '%s\n' "$patch_out"
    return 1
  fi

  while IFS= read -r line; do
    case $line in
      *"with fuzz"*|*"succeeded at"*|*"offset"*)
        echo "::warning title=补丁上下文漂移::${name}: ${line}" ;;
    esac
  done <<< "$patch_out"
  echo "    ✓ 带 fuzz 应用成功（上下文有漂移，建议核对改动是否符合预期）"
  return 0
}

cd "$repo_dir"

# 浅克隆缺基线 blob，git 的 --3way 会静默降级成严格匹配，日志里要说清楚
shallow_repo=false
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
  shallow_repo=true
  echo "::notice title=浅克隆::当前仓库是浅克隆，3-way 合并会降级为严格匹配，漂移只能靠 patch -F3 兜底"
fi

for p in "${patches[@]}"; do
  name=$(basename "$p")
  echo "==> 应用补丁 $name"
  normalize_patch "$p"

  # 上一次异常退出可能已经把冲突标记写进文件，这种状态下继续应用只会更乱
  while IFS= read -r target; do
    [ -e "$target" ] || continue
    if has_conflict_marker "$target"; then
      echo "::error title=工作区已被污染::${target} 事前就含 <<<<<<< 标记，请先还原再重跑"
      echo "    还原：cd ${repo_dir} && git checkout -- ${target}"
      exit 1
    fi
  done < <(list_patch_targets "$cur_patch")

  apply_one "$name" || exit 1
  check_clean_after_apply "$name" || exit 1
done

echo "补丁全部应用完成: $repo_dir"
