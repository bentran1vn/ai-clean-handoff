#!/usr/bin/env bash
# Chạy trong thư mục repo đích (đang checkout branch sync).
# 1) Gọi Claude Code hoặc Codex headless dọn dấu vết AI trong các file vừa sync
# 2) Guard: AI chỉ được sửa file trong danh sách + chỉ được đổi comment
# 3) (tuỳ chọn) chạy TEST_CMD
# Có bất kỳ vấn đề gì -> huỷ toàn bộ thay đổi của AI, sync vẫn tiếp tục.
#
# Usage: ai_cleanup.sh <changed_list> <prompt_file> <check_script> <client_base_ref>
# Env:   AI_ENGINE=claude|codex (mặc định claude)
#        AI_MODEL  (mặc định: claude -> claude-sonnet-5-5, codex -> gpt-6.1-sol)
#        AI_EFFORT (mặc định xhigh)
#        AI_STRICT=true|false, TEST_CMD
#        Chỉ claude: AI_MAX_TURNS, AI_MAX_BUDGET_USD (trần chi phí mỗi lần chạy, mặc định 2)
#        Đăng nhập: claude đã login hoặc ANTHROPIC_API_KEY; codex đã login hoặc OPENAI_API_KEY
set -uo pipefail

CHANGED_LIST="$1"
PROMPT_FILE="$2"
CHECK_SCRIPT="$3"
BASE_REF="${4:?Missing client base ref}"
SCOPE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ai_diff_scope.py"
STRICT="${AI_STRICT:-true}"
ENGINE="${AI_ENGINE:-claude}"
case "$ENGINE" in
  claude) MODEL="${AI_MODEL:-claude-sonnet-5-5}" ;;
  codex)  MODEL="${AI_MODEL:-gpt-6.1-sol}" ;;
  *) echo "[ai-cleanup] AI_ENGINE không hợp lệ: $ENGINE (claude hoặc codex)" >&2; exit 1 ;;
esac
EFFORT="${AI_EFFORT:-xhigh}"
REPORT="${RUNNER_TEMP:-/tmp}/ai_check.md"
AI_OUT="${RUNNER_TEMP:-/tmp}/ai_output.json"    # claude: 1 JSON · codex: JSONL các event
AI_LAST="${RUNNER_TEMP:-/tmp}/ai_last_message.txt"
AI_INFO=""   # "engine · model · effort · chi phí/token", ghi kèm AI_STATUS

status() {
  local msg="$1"
  [ -n "$AI_INFO" ] && msg="$msg ($AI_INFO)"
  echo "AI_STATUS=$msg" >> "${GITHUB_ENV:-/dev/null}"
  echo "[ai-cleanup] $msg"
}
revert() {
  git checkout -- . && git clean -fdq
}

: > "$REPORT"

if [ ! -s "$CHANGED_LIST" ]; then
  status "⏭️ Bỏ qua: không có file code/docs nào thay đổi"
  exit 0
fi

SCOPE_ROOT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ai-scope.XXXXXX")"
trap 'rm -rf "$SCOPE_ROOT"' EXIT
if ! "${PYTHON:-python3}" "$SCOPE_SCRIPT" prepare "$BASE_REF" "$CHANGED_LIST" "$SCOPE_ROOT"; then
  status "⚠️ Không tạo được diff scope; bỏ qua AI"
  exit 0
fi
if [ "$(find "$SCOPE_ROOT/fragments" -type f ! -name context.json | wc -l | tr -d ' ')" -eq 0 ]; then
  status "⏭️ Bỏ qua AI: không còn đoạn code/docs thay đổi sau khi lọc comment"
  exit 0
fi
PROMPT="$(cat "$PROMPT_FILE")"

echo "[ai-cleanup] Engine: $ENGINE · model: $MODEL · effort: $EFFORT"
: > "$AI_OUT"; : > "$AI_LAST"
if [ "$ENGINE" = "claude" ]; then
  (cd "$SCOPE_ROOT/fragments" && claude -p "$PROMPT" \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --output-format json \
    --allowedTools "Read,Edit,Glob,Grep" \
    --permission-mode acceptEdits \
    --max-turns "${AI_MAX_TURNS:-80}" \
    --max-budget-usd "${AI_MAX_BUDGET_USD:-2}" < /dev/null > "$AI_OUT")
  AI_RC=$?
else
  # Workspace chỉ chứa các đoạn thay đổi và ngữ cảnh, không chứa source repo.
  (cd "$SCOPE_ROOT/fragments" && codex exec "$PROMPT" \
    --skip-git-repo-check \
    --model "$MODEL" \
    -c model_reasoning_effort="$EFFORT" \
    -c approval_policy=never \
    --sandbox workspace-write \
    --ephemeral \
    --json \
    -o "$AI_LAST" < /dev/null > "$AI_OUT")
  AI_RC=$?
fi

# Dòng 1: is_error · dòng 2: AI_INFO · còn lại: tóm tắt của AI (ghi ra log)
PARSED="$("${PYTHON:-python3}" -I - "$ENGINE" "$MODEL" "$EFFORT" "$AI_OUT" "$AI_LAST" <<'PY'
import json, sys
engine, model, effort, out, last = sys.argv[1:6]
if engine == "claude":
    try:
        d = json.load(open(out, encoding="utf-8"))
    except Exception:
        print("true"); print(f"claude · {model} · {effort}"); sys.exit()
    # modelUsage cho biết model thực sự được dùng (có thể kèm model phụ)
    models = ", ".join(sorted((d.get("modelUsage") or {}).keys())) or model
    cost = d.get("total_cost_usd")
    print("true" if d.get("is_error") else "false")
    info = f"claude · {models} · {effort}"
    print(f"{info} · ${cost:.2f}" if isinstance(cost, (int, float)) else info)
    print(d.get("result") or "")
else:
    events = []
    for line in open(out, encoding="utf-8"):
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    types = [e.get("type") for e in events]
    failed = "turn.failed" in types or "error" in types or "turn.completed" not in types
    tokens = sum((e.get("usage") or {}).get(k, 0) or 0
                 for e in events if e.get("type") == "turn.completed"
                 for k in ("input_tokens", "output_tokens"))
    print("true" if failed else "false")
    print(f"codex · {model} · {effort} · {tokens:,} token")
    try:
        msg = open(last, encoding="utf-8").read().strip()
    except OSError:
        msg = ""
    errs = [(e.get("error") or {}).get("message") or e.get("message") or ""
            for e in events if e.get("type") in ("turn.failed", "error")]
    print(msg or "\n".join(m for m in errs if m))
PY
)"
AI_INFO="$(echo "$PARSED" | sed -n 2p)"
echo "$PARSED" | sed -n '3,$p' | sed "s/^/[$ENGINE] /"

if [ "$AI_RC" -ne 0 ] || [ "$(echo "$PARSED" | sed -n 1p)" != "false" ]; then
  revert
  status "⚠️ $ENGINE lỗi, đã bỏ qua bước AI (sync vẫn giữ nguyên)"
  exit 0
fi

if ! "${PYTHON:-python3}" "$SCOPE_SCRIPT" apply "$SCOPE_ROOT"; then
  revert
  status "↩️ Đã huỷ thay đổi của AI: sửa ngoài diff scope hoặc output không hợp lệ"
  exit 0
fi

TOUCHED="$( { git diff --name-only; git ls-files --others --exclude-standard; } | sort -u )"
if [ -z "$TOUCHED" ]; then
  status "✅ AI không tìm thấy dấu vết cần dọn"
  exit 0
fi

OUTSIDE="$(echo "$TOUCHED" | grep -vxF -f "$CHANGED_LIST" || true)"
if [ -n "$OUTSIDE" ]; then
  revert
  status "↩️ Đã huỷ thay đổi của AI: sửa file ngoài phạm vi ($(echo "$OUTSIDE" | tr '\n' ' '))"
  exit 0
fi

CHECK_ARGS=(--report "$REPORT")
[ "$STRICT" = "true" ] && CHECK_ARGS+=(--strict)
if ! "${PYTHON:-python3}" "$CHECK_SCRIPT" "${CHECK_ARGS[@]}"; then
  revert
  status "↩️ Đã huỷ thay đổi của AI: AI đổi cả dòng code, không chỉ comment (chi tiết bên dưới)"
  exit 0
fi

if [ -n "${TEST_CMD:-}" ]; then
  echo "[ai-cleanup] Running: $TEST_CMD"
  if ! bash -c "$TEST_CMD"; then
    revert
    status "↩️ Đã huỷ thay đổi của AI: TEST_CMD fail sau khi dọn"
    exit 0
  fi
fi

status "🧹 AI đã dọn $(echo "$TOUCHED" | wc -l | tr -d ' ') file"
