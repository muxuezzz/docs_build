#!/usr/bin/env python3
"""合并旧 MANIFEST.tsv 与本次各矩阵 job 产出的 *.meta，生成新的 MANIFEST.tsv。

每次工作流只更新本次拉取的镜像，所以必须把旧清单里其余行保留下来。
没有任何新行且旧清单存在时，原样保留旧清单（避免一次全失败把索引清空）。
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

COLS = 10
HEADER = (
    "# ref\tfile\tsize\tsha256\tparts\tpartsizes\tdigest\tplatform"
    "\tload_tag\tupdated\n"
)


def read_rows(path: str) -> dict[str, list[str]]:
    rows: dict[str, list[str]] = {}
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != COLS:
                print(f"::warning::{path}:{lineno} 列数 {len(cols)} != {COLS}，已忽略",
                      file=sys.stderr)
                continue
            rows[cols[1]] = cols  # 以资产文件名为键
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", default="", help="旧 MANIFEST.tsv（可以不存在）")
    ap.add_argument("--meta", default="meta", help="存放 *.meta 的目录")
    ap.add_argument("--out", default="MANIFEST.tsv", help="输出文件")
    args = ap.parse_args()

    rows = read_rows(args.old)
    meta_files = sorted(glob.glob(os.path.join(args.meta, "*.meta")))
    fresh: dict[str, list[str]] = {}
    for path in meta_files:
        fresh.update(read_rows(path))

    if not meta_files and rows:
        print("::warning::本次没有任何新元数据，原样保留旧 MANIFEST.tsv")
    elif not meta_files and not rows:
        print("::warning::既没有新元数据也没有旧 MANIFEST.tsv，写出空清单")
    rows.update(fresh)

    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(HEADER)
        for cols in sorted(rows.values(), key=lambda c: c[0]):
            f.write("\t".join(cols) + "\n")
    print(f"MANIFEST.tsv: 共 {len(rows)} 个镜像，本次新增/更新 {len(fresh)} 行 "
          f"（来自 {len(meta_files)} 个元数据文件）")


if __name__ == "__main__":
    main()
