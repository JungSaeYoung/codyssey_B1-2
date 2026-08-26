# [Bug] agent-leak-app 실행 34초 경과 시 MemoryGuard 정책에 의한 강제 종료

> 라벨: `bug`, `priority/high`, `area/memory`
> 담당: agent-dev
> 환경: Ubuntu 24.04.4 LTS / Linux 6.8.0-138-generic x86_64 / 16 vCPU / 62 GiB RAM, `ashofrondol`(uid=1000, root 아님) 계정
> 실험 환경변수: `MEMORY_LIMIT=256` / `CPU_MAX_OCCUPY=10` / `MULTI_THREAD_ENABLE=false`
> 측정 구간: 2026-08-26 09:02:35 ~ 09:06:13 (파이프라인 Before/After) · 08:47~08:52 (`MEMORY_LIMIT` 스윕 probe) · 09:23:24~09:23:52 (`smaps` 보강 캡처) (KST)

---

## 1. Description (현상 설명)

`agent-leak-app` 을 정상 실행한 뒤 **34초가 경과**하면, 별도의 사용자 입력이나 외부 요청이 없는데도 다음 두 줄을 남기고 프로세스가 스스로 종료된다.

```text
2026-08-26 09:03:09,155 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-08-26 09:03:09,155 [CRITICAL] [MemoryGuard] Self-terminating process 2738539 to prevent system instability.
```

> 원본: [../evidence/oom_app.log](../evidence/oom_app.log) L74-75 (nohup stdout) — 같은 2줄이 앱이 직접 쓰는 `agent_app.log` L90-91 에도 기록된다.

- 발생 시각: 2026-08-26 **09:02:36 실행**(부트 시퀀스 `[1/6]`~`[6/6]` 전부 `[OK]`) → **09:03:11 프로세스 소멸**. 생존 **0m34s**, 종료 코드 **137**(= 128+9, SIGKILL).
- 재현성: `MEMORY_LIMIT=256` 조합에서 **동일한 `[MemoryGuard]` 2줄 종료를 3회 관측**했다 — ① 실험 파이프라인 Before(0m34s, exit 137, [oom_monitor.log](../evidence/oom_monitor.log) L332-335) ② 독립 probe `p_mem256_cpu95`(34초, exit 137, [oom_monitor.log](../evidence/oom_monitor.log) L345-351) ③ `smaps` 보강 캡처 실행(09:23:51,618 에 같은 2줄을 남기고 소멸 — 이 실행에서는 종료 코드를 따로 수집하지 않았다, [oom_ps_top.txt](../evidence/oom_ps_top.txt) L364-372). 한도만 100MB 로 낮춘 probe 도 13초 만에 같은 방식(exit 137)으로 죽었다.
- 외부 트래픽 없음. 부팅 직후부터 **대상 프로세스의 물리 메모리(RSS)만** 단조 증가 → 한도 도달 → 자가 종료 패턴이 반복된다.
- 부트 시점에 앱이 이미 경고를 띄운다 — `[ MEMORY ] Limit: 256MB [ WARNING: Recommend Over 256MB ]` ([oom_app.log](../evidence/oom_app.log) L56).

> **정정 (실측 확인)**: 과제 PDF 예시에 있는 `>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<` 배너는 **이 바이너리가 출력하지 않는다.** 이번 수집분(`evidence/oom_app.log` 505줄) 어디에도 해당 문자열이 없다. 종료 판정 근거는 위 `[MemoryGuard]` 2줄과 종료 코드 137 이다.

---

## 2. Evidence & Logs (증거 자료)

### 2-0. 읽기 전 — `monitor.sh` 의 지표 의미

`src/monitor.sh` 는 한 줄에 **시스템 전체 지표(`SYS_*`)와 대상 프로세스 지표(`PROC_*`)를 함께** 남긴다.

| 컬럼 | 산출식 | 의미 |
| ---- | ------ | ---- |
| `SYS_CPU` / `SYS_MEM` | `top -bn1` / `free` | **호스트 전체** 값. 62 GiB 머신에서 앱 heap 이 수백 MB 늘어도 거의 움직이지 않는다 |
| `PROC_RSS` | `ps -o rss= -p <PID>` → MB 환산 | **대상 프로세스의 물리 메모리**. B1-2-A1 이 요구하는 "메모리 상승 수치"는 이 컬럼이다 |
| `PROC_CPU` | `ps -o pcpu= -p <PID>` | 대상 프로세스의 **시작 이후 누적 평균** %CPU (순간값 아님) |

이 구분이 이 리포트의 전제다. **`SYS_MEM` 으로는 이 장애가 관측되지 않는다.**

### 2-1. `monitor.sh` 콘솔 출력 — 구간 경계 2블록

```text
### ----- Before 구간 시작 — 첫 정상 수집 -----
$ AGENT_LOG_DIR=/home/ashofrondol/b12_sandbox/logs bash src/monitor.sh        # 2026-08-26 09:02:38
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-leak-app'... [OK] (PID: 2738539)
Checking port 15034... [OK]

[RESOURCE MONITORING]
SYS  CPU Usage : 1.7%
SYS  MEM Usage : 37.5%
PROC CPU (avg) : 2.2%   (PID 2738539)
PROC RSS       : 42.7 MB (PID 2738539)
DISK Used      : 9%

### ----- Before 마지막 정상 수집 — MemoryGuard 자가종료 직전 (PROC_RSS 최고점) -----
$ AGENT_LOG_DIR=/home/ashofrondol/b12_sandbox/logs bash src/monitor.sh        # 2026-08-26 09:03:05
[RESOURCE MONITORING]
SYS  CPU Usage : 1.7%
SYS  MEM Usage : 37.8%
PROC CPU (avg) : 0.5%   (PID 2738539)
PROC RSS       : 242.7 MB (PID 2738539)
DISK Used      : 9%
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L39-57 / L59-77 (§1 은 전체 88블록 중 구간 경계 6블록 발췌)

27초 사이에 `PROC RSS` 는 **42.7 MB → 242.7 MB** 로 200 MB 늘었는데 `SYS MEM` 은 **37.5% → 37.8%** 로 0.3%p 밖에 움직이지 않았다.

### 2-2. `monitor.sh` 가 append 한 관제 라인 (Before 구간 전량)

한 줄 포맷: `[TS] PID:n SYS_CPU:x% SYS_MEM:y% PROC_CPU:z% PROC_RSS:wMB DISK_USED:d%`

```text
[2026-08-26 09:02:38] PID:2738539 SYS_CPU:1.7% SYS_MEM:37.5% PROC_CPU:2.2% PROC_RSS:42.7MB DISK_USED:9%
[2026-08-26 09:02:42] PID:2738539 SYS_CPU:1.7% SYS_MEM:37.5% PROC_CPU:1.0% PROC_RSS:67.7MB DISK_USED:9%
[2026-08-26 09:02:45] PID:2738539 SYS_CPU:1.1% SYS_MEM:37.5% PROC_CPU:0.8% PROC_RSS:92.7MB DISK_USED:9%
[2026-08-26 09:02:48] PID:2738539 SYS_CPU:1.1% SYS_MEM:37.6% PROC_CPU:0.7% PROC_RSS:117.7MB DISK_USED:9%
[2026-08-26 09:02:52] PID:2738539 SYS_CPU:1.7% SYS_MEM:37.6% PROC_CPU:0.6% PROC_RSS:142.7MB DISK_USED:9%
[2026-08-26 09:02:55] PID:2738539 SYS_CPU:2.3% SYS_MEM:37.7% PROC_CPU:0.5% PROC_RSS:167.7MB DISK_USED:9%
[2026-08-26 09:02:58] PID:2738539 SYS_CPU:1.7% SYS_MEM:37.7% PROC_CPU:0.5% PROC_RSS:192.7MB DISK_USED:9%
[2026-08-26 09:03:02] PID:2738539 SYS_CPU:1.7% SYS_MEM:37.7% PROC_CPU:0.5% PROC_RSS:217.7MB DISK_USED:9%
[2026-08-26 09:03:05] PID:2738539 SYS_CPU:1.7% SYS_MEM:37.8% PROC_CPU:0.5% PROC_RSS:242.7MB DISK_USED:9%
[2026-08-26 09:03:08] PID:2738539 SYS_CPU:2.3% SYS_MEM:37.5% PROC_CPU:0.0% PROC_RSS:0.0MB DISK_USED:9%
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L155-164 (§2, Before 구간 전량)

파이프라인이 같은 계산식으로 3초 간격 샘플링한 고해상도 계열은 시작점(17.7 MB)까지 잡았다.

```text
[2026-08-26 09:02:37] PID:2738539 SYS_CPU:1.7% SYS_MEM:37.4% PROC_CPU:3.2% PROC_RSS:17.7MB DISK_USED:9%
...
[2026-08-26 09:03:07] PID:2738539 SYS_CPU:1.1% SYS_MEM:37.8% PROC_CPU:0.5% PROC_RSS:267.7MB DISK_USED:9%
[2026-08-26 09:03:11] [ERROR] Application process not running. (PID 2738539 종료)
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L227(17.7MB) · L236(267.7MB) · L237(프로세스 소멸)

**핵심 수치 (B1-2-E-OOM1 / B1-2-A1)**

| 지표 | 09:02:37 | 09:03:07 | 30초 변화 |
| ---- | -------- | -------- | --------- |
| `PROC_RSS` (대상 프로세스) | **17.7 MB** | **267.7 MB** | **+250.0 MB** (3초당 약 25 MB, 단조 증가) |
| `SYS_MEM` (호스트 전체) | 37.4% | 37.8% | +0.4%p (사실상 불변) |

즉 **같은 구간을 시스템 지표로 보면 아무 일도 일어나지 않은 것처럼 보인다.** 프로세스 단위 지표가 없으면 이 장애는 관제로 잡히지 않는다.

마지막 줄의 `PROC_RSS:0.0MB` 는 누수가 회수된 것이 아니라, 워커(자식) 프로세스가 소멸해 `ps` 가 값을 주지 못한 상태다. 이후 `monitor.sh` 는 Health Check 에서 걸린다.

```text
$ AGENT_LOG_DIR=/home/ashofrondol/b12_sandbox/logs bash src/monitor.sh        # 2026-08-26 09:07:20
[HEALTH CHECK]
Checking process 'agent-leak-app'... [FAIL]
[ERROR] Application process not running.
(monitor.sh exit=1)
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L140-147

### 2-3. `agent-leak-app` 실행 로그 (종료 직전/직후)

```text
2026-08-26 09:02:38,918 [INFO] [MemoryWorker] Current Heap: 25MB
2026-08-26 09:02:41,939 [INFO] [MemoryWorker] Current Heap: 50MB
2026-08-26 09:02:44,965 [INFO] [MemoryWorker] Current Heap: 75MB
...
2026-08-26 09:03:03,108 [INFO] [MemoryWorker] Current Heap: 225MB
2026-08-26 09:03:06,135 [INFO] [MemoryWorker] Current Heap: 250MB
2026-08-26 09:03:09,155 [INFO] [MemoryWorker] Current Heap: 275MB
2026-08-26 09:03:09,155 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-08-26 09:03:09,155 [CRITICAL] [MemoryGuard] Self-terminating process 2738539 to prevent system instability.
```

> 원본: [../evidence/oom_app.log](../evidence/oom_app.log) L63-75 (같은 계열이 L79-91 에도 기록됨)

- 앱 자기보고 heap 은 3초마다 정확히 **+25 MB**. `PROC_RSS` 의 3초당 +25 MB 와 일치한다.
- 임계 판정은 `275MB >= 256MB` — 즉 **한도를 넘긴 첫 샘플에서** 즉시 종료한다. 250MB 샘플에서는 아직 살아 있었다.
- `Self-terminating process 2738539` 의 PID 는 `monitor.sh` 가 관측한 PID 와 같다(부모 부트로더가 아니라 실제 워커 프로세스).

부트 시퀀스 전량 — 실행 사전 조건(B1-2-P1~P11) 이 모두 통과했음을 보여준다.

```text
>>> Starting Agent Boot Sequence...
[1/6] Checking User Account               [OK]
   ... Running as service user 'ashofrondol' (uid=1000)
[2/6] Verifying Environment Variables     [OK]
[3/6] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/6] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/6] Verifying Log Permission            [OK]
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=256MB, CPU_MAX_OCCUPY=10%, MULTI_THREAD_ENABLE=False
------------------------------------------------------------
All Boot Checks Passed!
Agent READY

 [ MEMORY ] Limit: 256MB 		[ WARNING: Recommend Over 256MB ]
 [ CPU    ] Limit: 10%  		[ OK ]
 [ THREAD ] Concurrency: False 		[ OK ]
```

> 원본: [../evidence/oom_app.log](../evidence/oom_app.log) L34-58

### 2-4. `ps` / `top` 출력

```text
##### 09:02:38  ps -o pid,ppid,rss,vsz,pcpu,stat,etime,cmd -p 2738539 #####
    PID    PPID   RSS    VSZ %CPU STAT     ELAPSED CMD
2738539 2738533 18088  23084  3.2 SN         00:01 ./agent-leak-app

##### 09:03:04  ps -o pid,ppid,rss,vsz,pcpu,stat,etime,cmd -p 2738539 #####
    PID    PPID   RSS    VSZ %CPU STAT     ELAPSED CMD
2738539 2738533 248524 253520 0.5 SN         00:27 ./agent-leak-app

##### 09:03:04  top -bn1 -p 2738539 #####
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2738539 ashofro+  30  10  253520 248524   9764 S   0.0   0.4   0:00.15 agent-l+

##### 09:03:11  ps -p 2738539  (종료 직후) #####
    PID TT           TIME CMD
# (헤더만 보이면 프로세스 종료됨)
```

> 원본: [../evidence/oom_ps_top.txt](../evidence/oom_ps_top.txt) L39-41 · L67-79 · L81-83

- `RSS 18088 → 248524 kB`, `VSZ 23084 → 253520 kB`. RSS 와 VSZ 가 나란히 증가 = **새로 할당한 익명 페이지에 실제로 쓰고 있다**(할당만 하고 안 쓰면 RSS 는 오르지 않는다).
- `%MEM 0.4` — 62 GiB 호스트 기준으로는 0.4% 에 불과하다. 이 값이 96% 로 보이려면 총 RAM 이 260 MB 여야 하므로, 호스트 `%MEM` 은 이 장애의 지표가 될 수 없다.
- `TIME+ 0:00.15` — CPU 는 거의 쓰지 않았다. **연산 폭주가 아니라 메모리 누수**임을 뒷받침한다.

`/proc/<pid>/smaps_rollup` 으로 "무엇이 늘었는지"까지 확인했다.

```text
##### t≈5s  2026-08-26 09:23:24 #####
Rss:               43688 kB
Private_Dirty:     33992 kB
2026-08-26 09:23:21,379 [INFO] [MemoryWorker] Current Heap: 25MB

##### t≈15s  2026-08-26 09:23:34 #####
Rss:              146104 kB
Private_Dirty:    136344 kB
2026-08-26 09:23:33,479 [INFO] [MemoryWorker] Current Heap: 125MB

##### t≈27s  2026-08-26 09:23:46 #####
Rss:              248520 kB
Private_Dirty:    238760 kB
2026-08-26 09:23:45,566 [INFO] [MemoryWorker] Current Heap: 225MB
```
(각 블록의 `Pss` 계열 라인과 `$ ps` / `$ free` 출력은 지면상 생략 — 원본 참조)

> 원본: [../evidence/oom_ps_top.txt](../evidence/oom_ps_top.txt) L299-348 (§3 보강 캡처, 같은 Before 조합 재실행)

증가분이 전부 **`Private_Dirty`(익명·수정된 사유 페이지)** 다. 파일 매핑(`Pss_File` 7098 kB)은 그대로다 → 공유 라이브러리나 파일 캐시가 아니라 **힙에 올린 객체가 회수되지 않고 쌓인 것**이다. 앱 자기보고 heap(25 / 125 / 225 MB)과 `Private_Dirty` 증가분이 그대로 대응한다.

같은 시각 호스트 전체 RSS 상위는 이 프로세스가 아니다 — 시스템 압박이 아니라 **이 프로세스 단독 문제**임을 보여준다.

```text
$ ps -eo pid,rss,pmem,comm --sort=-rss | head -8
    PID   RSS %MEM COMMAND
2363945 19539584 29.9 java
2472117 697788  1.0 claude
2534710 557024  0.8 claude
```

> 원본: [../evidence/oom_ps_top.txt](../evidence/oom_ps_top.txt) L353-362

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 현상 → 원인 매핑

| 관측 사실 | 근거 | 추론되는 원인 |
| --------- | ---- | ------------- |
| `PROC_CPU` 0.5~3.2%, `TIME+` 0:00.15 로 평탄한데 `PROC_RSS` 만 단조 증가 | oom_monitor.log L227-236 / oom_ps_top.txt L79 | 계산 폭주가 아닌 **메모리 누수**(Memory Leak) |
| 증가분이 전부 `Private_Dirty` 익명 페이지 | oom_ps_top.txt L310·L328·L346 | 워커가 만든 객체를 해제하지 않고 힙에 누적 |
| 3초마다 정확히 +25 MB (앱 heap·RSS 동시) | oom_app.log L63-73 | 주기적 워커 루프가 고정량을 할당하고 참조를 놓지 않음 |
| 커널 OOM Killer 가 아니라 앱 로그로 종료 | oom_app.log L74-75 | **앱 내장 `MemoryGuard`** 의 자가 종료 |
| `SYS_MEM` 은 37.4→37.8% 로 무변화 | oom_monitor.log L227·L236 | 호스트 자원은 여유. **정책 위반**이지 자원 고갈이 아니다 |

### 3-2. 운영체제 동작 원리

- 프로세스 메모리는 코드(Text) / 데이터 / 힙(Heap) / 스택으로 나뉜다. `malloc`/`list.append` 등으로 힙에 올린 객체는 참조가 남아 있는 한 GC 대상이 아니며, 한 번 물리 페이지로 실체화되면 **RSS(Resident Set Size)** 로 계상되고 회수되지 않는다.
- `ps` 의 `RSS` 는 "이 프로세스에 실제로 매핑된 물리 페이지"다. `smaps_rollup` 의 `Private_Dirty` 는 그중에서도 **공유되지 않고 수정된** 페이지 — 즉 순수하게 이 프로세스가 붙잡고 있는 양이다. 누수 진단의 1차 지표가 이것이다.
- `free` 기반 시스템 메모리는 **호스트 전체**의 합이다. 62 GiB 중 250 MB 는 0.4%p 에 지나지 않아, 프로세스 단위 누수는 시스템 지표에서 노이즈에 묻힌다. 그래서 관제는 `SYS_*` 와 `PROC_*` 를 **함께** 남겨야 한다.
- 누수가 계속되면 결국 커널의 **OOM Killer** 가 개입하지만, 본 앱은 그 전에 스스로 `heap >= MEMORY_LIMIT` 를 감시해 **시스템 전체를 보호할 목적으로** self-terminate 한다. 관측된 종료 코드 137 은 `128 + 9(SIGKILL)` 다. 외부에서 이 프로세스를 kill 한 주체는 없었고 호스트 메모리도 여유였으므로 커널 OOM Killer 의 조건이 아니며, 종료 직전 앱이 스스로 `Self-terminating process …` 로그를 남겼다 — 따라서 **앱이 자기 종료 경로에서 SIGKILL 을 탔다**고 읽는 것이 관측과 가장 잘 맞는다. (`dmesg` 확인은 이번 수집에서 수행하지 않았다.)

### 3-3. 결론

> 워커(`MemoryWorker`)가 3초마다 25 MB 씩 할당한 익명 페이지를 해제하지 않아 `PROC_RSS` 가 17.7 MB → 267.7 MB 로 30초간 단조 증가했고, 앱 자기보고 heap 이 275 MB 로 `MEMORY_LIMIT=256` 을 넘긴 첫 샘플에서 **MemoryGuard 정책이 발동**해 프로세스가 강제 종료(exit 137)되었다. 호스트 메모리는 시종 여유였으므로 이는 **자원 고갈이 아니라 정책 위반에 의한 종료**다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 — 임시: `MEMORY_LIMIT` 상향

```bash
# Before
export MEMORY_LIMIT=256 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false
# After (임시)
export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 MULTI_THREAD_ENABLE=false
```

> `CPU_MAX_OCCUPY` 는 양쪽 **10 으로 고정**했다. 이 앱은 부팅 시 Resource Check 결과로 시나리오를 하나 고르기 때문에, After 를 `MEMORY_LIMIT=512 + CPU_MAX_OCCUPY=95` 로 잡으면 메모리와 무관한 다른 워커가 프로세스를 죽여 비교 자체가 무효가 된다(4-3 참조).

### 4-2. Before & After 비교 (B1-2-E-OOM3 / B1-2-A3)

| 항목 | Before (`MEMORY_LIMIT=256`) | After (`MEMORY_LIMIT=512`) |
| ---- | --------------------------- | -------------------------- |
| 관측 구간 | 09:02:37 ~ 09:03:11 | 09:03:12 ~ 09:06:13 |
| 생존 시간 | **0m34s** | **>3m00s** (관측 상한까지 종료 없음) |
| 종료 코드 | **137** (128+9, SIGKILL) | 미종료 (`rc=2`, 관측 종료로 회수) |
| 종료 로그 | `[MemoryGuard] Memory limit exceeded (275MB >= 256MB)` + `Self-terminating process 2738539` | 해당 `[CRITICAL]` 라인 **0건** |
| 부트 배너 | `[ MEMORY ] Limit: 256MB [ WARNING: Recommend Over 256MB ]` | `[ MEMORY ] Limit: 512MB [ OK ]` |
| 선택된 시나리오 | 메모리 누수 (MemoryWorker 단독 가동) | `>>> Scenario Selected: [Healthy System Monitoring]` |
| `PROC_RSS` 궤적 | 17.7 → 267.7 MB **단조 증가 후 사망** | 17.7 → 518.0 MB → 리셋을 **2회 완주**하고 3주기째 진행 중 관측 종료 |

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L227-237(Before) · L239-294(After) / [../evidence/oom_app.log](../evidence/oom_app.log) L74-75(Before 종료 2줄) · L117-124(After 배너·시나리오) · L209-218(heap 리셋)

After 구간의 monitor.log 발췌 — 한도를 채운 뒤 **회수되고 다시 시작**한다.

```text
[2026-08-26 09:04:12] PID:2739609 SYS_CPU:1.7% SYS_MEM:38.4% PROC_CPU:0.7% PROC_RSS:518.0MB DISK_USED:9%
[2026-08-26 09:04:16] PID:2739609 SYS_CPU:1.1% SYS_MEM:37.7% PROC_CPU:0.7% PROC_RSS:17.9MB DISK_USED:9%
...
[2026-08-26 09:05:19] PID:2739609 SYS_CPU:2.8% SYS_MEM:38.3% PROC_CPU:0.7% PROC_RSS:518.0MB DISK_USED:9%
[2026-08-26 09:05:23] PID:2739609 SYS_CPU:1.1% SYS_MEM:37.6% PROC_CPU:0.7% PROC_RSS:67.9MB DISK_USED:9%
[2026-08-26 09:06:10] PID:2739609 SYS_CPU:0.6% SYS_MEM:38.1% PROC_CPU:0.7% PROC_RSS:393.0MB DISK_USED:9%
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L185-186 · L205-206 · L220 (§2 After 구간에서 발췌)

앱 로그에도 종료 대신 **회수** 가 찍힌다.

```text
2026-08-26 09:04:14,933 [INFO] [MemoryWorker] Current Heap: 525MB
2026-08-26 09:04:14,933 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-08-26 09:04:14,981 [INFO] [System] Memory Cache Flushed. Process Stabilized.

>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
```

> 원본: [../evidence/oom_app.log](../evidence/oom_app.log) L209-213 (같은 블록이 L269-273 에 한 번 더)

### 4-3. `MEMORY_LIMIT` 스윕 — 조치의 성격을 가르는 실측

한도만 바꾸고(다른 두 값은 고정) 값별 생존 시간을 잰 결과다.

```text
  MEMORY_LIMIT   생존시간   종료코드   종료 로그 / 관측
  ------------   --------   --------   -------------------------------------------------------
       100MB        13초      137      [MemoryGuard] Memory limit exceeded (100MB >= 100MB)
       256MB        34초      137      [MemoryGuard] Memory limit exceeded (275MB >= 256MB)
       512MB     >180초      (생존)    관측 상한까지 종료 없음. heap 이 25→525MB 를 순환하며
                                        MemoryGuard 가 한 번도 동작하지 않음
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L307-319 (§4 스윕표) · L337-360 (각 실행 원본 종료 요약)

두 가지를 알 수 있다.

1. **100 → 256 은 전형적인 임시 조치다.** 생존이 13초 → 34초로 2.6배 늘었을 뿐, 누수 속도(3초당 25 MB)는 그대로다. 한도를 채우는 데 걸리는 시간만 늘어난 것이다.
2. **512 는 "더 늦게 죽는" 값이 아니라 "이 장애가 재현되지 않는" 값이다.** 부트 배너가 `[ OK ]` 로 바뀌면서 앱이 누수 시나리오 자체를 선택하지 않고 `[Healthy System Monitoring]` 으로 들어간다. 따라서 After 구간의 "무사고"는 누수가 고쳐졌다는 뜻이 전혀 아니다.

**함정 — After 를 `MEMORY_LIMIT=512 + CPU_MAX_OCCUPY=95` 로 잡으면 안 되는 이유**

```text
  MEMORY_LIMIT   CPU_MAX_OCCUPY   생존시간   종료코드   실제로 죽인 주체
  ------------   --------------   --------   --------   ------------------------------------
       256MB           95%           34초      137      [MemoryGuard]  (메모리)
       512MB           95%           34초      143      [CpuWorker]    (메모리와 무관!)
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log) L321-330 · L361-367

생존 시간이 34초로 같아 "조치 효과 0" 처럼 보이지만, 실제로는 **사망 원인이 통째로 바뀐 것**이다(exit 137 = MemoryGuard/SIGKILL → exit 143 = CpuWorker/SIGTERM). 단일 변수 비교가 되도록 `src/experiments/01_oom.sh` 는 `CPU_MAX_OCCUPY` 를 양쪽 10 으로 고정한다.

### 4-4. 근본 해결을 위한 제안 (선택)

- 워커 로직에서 처리 완료된 작업 결과를 `del` / `pop` / `clear()` 처리하거나, `collections.deque(maxlen=...)` 로 상한을 강제
- 장시간 보관이 필요한 데이터는 디스크/외부 캐시(Redis 등)로 오프로드
- `tracemalloc`, `memray`, `objgraph` 등으로 누수 객체의 클래스·할당 스택 식별
- 관제 측: `PROC_RSS` 기울기(예: 3분 이동 평균 +50 MB 이상)에 경보를 걸어 **한도 도달 전에** 감지. `SYS_MEM` 임계만으로는 영원히 잡히지 않는다
- CI 에 메모리 회귀 가드 추가 (일정 시간 실행 후 RSS 상한 검사)

---

## 5. 첨부 / 참조

- [evidence/oom_monitor.log](../evidence/oom_monitor.log) — `monitor.sh` 콘솔 발췌 + 관제 라인 전량 + 3초 샘플 + `MEMORY_LIMIT` 스윕표
- [evidence/oom_app.log](../evidence/oom_app.log) — 부트 시퀀스, `MemoryWorker` heap 계열, `MemoryGuard` 종료 2줄, After 구간 전량
- [evidence/oom_ps_top.txt](../evidence/oom_ps_top.txt) — `ps` / `top` 12초 간격 스냅샷 + `smaps_rollup` 보강 캡처 + 시스템 전체 RSS 순위
