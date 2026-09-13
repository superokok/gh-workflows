#!/usr/bin/env bash
# 루프 자격증명을 소비 저장소들에 뿌리고, 빠진 곳을 찾아낸다.
#
# 왜 스크립트인가: 개인 계정에는 조직 secret이 없어서 **저장소마다** 등록해야 한다.
# 손으로 하면 저장소가 늘거나 토큰을 교체할 때 일부만 갱신되고, 그 저장소의 루프만
# 조용히 멈춘다 — 이 저장소가 제일 싫어하는 실패 형태다(README "알아둘 것":
# 침묵은 정상과 구별되지 않는다). `--check`가 그 침묵을 깨는 쪽이다.
#
# **자동으로 돌지 않는다.** 개인 계정에는 "저장소 생성" 이벤트를 다른 저장소에서 받을
# 방법이 없어서(조직 웹훅이 필요하다) 새 저장소가 생기면 사람이 한 번 실행한다.
#
# 사용:
#   scripts/sync-secrets.sh --check              # 현황만 본다 (읽기 전용, 값 불필요)
#   scripts/sync-secrets.sh                      # 물어보고 목록 전체에 등록
#   scripts/sync-secrets.sh <owner>/<repo>       # 물어보고 그 저장소에만 등록
#
# 값은 물어본다. 스크립트로 돌릴 땐 환경변수로 미리 주면 안 묻는다:
#   AGENT_APP_CLIENT_ID       GitHub App의 Client ID (Iv23… 형태)
#   AGENT_APP_PEM             private key .pem 파일 **경로** (값이 아니라 경로)
#   CLAUDE_CODE_OAUTH_TOKEN   Anthropic 인증 토큰
#
# 값은 stdin으로만 넘긴다 — `--body "$v"`로 주면 값이 argv에 올라가 `ps`에 보인다.
#
# **GitHub secret은 되읽을 수 없다.** 그래서 이 스크립트도 값을 어디선가 받아야 한다 —
# 마스터 사본을 Bitwarden 같은 곳에 두는 이유가 그거다.
set -uo pipefail

# 이 루프가 요구하는 secret. preview-smoke(VERCEL_…)·dotenvx(DOTENV_…)는 프로젝트마다
# 쓰고 안 쓰고가 갈려서 여기 넣지 않는다 — 없다고 루프가 멈추지 않는다.
REQUIRED=(AGENT_APP_CLIENT_ID AGENT_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN)

# ── 대상 저장소 목록 ────────────────────────────────────────────────────────
# **이 파일에 목록을 적지 않는다.** 이 저장소는 public이고, 목록은 곧 "이 계정이 어떤
# private 저장소를 갖고 있는가"다. 코드가 공개돼도 무해한 것과, 목록이 공개되면 곤란한
# 것은 다른 종류라 저장 위치를 나눈다.
#
# 찾는 순서 — 먼저 찾은 하나만 쓴다:
#   1. 인자로 준 저장소들
#   2. $AGENT_REPOS               공백/쉼표로 구분 (CI·일회성 실행용)
#   3. scripts/repos.local        저장소 안, gitignore됨 (평소 쓰는 곳)
#   4. ~/.config/gh-workflows/repos
# 둘 다 `owner/repo` 한 줄에 하나, `#` 주석과 빈 줄 허용.
#
# **못 찾으면 조용히 넘어가지 않고 실패한다.** 목록이 비면 `--check`는 아무것도 점검하지
# 않고 초록으로 끝나는데, 그건 "다 괜찮다"와 구별되지 않는다 — 이 스크립트가 존재하는
# 이유가 바로 그 침묵을 없애는 것이다.
read_repo_file() {
  [ -f "$1" ] || return 1
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -E '^[^/]+/[^/]+$'
}

resolve_repos() {
  local here list
  here="$(cd "$(dirname "$0")" && pwd)"

  if [ -n "${AGENT_REPOS:-}" ]; then
    printf '%s\n' "${AGENT_REPOS//,/ }" | tr ' ' '\n' | grep -E '^[^/]+/[^/]+$'
    return
  fi
  for f in "$here/repos.local" "${XDG_CONFIG_HOME:-$HOME/.config}/gh-workflows/repos"; do
    if list=$(read_repo_file "$f") && [ -n "$list" ]; then
      printf '%s\n' "$list"
      return
    fi
  done
  return 1
}

check_only=""
[ "${1:-}" = "--check" ] && { check_only=1; shift; }

repos=("$@")
if [ ${#repos[@]} -eq 0 ]; then
  # `mapfile`을 쓰지 않는다 — bash 4부터라 macOS 기본 bash 3.2에서 조용히 빈 배열이 된다.
  while IFS= read -r line; do
    [ -n "$line" ] && repos+=("$line")
  done < <(resolve_repos)

  if [ ${#repos[@]} -eq 0 ]; then
    cat >&2 <<'EOF'
대상 저장소 목록이 없다. 셋 중 하나로 준다:

  scripts/sync-secrets.sh owner/repo          # 인자로 직접
  AGENT_REPOS="owner/a owner/b" scripts/…     # 환경변수로
  scripts/repos.local 에 한 줄에 하나씩        # 평소 쓰는 곳 (gitignore됨)

repos.local 예시는 scripts/repos.local.example 에 있다.
EOF
    exit 2
  fi
fi

command -v gh >/dev/null 2>&1 || { echo "gh CLI가 필요하다" >&2; exit 1; }

# ── 점검 모드 ───────────────────────────────────────────────────────────────
# 빠진 게 하나라도 있으면 non-zero로 끝난다 — 교체 작업 뒤 확인용으로 쓸 수 있게.
if [ -n "$check_only" ]; then
  missing_total=0
  for r in "${repos[@]}"; do
    # **조회 실패와 "secret이 하나도 없음"을 구별한다.** 빈 출력만 보고 실패로 단정하면,
    # 아직 아무것도 등록 안 한 새 저장소가 "권한 없음"으로 잘못 보고된다(실제로 그랬다).
    # 파이프로 바로 넘기지 않는 것도 같은 이유다 — awk의 종료 코드가 gh의 것을 덮는다.
    # `--json`에 기대지 않는다 — gh 버전에 따라 없을 수 있다.
    if ! raw=$(gh secret list --repo "$r" 2>/dev/null); then
      echo "✗ $r — secret 목록 조회 실패 (저장소 없음/권한 없음?)"
      missing_total=$((missing_total + 1))
      continue
    fi
    have=$(printf '%s\n' "$raw" | awk 'NF {print $1}')
    missing=""
    for s in "${REQUIRED[@]}"; do
      printf '%s\n' "$have" | grep -qx "$s" || missing="$missing $s"
    done
    if [ -z "$missing" ]; then
      echo "✓ $r"
    else
      echo "✗ $r — 없음:$missing"
      missing_total=$((missing_total + 1))
    fi
  done
  echo
  if [ "$missing_total" -eq 0 ]; then
    echo "모두 갖춰져 있다."
  else
    echo "$missing_total 개 저장소가 불완전하다. --check 없이 다시 실행하면 값을 물어본다."
  fi
  exit "$((missing_total > 0))"
fi

# ── 값 받기 ─────────────────────────────────────────────────────────────────
# 환경변수가 있으면 그걸 쓰고(무인 실행), 없으면 물어본다.
# **빈 입력은 "이 secret은 건드리지 않음"이다** — 하나만 교체할 때 쓴다.

# 붙여넣은 윈도우 경로(C:\Users\...)를 Git Bash가 이해하는 형태로 바꾼다.
# 안 하면 백슬래시가 먹혀 경로가 조용히 뭉개진다.
normalize_path() {
  local p="$1"
  p="${p%\"}"; p="${p#\"}"          # 따옴표째 붙여넣는 경우
  p="${p//\\//}"                    # C:\a\b -> C:/a/b
  printf '%s' "$p"
}

echo "대상 저장소: ${repos[*]}"
echo "값을 비워두고 Enter를 치면 그 secret은 건드리지 않는다."
echo

if [ -z "${AGENT_APP_CLIENT_ID:-}" ]; then
  read -r -p "Client ID (github.com/settings/apps/… 의 Client ID, Iv23… 형태): " AGENT_APP_CLIENT_ID
fi
# **App ID(숫자)를 넣는 걸 막는 검사다.** 예전엔 "숫자인가"만 봤는데, App ID와
# Installation ID가 둘 다 숫자라 그 검사는 아무것도 못 걸렀다 — 설치 화면 URL의 숫자를
# 넣고 `A JSON web token could not be decoded`로 죽는 걸 실제로 겪었다(2026-09-11).
# Client ID는 접두가 고정이라 이 착각이 성립하지 않는다.
if [ -n "$AGENT_APP_CLIENT_ID" ]; then
  case "$AGENT_APP_CLIENT_ID" in
    Iv*) ;;
    *[!0-9]*) echo "Client ID 형식이 아니다: $AGENT_APP_CLIENT_ID" >&2; exit 1 ;;
    *) echo "숫자를 넣었다: $AGENT_APP_CLIENT_ID" >&2
       echo "App ID나 Installation ID가 아니라 **Client ID**(Iv23… 형태)가 필요하다." >&2
       exit 1 ;;
  esac
fi

if [ -z "${AGENT_APP_PEM:-}" ]; then
  # -e: readline. 경로 탭 완성이 된다.
  read -e -r -p "private key .pem 파일 경로: " AGENT_APP_PEM
fi
if [ -n "$AGENT_APP_PEM" ]; then
  AGENT_APP_PEM=$(normalize_path "$AGENT_APP_PEM")
  if [ ! -r "$AGENT_APP_PEM" ]; then
    echo "읽을 수 없다: $AGENT_APP_PEM" >&2
    exit 1
  fi
  # 엉뚱한 파일을 지정했는지 본다 — 내용은 출력하지 않는다.
  if ! head -1 "$AGENT_APP_PEM" | grep -q "BEGIN.*PRIVATE KEY"; then
    echo "private key 파일로 보이지 않는다 (첫 줄에 BEGIN … PRIVATE KEY 없음): $AGENT_APP_PEM" >&2
    exit 1
  fi
fi

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  # -s: 화면에 안 찍는다.
  read -r -s -p "CLAUDE_CODE_OAUTH_TOKEN (붙여넣기, 화면에 안 보임): " CLAUDE_CODE_OAUTH_TOKEN
  echo
fi

if [ -z "$AGENT_APP_CLIENT_ID" ] && [ -z "$AGENT_APP_PEM" ] && [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo "입력된 값이 없다. 아무것도 하지 않는다." >&2
  exit 1
fi

# ── 확인 ────────────────────────────────────────────────────────────────────
echo
echo "등록할 것:"
[ -n "$AGENT_APP_CLIENT_ID" ]     && echo "  - AGENT_APP_CLIENT_ID"
[ -n "$AGENT_APP_PEM" ]           && echo "  - AGENT_APP_PRIVATE_KEY  ($AGENT_APP_PEM)"
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo "  - CLAUDE_CODE_OAUTH_TOKEN"
echo "대상: ${repos[*]}"
read -r -p "진행할까? [y/N] " ok
case "$ok" in y|Y|yes|YES) ;; *) echo "취소했다."; exit 1 ;; esac

# ── 등록 ────────────────────────────────────────────────────────────────────
rc=0
for r in "${repos[@]}"; do
  echo "→ $r"
  if [ -n "$AGENT_APP_CLIENT_ID" ]; then
    printf '%s' "$AGENT_APP_CLIENT_ID" | gh secret set AGENT_APP_CLIENT_ID --repo "$r" || rc=1
  fi
  if [ -n "$AGENT_APP_PEM" ]; then
    gh secret set AGENT_APP_PRIVATE_KEY --repo "$r" < "$AGENT_APP_PEM" || rc=1
  fi
  if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$r" || rc=1
  fi
done

echo
if [ "$rc" -eq 0 ]; then
  echo "완료. 확인:"
  echo "  scripts/sync-secrets.sh --check"
else
  echo "일부 실패했다 — 위 출력을 확인하고 --check로 어디가 비었는지 볼 것." >&2
fi
exit "$rc"
