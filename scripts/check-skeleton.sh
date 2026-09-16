#!/usr/bin/env bash
# 스켈레톤 호출부가 **재사용 워크플로우가 요구하는 값을 실제로 넘기는지** 본다.
#
# 왜 필요한가 (2026-09-16, project-template #5):
# 스켈레톤은 devDepth에서 역산했는데 거기선 통합 브랜치가 `develop`이라 재사용 워크플로우의
# 기본값과 같았고, 그래서 `base-branch`를 **넘기지 않아도 동작했다.** 그 암묵 가정이 그대로
# 스켈레톤에 들어가, 통합 브랜치가 다른 저장소에서는 모든 게이트 job의 `if`가 거짓이 되어
# **전부 skipped**로 조용히 죽었다. PR은 CLEAN으로 보였다 — 통과가 아니라 안 돈 것이다.
#
# **actionlint도 AI 리뷰도 이걸 못 잡았다.** YAML은 유효하고 diff도 이상하지 않다.
# 기계가 볼 수 있는 형태로 바꿔서 이 부류를 게이트에 넣는다.
#
# 요구 목록을 하드코딩하지 않는다 — 재사용 워크플로우가 `base-branch` 입력을 선언하는지에서
# **직접 유도한다.** 입력이 생기거나 사라지면 이 검사도 같이 따라간다.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SKELETON="scripts/skeleton/.github/workflows"
[ -d "$SKELETON" ] || { echo "스켈레톤 디렉터리가 없다: $SKELETON" >&2; exit 1; }

fail=0

# ── 1. base-branch를 요구하는 재사용 워크플로우 목록 ─────────────────────────
requires=""
for f in .github/workflows/*.yml; do
  case "$(basename "$f")" in self-*) continue ;; esac
  if grep -qE '^      base-branch:' "$f"; then
    requires="${requires} $(basename "$f")"
  fi
done
echo "base-branch를 받는 재사용 워크플로우:${requires}"

# ── 2. 그 워크플로우를 부르는 스켈레톤 호출부가 값을 넘기는지 ────────────────
for caller in "$SKELETON"/*.yml; do
  called=$(grep -oE 'uses: superokok/gh-workflows/\.github/workflows/[a-z-]+\.yml' "$caller" \
             | sed 's#.*/##' || true)
  [ -z "$called" ] && continue          # 재사용 워크플로우를 안 부르는 호출부(claude.yml 등)
  case "$requires" in
    *" $called"*)
      if grep -qE '^\s+base-branch:' "$caller"; then
        echo "  ✓ $(basename "$caller") → $called (base-branch 넘김)"
      else
        echo "::error file=$caller::$called 은 base-branch를 받는데 이 호출부가 넘기지 않는다 — 통합 브랜치가 'develop'이 아닌 저장소에서 게이트가 전부 skipped로 죽는다"
        fail=1
      fi
      ;;
    *) echo "  - $(basename "$caller") → $called (base-branch 불필요)" ;;
  esac
done

# ── 3. 렌더된 결과에 자리표시자가 남지 않는지 (프로파일마다) ─────────────────
for prof in scripts/skeleton/profiles/*.env; do
  name="$(basename "$prof" .env)"
  out="$(mktemp -d)"
  if bash scripts/create-project.sh --stack "$name" --render-only "$out" >/dev/null; then
    # 렌더된 결과도 actionlint에 태운다. 스켈레톤 원본은 자리표시자 때문에 그대로는 못 태우고,
    # 값이 들어간 뒤라야 진짜 워크플로우가 된다. `lint-workflows.sh`가 받아둔 바이너리를 쓴다.
    if [ -x ./actionlint ] && ! ./actionlint "$out"/.github/workflows/*.yml; then
      echo "::error::$name 프로파일 렌더 결과가 actionlint를 통과하지 못했다"
      fail=1
    else
      echo "  ✓ $name 프로파일 렌더 + actionlint 통과"
    fi
  else
    echo "::error::$name 프로파일 렌더 실패"
    fail=1
  fi
  rm -rf "$out"
done

[ "$fail" = 0 ] || { echo; echo "스켈레톤 계약 검사 실패"; exit 1; }
echo
echo "스켈레톤 계약 검사 통과"
