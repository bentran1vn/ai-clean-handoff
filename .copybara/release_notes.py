#!/usr/bin/env python3
"""Draft a concise release scope from changed modules; review before publishing."""
import subprocess
import sys


def notes(base):
    raw = subprocess.check_output(['git', 'diff', '--name-only', '-z', base, 'HEAD'])
    paths = raw.decode().rstrip('\0').split('\0') if raw else []
    modules = set()
    for path in paths:
        parts = path.split('/')
        if 'usecases' in parts:
            index = parts.index('usecases')
            if len(parts) > index + 3:
                modules.add(parts[index + 2])
    bullets = [f'- Update `{name}` functionality.' for name in sorted(modules)]
    if any(p.startswith(('.docker/', 'scripts/')) for p in paths):
        bullets.append('- Update deployment and operational configuration.')
    if any('/Migrations/' in p for p in paths):
        bullets.append('- Update database migrations.')
    if not bullets:
        bullets = ['- Update application files. See Files changed for details.']
    return '\n'.join(['## Updates', '', *bullets, ''])


if __name__ == '__main__':
    print(notes(sys.argv[1]))
