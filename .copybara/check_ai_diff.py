#!/usr/bin/env python3
"""Kiểm tra thay đổi AI vừa làm (working tree so với HEAD): chỉ được đổi comment/docs.

Cách kiểm: với mỗi file, bỏ hết dòng comment và phần comment cuối dòng, bỏ khoảng trắng,
rồi so tập "dòng code" bị xoá với tập "dòng code" được thêm. Nếu hai tập khác nhau
nghĩa là AI đã đụng vào code thật.

Đây là heuristic: docstring Python nhiều dòng hoặc chuỗi chứa "//" có thể bị báo nhầm,
nên report luôn liệt kê dòng cụ thể để người review tự xem.

Usage: python3 check_ai_diff.py [--strict] [--report out.md]
  --strict  exit 1 nếu phát hiện dòng code bị đổi
"""
import argparse
import os
import re
import subprocess
import sys
from collections import Counter

DOC_EXT = {".md", ".mdx", ".txt", ".rst"}
HASH_EXT = {".py", ".sh", ".bash", ".rb", ".yml", ".yaml", ".toml", ".ps1", ".r", ".pl"}
SQL_EXT = {".sql"}

BLOCK_PREFIXES = ("/*", "*", "*/", "<!--", "-->", '"""', "'''")


def markers(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in HASH_EXT:
        return "#"
    if ext in SQL_EXT:
        return "--"
    return "//"


def is_comment(line, mk):
    s = line.strip()
    return not s or s.startswith(mk) or s.startswith(BLOCK_PREFIXES)


def normalize(line, mk):
    """Bỏ comment cuối dòng + toàn bộ khoảng trắng để so sánh."""
    if mk == "//":
        line = re.sub(r"(?<!:)//.*$", "", line)          # không cắt "https://"
        line = re.sub(r"/\*.*?\*/", "", line)
    elif mk == "#":
        line = re.sub(r"\s#.*$", "", line)
    elif mk == "--":
        line = re.sub(r"\s--.*$", "", line)
    return re.sub(r"\s+", "", line)


def parse_diff(diff_text):
    files, cur = {}, None
    for raw in diff_text.splitlines():
        if raw.startswith("+++ "):
            p = raw[4:]
            cur = None if p == "/dev/null" else p[2:] if p.startswith("b/") else p
            if cur:
                files.setdefault(cur, {"-": [], "+": []})
        elif raw.startswith("--- ") or raw.startswith("diff --git") or raw.startswith("@@"):
            continue
        elif cur and raw[:1] in "+-":
            files[cur][raw[0]].append(raw[1:])
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    diff = subprocess.run(["git", "diff", "-U0", "--no-color", "--no-ext-diff"],
                          capture_output=True, text=True, check=True).stdout
    files = parse_diff(diff)

    problems = {}
    stats = Counter()
    for path, ch in files.items():
        stats["files"] += 1
        if os.path.splitext(path)[1].lower() in DOC_EXT:
            stats["doc_files"] += 1
            continue
        mk = markers(path)
        removed = Counter(normalize(l, mk) for l in ch["-"] if not is_comment(l, mk))
        added = Counter(normalize(l, mk) for l in ch["+"] if not is_comment(l, mk))
        removed.pop("", None)
        added.pop("", None)
        if removed != added:
            gone = [l for l in ch["-"] if not is_comment(l, mk) and (removed - added)[normalize(l, mk)]]
            new = [l for l in ch["+"] if not is_comment(l, mk) and (added - removed)[normalize(l, mk)]]
            problems[path] = (gone[:10], new[:10])
        stats["comment_lines_removed"] += sum(1 for l in ch["-"] if is_comment(l, mk) and l.strip())

    lines = [
        f"- File AI đã sửa: **{stats['files']}** (trong đó {stats['doc_files']} file docs)",
        f"- Dòng comment bị xoá/sửa: **{stats['comment_lines_removed']}**",
    ]
    if problems:
        lines.append(f"- ⚠️ **{len(problems)} file có dòng code bị đổi** (không chỉ comment):")
        for path, (gone, new) in problems.items():
            lines.append(f"  - `{path}`")
            for l in gone:
                lines.append(f"    - `- {l.strip()[:120]}`")
            for l in new:
                lines.append(f"    - `+ {l.strip()[:120]}`")
    else:
        lines.append("- ✅ Không có dòng code thực thi nào bị đổi")

    report = "\n".join(lines)
    print(report)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            f.write(report + "\n")

    if problems and args.strict:
        sys.exit(1)


if __name__ == "__main__":
    main()
