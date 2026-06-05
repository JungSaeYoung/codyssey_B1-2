---
name: "🔬 분석 리포트 (Analysis)"
about: "정상 가동 데이터로 OS 동작(스케줄링 등)을 추론하는 분석 리포트 (장애 아님)"
title: "[Analysis] "
labels: ["analysis"]
assignees: []
---

> 라벨: `analysis`, `area/...`
> 담당:
> 대상: 정상 가동 중인 `agent-leak-app` (`<수집 조건>`)

## 1. 분석 목표

- 어떤 OS 동작/정책을 무슨 데이터로 추론하려는가

## 2. 수집 데이터 (Evidence)

```text
(워커 로그 타임스탬프 / top -H 스레드별 점유 등 발췌)
```

## 3. 패턴 → 추론

- 관측된 패턴(타임슬라이스/진행률/우선순위 등) → 어떤 시그니처(RR / FCFS / Priority / CFS)인가

## 4. 결론 & 한계

- 추론 결론 + 외부 관측만으로 단정할 수 없는 부분 명시

## 5. 첨부 / 참조

- evidence/ 원본 링크
