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
- **GitHub Pro 이상** — private 저장소의 브랜치 보호/룰셋이 Pro부터다. Free면 네이티브
  auto-merge를 못 써서 이 저장소의 머지 게이트를 쓸 수 없다
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

### `enable-auto-merge.yml` — 머지 게이트 (브랜치 보호 + 네이티브 auto-merge)

**전제: 브랜치 보호(또는 룰셋)에 required status checks가 설정돼 있고, Settings → General →
Allow auto-merge가 켜져 있어야 한다.** 둘 다 GitHub Pro 이상에서 private 저장소에 쓸 수 있다.
없으면 `gh pr merge --auto`가 거부돼 아무것도 머지되지 않는다.

```yaml
name: Enable auto-merge
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  decide:
    permissions:
      contents: write
      pull-requests: write
      issues: write
    uses: superokok/gh-workflows/.github/workflows/enable-auto-merge.yml@main
    secrets: inherit
    with:
      risk-paths: '^(prisma/|package\.json$|\.github/workflows/|\.env|Dockerfile|...)'
```

**머지 판정은 GitHub이 한다.** 이 워크플로우가 하는 일은 "이 PR에 auto-merge를 켤까 말까"를
한 번 정하는 것뿐이다. 게이트 구성은 브랜치 보호의 required checks로 표현한다.

`risk-paths`만 필수다. 걸리는 파일이 하나라도 바뀌면 **auto-merge를 켜지 않고**
`do-not-merge` 라벨과 `[AGENT-ACTION-REQUIRED]` 코멘트를 남겨 사람 머지로 넘긴다. 나중 push로
위험해지면 이미 켜둔 auto-merge를 **끈다**. **프로젝트마다 위험한 곳이 다르므로 기본값을
두지 않았다** — 안 넘기면 워크플로우가 뜨지 않는다.

> **위험 경로를 "체크 실패"로 만들지 않는다.** 필수 체크를 실패시키면 사람도 머지를 못 하게
> 된다(관리자 우회 필요). 네이티브 auto-merge는 PR별 opt-in이라 **안 켜는 것 자체가 게이트**다 —
> 체크는 전부 초록인 채로 머지 버튼만 사람 몫으로 남는다.

#### 필수 체크로 무엇을 넣을지

**`pull_request`로 트리거되는 것만 넣는다.** 워크플로우가 아예 안 돌면 그 체크는 영구
`Pending`으로 남아 머지를 영원히 막는다(잡이 `skip`되는 건 `success`로 취급돼 무해하다 —
둘은 다르다).

`preview-smoke.yml`이 그래서 `deployment_status` → `pull_request`로 바뀌었다(2026-09-09).
배포 URL을 이벤트로 받는 대신 **직접 조회하며 기다리므로** 어떤 경우에도 결론을 낸다 —
`smoke`를 필수 체크로 올릴 수 있다. 호출부 트리거를 이렇게 잡는다:

```yaml
name: Preview Smoke
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  smoke:
    permissions:
      contents: read
      deployments: read
    uses: superokok/gh-workflows/.github/workflows/preview-smoke.yml@main
    secrets: inherit
```

### 나머지

| 호출부 파일 | `uses:` | 트리거 |
|---|---|---|
| `after-merge.yml` | `after-merge.yml@main` | `pull_request: {types: [closed]}` |
| `claude-review.yml` | `claude-review.yml@main` | `pull_request: {types: [opened, synchronize, ready_for_review, reopened]}` |
| `claude-agent.yml` | `claude-agent.yml@main` | `issues: {types: [labeled]}` |
| `claude-fix.yml` | `claude-fix.yml@main` | `workflow_run: {workflows: ["CI", "Preview Smoke"], types: [completed]}` + `status:` |
| `preview-smoke.yml` | `preview-smoke.yml@main` | `pull_request: {types: [opened, synchronize, reopened, ready_for_review]}` |
| `release-pr.yml` | `release-pr.yml@main` (선택 입력 `pre-merge-note`: staging 링크·머지 방식 등 프로젝트별 안내 마크다운) | `push: {branches: [develop]}` + `workflow_dispatch:` |

`claude.yml`(`@claude` 멘션 응답)은 `/install-github-app`이 프로젝트에 직접 만들어 주므로
여기 없다. 배포(`deploy.yml`)·모바일 빌드도 프로젝트 고유라 각자 소유한다.

## 알아둘 것

- **`claude-agent`는 저장소당 하나만 돈다**(concurrency 그룹이 저장소 단위). 이슈별로 묶으면
  서로 다른 이슈의 에이전트가 병렬로 돌고 둘 다 "열린 PR 없음"을 봐서 WIP 제한이 뚫린다 —
  check-then-act 경합이다(2026-09-09 실측: 45초 간격으로 PR이 둘 열렸다). 대기 슬롯은
  하나뿐이라 세 번째가 오면 두 번째가 취소되는데, 그 이슈는 `agent` 라벨만 남고 멈춘다 —
  `drain-queue`가 그런 것도 라벨을 뗐다 붙여 되살린다.
- **WIP 제한 1 — 동시에 열린 작업 PR은 하나뿐이다.** 둘 이상이면 충돌이 **구조적으로**
  발생한다(겹치는 코드가 없어도 난다 — 2026-09-09 PR #190·#191이 서로 무관한데 변경 기록
  파일 끝에서 충돌했다). `claude-agent`는 열린 PR이 있으면 착수하지 않고 이슈를
  `agent-queued`로 대기시키고, `after-merge`의 `drain-queue`가 판이 비면 가장 오래 기다린
  것 하나를 다시 `agent`로 돌린다 — **사람이 스케줄러가 되지 않는다.** 릴리스 PR(base=main)은
  항상 열려 있으므로 세지 않는다. 이 방식은 `strict`(브랜치 최신화 요구)나 merge queue를
  불필요하게 만든다 — merge queue는 private 저장소에서 Enterprise Cloud + 조직 소유가
  필요해 어차피 못 쓴다.

- **Actions 분은 job 단위로 올림 과금된다 — job 수가 곧 비용이다.** 2026-09-10 실측(두 저장소
  65.8시간, job 350개): 실제 468분인데 **청구 715분**, 차이 247분(35%)이 전부 1분 미만 job의
  올림이었다. 그래서 규칙은 셋이다.
  1. **짧은 단계를 별도 job으로 나누지 않는다.** `lint`를 `check` job의 step으로 합친 이유다
     (실측 42 job / 실제 4.3분 / 청구 42분). 병렬로 얻을 게 없으면 같은 job에 붙인다.
  2. **`push:` 트리거를 습관적으로 걸지 않는다.** WIP 제한 1이라 PR과 머지 후 트리는 같다 —
     같은 검사를 한 번 더 청구할 뿐이다(`self-lint`의 `push: main`을 이래서 뺐다).
  3. **비싼 step은 변경 파일로 건너뛴다.** `claude-review`·`preview-smoke`의
     `skip-paths-regex`가 그것이고, **워크플로우 수준 `paths:` 필터는 절대 쓰지 않는다** —
     job이 아예 안 돌면 check-run이 생성되지 않고, 필수 체크가 "없는" 상태는 `success`가
     아니라 **영구 Pending**이라 PR을 영원히 막는다. step만 스킵하면 job은 `success`로 끝난다.
- **`run:` 블록에서 `grep -q`·`head`로 파이프를 일찍 닫지 않는다.** `set -o pipefail`에서
  앞 명령이 SIGPIPE(141)로 죽어 파이프라인 전체가 실패로 잡히고, "조회 실패"와 "결과 없음"이
  구별되지 않는다. 전부 읽는 형태(`grep -v` 결과를 변수에 담아 비었는지 확인)로 쓴다.
- **재사용 워크플로우에서 `uses: ./...`(로컬 composite action)은 쓸 수 없다.** 그 경로는
  **호출부 저장소**를 가리키므로 다른 프로젝트에서 부르면 깨진다. 공유하고 싶은 짧은 로직은
  각 워크플로우에 인라인으로 둔다(`skip-paths-regex` 판정이 그래서 두 곳에 같이 있다).
- **재사용 워크플로우를 *삭제*할 때는 순서가 반대다.** 추가·수정은 여기를 먼저 고치고 소비
  프로젝트가 따라오면 되지만, 삭제는 소비 프로젝트의 **`main`까지 호출부가 걷힌 뒤**에 해야
  한다. `workflow_run`/`status`/`schedule` 호출부는 default 브랜치 버전이 도는데, 여기서
  파일을 먼저 지우면 그 호출부가 없어진 워크플로우를 부르며 계속 실패한다
  (2026-09-09 실제 발생: `auto-merge.yml`을 여기서 먼저 지워 kitchen-tempo `main`이
  릴리스될 때까지 매 이벤트마다 실패했다).
- **`allowed_bots`가 없으면 봇이 트리거한 실행은 거부된다** (`Workflow initiated by
  non-human actor`). 셋 다 필요하지만 트리거 경로는 워크플로우마다 다르다:
  - `claude-agent`: 리뷰가 후속 이슈에 `agent` 라벨을 자동으로 붙이면 그 `issues: labeled`
    이벤트의 actor가 봇이라 거부된다 (2026-09-09 실제 발생).
  - `claude-fix`: `issues: labeled`와 무관하게 `workflow_run`/`status`로만 깨어난다. 봇이
    push한 커밋(claude-agent가 연 PR, claude-fix 자신이 단 수정 커밋)에서 도는 CI/Vercel이
    이 job을 깨우면 그 이벤트의 actor도 봇이라 마찬가지로 거부된다.
  - `claude-review`: 에이전트가 만든 PR(작성자가 봇)을 리뷰 대상으로 삼으므로 필요하다.

- **호출부 job은 `permissions`를 반드시 명시한다.** 불린 워크플로우가 요구하는 권한을
  호출부가 안 주면 job이 시작도 못 하고 `startup_failure`로 죽는다 — 로그도 안 남고
  check-run도 안 생긴다. `id-token: write`를 요구하는 건 `claude-review`·`claude-agent`·
  `claude-fix` 셋이다. 2026-09-07 kitchen-tempo에서 이걸 빠뜨려 Claude Review가 전부 죽었고,
  `review` check-run이 없으니 auto-merge는 "대기"로만 보여 **3시간 동안 알림 없이 정지**했다.
- **`agent` 라벨은 "처리 중/처리 대기" 상태를 뜻한다 — 손을 뗄 땐 라벨도 뗀다.** 이 루프는
  `issues: labeled`로 깨어나므로 **이미 붙어 있는 라벨은 다시 붙일 수 없다**. 에이전트가
  계획만 남기고 빠지거나(사전 계획 게이트) 리뷰가 깊이 2에서 멈출 때 라벨을 떼둔다.
- **재개는 `@claude` 코멘트가 기본 경로다.** 사용자가 라벨 규칙을 외우게 하지 않는다 —
  멈춘 이슈에 `@claude 진행해줘` 한 줄이면 이어진다. 이건 소비 프로젝트가 `@claude` 멘션
  워크플로우(kitchen-tempo의 `claude.yml`)를 갖고 있을 때의 얘기이고, 없는 저장소에서는
  `agent` 라벨을 (떼었다) 붙이는 게 유일한 경로다. 멈춤 안내 코멘트는 두 방법을 다 적는다.
- **감시용 cron 워크플로우는 두지 않는다(2026-09-07 `stale-sweep.yml` 삭제).** 위 두 사고는 전부
  "일어나야 할 이벤트가 안 와서 아무도 모르는" 형태라, 처음엔 매시 도는 스윕으로 메웠다. 그런데
  **감시자를 GitHub Actions 위에 두면 Actions가 죽을 때 감시자도 같이 죽고 침묵한다 — 그리고 침묵은
  정상과 구별되지 않는다.** 실제로 Actions 분 할당량이 소진되자 스윕도 같이 멈췄고, 정작 그 사고를
  아무도 못 알아챘다. 알림이 메일로 가는데 사용자가 메일을 잘 보지 않아 도달률도 0이었다.
  **대체 수단은 소비 프로젝트의 세션 시작 브리핑이다** — 모든 작업이 Claude 세션을 거치므로, 세션이
  시작될 때 `gh pr list`/`gh run list`로 상태를 훑어 보고한다. 세션은 Actions 위에서 돌지 않아
  Actions가 통째로 멈춰도 동작한다(kitchen-tempo `CLAUDE.md` "📢 알림" 참고).
  사유 저장소에서 매시 cron은 월 720분 = Free 할당량 2,000분의 3분의 1이기도 하다.

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
  `<호출 잡> / <불린 잡>`으로 이름을 만든다. 브랜치 보호에서 필수 체크를 지정할 때
  `check`가 아니라 **`check / check`**로 잡아야 한다.
- **private 저장소끼리 부르려면 접근 허용이 필요하다**: 이 저장소
  Settings → Actions → General → Access → *Accessible from repositories owned by the user*.
- 태그가 아니라 `@main`으로 고정해 두면 고친 즉시 모든 프로젝트에 반영된다. 반대로 한 곳의
  실수가 모든 프로젝트를 멈출 수 있으니, 큰 변경은 한 프로젝트에서 `@<sha>`로 먼저 확인한다.

## 이 저장소 자신 (`self-*.yml`)

재사용 워크플로우를 여기로 분리하면서, 워크플로우 관련 리뷰 후속 이슈는 소비
프로젝트에 생기는데 **고칠 코드는 여기 있고 여긄 루프가 없는** 상태가 됐다. 그래서
이 저장소도 같은 루프를 자기 자신에게 건다 (2026-09-07).

| 파일 | 역할 |
|---|---|
| `self-lint.yml` | `actionlint`로 워크플로우 YAML 검증. 여깔 `package.json`이 없어 `check.yml`을 못 쓴다 |
| `self-review.yml` | 이 저장소 PR에도 2차 AI 리뷰 |
| `self-agent.yml` | `agent` 라벨 이슈 → PR |

> ⚠️ **`self-*`는 이 저장소 자신의 시크릿을 쓴다.** 재사용 워크플로우를 "라이브러리"로만
> 쓸 땐 여기 시크릿이 필요 없었지만, 자기 루프를 돌리는 순간 필요해진다 —
> `secrets: inherit`은 **호출부가 있는 저장소**의 시크릿을 물려주기 때문이다.
> 없으면 `Environment variable validation failed`로 죽는다(2026-09-07 실제로 겪음).
>
> ```bash
> gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo superokok/gh-workflows
> gh secret set AGENT_WORKFLOW_TOKEN    --repo superokok/gh-workflows
> ```
>
> Claude GitHub App도 이 저장소에 설치돼 있어야 인라인 리뷰 코멘트가 달린다.
> `self-lint`·`self-after-merge`는 `GITHUB_TOKEN`만 써서 시크릿 없이도 돈다.

**로컬 경로(`./.github/workflows/...`)로 부른다.** 여기가 원본이라 `@main`으로 부르면
PR 브랜치의 변경이 아니라 이미 머지된 버전이 돌아버린다.

검증 커맨드는 CI 게이트와 에이전트가 **같은 것**을 보게 `scripts/lint-workflows.sh` 하나로 묶었다.

## 브랜치 전략 — `main` 하나 + 브랜치·PR

소비 프로젝트는 `develop`(통합) / `main`(운영) 둘이지만, **이 저장소는 `main` 하나다.**
의도된 선택이다.

- 소비 프로젝트가 `@main`으로 고정해 부르므로 **`main`이 곳 배포본**이다. 그 앞에
  `develop`을 두면 아무도 참조하지 않는 브랜치가 하나 생길 뿐이다 — 막아주는 게 없는데
  안전하다는 느낌만 준다
- `develop`의 존재 이유는 스테이징 배포 대상(Vercel Preview·staging)인데 여긴 배포가 없다
- 재사용 워크플로우는 **실제 소비 PR이 한 번 돌아야** 런타임 검증이 된다. 브랜치를
  더 둠다고 해결되지 않는다 — 그건 한 프로젝트에서 `@<sha>`로 먼저 불러보는 걸로 푸는다

대신 지키는 것:

- **`main` 직접 push 안 함.** 작은 변경도 브랜치 따서 PR
- **auto-merge 안 붙임.** 여기어 모든 변경은 정의상 위험 경로다 — 한 줄이 모든 소비
  프로젝트의 CI를 멈추게 할 수 있다. 사람이 diff 보고 머지한다(소비 프로젝트의
  `develop`→`main`과 같은 자리). 즉 에이전트가 여기서 하는 일은 **PR까지**다
- 큰 변경은 한 프로젝트에서 `@<sha>`로 먼저 확인한 뒤 머지

## 새 프로젝트에 붙이기

1. 위 호출부 파일들을 `.github/workflows/`에 만든다 (`risk-paths`만 프로젝트에 맞게)
2. Secrets 등록, 라벨 2개 생성, Vercel 연결
3. `superokok/claude-ops` 플러그인 설치 — 에이전트 쪽 규칙·스킬·훅
