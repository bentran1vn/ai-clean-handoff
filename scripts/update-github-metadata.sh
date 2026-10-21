#!/usr/bin/env bash
# Run after authenticating gh. No code changes or releases are published.
set -euo pipefail
repo="${1:-bentran1vn/copybara-release-sync}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gh repo edit "$repo" \
  --description 'Clean handoff for AI-assisted teams: sync dev to client repos without agent configs or new comments, while preserving client-only files. Built on Copybara + Roslyn.' \
  --add-topic claude-code --add-topic codex --add-topic cursor --add-topic ai-coding \
  --add-topic agentic-coding --add-topic vibe-coding --add-topic copybara --add-topic git \
  --add-topic repository-sync --add-topic release-automation --add-topic code-cleanup \
  --add-topic developer-tools --add-topic devtools --add-topic csharp --add-topic dotnet \
  --add-topic roslyn --add-topic cli --add-topic ai-agents --add-topic llm-tools --add-topic clean-code
existing="$(gh issue list --repo "$repo" --state all --search 'in:title Roadmap: parser-backed TypeScript and JavaScript support' --json title,url --jq '.[] | select(.title == "Roadmap: parser-backed TypeScript and JavaScript support") | .url')"
if [ -z "$existing" ]; then
  gh issue create --repo "$repo" --title 'Roadmap: parser-backed TypeScript and JavaScript support' \
    --body-file "$project_dir/docs/roadmap/typescript.md"
else
  echo "Roadmap issue already exists: $existing"
fi
