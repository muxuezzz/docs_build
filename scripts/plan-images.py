#!/usr/bin/env python3
"""把镜像清单解析成 GitHub Actions 矩阵，顺带做输入校验与重命名。

用法:
    python3 scripts/plan-images.py <清单文件> [已有资产列表文件]

环境变量:
    IMAGES_INPUT   非空时覆盖清单文件内容（workflow_dispatch 的输入）
    PLATFORM       目标平台，编进资产文件名（同镜像不同平台不能共用一个资产名）
    RENAME         触发时指定的重命名，见下
    ONLY_MISSING   true 时跳过「已有资产列表」里已存在的镜像
    GITHUB_OUTPUT  存在时把 matrix / count 追加写入；否则打印到 stdout

重命名语法（统一是「原引用=新名字」，左边原名、右边想要的名字）:
    - images.txt / images 输入里可以写 alpine:3.21=myalpine:latest
    - RENAME 输入同样支持，并且优先级更高；只想给唯一一个镜像改名时
      可以直接填 myalpine:latest，不必重复写原引用
    - 新名字同时决定资产文件名和 docker load 之后的 tag（本地脚本会 retag）

约束（和 scripts/load-images.sh 的 TSV 格式一致）:
    - 引用只允许 [A-Za-z0-9._:/@-]，杜绝 shell 元字符
    - 支持 tag 引用和 @sha256:... 摘要引用；摘要引用会被 crane 打上
      :i-was-a-digest，因此这里额外算出 load_tag 供本地脚本 retag
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys

REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,511}$")
ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,511}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-fA-F]{64}$")
SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")


def fail(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    raise SystemExit(1)


def validate(ref: str) -> None:
    if not REF_RE.match(ref):
        fail(f"非法镜像引用 {ref!r}：只允许字母数字和 . _ : / @ -，且不能以符号开头")
    if ".." in ref or "//" in ref:
        fail(f"非法镜像引用 {ref!r}：不允许 .. 或 //")
    if "@" in ref:
        if ref.count("@") != 1:
            fail(f"非法镜像引用 {ref!r}：@ 只能出现一次")
        repo, digest = ref.split("@", 1)
        if not repo or "/" in repo[:1] or not DIGEST_RE.match(digest):
            fail(f"非法摘要引用 {ref!r}：需要 repo@sha256:<64 位 hex>")


def normalize_tag(alias: str) -> str:
    """新名字必须是能直接给 docker tag 用的形式。"""
    if not ALIAS_RE.match(alias):
        fail(f"非法新名字 {alias!r}：只允许字母数字和 . _ : / -，不能带 @ 摘要")
    if ".." in alias or "//" in alias:
        fail(f"非法新名字 {alias!r}：不允许 .. 或 //")
    tail = alias.rsplit("/", 1)[-1]
    return alias if ":" in tail else alias + ":latest"


def short_digest(digest: str) -> str:
    # sha256- + 12 位 hex，既短又不会互相撞
    return digest.replace(":", "-")[:19]


def sanitize(text: str) -> str:
    return SAFE_RE.sub("_", text)


def default_load_tag(ref: str) -> str:
    """docker load 之后希望看到的镜像名（没指定重命名时）。"""
    if "@" in ref:
        repo, digest = ref.split("@", 1)
        return f"{repo}:{short_digest(digest)}"
    tail = ref.rsplit("/", 1)[-1]
    return ref if ":" in tail else ref + ":latest"


def asset_file(load_tag: str, platform: str) -> str:
    # 同一引用按不同平台各拉一次时，资产名必须不同，否则后跑的会覆盖先跑的
    stem = f"{sanitize(load_tag)}_{sanitize(platform)}"
    # 文件名受 ext4 255 字节限制，超长时截短并加 hash 保证唯一
    key = f"{load_tag}@{platform}"
    if len(stem) > 160:
        stem = stem[:140] + "-" + hashlib.sha1(key.encode()).hexdigest()[:8]
    return stem + ".tar"


def tokens(text: str):
    """按行去注释，再按逗号 / 空格 / 换行拆成 token。"""
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        # GitHub 的 workflow_dispatch 字符串输入是单行文本框，塞不进换行
        for token in line.replace(",", " ").split():
            yield token


def read_refs(list_path: str) -> tuple[list[str], dict[str, str]]:
    override = os.environ.get("IMAGES_INPUT", "").strip()
    if override:
        text = override
    else:
        with open(list_path, encoding="utf-8") as f:
            text = f.read()

    refs: list[str] = []
    aliases: dict[str, str] = {}
    for token in tokens(text):
        if "=" in token:
            ref, alias = token.split("=", 1)
            validate(ref)
            aliases[ref] = normalize_tag(alias)
        else:
            ref = token
            validate(ref)
        if ref not in refs:
            refs.append(ref)
    return refs, aliases


def parse_rename(text: str) -> tuple[dict[str, str], str]:
    """返回 (原引用->新名字 映射, 单个裸名字)。"""
    mapping: dict[str, str] = {}
    bare = ""
    for token in tokens(text):
        if "=" in token:
            ref, alias = token.split("=", 1)
            validate(ref)
            mapping[ref] = normalize_tag(alias)
        else:
            if bare:
                fail("rename 里出现多个不带等号的名字；多个镜像请用「原引用=新名字」逐条指定")
            bare = normalize_tag(token)
    return mapping, bare


def main() -> None:
    if len(sys.argv) < 2:
        fail("用法: plan-images.py <清单文件> [已有资产列表文件]")

    platform = os.environ.get("PLATFORM", "linux/amd64").strip() or "linux/amd64"
    refs, aliases = read_refs(sys.argv[1])
    if not refs:
        fail("没有可用镜像：在 workflow 里填 images，或往 images.txt 里加一行")

    mapping, bare = parse_rename(os.environ.get("RENAME", ""))
    if bare and len(refs) != 1:
        fail(f"rename 填了单个名字 {bare!r}，但本次有 {len(refs)} 个镜像；请用「原引用=新名字」逐条指定")
    aliases.update(mapping)
    if bare:
        aliases[refs[0]] = bare
    for ref in aliases:
        if ref not in refs:
            print(f"::warning::rename 里的 {ref!r} 不在本次镜像列表中，已忽略")

    tag_of = {r: aliases.get(r, default_load_tag(r)) for r in refs}
    file_of = {r: asset_file(tag_of[r], platform) for r in refs}

    existing: set[str] = set()
    if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
        with open(sys.argv[2], encoding="utf-8") as f:
            existing = {line.strip() for line in f if line.strip()}

    if os.environ.get("ONLY_MISSING", "").lower() == "true":
        before = len(refs)
        refs = [r for r in refs
                if file_of[r] not in existing
                and f"{file_of[r]}.part00" not in existing]
        print(f"only_missing: 跳过 {before - len(refs)} 个已存在的镜像")

    matrix: list[dict[str, str]] = []
    seen: dict[str, str] = {}
    for i, ref in enumerate(refs):
        f = file_of[ref]
        if f in seen and seen[f] != ref:
            fail(f"资产名冲突：{seen[f]!r} 与 {ref!r} 都会生成 {f!r}（改名撞车了）")
        seen[f] = ref
        matrix.append({
            "ref": ref,
            "file": f,
            "load_tag": tag_of[ref],
            "index": str(i),
        })

    if not matrix:
        print("::warning::矩阵为空（全部已存在或全部被跳过），本次不会拉取任何镜像")

    payload = json.dumps(matrix, ensure_ascii=False, separators=(",", ":"))
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(f"matrix={payload}\ncount={len(matrix)}\n")
    else:
        print(f"matrix={payload}")
        print(f"count={len(matrix)}")

    for item in matrix:
        renamed = " [重命名]" if item["load_tag"] != default_load_tag(item["ref"]) else ""
        print(f"  [{item['index']}] {item['ref']}  ->  {item['file']}  "
              f"({item['load_tag']}){renamed}")


if __name__ == "__main__":
    main()
