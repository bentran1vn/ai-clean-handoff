#!/usr/bin/env python3
"""Đọc REPOS và biến cấu hình từ copy.bara.sky (Starlark là tập con cú pháp Python).

Usage:
  cfg.py <config> repos          -> mỗi dòng: name<TAB>source_url<TAB>source_ref<TAB>dest_url<TAB>dest_base
  cfg.py <config> get <VAR>      -> giá trị chuỗi của biến top-level
  cfg.py <config> check          -> kiểm tra cấu hình, exit 1 nếu sai
"""
import ast
import sys


def load(path):
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=path)
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            try:
                values[node.targets[0].id] = ast.literal_eval(node.value)
            except ValueError:
                pass  # biểu thức không phải literal (glob(), phép nối chuỗi...) -> bỏ qua
    return values


def repos(values):
    out = []
    for r in values.get("REPOS", []):
        out.append({
            "name": r["name"],
            "source_url": r["source_url"],
            "source_ref": r.get("source_ref", "main"),
            "dest_url": r["dest_url"],
            "dest_base": r.get("dest_base", "main"),
        })
    return out


def check(values):
    errors = []
    rs = values.get("REPOS")
    if not isinstance(rs, list) or not rs:
        errors.append("REPOS trống hoặc không đọc được (giữ cú pháp {\"key\": \"value\"})")
        rs = []
    names = set()
    for i, r in enumerate(rs, 1):
        for k in ("name", "source_url", "dest_url"):
            if not r.get(k):
                errors.append(f"REPOS[{i}] thiếu '{k}'")
        for k in ("source_url", "dest_url"):
            if "<" in str(r.get(k, "")):
                errors.append(f"REPOS[{i}] ({r.get('name')}): chưa điền {k}")
        if r.get("source_url") and r.get("source_url") == r.get("dest_url"):
            errors.append(f"REPOS[{i}] ({r.get('name')}): source_url trùng dest_url")
        if r.get("name") in names:
            errors.append(f"Trùng name: {r.get('name')}")
        names.add(r.get("name"))
    da = values.get("DEFAULT_AUTHOR", "")
    if "<" not in da or ">" not in da:
        errors.append("DEFAULT_AUTHOR phải có dạng: Tên <email>")
    for k, v in (values.get("AUTHOR_MAP") or {}).items():
        if "<" not in v or ">" not in v:
            errors.append(f"AUTHOR_MAP['{k}'] phải có dạng: Tên <email>")
    return errors


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    values = load(sys.argv[1])
    cmd = sys.argv[2]
    if cmd == "repos":
        for r in repos(values):
            print("\t".join([r["name"], r["source_url"], r["source_ref"], r["dest_url"], r["dest_base"]]))
    elif cmd == "get":
        v = values.get(sys.argv[3], "")
        print(v if isinstance(v, str) else "")
    elif cmd == "check":
        errs = check(values)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1 if errs else 0)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
