#!/usr/bin/env bash
# =====================================================================
# Sync nhiều cặp repo (dev -> bàn giao client) bằng Copybara + AI cleanup, chạy local.
# Dùng git credential / SSH key và tài khoản Claude Code đã login sẵn trên máy.
#
#   sync-local.sh                      sync + tự dọn comment -> dừng cho bạn review
#   sync-local.sh backend frontend chỉ sync các repo được chọn
#   sync-local.sh --push               push kết quả đã review + mở PR (mọi repo đang chờ)
#   sync-local.sh --push --direct      push thẳng vào branch đích (bỏ PR)
#   sync-local.sh --auto               sync + AI + push + PR một lèo (cho cron/CI)
#   sync-local.sh --list               liệt kê repo trong config
#
# Tuỳ chọn:
#   --clean-comments     dọn comment mới trên bản review hiện có, không gọi AI/push
#   --skip-ai            không gọi AI (mặc định); vẫn tự động dọn comment
#   --ai <claude|codex>  bật thêm AI cleanup; mặc định không gọi AI
#   --init <sha>         lần đầu (1 repo): sync các commit SAU <sha> của repo nguồn
#   --init-history       lần đầu: sync toàn bộ lịch sử
#   --squash             đưa repo đích lên bản MỚI NHẤT của nguồn trong 1 commit
#                        (không lộ lịch sử commit). Hợp cho lần đầu khi client đã outdate.
#   --no-pr              khi push: chỉ push branch, không mở PR
#   --direct             khi push: đẩy thẳng vào branch đích (fast-forward only)
#   --open               mở các thư mục review bằng VS Code
#   -h, --help
#
# Biến môi trường (hoặc .copybara/local.env):
#   COPYBARA_VERSION, TEST_CMD, AI_ENGINE, AI_MODEL, AI_EFFORT, AI_STRICT, AI_MAX_FILES, SYNC_HOME, CONFIG
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/local.env" ] && set -a && . "$SCRIPT_DIR/local.env" && set +a

CONFIG="${CONFIG:-$SCRIPT_DIR/copy.bara.sky}"
LATEST_CB="v20260907"     # cần Java 25
JAVA21_CB="v20260727"     # bản cuối chạy được Java 21
SYNC_HOME="${SYNC_HOME:-$HOME/.cache/copybara-sync}"

export AI_ENGINE="${AI_ENGINE:-claude}"
MODE="sync"; SKIP_AI=true; NO_PR=false; DIRECT=false; OPEN=false; SQUASH=false
EXTRA_ARGS=(); SELECTED=(); INIT_SHA=""

c_blue=$'\e[34m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_bold=$'\e[1m'; c_off=$'\e[0m'
step() { echo "${c_blue}  ▸ $*${c_off}"; }
ok()   { echo "${c_green}  ✓ $*${c_off}"; }
warn() { echo "${c_yellow}  ! $*${c_off}"; }
fail() { echo "${c_red}✗ $*${c_off}" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --push) MODE="push" ;;
    --clean-comments) MODE="clean" ;;
    --auto) MODE="auto" ;;
    --list) MODE="list" ;;
    --skip-ai) SKIP_AI=true ;;
    --ai) [ $# -ge 2 ] || fail "--ai cần claude hoặc codex"; AI_ENGINE="$2"; SKIP_AI=false; shift ;;
    --init) [ $# -ge 2 ] || fail "--init cần <sha>"; INIT_SHA="$2"; EXTRA_ARGS+=(--force --last-rev "$2"); shift ;;
    --init-history) EXTRA_ARGS+=(--force --init-history) ;;
    --squash) SQUASH=true; EXTRA_ARGS+=(--force --squash --squash-skip-history) ;;
    --no-pr) NO_PR=true ;;
    --direct) DIRECT=true ;;
    --open) OPEN=true ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) fail "Tham số không hợp lệ: $1 (xem --help)" ;;
    *) SELECTED+=("$1") ;;
  esac
  shift
done

# ---------- Python (đọc config + guard) ----------
if command -v python3 >/dev/null 2>&1 && python3 -c "" >/dev/null 2>&1; then PYTHON=python3
elif command -v python >/dev/null 2>&1; then PYTHON=python
else fail "Thiếu Python 3"; fi
export PYTHON
cfg() { "$PYTHON" -I "$SCRIPT_DIR/cfg.py" "$CONFIG" "$@"; }

[ -f "$CONFIG" ] || fail "Không thấy $CONFIG"
if ! cfg check; then fail "copy.bara.sky chưa đúng (xem lỗi bên trên)"; fi

# ---------- danh sách repo ----------
R_NAME=(); R_SRC=(); R_SREF=(); R_DEST=(); R_DBASE=()
while IFS=$'\t' read -r n s sr d db; do
  R_NAME+=("$n"); R_SRC+=("$s"); R_SREF+=("$sr"); R_DEST+=("$d"); R_DBASE+=("$db")
done < <(cfg repos)

if [ "$MODE" = "list" ]; then
  for i in "${!R_NAME[@]}"; do
    printf "%-24s %s (%s)\n%-24s → %s (%s)\n" "${R_NAME[$i]}" "${R_SRC[$i]}" "${R_SREF[$i]}" "" "${R_DEST[$i]}" "${R_DBASE[$i]}"
  done
  exit 0
fi

TARGETS=()
if [ ${#SELECTED[@]} -eq 0 ]; then
  TARGETS=("${!R_NAME[@]}")
else
  for s in "${SELECTED[@]}"; do
    found=""
    for i in "${!R_NAME[@]}"; do [ "${R_NAME[$i]}" = "$s" ] && found="$i"; done
    [ -n "$found" ] || fail "Không có repo '$s' trong config. Xem: $0 --list"
    TARGETS+=("$found")
  done
fi
if $SQUASH && [ -n "$INIT_SHA" ]; then fail "Dùng --squash HOẶC --init <sha>, không dùng cả hai"; fi
if [ -n "$INIT_SHA" ] && [ ${#TARGETS[@]} -ne 1 ]; then
  fail "--init <sha> chỉ dùng cho 1 repo, vd: $0 backend --init $INIT_SHA"
fi

# ---------- identity: committer + commit dọn dẹp ----------
DEFAULT_AUTHOR="$(cfg get DEFAULT_AUTHOR)"
ID_NAME="$(echo "$DEFAULT_AUTHOR" | sed -E 's/^[[:space:]]*(.*[^[:space:]])[[:space:]]*<.*$/\1/')"
ID_EMAIL="$(echo "$DEFAULT_AUTHOR" | sed -nE 's/.*<([^>]+)>.*/\1/p')"

# Java trên Windows (Git Bash) cần path dạng C:/... thay vì /c/...
jpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
furl()  { local p; p="$(jpath "$1")"; case "$p" in /*) echo "file://$p" ;; *) echo "file:///$p" ;; esac; }

mkdir -p "$SYNC_HOME"
RESULTS="$(mktemp "${TMPDIR:-/tmp}/copybara-sync.XXXXXX")"
trap 'rm -f "$RESULTS"' EXIT

# =====================================================================
# Môi trường (chỉ khi cần chạy Copybara)
# =====================================================================
JAR=""
prepare_env() {
  echo "${c_bold}Môi trường${c_off}"
  command -v git >/dev/null || fail "Thiếu git"
  # Copybara gọi git init --ref-format=files; Apple Git cũ chưa hỗ trợ.
  # Chỉ đổi PATH trong tiến trình sync, không sửa cấu hình shell của người dùng.
  local git_probe git_candidate
  git_probe="$(mktemp -d "${TMPDIR:-/tmp}/copybara-git-check.XXXXXX")"
  if ! git init -q --bare --ref-format=files "$git_probe/repo.git" > "$git_probe/error.log" 2>&1; then
    for git_candidate in /opt/homebrew/bin/git /usr/local/bin/git; do
      [ -x "$git_candidate" ] || continue
      if "$git_candidate" init -q --bare --ref-format=files "$git_probe/alternative.git" >/dev/null 2>&1; then
        export PATH="$(dirname "$git_candidate"):$PATH"
        break
      fi
    done
    if ! git init -q --bare --ref-format=files "$git_probe/verify.git" >/dev/null 2>&1; then
      rm -rf "$git_probe"
      fail "$(git --version) không hỗ trợ git init --ref-format=files mà Copybara cần. Trên macOS: brew install git, rồi chạy lại lệnh sync."
    fi
  fi
  rm -rf "$git_probe"
  command -v dotnet >/dev/null || fail "Cần .NET SDK 9 để dọn comment C#"
  command -v ruby >/dev/null || fail "Cần Ruby để kiểm tra cấu hình YAML"
  command -v java >/dev/null || fail "Thiếu Java (cần 25+, hoặc 21+ với Copybara $JAVA21_CB)"
  local jv; jv="$(java -version 2>&1 | grep -E 'version "' | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
  [ -n "$jv" ] || fail "Không đọc được phiên bản Java"
  if [ -z "${COPYBARA_VERSION:-}" ]; then
    if [ "$jv" -ge 25 ]; then COPYBARA_VERSION="$LATEST_CB"
    elif [ "$jv" -ge 21 ]; then COPYBARA_VERSION="$JAVA21_CB"; warn "Java $jv -> dùng Copybara $JAVA21_CB (cài Java 25 để dùng bản mới)"
    else fail "Java $jv quá cũ, cần 21+"; fi
  fi
  if ! $SKIP_AI; then
    case "$AI_ENGINE" in
      claude) command -v claude >/dev/null || fail "Thiếu Claude Code CLI. Cài: npm i -g @anthropic-ai/claude-code rồi chạy 'claude' để login. Hoặc dùng --skip-ai." ;;
      codex)  command -v codex >/dev/null || fail "Thiếu Codex CLI. Cài: npm i -g @openai/codex rồi chạy 'codex login'. Hoặc dùng --skip-ai." ;;
      *) fail "AI_ENGINE không hợp lệ: $AI_ENGINE (claude hoặc codex)" ;;
    esac
  fi
  JAR="$SYNC_HOME/copybara_deploy-$COPYBARA_VERSION.jar"
  if [ ! -s "$JAR" ]; then
    step "Tải Copybara $COPYBARA_VERSION"
    curl -fL --progress-bar -o "$JAR.part" \
      "https://github.com/google/copybara/releases/download/$COPYBARA_VERSION/copybara_deploy.jar"
    mv "$JAR.part" "$JAR"
  fi
  ok "Java $jv · Copybara $COPYBARA_VERSION · AI: $($SKIP_AI && echo tắt || echo "$AI_ENGINE") · ${#TARGETS[@]} repo"
}

# =====================================================================
# Xử lý 1 repo (chạy trong subshell: lỗi ở repo này không chặn repo khác)
# =====================================================================
repo_main() {
  local i="$1"
  NAME="${R_NAME[$i]}"; SRC_URL="${R_SRC[$i]}"; DEST_URL="${R_DEST[$i]}"; DEST_BASE="${R_DBASE[$i]}"
  DEST_REPO="$(echo "$DEST_URL" | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')"
  WORK="$SYNC_HOME/$NAME-$(printf '%s' "$DEST_URL" | cksum | cut -d' ' -f1)"
  MIRROR="$WORK/dest.git"; REVIEW="$WORK/review"; TMPD="$WORK/tmp"; PENDING="$WORK/pending_branch"
  mkdir -p "$WORK" "$TMPD"

  # die trong repo: ghi kết quả rồi thoát subshell
  die() { echo "${c_red}  ✗ $*${c_off}" >&2; echo "$NAME|❌ lỗi|$*" >> "$RESULTS"; exit 1; }
  result() { echo "$NAME|$1|${2:-}" >> "$RESULTS"; }

  echo; echo "${c_bold}━━ $NAME${c_off}  ${SRC_URL##*/} → ${DEST_URL##*/}"
  case "$MODE" in
    push) push_pending ;;
    clean) clean_pending ;;
    sync) run_sync ;;
    auto) run_sync; [ -f "$PENDING" ] && push_pending ;;
  esac
  return 0
}

clean_review() {
  [ -d "$REVIEW/.git" ] || die "Chưa có bản review"
  cd "$REVIEW"
  [ -z "$(git status --porcelain)" ] || die "Working tree có thay đổi; cần xử lý trước khi dọn comment"
  "$PYTHON" "$SCRIPT_DIR/comment_policy.py" "origin/$DEST_BASE" --report "$TMPD/new_comments.txt" --apply \
    || die "Chưa dọn được hết; xem báo cáo và working tree. Chưa commit hoặc push."
  if [ -n "$(git diff --name-only)" ]; then
    git add -u
    GIT_AUTHOR_NAME="$ID_NAME" GIT_AUTHOR_EMAIL="$ID_EMAIL" \
    GIT_COMMITTER_NAME="$ID_NAME" GIT_COMMITTER_EMAIL="$ID_EMAIL" \
      git commit -q -m "chore: remove newly introduced comments"
  fi
}

clean_pending() {
  clean_review
  result "👀 đã dọn comment, chờ review" "$REVIEW"
}

push_pending() {
  if [ ! -f "$PENDING" ] || [ ! -d "$REVIEW/.git" ]; then
    result "⏭️ không có gì chờ push"; return 0
  fi
  local branch; branch="$(cat "$PENDING")"
  cd "$REVIEW"
  [ -z "$(git status --porcelain)" ] || die "Working tree có thay đổi chưa commit; chặn push"
  git fetch -q origin "$DEST_BASE" || die "Không cập nhật được nhánh đích để kiểm tra trước push"
  "$PYTHON" "$SCRIPT_DIR/preserve_client_files.py" "origin/$DEST_BASE" \
    || die "Chặn push: bản release đang xoá file khách. Chạy lại sync để giữ file."
  "$PYTHON" "$SCRIPT_DIR/comment_policy.py" "origin/$DEST_BASE" --report "$TMPD/new_comments.txt" \
    || die "Chặn push: còn comment mới/thay đổi so với khách. Xem $TMPD/new_comments.txt"
  if $DIRECT; then
    step "Push thẳng vào $DEST_BASE"
    git fetch -q origin "$DEST_BASE"
    git merge-base --is-ancestor "origin/$DEST_BASE" HEAD \
      || die "$DEST_BASE ở repo đích đã thay đổi từ lúc sync. Chạy lại sync rồi push."
    git push -q "$DEST_URL" "HEAD:refs/heads/$DEST_BASE" || die "Push thất bại"
    result "🚀 đã push vào $DEST_BASE"
  else
    step "Push branch $branch"
    git push -q "$DEST_URL" "HEAD:refs/heads/$branch" || die "Push thất bại"
    if $NO_PR; then
      result "🚀 đã push branch" "$branch"
    else
      command -v gh >/dev/null 2>&1 || die "Cần GitHub CLI (gh) để mở PR, hoặc dùng --no-pr"
      [ -n "$DEST_REPO" ] || die "dest_url không phải repo GitHub, dùng --no-pr"
      local url
      url="$(gh pr create -R "$DEST_REPO" --base "$DEST_BASE" --head "$branch" \
              --title "Release $(date +%Y-%m-%d)" --body-file "$TMPD/pr_body.md")" || die "Mở PR thất bại"
      warn "Khi merge: chọn Rebase and merge hoặc Create a merge commit để giữ GitOrigin-RevId."
      result "🔀 đã mở PR" "$url"
    fi
  fi
  rm -f "$PENDING"
  git -C "$MIRROR" fetch -q origin "+refs/heads/*:refs/heads/*" --prune || true
}

run_sync() {
  # Không để bản sync lỗi kế thừa trạng thái chờ push của lần trước.
  rm -f "$PENDING"
  # ---------- mirror repo đích (Copybara ghi vào đây, chưa đụng GitHub) ----------
  step "Cập nhật mirror repo đích"
  if [ ! -d "$MIRROR" ]; then
    git clone -q --bare "$DEST_URL" "$MIRROR" || die "Không clone được $DEST_URL (sai URL hoặc chưa có quyền?)"
  else
    git -C "$MIRROR" fetch -q origin "+refs/heads/*:refs/heads/*" --prune || die "Không fetch được $DEST_URL"
  fi
  git -C "$MIRROR" rev-parse -q --verify "refs/heads/$DEST_BASE" >/dev/null \
    || die "Repo đích chưa có branch '$DEST_BASE' (cần ít nhất 1 commit)"

  # ---------- nhớ --init cho tới khi branch đích có label GitOrigin-RevId ----------
  local init_file="$WORK/init_args" args=()
  [ ${#EXTRA_ARGS[@]} -gt 0 ] && args=("${EXTRA_ARGS[@]}")
  if [ -n "$(git -C "$MIRROR" log "$DEST_BASE" --grep='GitOrigin-RevId' -1 --format=%h 2>/dev/null)" ]; then
    rm -f "$init_file"
  elif [ ${#args[@]} -gt 0 ]; then
    printf '%s\n' "${args[@]}" > "$init_file"
  elif [ -f "$init_file" ]; then
    while IFS= read -r a; do args+=("$a"); done < "$init_file"
    warn "$DEST_BASE chưa có commit sync nào được merge -> dùng lại: ${args[*]}"
  fi

  # ---------- Copybara ----------
  local branch="release/$(date +%Y-%m-%d-%H%M%S)"
  step "Copybara migrate"
  set +e
  java -jar "$(jpath "$JAR")" migrate "$(jpath "$CONFIG")" "$NAME" \
    --output-root "$(jpath "$TMPD/copybara-work")" \
    --git-destination-url "$(furl "$MIRROR")" \
    --git-destination-push "$branch" \
    --git-committer-name "$ID_NAME" --git-committer-email "$ID_EMAIL" \
    ${args[@]+"${args[@]}"} 2>&1 | grep -vE '^Picked up JAVA_TOOL_OPTIONS' > "$TMPD/copybara.log"
  local code=${PIPESTATUS[0]}
  set -e
  if [ "$code" -eq 4 ]; then
    ok "Không có commit mới"
    rm -f "$PENDING"
    result "✅ không có gì mới"
    return 0
  elif [ "$code" -ne 0 ]; then
    tail -15 "$TMPD/copybara.log" | sed 's/^/    /'
    die "Copybara lỗi (exit $code). Log: $TMPD/copybara.log"
  fi

  # ---------- bản review ----------
  rm -rf "$REVIEW"
  git clone -q "$MIRROR" "$REVIEW" -b "$branch"
  git -C "$REVIEW" remote set-url origin "$DEST_URL"
  git -C "$REVIEW" fetch -q origin "$DEST_BASE" 2>/dev/null || true
  local base_ref="origin/$DEST_BASE"
  cd "$REVIEW"

  # commit squash: thay message mặc định của Copybara, giữ nguyên dòng GitOrigin-RevId
  if printf '%s\n' "${args[@]+"${args[@]}"}" | grep -qx -- "--squash"; then
    local label; label="$(git log -1 --format=%B | grep -E '^GitOrigin-RevId:' | tail -1)"
    if [ -n "$label" ]; then
      GIT_AUTHOR_NAME="$ID_NAME" GIT_AUTHOR_EMAIL="$ID_EMAIL" \
      GIT_COMMITTER_NAME="$ID_NAME" GIT_COMMITTER_EMAIL="$ID_EMAIL" \
        git commit -q --amend --reset-author -m "${SQUASH_MESSAGE:-chore: update to latest version ($(date +%Y-%m-%d))}" -m "$label"
    fi
  fi

  step "Giữ lại file chỉ có ở repo khách"
  "$PYTHON" "$SCRIPT_DIR/preserve_client_files.py" "$base_ref" --apply \
    || die "Không thể giữ file khách an toàn; dừng để review xung đột đường dẫn"
  if ! git diff --cached --quiet; then
    GIT_AUTHOR_NAME="$ID_NAME" GIT_AUTHOR_EMAIL="$ID_EMAIL" \
    GIT_COMMITTER_NAME="$ID_NAME" GIT_COMMITTER_EMAIL="$ID_EMAIL" \
      git commit -q -m "chore: preserve existing files"
  fi

  # Lọc comment theo toàn bộ snapshot client trước khi tạo diff cho AI.
  step "Lọc comment mới trước khi tạo dữ liệu cho AI"
  clean_review

  # ---------- AI cleanup ----------
  : > "$TMPD/status.env"; : > "$TMPD/ai_check.md"
  if $SKIP_AI; then
    echo "AI_STATUS=⏭️ Không gọi AI; comment được dọn bằng parser" > "$TMPD/status.env"
  else
    git diff --name-only --diff-filter=AM "$base_ref..HEAD" \
      | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|vue|cs|py|go|java|kt|php|rb|css|scss|sql|sh|md|mdx|ya?ml)$' \
      | grep -vE '(^|/)(node_modules|dist|build|bin|obj|vendor|\.next|Migrations)/|\.min\.|lock\.(json|yaml)$' \
      > "$TMPD/changed.txt" || true
    local file_count; file_count="$(wc -l < "$TMPD/changed.txt" | tr -d ' ')"
    if [ "$file_count" -gt "${AI_MAX_FILES:-200}" ]; then
      die "Có $file_count file cần AI review, vượt AI_MAX_FILES=${AI_MAX_FILES:-200}. Tăng giới hạn rồi chạy lại; chưa chạy AI, không bỏ qua file âm thầm."
    fi
    step "AI dọn dấu vết: $(wc -l < "$TMPD/changed.txt" | tr -d ' ') file"
    GITHUB_ENV="$TMPD/status.env" RUNNER_TEMP="$TMPD" \
      bash "$SCRIPT_DIR/ai_cleanup.sh" "$TMPD/changed.txt" \
        "$SCRIPT_DIR/ai-cleanup-prompt.md" "$SCRIPT_DIR/check_ai_diff.py" "$base_ref" > "$TMPD/ai.log" 2>&1 || true
    if [ -n "$(git diff --name-only)" ]; then
      git add -u
      GIT_AUTHOR_NAME="$ID_NAME" GIT_AUTHOR_EMAIL="$ID_EMAIL" \
      GIT_COMMITTER_NAME="$ID_NAME" GIT_COMMITTER_EMAIL="$ID_EMAIL" \
        git commit -q -m "chore: tidy comments and docs"
    fi
  fi
  local ai_status; ai_status="$(sed -n 's/^AI_STATUS=//p' "$TMPD/status.env" | tail -1)"
  echo "    AI: ${ai_status:-—}"

  if ! $SKIP_AI; then
    step "Kiểm tra và dọn comment sau AI"
    clean_review
  fi

  # Chỉ mô tả phạm vi bàn giao; báo cáo AI và nguồn nội bộ giữ local.
  "$PYTHON" "$SCRIPT_DIR/release_notes.py" "$base_ref" > "$TMPD/pr_body.md" \
    || die "Không tạo được mô tả release"

  echo "$branch" > "$PENDING"
  local n; n="$(git rev-list --count "$base_ref..HEAD")"
  git log --format='    %h %s  (%an)' -15 "$base_ref..HEAD"
  [ "$MODE" = "auto" ] || result "👀 chờ review" "$n commit · $(git diff --shortstat "$base_ref..HEAD" | sed 's/^ //')"
  $OPEN && command -v code >/dev/null && code "$REVIEW"
  return 0
}

# =====================================================================
if [ "$MODE" != "push" ] && [ "$MODE" != "clean" ]; then prepare_env; fi

set +e
for i in "${TARGETS[@]}"; do
  ( set -e; repo_main "$i" )
  rc=$?
  if [ $rc -ne 0 ] && ! grep -q "^${R_NAME[$i]}|" "$RESULTS"; then
    echo "${R_NAME[$i]}|❌ lỗi|lỗi không xác định (exit $rc), xem output bên trên" >> "$RESULTS"
  fi
done
set -e

# ---------- tổng kết ----------
echo
echo "${c_bold}━━ Tổng kết${c_off}"
while IFS='|' read -r n s d; do
  printf "  %-24s %s  %s\n" "$n" "$s" "$d"
done < "$RESULTS"

if [ "$MODE" = "sync" ] && grep -q "chờ review" "$RESULTS"; then
  echo
  echo "Chưa có gì được đẩy lên GitHub. Review:"
  while IFS='|' read -r n s d; do
    [[ "$s" == *"chờ review"* ]] || continue
    for i in "${!R_NAME[@]}"; do
      [ "${R_NAME[$i]}" = "$n" ] || continue
      w="$SYNC_HOME/$n-$(printf '%s' "${R_DEST[$i]}" | cksum | cut -d' ' -f1)"
      echo "  Mô tả PR (có thể chỉnh trước khi push): $w/tmp/pr_body.md"
      echo "  cd \"$w/review\" && git log -p origin/${R_DBASE[$i]}..HEAD"
    done
  done < "$RESULTS"
  echo
  echo "Ổn thì:  $SCRIPT_DIR/sync-local.sh --push            (mở PR cho mọi repo đang chờ)"
  echo "Khi merge: chọn Rebase and merge hoặc Create a merge commit để giữ GitOrigin-RevId."
  echo "   hoặc: $SCRIPT_DIR/sync-local.sh --push --direct   (đẩy thẳng vào branch đích)"
fi

grep -q "lỗi" "$RESULTS" && exit 1
exit 0
