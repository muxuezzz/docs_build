#!/usr/bin/env python3
"""把站点产物里残留的外链资源下载到本地，并改写 HTML/CSS 指向本地副本。

MkDocs 有 privacy 插件做这件事，Docusaurus / Next / rspress 没有，
所以统一在构建之后跑一遍这个脚本。

用法:
    python localize-external-assets.py <站点目录> [选项]

选项:
    --prefix assets/external   本地副本存放的相对目录（站点根下）
    --keep-iframes             保留 <iframe>（默认改写成占位链接，避免断网时白等）
    --jobs 8                   并发下载数
    --timeout 30               单次请求超时（秒）
    --json report.json         把统计写入 JSON

行为约定:
    - 下载失败（404 / 被墙 / 超时）就保留原 URL，不报错，最后打印统计。
      构建机网络不等于用户的网络，能下多少算多少。
    - 同一 URL 只下一次；文件名取 URL 的 sha1，扩展名按 Content-Type 补。
    - 幂等：本地已存在就跳过下载，重复构建不会重复拉取。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# 打开页面就会发请求的 <link rel>
FETCHING_LINK_REL = {
    "stylesheet", "preload", "modulepreload", "prefetch", "icon",
    "shortcut", "apple-touch-icon", "mask-icon", "manifest",
}

# (标签, 属性) 组合里真正会发请求的那些；href 只对 <link> 生效
FETCH_ATTRS = {
    ("img", "src"), ("img", "srcset"),
    ("source", "src"), ("source", "srcset"),
    ("script", "src"),
    ("video", "src"), ("video", "poster"),
    ("audio", "src"),
    ("track", "src"),
    ("object", "data"),
}

LOCAL_PREFIXES = ("#", "/", "./", "../", "data:", "javascript:", "mailto:", "tel:", "blob:")

TAG_RE = re.compile(r"<(img|source|script|video|audio|track|object|link|iframe)\b[^>]*>", re.I)
# 属性值可能带引号也可能不带：React 的服务端渲染会输出 src=https://x/y.png 这种裸值
ATTR_RE = re.compile(r"""(\b[a-zA-Z-]+\s*=\s*)(?:(["'])(.*?)\2|([^\s"'>]+))""", re.S)
IFRAME_RE = re.compile(r"<iframe\b[^>]*>.*?</iframe\s*>|<iframe\b[^>]*/?>", re.I | re.S)
RE_CSS_URL = re.compile(r"""url\(\s*(['"]?)([^)'"]+)\1\s*\)""")
RE_CSS_IMPORT = re.compile(r"""@import\s+(?:url\()?\s*['"]?([^'")\s;]+)""")

CTYPE_EXT = {
    "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/png": ".png",
    "image/gif": ".gif", "image/webp": ".webp", "image/svg+xml": ".svg",
    "image/avif": ".avif", "image/x-icon": ".ico", "image/vnd.microsoft.icon": ".ico",
    "text/css": ".css", "application/javascript": ".js", "text/javascript": ".js",
    "application/json": ".json", "video/mp4": ".mp4", "text/html": ".html",
}
PATH_EXT_RE = re.compile(r"\.(jpe?g|png|gif|webp|svg|avif|ico|css|js|json|mp4|webm|woff2?|ttf)$", re.I)


def is_external(url: str) -> bool:
    u = (url or "").strip()
    if not u or u.startswith(LOCAL_PREFIXES):
        return False
    if u.startswith("//"):
        return True
    if not re.match(r"^https?://", u, re.I):
        return False
    host = urllib.parse.urlsplit(u).hostname or ""
    return host not in ("localhost", "127.0.0.1")


class Downloader:
    def __init__(self, site: str, prefix: str, jobs: int, timeout: int) -> None:
        self.site = site
        self.prefix = prefix.strip("/")
        self.dest = os.path.join(site, *self.prefix.split("/"))
        os.makedirs(self.dest, exist_ok=True)
        self.jobs = jobs
        self.timeout = timeout
        self.lock = threading.Lock()
        self.mapping: dict[str, str] = {}      # 原 URL -> 站点内绝对路径
        self.failed: dict[str, str] = {}       # 原 URL -> 失败原因
        self.bytes = 0
        self.fetched = 0
        self.skipped = 0
        self._pending: set[str] = set()

    def _target(self, url: str, ctype: str = "") -> tuple[str, str]:
        h = hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]
        ext = CTYPE_EXT.get(ctype.split(";")[0].strip().lower(), "")
        if not ext:
            path = urllib.parse.urlsplit(url).path
            m = PATH_EXT_RE.search(path)
            ext = m.group(0).lower() if m else ".bin"
        return h + ext, f"/{self.prefix}/{h}{ext}"

    def _fetch(self, url: str) -> None:
        # 先看有没有已存在的同名文件（换扩展名的老缓存也认）
        h = hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]
        for name in os.listdir(self.dest):
            if name.startswith(h + ".") and os.path.getsize(os.path.join(self.dest, name)) > 0:
                with self.lock:
                    self.mapping[url] = f"/{self.prefix}/{name}"
                    self.skipped += 1
                return
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (compatible; offline-docs-builder)",
                "Accept": "image/*,text/css,*/*;q=0.8",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                data = r.read()
                ctype = r.headers.get("Content-Type", "")
            if not data:
                raise ValueError("空响应")
            if ctype.split(";")[0].strip().lower() == "text/html":
                # 一般只在内嵌页时出现；整页 HTML 下下来只会引入新的外链
                raise ValueError("返回 HTML，跳过")
            name, public = self._target(url, ctype)
            with open(os.path.join(self.dest, name), "wb") as fh:
                fh.write(data)
            with self.lock:
                self.mapping[url] = public
                self.bytes += len(data)
                self.fetched += 1
        except Exception as e:  # noqa: BLE001 - 失败不是错误，保留原链接即可
            reason = f"{type(e).__name__}: {e}"[:160]
            with self.lock:
                self.failed[url] = reason

    def collect(self, urls: set[str]) -> None:
        todo = sorted(u for u in urls if u not in self.mapping and u not in self.failed)
        if not todo:
            return
        print(f"[localize] 下载 {len(todo)} 个外链资源（并发 {self.jobs}）…")
        t0 = time.time()
        done = 0
        with ThreadPoolExecutor(max_workers=self.jobs) as pool:
            for _ in pool.map(self._fetch, todo):
                done += 1
                if done % 100 == 0:
                    print(f"[localize]   {done}/{len(todo)}，已失败 {len(self.failed)}", flush=True)
        print(f"[localize] 下载完成，用时 {time.time() - t0:.0f}s")

    def local(self, url: str) -> str | None:
        return self.mapping.get(url)


def rel_prefix(page_path: str, dest: str) -> str:
    """页面所在目录到外链副本目录的相对路径，如 '../..'。

    MkDocs 的 offline 插件让站点能从 file:// 直接打开，根路径 /assets/... 在那种
    场景下会指向磁盘根目录，所以一律写相对路径。
    """
    rel = os.path.relpath(dest, os.path.dirname(page_path)).replace(os.sep, "/")
    return "" if rel == "." else rel


def localize(loc: str | None, base: str) -> str | None:
    """把 /assets/external/x.png 拼成相对当前页面的路径。"""
    if not loc:
        return None
    name = loc.rsplit("/", 1)[-1]
    return f"{base}/{name}" if base else name


def rewrite_tag(tag: str, tag_name: str, dl: Downloader, found: set[str],
                base: str = "") -> str:
    """改写单个标签里所有会发请求的属性。"""
    tag_name = tag_name.lower()

    def attr_sub(m: re.Match) -> str:
        head = m.group(1)
        quote = m.group(2) or ""          # 裸值属性没有引号
        val = m.group(3) if m.group(3) is not None else m.group(4)
        name = head.strip().split("=")[0].strip().lower()
        if (tag_name, name) not in FETCH_ATTRS and not (tag_name == "link" and name == "href"):
            return m.group(0)
        if name == "srcset":
            parts = []
            changed = False
            for item in val.split(","):
                item = item.strip()
                if not item:
                    continue
                bits = item.split(None, 1)
                u = bits[0]
                desc = f" {bits[1]}" if len(bits) > 1 else ""
                if is_external(u):
                    found.add(u)
                    loc = localize(dl.local(u), base)
                    if loc:
                        parts.append(loc + desc)
                        changed = True
                        continue
                parts.append(item)
            if not changed:
                return m.group(0)
            return f"{head}{quote}{', '.join(parts)}{quote}"
        if not is_external(val):
            return m.group(0)
        if tag_name == "link":
            rel = re.search(r"""\brel\s*=\s*["']?([^"'\s>]+)""", tag, re.I)
            rels = set((rel.group(1) if rel else "").lower().split())
            if not (rels & FETCHING_LINK_REL):
                return m.group(0)
        found.add(val)
        loc = localize(dl.local(val), base)
        return f"{head}{quote}{loc or val}{quote}"

    return ATTR_RE.sub(attr_sub, tag)


def placeholder(url: str) -> str:
    """iframe 的离线替身：不发请求，只留一个能点开的链接。"""
    safe = url.replace('"', "&quot;")
    return (
        '<div class="offline-embed" style="border:1px dashed #bbb;border-radius:6px;'
        'padding:12px 14px;margin:1em 0;font-size:.9em;color:#666">'
        "离线构建已移除内嵌内容（断网时无法加载）。联网后可访问："
        f'<a href="{safe}" rel="noopener">{safe}</a></div>'
    )


def process_html(path: str, dl: Downloader, found: set[str], keep_iframes: bool,
                 stats: dict, collect_only: bool = False) -> bool:
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()
    original = text
    base = rel_prefix(path, dl.dest)

    if not keep_iframes:
        def iframe_sub(m: re.Match) -> str:
            src = re.search(r"""\bsrc\s*=\s*(["'])(.*?)\1|\bsrc\s*=\s*([^\s"'>]+)""", m.group(0), re.I)
            url = (src.group(2) or src.group(3)) if src else ""
            if url and is_external(url):
                # 内嵌页整页下下来没有意义（它自己还会带一堆外链），直接换成占位链接
                stats["iframes"] = stats.get("iframes", 0) + 1
                return placeholder(url)
            return m.group(0)

        text = IFRAME_RE.sub(iframe_sub, text)

    def tag_sub(m: re.Match) -> str:
        return rewrite_tag(m.group(0), m.group(1), dl, found, base)

    text = TAG_RE.sub(tag_sub, text)
    # <link>/<script> 里的 target_blank 之类无所谓，只看上面筛过的属性

    if collect_only:
        return False
    if text != original:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(text)
        stats["html_changed"] += 1
        return True
    return False


def process_css(path: str, dl: Downloader, found: set[str]) -> bool:
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()
    original = text
    base = rel_prefix(path, dl.dest)

    def url_sub(m: re.Match) -> str:
        u = m.group(2)
        if is_external(u):
            found.add(u)
            loc = localize(dl.local(u), base)
            if loc:
                return f"url({m.group(1)}{loc}{m.group(1)})"
        return m.group(0)

    def import_sub(m: re.Match) -> str:
        u = m.group(1)
        if is_external(u):
            found.add(u)
            loc = localize(dl.local(u), base)
            if loc:
                return f'@import url("{loc}")'
        return m.group(0)

    text = RE_CSS_URL.sub(url_sub, text)
    text = RE_CSS_IMPORT.sub(import_sub, text)
    if text != original:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(text)
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("site")
    ap.add_argument("--prefix", default="assets/external")
    ap.add_argument("--keep-iframes", action="store_true")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--json")
    args = ap.parse_args()

    root = os.path.abspath(args.site)
    if not os.path.isdir(root):
        print(f"目录不存在: {root}", file=sys.stderr)
        return 2

    dl = Downloader(root, args.prefix, args.jobs, args.timeout)
    stats = {"html": 0, "css": 0, "html_changed": 0, "css_changed": 0, "iframes": 0}

    html_files, css_files = [], []
    for dirpath, _dirnames, filenames in os.walk(root):
        if os.path.abspath(dirpath).startswith(dl.dest):
            continue  # 别去改刚下载下来的副本
        for name in filenames:
            if name.endswith((".html", ".htm")):
                html_files.append(os.path.join(dirpath, name))
            elif name.endswith(".css"):
                css_files.append(os.path.join(dirpath, name))

    # 两轮：第一轮只收集 URL（不落盘），第二轮才有本地副本可写
    found: set[str] = set()
    for p in html_files:
        process_html(p, dl, found, args.keep_iframes, {"iframes": 0}, collect_only=True)
    for p in css_files:
        process_css(p, dl, found)
    stats["html"], stats["css"] = len(html_files), len(css_files)

    dl.collect(found)

    # 第二轮：真正改写（此时 mapping 已就绪）
    stats["iframes"] = 0
    for p in html_files:
        process_html(p, dl, found, args.keep_iframes, stats)
    for p in css_files:
        if process_css(p, dl, found):
            stats["css_changed"] += 1

    total = len(found)
    ok, bad = len(dl.mapping), len(dl.failed)
    print(f"[localize] 外链资源 {total} 个：本地化 {ok} 个（{dl.bytes / 1048576:.1f} MB），"
          f"失败 {bad} 个，已有缓存 {dl.skipped} 个")
    print(f"[localize] 改写 html {stats['html_changed']}/{stats['html']}，"
          f"css {stats['css_changed']}/{stats['css']}，iframe 占位 {stats['iframes']} 处")
    if bad:
        by_host: dict[str, int] = {}
        for u in dl.failed:
            h = urllib.parse.urlsplit(u).hostname or u
            by_host[h] = by_host.get(h, 0) + 1
        for h, c in sorted(by_host.items(), key=lambda kv: -kv[1])[:8]:
            print(f"[localize]   下载失败 {h}: {c} 个")
        print("[localize] 失败项保留原 URL：联网时仍能显示，断网时只是缺图")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "site": root,
                    "found": total,
                    "localized": ok,
                    "failed": dl.failed,
                    "mb": round(dl.bytes / 1048576, 2),
                    **stats,
                },
                fh, ensure_ascii=False, indent=2,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
