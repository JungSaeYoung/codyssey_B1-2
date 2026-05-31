# Codyssey B1-2 — 시스템 장애 분석 & 기술 리포트 작성

> 실서버에서 발생하는 3대 장애(**OOM / CPU Spike / Deadlock**)를 관제 로그·실행 로그·시스템 도구의 객관적 증거를 근거로 추론하고, GitHub Issue 형태의 기술 리포트로 정리한다.
>
> 실행 환경: **macOS + OrbStack Ubuntu 24.04 머신** (B1-1과 동일 인프라 재사용)
>
> 본 저장소는 B1-1 에서 구축한 SSH/방화벽/계정/디렉토리/cron 인프라 위에 **B1-2 전용으로 `agent-leak-app` 을 얹어** 장애를 재현하는 구조다.

---

## 0. 미션이 진짜로 묻는 것

쉘 명령어를 외워서 푸는 게 아니라, **외부에서 보이는 데이터(로그·관제·시스템 도구) 만으로 프로세스 안과 OS 안에서 무슨 일이 벌어졌는지 역추론**할 수 있는지를 묻는다.

```
[관측] monitor.log 의 MEM% 가 96% 까지 올라갔고 SELF-TERMINATED 가 찍혔다
   ↓
[추론] 어떤 자료구조 위에서, 어떤 정책이, 누구를, 어떤 시그널로 죽였는가?
   ↓
[증명] /proc, ps, top 으로 그 추론을 뒷받침할 수 있는가?
   ↓
[소통] 위 3단계를 동료 개발자가 30초만에 따라올 수 있는 Issue 로 정리했는가?
```

따라서 미션의 산출물은 **리포트(.md)** 다. 하지만 진짜 측정 대상은 학습자가 **운영체제 동작 원리** 를 자기 언어로 설명할 수 있게 됐는가이다. 그래서 본 저장소는 리포트와 함께 **이론 지식 문서**를 핵심 산출물로 포함한다.

---

## 1. 학습 목표

수료 후 학습자는 다음을 자기 말로 설명할 수 있어야 한다:

- 가상 메모리·Heap·RSS·OOM Killer·앱 자체 MemoryGuard 의 관계
- 특정 프로세스의 CPU 과점유가 시스템 지연을 유발하는 원리, CFS 스케줄러의 기본 직관
- 데드락 4대 조건(상호배제·점유대기·비선점·순환대기), 외부 도구로 데드락을 증명하는 6가지 증거
- 로그·관제 데이터를 근거로 GitHub Issue 형태로 동료와 소통하는 방법

이론적 배경은 [docs/md/이론_지식.md](docs/md/이론_지식.md) 에 깊이 정리돼 있다 — 리포트를 쓰기 전에 한 번 통독할 것.

---

## 2. 디렉토리 구조

```
codyssey_B1-2/
├── README.md                       ← 이 파일 (미션 개요 + 수행 방법)
├── 실험_절차서.md                  ← 3개 장애 재현·검증 절차
│
├── docs/
│   ├── md/
│   │   └── 이론_지식.md            ← 컴퓨터 구조 · 메모리 · CPU · 동시성 (필독)
│   └── html/
│       └── index.html              ← tools/build_docs.py 가 생성하는 정적 사이트
│
├── reports/                        ← GitHub Issue 형식 분석 리포트 (제출 산출물)
│   ├── 01_oom_report.md
│   ├── 02_cpu_report.md
│   ├── 03_deadlock_report.md
│   └── 04_scheduling_analysis.md   ← 보너스 (스케줄링 추론)
│
├── evidence/                       ← 리포트가 인용한 로그·명령어 출력 원본
│   ├── oom_monitor.log / oom_app.log / oom_ps_top.txt
│   ├── cpu_monitor.log / cpu_app.log / cpu_top_ps.txt
│   ├── deadlock_monitor.log / deadlock_app.log / deadlock_ps_top.txt
│   └── scheduling_workers.log / scheduling_top_h.txt
│
├── bin/                            ← 운영 측 제공 agent-leak-app 을 두는 자리 (비어 있음)
│   └── (agent-leak-app)            ← 학습자가 직접 배치 — 이 저장소에는 포함 안 됨
│
├── src/                            ← B1-1 에서 가져온 인프라 자동화 스크립트
│   ├── monitor.sh                  ← 시스템 상태 수집·로깅 (cron 매분)
│   ├── report.sh                   ← monitor.log 통계 출력
│   ├── archive_logs.sh             ← 시간 기반 로그 보존 정책
│   ├── 00_run_all.sh               ← 01~07 setup 단계를 한 번에 실행
│   ├── 01_ssh_hardening.sh         ← SSH 포트 20022 + Root 차단
│   ├── 02_firewall_allowlist.sh    ← UFW 화이트리스트 (20022/15034)
│   ├── 03_users_and_groups.sh      ← 계정 3종 + 그룹 2종
│   ├── 04_directories_and_acl.sh   ← 디렉토리 + ACL
│   ├── 05_env_and_keyfile.sh       ← B1-2 사양 env 5종 + 실험용 3종 + secret.key
│   ├── 06_deploy_app_and_scripts.sh ← agent-leak-app + *.sh 배포 (B1-2 버전)
│   └── 07_cron_schedule.sh         ← cron 매분/매일 등록
│
└── tools/
    └── build_docs.py               ← .md → docs/html/index.html 빌더
```

> B1-1 과 가장 큰 차이는 두 가지다:
> 1. `src/05_env_and_keyfile.sh` 가 B1-2 사양으로 바뀌었다 (key 파일명, key 경로 의미, 실험용 ENV 3종 추가).
> 2. `src/06_deploy_app_and_scripts.sh` 의 바이너리 이름이 `agent-leak-app` 으로 바뀌었다. **이 저장소에 바이너리는 포함되어 있지 않으니** 운영 측이 제공한 파일을 `bin/agent-leak-app` 에 배치해야 한다.

---

## 3. 사전 준비 (agent-leak-app 실행 조건)

운영 측에서 제공한 `agent-leak-app` 은 부트 시퀀스에서 아래 항목을 모두 검사하고, 하나라도 실패하면 자동 부팅 실패 처리된다.

| 항목 | 조건 |
| ---- | ---- |
| 실행 계정 | root **금지**, 일반 사용자 (예: `agent-admin`) |
| `AGENT_HOME` | 필수 환경변수 |
| `AGENT_PORT` | `15034` 고정 |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` (디렉토리 존재) |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys` (경로 존재) — **B1-1 과 달리 디렉토리** |
| `AGENT_LOG_DIR` | 디렉토리 존재 + 쓰기 권한 |
| `MEMORY_LIMIT` | 정수, **50~512** (MB) |
| `CPU_MAX_OCCUPY` | 정수, **10~100** (%) |
| `MULTI_THREAD_ENABLE` | `true/false`, `1/0`, `yes/no` 허용 |
| `secret.key` 파일 | `$AGENT_HOME/api_keys/secret.key`, 내용 = `agent_api_key_test` |
| 네트워크 | `0.0.0.0:15034` 바인딩 가능 |

`.bashrc` 예시 (`src/05_env_and_keyfile.sh` 가 자동 등록):

```bash
export AGENT_HOME="/home/agent-admin/agent-app"
export AGENT_PORT="15034"
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="/var/log/agent-app"

# 베이스라인 (정상 가동) — 실험 시 실험_절차서.md 조합표대로 바꿔서 재실행
export MEMORY_LIMIT="512"
export CPU_MAX_OCCUPY="95"
export MULTI_THREAD_ENABLE="false"
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
        │  → 막히면 docs/md/이론_지식.md 재참조
        ▼
[5] 임시 조치 & 재검증 (Workaround)
        │  환경변수 조정 → 재실행 → Before/After 비교
        ▼
[6] GitHub Issue 작성 (reports/*.md)
```

---

## 5. 빠른 실행 가이드

### 5.1 환경 구축 (OrbStack)

```bash
# macOS 호스트
brew install orbstack
orb create ubuntu:24.04 codyssey-b1-2

# 운영 측 제공 agent-leak-app 을 bin/ 에 미리 두고 함께 push
cp ~/Downloads/agent-leak-app bin/agent-leak-app
orb push -m codyssey-b1-2 src/*.sh bin/agent-leak-app /tmp/

orb shell -m codyssey-b1-2

# 머신 안에서 (CRLF 정리 후 setup)
sudo apt-get install -y dos2unix
dos2unix /tmp/*.sh && chmod +x /tmp/*.sh
bash /tmp/00_run_all.sh           # 7단계 setup 한 번에
```

### 5.2 부트 시퀀스 확인

```bash
sudo -iu agent-admin
cd $AGENT_HOME
./agent-leak-app             # 모든 [OK] 가 떠야 정상
```

### 5.3 장애 실험

세 가지 장애를 순서대로 재현하는 환경변수 조합과 검증 명령은 [실험_절차서.md](실험_절차서.md) 에 정리돼 있다.

```bash
# 한 줄 요약
# OOM     : MEMORY_LIMIT=256        다른 건 정상 → 10분 후 SELF-TERMINATED
# CPU     : CPU_MAX_OCCUPY=80       다른 건 정상 → 4분 후 WATCHDOG SIGTERM
# Deadlock: MULTI_THREAD_ENABLE=true 다른 건 정상 → 2~4분 후 무응답
```

### 5.4 관제 모니터링

```bash
# 다른 터미널
tail -f /var/log/agent-app/monitor.log              # cron 매분 누적
tail -f $AGENT_LOG_DIR/agent-leak-app.log           # 앱 자체 로그
```

---

## 6. 리포트 작성 가이드

세 리포트 모두 동일한 4단 구조로 쓴다:

```markdown
[Bug] {장애 유형} - {한 줄 요약}

## 1. Description (현상 설명)
- 무엇이, 언제, 어떤 조건에서 발생했나

## 2. Evidence & Logs (증거 자료)
- monitor.log 발췌 (수치)
- 앱 로그 핵심 라인 발췌
- ps/top 출력

## 3. Root Cause Analysis (원인 분석)
- 위 증거가 OS 동작 원리로 어떻게 설명되는가
- (이론_지식.md 의 어느 부분을 끌어왔는지 자기 언어로 적기)

## 4. Workaround & Verification (조치 및 검증)
- 어떤 환경변수를 어떻게 바꿨고
- Before / After 결과가 어떻게 달라졌는가
- 근본 해결은 무엇인가 (선택)
```

> 🔑 **리포트의 합격선은 "동료가 30초 안에 따라올 수 있는가"** 다. 4단 구조의 각 섹션을 한 번에 한 가지 사실만 적되, 그 사실의 근거를 evidence/ 파일과 1:1 로 연결되게 인용한다.

---

## 7. 제약 사항

- 사용 가능 도구: `monitor.sh`, `ps`, `top`, `htop`, `pstree`, `kill`, `vmstat`, `/proc` 등 리눅스 표준 도구
- **바이너리 디컴파일/리버스 엔지니어링 금지** — 외부 관측 정보(로그/관제)만으로 추론
- 일반 계정으로만 실행 (root 금지)
- 자동화 스크립트는 **Bash 로만**

---

## 8. 필수 증거 체크리스트

| 장애 | 증거 |
| ---- | ---- |
| **OOM** | monitor.log MEM% 선형 증가 구간 + `Memory limit exceeded` / `SELF-TERMINATED` 로그 + `MEMORY_LIMIT` 변경 전/후 생존시간 비교 |
| **CPU** | monitor.log CPU% 급상승 구간 + `WATCHDOG … SIGTERM` 로그 + `CPU_MAX_OCCUPY` 변경 전/후 비교 |
| **Deadlock** | `ps -ef \| grep agent` PID 존재 + `top -H` 스레드 CPU 0% + `ps -L -o wchan` 의 `futex_wait_queue_me` + 마지막 `WAITING/BLOCKED` 로그 + `MULTI_THREAD_ENABLE=false` 회피 확인 |
| **(보너스) 스케줄링** | 워커 스레드 로그의 타임스탬프 + 진행률 패턴 → RR / FCFS / Priority / CFS 중 어느 시그니처인지 |

---

## 9. 문서 빌드 (선택)

세 개의 .md (이 파일, 실험_절차서, 이론_지식) 와 4개 리포트를 묶어 보기 좋은 정적 HTML 로 빌드:

```bash
# 의존성 (Python 3 + markdown + pygments)
pip install markdown pygments

python3 tools/build_docs.py            # docs/html/index.html 생성
# Windows: 더블클릭으로 열기 / macOS: open docs/html/index.html
```

생성된 `docs/html/index.html` 은 **단일 파일·외부 파일 없음** 으로 만들어져 어디로 옮겨도 그대로 열린다. 좌측 사이드바에서 문서 간 이동 + 우측에 현재 문서 목차가 같이 보인다.

---

## 10. 다음 단계 — 학습 체크리스트

리포트를 다 쓴 뒤, [이론_지식.md 의 §7 학습 체크리스트](docs/md/이론_지식.md) 의 질문들에 자기 언어로 답할 수 있는지 확인해보자. 답이 막히는 항목이 있다면 그 부분이 이번 미션에서 더 채워야 할 이론의 빈 곳이다.
