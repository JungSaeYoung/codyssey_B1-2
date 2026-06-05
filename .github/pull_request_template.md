<!--
  이 저장소의 PR 은 "장애 1건의 조치·검증" 단위다.
  분석 리포트(Issue)에 대응하는 워크어라운드 적용 + 실측 Before/After 증거를 담는다.
-->

## 연결 이슈

Closes #<issue번호>

## 무엇을 / 왜

- (한 줄 요약: 어떤 장애의 어떤 조치인가)

## 변경 사항

- [ ] 워크어라운드 적용 (환경변수/스크립트/문서)
- [ ] 실측 증거 추가/갱신 (`evidence/` 또는 `evidence_live/`)
- [ ] 리포트 `reports/0N_*.md` 의 Workaround & Verification 갱신

## Before / After (실측)

| 항목 | Before | After |
| ---- | ------ | ----- |
| 종료/무응답 시점 |  |  |
| 핵심 시그니처 |  |  |

증거: `evidence/...` 또는 `.verify-artifacts/...`

## 셀프 리뷰 체크리스트 (솔로)

- [ ] `verify_orbstack.sh` (또는 `--quick`) 로 실측해 증거를 만들었다
- [ ] Before/After 가 표/로그로 1:1 대응된다
- [ ] 외부 관측 정보만 사용 (바이너리 리버스 엔지니어링 없음)
- [ ] 변경이 미션 제약(Bash 전용·일반 계정)을 지킨다
- [ ] 머지 시 연결 이슈가 자동 close 되는지 `Closes #N` 확인
