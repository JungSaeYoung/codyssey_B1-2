# [Bug] agent-leak-app CPU 과점유로 Watchdog 정책에 의한 SIGTERM 종료

> 라벨: `bug`, `priority/high`, `area/cpu`
> 담당: agent-dev
> 환경: Ubuntu 24.04 (OrbStack, 4 vCPU), agent-admin 계정, `CPU_MAX_OCCUPY=80`

---

## 1. Description (현상 설명)

`agent-leak-app` 실행 후 약 **3~5분이 경과한 시점**부터 단일 프로세스의 CPU 점유율이 급격히 상승하여 `CPU_MAX_OCCUPY=80%` 임계치를 초과한다. 이때 앱 내부 Watchdog 정책이 SIGTERM 을 발송하여 프로세스를 종료시킨다.

- 발생 시각: 2026-05-11 16:00:00 실행 → 16:04:12 종료 (약 4분)
- 재현성: 동일 설정으로 5회 시도, 5회 모두 3~6분 사이 동일 시그니처로 종료
- 시스템 전체 load average가 아닌, **단일 프로세스(`agent-leak-app`)** 만 CPU 를 잡아먹는 패턴

---

## 2. Evidence & Logs (증거 자료)

### 2-1. `monitor.sh` 관제 로그

```text
[2026-05-11 16:00:00] PID:14001 CPU:2.1%   MEM:6.3% DISK_USED:42%
[2026-05-11 16:01:00] PID:14001 CPU:3.4%   MEM:6.4% DISK_USED:42%
[2026-05-11 16:02:00] PID:14001 CPU:38.7%  MEM:6.5% DISK_USED:42%
[2026-05-11 16:03:00] PID:14001 CPU:72.5%  MEM:6.6% DISK_USED:42%
[2026-05-11 16:04:00] PID:14001 CPU:91.2%  MEM:6.6% DISK_USED:42%
[2026-05-11 16:05:00] [ERROR] Application process not running.
```

> 1분당 CPU%가 2% → 38% → 72% → 91%로 비선형 급상승. MEM은 거의 변동 없음 → "CPU 단독 폭주" 패턴.
> 원본: [../evidence/cpu_monitor.log](../evidence/cpu_monitor.log)

### 2-2. agent-leak-app 실행 로그

```text
[2026-05-11 16:00:00.221] [INFO]  Boot sequence OK. Agent READY (pid=14001)
[2026-05-11 16:01:45.910] [INFO]  [Scheduler] dispatch tasks: 8 pending
[2026-05-11 16:02:30.005] [INFO]  [Worker-3] heavy_compute() loop=120000
[2026-05-11 16:03:15.812] [WARN]  [Watchdog] cpu=72.5% (threshold 80%) — sustained 60s
[2026-05-11 16:04:11.443] [CRITICAL] [Watchdog] cpu=91.2% > 80% sustained 90s
[2026-05-11 16:04:11.512] [CRITICAL] [Watchdog] INITIATING EMERGENCY ABORT (SIGTERM)
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
[2026-05-11 16:04:12.001] [INFO]  Caught signal SIGTERM, shutting down.
```

> 원본: [../evidence/cpu_app.log](../evidence/cpu_app.log)

### 2-3. `top` / `ps` 출력 (16:04:00 시점, 종료 직전)

```text
$ top -bn1 -o %CPU | head -n 12
top - 16:04:00 up 12 days,  3:41,  2 users,  load average: 2.85, 1.94, 1.12
Tasks: 132 total,   2 running, 130 sleeping
%Cpu(s): 92.3 us,  3.1 sy,  0.0 ni,  4.2 id,  0.0 wa,  0.0 hi,  0.4 si,  0.0 st

  PID USER       PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
14001 agent-admin 20  0   215M    32M  4.1M R  91.2   6.6   3:24.18 python3
   12 root       20  0     0       0      0 I   0.7   0.0   0:11.20 rcu_sched
```

```text
$ ps -o pid,pcpu,pmem,stat,etime,cmd -p 14001
   PID %CPU %MEM STAT     ELAPSED CMD
 14001 91.2  6.6 R+         04:00 /usr/bin/python3 ./agent-leak-app
```

> 단일 프로세스가 **한 코어의 91%** (top 의 per-process %CPU 는 1코어=100% 정규화이므로 4-vCPU 시스템 전체로는 약 22.8%)를 점유. 시스템 전체 압박은 top 헤더의 `%Cpu(s) 92.3 us` 와 `load average 2.85` 로 별도 확인된다. STAT 가 **`R`(Running)** 으로 지속 — I/O 대기 없이 사용자 모드에서 계속 실행되는 busy-loop 시그니처.

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 현상 → 원인 매핑

| 관측 사실 | 추론되는 원인 |
| --------- | ------------- |
| CPU만 비선형 급상승, MEM은 일정 | 메모리 누수가 아닌 **계산/루프 폭주** |
| `top` STAT = `R+`, %CPU > 90 지속 | I/O 대기가 아니라 **사용자 모드 CPU bound** (`%us` 92.3) |
| `heavy_compute() loop=120000` 직후 임계치 돌파 | 워커가 종료 조건 없는 루프 또는 과대한 반복 횟수로 폭주 |
| `Watchdog ... SIGTERM` 로그가 OOM 메시지 없이 단독 출력 | 앱 자체 보호 정책(Watchdog) 동작 |

### 3-2. 운영체제 동작 원리

- 리눅스 스케줄러는 `R`(Runnable) 상태 프로세스에 시간 할당량을 배분한다. CPU 바운드 작업이 동일 우선순위의 다른 프로세스에 비해 너무 많은 시간을 점유하면 시스템 응답성이 떨어진다(load average 상승).
- 본 앱의 `Watchdog`은 외부 OS 동작과 별개로 **자체적으로** `%CPU > CPU_MAX_OCCUPY`가 일정 시간 지속되면 SIGTERM 으로 자기 자신을 종료시켜 시스템에 미치는 영향을 차단한다.
- SIGTERM 은 SIGKILL 과 달리 graceful shutdown을 허용하므로, 앱이 핸들러를 등록해 두면 `Caught signal SIGTERM, shutting down.` 같은 정리 로그를 남길 수 있다.

### 3-3. 결론

> 워커 스레드의 계산 루프가 종료 조건/반복 횟수 조정 없이 폭주하여 CPU 사용률이 임계치를 초과했고, **Watchdog 정책이 SIGTERM 으로 프로세스를 종료**시켰다. 메모리/디스크 변화가 없는 점이 이를 보강한다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 — 임시: `CPU_MAX_OCCUPY` 상향

```bash
# Before
export CPU_MAX_OCCUPY=80
# After (임시)
export CPU_MAX_OCCUPY=95
```

### 4-2. Before & After 비교

| 항목 | Before (`CPU_MAX_OCCUPY=80`) | After (`CPU_MAX_OCCUPY=95`) |
| ---- | ---------------------------- | --------------------------- |
| 종료 시점 | 실행 후 **약 4분** | 실행 후 **약 12분**까지 생존 (이후 95% 도달 시 동일하게 종료) |
| 마지막 CPU% | 91.2% | 95.7% (도달 즉시 종료) |
| 종료 로그 | `WATCHDOG ... SIGTERM` | 동일 |

After 시점 monitor.log 발췌:

```text
[2026-05-11 16:30:00] PID:14502 CPU:2.0%  MEM:6.4% DISK_USED:42%
[2026-05-11 16:38:00] PID:14502 CPU:88.4% MEM:6.7% DISK_USED:42%
[2026-05-11 16:42:00] PID:14502 CPU:95.7% MEM:6.7% DISK_USED:42%
[2026-05-11 16:43:00] [ERROR] Application process not running.
```

→ **여전히 종료됨**. `CPU_MAX_OCCUPY` 상향은 임계치만 미루는 임시 조치일 뿐, 폭주 루프 자체를 멈추지는 않는다.

### 4-3. 근본 해결을 위한 제안 (선택)

- `heavy_compute()` 반복 횟수에 상한 부여 / 청크 단위 처리 후 `time.sleep(0)` 또는 `asyncio.sleep` 양보
- CPU 친화도(taskset, cpuset)로 특정 코어에 격리, `nice`/`renice` 로 우선순위 하향
- 알고리즘 자체 최적화 (O(n²) → O(n log n) 등)
- `py-spy record -p <pid>` 로 호출 스택 프로파일링 → 폭주 함수 식별

---

## 5. 첨부 / 참조

- [evidence/cpu_monitor.log](../evidence/cpu_monitor.log)
- [evidence/cpu_app.log](../evidence/cpu_app.log)
- [evidence/cpu_top_ps.txt](../evidence/cpu_top_ps.txt)
