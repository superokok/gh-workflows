# gh-workflows

에이전트 운영 루프(이슈 → 구현 → PR → 게이트 → 자동 머지 → 릴리스)의 **재사용 워크플로우**.
프로젝트마다 800줄짜리 YAML을 복사하지 않고, 여기 한 곳을 고치면 모든 프로젝트에 반영된다.

원본은 `kitchen-tempo`에서 시행착오로 만들어진 것이고, 이 저장소는 **트리거(`on:`) 블록만
`workflow_call`로 갈아끼운 그대로의 복사본**이다 — 로직은 손대지 않았다. 배경은 그 프로젝트의
`docs/adr/0002`(검증 레이어) · `0003`(브랜치·리뷰) · `0007`(자율 루프) · `0008`(운영 모델) ·
`0010`(머지 게이트).

## 전제 (프로젝트가 갖춰야 하는 것)

- 브랜치: `develop`(통합) / `main`(운영). 작업은 항상 `origin/develop`에서 딴 브랜치에서
- Node + npm, `npm run typecheck` / `test` / `lint`
- Vercel Preview (커밋 status `Vercel`) — 없으면 `check.yml`만 쓰고 auto-merge는 안 쓰는 편이 낫다
- 라벨 `do-not-merge`, `agent` (`review-followup` · `followup-pr`은 워크플로우가 알아서 만든다)
- Secrets: `CLAUDE_CODE_OAUTH_TOKEN`, `AGENT_WORKFLOW_TOKEN`(repo+workflow 스코프 PAT),
  `DOTENV_PRIVATE_KEY`(dotenvx 쓸 때), `VERCEL_AUTOMATION_BYPASS_SECRET`(프리뷰 스모크 쓸 때)

> **`secrets: inherit`을 반드시 넘긴다.** 재사용 워크플로우는 호출부의 시크릿을 자동으로
> 물려받지 않는다. 빼먹으면 조용히 인증이 없는 채로 돌다 실패한다.

## 호출부 (프로젝트 `.github/workflows/`)

트리거는 **호출부가 소유한다** — 재사용 워크플로우는 `on:`을 가질 수 없기 때문이다.
`workflow_run`으로 다른 워크플로우를 기다리는 파일들은 이름(`workflows: [...]`)으로 매칭하므로,
아래 `name:`을 바꾸면 그쪽도 같이 바꿔야 한다.

### `ci.yml` — 빠른 검증 게이트

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [develop, main]
jobs:
  check:
    uses: superokok/gh-workflows/.github/workflows/check.yml@main
    secrets: inherit
```

`check.yml`의 각 단계는 커맨드 문자열 입력이라, 빈 문자열을 넘기면 그 단계를 건너뛴다
(Prisma를 안 쓰면 `prepare: ""`, `schema-validate: ""`).

### `auto-merge.yml` — 머지 게이트

```yaml
name: Auto-merge to develop
on:
  workflow_run:
    workflows: ["CI", "Claude Review", "Preview Smoke"]
    types: [completed]
  status:
jobs:
  merge:
    uses: superokok/gh-workflows/.github/workflows/auto-merge.yml@main
    secrets: inherit
    with:
      risk-paths: '^(prisma/|package\.json$|\.github/workflows/|\.env|Dockerfile|...)'
      require-smoke-gate: true   # preview-smoke.yml을 쓰는 경우만. 안 쓰면 생략(기본 false)
```

`risk-paths`만 필수다. 걸리는 파일이 하나라도 바뀌면 자동 머지를 멈추고 `do-not-merge` 라벨과
`[AGENT-ACTION-REQUIRED]` 코멘트를 남겨 사람 머지로 넘긴다. **프로젝트마다 위험한 곳이 다르므로
기본값을 두지 않았다** — 안 넘기면 워크플로우가 뜨지 않는다.

`require-smoke-gate: true`로 두면 `smoke`(preview-smoke.yml)라는 이름의 check-run이
success/skipped/neutral일 때까지 머지를 미룬다. **`preview-smoke.yml`을 안 쓰면서 이걸
true로 두면 그 이름의 check-run이 영원히 안 생겨 자동 머지가 영구히 멈춘다** — 기본값은
안전하게 `false`.

### 나머지

| 호출부 파일 | `uses:` | 트리거 |
|---|---|---|
| `after-merge.yml` | `after-merge.yml@main` | `pull_request: {types: [closed]}` |
| `claude-review.yml` | `claude-review.yml@main` | `pull_request: {types: [opened, synchronize, ready_for_review, reopened]}` |
| `claude-agent.yml` | `claude-agent.yml@main` | `issues: {types: [labeled]}` |
| `claude-fix.yml` | `claude-fix.yml@main` | `workflow_run: {workflows: ["CI", "Preview Smoke"], types: [completed]}` + `status:` |
| `preview-smoke.yml` | `preview-smoke.yml@main` | `deployment_status:` |
| `release-pr.yml` | `release-pr.yml@main` (선택 입력 `pre-merge-note`: staging 링크·머지 방식 등 프로젝트별 안내 마크다운) | `push: {branches: [develop]}` + `workflow_dispatch:` |

`claude.yml`(`@claude` 멘션 응답)은 `/install-github-app`이 프로젝트에 직접 만들어 주므로
여기 없다. 배포(`deploy.yml`)·모바일 빌드도 프로젝트 고유라 각자 소유한다.

## 알아둘 것

- **후속 이슈는 사람 없이 착수되고, 연쇄는 깊이 1로 막힌다.** `claude-review.yml`이
  차단하지 않은 지적을 `review-followup` + `agent` 라벨 이슈로 남기면 `claude-agent.yml`이
  즉시 집어간다. 그 후속 PR에는 `followup-pr` 라벨이 붙고, 리뷰는 그 라벨을 보면
  **새 이슈를 만들지 않고 원래 이슈에 코멘트로 덧붙인다**(닫혔으면 reopen). 계보
  하나당 이슈 1개로 고정된다. 깊이 2 이상의 지적은 `agent` 라벨을 안 붙이므로
  거기서만 사람이 본다. 고위험 차단(`do-not-merge`)은 깊이와 무관하게 항상 동작한다.
- **`claude-review.yml`은 `AGENT_WORKFLOW_TOKEN`으로 라벨을 붙인다.** `GITHUB_TOKEN`으로
  만든 이벤트는 다른 워크플로우를 트리거하지 않아(GitHub 플랫폼 제약), 그 토큰으로
  `agent`를 붙이면 `claude-agent.yml`이 깨어나지 않아 이슈가 그대로 방치된다.

- **`workflow_run` / `status` / `deployment_status` 트리거는 default 브랜치(`main`)에 있는
  호출부 파일이 동작한다.** 즉 그 파일들을 고치면 `develop`→`main` 릴리스 후에 효력이 생긴다.
- **check-run 이름이 `잡이름 / 잡이름`이 된다.** 재사용 워크플로우를 부르면 GitHub이
  `<호출 잡> / <불린 잡>`으로 이름을 만든다. `auto-merge.yml`은 그래서 정확히 일치하는 이름과
  `/ 이름`으로 끝나는 이름을 모두 게이트로 본다. 브랜치 보호에서 필수 체크를 지정할 때도
  `check`가 아니라 `check / check`로 잡아야 한다.
- **private 저장소끼리 부르려면 접근 허용이 필요하다**: 이 저장소
  Settings → Actions → General → Access → *Accessible from repositories owned by the user*.
- 태그가 아니라 `@main`으로 고정해 두면 고친 즉시 모든 프로젝트에 반영된다. 반대로 한 곳의
  실수가 모든 프로젝트를 멈출 수 있으니, 큰 변경은 한 프로젝트에서 `@<sha>`로 먼저 확인한다.

## 새 프로젝트에 붙이기

1. 위 호출부 파일들을 `.github/workflows/`에 만든다 (`risk-paths`만 프로젝트에 맞게)
2. Secrets 등록, 라벨 2개 생성, Vercel 연결
3. `superokok/claude-ops` 플러그인 설치 — 에이전트 쪽 규칙·스킬·훅
