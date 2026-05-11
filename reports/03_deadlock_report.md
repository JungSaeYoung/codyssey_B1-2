# [Bug] agent-leak-app 멀티스레드 모드에서 교착상태(Deadlock)로 인한 무응답

> 라벨: `bug`, `priority/critical`, `area/concurrency`
> 담당: agent-dev
> 환경: Ubuntu 22.04 (OrbStack), agent-admin 계정, `MULTI_THREAD_ENABLE=true`

---

## 1. Description (현상 설명)

`agent-leak-app`을 멀티스레드 모드(`MULTI_THREAD_ENABLE=true`)로 실행하면, 부팅 후 약 **2~4분**이 경과한 시점부터 다음 3가지 현상이 **동시에** 관측된다.

1. **프로세스는 살아 있다** — `ps -ef | grep agent` 결과 PID가 그대로 존재
2. **CPU/MEM은 변하지 않는다** — monitor.log 의 CPU%, MEM% 가 0~1%대에서 미동
3. **로그가 멈춘다** — `agent-leak-app.log` 의 마지막 라인 timestamp 가 정지

즉 **죽지도 일하지도 않는** 무응답 상태. SIGINT(Ctrl+C)에는 반응하지만 외부 TCP 요청(`curl 0.0.0.0:15034`)에는 응답하지 않는다.

- 발생 시각: 2026-05-11 18:00:00 실행 → 18:02:47 무응답 진입 → 약 30분 방치해도 동일 상태
- 재현성: 같은 설정으로 4회 시도, 4회 모두 1~4분 내 동일 시그니처 관측

---

## 2. Evidence & Logs (증거 자료)

### 2-1. PID 존재 증거

```text
$ ps -ef | grep -v grep | grep agent
agent-admin 15021  2210  0 18:00 pts/1    00:00:01 /usr/bin/python3 ./agent-leak-app

$ ps -p 15021 -o pid,stat,etime,cmd
   PID STAT     ELAPSED CMD
 15021 Sl         30:12 /usr/bin/python3 ./agent-leak-app
```

> `etime=30:12` 동안 살아 있음. STAT 의 `S`(Sleeping) + `l`(multi-threaded) — 종료된 것이 아니라 **모든 스레드가 잠들어** 있는 상태.

### 2-2. 스레드별 CPU/MEM 정체 증거

```text
$ top -H -bn1 -p 15021
  PID USER       PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
15021 agent-admin 20  0   285M    48M  5.1M S   0.0   2.4   0:01.20 python3
15022 agent-admin 20  0   285M    48M  5.1M S   0.0   2.4   0:00.18 Worker-A
15023 agent-admin 20  0   285M    48M  5.1M S   0.0   2.4   0:00.17 Worker-B
15024 agent-admin 20  0   285M    48M  5.1M S   0.0   2.4   0:00.04 Watchdog
```

```text
$ ps -L -p 15021 -o lwp,pcpu,stat,wchan:25,cmd
   LWP %CPU STAT WCHAN                     CMD
 15021  0.0 Sl   futex_wait_queue_me       python3
 15022  0.0 Sl   futex_wait_queue_me       python3
 15023  0.0 Sl   futex_wait_queue_me       python3
 15024  0.0 Sl   poll_schedule_timeout     python3
```

> 모든 워커 스레드(`15022`, `15023`)가 `futex_wait_queue_me` 에서 잠들어 있음 = **락(뮤텍스/세마포어) 대기 중**. CPU% 0.0 지속.

### 2-3. monitor.sh 관제 로그

```text
[2026-05-11 18:00:00] PID:15021 CPU:1.8% MEM:2.3% DISK_USED:42%
[2026-05-11 18:02:00] PID:15021 CPU:1.2% MEM:2.4% DISK_USED:42%
[2026-05-11 18:03:00] PID:15021 CPU:0.0% MEM:2.4% DISK_USED:42%
[2026-05-11 18:05:00] PID:15021 CPU:0.0% MEM:2.4% DISK_USED:42%
[2026-05-11 18:10:00] PID:15021 CPU:0.0% MEM:2.4% DISK_USED:42%
[2026-05-11 18:30:00] PID:15021 CPU:0.0% MEM:2.4% DISK_USED:42%
```

> 18:03 부터 CPU 0.0%로 평탄, MEM 도 변화 없음. **monitor.sh 의 Health Check는 통과**(프로세스도 살아있고 포트도 LISTEN) — 외부에서는 정상으로 보이는 점이 위험.

### 2-4. agent-leak-app 마지막 로그 (정지 직전)

```text
[2026-05-11 18:02:30.014] [INFO]  [Worker-A] acquired LOCK_X
[2026-05-11 18:02:30.018] [INFO]  [Worker-B] acquired LOCK_Y
[2026-05-11 18:02:30.022] [INFO]  [Worker-A] WAITING for LOCK_Y ...
[2026-05-11 18:02:30.025] [INFO]  [Worker-B] WAITING for LOCK_X ...
[2026-05-11 18:02:30.026] [DEBUG] [Scheduler] queue=2 active=0
# 이후 라인 없음 — 무한 대기
```

> 원본: [../evidence/deadlock_app.log](../evidence/deadlock_app.log)

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 마지막 로그 4줄로 추론하는 락 의존 그래프

```
Worker-A 보유: LOCK_X    →    필요: LOCK_Y
Worker-B 보유: LOCK_Y    →    필요: LOCK_X
```

→ 정확하게 **순환(Cycle)** 이 형성된다. 양쪽 모두 상대가 자신이 가진 락을 놓아주기를 기다리지만, 그 누구도 락을 놓지 않으므로 **영원히 대기**한다.

### 3-2. 교착상태 4대 조건이 모두 성립함을 확인

| 조건 | 본 사례에서 어떻게 성립하는가 |
| ---- | ---------------------------- |
| 1. 상호 배제 (Mutual Exclusion) | `LOCK_X`, `LOCK_Y` 모두 한 번에 한 스레드만 보유 가능한 뮤텍스 |
| 2. 점유 대기 (Hold and Wait) | Worker-A 는 LOCK_X를 **잡은 채로** LOCK_Y 를 추가 요청, Worker-B 는 그 반대 |
| 3. 비선점 (No Preemption) | 외부에서 락을 강제로 회수하지 않음 — 보유자가 자발적으로 release 해야 함 |
| 4. 순환 대기 (Circular Wait) | A → Y → B → X → A 의 닫힌 사이클 형성 |

4개 조건 중 **하나만 깨도** 데드락은 발생하지 않는다. 본 미션의 임시 조치(아래 4번 항목)는 조건 1(상호 배제) 자체를 없애는(스레드를 1개로 직렬화) 방식으로 회피한다.

### 3-3. 운영체제 동작 원리

- 리눅스에서 사용자 공간 뮤텍스는 일반적으로 **futex(Fast Userspace Mutex)** 로 구현된다. 락을 잡을 수 없을 때 스레드는 `futex(FUTEX_WAIT, ...)` 시스템콜을 통해 커널의 대기 큐에 들어가 잠든다 → `ps`/`top` 에서 `WCHAN = futex_wait_queue_me` 로 보인다.
- 잠든 스레드는 누군가 `FUTEX_WAKE` 로 깨워주지 않는 한 절대 깨어나지 않는다. 데드락 시나리오에서는 깨워줄 주체(상대 워커)가 자신도 대기 상태이므로 영원히 깨어나지 못한다.
- 커널에는 일반적인 데드락 자동 탐지가 없다. 따라서 **외부 관측자(monitor.sh / `top -H` / `ps -L`)** 가 "스레드가 모두 잠들어 있고 작업 진행이 없음"을 감지해야 한다.

### 3-4. 결론

> Worker-A 와 Worker-B 가 서로 다른 순서로 두 개의 락을 획득하다가 **순환 대기**에 빠졌다. 4대 조건이 모두 성립한 전형적인 데드락이며, `WCHAN=futex_wait_queue_me`로 머문 모든 워커 스레드와 정지된 로그가 그 증거다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 — 임시: 멀티스레드 비활성화

```bash
# Before
export MULTI_THREAD_ENABLE=true
# After (임시)
export MULTI_THREAD_ENABLE=false
```

`MULTI_THREAD_ENABLE=false` 모드는 작업을 단일 스레드에서 직렬 처리하므로, 두 스레드가 동시에 락을 잡는 상황 자체가 존재하지 않는다 → 4대 조건의 ①상호 배제 / ④순환 대기 조건을 모두 무력화.

### 4-2. Before & After 비교

| 항목 | Before (`true`) | After (`false`) |
| ---- | --------------- | --------------- |
| 데드락 발생 | **예** (실행 후 2~4분 내) | **아니오** (30분 이상 관측, 정상 동작) |
| `top -H` 스레드 수 | 4개 (main + Worker-A + Worker-B + Watchdog) | 2개 (main + Watchdog) |
| `WCHAN` | 워커 모두 `futex_wait_queue_me` 잠금 대기 | 작업 중에는 `-`(러닝), 대기 시 짧은 `poll_schedule_timeout` |
| 마지막 로그 | `WAITING for LOCK_*` 에서 정지 | 작업 완료 라인이 지속적으로 누적 |
| `curl 0.0.0.0:15034` 응답 | **타임아웃** | `Agent OK\n` 즉시 응답 |

After 시점 로그:

```text
[2026-05-11 19:00:00] PID:15890 CPU:1.4% MEM:3.2% DISK_USED:42%
[2026-05-11 19:10:00] PID:15890 CPU:1.6% MEM:3.4% DISK_USED:42%
[2026-05-11 19:30:00] PID:15890 CPU:1.5% MEM:3.6% DISK_USED:42%
# 30분 이상 정상 가동, 외부 TCP 응답 정상
```

### 4-3. 근본 해결을 위한 제안 (선택)

- **락 획득 순서 통일**: 모든 워커가 `LOCK_X → LOCK_Y` 순서로만 잡도록 강제 → 순환 대기 조건 ④ 제거
- **타임아웃 도입**: `lock.acquire(timeout=5)` 형태로 일정 시간 내 못 잡으면 포기 후 재시도 → 점유 대기 조건 ② 제거
- **단일 통합 락**: 두 락을 하나의 큰 락으로 묶거나, lock-free 자료구조(queue, atomic) 활용
- **데드락 감지 옵저버**: 워커가 일정 시간 진행 로그를 못 남기면 자동 SIGTERM 후 재시작

---

## 5. 첨부 / 참조

- [evidence/deadlock_app.log](../evidence/deadlock_app.log)
- [evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt)
- [evidence/deadlock_monitor.log](../evidence/deadlock_monitor.log)
