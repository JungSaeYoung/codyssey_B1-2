#!/usr/bin/env bash
# 04_scheduling.sh — 스케줄링 추론용 데이터 수집 (보너스)
# -----------------------------------------------------------------------------
# 실험_절차서.md §4 에 대응.
#   환경    MULTI_THREAD_ENABLE=false MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10 (= [Healthy System Monitoring])
#   수집    SCHED_DURATION 동안 스케줄러/워커 로그([Scheduler]/[Thread-A|B|C]/[MemoryWorker]/[CpuWorker]) 누적 + top -H 스레드 스냅샷
#   증거    scheduling_workers.log / scheduling_top_h.txt
#   판정    서로 다른 워커 2종 이상 + 로그 1줄 이상이면 PASS (RR 추론 입력 확보)
#           (워커 태그는 WORKER_TAG 환경변수로 덮어쓸 수 있다)
#
# 장애 재현이 아니라 "정상 가동 구간" 데이터 수집이라 Before/After 가 없다.
#
# 단독 실행:  bash 04_scheduling.sh          (사전점검 → 수집 → 요약)
# 옵션 예:    QUICK=1 bash 04_scheduling.sh  SCHED_DURATION=120 bash 04_scheduling.sh
# 일괄 실행:  bash 00_run_experiments.sh scheduling
# -----------------------------------------------------------------------------

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_experiment.sh"

# 워커 로그 태그 패턴 — 예: [MemoryWorker] [CpuWorker] [Worker-Thread-1]
WORKER_TAG="${WORKER_TAG:-\\[[A-Za-z0-9_-]*(Worker|Thread|Scheduler)[A-Za-z0-9_-]*\\]}"

experiment_scheduling() {
    local WK="${EVIDENCE_DIR}/scheduling_workers.log"
    local TH="${EVIDENCE_DIR}/scheduling_top_h.txt"

    banner "Scheduling 추론 데이터 수집 (보너스)"
    # [고침] MULTI_THREAD_ENABLE=true → 데드락 시나리오라 9초 만에 전 스레드가 멈춘다.
    #   스케줄러 교체 패턴([Scheduler] Thread-A/B/C + Preempted/Resumed)은 세 조건이 모두
    #   안전할 때 선택되는 [Healthy System Monitoring] 시나리오에서만 출력된다(실측).
    #   따라서 보너스(B1-2-B1~B3) 데이터는 정상 가동 조합으로 받는다.
    step "환경: export MULTI_THREAD_ENABLE=false MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10  (Healthy System Monitoring)"
    export MULTI_THREAD_ENABLE=false MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10
    _kill_leftovers

    local pid; pid="$(launch_app "$APP_STDOUT")"; CURRENT_PID="$pid"
    pid="$(_confirm_pid "$pid")"; CURRENT_PID="$pid"
    step "정상 가동 $(fmt "$SCHED_DURATION") 동안 워커 로그 수집 (PID=${pid})"

    local waited=0
    while (( waited < SCHED_DURATION )); do
        app_alive "$pid" || { warn "앱이 조기 종료됨 — 수집 중단"; break; }
        sleep "$SAMPLE_INTERVAL"; waited=$(( waited + SAMPLE_INTERVAL ))
    done

    # [고침] 실제 앱이 찍는 워커 태그는 Worker-A/B/C 가 아니라
    #        [MemoryWorker] / [CpuWorker] / [Worker-Thread-N] 형태다(직접 실행해 확인).
    #        태그 이름을 하드코딩하지 않고 "…Worker…" / "…Thread…" 대괄호 태그를 포괄 매칭한다.
    grep -E "$WORKER_TAG" "$APP_LOG" > "$WK" 2>/dev/null || true
    top -H -bn1 -p "$pid" > "$TH" 2>/dev/null || true
    kill_app "$pid"; CURRENT_PID=""

    local lines workers
    lines="$(wc -l < "$WK" 2>/dev/null | tr -d ' ')"; lines="${lines:-0}"
    workers="$(grep -oE "$WORKER_TAG" "$WK" 2>/dev/null | sort -u | wc -l | tr -d ' ')"; workers="${workers:-0}"

    local verdict detail
    if (( lines > 0 && workers >= 2 )); then
        verdict="PASS"; detail="워커 로그 ${lines}줄 / 서로 다른 워커 ${workers}종 수집 (RR 추론 입력 확보)"
        pass "Scheduling 파이프라인 — ${detail}"
    else
        verdict="WARN"; detail="워커 로그 부족 (lines=${lines}, workers=${workers}) — 멀티스레드 로그 형식 확인"
        warn "Scheduling 파이프라인 — ${detail}"
    fi
    _record "Scheduling" "$verdict" "$detail"
}

# 직접 실행할 때만 단독 파이프라인을 돈다. (오케스트레이터가 source 로 함수만 가져갈 때는 통과)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == selftest ]] && { selftest; exit 0; }   # 단독 실행도 배선만 점검 가능
    preflight "run"
    experiment_scheduling
    print_summary
fi
