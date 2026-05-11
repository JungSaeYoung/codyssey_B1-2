# Codyssey B1-2 — 시스템 장애 분석 & 기술 리포트 작성

> 실서버에서 발생하는 3대 장애(**OOM / CPU Spike / Deadlock**)를 관제 로그·실행 로그·시스템 도구의 객관적 증거를 근거로 추론하고, GitHub Issue 형태의 기술 리포트로 정리한다.
> 실행 환경: **macOS + OrbStack Ubuntu 22.04 머신** (B1-1과 동일)

---

## 1. 미션 개요

운영 환경에서 프로세스가 갑자기 죽거나(OOM), CPU를 100% 잡거나, 응답이 멈추는(Deadlock) 사고가 났을 때 — 로그 없이 재부팅으로 묻으면 같은 장애가 반복된다.
이 미션은 제공된 바이너리 `agent-leak-app`을 운영 환경에서 실행하면서:

1. 장애가 어떻게 **관측**되는지 (현상)
2. 어떤 **증거**로 입증할 수 있는지 (로그/명령어/관제 데이터)
3. **근본 원인**이 무엇인지 (운영체제 원리 + 앱 동작)
4. **임시 조치**(환경변수 조정)와 그 효과는 어떤지 (Before & After)

— 의 4단계로 분해해 GitHub Issue 형태로 정리한다.

학습 목표 (수료 후 스스로 설명할 수 있어야 함):

- 메모리 누수가 시스템 전체에 미치는 영향
- 특정 프로세스의 CPU 과점유가 시스템 지연을 유발하는 원리
- 자원 경쟁으로 발생하는 교착상태(Deadlock)의 개념과 진단 방법
- 로그/관제 데이터를 근거로 GitHub Issue 형태로 동료와 소통하는 방법

---

## 2. 최종 산출물

| # | 산출물 | 비고 |
| - | ------ | ---- |
| 1 | [reports/01_oom_report.md](reports/01_oom_report.md) | OOM Crash 분석 리포트 (필수) |
| 2 | [reports/02_cpu_report.md](reports/02_cpu_report.md) | CPU 과점유 분석 리포트 (필수) |
| 3 | [reports/03_deadlock_report.md](reports/03_deadlock_report.md) | Deadlock 진단 리포트 (필수) |
| 4 | [reports/04_scheduling_analysis.md](reports/04_scheduling_analysis.md) | 스케줄링 알고리즘 추론 (보너스) |
| 5 | [evidence/](evidence/) | 각 리포트가 인용한 monitor.log / app.log / 명령어 출력 원본 |
| 6 | [실험_절차서.md](실험_절차서.md) | 3개 장애를 재현·검증한 순서와 환경변수 조합 |

---

## 3. 사전 준비 (agent-leak-app 실행 조건)

운영 측에서 제공한 `agent-leak-app`은 부트 시퀀스에서 다음 항목을 모두 검사한다. 하나라도 실패하면 자동 부팅 실패 처리된다.

| 항목 | 조건 |
| ---- | ---- |
| 실행 계정 | root **금지**, 일반 사용자 (예: `agent-admin`) |
| `AGENT_HOME` | 필수 |
| `AGENT_PORT` | `15034` 고정 |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` (디렉토리 존재) |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys` (경로 존재) |
| `AGENT_LOG_DIR` | 디렉토리 존재 + 쓰기 권한 |
| `MEMORY_LIMIT` | 정수, **50~512** (MB) |
| `CPU_MAX_OCCUPY` | 정수, **10~100** (%) |
| `MULTI_THREAD_ENABLE` | `true/false`, `1/0`, `yes/no` 허용 |
| `secret.key` | `$AGENT_HOME/api_keys/secret.key`, 내용 = `agent_api_key_test` |
| 네트워크 | `0.0.0.0:15034` 바인딩 가능 |

`.bash_profile` 예시:

```bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
export MEMORY_LIMIT=256
export CPU_MAX_OCCUPY=80
export MULTI_THREAD_ENABLE=true
```

---

## 4. 분석 흐름 (모든 장애 공통)

```
[1] 정상 가동 (Baseline 수집)
        │  monitor.sh 가 1분 단위로 CPU/MEM/DISK 로그
        ▼
[2] 장애 관측 (Symptom)
        │  - OOM: 메모리 선형 증가 → 종료
        │  - CPU: CPU% 급상승 → SIGTERM
        │  - Deadlock: PID 살아있지만 로그/리소스 정지
        ▼
[3] 증거 수집 (Evidence)
        │  monitor.log + agent-leak-app 실행 로그 + ps/top
        ▼
[4] 원인 추론 (Root Cause)
        │  OS 동작 원리 + 앱 정책 매핑
        ▼
[5] 임시 조치 & 재검증 (Workaround)
        │  환경변수 조정 → 재실행 → Before/After 비교
        ▼
[6] GitHub Issue 작성
```

---

## 5. 제약 사항

- 사용 가능 도구: `monitor.sh`, `ps`, `top`, `htop`, `pstree`, `kill` 등 리눅스 표준 명령어
- **바이너리 디컴파일/리버스 엔지니어링 금지** — 외부 관측 정보(로그/관제)만으로 추론
- 일반 계정으로만 실행 (root 금지)

---

## 6. 빠른 실행 가이드

```bash
# 1) B1-1 환경 위에서 시작 (agent-admin 계정, AGENT_HOME 셋업 완료 상태 가정)
ssh -p 20022 agent-admin@<host>

# 2) 환경변수 export 후 앱 실행
source ~/.bash_profile
./agent-leak-app &

# 3) 다른 터미널에서 관제
$AGENT_HOME/bin/monitor.sh           # 1회 수동 실행
crontab -l                            # 매분 cron 등록 확인
tail -f /var/log/agent-app/monitor.log

# 4) 앱 자체 실행 로그 (장애 메시지)
tail -f $AGENT_LOG_DIR/agent-leak-app.log
```

---

## 7. 필수 증거 자료 체크리스트

- [ ] **OOM**: monitor.log의 MEM% 선형 증가 구간 + `Memory limit exceeded` / `SELF-TERMINATED` 로그 + `MEMORY_LIMIT` 변경 전/후 생존시간 비교
- [ ] **CPU**: monitor.log의 CPU% 급상승 구간 + `WATCHDOG … SIGTERM` 로그 + `CPU_MAX_OCCUPY` 변경 전/후 비교
- [ ] **Deadlock**: `ps -ef | grep agent` PID 존재 + `top -H` 스레드 CPU 0% + 마지막 `WAITING/BLOCKED` 로그 + `MULTI_THREAD_ENABLE=false`로 회피 확인
