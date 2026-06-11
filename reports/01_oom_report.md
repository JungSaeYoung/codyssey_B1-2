# [Bug] agent-leak-app 실행 10분 경과 시 MemoryGuard 정책에 의한 강제 종료

> 라벨: `bug`, `priority/high`, `area/memory`
> 담당: agent-dev
> 환경: Ubuntu 24.04 (OrbStack), agent-admin 계정, `MEMORY_LIMIT=256`

---

## 1. Description (현상 설명)

`agent-leak-app` 어플리케이션을 정상 실행한 뒤 **약 10분이 경과**하면, 별도의 사용자 입력이나 외부 요청이 없는데도 다음 메시지가 출력되며 프로세스가 종료된다.

```
[CRITICAL] [MemoryGuard] Memory limit exceeded (256MB >= 256MB)
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
```

- 발생 시각: 2026-05-11 14:00:00 실행 → 14:10:23 종료 (약 10분 23초)
- 재현성: 동일한 환경변수(`MEMORY_LIMIT=256`)로 3회 시도, 3회 모두 9분~11분 사이에 동일 메시지 출력 후 종료
- 외부 트래픽 없음. 부팅 시점부터 자체적으로 메모리만 단조 증가 → 임계치 도달 → 종료의 패턴이 반복됨

---

## 2. Evidence & Logs (증거 자료)

### 2-1. `monitor.sh` 관제 로그 (`/var/log/agent-app/monitor.log`)

CPU 사용률은 1~2%대로 거의 일정한데, **MEM 사용률만 시간 경과에 따라 선형 상승** 후 임계치에서 종료된다.

```text
[2026-05-11 14:00:00] PID:12345 CPU:1.2% MEM:5.1%  DISK_USED:42%
[2026-05-11 14:03:00] PID:12345 CPU:1.5% MEM:35.4% DISK_USED:42%
[2026-05-11 14:06:00] PID:12345 CPU:1.4% MEM:68.2% DISK_USED:42%
[2026-05-11 14:09:00] PID:12345 CPU:1.3% MEM:89.5% DISK_USED:42%
[2026-05-11 14:10:00] PID:12345 CPU:1.5% MEM:96.8% DISK_USED:42%
# 14:11:00 이후 라인 사라짐 (Health Check 실패로 monitor.sh 가 exit 1)
[2026-05-11 14:11:00] [ERROR] Application process not running.
```

> 원본: [../evidence/oom_monitor.log](../evidence/oom_monitor.log)

추세를 정리하면 MEM%가 **3분당 약 +30%p** 씩 상승해 약 10분 후 96%에 도달했다. 이 시점에서 `MEMORY_LIMIT=256MB`를 채우자 앱 내부 정책이 발동했다.

### 2-2. agent-leak-app 실행 로그 (`$AGENT_LOG_DIR/agent-leak-app.log`)

```text
[2026-05-11 14:00:00.123] [INFO]  Boot sequence OK. Agent READY (pid=12345)
[2026-05-11 14:00:01.011] [INFO]  [Worker-A] Task started. allocate(8MB)
[2026-05-11 14:01:30.880] [INFO]  [Worker-A] heap=42MB / 256MB
[2026-05-11 14:05:00.114] [INFO]  [Worker-A] heap=140MB / 256MB
[2026-05-11 14:09:55.402] [WARN]  [MemoryGuard] heap usage approaching limit (244MB / 256MB)
[2026-05-11 14:10:22.999] [CRITICAL] [MemoryGuard] Memory limit exceeded (256MB >= 256MB) / (Recommend Over 256MB)
[2026-05-11 14:10:23.001] [CRITICAL] [MemoryGuard] Self-terminating process 12345 to prevent system instability.
>>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
```

> 원본: [../evidence/oom_app.log](../evidence/oom_app.log)

### 2-3. `ps` / `top` 출력 (종료 직전, 14:10:20 시점)

```text
$ ps -o pid,ppid,rss,vsz,cmd -C python3
   PID   PPID    RSS    VSZ CMD
 12345   2210 262144 318472 /usr/bin/python3 ./agent-leak-app

# RSS=262144 KB ≈ 256MB → MEMORY_LIMIT 와 일치
```

```text
$ top -bn1 -p 12345
  PID USER       PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
12345 agent-admin 20  0  311M   256M  4.2M S   1.5  96.5   0:08.31 python3
```

---

## 3. Root Cause Analysis (원인 분석)

### 3-1. 현상 → 원인 매핑

| 관측 사실 | 추론되는 원인 |
| --------- | ------------- |
| CPU는 평탄, MEM 만 단조 증가 | "계산 폭주"가 아닌 **메모리 누수**(Memory Leak) |
| 시간/실행량에 비례해 RSS 가 증가 | 워커 스레드가 생성한 객체를 해제하지 않고 컬렉션에 누적하고 있음 |
| OOM Killer 가 아닌 앱 자체 로그로 종료됨 | 커널 OOM 이 아니라 **앱 내장 MemoryGuard** 가 SIGKILL/exit 수행 |

### 3-2. 운영체제 동작 원리

- 프로세스 메모리는 **코드(Text) / 데이터 / 힙(Heap) / 스택**으로 나뉘며, `malloc`/`new`/`list.append` 등으로 힙에 적재된 객체는 명시적으로 `free`/`del`/GC 처리하지 않으면 RSS(Resident Set Size)가 회수되지 않는다.
- 누수가 누적되면 OS 입장에서는 "정상 점유 중인 메모리"이므로 다른 프로세스로 swap-out 되거나, 끝내 RAM 부족 시 **커널의 OOM Killer** 가 가장 큰 점유자를 SIGKILL 한다.
- 본 앱은 그 전에 자체적으로 `RSS >= MEMORY_LIMIT` 조건을 모니터링해 **시스템 전체를 보호**할 목적으로 self-terminate 한다. `Memory limit exceeded ... Self-terminating` 로그가 그 증거.

### 3-3. 결론

> 워커 로직이 생성한 데이터를 힙에서 해제하지 않아 RSS 가 단조 증가했고, 256MB 임계치에 도달하자 **MemoryGuard 정책이 발동**하여 프로세스가 강제 종료되었다.

---

## 4. Workaround & Verification (조치 및 검증)

### 4-1. 조치 — 임시: `MEMORY_LIMIT` 상향

`~/.bashrc` (환경변수 등록 파일 — `src/05_env_and_keyfile.sh` 가 자동 등록):

```bash
# Before
export MEMORY_LIMIT=256

# After (임시)
export MEMORY_LIMIT=512
```

`source ~/.bashrc` 후 동일 시나리오로 재실행.

### 4-2. Before & After 비교

| 항목 | Before (`MEMORY_LIMIT=256`) | After (`MEMORY_LIMIT=512`) |
| ---- | --------------------------- | -------------------------- |
| 종료 시점 | 실행 후 **약 10분 23초** | 실행 후 **약 21분 47초** (≈ 2배) |
| 종료 로그 | `SELF-TERMINATED (Memory Limit Exceeded)` | 동일 로그, 다만 임계치만 늦게 도달 |
| MEM% 도달 패턴 | 선형 증가, 약 **3분당 +30%p** | 선형 증가지만 한도가 2배(512MB)라 **MEM% 기울기는 약 절반(≈13%p/3분)** |

After 시점의 monitor.log:

```text
[2026-05-11 15:00:00] PID:13402 CPU:1.4% MEM:5.0%  DISK_USED:42%
[2026-05-11 15:10:00] PID:13402 CPU:1.5% MEM:48.6% DISK_USED:42%
[2026-05-11 15:20:00] PID:13402 CPU:1.3% MEM:92.1% DISK_USED:42%
[2026-05-11 15:22:00] [ERROR] Application process not running.
```

→ **임계치만 늦췄을 뿐, 누수 자체는 동일**. 종료 시점이 거의 정확히 2배 늘어났다는 사실이 "단위 시간당 누수량 일정 + 임계치만 변경됨"을 입증한다.

### 4-3. 근본 해결을 위한 제안 (선택)

- 워커 로직에서 처리 완료된 작업 결과를 `del` / `pop` / `clear()` 처리하거나, `collections.deque(maxlen=...)` 사용
- 장시간 보관이 필요한 데이터는 디스크/외부 캐시(Redis 등)로 오프로드
- `tracemalloc`, `memray`, `objgraph` 등으로 누수 객체의 클래스/스택트레이스 식별
- 단위 테스트에서 메모리 사용량 회귀 가드 (예: `psutil`로 RSS 측정, 임계치 초과 시 fail)

---

## 5. 첨부 / 참조

- [evidence/oom_monitor.log](../evidence/oom_monitor.log) — Before / After 관제 로그
- [evidence/oom_app.log](../evidence/oom_app.log) — agent-leak-app 실행 로그
- [evidence/oom_ps_top.txt](../evidence/oom_ps_top.txt) — `ps` / `top` 캡처
