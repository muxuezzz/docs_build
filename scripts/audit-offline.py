#!/usr/bin/env python3
"""离线审计：扫描构建产物里是否残留外部资源引用。

用法:
    python audit-offline.py <站点目录> [--verbose]

分类:
    BLOCKING  浏览器打开页面时必然会发起的网络请求（CSS/JS/字体/图片/iframe/font-face）
    LINK      只在用户点击时才访问的超链接（不影响加载速度）
    SCRIPT    脚本里的 http 字面量（多半是注释/文档链接，需人工判断）

退出码: 0 = 无 BLOCKING 外链；1 = 存在 BLOCKING 外链
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from html.parser import HTMLParser
from urllib.parse import urlparse

LOCAL_PREFIXES = ("#", "/", "./", "../", "data:", "javascript:", "mailto:", "tel:", "blob:")
SKIP_HOSTS = {"localhost", "127.0.0.1"}

# <link rel=...> 中真正会发起请求的取值；canonical/alternate/author 等只是语义标注
FETCHING_REL = {
    "stylesheet", "preload", "prefetch", "modulepreload", "preconnect",
    "dns-prefetch", "icon", "shortcut", "apple-touch-icon", "mask-icon",
    "manifest", "prerender", "preconnect ", "alternate icon",
}

# 会触发网络请求的标签/属性组合
BLOCKING_ATTRS = {
    ("script", "src"),
    ("img", "src"),
    ("img", "srcset"),
    ("source", "src"),
    ("source", "srcset"),
    ("iframe", "src"),
    ("frame", "src"),
    ("embed", "src"),
    ("object", "data"),
    ("video", "src"),
    ("video", "poster"),
    ("audio", "src"),
    ("track", "src"),
}


def is_external(url: str) -> bool:
    if not url:
        return False
    u = url.strip().strip("\"'")
    if not u or u.startswith(LOCAL_PREFIXES):
        return False
    if u.startswith("//"):
        return True  # 协议相对，也是外链
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", u):
        return False  # 相对路径
    try:
        host = urlparse(u).hostname or ""
    except ValueError:
        return False
    return host not in SKIP_HOSTS


def host_of(url: str) -> str:
    u = url.strip().strip("\"'")
    if u.startswith("//"):
        u = "https:" + u
    try:
        return urlparse(u).hostname or u
    except ValueError:
        return u


class Parser(HTMLParser):
    """收集 HTML 中所有可能发请求 / 跳转的引用。"""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.blocking: list[tuple[str, str, str]] = []  # (tag, attr, url)
        self.links: list[str] = []
        self._style_attr = 0

    def handle_starttag(self, tag, attrs):
        d = {k.lower(): (v or "") for k, v in attrs}
        # <a href> 只是超链接
        if tag == "a" and "href" in d:
            self.links.append(d["href"])
        for key in BLOCKING_ATTRS:
            if key[0] == tag and key[1] in d:
                val = d[key[1]]
                if key[1] == "srcset":
                    for part in val.split(","):
                        cand = part.strip().split(" ")[0]
                        if cand:
                            self.blocking.append((tag, "srcset", cand))
                else:
                    self.blocking.append((tag, key[1], val))
        # <link> 只有特定 rel 才会发请求，canonical/alternate 只是语义标注
        if tag == "link" and "href" in d:
            rels = set((d.get("rel") or "").lower().split())
            if rels & FETCHING_REL:
                self.blocking.append(("link", f"rel={' '.join(sorted(rels))}", d["href"]))
        # 内联 style 里的 url()
        style = d.get("style")
        if style:
            for m in re.finditer(r"url\(\s*(['\"]?)([^)'\"]+)\1\s*\)", style):
                self.blocking.append((f"{tag}[style]", "url()", m.group(2)))


RE_JS_HTTP = re.compile(r"""https?://[^\s"'`<>()\\]+""")
RE_CSS_URL = re.compile(r"""url\(\s*(['"]?)([^)'"]+)\1\s*\)""")
RE_CSS_IMPORT = re.compile(r"""@import\s+(?:url\()?\s*['"]?([^'")\s;]+)""")
RE_SRCSET_ATTR = re.compile(r"""\bsrcset\s*=\s*["']([^"']+)["']""", re.I)


def scan_file(path: str, ext: str):
    blocking, links, scripts = [], [], []
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return blocking, links, scripts

    if ext in (".html", ".htm"):
        p = Parser()
        try:
            p.feed(text)
        except Exception:
            pass
        for tag, attr, url in p.blocking:
            if is_external(url):
                blocking.append((tag, attr, url))
        for url in p.links:
            if is_external(url):
                links.append(url)
        # 有些模板把 srcset 写在 JS 里，HTML 解析器拿不到时补一刀
    elif ext == ".css":
        for m in RE_CSS_URL.finditer(text):
            if is_external(m.group(2)):
                blocking.append(("css", "url()", m.group(2)))
        for m in RE_CSS_IMPORT.finditer(text):
            if is_external(m.group(1)):
                blocking.append(("css", "@import", m.group(1)))
    elif ext in (".js", ".mjs"):
        for m in RE_JS_HTTP.finditer(text):
            scripts.append(m.group(0).rstrip(".,;"))
    return blocking, links, scripts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("site")
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--json", help="把结果写入 JSON 文件")
    args = ap.parse_args()

    root = os.path.abspath(args.site)
    if not os.path.isdir(root):
        print(f"目录不存在: {root}", file=sys.stderr)
        return 2

    blocking_by_host: dict[str, list] = defaultdict(list)
    links_by_host: dict[str, int] = defaultdict(int)
    script_by_host: dict[str, list] = defaultdict(list)
    n_html = n_css = n_js = 0
    total_bytes = 0

    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            ext = os.path.splitext(name)[1].lower()
            if ext not in (".html", ".htm", ".css", ".js", ".mjs"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace("\\", "/")
            try:
                total_bytes += os.path.getsize(full)
            except OSError:
                pass
            if ext in (".html", ".htm"):
                n_html += 1
            elif ext == ".css":
                n_css += 1
            else:
                n_js += 1

            blocking, links, scripts = scan_file(full, ext)
            for tag, attr, url in blocking:
                blocking_by_host[host_of(url)].append((rel, tag, attr, url))
            for url in links:
                links_by_host[host_of(url)] += 1
            for url in scripts:
                script_by_host[host_of(url)].append((rel, url))

    print(f"站点: {root}")
    print(f"文件: {n_html} html / {n_css} css / {n_js} js，共 {total_bytes/1048576:.1f} MB")
    print()

    if blocking_by_host:
        tot = sum(len(v) for v in blocking_by_host.values())
        print(f"[!] BLOCKING 外链: {tot} 处，涉及 {len(blocking_by_host)} 个域名")
        for host, items in sorted(blocking_by_host.items(), key=lambda kv: -len(kv[1])):
            print(f"  - {host}: {len(items)} 处")
            for rel, tag, attr, url in items[: (10 if args.verbose else 3)]:
                print(f"      {rel}  <{tag} {attr}> {url[:110]}")
            if len(items) > (10 if args.verbose else 3):
                print(f"      ... 另 {len(items) - (10 if args.verbose else 3)} 处")
    else:
        print("[OK] BLOCKING 外链: 0 —— 页面打开时不会发起任何外部请求")

    print()
    if links_by_host:
        tot = sum(links_by_host.values())
        print(f"[i] 超链接（仅点击时访问，不影响加载）: {tot} 处，{len(links_by_host)} 个域名")
        for host, cnt in sorted(links_by_host.items(), key=lambda kv: -kv[1])[:8]:
            print(f"  - {host}: {cnt}")
    else:
        print("[OK] 超链接: 无外链")

    if script_by_host:
        print()
        print(f"[?] JS 中的 http 字面量: {len(script_by_host)} 个域名（多为注释/文档链接，需人工确认）")
        for host, items in sorted(script_by_host.items(), key=lambda kv: -len(kv[1]))[:10]:
            print(f"  - {host}: {len(items)} 处，例: {items[0][1][:90]}")

    if args.json:
        payload = {
            "site": root,
            "html": n_html,
            "css": n_css,
            "js": n_js,
            "mb": round(total_bytes / 1048576, 2),
            "blocking": {h: [{"file": f, "tag": t, "attr": a, "url": u} for f, t, a, u in v]
                         for h, v in blocking_by_host.items()},
            "links": dict(links_by_host),
        }
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)

    return 1 if blocking_by_host else 0


if __name__ == "__main__":
    sys.exit(main())
