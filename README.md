# gh-workflows

에이전트 운영 루프(이슈 → 구현 → PR → 게이트 → 자동 머지 → 릴리스)의 **재사용 워크플로우**.
프로젝트마다 800줄짜리 YAML을 복사하지 않고, 여기 한 곳을 고치면 모든 프로젝트에 반영된다.

원본은 `kitchen-tempo`에서 시행착오로 만들어진 것이고, 이 저장소는 **트리거(`on:`) 블록만
`workflow_call`로 갈아끼운 그대로의 복사본**이다 — 로직은 손대지 않았다. 배경은 그 프로젝트의
`docs/adr/0002`(검증 레이어) · `0003`(브랜치·리뷰) · `0007`(자율 루프) · `0008`(운영 모델) ·
`0010`(머지 게이트).

> 워크플로우 주석 곳곳의 `docs/adr/…`는 **그 원본 프로젝트의 private 문서**를 가리킨다.
> 여기서는 열리지 않는다 — 주석은 결론과 근거를 그 자리에 적어두므로 링크를 못 따라가도
> 읽는 데 문제는 없다. 사고 기록에 나오는 저장소 이름들도 같다(private).

## 전제 (프로젝트가 갖춰야 하는 것)

- 브랜치: `develop`(통합) / `main`(운영). 작업은 항상 `origin/develop`에서 딴 브랜치에서
- 검증 커맨드 — 기본값은 Node 기준(`npm run typecheck` / `test` / `lint`)이지만 전부
  커맨드 문자열 입력이라 스택에 매이지 않는다. 툴체인도 선택값이다(아래 `ci.yml`)
- Vercel Preview (커밋 status `Vercel`) — 없으면 `check.yml`만 쓰고 auto-merge는 안 쓰는 편이 낫다
- **GitHub Pro 이상** — private 저장소의 브랜치 보호/룰셋이 Pro부터다. Free면 네이티브
  auto-merge를 못 써서 이 저장소의 머지 게이트를 쓸 수 없다
- 라벨 `do-not-merge`, `agent` (`review-followup` · `followup-pr`은 워크플로우가 알아서 만든다)
- **이 루프 전용 GitHub App** + Secrets `AGENT_APP_CLIENT_ID` / `AGENT_APP_PRIVATE_KEY`
  (아래 "에이전트 자격증명" 참고)
- Secrets: `CLAUDE_CODE_OAUTH_TOKEN`, `DOTENV_PRIVATE_KEY`(dotenvx 쓸 때),
  `VERCEL_AUTOMATION_BYPASS_SECRET`(프리뷰 스모크 쓸 때)

> **`secrets: inherit`을 반드시 넘긴다.** 재사용 워크플로우는 호출부의 시크릿을 자동으로
> 물려받지 않는다. 빼먹으면 조용히 인증이 없는 채로 돌다 실패한다.

## 새 프로젝트에 붙이기

붙이는 일은 **5층**인데, 이 저장소를 부르는 건 그중 1층뿐이다.

| 층 | 무엇 | 어떻게 |
|---|---|---|
| 1. 로직 | 여기 재사용 워크플로우 8개 | `uses:`로 부르면 끝 |
| 2. 호출부 | 소비 프로젝트 `.github/workflows/` | **복사 + 조정** (트리거·권한·`risk-paths`는 프로젝트마다 다르다) |
| 3. 에이전트 | `.claude/settings.json` · `hooks/**` · `skills/steward` | **복사**. `vitest.config`의 include에 `.claude/hooks/*.test.ts`를 넣는 것을 잊지 말 것 — 빠뜨리면 훅 회귀 테스트가 **조용히 안 돈다** |
| 4. 리포 설정 | 라벨 · auto-merge · 브랜치 보호 | **복사 불가** → `bootstrap-repo.sh` |
| 5. 자격증명 | App 시크릿 · Claude 토큰 | **복사 불가** → `sync-secrets.sh` |

```bash
scripts/bootstrap-repo.sh <owner/repo> --dry-run
```

4층을 한 번에 건다(멱등, 여러 번 돌려도 된다). 라벨 5개, auto-merge 켜기, 통합 브랜치 생성,
브랜치 보호(PR 필수 · 승인 0 · force push/삭제 차단). **스크립트가 못 하는 것**(GitHub App 설치,
Vercel 설정)은 끝에 목록으로 출력한다.

5층(자격증명)은 `scripts/sync-secrets.sh`가 맡는다 — 아래 "에이전트 자격증명" 참고.

이 층이 사람이 가장 잘 빠뜨리는 곳이고, **빠뜨리면 전부 조용히 안 돈다** — 라벨이 없으면
에이전트가 안 깨어나고, auto-merge가 꺼져 있으면 `gh pr merge --auto`가 거부되며, 브랜치 보호가
없으면 게이트가 아예 없는 것이다(2026-09-10 감사에서 **이 저장소의 `main`이 무보호**인 걸
발견했다 — 소비 프로젝트가 전부 `@main`을 핀하고 있었는데도).

스크립트가 강제하는 것 하나: **`delete_branch_on_merge`는 반드시 꺼둔다.** 그 설정은 머지된 PR의
head 브랜치를 무조건 지워서, `develop`→`main` 릴리스 PR을 머지하는 순간 **`develop` 자체가
삭제된다**(2026-09-05 kitchen-tempo에서 실제로 겪고 복구함). 브랜치 정리는 `after-merge.yml`이
base와 이름을 보고 안전하게 한다.

> **템플릿 저장소로 굳히는 건 아직이다.** 표본이 kitchen-tempo 하나뿐이라, 무엇이 진짜 공통이고
> 무엇이 그 프로젝트 전용(Vercel·Neon·Prisma·Capacitor, 스킬 4개 중 3개)인지 아직 못 가린다.
> 두 번째 프로젝트를 실제로 붙여보고 그 경계를 근거로 굳힌다.

## 에이전트 자격증명 — GitHub App

워크플로우들은 `actions/create-github-app-token@v3`로 **App 설치 토큰**을 job마다 발급해
쓴다. 예전엔 사람 계정의 fine-grained PAT(`AGENT_WORKFLOW_TOKEN`)였다.

**왜 `secrets.GITHUB_TOKEN`을 못 쓰나**: 그 토큰으로 만든 이벤트는 다른 워크플로우를
트리거하지 않는다(GitHub 플랫폼 제약). 라벨 하나가 다음 워크플로우를 깨워야 도는 루프라
이게 치명적이다. **App 설치 토큰에는 그 제약이 없다** — PAT를 쓰던 이유가 그거였고 App도
같은 성질을 갖는다.

**왜 PAT에서 옮겼나**: fine-grained PAT는 최대 1년으로 만료가 강제되고, 저장소를 추가할
때마다 토큰의 Repository access 목록을 갱신해야 한다. App은 private key라 만료가 없고,
설치를 *All repositories*로 두면 새 저장소가 자동으로 포함된다.

### App 설정

| 항목 | 값 |
|---|---|
| 이름 | `superokok-agent-ops` (봇 actor가 `superokok-agent-ops[bot]`이 된다) |
| 식별자 | **Client ID**(`Iv23…`). App ID가 아니다 — 아래 주의 참고 |
| Repository permissions | Contents: **Read and write** |
| | Pull requests: **Read and write** |
| | Issues: **Read and write** |
| | **Workflows: Read and write** |
| 설치 범위 | All repositories |

**Workflows 권한이 핵심이다.** 없으면 `.github/workflows/*`를 건드리는 커밋이 거부된다 —
Claude GitHub App 설치 토큰을 못 쓰고 PAT로 우회했던 원래 이유가 정확히 이것이다.

> **App 이름을 다르게 지으면** `claude-agent`·`claude-fix`·`claude-review`의
> `allowed_bots: "claude,superokok-agent-ops"`에서 뒤쪽 슬러그를 같이 바꿔야 한다. 안 바꾸면 그 App이
> 트리거한 실행이 `Workflow initiated by non-human actor`로 거부된다 — 봇이 붙인 `agent`
> 라벨로 깨어나는 경로가 조용히 죽는다.

> **App ID가 아니라 Client ID를 쓴다.** App 설정 페이지에는 숫자인 App ID와 `Iv23…` 형태의
> Client ID가 같이 보이고, 설치 화면 URL(`/settings/installations/<숫자>`)에도 숫자가 있다.
> **App ID와 Installation ID가 둘 다 숫자라 구별이 안 된다** — 후자를 넣으면 JWT의 `iss`가
> 앱을 가리키지 않아 `A JSON web token could not be decoded`로 죽는다(2026-09-11 실제로 겪었다).
> 에러 메시지가 키 문제처럼 읽혀서 엉뚱한 곳을 보게 된다.
> `client-id`는 접두가 고정이라 그 착각이 성립하지 않고, v3의 권장 방식이기도 하다.

### 소비 저장소에 자격증명 뿌리기 — `scripts/sync-secrets.sh`

개인 계정에는 조직 secret이 없어서 **저장소마다** 등록해야 한다. 저장소당 셋이다:
`AGENT_APP_CLIENT_ID`, `AGENT_APP_PRIVATE_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`.

> App 전환이 없앤 건 *저장소 목록 갱신*과 *GitHub 토큰 만료*지 등록 자체가 아니다 —
> 오히려 secret 개수는 2개에서 3개로 늘었다. 등록 자체를 없애려면 조직(Team 이상)이
> 필요한데, Free 조직은 private 저장소에 브랜치 보호가 없어 머지 게이트가 통째로
> 사라진다. 그래서 구조를 바꾸는 대신 스크립트로 자동화한다.

```bash
# 현황 점검 (읽기 전용, 값 불필요). 빠진 게 있으면 non-zero로 끝난다.
scripts/sync-secrets.sh --check

# 등록/교체 — 값을 하나씩 물어본다 (토큰은 화면에 안 찍히고, 쓰기 전에 한 번 더 확인한다)
scripts/sync-secrets.sh

# 새 저장소 하나만
scripts/sync-secrets.sh superokok/new-repo
```

**빈 입력은 "그 secret은 건드리지 않음"이다** — 하나만 교체할 때 나머지는 Enter로 넘긴다.
무인 실행이 필요하면 `AGENT_APP_CLIENT_ID` · `AGENT_APP_PEM`(파일 경로) · `CLAUDE_CODE_OAUTH_TOKEN`을
환경변수로 미리 주면 묻지 않는다.


**`--check`가 핵심이다.** 손으로 뿌리면 토큰 교체 때 일부만 갱신되고 그 저장소의 루프만
조용히 멈춘다 — 침묵은 정상과 구별되지 않는다. 교체 뒤 `--check` 한 번이면 끝난다.

**대상 저장소 목록은 이 저장소에 커밋하지 않는다.** 여기는 public이고, 목록은 곧 "이 계정이
어떤 private 저장소를 갖고 있는가"다 — 코드가 공개돼도 무해한 것과 목록이 공개되면 곤란한
것은 종류가 달라서 저장 위치를 나눈다. 스크립트가 찾는 순서는:

1. 인자로 준 저장소들
2. `$AGENT_REPOS` — 공백/쉼표 구분 (CI·일회성 실행용)
3. `scripts/repos.local` — gitignore됨. 평소 쓰는 곳 (`scripts/repos.local.example` 참고)
4. `~/.config/gh-workflows/repos`

**못 찾으면 조용히 넘어가지 않고 exit 2로 실패한다.** 목록이 비면 `--check`가 아무것도
점검하지 않고 초록으로 끝나는데, 그건 "다 괜찮다"와 구별되지 않는다 — 이 스크립트가 있는
이유가 바로 그 침묵을 없애는 것이다.

**자동으로 돌지 않는다 — 사람이 실행한다.** 개인 계정에는 "저장소 생성" 이벤트를 다른
저장소에서 받을 방법이 없어서(조직 웹훅이 필요하다), 자동화해도 결국 누군가 트리거해야 한다.
새 저장소가 생기면 위 명령 한 번 + `repos.local`에 한 줄 추가다. 후자를 빠뜨리면
`--check`가 그 저장소를 안 본다.

**GitHub secret은 되읽을 수 없다.** 그래서 어떤 도구를 만들든 값은 사람이나 외부 저장소
(Bitwarden 등)에서 와야 한다 — 마스터 사본을 한 곳에 두는 이유가 그거다.

**`CLAUDE_CODE_OAUTH_TOKEN`에는 여전히 만료가 있다** — Anthropic 쪽 자격증명이라 App과
무관하다. GitHub 쪽 교체가 사라졌을 뿐이지 교체가 통째로 없어진 건 아니다.

### 알림이 하나 바뀐다

`release-pr.yml`이 여는 릴리스 PR의 작성자가 사람에서 봇이 된다. 예전엔 "자기 자신의 행동"
이라 알림이 안 갔는데 이제 **새 릴리스 PR이 열릴 때 한 번** 간다(갱신은 여전히 무음이다 —
GitHub은 본문 수정·커밋 추가에 알림을 보내지 않는다). 빈도는 릴리스 주기당 1회다.

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

**툴체인 설치도 같은 규칙이다** — `node-version`/`java-version`이 빈 문자열이면 그 설치를
건너뛴다. 스택은 프로젝트가 정하고, 이 저장소는 *틀*만 갖는다:

```yaml
# 폴리글랏 (Next.js 웹 + Gradle 백엔드) — job 하나, 필수 체크 하나로 끝난다
with:
  java-version: "21"
  prepare: ""                                  # Prisma 없음
  schema-validate: ""
  test: "cd backend && ./gradlew test"
```

```yaml
with:
  node-version: ""        # package.json이 없는 JVM 전용 프로젝트
  install: ""
```

**스택별로 워크플로우를 쪼개지 않은 이유**: job이 늘면 그만큼 분이 올림 과금되고
(`lint`를 별도 job에서 step으로 내린 것과 같은 이유), 필수 체크 이름도 하나 더 늘어
브랜치 보호 설정이 프로젝트마다 갈라진다. 스택이 하나 늘 때 추가되는 건 setup 스텝
하나뿐이고, 기본값이 비어 있어 다른 프로젝트에는 무해하다.

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
| `after-merge.yml` | `after-merge.yml@main` (릴리스 PR도 여기서 — 입력 `release-target`: 운영 브랜치(보통 `main`), `pre-merge-note`: 프로젝트별 안내 마크다운) | `pull_request: {types: [closed]}` |
| `claude-review.yml` | `claude-review.yml@main` | `pull_request: {types: [opened, synchronize, ready_for_review, reopened]}` — `notify-handle`을 쓰면 `workflow_run: {workflows: ["CI"], types: [completed]}`도 같은 `on:`에 추가한다(`notify-ready` job의 폴백 트리거, 아래 "알아둘 것" 참고) |
| `claude-agent.yml` | `claude-agent.yml@main` | `issues: {types: [labeled]}` |
| `claude-fix.yml` | `claude-fix.yml@main` | `workflow_run: {workflows: ["CI", "Preview Smoke"], types: [completed]}` + `status:` |
| `preview-smoke.yml` | `preview-smoke.yml@main` | `pull_request: {types: [opened, synchronize, reopened, ready_for_review]}` |
| `release-pr.yml` | `release-pr.yml@main` — **수동 재생성 창구로만** 남긴다 (평소 경로는 `after-merge.yml`) | `workflow_dispatch:` **only** — `push:`를 걸면 같은 사건에 잡이 둘이 된다 |

> **릴리스 PR은 `after-merge.yml`이 같은 잡의 스텝으로 만든다.** 예전엔 `push: <통합 브랜치>`로
> 도는 별도 워크플로우였는데, 그 push는 **거의 항상 `after-merge`를 깨우는 PR 머지와 같은
> 사건**이다. 같은 사건에 잡이 둘이면 Actions 분이 잡 단위로 올림 과금돼 10초짜리 일이 2분으로
> 청구된다(실측: 11시간 표본에서 Release PR 11 run이 실제 2분 작업에 11분 청구).
>
> 커버리지는 오히려 늘었다 — **릴리스 PR이 머지되면 통합 브랜치는 안 바뀌어서** 예전
> `push:` 트리거는 그때 안 돌았는데, `after-merge`는 그 순간에도 깨어난다.
>
> 마이그레이션은 호출부 두 줄이다: `after-merge.yml`에 `release-target`·`pre-merge-note`를
> 넘기고, `release-pr.yml`에서 `push:` 트리거를 뗀다.

`claude.yml`(`@claude` 멘션 응답)은 `/install-github-app`이 프로젝트에 직접 만들어 주므로
여기 없다. 배포(`deploy.yml`)·모바일 빌드도 프로젝트 고유라 각자 소유한다.

> **`claude-agent`·`claude-fix`는 스택 커맨드를 입력으로 받는다 — Node + Prisma가 아니면
> 반드시 넘긴다.** 기본값(`install: npm ci`, `prepare: npx prisma generate`,
> `verify: npm run check`, `changelog-file: docs/BUSINESS_LOGIC.md`,
> `plan-only-paths: prisma/`)은 원본인 kitchen-tempo 기준이다. `with:`를 통째로 생략하면
> **그 기본값이 조용히 상속되고, 실패는 에이전트가 아니라 그 앞 준비 단계에서 난다** —
> 액션이 시작조차 못 하므로 이슈는 라벨만 붙은 채 방치되고 아무 알림도 없다.
> devDepth(Spring Boot + Next.js + Expo)가 2026-09-12에 정확히 이걸로 멈췄다:
> prisma가 의존성에 없으니 `npx`가 최신 rc를 받아왔고 거기엔 `generate`가 없어 exit 2.
> 다른 커맨드 문자열 입력과 같은 규칙으로, **빈 문자열이면 그 단계를 건너뛴다.**
>
> **JVM 스택은 `java-version`(기본값 `""`)을 넘긴다** — `check.yml`과 같은 패턴이다.
> 빈 문자열이면 `setup-java`를 건너뛰므로 기존 호출부는 그대로다. 다만 `setup-node`는
> (위 문단대로) `node-version`이 아니라 `install`에 물려 있다 — install → prepare → verify가
> 순차 파이프라인이라 Node 셋업만 따로 끄면 어중간한 상태가 남기 때문이다. `install: ""`로
> Node 파이프라인 전체를 끄고 `java-version`만 넘기면 JVM 전용 저장소도 검증이 돈다.

## 알아둘 것

- **`claude-agent`는 저장소당 하나만 돈다**(concurrency 그룹이 저장소 단위). 이슈별로 묶으면
  서로 다른 이슈의 에이전트가 병렬로 돌고 둘 다 "열린 PR 없음"을 봐서 WIP 제한이 뚫린다 —
  check-then-act 경합이다(2026-09-09 실측: 45초 간격으로 PR이 둘 열렸다). 대기 슬롯은
  하나뿐이라 세 번째가 오면 두 번째가 취소되는데, 그 이슈는 `agent` 라벨만 남고 멈춘다 —
  `after-merge` 잡의 큐 구동 스텝(`drain-queue`, PR #24부터 별도 잡이 아니라 스텝이다)이
  그런 것도 라벨을 뗐다 붙여 되살린다.
- **WIP 제한 1 — 동시에 열린 작업 PR은 하나뿐이다.** 둘 이상이면 충돌이 **구조적으로**
  발생한다(겹치는 코드가 없어도 난다 — 2026-09-09 PR #190·#191이 서로 무관한데 변경 기록
  파일 끝에서 충돌했다). `claude-agent`는 열린 PR이 있으면 착수하지 않고 이슈를
  `agent-queued`로 대기시키고, `after-merge` 잡의 큐 구동 스텝(`drain-queue`)이 판이 비면
  가장 오래 기다린 것 하나를 다시 `agent`로 돌린다 — **사람이 스케줄러가 되지 않는다.**
  릴리스 PR(base=main)은 항상 열려 있으므로 세지 않는다. 이 방식은 `strict`(브랜치 최신화
  요구)나 merge queue를
  불필요하게 만든다 — merge queue는 private 저장소에서 Enterprise Cloud + 조직 소유가
  필요해 어차피 못 쓴다.
  - **큐를 깨우는 트리거는 PR close 하나만이 아니다(#49).** `drain-queue`는 `pull_request:
    closed`에만 걸려 있어서, **판이 이미 비어 있는 상태**에서 이슈가 `agent-queued`로
    생기면(닫힐 PR이 없으니) 아무도 깨우지 않았다. 그래서 `claude-agent.yml`에
    `wake-if-idle` job을 추가했다 — `agent-queued` 라벨이 붙는 이벤트에서도 같은 판정을
    한 번 돌려서, 판이 비어 있으면 가장 오래 기다린 이슈를 그 자리에서 바로 승격한다.
    라벨 스왑이 자기 자신을 다시 깨우지는 않는다(`agent`로 승격하는 이벤트의
    `label.name`은 `agent`지 `agent-queued`가 아니라서 이 job의 조건에 다시 안 걸린다).

- **불린 워크플로우의 job 단위 `permissions`는 호출부가 준 권한을 덮는다 — 낮추기만 가능하다.**
  `merged-notice` job이 `pull-requests: write`만 선언해서 `contents`가 none이 됐고, compare API가
  403을 내며 그 **에러 JSON이 알림 본문에 값으로 들어갔다**(도입 이래 100%, 감사 L51).
  #176/#181이 배운 "호출부가 권한을 명시해야 한다"의 **반대 방향** 사례다.
- **실패를 `2>/dev/null`로 삼키지 않는다.** 위 사고가 조용했던 이유가 그거다 — stderr만 버려서
  잡은 초록으로 끝나고 `gh run list` 브리핑으로도 안 잡혔다. 값으로 쓸 거면 **형식 검증**을
  함께 건다(`case "$v" in ''|*[!0-9]*) v="" ;; esac`).
- **뒷정리 잡에 `merged == true`를 잡 단위로 걸지 않는다.** 큐 구동기(`drain-queue`)는 머지 없이
  닫힌 PR 뒤에도 돌아야 한다 — 안 그러면 PR을 취소했을 때 `agent-queued` 이슈가 아무도 깨우지
  않는 채 남고, **멈춘 상태가 정상과 구별되지 않는다**(감사 L08). 머지 전용 스텝만 각자 판정한다.
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
- **`claude-review.yml`은 App 설치 토큰으로 라벨을 붙인다.** `GITHUB_TOKEN`으로 만든
  이벤트는 다른 워크플로우를 트리거하지 않아(GitHub 플랫폼 제약), 그 토큰으로 `agent`를
  붙이면 `claude-agent.yml`이 깨어나지 않아 이슈가 그대로 방치된다. App 토큰엔 그 제약이
  없다. 그리고 이때 actor가 `superokok-agent-ops[bot]`이 되므로 `allowed_bots`에 그 슬러그가
  들어 있어야 한다 — 안 그러면 `Workflow initiated by non-human actor`로 거부된다.

- **담당자 지정(`notify-handle`)은 체크가 전부 초록이 된 뒤에만 한다(#55).**
  `enable-auto-merge.yml`이 위험 경로를 감지한 순간 담당자를 붙이면, 그때는 리뷰 같은 다른
  체크가 아직 도는 중이라 알림이 "머지 버튼이 아직 비활성"인 시점에 도착한다(실측:
  위험 경로 감지 직후 담당자 지정 → `review`가 2분 29초를 더 돎). 그래서 담당자 지정은
  `claude-review.yml`(리뷰가 보통 가장 긴 체크라 그 마지막 스텝에서 `mergeStateStatus ==
  CLEAN`을 판정)과 `notify-ready` job(CI가 리뷰보다 늦게 끝나는 PR을 위한 `workflow_run`
  폴백)으로 옮겼다. `enable-auto-merge.yml`의 같은 이름 입력은 이제 담당자를 붙이지 않고,
  **이미 붙어 있으면 뗀다**(새 커밋으로 다시 위험해지면 "지금 눌러도 된다"가 거짓이
  되므로). 두 호출부에 같은 `notify-handle` 값을 넘겨야 한다 — `do-not-merge` 라벨은
  "상태"(사람이 머지한다), 담당자 지정은 "실행 가능 시점"(지금 눌러도 된다)이라는 서로
  다른 의미이기 때문이다.
- **`workflow_run` / `status` / `deployment_status` 트리거는 default 브랜치(`main`)에 있는
  호출부 파일이 동작한다.** 즉 그 파일들을 고치면 `develop`→`main` 릴리스 후에 효력이 생긴다.
- **check-run 이름이 `잡이름 / 잡이름`이 된다.** 재사용 워크플로우를 부르면 GitHub이
  `<호출 잡> / <불린 잡>`으로 이름을 만든다. 브랜치 보호에서 필수 체크를 지정할 때
  `check`가 아니라 **`check / check`**로 잡아야 한다.
- **이 저장소가 public이면 접근 허용 설정이 필요 없다** — public 재사용 워크플로우는 누구나
  `uses:`로 부를 수 있다. private으로 두면 계정당 1회 열어줘야 한다: 이 저장소
  Settings → Actions → General → Access → *Accessible from repositories owned by the user*.
- **Dependabot PR도 시크릿을 못 받는다** — fork PR과 같은 이유이고, 결과는 훨씬 나쁘다.
  GitHub은 Dependabot secrets를 별도 저장소에 두므로 `create-github-app-token`부터 실패한다.
  `review / review`가 **필수 체크**면 그 PR은 BLOCKED로 굳고, `base=<통합 브랜치>` 열린 PR이
  사라지지 않아 **WIP 제한 1이 영구히 걸려 `claude-agent`가 통째로 멈춘다.**
  2026-09-13 devDepth에서 실제로 그랬다(Dependabot PR 4건이 동시에 막혀 `agent-queued`
  이슈가 깨어날 수 없게 됐다). 그래서 `claude-review`·`enable-auto-merge`·`claude-fix`는
  `github.actor != 'dependabot[bot]'`로 **깨어나지 않는다** — job 수준 `if:`라 check-run은
  `skipped`로 생성되고 필수 체크는 그걸 success로 본다.
  대안은 Dependabot secrets에 같은 값을 복제하는 것인데, **에이전트 App 토큰(write)을
  Dependabot 컨텍스트까지 넓히는** 일이라 택하지 않았다. 의존성 PR은 거의 전부 공급망
  위험 경로라 어차피 사람이 diff를 보고 머지한다 — 잃는 건 AI 리뷰 한 겹이고, 사람 게이트는
  그대로다.
  이 조치는 "Dependabot PR이 영구히 머지 불가로 굳는 것"만 막았고, "Dependabot PR이
  **열려 있는 동안 WIP 큐가 멈추는 것**"은 남아 있었다(#47) — `claude-agent.yml` 스텝 0과
  `after-merge.yml`의 `drain-queue`는 여전히 열린 PR을 author 구분 없이 셌다. 지금은 두
  곳 다 Dependabot PR을 WIP 카운트에서 뺀다. 다만 완전히 무시하지는 않는다: `claude-agent`
  스텝 0은 그 PR들이 건드린 파일에 `package-lock.json` 같은 의존성 manifest/락파일이 있고
  이번 이슈도 같은 파일을 건드릴 것 같으면 그때는 그대로 대기한다(2026-09-09 PR #190·#191
  충돌과 같은 부류를 다시 열지 않기 위함). `drain-queue`는 그 판단을 하지 않고 일단 깨우기만
  한다 — 무엇을 건드릴지는 깨어난 `claude-agent`만 알므로, 겹치면 그 자리에서 다시 큐로
  돌려보낸다.
- **public일 때 fork PR은 시크릿을 못 받는다**(GitHub 플랫폼 규칙). 그래서 `self-review`·
  `self-after-merge`는 `head.repo.full_name == github.repository`로 막아 뒀다 — 안 막으면
  외부 PR마다 App 토큰 발급부터 실패해 **리뷰는 한 줄도 못 하면서 빨간불과 분만** 나간다.
  `self-lint`는 시크릿이 필요 없어 외부 PR에서도 그대로 돈다.
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
| `self-after-merge.yml` | PR 머지 후 이슈 닫기·브랜치 정리 |

> ⚠️ **`self-*`는 이 저장소 자신의 시크릿을 쓴다.** 재사용 워크플로우를 "라이브러리"로만
> 쓸 땐 여기 시크릿이 필요 없었지만, 자기 루프를 돌리는 순간 필요해진다 —
> `secrets: inherit`은 **호출부가 있는 저장소**의 시크릿을 물려주기 때문이다.
> 없으면 `Environment variable validation failed`로 죽는다(2026-09-07 실제로 겪음).
>
> ```bash
> gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo superokok/gh-workflows
> gh secret set AGENT_APP_CLIENT_ID            --repo superokok/gh-workflows
> gh secret set AGENT_APP_PRIVATE_KEY   --repo superokok/gh-workflows < app-private-key.pem
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
