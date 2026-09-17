#!/usr/bin/env bash
# `enable-auto-merge.yml`의 "게이트 약화 검사" 스텝 회귀 테스트.
#
# **이 검사가 사람 게이트를 대체한다.** 예전엔 "게이트 파일을 건드리면 사람 머지"였는데,
# 그 게이트는 같은 경로를 건드릴 때마다 매번 울려서 결국 안 읽고 통과시키게 됐다 — 지연만
# 남고 검출은 0이었다. 대신 **무엇을 했는지**를 diff에서 보기로 했으니, 그 판정이 맞는지는
# 테스트가 지켜야 한다. 안 그러면 게이트를 게이트 없이 바꾼 것이 된다.
#
# 스크립트와 표식 기본값을 **워크플로우 원문에서 떼어내** 쓴다 — 여기에 복사해두면
# 워크플로우가 바뀔 때 테스트만 옛 동작을 통과시킨다.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
WF=".github/workflows/enable-auto-merge.yml"
PY="${PYTHON:-python3}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export RUNNER_TEMP="$WORK/tmp"; mkdir -p "$RUNNER_TEMP"

STEP="$WORK/step.sh"
"$PY" scripts/extract-block.py "$WF" step "게이트 약화 검사" > "$STEP"
[ -s "$STEP" ] || { echo "스텝 추출 실패" >&2; exit 1; }

MARKERS="$("$PY" scripts/extract-block.py "$WF" input gate-weakening-markers)"
GATE_PATHS='^(\.github/workflows/|\.claude/|scripts/hooks/|common/)'
export MARKERS GATE_PATHS
export BASE=develop
export PAIRED=''          # 스텝이 `set -u` 아래라 항상 정의돼 있어야 한다

pass=0; fail=0

run_step() {
  rm -f "$RUNNER_TEMP/gate-findings.txt"
  if ! bash "$STEP" > "$WORK/step.log" 2>&1; then
    echo "      !! 스텝이 0이 아닌 코드로 끝났다:"; sed 's/^/      /' "$WORK/step.log"
  fi
}

check() { # 이름, 기대(hit|clean)
  local name="$1" expect="$2" got=clean
  [ -s "$RUNNER_TEMP/gate-findings.txt" ] && got=hit
  if [ "$got" = "$expect" ]; then
    printf '  ok   %s\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL %s (기대=%s 실제=%s)\n' "$name" "$expect" "$got"; fail=$((fail+1))
  fi
  if [ -s "$RUNNER_TEMP/gate-findings.txt" ]; then
    sed 's/^/         /' "$RUNNER_TEMP/gate-findings.txt"
  fi
  return 0
}

# 소비 저장소의 최소 형태를 만든다 — 호출부·CI·훅·훅 등록.
setup_repo() {
  rm -rf "$WORK/r"; mkdir -p "$WORK/r"; cd "$WORK/r"
  git init -q -b develop
  git config core.autocrlf false
  git config user.email t@example.com; git config user.name t
  mkdir -p .github/workflows .claude/hooks scripts/hooks common/.claude/hooks common/scripts/hooks
  cat > .github/workflows/ci.yml <<'YML'
name: CI
on:
  pull_request:
jobs:
  web:
    runs-on: ubuntu-latest
    steps:
      - run: npm run lint
      - run: npm run test:hooks
YML
  cat > .github/workflows/enable-auto-merge.yml <<'YML'
name: Enable auto-merge
on:
  pull_request:
jobs:
  decide:
    permissions:
      contents: write
    uses: superokok/gh-workflows/.github/workflows/enable-auto-merge.yml@v1
    with:
      base-branch: develop
      risk-paths: '^(secret)'
YML
  cat > .claude/settings.json <<'JSON'
{ "hooks": { "PreToolUse": [ { "command": ".claude/hooks/guard-branch.sh" } ] } }
JSON
  echo "echo guard" > .claude/hooks/guard-branch.sh
  echo "echo test"  > scripts/hooks/run-tests.sh
  echo "echo guard" > common/.claude/hooks/guard-branch.sh
  echo "echo test"  > common/scripts/hooks/guard-branch.test.sh
  echo "# readme"   > README.md
  git add -A >/dev/null; git commit -qm base
  git update-ref refs/remotes/origin/develop HEAD   # 스텝이 보는 이름 그대로
  git switch -qc work
}

drop_line() { # 파일에서 문자열을 포함한 줄을 지운다
  "$PY" - "$1" "$2" <<'PY'
import io, sys
p, needle = sys.argv[1], sys.argv[2]
out = [l for l in io.open(p, encoding='utf-8').read().split('\n') if needle not in l]
io.open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
PY
}

sub_line() { # 파일에서 문자열을 다른 문자열로 바꾼다
  "$PY" - "$1" "$2" "$3" <<'PY'
import io, sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding='utf-8').read()
assert old in s, old
io.open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new, 1))
PY
}

echo "── 게이트를 약하게 만드는 변경은 잡아야 한다 ──"

setup_repo
sub_line .github/workflows/enable-auto-merge.yml "    permissions:
      contents: write
" ""
git commit -qam x; run_step
check "호출부의 permissions 블록 삭제 (잡이 startup_failure로 조용히 죽는다)" hit

setup_repo
drop_line .github/workflows/enable-auto-merge.yml "base-branch: develop"
git commit -qam x; run_step
check "base-branch 전달 삭제 (게이트 job이 전부 skipped가 된다)" hit

setup_repo
drop_line .github/workflows/enable-auto-merge.yml "risk-paths:"
git commit -qam x; run_step
check "risk-paths 삭제" hit

setup_repo
drop_line .github/workflows/ci.yml "npm run test:hooks"
git commit -qam x; run_step
check "CI에서 훅 테스트 호출 삭제" hit

setup_repo
echo '{ "hooks": {} }' > .claude/settings.json
git commit -qam x; run_step
check "settings.json에서 훅 등록 삭제 (훅이 조용히 안 돈다)" hit

setup_repo
sub_line .github/workflows/ci.yml "      - run: npm run lint" "      - run: npm run lint
        continue-on-error: true"
git commit -qam x; run_step
check "continue-on-error: true 추가 (빨간불이 초록으로 보고된다)" hit

setup_repo
sub_line .github/workflows/ci.yml "  pull_request:" "  workflow_dispatch:"
git commit -qam x; run_step
check "CI의 pull_request 트리거 삭제 (검사가 아예 안 돈다)" hit

echo
echo "── 게이트와 무관하거나 오히려 강화하는 변경은 통과해야 한다 ──"

setup_repo
echo "# 주석" >> .github/workflows/ci.yml
git commit -qam x; run_step
check "워크플로우에 주석만 추가" clean

setup_repo
echo "새 줄" >> README.md
git commit -qam x; run_step
check "게이트 범위 밖 파일만 변경 (체크아웃도 안 한다)" clean

setup_repo
sub_line .github/workflows/ci.yml "      - run: npm run lint" "      - run: npm run lint
      - run: npm run typecheck"
git commit -qam x; run_step
check "CI에 검증 단계 추가" clean

echo
echo "── 짝 변경 규칙 ──"
export PAIRED='^common/\.claude/hooks/||^common/scripts/hooks/'

setup_repo
echo "if [ \"\$1\" = ok ]; then exit 0; fi" >> common/.claude/hooks/guard-branch.sh
git commit -qam x; run_step
check "훅에 우회로를 더하고 테스트는 안 건드림" hit

setup_repo
echo "if [ \"\$1\" = ok ]; then exit 0; fi" >> common/.claude/hooks/guard-branch.sh
echo "# 새 케이스" >> common/scripts/hooks/guard-branch.test.sh
git commit -qam x; run_step
check "훅과 테스트를 같이 고침" clean

export PAIRED=''

echo
echo "통과 $pass · 실패 $fail"
[ "$fail" -eq 0 ]
