#!/usr/bin/env bash
# 워크플로우 YAML 검증 (actionlint).
# CI 게이트(self-lint.yml)와 에이전트의 검증 커맨드가 **같은 것**을 보게 하려고 스크립트로 뺐다.
set -euo pipefail

VERSION="${ACTIONLINT_VERSION:-1.7.7}"

# actionlint는 `run:` 블록을 shellcheck로도 검사한다 — 이게 진짜 값어치의 절반이다.
# 실제로 큰따옴표 안의 백틱이 명령 치환으로 해석되는 버그를 여기서 잡았다(2026-09-07).
# shellcheck가 없으면 그 검사가 **조용히 통째로 빠지고 그래도 exit 0**이라, 로컬에서
# "통과"를 보고 CI에서 깨지는 일이 생긴다. 그래서 없으면 눈에 띄게 경고한다.
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "⚠️  shellcheck가 없어 run: 블록 검사를 건너뜁니다 — 이 결과는 CI와 다를 수 있습니다." >&2
fi

# SC2016(단일 따옴표 안에서 $ 확장 안 됨)은 여기선 대부분 의도된 것이다:
# jq 필터, 마크다운 본문, GitHub 표현식을 일부러 리터럴로 둔다. info 레벨이라 무시한다.
export SHELLCHECK_OPTS="${SHELLCHECK_OPTS:--e SC2016}"

if [ ! -x ./actionlint ]; then
  bash <(curl -sSfL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) "$VERSION" >/dev/null
fi

./actionlint -color

# 로컬 composite action(`.github/actions/...`) 참조를 금지한다 — `./.github/actions/...`
# 형태와 `owner/repo/.github/actions/...@ref` 형태 둘 다. 재사용 워크플로우는 소비 저장소
# 워크스페이스에서 실행되므로 `./` 참조는 해석할 수 없고, `@main` 절대 참조는 도입 PR
# 자신을 검증할 수 없다(main에 아직 없다). 둘 다 실측으로 startup_failure를 냈다
# (PR #59 notify-assignee-if-clean, PR #62 assign-if-clean, 그리고 뒤늦게 발견된
# PR #56의 label-with-retry — 셋 다 같은 함정). 셸 중복을 감수한다.
bad_action_refs=""
for f in .github/workflows/*.yml; do
  match=$(sed -E 's/#.*$//' "$f" | grep -n 'uses:.*\.github/actions/' | sed "s#^#$f:#") || true
  [ -n "$match" ] && bad_action_refs="${bad_action_refs}${match}"$'\n'
done
if [ -n "$bad_action_refs" ]; then
  echo "::error::재사용 워크플로우는 소비 저장소 워크스페이스에서 실행되므로 로컬 액션을 해석할 수 없다. @main 절대 참조는 도입 PR에서 검증 불가. 셸 중복을 감수한다. (PR #59·#62)"
  printf '%s\n' "$bad_action_refs"
  exit 1
fi
