# 협업 검증 RUNBOOK — GitHub Issues & Pull Requests

> 이 과제는 3대 장애 분석을 **동료 개발자처럼 GitHub Issue 로 공유하고, 조치·검증을
> Pull Request 로 리뷰·머지**하는 흐름으로 검증한다. 이 문서는 그 절차서다.
> 리뷰는 **솔로(셀프리뷰)** 를 가정한다 — 본인이 author 이자 reviewer.

원격: `https://github.com/JungSaeYoung/codyssey_B1-2`

---

## 1. 협업 단위 매핑

```
장애 1건  ──►  Issue 1건  (분석 리포트 = Issue 본문)
   └─ 그 장애의 조치·검증  ──►  PR 1건  (Closes #N, 실측 Before/After 증거)
```

| 영역 | Issue | 리포트 | 라벨 |
| ---- | ----- | ------ | ---- |
| OOM | [#1](https://github.com/JungSaeYoung/codyssey_B1-2/issues/1) | [reports/01_oom_report.md](reports/01_oom_report.md) | `bug` `priority/high` `area/memory` |
| CPU | [#2](https://github.com/JungSaeYoung/codyssey_B1-2/issues/2) | [reports/02_cpu_report.md](reports/02_cpu_report.md) | `bug` `priority/high` `area/cpu` |
| Deadlock | [#3](https://github.com/JungSaeYoung/codyssey_B1-2/issues/3) | [reports/03_deadlock_report.md](reports/03_deadlock_report.md) | `bug` `priority/critical` `area/concurrency` |
| 스케줄링(보너스) | [#4](https://github.com/JungSaeYoung/codyssey_B1-2/issues/4) | [reports/04_scheduling_analysis.md](reports/04_scheduling_analysis.md) | `analysis` `bonus` `area/scheduling` |

스캐폴딩(완료): 커스텀 라벨 8종, [이슈 템플릿](.github/ISSUE_TEMPLATE/) 2종, [PR 템플릿](.github/pull_request_template.md).

---

## 2. 현재 상태 / 남은 단계

- [x] **스캐폴딩** — 라벨 + 이슈/PR 템플릿
- [x] **Issue 개설** — #1~#4 (리포트 본문을 Issue 로)
- [ ] **검증 PR** — 장애별로 실측 증거를 넣고 `Closes #N` 으로 이슈 닫기 (아래 §3)

> 분석/리포트는 이미 `master` 에 있다. 그래서 *앞으로의* 협업 트레일은
> "**예시 증거 → 실측 증거**" 검증을 PR 단위로 만든다.
> 현재 `evidence/*` 는 형식 예시이고, `verify_orbstack.sh` 로 돌린 실측 로그가 진짜 증거다.

---

## 3. 검증 PR 만들기 (장애 1건 = PR 1건)

### 3-1. 실측 증거 생성 (macOS + OrbStack)

```bash
cp ~/Downloads/agent-leak-app bin/agent-leak-app
./verify_orbstack.sh            # 전체 실측 (오래 걸림) — 또는 QUICK=1 ./verify_orbstack.sh
# 산출물: .verify-artifacts/evidence_live/{oom,cpu,deadlock,scheduling}_*
```

### 3-2. 브랜치 → 변경 → PR (OOM 예시, #1)

```bash
git switch -c verify/oom

# 실측 로그를 제출용 evidence/ 로 반영 (예시 덮어쓰기)
cp .verify-artifacts/evidence_live/oom_*.log  evidence/
cp .verify-artifacts/evidence_live/oom_*.txt  evidence/
#   필요 시 reports/01_oom_report.md 의 §4 Before/After 수치를 실측값으로 갱신

git add evidence/oom_* reports/01_oom_report.md
git commit -m "verify(oom): 실측 Before/After 증거 반영

Closes #1"
git push -u origin verify/oom

gh pr create --fill --base master --head verify/oom
#   (PR 템플릿이 자동으로 채워짐 — Closes #1 / Before·After 표 / 셀프 체크리스트)
```

각 장애 반복: `verify/cpu`(#2), `verify/deadlock`(#3), `verify/scheduling`(#4).

### 3-3. 솔로 셀프리뷰 → 머지

```bash
gh pr view --web                       # diff 를 GitHub 에서 눈으로 리뷰
gh pr comment <PR번호> --body "셀프리뷰: Before/After 로그 1:1 대응 확인, 외부 관측만 사용 — LGTM"
gh pr merge  <PR번호> --squash --delete-branch
#   머지되면 'Closes #N' 으로 해당 이슈가 자동 close 된다
```

> 팀 리뷰로 바꾸려면: `.github/CODEOWNERS` 추가 + 저장소 설정에서 branch protection
> ("require 1 approval before merge") 를 켜고, `gh pr review --approve` 를 리뷰어가 수행.

---

## 4. 진행 확인 / 정리

```bash
gh issue list --state all              # #1~#4 상태 (열림/닫힘)
gh pr list   --state all               # 검증 PR 목록
gh issue view 1 --web                  # 개별 이슈 확인
```

완료 기준: **#1~#3 (장애) 이 검증 PR 머지로 close + #4 (분석) 도 검증/정리되어 close**,
각 이슈가 리포트·실측 증거와 1:1 로 연결되어 있을 것.
