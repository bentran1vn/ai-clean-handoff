#!/usr/bin/env python3
"""Check or clean the supported backend formats. Unknown formats fail closed."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

p = argparse.ArgumentParser()
p.add_argument('base')
p.add_argument('--report', required=True)
p.add_argument('--apply', action='store_true')
a = p.parse_args()
scripts = Path(__file__).resolve().parent
artifacts = Path(tempfile.gettempdir()) / 'copybara-comment-policy-build'
subprocess.run(['dotnet','build',str(scripts/'comment-cleaner/CommentCleaner.csproj'),'--artifacts-path',str(artifacts),'--nologo','-v','quiet'],check=True)
dll=artifacts/'bin/CommentCleaner/debug/CommentCleaner.dll'
report=Path(a.report)
rc=0
for tool, extra in [('clean_csharp_comments.py',[str(dll)]),('clean_config_comments.py',[])]:
    command=[sys.executable,str(scripts/tool),a.base,*extra,'--report',str(report)+'.'+tool+'.json']
    if a.apply: command.append('--apply')
    rc |= subprocess.run(command).returncode
report.write_text('Comment policy '+('FAILED' if rc else 'PASSED')+'\nSee adjacent JSON reports.\n')
raise SystemExit(rc)
