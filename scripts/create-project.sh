#!/usr/bin/env bash
# 새 프로젝트를 이 루프에 **한 번에** 올린다 — 파일까지 포함해서.
#
# `bootstrap-repo.sh`는 리포 **설정**만 건다(라벨·보호·auto-merge). 파일은 "이 루프를 이미 쓰는
# 저장소에서 복사하세요"가 마지막 안내였는데, 복사는 사람이 가장 잘 빠뜨리는 단계이고
# **빠뜨리면 조용히 안 돈다.** 이 스크립트가 그 구멍을 메운다.
#
# 세 층이 각각 어디서 오는지:
#   - 루프 로직      → `superokok/gh-workflows` 재사용 워크플로우 (`uses:`로 참조, 복사 없음)
#   - 호출부·템플릿  → 이 저장소 `scripts/skeleton/` (**한 번 렌더**, 이후 프로젝트가 소유)
#   - 훅·공통 지침   → `superokok/project-template`의 `common/` (**계속 동기화**)
#
# 호출부가 여기 있는 이유: 재사용 워크플로우가 입력을 하나 늘리면 호출부 모양도 같이 바뀐다.
# 같은 저장소에 두면 그 둘을 한 PR에서 맞출 수 있다. 반대로 훅·공통 지침은 로직과 무관하게
# 계속 흘러가야 하므로 정본 저장소에 둔다.
#
#   scripts/create-project.sh <owner/repo> [옵션]
#
#     --stack <이름>        next-vercel | jvm-next | bare   (기본 next-vercel)
#     --profile <파일>      키=값 파일로 스택 기본값을 덮어쓴다
#     --set KEY=VALUE       개별 값 덮어쓰기 (여러 번 가능)
#     --new                 저장소를 새로 만든다(private). 없으면 기존 저장소에 붙인다
#     --render-only <디렉터리>  렌더 결과만 그 디렉터리에 쓰고 끝낸다(검증용)
#     --force-render        이미 있는 호출부도 스택 기본값으로 덮어쓴다(기본은 건드리지 않음)
#     --no-common           정본의 `common/`을 복사하지 않는다
#                           **정본 저장소 자신에 붙일 때 반드시 쓴다** — 자기 `common/`을
#                           루트로 복사해 훅·테스트가 통째로 중복된다(2026-09-16 dry-run 확인)
#     --skip <상대경로>     그 스켈레톤 파일을 렌더하지 않는다 (여러 번 가능)
#                           예: 정본 저장소 자신에는 `--skip .github/workflows/template-sync.yml`
#                           — 자기 자신을 정본으로 삼아 common/을 루트로 복사해 중복을 만든다
#     --dry-run             아무것도 바꾸지 않고 무엇을 할지만 출력
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKELETON="$SELF_DIR/skeleton"
TEMPLATE_REPO="${TEMPLATE_REPO:-superokok/project-template}"

REPO=""; STACK="next-vercel"; PROFILE=""; NEW=0; DRY=0; RENDER_ONLY=""; FORCE_RENDER=0
declare -a SKIP=()
NO_COMMON=0
declare -a OVERRIDES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --stack)       STACK="$2"; shift 2 ;;
    --profile)     PROFILE="$2"; shift 2 ;;
    --set)         OVERRIDES+=("$2"); shift 2 ;;
    --new)         NEW=1; shift ;;
    --render-only) RENDER_ONLY="$2"; shift 2 ;;
    --force-render) FORCE_RENDER=1; shift ;;
    --skip)        SKIP+=("$2"); shift 2 ;;
    --no-common)   NO_COMMON=1; shift ;;
    --dry-run)     DRY=1; shift ;;
    -h|--help)     sed -n '1,30p' "$0"; exit 0 ;;
    -*) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    *)  REPO="$1"; shift ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

[ -n "$RENDER_ONLY" ] || [ -n "$REPO" ] || {
  echo "사용법: $0 <owner/repo> [옵션]  (-h로 전체 옵션)" >&2; exit 2; }

# ── 값 모으기: 스택 기본값 → 프로파일 → --set ────────────────────────────────
declare -A V=()
load_env_file() {
  local f="$1" line key val
  [ -f "$f" ] || { echo "프로파일 파일이 없다: $f" >&2; exit 2; }
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"          # 값에 '='이 들어 있어도 첫 '='만 자른다(정규식·프롬프트가 그렇다)
    # **CR을 떼어낸다.** 프로파일이 CRLF로 저장돼 있으면 값 끝에 CR 한 바이트가
    # 남고, 그게 렌더된 YAML 안으로 들어가 **줄바꿈으로 해석된다** — 한 줄이어야 할
    # 프롬프트가 두 줄이 되면서 YAML 파싱이 깨진다(2026-09-16 실측: "develop" 다음에
    # CR이 붙어 "/main"이 다음 줄로 밀리면서 claude.yml이 무너졌다).
    # 저장소에는 `.gitattributes`로 LF를 강제하지만, 손으로 만든 프로파일은 그 밖이다.
    #
    # 이 주석 자체가 한 번 깨져 있었다(2026-09-17 발견): 설명하려던 CR을 **주석 안에
    # 리터럴로 적는 바람에** 줄이 쪼개져, 백틱이 명령 치환으로 열려 있었다. 파일 전체의
    # 백틱 개수가 우연히 짝이 맞아 `bash -n`을 통과했을 뿐이다 — 주석에 한 줄을 더하는
    # 것만으로 스크립트 전체가 문법 오류가 났다. 제어문자는 이름으로 적는다.
    key="${key%$'\r'}"
    val="${val%$'\r'}"
    V["$key"]="$val"
  done < "$f"
}

STACK_PROFILE="$SKELETON/profiles/$STACK.env"
[ -f "$STACK_PROFILE" ] || { echo "모르는 스택: $STACK (있는 것: $(cd "$SKELETON/profiles" && ls *.env | sed 's/\.env//' | tr '\n' ' '))" >&2; exit 2; }
load_env_file "$STACK_PROFILE"
[ -n "$PROFILE" ] && load_env_file "$PROFILE"
for kv in ${OVERRIDES+"${OVERRIDES[@]}"}; do
  V["${kv%%=*}"]="${kv#*=}"
done
# 저장소 이름은 인자에서 온다 — 프로파일에 적을 값이 아니다.
[ -n "$REPO" ] && [ -z "${V[PROJECT_NAME]:-}" ] && V[PROJECT_NAME]="${REPO#*/}"
[ -z "${V[PROJECT_NAME]:-}" ] && V[PROJECT_NAME]="project"

# ── 렌더 ─────────────────────────────────────────────────────────────────────
# `${var//pat/rep}`를 쓰지 않는다. **bash 5.2부터 치환문의 `&`가 매치된 문자열로 확장된다**
# (sed 흉내). 우리 값에는 `&&`가 흔하다 — `verify: "npm run typecheck && ./gradlew test"`가
# `{{VERIFY}}{{VERIFY}}`로 뭉개졌다(2026-09-16 실측). sed도 같은 이유로 못 쓴다: 값에
# `/`·`&`·`|`가 전부 들어간다(risk-paths 정규식, 긴 프롬프트).
# 아래는 접두/접미 제거만 쓰므로 어떤 bash에서도 값을 있는 그대로 넣는다.
replace_all() {
  local hay="$1" needle="$2" rep="$3" out=""
  while :; do
    case "$hay" in
      *"$needle"*)
        out="${out}${hay%%"$needle"*}${rep}"
        hay="${hay#*"$needle"}"
        ;;
      *) out="${out}${hay}"; break ;;
    esac
  done
  printf '%s' "$out"
}

# 스켈레톤은 **없으면 만들고, 있으면 건드리지 않는다.**
# 한 번 렌더된 호출부는 그 순간부터 프로젝트가 소유한다 — 위험 경로 정규식, 검증 명령,
# 에이전트 프롬프트는 저장소마다 자라기 때문이다. 덮어쓰면 그 조정이 통째로 날아간다
# (2026-09-16 devDepth dry-run: claude-agent·claude-fix·claude.yml·enable-auto-merge가
# 스택 기본값으로 되돌아가려 했다). 계속 흘러야 하는 것은 정본 `common/` 쪽이고, 그쪽은
# 아래에서 항상 덮어쓴다.
RENDER_SKIPPED=""
render_into() {
  local dest="$1" src rel out content key pass
  local -a written=()
  while IFS= read -r -d '' src; do
    rel="${src#"$SKELETON"/}"
    case "$rel" in profiles/*) continue ;; esac
    local skipped=0 sk
    for sk in ${SKIP+"${SKIP[@]}"}; do
      [ "$sk" = "$rel" ] && skipped=1
    done
    [ "$skipped" = 1 ] && continue
    out="$dest/$rel"
    if [ -e "$out" ] && [ "$FORCE_RENDER" = 0 ]; then
      RENDER_SKIPPED="${RENDER_SKIPPED}${RENDER_SKIPPED:+ }$rel"
      continue
    fi
    mkdir -p "$(dirname "$out")"
    content="$(cat "$src")"
    # **2패스로 돌린다.** 프로파일 값 안에 자리표시자가 또 들어 있다 — 예: MENTION_PROMPT가
    # {{INTEGRATION_BRANCH}}·{{VERIFY}}를 품는다. 1패스면 삽입 순서에 따라 남는 게 생긴다.
    for pass in 1 2; do
      for key in "${!V[@]}"; do
        case "$content" in
          *"{{$key}}"*) content="$(replace_all "$content" "{{$key}}" "${V[$key]}")" ;;
        esac
      done
    done
    printf '%s\n' "$content" > "$out"
    written+=("$out")
  done < <(find "$SKELETON" -type f -print0)

  # 남은 자리표시자가 있으면 값이 빠진 것이다 — 조용히 넘기지 않는다.
  local leftover
  # **방금 쓴 파일만 본다.** `$dest` 전체를 훑으면 대상 저장소에 원래 있던
  # `{{UPPER_CASE}}` 문자열(다른 템플릿 엔진, 이슈 폼 등)에 걸려, 우리가 렌더한 것과
  # 무관하게 스크립트가 통째로 실패한다(#78). 빈 디렉터리에 렌더하는
  # `--render-only`에서는 안 드러나고, 실제 저장소에 붙일 때만 터지는 종류다.
  [ ${#written[@]} -eq 0 ] && return 0
  leftover="$(grep -ohE '\{\{[A-Z_]+\}\}' "${written[@]}" 2>/dev/null | sort -u || true)"
  if [ -n "$leftover" ]; then
    echo "::error::채워지지 않은 자리표시자가 있다:" >&2
    printf '  %s\n' $leftover >&2
    return 1
  fi
}

if [ -n "$RENDER_ONLY" ]; then
  step "렌더만 수행 → $RENDER_ONLY"
  mkdir -p "$RENDER_ONLY"
  render_into "$RENDER_ONLY"
  ok "스켈레톤 렌더 완료 (스택: $STACK)"
  exit 0
fi

say "대상: $REPO   스택: $STACK   통합=${V[INTEGRATION_BRANCH]}  운영=${V[PRODUCTION_BRANCH]}"
[ "$DRY" = 1 ] && say "(dry-run — 아무것도 바꾸지 않습니다)"

command -v gh >/dev/null 2>&1 || { echo "gh CLI가 필요합니다." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh 인증이 필요합니다: gh auth login" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 저장소 준비 ──────────────────────────────────────────────────────────────
step "저장소"
if [ "$NEW" = 1 ]; then
  if [ "$DRY" = 1 ]; then
    say "  [dry-run] gh repo create $REPO --private --add-readme"
  else
    gh repo create "$REPO" --private --add-readme >/dev/null
    ok "$REPO 생성"
  fi
fi
if [ "$DRY" = 1 ] && ! gh repo view "$REPO" >/dev/null 2>&1; then
  say "  [dry-run] (저장소가 아직 없어 clone은 건너뜁니다)"
  DRY_NO_REPO=1
else
  gh repo clone "$REPO" "$WORK/repo" -- -q
  # **기본 브랜치가 아니라 통합 브랜치를 본다.** clone은 기본 브랜치(보통 운영 브랜치)를
  # 주는데, 붙이는 대상은 PR의 base가 될 통합 브랜치다. 이걸 빼면 이미 통합 브랜치에
  # 들어가 있는 파일을 "없다"고 판단해 되돌리는 PR을 연다(2026-09-16 dry-run에서 확인).
  if ! git -C "$WORK/repo" checkout -q "${V[INTEGRATION_BRANCH]}" 2>/dev/null; then
    # **없으면 여기서 만든다.** 예전엔 경고만 하고 기본 브랜치로 계속 갔는데, 그러면 아래
    # `gh pr create --base <통합 브랜치>`가 `Base ref must be a branch`로 죽는다 —
    # 저장소·파일·푸시까지 다 끝난 뒤에 마지막 한 줄에서 실패해서, 반쯤 만들어진 저장소가
    # 남는다(2026-09-17 superokok/devDepth를 실제로 만들면서 밟았다).
    #
    # 통합 브랜치는 `bootstrap-repo.sh`도 만들지만 그건 이 단계보다 **뒤에** 돈다.
    # 순서를 바꾸는 대신 여기서 만든다 — 브랜치가 있어야 PR을 열 수 있고, bootstrap의
    # 생성은 이미 멱등이라 두 번 만들어도 무해하다.
    if [ "$DRY" = 1 ]; then
      say "  [dry-run] 통합 브랜치 ${V[INTEGRATION_BRANCH]} 생성 + push"
    else
      git -C "$WORK/repo" switch -qc "${V[INTEGRATION_BRANCH]}"
      git -C "$WORK/repo" push -q -u origin "${V[INTEGRATION_BRANCH]}"
      ok "통합 브랜치 ${V[INTEGRATION_BRANCH]} 생성 (기본 브랜치에서 갈라냄)"
    fi
  fi
  ok "clone (${V[INTEGRATION_BRANCH]})"
fi

# ── 파일 ─────────────────────────────────────────────────────────────────────
step "파일"
if [ "${DRY_NO_REPO:-0}" = 1 ]; then
  say "  [dry-run] 스켈레톤 렌더 + 정본 common/ 복사"
else
  render_into "$WORK/repo"
  ok "호출부·템플릿 렌더 (scripts/skeleton → 저장소)"
  if [ -n "$RENDER_SKIPPED" ]; then
    say "    이미 있어 건드리지 않음(프로젝트 소유): $RENDER_SKIPPED"
  fi

  if [ "$NO_COMMON" = 1 ]; then
    say "    정본 common/ 복사 건너뜀 (--no-common)"
  else
  git clone -q --depth 1 "https://github.com/$TEMPLATE_REPO.git" "$WORK/template" 2>/dev/null || {
    warn "정본($TEMPLATE_REPO) clone 실패 — 훅·공통 지침은 건너뜁니다"; }
  if [ -d "$WORK/template/common" ]; then
    (cd "$WORK/template/common" && find . \( -type f -o -type l \) -print0) \
      | while IFS= read -r -d '' f; do
          rel="${f#./}"
          mkdir -p "$WORK/repo/$(dirname "$rel")"
          cp -pP "$WORK/template/common/$rel" "$WORK/repo/$rel"
        done
    ok "훅·공통 지침 복사 (정본 $TEMPLATE_REPO의 common/)"
  fi
  fi

  cd "$WORK/repo"
  # **판정은 `git status`가 아니라 인덱스로 한다.** `cp -p`가 mtime까지 보존하면 git이
  # 내용이 같은 파일도 stat 기준으로 M으로 보고한다(2026-09-16 실측: 9개 전부 오탐,
  # `cmp`로는 바이트 동일, `git diff`는 비어 있었다). 그 상태로 commit하면 "nothing to
  # commit"으로 죽는다. `git add -A`로 한 번 정규화한 뒤 스테이지된 것만 본다.
  git add -A
  if git diff --cached --quiet; then
    ok "바꿀 파일 없음 — 이미 최신"
  else
    if [ "$DRY" = 1 ]; then
      say "  [dry-run] 다음 파일이 추가/변경됩니다:"
      git diff --cached --name-status | sed 's/^/    /'
    else
      br="chore/adopt-loop"
      git checkout -q -B "$br"
      git -c user.name="create-project.sh" -c user.email="noreply@example.com"         commit -q -m "chore: 공통 루프 호출부·훅·지침을 붙인다

scripts/create-project.sh가 생성했다. 호출부는 gh-workflows의 scripts/skeleton을
이 프로젝트 값으로 렌더한 것이고(이후 이 저장소가 소유한다), 훅과 공통 지침은
$TEMPLATE_REPO의 common/에서 온 것이다(template-sync.yml이 계속 동기화한다)."
      git push -q -u origin "$br"
      gh pr create --repo "$REPO" --base "${V[INTEGRATION_BRANCH]}" --head "$br"         --title "chore: 공통 루프를 붙인다"         --body "\`create-project.sh\`가 생성한 PR이다. 호출부는 이 프로젝트 값으로 렌더됐고, 훅·공통 지침은 정본에서 왔다. 머지 전에 \`risk-paths\`와 검증 명령이 이 저장소에 맞는지 확인할 것." >/dev/null
      ok "PR 생성 (base: ${V[INTEGRATION_BRANCH]})"
    fi
  fi
  cd - >/dev/null
fi

# ── 필수 체크: **지금 실제로 존재하는 것만 건다** ────────────────────────────
#
# `REQUIRED_CHECKS`에는 `ci.yml`이 내는 이름(`backend`·`web-and-app`·`check / check`)이
# 들어 있는데, **`ci.yml`은 스켈레톤에 없다**(빌드 게이트는 스택이 소유한다). 그대로 걸면
# 그 체크는 **영영 생기지 않고 영구 Pending으로 남아 첫 PR부터 머지가 막힌다** — 에이전트
# 루프도 PR #1에서 그대로 멈춘다. devDepth가 2026-09-11에 정확히 이걸로 막혔고, 그 교훈이
# CLAUDE.md에 적혀 있는데 **이 스크립트가 그걸 구조적으로 재현하고 있었다.**
#
# 그래서 렌더된 워크플로우가 **열린 PR에서 실제로 만드는** 체크만 걸고, 나머지는 `ci.yml`을
# 쓴 뒤에 추가하도록 명령까지 찍어 준다.
producible_checks() {
  local dir="$1" f
  for f in "$dir"/.github/workflows/*.yml; do
    [ -e "$f" ] || continue
    awk '
      /^on:/ { inon = 1; next }
      inon && /^[^[:space:]]/ { inon = 0 }
      # `on:` 아래 2칸이 트리거 키다. pull_request 아래의 types만 봐야 한다 —
      # 파일에 workflow_run(types: [completed])이 같이 있으면 그걸 보고 잘못 뺀다.
      inon && /^  [a-z_]+:/ { inpr = ($0 ~ /^  pull_request:/); if (inpr) pr = 1 }
      # types에 opened가 없으면 열린 PR에 체크를 만들지 않는다(after-merge의 [closed]).
      inon && inpr && /types:/ && $0 !~ /opened/ { pr = 0 }
      /^jobs:/ { injobs = 1; next }
      injobs && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
        job = $1; sub(/:$/, "", job); n++; jobs[n] = job
      }
      injobs && /^[[:space:]]+uses:/ { reusable[job] = 1 }
      END {
        if (pr) for (i = 1; i <= n; i++)
          print (reusable[jobs[i]] ? jobs[i] " / " jobs[i] : jobs[i])
      }
    ' "$f"
  done
}

CHECKS_NOW=""; CHECKS_LATER=""
if [ -n "${V[REQUIRED_CHECKS]:-}" ]; then
  # 렌더 결과를 본다. dry-run이면 실제로 쓰지 않았으므로 임시로 한 번 더 렌더한다 —
  # **dry-run에서도 "무엇이 걸리고 무엇이 안 걸리는지"가 보여야** 미리 알 수 있다.
  _probe="$WORK/repo"
  if [ ! -d "$_probe/.github/workflows" ]; then
    _probe="$WORK/probe"; mkdir -p "$_probe"; render_into "$_probe" >/dev/null 2>&1 || true
  fi
  _have=$(producible_checks "$_probe")
  _old_ifs="$IFS"; IFS=','
  for _c in ${V[REQUIRED_CHECKS]}; do
    IFS="$_old_ifs"
    _c="${_c#"${_c%%[![:space:]]*}"}"; _c="${_c%"${_c##*[![:space:]]}"}"
    [ -z "$_c" ] && continue
    if printf '%s\n' "$_have" | grep -qxF "$_c"; then
      CHECKS_NOW="${CHECKS_NOW:+$CHECKS_NOW,}$_c"
    else
      CHECKS_LATER="${CHECKS_LATER:+$CHECKS_LATER,}$_c"
    fi
    IFS=','
  done
  IFS="$_old_ifs"
fi

# ── 리포 설정 ────────────────────────────────────────────────────────────────
step "리포 설정 (bootstrap-repo.sh에 위임)"
BOOTSTRAP_ARGS=("$REPO" --integration "${V[INTEGRATION_BRANCH]}" --production "${V[PRODUCTION_BRANCH]}")
[ -n "$CHECKS_NOW" ] && BOOTSTRAP_ARGS+=(--checks "$CHECKS_NOW")
[ "$DRY" = 1 ] && BOOTSTRAP_ARGS+=(--dry-run)
bash "$SELF_DIR/bootstrap-repo.sh" "${BOOTSTRAP_ARGS[@]}" | sed 's/^/  /'

step "남은 것 — 사람이 해야 한다"
say "  1) 에이전트 App 자격증명:  scripts/sync-secrets.sh $REPO"
say "  2) Claude GitHub App 설치:  github.com/apps/claude → 이 저장소 추가"
say "  3) 렌더된 호출부에서 확인:  risk-paths(위험 경로 정규식)와 verify(검증 명령)"
say "     — 스택 기본값이라 이 프로젝트에 맞는지는 사람이 본다"
say "  4) CI(ci.yml)는 스켈레톤에 없다 — 빌드 게이트는 스택이 소유한다"
if [ -n "$CHECKS_LATER" ]; then
  say ""
  say "  ⚠️ 지금 필수로 걸지 '않은' 체크: $CHECKS_LATER"
  say "     이 이름들은 아직 어떤 워크플로우도 만들지 않는다. 지금 걸면 영구 Pending으로"
  say "     첫 PR부터 머지가 막힌다(devDepth 2026-09-11 실측). ci.yml을 쓰고 **PR에서 그"
  say "     이름이 실제로 보이는 것을 확인한 뒤** 아래로 추가한다:"
  say ""
  say "       gh api -X PATCH repos/$REPO/branches/${V[INTEGRATION_BRANCH]}/protection/required_status_checks \\"
  say "         -f 'contexts[]=<이름1>' -f 'contexts[]=<이름2>'"
  say ""
  say "     실제 이름 확인:  gh pr checks <PR번호> --repo $REPO"
fi
