#!/usr/bin/env python3
"""Preserve client files absent from the release; never infer permission to delete."""
import argparse
import os
from pathlib import Path
import subprocess


def deleted(base):
    data = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '--diff-filter=D', '-z', base, 'HEAD'])
    return [p for p in data.split(b'\0') if p]


def preserve(base, apply=False):
    paths = deleted(base)
    if not paths:
        return 0
    if not apply:
        print(f'Blocked: release deletes {len(paths)} client files.')
        for path in paths:
            print(os.fsdecode(path))
        return 1
    if subprocess.check_output(['git', 'status', '--porcelain', '-z']):
        raise RuntimeError('Working tree must be clean before preserving client files')
    # A file/directory collision must not overwrite newly synced source files.
    for raw in paths:
        path = Path(os.fsdecode(raw))
        if path.exists() or path.is_symlink():
            raise RuntimeError(f'Cannot restore client file: conflicting path {path}')
        for parent in path.parents:
            if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                raise RuntimeError(f'Cannot restore client file: conflicting parent {parent}')
    subprocess.run(['git', '--literal-pathspecs', 'restore', '--source', base, '--staged', '--worktree',
                    '--pathspec-from-file=-', '--pathspec-file-nul'],
                   input=b'\0'.join(paths)+b'\0', check=True)
    print(f'Preserved {len(paths)} client files with original contents and Git file modes.')
    return 0


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('base')
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    raise SystemExit(preserve(a.base, a.apply))
