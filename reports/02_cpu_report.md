# [Bug] agent-leak-app CPU 과점유로 CpuWorker 보호 정책에 의한 종료 (exit 143 / SIGTERM)

> 라벨: `bug`, `priority/high`, `area/cpu`
> 담당: agent-dev
> 환경: Ubuntu 24.04.4 LTS / Linux 6.8.0-138-generic x86_64 / 16 vCPU / 62 GiB RAM, `ashofrondol`(uid=1000, root 아님) 계정
> 실험 환경변수: `CPU_MAX_OCCUPY=80` / `MEMORY_LIMIT=512` / `MULTI_THREAD_ENABLE=false`
> 측정 구간: 2026-08-26 09:07:40 ~ 09:11:14 (파이프라인 Before/After) · 08:48~08:56 (`CPU_MAX_OCCUPY` 스윕 probe) · 09:21:20~09:22:55 (`/proc` 델타·시스템 뷰 보강 캡처) (KST)

---

## 1. Description (현상 설명)

`agent-leak-app` 을 `CPU_MAX_OCCUPY=80` 으로 실행하면, 앱이 스스로 만들어 내는 부하(`[CpuWorker] Current Load`)가 **3초마다 계단식으로 상승**하다가 **약 30초 만에** 다음 한 줄을 남기고 프로세스가 종료된다.

```text
2026-08-26 09:08:11,284 [INFO] [CpuWorker] Current Load: 53.72%
2026-08-26 09:08:11,385 [CRITICAL] [CpuWorker] CPU Threshold Violated! (53.720000000000006%).
```

> 원본: [../evidence/cpu_app.log](../evidence/cpu_app.log) L77-78 (nohup stdout) — 같은 2줄이 `agent_app.log` L92-93 에도 기록된다.

- 발생 시각: 2026-08-26 **09:07:41 실행** → **09:08:12 프로세스 소멸**. 생존 **0m30s**, 종료 코드 **143**(= 128+15, SIGTERM).
- 재현성: `CPU_MAX_OCCUPY` 를 95 / 80 / 60 으로 바꿔 실행한 3회 모두 `CPU Threshold Violated!` + exit 143 으로 종료했다(생존 34초 / 30초 / 43초). 여기에 `/proc` 델타 측정용 재실행 2회를 더해 **동일 시그니처 5회 관측**. ([cpu_monitor.log](../evidence/cpu_monitor.log) L286-292, [cpu_top_ps.txt](../evidence/cpu_top_ps.txt) L341-343 · L387-389)
- 부트 시점에 앱이 이미 경고를 띄운다 — `[ CPU ] Limit: 80% [ WARNING: Recommend Under 50% ]` ([cpu_app.log](../evidence/cpu_app.log) L61). **이 "Under 50%" 가 뒤에서 결정적인 단서가 된다.**
- 메모리·디스크는 무변동이다. 같은 구간의 `PROC_RSS` 는 **17.7 MB 로 시종 고정**([cpu_monitor.log](../evidence/cpu_monitor.log) L134-142) — CPU 단독 문제다.

> **정정 (실측 확인)**: 과제 PDF 예시의 `WATCHDOG … INITIATING EMERGENCY ABORT (SIGTERM)` 문자열은 **이 바이너리가 출력하지 않는다.** 이번 수집분(`evidence/cpu_app.log` 497줄)에 `WATCHDOG` / `EMERGENCY ABORT` 는 0건이다. 보호 종료의 근거는 위 `[CRITICAL] [CpuWorker] CPU Threshold Violated!` 라인과 **종료 코드 143(SIGTERM 경로)** 이다.

---

## 2. Evidence & Logs (증거 자료)

### 2-0. 읽기 전 — "CPU 사용률" 이라는 말의 세 층위

이 케이스는 **어떤 CPU 수치를 보느냐에 따라 결론이 달라진다.** 이번 수집에서는 세 가지를 모두 재서 나란히 남겼다.

| 층위 | 측정 방법 | 이번 실측에서 본 것 |
| ---- | --------- | ------------------- |
| ① 앱 자기보고 부하 | 앱이 로그에 찍는 `[CpuWorker] Current Load: NN%` | 5.00% → 53.72% 로 3초마다 계단식 상승. **종료를 결정하는 값은 이것** |
| ② OS 가 본 이 프로세스 | `/proc/<pid>/stat` 의 `utime+stime` 1초 델타 | 같은 방향으로 단조 증가하나 **최대 5%(1코어 기준)** 로 훨씬 작다 |
| ③ 호스트 전체 | `top -b -n 2` / `/proc/loadavg` | 대응하는 상승 구간 **없음**. load average 0.23→0.28 |

`monitor.sh` 의 `PROC_CPU` 는 `ps -o pcpu=` 값이라 **프로세스 시작 이후 누적 평균**이다. 30초짜리 스파이크는 원리상 여기 안 잡힌다. 그래서 ②를 별도로 측정했다.

### 2-1. `monitor.sh` 관제 로그

```text
### ----- Before 구간 시작 — 첫 정상 수집 -----
$ AGENT_LOG_DIR=/home/ashofrondol/b12_sandbox/logs bash src/monitor.sh        # 2026-08-26 09:07:43
[HEALTH CHECK]
Checking process 'agent-leak-app'... [OK] (PID: 2747669)
Checking port 15034... [OK]

[RESOURCE MONITORING]
SYS  CPU Usage : 2.8%
SYS  MEM Usage : 37.6%
PROC CPU (avg) : 2.2%   (PID 2747669)
PROC RSS       : 17.7 MB (PID 2747669)
DISK Used      : 9%

### ----- Before 마지막 정상 수집 — [CpuWorker] 임계 위반 자가종료 직전 -----
$ AGENT_LOG_DIR=/home/ashofrondol/b12_sandbox/logs bash src/monitor.sh        # 2026-08-26 09:08:09
[RESOURCE MONITORING]
SYS  CPU Usage : 1.7%
SYS  MEM Usage : 37.6%
PROC CPU (avg) : 0.9%   (PID 2747669)
PROC RSS       : 17.7 MB (PID 2747669)
DISK Used      : 9%
```

> 원본: [../evidence/cpu_monitor.log](../evidence/cpu_monitor.log) L39-57 / L59-77 (§1 은 전체 90블록 중 구간 경계 5블록 발췌)

관제 라인 전량(Before 구간):

```text
[2026-08-26 09:07:43] PID:2747669 SYS_CPU:2.8% SYS_MEM:37.6% PROC_CPU:2.2% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:07:46] PID:2747669 SYS_CPU:1.7% SYS_MEM:37.6% PROC_CPU:1.0% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:07:49] PID:2747669 SYS_CPU:2.3% SYS_MEM:37.6% PROC_CPU:0.7% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:07:53] PID:2747669 SYS_CPU:1.1% SYS_MEM:37.6% PROC_CPU:0.7% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:07:56] PID:2747669 SYS_CPU:2.3% SYS_MEM:37.6% PROC_CPU:0.7% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:07:59] PID:2747669 SYS_CPU:7.4% SYS_MEM:37.6% PROC_CPU:0.7% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:08:03] PID:2747669 SYS_CPU:2.8% SYS_MEM:37.6% PROC_CPU:0.8% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:08:06] PID:2747669 SYS_CPU:1.7% SYS_MEM:37.6% PROC_CPU:0.8% PROC_RSS:17.7MB DISK_USED:9%
[2026-08-26 09:08:09] PID:2747669 SYS_CPU:1.7% SYS_MEM:37.6% PROC_CPU:0.9% PROC_RSS:17.7MB DISK_USED:9%
```

> 원본: [../evidence/cpu_monitor.log](../evidence/cpu_monitor.log) L134-142

**이 표가 말해 주는 것을 있는 그대로 적는다.**

- `PROC_RSS` 가 17.7 MB 로 완전히 고정 → 메모리 누수 케이스와 명확히 구분된다.
- `PROC_CPU`(누적 평균)는 0.7% → 0.9% 로 **미세하게만** 오른다. 부트 직후 2.2% 는 기동 비용이 평균에 섞인 값이라 오히려 더 높다. **1분 주기 cron 관제만으로는 이 장애를 CPU 지표로 잡을 수 없다** — 프로세스가 30초 만에 죽기 때문이다. 관제에서 실제로 보이는 신호는 "다음 수집에서 프로세스가 사라짐"이다.
- `SYS_CPU` 도 1.1~7.4% 범위에서 흔들릴 뿐 추세가 없다.

### 2-2. `agent-leak-app` 실행 로그 — 상승 계열과 보호 종료

```text
2026-08-26 09:07:43,264 [INFO] [CpuWorker] Started. Maximum CPU Limit: 80%
2026-08-26 09:07:43,265 [INFO] [CpuWorker] Current Load: 5.00%
2026-08-26 09:07:46,380 [INFO] [CpuWorker] Current Load: 8.98%
2026-08-26 09:07:49,492 [INFO] [CpuWorker] Current Load: 15.43%
2026-08-26 09:07:52,605 [INFO] [CpuWorker] Current Load: 16.92%
2026-08-26 09:07:55,721 [INFO] [CpuWorker] Current Load: 23.10%
2026-08-26 09:07:58,836 [INFO] [CpuWorker] Current Load: 32.79%
2026-08-26 09:08:01,946 [INFO] [CpuWorker] Current Load: 35.99%
2026-08-26 09:08:05,062 [INFO] [CpuWorker] Current Load: 44.76%
2026-08-26 09:08:08,173 [INFO] [CpuWorker] Current Load: 47.33%
2026-08-26 09:08:11,284 [INFO] [CpuWorker] Current Load: 53.72%
2026-08-26 09:08:11,385 [CRITICAL] [CpuWorker] CPU Threshold Violated! (53.720000000000006%).
```

> 원본: [../evidence/cpu_app.log](../evidence/cpu_app.log) L67-78 (같은 계열이 L82-93 에도 기록됨)

- 3초 간격으로 9회 상승해 **10번째 샘플에서 종료**. `CPU_MAX_OCCUPY=80` 인데 **80% 근처에는 가 보지도 못하고** 53.72% 에서 끊겼다.
- `CRITICAL` 라인 시각은 `Current Load` 라인보다 **101 ms 뒤**다. 즉 값을 찍고 곧바로 임계 판정이 돌았다.
- 이 라인 이후 로그는 없다. 프로세스는 09:08:12 에 소멸했고 종료 코드는 143 이다([cpu_monitor.log](../evidence/cpu_monitor.log) L289 · L303-304 — 스윕표의 `80%` 행이 곧 이 파이프라인 Before 구간이다).

### 2-3. `top` / `ps` 출력 — OS 가 본 이 프로세스

```text
##### 09:07:42  ps -o pid,ppid,rss,vsz,pcpu,stat,etime,cmd -p 2747669 #####
    PID    PPID   RSS    VSZ %CPU STAT     ELAPSED CMD
2747669 2747663 18084  23084  3.1 SN         00:01 ./agent-leak-app

##### 09:07:42  top -bn1 -p 2747669 #####
top - 09:07:42 up 3 days, 16:18,  4 users,  load average: 0.23, 0.51, 0.75
%Cpu(s):  0.0 us,  0.6 sy,  0.0 ni, 99.4 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2747669 ashofro+  30  10   23084  18084   9764 S   0.0   0.0   0:00.04 agent-l+

##### 09:08:09  ps -o pid,ppid,rss,vsz,pcpu,stat,etime,cmd -p 2747669 #####
    PID    PPID   RSS    VSZ %CPU STAT     ELAPSED CMD
2747669 2747663 18148  24108  1.0 SN         00:27 ./agent-leak-app

##### 09:08:09  top -bn1 -p 2747669 #####
top - 09:08:09 up 3 days, 16:18,  4 users,  load average: 0.28, 0.49, 0.73
%Cpu(s):  1.2 us,  0.6 sy,  0.0 ni, 98.1 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2747669 ashofro+  30  10   24108  18148   9764 S   0.0   0.0   0:00.28 agent-l+

##### 09:08:12  ps -p 2747669  (종료 직후) #####
    PID TT           TIME CMD
# (헤더만 보이면 프로세스 종료됨)
```

> 원본: [../evidence/cpu_top_ps.txt](../evidence/cpu_top_ps.txt) L43-55 · L71-87

**여기서 관측된 사실을 축소하거나 부풀리지 않고 적는다.**

- `TIME+` 는 27초 동안 **0:00.04 → 0:00.28**, 즉 실제 소모 CPU 시간은 **0.24초**다. 프로세스 상태(`STAT`)도 내내 `S`(Sleeping) 이고 `R`(Running) 로 관측된 스냅샷은 없다. **"한 코어를 90% 넘게 점유하는 busy-loop" 은 관측되지 않았다.**
- `load average` 는 0.23 → 0.28 로 사실상 무변화, `%Cpu(s)` 의 idle 도 99.4% → 98.1% 에 머문다. 16 vCPU 호스트에서 이 프로세스는 무시할 만한 부하다.
- `NI 10 / PR 30` — 앱이 부팅 시 스스로 `[SafetyGuard] Process priority lowered (nice=10)` 을 수행한다([cpu_app.log](../evidence/cpu_app.log) L54).

즉 **종료를 유발한 "CPU 급상승" 은 OS 지표가 아니라 앱 내부 회계(`Current Load`)에서 일어난 사건**이다. 이 구분이 이 케이스의 핵심이다.

### 2-4. `/proc/<pid>/stat` 1초 델타 — 프로세스 CPU 가 실제로 오르는가 (B1-2-E-CPU1 / B1-2-A4)

`ps %CPU` 가 누적 평균이라 스파이크를 못 잡으므로, `utime+stime`(jiffies) 을 1초 간격으로 직접 델타 계산했다. `CLK_TCK=100`.

```text
TIME       PROC_%CPU HOST_%CPU utime+stime RSS(MB)   앱이_스스로_보고한_[CpuWorker]_Current_Load
--------   --------- --------- ----------- -------   -------------------------------------------
09:21:21   0.0%      1.8%      4           17        -
09:21:22   1.0%      4.1%      5           17        Current Load: 5.00%
09:21:26   1.0%      1.6%      6           17        Current Load: 9.91%
09:21:29   2.0%      8.7%      8           17        Current Load: 19.90%
09:21:32   3.0%      1.1%      11          17        Current Load: 26.19%
09:21:35   3.0%      1.2%      14          17        Current Load: 34.10%
09:21:38   3.0%      5.8%      17          17        Current Load: 34.47%
09:21:41   4.0%      9.8%      21          17        Current Load: 36.25%
09:21:45   3.0%      2.2%      25          17        Current Load: 37.57%
09:21:48   4.0%      2.2%      29          17        Current Load: 43.91%
09:21:51   5.0%      2.0%      34          17        Current Load: 49.08%

$ (프로세스 종료 직후) tail -3 $AGENT_LOG_DIR/agent_app.log
2026-08-26 09:21:53,663 [INFO] [CpuWorker] Current Load: 53.27%
2026-08-26 09:21:53,764 [CRITICAL] [CpuWorker] CPU Threshold Violated! (53.269999999999996%).
```

> 원본: [../evidence/cpu_top_ps.txt](../evidence/cpu_top_ps.txt) L303-343 (§2, 32행 전량 중 부하 발생 초만 발췌)

읽는 법:

- 워커는 3초 주기로 **한 번에 몰아서** CPU 를 쓴다. 그래서 델타는 3초에 한 번만 0 이 아니고, 그 값이 **1 → 5 jiffies 로 단조 증가**한다. 방향은 앱 자기보고 `Current Load` 와 정확히 일치한다.
- 절대값은 **최대 5%(1코어 기준)** 로, 앱이 보고하는 49.08% 와 한 자릿수 배 차이가 난다. 앱의 `Current Load` 는 OS 사용률이 아니라 **앱이 자체 계산해 보고하는 값**이다.
- 같은 시각 `HOST_%CPU` 열에는 대응하는 상승 구간이 없다(1.1~9.8% 사이에서 무작위 진동). **부하가 이 프로세스에 국한된다**는 B1-2-A4 의 요구는 이 두 열의 대조로 충족된다.

호스트 전체 뷰로도 교차 확인했다.

```text
$ top -b -n 2 -d 1 -o %CPU | sed -n '/PID USER/,+8p' | tail -9        # 2회 샘플의 두 번째 = 진짜 순간값, 전체 시스템 상위 8
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2363945 ashofro+  20   0   26.6g  18.6g  42596 S  10.9  30.0 284:20.60 java
2534710 ashofro+  20   0 5609720 556868 135480 S   3.0   0.9  10:06.83 claude
 566936 root      20   0 2746056  94824  66720 S   2.0   0.1  27:03.41 promtail

$ ps -o pid,ppid,pcpu,rss,vsz,stat,nice,etime,cmd -p 2771411
    PID    PPID %CPU   RSS    VSZ STAT  NI     ELAPSED CMD
2771411 2771410  0.8 18212  24108 SN    10       00:26 ./agent-leak-app

$ cat /proc/loadavg
0.40 0.27 0.43 1/1273 2772248
```

> 원본: [../evidence/cpu_top_ps.txt](../evidence/cpu_top_ps.txt) L349-379

이 측정 호스트에는 `java`(누적 %CPU 48.1) · `grafana` · `loki` 등 상시 서비스가 돌고 있어 호스트 전체에는 항상 배경 부하가 있다. 그럼에도 `agent-leak-app` 은 상위 목록에 들어가지 않으며 `%CPU 0.8` 이다. **호스트 전체 부하와 이 프로세스의 사건은 무관하다.**

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 현상 → 원인 매핑

| 관측 사실 | 근거 | 추론되는 원인 |
| --------- | ---- | ------------- |
| `PROC_RSS` 17.7 MB 고정, `Current Load` 만 상승 | cpu_monitor.log L134-142 | 메모리가 아닌 **CPU 워크로드 계열의 문제** |
| `Current Load` 가 3초마다 계단식으로 증가, 감소 구간 없음 | cpu_app.log L67-77 | 워커가 **부하를 스스로 계속 올리도록** 설계됨(감쇠·양보 없음) |
| `CPU_MAX_OCCUPY=80` 인데 53.72% 에서 종료 | cpu_app.log L77-78 | 종료를 결정하는 선이 `CPU_MAX_OCCUPY` **가 아니다** |
| 95/80/60 세 값의 트립 지점이 58.93 / 53.72 / 57.39% | cpu_monitor.log L286-292 | 트립 라인은 **고정 50%** (부트 배너의 `Recommend Under 50%`) |
| 종료 코드 143, `[CRITICAL] [CpuWorker]` 라인 존재 | cpu_monitor.log L289 / cpu_app.log L78 | 오류·크래시가 아니라 **앱 내장 감시 로직의 보호 종료(SIGTERM 경로)** |
| `TIME+` 0.24초, load average 무변화 | cpu_top_ps.txt L55·L83 | 호스트를 실제로 압박한 사실은 **없다** — 정책 위반에 의한 선제 차단 |

### 3-2. 왜 "80% 임계"가 아니라 "50% 선"인가 — 근거

부트 배너가 값에 따라 두 가지로 갈린다. Before 구간:

```text
 [ CPU    ] Limit: 80%  		[ WARNING: Recommend Under 50% ]
```

> 원본: [../evidence/cpu_app.log](../evidence/cpu_app.log) L61

After 구간:

```text
 [ CPU    ] Limit: 10%  		[ OK ]
```

> 원본: [../evidence/cpu_app.log](../evidence/cpu_app.log) L120

그리고 `CPU_MAX_OCCUPY` 를 바꿔가며 실측한 트립 지점이 **설정값과 무관하게 전부 50% 직후**였다(4-3 스윕표). 이 두 사실을 합치면, 이 바이너리는

- `CPU_MAX_OCCUPY` 를 **CpuWorker 가 목표로 삼는 부하 상한**으로 쓰고,
- 프로세스를 죽이는 **보호 임계선은 별도로 50% 에 고정**해 두었으며,
- 부트 배너의 `Recommend Under 50%` 가 바로 그 선을 사용자에게 알려 주는 문구

라고 읽는 것이 관측과 가장 잘 맞는다. `CPU_MAX_OCCUPY > 50` 으로 두면 워커는 50% 를 넘겨 부하를 올리도록 지시받은 셈이 되고, 넘기는 순간 보호 로직이 프로세스를 끝낸다.

> 한계: 바이너리 내부 구현은 리버스 엔지니어링 금지(B1-2-C2) 대상이라 확인하지 않았다. 위 서술은 **외부 관측(배너 문구 + `CPU_MAX_OCCUPY` 5개 값의 스윕 결과와 그중 3개 사망 케이스의 트립 지점)만으로 세운 추론**이다.

### 3-3. 운영체제 동작 원리

- 리눅스 스케줄러(CFS)는 `R`(Runnable) 상태 태스크에 vruntime 기준으로 시간을 배분한다. CPU 바운드 태스크가 오래 점유하면 다른 태스크의 지연이 커지고 `load average` 가 오른다 — 이번 케이스에서는 **그 단계에 도달하기 전에** 앱이 스스로 멈췄다.
- `ps`/`top` 의 프로세스 `%CPU` 는 "1 코어 = 100%" 로 정규화된 값이며, `ps` 는 **프로세스 수명 전체의 누적 평균**을, `top -bn1` 의 첫 샘플도 마찬가지로 누적값을 준다. 짧은 스파이크를 보려면 `/proc/<pid>/stat` 의 `utime+stime` 을 두 시점 델타로 계산하거나 `top -b -n 2` 의 두 번째 샘플을 써야 한다. 이번 §2 측정이 전자다.
- 종료 코드 **143 = 128 + 15(SIGTERM)** 이다. SIGKILL(9→137)과 달리 SIGTERM 은 핸들러 등록이 가능한 "정중한" 종료 요청이므로, 앱이 정리 절차를 밟을 여지를 남긴 **의도된 보호 조치**로 해석된다. 실제로 OOM 케이스의 종료 코드는 137 로 서로 다르다.
- 앱은 부팅 시 `nice=10` 으로 자기 우선순위를 낮춘다(`[SafetyGuard] Process priority lowered`). 이 역시 호스트 보호 장치이며, 그 덕분에 부하가 올라가도 호스트 응답성에는 영향이 거의 없었다.

### 3-4. 결론

> `CpuWorker` 가 3초 주기로 자기 부하 목표를 계속 끌어올렸고(5.00% → 53.72%, 감쇠 구간 없음), 앱 내장 보호 임계선인 **50%** 를 넘긴 첫 샘플에서 `CPU Threshold Violated!` 를 기록하며 프로세스가 SIGTERM 경로로 종료(exit 143)되었다. 이는 오류가 아니라 **의도된 보호 조치**다(B1-2-A5). 다만 OS 관점에서 실제로 소모된 CPU 는 27초간 0.24초에 불과했고 호스트 부하 증가도 없었으므로, **"시스템을 실제로 마비시킨 폭주" 가 아니라 "앱이 스스로 정한 정책선을 넘어 선제 차단된 것"** 이다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 — 임시: `CPU_MAX_OCCUPY` **하향**

```bash
# Before
export CPU_MAX_OCCUPY=80 MEMORY_LIMIT=512 MULTI_THREAD_ENABLE=false
# After (임시)
export CPU_MAX_OCCUPY=10 MEMORY_LIMIT=512 MULTI_THREAD_ENABLE=false
```

> **조치 방향 정정**: 임계값을 **올리는**(80 → 95) 조치는 실측상 효과가 0 이다. 종료를 결정하는 선이 `CPU_MAX_OCCUPY` 가 아니라 고정 50% 이기 때문에, 80 이든 95 든 워커는 똑같이 50% 를 넘겨 똑같이 죽는다(생존 30초 vs 34초). 효과가 있는 방향은 **내리는 것**이다.

### 4-2. Before & After 비교 (B1-2-E-CPU3 / B1-2-A6)

| 항목 | Before (`CPU_MAX_OCCUPY=80`) | After (`CPU_MAX_OCCUPY=10`) |
| ---- | ---------------------------- | --------------------------- |
| 관측 구간 | 09:07:42 ~ 09:08:12 | 09:08:13 ~ 09:11:14 |
| 생존 시간 | **0m30s** | **>3m00s** (관측 상한까지 종료 없음) |
| 종료 코드 | **143** (128+15, SIGTERM) | 미종료 (`rc=2`, 관측 종료로 회수) |
| 마지막 `Current Load` | 53.72% (트립) | 10.00% (Peak 도달 후 냉각) |
| 종료 로그 | `[CRITICAL] [CpuWorker] CPU Threshold Violated! (53.72…%)` | 해당 `[CRITICAL]` 라인 **0건** |
| 부트 배너 | `[ CPU ] Limit: 80% [ WARNING: Recommend Under 50% ]` | `[ CPU ] Limit: 10% [ OK ]` |
| 선택된 시나리오 | CPU 과점유 (CpuWorker 단독 가동) | `>>> Scenario Selected: [Healthy System Monitoring]` |
| 부하 거동 | 5.00% → 53.72% 단조 상승 후 사망 | `Peak reached (10.00%) → Cooldown complete (5.00%)` **17회 순환** |

> 원본: [../evidence/cpu_app.log](../evidence/cpu_app.log) L67-78(Before) · L120·L126(After 배너·시나리오) / [../evidence/cpu_monitor.log](../evidence/cpu_monitor.log) L205-214(Before 샘플) · L216-271(After 샘플)

After 구간 앱 로그 — 상한에 닿으면 **스스로 되돌린다.**

```text
2026-08-26 09:08:15,594 [INFO] [CpuWorker] Started. Maximum CPU Limit: 10%
2026-08-26 09:08:15,594 [INFO] [CpuWorker] Current Load: 5.00%
2026-08-26 09:08:18,708 [INFO] [CpuWorker] Current Load: 8.58%
2026-08-26 09:08:21,818 [INFO] [CpuWorker] Current Load: 8.79%
2026-08-26 09:08:23,924 [INFO] [CpuWorker] Peak reached (10.00%). Starting cooldown...
2026-08-26 09:08:24,928 [INFO] [CpuWorker] Current Load: 10.00%
2026-08-26 09:08:27,039 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
2026-08-26 09:08:28,044 [INFO] [CpuWorker] Current Load: 5.00%
2026-08-26 09:08:30,155 [INFO] [CpuWorker] Peak reached (10.00%). Starting cooldown...
...
2026-08-26 09:11:12,015 [INFO] [CpuWorker] Peak reached (10.00%). Starting cooldown...
2026-08-26 09:11:13,021 [INFO] [CpuWorker] Current Load: 10.00%
```

> 원본: [../evidence/cpu_app.log](../evidence/cpu_app.log) L156-168 · L312-314 — 마지막 줄(09:11:13,021)이 관측 종료 시점이다. After 구간 전체에서 `Peak reached` / `Cooldown complete` 가 각각 17회. (파일에는 nohup stdout 과 agent_app.log 가 함께 실려 같은 이벤트가 두 번 보이므로, 고유 타임스탬프 기준으로 센 값이다.)

`Peak reached → Cooldown` 순환이 부하를 10% 상한 안에 묶어 두므로 **50% 선에 영영 닿지 않는다.** 그래서 종료 자체가 사라진다.

한편 After 구간의 `PROC_RSS` 는 17.7 MB → 518.0 MB 로 증가하다가 리셋된다([cpu_monitor.log](../evidence/cpu_monitor.log) L145-198). 이는 CPU 조치의 부작용이 아니라, 시나리오가 `[Healthy System Monitoring]` 으로 바뀌면서 `MemoryWorker` 가 함께 도는 정상 거동이다(`MEMORY_LIMIT=512` 이므로 525 MB 에서 캐시 플러시). CPU 케이스의 판정에는 영향이 없다.

### 4-3. `CPU_MAX_OCCUPY` 스윕 — 조치 방향을 뒤집은 실측

`MEMORY_LIMIT=512`, `MULTI_THREAD_ENABLE=false` 로 고정하고 `CPU_MAX_OCCUPY` 만 바꿨다.

```text
  CPU_MAX_OCCUPY   생존시간   종료코드   트립 시점의 [CpuWorker] Current Load   부팅 배너
  --------------   --------   --------   ------------------------------------   ------------------------
        95%          34초       143      58.93%                                 [ WARNING: Under 50% ]
        80%          30초       143      53.72%                                 [ WARNING: Under 50% ]
        60%          43초       143      57.39%                                 [ WARNING: Under 50% ]
        50%       >122초       (생존)    트립 없음 (Peak reached → cooldown 순환)  [ OK ]
        10%       >180초       (생존)    트립 없음 (Peak reached → cooldown 18회)  [ OK ]
```

> 원본: [../evidence/cpu_monitor.log](../evidence/cpu_monitor.log) L286-300 (§4 스윕표) · L306-336 (각 실행 원본 종료 요약)

- **상향은 효과가 없다.** 80 → 95 로 올려도 생존은 30초 → 34초로 사실상 같고, 종료 코드·종료 로그도 동일하다. 리포트 초판이 "95 로 올리면 약 12분까지 생존" 이라고 적었던 것은 실측과 맞지 않아 폐기한다.
- **트립 지점이 설정값을 따라가지 않는다.** 95 / 80 / 60 어느 쪽이든 종료는 53~59% 구간에서 일어난다. 종료선은 설정값이 아니라 고정 50% 라는 결론의 직접 증거다.
- **임계점은 50 과 60 사이다.** 50 이하로 내리면 부트 배너가 `[ OK ]` 로 바뀌고 CPU 과점유 시나리오 자체가 선택되지 않아 종료가 사라진다.
- 따라서 B1-2-A6 이 요구하는 "조정으로 종료 여부/생존 시간 변화 확인" 을 충족하는 조정은 **하향**이며, `src/experiments/02_cpu.sh` 의 After 를 95 → 10 으로 바꿨다.

### 4-4. 근본 해결을 위한 제안 (선택)

- 워커 루프에 **부하 상한과 감쇠(cooldown)를 강제**한다. 실제로 `CPU_MAX_OCCUPY<=50` 구간에서 앱이 보여 주는 `Peak reached → Cooldown` 거동이 그 형태다
- 반복 연산을 청크 단위로 쪼개고 사이에 `time.sleep(0)` / `await asyncio.sleep(0)` 으로 양보
- `cgroup v2` 의 `cpu.max` 로 프로세스 밖에서 상한을 강제(앱 정책과 무관하게 호스트를 보호)
- `taskset`/`cpuset` 으로 코어를 격리하고 `nice`/`renice` 로 우선순위 하향 (앱은 이미 `nice=10` 을 자체 적용)
- `py-spy record -p <pid>` 로 호출 스택 프로파일링 → 부하 발생 지점 식별
- 관제 측: `ps %CPU`(누적 평균) 대신 **`/proc/<pid>/stat` 델타 기반 순간 %CPU** 를 수집해야 짧은 스파이크가 보인다

---

## 5. 첨부 / 참조

- [evidence/cpu_monitor.log](../evidence/cpu_monitor.log) — `monitor.sh` 콘솔 발췌 + 관제 라인 전량 + 3초 샘플 + `CPU_MAX_OCCUPY` 스윕표
- [evidence/cpu_app.log](../evidence/cpu_app.log) — 부트 배너 대조, `Current Load` 상승 계열, `CPU Threshold Violated!`, After 의 `Peak reached / Cooldown` 순환
- [evidence/cpu_top_ps.txt](../evidence/cpu_top_ps.txt) — `ps`/`top` 스냅샷, `/proc/<pid>/stat` 1초 델타 측정표, 호스트 전체 상위 프로세스, 종료 직후 흔적
