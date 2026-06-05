#!/usr/bin/env bash
# 02_cpu.sh — CPU 과점유 장애 재현·검증
# -----------------------------------------------------------------------------
# 실험_절차서.md §2 에 대응.
#   Before  CPU_MAX_OCCUPY=80  → Watchdog 의 'EMERGENCY ABORT' / 'SIGTERM' 자가종료 관측
#   After   CPU_MAX_OCCUPY=95  → 생존시간 연장(Before×1.5 이상, 여전히 종료) 검증
#   증거    cpu_monitor.log / cpu_app.log / cpu_top_ps.txt
#
# 자가종료형이라 공통 코어 _terminating_experiment (lib_experiment.sh §6) 를 그대로 쓴다.
#
# 단독 실행:  bash 02_cpu.sh            (사전점검 → CPU 실험 → 요약)
# 옵션 예:    QUICK=1 bash 02_cpu.sh    RUN_AFTER=0 bash 02_cpu.sh
# 일괄 실행:  bash 00_run_experiments.sh cpu
# -----------------------------------------------------------------------------

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_experiment.sh"

experiment_cpu() {
    # 종료 시그니처: 'EMERGENCY ABORT' / 'SIGTERM' (Watchdog 자가 종료 라인).
    # 정상 동작 중 WARN '[Watchdog] cpu=72% (threshold 80%)' 에는 이 토큰이 없어
    # 조기 오탐을 피한다 — bare 'watchdog' 은 일부러 패턴에서 제외.
    _terminating_experiment "CPU" "emergency abort|sigterm" \
        cpu_monitor.log cpu_app.log cpu_top_ps.txt \
        "export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=80 MULTI_THREAD_ENABLE=false" \
        "export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95 MULTI_THREAD_ENABLE=false" \
        "$CPU_BEFORE_TIMEOUT"
}

# 직접 실행할 때만 단독 파이프라인을 돈다. (오케스트레이터가 source 로 함수만 가져갈 때는 통과)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == selftest ]] && { selftest; exit 0; }   # 단독 실행도 배선만 점검 가능
    preflight "run"
    experiment_cpu
    print_summary
fi
