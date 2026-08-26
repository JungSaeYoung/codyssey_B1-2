# [Bug] agent-leak-app 멀티스레드 모드에서 교착상태(Deadlock)로 인한 무응답

> 라벨: `bug`, `priority/critical`, `area/concurrency`
> 담당: agent-dev
> 환경: Ubuntu 24.04.4 LTS / Linux 6.8.0-138-generic x86_64 / 16 vCPU / 62 GiB RAM, `ashofrondol`(uid=1000, root 아님) 계정
> 실험 환경변수: `MULTI_THREAD_ENABLE=true` / `MEMORY_LIMIT=512` / `CPU_MAX_OCCUPY=10`
> 측정 구간: 2026-08-26 09:12:50 ~ 09:17:21 (파이프라인 Before/After) · 09:24:53 ~ 09:28:00 (반복 캡처 보강) (KST)

---

## 1. Description (현상 설명)

`agent-leak-app` 을 멀티스레드 모드(`MULTI_THREAD_ENABLE=true`)로 실행하면, 부팅 후 **약 9초** 만에 다음 3가지 현상이 **동시에** 관측된다.

1. **프로세스는 살아 있다** — `ps -ef | grep agent` 에 PID 가 그대로 존재하고, 210초 뒤에도 `kill -0` 가 성공한다
2. **CPU/메모리가 변하지 않는다** — `PROC_RSS` 17.7 MB 고정, `PROC_CPU`(누적 평균) 3.2% → 0.0% 로 감쇠 후 정지
3. **로그가 멈춘다** — `agent_app.log` 의 마지막 라인 타임스탬프가 더 이상 전진하지 않고, 파일 크기·mtime 까지 고정된다

즉 **죽지도 일하지도 않는** 무응답 상태다. 자가 종료도 자가 복구도 없어 관측을 끝내려면 **수동 SIGTERM** 이 필요했다.

- 발생 시각: 2026-08-26 **09:12:50 실행** → **09:12:59.963 앱 로그 정지**(마지막 `WAITING … (Status: BLOCKED)` 라인) → **09:14:07 freeze 판정 스냅샷 수집**(60초 무변화 조건 충족). 이후 09:14:09 까지 관제에서도 무변화.
- 지속성: 같은 조합으로 한 번 더 띄워 **30초 / 120초 / 210초** 세 시점에 동일 명령을 반복한 결과, `TIME+` · `VmRSS` · `voluntary_ctxt_switches` · 로그 파일 크기와 mtime 이 **네 항목 모두 완전히 동일**했다. 시간이 지나도 상태가 전혀 변하지 않는다.
- 부트 시점에 앱이 이미 경고를 띄운다 — `[ THREAD ] Concurrency: True [ WARNING ]` / `>>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.` ([deadlock_app.log](../evidence/deadlock_app.log) L61-63)

> **정정 (실측 확인)**: 초판이 무응답 근거로 인용했던 `curl 0.0.0.0:15034` 타임아웃은 **판별력이 없다.** 정상 모드(`MULTI_THREAD_ENABLE=false`)에서도 15034 포트는 LISTEN 만 하고 HTTP 응답을 주지 않아 `curl --max-time` 이 똑같이 0 bytes 로 끝난다. 데드락 판정에는 쓰지 않고 증거로만 남긴다([deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) L39-41 · L81-90 · L124-133, [deadlock_monitor.log](../evidence/deadlock_monitor.log) L295).

---

## 2. Evidence & Logs (증거 자료)

### 2-1. PID 존재 증거 (B1-2-E-DL1)

```text
##### 09:14:07  ps -ef | grep -v grep | grep agent #####
ashofro+ 2756204       1  0 09:12 ?        00:00:00 ./agent-leak-app
ashofro+ 2756210 2756204  0 09:12 ?        00:00:00 ./agent-leak-app

##### ps -p 2756210 -o pid,stat,etime,cmd #####
    PID STAT     ELAPSED CMD
2756210 SNl        01:16 ./agent-leak-app
```

> 원본: [../evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) L56-61 (`ps -ef` 원문에는 vscode-server 프로세스가 문자열 매칭으로 함께 잡힌다 — 원문 그대로 보존)

- PyInstaller onefile 바이너리라 **부모 부트로더(2756204) + 실제 워커(2756210)** 두 프로세스가 뜬다. 관측 대상은 자식 쪽이며, 앱이 로그에 남기는 PID 와도 이쪽이 일치한다.
- `ELAPSED 01:16` — 76초 동안 살아 있다. 위 `ps -ef` 의 `TIME` 열은 `00:00:00`, 즉 **살아 있는 내내 CPU 를 거의 쓰지 않았다.**
- `STAT = SNl` : `S`(Sleeping) + `N`(nice 양수) + `l`(multi-threaded). 죽은 것이 아니라 **모든 스레드가 잠들어** 있다.

### 2-2. 스레드별 CPU/MEM 정체 증거 (B1-2-E-DL2)

```text
##### top -H -bn1 -p 2756210 #####
top - 09:14:07 up 3 days, 16:24,  4 users,  load average: 0.17, 0.27, 0.56
Threads:   3 total,   0 running,   3 sleeping,   0 stopped,   0 zombie

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2756210 ashofro+  30  10  171572  18080   9696 S   0.0   0.0   0:00.04 agent-l+
2756386 ashofro+  30  10  171572  18080   9696 S   0.0   0.0   0:00.00 agent-l+
2756387 ashofro+  30  10  171572  18080   9696 S   0.0   0.0   0:00.00 agent-l+

##### ps -L -p 2756210 -o lwp,pcpu,stat,wchan:25,cmd #####
    LWP %CPU STAT WCHAN                     CMD
2756210  0.0 SNl  futex_wait_queue          ./agent-leak-app
2756386  0.0 SNl  futex_wait_queue          ./agent-leak-app
2756387  0.0 SNl  futex_wait_queue          ./agent-leak-app
```

> 원본: [../evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) L63-79

- 스레드는 **3개**다: 메인(2756210 — 프로세스 PID 와 같은 LWP) + 워커 2개(2756386, 2756387). `Threads: 3 total, 0 running, 3 sleeping`. 앱 로그의 `Worker-Thread-1` / `Worker-Thread-2` 가 이 두 LWP 에 대응하는 것으로 읽히지만, `top -H`/`ps -L` 이 스레드 이름을 주지 않으므로 **1:1 대응까지는 확인하지 못했다.**
- **세 스레드 전부 `WCHAN = futex_wait_queue`** — 커널의 futex 대기 큐에 들어가 있다. 즉 락(뮤텍스) 대기다.
- 워커 두 스레드의 `TIME+` 는 `0:00.00`. 시작 이후 **측정 가능한 CPU 시간을 한 번도 쓰지 않았다.** 메인의 0:00.04 는 기동 비용이다.
- `RES 18080 kB` 로 세 스레드(=같은 주소 공간)가 동일. 메모리도 정지 상태다.

### 2-3. `monitor.sh` 관제 로그

```text
### ----- Before 마지막 수집 — 로그·PROC_RSS 정지 상태에서 PID 만 생존 (freeze) -----
$ AGENT_LOG_DIR=/home/ashofrondol/b12_sandbox/logs bash src/monitor.sh        # 2026-08-26 09:14:09
[HEALTH CHECK]
Checking process 'agent-leak-app'... [OK] (PID: 2756210)
Checking port 15034... [OK]

[RESOURCE MONITORING]
SYS  CPU Usage : 1.7%
SYS  MEM Usage : 37.5%
PROC CPU (avg) : 0.0%   (PID 2756210)
PROC RSS       : 17.7 MB (PID 2756210)
DISK Used      : 9%
```

> 원본: [../evidence/deadlock_monitor.log](../evidence/deadlock_monitor.log) L59-77

관제 라인(Before 구간, 3초 간격 고해상도 샘플 24개 중 6개 발췌):

```text
[2026-08-26 09:12:51] PID:2756210 SYS_CPU:1.1% SYS_MEM:37.5% PROC_CPU:3.2% PROC_RSS:17.6MB DISK_USED:9%
[2026-08-26 09:12:58] PID:2756210 SYS_CPU:1.7% SYS_MEM:37.5% PROC_CPU:0.5% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:13:11] PID:2756210 SYS_CPU:2.3% SYS_MEM:37.5% PROC_CPU:0.1% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:13:31] PID:2756210 SYS_CPU:1.7% SYS_MEM:37.5% PROC_CPU:0.0% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:13:54] PID:2756210 SYS_CPU:2.3% SYS_MEM:37.5% PROC_CPU:0.0% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:14:07] PID:2756210 SYS_CPU:1.7% SYS_MEM:37.5% PROC_CPU:0.0% PROC_RSS:17.7MB DISK_USED:9%
```

> 원본: [../evidence/deadlock_monitor.log](../evidence/deadlock_monitor.log) L192-215 에서 발췌 (§3, Before 구간 24샘플 전량은 원본 참조)

- `PROC_RSS` 는 09:12:51 부터 09:14:07 까지 **76초 동안 17.6 → 17.7 MB**, 사실상 완전 정지.
- `PROC_CPU` 는 `ps` 의 **누적 평균**이라, 새 CPU 시간을 전혀 쓰지 않으면 분모(경과 시간)만 커져 3.2% → 0.0% 로 수렴한다. 이 감쇠 곡선 자체가 "이 시점 이후 일을 하지 않았다"는 증거다.
- **`monitor.sh` 의 Health Check 는 끝까지 통과한다** — 프로세스도 살아 있고 포트도 LISTEN 이다. 외부에서 보면 정상으로 보인다는 점이 이 장애의 가장 위험한 성질이다.

### 2-4. `agent-leak-app` 마지막 로그 지점 (B1-2-E-DL3)

```text
2026-08-26 09:12:52,928 [WARNING] [AgentWorker] Initializing concurrent transaction processors...
2026-08-26 09:12:52,929 [WARNING] [System] CAUTION: Strict resource locking is enabled.
2026-08-26 09:12:57,951 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-08-26 09:12:57,951 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
2026-08-26 09:12:57,952 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-08-26 09:12:57,952 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
2026-08-26 09:12:57,952 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-08-26 09:12:57,952 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
2026-08-26 09:12:57,952 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
2026-08-26 09:12:59,955 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-08-26 09:12:59,955 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
2026-08-26 09:12:59,963 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-08-26 09:12:59,963 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
# 이후 라인 없음 — 무한 대기
```

> 원본: [../evidence/deadlock_app.log](../evidence/deadlock_app.log) L82-94 (같은 계열이 nohup stdout L66-78 에도 기록됨)

이 13줄이 이 리포트의 핵심 증거다. 락 이름은 `Shared_Memory_A` / `Socket_Pool_B`, 스레드는 `Worker-Thread-1` / `Worker-Thread-2` 이며, 메인 스레드(`[AgentWorker] Waiting for worker threads to complete transactions...`)는 두 워커의 조인을 기다린다.

### 2-5. 시간이 지나도 변하지 않음 (B1-2-A7)

"지금 멈춰 있다"가 아니라 "계속 멈춰 있다"를 못 박기 위해, 같은 조합으로 한 번 더 띄워 **30초 / 120초 / 210초** 세 시점에 동일한 명령을 반복했다.

세 시점에서 **정지 판정에 쓰는 지표가 전부 동일**했다 — `TIME+`, `WCHAN`(`futex_wait_queue`), `VmRSS`(18148 kB), `voluntary_ctxt_switches`(14), 로그 파일 크기(1517 bytes)·mtime. (`%CPU` 표시값만 0.1 → 0.0 으로 감쇠한 뒤 고정됐다.)(아래는 t≈30s 블록 원문, t≈120s·t≈210s 는 원본 L169-193 · L195-219 참조).

```text
##### t≈30s  2026-08-26 09:24:53 #####
$ ps -L -p 2774062 -o lwp,pcpu,stat,wchan:20,time,cmd
    LWP %CPU STAT WCHAN                    TIME CMD
2774062  0.1 SNl  futex_wait_queue     00:00:00 ./agent-leak-app
2774166  0.0 SNl  futex_wait_queue     00:00:00 ./agent-leak-app
2774167  0.0 SNl  futex_wait_queue     00:00:00 ./agent-leak-app
$ top -H -bn1 -p 2774062 | tail -5

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2774062 ashofro+  30  10  171572  18148   9760 S   0.0   0.0   0:00.04 agent-l+
2774166 ashofro+  30  10  171572  18148   9760 S   0.0   0.0   0:00.00 agent-l+
2774167 ashofro+  30  10  171572  18148   9760 S   0.0   0.0   0:00.00 agent-l+

VmRSS:	   18148 kB
Threads:	3
voluntary_ctxt_switches:	14
nonvoluntary_ctxt_switches:	0

$ stat -c '%s bytes, mtime=%y' $AGENT_LOG_DIR/agent_app.log
1517 bytes, mtime=2026-08-26 09:24:32.637860249 +0900

##### 210초 경과 후에도 PID 생존 — 종료되지 않음 (자가 복구 없음) #####
$ kill -0 2774062 && echo ALIVE
ALIVE
$ kill 2774062   # 관측 종료 — 수동 SIGTERM
```

> 원본: [../evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) L143-167(t≈30s) · L169-193(t≈120s) · L195-219(t≈210s) · L221-226(생존 확인 및 수동 종료)

- `TIME+` 세 값, `VmRSS 18148 kB`, `voluntary_ctxt_switches 14` / `nonvoluntary 0`, 로그 파일 `1517 bytes` 와 mtime **나노초까지** 세 시점 모두 동일하다.
- 특히 **문맥 교환 카운터가 14 에서 멈춰 있다**는 것은, 이 프로세스가 스케줄러에 의해 깨어난 적조차 없다는 뜻이다. "느린 것"과 "멈춘 것"을 가르는 결정적 지표다.
- 210초 뒤에도 살아 있어 관측을 끝내려면 수동 `kill` 이 필요했다 — **자가 종료도 자가 복구도 없다.**

### 2-6. 참고 — `curl` 은 판별 지표가 아니다

```text
지표                          Before (true)                    After (false)
curl 127.0.0.1:15034          timeout, 0 bytes                 timeout, 0 bytes  ← 판별력 없음
```

> 원본: [../evidence/deadlock_monitor.log](../evidence/deadlock_monitor.log) L295 / [../evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) L81-90(Before) · L124-133(After)

두 구간 모두 `Connected to 127.0.0.1 port 15034` 까지는 가고 응답 없이 타임아웃한다. 포트는 열려 있지만 HTTP 응답을 주는 서비스가 아니므로, **데드락 판정에 쓰면 정상 상태를 오탐한다.** 실제로 변별력이 있는 지표는 **① 로그 mtime 정지 ② `ps -L` 전 스레드 `futex_wait_queue` ③ `TIME+` 누적 정지** 세 가지다.

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 마지막 로그 4줄로 추론하는 락 의존 그래프 (B1-2-E-DL4 / B1-2-A8)

아래 두 블록은 **2-4 의 로그 원문에서 시각·스레드·락·상태만 추린 요약표**다(원문은 2-4 참조).

```text
09:12:57,952  Worker-Thread-1  LOCK ACQUIRED: [Shared_Memory_A]
09:12:57,952  Worker-Thread-2  LOCK ACQUIRED: [Socket_Pool_B]
09:12:59,955  Worker-Thread-2  WAITING for [Shared_Memory_A]... (Status: BLOCKED)
09:12:59,963  Worker-Thread-1  WAITING for [Socket_Pool_B]... (Status: BLOCKED)
```

```text
Worker-Thread-1  보유: Shared_Memory_A   →   필요: Socket_Pool_B
Worker-Thread-2  보유: Socket_Pool_B     →   필요: Shared_Memory_A
```

→ 정확하게 **순환(Cycle)** 이 형성된다. T1 → (Socket_Pool_B) → T2 → (Shared_Memory_A) → T1. 양쪽 모두 상대가 자기 락을 놓아주기를 기다리지만, 그 누구도 놓지 않으므로 **영원히 대기**한다.

로그만으로도 순환이 증명되지만, `ps -L` 이 **세 스레드 전부를 `futex_wait_queue` 에서** 잡아 준 것이 커널 레벨 뒷받침이다. 두 워커는 서로의 락을, 메인은 두 워커의 조인을 기다린다 — 그래서 3개 전부 futex 대기다.

### 3-2. 교착상태 4대 조건이 모두 성립함을 확인

| 조건 | 본 사례에서 어떻게 성립하는가 | 관측 근거 |
| ---- | ---------------------------- | --------- |
| 1. 상호 배제 (Mutual Exclusion) | `Shared_Memory_A`, `Socket_Pool_B` 모두 한 번에 한 스레드만 보유 가능 | `LOCK ACQUIRED … (Holding...)` 뒤 상대가 `BLOCKED` 로 진입 |
| 2. 점유 대기 (Hold and Wait) | T1 은 `Shared_Memory_A` 를 **잡은 채로** `Socket_Pool_B` 를 추가 요청, T2 는 그 반대 | `Need resource … to finish job` 라인이 보유 상태에서 발생 |
| 3. 비선점 (No Preemption) | 외부에서 락을 강제 회수하지 않음 — 보유자가 자발적으로 release 해야 함 | 210초 뒤에도 `futex_wait_queue` 유지, 자가 복구 0 |
| 4. 순환 대기 (Circular Wait) | T1 → B → T2 → A → T1 의 닫힌 사이클 | 3-1 의 마지막 4줄 |

4개 조건 중 **하나만 깨도** 데드락은 발생하지 않는다. 본 미션의 임시 조치(4번 항목)는 상호 배제 속성 자체를 없애는 것이 아니라, 작업을 단일 스레드로 **직렬화하여 동시 경쟁을 제거**함으로써 ②점유 대기·④순환 대기가 성립하지 못하게 만들어 회피한다.

### 3-3. 운영체제 동작 원리

- 리눅스에서 사용자 공간 뮤텍스는 **futex(Fast Userspace Mutex)** 로 구현된다. 경합이 없으면 커널을 부르지 않고 사용자 공간에서 끝나지만, 락을 잡을 수 없으면 `futex(FUTEX_WAIT, …)` 시스템콜로 커널 대기 큐에 들어가 잠든다 → `ps`/`top` 에서 `WCHAN = futex_wait_queue` 로 보인다(커널 6.8 기준 심볼명. 예전 커널에서는 `futex_wait_queue_me`).
- 잠든 스레드는 누군가 `FUTEX_WAKE` 로 깨워 주지 않는 한 절대 깨어나지 않는다. 데드락에서는 깨워 줄 주체(상대 워커)가 자신도 대기 중이므로 영원히 깨어나지 못한다. **`voluntary_ctxt_switches` 가 14 에서 고정된 것**이 이 상태를 그대로 보여 준다 — 깨어나 실행된 적이 없으니 문맥 교환도 늘지 않는다.
- 커널에는 사용자 공간 락에 대한 일반적인 데드락 자동 탐지가 없다. 프로세스는 `S`(interruptible sleep) 상태라 OOM Killer 나 워치독의 대상도 아니다. 따라서 **외부 관측자(`monitor.sh` / `top -H` / `ps -L` / 로그 mtime)** 가 "스레드가 모두 잠들어 있고 진행이 없음"을 감지해야 한다.
- 프로세스가 살아 있고 포트도 LISTEN 이므로 **프로세스 존재·포트 검사만 하는 헬스체크는 100% 통과한다.** 무응답 감지를 하려면 "진행"을 보는 지표(로그 mtime, 처리 카운터, `TIME+` 증가)가 필요하다.

### 3-4. 결론

> `Worker-Thread-1` 과 `Worker-Thread-2` 가 서로 다른 순서로 두 개의 락(`Shared_Memory_A`, `Socket_Pool_B`)을 획득하다가 **순환 대기**에 빠졌다. 교착 4대 조건이 모두 성립한 전형적인 데드락이며, `WCHAN=futex_wait_queue` 에 머문 전 스레드 · 정지한 `TIME+` 와 문맥 교환 카운터 · 나노초까지 고정된 로그 mtime 이 그 증거다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 — 임시: 멀티스레드 비활성화

```bash
# Before
export MULTI_THREAD_ENABLE=true  MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10
# After (임시)
export MULTI_THREAD_ENABLE=false MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10
```

> `MEMORY_LIMIT` / `CPU_MAX_OCCUPY` 는 **양쪽 모두 안전값으로 고정**했다. 이 앱은 부팅 시 Resource Check 로 시나리오를 하나 고르기 때문에, `CPU_MAX_OCCUPY>50` 으로 두면 freeze 를 관측하기도 전에 `CpuWorker` 가 프로세스를 종료시켜(exit 143) `MULTI_THREAD_ENABLE` 의 순수 효과를 볼 수 없다.

`MULTI_THREAD_ENABLE=false` 모드는 작업을 단일 스레드에서 직렬 처리하므로, 두 워커가 동시에 서로 다른 락을 잡고 맞물리는 상황 자체가 생기지 않는다. 락의 **①상호 배제 속성은 그대로**이지만, 동시 경쟁이 사라져 **②점유 대기·④순환 대기가 성립할 수 없으므로** 데드락이 회피된다.

### 4-2. Before & After 비교 (B1-2-E-DL1~4 / B1-2-A9)

| 지표 | Before (`true`) | After (`false`) |
| ---- | --------------- | --------------- |
| 부팅 배너 | `[ THREAD ] Concurrency: True [ WARNING ]` + `>>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.` | `[ THREAD ] Concurrency: False [ OK ]` + `>>> SYSTEM STATUS: STABLE.` |
| 선택된 시나리오 | 동시성 트랜잭션 (`[AgentWorker]` 워커 2개) | `>>> Scenario Selected: [Healthy System Monitoring]` |
| 데드락 발생 | **예** — 부팅 9초 후 | **아니오** — 관측 3m00s 내내 정상 |
| PID 생존 | 생존 (그러나 무응답) | 생존 (정상 가동) |
| 앱 로그 | 09:12:59.963 이후 완전 정지 | 끝까지 계속 전진 (09:17:21 까지) |
| 마지막 로그 라인 | `[Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)` | 정지 없음 — `[MemoryWorker] Current Heap: 450MB` 까지 전진 |
| `top -H` 스레드 수 | 3개 (메인 + Worker-Thread-1 + Worker-Thread-2) | 3개 (메인 + 워커 2) — **수는 같고 상태가 다르다** |
| `ps -L` WCHAN | **3개 전부** `futex_wait_queue` | `futex_wait_queue` 1개(메인=조인 대기) + `do_select` 2개(워커 동작 중) |
| `top -H` TIME+ | `0:00.04 / 0:00.00 / 0:00.00` (정지) | `0:00.05 / 0:00.79 / 0:00.47` (전진) |
| `RES` | 18080 kB 고정 | 453564 kB (증가 중) |
| `PROC_RSS` (관제) | 17.7 MB 에서 76초간 불변 | 17.6 → 417.9 MB 로 증가 |
| `PROC_CPU` (누적평균) | 3.2% → 0.0% 로 감쇠 후 고정 | 0.7% 유지 (일하고 있음) |
| 자가 종료 / 자가 복구 | 없음 (수동 SIGTERM 필요) | 해당 없음 |
| `curl 127.0.0.1:15034` | timeout, 0 bytes | timeout, 0 bytes ← **판별력 없음** |

> 원본: [../evidence/deadlock_monitor.log](../evidence/deadlock_monitor.log) L274-302 (§4 비교표) · L192-215(Before 샘플) · L217-272(After 샘플) / [../evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) L63-79(Before) · L106-122(After)

After 시점(09:17:19)의 실제 스냅샷 — **초판이 "evidence 에 After 캡처가 없다"고 자인했던 항목이며, 이번 수집으로 확보했다.**

```text
##### ps -p 2758660 -o pid,stat,etime,cmd #####
    PID STAT     ELAPSED CMD
2758660 SNl        03:04 ./agent-leak-app

##### top -H -bn1 -p 2758660 #####
Threads:   3 total,   0 running,   3 sleeping,   0 stopped,   0 zombie
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2758660 ashofro+  30  10  695860 453564   9792 S   0.0   0.7   0:00.05 agent-l+
2758757 ashofro+  30  10  695860 453564   9792 S   0.0   0.7   0:00.79 agent-l+
2758758 ashofro+  30  10  695860 453564   9792 S   0.0   0.7   0:00.47 agent-l+

##### ps -L -p 2758660 -o lwp,pcpu,stat,wchan:25,cmd #####
    LWP %CPU STAT WCHAN                     CMD
2758660  0.0 SNl  futex_wait_queue          ./agent-leak-app
2758757  0.4 SNl  do_select                 ./agent-leak-app
2758758  0.2 SNl  do_select                 ./agent-leak-app
```

> 원본: [../evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) L102-122

**Before/After 를 가르는 신호는 "스레드 수"가 아니라 "무엇을 기다리는가"다.** After 에서도 스레드는 3개이고 메인은 여전히 `futex_wait_queue`(워커 조인 대기)에 있다. 다른 것은 워커 두 개가 `do_select`(타이머·I/O 대기 = 주기 작업 중)에 있고 `TIME+` 가 실제로 전진한다는 점이다. 데드락 판정에는 **`ps -L` 의 WCHAN 분포 + `TIME+` 전진 여부**를 함께 봐야 한다.

After 구간 관제 로그:

```text
[2026-08-26 09:14:15] PID:2758660 SYS_CPU:1.7% SYS_MEM:37.5% PROC_CPU:3.3% PROC_RSS:17.6MB DISK_USED:9%
[2026-08-26 09:14:45] PID:2758660 SYS_CPU:1.7% SYS_MEM:37.9% PROC_CPU:0.7% PROC_RSS:267.9MB DISK_USED:9%
[2026-08-26 09:15:14] PID:2758660 SYS_CPU:2.3% SYS_MEM:38.3% PROC_CPU:0.7% PROC_RSS:493.0MB DISK_USED:9%
[2026-08-26 09:17:15] PID:2758660 SYS_CPU:3.4% SYS_MEM:38.6% PROC_CPU:0.7% PROC_RSS:417.9MB DISK_USED:9%
```

> 원본: [../evidence/deadlock_monitor.log](../evidence/deadlock_monitor.log) L217-272 에서 발췌

`PROC_RSS` 가 오르내리는 것은 정상 시나리오의 `MemoryWorker` 가 525 MB 에서 캐시를 비우고 다시 쌓는 주기 거동이다(`MEMORY_LIMIT=512`). 정지가 아니라 **진행하고 있다는 신호**다.

### 4-3. 근본 해결을 위한 제안 (선택)

- **락 획득 순서 통일**: 모든 워커가 `Shared_Memory_A → Socket_Pool_B` 순서로만 잡도록 강제 → 순환 대기 조건 ④ 제거
- **타임아웃 도입**: `lock.acquire(timeout=5)` 형태로 일정 시간 내 못 잡으면 포기 후 재시도(백오프) → 점유 대기 조건 ② 제거
- **단일 통합 락 / lock-free**: 두 락을 하나로 묶거나 `queue.Queue` 등 원자적 자료구조로 자원 소유권을 옮김
- **데드락 감지 옵저버**: 워커가 일정 시간 진행 로그를 못 남기면 자동 SIGTERM 후 재시작. 판정 조건은 curl 이 아니라 **로그 mtime 정지 + `TIME+` 무변화 + 전 스레드 futex 대기** 로 잡는다
- **헬스체크 강화**: 프로세스 존재·포트 LISTEN 만으로는 이 장애를 절대 잡지 못한다. `monitor.sh` 에 "마지막 앱 로그 mtime 이 N초 이상 정지" 판정을 추가할 것을 권한다

---

## 5. 첨부 / 참조

- [evidence/deadlock_app.log](../evidence/deadlock_app.log) — 부트 배너(`POTENTIAL DEADLOCK` 경고), `LOCK ACQUIRED` → `WAITING … BLOCKED` 6줄, After 정상 구간 전량
- [evidence/deadlock_ps_top.txt](../evidence/deadlock_ps_top.txt) — Before/After `ps -ef` · `ps -p` · `top -H` · `ps -L` 대조, 30s/120s/210s 반복 캡처, `curl` 원문
- [evidence/deadlock_monitor.log](../evidence/deadlock_monitor.log) — `monitor.sh` 콘솔 발췌 + 관제 라인 전량 + 3초 샘플 + `MULTI_THREAD_ENABLE` 비교표
