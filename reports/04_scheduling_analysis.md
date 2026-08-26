# [Analysis] 로그 패턴 분석을 통한 agent-leak-app 스케줄링 알고리즘 추론

> 라벨: `analysis`, `bonus`, `area/scheduling`
> 담당: agent-dev
> 환경: Ubuntu 24.04.4 LTS / Linux 6.8.0-138-generic x86_64 / 16 vCPU / 62 GiB RAM, `ashofrondol`(uid=1000) 계정
> 대상: 정상 가동 중인 `agent-leak-app` — `MEMORY_LIMIT=512` / `CPU_MAX_OCCUPY=10` / `MULTI_THREAD_ENABLE=false`
> 측정 구간: 2026-08-26 09:18:09 ~ 09:20:15 (§1·§2) / 09:28:29 ~ 09:29:39 (스레드 보강 캡처) (KST)

---

## 1. 분석 개요

장애 분석 중 수집된 로그에서 **워커 간 실행 교체 패턴**이 일정한 규칙을 보이는 것을 확인했다. 본 리포트는 로그의 타임스탬프와 작업 진행률(Progress) 변화를 근거로 어떤 스케줄링 알고리즘이 적용되어 있는지 역추론한다.

후보:

- **FCFS (First-Come, First-Served)** — 먼저 도착한 작업을 끝까지 처리
- **Priority** — 우선순위가 높은 작업이 자원을 독점
- **Round-Robin** — 각 작업에 일정한 시간 할당량(Time Quantum)을 부여하고 끝나면 다음으로 교체

### 1-1. 수집 조건을 `MULTI_THREAD_ENABLE=false` 로 잡은 이유

이 앱은 부팅 시 Resource Check 결과로 시나리오를 하나 고른다. `[Scheduler]` 가 `Thread-A/B/C` 를 번갈아 돌리는 구간은 **세 값이 모두 안전할 때 선택되는 `[Healthy System Monitoring]` 시나리오에서만** 나온다.

```text
2026-08-26 09:18:11,331 [INFO] [Scheduler] Task Scheduler Initialized.
2026-08-26 09:18:11,331 [INFO] [Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
2026-08-26 09:18:11,331 [INFO] [Scheduler] Starting task execution...
```

> 원본: [../evidence/scheduling_workers.log](../evidence/scheduling_workers.log) L38-40

`MULTI_THREAD_ENABLE=true` 는 데드락 시나리오라 부팅 9초 만에 전 스레드가 멈춰([03_deadlock_report.md](./03_deadlock_report.md) 참조) 교체 패턴을 관측할 수 없다. 그래서 보너스 데이터는 정상 가동 조합으로 받았다.

---

## 2. 증거 자료

### 2-1. 정상 가동 구간 로그 (원문 전량)

```text
2026-08-26 09:18:11,331 [INFO] [Thread-A] Task Started. Calculating... (20%)
2026-08-26 09:18:11,382 [INFO] [Thread-A] Calculating... (40%)
2026-08-26 09:18:11,433 [INFO] [Thread-A] Preempted. Progress saved at (40%)
2026-08-26 09:18:11,483 [INFO] [Thread-B] Task Started. Calculating... (20%)
2026-08-26 09:18:11,534 [INFO] [Thread-B] Calculating... (40%)
2026-08-26 09:18:11,585 [INFO] [Thread-B] Preempted. Progress saved at (40%)
2026-08-26 09:18:11,636 [INFO] [Thread-C] Task Started. Calculating... (20%)
2026-08-26 09:18:11,686 [INFO] [Thread-C] Calculating... (40%)
2026-08-26 09:18:11,737 [INFO] [Thread-C] Preempted. Progress saved at (40%)
2026-08-26 09:18:11,788 [INFO] [Thread-A] Resumed. Calculating... (60%)
2026-08-26 09:18:11,839 [INFO] [Thread-A] Calculating... (80%)
2026-08-26 09:18:11,890 [INFO] [Thread-A] Preempted. Progress saved at (80%)
2026-08-26 09:18:11,940 [INFO] [Thread-B] Resumed. Calculating... (60%)
2026-08-26 09:18:11,991 [INFO] [Thread-B] Calculating... (80%)
2026-08-26 09:18:12,042 [INFO] [Thread-B] Preempted. Progress saved at (80%)
2026-08-26 09:18:12,092 [INFO] [Thread-C] Resumed. Calculating... (60%)
2026-08-26 09:18:12,143 [INFO] [Thread-C] Calculating... (80%)
2026-08-26 09:18:12,194 [INFO] [Thread-C] Preempted. Progress saved at (80%)
2026-08-26 09:18:12,245 [INFO] [Thread-A] Resumed. Calculating... (100%)
2026-08-26 09:18:12,296 [INFO] [Thread-B] Resumed. Calculating... (100%)
2026-08-26 09:18:12,347 [INFO] [Thread-C] Resumed. Calculating... (100%)
2026-08-26 09:18:12,398 [INFO] [Scheduler] All tasks completed.
```

> 원본: [../evidence/scheduling_workers.log](../evidence/scheduling_workers.log) L41-62 (발췌가 아니라 이 구간 전량이다)

읽는 법:

- 한 워커가 **연속 3개 이벤트**(`Task Started`/`Resumed` → `Calculating` → `Preempted`)를 내고 물러나면, 다음 워커가 이어받는다.
- `Preempted. Progress saved at (40%)` → 다음 턴에 `Resumed. Calculating... (60%)` 로 **중단 지점부터 재개**된다. 상태를 보존하는 교체다.
- 매 턴 진행률이 정확히 **20%p** 오른다(20 → 40 → 60 → 80 → 100).
- 마지막 라운드에서는 세 워커가 100% 를 찍고 `All tasks completed` 로 끝난다.

### 2-2. 타임스탬프로 본 교체 주기

첫 이벤트(09:18:11,331)를 0 ms 로 둔 경과·간격 표다.

```text
경과(ms)  간격(ms)  워커        이벤트
--------  --------  ----------  ------------------------------------------
       0         -  Thread-A    Task Started. Calculating... (20%)
      51        51  Thread-A    Calculating... (40%)
     102        51  Thread-A    Preempted. Progress saved at (40%)
     152        50  Thread-B    Task Started. Calculating... (20%)
     203        51  Thread-B    Calculating... (40%)
     254        51  Thread-B    Preempted. Progress saved at (40%)
     305        51  Thread-C    Task Started. Calculating... (20%)
     355        50  Thread-C    Calculating... (40%)
     406        51  Thread-C    Preempted. Progress saved at (40%)
     457        51  Thread-A    Resumed. Calculating... (60%)
     508        51  Thread-A    Calculating... (80%)
     559        51  Thread-A    Preempted. Progress saved at (80%)
     609        50  Thread-B    Resumed. Calculating... (60%)
     660        51  Thread-B    Calculating... (80%)
     711        51  Thread-B    Preempted. Progress saved at (80%)
     761        50  Thread-C    Resumed. Calculating... (60%)
     812        51  Thread-C    Calculating... (80%)
     863        51  Thread-C    Preempted. Progress saved at (80%)
     914        51  Thread-A    Resumed. Calculating... (100%)
     965        51  Thread-B    Resumed. Calculating... (100%)
    1016        51  Thread-C    Resumed. Calculating... (100%)

이벤트 21개 / 간격 표본 20개 — 최소 50ms, 최대 51ms, 평균 50.8ms, 중앙값 51ms
```

> 원본: [../evidence/scheduling_workers.log](../evidence/scheduling_workers.log) L176-200 (§2 — §1 의 `[Thread-*]` 라인만 뽑아 타임스탬프 차이를 계산한 표. 원본 라인은 무가공)

- **간격 20개 표본이 전부 50 또는 51 ms** 다. 편차가 1 ms 를 넘지 않는다.
- 워커 등장 순서: `A → A → A → B → B → B → C → C → C → A → A → A → B → B → B → C → C → C → A → B → C` — 라운드 단위로 **A → B → C 고정 회전**이다([scheduling_workers.log](../evidence/scheduling_workers.log) L201).
- 한 워커의 점유 구간은 `Started/Resumed → Preempted` 까지 약 **102 ms(=50 ms × 2)**, 그다음 51 ms 뒤 다음 워커가 시작한다.

### 2-3. `top -H` 에서 본 OS 스레드 (해석 주의)

```text
top - 09:20:10 up 3 days, 16:30,  4 users,  load average: 0.06, 0.21, 0.44
Threads:   3 total,   0 running,   3 sleeping,   0 stopped,   0 zombie

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
2765906 ashofro+  30  10  695860 479196   9828 S   0.0   0.7   0:00.05 agent-l+
2765955 ashofro+  30  10  695860 479196   9828 S   0.0   0.7   0:00.53 agent-l+
2765956 ashofro+  30  10  695860 479196   9828 S   0.0   0.7   0:00.32 agent-l+
```

> 원본: [../evidence/scheduling_top_h.txt](../evidence/scheduling_top_h.txt) L38-47

**여기서 관측된 사실을 정확히 적는다.** OS 가 보는 스레드는 3개이고 `TIME+` 는 서로 **다르다**(0:00.05 / 0:00.53 / 0:00.32). 즉 `[Thread-A] [Thread-B] [Thread-C]` 는 **OS 스레드가 아니라 앱 내부 스케줄러가 굴리는 논리적 태스크**이며, `top -H` 로는 개별 태스크의 CPU 시간을 분리해 볼 수 없다.

> 초판은 "세 스레드의 `TIME+` 가 ±0.03s 이내로 동일"한 것을 공평성의 결정적 증거로 제시했으나, 실측 `TIME+` 는 동일하지 않다. 해당 근거는 폐기하고, 공평성은 **로그의 턴 수·진행폭·완료 시각**(3-2 절)으로 다시 세운다.

스레드별 `TIME+` 가 실제로 전진하는지는 10s / 40s / 80s 세 시점 반복 캡처로 확인했다.

```text
##### t≈10s  2026-08-26 09:28:29  (MULTI_THREAD_ENABLE=false / Healthy System Monitoring) #####
2780021 ashofro+  30  10  197176  43976   9840 S   0.0   0.1   0:00.05 agent-l+
2780050 ashofro+  30  10  197176  43976   9840 S   0.0   0.1   0:00.01 agent-l+
2780051 ashofro+  30  10  197176  43976   9840 S   0.0   0.1   0:00.00 agent-l+
    LWP %CPU STAT WCHAN                    TIME CMD
2780021  0.9 SNl  futex_wait_queue     00:00:00 ./agent-leak-app
2780050  0.4 SNl  do_select            00:00:00 ./agent-leak-app
2780051  0.0 SNl  do_select            00:00:00 ./agent-leak-app

##### t≈80s  2026-08-26 09:29:39  (MULTI_THREAD_ENABLE=false / Healthy System Monitoring) #####
2780021 ashofro+  30  10  237108  95184   9840 S   0.0   0.1   0:00.05 agent-l+
2780050 ashofro+  30  10  237108  95184   9840 S   0.0   0.1   0:00.33 agent-l+
2780051 ashofro+  30  10  237108  95184   9840 S   0.0   0.1   0:00.19 agent-l+
```

> 원본: [../evidence/scheduling_top_h.txt](../evidence/scheduling_top_h.txt) L53-68 · L87-93 (t≈40s 블록은 원본 L70-85)

- 워커 스레드의 `TIME+` 가 `0:00.01 → 0:00.13 → 0:00.33` 으로 **전진**하고, 메인은 `0:00.05` 로 고정(워커 조인 대기)이다.
- `WCHAN` 은 `do_select`(타이머·I/O 대기) — 데드락 케이스에서 전 스레드가 `futex_wait_queue` 에 묶여 `TIME+` 가 정지했던 것과 정확히 대조된다.

---

## 3. 패턴 분석

### 3-1. FCFS 후보 기각

FCFS 라면 `Thread-A` 가 100% 로 끝날 때까지 B 와 C 는 시작조차 못 한다. 그러나 실제 로그는 A 가 **40% 에서 `Preempted`** 된 직후(51 ms 뒤) B 가 `Task Started` 로 진입한다.

```text
2026-08-26 09:18:11,433 [INFO] [Thread-A] Preempted. Progress saved at (40%)
2026-08-26 09:18:11,483 [INFO] [Thread-B] Task Started. Calculating... (20%)
```

→ **FCFS 아님.**

### 3-2. Priority 후보 기각

Priority 라면 특정 태스크가 자원을 독점하거나, 태스크 간 받은 턴 수·진행 속도에 편차가 있어야 한다. 실측은 정반대다.

| 확인 항목 | Thread-A | Thread-B | Thread-C |
| --------- | -------- | -------- | -------- |
| 받은 턴(라운드) 수 | 3 | 3 | 3 |
| 로그 이벤트 수 | 7 | 7 | 7 |
| 턴당 진행폭 | 20%p | 20%p | 20%p |
| 100% 도달 시각(경과) | 914 ms | 965 ms | 1016 ms |

세 태스크가 **완전히 같은 횟수의 턴**을 받았고, 완료 시각 차이는 한 할당량(51 ms) 이내다. 굶주린(starved) 태스크도, 앞질러 끝낸 태스크도 없다 → **Priority 아님.**

### 3-3. Round-Robin 결론

다음 세 가지가 모두 충족된다.

1. **고정 시간 할당량**: 간격 표본 20개가 전부 50~51 ms (평균 50.8 ms, 중앙값 51 ms)
2. **순환적 교체**: `A → B → C → A → B → C` 순서가 라운드마다 동일
3. **공평성**: 턴 수 3회씩 동일, 턴당 진행폭 20%p 동일, 완료 시각 차이 한 할당량 이내
4. **상태 보존 교체**: `Preempted. Progress saved at (40%)` → `Resumed. Calculating... (60%)` — 컨텍스트를 저장하고 복원한다

→ **Round-Robin** 스케줄링이 적용되어 있다고 강하게 추론할 수 있다. (할당량 ≈ 50 ms)

---

## 4. Round-Robin의 장단점과 적합 아키텍처

### 4-1. 장점

- **공평성**: 모든 작업이 굶주리지(starvation) 않고 일정 시간을 보장받음
- **응답성**: 새로운 작업도 한 라운드 안에 반드시 CPU 를 받음 → 인터랙티브 시스템에 유리
- **구현 단순성**: FIFO 큐 + 타이머만 있으면 됨

### 4-2. 단점

- **컨텍스트 스위칭 오버헤드**: 할당량이 너무 짧으면 교체 비용(레지스터 저장/복원, 캐시 미스)이 실제 작업 시간보다 커질 수 있음
- **처리량(throughput) 손해**: 긴 배치 작업에서는 끊임없이 인터럽트되어 캐시 효율이 떨어짐
- **할당량 튜닝 난도**: 너무 길면 응답성 저하, 너무 짧으면 오버헤드 증가 — "적정값"이 워크로드 의존적

### 4-3. 적합한 아키텍처

| 적합한 서비스 | 이유 |
| ------------- | ---- |
| **실시간 응답형 웹 서버**, REST API | 요청별 응답 지연 분산이 일정해야 함, 한 요청이 다른 요청을 굶기지 않아야 함 |
| **인터랙티브 데스크톱/CLI** | 사용자 체감 응답성 우선 |
| **멀티테넌트 SaaS 워커 풀** | 테넌트 간 공평성(fair-share) 보장 필요 |

| 부적합한 서비스 | 이유 |
| --------------- | ---- |
| **대용량 배치 / ETL** | 처리량이 우선이라 작업당 끝까지 실행하는 FCFS / SJF 가 유리 |
| **실시간 제어 시스템 (RTOS)** | 데드라인이 짧고 우선순위가 명확한 작업은 Priority/EDF 가 유리 |
| **HPC 수치연산** | 컨텍스트 스위칭 오버헤드 최소화가 필요 |

본 `agent-leak-app` 이 운영 환경에서 외부 클라이언트의 다수 요청을 동시에 처리하는 **에이전트형 서버**임을 고려하면, Round-Robin 채택은 합리적 설계 결정이라고 볼 수 있다.

---

## 5. 한계 / 추가 검증 아이디어

- **관측 표본이 1 라운드 세트뿐이다.** `[Scheduler]` 블록은 부팅 직후 **한 번만** 돌고(수집 120초 중 09:18:11,331 ~ 09:18:12,398 의 **약 1.07초**), 이후에는 `[MemoryWorker]` / `[CpuWorker]` 만 남는다(수집 133줄 중 `[Thread-*]` 21줄). 따라서 "할당량 ≈ 50 ms" 는 이 한 세트의 20개 간격에 근거한 값이며, 장시간 안정성은 확인하지 못했다.
- **`Preempted` 는 앱이 스스로 붙인 문구다.** 진정한 선점형(타이머 인터럽트)인지 협조적 양보(`time.sleep(0)` / `await`)인지는 외부 관측만으로 가르지 못했다. 구분하려면 **할당량을 다 채우지 못한 채 양보하는 케이스**가 있는지 확인해야 하는데, 이번 표본에서는 모든 구간이 50~51 ms 로 균일해 그런 사례가 없었다.
- **`[Thread-A/B/C]` 는 OS 스레드가 아니다.** `top -H` 는 스레드 3개(메인 + 워커 2)만 보여 주며 `TIME+` 도 서로 다르다(2-3 절). 태스크별 CPU 시간을 직접 재려면 앱이 태스크 단위 계측을 노출해야 한다.
- 워커 수를 4, 6, 8로 늘려 1라운드 주기가 `워커 수 × 50 ms` 로 비례하는지 검증하면 RR 가설을 더 강하게 확정할 수 있다. 다만 워커 수는 환경변수로 조절되지 않아 이번 실험에서는 확인하지 못했다.
- Linux 자체 스케줄러(CFS)는 본 분석 대상이 아니다 — 본 분석은 **앱 내부 워커 디스패처**의 정책에 한정된다. 참고로 이 프로세스는 부팅 시 `nice=10` 으로 우선순위를 낮춘다(`[SafetyGuard] Process priority lowered`).

---

## 6. 첨부 / 참조

- [evidence/scheduling_workers.log](../evidence/scheduling_workers.log) — `[Scheduler]`/`[Thread-A|B|C]`/`[MemoryWorker]`/`[CpuWorker]` 태그 133줄 원본 + 이벤트 간격 계산표
- [evidence/scheduling_top_h.txt](../evidence/scheduling_top_h.txt) — 파이프라인 `top -H` 스냅샷 + 10s/40s/80s 반복 캡처(`TIME+` 전진, `WCHAN=do_select`)
