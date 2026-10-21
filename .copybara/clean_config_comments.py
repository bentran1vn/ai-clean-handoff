#!/usr/bin/env python3
"""Remove new comments in the supported configuration/script formats, fail closed elsewhere."""
from collections import Counter
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import tokenize
import xml.etree.ElementTree as ET


def spans(name, text):
    suffix = Path(name).suffix
    if suffix == '.py':
        lines = text.split('\n')
        starts, pos = [], 0
        for line in lines:
            starts.append(pos); pos += len(line) + 1
        return [(starts[t.start[0]-1]+t.start[1], starts[t.end[0]-1]+t.end[1])
                for t in tokenize.generate_tokens(io.StringIO(text).readline) if t.type == tokenize.COMMENT and not (t.start[0] == 1 and t.string.startswith('#!'))]
    if suffix in ('.csproj', '.xml', '.md', '.mdx'):
        return [(m.start(), m.end()) for m in re.finditer(r'<!--[\s\S]*?-->', text)]
    if suffix == '.json':
        json.loads(text)
        return []
    hash_file = (suffix in ('.yml', '.yaml', '.sh', '.sln') or Path(name).name.startswith('.env') or name == '.gitignore' or name.startswith('.husky/'))
    if hash_file:
        pattern = r'(?m)^[ \t]*#(?!\!)[^\r\n]*' if name == '.gitignore' or suffix == '.sln' else r'(?m)(?<!\S)#(?!\!)[^\r\n]*'
        return [(m.start(), m.end()) for m in re.finditer(pattern, text)]
    raise ValueError(f'Unsupported format: {name}')


def semantic(name, text):
    ext = Path(name).suffix
    if ext == '.py':
        return [(t.type, t.string) for t in tokenize.generate_tokens(io.StringIO(text).readline)
                if t.type not in (tokenize.COMMENT, tokenize.NL, tokenize.ENCODING)]
    if ext in ('.yaml', '.yml'):
        result = subprocess.run(['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(STDIN.read, aliases: true))'], input=text, text=True, capture_output=True, check=True)
        return json.loads(result.stdout)
    if ext in ('.xml', '.csproj'):
        root = ET.fromstring(text)
        def normalized(node):
            return (node.tag, sorted(node.attrib.items()), (node.text or '').strip(), (node.tail or '').strip(), tuple(normalized(c) for c in node))
        return normalized(root)
    if ext == '.sh' or name.startswith('.husky/') or Path(name).name.startswith('.env'):
        if '<<' in text:
            raise ValueError(f'Here-document requires manual review: {name}')
        return list(shlex.shlex(text, posix=True))
    return None


def clean(base, report, apply=False):
    names = subprocess.check_output(['git','diff','--name-only','-z','--diff-filter=AM',base,'HEAD']).decode().split('\0')
    pending, results, errors = {}, [], []
    for name in filter(None, names):
        if name.endswith('.cs'):
            continue
        try:
            old = subprocess.run(['git','show',f'{base}:{name}'],capture_output=True)
            before = old.stdout.decode('utf-8') if old.returncode == 0 else ''
            after = Path(name).read_bytes().decode('utf-8')
            budget = Counter(before[a:b] for a,b in spans(name,before)) if before else Counter()
            cuts = []
            for a,b in spans(name,after):
                key=after[a:b]
                if budget[key]: budget[key]-=1
                else: cuts.append((a,b))
            cleaned=after
            for a,b in reversed(cuts):
                cleaned=cleaned[:a]+''.join(c if c in '\r\n' else ' ' for c in cleaned[a:b])+cleaned[b:]
            if cuts:
                if semantic(name,after) != semantic(name,cleaned):
                    raise ValueError(f'Semantic content changed: {name}')
                pending[name]=cleaned.encode('utf-8')
            results.append({'path':name,'removed':len(cuts)})
        except Exception as e:
            errors.append({'path':name,'error':str(e)})
    Path(report).write_text(json.dumps({'files':results,'errors':errors},ensure_ascii=False,indent=2))
    if apply:
        for name,content in pending.items(): Path(name).write_bytes(content)
    print(f'Config/script comments: {sum(r["removed"] for r in results)}; uncertain files: {len(errors)}; report: {report}')
    return bool(errors or (pending and not apply))

if __name__ == '__main__':
    import argparse
    p=argparse.ArgumentParser(); p.add_argument('base'); p.add_argument('--report',required=True); p.add_argument('--apply',action='store_true'); a=p.parse_args()
    raise SystemExit(clean(a.base,a.report,a.apply))
