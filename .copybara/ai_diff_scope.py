#!/usr/bin/env python3
"""Expose only added/replacement blocks to AI; apply edits at original offsets."""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def git(*args):
    return subprocess.check_output(['git', *args])


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(base, changed, root):
    root = Path(root)
    work = root / 'fragments'
    work.mkdir()
    entries, contexts = [], []
    for name in Path(changed).read_text().splitlines():
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or path.is_symlink():
            raise ValueError(f'Unsafe path: {name}')
        current = git('show', f'HEAD:{name}')
        exists = subprocess.run(['git', 'cat-file', '-e', f'{base}:{name}'],
                                stderr=subprocess.DEVNULL).returncode == 0
        old = git('show', f'{base}:{name}') if exists else b''
        try:
            before = old.decode('utf-8').splitlines(keepends=True)
            after = current.decode('utf-8').splitlines(keepends=True)
        except UnicodeDecodeError:
            raise ValueError(f'Non-UTF-8 file: {name}')
        if Path(name).read_bytes() != current:
            raise ValueError(f'Working tree differs from HEAD: {name}')
        for tag, a, b, c, d in difflib.SequenceMatcher(None, before, after, autojunk=False).get_opcodes():
            if tag not in ('insert', 'replace') or c == d:
                continue
            # Parser đã loại comment mới. Không gửi fragment chỉ còn khoảng trắng
            # hoặc code giống client, chỉ khác khoảng trắng cuối dòng.
            normalized_before = [line.rstrip() for line in before[a:b] if line.strip()]
            normalized_after = [line.rstrip() for line in after[c:d] if line.strip()]
            if not normalized_after or normalized_before == normalized_after:
                continue
            fragment = f'{len(entries):06d}{path.suffix}'
            content = ''.join(after[c:d])
            (work / fragment).write_bytes(content.encode('utf-8'))
            entries.append(dict(path=name, fragment=fragment, start=c, end=d,
                                source_hash=digest(current), original=content))
            contexts.append({'fragment': fragment, 'source': name, 'lines': [c + 1, d],
                             'before_context': ''.join(after[max(0, c-3):c]),
                             'old_client_lines': ''.join(before[a:b]),
                             'after_context': ''.join(after[d:d+3])})
    context = json.dumps(contexts, ensure_ascii=False, indent=2).encode('utf-8')
    (work / 'context.json').write_bytes(context)
    (root / 'manifest.json').write_text(json.dumps({'entries': entries, 'context_hash': digest(context)}))
    print(f'[ai-scope] {len(entries)} changed blocks from {len(set(e["path"] for e in entries))} files')


def apply(root):
    root = Path(root)
    work = root / 'fragments'
    manifest = json.loads((root / 'manifest.json').read_text())
    entries = manifest['entries']
    expected = {'context.json'} | {e['fragment'] for e in entries}
    actual = {p.name for p in work.iterdir()}
    if actual != expected or any(p.is_symlink() or not p.is_file() for p in work.iterdir()):
        raise ValueError('AI created/deleted files or symlinks')
    if digest((work / 'context.json').read_bytes()) != manifest['context_hash']:
        raise ValueError('AI changed read-only context')
    changes = {}
    for e in entries:
        path = Path(e['path'])
        if path.is_symlink() or digest(path.read_bytes()) != e['source_hash']:
            raise ValueError(f'Source changed during cleanup: {path}')
        data = (work / e['fragment']).read_bytes().decode('utf-8')
        if data == e['original']:
            continue
        # Prevent joining an unchanged following code line onto the edited comment.
        if data and e['original'].endswith('\n') and not data.endswith('\n'):
            raise ValueError('Replacement must preserve terminating newline')
        changes.setdefault(e['path'], []).append((e['start'], e['end'], data))
    outputs = {}
    for name, edits in changes.items():
        lines = Path(name).read_bytes().decode('utf-8').splitlines(keepends=True)
        for start, end, data in sorted(edits, reverse=True):
            lines[start:end] = [data]
        outputs[name] = ''.join(lines).encode('utf-8')
    for name, data in outputs.items():
        Path(name).write_bytes(data)
    print(f'[ai-scope] Applied edits to {len(outputs)} files; unchanged client lines preserved')


if __name__ == '__main__':
    if sys.argv[1] == 'prepare':
        prepare(*sys.argv[2:])
    elif sys.argv[1] == 'apply':
        apply(*sys.argv[2:])
    else:
        raise SystemExit('Expected prepare or apply')
