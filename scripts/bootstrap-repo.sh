#!/usr/bin/env bash
# 새 프로젝트에 이 루프를 붙일 때의 **리포 설정**을 한 번에 건다.
#
# 왜 스크립트인가: 파일(호출부 워크플로우·`.claude/`)은 복사하면 되지만 리포 설정은 복사가
# 안 된다. 그리고 이 층이 사람이 가장 잘 빠뜨리는 곳인데, **빠뜨리면 조용히 안 돈다** —
# 라벨이 없으면 에이전트가 안 깨어나고, auto-merge가 꺼져 있으면 `gh pr merge --auto`가
# 거부되며, 브랜치 보호가 없으면 게이트 자체가 없는 것이다(2026-09-10에 gh-workflows의
# `main`이 무보호인 걸 감사에서 발견했다 — 소비 프로젝트 전부가 `@main`을 핀하고 있었는데도).
#
# 멱등하다. 여러 번 돌려도 된다. 못 하는 것(시크릿·외부 서비스)은 마지막에 목록으로 출력한다.
#
#   scripts/bootstrap-repo.sh <owner/repo> [옵션]
#
#     --integration <br>   통합 브랜치 (기본 develop)
#     --production  <br>   운영 브랜치 (기본 main)
#     --checks "a,b,c"     통합 브랜치의 필수 상태 체크
#                          (기본 "check / check,review / review")
#     --protect-production 운영 브랜치에도 PR 필수 보호를 건다
#     --enforce-admins     관리자도 보호를 우회하지 못하게 한다 (아래 주의 참고)
#     --dry-run            바꾸지 않고 무엇을 할지만 출력
set -euo pipefail

REPO=""; INTEGRATION="develop"; PRODUCTION="main"
CHECKS="check / check,review / review"
PROTECT_PROD=0; ENFORCE_ADMINS=false; DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --integration) INTEGRATION="$2"; shift 2 ;;
    --production)  PRODUCTION="$2";  shift 2 ;;
    --checks)      CHECKS="$2";      shift 2 ;;
    --protect-production) PROTECT_PROD=1; shift ;;
    --enforce-admins)     ENFORCE_ADMINS=true; shift ;;
    --dry-run)     DRY=1; shift ;;
    -h|--help)     sed -n '1,25p' "$0"; exit 0 ;;
    -*) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    *)  REPO="$1"; shift ;;
  esac
done

[ -n "$REPO" ] || { echo "사용법: $0 <owner/repo> [옵션]  (-h로 전체 옵션)" >&2; exit 2; }

say()  { printf '%s\n' "$*"; }
step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
# 실제 실행에선 응답 JSON을 삼키고, dry-run에선 무엇을 할지 **보여준다**.
# 호출부에 `>/dev/null`을 붙이면 dry-run 미리보기까지 먹혀서 "아무것도 안 하면서 ✓만" 찍힌다.
run()  { if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@" >/dev/null; fi; }

command -v gh >/dev/null 2>&1 || { echo "gh CLI가 필요합니다." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh 인증이 필요합니다: gh auth login" >&2; exit 1; }
gh repo view "$REPO" >/dev/null 2>&1 || { echo "저장소를 찾을 수 없습니다: $REPO" >&2; exit 1; }

say "대상: $REPO   통합=$INTEGRATION  운영=$PRODUCTION"
[ "$DRY" = 1 ] && say "(dry-run — 아무것도 바꾸지 않습니다)"

# ── 1. 라벨 ──────────────────────────────────────────────────────────────────
# 없으면 루프가 조용히 멈춘다. `agent`가 없으면 이슈에 라벨을 못 붙여 에이전트가 안 깨어나고,
# `agent-queued`가 없으면 WIP 대기가 성립하지 않는다.
step "라벨"
while IFS='|' read -r name color desc; do
  run gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force
  ok "$name"
done <<'LABELS'
agent|5319e7|Claude가 자율로 구현할 작업 (claude-agent.yml 트리거)
agent-queued|FEF2C0|앞 PR을 기다리는 대기 큐 (WIP 제한 1)
do-not-merge|b60205|위험 구간 변경 — diff 리뷰 후 사람이 수동 머지 (auto-merge 스킵)
followup-pr|D4C5F9|후속 이슈에서 나온 PR (리뷰 깊이 제한용)
review-followup|BFD4F2|자동 리뷰가 남긴 후속 정리 거리
LABELS

# ── 2. 저장소 머지 설정 ──────────────────────────────────────────────────────
step "저장소 머지 설정"
# `delete_branch_on_merge`는 **반드시 꺼둔다.** 그 설정은 머지된 PR의 head 브랜치를 무조건
# 지워서, `develop`→`main` 릴리스 PR을 머지하는 순간 **`develop` 자체가 삭제된다**
# (2026-09-05 kitchen-tempo에서 실제로 겪고 복구함). 브랜치 정리는 `after-merge.yml`이
# base와 이름을 보고 안전하게 한다.
run gh api -X PATCH "repos/$REPO" \
  -F allow_auto_merge=true \
  -F allow_squash_merge=true \
  -F allow_merge_commit=true \
  -F delete_branch_on_merge=false
ok "auto-merge 켬 / squash·merge commit 허용 / delete_branch_on_merge **끔**"

# ── 3. 통합 브랜치 ───────────────────────────────────────────────────────────
step "통합 브랜치"
if gh api "repos/$REPO/git/ref/heads/$INTEGRATION" >/dev/null 2>&1; then
  ok "$INTEGRATION 이미 있음"
else
  base_sha=$(gh api "repos/$REPO/git/ref/heads/$PRODUCTION" --jq '.object.sha')
  run gh api -X POST "repos/$REPO/git/refs" \
    -f "ref=refs/heads/$INTEGRATION" -f "sha=$base_sha"
  ok "$INTEGRATION 생성 ($PRODUCTION 기준)"
fi

# ── 4. 브랜치 보호 ───────────────────────────────────────────────────────────
# 필수 체크에는 **`pull_request`로 트리거되는 것만** 넣는다. 워크플로우가 아예 안 돌면 그
# 체크는 생성되지 않고, "없음"은 `success`가 아니라 **영구 Pending**이라 PR을 영원히 막는다
# (잡이 skip되는 건 success 취급이라 무해하다 — 둘은 다르다).
#
# 승인 수는 0이다. 1인 소유자는 **자기 PR을 자기가 승인할 수 없어** 1로 걸면 본인이 잠긴다.
protect() {
  local branch="$1" contexts_json="$2"
  local payload
  payload=$(cat <<EOF
{
  "required_status_checks": $contexts_json,
  "enforce_admins": $ENFORCE_ADMINS,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
)
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run] %s 보호:\n%s\n' "$branch" "$payload"
    return 0
  fi
  if printf '%s' "$payload" | gh api -X PUT "repos/$REPO/branches/$branch/protection" --input - >/dev/null; then
    ok "$branch 보호 적용 (PR 필수 · 승인 0 · force push/삭제 차단 · enforce_admins=$ENFORCE_ADMINS)"
  else
    warn "$branch 보호 실패 — private 저장소는 **GitHub Pro 이상**이어야 합니다. 플랜을 확인하세요."
    return 1
  fi
}

step "브랜치 보호 — $INTEGRATION"
contexts=$(printf '%s' "$CHECKS" | awk -F',' '{
  printf "["
  for (i = 1; i <= NF; i++) {
    gsub(/^ +| +$/, "", $i)
    if ($i != "") { if (i > 1) printf ","; printf "\"%s\"", $i }
  }
  printf "]"
}')
protect "$INTEGRATION" "{\"strict\": false, \"contexts\": $contexts}" || true
say "  필수 체크: $CHECKS"
say "  ※ 재사용 워크플로우는 체크 이름이 '<호출 잡> / <불린 잡>'이 된다 — 'check'가 아니라 'check / check'."

if [ "$PROTECT_PROD" = 1 ]; then
  step "브랜치 보호 — $PRODUCTION"
  # 운영 브랜치엔 필수 체크를 걸지 않는다. 릴리스 PR은 사람이 보고 머지하는 자리이고,
  # 체크가 안 생기면 사람도 못 머지하게 되는 위험만 늘린다.
  protect "$PRODUCTION" "null" || true
fi

# ── 5. 사람이 해야 하는 것 ───────────────────────────────────────────────────
step "여기서 끝나지 않는다 — 직접 하셔야 하는 것"
cat <<EOF
  1) Claude GitHub App + 토큰
       github.com/apps/claude → Configure → 이 저장소를 Repository access에 추가
       토큰은 \`claude setup-token\` 으로 발급해 위 2번 스크립트에서 함께 넣습니다.
       ※ /install-github-app 도 되지만 claude.yml 을 새로 만들어 PR을 엽니다 —
          호출부를 이미 복사해 뒀다면 중복이라 닫아야 합니다.

  2) 에이전트 App 자격증명 (AGENT_APP_ID / AGENT_APP_PRIVATE_KEY)
       scripts/sync-secrets.sh $REPO
       ※ App을 All repositories로 설치해 두면 저장소별 추가 작업이 없습니다.
          Workflows 권한이 있어야 .github/workflows/* 커밋이 거부되지 않습니다.
       ※ GITHUB_TOKEN이 붙인 라벨은 다른 워크플로우를 깨우지 않습니다(GitHub 플랫폼 제약).
          이 자격증명이 없으면 drain-queue가 이슈를 깨워도 에이전트가 안 돕니다.

  3) 쓰는 것만:
       gh secret set VERCEL_AUTOMATION_BYPASS_SECRET --repo $REPO   # preview-smoke
       gh secret set DOTENV_PRIVATE_KEY --repo $REPO                # dotenvx

  4) 이 저장소(gh-workflows)의 접근 허용 — **계정당 1회면 됩니다**
       Settings → Actions → General → Access
       → "Accessible from repositories owned by the user"

  5) Vercel: 프로젝트 연결, $INTEGRATION → staging 도메인,
       Deployment Protection → Protection Bypass for Automation (위 3번 시크릿)

  6) 파일은 이 스크립트가 건드리지 않습니다. kitchen-tempo에서 가져오세요:
       .github/workflows/  (호출부 — 트리거·권한·risk-paths는 프로젝트마다 다릅니다)
       .claude/settings.json, .claude/hooks/**, .claude/skills/steward
       ※ vitest.config의 include에 '.claude/hooks/*.test.ts'를 넣으세요.
          빠뜨리면 훅 회귀 테스트가 **조용히 안 돕니다**.
EOF

step "확인"
say "  gh repo view $REPO --json deleteBranchOnMerge,autoMergeAllowed"
say "  gh api repos/$REPO/branches/$INTEGRATION/protection --jq '.required_status_checks.contexts'"
