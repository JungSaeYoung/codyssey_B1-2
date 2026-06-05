---
name: "🐛 장애 리포트 (Bug)"
about: "agent-leak-app 장애를 외부 관측 증거(로그·관제·시스템 도구)만으로 분석한 리포트"
title: "[Bug] "
labels: ["bug"]
assignees: []
---

> 라벨: `bug`, `priority/...`, `area/...`
> 담당:
> 환경: Ubuntu 24.04 (OrbStack), agent-admin 계정, `<재현 환경변수>`

<!--
  합격선 = "동료가 30초 안에 따라올 수 있는가".
  각 섹션은 한 번에 한 가지 사실만, 그 사실의 근거를 evidence/ 파일과 1:1 로 인용한다.
  바이너리 리버스 엔지니어링 금지 — 외부 관측 정보로만 추론.
-->

## 1. Description (현상 설명)

- 무엇이 / 언제 / 어떤 조건에서 발생했나
- 재현성 (몇 회 중 몇 회, 소요 시간)

## 2. Evidence & Logs (증거 자료)

### 2-1. `monitor.sh` 관제 로그 (`/var/log/agent-app/monitor.log`)
```text
(발췌)
```
### 2-2. agent-leak-app 실행 로그
```text
(핵심 라인 발췌)
```
### 2-3. `ps` / `top` 출력
```text
(캡처)
```

## 3. Root Cause Analysis (원인 분석)

- 위 증거가 OS 동작 원리로 어떻게 설명되는가 (docs/md/이론_지식.md 인용)

## 4. Workaround & Verification (조치 및 검증)

- 어떤 환경변수를 어떻게 바꿨고, Before / After 가 어떻게 달라졌는가
- 근본 해결 제안 (선택)

## 5. 첨부 / 참조

- evidence/ 원본 링크
