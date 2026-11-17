#!/usr/bin/env python3
# 按「锚点」而不是「上下文行」改写 mkdocs.yml，用来替代 mkdocs.yml 上的行级补丁。
#
# 为什么不用 unified diff：
#   mkdocs.yml 是上游最活跃的文件之一（版本号、nav 列表、markdown_extensions 每个
#   release 都在动）。任何基于「3 行上下文」的 hunk，只要上游在附近改了字，git apply
#   就直接失败；落到 git apply --3way 又会在「两边都改过的行」上留冲突标记，而冲突点
#   往往和你想改的内容毫无关系（典型例子：补丁要改 toc_depth，上游把那几行连同
#   `- tables` 一起重写了）。
#
# 这里改成按 key / 列表项定位，只做四类原子操作：
#   set_scalar        顶层键的整行值改写
#   ensure_sub_key    在某个块里保证存在一个标量子键（如 theme.font: false）
#   ensure_list_item  在某个块里保证存在一个列表项（如 plugins 里的 offline）
#   remove_list_item  删掉某个列表项（不管它在第几行、第几个）
#   rename_list_item  列表项路径改名（如 kv_cache_pool_ascend_store.md -> kv_pool.md）
#
# 关键性质：
#   * 幂等 —— 重复执行结果完全一致，不会像补丁那样第二次打就失败
#   * 无行号、无上下文 —— 上游在别处加 50 行 nav、改版本号都不影响
#   * 目标消失即报错 —— 上游真把 key 改名/删掉时，退出码 1 并指出缺哪个锚点，
#     而不是留一堆 <<<<<<< 让后面的 mkdocs build 报 YAML 语法错
#
# 用法:
#   python scripts/offline-config.py mkdocs.yml \
#       --site-url http://vllm-ascend/docx.cw.com/ \
#       --repo-url http://git.cw.com/ascend/vllm-ascend
#   python scripts/offline-config.py mkdocs.yml --check   # 只检查锚点，不写文件
#
# 退出码: 0 成功（或有/无改动）；1 锚点缺失（上游结构变了，需要人工看）
import argparse
import re
import sys
import pathlib


class AnchorError(Exception):
    pass


def find_key(lines, key, lo=0, hi=None, indent=None):
    """找形如 `key:` 的行，indent 给定时要求缩进完全一致。返回行下标或 None。"""
    hi = len(lines) if hi is None else hi
    pattern = re.compile(rf'^(\s*){re.escape(key)}\s*:(\s|$)')
    for i in range(lo, hi):
        m = pattern.match(lines[i])
        if not m:
            continue
        if indent is None or len(m.group(1)) == indent:
            return i
    return None


def block_end(lines, start):
    """返回 start 这个 key 所属块的最后一个「内容行」下标（跳过尾部空行/注释）。

    YAML 里比父键缩进更深的行才算子内容；同缩进就是兄弟键，块到此结束。
    空行和注释不打断块（它们对 YAML 结构没有影响）。
    """
    key_indent = len(lines[start]) - len(lines[start].lstrip(' '))
    last = start
    i = start + 1
    while i < len(lines):
        raw = lines[i]
        stripped = raw.strip()
        if stripped == '' or stripped.startswith('#'):
            i += 1
            continue
        indent = len(raw) - len(raw.lstrip(' '))
        if indent > key_indent:
            last = i
            i += 1
            continue
        break
    return last


def child_region(lines, key, parent=None):
    """定位块的 (key 行下标, 块尾下标)，parent 给定时在父块内查找（如 theme 下的 features）。"""
    if parent is None:
        idx = find_key(lines, key, indent=0)
        where = key
    else:
        pidx = find_key(lines, parent, indent=0)
        if pidx is None:
            raise AnchorError(f'找不到父键 {parent}:，上游顶层结构可能已变')
        pend = block_end(lines, pidx)
        idx = find_key(lines, key, pidx + 1, pend + 1)
        where = f'{parent}.{key}'
    if idx is None:
        raise AnchorError(f'找不到键 {where}:，上游结构可能已变')
    return idx, block_end(lines, idx)


def item_value(line):
    """把 `  - foo: bar` / `  - "foo"` 解析成 ('foo', 缩进)。不是列表项返回 (None, None)。"""
    stripped = line.strip()
    if not stripped.startswith('- '):
        return None, None
    value = stripped[2:].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
        value = value[1:-1]
    else:
        value = value.split(':', 1)[0].strip()
    return value, len(line) - len(line.lstrip(' '))


def set_scalar(lines, key, value):
    idx = find_key(lines, key, indent=0)
    if idx is None:
        raise AnchorError(f'找不到顶层键 {key}:')
    old = lines[idx]
    lines[idx] = f'{key}: {value}'
    return old


def ensure_sub_key(lines, parent, key, value):
    pidx = find_key(lines, parent, indent=0)
    if pidx is None:
        raise AnchorError(f'找不到父键 {parent}:')
    pend = block_end(lines, pidx)
    sub = find_key(lines, key, pidx + 1, pend + 1)
    if sub is not None:
        lines[sub] = re.sub(rf'(^\s*{re.escape(key)}\s*:\s*).*$',
                            lambda m: f'{m.group(1)}{value}', lines[sub])
        return lines[sub]
    parent_indent = len(lines[pidx]) - len(lines[pidx].lstrip(' '))
    insert_at = pidx + 1
    lines.insert(insert_at, f'{" " * (parent_indent + 2)}{key}: {value}')
    return None


def ensure_list_item(lines, key, item, parent=None):
    idx, end = child_region(lines, key, parent=parent)
    for i in range(idx + 1, end + 1):
        value, _ = item_value(lines[i])
        if value == item:
            return 'present'
    indent = None
    for i in range(idx + 1, end + 1):
        _, ind = item_value(lines[i])
        if ind is not None:
            indent = ind
            break
    if indent is None:
        parent_indent = 0 if parent is None else 2
        key_indent = len(lines[idx]) - len(lines[idx].lstrip(' '))
        indent = max(key_indent, parent_indent) + 2
    lines.insert(end + 1, f'{" " * indent}- {item}')
    return 'added'


def remove_list_item(lines, item):
    removed = 0
    for i in range(len(lines) - 1, -1, -1):
        value, _ = item_value(lines[i])
        if value == item:
            del lines[i]
            removed += 1
    return removed


def rename_list_item(lines, old, new):
    renamed = 0
    for i, line in enumerate(lines):
        value, _ = item_value(line)
        if value == old:
            lines[i] = line.replace(old, new)
            renamed += 1
    return renamed


# 页面在上游被删掉后 nav 里仍指向它，MkDocs 会报 warning（--strict 下直接中止）。
# 这些条目在部分版本里本来就不存在，所以缺了不算错，按「已不存在」处理。
NAV_PRUNE = [
    'tutorials/models/Step-5-Preview.md',
    'user_guide/configuration/runtime_config.md',
    'user_guide/feature_guide/runtime_guard.md',
    'user_guide/feature_guide/encoder_cache_cpu_offload.md',
]

# 上游改了文件名但 nav 没跟上时，这里做重定向。
NAV_RENAME = [
    ('user_guide/feature_guide/kv_cache_pool_ascend_store.md',
     'user_guide/feature_guide/kv_pool.md'),
]

DROP_EXTRA_JAVASCRIPT = ['javascripts/table-fullscreen.js']


def apply_vllm_ascend(lines, site_url, repo_url):
    report = []

    if site_url:
        old = set_scalar(lines, 'site_url',
                         f"!ENV [DOCS_SITE_URL, '{site_url}']")
        report.append(f'site_url: {old.split(":", 1)[1].strip()} -> {site_url}')
    if repo_url:
        old = set_scalar(lines, 'repo_url', repo_url)
        report.append(f'repo_url: {old.split(":", 1)[1].strip()} -> {repo_url}')

    ensure_sub_key(lines, 'theme', 'font', 'false')
    report.append('theme.font: false')
    for feature in ('offline', 'privacy'):
        report.append(f'theme.features += {feature} '
                      f'({ensure_list_item(lines, "features", feature, parent="theme")})')
    for plugin in ('offline', 'privacy'):
        report.append(f'plugins += {plugin} ({ensure_list_item(lines, "plugins", plugin)})')

    for js in DROP_EXTRA_JAVASCRIPT:
        n = remove_list_item(lines, js)
        report.append(f'extra_javascript -= {js} ({n} 处)')

    for page in NAV_PRUNE:
        n = remove_list_item(lines, page)
        report.append(f'nav -= {page} ({n} 处)')

    for old, new in NAV_RENAME:
        n = rename_list_item(lines, old, new)
        report.append(f'nav: {old} -> {new} ({n} 处)')
    return report


PROFILES = {'vllm-ascend': apply_vllm_ascend}


def main():
    ap = argparse.ArgumentParser(description='按锚点改写 mkdocs.yml（替代行级补丁）')
    ap.add_argument('config', help='mkdocs.yml 路径')
    ap.add_argument('--profile', default='vllm-ascend', choices=sorted(PROFILES))
    ap.add_argument('--site-url', default='')
    ap.add_argument('--repo-url', default='')
    ap.add_argument('--check', action='store_true', help='只校验锚点，不写文件')
    args = ap.parse_args()

    path = pathlib.Path(args.config)
    text = path.read_text(encoding='utf-8')
    lines = text.splitlines()

    try:
        report = PROFILES[args.profile](lines, args.site_url, args.repo_url)
    except AnchorError as exc:
        sys.stderr.write(f'::error title=配置锚点缺失::{exc}（{path}）\n')
        return 1

    new_text = '\n'.join(lines) + ('\n' if text.endswith('\n') else '')
    changed = new_text != text
    for line in report:
        print(f'  - {line}')
    if args.check:
        print('锚点校验通过' if not changed else '锚点校验通过（有改动待写入，去掉 --check 生效）')
        return 0
    if not changed:
        print('无需改动（已是离线态）')
        return 0
    path.write_text(new_text, encoding='utf-8')
    print(f'已改写 {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
