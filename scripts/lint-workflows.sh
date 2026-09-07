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
