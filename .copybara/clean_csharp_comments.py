#!/usr/bin/env python3
"""Remove newly introduced C# comments using Roslyn; stage nothing and fail on uncertain syntax."""
import argparse
import json
from pathlib import Path
import subprocess


def clean(base, dll, report, apply=False):
    paths = subprocess.check_output(['git', 'diff', '--name-only', '-z', '--diff-filter=AM', base, 'HEAD']).decode().split('\0')
    paths = [p for p in paths if p.endswith('.cs')]
    process = subprocess.Popen(['dotnet', dll], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    results, pending = [], {}
    try:
        for name in paths:
            old = subprocess.run(['git', 'show', f'{base}:{name}'], capture_output=True)
            if old.returncode:
                exists = subprocess.run(['git', 'cat-file', '-e', f'{base}:{name}'], stderr=subprocess.DEVNULL).returncode == 0
                if exists:
                    raise RuntimeError(f'Cannot read base blob: {name}')
            path = Path(name)
            if path.is_symlink():
                raise RuntimeError(f'Unexpected symlink: {name}')
            data = path.read_bytes().decode('utf-8')
            process.stdin.write(json.dumps({'before': old.stdout.decode('utf-8') if old.returncode == 0 else '', 'after': data}) + '\n')
            process.stdin.flush()
            response = json.loads(process.stdout.readline())
            results.append({'path': name, 'removed': response.get('removed', 0), 'error': response.get('error')})
            if response.get('removed'):
                pending[name] = response['text'].encode('utf-8')
    finally:
        process.stdin.close()
        process.wait()
    Path(report).write_text(json.dumps(results, ensure_ascii=False, indent=2))
    errors = [r for r in results if r['error']]
    print(f'C# files: {len(paths)}; comment blocks: {sum(r["removed"] for r in results)}; uncertain files: {len(errors)}')
    # Apply only independently verified files. Uncertain files remain unchanged and reported.
    if apply:
        for name, content in pending.items():
            Path(name).write_bytes(content)
        print(f'Applied verified cleanup to {len(pending)} files; report: {report}')
    return bool(errors or (pending and not apply))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('base')
    parser.add_argument('dll')
    parser.add_argument('--report', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    raise SystemExit(clean(args.base, args.dll, args.report, args.apply))
