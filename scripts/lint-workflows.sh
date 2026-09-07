#!/usr/bin/env bash
# 워크플로우 YAML 검증 (actionlint).
# CI 게이트(self-lint.yml)와 에이전트의 검증 커맨드가 **같은 것**을 보게 하려고 스크립트로 뺐다.
set -euo pipefail

VERSION="${ACTIONLINT_VERSION:-1.7.7}"

if [ ! -x ./actionlint ]; then
  bash <(curl -sSfL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) "$VERSION" >/dev/null
fi

./actionlint -color
