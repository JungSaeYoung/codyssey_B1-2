#!/usr/bin/env bash
# 01_oom.sh — OOM(메모리 한계 초과) 장애 재현·검증
# -----------------------------------------------------------------------------
# 실험_절차서.md §1 에 대응.
#   Before  MEMORY_LIMIT=256  → 'SELF-TERMINATED' / 'Memory limit exceeded' 자가종료 관측
#   After   MEMORY_LIMIT=512  → 생존시간 연장(Before×1.5 이상) 검증
#   증거    oom_monitor.log / oom_app.log / oom_ps_top.txt
#
# 자가종료형이라 공통 코어 _terminating_experiment (lib_experiment.sh §6) 를 그대로 쓴다.
#
# 단독 실행:  bash 01_oom.sh            (사전점검 → OOM 실험 → 요약)
# 옵션 예:    QUICK=1 bash 01_oom.sh    RUN_AFTER=0 bash 01_oom.sh
# 일괄 실행:  bash 00_run_experiments.sh oom
# -----------------------------------------------------------------------------

set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_experiment.sh"

experiment_oom() {
    # 종료 시그니처: 'SELF-TERMINATED' / 'Memory limit exceeded'
    # (정상 동작 중 WARN 'approaching limit' 은 매칭 안 되도록 'exceeded' 사용)
    _terminating_experiment "OOM" "self-terminat|limit exceeded" \
        oom_monitor.log oom_app.log oom_ps_top.txt \
        "export MEMORY_LIMIT=256 CPU_MAX_OCCUPY=95 MULTI_THREAD_ENABLE=false" \
        "export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95 MULTI_THREAD_ENABLE=false" \
        "$OOM_BEFORE_TIMEOUT"
}

# 직접 실행할 때만 단독 파이프라인을 돈다. (오케스트레이터가 source 로 함수만 가져갈 때는 통과)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "${1:-}" == selftest ]] && { selftest; exit 0; }   # 단독 실행도 배선만 점검 가능
    preflight "run"
    experiment_oom
    print_summary
fi
